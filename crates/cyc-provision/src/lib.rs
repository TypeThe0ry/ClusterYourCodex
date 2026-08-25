//! Durable Add Computer provisioning state for ClusterYourCodex.
//!
//! The persisted model contains credential references and public SSH host keys,
//! never passwords, private-key contents/passphrases, enrollment codes, or
//! other secret material. A redacted, validated local key path may be durable.
//! Managed smoke preparation persists an immutable placement/job/run binding
//! before polling, so retries and process restarts cannot silently re-plan.

mod discovery;
mod engine;
mod model;
mod smoke;
mod ssh_driver;
mod store;
mod worker_kit;
mod worker_kit_export;

pub use discovery::{DiscoveryError, RemotePlatform};
pub use engine::{
    DriveOutcome, DriverFailure, DriverRequest, ProvisioningAction, ProvisioningDriver,
    ProvisioningEngine, ProvisioningError, StepCompletion,
};
pub use model::{
    AllowedJobKind, ComputerConfiguration, ComputerEndpoint, ComputerRecord, CredentialPolicy,
    CredentialState, DiscoveredComputer, FailureCode, GpuInventory, NewComputer,
    PinnedHostKeyRecord, ProvisioningIntent, ProvisioningState, ProvisioningStep,
    RecordValidationError, ResourcePolicy, ServiceScope, SshAuthenticationMethod,
    SshAuthenticationPolicy, COMPUTER_RECORD_FORMAT_VERSION,
};
pub use smoke::{canonical_smoke_job_id, canonical_smoke_operation_id};
pub use ssh_driver::{
    ControllerBoundary, ControllerBoundaryFailure, PairingObservation, SshDriverOptions,
    SshProvisioningDriver, TransientSecretError, TransientSecretProvider,
};
pub use store::{ProvisioningStore, StoreError};
pub use worker_kit::{WorkerKit, WorkerKitCatalog, WorkerKitError, WorkerKitTarget};
pub use worker_kit_export::{
    EnrollmentSecret, WorkerKitCleanupReceipt, WorkerKitExportError, WorkerKitExportReceipt,
    WorkerKitExporter,
};
