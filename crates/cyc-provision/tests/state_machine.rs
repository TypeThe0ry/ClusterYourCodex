use std::{
    collections::BTreeMap,
    fs,
    path::Path,
    sync::atomic::{AtomicUsize, Ordering},
    sync::{Arc, Barrier},
    thread,
};

use chrono::Utc;
use cyc_protocol::{
    PlacementCandidateExplain, PlacementExplain, PlacementPlanBindingV1, PlacementPlanDecisionV1,
    PlacementPolicy, ScoreComponent, SmokeRunBindingV1, PLACEMENT_PLAN_BINDING_API_VERSION,
};
use cyc_provision::{
    canonical_smoke_job_id, canonical_smoke_operation_id, AllowedJobKind, ComputerEndpoint,
    DiscoveredComputer, DriveOutcome, DriverFailure, DriverRequest, GpuInventory, NewComputer,
    PinnedHostKeyRecord, ProvisioningAction, ProvisioningDriver, ProvisioningEngine,
    ProvisioningError, ProvisioningIntent, ProvisioningState, ProvisioningStep, ProvisioningStore,
    ServiceScope, SshAuthenticationMethod, SshAuthenticationPolicy, StepCompletion, StoreError,
    COMPUTER_RECORD_FORMAT_VERSION,
};
use cyc_secrets::{CredentialKey, Secret};
use cyc_ssh::{HostKey, PrivateKeyFile};
use tempfile::TempDir;
use uuid::Uuid;

#[test]
fn idempotent_create_replays_the_exact_durable_record() {
    let engine = ProvisioningEngine::new(ProvisioningStore::in_memory().expect("store"));
    let record_id = Uuid::new_v4();
    let intended_node_id = Uuid::new_v4();
    let input = new_computer();

    let created = engine
        .create_idempotent(input.clone(), record_id, intended_node_id)
        .expect("first create");
    let replayed = engine
        .create_idempotent(input, record_id, intended_node_id)
        .expect("response-loss replay");

    assert_eq!(created, replayed);
    assert_eq!(replayed.id, record_id);
    assert_eq!(replayed.intended_node_id, intended_node_id);
    assert_eq!(engine.list().expect("list records"), vec![created]);
}

#[test]
fn idempotent_create_rejects_identity_reuse_with_changed_input() {
    let engine = ProvisioningEngine::new(ProvisioningStore::in_memory().expect("store"));
    let record_id = Uuid::new_v4();
    let intended_node_id = Uuid::new_v4();
    let input = new_computer();
    engine
        .create_idempotent(input, record_id, intended_node_id)
        .expect("first create");

    let mut changed = new_computer();
    changed.display_name = "A different computer".to_owned();
    assert!(matches!(
        engine.create_idempotent(changed, record_id, intended_node_id),
        Err(ProvisioningError::IdempotencyConflict)
    ));
    assert!(matches!(
        engine.create_idempotent(new_computer(), record_id, Uuid::new_v4()),
        Err(ProvisioningError::IdempotencyConflict)
    ));
    let mut changed_authentication = new_computer();
    changed_authentication.ssh_authentication = SshAuthenticationPolicy::agent();
    changed_authentication.remember_credential = false;
    assert!(matches!(
        engine.create_idempotent(changed_authentication, record_id, intended_node_id),
        Err(ProvisioningError::IdempotencyConflict)
    ));
    assert!(matches!(
        engine.create_idempotent(new_computer(), Uuid::nil(), intended_node_id),
        Err(ProvisioningError::InvalidIdentity)
    ));
    assert_eq!(engine.list().expect("list records").len(), 1);
}

#[test]
fn authentication_policy_is_durable_redacted_and_legacy_defaults_to_password() {
    let temp = TempDir::new().expect("tempdir");
    let key_path = temp.path().join("id_fixture");
    fs::write(&key_path, b"fixture-private-key-material").expect("key fixture");
    let private_key = PrivateKeyFile::new(&key_path).expect("validated key fixture");
    let mut input = new_computer();
    input.ssh_authentication =
        SshAuthenticationPolicy::private_key(&private_key).expect("private-key policy");
    input.remember_credential = false;

    let engine = ProvisioningEngine::new(ProvisioningStore::in_memory().expect("store"));
    let record = engine.create(input).expect("private-key record");
    assert_eq!(
        record.ssh_authentication.method(),
        SshAuthenticationMethod::PrivateKey
    );
    assert!(record.ssh_authentication.private_key_configured());
    assert!(!format!("{record:?}").contains(&key_path.to_string_lossy().to_string()));
    let value = serde_json::to_value(&record).expect("record value");
    assert_eq!(
        value.pointer("/sshAuthentication/privateKeyPath"),
        Some(&serde_json::Value::String(
            key_path.to_string_lossy().to_string()
        ))
    );
    let json = serde_json::to_string(&value).expect("serialize record");
    assert!(!json.to_ascii_lowercase().contains("passphrase"));

    let mut legacy = value;
    legacy
        .as_object_mut()
        .expect("record object")
        .remove("sshAuthentication");
    let decoded: cyc_provision::ComputerRecord =
        serde_json::from_value(legacy).expect("legacy record");
    assert_eq!(
        decoded.ssh_authentication.method(),
        SshAuthenticationMethod::Password
    );
}

#[test]
fn remember_policy_is_rejected_for_agent_and_private_key_authentication() {
    let engine = ProvisioningEngine::new(ProvisioningStore::in_memory().expect("store"));
    let mut agent = new_computer();
    agent.ssh_authentication = SshAuthenticationPolicy::agent();
    assert!(matches!(
        engine.create(agent),
        Err(ProvisioningError::Validation(_))
    ));

    let mut valid_agent = new_computer();
    valid_agent.ssh_authentication = SshAuthenticationPolicy::agent();
    valid_agent.remember_credential = false;
    let created = engine.create(valid_agent).expect("agent policy");
    assert_eq!(
        created.ssh_authentication.method(),
        SshAuthenticationMethod::Agent
    );
    assert!(!created.credential_policy.remember_requested);
    assert!(created.credential_reference.is_none());
}

#[test]
fn concurrent_idempotent_creates_converge_on_one_record() {
    let temp = TempDir::new().expect("tempdir");
    let database = temp.path().join("idempotent-create.db");
    let record_id = Uuid::new_v4();
    let intended_node_id = Uuid::new_v4();
    let barrier = Arc::new(Barrier::new(2));
    let mut threads = Vec::new();
    for _ in 0..2 {
        let engine = engine_at(&database);
        let barrier = Arc::clone(&barrier);
        threads.push(thread::spawn(move || {
            barrier.wait();
            engine.create_idempotent(new_computer(), record_id, intended_node_id)
        }));
    }
    let first = threads
        .remove(0)
        .join()
        .expect("first writer")
        .expect("first create");
    let second = threads
        .remove(0)
        .join()
        .expect("second writer")
        .expect("second create");
    assert_eq!(first, second);
    assert_eq!(first.id, record_id);
    assert_eq!(engine_at(&database).list().expect("list records").len(), 1);
}

#[test]
fn checkpoints_survive_crash_and_resume_to_ready() {
    let temp = TempDir::new().expect("tempdir");
    let database = temp.path().join("provision.db");
    let mut driver = FakeDriver::default();

    let engine = engine_at(&database);
    let created = engine.create(new_computer()).expect("create");
    let checkpoint = drive_until(
        &engine,
        created.id,
        &mut driver,
        ProvisioningStep::CredentialStored,
    );
    let intended_node_id = checkpoint.intended_node_id;
    let credential_reference = checkpoint
        .credential_reference
        .as_ref()
        .expect("credential reference")
        .as_str()
        .to_owned();
    let host_key = checkpoint.host_key.clone().expect("host key");
    drop(engine);

    let engine = engine_at(&database);
    let recovered = engine.get(created.id).expect("recover checkpoint");
    assert_eq!(recovered.state, ProvisioningState::CredentialStored);
    assert_eq!(recovered.intended_node_id, intended_node_id);
    assert_eq!(recovered.host_key.as_ref(), Some(&host_key));
    assert_eq!(
        recovered
            .credential_reference
            .as_ref()
            .expect("credential reference")
            .as_str(),
        credential_reference
    );

    let resume = engine
        .request_intent(recovered.id, recovered.revision, ProvisioningIntent::Resume)
        .expect("persist resume intent");
    let resumed = outcome_record(
        engine
            .drive_once(resume.id, resume.revision, &mut driver)
            .expect("consume resume intent"),
    );
    assert_eq!(resumed.state, ProvisioningState::CredentialStored);
    assert_eq!(resumed.intent, ProvisioningIntent::Continue);

    let ready = drive_until(&engine, created.id, &mut driver, ProvisioningStep::Ready);
    assert_eq!(ready.state, ProvisioningState::Ready);
    assert_eq!(ready.paired_node_id, Some(intended_node_id));
    assert!(ready.pairing_id.is_some());
    assert!(ready.heartbeat_seen_at.is_some());
    assert_eq!(ready.format_version, COMPUTER_RECORD_FORMAT_VERSION);
    assert!(ready.smoke_run_binding.is_some());
    assert!(ready.smoke_check_completed_at.is_some());
}

#[test]
fn drive_until_boundary_stops_for_host_approval_then_reaches_ready() {
    let engine = ProvisioningEngine::new(ProvisioningStore::in_memory().expect("store"));
    let created = engine.create(new_computer()).expect("create");
    let mut driver = FakeDriver::default();
    let pending = outcome_record(
        engine
            .drive_until_boundary(created.id, created.revision, &mut driver, 64)
            .expect("drive to approval"),
    );
    assert!(matches!(pending.state, ProvisioningState::HostKeyPending));
    let fingerprint = pending.host_key.as_ref().unwrap().fingerprint.clone();
    let approved = engine
        .approve_host_key(pending.id, pending.revision, &fingerprint)
        .expect("approve");
    let ready = engine
        .drive_until_boundary(approved.id, approved.revision, &mut driver, 64)
        .expect("drive ready");
    assert!(matches!(ready, DriveOutcome::Ready(_)));
}

#[test]
fn ready_repair_preserves_identity_and_skips_enrollment_rotation() {
    let engine = ProvisioningEngine::new(ProvisioningStore::in_memory().expect("store"));
    let created = engine.create(new_computer()).expect("create");
    let mut driver = FakeDriver::default();
    let ready = drive_until(&engine, created.id, &mut driver, ProvisioningStep::Ready);
    let pairing_id = ready.pairing_id;
    let node_id = ready.paired_node_id;
    let previous_cycle = ready.cycle;
    let issue_count = driver
        .calls
        .iter()
        .filter(|(action, _)| *action == ProvisioningAction::IssueEnrollment)
        .count();
    let rollback_count = driver.rollback_count;

    let repairing = engine
        .begin_repair(ready.id, ready.revision)
        .expect("begin in-place repair");
    assert_eq!(repairing.state, ProvisioningState::CredentialStored);
    assert_eq!(repairing.cycle, previous_cycle + 1);
    assert_eq!(repairing.pairing_id, pairing_id);
    assert_eq!(repairing.paired_node_id, node_id);
    assert!(repairing.heartbeat_seen_at.is_none());
    assert!(repairing.smoke_run_binding.is_none());
    assert!(repairing.smoke_check_completed_at.is_none());
    assert_eq!(repairing.format_version, COMPUTER_RECORD_FORMAT_VERSION);

    let repaired = drive_until(&engine, ready.id, &mut driver, ProvisioningStep::Ready);
    assert_eq!(repaired.pairing_id, pairing_id);
    assert_eq!(repaired.paired_node_id, node_id);
    assert!(repaired.smoke_run_binding.is_some());
    assert_eq!(driver.rollback_count, rollback_count);
    assert_eq!(
        driver
            .calls
            .iter()
            .filter(|(action, _)| *action == ProvisioningAction::IssueEnrollment)
            .count(),
        issue_count,
        "routine repair must not rotate the worker credential"
    );

    let repair_actions = driver
        .calls
        .iter()
        .filter(|(_, operation_id)| operation_id.contains(":1:"))
        .map(|(action, _)| *action)
        .collect::<Vec<_>>();
    assert_eq!(
        repair_actions,
        vec![
            ProvisioningAction::StageKit,
            ProvisioningAction::InstallWorker,
            ProvisioningAction::AwaitHeartbeat,
            ProvisioningAction::BeginSmokeCheck,
            ProvisioningAction::RunSmokeCheck,
            ProvisioningAction::CleanupStaging,
        ]
    );
    let repair_smoke_operations = driver
        .calls
        .iter()
        .filter(|(action, _)| {
            matches!(
                action,
                ProvisioningAction::BeginSmokeCheck | ProvisioningAction::RunSmokeCheck
            )
        })
        .filter(|(_, operation_id)| operation_id.contains(":1:"))
        .map(|(_, operation_id)| operation_id)
        .collect::<Vec<_>>();
    assert_eq!(repair_smoke_operations.len(), 2);
    assert_eq!(repair_smoke_operations[0], repair_smoke_operations[1]);
    assert_eq!(
        repair_smoke_operations[0],
        &canonical_smoke_operation_id(repaired.id, repaired.cycle)
    );
}

#[test]
fn repair_is_rejected_before_the_worker_is_ready() {
    let engine = ProvisioningEngine::new(ProvisioningStore::in_memory().expect("store"));
    let created = engine.create(new_computer()).expect("create");
    assert!(matches!(
        engine.begin_repair(created.id, created.revision),
        Err(ProvisioningError::InvalidOperation(_))
    ));
}

#[test]
fn retryable_failure_checkpoints_and_reuses_operation_identity() {
    let engine = ProvisioningEngine::new(ProvisioningStore::in_memory().expect("store"));
    let created = engine.create(new_computer()).expect("create");
    let mut driver = FakeDriver {
        fail_once: Some(ProvisioningAction::StageKit),
        ..FakeDriver::default()
    };
    let checkpoint = drive_until(
        &engine,
        created.id,
        &mut driver,
        ProvisioningStep::CredentialStored,
    );

    let failed = outcome_record(
        engine
            .drive_once(checkpoint.id, checkpoint.revision, &mut driver)
            .expect("persist failure"),
    );
    match &failed.state {
        ProvisioningState::Failed {
            step,
            code,
            retryable,
        } => {
            assert_eq!(*step, ProvisioningStep::CredentialStored);
            assert_eq!(code.as_str(), "FAKE_TRANSIENT");
            assert!(*retryable);
        }
        state => panic!("unexpected state: {state:?}"),
    }

    let retry = engine
        .request_intent(failed.id, failed.revision, ProvisioningIntent::Retry)
        .expect("retry intent");
    let retry_checkpoint = outcome_record(
        engine
            .drive_once(retry.id, retry.revision, &mut driver)
            .expect("restore failed checkpoint"),
    );
    assert_eq!(retry_checkpoint.state, ProvisioningState::CredentialStored);
    let staged = outcome_record(
        engine
            .drive_once(retry_checkpoint.id, retry_checkpoint.revision, &mut driver)
            .expect("retry stage"),
    );
    assert_eq!(staged.state, ProvisioningState::KitStaged);

    let stage_operations = driver
        .calls
        .iter()
        .filter(|(action, _)| *action == ProvisioningAction::StageKit)
        .map(|(_, operation_id)| operation_id.as_str())
        .collect::<Vec<_>>();
    assert_eq!(stage_operations.len(), 2);
    assert_eq!(stage_operations[0], stage_operations[1]);
}

#[test]
fn rollback_and_remove_are_durable_intents() {
    let engine = ProvisioningEngine::new(ProvisioningStore::in_memory().expect("store"));
    let created = engine.create(new_computer()).expect("create");
    let mut driver = FakeDriver::default();
    let staged = drive_until(
        &engine,
        created.id,
        &mut driver,
        ProvisioningStep::KitStaged,
    );
    let pinned = staged.host_key.clone();

    let rollback = engine
        .request_intent(staged.id, staged.revision, ProvisioningIntent::Rollback)
        .expect("rollback intent");
    let rollback_checkpoint = outcome_record(
        engine
            .drive_once(rollback.id, rollback.revision, &mut driver)
            .expect("rollback"),
    );
    assert!(rollback_checkpoint.teardown_completed);
    assert_eq!(rollback_checkpoint.intent, ProvisioningIntent::Rollback);
    let rolled_back = outcome_record(
        engine
            .drive_once(
                rollback_checkpoint.id,
                rollback_checkpoint.revision,
                &mut driver,
            )
            .expect("commit rollback"),
    );
    assert_eq!(rolled_back.state, ProvisioningState::Draft);
    assert_eq!(rolled_back.cycle, 1);
    assert_eq!(rolled_back.host_key, pinned);
    assert!(rolled_back.inventory.is_none());
    assert!(rolled_back.credential_reference.is_some());
    assert_eq!(driver.rollback_count, 1);

    let remove = engine
        .request_intent(
            rolled_back.id,
            rolled_back.revision,
            ProvisioningIntent::Remove,
        )
        .expect("remove intent");
    let remove_checkpoint = outcome_record(
        engine
            .drive_once(remove.id, remove.revision, &mut driver)
            .expect("remote remove"),
    );
    assert!(remove_checkpoint.teardown_completed);
    let outcome = engine
        .drive_once(
            remove_checkpoint.id,
            remove_checkpoint.revision,
            &mut driver,
        )
        .expect("remove");
    assert_eq!(outcome, DriveOutcome::Removed { id: created.id });
    assert_eq!(driver.remove_count, 1);
    assert!(matches!(
        engine.get(created.id),
        Err(ProvisioningError::Store(StoreError::NotFound(_)))
    ));
}

#[test]
fn stale_revision_is_rejected_by_cas() {
    let engine = ProvisioningEngine::new(ProvisioningStore::in_memory().expect("store"));
    let created = engine.create(new_computer()).expect("create");
    let updated = engine
        .request_intent(created.id, created.revision, ProvisioningIntent::Resume)
        .expect("first mutation");
    assert!(updated.revision > created.revision);

    let stale = engine.request_intent(created.id, created.revision, ProvisioningIntent::Remove);
    assert!(matches!(
        stale,
        Err(ProvisioningError::Store(StoreError::Conflict {
            expected,
            actual: Some(actual),
        })) if expected == created.revision && actual == updated.revision
    ));
}

#[test]
fn concurrent_writers_allow_exactly_one_cas_winner() {
    let temp = TempDir::new().expect("tempdir");
    let database = temp.path().join("concurrent.db");
    let creator = engine_at(&database);
    let created = creator.create(new_computer()).expect("create");
    drop(creator);

    let first = engine_at(&database);
    let second = engine_at(&database);
    let first_record = first.get(created.id).expect("first snapshot");
    let second_record = second.get(created.id).expect("second snapshot");
    assert_eq!(first_record.revision, second_record.revision);
    let barrier = Arc::new(Barrier::new(3));

    let first_barrier = Arc::clone(&barrier);
    let first_thread = thread::spawn(move || {
        first_barrier.wait();
        first.request_intent(
            first_record.id,
            first_record.revision,
            ProvisioningIntent::Resume,
        )
    });
    let second_barrier = Arc::clone(&barrier);
    let second_thread = thread::spawn(move || {
        second_barrier.wait();
        second.request_intent(
            second_record.id,
            second_record.revision,
            ProvisioningIntent::Remove,
        )
    });
    barrier.wait();

    let results = [
        first_thread.join().expect("first thread"),
        second_thread.join().expect("second thread"),
    ];
    assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
    assert_eq!(
        results
            .iter()
            .filter(|result| matches!(
                result,
                Err(ProvisioningError::Store(StoreError::Conflict { .. }))
            ))
            .count(),
        1
    );
}

#[test]
fn sqlite_and_serialized_records_never_contain_ephemeral_password() {
    const PASSWORD: &str = "UltraSecretPassword-ShouldNeverPersist";
    let temp = TempDir::new().expect("tempdir");
    let database = temp.path().join("provision.db");
    let engine = engine_at(&database);
    let created = engine.create(new_computer()).expect("create");
    let mut driver = FakeDriver {
        ephemeral_password: Some(Secret::from_string(PASSWORD.to_owned())),
        ..FakeDriver::default()
    };
    let checkpoint = drive_until(
        &engine,
        created.id,
        &mut driver,
        ProvisioningStep::CredentialStored,
    );
    let json = serde_json::to_string(&checkpoint).expect("serialize record");
    let debug = format!("{checkpoint:?}");
    assert!(!json.contains(PASSWORD));
    assert!(!debug.contains(PASSWORD));
    drop(engine);

    assert_file_does_not_contain(&database, PASSWORD.as_bytes());
    let wal = database.with_extension("db-wal");
    if wal.exists() {
        assert_file_does_not_contain(&wal, PASSWORD.as_bytes());
    }

    let connection = rusqlite::Connection::open(&database).expect("inspect database");
    let mut statement = connection
        .prepare("PRAGMA table_info(provision_computers)")
        .expect("table info");
    let columns = statement
        .query_map([], |row| row.get::<_, String>(1))
        .expect("columns")
        .collect::<Result<Vec<_>, _>>()
        .expect("column names");
    assert!(columns.iter().all(|name| {
        let lower = name.to_ascii_lowercase();
        !lower.contains("password") && !lower.contains("secret") && !lower.contains("token")
    }));
}

#[test]
fn new_computer_dto_rejects_embedded_password_fields() {
    let payload = r#"{
        "displayName":"worker",
        "endpoint":{
            "host":"192.0.2.10",
            "port":22,
            "username":"worker",
            "password":"must-not-enter-the-record"
        }
    }"#;
    assert!(serde_json::from_str::<NewComputer>(payload).is_err());
}

#[test]
fn non_secret_worker_policy_is_strict_and_survives_reopen() {
    let temp = TempDir::new().expect("tempdir");
    let database = temp.path().join("policy.db");
    let engine = engine_at(&database);
    let mut input = new_computer();
    input.remember_credential = false;
    input.configuration.service_scope = ServiceScope::System;
    input.configuration.workspace = Some("/srv/codex-worker".to_owned());
    input.configuration.priority = 300;
    input.configuration.resources.maximum_parallel_jobs = Some(4);
    input.configuration.resources.cpu_limit_percent = Some(90);
    input.configuration.resources.memory_limit_bytes = Some(32 * 1024 * 1024 * 1024);
    input.configuration.allowed_job_kinds = [AllowedJobKind::Build, AllowedJobKind::Gpu]
        .into_iter()
        .collect();
    input.configuration.allow_on_battery = true;
    let created = engine.create(input).expect("create with policy");
    drop(engine);

    let reopened = engine_at(&database).get(created.id).expect("reopen policy");
    assert!(!reopened.credential_policy.remember_requested);
    assert_eq!(reopened.configuration.service_scope, ServiceScope::System);
    assert_eq!(
        reopened.configuration.workspace.as_deref(),
        Some("/srv/codex-worker")
    );
    assert_eq!(reopened.configuration.priority, 300);
    assert!(reopened
        .configuration
        .allowed_job_kinds
        .contains(&AllowedJobKind::Gpu));
    assert!(reopened.configuration.allow_on_battery);

    let invalid_workspace = r#"{
        "displayName":"worker",
        "endpoint":{"host":"192.0.2.10","port":22,"username":"worker"},
        "configuration":{"workspace":"relative/path"}
    }"#;
    let decoded = serde_json::from_str::<NewComputer>(invalid_workspace).expect("strict dto");
    assert!(decoded.validate().is_err());
    let unknown_policy = r#"{
        "displayName":"worker",
        "endpoint":{"host":"192.0.2.10","port":22,"username":"worker"},
        "configuration":{"password":"forbidden"}
    }"#;
    assert!(serde_json::from_str::<NewComputer>(unknown_policy).is_err());
}

#[test]
fn changed_host_key_fails_closed_after_rollback() {
    let engine = ProvisioningEngine::new(ProvisioningStore::in_memory().expect("store"));
    let created = engine.create(new_computer()).expect("create");
    let mut driver = FakeDriver::default();
    let authenticated = drive_until(
        &engine,
        created.id,
        &mut driver,
        ProvisioningStep::Authenticated,
    );
    let rollback = engine
        .request_intent(
            authenticated.id,
            authenticated.revision,
            ProvisioningIntent::Rollback,
        )
        .expect("rollback intent");
    let rollback_checkpoint = outcome_record(
        engine
            .drive_once(rollback.id, rollback.revision, &mut driver)
            .expect("rollback"),
    );
    let draft = outcome_record(
        engine
            .drive_once(
                rollback_checkpoint.id,
                rollback_checkpoint.revision,
                &mut driver,
            )
            .expect("commit rollback"),
    );
    driver.alternate_host_key = true;

    let connecting = outcome_record(
        engine
            .drive_once(draft.id, draft.revision, &mut driver)
            .expect("begin ssh"),
    );
    let failed = outcome_record(
        engine
            .drive_once(connecting.id, connecting.revision, &mut driver)
            .expect("observe changed host key"),
    );
    match failed.state {
        ProvisioningState::Failed {
            code, retryable, ..
        } => {
            assert_eq!(code.as_str(), "HOST_KEY_CHANGED");
            assert!(!retryable);
        }
        state => panic!("unexpected state: {state:?}"),
    }
}

#[test]
fn begin_smoke_response_loss_reuses_the_same_operation_job_plan_and_run() {
    let engine = ProvisioningEngine::new(ProvisioningStore::in_memory().expect("store"));
    let created = engine.create(new_computer()).expect("create");
    let mut driver = FakeDriver::default();
    let heartbeat = drive_until(
        &engine,
        created.id,
        &mut driver,
        ProvisioningStep::HeartbeatSeen,
    );
    driver.begin_smoke_response_loss_once = true;

    let failed = outcome_record(
        engine
            .drive_once(heartbeat.id, heartbeat.revision, &mut driver)
            .expect("persist response-loss failure"),
    );
    assert!(matches!(
        failed.state,
        ProvisioningState::Failed {
            step: ProvisioningStep::HeartbeatSeen,
            retryable: true,
            ..
        }
    ));
    assert!(failed.smoke_run_binding.is_none());
    let prepared = driver
        .smoke_bindings
        .values()
        .next()
        .expect("controller retained submitted binding")
        .clone();

    let retry = engine
        .request_intent(failed.id, failed.revision, ProvisioningIntent::Retry)
        .expect("retry intent");
    let restored = outcome_record(
        engine
            .drive_once(retry.id, retry.revision, &mut driver)
            .expect("restore heartbeat checkpoint"),
    );
    let smoke = outcome_record(
        engine
            .drive_once(restored.id, restored.revision, &mut driver)
            .expect("reconcile prepared smoke"),
    );

    assert_eq!(smoke.state, ProvisioningState::SmokeCheck);
    assert_eq!(smoke.smoke_run_binding.as_ref(), Some(&prepared));
    assert_eq!(
        prepared.plan.job_id,
        canonical_smoke_job_id(smoke.id, smoke.cycle)
    );
    let operations = driver
        .calls
        .iter()
        .filter(|(action, _)| *action == ProvisioningAction::BeginSmokeCheck)
        .map(|(_, operation_id)| operation_id)
        .collect::<Vec<_>>();
    assert_eq!(operations.len(), 2);
    assert_eq!(operations[0], operations[1]);
    assert_eq!(
        operations[0],
        &canonical_smoke_operation_id(smoke.id, smoke.cycle)
    );
}

#[test]
fn run_timeout_and_restart_poll_the_exact_expired_durable_binding_without_replanning() {
    let temp = TempDir::new().expect("tempdir");
    let database = temp.path().join("smoke-restart.db");
    let engine = engine_at(&database);
    let created = engine.create(new_computer()).expect("create");
    let mut prepare_driver = FakeDriver::default();
    let heartbeat = drive_until(
        &engine,
        created.id,
        &mut prepare_driver,
        ProvisioningStep::HeartbeatSeen,
    );
    prepare_driver.smoke_plan_already_expired = true;
    let prepared = outcome_record(
        engine
            .drive_once(heartbeat.id, heartbeat.revision, &mut prepare_driver)
            .expect("durably commit submitted smoke binding"),
    );
    let binding = prepared
        .smoke_run_binding
        .clone()
        .expect("durable smoke binding");
    assert!(binding.plan.expires_at < Utc::now());
    drop(engine);

    let engine = engine_at(&database);
    let mut timeout_driver = FakeDriver {
        run_smoke_pending_once: true,
        ..FakeDriver::default()
    };
    let waiting = engine
        .drive_once(prepared.id, prepared.revision, &mut timeout_driver)
        .expect("poll remains pending");
    let waiting_record = outcome_record(waiting);
    assert_eq!(waiting_record.state, ProvisioningState::SmokeCheck);
    assert_eq!(waiting_record.revision, prepared.revision);
    assert_eq!(waiting_record.smoke_run_binding.as_ref(), Some(&binding));
    assert_eq!(
        timeout_driver.smoke_bindings.len(),
        0,
        "run must not prepare"
    );
    assert_eq!(timeout_driver.observed_run_bindings, vec![binding.clone()]);
    drop(engine);

    let engine = engine_at(&database);
    let mut restarted_driver = FakeDriver::default();
    let smoke_passed = outcome_record(
        engine
            .drive_once(
                waiting_record.id,
                waiting_record.revision,
                &mut restarted_driver,
            )
            .expect("restart reconciles exact run"),
    );
    assert_eq!(smoke_passed.state, ProvisioningState::SmokeCheck);
    assert!(smoke_passed.smoke_check_completed_at.is_some());
    let ready = outcome_record(
        engine
            .drive_once(
                smoke_passed.id,
                smoke_passed.revision,
                &mut restarted_driver,
            )
            .expect("restart cleans staging before ready"),
    );
    assert_eq!(ready.state, ProvisioningState::Ready);
    assert_eq!(ready.smoke_run_binding.as_ref(), Some(&binding));
    assert_eq!(
        restarted_driver.smoke_bindings.len(),
        0,
        "run must not replan"
    );
    assert_eq!(
        restarted_driver.observed_run_bindings,
        vec![binding.clone()]
    );
    assert!(ready.smoke_check_completed_at.expect("completion") >= binding.plan.created_at);
}

#[test]
fn current_records_fail_closed_on_missing_or_tampered_smoke_identity() {
    let engine = ProvisioningEngine::new(ProvisioningStore::in_memory().expect("store"));
    let created = engine.create(new_computer()).expect("create");
    let mut driver = FakeDriver::default();
    let ready = drive_until(&engine, created.id, &mut driver, ProvisioningStep::Ready);

    let mut missing = ready.clone();
    missing.smoke_run_binding = None;
    assert_eq!(
        missing.validate(),
        Err(cyc_provision::RecordValidationError::MissingCheckpoint(
            "smokeRunBinding"
        ))
    );

    let mut wrong_job = ready.clone();
    wrong_job.smoke_run_binding.as_mut().unwrap().plan.job_id = Uuid::new_v4();
    assert_eq!(
        wrong_job.validate(),
        Err(cyc_provision::RecordValidationError::SmokeBindingJobMismatch)
    );

    let mut wrong_node = ready.clone();
    let replacement = Uuid::new_v4();
    let binding = wrong_node.smoke_run_binding.as_mut().unwrap();
    binding.plan.decision.node_id = replacement;
    binding.plan.decision.explanation.selected_node_id = Some(replacement);
    binding.plan.decision.explanation.candidates[0].node_id = replacement;
    assert_eq!(
        wrong_node.validate(),
        Err(cyc_provision::RecordValidationError::SmokeBindingNodeMismatch)
    );

    let mut nil_run = ready.clone();
    nil_run.smoke_run_binding.as_mut().unwrap().run_id = Uuid::nil();
    assert_eq!(
        nil_run.validate(),
        Err(cyc_provision::RecordValidationError::InvalidSmokeBinding)
    );

    let mut unsupported = ready.clone();
    unsupported.format_version = COMPUTER_RECORD_FORMAT_VERSION + 1;
    assert_eq!(
        unsupported.validate(),
        Err(cyc_provision::RecordValidationError::UnsupportedFormatVersion)
    );

    let mut fabricated_legacy = ready;
    fabricated_legacy.format_version = 1;
    assert_eq!(
        fabricated_legacy.validate(),
        Err(cyc_provision::RecordValidationError::InvalidSmokeCheckpoint)
    );
}

#[test]
fn engine_rejects_a_tampered_prepare_response_before_the_smoke_checkpoint() {
    let engine = ProvisioningEngine::new(ProvisioningStore::in_memory().expect("store"));
    let created = engine.create(new_computer()).expect("create");
    let mut driver = FakeDriver::default();
    let heartbeat = drive_until(
        &engine,
        created.id,
        &mut driver,
        ProvisioningStep::HeartbeatSeen,
    );
    driver.tamper_prepared_smoke_job_once = true;
    let failed = outcome_record(
        engine
            .drive_once(heartbeat.id, heartbeat.revision, &mut driver)
            .expect("fail closed on tampered binding"),
    );
    match failed.state {
        ProvisioningState::Failed {
            step,
            code,
            retryable,
        } => {
            assert_eq!(step, ProvisioningStep::HeartbeatSeen);
            assert_eq!(code.as_str(), "SMOKE_BINDING_INVALID");
            assert!(!retryable);
        }
        state => panic!("unexpected state: {state:?}"),
    }
    assert!(failed.smoke_run_binding.is_none());
}

#[test]
fn legacy_ready_is_recognized_without_fabricating_binding_and_repair_upgrades_it() {
    let temp = TempDir::new().expect("tempdir");
    let database = temp.path().join("legacy-ready.db");
    let engine = engine_at(&database);
    let created = engine.create(new_computer()).expect("create");
    let mut driver = FakeDriver::default();
    let ready = drive_until(&engine, created.id, &mut driver, ProvisioningStep::Ready);
    drop(engine);

    rewrite_as_legacy_document(&database, &ready);
    let engine = engine_at(&database);
    let legacy = engine.get(ready.id).expect("load legacy ready");
    assert_eq!(legacy.format_version, 1);
    assert!(legacy.is_legacy_ready());
    assert!(legacy.smoke_run_binding.is_none());
    assert!(legacy.smoke_check_completed_at.is_some());

    let repair = engine
        .begin_repair(legacy.id, legacy.revision)
        .expect("repair upgrades legacy ready");
    assert_eq!(repair.format_version, COMPUTER_RECORD_FORMAT_VERSION);
    assert!(!repair.is_legacy_ready());
    assert!(repair.smoke_run_binding.is_none());
    assert!(repair.smoke_check_completed_at.is_none());

    let upgraded = drive_until(&engine, repair.id, &mut driver, ProvisioningStep::Ready);
    assert_eq!(upgraded.format_version, COMPUTER_RECORD_FORMAT_VERSION);
    assert!(upgraded.smoke_run_binding.is_some());
}

#[test]
fn legacy_inflight_smoke_reenters_prepare_before_run() {
    let temp = TempDir::new().expect("tempdir");
    let database = temp.path().join("legacy-smoke.db");
    let engine = engine_at(&database);
    let created = engine.create(new_computer()).expect("create");
    let mut driver = FakeDriver::default();
    let current_smoke = drive_until(
        &engine,
        created.id,
        &mut driver,
        ProvisioningStep::SmokeCheck,
    );
    drop(engine);
    rewrite_as_legacy_document(&database, &current_smoke);

    let engine = engine_at(&database);
    let legacy = engine.get(created.id).expect("legacy in-flight smoke");
    assert_eq!(legacy.state, ProvisioningState::SmokeCheck);
    assert!(legacy.smoke_run_binding.is_none());
    let mut restarted_driver = FakeDriver::default();
    let rebound = outcome_record(
        engine
            .drive_once(legacy.id, legacy.revision, &mut restarted_driver)
            .expect("legacy smoke prepares a new durable binding"),
    );
    assert_eq!(
        restarted_driver.calls[0].0,
        ProvisioningAction::BeginSmokeCheck
    );
    assert_eq!(rebound.state, ProvisioningState::SmokeCheck);
    assert_eq!(rebound.format_version, COMPUTER_RECORD_FORMAT_VERSION);
    assert!(rebound.smoke_run_binding.is_some());
}

#[test]
fn ready_rollback_clears_binding_only_when_the_cycle_is_reset_and_remove_preserves_until_delete() {
    let engine = ProvisioningEngine::new(ProvisioningStore::in_memory().expect("store"));
    let created = engine.create(new_computer()).expect("create");
    let mut driver = FakeDriver::default();
    let ready = drive_until(&engine, created.id, &mut driver, ProvisioningStep::Ready);
    let binding = ready.smoke_run_binding.clone().expect("ready binding");

    let rollback = engine
        .request_intent(ready.id, ready.revision, ProvisioningIntent::Rollback)
        .expect("rollback intent");
    assert_eq!(rollback.smoke_run_binding.as_ref(), Some(&binding));
    let teardown = outcome_record(
        engine
            .drive_once(rollback.id, rollback.revision, &mut driver)
            .expect("remote rollback"),
    );
    assert_eq!(teardown.smoke_run_binding.as_ref(), Some(&binding));
    let reset = outcome_record(
        engine
            .drive_once(teardown.id, teardown.revision, &mut driver)
            .expect("reset cycle"),
    );
    assert_eq!(reset.state, ProvisioningState::Draft);
    assert!(reset.smoke_run_binding.is_none());
    assert!(reset.smoke_check_completed_at.is_none());
    assert_eq!(reset.format_version, COMPUTER_RECORD_FORMAT_VERSION);

    let second_ready = drive_until(&engine, reset.id, &mut driver, ProvisioningStep::Ready);
    let second_binding = second_ready
        .smoke_run_binding
        .clone()
        .expect("second-cycle binding");
    assert_ne!(binding.plan.job_id, second_binding.plan.job_id);
    let remove = engine
        .request_intent(
            second_ready.id,
            second_ready.revision,
            ProvisioningIntent::Remove,
        )
        .expect("remove intent");
    assert_eq!(remove.smoke_run_binding.as_ref(), Some(&second_binding));
    let removed_remote = outcome_record(
        engine
            .drive_once(remove.id, remove.revision, &mut driver)
            .expect("remote remove"),
    );
    assert_eq!(
        removed_remote.smoke_run_binding.as_ref(),
        Some(&second_binding)
    );
    assert!(matches!(
        engine
            .drive_once(removed_remote.id, removed_remote.revision, &mut driver)
            .expect("delete record"),
        DriveOutcome::Removed { .. }
    ));
}

#[test]
fn concurrent_begin_smoke_writers_have_one_cas_winner_and_one_binding() {
    let temp = TempDir::new().expect("tempdir");
    let database = temp.path().join("smoke-cas.db");
    let creator = engine_at(&database);
    let created = creator.create(new_computer()).expect("create");
    let mut setup_driver = FakeDriver::default();
    let heartbeat = drive_until(
        &creator,
        created.id,
        &mut setup_driver,
        ProvisioningStep::HeartbeatSeen,
    );
    drop(creator);

    let binding = smoke_binding(&heartbeat);
    let barrier = Arc::new(Barrier::new(2));
    let calls = Arc::new(AtomicUsize::new(0));
    let first_engine = engine_at(&database);
    let second_engine = engine_at(&database);
    let first_barrier = Arc::clone(&barrier);
    let second_barrier = Arc::clone(&barrier);
    let first_calls = Arc::clone(&calls);
    let second_calls = Arc::clone(&calls);
    let first_binding = binding.clone();
    let second_binding = binding.clone();
    let first_record = heartbeat.clone();
    let second_record = heartbeat.clone();

    let first = thread::spawn(move || {
        let mut driver = RacingPrepareDriver {
            barrier: first_barrier,
            calls: first_calls,
            binding: first_binding,
        };
        first_engine.drive_once(first_record.id, first_record.revision, &mut driver)
    });
    let second = thread::spawn(move || {
        let mut driver = RacingPrepareDriver {
            barrier: second_barrier,
            calls: second_calls,
            binding: second_binding,
        };
        second_engine.drive_once(second_record.id, second_record.revision, &mut driver)
    });
    let results = [
        first.join().expect("first writer"),
        second.join().expect("second writer"),
    ];
    assert_eq!(calls.load(Ordering::SeqCst), 2);
    assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
    assert_eq!(
        results
            .iter()
            .filter(|result| matches!(
                result,
                Err(ProvisioningError::Store(StoreError::Conflict { .. }))
            ))
            .count(),
        1
    );
    let stored = engine_at(&database)
        .get(heartbeat.id)
        .expect("winning smoke checkpoint");
    assert_eq!(stored.state, ProvisioningState::SmokeCheck);
    assert_eq!(stored.smoke_run_binding.as_ref(), Some(&binding));
}

fn rewrite_as_legacy_document(database: &Path, record: &cyc_provision::ComputerRecord) {
    let mut document = serde_json::to_value(record).expect("serialize record");
    let object = document.as_object_mut().expect("record object");
    object.remove("formatVersion");
    object.remove("smokeRunBinding");
    let connection = rusqlite::Connection::open(database).expect("open journal for migration test");
    let changed = connection
        .execute(
            "UPDATE provision_computers SET document = ?1 WHERE id = ?2",
            rusqlite::params![
                serde_json::to_string(&document).expect("legacy JSON"),
                record.id.to_string()
            ],
        )
        .expect("write legacy fixture");
    assert_eq!(changed, 1);
}

struct RacingPrepareDriver {
    barrier: Arc<Barrier>,
    calls: Arc<AtomicUsize>,
    binding: SmokeRunBindingV1,
}

impl ProvisioningDriver for RacingPrepareDriver {
    fn execute(&mut self, request: &DriverRequest<'_>) -> Result<StepCompletion, DriverFailure> {
        assert_eq!(request.action, ProvisioningAction::BeginSmokeCheck);
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.barrier.wait();
        Ok(StepCompletion::SmokeCheckPrepared {
            binding: self.binding.clone(),
        })
    }

    fn rollback(&mut self, _request: &DriverRequest<'_>) -> Result<(), DriverFailure> {
        panic!("unexpected rollback")
    }

    fn remove(&mut self, _request: &DriverRequest<'_>) -> Result<(), DriverFailure> {
        panic!("unexpected remove")
    }

    fn forget_credential(&mut self, _request: &DriverRequest<'_>) -> Result<(), DriverFailure> {
        panic!("unexpected credential deletion")
    }
}

fn engine_at(path: &Path) -> ProvisioningEngine {
    ProvisioningEngine::new(ProvisioningStore::open(path).expect("store"))
}

fn new_computer() -> NewComputer {
    NewComputer::new(
        "Build Worker",
        ComputerEndpoint::new("192.0.2.10", 22, "worker").expect("endpoint"),
    )
    .expect("computer")
}

fn drive_until(
    engine: &ProvisioningEngine,
    id: Uuid,
    driver: &mut FakeDriver,
    target: ProvisioningStep,
) -> cyc_provision::ComputerRecord {
    for _ in 0..64 {
        let record = engine.get(id).expect("get checkpoint");
        if record.state.active_step() == target
            && !matches!(record.state, ProvisioningState::Failed { .. })
        {
            return record;
        }
        if matches!(record.state, ProvisioningState::HostKeyPending)
            && record.host_key_approved_at.is_none()
        {
            let fingerprint = record
                .host_key
                .as_ref()
                .expect("observed host key")
                .fingerprint
                .clone();
            engine
                .approve_host_key(record.id, record.revision, &fingerprint)
                .expect("approve host key");
            continue;
        }
        let outcome = engine
            .drive_once(record.id, record.revision, driver)
            .expect("drive checkpoint");
        match outcome {
            DriveOutcome::Failed(failed) => panic!("unexpected failure: {:?}", failed.state),
            DriveOutcome::AwaitingIntent(waiting) => {
                panic!("unexpected intent wait: {:?}", waiting.state)
            }
            DriveOutcome::AwaitingHostKeyApproval(_) => {}
            DriveOutcome::AwaitingCredential(waiting) => {
                panic!("unexpected credential wait: {:?}", waiting.state)
            }
            DriveOutcome::AwaitingExternal(_) => {}
            DriveOutcome::Checkpoint(_) | DriveOutcome::Ready(_) | DriveOutcome::RolledBack(_) => {}
            DriveOutcome::Removed { .. } => panic!("unexpected removal"),
        }
    }
    panic!("did not reach {target:?}")
}

fn outcome_record(outcome: DriveOutcome) -> cyc_provision::ComputerRecord {
    match outcome {
        DriveOutcome::Checkpoint(record)
        | DriveOutcome::AwaitingHostKeyApproval(record)
        | DriveOutcome::AwaitingIntent(record)
        | DriveOutcome::AwaitingCredential(record)
        | DriveOutcome::AwaitingExternal(record)
        | DriveOutcome::Ready(record)
        | DriveOutcome::Failed(record)
        | DriveOutcome::RolledBack(record) => record,
        DriveOutcome::Removed { .. } => panic!("record was removed"),
    }
}

fn assert_file_does_not_contain(path: &Path, needle: &[u8]) {
    let bytes = fs::read(path).expect("read database file");
    assert!(!bytes.windows(needle.len()).any(|window| window == needle));
}

#[derive(Default)]
struct FakeDriver {
    fail_once: Option<ProvisioningAction>,
    alternate_host_key: bool,
    ephemeral_password: Option<Secret>,
    calls: Vec<(ProvisioningAction, String)>,
    smoke_bindings: BTreeMap<String, SmokeRunBindingV1>,
    begin_smoke_response_loss_once: bool,
    tamper_prepared_smoke_job_once: bool,
    smoke_plan_already_expired: bool,
    run_smoke_pending_once: bool,
    observed_run_bindings: Vec<SmokeRunBindingV1>,
    rollback_count: usize,
    remove_count: usize,
}

impl ProvisioningDriver for FakeDriver {
    fn execute(&mut self, request: &DriverRequest<'_>) -> Result<StepCompletion, DriverFailure> {
        let _password_length = self.ephemeral_password.as_ref().map(Secret::len);
        self.calls
            .push((request.action, request.operation_id.clone()));
        if self.fail_once == Some(request.action) {
            self.fail_once = None;
            return Err(DriverFailure::new("FAKE_TRANSIENT", true).expect("failure"));
        }
        let completion = match request.action {
            ProvisioningAction::BeginSsh => StepCompletion::SshStarted,
            ProvisioningAction::ProbeHostKey => {
                let bytes = if self.alternate_host_key {
                    vec![9, 9, 9, 9]
                } else {
                    vec![1, 2, 3, 4]
                };
                let host_key = HostKey::from_parts("ssh-ed25519", bytes).expect("host key");
                StepCompletion::HostKeyObserved(PinnedHostKeyRecord::from(&host_key))
            }
            ProvisioningAction::Authenticate => StepCompletion::Authenticated,
            ProvisioningAction::BeginDiscovery => StepCompletion::DiscoveryStarted,
            ProvisioningAction::DiscoverAndStoreCredential => {
                let mut toolchains = BTreeMap::new();
                toolchains.insert("git".to_owned(), "2.50.0".to_owned());
                StepCompletion::DiscoveryCompleted {
                    inventory: DiscoveredComputer {
                        hostname: "worker-01".to_owned(),
                        operating_system: "windows".to_owned(),
                        architecture: "x86_64".to_owned(),
                        cpu_model: "Fixture CPU".to_owned(),
                        logical_cpu_count: 16,
                        memory_bytes: 32 * 1024 * 1024 * 1024,
                        workspace_free_bytes: 100 * 1024 * 1024 * 1024,
                        gpu_devices: vec![GpuInventory {
                            name: "Test GPU".to_owned(),
                            stable_device_id: Some("gpu-0".to_owned()),
                            memory_bytes: Some(8 * 1024 * 1024 * 1024),
                        }],
                        toolchains,
                    },
                    credential_reference: CredentialKey::new(
                        "ssh-password",
                        request.computer.id.simple().to_string(),
                    )
                    .expect("credential key")
                    .reference(),
                }
            }
            ProvisioningAction::StageKit => StepCompletion::KitStaged,
            ProvisioningAction::InstallWorker => StepCompletion::WorkerInstalled,
            ProvisioningAction::IssueEnrollment => StepCompletion::EnrollmentIssued {
                pairing_id: Uuid::from_u128(0x1234),
            },
            ProvisioningAction::ApplyEnrollment | ProvisioningAction::AwaitPairing => {
                StepCompletion::Paired {
                    node_id: request.computer.intended_node_id,
                }
            }
            ProvisioningAction::EnableService => StepCompletion::ServiceEnabled,
            ProvisioningAction::AwaitHeartbeat => StepCompletion::HeartbeatObserved {
                observed_at: Utc::now(),
            },
            ProvisioningAction::BeginSmokeCheck => {
                let mut prepared = smoke_binding(request.computer);
                if self.smoke_plan_already_expired {
                    prepared.plan.created_at = Utc::now() - chrono::Duration::minutes(2);
                    prepared.plan.expires_at = Utc::now() - chrono::Duration::minutes(1);
                }
                let mut binding = self
                    .smoke_bindings
                    .entry(request.operation_id.clone())
                    .or_insert(prepared)
                    .clone();
                if self.begin_smoke_response_loss_once {
                    self.begin_smoke_response_loss_once = false;
                    return Err(
                        DriverFailure::new("SMOKE_PREPARE_RESPONSE_LOST", true).expect("failure")
                    );
                }
                if self.tamper_prepared_smoke_job_once {
                    self.tamper_prepared_smoke_job_once = false;
                    binding.plan.job_id = Uuid::new_v4();
                }
                StepCompletion::SmokeCheckPrepared { binding }
            }
            ProvisioningAction::RunSmokeCheck => {
                self.observed_run_bindings.push(
                    request
                        .computer
                        .smoke_run_binding
                        .clone()
                        .expect("run requires durable binding"),
                );
                if self.run_smoke_pending_once {
                    self.run_smoke_pending_once = false;
                    StepCompletion::Pending
                } else {
                    StepCompletion::SmokeCheckPassed {
                        completed_at: Utc::now(),
                    }
                }
            }
            ProvisioningAction::CleanupStaging => StepCompletion::StagingCleaned,
            ProvisioningAction::Rollback
            | ProvisioningAction::Remove
            | ProvisioningAction::ForgetCredential => {
                panic!("lifecycle intent passed to execute")
            }
        };
        Ok(completion)
    }

    fn rollback(&mut self, request: &DriverRequest<'_>) -> Result<(), DriverFailure> {
        assert_eq!(request.action, ProvisioningAction::Rollback);
        self.rollback_count += 1;
        Ok(())
    }

    fn remove(&mut self, request: &DriverRequest<'_>) -> Result<(), DriverFailure> {
        assert_eq!(request.action, ProvisioningAction::Remove);
        self.remove_count += 1;
        Ok(())
    }

    fn forget_credential(&mut self, request: &DriverRequest<'_>) -> Result<(), DriverFailure> {
        assert_eq!(request.action, ProvisioningAction::ForgetCredential);
        Ok(())
    }
}

fn smoke_binding(record: &cyc_provision::ComputerRecord) -> SmokeRunBindingV1 {
    let node_id = record
        .paired_node_id
        .expect("smoke binding requires paired node");
    let created_at = Utc::now();
    SmokeRunBindingV1 {
        plan: PlacementPlanBindingV1 {
            api_version: PLACEMENT_PLAN_BINDING_API_VERSION.to_owned(),
            plan_id: Uuid::new_v4(),
            job_id: canonical_smoke_job_id(record.id, record.cycle),
            job_digest: "0".repeat(64),
            created_at,
            expires_at: created_at + chrono::Duration::minutes(1),
            fleet_revision: 1,
            node_revision: 1,
            policy_revision: 1,
            decision: PlacementPlanDecisionV1 {
                node_id,
                score: 1,
                explanation: PlacementExplain {
                    policy: PlacementPolicy::Manual,
                    selected_node_id: Some(node_id),
                    candidates: vec![PlacementCandidateExplain {
                        node_id,
                        node_name: "fixture-worker".to_owned(),
                        eligible: true,
                        score: Some(1),
                        score_components: vec![ScoreComponent {
                            key: "preferred_node".to_owned(),
                            value: 1,
                            detail: "canonical provisioning target".to_owned(),
                        }],
                        rejection_reasons: Vec::new(),
                    }],
                },
            },
        },
        run_id: Uuid::new_v4(),
    }
}
