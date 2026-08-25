use std::{
    collections::{BTreeMap, BTreeSet, HashMap},
    io::Read,
    path::{Path, PathBuf},
    sync::{Arc, Mutex, MutexGuard},
    time::Duration,
};

use chrono::{DateTime, SecondsFormat, Utc};
#[cfg(test)]
use cyc_protocol::CapacityPolicy;
use cyc_protocol::{
    onboarding::{
        EnrollmentBundleV1, PairingFailureCodeV1, PairingPhaseV1, PairingStatusErrorV1,
        PairingStatusV1,
    },
    JobKind, Node, NodeConfig, SmokeRunBindingV1,
};
use cyc_provision::{
    AllowedJobKind, ComputerConfiguration, ComputerEndpoint, ComputerRecord, ControllerBoundary,
    ControllerBoundaryFailure, CredentialState, DriveOutcome, DriverFailure, NewComputer,
    PairingObservation, ProvisioningDriver, ProvisioningEngine, ProvisioningError,
    ProvisioningIntent, ProvisioningState, ProvisioningStore, ResourcePolicy, ServiceScope,
    SshAuthenticationMethod, SshAuthenticationPolicy, SshDriverOptions, SshProvisioningDriver,
    StepCompletion, StoreError, TransientSecretError, TransientSecretProvider, WorkerKitCatalog,
    WorkerKitError,
};
#[cfg(not(windows))]
use cyc_secrets::{CredentialKey, StoredCredential};
use cyc_secrets::{CredentialVault, Secret, VaultError};
use cyc_ssh::{PrivateKeyFile, Ssh2Transport};
use reqwest::{
    blocking::{Client as BlockingClient, RequestBuilder, Response as BlockingResponse},
    header::{HeaderValue, ACCEPT, AUTHORIZATION, CONTENT_LENGTH, CONTENT_TYPE},
    Method, StatusCode,
};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;
use zeroize::{Zeroize, Zeroizing};

use super::{
    full_run::{FullRunCheckManager, NodeSmokeError},
    load_token, CONTROLLER_ORIGIN,
};

const PROVISIONING_DATABASE: &str = "provisioning-v1.sqlite3";
const MAX_AUTHENTICATION_SECRET_BYTES: usize = 16 * 1024;
const MAX_CONTROLLER_RESPONSE_BYTES: usize = 1024 * 1024;
const MAX_DRIVE_TRANSITIONS: usize = 32;
const CONTROLLER_CONNECT_TIMEOUT: Duration = Duration::from_secs(2);
const CONTROLLER_REQUEST_TIMEOUT: Duration = Duration::from_secs(7);
const NODE_CONFIG_API_VERSION: &str = "cyc.dev/node-config/v1";
const NODE_CONFIG_SYNC_ATTEMPTS: usize = 3;
const POLICY_ALLOWED_JOB_KINDS: &str = "cyc.policy.allowedJobKinds";
const POLICY_RESOURCE: &str = "cyc.policy.resource";
const POLICY_BATTERY: &str = "cyc.policy.battery";

#[derive(Clone)]
pub struct ProvisioningManager {
    runtime: Arc<ProvisioningRuntime>,
}

struct ProvisioningRuntime {
    engine: ProvisioningEngine,
    driver: Mutex<BoxedProvisioningDriver>,
    transient_secrets: Arc<SessionSecretStore>,
}

struct BoxedProvisioningDriver {
    inner: Box<dyn ProvisioningDriver>,
    controller_policy: Option<Arc<HttpControllerBoundary>>,
}

impl ProvisioningDriver for BoxedProvisioningDriver {
    fn execute(
        &mut self,
        request: &cyc_provision::DriverRequest<'_>,
    ) -> Result<cyc_provision::StepCompletion, DriverFailure> {
        let completion = self.inner.execute(request)?;
        if let (Some(controller), StepCompletion::Paired { node_id }) =
            (&self.controller_policy, &completion)
        {
            controller
                .sync_node_config(request.computer, *node_id)
                .map_err(controller_driver_failure)?;
        }
        Ok(completion)
    }

    fn rollback(
        &mut self,
        request: &cyc_provision::DriverRequest<'_>,
    ) -> Result<(), DriverFailure> {
        self.inner.rollback(request)
    }

    fn remove(&mut self, request: &cyc_provision::DriverRequest<'_>) -> Result<(), DriverFailure> {
        self.inner.remove(request)
    }

    fn forget_credential(
        &mut self,
        request: &cyc_provision::DriverRequest<'_>,
    ) -> Result<(), DriverFailure> {
        self.inner.forget_credential(request)
    }
}

impl ProvisioningManager {
    pub fn new(
        data_root: &Path,
        token_file: PathBuf,
    ) -> Result<Self, ProvisioningInitializationError> {
        std::fs::create_dir_all(data_root)
            .map_err(|_| ProvisioningInitializationError::DataDirectory)?;
        let store = ProvisioningStore::open(data_root.join(PROVISIONING_DATABASE))?;
        let transient_secrets = Arc::new(SessionSecretStore::default());
        let transport = Arc::new(Ssh2Transport::default());
        let vault = platform_vault()?;
        let controller = Arc::new(HttpControllerBoundary::new(token_file)?);
        let catalog = WorkerKitCatalog::from_install_root(default_install_root()?)?;
        let driver = SshProvisioningDriver::new(
            transport,
            vault,
            transient_secrets.clone(),
            controller.clone(),
            catalog,
            SshDriverOptions::default(),
        );
        Ok(Self::from_parts_with_policy(
            ProvisioningEngine::new(store),
            Box::new(driver),
            transient_secrets,
            Some(controller),
        ))
    }

    #[cfg(test)]
    fn from_parts(
        engine: ProvisioningEngine,
        driver: Box<dyn ProvisioningDriver>,
        transient_secrets: Arc<SessionSecretStore>,
    ) -> Self {
        Self::from_parts_with_policy(engine, driver, transient_secrets, None)
    }

    fn from_parts_with_policy(
        engine: ProvisioningEngine,
        driver: Box<dyn ProvisioningDriver>,
        transient_secrets: Arc<SessionSecretStore>,
        controller_policy: Option<Arc<HttpControllerBoundary>>,
    ) -> Self {
        Self {
            runtime: Arc::new(ProvisioningRuntime {
                engine,
                driver: Mutex::new(BoxedProvisioningDriver {
                    inner: driver,
                    controller_policy,
                }),
                transient_secrets,
            }),
        }
    }

    pub fn start(
        &self,
        mut request: StartComputerRequest,
    ) -> Result<ProvisioningOperationResult, PublicProvisioningError> {
        let record_id = parse_id(&request.record_id)?;
        let intended_node_id = parse_id(&request.intended_node_id)?;
        let (ssh_authentication, secret) = request.take_authentication()?;
        let endpoint = ComputerEndpoint::new(
            std::mem::take(&mut request.host),
            request.port,
            std::mem::take(&mut request.username),
        )?;
        let configuration = std::mem::take(&mut request.advanced).into_configuration()?;
        let mut input = NewComputer::new(std::mem::take(&mut request.display_name), endpoint)?;
        input.ssh_authentication = ssh_authentication;
        input.remember_credential = request.remember_password
            && input.ssh_authentication.method() == SshAuthenticationMethod::Password;
        input.configuration = configuration;
        input.validate()?;
        let record = self
            .runtime
            .engine
            .create_idempotent(input, record_id, intended_node_id)?;
        // A response-loss retry against an already Ready record must not leave
        // newly supplied password bytes retained in the session map.  Every
        // non-ready checkpoint may still need the secret for an SSH retry.
        if !matches!(record.state, ProvisioningState::Ready) {
            if let Some(secret) = secret {
                self.runtime.transient_secrets.insert(record.id, secret)?;
            }
        }
        self.drive_bounded(record.id, record.revision)
    }

    pub fn list(&self) -> Result<Vec<ProvisioningComputerView>, PublicProvisioningError> {
        self.runtime
            .engine
            .list()?
            .iter()
            .map(|record| self.view(record, None))
            .collect()
    }

    pub fn get(
        &self,
        request: ComputerIdRequest,
    ) -> Result<ProvisioningComputerView, PublicProvisioningError> {
        let id = parse_id(&request.id)?;
        let record = self.runtime.engine.get(id)?;
        self.view(&record, None)
    }

    pub fn approve_host_key(
        &self,
        request: ApproveHostKeyRequest,
    ) -> Result<ProvisioningOperationResult, PublicProvisioningError> {
        validate_fingerprint(&request.fingerprint)?;
        let id = parse_id(&request.id)?;
        let record =
            self.runtime
                .engine
                .approve_host_key(id, request.revision, &request.fingerprint)?;
        self.drive_bounded(id, record.revision)
    }

    pub fn continue_provisioning(
        &self,
        mut request: SecretActionRequest,
    ) -> Result<ProvisioningOperationResult, PublicProvisioningError> {
        let id = parse_id(&request.id)?;
        self.inject_optional_secret(id, &mut request)?;
        self.drive_bounded(id, request.revision)
    }

    pub fn request_intent(
        &self,
        intent: ProvisioningIntent,
        mut request: SecretActionRequest,
    ) -> Result<ProvisioningOperationResult, PublicProvisioningError> {
        let id = parse_id(&request.id)?;
        self.inject_optional_secret(id, &mut request)?;
        let record = self
            .runtime
            .engine
            .request_intent(id, request.revision, intent)?;
        self.drive_bounded(id, record.revision)
    }

    pub fn repair(
        &self,
        mut request: SecretActionRequest,
    ) -> Result<ProvisioningOperationResult, PublicProvisioningError> {
        let id = parse_id(&request.id)?;
        self.inject_optional_secret(id, &mut request)?;
        let requested = self.runtime.engine.begin_repair(id, request.revision)?;
        self.drive_bounded(id, requested.revision)
    }

    pub fn rollback(
        &self,
        request: SecretActionRequest,
    ) -> Result<ProvisioningOperationResult, PublicProvisioningError> {
        self.request_single_step_intent(ProvisioningIntent::Rollback, request)
    }

    pub fn remove(
        &self,
        request: SecretActionRequest,
    ) -> Result<ProvisioningOperationResult, PublicProvisioningError> {
        self.request_single_step_intent(ProvisioningIntent::Remove, request)
    }

    pub fn forget_ssh_password(
        &self,
        request: RevisionRequest,
    ) -> Result<ProvisioningOperationResult, PublicProvisioningError> {
        let id = parse_id(&request.id)?;
        let record = {
            let mut driver = self.driver()?;
            self.runtime
                .engine
                .forget_credential(id, request.revision, &mut *driver)?
        };
        self.result(DriveOutcome::Ready(record))
    }

    fn request_single_step_intent(
        &self,
        intent: ProvisioningIntent,
        mut request: SecretActionRequest,
    ) -> Result<ProvisioningOperationResult, PublicProvisioningError> {
        let id = parse_id(&request.id)?;
        self.inject_optional_secret(id, &mut request)?;
        let record = self
            .runtime
            .engine
            .request_intent(id, request.revision, intent)?;
        self.drive_bounded(id, record.revision)
    }

    fn inject_optional_secret(
        &self,
        id: Uuid,
        request: &mut SecretActionRequest,
    ) -> Result<(), PublicProvisioningError> {
        let method = self.runtime.engine.get(id)?.ssh_authentication.method();
        if let Some(secret) = request.take_secret(method)? {
            self.runtime.transient_secrets.insert(id, secret)?;
        }
        Ok(())
    }

    fn drive_bounded(
        &self,
        id: Uuid,
        mut revision: u64,
    ) -> Result<ProvisioningOperationResult, PublicProvisioningError> {
        let mut driver = self.driver()?;
        for _ in 0..MAX_DRIVE_TRANSITIONS {
            let outcome = self.runtime.engine.drive_once(id, revision, &mut *driver)?;
            match outcome {
                DriveOutcome::Checkpoint(record) => revision = record.revision,
                terminal => return self.result(terminal),
            }
        }
        Err(PublicProvisioningError::new("drive_limit_reached", true))
    }

    fn result(
        &self,
        outcome: DriveOutcome,
    ) -> Result<ProvisioningOperationResult, PublicProvisioningError> {
        let result = match outcome {
            DriveOutcome::Checkpoint(record) => {
                ProvisioningOperationResult::computer("checkpoint", self.view(&record, None)?)
            }
            DriveOutcome::AwaitingHostKeyApproval(record) => ProvisioningOperationResult::computer(
                "awaiting_host_key_approval",
                self.view(&record, Some(ProvisioningAttention::HostKey))?,
            ),
            DriveOutcome::AwaitingIntent(record) => ProvisioningOperationResult::computer(
                "awaiting_intent",
                self.view(&record, Some(ProvisioningAttention::Intent))?,
            ),
            DriveOutcome::AwaitingCredential(record) => ProvisioningOperationResult::computer(
                "awaiting_credential",
                self.view(&record, Some(ProvisioningAttention::Credential))?,
            ),
            DriveOutcome::AwaitingExternal(record) => ProvisioningOperationResult::computer(
                "awaiting_external",
                self.view(&record, Some(ProvisioningAttention::External))?,
            ),
            DriveOutcome::Ready(record) => {
                self.runtime.transient_secrets.clear(record.id);
                ProvisioningOperationResult::computer("ready", self.view(&record, None)?)
            }
            DriveOutcome::Failed(record) => {
                ProvisioningOperationResult::computer("failed", self.view(&record, None)?)
            }
            DriveOutcome::RolledBack(record) => {
                self.runtime.transient_secrets.clear(record.id);
                ProvisioningOperationResult::computer("rolled_back", self.view(&record, None)?)
            }
            DriveOutcome::Removed { id } => {
                self.runtime.transient_secrets.clear(id);
                ProvisioningOperationResult::removed(id)
            }
        };
        Ok(result)
    }

    fn view(
        &self,
        record: &ComputerRecord,
        attention: Option<ProvisioningAttention>,
    ) -> Result<ProvisioningComputerView, PublicProvisioningError> {
        ProvisioningComputerView::from_record(
            record,
            attention.unwrap_or_else(|| self.durable_attention(record)),
        )
    }

    fn durable_attention(&self, record: &ComputerRecord) -> ProvisioningAttention {
        if let ProvisioningState::Failed { code, .. } = &record.state {
            return if matches!(
                code.as_str(),
                "SSH_AUTH_REJECTED" | "SSH_PRIVATE_KEY_REJECTED"
            ) {
                ProvisioningAttention::Credential
            } else {
                ProvisioningAttention::Intent
            };
        }
        if matches!(record.state, ProvisioningState::HostKeyPending)
            && record.host_key_approved_at.is_none()
        {
            return ProvisioningAttention::HostKey;
        }
        if matches!(
            record.state,
            ProvisioningState::EnrollmentIssued
                | ProvisioningState::ServiceEnabled
                | ProvisioningState::SmokeCheck
        ) {
            return ProvisioningAttention::External;
        }
        let needs_authenticated_ssh = matches!(
            record.state,
            ProvisioningState::HostKeyPending
                | ProvisioningState::Authenticated
                | ProvisioningState::Discovering
                | ProvisioningState::CredentialStored
                | ProvisioningState::KitStaged
                | ProvisioningState::WorkerInstalled
                | ProvisioningState::Paired
        );
        if needs_authenticated_ssh
            && record.ssh_authentication.method() == SshAuthenticationMethod::Password
            && record.credential_policy.state != CredentialState::Stored
            && !self.runtime.transient_secrets.contains(record.id)
        {
            return ProvisioningAttention::Credential;
        }
        ProvisioningAttention::None
    }

    fn driver(&self) -> Result<MutexGuard<'_, BoxedProvisioningDriver>, PublicProvisioningError> {
        self.runtime
            .driver
            .lock()
            .map_err(|_| PublicProvisioningError::new("driver_unavailable", false))
    }
}

#[derive(Default)]
struct SessionSecretStore {
    secrets: Mutex<HashMap<Uuid, Secret>>,
}

impl SessionSecretStore {
    fn insert(&self, id: Uuid, secret: Secret) -> Result<(), PublicProvisioningError> {
        self.secrets
            .lock()
            .map_err(|_| PublicProvisioningError::new("driver_unavailable", false))?
            .insert(id, secret);
        Ok(())
    }

    fn contains(&self, id: Uuid) -> bool {
        self.secrets
            .lock()
            .map(|secrets| secrets.contains_key(&id))
            .unwrap_or(false)
    }
}

impl TransientSecretProvider for SessionSecretStore {
    fn retrieve(&self, computer_id: Uuid) -> Result<Option<Secret>, TransientSecretError> {
        let secrets = self
            .secrets
            .lock()
            .map_err(|_| TransientSecretError::Unavailable)?;
        Ok(secrets
            .get(&computer_id)
            .map(|secret| Secret::from_bytes(secret.expose_secret().to_vec())))
    }

    fn clear_if_matches(&self, computer_id: Uuid, expected: &Secret) {
        if let Ok(mut secrets) = self.secrets.lock() {
            let matches = secrets
                .get(&computer_id)
                .is_some_and(|secret| secret.expose_secret() == expected.expose_secret());
            if matches {
                secrets.remove(&computer_id);
            }
        }
    }

    fn clear(&self, computer_id: Uuid) {
        if let Ok(mut secrets) = self.secrets.lock() {
            secrets.remove(&computer_id);
        }
    }
}

#[cfg(windows)]
fn platform_vault() -> Result<Arc<dyn CredentialVault>, ProvisioningInitializationError> {
    let vault = cyc_secrets::WindowsCredentialVault::new("ClusterYourCodex")?;
    Ok(Arc::new(vault))
}

#[cfg(not(windows))]
fn platform_vault() -> Result<Arc<dyn CredentialVault>, ProvisioningInitializationError> {
    Ok(Arc::new(UnsupportedCredentialVault))
}

#[cfg(not(windows))]
struct UnsupportedCredentialVault;

#[cfg(not(windows))]
impl CredentialVault for UnsupportedCredentialVault {
    fn store(
        &self,
        _key: &CredentialKey,
        _username: &str,
        _secret: &Secret,
    ) -> Result<cyc_secrets::CredentialReference, VaultError> {
        Err(VaultError::UnsupportedPlatform)
    }

    fn retrieve(&self, _key: &CredentialKey) -> Result<Option<StoredCredential>, VaultError> {
        Err(VaultError::UnsupportedPlatform)
    }

    fn delete(&self, _key: &CredentialKey) -> Result<bool, VaultError> {
        Err(VaultError::UnsupportedPlatform)
    }
}

fn default_install_root() -> Result<PathBuf, ProvisioningInitializationError> {
    let executable = std::env::current_exe()
        .map_err(|_| ProvisioningInitializationError::ExecutableDirectory)?;
    let root = executable
        .parent()
        .ok_or(ProvisioningInitializationError::ExecutableDirectory)?;
    Ok(root.to_path_buf())
}

struct HttpControllerBoundary {
    client: BlockingClient,
    token_file: PathBuf,
    smoke: FullRunCheckManager,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct NodeConfigDocument {
    api_version: String,
    node_id: Uuid,
    revision: i64,
    config: NodeConfig,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct NodeConfigUpdate<'a> {
    expected_revision: i64,
    config: &'a NodeConfig,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ReportPairingFailureRequest {
    code: PairingFailureCodeV1,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ResourcePolicyLabel {
    cpu_limit_percent: Option<u8>,
    maximum_parallel_jobs: Option<u16>,
    memory_limit_bytes: Option<u64>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct BatteryPolicyLabel {
    allow_on_battery: bool,
}

impl HttpControllerBoundary {
    fn new(token_file: PathBuf) -> Result<Self, ProvisioningInitializationError> {
        let client = BlockingClient::builder()
            .connect_timeout(CONTROLLER_CONNECT_TIMEOUT)
            .timeout(CONTROLLER_REQUEST_TIMEOUT)
            .redirect(reqwest::redirect::Policy::none())
            .no_proxy()
            .build()
            .map_err(|_| ProvisioningInitializationError::ControllerClient)?;
        let smoke = FullRunCheckManager::new(token_file.clone())
            .map_err(|_| ProvisioningInitializationError::ControllerClient)?;
        Ok(Self {
            client,
            token_file,
            smoke,
        })
    }

    fn request(
        &self,
        method: Method,
        path: &str,
    ) -> Result<RequestBuilder, ControllerBoundaryFailure> {
        let token = load_token(&self.token_file)
            .map_err(|_| controller_failure("CONTROLLER_AUTH_UNAVAILABLE", true))?;
        let encoded = Zeroizing::new(format!("Bearer {}", token.as_str()));
        let mut authorization = HeaderValue::from_str(encoded.as_str())
            .map_err(|_| controller_failure("CONTROLLER_AUTH_UNAVAILABLE", false))?;
        authorization.set_sensitive(true);
        Ok(self
            .client
            .request(method, format!("{CONTROLLER_ORIGIN}{path}"))
            .header(ACCEPT, "application/json")
            .header(AUTHORIZATION, authorization))
    }

    fn decode<T: for<'de> Deserialize<'de>>(
        &self,
        response: BlockingResponse,
    ) -> Result<T, ControllerBoundaryFailure> {
        if !response.status().is_success() {
            return Err(status_failure(response.status()));
        }
        if response
            .headers()
            .get(CONTENT_LENGTH)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.parse::<usize>().ok())
            .is_some_and(|length| length > MAX_CONTROLLER_RESPONSE_BYTES)
        {
            return Err(controller_failure("CONTROLLER_RESPONSE_LIMIT", false));
        }
        let mut bytes = Vec::new();
        response
            .take((MAX_CONTROLLER_RESPONSE_BYTES + 1) as u64)
            .read_to_end(&mut bytes)
            .map_err(|_| controller_failure("CONTROLLER_UNAVAILABLE", true))?;
        if bytes.len() > MAX_CONTROLLER_RESPONSE_BYTES {
            return Err(controller_failure("CONTROLLER_RESPONSE_LIMIT", false));
        }
        serde_json::from_slice(&bytes)
            .map_err(|_| controller_failure("CONTROLLER_RESPONSE_INVALID", false))
    }

    fn send_empty(&self, response: BlockingResponse) -> Result<(), ControllerBoundaryFailure> {
        if response.status().is_success() {
            Ok(())
        } else {
            Err(status_failure(response.status()))
        }
    }

    fn get_node_config(
        &self,
        node_id: Uuid,
    ) -> Result<NodeConfigDocument, ControllerBoundaryFailure> {
        let response = self
            .request(Method::GET, &format!("/v1/nodes/{node_id}/config"))?
            .send()
            .map_err(|_| controller_failure("CONTROLLER_UNAVAILABLE", true))?;
        if response.status() == StatusCode::NOT_FOUND {
            return Err(controller_failure("NODE_CONFIG_NOT_READY", true));
        }
        let document: NodeConfigDocument = self.decode(response)?;
        validate_node_config_document(&document, node_id)?;
        Ok(document)
    }

    fn sync_node_config(
        &self,
        record: &ComputerRecord,
        node_id: Uuid,
    ) -> Result<(), ControllerBoundaryFailure> {
        for attempt in 0..NODE_CONFIG_SYNC_ATTEMPTS {
            let current = self.get_node_config(node_id)?;
            let desired = desired_node_config(record, &current.config)?;
            if current.config == desired {
                return Ok(());
            }

            let response = self
                .request(Method::PUT, &format!("/v1/nodes/{node_id}/config"))?
                .header(CONTENT_TYPE, "application/json")
                .json(&NodeConfigUpdate {
                    expected_revision: current.revision,
                    config: &desired,
                })
                .send()
                .map_err(|_| controller_failure("CONTROLLER_UNAVAILABLE", true))?;
            if response.status() == StatusCode::CONFLICT {
                if attempt + 1 < NODE_CONFIG_SYNC_ATTEMPTS {
                    continue;
                }
                return Err(controller_failure("NODE_CONFIG_CONFLICT", true));
            }
            if response.status() == StatusCode::NOT_FOUND {
                return Err(controller_failure("NODE_CONFIG_NOT_READY", true));
            }

            let updated: NodeConfigDocument = self.decode(response)?;
            validate_node_config_document(&updated, node_id)?;
            if updated.revision <= current.revision || updated.config != desired {
                return Err(controller_failure("NODE_CONFIG_RECEIPT_MISMATCH", false));
            }
            return Ok(());
        }

        Err(controller_failure("NODE_CONFIG_CONFLICT", true))
    }
}

fn validate_node_config_document(
    document: &NodeConfigDocument,
    expected_node_id: Uuid,
) -> Result<(), ControllerBoundaryFailure> {
    if document.api_version != NODE_CONFIG_API_VERSION
        || document.node_id != expected_node_id
        || document.revision < 0
        || document.config.validate().is_err()
    {
        return Err(controller_failure("NODE_CONFIG_RESPONSE_INVALID", false));
    }
    Ok(())
}

fn desired_node_config(
    record: &ComputerRecord,
    current: &NodeConfig,
) -> Result<NodeConfig, ControllerBoundaryFailure> {
    let mut labels = current.labels.clone();
    let allowed_job_kinds = record
        .configuration
        .allowed_job_kinds
        .iter()
        .copied()
        .map(controller_job_kind_name)
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect::<Vec<_>>()
        .join(",");
    let resource = serde_json::to_string(&ResourcePolicyLabel {
        cpu_limit_percent: record.configuration.resources.cpu_limit_percent,
        maximum_parallel_jobs: record.configuration.resources.maximum_parallel_jobs,
        memory_limit_bytes: record.configuration.resources.memory_limit_bytes,
    })
    .map_err(|_| controller_failure("NODE_CONFIG_SERIALIZATION_FAILED", false))?;
    let battery = serde_json::to_string(&BatteryPolicyLabel {
        allow_on_battery: record.configuration.allow_on_battery,
    })
    .map_err(|_| controller_failure("NODE_CONFIG_SERIALIZATION_FAILED", false))?;
    labels.insert(POLICY_ALLOWED_JOB_KINDS.to_owned(), allowed_job_kinds);
    labels.insert(POLICY_RESOURCE.to_owned(), resource);
    labels.insert(POLICY_BATTERY.to_owned(), battery);

    let display_name_was_defaulted = record.display_name.trim() == record.endpoint.host.trim();
    let name = if display_name_was_defaulted {
        record
            .inventory
            .as_ref()
            .map(|inventory| inventory.hostname.clone())
            .unwrap_or_else(|| record.display_name.clone())
    } else {
        record.display_name.clone()
    };
    let mut capacity = current.capacity.clone();
    capacity.max_concurrent_jobs = record
        .configuration
        .resources
        .maximum_parallel_jobs
        .map(u32::from)
        .unwrap_or(1);
    capacity.allocatable_cpu_percent = record.configuration.resources.cpu_limit_percent;
    capacity.memory_limit_mib = record
        .configuration
        .resources
        .memory_limit_bytes
        .map(|bytes| bytes / (1024 * 1024));
    capacity.allowed_job_kinds = record
        .configuration
        .allowed_job_kinds
        .iter()
        .copied()
        .map(protocol_job_kind)
        .collect();
    capacity.allow_on_battery = record.configuration.allow_on_battery;
    let desired = NodeConfig {
        name,
        enabled: true,
        priority: record.configuration.priority,
        labels,
        desired_state: current.desired_state,
        capacity,
    };
    desired
        .validate()
        .map_err(|_| controller_failure("NODE_CONFIG_INVALID", false))?;
    Ok(desired)
}

const fn protocol_job_kind(value: AllowedJobKind) -> JobKind {
    match value {
        AllowedJobKind::Build => JobKind::Build,
        AllowedJobKind::Test => JobKind::Test,
        AllowedJobKind::StaticAnalysis => JobKind::Lint,
        AllowedJobKind::Compute
        | AllowedJobKind::DataTransform
        | AllowedJobKind::MediaTransform
        | AllowedJobKind::Render => JobKind::Batch,
        AllowedJobKind::Gpu => JobKind::Gpu,
        AllowedJobKind::Container => JobKind::Container,
        AllowedJobKind::Service => JobKind::Shell,
    }
}

const fn controller_job_kind_name(value: AllowedJobKind) -> &'static str {
    match value {
        AllowedJobKind::Build => "build",
        AllowedJobKind::Test => "test",
        AllowedJobKind::StaticAnalysis => "lint",
        AllowedJobKind::Compute
        | AllowedJobKind::DataTransform
        | AllowedJobKind::MediaTransform
        | AllowedJobKind::Render => "batch",
        AllowedJobKind::Gpu => "gpu",
        AllowedJobKind::Container => "container",
        AllowedJobKind::Service => "shell",
    }
}

fn controller_driver_failure(failure: ControllerBoundaryFailure) -> DriverFailure {
    DriverFailure::new(failure.code.as_str(), failure.retryable)
        .expect("validated controller failure code remains valid")
}

impl ControllerBoundary for HttpControllerBoundary {
    fn issue_enrollment(
        &self,
        operation_id: &str,
        intended_node_id: Uuid,
        existing_pairing_id: Option<Uuid>,
    ) -> Result<EnrollmentBundleV1, ControllerBoundaryFailure> {
        // The controller durably replays the exact bundle only while the
        // original idempotency operation is still Pending. The provisioning
        // driver polls first, so this replay is used after `pairing_id` has
        // already been checkpointed and never after consumption.
        let response = self
            .request(Method::POST, "/v1/pairings")?
            .header(CONTENT_TYPE, "application/json")
            .header("idempotency-key", operation_id)
            .json(&serde_json::json!({ "intendedNodeId": intended_node_id }))
            .send()
            .map_err(|_| controller_failure("CONTROLLER_UNAVAILABLE", true))?;
        let bundle: EnrollmentBundleV1 = self.decode(response)?;
        bundle
            .validate()
            .map_err(|_| controller_failure("ENROLLMENT_INVALID", false))?;
        if bundle.intended_node_id != intended_node_id {
            return Err(controller_failure("NODE_ID_MISMATCH", false));
        }
        if existing_pairing_id.is_some_and(|pairing_id| pairing_id != bundle.pairing_id) {
            return Err(controller_failure("PAIRING_ID_MISMATCH", false));
        }
        Ok(bundle)
    }

    fn poll_pairing(
        &self,
        pairing_id: Uuid,
        intended_node_id: Uuid,
    ) -> Result<PairingObservation, ControllerBoundaryFailure> {
        let response = self
            .request(Method::GET, &format!("/v1/pairings/{pairing_id}"))?
            .send()
            .map_err(|_| controller_failure("CONTROLLER_UNAVAILABLE", true))?;
        let status: PairingStatusV1 = self.decode(response)?;
        pairing_observation_from_status(status, pairing_id, intended_node_id)
    }

    fn report_pairing_failure(
        &self,
        pairing_id: Uuid,
        code: PairingFailureCodeV1,
    ) -> Result<(), ControllerBoundaryFailure> {
        let response = self
            .request(Method::PUT, &format!("/v1/pairings/{pairing_id}/failure"))?
            .header(CONTENT_TYPE, "application/json")
            .json(&ReportPairingFailureRequest { code })
            .send()
            .map_err(|_| controller_failure("CONTROLLER_UNAVAILABLE", true))?;
        self.send_empty(response)
    }

    fn poll_heartbeat(
        &self,
        node_id: Uuid,
        received_after: DateTime<Utc>,
    ) -> Result<Option<DateTime<Utc>>, ControllerBoundaryFailure> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct FleetProbe {
            nodes: Vec<Node>,
        }

        let response = self
            .request(Method::GET, "/v1/fleet")?
            .send()
            .map_err(|_| controller_failure("CONTROLLER_UNAVAILABLE", true))?;
        let fleet: FleetProbe = self.decode(response)?;
        Ok(fleet
            .nodes
            .into_iter()
            .find(|node| node.id == node_id)
            .and_then(|node| node.last_seen_at)
            .filter(|received_at| *received_at > received_after))
    }

    fn prepare_smoke_check(
        &self,
        node_id: Uuid,
        operation_id: &str,
        job_id: Uuid,
    ) -> Result<SmokeRunBindingV1, ControllerBoundaryFailure> {
        self.smoke
            .prepare_node_smoke(node_id, operation_id, job_id)
            .map_err(controller_smoke_failure)
    }

    fn run_smoke_check(
        &self,
        binding: &SmokeRunBindingV1,
    ) -> Result<Option<DateTime<Utc>>, ControllerBoundaryFailure> {
        self.smoke
            .run_node_smoke(binding)
            .map(Some)
            .map_err(controller_smoke_failure)
    }

    fn revoke_pairing(
        &self,
        pairing_id: Uuid,
        operation_id: &str,
    ) -> Result<(), ControllerBoundaryFailure> {
        let response = self
            .request(Method::POST, &format!("/v1/pairings/{pairing_id}/revoke"))?
            .header("idempotency-key", operation_id)
            .send()
            .map_err(|_| controller_failure("CONTROLLER_UNAVAILABLE", true))?;
        self.send_empty(response)
    }
}

fn pairing_observation_from_status(
    status: PairingStatusV1,
    pairing_id: Uuid,
    intended_node_id: Uuid,
) -> Result<PairingObservation, ControllerBoundaryFailure> {
    status
        .validate()
        .map_err(|_| controller_failure("PAIRING_STATUS_INVALID", false))?;
    if status.pairing_id != pairing_id || status.intended_node_id != intended_node_id {
        return Err(controller_failure("PAIRING_ID_MISMATCH", false));
    }
    match status.phase {
        PairingPhaseV1::Pending => Ok(PairingObservation::Pending),
        PairingPhaseV1::Consumed => Ok(PairingObservation::Consumed),
        PairingPhaseV1::Ready => status
            .node_id
            .map(|node_id| PairingObservation::Paired { node_id })
            .ok_or_else(|| controller_failure("PAIRING_STATUS_INVALID", false)),
        PairingPhaseV1::Expired => Err(controller_failure("PAIRING_EXPIRED", false)),
        PairingPhaseV1::Revoked => Err(controller_failure("PAIRING_REVOKED", false)),
        PairingPhaseV1::Failed => {
            if status.node_id.is_some()
                || status.consumed_at.is_some()
                || status.revoked_at.is_some()
                || status.ready
            {
                return Err(controller_failure("PAIRING_STATUS_INVALID", false));
            }
            let failure = pairing_status_failure(
                status
                    .error
                    .as_ref()
                    .ok_or_else(|| controller_failure("PAIRING_STATUS_INVALID", false))?,
            )?;
            Err(failure)
        }
    }
}

fn pairing_status_failure(
    error: &PairingStatusErrorV1,
) -> Result<ControllerBoundaryFailure, ControllerBoundaryFailure> {
    error
        .validate()
        .map_err(|_| controller_failure("PAIRING_STATUS_INVALID", false))?;
    if error.retryable {
        return Err(controller_failure("PAIRING_STATUS_INVALID", false));
    }
    let code = match error.code {
        PairingFailureCodeV1::ProvisioningFailed => "PAIRING_PROVISIONING_FAILED",
        PairingFailureCodeV1::WorkerInstallFailed => "PAIRING_WORKER_INSTALL_FAILED",
        PairingFailureCodeV1::WorkerPairingFailed => "PAIRING_WORKER_PAIRING_FAILED",
        PairingFailureCodeV1::WorkerHealthCheckFailed => "PAIRING_WORKER_HEALTH_CHECK_FAILED",
    };
    Ok(controller_failure(code, false))
}

fn controller_failure(code: &str, retryable: bool) -> ControllerBoundaryFailure {
    ControllerBoundaryFailure::new(code, retryable)
        .expect("constant controller failure code is valid")
}

fn controller_smoke_failure(failure: NodeSmokeError) -> ControllerBoundaryFailure {
    controller_failure(&failure.code, failure.retryable)
}

fn status_failure(status: StatusCode) -> ControllerBoundaryFailure {
    match status {
        StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => {
            controller_failure("CONTROLLER_AUTH_UNAVAILABLE", false)
        }
        StatusCode::NOT_FOUND => controller_failure("CONTROLLER_RECORD_NOT_FOUND", false),
        StatusCode::CONFLICT => controller_failure("CONTROLLER_CONFLICT", true),
        StatusCode::TOO_MANY_REQUESTS => controller_failure("CONTROLLER_RATE_LIMITED", true),
        status if status.is_server_error() => controller_failure("CONTROLLER_UNAVAILABLE", true),
        _ => controller_failure("CONTROLLER_REQUEST_REJECTED", false),
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StartComputerRequest {
    record_id: String,
    intended_node_id: String,
    display_name: String,
    host: String,
    port: u16,
    username: String,
    #[serde(default)]
    authentication_method: SshAuthenticationMethodInput,
    #[serde(default)]
    private_key_path: String,
    #[serde(default)]
    password: String,
    #[serde(default)]
    passphrase: String,
    #[serde(default = "default_true")]
    remember_password: bool,
    #[serde(default)]
    advanced: AdvancedOptionsRequest,
}

impl StartComputerRequest {
    fn take_authentication(
        &mut self,
    ) -> Result<(SshAuthenticationPolicy, Option<Secret>), PublicProvisioningError> {
        match self.authentication_method {
            SshAuthenticationMethodInput::Password => {
                if !self.private_key_path.is_empty() || !self.passphrase.is_empty() {
                    return Err(PublicProvisioningError::new("invalid_request", false));
                }
                validate_authentication_secret(&self.password, false)?;
                Ok((
                    SshAuthenticationPolicy::password(),
                    Some(Secret::from_string(std::mem::take(&mut self.password))),
                ))
            }
            SshAuthenticationMethodInput::Agent => {
                if !self.password.is_empty()
                    || !self.passphrase.is_empty()
                    || !self.private_key_path.is_empty()
                    || self.remember_password
                {
                    return Err(PublicProvisioningError::new("invalid_request", false));
                }
                Ok((SshAuthenticationPolicy::agent(), None))
            }
            SshAuthenticationMethodInput::PrivateKey => {
                if !self.password.is_empty()
                    || self.private_key_path.is_empty()
                    || self.remember_password
                {
                    return Err(PublicProvisioningError::new("invalid_request", false));
                }
                validate_authentication_secret(&self.passphrase, true)?;
                let path = std::mem::take(&mut self.private_key_path);
                let private_key = PrivateKeyFile::new(path)
                    .map_err(|_| PublicProvisioningError::new("private_key_invalid", false))?;
                let policy = SshAuthenticationPolicy::private_key(&private_key)
                    .map_err(|_| PublicProvisioningError::new("private_key_invalid", false))?;
                let passphrase = if self.passphrase.is_empty() {
                    None
                } else {
                    Some(Secret::from_string(std::mem::take(&mut self.passphrase)))
                };
                Ok((policy, passphrase))
            }
        }
    }
}

impl Drop for StartComputerRequest {
    fn drop(&mut self) {
        self.password.zeroize();
        self.passphrase.zeroize();
        self.private_key_path.zeroize();
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SecretActionRequest {
    id: String,
    revision: u64,
    #[serde(default)]
    password: String,
    #[serde(default)]
    passphrase: String,
}

impl SecretActionRequest {
    fn take_secret(
        &mut self,
        method: SshAuthenticationMethod,
    ) -> Result<Option<Secret>, PublicProvisioningError> {
        let value = match method {
            SshAuthenticationMethod::Password => {
                if !self.passphrase.is_empty() {
                    return Err(PublicProvisioningError::new("invalid_request", false));
                }
                &mut self.password
            }
            SshAuthenticationMethod::Agent => {
                if !self.password.is_empty() || !self.passphrase.is_empty() {
                    return Err(PublicProvisioningError::new("invalid_request", false));
                }
                return Ok(None);
            }
            SshAuthenticationMethod::PrivateKey => {
                if !self.password.is_empty() {
                    return Err(PublicProvisioningError::new("invalid_request", false));
                }
                &mut self.passphrase
            }
        };
        if value.is_empty() {
            return Ok(None);
        }
        validate_authentication_secret(value, false)?;
        Ok(Some(Secret::from_string(std::mem::take(value))))
    }
}

impl Drop for SecretActionRequest {
    fn drop(&mut self) {
        self.password.zeroize();
        self.passphrase.zeroize();
    }
}

#[derive(Clone, Copy, Debug, Default, Deserialize)]
#[serde(rename_all = "snake_case")]
enum SshAuthenticationMethodInput {
    #[default]
    Password,
    Agent,
    PrivateKey,
}

fn default_true() -> bool {
    true
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct AdvancedOptionsRequest {
    #[serde(default)]
    service_scope: ServiceScopeInput,
    #[serde(default)]
    workspace: Option<String>,
    #[serde(default)]
    priority: i32,
    #[serde(default)]
    maximum_parallel_jobs: Option<u16>,
    #[serde(default)]
    cpu_limit_percent: Option<u8>,
    #[serde(default)]
    memory_limit_mi_b: Option<u64>,
    #[serde(default = "default_allowed_job_kinds")]
    allowed_job_kinds: Vec<AllowedJobKindInput>,
    #[serde(default)]
    allow_on_battery: bool,
}

impl Default for AdvancedOptionsRequest {
    fn default() -> Self {
        Self {
            service_scope: ServiceScopeInput::Auto,
            workspace: None,
            priority: 0,
            maximum_parallel_jobs: None,
            cpu_limit_percent: None,
            memory_limit_mi_b: None,
            allowed_job_kinds: default_allowed_job_kinds(),
            allow_on_battery: false,
        }
    }
}

impl AdvancedOptionsRequest {
    fn into_configuration(self) -> Result<ComputerConfiguration, PublicProvisioningError> {
        let memory_limit_bytes = match self.memory_limit_mi_b {
            Some(value) => Some(
                value
                    .checked_mul(1024 * 1024)
                    .ok_or_else(|| PublicProvisioningError::new("invalid_request", false))?,
            ),
            None => None,
        };
        let configuration = ComputerConfiguration {
            service_scope: self.service_scope.into(),
            workspace: self.workspace.filter(|value| !value.is_empty()),
            priority: self.priority,
            resources: ResourcePolicy {
                maximum_parallel_jobs: self.maximum_parallel_jobs,
                cpu_limit_percent: self.cpu_limit_percent,
                memory_limit_bytes,
            },
            allowed_job_kinds: self
                .allowed_job_kinds
                .into_iter()
                .map(AllowedJobKind::from)
                .collect(),
            allow_on_battery: self.allow_on_battery,
        };
        configuration.validate()?;
        Ok(configuration)
    }
}

#[derive(Clone, Copy, Debug, Default, Deserialize)]
#[serde(rename_all = "snake_case")]
enum ServiceScopeInput {
    #[default]
    Auto,
    User,
    System,
}

impl From<ServiceScopeInput> for ServiceScope {
    fn from(value: ServiceScopeInput) -> Self {
        match value {
            ServiceScopeInput::Auto => Self::Auto,
            ServiceScopeInput::User => Self::User,
            ServiceScopeInput::System => Self::System,
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
enum AllowedJobKindInput {
    Build,
    Test,
    StaticAnalysis,
    Compute,
    Gpu,
    Container,
    Service,
    DataTransform,
    MediaTransform,
    Render,
}

impl From<AllowedJobKindInput> for AllowedJobKind {
    fn from(value: AllowedJobKindInput) -> Self {
        match value {
            AllowedJobKindInput::Build => Self::Build,
            AllowedJobKindInput::Test => Self::Test,
            AllowedJobKindInput::StaticAnalysis => Self::StaticAnalysis,
            AllowedJobKindInput::Compute => Self::Compute,
            AllowedJobKindInput::Gpu => Self::Gpu,
            AllowedJobKindInput::Container => Self::Container,
            AllowedJobKindInput::Service => Self::Service,
            AllowedJobKindInput::DataTransform => Self::DataTransform,
            AllowedJobKindInput::MediaTransform => Self::MediaTransform,
            AllowedJobKindInput::Render => Self::Render,
        }
    }
}

fn default_allowed_job_kinds() -> Vec<AllowedJobKindInput> {
    vec![
        AllowedJobKindInput::Build,
        AllowedJobKindInput::Test,
        AllowedJobKindInput::Compute,
    ]
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ComputerIdRequest {
    id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RevisionRequest {
    id: String,
    revision: u64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ApproveHostKeyRequest {
    id: String,
    revision: u64,
    fingerprint: String,
}

#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
enum ProvisioningAttention {
    None,
    HostKey,
    Credential,
    External,
    Intent,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProvisioningOperationResult {
    outcome: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    computer: Option<ProvisioningComputerView>,
    #[serde(skip_serializing_if = "Option::is_none")]
    removed_id: Option<String>,
}

impl ProvisioningOperationResult {
    fn computer(outcome: &'static str, computer: ProvisioningComputerView) -> Self {
        Self {
            outcome,
            computer: Some(computer),
            removed_id: None,
        }
    }

    fn removed(id: Uuid) -> Self {
        Self {
            outcome: "removed",
            computer: None,
            removed_id: Some(id.to_string()),
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProvisioningComputerView {
    id: String,
    display_name: String,
    endpoint: EndpointView,
    state: &'static str,
    step: &'static str,
    attention: Option<&'static str>,
    intent: &'static str,
    revision: u64,
    cycle: u32,
    intended_node_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    paired_node_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    host_key: Option<HostKeyView>,
    #[serde(skip_serializing_if = "Option::is_none")]
    inventory: Option<InventoryView>,
    credential: CredentialView,
    configuration: AdvancedOptionsView,
    #[serde(skip_serializing_if = "Option::is_none")]
    failure: Option<FailureView>,
    created_at: String,
    updated_at: String,
}

impl ProvisioningComputerView {
    fn from_record(
        record: &ComputerRecord,
        attention: ProvisioningAttention,
    ) -> Result<Self, PublicProvisioningError> {
        let (state, failure) = match &record.state {
            ProvisioningState::Failed {
                code, retryable, ..
            } => (
                "failed",
                Some(FailureView {
                    code: code.as_str().to_owned(),
                    retryable: *retryable,
                }),
            ),
            state => (state.active_step().as_str(), None),
        };
        let memory_limit_mi_b = record
            .configuration
            .resources
            .memory_limit_bytes
            .map(|bytes| bytes / 1024 / 1024);
        Ok(Self {
            id: record.id.to_string(),
            display_name: record.display_name.clone(),
            endpoint: EndpointView {
                host: record.endpoint.host.clone(),
                port: record.endpoint.port,
                username: record.endpoint.username.clone(),
            },
            state,
            step: record.state.active_step().as_str(),
            attention: match attention {
                ProvisioningAttention::None => None,
                ProvisioningAttention::HostKey => Some("host_key"),
                ProvisioningAttention::Credential => Some("credential"),
                ProvisioningAttention::External => Some("external"),
                ProvisioningAttention::Intent => Some("intent"),
            },
            intent: intent_name(record.intent),
            revision: record.revision,
            cycle: record.cycle,
            intended_node_id: record.intended_node_id.to_string(),
            paired_node_id: record.paired_node_id.map(|id| id.to_string()),
            host_key: record.host_key.as_ref().map(|host_key| HostKeyView {
                algorithm: host_key.algorithm.clone(),
                fingerprint: host_key.fingerprint.clone(),
                approved: record.host_key_approved_at.is_some(),
            }),
            inventory: record.inventory.as_ref().map(InventoryView::from),
            credential: CredentialView {
                authentication_method: record.ssh_authentication.method().as_str(),
                remember_requested: record.credential_policy.remember_requested,
                state: credential_state_name(record.credential_policy.state),
            },
            configuration: AdvancedOptionsView {
                service_scope: record.configuration.service_scope.as_str(),
                workspace: record.configuration.workspace.clone(),
                priority: record.configuration.priority,
                maximum_parallel_jobs: record.configuration.resources.maximum_parallel_jobs,
                cpu_limit_percent: record.configuration.resources.cpu_limit_percent,
                memory_limit_mi_b,
                allowed_job_kinds: record
                    .configuration
                    .allowed_job_kinds
                    .iter()
                    .copied()
                    .map(allowed_job_kind_name)
                    .collect(),
                allow_on_battery: record.configuration.allow_on_battery,
            },
            failure,
            created_at: timestamp(record.created_at),
            updated_at: timestamp(record.updated_at),
        })
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct EndpointView {
    host: String,
    port: u16,
    username: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct HostKeyView {
    algorithm: String,
    fingerprint: String,
    approved: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct CredentialView {
    authentication_method: &'static str,
    remember_requested: bool,
    state: &'static str,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct FailureView {
    code: String,
    retryable: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AdvancedOptionsView {
    service_scope: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    workspace: Option<String>,
    priority: i32,
    #[serde(skip_serializing_if = "Option::is_none")]
    maximum_parallel_jobs: Option<u16>,
    #[serde(skip_serializing_if = "Option::is_none")]
    cpu_limit_percent: Option<u8>,
    #[serde(skip_serializing_if = "Option::is_none")]
    memory_limit_mi_b: Option<u64>,
    allowed_job_kinds: Vec<&'static str>,
    allow_on_battery: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct InventoryView {
    hostname: String,
    operating_system: String,
    architecture: String,
    cpu_model: String,
    logical_cpu_count: u32,
    memory_bytes: u64,
    workspace_free_bytes: u64,
    gpu_devices: Vec<GpuView>,
    toolchains: BTreeMap<String, String>,
}

impl From<&cyc_provision::DiscoveredComputer> for InventoryView {
    fn from(value: &cyc_provision::DiscoveredComputer) -> Self {
        Self {
            hostname: value.hostname.clone(),
            operating_system: value.operating_system.clone(),
            architecture: value.architecture.clone(),
            cpu_model: value.cpu_model.clone(),
            logical_cpu_count: value.logical_cpu_count,
            memory_bytes: value.memory_bytes,
            workspace_free_bytes: value.workspace_free_bytes,
            gpu_devices: value
                .gpu_devices
                .iter()
                .map(|gpu| GpuView {
                    name: gpu.name.clone(),
                    memory_bytes: gpu.memory_bytes,
                })
                .collect(),
            toolchains: value.toolchains.clone(),
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct GpuView {
    name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    memory_bytes: Option<u64>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PublicProvisioningError {
    code: String,
    retryable: bool,
}

impl PublicProvisioningError {
    fn new(code: impl Into<String>, retryable: bool) -> Self {
        Self {
            code: code.into(),
            retryable,
        }
    }

    pub(crate) fn operation_unavailable() -> Self {
        Self::new("operation_unavailable", false)
    }

    pub(crate) fn initialization_unavailable(code: &'static str) -> Self {
        Self::new(code, false)
    }
}

impl From<ProvisioningError> for PublicProvisioningError {
    fn from(value: ProvisioningError) -> Self {
        match value {
            ProvisioningError::Store(error) => error.into(),
            ProvisioningError::Validation(_) => Self::new("invalid_request", false),
            ProvisioningError::Driver(failure) => {
                Self::new(failure.code.as_str(), failure.retryable)
            }
            ProvisioningError::InvalidOperation(_) => Self::new("operation_unavailable", false),
            ProvisioningError::HostKeyApprovalMismatch => Self::new("host_key_mismatch", false),
            ProvisioningError::IdempotencyConflict => {
                Self::new("start_idempotency_conflict", false)
            }
            ProvisioningError::InvalidIdentity => Self::new("invalid_id", false),
            ProvisioningError::CycleOverflow => Self::new("operation_unavailable", false),
        }
    }
}

impl From<StoreError> for PublicProvisioningError {
    fn from(value: StoreError) -> Self {
        match value {
            StoreError::NotFound(_) => Self::new("not_found", false),
            StoreError::Conflict { .. } => Self::new("revision_conflict", true),
            StoreError::Validation(_) | StoreError::InvalidInitialRevision => {
                Self::new("invalid_request", false)
            }
            StoreError::AlreadyExists(_)
            | StoreError::ImmutableFieldChanged
            | StoreError::RevisionOverflow => Self::new("operation_unavailable", false),
            StoreError::Sqlite(_)
            | StoreError::Serialization(_)
            | StoreError::UnsupportedSchema(_)
            | StoreError::LockPoisoned
            | StoreError::CorruptRecord => Self::new("provisioning_store_unavailable", false),
        }
    }
}

impl From<cyc_provision::RecordValidationError> for PublicProvisioningError {
    fn from(_: cyc_provision::RecordValidationError) -> Self {
        Self::new("invalid_request", false)
    }
}

#[derive(Debug, Error)]
pub enum ProvisioningInitializationError {
    #[error("provisioning data directory is unavailable")]
    DataDirectory,
    #[error("provisioning store initialization failed")]
    Store(#[from] StoreError),
    #[error("native credential vault initialization failed")]
    Vault(#[from] VaultError),
    #[error("worker-kit catalog initialization failed")]
    WorkerKit(#[from] WorkerKitError),
    #[error("controller client initialization failed")]
    ControllerClient,
    #[error("executable directory is unavailable")]
    ExecutableDirectory,
}

impl ProvisioningInitializationError {
    pub(crate) const fn public_code(&self) -> &'static str {
        match self {
            Self::WorkerKit(_) => "worker_kit_catalog_unavailable",
            Self::DataDirectory | Self::Store(_) => "provisioning_store_unavailable",
            Self::Vault(_) => "credential_store_unavailable",
            Self::ControllerClient => "controller_unavailable",
            Self::ExecutableDirectory => "provisioning_unavailable",
        }
    }
}

fn parse_id(value: &str) -> Result<Uuid, PublicProvisioningError> {
    Uuid::parse_str(value).map_err(|_| PublicProvisioningError::new("invalid_id", false))
}

fn validate_authentication_secret(
    value: &str,
    empty_allowed: bool,
) -> Result<(), PublicProvisioningError> {
    if (!empty_allowed && value.is_empty())
        || value.len() > MAX_AUTHENTICATION_SECRET_BYTES
        || value.contains('\0')
    {
        return Err(PublicProvisioningError::new("invalid_request", false));
    }
    Ok(())
}

fn validate_fingerprint(value: &str) -> Result<(), PublicProvisioningError> {
    if !value.starts_with("SHA256:")
        || !(32..=256).contains(&value.len())
        || value.chars().any(char::is_whitespace)
    {
        return Err(PublicProvisioningError::new("invalid_request", false));
    }
    Ok(())
}

fn timestamp(value: DateTime<Utc>) -> String {
    value.to_rfc3339_opts(SecondsFormat::Millis, true)
}

fn intent_name(value: ProvisioningIntent) -> &'static str {
    match value {
        ProvisioningIntent::Continue => "continue",
        ProvisioningIntent::Resume => "resume",
        ProvisioningIntent::Retry => "retry",
        ProvisioningIntent::Rollback => "rollback",
        ProvisioningIntent::Remove => "remove",
    }
}

fn credential_state_name(value: CredentialState) -> &'static str {
    match value {
        CredentialState::Pending => "pending",
        CredentialState::SessionOnly => "session_only",
        CredentialState::Stored => "stored",
        CredentialState::Forgotten => "forgotten",
    }
}

fn allowed_job_kind_name(value: AllowedJobKind) -> &'static str {
    match value {
        AllowedJobKind::Build => "build",
        AllowedJobKind::Test => "test",
        AllowedJobKind::StaticAnalysis => "static_analysis",
        AllowedJobKind::Compute => "compute",
        AllowedJobKind::Gpu => "gpu",
        AllowedJobKind::Container => "container",
        AllowedJobKind::Service => "service",
        AllowedJobKind::DataTransform => "data_transform",
        AllowedJobKind::MediaTransform => "media_transform",
        AllowedJobKind::Render => "render",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cyc_provision::{
        DiscoveredComputer, DriverRequest, PinnedHostKeyRecord, ProvisioningAction, StepCompletion,
    };
    use cyc_ssh::HostKey;

    const PASSWORD: &str = "test-password-that-must-not-persist";
    const PASSPHRASE: &str = "test-private-key-passphrase-must-not-persist";

    #[test]
    fn smoke_boundary_preserves_failure_code_and_retryability() {
        let retryable = controller_smoke_failure(NodeSmokeError {
            code: "SMOKE_EXECUTION_TIMEOUT".to_owned(),
            retryable: true,
        });
        assert_eq!(retryable.code.as_str(), "SMOKE_EXECUTION_TIMEOUT");
        assert!(retryable.retryable);

        let terminal = controller_smoke_failure(NodeSmokeError {
            code: "SMOKE_BINDING_MISMATCH".to_owned(),
            retryable: false,
        });
        assert_eq!(terminal.code.as_str(), "SMOKE_BINDING_MISMATCH");
        assert!(!terminal.retryable);
    }

    #[test]
    fn pairing_status_failure_codes_are_bounded_and_terminal() {
        let cases = [
            (
                PairingFailureCodeV1::ProvisioningFailed,
                "PAIRING_PROVISIONING_FAILED",
            ),
            (
                PairingFailureCodeV1::WorkerInstallFailed,
                "PAIRING_WORKER_INSTALL_FAILED",
            ),
            (
                PairingFailureCodeV1::WorkerPairingFailed,
                "PAIRING_WORKER_PAIRING_FAILED",
            ),
            (
                PairingFailureCodeV1::WorkerHealthCheckFailed,
                "PAIRING_WORKER_HEALTH_CHECK_FAILED",
            ),
        ];
        for (code, expected) in cases {
            let failure = pairing_status_failure(&PairingStatusErrorV1 {
                code,
                message: "Canonical controller failure".to_owned(),
                retryable: false,
            })
            .unwrap();
            assert_eq!(failure.code.as_str(), expected);
            assert!(!failure.retryable);
        }
    }

    #[test]
    fn retryable_pairing_failed_status_is_rejected_and_expired_is_terminal() {
        let pairing_id = Uuid::new_v4();
        let intended_node_id = Uuid::new_v4();
        let created_at = Utc::now();
        let failed = PairingStatusV1 {
            api_version: "cyc.dev/enrollment/v1".to_owned(),
            pairing_id,
            intended_node_id,
            node_id: None,
            phase: PairingPhaseV1::Failed,
            created_at,
            expires_at: created_at + chrono::Duration::minutes(10),
            consumed_at: None,
            revoked_at: None,
            ready: false,
            error: Some(PairingStatusErrorV1 {
                code: PairingFailureCodeV1::WorkerPairingFailed,
                message: "Canonical controller failure".to_owned(),
                retryable: true,
            }),
        };
        let invalid =
            pairing_observation_from_status(failed, pairing_id, intended_node_id).unwrap_err();
        assert_eq!(invalid.code.as_str(), "PAIRING_STATUS_INVALID");
        assert!(!invalid.retryable);

        let expired = PairingStatusV1 {
            api_version: "cyc.dev/enrollment/v1".to_owned(),
            pairing_id,
            intended_node_id,
            node_id: None,
            phase: PairingPhaseV1::Expired,
            created_at,
            expires_at: created_at + chrono::Duration::minutes(10),
            consumed_at: None,
            revoked_at: None,
            ready: false,
            error: None,
        };
        let terminal =
            pairing_observation_from_status(expired, pairing_id, intended_node_id).unwrap_err();
        assert_eq!(terminal.code.as_str(), "PAIRING_EXPIRED");
        assert!(!terminal.retryable);
    }

    #[test]
    fn failed_pairing_rejects_consumed_or_ready_evidence() {
        let pairing_id = Uuid::new_v4();
        let intended_node_id = Uuid::new_v4();
        let created_at = Utc::now();
        let failed = PairingStatusV1 {
            api_version: "cyc.dev/enrollment/v1".to_owned(),
            pairing_id,
            intended_node_id,
            node_id: Some(intended_node_id),
            phase: PairingPhaseV1::Failed,
            created_at,
            expires_at: created_at + chrono::Duration::minutes(10),
            consumed_at: Some(created_at),
            revoked_at: None,
            ready: false,
            error: Some(PairingStatusErrorV1 {
                code: PairingFailureCodeV1::WorkerPairingFailed,
                message: "Canonical controller failure".to_owned(),
                retryable: false,
            }),
        };
        let invalid =
            pairing_observation_from_status(failed, pairing_id, intended_node_id).unwrap_err();
        assert_eq!(invalid.code.as_str(), "PAIRING_STATUS_INVALID");
        assert!(!invalid.retryable);
    }

    #[test]
    fn pairing_failure_report_body_contains_only_the_code() {
        let wire = serde_json::to_value(ReportPairingFailureRequest {
            code: PairingFailureCodeV1::WorkerPairingFailed,
        })
        .unwrap();
        assert_eq!(wire, serde_json::json!({ "code": "worker_pairing_failed" }));
        let text = wire.to_string();
        for forbidden in ["message", "retryable", "detail", "secret", "token"] {
            assert!(!text.contains(forbidden));
        }
    }

    struct CheckpointDriver;

    impl ProvisioningDriver for CheckpointDriver {
        fn execute(
            &mut self,
            request: &DriverRequest<'_>,
        ) -> Result<StepCompletion, DriverFailure> {
            match request.action {
                ProvisioningAction::BeginSsh => Ok(StepCompletion::SshStarted),
                ProvisioningAction::ProbeHostKey => {
                    let key =
                        HostKey::from_parts("ssh-ed25519", vec![1, 2, 3, 4]).expect("host key");
                    Ok(StepCompletion::HostKeyObserved(PinnedHostKeyRecord::from(
                        &key,
                    )))
                }
                ProvisioningAction::Authenticate => Ok(StepCompletion::AuthenticatedSessionOnly),
                ProvisioningAction::BeginDiscovery => Ok(StepCompletion::DiscoveryStarted),
                ProvisioningAction::DiscoverAndStoreCredential => {
                    Err(DriverFailure::credential_required())
                }
                _ => Err(DriverFailure::new("TEST_STOP", false).expect("failure")),
            }
        }

        fn rollback(&mut self, _request: &DriverRequest<'_>) -> Result<(), DriverFailure> {
            Ok(())
        }

        fn remove(&mut self, _request: &DriverRequest<'_>) -> Result<(), DriverFailure> {
            Ok(())
        }

        fn forget_credential(&mut self, _request: &DriverRequest<'_>) -> Result<(), DriverFailure> {
            Ok(())
        }
    }

    fn manager(path: &Path) -> ProvisioningManager {
        let store = ProvisioningStore::open(path).expect("store");
        ProvisioningManager::from_parts(
            ProvisioningEngine::new(store),
            Box::new(CheckpointDriver),
            Arc::new(SessionSecretStore::default()),
        )
    }

    fn start_request_with_identity(
        record_id: Uuid,
        intended_node_id: Uuid,
        display_name: &str,
    ) -> StartComputerRequest {
        serde_json::from_value(serde_json::json!({
            "recordId": record_id,
            "intendedNodeId": intended_node_id,
            "displayName": display_name,
            "host": "192.0.2.10",
            "port": 22,
            "username": "builder",
            "password": PASSWORD,
            "rememberPassword": false,
            "advanced": {
                "serviceScope": "auto",
                "priority": 0,
                "allowedJobKinds": ["build", "test"],
                "allowOnBattery": false
            }
        }))
        .expect("request")
    }

    fn start_request() -> StartComputerRequest {
        start_request_with_identity(Uuid::new_v4(), Uuid::new_v4(), "Build worker")
    }

    fn private_key_request(path: &Path, passphrase: &str) -> StartComputerRequest {
        serde_json::from_value(serde_json::json!({
            "recordId": Uuid::new_v4(),
            "intendedNodeId": Uuid::new_v4(),
            "displayName": "Key worker",
            "host": "192.0.2.11",
            "port": 22,
            "username": "builder",
            "authenticationMethod": "private_key",
            "privateKeyPath": path,
            "password": "",
            "passphrase": passphrase,
            "rememberPassword": false,
            "advanced": {
                "serviceScope": "auto",
                "priority": 0,
                "allowedJobKinds": ["build", "test"],
                "allowOnBattery": false
            }
        }))
        .expect("private-key request")
    }

    fn agent_request() -> StartComputerRequest {
        serde_json::from_value(serde_json::json!({
            "recordId": Uuid::new_v4(),
            "intendedNodeId": Uuid::new_v4(),
            "displayName": "Agent worker",
            "host": "192.0.2.12",
            "port": 22,
            "username": "builder",
            "authenticationMethod": "agent",
            "password": "",
            "passphrase": "",
            "rememberPassword": false,
            "advanced": {
                "serviceScope": "auto",
                "priority": 0,
                "allowedJobKinds": ["build", "test"],
                "allowOnBattery": false
            }
        }))
        .expect("agent request")
    }

    fn temporary_database(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "cyc-desktop-provision-{name}-{}-{}.sqlite3",
            std::process::id(),
            Uuid::new_v4()
        ))
    }

    #[test]
    fn password_never_enters_result_or_sqlite_state() {
        let path = temporary_database("secret");
        let manager = manager(&path);
        let result = manager.start(start_request()).expect("start");
        let json = serde_json::to_string(&result).expect("serialize result");
        assert!(!json.contains(PASSWORD));
        assert!(!json.to_ascii_lowercase().contains("\"password\":"));
        drop(manager);
        let database = std::fs::read(&path).expect("database");
        assert!(!database
            .windows(PASSWORD.len())
            .any(|window| window == PASSWORD.as_bytes()));
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn private_key_path_is_native_validated_while_passphrase_stays_transient_and_redacted() {
        let database = temporary_database("private-key-secret");
        let key_dir = std::env::temp_dir().join(format!(
            "cyc-desktop-private-key-{}-{}",
            std::process::id(),
            Uuid::new_v4()
        ));
        std::fs::create_dir(&key_dir).expect("key tempdir");
        let key_path = key_dir.join("id_fixture");
        std::fs::write(&key_path, b"fixture-private-key-material").expect("key fixture");
        let manager = manager(&database);

        let result = manager
            .start(private_key_request(&key_path, PASSPHRASE))
            .expect("start private-key record");
        let view = result.computer.as_ref().expect("computer");
        let id = Uuid::parse_str(&view.id).expect("record id");
        let record = manager.runtime.engine.get(id).expect("durable record");
        assert_eq!(
            record.ssh_authentication.method(),
            SshAuthenticationMethod::PrivateKey
        );
        assert!(!record.credential_policy.remember_requested);
        let json = serde_json::to_string(&result).expect("public result");
        assert!(!json.contains(PASSPHRASE));
        assert!(!json.contains(&key_path.to_string_lossy().to_string()));
        assert!(!format!("{record:?}").contains(&key_path.to_string_lossy().to_string()));
        let transient = manager
            .runtime
            .transient_secrets
            .retrieve(id)
            .expect("transient lookup")
            .expect("passphrase retained for native operation");
        assert_eq!(transient.expose_secret(), PASSPHRASE.as_bytes());
        drop(transient);
        let bytes = std::fs::read(&database).expect("database");
        assert!(!bytes
            .windows(PASSPHRASE.len())
            .any(|window| window == PASSPHRASE.as_bytes()));

        let invalid_path = key_dir.join("missing-key");
        let invalid = manager.start(private_key_request(&invalid_path, PASSPHRASE));
        assert!(matches!(
            invalid,
            Err(ref error) if error.code == "private_key_invalid" && !error.retryable
        ));
        assert!(!format!("{invalid:?}").contains(&invalid_path.to_string_lossy().to_string()));
        let _ = std::fs::remove_file(key_path);
        let _ = std::fs::remove_dir(key_dir);
        let _ = std::fs::remove_file(database);
    }

    #[test]
    fn agent_policy_accepts_no_secret_and_legacy_request_defaults_to_password() {
        let database = temporary_database("agent-auth");
        let manager = manager(&database);
        let result = manager.start(agent_request()).expect("agent record");
        let view = result.computer.as_ref().expect("agent view");
        assert_eq!(view.credential.authentication_method, "agent");
        assert!(!view.credential.remember_requested);
        let id = Uuid::parse_str(&view.id).expect("record id");
        assert!(manager
            .runtime
            .transient_secrets
            .retrieve(id)
            .expect("transient lookup")
            .is_none());

        let legacy = start_request();
        assert!(matches!(
            legacy.authentication_method,
            SshAuthenticationMethodInput::Password
        ));
        let _ = std::fs::remove_file(database);
    }

    #[test]
    fn terminal_results_clear_native_transient_authentication_secrets() {
        let database = temporary_database("ready-secret-clear");
        let manager = manager(&database);
        let record = manager
            .runtime
            .engine
            .create(
                NewComputer::new(
                    "worker",
                    ComputerEndpoint::new("192.0.2.20", 22, "builder").expect("endpoint"),
                )
                .expect("input"),
            )
            .expect("record");
        manager
            .runtime
            .transient_secrets
            .insert(record.id, Secret::from_string(PASSPHRASE.to_owned()))
            .expect("insert transient");

        manager
            .result(DriveOutcome::Ready(record.clone()))
            .expect("ready result");
        assert!(manager
            .runtime
            .transient_secrets
            .retrieve(record.id)
            .expect("retrieve")
            .is_none());

        manager
            .runtime
            .transient_secrets
            .insert(record.id, Secret::from_string(PASSPHRASE.to_owned()))
            .expect("insert transient");
        manager
            .result(DriveOutcome::RolledBack(record.clone()))
            .expect("rolled-back result");
        assert!(manager
            .runtime
            .transient_secrets
            .retrieve(record.id)
            .expect("retrieve")
            .is_none());

        manager
            .runtime
            .transient_secrets
            .insert(record.id, Secret::from_string(PASSWORD.to_owned()))
            .expect("insert transient");
        manager
            .result(DriveOutcome::Removed { id: record.id })
            .expect("removed result");
        assert!(manager
            .runtime
            .transient_secrets
            .retrieve(record.id)
            .expect("retrieve")
            .is_none());
        let _ = std::fs::remove_file(database);
    }

    #[test]
    fn response_loss_retry_reuses_the_same_add_computer_record() {
        let path = temporary_database("start-idempotency");
        let manager = manager(&path);
        let record_id = Uuid::new_v4();
        let intended_node_id = Uuid::new_v4();

        let first = manager
            .start(start_request_with_identity(
                record_id,
                intended_node_id,
                "Build worker",
            ))
            .expect("first start");
        let replayed = manager
            .start(start_request_with_identity(
                record_id,
                intended_node_id,
                "Build worker",
            ))
            .expect("response-loss replay");

        let first_view = first.computer.as_ref().expect("first computer");
        let replayed_view = replayed.computer.as_ref().expect("replayed computer");
        assert_eq!(first_view.id, record_id.to_string());
        assert_eq!(replayed_view.id, first_view.id);
        assert_eq!(replayed_view.intended_node_id, intended_node_id.to_string());
        assert_eq!(manager.list().expect("list computers").len(), 1);

        let conflict = manager.start(start_request_with_identity(
            record_id,
            intended_node_id,
            "Changed worker",
        ));
        assert!(matches!(
            conflict,
            Err(ref error) if error.code == "start_idempotency_conflict" && !error.retryable
        ));
        assert_eq!(manager.list().expect("list after conflict").len(), 1);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn exact_host_key_confirmation_is_required() {
        let path = temporary_database("host-key");
        let manager = manager(&path);
        let started = manager.start(start_request()).expect("start");
        let computer = started.computer.as_ref().expect("computer");
        let fingerprint = computer
            .host_key
            .as_ref()
            .expect("host key")
            .fingerprint
            .clone();
        let wrong = manager.approve_host_key(ApproveHostKeyRequest {
            id: computer.id.clone(),
            revision: computer.revision,
            fingerprint: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".to_owned(),
        });
        assert!(matches!(wrong, Err(ref error) if error.code == "host_key_mismatch"));
        let continued = manager
            .approve_host_key(ApproveHostKeyRequest {
                id: computer.id.clone(),
                revision: computer.revision,
                fingerprint,
            })
            .expect("approve exact key");
        assert_eq!(continued.outcome, "awaiting_credential");
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn restart_recovers_durable_record_and_requests_lost_session_secret() {
        let path = temporary_database("restart");
        let first = manager(&path);
        let started = first.start(start_request()).expect("start");
        let pending = started.computer.as_ref().expect("pending");
        let approved = first
            .approve_host_key(ApproveHostKeyRequest {
                id: pending.id.clone(),
                revision: pending.revision,
                fingerprint: pending
                    .host_key
                    .as_ref()
                    .expect("host key")
                    .fingerprint
                    .clone(),
            })
            .expect("approve");
        assert_eq!(approved.outcome, "awaiting_credential");
        drop(first);

        let reopened = manager(&path);
        let recovered = reopened.list().expect("list");
        assert_eq!(recovered.len(), 1);
        assert_eq!(recovered[0].attention, Some("credential"));
        assert_eq!(recovered[0].credential.state, "session_only");
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn paired_node_config_preserves_user_labels_and_encodes_advanced_policy() {
        let endpoint = ComputerEndpoint::new("192.0.2.44", 22, "builder").expect("endpoint");
        let mut input = NewComputer::new("192.0.2.44", endpoint).expect("computer");
        input.configuration = ComputerConfiguration {
            service_scope: ServiceScope::System,
            workspace: Some("/srv/cyc".to_owned()),
            priority: 730,
            resources: ResourcePolicy {
                maximum_parallel_jobs: Some(3),
                cpu_limit_percent: Some(75),
                memory_limit_bytes: Some(8 * 1024 * 1024 * 1024),
            },
            allowed_job_kinds: [
                AllowedJobKind::Build,
                AllowedJobKind::Test,
                AllowedJobKind::StaticAnalysis,
                AllowedJobKind::Compute,
                AllowedJobKind::Gpu,
                AllowedJobKind::Container,
                AllowedJobKind::Service,
                AllowedJobKind::DataTransform,
                AllowedJobKind::MediaTransform,
                AllowedJobKind::Render,
            ]
            .into_iter()
            .collect(),
            allow_on_battery: true,
        };
        let store = ProvisioningStore::in_memory().expect("store");
        let engine = ProvisioningEngine::new(store);
        let mut record = engine.create(input).expect("record");
        record.inventory = Some(DiscoveredComputer {
            hostname: "helios-16".to_owned(),
            operating_system: "windows".to_owned(),
            architecture: "x86_64".to_owned(),
            cpu_model: "fixture".to_owned(),
            logical_cpu_count: 16,
            memory_bytes: 32 * 1024 * 1024 * 1024,
            workspace_free_bytes: 100 * 1024 * 1024 * 1024,
            gpu_devices: Vec::new(),
            toolchains: BTreeMap::new(),
        });
        let current = NodeConfig {
            name: "temporary".to_owned(),
            enabled: false,
            priority: 0,
            labels: BTreeMap::from([("user.location".to_owned(), "office".to_owned())]),
            desired_state: cyc_protocol::NodeDesiredState::Draining,
            capacity: CapacityPolicy {
                allocatable_cpu_cores: Some(12),
                max_cpu_percent: Some(90),
                max_cpu_ewma_percent: Some(80),
                max_memory_percent: Some(85),
                max_temperature_c: Some(88),
                ..CapacityPolicy::default()
            },
        };

        let desired = desired_node_config(&record, &current).expect("desired config");
        assert_eq!(desired.name, "helios-16");
        assert!(desired.enabled);
        assert_eq!(desired.priority, 730);
        assert_eq!(
            desired.desired_state,
            cyc_protocol::NodeDesiredState::Draining
        );
        assert_eq!(desired.capacity.max_concurrent_jobs, 3);
        assert_eq!(desired.capacity.allocatable_cpu_cores, Some(12));
        assert_eq!(desired.capacity.allocatable_cpu_percent, Some(75));
        assert_eq!(desired.capacity.memory_limit_mib, Some(8 * 1024));
        assert!(desired.capacity.allow_on_battery);
        assert_eq!(
            desired.capacity.allowed_job_kinds,
            [
                JobKind::Batch,
                JobKind::Build,
                JobKind::Container,
                JobKind::Gpu,
                JobKind::Lint,
                JobKind::Shell,
                JobKind::Test,
            ]
            .into_iter()
            .collect()
        );
        assert_eq!(desired.capacity.max_cpu_percent, Some(90));
        assert_eq!(desired.capacity.max_cpu_ewma_percent, Some(80));
        assert_eq!(desired.capacity.max_memory_percent, Some(85));
        assert_eq!(desired.capacity.max_temperature_c, Some(88));
        assert_eq!(
            desired.labels.get("user.location").map(String::as_str),
            Some("office")
        );
        assert_eq!(
            desired
                .labels
                .get(POLICY_ALLOWED_JOB_KINDS)
                .map(String::as_str),
            Some("batch,build,container,gpu,lint,shell,test")
        );
        assert_eq!(
            desired.labels.get(POLICY_RESOURCE).map(String::as_str),
            Some(
                "{\"cpuLimitPercent\":75,\"maximumParallelJobs\":3,\"memoryLimitBytes\":8589934592}"
            )
        );
        assert_eq!(
            desired.labels.get(POLICY_BATTERY).map(String::as_str),
            Some("{\"allowOnBattery\":true}")
        );

        record.display_name = "Render workstation".to_owned();
        let custom = desired_node_config(&record, &current).expect("custom name");
        assert_eq!(custom.name, "Render workstation");
    }
}
