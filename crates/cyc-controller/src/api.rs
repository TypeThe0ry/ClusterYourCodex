use std::str::FromStr;
use std::sync::Arc;

use axum::body::{Body, Bytes};
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::header::{
    AUTHORIZATION, CACHE_CONTROL, CONTENT_DISPOSITION, CONTENT_LENGTH, CONTENT_TYPE, ETAG, HOST,
    ORIGIN, WWW_AUTHENTICATE,
};
use axum::http::{HeaderMap, HeaderValue, Request, StatusCode, Uri};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post, put};
use axum::{Json, Router};
use chrono::{DateTime, Utc};
use cyc_protocol::onboarding::{
    CreatePairingRequestV1, EnrollmentBundleV1, PairingFailureCodeV1, PairingPhaseV1,
    PairingStatusErrorV1, PairingStatusV1, ENROLLMENT_API_VERSION,
};
use cyc_protocol::{
    CleanupReservationReleaseReasonV1, CleanupStatusPhaseV1, CleanupStatusV1,
    JobRootCleanupOutcomeV1, JobSpec, Node, NodeConfig, PlacementPlanBindingV1, Run,
    SnapshotMetadataV1, TerminalCompletionAckV1, CLEANUP_API_VERSION, MAX_SNAPSHOT_ARCHIVE_BYTES,
    SNAPSHOT_MEDIA_TYPE,
};
use cyc_scheduler::{ScheduleError, Scheduler};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::{json, Value};
use tower_http::trace::TraceLayer;
use uuid::Uuid;

use crate::auth::AuthToken;
use crate::store::{FleetNodeView, LogChunk, Store, StoreError, StoredArtifact, StoredJob};

const MAX_JSON_BODY_BYTES: usize = 1024 * 1024;

#[derive(Clone)]
pub struct AppState {
    pub store: Store,
    pub scheduler: Arc<Scheduler>,
    security: Arc<SecurityPolicy>,
    worker_endpoint: Option<Arc<WorkerEndpoint>>,
}

#[derive(Clone)]
pub struct WorkerEndpoint {
    pub public_url: String,
    pub certificate_pem: Arc<str>,
}

struct SecurityPolicy {
    token: AuthToken,
    port: u16,
}

impl AppState {
    pub fn new(store: Store, token: AuthToken, port: u16) -> Self {
        Self {
            store,
            scheduler: Arc::new(Scheduler::default()),
            security: Arc::new(SecurityPolicy { token, port }),
            worker_endpoint: None,
        }
    }

    pub fn with_worker_endpoint(mut self, public_url: String, certificate_pem: String) -> Self {
        self.worker_endpoint = Some(Arc::new(WorkerEndpoint {
            public_url,
            certificate_pem: Arc::from(certificate_pem),
        }));
        self
    }

    pub(crate) fn worker_endpoint(&self) -> Option<&WorkerEndpoint> {
        self.worker_endpoint.as_deref()
    }
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/v1/health", get(health))
        .route("/v1/fleet", get(fleet))
        .route(
            "/v1/nodes/{id}/config",
            get(get_node_config).put(update_node_config),
        )
        .route("/v1/plans", post(plan))
        .route("/v1/jobs", get(list_jobs).post(submit_job))
        .route("/v1/jobs/{id}", get(get_job))
        .route("/v1/jobs/{id}/cancel", post(cancel_job))
        .route("/v1/jobs/{id}/cleanup", get(get_job_cleanup))
        .route("/v1/pairings", post(create_pairing))
        .route("/v1/pairings/{id}", get(get_pairing_status))
        .route("/v1/pairings/{id}/failure", put(report_pairing_failure))
        .route("/v1/pairings/{id}/revoke", post(revoke_pairing))
        .route(
            "/v1/snapshots/{sha256}",
            put(upload_snapshot)
                .head(head_snapshot)
                .layer(DefaultBodyLimit::max(MAX_SNAPSHOT_ARCHIVE_BYTES as usize)),
        )
        .route("/v1/jobs/{id}/logs", get(list_job_logs))
        .route("/v1/jobs/{id}/logs/{stream}", get(download_job_log))
        .route("/v1/jobs/{id}/artifacts", get(list_job_artifacts))
        .route(
            "/v1/jobs/{id}/artifacts/{artifact_id}",
            get(download_job_artifact),
        )
        .layer(DefaultBodyLimit::max(MAX_JSON_BODY_BYTES))
        .layer(TraceLayer::new_for_http())
        .layer(middleware::from_fn_with_state(
            state.clone(),
            security_middleware,
        ))
        .with_state(state)
}

async fn upload_snapshot(
    State(state): State<AppState>,
    Path(sha256): Path<String>,
    headers: HeaderMap,
    bytes: Bytes,
) -> Result<Response, ApiError> {
    require_snapshot_content_type(&headers)?;
    let declared_size = parse_required_content_length(&headers)?;
    if declared_size > MAX_SNAPSHOT_ARCHIVE_BYTES {
        return Err(ApiError::snapshot_too_large());
    }
    if declared_size != u64::try_from(bytes.len()).unwrap_or(u64::MAX) {
        return Err(ApiError::invalid_snapshot());
    }
    let digest = format!("sha256:{sha256}");
    cyc_protocol::validate_snapshot_digest(&digest).map_err(|_| ApiError::invalid_snapshot())?;
    let store = state.store.clone();
    let metadata = store_call(move || store.put_snapshot(&digest, declared_size, &bytes)).await?;
    let mut response = (StatusCode::CREATED, Json(metadata.clone())).into_response();
    apply_snapshot_headers(response.headers_mut(), &metadata, false)?;
    Ok(response)
}

async fn head_snapshot(
    State(state): State<AppState>,
    Path(sha256): Path<String>,
) -> Result<Response, ApiError> {
    let digest = format!("sha256:{sha256}");
    cyc_protocol::validate_snapshot_digest(&digest).map_err(|_| ApiError::invalid_snapshot())?;
    let store = state.store.clone();
    let metadata = store_call(move || store.get_snapshot_metadata(&digest)).await?;
    let mut response = StatusCode::OK.into_response();
    apply_snapshot_headers(response.headers_mut(), &metadata, true)?;
    Ok(response)
}

fn require_snapshot_content_type(headers: &HeaderMap) -> Result<(), ApiError> {
    let content_type = headers
        .get(CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(';').next())
        .map(str::trim);
    if content_type.is_some_and(|value| value.eq_ignore_ascii_case(SNAPSHOT_MEDIA_TYPE)) {
        Ok(())
    } else {
        Err(ApiError::snapshot_content_type())
    }
}

fn parse_required_content_length(headers: &HeaderMap) -> Result<u64, ApiError> {
    headers
        .get(CONTENT_LENGTH)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<u64>().ok())
        .ok_or_else(ApiError::invalid_snapshot)
}

fn apply_snapshot_headers(
    headers: &mut HeaderMap,
    metadata: &SnapshotMetadataV1,
    archive_representation: bool,
) -> Result<(), ApiError> {
    let etag = HeaderValue::from_str(&format!("\"{}\"", metadata.digest))
        .map_err(|_| ApiError::internal())?;
    let size = HeaderValue::from_str(&metadata.size_bytes.to_string())
        .map_err(|_| ApiError::internal())?;
    headers.insert(ETAG, etag);
    headers.insert(
        CACHE_CONTROL,
        HeaderValue::from_static("private, immutable, max-age=31536000"),
    );
    headers.insert("x-cyc-snapshot-size", size.clone());
    headers.insert(
        "x-cyc-snapshot-version",
        HeaderValue::from_static(cyc_protocol::SNAPSHOT_API_VERSION),
    );
    headers.insert(
        "x-cyc-snapshot-format",
        HeaderValue::from_static(cyc_protocol::SNAPSHOT_ARCHIVE_FORMAT),
    );
    if archive_representation {
        headers.insert(CONTENT_TYPE, HeaderValue::from_static(SNAPSHOT_MEDIA_TYPE));
        headers.insert(CONTENT_LENGTH, size);
    }
    Ok(())
}

async fn security_middleware(
    State(state): State<AppState>,
    request: Request<Body>,
    next: Next,
) -> Response {
    if !valid_host(request.headers(), state.security.port) {
        return security_error(
            StatusCode::BAD_REQUEST,
            "invalid_host",
            "Host must identify the loopback controller",
        );
    }
    if !valid_origin(request.headers(), state.security.port) {
        return security_error(
            StatusCode::FORBIDDEN,
            "invalid_origin",
            "Origin is not allowed",
        );
    }
    if request.uri().path() != "/v1/health" && !authorized(request.headers(), &state.security.token)
    {
        return security_error(
            StatusCode::UNAUTHORIZED,
            "unauthorized",
            "a valid controller bearer token is required",
        );
    }
    next.run(request).await
}

fn valid_host(headers: &HeaderMap, expected_port: u16) -> bool {
    let Some(value) = headers.get(HOST).and_then(|value| value.to_str().ok()) else {
        return false;
    };
    valid_loopback_authority(value, expected_port)
}

fn valid_origin(headers: &HeaderMap, expected_port: u16) -> bool {
    let Some(value) = headers.get(ORIGIN) else {
        return true;
    };
    let Ok(value) = value.to_str() else {
        return false;
    };
    let Ok(uri) = Uri::from_str(value) else {
        return false;
    };
    if !matches!(uri.scheme_str(), Some("http" | "https")) {
        return false;
    }
    uri.authority()
        .is_some_and(|authority| valid_loopback_authority(authority.as_str(), expected_port))
}

fn valid_loopback_authority(value: &str, expected_port: u16) -> bool {
    let Ok(authority) = axum::http::uri::Authority::from_str(value) else {
        return false;
    };
    let host = authority.host();
    let loopback =
        matches!(host, "127.0.0.1" | "::1" | "[::1]") || host.eq_ignore_ascii_case("localhost");
    loopback && authority.port_u16() == Some(expected_port)
}

fn authorized(headers: &HeaderMap, token: &AuthToken) -> bool {
    let Some(value) = headers
        .get(AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
    else {
        return false;
    };
    let Some((scheme, candidate)) = value.split_once(' ') else {
        return false;
    };
    scheme.eq_ignore_ascii_case("bearer")
        && !candidate.is_empty()
        && !candidate.contains(char::is_whitespace)
        && token.matches(candidate)
}

fn security_error(status: StatusCode, code: &'static str, message: &'static str) -> Response {
    let mut response = (
        status,
        Json(json!({ "error": { "code": code, "message": message } })),
    )
        .into_response();
    if status == StatusCode::UNAUTHORIZED {
        response
            .headers_mut()
            .insert(WWW_AUTHENTICATE, HeaderValue::from_static("Bearer"));
    }
    response
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct HealthResponse {
    status: &'static str,
    api_version: &'static str,
    controller_version: &'static str,
    database: &'static str,
}

async fn health(State(state): State<AppState>) -> Result<Json<HealthResponse>, ApiError> {
    let store = state.store.clone();
    store_call(move || store.ping()).await?;
    Ok(Json(HealthResponse {
        status: "ok",
        api_version: "cyc.dev/v1",
        controller_version: env!("CARGO_PKG_VERSION"),
        database: "ok",
    }))
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct FleetResponse {
    fleet_revision: u64,
    observed_at: DateTime<Utc>,
    controller: ControllerSummary,
    codex: CodexSummary,
    nodes: Vec<Node>,
    node_views: Vec<FleetNodeView>,
    recent_jobs: Vec<JobView>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ControllerSummary {
    version: &'static str,
    api_version: &'static str,
    access: &'static str,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct CodexSummary {
    integration: &'static str,
    status: &'static str,
}

async fn fleet(State(state): State<AppState>) -> Result<Json<FleetResponse>, ApiError> {
    let store = state.store.clone();
    let snapshot = store_call(move || store.fleet_snapshot(20)).await?;
    Ok(Json(FleetResponse {
        fleet_revision: snapshot.fleet_revision,
        observed_at: snapshot.observed_at,
        controller: ControllerSummary {
            version: env!("CARGO_PKG_VERSION"),
            api_version: "cyc.dev/v1",
            access: "loopback",
        },
        codex: CodexSummary {
            integration: "mcp",
            status: "available",
        },
        nodes: snapshot.nodes,
        node_views: snapshot.node_views,
        recent_jobs: snapshot
            .recent_jobs
            .into_iter()
            .map(JobView::from)
            .collect(),
    }))
}

const NODE_CONFIG_API_VERSION: &str = "cyc.dev/node-config/v1";

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct NodeConfigDocument {
    api_version: &'static str,
    node_id: Uuid,
    revision: i64,
    config: NodeConfig,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct NodeConfigUpdate {
    expected_revision: i64,
    config: NodeConfig,
}

async fn get_node_config(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<Json<NodeConfigDocument>, ApiError> {
    let store = state.store.clone();
    let stored = store_call(move || store.get_node_config(id)).await?;
    Ok(Json(NodeConfigDocument {
        api_version: NODE_CONFIG_API_VERSION,
        node_id: stored.node_id,
        revision: stored.revision,
        config: stored.config,
    }))
}

async fn update_node_config(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    headers: HeaderMap,
    bytes: Bytes,
) -> Result<Json<NodeConfigDocument>, ApiError> {
    let request: NodeConfigUpdate = parse_json_body(&headers, &bytes)?;
    let store = state.store.clone();
    let stored = store_call(move || {
        store.update_node_config(id, request.expected_revision, &request.config)
    })
    .await?;
    Ok(Json(NodeConfigDocument {
        api_version: NODE_CONFIG_API_VERSION,
        node_id: stored.node_id,
        revision: stored.revision,
        config: stored.config,
    }))
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PlanRequest {
    job: JobSpec,
}

async fn plan(
    State(state): State<AppState>,
    headers: HeaderMap,
    bytes: Bytes,
) -> Result<Json<PlacementPlanBindingV1>, ApiError> {
    let request: PlanRequest = parse_json_body(&headers, &bytes)?;
    request
        .job
        .validate()
        .map_err(|_| ApiError::invalid_job())?;
    let store = state.store.clone();
    let scheduler = state.scheduler.clone();
    let job = request.job;
    let plan = store_call(move || store.create_plan(&job, &scheduler)).await?;
    Ok(Json(plan.binding))
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SubmitJobRequest {
    job: JobSpec,
    plan_id: Option<Uuid>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct JobView {
    job: JobSpec,
    run: Run,
    /// `null` is an explicit legacy marker for rows that lacked exactly one
    /// validated used plan during migration. New jobs always carry a binding.
    plan_binding: Option<PlacementPlanBindingV1>,
    version: u64,
    cancel_requested: bool,
}

impl From<StoredJob> for JobView {
    fn from(value: StoredJob) -> Self {
        Self {
            job: value.job,
            run: value.run,
            plan_binding: value.plan_binding,
            version: value.version,
            cancel_requested: value.cancel_requested,
        }
    }
}

async fn submit_job(
    State(state): State<AppState>,
    headers: HeaderMap,
    bytes: Bytes,
) -> Result<(StatusCode, Json<JobView>), ApiError> {
    let request: SubmitJobRequest = parse_json_body(&headers, &bytes)?;
    request
        .job
        .validate()
        .map_err(|_| ApiError::invalid_job())?;
    let store = state.store.clone();
    let scheduler = state.scheduler.clone();
    let stored =
        store_call(move || store.submit_job(&request.job, request.plan_id, &scheduler)).await?;
    Ok((StatusCode::CREATED, Json(stored.into())))
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct JobListResponse {
    jobs: Vec<JobView>,
}

async fn list_jobs(State(state): State<AppState>) -> Result<Json<JobListResponse>, ApiError> {
    let store = state.store.clone();
    let jobs = store_call(move || store.list_jobs(100)).await?;
    Ok(Json(JobListResponse {
        jobs: jobs.into_iter().map(JobView::from).collect(),
    }))
}

async fn get_job(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<Json<JobView>, ApiError> {
    let store = state.store.clone();
    Ok(Json(store_call(move || store.get_job(id)).await?.into()))
}

async fn cancel_job(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    headers: HeaderMap,
) -> Result<Json<JobView>, ApiError> {
    let expected_version = parse_if_match(&headers)?;
    let store = state.store.clone();
    Ok(Json(
        store_call(move || store.cancel_job(id, expected_version))
            .await?
            .into(),
    ))
}

async fn get_job_cleanup(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<Json<CleanupStatusV1>, ApiError> {
    let store = state.store.clone();
    let snapshot = store_call(move || store.get_cleanup_snapshot(id)).await?;
    let stored = snapshot.stored;
    let cleanup = snapshot.cleanup;
    let completion = snapshot.completion;
    let obligation = snapshot.obligation;
    let terminal_ack = completion.map(|completion| TerminalCompletionAckV1 {
        run_id: stored.run.id,
        lease_id: completion.completion.lease_id,
        completion_sha256: completion.sha256,
        state_version: stored.version,
        final_state: stored.run.state,
        acknowledged_at: completion.created_at,
    });
    let release_reason = obligation
        .as_ref()
        .and_then(|obligation| obligation.release_reason);
    let (status, job_root_deleted, relative_root, observed_at, received_at, terminal_ack) =
        if let Some(cleanup) = cleanup {
            let status = cleanup_status_phase(Some(cleanup.receipt.outcome), release_reason);
            (
                status,
                status == CleanupStatusPhaseV1::Removed && cleanup.receipt.job_root_deleted,
                Some(cleanup.receipt.relative_root),
                Some(cleanup.receipt.observed_at),
                Some(cleanup.received_at),
                Some(cleanup.receipt.terminal_ack),
            )
        } else {
            (
                cleanup_status_phase(None, release_reason),
                false,
                Some(format!("jobs/{}", stored.run.id)),
                None,
                None,
                terminal_ack,
            )
        };
    Ok(Json(CleanupStatusV1 {
        api_version: CLEANUP_API_VERSION.to_owned(),
        job_id: stored.job.id,
        run_id: stored.run.id,
        status,
        job_root_deleted,
        relative_root,
        observed_at,
        received_at,
        terminal_ack,
        cleanup_deadline_at: obligation
            .as_ref()
            .map(|obligation| obligation.cleanup_deadline_at),
        reservation_released_at: obligation
            .as_ref()
            .and_then(|obligation| obligation.reservation_released_at),
        release_reason,
        cleanup_failure: obligation.and_then(|obligation| obligation.cleanup_failure),
    }))
}

/// Capacity recovery is not cleanup evidence. A deadline or legacy migration
/// therefore remains `pending` until a real `removed` receipt is durable. A
/// late exact `removed` receipt may still upgrade the evidence phase without
/// rewriting the historical reason the reservation was released.
fn cleanup_status_phase(
    outcome: Option<JobRootCleanupOutcomeV1>,
    release_reason: Option<CleanupReservationReleaseReasonV1>,
) -> CleanupStatusPhaseV1 {
    match outcome {
        Some(JobRootCleanupOutcomeV1::Removed) => CleanupStatusPhaseV1::Removed,
        _ if matches!(
            release_reason,
            Some(
                CleanupReservationReleaseReasonV1::DeadlineRecovery
                    | CleanupReservationReleaseReasonV1::LegacyMigration
            )
        ) =>
        {
            CleanupStatusPhaseV1::Pending
        }
        Some(JobRootCleanupOutcomeV1::NotCreated) => CleanupStatusPhaseV1::NotCreated,
        None => CleanupStatusPhaseV1::Pending,
    }
}

async fn create_pairing(
    State(state): State<AppState>,
    headers: HeaderMap,
    bytes: Bytes,
) -> Result<Response, ApiError> {
    let request: CreatePairingRequestV1 = parse_json_body(&headers, &bytes)?;
    request
        .validate()
        .map_err(|_| ApiError::invalid_request())?;
    let endpoint = state
        .worker_endpoint()
        .cloned()
        .ok_or_else(ApiError::worker_listener_unavailable)?;
    let operation_key = headers
        .get("idempotency-key")
        .map(|value| {
            value
                .to_str()
                .map(str::to_owned)
                .map_err(|_| ApiError::invalid_request())
        })
        .transpose()?;
    let store = state.store.clone();
    let worker_url = endpoint.public_url.clone();
    let certificate_pem = endpoint.certificate_pem.to_string();
    let (pairing, controller_id, worker_url, certificate_pem, replayed) = store_call(move || {
        let (pairing, worker_url, certificate_pem, replayed) =
            if let Some(operation_key) = operation_key {
                let issued = store.create_pairing_idempotent(
                    &operation_key,
                    request.intended_node_id,
                    &worker_url,
                    &certificate_pem,
                )?;
                (
                    issued.pairing,
                    issued.worker_url,
                    issued.certificate_pem,
                    issued.replayed,
                )
            } else {
                (
                    store.create_pairing_for(request.intended_node_id)?,
                    worker_url,
                    certificate_pem,
                    false,
                )
            };
        let controller_id = store.controller_id()?;
        Ok((
            pairing,
            controller_id,
            worker_url,
            certificate_pem,
            replayed,
        ))
    })
    .await?;
    let bundle = EnrollmentBundleV1 {
        api_version: ENROLLMENT_API_VERSION.to_owned(),
        pairing_id: pairing.id,
        controller_id,
        intended_node_id: pairing.intended_node_id,
        worker_url,
        certificate_pem,
        pairing_code: pairing.code.clone(),
        created_at: pairing.created_at,
        expires_at: pairing.expires_at,
    };
    bundle.validate().map_err(|_| ApiError::internal())?;
    let status = if replayed {
        StatusCode::OK
    } else {
        StatusCode::CREATED
    };
    let mut response = (status, Json(bundle)).into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("no-store"));
    Ok(response)
}

async fn get_pairing_status(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<Json<PairingStatusV1>, ApiError> {
    let store = state.store.clone();
    let stored = store_call(move || store.get_pairing_status(id)).await?;
    let error = if matches!(stored.phase, PairingPhaseV1::Failed) {
        Some(canonical_pairing_error(
            stored.failure_code.ok_or_else(ApiError::internal)?,
        ))
    } else {
        None
    };
    let status = PairingStatusV1 {
        api_version: ENROLLMENT_API_VERSION.to_owned(),
        pairing_id: stored.pairing_id,
        intended_node_id: stored.intended_node_id,
        node_id: stored.node_id,
        phase: stored.phase,
        created_at: stored.created_at,
        expires_at: stored.expires_at,
        consumed_at: stored.consumed_at,
        revoked_at: stored.revoked_at,
        ready: matches!(stored.phase, PairingPhaseV1::Ready),
        error,
    };
    status.validate().map_err(|_| ApiError::internal())?;
    Ok(Json(status))
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PairingFailureRequest {
    code: PairingFailureCodeV1,
}

async fn report_pairing_failure(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    headers: HeaderMap,
    bytes: Bytes,
) -> Result<StatusCode, ApiError> {
    let request: PairingFailureRequest = parse_json_body(&headers, &bytes)?;
    let store = state.store.clone();
    store_call(move || store.fail_pairing(id, request.code)).await?;
    Ok(StatusCode::NO_CONTENT)
}

fn canonical_pairing_error(code: PairingFailureCodeV1) -> PairingStatusErrorV1 {
    let message = match code {
        PairingFailureCodeV1::ProvisioningFailed => {
            "Provisioning stopped before enrollment completed."
        }
        PairingFailureCodeV1::WorkerInstallFailed => {
            "Worker installation failed before enrollment completed."
        }
        PairingFailureCodeV1::WorkerPairingFailed => {
            "The worker could not complete controller pairing."
        }
        PairingFailureCodeV1::WorkerHealthCheckFailed => {
            "The worker did not pass its health check."
        }
    };
    PairingStatusErrorV1 {
        code,
        message: message.to_owned(),
        retryable: false,
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RevokePairingResponse {
    pairing_id: Uuid,
    revoked: bool,
}

async fn revoke_pairing(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<Json<RevokePairingResponse>, ApiError> {
    let store = state.store.clone();
    store_call(move || store.revoke_pairing(id)).await?;
    Ok(Json(RevokePairingResponse {
        pairing_id: id,
        revoked: true,
    }))
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct LogChunkView {
    run_id: Uuid,
    stream: String,
    offset: u64,
    length: u64,
    sha256: String,
    created_at: DateTime<Utc>,
}

impl From<LogChunk> for LogChunkView {
    fn from(value: LogChunk) -> Self {
        Self {
            run_id: value.run_id,
            stream: value.stream,
            offset: value.offset,
            length: value.length,
            sha256: value.sha256,
            created_at: value.created_at,
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct JobLogsResponse {
    chunks: Vec<LogChunkView>,
}

async fn list_job_logs(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<Json<JobLogsResponse>, ApiError> {
    let store = state.store.clone();
    let chunks = store_call(move || store.list_log_chunks(id)).await?;
    Ok(Json(JobLogsResponse {
        chunks: chunks.into_iter().map(Into::into).collect(),
    }))
}

async fn download_job_log(
    State(state): State<AppState>,
    Path((id, stream)): Path<(Uuid, String)>,
) -> Result<Response, ApiError> {
    let store = state.store.clone();
    let bytes = store_call(move || store.read_log(id, &stream)).await?;
    Ok((
        [(
            CONTENT_TYPE,
            HeaderValue::from_static("text/plain; charset=utf-8"),
        )],
        bytes,
    )
        .into_response())
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ArtifactView {
    id: Uuid,
    run_id: Uuid,
    name: String,
    size: u64,
    sha256: String,
    created_at: DateTime<Utc>,
}

impl From<StoredArtifact> for ArtifactView {
    fn from(value: StoredArtifact) -> Self {
        Self {
            id: value.id,
            run_id: value.run_id,
            name: value.name,
            size: value.size,
            sha256: value.sha256,
            created_at: value.created_at,
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct JobArtifactsResponse {
    artifacts: Vec<ArtifactView>,
}

async fn list_job_artifacts(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<Json<JobArtifactsResponse>, ApiError> {
    let store = state.store.clone();
    let artifacts = store_call(move || store.list_artifacts(id)).await?;
    Ok(Json(JobArtifactsResponse {
        artifacts: artifacts.into_iter().map(Into::into).collect(),
    }))
}

async fn download_job_artifact(
    State(state): State<AppState>,
    Path((id, artifact_id)): Path<(Uuid, Uuid)>,
) -> Result<Response, ApiError> {
    let store = state.store.clone();
    let (metadata, bytes) = store_call(move || store.read_artifact(id, artifact_id)).await?;
    let disposition = HeaderValue::from_str(&format!("attachment; filename=\"{}\"", metadata.id))
        .map_err(|_| ApiError::internal())?;
    let mut response = bytes.into_response();
    response.headers_mut().insert(
        CONTENT_TYPE,
        HeaderValue::from_static("application/octet-stream"),
    );
    response
        .headers_mut()
        .insert(CONTENT_DISPOSITION, disposition);
    Ok(response)
}

fn parse_json_body<T: DeserializeOwned>(headers: &HeaderMap, bytes: &[u8]) -> Result<T, ApiError> {
    let content_type = headers
        .get(CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(';').next())
        .map(str::trim);
    if !content_type.is_some_and(|value| value.eq_ignore_ascii_case("application/json")) {
        return Err(ApiError::unsupported_media_type());
    }
    serde_json::from_slice(bytes).map_err(|_| ApiError::invalid_request())
}

fn parse_if_match(headers: &HeaderMap) -> Result<Option<u64>, ApiError> {
    let Some(value) = headers.get("if-match") else {
        return Ok(None);
    };
    let value = value
        .to_str()
        .map_err(|_| ApiError::invalid_version())?
        .trim();
    let value = value
        .strip_prefix('"')
        .and_then(|value| value.strip_suffix('"'))
        .unwrap_or(value);
    value
        .parse::<u64>()
        .map(Some)
        .map_err(|_| ApiError::invalid_version())
}

async fn store_call<T, F>(operation: F) -> Result<T, ApiError>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, StoreError> + Send + 'static,
{
    tokio::task::spawn_blocking(operation)
        .await
        .map_err(|_| ApiError::internal())?
        .map_err(ApiError::from)
}

#[derive(Debug)]
struct ApiError {
    status: StatusCode,
    code: &'static str,
    message: &'static str,
    extra: Option<(&'static str, Value)>,
}

impl ApiError {
    fn new(status: StatusCode, code: &'static str, message: &'static str) -> Self {
        Self {
            status,
            code,
            message,
            extra: None,
        }
    }

    fn invalid_request() -> Self {
        Self::new(
            StatusCode::BAD_REQUEST,
            "invalid_request",
            "request body is invalid",
        )
    }

    fn unsupported_media_type() -> Self {
        Self::new(
            StatusCode::UNSUPPORTED_MEDIA_TYPE,
            "json_content_type_required",
            "Content-Type must be application/json",
        )
    }

    fn snapshot_content_type() -> Self {
        Self::new(
            StatusCode::UNSUPPORTED_MEDIA_TYPE,
            "snapshot_content_type_required",
            "Content-Type must identify a cyc tar.zst snapshot archive",
        )
    }

    fn invalid_snapshot() -> Self {
        Self::new(
            StatusCode::BAD_REQUEST,
            "invalid_snapshot",
            "snapshot path, size, or archive metadata is invalid",
        )
    }

    fn snapshot_too_large() -> Self {
        Self::new(
            StatusCode::PAYLOAD_TOO_LARGE,
            "snapshot_too_large",
            "snapshot archive exceeds the controller limit",
        )
    }

    fn invalid_version() -> Self {
        Self::new(
            StatusCode::BAD_REQUEST,
            "invalid_version",
            "If-Match must contain a numeric job version",
        )
    }

    fn invalid_job() -> Self {
        Self::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "invalid_job",
            "job validation failed",
        )
    }

    fn worker_listener_unavailable() -> Self {
        Self::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "worker_listener_unavailable",
            "the managed worker TLS listener is not configured",
        )
    }

    fn schedule(error: ScheduleError) -> Self {
        match error {
            ScheduleError::InvalidJob(_) => Self::invalid_job(),
            ScheduleError::NoEligibleNodes { explanation } => Self {
                status: StatusCode::CONFLICT,
                code: "no_eligible_node",
                message: "no compatible fresh worker is currently available",
                extra: serde_json::to_value(explanation)
                    .ok()
                    .map(|value| ("placement", value)),
            },
        }
    }

    fn internal() -> Self {
        Self::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "internal_error",
            "controller operation failed",
        )
    }
}

impl From<StoreError> for ApiError {
    fn from(error: StoreError) -> Self {
        match error {
            StoreError::NotFound => Self::new(
                StatusCode::NOT_FOUND,
                "not_found",
                "requested resource was not found",
            ),
            StoreError::Conflict => {
                Self::new(StatusCode::CONFLICT, "conflict", "job already exists")
            }
            StoreError::InvalidTransition => Self::new(
                StatusCode::CONFLICT,
                "invalid_state_transition",
                "job cannot be cancelled from its current state",
            ),
            StoreError::CancellationPending => Self::new(
                StatusCode::CONFLICT,
                "cancellation_pending",
                "run must acknowledge cancellation as cancelled or failed",
            ),
            StoreError::InvalidRunEvidence => Self::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "invalid_run_evidence",
                "terminal run evidence is missing or inconsistent",
            ),
            StoreError::InvalidNodeReport => Self::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "invalid_node_report",
                "node inventory or telemetry is invalid",
            ),
            StoreError::VersionConflict { current_version } => Self {
                status: StatusCode::CONFLICT,
                code: "version_conflict",
                message: "job version changed; reload before retrying",
                extra: Some(("details", json!({ "currentVersion": current_version }))),
            },
            StoreError::NodeConfigVersionConflict { current_revision } => Self {
                status: StatusCode::CONFLICT,
                code: "node_config_conflict",
                message: "node config revision changed; reload before retrying",
                extra: Some(("details", json!({ "currentRevision": current_revision }))),
            },
            StoreError::WorkerStateConflict {
                current_version,
                cancel_requested,
                current_state,
            } => Self {
                status: StatusCode::CONFLICT,
                code: "state_conflict",
                message: "worker run state changed",
                extra: Some((
                    "details",
                    json!({
                        "currentVersion": current_version,
                        "cancelRequested": cancel_requested,
                        "currentState": current_state,
                    }),
                )),
            },
            StoreError::PlanExpired => Self::new(
                StatusCode::CONFLICT,
                "plan_expired",
                "placement plan expired; create a new plan",
            ),
            StoreError::PlanStale => Self::new(
                StatusCode::CONFLICT,
                "plan_stale",
                "fleet or policy state changed; create a new plan",
            ),
            StoreError::PlanDigestMismatch => Self::new(
                StatusCode::CONFLICT,
                "plan_digest_mismatch",
                "placement plan does not match this canonical JobSpec",
            ),
            StoreError::Schedule(error) => Self::schedule(error),
            StoreError::WorkerUnauthorized | StoreError::RunUnauthorized => Self::new(
                StatusCode::UNAUTHORIZED,
                "unauthorized",
                "worker authentication failed",
            ),
            StoreError::PairingUnavailable => Self::new(
                StatusCode::GONE,
                "pairing_unavailable",
                "pairing code is expired, used, or revoked",
            ),
            StoreError::PairingBindingMismatch => Self::new(
                StatusCode::CONFLICT,
                "pairing_binding_mismatch",
                "pairing request does not match its consumed binding",
            ),
            StoreError::InvalidCredentialDigest => Self::new(
                StatusCode::BAD_REQUEST,
                "invalid_credential_digest",
                "credential digest is invalid",
            ),
            StoreError::PairingAcknowledgementUnavailable => Self::new(
                StatusCode::UNAUTHORIZED,
                "pairing_ack_unauthorized",
                "pairing acknowledgement authentication failed",
            ),
            StoreError::InvalidPairingOperationKey => Self::new(
                StatusCode::BAD_REQUEST,
                "invalid_idempotency_key",
                "Idempotency-Key must be 1-128 portable ASCII characters",
            ),
            StoreError::PairingIdempotencyMismatch => Self::new(
                StatusCode::CONFLICT,
                "idempotency_request_mismatch",
                "Idempotency-Key was already used with a different pairing request",
            ),
            StoreError::PairingIdempotencyFinalized { phase } => Self {
                status: StatusCode::CONFLICT,
                code: "idempotency_operation_finalized",
                message: "the original pairing operation is no longer pending",
                extra: Some(("details", json!({ "phase": phase }))),
            },
            StoreError::PairingFailureMismatch => Self::new(
                StatusCode::CONFLICT,
                "pairing_failure_mismatch",
                "pairing already has a different immutable failure code",
            ),
            StoreError::PairingFailureFinalized { phase } => Self {
                status: StatusCode::CONFLICT,
                code: "pairing_failure_finalized",
                message: "pairing can no longer transition to failed",
                extra: Some(("details", json!({ "phase": phase }))),
            },
            StoreError::UploadConflict => Self::new(
                StatusCode::CONFLICT,
                "upload_conflict",
                "upload conflicts with an existing object",
            ),
            StoreError::UploadOffset => Self::new(
                StatusCode::CONFLICT,
                "upload_offset",
                "log chunk offset is not contiguous",
            ),
            StoreError::DigestMismatch => Self::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "digest_mismatch",
                "uploaded bytes do not match the declared digest",
            ),
            StoreError::InvalidUpload => Self::new(
                StatusCode::BAD_REQUEST,
                "invalid_upload",
                "upload metadata is invalid",
            ),
            StoreError::LogQuotaExceeded => Self::new(
                StatusCode::PAYLOAD_TOO_LARGE,
                "log_quota_exceeded",
                "run log quota is exhausted",
            ),
            StoreError::ArtifactQuotaExceeded => Self::new(
                StatusCode::PAYLOAD_TOO_LARGE,
                "artifact_quota_exceeded",
                "run artifact quota is exhausted",
            ),
            StoreError::SnapshotQuotaExceeded => Self::snapshot_too_large(),
            StoreError::InvalidCleanupReceipt => Self::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "invalid_cleanup_receipt",
                "cleanup receipt does not match the terminal acknowledgement",
            ),
            StoreError::CleanupConflict => Self::new(
                StatusCode::CONFLICT,
                "cleanup_conflict",
                "cleanup receipt conflicts with immutable stored evidence",
            ),
            StoreError::InvalidManagedNode => Self::new(
                StatusCode::BAD_REQUEST,
                "invalid_managed_node",
                "pairing requires a managed worker node",
            ),
            StoreError::InvalidNodeConfig => Self::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "invalid_node_config",
                "node config or reserved policy labels are invalid",
            ),
            StoreError::StorageSecurity(_)
            | StoreError::Database(_)
            | StoreError::Document(_)
            | StoreError::NodeState(_)
            | StoreError::NodeIdentityMismatch
            | StoreError::InvalidPlanBinding
            | StoreError::InvalidFleetRevision
            | StoreError::InvalidPairingFailureState
            | StoreError::Identifier(_)
            | StoreError::Timestamp
            | StoreError::Poisoned
            | StoreError::Io(_) => {
                tracing::error!(error = %error, "controller storage failure");
                Self::internal()
            }
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let mut error = json!({
            "code": self.code,
            "message": self.message,
        });
        if let Some((key, value)) = self.extra {
            error[key] = value;
        }
        (self.status, Json(json!({ "error": error }))).into_response()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::{Method, Request};
    use cyc_protocol::{
        Architecture, CredentialRef, JobKind, JobStep, NodeResources, NodeStatus, NodeTransport,
        OperatingSystem, SourceSpec,
    };
    use http_body_util::BodyExt;
    use tower::ServiceExt;

    const TEST_TOKEN: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    fn test_app() -> Router {
        router(AppState::new(
            Store::in_memory().unwrap(),
            AuthToken::test_token(),
            47_831,
        ))
    }

    fn request(method: Method, uri: &str) -> axum::http::request::Builder {
        Request::builder()
            .method(method)
            .uri(uri)
            .header(HOST, "127.0.0.1:47831")
            .header(AUTHORIZATION, format!("Bearer {TEST_TOKEN}"))
    }

    fn online_node() -> Node {
        let mut node = Node::new(
            "windows-worker",
            NodeTransport::Managed {
                endpoint: "https://controller.example:47832".to_owned(),
                credential_ref: CredentialRef::new("controller-db:managed-worker"),
            },
            OperatingSystem::Windows,
            Architecture::X86_64,
        );
        node.status = NodeStatus::Online;
        node.resources = NodeResources {
            logical_cpu_cores: 16,
            available_cpu_cores: 12,
            memory_mib: 32_768,
            available_memory_mib: 24_576,
            disk_mib: 500_000,
            available_disk_mib: 400_000,
            gpus: Vec::new(),
        };
        node
    }

    fn worker_credential() -> String {
        format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple())
    }

    fn credential_digest(credential: &str) -> String {
        use sha2::{Digest, Sha256};
        Sha256::digest(credential.as_bytes())
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect()
    }

    fn pair_store_worker(
        store: &Store,
        pairing: &crate::store::PairingSecret,
        node: &Node,
    ) -> String {
        let credential = worker_credential();
        let digest = credential_digest(&credential);
        store
            .consume_pairing(
                &pairing.code,
                pairing.id,
                pairing.intended_node_id,
                &digest,
                node,
            )
            .unwrap();
        store
            .acknowledge_pairing(&credential, pairing.id, pairing.intended_node_id, &digest)
            .unwrap();
        credential
    }

    fn build_job() -> JobSpec {
        JobSpec::new(
            JobKind::Build,
            SourceSpec::Git {
                repository: "https://example.invalid/repository.git".to_owned(),
                revision: "0123456789abcdef0123456789abcdef01234567".to_owned(),
            },
            vec![JobStep::new("build", "cargo build --locked")],
        )
    }

    async fn body_json(response: Response) -> Value {
        let body = response.into_body().collect().await.unwrap().to_bytes();
        serde_json::from_slice(&body).unwrap()
    }

    #[tokio::test]
    async fn health_is_unauthenticated_but_requires_loopback_host() {
        let response = test_app()
            .oneshot(
                Request::builder()
                    .uri("/v1/health")
                    .header(HOST, "127.0.0.1:47831")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);

        let response = test_app()
            .oneshot(
                Request::builder()
                    .uri("/v1/health")
                    .header(HOST, "attacker.example:47831")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    async fn protected_routes_require_token_and_reject_foreign_origin() {
        let response = test_app()
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/v1/fleet")
                    .header(HOST, "127.0.0.1:47831")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
        assert_eq!(response.headers()[WWW_AUTHENTICATE], "Bearer");

        let response = test_app()
            .oneshot(
                request(Method::GET, "/v1/fleet")
                    .header(ORIGIN, "https://attacker.example")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::FORBIDDEN);
    }

    #[tokio::test]
    async fn fleet_exposes_one_javascript_safe_revisioned_snapshot() {
        let store = Store::in_memory().unwrap();
        let node = online_node();
        store.upsert_node(&node).unwrap();
        let app = router(AppState::new(store, AuthToken::test_token(), 47_831));
        let response = app
            .oneshot(
                request(Method::GET, "/v1/fleet")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let fleet = body_json(response).await;
        let revision = fleet["fleetRevision"].as_u64().unwrap();
        assert!(revision <= cyc_protocol::worker::MAX_SAFE_JSON_INTEGER);
        assert!(DateTime::parse_from_rfc3339(fleet["observedAt"].as_str().unwrap()).is_ok());
        assert_eq!(fleet["nodes"].as_array().unwrap().len(), 1);
        assert_eq!(fleet["nodeViews"].as_array().unwrap().len(), 1);
        assert_eq!(fleet["nodes"][0]["id"], fleet["nodeViews"][0]["nodeId"]);
    }

    #[test]
    fn capacity_recovery_never_masquerades_as_workspace_cleanup() {
        assert_eq!(
            cleanup_status_phase(
                Some(JobRootCleanupOutcomeV1::NotCreated),
                Some(CleanupReservationReleaseReasonV1::DeadlineRecovery),
            ),
            CleanupStatusPhaseV1::Pending
        );
        assert_eq!(
            cleanup_status_phase(
                None,
                Some(CleanupReservationReleaseReasonV1::LegacyMigration),
            ),
            CleanupStatusPhaseV1::Pending
        );
        assert_eq!(
            cleanup_status_phase(Some(JobRootCleanupOutcomeV1::NotCreated), None),
            CleanupStatusPhaseV1::NotCreated
        );
        assert_eq!(
            cleanup_status_phase(
                Some(JobRootCleanupOutcomeV1::Removed),
                Some(CleanupReservationReleaseReasonV1::DeadlineRecovery),
            ),
            CleanupStatusPhaseV1::Removed
        );
    }

    #[tokio::test]
    async fn json_posts_require_exact_media_type() {
        let response = test_app()
            .oneshot(
                request(Method::POST, "/v1/jobs")
                    .body(Body::from("{}"))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::UNSUPPORTED_MEDIA_TYPE);
    }

    #[tokio::test]
    async fn malformed_requests_do_not_reflect_secrets() {
        let marker = "correct-horse-battery-staple";
        let response = test_app()
            .oneshot(
                request(Method::POST, "/v1/jobs")
                    .header(CONTENT_TYPE, "application/json; charset=utf-8")
                    .body(Body::from(format!(r#"{{"password":"{marker}"}}"#)))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        let text = body_json(response).await.to_string();
        assert!(!text.contains(marker));
        assert!(!text.to_ascii_lowercase().contains("password"));
    }

    #[tokio::test]
    async fn snapshot_upload_is_content_addressed_idempotent_and_bounded() {
        use sha2::{Digest, Sha256};

        let store = Store::in_memory().unwrap();
        let app = router(AppState::new(store, AuthToken::test_token(), 47_831));
        let archive = b"bounded raw tar.zst bytes";
        let sha256 = Sha256::digest(archive)
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        let uri = format!("/v1/snapshots/{sha256}");
        for _ in 0..2 {
            let response = app
                .clone()
                .oneshot(
                    request(Method::PUT, &uri)
                        .header(CONTENT_TYPE, SNAPSHOT_MEDIA_TYPE)
                        .header(CONTENT_LENGTH, archive.len())
                        .body(Body::from(archive.as_slice()))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::CREATED);
            let metadata: SnapshotMetadataV1 =
                serde_json::from_value(body_json(response).await).unwrap();
            metadata.validate().unwrap();
            assert_eq!(metadata.digest, format!("sha256:{sha256}"));
            assert_eq!(metadata.size_bytes, archive.len() as u64);
        }

        let response = app
            .clone()
            .oneshot(request(Method::HEAD, &uri).body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response.headers()[CONTENT_LENGTH],
            archive.len().to_string()
        );
        assert_eq!(response.headers()[ETAG], format!("\"sha256:{sha256}\""));
        assert_eq!(response.headers()[CONTENT_TYPE], SNAPSHOT_MEDIA_TYPE);
        assert!(response
            .into_body()
            .collect()
            .await
            .unwrap()
            .to_bytes()
            .is_empty());

        let response = app
            .clone()
            .oneshot(
                request(Method::PUT, &format!("/v1/snapshots/{}", "f".repeat(64)))
                    .header(CONTENT_TYPE, SNAPSHOT_MEDIA_TYPE)
                    .header(CONTENT_LENGTH, archive.len())
                    .body(Body::from(archive.as_slice()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);

        let response = app
            .oneshot(
                request(Method::PUT, &format!("/v1/snapshots/{}", "e".repeat(64)))
                    .header(CONTENT_TYPE, SNAPSHOT_MEDIA_TYPE)
                    .header(CONTENT_LENGTH, MAX_SNAPSHOT_ARCHIVE_BYTES + 1)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::PAYLOAD_TOO_LARGE);
    }

    #[tokio::test]
    async fn pairing_bundle_is_available_only_with_a_tls_worker_endpoint() {
        let response = test_app()
            .oneshot(
                request(Method::POST, "/v1/pairings")
                    .header(CONTENT_TYPE, "application/json")
                    .body(Body::from("{}"))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);

        let store = Store::in_memory().unwrap();
        let state = AppState::new(store.clone(), AuthToken::test_token(), 47_831)
            .with_worker_endpoint(
                "https://192.0.2.10:47832".to_owned(),
                "-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----\n".to_owned(),
            );
        let expected_controller_id = state.store.controller_id().unwrap();
        let app = router(state);
        let intended_node_id = Uuid::new_v4();
        let response = app
            .clone()
            .oneshot(
                request(Method::POST, "/v1/pairings")
                    .header(CONTENT_TYPE, "application/json")
                    .body(Body::from(
                        serde_json::to_vec(&json!({
                            "intendedNodeId": intended_node_id,
                        }))
                        .unwrap(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::CREATED);
        assert_eq!(response.headers()[CACHE_CONTROL], "no-store");
        let bundle = body_json(response).await;
        assert_eq!(bundle["apiVersion"], ENROLLMENT_API_VERSION);
        assert_eq!(
            bundle["controllerId"],
            Value::String(expected_controller_id.to_string())
        );
        assert_eq!(bundle["intendedNodeId"], intended_node_id.to_string());
        assert_eq!(bundle["workerUrl"], "https://192.0.2.10:47832");
        assert_eq!(
            bundle["certificatePem"],
            "-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----\n"
        );
        assert!(bundle["pairingCode"].as_str().unwrap().len() >= 32);

        let pairing_id = Uuid::parse_str(bundle["pairingId"].as_str().unwrap()).unwrap();
        let response = app
            .clone()
            .oneshot(
                request(Method::GET, &format!("/v1/pairings/{pairing_id}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let pending = body_json(response).await;
        assert_eq!(pending["phase"], "pending");
        assert_eq!(pending["ready"], false);
        assert!(pending.get("pairingCode").is_none());

        let mut node = online_node();
        node.id = intended_node_id;
        let credential = worker_credential();
        let digest = credential_digest(&credential);
        let paired = store
            .consume_pairing(
                bundle["pairingCode"].as_str().unwrap(),
                pairing_id,
                intended_node_id,
                &digest,
                &node,
            )
            .unwrap();
        assert_eq!(paired.node_id, intended_node_id);
        let response = app
            .clone()
            .oneshot(
                request(Method::GET, &format!("/v1/pairings/{pairing_id}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let consumed = body_json(response).await;
        assert_eq!(consumed["phase"], "consumed");
        assert_eq!(consumed["ready"], false);
        store
            .acknowledge_pairing(&credential, pairing_id, intended_node_id, &digest)
            .unwrap();
        let response = app
            .oneshot(
                request(Method::GET, &format!("/v1/pairings/{pairing_id}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let ready = body_json(response).await;
        assert_eq!(ready["phase"], "ready");
        assert_eq!(ready["ready"], true);
        assert_eq!(ready["nodeId"], intended_node_id.to_string());
        assert!(ready.get("pairingCode").is_none());
    }

    #[tokio::test]
    async fn pairing_create_idempotency_replays_exact_pending_bundle() {
        let store = Store::in_memory().unwrap();
        let app = router(
            AppState::new(store.clone(), AuthToken::test_token(), 47_831).with_worker_endpoint(
                "https://192.0.2.10:47832".to_owned(),
                "-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----\n".to_owned(),
            ),
        );
        let intended = Uuid::new_v4();
        let operation = "desktop-operation:00000000-0000-4000-8000-000000000001";
        let body = serde_json::to_vec(&json!({ "intendedNodeId": intended })).unwrap();
        let issue = || {
            request(Method::POST, "/v1/pairings")
                .header(CONTENT_TYPE, "application/json")
                .header("idempotency-key", operation)
                .body(Body::from(body.clone()))
                .unwrap()
        };

        let first = app.clone().oneshot(issue()).await.unwrap();
        assert_eq!(first.status(), StatusCode::CREATED);
        assert_eq!(first.headers()[CACHE_CONTROL], "no-store");
        let first = body_json(first).await;
        let retry = app.clone().oneshot(issue()).await.unwrap();
        assert_eq!(retry.status(), StatusCode::OK);
        assert_eq!(retry.headers()[CACHE_CONTROL], "no-store");
        let retry = body_json(retry).await;
        assert_eq!(retry, first);

        let mismatch = app
            .clone()
            .oneshot(
                request(Method::POST, "/v1/pairings")
                    .header(CONTENT_TYPE, "application/json")
                    .header("idempotency-key", operation)
                    .body(Body::from("{}"))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(mismatch.status(), StatusCode::CONFLICT);
        assert_eq!(
            body_json(mismatch).await["error"]["code"],
            "idempotency_request_mismatch"
        );

        let pairing_id = Uuid::parse_str(first["pairingId"].as_str().unwrap()).unwrap();
        store.revoke_pairing(pairing_id).unwrap();
        let finalized = app.oneshot(issue()).await.unwrap();
        assert_eq!(finalized.status(), StatusCode::CONFLICT);
        let finalized = body_json(finalized).await;
        assert_eq!(
            finalized["error"]["code"],
            "idempotency_operation_finalized"
        );
        assert_eq!(finalized["error"]["details"]["phase"], "revoked");
    }

    #[tokio::test]
    async fn pairing_failure_endpoint_is_owner_authenticated_strict_and_non_secret() {
        let store = Store::in_memory().unwrap();
        let pairing = store.create_pairing().unwrap();
        let pairing_id = pairing.id;
        let pairing_code = pairing.code.clone();
        let app = router(AppState::new(
            store.clone(),
            AuthToken::test_token(),
            47_831,
        ));
        let path = format!("/v1/pairings/{pairing_id}/failure");
        let valid_body = Body::from(r#"{"code":"worker_install_failed"}"#);

        let unauthorized = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(Method::PUT)
                    .uri(&path)
                    .header(HOST, "127.0.0.1:47831")
                    .header(CONTENT_TYPE, "application/json")
                    .body(valid_body)
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(unauthorized.status(), StatusCode::UNAUTHORIZED);

        let marker = "failure-diagnostic-secret-marker";
        let rejected = app
            .clone()
            .oneshot(
                request(Method::PUT, &path)
                    .header(CONTENT_TYPE, "application/json")
                    .body(Body::from(
                        serde_json::to_vec(&json!({
                            "code": "worker_install_failed",
                            "diagnostic": marker,
                        }))
                        .unwrap(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(rejected.status(), StatusCode::BAD_REQUEST);
        let rejected = body_json(rejected).await.to_string();
        assert!(!rejected.contains(marker));
        assert!(!rejected.contains("diagnostic"));

        for _ in 0..2 {
            let response = app
                .clone()
                .oneshot(
                    request(Method::PUT, &path)
                        .header(CONTENT_TYPE, "application/json")
                        .body(Body::from(r#"{"code":"worker_install_failed"}"#))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::NO_CONTENT);
            assert!(response
                .into_body()
                .collect()
                .await
                .unwrap()
                .to_bytes()
                .is_empty());
        }

        let conflict = app
            .clone()
            .oneshot(
                request(Method::PUT, &path)
                    .header(CONTENT_TYPE, "application/json")
                    .body(Body::from(r#"{"code":"worker_pairing_failed"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(conflict.status(), StatusCode::CONFLICT);
        assert_eq!(
            body_json(conflict).await["error"]["code"],
            "pairing_failure_mismatch"
        );

        let failed = app
            .clone()
            .oneshot(
                request(Method::GET, &format!("/v1/pairings/{pairing_id}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(failed.status(), StatusCode::OK);
        let failed = body_json(failed).await;
        assert_eq!(failed["phase"], "failed");
        assert_eq!(failed["ready"], false);
        assert_eq!(failed["error"]["code"], "worker_install_failed");
        assert_eq!(
            failed["error"]["message"],
            "Worker installation failed before enrollment completed."
        );
        assert_eq!(failed["error"]["retryable"], false);
        let failed_text = failed.to_string();
        assert!(!failed_text.contains(&pairing_code));
        assert!(!failed_text.contains(marker));
        assert!(failed.get("pairingCode").is_none());
        assert!(failed.get("failedAt").is_none());

        let revoked = app
            .clone()
            .oneshot(
                request(Method::POST, &format!("/v1/pairings/{pairing_id}/revoke"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(revoked.status(), StatusCode::OK);
        let status = app
            .oneshot(
                request(Method::GET, &format!("/v1/pairings/{pairing_id}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let status = body_json(status).await;
        assert_eq!(status["phase"], "revoked");
        assert!(status.get("error").is_none());
    }

    #[tokio::test]
    async fn pairing_failure_storage_corruption_maps_to_generic_internal_error() {
        let response = ApiError::from(StoreError::InvalidPairingFailureState).into_response();
        assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
        let body = body_json(response).await;
        assert_eq!(body["error"]["code"], "internal_error");
        assert_eq!(body["error"]["message"], "controller operation failed");
        assert!(!body.to_string().contains("failure state"));
    }

    #[test]
    fn pairing_failure_messages_are_canonical_terminal_and_bounded() {
        let cases = [
            (
                PairingFailureCodeV1::ProvisioningFailed,
                "Provisioning stopped before enrollment completed.",
            ),
            (
                PairingFailureCodeV1::WorkerInstallFailed,
                "Worker installation failed before enrollment completed.",
            ),
            (
                PairingFailureCodeV1::WorkerPairingFailed,
                "The worker could not complete controller pairing.",
            ),
            (
                PairingFailureCodeV1::WorkerHealthCheckFailed,
                "The worker did not pass its health check.",
            ),
        ];
        for (code, message) in cases {
            let error = canonical_pairing_error(code);
            assert_eq!(error.code, code);
            assert_eq!(error.message, message);
            assert!(!error.retryable);
            error.validate().unwrap();
        }
    }

    #[tokio::test]
    async fn node_config_get_put_uses_strict_cas_and_policy_labels() {
        let store = Store::in_memory().unwrap();
        let node = online_node();
        let pairing = store.create_pairing_for(Some(node.id)).unwrap();
        pair_store_worker(&store, &pairing, &node);
        let app = router(AppState::new(store, AuthToken::test_token(), 47_831));
        let path = format!("/v1/nodes/{}/config", node.id);
        let response = app
            .clone()
            .oneshot(request(Method::GET, &path).body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let initial = body_json(response).await;
        assert_eq!(initial["apiVersion"], NODE_CONFIG_API_VERSION);
        assert_eq!(initial["revision"], 0);

        let mut config = initial["config"].clone();
        config["priority"] = json!(900);
        config["labels"] = json!({
            "cyc.policy.allowedJobKinds": "build,test",
            "cyc.policy.resource": "{\"cpuLimitPercent\":80,\"maximumParallelJobs\":2,\"memoryLimitBytes\":null}",
            "cyc.policy.battery": "{\"allowOnBattery\":false}"
        });
        let update = json!({ "expectedRevision": 0, "config": config });
        let response = app
            .clone()
            .oneshot(
                request(Method::PUT, &path)
                    .header(CONTENT_TYPE, "application/json")
                    .body(Body::from(serde_json::to_vec(&update).unwrap()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let updated = body_json(response).await;
        assert_eq!(updated["revision"], 1);
        assert_eq!(updated["config"]["priority"], 900);

        let response = app
            .oneshot(
                request(Method::PUT, &path)
                    .header(CONTENT_TYPE, "application/json")
                    .body(Body::from(serde_json::to_vec(&update).unwrap()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::CONFLICT);
        let conflict = body_json(response).await;
        assert_eq!(conflict["error"]["code"], "node_config_conflict");
        assert_eq!(conflict["error"]["details"]["currentRevision"], 1);
    }

    #[tokio::test]
    async fn planning_failure_keeps_structured_placement() {
        let job = build_job();
        let response = test_app()
            .oneshot(
                request(Method::POST, "/v1/plans")
                    .header(CONTENT_TYPE, "application/json")
                    .body(Body::from(
                        serde_json::to_vec(&json!({ "job": job })).unwrap(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::CONFLICT);
        let value = body_json(response).await;
        assert_eq!(value["error"]["code"], "no_eligible_node");
        assert_eq!(value["error"]["placement"]["policy"], "balanced");
        assert_eq!(
            value["error"]["placement"]["candidates"]
                .as_array()
                .unwrap()
                .len(),
            0
        );
    }

    #[tokio::test]
    async fn only_paired_workers_can_be_planned_submitted_and_cancelled() {
        let store = Store::in_memory().unwrap();
        let app = router(AppState::new(
            store.clone(),
            AuthToken::test_token(),
            47_831,
        ));
        let node = online_node();
        let response = app
            .clone()
            .oneshot(
                request(Method::POST, "/v1/nodes")
                    .header(CONTENT_TYPE, "application/json")
                    .body(Body::from(
                        serde_json::to_vec(&json!({ "node": node })).unwrap(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NOT_FOUND);
        assert!(store.list_nodes().unwrap().is_empty());

        let pairing = store.create_pairing_for(Some(node.id)).unwrap();
        let credential = pair_store_worker(&store, &pairing, &node);
        // Enrollment proves pairing only. An authenticated daemon poll is the
        // first liveness signal that makes the node eligible for placement.
        assert!(store.claim_job(&credential, &node).unwrap().is_none());

        let job = build_job();
        let response = app
            .clone()
            .oneshot(
                request(Method::POST, "/v1/plans")
                    .header(CONTENT_TYPE, "application/json")
                    .body(Body::from(
                        serde_json::to_vec(&json!({ "job": job })).unwrap(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let plan = body_json(response).await;
        assert_eq!(
            plan["apiVersion"],
            cyc_protocol::PLACEMENT_PLAN_BINDING_API_VERSION
        );
        assert_eq!(plan["jobDigest"].as_str().unwrap().len(), 64);

        let response = app
            .clone()
            .oneshot(
                request(Method::POST, "/v1/jobs")
                    .header(CONTENT_TYPE, "application/json")
                    .body(Body::from(
                        serde_json::to_vec(&json!({
                            "job": job,
                            "planId": plan["planId"],
                        }))
                        .unwrap(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::CREATED);
        let submitted = body_json(response).await;
        assert_eq!(submitted["run"]["nodeId"], node.id.to_string());
        assert_eq!(submitted["version"], 0);
        assert_eq!(submitted["cancelRequested"], false);
        assert_eq!(submitted["planBinding"], plan);

        let response = app
            .clone()
            .oneshot(
                request(Method::GET, &format!("/v1/jobs/{}", job.id))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(body_json(response).await["planBinding"], plan);

        let response = app
            .clone()
            .oneshot(
                request(Method::GET, "/v1/jobs")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(body_json(response).await["jobs"][0]["planBinding"], plan);

        let run_id = submitted["run"]["id"].as_str().unwrap();
        let response = app
            .oneshot(
                request(Method::POST, &format!("/v1/jobs/{run_id}/cancel"))
                    .header("if-match", "\"0\"")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let cancelled = body_json(response).await;
        assert_eq!(cancelled["run"]["state"], "cancelled");
        assert_eq!(cancelled["version"], 1);
        assert_eq!(cancelled["planBinding"], plan);
    }
}
