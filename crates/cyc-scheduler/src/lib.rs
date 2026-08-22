//! Explainable, deterministic placement for ClusterYourCodex jobs.
//!
//! Scheduling is intentionally split into two stages: hard compatibility and
//! allocatability checks first, then a policy-specific score.  A caller gets
//! the complete explanation on both success and failure.

use std::cmp::Ordering;
use std::time::Duration;

use chrono::{DateTime, Utc};
use cyc_protocol::{
    GpuRequirement, JobKind, JobSpec, Node, NodeStatus, PlacementCandidateExplain,
    PlacementExplain, PlacementPolicy, PlacementRejection, RejectionCode, ScoreComponent,
    ValidationError,
};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

/// Three missed 30-second heartbeats is a conservative default for local
/// worker discovery without leaving vanished workers eligible indefinitely.
pub const DEFAULT_NODE_FRESHNESS_TTL: Duration = Duration::from_secs(90);

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SchedulerWeights {
    pub priority: i64,
    pub available_cpu_core: i64,
    pub available_memory_gib: i64,
    pub available_disk_10gib: i64,
    pub cpu_headroom_percent: i64,
    pub gpu_vram_gib: i64,
    pub queue_depth_penalty: i64,
    pub running_job_penalty: i64,
    pub source_cache_bonus: i64,
    pub preferred_node_bonus: i64,
    pub degraded_penalty: i64,
}

impl SchedulerWeights {
    pub const fn balanced() -> Self {
        Self {
            priority: 1,
            available_cpu_core: 12,
            available_memory_gib: 2,
            available_disk_10gib: 1,
            cpu_headroom_percent: 2,
            gpu_vram_gib: 4,
            queue_depth_penalty: 60,
            running_job_penalty: 25,
            source_cache_bonus: 180,
            preferred_node_bonus: 250,
            degraded_penalty: 300,
        }
    }

    pub const fn performance() -> Self {
        Self {
            priority: 1,
            available_cpu_core: 30,
            available_memory_gib: 5,
            available_disk_10gib: 1,
            cpu_headroom_percent: 3,
            gpu_vram_gib: 10,
            queue_depth_penalty: 45,
            running_job_penalty: 20,
            source_cache_bonus: 80,
            preferred_node_bonus: 180,
            degraded_penalty: 400,
        }
    }
}

impl Default for SchedulerWeights {
    fn default() -> Self {
        Self::balanced()
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Scheduler {
    balanced_weights: SchedulerWeights,
    performance_weights: SchedulerWeights,
    node_freshness_ttl: Duration,
}

impl Scheduler {
    pub fn new(balanced_weights: SchedulerWeights, performance_weights: SchedulerWeights) -> Self {
        Self {
            balanced_weights,
            performance_weights,
            node_freshness_ttl: DEFAULT_NODE_FRESHNESS_TTL,
        }
    }

    pub fn with_node_freshness_ttl(mut self, ttl: Duration) -> Self {
        self.node_freshness_ttl = ttl;
        self
    }

    pub fn node_freshness_ttl(&self) -> Duration {
        self.node_freshness_ttl
    }

    pub fn schedule(
        &self,
        job: &JobSpec,
        nodes: &[Node],
    ) -> Result<PlacementDecision, ScheduleError> {
        self.schedule_at(job, nodes, Utc::now())
    }

    /// Deterministic scheduling entry point for tests, replay, and persisted
    /// decision audits.
    pub fn schedule_at(
        &self,
        job: &JobSpec,
        nodes: &[Node],
        observed_at: DateTime<Utc>,
    ) -> Result<PlacementDecision, ScheduleError> {
        job.validate()?;

        let weights = match job.placement_policy {
            PlacementPolicy::Balanced | PlacementPolicy::Manual => &self.balanced_weights,
            PlacementPolicy::Performance => &self.performance_weights,
        };
        let mut candidates = nodes
            .iter()
            .map(|node| evaluate_node(job, node, weights, &observed_at, self.node_freshness_ttl))
            .collect::<Vec<_>>();

        let selected = candidates
            .iter()
            .filter(|candidate| candidate.eligible)
            .max_by(|left, right| compare_candidates(left, right))
            .map(|candidate| (candidate.node_id, candidate.score.unwrap_or_default()));

        candidates.sort_by(|left, right| {
            left.node_name
                .cmp(&right.node_name)
                .then_with(|| left.node_id.cmp(&right.node_id))
        });
        let explanation = PlacementExplain {
            policy: job.placement_policy,
            selected_node_id: selected.map(|(node_id, _)| node_id),
            candidates,
        };

        match selected {
            Some((node_id, score)) => Ok(PlacementDecision {
                node_id,
                score,
                explanation,
            }),
            None => Err(ScheduleError::NoEligibleNodes { explanation }),
        }
    }
}

impl Default for Scheduler {
    fn default() -> Self {
        Self::new(
            SchedulerWeights::balanced(),
            SchedulerWeights::performance(),
        )
    }
}

/// Convenience API for callers that do not customize scoring weights.
pub fn select_node(job: &JobSpec, nodes: &[Node]) -> Result<PlacementDecision, ScheduleError> {
    Scheduler::default().schedule(job, nodes)
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlacementDecision {
    pub node_id: Uuid,
    pub score: i64,
    pub explanation: PlacementExplain,
}

#[derive(Debug, Error)]
pub enum ScheduleError {
    #[error("invalid job specification: {0}")]
    InvalidJob(#[from] ValidationError),
    #[error("no eligible node satisfied the job requirements")]
    NoEligibleNodes { explanation: PlacementExplain },
}

impl ScheduleError {
    pub fn explanation(&self) -> Option<&PlacementExplain> {
        match self {
            Self::InvalidJob(_) => None,
            Self::NoEligibleNodes { explanation } => Some(explanation),
        }
    }
}

fn compare_candidates(
    left: &PlacementCandidateExplain,
    right: &PlacementCandidateExplain,
) -> Ordering {
    left.score
        .unwrap_or(i64::MIN)
        .cmp(&right.score.unwrap_or(i64::MIN))
        // A lower UUID wins a score tie, independent of input slice ordering.
        .then_with(|| right.node_id.cmp(&left.node_id))
}

fn evaluate_node(
    job: &JobSpec,
    node: &Node,
    weights: &SchedulerWeights,
    observed_at: &DateTime<Utc>,
    freshness_ttl: Duration,
) -> PlacementCandidateExplain {
    let rejection_reasons = hard_rejections(job, node, observed_at, freshness_ttl);
    if !rejection_reasons.is_empty() {
        return PlacementCandidateExplain {
            node_id: node.id,
            node_name: node.name.clone(),
            eligible: false,
            score: None,
            score_components: Vec::new(),
            rejection_reasons,
        };
    }

    let score_components = score_components(job, node, weights);
    let score = score_components.iter().fold(0_i64, |total, component| {
        total.saturating_add(component.value)
    });
    PlacementCandidateExplain {
        node_id: node.id,
        node_name: node.name.clone(),
        eligible: true,
        score: Some(score),
        score_components,
        rejection_reasons: Vec::new(),
    }
}

fn hard_rejections(
    job: &JobSpec,
    node: &Node,
    observed_at: &DateTime<Utc>,
    freshness_ttl: Duration,
) -> Vec<PlacementRejection> {
    let mut reasons = Vec::new();
    if !node.enabled {
        reject(&mut reasons, RejectionCode::Disabled, "node is disabled");
    }
    match node.status {
        NodeStatus::Offline => reject(&mut reasons, RejectionCode::Offline, "node is offline"),
        NodeStatus::Draining => reject(
            &mut reasons,
            RejectionCode::Draining,
            "node is draining and accepts no new jobs",
        ),
        NodeStatus::Online | NodeStatus::Degraded => {}
    }
    match node.last_seen_at.as_ref() {
        None => reject(
            &mut reasons,
            RejectionCode::StaleNode,
            "node has never reported a heartbeat",
        ),
        Some(last_seen_at) => {
            let age = observed_at.signed_duration_since(*last_seen_at);
            let maximum_age =
                chrono::Duration::from_std(freshness_ttl).unwrap_or(chrono::Duration::MAX);
            if age > maximum_age {
                reject(
                    &mut reasons,
                    RejectionCode::StaleNode,
                    format!(
                        "last heartbeat is {} seconds old; freshness TTL is {} seconds",
                        age.num_seconds(),
                        freshness_ttl.as_secs()
                    ),
                );
            }
        }
    }

    if job.placement_policy == PlacementPolicy::Manual {
        match job.preferred_node_id {
            None => reject(
                &mut reasons,
                RejectionCode::ManualNodeRequired,
                "manual placement requires preferredNodeId",
            ),
            Some(preferred) if preferred != node.id => reject(
                &mut reasons,
                RejectionCode::ManualNodeMismatch,
                format!("manual placement selected node {preferred}"),
            ),
            Some(_) => {}
        }
    }

    let requirements = &job.requirements;
    if let Some(required_os) = requirements.os {
        if node.os != required_os {
            reject(
                &mut reasons,
                RejectionCode::WrongOs,
                format!("requires {required_os:?}, node provides {:?}", node.os),
            );
        }
    }
    if let Some(required_arch) = requirements.arch {
        if node.arch != required_arch {
            reject(
                &mut reasons,
                RejectionCode::WrongArchitecture,
                format!("requires {required_arch:?}, node provides {:?}", node.arch),
            );
        }
    }
    for capability in requirements.capabilities.difference(&node.capabilities) {
        reject(
            &mut reasons,
            RejectionCode::MissingCapability,
            format!("missing capability `{capability}`"),
        );
    }
    if let Some(required) = requirements.min_cpu_cores {
        if node.resources.available_cpu_cores < required {
            reject(
                &mut reasons,
                RejectionCode::InsufficientCpu,
                format!(
                    "requires {required} available CPU cores, node has {}",
                    node.resources.available_cpu_cores
                ),
            );
        }
    }
    if let Some(required) = requirements.min_memory_mib {
        if node.resources.available_memory_mib < required {
            reject(
                &mut reasons,
                RejectionCode::InsufficientMemory,
                format!(
                    "requires {required} MiB available memory, node has {} MiB",
                    node.resources.available_memory_mib
                ),
            );
        }
    }
    if let Some(required) = requirements.min_disk_mib {
        if node.resources.available_disk_mib < required {
            reject(
                &mut reasons,
                RejectionCode::InsufficientDisk,
                format!(
                    "requires {required} MiB available disk, node has {} MiB",
                    node.resources.available_disk_mib
                ),
            );
        }
    }

    let implicit_gpu = (job.kind == JobKind::Gpu).then(GpuRequirement::default);
    if let Some(requirement) = requirements.gpu.as_ref().or(implicit_gpu.as_ref()) {
        gpu_rejections(node, requirement, &mut reasons);
    }
    reasons
}

fn gpu_rejections(
    node: &Node,
    requirement: &GpuRequirement,
    reasons: &mut Vec<PlacementRejection>,
) {
    if node.resources.gpus.is_empty() {
        reject(reasons, RejectionCode::GpuRequired, "node has no GPU");
        return;
    }

    let vendor_matches = node
        .resources
        .gpus
        .iter()
        .filter(|gpu| requirement.vendor.is_none_or(|vendor| gpu.vendor == vendor))
        .collect::<Vec<_>>();
    if vendor_matches.is_empty() {
        reject(
            reasons,
            RejectionCode::GpuVendorMismatch,
            format!("node has no {:?} GPU", requirement.vendor),
        );
        return;
    }

    let allocatable_matches = vendor_matches
        .iter()
        .copied()
        .filter(|gpu| gpu.allocatable)
        .collect::<Vec<_>>();
    if allocatable_matches.is_empty() {
        let (code, detail) = if requirement.exclusive {
            (
                RejectionCode::ExclusiveGpuUnavailable,
                "matching GPUs cannot accept an exclusive lease",
            )
        } else {
            (
                RejectionCode::GpuUnavailable,
                "matching GPUs are administratively unavailable",
            )
        };
        reject(reasons, code, detail);
        return;
    }

    let vram_matches = allocatable_matches
        .iter()
        .copied()
        .filter(|gpu| {
            requirement
                .min_vram_mib
                .is_none_or(|minimum| gpu.available_vram_mib >= minimum)
        })
        .collect::<Vec<_>>();
    if vram_matches.is_empty() {
        let available = allocatable_matches
            .iter()
            .map(|gpu| gpu.available_vram_mib)
            .max()
            .unwrap_or_default();
        reject(
            reasons,
            RejectionCode::InsufficientVram,
            format!(
                "requires {} MiB available VRAM, best matching GPU has {available} MiB",
                requirement.min_vram_mib.unwrap_or_default()
            ),
        );
    }

    // The scheduler only establishes that an exclusive lease can be attempted.
    // The controller must atomically reserve the selected device before dispatch.
}

fn reject(reasons: &mut Vec<PlacementRejection>, code: RejectionCode, detail: impl Into<String>) {
    reasons.push(PlacementRejection {
        code,
        detail: detail.into(),
    });
}

fn score_components(job: &JobSpec, node: &Node, weights: &SchedulerWeights) -> Vec<ScoreComponent> {
    let mut components = vec![
        component(
            "priority",
            i64::from(node.priority).saturating_mul(weights.priority),
            format!("configured priority {}", node.priority),
        ),
        component(
            "cpu_capacity",
            i64::from(node.resources.available_cpu_cores)
                .saturating_mul(weights.available_cpu_core),
            format!(
                "{} available logical CPU cores",
                node.resources.available_cpu_cores
            ),
        ),
        component(
            "memory_capacity",
            capped_units(node.resources.available_memory_mib, 1_024, 1_024)
                .saturating_mul(weights.available_memory_gib),
            format!(
                "{} MiB available memory",
                node.resources.available_memory_mib
            ),
        ),
        component(
            "disk_capacity",
            capped_units(node.resources.available_disk_mib, 10_240, 1_024)
                .saturating_mul(weights.available_disk_10gib),
            format!("{} MiB available disk", node.resources.available_disk_mib),
        ),
        component(
            "cpu_headroom",
            i64::from(100_u8.saturating_sub(node.load.cpu_percent.min(100)))
                .saturating_mul(weights.cpu_headroom_percent),
            format!("{}% observed CPU utilization", node.load.cpu_percent),
        ),
        component(
            "queue_penalty",
            -i64::from(node.load.queue_depth).saturating_mul(weights.queue_depth_penalty),
            format!("{} queued jobs", node.load.queue_depth),
        ),
        component(
            "running_job_penalty",
            -i64::from(node.load.running_jobs).saturating_mul(weights.running_job_penalty),
            format!("{} running jobs", node.load.running_jobs),
        ),
    ];

    if job.kind == JobKind::Gpu || job.requirements.gpu.is_some() {
        let available_vram = node
            .resources
            .gpus
            .iter()
            .filter(|gpu| {
                job.requirements
                    .gpu
                    .as_ref()
                    .and_then(|requirement| requirement.vendor)
                    .is_none_or(|vendor| gpu.vendor == vendor)
            })
            .map(|gpu| gpu.available_vram_mib)
            .max()
            .unwrap_or_default();
        components.push(component(
            "gpu_capacity",
            capped_units(available_vram, 1_024, 1_024).saturating_mul(weights.gpu_vram_gib),
            format!("{available_vram} MiB available VRAM"),
        ));
    }

    let source_key = job.source.cache_key();
    if node.cached_sources.contains(&source_key) {
        components.push(component(
            "source_cache",
            weights.source_cache_bonus,
            "exact source is already cached",
        ));
    }
    if job.preferred_node_id == Some(node.id) {
        components.push(component(
            "preferred_node",
            weights.preferred_node_bonus,
            "job prefers this node",
        ));
    }
    if node.status == NodeStatus::Degraded {
        components.push(component(
            "degraded_penalty",
            -weights.degraded_penalty,
            "node reports degraded health",
        ));
    }
    components
}

fn capped_units(value: u64, divisor: u64, cap: u64) -> i64 {
    i64::try_from((value / divisor).min(cap)).unwrap_or(i64::MAX)
}

fn component(key: &str, value: i64, detail: impl Into<String>) -> ScoreComponent {
    ScoreComponent {
        key: key.to_owned(),
        value,
        detail: detail.into(),
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use cyc_protocol::{
        Architecture, Capability, GpuDevice, GpuVendor, JobRequirements, JobStep, NodeResources,
        NodeTransport, OperatingSystem, SourceSpec,
    };

    use super::*;

    fn node(id: u128, name: &str, cpu: u32, memory_mib: u64) -> Node {
        let mut node = Node::new(
            name,
            NodeTransport::Local,
            OperatingSystem::Linux,
            Architecture::X86_64,
        );
        node.id = Uuid::from_u128(id);
        node.status = NodeStatus::Online;
        node.resources = NodeResources {
            logical_cpu_cores: cpu,
            available_cpu_cores: cpu,
            memory_mib,
            available_memory_mib: memory_mib,
            disk_mib: 500_000,
            available_disk_mib: 400_000,
            gpus: Vec::new(),
        };
        node
    }

    fn job() -> JobSpec {
        JobSpec::new(
            JobKind::Build,
            SourceSpec::Git {
                repository: "https://example.invalid/project.git".to_owned(),
                revision: "0123456789abcdef".to_owned(),
            },
            vec![JobStep::new("build", "cargo build --locked")],
        )
    }

    #[test]
    fn hard_constraints_reject_incompatible_nodes_with_all_reasons() {
        let mut target_job = job();
        target_job.requirements = JobRequirements {
            os: Some(OperatingSystem::Windows),
            capabilities: BTreeSet::from([Capability::from("msvc")]),
            min_cpu_cores: Some(16),
            min_memory_mib: Some(32_768),
            ..JobRequirements::default()
        };
        let linux = node(1, "linux", 8, 16_384);

        let error = select_node(&target_job, &[linux]).expect_err("must reject node");
        let candidate = &error.explanation().expect("explanation").candidates[0];
        let codes = candidate
            .rejection_reasons
            .iter()
            .map(|reason| reason.code)
            .collect::<BTreeSet<_>>();

        assert_eq!(candidate.score, None);
        assert!(codes.contains(&RejectionCode::WrongOs));
        assert!(codes.contains(&RejectionCode::MissingCapability));
        assert!(codes.contains(&RejectionCode::InsufficientCpu));
        assert!(codes.contains(&RejectionCode::InsufficientMemory));
    }

    #[test]
    fn performance_policy_prefers_more_compute() {
        let mut target_job = job();
        target_job.placement_policy = PlacementPolicy::Performance;
        let small = node(1, "small", 4, 8_192);
        let large = node(2, "large", 32, 65_536);

        let decision = select_node(&target_job, &[small, large]).expect("place job");
        assert_eq!(decision.node_id, Uuid::from_u128(2));
        assert!(decision.explanation.candidates.iter().all(|candidate| {
            candidate.eligible
                && candidate.score.is_some()
                && !candidate.score_components.is_empty()
        }));
    }

    #[test]
    fn balanced_policy_rewards_exact_source_cache() {
        let target_job = job();
        let uncached = node(1, "uncached", 8, 16_384);
        let mut cached = node(2, "cached", 8, 16_384);
        cached.cached_sources.insert(target_job.source.cache_key());

        let decision = select_node(&target_job, &[uncached, cached]).expect("place job");
        assert_eq!(decision.node_id, Uuid::from_u128(2));
        let selected = decision
            .explanation
            .candidates
            .iter()
            .find(|candidate| candidate.node_id == decision.node_id)
            .expect("selected explanation");
        assert!(selected
            .score_components
            .iter()
            .any(|component| component.key == "source_cache"));
    }

    #[test]
    fn manual_policy_only_accepts_the_selected_node() {
        let mut target_job = job();
        target_job.placement_policy = PlacementPolicy::Manual;
        target_job.preferred_node_id = Some(Uuid::from_u128(2));
        let first = node(1, "first", 64, 65_536);
        let second = node(2, "second", 4, 8_192);

        let decision = select_node(&target_job, &[first, second]).expect("place manually");
        assert_eq!(decision.node_id, Uuid::from_u128(2));
        let rejected = decision
            .explanation
            .candidates
            .iter()
            .find(|candidate| candidate.node_id == Uuid::from_u128(1))
            .expect("rejected candidate");
        assert_eq!(
            rejected.rejection_reasons[0].code,
            RejectionCode::ManualNodeMismatch
        );
    }

    #[test]
    fn gpu_jobs_require_an_allocatable_matching_gpu() {
        let mut target_job = job();
        target_job.kind = JobKind::Gpu;
        target_job.requirements.gpu = Some(GpuRequirement {
            vendor: Some(GpuVendor::Nvidia),
            min_vram_mib: Some(8_000),
            exclusive: true,
        });
        let mut worker = node(1, "gpu-worker", 16, 32_768);
        worker.resources.gpus.push(GpuDevice {
            vendor: GpuVendor::Nvidia,
            model: "Example GPU".to_owned(),
            total_vram_mib: 12_000,
            available_vram_mib: 12_000,
            allocatable: false,
        });

        let error = select_node(&target_job, &[worker]).expect_err("GPU is leased");
        assert_eq!(
            error.explanation().expect("explanation").candidates[0].rejection_reasons[0].code,
            RejectionCode::ExclusiveGpuUnavailable
        );
    }

    #[test]
    fn shared_gpu_jobs_also_reject_unallocatable_devices() {
        let mut target_job = job();
        target_job.kind = JobKind::Gpu;
        target_job.requirements.gpu = Some(GpuRequirement {
            vendor: Some(GpuVendor::Nvidia),
            min_vram_mib: Some(4_000),
            exclusive: false,
        });
        let mut worker = node(1, "shared-gpu-worker", 16, 32_768);
        worker.resources.gpus.push(GpuDevice {
            vendor: GpuVendor::Nvidia,
            model: "Unavailable GPU".to_owned(),
            total_vram_mib: 12_000,
            available_vram_mib: 12_000,
            allocatable: false,
        });

        let error = select_node(&target_job, &[worker]).expect_err("GPU is unavailable");
        assert_eq!(
            error.explanation().expect("explanation").candidates[0].rejection_reasons[0].code,
            RejectionCode::GpuUnavailable
        );
    }

    #[test]
    fn stale_or_never_seen_nodes_are_ineligible() {
        let target_job = job();
        let observed_at = Utc::now();
        let mut stale = node(1, "stale", 8, 16_384);
        stale.last_seen_at = Some(observed_at - chrono::Duration::seconds(91));
        let mut never_seen = node(2, "never-seen", 8, 16_384);
        never_seen.last_seen_at = None;

        let error = Scheduler::default()
            .schedule_at(&target_job, &[stale, never_seen], observed_at)
            .expect_err("all nodes are stale");
        let explanation = error.explanation().expect("explanation");
        assert!(explanation.candidates.iter().all(|candidate| {
            candidate
                .rejection_reasons
                .iter()
                .any(|reason| reason.code == RejectionCode::StaleNode)
        }));
    }

    #[test]
    fn freshness_ttl_is_configurable_and_inclusive() {
        let target_job = job();
        let observed_at = Utc::now();
        let mut worker = node(1, "worker", 8, 16_384);
        worker.last_seen_at = Some(observed_at - chrono::Duration::seconds(10));
        let scheduler = Scheduler::default().with_node_freshness_ttl(Duration::from_secs(10));

        let decision = scheduler
            .schedule_at(&target_job, &[worker], observed_at)
            .expect("heartbeat at the TTL boundary remains fresh");
        assert_eq!(decision.node_id, Uuid::from_u128(1));
        assert_eq!(scheduler.node_freshness_ttl(), Duration::from_secs(10));
    }

    #[test]
    fn score_ties_are_independent_of_input_order() {
        let target_job = job();
        let first = node(1, "one", 8, 16_384);
        let second = node(2, "two", 8, 16_384);

        let forward =
            select_node(&target_job, &[first.clone(), second.clone()]).expect("place forward");
        let reverse = select_node(&target_job, &[second, first]).expect("place reverse");

        assert_eq!(forward.node_id, Uuid::from_u128(1));
        assert_eq!(reverse.node_id, forward.node_id);
        assert_eq!(reverse.explanation, forward.explanation);
    }

    #[test]
    fn missing_manual_selection_is_explained_for_every_node() {
        let mut target_job = job();
        target_job.placement_policy = PlacementPolicy::Manual;
        let error = select_node(&target_job, &[node(1, "worker", 8, 16_384)])
            .expect_err("preferred node is required");

        assert_eq!(
            error.explanation().expect("explanation").candidates[0].rejection_reasons[0].code,
            RejectionCode::ManualNodeRequired
        );
    }
}
