use cyc_worker::config::{WorkerConfig, WORKER_CONFIG_VERSION};
use cyc_worker::migration::relocate_identity_documents;
use cyc_worker::runtime::relocate_pairing_ledger;
use serde_json::{json, Value};
use std::path::PathBuf;
use uuid::Uuid;

#[test]
fn migration_preserves_generation_bytes_without_incrementing() {
    let (config, ledger, old, new) = fixture();
    let boot =
        b"{\n  \"apiVersion\": \"cyc.dev/worker-boot-generation/v1\", \"generation\": 475\n}\n";
    let result = relocate_identity_documents(
        &serde_json::to_vec(&config).unwrap(),
        &serde_json::to_vec(&ledger).unwrap(),
        boot,
        &old,
        &new,
        &new.parent().unwrap().join("workspace"),
    )
    .unwrap();
    assert_eq!(result.boot_generation, 475);
    assert_eq!(result.boot_generation_json, boot);
    let converted: WorkerConfig = serde_json::from_slice(&result.config_json).unwrap();
    assert_eq!(converted.node_id, config.node_id);
    assert_eq!(converted.controller_id, config.controller_id);
    assert_eq!(result.credentials.len(), 2);
    let current = result
        .credentials
        .iter()
        .find(|entry| entry.required)
        .unwrap();
    assert_eq!(current.source, config.credential_file);
    assert_eq!(current.target, converted.credential_file);
    assert_eq!(current.sha256, "a".repeat(64));
    let historical = result
        .credentials
        .iter()
        .find(|entry| !entry.required)
        .unwrap();
    assert_eq!(
        historical.source,
        old.parent().unwrap().join("previous.credential")
    );
    assert_eq!(
        historical.target,
        new.parent().unwrap().join("previous.credential")
    );
    assert_eq!(historical.sha256, "b".repeat(64));
}

#[test]
fn migration_inventory_deduplicates_history_and_rejects_conflicting_digests() {
    let (config, mut ledger, old, new) = fixture();
    let mut prior = ledger["records"][0].clone();
    let prior_id = Uuid::from_u128(7);
    prior["pairingId"] = json!(prior_id);
    prior["credentialFile"] = json!(old.with_extension(format!("{prior_id}.credential")));
    prior["state"] = json!("superseded");
    ledger["records"].as_array_mut().unwrap().push(prior);
    let convert = |ledger: &Value| {
        relocate_identity_documents(
            &serde_json::to_vec(&config).unwrap(),
            &serde_json::to_vec(ledger).unwrap(),
            br#"{"apiVersion":"cyc.dev/worker-boot-generation/v1","generation":1}"#,
            &old,
            &new,
            &new.parent().unwrap().join("workspace"),
        )
    };
    let result = convert(&ledger).unwrap();
    assert_eq!(result.credentials.len(), 3);
    assert_eq!(
        result
            .credentials
            .iter()
            .filter(|entry| entry.required)
            .count(),
        1
    );
    ledger["records"][1]["previousCredentialSha256"] = json!("c".repeat(64));
    assert!(convert(&ledger).is_err());
}

#[test]
fn migration_rejects_invalid_generation_and_mismatched_identity() {
    let (config, ledger, old, new) = fixture();
    let config_bytes = serde_json::to_vec(&config).unwrap();
    let ledger_bytes = serde_json::to_vec(&ledger).unwrap();
    let workspace = new.parent().unwrap().join("workspace");
    for boot in [
        json!({"apiVersion": "unknown", "generation": 1}),
        json!({"apiVersion": "cyc.dev/worker-boot-generation/v1", "generation": -1}),
        json!({"apiVersion": "cyc.dev/worker-boot-generation/v1", "generation": i64::MAX}),
        json!({"apiVersion": "cyc.dev/worker-boot-generation/v1", "generation": 1, "extra": true}),
    ] {
        assert!(relocate_identity_documents(
            &config_bytes,
            &ledger_bytes,
            &serde_json::to_vec(&boot).unwrap(),
            &old,
            &new,
            &workspace
        )
        .is_err());
    }
    let boot = serde_json::to_vec(
        &json!({"apiVersion": "cyc.dev/worker-boot-generation/v1", "generation": 1}),
    )
    .unwrap();
    for field in ["nodeId", "controllerId"] {
        let mut altered = ledger.clone();
        altered["records"][0][field] = json!(Uuid::from_u128(9));
        assert!(relocate_identity_documents(
            &config_bytes,
            &serde_json::to_vec(&altered).unwrap(),
            &boot,
            &old,
            &new,
            &workspace
        )
        .is_err());
    }
}

fn fixture() -> (WorkerConfig, Value, PathBuf, PathBuf) {
    let root = std::env::temp_dir().join("cyc-migration-document-fixture");
    let old = root.join("old/config.json");
    let new = root.join("new/config.json");
    let pairing = Uuid::from_u128(1);
    let config = WorkerConfig {
        api_version: WORKER_CONFIG_VERSION.to_owned(),
        worker_url: "https://controller.example.invalid/worker".to_owned(),
        certificate_pem: "fixture-public-certificate".to_owned(),
        controller_id: Uuid::from_u128(2),
        node_id: Uuid::from_u128(3),
        worker_api_version: "cyc.dev/worker-api/v1".to_owned(),
        heartbeat_interval_seconds: 5,
        lease_seconds: 30,
        workspace_root: root.join("old/workspace"),
        credential_file: old.with_extension(format!("{pairing}.credential")),
    };
    let ledger = json!({
        "apiVersion": "cyc.dev/worker-pairing-state/v1",
        "records": [{
            "pairingId": pairing, "controllerId": config.controller_id, "nodeId": config.node_id,
            "credentialFile": config.credential_file, "credentialSha256": "a".repeat(64),
            "createdAt": "2026-09-08T00:00:00Z", "expiresAt": "2026-09-09T00:00:00Z",
            "state": "acknowledged", "cleanupPending": false, "previousCleanupPending": false,
            "previousCredentialFile": root.join("old/previous.credential"),
            "previousCredentialSha256": "b".repeat(64)
        }]
    });
    (config, ledger, old, new)
}

#[test]
fn migration_preserves_identity_and_rewrites_only_paths() {
    let (config, ledger, old, new) = fixture();
    let before = serde_json::to_value(&config).unwrap();
    let workspace = new.parent().unwrap().join("workspace");
    let relocated = config.relocated(&old, &new, &workspace).unwrap();
    let mut expected = before.clone();
    expected["workspaceRoot"] = json!(workspace);
    expected["credentialFile"] = json!(new
        .parent()
        .unwrap()
        .join(config.credential_file.file_name().unwrap()));
    assert_eq!(serde_json::to_value(relocated).unwrap(), expected);
    assert_eq!(serde_json::to_value(&config).unwrap(), before);
    let bytes = serde_json::to_vec(&ledger).unwrap();
    let result: Value =
        serde_json::from_slice(&relocate_pairing_ledger(&bytes, &old, &new).unwrap()).unwrap();
    let mut expected_ledger = ledger;
    expected_ledger["records"][0]["credentialFile"] = expected["credentialFile"].clone();
    expected_ledger["records"][0]["previousCredentialFile"] =
        json!(new.parent().unwrap().join("previous.credential"));
    assert_eq!(result, expected_ledger);
}

#[test]
fn migration_rejects_pending_state_and_unknown_schema() {
    let (_, ledger, old, new) = fixture();
    for state in [
        "staged",
        "pair_request_unknown",
        "pair_accepted",
        "config_committed",
    ] {
        let mut input = ledger.clone();
        input["records"][0]["state"] = json!(state);
        assert!(relocate_pairing_ledger(&serde_json::to_vec(&input).unwrap(), &old, &new).is_err());
    }
    for field in ["cleanupPending", "previousCleanupPending"] {
        let mut input = ledger.clone();
        input["records"][0][field] = json!(true);
        assert!(relocate_pairing_ledger(&serde_json::to_vec(&input).unwrap(), &old, &new).is_err());
    }
    let mut input = ledger;
    input["apiVersion"] = json!("unknown/v99");
    assert!(relocate_pairing_ledger(&serde_json::to_vec(&input).unwrap(), &old, &new).is_err());
}

#[test]
fn migration_rejects_path_escape_and_config_rename() {
    let (mut config, ledger, old, new) = fixture();
    for target in [
        PathBuf::from("relative/config.json"),
        new.with_file_name("renamed.json"),
        new.parent().unwrap().join("../escape/config.json"),
    ] {
        assert!(config.relocated(&old, &target, &new).is_err());
        assert!(
            relocate_pairing_ledger(&serde_json::to_vec(&ledger).unwrap(), &old, &target).is_err()
        );
    }
    config.credential_file = new.parent().unwrap().join("foreign.credential");
    assert!(config
        .relocated(&old, &new, &new.parent().unwrap().join("workspace"))
        .is_err());
}

#[test]
fn migration_validates_ledger_before_rewriting_references() {
    let (_, ledger, old, new) = fixture();
    for (field, value) in [
        (
            "credentialFile",
            json!(new.parent().unwrap().join("foreign.credential")),
        ),
        (
            "previousCredentialFile",
            json!(new.parent().unwrap().join("previous.credential")),
        ),
        ("credentialSha256", json!("not-a-digest")),
        ("unknownField", json!(true)),
    ] {
        let mut input = ledger.clone();
        input["records"][0][field] = value;
        assert!(relocate_pairing_ledger(&serde_json::to_vec(&input).unwrap(), &old, &new).is_err());
    }
    let mut duplicate = ledger.clone();
    duplicate["records"]
        .as_array_mut()
        .unwrap()
        .push(ledger["records"][0].clone());
    assert!(relocate_pairing_ledger(&serde_json::to_vec(&duplicate).unwrap(), &old, &new).is_err());
}
