//! Strict, portable placement-plan evidence shared by controllers and clients.
//!
//! A binding is the immutable scheduling decision that authorized submission of
//! one canonical [`JobSpec`]. Runtime placement evidence may evolve as worker
//! telemetry is refreshed, so retry and smoke-test paths persist this document
//! rather than attempting to reconstruct the original plan later.

use std::collections::BTreeSet;

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Deserializer, Serialize};
use thiserror::Error;
use uuid::Uuid;

use crate::{
    canonical_job_digest, JobSpec, PlacementCandidateExplain, PlacementExplain, PlacementPolicy,
    PlacementRejection, RejectionCode, ScoreComponent,
};

/// Wire-level API identifier for immutable placement-plan evidence.
pub const PLACEMENT_PLAN_BINDING_API_VERSION: &str = "cyc.dev/placement-plan-binding/v1";

const MAX_CLOCK_SKEW: Duration = Duration::seconds(30);
const MAX_CANDIDATES: usize = 256;
const MAX_EVIDENCE_ITEMS: usize = 64;
const MAX_TEXT_BYTES: usize = 256;
const MAX_SAFE_JSON_I64: i64 = 9_007_199_254_740_991;

/// The selected node, score, and complete scheduler explanation for a plan.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PlacementPlanDecisionV1 {
    pub node_id: Uuid,
    pub score: i64,
    pub explanation: PlacementExplain,
}

/// Immutable evidence binding a canonical job to a scheduler decision.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PlacementPlanBindingV1 {
    pub api_version: String,
    pub plan_id: Uuid,
    pub job_id: Uuid,
    /// Lowercase, unprefixed SHA-256 from [`canonical_job_digest`].
    pub job_digest: String,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
    pub fleet_revision: i64,
    pub node_revision: i64,
    pub policy_revision: i64,
    pub decision: PlacementPlanDecisionV1,
}

/// Durable binding used to prove that a smoke retry observes the original run.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SmokeRunBindingV1 {
    pub plan: PlacementPlanBindingV1,
    pub run_id: Uuid,
}

/// Stable validation failures for placement evidence.
///
/// Variants intentionally carry no untrusted wire values, so callers can log
/// or return them without disclosing node names, digests, or job metadata.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum PlacementBindingError {
    #[error("unsupported placement binding API version")]
    UnsupportedApiVersion,
    #[error("placement plan ID is nil")]
    NilPlanId,
    #[error("placement job ID is nil")]
    NilJobId,
    #[error("placement decision node ID is nil")]
    NilDecisionNodeId,
    #[error("placement job digest is invalid")]
    InvalidJobDigest,
    #[error("fleet revision is negative")]
    NegativeFleetRevision,
    #[error("fleet revision exceeds the exact JSON integer range")]
    FleetRevisionExceedsSafeInteger,
    #[error("node revision is negative")]
    NegativeNodeRevision,
    #[error("node revision exceeds the exact JSON integer range")]
    NodeRevisionExceedsSafeInteger,
    #[error("policy revision is negative")]
    NegativePolicyRevision,
    #[error("policy revision exceeds the exact JSON integer range")]
    PolicyRevisionExceedsSafeInteger,
    #[error("placement decision score exceeds the exact JSON integer range")]
    DecisionScoreOutOfRange,
    #[error("placement candidate score exceeds the exact JSON integer range")]
    CandidateScoreOutOfRange,
    #[error("placement score component value exceeds the exact JSON integer range")]
    ScoreComponentValueOutOfRange,
    #[error("placement plan time range is invalid")]
    InvalidTimeRange,
    #[error("placement plan creation time is too far in the future")]
    CreatedTooFarInFuture,
    #[error("placement plan has expired")]
    Expired,
    #[error("expected job is invalid")]
    ExpectedJobInvalid,
    #[error("placement job ID does not match expected job")]
    ExpectedJobIdMismatch,
    #[error("placement job digest does not match expected job")]
    ExpectedJobDigestMismatch,
    #[error("placement policy does not match expected job")]
    ExpectedPolicyMismatch,
    #[error("placement node does not match the expected preferred node")]
    ExpectedPreferredNodeMismatch,
    #[error("placement explanation selected node does not match")]
    ExplanationSelectedNodeMismatch,
    #[error("placement candidate count is outside the supported range")]
    CandidateCountOutOfRange,
    #[error("placement candidate node ID is nil")]
    CandidateNilNodeId,
    #[error("placement candidate node name is invalid")]
    CandidateNameInvalid,
    #[error("placement candidate node ID is duplicated")]
    DuplicateCandidateNodeId,
    #[error("eligible placement candidate is missing a score")]
    EligibleCandidateMissingScore,
    #[error("eligible placement candidate score components are invalid")]
    EligibleCandidateScoreComponentsOutOfRange,
    #[error("eligible placement candidate contains rejection evidence")]
    EligibleCandidateHasRejections,
    #[error("ineligible placement candidate contains a score")]
    IneligibleCandidateHasScore,
    #[error("ineligible placement candidate contains score components")]
    IneligibleCandidateHasScoreComponents,
    #[error("ineligible placement candidate rejections are invalid")]
    IneligibleCandidateRejectionsOutOfRange,
    #[error("placement score component key is invalid")]
    ScoreComponentKeyInvalid,
    #[error("placement score component detail is invalid")]
    ScoreComponentDetailInvalid,
    #[error("placement score component key is duplicated")]
    DuplicateScoreComponentKey,
    #[error("placement score component sum overflowed")]
    ScoreComponentSumOverflow,
    #[error("placement score component sum exceeds the exact JSON integer range")]
    ScoreComponentSumOutOfRange,
    #[error("placement score component sum does not match candidate score")]
    ScoreComponentSumMismatch,
    #[error("placement rejection detail is invalid")]
    RejectionDetailInvalid,
    #[error("placement rejection code is duplicated")]
    DuplicateRejectionCode,
    #[error("selected placement candidate count does not equal one")]
    SelectedCandidateCountMismatch,
    #[error("selected placement candidate is ineligible")]
    SelectedCandidateIneligible,
    #[error("selected placement candidate score does not match decision")]
    DecisionScoreMismatch,
    #[error("smoke run ID is nil")]
    NilRunId,
}

impl PlacementPlanBindingV1 {
    /// Validate structural evidence and, when supplied, bind it to a job and
    /// the caller's current UTC clock.
    pub fn validate(
        &self,
        expected_job: Option<&JobSpec>,
        now: Option<DateTime<Utc>>,
    ) -> Result<(), PlacementBindingError> {
        if self.api_version != PLACEMENT_PLAN_BINDING_API_VERSION {
            return Err(PlacementBindingError::UnsupportedApiVersion);
        }
        if self.plan_id.is_nil() {
            return Err(PlacementBindingError::NilPlanId);
        }
        if self.job_id.is_nil() {
            return Err(PlacementBindingError::NilJobId);
        }
        if self.decision.node_id.is_nil() {
            return Err(PlacementBindingError::NilDecisionNodeId);
        }
        if !is_lowercase_sha256(&self.job_digest) {
            return Err(PlacementBindingError::InvalidJobDigest);
        }
        if self.fleet_revision < 0 {
            return Err(PlacementBindingError::NegativeFleetRevision);
        }
        if self.fleet_revision > MAX_SAFE_JSON_I64 {
            return Err(PlacementBindingError::FleetRevisionExceedsSafeInteger);
        }
        if self.node_revision < 0 {
            return Err(PlacementBindingError::NegativeNodeRevision);
        }
        if self.node_revision > MAX_SAFE_JSON_I64 {
            return Err(PlacementBindingError::NodeRevisionExceedsSafeInteger);
        }
        if self.policy_revision < 0 {
            return Err(PlacementBindingError::NegativePolicyRevision);
        }
        if self.policy_revision > MAX_SAFE_JSON_I64 {
            return Err(PlacementBindingError::PolicyRevisionExceedsSafeInteger);
        }
        if !is_safe_json_i64(self.decision.score) {
            return Err(PlacementBindingError::DecisionScoreOutOfRange);
        }
        if self.created_at >= self.expires_at {
            return Err(PlacementBindingError::InvalidTimeRange);
        }
        if let Some(now) = now {
            if self.created_at > now + MAX_CLOCK_SKEW {
                return Err(PlacementBindingError::CreatedTooFarInFuture);
            }
            if self.expires_at <= now {
                return Err(PlacementBindingError::Expired);
            }
        }

        if let Some(job) = expected_job {
            job.validate()
                .map_err(|_| PlacementBindingError::ExpectedJobInvalid)?;
            if self.job_id != job.id {
                return Err(PlacementBindingError::ExpectedJobIdMismatch);
            }
            let digest =
                canonical_job_digest(job).map_err(|_| PlacementBindingError::ExpectedJobInvalid)?;
            if self.job_digest != digest {
                return Err(PlacementBindingError::ExpectedJobDigestMismatch);
            }
            if self.decision.explanation.policy != job.placement_policy {
                return Err(PlacementBindingError::ExpectedPolicyMismatch);
            }
            if job
                .preferred_node_id
                .is_some_and(|node_id| node_id != self.decision.node_id)
            {
                return Err(PlacementBindingError::ExpectedPreferredNodeMismatch);
            }
        }

        validate_explanation(&self.decision)
    }
}

impl SmokeRunBindingV1 {
    /// Validate both the immutable plan and the bound run identity.
    pub fn validate(
        &self,
        expected_job: Option<&JobSpec>,
        now: Option<DateTime<Utc>>,
    ) -> Result<(), PlacementBindingError> {
        self.plan.validate(expected_job, now)?;
        if self.run_id.is_nil() {
            return Err(PlacementBindingError::NilRunId);
        }
        Ok(())
    }
}

fn validate_explanation(decision: &PlacementPlanDecisionV1) -> Result<(), PlacementBindingError> {
    let explanation = &decision.explanation;
    if explanation.selected_node_id != Some(decision.node_id) {
        return Err(PlacementBindingError::ExplanationSelectedNodeMismatch);
    }
    if explanation.candidates.is_empty() || explanation.candidates.len() > MAX_CANDIDATES {
        return Err(PlacementBindingError::CandidateCountOutOfRange);
    }

    let mut node_ids = BTreeSet::new();
    let mut selected_candidate = None;
    for candidate in &explanation.candidates {
        if candidate.node_id.is_nil() {
            return Err(PlacementBindingError::CandidateNilNodeId);
        }
        if !valid_text(&candidate.node_name) {
            return Err(PlacementBindingError::CandidateNameInvalid);
        }
        if !node_ids.insert(candidate.node_id) {
            return Err(PlacementBindingError::DuplicateCandidateNodeId);
        }
        if candidate.eligible {
            validate_eligible_candidate(candidate)?;
        } else {
            validate_ineligible_candidate(candidate)?;
        }

        if candidate.node_id == decision.node_id && selected_candidate.replace(candidate).is_some()
        {
            return Err(PlacementBindingError::SelectedCandidateCountMismatch);
        }
    }

    let selected =
        selected_candidate.ok_or(PlacementBindingError::SelectedCandidateCountMismatch)?;
    if !selected.eligible {
        return Err(PlacementBindingError::SelectedCandidateIneligible);
    }
    if selected.score != Some(decision.score) {
        return Err(PlacementBindingError::DecisionScoreMismatch);
    }
    Ok(())
}

fn validate_eligible_candidate(
    candidate: &PlacementCandidateExplain,
) -> Result<(), PlacementBindingError> {
    let score = candidate
        .score
        .ok_or(PlacementBindingError::EligibleCandidateMissingScore)?;
    if !is_safe_json_i64(score) {
        return Err(PlacementBindingError::CandidateScoreOutOfRange);
    }
    if candidate.score_components.is_empty()
        || candidate.score_components.len() > MAX_EVIDENCE_ITEMS
    {
        return Err(PlacementBindingError::EligibleCandidateScoreComponentsOutOfRange);
    }
    if !candidate.rejection_reasons.is_empty() {
        return Err(PlacementBindingError::EligibleCandidateHasRejections);
    }

    let mut keys = BTreeSet::new();
    let mut sum = 0_i64;
    for component in &candidate.score_components {
        if !valid_text(&component.key) {
            return Err(PlacementBindingError::ScoreComponentKeyInvalid);
        }
        if !valid_text(&component.detail) {
            return Err(PlacementBindingError::ScoreComponentDetailInvalid);
        }
        if !keys.insert(component.key.as_str()) {
            return Err(PlacementBindingError::DuplicateScoreComponentKey);
        }
        if !is_safe_json_i64(component.value) {
            return Err(PlacementBindingError::ScoreComponentValueOutOfRange);
        }
        sum = sum
            .checked_add(component.value)
            .ok_or(PlacementBindingError::ScoreComponentSumOverflow)?;
        if !is_safe_json_i64(sum) {
            return Err(PlacementBindingError::ScoreComponentSumOutOfRange);
        }
    }
    if sum != score {
        return Err(PlacementBindingError::ScoreComponentSumMismatch);
    }
    Ok(())
}

fn validate_ineligible_candidate(
    candidate: &PlacementCandidateExplain,
) -> Result<(), PlacementBindingError> {
    if candidate.score.is_some() {
        return Err(PlacementBindingError::IneligibleCandidateHasScore);
    }
    if !candidate.score_components.is_empty() {
        return Err(PlacementBindingError::IneligibleCandidateHasScoreComponents);
    }
    if candidate.rejection_reasons.is_empty()
        || candidate.rejection_reasons.len() > MAX_EVIDENCE_ITEMS
    {
        return Err(PlacementBindingError::IneligibleCandidateRejectionsOutOfRange);
    }

    let mut codes = BTreeSet::new();
    for rejection in &candidate.rejection_reasons {
        if !valid_text(&rejection.detail) {
            return Err(PlacementBindingError::RejectionDetailInvalid);
        }
        if !codes.insert(rejection.code) {
            return Err(PlacementBindingError::DuplicateRejectionCode);
        }
    }
    Ok(())
}

fn valid_text(value: &str) -> bool {
    !value.trim().is_empty()
        && value.len() <= MAX_TEXT_BYTES
        && !value.chars().any(char::is_control)
}

fn is_lowercase_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn is_safe_json_i64(value: i64) -> bool {
    (-MAX_SAFE_JSON_I64..=MAX_SAFE_JSON_I64).contains(&value)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StrictPlacementPlanDecisionV1 {
    node_id: Uuid,
    score: i64,
    explanation: StrictPlacementExplain,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StrictPlacementExplain {
    policy: PlacementPolicy,
    selected_node_id: Option<Uuid>,
    candidates: Vec<StrictPlacementCandidateExplain>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StrictPlacementCandidateExplain {
    node_id: Uuid,
    node_name: String,
    eligible: bool,
    score: Option<i64>,
    #[serde(default)]
    score_components: Vec<StrictScoreComponent>,
    #[serde(default)]
    rejection_reasons: Vec<StrictPlacementRejection>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StrictScoreComponent {
    key: String,
    value: i64,
    detail: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StrictPlacementRejection {
    code: RejectionCode,
    detail: String,
}

impl<'de> Deserialize<'de> for PlacementPlanDecisionV1 {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let strict = StrictPlacementPlanDecisionV1::deserialize(deserializer)?;
        Ok(Self {
            node_id: strict.node_id,
            score: strict.score,
            explanation: PlacementExplain {
                policy: strict.explanation.policy,
                selected_node_id: strict.explanation.selected_node_id,
                candidates: strict
                    .explanation
                    .candidates
                    .into_iter()
                    .map(|candidate| PlacementCandidateExplain {
                        node_id: candidate.node_id,
                        node_name: candidate.node_name,
                        eligible: candidate.eligible,
                        score: candidate.score,
                        score_components: candidate
                            .score_components
                            .into_iter()
                            .map(|component| ScoreComponent {
                                key: component.key,
                                value: component.value,
                                detail: component.detail,
                            })
                            .collect(),
                        rejection_reasons: candidate
                            .rejection_reasons
                            .into_iter()
                            .map(|rejection| PlacementRejection {
                                code: rejection.code,
                                detail: rejection.detail,
                            })
                            .collect(),
                    })
                    .collect(),
            },
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{JobKind, JobStep, SourceSpec};

    fn sample_job() -> JobSpec {
        let mut job = JobSpec::new(
            JobKind::Build,
            SourceSpec::Git {
                repository: "https://example.invalid/repo.git".to_owned(),
                revision: "0123456789abcdef0123456789abcdef01234567".to_owned(),
            },
            vec![JobStep::new("build", "cargo build --locked")],
        );
        job.placement_policy = PlacementPolicy::Performance;
        job
    }

    fn sample_binding() -> (JobSpec, PlacementPlanBindingV1, DateTime<Utc>) {
        let job = sample_job();
        let now = DateTime::parse_from_rfc3339("2026-08-23T12:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        let selected_id = Uuid::new_v4();
        let binding = PlacementPlanBindingV1 {
            api_version: PLACEMENT_PLAN_BINDING_API_VERSION.to_owned(),
            plan_id: Uuid::new_v4(),
            job_id: job.id,
            job_digest: canonical_job_digest(&job).unwrap(),
            created_at: now - Duration::seconds(1),
            expires_at: now + Duration::seconds(59),
            fleet_revision: 7,
            node_revision: 3,
            policy_revision: 2,
            decision: PlacementPlanDecisionV1 {
                node_id: selected_id,
                score: 105,
                explanation: PlacementExplain {
                    policy: PlacementPolicy::Performance,
                    selected_node_id: Some(selected_id),
                    candidates: vec![
                        PlacementCandidateExplain {
                            node_id: selected_id,
                            node_name: "helio".to_owned(),
                            eligible: true,
                            score: Some(105),
                            score_components: vec![
                                ScoreComponent {
                                    key: "priority".to_owned(),
                                    value: 100,
                                    detail: "configured priority".to_owned(),
                                },
                                ScoreComponent {
                                    key: "capacity".to_owned(),
                                    value: 5,
                                    detail: "available capacity".to_owned(),
                                },
                            ],
                            rejection_reasons: Vec::new(),
                        },
                        PlacementCandidateExplain {
                            node_id: Uuid::new_v4(),
                            node_name: "p1".to_owned(),
                            eligible: false,
                            score: None,
                            score_components: Vec::new(),
                            rejection_reasons: vec![PlacementRejection {
                                code: RejectionCode::Offline,
                                detail: "heartbeat is stale".to_owned(),
                            }],
                        },
                    ],
                },
            },
        };
        (job, binding, now)
    }

    #[test]
    fn valid_binding_round_trips_and_binds_expected_job() {
        let (job, binding, now) = sample_binding();
        binding.validate(Some(&job), Some(now)).unwrap();

        let json = serde_json::to_string(&binding).unwrap();
        let decoded: PlacementPlanBindingV1 = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded, binding);
        decoded.validate(Some(&job), Some(now)).unwrap();

        let value = serde_json::to_value(decoded).unwrap();
        assert_eq!(value["apiVersion"], PLACEMENT_PLAN_BINDING_API_VERSION);
        assert!(value.get("planId").is_some());
        assert!(value.get("plan_id").is_none());
    }

    #[test]
    fn serde_rejects_unknown_fields_at_every_nested_level() {
        let (_, binding, _) = sample_binding();
        let original = serde_json::to_value(binding).unwrap();
        let paths = [
            Vec::<&str>::new(),
            vec!["decision"],
            vec!["decision", "explanation"],
            vec!["decision", "explanation", "candidates", "0"],
            vec![
                "decision",
                "explanation",
                "candidates",
                "0",
                "scoreComponents",
                "0",
            ],
            vec![
                "decision",
                "explanation",
                "candidates",
                "1",
                "rejectionReasons",
                "0",
            ],
        ];
        for path in paths {
            let mut value = original.clone();
            let mut cursor = &mut value;
            for segment in path {
                cursor = if let Ok(index) = segment.parse::<usize>() {
                    &mut cursor.as_array_mut().unwrap()[index]
                } else {
                    cursor.get_mut(segment).unwrap()
                };
            }
            cursor
                .as_object_mut()
                .unwrap()
                .insert("unexpected".to_owned(), serde_json::json!(true));
            assert!(serde_json::from_value::<PlacementPlanBindingV1>(value).is_err());
        }

        let smoke = SmokeRunBindingV1 {
            plan: sample_binding().1,
            run_id: Uuid::new_v4(),
        };
        let mut value = serde_json::to_value(smoke).unwrap();
        value["extra"] = serde_json::json!(1);
        assert!(serde_json::from_value::<SmokeRunBindingV1>(value).is_err());
    }

    #[test]
    fn validation_rejects_identity_digest_revision_and_time_tampering() {
        let (job, binding, now) = sample_binding();
        let cases = [
            (
                {
                    let mut value = binding.clone();
                    value.api_version = "cyc.dev/placement-plan-binding/v2".to_owned();
                    value
                },
                PlacementBindingError::UnsupportedApiVersion,
            ),
            (
                {
                    let mut value = binding.clone();
                    value.plan_id = Uuid::nil();
                    value
                },
                PlacementBindingError::NilPlanId,
            ),
            (
                {
                    let mut value = binding.clone();
                    value.job_id = Uuid::nil();
                    value
                },
                PlacementBindingError::NilJobId,
            ),
            (
                {
                    let mut value = binding.clone();
                    value.decision.node_id = Uuid::nil();
                    value
                },
                PlacementBindingError::NilDecisionNodeId,
            ),
            (
                {
                    let mut value = binding.clone();
                    value.job_digest = "A".repeat(64);
                    value
                },
                PlacementBindingError::InvalidJobDigest,
            ),
            (
                {
                    let mut value = binding.clone();
                    value.fleet_revision = -1;
                    value
                },
                PlacementBindingError::NegativeFleetRevision,
            ),
            (
                {
                    let mut value = binding.clone();
                    value.node_revision = -1;
                    value
                },
                PlacementBindingError::NegativeNodeRevision,
            ),
            (
                {
                    let mut value = binding.clone();
                    value.policy_revision = -1;
                    value
                },
                PlacementBindingError::NegativePolicyRevision,
            ),
            (
                {
                    let mut value = binding.clone();
                    value.created_at = value.expires_at;
                    value
                },
                PlacementBindingError::InvalidTimeRange,
            ),
            (
                {
                    let mut value = binding.clone();
                    value.created_at = now + Duration::seconds(31);
                    value.expires_at = now + Duration::seconds(60);
                    value
                },
                PlacementBindingError::CreatedTooFarInFuture,
            ),
            (
                {
                    let mut value = binding.clone();
                    value.expires_at = now;
                    value
                },
                PlacementBindingError::Expired,
            ),
        ];
        for (value, expected) in cases {
            assert_eq!(value.validate(Some(&job), Some(now)), Err(expected));
        }

        for digest in ["a".repeat(63), format!("sha256:{}", "a".repeat(64))] {
            let mut value = binding.clone();
            value.job_digest = digest;
            assert_eq!(
                value.validate(Some(&job), Some(now)),
                Err(PlacementBindingError::InvalidJobDigest)
            );
        }

        let mut exact_skew = binding.clone();
        exact_skew.created_at = now + Duration::seconds(30);
        exact_skew.expires_at = now + Duration::seconds(31);
        exact_skew.validate(Some(&job), Some(now)).unwrap();

        let mut unchecked_clock = binding;
        unchecked_clock.created_at = now + Duration::days(1);
        unchecked_clock.expires_at = now + Duration::days(2);
        unchecked_clock.validate(Some(&job), None).unwrap();
    }

    #[test]
    fn validation_binds_job_digest_policy_and_preferred_node() {
        let (job, binding, now) = sample_binding();

        let mut changed_id = job.clone();
        changed_id.id = Uuid::new_v4();
        assert_eq!(
            binding.validate(Some(&changed_id), Some(now)),
            Err(PlacementBindingError::ExpectedJobIdMismatch)
        );

        let mut changed_job = job.clone();
        changed_job.steps[0].script.push_str(" --release");
        assert_eq!(
            binding.validate(Some(&changed_job), Some(now)),
            Err(PlacementBindingError::ExpectedJobDigestMismatch)
        );

        let mut changed_policy = job.clone();
        changed_policy.placement_policy = PlacementPolicy::Balanced;
        assert_eq!(
            binding.validate(Some(&changed_policy), Some(now)),
            Err(PlacementBindingError::ExpectedJobDigestMismatch)
        );
        let mut policy_binding = binding.clone();
        policy_binding.job_digest = canonical_job_digest(&changed_policy).unwrap();
        assert_eq!(
            policy_binding.validate(Some(&changed_policy), Some(now)),
            Err(PlacementBindingError::ExpectedPolicyMismatch)
        );

        let mut preferred = job.clone();
        preferred.preferred_node_id = Some(Uuid::new_v4());
        let mut preferred_binding = binding.clone();
        preferred_binding.job_digest = canonical_job_digest(&preferred).unwrap();
        assert_eq!(
            preferred_binding.validate(Some(&preferred), Some(now)),
            Err(PlacementBindingError::ExpectedPreferredNodeMismatch)
        );

        let mut invalid = job;
        invalid.steps.clear();
        assert_eq!(
            binding.validate(Some(&invalid), Some(now)),
            Err(PlacementBindingError::ExpectedJobInvalid)
        );
    }

    #[test]
    fn explanation_rejects_duplicate_unbounded_and_control_text() {
        let (job, binding, now) = sample_binding();

        let mut duplicate_id = binding.clone();
        duplicate_id.decision.explanation.candidates[1].node_id =
            duplicate_id.decision.explanation.candidates[0].node_id;
        assert_eq!(
            duplicate_id.validate(Some(&job), Some(now)),
            Err(PlacementBindingError::DuplicateCandidateNodeId)
        );

        let mut duplicate_name_is_valid = binding.clone();
        duplicate_name_is_valid.decision.explanation.candidates[1].node_name =
            duplicate_name_is_valid.decision.explanation.candidates[0]
                .node_name
                .clone();
        duplicate_name_is_valid
            .validate(Some(&job), Some(now))
            .unwrap();

        let mut nil_id = binding.clone();
        nil_id.decision.explanation.candidates[1].node_id = Uuid::nil();
        assert_eq!(
            nil_id.validate(Some(&job), Some(now)),
            Err(PlacementBindingError::CandidateNilNodeId)
        );

        let mut selected_mismatch = binding.clone();
        selected_mismatch.decision.explanation.selected_node_id = Some(Uuid::new_v4());
        assert_eq!(
            selected_mismatch.validate(Some(&job), Some(now)),
            Err(PlacementBindingError::ExplanationSelectedNodeMismatch)
        );

        let mut exact_name = binding.clone();
        exact_name.decision.explanation.candidates[0].node_name = "n".repeat(MAX_TEXT_BYTES);
        exact_name.validate(Some(&job), Some(now)).unwrap();

        let mut unbounded = binding.clone();
        unbounded.decision.explanation.candidates[0].node_name = "n".repeat(257);
        assert_eq!(
            unbounded.validate(Some(&job), Some(now)),
            Err(PlacementBindingError::CandidateNameInvalid)
        );

        let mut empty = binding.clone();
        empty.decision.explanation.candidates[0].node_name = "   ".to_owned();
        assert_eq!(
            empty.validate(Some(&job), Some(now)),
            Err(PlacementBindingError::CandidateNameInvalid)
        );

        let mut node_control = binding.clone();
        node_control.decision.explanation.candidates[0].node_name = "helio\tspoof".to_owned();
        assert_eq!(
            node_control.validate(Some(&job), Some(now)),
            Err(PlacementBindingError::CandidateNameInvalid)
        );

        let mut control = binding;
        control.decision.explanation.candidates[0].score_components[0].detail =
            "priority\nspoof".to_owned();
        assert_eq!(
            control.validate(Some(&job), Some(now)),
            Err(PlacementBindingError::ScoreComponentDetailInvalid)
        );
    }

    #[test]
    fn explanation_rejects_eligibility_and_score_tampering() {
        let (job, binding, now) = sample_binding();

        let mut missing_score = binding.clone();
        missing_score.decision.explanation.candidates[0].score = None;
        assert_eq!(
            missing_score.validate(Some(&job), Some(now)),
            Err(PlacementBindingError::EligibleCandidateMissingScore)
        );

        let mut missing_components = binding.clone();
        missing_components.decision.explanation.candidates[0]
            .score_components
            .clear();
        assert_eq!(
            missing_components.validate(Some(&job), Some(now)),
            Err(PlacementBindingError::EligibleCandidateScoreComponentsOutOfRange)
        );

        let mut duplicate_component = binding.clone();
        duplicate_component.decision.explanation.candidates[0].score_components[1].key =
            "priority".to_owned();
        assert_eq!(
            duplicate_component.validate(Some(&job), Some(now)),
            Err(PlacementBindingError::DuplicateScoreComponentKey)
        );

        let mut invalid_component_key = binding.clone();
        invalid_component_key.decision.explanation.candidates[0].score_components[0].key =
            "   ".to_owned();
        assert_eq!(
            invalid_component_key.validate(Some(&job), Some(now)),
            Err(PlacementBindingError::ScoreComponentKeyInvalid)
        );

        let mut invalid_component_detail = binding.clone();
        invalid_component_detail.decision.explanation.candidates[0].score_components[0].detail =
            "d".repeat(MAX_TEXT_BYTES + 1);
        assert_eq!(
            invalid_component_detail.validate(Some(&job), Some(now)),
            Err(PlacementBindingError::ScoreComponentDetailInvalid)
        );

        let mut score_mismatch = binding.clone();
        score_mismatch.decision.explanation.candidates[0].score_components[1].value = 4;
        assert_eq!(
            score_mismatch.validate(Some(&job), Some(now)),
            Err(PlacementBindingError::ScoreComponentSumMismatch)
        );

        let mut eligible_rejection = binding.clone();
        eligible_rejection.decision.explanation.candidates[0]
            .rejection_reasons
            .push(PlacementRejection {
                code: RejectionCode::Offline,
                detail: "contradictory rejection".to_owned(),
            });
        assert_eq!(
            eligible_rejection.validate(Some(&job), Some(now)),
            Err(PlacementBindingError::EligibleCandidateHasRejections)
        );

        let mut ineligible_score = binding.clone();
        ineligible_score.decision.explanation.candidates[1].score = Some(0);
        assert_eq!(
            ineligible_score.validate(Some(&job), Some(now)),
            Err(PlacementBindingError::IneligibleCandidateHasScore)
        );

        let mut ineligible_component = binding.clone();
        ineligible_component.decision.explanation.candidates[1]
            .score_components
            .push(ScoreComponent {
                key: "invalid".to_owned(),
                value: 0,
                detail: "ineligible candidate".to_owned(),
            });
        assert_eq!(
            ineligible_component.validate(Some(&job), Some(now)),
            Err(PlacementBindingError::IneligibleCandidateHasScoreComponents)
        );

        let mut missing_rejection = binding.clone();
        missing_rejection.decision.explanation.candidates[1]
            .rejection_reasons
            .clear();
        assert_eq!(
            missing_rejection.validate(Some(&job), Some(now)),
            Err(PlacementBindingError::IneligibleCandidateRejectionsOutOfRange)
        );

        let mut duplicate_rejection = binding.clone();
        duplicate_rejection.decision.explanation.candidates[1]
            .rejection_reasons
            .push(PlacementRejection {
                code: RejectionCode::Offline,
                detail: "still offline".to_owned(),
            });
        assert_eq!(
            duplicate_rejection.validate(Some(&job), Some(now)),
            Err(PlacementBindingError::DuplicateRejectionCode)
        );

        let mut rejection_detail = binding.clone();
        rejection_detail.decision.explanation.candidates[1].rejection_reasons[0].detail =
            "r".repeat(MAX_TEXT_BYTES + 1);
        assert_eq!(
            rejection_detail.validate(Some(&job), Some(now)),
            Err(PlacementBindingError::RejectionDetailInvalid)
        );

        let mut decision_score = binding.clone();
        decision_score.decision.score += 1;
        assert_eq!(
            decision_score.validate(Some(&job), Some(now)),
            Err(PlacementBindingError::DecisionScoreMismatch)
        );

        let mut selected_ineligible = binding;
        selected_ineligible.decision.node_id =
            selected_ineligible.decision.explanation.candidates[1].node_id;
        selected_ineligible.decision.explanation.selected_node_id =
            Some(selected_ineligible.decision.node_id);
        assert_eq!(
            selected_ineligible.validate(Some(&job), Some(now)),
            Err(PlacementBindingError::SelectedCandidateIneligible)
        );
    }

    #[test]
    fn exact_candidate_and_evidence_bounds_are_enforced() {
        let (job, binding, now) = sample_binding();

        let mut no_candidates = binding.clone();
        no_candidates.decision.explanation.candidates.clear();
        assert_eq!(
            no_candidates.validate(Some(&job), Some(now)),
            Err(PlacementBindingError::CandidateCountOutOfRange)
        );

        let mut bounded_candidates = binding.clone();
        let template = bounded_candidates.decision.explanation.candidates[1].clone();
        while bounded_candidates.decision.explanation.candidates.len() < MAX_CANDIDATES {
            let mut candidate = template.clone();
            candidate.node_id = Uuid::new_v4();
            candidate.node_name = format!("node-{}", candidate.node_id);
            bounded_candidates
                .decision
                .explanation
                .candidates
                .push(candidate);
        }
        bounded_candidates.validate(Some(&job), Some(now)).unwrap();

        let mut too_many_candidates = bounded_candidates;
        let mut candidate = template.clone();
        candidate.node_id = Uuid::new_v4();
        candidate.node_name = "one-too-many".to_owned();
        too_many_candidates
            .decision
            .explanation
            .candidates
            .push(candidate);
        assert_eq!(
            too_many_candidates.validate(Some(&job), Some(now)),
            Err(PlacementBindingError::CandidateCountOutOfRange)
        );

        let mut bounded_components = binding;
        bounded_components.decision.score = 0;
        let selected = &mut bounded_components.decision.explanation.candidates[0];
        selected.score = Some(0);
        selected.score_components = (0..MAX_EVIDENCE_ITEMS)
            .map(|index| ScoreComponent {
                key: format!("component-{index}"),
                value: 0,
                detail: "bounded evidence".to_owned(),
            })
            .collect();
        bounded_components.validate(Some(&job), Some(now)).unwrap();

        let mut too_many_rejections = bounded_components.clone();
        let ineligible = &mut too_many_rejections.decision.explanation.candidates[1];
        ineligible.rejection_reasons = (0..=MAX_EVIDENCE_ITEMS)
            .map(|_| PlacementRejection {
                code: RejectionCode::Offline,
                detail: "bounded rejection".to_owned(),
            })
            .collect();
        assert_eq!(
            too_many_rejections.validate(Some(&job), Some(now)),
            Err(PlacementBindingError::IneligibleCandidateRejectionsOutOfRange)
        );

        let mut too_many_components = bounded_components;
        too_many_components.decision.explanation.candidates[0]
            .score_components
            .push(ScoreComponent {
                key: "one-too-many".to_owned(),
                value: 0,
                detail: "bounded evidence".to_owned(),
            });
        assert_eq!(
            too_many_components.validate(Some(&job), Some(now)),
            Err(PlacementBindingError::EligibleCandidateScoreComponentsOutOfRange)
        );
    }

    #[test]
    fn exact_json_integer_bounds_are_accepted_and_plus_one_is_rejected() {
        let (job, binding, now) = sample_binding();

        let mut exact = binding.clone();
        exact.fleet_revision = MAX_SAFE_JSON_I64;
        exact.node_revision = MAX_SAFE_JSON_I64;
        exact.policy_revision = MAX_SAFE_JSON_I64;
        exact.decision.score = MAX_SAFE_JSON_I64;
        exact.decision.explanation.candidates[0].score = Some(MAX_SAFE_JSON_I64);
        exact.decision.explanation.candidates[0].score_components = vec![ScoreComponent {
            key: "maximum".to_owned(),
            value: MAX_SAFE_JSON_I64,
            detail: "exact JSON integer boundary".to_owned(),
        }];
        exact.validate(Some(&job), Some(now)).unwrap();

        exact.decision.score = -MAX_SAFE_JSON_I64;
        exact.decision.explanation.candidates[0].score = Some(-MAX_SAFE_JSON_I64);
        exact.decision.explanation.candidates[0].score_components[0].value = -MAX_SAFE_JSON_I64;
        exact.validate(Some(&job), Some(now)).unwrap();

        let revision_cases = [
            (
                {
                    let mut value = binding.clone();
                    value.fleet_revision = MAX_SAFE_JSON_I64 + 1;
                    value
                },
                PlacementBindingError::FleetRevisionExceedsSafeInteger,
            ),
            (
                {
                    let mut value = binding.clone();
                    value.node_revision = MAX_SAFE_JSON_I64 + 1;
                    value
                },
                PlacementBindingError::NodeRevisionExceedsSafeInteger,
            ),
            (
                {
                    let mut value = binding.clone();
                    value.policy_revision = MAX_SAFE_JSON_I64 + 1;
                    value
                },
                PlacementBindingError::PolicyRevisionExceedsSafeInteger,
            ),
        ];
        for (value, expected) in revision_cases {
            assert_eq!(value.validate(Some(&job), Some(now)), Err(expected));
        }

        let mut decision = binding.clone();
        decision.decision.score = MAX_SAFE_JSON_I64 + 1;
        assert_eq!(
            decision.validate(Some(&job), Some(now)),
            Err(PlacementBindingError::DecisionScoreOutOfRange)
        );

        decision.decision.score = -MAX_SAFE_JSON_I64 - 1;
        assert_eq!(
            decision.validate(Some(&job), Some(now)),
            Err(PlacementBindingError::DecisionScoreOutOfRange)
        );

        let mut candidate = binding.clone();
        candidate.decision.explanation.candidates[0].score = Some(MAX_SAFE_JSON_I64 + 1);
        assert_eq!(
            candidate.validate(Some(&job), Some(now)),
            Err(PlacementBindingError::CandidateScoreOutOfRange)
        );

        let mut component = binding.clone();
        component.decision.explanation.candidates[0].score_components[0].value =
            MAX_SAFE_JSON_I64 + 1;
        assert_eq!(
            component.validate(Some(&job), Some(now)),
            Err(PlacementBindingError::ScoreComponentValueOutOfRange)
        );

        let mut sum = binding;
        sum.decision.score = MAX_SAFE_JSON_I64;
        sum.decision.explanation.candidates[0].score = Some(MAX_SAFE_JSON_I64);
        sum.decision.explanation.candidates[0].score_components = vec![
            ScoreComponent {
                key: "maximum".to_owned(),
                value: MAX_SAFE_JSON_I64,
                detail: "maximum exact value".to_owned(),
            },
            ScoreComponent {
                key: "one".to_owned(),
                value: 1,
                detail: "one more".to_owned(),
            },
        ];
        assert_eq!(
            sum.validate(Some(&job), Some(now)),
            Err(PlacementBindingError::ScoreComponentSumOutOfRange)
        );
    }

    #[test]
    fn smoke_binding_rejects_nil_run_id() {
        let (job, plan, now) = sample_binding();
        let mut binding = SmokeRunBindingV1 {
            plan,
            run_id: Uuid::new_v4(),
        };
        binding.validate(Some(&job), Some(now)).unwrap();
        binding.run_id = Uuid::nil();
        assert_eq!(
            binding.validate(Some(&job), Some(now)),
            Err(PlacementBindingError::NilRunId)
        );
    }
}
