use axum::body::{Body, Bytes};
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::header::{
    AUTHORIZATION, CACHE_CONTROL, CONTENT_LENGTH, CONTENT_TYPE, ETAG, ORIGIN, WWW_AUTHENTICATE,
};
use axum::http::{HeaderMap, HeaderName, HeaderValue, Request, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
#[cfg(test)]
use chrono::Utc;
use cyc_protocol::worker::{
    ArtifactMetadata, ClaimAssignment, ClaimRequest, ClaimResponse, ExecutionLimits,
    HeartbeatRequest, HeartbeatResponse, NodeReportRequest, PairAckRequest, PairAckResponse,
    PairRequest, PairResponse, RunCompletion, StateUpdate, StateUpdateResponse,
    WorkspaceAssignment, ARTIFACT_NAME_HEADER as ARTIFACT_NAME_HEADER_STR,
    LEASE_ID_HEADER as LEASE_ID_HEADER_STR, LOG_OFFSET_HEADER as LOG_OFFSET_HEADER_STR,
    LOG_STREAM_HEADER as LOG_STREAM_HEADER_STR,
    NODE_REPORT_ACCEPTED_HEADER as NODE_REPORT_ACCEPTED_HEADER_STR,
    NODE_REPORT_BOOT_GENERATION_HEADER as NODE_REPORT_BOOT_GENERATION_HEADER_STR,
    NODE_REPORT_INVENTORY_REVISION_HEADER as NODE_REPORT_INVENTORY_REVISION_HEADER_STR,
    NODE_REPORT_SEQUENCE_HEADER as NODE_REPORT_SEQUENCE_HEADER_STR, PAIR_AUTH_SCHEME,
    RUN_CREDENTIAL_HEADER as RUN_CREDENTIAL_HEADER_STR, SHA256_HEADER as SHA256_HEADER_STR,
    WORKER_API_VERSION, WORKER_AUTH_SCHEME,
};
use cyc_protocol::{
    CleanupReceiptV1, CredentialRef, Node, NodeStatus, NodeTransport,
    COMPLETION_ACKNOWLEDGED_AT_HEADER as COMPLETION_ACKNOWLEDGED_AT_HEADER_STR,
    COMPLETION_SHA256_HEADER as COMPLETION_SHA256_HEADER_STR, SNAPSHOT_API_VERSION,
    SNAPSHOT_MEDIA_TYPE,
};
use serde::{de::DeserializeOwned, Serialize};
use serde_json::json;
use tokio::io::AsyncReadExt;
use tokio_util::io::ReaderStream;
use tower_http::trace::TraceLayer;
use uuid::Uuid;

use crate::api::AppState;
use crate::store::{
    StoreError, StoredJob, MAX_RUN_ARTIFACT_BYTES, MAX_RUN_ARTIFACT_COUNT, MAX_RUN_LOG_BYTES,
};

const MAX_WORKER_BODY_BYTES: usize = 64 * 1024 * 1024;
const MAX_WORKER_JSON_BODY_BYTES: usize = 1024 * 1024;
const MAX_LOG_CHUNK_BYTES: usize = 1024 * 1024;
const MAX_ARTIFACT_BYTES: usize = MAX_RUN_ARTIFACT_BYTES as usize;
/// Workers refresh both availability telemetry and active leases on the same
/// five-second product cadence. The controller's own receive time remains the
/// freshness authority; worker clocks are never trusted for eligibility.
const HEARTBEAT_INTERVAL_SECONDS: u32 = 5;
const IDLE_RETRY_SECONDS: u32 = 2;

const RUN_CREDENTIAL_HEADER: HeaderName = HeaderName::from_static(RUN_CREDENTIAL_HEADER_STR);
const LEASE_ID_HEADER: HeaderName = HeaderName::from_static(LEASE_ID_HEADER_STR);
const LOG_STREAM_HEADER: HeaderName = HeaderName::from_static(LOG_STREAM_HEADER_STR);
const LOG_OFFSET_HEADER: HeaderName = HeaderName::from_static(LOG_OFFSET_HEADER_STR);
const SHA256_HEADER: HeaderName = HeaderName::from_static(SHA256_HEADER_STR);
const ARTIFACT_NAME_HEADER: HeaderName = HeaderName::from_static(ARTIFACT_NAME_HEADER_STR);
const NODE_REPORT_ACCEPTED_HEADER: HeaderName =
    HeaderName::from_static(NODE_REPORT_ACCEPTED_HEADER_STR);
const NODE_REPORT_INVENTORY_REVISION_HEADER: HeaderName =
    HeaderName::from_static(NODE_REPORT_INVENTORY_REVISION_HEADER_STR);
const NODE_REPORT_BOOT_GENERATION_HEADER: HeaderName =
    HeaderName::from_static(NODE_REPORT_BOOT_GENERATION_HEADER_STR);
const NODE_REPORT_SEQUENCE_HEADER: HeaderName =
    HeaderName::from_static(NODE_REPORT_SEQUENCE_HEADER_STR);
const COMPLETION_SHA256_HEADER: HeaderName = HeaderName::from_static(COMPLETION_SHA256_HEADER_STR);
const COMPLETION_ACKNOWLEDGED_AT_HEADER: HeaderName =
    HeaderName::from_static(COMPLETION_ACKNOWLEDGED_AT_HEADER_STR);

pub fn router(state: AppState) -> Router {
    Router::new()
        .route(
            "/worker/v1/pair",
            post(pair).layer(DefaultBodyLimit::max(MAX_WORKER_JSON_BODY_BYTES)),
        )
        .route(
            "/worker/v1/pair/ack",
            post(pair_ack).layer(DefaultBodyLimit::max(MAX_WORKER_JSON_BODY_BYTES)),
        )
        .route(
            "/worker/v1/claim",
            post(claim).layer(DefaultBodyLimit::max(MAX_WORKER_JSON_BODY_BYTES)),
        )
        .route(
            "/worker/v1/node-report",
            post(node_report).layer(DefaultBodyLimit::max(MAX_WORKER_JSON_BODY_BYTES)),
        )
        .route(
            "/worker/v1/runs/{run_id}/heartbeat",
            post(heartbeat).layer(DefaultBodyLimit::max(MAX_WORKER_JSON_BODY_BYTES)),
        )
        .route(
            "/worker/v1/runs/{run_id}/state",
            post(update_state).layer(DefaultBodyLimit::max(MAX_WORKER_JSON_BODY_BYTES)),
        )
        .route(
            "/worker/v1/runs/{run_id}/complete",
            post(complete).layer(DefaultBodyLimit::max(MAX_WORKER_JSON_BODY_BYTES)),
        )
        .route(
            "/worker/v1/runs/{run_id}/cleanup",
            post(cleanup).layer(DefaultBodyLimit::max(MAX_WORKER_JSON_BODY_BYTES)),
        )
        .route(
            "/worker/v1/runs/{run_id}/logs",
            post(upload_log).layer(DefaultBodyLimit::max(MAX_LOG_CHUNK_BYTES)),
        )
        .route(
            "/worker/v1/runs/{run_id}/artifacts/{artifact_id}",
            post(upload_artifact).layer(DefaultBodyLimit::max(MAX_ARTIFACT_BYTES)),
        )
        .route(
            "/worker/v1/runs/{run_id}/source/{sha256}",
            get(download_source),
        )
        .layer(DefaultBodyLimit::max(MAX_WORKER_BODY_BYTES))
        .layer(TraceLayer::new_for_http())
        .layer(middleware::from_fn_with_state(
            state.clone(),
            preauthorize_before_body,
        ))
        .layer(middleware::from_fn(reject_browser_origin))
        .with_state(state)
}

/// Authenticate solely from the request head. This middleware must run before
/// handlers containing `Bytes`, otherwise axum would buffer as much as 64 MiB
/// before discovering an invalid pairing/worker/run credential.
async fn preauthorize_before_body(
    State(state): State<AppState>,
    request: Request<Body>,
    next: Next,
) -> Response {
    let path = request.uri().path();
    let headers = request.headers();
    let authorization = if path == "/worker/v1/pair" {
        match authorization_secret(headers, PAIR_AUTH_SCHEME) {
            Ok(pairing_code) => {
                let store = state.store.clone();
                store_call(move || store.preauthorize_pairing(&pairing_code)).await
            }
            Err(error) => Err(error),
        }
    } else if path == "/worker/v1/pair/ack" {
        match authorization_secret(headers, WORKER_AUTH_SCHEME) {
            Ok(worker_credential) => {
                let store = state.store.clone();
                store_call(move || store.preauthorize_pairing_ack(&worker_credential)).await
            }
            Err(error) => Err(error),
        }
    } else if matches!(path, "/worker/v1/claim" | "/worker/v1/node-report") {
        match authorization_secret(headers, WORKER_AUTH_SCHEME) {
            Ok(worker_credential) => {
                let store = state.store.clone();
                store_call(move || store.authenticate_worker(&worker_credential).map(|_| ())).await
            }
            Err(error) => Err(error),
        }
    } else if let Some((run_id, allow_revoked_completion)) = run_route(path) {
        match (
            authorization_secret(headers, WORKER_AUTH_SCHEME),
            required_secret_header(headers, &RUN_CREDENTIAL_HEADER),
        ) {
            (Ok(worker_credential), Ok(run_credential)) => {
                let store = state.store.clone();
                store_call(move || {
                    store.preauthorize_run_route(
                        &worker_credential,
                        &run_credential,
                        run_id,
                        allow_revoked_completion,
                    )
                })
                .await
            }
            (Err(error), _) | (_, Err(error)) => Err(error),
        }
    } else {
        return next.run(request).await;
    };

    match authorization {
        Ok(()) => next.run(request).await,
        Err(error) => error.into_response(),
    }
}

async fn node_report(
    State(state): State<AppState>,
    headers: HeaderMap,
    bytes: Bytes,
) -> Result<Response, WorkerApiError> {
    let worker_credential = authorization_secret(&headers, WORKER_AUTH_SCHEME)?;
    let report: NodeReportRequest = parse_json(&headers, &bytes)?;
    report
        .validate()
        .map_err(|_| WorkerApiError::invalid_request())?;
    let store = state.store.clone();
    let outcome = store_call(move || store.record_node_report(&worker_credential, &report)).await?;
    let mut response = StatusCode::NO_CONTENT.into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("no-store"));
    response.headers_mut().insert(
        &NODE_REPORT_ACCEPTED_HEADER,
        HeaderValue::from_static(if outcome.accepted { "true" } else { "false" }),
    );
    response.headers_mut().insert(
        &NODE_REPORT_INVENTORY_REVISION_HEADER,
        HeaderValue::from_str(&outcome.inventory_revision.to_string())
            .map_err(|_| WorkerApiError::internal())?,
    );
    response.headers_mut().insert(
        &NODE_REPORT_BOOT_GENERATION_HEADER,
        HeaderValue::from_str(&outcome.telemetry_boot_generation.to_string())
            .map_err(|_| WorkerApiError::internal())?,
    );
    response.headers_mut().insert(
        &NODE_REPORT_SEQUENCE_HEADER,
        HeaderValue::from_str(&outcome.telemetry_sequence.to_string())
            .map_err(|_| WorkerApiError::internal())?,
    );
    Ok(response)
}

fn run_route(path: &str) -> Option<(Uuid, bool)> {
    let mut segments = path.strip_prefix("/worker/v1/runs/")?.split('/');
    let run_id = segments.next()?.parse().ok()?;
    let operation = segments.next()?;
    let tail = segments.next();
    let exact_shape = match operation {
        "heartbeat" | "state" | "complete" | "cleanup" | "logs" => tail.is_none(),
        "artifacts" | "source" => tail.is_some() && segments.next().is_none(),
        _ => false,
    };
    exact_shape.then_some((run_id, matches!(operation, "complete" | "cleanup")))
}

async fn reject_browser_origin(request: Request<Body>, next: Next) -> Response {
    if request.headers().contains_key(ORIGIN) {
        return WorkerApiError::new(
            StatusCode::FORBIDDEN,
            "origin_forbidden",
            "browser Origin requests are not accepted",
        )
        .into_response();
    }
    next.run(request).await
}

async fn pair(
    State(state): State<AppState>,
    headers: HeaderMap,
    bytes: Bytes,
) -> Result<Response, WorkerApiError> {
    let pairing_code = authorization_secret(&headers, PAIR_AUTH_SCHEME)?;
    let request: PairRequest = parse_json(&headers, &bytes)?;
    request
        .validate()
        .map_err(|_| WorkerApiError::invalid_request())?;
    let endpoint = state
        .worker_endpoint()
        .ok_or_else(WorkerApiError::unavailable)?;
    let node = node_from_probe(
        Some(request.intended_node_id),
        request.display_name.as_deref(),
        &request.probe,
        &endpoint.public_url,
        false,
    );
    let store = state.store.clone();
    let (paired, controller_id) = store_call(move || {
        let paired = store.consume_pairing(
            &pairing_code,
            request.pairing_id,
            request.intended_node_id,
            &request.credential_sha256,
            &node,
        )?;
        Ok((paired, store.controller_id()?))
    })
    .await?;

    let response = PairResponse {
        api_version: WORKER_API_VERSION.to_owned(),
        pairing_id: paired.pairing_id,
        controller_id,
        node_id: paired.node_id,
        credential_sha256: paired.credential_sha256,
        paired_at: paired.consumed_at,
        heartbeat_interval_seconds: HEARTBEAT_INTERVAL_SECONDS,
        lease_seconds: u32::try_from(crate::store::CLAIM_TTL_SECONDS).unwrap_or(u32::MAX),
    };
    response
        .validate()
        .map_err(|_| WorkerApiError::internal())?;
    let status = if paired.replayed {
        StatusCode::OK
    } else {
        StatusCode::CREATED
    };
    let mut response = (status, Json(response)).into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("no-store"));
    Ok(response)
}

async fn pair_ack(
    State(state): State<AppState>,
    headers: HeaderMap,
    bytes: Bytes,
) -> Result<Response, WorkerApiError> {
    let worker_credential = authorization_secret(&headers, WORKER_AUTH_SCHEME)?;
    let request: PairAckRequest = parse_json(&headers, &bytes)?;
    request
        .validate()
        .map_err(|_| WorkerApiError::invalid_request())?;
    let store = state.store.clone();
    let acknowledgement = store_call(move || {
        store.acknowledge_pairing(
            &worker_credential,
            request.pairing_id,
            request.node_id,
            &request.credential_sha256,
        )
    })
    .await?;
    let response = PairAckResponse {
        api_version: WORKER_API_VERSION.to_owned(),
        pairing_id: acknowledgement.pairing_id,
        node_id: acknowledgement.node_id,
        credential_sha256: acknowledgement.credential_sha256,
        acknowledged_at: acknowledgement.acknowledged_at,
    };
    response
        .validate()
        .map_err(|_| WorkerApiError::internal())?;
    let mut response = Json(response).into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("no-store"));
    Ok(response)
}

async fn claim(
    State(state): State<AppState>,
    headers: HeaderMap,
    bytes: Bytes,
) -> Result<Response, WorkerApiError> {
    let worker_credential = authorization_secret(&headers, WORKER_AUTH_SCHEME)?;
    let request: ClaimRequest = parse_json(&headers, &bytes)?;
    request
        .validate()
        .map_err(|_| WorkerApiError::invalid_request())?;
    let store = state.store.clone();
    let credential_for_auth = worker_credential.clone();
    let node_id = store_call(move || store.authenticate_worker(&credential_for_auth)).await?;
    let endpoint = state
        .worker_endpoint()
        .ok_or_else(WorkerApiError::unavailable)?;
    let node = node_from_probe(
        Some(node_id),
        None,
        &request.probe,
        &endpoint.public_url,
        true,
    );
    let store = state.store.clone();
    let claim = store_call(move || store.claim_job(&worker_credential, &node)).await?;
    let Some(claim) = claim else {
        return Ok(StatusCode::NO_CONTENT.into_response());
    };
    let assignment = ClaimAssignment {
        job_id: claim.stored.job.id,
        run_id: claim.stored.run.id,
        job_digest: claim.job_digest,
        lease_id: claim.lease_id,
        lease_until: claim.lease_until,
        state_version: claim.stored.version,
        job_spec: claim.stored.job,
        workspace: WorkspaceAssignment {
            relative_root: format!("jobs/{}", claim.stored.run.id),
            source_directory: "repo".to_owned(),
            logs_directory: "logs".to_owned(),
            artifacts_directory: "artifacts".to_owned(),
        },
        limits: ExecutionLimits {
            max_log_bytes: MAX_RUN_LOG_BYTES,
            max_artifact_bytes: MAX_RUN_ARTIFACT_BYTES,
            max_artifact_count: MAX_RUN_ARTIFACT_COUNT,
            ..ExecutionLimits::default()
        },
    };
    assignment
        .validate()
        .map_err(|_| WorkerApiError::internal())?;
    let body = ClaimResponse {
        assignment: Some(assignment),
        retry_after_seconds: IDLE_RETRY_SECONDS,
    };
    let mut credential =
        HeaderValue::from_str(&claim.run_credential).map_err(|_| WorkerApiError::internal())?;
    credential.set_sensitive(true);
    let mut response = Json(body).into_response();
    response
        .headers_mut()
        .insert(RUN_CREDENTIAL_HEADER, credential);
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("no-store"));
    Ok(response)
}

async fn heartbeat(
    State(state): State<AppState>,
    Path(run_id): Path<Uuid>,
    headers: HeaderMap,
    bytes: Bytes,
) -> Result<Json<HeartbeatResponse>, WorkerApiError> {
    let worker_credential = authorization_secret(&headers, WORKER_AUTH_SCHEME)?;
    let run_credential = required_secret_header(&headers, &RUN_CREDENTIAL_HEADER)?;
    let request: HeartbeatRequest = parse_json(&headers, &bytes)?;
    request
        .validate()
        .map_err(|_| WorkerApiError::invalid_request())?;
    if request.run_id != run_id {
        return Err(WorkerApiError::invalid_request());
    }
    let store = state.store.clone();
    let heartbeat = store_call(move || {
        store.worker_heartbeat(
            &worker_credential,
            &run_credential,
            run_id,
            request.lease_id,
            request.expected_version,
            request.state,
        )
    })
    .await?;
    Ok(Json(HeartbeatResponse {
        cancel_requested: heartbeat.stored.cancel_requested,
        current_version: heartbeat.stored.version,
        lease_until: heartbeat.lease_until,
    }))
}

async fn update_state(
    State(state): State<AppState>,
    Path(run_id): Path<Uuid>,
    headers: HeaderMap,
    bytes: Bytes,
) -> Result<Json<StateUpdateResponse>, WorkerApiError> {
    let worker_credential = authorization_secret(&headers, WORKER_AUTH_SCHEME)?;
    let run_credential = required_secret_header(&headers, &RUN_CREDENTIAL_HEADER)?;
    let request: StateUpdate = parse_json(&headers, &bytes)?;
    request
        .validate()
        .map_err(|_| WorkerApiError::invalid_request())?;
    if request.run_id != run_id || request.next_state.is_terminal() {
        return Err(WorkerApiError::invalid_request());
    }
    let store = state.store.clone();
    let stored = store_call(move || {
        store.worker_transition(
            &worker_credential,
            &run_credential,
            run_id,
            request.lease_id,
            request.expected_version,
            request.next_state,
        )
    })
    .await?;
    Ok(Json(state_update_response(stored)))
}

async fn complete(
    State(state): State<AppState>,
    Path(run_id): Path<Uuid>,
    headers: HeaderMap,
    bytes: Bytes,
) -> Result<Response, WorkerApiError> {
    let worker_credential = authorization_secret(&headers, WORKER_AUTH_SCHEME)?;
    let run_credential = required_secret_header(&headers, &RUN_CREDENTIAL_HEADER)?;
    let request: RunCompletion = parse_json(&headers, &bytes)?;
    request
        .validate()
        .map_err(|_| WorkerApiError::invalid_request())?;
    if request.run_id != run_id {
        return Err(WorkerApiError::invalid_request());
    }
    let store = state.store.clone();
    let (stored, completion) = store_call(move || {
        let stored =
            store.worker_complete_managed(&worker_credential, &run_credential, &request)?;
        let completion = store.get_completion(run_id)?;
        Ok((stored, completion))
    })
    .await?;
    let mut response = Json(state_update_response(stored)).into_response();
    response.headers_mut().insert(
        COMPLETION_SHA256_HEADER,
        HeaderValue::from_str(&completion.sha256).map_err(|_| WorkerApiError::internal())?,
    );
    response.headers_mut().insert(
        COMPLETION_ACKNOWLEDGED_AT_HEADER,
        HeaderValue::from_str(&completion.created_at.to_rfc3339())
            .map_err(|_| WorkerApiError::internal())?,
    );
    Ok(response)
}

async fn cleanup(
    State(state): State<AppState>,
    Path(run_id): Path<Uuid>,
    headers: HeaderMap,
    bytes: Bytes,
) -> Result<Json<CleanupReceiptV1>, WorkerApiError> {
    let worker_credential = authorization_secret(&headers, WORKER_AUTH_SCHEME)?;
    let run_credential = required_secret_header(&headers, &RUN_CREDENTIAL_HEADER)?;
    let receipt: CleanupReceiptV1 = parse_json(&headers, &bytes)?;
    receipt
        .validate()
        .map_err(|_| WorkerApiError::invalid_request())?;
    if receipt.run_id != run_id {
        return Err(WorkerApiError::invalid_request());
    }
    let store = state.store.clone();
    let stored =
        store_call(move || store.record_cleanup(&worker_credential, &run_credential, &receipt))
            .await?;
    Ok(Json(stored.receipt))
}

async fn upload_log(
    State(state): State<AppState>,
    Path(run_id): Path<Uuid>,
    headers: HeaderMap,
    bytes: Bytes,
) -> Result<Json<LogChunkResponse>, WorkerApiError> {
    require_binary_content_type(&headers)?;
    if bytes.len() > MAX_LOG_CHUNK_BYTES {
        return Err(WorkerApiError::payload_too_large());
    }
    let worker_credential = authorization_secret(&headers, WORKER_AUTH_SCHEME)?;
    let run_credential = required_secret_header(&headers, &RUN_CREDENTIAL_HEADER)?;
    let lease_id = required_uuid_header(&headers, &LEASE_ID_HEADER)?;
    let stream = required_text_header(&headers, &LOG_STREAM_HEADER)?;
    let offset = required_u64_header(&headers, &LOG_OFFSET_HEADER)?;
    let sha256 = required_text_header(&headers, &SHA256_HEADER)?;
    let store = state.store.clone();
    let chunk = store_call(move || {
        store.put_log_chunk(
            &worker_credential,
            &run_credential,
            run_id,
            lease_id,
            &stream,
            offset,
            &sha256,
            &bytes,
        )
    })
    .await?;
    Ok(Json(LogChunkResponse {
        run_id: chunk.run_id,
        stream: chunk.stream,
        offset: chunk.offset,
        length: chunk.length,
        sha256: chunk.sha256,
    }))
}

async fn upload_artifact(
    State(state): State<AppState>,
    Path((run_id, artifact_id)): Path<(Uuid, Uuid)>,
    headers: HeaderMap,
    bytes: Bytes,
) -> Result<(StatusCode, Json<ArtifactMetadata>), WorkerApiError> {
    require_binary_content_type(&headers)?;
    if bytes.len() > MAX_ARTIFACT_BYTES {
        return Err(WorkerApiError::payload_too_large());
    }
    let worker_credential = authorization_secret(&headers, WORKER_AUTH_SCHEME)?;
    let run_credential = required_secret_header(&headers, &RUN_CREDENTIAL_HEADER)?;
    let lease_id = required_uuid_header(&headers, &LEASE_ID_HEADER)?;
    let name = required_text_header(&headers, &ARTIFACT_NAME_HEADER)?;
    let sha256 = required_text_header(&headers, &SHA256_HEADER)?;
    let store = state.store.clone();
    let artifact = store_call(move || {
        store.put_artifact(
            &worker_credential,
            &run_credential,
            run_id,
            lease_id,
            artifact_id,
            &name,
            &sha256,
            &bytes,
        )
    })
    .await?;
    let response = ArtifactMetadata {
        id: artifact.id,
        run_id: artifact.run_id,
        relative_path: artifact.name,
        size_bytes: artifact.size,
        sha256: artifact.sha256,
        media_type: None,
        created_at: artifact.created_at,
    };
    response
        .validate()
        .map_err(|_| WorkerApiError::internal())?;
    Ok((StatusCode::CREATED, Json(response)))
}

async fn download_source(
    State(state): State<AppState>,
    Path((run_id, sha256)): Path<(Uuid, String)>,
    headers: HeaderMap,
) -> Result<Response, WorkerApiError> {
    let worker_credential = authorization_secret(&headers, WORKER_AUTH_SCHEME)?;
    let run_credential = required_secret_header(&headers, &RUN_CREDENTIAL_HEADER)?;
    let lease_id = required_uuid_header(&headers, &LEASE_ID_HEADER)?;
    let digest = format!("sha256:{sha256}");
    cyc_protocol::validate_snapshot_digest(&digest)
        .map_err(|_| WorkerApiError::invalid_request())?;
    let store = state.store.clone();
    let download = store_call(move || {
        store.authorize_snapshot_download(
            &worker_credential,
            &run_credential,
            run_id,
            lease_id,
            &digest,
        )
    })
    .await?;
    let file = tokio::fs::File::open(&download.path)
        .await
        .map_err(|_| WorkerApiError::internal())?;
    let stream = ReaderStream::new(file.take(download.metadata.size_bytes.saturating_add(1)));
    let mut response = Body::from_stream(stream).into_response();
    let size = HeaderValue::from_str(&download.metadata.size_bytes.to_string())
        .map_err(|_| WorkerApiError::internal())?;
    let digest =
        HeaderValue::from_str(&download.metadata.digest).map_err(|_| WorkerApiError::internal())?;
    let etag = HeaderValue::from_str(&format!("\"{}\"", download.metadata.digest))
        .map_err(|_| WorkerApiError::internal())?;
    response
        .headers_mut()
        .insert(CONTENT_TYPE, HeaderValue::from_static(SNAPSHOT_MEDIA_TYPE));
    response.headers_mut().insert(CONTENT_LENGTH, size);
    response.headers_mut().insert(SHA256_HEADER, digest);
    response.headers_mut().insert(ETAG, etag);
    response.headers_mut().insert(
        "x-cyc-snapshot-version",
        HeaderValue::from_static(SNAPSHOT_API_VERSION),
    );
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    Ok(response)
}

fn node_from_probe(
    id: Option<Uuid>,
    display_name: Option<&str>,
    probe: &cyc_protocol::worker::ProbeReport,
    endpoint: &str,
    daemon_active: bool,
) -> Node {
    let mut node = Node::new(
        display_name.unwrap_or(&probe.hostname),
        NodeTransport::Managed {
            endpoint: endpoint.to_owned(),
            credential_ref: CredentialRef::new("controller-db:managed-worker"),
        },
        probe.os,
        probe.arch,
    );
    if let Some(id) = id {
        node.id = id;
    }
    node.status = if daemon_active {
        NodeStatus::Online
    } else {
        NodeStatus::Offline
    };
    node.capabilities.clone_from(&probe.capabilities);
    node.resources.clone_from(&probe.resources);
    node.load.clone_from(&probe.load);
    node.last_seen_at = daemon_active.then_some(probe.observed_at);
    node
}

fn state_update_response(value: StoredJob) -> StateUpdateResponse {
    StateUpdateResponse {
        run: value.run,
        state_version: value.version,
        cancel_requested: value.cancel_requested,
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct LogChunkResponse {
    run_id: Uuid,
    stream: String,
    offset: u64,
    length: u64,
    sha256: String,
}

fn authorization_secret(
    headers: &HeaderMap,
    expected_scheme: &str,
) -> Result<String, WorkerApiError> {
    let value = headers
        .get(AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .ok_or_else(WorkerApiError::unauthorized)?;
    let (scheme, secret) = value
        .split_once(' ')
        .ok_or_else(WorkerApiError::unauthorized)?;
    if !scheme.eq_ignore_ascii_case(expected_scheme) || !valid_secret(secret) {
        return Err(WorkerApiError::unauthorized());
    }
    Ok(secret.to_owned())
}

fn required_secret_header(
    headers: &HeaderMap,
    name: &HeaderName,
) -> Result<String, WorkerApiError> {
    let value = required_text_header(headers, name)?;
    if !valid_secret(&value) {
        return Err(WorkerApiError::unauthorized());
    }
    Ok(value)
}

fn valid_secret(secret: &str) -> bool {
    (32..=256).contains(&secret.len())
        && secret
            .bytes()
            .all(|byte| byte.is_ascii_graphic() && !byte.is_ascii_whitespace())
}

fn required_text_header(headers: &HeaderMap, name: &HeaderName) -> Result<String, WorkerApiError> {
    headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .filter(|value| !value.is_empty() && value.len() <= 1024)
        .map(ToOwned::to_owned)
        .ok_or_else(WorkerApiError::invalid_request)
}

fn required_uuid_header(headers: &HeaderMap, name: &HeaderName) -> Result<Uuid, WorkerApiError> {
    required_text_header(headers, name)?
        .parse()
        .map_err(|_| WorkerApiError::invalid_request())
}

fn required_u64_header(headers: &HeaderMap, name: &HeaderName) -> Result<u64, WorkerApiError> {
    required_text_header(headers, name)?
        .parse()
        .map_err(|_| WorkerApiError::invalid_request())
}

fn parse_json<T: DeserializeOwned>(headers: &HeaderMap, bytes: &[u8]) -> Result<T, WorkerApiError> {
    let content_type = headers
        .get(CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(';').next())
        .map(str::trim);
    if !content_type.is_some_and(|value| value.eq_ignore_ascii_case("application/json")) {
        return Err(WorkerApiError::unsupported_media_type());
    }
    serde_json::from_slice(bytes).map_err(|_| WorkerApiError::invalid_request())
}

fn require_binary_content_type(headers: &HeaderMap) -> Result<(), WorkerApiError> {
    let valid = headers
        .get(CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| value.eq_ignore_ascii_case("application/octet-stream"));
    if valid {
        Ok(())
    } else {
        Err(WorkerApiError::unsupported_media_type())
    }
}

async fn store_call<T, F>(operation: F) -> Result<T, WorkerApiError>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, StoreError> + Send + 'static,
{
    tokio::task::spawn_blocking(operation)
        .await
        .map_err(|_| WorkerApiError::internal())?
        .map_err(WorkerApiError::from)
}

#[derive(Debug)]
struct WorkerApiError {
    status: StatusCode,
    code: &'static str,
    message: &'static str,
    current_version: Option<u64>,
    cancel_requested: Option<bool>,
    current_state: Option<cyc_protocol::JobState>,
}

impl WorkerApiError {
    fn new(status: StatusCode, code: &'static str, message: &'static str) -> Self {
        Self {
            status,
            code,
            message,
            current_version: None,
            cancel_requested: None,
            current_state: None,
        }
    }

    fn invalid_request() -> Self {
        Self::new(
            StatusCode::BAD_REQUEST,
            "invalid_request",
            "request is invalid",
        )
    }

    fn unsupported_media_type() -> Self {
        Self::new(
            StatusCode::UNSUPPORTED_MEDIA_TYPE,
            "invalid_content_type",
            "the endpoint requires its documented Content-Type",
        )
    }

    fn unauthorized() -> Self {
        Self::new(
            StatusCode::UNAUTHORIZED,
            "unauthorized",
            "worker authentication failed",
        )
    }

    fn unavailable() -> Self {
        Self::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "worker_listener_unavailable",
            "managed worker service is unavailable",
        )
    }

    fn payload_too_large() -> Self {
        Self::new(
            StatusCode::PAYLOAD_TOO_LARGE,
            "payload_too_large",
            "upload exceeds the endpoint limit",
        )
    }

    fn internal() -> Self {
        Self::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "internal_error",
            "controller operation failed",
        )
    }
}

impl From<StoreError> for WorkerApiError {
    fn from(error: StoreError) -> Self {
        match error {
            StoreError::WorkerUnauthorized | StoreError::RunUnauthorized => Self::unauthorized(),
            StoreError::PairingUnavailable => Self::new(
                StatusCode::GONE,
                "pairing_unavailable",
                "pairing code is expired, used, or revoked",
            ),
            StoreError::PairingBindingMismatch => Self::new(
                StatusCode::CONFLICT,
                "pairing_binding_mismatch",
                "pairing retry does not match the consumed binding",
            ),
            StoreError::InvalidCredentialDigest => Self::invalid_request(),
            StoreError::PairingAcknowledgementUnavailable => Self::new(
                StatusCode::UNAUTHORIZED,
                "pairing_ack_unauthorized",
                "pairing acknowledgement authentication failed",
            ),
            StoreError::NotFound => Self::new(
                StatusCode::NOT_FOUND,
                "not_found",
                "requested run was not found",
            ),
            StoreError::VersionConflict { current_version } => {
                let mut response = Self::new(
                    StatusCode::CONFLICT,
                    "version_conflict",
                    "run state version changed",
                );
                response.current_version = Some(current_version);
                response
            }
            StoreError::NodeConfigVersionConflict { .. } | StoreError::InvalidNodeConfig => {
                Self::new(
                    StatusCode::CONFLICT,
                    "controller_conflict",
                    "controller node configuration conflicts with this worker request",
                )
            }
            StoreError::WorkerStateConflict {
                current_version,
                cancel_requested,
                current_state,
            } => {
                let mut response = Self::new(
                    StatusCode::CONFLICT,
                    "state_conflict",
                    "run state no longer accepts this operation",
                );
                response.current_version = Some(current_version);
                response.cancel_requested = Some(cancel_requested);
                response.current_state = Some(current_state);
                response
            }
            StoreError::InvalidTransition | StoreError::CancellationPending => Self::new(
                StatusCode::CONFLICT,
                "state_conflict",
                "run state no longer accepts this operation",
            ),
            StoreError::InvalidRunEvidence => Self::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "invalid_run_evidence",
                "run evidence is missing or inconsistent",
            ),
            StoreError::InvalidNodeReport => Self::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "invalid_node_report",
                "node inventory or telemetry is invalid",
            ),
            StoreError::UploadConflict => Self::new(
                StatusCode::CONFLICT,
                "upload_conflict",
                "upload conflicts with stored content",
            ),
            StoreError::UploadOffset => Self::new(
                StatusCode::CONFLICT,
                "upload_offset",
                "log offset is not contiguous",
            ),
            StoreError::DigestMismatch => Self::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "digest_mismatch",
                "uploaded bytes do not match the declared digest",
            ),
            StoreError::InvalidUpload => Self::invalid_request(),
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
            StoreError::SnapshotQuotaExceeded => Self::new(
                StatusCode::PAYLOAD_TOO_LARGE,
                "snapshot_too_large",
                "snapshot archive exceeds the controller limit",
            ),
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
            StoreError::InvalidManagedNode => Self::invalid_request(),
            StoreError::InvalidPairingOperationKey
            | StoreError::PairingIdempotencyMismatch
            | StoreError::PairingIdempotencyFinalized { .. } => Self::new(
                StatusCode::CONFLICT,
                "controller_conflict",
                "controller pairing state conflicts with this worker request",
            ),
            StoreError::Conflict
            | StoreError::PlanExpired
            | StoreError::PlanStale
            | StoreError::PlanDigestMismatch
            | StoreError::Schedule(_) => Self::new(
                StatusCode::CONFLICT,
                "controller_conflict",
                "controller state conflicts with this worker request",
            ),
            StoreError::StorageSecurity(_)
            | StoreError::Database(_)
            | StoreError::Document(_)
            | StoreError::NodeState(_)
            | StoreError::NodeIdentityMismatch
            | StoreError::InvalidPlanBinding
            | StoreError::InvalidFleetRevision
            | StoreError::Identifier(_)
            | StoreError::Timestamp
            | StoreError::Poisoned
            | StoreError::Io(_) => {
                tracing::error!(error = %error, "managed worker controller failure");
                Self::internal()
            }
        }
    }
}

impl IntoResponse for WorkerApiError {
    fn into_response(self) -> Response {
        let mut error = json!({ "code": self.code, "message": self.message });
        if let Some(version) = self.current_version {
            error["currentVersion"] = json!(version);
        }
        if let Some(cancel_requested) = self.cancel_requested {
            error["cancelRequested"] = json!(cancel_requested);
        }
        if let Some(current_state) = self.current_state {
            error["currentState"] = json!(current_state);
        }
        let mut response = (self.status, Json(json!({ "error": error }))).into_response();
        if self.status == StatusCode::UNAUTHORIZED {
            response
                .headers_mut()
                .insert(WWW_AUTHENTICATE, HeaderValue::from_static("Bearer"));
        }
        response
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::header::HOST;
    use axum::http::{Method, Request};
    use cyc_protocol::worker::{
        ExecutionEvidence, ExecutionSourceEvidence, ProbeReport, RunEvidence, RunStreamsEvidence,
        StepExecutionEvidence, StreamEvidence, TerminationEvidence, TerminationReason,
    };
    use cyc_protocol::{
        Architecture, JobKind, JobSpec, JobState, JobStep, NodeInventory, NodeLoad, NodeResources,
        NodeTelemetry, OperatingSystem, Shell, SourceSpec, PROTOCOL_VERSION,
    };
    use http_body::{Body as HttpBody, Frame};
    use http_body_util::BodyExt;
    use serde_json::Value;
    use std::convert::Infallible;
    use std::pin::Pin;
    use std::task::{Context, Poll};
    use tower::ServiceExt;

    use crate::store::Store;

    struct PanicOnPollBody;

    impl HttpBody for PanicOnPollBody {
        type Data = Bytes;
        type Error = Infallible;

        fn poll_frame(
            self: Pin<&mut Self>,
            _context: &mut Context<'_>,
        ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
            panic!("unauthorized request body was polled")
        }
    }

    fn probe() -> ProbeReport {
        ProbeReport {
            protocol_version: PROTOCOL_VERSION,
            agent_version: "0.1.0".to_owned(),
            observed_at: Utc::now(),
            hostname: "managed-test".to_owned(),
            os: OperatingSystem::Linux,
            arch: Architecture::X86_64,
            capabilities: Default::default(),
            resources: NodeResources {
                logical_cpu_cores: 8,
                available_cpu_cores: 8,
                memory_mib: 16_384,
                available_memory_mib: 12_288,
                disk_mib: 100_000,
                available_disk_mib: 80_000,
                gpus: Vec::new(),
            },
            load: NodeLoad::default(),
        }
    }

    fn job() -> JobSpec {
        JobSpec::new(
            JobKind::Build,
            SourceSpec::Git {
                repository: "https://example.invalid/repository.git".to_owned(),
                revision: "0123456789abcdef0123456789abcdef01234567".to_owned(),
            },
            vec![JobStep::new("build", "cargo build --locked")],
        )
    }

    fn snapshot_job(digest: String, size_bytes: u64) -> JobSpec {
        JobSpec::new(
            JobKind::Test,
            SourceSpec::Snapshot {
                digest,
                size_bytes: Some(size_bytes),
            },
            vec![JobStep::new("check", "echo snapshot")],
        )
    }

    fn state(store: Store) -> AppState {
        AppState::new(store, crate::auth::AuthToken::test_token(), 47_831).with_worker_endpoint(
            "https://controller.example:47832".to_owned(),
            "test certificate".to_owned(),
        )
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

    async fn json_body(response: Response) -> Value {
        let body = response.into_body().collect().await.unwrap().to_bytes();
        serde_json::from_slice(&body).unwrap()
    }

    #[test]
    fn generated_worker_paths_do_not_accept_secrets_in_json() {
        assert!(valid_secret(&"a".repeat(64)));
        assert!(!valid_secret("short"));
        assert!(!valid_secret(&format!("{} {}", "a".repeat(32), "b")));
    }

    #[test]
    fn worker_router_constants_keep_uploads_bounded() {
        let log_limit = std::hint::black_box(MAX_LOG_CHUNK_BYTES);
        let artifact_limit = std::hint::black_box(MAX_ARTIFACT_BYTES);
        let body_limit = std::hint::black_box(MAX_WORKER_BODY_BYTES);
        let heartbeat = std::hint::black_box(HEARTBEAT_INTERVAL_SECONDS);
        assert!(log_limit < artifact_limit);
        assert_eq!(body_limit, artifact_limit);
        assert_eq!(heartbeat, 5);
        assert!(heartbeat < crate::store::CLAIM_TTL_SECONDS as u32);
    }

    #[tokio::test]
    async fn worker_router_exposes_no_client_admin_and_rejects_origin() {
        let app = router(state(Store::in_memory().unwrap()));
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/v1/fleet")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NOT_FOUND);

        let response = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/worker/v1/pair")
                    .header(ORIGIN, "https://attacker.example")
                    .body(Body::from("{}"))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::FORBIDDEN);
    }

    #[tokio::test]
    async fn worker_authentication_rejects_every_route_before_polling_the_body() {
        let app = router(state(Store::in_memory().unwrap()));
        let run_id = Uuid::new_v4();
        let artifact_id = Uuid::new_v4();
        let invalid = "x".repeat(64);
        let requests = [
            (
                "/worker/v1/pair".to_owned(),
                format!("{PAIR_AUTH_SCHEME} {invalid}"),
                None,
                StatusCode::GONE,
            ),
            (
                "/worker/v1/pair/ack".to_owned(),
                format!("{WORKER_AUTH_SCHEME} {invalid}"),
                None,
                StatusCode::UNAUTHORIZED,
            ),
            (
                "/worker/v1/claim".to_owned(),
                format!("{WORKER_AUTH_SCHEME} {invalid}"),
                None,
                StatusCode::UNAUTHORIZED,
            ),
            (
                "/worker/v1/node-report".to_owned(),
                format!("{WORKER_AUTH_SCHEME} {invalid}"),
                None,
                StatusCode::UNAUTHORIZED,
            ),
            (
                format!("/worker/v1/runs/{run_id}/heartbeat"),
                format!("{WORKER_AUTH_SCHEME} {invalid}"),
                Some(invalid.as_str()),
                StatusCode::UNAUTHORIZED,
            ),
            (
                format!("/worker/v1/runs/{run_id}/state"),
                format!("{WORKER_AUTH_SCHEME} {invalid}"),
                Some(invalid.as_str()),
                StatusCode::UNAUTHORIZED,
            ),
            (
                format!("/worker/v1/runs/{run_id}/complete"),
                format!("{WORKER_AUTH_SCHEME} {invalid}"),
                Some(invalid.as_str()),
                StatusCode::UNAUTHORIZED,
            ),
            (
                format!("/worker/v1/runs/{run_id}/logs"),
                format!("{WORKER_AUTH_SCHEME} {invalid}"),
                Some(invalid.as_str()),
                StatusCode::UNAUTHORIZED,
            ),
            (
                format!("/worker/v1/runs/{run_id}/artifacts/{artifact_id}"),
                format!("{WORKER_AUTH_SCHEME} {invalid}"),
                Some(invalid.as_str()),
                StatusCode::UNAUTHORIZED,
            ),
        ];

        for (uri, authorization, run_credential, expected) in requests {
            let mut request = Request::builder()
                .method(Method::POST)
                .uri(uri)
                .header(AUTHORIZATION, authorization)
                .header(CONTENT_TYPE, "application/octet-stream");
            if let Some(run_credential) = run_credential {
                request = request.header(&RUN_CREDENTIAL_HEADER, run_credential);
            }
            let response = app
                .clone()
                .oneshot(request.body(Body::new(PanicOnPollBody)).unwrap())
                .await
                .unwrap();
            assert_eq!(response.status(), expected);
        }

        let response = app
            .oneshot(
                Request::builder()
                    .method(Method::GET)
                    .uri(format!(
                        "/worker/v1/runs/{run_id}/source/{}",
                        "a".repeat(64)
                    ))
                    .header(AUTHORIZATION, format!("{WORKER_AUTH_SCHEME} {invalid}"))
                    .header(&RUN_CREDENTIAL_HEADER, &invalid)
                    .body(Body::new(PanicOnPollBody))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn snapshot_claim_download_is_bound_to_run_node_digest_and_lease() {
        use sha2::{Digest, Sha256};

        let store = Store::in_memory().unwrap();
        let archive = b"raw snapshot archive fixture";
        let digest = format!(
            "sha256:{}",
            Sha256::digest(archive)
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect::<String>()
        );
        store
            .put_snapshot(&digest, archive.len() as u64, archive)
            .unwrap();
        let pairing = store.create_pairing().unwrap();
        let endpoint = "https://controller.example:47832";
        let node = node_from_probe(
            Some(pairing.intended_node_id),
            Some("snapshot-worker"),
            &probe(),
            endpoint,
            true,
        );
        let worker_credential = worker_credential();
        let worker_digest = credential_digest(&worker_credential);
        store
            .consume_pairing(
                &pairing.code,
                pairing.id,
                pairing.intended_node_id,
                &worker_digest,
                &node,
            )
            .unwrap();
        store
            .acknowledge_pairing(
                &worker_credential,
                pairing.id,
                pairing.intended_node_id,
                &worker_digest,
            )
            .unwrap();
        assert!(store
            .claim_job(&worker_credential, &node)
            .unwrap()
            .is_none());
        store
            .submit_job(
                &snapshot_job(digest.clone(), archive.len() as u64),
                None,
                &cyc_scheduler::Scheduler::default(),
            )
            .unwrap();
        let claim = store.claim_job(&worker_credential, &node).unwrap().unwrap();
        let app = router(state(store));
        let sha256 = cyc_protocol::snapshot_digest_hex(&digest).unwrap();
        let request_source = |requested_sha256: &str, run_credential: &str| {
            Request::builder()
                .method(Method::GET)
                .uri(format!(
                    "/worker/v1/runs/{}/source/{requested_sha256}",
                    claim.stored.run.id
                ))
                .header(AUTHORIZATION, format!("Bearer {worker_credential}"))
                .header(&RUN_CREDENTIAL_HEADER, run_credential)
                .header(&LEASE_ID_HEADER, claim.lease_id.to_string())
                .body(Body::empty())
                .unwrap()
        };

        let response = app
            .clone()
            .oneshot(request_source(sha256, &claim.run_credential))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.headers()[CONTENT_TYPE], SNAPSHOT_MEDIA_TYPE);
        assert_eq!(response.headers()[SHA256_HEADER], digest);
        let body = response.into_body().collect().await.unwrap().to_bytes();
        assert_eq!(body.as_ref(), archive);

        let response = app
            .clone()
            .oneshot(request_source(&"f".repeat(64), &claim.run_credential))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);

        let response = app
            .oneshot(request_source(sha256, &"x".repeat(64)))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn state_conflicts_return_authoritative_cancel_version_and_state() {
        let response = WorkerApiError::from(StoreError::WorkerStateConflict {
            current_version: 7,
            cancel_requested: true,
            current_state: JobState::Running,
        })
        .into_response();
        assert_eq!(response.status(), StatusCode::CONFLICT);
        let value = json_body(response).await;
        assert_eq!(value["error"]["code"], "state_conflict");
        assert_eq!(value["error"]["currentVersion"], 7);
        assert_eq!(value["error"]["cancelRequested"], true);
        assert_eq!(value["error"]["currentState"], "running");
    }

    #[tokio::test]
    async fn http_pair_claim_heartbeat_state_and_complete_round_trip() {
        let store = Store::in_memory().unwrap();
        let pairing = store.create_pairing().unwrap();
        let app = router(state(store.clone()));
        let worker_credential = worker_credential();
        let worker_digest = credential_digest(&worker_credential);
        let pair_request = PairRequest {
            pairing_id: pairing.id,
            intended_node_id: pairing.intended_node_id,
            credential_sha256: worker_digest.clone(),
            display_name: Some("managed-test".to_owned()),
            probe: probe(),
        };
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/worker/v1/pair")
                    .header(CONTENT_TYPE, "application/json")
                    .header(AUTHORIZATION, format!("Pairing {}", pairing.code))
                    .body(Body::from(serde_json::to_vec(&pair_request).unwrap()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::CREATED);
        assert_eq!(response.headers()[CACHE_CONTROL], "no-store");
        assert!(!response.headers().contains_key("x-cyc-worker-credential"));
        let pair_response: PairResponse =
            serde_json::from_value(json_body(response).await).unwrap();
        assert_eq!(pair_response.node_id, pairing.intended_node_id);
        assert_eq!(pair_response.pairing_id, pairing.id);
        assert_eq!(pair_response.credential_sha256, worker_digest);
        assert_eq!(
            store.get_pairing_status(pairing.id).unwrap().phase,
            cyc_protocol::onboarding::PairingPhaseV1::Consumed
        );
        assert!(matches!(
            store.authenticate_worker(&worker_credential),
            Err(StoreError::WorkerUnauthorized)
        ));

        let ack_request = PairAckRequest {
            api_version: WORKER_API_VERSION.to_owned(),
            pairing_id: pairing.id,
            node_id: pair_response.node_id,
            credential_sha256: worker_digest.clone(),
        };
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/worker/v1/pair/ack")
                    .header(CONTENT_TYPE, "application/json")
                    .header(AUTHORIZATION, format!("Bearer {worker_credential}"))
                    .body(Body::from(serde_json::to_vec(&ack_request).unwrap()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let ack_response: PairAckResponse =
            serde_json::from_value(json_body(response).await).unwrap();
        assert_eq!(ack_response.pairing_id, pairing.id);
        assert_eq!(
            store.authenticate_worker(&worker_credential).unwrap(),
            pair_response.node_id
        );

        let reported_node = node_from_probe(
            Some(pair_response.node_id),
            Some("managed-test"),
            &probe(),
            "https://controller.example:47832",
            true,
        );
        let mut telemetry = NodeTelemetry::from_node(&reported_node, Utc::now());
        telemetry.boot_generation = 1;
        telemetry.boot_id = Uuid::new_v4();
        telemetry.sequence = 1;
        let report = NodeReportRequest {
            api_version: WORKER_API_VERSION.to_owned(),
            inventory: Some(NodeInventory::from_node(&reported_node)),
            telemetry,
        };
        let report_request = || {
            Request::builder()
                .method(Method::POST)
                .uri("/worker/v1/node-report")
                .header(CONTENT_TYPE, "application/json")
                .header(AUTHORIZATION, format!("Bearer {worker_credential}"))
                .body(Body::from(serde_json::to_vec(&report).unwrap()))
                .unwrap()
        };
        let response = app.clone().oneshot(report_request()).await.unwrap();
        assert_eq!(response.status(), StatusCode::NO_CONTENT);
        assert_eq!(response.headers()[&NODE_REPORT_ACCEPTED_HEADER], "true");
        assert_eq!(response.headers()[&NODE_REPORT_BOOT_GENERATION_HEADER], "1");
        assert_eq!(response.headers()[&NODE_REPORT_SEQUENCE_HEADER], "1");
        let replay = app.clone().oneshot(report_request()).await.unwrap();
        assert_eq!(replay.status(), StatusCode::NO_CONTENT);
        assert_eq!(replay.headers()[&NODE_REPORT_ACCEPTED_HEADER], "false");

        let claim_request = ClaimRequest {
            probe: probe(),
            active_run_ids: Vec::new(),
        };
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/worker/v1/claim")
                    .header(CONTENT_TYPE, "application/json")
                    .header(AUTHORIZATION, format!("Bearer {worker_credential}"))
                    .body(Body::from(serde_json::to_vec(&claim_request).unwrap()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NO_CONTENT);

        store
            .submit_job(&job(), None, &cyc_scheduler::Scheduler::default())
            .unwrap();
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/worker/v1/claim")
                    .header(CONTENT_TYPE, "application/json")
                    .header(AUTHORIZATION, format!("Bearer {worker_credential}"))
                    .body(Body::from(serde_json::to_vec(&claim_request).unwrap()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert!(response.headers()[&RUN_CREDENTIAL_HEADER].is_sensitive());
        assert_eq!(response.headers()[CACHE_CONTROL], "no-store");
        let run_credential = response.headers()[&RUN_CREDENTIAL_HEADER]
            .to_str()
            .unwrap()
            .to_owned();
        let claim: ClaimResponse = serde_json::from_value(json_body(response).await).unwrap();
        let assignment = claim.assignment.unwrap();
        assert_eq!(assignment.state_version, 1);

        let heartbeat = HeartbeatRequest {
            run_id: assignment.run_id,
            lease_id: assignment.lease_id,
            expected_version: assignment.state_version,
            state: JobState::Preparing,
            probe: None,
            last_log_sequence: None,
        };
        let response = run_request(
            &worker_credential,
            &run_credential,
            &format!("/worker/v1/runs/{}/heartbeat", assignment.run_id),
            &heartbeat,
        );
        let response = app.clone().oneshot(response).await.unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let heartbeat: HeartbeatResponse =
            serde_json::from_value(json_body(response).await).unwrap();
        assert_eq!(heartbeat.current_version, 1);

        let update = StateUpdate {
            run_id: assignment.run_id,
            lease_id: assignment.lease_id,
            expected_version: 1,
            next_state: JobState::Running,
            evidence: None,
        };
        let response = app
            .clone()
            .oneshot(run_request(
                &worker_credential,
                &run_credential,
                &format!("/worker/v1/runs/{}/state", assignment.run_id),
                &update,
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let running_state: StateUpdateResponse =
            serde_json::from_value(json_body(response).await).unwrap();
        assert_eq!(running_state.state_version, 2);
        assert_eq!(running_state.run.state, JobState::Running);

        let started_at = running_state.run.started_at.unwrap();
        let now = Utc::now();
        let completion = RunCompletion {
            run_id: assignment.run_id,
            lease_id: assignment.lease_id,
            expected_version: running_state.state_version,
            final_state: JobState::Succeeded,
            evidence: RunEvidence {
                started_at: Some(started_at),
                finished_at: Some(now),
                exit_code: Some(0),
                error: None,
                artifact_ids: Vec::new(),
            },
            execution: ExecutionEvidence {
                source: ExecutionSourceEvidence {
                    kind: "git".to_owned(),
                    repository: "https://example.invalid/repository.git".to_owned(),
                    requested_revision: "0123456789abcdef0123456789abcdef01234567".to_owned(),
                    resolved_revision: "0123456789abcdef0123456789abcdef01234567".to_owned(),
                    tree: "abcdef0123456789abcdef0123456789abcdef01".to_owned(),
                    git_version: "git version 2.45.0".to_owned(),
                },
                steps: vec![StepExecutionEvidence {
                    index: 0,
                    name: "build".to_owned(),
                    shell: Shell::Bash,
                    started_at,
                    finished_at: now,
                    exit_code: Some(0),
                    termination: TerminationReason::Exited,
                }],
                streams: RunStreamsEvidence {
                    stdout: empty_stream(),
                    stderr: empty_stream(),
                },
                termination: TerminationEvidence {
                    reason: TerminationReason::Exited,
                    process_tree_terminated: true,
                    forced_kill: false,
                    root_exit_code: Some(0),
                    signal: None,
                    observed_at: now,
                },
            },
            artifacts: Vec::new(),
        };
        let response = app
            .clone()
            .oneshot(run_request(
                &worker_credential,
                &run_credential,
                &format!("/worker/v1/runs/{}/complete", assignment.run_id),
                &completion,
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let completion_sha256 = response.headers()[&COMPLETION_SHA256_HEADER]
            .to_str()
            .unwrap()
            .to_owned();
        let acknowledged_at = chrono::DateTime::parse_from_rfc3339(
            response.headers()[&COMPLETION_ACKNOWLEDGED_AT_HEADER]
                .to_str()
                .unwrap(),
        )
        .unwrap()
        .with_timezone(&Utc);
        let completed: StateUpdateResponse =
            serde_json::from_value(json_body(response).await).unwrap();
        assert_eq!(completed.run.state, JobState::Succeeded);
        assert_eq!(completed.run.exit_code, Some(0));

        // The first response may be lost after the transaction commits. The
        // original run credential is revoked at that point, but an exact
        // receipt retry must still pass the pre-body middleware and return the
        // authoritative terminal run.
        let response = app
            .clone()
            .oneshot(run_request(
                &worker_credential,
                &run_credential,
                &format!("/worker/v1/runs/{}/complete", assignment.run_id),
                &completion,
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let retry: StateUpdateResponse = serde_json::from_value(json_body(response).await).unwrap();
        assert_eq!(retry.state_version, completed.state_version);

        let receipt = cyc_protocol::CleanupReceiptV1 {
            api_version: cyc_protocol::CLEANUP_API_VERSION.to_owned(),
            run_id: assignment.run_id,
            lease_id: assignment.lease_id,
            relative_root: format!("jobs/{}", assignment.run_id),
            outcome: cyc_protocol::JobRootCleanupOutcomeV1::Removed,
            job_root_deleted: true,
            observed_at: Utc::now(),
            terminal_ack: cyc_protocol::TerminalCompletionAckV1 {
                run_id: assignment.run_id,
                lease_id: assignment.lease_id,
                completion_sha256,
                state_version: completed.state_version,
                final_state: completed.run.state,
                acknowledged_at,
            },
        };
        let response = app
            .clone()
            .oneshot(run_request(
                &worker_credential,
                &run_credential,
                &format!("/worker/v1/runs/{}/cleanup", assignment.run_id),
                &receipt,
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let stored: cyc_protocol::CleanupReceiptV1 =
            serde_json::from_value(json_body(response).await).unwrap();
        assert_eq!(stored, receipt);
        assert_eq!(
            store
                .get_cleanup(assignment.run_id)
                .unwrap()
                .unwrap()
                .receipt,
            receipt
        );

        let mut conflicting = receipt;
        conflicting.outcome = cyc_protocol::JobRootCleanupOutcomeV1::NotCreated;
        conflicting.job_root_deleted = false;
        let response = app
            .oneshot(run_request(
                &worker_credential,
                &run_credential,
                &format!("/worker/v1/runs/{}/cleanup", assignment.run_id),
                &conflicting,
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::CONFLICT);

        let user_app = crate::api::router(state(store));
        let response = user_app
            .oneshot(
                Request::builder()
                    .method(Method::GET)
                    .uri(format!("/v1/jobs/{}/cleanup", assignment.job_id))
                    .header(HOST, "127.0.0.1:47831")
                    .header(AUTHORIZATION, format!("Bearer {}", "a".repeat(64)))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let status = json_body(response).await;
        assert_eq!(status["apiVersion"], cyc_protocol::CLEANUP_API_VERSION);
        assert_eq!(status["jobId"], assignment.job_id.to_string());
        assert_eq!(status["runId"], assignment.run_id.to_string());
        assert_eq!(status["status"], "removed");
        assert_eq!(status["jobRootDeleted"], true);
        assert!(status["cleanupDeadlineAt"].is_string());
        assert!(status["reservationReleasedAt"].is_string());
        assert_eq!(status["releaseReason"], "removed_receipt");
        assert!(status.get("cleanupFailure").is_none());
        assert_eq!(
            status["terminalAck"]["completionSha256"],
            conflicting.terminal_ack.completion_sha256
        );
    }

    fn empty_stream() -> StreamEvidence {
        StreamEvidence {
            byte_count: 0,
            sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855".to_owned(),
            truncated: false,
            chunk_count: 0,
        }
    }

    fn run_request<T: Serialize>(
        worker_credential: &str,
        run_credential: &str,
        uri: &str,
        body: &T,
    ) -> Request<Body> {
        Request::builder()
            .method(Method::POST)
            .uri(uri)
            .header(HOST, "controller.example:47832")
            .header(CONTENT_TYPE, "application/json")
            .header(AUTHORIZATION, format!("Bearer {worker_credential}"))
            .header(&RUN_CREDENTIAL_HEADER, run_credential)
            .body(Body::from(serde_json::to_vec(body).unwrap()))
            .unwrap()
    }
}
