use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::fs::{self, OpenOptions};
use std::future::Future;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, AtomicU8, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use cyc_protocol::worker::{
    ArtifactMetadata, ClaimAssignment, ClaimRequest, ExecutionEvidence, ExecutionSourceEvidence,
    HeartbeatRequest, PairAckRequest, PairRequest, RunCompletion, RunEvidence, RunStreamsEvidence,
    StateUpdate, TerminationEvidence, TerminationReason, WORKER_API_VERSION,
};
use cyc_protocol::{
    canonical_job_digest, CleanupReceiptV1, JobRootCleanupOutcomeV1, JobState, NodeInventory,
    TerminalCompletionAckV1, CLEANUP_API_VERSION,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::sync::Mutex;

use crate::artifacts::{collect_artifacts, ArtifactEvidence, MAX_ARTIFACT_BYTES};
use crate::config::{
    acquire_pairing_lock, allocate_boot_generation, load_enrollment_bundle, EnrollmentBundle,
    WorkerConfig, WORKER_CONFIG_VERSION,
};
use crate::executor::{execute_steps, write_result, StepsOutcome};
use crate::http::{pairing_terminal_code, HttpLogSink, RunSession, VersionConflict, WorkerClient};
use crate::isolation::HostileIsolation;
use crate::process::{
    ensure_process_containment_available, LogBudget, LogSink, ProcessTerminationReason,
    CANCEL_JOB_TIMEOUT, CANCEL_LEASE_LOST, CANCEL_NONE, CANCEL_REQUESTED, CANCEL_TRANSPORT_FAILURE,
};
use crate::security::{
    ensure_no_windows_reparse_points, ensure_protected_directory, ensure_protected_input,
    prepare_private_directory, read_secret_file, remove_protected_file, replace_protected_file,
    write_protected_file, write_secret_file, SecretString,
};
use crate::source::{prepare_job, PrepareJobError, PreparedJob, SourceContainment, SourceEvidence};
use crate::{probe_at_or_conservative, NodeSampler};

const CONTAINMENT_QUARANTINE_FILE: &str = ".cyc-containment-quarantine.json";
const ACTIVE_RUN_GUARD_VERSION: &str = "cyc.dev/active-run-guard/v1";
const ACTIVE_RUN_GUARD_REASON: &str = "active_run_pending_terminal_ack";
const NODE_REPORT_INTERVAL: Duration = Duration::from_secs(5);
const PAIRING_LEDGER_VERSION: &str = "cyc.dev/worker-pairing-state/v1";
const MAX_PAIRING_LEDGER_BYTES: usize = 256 * 1024;
const MAX_PAIRING_LEDGER_RECORDS: usize = 32;
// `acquire_pairing_lock` keeps each OS-level probe bounded so a permanently
// wedged peer cannot block a worker forever. A real pair/repair transaction
// can legitimately hold that lock longer than one probe on Windows, where
// each protected-file replacement re-applies and verifies a DACL. Retry only
// the specific bounded-timeout result here so callers get a longer bounded
// transaction wait without weakening lock ownership or sharing a lock inode.
const PAIRING_TRANSACTION_WAIT_TIMEOUT: Duration = Duration::from_secs(120);
const PAIRING_TRANSACTION_RETRY_DELAY: Duration = Duration::from_millis(25);

#[derive(Default)]
struct WorkerActivity {
    active_run_ids: StdMutex<BTreeSet<uuid::Uuid>>,
}

/// Inventory is acknowledged state, not fire-and-forget telemetry. Keep
/// sending it until a report carrying the exact document succeeds; only then
/// may steady-state reports omit it. A changed document follows the same
/// retry-until-accepted rule.
#[derive(Default)]
struct InventoryPublicationState {
    accepted: Option<NodeInventory>,
}

impl InventoryPublicationState {
    fn prepare(
        &self,
        mut report: cyc_protocol::worker::NodeReportRequest,
    ) -> cyc_protocol::worker::NodeReportRequest {
        if report
            .inventory
            .as_ref()
            .is_some_and(|inventory| self.accepted.as_ref() == Some(inventory))
        {
            report.inventory = None;
        }
        report
    }

    fn record_success(&mut self, report: &cyc_protocol::worker::NodeReportRequest) {
        if let Some(inventory) = &report.inventory {
            self.accepted = Some(inventory.clone());
        }
    }

    fn invalidate(&mut self) {
        // A negative or missing acknowledgement means the controller may no
        // longer have the inventory document we previously published (for
        // example after restore/failover). Force the next report to carry the
        // complete inventory again instead of relying on stale local state.
        self.accepted = None;
    }
}

impl WorkerActivity {
    fn begin(&self, run_id: uuid::Uuid) -> Result<()> {
        let mut active = self
            .active_run_ids
            .lock()
            .map_err(|_| anyhow::anyhow!("worker activity state is poisoned"))?;
        if !active.is_empty() || !active.insert(run_id) {
            bail!("one-slot worker already has an active run");
        }
        Ok(())
    }

    fn end(&self, run_id: uuid::Uuid) -> Result<()> {
        let mut active = self
            .active_run_ids
            .lock()
            .map_err(|_| anyhow::anyhow!("worker activity state is poisoned"))?;
        if !active.remove(&run_id) {
            bail!("active run was not present in worker activity state");
        }
        Ok(())
    }

    fn sample(&self, sampler: &mut NodeSampler) -> Result<cyc_protocol::worker::NodeReportRequest> {
        // Keep this gate held through the synchronous sample. An assignment
        // cannot become active between the empty-set decision and an optional
        // nvidia-smi helper spawn.
        let active = self
            .active_run_ids
            .lock()
            .map_err(|_| anyhow::anyhow!("worker activity state is poisoned"))?;
        let ids = active.iter().copied().collect::<Vec<_>>();
        sampler.sample(&ids)
    }
}

#[derive(Clone, Debug, Default)]
pub struct PairOptions {
    pub workspace_root: Option<PathBuf>,
    pub repair: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum PairingCredentialState {
    Staged,
    PairRequestUnknown,
    PairAccepted,
    ConfigCommitted,
    Acknowledged,
    TerminalUnavailable,
    Superseded,
    Expired,
}

impl PairingCredentialState {
    fn deletes_staged_credential(self) -> bool {
        matches!(
            self,
            Self::TerminalUnavailable | Self::Superseded | Self::Expired
        )
    }

    fn has_uncertain_remote_state(self) -> bool {
        matches!(
            self,
            Self::PairRequestUnknown | Self::PairAccepted | Self::ConfigCommitted
        )
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PairingCredentialRecord {
    pairing_id: uuid::Uuid,
    controller_id: uuid::Uuid,
    node_id: uuid::Uuid,
    credential_file: PathBuf,
    credential_sha256: String,
    created_at: DateTime<Utc>,
    expires_at: DateTime<Utc>,
    state: PairingCredentialState,
    #[serde(skip_serializing_if = "Option::is_none")]
    previous_credential_file: Option<PathBuf>,
    #[serde(skip_serializing_if = "Option::is_none")]
    previous_credential_sha256: Option<String>,
    #[serde(default)]
    previous_cleanup_pending: bool,
    cleanup_pending: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PairingCredentialLedger {
    api_version: String,
    records: Vec<PairingCredentialRecord>,
}

impl PairingCredentialLedger {
    fn empty() -> Self {
        Self {
            api_version: PAIRING_LEDGER_VERSION.to_owned(),
            records: Vec::new(),
        }
    }

    fn path(config_path: &Path) -> PathBuf {
        config_path.with_extension("pairing-state.json")
    }

    fn load(config_path: &Path) -> Result<Self> {
        let path = Self::path(config_path);
        if !path_entry_exists(&path)? {
            return Ok(Self::empty());
        }
        ensure_protected_input(&path)
            .with_context(|| format!("verify protected pairing ledger {}", path.display()))?;
        let bytes = fs::read(&path)
            .with_context(|| format!("read protected pairing ledger {}", path.display()))?;
        if bytes.len() > MAX_PAIRING_LEDGER_BYTES {
            bail!("pairing ledger is unexpectedly large");
        }
        let ledger: Self =
            serde_json::from_slice(&bytes).context("parse strict pairing ledger JSON")?;
        ledger.validate(config_path)?;
        Ok(ledger)
    }

    fn persist(&self, config_path: &Path) -> Result<()> {
        self.validate(config_path)?;
        let path = Self::path(config_path);
        let mut bytes = serde_json::to_vec_pretty(self).context("serialize pairing ledger")?;
        if bytes.len() >= MAX_PAIRING_LEDGER_BYTES {
            bytes.fill(0);
            bail!("pairing ledger exceeds its protected storage bound");
        }
        bytes.push(b'\n');
        let result = if path_entry_exists(&path)? {
            replace_protected_file(&path, &bytes)
        } else {
            write_protected_file(&path, &bytes)
        };
        bytes.fill(0);
        result.with_context(|| format!("persist protected pairing ledger {}", path.display()))
    }

    fn validate(&self, config_path: &Path) -> Result<()> {
        if self.api_version != PAIRING_LEDGER_VERSION {
            bail!(
                "unsupported pairing ledger apiVersion `{}`",
                self.api_version
            );
        }
        if self.records.len() > MAX_PAIRING_LEDGER_RECORDS {
            bail!("pairing ledger contains too many records");
        }
        let mut pairing_ids = BTreeSet::new();
        let mut staged_paths = BTreeSet::new();
        for record in &self.records {
            if record.pairing_id.is_nil()
                || record.controller_id.is_nil()
                || record.node_id.is_nil()
            {
                bail!("pairing ledger contains a nil identifier");
            }
            if !pairing_ids.insert(record.pairing_id) {
                bail!("pairing ledger contains a duplicate pairingId");
            }
            if !staged_paths.insert(record.credential_file.clone()) {
                bail!("pairing ledger contains a duplicate staged credential path");
            }
            let expected = config_path.with_extension(format!("{}.credential", record.pairing_id));
            if record.credential_file != expected {
                bail!("pairing ledger staged credential path is not pairing-owned");
            }
            validate_ledger_credential_path(config_path, &record.credential_file)?;
            validate_credential_digest(&record.credential_sha256)?;
            if record.expires_at <= record.created_at {
                bail!("pairing ledger contains an invalid expiry range");
            }
            match (
                &record.previous_credential_file,
                &record.previous_credential_sha256,
            ) {
                (Some(path), Some(digest)) => {
                    if path == &record.credential_file {
                        bail!("pairing ledger previous credential aliases the staged credential");
                    }
                    validate_ledger_credential_path(config_path, path)?;
                    validate_credential_digest(digest)?;
                }
                (None, None) => {}
                _ => bail!("pairing ledger previous credential binding is incomplete"),
            }
            if record.previous_cleanup_pending && record.previous_credential_file.is_none() {
                bail!("pairing has previous cleanup pending without a previous credential");
            }
            if record.state == PairingCredentialState::Acknowledged && record.cleanup_pending {
                bail!("acknowledged pairing cannot delete its current credential");
            }
        }
        Ok(())
    }

    fn record(&self, pairing_id: uuid::Uuid) -> Option<&PairingCredentialRecord> {
        self.records
            .iter()
            .find(|record| record.pairing_id == pairing_id)
    }

    fn record_mut(&mut self, pairing_id: uuid::Uuid) -> Option<&mut PairingCredentialRecord> {
        self.records
            .iter_mut()
            .find(|record| record.pairing_id == pairing_id)
    }

    /// Reconcile only records belonging to this authenticated enrollment
    /// binding.  A different controller/node namespace is never garbage
    /// collected as a side effect of the current invocation.
    fn prepare_invocation(
        &mut self,
        config_path: &Path,
        enrollment: &EnrollmentBundle,
        current_config: Option<&WorkerConfig>,
    ) -> Result<()> {
        let current_path = current_config.map(|config| config.credential_file.as_path());
        for record in &mut self.records {
            let same_binding = record.controller_id == enrollment.controller_id
                && record.node_id == enrollment.intended_node_id;
            let owns_existing_file = path_entry_exists(&record.credential_file)?
                || match &record.previous_credential_file {
                    Some(path) => path_entry_exists(path)?,
                    None => false,
                };
            if !same_binding && owns_existing_file {
                bail!("pairing ledger contains protected state for a different controller or node");
            }
            if !same_binding || record.pairing_id == enrollment.pairing_id {
                continue;
            }
            if record.state == PairingCredentialState::Staged
                && current_path != Some(record.credential_file.as_path())
            {
                record.state = if record.expires_at <= Utc::now() {
                    PairingCredentialState::Expired
                } else {
                    PairingCredentialState::Superseded
                };
                record.cleanup_pending = true;
            }
        }
        self.persist(config_path)
    }

    fn transition(
        &mut self,
        config_path: &Path,
        pairing_id: uuid::Uuid,
        state: PairingCredentialState,
    ) -> Result<()> {
        let record = self
            .record_mut(pairing_id)
            .context("pairing ledger record disappeared")?;
        record.state = state;
        if state.deletes_staged_credential() {
            record.cleanup_pending = true;
        }
        self.persist(config_path)
    }

    fn mark_terminal_ack(&mut self, config_path: &Path, pairing_id: uuid::Uuid) -> Result<()> {
        let record = self
            .record_mut(pairing_id)
            .context("pairing ledger record disappeared after terminal acknowledgement")?;
        record.state = PairingCredentialState::TerminalUnavailable;
        // The committed credential is terminal but remains protected while it
        // is current. Its predecessor is not eligible for deletion until a
        // later acknowledged repair supersedes this record.
        record.cleanup_pending = true;
        record.previous_cleanup_pending = record.previous_credential_file.is_some();
        self.persist(config_path)
    }

    fn acknowledge_and_supersede(
        &mut self,
        config_path: &Path,
        pairing_id: uuid::Uuid,
    ) -> Result<()> {
        let (controller_id, node_id) = {
            let current = self
                .record(pairing_id)
                .context("pairing ledger record disappeared before acknowledgement")?;
            (current.controller_id, current.node_id)
        };
        for record in &mut self.records {
            if record.pairing_id == pairing_id {
                record.state = PairingCredentialState::Acknowledged;
                record.cleanup_pending = false;
                record.previous_cleanup_pending = record.previous_credential_file.is_some();
            } else if record.controller_id == controller_id && record.node_id == node_id {
                // A successful controller ACK transaction revokes every other
                // credential/pending enrollment for this stable node.
                record.state = PairingCredentialState::Superseded;
                record.cleanup_pending = true;
                // Preserve a prior committed-config cleanup obligation. It
                // becomes eligible only now that an acknowledged successor
                // exists; a pre-commit terminal record leaves this false.
            }
        }
        self.persist(config_path)
    }
}

fn validate_credential_digest(value: &str) -> Result<()> {
    if value.len() != 64
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        bail!("pairing ledger credential digest is not canonical lowercase SHA-256");
    }
    Ok(())
}

fn validate_ledger_credential_path(config_path: &Path, path: &Path) -> Result<()> {
    let parent = config_path
        .parent()
        .context("worker config must have a parent directory")?;
    if !path.is_absolute() || path.parent() != Some(parent) {
        bail!("pairing ledger credential is not a direct child of the config directory");
    }
    if path.extension().and_then(|value| value.to_str()) != Some("credential") {
        bail!("pairing ledger path is not a credential file");
    }
    Ok(())
}

pub async fn pair(
    enrollment_file: &Path,
    config_path: &Path,
    options: PairOptions,
) -> Result<WorkerConfig> {
    pair_with_transport(enrollment_file, config_path, options, &HttpPairingTransport).await
}

#[async_trait]
trait PairingTransport: Send + Sync {
    async fn pair(
        &self,
        enrollment: &EnrollmentBundle,
        request: &PairRequest,
    ) -> Result<cyc_protocol::worker::PairResponse>;

    async fn acknowledge(
        &self,
        config: &WorkerConfig,
        pairing_id: uuid::Uuid,
        intended_node_id: uuid::Uuid,
        credential_sha256: &str,
    ) -> Result<()>;
}

struct HttpPairingTransport;

#[async_trait]
impl PairingTransport for HttpPairingTransport {
    async fn pair(
        &self,
        enrollment: &EnrollmentBundle,
        request: &PairRequest,
    ) -> Result<cyc_protocol::worker::PairResponse> {
        WorkerClient::pair(enrollment, request).await
    }

    async fn acknowledge(
        &self,
        config: &WorkerConfig,
        pairing_id: uuid::Uuid,
        intended_node_id: uuid::Uuid,
        credential_sha256: &str,
    ) -> Result<()> {
        acknowledge_committed_pairing(config, pairing_id, intended_node_id, credential_sha256).await
    }
}

async fn pair_with_transport(
    enrollment_file: &Path,
    config_path: &Path,
    options: PairOptions,
    transport: &dyn PairingTransport,
) -> Result<WorkerConfig> {
    let config_path = absolute_clean_path(config_path, "worker config")?;
    // This guard is intentionally kept across network awaits. Pairing is a
    // rare control-plane transaction; serializing it prevents two processes
    // from staging different secrets and last-writer-wins replacing config.
    let _pairing_lock = acquire_pairing_transaction_lock(&config_path).await?;
    let enrollment = load_enrollment_bundle(enrollment_file)?;
    let layout = prepare_pairing_layout(
        &config_path,
        options.workspace_root.as_deref(),
        options.repair,
        enrollment.controller_id,
        enrollment.intended_node_id,
        enrollment.pairing_id,
    )?;
    let mut ledger = PairingCredentialLedger::load(&layout.config_path)?;
    ledger.prepare_invocation(
        &layout.config_path,
        &enrollment,
        layout.existing_config.as_ref(),
    )?;
    garbage_collect_pairing_credentials(
        &layout.config_path,
        &mut ledger,
        layout.existing_config.as_ref(),
        Some(enrollment.pairing_id),
        enrollment.controller_id,
        enrollment.intended_node_id,
    )?;
    // The worker owns credential generation. Persist it before the consuming
    // request so every crash/retry reuses exactly the same secret and digest.
    let staged_credential = stage_pairing_credential(&layout, &enrollment, &mut ledger)?;
    let staged_digest = credential_sha256(staged_credential.expose());

    if let Some(config) = layout.committed_config.clone() {
        if config.worker_url != enrollment.worker_url
            || config.certificate_pem != enrollment.certificate_pem
            || config.worker_api_version != WORKER_API_VERSION
        {
            bail!("committed worker config does not match the enrollment listener identity");
        }
        if credential_sha256(config.load_credential()?.expose()) != staged_digest {
            bail!("committed worker config credential does not match pairing stage");
        }
        let acknowledgement = transport
            .acknowledge(
                &config,
                enrollment.pairing_id,
                enrollment.intended_node_id,
                &staged_digest,
            )
            .await;
        if let Err(error) = acknowledgement {
            if pairing_terminal_code(&error).is_some() {
                ledger.mark_terminal_ack(&layout.config_path, enrollment.pairing_id)?;
            }
            return Err(error);
        }
        ledger.acknowledge_and_supersede(&layout.config_path, enrollment.pairing_id)?;
        garbage_collect_pairing_credentials(
            &layout.config_path,
            &mut ledger,
            Some(&config),
            None,
            enrollment.controller_id,
            enrollment.intended_node_id,
        )?;
        return Ok(config);
    }

    let request = PairRequest {
        pairing_id: enrollment.pairing_id,
        intended_node_id: enrollment.intended_node_id,
        credential_sha256: staged_digest.clone(),
        display_name: None,
        probe: probe_at_or_conservative(&layout.workspace_root),
    };
    ledger.transition(
        &layout.config_path,
        enrollment.pairing_id,
        PairingCredentialState::PairRequestUnknown,
    )?;
    let paired = match transport.pair(&enrollment, &request).await {
        Ok(response) => response,
        Err(error) => {
            if let Some(code) = pairing_terminal_code(&error) {
                let state = if code == "pairing_binding_mismatch" {
                    PairingCredentialState::Superseded
                } else {
                    PairingCredentialState::TerminalUnavailable
                };
                ledger.transition(&layout.config_path, enrollment.pairing_id, state)?;
            }
            return Err(error);
        }
    };
    ledger.transition(
        &layout.config_path,
        enrollment.pairing_id,
        PairingCredentialState::PairAccepted,
    )?;
    // Re-verify the namespace after the network round trip and before any
    // long-lived identity bytes are persisted.
    ensure_protected_directory(&layout.config_parent)?;
    ensure_protected_directory(&layout.workspace_root)?;
    let config = WorkerConfig {
        api_version: WORKER_CONFIG_VERSION.to_owned(),
        worker_url: enrollment.worker_url.clone(),
        certificate_pem: enrollment.certificate_pem.clone(),
        controller_id: paired.controller_id,
        node_id: paired.node_id,
        worker_api_version: paired.api_version,
        heartbeat_interval_seconds: u64::from(paired.heartbeat_interval_seconds),
        lease_seconds: u64::from(paired.lease_seconds),
        workspace_root: layout.workspace_root,
        credential_file: layout.credential_file.clone(),
    };
    let persist_result = if layout.previous_credential.is_some() {
        config.replace(&layout.config_path)
    } else {
        config.write(&layout.config_path)
    };
    persist_result?;
    ledger.transition(
        &layout.config_path,
        enrollment.pairing_id,
        PairingCredentialState::ConfigCommitted,
    )?;
    let acknowledgement = transport
        .acknowledge(
            &config,
            enrollment.pairing_id,
            enrollment.intended_node_id,
            &staged_digest,
        )
        .await;
    if let Err(error) = acknowledgement {
        if pairing_terminal_code(&error).is_some() {
            ledger.mark_terminal_ack(&layout.config_path, enrollment.pairing_id)?;
        }
        return Err(error);
    }
    ledger.acknowledge_and_supersede(&layout.config_path, enrollment.pairing_id)?;
    garbage_collect_pairing_credentials(
        &layout.config_path,
        &mut ledger,
        Some(&config),
        None,
        enrollment.controller_id,
        enrollment.intended_node_id,
    )?;
    Ok(config)
}

/// Acquire the stable pairing lock with a transaction-level deadline.
///
/// The lower-level lock helper deliberately has a shorter per-probe timeout
/// because it is also used by small synchronous lock tests. Pairing/repair is
/// a larger transaction: on Windows its protected-directory and atomic-file
/// checks can consume more than one probe under workspace contention. A
/// timeout is therefore retried only when it is the exact pairing lock
/// timeout. Permission, integrity, path, and task failures still return
/// immediately, and no lock is ever held between attempts.
async fn acquire_pairing_transaction_lock(
    config_path: &Path,
) -> Result<crate::config::PairingLock> {
    let deadline = Instant::now() + PAIRING_TRANSACTION_WAIT_TIMEOUT;
    loop {
        match acquire_pairing_lock(config_path).await {
            Ok(lock) => return Ok(lock),
            Err(error) if is_pairing_lock_timeout(&error) => {
                if Instant::now() >= deadline {
                    return Err(error);
                }
                tokio::time::sleep(PAIRING_TRANSACTION_RETRY_DELAY).await;
            }
            Err(error) => return Err(error),
        }
    }
}

fn is_pairing_lock_timeout(error: &anyhow::Error) -> bool {
    format!("{error:#}").contains("timed out waiting for pairing transaction lock")
}

#[derive(Debug)]
struct PairingLayout {
    config_path: PathBuf,
    config_parent: PathBuf,
    workspace_root: PathBuf,
    credential_file: PathBuf,
    previous_credential: Option<PathBuf>,
    previous_credential_sha256: Option<String>,
    existing_config: Option<WorkerConfig>,
    committed_config: Option<WorkerConfig>,
}

fn prepare_pairing_layout(
    config_path: &Path,
    requested_workspace_root: Option<&Path>,
    repair: bool,
    expected_controller_id: uuid::Uuid,
    expected_node_id: uuid::Uuid,
    pairing_id: uuid::Uuid,
) -> Result<PairingLayout> {
    let config_path = absolute_clean_path(config_path, "worker config")?;
    let config_exists = path_entry_exists(&config_path)?;
    let config_parent = config_path
        .parent()
        .context("worker config must have a parent directory")?
        .to_path_buf();
    prepare_private_directory(&config_parent).with_context(|| {
        format!(
            "provision or verify worker config directory {}",
            config_parent.display()
        )
    })?;
    if !config_exists && path_entry_exists(&config_path)? {
        bail!(
            "worker config appeared during secure layout creation: {}",
            config_path.display()
        );
    }

    // A pairing-specific file name is the durable idempotency key on disk. It
    // lets a retry distinguish its own staged credential from an unrelated
    // prior installation without putting secret material in config or argv.
    let credential_file = config_path.with_extension(format!("{pairing_id}.credential"));
    let existing = if config_exists {
        let config = WorkerConfig::load(&config_path)?;
        if config.controller_id != expected_controller_id {
            bail!("enrollment controllerId does not match the existing worker config");
        }
        if config.node_id != expected_node_id {
            bail!("enrollment intendedNodeId does not match the existing worker config");
        }
        let _credential = config.load_credential()?;
        let credential_parent = config
            .credential_file
            .parent()
            .context("existing credential file must have a parent directory")?;
        if fs::canonicalize(credential_parent).context("canonicalize credential parent")?
            != fs::canonicalize(&config_parent).context("canonicalize config parent")?
        {
            bail!("existing credential file is not owned by the worker config directory");
        }
        Some(config)
    } else {
        if repair {
            bail!(
                "--repair requires an existing protected worker config: {}",
                config_path.display()
            );
        }
        None
    };

    let committed_config = existing
        .as_ref()
        .filter(|config| config.credential_file == credential_file)
        .cloned();
    if existing.is_some() && committed_config.is_none() && !repair {
        bail!(
            "worker config already exists; pass --repair only for an enrollment issued to the same controller and intended node: {}",
            config_path.display()
        );
    }

    let workspace_root = match requested_workspace_root {
        Some(path) => {
            if !path.is_absolute() {
                bail!("--workspace-root must be an absolute path");
            }
            absolute_clean_path(path, "worker workspace")?
        }
        None => existing
            .as_ref()
            .map(|config| config.workspace_root.clone())
            .unwrap_or_else(|| config_parent.join("workspace")),
    };
    if let Some(config) = &committed_config {
        if workspace_root != config.workspace_root {
            bail!("resumed pairing workspaceRoot does not match the committed worker config");
        }
    }
    prepare_private_directory(&workspace_root).with_context(|| {
        format!(
            "provision or verify worker workspace {}",
            workspace_root.display()
        )
    })?;
    ensure_protected_directory(&config_parent)?;
    ensure_protected_directory(&workspace_root)?;
    let previous_credential = existing
        .as_ref()
        .filter(|_| committed_config.is_none())
        .map(|config| config.credential_file.clone());
    let previous_credential_sha256 = existing
        .as_ref()
        .filter(|_| committed_config.is_none())
        .map(|config| {
            config
                .load_credential()
                .map(|credential| credential_sha256(credential.expose()))
        })
        .transpose()?;
    Ok(PairingLayout {
        config_path,
        config_parent,
        workspace_root,
        credential_file,
        previous_credential,
        previous_credential_sha256,
        existing_config: existing,
        committed_config,
    })
}

fn stage_pairing_credential(
    layout: &PairingLayout,
    enrollment: &EnrollmentBundle,
    ledger: &mut PairingCredentialLedger,
) -> Result<SecretString> {
    if let Some(record) = ledger.record(enrollment.pairing_id) {
        if record.controller_id != enrollment.controller_id
            || record.node_id != enrollment.intended_node_id
            || record.credential_file != layout.credential_file
        {
            bail!("pairing ledger record does not match the current enrollment binding");
        }
        if record.state.deletes_staged_credential() {
            bail!("pairing enrollment has a durable terminal local state");
        }
        if record.previous_credential_file != layout.previous_credential
            || record.previous_credential_sha256 != layout.previous_credential_sha256
        {
            // A committed-config replay sees no previous credential in the
            // reconstructed layout.  Its durable ledger is authoritative for
            // the still-pending old-credential cleanup.
            if layout.committed_config.is_none() {
                bail!("pairing ledger previous credential binding changed");
            }
        }
    }

    let exists = path_entry_exists(&layout.credential_file)?;
    let mut created = false;
    let credential = if exists {
        read_secret_file(&layout.credential_file)
            .context("resume protected staged worker credential")?
    } else {
        let credential = new_staged_credential()?;
        created = true;
        credential
    };
    validate_staged_credential(&credential)?;
    let digest = credential_sha256(credential.expose());

    if let Some(record) = ledger.record_mut(enrollment.pairing_id) {
        if exists && record.credential_sha256 != digest {
            bail!("staged worker credential digest does not match the durable pairing ledger");
        }
        if created {
            if record.state != PairingCredentialState::Staged {
                bail!("uncertain or committed pairing credential is missing");
            }
            // A crash can occur after the ledger was committed but before the
            // secret target was installed. Replace the expected digest first;
            // no request has been sent in Staged state, so regeneration is safe.
            record.credential_sha256 = digest.clone();
        }
        if layout.committed_config.is_some() && record.state != PairingCredentialState::Acknowledged
        {
            record.state = PairingCredentialState::ConfigCommitted;
        }
        ledger.persist(&layout.config_path)?;
    } else {
        if ledger.records.len() >= MAX_PAIRING_LEDGER_RECORDS {
            bail!("pairing ledger record limit reached; unresolved credentials remain protected");
        }
        ledger.records.push(PairingCredentialRecord {
            pairing_id: enrollment.pairing_id,
            controller_id: enrollment.controller_id,
            node_id: enrollment.intended_node_id,
            credential_file: layout.credential_file.clone(),
            credential_sha256: digest.clone(),
            created_at: enrollment.created_at,
            expires_at: enrollment.expires_at,
            state: if layout.committed_config.is_some() {
                PairingCredentialState::ConfigCommitted
            } else {
                PairingCredentialState::Staged
            },
            previous_credential_file: layout.previous_credential.clone(),
            previous_credential_sha256: layout.previous_credential_sha256.clone(),
            previous_cleanup_pending: false,
            cleanup_pending: false,
        });
        // Commit ownership and digest before a new secret file appears.  A
        // crash can leave a ledger entry without a file, never an unowned
        // secret file without a ledger entry.
        ledger.persist(&layout.config_path)?;
    }

    if created {
        write_secret_file(&layout.credential_file, credential.expose())
            .context("persist protected staged worker credential before pairing")?;
    }
    Ok(credential)
}

fn new_staged_credential() -> Result<SecretString> {
    SecretString::new(format!(
        "{}{}",
        uuid::Uuid::new_v4().simple(),
        uuid::Uuid::new_v4().simple()
    ))
}

fn validate_staged_credential(credential: &SecretString) -> Result<()> {
    if credential.expose().len() != 64
        || !credential
            .expose()
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        bail!("staged worker credential has an invalid generated format");
    }
    Ok(())
}

#[cfg(test)]
fn load_or_create_staged_credential(path: &Path) -> Result<SecretString> {
    let credential = if path_entry_exists(path)? {
        read_secret_file(path).context("resume protected staged worker credential")?
    } else {
        let credential = new_staged_credential()?;
        write_secret_file(path, credential.expose())
            .context("persist protected staged worker credential before pairing")?;
        credential
    };
    validate_staged_credential(&credential)?;
    Ok(credential)
}

fn credential_sha256(credential: &str) -> String {
    hex::encode(Sha256::digest(credential.as_bytes()))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PairingCleanupSlot {
    Staged,
    Previous,
}

fn garbage_collect_pairing_credentials(
    config_path: &Path,
    ledger: &mut PairingCredentialLedger,
    current_config: Option<&WorkerConfig>,
    invocation_pairing_id: Option<uuid::Uuid>,
    authorized_controller_id: uuid::Uuid,
    authorized_node_id: uuid::Uuid,
) -> Result<()> {
    let current_binding = current_config
        .map(|config| {
            let credential = config.load_credential()?;
            Ok::<_, anyhow::Error>((
                config.credential_file.clone(),
                credential_sha256(credential.expose()),
            ))
        })
        .transpose()?;

    // Never let one enrollment clean another controller/node namespace.
    for record in &ledger.records {
        if record.controller_id == authorized_controller_id && record.node_id == authorized_node_id
        {
            continue;
        }
        if path_entry_exists(&record.credential_file)?
            || match &record.previous_credential_file {
                Some(path) => path_entry_exists(path)?,
                None => false,
            }
        {
            bail!("pairing ledger contains protected state for a different controller or node");
        }
    }

    if let Some((current_path, current_digest)) = &current_binding {
        validate_ledger_credential_path(config_path, current_path)?;
        for record in &ledger.records {
            if &record.credential_file == current_path
                && (&record.credential_sha256 != current_digest
                    || record.controller_id != authorized_controller_id
                    || record.node_id != authorized_node_id)
            {
                bail!("current worker credential conflicts with the pairing ledger binding");
            }
        }
    }

    // Expiry is definitive only before a pair request was attempted. Once a
    // request may have reached the controller, expiry does not prove that its
    // staged credential was not consumed and therefore cannot authorize GC.
    let now = Utc::now();
    let mut changed = false;
    for record in &mut ledger.records {
        if record.controller_id == authorized_controller_id
            && record.node_id == authorized_node_id
            && record.state == PairingCredentialState::Staged
            && record.expires_at <= now
            && invocation_pairing_id != Some(record.pairing_id)
            && current_binding
                .as_ref()
                .is_none_or(|(path, _)| path != &record.credential_file)
        {
            record.state = PairingCredentialState::Expired;
            record.cleanup_pending = true;
            changed = true;
        }
    }
    if changed {
        ledger.persist(config_path)?;
    }

    let mut candidates: BTreeMap<PathBuf, (String, Vec<(usize, PairingCleanupSlot)>)> =
        BTreeMap::new();
    for (index, record) in ledger.records.iter().enumerate() {
        if record.state.has_uncertain_remote_state() {
            continue;
        }
        let mut targets = Vec::with_capacity(2);
        if record.cleanup_pending && record.state.deletes_staged_credential() {
            targets.push((
                &record.credential_file,
                &record.credential_sha256,
                PairingCleanupSlot::Staged,
            ));
        }
        if record.previous_cleanup_pending
            && matches!(
                record.state,
                PairingCredentialState::Acknowledged | PairingCredentialState::Superseded
            )
        {
            if let Some((path, digest)) = record
                .previous_credential_file
                .as_ref()
                .zip(record.previous_credential_sha256.as_ref())
            {
                targets.push((path, digest, PairingCleanupSlot::Previous));
            }
        }
        for (path, digest, slot) in targets {
            // Invocation protection applies to its staged credential. An
            // already-ACKed previous credential is a separate durable cleanup
            // obligation and is safe to retry before replaying ACK.
            if (slot == PairingCleanupSlot::Staged
                && invocation_pairing_id == Some(record.pairing_id))
                || current_binding
                    .as_ref()
                    .is_some_and(|(current, _)| current == path)
            {
                continue;
            }
            match candidates.entry(path.clone()) {
                std::collections::btree_map::Entry::Vacant(entry) => {
                    entry.insert((digest.clone(), vec![(index, slot)]));
                }
                std::collections::btree_map::Entry::Occupied(mut entry) => {
                    if entry.get().0 != *digest {
                        bail!("pairing ledger assigns conflicting digests to one cleanup path");
                    }
                    entry.get_mut().1.push((index, slot));
                }
            }
        }
    }

    // Preflight every target before removing any of them. A malformed path,
    // weak ACL, symlink/reparse point, or digest mismatch aborts the whole GC
    // pass while the already-durable cleanupPending bits remain set for retry.
    let mut present = BTreeMap::new();
    for (path, (digest, _)) in &candidates {
        present.insert(
            path.clone(),
            verify_owned_credential_for_cleanup(config_path, path, digest)?,
        );
    }

    for (path, (_, indices)) in &candidates {
        if present.get(path).copied().unwrap_or(false) {
            remove_protected_file(path).with_context(|| {
                format!("remove ledger-owned stale credential {}", path.display())
            })?;
        }
        for (index, slot) in indices {
            match slot {
                PairingCleanupSlot::Staged => ledger.records[*index].cleanup_pending = false,
                PairingCleanupSlot::Previous => {
                    ledger.records[*index].previous_cleanup_pending = false;
                }
            }
        }
        changed = true;
    }

    let current_path = current_binding.as_ref().map(|(path, _)| path);
    ledger.records.retain(|record| {
        if invocation_pairing_id == Some(record.pairing_id)
            || current_path == Some(&record.credential_file)
            || record.cleanup_pending
            || record.previous_cleanup_pending
            || record.state.has_uncertain_remote_state()
        {
            return true;
        }
        if record.state.deletes_staged_credential() {
            changed = true;
            return false;
        }
        true
    });
    if changed {
        ledger.persist(config_path)?;
    }
    Ok(())
}

/// Validate an exact deletion candidate without following an untrusted path.
/// `false` means the ledger-owned file was already absent; it is still safe to
/// clear cleanupPending because there are no credential bytes at that path.
fn verify_owned_credential_for_cleanup(
    config_path: &Path,
    path: &Path,
    expected_digest: &str,
) -> Result<bool> {
    validate_ledger_credential_path(config_path, path)?;
    validate_credential_digest(expected_digest)?;
    if !path_entry_exists(path)? {
        return Ok(false);
    }
    ensure_protected_input(path)?;
    let parent = config_path
        .parent()
        .context("worker config must have a parent directory")?;
    let canonical_parent = fs::canonicalize(parent)
        .with_context(|| format!("canonicalize pairing state directory {}", parent.display()))?;
    let canonical_file = fs::canonicalize(path)
        .with_context(|| format!("canonicalize pairing credential {}", path.display()))?;
    if canonical_file.parent() != Some(canonical_parent.as_path()) {
        bail!("pairing cleanup candidate is not a canonical direct child");
    }
    let credential = read_secret_file(path)?;
    if credential_sha256(credential.expose()) != expected_digest {
        bail!("pairing cleanup candidate digest does not match its ledger binding");
    }
    Ok(true)
}

async fn acknowledge_committed_pairing(
    config: &WorkerConfig,
    pairing_id: uuid::Uuid,
    intended_node_id: uuid::Uuid,
    credential_sha256: &str,
) -> Result<()> {
    if config.node_id != intended_node_id {
        bail!("committed worker config nodeId does not match enrollment");
    }
    let client = WorkerClient::from_config(config)?;
    let request = PairAckRequest {
        api_version: WORKER_API_VERSION.to_owned(),
        pairing_id,
        node_id: intended_node_id,
        credential_sha256: credential_sha256.to_owned(),
    };
    client.acknowledge_pairing(&request).await?;
    Ok(())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkerStatus {
    api_version: &'static str,
    paired: bool,
    controller_id: uuid::Uuid,
    node_id: uuid::Uuid,
    worker_url: String,
    workspace_root: PathBuf,
    credential_protected: bool,
    quarantined: bool,
    quarantine_file: Option<PathBuf>,
    hostile_isolation: cyc_protocol::HostileIsolationInventory,
    probe: cyc_protocol::worker::ProbeReport,
}

pub fn status(config_path: &Path) -> Result<WorkerStatus> {
    let config = WorkerConfig::load(config_path)?;
    let hostile_isolation = HostileIsolation::from_environment(Some(config.node_id))?;
    // Reading validates that the protected file exists and has acceptable
    // permissions. The credential value never enters the status object.
    let _credential = config.load_credential()?;
    ensure_protected_directory(&config.workspace_root)
        .context("refuse unprotected worker workspace during status")?;
    let quarantine_file = containment_quarantine_path(&config);
    let quarantined = path_entry_exists(&quarantine_file)?;
    Ok(WorkerStatus {
        api_version: WORKER_CONFIG_VERSION,
        paired: true,
        controller_id: config.controller_id,
        node_id: config.node_id,
        worker_url: config.worker_url.clone(),
        workspace_root: config.workspace_root.clone(),
        credential_protected: true,
        quarantined,
        quarantine_file: quarantined.then_some(quarantine_file),
        hostile_isolation: hostile_isolation.inventory(),
        probe: probe_at_or_conservative(&config.workspace_root),
    })
}

pub async fn run_forever(config_path: &Path) -> Result<()> {
    let config = WorkerConfig::load(config_path)?;
    let hostile_isolation = HostileIsolation::from_environment(Some(config.node_id))?;
    ensure_protected_directory(&config.workspace_root)
        .context("refuse unprotected worker workspace before run")?;
    hostile_isolation
        .validate_worker_boundaries(config_path, &config)
        .context("hostile-workload isolation gate failed before daemon start")?;
    // Reconcile outside the job-controlled workspace before inspecting the
    // in-workspace terminal-ack quarantine. A crash may leave both records;
    // residual processes are killed first, while the existing ack quarantine
    // still blocks another claim until its independent recovery completes.
    hostile_isolation
        .reconcile_before_claim()
        .context("reconcile hostile-workload residuals before any claim")?;
    hostile_isolation
        .verify_before_claim()
        .context("hostile-workload reconciliation proof is not claimable")?;
    refuse_containment_quarantine(&config)?;
    ensure_process_containment_available()
        .context("managed execution containment gate failed; refusing to claim work")?;
    let boot_generation =
        allocate_boot_generation(config_path).context("allocate durable worker boot generation")?;
    let client = Arc::new(WorkerClient::from_config(&config)?);
    let activity = Arc::new(WorkerActivity::default());
    let reporter = tokio::spawn(node_report_loop(
        config.workspace_root.clone(),
        boot_generation,
        client.clone(),
        activity.clone(),
    ));
    let result = claim_loop(config, client, activity, hostile_isolation).await;
    reporter.abort();
    let _ = reporter.await;
    result
}

async fn claim_loop(
    config: WorkerConfig,
    client: Arc<WorkerClient>,
    activity: Arc<WorkerActivity>,
    hostile_isolation: HostileIsolation,
) -> Result<()> {
    let mut transient_failures = 0u32;
    loop {
        ensure_protected_directory(&config.workspace_root)
            .context("worker workspace protection changed; refusing another claim")?;
        hostile_isolation
            .verify_before_claim()
            .context("hostile-workload external guard changed; refusing another claim")?;
        // Check on every poll, not only at daemon startup. Any marker entry --
        // including a truncated or malformed record left by a crash -- blocks
        // another claim before a resource probe or controller request can run.
        refuse_containment_quarantine(&config)?;
        let request = ClaimRequest {
            probe: probe_at_or_conservative(&config.workspace_root),
            active_run_ids: Vec::new(),
        };
        refuse_containment_quarantine(&config)?;
        hostile_isolation
            .verify_before_claim()
            .context("hostile-workload residual appeared before controller claim")?;
        let claim = match client.claim(&request).await {
            Ok(claim) => {
                // The controller round trip is an attacker-controlled timing
                // window. Revalidate after the response and before accepting an
                // assignment so a residual appearing in flight cannot cross the
                // claim boundary on the strength of the earlier probe.
                hostile_isolation
                    .verify_before_claim()
                    .context("hostile-workload state changed while claiming work")?;
                transient_failures = 0;
                claim
            }
            Err(error) if !fatal_controller_error(&error) => {
                transient_failures = transient_failures.saturating_add(1);
                let delay = 2u64.saturating_pow(transient_failures.min(4)).min(30);
                eprintln!("worker claim failed; retrying in {delay}s: {error:#}");
                tokio::select! {
                    _ = tokio::time::sleep(Duration::from_secs(delay)) => continue,
                    _ = tokio::signal::ctrl_c() => return Ok(()),
                }
            }
            Err(error) => return Err(error.context("worker claim failed permanently")),
        };
        let Some(assignment) = claim.assignment else {
            let delay = u64::from(claim.retry_after_seconds.clamp(1, 300));
            tokio::select! {
                _ = tokio::time::sleep(Duration::from_secs(delay)) => continue,
                _ = tokio::signal::ctrl_c() => return Ok(()),
            }
        };
        let cancellation = Arc::new(AtomicU8::new(CANCEL_NONE));
        let run_id = assignment.run_id;
        activity.begin(run_id)?;
        let work = run_guarded_assignment(&config, run_id, async {
            let run_credential = claim
                .run_credential
                .context("claimed assignment omitted run credential")?;
            process_assignment(
                &config,
                client.clone(),
                assignment,
                run_credential,
                cancellation.clone(),
            )
            .await
        });
        tokio::pin!(work);
        let mut stop = false;
        let result = tokio::select! {
            result = &mut work => result,
            _ = tokio::signal::ctrl_c() => {
                cancellation.store(CANCEL_REQUESTED, Ordering::SeqCst);
                stop = true;
                work.await
            }
        };
        if let Err(error) = result {
            handle_guarded_assignment_error(error).await?;
        }
        activity.end(run_id)?;
        if stop {
            return Ok(());
        }
    }
}

async fn node_report_loop(
    workspace: PathBuf,
    boot_generation: u64,
    client: Arc<WorkerClient>,
    activity: Arc<WorkerActivity>,
) {
    let mut sampler = match NodeSampler::new_with_boot_generation(&workspace, boot_generation) {
        Ok(sampler) => sampler,
        Err(error) => {
            eprintln!("worker inventory probe degraded to conservative capacity: {error:#}");
            NodeSampler::conservative_with_boot_generation(&workspace, boot_generation)
        }
    };
    let mut inventory_publication = InventoryPublicationState::default();
    let mut interval = tokio::time::interval(NODE_REPORT_INTERVAL);
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        interval.tick().await;
        let request = match activity.sample(&mut sampler) {
            Ok(request) => request,
            Err(error) => {
                eprintln!("worker node telemetry sample failed; retrying: {error:#}");
                continue;
            }
        };
        let request = inventory_publication.prepare(request);
        match client.node_report(&request).await {
            Ok(true) => inventory_publication.record_success(&request),
            Ok(false) => {
                inventory_publication.invalidate();
                eprintln!(
                    "worker node report was not accepted; retaining inventory for the next report"
                );
            }
            Err(error) => {
                inventory_publication.invalidate();
                // Node reporting is independent of run leases. A transient
                // report failure must not terminate execution or acknowledge
                // an inventory document that the controller never accepted.
                eprintln!("worker node report failed; retrying: {error:#}");
            }
        }
    }
}

async fn process_assignment(
    config: &WorkerConfig,
    client: Arc<WorkerClient>,
    assignment: ClaimAssignment,
    run_credential: crate::security::SecretString,
    cancellation: Arc<AtomicU8>,
) -> Result<()> {
    assignment
        .validate()
        .context("validate claimed assignment")?;
    validate_job_digest(&assignment)?;
    if assignment.lease_until <= Utc::now() {
        bail!("claimed assignment lease is already expired");
    }
    let session = Arc::new(client.run_session(&assignment, run_credential));
    let log_sink = Arc::new(HttpLogSink::new(session.clone()));
    let sink: Arc<dyn LogSink> = log_sink.clone();
    let log_budget = Arc::new(LogBudget::new(assignment.limits.max_log_bytes));
    let control = Arc::new(RunControl::new(
        assignment.state_version,
        assignment.lease_until,
        JobState::Preparing,
        cancellation.clone(),
    ));

    let heartbeat = tokio::spawn(heartbeat_loop(
        config.clone(),
        assignment.run_id,
        assignment.lease_id,
        session.clone(),
        control.clone(),
        log_sink.clone(),
    ));
    let watchdog = tokio::spawn(lease_watchdog(control.clone()));
    let effective_timeout = assignment
        .job_spec
        .timeout_seconds
        .unwrap_or(assignment.limits.job_timeout_seconds)
        .min(assignment.limits.job_timeout_seconds);
    let timeout_cancel = cancellation.clone();
    let timeout_watchdog = tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(effective_timeout)).await;
        let _ = timeout_cancel.compare_exchange(
            CANCEL_NONE,
            CANCEL_JOB_TIMEOUT,
            Ordering::SeqCst,
            Ordering::SeqCst,
        );
    });

    let result = execute_assignment(
        config,
        &assignment,
        session.clone(),
        control.clone(),
        cancellation,
        sink,
        log_sink,
        log_budget,
    )
    .await;
    heartbeat.abort();
    watchdog.abort();
    timeout_watchdog.abort();
    let _ = heartbeat.await;
    let _ = watchdog.await;
    let _ = timeout_watchdog.await;
    let terminal_ack = result?;
    let workspace_root = config.workspace_root.clone();
    let relative_root = assignment.workspace.relative_root.clone();
    let run_id = assignment.run_id;
    let cleanup_outcome = tokio::task::spawn_blocking(move || {
        remove_job_root_after_terminal_ack(&workspace_root, run_id, &relative_root)
    })
    .await
    .context("job-root cleanup task panicked")??;
    let receipt = CleanupReceiptV1 {
        api_version: CLEANUP_API_VERSION.to_owned(),
        run_id: assignment.run_id,
        lease_id: assignment.lease_id,
        relative_root: assignment.workspace.relative_root.clone(),
        outcome: cleanup_outcome,
        job_root_deleted: matches!(cleanup_outcome, JobRootCleanupOutcomeV1::Removed),
        observed_at: Utc::now(),
        terminal_ack,
    };
    session
        .cleanup(&receipt)
        .await
        .context("submit authoritative job-root cleanup receipt")?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn execute_assignment(
    config: &WorkerConfig,
    assignment: &ClaimAssignment,
    session: Arc<RunSession>,
    control: Arc<RunControl>,
    cancellation: Arc<AtomicU8>,
    sink: Arc<dyn LogSink>,
    log_sink: Arc<HttpLogSink>,
    log_budget: Arc<LogBudget>,
) -> Result<TerminalCompletionAckV1> {
    let snapshot_archive = match &assignment.job_spec.source {
        cyc_protocol::SourceSpec::Git { .. } => None,
        cyc_protocol::SourceSpec::Snapshot {
            digest,
            size_bytes: Some(size_bytes),
        } => Some(
            session
                .download_snapshot(digest, *size_bytes)
                .await
                .map_err(PrepareJobError::from),
        ),
        cyc_protocol::SourceSpec::Snapshot {
            size_bytes: None, ..
        } => Some(Err(PrepareJobError::from(anyhow::anyhow!(
            "snapshot assignment omitted required sizeBytes"
        )))),
    };
    let snapshot_archive = match snapshot_archive.transpose() {
        Ok(archive) => archive,
        Err(error) => {
            let finished_at = Utc::now();
            let (final_state, termination) = source_failure_termination(
                &assignment.job_spec.source,
                error.containment(),
                &cancellation,
                finished_at,
            )?;
            let execution = ExecutionEvidence {
                source: assigned_source_evidence(assignment),
                steps: Vec::new(),
                streams: log_sink.streams(&log_budget),
                termination,
            };
            return complete_early_failure(
                &session,
                &control,
                assignment,
                final_state,
                format!("source preparation failed: {error:#}"),
                finished_at,
                execution,
            )
            .await;
        }
    };
    let prepared = match prepare_job(
        &config.workspace_root,
        assignment.job_id,
        assignment.run_id,
        &assignment.job_spec,
        &assignment.workspace,
        snapshot_archive,
        cancellation.clone(),
        sink.clone(),
        log_budget.clone(),
    )
    .await
    {
        Ok(prepared) => prepared,
        Err(error) => {
            let finished_at = Utc::now();
            let (final_state, termination) = source_failure_termination(
                &assignment.job_spec.source,
                error.containment(),
                &cancellation,
                finished_at,
            )
            .with_context(|| {
                format!(
                    "source preparation failed without terminal containment proof; refusing completion: {error:#}"
                )
            })?;
            let execution = ExecutionEvidence {
                source: assigned_source_evidence(assignment),
                steps: Vec::new(),
                streams: log_sink.streams(&log_budget),
                termination,
            };
            return complete_early_failure(
                &session,
                &control,
                assignment,
                final_state,
                format!("source preparation failed: {error:#}"),
                finished_at,
                execution,
            )
            .await;
        }
    };
    let started_at = Utc::now();
    transition(
        &session,
        &control,
        assignment,
        JobState::Running,
        Some(RunEvidence {
            started_at: Some(started_at),
            ..RunEvidence::default()
        }),
    )
    .await?;

    let outcome = execute_steps(
        &prepared,
        &assignment.job_spec,
        cancellation.clone(),
        sink,
        assignment.limits.job_timeout_seconds,
        log_budget.clone(),
    )
    .await;
    if let Err(error) = write_result(&prepared, &outcome) {
        eprintln!("write local result evidence failed: {error:#}");
    }
    if !outcome.process_tree_terminated {
        return Err(ContainmentProofLost::new(
            "step execution ended without proof that the managed process tree is empty",
        )
        .into());
    }
    if !outcome.succeeded() {
        let final_state = if outcome.cancelled() {
            JobState::Cancelled
        } else {
            JobState::Failed
        };
        let finished_at = Utc::now();
        let execution = execution_from_outcome(
            &prepared.source,
            &outcome,
            log_sink.streams(&log_budget),
            outcome.termination,
            finished_at,
        );
        return complete_after_start(
            &session,
            &control,
            assignment,
            started_at,
            final_state,
            outcome.exit_code,
            Some(
                outcome
                    .error
                    .clone()
                    .unwrap_or_else(|| format!("job terminated: {:?}", outcome.termination)),
            ),
            Vec::new(),
            finished_at,
            execution,
        )
        .await;
    }

    transition(
        &session,
        &control,
        assignment,
        JobState::Verifying,
        Some(RunEvidence {
            started_at: Some(started_at),
            ..RunEvidence::default()
        }),
    )
    .await?;
    let upload = collect_and_upload(&prepared, assignment, &session, cancellation.as_ref()).await;
    let artifacts = match upload.error {
        None => upload.artifacts,
        Some(error) => {
            let finished_at = Utc::now();
            let reason = cancellation_termination_reason(&cancellation)
                .unwrap_or(TerminationReason::ArtifactVerificationFailed);
            let final_state = cancellation_final_state(&cancellation);
            let execution = execution_from_outcome(
                &prepared.source,
                &outcome,
                log_sink.streams(&log_budget),
                reason,
                finished_at,
            );
            return complete_after_start(
                &session,
                &control,
                assignment,
                started_at,
                final_state,
                Some(0),
                Some(format!("artifact verification failed: {error:#}")),
                upload.artifacts,
                finished_at,
                execution,
            )
            .await;
        }
    };
    let finished_at = Utc::now();
    let artifact_ids = artifacts.iter().map(|artifact| artifact.id).collect();
    let execution = execution_from_outcome(
        &prepared.source,
        &outcome,
        log_sink.streams(&log_budget),
        TerminationReason::Exited,
        finished_at,
    );
    let completion = RunCompletion {
        run_id: assignment.run_id,
        lease_id: assignment.lease_id,
        expected_version: control.version.load(Ordering::SeqCst),
        final_state: JobState::Succeeded,
        evidence: RunEvidence {
            started_at: Some(started_at),
            finished_at: Some(finished_at),
            exit_code: Some(0),
            error: None,
            artifact_ids,
        },
        execution,
        artifacts,
    };
    let _guard = control.mutation_gate.lock().await;
    submit_completion(&session, &control, &completion).await
}

struct ArtifactUploadOutcome {
    artifacts: Vec<ArtifactMetadata>,
    error: Option<anyhow::Error>,
}

async fn collect_and_upload(
    prepared: &PreparedJob,
    assignment: &ClaimAssignment,
    session: &RunSession,
    cancellation: &AtomicU8,
) -> ArtifactUploadOutcome {
    let artifacts = match collect_artifacts(prepared, &assignment.job_spec.artifacts) {
        Ok(artifacts) => artifacts,
        Err(error) => {
            return ArtifactUploadOutcome {
                artifacts: Vec::new(),
                error: Some(error),
            };
        }
    };
    if artifacts.len() > assignment.limits.max_artifact_count as usize {
        return ArtifactUploadOutcome {
            artifacts: Vec::new(),
            error: Some(anyhow::anyhow!("artifact count exceeds assignment limit")),
        };
    }
    let total_bytes = match artifacts
        .iter()
        .try_fold(0u64, |total, artifact| {
            total.checked_add(artifact.size_bytes)
        })
        .context("artifact byte count overflow")
    {
        Ok(total) => total,
        Err(error) => {
            return ArtifactUploadOutcome {
                artifacts: Vec::new(),
                error: Some(error),
            };
        }
    };
    if total_bytes > assignment.limits.max_artifact_bytes {
        return ArtifactUploadOutcome {
            artifacts: Vec::new(),
            error: Some(anyhow::anyhow!("artifact bytes exceed assignment limit")),
        };
    }
    let mut uploaded = Vec::with_capacity(artifacts.len());
    for artifact in artifacts {
        if cancellation.load(Ordering::SeqCst) != CANCEL_NONE {
            return ArtifactUploadOutcome {
                artifacts: uploaded,
                error: Some(anyhow::anyhow!(
                    "artifact verification interrupted by run cancellation"
                )),
            };
        }
        if artifact.size_bytes > assignment.limits.max_artifact_bytes.min(MAX_ARTIFACT_BYTES) {
            return ArtifactUploadOutcome {
                artifacts: uploaded,
                error: Some(anyhow::anyhow!(
                    "artifact `{}` exceeds per-upload limit",
                    artifact.name
                )),
            };
        }
        if let Err(error) = session.upload_artifact(&artifact).await {
            return ArtifactUploadOutcome {
                artifacts: uploaded,
                error: Some(error),
            };
        }
        uploaded.push(artifact_metadata(assignment.run_id, artifact));
    }
    ArtifactUploadOutcome {
        artifacts: uploaded,
        error: None,
    }
}

fn artifact_metadata(run_id: uuid::Uuid, artifact: ArtifactEvidence) -> ArtifactMetadata {
    ArtifactMetadata {
        id: artifact.id,
        run_id,
        relative_path: artifact.name,
        size_bytes: artifact.size_bytes,
        sha256: artifact.sha256,
        media_type: None,
        created_at: Utc::now(),
    }
}

fn assigned_source_evidence(assignment: &ClaimAssignment) -> ExecutionSourceEvidence {
    match &assignment.job_spec.source {
        cyc_protocol::SourceSpec::Git {
            repository,
            revision,
        } => ExecutionSourceEvidence {
            kind: "git".to_owned(),
            repository: repository.clone(),
            requested_revision: revision.clone(),
            resolved_revision: String::new(),
            tree: String::new(),
            git_version: "unavailable".to_owned(),
        },
        cyc_protocol::SourceSpec::Snapshot { digest, .. } => ExecutionSourceEvidence {
            kind: "snapshot".to_owned(),
            repository: "snapshot".to_owned(),
            requested_revision: digest.clone(),
            resolved_revision: String::new(),
            tree: String::new(),
            git_version: "not-applicable".to_owned(),
        },
    }
}

fn prepared_source_evidence(source: &SourceEvidence) -> ExecutionSourceEvidence {
    ExecutionSourceEvidence {
        kind: source.kind.clone(),
        repository: source.repository.clone(),
        requested_revision: source.requested_revision.clone(),
        resolved_revision: source.resolved_revision.clone(),
        tree: source.tree.clone(),
        git_version: source.git_version.clone(),
    }
}

fn execution_from_outcome(
    source: &SourceEvidence,
    outcome: &StepsOutcome,
    streams: RunStreamsEvidence,
    reason: TerminationReason,
    observed_at: DateTime<Utc>,
) -> ExecutionEvidence {
    ExecutionEvidence {
        source: prepared_source_evidence(source),
        steps: outcome.steps.clone(),
        streams,
        termination: TerminationEvidence {
            reason,
            process_tree_terminated: outcome.process_tree_terminated,
            forced_kill: outcome.forced_kill,
            root_exit_code: outcome.exit_code,
            signal: outcome.signal,
            observed_at,
        },
    }
}

async fn complete_early_failure(
    session: &RunSession,
    control: &RunControl,
    assignment: &ClaimAssignment,
    final_state: JobState,
    error: String,
    finished_at: DateTime<Utc>,
    execution: ExecutionEvidence,
) -> Result<TerminalCompletionAckV1> {
    let completion = early_failure_completion(
        assignment,
        control.version.load(Ordering::SeqCst),
        final_state,
        error,
        finished_at,
        execution,
    );
    let _guard = control.mutation_gate.lock().await;
    submit_completion(session, control, &completion).await
}

fn early_failure_completion(
    assignment: &ClaimAssignment,
    expected_version: u64,
    final_state: JobState,
    error: String,
    finished_at: DateTime<Utc>,
    execution: ExecutionEvidence,
) -> RunCompletion {
    // Source preparation can fail after a managed Git process exits. Bind the
    // run-level exit code to that exact observed root result, just as the
    // protocol requires for step completions. Snapshot/local validation
    // failures and termination paths without a root process remain `None` on
    // both sides of the invariant.
    let exit_code = execution.termination.root_exit_code;
    RunCompletion {
        run_id: assignment.run_id,
        lease_id: assignment.lease_id,
        expected_version,
        final_state,
        evidence: RunEvidence {
            finished_at: Some(finished_at),
            exit_code,
            error: Some(error),
            ..RunEvidence::default()
        },
        execution,
        artifacts: Vec::new(),
    }
}

#[allow(clippy::too_many_arguments)]
async fn complete_after_start(
    session: &RunSession,
    control: &RunControl,
    assignment: &ClaimAssignment,
    started_at: DateTime<Utc>,
    final_state: JobState,
    exit_code: Option<i32>,
    error: Option<String>,
    artifacts: Vec<ArtifactMetadata>,
    finished_at: DateTime<Utc>,
    execution: ExecutionEvidence,
) -> Result<TerminalCompletionAckV1> {
    let artifact_ids = artifacts.iter().map(|artifact| artifact.id).collect();
    let completion = RunCompletion {
        run_id: assignment.run_id,
        lease_id: assignment.lease_id,
        expected_version: control.version.load(Ordering::SeqCst),
        final_state,
        evidence: RunEvidence {
            started_at: Some(started_at),
            finished_at: Some(finished_at),
            exit_code,
            error,
            artifact_ids,
        },
        execution,
        artifacts,
    };
    let _guard = control.mutation_gate.lock().await;
    submit_completion(session, control, &completion).await
}

async fn submit_completion(
    session: &RunSession,
    control: &RunControl,
    completion: &RunCompletion,
) -> Result<TerminalCompletionAckV1> {
    let mut pending = completion.clone();
    pending.expected_version = control.version.load(Ordering::SeqCst);
    for attempt in 0..3 {
        match session.complete(&pending).await {
            Ok((response, terminal_ack)) => {
                if response.run.id != pending.run_id || response.run.state != pending.final_state {
                    bail!("controller completion acknowledgement does not match the terminal run");
                }
                if response.state_version < pending.expected_version {
                    bail!("controller completion acknowledgement regressed stateVersion");
                }
                apply_state_version(control, response.state_version, pending.final_state).await;
                if response.cancel_requested {
                    control
                        .cancellation
                        .store(CANCEL_REQUESTED, Ordering::SeqCst);
                }
                if terminal_ack.run_id != pending.run_id
                    || terminal_ack.lease_id != pending.lease_id
                    || terminal_ack.state_version != response.state_version
                    || terminal_ack.final_state != response.run.state
                {
                    bail!("controller terminal acknowledgement is not bound to the completion");
                }
                return Ok(terminal_ack);
            }
            Err(error) => {
                if let Some(conflict) = error.downcast_ref::<VersionConflict>() {
                    apply_version_conflict(control, conflict).await;
                    if conflict.current_state.is_some_and(JobState::is_terminal) {
                        return Err(
                            error.context("controller run became terminal during completion")
                        );
                    }
                    pending.expected_version = conflict.current_version;
                    if conflict.cancel_requested && pending.final_state != JobState::Cancelled {
                        if !pending.execution.termination.process_tree_terminated {
                            return Err(error.context(
                                "controller requested cancellation before process-tree termination was proven",
                            ));
                        }
                        let observed_at = Utc::now();
                        pending.final_state = JobState::Cancelled;
                        pending.evidence.finished_at = Some(observed_at);
                        pending.evidence.error =
                            Some("controller cancellation observed during terminal CAS".to_owned());
                        pending.execution.termination.reason = TerminationReason::CancelRequested;
                        pending.execution.termination.observed_at = observed_at;
                    }
                    continue;
                }
                if crate::http::is_retryable_transport_error(&error) && attempt < 2 {
                    // The controller may have committed before the connection
                    // dropped. Retry the byte-for-byte identical receipt so its
                    // durable digest can acknowledge a lost response.
                    tokio::time::sleep(Duration::from_millis(200 * (attempt + 1) as u64)).await;
                    continue;
                }
                return Err(error);
            }
        }
    }
    bail!("controller completion version changed repeatedly")
}

async fn transition(
    session: &RunSession,
    control: &RunControl,
    assignment: &ClaimAssignment,
    next_state: JobState,
    evidence: Option<RunEvidence>,
) -> Result<()> {
    let _guard = control.mutation_gate.lock().await;
    for attempt in 0..3 {
        let update = StateUpdate {
            run_id: assignment.run_id,
            lease_id: assignment.lease_id,
            expected_version: control.version.load(Ordering::SeqCst),
            next_state,
            evidence: evidence.clone(),
        };
        match session.state(&update).await {
            Ok(response) => {
                if response.run.id != assignment.run_id || response.run.state != next_state {
                    bail!("controller state acknowledgement does not match the run transition");
                }
                if response.state_version < update.expected_version {
                    bail!("controller state acknowledgement regressed stateVersion");
                }
                apply_state_version(control, response.state_version, next_state).await;
                if response.cancel_requested {
                    control
                        .cancellation
                        .store(CANCEL_REQUESTED, Ordering::SeqCst);
                }
                return Ok(());
            }
            Err(error) => {
                if let Some(conflict) = error.downcast_ref::<VersionConflict>() {
                    apply_version_conflict(control, conflict).await;
                    if conflict.cancel_requested {
                        return Ok(());
                    }
                    if conflict.current_state == Some(next_state) {
                        return Ok(());
                    }
                    if conflict.current_state.is_some_and(JobState::is_terminal) {
                        return Err(
                            error.context("controller run became terminal during transition")
                        );
                    }
                    continue;
                }
                if crate::http::is_retryable_transport_error(&error) && attempt < 2 {
                    tokio::time::sleep(Duration::from_millis(200 * (attempt + 1) as u64)).await;
                    continue;
                }
                return Err(error);
            }
        }
    }
    bail!("controller state version changed repeatedly")
}

async fn apply_version_conflict(control: &RunControl, conflict: &VersionConflict) {
    if let Some(state) = conflict.current_state {
        apply_state_version(control, conflict.current_version, state).await;
    } else {
        publish_version(control, conflict.current_version);
    }
    if conflict.cancel_requested {
        control
            .cancellation
            .store(CANCEL_REQUESTED, Ordering::SeqCst);
    }
}

fn publish_version(control: &RunControl, version: u64) {
    control.version.fetch_max(version, Ordering::SeqCst);
}

async fn apply_state_version(control: &RunControl, version: u64, state: JobState) {
    // State and its version are published while holding the state lock. A
    // delayed lower-version response can never overwrite a newer transition.
    let mut current_state = control.state.lock().await;
    let previous_version = control.version.fetch_max(version, Ordering::SeqCst);
    if version >= previous_version {
        *current_state = state;
    }
}

async fn heartbeat_snapshot(control: &RunControl) -> (u64, JobState) {
    let state = *control.state.lock().await;
    let version = control.version.load(Ordering::SeqCst);
    (version, state)
}

struct RunControl {
    version: AtomicU64,
    lease_until: Mutex<DateTime<Utc>>,
    state: Mutex<JobState>,
    /// Serializes state-changing CAS requests only. Heartbeats deliberately
    /// bypass this gate so a delayed transition/completion cannot starve lease
    /// renewal.
    mutation_gate: Mutex<()>,
    cancellation: Arc<AtomicU8>,
}

impl RunControl {
    fn new(
        version: u64,
        lease_until: DateTime<Utc>,
        state: JobState,
        cancellation: Arc<AtomicU8>,
    ) -> Self {
        Self {
            version: AtomicU64::new(version),
            lease_until: Mutex::new(lease_until),
            state: Mutex::new(state),
            mutation_gate: Mutex::new(()),
            cancellation,
        }
    }
}

async fn heartbeat_loop(
    config: WorkerConfig,
    run_id: uuid::Uuid,
    lease_id: uuid::Uuid,
    session: Arc<RunSession>,
    control: Arc<RunControl>,
    log_sink: Arc<HttpLogSink>,
) {
    let mut interval =
        tokio::time::interval(Duration::from_secs(config.heartbeat_interval_seconds));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    interval.tick().await;
    loop {
        interval.tick().await;
        if control.cancellation.load(Ordering::SeqCst) != CANCEL_NONE {
            return;
        }
        let (expected_version, state) = heartbeat_snapshot(&control).await;
        let last_log_sequence = log_sink.last_sequence();
        let request = HeartbeatRequest {
            run_id,
            lease_id,
            expected_version,
            state,
            // Do not spawn probe helpers (for example nvidia-smi) while a
            // managed process is active. Linux descendant containment relies
            // on the daemon having no unrelated concurrent children.
            probe: None,
            last_log_sequence,
        };
        match session.heartbeat(&request).await {
            Ok(response) => {
                if response.current_version < request.expected_version {
                    eprintln!(
                        "run heartbeat response regressed stateVersion; ignoring lease receipt"
                    );
                    continue;
                }
                publish_version(&control, response.current_version);
                let mut lease_until = control.lease_until.lock().await;
                if response.lease_until > *lease_until {
                    *lease_until = response.lease_until;
                }
                drop(lease_until);
                if response.cancel_requested {
                    control
                        .cancellation
                        .store(CANCEL_REQUESTED, Ordering::SeqCst);
                    return;
                }
            }
            Err(error) => {
                if let Some(conflict) = error.downcast_ref::<VersionConflict>() {
                    apply_version_conflict(&control, conflict).await;
                    if conflict.cancel_requested {
                        return;
                    }
                    continue;
                }
                eprintln!("run heartbeat failed; lease watchdog remains active: {error:#}");
            }
        }
    }
}

async fn lease_watchdog(control: Arc<RunControl>) {
    let mut interval = tokio::time::interval(Duration::from_millis(250));
    loop {
        interval.tick().await;
        if control.cancellation.load(Ordering::SeqCst) != CANCEL_NONE {
            return;
        }
        if Utc::now() >= *control.lease_until.lock().await {
            let _ = control.cancellation.compare_exchange(
                CANCEL_NONE,
                CANCEL_LEASE_LOST,
                Ordering::SeqCst,
                Ordering::SeqCst,
            );
            return;
        }
    }
}

fn validate_job_digest(assignment: &ClaimAssignment) -> Result<()> {
    let actual = canonical_job_digest(&assignment.job_spec)
        .context("canonicalize assigned job for digest validation")?;
    if actual != assignment.job_digest {
        bail!("assigned jobDigest does not match the immutable JobSpec");
    }
    Ok(())
}

fn cancellation_final_state(cancellation: &AtomicU8) -> JobState {
    match cancellation.load(Ordering::SeqCst) {
        CANCEL_REQUESTED | CANCEL_LEASE_LOST => JobState::Cancelled,
        _ => JobState::Failed,
    }
}

fn cancellation_termination_reason(cancellation: &AtomicU8) -> Option<TerminationReason> {
    match cancellation.load(Ordering::SeqCst) {
        CANCEL_REQUESTED => Some(TerminationReason::CancelRequested),
        CANCEL_LEASE_LOST => Some(TerminationReason::LeaseLost),
        CANCEL_TRANSPORT_FAILURE => Some(TerminationReason::TransportFailure),
        CANCEL_JOB_TIMEOUT => Some(TerminationReason::TimedOut),
        _ => None,
    }
}

fn source_failure_termination(
    source: &cyc_protocol::SourceSpec,
    containment: SourceContainment,
    cancellation: &AtomicU8,
    observed_at: DateTime<Utc>,
) -> Result<(JobState, TerminationEvidence)> {
    let SourceContainment::Confirmed(confirmed) = containment else {
        return Err(
            ContainmentProofLost::new("managed source process tree was not proven empty").into(),
        );
    };
    let process_reason = confirmed.reason.map(|reason| match reason {
        ProcessTerminationReason::TimedOut => TerminationReason::TimedOut,
        ProcessTerminationReason::CancelRequested => TerminationReason::CancelRequested,
        ProcessTerminationReason::LeaseLost => TerminationReason::LeaseLost,
        ProcessTerminationReason::TransportFailure => TerminationReason::TransportFailure,
        ProcessTerminationReason::Exited | ProcessTerminationReason::ExecutionFailed => {
            TerminationReason::SourcePreparationFailed
        }
    });
    let (final_state, reason) = match source {
        cyc_protocol::SourceSpec::Snapshot { .. } => {
            (JobState::Failed, TerminationReason::SourcePreparationFailed)
        }
        cyc_protocol::SourceSpec::Git { .. } => {
            let reason = cancellation_termination_reason(cancellation)
                .or(process_reason)
                .unwrap_or(TerminationReason::SourcePreparationFailed);
            let state = match reason {
                TerminationReason::CancelRequested | TerminationReason::LeaseLost => {
                    JobState::Cancelled
                }
                _ => JobState::Failed,
            };
            (state, reason)
        }
    };
    Ok((
        final_state,
        TerminationEvidence {
            reason,
            process_tree_terminated: true,
            forced_kill: confirmed.forced_kill,
            root_exit_code: confirmed.root_exit_code,
            signal: confirmed.signal,
            observed_at,
        },
    ))
}

/// Marker error for the one assignment failure that poisons the daemon.
///
/// Ordinary malformed assignments and controller failures remain isolated to
/// their run. Losing containment proof is different: the worker may still own
/// a live descendant, so claiming another run would invalidate both process
/// attribution and terminal evidence. The daemon must durably quarantine the
/// worker until an operator has inspected or rebooted the host and explicitly
/// clears the marker.
#[derive(Debug)]
struct ContainmentProofLost {
    detail: String,
}

impl ContainmentProofLost {
    fn new(detail: impl Into<String>) -> Self {
        Self {
            detail: detail.into(),
        }
    }
}

impl fmt::Display for ContainmentProofLost {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}", self.detail)
    }
}

impl std::error::Error for ContainmentProofLost {}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct ContainmentQuarantineRecord {
    api_version: String,
    node_id: uuid::Uuid,
    run_id: uuid::Uuid,
    observed_at: DateTime<Utc>,
    reason: String,
}

#[derive(Debug)]
struct GuardDurabilityLost {
    operation: &'static str,
    source: anyhow::Error,
}

impl GuardDurabilityLost {
    fn new(operation: &'static str, source: anyhow::Error) -> Self {
        Self { operation, source }
    }
}

impl fmt::Display for GuardDurabilityLost {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "active-run guard durability failed during {}: {:#}",
            self.operation, self.source
        )
    }
}

impl std::error::Error for GuardDurabilityLost {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(self.source.as_ref())
    }
}

#[derive(Debug)]
struct AssignmentQuarantined {
    marker: PathBuf,
    source: anyhow::Error,
}

impl fmt::Display for AssignmentQuarantined {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "assignment did not receive an authoritative terminal acknowledgement; active-run guard retained as containment quarantine at {}: {:#}",
            self.marker.display(),
            self.source
        )
    }
}

impl std::error::Error for AssignmentQuarantined {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(self.source.as_ref())
    }
}

#[derive(Debug)]
struct ActiveRunGuard {
    marker: PathBuf,
    node_id: uuid::Uuid,
    run_id: uuid::Uuid,
    #[cfg(test)]
    clear_fault: bool,
}

impl ActiveRunGuard {
    fn arm(config: &WorkerConfig, run_id: uuid::Uuid) -> Result<Self> {
        let marker = persist_active_run_guard(config, run_id)?;
        Ok(Self {
            marker,
            node_id: config.node_id,
            run_id,
            #[cfg(test)]
            clear_fault: false,
        })
    }

    #[cfg(test)]
    fn inject_clear_fault(&mut self) {
        self.clear_fault = true;
    }

    fn verify(&self) -> Result<()> {
        verify_active_run_guard(&self.marker, self.node_id, self.run_id)
    }

    fn clear(self) -> Result<()> {
        self.verify()?;
        #[cfg(test)]
        if self.clear_fault {
            bail!("injected active-run guard clear failure");
        }
        fs::remove_file(&self.marker)
            .with_context(|| format!("remove active-run guard {}", self.marker.display()))?;
        #[cfg(unix)]
        FileSync::sync_directory(
            self.marker
                .parent()
                .context("active-run guard must have a parent")?,
        )?;
        Ok(())
    }
}

async fn run_guarded_assignment<F>(config: &WorkerConfig, run_id: uuid::Uuid, work: F) -> Result<()>
where
    F: Future<Output = Result<()>>,
{
    run_guarded_assignment_inner(config, run_id, work, false).await
}

async fn run_guarded_assignment_inner<F>(
    config: &WorkerConfig,
    run_id: uuid::Uuid,
    work: F,
    #[cfg_attr(not(test), allow(unused_variables))] inject_clear_fault: bool,
) -> Result<()>
where
    F: Future<Output = Result<()>>,
{
    // Async futures are lazy: arming completes before `work` receives its
    // first poll, so prepare_job/git/step process creation is always guarded.
    let guard = ActiveRunGuard::arm(config, run_id)
        .map_err(|error| GuardDurabilityLost::new("establish", error))?;
    #[cfg(test)]
    let mut guard = guard;
    #[cfg(test)]
    if inject_clear_fault {
        guard.inject_clear_fault();
    }

    match work.await {
        Ok(()) => guard
            .clear()
            .map_err(|error| GuardDurabilityLost::new("clear", error).into()),
        Err(error) => {
            guard
                .verify()
                .map_err(|guard_error| GuardDurabilityLost::new("retain", guard_error))?;
            Err(AssignmentQuarantined {
                marker: guard.marker,
                source: error,
            }
            .into())
        }
    }
}

fn containment_quarantine_path(config: &WorkerConfig) -> PathBuf {
    config.workspace_root.join(CONTAINMENT_QUARANTINE_FILE)
}

fn remove_job_root_after_terminal_ack(
    workspace_root: &Path,
    run_id: uuid::Uuid,
    relative_root: &str,
) -> Result<JobRootCleanupOutcomeV1> {
    let expected_relative = format!("jobs/{run_id}");
    if relative_root != expected_relative {
        bail!("assignment job root is not the exact controller-owned run root");
    }
    ensure_protected_directory(workspace_root)
        .context("verify protected worker workspace before cleanup")?;
    ensure_no_windows_reparse_points(workspace_root)
        .context("reject workspace reparse points before cleanup")?;
    let canonical_workspace = fs::canonicalize(workspace_root)
        .with_context(|| format!("canonicalize worker workspace {}", workspace_root.display()))?;
    let jobs = workspace_root.join("jobs");
    if !path_entry_exists(&jobs)? {
        return Ok(JobRootCleanupOutcomeV1::NotCreated);
    }
    verify_direct_directory_for_cleanup(&jobs)?;
    let canonical_jobs = fs::canonicalize(&jobs)
        .with_context(|| format!("canonicalize jobs root {}", jobs.display()))?;
    if canonical_jobs.parent() != Some(canonical_workspace.as_path()) {
        bail!("canonical jobs root escaped the configured worker workspace");
    }
    let target = jobs.join(run_id.to_string());
    if !path_entry_exists(&target)? {
        return Ok(JobRootCleanupOutcomeV1::NotCreated);
    }
    verify_direct_directory_for_cleanup(&target)?;
    let canonical_target = fs::canonicalize(&target)
        .with_context(|| format!("canonicalize job root {}", target.display()))?;
    let expected_name = run_id.to_string();
    if canonical_target.parent() != Some(canonical_jobs.as_path())
        || canonical_target.file_name() != Some(std::ffi::OsStr::new(&expected_name))
    {
        bail!("canonical job root does not match workspace/jobs/<run-id>");
    }
    verify_cleanup_tree(&target)?;

    // Rename inside the already-proven jobs directory before recursive
    // removal. A concurrent process cannot replace `jobs/<run-id>` and make
    // the cleanup walk outside this job-owned root after this point.
    let quarantine = jobs.join(format!(".cleanup-{run_id}-{}", uuid::Uuid::new_v4()));
    if path_entry_exists(&quarantine)? {
        bail!("cleanup quarantine path already exists");
    }
    fs::rename(&target, &quarantine).with_context(|| {
        format!(
            "atomically quarantine completed job root {}",
            target.display()
        )
    })?;
    if path_entry_exists(&target)? {
        bail!("completed job root still exists after quarantine rename");
    }
    verify_direct_directory_for_cleanup(&quarantine)?;
    verify_cleanup_tree(&quarantine)?;
    fs::remove_dir_all(&quarantine).with_context(|| {
        format!(
            "remove quarantined completed job root {}",
            quarantine.display()
        )
    })?;
    if path_entry_exists(&quarantine)? || path_entry_exists(&target)? {
        bail!("completed job root remains after recursive cleanup");
    }
    #[cfg(unix)]
    FileSync::sync_directory(&jobs)?;
    Ok(JobRootCleanupOutcomeV1::Removed)
}

fn verify_cleanup_tree(root: &Path) -> Result<()> {
    for entry in walkdir::WalkDir::new(root).follow_links(false) {
        let entry = entry.with_context(|| format!("walk cleanup root {}", root.display()))?;
        let metadata = fs::symlink_metadata(entry.path())
            .with_context(|| format!("inspect cleanup entry {}", entry.path().display()))?;
        if metadata.file_type().is_symlink() || cleanup_metadata_is_reparse(&metadata) {
            bail!(
                "cleanup root contains a symlink or reparse point: {}",
                entry.path().display()
            );
        }
    }
    Ok(())
}

fn verify_direct_directory_for_cleanup(path: &Path) -> Result<()> {
    ensure_no_windows_reparse_points(path)?;
    let metadata = fs::symlink_metadata(path)
        .with_context(|| format!("inspect cleanup directory {}", path.display()))?;
    if !metadata.is_dir()
        || metadata.file_type().is_symlink()
        || cleanup_metadata_is_reparse(&metadata)
    {
        bail!("cleanup path is not a direct directory: {}", path.display());
    }
    Ok(())
}

#[cfg(windows)]
fn cleanup_metadata_is_reparse(metadata: &fs::Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;
    use windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT;

    metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

#[cfg(not(windows))]
fn cleanup_metadata_is_reparse(_metadata: &fs::Metadata) -> bool {
    false
}

fn path_entry_exists(path: &Path) -> Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error).with_context(|| format!("inspect path entry {}", path.display())),
    }
}

fn refuse_containment_quarantine(config: &WorkerConfig) -> Result<()> {
    let marker = containment_quarantine_path(config);
    ensure_no_windows_reparse_points(&marker)
        .context("validate containment quarantine path before claim")?;
    if path_entry_exists(&marker)? {
        bail!(
            "worker containment quarantine is active at {}; inspect the host and confirm no managed descendants remain (or reboot), then explicitly remove this marker before restarting",
            marker.display()
        );
    }
    Ok(())
}

fn persist_active_run_guard(config: &WorkerConfig, run_id: uuid::Uuid) -> Result<PathBuf> {
    let marker = containment_quarantine_path(config);
    ensure_no_windows_reparse_points(&marker)
        .context("validate active-run guard path before creation")?;
    if path_entry_exists(&marker)? {
        bail!(
            "active-run guard path already exists and is quarantined: {}",
            marker.display()
        );
    }
    let parent = marker
        .parent()
        .context("containment quarantine marker must have a parent")?;
    let metadata = fs::symlink_metadata(parent)
        .with_context(|| format!("inspect worker workspace {}", parent.display()))?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        bail!(
            "worker workspace is not a direct directory: {}",
            parent.display()
        );
    }

    let record = ContainmentQuarantineRecord {
        api_version: ACTIVE_RUN_GUARD_VERSION.to_owned(),
        node_id: config.node_id,
        run_id,
        observed_at: Utc::now(),
        reason: ACTIVE_RUN_GUARD_REASON.to_owned(),
    };
    let bytes = serde_json::to_vec_pretty(&record).context("serialize containment quarantine")?;
    let temporary = parent.join(format!(
        ".{CONTAINMENT_QUARANTINE_FILE}.{}.tmp",
        uuid::Uuid::new_v4()
    ));
    ensure_no_windows_reparse_points(&temporary)
        .context("validate active-run temporary path before creation")?;
    let write_result = (|| -> Result<()> {
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options
            .open(&temporary)
            .with_context(|| format!("create active-run temporary {}", temporary.display()))?;
        file.write_all(&bytes).context("write active-run guard")?;
        file.write_all(b"\n").context("finish active-run guard")?;
        file.sync_all().context("flush active-run guard")?;
        drop(file);
        ensure_no_windows_reparse_points(&temporary)
            .context("validate flushed active-run temporary path")?;

        // The target is never replaced. On Unix an atomic hard-link install
        // supplies create-new semantics; on Windows rename itself fails when
        // the destination exists. A second daemon therefore cannot adopt or
        // overwrite another run's guard.
        ensure_no_windows_reparse_points(&marker)
            .context("revalidate active-run guard destination before installation")?;
        if path_entry_exists(&marker)? {
            bail!(
                "active-run guard appeared concurrently at {}",
                marker.display()
            );
        }

        #[cfg(unix)]
        {
            fs::hard_link(&temporary, &marker).with_context(|| {
                format!(
                    "atomically install active-run guard {} -> {}",
                    temporary.display(),
                    marker.display()
                )
            })?;
            FileSync::sync_directory(parent)?;
            fs::remove_file(&temporary)
                .with_context(|| format!("remove active-run temporary {}", temporary.display()))?;
            FileSync::sync_directory(parent)?;
        }
        #[cfg(windows)]
        {
            atomic_install_active_run_guard_windows(&temporary, &marker)?;
        }
        #[cfg(not(any(unix, windows)))]
        compile_error!("active-run guard atomic installation is not implemented for this platform");
        Ok(())
    })();
    if write_result.is_err() && !path_entry_exists(&marker).unwrap_or(false) {
        let _ = fs::remove_file(&temporary);
    }
    write_result?;
    if !path_entry_exists(&marker)? {
        bail!("active-run guard did not persist at {}", marker.display());
    }
    verify_active_run_guard(&marker, config.node_id, run_id)?;
    Ok(marker)
}

fn verify_active_run_guard(
    marker: &Path,
    expected_node_id: uuid::Uuid,
    expected_run_id: uuid::Uuid,
) -> Result<()> {
    ensure_no_windows_reparse_points(marker).context("validate active-run guard path")?;
    let metadata = fs::symlink_metadata(marker)
        .with_context(|| format!("inspect active-run guard {}", marker.display()))?;
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        bail!(
            "active-run guard is not a direct regular file: {}",
            marker.display()
        );
    }
    let record: ContainmentQuarantineRecord = serde_json::from_slice(
        &fs::read(marker).with_context(|| format!("read active-run guard {}", marker.display()))?,
    )
    .with_context(|| format!("parse active-run guard {}", marker.display()))?;
    if record.api_version != ACTIVE_RUN_GUARD_VERSION
        || record.node_id != expected_node_id
        || record.run_id != expected_run_id
        || record.reason != ACTIVE_RUN_GUARD_REASON
    {
        bail!(
            "active-run guard identity or version mismatch at {}",
            marker.display()
        );
    }
    Ok(())
}

#[cfg(unix)]
struct FileSync;

#[cfg(unix)]
impl FileSync {
    fn sync_directory(path: &Path) -> Result<()> {
        fs::File::open(path)
            .with_context(|| format!("open quarantine parent {}", path.display()))?
            .sync_all()
            .with_context(|| format!("flush quarantine parent {}", path.display()))
    }
}

#[cfg(windows)]
fn atomic_install_active_run_guard_windows(source: &Path, destination: &Path) -> Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{MoveFileExW, MOVEFILE_WRITE_THROUGH};

    let source_wide = source
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    let destination_wide = destination
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    // Omitting MOVEFILE_REPLACE_EXISTING gives atomic create-new semantics;
    // WRITE_THROUGH does not return until the move is flushed to disk.
    let moved = unsafe {
        MoveFileExW(
            source_wide.as_ptr(),
            destination_wide.as_ptr(),
            MOVEFILE_WRITE_THROUGH,
        )
    };
    if moved == 0 {
        return Err(std::io::Error::last_os_error()).with_context(|| {
            format!(
                "atomically install and flush active-run guard {} -> {}",
                source.display(),
                destination.display()
            )
        });
    }
    Ok(())
}

async fn handle_guarded_assignment_error(error: anyhow::Error) -> Result<()> {
    if error.downcast_ref::<GuardDurabilityLost>().is_some() {
        // Exiting here could let a restart-on-failure supervisor relaunch a
        // worker whose guard update was not durable. Stay alive but never poll
        // or claim again; an operator must stop and repair the service.
        eprintln!(
            "fatal active-run guard durability failure; worker is permanently parked and will not claim again: {error:#}"
        );
        loop {
            tokio::time::sleep(Duration::from_secs(3600)).await;
        }
    }

    // Every post-claim error keeps the already durable guard. This includes
    // execution, transition, lease, transport, and completion-ack ambiguity.
    // Exiting is safe because any supervisor restart refuses the marker before
    // another claim.
    Err(error)
}

fn fatal_controller_error(error: &anyhow::Error) -> bool {
    let text = format!("{error:#}");
    text.contains("HTTP 401")
        || text.contains("HTTP 403")
        || text.contains("certificate")
        || text.contains("worker config")
}

fn absolute_clean_path(path: &Path, label: &str) -> Result<PathBuf> {
    let absolute = if path.is_absolute() {
        path.to_owned()
    } else {
        std::env::current_dir()?.join(path)
    };
    if absolute.components().any(|component| {
        matches!(
            component,
            std::path::Component::CurDir | std::path::Component::ParentDir
        )
    }) {
        bail!("{label} path must not contain `.` or `..` components");
    }
    Ok(absolute)
}

#[cfg(test)]
mod tests {
    use super::*;
    use cyc_protocol::worker::{ExecutionLimits, WorkspaceAssignment};
    #[cfg(any(windows, target_os = "linux"))]
    use cyc_protocol::Shell;
    use cyc_protocol::{JobKind, JobSpec, JobStep, SourceSpec};
    use tempfile::tempdir;
    use uuid::Uuid;

    // The first transport callback follows several protected-file operations.
    // On Windows each ACL apply/verify launches PowerShell, and cold hosted
    // runners can spend more than a minute before the callback is reached.
    // Keep a finite bound for deadlock detection while giving that setup
    // enough headroom; Unix keeps the shorter fail-fast bound.
    #[cfg(windows)]
    const PAIRING_TEST_ENTRY_TIMEOUT: Duration = Duration::from_secs(180);
    #[cfg(not(windows))]
    const PAIRING_TEST_ENTRY_TIMEOUT: Duration = Duration::from_secs(60);

    fn worker_config(directory: &tempfile::TempDir) -> WorkerConfig {
        let workspace = directory.path().join("workspace");
        fs::create_dir(&workspace).unwrap();
        WorkerConfig {
            api_version: WORKER_CONFIG_VERSION.to_owned(),
            worker_url: "https://controller.example.invalid/worker".to_owned(),
            certificate_pem: "test-certificate".to_owned(),
            controller_id: Uuid::new_v4(),
            node_id: Uuid::new_v4(),
            worker_api_version: "cyc.dev/worker-api/v1".to_owned(),
            heartbeat_interval_seconds: 5,
            lease_seconds: 30,
            workspace_root: workspace,
            credential_file: directory.path().join("worker.credential"),
        }
    }

    fn prepare_new_pairing_layout(config_path: &Path) -> Result<PairingLayout> {
        prepare_pairing_layout(
            config_path,
            None,
            false,
            Uuid::new_v4(),
            Uuid::new_v4(),
            Uuid::new_v4(),
        )
    }

    fn write_test_enrollment(path: &Path, pairing_id: Uuid, controller_id: Uuid, node_id: Uuid) {
        prepare_private_directory(path.parent().unwrap()).unwrap();
        let bundle = EnrollmentBundle {
            api_version: cyc_protocol::onboarding::ENROLLMENT_API_VERSION.to_owned(),
            pairing_id,
            controller_id,
            intended_node_id: node_id,
            worker_url: "https://controller.example.invalid/worker".to_owned(),
            certificate_pem: "test-certificate".to_owned(),
            pairing_code: "0123456789abcdef0123456789abcdef".to_owned(),
            created_at: Utc::now() - chrono::Duration::seconds(1),
            expires_at: Utc::now() + chrono::Duration::minutes(10),
        };
        let bytes = serde_json::to_vec(&bundle).unwrap();
        write_protected_file(path, &bytes).unwrap();
    }

    struct FakePairingTransport {
        pair_calls: std::sync::atomic::AtomicUsize,
        ack_calls: std::sync::atomic::AtomicUsize,
        block_first_pair: std::sync::atomic::AtomicBool,
        lose_first_ack_response: std::sync::atomic::AtomicBool,
        terminal_first_ack: std::sync::atomic::AtomicBool,
        expect_absent_before_ack: StdMutex<Option<PathBuf>>,
        first_pair_entered: tokio::sync::Notify,
        release_first_pair: tokio::sync::Notify,
    }

    impl FakePairingTransport {
        fn new(block_first_pair: bool, lose_first_ack_response: bool) -> Self {
            Self {
                pair_calls: std::sync::atomic::AtomicUsize::new(0),
                ack_calls: std::sync::atomic::AtomicUsize::new(0),
                block_first_pair: std::sync::atomic::AtomicBool::new(block_first_pair),
                lose_first_ack_response: std::sync::atomic::AtomicBool::new(
                    lose_first_ack_response,
                ),
                terminal_first_ack: std::sync::atomic::AtomicBool::new(false),
                expect_absent_before_ack: StdMutex::new(None),
                first_pair_entered: tokio::sync::Notify::new(),
                release_first_pair: tokio::sync::Notify::new(),
            }
        }

        fn with_terminal_first_ack(self) -> Self {
            self.terminal_first_ack.store(true, Ordering::SeqCst);
            self
        }

        fn expect_absent_before_ack(self, path: PathBuf) -> Self {
            *self.expect_absent_before_ack.lock().unwrap() = Some(path);
            self
        }
    }

    #[async_trait]
    impl PairingTransport for FakePairingTransport {
        async fn pair(
            &self,
            enrollment: &EnrollmentBundle,
            request: &PairRequest,
        ) -> Result<cyc_protocol::worker::PairResponse> {
            let call = self.pair_calls.fetch_add(1, Ordering::SeqCst);
            if call == 0 && self.block_first_pair.load(Ordering::SeqCst) {
                self.first_pair_entered.notify_one();
                self.release_first_pair.notified().await;
            }
            Ok(cyc_protocol::worker::PairResponse {
                api_version: WORKER_API_VERSION.to_owned(),
                pairing_id: request.pairing_id,
                controller_id: enrollment.controller_id,
                node_id: request.intended_node_id,
                credential_sha256: request.credential_sha256.clone(),
                paired_at: Utc::now(),
                heartbeat_interval_seconds: 5,
                lease_seconds: 90,
            })
        }

        async fn acknowledge(
            &self,
            config: &WorkerConfig,
            _pairing_id: Uuid,
            intended_node_id: Uuid,
            expected_digest: &str,
        ) -> Result<()> {
            self.ack_calls.fetch_add(1, Ordering::SeqCst);
            if config.node_id != intended_node_id
                || credential_sha256(config.load_credential()?.expose()) != expected_digest
            {
                bail!("fake pairing acknowledgement binding mismatch");
            }
            if let Some(path) = self.expect_absent_before_ack.lock().unwrap().as_ref() {
                if path_entry_exists(path)? {
                    bail!("durable previous cleanup was not retried before acknowledgement");
                }
            }
            if self.terminal_first_ack.swap(false, Ordering::SeqCst) {
                return Err(crate::http::test_worker_api_error(
                    reqwest::StatusCode::UNAUTHORIZED,
                    "pairing_ack_unauthorized",
                ));
            }
            if self.lose_first_ack_response.swap(false, Ordering::SeqCst) {
                bail!("simulated acknowledgement response loss");
            }
            Ok(())
        }
    }

    fn ledger_record_with_secret(
        config_path: &Path,
        pairing_id: Uuid,
        controller_id: Uuid,
        node_id: Uuid,
        state: PairingCredentialState,
        secret: &str,
    ) -> PairingCredentialRecord {
        let credential_file = config_path.with_extension(format!("{pairing_id}.credential"));
        write_secret_file(&credential_file, secret).unwrap();
        PairingCredentialRecord {
            pairing_id,
            controller_id,
            node_id,
            credential_file,
            credential_sha256: credential_sha256(secret),
            created_at: Utc::now() - chrono::Duration::minutes(5),
            expires_at: Utc::now() + chrono::Duration::minutes(5),
            state,
            previous_credential_file: None,
            previous_credential_sha256: None,
            previous_cleanup_pending: false,
            cleanup_pending: state.deletes_staged_credential(),
        }
    }

    #[test]
    fn worker_activity_serializes_one_slot_and_feeds_idle_active_reports() {
        let directory = tempdir().unwrap();
        let activity = WorkerActivity::default();
        let mut sampler = NodeSampler::conservative(directory.path());
        let idle = activity.sample(&mut sampler).unwrap();
        assert!(idle.telemetry.active_run_ids.is_empty());

        let run_id = Uuid::new_v4();
        activity.begin(run_id).unwrap();
        assert!(activity.begin(Uuid::new_v4()).is_err());
        let active = activity.sample(&mut sampler).unwrap();
        assert_eq!(active.telemetry.active_run_ids, vec![run_id]);
        assert_eq!(active.telemetry.load.running_jobs, 1);
        activity.end(run_id).unwrap();
        let idle_again = activity.sample(&mut sampler).unwrap();
        assert!(idle_again.telemetry.active_run_ids.is_empty());
        assert_eq!(idle_again.telemetry.sequence, 3);
    }

    #[test]
    fn inventory_is_omitted_only_after_the_exact_document_is_accepted() {
        let directory = tempdir().unwrap();
        let mut sampler = NodeSampler::conservative(directory.path());
        let mut publication = InventoryPublicationState::default();

        let failed_first = publication.prepare(sampler.sample(&[]).unwrap());
        assert!(failed_first.inventory.is_some());
        // No success receipt was recorded, so the next report must retry the
        // complete inventory rather than silently switching to telemetry-only.
        let accepted_retry = publication.prepare(sampler.sample(&[]).unwrap());
        assert!(accepted_retry.inventory.is_some());
        publication.record_success(&accepted_retry);

        let steady_state = publication.prepare(sampler.sample(&[]).unwrap());
        assert!(steady_state.inventory.is_none());

        // A controller rejection or transport failure invalidates the local
        // acknowledgement. Even an unchanged document must be republished.
        publication.invalidate();
        let retry_after_rejection = publication.prepare(sampler.sample(&[]).unwrap());
        assert!(retry_after_rejection.inventory.is_some());
        publication.record_success(&retry_after_rejection);
        assert!(publication
            .prepare(sampler.sample(&[]).unwrap())
            .inventory
            .is_none());

        // The error branch has the same fail-closed publication transition as
        // an explicit `accepted: false` receipt.
        publication.invalidate();
        let retry_after_transport_error = publication.prepare(sampler.sample(&[]).unwrap());
        assert!(retry_after_transport_error.inventory.is_some());
        publication.record_success(&retry_after_transport_error);

        let changed_model = "inventory-changed".to_owned();
        let mut failed_change = sampler.sample(&[]).unwrap();
        failed_change.inventory.as_mut().unwrap().cpu_model = changed_model.clone();
        let failed_change = publication.prepare(failed_change);
        assert!(failed_change.inventory.is_some());

        let mut accepted_change = sampler.sample(&[]).unwrap();
        accepted_change.inventory.as_mut().unwrap().cpu_model = changed_model.clone();
        let accepted_change = publication.prepare(accepted_change);
        assert!(accepted_change.inventory.is_some());
        publication.record_success(&accepted_change);

        let mut changed_steady_state = sampler.sample(&[]).unwrap();
        changed_steady_state.inventory.as_mut().unwrap().cpu_model = changed_model;
        let changed_steady_state = publication.prepare(changed_steady_state);
        assert!(changed_steady_state.inventory.is_none());
    }

    #[tokio::test]
    async fn delayed_transition_gate_never_blocks_heartbeat_snapshot() {
        let control = Arc::new(RunControl::new(
            7,
            Utc::now() + chrono::Duration::seconds(90),
            JobState::Running,
            Arc::new(AtomicU8::new(CANCEL_NONE)),
        ));
        let (acquired_tx, acquired_rx) = tokio::sync::oneshot::channel();
        let delayed = {
            let control = control.clone();
            tokio::spawn(async move {
                let _guard = control.mutation_gate.lock().await;
                acquired_tx.send(()).unwrap();
                tokio::time::sleep(Duration::from_millis(100)).await;
            })
        };
        acquired_rx.await.unwrap();

        let snapshot =
            tokio::time::timeout(Duration::from_millis(25), heartbeat_snapshot(&control))
                .await
                .expect("heartbeat snapshot must bypass a delayed mutation request");
        assert_eq!(snapshot, (7, JobState::Running));
        delayed.await.unwrap();
    }

    #[tokio::test]
    async fn delayed_control_responses_never_regress_version_or_state() {
        let control = RunControl::new(
            5,
            Utc::now() + chrono::Duration::seconds(90),
            JobState::Preparing,
            Arc::new(AtomicU8::new(CANCEL_NONE)),
        );
        apply_state_version(&control, 6, JobState::Running).await;
        publish_version(&control, 8);
        apply_state_version(&control, 7, JobState::Preparing).await;

        assert_eq!(control.version.load(Ordering::SeqCst), 8);
        assert_eq!(*control.state.lock().await, JobState::Running);
        assert_eq!(heartbeat_snapshot(&control).await, (8, JobState::Running));
    }

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

    #[cfg(windows)]
    fn create_directory_junction(junction: &Path, target: &Path) {
        let output = std::process::Command::new("powershell.exe")
            .args([
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-Command",
                "$ErrorActionPreference = 'Stop'; New-Item -ItemType Junction -Path $env:CYC_TEST_JUNCTION -Target $env:CYC_TEST_TARGET | Out-Null",
            ])
            .env("CYC_TEST_JUNCTION", junction)
            .env("CYC_TEST_TARGET", target)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "failed to create test junction: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    #[test]
    fn digest_binds_exact_job_spec() {
        let job = JobSpec::new(
            JobKind::Build,
            SourceSpec::Git {
                repository: "https://example.invalid/repo.git".into(),
                revision: "a".repeat(40),
            },
            vec![JobStep::new("build", "cargo build")],
        );
        let digest = canonical_job_digest(&job).unwrap();
        let mut assignment = ClaimAssignment {
            job_id: job.id,
            run_id: Uuid::new_v4(),
            job_digest: digest,
            lease_id: Uuid::new_v4(),
            lease_until: Utc::now() + chrono::Duration::minutes(1),
            state_version: 1,
            job_spec: job,
            workspace: WorkspaceAssignment {
                relative_root: format!("jobs/{}", Uuid::new_v4()),
                source_directory: "repo".into(),
                logs_directory: "logs".into(),
                artifacts_directory: "artifacts".into(),
            },
            limits: ExecutionLimits::default(),
        };
        validate_job_digest(&assignment).unwrap();
        assignment.job_spec.steps[0].script.push_str(" --release");
        assert!(validate_job_digest(&assignment).is_err());
    }

    #[test]
    fn snapshot_failure_evidence_binds_the_exact_digest() {
        let digest = format!("sha256:{}", "b".repeat(64));
        let job = JobSpec::new(
            JobKind::Build,
            SourceSpec::Snapshot {
                digest: digest.clone(),
                size_bytes: Some(128),
            },
            vec![JobStep::new("build", "cargo build")],
        );
        let assignment = ClaimAssignment {
            job_id: job.id,
            run_id: Uuid::new_v4(),
            job_digest: canonical_job_digest(&job).unwrap(),
            lease_id: Uuid::new_v4(),
            lease_until: Utc::now() + chrono::Duration::minutes(1),
            state_version: 1,
            job_spec: job,
            workspace: WorkspaceAssignment {
                relative_root: format!("jobs/{}", Uuid::new_v4()),
                source_directory: "repo".into(),
                logs_directory: "logs".into(),
                artifacts_directory: "artifacts".into(),
            },
            limits: ExecutionLimits::default(),
        };
        let evidence = assigned_source_evidence(&assignment);
        evidence.validate().unwrap();
        assert_eq!(evidence.kind, "snapshot");
        assert_eq!(evidence.requested_revision, digest);
    }

    #[cfg(any(windows, target_os = "linux"))]
    #[tokio::test]
    async fn snapshot_extract_then_execute_uses_digest_bound_tree() {
        use sha2::{Digest, Sha256};
        use std::io::Cursor;

        let directory = tempdir().unwrap();
        let workspace_root = directory.path().join("workspace");
        fs::create_dir(&workspace_root).unwrap();
        let mut tar_bytes = Vec::new();
        {
            let mut builder = tar::Builder::new(&mut tar_bytes);
            let payload = b"snapshot execution\n";
            let mut header = tar::Header::new_gnu();
            header.set_entry_type(tar::EntryType::Regular);
            header.set_mode(0o644);
            header.set_uid(0);
            header.set_gid(0);
            header.set_mtime(0);
            header.set_size(payload.len() as u64);
            header.set_cksum();
            builder
                .append_data(&mut header, "input.txt", Cursor::new(payload))
                .unwrap();
            builder.finish().unwrap();
        }
        let archive = zstd::stream::encode_all(Cursor::new(tar_bytes), 3).unwrap();
        let digest = format!("sha256:{}", hex::encode(Sha256::digest(&archive)));
        #[cfg(windows)]
        let mut step = JobStep::new(
            "check",
            "Get-Content -LiteralPath input.txt | Set-Content -LiteralPath executed.txt",
        );
        #[cfg(windows)]
        {
            step.shell = Some(Shell::Powershell);
        }
        #[cfg(unix)]
        let mut step = JobStep::new("check", "cat input.txt > executed.txt");
        #[cfg(unix)]
        {
            step.shell = Some(Shell::Bash);
        }
        let job = JobSpec::new(
            JobKind::Test,
            SourceSpec::Snapshot {
                digest: digest.clone(),
                size_bytes: Some(archive.len() as u64),
            },
            vec![step],
        );
        let run_id = Uuid::new_v4();
        let prepared = prepare_job(
            &workspace_root,
            job.id,
            run_id,
            &job,
            &WorkspaceAssignment {
                relative_root: format!("jobs/{run_id}"),
                source_directory: "repo".to_owned(),
                logs_directory: "logs".to_owned(),
                artifacts_directory: "artifacts".to_owned(),
            },
            Some(archive),
            Arc::new(AtomicU8::new(CANCEL_NONE)),
            Arc::new(crate::process::DiscardLogSink),
            Arc::new(LogBudget::new(1024 * 1024)),
        )
        .await
        .unwrap();
        assert_eq!(prepared.source.resolved_revision, digest);
        assert_eq!(prepared.source.tree, digest);
        let outcome = execute_steps(
            &prepared,
            &job,
            Arc::new(AtomicU8::new(CANCEL_NONE)),
            Arc::new(crate::process::DiscardLogSink),
            // Hosted Windows runners may spend well over thirty seconds
            // starting their first PowerShell process.
            180,
            Arc::new(LogBudget::new(1024 * 1024)),
        )
        .await;
        assert!(outcome.succeeded(), "{outcome:?}");
        assert_eq!(
            fs::read_to_string(prepared.repository.join("executed.txt"))
                .unwrap()
                .trim(),
            "snapshot execution"
        );
    }

    #[test]
    fn transport_and_timeout_are_failures_not_user_cancellations() {
        let cancellation = AtomicU8::new(CANCEL_TRANSPORT_FAILURE);
        assert_eq!(cancellation_final_state(&cancellation), JobState::Failed);
        cancellation.store(CANCEL_JOB_TIMEOUT, Ordering::SeqCst);
        assert_eq!(cancellation_final_state(&cancellation), JobState::Failed);
        cancellation.store(CANCEL_REQUESTED, Ordering::SeqCst);
        assert_eq!(cancellation_final_state(&cancellation), JobState::Cancelled);
    }

    #[test]
    fn unconfirmed_source_containment_refuses_terminal_evidence() {
        let source = SourceSpec::Git {
            repository: "https://example.invalid/repo.git".into(),
            revision: "a".repeat(40),
        };
        let cancellation = AtomicU8::new(CANCEL_NONE);
        let error = source_failure_termination(
            &source,
            SourceContainment::Unconfirmed,
            &cancellation,
            Utc::now(),
        )
        .unwrap_err();
        assert!(error
            .to_string()
            .contains("process tree was not proven empty"));
        let contextualized = error.context("assignment execution failed");
        assert!(contextualized
            .downcast_ref::<ContainmentProofLost>()
            .is_some());
        assert!(anyhow::anyhow!("ordinary malformed assignment")
            .downcast_ref::<ContainmentProofLost>()
            .is_none());
    }

    #[test]
    fn git_source_exit_failure_builds_protocol_valid_completion() {
        let source = SourceSpec::Git {
            repository: "https://example.invalid/repo.git".into(),
            // Models the syntactically valid but nonexistent OID used by the
            // real TLS regression scenario.
            revision: "f".repeat(40),
        };
        let job = JobSpec::new(JobKind::Build, source.clone(), Vec::new());
        let assignment = ClaimAssignment {
            job_id: job.id,
            run_id: Uuid::new_v4(),
            job_digest: canonical_job_digest(&job).unwrap(),
            lease_id: Uuid::new_v4(),
            lease_until: Utc::now() + chrono::Duration::minutes(1),
            state_version: 1,
            job_spec: job,
            workspace: WorkspaceAssignment {
                relative_root: format!("jobs/{}", Uuid::new_v4()),
                source_directory: "repo".into(),
                logs_directory: "logs".into(),
                artifacts_directory: "artifacts".into(),
            },
            limits: ExecutionLimits::default(),
        };
        let finished_at = Utc::now();
        let cancellation = AtomicU8::new(CANCEL_NONE);
        let (final_state, termination) = source_failure_termination(
            &source,
            SourceContainment::Confirmed(crate::source::ConfirmedSourceTermination {
                reason: Some(ProcessTerminationReason::Exited),
                forced_kill: false,
                root_exit_code: Some(128),
                signal: None,
            }),
            &cancellation,
            finished_at,
        )
        .unwrap();
        let empty_stream = cyc_protocol::worker::StreamEvidence {
            byte_count: 0,
            sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855".into(),
            truncated: false,
            chunk_count: 0,
        };
        let execution = ExecutionEvidence {
            source: assigned_source_evidence(&assignment),
            steps: Vec::new(),
            streams: RunStreamsEvidence {
                stdout: empty_stream.clone(),
                stderr: empty_stream,
            },
            termination,
        };

        let completion = early_failure_completion(
            &assignment,
            assignment.state_version,
            final_state,
            "source preparation failed: protected Git checkout failed".into(),
            finished_at,
            execution,
        );

        assert_eq!(completion.final_state, JobState::Failed);
        assert_eq!(completion.evidence.exit_code, Some(128));
        assert_eq!(completion.execution.termination.root_exit_code, Some(128));
        completion.validate().unwrap();
    }

    #[test]
    fn source_failures_without_a_root_exit_keep_both_exit_codes_absent() {
        let digest = format!("sha256:{}", "b".repeat(64));
        let source = SourceSpec::Snapshot {
            digest,
            size_bytes: Some(128),
        };
        let job = JobSpec::new(JobKind::Build, source.clone(), Vec::new());
        let assignment = ClaimAssignment {
            job_id: job.id,
            run_id: Uuid::new_v4(),
            job_digest: canonical_job_digest(&job).unwrap(),
            lease_id: Uuid::new_v4(),
            lease_until: Utc::now() + chrono::Duration::minutes(1),
            state_version: 1,
            job_spec: job,
            workspace: WorkspaceAssignment {
                relative_root: format!("jobs/{}", Uuid::new_v4()),
                source_directory: "repo".into(),
                logs_directory: "logs".into(),
                artifacts_directory: "artifacts".into(),
            },
            limits: ExecutionLimits::default(),
        };
        let finished_at = Utc::now();
        let (final_state, termination) = source_failure_termination(
            &source,
            SourceContainment::Confirmed(crate::source::ConfirmedSourceTermination {
                reason: None,
                forced_kill: false,
                root_exit_code: None,
                signal: None,
            }),
            &AtomicU8::new(CANCEL_NONE),
            finished_at,
        )
        .unwrap();
        let empty_stream = cyc_protocol::worker::StreamEvidence {
            byte_count: 0,
            sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855".into(),
            truncated: false,
            chunk_count: 0,
        };
        let completion = early_failure_completion(
            &assignment,
            assignment.state_version,
            final_state,
            "source preparation failed before a root process was spawned".into(),
            finished_at,
            ExecutionEvidence {
                source: assigned_source_evidence(&assignment),
                steps: Vec::new(),
                streams: RunStreamsEvidence {
                    stdout: empty_stream.clone(),
                    stderr: empty_stream,
                },
                termination,
            },
        );

        assert_eq!(completion.evidence.exit_code, None);
        assert_eq!(completion.execution.termination.root_exit_code, None);
        completion.validate().unwrap();
    }

    #[test]
    fn cancelled_and_timed_out_source_failures_preserve_exit_code_invariant() {
        let source = SourceSpec::Git {
            repository: "https://example.invalid/repo.git".into(),
            revision: "f".repeat(40),
        };
        let job = JobSpec::new(JobKind::Build, source.clone(), Vec::new());
        let assignment = ClaimAssignment {
            job_id: job.id,
            run_id: Uuid::new_v4(),
            job_digest: canonical_job_digest(&job).unwrap(),
            lease_id: Uuid::new_v4(),
            lease_until: Utc::now() + chrono::Duration::minutes(1),
            state_version: 1,
            job_spec: job,
            workspace: WorkspaceAssignment {
                relative_root: format!("jobs/{}", Uuid::new_v4()),
                source_directory: "repo".into(),
                logs_directory: "logs".into(),
                artifacts_directory: "artifacts".into(),
            },
            limits: ExecutionLimits::default(),
        };

        for (cancellation_code, process_reason, root_exit_code, expected_state) in [
            (
                CANCEL_REQUESTED,
                ProcessTerminationReason::CancelRequested,
                Some(130),
                JobState::Cancelled,
            ),
            (
                CANCEL_JOB_TIMEOUT,
                ProcessTerminationReason::TimedOut,
                None,
                JobState::Failed,
            ),
        ] {
            let finished_at = Utc::now();
            let (final_state, termination) = source_failure_termination(
                &source,
                SourceContainment::Confirmed(crate::source::ConfirmedSourceTermination {
                    reason: Some(process_reason),
                    forced_kill: true,
                    root_exit_code,
                    signal: None,
                }),
                &AtomicU8::new(cancellation_code),
                finished_at,
            )
            .unwrap();
            let empty_stream = cyc_protocol::worker::StreamEvidence {
                byte_count: 0,
                sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855".into(),
                truncated: false,
                chunk_count: 0,
            };
            let completion = early_failure_completion(
                &assignment,
                assignment.state_version,
                final_state,
                "source preparation was interrupted".into(),
                finished_at,
                ExecutionEvidence {
                    source: assigned_source_evidence(&assignment),
                    steps: Vec::new(),
                    streams: RunStreamsEvidence {
                        stdout: empty_stream.clone(),
                        stderr: empty_stream,
                    },
                    termination,
                },
            );

            assert_eq!(completion.final_state, expected_state);
            assert_eq!(completion.evidence.exit_code, root_exit_code);
            assert_eq!(
                completion.execution.termination.root_exit_code,
                root_exit_code
            );
            completion.validate().unwrap();
        }
    }

    #[test]
    fn durable_quarantine_blocks_restart_until_explicit_repair() {
        let directory = tempdir().unwrap();
        let config = worker_config(&directory);
        refuse_containment_quarantine(&config).unwrap();

        let run_id = Uuid::new_v4();
        let marker = persist_active_run_guard(&config, run_id).unwrap();
        let value: serde_json::Value = serde_json::from_slice(&fs::read(&marker).unwrap()).unwrap();
        assert_eq!(value["apiVersion"], ACTIVE_RUN_GUARD_VERSION);
        assert_eq!(value["reason"], ACTIVE_RUN_GUARD_REASON);
        assert_eq!(value["runId"], run_id.to_string());

        // A freshly constructed config models a supervisor restart. Mere
        // process exit/relaunch must not clear the durable poison state.
        let restarted = config.clone();
        let error = refuse_containment_quarantine(&restarted).unwrap_err();
        assert!(error.to_string().contains("quarantine is active"));

        fs::remove_file(&marker).unwrap();
        #[cfg(unix)]
        FileSync::sync_directory(&config.workspace_root).unwrap();
        refuse_containment_quarantine(&restarted).unwrap();
    }

    #[test]
    fn pairing_rejects_an_existing_weak_config_parent_without_repair() {
        let directory = tempdir().unwrap();
        let parent = directory.path().join("worker-state");
        fs::create_dir(&parent).unwrap();
        make_directory_weak(&parent);
        let config_path = parent.join("worker.json");

        let error = prepare_new_pairing_layout(&config_path).unwrap_err();
        assert!(format!("{error:#}").contains("private directory"));
        assert!(ensure_protected_directory(&parent).is_err());
    }

    #[test]
    fn pairing_rejects_a_prepositioned_weak_workspace_without_repair() {
        let directory = tempdir().unwrap();
        let parent = directory.path().join("worker-state");
        prepare_private_directory(&parent).unwrap();
        let workspace = parent.join("workspace");
        fs::create_dir(&workspace).unwrap();
        make_directory_weak(&workspace);

        let error = prepare_new_pairing_layout(&parent.join("worker.json")).unwrap_err();
        assert!(format!("{error:#}").contains("worker workspace"));
        ensure_protected_directory(&parent).unwrap();
        assert!(ensure_protected_directory(&workspace).is_err());
    }

    #[test]
    fn pairing_persists_an_explicit_absolute_workspace() {
        let directory = tempdir().unwrap();
        let config_path = directory.path().join("state").join("worker.json");
        let workspace = directory.path().join("selected-workspace");
        let pairing_id = Uuid::new_v4();
        let layout = prepare_pairing_layout(
            &config_path,
            Some(&workspace),
            false,
            Uuid::new_v4(),
            Uuid::new_v4(),
            pairing_id,
        )
        .unwrap();

        assert_eq!(layout.workspace_root, workspace);
        assert_eq!(
            layout.credential_file,
            config_path.with_extension(format!("{pairing_id}.credential"))
        );
        assert!(layout.previous_credential.is_none());
        ensure_protected_directory(&layout.workspace_root).unwrap();
    }

    #[test]
    fn staged_pairing_credential_survives_a_crash_and_is_reused() {
        let directory = tempdir().unwrap();
        let config_path = directory.path().join("state").join("worker.json");
        let pairing_id = Uuid::new_v4();
        let layout = prepare_pairing_layout(
            &config_path,
            None,
            false,
            Uuid::new_v4(),
            Uuid::new_v4(),
            pairing_id,
        )
        .unwrap();

        let first = load_or_create_staged_credential(&layout.credential_file).unwrap();
        let first_digest = credential_sha256(first.expose());
        drop(first); // simulate process loss after staging, before consume
        let replay = load_or_create_staged_credential(&layout.credential_file).unwrap();
        assert_eq!(credential_sha256(replay.expose()), first_digest);
        assert_eq!(replay.expose().len(), 64);
        assert!(crate::security::ensure_protected_input(&layout.credential_file).is_ok());
    }

    #[test]
    fn staged_ledger_without_a_secret_recovers_before_any_request_is_sent() {
        let directory = tempdir().unwrap();
        let state = directory.path().join("state");
        let config_path = state.join("worker.json");
        let enrollment_path = state.join("enrollment.json");
        let controller_id = Uuid::new_v4();
        let node_id = Uuid::new_v4();
        let pairing_id = Uuid::new_v4();
        write_test_enrollment(&enrollment_path, pairing_id, controller_id, node_id);
        let enrollment = load_enrollment_bundle(&enrollment_path).unwrap();
        let layout = prepare_pairing_layout(
            &config_path,
            None,
            false,
            controller_id,
            node_id,
            pairing_id,
        )
        .unwrap();
        let mut ledger = PairingCredentialLedger {
            api_version: PAIRING_LEDGER_VERSION.to_owned(),
            records: vec![PairingCredentialRecord {
                pairing_id,
                controller_id,
                node_id,
                credential_file: layout.credential_file.clone(),
                credential_sha256: "0".repeat(64),
                created_at: enrollment.created_at,
                expires_at: enrollment.expires_at,
                state: PairingCredentialState::Staged,
                previous_credential_file: None,
                previous_credential_sha256: None,
                previous_cleanup_pending: false,
                cleanup_pending: false,
            }],
        };
        // Models a crash after durable ledger publication and before the
        // pairing-owned secret file was atomically installed.
        ledger.persist(&config_path).unwrap();
        assert!(!layout.credential_file.exists());

        let recovered = stage_pairing_credential(&layout, &enrollment, &mut ledger).unwrap();
        assert_eq!(recovered.expose().len(), 64);
        assert!(ensure_protected_input(&layout.credential_file).is_ok());
        let record = ledger.record(pairing_id).unwrap();
        assert_eq!(record.state, PairingCredentialState::Staged);
        assert_eq!(
            record.credential_sha256,
            credential_sha256(recovered.expose())
        );
        let serialized = fs::read_to_string(PairingCredentialLedger::path(&config_path)).unwrap();
        assert!(!serialized.contains(recovered.expose()));
    }

    #[test]
    fn unknown_request_with_a_missing_secret_fails_closed_without_regeneration() {
        let directory = tempdir().unwrap();
        let state = directory.path().join("state");
        let config_path = state.join("worker.json");
        let enrollment_path = state.join("enrollment.json");
        let controller_id = Uuid::new_v4();
        let node_id = Uuid::new_v4();
        let pairing_id = Uuid::new_v4();
        write_test_enrollment(&enrollment_path, pairing_id, controller_id, node_id);
        let enrollment = load_enrollment_bundle(&enrollment_path).unwrap();
        let layout = prepare_pairing_layout(
            &config_path,
            None,
            false,
            controller_id,
            node_id,
            pairing_id,
        )
        .unwrap();
        let mut ledger = PairingCredentialLedger {
            api_version: PAIRING_LEDGER_VERSION.to_owned(),
            records: vec![PairingCredentialRecord {
                pairing_id,
                controller_id,
                node_id,
                credential_file: layout.credential_file.clone(),
                credential_sha256: "1".repeat(64),
                created_at: enrollment.created_at,
                expires_at: enrollment.expires_at,
                state: PairingCredentialState::PairRequestUnknown,
                previous_credential_file: None,
                previous_credential_sha256: None,
                previous_cleanup_pending: false,
                cleanup_pending: false,
            }],
        };
        ledger.persist(&config_path).unwrap();

        let error = match stage_pairing_credential(&layout, &enrollment, &mut ledger) {
            Ok(_) => panic!("uncertain pairing unexpectedly regenerated its credential"),
            Err(error) => error,
        };
        assert!(error
            .to_string()
            .contains("uncertain or committed pairing credential is missing"));
        assert!(!layout.credential_file.exists());
        let persisted = PairingCredentialLedger::load(&config_path).unwrap();
        assert_eq!(
            persisted.record(pairing_id).unwrap().state,
            PairingCredentialState::PairRequestUnknown
        );
        assert_eq!(
            persisted.record(pairing_id).unwrap().credential_sha256,
            "1".repeat(64)
        );
    }

    #[test]
    fn committed_pairing_config_is_resumed_without_repair_after_ack_loss() {
        let directory = tempdir().unwrap();
        let config_path = directory.path().join("state").join("worker.json");
        let controller_id = Uuid::new_v4();
        let node_id = Uuid::new_v4();
        let pairing_id = Uuid::new_v4();
        let layout = prepare_pairing_layout(
            &config_path,
            None,
            false,
            controller_id,
            node_id,
            pairing_id,
        )
        .unwrap();
        let staged = load_or_create_staged_credential(&layout.credential_file).unwrap();
        let staged_digest = credential_sha256(staged.expose());
        let config = WorkerConfig {
            api_version: WORKER_CONFIG_VERSION.to_owned(),
            worker_url: "https://controller.example.invalid/worker".to_owned(),
            certificate_pem: "test-certificate".to_owned(),
            controller_id,
            node_id,
            worker_api_version: WORKER_API_VERSION.to_owned(),
            heartbeat_interval_seconds: 5,
            lease_seconds: 90,
            workspace_root: layout.workspace_root.clone(),
            credential_file: layout.credential_file.clone(),
        };
        config.write(&config_path).unwrap();
        drop(staged); // simulate loss after config rename, before/after ACK response

        let resumed = prepare_pairing_layout(
            &config_path,
            None,
            false,
            controller_id,
            node_id,
            pairing_id,
        )
        .unwrap();
        let committed = resumed.committed_config.unwrap();
        assert!(resumed.previous_credential.is_none());
        assert_eq!(committed.credential_file, layout.credential_file);
        assert_eq!(
            credential_sha256(committed.load_credential().unwrap().expose()),
            staged_digest
        );
    }

    #[test]
    fn repair_requires_the_same_controller_and_node_and_can_move_workspace() {
        let directory = tempdir().unwrap();
        let parent = directory.path().join("worker-state");
        let old_workspace = directory.path().join("old-workspace");
        prepare_private_directory(&parent).unwrap();
        prepare_private_directory(&old_workspace).unwrap();
        let old_credential = parent.join("worker.credential");
        write_secret_file(&old_credential, "opaque-worker-credential").unwrap();
        let config_path = parent.join("worker.json");
        let controller_id = Uuid::new_v4();
        let node_id = Uuid::new_v4();
        WorkerConfig {
            api_version: WORKER_CONFIG_VERSION.to_owned(),
            worker_url: "https://controller.example.invalid/worker".to_owned(),
            certificate_pem: "test-certificate".to_owned(),
            controller_id,
            node_id,
            worker_api_version: "cyc.dev/worker-api/v1".to_owned(),
            heartbeat_interval_seconds: 5,
            lease_seconds: 30,
            workspace_root: old_workspace,
            credential_file: old_credential.clone(),
        }
        .write(&config_path)
        .unwrap();

        let new_workspace = directory.path().join("selected-workspace");
        let pairing_id = Uuid::new_v4();
        let layout = prepare_pairing_layout(
            &config_path,
            Some(&new_workspace),
            true,
            controller_id,
            node_id,
            pairing_id,
        )
        .unwrap();
        assert_eq!(layout.workspace_root, new_workspace);
        assert_eq!(layout.previous_credential, Some(old_credential));
        assert_eq!(
            layout.credential_file,
            config_path.with_extension(format!("{pairing_id}.credential"))
        );

        let wrong_controller = prepare_pairing_layout(
            &config_path,
            None,
            true,
            Uuid::new_v4(),
            node_id,
            Uuid::new_v4(),
        )
        .unwrap_err();
        assert!(wrong_controller.to_string().contains("controllerId"));
        let wrong_node = prepare_pairing_layout(
            &config_path,
            None,
            true,
            controller_id,
            Uuid::new_v4(),
            Uuid::new_v4(),
        )
        .unwrap_err();
        assert!(wrong_node.to_string().contains("intendedNodeId"));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn concurrent_fresh_pair_reuses_the_winner_and_never_last_writer_wins() {
        let directory = tempdir().unwrap();
        let state = directory.path().join("state");
        let enrollment_path = state.join("enrollment.json");
        let config_path = state.join("worker.json");
        let controller_id = Uuid::new_v4();
        let node_id = Uuid::new_v4();
        let pairing_id = Uuid::new_v4();
        write_test_enrollment(&enrollment_path, pairing_id, controller_id, node_id);
        let transport = Arc::new(FakePairingTransport::new(true, false));

        let entered = transport.first_pair_entered.notified();
        let first_transport = transport.clone();
        let first_enrollment = enrollment_path.clone();
        let first_config = config_path.clone();
        let first = tokio::spawn(async move {
            pair_with_transport(
                &first_enrollment,
                &first_config,
                PairOptions::default(),
                first_transport.as_ref(),
            )
            .await
        });
        tokio::time::timeout(PAIRING_TEST_ENTRY_TIMEOUT, entered)
            .await
            .unwrap();

        let second_transport = transport.clone();
        let second_enrollment = enrollment_path.clone();
        let second_config = config_path.clone();
        let second = tokio::spawn(async move {
            pair_with_transport(
                &second_enrollment,
                &second_config,
                PairOptions::default(),
                second_transport.as_ref(),
            )
            .await
        });
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(transport.pair_calls.load(Ordering::SeqCst), 1);
        assert!(!second.is_finished(), "second pairer bypassed the OS lock");

        transport.release_first_pair.notify_one();
        let first = first.await.unwrap().unwrap();
        let second = second.await.unwrap().unwrap();
        assert_eq!(first.credential_file, second.credential_file);
        assert_eq!(first.node_id, second.node_id);
        assert_eq!(transport.pair_calls.load(Ordering::SeqCst), 1);
        assert_eq!(transport.ack_calls.load(Ordering::SeqCst), 2);
        let committed = WorkerConfig::load(&config_path).unwrap();
        assert_eq!(committed.node_id, first.node_id);
        assert_eq!(committed.credential_file, first.credential_file);
        assert!(config_path.with_extension("pair.lock").is_file());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn concurrent_different_fresh_pairing_cannot_replace_the_first_winner() {
        let directory = tempdir().unwrap();
        let state = directory.path().join("state");
        let first_enrollment = state.join("enrollment-first.json");
        let second_enrollment = state.join("enrollment-second.json");
        let config_path = state.join("worker.json");
        let controller_id = Uuid::new_v4();
        let node_id = Uuid::new_v4();
        let first_pairing_id = Uuid::new_v4();
        let second_pairing_id = Uuid::new_v4();
        write_test_enrollment(&first_enrollment, first_pairing_id, controller_id, node_id);
        write_test_enrollment(
            &second_enrollment,
            second_pairing_id,
            controller_id,
            node_id,
        );
        let transport = Arc::new(FakePairingTransport::new(true, false));

        let entered = transport.first_pair_entered.notified();
        let first_transport = transport.clone();
        let first_path = first_enrollment.clone();
        let first_config = config_path.clone();
        let first = tokio::spawn(async move {
            pair_with_transport(
                &first_path,
                &first_config,
                PairOptions::default(),
                first_transport.as_ref(),
            )
            .await
        });
        tokio::time::timeout(PAIRING_TEST_ENTRY_TIMEOUT, entered)
            .await
            .unwrap();
        let second_transport = transport.clone();
        let second_path = second_enrollment.clone();
        let second_config = config_path.clone();
        let second = tokio::spawn(async move {
            pair_with_transport(
                &second_path,
                &second_config,
                PairOptions::default(),
                second_transport.as_ref(),
            )
            .await
        });
        transport.release_first_pair.notify_one();
        let winner = first.await.unwrap().unwrap();
        let loser = second.await.unwrap().unwrap_err();
        assert!(loser.to_string().contains("--repair"));
        assert_eq!(transport.pair_calls.load(Ordering::SeqCst), 1);
        let committed = WorkerConfig::load(&config_path).unwrap();
        assert_eq!(committed.credential_file, winner.credential_file);
        assert!(committed
            .credential_file
            .to_string_lossy()
            .contains(&first_pairing_id.to_string()));
        assert!(!committed
            .credential_file
            .to_string_lossy()
            .contains(&second_pairing_id.to_string()));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn concurrent_repair_reuses_one_rotation_and_cleans_the_old_secret_once() {
        let directory = tempdir().unwrap();
        let state = directory.path().join("state");
        let workspace = directory.path().join("workspace");
        prepare_private_directory(&state).unwrap();
        prepare_private_directory(&workspace).unwrap();
        let config_path = state.join("worker.json");
        let old_credential = state.join("worker.credential");
        write_secret_file(&old_credential, "opaque-old-repair-credential").unwrap();
        let controller_id = Uuid::new_v4();
        let node_id = Uuid::new_v4();
        WorkerConfig {
            api_version: WORKER_CONFIG_VERSION.to_owned(),
            worker_url: "https://controller.example.invalid/worker".to_owned(),
            certificate_pem: "test-certificate".to_owned(),
            controller_id,
            node_id,
            worker_api_version: WORKER_API_VERSION.to_owned(),
            heartbeat_interval_seconds: 5,
            lease_seconds: 90,
            workspace_root: workspace,
            credential_file: old_credential.clone(),
        }
        .write(&config_path)
        .unwrap();
        let pairing_id = Uuid::new_v4();
        let enrollment_path = state.join("repair-enrollment.json");
        write_test_enrollment(&enrollment_path, pairing_id, controller_id, node_id);
        let transport = Arc::new(FakePairingTransport::new(true, false));
        let repair_options = PairOptions {
            workspace_root: None,
            repair: true,
        };

        let entered = transport.first_pair_entered.notified();
        let first_transport = transport.clone();
        let first_enrollment = enrollment_path.clone();
        let first_config = config_path.clone();
        let first_options = repair_options.clone();
        let first = tokio::spawn(async move {
            pair_with_transport(
                &first_enrollment,
                &first_config,
                first_options,
                first_transport.as_ref(),
            )
            .await
        });
        tokio::time::timeout(PAIRING_TEST_ENTRY_TIMEOUT, entered)
            .await
            .unwrap();

        let second_transport = transport.clone();
        let second_enrollment = enrollment_path.clone();
        let second_config = config_path.clone();
        let second = tokio::spawn(async move {
            pair_with_transport(
                &second_enrollment,
                &second_config,
                repair_options,
                second_transport.as_ref(),
            )
            .await
        });
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(transport.pair_calls.load(Ordering::SeqCst), 1);
        assert!(!second.is_finished(), "second repair bypassed the OS lock");

        transport.release_first_pair.notify_one();
        let first = first.await.unwrap().unwrap();
        let second = second.await.unwrap().unwrap();
        assert_eq!(first.credential_file, second.credential_file);
        assert!(!old_credential.exists());
        assert_eq!(transport.pair_calls.load(Ordering::SeqCst), 1);
        assert_eq!(transport.ack_calls.load(Ordering::SeqCst), 2);
        let committed = WorkerConfig::load(&config_path).unwrap();
        assert_eq!(committed.credential_file, first.credential_file);
        let ledger = PairingCredentialLedger::load(&config_path).unwrap();
        let record = ledger.record(pairing_id).unwrap();
        assert_eq!(record.state, PairingCredentialState::Acknowledged);
        assert!(!record.cleanup_pending);
    }

    #[tokio::test]
    async fn consecutive_repairs_do_not_orphan_an_older_credential_generation() {
        let directory = tempdir().unwrap();
        let state = directory.path().join("state");
        let workspace = directory.path().join("workspace");
        prepare_private_directory(&state).unwrap();
        prepare_private_directory(&workspace).unwrap();
        let config_path = state.join("worker.json");
        let initial_credential = state.join("worker.credential");
        write_secret_file(&initial_credential, "opaque-initial-worker-credential").unwrap();
        let controller_id = Uuid::new_v4();
        let node_id = Uuid::new_v4();
        WorkerConfig {
            api_version: WORKER_CONFIG_VERSION.to_owned(),
            worker_url: "https://controller.example.invalid/worker".to_owned(),
            certificate_pem: "test-certificate".to_owned(),
            controller_id,
            node_id,
            worker_api_version: WORKER_API_VERSION.to_owned(),
            heartbeat_interval_seconds: 5,
            lease_seconds: 90,
            workspace_root: workspace,
            credential_file: initial_credential.clone(),
        }
        .write(&config_path)
        .unwrap();
        let transport = FakePairingTransport::new(false, false);

        let first_pairing_id = Uuid::new_v4();
        let first_enrollment = state.join("repair-first.json");
        write_test_enrollment(&first_enrollment, first_pairing_id, controller_id, node_id);
        let first = pair_with_transport(
            &first_enrollment,
            &config_path,
            PairOptions {
                workspace_root: None,
                repair: true,
            },
            &transport,
        )
        .await
        .unwrap();
        assert!(!initial_credential.exists());
        let first_credential = first.credential_file.clone();
        assert!(first_credential.is_file());

        let second_pairing_id = Uuid::new_v4();
        let second_enrollment = state.join("repair-second.json");
        write_test_enrollment(
            &second_enrollment,
            second_pairing_id,
            controller_id,
            node_id,
        );
        let second = pair_with_transport(
            &second_enrollment,
            &config_path,
            PairOptions {
                workspace_root: None,
                repair: true,
            },
            &transport,
        )
        .await
        .unwrap();
        assert_ne!(second.credential_file, first_credential);
        assert!(!initial_credential.exists());
        assert!(!first_credential.exists());
        assert!(second.credential_file.is_file());
        assert_eq!(transport.pair_calls.load(Ordering::SeqCst), 2);
        assert_eq!(transport.ack_calls.load(Ordering::SeqCst), 2);

        let ledger = PairingCredentialLedger::load(&config_path).unwrap();
        assert!(ledger.record(first_pairing_id).is_none());
        let current = ledger.record(second_pairing_id).unwrap();
        assert_eq!(current.state, PairingCredentialState::Acknowledged);
        assert!(!current.cleanup_pending);
        assert!(!current.previous_cleanup_pending);
    }

    #[tokio::test]
    async fn new_repair_after_terminal_ack_cleans_the_complete_predecessor_chain() {
        let directory = tempdir().unwrap();
        let state = directory.path().join("state");
        let workspace = directory.path().join("workspace");
        prepare_private_directory(&state).unwrap();
        prepare_private_directory(&workspace).unwrap();
        let config_path = state.join("worker.json");
        let oldest_credential = state.join("worker.credential");
        write_secret_file(&oldest_credential, "opaque-oldest-worker-credential").unwrap();
        let controller_id = Uuid::new_v4();
        let node_id = Uuid::new_v4();
        WorkerConfig {
            api_version: WORKER_CONFIG_VERSION.to_owned(),
            worker_url: "https://controller.example.invalid/worker".to_owned(),
            certificate_pem: "test-certificate".to_owned(),
            controller_id,
            node_id,
            worker_api_version: WORKER_API_VERSION.to_owned(),
            heartbeat_interval_seconds: 5,
            lease_seconds: 90,
            workspace_root: workspace,
            credential_file: oldest_credential.clone(),
        }
        .write(&config_path)
        .unwrap();
        let transport = FakePairingTransport::new(false, false).with_terminal_first_ack();

        let terminal_pairing_id = Uuid::new_v4();
        let terminal_enrollment = state.join("repair-terminal.json");
        write_test_enrollment(
            &terminal_enrollment,
            terminal_pairing_id,
            controller_id,
            node_id,
        );
        let terminal_error = pair_with_transport(
            &terminal_enrollment,
            &config_path,
            PairOptions {
                workspace_root: None,
                repair: true,
            },
            &transport,
        )
        .await
        .unwrap_err();
        assert_eq!(
            pairing_terminal_code(&terminal_error),
            Some("pairing_ack_unauthorized")
        );
        let terminal_config = WorkerConfig::load(&config_path).unwrap();
        let terminal_credential = terminal_config.credential_file.clone();
        assert!(terminal_credential.is_file());
        assert!(oldest_credential.is_file());
        let terminal_ledger = PairingCredentialLedger::load(&config_path).unwrap();
        let terminal_record = terminal_ledger.record(terminal_pairing_id).unwrap();
        assert_eq!(
            terminal_record.state,
            PairingCredentialState::TerminalUnavailable
        );
        assert!(terminal_record.cleanup_pending);
        assert!(terminal_record.previous_cleanup_pending);

        let recovery_pairing_id = Uuid::new_v4();
        let recovery_enrollment = state.join("repair-recovery.json");
        write_test_enrollment(
            &recovery_enrollment,
            recovery_pairing_id,
            controller_id,
            node_id,
        );
        let recovered = pair_with_transport(
            &recovery_enrollment,
            &config_path,
            PairOptions {
                workspace_root: None,
                repair: true,
            },
            &transport,
        )
        .await
        .unwrap();
        assert!(!oldest_credential.exists());
        assert!(!terminal_credential.exists());
        assert!(recovered.credential_file.is_file());
        assert_eq!(transport.pair_calls.load(Ordering::SeqCst), 2);
        assert_eq!(transport.ack_calls.load(Ordering::SeqCst), 2);
        let recovered_ledger = PairingCredentialLedger::load(&config_path).unwrap();
        assert!(recovered_ledger.record(terminal_pairing_id).is_none());
        let recovered_record = recovered_ledger.record(recovery_pairing_id).unwrap();
        assert_eq!(recovered_record.state, PairingCredentialState::Acknowledged);
        assert!(!recovered_record.cleanup_pending);
        assert!(!recovered_record.previous_cleanup_pending);
    }

    #[tokio::test]
    async fn committed_fast_path_retries_durable_previous_cleanup_before_ack() {
        let directory = tempdir().unwrap();
        let state = directory.path().join("state");
        let workspace = directory.path().join("workspace");
        prepare_private_directory(&state).unwrap();
        prepare_private_directory(&workspace).unwrap();
        let config_path = state.join("worker.json");
        let controller_id = Uuid::new_v4();
        let node_id = Uuid::new_v4();
        let pairing_id = Uuid::new_v4();
        let enrollment_path = state.join("committed-enrollment.json");
        write_test_enrollment(&enrollment_path, pairing_id, controller_id, node_id);
        let enrollment = load_enrollment_bundle(&enrollment_path).unwrap();
        let current_credential = config_path.with_extension(format!("{pairing_id}.credential"));
        let current_secret = "a".repeat(64);
        write_secret_file(&current_credential, &current_secret).unwrap();
        let previous_credential = state.join("worker.credential");
        let previous_secret = "opaque-previous-cleanup-retry";
        write_secret_file(&previous_credential, previous_secret).unwrap();
        let config = WorkerConfig {
            api_version: WORKER_CONFIG_VERSION.to_owned(),
            worker_url: enrollment.worker_url.clone(),
            certificate_pem: enrollment.certificate_pem.clone(),
            controller_id,
            node_id,
            worker_api_version: WORKER_API_VERSION.to_owned(),
            heartbeat_interval_seconds: 5,
            lease_seconds: 90,
            workspace_root: workspace,
            credential_file: current_credential.clone(),
        };
        config.write(&config_path).unwrap();
        PairingCredentialLedger {
            api_version: PAIRING_LEDGER_VERSION.to_owned(),
            records: vec![PairingCredentialRecord {
                pairing_id,
                controller_id,
                node_id,
                credential_file: current_credential,
                credential_sha256: credential_sha256(&current_secret),
                created_at: enrollment.created_at,
                expires_at: enrollment.expires_at,
                state: PairingCredentialState::Acknowledged,
                previous_credential_file: Some(previous_credential.clone()),
                previous_credential_sha256: Some(credential_sha256(previous_secret)),
                previous_cleanup_pending: true,
                cleanup_pending: false,
            }],
        }
        .persist(&config_path)
        .unwrap();
        let transport = FakePairingTransport::new(false, false)
            .expect_absent_before_ack(previous_credential.clone());

        let recovered = pair_with_transport(
            &enrollment_path,
            &config_path,
            PairOptions::default(),
            &transport,
        )
        .await
        .unwrap();
        assert_eq!(recovered.credential_file, config.credential_file);
        assert!(!previous_credential.exists());
        assert_eq!(transport.pair_calls.load(Ordering::SeqCst), 0);
        assert_eq!(transport.ack_calls.load(Ordering::SeqCst), 1);
        let ledger = PairingCredentialLedger::load(&config_path).unwrap();
        let record = ledger.record(pairing_id).unwrap();
        assert_eq!(record.state, PairingCredentialState::Acknowledged);
        assert!(!record.cleanup_pending);
        assert!(!record.previous_cleanup_pending);
    }

    #[tokio::test]
    async fn repair_ack_response_loss_replays_committed_config_and_finishes_old_cleanup() {
        let directory = tempdir().unwrap();
        let state = directory.path().join("state");
        let workspace = directory.path().join("workspace");
        prepare_private_directory(&state).unwrap();
        prepare_private_directory(&workspace).unwrap();
        let config_path = state.join("worker.json");
        let old_credential = state.join("worker.credential");
        let old_secret = "opaque-old-worker-credential";
        write_secret_file(&old_credential, old_secret).unwrap();
        let controller_id = Uuid::new_v4();
        let node_id = Uuid::new_v4();
        WorkerConfig {
            api_version: WORKER_CONFIG_VERSION.to_owned(),
            worker_url: "https://controller.example.invalid/worker".to_owned(),
            certificate_pem: "test-certificate".to_owned(),
            controller_id,
            node_id,
            worker_api_version: WORKER_API_VERSION.to_owned(),
            heartbeat_interval_seconds: 5,
            lease_seconds: 90,
            workspace_root: workspace,
            credential_file: old_credential.clone(),
        }
        .write(&config_path)
        .unwrap();
        let pairing_id = Uuid::new_v4();
        let enrollment_path = state.join("repair-enrollment.json");
        write_test_enrollment(&enrollment_path, pairing_id, controller_id, node_id);
        let transport = FakePairingTransport::new(false, true);

        let first = pair_with_transport(
            &enrollment_path,
            &config_path,
            PairOptions {
                workspace_root: None,
                repair: true,
            },
            &transport,
        )
        .await;
        assert!(first
            .unwrap_err()
            .to_string()
            .contains("acknowledgement response loss"));
        assert!(old_credential.is_file());
        let committed_after_loss = WorkerConfig::load(&config_path).unwrap();
        assert_ne!(committed_after_loss.credential_file, old_credential);

        let recovered = pair_with_transport(
            &enrollment_path,
            &config_path,
            PairOptions {
                workspace_root: None,
                repair: true,
            },
            &transport,
        )
        .await
        .unwrap();
        assert_eq!(
            recovered.credential_file,
            committed_after_loss.credential_file
        );
        assert!(!old_credential.exists());
        assert_eq!(transport.pair_calls.load(Ordering::SeqCst), 1);
        assert_eq!(transport.ack_calls.load(Ordering::SeqCst), 2);

        let new_secret = recovered.load_credential().unwrap().expose().to_owned();
        let ledger_bytes = fs::read(PairingCredentialLedger::path(&config_path)).unwrap();
        let ledger_text = String::from_utf8(ledger_bytes).unwrap();
        assert!(!ledger_text.contains(old_secret));
        assert!(!ledger_text.contains(&new_secret));
        let ledger = PairingCredentialLedger::load(&config_path).unwrap();
        let record = ledger.record(pairing_id).unwrap();
        assert_eq!(record.state, PairingCredentialState::Acknowledged);
        assert!(!record.cleanup_pending);
    }

    #[test]
    fn ledger_gc_deletes_only_definite_terminal_records_and_protects_unknown_and_invocation() {
        let directory = tempdir().unwrap();
        let state = directory.path().join("state");
        prepare_private_directory(&state).unwrap();
        let config_path = state.join("worker.json");
        let controller_id = Uuid::new_v4();
        let node_id = Uuid::new_v4();
        let revoked_id = Uuid::new_v4();
        let superseded_id = Uuid::new_v4();
        let expired_id = Uuid::new_v4();
        let unknown_id = Uuid::new_v4();
        let invocation_id = Uuid::new_v4();
        let mut expired = ledger_record_with_secret(
            &config_path,
            expired_id,
            controller_id,
            node_id,
            PairingCredentialState::Staged,
            "expired-stage-secret",
        );
        expired.created_at = Utc::now() - chrono::Duration::minutes(10);
        expired.expires_at = Utc::now() - chrono::Duration::minutes(1);
        let mut unknown = ledger_record_with_secret(
            &config_path,
            unknown_id,
            controller_id,
            node_id,
            PairingCredentialState::PairRequestUnknown,
            "unknown-stage-secret",
        );
        // Even a malformed prior cleanup attempt cannot authorize deletion of
        // an uncertain request state.
        unknown.cleanup_pending = true;
        let mut ledger = PairingCredentialLedger {
            api_version: PAIRING_LEDGER_VERSION.to_owned(),
            records: vec![
                ledger_record_with_secret(
                    &config_path,
                    revoked_id,
                    controller_id,
                    node_id,
                    PairingCredentialState::TerminalUnavailable,
                    "revoked-stage-secret",
                ),
                ledger_record_with_secret(
                    &config_path,
                    superseded_id,
                    controller_id,
                    node_id,
                    PairingCredentialState::Superseded,
                    "superseded-stage-secret",
                ),
                expired,
                unknown,
                ledger_record_with_secret(
                    &config_path,
                    invocation_id,
                    controller_id,
                    node_id,
                    PairingCredentialState::TerminalUnavailable,
                    "invocation-stage-secret",
                ),
            ],
        };
        ledger.persist(&config_path).unwrap();

        garbage_collect_pairing_credentials(
            &config_path,
            &mut ledger,
            None,
            Some(invocation_id),
            controller_id,
            node_id,
        )
        .unwrap();
        for pairing_id in [revoked_id, superseded_id, expired_id] {
            assert!(!config_path
                .with_extension(format!("{pairing_id}.credential"))
                .exists());
        }
        assert!(config_path
            .with_extension(format!("{unknown_id}.credential"))
            .is_file());
        assert!(config_path
            .with_extension(format!("{invocation_id}.credential"))
            .is_file());

        garbage_collect_pairing_credentials(
            &config_path,
            &mut ledger,
            None,
            None,
            controller_id,
            node_id,
        )
        .unwrap();
        assert!(!config_path
            .with_extension(format!("{invocation_id}.credential"))
            .exists());
        assert!(config_path
            .with_extension(format!("{unknown_id}.credential"))
            .is_file());
    }

    #[test]
    fn ledger_gc_protects_current_config_and_rejects_a_different_binding() {
        let directory = tempdir().unwrap();
        let state = directory.path().join("state");
        let workspace = directory.path().join("workspace");
        prepare_private_directory(&state).unwrap();
        prepare_private_directory(&workspace).unwrap();
        let config_path = state.join("worker.json");
        let controller_id = Uuid::new_v4();
        let node_id = Uuid::new_v4();
        let current_id = Uuid::new_v4();
        let current = ledger_record_with_secret(
            &config_path,
            current_id,
            controller_id,
            node_id,
            PairingCredentialState::TerminalUnavailable,
            "current-config-secret",
        );
        let current_path = current.credential_file.clone();
        let config = WorkerConfig {
            api_version: WORKER_CONFIG_VERSION.to_owned(),
            worker_url: "https://controller.example.invalid/worker".to_owned(),
            certificate_pem: "test-certificate".to_owned(),
            controller_id,
            node_id,
            worker_api_version: WORKER_API_VERSION.to_owned(),
            heartbeat_interval_seconds: 5,
            lease_seconds: 90,
            workspace_root: workspace,
            credential_file: current_path.clone(),
        };
        let other_id = Uuid::new_v4();
        let other_controller = Uuid::new_v4();
        let other_node = Uuid::new_v4();
        let other = ledger_record_with_secret(
            &config_path,
            other_id,
            other_controller,
            other_node,
            PairingCredentialState::TerminalUnavailable,
            "other-binding-secret",
        );
        let other_path = other.credential_file.clone();
        let mut ledger = PairingCredentialLedger {
            api_version: PAIRING_LEDGER_VERSION.to_owned(),
            records: vec![current, other],
        };
        ledger.persist(&config_path).unwrap();

        let error = garbage_collect_pairing_credentials(
            &config_path,
            &mut ledger,
            Some(&config),
            None,
            controller_id,
            node_id,
        )
        .unwrap_err();
        assert!(error.to_string().contains("different controller or node"));
        assert!(current_path.is_file());
        assert!(other_path.is_file());

        // Once unrelated state is absent, the current config remains protected
        // even though its record carries a terminal cleanup marker.
        remove_protected_file(&other_path).unwrap();
        ledger.records.pop();
        ledger.persist(&config_path).unwrap();
        garbage_collect_pairing_credentials(
            &config_path,
            &mut ledger,
            Some(&config),
            None,
            controller_id,
            node_id,
        )
        .unwrap();
        assert!(current_path.is_file());
        assert!(ledger.record(current_id).unwrap().cleanup_pending);
    }

    #[test]
    fn digest_mismatch_retains_cleanup_and_a_corrected_retry_converges() {
        let directory = tempdir().unwrap();
        let state = directory.path().join("state");
        prepare_private_directory(&state).unwrap();
        let config_path = state.join("worker.json");
        let controller_id = Uuid::new_v4();
        let node_id = Uuid::new_v4();
        let pairing_id = Uuid::new_v4();
        let mut record = ledger_record_with_secret(
            &config_path,
            pairing_id,
            controller_id,
            node_id,
            PairingCredentialState::TerminalUnavailable,
            "digest-bound-secret",
        );
        let exact_path = record.credential_file.clone();
        let correct_digest = record.credential_sha256.clone();
        record.credential_sha256 = "0".repeat(64);
        let mut ledger = PairingCredentialLedger {
            api_version: PAIRING_LEDGER_VERSION.to_owned(),
            records: vec![record],
        };
        ledger.persist(&config_path).unwrap();

        assert!(garbage_collect_pairing_credentials(
            &config_path,
            &mut ledger,
            None,
            None,
            controller_id,
            node_id,
        )
        .is_err());
        assert!(exact_path.is_file());
        let persisted = PairingCredentialLedger::load(&config_path).unwrap();
        assert!(persisted.record(pairing_id).unwrap().cleanup_pending);

        ledger.record_mut(pairing_id).unwrap().credential_sha256 = correct_digest;
        ledger.persist(&config_path).unwrap();
        garbage_collect_pairing_credentials(
            &config_path,
            &mut ledger,
            None,
            None,
            controller_id,
            node_id,
        )
        .unwrap();
        assert!(!exact_path.exists());
    }

    #[cfg(unix)]
    #[test]
    fn gc_rejects_symlink_and_weak_acl_without_deleting_bytes() {
        use std::os::unix::fs::{symlink, PermissionsExt};

        let directory = tempdir().unwrap();
        let state = directory.path().join("state");
        prepare_private_directory(&state).unwrap();
        let config_path = state.join("worker.json");
        let controller_id = Uuid::new_v4();
        let node_id = Uuid::new_v4();

        let link_id = Uuid::new_v4();
        let link_path = config_path.with_extension(format!("{link_id}.credential"));
        let outside = directory.path().join("outside-secret");
        fs::write(&outside, b"outside-secret").unwrap();
        symlink(&outside, &link_path).unwrap();
        let link_record = PairingCredentialRecord {
            pairing_id: link_id,
            controller_id,
            node_id,
            credential_file: link_path.clone(),
            credential_sha256: credential_sha256("outside-secret"),
            created_at: Utc::now() - chrono::Duration::minutes(1),
            expires_at: Utc::now() + chrono::Duration::minutes(1),
            state: PairingCredentialState::TerminalUnavailable,
            previous_credential_file: None,
            previous_credential_sha256: None,
            previous_cleanup_pending: false,
            cleanup_pending: true,
        };
        let mut ledger = PairingCredentialLedger {
            api_version: PAIRING_LEDGER_VERSION.to_owned(),
            records: vec![link_record],
        };
        ledger.persist(&config_path).unwrap();
        assert!(garbage_collect_pairing_credentials(
            &config_path,
            &mut ledger,
            None,
            None,
            controller_id,
            node_id,
        )
        .is_err());
        assert_eq!(fs::read(&outside).unwrap(), b"outside-secret");
        fs::remove_file(&link_path).unwrap();

        let weak_id = Uuid::new_v4();
        let weak = ledger_record_with_secret(
            &config_path,
            weak_id,
            controller_id,
            node_id,
            PairingCredentialState::TerminalUnavailable,
            "weak-acl-secret",
        );
        let weak_path = weak.credential_file.clone();
        fs::set_permissions(&weak_path, fs::Permissions::from_mode(0o644)).unwrap();
        ledger.records = vec![weak];
        ledger.persist(&config_path).unwrap();
        assert!(garbage_collect_pairing_credentials(
            &config_path,
            &mut ledger,
            None,
            None,
            controller_id,
            node_id,
        )
        .is_err());
        assert!(weak_path.is_file());
        fs::set_permissions(&weak_path, fs::Permissions::from_mode(0o600)).unwrap();
        garbage_collect_pairing_credentials(
            &config_path,
            &mut ledger,
            None,
            None,
            controller_id,
            node_id,
        )
        .unwrap();
        assert!(!weak_path.exists());
    }

    #[tokio::test]
    async fn status_and_run_reject_a_workspace_that_became_weak() {
        let directory = tempdir().unwrap();
        let parent = directory.path().join("worker-state");
        let workspace = parent.join("workspace");
        prepare_private_directory(&parent).unwrap();
        prepare_private_directory(&workspace).unwrap();
        let credential = parent.join("worker.credential");
        write_secret_file(&credential, "opaque-worker-credential").unwrap();
        let config_path = parent.join("worker.json");
        let config = WorkerConfig {
            api_version: WORKER_CONFIG_VERSION.to_owned(),
            worker_url: "https://controller.example.invalid/worker".to_owned(),
            certificate_pem: "test-certificate".to_owned(),
            controller_id: Uuid::new_v4(),
            node_id: Uuid::new_v4(),
            worker_api_version: "cyc.dev/worker-api/v1".to_owned(),
            heartbeat_interval_seconds: 5,
            lease_seconds: 30,
            workspace_root: workspace.clone(),
            credential_file: credential,
        };
        config.write(&config_path).unwrap();
        make_directory_weak(&workspace);

        let status_error = status(&config_path).err().unwrap();
        assert!(format!("{status_error:#}").contains("workspace"));
        assert!(
            format!("{:#}", run_forever(&config_path).await.unwrap_err()).contains("workspace")
        );
        assert!(ensure_protected_directory(&workspace).is_err());
    }

    #[cfg(windows)]
    #[test]
    fn pairing_rejects_a_prepositioned_workspace_junction() {
        let directory = tempdir().unwrap();
        let parent = directory.path().join("worker-state");
        let backing = directory.path().join("backing");
        prepare_private_directory(&parent).unwrap();
        prepare_private_directory(&backing).unwrap();
        let workspace = parent.join("workspace");
        create_directory_junction(&workspace, &backing);

        let error = prepare_new_pairing_layout(&parent.join("worker.json")).unwrap_err();
        assert!(format!("{error:#}").contains("reparse"));
        assert!(!path_entry_exists(&parent.join("worker.json")).unwrap());

        fs::remove_dir(&workspace).unwrap();
    }

    #[cfg(windows)]
    #[test]
    fn guard_rejects_a_junction_anywhere_in_its_existing_path_chain() {
        let directory = tempdir().unwrap();
        let mut config = worker_config(&directory);
        fs::remove_dir(&config.workspace_root).unwrap();

        let backing = directory.path().join("backing");
        let backing_workspace = backing.join("workspace");
        let junction = directory.path().join("junction");
        fs::create_dir_all(&backing_workspace).unwrap();
        create_directory_junction(&junction, &backing);
        config.workspace_root = junction.join("workspace");

        // The workspace itself resolves as an ordinary directory. The guard
        // must still walk upward and reject the junction above it before a
        // claim or temporary/marker creation can occur.
        let claim_error = refuse_containment_quarantine(&config).unwrap_err();
        assert!(format!("{claim_error:#}").contains("reparse point"));
        let arm_error = ActiveRunGuard::arm(&config, Uuid::new_v4()).unwrap_err();
        assert!(format!("{arm_error:#}").contains("reparse point"));
        assert!(!path_entry_exists(&containment_quarantine_path(&config)).unwrap());

        fs::remove_dir(&junction).unwrap();
    }

    #[tokio::test]
    async fn guard_is_durable_before_work_can_spawn_and_clears_after_ack() {
        let directory = tempdir().unwrap();
        let config = worker_config(&directory);
        let run_id = Uuid::new_v4();
        let marker = containment_quarantine_path(&config);

        run_guarded_assignment(&config, run_id, async {
            // This block models the first source/job spawn. It cannot receive
            // a poll until run_guarded_assignment has durably armed the file.
            assert!(path_entry_exists(&marker).unwrap());
            verify_active_run_guard(&marker, config.node_id, run_id).unwrap();

            // The Linux containment tests enable a process-wide subreaper and
            // intentionally inspect/terminate newly adopted children. Keep
            // this deliberately uncontained probe mutually exclusive with
            // those tests so a concurrent managed tree cannot claim it.
            let _child_process_guard = crate::process::test_exclusive_child_process_guard().await;

            #[cfg(unix)]
            let status = std::process::Command::new("sh")
                .args(["-c", "test -f \"$1\"", "guard-check"])
                .arg(&marker)
                .status()
                .unwrap();
            #[cfg(windows)]
            let status = std::process::Command::new("cmd.exe")
                .args(["/D", "/C", "exit /b 0"])
                .status()
                .unwrap();
            assert!(status.success(), "guarded work did not spawn successfully");

            // Production reaches Ok only after source/step containment is
            // ConfirmedEmpty and submit_completion returns a matching terminal
            // controller acknowledgement.
            Ok(())
        })
        .await
        .unwrap();

        assert!(!path_entry_exists(&marker).unwrap());
    }

    #[tokio::test]
    async fn post_claim_error_retains_guard_and_blocks_restart() {
        let directory = tempdir().unwrap();
        let config = worker_config(&directory);
        let run_id = Uuid::new_v4();
        let marker = containment_quarantine_path(&config);

        let error = run_guarded_assignment(&config, run_id, async {
            Err(anyhow::anyhow!(
                "controller terminal acknowledgement was lost"
            ))
        })
        .await
        .unwrap_err();
        assert!(error.downcast_ref::<AssignmentQuarantined>().is_some());
        verify_active_run_guard(&marker, config.node_id, run_id).unwrap();

        let restarted = config.clone();
        assert!(refuse_containment_quarantine(&restarted).is_err());
    }

    #[tokio::test]
    async fn guard_clear_fault_parks_instead_of_returning_to_supervisor() {
        let directory = tempdir().unwrap();
        let config = worker_config(&directory);
        let run_id = Uuid::new_v4();
        let marker = containment_quarantine_path(&config);

        let error = run_guarded_assignment_inner(&config, run_id, async { Ok(()) }, true)
            .await
            .unwrap_err();
        assert!(error.downcast_ref::<GuardDurabilityLost>().is_some());
        assert!(path_entry_exists(&marker).unwrap());

        let parked = tokio::time::timeout(
            Duration::from_millis(25),
            handle_guarded_assignment_error(error),
        )
        .await;
        assert!(
            parked.is_err(),
            "guard durability failure returned instead of parking"
        );
        assert!(path_entry_exists(&marker).unwrap());
    }

    #[test]
    fn malformed_or_non_file_marker_is_fail_closed() {
        let directory = tempdir().unwrap();
        let config = worker_config(&directory);
        let marker = containment_quarantine_path(&config);
        fs::write(&marker, b"{truncated").unwrap();

        assert!(refuse_containment_quarantine(&config).is_err());
        assert!(ActiveRunGuard::arm(&config, Uuid::new_v4()).is_err());
    }

    #[test]
    fn post_ack_cleanup_removes_only_the_exact_owned_run_root() {
        let directory = tempdir().unwrap();
        let workspace = directory.path().join("private-workspace");
        prepare_private_directory(&workspace).unwrap();
        let jobs = workspace.join("jobs");
        fs::create_dir(&jobs).unwrap();
        let run_id = Uuid::new_v4();
        let run_root = jobs.join(run_id.to_string());
        fs::create_dir(&run_root).unwrap();
        fs::write(run_root.join("result.txt"), b"complete").unwrap();
        let relative = format!("jobs/{run_id}");

        assert_eq!(
            remove_job_root_after_terminal_ack(&workspace, run_id, &relative).unwrap(),
            JobRootCleanupOutcomeV1::Removed
        );
        assert!(!path_entry_exists(&run_root).unwrap());
        assert_eq!(
            remove_job_root_after_terminal_ack(&workspace, run_id, &relative).unwrap(),
            JobRootCleanupOutcomeV1::NotCreated
        );
        assert!(remove_job_root_after_terminal_ack(
            &workspace,
            run_id,
            &format!("jobs/{}", Uuid::new_v4())
        )
        .is_err());
    }

    #[cfg(unix)]
    #[test]
    fn post_ack_cleanup_rejects_links_without_deleting_their_targets() {
        use std::os::unix::fs::symlink;

        let directory = tempdir().unwrap();
        let workspace = directory.path().join("private-workspace");
        prepare_private_directory(&workspace).unwrap();
        let jobs = workspace.join("jobs");
        fs::create_dir(&jobs).unwrap();
        let run_id = Uuid::new_v4();
        let run_root = jobs.join(run_id.to_string());
        fs::create_dir(&run_root).unwrap();
        let outside = directory.path().join("outside");
        fs::create_dir(&outside).unwrap();
        fs::write(outside.join("keep.txt"), b"keep").unwrap();
        symlink(&outside, run_root.join("escape")).unwrap();

        assert!(
            remove_job_root_after_terminal_ack(&workspace, run_id, &format!("jobs/{run_id}"))
                .is_err()
        );
        assert!(outside.join("keep.txt").exists());
        assert!(run_root.exists());
    }
}
