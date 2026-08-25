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

/// Stable, non-secret failure categories safe to expose in polling responses.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PairingFailureCodeV1 {
    ProvisioningFailed,
    WorkerInstallFailed,
    WorkerPairingFailed,
    WorkerHealthCheckFailed,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PairingStatusErrorV1 {
    pub code: PairingFailureCodeV1,
    pub message: String,
    pub retryable: bool,
}

impl PairingStatusErrorV1 {
    pub fn validate(&self) -> Result<(), EnrollmentValidationError> {
        if self.message.trim().is_empty()
            || self.message.len() > 160
            || self.message.chars().any(char::is_control)
        {
            return Err(EnrollmentValidationError::InvalidField("error.message"));
        }
        Ok(())
    }
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
        if let Some(error) = &self.error {
            error.validate()?;
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
    use std::collections::BTreeSet;

    use super::*;

    const ENROLLMENT_SCHEMA: &str = include_str!("../../../schemas/enrollment.schema.json");

    fn bundle() -> EnrollmentBundleV1 {
        let created_at = Utc::now();
        EnrollmentBundleV1 {
            api_version: ENROLLMENT_API_VERSION.to_owned(),
            pairing_id: Uuid::new_v4(),
            controller_id: Uuid::new_v4(),
            intended_node_id: Uuid::new_v4(),
            worker_url: "https://controller.example.invalid:47832".to_owned(),
            certificate_pem:
                "-----BEGIN CERTIFICATE-----\nZml4dHVyZQ==\n-----END CERTIFICATE-----\n".to_owned(),
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

    fn status(phase: PairingPhaseV1) -> PairingStatusV1 {
        let created_at = Utc::now();
        let intended_node_id = Uuid::new_v4();
        PairingStatusV1 {
            api_version: ENROLLMENT_API_VERSION.to_owned(),
            pairing_id: Uuid::new_v4(),
            intended_node_id,
            node_id: matches!(phase, PairingPhaseV1::Consumed | PairingPhaseV1::Ready)
                .then_some(intended_node_id),
            phase,
            created_at,
            expires_at: created_at + chrono::Duration::minutes(10),
            consumed_at: matches!(phase, PairingPhaseV1::Consumed | PairingPhaseV1::Ready)
                .then_some(created_at),
            revoked_at: matches!(phase, PairingPhaseV1::Revoked).then_some(created_at),
            ready: matches!(phase, PairingPhaseV1::Ready),
            error: matches!(phase, PairingPhaseV1::Failed).then_some(PairingStatusErrorV1 {
                code: PairingFailureCodeV1::WorkerHealthCheckFailed,
                message: "Worker health check failed".to_owned(),
                retryable: true,
            }),
        }
    }

    #[test]
    fn ready_status_requires_the_intended_identity_and_consumption_time() {
        let mut status = status(PairingPhaseV1::Ready);
        status.validate().unwrap();
        status.node_id = Some(Uuid::new_v4());
        assert_eq!(
            status.validate(),
            Err(EnrollmentValidationError::InconsistentStatus)
        );
    }

    #[test]
    fn failure_codes_have_one_bounded_stable_wire_set() {
        let fixtures = [
            (
                PairingFailureCodeV1::ProvisioningFailed,
                "provisioning_failed",
            ),
            (
                PairingFailureCodeV1::WorkerInstallFailed,
                "worker_install_failed",
            ),
            (
                PairingFailureCodeV1::WorkerPairingFailed,
                "worker_pairing_failed",
            ),
            (
                PairingFailureCodeV1::WorkerHealthCheckFailed,
                "worker_health_check_failed",
            ),
        ];
        for (code, expected) in fixtures {
            assert_eq!(serde_json::to_value(code).unwrap(), expected);
            assert_eq!(
                serde_json::from_value::<PairingFailureCodeV1>(expected.into()).unwrap(),
                code
            );
        }
        assert!(
            serde_json::from_value::<PairingFailureCodeV1>("arbitrary_failure".into()).is_err()
        );
    }

    #[test]
    fn failed_status_requires_a_safe_bounded_error() {
        let mut failed = status(PairingPhaseV1::Failed);
        failed.validate().unwrap();
        let error = failed.error.as_mut().unwrap();

        error.message.clear();
        assert_eq!(
            failed.validate(),
            Err(EnrollmentValidationError::InvalidField("error.message"))
        );

        failed.error.as_mut().unwrap().message = " \t ".to_owned();
        assert_eq!(
            failed.validate(),
            Err(EnrollmentValidationError::InvalidField("error.message"))
        );

        failed.error.as_mut().unwrap().message = "x".repeat(161);
        assert_eq!(
            failed.validate(),
            Err(EnrollmentValidationError::InvalidField("error.message"))
        );

        failed.error.as_mut().unwrap().message = "é".repeat(81);
        assert_eq!(
            failed.validate(),
            Err(EnrollmentValidationError::InvalidField("error.message"))
        );

        failed.error.as_mut().unwrap().message = "retry\nlater".to_owned();
        assert_eq!(
            failed.validate(),
            Err(EnrollmentValidationError::InvalidField("error.message"))
        );

        failed.error.as_mut().unwrap().message = "x".repeat(160);
        failed.validate().unwrap();
    }

    #[test]
    fn phase_and_error_presence_are_consistent() {
        let mut failed = status(PairingPhaseV1::Failed);
        failed.error = None;
        assert_eq!(
            failed.validate(),
            Err(EnrollmentValidationError::InconsistentStatus)
        );

        let mut pending = status(PairingPhaseV1::Pending);
        pending.error = Some(PairingStatusErrorV1 {
            code: PairingFailureCodeV1::ProvisioningFailed,
            message: "Provisioning failed".to_owned(),
            retryable: false,
        });
        assert_eq!(
            pending.validate(),
            Err(EnrollmentValidationError::InconsistentStatus)
        );
    }

    fn schema() -> serde_json::Value {
        serde_json::from_str(ENROLLMENT_SCHEMA).expect("enrollment schema is valid JSON")
    }

    fn string_set(value: &serde_json::Value) -> BTreeSet<String> {
        value
            .as_array()
            .expect("schema string array")
            .iter()
            .map(|entry| entry.as_str().expect("schema string").to_owned())
            .collect()
    }

    fn assert_fixture_matches_object_contract(
        definitions: &serde_json::Map<String, serde_json::Value>,
        definition: &str,
        fixture: &serde_json::Value,
    ) {
        let contract = &definitions[definition];
        assert_eq!(contract["additionalProperties"], false, "{definition}");
        let properties = contract["properties"]
            .as_object()
            .expect("contract properties");
        let object = fixture.as_object().expect("wire fixture object");
        for key in object.keys() {
            assert!(
                properties.contains_key(key),
                "{definition} fixture has schema-unknown field {key}"
            );
        }
        if let Some(required) = contract.get("required") {
            for key in string_set(required) {
                assert!(
                    object.contains_key(&key),
                    "{definition} fixture is missing required field {key}"
                );
            }
        }
    }

    fn assert_no_secret_keys(value: &serde_json::Value) {
        const FORBIDDEN: &[&str] = &[
            "certificatepem",
            "credential",
            "pairingcode",
            "password",
            "privatekey",
            "secret",
            "token",
        ];
        match value {
            serde_json::Value::Object(object) => {
                for (key, nested) in object {
                    let normalized = key.to_ascii_lowercase();
                    assert!(
                        !FORBIDDEN.contains(&normalized.as_str()),
                        "secret-bearing field {key} leaked into status wire"
                    );
                    assert_no_secret_keys(nested);
                }
            }
            serde_json::Value::Array(array) => {
                for nested in array {
                    assert_no_secret_keys(nested);
                }
            }
            _ => {}
        }
    }

    #[test]
    fn enrollment_schema_tracks_strict_wire_contracts_and_limits() {
        let schema = schema();
        assert_eq!(
            schema["$schema"],
            "https://json-schema.org/draft/2020-12/schema"
        );
        assert_eq!(
            schema["oneOf"],
            serde_json::json!([
                { "$ref": "#/$defs/createPairingRequestV1" },
                { "$ref": "#/$defs/enrollmentBundleV1" },
                { "$ref": "#/$defs/pairingStatusV1" },
                { "$ref": "#/$defs/pairingStatusErrorV1" }
            ])
        );
        let definitions = schema["$defs"].as_object().expect("schema definitions");
        for contract in [
            "createPairingRequestV1",
            "enrollmentBundleV1",
            "pairingStatusV1",
            "pairingStatusErrorV1",
        ] {
            assert_eq!(
                definitions[contract]["additionalProperties"], false,
                "{contract} must remain closed"
            );
        }
        assert!(definitions["createPairingRequestV1"]
            .get("required")
            .is_none());
        assert_eq!(
            definitions["createPairingRequestV1"]["properties"]
                .as_object()
                .expect("create-pairing properties")
                .keys()
                .cloned()
                .collect::<BTreeSet<_>>(),
            BTreeSet::from(["intendedNodeId".to_owned()])
        );

        assert_eq!(definitions["uuid"]["format"], "uuid");
        assert_eq!(definitions["uuid"]["minLength"], 36);
        assert_eq!(definitions["uuid"]["maxLength"], 36);
        assert!(definitions["uuid"]["pattern"]
            .as_str()
            .unwrap()
            .starts_with("^[0-9a-f]{8}-"));
        assert_eq!(
            definitions["uuid"]["not"]["const"],
            "00000000-0000-0000-0000-000000000000"
        );
        assert_eq!(definitions["dateTime"]["format"], "date-time");
        assert_eq!(definitions["dateTime"]["minLength"], 20);
        assert_eq!(definitions["dateTime"]["maxLength"], 35);
        assert_eq!(definitions["workerUrl"]["format"], "uri");
        assert_eq!(definitions["workerUrl"]["minLength"], 9);
        assert_eq!(definitions["workerUrl"]["maxLength"], 2_048);
        assert!(definitions["workerUrl"]["pattern"]
            .as_str()
            .unwrap()
            .starts_with("^https://"));
        assert_eq!(definitions["certificatePem"]["minLength"], 58);
        assert_eq!(definitions["certificatePem"]["maxLength"], 128 * 1_024);
        assert!(definitions["certificatePem"]["pattern"]
            .as_str()
            .unwrap()
            .contains("BEGIN CERTIFICATE"));
        assert_eq!(definitions["pairingCode"]["minLength"], 32);
        assert_eq!(definitions["pairingCode"]["maxLength"], 512);
        assert_eq!(definitions["pairingCode"]["pattern"], "^[!-~]{32,512}$");

        let bundle = &definitions["enrollmentBundleV1"];
        assert_eq!(
            bundle["properties"]["apiVersion"]["const"],
            ENROLLMENT_API_VERSION
        );
        assert_eq!(
            string_set(&bundle["required"]),
            BTreeSet::from([
                "apiVersion".to_owned(),
                "certificatePem".to_owned(),
                "controllerId".to_owned(),
                "createdAt".to_owned(),
                "expiresAt".to_owned(),
                "intendedNodeId".to_owned(),
                "pairingCode".to_owned(),
                "pairingId".to_owned(),
                "workerUrl".to_owned(),
            ])
        );

        let error = &definitions["pairingStatusErrorV1"];
        assert_eq!(
            definitions["pairingFailureCodeV1"]["enum"],
            serde_json::json!([
                "provisioning_failed",
                "worker_install_failed",
                "worker_pairing_failed",
                "worker_health_check_failed"
            ])
        );
        assert_eq!(error["properties"]["message"]["minLength"], 1);
        assert_eq!(error["properties"]["message"]["maxLength"], 160);
        assert_eq!(error["properties"]["retryable"]["type"], "boolean");
        assert_eq!(
            string_set(&error["required"]),
            BTreeSet::from([
                "code".to_owned(),
                "message".to_owned(),
                "retryable".to_owned(),
            ])
        );

        let status = &definitions["pairingStatusV1"];
        assert_eq!(
            status["properties"]["apiVersion"]["const"],
            ENROLLMENT_API_VERSION
        );
        assert_eq!(
            string_set(&status["required"]),
            BTreeSet::from([
                "apiVersion".to_owned(),
                "createdAt".to_owned(),
                "expiresAt".to_owned(),
                "intendedNodeId".to_owned(),
                "pairingId".to_owned(),
                "phase".to_owned(),
                "ready".to_owned(),
            ])
        );
        assert_eq!(
            status["properties"]["error"]["$ref"],
            "#/$defs/pairingStatusErrorV1"
        );
        assert_eq!(
            definitions["pairingPhaseV1"]["enum"],
            serde_json::json!(["pending", "consumed", "ready", "expired", "revoked", "failed"])
        );
        let conditionals = status["allOf"].as_array().expect("status conditionals");
        let find_phase = |phase: &str| {
            conditionals
                .iter()
                .find(|conditional| conditional["if"]["properties"]["phase"]["const"] == phase)
                .unwrap_or_else(|| panic!("missing {phase} status conditional"))
        };
        let ready = find_phase("ready");
        assert_eq!(ready["then"]["properties"]["ready"]["const"], true);
        assert_eq!(ready["else"]["properties"]["ready"]["const"], false);
        assert_eq!(
            string_set(&ready["then"]["required"]),
            BTreeSet::from(["consumedAt".to_owned(), "nodeId".to_owned()])
        );
        let failed = find_phase("failed");
        assert_eq!(
            string_set(&failed["then"]["required"]),
            BTreeSet::from(["error".to_owned()])
        );
        assert_eq!(
            string_set(&failed["else"]["not"]["required"]),
            BTreeSet::from(["error".to_owned()])
        );
        assert_eq!(
            string_set(&find_phase("consumed")["then"]["required"]),
            BTreeSet::from(["consumedAt".to_owned(), "nodeId".to_owned()])
        );
        assert_eq!(
            string_set(&find_phase("revoked")["then"]["required"]),
            BTreeSet::from(["revokedAt".to_owned()])
        );
    }

    #[test]
    fn enrollment_schema_matches_representative_wire_and_status_is_secret_free() {
        let schema = schema();
        let definitions = schema["$defs"].as_object().expect("schema definitions");

        let request = CreatePairingRequestV1 {
            intended_node_id: Some(Uuid::new_v4()),
        };
        let request_wire = serde_json::to_value(request).unwrap();
        assert_fixture_matches_object_contract(
            definitions,
            "createPairingRequestV1",
            &request_wire,
        );

        let bundle = bundle();
        let bundle_wire = serde_json::to_value(&bundle).unwrap();
        assert_fixture_matches_object_contract(definitions, "enrollmentBundleV1", &bundle_wire);
        assert_eq!(bundle_wire["apiVersion"], ENROLLMENT_API_VERSION);

        let status = status(PairingPhaseV1::Failed);
        status.validate().unwrap();
        let status_wire = serde_json::to_value(&status).unwrap();
        assert_fixture_matches_object_contract(definitions, "pairingStatusV1", &status_wire);
        assert_fixture_matches_object_contract(
            definitions,
            "pairingStatusErrorV1",
            &status_wire["error"],
        );
        assert_eq!(
            status_wire["error"],
            serde_json::json!({
                "code": "worker_health_check_failed",
                "message": "Worker health check failed",
                "retryable": true
            })
        );
        assert_no_secret_keys(&status_wire);

        for definition in ["pairingStatusV1", "pairingStatusErrorV1"] {
            assert_no_secret_keys(&serde_json::Value::Object(
                definitions[definition]["properties"]
                    .as_object()
                    .expect("status properties")
                    .clone(),
            ));
        }
    }
}
