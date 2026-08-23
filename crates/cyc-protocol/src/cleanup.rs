//! Authoritative post-terminal worker workspace cleanup receipts.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

use crate::JobState;

pub const CLEANUP_API_VERSION: &str = "cyc.dev/cleanup/v1";
pub const COMPLETION_SHA256_HEADER: &str = "x-cyc-completion-sha256";
pub const COMPLETION_ACKNOWLEDGED_AT_HEADER: &str = "x-cyc-completion-acknowledged-at";

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TerminalCompletionAckV1 {
    pub run_id: Uuid,
    pub lease_id: Uuid,
    pub completion_sha256: String,
    pub state_version: u64,
    pub final_state: JobState,
    pub acknowledged_at: DateTime<Utc>,
}

impl TerminalCompletionAckV1 {
    pub fn validate(&self) -> Result<(), CleanupValidationError> {
        if self.run_id.is_nil() || self.lease_id.is_nil() {
            return Err(CleanupValidationError::InvalidIdentifier);
        }
        if self.completion_sha256.len() != 64
            || !self
                .completion_sha256
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return Err(CleanupValidationError::InvalidCompletionDigest);
        }
        if !self.final_state.is_terminal() {
            return Err(CleanupValidationError::NonTerminalAck);
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JobRootCleanupOutcomeV1 {
    Removed,
    NotCreated,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CleanupReceiptV1 {
    pub api_version: String,
    pub run_id: Uuid,
    pub lease_id: Uuid,
    pub relative_root: String,
    pub outcome: JobRootCleanupOutcomeV1,
    /// True only when an existing root was actually removed. `not_created`
    /// proves absence separately and therefore keeps this field false.
    pub job_root_deleted: bool,
    pub observed_at: DateTime<Utc>,
    pub terminal_ack: TerminalCompletionAckV1,
}

impl CleanupReceiptV1 {
    pub fn validate(&self) -> Result<(), CleanupValidationError> {
        if self.api_version != CLEANUP_API_VERSION {
            return Err(CleanupValidationError::UnsupportedApiVersion);
        }
        self.terminal_ack.validate()?;
        if self.run_id != self.terminal_ack.run_id
            || self.lease_id != self.terminal_ack.lease_id
            || self.relative_root != format!("jobs/{}", self.run_id)
        {
            return Err(CleanupValidationError::BindingMismatch);
        }
        if self.job_root_deleted != matches!(self.outcome, JobRootCleanupOutcomeV1::Removed) {
            return Err(CleanupValidationError::OutcomeMismatch);
        }
        if self.observed_at < self.terminal_ack.acknowledged_at {
            return Err(CleanupValidationError::CleanupBeforeAck);
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CleanupStatusPhaseV1 {
    Pending,
    Removed,
    NotCreated,
}

/// Why the controller stopped holding the run's capacity reservation.  This
/// is deliberately separate from [`CleanupStatusPhaseV1`]: deadline recovery
/// releases scheduler capacity but does not claim that the workspace was
/// removed.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CleanupReservationReleaseReasonV1 {
    RemovedReceipt,
    DeadlineRecovery,
    LegacyMigration,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CleanupFailureCodeV1 {
    RemovedReceiptDeadlineExceeded,
    LegacyReleaseWithoutCleanupEvidence,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CleanupFailureV1 {
    pub code: CleanupFailureCodeV1,
    pub observed_at: DateTime<Utc>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CleanupStatusV1 {
    pub api_version: String,
    pub job_id: Uuid,
    pub run_id: Uuid,
    pub status: CleanupStatusPhaseV1,
    pub job_root_deleted: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub relative_root: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub observed_at: Option<DateTime<Utc>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub received_at: Option<DateTime<Utc>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub terminal_ack: Option<TerminalCompletionAckV1>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cleanup_deadline_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reservation_released_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub release_reason: Option<CleanupReservationReleaseReasonV1>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cleanup_failure: Option<CleanupFailureV1>,
}

#[derive(Clone, Debug, Error, Eq, PartialEq)]
pub enum CleanupValidationError {
    #[error("unsupported cleanup apiVersion")]
    UnsupportedApiVersion,
    #[error("cleanup identifier is invalid")]
    InvalidIdentifier,
    #[error("terminal completion digest is invalid")]
    InvalidCompletionDigest,
    #[error("completion acknowledgement is not terminal")]
    NonTerminalAck,
    #[error("cleanup receipt binding does not match the run")]
    BindingMismatch,
    #[error("cleanup outcome and deletion evidence disagree")]
    OutcomeMismatch,
    #[error("cleanup observation predates the terminal acknowledgement")]
    CleanupBeforeAck,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn receipt_binds_exact_job_root_and_terminal_ack() {
        let run_id = Uuid::new_v4();
        let lease_id = Uuid::new_v4();
        let acknowledged_at = Utc::now();
        let mut receipt = CleanupReceiptV1 {
            api_version: CLEANUP_API_VERSION.to_owned(),
            run_id,
            lease_id,
            relative_root: format!("jobs/{run_id}"),
            outcome: JobRootCleanupOutcomeV1::Removed,
            job_root_deleted: true,
            observed_at: acknowledged_at,
            terminal_ack: TerminalCompletionAckV1 {
                run_id,
                lease_id,
                completion_sha256: "a".repeat(64),
                state_version: 4,
                final_state: JobState::Succeeded,
                acknowledged_at,
            },
        };
        receipt.validate().unwrap();
        receipt.relative_root = "jobs/../escape".to_owned();
        assert_eq!(
            receipt.validate(),
            Err(CleanupValidationError::BindingMismatch)
        );
    }

    #[test]
    fn cleanup_status_diagnostics_are_bounded_and_backward_compatible() {
        let job_id = Uuid::new_v4();
        let run_id = Uuid::new_v4();
        let observed_at = Utc::now();
        let status = CleanupStatusV1 {
            api_version: CLEANUP_API_VERSION.to_owned(),
            job_id,
            run_id,
            status: CleanupStatusPhaseV1::Pending,
            job_root_deleted: false,
            relative_root: Some(format!("jobs/{run_id}")),
            observed_at: None,
            received_at: None,
            terminal_ack: None,
            cleanup_deadline_at: Some(observed_at),
            reservation_released_at: Some(observed_at),
            release_reason: Some(CleanupReservationReleaseReasonV1::DeadlineRecovery),
            cleanup_failure: Some(CleanupFailureV1 {
                code: CleanupFailureCodeV1::RemovedReceiptDeadlineExceeded,
                observed_at,
            }),
        };
        let document = serde_json::to_value(status).unwrap();
        assert_eq!(document["status"], "pending");
        assert_eq!(document["releaseReason"], "deadline_recovery");
        assert_eq!(
            document["cleanupFailure"]["code"],
            "removed_receipt_deadline_exceeded"
        );

        let legacy = json!({
            "apiVersion": CLEANUP_API_VERSION,
            "jobId": job_id,
            "runId": run_id,
            "status": "pending",
            "jobRootDeleted": false
        });
        let decoded: CleanupStatusV1 = serde_json::from_value(legacy).unwrap();
        assert!(decoded.cleanup_deadline_at.is_none());
        assert!(decoded.reservation_released_at.is_none());
        assert!(decoded.release_reason.is_none());
        assert!(decoded.cleanup_failure.is_none());

        let mut invalid = document;
        invalid["cleanupFailure"]["detail"] = json!("unbounded text is forbidden");
        assert!(serde_json::from_value::<CleanupStatusV1>(invalid).is_err());
    }
}
