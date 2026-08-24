use std::collections::{BTreeMap, BTreeSet};
use std::ffi::{OsStr, OsString};
use std::fs::File;
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex, MutexGuard, TryLockError};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use thiserror::Error;
use uuid::Uuid;

const PLUGIN_ID: &str = "cluster-your-codex@clusteryourcodex";
const MARKETPLACE_NAME: &str = "clusteryourcodex";
const MAX_PROCESS_OUTPUT: usize = 2 * 1024 * 1024;
const CODEX_TIMEOUT: Duration = Duration::from_secs(20);
const CODEX_INTEGRATION_TIMEOUT: Duration = Duration::from_secs(90);
const MCP_TIMEOUT: Duration = Duration::from_secs(15);
const LIVE_RUNTIME_REFRESH_TIMEOUT: Duration = Duration::from_secs(8);
const CODEX_ONLY_RECEIPT_SCHEMA: &str = "cyc.dev/codex-integration-receipt/v1";
const INSTALL_MANIFEST_SCHEMA: &str = "cyc.dev/windows-install-manifest/v1";
const INSTALLED_BOOTSTRAP_RELATIVE_PATH: &str = "installer/bootstrap.ps1";
const AGENTS_TEMPLATE_RELATIVE_PATH: &str = "integrations/codex/cluster-agents-block.md";
const CODEX_MARKETPLACE_PREFIX: &str = "integrations/codex-marketplace/";
const CODEX_MARKETPLACE_RELATIVE_ROOT: &str = "integrations/codex-marketplace";
const FILE_CATALOG_SCHEMA: &str = "cyc.dev/file-catalog/v1";
const AGENTS_INTEGRATION_SCHEMA: &str = "cyc.dev/agents-managed-block/v1";
const AGENTS_BEGIN_MARKER: &str = "<!-- CLUSTERYOURCODEX-MANAGED:BEGIN -->";
const AGENTS_END_MARKER: &str = "<!-- CLUSTERYOURCODEX-MANAGED:END -->";
const MAX_CODEX_ONLY_RECEIPT: usize = 4096;
const MAX_INSTALL_MANIFEST: u64 = 16 * 1024 * 1024;
const ACTIVE_RECEIPT_TTL: chrono::Duration = chrono::Duration::seconds(90);
const ACTIVE_CONTROLLER_VERIFICATION_TTL: chrono::Duration = chrono::Duration::seconds(15);
const ACTIVE_RECEIPT_CLOCK_SKEW: chrono::Duration = chrono::Duration::seconds(30);
static STATE_FILE_COUNTER: AtomicU64 = AtomicU64::new(0);

#[derive(Clone)]
pub(crate) struct IntegrationManager {
    inner: Arc<IntegrationManagerInner>,
}

struct IntegrationManagerInner {
    token_file: PathBuf,
    data_root: PathBuf,
    operation_lock: Mutex<()>,
}

fn try_operation_lock(
    inner: &IntegrationManagerInner,
) -> Result<MutexGuard<'_, ()>, IntegrationError> {
    match inner.operation_lock.try_lock() {
        Ok(guard) => Ok(guard),
        // Never queue native operations behind a packaging/AGENTS journal.
        // The public error is an explicit retryable-busy result and the active
        // operation is allowed to finish its durable transaction normally.
        Err(TryLockError::WouldBlock | TryLockError::Poisoned(_)) => {
            Err(IntegrationError::OperationUnavailable)
        }
    }
}

impl IntegrationManager {
    pub(crate) fn new(token_file: PathBuf) -> Result<Self, IntegrationError> {
        let data_root = token_file
            .parent()
            .map(Path::to_path_buf)
            .ok_or(IntegrationError::DataUnavailable)?;
        Ok(Self {
            inner: Arc::new(IntegrationManagerInner {
                token_file,
                data_root,
                operation_lock: Mutex::new(()),
            }),
        })
    }

    pub(crate) fn status(&self) -> Result<IntegrationStatus, IntegrationError> {
        let _guard = try_operation_lock(&self.inner)?;
        collect_status(&self.inner)
    }

    pub(crate) fn install_or_repair(&self) -> Result<IntegrationActionResult, IntegrationError> {
        let _guard = try_operation_lock(&self.inner)?;
        install_or_repair(&self.inner)
    }

    pub(crate) fn self_test(&self) -> Result<IntegrationSelfTestResult, IntegrationError> {
        let _guard = try_operation_lock(&self.inner)?;
        run_self_test(&self.inner)
    }

    pub(crate) fn connected_runtime_identity(
        &self,
    ) -> Result<Option<ActiveRuntimeIdentity>, IntegrationError> {
        let _guard = try_operation_lock(&self.inner)?;
        connected_runtime_identity(&self.inner)
    }

    pub(crate) fn wait_for_runtime_refresh(
        &self,
        expected: &ActiveRuntimeIdentity,
        after: DateTime<Utc>,
    ) -> Result<bool, IntegrationError> {
        let deadline = Instant::now() + LIVE_RUNTIME_REFRESH_TIMEOUT;
        loop {
            {
                let _guard = try_operation_lock(&self.inner)?;
                let Some(receipt) =
                    read_small_json::<McpActiveReceipt>(&active_receipt_path(&self.inner))
                else {
                    return Ok(false);
                };
                if !same_runtime(&receipt, expected)
                    || !valid_active_receipt(&receipt, &expected.bridge_version, Utc::now())
                {
                    return Ok(false);
                }
                if receipt.last_seen_at > after && receipt.controller_verified_at > after {
                    return Ok(true);
                }
            }
            if Instant::now() >= deadline {
                return Ok(false);
            }
            thread::sleep(Duration::from_millis(100));
        }
    }

    pub(crate) fn with_mcp_session<T, E, F>(
        &self,
        total_timeout: Duration,
        operation: F,
    ) -> Result<T, E>
    where
        F: FnOnce(&mut McpSession) -> Result<T, E>,
        E: From<IntegrationError>,
    {
        let _guard = try_operation_lock(&self.inner).map_err(E::from)?;
        let installed = verified_installed_plugin(&self.inner).map_err(E::from)?;
        let mut session =
            McpSession::start(&self.inner, &installed, total_timeout).map_err(E::from)?;
        operation(&mut session)
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ActiveRuntimeIdentity {
    pub(crate) pid: u32,
    pub(crate) started_at: DateTime<Utc>,
    pub(crate) bridge_version: String,
}

/// Identity of the isolated MCP child launched by Desktop for a bounded
/// installed-package self-test. This is deliberately distinct from
/// `ActiveRuntimeIdentity`, which comes only from a fresh Codex-owned runtime
/// receipt.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SelfTestExecutorIdentity {
    pub(crate) pid: u32,
    pub(crate) started_at: DateTime<Utc>,
    pub(crate) bridge_version: String,
    pub(crate) session_id: Uuid,
}

#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(crate) enum IntegrationState {
    NotFound,
    NotInstalled,
    Installed,
    RestartRequired,
    Connected,
    Stale,
    Broken,
    VersionMismatch,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct IntegrationStatus {
    state: IntegrationState,
    checked_at_ms: u64,
    payload_available: bool,
    plugin_enabled: bool,
    agents_integrated: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    payload_catalog_sha256: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    build_catalog_sha256: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    install_manifest_sha256: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    agents_block_sha256: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    cli_version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    installed_version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    desired_version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    active_runtime: Option<ActiveRuntimeIdentity>,
    message: &'static str,
}

impl IntegrationStatus {
    pub(crate) fn is_connected(&self) -> bool {
        self.state == IntegrationState::Connected
            && self.agents_integrated
            && self.active_runtime.is_some()
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct IntegrationStep {
    id: &'static str,
    passed: bool,
    message: &'static str,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct IntegrationActionResult {
    changed: bool,
    restart_required: bool,
    steps: Vec<IntegrationStep>,
    status: IntegrationStatus,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct IntegrationSelfTestResult {
    passed: bool,
    duration_ms: u64,
    restart_recommended: bool,
    checks: Vec<IntegrationStep>,
    #[serde(skip_serializing_if = "Option::is_none")]
    self_test_executor: Option<SelfTestExecutorIdentity>,
    status: IntegrationStatus,
}

#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) struct PublicIntegrationError {
    code: &'static str,
    retryable: bool,
}

#[derive(Debug, Error)]
pub(crate) enum IntegrationError {
    #[error("integration data directory is unavailable")]
    DataUnavailable,
    #[error("integration operation is unavailable")]
    OperationUnavailable,
    #[error("Codex CLI is unavailable")]
    CodexNotFound,
    #[error("Codex CLI invocation failed")]
    CodexInvocationFailed,
    #[error("Codex CLI returned invalid output")]
    CodexOutputInvalid,
    #[error("the bundled Codex integration is unavailable")]
    PayloadUnavailable,
    #[error("Codex marketplace registration failed")]
    MarketplaceInstallFailed,
    #[error("Codex plugin installation failed")]
    PluginInstallFailed,
    #[error("global Codex AGENTS.md integration failed")]
    AgentsIntegrationFailed,
    #[error("integration state could not be persisted")]
    StatePersistenceFailed,
    #[error("the MCP bridge could not be started")]
    McpStartFailed,
    #[error("the MCP bridge self-test failed")]
    McpSelfTestFailed,
}

impl From<IntegrationError> for PublicIntegrationError {
    fn from(value: IntegrationError) -> Self {
        let retryable = matches!(value, IntegrationError::OperationUnavailable);
        let code = match value {
            IntegrationError::DataUnavailable => "integration_data_unavailable",
            IntegrationError::OperationUnavailable => "integration_busy_retryable",
            IntegrationError::CodexNotFound => "codex_not_found",
            IntegrationError::CodexInvocationFailed | IntegrationError::CodexOutputInvalid => {
                "codex_cli_broken"
            }
            IntegrationError::PayloadUnavailable => "integration_payload_unavailable",
            IntegrationError::MarketplaceInstallFailed => "marketplace_install_failed",
            IntegrationError::PluginInstallFailed => "plugin_install_failed",
            IntegrationError::AgentsIntegrationFailed => "agents_integration_failed",
            IntegrationError::StatePersistenceFailed => "integration_state_unavailable",
            IntegrationError::McpStartFailed | IntegrationError::McpSelfTestFailed => {
                "integration_self_test_failed"
            }
        };
        Self { code, retryable }
    }
}

#[derive(Debug)]
struct Payload {
    marketplace_root: PathBuf,
    plugin_root: PathBuf,
    desired_version: String,
}

#[derive(Debug)]
struct VerifiedInstall {
    install_root: PathBuf,
    data_root: PathBuf,
    manifest_sha256: String,
    build_catalog_sha256: String,
    payload_catalog_sha256: String,
    files: BTreeMap<String, InstalledFileReceipt>,
    agents_integration: Option<AgentsIntegrationRecord>,
}

#[derive(Debug)]
struct AgentsEvidence {
    block_sha256: String,
}

#[derive(Debug)]
struct VerifiedBootstrap {
    install_root: PathBuf,
    data_root: PathBuf,
    path: PathBuf,
    _guard: File,
    integrity: VerifiedInstall,
}

#[derive(Debug)]
struct PluginRegistration {
    version: String,
    enabled: bool,
    source_path: PathBuf,
}

#[derive(Debug)]
struct InstalledPlugin {
    root: PathBuf,
    runtime: PathBuf,
    server: PathBuf,
    version: String,
}

#[derive(Clone, Debug)]
struct DiscoveredCodexCli {
    path: PathBuf,
    version: String,
    modified_at: SystemTime,
}

#[derive(Debug)]
struct ProcessOutput {
    status: ExitStatus,
    stdout: Vec<u8>,
    _stderr: Vec<u8>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct HealthReceipt {
    checked_at_ms: u64,
    passed: bool,
    #[serde(default)]
    failed_check: Option<String>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct RestartReceipt {
    installed_at_ms: u64,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum CodexOnlyStatus {
    Installed,
    Repaired,
    Unchanged,
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CodexOnlyReceipt {
    schema_version: String,
    status: CodexOnlyStatus,
    plugin_id: String,
    plugin_version: String,
    agents_block_sha256: String,
    payload_catalog_sha256: String,
    build_catalog_sha256: String,
    install_manifest_sha256: String,
    agents_file_sha256: String,
    agents_external_sha256: String,
    agents_owned_range_sha256: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InstalledManifest {
    schema_version: String,
    install_root: PathBuf,
    data_root: PathBuf,
    files: Vec<InstalledFileReceipt>,
    #[serde(default)]
    build_catalog_sha256: Option<String>,
    #[serde(default)]
    codex_payload_catalog_sha256: Option<String>,
    #[serde(default)]
    agents_integration: Option<Value>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct InstalledFileReceipt {
    relative_path: String,
    sha256: String,
    length: u64,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AgentsIntegrationRecord {
    schema_version: String,
    enabled: bool,
    installed: bool,
    path: PathBuf,
    codex_home: PathBuf,
    template_relative_path: String,
    template_sha256: String,
    encoding: String,
    installed_file_sha256: String,
    installed_file_length: u64,
    block_sha256: String,
    prefix_sha256: String,
    owned_prefix_base64: String,
    external_sha256: String,
    external_length: u64,
    owned_range_sha256: String,
    transaction_id: String,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct McpActiveReceipt {
    api_version: String,
    pid: u32,
    started_at: DateTime<Utc>,
    last_seen_at: DateTime<Utc>,
    controller_verified_at: DateTime<Utc>,
    bridge_version: String,
}

fn now_ms() -> Result<u64, IntegrationError> {
    let elapsed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| IntegrationError::StatePersistenceFailed)?;
    u64::try_from(elapsed.as_millis()).map_err(|_| IntegrationError::StatePersistenceFailed)
}

fn integration_state_root(inner: &IntegrationManagerInner) -> PathBuf {
    inner.data_root.join(".integration")
}

fn health_receipt_path(inner: &IntegrationManagerInner) -> PathBuf {
    integration_state_root(inner).join("health-v1.json")
}

fn restart_receipt_path(inner: &IntegrationManagerInner) -> PathBuf {
    integration_state_root(inner).join("restart-required-v1.json")
}

fn active_receipt_path(inner: &IntegrationManagerInner) -> PathBuf {
    integration_state_root(inner).join("mcp-active-v1.json")
}

fn read_small_json<T: for<'de> Deserialize<'de>>(path: &Path) -> Option<T> {
    let metadata = std::fs::metadata(path).ok()?;
    if !metadata.is_file() || metadata.len() > 64 * 1024 {
        return None;
    }
    let bytes = std::fs::read(path).ok()?;
    serde_json::from_slice(&bytes).ok()
}

fn unique_state_suffix() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_nanos())
        .unwrap_or_default();
    let counter = STATE_FILE_COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{}-{nanos}-{counter}", std::process::id())
}

fn write_atomic_json<T: Serialize>(path: &Path, value: &T) -> Result<(), IntegrationError> {
    let parent = path
        .parent()
        .ok_or(IntegrationError::StatePersistenceFailed)?;
    std::fs::create_dir_all(parent).map_err(|_| IntegrationError::StatePersistenceFailed)?;
    let file_name = path
        .file_name()
        .and_then(OsStr::to_str)
        .ok_or(IntegrationError::StatePersistenceFailed)?;
    let suffix = unique_state_suffix();
    let temporary = parent.join(format!(".{file_name}.tmp-{suffix}"));
    let backup = parent.join(format!(".{file_name}.backup-{suffix}"));
    let encoded =
        serde_json::to_vec(value).map_err(|_| IntegrationError::StatePersistenceFailed)?;
    let mut file = File::options()
        .write(true)
        .create_new(true)
        .open(&temporary)
        .map_err(|_| IntegrationError::StatePersistenceFailed)?;
    let result = (|| {
        file.write_all(&encoded)
            .map_err(|_| IntegrationError::StatePersistenceFailed)?;
        file.sync_all()
            .map_err(|_| IntegrationError::StatePersistenceFailed)?;
        drop(file);

        // Unix replaces the destination atomically. Windows does not, so keep a
        // uniquely named rollback copy rather than deleting the last good state.
        if std::fs::rename(&temporary, path).is_ok() {
            return Ok(());
        }
        if !path.is_file() {
            return Err(IntegrationError::StatePersistenceFailed);
        }
        std::fs::rename(path, &backup).map_err(|_| IntegrationError::StatePersistenceFailed)?;
        match std::fs::rename(&temporary, path) {
            Ok(()) => {
                let _ = std::fs::remove_file(&backup);
                Ok(())
            }
            Err(_) => {
                let _ = std::fs::rename(&backup, path);
                Err(IntegrationError::StatePersistenceFailed)
            }
        }
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
        if backup.is_file() && !path.is_file() {
            let _ = std::fs::rename(&backup, path);
        }
    }
    result
}

fn is_lower_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
}

fn is_regular_metadata_without_reparse(metadata: &std::fs::Metadata) -> bool {
    if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
        return false;
    }
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::fs::MetadataExt;
        const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
        if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            return false;
        }
    }
    true
}

fn is_regular_file_without_reparse(path: &Path) -> bool {
    let Ok(metadata) = std::fs::symlink_metadata(path) else {
        return false;
    };
    is_regular_metadata_without_reparse(&metadata)
}

fn is_real_directory_without_reparse(path: &Path) -> bool {
    let Ok(metadata) = std::fs::symlink_metadata(path) else {
        return false;
    };
    if !metadata.file_type().is_dir() || metadata.file_type().is_symlink() {
        return false;
    }
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::fs::MetadataExt;
        const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
        if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            return false;
        }
    }
    true
}

fn open_read_locked(path: &Path) -> Result<File, IntegrationError> {
    let mut options = File::options();
    options.read(true);
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::fs::OpenOptionsExt;
        // Permit the child PowerShell process to read the verified script, but
        // deny writers and delete/rename while the native verifier owns it.
        const FILE_SHARE_READ: u32 = 0x0000_0001;
        const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
        options.share_mode(FILE_SHARE_READ);
        options.custom_flags(FILE_FLAG_OPEN_REPARSE_POINT);
    }
    options
        .open(path)
        .map_err(|_| IntegrationError::AgentsIntegrationFailed)
}

fn sha256_reader(file: &mut File) -> Result<String, IntegrationError> {
    file.seek(SeekFrom::Start(0))
        .map_err(|_| IntegrationError::AgentsIntegrationFailed)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let count = file
            .read(&mut buffer)
            .map_err(|_| IntegrationError::AgentsIntegrationFailed)?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    file.seek(SeekFrom::Start(0))
        .map_err(|_| IntegrationError::AgentsIntegrationFailed)?;
    Ok(format!("{:x}", hasher.finalize()))
}

#[cfg(test)]
fn sha256_file(path: &Path) -> Result<String, IntegrationError> {
    let mut file = open_read_locked(path)?;
    sha256_reader(&mut file)
}

fn strict_relative_path(value: &str) -> Option<Vec<&str>> {
    if value.is_empty()
        || value.len() > 4096
        || value.starts_with('/')
        || value.ends_with('/')
        || value.contains('\\')
        || value.contains(':')
        || value.chars().any(char::is_control)
        || Path::new(value).is_absolute()
    {
        return None;
    }
    let segments: Vec<&str> = value.split('/').collect();
    if segments
        .iter()
        .any(|segment| segment.is_empty() || *segment == "." || *segment == "..")
    {
        return None;
    }
    Some(segments)
}

fn receipt_key(relative_path: &str) -> String {
    if cfg!(target_os = "windows") {
        relative_path.to_lowercase()
    } else {
        relative_path.to_owned()
    }
}

fn catalog_digest<'a>(receipts: impl Iterator<Item = &'a InstalledFileReceipt>) -> String {
    let mut receipts: Vec<&InstalledFileReceipt> = receipts.collect();
    receipts.sort_by(|left, right| left.relative_path.cmp(&right.relative_path));
    let mut hasher = Sha256::new();
    hasher.update(FILE_CATALOG_SCHEMA.as_bytes());
    hasher.update(b"\n");
    for receipt in receipts {
        hasher.update(receipt.relative_path.as_bytes());
        hasher.update(b"\n");
        hasher.update(receipt.sha256.as_bytes());
        hasher.update(b"\n");
        hasher.update(receipt.length.to_string().as_bytes());
        hasher.update(b"\n");
    }
    format!("{:x}", hasher.finalize())
}

fn validate_path_chain(root: &Path, target: &Path, target_is_file: bool) -> bool {
    if !root.is_absolute() || !target.starts_with(root) || !is_real_directory_without_reparse(root)
    {
        return false;
    }
    let Ok(relative) = target.strip_prefix(root) else {
        return false;
    };
    let components: Vec<_> = relative.components().collect();
    if components.is_empty() {
        return !target_is_file;
    }
    let mut current = root.to_path_buf();
    for (index, component) in components.iter().enumerate() {
        let std::path::Component::Normal(segment) = component else {
            return false;
        };
        current.push(segment);
        let last = index + 1 == components.len();
        if last && target_is_file {
            if !is_regular_file_without_reparse(&current) {
                return false;
            }
        } else if !is_real_directory_without_reparse(&current) {
            return false;
        }
    }
    true
}

fn validate_installed_file(
    install_root: &Path,
    path: &Path,
    expected: &InstalledFileReceipt,
) -> Result<(), IntegrationError> {
    read_verified_installed_file(install_root, path, expected).map(|_| ())
}

fn read_verified_installed_file(
    install_root: &Path,
    path: &Path,
    expected: &InstalledFileReceipt,
) -> Result<Vec<u8>, IntegrationError> {
    if !validate_path_chain(install_root, path, true) {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    let mut file = open_read_locked(path)?;
    let metadata = file
        .metadata()
        .map_err(|_| IntegrationError::AgentsIntegrationFailed)?;
    if !is_regular_metadata_without_reparse(&metadata) || metadata.len() != expected.length {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    let capacity =
        usize::try_from(expected.length).map_err(|_| IntegrationError::AgentsIntegrationFailed)?;
    let mut bytes = Vec::with_capacity(capacity);
    file.read_to_end(&mut bytes)
        .map_err(|_| IntegrationError::AgentsIntegrationFailed)?;
    if bytes.len() as u64 != expected.length
        || format!("{:x}", Sha256::digest(&bytes)) != expected.sha256
    {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    Ok(bytes)
}

fn enumerate_regular_tree(root: &Path) -> Result<BTreeSet<String>, IntegrationError> {
    if !is_real_directory_without_reparse(root) {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    let mut pending = vec![root.to_path_buf()];
    let mut files = BTreeSet::new();
    while let Some(directory) = pending.pop() {
        let entries =
            std::fs::read_dir(&directory).map_err(|_| IntegrationError::AgentsIntegrationFailed)?;
        for entry in entries {
            let entry = entry.map_err(|_| IntegrationError::AgentsIntegrationFailed)?;
            let path = entry.path();
            let metadata = std::fs::symlink_metadata(&path)
                .map_err(|_| IntegrationError::AgentsIntegrationFailed)?;
            if metadata.file_type().is_symlink() {
                return Err(IntegrationError::AgentsIntegrationFailed);
            }
            #[cfg(target_os = "windows")]
            {
                use std::os::windows::fs::MetadataExt;
                const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
                if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
                    return Err(IntegrationError::AgentsIntegrationFailed);
                }
            }
            if metadata.file_type().is_dir() {
                let relative = path
                    .strip_prefix(root)
                    .map_err(|_| IntegrationError::AgentsIntegrationFailed)?;
                let segments: Vec<String> = relative
                    .components()
                    .map(|component| match component {
                        std::path::Component::Normal(value) => value.to_str().map(str::to_owned),
                        _ => None,
                    })
                    .collect::<Option<_>>()
                    .ok_or(IntegrationError::AgentsIntegrationFailed)?;
                if segments.is_empty() {
                    return Err(IntegrationError::AgentsIntegrationFailed);
                }
                files.insert(format!("{}/", segments.join("/")));
                pending.push(path);
            } else if metadata.file_type().is_file() {
                let relative = path
                    .strip_prefix(root)
                    .map_err(|_| IntegrationError::AgentsIntegrationFailed)?;
                let segments: Vec<String> = relative
                    .components()
                    .map(|component| match component {
                        std::path::Component::Normal(value) => value.to_str().map(str::to_owned),
                        _ => None,
                    })
                    .collect::<Option<_>>()
                    .ok_or(IntegrationError::AgentsIntegrationFailed)?;
                if segments.is_empty() {
                    return Err(IntegrationError::AgentsIntegrationFailed);
                }
                files.insert(segments.join("/"));
            } else {
                return Err(IntegrationError::AgentsIntegrationFailed);
            }
        }
    }
    Ok(files)
}

fn validate_install_manifest(
    bytes: &[u8],
    install_root: &Path,
    data_root: &Path,
) -> Result<VerifiedInstall, IntegrationError> {
    let manifest: InstalledManifest =
        serde_json::from_slice(bytes).map_err(|_| IntegrationError::AgentsIntegrationFailed)?;
    if manifest.schema_version != INSTALL_MANIFEST_SCHEMA
        || !manifest.install_root.is_absolute()
        || !manifest.data_root.is_absolute()
        || !same_path(&manifest.install_root, install_root)
        || !same_path(&manifest.data_root, data_root)
    {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    if manifest.files.is_empty() || manifest.files.len() > 100_000 {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    let mut files = BTreeMap::new();
    for receipt in manifest.files {
        if strict_relative_path(&receipt.relative_path).is_none()
            || !is_lower_sha256(&receipt.sha256)
        {
            return Err(IntegrationError::AgentsIntegrationFailed);
        }
        let key = receipt_key(&receipt.relative_path);
        if files.insert(key, receipt).is_some() {
            return Err(IntegrationError::AgentsIntegrationFailed);
        }
    }
    let build_catalog_sha256 = catalog_digest(files.values());
    if manifest
        .build_catalog_sha256
        .as_deref()
        .is_some_and(|digest| digest != build_catalog_sha256)
    {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }

    let marketplace_receipts: Vec<&InstalledFileReceipt> = files
        .values()
        .filter(|receipt| receipt.relative_path.starts_with(CODEX_MARKETPLACE_PREFIX))
        .collect();
    if marketplace_receipts.is_empty() {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    let payload_catalog_sha256 = catalog_digest(marketplace_receipts.iter().copied());
    if manifest
        .codex_payload_catalog_sha256
        .as_deref()
        .is_some_and(|digest| digest != payload_catalog_sha256)
    {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    let marketplace_root = install_root.join(CODEX_MARKETPLACE_RELATIVE_ROOT);
    if !validate_path_chain(install_root, &marketplace_root, false) {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    let actual_tree = enumerate_regular_tree(&marketplace_root)?;
    let mut expected_tree = BTreeSet::new();
    for receipt in &marketplace_receipts {
        let relative = receipt
            .relative_path
            .strip_prefix(CODEX_MARKETPLACE_PREFIX)
            .unwrap_or_default();
        expected_tree.insert(relative.to_owned());
        let segments: Vec<&str> = relative.split('/').collect();
        for index in 1..segments.len() {
            expected_tree.insert(format!("{}/", segments[..index].join("/")));
        }
    }
    if actual_tree != expected_tree {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    for receipt in marketplace_receipts {
        let target = install_root.join(receipt.relative_path.split('/').collect::<PathBuf>());
        validate_installed_file(install_root, &target, receipt)?;
    }

    // A fresh full install intentionally carries a disabled, compact record.
    // Older installed records also lack the extended read-only evidence. Keep
    // the payload install repairable, but fail the AGENTS/Connected gate closed
    // until IntegrateCodex publishes a complete current record.
    let agents_integration = manifest.agents_integration.and_then(|value| {
        let enabled = value.get("enabled").and_then(Value::as_bool) == Some(true);
        let installed = value.get("installed").and_then(Value::as_bool) == Some(true);
        if enabled && installed {
            serde_json::from_value::<AgentsIntegrationRecord>(value).ok()
        } else {
            None
        }
    });

    Ok(VerifiedInstall {
        install_root: install_root.to_path_buf(),
        data_root: data_root.to_path_buf(),
        manifest_sha256: format!("{:x}", Sha256::digest(bytes)),
        build_catalog_sha256,
        payload_catalog_sha256,
        files,
        agents_integration,
    })
}

fn load_verified_install(
    inner: &IntegrationManagerInner,
) -> Result<VerifiedInstall, IntegrationError> {
    let executable =
        std::env::current_exe().map_err(|_| IntegrationError::AgentsIntegrationFailed)?;
    let install_root = executable
        .parent()
        .ok_or(IntegrationError::AgentsIntegrationFailed)?
        .to_path_buf();
    if !is_real_directory_without_reparse(&install_root) {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    let data_root = inner.data_root.clone();
    if !is_real_directory_without_reparse(&data_root) {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    let manifest_path = data_root.join(".installer").join("install-manifest.json");
    if !validate_path_chain(&data_root, &manifest_path, true) {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    let manifest_metadata =
        std::fs::metadata(&manifest_path).map_err(|_| IntegrationError::AgentsIntegrationFailed)?;
    if !install_manifest_size_is_supported(manifest_metadata.len()) {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    let mut manifest_file = open_read_locked(&manifest_path)?;
    let mut manifest_bytes = Vec::with_capacity(manifest_metadata.len() as usize);
    manifest_file
        .read_to_end(&mut manifest_bytes)
        .map_err(|_| IntegrationError::AgentsIntegrationFailed)?;
    if manifest_bytes.len() as u64 != manifest_metadata.len() {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    validate_install_manifest(&manifest_bytes, &install_root, &data_root)
}

fn install_manifest_size_is_supported(length: u64) -> bool {
    (2..=MAX_INSTALL_MANIFEST).contains(&length)
}

fn installed_bootstrap(
    inner: &IntegrationManagerInner,
) -> Result<VerifiedBootstrap, IntegrationError> {
    let integrity = load_verified_install(inner)?;
    let expected = integrity
        .files
        .get(&receipt_key(INSTALLED_BOOTSTRAP_RELATIVE_PATH))
        .filter(|receipt| receipt.relative_path == INSTALLED_BOOTSTRAP_RELATIVE_PATH)
        .ok_or(IntegrationError::AgentsIntegrationFailed)?;
    if expected.length == 0 {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    let path = integrity
        .install_root
        .join("installer")
        .join("bootstrap.ps1");
    if !validate_path_chain(&integrity.install_root, &path, true) {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    let mut guard = open_read_locked(&path)?;
    let metadata = guard
        .metadata()
        .map_err(|_| IntegrationError::AgentsIntegrationFailed)?;
    if metadata.len() != expected.length || sha256_reader(&mut guard)? != expected.sha256 {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    Ok(VerifiedBootstrap {
        install_root: integrity.install_root.clone(),
        data_root: integrity.data_root.clone(),
        path,
        _guard: guard,
        integrity,
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum AgentsEncoding {
    Utf8,
    Utf8Bom,
    Utf16Le,
    Utf16Be,
}

fn decode_utf16_strict(bytes: &[u8], big_endian: bool) -> Option<String> {
    if bytes.len() % 2 != 0 {
        return None;
    }
    let units = bytes.chunks_exact(2).map(|pair| {
        if big_endian {
            u16::from_be_bytes([pair[0], pair[1]])
        } else {
            u16::from_le_bytes([pair[0], pair[1]])
        }
    });
    char::decode_utf16(units)
        .collect::<Result<String, _>>()
        .ok()
}

fn decode_agents_document(bytes: &[u8]) -> Option<(String, AgentsEncoding)> {
    if bytes.starts_with(&[0xef, 0xbb, 0xbf]) {
        return String::from_utf8(bytes[3..].to_vec())
            .ok()
            .map(|text| (text, AgentsEncoding::Utf8Bom));
    }
    if bytes.starts_with(&[0xff, 0xfe]) {
        return decode_utf16_strict(&bytes[2..], false).map(|text| (text, AgentsEncoding::Utf16Le));
    }
    if bytes.starts_with(&[0xfe, 0xff]) {
        return decode_utf16_strict(&bytes[2..], true).map(|text| (text, AgentsEncoding::Utf16Be));
    }
    String::from_utf8(bytes.to_vec())
        .ok()
        .map(|text| (text, AgentsEncoding::Utf8))
}

fn encode_agents_text(text: &str, encoding: AgentsEncoding, include_preamble: bool) -> Vec<u8> {
    match encoding {
        AgentsEncoding::Utf8 | AgentsEncoding::Utf8Bom => {
            let mut bytes = Vec::with_capacity(text.len() + 3);
            if include_preamble && encoding == AgentsEncoding::Utf8Bom {
                bytes.extend_from_slice(&[0xef, 0xbb, 0xbf]);
            }
            bytes.extend_from_slice(text.as_bytes());
            bytes
        }
        AgentsEncoding::Utf16Le | AgentsEncoding::Utf16Be => {
            let mut bytes = Vec::with_capacity(text.len() * 2 + 2);
            if include_preamble {
                bytes.extend_from_slice(if encoding == AgentsEncoding::Utf16Le {
                    &[0xff, 0xfe]
                } else {
                    &[0xfe, 0xff]
                });
            }
            for unit in text.encode_utf16() {
                let encoded = if encoding == AgentsEncoding::Utf16Le {
                    unit.to_le_bytes()
                } else {
                    unit.to_be_bytes()
                };
                bytes.extend_from_slice(&encoded);
            }
            bytes
        }
    }
}

fn encoding_name(encoding: AgentsEncoding) -> &'static str {
    match encoding {
        AgentsEncoding::Utf8 => "utf8",
        AgentsEncoding::Utf8Bom => "utf8-bom",
        AgentsEncoding::Utf16Le => "utf16-le",
        AgentsEncoding::Utf16Be => "utf16-be",
    }
}

fn normalize_template_text(bytes: &[u8]) -> Option<String> {
    let body = bytes.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(bytes);
    let text = std::str::from_utf8(body).ok()?;
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    let normalized = normalized.trim_end_matches('\n').to_owned();
    if normalized.starts_with(AGENTS_BEGIN_MARKER)
        && normalized.ends_with(AGENTS_END_MARKER)
        && normalized.match_indices(AGENTS_BEGIN_MARKER).count() == 1
        && normalized.match_indices(AGENTS_END_MARKER).count() == 1
    {
        Some(normalized)
    } else {
        None
    }
}

fn verify_agents_integration(
    integrity: &VerifiedInstall,
    codex_home: &Path,
) -> Result<AgentsEvidence, IntegrationError> {
    let record = integrity
        .agents_integration
        .as_ref()
        .ok_or(IntegrationError::AgentsIntegrationFailed)?;
    if record.schema_version != AGENTS_INTEGRATION_SCHEMA
        || !record.enabled
        || !record.installed
        || record.template_relative_path != AGENTS_TEMPLATE_RELATIVE_PATH
        || !is_lower_sha256(&record.template_sha256)
        || !is_lower_sha256(&record.installed_file_sha256)
        || !is_lower_sha256(&record.block_sha256)
        || !is_lower_sha256(&record.prefix_sha256)
        || !is_lower_sha256(&record.external_sha256)
        || !is_lower_sha256(&record.owned_range_sha256)
        || record.transaction_id.is_empty()
        || record.transaction_id.len() > 128
        || !record
            .transaction_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        || !codex_home.is_absolute()
        || !same_path(&record.codex_home, codex_home)
    {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    let expected_agents_path = codex_home.join("AGENTS.md");
    if !same_path(&record.path, &expected_agents_path)
        || !is_real_directory_without_reparse(codex_home)
        || !validate_path_chain(codex_home, &expected_agents_path, true)
    {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    let mut agents_file = open_read_locked(&expected_agents_path)?;
    let agents_metadata = agents_file
        .metadata()
        .map_err(|_| IntegrationError::AgentsIntegrationFailed)?;
    if !is_regular_metadata_without_reparse(&agents_metadata)
        || agents_metadata.len() != record.installed_file_length
    {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    let capacity = usize::try_from(record.installed_file_length)
        .map_err(|_| IntegrationError::AgentsIntegrationFailed)?;
    let mut bytes = Vec::with_capacity(capacity);
    agents_file
        .read_to_end(&mut bytes)
        .map_err(|_| IntegrationError::AgentsIntegrationFailed)?;
    if bytes.len() as u64 != record.installed_file_length
        || format!("{:x}", Sha256::digest(&bytes)) != record.installed_file_sha256
    {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    let (text, encoding) =
        decode_agents_document(&bytes).ok_or(IntegrationError::AgentsIntegrationFailed)?;
    if encoding_name(encoding) != record.encoding || text.contains('\0') {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    let begins: Vec<usize> = text
        .match_indices(AGENTS_BEGIN_MARKER)
        .map(|(index, _)| index)
        .collect();
    let ends: Vec<usize> = text
        .match_indices(AGENTS_END_MARKER)
        .map(|(index, _)| index)
        .collect();
    if begins.len() != 1 || ends.len() != 1 || begins[0] >= ends[0] {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    let begin = begins[0];
    let end = ends[0] + AGENTS_END_MARKER.len();
    let block = &text[begin..end];
    let block_bytes = encode_agents_text(block, encoding, false);
    if format!("{:x}", Sha256::digest(&block_bytes)) != record.block_sha256 {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    let prefix_bytes = base64::engine::general_purpose::STANDARD
        .decode(record.owned_prefix_base64.as_bytes())
        .map_err(|_| IntegrationError::AgentsIntegrationFailed)?;
    if format!("{:x}", Sha256::digest(&prefix_bytes)) != record.prefix_sha256 {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    let prefix_text = match encoding {
        AgentsEncoding::Utf8 | AgentsEncoding::Utf8Bom => {
            String::from_utf8(prefix_bytes.clone()).ok()
        }
        AgentsEncoding::Utf16Le => decode_utf16_strict(&prefix_bytes, false),
        AgentsEncoding::Utf16Be => decode_utf16_strict(&prefix_bytes, true),
    }
    .ok_or(IntegrationError::AgentsIntegrationFailed)?;
    let Some(prefix_start) = begin.checked_sub(prefix_text.len()) else {
        return Err(IntegrationError::AgentsIntegrationFailed);
    };
    if text.get(prefix_start..begin) != Some(prefix_text.as_str()) {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    let owned_range = format!("{prefix_text}{block}");
    let owned_range_bytes = encode_agents_text(&owned_range, encoding, false);
    if format!("{:x}", Sha256::digest(&owned_range_bytes)) != record.owned_range_sha256 {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    let external_text = format!("{}{}", &text[..prefix_start], &text[end..]);
    let external_bytes = encode_agents_text(&external_text, encoding, true);
    if external_bytes.len() as u64 != record.external_length
        || format!("{:x}", Sha256::digest(&external_bytes)) != record.external_sha256
    {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }

    let template_receipt = integrity
        .files
        .get(&receipt_key(AGENTS_TEMPLATE_RELATIVE_PATH))
        .filter(|receipt| receipt.relative_path == AGENTS_TEMPLATE_RELATIVE_PATH)
        .ok_or(IntegrationError::AgentsIntegrationFailed)?;
    if template_receipt.sha256 != record.template_sha256 {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    let template_path = integrity.install_root.join(
        AGENTS_TEMPLATE_RELATIVE_PATH
            .split('/')
            .collect::<PathBuf>(),
    );
    let template_bytes =
        read_verified_installed_file(&integrity.install_root, &template_path, template_receipt)?;
    let expected_template = normalize_template_text(&template_bytes)
        .ok_or(IntegrationError::AgentsIntegrationFailed)?;
    if block.replace("\r\n", "\n").replace('\r', "\n") != expected_template {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    Ok(AgentsEvidence {
        block_sha256: record.block_sha256.clone(),
    })
}

fn parse_codex_only_receipt(
    bytes: &[u8],
    expected_version: &str,
    expected_integrity: &VerifiedInstall,
) -> Result<CodexOnlyReceipt, IntegrationError> {
    if bytes.is_empty() || bytes.len() > MAX_CODEX_ONLY_RECEIPT || bytes.contains(&0) {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    let mut line = bytes;
    if let Some(without_lf) = line.strip_suffix(b"\n") {
        line = without_lf.strip_suffix(b"\r").unwrap_or(without_lf);
    }
    if line.is_empty() || line.contains(&b'\r') || line.contains(&b'\n') {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    let text = std::str::from_utf8(line).map_err(|_| IntegrationError::AgentsIntegrationFailed)?;
    if text.trim() != text || !text.starts_with('{') || !text.ends_with('}') {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    let receipt: CodexOnlyReceipt =
        serde_json::from_str(text).map_err(|_| IntegrationError::AgentsIntegrationFailed)?;
    if receipt.schema_version != CODEX_ONLY_RECEIPT_SCHEMA
        || receipt.plugin_id != PLUGIN_ID
        || receipt.plugin_version != expected_version
        || !is_lower_sha256(&receipt.agents_block_sha256)
        || receipt.payload_catalog_sha256 != expected_integrity.payload_catalog_sha256
        || receipt.build_catalog_sha256 != expected_integrity.build_catalog_sha256
        || receipt.install_manifest_sha256 != expected_integrity.manifest_sha256
        || !is_lower_sha256(&receipt.agents_file_sha256)
        || !is_lower_sha256(&receipt.agents_external_sha256)
        || !is_lower_sha256(&receipt.agents_owned_range_sha256)
    {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    let _status = receipt.status;
    Ok(receipt)
}

fn discover_windows_powershell() -> Option<PathBuf> {
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::ffi::OsStringExt;
        use windows_sys::Win32::System::SystemInformation::GetSystemDirectoryW;

        let mut buffer = vec![0_u16; 32_768];
        // SAFETY: `buffer` is writable for the advertised length. The API
        // returns the number of UTF-16 code units excluding the terminator.
        let length = unsafe { GetSystemDirectoryW(buffer.as_mut_ptr(), buffer.len() as u32) };
        if length == 0 || length as usize >= buffer.len() {
            return None;
        }
        let system_directory = PathBuf::from(OsString::from_wide(&buffer[..length as usize]));
        let candidate = system_directory
            .join("WindowsPowerShell")
            .join("v1.0")
            .join("powershell.exe");
        if validate_path_chain(&system_directory, &candidate, true) {
            Some(candidate)
        } else {
            None
        }
    }
    #[cfg(not(target_os = "windows"))]
    {
        None
    }
}

fn resolve_codex_home() -> Result<PathBuf, IntegrationError> {
    if let Some(value) = std::env::var_os("CODEX_HOME") {
        let candidate = PathBuf::from(value);
        if candidate.is_absolute() {
            return Ok(candidate);
        }
    }
    for variable in ["USERPROFILE", "HOME"] {
        if let Some(value) = std::env::var_os(variable) {
            let candidate = PathBuf::from(value).join(".codex");
            if candidate.is_absolute() {
                return Ok(candidate);
            }
        }
    }
    Err(IntegrationError::AgentsIntegrationFailed)
}

fn integrate_global_agents(
    inner: &IntegrationManagerInner,
    expected_version: &str,
    codex_cli: &Path,
) -> Result<CodexOnlyReceipt, IntegrationError> {
    let verified = installed_bootstrap(inner)?;
    let install_root = &verified.install_root;
    let data_root = &verified.data_root;
    let bootstrap = &verified.path;
    let codex_home = resolve_codex_home()?;
    let powershell =
        discover_windows_powershell().ok_or(IntegrationError::AgentsIntegrationFailed)?;
    let arguments = [
        OsString::from("-NoLogo"),
        OsString::from("-NoProfile"),
        OsString::from("-NonInteractive"),
        OsString::from("-ExecutionPolicy"),
        OsString::from("Bypass"),
        OsString::from("-File"),
        bootstrap.as_os_str().to_owned(),
        OsString::from("-Action"),
        OsString::from("IntegrateCodex"),
        OsString::from("-InstallRoot"),
        install_root.as_os_str().to_owned(),
        OsString::from("-DataRoot"),
        data_root.as_os_str().to_owned(),
        OsString::from("-CodexHome"),
        codex_home.as_os_str().to_owned(),
        OsString::from("-CodexCliPath"),
        codex_cli.as_os_str().to_owned(),
        OsString::from("-ExpectedInstallManifestSha256"),
        OsString::from(&verified.integrity.manifest_sha256),
        OsString::from("-ActionTimeoutSeconds"),
        OsString::from("60"),
        OsString::from("-MutexTimeoutSeconds"),
        OsString::from("10"),
    ];
    let references: Vec<&OsStr> = arguments.iter().map(OsString::as_os_str).collect();
    let output = run_process(&powershell, &references, CODEX_INTEGRATION_TIMEOUT)
        .map_err(|_| IntegrationError::AgentsIntegrationFailed)?;
    if !output.status.success() {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    let receipt = parse_codex_only_receipt(&output.stdout, expected_version, &verified.integrity)?;
    let refreshed = load_verified_install(inner)?;
    if refreshed.build_catalog_sha256 != verified.integrity.build_catalog_sha256
        || refreshed.payload_catalog_sha256 != verified.integrity.payload_catalog_sha256
    {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    let evidence = verify_agents_integration(&refreshed, &codex_home)?;
    let record = refreshed
        .agents_integration
        .as_ref()
        .ok_or(IntegrationError::AgentsIntegrationFailed)?;
    if evidence.block_sha256 != receipt.agents_block_sha256
        || record.installed_file_sha256 != receipt.agents_file_sha256
        || record.external_sha256 != receipt.agents_external_sha256
        || record.owned_range_sha256 != receipt.agents_owned_range_sha256
    {
        return Err(IntegrationError::AgentsIntegrationFailed);
    }
    Ok(receipt)
}

fn locate_payload() -> Result<Payload, IntegrationError> {
    let installed = std::env::current_exe()
        .ok()
        .and_then(|executable| executable.parent().map(Path::to_path_buf))
        .map(|root| root.join("integrations").join("codex-marketplace"));

    let mut candidates = Vec::new();
    if let Some(installed) = installed {
        candidates.push(installed);
    }
    if cfg!(debug_assertions) {
        candidates.push(
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("..")
                .join("..")
                .join(".."),
        );
    }

    for candidate in candidates {
        let root = candidate.canonicalize().unwrap_or(candidate);
        if let Some(payload) = validate_payload_root(&root) {
            return Ok(payload);
        }
    }
    Err(IntegrationError::PayloadUnavailable)
}

fn locate_verified_payload(
    inner: &IntegrationManagerInner,
) -> Result<(Payload, VerifiedInstall), IntegrationError> {
    let payload = locate_payload()?;
    let integrity = load_verified_install(inner)?;
    let expected_marketplace = integrity.install_root.join(CODEX_MARKETPLACE_RELATIVE_ROOT);
    let expected_plugin = expected_marketplace
        .join("plugins")
        .join("cluster-your-codex");
    if !same_path(&payload.marketplace_root, &expected_marketplace)
        || !same_path(&payload.plugin_root, &expected_plugin)
    {
        return Err(IntegrationError::PayloadUnavailable);
    }
    Ok((payload, integrity))
}

fn validate_payload_root(root: &Path) -> Option<Payload> {
    let marketplace_manifest = root
        .join(".agents")
        .join("plugins")
        .join("marketplace.json");
    let plugin_root = root.join("plugins").join("cluster-your-codex");
    let plugin_manifest = plugin_root.join(".codex-plugin").join("plugin.json");
    for required in [
        marketplace_manifest.as_path(),
        plugin_manifest.as_path(),
        plugin_root.join(".mcp.json").as_path(),
        plugin_root
            .join("mcp")
            .join("dist")
            .join("server.js")
            .as_path(),
    ] {
        if !required.is_file() {
            return None;
        }
    }
    let manifest: Value = read_small_json(&plugin_manifest)?;
    if manifest.get("name")?.as_str()? != "cluster-your-codex" {
        return None;
    }
    let desired_version = manifest.get("version")?.as_str()?.to_owned();
    if !valid_version(&desired_version) {
        return None;
    }
    let marketplace: Value = read_small_json(&marketplace_manifest)?;
    if marketplace.get("name")?.as_str()? != MARKETPLACE_NAME {
        return None;
    }
    let owned_plugin = marketplace
        .get("plugins")?
        .as_array()?
        .iter()
        .find(|plugin| plugin.get("name").and_then(Value::as_str) == Some("cluster-your-codex"))?;
    let source = owned_plugin.get("source")?;
    if source.get("source")?.as_str()? != "local" {
        return None;
    }
    let relative_source = source.get("path")?.as_str()?;
    if relative_source.is_empty()
        || relative_source.len() > 4096
        || relative_source.chars().any(char::is_control)
        || Path::new(relative_source).is_absolute()
    {
        return None;
    }
    let resolved_source = root.join(relative_source).canonicalize().ok()?;
    let canonical_plugin = plugin_root.canonicalize().ok()?;
    if !same_path(&resolved_source, &canonical_plugin) {
        return None;
    }
    Some(Payload {
        marketplace_root: root.to_path_buf(),
        plugin_root,
        desired_version,
    })
}

fn valid_version(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_' | b'+'))
}

fn validate_owned_marketplace_root(root: &Path) -> Option<PathBuf> {
    if !root.is_absolute() {
        return None;
    }
    let canonical = root.canonicalize().ok()?;
    validate_payload_root(&canonical)?;
    Some(canonical)
}

fn validate_installed_plugin(registration: &PluginRegistration) -> Option<InstalledPlugin> {
    if !registration.source_path.is_absolute() || !valid_version(&registration.version) {
        return None;
    }
    let root = registration.source_path.canonicalize().ok()?;
    if !root.is_dir() {
        return None;
    }

    let plugin_manifest = root.join(".codex-plugin").join("plugin.json");
    let manifest: Value = read_small_json(&plugin_manifest)?;
    if manifest.get("name")?.as_str()? != "cluster-your-codex"
        || manifest.get("version")?.as_str()? != registration.version.as_str()
    {
        return None;
    }

    let bridge_manifest: Value = read_small_json(&root.join(".mcp.json"))?;
    let bridge = bridge_manifest
        .get("mcpServers")?
        .get("cluster_your_codex")?;
    if bridge.get("cwd")?.as_str()? != "." {
        return None;
    }
    let arguments = bridge.get("args")?.as_array()?;
    let environment = bridge.get("env_vars")?.as_array()?;
    if arguments.len() != 1
        || arguments[0].as_str()? != "./mcp/dist/server.js"
        || environment.len() != 1
        || environment[0].as_str()? != "CYC_CONTROLLER_TOKEN_FILE"
    {
        return None;
    }

    let server = root.join("mcp").join("dist").join("server.js");
    let server_metadata = std::fs::metadata(&server).ok()?;
    if !server_metadata.is_file() || server_metadata.len() == 0 {
        return None;
    }
    let server = server.canonicalize().ok()?;
    if !server.starts_with(&root) {
        return None;
    }

    let runtime = match bridge.get("command")?.as_str()? {
        "node" => discover_path_executable("node")?,
        "./mcp/runtime/node.exe" if cfg!(target_os = "windows") => {
            let runtime = root
                .join("mcp")
                .join("runtime")
                .join("node.exe")
                .canonicalize()
                .ok()?;
            if !runtime.starts_with(&root) {
                return None;
            }
            runtime
        }
        "./mcp/runtime/node" if !cfg!(target_os = "windows") => {
            let runtime = root
                .join("mcp")
                .join("runtime")
                .join("node")
                .canonicalize()
                .ok()?;
            if !runtime.starts_with(&root) {
                return None;
            }
            runtime
        }
        _ => return None,
    };
    let runtime_metadata = std::fs::metadata(&runtime).ok()?;
    if !runtime_metadata.is_file() || runtime_metadata.len() == 0 {
        return None;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if runtime_metadata.permissions().mode() & 0o111 == 0 {
            return None;
        }
    }

    Some(InstalledPlugin {
        root,
        runtime,
        server,
        version: registration.version.clone(),
    })
}

fn discover_codex_cli() -> Result<Option<DiscoveredCodexCli>, IntegrationError> {
    let mut saw_candidate = false;
    let mut probe = |candidate: &Path| cli_version(candidate).ok();

    if let Some(explicit) = std::env::var_os("CODEX_CLI_PATH") {
        if let Some(cli) =
            probe_codex_cli_candidate(PathBuf::from(explicit), &mut saw_candidate, &mut probe)
        {
            return Ok(Some(cli));
        }
    }

    let local_app_candidates = local_app_codex_candidates();
    let local_app_probes =
        probe_codex_cli_candidates(local_app_candidates, &mut saw_candidate, &mut probe);
    if let Some(cli) = best_versioned_codex_cli(local_app_probes) {
        return Ok(Some(cli));
    }

    let mut plugin_appserver_candidates = Vec::new();
    if let Some(home) = std::env::var_os("CODEX_HOME") {
        plugin_appserver_candidates.push(
            PathBuf::from(home)
                .join("plugins")
                .join(".plugin-appserver")
                .join(executable_name("codex")),
        );
    }
    if let Some(home) = std::env::var_os("USERPROFILE").or_else(|| std::env::var_os("HOME")) {
        plugin_appserver_candidates.push(
            PathBuf::from(home)
                .join(".codex")
                .join("plugins")
                .join(".plugin-appserver")
                .join(executable_name("codex")),
        );
    }
    for candidate in plugin_appserver_candidates {
        if let Some(cli) = probe_codex_cli_candidate(candidate, &mut saw_candidate, &mut probe) {
            return Ok(Some(cli));
        }
    }

    if let Some(path) = std::env::var_os("PATH") {
        for candidate in
            std::env::split_paths(&path).map(|root| root.join(executable_name("codex")))
        {
            if let Some(cli) = probe_codex_cli_candidate(candidate, &mut saw_candidate, &mut probe)
            {
                return Ok(Some(cli));
            }
        }
    }

    if saw_candidate {
        Err(IntegrationError::CodexInvocationFailed)
    } else {
        Ok(None)
    }
}

fn local_app_codex_candidates() -> Vec<PathBuf> {
    let Some(local_app_data) = std::env::var_os("LOCALAPPDATA") else {
        return Vec::new();
    };
    let root = PathBuf::from(local_app_data)
        .join("OpenAI")
        .join("Codex")
        .join("bin");
    let Ok(entries) = std::fs::read_dir(root) else {
        return Vec::new();
    };
    let mut candidates = entries
        .filter_map(Result::ok)
        .filter_map(|entry| {
            entry
                .file_type()
                .ok()
                .filter(|kind| kind.is_dir())
                .map(|_| entry)
        })
        .map(|entry| entry.path().join(executable_name("codex")))
        .collect::<Vec<_>>();
    candidates.sort();
    candidates
}

fn probe_codex_cli_candidates(
    candidates: Vec<PathBuf>,
    saw_candidate: &mut bool,
    probe: &mut impl FnMut(&Path) -> Option<String>,
) -> Vec<DiscoveredCodexCli> {
    candidates
        .into_iter()
        .filter_map(|candidate| probe_codex_cli_candidate(candidate, saw_candidate, probe))
        .collect()
}

fn probe_codex_cli_candidate(
    candidate: PathBuf,
    saw_candidate: &mut bool,
    probe: &mut impl FnMut(&Path) -> Option<String>,
) -> Option<DiscoveredCodexCli> {
    let metadata = std::fs::metadata(&candidate).ok()?;
    if !metadata.is_file() {
        return None;
    }
    *saw_candidate = true;
    let version = probe(&candidate)?;
    Some(DiscoveredCodexCli {
        path: candidate.canonicalize().unwrap_or(candidate),
        version,
        modified_at: metadata.modified().unwrap_or(UNIX_EPOCH),
    })
}

fn best_versioned_codex_cli(mut candidates: Vec<DiscoveredCodexCli>) -> Option<DiscoveredCodexCli> {
    candidates.sort_by(|left, right| {
        codex_version_rank(&right.version)
            .cmp(&codex_version_rank(&left.version))
            .then_with(|| right.modified_at.cmp(&left.modified_at))
            .then_with(|| left.path.cmp(&right.path))
    });
    candidates.into_iter().next()
}

fn codex_version_rank(version: &str) -> Vec<u64> {
    let mut rank = Vec::new();
    let mut current = None::<u64>;
    for byte in version.bytes() {
        if byte.is_ascii_digit() {
            current = Some(
                current
                    .unwrap_or(0)
                    .saturating_mul(10)
                    .saturating_add(u64::from(byte - b'0')),
            );
        } else if let Some(value) = current.take() {
            rank.push(value);
        }
    }
    if let Some(value) = current {
        rank.push(value);
    }
    rank
}

fn executable_name(base: &str) -> OsString {
    if cfg!(target_os = "windows") {
        format!("{base}.exe").into()
    } else {
        base.into()
    }
}

fn discover_path_executable(base: &str) -> Option<PathBuf> {
    std::env::var_os("PATH").and_then(|path| {
        std::env::split_paths(&path)
            .map(|root| root.join(executable_name(base)))
            .find(|candidate| candidate.is_file())
    })
}

fn read_bounded<R: Read>(mut reader: R, maximum: usize) -> Vec<u8> {
    let mut stored = Vec::new();
    let mut buffer = [0_u8; 8192];
    loop {
        let count = match reader.read(&mut buffer) {
            Ok(0) | Err(_) => break,
            Ok(count) => count,
        };
        if stored.len() < maximum {
            let remaining = maximum - stored.len();
            stored.extend_from_slice(&buffer[..count.min(remaining)]);
        }
    }
    stored
}

fn run_process(
    executable: &Path,
    arguments: &[&OsStr],
    timeout: Duration,
) -> Result<ProcessOutput, IntegrationError> {
    let mut child = Command::new(executable)
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|_| IntegrationError::CodexInvocationFailed)?;
    let stdout = child
        .stdout
        .take()
        .ok_or(IntegrationError::CodexInvocationFailed)?;
    let stderr = child
        .stderr
        .take()
        .ok_or(IntegrationError::CodexInvocationFailed)?;
    let stdout_reader = thread::spawn(move || read_bounded(stdout, MAX_PROCESS_OUTPUT));
    let stderr_reader = thread::spawn(move || read_bounded(stderr, MAX_PROCESS_OUTPUT));

    let deadline = Instant::now() + timeout;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(40)),
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(IntegrationError::CodexInvocationFailed);
            }
            Err(_) => return Err(IntegrationError::CodexInvocationFailed),
        }
    };
    let stdout = stdout_reader
        .join()
        .map_err(|_| IntegrationError::CodexInvocationFailed)?;
    let stderr = stderr_reader
        .join()
        .map_err(|_| IntegrationError::CodexInvocationFailed)?;
    Ok(ProcessOutput {
        status,
        stdout,
        _stderr: stderr,
    })
}

fn run_codex(cli: &Path, arguments: &[&OsStr]) -> Result<Vec<u8>, IntegrationError> {
    let output = run_process(cli, arguments, CODEX_TIMEOUT)?;
    if !output.status.success() {
        return Err(IntegrationError::CodexInvocationFailed);
    }
    Ok(output.stdout)
}

fn cli_version(cli: &Path) -> Result<String, IntegrationError> {
    let stdout = run_codex(cli, &[OsStr::new("--version")])?;
    let version = std::str::from_utf8(&stdout)
        .map_err(|_| IntegrationError::CodexOutputInvalid)?
        .trim();
    if version.is_empty() || version.len() > 128 || version.contains(['\r', '\n']) {
        return Err(IntegrationError::CodexOutputInvalid);
    }
    Ok(version.to_owned())
}

fn plugin_registration(cli: &Path) -> Result<Option<PluginRegistration>, IntegrationError> {
    let stdout = run_codex(
        cli,
        &[
            OsStr::new("plugin"),
            OsStr::new("list"),
            OsStr::new("--json"),
        ],
    )?;
    parse_plugin_registration(&stdout)
}

fn parse_plugin_registration(bytes: &[u8]) -> Result<Option<PluginRegistration>, IntegrationError> {
    let value: Value =
        serde_json::from_slice(bytes).map_err(|_| IntegrationError::CodexOutputInvalid)?;
    let installed = value
        .get("installed")
        .and_then(Value::as_array)
        .ok_or(IntegrationError::CodexOutputInvalid)?;
    for plugin in installed {
        if plugin.get("pluginId").and_then(Value::as_str) == Some(PLUGIN_ID) {
            if plugin.get("name").and_then(Value::as_str) != Some("cluster-your-codex")
                || plugin.get("marketplaceName").and_then(Value::as_str) != Some(MARKETPLACE_NAME)
                || plugin.get("installed").and_then(Value::as_bool) != Some(true)
                || plugin
                    .get("marketplaceSource")
                    .and_then(|value| value.get("sourceType"))
                    .and_then(Value::as_str)
                    != Some("local")
            {
                return Err(IntegrationError::CodexOutputInvalid);
            }
            let version = plugin
                .get("version")
                .and_then(Value::as_str)
                .filter(|value| valid_version(value))
                .ok_or(IntegrationError::CodexOutputInvalid)?;
            let enabled = plugin
                .get("enabled")
                .and_then(Value::as_bool)
                .ok_or(IntegrationError::CodexOutputInvalid)?;
            let source = plugin
                .get("source")
                .ok_or(IntegrationError::CodexOutputInvalid)?;
            if source.get("source").and_then(Value::as_str) != Some("local") {
                return Err(IntegrationError::CodexOutputInvalid);
            }
            let source_path = source
                .get("path")
                .and_then(Value::as_str)
                .filter(|value| {
                    !value.is_empty()
                        && value.len() <= 4096
                        && !value.chars().any(char::is_control)
                        && Path::new(value).is_absolute()
                })
                .ok_or(IntegrationError::CodexOutputInvalid)?;
            return Ok(Some(PluginRegistration {
                version: version.to_owned(),
                enabled,
                source_path: PathBuf::from(source_path),
            }));
        }
    }
    Ok(None)
}

fn registered_marketplace_root(cli: &Path) -> Result<Option<PathBuf>, IntegrationError> {
    let stdout = run_codex(
        cli,
        &[
            OsStr::new("plugin"),
            OsStr::new("marketplace"),
            OsStr::new("list"),
            OsStr::new("--json"),
        ],
    )?;
    let value: Value =
        serde_json::from_slice(&stdout).map_err(|_| IntegrationError::CodexOutputInvalid)?;
    let marketplaces = value
        .get("marketplaces")
        .and_then(Value::as_array)
        .ok_or(IntegrationError::CodexOutputInvalid)?;
    for marketplace in marketplaces {
        if marketplace.get("name").and_then(Value::as_str) == Some(MARKETPLACE_NAME) {
            let root = marketplace
                .get("root")
                .and_then(Value::as_str)
                .filter(|value| {
                    !value.is_empty()
                        && value.len() <= 4096
                        && !value.chars().any(char::is_control)
                        && Path::new(value).is_absolute()
                })
                .ok_or(IntegrationError::CodexOutputInvalid)?;
            return Ok(Some(PathBuf::from(root)));
        }
    }
    Ok(None)
}

fn same_path(left: &Path, right: &Path) -> bool {
    let left = left.canonicalize().unwrap_or_else(|_| left.to_path_buf());
    let right = right.canonicalize().unwrap_or_else(|_| right.to_path_buf());
    if cfg!(target_os = "windows") {
        left.to_string_lossy()
            .eq_ignore_ascii_case(&right.to_string_lossy())
    } else {
        left == right
    }
}

fn process_is_alive(pid: u32) -> bool {
    if pid == 0 {
        return false;
    }
    #[cfg(target_os = "windows")]
    {
        use windows_sys::Win32::Foundation::CloseHandle;
        use windows_sys::Win32::System::Threading::{
            GetExitCodeProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
        };
        // SAFETY: the numeric PID comes from a bounded, strict local receipt;
        // the returned handle is closed on every successful OpenProcess path.
        unsafe {
            let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
            if handle.is_null() {
                return false;
            }
            let mut code = 0_u32;
            const STILL_ACTIVE_EXIT_CODE: u32 = 259;
            let alive =
                GetExitCodeProcess(handle, &mut code) != 0 && code == STILL_ACTIVE_EXIT_CODE;
            CloseHandle(handle);
            return alive;
        }
    }
    #[cfg(target_os = "linux")]
    {
        return PathBuf::from("/proc").join(pid.to_string()).is_dir();
    }
    #[cfg(target_os = "macos")]
    {
        return Command::new("kill")
            .args(["-0", &pid.to_string()])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|status| status.success());
    }
    #[allow(unreachable_code)]
    false
}

fn valid_active_receipt(
    receipt: &McpActiveReceipt,
    installed_version: &str,
    now: DateTime<Utc>,
) -> bool {
    if receipt.api_version != "cyc.dev/mcp-runtime/v1"
        || receipt.bridge_version != installed_version
        || receipt.last_seen_at < receipt.started_at
        || receipt.controller_verified_at < receipt.started_at
        || receipt.controller_verified_at > receipt.last_seen_at
        || !process_is_alive(receipt.pid)
    {
        return false;
    }
    let age = now.signed_duration_since(receipt.last_seen_at);
    let controller_age = now.signed_duration_since(receipt.controller_verified_at);
    age >= -ACTIVE_RECEIPT_CLOCK_SKEW
        && age <= ACTIVE_RECEIPT_TTL
        && controller_age >= -ACTIVE_RECEIPT_CLOCK_SKEW
        && controller_age <= ACTIVE_CONTROLLER_VERIFICATION_TTL
}

fn same_runtime(receipt: &McpActiveReceipt, expected: &ActiveRuntimeIdentity) -> bool {
    receipt.pid == expected.pid
        && receipt.started_at == expected.started_at
        && receipt.bridge_version == expected.bridge_version
}

fn connected_runtime_identity(
    inner: &IntegrationManagerInner,
) -> Result<Option<ActiveRuntimeIdentity>, IntegrationError> {
    let status = collect_status(inner)?;
    if !status.is_connected() {
        return Ok(None);
    }
    Ok(status.active_runtime)
}

fn status_from_receipts(
    inner: &IntegrationManagerInner,
    installed_version: &str,
) -> (IntegrationState, Option<ActiveRuntimeIdentity>) {
    let restart = read_small_json::<RestartReceipt>(&restart_receipt_path(inner));
    let active_path = active_receipt_path(inner);
    let active = read_small_json::<McpActiveReceipt>(&active_path);
    if let Some(receipt) = active {
        if valid_active_receipt(&receipt, installed_version, Utc::now()) {
            let loaded_after_install = restart.as_ref().is_none_or(|restart| {
                i64::try_from(restart.installed_at_ms)
                    .is_ok_and(|installed_at| receipt.started_at.timestamp_millis() > installed_at)
            });
            if loaded_after_install {
                if restart.is_some() {
                    let _ = std::fs::remove_file(restart_receipt_path(inner));
                }
                return (
                    IntegrationState::Connected,
                    Some(ActiveRuntimeIdentity {
                        pid: receipt.pid,
                        started_at: receipt.started_at,
                        bridge_version: receipt.bridge_version,
                    }),
                );
            }
        } else {
            // A crashed or stale runtime must not remain authoritative. Return
            // Stale once for visibility, then subsequent status calls settle
            // to Installed (or RestartRequired when the install marker exists).
            let _ = std::fs::remove_file(&active_path);
            if restart.is_none() {
                return (IntegrationState::Stale, None);
            }
        }
    } else if active_path.is_file() {
        let _ = std::fs::remove_file(active_path);
        if restart.is_none() {
            return (IntegrationState::Broken, None);
        }
    }
    if restart.is_some() {
        (IntegrationState::RestartRequired, None)
    } else {
        (IntegrationState::Installed, None)
    }
}

fn state_from_receipts(
    inner: &IntegrationManagerInner,
    installed_version: &str,
) -> IntegrationState {
    status_from_receipts(inner, installed_version).0
}

fn status_message(state: IntegrationState) -> &'static str {
    match state {
        IntegrationState::NotFound => "Install Codex Desktop or the Codex CLI first.",
        IntegrationState::NotInstalled => "The ClusterYourCodex plugin is ready to install.",
        IntegrationState::Installed => {
            "The plugin package is installed; active Codex loading is not yet verified."
        }
        IntegrationState::RestartRequired => {
            "Restart Codex after installation, then run the connection check."
        }
        IntegrationState::Connected => {
            "The active Codex runtime loaded the plugin and completed a verified handshake."
        }
        IntegrationState::Stale => "The active Codex runtime handshake is stale.",
        IntegrationState::Broken => "The integration needs repair or a new connection check.",
        IntegrationState::VersionMismatch => {
            "The installed plugin version does not match this controller."
        }
    }
}

fn collect_status(inner: &IntegrationManagerInner) -> Result<IntegrationStatus, IntegrationError> {
    let checked_at_ms = now_ms()?;
    let structural_payload = locate_payload().ok();
    let desired_version = structural_payload
        .as_ref()
        .map(|value| value.desired_version.clone());
    let (payload, integrity) = match locate_verified_payload(inner) {
        Ok(value) => value,
        Err(_) => {
            return Ok(IntegrationStatus {
                state: IntegrationState::Broken,
                checked_at_ms,
                payload_available: false,
                plugin_enabled: false,
                agents_integrated: false,
                payload_catalog_sha256: None,
                build_catalog_sha256: None,
                install_manifest_sha256: None,
                agents_block_sha256: None,
                cli_version: None,
                installed_version: None,
                desired_version,
                active_runtime: None,
                message: "The installed Codex payload or its build catalog failed integrity verification.",
            });
        }
    };
    let desired_version = Some(payload.desired_version.clone());
    let payload_catalog_sha256 = Some(integrity.payload_catalog_sha256.clone());
    let build_catalog_sha256 = Some(integrity.build_catalog_sha256.clone());
    let install_manifest_sha256 = Some(integrity.manifest_sha256.clone());
    let agents_evidence = resolve_codex_home()
        .ok()
        .and_then(|home| verify_agents_integration(&integrity, &home).ok());
    let agents_integrated = agents_evidence.is_some();
    let agents_block_sha256 = agents_evidence.map(|evidence| evidence.block_sha256);
    let cli = match discover_codex_cli() {
        Ok(Some(cli)) => cli,
        Ok(None) => {
            return Ok(IntegrationStatus {
                state: IntegrationState::NotFound,
                checked_at_ms,
                payload_available: true,
                plugin_enabled: false,
                agents_integrated,
                payload_catalog_sha256,
                build_catalog_sha256,
                install_manifest_sha256,
                agents_block_sha256,
                cli_version: None,
                installed_version: None,
                desired_version,
                active_runtime: None,
                message: status_message(IntegrationState::NotFound),
            })
        }
        Err(_) => {
            return Ok(IntegrationStatus {
                state: IntegrationState::Broken,
                checked_at_ms,
                payload_available: true,
                plugin_enabled: false,
                agents_integrated,
                payload_catalog_sha256,
                build_catalog_sha256,
                install_manifest_sha256,
                agents_block_sha256,
                cli_version: None,
                installed_version: None,
                desired_version,
                active_runtime: None,
                message: "The detected Codex CLI could not be started.",
            })
        }
    };
    let cli_version = Some(cli.version.clone());
    let registration = match plugin_registration(&cli.path) {
        Ok(value) => value,
        Err(_) => {
            return Ok(IntegrationStatus {
                state: IntegrationState::Broken,
                checked_at_ms,
                payload_available: true,
                plugin_enabled: false,
                agents_integrated,
                payload_catalog_sha256,
                build_catalog_sha256,
                install_manifest_sha256,
                agents_block_sha256,
                cli_version,
                installed_version: None,
                desired_version,
                active_runtime: None,
                message: "The detected Codex CLI did not return valid plugin status.",
            })
        }
    };
    let Some(registration) = registration else {
        let state = IntegrationState::NotInstalled;
        return Ok(IntegrationStatus {
            state,
            checked_at_ms,
            payload_available: true,
            plugin_enabled: false,
            agents_integrated,
            payload_catalog_sha256,
            build_catalog_sha256,
            install_manifest_sha256,
            agents_block_sha256,
            cli_version,
            installed_version: None,
            desired_version,
            active_runtime: None,
            message: status_message(state),
        });
    };
    let (state, active_runtime) = if !registration.enabled {
        (IntegrationState::Broken, None)
    } else if desired_version.as_deref() != Some(registration.version.as_str()) {
        (IntegrationState::VersionMismatch, None)
    } else if validate_installed_plugin(&registration).is_none() || !agents_integrated {
        (IntegrationState::Broken, None)
    } else {
        status_from_receipts(inner, &registration.version)
    };
    Ok(IntegrationStatus {
        state,
        checked_at_ms,
        payload_available: true,
        plugin_enabled: registration.enabled,
        agents_integrated,
        payload_catalog_sha256,
        build_catalog_sha256,
        install_manifest_sha256,
        agents_block_sha256,
        cli_version,
        installed_version: Some(registration.version),
        desired_version,
        active_runtime,
        message: status_message(state),
    })
}

fn step(id: &'static str, passed: bool, message: &'static str) -> IntegrationStep {
    IntegrationStep {
        id,
        passed,
        message,
    }
}

trait MarketplaceCommandExecutor {
    fn remove_owned(&mut self) -> Result<bool, IntegrationError>;
    fn add_local(&mut self, root: &Path) -> Result<bool, IntegrationError>;
}

struct CliMarketplaceExecutor<'a> {
    cli: &'a Path,
}

impl MarketplaceCommandExecutor for CliMarketplaceExecutor<'_> {
    fn remove_owned(&mut self) -> Result<bool, IntegrationError> {
        let output = run_process(
            self.cli,
            &[
                OsStr::new("plugin"),
                OsStr::new("marketplace"),
                OsStr::new("remove"),
                OsStr::new(MARKETPLACE_NAME),
            ],
            CODEX_TIMEOUT,
        )?;
        Ok(output.status.success())
    }

    fn add_local(&mut self, root: &Path) -> Result<bool, IntegrationError> {
        let output = run_process(
            self.cli,
            &[
                OsStr::new("plugin"),
                OsStr::new("marketplace"),
                OsStr::new("add"),
                root.as_os_str(),
                OsStr::new("--json"),
            ],
            CODEX_TIMEOUT,
        )?;
        Ok(output.status.success())
    }
}

#[derive(Debug)]
struct MarketplaceSwitch {
    changed: bool,
    previous_owned_root: Option<PathBuf>,
}

fn restore_marketplace<E: MarketplaceCommandExecutor>(
    executor: &mut E,
    switch: &MarketplaceSwitch,
) {
    if !switch.changed {
        return;
    }
    // A failed `add` can still have written partial state. Remove the fixed
    // owned name before attempting to put the validated old registration back.
    let _ = executor.remove_owned();
    if let Some(previous) = switch.previous_owned_root.as_deref() {
        let _ = executor.add_local(previous);
    }
}

fn switch_marketplace<E: MarketplaceCommandExecutor>(
    executor: &mut E,
    current: Option<&Path>,
    desired: &Path,
) -> Result<MarketplaceSwitch, IntegrationError> {
    if current.is_some_and(|root| same_path(root, desired)) {
        return Ok(MarketplaceSwitch {
            changed: false,
            previous_owned_root: None,
        });
    }

    let previous_owned_root = current.and_then(validate_owned_marketplace_root);
    let switch = MarketplaceSwitch {
        changed: true,
        previous_owned_root,
    };
    if current.is_some() && !executor.remove_owned()? {
        return Err(IntegrationError::MarketplaceInstallFailed);
    }
    match executor.add_local(desired) {
        Ok(true) => Ok(switch),
        Ok(false) => {
            restore_marketplace(executor, &switch);
            Err(IntegrationError::MarketplaceInstallFailed)
        }
        Err(error) => {
            restore_marketplace(executor, &switch);
            Err(error)
        }
    }
}

fn best_effort_restore_plugin(
    cli: &Path,
    marketplace: &mut impl MarketplaceCommandExecutor,
    switch: &MarketplaceSwitch,
) {
    restore_marketplace(marketplace, switch);
    if switch.previous_owned_root.is_some() {
        let _ = run_process(
            cli,
            &[
                OsStr::new("plugin"),
                OsStr::new("add"),
                OsStr::new(PLUGIN_ID),
                OsStr::new("--json"),
            ],
            CODEX_TIMEOUT,
        );
    }
}

fn integration_action_flags(
    runtime_build_changed: bool,
    agents_status: CodexOnlyStatus,
    status_state: IntegrationState,
    runtime_was_connected: bool,
) -> (bool, bool) {
    let changed = runtime_build_changed || agents_status != CodexOnlyStatus::Unchanged;
    let restart_required = status_state == IntegrationState::RestartRequired
        || (runtime_build_changed && !runtime_was_connected);
    (changed, restart_required)
}

fn install_or_repair(
    inner: &IntegrationManagerInner,
) -> Result<IntegrationActionResult, IntegrationError> {
    // This is the mutation gate: the entire installed marketplace must match
    // the manifest one-for-one before any Codex CLI command can change state.
    let (payload, initial_integrity) = locate_verified_payload(inner)?;
    let cli = discover_codex_cli()?.ok_or(IntegrationError::CodexNotFound)?;
    let mut steps = vec![step("codex_cli", true, "Codex CLI detected")];

    let old_marketplace = registered_marketplace_root(&cli.path)?;
    let existing_registration = plugin_registration(&cli.path)?;
    let plugin_already_exact = old_marketplace
        .as_deref()
        .is_some_and(|root| same_path(root, &payload.marketplace_root))
        && existing_registration.as_ref().is_some_and(|registration| {
            registration.enabled
                && registration.version == payload.desired_version
                && same_path(&registration.source_path, &payload.plugin_root)
                && validate_installed_plugin(registration).is_some()
        });
    let runtime_was_connected = plugin_already_exact
        && state_from_receipts(inner, &payload.desired_version) == IntegrationState::Connected;
    let mut marketplace = CliMarketplaceExecutor { cli: &cli.path };
    let marketplace_switch = switch_marketplace(
        &mut marketplace,
        old_marketplace.as_deref(),
        &payload.marketplace_root,
    )?;
    steps.push(step(
        "marketplace",
        true,
        "Local ClusterYourCodex marketplace registered",
    ));

    if !plugin_already_exact {
        let output = match run_process(
            &cli.path,
            &[
                OsStr::new("plugin"),
                OsStr::new("add"),
                OsStr::new(PLUGIN_ID),
                OsStr::new("--json"),
            ],
            CODEX_TIMEOUT,
        ) {
            Ok(output) => output,
            Err(error) => {
                best_effort_restore_plugin(&cli.path, &mut marketplace, &marketplace_switch);
                return Err(error);
            }
        };
        if !output.status.success() {
            best_effort_restore_plugin(&cli.path, &mut marketplace, &marketplace_switch);
            return Err(IntegrationError::PluginInstallFailed);
        }
    }
    let registration = match plugin_registration(&cli.path) {
        Ok(Some(registration)) => registration,
        _ => {
            best_effort_restore_plugin(&cli.path, &mut marketplace, &marketplace_switch);
            return Err(IntegrationError::PluginInstallFailed);
        }
    };
    if !registration.enabled
        || registration.version != payload.desired_version
        || !same_path(&registration.source_path, &payload.plugin_root)
        || validate_installed_plugin(&registration).is_none()
    {
        best_effort_restore_plugin(&cli.path, &mut marketplace, &marketplace_switch);
        return Err(IntegrationError::PluginInstallFailed);
    }
    steps.push(step(
        "plugin",
        true,
        "ClusterYourCodex plugin installed and enabled",
    ));

    let current_integrity = load_verified_install(inner)?;
    if current_integrity.build_catalog_sha256 != initial_integrity.build_catalog_sha256
        || current_integrity.payload_catalog_sha256 != initial_integrity.payload_catalog_sha256
    {
        best_effort_restore_plugin(&cli.path, &mut marketplace, &marketplace_switch);
        return Err(IntegrationError::PayloadUnavailable);
    }
    let agents_receipt = integrate_global_agents(inner, &payload.desired_version, &cli.path)?;
    steps.push(step(
        "global_agents",
        true,
        "Global AGENTS.md cluster routing installed",
    ));

    let restart_path = restart_receipt_path(inner);
    let runtime_build_changed = marketplace_switch.changed || !plugin_already_exact;
    if runtime_build_changed {
        let _ = std::fs::remove_file(health_receipt_path(inner));
        write_atomic_json(
            &restart_path,
            &RestartReceipt {
                installed_at_ms: now_ms()?,
            },
        )?;
    }
    let status = collect_status(inner)?;
    let (state_changed, restart_required) = integration_action_flags(
        runtime_build_changed,
        agents_receipt.status,
        status.state,
        runtime_was_connected,
    );
    Ok(IntegrationActionResult {
        changed: state_changed,
        restart_required,
        steps,
        status,
    })
}

fn terminate_child(child: &mut Child) {
    if child.try_wait().ok().flatten().is_none() {
        let _ = child.kill();
    }
    let _ = child.wait();
}

fn verified_installed_plugin(
    inner: &IntegrationManagerInner,
) -> Result<InstalledPlugin, IntegrationError> {
    let (payload, integrity) = locate_verified_payload(inner)?;
    let codex_home = resolve_codex_home()?;
    verify_agents_integration(&integrity, &codex_home)?;
    let cli = discover_codex_cli()?.ok_or(IntegrationError::CodexNotFound)?;
    let registration = plugin_registration(&cli.path)?
        .filter(|registration| {
            registration.enabled
                && registration.version == payload.desired_version
                && same_path(&registration.source_path, &payload.plugin_root)
        })
        .ok_or(IntegrationError::PluginInstallFailed)?;
    validate_installed_plugin(&registration).ok_or(IntegrationError::PluginInstallFailed)
}

fn strict_mcp_result(
    receiver: &mpsc::Receiver<String>,
    id: u64,
    deadline: Instant,
) -> Result<Value, IntegrationError> {
    loop {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .ok_or(IntegrationError::McpSelfTestFailed)?;
        let line = receiver
            .recv_timeout(remaining)
            .map_err(|_| IntegrationError::McpSelfTestFailed)?;
        if line.is_empty() || line.len() > 1024 * 1024 || line.contains('\0') {
            return Err(IntegrationError::McpSelfTestFailed);
        }
        let value: Value =
            serde_json::from_str(&line).map_err(|_| IntegrationError::McpSelfTestFailed)?;
        let object = value
            .as_object()
            .ok_or(IntegrationError::McpSelfTestFailed)?;
        if object.get("id").is_none() {
            // MCP servers may emit notifications, but only well-formed 2.0
            // notifications are ignored while waiting for the one request.
            if object.get("jsonrpc").and_then(Value::as_str) != Some("2.0")
                || object.get("method").and_then(Value::as_str).is_none()
            {
                return Err(IntegrationError::McpSelfTestFailed);
            }
            continue;
        }
        if object.get("jsonrpc").and_then(Value::as_str) != Some("2.0")
            || object.get("id").and_then(Value::as_u64) != Some(id)
            || object.contains_key("error")
            || object.len() != 3
            || !object.contains_key("result")
        {
            return Err(IntegrationError::McpSelfTestFailed);
        }
        return object
            .get("result")
            .cloned()
            .ok_or(IntegrationError::McpSelfTestFailed);
    }
}

fn parse_strict_tool_payload(result: Value) -> Result<Value, IntegrationError> {
    let result = result
        .as_object()
        .ok_or(IntegrationError::McpSelfTestFailed)?;
    if result.len() != 1 || result.contains_key("isError") {
        return Err(IntegrationError::McpSelfTestFailed);
    }
    let content = result
        .get("content")
        .and_then(Value::as_array)
        .filter(|content| content.len() == 1)
        .ok_or(IntegrationError::McpSelfTestFailed)?;
    let item = content[0]
        .as_object()
        .ok_or(IntegrationError::McpSelfTestFailed)?;
    if item.len() != 2 || item.get("type").and_then(Value::as_str) != Some("text") {
        return Err(IntegrationError::McpSelfTestFailed);
    }
    let text = item
        .get("text")
        .and_then(Value::as_str)
        .filter(|text| {
            !text.is_empty()
                && text.len() <= MAX_PROCESS_OUTPUT
                && !text.contains('\0')
                && text.trim() == *text
        })
        .ok_or(IntegrationError::McpSelfTestFailed)?;
    let payload: Value =
        serde_json::from_str(text).map_err(|_| IntegrationError::McpSelfTestFailed)?;
    if !payload.is_object() {
        return Err(IntegrationError::McpSelfTestFailed);
    }
    Ok(payload)
}

pub(crate) struct McpSession {
    child: Child,
    stdin: Option<ChildStdin>,
    receiver: mpsc::Receiver<String>,
    reader: Option<thread::JoinHandle<()>>,
    next_id: u64,
    deadline: Instant,
    identity: SelfTestExecutorIdentity,
}

impl McpSession {
    fn start(
        inner: &IntegrationManagerInner,
        installed: &InstalledPlugin,
        total_timeout: Duration,
    ) -> Result<Self, IntegrationError> {
        if total_timeout.is_zero() || !inner.token_file.is_file() {
            return Err(IntegrationError::McpStartFailed);
        }
        let deadline = Instant::now()
            .checked_add(total_timeout)
            .ok_or(IntegrationError::McpStartFailed)?;
        let session_id = Uuid::new_v4();
        let started_at = Utc::now();
        let mut child = Command::new(&installed.runtime)
            .arg(&installed.server)
            .current_dir(&installed.root)
            .env("CYC_CONTROLLER_TOKEN_FILE", &inner.token_file)
            .env("CYC_MCP_SELF_TEST", "1")
            .env("CYC_MCP_SELF_TEST_SESSION_ID", session_id.to_string())
            .env("CLUSTERYOURCODEX_CONTROLLER_URL", "http://127.0.0.1:47831")
            .env_remove("CYC_MCP_ACTIVE_RECEIPT_FILE")
            .env_remove("NODE_OPTIONS")
            .env_remove("NODE_PATH")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|_| IntegrationError::McpStartFailed)?;
        let pid = child.id();
        if pid == 0 {
            terminate_child(&mut child);
            return Err(IntegrationError::McpStartFailed);
        }
        let stdin = child.stdin.take().ok_or(IntegrationError::McpStartFailed)?;
        let stdout = child
            .stdout
            .take()
            .ok_or(IntegrationError::McpStartFailed)?;
        let (sender, receiver) = mpsc::sync_channel::<String>(32);
        let reader = thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                if sender.send(line).is_err() {
                    break;
                }
            }
        });
        let mut session = Self {
            child,
            stdin: Some(stdin),
            receiver,
            reader: Some(reader),
            next_id: 1,
            deadline,
            identity: SelfTestExecutorIdentity {
                pid,
                started_at,
                bridge_version: installed.version.clone(),
                session_id,
            },
        };
        let initialize_id = session.allocate_id()?;
        session.send(json!({
            "jsonrpc": "2.0",
            "id": initialize_id,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "clusteryourcodex-desktop-native", "version": env!("CARGO_PKG_VERSION")}
            }
        }))?;
        let initialized = strict_mcp_result(&session.receiver, initialize_id, session.deadline)?;
        if initialized
            .get("serverInfo")
            .and_then(|value| value.get("name"))
            .and_then(Value::as_str)
            != Some("cluster-your-codex")
            || initialized
                .get("serverInfo")
                .and_then(|value| value.get("version"))
                .and_then(Value::as_str)
                != Some(installed.version.as_str())
        {
            return Err(IntegrationError::McpSelfTestFailed);
        }
        session.send(json!({
            "jsonrpc":"2.0",
            "method":"notifications/initialized",
            "params":{}
        }))?;
        let list_id = session.allocate_id()?;
        session.send(json!({"jsonrpc":"2.0","id":list_id,"method":"tools/list","params":{}}))?;
        let listed = strict_mcp_result(&session.receiver, list_id, session.deadline)?;
        let tools = listed
            .get("tools")
            .and_then(Value::as_array)
            .ok_or(IntegrationError::McpSelfTestFailed)?;
        let mut names = BTreeSet::new();
        for tool in tools {
            let name = tool
                .as_object()
                .and_then(|tool| tool.get("name"))
                .and_then(Value::as_str)
                .ok_or(IntegrationError::McpSelfTestFailed)?;
            if !names.insert(name) {
                return Err(IntegrationError::McpSelfTestFailed);
            }
        }
        let expected = BTreeSet::from([
            "fleet_cancel",
            "fleet_info",
            "fleet_job",
            "fleet_plan",
            "fleet_plan_submit",
            "fleet_snapshot_upload",
            "fleet_submit",
            "workspace_snapshot_pack",
        ]);
        if names != expected {
            return Err(IntegrationError::McpSelfTestFailed);
        }
        Ok(session)
    }

    pub(crate) fn executor_identity(&self) -> &SelfTestExecutorIdentity {
        &self.identity
    }

    fn allocate_id(&mut self) -> Result<u64, IntegrationError> {
        let id = self.next_id;
        self.next_id = self
            .next_id
            .checked_add(1)
            .ok_or(IntegrationError::McpSelfTestFailed)?;
        Ok(id)
    }

    fn send(&mut self, value: Value) -> Result<(), IntegrationError> {
        let stdin = self
            .stdin
            .as_mut()
            .ok_or(IntegrationError::McpSelfTestFailed)?;
        send_mcp(stdin, value)
    }

    pub(crate) fn call_tool(
        &mut self,
        name: &str,
        arguments: Value,
        timeout: Duration,
    ) -> Result<Value, IntegrationError> {
        const TOOL_NAMES: [&str; 8] = [
            "fleet_cancel",
            "fleet_info",
            "fleet_job",
            "fleet_plan",
            "fleet_plan_submit",
            "fleet_snapshot_upload",
            "fleet_submit",
            "workspace_snapshot_pack",
        ];
        if timeout.is_zero() || TOOL_NAMES.binary_search(&name).is_err() || !arguments.is_object() {
            return Err(IntegrationError::McpSelfTestFailed);
        }
        let call_deadline = Instant::now()
            .checked_add(timeout)
            .map(|deadline| deadline.min(self.deadline))
            .ok_or(IntegrationError::McpSelfTestFailed)?;
        if call_deadline <= Instant::now() {
            return Err(IntegrationError::McpSelfTestFailed);
        }
        let id = self.allocate_id()?;
        self.send(json!({
            "jsonrpc":"2.0",
            "id":id,
            "method":"tools/call",
            "params":{"name":name,"arguments":arguments}
        }))?;
        let result = strict_mcp_result(&self.receiver, id, call_deadline)?;
        parse_strict_tool_payload(result)
    }
}

impl Drop for McpSession {
    fn drop(&mut self) {
        self.stdin.take();
        terminate_child(&mut self.child);
        if let Some(reader) = self.reader.take() {
            let _ = reader.join();
        }
    }
}

fn send_mcp(stdin: &mut impl Write, value: Value) -> Result<(), IntegrationError> {
    serde_json::to_writer(&mut *stdin, &value).map_err(|_| IntegrationError::McpSelfTestFailed)?;
    stdin
        .write_all(b"\n")
        .and_then(|_| stdin.flush())
        .map_err(|_| IntegrationError::McpSelfTestFailed)
}

fn run_mcp_probe(
    inner: &IntegrationManagerInner,
    installed: &InstalledPlugin,
) -> Result<(Vec<IntegrationStep>, SelfTestExecutorIdentity), IntegrationError> {
    let mut session = McpSession::start(inner, installed, MCP_TIMEOUT)?;
    let fleet = session.call_tool("fleet_info", json!({}), MCP_TIMEOUT)?;
    if fleet.get("health").is_none() || fleet.get("fleet").is_none() {
        return Err(IntegrationError::McpSelfTestFailed);
    }
    let executor = session.executor_identity().clone();
    Ok((
        vec![
            step(
                "mcp_initialize",
                true,
                "Isolated installed-MCP executor completed initialize",
            ),
            step(
                "tools_list",
                true,
                "Isolated installed-MCP executor listed all eight cluster tools",
            ),
            step(
                "controller_round_trip",
                true,
                "Isolated installed-MCP executor reached the authenticated local controller",
            ),
        ],
        executor,
    ))
}

fn run_self_test(
    inner: &IntegrationManagerInner,
) -> Result<IntegrationSelfTestResult, IntegrationError> {
    let started = Instant::now();
    let before = collect_status(inner)?;
    let restart_recommended = before.state == IntegrationState::RestartRequired;
    let eligible = matches!(
        before.state,
        IntegrationState::Installed
            | IntegrationState::RestartRequired
            | IntegrationState::Connected
            | IntegrationState::Stale
            | IntegrationState::Broken
    ) && before.plugin_enabled
        && before.agents_integrated
        && before.installed_version == before.desired_version;
    let mut checks = Vec::new();
    if !eligible {
        checks.push(step(
            "plugin_registration",
            false,
            "Install or repair the plugin before running the connection check",
        ));
        return Ok(IntegrationSelfTestResult {
            passed: false,
            duration_ms: started.elapsed().as_millis() as u64,
            restart_recommended,
            checks,
            self_test_executor: None,
            status: before,
        });
    }
    checks.push(step(
        "plugin_registration",
        true,
        "Plugin registration and version are valid",
    ));
    let integrity_valid = locate_verified_payload(inner)
        .ok()
        .and_then(|(_, integrity)| {
            resolve_codex_home()
                .ok()
                .and_then(|home| verify_agents_integration(&integrity, &home).ok())
        })
        .is_some();
    if !integrity_valid {
        checks.push(step(
            "integration_integrity",
            false,
            "The payload catalog or global AGENTS.md evidence drifted",
        ));
        let status = collect_status(inner).unwrap_or(before);
        return Ok(IntegrationSelfTestResult {
            passed: false,
            duration_ms: started.elapsed().as_millis() as u64,
            restart_recommended,
            checks,
            self_test_executor: None,
            status,
        });
    }
    checks.push(step(
        "integration_integrity",
        true,
        "Payload catalog and global AGENTS.md evidence are intact",
    ));
    let installed = discover_codex_cli()
        .ok()
        .flatten()
        .and_then(|cli| plugin_registration(&cli.path).ok().flatten())
        .filter(|registration| {
            registration.enabled
                && before.installed_version.as_deref() == Some(registration.version.as_str())
                && before.desired_version.as_deref() == Some(registration.version.as_str())
        })
        .and_then(|registration| validate_installed_plugin(&registration));
    let Some(installed) = installed else {
        checks.push(step(
            "installed_source",
            false,
            "The installed plugin source or MCP runtime is damaged",
        ));
        let status = collect_status(inner).unwrap_or(before);
        return Ok(IntegrationSelfTestResult {
            passed: false,
            duration_ms: started.elapsed().as_millis() as u64,
            restart_recommended,
            checks,
            self_test_executor: None,
            status,
        });
    };
    checks.push(step(
        "installed_source",
        true,
        "Installed plugin manifest, bridge, and runtime are valid",
    ));
    let (probe_passed, self_test_executor) = match run_mcp_probe(inner, &installed) {
        Ok((mut probe_checks, executor)) => {
            checks.append(&mut probe_checks);
            let receipt = HealthReceipt {
                checked_at_ms: now_ms()?,
                passed: true,
                failed_check: None,
            };
            write_atomic_json(&health_receipt_path(inner), &receipt)?;
            (true, Some(executor))
        }
        Err(_) => {
            checks.push(step(
                "mcp_runtime",
                false,
                "The MCP bridge did not complete the controller round trip",
            ));
            let receipt = HealthReceipt {
                checked_at_ms: now_ms()?,
                passed: false,
                failed_check: Some("mcp_runtime".to_owned()),
            };
            write_atomic_json(&health_receipt_path(inner), &receipt)?;
            (false, None)
        }
    };
    let status = collect_status(inner)?;
    Ok(IntegrationSelfTestResult {
        passed: probe_passed,
        duration_ms: started.elapsed().as_millis() as u64,
        restart_recommended,
        checks,
        self_test_executor,
        status,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture_root(label: &str) -> PathBuf {
        std::env::temp_dir().join(format!("cyc-integration-{label}-{}", unique_state_suffix()))
    }

    fn registration_json(source_path: &Path) -> Value {
        json!({
            "pluginId": PLUGIN_ID,
            "name": "cluster-your-codex",
            "marketplaceName": MARKETPLACE_NAME,
            "version": "0.1.0",
            "installed": true,
            "enabled": true,
            "source": {
                "source": "local",
                "path": source_path,
            },
            "marketplaceSource": {
                "sourceType": "local",
                "source": source_path.parent().unwrap_or(source_path),
            },
        })
    }

    fn write_plugin_fixture(plugin: &Path, version: &str) {
        std::fs::create_dir_all(plugin.join(".codex-plugin")).unwrap();
        std::fs::create_dir_all(plugin.join("mcp/dist")).unwrap();
        std::fs::create_dir_all(plugin.join("mcp/runtime")).unwrap();
        std::fs::write(
            plugin.join(".codex-plugin/plugin.json"),
            serde_json::to_vec(&json!({
                "name": "cluster-your-codex",
                "version": version,
            }))
            .unwrap(),
        )
        .unwrap();
        let runtime_command = if cfg!(target_os = "windows") {
            "./mcp/runtime/node.exe"
        } else {
            "./mcp/runtime/node"
        };
        std::fs::write(
            plugin.join(".mcp.json"),
            serde_json::to_vec(&json!({
                "mcpServers": {
                    "cluster_your_codex": {
                        "command": runtime_command,
                        "args": ["./mcp/dist/server.js"],
                        "cwd": ".",
                        "env_vars": ["CYC_CONTROLLER_TOKEN_FILE"],
                    }
                }
            }))
            .unwrap(),
        )
        .unwrap();
        std::fs::write(plugin.join("mcp/dist/server.js"), "// fixture").unwrap();
        let runtime = plugin.join("mcp/runtime").join(executable_name("node"));
        std::fs::write(&runtime, "fixture runtime").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut permissions = std::fs::metadata(&runtime).unwrap().permissions();
            permissions.set_mode(0o700);
            std::fs::set_permissions(&runtime, permissions).unwrap();
        }
    }

    fn write_marketplace_fixture(root: &Path, version: &str) -> PathBuf {
        let plugin = root.join("plugins/cluster-your-codex");
        std::fs::create_dir_all(root.join(".agents/plugins")).unwrap();
        write_plugin_fixture(&plugin, version);
        std::fs::write(
            root.join(".agents/plugins/marketplace.json"),
            serde_json::to_vec(&json!({
                "name": MARKETPLACE_NAME,
                "plugins": [{
                    "name": "cluster-your-codex",
                    "source": {
                        "source": "local",
                        "path": "./plugins/cluster-your-codex",
                    }
                }]
            }))
            .unwrap(),
        )
        .unwrap();
        plugin
    }

    #[test]
    fn cli_candidate_probe_skips_unstartable_aliases_and_ranks_real_versions() {
        let root = fixture_root("cli-candidates");
        let blocked = root.join("blocked").join(executable_name("codex"));
        let older = root.join("older").join(executable_name("codex"));
        let newer = root.join("newer").join(executable_name("codex"));
        for candidate in [&blocked, &older, &newer] {
            std::fs::create_dir_all(candidate.parent().unwrap()).unwrap();
            std::fs::write(candidate, "fixture").unwrap();
        }

        let mut saw_candidate = false;
        let mut probe = |candidate: &Path| match candidate
            .parent()
            .and_then(Path::file_name)
            .and_then(OsStr::to_str)
        {
            Some("blocked") => None,
            Some("older") => Some("codex-cli 0.9.0".to_owned()),
            Some("newer") => Some("codex-cli 0.10.0".to_owned()),
            _ => None,
        };
        let probed = probe_codex_cli_candidates(
            vec![blocked, older, newer.clone()],
            &mut saw_candidate,
            &mut probe,
        );
        assert!(saw_candidate);
        assert_eq!(
            probed.len(),
            2,
            "the simulated access-denied alias is skipped"
        );
        let selected = best_versioned_codex_cli(probed).expect("runnable CLI");
        assert_eq!(selected.path, newer.canonicalize().unwrap());

        let old_mtime = DiscoveredCodexCli {
            path: root.join("same-old"),
            version: "codex-cli 1.2.3".to_owned(),
            modified_at: UNIX_EPOCH + Duration::from_secs(10),
        };
        let new_mtime = DiscoveredCodexCli {
            path: root.join("same-new"),
            version: "codex-cli 1.2.3".to_owned(),
            modified_at: UNIX_EPOCH + Duration::from_secs(20),
        };
        assert_eq!(
            best_versioned_codex_cli(vec![old_mtime, new_mtime.clone()])
                .expect("mtime tiebreak")
                .path,
            new_mtime.path
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn parses_only_the_owned_plugin_registration() {
        let source_path = fixture_root("registration");
        let bytes = serde_json::to_vec(&json!({
            "installed": [
                {"pluginId":"other@market","version":"9","enabled":true},
                registration_json(&source_path),
            ]
        }))
        .unwrap();
        let registration = parse_plugin_registration(&bytes).unwrap().unwrap();
        assert_eq!(registration.version, "0.1.0");
        assert!(registration.enabled);
        assert_eq!(registration.source_path, source_path);
    }

    #[test]
    fn rejects_malformed_plugin_status_instead_of_guessing() {
        let source_path = fixture_root("malformed-registration");
        let mut missing_source = registration_json(&source_path);
        missing_source.as_object_mut().unwrap().remove("source");
        for bytes in [
            serde_json::to_vec(&json!({})).unwrap(),
            serde_json::to_vec(&json!({"installed":"yes"})).unwrap(),
            serde_json::to_vec(&json!({"installed":[missing_source]})).unwrap(),
        ] {
            assert!(parse_plugin_registration(&bytes).is_err());
        }
    }

    #[test]
    fn exact_plugin_id_is_required() {
        let bytes = br#"{"installed":[{"pluginId":"cluster-your-codex@evil","version":"0.1.0","enabled":true}]}"#;
        assert!(parse_plugin_registration(bytes).unwrap().is_none());
    }

    #[test]
    fn owned_plugin_must_have_an_absolute_local_source() {
        let mut remote = registration_json(&fixture_root("remote-registration"));
        remote["source"]["source"] = json!("git");
        let remote = serde_json::to_vec(&json!({"installed":[remote]})).unwrap();
        assert!(parse_plugin_registration(&remote).is_err());

        let mut relative = registration_json(&fixture_root("relative-registration"));
        relative["source"]["path"] = json!("./plugin");
        let relative = serde_json::to_vec(&json!({"installed":[relative]})).unwrap();
        assert!(parse_plugin_registration(&relative).is_err());
    }

    #[test]
    fn state_messages_cover_every_public_state() {
        for state in [
            IntegrationState::NotFound,
            IntegrationState::NotInstalled,
            IntegrationState::Installed,
            IntegrationState::RestartRequired,
            IntegrationState::Connected,
            IntegrationState::Stale,
            IntegrationState::Broken,
            IntegrationState::VersionMismatch,
        ] {
            assert!(!status_message(state).is_empty());
        }
    }

    #[test]
    fn complete_payload_fixture_is_accepted() {
        let root = fixture_root("payload");
        let plugin = write_marketplace_fixture(&root, "0.1.0");

        let payload = validate_payload_root(&root).unwrap();
        assert_eq!(payload.desired_version, "0.1.0");
        assert_eq!(payload.plugin_root, plugin);
        std::fs::remove_dir_all(root).unwrap();
    }

    fn receipt_integrity() -> VerifiedInstall {
        VerifiedInstall {
            install_root: fixture_root("receipt-install"),
            data_root: fixture_root("receipt-data"),
            manifest_sha256: "d".repeat(64),
            build_catalog_sha256: "c".repeat(64),
            payload_catalog_sha256: "b".repeat(64),
            files: BTreeMap::new(),
            agents_integration: None,
        }
    }

    fn codex_only_receipt_bytes(status: &str) -> Vec<u8> {
        format!(
            "{{\"schemaVersion\":\"{CODEX_ONLY_RECEIPT_SCHEMA}\",\"status\":\"{status}\",\"pluginId\":\"{PLUGIN_ID}\",\"pluginVersion\":\"0.1.0\",\"agentsBlockSha256\":\"{}\",\"payloadCatalogSha256\":\"{}\",\"buildCatalogSha256\":\"{}\",\"installManifestSha256\":\"{}\",\"agentsFileSha256\":\"{}\",\"agentsExternalSha256\":\"{}\",\"agentsOwnedRangeSha256\":\"{}\"}}\r\n",
            "a".repeat(64),
            "b".repeat(64),
            "c".repeat(64),
            "d".repeat(64),
            "e".repeat(64),
            "f".repeat(64),
            "1".repeat(64),
        )
        .into_bytes()
    }

    #[test]
    fn codex_only_receipt_accepts_only_the_exact_bounded_schema() {
        let integrity = receipt_integrity();
        for status in ["installed", "repaired", "unchanged"] {
            let parsed =
                parse_codex_only_receipt(&codex_only_receipt_bytes(status), "0.1.0", &integrity)
                    .expect("valid receipt");
            assert_eq!(parsed.plugin_id, PLUGIN_ID);
            assert_eq!(parsed.plugin_version, "0.1.0");
        }

        let mut extra: Value =
            serde_json::from_slice(&codex_only_receipt_bytes("installed")).unwrap();
        extra["unexpected"] = json!(true);
        assert!(parse_codex_only_receipt(
            &serde_json::to_vec(&extra).unwrap(),
            "0.1.0",
            &integrity,
        )
        .is_err());

        let cases = [
            b"\n".to_vec(),
            [codex_only_receipt_bytes("installed"), b"second\n".to_vec()].concat(),
            b" {\"schemaVersion\":\"bad\"}".to_vec(),
            vec![0xff, 0xfe],
            vec![b'x'; MAX_CODEX_ONLY_RECEIPT + 1],
        ];
        for bytes in cases {
            assert!(parse_codex_only_receipt(&bytes, "0.1.0", &integrity).is_err());
        }

        let mut wrong_version: Value =
            serde_json::from_slice(&codex_only_receipt_bytes("installed")).unwrap();
        wrong_version["pluginVersion"] = json!("0.2.0");
        assert!(parse_codex_only_receipt(
            &serde_json::to_vec(&wrong_version).unwrap(),
            "0.1.0",
            &integrity,
        )
        .is_err());
        wrong_version["pluginVersion"] = json!("0.1.0");
        wrong_version["agentsBlockSha256"] = json!("A".repeat(64));
        assert!(parse_codex_only_receipt(
            &serde_json::to_vec(&wrong_version).unwrap(),
            "0.1.0",
            &integrity,
        )
        .is_err());
    }

    fn collect_file_receipts(
        root: &Path,
        directory: &Path,
        receipts: &mut Vec<InstalledFileReceipt>,
    ) {
        for entry in std::fs::read_dir(directory).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                collect_file_receipts(root, &path, receipts);
            } else {
                let relative_path = path
                    .strip_prefix(root)
                    .unwrap()
                    .components()
                    .map(|component| component.as_os_str().to_str().unwrap())
                    .collect::<Vec<_>>()
                    .join("/");
                receipts.push(InstalledFileReceipt {
                    relative_path,
                    sha256: sha256_file(&path).unwrap(),
                    length: std::fs::metadata(path).unwrap().len(),
                });
            }
        }
    }

    fn install_catalog_fixture(root: &Path) -> (PathBuf, PathBuf, Vec<InstalledFileReceipt>) {
        let install = root.join("install");
        let data = root.join("data");
        std::fs::create_dir_all(&data).unwrap();
        let marketplace = install.join(CODEX_MARKETPLACE_RELATIVE_ROOT);
        write_marketplace_fixture(&marketplace, "0.1.0");
        std::fs::create_dir_all(install.join("installer")).unwrap();
        std::fs::write(install.join(INSTALLED_BOOTSTRAP_RELATIVE_PATH), b"safe").unwrap();
        let mut receipts = Vec::new();
        collect_file_receipts(&install, &install, &mut receipts);
        (install, data, receipts)
    }

    fn install_manifest_value(
        install: &Path,
        data: &Path,
        receipts: &[InstalledFileReceipt],
    ) -> Value {
        let build_digest = catalog_digest(receipts.iter());
        let payload_digest = catalog_digest(
            receipts
                .iter()
                .filter(|receipt| receipt.relative_path.starts_with(CODEX_MARKETPLACE_PREFIX)),
        );
        json!({
            "schemaVersion": INSTALL_MANIFEST_SCHEMA,
            "installRoot": install,
            "dataRoot": data,
            "buildCatalogSha256": build_digest,
            "codexPayloadCatalogSha256": payload_digest,
            "files": receipts,
        })
    }

    #[test]
    fn install_manifest_size_gate_matches_the_self_contained_package_capacity() {
        assert!(!install_manifest_size_is_supported(0));
        assert!(!install_manifest_size_is_supported(1));
        assert!(install_manifest_size_is_supported(2));
        assert!(install_manifest_size_is_supported(2 * 1024 * 1024 + 1));
        assert!(install_manifest_size_is_supported(MAX_INSTALL_MANIFEST));
        assert!(!install_manifest_size_is_supported(
            MAX_INSTALL_MANIFEST + 1
        ));
    }

    #[test]
    fn install_manifest_binds_bootstrap_to_exact_install_and_data_roots() {
        let root = fixture_root("bootstrap-manifest");
        let (install, data, receipts) = install_catalog_fixture(&root);
        let build_digest = catalog_digest(receipts.iter());
        let payload_digest = catalog_digest(
            receipts
                .iter()
                .filter(|receipt| receipt.relative_path.starts_with(CODEX_MARKETPLACE_PREFIX)),
        );
        let manifest = json!({
            "schemaVersion": INSTALL_MANIFEST_SCHEMA,
            "installRoot": install,
            "dataRoot": data,
            "buildCatalogSha256": build_digest,
            "codexPayloadCatalogSha256": payload_digest,
            "files": receipts,
            "futureField": {"isAllowed": true},
        });
        let parsed = validate_install_manifest(
            &serde_json::to_vec(&manifest).unwrap(),
            &root.join("install"),
            &root.join("data"),
        )
        .expect("valid installed payload catalog");
        assert_eq!(parsed.build_catalog_sha256, build_digest);
        assert_eq!(parsed.payload_catalog_sha256, payload_digest);

        let mut duplicate = manifest.clone();
        let duplicate_entry = duplicate["files"][0].clone();
        duplicate["files"]
            .as_array_mut()
            .unwrap()
            .push(duplicate_entry);
        assert!(validate_install_manifest(
            &serde_json::to_vec(&duplicate).unwrap(),
            &root.join("install"),
            &root.join("data"),
        )
        .is_err());
        assert!(validate_install_manifest(
            &serde_json::to_vec(&manifest).unwrap(),
            &root.join("other-install"),
            &root.join("data"),
        )
        .is_err());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn install_manifest_rejects_every_marketplace_tree_tamper_class() {
        let root = fixture_root("marketplace-tree-integrity");
        let (install, data, receipts) = install_catalog_fixture(&root);
        let manifest = install_manifest_value(&install, &data, &receipts);
        let validate = |manifest: &Value| {
            validate_install_manifest(&serde_json::to_vec(manifest).unwrap(), &install, &data)
        };
        validate(&manifest).expect("untampered marketplace catalog");

        let server = install
            .join("integrations/codex-marketplace/plugins/cluster-your-codex/mcp/dist/server.js");
        let original = std::fs::read(&server).unwrap();
        std::fs::write(&server, b"// altered").unwrap();
        assert!(validate(&manifest).is_err(), "same-length SHA drift");
        std::fs::write(&server, &original).unwrap();

        let missing =
            install.join("integrations/codex-marketplace/plugins/cluster-your-codex/.mcp.json");
        let missing_bytes = std::fs::read(&missing).unwrap();
        std::fs::remove_file(&missing).unwrap();
        assert!(validate(&manifest).is_err(), "missing catalog file");
        std::fs::write(&missing, missing_bytes).unwrap();

        let extra =
            install.join("integrations/codex-marketplace/plugins/cluster-your-codex/extra.bin");
        std::fs::write(&extra, b"extra").unwrap();
        assert!(validate(&manifest).is_err(), "extra marketplace file");
        std::fs::remove_file(&extra).unwrap();

        let mut wrong_length = manifest.clone();
        let file = wrong_length["files"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|entry| {
                entry["relativePath"]
                    .as_str()
                    .is_some_and(|path| path.ends_with("mcp/dist/server.js"))
            })
            .unwrap();
        file["length"] = json!(file["length"].as_u64().unwrap() + 1);
        wrong_length["buildCatalogSha256"] = json!(catalog_digest(
            serde_json::from_value::<Vec<InstalledFileReceipt>>(wrong_length["files"].clone(),)
                .unwrap()
                .iter(),
        ));
        wrong_length["codexPayloadCatalogSha256"] = json!(catalog_digest(
            serde_json::from_value::<Vec<InstalledFileReceipt>>(wrong_length["files"].clone(),)
                .unwrap()
                .iter()
                .filter(|receipt| receipt.relative_path.starts_with(CODEX_MARKETPLACE_PREFIX)),
        ));
        assert!(validate(&wrong_length).is_err(), "length mismatch");

        for invalid in [
            "../escape",
            "integrations\\codex-marketplace\\bad",
            "/absolute/path",
        ] {
            let mut bad_path = manifest.clone();
            bad_path["files"][0]["relativePath"] = json!(invalid);
            assert!(
                validate(&bad_path).is_err(),
                "invalid relative path {invalid}"
            );
        }

        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn legacy_or_disabled_agents_receipts_keep_payload_repairable_but_gate_closed() {
        let root = fixture_root("legacy-agents-receipt");
        let (install, data, receipts) = install_catalog_fixture(&root);
        let mut manifest = install_manifest_value(&install, &data, &receipts);

        manifest["agentsIntegration"] = json!({"enabled": false, "installed": false});
        let disabled =
            validate_install_manifest(&serde_json::to_vec(&manifest).unwrap(), &install, &data)
                .expect("disabled record remains repairable");
        assert!(disabled.agents_integration.is_none());

        manifest["agentsIntegration"] = json!({
            "enabled": true,
            "installed": true,
            "path": install.join("legacy-AGENTS.md"),
        });
        let legacy =
            validate_install_manifest(&serde_json::to_vec(&manifest).unwrap(), &install, &data)
                .expect("legacy record remains repairable");
        assert!(legacy.agents_integration.is_none());
        std::fs::remove_dir_all(root).unwrap();
    }

    fn agents_verifier_fixture(root: &Path) -> (VerifiedInstall, PathBuf, PathBuf, Vec<u8>) {
        let install = root.join("install");
        let codex_home = root.join("codex-home");
        let agents_path = codex_home.join("AGENTS.md");
        let template_path = install.join(AGENTS_TEMPLATE_RELATIVE_PATH);
        std::fs::create_dir_all(template_path.parent().unwrap()).unwrap();
        std::fs::create_dir_all(&codex_home).unwrap();

        let block = format!("{AGENTS_BEGIN_MARKER}\n# ClusterYourCodex\n{AGENTS_END_MARKER}");
        let prefix = "\n\n";
        let external_before = "# Existing user instructions\n";
        let external_after = "\n# Existing trailing instructions\n";
        let document = format!("{external_before}{prefix}{block}{external_after}").into_bytes();
        let external = format!("{external_before}{external_after}").into_bytes();
        let owned_range = format!("{prefix}{block}").into_bytes();
        let template = format!("{block}\n").into_bytes();
        std::fs::write(&agents_path, &document).unwrap();
        std::fs::write(&template_path, &template).unwrap();

        let sha = |bytes: &[u8]| format!("{:x}", Sha256::digest(bytes));
        let template_receipt = InstalledFileReceipt {
            relative_path: AGENTS_TEMPLATE_RELATIVE_PATH.to_owned(),
            sha256: sha(&template),
            length: template.len() as u64,
        };
        let mut files = BTreeMap::new();
        files.insert(
            receipt_key(AGENTS_TEMPLATE_RELATIVE_PATH),
            template_receipt.clone(),
        );
        let integrity = VerifiedInstall {
            install_root: install,
            data_root: root.join("data"),
            manifest_sha256: "a".repeat(64),
            build_catalog_sha256: catalog_digest(files.values()),
            payload_catalog_sha256: "b".repeat(64),
            files,
            agents_integration: Some(AgentsIntegrationRecord {
                schema_version: AGENTS_INTEGRATION_SCHEMA.to_owned(),
                enabled: true,
                installed: true,
                path: agents_path.clone(),
                codex_home: codex_home.clone(),
                template_relative_path: AGENTS_TEMPLATE_RELATIVE_PATH.to_owned(),
                template_sha256: template_receipt.sha256,
                encoding: "utf8".to_owned(),
                installed_file_sha256: sha(&document),
                installed_file_length: document.len() as u64,
                block_sha256: sha(block.as_bytes()),
                prefix_sha256: sha(prefix.as_bytes()),
                owned_prefix_base64: base64::engine::general_purpose::STANDARD
                    .encode(prefix.as_bytes()),
                external_sha256: sha(&external),
                external_length: external.len() as u64,
                owned_range_sha256: sha(&owned_range),
                transaction_id: "tx-123".to_owned(),
            }),
        };
        (integrity, codex_home, agents_path, document)
    }

    #[test]
    fn global_agents_read_only_verifier_detects_block_external_and_receipt_drift() {
        let root = fixture_root("agents-verifier");
        let (mut integrity, codex_home, agents_path, original) = agents_verifier_fixture(&root);
        let evidence = verify_agents_integration(&integrity, &codex_home)
            .expect("exact managed AGENTS transaction");
        assert_eq!(
            evidence.block_sha256,
            integrity.agents_integration.as_ref().unwrap().block_sha256
        );

        let external_edit = String::from_utf8(original.clone())
            .unwrap()
            .replace("Existing user", "Existing USER");
        std::fs::write(&agents_path, external_edit).unwrap();
        assert!(verify_agents_integration(&integrity, &codex_home).is_err());
        std::fs::write(&agents_path, &original).unwrap();

        let block_edit = String::from_utf8(original.clone())
            .unwrap()
            .replace("# ClusterYourCodex", "# ClusterYourCodey");
        std::fs::write(&agents_path, block_edit).unwrap();
        assert!(verify_agents_integration(&integrity, &codex_home).is_err());
        std::fs::write(&agents_path, &original).unwrap();

        let duplicate = [
            original.clone(),
            format!("\n{AGENTS_BEGIN_MARKER}\nextra\n{AGENTS_END_MARKER}").into_bytes(),
        ]
        .concat();
        std::fs::write(&agents_path, duplicate).unwrap();
        assert!(verify_agents_integration(&integrity, &codex_home).is_err());
        std::fs::write(&agents_path, &original).unwrap();

        integrity
            .agents_integration
            .as_mut()
            .unwrap()
            .external_sha256 = "0".repeat(64);
        assert!(verify_agents_integration(&integrity, &codex_home).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn installed_bootstrap_digest_rejects_missing_and_tampered_files() {
        let root = fixture_root("bootstrap-digest");
        std::fs::create_dir_all(&root).unwrap();
        let bootstrap = root.join("bootstrap.ps1");
        std::fs::write(&bootstrap, b"safe").unwrap();
        let expected = InstalledFileReceipt {
            relative_path: INSTALLED_BOOTSTRAP_RELATIVE_PATH.to_owned(),
            sha256: sha256_file(&bootstrap).unwrap(),
            length: 4,
        };
        validate_installed_file(&root, &bootstrap, &expected).unwrap();
        std::fs::write(&bootstrap, b"evil").unwrap();
        assert!(validate_installed_file(&root, &bootstrap, &expected).is_err());
        std::fs::remove_file(&bootstrap).unwrap();
        assert!(validate_installed_file(&root, &bootstrap, &expected).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn verified_file_handle_denies_write_delete_and_rename_until_drop() {
        let root = fixture_root("locked-bootstrap-handle");
        std::fs::create_dir_all(&root).unwrap();
        let path = root.join("bootstrap.ps1");
        let renamed = root.join("swapped.ps1");
        std::fs::write(&path, b"verified bytes").unwrap();

        let guard = open_read_locked(&path).expect("locked read handle");
        assert!(File::options().write(true).open(&path).is_err());
        assert!(std::fs::remove_file(&path).is_err());
        assert!(std::fs::rename(&path, &renamed).is_err());

        drop(guard);
        std::fs::write(&path, b"replacement").unwrap();
        std::fs::rename(&path, &renamed).unwrap();
        std::fs::remove_file(&renamed).unwrap();
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn retryable_busy_error_prevents_native_mutex_queueing() {
        let root = fixture_root("native-operation-busy");
        let inner = IntegrationManagerInner {
            token_file: root.join("controller.token"),
            data_root: root,
            operation_lock: Mutex::new(()),
        };
        let held = inner.operation_lock.lock().unwrap();
        assert!(matches!(
            try_operation_lock(&inner),
            Err(IntegrationError::OperationUnavailable)
        ));
        let public = PublicIntegrationError::from(IntegrationError::OperationUnavailable);
        assert_eq!(public.code, "integration_busy_retryable");
        assert!(public.retryable);
        drop(held);
        assert!(try_operation_lock(&inner).is_ok());
    }

    #[test]
    fn exact_unchanged_install_has_no_change_or_restart_signal() {
        assert_eq!(
            integration_action_flags(
                false,
                CodexOnlyStatus::Unchanged,
                IntegrationState::Installed,
                false,
            ),
            (false, false)
        );
        assert_eq!(
            integration_action_flags(
                false,
                CodexOnlyStatus::Repaired,
                IntegrationState::Installed,
                false,
            ),
            (true, false)
        );
        assert_eq!(
            integration_action_flags(
                true,
                CodexOnlyStatus::Unchanged,
                IntegrationState::RestartRequired,
                false,
            ),
            (true, true)
        );
    }

    #[test]
    fn mcp_tool_payload_parser_accepts_only_one_exact_json_object_text_item() {
        let valid = json!({
            "content": [{"type": "text", "text": "{\"ok\":true}"}],
        });
        assert_eq!(
            parse_strict_tool_payload(valid).unwrap(),
            json!({"ok": true})
        );

        for invalid in [
            json!({"content": [{"type":"text","text":"{\"ok\":true}"}], "isError":false}),
            json!({"content": [
                {"type":"text","text":"{\"ok\":true}"},
                {"type":"text","text":"{\"extra\":true}"},
            ]}),
            json!({"content": [{"type":"text","text":"[]"}]}),
            json!({"content": [{"type":"text","text":" {\"ok\":true}"}]}),
            json!({"content": [{"type":"text","text":"{\"ok\":true}","extra":true}]}),
            json!({"content": [{"type":"image","text":"{\"ok\":true}"}]}),
            json!({"content": [{"type":"text","text":"{\"ok\":true}"}], "extra":true}),
        ] {
            assert!(parse_strict_tool_payload(invalid).is_err());
        }
    }

    #[test]
    fn bundled_payload_requires_the_exact_owned_local_marketplace() {
        let root = fixture_root("payload-marketplace-tamper");
        write_marketplace_fixture(&root, "0.1.0");
        std::fs::write(
            root.join(".agents/plugins/marketplace.json"),
            r#"{"name":"other-marketplace","plugins":[]}"#,
        )
        .unwrap();
        assert!(validate_payload_root(&root).is_none());
        assert!(validate_owned_marketplace_root(&root).is_none());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn validates_the_actual_installed_manifest_bridge_and_runtime() {
        let root = fixture_root("installed-source");
        write_plugin_fixture(&root, "0.1.0");
        let registration = PluginRegistration {
            version: "0.1.0".to_owned(),
            enabled: true,
            source_path: root.clone(),
        };
        let installed = validate_installed_plugin(&registration).unwrap();
        assert!(same_path(&installed.root, &root));
        assert!(installed.server.ends_with("mcp/dist/server.js"));

        std::fs::write(
            root.join(".codex-plugin/plugin.json"),
            r#"{"name":"cluster-your-codex","version":"9.9.9"}"#,
        )
        .unwrap();
        assert!(validate_installed_plugin(&registration).is_none());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn damaged_installed_bridge_is_rejected() {
        let root = fixture_root("damaged-bridge");
        write_plugin_fixture(&root, "0.1.0");
        let registration = PluginRegistration {
            version: "0.1.0".to_owned(),
            enabled: true,
            source_path: root.clone(),
        };
        std::fs::write(
            root.join(".mcp.json"),
            r#"{"mcpServers":{"cluster_your_codex":{"command":"powershell","args":["-c","whoami"],"cwd":".","env_vars":["CYC_CONTROLLER_TOKEN_FILE"]}}}"#,
        )
        .unwrap();
        assert!(validate_installed_plugin(&registration).is_none());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[derive(Debug, PartialEq, Eq)]
    enum FakeMarketplaceCall {
        Remove,
        Add(PathBuf),
    }

    struct FakeMarketplace {
        remove_results: Vec<bool>,
        add_results: Vec<bool>,
        calls: Vec<FakeMarketplaceCall>,
    }

    impl MarketplaceCommandExecutor for FakeMarketplace {
        fn remove_owned(&mut self) -> Result<bool, IntegrationError> {
            self.calls.push(FakeMarketplaceCall::Remove);
            Ok(self.remove_results.remove(0))
        }

        fn add_local(&mut self, root: &Path) -> Result<bool, IntegrationError> {
            self.calls
                .push(FakeMarketplaceCall::Add(root.to_path_buf()));
            Ok(self.add_results.remove(0))
        }
    }

    #[test]
    fn failed_marketplace_switch_restores_the_validated_previous_source() {
        let previous = fixture_root("marketplace-previous");
        write_marketplace_fixture(&previous, "0.0.9");
        let desired = fixture_root("marketplace-desired");
        write_marketplace_fixture(&desired, "0.1.0");
        let canonical_previous = previous.canonicalize().unwrap();
        let mut executor = FakeMarketplace {
            remove_results: vec![true, true],
            add_results: vec![false, true],
            calls: Vec::new(),
        };

        assert!(switch_marketplace(&mut executor, Some(&previous), &desired).is_err());
        assert_eq!(
            executor.calls,
            vec![
                FakeMarketplaceCall::Remove,
                FakeMarketplaceCall::Add(desired.clone()),
                FakeMarketplaceCall::Remove,
                FakeMarketplaceCall::Add(canonical_previous),
            ]
        );
        std::fs::remove_dir_all(previous).unwrap();
        std::fs::remove_dir_all(desired).unwrap();
    }

    #[test]
    fn plugin_phase_rollback_restores_the_previous_marketplace() {
        let previous = fixture_root("plugin-rollback-previous");
        write_marketplace_fixture(&previous, "0.0.9");
        let desired = fixture_root("plugin-rollback-desired");
        write_marketplace_fixture(&desired, "0.1.0");
        let canonical_previous = previous.canonicalize().unwrap();
        let mut executor = FakeMarketplace {
            remove_results: vec![true, true],
            add_results: vec![true, true],
            calls: Vec::new(),
        };
        let switched = switch_marketplace(&mut executor, Some(&previous), &desired).unwrap();
        restore_marketplace(&mut executor, &switched);
        assert_eq!(
            executor.calls,
            vec![
                FakeMarketplaceCall::Remove,
                FakeMarketplaceCall::Add(desired.clone()),
                FakeMarketplaceCall::Remove,
                FakeMarketplaceCall::Add(canonical_previous),
            ]
        );
        std::fs::remove_dir_all(previous).unwrap();
        std::fs::remove_dir_all(desired).unwrap();
    }

    #[test]
    fn stale_atomic_temp_files_do_not_block_state_replacement() {
        let root = fixture_root("atomic-state");
        std::fs::create_dir_all(&root).unwrap();
        let target = root.join("health-v1.json");
        let stale = root.join(format!(".health-v1.json.tmp-{}", std::process::id()));
        std::fs::write(&stale, "stale").unwrap();

        write_atomic_json(
            &target,
            &HealthReceipt {
                checked_at_ms: 1,
                passed: false,
                failed_check: Some("first".to_owned()),
            },
        )
        .unwrap();
        write_atomic_json(
            &target,
            &HealthReceipt {
                checked_at_ms: 2,
                passed: true,
                failed_check: None,
            },
        )
        .unwrap();
        let receipt: HealthReceipt = read_small_json(&target).unwrap();
        assert_eq!(receipt.checked_at_ms, 2);
        assert!(receipt.passed);
        assert!(stale.is_file());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn desktop_probe_receipt_never_impersonates_an_active_codex_runtime() {
        let root = fixture_root("desktop-probe-not-connected");
        let inner = IntegrationManagerInner {
            token_file: root.join("controller.token"),
            data_root: root.clone(),
            operation_lock: Mutex::new(()),
        };
        write_atomic_json(
            &health_receipt_path(&inner),
            &HealthReceipt {
                checked_at_ms: now_ms().unwrap(),
                passed: true,
                failed_check: None,
            },
        )
        .unwrap();
        assert_eq!(
            state_from_receipts(&inner, "0.1.0"),
            IntegrationState::Installed
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn only_a_live_fresh_runtime_receipt_clears_restart_required() {
        let root = fixture_root("active-runtime-receipt");
        let inner = IntegrationManagerInner {
            token_file: root.join("controller.token"),
            data_root: root.clone(),
            operation_lock: Mutex::new(()),
        };
        let installed_at_ms = now_ms().unwrap().saturating_sub(1_000);
        write_atomic_json(
            &restart_receipt_path(&inner),
            &RestartReceipt { installed_at_ms },
        )
        .unwrap();
        let now = Utc::now();
        write_atomic_json(
            &active_receipt_path(&inner),
            &McpActiveReceipt {
                api_version: "cyc.dev/mcp-runtime/v1".to_owned(),
                pid: std::process::id(),
                started_at: now,
                last_seen_at: now,
                controller_verified_at: now,
                bridge_version: "0.1.0".to_owned(),
            },
        )
        .unwrap();
        let (state, identity) = status_from_receipts(&inner, "0.1.0");
        assert_eq!(state, IntegrationState::Connected);
        assert_eq!(
            identity,
            Some(ActiveRuntimeIdentity {
                pid: std::process::id(),
                started_at: now,
                bridge_version: "0.1.0".to_owned(),
            })
        );
        assert!(!restart_receipt_path(&inner).exists());

        let stale = Utc::now() - chrono::Duration::minutes(5);
        write_atomic_json(
            &active_receipt_path(&inner),
            &McpActiveReceipt {
                api_version: "cyc.dev/mcp-runtime/v1".to_owned(),
                pid: std::process::id(),
                started_at: stale,
                last_seen_at: Utc::now(),
                controller_verified_at: stale,
                bridge_version: "0.1.0".to_owned(),
            },
        )
        .unwrap();
        let (state, identity) = status_from_receipts(&inner, "0.1.0");
        assert_eq!(state, IntegrationState::Stale);
        assert!(identity.is_none());
        assert!(!active_receipt_path(&inner).exists());
        std::fs::remove_dir_all(root).unwrap();
    }
}
