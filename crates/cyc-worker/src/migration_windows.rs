//! Windows-only source snapshot held through protected staging.

use super::{relocate_identity_documents, stage_identity_documents, RelocatedIdentityDocuments};
use crate::{config::WorkerConfig, security::LockedMigrationSource};
use anyhow::{bail, Context, Result};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
};

/// Retains deny-write/delete source handles until staging finishes or is dropped.
/// The coordinator must still validate installation ownership metadata, stop the
/// exact old task, and check residual work before calling this. No task is started
/// or stopped here, and no incomplete destination is resumed automatically.
pub struct LockedMigrationInputs {
    source_config: PathBuf,
    source_workspace: PathBuf,
    source_owner_sid: String,
    destination: PathBuf,
    documents: RelocatedIdentityDocuments,
    credentials: BTreeMap<PathBuf, Vec<u8>>,
    handles: Vec<LockedMigrationSource>,
}

impl Drop for LockedMigrationInputs {
    fn drop(&mut self) {
        for bytes in self.credentials.values_mut() {
            bytes.fill(0);
        }
    }
}

impl LockedMigrationInputs {
    pub fn open(
        old_config: &Path,
        new_config: &Path,
        new_workspace: &Path,
        expected_old_owner_sid: &str,
    ) -> Result<Self> {
        let mut config_handle = LockedMigrationSource::open(old_config, expected_old_owner_sid)?;
        let config_bytes = config_handle.read_bounded(256 * 1024)?;
        let config: WorkerConfig = serde_json::from_slice(&config_bytes)?;
        config.validate()?;
        verify_residuals(old_config, &config.workspace_root, expected_old_owner_sid)?;
        let mut ledger_handle = LockedMigrationSource::open(
            &old_config.with_extension("pairing-state.json"),
            expected_old_owner_sid,
        )?;
        let ledger_bytes = ledger_handle.read_bounded(256 * 1024)?;
        let mut boot_handle = LockedMigrationSource::open(
            &old_config.with_extension("boot-generation.json"),
            expected_old_owner_sid,
        )?;
        let boot_bytes = boot_handle.read_bounded(16 * 1024)?;
        let documents = relocate_identity_documents(
            &config_bytes,
            &ledger_bytes,
            &boot_bytes,
            old_config,
            new_config,
            new_workspace,
        )?;
        let mut inputs = Self {
            source_config: old_config.to_path_buf(),
            source_workspace: config.workspace_root,
            source_owner_sid: expected_old_owner_sid.to_owned(),
            destination: new_config.to_path_buf(),
            documents,
            credentials: BTreeMap::new(),
            handles: vec![config_handle, ledger_handle, boot_handle],
        };
        for entry in &inputs.documents.credentials {
            match std::fs::symlink_metadata(&entry.source) {
                Err(error) if error.kind() == std::io::ErrorKind::NotFound && !entry.required => {
                    continue
                }
                Err(error) => return Err(error).context("inspect migration source credential"),
                Ok(_) => {}
            }
            let mut handle = LockedMigrationSource::open(&entry.source, expected_old_owner_sid)?;
            let bytes = handle.read_bounded(16 * 1024)?;
            inputs.credentials.insert(entry.source.clone(), bytes);
            inputs.handles.push(handle);
        }
        Ok(inputs)
    }

    /// Consuming self keeps all source handles alive across validation, copying
    /// and receipt persistence, then clears in-memory credential buffers.
    pub fn stage(self) -> Result<()> {
        verify_residuals(
            &self.source_config,
            &self.source_workspace,
            &self.source_owner_sid,
        )?;
        stage_identity_documents(&self.destination, &self.documents, &self.credentials)
    }
}

/// Read-only residual check, repeated immediately before staging. Task stop and
/// external guard reconciliation are still required from the coordinator.
fn verify_residuals(config: &Path, workspace: &Path, owner_sid: &str) -> Result<()> {
    let parent = config.parent().context("migration source has no parent")?;
    for entry in std::fs::read_dir(parent)? {
        let name = entry?.file_name().to_string_lossy().to_ascii_lowercase();
        if name.starts_with(".repair-transaction") || name == ".migration-stage.json" {
            bail!("resolve the existing worker repair or migration transaction first");
        }
    }
    crate::security::verify_migration_directory(workspace, owner_sid)?;
    let marker = workspace.join(".cyc-containment-quarantine.json");
    match std::fs::symlink_metadata(marker) {
        Ok(_) => bail!("resolve worker containment quarantine before migration"),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error).context("inspect migration quarantine"),
    }
    let jobs = workspace.join("jobs");
    match std::fs::symlink_metadata(&jobs) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error).context("inspect migration job roots"),
        Ok(_) => {
            crate::security::ensure_no_windows_reparse_points(&jobs)?;
            if std::fs::read_dir(jobs)?.next().transpose()?.is_some() {
                bail!("resolve retained job roots before migration");
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn residual_preflight_rejects_transactions_quarantine_and_retained_jobs() {
        let temporary = tempfile::tempdir().unwrap();
        let config = temporary.path().join("source/config.json");
        let workspace = temporary.path().join("workspace");
        crate::security::write_protected_file(&config, b"fixture").unwrap();
        crate::security::write_protected_file(&workspace.join("fixture"), b"fixture").unwrap();
        let output = std::process::Command::new("whoami.exe")
            .args(["/user", "/fo", "csv", "/nh"])
            .output()
            .unwrap();
        assert!(output.status.success());
        let identity = String::from_utf8(output.stdout).unwrap();
        let sid = identity
            .split([',', '"'])
            .find(|part| part.starts_with("S-1-"))
            .unwrap();
        verify_residuals(&config, &workspace, sid).unwrap();
        for name in [
            ".repair-transaction",
            ".repair-transaction.new-fixture",
            ".migration-stage.json",
        ] {
            let marker = config.parent().unwrap().join(name);
            crate::security::write_protected_file(&marker, b"incomplete").unwrap();
            assert!(verify_residuals(&config, &workspace, sid).is_err());
            assert_eq!(std::fs::read(&marker).unwrap(), b"incomplete");
            std::fs::remove_file(marker).unwrap();
        }
        let quarantine = workspace.join(".cyc-containment-quarantine.json");
        crate::security::write_protected_file(&quarantine, b"truncated").unwrap();
        assert!(verify_residuals(&config, &workspace, sid).is_err());
        std::fs::remove_file(quarantine).unwrap();
        std::fs::create_dir(workspace.join("jobs")).unwrap();
        std::fs::create_dir(workspace.join("jobs/retained-run")).unwrap();
        assert!(verify_residuals(&config, &workspace, sid).is_err());
        assert!(workspace.join("jobs/retained-run").is_dir());
        std::fs::remove_dir(workspace.join("jobs/retained-run")).unwrap();
        verify_residuals(&config, &workspace, sid).unwrap();
    }
}
