use chrono::{DateTime, Utc};
use cyc_protocol::SmokeRunBindingV1;
use cyc_secrets::CredentialReference;
use serde::Serialize;
use thiserror::Error;
use uuid::Uuid;

use crate::{
    ComputerRecord, CredentialState, DiscoveredComputer, FailureCode, NewComputer,
    PinnedHostKeyRecord, ProvisioningIntent, ProvisioningState, ProvisioningStep,
    ProvisioningStore, RecordValidationError, SshAuthenticationMethod, StoreError,
    COMPUTER_RECORD_FORMAT_VERSION,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ProvisioningAction {
    BeginSsh,
    ProbeHostKey,
    Authenticate,
    BeginDiscovery,
    DiscoverAndStoreCredential,
    StageKit,
    InstallWorker,
    IssueEnrollment,
    /// Reconcile the durable enrollment checkpoint, then apply its one-time
    /// bundle over SSH only while the controller still reports it pending.
    /// This action intentionally follows `IssueEnrollment` in a separate
    /// engine turn so a remote worker can never be paired before `pairing_id`
    /// is committed to the provisioning journal.
    ApplyEnrollment,
    /// Compatibility action retained for injected drivers compiled against
    /// the original state-machine vocabulary. New engine transitions use
    /// `ApplyEnrollment`.
    AwaitPairing,
    EnableService,
    AwaitHeartbeat,
    BeginSmokeCheck,
    RunSmokeCheck,
    /// Remove the job-owned remote provisioning staging tree after the
    /// managed smoke run has passed.  This is deliberately a separate durable
    /// checkpoint: a cleanup failure must never publish the computer Ready.
    CleanupStaging,
    Rollback,
    Remove,
    ForgetCredential,
}

impl ProvisioningAction {
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::BeginSsh => "begin_ssh",
            Self::ProbeHostKey => "probe_host_key",
            Self::Authenticate => "authenticate",
            Self::BeginDiscovery => "begin_discovery",
            Self::DiscoverAndStoreCredential => "discover_and_store_credential",
            Self::StageKit => "stage_kit",
            Self::InstallWorker => "install_worker",
            Self::IssueEnrollment => "issue_enrollment",
            Self::ApplyEnrollment => "apply_enrollment",
            Self::AwaitPairing => "await_pairing",
            Self::EnableService => "enable_service",
            Self::AwaitHeartbeat => "await_heartbeat",
            Self::BeginSmokeCheck => "begin_smoke_check",
            Self::RunSmokeCheck => "run_smoke_check",
            Self::CleanupStaging => "cleanup_staging",
            Self::Rollback => "rollback",
            Self::Remove => "remove",
            Self::ForgetCredential => "forget_credential",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StepCompletion {
    SshStarted,
    HostKeyObserved(PinnedHostKeyRecord),
    Authenticated,
    AuthenticatedStored {
        credential_reference: CredentialReference,
    },
    AuthenticatedSessionOnly,
    DiscoveryStarted,
    DiscoveryCompleted {
        inventory: DiscoveredComputer,
        credential_reference: CredentialReference,
    },
    DiscoveryCompletedSessionOnly {
        inventory: DiscoveredComputer,
    },
    KitStaged,
    WorkerInstalled,
    EnrollmentIssued {
        pairing_id: Uuid,
    },
    Paired {
        node_id: Uuid,
    },
    ServiceEnabled,
    HeartbeatObserved {
        observed_at: DateTime<Utc>,
    },
    SmokeCheckPrepared {
        binding: SmokeRunBindingV1,
    },
    SmokeCheckPassed {
        completed_at: DateTime<Utc>,
    },
    StagingCleaned,
    /// A controller-side asynchronous condition has not completed yet. This is
    /// a normal polling boundary and must never be persisted as `failed`.
    Pending,
}

/// A driver request contains only durable non-secret state. Concrete Tauri
/// drivers retain the transient password/private-key passphrase or fetch a
/// remembered password from `cyc-secrets` rather than putting it in this
/// request. SSH-agent authentication carries no secret.
#[derive(Debug)]
pub struct DriverRequest<'a> {
    pub computer: &'a ComputerRecord,
    pub action: ProvisioningAction,
    pub operation_id: String,
}

impl DriverRequest<'_> {
    /// Return the stable idempotency key for another action in the same
    /// provisioning cycle. Enrollment application uses this to replay the
    /// *original* issue operation after the pairing id is durable instead of
    /// accidentally creating a second controller operation.
    #[must_use]
    pub fn operation_id_for(&self, action: ProvisioningAction) -> String {
        operation_id_for_action(self.computer, action)
    }
}

pub trait ProvisioningDriver: Send {
    /// Execute must be idempotent for `request.operation_id`. The core keeps
    /// that identifier stable across process crashes, CAS conflicts, and
    /// retryable failures so remote side effects can be safely reconciled.
    fn execute(&mut self, request: &DriverRequest<'_>) -> Result<StepCompletion, DriverFailure>;

    /// Rollback must be idempotent for `request.operation_id`.
    fn rollback(&mut self, request: &DriverRequest<'_>) -> Result<(), DriverFailure>;

    /// Remove must be idempotent for `request.operation_id`.
    fn remove(&mut self, request: &DriverRequest<'_>) -> Result<(), DriverFailure>;

    /// Delete only the SSH bootstrap credential. The installed managed worker
    /// and its controller credential remain untouched.
    fn forget_credential(&mut self, request: &DriverRequest<'_>) -> Result<(), DriverFailure>;
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DriverFailure {
    pub code: FailureCode,
    pub retryable: bool,
    kind: DriverFailureKind,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum DriverFailureKind {
    Failure,
    CredentialRequired,
}

impl DriverFailure {
    pub fn new(code: impl Into<String>, retryable: bool) -> Result<Self, RecordValidationError> {
        Ok(Self {
            code: FailureCode::new(code)?,
            retryable,
            kind: DriverFailureKind::Failure,
        })
    }

    pub fn credential_required() -> Self {
        Self {
            code: FailureCode::new("SSH_CREDENTIAL_REQUIRED")
                .expect("constant failure code is valid"),
            retryable: true,
            kind: DriverFailureKind::CredentialRequired,
        }
    }

    #[must_use]
    pub fn is_credential_required(&self) -> bool {
        self.kind == DriverFailureKind::CredentialRequired
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "outcome", content = "data", rename_all = "snake_case")]
pub enum DriveOutcome {
    Checkpoint(ComputerRecord),
    AwaitingHostKeyApproval(ComputerRecord),
    AwaitingIntent(ComputerRecord),
    AwaitingCredential(ComputerRecord),
    AwaitingExternal(ComputerRecord),
    Ready(ComputerRecord),
    Failed(ComputerRecord),
    RolledBack(ComputerRecord),
    Removed { id: Uuid },
}

pub struct ProvisioningEngine {
    store: ProvisioningStore,
}

impl ProvisioningEngine {
    #[must_use]
    pub fn new(store: ProvisioningStore) -> Self {
        Self { store }
    }

    pub fn create(&self, input: NewComputer) -> Result<ComputerRecord, ProvisioningError> {
        input.validate()?;
        let record = ComputerRecord::new(input, Utc::now());
        record.validate()?;
        self.store.insert(&record)?;
        Ok(record)
    }

    /// Idempotently create the durable Add Computer record under identities
    /// generated before the native invocation.  A retry after an ambiguous UI
    /// response reuses the exact record; reusing an id with different immutable
    /// input fails closed instead of silently targeting another machine.
    pub fn create_idempotent(
        &self,
        input: NewComputer,
        id: Uuid,
        intended_node_id: Uuid,
    ) -> Result<ComputerRecord, ProvisioningError> {
        input.validate()?;
        if id.is_nil() || intended_node_id.is_nil() {
            return Err(ProvisioningError::InvalidIdentity);
        }
        let record =
            ComputerRecord::new_with_identity(input.clone(), Utc::now(), id, intended_node_id);
        record.validate()?;
        match self.store.insert(&record) {
            Ok(()) => Ok(record),
            Err(StoreError::AlreadyExists(existing_id)) if existing_id == id => {
                let existing = self.store.get(id)?;
                if existing.intended_node_id != intended_node_id
                    || existing.display_name != input.display_name
                    || existing.endpoint != input.endpoint
                    || existing.ssh_authentication != input.ssh_authentication
                    || existing.configuration != input.configuration
                    || existing.credential_policy.remember_requested != input.remember_credential
                {
                    return Err(ProvisioningError::IdempotencyConflict);
                }
                Ok(existing)
            }
            Err(error) => Err(error.into()),
        }
    }

    pub fn get(&self, id: Uuid) -> Result<ComputerRecord, ProvisioningError> {
        Ok(self.store.get(id)?)
    }

    pub fn list(&self) -> Result<Vec<ComputerRecord>, ProvisioningError> {
        Ok(self.store.list()?)
    }

    pub fn approve_host_key(
        &self,
        id: Uuid,
        expected_revision: u64,
        expected_fingerprint: &str,
    ) -> Result<ComputerRecord, ProvisioningError> {
        let mut record = self.load_expected(id, expected_revision)?;
        if !matches!(record.state, ProvisioningState::HostKeyPending) {
            return Err(ProvisioningError::InvalidOperation(
                "host-key approval requires host_key_pending",
            ));
        }
        let observed = record
            .host_key
            .as_ref()
            .ok_or(ProvisioningError::InvalidOperation(
                "host key checkpoint is missing",
            ))?;
        if observed.fingerprint != expected_fingerprint {
            return Err(ProvisioningError::HostKeyApprovalMismatch);
        }
        record.host_key_approved_at = Some(Utc::now());
        Ok(self.store.save_cas(record, expected_revision)?)
    }

    pub fn request_intent(
        &self,
        id: Uuid,
        expected_revision: u64,
        intent: ProvisioningIntent,
    ) -> Result<ComputerRecord, ProvisioningError> {
        if intent == ProvisioningIntent::Continue {
            return Err(ProvisioningError::InvalidOperation(
                "continue is an internal intent",
            ));
        }
        let mut record = self.load_expected(id, expected_revision)?;
        if matches!(
            intent,
            ProvisioningIntent::Rollback | ProvisioningIntent::Remove
        ) {
            record.teardown_completed = false;
        }
        match intent {
            ProvisioningIntent::Resume
                if matches!(
                    record.state,
                    ProvisioningState::Failed { .. } | ProvisioningState::Ready
                ) =>
            {
                return Err(ProvisioningError::InvalidOperation(
                    "resume requires a non-terminal checkpoint",
                ))
            }
            ProvisioningIntent::Retry => match &record.state {
                ProvisioningState::Failed {
                    retryable: true, ..
                } => {}
                _ => {
                    return Err(ProvisioningError::InvalidOperation(
                        "retry requires a retryable failure",
                    ))
                }
            },
            ProvisioningIntent::Rollback | ProvisioningIntent::Remove => {}
            ProvisioningIntent::Continue | ProvisioningIntent::Resume => {}
        }
        record.intent = intent;
        Ok(self.store.save_cas(record, expected_revision)?)
    }

    /// Start an in-place repair of a fully managed worker without tearing down
    /// or rotating its controller identity. The new cycle reuses the approved
    /// SSH host key, discovered inventory, worker configuration, pairing, and
    /// current managed credential. Only the kit is staged again; the remote
    /// lifecycle script owns the binary/service transaction and must restore
    /// the old state if that transaction fails.
    pub fn begin_repair(
        &self,
        id: Uuid,
        expected_revision: u64,
    ) -> Result<ComputerRecord, ProvisioningError> {
        let mut record = self.load_expected(id, expected_revision)?;
        if !matches!(record.state, ProvisioningState::Ready)
            || record.pairing_id.is_none()
            || record.paired_node_id != Some(record.intended_node_id)
        {
            return Err(ProvisioningError::InvalidOperation(
                "repair requires a ready paired worker",
            ));
        }
        record.cycle = record
            .cycle
            .checked_add(1)
            .ok_or(ProvisioningError::CycleOverflow)?;
        record.state = ProvisioningState::CredentialStored;
        record.intent = ProvisioningIntent::Continue;
        record.teardown_completed = false;
        record.heartbeat_seen_at = None;
        record.smoke_run_binding = None;
        record.smoke_check_completed_at = None;
        record.format_version = COMPUTER_RECORD_FORMAT_VERSION;
        if record.credential_policy.state == CredentialState::Forgotten {
            // The Desktop boundary injects the one-shot SSH secret before it
            // calls this method. If none is present, the first remote action
            // stops at the normal credential-required boundary.
            record.credential_policy.state = CredentialState::SessionOnly;
        }
        Ok(self.store.save_cas(record, expected_revision)?)
    }

    pub fn forget_credential(
        &self,
        id: Uuid,
        expected_revision: u64,
        driver: &mut impl ProvisioningDriver,
    ) -> Result<ComputerRecord, ProvisioningError> {
        let mut record = self.load_expected(id, expected_revision)?;
        if !matches!(record.state, ProvisioningState::Ready) {
            return Err(ProvisioningError::InvalidOperation(
                "forget credential requires ready",
            ));
        }
        if record.ssh_authentication.method() != SshAuthenticationMethod::Password {
            return Err(ProvisioningError::InvalidOperation(
                "forget credential requires password authentication",
            ));
        }
        let request = driver_request(
            &record,
            ProvisioningAction::ForgetCredential,
            "forget_credential",
        );
        if let Err(failure) = driver.forget_credential(&request) {
            if failure.is_credential_required() {
                return Err(ProvisioningError::InvalidOperation(
                    "credential deletion boundary requested a credential",
                ));
            }
            return Err(ProvisioningError::Driver(failure));
        }
        record.credential_reference = None;
        record.credential_policy.remember_requested = false;
        record.credential_policy.state = CredentialState::Forgotten;
        Ok(self.store.save_cas(record, expected_revision)?)
    }

    pub fn drive_once(
        &self,
        id: Uuid,
        expected_revision: u64,
        driver: &mut impl ProvisioningDriver,
    ) -> Result<DriveOutcome, ProvisioningError> {
        let mut record = self.load_expected(id, expected_revision)?;

        match record.intent {
            ProvisioningIntent::Resume => {
                record.intent = ProvisioningIntent::Continue;
                return Ok(DriveOutcome::Checkpoint(
                    self.store.save_cas(record, expected_revision)?,
                ));
            }
            ProvisioningIntent::Retry => {
                let step = match &record.state {
                    ProvisioningState::Failed {
                        step,
                        retryable: true,
                        ..
                    } => *step,
                    _ => {
                        return Err(ProvisioningError::InvalidOperation(
                            "retry intent is inconsistent with state",
                        ))
                    }
                };
                record.state = ProvisioningState::from_step(step);
                record.intent = ProvisioningIntent::Continue;
                return Ok(DriveOutcome::Checkpoint(
                    self.store.save_cas(record, expected_revision)?,
                ));
            }
            ProvisioningIntent::Rollback => {
                if record.teardown_completed {
                    reset_after_rollback(&mut record)?;
                    return Ok(DriveOutcome::RolledBack(
                        self.store.save_cas(record, expected_revision)?,
                    ));
                }
                let request = driver_request(&record, ProvisioningAction::Rollback, "rollback");
                if let Err(failure) = driver.rollback(&request) {
                    if failure.is_credential_required() {
                        return self.persist_credential_required(record, expected_revision);
                    }
                    return self.persist_driver_failure(record, expected_revision, failure);
                }
                record.teardown_completed = true;
                return Ok(DriveOutcome::Checkpoint(
                    self.store.save_cas(record, expected_revision)?,
                ));
            }
            ProvisioningIntent::Remove => {
                if record.teardown_completed {
                    let request = driver_request(
                        &record,
                        ProvisioningAction::ForgetCredential,
                        "forget_credential",
                    );
                    driver
                        .forget_credential(&request)
                        .map_err(ProvisioningError::Driver)?;
                    self.store.delete_cas(id, expected_revision)?;
                    return Ok(DriveOutcome::Removed { id });
                }
                let request = driver_request(&record, ProvisioningAction::Remove, "remove");
                if let Err(failure) = driver.remove(&request) {
                    if failure.is_credential_required() {
                        return self.persist_credential_required(record, expected_revision);
                    }
                    return self.persist_driver_failure(record, expected_revision, failure);
                }
                record.teardown_completed = true;
                return Ok(DriveOutcome::Checkpoint(
                    self.store.save_cas(record, expected_revision)?,
                ));
            }
            ProvisioningIntent::Continue => {}
        }

        if matches!(record.state, ProvisioningState::Failed { .. }) {
            return Ok(DriveOutcome::AwaitingIntent(record));
        }
        if matches!(record.state, ProvisioningState::Ready) {
            return Ok(DriveOutcome::Ready(record));
        }
        if matches!(record.state, ProvisioningState::HostKeyPending)
            && record.host_key_approved_at.is_none()
        {
            return Ok(DriveOutcome::AwaitingHostKeyApproval(record));
        }

        let action = action_for_record(&record).ok_or(ProvisioningError::InvalidOperation(
            "no action exists for current checkpoint",
        ))?;
        let request = driver_request(&record, action, action.as_str());
        let completion = match driver.execute(&request) {
            Ok(completion) => completion,
            Err(failure) if failure.is_credential_required() => {
                return self.persist_credential_required(record, expected_revision)
            }
            Err(failure) => return self.persist_driver_failure(record, expected_revision, failure),
        };

        if matches!(completion, StepCompletion::Pending) {
            return Ok(DriveOutcome::AwaitingExternal(record));
        }

        if let Err(error) = apply_completion(&mut record, action, completion) {
            let code = match error {
                TransitionError::HostKeyChanged => "HOST_KEY_CHANGED",
                TransitionError::NodeIdentityMismatch => "NODE_ID_MISMATCH",
                TransitionError::PairingIdentityChanged => "PAIRING_ID_CHANGED",
                TransitionError::SmokeBindingInvalid => "SMOKE_BINDING_INVALID",
                TransitionError::InvalidCompletion => "INVALID_DRIVER_OUTCOME",
            };
            let failure = DriverFailure::new(code, false)?;
            return self.persist_driver_failure(record, expected_revision, failure);
        }

        let saved = self.store.save_cas(record, expected_revision)?;
        if matches!(saved.state, ProvisioningState::Ready) {
            Ok(DriveOutcome::Ready(saved))
        } else {
            Ok(DriveOutcome::Checkpoint(saved))
        }
    }

    /// Advance through immediately-completable checkpoints and stop at a GUI
    /// boundary (host-key approval, credential input, asynchronous controller
    /// polling, failure, rollback/remove completion, or ready). The bound
    /// prevents a faulty injected driver from monopolizing a Tauri command.
    pub fn drive_until_boundary(
        &self,
        id: Uuid,
        expected_revision: u64,
        driver: &mut impl ProvisioningDriver,
        maximum_steps: u8,
    ) -> Result<DriveOutcome, ProvisioningError> {
        if maximum_steps == 0 || maximum_steps > 64 {
            return Err(ProvisioningError::InvalidOperation(
                "maximum_steps must be in 1..=64",
            ));
        }
        let mut revision = expected_revision;
        let mut last_checkpoint = None;
        for _ in 0..maximum_steps {
            match self.drive_once(id, revision, driver)? {
                DriveOutcome::Checkpoint(record) => {
                    revision = record.revision;
                    last_checkpoint = Some(record);
                }
                boundary => return Ok(boundary),
            }
        }
        Ok(DriveOutcome::Checkpoint(last_checkpoint.ok_or(
            ProvisioningError::InvalidOperation("driver made no provisioning progress"),
        )?))
    }

    fn load_expected(
        &self,
        id: Uuid,
        expected_revision: u64,
    ) -> Result<ComputerRecord, ProvisioningError> {
        let record = self.store.get(id)?;
        if record.revision != expected_revision {
            return Err(StoreError::Conflict {
                expected: expected_revision,
                actual: Some(record.revision),
            }
            .into());
        }
        Ok(record)
    }

    fn persist_driver_failure(
        &self,
        mut record: ComputerRecord,
        expected_revision: u64,
        failure: DriverFailure,
    ) -> Result<DriveOutcome, ProvisioningError> {
        let step = record.state.active_step();
        // Authentication rejection is a durable credential-attention event,
        // not a generic retry.  Drop the stale vault reference in the same
        // CAS as the failed checkpoint so a corrected password supplied on
        // Retry is the only credential eligible for the next SSH attempt.
        if matches!(
            failure.code.as_str(),
            "SSH_AUTH_REJECTED" | "SSH_PRIVATE_KEY_REJECTED"
        ) {
            record.credential_policy.state = CredentialState::Pending;
            record.credential_reference = None;
        }
        record.state = ProvisioningState::Failed {
            step,
            code: failure.code,
            retryable: failure.retryable,
        };
        record.intent = ProvisioningIntent::Continue;
        Ok(DriveOutcome::Failed(
            self.store.save_cas(record, expected_revision)?,
        ))
    }

    fn persist_credential_required(
        &self,
        mut record: ComputerRecord,
        expected_revision: u64,
    ) -> Result<DriveOutcome, ProvisioningError> {
        if record.credential_policy.state == CredentialState::Stored {
            record.credential_policy.state = CredentialState::Pending;
            record.credential_reference = None;
            return Ok(DriveOutcome::AwaitingCredential(
                self.store.save_cas(record, expected_revision)?,
            ));
        }
        Ok(DriveOutcome::AwaitingCredential(record))
    }
}

fn driver_request<'a>(
    record: &'a ComputerRecord,
    action: ProvisioningAction,
    operation: &str,
) -> DriverRequest<'a> {
    DriverRequest {
        computer: record,
        action,
        operation_id: if matches!(
            action,
            ProvisioningAction::BeginSmokeCheck | ProvisioningAction::RunSmokeCheck
        ) {
            crate::canonical_smoke_operation_id(record.id, record.cycle)
        } else {
            operation_id(record, operation)
        },
    }
}

fn operation_id(record: &ComputerRecord, operation: &str) -> String {
    format!("{}:{}:{}", record.id, record.cycle, operation)
}

fn operation_id_for_action(record: &ComputerRecord, action: ProvisioningAction) -> String {
    if matches!(
        action,
        ProvisioningAction::BeginSmokeCheck | ProvisioningAction::RunSmokeCheck
    ) {
        crate::canonical_smoke_operation_id(record.id, record.cycle)
    } else {
        operation_id(record, action.as_str())
    }
}

fn action_for_step(step: ProvisioningStep) -> Option<ProvisioningAction> {
    match step {
        ProvisioningStep::Draft => Some(ProvisioningAction::BeginSsh),
        ProvisioningStep::SshConnecting => Some(ProvisioningAction::ProbeHostKey),
        ProvisioningStep::HostKeyPending => Some(ProvisioningAction::Authenticate),
        ProvisioningStep::Authenticated => Some(ProvisioningAction::BeginDiscovery),
        ProvisioningStep::Discovering => Some(ProvisioningAction::DiscoverAndStoreCredential),
        ProvisioningStep::CredentialStored => Some(ProvisioningAction::StageKit),
        ProvisioningStep::KitStaged => Some(ProvisioningAction::InstallWorker),
        ProvisioningStep::WorkerInstalled => Some(ProvisioningAction::IssueEnrollment),
        ProvisioningStep::EnrollmentIssued => Some(ProvisioningAction::ApplyEnrollment),
        ProvisioningStep::Paired => Some(ProvisioningAction::EnableService),
        ProvisioningStep::ServiceEnabled => Some(ProvisioningAction::AwaitHeartbeat),
        ProvisioningStep::HeartbeatSeen => Some(ProvisioningAction::BeginSmokeCheck),
        ProvisioningStep::SmokeCheck => Some(ProvisioningAction::RunSmokeCheck),
        ProvisioningStep::Ready => None,
    }
}

fn action_for_record(record: &ComputerRecord) -> Option<ProvisioningAction> {
    if record.state.active_step() == ProvisioningStep::SmokeCheck
        && record.smoke_run_binding.is_none()
    {
        // A legacy v1 process may have crashed after the old, unbound begin
        // marker. Re-enter prepare; never run or fabricate a binding.
        Some(ProvisioningAction::BeginSmokeCheck)
    } else if record.state.active_step() == ProvisioningStep::SmokeCheck
        && record.smoke_check_completed_at.is_some()
    {
        Some(ProvisioningAction::CleanupStaging)
    } else {
        action_for_step(record.state.active_step())
    }
}

fn apply_completion(
    record: &mut ComputerRecord,
    action: ProvisioningAction,
    completion: StepCompletion,
) -> Result<(), TransitionError> {
    match (action, completion) {
        (ProvisioningAction::BeginSsh, StepCompletion::SshStarted) => {
            record.state = ProvisioningState::SshConnecting;
        }
        (ProvisioningAction::ProbeHostKey, StepCompletion::HostKeyObserved(host_key)) => {
            host_key
                .validate()
                .map_err(|_| TransitionError::InvalidCompletion)?;
            if record
                .host_key
                .as_ref()
                .is_some_and(|existing| existing != &host_key)
            {
                return Err(TransitionError::HostKeyChanged);
            }
            record.host_key = Some(host_key);
            record.state = ProvisioningState::HostKeyPending;
        }
        (ProvisioningAction::Authenticate, StepCompletion::Authenticated) => {
            if record.host_key_approved_at.is_none() {
                return Err(TransitionError::InvalidCompletion);
            }
            record.state = ProvisioningState::Authenticated;
        }
        (
            ProvisioningAction::Authenticate,
            StepCompletion::AuthenticatedStored {
                credential_reference,
            },
        ) => {
            if record.host_key_approved_at.is_none() {
                return Err(TransitionError::InvalidCompletion);
            }
            if record
                .credential_reference
                .as_ref()
                .is_some_and(|existing| existing != &credential_reference)
            {
                return Err(TransitionError::InvalidCompletion);
            }
            record.credential_reference = Some(credential_reference);
            record.credential_policy.state = CredentialState::Stored;
            record.state = ProvisioningState::Authenticated;
        }
        (ProvisioningAction::Authenticate, StepCompletion::AuthenticatedSessionOnly) => {
            if record.host_key_approved_at.is_none() {
                return Err(TransitionError::InvalidCompletion);
            }
            record.credential_reference = None;
            record.credential_policy.state = CredentialState::SessionOnly;
            record.state = ProvisioningState::Authenticated;
        }
        (ProvisioningAction::BeginDiscovery, StepCompletion::DiscoveryStarted) => {
            record.state = ProvisioningState::Discovering;
        }
        (
            ProvisioningAction::DiscoverAndStoreCredential,
            StepCompletion::DiscoveryCompleted {
                inventory,
                credential_reference,
            },
        ) => {
            inventory
                .validate()
                .map_err(|_| TransitionError::InvalidCompletion)?;
            record.inventory = Some(inventory);
            record.credential_reference = Some(credential_reference);
            record.credential_policy.state = CredentialState::Stored;
            record.state = ProvisioningState::CredentialStored;
        }
        (
            ProvisioningAction::DiscoverAndStoreCredential,
            StepCompletion::DiscoveryCompletedSessionOnly { inventory },
        ) => {
            inventory
                .validate()
                .map_err(|_| TransitionError::InvalidCompletion)?;
            record.inventory = Some(inventory);
            record.credential_reference = None;
            record.credential_policy.state = CredentialState::SessionOnly;
            record.state = ProvisioningState::CredentialStored;
        }
        (ProvisioningAction::StageKit, StepCompletion::KitStaged) => {
            record.state = ProvisioningState::KitStaged;
        }
        (ProvisioningAction::InstallWorker, StepCompletion::WorkerInstalled) => {
            // A routine repair keeps the existing pairing and executes the
            // binary/config/service swap as one remote transaction. Its
            // PairedService receipt proves the service was re-enabled; require
            // a fresh controller heartbeat and managed smoke next. A new or
            // rolled-back install has no preserved pairing and follows the
            // normal enrollment path.
            record.state = if is_in_place_repair(record) {
                ProvisioningState::ServiceEnabled
            } else {
                ProvisioningState::WorkerInstalled
            };
        }
        (ProvisioningAction::IssueEnrollment, StepCompletion::EnrollmentIssued { pairing_id }) => {
            if pairing_id.is_nil() {
                return Err(TransitionError::InvalidCompletion);
            }
            if record
                .pairing_id
                .is_some_and(|existing| existing != pairing_id)
            {
                return Err(TransitionError::PairingIdentityChanged);
            }
            record.pairing_id = Some(pairing_id);
            record.state = ProvisioningState::EnrollmentIssued;
        }
        (
            ProvisioningAction::ApplyEnrollment | ProvisioningAction::AwaitPairing,
            StepCompletion::Paired { node_id },
        ) => {
            if node_id != record.intended_node_id {
                return Err(TransitionError::NodeIdentityMismatch);
            }
            record.paired_node_id = Some(node_id);
            record.state = ProvisioningState::Paired;
        }
        (ProvisioningAction::EnableService, StepCompletion::ServiceEnabled) => {
            record.state = ProvisioningState::ServiceEnabled;
        }
        (ProvisioningAction::AwaitHeartbeat, StepCompletion::HeartbeatObserved { observed_at }) => {
            record.heartbeat_seen_at = Some(observed_at);
            record.state = ProvisioningState::HeartbeatSeen;
        }
        (ProvisioningAction::BeginSmokeCheck, StepCompletion::SmokeCheckPrepared { binding }) => {
            record
                .validate_smoke_binding(&binding)
                .map_err(|_| TransitionError::SmokeBindingInvalid)?;
            record.format_version = COMPUTER_RECORD_FORMAT_VERSION;
            record.smoke_run_binding = Some(binding);
            record.smoke_check_completed_at = None;
            record.state = ProvisioningState::SmokeCheck;
        }
        (ProvisioningAction::RunSmokeCheck, StepCompletion::SmokeCheckPassed { completed_at }) => {
            let binding = record
                .smoke_run_binding
                .as_ref()
                .ok_or(TransitionError::SmokeBindingInvalid)?;
            record
                .validate_smoke_binding(binding)
                .map_err(|_| TransitionError::SmokeBindingInvalid)?;
            if completed_at < binding.plan.created_at {
                return Err(TransitionError::SmokeBindingInvalid);
            }
            record.smoke_check_completed_at = Some(completed_at);
            // Persist smoke success while remaining non-Ready.  The following
            // turn performs idempotent remote staging cleanup; this marker is
            // the crash/response-loss recovery discriminator.
            record.state = ProvisioningState::SmokeCheck;
        }
        (ProvisioningAction::CleanupStaging, StepCompletion::StagingCleaned) => {
            if record.smoke_check_completed_at.is_none() {
                return Err(TransitionError::InvalidCompletion);
            }
            record.state = ProvisioningState::Ready;
        }
        _ => return Err(TransitionError::InvalidCompletion),
    }
    Ok(())
}

fn is_in_place_repair(record: &ComputerRecord) -> bool {
    record.cycle > 0
        && record.pairing_id.is_some()
        && record.paired_node_id == Some(record.intended_node_id)
}

fn reset_after_rollback(record: &mut ComputerRecord) -> Result<(), ProvisioningError> {
    record.cycle = record
        .cycle
        .checked_add(1)
        .ok_or(ProvisioningError::CycleOverflow)?;
    record.state = ProvisioningState::Draft;
    record.intent = ProvisioningIntent::Continue;
    record.teardown_completed = false;
    record.inventory = None;
    if record.credential_policy.state == CredentialState::Forgotten {
        record.credential_policy.state = CredentialState::SessionOnly;
    }
    record.pairing_id = None;
    record.paired_node_id = None;
    record.heartbeat_seen_at = None;
    record.smoke_run_binding = None;
    record.smoke_check_completed_at = None;
    record.format_version = COMPUTER_RECORD_FORMAT_VERSION;
    // The full public host key and its explicit approval survive rollback. A
    // later probe must match it exactly, so repair cannot silently trust a new
    // server identity.
    Ok(())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum TransitionError {
    InvalidCompletion,
    HostKeyChanged,
    NodeIdentityMismatch,
    PairingIdentityChanged,
    SmokeBindingInvalid,
}

#[derive(Debug, Error)]
pub enum ProvisioningError {
    #[error(transparent)]
    Store(#[from] StoreError),
    #[error(transparent)]
    Validation(#[from] RecordValidationError),
    #[error("provisioning driver failed: {0:?}")]
    Driver(DriverFailure),
    #[error("invalid provisioning operation: {0}")]
    InvalidOperation(&'static str),
    #[error("host-key approval did not match the observed fingerprint")]
    HostKeyApprovalMismatch,
    #[error("Add Computer idempotency identity was reused with different input")]
    IdempotencyConflict,
    #[error("Add Computer idempotency identity is invalid")]
    InvalidIdentity,
    #[error("provisioning cycle overflow")]
    CycleOverflow,
}
