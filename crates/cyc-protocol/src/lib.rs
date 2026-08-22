//! Transport-neutral domain types shared by ClusterYourCodex components.
//!
//! This crate deliberately carries opaque credential references rather than
//! credential material.  `JobSpec` is safe to pass between Codex, the MCP
//! bridge, the controller, and workers without teaching those layers how a
//! credential is stored.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

/// Current wire-level API identifier used by [`JobSpec`].
pub const API_VERSION: &str = "cyc.dev/v1";

/// Numeric protocol generation for capability negotiation outside `JobSpec`.
pub const PROTOCOL_VERSION: u32 = 1;

/// A stable, extensible capability name such as `docker`, `cuda`, or
/// `toolchain:msvc`.
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Capability(String);

impl Capability {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn is_valid(&self) -> bool {
        !self.0.trim().is_empty()
    }
}

impl From<&str> for Capability {
    fn from(value: &str) -> Self {
        Self::new(value)
    }
}

impl From<String> for Capability {
    fn from(value: String) -> Self {
        Self::new(value)
    }
}

impl fmt::Display for Capability {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

/// Opaque lookup key owned by a controller credential provider.
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(transparent)]
pub struct CredentialRef(String);

impl CredentialRef {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl From<&str> for CredentialRef {
    fn from(value: &str) -> Self {
        Self::new(value)
    }
}

impl From<String> for CredentialRef {
    fn from(value: String) -> Self {
        Self::new(value)
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OperatingSystem {
    Windows,
    Linux,
    Macos,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Architecture {
    X86_64,
    Aarch64,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum NodeTransport {
    Local,
    Managed {
        endpoint: String,
        #[serde(rename = "credentialRef")]
        credential_ref: CredentialRef,
    },
    Ssh {
        host: String,
        #[serde(default = "default_ssh_port")]
        port: u16,
        username: String,
        #[serde(rename = "credentialRef")]
        credential_ref: CredentialRef,
    },
}

const fn default_ssh_port() -> u16 {
    22
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NodeStatus {
    Online,
    Degraded,
    Draining,
    #[default]
    Offline,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum GpuVendor {
    Nvidia,
    Amd,
    Intel,
    Apple,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GpuDevice {
    pub vendor: GpuVendor,
    pub model: String,
    pub total_vram_mib: u64,
    pub available_vram_mib: u64,
    /// False while an exclusive lease is held or the device is administratively
    /// unavailable for ClusterYourCodex work.
    #[serde(default = "default_true")]
    pub allocatable: bool,
}

const fn default_true() -> bool {
    true
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NodeResources {
    pub logical_cpu_cores: u32,
    pub available_cpu_cores: u32,
    pub memory_mib: u64,
    pub available_memory_mib: u64,
    pub disk_mib: u64,
    pub available_disk_mib: u64,
    #[serde(default)]
    pub gpus: Vec<GpuDevice>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NodeLoad {
    /// Integer percentage in the inclusive range 0..=100.
    pub cpu_percent: u8,
    pub queue_depth: u32,
    pub running_jobs: u32,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Node {
    pub id: Uuid,
    pub name: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    pub transport: NodeTransport,
    pub os: OperatingSystem,
    pub arch: Architecture,
    #[serde(default)]
    pub status: NodeStatus,
    #[serde(default)]
    pub capabilities: BTreeSet<Capability>,
    #[serde(default)]
    pub resources: NodeResources,
    #[serde(default)]
    pub load: NodeLoad,
    #[serde(default)]
    pub priority: i32,
    #[serde(default)]
    pub labels: BTreeMap<String, String>,
    /// Source cache identities. See [`SourceSpec::cache_key`].
    #[serde(default)]
    pub cached_sources: BTreeSet<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_seen_at: Option<DateTime<Utc>>,
}

impl Node {
    pub fn new(
        name: impl Into<String>,
        transport: NodeTransport,
        os: OperatingSystem,
        arch: Architecture,
    ) -> Self {
        Self {
            id: Uuid::new_v4(),
            name: name.into(),
            enabled: true,
            transport,
            os,
            arch,
            status: NodeStatus::Offline,
            capabilities: BTreeSet::new(),
            resources: NodeResources::default(),
            load: NodeLoad::default(),
            priority: 0,
            labels: BTreeMap::new(),
            cached_sources: BTreeSet::new(),
            last_seen_at: Some(Utc::now()),
        }
    }

    pub fn with_capability(mut self, capability: impl Into<Capability>) -> Self {
        self.capabilities.insert(capability.into());
        self
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct JobOrigin {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub codex_session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace_id: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum JobKind {
    Shell,
    Build,
    Test,
    Lint,
    Container,
    Gpu,
    Batch,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase", deny_unknown_fields)]
pub enum SourceSpec {
    Git {
        repository: String,
        revision: String,
    },
    Snapshot {
        digest: String,
        #[serde(rename = "sizeBytes", skip_serializing_if = "Option::is_none")]
        size_bytes: Option<u64>,
    },
}

impl SourceSpec {
    /// Stable key suitable for comparing a job source with a worker cache.
    pub fn cache_key(&self) -> String {
        match self {
            Self::Git {
                repository,
                revision,
            } => format!("git:{repository}@{revision}"),
            Self::Snapshot { digest, .. } => format!("snapshot:{digest}"),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GpuRequirement {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub vendor: Option<GpuVendor>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub min_vram_mib: Option<u64>,
    #[serde(default = "default_true")]
    pub exclusive: bool,
}

impl Default for GpuRequirement {
    fn default() -> Self {
        Self {
            vendor: None,
            min_vram_mib: None,
            exclusive: true,
        }
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct JobRequirements {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub os: Option<OperatingSystem>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub arch: Option<Architecture>,
    #[serde(default)]
    pub capabilities: BTreeSet<Capability>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub min_cpu_cores: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub min_memory_mib: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub min_disk_mib: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gpu: Option<GpuRequirement>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Shell {
    Powershell,
    Bash,
    Zsh,
    Cmd,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct JobStep {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub shell: Option<Shell>,
    pub script: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub working_directory: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timeout_seconds: Option<u64>,
}

impl JobStep {
    pub fn new(name: impl Into<String>, script: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            shell: None,
            script: script.into(),
            working_directory: None,
            timeout_seconds: None,
        }
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ArtifactSpec {
    #[serde(default)]
    pub include: Vec<String>,
    #[serde(default)]
    pub exclude: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retention_days: Option<u32>,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PlacementPolicy {
    #[default]
    Balanced,
    Performance,
    Manual,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct JobSpec {
    pub api_version: String,
    pub id: Uuid,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub origin: Option<JobOrigin>,
    pub kind: JobKind,
    pub source: SourceSpec,
    #[serde(default)]
    pub requirements: JobRequirements,
    pub steps: Vec<JobStep>,
    #[serde(default)]
    pub artifacts: ArtifactSpec,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timeout_seconds: Option<u64>,
    #[serde(default)]
    pub placement_policy: PlacementPolicy,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub preferred_node_id: Option<Uuid>,
}

impl JobSpec {
    pub fn new(kind: JobKind, source: SourceSpec, steps: Vec<JobStep>) -> Self {
        Self {
            api_version: API_VERSION.to_owned(),
            id: Uuid::new_v4(),
            origin: None,
            kind,
            source,
            requirements: JobRequirements::default(),
            steps,
            artifacts: ArtifactSpec::default(),
            timeout_seconds: None,
            placement_policy: PlacementPolicy::default(),
            preferred_node_id: None,
        }
    }

    pub fn validate(&self) -> Result<(), ValidationError> {
        if self.api_version != API_VERSION {
            return Err(ValidationError::UnsupportedApiVersion(
                self.api_version.clone(),
            ));
        }
        if self.steps.is_empty() {
            return Err(ValidationError::NoSteps);
        }
        if let Some(origin) = &self.origin {
            for (field, value) in [
                ("codexSessionId", origin.codex_session_id.as_deref()),
                ("projectId", origin.project_id.as_deref()),
                ("workspaceId", origin.workspace_id.as_deref()),
            ] {
                if value.is_some_and(|value| value.chars().count() > 256) {
                    return Err(ValidationError::OriginFieldTooLong(field));
                }
            }
        }
        for (index, step) in self.steps.iter().enumerate() {
            if step.name.trim().is_empty() {
                return Err(ValidationError::EmptyStepName(index));
            }
            if step.script.trim().is_empty() {
                return Err(ValidationError::EmptyStepScript(index));
            }
            validate_timeout(step.timeout_seconds, "step timeoutSeconds")?;
        }
        validate_timeout(self.timeout_seconds, "timeoutSeconds")?;
        if self
            .requirements
            .capabilities
            .iter()
            .any(|capability| !capability.is_valid())
        {
            return Err(ValidationError::EmptyCapability);
        }
        for (field, value) in [
            (
                "minCpuCores",
                self.requirements.min_cpu_cores.map(u64::from),
            ),
            ("minMemoryMiB", self.requirements.min_memory_mib),
            ("minDiskMiB", self.requirements.min_disk_mib),
        ] {
            if value == Some(0) {
                return Err(ValidationError::ZeroRequirement(field));
            }
        }
        if self
            .requirements
            .gpu
            .as_ref()
            .and_then(|gpu| gpu.min_vram_mib)
            == Some(0)
        {
            return Err(ValidationError::ZeroRequirement("minVramMiB"));
        }
        if matches!(self.artifacts.retention_days, Some(0 | 3651..)) {
            return Err(ValidationError::InvalidRetentionDays);
        }
        match &self.source {
            SourceSpec::Git {
                repository,
                revision,
            } => {
                if repository.trim().is_empty() {
                    return Err(ValidationError::InvalidSource(
                        "git repository must not be empty",
                    ));
                }
                if revision.len() < 7 {
                    return Err(ValidationError::InvalidSource(
                        "git revision must contain at least 7 characters",
                    ));
                }
            }
            SourceSpec::Snapshot { digest, .. } => {
                let hash = digest.strip_prefix("sha256:");
                if hash.is_none_or(|value| {
                    value.len() != 64
                        || !value
                            .bytes()
                            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
                }) {
                    return Err(ValidationError::InvalidSource(
                        "snapshot digest must be sha256 followed by 64 lowercase hex digits",
                    ));
                }
            }
        }
        Ok(())
    }
}

fn validate_timeout(value: Option<u64>, field: &'static str) -> Result<(), ValidationError> {
    if matches!(value, Some(0 | 86401..)) {
        return Err(ValidationError::InvalidTimeout(field));
    }
    Ok(())
}

#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum ValidationError {
    #[error("unsupported apiVersion `{0}`")]
    UnsupportedApiVersion(String),
    #[error("steps must contain at least one item")]
    NoSteps,
    #[error("origin.{0} must contain at most 256 characters")]
    OriginFieldTooLong(&'static str),
    #[error("steps[{0}].name must not be empty")]
    EmptyStepName(usize),
    #[error("steps[{0}].script must not be empty")]
    EmptyStepScript(usize),
    #[error("{0} must be in the inclusive range 1..=86400")]
    InvalidTimeout(&'static str),
    #[error("capability names must not be empty")]
    EmptyCapability,
    #[error("{0} must be greater than zero")]
    ZeroRequirement(&'static str),
    #[error("retentionDays must be in the inclusive range 1..=3650")]
    InvalidRetentionDays,
    #[error("invalid source: {0}")]
    InvalidSource(&'static str),
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JobState {
    #[default]
    Queued,
    Preparing,
    Running,
    Verifying,
    Succeeded,
    Failed,
    Cancelled,
}

impl JobState {
    pub fn is_terminal(self) -> bool {
        matches!(self, Self::Succeeded | Self::Failed | Self::Cancelled)
    }

    pub fn can_transition_to(self, next: Self) -> bool {
        match self {
            Self::Queued => matches!(next, Self::Preparing | Self::Failed | Self::Cancelled),
            Self::Preparing => matches!(next, Self::Running | Self::Failed | Self::Cancelled),
            Self::Running => matches!(
                next,
                Self::Verifying | Self::Succeeded | Self::Failed | Self::Cancelled
            ),
            Self::Verifying => matches!(next, Self::Succeeded | Self::Failed | Self::Cancelled),
            Self::Succeeded | Self::Failed | Self::Cancelled => false,
        }
    }
}

/// Compatibility alias for consumers that name the per-attempt state rather
/// than the overall job state.
pub type RunState = JobState;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Run {
    pub id: Uuid,
    pub job_id: Uuid,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub node_id: Option<Uuid>,
    pub state: JobState,
    pub created_at: DateTime<Utc>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub started_at: Option<DateTime<Utc>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub finished_at: Option<DateTime<Utc>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub placement: Option<PlacementExplain>,
    #[serde(default)]
    pub artifact_ids: Vec<Uuid>,
}

impl Run {
    pub fn queued(job_id: Uuid) -> Self {
        Self {
            id: Uuid::new_v4(),
            job_id,
            node_id: None,
            state: JobState::Queued,
            created_at: Utc::now(),
            started_at: None,
            finished_at: None,
            exit_code: None,
            error: None,
            placement: None,
            artifact_ids: Vec::new(),
        }
    }

    pub fn transition(&mut self, next: JobState) -> Result<(), StateTransitionError> {
        if !self.state.can_transition_to(next) {
            return Err(StateTransitionError {
                from: self.state,
                to: next,
            });
        }
        let now = Utc::now();
        if next == JobState::Running && self.started_at.is_none() {
            self.started_at = Some(now);
        }
        if next.is_terminal() {
            self.finished_at = Some(now);
        }
        self.state = next;
        Ok(())
    }

    /// Validate persisted run evidence independently of state-transition code.
    ///
    /// Workers may crash, controllers may restart, and older database rows may
    /// be decoded without having passed through [`Run::transition`]. Consumers
    /// should call this method before publishing a terminal result as verified.
    pub fn validate(&self) -> Result<(), RunValidationError> {
        if self
            .started_at
            .as_ref()
            .is_some_and(|started| started < &self.created_at)
        {
            return Err(RunValidationError::StartedBeforeCreated);
        }
        if self
            .finished_at
            .as_ref()
            .is_some_and(|finished| finished < &self.created_at)
        {
            return Err(RunValidationError::FinishedBeforeCreated);
        }
        if self
            .started_at
            .as_ref()
            .zip(self.finished_at.as_ref())
            .is_some_and(|(started, finished)| finished < started)
        {
            return Err(RunValidationError::FinishedBeforeStarted);
        }

        match self.state {
            JobState::Queued | JobState::Preparing => {
                if self.finished_at.is_some() {
                    return Err(RunValidationError::UnexpectedFinishedAt(self.state));
                }
            }
            JobState::Running | JobState::Verifying => {
                if self.started_at.is_none() {
                    return Err(RunValidationError::MissingStartedAt(self.state));
                }
                if self.finished_at.is_some() {
                    return Err(RunValidationError::UnexpectedFinishedAt(self.state));
                }
            }
            JobState::Succeeded => {
                if self.started_at.is_none() {
                    return Err(RunValidationError::MissingStartedAt(self.state));
                }
                if self.finished_at.is_none() {
                    return Err(RunValidationError::MissingFinishedAt(self.state));
                }
                if self.exit_code != Some(0) {
                    return Err(RunValidationError::InvalidSuccessExitCode(self.exit_code));
                }
                if self.error.as_ref().is_some_and(|error| !error.is_empty()) {
                    return Err(RunValidationError::SuccessContainsError);
                }
            }
            JobState::Failed => {
                if self.finished_at.is_none() {
                    return Err(RunValidationError::MissingFinishedAt(self.state));
                }
                let has_nonzero_exit = self.exit_code.is_some_and(|exit_code| exit_code != 0);
                let has_error = self
                    .error
                    .as_ref()
                    .is_some_and(|error| !error.trim().is_empty());
                if !has_nonzero_exit && !has_error {
                    return Err(RunValidationError::FailedWithoutEvidence);
                }
            }
            JobState::Cancelled => {
                if self.finished_at.is_none() {
                    return Err(RunValidationError::MissingFinishedAt(self.state));
                }
            }
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
#[error("invalid job-state transition from {from:?} to {to:?}")]
pub struct StateTransitionError {
    pub from: JobState,
    pub to: JobState,
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum RunValidationError {
    #[error("startedAt is earlier than createdAt")]
    StartedBeforeCreated,
    #[error("finishedAt is earlier than createdAt")]
    FinishedBeforeCreated,
    #[error("finishedAt is earlier than startedAt")]
    FinishedBeforeStarted,
    #[error("state {0:?} requires startedAt")]
    MissingStartedAt(JobState),
    #[error("state {0:?} requires finishedAt")]
    MissingFinishedAt(JobState),
    #[error("state {0:?} must not contain finishedAt")]
    UnexpectedFinishedAt(JobState),
    #[error("a succeeded run requires exitCode 0, got {0:?}")]
    InvalidSuccessExitCode(Option<i32>),
    #[error("a succeeded run must not contain an error")]
    SuccessContainsError,
    #[error("a failed run requires a non-zero exitCode or a non-empty error")]
    FailedWithoutEvidence,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlacementExplain {
    pub policy: PlacementPolicy,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub selected_node_id: Option<Uuid>,
    #[serde(default)]
    pub candidates: Vec<PlacementCandidateExplain>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlacementCandidateExplain {
    pub node_id: Uuid,
    pub node_name: String,
    pub eligible: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub score: Option<i64>,
    #[serde(default)]
    pub score_components: Vec<ScoreComponent>,
    #[serde(default)]
    pub rejection_reasons: Vec<PlacementRejection>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScoreComponent {
    pub key: String,
    pub value: i64,
    pub detail: String,
}

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RejectionCode {
    Disabled,
    Offline,
    Draining,
    StaleNode,
    ManualNodeRequired,
    ManualNodeMismatch,
    WrongOs,
    WrongArchitecture,
    MissingCapability,
    InsufficientCpu,
    InsufficientMemory,
    InsufficientDisk,
    GpuRequired,
    GpuUnavailable,
    GpuVendorMismatch,
    InsufficientVram,
    ExclusiveGpuUnavailable,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlacementRejection {
    pub code: RejectionCode,
    pub detail: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_job() -> JobSpec {
        JobSpec::new(
            JobKind::Build,
            SourceSpec::Git {
                repository: "https://example.invalid/repo.git".to_owned(),
                revision: "0123456789abcdef".to_owned(),
            },
            vec![JobStep::new("build", "cargo build --locked")],
        )
    }

    #[test]
    fn job_spec_uses_v1_camel_case_wire_contract() {
        let job = sample_job();
        let value = serde_json::to_value(&job).expect("serialize JobSpec");

        assert_eq!(value["apiVersion"], API_VERSION);
        assert_eq!(value["placementPolicy"], "balanced");
        assert_eq!(value["source"]["type"], "git");
        assert!(value.get("preferredNodeId").is_none());
        assert!(value.get("password").is_none());
        assert!(value.get("privateKey").is_none());
    }

    #[test]
    fn job_spec_round_trips_without_losing_defaults() {
        let original = sample_job();
        let encoded = serde_json::to_string(&original).expect("serialize JobSpec");
        let decoded: JobSpec = serde_json::from_str(&encoded).expect("deserialize JobSpec");

        assert_eq!(decoded, original);
        assert_eq!(decoded.placement_policy, PlacementPolicy::Balanced);
        assert!(decoded.validate().is_ok());
    }

    #[test]
    fn omitted_placement_policy_defaults_to_balanced() {
        let mut value = serde_json::to_value(sample_job()).expect("serialize JobSpec");
        value
            .as_object_mut()
            .expect("job object")
            .remove("placementPolicy");

        let decoded: JobSpec = serde_json::from_value(value).expect("deserialize JobSpec");
        assert_eq!(decoded.placement_policy, PlacementPolicy::Balanced);
    }

    #[test]
    fn validation_rejects_unknown_versions_and_empty_work() {
        let mut job = sample_job();
        job.api_version = "cyc.dev/v99".to_owned();
        assert!(matches!(
            job.validate(),
            Err(ValidationError::UnsupportedApiVersion(_))
        ));

        job.api_version = API_VERSION.to_owned();
        job.steps.clear();
        assert_eq!(job.validate(), Err(ValidationError::NoSteps));
    }

    #[test]
    fn job_spec_rejects_unknown_top_level_and_nested_fields() {
        let mut top_level = serde_json::to_value(sample_job()).expect("serialize JobSpec");
        top_level
            .as_object_mut()
            .expect("job object")
            .insert("placementPolciy".to_owned(), serde_json::json!("manual"));
        assert!(serde_json::from_value::<JobSpec>(top_level).is_err());

        let mut nested = serde_json::to_value(sample_job()).expect("serialize JobSpec");
        nested["steps"][0]["environment"] = serde_json::json!({ "TOKEN": "opaque" });
        assert!(serde_json::from_value::<JobSpec>(nested).is_err());
    }

    #[test]
    fn validation_enforces_origin_schema_lengths() {
        let mut job = sample_job();
        job.origin = Some(JobOrigin {
            codex_session_id: Some("x".repeat(257)),
            ..JobOrigin::default()
        });
        assert_eq!(
            job.validate(),
            Err(ValidationError::OriginFieldTooLong("codexSessionId"))
        );
    }

    #[test]
    fn run_state_machine_rejects_terminal_transitions() {
        let mut run = Run::queued(Uuid::new_v4());
        run.transition(JobState::Preparing).expect("prepare");
        run.transition(JobState::Running).expect("run");
        run.transition(JobState::Verifying).expect("verify");
        run.transition(JobState::Succeeded).expect("succeed");

        assert!(run.started_at.is_some());
        assert!(run.finished_at.is_some());
        assert_eq!(
            run.transition(JobState::Running),
            Err(StateTransitionError {
                from: JobState::Succeeded,
                to: JobState::Running,
            })
        );
    }

    #[test]
    fn succeeded_runs_require_verified_terminal_evidence() {
        let mut run = Run::queued(Uuid::new_v4());
        run.transition(JobState::Preparing).expect("prepare");
        run.transition(JobState::Running).expect("run");
        run.transition(JobState::Succeeded).expect("succeed");

        assert_eq!(
            run.validate(),
            Err(RunValidationError::InvalidSuccessExitCode(None))
        );
        run.exit_code = Some(0);
        assert!(run.validate().is_ok());

        run.error = Some("verification failed".to_owned());
        assert_eq!(
            run.validate(),
            Err(RunValidationError::SuccessContainsError)
        );
    }

    #[test]
    fn failed_runs_require_an_exit_code_or_error() {
        let mut run = Run::queued(Uuid::new_v4());
        run.transition(JobState::Failed).expect("fail");
        assert_eq!(
            run.validate(),
            Err(RunValidationError::FailedWithoutEvidence)
        );

        run.error = Some("worker disconnected".to_owned());
        assert!(run.validate().is_ok());
    }

    #[test]
    fn node_transport_serializes_only_an_opaque_credential_reference() {
        let node = Node::new(
            "worker",
            NodeTransport::Ssh {
                host: "worker.lan".to_owned(),
                port: 22,
                username: "builder".to_owned(),
                credential_ref: CredentialRef::new("vault://nodes/worker"),
            },
            OperatingSystem::Linux,
            Architecture::X86_64,
        );
        let encoded = serde_json::to_string(&node).expect("serialize node");

        assert!(encoded.contains("credentialRef"));
        assert!(!encoded.contains("password"));
        assert!(!encoded.contains("privateKey"));
        assert!(node.last_seen_at.is_some());
    }
}
