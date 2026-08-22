use std::sync::Arc;

use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use chrono::{DateTime, Utc};
use cyc_protocol::{JobSpec, Node, Run};
use cyc_scheduler::{PlacementDecision, ScheduleError, Scheduler};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::json;
use tower_http::trace::TraceLayer;
use uuid::Uuid;

use crate::store::{Store, StoreError, StoredJob};

#[derive(Clone)]
pub struct AppState {
    pub store: Store,
    pub scheduler: Arc<Scheduler>,
}

impl AppState {
    pub fn new(store: Store) -> Self {
        Self {
            store,
            scheduler: Arc::new(Scheduler::default()),
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
        .layer(TraceLayer::new_for_http())
        .with_state(state)
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
    state.store.ping()?;
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
    let nodes = state.store.list_nodes()?;
    let recent_jobs = state
        .store
        .list_jobs(20)?
        .into_iter()
        .map(JobView::from)
        .collect();
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
        recent_jobs,
    }))
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RegisterNodeRequest {
    node: Node,
}

async fn register_node(
    State(state): State<AppState>,
    bytes: Bytes,
) -> Result<(StatusCode, Json<Node>), ApiError> {
    let request: RegisterNodeRequest = parse_body(&bytes)?;
    state.store.upsert_node(&request.node)?;
    Ok((StatusCode::CREATED, Json(request.node)))
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
    created_at: DateTime<Utc>,
    decision: PlacementDecision,
}

async fn plan(State(state): State<AppState>, bytes: Bytes) -> Result<Json<PlanResponse>, ApiError> {
    let request: PlanRequest = parse_body(&bytes)?;
    request
        .job
        .validate()
        .map_err(|_| ApiError::invalid_job())?;
    let nodes = state.store.list_nodes()?;
    let decision = state
        .scheduler
        .schedule(&request.job, &nodes)
        .map_err(ApiError::schedule)?;
    let plan_id = Uuid::new_v4();
    state
        .store
        .insert_plan(plan_id, request.job.id, &decision)?;
    Ok(Json(PlanResponse {
        plan_id,
        job_id: request.job.id,
        created_at: Utc::now(),
        decision,
    }))
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
}

impl From<StoredJob> for JobView {
    fn from(value: StoredJob) -> Self {
        Self {
            job: value.job,
            run: value.run,
        }
    }
}

async fn submit_job(
    State(state): State<AppState>,
    bytes: Bytes,
) -> Result<(StatusCode, Json<JobView>), ApiError> {
    let request: SubmitJobRequest = parse_body(&bytes)?;
    request
        .job
        .validate()
        .map_err(|_| ApiError::invalid_job())?;

    let decision = if let Some(plan_id) = request.plan_id {
        let plan = state.store.get_plan(plan_id)?;
        if plan.job_id != request.job.id {
            return Err(ApiError::plan_mismatch());
        }
        plan.decision
    } else {
        let nodes = state.store.list_nodes()?;
        state
            .scheduler
            .schedule(&request.job, &nodes)
            .map_err(ApiError::schedule)?
    };

    let mut run = Run::queued(request.job.id);
    run.node_id = Some(decision.node_id);
    run.placement = Some(decision.explanation);
    state.store.insert_job(&request.job, &run)?;
    Ok((
        StatusCode::CREATED,
        Json(JobView {
            job: request.job,
            run,
        }),
    ))
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct JobListResponse {
    jobs: Vec<JobView>,
}

async fn list_jobs(State(state): State<AppState>) -> Result<Json<JobListResponse>, ApiError> {
    let jobs = state
        .store
        .list_jobs(100)?
        .into_iter()
        .map(JobView::from)
        .collect();
    Ok(Json(JobListResponse { jobs }))
}

async fn get_job(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<Json<JobView>, ApiError> {
    Ok(Json(state.store.get_job(id)?.into()))
}

async fn cancel_job(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<Json<JobView>, ApiError> {
    Ok(Json(state.store.cancel_job(id)?.into()))
}

fn parse_body<T: DeserializeOwned>(bytes: &[u8]) -> Result<T, ApiError> {
    // Deliberately discard serde's detailed message. It may contain a value
    // supplied by an untrusted caller; request bodies are never logged or echoed.
    serde_json::from_slice(bytes).map_err(|_| ApiError::invalid_request())
}

#[derive(Debug)]
struct ApiError {
    status: StatusCode,
    code: &'static str,
    message: &'static str,
    details: Option<serde_json::Value>,
}

impl ApiError {
    fn invalid_request() -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            code: "invalid_request",
            message: "request body is invalid",
            details: None,
        }
    }

    fn invalid_job() -> Self {
        Self {
            status: StatusCode::UNPROCESSABLE_ENTITY,
            code: "invalid_job",
            message: "job validation failed",
            details: None,
        }
    }

    fn schedule(error: ScheduleError) -> Self {
        match error {
            ScheduleError::InvalidJob(_) => Self::invalid_job(),
            ScheduleError::NoEligibleNodes { explanation } => Self {
                status: StatusCode::CONFLICT,
                code: "no_eligible_node",
                message: "no compatible worker is currently available",
                details: serde_json::to_value(explanation).ok(),
            },
        }
    }

    fn plan_mismatch() -> Self {
        Self {
            status: StatusCode::CONFLICT,
            code: "plan_mismatch",
            message: "plan does not belong to this job",
            details: None,
        }
    }
}

impl From<StoreError> for ApiError {
    fn from(error: StoreError) -> Self {
        match error {
            StoreError::NotFound => Self {
                status: StatusCode::NOT_FOUND,
                code: "not_found",
                message: "requested resource was not found",
                details: None,
            },
            StoreError::Conflict => Self {
                status: StatusCode::CONFLICT,
                code: "conflict",
                message: "job already exists",
                details: None,
            },
            StoreError::InvalidTransition => Self {
                status: StatusCode::CONFLICT,
                code: "invalid_state_transition",
                message: "job cannot be cancelled from its current state",
                details: None,
            },
            StoreError::Database(_)
            | StoreError::Document(_)
            | StoreError::Identifier(_)
            | StoreError::Poisoned => {
                tracing::error!(error = %error, "controller storage failure");
                Self {
                    status: StatusCode::INTERNAL_SERVER_ERROR,
                    code: "internal_error",
                    message: "controller storage operation failed",
                    details: None,
                }
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
        if let Some(details) = self.details {
            error["details"] = details;
        }
        (self.status, Json(json!({ "error": error }))).into_response()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::Request;
    use cyc_protocol::{
        Architecture, JobKind, JobStep, NodeResources, NodeStatus, NodeTransport, OperatingSystem,
        SourceSpec,
    };
    use http_body_util::BodyExt;
    use tower::ServiceExt;

    fn test_app() -> Router {
        router(AppState::new(Store::in_memory().unwrap()))
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

    #[tokio::test]
    async fn health_reports_database_status() {
        let response = test_app()
            .oneshot(
                Request::builder()
                    .uri("/v1/health")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let body = response.into_body().collect().await.unwrap().to_bytes();
        let value: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(value["status"], "ok");
        assert_eq!(value["database"], "ok");
    }

    #[tokio::test]
    async fn malformed_requests_do_not_reflect_secrets() {
        let marker = "correct-horse-battery-staple";
        let response = test_app()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/jobs")
                    .header("content-type", "application/json")
                    .body(Body::from(format!(r#"{{"password":"{marker}"}}"#)))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        let body = response.into_body().collect().await.unwrap().to_bytes();
        let text = String::from_utf8_lossy(&body);
        assert!(!text.contains(marker));
        assert!(!text.to_ascii_lowercase().contains("password"));
    }

    #[tokio::test]
    async fn planning_failure_keeps_scheduler_explanation() {
        let job = build_job();
        let response = test_app()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/plans")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        serde_json::to_vec(&json!({ "job": job })).unwrap(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::CONFLICT);
        let body = response.into_body().collect().await.unwrap().to_bytes();
        let value: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(value["error"]["code"], "no_eligible_node");
        assert_eq!(value["error"]["details"]["policy"], "balanced");
        assert_eq!(
            value["error"]["details"]["candidates"]
                .as_array()
                .unwrap()
                .len(),
            0
        );
    }

    #[tokio::test]
    async fn registers_a_node_and_submits_a_scheduled_job() {
        let app = test_app();
        let node = online_node();
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/nodes")
                    .header("content-type", "application/json")
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
                Request::builder()
                    .method("POST")
                    .uri("/v1/jobs")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        serde_json::to_vec(&json!({ "job": job })).unwrap(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::CREATED);
        let body = response.into_body().collect().await.unwrap().to_bytes();
        let value: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(value["run"]["jobId"], job.id.to_string());
        assert_eq!(value["run"]["nodeId"], node.id.to_string());
        assert_eq!(value["run"]["state"], "queued");

        let response = app
            .oneshot(
                Request::builder()
                    .uri("/v1/fleet")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let body = response.into_body().collect().await.unwrap().to_bytes();
        let value: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(value["nodes"].as_array().unwrap().len(), 1);
        assert_eq!(value["recentJobs"].as_array().unwrap().len(), 1);
    }
}
