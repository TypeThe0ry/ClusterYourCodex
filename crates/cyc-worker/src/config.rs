use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use reqwest::Url;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::security::{
    ensure_protected_input, read_secret_file, write_protected_file, SecretString,
};

pub const WORKER_CONFIG_VERSION: &str = "cyc.dev/worker-config/v1";

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EnrollmentBundle {
    pub worker_url: String,
    pub certificate_pem: String,
    pub pairing_code: String,
    #[serde(default)]
    pub controller_id: Option<Uuid>,
}

impl Drop for EnrollmentBundle {
    fn drop(&mut self) {
        unsafe { self.pairing_code.as_bytes_mut().fill(0) };
    }
}

impl EnrollmentBundle {
    pub fn load(path: &Path) -> Result<Self> {
        ensure_protected_input(path)?;
        let raw =
            fs::read(path).with_context(|| format!("read enrollment bundle {}", path.display()))?;
        if raw.len() > 128 * 1024 {
            bail!("enrollment bundle is unexpectedly large");
        }
        let bundle: Self = serde_json::from_slice(&raw).context("parse enrollment bundle JSON")?;
        bundle.validate()?;
        Ok(bundle)
    }

    pub fn validate(&self) -> Result<()> {
        validate_https_url(&self.worker_url)?;
        if self.certificate_pem.trim().is_empty() {
            bail!("enrollment certificatePem must not be empty");
        }
        if self.pairing_code.trim().is_empty() || self.pairing_code.contains(['\r', '\n', '\0']) {
            bail!("enrollment pairingCode is empty or malformed");
        }
        Ok(())
    }
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
        if self.heartbeat_interval_seconds == 0 || self.heartbeat_interval_seconds > 3600 {
            bail!("heartbeatIntervalSeconds must be in 1..=3600");
        }
        if self.lease_seconds < self.heartbeat_interval_seconds || self.lease_seconds > 86_400 {
            bail!("leaseSeconds must cover at least one heartbeat and be <= 86400");
        }
        Ok(())
    }

    pub fn load_credential(&self) -> Result<SecretString> {
        read_secret_file(&self.credential_file)
    }

    pub fn write(&self, path: &Path) -> Result<()> {
        self.validate()?;
        let mut bytes = serde_json::to_vec_pretty(self).context("serialize worker config")?;
        bytes.push(b'\n');
        write_protected_file(path, &bytes)
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
            "workerUrl": "https://controller.lan",
            "certificatePem": "certificate",
            "pairingCode": "code",
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
            "workerUrl": "https://attacker.example.invalid/worker",
            "certificatePem": "attacker-certificate",
            "pairingCode": "prepositioned-code"
        }))
        .unwrap();
        write_protected_file(&enrollment, &bytes).unwrap();
        make_directory_weak(&protected);

        let error = EnrollmentBundle::load(&enrollment).err().unwrap();
        assert!(format!("{error:#}").contains("private directory"));
        assert!(ensure_protected_directory(&protected).is_err());
        assert!(EnrollmentBundle::load(&enrollment).is_err());
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
}
