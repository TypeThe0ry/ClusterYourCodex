//! Opt-in live SSH provisioning acceptance.
//!
//! This module is intentionally test-only when included by `provisioning.rs`.
//! The test is `#[ignore]` and requires an explicit JSON config through
//! `CYC_PROVISIONING_E2E_CONFIG`.  Secrets are read from private files and are
//! never accepted in the config itself or emitted in the report.

use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Component, Path, PathBuf},
    sync::Arc,
    thread,
    time::Duration,
};

use chrono::Utc;
use cyc_secrets::{CredentialKey, CredentialVault, Secret, StoredCredential, VaultError};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::*;

const CONFIG_ENV: &str = "CYC_PROVISIONING_E2E_CONFIG";
const OUTPUT_OWNERSHIP_MARKER: &str = "ClusterYourCodex live provisioning e2e output v1\n";
const REPORT_NAME: &str = "live-ssh-provisioning-result.json";
const MAX_CONFIG_BYTES: u64 = 64 * 1024;
const MAX_PASSWORD_BYTES: u64 = 16 * 1024;
const DEFAULT_MAX_STEPS: u16 = 120;
const DEFAULT_POLL_INTERVAL_MS: u64 = 2_000;

/// Private configuration for a disposable live acceptance run.
///
/// Deliberately no `password`/`token` fields exist here.  `deny_unknown_fields`
/// makes accidental plaintext secret insertion fail closed.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LiveSshProvisioningConfig {
    /// Explicit opt-in; the ignored test still refuses to run without this.
    allow_live_ssh: bool,
    /// The remote must be disposable because the test installs and removes a worker.
    disposable: bool,
    /// The output directory must carry this exact ownership marker.
    ownership_marker: String,
    host: String,
    port: u16,
    username: String,
    password_file: PathBuf,
    expected_host_key_fingerprint: String,
    controller_token_file: PathBuf,
    data_root: PathBuf,
    install_root: PathBuf,
    output_root: PathBuf,
    #[serde(default = "default_max_steps")]
    max_steps: u16,
    #[serde(default = "default_poll_interval_ms")]
    poll_interval_ms: u64,
}

fn default_max_steps() -> u16 {
    DEFAULT_MAX_STEPS
}

fn default_poll_interval_ms() -> u64 {
    DEFAULT_POLL_INTERVAL_MS
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct LiveSshReport {
    schema: &'static str,
    started_at: String,
    finished_at: String,
    final_state: &'static str,
    paired_node_id: String,
    removed: bool,
    steps: Vec<LiveSshStep>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct LiveSshStep {
    name: String,
    outcome: String,
    state: String,
    revision: u64,
}

#[derive(Debug)]
enum LiveSshHarnessError {
    Config(&'static str),
    Io,
    Initialization(&'static str),
    Provisioning(String),
    Protocol(&'static str),
    Cleanup(&'static str),
}

impl LiveSshHarnessError {
    fn code(&self) -> &str {
        match self {
            Self::Config(code) | Self::Initialization(code) | Self::Protocol(code) => code,
            Self::Io => "io_error",
            Self::Provisioning(code) => code,
            Self::Cleanup(code) => code,
        }
    }
}

fn parse_config_bytes(bytes: &[u8]) -> Result<LiveSshProvisioningConfig, LiveSshHarnessError> {
    if bytes.len() > MAX_CONFIG_BYTES as usize {
        return Err(LiveSshHarnessError::Config("config_too_large"));
    }
    let config: LiveSshProvisioningConfig =
        serde_json::from_slice(bytes).map_err(|_| LiveSshHarnessError::Config("invalid_config"))?;
    validate_config(&config)?;
    Ok(config)
}

fn validate_config(config: &LiveSshProvisioningConfig) -> Result<(), LiveSshHarnessError> {
    if !config.allow_live_ssh || !config.disposable {
        return Err(LiveSshHarnessError::Config(
            "explicit_live_disposable_opt_in_required",
        ));
    }
    if config.ownership_marker != OUTPUT_OWNERSHIP_MARKER.trim_end_matches('\n') {
        return Err(LiveSshHarnessError::Config(
            "output_ownership_marker_required",
        ));
    }
    if config.host.trim().is_empty()
        || config.host.len() > 255
        || config.username.trim().is_empty()
        || config.username.len() > 128
        || config.port == 0
    {
        return Err(LiveSshHarnessError::Config("invalid_endpoint"));
    }
    if !config
        .expected_host_key_fingerprint
        .strip_prefix("SHA256:")
        .is_some_and(|value| {
            !value.is_empty()
                && value.len() <= 128
                && value
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'+' | b'/' | b'='))
        })
    {
        return Err(LiveSshHarnessError::Config(
            "invalid_expected_host_key_fingerprint",
        ));
    }
    for (field, path) in [
        ("password_file", &config.password_file),
        ("controller_token_file", &config.controller_token_file),
        ("data_root", &config.data_root),
        ("install_root", &config.install_root),
        ("output_root", &config.output_root),
    ] {
        validate_absolute_path(field, path)?;
    }
    if config.password_file == config.controller_token_file
        || config.data_root == config.output_root
        || config.max_steps == 0
        || config.max_steps > 256
        || config.poll_interval_ms > 60_000
    {
        return Err(LiveSshHarnessError::Config("invalid_run_limits_or_paths"));
    }
    Ok(())
}

fn validate_absolute_path(_field: &'static str, path: &Path) -> Result<(), LiveSshHarnessError> {
    if !path.is_absolute()
        || path
            .components()
            .any(|component| matches!(component, Component::ParentDir))
    {
        return Err(LiveSshHarnessError::Config(
            "path_must_be_absolute_without_parent",
        ));
    }
    Ok(())
}

fn read_private_file(path: &Path, maximum: u64) -> Result<Vec<u8>, LiveSshHarnessError> {
    let metadata = fs::symlink_metadata(path).map_err(|_| LiveSshHarnessError::Io)?;
    if !metadata.file_type().is_file() || metadata.len() > maximum {
        return Err(LiveSshHarnessError::Config("private_file_invalid"));
    }
    let mut file = File::open(path).map_err(|_| LiveSshHarnessError::Io)?;
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    (&mut file)
        .take(maximum + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| LiveSshHarnessError::Io)?;
    if bytes.len() as u64 > maximum {
        return Err(LiveSshHarnessError::Config("private_file_too_large"));
    }
    Ok(bytes)
}

fn read_password(path: &Path) -> Result<String, LiveSshHarnessError> {
    let bytes = read_private_file(path, MAX_PASSWORD_BYTES)?;
    let mut password =
        String::from_utf8(bytes).map_err(|_| LiveSshHarnessError::Config("password_not_utf8"))?;
    while matches!(password.as_bytes().last(), Some(b'\r' | b'\n')) {
        password.pop();
    }
    if password.is_empty() {
        return Err(LiveSshHarnessError::Config("password_empty"));
    }
    Ok(password)
}

fn ensure_owned_output_root(path: &Path) -> Result<(), LiveSshHarnessError> {
    let created = if path.exists() {
        let metadata = fs::symlink_metadata(path).map_err(|_| LiveSshHarnessError::Io)?;
        if !metadata.file_type().is_dir() {
            return Err(LiveSshHarnessError::Config("output_root_not_directory"));
        }
        false
    } else {
        fs::create_dir_all(path).map_err(|_| LiveSshHarnessError::Io)?;
        true
    };
    let marker = path.join(".cyc-live-provisioning-e2e-owned");
    if created {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&marker)
            .map_err(|_| LiveSshHarnessError::Io)?;
        file.write_all(OUTPUT_OWNERSHIP_MARKER.as_bytes())
            .map_err(|_| LiveSshHarnessError::Io)?;
    } else {
        let bytes = read_private_file(&marker, 256)?;
        if bytes != OUTPUT_OWNERSHIP_MARKER.as_bytes() {
            return Err(LiveSshHarnessError::Config("output_root_not_owned"));
        }
    }
    Ok(())
}

fn manager_for_live_run(
    config: &LiveSshProvisioningConfig,
) -> Result<ProvisioningManager, LiveSshHarnessError> {
    fs::create_dir_all(&config.data_root).map_err(|_| LiveSshHarnessError::Io)?;
    let store = ProvisioningStore::open(config.data_root.join(PROVISIONING_DATABASE))
        .map_err(|_| LiveSshHarnessError::Initialization("provisioning_store_unavailable"))?;
    let controller = Arc::new(
        HttpControllerBoundary::new(config.controller_token_file.clone())
            .map_err(|error| LiveSshHarnessError::Initialization(error.public_code()))?,
    );
    let catalog = WorkerKitCatalog::from_install_root(&config.install_root)
        .map_err(|_| LiveSshHarnessError::Initialization("worker_kit_catalog_unavailable"))?;
    let transient_secrets = Arc::new(SessionSecretStore::default());
    let driver = SshProvisioningDriver::new(
        Arc::new(Ssh2Transport::default()),
        // The acceptance run is deliberately session-only.  A no-op vault
        // keeps it portable to Linux/macOS and prevents test credentials from
        // being persisted even on Windows.
        Arc::new(SessionOnlyVault),
        transient_secrets.clone(),
        controller.clone(),
        catalog,
        SshDriverOptions::default(),
    );
    Ok(ProvisioningManager::from_parts_with_policy(
        ProvisioningEngine::new(store),
        Box::new(driver),
        transient_secrets,
        Some(controller),
    ))
}

struct SessionOnlyVault;

impl CredentialVault for SessionOnlyVault {
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
        Ok(false)
    }
}

fn capture_step(
    steps: &mut Vec<LiveSshStep>,
    name: impl Into<String>,
    result: &ProvisioningOperationResult,
) -> Result<(), LiveSshHarnessError> {
    let computer = result
        .computer
        .as_ref()
        .ok_or(LiveSshHarnessError::Protocol("missing_computer_result"))?;
    steps.push(LiveSshStep {
        name: name.into(),
        outcome: result.outcome.to_owned(),
        state: computer.state.to_owned(),
        revision: computer.revision,
    });
    Ok(())
}

fn current_computer(
    result: &ProvisioningOperationResult,
) -> Result<&ProvisioningComputerView, LiveSshHarnessError> {
    result
        .computer
        .as_ref()
        .ok_or(LiveSshHarnessError::Protocol("missing_computer_result"))
}

fn provisioning_error(error: PublicProvisioningError) -> LiveSshHarnessError {
    LiveSshHarnessError::Provisioning(error.code)
}

fn remove_record(
    manager: &ProvisioningManager,
    id: &str,
    revision: u64,
    password: &str,
) -> Result<(), LiveSshHarnessError> {
    let result = manager
        .remove(SecretActionRequest {
            id: id.to_owned(),
            revision,
            password: password.to_owned(),
            passphrase: String::new(),
        })
        .map_err(provisioning_error)?;
    if result.outcome != "removed" {
        return Err(LiveSshHarnessError::Cleanup("remove_did_not_complete"));
    }
    match manager.get(ComputerIdRequest { id: id.to_owned() }) {
        Err(error) if error.code == "not_found" => Ok(()),
        Ok(_) => Err(LiveSshHarnessError::Cleanup("record_remains_after_remove")),
        Err(_) => Err(LiveSshHarnessError::Cleanup("remove_verification_failed")),
    }
}

fn write_report(output_root: &Path, report: &LiveSshReport) -> Result<(), LiveSshHarnessError> {
    let report_path = output_root.join(REPORT_NAME);
    let temporary = output_root.join(".live-ssh-provisioning-result.tmp");
    let bytes = serde_json::to_vec_pretty(report)
        .map_err(|_| LiveSshHarnessError::Protocol("report_serialization_failed"))?;
    let mut file = File::create(&temporary).map_err(|_| LiveSshHarnessError::Io)?;
    file.write_all(&bytes)
        .map_err(|_| LiveSshHarnessError::Io)?;
    file.sync_all().map_err(|_| LiveSshHarnessError::Io)?;
    fs::rename(&temporary, &report_path).map_err(|_| LiveSshHarnessError::Io)?;
    Ok(())
}

fn run_live_ssh_provisioning(
    config: LiveSshProvisioningConfig,
) -> Result<LiveSshReport, LiveSshHarnessError> {
    ensure_owned_output_root(&config.output_root)?;
    let password = read_password(&config.password_file)?;
    let manager = manager_for_live_run(&config)?;
    let id = Uuid::new_v4();
    let intended_node_id = Uuid::new_v4();
    let started_at = Utc::now().to_rfc3339();
    let mut steps = Vec::new();
    let mut result = manager
        .start(StartComputerRequest {
            record_id: id.to_string(),
            intended_node_id: intended_node_id.to_string(),
            display_name: "live-ssh-e2e".to_owned(),
            host: config.host.clone(),
            port: config.port,
            username: config.username.clone(),
            authentication_method: SshAuthenticationMethodInput::Password,
            private_key_path: String::new(),
            password: password.clone(),
            passphrase: String::new(),
            remember_password: false,
            advanced: AdvancedOptionsRequest::default(),
        })
        .map_err(provisioning_error)?;
    capture_step(&mut steps, "start", &result)?;

    let run_result = (|| -> Result<(String, &'static str, u64), LiveSshHarnessError> {
        for index in 0..=config.max_steps {
            let outcome = result.outcome;
            let computer = current_computer(&result)?;
            let revision = computer.revision;
            match outcome {
                "awaiting_host_key_approval" => {
                    let host_key = computer
                        .host_key
                        .as_ref()
                        .ok_or(LiveSshHarnessError::Protocol("missing_host_key"))?;
                    if host_key.fingerprint != config.expected_host_key_fingerprint {
                        return Err(LiveSshHarnessError::Protocol(
                            "host_key_fingerprint_mismatch",
                        ));
                    }
                    result = manager
                        .approve_host_key(ApproveHostKeyRequest {
                            id: id.to_string(),
                            revision,
                            fingerprint: host_key.fingerprint.clone(),
                        })
                        .map_err(provisioning_error)?;
                    capture_step(&mut steps, "approve_host_key", &result)?;
                }
                "ready" => {
                    let node_id = computer
                        .paired_node_id
                        .clone()
                        .ok_or(LiveSshHarnessError::Protocol("ready_without_paired_node"))?;
                    return Ok((node_id, computer.state, computer.revision));
                }
                "failed" => {
                    let code = computer
                        .failure
                        .as_ref()
                        .map(|failure| failure.code.as_str())
                        .unwrap_or("provisioning_failed");
                    return Err(LiveSshHarnessError::Provisioning(code.to_owned()));
                }
                "awaiting_credential" | "checkpoint" | "awaiting_external" => {
                    result = manager
                        .continue_provisioning(SecretActionRequest {
                            id: id.to_string(),
                            revision,
                            password: if outcome == "awaiting_credential" {
                                password.clone()
                            } else {
                                String::new()
                            },
                            passphrase: String::new(),
                        })
                        .map_err(provisioning_error)?;
                    capture_step(&mut steps, format!("continue_{}", index + 1), &result)?;
                }
                _ => {
                    return Err(LiveSshHarnessError::Protocol(
                        "unexpected_provisioning_outcome",
                    ))
                }
            }
            if config.poll_interval_ms != 0 {
                thread::sleep(Duration::from_millis(config.poll_interval_ms));
            }
        }
        Err(LiveSshHarnessError::Protocol("provisioning_step_limit"))
    })();

    let cleanup_revision = manager
        .get(ComputerIdRequest { id: id.to_string() })
        .map(|computer| computer.revision);
    let cleanup_result = cleanup_revision
        .map(|revision| remove_record(&manager, &id.to_string(), revision, &password))
        .unwrap_or(Ok(()));
    cleanup_result?;

    let (paired_node_id, final_state, _revision) = run_result?;
    let report = LiveSshReport {
        schema: "cyc.dev/live-ssh-provisioning-e2e/v1",
        started_at,
        finished_at: Utc::now().to_rfc3339(),
        final_state,
        paired_node_id,
        removed: true,
        steps,
    };
    write_report(&config.output_root, &report)?;
    Ok(report)
}

#[test]
#[ignore = "requires explicit CYC_PROVISIONING_E2E_CONFIG and a disposable SSH host"]
fn live_ssh_provisioning() {
    let config_path = match std::env::var_os(CONFIG_ENV) {
        Some(path) => PathBuf::from(path),
        None => panic!("{CONFIG_ENV} is required for the ignored live acceptance test"),
    };
    let bytes = read_private_file(&config_path, MAX_CONFIG_BYTES)
        .unwrap_or_else(|error| panic!("live SSH config read failed: {}", error.code()));
    let config = parse_config_bytes(&bytes)
        .unwrap_or_else(|error| panic!("live SSH config rejected: {}", error.code()));
    match run_live_ssh_provisioning(config) {
        // Do not log report fields here. The configuration carries secret-file
        // taint through the live run; keeping the test silent makes it
        // impossible for a future report field to become a log sink.
        Ok(_report) => {}
        Err(error) => panic!("live SSH provisioning failed: {}", error.code()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid_config_json() -> serde_json::Value {
        serde_json::json!({
            "allowLiveSsh": true,
            "disposable": true,
            "ownershipMarker": OUTPUT_OWNERSHIP_MARKER.trim_end_matches('\n'),
            "host": "192.0.2.10",
            "port": 22,
            "username": "builder",
            "passwordFile": "C:\\private\\password.txt",
            "expectedHostKeyFingerprint": "SHA256:abcDEF123+/=",
            "controllerTokenFile": "C:\\private\\token.txt",
            "dataRoot": "D:\\cyc-e2e\\data",
            "installRoot": "D:\\cyc-e2e\\install",
            "outputRoot": "D:\\cyc-e2e\\output",
        })
    }

    #[test]
    fn config_requires_explicit_live_and_disposable_markers() {
        let mut value = valid_config_json();
        value["allowLiveSsh"] = serde_json::Value::Bool(false);
        let bytes = serde_json::to_vec(&value).expect("json");
        assert!(matches!(
            parse_config_bytes(&bytes),
            Err(LiveSshHarnessError::Config(
                "explicit_live_disposable_opt_in_required"
            ))
        ));
    }

    #[test]
    fn config_rejects_plaintext_secret_fields() {
        let mut value = valid_config_json();
        value["password"] = serde_json::Value::String("must-not-be-accepted".to_owned());
        let bytes = serde_json::to_vec(&value).expect("json");
        assert!(matches!(
            parse_config_bytes(&bytes),
            Err(LiveSshHarnessError::Config("invalid_config"))
        ));
    }

    #[test]
    fn fingerprint_must_be_explicit_sha256_value() {
        let mut value = valid_config_json();
        value["expectedHostKeyFingerprint"] = serde_json::Value::String("observed".to_owned());
        let bytes = serde_json::to_vec(&value).expect("json");
        assert!(matches!(
            parse_config_bytes(&bytes),
            Err(LiveSshHarnessError::Config(
                "invalid_expected_host_key_fingerprint"
            ))
        ));
    }
}
