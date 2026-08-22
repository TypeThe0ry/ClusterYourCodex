//! Managed-pull worker wire contract.
//!
//! Authentication is deliberately out-of-band. Pairing codes and long-lived
//! worker credentials are carried in authenticated HTTP headers and must never
//! be placed in these serializable or `Debug`-printable DTOs. The controller
//! resolves the authenticated credential to a node before accepting a payload.

use std::collections::BTreeSet;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

use crate::{
    canonical_job_digest, validate_portable_relative_path, Architecture, Capability, JobSpec,
    JobState, NodeLoad, NodeResources, OperatingSystem, PortablePathError, Run, Shell,
    PROTOCOL_VERSION,
};

/// Version identifier for the managed worker HTTP contract.
pub const WORKER_API_VERSION: &str = "cyc.dev/worker/v1";

/// HTTP authentication and metadata names shared by controller and worker.
/// Values carried by these headers remain out-of-band and are never embedded
/// in serializable DTOs.
pub const PAIR_AUTH_SCHEME: &str = "Pairing";
pub const WORKER_AUTH_SCHEME: &str = "Bearer";
pub const WORKER_CREDENTIAL_HEADER: &str = "x-cyc-worker-credential";
pub const RUN_CREDENTIAL_HEADER: &str = "x-cyc-run-credential";
pub const LEASE_ID_HEADER: &str = "x-cyc-lease-id";
pub const LOG_STREAM_HEADER: &str = "x-cyc-stream";
pub const LOG_OFFSET_HEADER: &str = "x-cyc-offset";
pub const SHA256_HEADER: &str = "x-cyc-sha256";
pub const ARTIFACT_NAME_HEADER: &str = "x-cyc-artifact-name";

// Descriptive aliases retained for consumers that name custom headers by the
// wire token rather than the field purpose.
pub const X_CYC_WORKER_CREDENTIAL: &str = WORKER_CREDENTIAL_HEADER;
pub const X_CYC_RUN_CREDENTIAL: &str = RUN_CREDENTIAL_HEADER;
pub const X_CYC_LEASE_ID: &str = LEASE_ID_HEADER;
pub const X_CYC_STREAM: &str = LOG_STREAM_HEADER;
pub const X_CYC_OFFSET: &str = LOG_OFFSET_HEADER;
pub const X_CYC_SHA256: &str = SHA256_HEADER;
pub const X_CYC_ARTIFACT_NAME: &str = ARTIFACT_NAME_HEADER;

/// A fresh, typed capability report produced by the worker itself.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ProbeReport {
    pub protocol_version: u32,
    pub agent_version: String,
    pub observed_at: DateTime<Utc>,
    pub hostname: String,
    pub os: OperatingSystem,
    pub arch: Architecture,
    #[serde(default)]
    pub capabilities: BTreeSet<Capability>,
    pub resources: NodeResources,
    pub load: NodeLoad,
}

impl ProbeReport {
    pub fn validate(&self) -> Result<(), WorkerValidationError> {
        if self.protocol_version != PROTOCOL_VERSION {
            return Err(WorkerValidationError::UnsupportedProtocolVersion(
                self.protocol_version,
            ));
        }
        if self.agent_version.trim().is_empty() {
            return Err(WorkerValidationError::EmptyField("agentVersion"));
        }
        if self.hostname.trim().is_empty() {
            return Err(WorkerValidationError::EmptyField("hostname"));
        }
        if self
            .capabilities
            .iter()
            .any(|capability| !capability.is_valid())
        {
            return Err(WorkerValidationError::InvalidResource(
                "capability names must not be empty",
            ));
        }
        if self.resources.logical_cpu_cores == 0
            || self.resources.available_cpu_cores > self.resources.logical_cpu_cores
        {
            return Err(WorkerValidationError::InvalidResource(
                "available CPU cores must be no greater than a non-zero logical core count",
            ));
        }
        if self.resources.memory_mib == 0
            || self.resources.available_memory_mib > self.resources.memory_mib
        {
            return Err(WorkerValidationError::InvalidResource(
                "available memory must be no greater than non-zero total memory",
            ));
        }
        if self.resources.disk_mib == 0
            || self.resources.available_disk_mib > self.resources.disk_mib
        {
            return Err(WorkerValidationError::InvalidResource(
                "available disk must be no greater than non-zero total disk",
            ));
        }
        if self.load.cpu_percent > 100 {
            return Err(WorkerValidationError::InvalidResource(
                "cpuPercent must be in the inclusive range 0..=100",
            ));
        }
        if self
            .resources
            .gpus
            .iter()
            .any(|gpu| gpu.available_vram_mib > gpu.total_vram_mib)
        {
            return Err(WorkerValidationError::InvalidResource(
                "available GPU VRAM must not exceed total VRAM",
            ));
        }
        Ok(())
    }
}

/// Pair a previously untrusted worker. The one-time pair code is an HTTP
/// header and is intentionally absent here.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PairRequest {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub display_name: Option<String>,
    pub probe: ProbeReport,
}

impl PairRequest {
    pub fn validate(&self) -> Result<(), WorkerValidationError> {
        if self.display_name.as_ref().is_some_and(|name| {
            name.trim().is_empty()
                || name.chars().count() > 128
                || name.chars().any(char::is_control)
        }) {
            return Err(WorkerValidationError::InvalidDisplayName);
        }
        self.probe.validate()
    }
}

/// Non-secret pairing result. The newly issued worker credential is returned
/// only in a protected response header and is not part of this DTO.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PairResponse {
    pub api_version: String,
    pub controller_id: Uuid,
    pub node_id: Uuid,
    pub paired_at: DateTime<Utc>,
    pub heartbeat_interval_seconds: u32,
    pub lease_seconds: u32,
}

impl PairResponse {
    pub fn validate(&self) -> Result<(), WorkerValidationError> {
        if self.api_version != WORKER_API_VERSION {
            return Err(WorkerValidationError::UnsupportedWorkerApiVersion(
                self.api_version.clone(),
            ));
        }
        if self.heartbeat_interval_seconds == 0 || self.lease_seconds == 0 {
            return Err(WorkerValidationError::InvalidLimits(
                "heartbeat and lease intervals must be greater than zero",
            ));
        }
        if self.heartbeat_interval_seconds >= self.lease_seconds {
            return Err(WorkerValidationError::InvalidLimits(
                "heartbeat interval must be shorter than the lease interval",
            ));
        }
        Ok(())
    }
}

/// A worker asks for at most one assignment. Authentication determines the
/// node identity and the payload refreshes capacity. `activeRunIds` is reserved
/// for later split-brain reconciliation; the one-slot preview reports an empty
/// list while it is polling for work.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ClaimRequest {
    pub probe: ProbeReport,
    #[serde(default)]
    pub active_run_ids: Vec<Uuid>,
}

impl ClaimRequest {
    pub fn validate(&self) -> Result<(), WorkerValidationError> {
        self.probe.validate()?;
        let mut unique = BTreeSet::new();
        if self
            .active_run_ids
            .iter()
            .any(|run_id| !unique.insert(run_id))
        {
            return Err(WorkerValidationError::DuplicateActiveRun);
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ClaimResponse {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub assignment: Option<ClaimAssignment>,
    pub retry_after_seconds: u32,
}

impl ClaimResponse {
    pub fn validate(&self) -> Result<(), WorkerValidationError> {
        if self.retry_after_seconds == 0 || self.retry_after_seconds > 3_600 {
            return Err(WorkerValidationError::InvalidRetryInterval);
        }
        if let Some(assignment) = &self.assignment {
            assignment.validate()?;
        }
        Ok(())
    }
}

/// A lease-bound immutable assignment. `jobDigest` binds the canonical
/// `JobSpec` to the run and prevents plan/spec substitution.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ClaimAssignment {
    pub job_id: Uuid,
    pub run_id: Uuid,
    pub job_digest: String,
    pub lease_id: Uuid,
    pub lease_until: DateTime<Utc>,
    pub state_version: u64,
    pub job_spec: JobSpec,
    pub workspace: WorkspaceAssignment,
    pub limits: ExecutionLimits,
}

impl ClaimAssignment {
    pub fn validate(&self) -> Result<(), WorkerValidationError> {
        if self.job_spec.id != self.job_id {
            return Err(WorkerValidationError::JobIdMismatch);
        }
        validate_lower_hex(&self.job_digest, 64)
            .map_err(|_| WorkerValidationError::InvalidJobDigest)?;
        self.job_spec
            .validate()
            .map_err(|error| WorkerValidationError::InvalidJobSpec(error.to_string()))?;
        let actual = canonical_job_digest(&self.job_spec)
            .map_err(|error| WorkerValidationError::InvalidJobSpec(error.to_string()))?;
        if actual != self.job_digest {
            return Err(WorkerValidationError::JobDigestMismatch);
        }
        self.workspace.validate()?;
        self.limits.validate()?;
        Ok(())
    }
}

/// Every path is relative to a worker-configured root. The controller never
/// sends an absolute worker filesystem path.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkspaceAssignment {
    pub relative_root: String,
    pub source_directory: String,
    pub logs_directory: String,
    pub artifacts_directory: String,
}

impl WorkspaceAssignment {
    pub fn validate(&self) -> Result<(), WorkerValidationError> {
        for (field, value) in [
            ("relativeRoot", self.relative_root.as_str()),
            ("sourceDirectory", self.source_directory.as_str()),
            ("logsDirectory", self.logs_directory.as_str()),
            ("artifactsDirectory", self.artifacts_directory.as_str()),
        ] {
            validate_portable_relative_path(value)
                .map_err(|source| WorkerValidationError::InvalidWorkspacePath { field, source })?;
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ExecutionLimits {
    pub job_timeout_seconds: u64,
    pub max_log_bytes: u64,
    pub max_artifact_bytes: u64,
    pub max_artifact_count: u32,
}

impl Default for ExecutionLimits {
    fn default() -> Self {
        Self {
            job_timeout_seconds: 86_400,
            max_log_bytes: 16 * 1024 * 1024,
            max_artifact_bytes: 2 * 1024 * 1024 * 1024,
            max_artifact_count: 1_000,
        }
    }
}

impl ExecutionLimits {
    pub fn validate(&self) -> Result<(), WorkerValidationError> {
        if self.job_timeout_seconds == 0
            || self.job_timeout_seconds > 86_400
            || self.max_log_bytes == 0
            || self.max_artifact_bytes == 0
            || self.max_artifact_count == 0
        {
            return Err(WorkerValidationError::InvalidLimits(
                "execution limits must be non-zero and jobTimeoutSeconds must not exceed 86400",
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct HeartbeatRequest {
    pub run_id: Uuid,
    pub lease_id: Uuid,
    pub expected_version: u64,
    pub state: JobState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub probe: Option<ProbeReport>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_log_sequence: Option<u64>,
}

impl HeartbeatRequest {
    pub fn validate(&self) -> Result<(), WorkerValidationError> {
        if self.state.is_terminal() {
            return Err(WorkerValidationError::TerminalHeartbeat);
        }
        if let Some(probe) = &self.probe {
            probe.validate()?;
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct HeartbeatResponse {
    pub cancel_requested: bool,
    pub current_version: u64,
    pub lease_until: DateTime<Utc>,
}

/// Evidence fields map directly to the existing controller [`Run`] without
/// changing its established wire representation.
#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RunEvidence {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub started_at: Option<DateTime<Utc>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub finished_at: Option<DateTime<Utc>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default)]
    pub artifact_ids: Vec<Uuid>,
}

impl RunEvidence {
    pub fn from_run(run: &Run) -> Self {
        Self {
            started_at: run.started_at,
            finished_at: run.finished_at,
            exit_code: run.exit_code,
            error: run.error.clone(),
            artifact_ids: run.artifact_ids.clone(),
        }
    }

    pub fn apply_to_run(&self, run: &mut Run) {
        run.started_at = self.started_at;
        run.finished_at = self.finished_at;
        run.exit_code = self.exit_code;
        run.error.clone_from(&self.error);
        run.artifact_ids.clone_from(&self.artifact_ids);
    }

    pub fn validate_for(&self, state: JobState) -> Result<(), WorkerValidationError> {
        let artifact_ids = self.artifact_ids.iter().copied().collect::<BTreeSet<_>>();
        if artifact_ids.len() != self.artifact_ids.len() {
            return Err(WorkerValidationError::DuplicateArtifactId);
        }
        if self
            .started_at
            .as_ref()
            .zip(self.finished_at.as_ref())
            .is_some_and(|(started, finished)| finished < started)
        {
            return Err(WorkerValidationError::InvalidRunEvidence(
                "finishedAt must not be earlier than startedAt",
            ));
        }
        match state {
            JobState::Succeeded => {
                if self.started_at.is_none()
                    || self.finished_at.is_none()
                    || self.exit_code != Some(0)
                    || self.error.as_ref().is_some_and(|error| !error.is_empty())
                {
                    return Err(WorkerValidationError::InvalidRunEvidence(
                        "succeeded requires startedAt, finishedAt, exitCode 0, and no error",
                    ));
                }
            }
            JobState::Failed => {
                let has_failure = self.exit_code.is_some_and(|code| code != 0)
                    || self
                        .error
                        .as_ref()
                        .is_some_and(|error| !error.trim().is_empty());
                if self.finished_at.is_none() || !has_failure {
                    return Err(WorkerValidationError::InvalidRunEvidence(
                        "failed requires finishedAt and a non-zero exitCode or non-empty error",
                    ));
                }
            }
            JobState::Cancelled => {
                if self.finished_at.is_none() {
                    return Err(WorkerValidationError::InvalidRunEvidence(
                        "cancelled requires finishedAt",
                    ));
                }
            }
            JobState::Running | JobState::Verifying => {
                if self.started_at.is_none() || self.finished_at.is_some() {
                    return Err(WorkerValidationError::InvalidRunEvidence(
                        "active states require startedAt and no finishedAt",
                    ));
                }
            }
            JobState::Queued | JobState::Preparing => {
                if self.finished_at.is_some() {
                    return Err(WorkerValidationError::InvalidRunEvidence(
                        "queued/preparing states must not contain finishedAt",
                    ));
                }
            }
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StateUpdate {
    pub run_id: Uuid,
    pub lease_id: Uuid,
    pub expected_version: u64,
    pub next_state: JobState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub evidence: Option<RunEvidence>,
}

impl StateUpdate {
    pub fn validate(&self) -> Result<(), WorkerValidationError> {
        if self.next_state.is_terminal() && self.evidence.is_none() {
            return Err(WorkerValidationError::MissingTerminalEvidence);
        }
        if let Some(evidence) = &self.evidence {
            evidence.validate_for(self.next_state)?;
        }
        Ok(())
    }
}

/// CAS result shared by state-transition and completion endpoints.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StateUpdateResponse {
    pub run: Run,
    pub state_version: u64,
    pub cancel_requested: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LogStream {
    Stdout,
    Stderr,
    System,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LogRecord {
    pub sequence: u64,
    pub recorded_at: DateTime<Utc>,
    pub stream: LogStream,
    pub message: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LogBatch {
    pub run_id: Uuid,
    pub lease_id: Uuid,
    pub records: Vec<LogRecord>,
}

impl LogBatch {
    pub fn validate(&self) -> Result<(), WorkerValidationError> {
        if self.records.is_empty() {
            return Err(WorkerValidationError::EmptyLogBatch);
        }
        for window in self.records.windows(2) {
            if window[1].sequence != window[0].sequence.saturating_add(1) {
                return Err(WorkerValidationError::NonContiguousLogSequence);
            }
        }
        Ok(())
    }

    pub fn metadata(&self, truncated: bool) -> LogMetadata {
        LogMetadata {
            first_sequence: self
                .records
                .first()
                .map(|record| record.sequence)
                .unwrap_or(0),
            last_sequence: self
                .records
                .last()
                .map(|record| record.sequence)
                .unwrap_or(0),
            record_count: self.records.len() as u64,
            byte_count: self
                .records
                .iter()
                .map(|record| record.message.len() as u64)
                .sum(),
            truncated,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LogMetadata {
    pub first_sequence: u64,
    pub last_sequence: u64,
    pub record_count: u64,
    pub byte_count: u64,
    #[serde(default)]
    pub truncated: bool,
}

impl LogMetadata {
    pub fn validate(&self) -> Result<(), WorkerValidationError> {
        if self.record_count == 0 {
            if self.first_sequence != 0 || self.last_sequence != 0 || self.byte_count != 0 {
                return Err(WorkerValidationError::InvalidLogMetadata);
            }
        } else if self.last_sequence < self.first_sequence
            || self
                .last_sequence
                .saturating_sub(self.first_sequence)
                .saturating_add(1)
                != self.record_count
        {
            return Err(WorkerValidationError::InvalidLogMetadata);
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ArtifactMetadata {
    pub id: Uuid,
    pub run_id: Uuid,
    pub relative_path: String,
    pub size_bytes: u64,
    pub sha256: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub media_type: Option<String>,
    pub created_at: DateTime<Utc>,
}

/// Source identity actually observed by the worker. Requested values remain
/// present even when checkout fails; successful runs also carry resolved/tree
/// object IDs so the controller can bind evidence to the immutable JobSpec.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ExecutionSourceEvidence {
    pub kind: String,
    pub repository: String,
    pub requested_revision: String,
    pub resolved_revision: String,
    pub tree: String,
    pub git_version: String,
}

impl ExecutionSourceEvidence {
    pub fn validate(&self) -> Result<(), WorkerValidationError> {
        if self.kind.trim().is_empty()
            || self.repository.trim().is_empty()
            || self.git_version.trim().is_empty()
            || self
                .kind
                .chars()
                .chain(self.repository.chars())
                .any(char::is_control)
            || self.git_version.chars().any(char::is_control)
            || self.git_version.len() > 512
        {
            return Err(WorkerValidationError::InvalidExecutionEvidence(
                "source identity contains an empty, control, or oversized field",
            ));
        }
        match self.kind.as_str() {
            "git" => {
                if !valid_object_id(&self.requested_revision)
                    || (!self.resolved_revision.is_empty()
                        && !valid_object_id(&self.resolved_revision))
                    || (!self.tree.is_empty() && !valid_object_id(&self.tree))
                {
                    return Err(WorkerValidationError::InvalidExecutionEvidence(
                        "Git revisions and tree must be complete lowercase object IDs",
                    ));
                }
            }
            "snapshot" => {
                if self.repository != "snapshot"
                    || self.git_version != "not-applicable"
                    || !self.resolved_revision.is_empty()
                    || !self.tree.is_empty()
                    || self
                        .requested_revision
                        .strip_prefix("sha256:")
                        .is_none_or(|digest| validate_lower_hex(digest, 64).is_err())
                {
                    return Err(WorkerValidationError::InvalidExecutionEvidence(
                        "snapshot source identity is invalid",
                    ));
                }
            }
            _ => {
                return Err(WorkerValidationError::InvalidExecutionEvidence(
                    "source kind is unsupported",
                ));
            }
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TerminationReason {
    Exited,
    TimedOut,
    CancelRequested,
    LeaseLost,
    TransportFailure,
    SourcePreparationFailed,
    ExecutionFailed,
    ArtifactVerificationFailed,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StepExecutionEvidence {
    pub index: u32,
    pub name: String,
    pub shell: Shell,
    pub started_at: DateTime<Utc>,
    pub finished_at: DateTime<Utc>,
    pub exit_code: Option<i32>,
    pub termination: TerminationReason,
}

impl StepExecutionEvidence {
    pub fn validate(&self) -> Result<(), WorkerValidationError> {
        if self.name.trim().is_empty() || self.name.chars().any(char::is_control) {
            return Err(WorkerValidationError::InvalidExecutionEvidence(
                "step name is empty or contains a control character",
            ));
        }
        if self.finished_at < self.started_at {
            return Err(WorkerValidationError::InvalidExecutionEvidence(
                "step finishedAt precedes startedAt",
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StreamEvidence {
    pub byte_count: u64,
    pub sha256: String,
    #[serde(default)]
    pub truncated: bool,
    pub chunk_count: u64,
}

impl StreamEvidence {
    pub fn validate(&self) -> Result<(), WorkerValidationError> {
        validate_lower_hex(&self.sha256, 64)
            .map_err(|_| WorkerValidationError::InvalidStreamEvidence("invalid sha256"))?;
        if (self.byte_count == 0) != (self.chunk_count == 0) {
            return Err(WorkerValidationError::InvalidStreamEvidence(
                "byteCount and chunkCount zero state is inconsistent",
            ));
        }
        if self.byte_count == 0
            && self.sha256 != "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        {
            return Err(WorkerValidationError::InvalidStreamEvidence(
                "empty stream must use the SHA-256 of empty bytes",
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RunStreamsEvidence {
    pub stdout: StreamEvidence,
    pub stderr: StreamEvidence,
}

impl RunStreamsEvidence {
    pub fn validate(&self) -> Result<(), WorkerValidationError> {
        self.stdout.validate()?;
        self.stderr.validate()?;
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TerminationEvidence {
    pub reason: TerminationReason,
    pub process_tree_terminated: bool,
    pub forced_kill: bool,
    pub root_exit_code: Option<i32>,
    pub signal: Option<i32>,
    pub observed_at: DateTime<Utc>,
}

impl TerminationEvidence {
    pub fn validate(&self) -> Result<(), WorkerValidationError> {
        if self.forced_kill && !self.process_tree_terminated {
            return Err(WorkerValidationError::InvalidExecutionEvidence(
                "forcedKill requires processTreeTerminated",
            ));
        }
        if self.signal.is_some_and(|signal| signal <= 0) {
            return Err(WorkerValidationError::InvalidExecutionEvidence(
                "signal must be positive when present",
            ));
        }
        if matches!(
            self.reason,
            TerminationReason::TimedOut
                | TerminationReason::CancelRequested
                | TerminationReason::LeaseLost
        ) && !self.process_tree_terminated
        {
            return Err(WorkerValidationError::InvalidExecutionEvidence(
                "cancel and timeout termination must cover the process tree",
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ExecutionEvidence {
    pub source: ExecutionSourceEvidence,
    #[serde(default)]
    pub steps: Vec<StepExecutionEvidence>,
    pub streams: RunStreamsEvidence,
    pub termination: TerminationEvidence,
}

impl ExecutionEvidence {
    pub fn validate(&self) -> Result<(), WorkerValidationError> {
        self.source.validate()?;
        self.streams.validate()?;
        self.termination.validate()?;
        for (index, step) in self.steps.iter().enumerate() {
            step.validate()?;
            if usize::try_from(step.index).ok() != Some(index) {
                return Err(WorkerValidationError::InvalidExecutionEvidence(
                    "step indices must start at zero and be contiguous",
                ));
            }
        }
        Ok(())
    }
}

impl ArtifactMetadata {
    pub fn validate(&self) -> Result<(), WorkerValidationError> {
        validate_portable_relative_path(&self.relative_path)
            .map_err(|source| WorkerValidationError::InvalidArtifactPath { source })?;
        if self
            .relative_path
            .split('/')
            .any(|segment| segment == ".git")
        {
            return Err(WorkerValidationError::GitMetadataArtifact);
        }
        validate_lower_hex(&self.sha256, 64)
            .map_err(|_| WorkerValidationError::InvalidArtifactDigest)?;
        if self.media_type.as_ref().is_some_and(|media_type| {
            media_type.trim().is_empty() || media_type.chars().any(char::is_control)
        }) {
            return Err(WorkerValidationError::InvalidMediaType);
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RunCompletion {
    pub run_id: Uuid,
    pub lease_id: Uuid,
    pub expected_version: u64,
    pub final_state: JobState,
    pub evidence: RunEvidence,
    pub execution: ExecutionEvidence,
    #[serde(default)]
    pub artifacts: Vec<ArtifactMetadata>,
}

impl RunCompletion {
    pub fn validate(&self) -> Result<(), WorkerValidationError> {
        if !self.final_state.is_terminal() {
            return Err(WorkerValidationError::NonTerminalCompletion);
        }
        self.evidence.validate_for(self.final_state)?;
        self.execution.validate()?;
        if !self.execution.termination.process_tree_terminated {
            return Err(WorkerValidationError::InvalidExecutionEvidence(
                "terminal completion must prove process-tree cleanup",
            ));
        }
        if self.execution.termination.root_exit_code != self.evidence.exit_code {
            return Err(WorkerValidationError::InvalidExecutionEvidence(
                "termination rootExitCode must match run exitCode",
            ));
        }
        if self
            .evidence
            .finished_at
            .is_some_and(|finished| self.execution.termination.observed_at < finished)
        {
            return Err(WorkerValidationError::InvalidExecutionEvidence(
                "termination observedAt precedes run finishedAt",
            ));
        }
        if self.final_state == JobState::Succeeded
            && (self.execution.termination.reason != TerminationReason::Exited
                || self.execution.termination.root_exit_code != Some(0)
                || self.execution.termination.forced_kill
                || self.execution.steps.iter().any(|step| {
                    step.exit_code != Some(0) || step.termination != TerminationReason::Exited
                }))
        {
            return Err(WorkerValidationError::InvalidExecutionEvidence(
                "succeeded completion requires clean exited execution evidence",
            ));
        }
        if self
            .artifacts
            .iter()
            .any(|artifact| artifact.run_id != self.run_id)
        {
            return Err(WorkerValidationError::ArtifactRunMismatch);
        }
        for artifact in &self.artifacts {
            artifact.validate()?;
        }
        let metadata_ids = self
            .artifacts
            .iter()
            .map(|artifact| artifact.id)
            .collect::<BTreeSet<_>>();
        let evidence_ids = self
            .evidence
            .artifact_ids
            .iter()
            .copied()
            .collect::<BTreeSet<_>>();
        let metadata_paths = self
            .artifacts
            .iter()
            .map(|artifact| artifact.relative_path.as_str())
            .collect::<BTreeSet<_>>();
        if metadata_ids.len() != self.artifacts.len()
            || metadata_paths.len() != self.artifacts.len()
            || evidence_ids.len() != self.evidence.artifact_ids.len()
            || metadata_ids != evidence_ids
        {
            return Err(WorkerValidationError::ArtifactManifestMismatch);
        }
        Ok(())
    }
}

fn validate_lower_hex(value: &str, length: usize) -> Result<(), ()> {
    if value.len() == length
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        Ok(())
    } else {
        Err(())
    }
}

fn valid_object_id(value: &str) -> bool {
    matches!(value.len(), 40 | 64)
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum WorkerValidationError {
    #[error("unsupported protocolVersion {0}")]
    UnsupportedProtocolVersion(u32),
    #[error("unsupported worker apiVersion `{0}`")]
    UnsupportedWorkerApiVersion(String),
    #[error("{0} must not be empty")]
    EmptyField(&'static str),
    #[error("displayName must contain 1..=128 non-control characters")]
    InvalidDisplayName,
    #[error("invalid resource report: {0}")]
    InvalidResource(&'static str),
    #[error("activeRunIds must not contain duplicates")]
    DuplicateActiveRun,
    #[error("retryAfterSeconds must be in the inclusive range 1..=3600")]
    InvalidRetryInterval,
    #[error("assignment jobId does not match jobSpec.id")]
    JobIdMismatch,
    #[error("jobDigest must contain 64 lowercase hex characters")]
    InvalidJobDigest,
    #[error("jobDigest does not match the canonical normalized JobSpec")]
    JobDigestMismatch,
    #[error("invalid assigned JobSpec: {0}")]
    InvalidJobSpec(String),
    #[error("workspace.{field} is invalid: {source}")]
    InvalidWorkspacePath {
        field: &'static str,
        source: PortablePathError,
    },
    #[error("invalid execution limits: {0}")]
    InvalidLimits(&'static str),
    #[error("terminal runs must use RunCompletion rather than heartbeat")]
    TerminalHeartbeat,
    #[error("terminal state updates require evidence")]
    MissingTerminalEvidence,
    #[error("invalid run evidence: {0}")]
    InvalidRunEvidence(&'static str),
    #[error("artifactIds must not contain duplicates")]
    DuplicateArtifactId,
    #[error("log batch must contain at least one record")]
    EmptyLogBatch,
    #[error("log record sequences must be contiguous")]
    NonContiguousLogSequence,
    #[error("log metadata sequence range, recordCount, and byteCount are inconsistent")]
    InvalidLogMetadata,
    #[error("invalid execution evidence: {0}")]
    InvalidExecutionEvidence(&'static str),
    #[error("invalid stream evidence: {0}")]
    InvalidStreamEvidence(&'static str),
    #[error("artifact relativePath is invalid: {source}")]
    InvalidArtifactPath { source: PortablePathError },
    #[error("artifact paths must not include .git metadata")]
    GitMetadataArtifact,
    #[error("artifact sha256 must contain 64 lowercase hex characters")]
    InvalidArtifactDigest,
    #[error("artifact mediaType must not be empty or contain control characters")]
    InvalidMediaType,
    #[error("RunCompletion finalState must be terminal")]
    NonTerminalCompletion,
    #[error("artifact runId does not match completion runId")]
    ArtifactRunMismatch,
    #[error("artifact metadata IDs must be unique and cover evidence.artifactIds")]
    ArtifactManifestMismatch,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{ArtifactSpec, JobKind, JobStep, SourceSpec, DEFAULT_GIT_ARTIFACT_EXCLUDE};

    fn probe() -> ProbeReport {
        ProbeReport {
            protocol_version: PROTOCOL_VERSION,
            agent_version: "0.1.0".to_owned(),
            observed_at: Utc::now(),
            hostname: "worker-01".to_owned(),
            os: OperatingSystem::Linux,
            arch: Architecture::X86_64,
            capabilities: [Capability::new("tool.git")].into_iter().collect(),
            resources: NodeResources {
                logical_cpu_cores: 16,
                available_cpu_cores: 12,
                memory_mib: 32_768,
                available_memory_mib: 24_000,
                disk_mib: 500_000,
                available_disk_mib: 400_000,
                gpus: Vec::new(),
            },
            load: NodeLoad {
                cpu_percent: 20,
                queue_depth: 0,
                running_jobs: 0,
            },
        }
    }

    fn job() -> JobSpec {
        let mut job = JobSpec::new(
            JobKind::Build,
            SourceSpec::Git {
                repository: "https://example.invalid/repository.git".to_owned(),
                revision: "0123456789abcdef0123456789abcdef01234567".to_owned(),
            },
            vec![JobStep::new("build", "cargo build --locked")],
        );
        job.artifacts = ArtifactSpec {
            include: vec!["target/release/*".to_owned()],
            exclude: vec![DEFAULT_GIT_ARTIFACT_EXCLUDE.to_owned()],
            retention_days: Some(7),
        };
        job
    }

    fn assignment() -> ClaimAssignment {
        let job = job();
        let job_digest = canonical_job_digest(&job).expect("canonical assignment digest");
        ClaimAssignment {
            job_id: job.id,
            run_id: Uuid::new_v4(),
            job_digest,
            lease_id: Uuid::new_v4(),
            lease_until: Utc::now(),
            state_version: 0,
            job_spec: job,
            workspace: WorkspaceAssignment {
                relative_root: format!("jobs/{}", Uuid::new_v4()),
                source_directory: "repo".to_owned(),
                logs_directory: "logs".to_owned(),
                artifacts_directory: "artifacts".to_owned(),
            },
            limits: ExecutionLimits::default(),
        }
    }

    #[test]
    fn pair_request_has_no_serializable_secret_surface() {
        let request = PairRequest {
            display_name: Some("Linux builder".to_owned()),
            probe: probe(),
        };
        let json = serde_json::to_string(&request).expect("serialize pair request");
        for forbidden in ["pairCode", "credential", "password", "privateKey", "token"] {
            assert!(!json.contains(forbidden), "secret-shaped field {forbidden}");
        }
        let mut value = serde_json::to_value(&request).expect("pair value");
        value["pairCode"] = serde_json::json!("do-not-accept");
        assert!(serde_json::from_value::<PairRequest>(value).is_err());
        request.validate().expect("valid request");
    }

    #[test]
    fn typed_probe_rejects_impossible_resource_values_and_unknown_fields() {
        let mut invalid = probe();
        invalid.resources.available_cpu_cores = 17;
        assert!(matches!(
            invalid.validate(),
            Err(WorkerValidationError::InvalidResource(_))
        ));

        let mut value = serde_json::to_value(probe()).expect("probe value");
        value["resources"]["unexpected"] = serde_json::json!(1);
        assert!(serde_json::from_value::<ProbeReport>(value).is_err());
    }

    #[test]
    fn assignment_round_trips_and_binds_job_identity() {
        let original = assignment();
        original.validate().expect("valid assignment");
        let encoded = serde_json::to_string(&original).expect("serialize assignment");
        let decoded: ClaimAssignment =
            serde_json::from_str(&encoded).expect("deserialize assignment");
        assert_eq!(decoded, original);

        let mut swapped = original;
        swapped.job_id = Uuid::new_v4();
        assert_eq!(
            swapped.validate(),
            Err(WorkerValidationError::JobIdMismatch)
        );

        let mut changed_after_digest = assignment();
        changed_after_digest.job_spec.steps[0]
            .script
            .push_str(" --release");
        assert_eq!(
            changed_after_digest.validate(),
            Err(WorkerValidationError::JobDigestMismatch)
        );
    }

    #[test]
    fn claim_refreshes_probe_without_carrying_node_credentials() {
        let run_id = Uuid::new_v4();
        let request = ClaimRequest {
            probe: probe(),
            active_run_ids: vec![run_id],
        };
        request.validate().expect("valid claim request");
        let encoded = serde_json::to_string(&request).expect("claim JSON");
        assert!(!encoded.contains("credential"));

        let duplicate = ClaimRequest {
            active_run_ids: vec![run_id, run_id],
            ..request
        };
        assert_eq!(
            duplicate.validate(),
            Err(WorkerValidationError::DuplicateActiveRun)
        );

        let response = ClaimResponse {
            assignment: Some(assignment()),
            retry_after_seconds: 2,
        };
        response.validate().expect("valid claim response");
    }

    #[test]
    fn workspace_paths_are_always_portable_and_relative() {
        for invalid in [
            "/tmp/job",
            "C:/job",
            "//server/share",
            "jobs\\run",
            "jobs//run",
            "jobs/./run",
            "jobs/../run",
            "jobs/\0run",
        ] {
            let mut value = assignment();
            value.workspace.relative_root = invalid.to_owned();
            assert!(matches!(
                value.validate(),
                Err(WorkerValidationError::InvalidWorkspacePath { .. })
            ));
        }
    }

    #[test]
    fn state_update_requires_valid_terminal_evidence() {
        let update = StateUpdate {
            run_id: Uuid::new_v4(),
            lease_id: Uuid::new_v4(),
            expected_version: 2,
            next_state: JobState::Succeeded,
            evidence: None,
        };
        assert_eq!(
            update.validate(),
            Err(WorkerValidationError::MissingTerminalEvidence)
        );

        let now = Utc::now();
        let update = StateUpdate {
            evidence: Some(RunEvidence {
                started_at: Some(now),
                finished_at: Some(now),
                exit_code: Some(0),
                ..RunEvidence::default()
            }),
            ..update
        };
        update.validate().expect("terminal evidence");
    }

    #[test]
    fn heartbeat_is_lease_bound_and_cannot_publish_terminal_state() {
        let request = HeartbeatRequest {
            run_id: Uuid::new_v4(),
            lease_id: Uuid::new_v4(),
            expected_version: 1,
            state: JobState::Running,
            probe: Some(probe()),
            last_log_sequence: Some(9),
        };
        request.validate().expect("active heartbeat");

        let terminal = HeartbeatRequest {
            state: JobState::Succeeded,
            ..request
        };
        assert_eq!(
            terminal.validate(),
            Err(WorkerValidationError::TerminalHeartbeat)
        );
    }

    #[test]
    fn run_evidence_converts_without_changing_run_wire_contract() {
        let mut run = Run::queued(Uuid::new_v4());
        let now = Utc::now();
        let evidence = RunEvidence {
            started_at: Some(now),
            finished_at: Some(now),
            exit_code: Some(0),
            error: None,
            artifact_ids: vec![Uuid::new_v4()],
        };
        evidence.apply_to_run(&mut run);
        assert_eq!(RunEvidence::from_run(&run), evidence);
        let value = serde_json::to_value(run).expect("serialize legacy Run");
        assert!(value.get("stateVersion").is_none());
        assert!(value.get("evidence").is_none());
    }

    #[test]
    fn log_batch_requires_contiguous_sequences_and_reports_metadata() {
        let now = Utc::now();
        let mut batch = LogBatch {
            run_id: Uuid::new_v4(),
            lease_id: Uuid::new_v4(),
            records: vec![
                LogRecord {
                    sequence: 7,
                    recorded_at: now,
                    stream: LogStream::Stdout,
                    message: "abc".to_owned(),
                },
                LogRecord {
                    sequence: 8,
                    recorded_at: now,
                    stream: LogStream::Stderr,
                    message: "de".to_owned(),
                },
            ],
        };
        batch.validate().expect("valid log batch");
        assert_eq!(batch.metadata(false).byte_count, 5);
        batch.records[1].sequence = 9;
        assert_eq!(
            batch.validate(),
            Err(WorkerValidationError::NonContiguousLogSequence)
        );
    }

    #[test]
    fn completion_binds_artifacts_to_run_and_evidence() {
        let run_id = Uuid::new_v4();
        let artifact_id = Uuid::new_v4();
        let now = Utc::now();
        let completion = RunCompletion {
            run_id,
            lease_id: Uuid::new_v4(),
            expected_version: 4,
            final_state: JobState::Succeeded,
            evidence: RunEvidence {
                started_at: Some(now),
                finished_at: Some(now),
                exit_code: Some(0),
                error: None,
                artifact_ids: vec![artifact_id],
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
                    started_at: now,
                    finished_at: now,
                    exit_code: Some(0),
                    termination: TerminationReason::Exited,
                }],
                streams: RunStreamsEvidence {
                    stdout: StreamEvidence {
                        byte_count: 0,
                        sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
                            .to_owned(),
                        truncated: false,
                        chunk_count: 0,
                    },
                    stderr: StreamEvidence {
                        byte_count: 0,
                        sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
                            .to_owned(),
                        truncated: false,
                        chunk_count: 0,
                    },
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
            artifacts: vec![ArtifactMetadata {
                id: artifact_id,
                run_id,
                relative_path: "target/release/cyc".to_owned(),
                size_bytes: 42,
                sha256: "b".repeat(64),
                media_type: Some("application/octet-stream".to_owned()),
                created_at: now,
            }],
        };
        completion.validate().expect("valid completion");

        let mut surviving_tree = completion.clone();
        surviving_tree.execution.termination.process_tree_terminated = false;
        assert!(matches!(
            surviving_tree.validate(),
            Err(WorkerValidationError::InvalidExecutionEvidence(_))
        ));

        let mut wrong_run = completion;
        wrong_run.artifacts[0].run_id = Uuid::new_v4();
        assert_eq!(
            wrong_run.validate(),
            Err(WorkerValidationError::ArtifactRunMismatch)
        );
    }

    #[test]
    fn artifact_metadata_rejects_git_paths_and_noncanonical_hashes() {
        let mut artifact = ArtifactMetadata {
            id: Uuid::new_v4(),
            run_id: Uuid::new_v4(),
            relative_path: ".git/config".to_owned(),
            size_bytes: 1,
            sha256: "a".repeat(64),
            media_type: None,
            created_at: Utc::now(),
        };
        assert_eq!(
            artifact.validate(),
            Err(WorkerValidationError::GitMetadataArtifact)
        );
        artifact.relative_path = "target/output.bin".to_owned();
        artifact.sha256 = "A".repeat(64);
        assert_eq!(
            artifact.validate(),
            Err(WorkerValidationError::InvalidArtifactDigest)
        );
    }

    #[test]
    fn all_worker_structs_reject_unknown_fields() {
        let response = HeartbeatResponse {
            cancel_requested: false,
            current_version: 3,
            lease_until: Utc::now(),
        };
        let mut value = serde_json::to_value(response).expect("heartbeat response");
        value["credential"] = serde_json::json!("must-not-be-accepted");
        assert!(serde_json::from_value::<HeartbeatResponse>(value).is_err());

        let response = StateUpdateResponse {
            run: Run::queued(Uuid::new_v4()),
            state_version: 1,
            cancel_requested: false,
        };
        let mut value = serde_json::to_value(response).expect("state update response");
        value["credential"] = serde_json::json!("must-not-be-accepted");
        assert!(serde_json::from_value::<StateUpdateResponse>(value).is_err());
    }

    #[test]
    fn worker_schema_tracks_execution_receipt_wire() {
        let schema: serde_json::Value =
            serde_json::from_str(include_str!("../../../schemas/worker-api.schema.json"))
                .expect("worker API schema is JSON");
        let definitions = schema["$defs"].as_object().expect("schema definitions");
        for required in [
            "executionSourceEvidence",
            "stepExecutionEvidence",
            "streamEvidence",
            "runStreamsEvidence",
            "terminationEvidence",
            "executionEvidence",
        ] {
            assert!(definitions.contains_key(required), "missing {required}");
        }
        let completion = &definitions["runCompletion"];
        assert!(completion["required"]
            .as_array()
            .expect("completion required")
            .iter()
            .any(|value| value == "execution"));
        assert!(completion["properties"].get("log").is_none());
        assert_eq!(
            completion["properties"]["execution"]["$ref"],
            "#/$defs/executionEvidence"
        );
        assert_eq!(
            definitions["terminationEvidence"]["properties"]["processTreeTerminated"]["const"],
            true
        );
        assert_eq!(
            definitions["executionSourceEvidence"]["properties"]["kind"]["enum"],
            serde_json::json!(["git", "snapshot"])
        );
    }

    #[test]
    fn public_constants_remain_versioned() {
        assert_eq!(crate::API_VERSION, "cyc.dev/v1");
        assert_eq!(WORKER_API_VERSION, "cyc.dev/worker/v1");
    }
}
