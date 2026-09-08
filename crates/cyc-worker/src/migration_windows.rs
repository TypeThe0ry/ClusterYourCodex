//! Windows-only source snapshot held through protected staging.

use super::{relocate_identity_documents, stage_identity_documents, RelocatedIdentityDocuments};
use crate::{config::WorkerConfig, security::LockedMigrationSource};
use anyhow::{Context, Result};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
};

/// Retains deny-write/delete source handles until staging finishes or is dropped.
/// The coordinator must still validate installation ownership metadata, stop the
/// exact old task, and check residual work before calling this. No task is started
/// or stopped here, and no incomplete destination is resumed automatically.
pub struct LockedMigrationInputs {
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
        stage_identity_documents(&self.destination, &self.documents, &self.credentials)
    }
}
