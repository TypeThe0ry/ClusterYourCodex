//! Opt-in hostile-workload isolation.
//!
//! The default worker remains the trusted same-user execution model. The
//! hostile backends are deliberately unavailable in production until their
//! platform escape/identity proofs are complete. Setting
//! `CYC_HOSTILE_ISOLATION_CONFIG` therefore fails daemon startup closed in this
//! preview. The Linux mechanism remains executable only from `cfg(test)` native
//! acceptance tests; it is never advertised or enabled by a release build.

use std::env;
use std::ffi::{OsStr, OsString};
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::process::Command;
#[cfg(target_os = "linux")]
use std::thread;
#[cfg(target_os = "linux")]
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use chrono::{DateTime, Utc};
use cyc_protocol::{HostileIsolationBackend, HostileIsolationInventory};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::config::WorkerConfig;
use crate::security::{
    ensure_protected_directory, ensure_protected_input, prepare_private_directory,
    replace_protected_file, write_protected_file,
};

pub const HOSTILE_ISOLATION_CONFIG_ENV: &str = "CYC_HOSTILE_ISOLATION_CONFIG";
pub const HOSTILE_ISOLATION_CONFIG_VERSION: &str = "cyc.dev/hostile-isolation/v1";
const RECONCILIATION_RECEIPT_VERSION: &str = "cyc.dev/hostile-reconciliation/v1";
const MAX_CONFIG_BYTES: usize = 128 * 1024;
const MAX_RECEIPT_BYTES: usize = 64 * 1024;
const MAX_RECEIPT_AGE_MINUTES: i64 = 15;
#[cfg(target_os = "linux")]
const RECONCILE_TIMEOUT: Duration = Duration::from_secs(10);

const EXPERIMENTAL_UNVERIFIED_REASON: &str = "hostile_isolation_experimental_unverified";
const WINDOWS_NATIVE_GUARD_UNAVAILABLE_REASON: &str = "native_guard_unavailable";
const MACOS_BACKEND_UNAVAILABLE_REASON: &str = "containment_backend_unavailable";

fn default_pids_max() -> u32 {
    512
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "backend", rename_all = "snake_case", deny_unknown_fields)]
enum IsolationDocument {
    LinuxCgroupV2 {
        #[serde(rename = "apiVersion")]
        api_version: String,
        #[serde(rename = "nodeId")]
        node_id: Uuid,
        #[serde(rename = "executionUid")]
        execution_uid: u32,
        #[serde(rename = "executionGid")]
        execution_gid: u32,
        #[serde(rename = "cgroupPath")]
        cgroup_path: PathBuf,
        #[serde(rename = "guardStateFile")]
        guard_state_file: PathBuf,
        #[serde(default = "default_pids_max", rename = "pidsMax")]
        pids_max: u32,
    },
    WindowsExternalGuard {
        #[serde(rename = "apiVersion")]
        api_version: String,
        #[serde(rename = "nodeId")]
        node_id: Uuid,
        #[serde(rename = "executionSid")]
        execution_sid: String,
        #[serde(rename = "guardExecutable")]
        guard_executable: PathBuf,
        #[serde(rename = "guardStateDirectory")]
        guard_state_directory: PathBuf,
        #[serde(rename = "guardStateFile")]
        guard_state_file: PathBuf,
    },
    MacosExternalReconciliation {
        #[serde(rename = "apiVersion")]
        api_version: String,
        #[serde(rename = "nodeId")]
        node_id: Uuid,
        #[serde(rename = "executionUid")]
        execution_uid: u32,
        #[serde(rename = "executionGid")]
        execution_gid: u32,
        #[serde(rename = "guardExecutable")]
        guard_executable: PathBuf,
        #[serde(rename = "guardStateDirectory")]
        guard_state_directory: PathBuf,
        #[serde(rename = "guardStateFile")]
        guard_state_file: PathBuf,
    },
}

impl IsolationDocument {
    fn api_version(&self) -> &str {
        match self {
            Self::LinuxCgroupV2 { api_version, .. }
            | Self::WindowsExternalGuard { api_version, .. }
            | Self::MacosExternalReconciliation { api_version, .. } => api_version,
        }
    }

    fn node_id(&self) -> Uuid {
        match self {
            Self::LinuxCgroupV2 { node_id, .. }
            | Self::WindowsExternalGuard { node_id, .. }
            | Self::MacosExternalReconciliation { node_id, .. } => *node_id,
        }
    }
}

#[derive(Clone, Debug)]
struct LinuxIsolation {
    node_id: Uuid,
    execution_uid: u32,
    execution_gid: u32,
    cgroup_path: PathBuf,
    guard_state_file: PathBuf,
    pids_max: u32,
}

#[derive(Clone, Debug)]
struct WindowsIsolation {
    node_id: Uuid,
    execution_sid: String,
    guard_executable: PathBuf,
    guard_state_directory: PathBuf,
    guard_state_file: PathBuf,
}

#[derive(Clone, Debug)]
struct MacosIsolation {
    node_id: Uuid,
    execution_uid: u32,
    execution_gid: u32,
    guard_executable: PathBuf,
    guard_state_directory: PathBuf,
    guard_state_file: PathBuf,
}

#[derive(Clone, Debug)]
enum IsolationBackend {
    Linux(LinuxIsolation),
    Windows(WindowsIsolation),
    Macos(MacosIsolation),
}

/// Process-local view of the opt-in policy.  It is cheap to load for each
/// spawn, which avoids global mutable policy and makes replacement/tampering of
/// the protected config fail closed before the next child starts.
#[derive(Clone, Debug)]
pub struct HostileIsolation {
    config_path: Option<PathBuf>,
    backend: Option<IsolationBackend>,
}

#[derive(Clone, Debug)]
pub struct LaunchSpec {
    pub program: OsString,
    pub arguments: Vec<OsString>,
    pub manages_cwd: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ReconciliationReceipt {
    api_version: String,
    node_id: Uuid,
    backend: HostileIsolationBackend,
    generation: Uuid,
    reconciled_at: DateTime<Utc>,
    residual_processes_killed: u32,
    residual_empty: bool,
    dedicated_identity: bool,
    protected_guard_state: bool,
    worker_state_isolated: bool,
}

impl HostileIsolation {
    pub fn disabled() -> Self {
        Self {
            config_path: None,
            backend: None,
        }
    }

    pub fn from_environment(expected_node_id: Option<Uuid>) -> Result<Self> {
        let Some(raw_path) = env::var_os(HOSTILE_ISOLATION_CONFIG_ENV) else {
            return Ok(Self::disabled());
        };
        if raw_path.is_empty() {
            bail!("{HOSTILE_ISOLATION_CONFIG_ENV} must not be empty");
        }
        let config_path = absolute_clean_path(Path::new(&raw_path), "hostile isolation config")?;
        ensure_protected_input(&config_path).with_context(|| {
            format!(
                "refuse unprotected hostile isolation config {}",
                config_path.display()
            )
        })?;
        let raw = fs::read(&config_path)
            .with_context(|| format!("read hostile isolation config {}", config_path.display()))?;
        if raw.len() > MAX_CONFIG_BYTES {
            bail!("hostile isolation config is unexpectedly large");
        }
        let document: IsolationDocument =
            serde_json::from_slice(&raw).context("parse hostile isolation config JSON")?;
        if document.api_version() != HOSTILE_ISOLATION_CONFIG_VERSION {
            bail!(
                "unsupported hostile isolation apiVersion `{}`",
                document.api_version()
            );
        }
        if document.node_id().is_nil() {
            bail!("hostile isolation nodeId must not be nil");
        }
        if expected_node_id.is_some_and(|expected| expected != document.node_id()) {
            bail!("hostile isolation nodeId does not match worker config");
        }

        let backend = match document {
            IsolationDocument::LinuxCgroupV2 {
                node_id,
                execution_uid,
                execution_gid,
                cgroup_path,
                guard_state_file,
                pids_max,
                ..
            } => {
                if !cfg!(target_os = "linux") {
                    bail!("linux_cgroup_v2 hostile isolation requires a Linux worker");
                }
                validate_numeric_identity(execution_uid, execution_gid)?;
                if pids_max == 0 || pids_max > 1_048_576 {
                    bail!("hostile isolation pidsMax must be in 1..=1048576");
                }
                let cgroup_path = absolute_clean_path(&cgroup_path, "cgroup")?;
                validate_linux_cgroup_path(&cgroup_path, node_id)?;
                let guard_state_file =
                    absolute_clean_path(&guard_state_file, "hostile guard state")?;
                IsolationBackend::Linux(LinuxIsolation {
                    node_id,
                    execution_uid,
                    execution_gid,
                    cgroup_path,
                    guard_state_file,
                    pids_max,
                })
            }
            IsolationDocument::WindowsExternalGuard {
                node_id,
                execution_sid,
                guard_executable,
                guard_state_directory,
                guard_state_file,
                ..
            } => {
                if !cfg!(windows) {
                    bail!("windows_external_guard hostile isolation requires a Windows worker");
                }
                validate_windows_sid(&execution_sid)?;
                let guard_executable =
                    absolute_clean_path(&guard_executable, "Windows isolation guard")?;
                let guard_state_directory =
                    absolute_clean_path(&guard_state_directory, "Windows guard state directory")?;
                let guard_state_file =
                    absolute_clean_path(&guard_state_file, "hostile guard state")?;
                require_direct_child(&guard_state_directory, &guard_state_file, "guardStateFile")?;
                IsolationBackend::Windows(WindowsIsolation {
                    node_id,
                    execution_sid,
                    guard_executable,
                    guard_state_directory,
                    guard_state_file,
                })
            }
            IsolationDocument::MacosExternalReconciliation {
                node_id,
                execution_uid,
                execution_gid,
                guard_executable,
                guard_state_directory,
                guard_state_file,
                ..
            } => {
                if !cfg!(target_os = "macos") {
                    bail!(
                        "macos_external_reconciliation hostile isolation requires a macOS worker"
                    );
                }
                validate_numeric_identity(execution_uid, execution_gid)?;
                let guard_executable =
                    absolute_clean_path(&guard_executable, "macOS isolation guard")?;
                let guard_state_directory =
                    absolute_clean_path(&guard_state_directory, "macOS guard state directory")?;
                let guard_state_file =
                    absolute_clean_path(&guard_state_file, "hostile guard state")?;
                require_direct_child(&guard_state_directory, &guard_state_file, "guardStateFile")?;
                IsolationBackend::Macos(MacosIsolation {
                    node_id,
                    execution_uid,
                    execution_gid,
                    guard_executable,
                    guard_state_directory,
                    guard_state_file,
                })
            }
        };
        Ok(Self {
            config_path: Some(config_path),
            backend: Some(backend),
        })
    }

    pub fn enabled(&self) -> bool {
        self.backend.is_some()
    }

    pub fn inventory(&self) -> HostileIsolationInventory {
        let Some(backend) = &self.backend else {
            return HostileIsolationInventory::default();
        };
        // Public readiness stays hard-gated until each backend has the complete
        // hostile-workload proof, not merely a clean residual receipt.  In
        // particular, a writable/delegated cgroup can let a Linux task migrate
        // out, and the Windows external JSON protocol is not a native proof of
        // token or Job Object state.  Keep the internal Linux mechanism testable
        // without making it schedulable in a production inventory.
        let (kind, reason_code) = match backend {
            IsolationBackend::Linux(_) => (
                HostileIsolationBackend::LinuxCgroupV2DedicatedIdentity,
                EXPERIMENTAL_UNVERIFIED_REASON,
            ),
            IsolationBackend::Windows(_) => (
                HostileIsolationBackend::WindowsJobObjectExternalGuard,
                WINDOWS_NATIVE_GUARD_UNAVAILABLE_REASON,
            ),
            IsolationBackend::Macos(_) => (
                HostileIsolationBackend::MacosExternalReconciliation,
                MACOS_BACKEND_UNAVAILABLE_REASON,
            ),
        };
        HostileIsolationInventory {
            opt_in: true,
            ready: false,
            backend: kind,
            dedicated_identity: false,
            external_reconciliation: false,
            protected_guard_state: false,
            worker_state_isolated: false,
            reason_code: Some(reason_code.to_owned()),
        }
    }

    pub fn validate_worker_boundaries(
        &self,
        worker_config_path: &Path,
        worker_config: &WorkerConfig,
    ) -> Result<()> {
        let Some(backend) = &self.backend else {
            return Ok(());
        };
        self.ensure_runtime_backend_available()?;
        let isolation_config = self
            .config_path
            .as_deref()
            .context("enabled hostile isolation omitted its config path")?;
        ensure_protected_input(isolation_config)
            .context("hostile isolation config protection changed")?;
        ensure_protected_input(worker_config_path)
            .context("worker config protection changed before hostile execution")?;
        ensure_protected_input(&worker_config.credential_file)
            .context("worker credential protection changed before hostile execution")?;
        ensure_protected_directory(&worker_config.workspace_root)
            .context("worker workspace protection changed before hostile execution")?;

        match backend {
            IsolationBackend::Linux(config) => {
                // The cgroup control files do not exist until the node-owned
                // child is prepared. Create and validate that boundary first,
                // then run the broader worker/credential checks against the
                // now-existing controls before allowing a claim.
                prepare_guard_parent(&config.guard_state_file)?;
                prepare_linux_cgroup(config)?;
                validate_linux_worker_boundaries(
                    config,
                    isolation_config,
                    worker_config_path,
                    &worker_config.credential_file,
                    &worker_config.workspace_root,
                )?;
            }
            IsolationBackend::Windows(_) | IsolationBackend::Macos(_) => {
                bail!("unavailable hostile backend bypassed the fail-closed startup gate")
            }
        }
        Ok(())
    }

    /// Must run on daemon start before any controller claim. The experimental
    /// Linux test backend kills and proves the configured cgroup empty. Release
    /// builds fail the runtime-availability gate before reaching this path.
    pub fn reconcile_before_claim(&self) -> Result<()> {
        self.ensure_runtime_backend_available()?;
        match &self.backend {
            None => Ok(()),
            Some(IsolationBackend::Linux(config)) => {
                let residual = reconcile_linux_cgroup(config)?;
                persist_receipt(
                    &config.guard_state_file,
                    ReconciliationReceipt::clean(
                        config.node_id,
                        HostileIsolationBackend::LinuxCgroupV2DedicatedIdentity,
                        residual,
                    ),
                )
            }
            Some(IsolationBackend::Windows(config)) => {
                let _ = config;
                bail!(
                    "CYC-WINDOWS-HOSTILE-ISOLATION-UNAVAILABLE: external JSON receipts are not native containment proof"
                )
            }
            Some(IsolationBackend::Macos(_)) => bail!(
                "CYC-MACOS-HOSTILE-ISOLATION-UNAVAILABLE: external process reconciliation is not implemented"
            ),
        }
    }

    /// Re-check the durable external proof and current backend immediately
    /// before each claim.  This detects malicious guard replacement or newly
    /// appeared residual processes without silently repairing either condition.
    pub fn verify_before_claim(&self) -> Result<()> {
        self.ensure_runtime_backend_available()?;
        match &self.backend {
            None => Ok(()),
            Some(IsolationBackend::Linux(config)) => {
                validate_receipt_file(
                    &config.guard_state_file,
                    config.node_id,
                    HostileIsolationBackend::LinuxCgroupV2DedicatedIdentity,
                )?;
                ensure_linux_cgroup_empty(&config.cgroup_path)?;
                validate_linux_cgroup_control_boundary(config)?;
                validate_linux_cgroup_resource_limit(config)
            }
            Some(IsolationBackend::Windows(config)) => {
                let _ = config;
                bail!(
                    "CYC-WINDOWS-HOSTILE-ISOLATION-UNAVAILABLE: bundled native guard verification is not implemented"
                )
            }
            Some(IsolationBackend::Macos(_)) => bail!(
                "CYC-MACOS-HOSTILE-ISOLATION-UNAVAILABLE: external process reconciliation is not implemented"
            ),
        }
    }

    pub fn launch_spec(
        &self,
        program: &OsStr,
        arguments: &[OsString],
        cwd: &Path,
        stdout_path: &Path,
    ) -> Result<LaunchSpec> {
        self.ensure_runtime_backend_available()?;
        match &self.backend {
            None => Ok(LaunchSpec {
                program: program.to_owned(),
                arguments: arguments.to_vec(),
                manages_cwd: false,
            }),
            Some(IsolationBackend::Linux(config)) => {
                prepare_linux_execution_scope(config, cwd, stdout_path)?;
                Ok(LaunchSpec {
                    program: program.to_owned(),
                    arguments: arguments.to_vec(),
                    manages_cwd: true,
                })
            }
            Some(IsolationBackend::Windows(config)) => {
                let _ = (config, program, arguments, cwd, stdout_path);
                bail!(
                    "CYC-WINDOWS-HOSTILE-ISOLATION-UNAVAILABLE: refusing launch without the bundled native guard"
                )
            }
            Some(IsolationBackend::Macos(_)) => bail!(
                "CYC-MACOS-HOSTILE-ISOLATION-UNAVAILABLE: external process reconciliation is not implemented"
            ),
        }
    }

    pub fn configure_command(&self, command: &mut Command, cwd: &Path) -> Result<()> {
        self.ensure_runtime_backend_available()?;
        match &self.backend {
            None => Ok(()),
            Some(IsolationBackend::Windows(_)) => bail!(
                "CYC-WINDOWS-HOSTILE-ISOLATION-UNAVAILABLE: refusing command configuration without the bundled native guard"
            ),
            Some(IsolationBackend::Linux(config)) => {
                configure_linux_command(command, cwd, config)
            }
            Some(IsolationBackend::Macos(_)) => bail!(
                "CYC-MACOS-HOSTILE-ISOLATION-UNAVAILABLE: external process reconciliation is not implemented"
            ),
        }
    }

    /// A managed tree is not terminal evidence in hostile mode until the
    /// external backend independently reports empty.
    pub fn verify_after_process(&self) -> Result<()> {
        self.ensure_runtime_backend_available()?;
        match &self.backend {
            None => Ok(()),
            Some(IsolationBackend::Linux(config)) => {
                ensure_linux_cgroup_empty(&config.cgroup_path)
            }
            Some(IsolationBackend::Windows(config)) => {
                let _ = config;
                bail!(
                    "CYC-WINDOWS-HOSTILE-ISOLATION-UNAVAILABLE: native guard cannot prove the external process tree empty"
                )
            }
            Some(IsolationBackend::Macos(_)) => bail!(
                "CYC-MACOS-HOSTILE-ISOLATION-UNAVAILABLE: external process reconciliation is not implemented"
            ),
        }
    }

    fn ensure_runtime_backend_available(&self) -> Result<()> {
        #[cfg(test)]
        {
            self.ensure_runtime_backend_available_inner(true)
        }
        #[cfg(not(test))]
        {
            self.ensure_runtime_backend_available_inner(false)
        }
    }

    fn ensure_runtime_backend_available_inner(
        &self,
        allow_experimental_linux_for_native_tests: bool,
    ) -> Result<()> {
        match &self.backend {
            None => Ok(()),
            Some(IsolationBackend::Linux(_)) if allow_experimental_linux_for_native_tests => {
                Ok(())
            }
            Some(IsolationBackend::Linux(_)) => bail!(
                "CYC-LINUX-HOSTILE-ISOLATION-UNAVAILABLE: delegated-cgroup escape and identity exclusivity proofs are incomplete"
            ),
            Some(IsolationBackend::Windows(config)) => {
                validate_windows_schema(config)?;
                bail!(
                    "CYC-WINDOWS-HOSTILE-ISOLATION-UNAVAILABLE: bundled native guard and isolated identity provisioning are not implemented"
                )
            }
            Some(IsolationBackend::Macos(config)) => {
                validate_macos_schema(config)?;
                bail!(
                    "CYC-MACOS-HOSTILE-ISOLATION-UNAVAILABLE: external process reconciliation is not implemented"
                )
            }
        }
    }
}

impl ReconciliationReceipt {
    fn clean(node_id: Uuid, backend: HostileIsolationBackend, residual: u32) -> Self {
        Self {
            api_version: RECONCILIATION_RECEIPT_VERSION.to_owned(),
            node_id,
            backend,
            generation: Uuid::new_v4(),
            reconciled_at: Utc::now(),
            residual_processes_killed: residual,
            residual_empty: true,
            dedicated_identity: true,
            protected_guard_state: true,
            worker_state_isolated: true,
        }
    }

    fn validate(&self, node_id: Uuid, backend: HostileIsolationBackend) -> Result<()> {
        let now = Utc::now();
        if self.api_version != RECONCILIATION_RECEIPT_VERSION
            || self.node_id != node_id
            || self.backend != backend
            || self.generation.is_nil()
            || !self.residual_empty
            || !self.dedicated_identity
            || !self.protected_guard_state
            || !self.worker_state_isolated
            || self.reconciled_at > now + chrono::Duration::minutes(5)
            || self.reconciled_at < now - chrono::Duration::minutes(MAX_RECEIPT_AGE_MINUTES)
        {
            bail!("hostile reconciliation receipt is invalid or incomplete");
        }
        Ok(())
    }
}

pub fn hostile_isolation_inventory() -> HostileIsolationInventory {
    match HostileIsolation::from_environment(None) {
        Ok(isolation) => isolation.inventory(),
        Err(_) if env::var_os(HOSTILE_ISOLATION_CONFIG_ENV).is_some() => {
            HostileIsolationInventory {
                opt_in: true,
                ready: false,
                backend: HostileIsolationBackend::Unsupported,
                dedicated_identity: false,
                external_reconciliation: false,
                protected_guard_state: false,
                worker_state_isolated: false,
                reason_code: Some("configuration_invalid".to_owned()),
            }
        }
        Err(_) => HostileIsolationInventory::default(),
    }
}

fn persist_receipt(path: &Path, receipt: ReconciliationReceipt) -> Result<()> {
    receipt.validate(receipt.node_id, receipt.backend)?;
    prepare_guard_parent(path)?;
    let mut bytes =
        serde_json::to_vec_pretty(&receipt).context("serialize hostile reconciliation receipt")?;
    bytes.push(b'\n');
    if path_exists(path)? {
        replace_protected_file(path, &bytes)
    } else {
        write_protected_file(path, &bytes)
    }
    .with_context(|| format!("persist protected hostile guard state {}", path.display()))?;
    validate_receipt_file(path, receipt.node_id, receipt.backend)
}

fn validate_receipt_file(
    path: &Path,
    node_id: Uuid,
    backend: HostileIsolationBackend,
) -> Result<()> {
    ensure_protected_input(path)
        .with_context(|| format!("refuse unprotected hostile guard state {}", path.display()))?;
    let raw =
        fs::read(path).with_context(|| format!("read hostile guard state {}", path.display()))?;
    if raw.len() > MAX_RECEIPT_BYTES {
        bail!("hostile guard state is unexpectedly large");
    }
    let receipt: ReconciliationReceipt =
        serde_json::from_slice(&raw).context("parse hostile reconciliation receipt")?;
    receipt.validate(node_id, backend)
}

fn prepare_guard_parent(path: &Path) -> Result<()> {
    let parent = path
        .parent()
        .context("hostile guard state must have a parent")?;
    prepare_private_directory(parent).context("prepare protected external guard directory")?;
    ensure_protected_directory(parent).context("verify protected external guard directory")
}

fn path_exists(path: &Path) -> Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error).with_context(|| format!("inspect path {}", path.display())),
    }
}

fn absolute_clean_path(path: &Path, label: &str) -> Result<PathBuf> {
    if !path.is_absolute() {
        bail!("{label} path must be absolute");
    }
    if path.components().any(|component| match component {
        Component::CurDir | Component::ParentDir => true,
        Component::Prefix(_) => !cfg!(windows),
        Component::RootDir | Component::Normal(_) => false,
    }) {
        bail!("{label} path must not contain `.` or `..` components");
    }
    Ok(path.to_owned())
}

fn require_direct_child(parent: &Path, child: &Path, label: &str) -> Result<()> {
    if child.parent() != Some(parent) {
        bail!("{label} must be a direct child of the configured guard state directory");
    }
    Ok(())
}

fn validate_numeric_identity(uid: u32, gid: u32) -> Result<()> {
    if uid == 0 || gid == 0 {
        bail!("hostile execution uid/gid must be non-root");
    }
    Ok(())
}

fn validate_windows_sid(value: &str) -> Result<()> {
    let mut fields = value.split('-');
    if fields.next() != Some("S")
        || fields.next() != Some("1")
        || fields.clone().count() < 2
        || fields.any(|field| field.is_empty() || field.parse::<u64>().is_err())
    {
        bail!("hostile executionSid must be a canonical SID string");
    }
    Ok(())
}

fn validate_linux_cgroup_path(path: &Path, node_id: Uuid) -> Result<()> {
    let expected_name = format!("cyc-hostile-{node_id}");
    if !path.starts_with("/sys/fs/cgroup") || path.file_name() != Some(OsStr::new(&expected_name)) {
        bail!(
            "cgroupPath must be a node-owned `cyc-hostile-<nodeId>` directory below /sys/fs/cgroup"
        );
    }
    Ok(())
}

#[cfg(any(target_os = "linux", test))]
fn hostile_job_scope(cwd: &Path, stdout_path: &Path) -> Result<PathBuf> {
    let cwd = fs::canonicalize(cwd)
        .with_context(|| format!("canonicalize hostile process cwd {}", cwd.display()))?;
    let log_parent = stdout_path
        .parent()
        .context("hostile process stdout must have a parent")?;
    let log_parent = fs::canonicalize(log_parent).with_context(|| {
        format!(
            "canonicalize hostile process log directory {}",
            log_parent.display()
        )
    })?;
    let scope = cwd
        .ancestors()
        .find(|candidate| log_parent.starts_with(candidate))
        .context("hostile cwd and logs do not share a job-owned root")?
        .to_owned();
    let name = scope
        .file_name()
        .and_then(OsStr::to_str)
        .context("hostile job root must have a UTF-8 run identifier")?;
    if Uuid::parse_str(name).is_err()
        || scope.parent().and_then(Path::file_name) != Some(OsStr::new("jobs"))
    {
        bail!("hostile execution scope must be the exact jobs/<runId> directory");
    }
    Ok(scope)
}

#[cfg(target_os = "linux")]
fn validate_linux_worker_boundaries(
    config: &LinuxIsolation,
    isolation_config: &Path,
    worker_config: &Path,
    credential_file: &Path,
    workspace_root: &Path,
) -> Result<()> {
    use std::os::unix::fs::MetadataExt;

    let worker_uid = unsafe { libc::geteuid() };
    if worker_uid != 0 {
        bail!("linux hostile isolation requires the worker daemon to run as root");
    }
    if config.execution_uid == worker_uid {
        bail!("linux hostile execution uid must differ from the worker uid");
    }
    validate_linux_account(config.execution_uid, config.execution_gid)?;
    // A delegated cgroup is only a containment boundary when the hostile
    // identity cannot rewrite its control files. Validate this before claim.
    validate_linux_cgroup_control_boundary(config)?;
    for (label, path) in [
        ("hostile isolation config", isolation_config),
        ("worker config", worker_config),
        ("worker credential", credential_file),
    ] {
        ensure_sensitive_file_inaccessible_to_identity(
            path,
            config.execution_uid,
            config.execution_gid,
        )
        .with_context(|| format!("{label} is reachable by the hostile execution identity"))?;
    }
    let workspace = fs::metadata(workspace_root)
        .with_context(|| format!("inspect worker workspace {}", workspace_root.display()))?;
    if workspace.uid() == config.execution_uid {
        bail!("hostile execution identity must not own the worker workspace root");
    }
    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn validate_linux_worker_boundaries(
    config: &LinuxIsolation,
    _isolation_config: &Path,
    _worker_config: &Path,
    _credential_file: &Path,
    _workspace_root: &Path,
) -> Result<()> {
    let _ = (
        config.node_id,
        config.execution_uid,
        config.execution_gid,
        &config.cgroup_path,
        &config.guard_state_file,
        config.pids_max,
    );
    bail!("linux hostile isolation requires a Linux worker")
}

#[cfg(target_os = "linux")]
fn validate_linux_account(uid: u32, gid: u32) -> Result<()> {
    let mut password = std::mem::MaybeUninit::<libc::passwd>::uninit();
    let mut result = std::ptr::null_mut();
    let mut buffer = vec![0u8; 16 * 1024];
    let status = unsafe {
        libc::getpwuid_r(
            uid,
            password.as_mut_ptr(),
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            &mut result,
        )
    };
    if status != 0 {
        return Err(std::io::Error::from_raw_os_error(status))
            .context("resolve hostile execution uid");
    }
    if result.is_null() {
        bail!("hostile execution uid does not resolve to a local account");
    }
    let password = unsafe { password.assume_init() };
    if password.pw_gid != gid {
        bail!("hostile execution gid must equal the dedicated account primary gid");
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn ensure_sensitive_file_inaccessible_to_identity(path: &Path, uid: u32, gid: u32) -> Result<()> {
    use std::os::unix::fs::MetadataExt;

    ensure_protected_input(path)?;
    let metadata =
        fs::metadata(path).with_context(|| format!("inspect sensitive path {}", path.display()))?;
    let mode = metadata.mode() & 0o777;
    if metadata.uid() == uid || mode & 0o004 != 0 || (metadata.gid() == gid && mode & 0o040 != 0) {
        bail!("sensitive file permissions allow the hostile execution identity");
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn prepare_linux_cgroup(config: &LinuxIsolation) -> Result<()> {
    if !Path::new("/sys/fs/cgroup/cgroup.controllers").is_file() {
        bail!("Linux cgroup v2 unified hierarchy is unavailable");
    }
    let parent = config
        .cgroup_path
        .parent()
        .context("configured cgroupPath must have a parent")?;
    let canonical_parent = fs::canonicalize(parent)
        .with_context(|| format!("canonicalize cgroup parent {}", parent.display()))?;
    if !canonical_parent.starts_with("/sys/fs/cgroup") {
        bail!("configured cgroup parent escaped the cgroup v2 hierarchy");
    }
    if !path_exists(&config.cgroup_path)? {
        fs::create_dir(&config.cgroup_path).with_context(|| {
            format!(
                "create node-owned hostile cgroup {}",
                config.cgroup_path.display()
            )
        })?;
    }
    let metadata = fs::symlink_metadata(&config.cgroup_path)
        .with_context(|| format!("inspect hostile cgroup {}", config.cgroup_path.display()))?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        bail!("hostile cgroupPath is not a direct directory");
    }
    let canonical =
        fs::canonicalize(&config.cgroup_path).context("canonicalize node-owned hostile cgroup")?;
    if canonical != config.cgroup_path {
        bail!("hostile cgroupPath changed through aliasing or symlink resolution");
    }
    for required in ["cgroup.procs", "cgroup.events", "cgroup.kill", "pids.max"] {
        if !config.cgroup_path.join(required).is_file() {
            bail!("hostile cgroup v2 control `{required}` is unavailable");
        }
    }
    validate_linux_cgroup_control_boundary(config)?;
    fs::write(
        config.cgroup_path.join("pids.max"),
        format!("{}\n", config.pids_max),
    )
    .context("set hostile cgroup pids.max")?;
    validate_linux_cgroup_resource_limit(config)?;
    Ok(())
}

#[cfg(target_os = "linux")]
fn validate_linux_cgroup_control_boundary(config: &LinuxIsolation) -> Result<()> {
    use std::os::unix::fs::MetadataExt;

    let cgroup = fs::symlink_metadata(&config.cgroup_path).with_context(|| {
        format!(
            "inspect hostile cgroup boundary {}",
            config.cgroup_path.display()
        )
    })?;
    if !cgroup.is_dir() || cgroup.file_type().is_symlink() || cgroup.uid() != 0 {
        bail!("hostile cgroup directory must be root-owned and non-symlink");
    }
    if cgroup.mode() & 0o022 != 0 {
        bail!("hostile cgroup directory is writable by group or other");
    }
    for name in ["cgroup.procs", "cgroup.kill", "pids.max"] {
        let path = config.cgroup_path.join(name);
        let metadata = fs::symlink_metadata(&path)
            .with_context(|| format!("inspect hostile cgroup control {name}"))?;
        if !metadata.is_file() || metadata.file_type().is_symlink() || metadata.uid() != 0 {
            bail!("hostile cgroup control {name} must be a root-owned regular file");
        }
        let mode = metadata.mode() & 0o777;
        if mode & 0o002 != 0 || (metadata.gid() == config.execution_gid && mode & 0o020 != 0) {
            bail!("hostile execution identity can write cgroup control {name}");
        }
    }
    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn validate_linux_cgroup_control_boundary(_config: &LinuxIsolation) -> Result<()> {
    bail!("linux hostile isolation requires a Linux worker")
}

#[cfg(target_os = "linux")]
fn cgroup_pids_limit(path: &Path) -> Result<u32> {
    let raw = fs::read_to_string(path.join("pids.max"))
        .with_context(|| format!("read hostile cgroup pids.max at {}", path.display()))?;
    raw.trim()
        .parse::<u32>()
        .context("hostile cgroup pids.max must be a finite numeric limit")
}

#[cfg(target_os = "linux")]
fn validate_linux_cgroup_resource_limit(config: &LinuxIsolation) -> Result<()> {
    let observed = cgroup_pids_limit(&config.cgroup_path)?;
    if observed != config.pids_max {
        bail!(
            "hostile cgroup resource limit mismatch (expected {}, observed {})",
            config.pids_max,
            observed
        );
    }
    Ok(())
}

#[cfg(not(target_os = "linux"))]
#[allow(dead_code)]
fn validate_linux_cgroup_resource_limit(_config: &LinuxIsolation) -> Result<()> {
    bail!("linux hostile isolation requires a Linux worker")
}

#[cfg(not(target_os = "linux"))]
fn prepare_linux_cgroup(config: &LinuxIsolation) -> Result<()> {
    let _ = (config.execution_uid, config.execution_gid, config.pids_max);
    bail!("linux hostile isolation requires a Linux worker")
}

#[cfg(target_os = "linux")]
fn linux_cgroup_pids(path: &Path) -> Result<Vec<u32>> {
    let text = fs::read_to_string(path.join("cgroup.procs"))
        .with_context(|| format!("read hostile cgroup processes at {}", path.display()))?;
    text.lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            line.trim()
                .parse::<u32>()
                .context("hostile cgroup.procs contained a malformed PID")
        })
        .collect()
}

#[cfg(target_os = "linux")]
fn linux_cgroup_populated(path: &Path) -> Result<bool> {
    let text = fs::read_to_string(path.join("cgroup.events"))
        .with_context(|| format!("read hostile cgroup events at {}", path.display()))?;
    let mut populated = None;
    for line in text.lines() {
        let mut fields = line.split_whitespace();
        if fields.next() == Some("populated") {
            populated = match fields.next() {
                Some("0") => Some(false),
                Some("1") => Some(true),
                _ => bail!("hostile cgroup.events contained malformed populated state"),
            };
        }
    }
    populated.context("hostile cgroup.events omitted populated state")
}

#[cfg(target_os = "linux")]
fn ensure_linux_cgroup_empty(path: &Path) -> Result<()> {
    if !linux_cgroup_pids(path)?.is_empty() || linux_cgroup_populated(path)? {
        bail!("hostile cgroup contains residual processes");
    }
    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn ensure_linux_cgroup_empty(_path: &Path) -> Result<()> {
    bail!("linux hostile isolation requires a Linux worker")
}

#[cfg(target_os = "linux")]
fn reconcile_linux_cgroup(config: &LinuxIsolation) -> Result<u32> {
    prepare_linux_cgroup(config)?;
    let initial = linux_cgroup_pids(&config.cgroup_path)?;
    let populated = linux_cgroup_populated(&config.cgroup_path)?;
    if populated || !initial.is_empty() {
        fs::write(config.cgroup_path.join("cgroup.kill"), b"1\n")
            .context("kill residual hostile cgroup processes")?;
    }
    let deadline = Instant::now() + RECONCILE_TIMEOUT;
    loop {
        match ensure_linux_cgroup_empty(&config.cgroup_path) {
            Ok(()) => break,
            Err(error) if Instant::now() < deadline => {
                let _ = error;
                thread::sleep(Duration::from_millis(25));
            }
            Err(error) => {
                return Err(error).context("hostile cgroup residual reconciliation timed out")
            }
        }
    }
    Ok(u32::try_from(initial.len()).unwrap_or(u32::MAX))
}

#[cfg(not(target_os = "linux"))]
fn reconcile_linux_cgroup(_config: &LinuxIsolation) -> Result<u32> {
    bail!("linux hostile isolation requires a Linux worker")
}

#[cfg(target_os = "linux")]
fn prepare_linux_execution_scope(
    config: &LinuxIsolation,
    cwd: &Path,
    stdout_path: &Path,
) -> Result<()> {
    use std::os::unix::fs::MetadataExt;

    ensure_linux_cgroup_empty(&config.cgroup_path)?;
    let scope = hostile_job_scope(cwd, stdout_path)?;
    for entry in walkdir::WalkDir::new(&scope).follow_links(false) {
        let entry = entry.context("enumerate hostile job scope for identity handoff")?;
        let path = entry.path();
        let metadata = fs::symlink_metadata(path)
            .with_context(|| format!("inspect hostile job entry {}", path.display()))?;
        let changed = unsafe {
            let path = std::ffi::CString::new(path.as_os_str().as_encoded_bytes())
                .context("hostile job path contains NUL")?;
            libc::lchown(path.as_ptr(), config.execution_uid, config.execution_gid)
        };
        if changed != 0 {
            return Err(std::io::Error::last_os_error())
                .with_context(|| format!("handoff hostile job entry {}", path.display()));
        }
        if !metadata.file_type().is_symlink() {
            let after = fs::metadata(path)
                .with_context(|| format!("verify hostile job handoff {}", path.display()))?;
            if after.uid() != config.execution_uid || after.gid() != config.execution_gid {
                bail!("hostile job identity handoff did not persist");
            }
        }
    }
    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn prepare_linux_execution_scope(
    _config: &LinuxIsolation,
    _cwd: &Path,
    _stdout_path: &Path,
) -> Result<()> {
    bail!("linux hostile isolation requires a Linux worker")
}

#[cfg(target_os = "linux")]
fn configure_linux_command(
    command: &mut Command,
    cwd: &Path,
    config: &LinuxIsolation,
) -> Result<()> {
    use std::os::fd::AsRawFd;
    use std::os::unix::process::CommandExt;

    let cwd_handle = fs::File::open(cwd)
        .with_context(|| format!("open hostile process cwd {}", cwd.display()))?;
    let cgroup_handle = fs::OpenOptions::new()
        .write(true)
        .open(config.cgroup_path.join("cgroup.procs"))
        .context("open hostile cgroup.procs before spawn")?;
    let uid = config.execution_uid;
    let gid = config.execution_gid;
    unsafe {
        command.pre_exec(move || {
            let cwd_fd = cwd_handle.as_raw_fd();
            let cgroup_fd = cgroup_handle.as_raw_fd();
            if libc::write(cgroup_fd, b"0\n".as_ptr().cast(), 2) != 2 {
                return Err(std::io::Error::last_os_error());
            }
            if libc::fchdir(cwd_fd) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            if libc::setgroups(0, std::ptr::null()) != 0
                || libc::setgid(gid) != 0
                || libc::setuid(uid) != 0
            {
                return Err(std::io::Error::last_os_error());
            }
            if libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            libc::umask(0o077);
            Ok(())
        });
    }
    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn configure_linux_command(
    _command: &mut Command,
    _cwd: &Path,
    _config: &LinuxIsolation,
) -> Result<()> {
    bail!("linux hostile isolation requires a Linux worker")
}

fn validate_windows_schema(config: &WindowsIsolation) -> Result<()> {
    if config.node_id.is_nil() {
        bail!("Windows hostile isolation node id must not be nil");
    }
    validate_windows_sid(&config.execution_sid)?;
    if !config.guard_executable.is_absolute()
        || !config.guard_state_directory.is_absolute()
        || !config.guard_state_file.is_absolute()
    {
        bail!("Windows hostile isolation paths must be absolute");
    }
    require_direct_child(
        &config.guard_state_directory,
        &config.guard_state_file,
        "guardStateFile",
    )?;
    Ok(())
}

fn validate_macos_schema(config: &MacosIsolation) -> Result<()> {
    if config.node_id.is_nil() {
        bail!("macOS hostile isolation node id must not be nil");
    }
    validate_numeric_identity(config.execution_uid, config.execution_gid)?;
    if config.execution_uid == unsafe { libc_geteuid_portable() } {
        bail!("macOS hostile execution uid must differ from the worker uid");
    }
    if !config.guard_executable.is_absolute()
        || !config.guard_state_directory.is_absolute()
        || !config.guard_state_file.is_absolute()
    {
        bail!("macOS hostile isolation paths must be absolute");
    }
    Ok(())
}

#[cfg(unix)]
unsafe fn libc_geteuid_portable() -> u32 {
    libc::geteuid()
}

#[cfg(not(unix))]
unsafe fn libc_geteuid_portable() -> u32 {
    u32::MAX
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disabled_inventory_is_conservative() {
        let inventory = HostileIsolation::disabled().inventory();
        assert!(!inventory.opt_in);
        assert!(!inventory.ready);
        assert_eq!(inventory.backend, HostileIsolationBackend::Disabled);
    }

    #[test]
    fn windows_sid_validation_is_strict() {
        validate_windows_sid("S-1-5-21-1-2-3-1001").unwrap();
        for invalid in ["", "s-1-5-21", "S-2-5-21", "S-1-x-21", "S-1-5"] {
            assert!(
                validate_windows_sid(invalid).is_err(),
                "accepted `{invalid}`"
            );
        }
    }

    #[test]
    fn receipt_tampering_is_fail_closed() {
        let node_id = Uuid::new_v4();
        let mut receipt = ReconciliationReceipt::clean(
            node_id,
            HostileIsolationBackend::LinuxCgroupV2DedicatedIdentity,
            3,
        );
        receipt
            .validate(
                node_id,
                HostileIsolationBackend::LinuxCgroupV2DedicatedIdentity,
            )
            .unwrap();
        receipt.residual_empty = false;
        assert!(receipt
            .validate(
                node_id,
                HostileIsolationBackend::LinuxCgroupV2DedicatedIdentity
            )
            .is_err());
        receipt.residual_empty = true;
        receipt.worker_state_isolated = false;
        assert!(receipt
            .validate(
                node_id,
                HostileIsolationBackend::LinuxCgroupV2DedicatedIdentity
            )
            .is_err());
        receipt.worker_state_isolated = true;
        assert!(receipt
            .validate(
                Uuid::new_v4(),
                HostileIsolationBackend::LinuxCgroupV2DedicatedIdentity
            )
            .is_err());

        receipt.node_id = node_id;
        receipt.reconciled_at = Utc::now() - chrono::Duration::minutes(MAX_RECEIPT_AGE_MINUTES + 1);
        assert!(receipt
            .validate(
                node_id,
                HostileIsolationBackend::LinuxCgroupV2DedicatedIdentity
            )
            .is_err());
    }

    #[test]
    fn linux_clean_receipt_cannot_enable_public_readiness() {
        let directory = tempfile::tempdir().unwrap();
        let node_id = Uuid::new_v4();
        let guard_state_file = directory.path().join("linux-clean-receipt.json");
        fs::write(
            &guard_state_file,
            serde_json::to_vec(&ReconciliationReceipt::clean(
                node_id,
                HostileIsolationBackend::LinuxCgroupV2DedicatedIdentity,
                0,
            ))
            .unwrap(),
        )
        .unwrap();
        let isolation = HostileIsolation {
            config_path: Some(directory.path().join("hostile.json")),
            backend: Some(IsolationBackend::Linux(LinuxIsolation {
                node_id,
                execution_uid: 65_534,
                execution_gid: 65_534,
                cgroup_path: PathBuf::from(format!("/sys/fs/cgroup/cyc-hostile-{node_id}")),
                guard_state_file,
                pids_max: 64,
            })),
        };

        let inventory = isolation.inventory();
        assert!(isolation
            .ensure_runtime_backend_available_inner(false)
            .unwrap_err()
            .to_string()
            .contains("CYC-LINUX-HOSTILE-ISOLATION-UNAVAILABLE"));
        assert!(isolation
            .ensure_runtime_backend_available_inner(true)
            .is_ok());
        assert!(inventory.opt_in);
        assert!(!inventory.ready);
        assert!(!inventory.dedicated_identity);
        assert!(!inventory.external_reconciliation);
        assert_eq!(
            inventory.reason_code.as_deref(),
            Some(EXPERIMENTAL_UNVERIFIED_REASON)
        );
    }

    #[test]
    fn fake_windows_receipt_cannot_enable_public_readiness() {
        let directory = tempfile::tempdir().unwrap();
        let node_id = Uuid::new_v4();
        let guard_state_file = directory.path().join("fake-windows-receipt.json");
        fs::write(
            &guard_state_file,
            serde_json::to_vec(&ReconciliationReceipt::clean(
                node_id,
                HostileIsolationBackend::WindowsJobObjectExternalGuard,
                0,
            ))
            .unwrap(),
        )
        .unwrap();
        let isolation = HostileIsolation {
            config_path: Some(directory.path().join("hostile.json")),
            backend: Some(IsolationBackend::Windows(WindowsIsolation {
                node_id,
                execution_sid: "S-1-5-21-1-2-3-1001".to_owned(),
                guard_executable: directory.path().join("fake-guard.exe"),
                guard_state_directory: directory.path().to_path_buf(),
                guard_state_file,
            })),
        };

        let inventory = isolation.inventory();
        assert!(inventory.opt_in);
        assert!(!inventory.ready);
        assert!(!inventory.protected_guard_state);
        assert!(!inventory.worker_state_isolated);
        assert_eq!(
            inventory.reason_code.as_deref(),
            Some(WINDOWS_NATIVE_GUARD_UNAVAILABLE_REASON)
        );
    }

    #[test]
    fn windows_external_json_contract_is_fail_closed_at_every_runtime_gate() {
        let directory = tempfile::tempdir().unwrap();
        let node_id = Uuid::new_v4();
        let isolation = HostileIsolation {
            config_path: Some(directory.path().join("hostile.json")),
            backend: Some(IsolationBackend::Windows(WindowsIsolation {
                node_id,
                execution_sid: "S-1-5-21-1-2-3-1001".to_owned(),
                guard_executable: directory.path().join("fake-guard.exe"),
                guard_state_directory: directory.path().to_path_buf(),
                guard_state_file: directory.path().join("fake-receipt.json"),
            })),
        };
        let worker = WorkerConfig {
            api_version: crate::config::WORKER_CONFIG_VERSION.to_owned(),
            worker_url: "https://controller.example.invalid/worker".to_owned(),
            certificate_pem: "test-certificate".to_owned(),
            controller_id: Uuid::new_v4(),
            node_id,
            worker_api_version: "cyc.dev/worker-api/v1".to_owned(),
            heartbeat_interval_seconds: 5,
            lease_seconds: 30,
            workspace_root: directory.path().join("workspace"),
            credential_file: directory.path().join("worker.credential"),
        };
        let marker = "CYC-WINDOWS-HOSTILE-ISOLATION-UNAVAILABLE";

        assert!(isolation
            .validate_worker_boundaries(&directory.path().join("worker.json"), &worker)
            .unwrap_err()
            .to_string()
            .contains(marker));
        assert!(isolation
            .reconcile_before_claim()
            .unwrap_err()
            .to_string()
            .contains(marker));
        assert!(isolation
            .verify_before_claim()
            .unwrap_err()
            .to_string()
            .contains(marker));
        assert!(isolation
            .launch_spec(
                OsStr::new("ignored.exe"),
                &[],
                directory.path(),
                &directory.path().join("stdout.log"),
            )
            .unwrap_err()
            .to_string()
            .contains(marker));
        let mut command = Command::new("ignored.exe");
        assert!(isolation
            .configure_command(&mut command, directory.path())
            .unwrap_err()
            .to_string()
            .contains(marker));
        assert!(isolation
            .verify_after_process()
            .unwrap_err()
            .to_string()
            .contains(marker));
    }

    #[test]
    fn macos_external_reconciliation_is_fail_closed_at_every_runtime_gate() {
        let directory = tempfile::tempdir().unwrap();
        let node_id = Uuid::new_v4();
        let worker_uid = unsafe { libc_geteuid_portable() };
        let execution_uid = if worker_uid == 65_534 { 65_533 } else { 65_534 };
        let isolation = HostileIsolation {
            config_path: Some(directory.path().join("hostile.json")),
            backend: Some(IsolationBackend::Macos(MacosIsolation {
                node_id,
                execution_uid,
                execution_gid: 20,
                guard_executable: directory.path().join("fake-guard"),
                guard_state_directory: directory.path().to_path_buf(),
                guard_state_file: directory.path().join("fake-receipt.json"),
            })),
        };
        let worker = WorkerConfig {
            api_version: crate::config::WORKER_CONFIG_VERSION.to_owned(),
            worker_url: "https://controller.example.invalid/worker".to_owned(),
            certificate_pem: "test-certificate".to_owned(),
            controller_id: Uuid::new_v4(),
            node_id,
            worker_api_version: "cyc.dev/worker-api/v1".to_owned(),
            heartbeat_interval_seconds: 5,
            lease_seconds: 30,
            workspace_root: directory.path().join("workspace"),
            credential_file: directory.path().join("worker.credential"),
        };
        let inventory = isolation.inventory();
        let marker = "CYC-MACOS-HOSTILE-ISOLATION-UNAVAILABLE";

        assert!(!inventory.ready);
        assert!(!inventory.dedicated_identity);
        assert!(!inventory.external_reconciliation);
        assert_eq!(
            inventory.reason_code.as_deref(),
            Some(MACOS_BACKEND_UNAVAILABLE_REASON)
        );
        assert!(isolation
            .validate_worker_boundaries(&directory.path().join("worker.json"), &worker)
            .unwrap_err()
            .to_string()
            .contains(marker));
        assert!(isolation
            .reconcile_before_claim()
            .unwrap_err()
            .to_string()
            .contains(marker));
        assert!(isolation
            .verify_before_claim()
            .unwrap_err()
            .to_string()
            .contains(marker));
        assert!(isolation
            .launch_spec(
                OsStr::new("ignored"),
                &[],
                directory.path(),
                &directory.path().join("stdout.log"),
            )
            .unwrap_err()
            .to_string()
            .contains(marker));
        let mut command = Command::new("ignored");
        assert!(isolation
            .configure_command(&mut command, directory.path())
            .unwrap_err()
            .to_string()
            .contains(marker));
        assert!(isolation
            .verify_after_process()
            .unwrap_err()
            .to_string()
            .contains(marker));
    }

    #[test]
    fn process_scope_cannot_expand_beyond_exact_run_root() {
        let directory = tempfile::tempdir().unwrap();
        let jobs = directory.path().join("jobs");
        let run_id = Uuid::new_v4();
        let root = jobs.join(run_id.to_string());
        let repo = root.join("repo");
        let logs = root.join("logs");
        fs::create_dir_all(&repo).unwrap();
        fs::create_dir(&logs).unwrap();
        let scope = hostile_job_scope(&repo, &logs.join("step.stdout.log")).unwrap();
        assert_eq!(scope, fs::canonicalize(root).unwrap());

        let unrelated = directory.path().join("other-logs");
        fs::create_dir(&unrelated).unwrap();
        assert!(hostile_job_scope(&repo, &unrelated.join("out.log")).is_err());
    }

    #[test]
    fn macos_backend_inventory_can_never_claim_runtime_readiness() {
        let isolation = HostileIsolation {
            config_path: Some(PathBuf::from("/protected/hostile.json")),
            backend: Some(IsolationBackend::Macos(MacosIsolation {
                node_id: Uuid::new_v4(),
                execution_uid: 501,
                execution_gid: 20,
                guard_executable: PathBuf::from("/Library/PrivilegedHelperTools/cyc-guard"),
                guard_state_directory: PathBuf::from("/var/db/cyc-guard"),
                guard_state_file: PathBuf::from("/var/db/cyc-guard/reconcile.json"),
            })),
        };
        let inventory = isolation.inventory();
        assert!(inventory.opt_in);
        assert!(!inventory.ready);
        assert_eq!(
            inventory.backend,
            HostileIsolationBackend::MacosExternalReconciliation
        );
        assert_eq!(
            inventory.reason_code.as_deref(),
            Some("containment_backend_unavailable")
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn sensitive_file_mode_rejects_hostile_read_access() {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};

        let directory = tempfile::tempdir().unwrap();
        let protected = directory.path().join("state");
        fs::create_dir(&protected).unwrap();
        fs::set_permissions(&protected, fs::Permissions::from_mode(0o700)).unwrap();
        let credential = protected.join("worker.credential");
        fs::write(&credential, b"opaque").unwrap();
        fs::set_permissions(&credential, fs::Permissions::from_mode(0o600)).unwrap();
        let metadata = fs::metadata(&credential).unwrap();
        let hostile_uid = metadata.uid().saturating_add(10_000).max(1);
        let hostile_gid = metadata.gid().saturating_add(10_000).max(1);
        ensure_sensitive_file_inaccessible_to_identity(&credential, hostile_uid, hostile_gid)
            .unwrap();

        fs::set_permissions(&credential, fs::Permissions::from_mode(0o604)).unwrap();
        assert!(ensure_sensitive_file_inaccessible_to_identity(
            &credential,
            hostile_uid,
            hostile_gid
        )
        .is_err());
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn cgroup_parsers_reject_residual_and_malformed_state() {
        let directory = tempfile::tempdir().unwrap();
        fs::write(directory.path().join("cgroup.procs"), b"123\n456\n").unwrap();
        fs::write(
            directory.path().join("cgroup.events"),
            b"populated 1\nfrozen 0\n",
        )
        .unwrap();
        assert_eq!(linux_cgroup_pids(directory.path()).unwrap(), vec![123, 456]);
        assert!(ensure_linux_cgroup_empty(directory.path()).is_err());

        fs::write(directory.path().join("cgroup.procs"), b"").unwrap();
        fs::write(directory.path().join("cgroup.events"), b"populated 0\n").unwrap();
        ensure_linux_cgroup_empty(directory.path()).unwrap();

        fs::write(directory.path().join("cgroup.procs"), b"not-a-pid\n").unwrap();
        assert!(linux_cgroup_pids(directory.path()).is_err());
        fs::write(directory.path().join("cgroup.procs"), b"").unwrap();
        fs::write(directory.path().join("cgroup.events"), b"populated maybe\n").unwrap();
        assert!(linux_cgroup_populated(directory.path()).is_err());
    }

    /// Native acceptance probe for release workers.  It is ignored by the
    /// ordinary suite because it intentionally requires root, cgroup v2
    /// delegation, and a pre-created dedicated account.  CI/cluster runners
    /// invoke it explicitly with `CYC_TEST_HOSTILE_LIVE_UID/GID`.
    #[cfg(target_os = "linux")]
    #[tokio::test]
    #[ignore = "requires root, writable cgroup v2, and a dedicated test identity"]
    async fn linux_live_dedicated_identity_credential_and_residual_reconciliation() {
        use std::sync::atomic::AtomicU8;
        use std::sync::Arc;

        use crate::process::{run_process, DiscardLogSink, LogBudget, ProcessRequest, CANCEL_NONE};
        use crate::security::{prepare_private_directory, write_protected_file, write_secret_file};

        let uid = env::var("CYC_TEST_HOSTILE_LIVE_UID")
            .expect("CYC_TEST_HOSTILE_LIVE_UID")
            .parse::<u32>()
            .unwrap();
        let gid = env::var("CYC_TEST_HOSTILE_LIVE_GID")
            .expect("CYC_TEST_HOSTILE_LIVE_GID")
            .parse::<u32>()
            .unwrap();
        assert_eq!(unsafe { libc::geteuid() }, 0, "live probe must run as root");

        struct Cleanup {
            cgroup: PathBuf,
        }
        impl Drop for Cleanup {
            fn drop(&mut self) {
                env::remove_var(HOSTILE_ISOLATION_CONFIG_ENV);
                let _ = fs::write(self.cgroup.join("cgroup.kill"), b"1\n");
                let _ = fs::remove_dir(&self.cgroup);
            }
        }

        let directory = tempfile::tempdir().unwrap();
        let state = directory.path().join("state");
        let workspace = directory.path().join("workspace");
        prepare_private_directory(&state).unwrap();
        prepare_private_directory(&workspace).unwrap();
        let worker_config_path = state.join("worker.json");
        let credential = state.join("worker.credential");
        write_protected_file(&worker_config_path, b"opaque-test-config\n").unwrap();
        write_secret_file(&credential, "opaque-worker-credential").unwrap();
        let node_id = Uuid::new_v4();
        let cgroup = PathBuf::from(format!("/sys/fs/cgroup/cyc-hostile-{node_id}"));
        let _cleanup = Cleanup {
            cgroup: cgroup.clone(),
        };
        let guard_state = state.join("hostile-reconciliation.json");
        let isolation_path = state.join("hostile-isolation.json");
        let document = IsolationDocument::LinuxCgroupV2 {
            api_version: HOSTILE_ISOLATION_CONFIG_VERSION.to_owned(),
            node_id,
            execution_uid: uid,
            execution_gid: gid,
            cgroup_path: cgroup.clone(),
            guard_state_file: guard_state.clone(),
            pids_max: 64,
        };
        let mut document_bytes = serde_json::to_vec_pretty(&document).unwrap();
        document_bytes.push(b'\n');
        write_protected_file(&isolation_path, &document_bytes).unwrap();
        env::set_var(HOSTILE_ISOLATION_CONFIG_ENV, &isolation_path);

        let worker_config = WorkerConfig {
            api_version: crate::config::WORKER_CONFIG_VERSION.to_owned(),
            worker_url: "https://controller.example.invalid/worker".to_owned(),
            certificate_pem: "test-certificate".to_owned(),
            controller_id: Uuid::new_v4(),
            node_id,
            worker_api_version: "cyc.dev/worker-api/v1".to_owned(),
            heartbeat_interval_seconds: 5,
            lease_seconds: 30,
            workspace_root: workspace.clone(),
            credential_file: credential.clone(),
        };
        let isolation = HostileIsolation::from_environment(Some(node_id)).unwrap();
        isolation
            .validate_worker_boundaries(&worker_config_path, &worker_config)
            .unwrap();
        isolation.reconcile_before_claim().unwrap();
        isolation.verify_before_claim().unwrap();

        let run_id = Uuid::new_v4();
        let root = workspace.join("jobs").join(run_id.to_string());
        let repo = root.join("repo");
        let logs = root.join("logs");
        fs::create_dir_all(&repo).unwrap();
        fs::create_dir(&logs).unwrap();
        let stdout = logs.join("identity.stdout.log");
        let result = run_process(
            ProcessRequest {
                program: OsString::from("sh"),
                arguments: vec![
                    OsString::from("-c"),
                    OsString::from(
                        "printf 'uid=%s gid=%s\\n' \"$(id -u)\" \"$(id -g)\"; \
                         if cat \"$1\" >/dev/null 2>&1; then exit 91; fi; \
                         if cat \"$2\" >/dev/null 2>&1; then exit 92; fi; \
                         if printf '%s\\n' \"$$\" > \"$3\" 2>/dev/null; then exit 93; fi; \
                         printf 'cgroup_escape=blocked\\n'",
                    ),
                    OsString::from("hostile-live"),
                    credential.as_os_str().to_owned(),
                    guard_state.as_os_str().to_owned(),
                    cgroup
                        .parent()
                        .unwrap()
                        .join("cgroup.procs")
                        .as_os_str()
                        .to_owned(),
                ],
                cwd: repo,
                timeout: Duration::from_secs(30),
                stdout_path: stdout.clone(),
                stderr_path: logs.join("identity.stderr.log"),
                log_budget: Arc::new(LogBudget::new(16 * 1024)),
                environment: Vec::new(),
                fault: None,
            },
            Arc::new(AtomicU8::new(CANCEL_NONE)),
            Arc::new(DiscardLogSink),
        )
        .await
        .unwrap();
        assert!(result.succeeded(), "{result:?}");
        assert_eq!(
            fs::read_to_string(&stdout).unwrap(),
            format!("uid={uid} gid={gid}\ncgroup_escape=blocked\n")
        );
        isolation.verify_after_process().unwrap();

        let mut residual = Command::new("sh")
            .args([
                "-c",
                "printf '%s\\n' $$ > \"$1\"; exec sleep 300",
                "residual",
            ])
            .arg(cgroup.join("cgroup.procs"))
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while linux_cgroup_pids(&cgroup).unwrap().is_empty() {
            assert!(Instant::now() < deadline, "residual never entered cgroup");
            thread::sleep(Duration::from_millis(10));
        }
        isolation.reconcile_before_claim().unwrap();
        isolation.verify_before_claim().unwrap();
        let status = residual.wait().unwrap();
        assert!(!status.success(), "residual survived cgroup.kill");
        let receipt: ReconciliationReceipt =
            serde_json::from_slice(&fs::read(&guard_state).unwrap()).unwrap();
        assert!(receipt.residual_processes_killed >= 1);
        assert!(receipt.residual_empty);
    }
}
