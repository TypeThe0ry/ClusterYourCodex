//! In-memory identity documents for the future journaled migration operation.
//! No function here reads credentials, creates files, or authorizes task switching.

use std::path::Path;

use anyhow::{bail, Context, Result};

use crate::config::{validate_boot_generation_document, WorkerConfig};
use crate::runtime::{relocate_pairing_ledger, validate_migration_identity_binding};

/// Caller must persist these through a protected, recoverable transaction.
/// Intentionally not Debug/Serialize: avoid incidental logging of state documents.
pub struct RelocatedIdentityDocuments {
    pub config_json: Vec<u8>,
    pub pairing_ledger_json: Vec<u8>,
    pub boot_generation_json: Vec<u8>,
    pub boot_generation: u64,
}

/// Validate all documents before returning any target document. Preserve the
/// exact generation bytes so migration does not count as a daemon startup.
/// The caller still owns quiescence, source identity, credential verification,
/// target ACLs, durable journaling, rollback, and live controller verification.
pub fn relocate_identity_documents(
    config_json: &[u8],
    ledger_json: &[u8],
    boot_generation_json: &[u8],
    old_config: &Path,
    new_config: &Path,
    new_workspace: &Path,
) -> Result<RelocatedIdentityDocuments> {
    if config_json.len() > 256 * 1024 {
        bail!("worker config is unexpectedly large");
    }
    let config: WorkerConfig =
        serde_json::from_slice(config_json).context("parse migration config")?;
    validate_migration_identity_binding(ledger_json, &config)?;
    let config = config.relocated(old_config, new_config, new_workspace)?;
    let pairing_ledger_json = relocate_pairing_ledger(ledger_json, old_config, new_config)?;
    let boot_generation = validate_boot_generation_document(boot_generation_json)?;
    Ok(RelocatedIdentityDocuments {
        config_json: serde_json::to_vec(&config).context("serialize migration config")?,
        pairing_ledger_json,
        boot_generation_json: boot_generation_json.to_vec(),
        boot_generation,
    })
}
