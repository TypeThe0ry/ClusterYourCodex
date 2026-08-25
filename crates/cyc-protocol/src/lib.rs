//! Transport-neutral domain types shared by ClusterYourCodex components.
//!
//! This crate deliberately carries opaque credential references rather than
//! credential material.  `JobSpec` is safe to pass between Codex, the MCP
//! bridge, the controller, and workers without teaching those layers how a
//! credential is stored.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use thiserror::Error;
use uuid::Uuid;

pub mod cleanup;
pub mod node_state;
pub mod onboarding;
pub mod placement_binding;
pub mod snapshot;
pub mod worker;

pub use cleanup::{
    CleanupFailureCodeV1, CleanupFailureV1, CleanupReceiptV1, CleanupReservationReleaseReasonV1,
    CleanupStatusPhaseV1, CleanupStatusV1, JobRootCleanupOutcomeV1, TerminalCompletionAckV1,
    CLEANUP_API_VERSION, COMPLETION_ACKNOWLEDGED_AT_HEADER, COMPLETION_SHA256_HEADER,
};

pub use node_state::{
    BatteryTelemetry, CapacityPolicy, ContainmentBackend, ContainmentInventory, GpuInventory,
    GpuTelemetry, HostileIsolationBackend, HostileIsolationInventory, NodeAvailability, NodeConfig,
    NodeDesiredState, NodeInventory, NodeMergeView, NodeStateError, NodeTelemetry, PowerSource,
};
pub use placement_binding::{
    PlacementBindingError, PlacementPlanBindingV1, PlacementPlanDecisionV1, SmokeRunBindingV1,
    PLACEMENT_PLAN_BINDING_API_VERSION,
};
pub use snapshot::{
    snapshot_digest_hex, validate_snapshot_digest, validate_snapshot_size, SnapshotContractError,
    SnapshotMetadataV1, MAX_SNAPSHOT_ARCHIVE_BYTES, MAX_SNAPSHOT_ENTRIES,
    MAX_SNAPSHOT_EXPANDED_BYTES, MAX_SNAPSHOT_FILE_BYTES, MAX_SNAPSHOT_PATH_BYTES,
    SNAPSHOT_API_VERSION, SNAPSHOT_ARCHIVE_FORMAT, SNAPSHOT_MEDIA_TYPE,
};

/// Current wire-level API identifier used by [`JobSpec`].
pub const API_VERSION: &str = "cyc.dev/v1";

/// Numeric protocol generation for capability negotiation outside `JobSpec`.
pub const PROTOCOL_VERSION: u32 = 1;

/// Artifact collectors must always apply this exclusion after include rules.
pub const DEFAULT_GIT_ARTIFACT_EXCLUDE: &str = ".git/**";

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

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
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
#[serde(rename_all = "camelCase", deny_unknown_fields)]
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
#[serde(rename_all = "camelCase", deny_unknown_fields)]
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
#[serde(rename_all = "camelCase", deny_unknown_fields)]
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

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
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

/// Explicit consumable capacity requested for one scheduled run. Hard
/// compatibility constraints such as OS, architecture, and capabilities stay
/// in [`JobRequirements`]; this document is reserved for resources that are
/// accounted and reserved by the scheduler.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GpuResourceRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub vendor: Option<GpuVendor>,
    #[serde(default)]
    pub vram_mib: u64,
    #[serde(default = "default_true")]
    pub exclusive: bool,
}

impl Default for GpuResourceRequest {
    fn default() -> Self {
        Self {
            device_id: None,
            vendor: None,
            vram_mib: 0,
            exclusive: true,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ResourceRequest {
    #[serde(default = "default_resource_slots")]
    pub slots: u32,
    #[serde(default = "default_resource_cpu_cores")]
    pub cpu_cores: u32,
    #[serde(default)]
    pub memory_mib: u64,
    #[serde(default)]
    pub disk_mib: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gpu: Option<GpuResourceRequest>,
}

const fn default_resource_slots() -> u32 {
    1
}

const fn default_resource_cpu_cores() -> u32 {
    1
}

impl Default for ResourceRequest {
    fn default() -> Self {
        Self {
            slots: default_resource_slots(),
            cpu_cores: default_resource_cpu_cores(),
            memory_mib: 0,
            disk_mib: 0,
            gpu: None,
        }
    }
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

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ArtifactSpec {
    #[serde(default)]
    pub include: Vec<String>,
    #[serde(default = "default_artifact_excludes")]
    pub exclude: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retention_days: Option<u32>,
}

impl Default for ArtifactSpec {
    fn default() -> Self {
        Self {
            include: Vec::new(),
            exclude: default_artifact_excludes(),
            retention_days: None,
        }
    }
}

fn default_artifact_excludes() -> Vec<String> {
    vec![DEFAULT_GIT_ARTIFACT_EXCLUDE.to_owned()]
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
    /// Omission is wire-compatible with preview clients. The deterministic
    /// effective value is then derived from legacy `requirements`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resource_request: Option<ResourceRequest>,
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
            resource_request: None,
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
            if let Some(working_directory) = &step.working_directory {
                validate_portable_relative_path(working_directory)
                    .map_err(|source| ValidationError::InvalidWorkingDirectory { index, source })?;
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
        if let Some(request) = &self.resource_request {
            validate_resource_request(request, &self.requirements)?;
        }
        if matches!(self.artifacts.retention_days, Some(0 | 3651..)) {
            return Err(ValidationError::InvalidRetentionDays);
        }
        for (index, pattern) in self.artifacts.include.iter().enumerate() {
            validate_portable_relative_glob(pattern).map_err(|source| {
                ValidationError::InvalidArtifactPattern {
                    field: "include",
                    index,
                    source,
                }
            })?;
            if has_literal_git_segment(pattern) {
                return Err(ValidationError::GitMetadataIncluded(index));
            }
        }
        for (index, pattern) in self.artifacts.exclude.iter().enumerate() {
            validate_portable_relative_glob(pattern).map_err(|source| {
                ValidationError::InvalidArtifactPattern {
                    field: "exclude",
                    index,
                    source,
                }
            })?;
        }
        if !self
            .artifacts
            .exclude
            .iter()
            .any(|pattern| matches!(pattern.as_str(), ".git" | DEFAULT_GIT_ARTIFACT_EXCLUDE))
        {
            return Err(ValidationError::GitMetadataNotExcluded);
        }
        match &self.source {
            SourceSpec::Git {
                repository,
                revision,
            } => {
                validate_public_https_repository(repository)?;
                if !matches!(revision.len(), 40 | 64)
                    || !revision
                        .bytes()
                        .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
                {
                    return Err(ValidationError::InvalidSource(
                        "git revision must be a complete 40- or 64-character lowercase hex object ID",
                    ));
                }
            }
            SourceSpec::Snapshot { digest, size_bytes } => {
                snapshot::validate_snapshot_digest(digest).map_err(|_| {
                    ValidationError::InvalidSource(
                        "snapshot digest must be sha256 followed by 64 lowercase hex digits",
                    )
                })?;
                let size_bytes = size_bytes.ok_or(ValidationError::InvalidSource(
                    "snapshot sizeBytes is required and must bind the raw archive bytes",
                ))?;
                snapshot::validate_snapshot_size(size_bytes).map_err(|_| {
                    ValidationError::InvalidSource(
                        "snapshot sizeBytes must be in the supported bounded range",
                    )
                })?;
            }
        }
        Ok(())
    }

    /// Produce the one scheduler resource contract for both legacy and new
    /// clients. Explicit requests are validated not to weaken legacy minima.
    pub fn effective_resource_request(&self) -> ResourceRequest {
        self.resource_request
            .clone()
            .unwrap_or_else(|| resource_request_from_legacy(&self.requirements))
    }
}

fn resource_request_from_legacy(requirements: &JobRequirements) -> ResourceRequest {
    ResourceRequest {
        slots: 1,
        cpu_cores: requirements.min_cpu_cores.unwrap_or(1),
        memory_mib: requirements.min_memory_mib.unwrap_or(0),
        disk_mib: requirements.min_disk_mib.unwrap_or(0),
        gpu: requirements.gpu.as_ref().map(|gpu| GpuResourceRequest {
            device_id: None,
            vendor: gpu.vendor,
            vram_mib: gpu.min_vram_mib.unwrap_or(0),
            exclusive: gpu.exclusive,
        }),
    }
}

fn validate_resource_request(
    request: &ResourceRequest,
    legacy: &JobRequirements,
) -> Result<(), ValidationError> {
    if request.slots == 0 {
        return Err(ValidationError::ZeroResourceRequest("slots"));
    }
    if request.cpu_cores == 0 {
        return Err(ValidationError::ZeroResourceRequest("cpuCores"));
    }
    if request.cpu_cores < legacy.min_cpu_cores.unwrap_or(1)
        || request.memory_mib < legacy.min_memory_mib.unwrap_or(0)
        || request.disk_mib < legacy.min_disk_mib.unwrap_or(0)
    {
        return Err(ValidationError::ResourceRequestWeakensLegacy);
    }
    if let Some(gpu) = &request.gpu {
        if gpu.device_id.as_ref().is_some_and(|device_id| {
            device_id.trim().is_empty()
                || device_id.chars().count() > 256
                || device_id.chars().any(char::is_control)
        }) {
            return Err(ValidationError::InvalidGpuDeviceId);
        }
    }
    match (&request.gpu, &legacy.gpu) {
        (None, Some(_)) => return Err(ValidationError::ResourceRequestWeakensLegacy),
        (Some(request), Some(legacy)) => {
            if request.vram_mib < legacy.min_vram_mib.unwrap_or(0)
                || legacy.exclusive && !request.exclusive
                || request
                    .vendor
                    .zip(legacy.vendor)
                    .is_some_and(|(requested, required)| requested != required)
            {
                return Err(ValidationError::ResourceRequestWeakensLegacy);
            }
            if legacy.vendor.is_some() && request.vendor.is_none() {
                return Err(ValidationError::ResourceRequestWeakensLegacy);
            }
        }
        _ => {}
    }
    Ok(())
}

/// Apply scheduler-equivalent defaults before binding a job to a plan or run.
///
/// Every component that computes or verifies a job digest must call this one
/// shared normalization path. Adding a new scheduling-equivalent default is a
/// wire-level change and therefore requires a golden digest test.
pub fn normalize_job_spec(job: &JobSpec) -> JobSpec {
    let mut normalized = job.clone();
    if normalized.requirements.min_cpu_cores.is_none() {
        normalized.requirements.min_cpu_cores = Some(1);
    }
    normalized
}

/// SHA-256 of the normalized `JobSpec` encoded as recursively key-sorted,
/// whitespace-free JSON.
///
/// This is the only supported digest algorithm for `ClaimAssignment.jobDigest`.
/// It deliberately does not hash `serde_json::to_vec(job)` because Rust field
/// order is not a cross-implementation canonicalization contract.
pub fn canonical_job_digest(job: &JobSpec) -> Result<String, serde_json::Error> {
    let value = serde_json::to_value(normalize_job_spec(job))?;
    let mut canonical = Vec::new();
    write_canonical_json(&value, &mut canonical)?;
    let digest = Sha256::digest(canonical);
    Ok(digest.iter().map(|byte| format!("{byte:02x}")).collect())
}

fn write_canonical_json(value: &Value, output: &mut Vec<u8>) -> Result<(), serde_json::Error> {
    match value {
        Value::Null | Value::Bool(_) | Value::Number(_) | Value::String(_) => {
            serde_json::to_writer(&mut *output, value)?;
        }
        Value::Array(values) => {
            output.push(b'[');
            for (index, value) in values.iter().enumerate() {
                if index > 0 {
                    output.push(b',');
                }
                write_canonical_json(value, output)?;
            }
            output.push(b']');
        }
        Value::Object(values) => {
            output.push(b'{');
            let mut keys = values.keys().collect::<Vec<_>>();
            keys.sort_unstable();
            for (index, key) in keys.into_iter().enumerate() {
                if index > 0 {
                    output.push(b',');
                }
                serde_json::to_writer(&mut *output, key)?;
                output.push(b':');
                write_canonical_json(&values[key], output)?;
            }
            output.push(b'}');
        }
    }
    Ok(())
}

/// Validate a path that must mean the same job-owned location on Windows,
/// Linux, and macOS. The path is deliberately lexical: workers join it below
/// an already-proven job root and never canonicalize an attacker-selected
/// absolute path.
pub fn validate_portable_relative_path(value: &str) -> Result<(), PortablePathError> {
    validate_portable_relative(value, false)
}

/// Validate a glob whose matches are constrained to a job-owned root.
///
/// Glob metacharacters are allowed inside a segment, but negated patterns and
/// traversal/absolute syntax are not. Exclusion rules are applied after all
/// include rules by the worker.
pub fn validate_portable_relative_glob(value: &str) -> Result<(), PortablePathError> {
    validate_portable_relative(value, true)
}

fn validate_portable_relative(value: &str, glob: bool) -> Result<(), PortablePathError> {
    if value.is_empty() {
        return Err(PortablePathError::Empty);
    }
    if value.contains('\0') {
        return Err(PortablePathError::Nul);
    }
    if value.contains('\\') {
        return Err(PortablePathError::Backslash);
    }
    if value.starts_with('/') {
        return Err(PortablePathError::Absolute);
    }
    if value
        .as_bytes()
        .get(0..2)
        .is_some_and(|prefix| prefix[0].is_ascii_alphabetic() && prefix[1] == b':')
    {
        return Err(PortablePathError::DrivePrefix);
    }
    if glob && value.starts_with('!') {
        return Err(PortablePathError::NegatedGlob);
    }

    for segment in value.split('/') {
        match segment {
            "" => return Err(PortablePathError::EmptySegment),
            "." => return Err(PortablePathError::DotSegment),
            ".." => return Err(PortablePathError::ParentSegment),
            _ => {}
        }
    }
    Ok(())
}

fn has_literal_git_segment(value: &str) -> bool {
    value.split('/').any(|segment| segment == ".git")
}

fn validate_public_https_repository(repository: &str) -> Result<(), ValidationError> {
    if repository.trim() != repository
        || repository.chars().any(char::is_control)
        || repository
            .chars()
            .any(|character| matches!(character, '?' | '#' | '\\'))
    {
        return Err(ValidationError::InvalidSource(
            "git repository must be a canonical public HTTPS URL without query or fragment",
        ));
    }

    let Some(remainder) = repository.strip_prefix("https://") else {
        return Err(ValidationError::InvalidSource(
            "git repository must use https://",
        ));
    };
    let Some((authority, path)) = remainder.split_once('/') else {
        return Err(ValidationError::InvalidSource(
            "git repository URL must contain a repository path",
        ));
    };
    if authority.is_empty() || authority.contains('@') {
        return Err(ValidationError::InvalidSource(
            "git repository URL must not contain userinfo",
        ));
    }
    if path.is_empty()
        || path.split('/').any(|segment| segment.is_empty())
        || path.split('/').any(|segment| matches!(segment, "." | ".."))
    {
        return Err(ValidationError::InvalidSource(
            "git repository URL must contain a canonical repository path",
        ));
    }

    let host = repository_host(authority)?;
    if !is_public_repository_host(host) {
        return Err(ValidationError::InvalidSource(
            "git repository host must be public",
        ));
    }
    Ok(())
}

fn repository_host(authority: &str) -> Result<&str, ValidationError> {
    if let Some(bracketed) = authority.strip_prefix('[') {
        let Some(close) = bracketed.find(']') else {
            return Err(ValidationError::InvalidSource(
                "git repository host is invalid",
            ));
        };
        let (host, suffix) = bracketed.split_at(close);
        let suffix = &suffix[1..];
        if !suffix.is_empty() && !valid_port_suffix(suffix) {
            return Err(ValidationError::InvalidSource(
                "git repository port is invalid",
            ));
        }
        if host.is_empty() {
            return Err(ValidationError::InvalidSource(
                "git repository host is invalid",
            ));
        }
        return Ok(host);
    }

    if authority.matches(':').count() > 1 {
        return Err(ValidationError::InvalidSource(
            "IPv6 git repository hosts must use brackets",
        ));
    }
    let (host, suffix) = authority
        .split_once(':')
        .map_or((authority, ""), |(host, port)| (host, port));
    if host.is_empty()
        || !host
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-'))
        || host.starts_with('.')
        || host.ends_with('.')
    {
        return Err(ValidationError::InvalidSource(
            "git repository host is invalid",
        ));
    }
    if !suffix.is_empty() && !valid_port(suffix) {
        return Err(ValidationError::InvalidSource(
            "git repository port is invalid",
        ));
    }
    Ok(host)
}

fn valid_port_suffix(suffix: &str) -> bool {
    suffix.strip_prefix(':').is_some_and(valid_port)
}

fn valid_port(port: &str) -> bool {
    port.parse::<u16>().is_ok_and(|port| port != 0)
}

fn is_public_repository_host(host: &str) -> bool {
    if host.eq_ignore_ascii_case("localhost")
        || host.to_ascii_lowercase().ends_with(".localhost")
        || host.to_ascii_lowercase().ends_with(".local")
    {
        return false;
    }
    match host.parse::<IpAddr>() {
        Ok(IpAddr::V4(address)) => is_public_ipv4(address),
        Ok(IpAddr::V6(address)) => is_public_ipv6(address),
        Err(_) => true,
    }
}

fn is_public_ipv4(address: Ipv4Addr) -> bool {
    let [a, b, _, _] = address.octets();
    !(a == 0
        || a == 10
        || a == 127
        || (a == 100 && (64..=127).contains(&b))
        || (a == 169 && b == 254)
        || (a == 172 && (16..=31).contains(&b))
        || (a == 192 && b == 168)
        || (a == 198 && (18..=19).contains(&b))
        || a >= 224)
}

fn is_public_ipv6(address: Ipv6Addr) -> bool {
    if address.is_unspecified() || address.is_loopback() || address.is_multicast() {
        return false;
    }
    let first = address.segments()[0];
    if first & 0xfe00 == 0xfc00 || first & 0xffc0 == 0xfe80 {
        return false;
    }
    address.to_ipv4().is_none_or(is_public_ipv4)
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum PortablePathError {
    #[error("path must not be empty")]
    Empty,
    #[error("NUL is not allowed")]
    Nul,
    #[error("backslashes are not portable")]
    Backslash,
    #[error("absolute paths are not allowed")]
    Absolute,
    #[error("Windows drive prefixes are not allowed")]
    DrivePrefix,
    #[error("empty path segments are not allowed")]
    EmptySegment,
    #[error("dot path segments are not allowed")]
    DotSegment,
    #[error("parent path segments are not allowed")]
    ParentSegment,
    #[error("negated glob patterns are not allowed")]
    NegatedGlob,
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
    #[error("steps[{index}].workingDirectory is invalid: {source}")]
    InvalidWorkingDirectory {
        index: usize,
        source: PortablePathError,
    },
    #[error("{0} must be in the inclusive range 1..=86400")]
    InvalidTimeout(&'static str),
    #[error("capability names must not be empty")]
    EmptyCapability,
    #[error("{0} must be greater than zero")]
    ZeroRequirement(&'static str),
    #[error("resourceRequest.{0} must be greater than zero")]
    ZeroResourceRequest(&'static str),
    #[error("resourceRequest must not weaken legacy requirements")]
    ResourceRequestWeakensLegacy,
    #[error("resourceRequest.gpu.deviceId is invalid")]
    InvalidGpuDeviceId,
    #[error("retentionDays must be in the inclusive range 1..=3650")]
    InvalidRetentionDays,
    #[error("artifacts.{field}[{index}] is invalid: {source}")]
    InvalidArtifactPattern {
        field: &'static str,
        index: usize,
        source: PortablePathError,
    },
    #[error("artifacts.include[{0}] must not explicitly include .git metadata")]
    GitMetadataIncluded(usize),
    #[error("artifacts.exclude must contain .git/** (or .git)")]
    GitMetadataNotExcluded,
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
    PolicyJobKindDenied,
    BatteryDisallowed,
    CpuLimitExceeded,
    CpuEwmaLimitExceeded,
    MemoryLimitExceeded,
    TemperatureLimitExceeded,
    SlotLimitReached,
    ContainmentLimitReached,
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
                revision: "0123456789abcdef0123456789abcdef01234567".to_owned(),
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
    fn omitted_artifact_excludes_default_to_git_metadata_protection() {
        let mut value = serde_json::to_value(sample_job()).expect("serialize JobSpec");
        value["artifacts"] = serde_json::json!({});

        let decoded: JobSpec = serde_json::from_value(value).expect("deserialize JobSpec");
        assert_eq!(
            decoded.artifacts.exclude,
            vec![DEFAULT_GIT_ARTIFACT_EXCLUDE.to_owned()]
        );
        decoded.validate().expect("default artifact exclusion");
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
    fn git_sources_require_public_https_and_complete_object_ids() {
        let invalid_repositories = [
            "http://example.invalid/repo.git",
            "ssh://git@example.invalid/repo.git",
            "https://user@example.invalid/repo.git",
            "https://example.invalid/repo.git?token=secret",
            "https://example.invalid/repo.git#main",
            "https://localhost/repo.git",
            "https://192.168.1.10/repo.git",
            "https://example.invalid",
        ];
        for repository in invalid_repositories {
            let mut job = sample_job();
            let SourceSpec::Git {
                repository: current,
                ..
            } = &mut job.source
            else {
                unreachable!()
            };
            *current = repository.to_owned();
            assert!(matches!(
                job.validate(),
                Err(ValidationError::InvalidSource(_))
            ));
        }

        for revision in [
            "0123456789abcdef".to_owned(),
            "0123456789abcdef0123456789abcdef0123456G".to_owned(),
            "ABCDEF0123456789ABCDEF0123456789ABCDEF01".to_owned(),
            "a".repeat(63),
        ] {
            let mut job = sample_job();
            let SourceSpec::Git {
                revision: current, ..
            } = &mut job.source
            else {
                unreachable!()
            };
            *current = revision;
            assert!(matches!(
                job.validate(),
                Err(ValidationError::InvalidSource(_))
            ));
        }

        let mut sha256_job = sample_job();
        let SourceSpec::Git { revision, .. } = &mut sha256_job.source else {
            unreachable!()
        };
        *revision = "a".repeat(64);
        sha256_job.validate().expect("64-character object ID");
    }

    #[test]
    fn snapshot_sources_require_raw_archive_digest_and_exact_bounded_size() {
        let digest = format!("sha256:{}", "a".repeat(64));
        let mut job = JobSpec::new(
            JobKind::Build,
            SourceSpec::Snapshot {
                digest: digest.clone(),
                size_bytes: None,
            },
            vec![JobStep::new("build", "cargo build")],
        );
        assert!(matches!(
            job.validate(),
            Err(ValidationError::InvalidSource(_))
        ));
        if let SourceSpec::Snapshot { size_bytes, .. } = &mut job.source {
            *size_bytes = Some(0);
        }
        assert!(job.validate().is_err());
        if let SourceSpec::Snapshot { size_bytes, .. } = &mut job.source {
            *size_bytes = Some(42);
        }
        job.validate().unwrap();
        let SourceSpec::Snapshot { digest, .. } = &mut job.source else {
            unreachable!()
        };
        *digest = format!("sha256:{}", "A".repeat(64));
        assert!(job.validate().is_err());
    }

    #[test]
    fn working_directories_reject_non_portable_and_traversal_paths() {
        for path in [
            "",
            "/tmp/build",
            "C:/build",
            "//server/share",
            "target\\release",
            "target//release",
            "target/./release",
            "target/../release",
            "target/\0release",
        ] {
            let mut job = sample_job();
            job.steps[0].working_directory = Some(path.to_owned());
            assert!(matches!(
                job.validate(),
                Err(ValidationError::InvalidWorkingDirectory { .. })
            ));
        }

        let mut job = sample_job();
        job.steps[0].working_directory = Some("crates/cyc-protocol".to_owned());
        job.validate().expect("portable working directory");
    }

    #[test]
    fn artifact_globs_are_relative_and_always_exclude_git_metadata() {
        let default = ArtifactSpec::default();
        assert_eq!(
            default.exclude,
            vec![DEFAULT_GIT_ARTIFACT_EXCLUDE.to_owned()]
        );

        let mut job = sample_job();
        job.artifacts.include = vec!["target/**/*.zip".to_owned()];
        job.validate().expect("safe relative artifact glob");

        job.artifacts.exclude.clear();
        assert_eq!(job.validate(), Err(ValidationError::GitMetadataNotExcluded));

        job.artifacts.exclude = vec![DEFAULT_GIT_ARTIFACT_EXCLUDE.to_owned()];
        job.artifacts.include = vec![".git/config".to_owned()];
        assert_eq!(job.validate(), Err(ValidationError::GitMetadataIncluded(0)));

        for pattern in ["/etc/*", "C:/*", "../*.zip", "target\\*.zip", "!secret"] {
            let mut job = sample_job();
            job.artifacts.include = vec![pattern.to_owned()];
            assert!(matches!(
                job.validate(),
                Err(ValidationError::InvalidArtifactPattern { .. })
            ));
        }
    }

    #[test]
    fn canonical_job_digest_has_one_normalized_golden_contract() {
        let mut implicit_default = sample_job();
        implicit_default.id = Uuid::nil();
        let digest = canonical_job_digest(&implicit_default).expect("canonical digest");
        assert_eq!(
            digest,
            "c42a975899786da2fe30fc286d8ab2dae08519696e659c9ac524d9adcadaad73"
        );

        let mut explicit_default = implicit_default.clone();
        explicit_default.requirements.min_cpu_cores = Some(1);
        assert_eq!(
            canonical_job_digest(&implicit_default).expect("implicit digest"),
            canonical_job_digest(&explicit_default).expect("explicit digest")
        );

        explicit_default.steps[0].script.push_str(" --release");
        assert_ne!(
            canonical_job_digest(&implicit_default).expect("original digest"),
            canonical_job_digest(&explicit_default).expect("changed digest")
        );
    }

    #[test]
    fn absent_resource_request_preserves_wire_and_maps_legacy_requirements() {
        let mut job = sample_job();
        job.requirements.min_cpu_cores = Some(4);
        job.requirements.min_memory_mib = Some(8_192);
        job.requirements.min_disk_mib = Some(20_000);
        job.requirements.gpu = Some(GpuRequirement {
            vendor: Some(GpuVendor::Nvidia),
            min_vram_mib: Some(6_144),
            exclusive: true,
        });
        let value = serde_json::to_value(&job).unwrap();
        assert!(value.get("resourceRequest").is_none());
        assert_eq!(
            job.effective_resource_request(),
            ResourceRequest {
                slots: 1,
                cpu_cores: 4,
                memory_mib: 8_192,
                disk_mib: 20_000,
                gpu: Some(GpuResourceRequest {
                    device_id: None,
                    vendor: Some(GpuVendor::Nvidia),
                    vram_mib: 6_144,
                    exclusive: true,
                }),
            }
        );
        job.validate().unwrap();
    }

    #[test]
    fn explicit_resource_request_is_bound_and_cannot_weaken_legacy_minima() {
        let mut job = sample_job();
        job.requirements.min_cpu_cores = Some(2);
        job.resource_request = Some(ResourceRequest {
            slots: 1,
            cpu_cores: 3,
            memory_mib: 4_096,
            disk_mib: 1_024,
            gpu: None,
        });
        job.validate().unwrap();
        let encoded = serde_json::to_value(&job).unwrap();
        assert_eq!(encoded["resourceRequest"]["cpuCores"], 3);

        let original_digest = canonical_job_digest(&job).unwrap();
        job.resource_request.as_mut().unwrap().cpu_cores = 4;
        assert_ne!(original_digest, canonical_job_digest(&job).unwrap());

        job.resource_request.as_mut().unwrap().cpu_cores = 1;
        assert_eq!(
            job.validate(),
            Err(ValidationError::ResourceRequestWeakensLegacy)
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
