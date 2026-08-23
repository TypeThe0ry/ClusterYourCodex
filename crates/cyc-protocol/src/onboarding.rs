//! Controller-to-worker enrollment contracts.
//!
//! The enrollment bundle contains a one-time pairing code. It is intentionally
//! not `Debug` and must never be routed through generic diagnostic JSON values
//! or logging fields. Consumers should persist it only in a protected file and
//! delete that file after a successful pairing.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

/// Wire identifier for controller-created enrollment documents and status.
pub const ENROLLMENT_API_VERSION: &str = "cyc.dev/enrollment/v1";

/// Request a one-time enrollment for a controller-owned node identity.
///
/// Passing `intendedNodeId` rotates the credential of that logical node during
/// repair/re-pair. Omitting it asks the controller to allocate a new stable id.
#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CreatePairingRequestV1 {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub intended_node_id: Option<Uuid>,
}

impl CreatePairingRequestV1 {
    pub fn validate(&self) -> Result<(), EnrollmentValidationError> {
        if self.intended_node_id.is_some_and(|id| id.is_nil()) {
            return Err(EnrollmentValidationError::NilIdentifier("intendedNodeId"));
        }
        Ok(())
    }
}

/// Secret-bearing one-time worker enrollment document.
///
/// Deliberately not `Debug` or `Clone`: both traits make accidental secret
/// duplication/logging unnecessarily easy. Serialization exists only for the
/// protected controller-to-worker handoff.
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EnrollmentBundleV1 {
    pub api_version: String,
    pub pairing_id: Uuid,
    pub controller_id: Uuid,
    pub intended_node_id: Uuid,
    pub worker_url: String,
    pub certificate_pem: String,
    pub pairing_code: String,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}

impl EnrollmentBundleV1 {
    pub fn validate(&self) -> Result<(), EnrollmentValidationError> {
        if self.api_version != ENROLLMENT_API_VERSION {
            return Err(EnrollmentValidationError::UnsupportedApiVersion(
                self.api_version.clone(),
            ));
        }
        for (field, id) in [
            ("pairingId", self.pairing_id),
            ("controllerId", self.controller_id),
            ("intendedNodeId", self.intended_node_id),
        ] {
            if id.is_nil() {
                return Err(EnrollmentValidationError::NilIdentifier(field));
            }
        }
        if self.worker_url.trim().is_empty()
            || self.worker_url.len() > 2_048
            || self.worker_url.chars().any(char::is_control)
        {
            return Err(EnrollmentValidationError::InvalidField("workerUrl"));
        }
        if self.certificate_pem.trim().is_empty() || self.certificate_pem.len() > 128 * 1024 {
            return Err(EnrollmentValidationError::InvalidField("certificatePem"));
        }
        if !(32..=512).contains(&self.pairing_code.len())
            || self
                .pairing_code
                .bytes()
                .any(|byte| !byte.is_ascii_graphic() || byte.is_ascii_whitespace())
        {
            return Err(EnrollmentValidationError::InvalidField("pairingCode"));
        }
        if self.expires_at <= self.created_at {
            return Err(EnrollmentValidationError::InvalidExpiry);
        }
        Ok(())
    }
}

impl Drop for EnrollmentBundleV1 {
    fn drop(&mut self) {
        // Replacing ASCII pairing-code bytes with NUL preserves String's UTF-8
        // invariant while reducing the lifetime of plaintext secret material.
        unsafe { self.pairing_code.as_bytes_mut().fill(0) };
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PairingPhaseV1 {
    Pending,
    Consumed,
    Ready,
    Expired,
    Revoked,
    Failed,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PairingStatusErrorV1 {
    pub code: String,
    pub message: String,
}

/// Non-secret polling view used by GUI/CLI onboarding state machines.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PairingStatusV1 {
    pub api_version: String,
    pub pairing_id: Uuid,
    pub intended_node_id: Uuid,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub node_id: Option<Uuid>,
    pub phase: PairingPhaseV1,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub consumed_at: Option<DateTime<Utc>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub revoked_at: Option<DateTime<Utc>>,
    pub ready: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<PairingStatusErrorV1>,
}

impl PairingStatusV1 {
    pub fn validate(&self) -> Result<(), EnrollmentValidationError> {
        if self.api_version != ENROLLMENT_API_VERSION {
            return Err(EnrollmentValidationError::UnsupportedApiVersion(
                self.api_version.clone(),
            ));
        }
        for (field, id) in [
            ("pairingId", self.pairing_id),
            ("intendedNodeId", self.intended_node_id),
        ] {
            if id.is_nil() {
                return Err(EnrollmentValidationError::NilIdentifier(field));
            }
        }
        if self.node_id.is_some_and(|id| id.is_nil()) {
            return Err(EnrollmentValidationError::NilIdentifier("nodeId"));
        }
        if self.expires_at <= self.created_at {
            return Err(EnrollmentValidationError::InvalidExpiry);
        }
        if self.ready != matches!(self.phase, PairingPhaseV1::Ready) {
            return Err(EnrollmentValidationError::InconsistentStatus);
        }
        if self.ready && (self.node_id != Some(self.intended_node_id) || self.consumed_at.is_none())
        {
            return Err(EnrollmentValidationError::InconsistentStatus);
        }
        if self.error.is_some() != matches!(self.phase, PairingPhaseV1::Failed) {
            return Err(EnrollmentValidationError::InconsistentStatus);
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Error, Eq, PartialEq)]
pub enum EnrollmentValidationError {
    #[error("unsupported enrollment apiVersion `{0}`")]
    UnsupportedApiVersion(String),
    #[error("{0} must not be the nil UUID")]
    NilIdentifier(&'static str),
    #[error("enrollment field {0} is invalid")]
    InvalidField(&'static str),
    #[error("enrollment expiresAt must be later than createdAt")]
    InvalidExpiry,
    #[error("pairing status fields are inconsistent")]
    InconsistentStatus,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bundle() -> EnrollmentBundleV1 {
        let created_at = Utc::now();
        EnrollmentBundleV1 {
            api_version: ENROLLMENT_API_VERSION.to_owned(),
            pairing_id: Uuid::new_v4(),
            controller_id: Uuid::new_v4(),
            intended_node_id: Uuid::new_v4(),
            worker_url: "https://controller.example.invalid:47832".to_owned(),
            certificate_pem: "-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----\n"
                .to_owned(),
            pairing_code: "0123456789abcdef0123456789abcdef".to_owned(),
            created_at,
            expires_at: created_at + chrono::Duration::minutes(10),
        }
    }

    #[test]
    fn enrollment_bundle_is_versioned_strict_and_validated() {
        let bundle = bundle();
        bundle.validate().unwrap();
        let mut value = serde_json::to_value(&bundle).unwrap();
        assert_eq!(value["apiVersion"], ENROLLMENT_API_VERSION);
        assert_eq!(value["intendedNodeId"], bundle.intended_node_id.to_string());
        value["unexpected"] = serde_json::json!(true);
        assert!(serde_json::from_value::<EnrollmentBundleV1>(value).is_err());
    }

    #[test]
    fn enrollment_bundle_rejects_malformed_secret_and_expiry() {
        let mut bundle = bundle();
        bundle.pairing_code = "short".to_owned();
        assert_eq!(
            bundle.validate(),
            Err(EnrollmentValidationError::InvalidField("pairingCode"))
        );
        bundle.pairing_code = "0123456789abcdef0123456789abcdef".to_owned();
        bundle.expires_at = bundle.created_at;
        assert_eq!(
            bundle.validate(),
            Err(EnrollmentValidationError::InvalidExpiry)
        );
    }

    #[test]
    fn ready_status_requires_the_intended_identity_and_consumption_time() {
        let pairing_id = Uuid::new_v4();
        let node_id = Uuid::new_v4();
        let created_at = Utc::now();
        let mut status = PairingStatusV1 {
            api_version: ENROLLMENT_API_VERSION.to_owned(),
            pairing_id,
            intended_node_id: node_id,
            node_id: Some(node_id),
            phase: PairingPhaseV1::Ready,
            created_at,
            expires_at: created_at + chrono::Duration::minutes(10),
            consumed_at: Some(created_at),
            revoked_at: None,
            ready: true,
            error: None,
        };
        status.validate().unwrap();
        status.node_id = Some(Uuid::new_v4());
        assert_eq!(
            status.validate(),
            Err(EnrollmentValidationError::InconsistentStatus)
        );
    }
}
