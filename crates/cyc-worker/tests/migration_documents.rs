use cyc_worker::config::{WorkerConfig, WORKER_CONFIG_VERSION};
use cyc_worker::migration::relocate_identity_documents;
use cyc_worker::runtime::relocate_pairing_ledger;
use serde_json::{json, Value};
use std::path::PathBuf;
use uuid::Uuid;

#[cfg(windows)]
#[test]
fn locked_source_stages_identity_without_touching_original_files() {
    use cyc_worker::{
        migration::{inspect_migration_stage, LockedMigrationInputs},
        security::write_secret_file,
    };
    use sha2::{Digest, Sha256};
    let temporary = tempfile::tempdir().unwrap();
    let (config, ledger, original, _) = fixture();
    let old = temporary.path().join("source/config.json");
    let new = temporary
        .path()
        .join("target-private/destination/config.json");
    let config = config
        .relocated(&original, &old, &old.parent().unwrap().join("workspace"))
        .unwrap();
    let mut ledger: Value = serde_json::from_slice(
        &relocate_pairing_ledger(&serde_json::to_vec(&ledger).unwrap(), &original, &old).unwrap(),
    )
    .unwrap();
    ledger["records"][0]["credentialSha256"] =
        json!(hex::encode(Sha256::digest(b"source-credential-fixture")));
    config.write(&old).unwrap();
    write_secret_file(&config.workspace_root.join("fixture-marker"), "fixture").unwrap();
    write_secret_file(
        &old.with_extension("pairing-state.json"),
        &serde_json::to_string(&ledger).unwrap(),
    )
    .unwrap();
    write_secret_file(
        &old.with_extension("boot-generation.json"),
        r#"{"apiVersion":"cyc.dev/worker-boot-generation/v1","generation":29}"#,
    )
    .unwrap();
    write_secret_file(&config.credential_file, "source-credential-fixture").unwrap();
    let before = std::fs::read(&old).unwrap();
    let output = std::process::Command::new("whoami.exe")
        .args(["/user", "/fo", "csv", "/nh"])
        .output()
        .unwrap();
    assert!(output.status.success());
    let identity = String::from_utf8(output.stdout).unwrap();
    let sid = identity
        .split([',', '"'])
        .find(|part| part.starts_with("S-1-"))
        .unwrap();
    let inputs =
        LockedMigrationInputs::open(&old, &new, &new.parent().unwrap().join("workspace"), sid)
            .unwrap();
    assert!(std::fs::write(&old, b"changed").is_err());
    assert!(std::fs::write(&config.credential_file, b"changed").is_err());
    inputs.stage().unwrap();
    assert_eq!(inspect_migration_stage(&new).unwrap().files_verified, 4);
    assert_eq!(std::fs::read(&old).unwrap(), before);
    assert_eq!(
        std::fs::read(&config.credential_file).unwrap(),
        b"source-credential-fixture"
    );
    let converted: WorkerConfig = serde_json::from_slice(&std::fs::read(&new).unwrap()).unwrap();
    assert_eq!(converted.node_id, config.node_id);
    assert_eq!(converted.controller_id, config.controller_id);
    assert_eq!(
        std::fs::read(&converted.credential_file).unwrap(),
        b"source-credential-fixture"
    );
}

#[test]
fn migration_staging_validates_before_writes_and_preserves_exact_bytes() {
    use cyc_worker::migration::stage_identity_documents;
    use sha2::{Digest, Sha256};
    use std::collections::BTreeMap;
    let temporary = tempfile::tempdir().unwrap();
    let (config, mut ledger, old, _) = fixture();
    let new = temporary.path().join("private/staged/config.json");
    let secret: Vec<u8> = (0u8..32).map(|index| b'a' + (index % 26)).collect();
    ledger["records"][0]["credentialSha256"] = json!(hex::encode(Sha256::digest(&secret)));
    let boot = br#"{"apiVersion":"cyc.dev/worker-boot-generation/v1","generation":17}"#;
    let documents = relocate_identity_documents(
        &serde_json::to_vec(&config).unwrap(),
        &serde_json::to_vec(&ledger).unwrap(),
        boot,
        &old,
        &new,
        &new.parent().unwrap().join("workspace"),
    )
    .unwrap();
    assert!(stage_identity_documents(&new, &documents, &BTreeMap::new()).is_err());
    assert!(!new.parent().unwrap().exists());
    let mut credentials = BTreeMap::from([(config.credential_file.clone(), b"incorrect".to_vec())]);
    assert!(stage_identity_documents(&new, &documents, &credentials).is_err());
    assert!(!new.parent().unwrap().exists());
    credentials.insert(config.credential_file.clone(), secret.clone());
    stage_identity_documents(&new, &documents, &credentials).unwrap();
    assert_eq!(std::fs::read(&new).unwrap(), documents.config_json);
    assert_eq!(
        std::fs::read(new.with_extension("boot-generation.json")).unwrap(),
        boot
    );
    let current = documents
        .credentials
        .iter()
        .find(|entry| entry.required)
        .unwrap();
    assert_eq!(std::fs::read(&current.target).unwrap(), secret);
    cyc_worker::security::ensure_protected_input(&current.target).unwrap();
    let journal_path = new.parent().unwrap().join(".migration-stage.json");
    cyc_worker::security::ensure_protected_input(&journal_path).unwrap();
    let journal = std::fs::read(&journal_path).unwrap();
    let mut receipt: Value = serde_json::from_slice(&journal).unwrap();
    assert_eq!(receipt["phase"], "staged");
    assert_eq!(receipt["activationAllowed"], false);
    assert_eq!(receipt["files"].as_array().unwrap().len(), 4);
    assert!(!journal.windows(secret.len()).any(|window| window == secret));
    assert!(stage_identity_documents(&new, &documents, &credentials).is_err());
    assert_eq!(std::fs::read(&current.target).unwrap(), secret);
    let inspected = cyc_worker::migration::inspect_migration_stage(&new).unwrap();
    assert_eq!(inspected.files_verified, 4);
    assert!(!inspected.activation_allowed);
    assert!(WorkerConfig::load(&new).is_err());
    for command in ["status", "run", "pair"] {
        let mut process = std::process::Command::new(env!("CARGO_BIN_EXE_cyc-worker"));
        process.args([command, "--config"]).arg(&new);
        if command == "pair" {
            process
                .arg("--enrollment-file")
                .arg(new.parent().unwrap().join("absent-enrollment.json"));
        }
        let rejected = process.output().unwrap();
        assert!(!rejected.status.success());
        assert!(String::from_utf8(rejected.stderr)
            .unwrap()
            .contains("worker migration is pending"));
    }
    assert!(!new.with_extension("pair.lock").exists());
    assert!(!new.with_extension("boot-generation.lock").exists());
    let output = std::process::Command::new(env!("CARGO_BIN_EXE_cyc-worker"))
        .args(["migration-status", "--config"])
        .arg(&new)
        .output()
        .unwrap();
    assert!(output.status.success());
    let public: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(public["phase"], "staged");
    assert_eq!(public["activationAllowed"], false);
    assert!(!output
        .stdout
        .windows(secret.len())
        .any(|window| window == secret));
    std::fs::write(&current.target, b"changed").unwrap();
    assert!(cyc_worker::migration::inspect_migration_stage(&new).is_err());
    std::fs::write(&current.target, &secret).unwrap();
    receipt["files"][0]["name"] = json!("../outside");
    std::fs::write(&journal_path, serde_json::to_vec(&receipt).unwrap()).unwrap();
    assert!(cyc_worker::migration::inspect_migration_stage(&new).is_err());
    let mut receipt: Value =
        serde_json::from_slice(&std::fs::read(&journal_path).unwrap()).unwrap();
    receipt["files"] = json!([]);
    receipt["phase"] = json!("copying");
    std::fs::write(&journal_path, serde_json::to_vec(&receipt).unwrap()).unwrap();
    let interrupted = cyc_worker::migration::inspect_migration_stage(&new).unwrap();
    assert_eq!(interrupted.phase, "copying");
    assert_eq!(interrupted.files_verified, 0);
    assert!(!interrupted.activation_allowed);
}

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
