use std::{
    collections::{BTreeMap, BTreeSet},
    fmt,
    path::{Component, Path},
};

use base64::{engine::general_purpose::STANDARD_NO_PAD, Engine as _};
use chrono::{DateTime, Utc};
use cyc_protocol::SmokeRunBindingV1;
use cyc_secrets::CredentialReference;
use cyc_ssh::{HostKey, PrivateKeyFile};
use serde::{de::Error as _, Deserialize, Deserializer, Serialize, Serializer};
use thiserror::Error;
use uuid::Uuid;

const MAX_DISPLAY_NAME_BYTES: usize = 128;
const MAX_HOST_BYTES: usize = 1024;
const MAX_USERNAME_BYTES: usize = 256;
const MAX_TEXT_BYTES: usize = 512;
const MAX_TOOLCHAINS: usize = 128;
const MAX_GPU_DEVICES: usize = 32;
const MAX_FAILURE_CODE_BYTES: usize = 64;
const MAX_WORKSPACE_BYTES: usize = 4 * 1024;
const MAX_PRIVATE_KEY_PATH_BYTES: usize = 16 * 1024;

/// Current durable JSON format for [`ComputerRecord`].
pub const COMPUTER_RECORD_FORMAT_VERSION: u32 = 2;
const LEGACY_COMPUTER_RECORD_FORMAT_VERSION: u32 = 1;

const fn legacy_computer_record_format_version() -> u32 {
    LEGACY_COMPUTER_RECORD_FORMAT_VERSION
}

fn default_true() -> bool {
    true
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SshAuthenticationMethod {
    #[default]
    Password,
    Agent,
    PrivateKey,
}

impl SshAuthenticationMethod {
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Password => "password",
            Self::Agent => "agent",
            Self::PrivateKey => "private_key",
        }
    }
}

/// Durable, non-secret SSH authentication policy.
///
/// A private-key path is persisted so repair/restart can select the same local
/// identity, but is deliberately redacted from `Debug`. Passwords and key
/// passphrases never enter this value. A path supplied by a new request and
/// every authentication-time use must pass [`PrivateKeyFile`] validation.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SshAuthenticationPolicy {
    #[serde(default)]
    method: SshAuthenticationMethod,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    private_key_path: Option<String>,
}

impl Default for SshAuthenticationPolicy {
    fn default() -> Self {
        Self::password()
    }
}

impl fmt::Debug for SshAuthenticationPolicy {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SshAuthenticationPolicy")
            .field("method", &self.method)
            .field("private_key_configured", &self.private_key_path.is_some())
            .finish()
    }
}

impl SshAuthenticationPolicy {
    #[must_use]
    pub const fn password() -> Self {
        Self {
            method: SshAuthenticationMethod::Password,
            private_key_path: None,
        }
    }

    #[must_use]
    pub const fn agent() -> Self {
        Self {
            method: SshAuthenticationMethod::Agent,
            private_key_path: None,
        }
    }

    pub fn private_key(private_key: &PrivateKeyFile) -> Result<Self, RecordValidationError> {
        let path = private_key
            .as_path()
            .to_str()
            .ok_or(RecordValidationError::InvalidAuthenticationPolicy)?;
        let value = Self {
            method: SshAuthenticationMethod::PrivateKey,
            private_key_path: Some(path.to_owned()),
        };
        value.validate_durable()?;
        Ok(value)
    }

    #[must_use]
    pub const fn method(&self) -> SshAuthenticationMethod {
        self.method
    }

    #[must_use]
    pub fn private_key_configured(&self) -> bool {
        self.private_key_path.is_some()
    }

    /// Reconstructs and strictly revalidates the private-key file immediately
    /// before authentication. Errors never include the underlying path.
    pub fn private_key_file(&self) -> Result<PrivateKeyFile, RecordValidationError> {
        if self.method != SshAuthenticationMethod::PrivateKey {
            return Err(RecordValidationError::InvalidAuthenticationPolicy);
        }
        let path = self
            .private_key_path
            .as_deref()
            .ok_or(RecordValidationError::InvalidAuthenticationPolicy)?;
        PrivateKeyFile::new(path).map_err(|_| RecordValidationError::InvalidAuthenticationPolicy)
    }

    fn validate_for_new(&self) -> Result<(), RecordValidationError> {
        self.validate_durable()?;
        if self.method == SshAuthenticationMethod::PrivateKey {
            self.private_key_file()?;
        }
        Ok(())
    }

    fn validate_durable(&self) -> Result<(), RecordValidationError> {
        match (self.method, self.private_key_path.as_deref()) {
            (SshAuthenticationMethod::Password | SshAuthenticationMethod::Agent, None) => Ok(()),
            (SshAuthenticationMethod::PrivateKey, Some(path))
                if is_durable_private_key_path(path) =>
            {
                Ok(())
            }
            _ => Err(RecordValidationError::InvalidAuthenticationPolicy),
        }
    }
}

fn is_durable_private_key_path(value: &str) -> bool {
    let path = Path::new(value);
    !value.is_empty()
        && value.len() <= MAX_PRIVATE_KEY_PATH_BYTES
        && !value.contains(['\0', '\r', '\n'])
        && path.is_absolute()
        && !path
            .components()
            .any(|component| matches!(component, Component::CurDir | Component::ParentDir))
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ServiceScope {
    #[default]
    Auto,
    User,
    System,
}

impl ServiceScope {
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::User => "user",
            Self::System => "system",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AllowedJobKind {
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

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ResourcePolicy {
    pub maximum_parallel_jobs: Option<u16>,
    pub cpu_limit_percent: Option<u8>,
    pub memory_limit_bytes: Option<u64>,
}

impl ResourcePolicy {
    fn validate(&self) -> Result<(), RecordValidationError> {
        if self
            .maximum_parallel_jobs
            .is_some_and(|value| value == 0 || value > 1_024)
            || self
                .cpu_limit_percent
                .is_some_and(|value| value == 0 || value > 100)
            || self.memory_limit_bytes == Some(0)
        {
            return Err(RecordValidationError::InvalidField(
                "configuration.resources",
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ComputerConfiguration {
    #[serde(default)]
    pub service_scope: ServiceScope,
    #[serde(default)]
    pub workspace: Option<String>,
    #[serde(default)]
    pub priority: i32,
    #[serde(default)]
    pub resources: ResourcePolicy,
    #[serde(default)]
    pub allowed_job_kinds: BTreeSet<AllowedJobKind>,
    #[serde(default)]
    pub allow_on_battery: bool,
}

impl Default for ComputerConfiguration {
    fn default() -> Self {
        Self {
            service_scope: ServiceScope::Auto,
            workspace: None,
            priority: 0,
            resources: ResourcePolicy::default(),
            allowed_job_kinds: [
                AllowedJobKind::Build,
                AllowedJobKind::Test,
                AllowedJobKind::Compute,
            ]
            .into_iter()
            .collect(),
            allow_on_battery: false,
        }
    }
}

impl ComputerConfiguration {
    pub fn validate(&self) -> Result<(), RecordValidationError> {
        if !(-10_000..=10_000).contains(&self.priority) {
            return Err(RecordValidationError::InvalidField(
                "configuration.priority",
            ));
        }
        if let Some(workspace) = &self.workspace {
            validate_remote_workspace(workspace)?;
        }
        if self.allowed_job_kinds.is_empty() {
            return Err(RecordValidationError::InvalidField(
                "configuration.allowedJobKinds",
            ));
        }
        self.resources.validate()
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CredentialState {
    #[default]
    Pending,
    SessionOnly,
    Stored,
    Forgotten,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CredentialPolicy {
    #[serde(default = "default_true")]
    pub remember_requested: bool,
    #[serde(default)]
    pub state: CredentialState,
}

impl Default for CredentialPolicy {
    fn default() -> Self {
        Self {
            remember_requested: true,
            state: CredentialState::Pending,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ComputerEndpoint {
    pub host: String,
    pub port: u16,
    pub username: String,
}

impl ComputerEndpoint {
    pub fn new(
        host: impl Into<String>,
        port: u16,
        username: impl Into<String>,
    ) -> Result<Self, RecordValidationError> {
        let endpoint = Self {
            host: host.into(),
            port,
            username: username.into(),
        };
        endpoint.validate()?;
        Ok(endpoint)
    }

    pub fn validate(&self) -> Result<(), RecordValidationError> {
        validate_text("endpoint.host", &self.host, MAX_HOST_BYTES)?;
        validate_text("endpoint.username", &self.username, MAX_USERNAME_BYTES)?;
        if self.port == 0 {
            return Err(RecordValidationError::InvalidField("endpoint.port"));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NewComputer {
    pub display_name: String,
    pub endpoint: ComputerEndpoint,
    #[serde(default)]
    pub ssh_authentication: SshAuthenticationPolicy,
    #[serde(default = "default_true")]
    pub remember_credential: bool,
    #[serde(default)]
    pub configuration: ComputerConfiguration,
}

impl NewComputer {
    pub fn new(
        display_name: impl Into<String>,
        endpoint: ComputerEndpoint,
    ) -> Result<Self, RecordValidationError> {
        let value = Self {
            display_name: display_name.into(),
            endpoint,
            ssh_authentication: SshAuthenticationPolicy::default(),
            remember_credential: true,
            configuration: ComputerConfiguration::default(),
        };
        value.validate()?;
        Ok(value)
    }

    pub fn validate(&self) -> Result<(), RecordValidationError> {
        validate_text("displayName", &self.display_name, MAX_DISPLAY_NAME_BYTES)?;
        self.endpoint.validate()?;
        self.ssh_authentication.validate_for_new()?;
        if self.ssh_authentication.method() != SshAuthenticationMethod::Password
            && self.remember_credential
        {
            return Err(RecordValidationError::InvalidAuthenticationPolicy);
        }
        self.configuration.validate()
    }
}

/// Complete host public key record. The key bytes are public; the fingerprint
/// is derived and validated rather than trusted independently.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PinnedHostKeyRecord {
    pub algorithm: String,
    pub public_key_base64: String,
    pub fingerprint: String,
}

impl PinnedHostKeyRecord {
    pub fn validate(&self) -> Result<(), RecordValidationError> {
        validate_text("hostKey.algorithm", &self.algorithm, 128)?;
        validate_text(
            "hostKey.publicKeyBase64",
            &self.public_key_base64,
            64 * 1024,
        )?;
        validate_text("hostKey.fingerprint", &self.fingerprint, 256)?;
        let key = HostKey::try_from(self)?;
        if key.fingerprint() != self.fingerprint {
            return Err(RecordValidationError::InvalidHostKey);
        }
        Ok(())
    }
}

impl From<&HostKey> for PinnedHostKeyRecord {
    fn from(value: &HostKey) -> Self {
        Self {
            algorithm: value.algorithm().to_owned(),
            public_key_base64: STANDARD_NO_PAD.encode(value.key_bytes()),
            fingerprint: value.fingerprint().to_owned(),
        }
    }
}

impl TryFrom<&PinnedHostKeyRecord> for HostKey {
    type Error = RecordValidationError;

    fn try_from(value: &PinnedHostKeyRecord) -> Result<Self, Self::Error> {
        let bytes = STANDARD_NO_PAD
            .decode(value.public_key_base64.as_bytes())
            .map_err(|_| RecordValidationError::InvalidHostKey)?;
        HostKey::from_parts(value.algorithm.clone(), bytes)
            .map_err(|_| RecordValidationError::InvalidHostKey)
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GpuInventory {
    pub name: String,
    pub stable_device_id: Option<String>,
    pub memory_bytes: Option<u64>,
}

impl GpuInventory {
    fn validate(&self) -> Result<(), RecordValidationError> {
        validate_text("inventory.gpu.name", &self.name, MAX_TEXT_BYTES)?;
        if let Some(id) = &self.stable_device_id {
            validate_text("inventory.gpu.stableDeviceId", id, MAX_TEXT_BYTES)?;
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DiscoveredComputer {
    pub hostname: String,
    pub operating_system: String,
    pub architecture: String,
    pub cpu_model: String,
    pub logical_cpu_count: u32,
    pub memory_bytes: u64,
    pub workspace_free_bytes: u64,
    pub gpu_devices: Vec<GpuInventory>,
    pub toolchains: BTreeMap<String, String>,
}

impl DiscoveredComputer {
    pub fn validate(&self) -> Result<(), RecordValidationError> {
        validate_text("inventory.hostname", &self.hostname, MAX_TEXT_BYTES)?;
        validate_text(
            "inventory.operatingSystem",
            &self.operating_system,
            MAX_TEXT_BYTES,
        )?;
        validate_text("inventory.architecture", &self.architecture, MAX_TEXT_BYTES)?;
        validate_text("inventory.cpuModel", &self.cpu_model, MAX_TEXT_BYTES)?;
        if self.logical_cpu_count == 0 {
            return Err(RecordValidationError::InvalidField(
                "inventory.logicalCpuCount",
            ));
        }
        if self.gpu_devices.len() > MAX_GPU_DEVICES {
            return Err(RecordValidationError::InvalidField("inventory.gpuDevices"));
        }
        for gpu in &self.gpu_devices {
            gpu.validate()?;
        }
        if self.toolchains.len() > MAX_TOOLCHAINS {
            return Err(RecordValidationError::InvalidField("inventory.toolchains"));
        }
        for (name, version) in &self.toolchains {
            validate_text("inventory.toolchain.name", name, MAX_TEXT_BYTES)?;
            validate_text("inventory.toolchain.version", version, MAX_TEXT_BYTES)?;
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProvisioningStep {
    Draft,
    SshConnecting,
    HostKeyPending,
    Authenticated,
    Discovering,
    CredentialStored,
    KitStaged,
    WorkerInstalled,
    EnrollmentIssued,
    Paired,
    ServiceEnabled,
    HeartbeatSeen,
    SmokeCheck,
    Ready,
}

impl ProvisioningStep {
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Draft => "draft",
            Self::SshConnecting => "ssh_connecting",
            Self::HostKeyPending => "host_key_pending",
            Self::Authenticated => "authenticated",
            Self::Discovering => "discovering",
            Self::CredentialStored => "credential_stored",
            Self::KitStaged => "kit_staged",
            Self::WorkerInstalled => "worker_installed",
            Self::EnrollmentIssued => "enrollment_issued",
            Self::Paired => "paired",
            Self::ServiceEnabled => "service_enabled",
            Self::HeartbeatSeen => "heartbeat_seen",
            Self::SmokeCheck => "smoke_check",
            Self::Ready => "ready",
        }
    }

    fn rank(self) -> u8 {
        match self {
            Self::Draft => 0,
            Self::SshConnecting => 1,
            Self::HostKeyPending => 2,
            Self::Authenticated => 3,
            Self::Discovering => 4,
            Self::CredentialStored => 5,
            Self::KitStaged => 6,
            Self::WorkerInstalled => 7,
            Self::EnrollmentIssued => 8,
            Self::Paired => 9,
            Self::ServiceEnabled => 10,
            Self::HeartbeatSeen => 11,
            Self::SmokeCheck => 12,
            Self::Ready => 13,
        }
    }

    #[must_use]
    pub fn is_at_least(self, checkpoint: Self) -> bool {
        self.rank() >= checkpoint.rank()
    }
}

#[derive(Clone, PartialEq, Eq, Hash)]
pub struct FailureCode(String);

impl FailureCode {
    pub fn new(value: impl Into<String>) -> Result<Self, RecordValidationError> {
        let value = value.into();
        if value.is_empty()
            || value.len() > MAX_FAILURE_CODE_BYTES
            || !value.bytes().all(|byte| {
                byte.is_ascii_uppercase()
                    || byte.is_ascii_digit()
                    || matches!(byte, b'_' | b'-' | b'.')
            })
        {
            return Err(RecordValidationError::InvalidFailureCode);
        }
        Ok(Self(value))
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for FailureCode {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.debug_tuple("FailureCode").field(&self.0).finish()
    }
}

impl Serialize for FailureCode {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(&self.0)
    }
}

impl<'de> Deserialize<'de> for FailureCode {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        Self::new(String::deserialize(deserializer)?).map_err(D::Error::custom)
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum ProvisioningState {
    Draft,
    SshConnecting,
    HostKeyPending,
    Authenticated,
    Discovering,
    CredentialStored,
    KitStaged,
    WorkerInstalled,
    EnrollmentIssued,
    Paired,
    ServiceEnabled,
    HeartbeatSeen,
    SmokeCheck,
    Ready,
    Failed {
        step: ProvisioningStep,
        code: FailureCode,
        retryable: bool,
    },
}

impl ProvisioningState {
    #[must_use]
    pub fn active_step(&self) -> ProvisioningStep {
        match self {
            Self::Draft => ProvisioningStep::Draft,
            Self::SshConnecting => ProvisioningStep::SshConnecting,
            Self::HostKeyPending => ProvisioningStep::HostKeyPending,
            Self::Authenticated => ProvisioningStep::Authenticated,
            Self::Discovering => ProvisioningStep::Discovering,
            Self::CredentialStored => ProvisioningStep::CredentialStored,
            Self::KitStaged => ProvisioningStep::KitStaged,
            Self::WorkerInstalled => ProvisioningStep::WorkerInstalled,
            Self::EnrollmentIssued => ProvisioningStep::EnrollmentIssued,
            Self::Paired => ProvisioningStep::Paired,
            Self::ServiceEnabled => ProvisioningStep::ServiceEnabled,
            Self::HeartbeatSeen => ProvisioningStep::HeartbeatSeen,
            Self::SmokeCheck => ProvisioningStep::SmokeCheck,
            Self::Ready => ProvisioningStep::Ready,
            Self::Failed { step, .. } => *step,
        }
    }

    #[must_use]
    pub fn from_step(step: ProvisioningStep) -> Self {
        match step {
            ProvisioningStep::Draft => Self::Draft,
            ProvisioningStep::SshConnecting => Self::SshConnecting,
            ProvisioningStep::HostKeyPending => Self::HostKeyPending,
            ProvisioningStep::Authenticated => Self::Authenticated,
            ProvisioningStep::Discovering => Self::Discovering,
            ProvisioningStep::CredentialStored => Self::CredentialStored,
            ProvisioningStep::KitStaged => Self::KitStaged,
            ProvisioningStep::WorkerInstalled => Self::WorkerInstalled,
            ProvisioningStep::EnrollmentIssued => Self::EnrollmentIssued,
            ProvisioningStep::Paired => Self::Paired,
            ProvisioningStep::ServiceEnabled => Self::ServiceEnabled,
            ProvisioningStep::HeartbeatSeen => Self::HeartbeatSeen,
            ProvisioningStep::SmokeCheck => Self::SmokeCheck,
            ProvisioningStep::Ready => Self::Ready,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProvisioningIntent {
    #[default]
    Continue,
    Resume,
    Retry,
    Rollback,
    Remove,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ComputerRecord {
    /// Version of the JSON document stored in the provisioning journal.
    /// Records written before this field existed deserialize as legacy v1.
    #[serde(default = "legacy_computer_record_format_version")]
    pub format_version: u32,
    pub id: Uuid,
    pub display_name: String,
    pub endpoint: ComputerEndpoint,
    #[serde(default)]
    pub ssh_authentication: SshAuthenticationPolicy,
    pub state: ProvisioningState,
    pub intent: ProvisioningIntent,
    #[serde(default)]
    pub teardown_completed: bool,
    pub revision: u64,
    pub cycle: u32,
    pub intended_node_id: Uuid,
    pub pairing_id: Option<Uuid>,
    pub paired_node_id: Option<Uuid>,
    pub host_key: Option<PinnedHostKeyRecord>,
    pub host_key_approved_at: Option<DateTime<Utc>>,
    pub inventory: Option<DiscoveredComputer>,
    #[serde(default)]
    pub credential_policy: CredentialPolicy,
    pub credential_reference: Option<CredentialReference>,
    #[serde(default)]
    pub configuration: ComputerConfiguration,
    pub heartbeat_seen_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub smoke_run_binding: Option<SmokeRunBindingV1>,
    pub smoke_check_completed_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl ComputerRecord {
    pub(crate) fn new(input: NewComputer, now: DateTime<Utc>) -> Self {
        Self::new_with_identity(input, now, Uuid::new_v4(), Uuid::new_v4())
    }

    /// Construct a record from controller/UI-owned idempotency identities.
    ///
    /// `id` is the durable Add Computer operation key and
    /// `intended_node_id` is the stable logical worker identity.  Keeping this
    /// constructor crate-private prevents persisted callers from changing
    /// identities after creation while allowing the engine to recover a lost
    /// create response without allocating a duplicate computer.
    pub(crate) fn new_with_identity(
        input: NewComputer,
        now: DateTime<Utc>,
        id: Uuid,
        intended_node_id: Uuid,
    ) -> Self {
        Self {
            format_version: COMPUTER_RECORD_FORMAT_VERSION,
            id,
            display_name: input.display_name,
            endpoint: input.endpoint,
            ssh_authentication: input.ssh_authentication,
            state: ProvisioningState::Draft,
            intent: ProvisioningIntent::Continue,
            teardown_completed: false,
            revision: 1,
            cycle: 0,
            intended_node_id,
            pairing_id: None,
            paired_node_id: None,
            host_key: None,
            host_key_approved_at: None,
            inventory: None,
            credential_policy: CredentialPolicy {
                remember_requested: input.remember_credential,
                state: CredentialState::Pending,
            },
            credential_reference: None,
            configuration: input.configuration,
            heartbeat_seen_at: None,
            smoke_run_binding: None,
            smoke_check_completed_at: None,
            created_at: now,
            updated_at: now,
        }
    }

    pub fn validate(&self) -> Result<(), RecordValidationError> {
        if !matches!(
            self.format_version,
            LEGACY_COMPUTER_RECORD_FORMAT_VERSION | COMPUTER_RECORD_FORMAT_VERSION
        ) {
            return Err(RecordValidationError::UnsupportedFormatVersion);
        }
        if self.id.is_nil()
            || self.intended_node_id.is_nil()
            || self.pairing_id.is_some_and(|id| id.is_nil())
            || self.paired_node_id.is_some_and(|id| id.is_nil())
            || self.revision == 0
        {
            return Err(RecordValidationError::InvalidIdentity);
        }
        validate_text("displayName", &self.display_name, MAX_DISPLAY_NAME_BYTES)?;
        self.endpoint.validate()?;
        self.ssh_authentication.validate_durable()?;
        if self.ssh_authentication.method() != SshAuthenticationMethod::Password
            && (self.credential_policy.remember_requested
                || self.credential_reference.is_some()
                || self.credential_policy.state == CredentialState::Stored)
        {
            return Err(RecordValidationError::InvalidAuthenticationPolicy);
        }
        if self.updated_at < self.created_at {
            return Err(RecordValidationError::InvalidTimestamp);
        }
        if self
            .host_key_approved_at
            .is_some_and(|value| value < self.created_at)
            || self
                .heartbeat_seen_at
                .is_some_and(|value| value < self.created_at)
            || self
                .smoke_check_completed_at
                .is_some_and(|value| value < self.created_at)
            || matches!(
                (self.heartbeat_seen_at, self.smoke_check_completed_at),
                (Some(heartbeat), Some(smoke)) if smoke < heartbeat
            )
        {
            return Err(RecordValidationError::InvalidTimestamp);
        }
        if let Some(host_key) = &self.host_key {
            host_key.validate()?;
        }
        if let Some(inventory) = &self.inventory {
            inventory.validate()?;
        }
        self.configuration.validate()?;
        if self.teardown_completed
            && !matches!(
                self.intent,
                ProvisioningIntent::Rollback | ProvisioningIntent::Remove
            )
        {
            return Err(RecordValidationError::InvalidTeardownCheckpoint);
        }

        match self.credential_policy.state {
            CredentialState::Stored if self.credential_reference.is_none() => {
                return Err(RecordValidationError::MissingCheckpoint(
                    "credentialReference",
                ));
            }
            CredentialState::Pending
            | CredentialState::SessionOnly
            | CredentialState::Forgotten
                if self.credential_reference.is_some() =>
            {
                return Err(RecordValidationError::InvalidCredentialState);
            }
            _ => {}
        }

        let step = self.state.active_step();
        if step.rank() >= ProvisioningStep::HostKeyPending.rank() && self.host_key.is_none() {
            return Err(RecordValidationError::MissingCheckpoint("hostKey"));
        }
        if step.rank() >= ProvisioningStep::Authenticated.rank()
            && self.host_key_approved_at.is_none()
        {
            return Err(RecordValidationError::MissingCheckpoint(
                "hostKeyApprovedAt",
            ));
        }
        if step.rank() >= ProvisioningStep::CredentialStored.rank() {
            if self.inventory.is_none() {
                return Err(RecordValidationError::MissingCheckpoint("inventory"));
            }
            if !matches!(
                self.credential_policy.state,
                CredentialState::Stored | CredentialState::SessionOnly | CredentialState::Forgotten
            ) {
                return Err(RecordValidationError::InvalidCredentialState);
            }
        }
        if self.credential_policy.state == CredentialState::Forgotten
            && !matches!(self.state, ProvisioningState::Ready)
        {
            return Err(RecordValidationError::InvalidCredentialState);
        }
        if step.rank() >= ProvisioningStep::EnrollmentIssued.rank() && self.pairing_id.is_none() {
            return Err(RecordValidationError::MissingCheckpoint("pairingId"));
        }
        if step.rank() >= ProvisioningStep::Paired.rank()
            && self.paired_node_id != Some(self.intended_node_id)
        {
            return Err(RecordValidationError::MissingCheckpoint("pairedNodeId"));
        }
        if step.rank() >= ProvisioningStep::HeartbeatSeen.rank() && self.heartbeat_seen_at.is_none()
        {
            return Err(RecordValidationError::MissingCheckpoint("heartbeatSeenAt"));
        }
        self.validate_smoke_checkpoint(step)?;
        if step.rank() >= ProvisioningStep::Ready.rank() && self.smoke_check_completed_at.is_none()
        {
            return Err(RecordValidationError::MissingCheckpoint(
                "smokeCheckCompletedAt",
            ));
        }

        match (&self.state, self.intent) {
            (
                ProvisioningState::Failed {
                    retryable: true, ..
                },
                ProvisioningIntent::Retry,
            )
            | (_, ProvisioningIntent::Continue)
            | (_, ProvisioningIntent::Rollback)
            | (_, ProvisioningIntent::Remove) => {}
            (ProvisioningState::Failed { .. }, ProvisioningIntent::Resume)
            | (ProvisioningState::Failed { .. }, ProvisioningIntent::Retry) => {
                return Err(RecordValidationError::InvalidIntent)
            }
            (_, ProvisioningIntent::Retry) => return Err(RecordValidationError::InvalidIntent),
            (ProvisioningState::Ready, ProvisioningIntent::Resume) => {
                return Err(RecordValidationError::InvalidIntent)
            }
            (_, ProvisioningIntent::Resume) => {}
        }
        Ok(())
    }

    /// True only for a pre-binding ready record loaded from the legacy journal
    /// format. It remains reportable as ready, but a repair clears its legacy
    /// completion and performs a newly bound smoke run.
    #[must_use]
    pub fn is_legacy_ready(&self) -> bool {
        self.format_version == LEGACY_COMPUTER_RECORD_FORMAT_VERSION
            && matches!(self.state, ProvisioningState::Ready)
            && self.smoke_run_binding.is_none()
    }

    pub(crate) fn validate_smoke_binding(
        &self,
        binding: &SmokeRunBindingV1,
    ) -> Result<(), RecordValidationError> {
        binding
            .validate(None, None)
            .map_err(|_| RecordValidationError::InvalidSmokeBinding)?;
        if binding.plan.job_id != crate::canonical_smoke_job_id(self.id, self.cycle) {
            return Err(RecordValidationError::SmokeBindingJobMismatch);
        }
        if binding.plan.decision.node_id != self.intended_node_id
            || self.paired_node_id != Some(self.intended_node_id)
        {
            return Err(RecordValidationError::SmokeBindingNodeMismatch);
        }
        Ok(())
    }

    fn validate_smoke_checkpoint(
        &self,
        step: ProvisioningStep,
    ) -> Result<(), RecordValidationError> {
        if self.format_version == LEGACY_COMPUTER_RECORD_FORMAT_VERSION {
            if self.smoke_run_binding.is_some() {
                return Err(RecordValidationError::InvalidSmokeCheckpoint);
            }
            return Ok(());
        }

        match (
            step.is_at_least(ProvisioningStep::SmokeCheck),
            &self.smoke_run_binding,
        ) {
            (true, Some(binding)) => self.validate_smoke_binding(binding)?,
            (true, None) => {
                return Err(RecordValidationError::MissingCheckpoint("smokeRunBinding"))
            }
            (false, Some(_)) => return Err(RecordValidationError::InvalidSmokeCheckpoint),
            (false, None) => {}
        }

        // Smoke success is durably checkpointed in SmokeCheck while the
        // remote staging tree is being removed.  Only successful cleanup may
        // advance that checkpoint to Ready.
        if !matches!(step, ProvisioningStep::SmokeCheck | ProvisioningStep::Ready)
            && self.smoke_check_completed_at.is_some()
        {
            return Err(RecordValidationError::InvalidSmokeCheckpoint);
        }
        if let (Some(binding), Some(completed_at)) =
            (&self.smoke_run_binding, self.smoke_check_completed_at)
        {
            if completed_at < binding.plan.created_at {
                return Err(RecordValidationError::InvalidTimestamp);
            }
        }
        Ok(())
    }
}

fn validate_text(
    field: &'static str,
    value: &str,
    maximum_bytes: usize,
) -> Result<(), RecordValidationError> {
    if value.trim().is_empty() || value.len() > maximum_bytes || value.chars().any(char::is_control)
    {
        return Err(RecordValidationError::InvalidField(field));
    }
    Ok(())
}

fn validate_remote_workspace(value: &str) -> Result<(), RecordValidationError> {
    validate_text("configuration.workspace", value, MAX_WORKSPACE_BYTES)?;
    let normalized = value.replace('\\', "/");
    let windows_absolute = normalized.as_bytes().get(1) == Some(&b':')
        && normalized
            .as_bytes()
            .first()
            .is_some_and(u8::is_ascii_alphabetic)
        && normalized.as_bytes().get(2) == Some(&b'/');
    let posix_absolute = normalized.starts_with('/') && !normalized.starts_with("//");
    let invalid_component = normalized
        .split('/')
        .any(|component| matches!(component, "." | ".."));
    if (!windows_absolute && !posix_absolute)
        || invalid_component
        || value.contains(['\0', '\r', '\n', '"'])
    {
        return Err(RecordValidationError::InvalidField(
            "configuration.workspace",
        ));
    }
    Ok(())
}

#[derive(Clone, Debug, Error, PartialEq, Eq)]
pub enum RecordValidationError {
    #[error("invalid field {0}")]
    InvalidField(&'static str),
    #[error("invalid computer identity")]
    InvalidIdentity,
    #[error("invalid record timestamp")]
    InvalidTimestamp,
    #[error("invalid SSH host key record")]
    InvalidHostKey,
    #[error("invalid failure code")]
    InvalidFailureCode,
    #[error("checkpoint {0} is missing")]
    MissingCheckpoint(&'static str),
    #[error("intent is invalid for the current state")]
    InvalidIntent,
    #[error("credential policy state is inconsistent with the record")]
    InvalidCredentialState,
    #[error("SSH authentication policy is invalid")]
    InvalidAuthenticationPolicy,
    #[error("teardown checkpoint is inconsistent with the current intent")]
    InvalidTeardownCheckpoint,
    #[error("unsupported provisioning record format version")]
    UnsupportedFormatVersion,
    #[error("smoke run binding is structurally invalid")]
    InvalidSmokeBinding,
    #[error("smoke run binding job identity is invalid")]
    SmokeBindingJobMismatch,
    #[error("smoke run binding node identity is invalid")]
    SmokeBindingNodeMismatch,
    #[error("smoke run checkpoint is inconsistent with the record state")]
    InvalidSmokeCheckpoint,
}

#[cfg(test)]
mod tests {
    use super::{ComputerConfiguration, PinnedHostKeyRecord};
    use cyc_ssh::HostKey;

    #[test]
    fn host_key_record_round_trip_preserves_full_key() {
        let key = HostKey::from_parts("ssh-ed25519", vec![1, 2, 3, 4]).expect("host key");
        let record = PinnedHostKeyRecord::from(&key);
        record.validate().expect("valid record");
        let decoded = HostKey::try_from(&record).expect("decode host key");
        assert_eq!(decoded.algorithm(), key.algorithm());
        assert_eq!(decoded.key_bytes(), key.key_bytes());
        assert_eq!(decoded.fingerprint(), key.fingerprint());
    }

    #[test]
    fn computer_configuration_requires_an_explicit_job_kind() {
        let mut configuration = ComputerConfiguration::default();
        configuration.allowed_job_kinds.clear();
        assert!(configuration.validate().is_err());
    }
}
