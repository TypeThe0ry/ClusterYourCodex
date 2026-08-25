use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use chrono::Utc;
pub use cyc_protocol::onboarding::EnrollmentBundleV1 as EnrollmentBundle;
use reqwest::Url;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::security::{
    ensure_protected_directory, ensure_protected_input, prepare_private_directory,
    read_secret_file, replace_protected_file, write_protected_file, SecretString,
};

pub const WORKER_CONFIG_VERSION: &str = "cyc.dev/worker-config/v1";
const BOOT_GENERATION_STATE_VERSION: &str = "cyc.dev/worker-boot-generation/v1";
// Allocating a generation replaces an ACL-protected state file while holding
// this lock. On Windows, every contender must complete several native DACL
// apply/verify operations in sequence. A 30-second bound was shorter than the
// legitimate serialized work of eight independent daemon starts on a clean
// release runner, so the last valid contender could fail even though the lock
// owner was making progress. Keep the wait bounded, but cover the supported
// contention test and slow first-run ACL initialization.
const BOOT_GENERATION_LOCK_TIMEOUT: Duration = Duration::from_secs(120);
const PAIRING_LOCK_TIMEOUT: Duration = Duration::from_secs(30);

/// RAII ownership of the stable per-config pairing lock.  The lock file is a
/// durable protected inode and is intentionally never unlinked: deleting a
/// lock file would let a second process lock a replacement inode while the
/// first process still owns the old one.
pub struct PairingLock {
    _file: File,
}

/// Acquire the OS-backed pairing lock without blocking a Tokio executor
/// thread.  Callers must keep the returned guard alive across every local and
/// remote step of pair/repair.
pub async fn acquire_pairing_lock(config_path: &Path) -> Result<PairingLock> {
    let config_path = config_path.to_path_buf();
    tokio::task::spawn_blocking(move || {
        acquire_pairing_lock_blocking(&config_path, PAIRING_LOCK_TIMEOUT)
    })
    .await
    .context("pairing lock worker task failed")?
}

fn acquire_pairing_lock_blocking(config_path: &Path, timeout: Duration) -> Result<PairingLock> {
    let parent = config_path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    if let Err(create_error) = prepare_private_directory(parent) {
        // Two first-time pairers can race while provisioning the same parent.
        // The loser consumes it only after the normal verify-only gate proves
        // the winner created the expected private directory.
        if ensure_protected_directory(parent).is_err() {
            return Err(create_error).with_context(|| {
                format!("provision protected pairing directory {}", parent.display())
            });
        }
    }
    ensure_protected_directory(parent)?;
    let lock_path = config_path.with_extension("pair.lock");
    ensure_lock_file(&lock_path, b"cyc pairing lock\n")?;
    let file = acquire_file_lock(&lock_path, timeout, "pairing transaction")?;
    Ok(PairingLock { _file: file })
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct BootGenerationState {
    api_version: String,
    generation: u64,
}

/// Allocate one durable daemon generation under an OS-backed cross-process
/// lock. The protected state file is atomically replaced before the caller may
/// construct a boot id, so a crash can skip a generation but can never reuse
/// one. The returned value always fits SQLite's signed INTEGER domain.
pub fn allocate_boot_generation(config_path: &Path) -> Result<u64> {
    let parent = config_path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    ensure_protected_directory(parent).with_context(|| {
        format!(
            "verify protected boot-generation directory {}",
            parent.display()
        )
    })?;
    let state_path = config_path.with_extension("boot-generation.json");
    let lock_path = config_path.with_extension("boot-generation.lock");
    ensure_lock_file(&lock_path, b"cyc boot generation lock\n")?;
    let _lock = acquire_file_lock(
        &lock_path,
        BOOT_GENERATION_LOCK_TIMEOUT,
        "boot generation state",
    )?;

    let exists = match fs::symlink_metadata(&state_path) {
        Ok(_) => true,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
        Err(error) => {
            return Err(error).with_context(|| {
                format!("inspect boot generation state {}", state_path.display())
            });
        }
    };
    let current = if exists {
        ensure_protected_input(&state_path)?;
        let raw = fs::read(&state_path)
            .with_context(|| format!("read boot generation state {}", state_path.display()))?;
        if raw.len() > 16 * 1024 {
            bail!("boot generation state is unexpectedly large");
        }
        let state: BootGenerationState =
            serde_json::from_slice(&raw).context("parse boot generation state JSON")?;
        if state.api_version != BOOT_GENERATION_STATE_VERSION {
            bail!(
                "unsupported boot generation state apiVersion `{}`",
                state.api_version
            );
        }
        state.generation
    } else {
        0
    };
    let maximum = u64::try_from(i64::MAX).unwrap_or(u64::MAX);
    let generation = current
        .checked_add(1)
        .filter(|generation| *generation <= maximum)
        .context("boot generation exhausted signed 64-bit storage")?;
    let mut bytes = serde_json::to_vec_pretty(&BootGenerationState {
        api_version: BOOT_GENERATION_STATE_VERSION.to_owned(),
        generation,
    })
    .context("serialize boot generation state")?;
    bytes.push(b'\n');
    if exists {
        replace_protected_file(&state_path, &bytes)?;
    } else {
        write_protected_file(&state_path, &bytes)?;
    }
    Ok(generation)
}

fn ensure_lock_file(path: &Path, marker: &[u8]) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(_) => ensure_protected_input(path),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            match write_protected_file(path, marker) {
                Ok(()) => Ok(()),
                // A peer may have won creation. Consume it only after the
                // normal protected-input verification succeeds.
                Err(_) => ensure_protected_input(path),
            }
        }
        Err(error) => {
            Err(error).with_context(|| format!("inspect protected lock file {}", path.display()))
        }
    }
}

fn acquire_file_lock(path: &Path, timeout: Duration, label: &str) -> Result<File> {
    let deadline = Instant::now() + timeout;
    loop {
        #[cfg(windows)]
        let opened = {
            use std::os::windows::fs::OpenOptionsExt;

            let mut options = OpenOptions::new();
            options.read(true).write(true).share_mode(0);
            options.open(path)
        };
        #[cfg(unix)]
        let opened = {
            use std::os::unix::fs::OpenOptionsExt;

            let mut options = OpenOptions::new();
            options.read(true).write(true).mode(0o600);
            options.open(path)
        };
        #[cfg(not(any(unix, windows)))]
        compile_error!("boot-generation locking is not implemented for this platform");

        match opened {
            Ok(file) => {
                #[cfg(unix)]
                {
                    use std::os::fd::AsRawFd;

                    // SAFETY: `file` owns a valid descriptor for the duration
                    // of the call. LOCK_NB avoids an unbounded startup wait.
                    let locked =
                        unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
                    if locked == 0 {
                        return Ok(file);
                    }
                    let error = std::io::Error::last_os_error();
                    if !lock_would_block(&error) {
                        return Err(error)
                            .with_context(|| format!("lock {label} {}", path.display()));
                    }
                }
                #[cfg(windows)]
                return Ok(file);
            }
            Err(error) if cfg!(windows) && lock_would_block(&error) => {}
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("open {label} lock file {}", path.display()));
            }
        }
        if Instant::now() >= deadline {
            bail!("timed out waiting for {label} lock {}", path.display());
        }
        thread::sleep(Duration::from_millis(25));
    }
}

fn lock_would_block(error: &std::io::Error) -> bool {
    matches!(
        error.kind(),
        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::PermissionDenied
    ) || matches!(error.raw_os_error(), Some(11 | 13 | 32 | 33 | 35))
}

pub fn load_enrollment_bundle(path: &Path) -> Result<EnrollmentBundle> {
    ensure_protected_input(path)?;
    let mut raw =
        fs::read(path).with_context(|| format!("read enrollment bundle {}", path.display()))?;
    if raw.len() > 128 * 1024 {
        raw.fill(0);
        bail!("enrollment bundle is unexpectedly large");
    }
    let parsed = serde_json::from_slice(&raw);
    raw.fill(0);
    let bundle: EnrollmentBundle = parsed.context("parse enrollment bundle JSON")?;
    validate_enrollment_bundle(&bundle)?;
    Ok(bundle)
}

pub fn validate_enrollment_bundle(bundle: &EnrollmentBundle) -> Result<()> {
    bundle
        .validate()
        .context("validate shared enrollment contract")?;
    validate_https_url(&bundle.worker_url)?;
    if bundle.expires_at <= Utc::now() {
        bail!("enrollment bundle has expired");
    }
    Ok(())
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkerConfig {
    pub api_version: String,
    pub worker_url: String,
    pub certificate_pem: String,
    pub controller_id: Uuid,
    pub node_id: Uuid,
    pub worker_api_version: String,
    pub heartbeat_interval_seconds: u64,
    pub lease_seconds: u64,
    pub workspace_root: PathBuf,
    pub credential_file: PathBuf,
}

impl WorkerConfig {
    pub fn load(path: &Path) -> Result<Self> {
        ensure_protected_input(path)
            .with_context(|| format!("refuse unprotected worker config {}", path.display()))?;
        let raw = fs::read(path).with_context(|| format!("read config {}", path.display()))?;
        if raw.len() > 256 * 1024 {
            bail!("worker config is unexpectedly large");
        }
        let mut config: Self = serde_json::from_slice(&raw).context("parse worker config JSON")?;
        if config.credential_file.is_relative() {
            let parent = path.parent().unwrap_or_else(|| Path::new("."));
            config.credential_file = parent.join(&config.credential_file);
        }
        if config.workspace_root.is_relative() {
            let parent = path.parent().unwrap_or_else(|| Path::new("."));
            config.workspace_root = parent.join(&config.workspace_root);
        }
        config.validate()?;
        Ok(config)
    }

    pub fn validate(&self) -> Result<()> {
        if self.api_version != WORKER_CONFIG_VERSION {
            bail!(
                "unsupported worker config apiVersion `{}`",
                self.api_version
            );
        }
        validate_https_url(&self.worker_url)?;
        if self.certificate_pem.trim().is_empty() {
            bail!("worker config certificatePem must not be empty");
        }
        if self.worker_api_version.trim().is_empty() {
            bail!("workerApiVersion must not be empty");
        }
        if !self.workspace_root.is_absolute() {
            bail!("workspaceRoot must be absolute");
        }
        if !self.credential_file.is_absolute() {
            bail!("credentialFile must be absolute");
        }
        if self.heartbeat_interval_seconds == 0 || self.heartbeat_interval_seconds > 3600 {
            bail!("heartbeatIntervalSeconds must be in 1..=3600");
        }
        if self.lease_seconds <= self.heartbeat_interval_seconds || self.lease_seconds > 86_400 {
            bail!("leaseSeconds must be greater than heartbeatIntervalSeconds and <= 86400");
        }
        Ok(())
    }

    pub fn load_credential(&self) -> Result<SecretString> {
        read_secret_file(&self.credential_file)
    }

    pub fn write(&self, path: &Path) -> Result<()> {
        self.persist(path, false)
    }

    pub fn replace(&self, path: &Path) -> Result<()> {
        self.persist(path, true)
    }

    fn persist(&self, path: &Path, replace: bool) -> Result<()> {
        self.validate()?;
        let mut bytes = serde_json::to_vec_pretty(self).context("serialize worker config")?;
        bytes.push(b'\n');
        if replace {
            replace_protected_file(path, &bytes)
        } else {
            write_protected_file(path, &bytes)
        }
        .with_context(|| format!("persist protected worker config {}", path.display()))
    }
}

pub fn validate_https_url(raw: &str) -> Result<Url> {
    let url = Url::parse(raw).context("parse worker URL")?;
    if url.scheme() != "https" {
        bail!("worker URL must use HTTPS");
    }
    if url.host_str().is_none() || url.username() != "" || url.password().is_some() {
        bail!("worker URL must contain a host and no embedded credentials");
    }
    if url.query().is_some() || url.fragment().is_some() {
        bail!("worker URL must not contain a query or fragment");
    }
    Ok(url)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::security::{ensure_protected_directory, ensure_protected_input};
    use tempfile::tempdir;

    #[cfg(unix)]
    fn make_directory_weak(path: &Path) {
        use std::os::unix::fs::PermissionsExt;

        fs::set_permissions(path, fs::Permissions::from_mode(0o777)).unwrap();
    }

    #[cfg(windows)]
    fn make_directory_weak(path: &Path) {
        let status = std::process::Command::new("icacls.exe")
            .arg(path)
            .args(["/grant", "*S-1-1-0:(OI)(CI)(R)"])
            .status()
            .unwrap();
        assert!(status.success());
    }

    #[cfg(unix)]
    fn make_file_weak(path: &Path) {
        use std::os::unix::fs::PermissionsExt;

        fs::set_permissions(path, fs::Permissions::from_mode(0o644)).unwrap();
    }

    #[cfg(windows)]
    fn make_file_weak(path: &Path) {
        let status = std::process::Command::new("icacls.exe")
            .arg(path)
            .args(["/grant", "*S-1-1-0:(R)"])
            .status()
            .unwrap();
        assert!(status.success());
    }

    fn sample_config(directory: &Path) -> WorkerConfig {
        WorkerConfig {
            api_version: WORKER_CONFIG_VERSION.to_owned(),
            worker_url: "https://controller.example.invalid/worker".to_owned(),
            certificate_pem: "test-certificate".to_owned(),
            controller_id: Uuid::new_v4(),
            node_id: Uuid::new_v4(),
            worker_api_version: "cyc.dev/worker-api/v1".to_owned(),
            heartbeat_interval_seconds: 5,
            lease_seconds: 30,
            workspace_root: directory.join("workspace"),
            credential_file: directory.join("worker.credential"),
        }
    }

    #[test]
    fn https_is_mandatory_and_url_credentials_are_forbidden() {
        assert!(validate_https_url("http://controller.lan:7443").is_err());
        assert!(validate_https_url("https://user:pass@controller.lan").is_err());
        assert!(validate_https_url("https://controller.lan:7443/worker").is_ok());
    }

    #[test]
    fn enrollment_rejects_unknown_fields() {
        let value = serde_json::json!({
            "apiVersion": cyc_protocol::onboarding::ENROLLMENT_API_VERSION,
            "pairingId": Uuid::new_v4(),
            "controllerId": Uuid::new_v4(),
            "intendedNodeId": Uuid::new_v4(),
            "workerUrl": "https://controller.lan",
            "certificatePem": "certificate",
            "pairingCode": "0123456789abcdef0123456789abcdef",
            "createdAt": Utc::now(),
            "expiresAt": Utc::now() + chrono::Duration::minutes(10),
            "unexpected": true
        });
        assert!(serde_json::from_value::<EnrollmentBundle>(value).is_err());
    }

    #[test]
    fn prepositioned_enrollment_in_a_weak_parent_is_never_repaired_and_trusted() {
        let directory = tempdir().unwrap();
        let protected = directory.path().join("private");
        let enrollment = protected.join("enrollment.json");
        let bytes = serde_json::to_vec(&serde_json::json!({
            "apiVersion": cyc_protocol::onboarding::ENROLLMENT_API_VERSION,
            "pairingId": Uuid::new_v4(),
            "controllerId": Uuid::new_v4(),
            "intendedNodeId": Uuid::new_v4(),
            "workerUrl": "https://attacker.example.invalid/worker",
            "certificatePem": "attacker-certificate",
            "pairingCode": "0123456789abcdef0123456789abcdef",
            "createdAt": Utc::now(),
            "expiresAt": Utc::now() + chrono::Duration::minutes(10)
        }))
        .unwrap();
        write_protected_file(&enrollment, &bytes).unwrap();
        make_directory_weak(&protected);

        let error = load_enrollment_bundle(&enrollment).err().unwrap();
        assert!(format!("{error:#}").contains("private directory"));
        assert!(ensure_protected_directory(&protected).is_err());
        assert!(load_enrollment_bundle(&enrollment).is_err());
    }

    #[test]
    fn worker_config_is_securely_published_and_load_is_verify_only() {
        let directory = tempdir().unwrap();
        let protected = directory.path().join("private");
        let path = protected.join("worker.json");
        let config = sample_config(&protected);
        config.write(&path).unwrap();

        let loaded = WorkerConfig::load(&path).unwrap();
        assert_eq!(loaded.node_id, config.node_id);
        ensure_protected_input(&path).unwrap();

        make_file_weak(&path);
        assert!(WorkerConfig::load(&path).is_err());
        assert!(ensure_protected_input(&path).is_err());
        assert!(WorkerConfig::load(&path).is_err());
    }

    #[test]
    fn heartbeat_must_leave_strict_lease_headroom() {
        let directory = tempdir().unwrap();
        let mut config = sample_config(directory.path());
        config.lease_seconds = config.heartbeat_interval_seconds;
        assert!(config.validate().is_err());
        config.lease_seconds += 1;
        config.validate().unwrap();
    }

    #[test]
    fn boot_generation_survives_restart_and_ignores_orphaned_atomic_temp() {
        let directory = tempdir().unwrap();
        let protected = directory.path().join("private");
        let config_path = protected.join("worker.json");
        sample_config(&protected).write(&config_path).unwrap();

        assert_eq!(allocate_boot_generation(&config_path).unwrap(), 1);
        // A process crash before atomic installation may leave a sibling temp
        // file. It is never interpreted as committed generation state.
        write_protected_file(
            &protected.join(".worker.boot-generation.json.tmp-crash"),
            br#"{"apiVersion":"cyc.dev/worker-boot-generation/v1","generation":999}"#,
        )
        .unwrap();
        assert_eq!(allocate_boot_generation(&config_path).unwrap(), 2);

        let state_path = config_path.with_extension("boot-generation.json");
        let state: BootGenerationState =
            serde_json::from_slice(&fs::read(state_path).unwrap()).unwrap();
        assert_eq!(state.generation, 2);
    }

    #[test]
    fn boot_generation_allocation_is_serialized_across_independent_handles() {
        let directory = tempdir().unwrap();
        let protected = directory.path().join("private");
        let config_path = protected.join("worker.json");
        sample_config(&protected).write(&config_path).unwrap();

        let barrier = std::sync::Arc::new(std::sync::Barrier::new(8));
        let mut threads = Vec::new();
        for _ in 0..8 {
            let barrier = barrier.clone();
            let config_path = config_path.clone();
            threads.push(std::thread::spawn(move || {
                barrier.wait();
                allocate_boot_generation(&config_path).unwrap()
            }));
        }
        let mut generations = threads
            .into_iter()
            .map(|thread| thread.join().unwrap())
            .collect::<Vec<_>>();
        generations.sort_unstable();
        assert_eq!(generations, (1..=8).collect::<Vec<_>>());
        assert_eq!(allocate_boot_generation(&config_path).unwrap(), 9);
    }

    #[test]
    fn pairing_lock_is_stable_persistent_and_serializes_independent_handles() {
        let directory = tempdir().unwrap();
        let protected = directory.path().join("private");
        prepare_private_directory(&protected).unwrap();
        let config_path = protected.join("worker.json");
        let first = acquire_pairing_lock_blocking(&config_path, Duration::from_secs(2)).unwrap();
        let lock_path = config_path.with_extension("pair.lock");
        ensure_protected_input(&lock_path).unwrap();

        // Probe contention synchronously rather than relying on a helper
        // thread being scheduled inside a two-second window.  Full Windows
        // workspace test runs can starve that helper long enough to create a
        // false negative even though the OS lock is behaving correctly.
        let blocked = acquire_pairing_lock_blocking(&config_path, Duration::from_millis(100));
        assert!(
            blocked.is_err(),
            "a second independent handle acquired the pairing lock while it was held"
        );
        drop(first);
        let second = acquire_pairing_lock_blocking(&config_path, Duration::from_secs(10)).unwrap();
        drop(second);

        // Lock release never relies on unlinking the inode.
        assert!(lock_path.is_file());
        ensure_protected_input(&lock_path).unwrap();
    }

    #[test]
    fn pairing_lock_is_released_when_the_owner_unwinds() {
        let directory = tempdir().unwrap();
        let protected = directory.path().join("private");
        prepare_private_directory(&protected).unwrap();
        let config_path = protected.join("worker.json");
        let crashing_path = config_path.clone();
        let crashed = std::thread::spawn(move || {
            let _guard =
                acquire_pairing_lock_blocking(&crashing_path, Duration::from_secs(2)).unwrap();
            panic!("simulated pairing process crash");
        });
        assert!(crashed.join().is_err());

        let recovered =
            acquire_pairing_lock_blocking(&config_path, Duration::from_secs(2)).unwrap();
        drop(recovered);
        assert!(config_path.with_extension("pair.lock").is_file());
    }

    #[test]
    #[ignore = "subprocess helper for cross-process pairing lock tests"]
    fn pairing_lock_process_exit_helper() {
        let Some(config_path) = std::env::var_os("CYC_TEST_PAIR_LOCK_CONFIG") else {
            return;
        };
        let Some(marker_path) = std::env::var_os("CYC_TEST_PAIR_LOCK_MARKER") else {
            return;
        };
        let _guard =
            acquire_pairing_lock_blocking(Path::new(&config_path), Duration::from_secs(2)).unwrap();
        write_protected_file(Path::new(&marker_path), b"locked\n").unwrap();

        if let Some(release_path) = std::env::var_os("CYC_TEST_PAIR_LOCK_RELEASE") {
            let deadline = Instant::now() + Duration::from_secs(60);
            loop {
                match fs::symlink_metadata(Path::new(&release_path)) {
                    Ok(_) => std::process::exit(42),
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                    Err(_) => std::process::exit(43),
                }
                if Instant::now() >= deadline {
                    std::process::exit(44);
                }
                thread::sleep(Duration::from_millis(10));
            }
        }

        // `process::exit` deliberately skips Rust destructors, matching a
        // process crash from the lock guard's point of view. The kernel must
        // close the descriptor/handle and release the OS lock.
        std::process::exit(41);
    }

    #[test]
    fn pairing_lock_is_released_after_process_exit() {
        let directory = tempdir().unwrap();
        let protected = directory.path().join("private");
        prepare_private_directory(&protected).unwrap();
        let config_path = protected.join("worker.json");
        let marker_path = protected.join("pair-lock-child-owned.marker");
        let status = std::process::Command::new(std::env::current_exe().unwrap())
            .arg("--ignored")
            .arg("--exact")
            .arg("config::tests::pairing_lock_process_exit_helper")
            .arg("--test-threads=1")
            .env("CYC_TEST_PAIR_LOCK_CONFIG", &config_path)
            .env("CYC_TEST_PAIR_LOCK_MARKER", &marker_path)
            .status()
            .unwrap();
        assert_eq!(status.code(), Some(41));
        ensure_protected_input(&marker_path).unwrap();

        let recovered =
            acquire_pairing_lock_blocking(&config_path, Duration::from_secs(2)).unwrap();
        drop(recovered);
        let lock_path = config_path.with_extension("pair.lock");
        assert!(lock_path.is_file());
        ensure_protected_input(&lock_path).unwrap();
    }

    #[test]
    fn pairing_lock_contends_across_processes_and_recovers_after_release() {
        let directory = tempdir().unwrap();
        let protected = directory.path().join("private");
        prepare_private_directory(&protected).unwrap();
        let config_path = protected.join("worker.json");
        let marker_path = protected.join("pair-lock-child-owned.marker");
        let release_path = protected.join("pair-lock-child-release.marker");
        let lock_path = config_path.with_extension("pair.lock");
        let mut child = std::process::Command::new(std::env::current_exe().unwrap())
            .arg("--ignored")
            .arg("--exact")
            .arg("config::tests::pairing_lock_process_exit_helper")
            .arg("--test-threads=1")
            .env("CYC_TEST_PAIR_LOCK_CONFIG", &config_path)
            .env("CYC_TEST_PAIR_LOCK_MARKER", &marker_path)
            .env("CYC_TEST_PAIR_LOCK_RELEASE", &release_path)
            .spawn()
            .unwrap();

        // From this point until the child has been released and reaped, keep
        // every observation as data instead of asserting/panicking. That
        // guarantees a failed assertion cannot strand a lock-owning helper.
        let observation = (|| -> std::result::Result<Duration, String> {
            let marker_deadline = Instant::now() + Duration::from_secs(30);
            loop {
                match fs::symlink_metadata(&marker_path) {
                    Ok(_) => break,
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                    Err(error) => return Err(format!("inspect child marker: {error}")),
                }
                match child.try_wait() {
                    Ok(Some(status)) => {
                        return Err(format!(
                            "lock-owning child exited before contention: {status}"
                        ));
                    }
                    Ok(None) => {}
                    Err(error) => return Err(format!("poll lock-owning child: {error}")),
                }
                if Instant::now() >= marker_deadline {
                    return Err("timed out waiting for lock-owning child marker".to_owned());
                }
                thread::sleep(Duration::from_millis(10));
            }

            let started = Instant::now();
            let contention = acquire_file_lock(
                &lock_path,
                Duration::from_millis(250),
                "pairing transaction",
            );
            let elapsed = started.elapsed();
            match contention {
                Ok(file) => {
                    drop(file);
                    Err("parent acquired pair.lock while the child still owned it".to_owned())
                }
                Err(error) => {
                    let detail = format!("{error:#}");
                    if !detail.contains("timed out waiting for pairing transaction lock") {
                        return Err(format!(
                            "contention did not reach bounded timeout: {detail}"
                        ));
                    }
                    if elapsed < Duration::from_millis(200) || elapsed > Duration::from_secs(2) {
                        return Err(format!(
                            "pairing contention timeout was outside its bound: {elapsed:?}"
                        ));
                    }
                    Ok(elapsed)
                }
            }
        })();

        let release_result = write_protected_file(&release_path, b"release\n");
        let child_deadline = Instant::now() + Duration::from_secs(30);
        let mut wait_error = None;
        let mut child_status = None;
        loop {
            match child.try_wait() {
                Ok(Some(status)) => {
                    child_status = Some(status);
                    break;
                }
                Ok(None) => {}
                Err(error) => {
                    wait_error = Some(format!("poll released lock-owning child: {error}"));
                    break;
                }
            }
            if Instant::now() >= child_deadline {
                wait_error = Some("released lock-owning child did not exit".to_owned());
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }
        if child_status.is_none() {
            let _ = child.kill();
            child_status = child.wait().ok();
        }

        // The helper is now definitely reaped (or a best-effort kill+wait was
        // attempted), so failures below cannot leak a child or an OS lock.
        assert!(
            release_result.is_ok(),
            "failed to signal lock-owning child: {release_result:?}"
        );
        assert!(wait_error.is_none(), "{}", wait_error.unwrap_or_default());
        assert_eq!(child_status.and_then(|status| status.code()), Some(42));
        observation.unwrap();

        let recovered =
            acquire_pairing_lock_blocking(&config_path, Duration::from_secs(2)).unwrap();
        drop(recovered);
        assert!(lock_path.is_file());
        ensure_protected_input(&lock_path).unwrap();
    }
}
