use std::str::FromStr;
use std::sync::Arc;

use axum::body::{Body, Bytes};
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::header::{AUTHORIZATION, CONTENT_TYPE, HOST, ORIGIN, WWW_AUTHENTICATE};
use axum::http::{HeaderMap, HeaderValue, Request, StatusCode, Uri};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use chrono::{DateTime, Utc};
use cyc_protocol::{JobSpec, Node, Run};
use cyc_scheduler::{PlacementDecision, ScheduleError, Scheduler};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::{json, Value};
use tower_http::trace::TraceLayer;
use uuid::Uuid;

use crate::auth::AuthToken;
use crate::store::{Store, StoreError, StoredJob, StoredPlan};

const MAX_JSON_BODY_BYTES: usize = 1024 * 1024;

#[derive(Clone)]
pub struct AppState {
    pub store: Store,
    pub scheduler: Arc<Scheduler>,
    security: Arc<SecurityPolicy>,
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
        }
    }
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/v1/health", get(health))
        .route("/v1/fleet", get(fleet))
        .route("/v1/nodes", post(register_node))
        .route("/v1/plans", post(plan))
        .route("/v1/jobs", get(list_jobs).post(submit_job))
        .route("/v1/jobs/{id}", get(get_job))
        .route("/v1/jobs/{id}/cancel", post(cancel_job))
        .layer(DefaultBodyLimit::max(MAX_JSON_BODY_BYTES))
        .layer(TraceLayer::new_for_http())
        .layer(middleware::from_fn_with_state(
            state.clone(),
            security_middleware,
        ))
        .with_state(state)
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
    controller: ControllerSummary,
    codex: CodexSummary,
    nodes: Vec<Node>,
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
    let (nodes, jobs) = store_call(move || {
        let nodes = store.list_nodes()?;
        let jobs = store.list_jobs(20)?;
        Ok((nodes, jobs))
    })
    .await?;
    Ok(Json(FleetResponse {
        controller: ControllerSummary {
            version: env!("CARGO_PKG_VERSION"),
            api_version: "cyc.dev/v1",
            access: "loopback",
        },
        codex: CodexSummary {
            integration: "mcp",
            status: "available",
        },
        nodes,
        recent_jobs: jobs.into_iter().map(JobView::from).collect(),
    }))
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RegisterNodeRequest {
    node: Node,
}

async fn register_node(
    State(state): State<AppState>,
    headers: HeaderMap,
    bytes: Bytes,
) -> Result<(StatusCode, Json<Node>), ApiError> {
    let request: RegisterNodeRequest = parse_json_body(&headers, &bytes)?;
    let node = request.node;
    let stored = node.clone();
    let store = state.store.clone();
    store_call(move || store.upsert_node(&stored)).await?;
    Ok((StatusCode::CREATED, Json(node)))
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PlanRequest {
    job: JobSpec,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct PlanResponse {
    plan_id: Uuid,
    job_id: Uuid,
    job_digest: String,
    created_at: DateTime<Utc>,
    expires_at: DateTime<Utc>,
    fleet_revision: i64,
    node_revision: i64,
    policy_revision: i64,
    decision: PlacementDecision,
}

impl From<StoredPlan> for PlanResponse {
    fn from(plan: StoredPlan) -> Self {
        Self {
            plan_id: plan.id,
            job_id: plan.job_id,
            job_digest: plan.job_digest,
            created_at: plan.created_at,
            expires_at: plan.expires_at,
            fleet_revision: plan.fleet_revision,
            node_revision: plan.node_revision,
            policy_revision: plan.policy_revision,
            decision: plan.decision,
        }
    }
}

async fn plan(
    State(state): State<AppState>,
    headers: HeaderMap,
    bytes: Bytes,
) -> Result<Json<PlanResponse>, ApiError> {
    let request: PlanRequest = parse_json_body(&headers, &bytes)?;
    request
        .job
        .validate()
        .map_err(|_| ApiError::invalid_job())?;
    let store = state.store.clone();
    let scheduler = state.scheduler.clone();
    let job = request.job;
    let plan = store_call(move || store.create_plan(&job, &scheduler)).await?;
    Ok(Json(plan.into()))
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
    version: u64,
    cancel_requested: bool,
}

impl From<StoredJob> for JobView {
    fn from(value: StoredJob) -> Self {
        Self {
            job: value.job,
            run: value.run,
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
            StoreError::VersionConflict { current_version } => Self {
                status: StatusCode::CONFLICT,
                code: "version_conflict",
                message: "job version changed; reload before retrying",
                extra: Some(("details", json!({ "currentVersion": current_version }))),
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
            StoreError::Database(_)
            | StoreError::Document(_)
            | StoreError::Identifier(_)
            | StoreError::Timestamp
            | StoreError::Poisoned => {
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
        Architecture, JobKind, JobStep, NodeResources, NodeStatus, NodeTransport, OperatingSystem,
        SourceSpec,
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
            NodeTransport::Local,
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

    fn build_job() -> JobSpec {
        JobSpec::new(
            JobKind::Build,
            SourceSpec::Git {
                repository: "https://example.invalid/repository.git".to_owned(),
                revision: "0123456789abcdef".to_owned(),
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
    async fn registers_node_plans_submits_and_cancels_with_versions() {
        let app = test_app();
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
        assert_eq!(response.status(), StatusCode::CREATED);

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
    }
}
