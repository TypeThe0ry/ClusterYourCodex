//! Split node-state contracts.
//!
//! Controller-owned configuration, worker-owned static inventory, and
//! worker-observed dynamic telemetry intentionally travel and persist as
//! separate documents. [`NodeMergeView`] is the compatibility boundary for
//! existing scheduler/API consumers that still use [`crate::Node`].

use std::collections::{BTreeMap, BTreeSet};
use std::time::Duration;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

use crate::{
    Architecture, Capability, GpuDevice, GpuVendor, JobKind, Node, NodeLoad, NodeResources,
    NodeStatus, NodeTransport, OperatingSystem, PROTOCOL_VERSION,
};

const MAX_TEMPERATURE_C: i16 = 200;
const MIN_TEMPERATURE_C: i16 = -100;

const fn default_max_concurrent_jobs() -> u32 {
    1
}

const fn default_protocol_version() -> u32 {
    PROTOCOL_VERSION
}

fn default_unknown() -> String {
    "unknown".to_owned()
}

/// Controller intent is independent from the last status observed on the
/// worker. `Active` remains the legacy-compatible default; `Draining` stops
/// new placement without pretending that a currently running worker is
/// offline.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NodeDesiredState {
    #[default]
    Active,
    Draining,
}

/// Controller-owned admission and resource-allocation policy.
///
/// An empty `allowedJobKinds` set means all job kinds. Resource ceilings are
/// optional so legacy node JSON keeps its previous effective behavior. The
/// worker still advertises a containment-enforced hard maximum independently.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CapacityPolicy {
    #[serde(default = "default_max_concurrent_jobs")]
    pub max_concurrent_jobs: u32,
    #[serde(default)]
    pub allocatable_cpu_cores: Option<u32>,
    #[serde(default)]
    pub allocatable_cpu_percent: Option<u8>,
    #[serde(default)]
    pub memory_limit_mib: Option<u64>,
    #[serde(default)]
    pub allowed_job_kinds: BTreeSet<JobKind>,
    #[serde(default)]
    pub allow_on_battery: bool,
    #[serde(default)]
    pub max_cpu_percent: Option<u8>,
    #[serde(default)]
    pub max_cpu_ewma_percent: Option<u8>,
    #[serde(default)]
    pub max_memory_percent: Option<u8>,
    #[serde(default)]
    pub max_temperature_c: Option<i16>,
}

impl Default for CapacityPolicy {
    fn default() -> Self {
        Self {
            max_concurrent_jobs: default_max_concurrent_jobs(),
            allocatable_cpu_cores: None,
            allocatable_cpu_percent: None,
            memory_limit_mib: None,
            allowed_job_kinds: BTreeSet::new(),
            allow_on_battery: false,
            max_cpu_percent: None,
            max_cpu_ewma_percent: None,
            max_memory_percent: None,
            max_temperature_c: None,
        }
    }
}

impl CapacityPolicy {
    pub fn validate(&self) -> Result<(), NodeStateError> {
        if self.max_concurrent_jobs == 0 {
            return Err(NodeStateError::InvalidConfig("capacity.maxConcurrentJobs"));
        }
        if self.allocatable_cpu_cores == Some(0) {
            return Err(NodeStateError::InvalidConfig(
                "capacity.allocatableCpuCores",
            ));
        }
        if self.memory_limit_mib == Some(0) {
            return Err(NodeStateError::InvalidConfig("capacity.memoryLimitMiB"));
        }
        for (field, value) in [
            (
                "capacity.allocatableCpuPercent",
                self.allocatable_cpu_percent,
            ),
            ("capacity.maxCpuPercent", self.max_cpu_percent),
            ("capacity.maxCpuEwmaPercent", self.max_cpu_ewma_percent),
            ("capacity.maxMemoryPercent", self.max_memory_percent),
        ] {
            if value.is_some_and(|value| value == 0 || value > 100) {
                return Err(NodeStateError::InvalidConfig(field));
            }
        }
        if self.max_temperature_c.is_some_and(|temperature| {
            !(MIN_TEMPERATURE_C..=MAX_TEMPERATURE_C).contains(&temperature)
        }) {
            return Err(NodeStateError::InvalidConfig("capacity.maxTemperatureC"));
        }
        Ok(())
    }
}

/// User/controller-owned settings. A worker probe must never overwrite this
/// document after the logical node has been created.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NodeConfig {
    pub name: String,
    pub enabled: bool,
    pub priority: i32,
    pub labels: BTreeMap<String, String>,
    #[serde(default)]
    pub desired_state: NodeDesiredState,
    #[serde(default)]
    pub capacity: CapacityPolicy,
}

impl NodeConfig {
    pub fn from_node(node: &Node) -> Self {
        Self {
            name: node.name.clone(),
            enabled: node.enabled,
            priority: node.priority,
            labels: node.labels.clone(),
            desired_state: NodeDesiredState::default(),
            capacity: CapacityPolicy::default(),
        }
    }

    pub fn validate(&self) -> Result<(), NodeStateError> {
        if self.name.trim().is_empty()
            || self.name.chars().count() > 128
            || self.name.chars().any(char::is_control)
        {
            return Err(NodeStateError::InvalidConfig("name"));
        }
        if self.labels.iter().any(|(key, value)| {
            key.trim().is_empty()
                || key.chars().count() > 128
                || value.chars().count() > 1_024
                || key.chars().any(char::is_control)
                || value.chars().any(char::is_control)
        }) {
            return Err(NodeStateError::InvalidConfig("labels"));
        }
        self.capacity.validate()?;
        Ok(())
    }
}

/// Static portion of a GPU report.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GpuInventory {
    pub vendor: GpuVendor,
    pub model: String,
    pub total_vram_mib: u64,
    #[serde(default)]
    pub stable_id: Option<String>,
    #[serde(default)]
    pub driver_version: Option<String>,
}

/// Process-tree containment backend that bounds safe worker concurrency.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ContainmentBackend {
    #[default]
    Legacy,
    LinuxSubreaperProcessGroup,
    /// macOS native process-group inventory and descendant reconciliation.
    ///
    /// This is the trusted same-user lifecycle backend; hostile-workload
    /// isolation remains a separate, fail-closed capability.
    MacosProcessGroup,
    WindowsJobObject,
    Unsupported,
}

/// Opt-in hostile-workload isolation backend.  This is deliberately separate
/// from [`ContainmentBackend`]: the latter proves that a trusted same-user
/// process tree is gone, while this capability also requires a dedicated
/// execution identity, state/credential separation, and restart-time external
/// reconciliation.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HostileIsolationBackend {
    #[default]
    Disabled,
    LinuxCgroupV2DedicatedIdentity,
    WindowsJobObjectExternalGuard,
    MacosExternalReconciliation,
    Unsupported,
}

/// Secret-free hostile-workload capability advertised by a worker.  `ready`
/// is intentionally fail-closed: it may be true only after every protection
/// below is active and restart reconciliation has produced a valid receipt.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct HostileIsolationInventory {
    #[serde(default)]
    pub opt_in: bool,
    #[serde(default)]
    pub ready: bool,
    #[serde(default)]
    pub backend: HostileIsolationBackend,
    #[serde(default)]
    pub dedicated_identity: bool,
    #[serde(default)]
    pub external_reconciliation: bool,
    #[serde(default)]
    pub protected_guard_state: bool,
    #[serde(default)]
    pub worker_state_isolated: bool,
    #[serde(default)]
    pub reason_code: Option<String>,
}

impl Default for HostileIsolationInventory {
    fn default() -> Self {
        Self {
            opt_in: false,
            ready: false,
            backend: HostileIsolationBackend::Disabled,
            dedicated_identity: false,
            external_reconciliation: false,
            protected_guard_state: false,
            worker_state_isolated: false,
            reason_code: None,
        }
    }
}

impl HostileIsolationInventory {
    fn validate(&self) -> Result<(), NodeStateError> {
        if self.reason_code.as_ref().is_some_and(|reason| {
            reason.trim().is_empty()
                || reason.chars().count() > 128
                || reason.chars().any(char::is_control)
        }) {
            return Err(NodeStateError::InvalidInventory(
                "hostile isolation reasonCode is invalid",
            ));
        }

        if !self.opt_in {
            if self.ready
                || self.backend != HostileIsolationBackend::Disabled
                || self.dedicated_identity
                || self.external_reconciliation
                || self.protected_guard_state
                || self.worker_state_isolated
                || self.reason_code.is_some()
            {
                return Err(NodeStateError::InvalidInventory(
                    "disabled hostile isolation must use conservative defaults",
                ));
            }
            return Ok(());
        }

        if self.backend == HostileIsolationBackend::Disabled {
            return Err(NodeStateError::InvalidInventory(
                "opt-in hostile isolation must identify a backend",
            ));
        }
        if self.ready
            && (!self.dedicated_identity
                || !self.external_reconciliation
                || !self.protected_guard_state
                || !self.worker_state_isolated
                || self.reason_code.is_some()
                || matches!(
                    self.backend,
                    HostileIsolationBackend::MacosExternalReconciliation
                        | HostileIsolationBackend::Unsupported
                ))
        {
            return Err(NodeStateError::InvalidInventory(
                "ready hostile isolation is missing a required protection",
            ));
        }
        if !self.ready && self.reason_code.is_none() {
            return Err(NodeStateError::InvalidInventory(
                "unready hostile isolation must provide a reasonCode",
            ));
        }
        Ok(())
    }
}

/// Static containment capability. P0 deliberately advertises one safe slot;
/// this prevents policy configuration from enabling unsafe multi-run execution.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ContainmentInventory {
    #[serde(default)]
    pub backend: ContainmentBackend,
    #[serde(default = "default_unknown")]
    pub version: String,
    #[serde(default = "default_max_concurrent_jobs")]
    pub max_safe_slots: u32,
    #[serde(default)]
    pub hostile_isolation: HostileIsolationInventory,
}

impl Default for ContainmentInventory {
    fn default() -> Self {
        Self {
            backend: ContainmentBackend::Legacy,
            version: default_unknown(),
            max_safe_slots: 1,
            hostile_isolation: HostileIsolationInventory::default(),
        }
    }
}

/// Worker-owned hardware, platform, transport, and tool/capability inventory.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NodeInventory {
    pub transport: NodeTransport,
    pub os: OperatingSystem,
    pub arch: Architecture,
    pub capabilities: BTreeSet<Capability>,
    pub logical_cpu_cores: u32,
    pub memory_mib: u64,
    pub disk_mib: u64,
    pub gpus: Vec<GpuInventory>,
    #[serde(default = "default_unknown")]
    pub cpu_model: String,
    #[serde(default)]
    pub tool_versions: BTreeMap<String, String>,
    #[serde(default = "default_unknown")]
    pub worker_version: String,
    #[serde(default = "default_protocol_version")]
    pub protocol_version: u32,
    #[serde(default)]
    pub containment: ContainmentInventory,
}

impl NodeInventory {
    pub fn from_node(node: &Node) -> Self {
        Self {
            transport: node.transport.clone(),
            os: node.os,
            arch: node.arch,
            capabilities: node.capabilities.clone(),
            logical_cpu_cores: node.resources.logical_cpu_cores,
            memory_mib: node.resources.memory_mib,
            disk_mib: node.resources.disk_mib,
            gpus: node
                .resources
                .gpus
                .iter()
                .map(|gpu| GpuInventory {
                    vendor: gpu.vendor,
                    model: gpu.model.clone(),
                    total_vram_mib: gpu.total_vram_mib,
                    stable_id: None,
                    driver_version: None,
                })
                .collect(),
            cpu_model: default_unknown(),
            tool_versions: BTreeMap::new(),
            worker_version: default_unknown(),
            protocol_version: PROTOCOL_VERSION,
            containment: ContainmentInventory::default(),
        }
    }

    pub fn validate(&self) -> Result<(), NodeStateError> {
        if self
            .capabilities
            .iter()
            .any(|capability| !capability.is_valid())
        {
            return Err(NodeStateError::InvalidInventory(
                "capability names must not be empty",
            ));
        }
        let mut gpu_ids = BTreeSet::new();
        if self.gpus.iter().any(|gpu| {
            gpu.model.trim().is_empty()
                || gpu.model.chars().count() > 512
                || gpu.model.chars().any(char::is_control)
                || gpu.total_vram_mib == 0
                || gpu.stable_id.as_ref().is_some_and(|stable_id| {
                    stable_id.trim().is_empty()
                        || stable_id.chars().count() > 256
                        || stable_id.chars().any(char::is_control)
                        || !gpu_ids.insert(stable_id)
                })
                || gpu.driver_version.as_ref().is_some_and(|version| {
                    version.trim().is_empty()
                        || version.chars().count() > 128
                        || version.chars().any(char::is_control)
                })
        }) {
            return Err(NodeStateError::InvalidInventory("invalid GPU inventory"));
        }
        if self.cpu_model.trim().is_empty()
            || self.cpu_model.chars().count() > 512
            || self.cpu_model.chars().any(char::is_control)
        {
            return Err(NodeStateError::InvalidInventory("invalid cpuModel"));
        }
        if self.worker_version.trim().is_empty()
            || self.worker_version.chars().count() > 128
            || self.worker_version.chars().any(char::is_control)
        {
            return Err(NodeStateError::InvalidInventory("invalid workerVersion"));
        }
        if self.protocol_version != PROTOCOL_VERSION {
            return Err(NodeStateError::InvalidInventory(
                "unsupported protocolVersion",
            ));
        }
        if self.tool_versions.iter().any(|(name, version)| {
            name.trim().is_empty()
                || name.chars().count() > 128
                || version.trim().is_empty()
                || version.chars().count() > 512
                || name.chars().any(char::is_control)
                || version.chars().any(char::is_control)
        }) {
            return Err(NodeStateError::InvalidInventory(
                "invalid toolVersions entry",
            ));
        }
        if self.containment.version.trim().is_empty()
            || self.containment.version.chars().count() > 128
            || self.containment.version.chars().any(char::is_control)
            || self.containment.max_safe_slots != 1
        {
            return Err(NodeStateError::InvalidInventory(
                "containment must identify the current one-slot backend",
            ));
        }
        self.containment.hostile_isolation.validate()?;
        Ok(())
    }
}

/// Dynamic portion of a GPU report. Modern workers join by `stableId`; legacy
/// reports without stable IDs retain index-order compatibility.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GpuTelemetry {
    pub available_vram_mib: u64,
    pub allocatable: bool,
    #[serde(default)]
    pub stable_id: Option<String>,
    #[serde(default)]
    pub utilization_percent: Option<u8>,
    #[serde(default)]
    pub temperature_c: Option<i16>,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PowerSource {
    Ac,
    Battery,
    #[default]
    Unknown,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BatteryTelemetry {
    #[serde(default)]
    pub charge_percent: Option<u8>,
    #[serde(default)]
    pub charging: Option<bool>,
}

/// Worker-observed dynamic capacity and load. `observedAt` is useful evidence,
/// but it is not trusted for liveness; the controller records a separate
/// `receivedAt` in [`NodeMergeView`].
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NodeTelemetry {
    pub status: NodeStatus,
    pub available_cpu_cores: u32,
    pub available_memory_mib: u64,
    pub available_disk_mib: u64,
    pub gpus: Vec<GpuTelemetry>,
    pub load: NodeLoad,
    pub cached_sources: BTreeSet<String>,
    pub observed_at: DateTime<Utc>,
    /// Monotonically increasing daemon generation allocated from protected
    /// worker state before a managed daemon starts. Generation zero is
    /// reserved for pre-generation workers and local compatibility probes.
    #[serde(default)]
    pub boot_generation: u64,
    /// Stable for one daemon process lifetime. Nil is accepted only as a
    /// legacy decode value; authenticated NodeReport validation rejects it.
    #[serde(default)]
    pub boot_id: Uuid,
    #[serde(default)]
    pub sequence: u64,
    #[serde(default)]
    pub cpu_ewma_percent: u8,
    #[serde(default)]
    pub active_run_ids: Vec<Uuid>,
    #[serde(default)]
    pub power_source: PowerSource,
    #[serde(default)]
    pub battery: Option<BatteryTelemetry>,
    #[serde(default)]
    pub temperature_c: Option<i16>,
}

impl NodeTelemetry {
    pub fn from_node(node: &Node, fallback_observed_at: DateTime<Utc>) -> Self {
        Self {
            status: node.status,
            available_cpu_cores: node.resources.available_cpu_cores,
            available_memory_mib: node.resources.available_memory_mib,
            available_disk_mib: node.resources.available_disk_mib,
            gpus: node
                .resources
                .gpus
                .iter()
                .map(|gpu| GpuTelemetry {
                    available_vram_mib: gpu.available_vram_mib,
                    allocatable: gpu.allocatable,
                    stable_id: None,
                    utilization_percent: None,
                    temperature_c: None,
                })
                .collect(),
            load: node.load.clone(),
            cached_sources: node.cached_sources.clone(),
            observed_at: node.last_seen_at.unwrap_or(fallback_observed_at),
            boot_generation: 0,
            boot_id: Uuid::nil(),
            sequence: 0,
            cpu_ewma_percent: node.load.cpu_percent,
            active_run_ids: Vec::new(),
            power_source: PowerSource::Unknown,
            battery: None,
            temperature_c: None,
        }
    }

    pub fn validate(&self, inventory: &NodeInventory) -> Result<(), NodeStateError> {
        self.validate_shape()?;
        if self.available_cpu_cores > inventory.logical_cpu_cores
            || self.available_memory_mib > inventory.memory_mib
            || self.available_disk_mib > inventory.disk_mib
        {
            return Err(NodeStateError::InvalidTelemetry(
                "available capacity exceeds inventory total",
            ));
        }
        if self.gpus.len() != inventory.gpus.len()
            || inventory
                .gpus
                .iter()
                .enumerate()
                .any(|(index, inventory_gpu)| {
                    self.gpu_for_inventory(index, inventory_gpu)
                        .is_none_or(|telemetry| {
                            telemetry.available_vram_mib > inventory_gpu.total_vram_mib
                        })
                })
        {
            return Err(NodeStateError::InvalidTelemetry(
                "GPU telemetry does not match inventory",
            ));
        }
        Ok(())
    }

    fn gpu_for_inventory(&self, index: usize, inventory: &GpuInventory) -> Option<&GpuTelemetry> {
        inventory.stable_id.as_ref().map_or_else(
            || self.gpus.get(index),
            |stable_id| {
                self.gpus
                    .iter()
                    .find(|telemetry| telemetry.stable_id.as_ref() == Some(stable_id))
            },
        )
    }

    /// Validate dynamic fields that do not require a static inventory. The
    /// controller uses this when an authenticated report omits unchanged
    /// inventory and validates resource totals against its persisted copy.
    pub fn validate_shape(&self) -> Result<(), NodeStateError> {
        if self.load.cpu_percent > 100 || self.cpu_ewma_percent > 100 {
            return Err(NodeStateError::InvalidTelemetry(
                "CPU percentages must be in 0..=100",
            ));
        }
        if self
            .battery
            .as_ref()
            .and_then(|battery| battery.charge_percent)
            .is_some_and(|percent| percent > 100)
        {
            return Err(NodeStateError::InvalidTelemetry(
                "battery chargePercent must be in 0..=100",
            ));
        }
        if self.temperature_c.is_some_and(|temperature| {
            !(MIN_TEMPERATURE_C..=MAX_TEMPERATURE_C).contains(&temperature)
        }) {
            return Err(NodeStateError::InvalidTelemetry(
                "temperatureC is outside the supported range",
            ));
        }
        let mut active_runs = BTreeSet::new();
        if self
            .active_run_ids
            .iter()
            .any(|run_id| run_id.is_nil() || !active_runs.insert(*run_id))
        {
            return Err(NodeStateError::InvalidTelemetry(
                "activeRunIds must be non-nil and unique",
            ));
        }
        let mut stable_ids = BTreeSet::new();
        for gpu in &self.gpus {
            if gpu.utilization_percent.is_some_and(|percent| percent > 100) {
                return Err(NodeStateError::InvalidTelemetry(
                    "GPU utilizationPercent must be in 0..=100",
                ));
            }
            if gpu.temperature_c.is_some_and(|temperature| {
                !(MIN_TEMPERATURE_C..=MAX_TEMPERATURE_C).contains(&temperature)
            }) {
                return Err(NodeStateError::InvalidTelemetry(
                    "GPU temperatureC is outside the supported range",
                ));
            }
            if let Some(stable_id) = &gpu.stable_id {
                if stable_id.trim().is_empty()
                    || stable_id.chars().count() > 256
                    || stable_id.chars().any(char::is_control)
                    || !stable_ids.insert(stable_id)
                {
                    return Err(NodeStateError::InvalidTelemetry(
                        "GPU stableId must be non-empty and unique",
                    ));
                }
            }
        }
        Ok(())
    }
}

/// Controller-derived availability state. Only `Available` and `Degraded`
/// nodes are candidates for new work.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NodeAvailability {
    Available,
    Degraded,
    Draining,
    Disabled,
    Offline,
    Stale,
}

impl NodeAvailability {
    pub fn derive(
        config: &NodeConfig,
        telemetry: &NodeTelemetry,
        received_at: DateTime<Utc>,
        now: DateTime<Utc>,
        freshness_ttl: Duration,
    ) -> Self {
        if !config.enabled {
            return Self::Disabled;
        }
        if config.desired_state == NodeDesiredState::Draining {
            return Self::Draining;
        }
        let maximum_age =
            chrono::Duration::from_std(freshness_ttl).unwrap_or(chrono::Duration::MAX);
        if now.signed_duration_since(received_at) > maximum_age {
            return Self::Stale;
        }
        match telemetry.status {
            NodeStatus::Online => Self::Available,
            NodeStatus::Degraded => Self::Degraded,
            NodeStatus::Draining => Self::Draining,
            NodeStatus::Offline => Self::Offline,
        }
    }

    pub fn schedulable(self) -> bool {
        matches!(self, Self::Available | Self::Degraded)
    }
}

/// Strict split-state view plus controller receive time. This is the source
/// for a legacy/compatibility [`Node`] returned by the fleet API and consumed
/// by the current scheduler.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NodeMergeView {
    pub id: Uuid,
    pub config: NodeConfig,
    pub inventory: NodeInventory,
    pub telemetry: NodeTelemetry,
    pub received_at: DateTime<Utc>,
    pub availability: NodeAvailability,
}

impl NodeMergeView {
    pub fn merge(
        id: Uuid,
        config: NodeConfig,
        inventory: NodeInventory,
        telemetry: NodeTelemetry,
        received_at: DateTime<Utc>,
        now: DateTime<Utc>,
        freshness_ttl: Duration,
    ) -> Result<Self, NodeStateError> {
        if id.is_nil() {
            return Err(NodeStateError::NilNodeId);
        }
        config.validate()?;
        inventory.validate()?;
        telemetry.validate(&inventory)?;
        let availability =
            NodeAvailability::derive(&config, &telemetry, received_at, now, freshness_ttl);
        Ok(Self {
            id,
            config,
            inventory,
            telemetry,
            received_at,
            availability,
        })
    }

    pub fn to_node(&self) -> Result<Node, NodeStateError> {
        self.config.validate()?;
        self.inventory.validate()?;
        self.telemetry.validate(&self.inventory)?;
        let resources = NodeResources {
            logical_cpu_cores: self.inventory.logical_cpu_cores,
            available_cpu_cores: self.telemetry.available_cpu_cores,
            memory_mib: self.inventory.memory_mib,
            available_memory_mib: self.telemetry.available_memory_mib,
            disk_mib: self.inventory.disk_mib,
            available_disk_mib: self.telemetry.available_disk_mib,
            gpus: self
                .inventory
                .gpus
                .iter()
                .enumerate()
                .map(|(index, inventory)| {
                    let telemetry = self
                        .telemetry
                        .gpu_for_inventory(index, inventory)
                        .expect("validated GPU inventory/telemetry join");
                    GpuDevice {
                        vendor: inventory.vendor,
                        model: inventory.model.clone(),
                        total_vram_mib: inventory.total_vram_mib,
                        available_vram_mib: telemetry.available_vram_mib,
                        allocatable: telemetry.allocatable,
                    }
                })
                .collect(),
        };
        let status = match self.availability {
            NodeAvailability::Available => NodeStatus::Online,
            NodeAvailability::Degraded => NodeStatus::Degraded,
            NodeAvailability::Draining => NodeStatus::Draining,
            NodeAvailability::Disabled => self.telemetry.status,
            NodeAvailability::Offline | NodeAvailability::Stale => NodeStatus::Offline,
        };
        Ok(Node {
            id: self.id,
            name: self.config.name.clone(),
            enabled: self.config.enabled,
            transport: self.inventory.transport.clone(),
            os: self.inventory.os,
            arch: self.inventory.arch,
            status,
            capabilities: self.inventory.capabilities.clone(),
            resources,
            load: self.telemetry.load.clone(),
            priority: self.config.priority,
            labels: self.config.labels.clone(),
            cached_sources: self.telemetry.cached_sources.clone(),
            last_seen_at: Some(self.received_at),
        })
    }
}

#[derive(Clone, Debug, Error, Eq, PartialEq)]
pub enum NodeStateError {
    #[error("node id must not be nil")]
    NilNodeId,
    #[error("invalid node config field: {0}")]
    InvalidConfig(&'static str),
    #[error("invalid node inventory: {0}")]
    InvalidInventory(&'static str),
    #[error("invalid node telemetry: {0}")]
    InvalidTelemetry(&'static str),
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{CredentialRef, NodeTransport};

    fn node() -> Node {
        let mut node = Node::new(
            "worker",
            NodeTransport::Managed {
                endpoint: "https://controller.example.invalid:47832".to_owned(),
                credential_ref: CredentialRef::new("controller-db:managed-worker"),
            },
            OperatingSystem::Linux,
            Architecture::X86_64,
        );
        node.status = NodeStatus::Online;
        node.priority = 42;
        node.labels.insert("pool".to_owned(), "build".to_owned());
        node.resources = NodeResources {
            logical_cpu_cores: 12,
            available_cpu_cores: 8,
            memory_mib: 32_768,
            available_memory_mib: 24_000,
            disk_mib: 500_000,
            available_disk_mib: 400_000,
            gpus: vec![GpuDevice {
                vendor: GpuVendor::Nvidia,
                model: "fixture".to_owned(),
                total_vram_mib: 8_192,
                available_vram_mib: 6_144,
                allocatable: true,
            }],
        };
        node
    }

    #[test]
    fn split_contracts_are_strict_and_merge_to_legacy_node() {
        let node = node();
        let received_at = Utc::now();
        let view = NodeMergeView::merge(
            node.id,
            NodeConfig::from_node(&node),
            NodeInventory::from_node(&node),
            NodeTelemetry::from_node(&node, received_at),
            received_at,
            received_at,
            Duration::from_secs(120),
        )
        .unwrap();
        assert_eq!(view.availability, NodeAvailability::Available);
        let merged = view.to_node().unwrap();
        assert_eq!(merged.id, node.id);
        assert_eq!(merged.name, node.name);
        assert_eq!(merged.priority, node.priority);
        assert_eq!(merged.resources, node.resources);
        assert_eq!(merged.last_seen_at, Some(received_at));

        let mut config = serde_json::to_value(&view.config).unwrap();
        config["workerMayNotWriteThis"] = serde_json::json!(true);
        assert!(serde_json::from_value::<NodeConfig>(config).is_err());
        let mut telemetry = serde_json::to_value(&view.telemetry).unwrap();
        telemetry["unknown"] = serde_json::json!(true);
        assert!(serde_json::from_value::<NodeTelemetry>(telemetry).is_err());
    }

    #[test]
    fn controller_received_at_not_worker_observed_at_drives_freshness() {
        let node = node();
        let now = Utc::now();
        let mut telemetry = NodeTelemetry::from_node(&node, now);
        telemetry.observed_at = now - chrono::Duration::days(365);
        let fresh = NodeAvailability::derive(
            &NodeConfig::from_node(&node),
            &telemetry,
            now,
            now,
            Duration::from_secs(120),
        );
        assert_eq!(fresh, NodeAvailability::Available);
        let stale = NodeAvailability::derive(
            &NodeConfig::from_node(&node),
            &telemetry,
            now - chrono::Duration::seconds(121),
            now,
            Duration::from_secs(120),
        );
        assert_eq!(stale, NodeAvailability::Stale);
    }

    #[test]
    fn telemetry_cannot_exceed_static_inventory() {
        let node = node();
        let inventory = NodeInventory::from_node(&node);
        let mut telemetry = NodeTelemetry::from_node(&node, Utc::now());
        telemetry.available_memory_mib = inventory.memory_mib + 1;
        assert!(matches!(
            telemetry.validate(&inventory),
            Err(NodeStateError::InvalidTelemetry(_))
        ));
    }

    #[test]
    fn legacy_split_state_json_decodes_with_safe_defaults() {
        let node = node();
        let now = Utc::now();

        let mut config = serde_json::to_value(NodeConfig::from_node(&node)).unwrap();
        let config_object = config.as_object_mut().unwrap();
        config_object.remove("desiredState");
        config_object.remove("capacity");
        let config: NodeConfig = serde_json::from_value(config).unwrap();
        assert_eq!(config.desired_state, NodeDesiredState::Active);
        assert_eq!(config.capacity.max_concurrent_jobs, 1);

        let mut inventory = serde_json::to_value(NodeInventory::from_node(&node)).unwrap();
        let inventory_object = inventory.as_object_mut().unwrap();
        for field in [
            "cpuModel",
            "toolVersions",
            "workerVersion",
            "protocolVersion",
            "containment",
        ] {
            inventory_object.remove(field);
        }
        for gpu in inventory_object["gpus"].as_array_mut().unwrap() {
            let gpu = gpu.as_object_mut().unwrap();
            gpu.remove("stableId");
            gpu.remove("driverVersion");
        }
        let inventory: NodeInventory = serde_json::from_value(inventory).unwrap();
        assert_eq!(inventory.cpu_model, "unknown");
        assert_eq!(inventory.protocol_version, PROTOCOL_VERSION);
        assert_eq!(inventory.containment.max_safe_slots, 1);
        assert_eq!(
            inventory.containment.hostile_isolation,
            HostileIsolationInventory::default()
        );

        let mut telemetry = serde_json::to_value(NodeTelemetry::from_node(&node, now)).unwrap();
        let telemetry_object = telemetry.as_object_mut().unwrap();
        for field in [
            "bootId",
            "sequence",
            "cpuEwmaPercent",
            "activeRunIds",
            "powerSource",
            "battery",
            "temperatureC",
        ] {
            telemetry_object.remove(field);
        }
        for gpu in telemetry_object["gpus"].as_array_mut().unwrap() {
            let gpu = gpu.as_object_mut().unwrap();
            gpu.remove("stableId");
            gpu.remove("utilizationPercent");
            gpu.remove("temperatureC");
        }
        let telemetry: NodeTelemetry = serde_json::from_value(telemetry).unwrap();
        assert_eq!(telemetry.boot_generation, 0);
        assert!(telemetry.boot_id.is_nil());
        assert_eq!(telemetry.sequence, 0);
        assert_eq!(telemetry.power_source, PowerSource::Unknown);
    }

    #[test]
    fn hostile_isolation_capability_is_strict_and_secret_free() {
        let mut inventory = NodeInventory::from_node(&node());
        inventory.containment.hostile_isolation = HostileIsolationInventory {
            opt_in: true,
            ready: true,
            backend: HostileIsolationBackend::LinuxCgroupV2DedicatedIdentity,
            dedicated_identity: true,
            external_reconciliation: true,
            protected_guard_state: true,
            worker_state_isolated: true,
            reason_code: None,
        };
        inventory.validate().unwrap();
        let json = serde_json::to_string(&inventory.containment.hostile_isolation).unwrap();
        for forbidden in ["uid", "gid", "sid", "path", "password", "token", "secret"] {
            assert!(
                !json.to_ascii_lowercase().contains(forbidden),
                "hostile capability leaked implementation detail `{forbidden}`: {json}"
            );
        }

        inventory
            .containment
            .hostile_isolation
            .worker_state_isolated = false;
        assert!(matches!(
            inventory.validate(),
            Err(NodeStateError::InvalidInventory(
                "ready hostile isolation is missing a required protection"
            ))
        ));

        inventory.containment.hostile_isolation = HostileIsolationInventory {
            opt_in: true,
            ready: false,
            backend: HostileIsolationBackend::MacosExternalReconciliation,
            dedicated_identity: true,
            external_reconciliation: true,
            protected_guard_state: true,
            worker_state_isolated: true,
            reason_code: Some("containment_backend_unavailable".to_owned()),
        };
        inventory.validate().unwrap();
    }

    #[test]
    fn legacy_containment_without_hostile_inventory_decodes_fail_closed() {
        let mut encoded = serde_json::to_value(NodeInventory::from_node(&node())).unwrap();
        encoded["containment"]
            .as_object_mut()
            .unwrap()
            .remove("hostileIsolation");

        let decoded: NodeInventory = serde_json::from_value(encoded).unwrap();
        assert_eq!(
            decoded.containment.hostile_isolation,
            HostileIsolationInventory::default()
        );
        decoded.validate().unwrap();
    }

    #[test]
    fn typed_capacity_policy_round_trips_and_validates() {
        let mut config = NodeConfig::from_node(&node());
        config.desired_state = NodeDesiredState::Draining;
        config.capacity = CapacityPolicy {
            max_concurrent_jobs: 3,
            allocatable_cpu_cores: Some(8),
            allocatable_cpu_percent: Some(75),
            memory_limit_mib: Some(16_384),
            allowed_job_kinds: [JobKind::Build, JobKind::Test].into_iter().collect(),
            allow_on_battery: true,
            max_cpu_percent: Some(90),
            max_cpu_ewma_percent: Some(80),
            max_memory_percent: Some(85),
            max_temperature_c: Some(88),
        };
        config.validate().unwrap();
        let json = serde_json::to_string(&config).unwrap();
        let decoded: NodeConfig = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded, config);

        config.capacity.max_concurrent_jobs = 0;
        assert!(matches!(
            config.validate(),
            Err(NodeStateError::InvalidConfig("capacity.maxConcurrentJobs"))
        ));
    }

    #[test]
    fn gpu_telemetry_joins_static_inventory_by_stable_id_not_position() {
        let node = node();
        let mut inventory = NodeInventory::from_node(&node);
        let first = inventory.gpus.first_mut().unwrap();
        first.stable_id = Some("GPU-first".to_owned());
        inventory.gpus.push(GpuInventory {
            vendor: GpuVendor::Nvidia,
            model: "fixture-two".to_owned(),
            total_vram_mib: 4_096,
            stable_id: Some("GPU-second".to_owned()),
            driver_version: Some("555.42".to_owned()),
        });
        let mut telemetry = NodeTelemetry::from_node(&node, Utc::now());
        telemetry.gpus = vec![
            GpuTelemetry {
                available_vram_mib: 3_000,
                allocatable: true,
                stable_id: Some("GPU-second".to_owned()),
                utilization_percent: Some(10),
                temperature_c: Some(50),
            },
            GpuTelemetry {
                available_vram_mib: 6_000,
                allocatable: true,
                stable_id: Some("GPU-first".to_owned()),
                utilization_percent: Some(20),
                temperature_c: Some(55),
            },
        ];
        telemetry.validate(&inventory).unwrap();
        assert_eq!(
            telemetry
                .gpu_for_inventory(0, &inventory.gpus[0])
                .unwrap()
                .available_vram_mib,
            6_000
        );
    }
}
