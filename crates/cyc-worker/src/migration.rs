//! Identity conversion and protected staging. Staging never authorizes task
//! switching: source ownership, quiescence and live acceptance remain external.

use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use sha2::{Digest, Sha256};

#[cfg(windows)]
#[path = "migration_windows.rs"]
mod windows;
#[cfg(windows)]
pub use windows::LockedMigrationInputs;

use crate::config::{validate_boot_generation_document, WorkerConfig};
use crate::runtime::{
    migration_credential_inventory, relocate_pairing_ledger, validate_migration_identity_binding,
};

/// Exact source/target binding for a protected transactional copy. Historical
/// credentials may already have been removed by acknowledged pairing cleanup.
/// Do not recreate absent optional files or emit this inventory to public logs.
pub struct MigrationCredential {
    pub source: PathBuf,
    pub target: PathBuf,
    pub sha256: String,
    pub required: bool,
}

/// Caller must persist these through a protected, recoverable transaction.
/// Intentionally not Debug/Serialize: avoid incidental logging of state documents.
pub struct RelocatedIdentityDocuments {
    pub config_json: Vec<u8>,
    pub pairing_ledger_json: Vec<u8>,
    pub boot_generation_json: Vec<u8>,
    pub boot_generation: u64,
    pub credentials: Vec<MigrationCredential>,
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StageReceipt {
    api_version: String,
    phase: String,
    activation_allowed: bool,
    files: Vec<StageFile>,
}

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct StageFile {
    name: String,
    sha256: String,
}

/// Public inspection contains no identities, paths, hashes or credential bytes.
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MigrationStageStatus {
    pub phase: String,
    pub files_verified: usize,
    pub activation_allowed: bool,
}

fn read_stage_file(path: &Path, limit: usize) -> Result<Vec<u8>> {
    use std::io::Read;
    crate::security::ensure_protected_input(path)?;
    let mut bytes = Vec::new();
    std::fs::File::open(path)?
        .take((limit + 1) as u64)
        .read_to_end(&mut bytes)?;
    if bytes.len() > limit {
        bytes.fill(0);
        bail!("migration staged file exceeds size bound");
    }
    Ok(bytes)
}

/// Inspect an interrupted or finished staging directory without mutating it.
/// A copying receipt is never accepted as complete. A staged receipt requires
/// all hashes, strict identity documents and the exact allowed file inventory.
pub fn inspect_migration_stage(new_config: &Path) -> Result<MigrationStageStatus> {
    use std::collections::{BTreeMap, BTreeSet};
    if !new_config.is_absolute()
        || new_config
            .components()
            .any(|part| matches!(part, std::path::Component::ParentDir))
    {
        bail!("migration inspection requires an absolute config path");
    }
    let root = new_config
        .parent()
        .context("migration target has no parent")?;
    let receipt: StageReceipt = serde_json::from_slice(&read_stage_file(
        &root.join(".migration-stage.json"),
        64 * 1024,
    )?)?;
    if receipt.api_version != "cyc.dev/worker-migration-stage/v1"
        || receipt.activation_allowed
        || !matches!(receipt.phase.as_str(), "copying" | "staged")
        || receipt.files.len() > 67
    {
        bail!("unsupported migration staging receipt");
    }
    let mut declared = BTreeMap::new();
    for file in receipt.files {
        if file.name.is_empty()
            || file.name == "."
            || file.name == ".."
            || file.name.contains(['/', '\\', ':'])
            || file.name.chars().any(char::is_control)
            || file.sha256.len() != 64
            || !file
                .sha256
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            || declared.insert(root.join(file.name), file.sha256).is_some()
        {
            bail!("invalid migration staging file entry");
        }
    }
    if receipt.phase == "copying" {
        return Ok(MigrationStageStatus {
            phase: receipt.phase,
            files_verified: 0,
            activation_allowed: false,
        });
    }
    let config: WorkerConfig = serde_json::from_slice(&read_stage_file(new_config, 256 * 1024)?)?;
    config.validate()?;
    let ledger_path = new_config.with_extension("pairing-state.json");
    let ledger = read_stage_file(&ledger_path, 256 * 1024)?;
    let inventory = migration_credential_inventory(&ledger, &config, new_config, new_config)?;
    let boot_path = new_config.with_extension("boot-generation.json");
    validate_boot_generation_document(&read_stage_file(&boot_path, 16 * 1024)?)?;
    let mut allowed = BTreeSet::from([new_config.to_path_buf(), ledger_path, boot_path]);
    for path in &allowed {
        if !declared.contains_key(path) {
            bail!("migration receipt omits a required identity document");
        }
    }
    for entry in inventory {
        let included = declared.contains_key(&entry.target);
        if entry.required && !included {
            bail!("migration receipt omits the current credential");
        }
        if included {
            let mut bytes = read_stage_file(&entry.target, 16 * 1024)?;
            let check = (|| -> Result<()> {
                let value =
                    crate::security::SecretString::new(std::str::from_utf8(&bytes)?.to_owned())?;
                if hex::encode(Sha256::digest(value.expose().as_bytes())) != entry.sha256 {
                    bail!("migration staged credential does not match its ledger");
                }
                Ok(())
            })();
            bytes.fill(0);
            check?;
            allowed.insert(entry.target);
        }
    }
    if declared.keys().cloned().collect::<BTreeSet<_>>() != allowed {
        bail!("migration receipt contains an unexpected file");
    }
    for (path, digest) in &declared {
        let mut bytes = read_stage_file(path, 256 * 1024)?;
        let matches = hex::encode(Sha256::digest(&bytes)) == *digest;
        bytes.fill(0);
        if !matches {
            bail!("migration staged file digest mismatch");
        }
    }
    allowed.insert(root.join(".migration-stage.json"));
    for entry in std::fs::read_dir(root)? {
        if !allowed.contains(&entry?.path()) {
            bail!("migration staging directory contains an unexpected entry");
        }
    }
    Ok(MigrationStageStatus {
        phase: receipt.phase,
        files_verified: declared.len(),
        activation_allowed: false,
    })
}

/// Stage prevalidated documents and caller-held credential bytes in a fresh
/// target directory. Source handles/ACLs and quiescence must be checked by the
/// migration coordinator. Never reads source files, deletes data, or starts a
/// worker. An interrupted directory is retained and must not be adopted by retry.
/// The receipt explicitly distinguishes staging from a completed migration.
pub fn stage_identity_documents(
    new_config: &Path,
    documents: &RelocatedIdentityDocuments,
    credentials: &std::collections::BTreeMap<PathBuf, Vec<u8>>,
) -> Result<()> {
    use crate::security::{
        create_private_directory_new, ensure_protected_input, replace_protected_file,
        write_protected_file, SecretString,
    };
    let root = new_config
        .parent()
        .context("migration target has no parent")?;
    if !new_config.is_absolute()
        || new_config
            .components()
            .any(|part| matches!(part, std::path::Component::ParentDir))
        || std::fs::symlink_metadata(root).is_ok()
    {
        bail!("migration staging requires a fresh absolute target directory");
    }
    let config: WorkerConfig = serde_json::from_slice(&documents.config_json)?;
    config.validate()?;
    validate_migration_identity_binding(&documents.pairing_ledger_json, &config)?;
    let expected = migration_credential_inventory(
        &documents.pairing_ledger_json,
        &config,
        new_config,
        new_config,
    )?;
    if expected.len() != documents.credentials.len()
        || validate_boot_generation_document(&documents.boot_generation_json)?
            != documents.boot_generation
    {
        bail!("migration staging document inventory mismatch");
    }
    let mut writes = std::collections::BTreeMap::<PathBuf, &[u8]>::new();
    writes.insert(new_config.to_path_buf(), &documents.config_json);
    writes.insert(
        new_config.with_extension("pairing-state.json"),
        &documents.pairing_ledger_json,
    );
    writes.insert(
        new_config.with_extension("boot-generation.json"),
        &documents.boot_generation_json,
    );
    let mut used = std::collections::BTreeSet::new();
    let mut targets = std::collections::BTreeSet::new();
    for entry in &documents.credentials {
        if !expected.iter().any(|candidate| {
            candidate.target == entry.target
                && candidate.sha256 == entry.sha256
                && candidate.required == entry.required
        }) || entry.target.parent() != Some(root)
            || !targets.insert(entry.target.clone())
        {
            bail!("migration staging credential binding mismatch");
        }
        match credentials.get(&entry.source) {
            Some(bytes) => {
                if bytes.len() > 16 * 1024 {
                    bail!("migration credential is unexpectedly large");
                }
                let value = SecretString::new(std::str::from_utf8(bytes)?.to_owned())?;
                if hex::encode(Sha256::digest(value.expose().as_bytes())) != entry.sha256 {
                    bail!("migration credential digest mismatch");
                }
                if !used.insert(entry.source.clone())
                    || writes.insert(entry.target.clone(), bytes).is_some()
                {
                    bail!("migration staging has a duplicate credential binding");
                }
            }
            None if entry.required => bail!("migration current credential is missing"),
            None => {}
        }
    }
    if used.len() != credentials.len() {
        bail!("migration received an unreferenced credential");
    }
    if writes
        .keys()
        .any(|path| path.file_name().and_then(|name| name.to_str()).is_none())
    {
        bail!("migration staging filenames must be valid Unicode");
    }
    // Finish all content validation before creating any output.
    create_private_directory_new(root)?;
    let journal = root.join(".migration-stage.json");
    let receipt = |phase: &str| {
        serde_json::to_vec(&serde_json::json!({
            "apiVersion": "cyc.dev/worker-migration-stage/v1",
            "phase": phase, "activationAllowed": false,
            "files": writes.iter().map(|(path, bytes)| serde_json::json!({
                "name": path.file_name().and_then(|name| name.to_str()), "sha256": hex::encode(Sha256::digest(bytes))
            })).collect::<Vec<_>>()
        }))
    };
    write_protected_file(&journal, &receipt("copying")?)?;
    for (path, bytes) in &writes {
        write_protected_file(path, bytes)?;
        ensure_protected_input(path)?;
        if Sha256::digest(std::fs::read(path)?) != Sha256::digest(bytes) {
            bail!("migration staged file verification failed");
        }
    }
    replace_protected_file(&journal, &receipt("staged")?)?;
    Ok(())
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
    let credentials = migration_credential_inventory(ledger_json, &config, old_config, new_config)?;
    let config = config.relocated(old_config, new_config, new_workspace)?;
    let pairing_ledger_json = relocate_pairing_ledger(ledger_json, old_config, new_config)?;
    let boot_generation = validate_boot_generation_document(boot_generation_json)?;
    let config_json = serde_json::to_vec(&config).context("serialize migration config")?;
    if config_json.len() >= 256 * 1024 {
        bail!("migration config exceeds its protected storage bound");
    }
    Ok(RelocatedIdentityDocuments {
        config_json,
        pairing_ledger_json,
        boot_generation_json: boot_generation_json.to_vec(),
        boot_generation,
        credentials,
    })
}
