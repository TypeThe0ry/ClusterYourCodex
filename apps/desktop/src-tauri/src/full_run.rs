use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, OpenOptions};
use std::io::{Cursor, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, TryLockError};
use std::thread;
use std::time::{Duration, Instant};

use chrono::{DateTime, SecondsFormat, Utc};
#[cfg(test)]
use cyc_protocol::TerminalCompletionAckV1;
use cyc_protocol::{
    Architecture, ArtifactSpec, CleanupFailureCodeV1, CleanupReservationReleaseReasonV1,
    CleanupStatusPhaseV1, CleanupStatusV1, JobKind, JobSpec, JobState, JobStep, Node, NodeStatus,
    NodeTransport, OperatingSystem, PlacementExplain, PlacementPlanBindingV1, PlacementPolicy, Run,
    Shell, SmokeRunBindingV1, SnapshotMetadataV1, SourceSpec, CLEANUP_API_VERSION,
    SNAPSHOT_API_VERSION, SNAPSHOT_ARCHIVE_FORMAT, SNAPSHOT_MEDIA_TYPE,
};
use reqwest::blocking::{Client as BlockingClient, RequestBuilder, Response as BlockingResponse};
use reqwest::header::{HeaderValue, ACCEPT, AUTHORIZATION, CONTENT_LENGTH, CONTENT_TYPE, IF_MATCH};
use reqwest::{Method, StatusCode};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;
use zeroize::Zeroizing;

use super::integration::{
    ActiveRuntimeIdentity, IntegrationError, IntegrationManager, SelfTestExecutorIdentity,
};
use super::{load_token, CONTROLLER_ORIGIN};

const CONTROLLER_CONNECT_TIMEOUT: Duration = Duration::from_secs(2);
const CONTROLLER_REQUEST_TIMEOUT: Duration = Duration::from_secs(10);
const FULL_RUN_TIMEOUT: Duration = Duration::from_secs(120);
const PROVISIONING_SMOKE_TIMEOUT: Duration = Duration::from_secs(90);
const POLL_INTERVAL: Duration = Duration::from_millis(500);
const FRESH_HEARTBEAT_AGE: chrono::Duration = chrono::Duration::seconds(15);
const MAX_CLOCK_SKEW: chrono::Duration = chrono::Duration::seconds(30);
const MAX_JSON_RESPONSE_BYTES: usize = 2 * 1024 * 1024;
const MAX_LOG_RESPONSE_BYTES: usize = 2 * 1024 * 1024;
const MAX_PROOF_RESPONSE_BYTES: usize = 1024 * 1024;
const MAX_MCP_FIXTURE_ARCHIVE_BYTES: usize = 64 * 1024;
const MAX_JSON_SAFE_INTEGER_U64: u64 = 9_007_199_254_740_991;
const MCP_PIPELINE_TIMEOUT: Duration = Duration::from_secs(75);
const MCP_TOOL_TIMEOUT: Duration = Duration::from_secs(15);
const SNAPSHOT_INPUT: &[u8] = b"ClusterYourCodex full run check\n";
const SNAPSHOT_STDOUT_PROOF: &[u8] = b"ClusterYourCodex full run check";
const STDOUT_PROOF: &[u8] = b"CYC_FULL_RUN_EXECUTED";
const STDERR_PROOF: &[u8] = b"CYC_FULL_RUN_STDERR";
const ARTIFACT_NAME: &str = "full-run-proof.txt";
#[cfg(test)]
const ARTIFACT_PROOF: &[u8] = b"CYC_FULL_RUN_OK\n";
const ARTIFACT_PROOF_TEXT: &str = "CYC_FULL_RUN_OK";
const MAX_ARTIFACT_PROOF_BYTES: u64 = 128;

const LAYER_PLUGIN: &str = "plugin_check";
const LAYER_HEARTBEAT: &str = "fresh_heartbeat";
const LAYER_SNAPSHOT: &str = "source_snapshot";
const LAYER_SELECTION: &str = "worker_selection";
const LAYER_EXECUTION: &str = "remote_execution";
const LAYER_LOGS: &str = "log_verification";
const LAYER_ARTIFACT: &str = "artifact_verification";
const LAYER_CLEANUP: &str = "cleanup";

const LAYERS: [(&str, &str); 8] = [
    (LAYER_PLUGIN, "Waiting for the Codex plugin check."),
    (
        LAYER_HEARTBEAT,
        "Waiting for a fresh managed-worker heartbeat.",
    ),
    (
        LAYER_SNAPSHOT,
        "Waiting to package and upload the source snapshot.",
    ),
    (
        LAYER_SELECTION,
        "Waiting for a real controller placement plan.",
    ),
    (
        LAYER_EXECUTION,
        "Waiting for the selected worker to claim and execute the job.",
    ),
    (LAYER_LOGS, "Waiting to download and verify remote logs."),
    (
        LAYER_ARTIFACT,
        "Waiting to download and verify the returned artifact.",
    ),
    (LAYER_CLEANUP, "Waiting for terminal-state cleanup."),
];

#[derive(Clone)]
pub(crate) struct FullRunCheckManager {
    inner: Arc<FullRunCheckManagerInner>,
}

struct FullRunCheckManagerInner {
    client: BlockingClient,
    token_file: PathBuf,
    operation_lock: Mutex<()>,
    // This deliberately does not share the operation mutex.  The Tauri bridge
    // must be able to poll an in-flight check while `run` owns the long-lived
    // single-operation guard.
    progress: Mutex<Option<FullRunCheckResult>>,
}

impl FullRunCheckManager {
    pub(crate) fn new(token_file: PathBuf) -> Result<Self, FullRunInitializationError> {
        let client = BlockingClient::builder()
            .connect_timeout(CONTROLLER_CONNECT_TIMEOUT)
            .timeout(CONTROLLER_REQUEST_TIMEOUT)
            .redirect(reqwest::redirect::Policy::none())
            .no_proxy()
            .build()
            .map_err(|_| FullRunInitializationError::ControllerClient)?;
        Ok(Self {
            inner: Arc::new(FullRunCheckManagerInner {
                client,
                token_file,
                operation_lock: Mutex::new(()),
                progress: Mutex::new(None),
            }),
        })
    }

    pub(crate) fn progress(&self) -> Option<FullRunCheckResult> {
        self.inner
            .progress
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    fn publish(&self, result: &FullRunCheckResult) {
        *self
            .inner
            .progress
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(result.clone());
    }

    pub(crate) fn run(
        &self,
        integration: &IntegrationManager,
    ) -> Result<FullRunCheckResult, PublicFullRunCheckError> {
        let _guard = match self.inner.operation_lock.try_lock() {
            Ok(guard) => guard,
            Err(TryLockError::WouldBlock) => {
                return Err(PublicFullRunCheckError {
                    code: "full_run_check_busy",
                })
            }
            Err(TryLockError::Poisoned(_)) => {
                return Err(PublicFullRunCheckError {
                    code: "full_run_check_unavailable",
                })
            }
        };
        let backend = HttpFullRunBackend {
            inner: &self.inner,
            integration: Some(integration),
        };
        Ok(execute_full_run_with_progress(
            &backend,
            integration,
            FULL_RUN_TIMEOUT,
            &|result| self.publish(result),
        ))
    }

    pub(crate) fn prepare_node_smoke(
        &self,
        node_id: Uuid,
        operation_id: &str,
        job_id: Uuid,
    ) -> Result<SmokeRunBindingV1, NodeSmokeError> {
        let _guard = self
            .inner
            .operation_lock
            .lock()
            .map_err(|_| NodeSmokeError::new("SMOKE_OPERATION_UNAVAILABLE", false))?;
        let backend = HttpFullRunBackend {
            inner: &self.inner,
            integration: None,
        };
        prepare_node_smoke(&backend, node_id, operation_id, job_id)
    }

    pub(crate) fn run_node_smoke(
        &self,
        binding: &SmokeRunBindingV1,
    ) -> Result<DateTime<Utc>, NodeSmokeError> {
        let _guard = self
            .inner
            .operation_lock
            .lock()
            .map_err(|_| NodeSmokeError::new("SMOKE_OPERATION_UNAVAILABLE", false))?;
        let backend = HttpFullRunBackend {
            inner: &self.inner,
            integration: None,
        };
        execute_bound_node_smoke(&backend, binding, PROVISIONING_SMOKE_TIMEOUT)
    }
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum FullRunInitializationError {
    #[error("full run controller client initialization failed")]
    ControllerClient,
}

#[derive(Clone, Debug)]
pub(crate) struct NodeSmokeError {
    pub(crate) code: String,
    pub(crate) retryable: bool,
}

impl NodeSmokeError {
    fn new(code: impl Into<String>, retryable: bool) -> Self {
        Self {
            code: code.into(),
            retryable,
        }
    }
}

impl From<BackendFailure> for NodeSmokeError {
    fn from(value: BackendFailure) -> Self {
        // Provisioning failure codes are deliberately restricted to a
        // log-safe uppercase alphabet. Preserve the backend's stable semantic
        // name while adapting it at this internal boundary.
        Self::new(value.code.to_ascii_uppercase(), value.retryable)
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct PublicFullRunCheckError {
    code: &'static str,
}

impl PublicFullRunCheckError {
    pub(crate) const fn operation_unavailable() -> Self {
        Self {
            code: "full_run_check_unavailable",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum FullRunState {
    Running,
    Passed,
    Failed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum LayerState {
    Pending,
    Running,
    Passed,
    Failed,
    Skipped,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct FullRunLayer {
    id: &'static str,
    state: LayerState,
    message: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct FullRunFailure {
    code: &'static str,
    retryable: bool,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct SelectedNodeEvidence {
    id: String,
    name: String,
    operating_system: &'static str,
    architecture: &'static str,
    heartbeat_at: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ManagedTransportEvidence {
    transport: &'static str,
    endpoint: String,
    tls: bool,
    credential_reference_present: bool,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ActiveRuntimeEvidence {
    pid: u32,
    started_at: String,
    bridge_version: String,
    initial_receipt_verified_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    final_receipt_verified_at: Option<String>,
    reverified_after_run: bool,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct SelfTestExecutorEvidence {
    pid: u32,
    started_at: String,
    bridge_version: String,
    session_id: String,
    initialize_completed: bool,
    tools_list_completed: bool,
    controller_round_trip_at: String,
    mcp_tools_exercised: Vec<&'static str>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct IntegrationEvidence {
    active_runtime: ActiveRuntimeEvidence,
    #[serde(skip_serializing_if = "Option::is_none")]
    self_test_executor: Option<SelfTestExecutorEvidence>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct SnapshotEvidence {
    digest: String,
    size_bytes: u64,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct JobEvidence {
    job_id: String,
    run_id: String,
    state: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    exit_code: Option<i32>,
    observed_states: Vec<&'static str>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct PlacementEvidence {
    plan_id: String,
    job_digest: String,
    score: i64,
    fleet_revision: i64,
    node_revision: i64,
    policy_revision: i64,
    explanation: PlacementExplain,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct FinalFleetEvidence {
    fleet_revision: u64,
    observed_at: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct LogEvidence {
    stream: String,
    size_bytes: u64,
    sha256: String,
    chunk_count: usize,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ArtifactEvidence {
    id: String,
    name: String,
    size_bytes: u64,
    sha256: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct CleanupEvidence {
    job_id: String,
    run_id: String,
    relative_root: String,
    status: &'static str,
    job_root_deleted: bool,
    terminal_state_version: u64,
    terminal_acknowledged_at: String,
    observed_at: String,
    received_at: String,
    reservation_released_at: String,
    release_reason: &'static str,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct FullRunCheckResult {
    state: FullRunState,
    layers: Vec<FullRunLayer>,
    started_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    finished_at: Option<String>,
    duration_ms: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    failure: Option<FullRunFailure>,
    #[serde(skip_serializing_if = "Option::is_none")]
    integration: Option<IntegrationEvidence>,
    #[serde(skip_serializing_if = "Option::is_none")]
    selected_node: Option<SelectedNodeEvidence>,
    #[serde(skip_serializing_if = "Option::is_none")]
    transport: Option<ManagedTransportEvidence>,
    #[serde(skip_serializing_if = "Option::is_none")]
    snapshot: Option<SnapshotEvidence>,
    #[serde(skip_serializing_if = "Option::is_none")]
    job: Option<JobEvidence>,
    #[serde(skip_serializing_if = "Option::is_none")]
    placement: Option<PlacementEvidence>,
    #[serde(skip_serializing_if = "Option::is_none")]
    final_fleet: Option<FinalFleetEvidence>,
    logs: Vec<LogEvidence>,
    artifacts: Vec<ArtifactEvidence>,
    #[serde(skip_serializing_if = "Option::is_none")]
    cleanup: Option<CleanupEvidence>,
}

impl FullRunCheckResult {
    fn pending(started_at: DateTime<Utc>) -> Self {
        Self {
            state: FullRunState::Running,
            layers: LAYERS
                .into_iter()
                .map(|(id, message)| FullRunLayer {
                    id,
                    state: LayerState::Pending,
                    message: message.to_owned(),
                })
                .collect(),
            started_at: timestamp(started_at),
            finished_at: None,
            duration_ms: 0,
            failure: None,
            integration: None,
            selected_node: None,
            transport: None,
            snapshot: None,
            job: None,
            placement: None,
            final_fleet: None,
            logs: Vec::new(),
            artifacts: Vec::new(),
            cleanup: None,
        }
    }

    fn layer_mut(&mut self, id: &'static str) -> &mut FullRunLayer {
        self.layers
            .iter_mut()
            .find(|layer| layer.id == id)
            .expect("constant full-run layer exists")
    }

    fn begin(&mut self, id: &'static str, message: impl Into<String>) {
        let layer = self.layer_mut(id);
        layer.state = LayerState::Running;
        layer.message = message.into();
    }

    fn pass(&mut self, id: &'static str, message: impl Into<String>) {
        let layer = self.layer_mut(id);
        layer.state = LayerState::Passed;
        layer.message = message.into();
    }

    fn fail(&mut self, failure: WorkflowFailure) {
        let layer = self.layer_mut(failure.layer);
        layer.state = LayerState::Failed;
        layer.message = failure.message.to_owned();
        self.failure = Some(FullRunFailure {
            code: failure.code,
            retryable: failure.retryable,
        });
        for pending in &mut self.layers {
            if pending.state == LayerState::Pending && pending.id != LAYER_CLEANUP {
                pending.state = LayerState::Skipped;
                pending.message = "Skipped after an earlier layer failed.".to_owned();
            }
        }
    }

    fn finish(&mut self, started: Instant, state: FullRunState) {
        self.state = state;
        self.finished_at = Some(timestamp(Utc::now()));
        self.duration_ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
    }

    fn update_elapsed(&mut self, started: Instant) {
        self.duration_ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
    }
}

#[derive(Clone, Copy, Debug)]
struct BackendFailure {
    code: &'static str,
    retryable: bool,
}

impl BackendFailure {
    const fn new(code: &'static str, retryable: bool) -> Self {
        Self { code, retryable }
    }
}

#[derive(Clone, Copy, Debug)]
struct WorkflowFailure {
    layer: &'static str,
    code: &'static str,
    retryable: bool,
    message: &'static str,
}

impl WorkflowFailure {
    const fn new(
        layer: &'static str,
        code: &'static str,
        retryable: bool,
        message: &'static str,
    ) -> Self {
        Self {
            layer,
            code,
            retryable,
            message,
        }
    }

    const fn backend(layer: &'static str, failure: BackendFailure, message: &'static str) -> Self {
        Self::new(layer, failure.code, failure.retryable, message)
    }
}

trait PluginProbe {
    fn active_runtime(&self) -> Result<Option<ActiveRuntimeIdentity>, BackendFailure>;
    fn wait_for_runtime_refresh(
        &self,
        expected: &ActiveRuntimeIdentity,
        after: DateTime<Utc>,
    ) -> Result<bool, BackendFailure>;
}

impl PluginProbe for IntegrationManager {
    fn active_runtime(&self) -> Result<Option<ActiveRuntimeIdentity>, BackendFailure> {
        self.connected_runtime_identity()
            .map_err(|_| BackendFailure::new("plugin_status_failed", false))
    }

    fn wait_for_runtime_refresh(
        &self,
        expected: &ActiveRuntimeIdentity,
        after: DateTime<Utc>,
    ) -> Result<bool, BackendFailure> {
        IntegrationManager::wait_for_runtime_refresh(self, expected, after)
            .map_err(|_| BackendFailure::new("plugin_status_failed", false))
    }
}

trait FullRunBackend {
    fn fleet(&self) -> Result<FleetResponse, BackendFailure>;
    fn mcp_full_run_pipeline(
        &self,
        job_id: Uuid,
        timeout: Duration,
    ) -> Result<McpFullRunReceipt, McpPipelineFailure>;
    fn upload_snapshot(
        &self,
        snapshot: &SnapshotPayload,
    ) -> Result<SnapshotMetadataV1, BackendFailure>;
    fn plan(&self, job: &JobSpec) -> Result<PlanResponse, BackendFailure>;
    fn submit(&self, job: &JobSpec, plan_id: Uuid) -> Result<JobView, BackendFailure>;
    fn get_job_optional(&self, job_id: Uuid) -> Result<Option<JobView>, BackendFailure>;
    fn get_job(&self, job_id: Uuid) -> Result<JobView, BackendFailure>;
    fn cancel(&self, job_id: Uuid, version: u64) -> Result<JobView, BackendFailure>;
    fn list_logs(&self, job_id: Uuid) -> Result<JobLogsResponse, BackendFailure>;
    fn download_log(&self, job_id: Uuid, stream: &str) -> Result<Vec<u8>, BackendFailure>;
    fn list_artifacts(&self, job_id: Uuid) -> Result<JobArtifactsResponse, BackendFailure>;
    fn download_artifact(&self, job_id: Uuid, artifact_id: Uuid)
        -> Result<Vec<u8>, BackendFailure>;
    fn cleanup_receipt(&self, job_id: Uuid) -> Result<CleanupStatusV1, BackendFailure>;
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct FleetResponse {
    fleet_revision: u64,
    observed_at: DateTime<Utc>,
    nodes: Vec<Node>,
}

fn validate_fleet_response(
    fleet: &FleetResponse,
    now: DateTime<Utc>,
) -> Result<(), BackendFailure> {
    if fleet.fleet_revision > MAX_JSON_SAFE_INTEGER_U64
        || fleet.observed_at > now + MAX_CLOCK_SKEW
        || fleet.nodes.len() > 10_000
    {
        return Err(BackendFailure::new("fleet_snapshot_invalid", false));
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum McpPipelineStage {
    Info,
    Pack,
    Upload,
    PlanSubmit,
    Job,
}

#[derive(Clone, Debug)]
struct McpPipelineFailure {
    stage: McpPipelineStage,
    failure: BackendFailure,
    cleanup_target: Option<CleanupTarget>,
}

impl McpPipelineFailure {
    const fn new(stage: McpPipelineStage, code: &'static str, retryable: bool) -> Self {
        Self {
            stage,
            failure: BackendFailure::new(code, retryable),
            cleanup_target: None,
        }
    }

    const fn integration(stage: McpPipelineStage) -> Self {
        Self::new(stage, "plugin_mcp_pipeline_failed", false)
    }
}

#[derive(Debug)]
enum McpOperationError {
    Integration(IntegrationError),
    Pipeline(McpPipelineFailure),
}

impl From<IntegrationError> for McpOperationError {
    fn from(value: IntegrationError) -> Self {
        Self::Integration(value)
    }
}

impl From<McpPipelineFailure> for McpOperationError {
    fn from(value: McpPipelineFailure) -> Self {
        Self::Pipeline(value)
    }
}

#[derive(Clone, Debug)]
struct McpFullRunReceipt {
    executor: SelfTestExecutorIdentity,
    snapshot: SnapshotPayload,
    descriptor: PackedSnapshotDescriptor,
    metadata: SnapshotMetadataV1,
    job: JobSpec,
    plan: PlanResponse,
    submission: JobView,
    initial_job: JobView,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PackedSnapshotDescriptor {
    api_version: String,
    format: String,
    digest: String,
    size_bytes: u64,
    archive_path: PathBuf,
    file_count: u64,
    expanded_size_bytes: u64,
    skipped_count: u64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct McpPlanSubmitResponse {
    plan: PlanResponse,
    submission: JobView,
}

type PlanResponse = PlacementPlanBindingV1;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct JobView {
    job: JobSpec,
    run: Run,
    version: u64,
    cancel_requested: bool,
    #[serde(default)]
    plan_binding: Option<PlacementPlanBindingV1>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct JobLogsResponse {
    chunks: Vec<LogChunk>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LogChunk {
    run_id: Uuid,
    stream: String,
    offset: u64,
    length: u64,
    sha256: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct JobArtifactsResponse {
    artifacts: Vec<ArtifactMetadata>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ArtifactMetadata {
    id: Uuid,
    run_id: Uuid,
    name: String,
    size: u64,
    sha256: String,
}

#[derive(Clone, Debug)]
struct SnapshotPayload {
    bytes: Vec<u8>,
    digest: String,
}

impl SnapshotPayload {
    fn size_bytes(&self) -> u64 {
        u64::try_from(self.bytes.len()).unwrap_or(u64::MAX)
    }

    fn digest_hex(&self) -> &str {
        self.digest
            .strip_prefix("sha256:")
            .expect("locally generated snapshot digest has a prefix")
    }
}

/// A job-owned, secret-free fixture directory used only for the installed MCP
/// pipeline. Cleanup removes only the two exact files and two exact
/// directories created here; it never recursively follows a path returned by
/// the plugin.
struct McpFixture {
    root: PathBuf,
    workspace: PathBuf,
    input: PathBuf,
    archive: PathBuf,
}

impl McpFixture {
    fn create() -> Result<Self, McpPipelineFailure> {
        let base = std::env::temp_dir()
            .join("ClusterYourCodex")
            .join("full-run-check");
        fs::create_dir_all(&base).map_err(|_| {
            McpPipelineFailure::new(McpPipelineStage::Pack, "snapshot_fixture_failed", false)
        })?;
        let root = (0..8)
            .find_map(|_| {
                let candidate = base.join(Uuid::new_v4().to_string());
                fs::create_dir(&candidate).ok().map(|()| candidate)
            })
            .ok_or_else(|| {
                McpPipelineFailure::new(McpPipelineStage::Pack, "snapshot_fixture_failed", false)
            })?;
        let workspace = root.join("workspace");
        let input = workspace.join("input.txt");
        let archive = root.join("fixture.tar.zst");
        let created = (|| {
            fs::create_dir(&workspace)?;
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&input)?;
            file.write_all(SNAPSHOT_INPUT)?;
            file.sync_all()?;
            Ok::<(), std::io::Error>(())
        })();
        if created.is_err() {
            let _ = fs::remove_file(&input);
            let _ = fs::remove_dir(&workspace);
            let _ = fs::remove_dir(&root);
            return Err(McpPipelineFailure::new(
                McpPipelineStage::Pack,
                "snapshot_fixture_failed",
                false,
            ));
        }
        Ok(Self {
            root,
            workspace,
            input,
            archive,
        })
    }

    fn workspace_argument(&self) -> Result<&str, McpPipelineFailure> {
        self.workspace.to_str().ok_or_else(|| {
            McpPipelineFailure::new(McpPipelineStage::Pack, "snapshot_fixture_failed", false)
        })
    }

    fn archive_argument(&self) -> Result<&str, McpPipelineFailure> {
        self.archive.to_str().ok_or_else(|| {
            McpPipelineFailure::new(McpPipelineStage::Pack, "snapshot_fixture_failed", false)
        })
    }
}

impl Drop for McpFixture {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.archive);
        let _ = fs::remove_file(&self.input);
        let _ = fs::remove_dir(&self.workspace);
        let _ = fs::remove_dir(&self.root);
    }
}

#[derive(Clone, Copy, Debug)]
struct CleanupTarget {
    job_id: Uuid,
    run_id: Uuid,
    version: u64,
    state: JobState,
}

fn cleanup_target_from_untrusted(view: &JobView, expected_job_id: Uuid) -> Option<CleanupTarget> {
    (view.job.id == expected_job_id && view.run.job_id == expected_job_id && !view.run.id.is_nil())
        .then_some(CleanupTarget {
            job_id: expected_job_id,
            run_id: view.run.id,
            version: view.version,
            state: view.run.state,
        })
}

enum ValidatedCleanup {
    Pending,
    Removed(DateTime<Utc>),
}

fn validate_success_cleanup(
    receipt: &CleanupStatusV1,
    expected_job_id: Uuid,
    expected_run_id: Uuid,
    expected_state_version: u64,
) -> Result<ValidatedCleanup, BackendFailure> {
    if receipt.api_version != CLEANUP_API_VERSION
        || receipt.job_id != expected_job_id
        || receipt.run_id != expected_run_id
    {
        return Err(BackendFailure::new(
            "worker_cleanup_receipt_mismatch",
            false,
        ));
    }
    let expected_relative_root = format!("jobs/{expected_run_id}");
    if receipt.relative_root.as_deref() != Some(expected_relative_root.as_str()) {
        return Err(BackendFailure::new("worker_cleanup_receipt_invalid", false));
    }
    let terminal_ack = receipt
        .terminal_ack
        .as_ref()
        .ok_or_else(|| BackendFailure::new("worker_cleanup_receipt_invalid", false))?;
    if terminal_ack.validate().is_err()
        || terminal_ack.run_id != expected_run_id
        || terminal_ack.state_version != expected_state_version
        || terminal_ack.final_state != JobState::Succeeded
    {
        return Err(BackendFailure::new("worker_cleanup_receipt_invalid", false));
    }

    if receipt
        .cleanup_deadline_at
        .is_some_and(|deadline| deadline < terminal_ack.acknowledged_at)
        || receipt
            .reservation_released_at
            .is_some_and(|released| released < terminal_ack.acknowledged_at)
    {
        return Err(BackendFailure::new("worker_cleanup_receipt_invalid", false));
    }
    match receipt.release_reason {
        None => {
            if receipt.reservation_released_at.is_some() || receipt.cleanup_failure.is_some() {
                return Err(BackendFailure::new("worker_cleanup_receipt_invalid", false));
            }
        }
        Some(CleanupReservationReleaseReasonV1::RemovedReceipt) => {
            if receipt.status != CleanupStatusPhaseV1::Removed
                || receipt.reservation_released_at.is_none()
                || receipt.cleanup_failure.is_some()
            {
                return Err(BackendFailure::new("worker_cleanup_receipt_invalid", false));
            }
        }
        Some(CleanupReservationReleaseReasonV1::DeadlineRecovery) => {
            let valid_failure = receipt.cleanup_failure.as_ref().is_some_and(|failure| {
                failure.code == CleanupFailureCodeV1::RemovedReceiptDeadlineExceeded
                    && receipt
                        .cleanup_deadline_at
                        .is_some_and(|deadline| failure.observed_at >= deadline)
            });
            if receipt.status != CleanupStatusPhaseV1::Pending
                || receipt.reservation_released_at.is_none()
                || !valid_failure
            {
                return Err(BackendFailure::new("worker_cleanup_receipt_invalid", false));
            }
        }
        Some(CleanupReservationReleaseReasonV1::LegacyMigration) => {
            if receipt.status != CleanupStatusPhaseV1::Pending
                || receipt.reservation_released_at.is_none()
                || receipt.cleanup_failure.as_ref().is_none_or(|failure| {
                    failure.code != CleanupFailureCodeV1::LegacyReleaseWithoutCleanupEvidence
                })
            {
                return Err(BackendFailure::new("worker_cleanup_receipt_invalid", false));
            }
        }
    }

    match receipt.status {
        CleanupStatusPhaseV1::Pending => {
            if receipt.job_root_deleted
                || receipt.observed_at.is_some()
                || receipt.received_at.is_some()
                || receipt.release_reason == Some(CleanupReservationReleaseReasonV1::RemovedReceipt)
            {
                return Err(BackendFailure::new("worker_cleanup_receipt_invalid", false));
            }
            Ok(ValidatedCleanup::Pending)
        }
        CleanupStatusPhaseV1::Removed => {
            let observed_at = receipt
                .observed_at
                .ok_or_else(|| BackendFailure::new("worker_cleanup_receipt_invalid", false))?;
            let received_at = receipt
                .received_at
                .ok_or_else(|| BackendFailure::new("worker_cleanup_receipt_invalid", false))?;
            if !receipt.job_root_deleted
                || observed_at < terminal_ack.acknowledged_at
                || received_at < terminal_ack.acknowledged_at
                || receipt.release_reason != Some(CleanupReservationReleaseReasonV1::RemovedReceipt)
            {
                return Err(BackendFailure::new("worker_cleanup_receipt_invalid", false));
            }
            Ok(ValidatedCleanup::Removed(observed_at))
        }
        CleanupStatusPhaseV1::NotCreated => {
            Err(BackendFailure::new("worker_cleanup_receipt_invalid", false))
        }
    }
}

fn managed_transport_evidence(node: &Node) -> Result<ManagedTransportEvidence, WorkflowFailure> {
    let NodeTransport::Managed {
        endpoint,
        credential_ref,
    } = &node.transport
    else {
        return Err(WorkflowFailure::new(
            LAYER_SELECTION,
            "managed_transport_required",
            false,
            "The selected worker was not bound to the managed-worker transport.",
        ));
    };
    let parsed = reqwest::Url::parse(endpoint).map_err(|_| {
        WorkflowFailure::new(
            LAYER_SELECTION,
            "managed_transport_security_invalid",
            false,
            "The selected managed-worker endpoint was not a valid HTTPS URL.",
        )
    })?;
    if parsed.scheme() != "https"
        || parsed.host_str().is_none()
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.query().is_some()
        || parsed.fragment().is_some()
        || credential_ref.as_str().trim().is_empty()
    {
        return Err(WorkflowFailure::new(
            LAYER_SELECTION,
            "managed_transport_security_invalid",
            false,
            "The selected managed-worker endpoint lacked TLS or its per-node credential reference.",
        ));
    }
    Ok(ManagedTransportEvidence {
        transport: "managed_https",
        endpoint: endpoint.clone(),
        tls: true,
        credential_reference_present: true,
    })
}

fn removed_cleanup_evidence(receipt: &CleanupStatusV1) -> Result<CleanupEvidence, BackendFailure> {
    let relative_root = receipt
        .relative_root
        .clone()
        .ok_or_else(|| BackendFailure::new("worker_cleanup_receipt_invalid", false))?;
    let terminal_ack = receipt
        .terminal_ack
        .as_ref()
        .ok_or_else(|| BackendFailure::new("worker_cleanup_receipt_invalid", false))?;
    let observed_at = receipt
        .observed_at
        .ok_or_else(|| BackendFailure::new("worker_cleanup_receipt_invalid", false))?;
    let received_at = receipt
        .received_at
        .ok_or_else(|| BackendFailure::new("worker_cleanup_receipt_invalid", false))?;
    let reservation_released_at = receipt
        .reservation_released_at
        .ok_or_else(|| BackendFailure::new("worker_cleanup_receipt_invalid", false))?;
    if receipt.status != CleanupStatusPhaseV1::Removed
        || receipt.release_reason != Some(CleanupReservationReleaseReasonV1::RemovedReceipt)
        || !receipt.job_root_deleted
    {
        return Err(BackendFailure::new("worker_cleanup_receipt_invalid", false));
    }
    Ok(CleanupEvidence {
        job_id: receipt.job_id.to_string(),
        run_id: receipt.run_id.to_string(),
        relative_root,
        status: "removed",
        job_root_deleted: true,
        terminal_state_version: terminal_ack.state_version,
        terminal_acknowledged_at: timestamp(terminal_ack.acknowledged_at),
        observed_at: timestamp(observed_at),
        received_at: timestamp(received_at),
        reservation_released_at: timestamp(reservation_released_at),
        release_reason: "removed_receipt",
    })
}

type ProgressPublisher<'a> = dyn Fn(&FullRunCheckResult) + 'a;

struct WorkflowWindow {
    heartbeat_after: DateTime<Utc>,
    started: Instant,
    timeout: Duration,
}

fn publish_progress(
    result: &mut FullRunCheckResult,
    started: Instant,
    publisher: &ProgressPublisher<'_>,
) {
    result.update_elapsed(started);
    publisher(result);
}

fn begin_layer(
    result: &mut FullRunCheckResult,
    started: Instant,
    publisher: &ProgressPublisher<'_>,
    id: &'static str,
    message: impl Into<String>,
) {
    result.begin(id, message);
    publish_progress(result, started, publisher);
}

fn pass_layer(
    result: &mut FullRunCheckResult,
    started: Instant,
    publisher: &ProgressPublisher<'_>,
    id: &'static str,
    message: impl Into<String>,
) {
    result.pass(id, message);
    publish_progress(result, started, publisher);
}

fn validate_pass_evidence(result: &FullRunCheckResult) -> Result<(), WorkflowFailure> {
    if result
        .layers
        .iter()
        .any(|layer| layer.state != LayerState::Passed)
    {
        return Err(WorkflowFailure::new(
            LAYER_PLUGIN,
            "full_run_evidence_incomplete",
            false,
            "A required Full Run Check layer lacked pass evidence.",
        ));
    }

    let integration = result.integration.as_ref().ok_or_else(|| {
        WorkflowFailure::new(
            LAYER_PLUGIN,
            "integration_evidence_missing",
            false,
            "The live plugin integration evidence was missing.",
        )
    })?;
    const REQUIRED_MCP_TOOLS: [&str; 5] = [
        "fleet_info",
        "workspace_snapshot_pack",
        "fleet_snapshot_upload",
        "fleet_plan_submit",
        "fleet_job",
    ];
    let active_runtime = &integration.active_runtime;
    if active_runtime.pid == 0
        || active_runtime.started_at.is_empty()
        || active_runtime.bridge_version.trim().is_empty()
        || active_runtime.initial_receipt_verified_at.is_empty()
        || active_runtime.final_receipt_verified_at.is_none()
        || !active_runtime.reverified_after_run
    {
        return Err(WorkflowFailure::new(
            LAYER_PLUGIN,
            "integration_evidence_invalid",
            false,
            "The active Codex runtime was not independently proven online before and after the run.",
        ));
    }
    let executor = integration.self_test_executor.as_ref().ok_or_else(|| {
        WorkflowFailure::new(
            LAYER_PLUGIN,
            "self_test_executor_evidence_missing",
            false,
            "The isolated installed-MCP executor evidence was missing.",
        )
    })?;
    if executor.pid == 0
        || executor.pid == active_runtime.pid
        || executor.started_at.is_empty()
        || executor.bridge_version != active_runtime.bridge_version
        || Uuid::parse_str(&executor.session_id)
            .ok()
            .is_none_or(|session_id| session_id.is_nil())
        || !executor.initialize_completed
        || !executor.tools_list_completed
        || executor.controller_round_trip_at.is_empty()
        || executor.mcp_tools_exercised != REQUIRED_MCP_TOOLS
    {
        return Err(WorkflowFailure::new(
            LAYER_PLUGIN,
            "self_test_executor_evidence_invalid",
            false,
            "The actual isolated MCP executor was missing, confused with the active runtime, or did not execute the exact tool chain.",
        ));
    }

    let transport = result.transport.as_ref().ok_or_else(|| {
        WorkflowFailure::new(
            LAYER_SELECTION,
            "managed_transport_evidence_missing",
            false,
            "Managed worker transport evidence was missing.",
        )
    })?;
    if transport.transport != "managed_https"
        || !transport.tls
        || !transport.credential_reference_present
        || !transport.endpoint.starts_with("https://")
    {
        return Err(WorkflowFailure::new(
            LAYER_SELECTION,
            "managed_transport_evidence_invalid",
            false,
            "The selected worker lacked HTTPS and per-node credential-reference evidence.",
        ));
    }

    let job = result.job.as_ref().ok_or_else(|| {
        WorkflowFailure::new(
            LAYER_EXECUTION,
            "execution_evidence_missing",
            false,
            "Terminal execution evidence was missing.",
        )
    })?;
    if job.state != "succeeded"
        || job.exit_code != Some(0)
        || job.observed_states.is_empty()
        || job.observed_states.last().copied() != Some("succeeded")
    {
        return Err(WorkflowFailure::new(
            LAYER_EXECUTION,
            "execution_evidence_invalid",
            false,
            "The exact job did not finish with succeeded and native exit code 0.",
        ));
    }

    let placement = result.placement.as_ref().ok_or_else(|| {
        WorkflowFailure::new(
            LAYER_SELECTION,
            "placement_evidence_missing",
            false,
            "Placement evidence was missing.",
        )
    })?;
    let final_fleet = result.final_fleet.as_ref().ok_or_else(|| {
        WorkflowFailure::new(
            LAYER_HEARTBEAT,
            "final_fleet_evidence_missing",
            false,
            "The post-run fleet freshness baseline was missing.",
        )
    })?;
    if final_fleet.observed_at.is_empty()
        || u64::try_from(placement.fleet_revision)
            .ok()
            .is_none_or(|revision| final_fleet.fleet_revision < revision)
    {
        return Err(WorkflowFailure::new(
            LAYER_HEARTBEAT,
            "final_fleet_evidence_invalid",
            false,
            "The post-run fleet freshness baseline regressed behind placement.",
        ));
    }

    let log_streams = result
        .logs
        .iter()
        .map(|log| log.stream.as_str())
        .collect::<BTreeSet<_>>();
    if result.snapshot.is_none()
        || result.logs.len() != 2
        || log_streams != BTreeSet::from(["stderr", "stdout"])
        || result.artifacts.is_empty()
    {
        return Err(WorkflowFailure::new(
            LAYER_ARTIFACT,
            "proof_evidence_incomplete",
            false,
            "Snapshot, placement, logs, or artifact digest evidence was incomplete.",
        ));
    }

    let cleanup = result.cleanup.as_ref().ok_or_else(|| {
        WorkflowFailure::new(
            LAYER_CLEANUP,
            "cleanup_evidence_missing",
            false,
            "Exact worker cleanup evidence was missing.",
        )
    })?;
    if cleanup.status != "removed"
        || !cleanup.job_root_deleted
        || cleanup.release_reason != "removed_receipt"
        || cleanup.job_id != job.job_id
        || cleanup.run_id != job.run_id
        || cleanup.relative_root != format!("jobs/{}", job.run_id)
        || cleanup.terminal_state_version == 0
    {
        return Err(WorkflowFailure::new(
            LAYER_CLEANUP,
            "cleanup_evidence_invalid",
            false,
            "Cleanup was not bound to the exact job, run, deleted root, and terminal acknowledgement.",
        ));
    }

    Ok(())
}

#[cfg(test)]
fn execute_full_run(
    backend: &dyn FullRunBackend,
    plugin: &dyn PluginProbe,
    timeout: Duration,
) -> FullRunCheckResult {
    execute_full_run_with_progress(backend, plugin, timeout, &|_| {})
}

fn execute_full_run_with_progress(
    backend: &dyn FullRunBackend,
    plugin: &dyn PluginProbe,
    timeout: Duration,
    publisher: &ProgressPublisher<'_>,
) -> FullRunCheckResult {
    let started_at = Utc::now();
    let started = Instant::now();
    let mut result = FullRunCheckResult::pending(started_at);
    publish_progress(&mut result, started, publisher);
    let mut cleanup_target = None;
    let window = WorkflowWindow {
        heartbeat_after: started_at,
        started,
        timeout,
    };
    let workflow = run_workflow(
        backend,
        plugin,
        window,
        &mut result,
        &mut cleanup_target,
        publisher,
    )
    .and_then(|()| validate_pass_evidence(&result));
    match workflow {
        Ok(()) => {
            result.finish(started, FullRunState::Passed);
            publisher(&result);
        }
        Err(failure) => {
            result.fail(failure);
            publish_progress(&mut result, started, publisher);
            best_effort_cleanup(backend, &mut result, cleanup_target, started, publisher);
            result.finish(started, FullRunState::Failed);
            publisher(&result);
        }
    }
    result
}

fn run_workflow(
    backend: &dyn FullRunBackend,
    plugin: &dyn PluginProbe,
    window: WorkflowWindow,
    result: &mut FullRunCheckResult,
    cleanup_target: &mut Option<CleanupTarget>,
    publisher: &ProgressPublisher<'_>,
) -> Result<(), WorkflowFailure> {
    let WorkflowWindow {
        heartbeat_after,
        started,
        timeout,
    } = window;
    begin_layer(
        result,
        started,
        publisher,
        LAYER_PLUGIN,
        "Checking plugin registration, installed source, MCP tools, and the authenticated controller round trip.",
    );
    let plugin_session = plugin.active_runtime().map_err(|failure| {
        WorkflowFailure::backend(
            LAYER_PLUGIN,
            failure,
            "The active Codex runtime status could not be verified.",
        )
    })?;
    let Some(plugin_session) = plugin_session else {
        return Err(WorkflowFailure::new(
            LAYER_PLUGIN,
            "plugin_check_failed",
            false,
            "The installed Codex plugin did not pass its real MCP connection check.",
        ));
    };
    result.integration = Some(IntegrationEvidence {
        active_runtime: ActiveRuntimeEvidence {
            pid: plugin_session.pid,
            started_at: timestamp(plugin_session.started_at),
            bridge_version: plugin_session.bridge_version.clone(),
            initial_receipt_verified_at: timestamp(Utc::now()),
            final_receipt_verified_at: None,
            reverified_after_run: false,
        },
        self_test_executor: None,
    });
    pass_layer(
        result,
        started,
        publisher,
        LAYER_PLUGIN,
        "The active Codex runtime is online; the isolated installed-MCP executor will be proven separately.",
    );

    begin_layer(
        result,
        started,
        publisher,
        LAYER_HEARTBEAT,
        "Reading the controller fleet and requiring a managed worker heartbeat no older than 15 seconds (three five-second reports).",
    );
    let heartbeat_witness = loop {
        let fleet = backend.fleet().map_err(|failure| {
            WorkflowFailure::backend(
                LAYER_HEARTBEAT,
                failure,
                "The authenticated fleet snapshot could not be read.",
            )
        })?;
        validate_fleet_response(&fleet, Utc::now()).map_err(|failure| {
            WorkflowFailure::backend(
                LAYER_HEARTBEAT,
                failure,
                "The authenticated fleet snapshot revision or timestamp was invalid.",
            )
        })?;
        if let Some(node) =
            select_fresh_managed_node(&fleet.nodes, Utc::now(), Some(heartbeat_after))
        {
            break node;
        }
        let elapsed = started.elapsed();
        if elapsed >= timeout {
            return Err(WorkflowFailure::new(
                LAYER_HEARTBEAT,
                "fresh_managed_worker_unavailable",
                true,
                "No online managed worker produced a new heartbeat after this check began.",
            ));
        }
        thread::sleep(POLL_INTERVAL.min(timeout.saturating_sub(elapsed)));
    };
    pass_layer(
        result,
        started,
        publisher,
        LAYER_HEARTBEAT,
        format!(
            "Found a fresh {} / {} worker profile from {} at heartbeat {} for dynamic placement.",
            operating_system_name(heartbeat_witness.os),
            architecture_name(heartbeat_witness.arch),
            heartbeat_witness.name,
            timestamp(
                heartbeat_witness
                    .last_seen_at
                    .expect("fresh node selection requires a heartbeat")
            )
        ),
    );

    begin_layer(
        result,
        started,
        publisher,
        LAYER_SNAPSHOT,
        "Calling the installed MCP snapshot packer and uploader, then independently verifying the exact archive bytes.",
    );
    let mcp_job_id = Uuid::new_v4();
    let remaining = timeout.saturating_sub(started.elapsed());
    let pipeline = match backend.mcp_full_run_pipeline(mcp_job_id, remaining) {
        Ok(receipt) => receipt,
        Err(pipeline_failure) => {
            let McpPipelineFailure {
                stage,
                failure,
                cleanup_target: failed_cleanup,
            } = pipeline_failure;
            *cleanup_target = failed_cleanup;
            let (layer, message) = match stage {
                McpPipelineStage::Info => (
                    LAYER_SNAPSHOT,
                    "The isolated installed-MCP executor could not complete fleet_info.",
                ),
                McpPipelineStage::Pack | McpPipelineStage::Upload => (
                    LAYER_SNAPSHOT,
                    "The installed MCP snapshot pack or authenticated upload stage failed.",
                ),
                McpPipelineStage::PlanSubmit => {
                    pass_layer(
                        result,
                        started,
                        publisher,
                        LAYER_SNAPSHOT,
                        "The installed MCP packed and uploaded the independently verified fixture before the later tool failure.",
                    );
                    begin_layer(
                        result,
                        started,
                        publisher,
                        LAYER_SELECTION,
                        "Calling the installed MCP atomic plan-and-submit tool.",
                    );
                    (
                        LAYER_SELECTION,
                        "The installed MCP plan-and-submit stage failed.",
                    )
                }
                McpPipelineStage::Job => {
                    pass_layer(
                        result,
                        started,
                        publisher,
                        LAYER_SNAPSHOT,
                        "The installed MCP packed and uploaded the independently verified fixture.",
                    );
                    pass_layer(
                        result,
                        started,
                        publisher,
                        LAYER_SELECTION,
                        "The installed MCP returned a plan-and-submit receipt before its job-read stage failed.",
                    );
                    (
                        LAYER_EXECUTION,
                        "The installed MCP could not read back the newly submitted job.",
                    )
                }
            };
            return Err(WorkflowFailure::backend(layer, failure, message));
        }
    };
    // The isolated MCP session may already have submitted a job before a
    // later native evidence check fails. Preserve only the minimally trusted
    // exact job/run binding now so the failure path can request bounded
    // cancellation instead of orphaning that work.
    *cleanup_target = cleanup_target_from_untrusted(&pipeline.submission, mcp_job_id);
    let executor = pipeline.executor;
    if executor.pid == 0
        || executor.pid == plugin_session.pid
        || executor.started_at < heartbeat_after
        || executor.bridge_version != plugin_session.bridge_version
        || executor.session_id.is_nil()
    {
        return Err(WorkflowFailure::new(
            LAYER_SNAPSHOT,
            "self_test_executor_identity_invalid",
            false,
            "The isolated installed-MCP executor identity was missing or confused with the active Codex runtime.",
        ));
    }
    result
        .integration
        .as_mut()
        .expect("active runtime evidence exists after the plugin gate")
        .self_test_executor = Some(SelfTestExecutorEvidence {
        pid: executor.pid,
        started_at: timestamp(executor.started_at),
        bridge_version: executor.bridge_version,
        session_id: executor.session_id.to_string(),
        initialize_completed: true,
        tools_list_completed: true,
        controller_round_trip_at: timestamp(Utc::now()),
        mcp_tools_exercised: vec![
            "fleet_info",
            "workspace_snapshot_pack",
            "fleet_snapshot_upload",
            "fleet_plan_submit",
            "fleet_job",
        ],
    });
    let snapshot = pipeline.snapshot;
    let descriptor = pipeline.descriptor;
    let metadata = pipeline.metadata;
    if descriptor.api_version != SNAPSHOT_API_VERSION
        || descriptor.format != SNAPSHOT_ARCHIVE_FORMAT
        || descriptor.digest != snapshot.digest
        || descriptor.size_bytes != snapshot.size_bytes()
        || descriptor.file_count != 1
        || descriptor.expanded_size_bytes != SNAPSHOT_INPUT.len() as u64
        || descriptor.skipped_count != 0
        || snapshot.bytes.is_empty()
        || snapshot.bytes.len() > MAX_MCP_FIXTURE_ARCHIVE_BYTES
        || format!("sha256:{}", sha256_hex(&snapshot.bytes)) != snapshot.digest
        || validate_fixture_archive(&snapshot.bytes).is_err()
    {
        return Err(WorkflowFailure::new(
            LAYER_SNAPSHOT,
            "snapshot_descriptor_invalid",
            false,
            "The MCP snapshot descriptor or archive did not contain exactly the expected fixture.",
        ));
    }
    metadata.validate().map_err(|_| {
        WorkflowFailure::new(
            LAYER_SNAPSHOT,
            "snapshot_receipt_invalid",
            false,
            "The controller returned invalid snapshot metadata.",
        )
    })?;
    if metadata.digest != snapshot.digest || metadata.size_bytes != snapshot.size_bytes() {
        return Err(WorkflowFailure::new(
            LAYER_SNAPSHOT,
            "snapshot_receipt_mismatch",
            false,
            "The controller snapshot receipt did not match the uploaded bytes.",
        ));
    }
    result.snapshot = Some(SnapshotEvidence {
        digest: snapshot.digest.clone(),
        size_bytes: snapshot.size_bytes(),
    });
    pass_layer(
        result,
        started,
        publisher,
        LAYER_SNAPSHOT,
        format!(
            "MCP packed and uploaded {} bytes as {}; native verification recomputed the digest and exact tar contents.",
            snapshot.size_bytes(),
            snapshot.digest
        ),
    );

    begin_layer(
        result,
        started,
        publisher,
        LAYER_SELECTION,
        "Validating the installed MCP atomic plan-and-submit response against the exact portable JobSpec.",
    );
    let mut expected_job = build_portable_job(&snapshot).map_err(|_| {
        WorkflowFailure::new(
            LAYER_SELECTION,
            "job_spec_invalid",
            false,
            "The fixed Full Run Check JobSpec failed local protocol validation.",
        )
    })?;
    expected_job.id = mcp_job_id;
    expected_job.validate().map_err(|_| {
        WorkflowFailure::new(
            LAYER_SELECTION,
            "job_spec_invalid",
            false,
            "The fixed Full Run Check JobSpec failed local protocol validation.",
        )
    })?;
    let job = pipeline.job;
    if job != expected_job {
        return Err(WorkflowFailure::new(
            LAYER_SELECTION,
            "mcp_job_spec_mismatch",
            false,
            "The JobSpec passed through MCP did not exactly match the native verifier's reconstruction.",
        ));
    }
    let plan = pipeline.plan;
    validate_plan_response(&plan, &job, Utc::now()).map_err(|failure| {
        WorkflowFailure::new(
            LAYER_SELECTION,
            failure.code,
            failure.retryable,
            "The controller plan did not preserve the exact JobSpec digest, policy, revisions, or explanation.",
        )
    })?;
    if plan.job_id != job.id {
        return Err(WorkflowFailure::new(
            LAYER_SELECTION,
            "placement_plan_mismatch",
            false,
            "The controller plan did not bind the requested job.",
        ));
    }
    let selected_node_id = plan.decision.node_id;
    let placement_fleet = backend.fleet().map_err(|failure| {
        WorkflowFailure::backend(
            LAYER_SELECTION,
            failure,
            "The controller-selected worker could not be verified against a current fleet snapshot.",
        )
    })?;
    validate_fleet_response(&placement_fleet, Utc::now()).map_err(|failure| {
        WorkflowFailure::backend(
            LAYER_SELECTION,
            failure,
            "The post-plan fleet snapshot revision or timestamp was invalid.",
        )
    })?;
    if placement_fleet.fleet_revision
        < u64::try_from(plan.fleet_revision).map_err(|_| {
            WorkflowFailure::new(
                LAYER_SELECTION,
                "placement_plan_mismatch",
                false,
                "The controller plan exposed an invalid fleet revision.",
            )
        })?
        || placement_fleet.observed_at + MAX_CLOCK_SKEW < plan.created_at
    {
        return Err(WorkflowFailure::new(
            LAYER_SELECTION,
            "placement_fleet_regressed",
            false,
            "The independently read fleet snapshot predates the controller placement plan.",
        ));
    }
    let selected_node = placement_fleet
        .nodes
        .iter()
        .find(|candidate| candidate.id == selected_node_id)
        .filter(|candidate| {
            candidate.enabled
                && matches!(candidate.transport, NodeTransport::Managed { .. })
                && matches!(candidate.status, NodeStatus::Online | NodeStatus::Degraded)
                && candidate.resources.available_cpu_cores > 0
                && candidate.resources.available_memory_mib > 0
                && candidate.last_seen_at.is_some_and(|heartbeat| {
                    let age = Utc::now().signed_duration_since(heartbeat);
                    age >= -MAX_CLOCK_SKEW
                        && age <= FRESH_HEARTBEAT_AGE
                        && heartbeat > heartbeat_after
                })
        })
        .ok_or_else(|| {
            WorkflowFailure::new(
                LAYER_SELECTION,
                "placement_node_not_fresh",
                true,
                "The controller-selected worker was not fresh or no longer satisfied the JobSpec requirements.",
            )
        })?;
    let selected_heartbeat = selected_node
        .last_seen_at
        .expect("selected worker freshness was verified");
    result.selected_node = Some(SelectedNodeEvidence {
        id: selected_node.id.to_string(),
        name: selected_node.name.clone(),
        operating_system: operating_system_name(selected_node.os),
        architecture: architecture_name(selected_node.arch),
        heartbeat_at: timestamp(selected_heartbeat),
    });
    result.transport = Some(managed_transport_evidence(selected_node)?);
    result.placement = Some(PlacementEvidence {
        plan_id: plan.plan_id.to_string(),
        job_digest: plan.job_digest.clone(),
        score: plan.decision.score,
        fleet_revision: plan.fleet_revision,
        node_revision: plan.node_revision,
        policy_revision: plan.policy_revision,
        explanation: plan.decision.explanation.clone(),
    });
    let submission = pipeline.submission;
    validate_job_identity(&submission, &job, &plan).map_err(|failure| {
        WorkflowFailure::new(
            LAYER_SELECTION,
            failure.code,
            failure.retryable,
            "The submitted job receipt did not preserve job, run, and worker identity.",
        )
    })?;
    let submitted = pipeline.initial_job;
    validate_polled_job(&submitted, &job, &plan, submission.run.id).map_err(|failure| {
        WorkflowFailure::new(
            LAYER_SELECTION,
            failure.code,
            failure.retryable,
            "The MCP fleet_job response changed immutable job, run, or worker identity.",
        )
    })?;
    validate_job_progress(&submission, &submitted).map_err(|failure| {
        WorkflowFailure::new(
            LAYER_SELECTION,
            failure.code,
            failure.retryable,
            "The MCP fleet_job response regressed the plan-and-submit receipt.",
        )
    })?;
    *cleanup_target = Some(CleanupTarget {
        job_id: job.id,
        run_id: submitted.run.id,
        version: submitted.version,
        state: submitted.run.state,
    });
    pass_layer(
        result,
        started,
        publisher,
        LAYER_SELECTION,
        format!(
            "Controller plan {} bound job {} to worker {}.",
            plan.plan_id, job.id, selected_node_id
        ),
    );

    let run_id = submitted.run.id;
    let mut previous_job = submitted.clone();
    let mut observed_states = vec![submitted.run.state];
    result.job = Some(JobEvidence {
        job_id: job.id.to_string(),
        run_id: run_id.to_string(),
        state: job_state_name(submitted.run.state),
        exit_code: submitted.run.exit_code,
        observed_states: observed_states
            .iter()
            .copied()
            .map(job_state_name)
            .collect(),
    });
    begin_layer(
        result,
        started,
        publisher,
        LAYER_EXECUTION,
        format!(
            "Polling the real job; latest managed-worker state is {}.",
            job_state_name(submitted.run.state)
        ),
    );
    let final_job = loop {
        let elapsed = started.elapsed();
        if elapsed >= timeout {
            return Err(WorkflowFailure::new(
                LAYER_EXECUTION,
                "remote_execution_timeout",
                true,
                "The managed worker did not finish within the bounded Full Run Check window.",
            ));
        }
        let current = backend.get_job(job.id).map_err(|failure| {
            WorkflowFailure::backend(
                LAYER_EXECUTION,
                failure,
                "The controller job status could not be polled.",
            )
        })?;
        validate_polled_job(&current, &job, &plan, run_id).map_err(|failure| {
            WorkflowFailure::new(
                LAYER_EXECUTION,
                failure.code,
                failure.retryable,
                "The polled job changed immutable job, run, or worker identity.",
            )
        })?;
        validate_job_progress(&previous_job, &current).map_err(|failure| {
            WorkflowFailure::new(
                LAYER_EXECUTION,
                failure.code,
                failure.retryable,
                "The controller job receipt regressed state, version, or immutable timestamps.",
            )
        })?;
        let state_changed = observed_states.last().copied() != Some(current.run.state);
        if state_changed {
            observed_states.push(current.run.state);
        }
        if let Some(job_evidence) = result.job.as_mut() {
            job_evidence.state = job_state_name(current.run.state);
            job_evidence.exit_code = current.run.exit_code;
            job_evidence.observed_states = observed_states
                .iter()
                .copied()
                .map(job_state_name)
                .collect();
        }
        if state_changed {
            begin_layer(
                result,
                started,
                publisher,
                LAYER_EXECUTION,
                format!(
                    "Managed worker state changed to {}.",
                    job_state_name(current.run.state)
                ),
            );
        }
        *cleanup_target = Some(CleanupTarget {
            job_id: job.id,
            run_id: current.run.id,
            version: current.version,
            state: current.run.state,
        });
        if current.run.state.is_terminal() {
            break current;
        }
        previous_job = current;
        thread::sleep(POLL_INTERVAL.min(timeout.saturating_sub(elapsed)));
    };
    if final_job.run.state != JobState::Succeeded
        || final_job.run.exit_code != Some(0)
        || final_job.run.started_at.is_none()
        || final_job.run.finished_at.is_none()
    {
        return Err(WorkflowFailure::new(
            LAYER_EXECUTION,
            "remote_execution_failed",
            false,
            "The managed worker returned a non-success terminal state or incomplete execution evidence.",
        ));
    }
    if let Some(job_evidence) = result.job.as_mut() {
        job_evidence.state = job_state_name(final_job.run.state);
        job_evidence.exit_code = final_job.run.exit_code;
        job_evidence.observed_states = observed_states.into_iter().map(job_state_name).collect();
    }
    pass_layer(
        result,
        started,
        publisher,
        LAYER_EXECUTION,
        "The selected managed worker claimed the snapshot job and returned succeeded with native exit code 0.",
    );

    begin_layer(
        result,
        started,
        publisher,
        LAYER_LOGS,
        "Listing remote log chunks, downloading the aggregate streams, and recomputing every chunk digest.",
    );
    result.logs = verify_logs(backend, job.id, run_id).map_err(|failure| {
        WorkflowFailure::backend(
            LAYER_LOGS,
            failure,
            "Remote logs were missing, discontinuous, or failed SHA-256 verification.",
        )
    })?;
    pass_layer(
        result,
        started,
        publisher,
        LAYER_LOGS,
        format!(
            "Downloaded and verified {} remote log stream(s), including the execution marker.",
            result.logs.len()
        ),
    );

    begin_layer(
        result,
        started,
        publisher,
        LAYER_ARTIFACT,
        "Listing job artifacts, downloading the proof file, and recomputing its SHA-256 digest.",
    );
    let artifact = verify_artifact(backend, job.id, &final_job.run).map_err(|failure| {
        WorkflowFailure::backend(
            LAYER_ARTIFACT,
            failure,
            "The proof artifact was missing or did not match its declared size, content, and SHA-256 digest.",
        )
    })?;
    result.artifacts.push(artifact.clone());
    pass_layer(
        result,
        started,
        publisher,
        LAYER_ARTIFACT,
        format!(
            "Downloaded {} ({} bytes) and verified SHA-256 {}.",
            artifact.name, artifact.size_bytes, artifact.sha256
        ),
    );

    begin_layer(
        result,
        started,
        publisher,
        LAYER_CLEANUP,
        "Waiting for the controller's durable worker workspace-cleanup receipt.",
    );
    loop {
        let elapsed = started.elapsed();
        if elapsed >= timeout {
            return Err(WorkflowFailure::new(
                LAYER_CLEANUP,
                "worker_cleanup_timeout",
                true,
                "The worker proof succeeded, but no authoritative workspace-cleanup receipt arrived in time.",
            ));
        }
        let receipt = backend.cleanup_receipt(job.id).map_err(|failure| {
            WorkflowFailure::backend(
                LAYER_CLEANUP,
                failure,
                "The controller cleanup receipt could not be read.",
            )
        })?;
        match validate_success_cleanup(&receipt, job.id, run_id, final_job.version).map_err(
            |failure| {
                WorkflowFailure::backend(
                    LAYER_CLEANUP,
                    failure,
                    "The cleanup receipt was not bound to the exact job root and terminal completion acknowledgement.",
                )
            },
        )? {
            ValidatedCleanup::Removed(observed_at) => {
                result.cleanup = Some(removed_cleanup_evidence(&receipt).map_err(|failure| {
                    WorkflowFailure::backend(
                        LAYER_CLEANUP,
                        failure,
                        "The cleanup receipt could not be converted into exact structured evidence.",
                    )
                })?);
                pass_layer(
                    result,
                    started,
                    publisher,
                    LAYER_CLEANUP,
                    format!(
                        "Worker workspace removal was durably acknowledged at {}.",
                        timestamp(observed_at)
                    ),
                );
                break;
            }
            ValidatedCleanup::Pending => {
                thread::sleep(POLL_INTERVAL.min(timeout.saturating_sub(elapsed)));
            }
        }
    }

    // Require a controller-authenticated refresh produced after every remote
    // proof and cleanup check completed. A receipt that was merely still
    // inside its TTL at the end cannot satisfy this gate.
    let reverify_after = Utc::now();
    if !plugin
        .wait_for_runtime_refresh(&plugin_session, reverify_after)
        .map_err(|failure| {
            WorkflowFailure::backend(
                LAYER_PLUGIN,
                failure,
                "The live Codex plugin runtime could not be revalidated after the remote run.",
            )
        })?
    {
        return Err(WorkflowFailure::new(
            LAYER_PLUGIN,
            "plugin_runtime_changed",
            true,
            "The Codex plugin process changed or lost controller authentication during Full Run Check.",
        ));
    }
    let integration = result
        .integration
        .as_mut()
        .expect("plugin identity evidence exists after the plugin gate");
    integration.active_runtime.final_receipt_verified_at = Some(timestamp(Utc::now()));
    integration.active_runtime.reverified_after_run = true;

    // Capture a new controller-authenticated fleet baseline only after the
    // live MCP runtime has been reverified.  Placement revisions naturally
    // age while leases and cleanup advance, so returning the placement
    // revision as the UI freshness baseline would make a successful run look
    // stale immediately.
    let final_fleet = backend.fleet().map_err(|failure| {
        WorkflowFailure::backend(
            LAYER_HEARTBEAT,
            failure,
            "The post-run fleet freshness baseline could not be read.",
        )
    })?;
    validate_fleet_response(&final_fleet, Utc::now()).map_err(|failure| {
        WorkflowFailure::backend(
            LAYER_HEARTBEAT,
            failure,
            "The post-run fleet freshness baseline was invalid.",
        )
    })?;
    let placement_revision = u64::try_from(plan.fleet_revision).map_err(|_| {
        WorkflowFailure::new(
            LAYER_HEARTBEAT,
            "final_fleet_evidence_invalid",
            false,
            "The placement fleet revision could not be used as a freshness baseline.",
        )
    })?;
    if final_fleet.fleet_revision < placement_revision
        || final_fleet.observed_at < placement_fleet.observed_at
    {
        return Err(WorkflowFailure::new(
            LAYER_HEARTBEAT,
            "final_fleet_evidence_regressed",
            true,
            "The post-run fleet baseline regressed behind the placement snapshot.",
        ));
    }
    result.final_fleet = Some(FinalFleetEvidence {
        fleet_revision: final_fleet.fleet_revision,
        observed_at: timestamp(final_fleet.observed_at),
    });
    pass_layer(
        result,
        started,
        publisher,
        LAYER_PLUGIN,
        format!(
            "The same live Codex plugin process remained authenticated; final fleet revision {} was captured after the run.",
            final_fleet.fleet_revision
        ),
    );
    Ok(())
}

fn prepare_node_smoke(
    backend: &dyn FullRunBackend,
    node_id: Uuid,
    operation_id: &str,
    job_id: Uuid,
) -> Result<SmokeRunBindingV1, NodeSmokeError> {
    if node_id.is_nil()
        || job_id.is_nil()
        || operation_id.trim().is_empty()
        || operation_id.len() > 512
        || operation_id.chars().any(char::is_control)
    {
        return Err(NodeSmokeError::new("SMOKE_OPERATION_ID_INVALID", false));
    }

    let snapshot =
        build_snapshot().map_err(|_| NodeSmokeError::new("SMOKE_SNAPSHOT_PACK_FAILED", false))?;

    // Reconcile first.  If submit succeeded but its response was lost, a
    // retry must recover the exact durable run without requiring a new fresh
    // heartbeat, upload, plan, or capacity decision.
    if let Some(existing) = backend.get_job_optional(job_id)? {
        let expected = expected_bound_smoke_job(&existing.job, node_id, job_id, &snapshot)?;
        validate_job_identity_for_node(&existing, &expected, node_id)
            .map_err(NodeSmokeError::from)?;
        let plan = existing
            .plan_binding
            .clone()
            .ok_or_else(|| NodeSmokeError::new("SMOKE_BINDING_MISSING", false))?;
        let binding = SmokeRunBindingV1 {
            plan,
            run_id: existing.run.id,
        };
        binding
            .validate(Some(&expected), None)
            .map_err(|_| NodeSmokeError::new("SMOKE_BINDING_INVALID", false))?;
        return Ok(binding);
    }

    let fleet = backend.fleet()?;
    validate_fleet_response(&fleet, Utc::now()).map_err(NodeSmokeError::from)?;
    let now = Utc::now();
    let node = fleet
        .nodes
        .into_iter()
        .find(|node| {
            node.id == node_id
                && node.enabled
                && matches!(node.transport, NodeTransport::Managed { .. })
                && matches!(node.status, NodeStatus::Online | NodeStatus::Degraded)
                && node.resources.available_cpu_cores > 0
                && node.resources.available_memory_mib > 0
                && node.last_seen_at.is_some_and(|heartbeat| {
                    let age = now.signed_duration_since(heartbeat);
                    age >= -MAX_CLOCK_SKEW && age <= FRESH_HEARTBEAT_AGE
                })
        })
        .ok_or_else(|| NodeSmokeError::new("SMOKE_NODE_NOT_FRESH", true))?;

    let metadata = backend.upload_snapshot(&snapshot)?;
    metadata
        .validate()
        .map_err(|_| NodeSmokeError::new("SMOKE_SNAPSHOT_RECEIPT_INVALID", false))?;
    if metadata.digest != snapshot.digest || metadata.size_bytes != snapshot.size_bytes() {
        return Err(NodeSmokeError::new(
            "SMOKE_SNAPSHOT_RECEIPT_MISMATCH",
            false,
        ));
    }

    let job = build_bound_smoke_job(node_id, node.os, node.arch, job_id, &snapshot)
        .map_err(|_| NodeSmokeError::new("SMOKE_JOB_SPEC_INVALID", false))?;

    let plan = backend.plan(&job)?;
    validate_plan_response(&plan, &job, Utc::now()).map_err(NodeSmokeError::from)?;
    if plan.decision.node_id != node_id {
        return Err(NodeSmokeError::new("SMOKE_PLACEMENT_MISMATCH", false));
    }
    let submitted = match backend.submit(&job, plan.plan_id) {
        Ok(submitted) => submitted,
        Err(original) => match backend.get_job_optional(job.id) {
            Ok(Some(existing)) => existing,
            Ok(None) | Err(_) => return Err(NodeSmokeError::from(original)),
        },
    };
    validate_job_identity(&submitted, &job, &plan).map_err(NodeSmokeError::from)?;
    let binding = SmokeRunBindingV1 {
        plan,
        run_id: submitted.run.id,
    };
    binding
        .validate(Some(&job), None)
        .map_err(|_| NodeSmokeError::new("SMOKE_BINDING_INVALID", false))?;
    Ok(binding)
}

fn execute_bound_node_smoke(
    backend: &dyn FullRunBackend,
    binding: &SmokeRunBindingV1,
    timeout: Duration,
) -> Result<DateTime<Utc>, NodeSmokeError> {
    binding
        .validate(None, None)
        .map_err(|_| NodeSmokeError::new("SMOKE_BINDING_INVALID", false))?;
    let started = Instant::now();
    let job_id = binding.plan.job_id;
    let node_id = binding.plan.decision.node_id;
    let snapshot =
        build_snapshot().map_err(|_| NodeSmokeError::new("SMOKE_SNAPSHOT_PACK_FAILED", false))?;
    let mut current = backend.get_job(job_id)?;
    let expected = expected_bound_smoke_job(&current.job, node_id, job_id, &snapshot)?;
    validate_job_identity(&current, &expected, &binding.plan).map_err(NodeSmokeError::from)?;
    if current.run.id != binding.run_id {
        return Err(NodeSmokeError::new("SMOKE_RUN_ID_MISMATCH", false));
    }
    let expected_placement = current
        .run
        .placement
        .clone()
        .ok_or_else(|| NodeSmokeError::new("SMOKE_PLACEMENT_MISMATCH", false))?;

    let run_id = current.run.id;
    let mut previous_job = current.clone();
    loop {
        if current.run.state.is_terminal() {
            break;
        }
        let elapsed = started.elapsed();
        if elapsed >= timeout {
            // Provisioning retries deliberately reuse the operation-derived
            // job id. Leave a still-running job alone so the next retry can
            // reconcile the same durable run instead of finding a cancelled
            // terminal job that can never become ready.
            return Err(NodeSmokeError::new("SMOKE_EXECUTION_TIMEOUT", true));
        }
        thread::sleep(POLL_INTERVAL.min(timeout.saturating_sub(elapsed)));
        current = backend.get_job(job_id)?;
        validate_polled_job_with_placement(
            &current,
            &expected,
            node_id,
            &expected_placement,
            run_id,
        )
        .map_err(NodeSmokeError::from)?;
        validate_job_progress(&previous_job, &current).map_err(NodeSmokeError::from)?;
        previous_job = current.clone();
    }
    if current.run.state != JobState::Succeeded
        || current.run.exit_code != Some(0)
        || current.run.started_at.is_none()
    {
        return Err(NodeSmokeError::new("SMOKE_EXECUTION_FAILED", false));
    }
    let completed_at = current
        .run
        .finished_at
        .ok_or_else(|| NodeSmokeError::new("SMOKE_EXECUTION_RECEIPT_INVALID", false))?;
    verify_logs(backend, job_id, run_id).map_err(NodeSmokeError::from)?;
    verify_artifact(backend, job_id, &current.run).map_err(NodeSmokeError::from)?;

    loop {
        let elapsed = started.elapsed();
        if elapsed >= timeout {
            return Err(NodeSmokeError::new("SMOKE_CLEANUP_TIMEOUT", true));
        }
        let receipt = backend.cleanup_receipt(job_id)?;
        match validate_success_cleanup(&receipt, job_id, run_id, current.version)
            .map_err(NodeSmokeError::from)?
        {
            ValidatedCleanup::Removed(_) => return Ok(completed_at),
            ValidatedCleanup::Pending => {
                thread::sleep(POLL_INTERVAL.min(timeout.saturating_sub(elapsed)));
            }
        }
    }
}

fn best_effort_cleanup(
    backend: &dyn FullRunBackend,
    result: &mut FullRunCheckResult,
    target: Option<CleanupTarget>,
    started: Instant,
    publisher: &ProgressPublisher<'_>,
) {
    let cleanup_state = result.layer_mut(LAYER_CLEANUP).state;
    if cleanup_state == LayerState::Passed || cleanup_state == LayerState::Failed {
        return;
    }
    let Some(target) = target else {
        let layer = result.layer_mut(LAYER_CLEANUP);
        layer.state = LayerState::Skipped;
        layer.message = "No job was submitted, so no cancellation was necessary.".to_owned();
        publish_progress(result, started, publisher);
        return;
    };
    if target.state.is_terminal() {
        let validation = backend.cleanup_receipt(target.job_id).and_then(|receipt| {
            validate_success_cleanup(&receipt, target.job_id, target.run_id, target.version)
        });
        let layer = result.layer_mut(LAYER_CLEANUP);
        match validation {
            Ok(ValidatedCleanup::Removed(observed_at)) => {
                layer.state = LayerState::Passed;
                layer.message = format!(
                    "Worker workspace removal was durably acknowledged at {}.",
                    timestamp(observed_at)
                );
            }
            Ok(ValidatedCleanup::Pending) | Err(_) => {
                layer.state = LayerState::Failed;
                layer.message = "The job is terminal, but this failed check did not obtain an authoritative workspace-cleanup receipt.".to_owned();
            }
        }
        publish_progress(result, started, publisher);
        return;
    }
    begin_layer(
        result,
        started,
        publisher,
        LAYER_CLEANUP,
        "Requesting cancellation with the latest observed job version.",
    );
    match backend.cancel(target.job_id, target.version) {
        Ok(cancelled)
            if cancelled.job.id == target.job_id
                && (cancelled.cancel_requested || cancelled.run.state.is_terminal()) =>
        {
            let layer = result.layer_mut(LAYER_CLEANUP);
            layer.state = LayerState::Failed;
            layer.message = "The controller accepted cancellation, but worker cleanup is not yet authoritatively acknowledged.".to_owned();
        }
        Ok(_) | Err(_) => {
            let layer = result.layer_mut(LAYER_CLEANUP);
            layer.state = LayerState::Failed;
            layer.message =
                "Best-effort cancellation did not return an authoritative acknowledgement."
                    .to_owned();
        }
    }
    publish_progress(result, started, publisher);
}

fn select_fresh_managed_node(
    nodes: &[Node],
    now: DateTime<Utc>,
    received_after: Option<DateTime<Utc>>,
) -> Option<Node> {
    let mut candidates = nodes
        .iter()
        .filter(|node| {
            node.enabled
                && matches!(node.transport, NodeTransport::Managed { .. })
                && matches!(node.status, NodeStatus::Online | NodeStatus::Degraded)
                && node.resources.available_cpu_cores > 0
                && node.resources.available_memory_mib > 0
                && node.last_seen_at.is_some_and(|heartbeat| {
                    let age = now.signed_duration_since(heartbeat);
                    age >= -MAX_CLOCK_SKEW
                        && age <= FRESH_HEARTBEAT_AGE
                        && received_after.is_none_or(|baseline| heartbeat > baseline)
                })
        })
        .cloned()
        .collect::<Vec<_>>();
    candidates.sort_by(|left, right| {
        right
            .priority
            .cmp(&left.priority)
            .then_with(|| {
                right
                    .resources
                    .available_cpu_cores
                    .cmp(&left.resources.available_cpu_cores)
            })
            .then_with(|| {
                right
                    .resources
                    .available_memory_mib
                    .cmp(&left.resources.available_memory_mib)
            })
            .then_with(|| left.id.cmp(&right.id))
    });
    candidates.into_iter().next()
}

fn build_snapshot() -> Result<SnapshotPayload, std::io::Error> {
    let mut tar_bytes = Vec::new();
    {
        let mut builder = tar::Builder::new(&mut tar_bytes);
        let mut header = tar::Header::new_gnu();
        header.set_entry_type(tar::EntryType::Regular);
        header.set_mode(0o644);
        header.set_uid(0);
        header.set_gid(0);
        header.set_mtime(0);
        header.set_size(SNAPSHOT_INPUT.len() as u64);
        header.set_cksum();
        builder.append_data(&mut header, "input.txt", Cursor::new(SNAPSHOT_INPUT))?;
        builder.finish()?;
    }
    let bytes = zstd::stream::encode_all(Cursor::new(tar_bytes), 3)?;
    let digest = format!("sha256:{}", sha256_hex(&bytes));
    Ok(SnapshotPayload { bytes, digest })
}

fn read_and_validate_mcp_snapshot(
    descriptor: &PackedSnapshotDescriptor,
    expected_archive: &Path,
) -> Result<SnapshotPayload, McpPipelineFailure> {
    let invalid =
        || McpPipelineFailure::new(McpPipelineStage::Pack, "snapshot_descriptor_invalid", false);
    if descriptor.api_version != SNAPSHOT_API_VERSION
        || descriptor.format != SNAPSHOT_ARCHIVE_FORMAT
        || descriptor.file_count != 1
        || descriptor.expanded_size_bytes != SNAPSHOT_INPUT.len() as u64
        || descriptor.skipped_count != 0
        || descriptor.size_bytes == 0
        || descriptor.size_bytes > MAX_MCP_FIXTURE_ARCHIVE_BYTES as u64
        || !descriptor.archive_path.is_absolute()
    {
        return Err(invalid());
    }
    let expected = fs::canonicalize(expected_archive).map_err(|_| invalid())?;
    let returned = fs::canonicalize(&descriptor.archive_path).map_err(|_| invalid())?;
    if returned != expected {
        return Err(invalid());
    }
    let before = fs::symlink_metadata(&returned).map_err(|_| invalid())?;
    if !before.file_type().is_file() || before.file_type().is_symlink() {
        return Err(invalid());
    }
    let bytes = fs::read(&returned).map_err(|_| invalid())?;
    let after = fs::symlink_metadata(&returned).map_err(|_| invalid())?;
    if before.len() != after.len()
        || bytes.len() as u64 != descriptor.size_bytes
        || format!("sha256:{}", sha256_hex(&bytes)) != descriptor.digest
    {
        return Err(invalid());
    }
    validate_fixture_archive(&bytes).map_err(|_| invalid())?;
    Ok(SnapshotPayload {
        bytes,
        digest: descriptor.digest.clone(),
    })
}

fn validate_fixture_archive(bytes: &[u8]) -> Result<(), ()> {
    // The fixture expands to one tiny tar stream. A tight bound makes the
    // native verifier independent of the plugin's advertised expanded size.
    const MAX_FIXTURE_TAR_BYTES: u64 = 16 * 1024;
    let mut decoder = zstd::stream::read::Decoder::new(Cursor::new(bytes)).map_err(|_| ())?;
    let mut decoded = Vec::new();
    decoder
        .by_ref()
        .take(MAX_FIXTURE_TAR_BYTES + 1)
        .read_to_end(&mut decoded)
        .map_err(|_| ())?;
    if decoded.is_empty() || decoded.len() as u64 > MAX_FIXTURE_TAR_BYTES {
        return Err(());
    }
    let mut archive = tar::Archive::new(Cursor::new(decoded));
    let mut entries = archive.entries().map_err(|_| ())?;
    let mut entry = entries.next().ok_or(())?.map_err(|_| ())?;
    if !entry.header().entry_type().is_file()
        || entry.path().map_err(|_| ())?.as_ref() != Path::new("input.txt")
        || entry.size() != SNAPSHOT_INPUT.len() as u64
    {
        return Err(());
    }
    let mut contents = Vec::new();
    entry
        .by_ref()
        .take(SNAPSHOT_INPUT.len() as u64 + 1)
        .read_to_end(&mut contents)
        .map_err(|_| ())?;
    drop(entry);
    if contents != SNAPSHOT_INPUT || entries.next().is_some() {
        return Err(());
    }
    Ok(())
}

/// Build one worker-native proof that leaves OS and architecture open for the
/// controller's Performance scheduler. `cat`, `echo`, and `>` have compatible
/// semantics in Bash/Zsh and PowerShell. The native verifier requires both the
/// snapshot input line and execution marker in stdout, then independently
/// verifies the returned artifact bytes and digest.
fn build_portable_job(snapshot: &SnapshotPayload) -> Result<JobSpec, ()> {
    let mut step = JobStep::new(
        "full-run-proof",
        r#"cat input.txt
echo CYC_FULL_RUN_EXECUTED
echo CYC_FULL_RUN_STDERR >&2
echo CYC_FULL_RUN_OK > full-run-proof.txt"#,
    );
    step.timeout_seconds = Some(30);
    let mut job = JobSpec::new(
        JobKind::Test,
        SourceSpec::Snapshot {
            digest: snapshot.digest.clone(),
            size_bytes: Some(snapshot.size_bytes()),
        },
        vec![step],
    );
    job.requirements.min_cpu_cores = Some(1);
    job.requirements.min_memory_mib = Some(64);
    job.requirements.min_disk_mib = Some(16);
    job.artifacts = ArtifactSpec {
        include: vec![ARTIFACT_NAME.to_owned()],
        exclude: vec![".git/**".to_owned()],
        retention_days: Some(1),
    };
    job.timeout_seconds = Some(60);
    job.placement_policy = PlacementPolicy::Performance;
    job.preferred_node_id = None;
    job.validate().map_err(|_| ())?;
    Ok(job)
}

fn build_job(node: &Node, snapshot: &SnapshotPayload) -> Result<JobSpec, ()> {
    let mut step = match node.os {
        OperatingSystem::Windows => JobStep::new(
            "full-run-proof",
            r#"$ErrorActionPreference = "Stop"
$inputText = [System.IO.File]::ReadAllText((Join-Path (Get-Location) "input.txt"))
if ($inputText.Trim() -ne "ClusterYourCodex full run check") { throw "snapshot input mismatch" }
[Console]::Out.WriteLine("CYC_FULL_RUN_EXECUTED")
[Console]::Error.WriteLine("CYC_FULL_RUN_STDERR")
[System.IO.File]::WriteAllBytes((Join-Path (Get-Location) "full-run-proof.txt"), [System.Text.Encoding]::UTF8.GetBytes("CYC_FULL_RUN_OK`n"))"#,
        ),
        OperatingSystem::Linux | OperatingSystem::Macos => JobStep::new(
            "full-run-proof",
            r#"set -euo pipefail
test "$(cat input.txt)" = "ClusterYourCodex full run check"
printf 'CYC_FULL_RUN_EXECUTED\n'
printf 'CYC_FULL_RUN_STDERR\n' >&2
printf 'CYC_FULL_RUN_OK\n' > full-run-proof.txt"#,
        ),
    };
    step.shell = Some(match node.os {
        OperatingSystem::Windows => Shell::Powershell,
        OperatingSystem::Linux => Shell::Bash,
        OperatingSystem::Macos => Shell::Zsh,
    });
    step.timeout_seconds = Some(30);
    let mut job = JobSpec::new(
        JobKind::Test,
        SourceSpec::Snapshot {
            digest: snapshot.digest.clone(),
            size_bytes: Some(snapshot.size_bytes()),
        },
        vec![step],
    );
    job.requirements.os = Some(node.os);
    job.requirements.arch = Some(node.arch);
    job.requirements.min_cpu_cores = Some(1);
    job.requirements.min_memory_mib = Some(64);
    job.requirements.min_disk_mib = Some(16);
    job.artifacts = ArtifactSpec {
        include: vec![ARTIFACT_NAME.to_owned()],
        exclude: vec![".git/**".to_owned()],
        retention_days: Some(1),
    };
    job.timeout_seconds = Some(60);
    job.placement_policy = PlacementPolicy::Performance;
    job.preferred_node_id = None;
    job.validate().map_err(|_| ())?;
    Ok(job)
}

fn build_bound_smoke_job(
    node_id: Uuid,
    os: OperatingSystem,
    arch: Architecture,
    job_id: Uuid,
    snapshot: &SnapshotPayload,
) -> Result<JobSpec, ()> {
    if node_id.is_nil() || job_id.is_nil() {
        return Err(());
    }
    let verifier_node = Node::new("bound-smoke-verifier", NodeTransport::Local, os, arch);
    let mut job = build_job(&verifier_node, snapshot)?;
    job.id = job_id;
    job.placement_policy = PlacementPolicy::Manual;
    job.preferred_node_id = Some(node_id);
    job.validate().map_err(|_| ())?;
    Ok(job)
}

fn expected_bound_smoke_job(
    observed: &JobSpec,
    node_id: Uuid,
    job_id: Uuid,
    snapshot: &SnapshotPayload,
) -> Result<JobSpec, NodeSmokeError> {
    let os = observed
        .requirements
        .os
        .ok_or_else(|| NodeSmokeError::new("SMOKE_JOB_SPEC_INVALID", false))?;
    let arch = observed
        .requirements
        .arch
        .ok_or_else(|| NodeSmokeError::new("SMOKE_JOB_SPEC_INVALID", false))?;
    let expected = build_bound_smoke_job(node_id, os, arch, job_id, snapshot)
        .map_err(|_| NodeSmokeError::new("SMOKE_JOB_SPEC_INVALID", false))?;
    if observed != &expected {
        return Err(NodeSmokeError::new("SMOKE_JOB_SPEC_MISMATCH", false));
    }
    Ok(expected)
}

fn validate_plan_response(
    plan: &PlanResponse,
    expected: &JobSpec,
    now: DateTime<Utc>,
) -> Result<(), BackendFailure> {
    plan.validate(Some(expected), Some(now))
        .map_err(|_| BackendFailure::new("placement_plan_mismatch", false))
}

fn validate_placement_explanation(
    explanation: &PlacementExplain,
    policy: PlacementPolicy,
    node_id: Uuid,
    expected_score: Option<i64>,
) -> Result<(), BackendFailure> {
    if explanation.policy != policy
        || explanation.selected_node_id != Some(node_id)
        || explanation.candidates.is_empty()
        || explanation.candidates.len() > 256
    {
        return Err(BackendFailure::new("placement_plan_mismatch", false));
    }
    let mut candidate_ids = BTreeSet::new();
    let mut selected = None;
    for candidate in &explanation.candidates {
        let mut component_keys = BTreeSet::new();
        let components_valid = candidate.score_components.len() <= 64
            && candidate.score_components.iter().all(|component| {
                !component.key.trim().is_empty()
                    && component.key.len() <= 128
                    && !component.key.chars().any(char::is_control)
                    && !component.detail.trim().is_empty()
                    && component.detail.len() <= 512
                    && !component.detail.chars().any(char::is_control)
                    && component.value.unsigned_abs() <= MAX_JSON_SAFE_INTEGER_U64
                    && component_keys.insert(component.key.as_str())
            });
        let component_score = candidate
            .score_components
            .iter()
            .try_fold(0_i64, |sum, component| sum.checked_add(component.value));
        let mut rejection_codes = BTreeSet::new();
        let rejections_valid = candidate.rejection_reasons.len() <= 64
            && candidate.rejection_reasons.iter().all(|reason| {
                !reason.detail.trim().is_empty()
                    && reason.detail.len() <= 512
                    && !reason.detail.chars().any(char::is_control)
                    && rejection_codes.insert(reason.code)
            });
        let eligibility_evidence_valid = if candidate.eligible {
            component_score.is_some_and(|score| candidate.score == Some(score))
                && !candidate.score_components.is_empty()
                && candidate.rejection_reasons.is_empty()
        } else {
            candidate.score.is_none()
                && candidate.score_components.is_empty()
                && !candidate.rejection_reasons.is_empty()
        };
        if candidate.node_id.is_nil()
            || candidate.node_name.trim().is_empty()
            || candidate.node_name.len() > 256
            || candidate.node_name.chars().any(char::is_control)
            || candidate
                .score
                .is_some_and(|score| score.unsigned_abs() > MAX_JSON_SAFE_INTEGER_U64)
            || !candidate_ids.insert(candidate.node_id)
            || !components_valid
            || !rejections_valid
            || !eligibility_evidence_valid
        {
            return Err(BackendFailure::new("placement_plan_mismatch", false));
        }
        if candidate.node_id == node_id {
            selected = Some(candidate);
        }
    }
    let selected = selected.ok_or_else(|| BackendFailure::new("placement_plan_mismatch", false))?;
    if !selected.eligible || expected_score.is_some_and(|score| selected.score != Some(score)) {
        return Err(BackendFailure::new("placement_plan_mismatch", false));
    }
    Ok(())
}

fn validate_job_identity_for_node(
    value: &JobView,
    expected: &JobSpec,
    node_id: Uuid,
) -> Result<(), BackendFailure> {
    if value.job != *expected
        || value.run.job_id != expected.id
        || value.run.node_id != Some(node_id)
        || value.version > MAX_JSON_SAFE_INTEGER_U64
        || validate_run_receipt(&value.run).is_err()
        || value.cancel_requested
    {
        return Err(BackendFailure::new("job_receipt_mismatch", false));
    }
    let plan_binding = value
        .plan_binding
        .as_ref()
        .ok_or_else(|| BackendFailure::new("job_plan_binding_missing", false))?;
    // The plan can legitimately expire after the job was atomically
    // submitted.  Polling validates its immutable structure and exact job
    // binding without applying the pre-submit expiry gate again.
    plan_binding
        .validate(Some(expected), None)
        .map_err(|_| BackendFailure::new("job_plan_binding_mismatch", false))?;
    if plan_binding.decision.node_id != node_id {
        return Err(BackendFailure::new("job_plan_binding_mismatch", false));
    }
    let placement = value
        .run
        .placement
        .as_ref()
        .ok_or_else(|| BackendFailure::new("job_receipt_mismatch", false))?;
    validate_placement_explanation(placement, expected.placement_policy, node_id, None)
        .map_err(|_| BackendFailure::new("job_receipt_mismatch", false))
}

fn validate_run_receipt(run: &Run) -> Result<(), BackendFailure> {
    run.validate()
        .map_err(|_| BackendFailure::new("run_receipt_invalid", false))?;
    let unexpected_nonterminal_evidence = !run.state.is_terminal()
        && (run.exit_code.is_some() || run.error.is_some() || !run.artifact_ids.is_empty());
    let unexpected_start =
        matches!(run.state, JobState::Queued | JobState::Preparing) && run.started_at.is_some();
    if unexpected_nonterminal_evidence || unexpected_start {
        return Err(BackendFailure::new("run_receipt_invalid", false));
    }
    Ok(())
}

fn validate_job_identity(
    value: &JobView,
    expected: &JobSpec,
    plan: &PlanResponse,
) -> Result<(), BackendFailure> {
    // The controller may refresh telemetry and recompute the actual placement
    // explanation during submit while still honoring the exact selected node.
    // The immutable original plan is persisted separately as planBinding; the
    // runtime explanation therefore receives structural/node validation here
    // rather than incorrect byte equality with the older plan snapshot.
    validate_job_identity_for_node(value, expected, plan.decision.node_id)?;
    if value.plan_binding.as_ref() != Some(plan) {
        return Err(BackendFailure::new("job_plan_binding_mismatch", false));
    }
    Ok(())
}

fn validate_polled_job(
    value: &JobView,
    expected: &JobSpec,
    plan: &PlanResponse,
    run_id: Uuid,
) -> Result<(), BackendFailure> {
    validate_job_identity(value, expected, plan)?;
    if value.run.id != run_id {
        return Err(BackendFailure::new("run_identity_changed", false));
    }
    Ok(())
}

fn validate_polled_job_with_placement(
    value: &JobView,
    expected: &JobSpec,
    node_id: Uuid,
    expected_placement: &PlacementExplain,
    run_id: Uuid,
) -> Result<(), BackendFailure> {
    validate_job_identity_for_node(value, expected, node_id)?;
    if value.run.id != run_id || value.run.placement.as_ref() != Some(expected_placement) {
        return Err(BackendFailure::new("run_identity_changed", false));
    }
    Ok(())
}

fn validate_job_progress(previous: &JobView, current: &JobView) -> Result<(), BackendFailure> {
    if current.version < previous.version
        || current.run.created_at != previous.run.created_at
        || previous
            .run
            .started_at
            .is_some_and(|started| current.run.started_at != Some(started))
        || previous
            .run
            .finished_at
            .is_some_and(|finished| current.run.finished_at != Some(finished))
    {
        return Err(BackendFailure::new("job_progress_regressed", false));
    }
    if current.version == previous.version {
        return if current == previous {
            Ok(())
        } else {
            Err(BackendFailure::new("job_progress_regressed", false))
        };
    }
    if current.run.state == previous.run.state {
        return Err(BackendFailure::new("job_progress_regressed", false));
    }
    if previous.run.state.is_terminal()
        || (!current.run.state.is_terminal()
            && job_state_rank(current.run.state) <= job_state_rank(previous.run.state))
    {
        return Err(BackendFailure::new("job_progress_regressed", false));
    }
    Ok(())
}

fn job_state_rank(state: JobState) -> u8 {
    match state {
        JobState::Queued => 0,
        JobState::Preparing => 1,
        JobState::Running => 2,
        JobState::Verifying => 3,
        JobState::Succeeded | JobState::Failed | JobState::Cancelled => 4,
    }
}

fn verify_logs(
    backend: &dyn FullRunBackend,
    job_id: Uuid,
    run_id: Uuid,
) -> Result<Vec<LogEvidence>, BackendFailure> {
    let listing = backend.list_logs(job_id)?;
    if listing.chunks.is_empty() {
        return Err(BackendFailure::new("remote_logs_missing", false));
    }
    let mut streams = BTreeMap::<String, Vec<LogChunk>>::new();
    for chunk in listing.chunks {
        if chunk.run_id != run_id
            || !matches!(chunk.stream.as_str(), "stdout" | "stderr")
            || !valid_sha256(&chunk.sha256)
            || chunk.length == 0
        {
            return Err(BackendFailure::new("remote_log_metadata_invalid", false));
        }
        streams.entry(chunk.stream.clone()).or_default().push(chunk);
    }
    let stream_names = streams.keys().cloned().collect::<BTreeSet<_>>();
    let mut evidence = Vec::new();
    let mut stdout_marker_found = false;
    let mut snapshot_input_found = false;
    let mut stderr_marker_found = false;
    for (stream, mut chunks) in streams {
        chunks.sort_by_key(|chunk| chunk.offset);
        let bytes = backend.download_log(job_id, &stream)?;
        let mut expected_offset = 0_u64;
        for chunk in &chunks {
            if chunk.offset != expected_offset {
                return Err(BackendFailure::new("remote_log_discontinuous", false));
            }
            let end = chunk
                .offset
                .checked_add(chunk.length)
                .and_then(|value| usize::try_from(value).ok())
                .ok_or_else(|| BackendFailure::new("remote_log_size_invalid", false))?;
            let start = usize::try_from(chunk.offset)
                .map_err(|_| BackendFailure::new("remote_log_size_invalid", false))?;
            let slice = bytes
                .get(start..end)
                .ok_or_else(|| BackendFailure::new("remote_log_size_mismatch", false))?;
            if sha256_hex(slice) != chunk.sha256 {
                return Err(BackendFailure::new("remote_log_digest_mismatch", false));
            }
            expected_offset = expected_offset.saturating_add(chunk.length);
        }
        if expected_offset != bytes.len() as u64 {
            return Err(BackendFailure::new("remote_log_size_mismatch", false));
        }
        if stream == "stdout" {
            stdout_marker_found = bytes
                .windows(STDOUT_PROOF.len())
                .any(|window| window == STDOUT_PROOF);
            snapshot_input_found = bytes
                .windows(SNAPSHOT_STDOUT_PROOF.len())
                .any(|window| window == SNAPSHOT_STDOUT_PROOF);
        } else if stream == "stderr" {
            stderr_marker_found = bytes
                .windows(STDERR_PROOF.len())
                .any(|window| window == STDERR_PROOF);
        }
        evidence.push(LogEvidence {
            stream,
            size_bytes: bytes.len() as u64,
            sha256: sha256_hex(&bytes),
            chunk_count: chunks.len(),
        });
    }
    if stream_names.len() != 2
        || !stream_names.contains("stdout")
        || !stream_names.contains("stderr")
        || !stdout_marker_found
        || !snapshot_input_found
        || !stderr_marker_found
    {
        return Err(BackendFailure::new("remote_log_marker_missing", false));
    }
    Ok(evidence)
}

fn verify_artifact(
    backend: &dyn FullRunBackend,
    job_id: Uuid,
    run: &Run,
) -> Result<ArtifactEvidence, BackendFailure> {
    let listing = backend.list_artifacts(job_id)?;
    if listing.artifacts.len() != 1 {
        return Err(BackendFailure::new("proof_artifact_missing", false));
    }
    let matches = listing
        .artifacts
        .into_iter()
        .filter(|artifact| artifact.name == ARTIFACT_NAME)
        .collect::<Vec<_>>();
    let [metadata] = matches.as_slice() else {
        return Err(BackendFailure::new("proof_artifact_missing", false));
    };
    if metadata.run_id != run.id
        || run.artifact_ids.as_slice() != [metadata.id]
        || metadata.size == 0
        || metadata.size > MAX_ARTIFACT_PROOF_BYTES
        || !valid_sha256(&metadata.sha256)
    {
        return Err(BackendFailure::new(
            "proof_artifact_metadata_invalid",
            false,
        ));
    }
    let bytes = backend.download_artifact(job_id, metadata.id)?;
    let actual = sha256_hex(&bytes);
    if bytes.len() as u64 != metadata.size || actual != metadata.sha256 {
        return Err(BackendFailure::new("proof_artifact_digest_mismatch", false));
    }
    if !artifact_proof_matches(&bytes) {
        return Err(BackendFailure::new("proof_artifact_content_invalid", false));
    }
    Ok(ArtifactEvidence {
        id: metadata.id.to_string(),
        name: metadata.name.clone(),
        size_bytes: metadata.size,
        sha256: actual,
    })
}

/// PowerShell 5.1 redirection writes UTF-16LE while PowerShell 7 and POSIX
/// shells write UTF-8. Accept exactly the fixed proof text in those encodings;
/// SHA-256 and declared length are still verified over the original bytes.
fn artifact_proof_matches(bytes: &[u8]) -> bool {
    let utf8 = bytes.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(bytes);
    if let Ok(text) = std::str::from_utf8(utf8) {
        if artifact_proof_text_matches(text) {
            return true;
        }
    }

    let utf16 = bytes.strip_prefix(&[0xff, 0xfe]).unwrap_or(bytes);
    if utf16.is_empty() || utf16.len() % 2 != 0 {
        return false;
    }
    // Without a BOM only accept an unmistakable ASCII-shaped UTF-16LE stream.
    if !bytes.starts_with(&[0xff, 0xfe]) && !utf16.chunks_exact(2).all(|pair| pair[1] == 0) {
        return false;
    }
    let units = utf16
        .chunks_exact(2)
        .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
        .collect::<Vec<_>>();
    String::from_utf16(&units).is_ok_and(|text| artifact_proof_text_matches(&text))
}

fn artifact_proof_text_matches(text: &str) -> bool {
    text.strip_suffix("\r\n")
        .or_else(|| text.strip_suffix('\n'))
        .unwrap_or(text)
        == ARTIFACT_PROOF_TEXT
}

struct HttpFullRunBackend<'a> {
    inner: &'a FullRunCheckManagerInner,
    integration: Option<&'a IntegrationManager>,
}

impl HttpFullRunBackend<'_> {
    fn request(&self, method: Method, path: &str) -> Result<RequestBuilder, BackendFailure> {
        let token = load_token(&self.inner.token_file)
            .map_err(|_| BackendFailure::new("controller_auth_unavailable", true))?;
        let encoded = Zeroizing::new(format!("Bearer {}", token.as_str()));
        let mut authorization = HeaderValue::from_str(encoded.as_str())
            .map_err(|_| BackendFailure::new("controller_auth_unavailable", false))?;
        authorization.set_sensitive(true);
        Ok(self
            .inner
            .client
            .request(method, format!("{CONTROLLER_ORIGIN}{path}"))
            .header(ACCEPT, "application/json")
            .header(AUTHORIZATION, authorization))
    }

    fn send_json<T: DeserializeOwned>(
        &self,
        request: RequestBuilder,
        expected: StatusCode,
    ) -> Result<T, BackendFailure> {
        let response = request
            .send()
            .map_err(|_| BackendFailure::new("controller_unavailable", true))?;
        if response.status() != expected {
            return Err(status_failure(response.status()));
        }
        let content_type = response
            .headers()
            .get(CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.split(';').next())
            .map(str::trim);
        if content_type != Some("application/json") {
            return Err(BackendFailure::new("controller_response_invalid", false));
        }
        let bytes = read_bounded(response, MAX_JSON_RESPONSE_BYTES)?;
        serde_json::from_slice(&bytes)
            .map_err(|_| BackendFailure::new("controller_response_invalid", false))
    }

    fn send_bytes(
        &self,
        request: RequestBuilder,
        expected_content_type: &str,
        maximum: usize,
    ) -> Result<Vec<u8>, BackendFailure> {
        let response = request
            .send()
            .map_err(|_| BackendFailure::new("controller_unavailable", true))?;
        if response.status() != StatusCode::OK {
            return Err(status_failure(response.status()));
        }
        let content_type = response
            .headers()
            .get(CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.split(';').next())
            .map(str::trim);
        if content_type != Some(expected_content_type) {
            return Err(BackendFailure::new("controller_response_invalid", false));
        }
        read_bounded(response, maximum)
    }
}

impl FullRunBackend for HttpFullRunBackend<'_> {
    fn fleet(&self) -> Result<FleetResponse, BackendFailure> {
        let request = self.request(Method::GET, "/v1/fleet")?;
        self.send_json(request, StatusCode::OK)
    }

    fn mcp_full_run_pipeline(
        &self,
        job_id: Uuid,
        timeout: Duration,
    ) -> Result<McpFullRunReceipt, McpPipelineFailure> {
        let integration = self.integration.ok_or_else(|| {
            McpPipelineFailure::new(
                McpPipelineStage::Info,
                "plugin_mcp_pipeline_unavailable",
                false,
            )
        })?;
        if timeout.is_zero() {
            return Err(McpPipelineFailure::new(
                McpPipelineStage::Info,
                "plugin_mcp_pipeline_timeout",
                true,
            ));
        }
        let fixture = McpFixture::create()?;
        let workspace_argument = fixture.workspace_argument()?.to_owned();
        let archive_argument = fixture.archive_argument()?.to_owned();
        let pipeline_timeout = timeout.min(MCP_PIPELINE_TIMEOUT);
        let operation = integration.with_mcp_session(
            pipeline_timeout,
            |session| -> Result<McpFullRunReceipt, McpOperationError> {
                let executor = session.executor_identity().clone();
                let fleet = session
                    .call_tool("fleet_info", serde_json::json!({}), MCP_TOOL_TIMEOUT)
                    .map_err(|_| {
                        McpOperationError::from(McpPipelineFailure::integration(
                            McpPipelineStage::Info,
                        ))
                    })?;
                if fleet.get("health").is_none() || fleet.get("fleet").is_none() {
                    return Err(McpPipelineFailure::new(
                        McpPipelineStage::Info,
                        "plugin_fleet_info_invalid",
                        false,
                    )
                    .into());
                }
                let packed = session
                    .call_tool(
                        "workspace_snapshot_pack",
                        serde_json::json!({
                            "workspacePath": workspace_argument,
                            "outputPath": archive_argument,
                            "include": ["input.txt"]
                        }),
                        MCP_TOOL_TIMEOUT,
                    )
                    .map_err(|_| {
                        McpOperationError::from(McpPipelineFailure::integration(
                            McpPipelineStage::Pack,
                        ))
                    })?;
                let descriptor: PackedSnapshotDescriptor =
                    serde_json::from_value(packed).map_err(|_| {
                        McpPipelineFailure::new(
                            McpPipelineStage::Pack,
                            "snapshot_descriptor_invalid",
                            false,
                        )
                    })?;
                let snapshot = read_and_validate_mcp_snapshot(&descriptor, &fixture.archive)?;

                let uploaded = session
                    .call_tool(
                        "fleet_snapshot_upload",
                        serde_json::json!({
                            "archivePath": archive_argument,
                            "digest": descriptor.digest,
                            "sizeBytes": descriptor.size_bytes
                        }),
                        MCP_TOOL_TIMEOUT,
                    )
                    .map_err(|_| {
                        McpOperationError::from(McpPipelineFailure::integration(
                            McpPipelineStage::Upload,
                        ))
                    })?;
                let metadata: SnapshotMetadataV1 =
                    serde_json::from_value(uploaded).map_err(|_| {
                        McpPipelineFailure::new(
                            McpPipelineStage::Upload,
                            "snapshot_receipt_invalid",
                            false,
                        )
                    })?;

                let mut job = build_portable_job(&snapshot).map_err(|_| {
                    McpPipelineFailure::new(McpPipelineStage::PlanSubmit, "job_spec_invalid", false)
                })?;
                job.id = job_id;
                job.validate().map_err(|_| {
                    McpPipelineFailure::new(McpPipelineStage::PlanSubmit, "job_spec_invalid", false)
                })?;
                let planned = session
                    .call_tool(
                        "fleet_plan_submit",
                        serde_json::json!({"job": job}),
                        MCP_TOOL_TIMEOUT,
                    )
                    .map_err(|_| {
                        McpOperationError::from(McpPipelineFailure::integration(
                            McpPipelineStage::PlanSubmit,
                        ))
                    })?;
                let planned: McpPlanSubmitResponse =
                    serde_json::from_value(planned).map_err(|_| {
                        McpPipelineFailure::new(
                            McpPipelineStage::PlanSubmit,
                            "placement_submission_receipt_invalid",
                            false,
                        )
                    })?;

                let submitted_cleanup = cleanup_target_from_untrusted(&planned.submission, job.id);

                let initial = session
                    .call_tool(
                        "fleet_job",
                        serde_json::json!({"jobId": job.id}),
                        MCP_TOOL_TIMEOUT,
                    )
                    .map_err(|_| {
                        let mut failure = McpPipelineFailure::integration(McpPipelineStage::Job);
                        failure.cleanup_target = submitted_cleanup;
                        McpOperationError::from(failure)
                    })?;
                let initial_job: JobView = serde_json::from_value(initial).map_err(|_| {
                    let mut failure = McpPipelineFailure::new(
                        McpPipelineStage::Job,
                        "initial_job_receipt_invalid",
                        false,
                    );
                    failure.cleanup_target = submitted_cleanup;
                    failure
                })?;
                Ok(McpFullRunReceipt {
                    executor,
                    snapshot,
                    descriptor,
                    metadata,
                    job,
                    plan: planned.plan,
                    submission: planned.submission,
                    initial_job,
                })
            },
        );
        operation.map_err(|error| {
            let mut failure = match error {
                McpOperationError::Pipeline(failure) => failure,
                McpOperationError::Integration(error) => {
                    let retryable = matches!(error, IntegrationError::OperationUnavailable);
                    McpPipelineFailure::new(
                        McpPipelineStage::Info,
                        "plugin_mcp_pipeline_failed",
                        retryable,
                    )
                }
            };
            if failure.cleanup_target.is_none()
                && matches!(
                    failure.stage,
                    McpPipelineStage::PlanSubmit | McpPipelineStage::Job
                )
            {
                failure.cleanup_target = self
                    .get_job_optional(job_id)
                    .ok()
                    .flatten()
                    .as_ref()
                    .and_then(|view| cleanup_target_from_untrusted(view, job_id));
            }
            failure
        })
    }

    fn upload_snapshot(
        &self,
        snapshot: &SnapshotPayload,
    ) -> Result<SnapshotMetadataV1, BackendFailure> {
        let request = self
            .request(
                Method::PUT,
                &format!("/v1/snapshots/{}", snapshot.digest_hex()),
            )?
            .header(CONTENT_TYPE, SNAPSHOT_MEDIA_TYPE)
            .header(CONTENT_LENGTH, snapshot.bytes.len().to_string())
            .body(snapshot.bytes.clone());
        self.send_json(request, StatusCode::CREATED)
    }

    fn plan(&self, job: &JobSpec) -> Result<PlanResponse, BackendFailure> {
        let request = self
            .request(Method::POST, "/v1/plans")?
            .header(CONTENT_TYPE, "application/json")
            .json(&serde_json::json!({ "job": job }));
        self.send_json(request, StatusCode::OK)
    }

    fn submit(&self, job: &JobSpec, plan_id: Uuid) -> Result<JobView, BackendFailure> {
        let request = self
            .request(Method::POST, "/v1/jobs")?
            .header(CONTENT_TYPE, "application/json")
            .json(&serde_json::json!({ "job": job, "planId": plan_id }));
        self.send_json(request, StatusCode::CREATED)
    }

    fn get_job_optional(&self, job_id: Uuid) -> Result<Option<JobView>, BackendFailure> {
        let response = self
            .request(Method::GET, &format!("/v1/jobs/{job_id}"))?
            .send()
            .map_err(|_| BackendFailure::new("controller_unavailable", true))?;
        if response.status() == StatusCode::NOT_FOUND {
            return Ok(None);
        }
        if response.status() != StatusCode::OK {
            return Err(status_failure(response.status()));
        }
        let content_type = response
            .headers()
            .get(CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.split(';').next())
            .map(str::trim);
        if content_type != Some("application/json") {
            return Err(BackendFailure::new("controller_response_invalid", false));
        }
        let bytes = read_bounded(response, MAX_JSON_RESPONSE_BYTES)?;
        serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|_| BackendFailure::new("controller_response_invalid", false))
    }

    fn get_job(&self, job_id: Uuid) -> Result<JobView, BackendFailure> {
        let request = self.request(Method::GET, &format!("/v1/jobs/{job_id}"))?;
        self.send_json(request, StatusCode::OK)
    }

    fn cancel(&self, job_id: Uuid, version: u64) -> Result<JobView, BackendFailure> {
        let request = self
            .request(Method::POST, &format!("/v1/jobs/{job_id}/cancel"))?
            .header(IF_MATCH, format!("\"{version}\""))
            .body(Vec::new());
        self.send_json(request, StatusCode::OK)
    }

    fn list_logs(&self, job_id: Uuid) -> Result<JobLogsResponse, BackendFailure> {
        let request = self.request(Method::GET, &format!("/v1/jobs/{job_id}/logs"))?;
        self.send_json(request, StatusCode::OK)
    }

    fn download_log(&self, job_id: Uuid, stream: &str) -> Result<Vec<u8>, BackendFailure> {
        if !matches!(stream, "stdout" | "stderr") {
            return Err(BackendFailure::new("remote_log_stream_invalid", false));
        }
        let request = self.request(Method::GET, &format!("/v1/jobs/{job_id}/logs/{stream}"))?;
        self.send_bytes(request, "text/plain", MAX_LOG_RESPONSE_BYTES)
    }

    fn list_artifacts(&self, job_id: Uuid) -> Result<JobArtifactsResponse, BackendFailure> {
        let request = self.request(Method::GET, &format!("/v1/jobs/{job_id}/artifacts"))?;
        self.send_json(request, StatusCode::OK)
    }

    fn download_artifact(
        &self,
        job_id: Uuid,
        artifact_id: Uuid,
    ) -> Result<Vec<u8>, BackendFailure> {
        let request = self.request(
            Method::GET,
            &format!("/v1/jobs/{job_id}/artifacts/{artifact_id}"),
        )?;
        self.send_bytes(
            request,
            "application/octet-stream",
            MAX_PROOF_RESPONSE_BYTES,
        )
    }

    fn cleanup_receipt(&self, job_id: Uuid) -> Result<CleanupStatusV1, BackendFailure> {
        let request = self.request(Method::GET, &format!("/v1/jobs/{job_id}/cleanup"))?;
        self.send_json(request, StatusCode::OK)
    }
}

fn read_bounded(response: BlockingResponse, maximum: usize) -> Result<Vec<u8>, BackendFailure> {
    if response
        .content_length()
        .is_some_and(|length| length > maximum as u64)
    {
        return Err(BackendFailure::new("controller_response_too_large", false));
    }
    let mut bytes = Vec::new();
    response
        .take((maximum + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| BackendFailure::new("controller_unavailable", true))?;
    if bytes.len() > maximum {
        return Err(BackendFailure::new("controller_response_too_large", false));
    }
    Ok(bytes)
}

fn status_failure(status: StatusCode) -> BackendFailure {
    match status {
        StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => {
            BackendFailure::new("controller_auth_unavailable", false)
        }
        StatusCode::CONFLICT | StatusCode::PRECONDITION_FAILED => {
            BackendFailure::new("controller_conflict", true)
        }
        StatusCode::TOO_MANY_REQUESTS => BackendFailure::new("controller_rate_limited", true),
        status if status.is_server_error() => BackendFailure::new("controller_unavailable", true),
        _ => BackendFailure::new("controller_request_rejected", false),
    }
}

fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn valid_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn timestamp(value: DateTime<Utc>) -> String {
    value.to_rfc3339_opts(SecondsFormat::Millis, true)
}

fn operating_system_name(value: OperatingSystem) -> &'static str {
    match value {
        OperatingSystem::Windows => "windows",
        OperatingSystem::Linux => "linux",
        OperatingSystem::Macos => "macos",
    }
}

fn architecture_name(value: Architecture) -> &'static str {
    match value {
        Architecture::X86_64 => "x86_64",
        Architecture::Aarch64 => "aarch64",
    }
}

fn job_state_name(value: JobState) -> &'static str {
    match value {
        JobState::Queued => "queued",
        JobState::Preparing => "preparing",
        JobState::Running => "running",
        JobState::Verifying => "verifying",
        JobState::Succeeded => "succeeded",
        JobState::Failed => "failed",
        JobState::Cancelled => "cancelled",
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::{mpsc, Arc};

    use cyc_protocol::{CredentialRef, NodeResources, PlacementCandidateExplain, ScoreComponent};

    use super::*;

    struct PassingPlugin;

    impl PluginProbe for PassingPlugin {
        fn active_runtime(&self) -> Result<Option<ActiveRuntimeIdentity>, BackendFailure> {
            Ok(Some(ActiveRuntimeIdentity {
                pid: 1,
                started_at: Utc::now(),
                bridge_version: "0.1.0".to_owned(),
            }))
        }

        fn wait_for_runtime_refresh(
            &self,
            _expected: &ActiveRuntimeIdentity,
            _after: DateTime<Utc>,
        ) -> Result<bool, BackendFailure> {
            Ok(true)
        }
    }

    struct DisconnectingPlugin;

    impl PluginProbe for DisconnectingPlugin {
        fn active_runtime(&self) -> Result<Option<ActiveRuntimeIdentity>, BackendFailure> {
            Ok(Some(ActiveRuntimeIdentity {
                pid: 1,
                started_at: Utc::now(),
                bridge_version: "0.1.0".to_owned(),
            }))
        }

        fn wait_for_runtime_refresh(
            &self,
            _expected: &ActiveRuntimeIdentity,
            _after: DateTime<Utc>,
        ) -> Result<bool, BackendFailure> {
            Ok(false)
        }
    }

    struct FakeBackend {
        node: Node,
        run_id: Uuid,
        artifact_id: Uuid,
        run_created_at: DateTime<Utc>,
        remain_queued: AtomicBool,
        corrupt_artifact: AtomicBool,
        omit_snapshot_log: AtomicBool,
        artifact_bytes: Mutex<Vec<u8>>,
        cancellations: AtomicUsize,
        submissions: AtomicUsize,
        submitted_job: Mutex<Option<JobSpec>>,
        planned: Mutex<Option<PlanResponse>>,
        self_test_executor_pid: AtomicUsize,
        mcp_failure_stage: Mutex<Option<McpPipelineStage>>,
        mcp_trace: Mutex<Vec<&'static str>>,
        lose_next_submit_response: AtomicBool,
    }

    impl FakeBackend {
        fn new() -> Self {
            let mut node = Node::new(
                "fixture-worker",
                NodeTransport::Managed {
                    endpoint: "https://fixture.invalid".to_owned(),
                    credential_ref: CredentialRef::new("fixture-ref"),
                },
                OperatingSystem::Linux,
                Architecture::X86_64,
            );
            node.status = NodeStatus::Online;
            node.priority = 100;
            node.resources = NodeResources {
                logical_cpu_cores: 8,
                available_cpu_cores: 6,
                memory_mib: 16_384,
                available_memory_mib: 12_288,
                disk_mib: 100_000,
                available_disk_mib: 80_000,
                gpus: Vec::new(),
            };
            node.last_seen_at = Some(Utc::now());
            Self {
                node,
                run_id: Uuid::new_v4(),
                artifact_id: Uuid::new_v4(),
                run_created_at: Utc::now(),
                remain_queued: AtomicBool::new(false),
                corrupt_artifact: AtomicBool::new(false),
                omit_snapshot_log: AtomicBool::new(false),
                artifact_bytes: Mutex::new(ARTIFACT_PROOF.to_vec()),
                cancellations: AtomicUsize::new(0),
                submissions: AtomicUsize::new(0),
                submitted_job: Mutex::new(None),
                planned: Mutex::new(None),
                self_test_executor_pid: AtomicUsize::new(2),
                mcp_failure_stage: Mutex::new(None),
                mcp_trace: Mutex::new(Vec::new()),
                lose_next_submit_response: AtomicBool::new(false),
            }
        }

        fn make_plan(&self, job: &JobSpec) -> PlanResponse {
            let now = Utc::now();
            let score = 42;
            PlanResponse {
                api_version: cyc_protocol::PLACEMENT_PLAN_BINDING_API_VERSION.to_owned(),
                plan_id: Uuid::new_v4(),
                job_id: job.id,
                job_digest: cyc_protocol::canonical_job_digest(job).expect("fixture digest"),
                created_at: now,
                expires_at: now + chrono::Duration::seconds(30),
                fleet_revision: 11,
                node_revision: 7,
                policy_revision: 3,
                decision: cyc_protocol::PlacementPlanDecisionV1 {
                    node_id: self.node.id,
                    score,
                    explanation: PlacementExplain {
                        policy: job.placement_policy,
                        selected_node_id: Some(self.node.id),
                        candidates: vec![PlacementCandidateExplain {
                            node_id: self.node.id,
                            node_name: self.node.name.clone(),
                            eligible: true,
                            score: Some(score),
                            score_components: vec![ScoreComponent {
                                key: "fixture_score".to_owned(),
                                value: score,
                                detail: "deterministic fixture score".to_owned(),
                            }],
                            rejection_reasons: Vec::new(),
                        }],
                    },
                },
            }
        }

        fn job_view(&self, terminal: bool) -> JobView {
            let job = self
                .submitted_job
                .lock()
                .unwrap()
                .clone()
                .expect("job was submitted");
            // A controller receipt may be read repeatedly.  Its immutable
            // execution timestamps must therefore remain byte-for-byte
            // stable across polls; generating `Utc::now()` here made the
            // fail-closed progress validator correctly reject the fixture.
            let started_at = self.run_created_at + chrono::Duration::milliseconds(1);
            let finished_at = started_at + chrono::Duration::milliseconds(1);
            let placement = self
                .planned
                .lock()
                .unwrap()
                .as_ref()
                .map(|plan| plan.decision.explanation.clone())
                .expect("job has a bound plan");
            JobView {
                run: Run {
                    id: self.run_id,
                    job_id: job.id,
                    node_id: Some(self.node.id),
                    state: if terminal {
                        JobState::Succeeded
                    } else {
                        JobState::Queued
                    },
                    created_at: self.run_created_at,
                    started_at: terminal.then_some(started_at),
                    finished_at: terminal.then_some(finished_at),
                    exit_code: terminal.then_some(0),
                    error: None,
                    placement: Some(placement),
                    artifact_ids: terminal
                        .then_some(vec![self.artifact_id])
                        .unwrap_or_default(),
                },
                job,
                version: if terminal { 4 } else { 0 },
                cancel_requested: false,
                plan_binding: self.planned.lock().unwrap().clone(),
            }
        }
    }

    fn valid_cleanup_status(job_id: Uuid, run_id: Uuid, state_version: u64) -> CleanupStatusV1 {
        let acknowledged_at = Utc::now();
        CleanupStatusV1 {
            api_version: CLEANUP_API_VERSION.to_owned(),
            job_id,
            run_id,
            status: CleanupStatusPhaseV1::Removed,
            job_root_deleted: true,
            relative_root: Some(format!("jobs/{run_id}")),
            observed_at: Some(acknowledged_at),
            received_at: Some(acknowledged_at),
            terminal_ack: Some(TerminalCompletionAckV1 {
                run_id,
                lease_id: Uuid::new_v4(),
                completion_sha256: "a".repeat(64),
                state_version,
                final_state: JobState::Succeeded,
                acknowledged_at,
            }),
            cleanup_deadline_at: Some(acknowledged_at),
            reservation_released_at: Some(acknowledged_at),
            release_reason: Some(CleanupReservationReleaseReasonV1::RemovedReceipt),
            cleanup_failure: None,
        }
    }

    impl FullRunBackend for FakeBackend {
        fn fleet(&self) -> Result<FleetResponse, BackendFailure> {
            let mut node = self.node.clone();
            let observed_at = Utc::now() + chrono::Duration::milliseconds(1);
            node.last_seen_at = Some(observed_at);
            Ok(FleetResponse {
                fleet_revision: 11,
                observed_at,
                nodes: vec![node],
            })
        }

        fn mcp_full_run_pipeline(
            &self,
            job_id: Uuid,
            _timeout: Duration,
        ) -> Result<McpFullRunReceipt, McpPipelineFailure> {
            let fails_at = *self.mcp_failure_stage.lock().unwrap();
            self.mcp_trace.lock().unwrap().push("fleet_info");
            if fails_at == Some(McpPipelineStage::Info) {
                return Err(McpPipelineFailure::integration(McpPipelineStage::Info));
            }
            self.mcp_trace
                .lock()
                .unwrap()
                .push("workspace_snapshot_pack");
            if fails_at == Some(McpPipelineStage::Pack) {
                return Err(McpPipelineFailure::integration(McpPipelineStage::Pack));
            }
            let snapshot = build_snapshot().map_err(|_| {
                McpPipelineFailure::new(McpPipelineStage::Pack, "snapshot_pack_failed", false)
            })?;
            let descriptor = PackedSnapshotDescriptor {
                api_version: SNAPSHOT_API_VERSION.to_owned(),
                format: SNAPSHOT_ARCHIVE_FORMAT.to_owned(),
                digest: snapshot.digest.clone(),
                size_bytes: snapshot.size_bytes(),
                archive_path: std::env::temp_dir().join("fixture.tar.zst"),
                file_count: 1,
                expanded_size_bytes: SNAPSHOT_INPUT.len() as u64,
                skipped_count: 0,
            };

            self.mcp_trace.lock().unwrap().push("fleet_snapshot_upload");
            if fails_at == Some(McpPipelineStage::Upload) {
                return Err(McpPipelineFailure::integration(McpPipelineStage::Upload));
            }
            let metadata =
                self.upload_snapshot(&snapshot)
                    .map_err(|failure| McpPipelineFailure {
                        stage: McpPipelineStage::Upload,
                        failure,
                        cleanup_target: None,
                    })?;

            self.mcp_trace.lock().unwrap().push("fleet_plan_submit");
            if fails_at == Some(McpPipelineStage::PlanSubmit) {
                return Err(McpPipelineFailure::integration(
                    McpPipelineStage::PlanSubmit,
                ));
            }
            let mut job = build_portable_job(&snapshot).map_err(|_| {
                McpPipelineFailure::new(McpPipelineStage::PlanSubmit, "job_spec_invalid", false)
            })?;
            job.id = job_id;
            let plan = self.plan(&job).map_err(|failure| McpPipelineFailure {
                stage: McpPipelineStage::PlanSubmit,
                failure,
                cleanup_target: None,
            })?;
            let submission =
                self.submit(&job, plan.plan_id)
                    .map_err(|failure| McpPipelineFailure {
                        stage: McpPipelineStage::PlanSubmit,
                        failure,
                        cleanup_target: None,
                    })?;

            self.mcp_trace.lock().unwrap().push("fleet_job");
            let cleanup = cleanup_target_from_untrusted(&submission, job.id);
            if fails_at == Some(McpPipelineStage::Job) {
                let mut failure = McpPipelineFailure::integration(McpPipelineStage::Job);
                failure.cleanup_target = cleanup;
                return Err(failure);
            }
            let initial_job = self.get_job(job.id).map_err(|failure| McpPipelineFailure {
                stage: McpPipelineStage::Job,
                failure,
                cleanup_target: cleanup,
            })?;
            Ok(McpFullRunReceipt {
                executor: SelfTestExecutorIdentity {
                    pid: u32::try_from(self.self_test_executor_pid.load(Ordering::SeqCst))
                        .expect("fixture executor pid"),
                    started_at: Utc::now(),
                    bridge_version: "0.1.0".to_owned(),
                    session_id: Uuid::new_v4(),
                },
                snapshot,
                descriptor,
                metadata,
                job,
                plan,
                submission,
                initial_job,
            })
        }

        fn upload_snapshot(
            &self,
            snapshot: &SnapshotPayload,
        ) -> Result<SnapshotMetadataV1, BackendFailure> {
            Ok(SnapshotMetadataV1::new(
                snapshot.digest.clone(),
                snapshot.size_bytes(),
                Utc::now(),
            ))
        }

        fn plan(&self, job: &JobSpec) -> Result<PlanResponse, BackendFailure> {
            let plan = self.make_plan(job);
            *self.planned.lock().unwrap() = Some(plan.clone());
            Ok(plan)
        }

        fn submit(&self, job: &JobSpec, plan_id: Uuid) -> Result<JobView, BackendFailure> {
            if self
                .planned
                .lock()
                .unwrap()
                .as_ref()
                .is_none_or(|plan| plan.plan_id != plan_id || plan.job_id != job.id)
            {
                return Err(BackendFailure::new("fixture_plan_mismatch", false));
            }
            self.submissions.fetch_add(1, Ordering::SeqCst);
            *self.submitted_job.lock().unwrap() = Some(job.clone());
            let submitted = self.job_view(false);
            if self.lose_next_submit_response.swap(false, Ordering::SeqCst) {
                Err(BackendFailure::new("controller_unavailable", true))
            } else {
                Ok(submitted)
            }
        }

        fn get_job_optional(&self, _job_id: Uuid) -> Result<Option<JobView>, BackendFailure> {
            if self.submitted_job.lock().unwrap().is_some() {
                Ok(Some(
                    self.job_view(!self.remain_queued.load(Ordering::SeqCst)),
                ))
            } else {
                Ok(None)
            }
        }

        fn get_job(&self, _job_id: Uuid) -> Result<JobView, BackendFailure> {
            Ok(self.job_view(!self.remain_queued.load(Ordering::SeqCst)))
        }

        fn cancel(&self, job_id: Uuid, _version: u64) -> Result<JobView, BackendFailure> {
            self.cancellations.fetch_add(1, Ordering::SeqCst);
            let mut view = self.job_view(false);
            assert_eq!(view.job.id, job_id);
            view.cancel_requested = true;
            Ok(view)
        }

        fn list_logs(&self, _job_id: Uuid) -> Result<JobLogsResponse, BackendFailure> {
            let stdout: &[u8] = if self.omit_snapshot_log.load(Ordering::SeqCst) {
                b"CYC_FULL_RUN_EXECUTED\n"
            } else {
                b"ClusterYourCodex full run check\nCYC_FULL_RUN_EXECUTED\n"
            };
            let stderr = b"CYC_FULL_RUN_STDERR\n";
            Ok(JobLogsResponse {
                chunks: vec![
                    LogChunk {
                        run_id: self.run_id,
                        stream: "stdout".to_owned(),
                        offset: 0,
                        length: stdout.len() as u64,
                        sha256: sha256_hex(stdout),
                    },
                    LogChunk {
                        run_id: self.run_id,
                        stream: "stderr".to_owned(),
                        offset: 0,
                        length: stderr.len() as u64,
                        sha256: sha256_hex(stderr),
                    },
                ],
            })
        }

        fn download_log(&self, _job_id: Uuid, stream: &str) -> Result<Vec<u8>, BackendFailure> {
            match stream {
                "stdout" => Ok(if self.omit_snapshot_log.load(Ordering::SeqCst) {
                    b"CYC_FULL_RUN_EXECUTED\n".to_vec()
                } else {
                    b"ClusterYourCodex full run check\nCYC_FULL_RUN_EXECUTED\n".to_vec()
                }),
                "stderr" => Ok(b"CYC_FULL_RUN_STDERR\n".to_vec()),
                _ => Err(BackendFailure::new("remote_log_stream_invalid", false)),
            }
        }

        fn list_artifacts(&self, _job_id: Uuid) -> Result<JobArtifactsResponse, BackendFailure> {
            let bytes = self.artifact_bytes.lock().unwrap();
            Ok(JobArtifactsResponse {
                artifacts: vec![ArtifactMetadata {
                    id: self.artifact_id,
                    run_id: self.run_id,
                    name: ARTIFACT_NAME.to_owned(),
                    size: bytes.len() as u64,
                    sha256: sha256_hex(bytes.as_slice()),
                }],
            })
        }

        fn download_artifact(
            &self,
            _job_id: Uuid,
            _artifact_id: Uuid,
        ) -> Result<Vec<u8>, BackendFailure> {
            if self.corrupt_artifact.load(Ordering::SeqCst) {
                Ok(b"corrupt\n".to_vec())
            } else {
                Ok(self.artifact_bytes.lock().unwrap().clone())
            }
        }

        fn cleanup_receipt(&self, job_id: Uuid) -> Result<CleanupStatusV1, BackendFailure> {
            assert_eq!(
                self.submitted_job
                    .lock()
                    .unwrap()
                    .as_ref()
                    .map(|job| job.id),
                Some(job_id)
            );
            Ok(valid_cleanup_status(job_id, self.run_id, 4))
        }
    }

    #[test]
    fn embedded_snapshot_is_deterministic_and_contains_only_the_fixture() {
        let first = build_snapshot().unwrap();
        let second = build_snapshot().unwrap();
        assert_eq!(first.digest, second.digest);
        assert_eq!(first.bytes, second.bytes);
        let decoded = zstd::stream::decode_all(Cursor::new(first.bytes)).unwrap();
        let mut archive = tar::Archive::new(Cursor::new(decoded));
        let mut entries = archive.entries().unwrap();
        let mut entry = entries.next().unwrap().unwrap();
        assert_eq!(
            entry.path().unwrap().as_ref(),
            std::path::Path::new("input.txt")
        );
        let mut payload = Vec::new();
        entry.read_to_end(&mut payload).unwrap();
        assert_eq!(payload, SNAPSHOT_INPUT);
        assert!(entries.next().is_none());
    }

    #[test]
    fn plan_validation_binds_digest_policy_score_revisions_and_explanation() {
        let backend = FakeBackend::new();
        let snapshot = build_snapshot().unwrap();
        let job = build_portable_job(&snapshot).unwrap();
        let plan = backend.make_plan(&job);
        assert!(validate_plan_response(&plan, &job, Utc::now()).is_ok());

        let mut wrong_api = plan.clone();
        wrong_api.api_version = "cyc.dev/placement-plan-binding/v999".to_owned();
        assert!(validate_plan_response(&wrong_api, &job, Utc::now()).is_err());

        let mut wrong_digest = plan.clone();
        wrong_digest.job_digest = "0".repeat(64);
        assert_eq!(
            validate_plan_response(&wrong_digest, &job, Utc::now())
                .unwrap_err()
                .code,
            "placement_plan_mismatch"
        );

        let mut wrong_policy = plan.clone();
        wrong_policy.decision.explanation.policy = PlacementPolicy::Balanced;
        assert!(validate_plan_response(&wrong_policy, &job, Utc::now()).is_err());

        let mut wrong_score = plan.clone();
        wrong_score.decision.explanation.candidates[0].score = Some(plan.decision.score + 1);
        assert!(validate_plan_response(&wrong_score, &job, Utc::now()).is_err());

        let mut missing_components = plan.clone();
        missing_components.decision.explanation.candidates[0]
            .score_components
            .clear();
        assert!(validate_plan_response(&missing_components, &job, Utc::now()).is_err());

        let mut contradictory_rejection = plan.clone();
        contradictory_rejection.decision.explanation.candidates[0]
            .rejection_reasons
            .push(cyc_protocol::PlacementRejection {
                code: cyc_protocol::RejectionCode::Offline,
                detail: "contradicts eligible=true".to_owned(),
            });
        assert!(validate_plan_response(&contradictory_rejection, &job, Utc::now()).is_err());

        let mut duplicate_candidate = plan.clone();
        let repeated = duplicate_candidate.decision.explanation.candidates[0].clone();
        duplicate_candidate
            .decision
            .explanation
            .candidates
            .push(repeated);
        assert!(validate_plan_response(&duplicate_candidate, &job, Utc::now()).is_err());

        let mut stale_revision = plan;
        stale_revision.fleet_revision = -1;
        assert!(validate_plan_response(&stale_revision, &job, Utc::now()).is_err());
    }

    #[test]
    fn refreshed_run_explanation_may_change_score_but_not_selected_node() {
        let backend = FakeBackend::new();
        let snapshot = build_snapshot().unwrap();
        let job = build_portable_job(&snapshot).unwrap();
        let plan = backend.plan(&job).unwrap();
        let mut view = backend.submit(&job, plan.plan_id).unwrap();
        assert!(validate_job_identity(&view, &job, &plan).is_ok());
        view.run.placement.as_mut().expect("placement").candidates[0].score =
            Some(plan.decision.score + 1);
        view.run.placement.as_mut().expect("placement").candidates[0].score_components[0].value =
            plan.decision.score + 1;
        assert!(validate_job_identity(&view, &job, &plan).is_ok());

        let mut missing_binding = view.clone();
        missing_binding.plan_binding = None;
        assert_eq!(
            validate_job_identity(&missing_binding, &job, &plan)
                .unwrap_err()
                .code,
            "job_plan_binding_missing"
        );

        let mut tampered_binding = view.clone();
        tampered_binding
            .plan_binding
            .as_mut()
            .expect("plan binding")
            .decision
            .score += 1;
        assert_eq!(
            validate_job_identity(&tampered_binding, &job, &plan)
                .unwrap_err()
                .code,
            "job_plan_binding_mismatch"
        );

        view.run.node_id = Some(Uuid::new_v4());
        assert_eq!(
            validate_job_identity(&view, &job, &plan).unwrap_err().code,
            "job_receipt_mismatch"
        );
    }

    #[test]
    fn run_receipts_and_poll_progress_fail_closed() {
        let backend = FakeBackend::new();
        let snapshot = build_snapshot().unwrap();
        let job = build_portable_job(&snapshot).unwrap();
        let plan = backend.plan(&job).unwrap();
        let queued = backend.submit(&job, plan.plan_id).unwrap();

        let mut invalid_success = backend.job_view(true);
        invalid_success.run.error = Some("unexpected terminal error".to_owned());
        assert!(validate_job_identity(&invalid_success, &job, &plan).is_err());

        let mut same_version_transition = queued.clone();
        same_version_transition.run.state = JobState::Preparing;
        assert_eq!(
            validate_job_progress(&queued, &same_version_transition)
                .unwrap_err()
                .code,
            "job_progress_regressed"
        );

        let mut same_version_artifact_mutation = queued.clone();
        same_version_artifact_mutation
            .run
            .artifact_ids
            .push(Uuid::new_v4());
        assert_eq!(
            validate_job_progress(&queued, &same_version_artifact_mutation)
                .unwrap_err()
                .code,
            "job_progress_regressed"
        );

        let mut changed_creation_time = backend.job_view(true);
        changed_creation_time.run.created_at = queued.run.created_at + chrono::Duration::seconds(1);
        assert!(validate_job_progress(&queued, &changed_creation_time).is_err());

        let terminal = backend.job_view(true);
        let mut regressed = queued;
        regressed.version = terminal.version + 1;
        assert!(validate_job_progress(&terminal, &regressed).is_err());
    }

    #[test]
    fn artifact_proof_accepts_utf8_and_powershell_utf16le_only() {
        assert!(artifact_proof_matches(ARTIFACT_PROOF));
        let mut utf16 = vec![0xff, 0xfe];
        for unit in "CYC_FULL_RUN_OK\r\n".encode_utf16() {
            utf16.extend_from_slice(&unit.to_le_bytes());
        }
        assert!(artifact_proof_matches(&utf16));
        assert!(!artifact_proof_matches(b"CYC_FULL_RUN_NOT_OK\n"));
        assert!(!artifact_proof_matches(b" CYC_FULL_RUN_OK\n"));
        assert!(!artifact_proof_matches(b"CYC_FULL_RUN_OK\n\n"));
    }

    #[test]
    fn full_workflow_requires_real_log_and_artifact_digest_evidence() {
        let backend = FakeBackend::new();
        let result = execute_full_run(&backend, &PassingPlugin, Duration::from_secs(2));
        assert_eq!(result.state, FullRunState::Passed);
        assert!(result.failure.is_none());
        assert!(result
            .layers
            .iter()
            .all(|layer| layer.state == LayerState::Passed));
        assert_eq!(result.logs.len(), 2);
        assert_eq!(
            result
                .logs
                .iter()
                .map(|log| log.stream.as_str())
                .collect::<std::collections::BTreeSet<_>>(),
            std::collections::BTreeSet::from(["stderr", "stdout"])
        );
        assert_eq!(result.artifacts.len(), 1);
        assert!(result.placement.is_some());
        let integration = result.integration.as_ref().expect("integration evidence");
        assert!(integration.active_runtime.reverified_after_run);
        assert!(integration
            .active_runtime
            .final_receipt_verified_at
            .is_some());
        let executor = integration
            .self_test_executor
            .as_ref()
            .expect("self-test executor evidence");
        assert_ne!(integration.active_runtime.pid, executor.pid);
        assert!(executor.initialize_completed);
        assert!(executor.tools_list_completed);
        assert_eq!(
            executor.mcp_tools_exercised,
            [
                "fleet_info",
                "workspace_snapshot_pack",
                "fleet_snapshot_upload",
                "fleet_plan_submit",
                "fleet_job",
            ]
        );
        let transport = result.transport.as_ref().expect("transport evidence");
        assert_eq!(transport.transport, "managed_https");
        assert!(transport.tls);
        assert!(transport.credential_reference_present);
        let final_fleet = result.final_fleet.as_ref().expect("final fleet evidence");
        assert!(
            final_fleet.fleet_revision >= result.placement.as_ref().unwrap().fleet_revision as u64
        );
        assert!(!final_fleet.observed_at.is_empty());
        let cleanup = result.cleanup.as_ref().expect("cleanup evidence");
        assert_eq!(cleanup.status, "removed");
        assert!(cleanup.job_root_deleted);
        assert_eq!(cleanup.release_reason, "removed_receipt");
        assert_eq!(cleanup.job_id, result.job.as_ref().unwrap().job_id);
        assert_eq!(cleanup.run_id, result.job.as_ref().unwrap().run_id);
        assert_eq!(backend.cancellations.load(Ordering::SeqCst), 0);
        let submitted = backend.submitted_job.lock().unwrap();
        let submitted = submitted.as_ref().expect("submitted full-run job");
        assert_eq!(submitted.placement_policy, PlacementPolicy::Performance);
        assert!(submitted.preferred_node_id.is_none());
        assert!(submitted.requirements.os.is_none());
        assert!(submitted.requirements.arch.is_none());
        assert!(submitted.steps.iter().all(|step| step.shell.is_none()));
        assert_eq!(
            backend.mcp_trace.lock().unwrap().as_slice(),
            [
                "fleet_info",
                "workspace_snapshot_pack",
                "fleet_snapshot_upload",
                "fleet_plan_submit",
                "fleet_job",
            ]
        );
    }

    #[test]
    fn progress_polling_is_independent_from_the_operation_lock() {
        let manager = FullRunCheckManager::new(PathBuf::from("fixture-token"))
            .expect("fixture manager initializes");
        assert!(
            manager.progress().is_none(),
            "no run must serialize as null"
        );

        let running = FullRunCheckResult::pending(Utc::now());
        manager.publish(&running);
        let operation_guard = manager.inner.operation_lock.lock().unwrap();
        let poller = manager.clone();
        let (sender, receiver) = mpsc::channel();
        thread::spawn(move || {
            sender
                .send(poller.progress())
                .expect("poll result is delivered");
        });

        let snapshot = receiver
            .recv_timeout(Duration::from_millis(250))
            .expect("progress mutex must not wait for the operation lock")
            .expect("published progress exists");
        drop(operation_guard);
        assert_eq!(snapshot.state, FullRunState::Running);
        assert!(snapshot.finished_at.is_none());
        assert!(snapshot.failure.is_none());
        assert!(snapshot
            .layers
            .iter()
            .all(|layer| layer.state == LayerState::Pending));
    }

    #[test]
    fn progress_publishes_phases_worker_changes_and_exact_final_result() {
        let backend = Arc::new(FakeBackend::new());
        backend.remain_queued.store(true, Ordering::SeqCst);
        let release_backend = Arc::clone(&backend);
        let release = thread::spawn(move || {
            thread::sleep(Duration::from_millis(75));
            release_backend.remain_queued.store(false, Ordering::SeqCst);
        });

        let manager = FullRunCheckManager::new(PathBuf::from("fixture-token"))
            .expect("fixture manager initializes");
        let snapshots = Arc::new(Mutex::new(Vec::new()));
        let captured = Arc::clone(&snapshots);
        let result = execute_full_run_with_progress(
            backend.as_ref(),
            &PassingPlugin,
            Duration::from_secs(2),
            &|snapshot| {
                manager.publish(snapshot);
                captured
                    .lock()
                    .unwrap()
                    .push(serde_json::to_value(snapshot).unwrap());
            },
        );
        release.join().unwrap();

        assert_eq!(result.state, FullRunState::Passed);
        let final_status = manager.progress().expect("final progress exists");
        assert_eq!(
            serde_json::to_value(&final_status).unwrap(),
            serde_json::to_value(&result).unwrap(),
            "the final polling snapshot must exactly equal the command response"
        );

        let snapshots = snapshots.lock().unwrap();
        assert!(snapshots.len() > LAYERS.len() * 2);
        assert_eq!(snapshots[0]["state"], "running");
        assert!(snapshots[0].get("finishedAt").is_none());
        assert!(snapshots[0].get("failure").is_none());
        for (layer_id, _) in LAYERS {
            assert!(
                snapshots.iter().any(|snapshot| {
                    snapshot["layers"].as_array().is_some_and(|layers| {
                        layers
                            .iter()
                            .any(|layer| layer["id"] == layer_id && layer["state"] == "running")
                    })
                }),
                "missing running publication for {layer_id}"
            );
            assert!(
                snapshots.iter().any(|snapshot| {
                    snapshot["layers"].as_array().is_some_and(|layers| {
                        layers
                            .iter()
                            .any(|layer| layer["id"] == layer_id && layer["state"] == "passed")
                    })
                }),
                "missing pass publication for {layer_id}"
            );
        }
        assert!(snapshots.iter().any(|snapshot| {
            snapshot["job"]["state"] == "queued"
                && snapshot["job"]["observedStates"] == serde_json::json!(["queued"])
        }));
        assert!(snapshots.iter().any(|snapshot| {
            snapshot["job"]["state"] == "succeeded"
                && snapshot["job"]["observedStates"] == serde_json::json!(["queued", "succeeded"])
        }));
    }

    #[test]
    fn failure_transition_is_published_before_the_final_failed_snapshot() {
        let backend = FakeBackend::new();
        *backend.mcp_failure_stage.lock().unwrap() = Some(McpPipelineStage::Pack);
        let snapshots = Mutex::new(Vec::new());
        let result = execute_full_run_with_progress(
            &backend,
            &PassingPlugin,
            Duration::from_secs(2),
            &|snapshot| snapshots.lock().unwrap().push(snapshot.clone()),
        );

        assert_eq!(result.state, FullRunState::Failed);
        let snapshots = snapshots.lock().unwrap();
        assert!(snapshots.iter().any(|snapshot| {
            snapshot.state == FullRunState::Running
                && snapshot.failure.is_some()
                && snapshot.layer_mut_for_test(LAYER_SNAPSHOT).state == LayerState::Failed
        }));
        assert_eq!(snapshots.last().unwrap().state, FullRunState::Failed);
        assert!(snapshots.last().unwrap().finished_at.is_some());
    }

    #[test]
    fn pass_guard_requires_integration_tls_credential_and_exact_cleanup_binding() {
        let backend = FakeBackend::new();
        let result = execute_full_run(&backend, &PassingPlugin, Duration::from_secs(2));
        assert!(validate_pass_evidence(&result).is_ok());

        let mut missing_integration = result.clone();
        missing_integration
            .integration
            .as_mut()
            .unwrap()
            .active_runtime
            .reverified_after_run = false;
        assert_eq!(
            validate_pass_evidence(&missing_integration)
                .unwrap_err()
                .code,
            "integration_evidence_invalid"
        );

        let mut missing_executor = result.clone();
        missing_executor
            .integration
            .as_mut()
            .unwrap()
            .self_test_executor = None;
        assert_eq!(
            validate_pass_evidence(&missing_executor).unwrap_err().code,
            "self_test_executor_evidence_missing"
        );

        let mut confused_executor = result.clone();
        let integration = confused_executor.integration.as_mut().unwrap();
        integration.self_test_executor.as_mut().unwrap().pid = integration.active_runtime.pid;
        assert_eq!(
            validate_pass_evidence(&confused_executor).unwrap_err().code,
            "self_test_executor_evidence_invalid"
        );

        let mut missing_credential_reference = result.clone();
        missing_credential_reference
            .transport
            .as_mut()
            .unwrap()
            .credential_reference_present = false;
        assert_eq!(
            validate_pass_evidence(&missing_credential_reference)
                .unwrap_err()
                .code,
            "managed_transport_evidence_invalid"
        );

        let mut wrong_cleanup_root = result.clone();
        wrong_cleanup_root.cleanup.as_mut().unwrap().relative_root = "jobs/wrong".to_owned();
        assert_eq!(
            validate_pass_evidence(&wrong_cleanup_root)
                .unwrap_err()
                .code,
            "cleanup_evidence_invalid"
        );

        let mut regressed_final_fleet =
            execute_full_run(&FakeBackend::new(), &PassingPlugin, Duration::from_secs(2));
        regressed_final_fleet
            .final_fleet
            .as_mut()
            .unwrap()
            .fleet_revision = 0;
        assert_eq!(
            validate_pass_evidence(&regressed_final_fleet)
                .unwrap_err()
                .code,
            "final_fleet_evidence_invalid"
        );
    }

    #[test]
    fn active_runtime_and_isolated_executor_are_distinct_execution_subjects() {
        let backend = FakeBackend::new();
        let passed = execute_full_run(&backend, &PassingPlugin, Duration::from_secs(2));
        assert_eq!(passed.state, FullRunState::Passed);
        let integration = passed.integration.unwrap();
        assert_ne!(
            integration.active_runtime.pid,
            integration.self_test_executor.unwrap().pid
        );

        let confused = FakeBackend::new();
        confused.self_test_executor_pid.store(1, Ordering::SeqCst);
        let failed = execute_full_run(&confused, &PassingPlugin, Duration::from_secs(2));
        assert_eq!(failed.state, FullRunState::Failed);
        assert_eq!(
            failed.failure.as_ref().map(|failure| failure.code),
            Some("self_test_executor_identity_invalid")
        );
        assert_eq!(confused.cancellations.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn non_https_managed_transport_never_reports_pass() {
        let mut backend = FakeBackend::new();
        backend.node.transport = NodeTransport::Managed {
            endpoint: "http://fixture.invalid".to_owned(),
            credential_ref: CredentialRef::new("fixture-ref"),
        };
        let result = execute_full_run(&backend, &PassingPlugin, Duration::from_secs(2));
        assert_eq!(result.state, FullRunState::Failed);
        assert_eq!(
            result.failure.as_ref().map(|failure| failure.code),
            Some("managed_transport_security_invalid")
        );
        assert!(result.transport.is_none());
        assert!(result.cleanup.is_none());
    }

    #[test]
    fn every_required_mcp_pipeline_tool_is_a_fail_closed_gate() {
        let cases = [
            (McpPipelineStage::Info, 1_usize),
            (McpPipelineStage::Pack, 2),
            (McpPipelineStage::Upload, 3),
            (McpPipelineStage::PlanSubmit, 4),
            (McpPipelineStage::Job, 5),
        ];
        for (stage, expected_calls) in cases {
            let backend = FakeBackend::new();
            *backend.mcp_failure_stage.lock().unwrap() = Some(stage);
            let result = execute_full_run(&backend, &PassingPlugin, Duration::from_secs(2));
            assert_eq!(result.state, FullRunState::Failed, "stage {stage:?}");
            assert_eq!(
                result.failure.as_ref().map(|failure| failure.code),
                Some("plugin_mcp_pipeline_failed"),
                "stage {stage:?}"
            );
            assert_eq!(
                backend.mcp_trace.lock().unwrap().len(),
                expected_calls,
                "stage {stage:?}"
            );
            assert_ne!(
                result.layer_mut_for_test(LAYER_CLEANUP).state,
                LayerState::Passed,
                "a broken MCP stage may never inherit a successful cleanup gate"
            );
        }
    }

    #[test]
    fn missing_snapshot_stdout_proof_never_reports_pass() {
        let backend = FakeBackend::new();
        backend.omit_snapshot_log.store(true, Ordering::SeqCst);
        let result = execute_full_run(&backend, &PassingPlugin, Duration::from_secs(2));
        assert_eq!(result.state, FullRunState::Failed);
        assert_eq!(
            result.failure.as_ref().map(|failure| failure.code),
            Some("remote_log_marker_missing")
        );
    }

    #[test]
    fn powershell_utf16le_proof_is_digest_verified_end_to_end() {
        let backend = FakeBackend::new();
        let mut utf16 = vec![0xff, 0xfe];
        for unit in "CYC_FULL_RUN_OK\r\n".encode_utf16() {
            utf16.extend_from_slice(&unit.to_le_bytes());
        }
        *backend.artifact_bytes.lock().unwrap() = utf16;
        let result = execute_full_run(&backend, &PassingPlugin, Duration::from_secs(2));
        assert_eq!(result.state, FullRunState::Passed);
    }

    #[test]
    fn corrupt_download_never_reports_pass() {
        let backend = FakeBackend::new();
        backend.corrupt_artifact.store(true, Ordering::SeqCst);
        let result = execute_full_run(&backend, &PassingPlugin, Duration::from_secs(2));
        assert_eq!(result.state, FullRunState::Failed);
        assert_eq!(
            result.failure.as_ref().map(|failure| failure.code),
            Some("proof_artifact_digest_mismatch")
        );
        assert_eq!(
            result.layer_mut_for_test(LAYER_ARTIFACT).state,
            LayerState::Failed
        );
    }

    #[test]
    fn runtime_change_after_remote_success_never_reports_pass() {
        let backend = FakeBackend::new();
        let result = execute_full_run(&backend, &DisconnectingPlugin, Duration::from_secs(2));
        assert_eq!(result.state, FullRunState::Failed);
        assert_eq!(
            result.failure.as_ref().map(|failure| failure.code),
            Some("plugin_runtime_changed")
        );
        assert_eq!(
            result.layer_mut_for_test(LAYER_PLUGIN).state,
            LayerState::Failed
        );
        assert_eq!(
            result.layer_mut_for_test(LAYER_CLEANUP).state,
            LayerState::Passed,
            "a later plugin failure must not erase an already verified cleanup receipt"
        );
    }

    #[test]
    fn cleanup_pass_requires_exact_deleted_root_and_terminal_ack() {
        let job_id = Uuid::new_v4();
        let run_id = Uuid::new_v4();
        let version = 7;
        let receipt = valid_cleanup_status(job_id, run_id, version);
        assert!(matches!(
            validate_success_cleanup(&receipt, job_id, run_id, version),
            Ok(ValidatedCleanup::Removed(_))
        ));

        let mut wrong_root = receipt.clone();
        wrong_root.relative_root = Some("jobs/../wrong".to_owned());
        assert!(validate_success_cleanup(&wrong_root, job_id, run_id, version).is_err());

        let mut deletion_not_proven = receipt.clone();
        deletion_not_proven.job_root_deleted = false;
        assert!(validate_success_cleanup(&deletion_not_proven, job_id, run_id, version).is_err());

        let mut wrong_ack = receipt.clone();
        wrong_ack
            .terminal_ack
            .as_mut()
            .expect("terminal ack")
            .final_state = JobState::Failed;
        assert!(validate_success_cleanup(&wrong_ack, job_id, run_id, version).is_err());

        let mut missing_received_at = receipt.clone();
        missing_received_at.received_at = None;
        assert!(validate_success_cleanup(&missing_received_at, job_id, run_id, version).is_err());

        let mut deadline_recovered = receipt.clone();
        let deadline = deadline_recovered
            .terminal_ack
            .as_ref()
            .expect("terminal ack")
            .acknowledged_at
            + chrono::Duration::seconds(30);
        deadline_recovered.status = CleanupStatusPhaseV1::Pending;
        deadline_recovered.job_root_deleted = false;
        deadline_recovered.observed_at = None;
        deadline_recovered.received_at = None;
        deadline_recovered.cleanup_deadline_at = Some(deadline);
        deadline_recovered.reservation_released_at = Some(deadline);
        deadline_recovered.release_reason =
            Some(CleanupReservationReleaseReasonV1::DeadlineRecovery);
        deadline_recovered.cleanup_failure = Some(cyc_protocol::CleanupFailureV1 {
            code: CleanupFailureCodeV1::RemovedReceiptDeadlineExceeded,
            observed_at: deadline,
        });
        assert!(matches!(
            validate_success_cleanup(&deadline_recovered, job_id, run_id, version),
            Ok(ValidatedCleanup::Pending)
        ));

        let mut not_created = receipt;
        not_created.status = CleanupStatusPhaseV1::NotCreated;
        not_created.job_root_deleted = false;
        assert!(validate_success_cleanup(&not_created, job_id, run_id, version).is_err());
    }

    #[test]
    fn timeout_requests_best_effort_cancel_with_latest_version() {
        let backend = FakeBackend::new();
        backend.remain_queued.store(true, Ordering::SeqCst);
        let result = execute_full_run(&backend, &PassingPlugin, Duration::ZERO);
        assert_eq!(result.state, FullRunState::Failed);
        assert_eq!(
            result.failure.as_ref().map(|failure| failure.code),
            Some("remote_execution_timeout")
        );
        assert_eq!(backend.cancellations.load(Ordering::SeqCst), 1);
        assert_eq!(
            result.layer_mut_for_test(LAYER_CLEANUP).state,
            LayerState::Failed
        );
    }

    #[test]
    fn provisioning_smoke_timeout_reconciles_the_same_job_on_retry() {
        let backend = FakeBackend::new();
        backend.remain_queued.store(true, Ordering::SeqCst);
        backend
            .lose_next_submit_response
            .store(true, Ordering::SeqCst);
        let record_id = Uuid::new_v4();
        let operation_id = cyc_provision::canonical_smoke_operation_id(record_id, 3);
        let expected_job_id = cyc_provision::canonical_smoke_job_id(record_id, 3);

        let binding = prepare_node_smoke(&backend, backend.node.id, &operation_id, expected_job_id)
            .expect("a lost submit response is reconciled through exact GET");
        assert_eq!(binding.plan.job_id, expected_job_id);
        assert_eq!(binding.run_id, backend.run_id);
        let first = execute_bound_node_smoke(&backend, &binding, Duration::ZERO);
        assert_eq!(
            first.unwrap_err().code,
            "SMOKE_EXECUTION_TIMEOUT",
            "the first bounded drive stops without destroying the durable job"
        );
        assert_eq!(backend.cancellations.load(Ordering::SeqCst), 0);
        assert_eq!(backend.submissions.load(Ordering::SeqCst), 1);

        assert_eq!(
            backend
                .submitted_job
                .lock()
                .unwrap()
                .as_ref()
                .map(|job| job.id),
            Some(expected_job_id)
        );

        let replayed =
            prepare_node_smoke(&backend, backend.node.id, &operation_id, expected_job_id)
                .expect("prepare retry reconciles the exact existing binding");
        assert_eq!(replayed, binding);

        backend.remain_queued.store(false, Ordering::SeqCst);
        let completed_at = execute_bound_node_smoke(&backend, &binding, Duration::from_secs(2))
            .expect("retry reconciles the original job through cleanup");

        assert!(completed_at <= Utc::now() + chrono::Duration::seconds(1));
        assert_eq!(backend.cancellations.load(Ordering::SeqCst), 0);
        assert_eq!(backend.submissions.load(Ordering::SeqCst), 1);
    }

    impl FullRunCheckResult {
        fn layer_mut_for_test(&self, id: &str) -> &FullRunLayer {
            self.layers.iter().find(|layer| layer.id == id).unwrap()
        }
    }
}
