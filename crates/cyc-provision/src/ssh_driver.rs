use std::{fmt, sync::Arc};

use chrono::{DateTime, Utc};
use cyc_protocol::onboarding::EnrollmentBundleV1;
use cyc_protocol::SmokeRunBindingV1;
use cyc_secrets::{CredentialKey, CredentialVault, Secret, StoredCredential, VaultError};
use cyc_ssh::{
    CommandArgument, FixedCommand, HostKey, RemotePath, RemoteSession, SshEndpoint, SshError,
    SshTransport,
};
use thiserror::Error;
use uuid::Uuid;
use zeroize::Zeroizing;

use crate::{
    discovery::{parse_discovery, RemotePlatform, MAX_DISCOVERY_OUTPUT_BYTES},
    worker_kit::{sha256_hex, WorkerKit, WorkerKitCatalog, WorkerKitError, WorkerKitTarget},
    ComputerRecord, CredentialState, DriverFailure, DriverRequest, FailureCode,
    PinnedHostKeyRecord, ProvisioningAction, ProvisioningDriver, ProvisioningStep, StepCompletion,
};

const CREDENTIAL_NAMESPACE: &str = "ssh-password";
const MAX_LIFECYCLE_OUTPUT_BYTES: usize = 256 * 1024;

/// Tauri owns the lifetime of user-entered passwords and injects them through
/// this boundary. Implementations may retain a `Secret` in protected process
/// memory for a session, but must never expose it as a DTO or log field.
pub trait TransientSecretProvider: Send + Sync {
    fn retrieve(&self, computer_id: Uuid) -> Result<Option<Secret>, TransientSecretError>;
    /// Clears the transient value only when it is still the value that was
    /// used for this authentication attempt. A corrected password may be
    /// injected concurrently after an older attempt has started; that newer
    /// value must not be erased by the older attempt's completion.
    fn clear_if_matches(&self, computer_id: Uuid, expected: &Secret);
    fn clear(&self, computer_id: Uuid);
}

#[derive(Clone, Copy, Debug, Error, PartialEq, Eq)]
pub enum TransientSecretError {
    #[error("transient secret provider is unavailable")]
    Unavailable,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PairingObservation {
    Pending,
    /// The one-time credential has been consumed, but the controller has not
    /// published the paired node as ready yet. Enrollment material must not be
    /// replayed in this phase.
    Consumed,
    Paired {
        node_id: Uuid,
    },
}

/// Controller API boundary. `operation_id` is an idempotency key: repeated
/// calls for the same issue operation must return the exact pending bundle,
/// including the same `pairing_id` and intended node identity, until that
/// enrollment is consumed or revoked. Callers poll first and never request a
/// bundle once the controller reports `Consumed` or `Paired`.
pub trait ControllerBoundary: Send + Sync {
    fn issue_enrollment(
        &self,
        operation_id: &str,
        intended_node_id: Uuid,
        existing_pairing_id: Option<Uuid>,
    ) -> Result<EnrollmentBundleV1, ControllerBoundaryFailure>;

    fn poll_pairing(
        &self,
        pairing_id: Uuid,
        intended_node_id: Uuid,
    ) -> Result<PairingObservation, ControllerBoundaryFailure>;

    fn poll_heartbeat(
        &self,
        node_id: Uuid,
        received_after: DateTime<Utc>,
    ) -> Result<Option<DateTime<Utc>>, ControllerBoundaryFailure>;

    /// Idempotently plan and submit the canonical smoke job. Repeating this
    /// call for `operation_id` must return the exact same plan/job/run binding.
    fn prepare_smoke_check(
        &self,
        node_id: Uuid,
        operation_id: &str,
        job_id: Uuid,
    ) -> Result<SmokeRunBindingV1, ControllerBoundaryFailure>;

    /// Poll and verify only the already submitted run identified by `binding`.
    /// Implementations must not perform placement or submit a replacement job.
    fn run_smoke_check(
        &self,
        binding: &SmokeRunBindingV1,
    ) -> Result<Option<DateTime<Utc>>, ControllerBoundaryFailure>;

    fn revoke_pairing(
        &self,
        pairing_id: Uuid,
        operation_id: &str,
    ) -> Result<(), ControllerBoundaryFailure>;
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ControllerBoundaryFailure {
    pub code: FailureCode,
    pub retryable: bool,
}

impl ControllerBoundaryFailure {
    pub fn new(
        code: impl Into<String>,
        retryable: bool,
    ) -> Result<Self, crate::RecordValidationError> {
        Ok(Self {
            code: FailureCode::new(code)?,
            retryable,
        })
    }

    fn into_driver(self) -> DriverFailure {
        DriverFailure::new(self.code.as_str(), self.retryable)
            .expect("validated controller failure code remains valid")
    }
}

#[derive(Clone, Debug, Default)]
pub struct SshDriverOptions {
    /// `None` probes Linux then Windows with separately uploaded fixed scripts.
    pub discovery_platform_hint: Option<RemotePlatform>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum CredentialSource {
    Transient,
    Vault,
}

struct LoadedCredential {
    secret: Secret,
    source: CredentialSource,
}

pub struct SshProvisioningDriver {
    transport: Arc<dyn SshTransport>,
    vault: Arc<dyn CredentialVault>,
    transient_secrets: Arc<dyn TransientSecretProvider>,
    controller: Arc<dyn ControllerBoundary>,
    catalog: WorkerKitCatalog,
    options: SshDriverOptions,
}

impl fmt::Debug for SshProvisioningDriver {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SshProvisioningDriver")
            .field("catalog_root", &self.catalog.root())
            .field("options", &self.options)
            .finish_non_exhaustive()
    }
}

impl SshProvisioningDriver {
    #[must_use]
    pub fn new(
        transport: Arc<dyn SshTransport>,
        vault: Arc<dyn CredentialVault>,
        transient_secrets: Arc<dyn TransientSecretProvider>,
        controller: Arc<dyn ControllerBoundary>,
        catalog: WorkerKitCatalog,
        options: SshDriverOptions,
    ) -> Self {
        Self {
            transport,
            vault,
            transient_secrets,
            controller,
            catalog,
            options,
        }
    }

    fn probe_host_key(&self, record: &ComputerRecord) -> Result<StepCompletion, DriverFailure> {
        let endpoint = ssh_endpoint(record)?;
        let host_key = self
            .transport
            .probe_host_key(&endpoint)
            .map_err(map_ssh_error)?;
        Ok(StepCompletion::HostKeyObserved(PinnedHostKeyRecord::from(
            &host_key,
        )))
    }

    fn authenticate(&self, record: &ComputerRecord) -> Result<StepCompletion, DriverFailure> {
        if record.host_key_approved_at.is_none() {
            return Err(failure("HOST_KEY_NOT_APPROVED", false));
        }
        let credential = self.load_secret(record)?;
        let _session = self.connect_loaded(record, &credential, false)?;
        if record.credential_policy.remember_requested {
            let reference = self.store_authenticated_credential(record, &credential)?;
            Ok(StepCompletion::AuthenticatedStored {
                credential_reference: reference,
            })
        } else {
            Ok(StepCompletion::AuthenticatedSessionOnly)
        }
    }

    fn discover(&self, record: &ComputerRecord) -> Result<StepCompletion, DriverFailure> {
        let credential = self.load_secret(record)?;
        let platforms: &[RemotePlatform] = match self.options.discovery_platform_hint {
            Some(RemotePlatform::Linux) => &[RemotePlatform::Linux],
            Some(RemotePlatform::Windows) => &[RemotePlatform::Windows],
            None => &[RemotePlatform::Linux, RemotePlatform::Windows],
        };
        let mut last_failure = None;
        for platform in platforms {
            let attempt = self
                .connect_loaded(record, &credential, true)
                .and_then(|mut session| self.run_discovery(record, *platform, session.as_mut()));
            match attempt {
                Ok(inventory) => {
                    return if record.credential_policy.state == CredentialState::Stored {
                        let reference = record
                            .credential_reference
                            .clone()
                            .ok_or_else(DriverFailure::credential_required)?;
                        Ok(StepCompletion::DiscoveryCompleted {
                            inventory,
                            credential_reference: reference,
                        })
                    } else {
                        Ok(StepCompletion::DiscoveryCompletedSessionOnly { inventory })
                    };
                }
                Err(error) => last_failure = Some(error),
            }
        }
        Err(last_failure.unwrap_or_else(|| failure("DISCOVERY_FAILED", false)))
    }

    fn run_discovery(
        &self,
        record: &ComputerRecord,
        platform: RemotePlatform,
        session: &mut dyn RemoteSession,
    ) -> Result<crate::DiscoveredComputer, DriverFailure> {
        let layout = RemoteLayout::new(record, platform)?;
        session
            .create_dir(&layout.staging_dir, 0o700)
            .map_err(map_ssh_error)?;
        let script_path = layout.join(platform.discovery_file_name())?;
        upload_and_verify(session, &script_path, platform.discovery_script(), 0o700)?;
        let workspace = record.configuration.workspace.clone().unwrap_or_default();
        let argument = CommandArgument::new(workspace).map_err(map_ssh_error)?;
        let command = match platform {
            RemotePlatform::Linux => FixedCommand::posix_script(script_path, [argument]),
            RemotePlatform::Windows => {
                FixedCommand::windows_powershell_script(script_path, [argument])
            }
        };
        let output = session.exec_fixed(&command).map_err(map_ssh_error)?;
        if output.exit_code != 0 {
            return Err(failure("DISCOVERY_COMMAND_FAILED", true));
        }
        if output.stdout.len() > MAX_DISCOVERY_OUTPUT_BYTES {
            return Err(failure("DISCOVERY_OUTPUT_LIMIT", false));
        }
        parse_discovery(&output.stdout, platform)
            .map_err(|_| failure("DISCOVERY_OUTPUT_INVALID", false))
    }

    fn stage_kit(&self, record: &ComputerRecord) -> Result<StepCompletion, DriverFailure> {
        let inventory = record
            .inventory
            .as_ref()
            .ok_or_else(|| failure("INVENTORY_MISSING", false))?;
        let kit = self
            .catalog
            .load_for_inventory(inventory)
            .map_err(map_worker_kit_error)?;
        let platform = platform_for_target(kit.target());
        let layout = RemoteLayout::new(record, platform)?;
        let mut session = self.authenticated_session(record)?;
        upload_kit_to_session(session.as_mut(), &layout, &kit)?;
        Ok(StepCompletion::KitStaged)
    }

    fn install_worker(&self, record: &ComputerRecord) -> Result<StepCompletion, DriverFailure> {
        let kit = self.load_record_kit(record)?;
        let mut session = self.authenticated_session(record)?;
        let in_place_repair = record.cycle > 0
            && record.pairing_id.is_some()
            && record.paired_node_id == Some(record.intended_node_id);
        let (action, expectation) = if record.cycle == 0 {
            ("install", LifecycleReceiptExpectation::UnpairedPreinstall)
        } else if in_place_repair {
            // Routine repair preserves the existing worker credential and
            // invokes one remote transaction without an enrollment file or
            // PairOnly. The receipt must prove the paired service is running.
            ("repair", LifecycleReceiptExpectation::PairedService)
        } else {
            // A rollback/reinstall cycle has no live pairing yet and remains
            // dormant until the normal enrollment checkpoints complete.
            ("repair", LifecycleReceiptExpectation::DormantInstalled)
        };
        self.run_lifecycle(record, session.as_mut(), &kit, action, None, expectation)?;
        Ok(StepCompletion::WorkerInstalled)
    }

    fn issue_enrollment(
        &self,
        request: &DriverRequest<'_>,
    ) -> Result<StepCompletion, DriverFailure> {
        let record = request.computer;
        let bundle = self
            .controller
            .issue_enrollment(
                &request.operation_id,
                record.intended_node_id,
                record.pairing_id,
            )
            .map_err(ControllerBoundaryFailure::into_driver)?;
        bundle
            .validate()
            .map_err(|_| failure("ENROLLMENT_INVALID", false))?;
        if bundle.intended_node_id != record.intended_node_id
            || record
                .pairing_id
                .is_some_and(|pairing_id| pairing_id != bundle.pairing_id)
        {
            return Err(failure("ENROLLMENT_IDENTITY_MISMATCH", false));
        }

        // Deliberately do not touch SSH here. The engine must first persist
        // `pairing_id` as EnrollmentIssued. A crash anywhere before that CAS
        // simply replays this same controller operation and cannot leave an
        // untracked paired worker behind.
        Ok(StepCompletion::EnrollmentIssued {
            pairing_id: bundle.pairing_id,
        })
    }

    fn apply_enrollment(
        &self,
        request: &DriverRequest<'_>,
    ) -> Result<StepCompletion, DriverFailure> {
        let record = request.computer;
        let pairing_id = record
            .pairing_id
            .ok_or_else(|| failure("PAIRING_ID_MISSING", false))?;

        // Reconcile before replaying any one-time material. This is the crash
        // recovery gate for a worker that completed pairing after the SSH
        // command returned but before Desktop committed the Paired checkpoint.
        match self.observe_pairing(record, pairing_id)? {
            PairingObservation::Paired { node_id } => {
                return self.finish_pairing(record, pairing_id, node_id)
            }
            PairingObservation::Consumed => return Ok(StepCompletion::Pending),
            PairingObservation::Pending => {}
        }

        // Re-fetch the exact pending bundle under the original issue key. The
        // apply action's own id is never used to mint identity, which keeps the
        // controller pairing stable across Desktop restarts.
        let issue_operation_id = request.operation_id_for(ProvisioningAction::IssueEnrollment);
        let bundle = match self.controller.issue_enrollment(
            &issue_operation_id,
            record.intended_node_id,
            Some(pairing_id),
        ) {
            Ok(bundle) => bundle,
            Err(issue_failure) => {
                // Close the poll/replay race. If another attempt consumed the
                // credential between those calls, reconcile instead of
                // converting a successful remote pair into a failed record.
                return match self.observe_pairing(record, pairing_id)? {
                    PairingObservation::Paired { node_id } => {
                        self.finish_pairing(record, pairing_id, node_id)
                    }
                    PairingObservation::Consumed => Ok(StepCompletion::Pending),
                    PairingObservation::Pending => Err(issue_failure.into_driver()),
                };
            }
        };
        self.validate_enrollment_bundle(record, pairing_id, &bundle)?;
        self.apply_enrollment_bundle(record, &bundle)?;

        // Pairing may become Ready in the same controller transaction. Poll
        // again so the normal engine CAS can persist Paired immediately. If
        // controller acknowledgement is still in flight, remain at the
        // durable EnrollmentIssued checkpoint and reconcile on the next turn.
        match self.observe_pairing(record, pairing_id)? {
            PairingObservation::Paired { node_id } => {
                self.finish_pairing(record, pairing_id, node_id)
            }
            PairingObservation::Pending | PairingObservation::Consumed => {
                Ok(StepCompletion::Pending)
            }
        }
    }

    fn validate_enrollment_bundle(
        &self,
        record: &ComputerRecord,
        pairing_id: Uuid,
        bundle: &EnrollmentBundleV1,
    ) -> Result<(), DriverFailure> {
        bundle
            .validate()
            .map_err(|_| failure("ENROLLMENT_INVALID", false))?;
        if bundle.pairing_id != pairing_id || bundle.intended_node_id != record.intended_node_id {
            return Err(failure("ENROLLMENT_IDENTITY_MISMATCH", false));
        }
        Ok(())
    }

    fn apply_enrollment_bundle(
        &self,
        record: &ComputerRecord,
        bundle: &EnrollmentBundleV1,
    ) -> Result<(), DriverFailure> {
        let kit = self.load_record_kit(record)?;
        let platform = platform_for_target(kit.target());
        let layout = RemoteLayout::new(record, platform)?;
        let enrollment_path = layout.enrollment_path(bundle.pairing_id)?;
        let serialized = Zeroizing::new(
            serde_json::to_vec(bundle)
                .map_err(|_| failure("ENROLLMENT_SERIALIZE_FAILED", false))?,
        );
        let mut session = self.authenticated_session(record)?;
        session
            .create_dir(&layout.staging_dir, 0o700)
            .map_err(map_ssh_error)?;
        upload_receipt_only(session.as_mut(), &enrollment_path, &serialized, 0o600)?;
        self.run_lifecycle(
            record,
            session.as_mut(),
            &kit,
            "repair",
            Some(&enrollment_path),
            LifecycleReceiptExpectation::PairingOnly,
        )
    }

    fn observe_pairing(
        &self,
        record: &ComputerRecord,
        pairing_id: Uuid,
    ) -> Result<PairingObservation, DriverFailure> {
        self.controller
            .poll_pairing(pairing_id, record.intended_node_id)
            .map_err(ControllerBoundaryFailure::into_driver)
    }

    fn finish_pairing(
        &self,
        record: &ComputerRecord,
        pairing_id: Uuid,
        node_id: Uuid,
    ) -> Result<StepCompletion, DriverFailure> {
        self.remove_enrollment_file(record, pairing_id)?;
        Ok(StepCompletion::Paired { node_id })
    }

    fn enable_service(&self, record: &ComputerRecord) -> Result<StepCompletion, DriverFailure> {
        let kit = self.load_record_kit(record)?;
        let mut session = self.authenticated_session(record)?;
        self.run_lifecycle(
            record,
            session.as_mut(),
            &kit,
            "repair",
            None,
            LifecycleReceiptExpectation::PairedService,
        )?;
        Ok(StepCompletion::ServiceEnabled)
    }

    fn await_heartbeat(&self, record: &ComputerRecord) -> Result<StepCompletion, DriverFailure> {
        let node_id = record
            .paired_node_id
            .ok_or_else(|| failure("PAIRED_NODE_ID_MISSING", false))?;
        match self
            .controller
            .poll_heartbeat(node_id, record.updated_at)
            .map_err(ControllerBoundaryFailure::into_driver)?
        {
            // `updated_at` is the durable checkpoint written only after this
            // provisioning cycle successfully enabled the service. Reject an
            // old fleet timestamp even if a boundary implementation returns
            // it accidentally; pairing probes and a prior worker process must
            // not satisfy the fresh-daemon liveness gate.
            Some(observed_at) if observed_at > record.updated_at => {
                Ok(StepCompletion::HeartbeatObserved { observed_at })
            }
            Some(_) | None => Ok(StepCompletion::Pending),
        }
    }

    fn run_smoke_check(
        &self,
        request: &DriverRequest<'_>,
    ) -> Result<StepCompletion, DriverFailure> {
        let binding = request
            .computer
            .smoke_run_binding
            .as_ref()
            .ok_or_else(|| failure("SMOKE_BINDING_MISSING", false))?;
        request
            .computer
            .validate_smoke_binding(binding)
            .map_err(|_| failure("SMOKE_BINDING_INVALID", false))?;
        match self
            .controller
            .run_smoke_check(binding)
            .map_err(ControllerBoundaryFailure::into_driver)?
        {
            Some(completed_at) => Ok(StepCompletion::SmokeCheckPassed { completed_at }),
            None => Ok(StepCompletion::Pending),
        }
    }

    fn prepare_smoke_check(
        &self,
        request: &DriverRequest<'_>,
    ) -> Result<StepCompletion, DriverFailure> {
        let record = request.computer;
        let node_id = record
            .paired_node_id
            .ok_or_else(|| failure("PAIRED_NODE_ID_MISSING", false))?;
        let expected_operation_id = crate::canonical_smoke_operation_id(record.id, record.cycle);
        if request.operation_id != expected_operation_id {
            return Err(failure("SMOKE_OPERATION_ID_INVALID", false));
        }
        let job_id = crate::canonical_smoke_job_id(record.id, record.cycle);
        let binding = self
            .controller
            .prepare_smoke_check(node_id, &request.operation_id, job_id)
            .map_err(ControllerBoundaryFailure::into_driver)?;
        record
            .validate_smoke_binding(&binding)
            .map_err(|_| failure("SMOKE_BINDING_INVALID", false))?;
        Ok(StepCompletion::SmokeCheckPrepared { binding })
    }

    fn load_record_kit(&self, record: &ComputerRecord) -> Result<WorkerKit, DriverFailure> {
        self.catalog
            .load_for_inventory(
                record
                    .inventory
                    .as_ref()
                    .ok_or_else(|| failure("INVENTORY_MISSING", false))?,
            )
            .map_err(map_worker_kit_error)
    }

    fn run_lifecycle(
        &self,
        record: &ComputerRecord,
        session: &mut dyn RemoteSession,
        kit: &WorkerKit,
        action: &str,
        enrollment_path: Option<&RemotePath>,
        expectation: LifecycleReceiptExpectation,
    ) -> Result<(), DriverFailure> {
        let platform = platform_for_target(kit.target());
        let layout = RemoteLayout::new(record, platform)?;
        let lifecycle_path = layout.join(kit.lifecycle_name())?;
        let mut arguments = Vec::new();
        match platform {
            RemotePlatform::Linux => {
                arguments.push(argument(action)?);
                arguments.push(argument("--bundle-root")?);
                arguments.push(argument(layout.staging_dir.as_str())?);
                if let Some(workspace) = &record.configuration.workspace {
                    arguments.push(argument("--workspace-root")?);
                    arguments.push(argument(workspace)?);
                }
                arguments.push(argument("--scope")?);
                arguments.push(argument(record.configuration.service_scope.as_str())?);
                if record.configuration.allow_on_battery {
                    arguments.push(argument("--allow-on-battery")?);
                }
                if matches!(
                    expectation,
                    LifecycleReceiptExpectation::DormantInstalled
                        | LifecycleReceiptExpectation::PairingOnly
                ) {
                    arguments.push(argument("--pair-only")?);
                }
                if let Some(path) = enrollment_path {
                    arguments.push(argument("--enrollment")?);
                    arguments.push(argument(path.as_str())?);
                }
            }
            RemotePlatform::Windows => {
                arguments.push(argument("-Action")?);
                arguments.push(argument(match action {
                    "install" => "Install",
                    "repair" => "Repair",
                    "uninstall" => "Uninstall",
                    _ => return Err(failure("LIFECYCLE_ACTION_INVALID", false)),
                })?);
                arguments.push(argument("-BundleRoot")?);
                arguments.push(argument(layout.staging_dir.as_str())?);
                if let Some(workspace) = &record.configuration.workspace {
                    arguments.push(argument("-WorkspaceRoot")?);
                    arguments.push(argument(workspace)?);
                }
                arguments.push(argument("-Scope")?);
                arguments.push(argument(record.configuration.service_scope.as_str())?);
                if record.configuration.allow_on_battery {
                    arguments.push(argument("-AllowOnBattery")?);
                }
                if matches!(
                    expectation,
                    LifecycleReceiptExpectation::DormantInstalled
                        | LifecycleReceiptExpectation::PairingOnly
                ) {
                    arguments.push(argument("-PairOnly")?);
                }
                if let Some(path) = enrollment_path {
                    arguments.push(argument("-EnrollmentFile")?);
                    arguments.push(argument(path.as_str())?);
                }
            }
        }
        let command = match platform {
            RemotePlatform::Linux => FixedCommand::posix_script(lifecycle_path, arguments),
            RemotePlatform::Windows => {
                FixedCommand::windows_powershell_script(lifecycle_path, arguments)
            }
        };
        let output = session.exec_fixed(&command).map_err(map_ssh_error)?;
        if output.exit_code != 0 {
            return Err(failure("WORKER_LIFECYCLE_FAILED", true));
        }
        validate_lifecycle_receipt(&output.stdout, action, expectation)?;
        Ok(())
    }

    fn remove_enrollment_file(
        &self,
        record: &ComputerRecord,
        pairing_id: Uuid,
    ) -> Result<(), DriverFailure> {
        let target = WorkerKitTarget::from_inventory(
            record
                .inventory
                .as_ref()
                .ok_or_else(|| failure("INVENTORY_MISSING", false))?,
        )
        .map_err(map_worker_kit_error)?;
        let platform = platform_for_target(target);
        let layout = RemoteLayout::new(record, platform)?;
        let enrollment_path = layout.enrollment_path(pairing_id)?;
        let mut session = self.authenticated_session(record)?;
        run_cleanup_script(session.as_mut(), record, platform, "file", &enrollment_path)
    }

    fn cleanup_staging(&self, record: &ComputerRecord) -> Result<StepCompletion, DriverFailure> {
        if record.smoke_check_completed_at.is_none() {
            return Err(failure("SMOKE_CHECK_NOT_COMPLETED", false));
        }
        let target = WorkerKitTarget::from_inventory(
            record
                .inventory
                .as_ref()
                .ok_or_else(|| failure("INVENTORY_MISSING", false))?,
        )
        .map_err(map_worker_kit_error)?;
        let platform = platform_for_target(target);
        let layout = RemoteLayout::new(record, platform)?;
        let mut session = self.authenticated_session(record)?;
        // The cleanup helper lives outside the staging tree and tree removal
        // is idempotent on both platforms.  A response lost after deletion is
        // therefore reconciled by replaying this exact cycle-owned operation.
        run_cleanup_script(
            session.as_mut(),
            record,
            platform,
            "tree",
            &layout.staging_dir,
        )?;
        Ok(StepCompletion::StagingCleaned)
    }

    fn teardown(&self, request: &DriverRequest<'_>) -> Result<(), DriverFailure> {
        let record = request.computer;
        if record
            .state
            .active_step()
            .is_at_least(ProvisioningStep::CredentialStored)
        {
            let target = WorkerKitTarget::from_inventory(
                record
                    .inventory
                    .as_ref()
                    .ok_or_else(|| failure("INVENTORY_MISSING", false))?,
            )
            .map_err(map_worker_kit_error)?;
            let platform = platform_for_target(target);
            let layout = RemoteLayout::new(record, platform)?;
            let mut session = self.authenticated_session(record)?;
            if record
                .state
                .active_step()
                .is_at_least(ProvisioningStep::KitStaged)
            {
                let kit = self.load_record_kit(record)?;
                // Re-stage the verified exact kit before uninstall. A prior
                // crash may have happened after cleanup but before the durable
                // teardown checkpoint; re-staging makes the same operation
                // safe to execute again.
                upload_kit_to_session(session.as_mut(), &layout, &kit)?;
                self.run_lifecycle(
                    record,
                    session.as_mut(),
                    &kit,
                    "uninstall",
                    None,
                    LifecycleReceiptExpectation::Uninstall,
                )?;
            }
            run_cleanup_script(
                session.as_mut(),
                record,
                platform,
                "tree",
                &layout.staging_dir,
            )?;
        }
        if let Some(pairing_id) = record.pairing_id {
            self.controller
                .revoke_pairing(pairing_id, &request.operation_id)
                .map_err(ControllerBoundaryFailure::into_driver)?;
        }
        Ok(())
    }

    fn delete_credential(&self, record: &ComputerRecord) -> Result<(), DriverFailure> {
        let key = credential_key(record)?;
        self.vault.delete(&key).map_err(map_vault_delete_error)?;
        self.transient_secrets.clear(record.id);
        Ok(())
    }

    fn authenticated_session(
        &self,
        record: &ComputerRecord,
    ) -> Result<Box<dyn RemoteSession>, DriverFailure> {
        let credential = self.load_secret(record)?;
        self.connect_loaded(record, &credential, true)
    }

    fn connect_loaded(
        &self,
        record: &ComputerRecord,
        credential: &LoadedCredential,
        replace_stored_from_transient: bool,
    ) -> Result<Box<dyn RemoteSession>, DriverFailure> {
        let session = match self.connect(record, &credential.secret) {
            Ok(session) => session,
            Err(error) => {
                if error.code.as_str() == "SSH_AUTH_REJECTED" {
                    self.invalidate_rejected_credential(record, credential)?;
                }
                return Err(error);
            }
        };
        if replace_stored_from_transient
            && credential.source == CredentialSource::Transient
            && record.credential_policy.remember_requested
        {
            self.store_authenticated_credential(record, credential)?;
        }
        Ok(session)
    }

    fn store_authenticated_credential(
        &self,
        record: &ComputerRecord,
        credential: &LoadedCredential,
    ) -> Result<cyc_secrets::CredentialReference, DriverFailure> {
        let key = credential_key(record)?;
        let reference = self
            .vault
            .store(&key, &record.endpoint.username, &credential.secret)
            .map_err(map_vault_write_error)?;
        if reference != key.reference() {
            return Err(failure("CREDENTIAL_REFERENCE_MISMATCH", false));
        }
        if credential.source == CredentialSource::Transient {
            self.transient_secrets
                .clear_if_matches(record.id, &credential.secret);
        }
        Ok(reference)
    }

    fn invalidate_rejected_credential(
        &self,
        record: &ComputerRecord,
        credential: &LoadedCredential,
    ) -> Result<(), DriverFailure> {
        match credential.source {
            CredentialSource::Transient => self
                .transient_secrets
                .clear_if_matches(record.id, &credential.secret),
            CredentialSource::Vault => {
                let key = credential_key(record)?;
                self.vault.delete(&key).map_err(map_vault_delete_error)?;
            }
        }
        Ok(())
    }

    fn connect(
        &self,
        record: &ComputerRecord,
        secret: &Secret,
    ) -> Result<Box<dyn RemoteSession>, DriverFailure> {
        let endpoint = ssh_endpoint(record)?;
        let pinned = record
            .host_key
            .as_ref()
            .ok_or_else(|| failure("HOST_KEY_MISSING", false))?;
        let pinned = HostKey::try_from(pinned).map_err(|_| failure("HOST_KEY_INVALID", false))?;
        self.transport
            .connect_password(&endpoint, &pinned, &record.endpoint.username, secret)
            .map_err(map_ssh_error)
    }

    fn load_secret(&self, record: &ComputerRecord) -> Result<LoadedCredential, DriverFailure> {
        if let Some(secret) = self
            .transient_secrets
            .retrieve(record.id)
            .map_err(|_| failure("TRANSIENT_SECRET_PROVIDER_FAILED", true))?
        {
            return Ok(LoadedCredential {
                secret,
                source: CredentialSource::Transient,
            });
        }

        let key = credential_key(record)?;
        let expected_reference = key.reference();
        if record
            .credential_reference
            .as_ref()
            .is_some_and(|reference| reference != &expected_reference)
        {
            return Err(failure("CREDENTIAL_REFERENCE_MISMATCH", false));
        }

        let should_try_vault = record.credential_policy.state == CredentialState::Stored
            || (record.credential_policy.remember_requested
                && record.credential_policy.state == CredentialState::Pending);
        if should_try_vault {
            if let Some(stored) = self.vault.retrieve(&key).map_err(map_vault_read_error)? {
                return Ok(LoadedCredential {
                    secret: validate_stored_credential(record, stored)?,
                    source: CredentialSource::Vault,
                });
            }
        }
        Err(DriverFailure::credential_required())
    }
}

impl ProvisioningDriver for SshProvisioningDriver {
    fn execute(&mut self, request: &DriverRequest<'_>) -> Result<StepCompletion, DriverFailure> {
        match request.action {
            ProvisioningAction::BeginSsh => Ok(StepCompletion::SshStarted),
            ProvisioningAction::ProbeHostKey => self.probe_host_key(request.computer),
            ProvisioningAction::Authenticate => self.authenticate(request.computer),
            ProvisioningAction::BeginDiscovery => Ok(StepCompletion::DiscoveryStarted),
            ProvisioningAction::DiscoverAndStoreCredential => self.discover(request.computer),
            ProvisioningAction::StageKit => self.stage_kit(request.computer),
            ProvisioningAction::InstallWorker => self.install_worker(request.computer),
            ProvisioningAction::IssueEnrollment => self.issue_enrollment(request),
            ProvisioningAction::ApplyEnrollment | ProvisioningAction::AwaitPairing => {
                self.apply_enrollment(request)
            }
            ProvisioningAction::EnableService => self.enable_service(request.computer),
            ProvisioningAction::AwaitHeartbeat => self.await_heartbeat(request.computer),
            ProvisioningAction::BeginSmokeCheck => self.prepare_smoke_check(request),
            ProvisioningAction::RunSmokeCheck => self.run_smoke_check(request),
            ProvisioningAction::CleanupStaging => self.cleanup_staging(request.computer),
            ProvisioningAction::Rollback
            | ProvisioningAction::Remove
            | ProvisioningAction::ForgetCredential => Err(failure("DRIVER_ACTION_MISMATCH", false)),
        }
    }

    fn rollback(&mut self, request: &DriverRequest<'_>) -> Result<(), DriverFailure> {
        self.teardown(request)
    }

    fn remove(&mut self, request: &DriverRequest<'_>) -> Result<(), DriverFailure> {
        self.teardown(request)
    }

    fn forget_credential(&mut self, request: &DriverRequest<'_>) -> Result<(), DriverFailure> {
        self.delete_credential(request.computer)
    }
}

fn ssh_endpoint(record: &ComputerRecord) -> Result<SshEndpoint, DriverFailure> {
    SshEndpoint::new(record.endpoint.host.clone(), record.endpoint.port).map_err(map_ssh_error)
}

fn credential_key(record: &ComputerRecord) -> Result<CredentialKey, DriverFailure> {
    CredentialKey::new(CREDENTIAL_NAMESPACE, record.id.simple().to_string())
        .map_err(|_| failure("CREDENTIAL_KEY_INVALID", false))
}

fn validate_stored_credential(
    record: &ComputerRecord,
    credential: StoredCredential,
) -> Result<Secret, DriverFailure> {
    if credential.username != record.endpoint.username {
        return Err(failure("CREDENTIAL_USERNAME_MISMATCH", false));
    }
    Ok(credential.secret)
}

fn argument(value: impl Into<String>) -> Result<CommandArgument, DriverFailure> {
    CommandArgument::new(value).map_err(map_ssh_error)
}

fn platform_for_target(target: WorkerKitTarget) -> RemotePlatform {
    match target {
        WorkerKitTarget::WindowsX86_64 => RemotePlatform::Windows,
        WorkerKitTarget::LinuxX86_64 | WorkerKitTarget::LinuxAarch64 => RemotePlatform::Linux,
    }
}

struct RemoteLayout {
    platform: RemotePlatform,
    staging_dir: RemotePath,
}

impl RemoteLayout {
    fn new(record: &ComputerRecord, platform: RemotePlatform) -> Result<Self, DriverFailure> {
        let suffix = format!("{}-{}", record.id.simple(), record.cycle);
        let staging = match platform {
            RemotePlatform::Linux => {
                format!("/tmp/.clusteryourcodex-provision-{suffix}")
            }
            RemotePlatform::Windows => {
                format!("C:\\Windows\\Temp\\clusteryourcodex-provision-{suffix}")
            }
        };
        Ok(Self {
            platform,
            staging_dir: RemotePath::new(staging).map_err(map_ssh_error)?,
        })
    }

    fn join(&self, leaf: &str) -> Result<RemotePath, DriverFailure> {
        if leaf.is_empty()
            || leaf.contains(['/', '\\', '\0', '\r', '\n'])
            || matches!(leaf, "." | "..")
        {
            return Err(failure("REMOTE_PATH_INVALID", false));
        }
        let separator = match self.platform {
            RemotePlatform::Linux => "/",
            RemotePlatform::Windows => "\\",
        };
        RemotePath::new(format!("{}{separator}{leaf}", self.staging_dir.as_str()))
            .map_err(map_ssh_error)
    }

    fn enrollment_path(&self, pairing_id: Uuid) -> Result<RemotePath, DriverFailure> {
        self.join(&format!("enrollment-{}.json", pairing_id.simple()))
    }
}

fn cleanup_script_path(
    record: &ComputerRecord,
    platform: RemotePlatform,
) -> Result<RemotePath, DriverFailure> {
    let suffix = format!("{}-{}", record.id.simple(), record.cycle);
    let path = match platform {
        RemotePlatform::Linux => format!("/tmp/.clusteryourcodex-clean-{suffix}.sh"),
        RemotePlatform::Windows => {
            format!("C:\\Windows\\Temp\\clusteryourcodex-clean-{suffix}.ps1")
        }
    };
    RemotePath::new(path).map_err(map_ssh_error)
}

fn run_cleanup_script(
    session: &mut dyn RemoteSession,
    record: &ComputerRecord,
    platform: RemotePlatform,
    mode: &str,
    target: &RemotePath,
) -> Result<(), DriverFailure> {
    let script_path = cleanup_script_path(record, platform)?;
    let content = match platform {
        RemotePlatform::Linux => LINUX_CLEANUP_SCRIPT.as_bytes(),
        RemotePlatform::Windows => WINDOWS_CLEANUP_SCRIPT.as_bytes(),
    };
    upload_and_verify(session, &script_path, content, 0o700)?;
    let command = match platform {
        RemotePlatform::Linux => FixedCommand::posix_script(
            script_path.clone(),
            [argument(mode)?, argument(target.as_str())?],
        ),
        RemotePlatform::Windows => FixedCommand::windows_powershell_script(
            script_path.clone(),
            [argument(mode)?, argument(target.as_str())?],
        ),
    };
    let output = session.exec_fixed(&command).map_err(map_ssh_error)?;
    if output.exit_code != 0 {
        return Err(failure("REMOTE_CLEANUP_FAILED", true));
    }
    session.remove_file(&script_path).map_err(map_ssh_error)
}

fn upload_and_verify(
    session: &mut dyn RemoteSession,
    path: &RemotePath,
    content: &[u8],
    unix_mode: i32,
) -> Result<(), DriverFailure> {
    upload_receipt_only(session, path, content, unix_mode)?;
    let maximum = content
        .len()
        .checked_add(1)
        .ok_or_else(|| failure("REMOTE_FILE_TOO_LARGE", false))?;
    let downloaded = session
        .download_bytes(path, maximum)
        .map_err(map_ssh_error)?;
    if downloaded.len() != content.len() || sha256_hex(&downloaded) != sha256_hex(content) {
        return Err(failure("REMOTE_HASH_MISMATCH", true));
    }
    Ok(())
}

fn upload_kit_to_session(
    session: &mut dyn RemoteSession,
    layout: &RemoteLayout,
    kit: &WorkerKit,
) -> Result<(), DriverFailure> {
    session
        .create_dir(&layout.staging_dir, 0o700)
        .map_err(map_ssh_error)?;
    for file in kit.files() {
        if sha256_hex(&file.content) != file.sha256 {
            return Err(failure("KIT_LOCAL_HASH_CHANGED", false));
        }
        let path = layout.join(&file.name)?;
        upload_and_verify(session, &path, &file.content, file.unix_mode)?;
    }
    Ok(())
}

fn upload_receipt_only(
    session: &mut dyn RemoteSession,
    path: &RemotePath,
    content: &[u8],
    unix_mode: i32,
) -> Result<(), DriverFailure> {
    let receipt = session
        .upload_bytes(path, content, unix_mode)
        .map_err(map_ssh_error)?;
    if receipt.bytes != content.len() as u64 || receipt.sha256 != sha256_hex(content) {
        return Err(failure("REMOTE_RECEIPT_MISMATCH", true));
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum LifecycleReceiptExpectation {
    /// A first install must only place the owned binary and manifest. It must
    /// not start an unpaired worker before the one-time enrollment exists.
    UnpairedPreinstall,
    /// A repair cycle may encounter either preserved paired state or a clean
    /// preinstall, but it must keep the daemon dormant until a fresh pairing
    /// and the explicit service-enable checkpoint have succeeded.
    DormantInstalled,
    /// Enrollment activation must persist the paired worker config while
    /// deliberately leaving the daemon disabled until the separate
    /// service-enable checkpoint.
    PairingOnly,
    /// The service-enable checkpoint must prove that a paired service was
    /// actually enabled.
    PairedService,
    /// Uninstall receipts intentionally omit pairing/service state.
    Uninstall,
}

fn validate_lifecycle_receipt(
    content: &[u8],
    expected_action: &str,
    expectation: LifecycleReceiptExpectation,
) -> Result<(), DriverFailure> {
    if content.is_empty() || content.len() > MAX_LIFECYCLE_OUTPUT_BYTES {
        return Err(failure("LIFECYCLE_RECEIPT_INVALID", false));
    }
    let text =
        std::str::from_utf8(content).map_err(|_| failure("LIFECYCLE_RECEIPT_INVALID", false))?;
    let line = text
        .lines()
        .rev()
        .find(|line| !line.trim().is_empty())
        .ok_or_else(|| failure("LIFECYCLE_RECEIPT_INVALID", false))?;
    let value: serde_json::Value =
        serde_json::from_str(line).map_err(|_| failure("LIFECYCLE_RECEIPT_INVALID", false))?;
    let object = value
        .as_object()
        .ok_or_else(|| failure("LIFECYCLE_RECEIPT_INVALID", false))?;
    const ALLOWED: &[&str] = &[
        "schemaVersion",
        "action",
        "succeeded",
        "paired",
        "service",
        "serviceEnabled",
        "scope",
        "allowOnBattery",
        "version",
        "alreadyAbsent",
        "dataPreserved",
    ];
    if object.keys().any(|key| !ALLOWED.contains(&key.as_str()))
        || object.get("succeeded").and_then(serde_json::Value::as_bool) != Some(true)
        || object.get("action").and_then(serde_json::Value::as_str) != Some(expected_action)
        || object
            .get("schemaVersion")
            .and_then(serde_json::Value::as_str)
            .is_none_or(|value| {
                !matches!(
                    value,
                    "cyc.dev/linux-worker-install/v1" | "cyc.dev/windows-worker-install/v1"
                )
            })
    {
        return Err(failure("LIFECYCLE_RECEIPT_INVALID", false));
    }

    let paired = object.get("paired").and_then(serde_json::Value::as_bool);
    let service = object.get("service").and_then(serde_json::Value::as_str);
    let service_enabled = object
        .get("serviceEnabled")
        .and_then(serde_json::Value::as_bool);
    let service_is_valid = service.is_some_and(|value| {
        !value.is_empty()
            && value.len() <= 128
            && value.bytes().all(|byte| {
                byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'_' | b'-')
            })
    });
    let expectation_satisfied = match expectation {
        LifecycleReceiptExpectation::UnpairedPreinstall => {
            paired == Some(false)
                && service == Some("not_enabled")
                && service_enabled.is_none_or(|value| !value)
        }
        LifecycleReceiptExpectation::DormantInstalled => {
            matches!(paired, Some(false) | Some(true))
                && service == Some("not_enabled")
                && service_enabled == Some(false)
        }
        LifecycleReceiptExpectation::PairingOnly => {
            paired == Some(true) && service == Some("not_enabled") && service_enabled == Some(false)
        }
        LifecycleReceiptExpectation::PairedService => {
            paired == Some(true)
                && service_is_valid
                && service != Some("not_enabled")
                && service_enabled.is_none_or(|value| value)
        }
        LifecycleReceiptExpectation::Uninstall => paired.is_none() && service.is_none(),
    };
    if !expectation_satisfied {
        return Err(failure("LIFECYCLE_RECEIPT_INVALID", false));
    }
    Ok(())
}

fn map_ssh_error(error: SshError) -> DriverFailure {
    match error {
        SshError::Authentication { .. } | SshError::AuthenticationRejected => {
            failure("SSH_AUTH_REJECTED", true)
        }
        SshError::HostKeyMismatch { .. } => failure("HOST_KEY_CHANGED", false),
        SshError::UnsupportedHostKeyAlgorithm => failure("HOST_KEY_UNSUPPORTED", false),
        SshError::HostKeyUnavailable => failure("HOST_KEY_UNAVAILABLE", true),
        SshError::InvalidEndpoint
        | SshError::InvalidUsername
        | SshError::PasswordNotUtf8
        | SshError::InvalidRemotePath
        | SshError::InvalidCommandArgument
        | SshError::InvalidTransportLimits
        | SshError::NoResolvedAddress => failure("SSH_CONFIGURATION_INVALID", false),
        SshError::RemotePathNotDirectory => failure("SSH_REMOTE_PATH_CONFLICT", false),
        SshError::OutputLimitExceeded { .. } => failure("SSH_OUTPUT_LIMIT", false),
        SshError::CommandOutputTimedOut { .. } | SshError::Io(_) | SshError::Protocol(_) => {
            failure("SSH_IO", true)
        }
    }
}

fn map_worker_kit_error(error: WorkerKitError) -> DriverFailure {
    match error {
        WorkerKitError::UnsupportedTarget => failure("KIT_TARGET_UNSUPPORTED", false),
        WorkerKitError::InvalidCatalogRoot => failure("KIT_ROOT_INVALID", false),
        WorkerKitError::Io(_) => failure("KIT_IO", true),
        WorkerKitError::UnsafeEntry
        | WorkerKitError::UnexpectedFileSet
        | WorkerKitError::InvalidManifest
        | WorkerKitError::InvalidChecksums
        | WorkerKitError::DigestMismatch => failure("KIT_TAMPERED", false),
    }
}

fn map_vault_read_error(_error: VaultError) -> DriverFailure {
    failure("CREDENTIAL_VAULT_READ_FAILED", true)
}

fn map_vault_write_error(_error: VaultError) -> DriverFailure {
    failure("CREDENTIAL_VAULT_WRITE_FAILED", true)
}

fn map_vault_delete_error(_error: VaultError) -> DriverFailure {
    failure("CREDENTIAL_VAULT_DELETE_FAILED", true)
}

fn failure(code: &str, retryable: bool) -> DriverFailure {
    DriverFailure::new(code, retryable).expect("constant driver failure code is valid")
}

const LINUX_CLEANUP_SCRIPT: &str = r#"#!/bin/sh
set -eu
umask 077
mode="${1:-}"
target="${2:-}"
case "$target" in /tmp/.clusteryourcodex-provision-*) ;; *) exit 2 ;; esac
case "$mode" in
  file) rm -f -- "$target" ;;
  tree) if [ -d "$target" ] && [ ! -L "$target" ]; then rm -rf -- "$target"; fi ;;
  *) exit 2 ;;
esac
"#;

const WINDOWS_CLEANUP_SCRIPT: &str = r#"param([string]$Mode, [string]$Target)
$ErrorActionPreference = 'Stop'
$full = [IO.Path]::GetFullPath($Target)
$prefix = [IO.Path]::GetFullPath((Join-Path $env:WINDIR 'Temp\clusteryourcodex-provision-'))
if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid cleanup target.' }
switch ($Mode) {
    'file' { if (Test-Path -LiteralPath $full -PathType Leaf) { Remove-Item -LiteralPath $full -Force } }
    'tree' {
        if (Test-Path -LiteralPath $full -PathType Container) {
            $item = Get-Item -LiteralPath $full -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Refusing reparse point.' }
            Remove-Item -LiteralPath $full -Recurse -Force
        }
    }
    default { throw 'Invalid cleanup mode.' }
}
"#;

#[cfg(test)]
mod tests {
    use std::{
        collections::{BTreeMap, HashMap},
        fs,
        sync::atomic::{AtomicBool, AtomicU8, Ordering},
        sync::{Arc, Mutex},
    };

    use base64::{engine::general_purpose::STANDARD, Engine as _};
    use chrono::{DateTime, Duration, Utc};
    use cyc_protocol::onboarding::{EnrollmentBundleV1, ENROLLMENT_API_VERSION};
    use cyc_protocol::{
        PlacementCandidateExplain, PlacementExplain, PlacementPlanBindingV1,
        PlacementPlanDecisionV1, PlacementPolicy, ScoreComponent, SmokeRunBindingV1,
        PLACEMENT_PLAN_BINDING_API_VERSION,
    };
    use cyc_secrets::{
        CredentialKey, CredentialReference, CredentialVault, Secret, StoredCredential, VaultError,
    };
    use cyc_ssh::{
        CommandOutput, FixedCommand, HostKey, RemotePath, RemoteSession, SshEndpoint, SshError,
        SshTransport, TransferReceipt,
    };
    use ed25519_dalek::{Signer, SigningKey};
    use sha2::{Digest, Sha256};
    use tempfile::TempDir;
    use uuid::Uuid;

    use super::{
        sha256_hex, validate_lifecycle_receipt, ControllerBoundary, ControllerBoundaryFailure,
        LifecycleReceiptExpectation, PairingObservation, RemotePlatform, SshDriverOptions,
        SshProvisioningDriver, TransientSecretError, TransientSecretProvider, WorkerKitCatalog,
    };
    use crate::{
        ComputerEndpoint, CredentialState, DriveOutcome, DriverRequest, NewComputer,
        ProvisioningAction, ProvisioningDriver, ProvisioningEngine, ProvisioningState,
        ProvisioningStep, ProvisioningStore, StepCompletion,
    };

    const FIXTURE_SIGNING_SEED: [u8; 32] = [
        0x9d, 0x61, 0xb1, 0x9d, 0xef, 0xfd, 0x5a, 0x60, 0xba, 0x84, 0x4a, 0xf4, 0x92, 0xec, 0x2c,
        0xc4, 0x44, 0x49, 0xc5, 0x69, 0x7b, 0x32, 0x69, 0x19, 0x70, 0x3b, 0xac, 0x03, 0x1c, 0xae,
        0x7f, 0x60,
    ];

    const GOOD_PASSWORD: &str = "good-password-value";
    const BAD_PASSWORD: &str = "bad-password-must-never-persist";
    const PAIRING_SECRET: &str = "0123456789abcdef0123456789abcdef";
    const PAIRING_PENDING: u8 = 0;
    const PAIRING_CONSUMED: u8 = 1;
    const PAIRING_READY: u8 = 2;

    #[test]
    fn lifecycle_receipts_enforce_preinstall_and_activation_boundaries() {
        let preinstall = br#"{"schemaVersion":"cyc.dev/linux-worker-install/v1","action":"install","succeeded":true,"paired":false,"service":"not_enabled"}
"#;
        validate_lifecycle_receipt(
            preinstall,
            "install",
            LifecycleReceiptExpectation::UnpairedPreinstall,
        )
        .unwrap();
        assert!(validate_lifecycle_receipt(
            preinstall,
            "install",
            LifecycleReceiptExpectation::PairedService,
        )
        .is_err());

        let paired_only = br#"{"schemaVersion":"cyc.dev/windows-worker-install/v1","action":"repair","succeeded":true,"paired":true,"service":"not_enabled","serviceEnabled":false,"scope":"system","allowOnBattery":false}
"#;
        validate_lifecycle_receipt(
            paired_only,
            "repair",
            LifecycleReceiptExpectation::PairingOnly,
        )
        .unwrap();
        assert!(validate_lifecycle_receipt(
            paired_only,
            "repair",
            LifecycleReceiptExpectation::PairedService,
        )
        .is_err());

        let activated = br#"{"schemaVersion":"cyc.dev/windows-worker-install/v1","action":"repair","succeeded":true,"paired":true,"service":"scheduled_task","serviceEnabled":true,"scope":"system","allowOnBattery":false}
"#;
        validate_lifecycle_receipt(
            activated,
            "repair",
            LifecycleReceiptExpectation::PairedService,
        )
        .unwrap();
        assert!(validate_lifecycle_receipt(
            br#"{"schemaVersion":"cyc.dev/windows-worker-install/v1","action":"repair","succeeded":true,"paired":true,"service":"not_enabled"}
"#,
            "repair",
            LifecycleReceiptExpectation::PairedService,
        )
        .is_err());
        assert!(validate_lifecycle_receipt(
            br#"{"schemaVersion":"cyc.dev/windows-worker-install/v1","action":"repair","succeeded":true}
"#,
            "repair",
            LifecycleReceiptExpectation::PairedService,
        )
        .is_err());
    }

    struct Harness {
        _kits: TempDir,
        catalog: WorkerKitCatalog,
        ssh: Arc<FakeSshTransport>,
        vault: Arc<FakeVault>,
        transient: Arc<FakeTransientSecrets>,
        controller: Arc<FakeController>,
    }

    impl Harness {
        fn new(password: &str) -> Self {
            let kits = kit_fixture();
            let fixture_publisher = SigningKey::from_bytes(&FIXTURE_SIGNING_SEED);
            let catalog = WorkerKitCatalog::with_trusted_publisher(
                kits.path(),
                "cyc-test-fixture-rfc8032-1",
                fixture_publisher.verifying_key().to_bytes(),
            )
            .unwrap();
            let pairing_phase = Arc::new(AtomicU8::new(PAIRING_PENDING));
            Self {
                _kits: kits,
                catalog,
                ssh: Arc::new(FakeSshTransport::new(GOOD_PASSWORD, pairing_phase.clone())),
                vault: Arc::new(FakeVault::default()),
                transient: Arc::new(FakeTransientSecrets::new(Some(password))),
                controller: Arc::new(FakeController::new(pairing_phase)),
            }
        }

        fn driver(&self) -> SshProvisioningDriver {
            SshProvisioningDriver::new(
                self.ssh.clone(),
                self.vault.clone(),
                self.transient.clone(),
                self.controller.clone(),
                self.catalog.clone(),
                SshDriverOptions {
                    discovery_platform_hint: Some(RemotePlatform::Linux),
                },
            )
        }

        fn driver_with_transient(
            &self,
            transient: Arc<FakeTransientSecrets>,
        ) -> SshProvisioningDriver {
            SshProvisioningDriver::new(
                self.ssh.clone(),
                self.vault.clone(),
                transient,
                self.controller.clone(),
                self.catalog.clone(),
                SshDriverOptions {
                    discovery_platform_hint: Some(RemotePlatform::Linux),
                },
            )
        }
    }

    #[test]
    fn full_real_driver_sequence_is_ordered_idempotent_and_redacted() {
        let harness = Harness::new(GOOD_PASSWORD);
        let engine = ProvisioningEngine::new(ProvisioningStore::in_memory().unwrap());
        let created = engine.create(new_computer(true)).unwrap();

        let connecting = drive_one(&engine, created.id, &harness);
        assert_eq!(
            connecting.state.active_step(),
            ProvisioningStep::SshConnecting
        );
        let pending = drive_one(&engine, created.id, &harness);
        assert!(matches!(pending.state, ProvisioningState::HostKeyPending));
        assert_eq!(harness.transient.retrieval_count(), 0);
        assert_eq!(harness.vault.store_count(), 0);
        let direct_auth = DriverRequest {
            computer: &pending,
            action: ProvisioningAction::Authenticate,
            operation_id: "direct-unapproved-auth-must-fail".to_owned(),
        };
        let error = harness.driver().execute(&direct_auth).unwrap_err();
        assert_eq!(error.code.as_str(), "HOST_KEY_NOT_APPROVED");
        assert_eq!(harness.transient.retrieval_count(), 0);
        let fingerprint = pending.host_key.as_ref().unwrap().fingerprint.clone();
        engine
            .approve_host_key(pending.id, pending.revision, &fingerprint)
            .unwrap();

        let ready = drive_to(&engine, created.id, &harness, ProvisioningStep::Ready);
        assert_eq!(ready.credential_policy.state, CredentialState::Stored);
        assert!(ready.credential_reference.is_some());
        assert_eq!(ready.paired_node_id, Some(ready.intended_node_id));
        let durable_binding = ready.smoke_run_binding.as_ref().expect("smoke binding");
        let prepares = harness.controller.smoke_prepare_calls();
        assert_eq!(prepares.len(), 1);
        assert_eq!(
            prepares[0],
            (
                crate::canonical_smoke_operation_id(ready.id, ready.cycle),
                ready.intended_node_id,
                crate::canonical_smoke_job_id(ready.id, ready.cycle),
            )
        );
        assert_eq!(
            harness.controller.smoke_run_bindings(),
            vec![durable_binding.clone()]
        );
        assert_eq!(harness.vault.store_count(), 1);
        assert!(harness.ssh.enrollment_was_uploaded());

        let events = harness.ssh.events();
        let probe_index = events
            .iter()
            .position(|event| event == "probe_host_key")
            .unwrap();
        let auth_index = events
            .iter()
            .position(|event| event.starts_with("authenticate:"))
            .unwrap();
        assert!(probe_index < auth_index);
        assert!(events.iter().all(|event| !event.contains(GOOD_PASSWORD)));
        assert!(events.iter().all(|event| !event.contains(PAIRING_SECRET)));
        assert!(harness
            .ssh
            .private_directory_modes()
            .iter()
            .all(|mode| *mode == 0o700));

        let serialized = serde_json::to_string(&ready).unwrap();
        assert!(!serialized.contains(GOOD_PASSWORD));
        assert!(!serialized.contains(PAIRING_SECRET));
        let driver_debug = format!("{:?}", harness.driver());
        assert!(!driver_debug.contains(GOOD_PASSWORD));
        assert!(!driver_debug.contains(PAIRING_SECRET));

        let mut driver = harness.driver();
        let forgotten = engine
            .forget_credential(ready.id, ready.revision, &mut driver)
            .unwrap();
        assert_eq!(
            forgotten.credential_policy.state,
            CredentialState::Forgotten
        );
        assert!(!forgotten.credential_policy.remember_requested);
        assert!(forgotten.credential_reference.is_none());
        assert_eq!(harness.vault.delete_count(), 1);
        assert_eq!(harness.controller.revoke_count(), 0);
    }

    #[test]
    fn issue_crash_before_checkpoint_replays_identity_then_checkpoints_before_ssh() {
        let harness = Harness::new(GOOD_PASSWORD);
        let database = TempDir::new().unwrap();
        let database_path = database.path().join("provision.sqlite3");
        let engine = ProvisioningEngine::new(ProvisioningStore::open(&database_path).unwrap());
        let created = engine.create(new_computer(true)).unwrap();
        approve_when_pending(&engine, created.id, &harness);
        let installed = drive_to(
            &engine,
            created.id,
            &harness,
            ProvisioningStep::WorkerInstalled,
        );
        let request = DriverRequest {
            computer: &installed,
            action: ProvisioningAction::IssueEnrollment,
            operation_id: format!("{}:{}:issue_enrollment", installed.id, installed.cycle),
        };
        let mut first_driver = harness.driver();
        let first = first_driver.execute(&request).unwrap();
        let first_id = match first {
            StepCompletion::EnrollmentIssued { pairing_id } => pairing_id,
            other => panic!("unexpected completion: {other:?}"),
        };
        assert!(!harness.ssh.enrollment_was_uploaded());
        assert_eq!(harness.ssh.pairing_apply_count(), 0);

        // Simulate process loss after the controller returned the bundle but
        // before the engine committed EnrollmentIssued.
        drop(engine);
        let restarted = ProvisioningEngine::new(ProvisioningStore::open(&database_path).unwrap());
        let checkpoint = drive_one(&restarted, created.id, &harness);
        assert_eq!(checkpoint.state, ProvisioningState::EnrollmentIssued);
        assert_eq!(checkpoint.pairing_id, Some(first_id));
        assert_eq!(harness.controller.unique_pairing_count(), 1);
        assert!(!harness.ssh.enrollment_was_uploaded());
        assert_eq!(harness.ssh.distinct_enrollment_paths(), 0);

        let ready = drive_to(&restarted, created.id, &harness, ProvisioningStep::Ready);
        assert_eq!(ready.pairing_id, Some(first_id));
        assert_eq!(ready.paired_node_id, Some(ready.intended_node_id));
        assert_eq!(harness.ssh.pairing_apply_count(), 1);
        assert_eq!(harness.ssh.distinct_enrollment_paths(), 1);
    }

    #[test]
    fn remote_pair_crash_before_paired_cas_reconciles_without_reapplying_identity() {
        let harness = Harness::new(GOOD_PASSWORD);
        let database = TempDir::new().unwrap();
        let database_path = database.path().join("provision.sqlite3");
        let engine = ProvisioningEngine::new(ProvisioningStore::open(&database_path).unwrap());
        let created = engine.create(new_computer(true)).unwrap();
        approve_when_pending(&engine, created.id, &harness);
        let issued = drive_to(
            &engine,
            created.id,
            &harness,
            ProvisioningStep::EnrollmentIssued,
        );
        let pairing_id = issued.pairing_id.expect("durable pairing id");
        assert_eq!(harness.ssh.pairing_apply_count(), 0);

        // Execute the remote effect directly, then deliberately skip the
        // engine CAS to inject a crash at the precise audit window.
        let request = DriverRequest {
            computer: &issued,
            action: ProvisioningAction::ApplyEnrollment,
            operation_id: format!("{}:{}:apply_enrollment", issued.id, issued.cycle),
        };
        let completion = harness.driver().execute(&request).unwrap();
        assert_eq!(
            completion,
            StepCompletion::Paired {
                node_id: issued.intended_node_id
            }
        );
        assert_eq!(harness.ssh.pairing_apply_count(), 1);
        let not_checkpointed = engine.get(created.id).unwrap();
        assert_eq!(not_checkpointed.state, ProvisioningState::EnrollmentIssued);
        assert_eq!(not_checkpointed.pairing_id, Some(pairing_id));
        assert!(not_checkpointed.paired_node_id.is_none());

        drop(engine);
        let restarted = ProvisioningEngine::new(ProvisioningStore::open(&database_path).unwrap());
        let ready = drive_to(&restarted, created.id, &harness, ProvisioningStep::Ready);
        assert_eq!(ready.pairing_id, Some(pairing_id));
        assert_eq!(ready.paired_node_id, Some(issued.intended_node_id));
        assert_eq!(harness.controller.unique_pairing_count(), 1);
        assert_eq!(harness.ssh.pairing_apply_count(), 1);
        assert_eq!(harness.ssh.distinct_enrollment_paths(), 1);
    }

    #[test]
    fn consumed_pairing_waits_for_controller_ready_without_ssh_replay() {
        let harness = Harness::new(GOOD_PASSWORD);
        let engine = ProvisioningEngine::new(ProvisioningStore::in_memory().unwrap());
        let created = engine.create(new_computer(true)).unwrap();
        approve_when_pending(&engine, created.id, &harness);
        let issued = drive_to(
            &engine,
            created.id,
            &harness,
            ProvisioningStep::EnrollmentIssued,
        );
        harness.controller.set_pairing_consumed();

        let waiting = drive_one(&engine, created.id, &harness);
        assert_eq!(waiting.revision, issued.revision);
        assert_eq!(waiting.state, ProvisioningState::EnrollmentIssued);
        assert_eq!(waiting.pairing_id, issued.pairing_id);
        assert_eq!(harness.ssh.pairing_apply_count(), 0);
        assert!(!harness.ssh.enrollment_was_uploaded());
    }

    #[test]
    fn heartbeat_must_be_received_after_the_current_service_enable_checkpoint() {
        let harness = Harness::new(GOOD_PASSWORD);
        let engine = ProvisioningEngine::new(ProvisioningStore::in_memory().unwrap());
        let created = engine.create(new_computer(true)).unwrap();
        approve_when_pending(&engine, created.id, &harness);
        let enabled = drive_to(
            &engine,
            created.id,
            &harness,
            ProvisioningStep::ServiceEnabled,
        );

        harness.controller.set_stale_heartbeat(true);
        let waiting = drive_one(&engine, enabled.id, &harness);
        assert_eq!(
            waiting.state.active_step(),
            ProvisioningStep::ServiceEnabled
        );
        assert!(waiting.heartbeat_seen_at.is_none());

        harness.controller.set_stale_heartbeat(false);
        let observed = drive_one(&engine, enabled.id, &harness);
        assert_eq!(
            observed.state.active_step(),
            ProvisioningStep::HeartbeatSeen
        );
        assert!(observed
            .heartbeat_seen_at
            .is_some_and(|seen| seen > enabled.updated_at));
    }

    #[test]
    fn bad_password_is_never_written_to_vault_database_or_diagnostics() {
        let harness = Harness::new(BAD_PASSWORD);
        let database = TempDir::new().unwrap();
        let database_path = database.path().join("provision.sqlite3");
        let engine = ProvisioningEngine::new(ProvisioningStore::open(&database_path).unwrap());
        let created = engine.create(new_computer(true)).unwrap();
        approve_when_pending(&engine, created.id, &harness);
        let before = engine.get(created.id).unwrap();
        let mut driver = harness.driver();
        let outcome = engine
            .drive_once(before.id, before.revision, &mut driver)
            .unwrap();
        let failed = match outcome {
            DriveOutcome::Failed(record) => record,
            other => panic!("unexpected outcome: {other:?}"),
        };
        assert!(matches!(failed.state, ProvisioningState::Failed { .. }));
        assert_eq!(harness.vault.store_count(), 0);
        assert!(harness.vault.is_empty());
        assert!(!serde_json::to_string(&failed)
            .unwrap()
            .contains(BAD_PASSWORD));
        assert!(harness
            .ssh
            .events()
            .iter()
            .all(|event| !event.contains(BAD_PASSWORD)));
        drop(engine);
        let database_bytes = fs::read(database_path).unwrap();
        assert!(!database_bytes
            .windows(BAD_PASSWORD.len())
            .any(|window| window == BAD_PASSWORD.as_bytes()));
    }

    #[test]
    fn corrected_password_retry_reuses_the_checkpoint_and_reaches_ready_without_restart() {
        let harness = Harness::new(BAD_PASSWORD);
        let engine = ProvisioningEngine::new(ProvisioningStore::in_memory().unwrap());
        let created = engine.create(new_computer(true)).unwrap();
        approve_when_pending(&engine, created.id, &harness);

        let failed = drive_one(&engine, created.id, &harness);
        assert!(matches!(
            failed.state,
            ProvisioningState::Failed {
                retryable: true,
                ..
            }
        ));
        assert_eq!(failed.credential_policy.state, CredentialState::Pending);
        assert!(failed.credential_reference.is_none());
        assert!(harness.vault.is_empty());

        let retry = engine
            .request_intent(failed.id, failed.revision, crate::ProvisioningIntent::Retry)
            .expect("credential retry intent");
        let corrected = Arc::new(FakeTransientSecrets::new(Some(GOOD_PASSWORD)));
        let mut current = retry;
        for _ in 0..64 {
            let mut driver = harness.driver_with_transient(corrected.clone());
            current = outcome_record(
                engine
                    .drive_once(current.id, current.revision, &mut driver)
                    .expect("corrected retry drive"),
            );
            if current.state == ProvisioningState::Ready {
                break;
            }
            assert!(
                !matches!(current.state, ProvisioningState::Failed { .. }),
                "corrected password must not fail again: {:?}",
                current.state
            );
        }

        assert_eq!(current.state, ProvisioningState::Ready);
        assert_eq!(current.credential_policy.state, CredentialState::Stored);
        assert!(current.credential_reference.is_some());
        assert_eq!(harness.vault.store_count(), 1);
        assert!(corrected.retrieval_count() >= 1);
    }

    #[test]
    fn session_only_crash_resumes_at_explicit_credential_boundary() {
        let harness = Harness::new(GOOD_PASSWORD);
        let database = TempDir::new().unwrap();
        let database_path = database.path().join("provision.sqlite3");
        let engine = ProvisioningEngine::new(ProvisioningStore::open(&database_path).unwrap());
        let created = engine.create(new_computer(false)).unwrap();
        approve_when_pending(&engine, created.id, &harness);
        let authenticated = drive_to(
            &engine,
            created.id,
            &harness,
            ProvisioningStep::Authenticated,
        );
        assert_eq!(
            authenticated.credential_policy.state,
            CredentialState::SessionOnly
        );
        assert!(authenticated.credential_reference.is_none());
        assert_eq!(harness.vault.store_count(), 0);
        drop(engine);

        let restarted = ProvisioningEngine::new(ProvisioningStore::open(&database_path).unwrap());
        let empty_transient = Arc::new(FakeTransientSecrets::new(None));
        let mut driver = harness.driver_with_transient(empty_transient);
        let current = restarted.get(created.id).unwrap();
        let discovery_started = outcome_record(
            restarted
                .drive_once(current.id, current.revision, &mut driver)
                .unwrap(),
        );
        assert_eq!(
            discovery_started.state.active_step(),
            ProvisioningStep::Discovering
        );
        let outcome = restarted
            .drive_once(
                discovery_started.id,
                discovery_started.revision,
                &mut driver,
            )
            .unwrap();
        let waiting = match outcome {
            DriveOutcome::AwaitingCredential(record) => record,
            other => panic!("unexpected outcome: {other:?}"),
        };
        assert_eq!(waiting.state.active_step(), ProvisioningStep::Discovering);
        assert_eq!(
            waiting.credential_policy.state,
            CredentialState::SessionOnly
        );
        assert!(!matches!(waiting.state, ProvisioningState::Failed { .. }));
    }

    #[test]
    fn remember_false_can_reach_ready_without_ever_storing_a_password() {
        let harness = Harness::new(GOOD_PASSWORD);
        let engine = ProvisioningEngine::new(ProvisioningStore::in_memory().unwrap());
        let created = engine.create(new_computer(false)).unwrap();
        approve_when_pending(&engine, created.id, &harness);
        let ready = drive_to(&engine, created.id, &harness, ProvisioningStep::Ready);
        assert_eq!(ready.credential_policy.state, CredentialState::SessionOnly);
        assert!(!ready.credential_policy.remember_requested);
        assert!(ready.credential_reference.is_none());
        assert_eq!(harness.vault.store_count(), 0);
        assert!(harness.vault.is_empty());
    }

    #[test]
    fn successful_add_and_in_place_repair_remove_each_cycle_staging_tree() {
        let harness = Harness::new(GOOD_PASSWORD);
        let fixture_kit = harness
            .catalog
            .load_target(crate::worker_kit::WorkerKitTarget::LinuxX86_64)
            .expect("signed SSH fixture kit must load");
        assert_eq!(fixture_kit.files().len(), 5);
        let engine = ProvisioningEngine::new(ProvisioningStore::in_memory().unwrap());
        let created = engine.create(new_computer(true)).unwrap();
        approve_when_pending(&engine, created.id, &harness);

        let ready = drive_to(&engine, created.id, &harness, ProvisioningStep::Ready);
        assert_eq!(ready.cycle, 0);
        assert_eq!(harness.ssh.staging_file_count(), 0);
        assert_eq!(harness.ssh.tree_cleanup_count(), 1);

        let repairing = engine
            .begin_repair(ready.id, ready.revision)
            .expect("begin in-place repair");
        assert_eq!(repairing.intended_node_id, ready.intended_node_id);
        assert_eq!(repairing.paired_node_id, ready.paired_node_id);
        let repaired = drive_to(&engine, ready.id, &harness, ProvisioningStep::Ready);
        assert_eq!(repaired.cycle, 1);
        assert_eq!(repaired.intended_node_id, ready.intended_node_id);
        assert_eq!(repaired.paired_node_id, ready.paired_node_id);
        assert_eq!(harness.ssh.staging_file_count(), 0);
        assert_eq!(harness.ssh.tree_cleanup_count(), 2);
    }

    #[test]
    fn cleanup_response_loss_never_publishes_ready_and_replays_idempotently_after_restart() {
        let harness = Harness::new(GOOD_PASSWORD);
        let database = TempDir::new().unwrap();
        let database_path = database.path().join("provision.sqlite3");
        let engine = ProvisioningEngine::new(ProvisioningStore::open(&database_path).unwrap());
        let created = engine.create(new_computer(true)).unwrap();
        approve_when_pending(&engine, created.id, &harness);
        let smoke_passed = drive_to_smoke_pass(&engine, created.id, &harness);
        assert_eq!(smoke_passed.state, ProvisioningState::SmokeCheck);
        assert!(smoke_passed.smoke_check_completed_at.is_some());
        assert!(harness.ssh.staging_file_count() > 0);

        harness.ssh.lose_next_cleanup_response();
        let failed = drive_one(&engine, created.id, &harness);
        assert!(matches!(
            &failed.state,
            ProvisioningState::Failed {
                step: ProvisioningStep::SmokeCheck,
                retryable: true,
                ..
            }
        ));
        assert!(failed.smoke_check_completed_at.is_some());
        assert_eq!(harness.ssh.staging_file_count(), 0);
        assert_eq!(harness.ssh.tree_cleanup_count(), 1);
        drop(engine);

        let restarted = ProvisioningEngine::new(ProvisioningStore::open(&database_path).unwrap());
        let retry = restarted
            .request_intent(failed.id, failed.revision, crate::ProvisioningIntent::Retry)
            .expect("request cleanup retry");
        let checkpoint = drive_one(&restarted, retry.id, &harness);
        assert_eq!(checkpoint.state, ProvisioningState::SmokeCheck);
        assert!(checkpoint.smoke_check_completed_at.is_some());
        let ready = drive_one(&restarted, checkpoint.id, &harness);
        assert_eq!(ready.state, ProvisioningState::Ready);
        assert!(ready.smoke_check_completed_at.is_some());
        assert_eq!(harness.ssh.staging_file_count(), 0);
        assert_eq!(harness.ssh.tree_cleanup_count(), 2);
    }

    #[test]
    fn rollback_and_remove_have_durable_idempotent_remote_checkpoints() {
        let harness = Harness::new(GOOD_PASSWORD);
        let engine = ProvisioningEngine::new(ProvisioningStore::in_memory().unwrap());
        let created = engine.create(new_computer(true)).unwrap();
        approve_when_pending(&engine, created.id, &harness);
        let ready = drive_to(&engine, created.id, &harness, ProvisioningStep::Ready);
        let intended_node_id = ready.intended_node_id;
        let rollback = engine
            .request_intent(
                ready.id,
                ready.revision,
                crate::ProvisioningIntent::Rollback,
            )
            .unwrap();
        let request = DriverRequest {
            computer: &rollback,
            action: ProvisioningAction::Rollback,
            operation_id: format!("{}:{}:rollback", rollback.id, rollback.cycle),
        };
        let mut first = harness.driver();
        first.rollback(&request).unwrap();
        let mut after_crash = harness.driver();
        after_crash.rollback(&request).unwrap();

        let rollback_checkpoint = drive_one(&engine, created.id, &harness);
        assert!(rollback_checkpoint.teardown_completed);
        assert_eq!(
            rollback_checkpoint.intent,
            crate::ProvisioningIntent::Rollback
        );
        let rolled_back = drive_one(&engine, created.id, &harness);
        assert_eq!(rolled_back.state, ProvisioningState::Draft);
        assert_eq!(rolled_back.cycle, 1);
        assert_eq!(rolled_back.intended_node_id, intended_node_id);
        assert_eq!(rolled_back.credential_policy.state, CredentialState::Stored);
        assert!(rolled_back.credential_reference.is_some());

        let repaired = drive_to(&engine, created.id, &harness, ProvisioningStep::Ready);
        assert_eq!(repaired.intended_node_id, intended_node_id);
        let remove = engine
            .request_intent(
                repaired.id,
                repaired.revision,
                crate::ProvisioningIntent::Remove,
            )
            .unwrap();
        let remove_checkpoint = drive_one(&engine, remove.id, &harness);
        assert!(remove_checkpoint.teardown_completed);
        assert_eq!(remove_checkpoint.intent, crate::ProvisioningIntent::Remove);
        let mut driver = harness.driver();
        let removed = engine
            .drive_once(
                remove_checkpoint.id,
                remove_checkpoint.revision,
                &mut driver,
            )
            .unwrap();
        assert_eq!(removed, DriveOutcome::Removed { id: created.id });
        assert!(harness.vault.is_empty());
    }

    fn new_computer(remember: bool) -> NewComputer {
        let mut input = NewComputer::new(
            "Linux Worker",
            ComputerEndpoint::new("worker.example.invalid", 22, "worker").unwrap(),
        )
        .unwrap();
        input.remember_credential = remember;
        input
    }

    fn approve_when_pending(engine: &ProvisioningEngine, id: Uuid, harness: &Harness) {
        loop {
            let record = engine.get(id).unwrap();
            if matches!(record.state, ProvisioningState::HostKeyPending) {
                let fingerprint = record.host_key.as_ref().unwrap().fingerprint.clone();
                engine
                    .approve_host_key(record.id, record.revision, &fingerprint)
                    .unwrap();
                return;
            }
            let _ = drive_one(engine, id, harness);
        }
    }

    fn drive_to(
        engine: &ProvisioningEngine,
        id: Uuid,
        harness: &Harness,
        target: ProvisioningStep,
    ) -> crate::ComputerRecord {
        for _ in 0..64 {
            let record = engine.get(id).unwrap();
            if record.state.active_step() == target
                && !matches!(record.state, ProvisioningState::Failed { .. })
            {
                return record;
            }
            if matches!(record.state, ProvisioningState::HostKeyPending)
                && record.host_key_approved_at.is_none()
            {
                let fingerprint = record.host_key.as_ref().unwrap().fingerprint.clone();
                engine
                    .approve_host_key(record.id, record.revision, &fingerprint)
                    .unwrap();
                continue;
            }
            let result = drive_one(engine, id, harness);
            if matches!(result.state, ProvisioningState::Failed { .. }) {
                panic!("unexpected driver failure: {:?}", result.state);
            }
        }
        panic!("did not reach {target:?}")
    }

    fn drive_to_smoke_pass(
        engine: &ProvisioningEngine,
        id: Uuid,
        harness: &Harness,
    ) -> crate::ComputerRecord {
        for _ in 0..64 {
            let record = engine.get(id).unwrap();
            if matches!(record.state, ProvisioningState::SmokeCheck)
                && record.smoke_check_completed_at.is_some()
            {
                return record;
            }
            if matches!(record.state, ProvisioningState::HostKeyPending)
                && record.host_key_approved_at.is_none()
            {
                let fingerprint = record.host_key.as_ref().unwrap().fingerprint.clone();
                engine
                    .approve_host_key(record.id, record.revision, &fingerprint)
                    .unwrap();
                continue;
            }
            let result = drive_one(engine, id, harness);
            if matches!(result.state, ProvisioningState::Failed { .. }) {
                panic!("unexpected driver failure: {:?}", result.state);
            }
        }
        panic!("did not reach durable smoke-pass cleanup checkpoint")
    }

    fn drive_one(
        engine: &ProvisioningEngine,
        id: Uuid,
        harness: &Harness,
    ) -> crate::ComputerRecord {
        let record = engine.get(id).unwrap();
        let mut driver = harness.driver();
        outcome_record(
            engine
                .drive_once(record.id, record.revision, &mut driver)
                .unwrap(),
        )
    }

    fn outcome_record(outcome: DriveOutcome) -> crate::ComputerRecord {
        match outcome {
            DriveOutcome::Checkpoint(record)
            | DriveOutcome::AwaitingHostKeyApproval(record)
            | DriveOutcome::AwaitingIntent(record)
            | DriveOutcome::AwaitingCredential(record)
            | DriveOutcome::AwaitingExternal(record)
            | DriveOutcome::Ready(record)
            | DriveOutcome::Failed(record)
            | DriveOutcome::RolledBack(record) => record,
            DriveOutcome::Removed { .. } => panic!("record removed"),
        }
    }

    fn kit_fixture() -> TempDir {
        let root = TempDir::new().unwrap();
        let directory = root.path().join("linux-x86_64");
        fs::create_dir(&directory).unwrap();
        let worker = b"fixture-worker";
        let lifecycle = b"#!/bin/sh\nexit 0\n";
        fs::write(directory.join("cyc-worker"), worker).unwrap();
        fs::write(directory.join("install-worker.sh"), lifecycle).unwrap();
        let manifest_bytes = format!(
            concat!(
                "{{\"schemaVersion\":\"cyc.dev/worker-kit/v1\",",
                "\"product\":\"ClusterYourCodex Managed Worker\",",
                "\"version\":\"0.1.0-test.1\",",
                "\"target\":\"linux-x86_64\",",
                "\"os\":\"linux\",",
                "\"architecture\":\"x86_64\",",
                "\"files\":[",
                "{{\"path\":\"cyc-worker\",\"sizeBytes\":{},\"sha256\":\"{}\",\"role\":\"worker\"}},",
                "{{\"path\":\"install-worker.sh\",\"sizeBytes\":{},\"sha256\":\"{}\",\"role\":\"lifecycle\"}}",
                "]}}\n"
            ),
            worker.len(),
            sha256_hex(worker),
            lifecycle.len(),
            sha256_hex(lifecycle)
        )
        .into_bytes();
        fs::write(directory.join("worker-kit.json"), &manifest_bytes).unwrap();
        let signing_key = SigningKey::from_bytes(&FIXTURE_SIGNING_SEED);
        let signature = signing_key.sign(&manifest_bytes);
        let signature_bytes = format!(
            concat!(
                "{{\"schemaVersion\":\"cyc.dev/worker-kit-signature/v1\",",
                "\"algorithm\":\"Ed25519\",",
                "\"keyId\":\"cyc-test-fixture-rfc8032-1\",",
                "\"signedObject\":\"worker-kit.json\",",
                "\"manifestSha256\":\"{}\",",
                "\"signature\":\"{}\"}}\n"
            ),
            sha256_hex(&manifest_bytes),
            STANDARD.encode(signature.to_bytes())
        )
        .into_bytes();
        fs::write(directory.join("worker-kit.sig"), &signature_bytes).unwrap();
        fs::write(
            directory.join("SHA256SUMS"),
            format!(
                "{}  cyc-worker\n{}  install-worker.sh\n{}  worker-kit.json\n{}  worker-kit.sig\n",
                sha256_hex(worker),
                sha256_hex(lifecycle),
                sha256_hex(&manifest_bytes),
                sha256_hex(&signature_bytes)
            ),
        )
        .unwrap();
        root
    }

    struct FakeSshTransport {
        inner: Arc<Mutex<FakeSshState>>,
        host_key: HostKey,
        accepted_password_hash: [u8; 32],
        pairing_phase: Arc<AtomicU8>,
    }

    #[derive(Default)]
    struct FakeSshState {
        events: Vec<String>,
        files: HashMap<String, Vec<u8>>,
        private_directory_modes: Vec<i32>,
        enrollment_paths: Vec<String>,
        enrollment_uploaded: bool,
        pairing_apply_count: usize,
        paired: bool,
        tree_cleanup_count: usize,
        cleanup_response_loss_once: bool,
    }

    impl FakeSshTransport {
        fn new(password: &str, pairing_phase: Arc<AtomicU8>) -> Self {
            Self {
                inner: Arc::new(Mutex::new(FakeSshState::default())),
                host_key: HostKey::from_parts("ssh-ed25519", vec![1, 2, 3, 4]).unwrap(),
                accepted_password_hash: Sha256::digest(password.as_bytes()).into(),
                pairing_phase,
            }
        }

        fn events(&self) -> Vec<String> {
            self.inner.lock().unwrap().events.clone()
        }

        fn private_directory_modes(&self) -> Vec<i32> {
            self.inner.lock().unwrap().private_directory_modes.clone()
        }

        fn enrollment_was_uploaded(&self) -> bool {
            self.inner.lock().unwrap().enrollment_uploaded
        }

        fn distinct_enrollment_paths(&self) -> usize {
            self.inner
                .lock()
                .unwrap()
                .enrollment_paths
                .iter()
                .collect::<std::collections::BTreeSet<_>>()
                .len()
        }

        fn pairing_apply_count(&self) -> usize {
            self.inner.lock().unwrap().pairing_apply_count
        }

        fn staging_file_count(&self) -> usize {
            self.inner
                .lock()
                .unwrap()
                .files
                .keys()
                .filter(|path| path.contains("clusteryourcodex-provision-"))
                .count()
        }

        fn tree_cleanup_count(&self) -> usize {
            self.inner.lock().unwrap().tree_cleanup_count
        }

        fn lose_next_cleanup_response(&self) {
            self.inner.lock().unwrap().cleanup_response_loss_once = true;
        }
    }

    impl SshTransport for FakeSshTransport {
        fn probe_host_key(&self, _endpoint: &SshEndpoint) -> Result<HostKey, SshError> {
            self.inner
                .lock()
                .unwrap()
                .events
                .push("probe_host_key".to_owned());
            Ok(self.host_key.clone())
        }

        fn connect_password(
            &self,
            _endpoint: &SshEndpoint,
            pinned_host_key: &HostKey,
            _username: &str,
            password: &Secret,
        ) -> Result<Box<dyn RemoteSession>, SshError> {
            if pinned_host_key != &self.host_key {
                return Err(SshError::HostKeyMismatch {
                    expected: pinned_host_key.fingerprint().to_owned(),
                    actual: self.host_key.fingerprint().to_owned(),
                });
            }
            let observed: [u8; 32] = Sha256::digest(password.expose_secret()).into();
            self.inner
                .lock()
                .unwrap()
                .events
                .push(format!("authenticate:{}", password.len()));
            if observed != self.accepted_password_hash {
                return Err(SshError::AuthenticationRejected);
            }
            Ok(Box::new(FakeSession {
                inner: self.inner.clone(),
                pairing_phase: self.pairing_phase.clone(),
            }))
        }
    }

    struct FakeSession {
        inner: Arc<Mutex<FakeSshState>>,
        pairing_phase: Arc<AtomicU8>,
    }

    impl RemoteSession for FakeSession {
        fn exec_fixed(&mut self, command: &FixedCommand) -> Result<CommandOutput, SshError> {
            let (path, arguments) = match command {
                FixedCommand::PosixScript {
                    remote_path,
                    arguments,
                }
                | FixedCommand::WindowsPowerShellScript {
                    remote_path,
                    arguments,
                } => (remote_path.as_str(), arguments),
            };
            if path.ends_with("cyc-discovery.sh") || path.ends_with("cyc-discovery.ps1") {
                return Ok(CommandOutput {
                    exit_code: 0,
                    stdout: discovery_payload(),
                    stderr: Vec::new(),
                });
            }
            if path.contains("clusteryourcodex-clean-") {
                let mode = arguments.first().map(|value| value.as_str()).unwrap_or("");
                let target = arguments.get(1).map(|value| value.as_str()).unwrap_or("");
                let mut state = self.inner.lock().unwrap();
                match mode {
                    "file" => {
                        state.files.remove(target);
                    }
                    "tree" => {
                        state.files.retain(|path, _| !path.starts_with(target));
                        state.tree_cleanup_count += 1;
                    }
                    _ => {
                        return Ok(CommandOutput {
                            exit_code: 2,
                            stdout: Vec::new(),
                            stderr: Vec::new(),
                        });
                    }
                }
                if mode == "tree" && state.cleanup_response_loss_once {
                    state.cleanup_response_loss_once = false;
                    drop(state);
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::ConnectionReset,
                        "fixture lost cleanup response after remote success",
                    )
                    .into());
                }
                return Ok(CommandOutput {
                    exit_code: 0,
                    stdout: Vec::new(),
                    stderr: Vec::new(),
                });
            }
            if path.ends_with("install-worker.sh") || path.ends_with("Install-Worker.ps1") {
                let action = if path.ends_with("install-worker.sh") {
                    arguments.first().map(|value| value.as_str()).unwrap_or("")
                } else {
                    arguments.get(1).map(|value| value.as_str()).unwrap_or("")
                }
                .to_ascii_lowercase();
                let enrollment_index = arguments.iter().position(|argument| {
                    matches!(argument.as_str(), "--enrollment" | "-EnrollmentFile")
                });
                let pair_only = arguments
                    .iter()
                    .any(|argument| matches!(argument.as_str(), "--pair-only" | "-PairOnly"));
                let paired = {
                    let mut state = self.inner.lock().unwrap();
                    if let Some(index) = enrollment_index {
                        if let Some(path) = arguments.get(index + 1) {
                            state.files.remove(path.as_str());
                            state.pairing_apply_count += 1;
                            state.paired = true;
                            self.pairing_phase.store(PAIRING_READY, Ordering::SeqCst);
                        }
                    }
                    state.paired
                };
                let state_fields = if action == "uninstall" {
                    String::new()
                } else if paired && pair_only {
                    ",\"paired\":true,\"service\":\"not_enabled\",\"serviceEnabled\":false"
                        .to_owned()
                } else if paired {
                    ",\"paired\":true,\"service\":\"systemd-user\",\"serviceEnabled\":true"
                        .to_owned()
                } else {
                    ",\"paired\":false,\"service\":\"not_enabled\",\"serviceEnabled\":false"
                        .to_owned()
                };
                return Ok(CommandOutput {
                    exit_code: 0,
                    stdout: format!(
                        "{{\"schemaVersion\":\"cyc.dev/linux-worker-install/v1\",\"action\":\"{action}\",\"succeeded\":true{state_fields}}}\n"
                    )
                    .into_bytes(),
                    stderr: Vec::new(),
                });
            }
            Err(SshError::InvalidCommandArgument)
        }

        fn upload_bytes(
            &mut self,
            remote_path: &RemotePath,
            content: &[u8],
            _unix_mode: i32,
        ) -> Result<TransferReceipt, SshError> {
            let path = remote_path.as_str().to_owned();
            let mut state = self.inner.lock().unwrap();
            if path.contains("enrollment-") {
                state.enrollment_uploaded = true;
                state.enrollment_paths.push(path.clone());
            }
            state.files.insert(path, content.to_vec());
            Ok(TransferReceipt {
                bytes: content.len() as u64,
                sha256: sha256_hex(content),
            })
        }

        fn download_bytes(
            &mut self,
            remote_path: &RemotePath,
            maximum_bytes: usize,
        ) -> Result<Vec<u8>, SshError> {
            let content = self
                .inner
                .lock()
                .unwrap()
                .files
                .get(remote_path.as_str())
                .cloned()
                .ok_or_else(|| std::io::Error::from(std::io::ErrorKind::NotFound))?;
            if content.len() > maximum_bytes {
                return Err(SshError::OutputLimitExceeded {
                    stream: "download",
                    maximum_bytes,
                });
            }
            Ok(content)
        }

        fn create_dir(
            &mut self,
            _remote_path: &RemotePath,
            unix_mode: i32,
        ) -> Result<(), SshError> {
            self.inner
                .lock()
                .unwrap()
                .private_directory_modes
                .push(unix_mode);
            Ok(())
        }

        fn rename(
            &mut self,
            from: &RemotePath,
            to: &RemotePath,
            _overwrite: bool,
        ) -> Result<(), SshError> {
            let mut state = self.inner.lock().unwrap();
            let content = state
                .files
                .remove(from.as_str())
                .ok_or_else(|| std::io::Error::from(std::io::ErrorKind::NotFound))?;
            state.files.insert(to.as_str().to_owned(), content);
            Ok(())
        }

        fn remove_file(&mut self, remote_path: &RemotePath) -> Result<(), SshError> {
            self.inner
                .lock()
                .unwrap()
                .files
                .remove(remote_path.as_str());
            Ok(())
        }
    }

    fn discovery_payload() -> Vec<u8> {
        format!(
            "CYC_DISCOVERY_V1\nhostname={}\noperating_system=linux\narchitecture=x86_64\ncpu_model={}\nlogical_cpu_count=16\nmemory_bytes=34359738368\nworkspace_free_bytes=107374182400\ngpu={}|{}|8589934592\ntool={}|{}\n",
            STANDARD.encode("worker-01"),
            STANDARD.encode("Fixture CPU"),
            STANDARD.encode("Fixture GPU"),
            STANDARD.encode("GPU-1"),
            STANDARD.encode("cargo"),
            STANDARD.encode("cargo 1.90.0")
        )
        .into_bytes()
    }

    #[derive(Default)]
    struct FakeVault {
        entries: Mutex<HashMap<String, (String, Vec<u8>)>>,
        stores: Mutex<usize>,
        deletes: Mutex<usize>,
    }

    impl FakeVault {
        fn store_count(&self) -> usize {
            *self.stores.lock().unwrap()
        }

        fn delete_count(&self) -> usize {
            *self.deletes.lock().unwrap()
        }

        fn is_empty(&self) -> bool {
            self.entries.lock().unwrap().is_empty()
        }
    }

    impl CredentialVault for FakeVault {
        fn store(
            &self,
            key: &CredentialKey,
            username: &str,
            secret: &Secret,
        ) -> Result<CredentialReference, VaultError> {
            *self.stores.lock().unwrap() += 1;
            self.entries.lock().unwrap().insert(
                key.reference().as_str().to_owned(),
                (username.to_owned(), secret.expose_secret().to_vec()),
            );
            Ok(key.reference())
        }

        fn retrieve(&self, key: &CredentialKey) -> Result<Option<StoredCredential>, VaultError> {
            Ok(self
                .entries
                .lock()
                .unwrap()
                .get(key.reference().as_str())
                .cloned()
                .map(|(username, bytes)| StoredCredential {
                    username,
                    secret: Secret::from_bytes(bytes),
                }))
        }

        fn delete(&self, key: &CredentialKey) -> Result<bool, VaultError> {
            *self.deletes.lock().unwrap() += 1;
            Ok(self
                .entries
                .lock()
                .unwrap()
                .remove(key.reference().as_str())
                .is_some())
        }
    }

    struct FakeTransientSecrets {
        bytes: Mutex<Option<Vec<u8>>>,
        retrievals: Mutex<usize>,
    }

    impl FakeTransientSecrets {
        fn new(value: Option<&str>) -> Self {
            Self {
                bytes: Mutex::new(value.map(|value| value.as_bytes().to_vec())),
                retrievals: Mutex::new(0),
            }
        }

        fn retrieval_count(&self) -> usize {
            *self.retrievals.lock().unwrap()
        }
    }

    impl TransientSecretProvider for FakeTransientSecrets {
        fn retrieve(&self, _computer_id: Uuid) -> Result<Option<Secret>, TransientSecretError> {
            *self.retrievals.lock().unwrap() += 1;
            Ok(self
                .bytes
                .lock()
                .unwrap()
                .as_ref()
                .map(|bytes| Secret::from_bytes(bytes.clone())))
        }

        fn clear_if_matches(&self, _computer_id: Uuid, expected: &Secret) {
            let mut bytes = self.bytes.lock().unwrap();
            if bytes
                .as_deref()
                .is_some_and(|value| value == expected.expose_secret())
            {
                if let Some(value) = bytes.as_mut() {
                    value.fill(0);
                }
                *bytes = None;
            }
        }

        fn clear(&self, _computer_id: Uuid) {
            if let Some(bytes) = self.bytes.lock().unwrap().as_mut() {
                bytes.fill(0);
            }
            *self.bytes.lock().unwrap() = None;
        }
    }

    struct FakeController {
        pairings: Mutex<BTreeMap<String, Uuid>>,
        smoke_bindings: Mutex<BTreeMap<String, SmokeRunBindingV1>>,
        smoke_prepare_calls: Mutex<Vec<(String, Uuid, Uuid)>>,
        smoke_run_bindings: Mutex<Vec<SmokeRunBindingV1>>,
        revoked: Mutex<usize>,
        stale_heartbeat: AtomicBool,
        pairing_phase: Arc<AtomicU8>,
    }

    impl FakeController {
        fn new(pairing_phase: Arc<AtomicU8>) -> Self {
            Self {
                pairings: Mutex::new(BTreeMap::new()),
                smoke_bindings: Mutex::new(BTreeMap::new()),
                smoke_prepare_calls: Mutex::new(Vec::new()),
                smoke_run_bindings: Mutex::new(Vec::new()),
                revoked: Mutex::new(0),
                stale_heartbeat: AtomicBool::new(false),
                pairing_phase,
            }
        }

        fn unique_pairing_count(&self) -> usize {
            self.pairings.lock().unwrap().len()
        }

        fn revoke_count(&self) -> usize {
            *self.revoked.lock().unwrap()
        }

        fn smoke_prepare_calls(&self) -> Vec<(String, Uuid, Uuid)> {
            self.smoke_prepare_calls.lock().unwrap().clone()
        }

        fn smoke_run_bindings(&self) -> Vec<SmokeRunBindingV1> {
            self.smoke_run_bindings.lock().unwrap().clone()
        }

        fn set_stale_heartbeat(&self, stale: bool) {
            self.stale_heartbeat.store(stale, Ordering::SeqCst);
        }

        fn set_pairing_consumed(&self) {
            self.pairing_phase.store(PAIRING_CONSUMED, Ordering::SeqCst);
        }
    }

    impl ControllerBoundary for FakeController {
        fn issue_enrollment(
            &self,
            operation_id: &str,
            intended_node_id: Uuid,
            existing_pairing_id: Option<Uuid>,
        ) -> Result<EnrollmentBundleV1, ControllerBoundaryFailure> {
            let mut pairings = self.pairings.lock().unwrap();
            let pairing_id = match pairings.entry(operation_id.to_owned()) {
                std::collections::btree_map::Entry::Occupied(entry) => *entry.get(),
                std::collections::btree_map::Entry::Vacant(entry) => {
                    self.pairing_phase.store(PAIRING_PENDING, Ordering::SeqCst);
                    *entry.insert(existing_pairing_id.unwrap_or_else(Uuid::new_v4))
                }
            };
            if existing_pairing_id.is_some_and(|existing| existing != pairing_id) {
                return Err(ControllerBoundaryFailure::new("PAIRING_ID_MISMATCH", false).unwrap());
            }
            let created_at = Utc::now();
            Ok(EnrollmentBundleV1 {
                api_version: ENROLLMENT_API_VERSION.to_owned(),
                pairing_id,
                controller_id: Uuid::from_u128(1),
                intended_node_id,
                worker_url: "https://controller.example.invalid:47832".to_owned(),
                certificate_pem:
                    "-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----\n".to_owned(),
                pairing_code: PAIRING_SECRET.to_owned(),
                created_at,
                expires_at: created_at + Duration::minutes(10),
            })
        }

        fn poll_pairing(
            &self,
            _pairing_id: Uuid,
            intended_node_id: Uuid,
        ) -> Result<PairingObservation, ControllerBoundaryFailure> {
            match self.pairing_phase.load(Ordering::SeqCst) {
                PAIRING_PENDING => Ok(PairingObservation::Pending),
                PAIRING_CONSUMED => Ok(PairingObservation::Consumed),
                PAIRING_READY => Ok(PairingObservation::Paired {
                    node_id: intended_node_id,
                }),
                _ => panic!("invalid fake pairing phase"),
            }
        }

        fn poll_heartbeat(
            &self,
            _node_id: Uuid,
            received_after: DateTime<Utc>,
        ) -> Result<Option<chrono::DateTime<Utc>>, ControllerBoundaryFailure> {
            if self.stale_heartbeat.load(Ordering::SeqCst) {
                return Ok(Some(received_after - Duration::milliseconds(1)));
            }
            // Keep the fixture strictly newer than the service checkpoint but
            // never synthesize a future timestamp. Windows clocks can expose a
            // coarser tick than the surrounding SQLite writes.
            let mut observed_at = Utc::now();
            while observed_at <= received_after {
                std::thread::sleep(std::time::Duration::from_millis(1));
                observed_at = Utc::now();
            }
            Ok(Some(observed_at))
        }

        fn prepare_smoke_check(
            &self,
            node_id: Uuid,
            operation_id: &str,
            job_id: Uuid,
        ) -> Result<SmokeRunBindingV1, ControllerBoundaryFailure> {
            self.smoke_prepare_calls.lock().unwrap().push((
                operation_id.to_owned(),
                node_id,
                job_id,
            ));
            let mut bindings = self.smoke_bindings.lock().unwrap();
            Ok(bindings
                .entry(operation_id.to_owned())
                .or_insert_with(|| smoke_binding(node_id, job_id))
                .clone())
        }

        fn run_smoke_check(
            &self,
            binding: &SmokeRunBindingV1,
        ) -> Result<Option<chrono::DateTime<Utc>>, ControllerBoundaryFailure> {
            self.smoke_run_bindings
                .lock()
                .unwrap()
                .push(binding.clone());
            Ok(Some(Utc::now()))
        }

        fn revoke_pairing(
            &self,
            _pairing_id: Uuid,
            _operation_id: &str,
        ) -> Result<(), ControllerBoundaryFailure> {
            *self.revoked.lock().unwrap() += 1;
            Ok(())
        }
    }

    fn smoke_binding(node_id: Uuid, job_id: Uuid) -> SmokeRunBindingV1 {
        let created_at = Utc::now();
        SmokeRunBindingV1 {
            plan: PlacementPlanBindingV1 {
                api_version: PLACEMENT_PLAN_BINDING_API_VERSION.to_owned(),
                plan_id: Uuid::new_v4(),
                job_id,
                job_digest: "0".repeat(64),
                created_at,
                expires_at: created_at + Duration::minutes(1),
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
}
