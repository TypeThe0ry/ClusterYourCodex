use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use chrono::{DateTime, Utc};
use cyc_protocol::onboarding::{PairingFailureCodeV1, PairingPhaseV1};
use cyc_protocol::worker::{
    ExecutionEvidence, NodeReportRequest, RunCompletion, StreamEvidence, TerminationReason,
    MAX_SAFE_JSON_INTEGER,
};
use cyc_protocol::{
    canonical_job_digest, normalize_job_spec, validate_portable_relative_path,
    CleanupFailureCodeV1, CleanupFailureV1, CleanupReceiptV1, CleanupReservationReleaseReasonV1,
    GpuResourceRequest, JobKind, JobSpec, JobState, Node, NodeConfig, NodeInventory, NodeMergeView,
    NodeStateError, NodeTelemetry, NodeTransport, OperatingSystem, PlacementPlanBindingV1,
    PlacementPlanDecisionV1, Run, Shell, SnapshotMetadataV1, SourceSpec,
    MAX_SNAPSHOT_ARCHIVE_BYTES, PLACEMENT_PLAN_BINDING_API_VERSION, SNAPSHOT_API_VERSION,
    SNAPSHOT_ARCHIVE_FORMAT,
};
use cyc_scheduler::{PlacementDecision, ScheduleError, Scheduler, SchedulingNode};
use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use serde::{de::DeserializeOwned, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;
use uuid::Uuid;

pub const PLAN_TTL_SECONDS: i64 = 60;
pub const NODE_FRESHNESS_SECONDS: i64 = cyc_scheduler::DEFAULT_NODE_FRESHNESS_TTL.as_secs() as i64;
pub const POLICY_REVISION: i64 = 3;
pub const PAIRING_TTL_SECONDS: i64 = 600;
pub const DISPATCH_TTL_SECONDS: i64 = 30;
pub const CLAIM_TTL_SECONDS: i64 = 90;
/// A terminal managed run keeps its capacity reservation while the worker
/// removes the run-owned workspace.  This durable deadline bounds leakage if
/// the worker never returns the authoritative `removed` receipt.
pub const CLEANUP_RESERVATION_TTL_SECONDS: i64 = 15 * 60;
pub const MAX_RUN_LOG_BYTES: u64 = 16 * 1024 * 1024;
pub const MAX_RUN_LOG_CHUNKS: u64 = 4_096;
pub const MAX_RUN_ARTIFACT_BYTES: u64 = 64 * 1024 * 1024;
pub const MAX_RUN_ARTIFACT_COUNT: u32 = 1_000;

const LEASE_PHASE_DISPATCH: &str = "dispatch";
const LEASE_PHASE_EXECUTION: &str = "execution";
const LEASE_PHASE_CLEANUP_PENDING: &str = "cleanup_pending";
const PLACEMENT_ATTEMPT_INITIAL: &str = "initial_dispatch";
const PLACEMENT_ATTEMPT_DISPATCH_EXPIRED: &str = "dispatch_lease_expired";
const CLEANUP_RELEASE_REMOVED: &str = "removed_receipt";
const CLEANUP_RELEASE_DEADLINE: &str = "deadline_recovery";
const CLEANUP_RELEASE_LEGACY: &str = "legacy_migration";
const CLEANUP_FAILURE_DEADLINE: &str = "removed_receipt_deadline_exceeded";
const CLEANUP_FAILURE_LEGACY: &str = "legacy_release_without_cleanup_evidence";
#[cfg(test)]
const LEASE_PHASE_LEGACY: &str = "legacy";

#[derive(Debug, Error)]
pub enum StoreError {
    #[error("controller storage security validation failed")]
    StorageSecurity(#[source] anyhow::Error),
    #[error("database operation failed")]
    Database(#[from] rusqlite::Error),
    #[error("stored document is invalid")]
    Document(#[from] serde_json::Error),
    #[error("stored node state is invalid")]
    NodeState(#[from] NodeStateError),
    #[error("node config or reserved policy labels are invalid")]
    InvalidNodeConfig,
    #[error("worker node report is invalid")]
    InvalidNodeReport,
    #[error("stored node row identity does not match its document")]
    NodeIdentityMismatch,
    #[error("stored identifier is invalid")]
    Identifier(#[from] uuid::Error),
    #[error("stored timestamp is invalid")]
    Timestamp,
    #[error("controller database lock is poisoned")]
    Poisoned,
    #[error("job or plan does not exist")]
    NotFound,
    #[error("job already exists")]
    Conflict,
    #[error("invalid state transition")]
    InvalidTransition,
    #[error("run has a pending cancellation request")]
    CancellationPending,
    #[error("run evidence is invalid for the requested state")]
    InvalidRunEvidence,
    #[error("optimistic concurrency version mismatch")]
    VersionConflict { current_version: u64 },
    #[error("node config revision mismatch")]
    NodeConfigVersionConflict { current_revision: i64 },
    #[error("worker run state changed")]
    WorkerStateConflict {
        current_version: u64,
        cancel_requested: bool,
        current_state: JobState,
    },
    #[error("plan has expired")]
    PlanExpired,
    #[error("plan no longer matches controller state")]
    PlanStale,
    #[error("plan JobSpec digest does not match")]
    PlanDigestMismatch,
    #[error("stored placement plan binding is invalid")]
    InvalidPlanBinding,
    #[error("placement failed")]
    Schedule(#[from] ScheduleError),
    #[error("worker authentication failed")]
    WorkerUnauthorized,
    #[error("pairing code is expired, used, or revoked")]
    PairingUnavailable,
    #[error("pairing request does not match the consumed pairing binding")]
    PairingBindingMismatch,
    #[error("pairing credential digest is invalid")]
    InvalidCredentialDigest,
    #[error("pairing acknowledgement is not authorized for this staged credential")]
    PairingAcknowledgementUnavailable,
    #[error("pairing idempotency key is invalid")]
    InvalidPairingOperationKey,
    #[error("pairing idempotency key was already used with a different request")]
    PairingIdempotencyMismatch,
    #[error("pairing idempotency operation is no longer pending ({phase:?})")]
    PairingIdempotencyFinalized { phase: PairingPhaseV1 },
    #[error("stored pairing failure state is invalid")]
    InvalidPairingFailureState,
    #[error("pairing failure conflicts with the immutable stored failure code")]
    PairingFailureMismatch,
    #[error("pairing can no longer transition to failed ({phase:?})")]
    PairingFailureFinalized { phase: PairingPhaseV1 },
    #[error("paired node is not a managed worker")]
    InvalidManagedNode,
    #[error("worker does not own this run")]
    RunUnauthorized,
    #[error("worker upload conflicts with stored data")]
    UploadConflict,
    #[error("worker upload offset is not contiguous")]
    UploadOffset,
    #[error("worker upload digest does not match")]
    DigestMismatch,
    #[error("worker upload metadata is invalid")]
    InvalidUpload,
    #[error("run log quota is exhausted")]
    LogQuotaExceeded,
    #[error("run artifact quota is exhausted")]
    ArtifactQuotaExceeded,
    #[error("snapshot archive exceeds the controller limit")]
    SnapshotQuotaExceeded,
    #[error("cleanup receipt is invalid or does not match the terminal acknowledgement")]
    InvalidCleanupReceipt,
    #[error("cleanup receipt conflicts with the immutable stored receipt")]
    CleanupConflict,
    #[error("controller fleet revision is outside the exact JSON integer range")]
    InvalidFleetRevision,
    #[error("controller object storage failed")]
    Io(#[from] std::io::Error),
}

pub type StoreResult<T> = Result<T, StoreError>;

#[derive(Clone)]
pub struct Store {
    connection: Arc<Mutex<Connection>>,
    object_root: Arc<PathBuf>,
    snapshot_root: Arc<PathBuf>,
}

#[derive(Debug, Clone)]
pub struct StoredJob {
    pub job: JobSpec,
    pub run: Run,
    /// Controller-authored evidence for the active placement attempt. Every
    /// superseded value remains immutable in `job_placement_attempts`. `None`
    /// is reserved for pre-binding legacy rows which could not be backfilled.
    pub plan_binding: Option<PlacementPlanBindingV1>,
    pub version: u64,
    pub cancel_requested: bool,
    pub lease_id: Option<Uuid>,
}

#[derive(Debug, Clone)]
pub struct StoredPlan {
    pub binding: PlacementPlanBindingV1,
    pub used_at: Option<DateTime<Utc>>,
}

/// Evidence supplied by the worker while committing a terminal run state.
/// The controller never infers success or failure without this data.
#[derive(Debug, Clone, Default)]
pub struct RunEvidence {
    pub exit_code: Option<i32>,
    pub error: Option<String>,
    pub artifact_ids: Option<Vec<Uuid>>,
}

#[derive(Debug, Clone)]
pub struct LeaseRenewal {
    pub run_id: Uuid,
    pub lease_id: Uuid,
    pub expires_at: DateTime<Utc>,
}

// Deliberately not `Debug`: this value owns a one-time plaintext pairing code.
pub struct PairingSecret {
    pub id: Uuid,
    pub intended_node_id: Uuid,
    pub code: String,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}

/// Result of an idempotent enrollment issue. The one-time code remains in the
/// non-`Debug` `PairingSecret`; endpoint material is the immutable snapshot
/// captured by the first request, so retries return byte-for-byte equivalent
/// enrollment fields even if the active listener identity later changes.
pub struct IdempotentPairing {
    pub pairing: PairingSecret,
    pub worker_url: String,
    pub certificate_pem: String,
    pub replayed: bool,
}

impl Drop for PairingSecret {
    fn drop(&mut self) {
        unsafe { self.code.as_bytes_mut().fill(0) };
    }
}

#[derive(Debug, Clone)]
pub struct StoredPairingStatus {
    pub pairing_id: Uuid,
    pub intended_node_id: Uuid,
    pub node_id: Option<Uuid>,
    pub phase: PairingPhaseV1,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
    pub consumed_at: Option<DateTime<Utc>>,
    pub acknowledged_at: Option<DateTime<Utc>>,
    pub revoked_at: Option<DateTime<Utc>>,
    pub failed_at: Option<DateTime<Utc>>,
    pub failure_code: Option<PairingFailureCodeV1>,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct PairedWorker {
    pub pairing_id: Uuid,
    pub node_id: Uuid,
    pub credential_sha256: String,
    pub consumed_at: DateTime<Utc>,
    pub replayed: bool,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct PairingAcknowledgement {
    pub pairing_id: Uuid,
    pub node_id: Uuid,
    pub credential_sha256: String,
    pub acknowledged_at: DateTime<Utc>,
}

// Deliberately not `Debug`: this value owns the run's plaintext credential.
#[derive(Clone)]
pub struct WorkerClaim {
    pub stored: StoredJob,
    pub job_digest: String,
    pub lease_id: Uuid,
    pub lease_until: DateTime<Utc>,
    pub run_credential: String,
}

#[derive(Debug, Clone)]
pub struct WorkerHeartbeat {
    pub stored: StoredJob,
    pub lease_id: Uuid,
    pub lease_until: DateTime<Utc>,
}

#[derive(Debug, Clone)]
pub struct LogChunk {
    pub run_id: Uuid,
    pub stream: String,
    pub offset: u64,
    pub length: u64,
    pub sha256: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone)]
pub struct StoredArtifact {
    pub id: Uuid,
    pub run_id: Uuid,
    pub name: String,
    pub size: u64,
    pub sha256: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone)]
pub struct StoredSnapshot {
    pub metadata: SnapshotMetadataV1,
    relative_path: PathBuf,
}

#[derive(Debug, Clone)]
pub struct SnapshotDownload {
    pub metadata: SnapshotMetadataV1,
    pub path: PathBuf,
}

#[derive(Debug, Clone)]
pub struct StoredCompletion {
    pub completion: RunCompletion,
    pub sha256: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone)]
pub struct StoredCleanup {
    pub receipt: cyc_protocol::CleanupReceiptV1,
    pub received_at: DateTime<Utc>,
}

/// Durable controller-side binding for the post-terminal cleanup reservation.
/// No credential material is stored here: only identifiers, the immutable
/// terminal receipt digest, and cleanup/recovery evidence.
#[derive(Debug, Clone, Eq, PartialEq)]
pub struct StoredCleanupObligation {
    pub job_id: Uuid,
    pub run_id: Uuid,
    pub lease_id: Uuid,
    pub state_version: u64,
    pub final_state: JobState,
    pub completion_sha256: String,
    pub terminal_acknowledged_at: DateTime<Utc>,
    pub cleanup_deadline_at: DateTime<Utc>,
    pub reservation_released_at: Option<DateTime<Utc>>,
    pub release_reason: Option<CleanupReservationReleaseReasonV1>,
    pub cleanup_failure: Option<CleanupFailureV1>,
}

#[derive(Debug, Clone)]
pub struct CleanupSnapshot {
    pub stored: StoredJob,
    pub cleanup: Option<StoredCleanup>,
    pub completion: Option<StoredCompletion>,
    pub obligation: Option<StoredCleanupObligation>,
}

#[derive(Debug, Clone)]
pub struct StoredNodeConfig {
    pub node_id: Uuid,
    pub revision: i64,
    pub config: NodeConfig,
}

#[derive(Debug, Clone)]
pub struct NodeReportOutcome {
    pub node_id: Uuid,
    pub accepted: bool,
    pub inventory_revision: i64,
    pub inventory_digest: String,
    pub telemetry_boot_generation: u64,
    pub telemetry_boot_id: Uuid,
    pub telemetry_sequence: u64,
    pub received_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FleetDocument<T> {
    pub document: T,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub revision: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub digest: Option<String>,
    pub observed_at: DateTime<Utc>,
    pub received_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FleetSlotView {
    pub configured: u32,
    pub containment_max_safe: u32,
    pub effective: u32,
    pub reserved: u32,
    pub available: u32,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FleetReservationView {
    pub lease_id: Uuid,
    pub run_id: Uuid,
    pub job_id: Uuid,
    pub phase: String,
    pub slots: u32,
    pub cpu_cores: u32,
    pub memory_mib: u64,
    pub disk_mib: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gpu_device_id: Option<String>,
    pub gpu_vram_mib: u64,
    pub gpu_exclusive: bool,
    pub expires_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FleetNodeView {
    pub node_id: Uuid,
    pub config: FleetDocument<NodeConfig>,
    pub inventory: FleetDocument<NodeInventory>,
    pub telemetry: FleetDocument<NodeTelemetry>,
    pub availability: cyc_protocol::NodeAvailability,
    pub availability_reasons: Vec<String>,
    pub effective_slots: FleetSlotView,
    pub effective_resources: cyc_protocol::NodeResources,
    pub reservations: Vec<FleetReservationView>,
}

/// One authoritative `/v1/fleet` read.  Every field is decoded from the same
/// SQLite snapshot and uses the same controller observation timestamp.
#[derive(Debug, Clone)]
pub struct FleetSnapshot {
    pub fleet_revision: u64,
    pub observed_at: DateTime<Utc>,
    pub nodes: Vec<Node>,
    pub node_views: Vec<FleetNodeView>,
    pub recent_jobs: Vec<StoredJob>,
}

#[derive(Default)]
struct ReservationTotals {
    slots: u64,
    cpu_cores: u64,
    memory_mib: u64,
    disk_mib: u64,
    gpu_reservations: u64,
    count: u64,
}

#[derive(Clone, Debug, Default)]
struct GpuReservationTotals {
    vram_mib: u64,
    exclusive: bool,
    count: u32,
}

impl Store {
    pub fn open(path: impl AsRef<Path>) -> StoreResult<Self> {
        let path = path.as_ref();
        crate::auth::prepare_database_layout(path).map_err(StoreError::StorageSecurity)?;
        let object_root = path
            .parent()
            .filter(|path| !path.as_os_str().is_empty())
            .unwrap_or_else(|| Path::new("."))
            .join("jobs");
        let store = Self::from_connection(Connection::open(path)?, object_root)?;
        crate::auth::finalize_database_layout(path).map_err(StoreError::StorageSecurity)?;
        Ok(store)
    }

    pub fn in_memory() -> StoreResult<Self> {
        Self::from_connection(
            Connection::open_in_memory()?,
            std::env::temp_dir()
                .join(format!("cyc-store-{}", Uuid::new_v4()))
                .join("jobs"),
        )
    }

    fn from_connection(connection: Connection, object_root: PathBuf) -> StoreResult<Self> {
        connection.busy_timeout(Duration::from_secs(5))?;
        connection.pragma_update(None, "foreign_keys", "ON")?;
        connection.pragma_update(None, "journal_mode", "WAL")?;
        connection.pragma_update(None, "synchronous", "NORMAL")?;
        let snapshot_root = object_root
            .parent()
            .filter(|path| !path.as_os_str().is_empty())
            .unwrap_or_else(|| Path::new("."))
            .join("snapshots");
        let store = Self {
            connection: Arc::new(Mutex::new(connection)),
            object_root: Arc::new(object_root),
            snapshot_root: Arc::new(snapshot_root),
        };
        store.migrate()?;
        Ok(store)
    }

    fn connection(&self) -> StoreResult<MutexGuard<'_, Connection>> {
        self.connection.lock().map_err(|_| StoreError::Poisoned)
    }

    fn migrate(&self) -> StoreResult<()> {
        let mut connection = self.connection()?;
        connection.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS controller_meta (
                key TEXT PRIMARY KEY NOT NULL,
                value INTEGER NOT NULL
            );
            INSERT OR IGNORE INTO controller_meta(key, value) VALUES ('fleet_revision', 0);
            INSERT OR IGNORE INTO controller_meta(key, value) VALUES ('policy_revision', 1);
            CREATE TABLE IF NOT EXISTS controller_identity (
                singleton INTEGER PRIMARY KEY NOT NULL CHECK(singleton = 1),
                id TEXT UNIQUE NOT NULL
            );
            CREATE TABLE IF NOT EXISTS controller_secrets (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS nodes (
                id TEXT PRIMARY KEY NOT NULL,
                document TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                revision INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS node_configs (
                node_id TEXT PRIMARY KEY NOT NULL,
                document TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                revision INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS node_inventories (
                node_id TEXT PRIMARY KEY NOT NULL,
                document TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                revision INTEGER NOT NULL DEFAULT 0,
                digest TEXT NOT NULL DEFAULT '',
                observed_at TEXT NOT NULL DEFAULT '1970-01-01T00:00:00+00:00'
            );
            CREATE TABLE IF NOT EXISTS node_telemetry (
                node_id TEXT PRIMARY KEY NOT NULL,
                document TEXT NOT NULL,
                received_at TEXT NOT NULL,
                boot_generation INTEGER NOT NULL DEFAULT 0,
                boot_id TEXT NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000',
                sequence INTEGER NOT NULL DEFAULT 0,
                observed_at TEXT NOT NULL DEFAULT '1970-01-01T00:00:00+00:00'
            );
            CREATE TABLE IF NOT EXISTS node_telemetry_boots (
                node_id TEXT NOT NULL,
                boot_id TEXT NOT NULL,
                first_received_at TEXT NOT NULL,
                PRIMARY KEY(node_id, boot_id)
            );
            CREATE TABLE IF NOT EXISTS plans (
                id TEXT PRIMARY KEY NOT NULL,
                job_id TEXT NOT NULL,
                decision TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                job_digest TEXT NOT NULL DEFAULT '',
                expires_at INTEGER NOT NULL DEFAULT 0,
                fleet_revision INTEGER NOT NULL DEFAULT 0,
                node_revision INTEGER NOT NULL DEFAULT 0,
                policy_revision INTEGER NOT NULL DEFAULT 0,
                used_at INTEGER
            );
            CREATE TABLE IF NOT EXISTS jobs (
                run_id TEXT PRIMARY KEY NOT NULL,
                job_id TEXT UNIQUE NOT NULL,
                job TEXT NOT NULL,
                run TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                version INTEGER NOT NULL DEFAULT 0,
                cancel_requested INTEGER NOT NULL DEFAULT 0,
                lease_id TEXT,
                plan_binding TEXT
            );
            CREATE TABLE IF NOT EXISTS job_placement_attempts (
                run_id TEXT NOT NULL,
                attempt INTEGER NOT NULL,
                plan_id TEXT UNIQUE NOT NULL,
                node_id TEXT NOT NULL,
                plan_binding TEXT NOT NULL,
                reason TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                PRIMARY KEY(run_id, attempt)
            );
            CREATE INDEX IF NOT EXISTS job_placement_attempts_run_idx
                ON job_placement_attempts(run_id, attempt DESC);
            CREATE TABLE IF NOT EXISTS leases (
                id TEXT PRIMARY KEY NOT NULL,
                run_id TEXT UNIQUE NOT NULL,
                job_id TEXT NOT NULL,
                node_id TEXT NOT NULL,
                cpu_cores INTEGER NOT NULL,
                memory_mib INTEGER NOT NULL,
                disk_mib INTEGER NOT NULL,
                gpu_reserved INTEGER NOT NULL,
                slots INTEGER NOT NULL DEFAULT 1,
                phase TEXT NOT NULL DEFAULT 'legacy',
                created_at INTEGER NOT NULL,
                expires_at INTEGER NOT NULL,
                released_at INTEGER
            );
            CREATE INDEX IF NOT EXISTS jobs_updated_at_idx ON jobs(updated_at DESC);
            CREATE INDEX IF NOT EXISTS leases_active_node_idx
                ON leases(node_id, expires_at, released_at);

            CREATE TABLE IF NOT EXISTS lease_gpu_reservations (
                lease_id TEXT PRIMARY KEY NOT NULL,
                device_id TEXT NOT NULL,
                vram_mib INTEGER NOT NULL,
                exclusive INTEGER NOT NULL,
                FOREIGN KEY(lease_id) REFERENCES leases(id)
            );

            CREATE TABLE IF NOT EXISTS pairings (
                id TEXT PRIMARY KEY NOT NULL,
                code_hash TEXT UNIQUE NOT NULL,
                created_at INTEGER NOT NULL,
                expires_at INTEGER NOT NULL,
                used_at INTEGER,
                acknowledged_at INTEGER,
                revoked_at INTEGER,
                node_id TEXT,
                intended_node_id TEXT,
                failed_at INTEGER,
                failure_code TEXT
            );
            CREATE INDEX IF NOT EXISTS pairings_expiry_idx
                ON pairings(expires_at, used_at, revoked_at);

            CREATE TABLE IF NOT EXISTS pairing_operations (
                operation_key TEXT PRIMARY KEY NOT NULL,
                pairing_id TEXT UNIQUE NOT NULL,
                requested_node_id TEXT,
                worker_url TEXT NOT NULL,
                certificate_pem TEXT NOT NULL,
                FOREIGN KEY(pairing_id) REFERENCES pairings(id)
            );

            CREATE TABLE IF NOT EXISTS worker_credentials (
                id TEXT PRIMARY KEY NOT NULL,
                pairing_id TEXT NOT NULL,
                node_id TEXT NOT NULL,
                credential_hash TEXT UNIQUE NOT NULL,
                created_at INTEGER NOT NULL,
                activated_at INTEGER,
                last_used_at INTEGER,
                revoked_at INTEGER,
                FOREIGN KEY(pairing_id) REFERENCES pairings(id)
            );
            CREATE INDEX IF NOT EXISTS worker_credentials_node_idx
                ON worker_credentials(node_id, revoked_at);

            CREATE TABLE IF NOT EXISTS worker_claims (
                run_id TEXT PRIMARY KEY NOT NULL,
                node_id TEXT NOT NULL,
                lease_id TEXT NOT NULL,
                credential_hash TEXT UNIQUE NOT NULL,
                created_at INTEGER NOT NULL,
                expires_at INTEGER NOT NULL,
                revoked_at INTEGER,
                FOREIGN KEY(run_id) REFERENCES jobs(run_id),
                FOREIGN KEY(lease_id) REFERENCES leases(id)
            );
            CREATE INDEX IF NOT EXISTS worker_claims_expiry_idx
                ON worker_claims(expires_at, revoked_at);

            CREATE TABLE IF NOT EXISTS log_chunks (
                run_id TEXT NOT NULL,
                stream TEXT NOT NULL,
                chunk_offset INTEGER NOT NULL,
                chunk_length INTEGER NOT NULL,
                sha256 TEXT NOT NULL,
                relative_path TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                PRIMARY KEY(run_id, stream, chunk_offset),
                FOREIGN KEY(run_id) REFERENCES jobs(run_id)
            );

            CREATE TABLE IF NOT EXISTS artifacts (
                id TEXT PRIMARY KEY NOT NULL,
                run_id TEXT NOT NULL,
                name TEXT NOT NULL,
                size INTEGER NOT NULL,
                sha256 TEXT NOT NULL,
                relative_path TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                FOREIGN KEY(run_id) REFERENCES jobs(run_id)
            );
            CREATE INDEX IF NOT EXISTS artifacts_run_idx ON artifacts(run_id, created_at);

            CREATE TABLE IF NOT EXISTS snapshots (
                digest TEXT PRIMARY KEY NOT NULL,
                size INTEGER NOT NULL,
                api_version TEXT NOT NULL,
                archive_format TEXT NOT NULL,
                relative_path TEXT NOT NULL,
                created_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS run_completions (
                run_id TEXT PRIMARY KEY NOT NULL,
                document TEXT NOT NULL,
                document_sha256 TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                FOREIGN KEY(run_id) REFERENCES jobs(run_id)
            );

            CREATE TABLE IF NOT EXISTS run_cleanups (
                run_id TEXT PRIMARY KEY NOT NULL,
                document TEXT NOT NULL,
                document_sha256 TEXT NOT NULL,
                received_at INTEGER NOT NULL,
                FOREIGN KEY(run_id) REFERENCES jobs(run_id)
            );

            CREATE TABLE IF NOT EXISTS run_cleanup_obligations (
                run_id TEXT PRIMARY KEY NOT NULL,
                job_id TEXT NOT NULL,
                lease_id TEXT UNIQUE NOT NULL,
                state_version INTEGER NOT NULL,
                final_state TEXT NOT NULL,
                completion_sha256 TEXT NOT NULL,
                terminal_acknowledged_at INTEGER NOT NULL,
                cleanup_deadline_at INTEGER NOT NULL,
                reservation_released_at INTEGER,
                release_reason TEXT,
                cleanup_failure_code TEXT,
                failure_observed_at INTEGER,
                FOREIGN KEY(run_id) REFERENCES jobs(run_id),
                FOREIGN KEY(lease_id) REFERENCES leases(id)
            );
            CREATE INDEX IF NOT EXISTS run_cleanup_obligations_deadline_idx
                ON run_cleanup_obligations(cleanup_deadline_at, reservation_released_at);
            "#,
        )?;

        migrate_pairing_ack_schema(&mut connection)?;
        migrate_pairing_failure_schema(&mut connection)?;

        connection.execute(
            "INSERT OR IGNORE INTO controller_identity(singleton, id) VALUES (1, ?1)",
            [Uuid::new_v4().to_string()],
        )?;
        connection.execute(
            "INSERT OR IGNORE INTO controller_secrets(key, value) VALUES ('pairing_prf_seed_v1', ?1)",
            [random_secret()],
        )?;

        ensure_column(
            &connection,
            "nodes",
            "revision",
            "INTEGER NOT NULL DEFAULT 0",
        )?;
        ensure_column(
            &connection,
            "node_configs",
            "revision",
            "INTEGER NOT NULL DEFAULT 0",
        )?;
        ensure_column(
            &connection,
            "node_inventories",
            "revision",
            "INTEGER NOT NULL DEFAULT 0",
        )?;
        ensure_column(
            &connection,
            "node_inventories",
            "digest",
            "TEXT NOT NULL DEFAULT ''",
        )?;
        ensure_column(
            &connection,
            "node_inventories",
            "observed_at",
            "TEXT NOT NULL DEFAULT '1970-01-01T00:00:00+00:00'",
        )?;
        ensure_column(
            &connection,
            "node_telemetry",
            "boot_generation",
            "INTEGER NOT NULL DEFAULT 0",
        )?;
        ensure_column(
            &connection,
            "node_telemetry",
            "boot_id",
            "TEXT NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000'",
        )?;
        ensure_column(
            &connection,
            "node_telemetry",
            "sequence",
            "INTEGER NOT NULL DEFAULT 0",
        )?;
        ensure_column(
            &connection,
            "node_telemetry",
            "observed_at",
            "TEXT NOT NULL DEFAULT '1970-01-01T00:00:00+00:00'",
        )?;
        migrate_legacy_node_documents(&connection)?;
        backfill_node_report_metadata(&connection)?;
        connection.execute(
            r#"
            INSERT OR IGNORE INTO node_telemetry_boots(node_id, boot_id, first_received_at)
            SELECT node_id, boot_id, received_at FROM node_telemetry
            WHERE boot_id != '' AND boot_id != ?1
            "#,
            [Uuid::nil().to_string()],
        )?;
        ensure_column(
            &connection,
            "plans",
            "job_digest",
            "TEXT NOT NULL DEFAULT ''",
        )?;
        ensure_column(
            &connection,
            "plans",
            "expires_at",
            "INTEGER NOT NULL DEFAULT 0",
        )?;
        ensure_column(
            &connection,
            "plans",
            "fleet_revision",
            "INTEGER NOT NULL DEFAULT 0",
        )?;
        ensure_column(
            &connection,
            "plans",
            "node_revision",
            "INTEGER NOT NULL DEFAULT 0",
        )?;
        ensure_column(
            &connection,
            "plans",
            "policy_revision",
            "INTEGER NOT NULL DEFAULT 0",
        )?;
        ensure_column(&connection, "plans", "used_at", "INTEGER")?;
        ensure_column(&connection, "jobs", "version", "INTEGER NOT NULL DEFAULT 0")?;
        ensure_column(
            &connection,
            "jobs",
            "cancel_requested",
            "INTEGER NOT NULL DEFAULT 0",
        )?;
        ensure_column(&connection, "jobs", "lease_id", "TEXT")?;
        ensure_column(&connection, "jobs", "plan_binding", "TEXT")?;
        ensure_column(&connection, "leases", "slots", "INTEGER NOT NULL DEFAULT 1")?;
        ensure_column(
            &connection,
            "leases",
            "phase",
            "TEXT NOT NULL DEFAULT 'legacy'",
        )?;
        // A historical live worker_claim proves execution ownership. Other
        // historical leases retain `legacy` timeout behavior rather than being
        // silently reinterpreted as never-started dispatches.
        connection.execute(
            r#"
            UPDATE leases SET phase = 'execution'
            WHERE phase = 'legacy' AND released_at IS NULL
              AND expires_at > CAST(strftime('%s', 'now') AS INTEGER)
              AND EXISTS(
                SELECT 1 FROM worker_claims c
                WHERE c.lease_id = leases.id AND c.revoked_at IS NULL
                  AND c.expires_at > CAST(strftime('%s', 'now') AS INTEGER)
            )
            "#,
            [],
        )?;
        migrate_cleanup_reservation_schema(&mut connection)?;
        ensure_column(&connection, "pairings", "intended_node_id", "TEXT")?;
        // Historical consumed rows already carry their stable identity in
        // node_id. Historical pending rows use their unique pairing id as a
        // deterministic intended identity so status/pairing remains stable.
        connection.execute(
            r#"
            UPDATE pairings SET intended_node_id = COALESCE(node_id, id)
            WHERE intended_node_id IS NULL OR intended_node_id = ''
            "#,
            [],
        )?;
        connection.execute(
            "UPDATE controller_meta SET value = ?1 WHERE key = 'policy_revision' AND value < ?1",
            [POLICY_REVISION],
        )?;
        // Plans from the pre-digest schema are ephemeral and cannot be safely
        // reused under the normalized scheduling contract.
        connection.execute(
            "DELETE FROM plans WHERE job_digest = '' OR expires_at <= 0",
            [],
        )?;
        migrate_job_plan_bindings(&mut connection)?;
        migrate_job_placement_attempts(&mut connection)?;
        Ok(())
    }

    pub fn ping(&self) -> StoreResult<()> {
        self.connection()?
            .query_row("SELECT 1", [], |_row| Ok(()))?;
        Ok(())
    }

    pub fn controller_id(&self) -> StoreResult<Uuid> {
        let value = self.connection()?.query_row(
            "SELECT id FROM controller_identity WHERE singleton = 1",
            [],
            |row| row.get::<_, String>(0),
        )?;
        Ok(Uuid::parse_str(&value)?)
    }

    pub fn journal_mode(&self) -> StoreResult<String> {
        Ok(self
            .connection()?
            .query_row("PRAGMA journal_mode", [], |row| row.get(0))?)
    }

    pub fn upsert_node(&self, node: &Node) -> StoreResult<()> {
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        upsert_node_tx(&transaction, node, NodeWriteAuthority::Controller)?;
        transaction.commit()?;
        Ok(())
    }

    /// Refresh node liveness without invalidating placement plans. Scheduling
    /// material must continue to flow through `upsert_node`.
    pub fn touch_node(&self, node_id: Uuid) -> StoreResult<()> {
        let now = Utc::now().to_rfc3339();
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let changed = transaction.execute(
            "UPDATE node_telemetry SET received_at = ?1 WHERE node_id = ?2",
            params![now, node_id.to_string()],
        )?;
        if changed == 0 {
            return Err(StoreError::NotFound);
        }
        transaction.execute(
            "UPDATE nodes SET updated_at = ?1 WHERE id = ?2",
            params![now, node_id.to_string()],
        )?;
        transaction.commit()?;
        Ok(())
    }

    pub fn list_nodes(&self) -> StoreResult<Vec<Node>> {
        self.list_node_views()?
            .into_iter()
            .map(|view| view.to_node().map_err(StoreError::from))
            .collect()
    }

    pub fn list_node_views(&self) -> StoreResult<Vec<NodeMergeView>> {
        let connection = self.connection()?;
        list_all_node_views(&connection, Utc::now())
    }

    pub fn list_fleet_node_views(&self) -> StoreResult<Vec<FleetNodeView>> {
        let now = Utc::now();
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        expire_leases(&transaction, now.timestamp())?;
        let views = list_fleet_node_views_tx(&transaction, now)?;
        transaction.commit()?;
        Ok(views)
    }

    /// Return every `/v1/fleet` data source from one SQLite read snapshot.
    /// Lease/deadline maintenance is committed first; the following deferred
    /// transaction is read-only and pins one WAL snapshot across all queries.
    pub fn fleet_snapshot(&self, recent_job_limit: usize) -> StoreResult<FleetSnapshot> {
        let mut connection = self.connection()?;
        {
            let maintenance =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            expire_leases(&maintenance, Utc::now().timestamp())?;
            maintenance.commit()?;
        }

        let transaction = connection.transaction_with_behavior(TransactionBehavior::Deferred)?;
        // The revision SELECT is deliberately first: it pins the WAL read
        // snapshot before the controller observation clock is captured. No
        // later concurrent commit can therefore appear to predate observedAt.
        let fleet_revision = read_safe_fleet_revision(&transaction)?;
        let observed_at = Utc::now();
        let snapshot =
            read_fleet_snapshot_tx(&transaction, fleet_revision, observed_at, recent_job_limit)?;
        transaction.commit()?;
        Ok(snapshot)
    }

    pub fn get_node_config(&self, node_id: Uuid) -> StoreResult<StoredNodeConfig> {
        let connection = self.connection()?;
        let (document, revision) = connection
            .query_row(
                "SELECT document, revision FROM node_configs WHERE node_id = ?1",
                [node_id.to_string()],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
            )
            .optional()?
            .ok_or(StoreError::NotFound)?;
        Ok(StoredNodeConfig {
            node_id,
            revision,
            config: serde_json::from_str(&document)?,
        })
    }

    pub fn update_node_config(
        &self,
        node_id: Uuid,
        expected_revision: i64,
        config: &NodeConfig,
    ) -> StoreResult<StoredNodeConfig> {
        config
            .validate()
            .map_err(|_| StoreError::InvalidNodeConfig)?;
        validate_reserved_policy_labels(config)?;
        effective_capacity_policy(config)?;
        if expected_revision < 0 {
            return Err(StoreError::InvalidNodeConfig);
        }
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let row = transaction
            .query_row(
                r#"
                SELECT c.revision, i.document, t.document, t.received_at, n.revision
                FROM node_configs c
                JOIN node_inventories i ON i.node_id = c.node_id
                JOIN node_telemetry t ON t.node_id = c.node_id
                JOIN nodes n ON n.id = c.node_id
                WHERE c.node_id = ?1
                "#,
                [node_id.to_string()],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, String>(3)?,
                        row.get::<_, i64>(4)?,
                    ))
                },
            )
            .optional()?
            .ok_or(StoreError::NotFound)?;
        if row.0 != expected_revision {
            return Err(StoreError::NodeConfigVersionConflict {
                current_revision: row.0,
            });
        }
        let next_revision = row.0.saturating_add(1);
        let now = Utc::now();
        let received_at = DateTime::parse_from_rfc3339(&row.3)
            .map_err(|_| StoreError::Timestamp)?
            .with_timezone(&Utc);
        let view = NodeMergeView::merge(
            node_id,
            config.clone(),
            serde_json::from_str(&row.1)?,
            serde_json::from_str(&row.2)?,
            received_at,
            now,
            Duration::from_secs(u64::try_from(NODE_FRESHNESS_SECONDS).unwrap_or_default()),
        )?;
        let changed = transaction.execute(
            r#"
            UPDATE node_configs SET document = ?1, updated_at = ?2, revision = ?3
            WHERE node_id = ?4 AND revision = ?5
            "#,
            params![
                serde_json::to_string(config)?,
                now.to_rfc3339(),
                next_revision,
                node_id.to_string(),
                expected_revision,
            ],
        )?;
        if changed != 1 {
            return Err(StoreError::NodeConfigVersionConflict {
                current_revision: row.0,
            });
        }
        transaction.execute(
            r#"
            UPDATE nodes SET document = ?1, updated_at = ?2, revision = ?3 WHERE id = ?4
            "#,
            params![
                serde_json::to_string(&view.to_node()?)?,
                now.to_rfc3339(),
                row.4.saturating_add(1),
                node_id.to_string(),
            ],
        )?;
        increment_meta(&transaction, "fleet_revision")?;
        transaction.commit()?;
        Ok(StoredNodeConfig {
            node_id,
            revision: next_revision,
            config: config.clone(),
        })
    }

    pub fn create_pairing(&self) -> StoreResult<PairingSecret> {
        self.create_pairing_for(None)
    }

    pub fn create_pairing_for(&self, intended_node_id: Option<Uuid>) -> StoreResult<PairingSecret> {
        let now = timestamp(Utc::now().timestamp())?;
        let pairing = PairingSecret {
            id: Uuid::new_v4(),
            intended_node_id: intended_node_id.unwrap_or_else(Uuid::new_v4),
            code: random_secret(),
            created_at: now,
            expires_at: now + chrono::Duration::seconds(PAIRING_TTL_SECONDS),
        };
        let hash = secret_hash(&pairing.code);
        self.connection()?.execute(
            r#"
            INSERT INTO pairings(
                id, code_hash, created_at, expires_at, used_at, revoked_at, node_id,
                intended_node_id
            )
            VALUES (?1, ?2, ?3, ?4, NULL, NULL, NULL, ?5)
            "#,
            params![
                pairing.id.to_string(),
                hash,
                pairing.created_at.timestamp(),
                pairing.expires_at.timestamp(),
                pairing.intended_node_id.to_string(),
            ],
        )?;
        Ok(pairing)
    }

    /// Issue or replay an enrollment bundle under a durable controller-side
    /// operation key. The plaintext pairing code is never persisted: it is
    /// deterministically derived from a private controller seed plus immutable
    /// operation fields, while only its normal verifier hash is stored in the
    /// `pairings` table.
    pub fn create_pairing_idempotent(
        &self,
        operation_key: &str,
        requested_node_id: Option<Uuid>,
        worker_url: &str,
        certificate_pem: &str,
    ) -> StoreResult<IdempotentPairing> {
        if !valid_pairing_operation_key(operation_key) {
            return Err(StoreError::InvalidPairingOperationKey);
        }
        if worker_url.is_empty()
            || worker_url.len() > 2_048
            || worker_url.chars().any(char::is_control)
            || certificate_pem.is_empty()
            || certificate_pem.len() > 128 * 1024
        {
            return Err(StoreError::InvalidUpload);
        }

        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let seed = transaction.query_row(
            "SELECT value FROM controller_secrets WHERE key = 'pairing_prf_seed_v1'",
            [],
            |row| row.get::<_, String>(0),
        )?;
        let existing = transaction
            .query_row(
                r#"
                SELECT
                    p.id, p.intended_node_id, p.created_at, p.expires_at,
                    p.used_at, p.acknowledged_at, p.node_id,
                    p.revoked_at,
                    p.failed_at, p.failure_code,
                    EXISTS(SELECT 1 FROM nodes n WHERE n.id = p.node_id),
                    (
                        SELECT COUNT(*) FROM worker_credentials wc
                        WHERE wc.pairing_id = p.id
                    ),
                    (
                        SELECT COUNT(*) FROM worker_credentials wc
                        WHERE wc.pairing_id = p.id
                          AND wc.node_id = p.node_id
                          AND wc.activated_at IS NULL
                          AND wc.revoked_at IS NULL
                    ),
                    (
                        SELECT COUNT(*) FROM worker_credentials wc
                        WHERE wc.pairing_id = p.id
                          AND wc.node_id = p.node_id
                          AND wc.activated_at IS NOT NULL
                          AND wc.revoked_at IS NULL
                    ),
                    (
                        SELECT COUNT(*) FROM worker_credentials wc
                        WHERE wc.pairing_id = p.id
                          AND wc.node_id = p.node_id
                          AND wc.activated_at IS NULL
                          AND wc.revoked_at IS NOT NULL
                    ),
                    (
                        SELECT COUNT(*) FROM worker_credentials wc
                        WHERE wc.pairing_id = p.id
                          AND wc.node_id = p.node_id
                          AND wc.activated_at IS NOT NULL
                          AND wc.revoked_at IS NOT NULL
                    ),
                    o.requested_node_id,
                    o.worker_url, o.certificate_pem
                FROM pairing_operations o
                JOIN pairings p ON p.id = o.pairing_id
                WHERE o.operation_key = ?1
                "#,
                [operation_key],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, i64>(3)?,
                        row.get::<_, Option<i64>>(4)?,
                        row.get::<_, Option<i64>>(5)?,
                        row.get::<_, Option<String>>(6)?,
                        row.get::<_, Option<i64>>(7)?,
                        row.get::<_, Option<i64>>(8)?,
                        row.get::<_, Option<String>>(9)?,
                        row.get::<_, i64>(10)? != 0,
                        row.get::<_, i64>(11)?,
                        row.get::<_, i64>(12)?,
                        row.get::<_, i64>(13)?,
                        row.get::<_, i64>(14)?,
                        row.get::<_, i64>(15)?,
                        row.get::<_, Option<String>>(16)?,
                        row.get::<_, String>(17)?,
                        row.get::<_, String>(18)?,
                    ))
                },
            )
            .optional()?;

        if let Some(existing) = existing {
            let original_request = existing
                .16
                .as_deref()
                .map(Uuid::parse_str)
                .transpose()
                .map_err(|_| StoreError::InvalidPairingFailureState)?;
            if original_request != requested_node_id {
                return Err(StoreError::PairingIdempotencyMismatch);
            }
            let created_at = timestamp(existing.2)?;
            let expires_at = timestamp(existing.3)?;
            let (failed_at, _) = pairing_failure_state(existing.8, existing.9.as_deref())?;
            let intended_node_id =
                Uuid::parse_str(&existing.1).map_err(|_| StoreError::InvalidPairingFailureState)?;
            let node_id = existing
                .6
                .as_deref()
                .map(Uuid::parse_str)
                .transpose()
                .map_err(|_| StoreError::InvalidPairingFailureState)?;
            let phase = classify_pairing_phase(
                intended_node_id,
                node_id,
                expires_at,
                existing.4.is_some(),
                existing.5.is_some(),
                existing.7.is_some(),
                failed_at.is_some(),
                existing.10,
                PairingCredentialState {
                    total: existing.11,
                    staged_unrevoked: existing.12,
                    active_unrevoked: existing.13,
                    staged_revoked: existing.14,
                    active_revoked: existing.15,
                },
                Utc::now(),
            )?;
            if phase != PairingPhaseV1::Pending {
                return Err(StoreError::PairingIdempotencyFinalized { phase });
            }
            let pairing_id = Uuid::parse_str(&existing.0)?;
            let code = derive_pairing_code(
                &seed,
                operation_key,
                pairing_id,
                intended_node_id,
                created_at.timestamp(),
            );
            return Ok(IdempotentPairing {
                pairing: PairingSecret {
                    id: pairing_id,
                    intended_node_id,
                    code,
                    created_at,
                    expires_at,
                },
                worker_url: existing.17,
                certificate_pem: existing.18,
                replayed: true,
            });
        }

        let created_at = timestamp(Utc::now().timestamp())?;
        let expires_at = created_at + chrono::Duration::seconds(PAIRING_TTL_SECONDS);
        let pairing_id = Uuid::new_v4();
        let intended_node_id = requested_node_id.unwrap_or_else(Uuid::new_v4);
        let code = derive_pairing_code(
            &seed,
            operation_key,
            pairing_id,
            intended_node_id,
            created_at.timestamp(),
        );
        transaction.execute(
            r#"
            INSERT INTO pairings(
                id, code_hash, created_at, expires_at, used_at, revoked_at, node_id,
                intended_node_id
            ) VALUES (?1, ?2, ?3, ?4, NULL, NULL, NULL, ?5)
            "#,
            params![
                pairing_id.to_string(),
                secret_hash(&code),
                created_at.timestamp(),
                expires_at.timestamp(),
                intended_node_id.to_string(),
            ],
        )?;
        transaction.execute(
            r#"
            INSERT INTO pairing_operations(
                operation_key, pairing_id, requested_node_id, worker_url, certificate_pem
            ) VALUES (?1, ?2, ?3, ?4, ?5)
            "#,
            params![
                operation_key,
                pairing_id.to_string(),
                requested_node_id.map(|id| id.to_string()),
                worker_url,
                certificate_pem,
            ],
        )?;
        transaction.commit()?;
        Ok(IdempotentPairing {
            pairing: PairingSecret {
                id: pairing_id,
                intended_node_id,
                code,
                created_at,
                expires_at,
            },
            worker_url: worker_url.to_owned(),
            certificate_pem: certificate_pem.to_owned(),
            replayed: false,
        })
    }

    pub fn get_pairing_status(&self, pairing_id: Uuid) -> StoreResult<StoredPairingStatus> {
        let connection = self.connection()?;
        let row = connection
            .query_row(
                r#"
                SELECT
                    p.intended_node_id,
                    p.node_id,
                    p.created_at,
                    p.expires_at,
                    p.used_at,
                    p.acknowledged_at,
                    p.revoked_at,
                    p.failed_at,
                    p.failure_code,
                    EXISTS(SELECT 1 FROM nodes n WHERE n.id = p.node_id),
                    (
                        SELECT COUNT(*) FROM worker_credentials wc
                        WHERE wc.pairing_id = p.id
                    ),
                    (
                        SELECT COUNT(*) FROM worker_credentials wc
                        WHERE wc.pairing_id = p.id
                          AND wc.node_id = p.node_id
                          AND wc.activated_at IS NULL
                          AND wc.revoked_at IS NULL
                    ),
                    (
                        SELECT COUNT(*) FROM worker_credentials wc
                        WHERE wc.pairing_id = p.id
                          AND wc.node_id = p.node_id
                          AND wc.activated_at IS NOT NULL
                          AND wc.revoked_at IS NULL
                    ),
                    (
                        SELECT COUNT(*) FROM worker_credentials wc
                        WHERE wc.pairing_id = p.id
                          AND wc.node_id = p.node_id
                          AND wc.activated_at IS NULL
                          AND wc.revoked_at IS NOT NULL
                    ),
                    (
                        SELECT COUNT(*) FROM worker_credentials wc
                        WHERE wc.pairing_id = p.id
                          AND wc.node_id = p.node_id
                          AND wc.activated_at IS NOT NULL
                          AND wc.revoked_at IS NOT NULL
                    )
                FROM pairings p WHERE p.id = ?1
                "#,
                [pairing_id.to_string()],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, Option<String>>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, i64>(3)?,
                        row.get::<_, Option<i64>>(4)?,
                        row.get::<_, Option<i64>>(5)?,
                        row.get::<_, Option<i64>>(6)?,
                        row.get::<_, Option<i64>>(7)?,
                        row.get::<_, Option<String>>(8)?,
                        row.get::<_, i64>(9)? != 0,
                        row.get::<_, i64>(10)?,
                        row.get::<_, i64>(11)?,
                        row.get::<_, i64>(12)?,
                        row.get::<_, i64>(13)?,
                        row.get::<_, i64>(14)?,
                    ))
                },
            )
            .optional()?
            .ok_or(StoreError::NotFound)?;
        let intended_node_id =
            Uuid::parse_str(&row.0).map_err(|_| StoreError::InvalidPairingFailureState)?;
        let node_id = row
            .1
            .as_deref()
            .map(Uuid::parse_str)
            .transpose()
            .map_err(|_| StoreError::InvalidPairingFailureState)?;
        let created_at = timestamp(row.2)?;
        let expires_at = timestamp(row.3)?;
        let consumed_at = row.4.map(timestamp).transpose()?;
        let acknowledged_at = row.5.map(timestamp).transpose()?;
        let revoked_at = row.6.map(timestamp).transpose()?;
        let (failed_at, failure_code) = pairing_failure_state(row.7, row.8.as_deref())?;
        let phase = classify_pairing_phase(
            intended_node_id,
            node_id,
            expires_at,
            consumed_at.is_some(),
            acknowledged_at.is_some(),
            revoked_at.is_some(),
            failed_at.is_some(),
            row.9,
            PairingCredentialState {
                total: row.10,
                staged_unrevoked: row.11,
                active_unrevoked: row.12,
                staged_revoked: row.13,
                active_revoked: row.14,
            },
            Utc::now(),
        )?;
        Ok(StoredPairingStatus {
            pairing_id,
            intended_node_id,
            node_id,
            phase,
            created_at,
            expires_at,
            consumed_at,
            acknowledged_at,
            revoked_at,
            failed_at,
            failure_code,
        })
    }

    /// Persist a bounded, non-secret enrollment failure. Failure is a terminal
    /// transition from a live pending pairing. A same-code replay is read-only
    /// and succeeds so a lost controller response cannot change the evidence.
    pub fn fail_pairing(
        &self,
        pairing_id: Uuid,
        failure_code: PairingFailureCodeV1,
    ) -> StoreResult<()> {
        let now = Utc::now().timestamp();
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let row = transaction
            .query_row(
                r#"
                SELECT
                    p.intended_node_id, p.node_id, p.expires_at, p.used_at,
                    p.acknowledged_at, p.revoked_at, p.failed_at, p.failure_code,
                    EXISTS(SELECT 1 FROM nodes n WHERE n.id = p.node_id),
                    (SELECT COUNT(*) FROM worker_credentials wc WHERE wc.pairing_id = p.id),
                    (
                        SELECT COUNT(*) FROM worker_credentials wc
                        WHERE wc.pairing_id = p.id
                          AND wc.node_id = p.node_id
                          AND wc.activated_at IS NULL
                          AND wc.revoked_at IS NULL
                    ),
                    (
                        SELECT COUNT(*) FROM worker_credentials wc
                        WHERE wc.pairing_id = p.id
                          AND wc.node_id = p.node_id
                          AND wc.activated_at IS NOT NULL
                          AND wc.revoked_at IS NULL
                    ),
                    (
                        SELECT COUNT(*) FROM worker_credentials wc
                        WHERE wc.pairing_id = p.id
                          AND wc.node_id = p.node_id
                          AND wc.activated_at IS NULL
                          AND wc.revoked_at IS NOT NULL
                    ),
                    (
                        SELECT COUNT(*) FROM worker_credentials wc
                        WHERE wc.pairing_id = p.id
                          AND wc.node_id = p.node_id
                          AND wc.activated_at IS NOT NULL
                          AND wc.revoked_at IS NOT NULL
                    )
                FROM pairings p WHERE p.id = ?1
                "#,
                [pairing_id.to_string()],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, Option<String>>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, Option<i64>>(3)?,
                        row.get::<_, Option<i64>>(4)?,
                        row.get::<_, Option<i64>>(5)?,
                        row.get::<_, Option<i64>>(6)?,
                        row.get::<_, Option<String>>(7)?,
                        row.get::<_, i64>(8)? != 0,
                        row.get::<_, i64>(9)?,
                        row.get::<_, i64>(10)?,
                        row.get::<_, i64>(11)?,
                        row.get::<_, i64>(12)?,
                        row.get::<_, i64>(13)?,
                    ))
                },
            )
            .optional()?
            .ok_or(StoreError::NotFound)?;

        let intended_node_id =
            Uuid::parse_str(&row.0).map_err(|_| StoreError::InvalidPairingFailureState)?;
        let node_id = row
            .1
            .as_deref()
            .map(Uuid::parse_str)
            .transpose()
            .map_err(|_| StoreError::InvalidPairingFailureState)?;
        let expires_at = timestamp(row.2).map_err(|_| StoreError::InvalidPairingFailureState)?;
        let (failed_at, stored_failure_code) = pairing_failure_state(row.6, row.7.as_deref())?;
        let phase = classify_pairing_phase(
            intended_node_id,
            node_id,
            expires_at,
            row.3.is_some(),
            row.4.is_some(),
            row.5.is_some(),
            failed_at.is_some(),
            row.8,
            PairingCredentialState {
                total: row.9,
                staged_unrevoked: row.10,
                active_unrevoked: row.11,
                staged_revoked: row.12,
                active_revoked: row.13,
            },
            Utc::now(),
        )?;
        match phase {
            PairingPhaseV1::Pending => {}
            PairingPhaseV1::Failed => {
                if stored_failure_code == Some(failure_code) {
                    transaction.commit()?;
                    return Ok(());
                }
                return Err(StoreError::PairingFailureMismatch);
            }
            phase => return Err(StoreError::PairingFailureFinalized { phase }),
        }

        let changed = transaction.execute(
            r#"
            UPDATE pairings SET failed_at = ?1, failure_code = ?2
            WHERE id = ?3 AND used_at IS NULL AND acknowledged_at IS NULL
              AND revoked_at IS NULL AND failed_at IS NULL AND failure_code IS NULL
              AND node_id IS NULL AND expires_at > ?1
              AND NOT EXISTS(
                  SELECT 1 FROM worker_credentials wc
                  WHERE wc.pairing_id = pairings.id
              )
            "#,
            params![
                now,
                pairing_failure_code_name(failure_code),
                pairing_id.to_string(),
            ],
        )?;
        if changed != 1 {
            return Err(StoreError::InvalidPairingFailureState);
        }
        transaction.commit()?;
        Ok(())
    }

    /// Validate a one-time pairing code without consuming it. The worker
    /// listener uses this before polling the request body so an unauthenticated
    /// client cannot make the controller buffer an enrollment document first.
    /// `consume_pairing` remains the authoritative atomic check.
    pub fn preauthorize_pairing(&self, code: &str) -> StoreResult<()> {
        let available = self
            .connection()?
            .query_row(
                r#"
                SELECT 1 FROM pairings p
                WHERE p.code_hash = ?1 AND p.revoked_at IS NULL AND p.expires_at > ?2
                  AND p.failed_at IS NULL AND p.failure_code IS NULL
                  AND (
                    (
                      p.used_at IS NULL
                      AND p.acknowledged_at IS NULL
                      AND p.node_id IS NULL
                      AND NOT EXISTS(
                        SELECT 1 FROM worker_credentials wc
                        WHERE wc.pairing_id = p.id
                      )
                    )
                    OR (
                      p.used_at IS NOT NULL
                      AND p.acknowledged_at IS NULL
                      AND p.node_id = p.intended_node_id
                      AND EXISTS(SELECT 1 FROM nodes n WHERE n.id = p.node_id)
                      AND EXISTS(
                        SELECT 1 FROM worker_credentials wc
                        WHERE wc.pairing_id = p.id
                          AND wc.node_id = p.node_id
                          AND wc.activated_at IS NULL
                          AND wc.revoked_at IS NULL
                      )
                      AND 1 = (
                        SELECT COUNT(*) FROM worker_credentials wc
                        WHERE wc.pairing_id = p.id
                      )
                    )
                  )
                "#,
                params![secret_hash(code), Utc::now().timestamp()],
                |_| Ok(()),
            )
            .optional()?;
        available.ok_or(StoreError::PairingUnavailable)
    }

    /// Atomically bind a pairing code to a worker-generated credential digest.
    /// A byte-identical retry is a read-only replay, including after the first
    /// transaction committed but its response was lost. The staged credential
    /// remains inactive until `acknowledge_pairing` commits the worker's local
    /// config installation.
    pub fn consume_pairing(
        &self,
        code: &str,
        pairing_id: Uuid,
        intended_node_id: Uuid,
        credential_sha256: &str,
        node: &Node,
    ) -> StoreResult<PairedWorker> {
        if !matches!(&node.transport, NodeTransport::Managed { .. }) {
            return Err(StoreError::InvalidManagedNode);
        }
        if !valid_sha256(credential_sha256) {
            return Err(StoreError::InvalidCredentialDigest);
        }
        let now = Utc::now().timestamp();
        let code_hash = secret_hash(code);
        let credential_id = Uuid::new_v4();
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let pairing = transaction
            .query_row(
                r#"
                SELECT
                    p.id, p.intended_node_id, p.node_id, p.used_at, p.acknowledged_at,
                    (
                        SELECT COUNT(*) FROM worker_credentials wc
                        WHERE wc.pairing_id = p.id
                    ),
                    EXISTS(SELECT 1 FROM nodes n WHERE n.id = p.node_id)
                FROM pairings p
                WHERE p.code_hash = ?1 AND p.revoked_at IS NULL AND p.expires_at > ?2
                  AND p.failed_at IS NULL AND p.failure_code IS NULL
                "#,
                params![code_hash, now],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, Option<String>>(2)?,
                        row.get::<_, Option<i64>>(3)?,
                        row.get::<_, Option<i64>>(4)?,
                        row.get::<_, i64>(5)?,
                        row.get::<_, i64>(6)? != 0,
                    ))
                },
            )
            .optional()?
            .ok_or(StoreError::PairingUnavailable)?;
        let stored_pairing_id = Uuid::parse_str(&pairing.0)?;
        let stored_intended_node_id = Uuid::parse_str(&pairing.1)?;
        if pairing_id != stored_pairing_id
            || intended_node_id != stored_intended_node_id
            || node.id != stored_intended_node_id
        {
            return Err(StoreError::PairingBindingMismatch);
        }

        if let Some(consumed_at) = pairing.3 {
            let stored_node_id = pairing
                .2
                .as_deref()
                .map(Uuid::parse_str)
                .transpose()?
                .ok_or(StoreError::PairingBindingMismatch)?;
            if pairing.4.is_some()
                || stored_node_id != intended_node_id
                || pairing.5 != 1
                || !pairing.6
            {
                return Err(StoreError::PairingUnavailable);
            }
            let exact = transaction
                .query_row(
                    r#"
                    SELECT 1 FROM worker_credentials
                    WHERE pairing_id = ?1 AND node_id = ?2 AND credential_hash = ?3
                      AND activated_at IS NULL AND revoked_at IS NULL
                    "#,
                    params![
                        pairing_id.to_string(),
                        intended_node_id.to_string(),
                        credential_sha256,
                    ],
                    |_| Ok(()),
                )
                .optional()?;
            if exact.is_none() {
                return Err(StoreError::PairingBindingMismatch);
            }
            transaction.commit()?;
            return Ok(PairedWorker {
                pairing_id,
                node_id: intended_node_id,
                credential_sha256: credential_sha256.to_owned(),
                consumed_at: timestamp(consumed_at)?,
                replayed: true,
            });
        }

        if pairing.4.is_some() || pairing.2.is_some() || pairing.5 != 0 {
            return Err(StoreError::PairingUnavailable);
        }

        if transaction
            .query_row(
                "SELECT 1 FROM worker_credentials WHERE credential_hash = ?1",
                [credential_sha256],
                |_| Ok(()),
            )
            .optional()?
            .is_some()
        {
            return Err(StoreError::PairingBindingMismatch);
        }

        let changed = transaction.execute(
            r#"
            UPDATE pairings SET used_at = ?1, node_id = ?2
            WHERE id = ?3 AND intended_node_id = ?2 AND code_hash = ?4
              AND used_at IS NULL AND acknowledged_at IS NULL AND node_id IS NULL
              AND revoked_at IS NULL AND expires_at > ?1
              AND failed_at IS NULL AND failure_code IS NULL
              AND NOT EXISTS(
                  SELECT 1 FROM worker_credentials wc
                  WHERE wc.pairing_id = pairings.id
              )
            "#,
            params![
                now,
                intended_node_id.to_string(),
                pairing_id.to_string(),
                code_hash,
            ],
        )?;
        if changed != 1 {
            return Err(StoreError::PairingUnavailable);
        }
        let mut node = node.clone();
        node.id = intended_node_id;
        upsert_node_tx(&transaction, &node, NodeWriteAuthority::PairingProbe)?;
        transaction.execute(
            r#"
            INSERT INTO worker_credentials(
                id, pairing_id, node_id, credential_hash, created_at, activated_at,
                last_used_at, revoked_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, NULL, NULL, NULL)
            "#,
            params![
                credential_id.to_string(),
                pairing_id.to_string(),
                intended_node_id.to_string(),
                credential_sha256,
                now,
            ],
        )?;
        transaction.commit()?;
        Ok(PairedWorker {
            pairing_id,
            node_id: intended_node_id,
            credential_sha256: credential_sha256.to_owned(),
            consumed_at: timestamp(now)?,
            replayed: false,
        })
    }

    /// Header-only preauthorization for the ACK route. Pending credentials are
    /// accepted here and nowhere else; the strict body binding is checked in
    /// `acknowledge_pairing` inside the same database transaction.
    pub fn preauthorize_pairing_ack(&self, credential: &str) -> StoreResult<()> {
        self.connection()?
            .query_row(
                r#"
                SELECT 1 FROM worker_credentials wc
                JOIN pairings p ON p.id = wc.pairing_id
                JOIN nodes n ON n.id = wc.node_id
                WHERE wc.credential_hash = ?1 AND wc.revoked_at IS NULL
                  AND p.used_at IS NOT NULL AND p.revoked_at IS NULL
                  AND p.failed_at IS NULL AND p.failure_code IS NULL
                  AND wc.node_id = p.node_id AND p.node_id = p.intended_node_id
                  AND (
                    (p.acknowledged_at IS NULL AND wc.activated_at IS NULL)
                    OR
                    (p.acknowledged_at IS NOT NULL AND wc.activated_at IS NOT NULL)
                  )
                  AND NOT EXISTS(
                    SELECT 1 FROM worker_credentials other
                    WHERE other.pairing_id = p.id AND other.id != wc.id
                  )
                "#,
                [secret_hash(credential)],
                |_| Ok(()),
            )
            .optional()?
            .ok_or(StoreError::PairingAcknowledgementUnavailable)
    }

    /// Activate the staged credential only after the worker has durably
    /// installed it. Credential rotation and old-credential revocation are one
    /// transaction, so readers observe either the old identity or the new one,
    /// never a partially switched state.
    pub fn acknowledge_pairing(
        &self,
        credential: &str,
        pairing_id: Uuid,
        node_id: Uuid,
        credential_sha256: &str,
    ) -> StoreResult<PairingAcknowledgement> {
        if !valid_sha256(credential_sha256) || secret_hash(credential) != credential_sha256 {
            return Err(StoreError::PairingAcknowledgementUnavailable);
        }
        let now = Utc::now().timestamp();
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let row = transaction
            .query_row(
                r#"
                SELECT p.acknowledged_at
                FROM worker_credentials wc
                JOIN pairings p ON p.id = wc.pairing_id
                JOIN nodes n ON n.id = wc.node_id
                WHERE wc.credential_hash = ?1 AND wc.pairing_id = ?2
                  AND wc.node_id = ?3 AND p.node_id = ?3 AND p.intended_node_id = ?3
                  AND wc.revoked_at IS NULL AND p.revoked_at IS NULL
                  AND p.used_at IS NOT NULL
                  AND p.failed_at IS NULL AND p.failure_code IS NULL
                  AND (
                    (p.acknowledged_at IS NULL AND wc.activated_at IS NULL)
                    OR
                    (p.acknowledged_at IS NOT NULL AND wc.activated_at IS NOT NULL)
                  )
                  AND NOT EXISTS(
                    SELECT 1 FROM worker_credentials other
                    WHERE other.pairing_id = p.id AND other.id != wc.id
                  )
                "#,
                params![
                    credential_sha256,
                    pairing_id.to_string(),
                    node_id.to_string(),
                ],
                |row| row.get::<_, Option<i64>>(0),
            )
            .optional()?
            .ok_or(StoreError::PairingAcknowledgementUnavailable)?;
        let acknowledged_at = if let Some(acknowledged_at) = row {
            acknowledged_at
        } else {
            transaction.execute(
                r#"
                UPDATE worker_credentials SET revoked_at = ?1
                WHERE node_id = ?2 AND pairing_id != ?3 AND revoked_at IS NULL
                  AND EXISTS(
                    SELECT 1 FROM pairings p
                    JOIN worker_credentials current ON current.pairing_id = p.id
                    JOIN nodes n ON n.id = p.node_id
                    WHERE p.id = ?3 AND current.credential_hash = ?4
                      AND current.node_id = ?2 AND current.revoked_at IS NULL
                      AND current.activated_at IS NULL
                      AND p.used_at IS NOT NULL AND p.acknowledged_at IS NULL
                      AND p.revoked_at IS NULL
                      AND p.failed_at IS NULL AND p.failure_code IS NULL
                      AND p.node_id = ?2 AND p.intended_node_id = ?2
                      AND NOT EXISTS(
                        SELECT 1 FROM worker_credentials other
                        WHERE other.pairing_id = p.id AND other.id != current.id
                      )
                  )
                "#,
                params![
                    now,
                    node_id.to_string(),
                    pairing_id.to_string(),
                    credential_sha256,
                ],
            )?;
            let activated = transaction.execute(
                r#"
                UPDATE worker_credentials SET activated_at = ?1, last_used_at = ?1
                WHERE pairing_id = ?2 AND node_id = ?3 AND credential_hash = ?4
                  AND activated_at IS NULL AND revoked_at IS NULL
                  AND EXISTS(
                    SELECT 1 FROM pairings p
                    JOIN nodes n ON n.id = p.node_id
                    WHERE p.id = worker_credentials.pairing_id
                      AND p.id = ?2 AND p.used_at IS NOT NULL
                      AND p.acknowledged_at IS NULL AND p.revoked_at IS NULL
                      AND p.failed_at IS NULL AND p.failure_code IS NULL
                      AND p.node_id = worker_credentials.node_id
                      AND p.node_id = p.intended_node_id
                  )
                  AND NOT EXISTS(
                    SELECT 1 FROM worker_credentials other
                    WHERE other.pairing_id = worker_credentials.pairing_id
                      AND other.id != worker_credentials.id
                  )
                "#,
                params![
                    now,
                    pairing_id.to_string(),
                    node_id.to_string(),
                    credential_sha256,
                ],
            )?;
            if activated != 1 {
                return Err(StoreError::PairingAcknowledgementUnavailable);
            }
            let acknowledged = transaction.execute(
                r#"
                UPDATE pairings SET acknowledged_at = ?1
                WHERE id = ?2 AND used_at IS NOT NULL
                  AND node_id = ?3 AND intended_node_id = ?3
                  AND acknowledged_at IS NULL
                  AND revoked_at IS NULL AND failed_at IS NULL AND failure_code IS NULL
                  AND EXISTS(SELECT 1 FROM nodes n WHERE n.id = pairings.node_id)
                  AND EXISTS(
                    SELECT 1 FROM worker_credentials wc
                    WHERE wc.pairing_id = pairings.id
                      AND wc.node_id = pairings.node_id
                      AND wc.credential_hash = ?4
                      AND wc.activated_at IS NOT NULL
                      AND wc.revoked_at IS NULL
                  )
                  AND 1 = (
                    SELECT COUNT(*) FROM worker_credentials wc
                    WHERE wc.pairing_id = pairings.id
                  )
                "#,
                params![
                    now,
                    pairing_id.to_string(),
                    node_id.to_string(),
                    credential_sha256,
                ],
            )?;
            if acknowledged != 1 {
                return Err(StoreError::PairingAcknowledgementUnavailable);
            }
            // The newly activated credential is the sole current identity for
            // this stable node. Mark every older enrollment terminal as well
            // as revoking its credential, so status and authentication expose
            // one coherent lifecycle rather than an unrevoked Ready pairing
            // backed by a revoked credential.
            transaction.execute(
                r#"
                UPDATE pairings SET revoked_at = ?1
                WHERE intended_node_id = ?2 AND id != ?3
                  AND revoked_at IS NULL
                "#,
                params![now, node_id.to_string(), pairing_id.to_string()],
            )?;
            now
        };
        transaction.commit()?;
        Ok(PairingAcknowledgement {
            pairing_id,
            node_id,
            credential_sha256: credential_sha256.to_owned(),
            acknowledged_at: timestamp(acknowledged_at)?,
        })
    }

    pub fn revoke_pairing(&self, pairing_id: Uuid) -> StoreResult<()> {
        let now = Utc::now().timestamp();
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let changed = transaction.execute(
            "UPDATE pairings SET revoked_at = COALESCE(revoked_at, ?1) WHERE id = ?2",
            params![now, pairing_id.to_string()],
        )?;
        if changed == 0 {
            return Err(StoreError::NotFound);
        }
        transaction.execute(
            "UPDATE worker_credentials SET revoked_at = COALESCE(revoked_at, ?1) WHERE pairing_id = ?2",
            params![now, pairing_id.to_string()],
        )?;
        transaction.commit()?;
        Ok(())
    }

    pub fn authenticate_worker(&self, credential: &str) -> StoreResult<Uuid> {
        let now = Utc::now().timestamp();
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let node_id = authenticate_worker_tx(&transaction, credential, now)?;
        transaction.commit()?;
        Ok(node_id)
    }

    /// Persist one authenticated, sequenced worker report. Node identity comes
    /// only from the credential lookup. A replay or out-of-order report is a
    /// successful no-op and cannot refresh either document or controller
    /// receive time.
    pub fn record_node_report(
        &self,
        credential: &str,
        report: &NodeReportRequest,
    ) -> StoreResult<NodeReportOutcome> {
        report
            .validate()
            .map_err(|_| StoreError::InvalidNodeReport)?;
        let now = Utc::now();
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        expire_leases(&transaction, now.timestamp())?;
        let node_id = authenticate_worker_tx(&transaction, credential, now.timestamp())?;

        let existing = transaction
            .query_row(
                r#"
                SELECT i.document, i.revision, i.digest, i.observed_at,
                       t.boot_generation, t.boot_id, t.sequence, t.received_at,
                       c.document, n.revision
                FROM node_inventories i
                JOIN node_telemetry t ON t.node_id = i.node_id
                JOIN node_configs c ON c.node_id = i.node_id
                JOIN nodes n ON n.id = i.node_id
                WHERE i.node_id = ?1
                "#,
                [node_id.to_string()],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, String>(3)?,
                        row.get::<_, i64>(4)?,
                        row.get::<_, String>(5)?,
                        row.get::<_, i64>(6)?,
                        row.get::<_, String>(7)?,
                        row.get::<_, String>(8)?,
                        row.get::<_, i64>(9)?,
                    ))
                },
            )
            .optional()?
            .ok_or(StoreError::NotFound)?;
        let previous_generation = as_u64(existing.4);
        let previous_boot = Uuid::parse_str(&existing.5)?;
        let previous_sequence = as_u64(existing.6);
        let legacy_retired_boot_replay = previous_generation == 0
            && report.telemetry.boot_generation == 0
            && previous_boot != report.telemetry.boot_id
            && transaction
                .query_row(
                    r#"
                    SELECT 1 FROM node_telemetry_boots
                    WHERE node_id = ?1 AND boot_id = ?2
                    "#,
                    params![node_id.to_string(), report.telemetry.boot_id.to_string()],
                    |_row| Ok(()),
                )
                .optional()?
                .is_some();
        let generation_order_reject =
            if previous_generation == 0 && report.telemetry.boot_generation == 0 {
                (previous_boot == report.telemetry.boot_id
                    && report.telemetry.sequence <= previous_sequence)
                    || legacy_retired_boot_replay
            } else {
                report.telemetry.boot_generation < previous_generation
                    || (report.telemetry.boot_generation == previous_generation
                        && (report.telemetry.boot_id != previous_boot
                            || report.telemetry.sequence <= previous_sequence))
            };
        if generation_order_reject {
            let received_at = DateTime::parse_from_rfc3339(&existing.7)
                .map_err(|_| StoreError::Timestamp)?
                .with_timezone(&Utc);
            transaction.commit()?;
            return Ok(NodeReportOutcome {
                node_id,
                accepted: false,
                inventory_revision: existing.1,
                inventory_digest: existing.2,
                telemetry_boot_generation: previous_generation,
                telemetry_boot_id: previous_boot,
                telemetry_sequence: previous_sequence,
                received_at,
            });
        }

        let previous_inventory: NodeInventory = serde_json::from_str(&existing.0)?;
        let inventory = report
            .inventory
            .as_ref()
            .unwrap_or(&previous_inventory)
            .clone();
        inventory.validate()?;
        if !matches!(&inventory.transport, NodeTransport::Managed { .. }) {
            return Err(StoreError::InvalidManagedNode);
        }
        report.telemetry.validate(&inventory)?;
        let inventory_document = serde_json::to_string(&inventory)?;
        let inventory_supplied = report.inventory.is_some();
        let inventory_changed = inventory_supplied && inventory_document != existing.0;
        let inventory_revision = if inventory_changed {
            existing.1.saturating_add(1)
        } else {
            existing.1
        };
        let inventory_digest = if inventory_supplied {
            format!("sha256:{}", bytes_sha256(inventory_document.as_bytes()))
        } else {
            existing.2.clone()
        };
        let config: NodeConfig = serde_json::from_str(&existing.8)?;
        let view = NodeMergeView::merge(
            node_id,
            config,
            inventory.clone(),
            report.telemetry.clone(),
            now,
            now,
            Duration::from_secs(u64::try_from(NODE_FRESHNESS_SECONDS).unwrap_or_default()),
        )?;
        if inventory_supplied {
            transaction.execute(
                r#"
                UPDATE node_inventories SET
                    document = ?1, updated_at = ?2, revision = ?3,
                    digest = ?4, observed_at = ?5
                WHERE node_id = ?6
                "#,
                params![
                    inventory_document,
                    now.to_rfc3339(),
                    inventory_revision,
                    inventory_digest,
                    report.telemetry.observed_at.to_rfc3339(),
                    node_id.to_string(),
                ],
            )?;
        }
        transaction.execute(
            r#"
            UPDATE node_telemetry SET
                document = ?1, received_at = ?2, boot_generation = ?3,
                boot_id = ?4, sequence = ?5, observed_at = ?6
            WHERE node_id = ?7
            "#,
            params![
                serde_json::to_string(&report.telemetry)?,
                now.to_rfc3339(),
                as_i64(report.telemetry.boot_generation),
                report.telemetry.boot_id.to_string(),
                as_i64(report.telemetry.sequence),
                report.telemetry.observed_at.to_rfc3339(),
                node_id.to_string(),
            ],
        )?;
        transaction.execute(
            r#"
            INSERT OR IGNORE INTO node_telemetry_boots(node_id, boot_id, first_received_at)
            VALUES (?1, ?2, ?3)
            "#,
            params![
                node_id.to_string(),
                report.telemetry.boot_id.to_string(),
                now.to_rfc3339(),
            ],
        )?;
        transaction.execute(
            r#"
            UPDATE nodes SET document = ?1, updated_at = ?2, revision = ?3
            WHERE id = ?4
            "#,
            params![
                serde_json::to_string(&view.to_node()?)?,
                now.to_rfc3339(),
                if inventory_changed {
                    existing.9.saturating_add(1)
                } else {
                    existing.9
                },
                node_id.to_string(),
            ],
        )?;
        if inventory_changed {
            increment_meta(&transaction, "fleet_revision")?;
        }
        redispatch_queued_jobs(&transaction, now.timestamp(), &Scheduler::default())?;
        transaction.commit()?;
        Ok(NodeReportOutcome {
            node_id,
            accepted: true,
            inventory_revision,
            inventory_digest,
            telemetry_boot_generation: report.telemetry.boot_generation,
            telemetry_boot_id: report.telemetry.boot_id,
            telemetry_sequence: report.telemetry.sequence,
            received_at: now,
        })
    }

    /// Authenticate the worker and bind a run credential to the URL's run id
    /// before an axum body extractor is allowed to poll the body. Completion
    /// retries may use the original, now-revoked claim credential only after a
    /// durable receipt exists; every other run route requires a live claim.
    pub fn preauthorize_run_route(
        &self,
        worker_credential: &str,
        run_credential: &str,
        run_id: Uuid,
        allow_revoked_completion: bool,
    ) -> StoreResult<()> {
        let now = Utc::now().timestamp();
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let node_id = authenticate_worker_tx(&transaction, worker_credential, now)?;
        let claim_node = if allow_revoked_completion {
            transaction
                .query_row(
                    r#"
                    SELECT c.node_id FROM worker_claims c
                    WHERE c.run_id = ?1 AND c.credential_hash = ?2
                      AND (
                        (c.revoked_at IS NULL AND c.expires_at > ?3)
                        OR EXISTS(
                          SELECT 1 FROM run_completions r WHERE r.run_id = c.run_id
                        )
                      )
                    "#,
                    params![run_id.to_string(), secret_hash(run_credential), now],
                    |row| row.get::<_, String>(0),
                )
                .optional()?
        } else {
            transaction
                .query_row(
                    r#"
                    SELECT node_id FROM worker_claims
                    WHERE run_id = ?1 AND credential_hash = ?2
                      AND revoked_at IS NULL AND expires_at > ?3
                    "#,
                    params![run_id.to_string(), secret_hash(run_credential), now,],
                    |row| row.get::<_, String>(0),
                )
                .optional()?
        }
        .ok_or(StoreError::RunUnauthorized)?;
        if Uuid::parse_str(&claim_node)? != node_id {
            return Err(StoreError::RunUnauthorized);
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn create_plan(&self, job: &JobSpec, scheduler: &Scheduler) -> StoreResult<StoredPlan> {
        job.validate().map_err(ScheduleError::from)?;
        let normalized_job = normalize_job_spec(job);
        let digest = canonical_job_digest(&normalized_job)?;
        // The plans table stores second-resolution timestamps. Build the
        // public binding at that same resolution so the document returned by
        // POST /v1/plans is exactly the document later persisted on the job.
        let now = timestamp(Utc::now().timestamp())?;
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        expire_leases(&transaction, now.timestamp())?;
        let nodes_with_revisions = fresh_available_nodes(&transaction, now)?;
        let nodes = nodes_with_revisions
            .iter()
            .map(|record| record.scheduling.clone())
            .collect::<Vec<_>>();
        let decision = scheduler.schedule_contexts(&normalized_job, &nodes)?;
        let node_revision = nodes_with_revisions
            .iter()
            .find(|record| record.scheduling.node.id == decision.node_id)
            .map(|record| record.revision)
            .ok_or(StoreError::PlanStale)?;
        let fleet_revision = get_meta(&transaction, "fleet_revision")?;
        let policy_revision = get_meta(&transaction, "policy_revision")?;
        let binding = new_plan_binding(
            &normalized_job,
            digest,
            decision,
            now,
            fleet_revision,
            node_revision,
            policy_revision,
        )?;
        insert_plan_tx(&transaction, &binding, None)?;
        transaction.commit()?;
        Ok(StoredPlan {
            binding,
            used_at: None,
        })
    }

    pub fn get_plan(&self, plan_id: Uuid) -> StoreResult<StoredPlan> {
        let connection = self.connection()?;
        get_plan(&connection, plan_id)
    }

    pub fn submit_job(
        &self,
        job: &JobSpec,
        plan_id: Option<Uuid>,
        scheduler: &Scheduler,
    ) -> StoreResult<StoredJob> {
        job.validate().map_err(ScheduleError::from)?;
        let normalized_job = normalize_job_spec(job);
        let digest = canonical_job_digest(&normalized_job)?;
        let now = timestamp(Utc::now().timestamp())?;
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;

        if transaction
            .query_row(
                "SELECT 1 FROM jobs WHERE job_id = ?1 OR run_id = ?1",
                [job.id.to_string()],
                |_row| Ok(()),
            )
            .optional()?
            .is_some()
        {
            return Err(StoreError::Conflict);
        }

        expire_leases(&transaction, now.timestamp())?;
        let nodes_with_revisions = fresh_available_nodes(&transaction, now)?;
        let nodes = nodes_with_revisions
            .iter()
            .map(|record| record.scheduling.clone())
            .collect::<Vec<_>>();
        let current_fleet_revision = get_meta(&transaction, "fleet_revision")?;
        let current_policy_revision = get_meta(&transaction, "policy_revision")?;

        let (decision, plan_binding, created_internal_plan) = if let Some(plan_id) = plan_id {
            let plan = get_plan(&transaction, plan_id)?;
            if plan.binding.job_id != normalized_job.id || plan.binding.job_digest != digest {
                return Err(StoreError::PlanDigestMismatch);
            }
            if plan.used_at.is_some() {
                return Err(StoreError::PlanStale);
            }
            if plan.binding.expires_at <= now {
                return Err(StoreError::PlanExpired);
            }
            plan.binding
                .validate(Some(&normalized_job), Some(now))
                .map_err(|_| StoreError::InvalidPlanBinding)?;
            if plan.binding.fleet_revision != current_fleet_revision
                || plan.binding.policy_revision != current_policy_revision
            {
                return Err(StoreError::PlanStale);
            }
            let current_node_revision = nodes_with_revisions
                .iter()
                .find(|record| record.scheduling.node.id == plan.binding.decision.node_id)
                .map(|record| record.revision)
                .ok_or(StoreError::PlanStale)?;
            if current_node_revision != plan.binding.node_revision {
                return Err(StoreError::PlanStale);
            }
            let refreshed = scheduler.schedule_contexts(&normalized_job, &nodes)?;
            if refreshed.node_id != plan.binding.decision.node_id {
                return Err(StoreError::PlanStale);
            }
            (refreshed, plan.binding, false)
        } else {
            let decision = scheduler.schedule_contexts(&normalized_job, &nodes)?;
            let node_revision = nodes_with_revisions
                .iter()
                .find(|record| record.scheduling.node.id == decision.node_id)
                .map(|record| record.revision)
                .ok_or(StoreError::PlanStale)?;
            let binding = new_plan_binding(
                &normalized_job,
                digest,
                decision.clone(),
                now,
                current_fleet_revision,
                node_revision,
                current_policy_revision,
            )?;
            // A submit without an external planning round still receives a
            // controller-authored, already-used plan in this same transaction.
            insert_plan_tx(&transaction, &binding, Some(now))?;
            (decision, binding, true)
        };

        let mut run = unique_queued_run(&transaction, job.id)?;
        run.node_id = Some(decision.node_id);
        run.placement = Some(decision.explanation);
        let lease_id = Uuid::new_v4();
        let resources = normalized_job.effective_resource_request();
        let gpu_request = effective_gpu_request(&normalized_job);
        let gpu_reservation = select_gpu_reservation(
            &nodes_with_revisions,
            decision.node_id,
            gpu_request.as_ref(),
        )?;
        let gpu_reserved = i64::from(gpu_request.is_some());
        transaction.execute(
            r#"
            INSERT INTO leases(
                id, run_id, job_id, node_id, cpu_cores, memory_mib, disk_mib,
                gpu_reserved, slots, phase, created_at, expires_at, released_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, NULL)
            "#,
            params![
                lease_id.to_string(),
                run.id.to_string(),
                job.id.to_string(),
                decision.node_id.to_string(),
                i64::from(resources.cpu_cores),
                as_i64(resources.memory_mib),
                as_i64(resources.disk_mib),
                gpu_reserved,
                i64::from(resources.slots),
                LEASE_PHASE_DISPATCH,
                now.timestamp(),
                now.timestamp().saturating_add(DISPATCH_TTL_SECONDS),
            ],
        )?;
        if let Some((device_id, request)) = gpu_reservation {
            transaction.execute(
                r#"
                INSERT INTO lease_gpu_reservations(lease_id, device_id, vram_mib, exclusive)
                VALUES (?1, ?2, ?3, ?4)
                "#,
                params![
                    lease_id.to_string(),
                    device_id,
                    as_i64(request.vram_mib),
                    i64::from(request.exclusive),
                ],
            )?;
        }

        let now_text = now.to_rfc3339();
        transaction.execute(
            r#"
            INSERT INTO jobs(
                run_id, job_id, job, run, created_at, updated_at,
                version, cancel_requested, lease_id, plan_binding
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?5, 0, 0, ?6, ?7)
            "#,
            params![
                run.id.to_string(),
                job.id.to_string(),
                serde_json::to_string(&normalized_job)?,
                serde_json::to_string(&run)?,
                now_text,
                lease_id.to_string(),
                serde_json::to_string(&plan_binding)?,
            ],
        )?;
        insert_placement_attempt_tx(
            &transaction,
            run.id,
            &plan_binding,
            PLACEMENT_ATTEMPT_INITIAL,
        )?;

        if !created_internal_plan {
            let plan_id = plan_id.ok_or(StoreError::InvalidPlanBinding)?;
            let changed = transaction.execute(
                "UPDATE plans SET used_at = ?1 WHERE id = ?2 AND used_at IS NULL",
                params![now.timestamp(), plan_id.to_string()],
            )?;
            if changed != 1 {
                return Err(StoreError::PlanStale);
            }
        }
        // The active reservation is part of the authoritative fleet state and
        // must invalidate stale placement plans/snapshots.
        increment_meta(&transaction, "fleet_revision")?;
        transaction.commit()?;
        Ok(StoredJob {
            job: normalized_job,
            run,
            plan_binding: Some(plan_binding),
            version: 0,
            cancel_requested: false,
            lease_id: Some(lease_id),
        })
    }

    /// Claim the oldest queued run already placed on the authenticated node.
    /// The credential lookup, Queued -> Preparing CAS, run-secret creation,
    /// and lease deadline update share one IMMEDIATE transaction.
    pub fn claim_job(
        &self,
        worker_credential: &str,
        observed_node: &Node,
    ) -> StoreResult<Option<WorkerClaim>> {
        let now = Utc::now();
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        expire_leases(&transaction, now.timestamp())?;
        let node_id = authenticate_worker_tx(&transaction, worker_credential, now.timestamp())?;
        if node_id != observed_node.id {
            return Err(StoreError::WorkerUnauthorized);
        }
        // Legacy claim probes remain a compatibility liveness path only until
        // a sequenced NodeReport has been observed. They must never overwrite
        // a modern report or defeat its monotonic boot/sequence contract.
        upsert_legacy_probe_tx(&transaction, observed_node)?;

        let rows = {
            let mut statement = transaction.prepare(
                r#"
                SELECT j.job, j.run, j.version, j.cancel_requested, j.lease_id,
                       j.plan_binding
                FROM jobs j
                JOIN leases l ON l.run_id = j.run_id
                WHERE l.node_id = ?1 AND l.released_at IS NULL AND l.expires_at > ?2
                ORDER BY j.created_at, j.run_id
                "#,
            )?;
            let rows = statement
                .query_map(params![node_id.to_string(), now.timestamp()], job_row)?
                .collect::<Result<Vec<_>, _>>()?;
            rows
        };
        let Some(mut stored) = rows
            .into_iter()
            .map(decode_job_row)
            .collect::<StoreResult<Vec<_>>>()?
            .into_iter()
            .find(|stored| stored.run.state == JobState::Queued)
        else {
            transaction.commit()?;
            return Ok(None);
        };
        if stored.cancel_requested {
            return Err(StoreError::CancellationPending);
        }
        if stored
            .plan_binding
            .as_ref()
            .is_some_and(|binding| binding.decision.node_id != node_id)
        {
            return Err(StoreError::InvalidPlanBinding);
        }
        let lease_id = stored.lease_id.ok_or(StoreError::InvalidTransition)?;
        stored
            .run
            .transition(JobState::Preparing)
            .map_err(|_| StoreError::InvalidTransition)?;
        update_job_cas(&transaction, &mut stored)?;

        let run_credential = random_secret();
        let expires_at = now + chrono::Duration::seconds(CLAIM_TTL_SECONDS);
        transaction.execute(
            r#"
            INSERT INTO worker_claims(
                run_id, node_id, lease_id, credential_hash, created_at, expires_at, revoked_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, NULL)
            "#,
            params![
                stored.run.id.to_string(),
                node_id.to_string(),
                lease_id.to_string(),
                secret_hash(&run_credential),
                now.timestamp(),
                expires_at.timestamp(),
            ],
        )?;
        let changed = transaction.execute(
            r#"
            UPDATE leases SET expires_at = ?1, phase = ?4
            WHERE id = ?2 AND run_id = ?3 AND released_at IS NULL
              AND phase IN ('dispatch', 'legacy')
            "#,
            params![
                expires_at.timestamp(),
                lease_id.to_string(),
                stored.run.id.to_string(),
                LEASE_PHASE_EXECUTION,
            ],
        )?;
        if changed != 1 {
            return Err(StoreError::InvalidTransition);
        }
        let job_digest = canonical_job_digest(&stored.job)?;
        transaction.commit()?;
        Ok(Some(WorkerClaim {
            stored,
            job_digest,
            lease_id,
            lease_until: expires_at,
            run_credential,
        }))
    }

    pub fn worker_heartbeat(
        &self,
        worker_credential: &str,
        run_credential: &str,
        run_id: Uuid,
        lease_id: Uuid,
        expected_version: u64,
        expected_state: JobState,
    ) -> StoreResult<WorkerHeartbeat> {
        let now = Utc::now();
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        expire_leases(&transaction, now.timestamp())?;
        authorize_run_tx(
            &transaction,
            worker_credential,
            run_credential,
            run_id,
            lease_id,
            now.timestamp(),
        )?;
        let stored = get_job_by_run_id(&transaction, run_id)?;
        if stored.version != expected_version
            && !(stored.cancel_requested && expected_version < stored.version)
        {
            return Err(worker_state_conflict(&stored));
        }
        if stored.run.state != expected_state {
            return Err(worker_state_conflict(&stored));
        }
        if stored.run.state.is_terminal() {
            return Err(worker_state_conflict(&stored));
        }
        let expires_at = now + chrono::Duration::seconds(CLAIM_TTL_SECONDS);
        let claim_changed = transaction.execute(
            r#"
            UPDATE worker_claims SET expires_at = ?1
            WHERE run_id = ?2 AND lease_id = ?3 AND revoked_at IS NULL AND expires_at > ?4
            "#,
            params![
                expires_at.timestamp(),
                run_id.to_string(),
                lease_id.to_string(),
                now.timestamp(),
            ],
        )?;
        let lease_changed = transaction.execute(
            r#"
            UPDATE leases SET expires_at = ?1
            WHERE id = ?2 AND run_id = ?3 AND released_at IS NULL AND expires_at > ?4
              AND phase IN ('execution', 'legacy')
            "#,
            params![
                expires_at.timestamp(),
                lease_id.to_string(),
                run_id.to_string(),
                now.timestamp(),
            ],
        )?;
        if claim_changed != 1 || lease_changed != 1 {
            return Err(StoreError::RunUnauthorized);
        }
        // Run heartbeats renew only execution ownership. Node telemetry
        // freshness is refreshed exclusively by monotonic NodeReport writes;
        // an old run heartbeat with probe=None can never resurrect a node.
        transaction.commit()?;
        Ok(WorkerHeartbeat {
            stored,
            lease_id,
            lease_until: expires_at,
        })
    }

    pub fn worker_transition(
        &self,
        worker_credential: &str,
        run_credential: &str,
        run_id: Uuid,
        lease_id: Uuid,
        expected_version: u64,
        next: JobState,
    ) -> StoreResult<StoredJob> {
        if next.is_terminal() || next == JobState::Queued {
            return Err(StoreError::InvalidTransition);
        }
        self.worker_transition_inner(
            worker_credential,
            run_credential,
            run_id,
            lease_id,
            expected_version,
            next,
            RunEvidence::default(),
        )
    }

    /// Test-only legacy transition helper. Production managed completions must
    /// enter through `worker_complete_managed`, which verifies the full
    /// execution receipt before committing terminal state.
    #[cfg(test)]
    #[allow(clippy::too_many_arguments)]
    fn worker_complete(
        &self,
        worker_credential: &str,
        run_credential: &str,
        run_id: Uuid,
        lease_id: Uuid,
        expected_version: u64,
        next: JobState,
        evidence: RunEvidence,
    ) -> StoreResult<StoredJob> {
        if !next.is_terminal() {
            return Err(StoreError::InvalidTransition);
        }
        self.worker_transition_inner(
            worker_credential,
            run_credential,
            run_id,
            lease_id,
            expected_version,
            next,
            evidence,
        )
    }

    /// Validate the managed worker's complete execution receipt and commit it
    /// together with the terminal run transition. A byte-for-byte equivalent
    /// retry (represented by the same serialized receipt digest) is
    /// idempotent after the claim is revoked and while the cleanup reservation
    /// remains held (or after it is released by authoritative cleanup/reaper).
    pub fn worker_complete_managed(
        &self,
        worker_credential: &str,
        run_credential: &str,
        completion: &RunCompletion,
    ) -> StoreResult<StoredJob> {
        completion
            .validate()
            .map_err(|_| StoreError::InvalidRunEvidence)?;
        let document = serde_json::to_string(completion)?;
        let document_sha256 = bytes_sha256(document.as_bytes());
        let now = Utc::now();
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        expire_leases(&transaction, now.timestamp())?;

        let node_id = authorize_completion_receipt_tx(
            &transaction,
            worker_credential,
            run_credential,
            completion.run_id,
            completion.lease_id,
            now.timestamp(),
        )?;
        let mut stored = get_job_by_run_id(&transaction, completion.run_id)?;
        if stored.run.node_id != Some(node_id) {
            return Err(StoreError::RunUnauthorized);
        }

        if stored.run.state.is_terminal() {
            let existing = transaction
                .query_row(
                    "SELECT document_sha256 FROM run_completions WHERE run_id = ?1",
                    [completion.run_id.to_string()],
                    |row| row.get::<_, String>(0),
                )
                .optional()?;
            if existing.as_deref() == Some(document_sha256.as_str()) {
                transaction.commit()?;
                return Ok(stored);
            }
            return Err(worker_state_conflict(&stored));
        }

        // Idempotent receipt authentication above intentionally accepts the
        // revoked claim. A first terminal commit still requires an active
        // claim and resource lease.
        authorize_run_tx(
            &transaction,
            worker_credential,
            run_credential,
            completion.run_id,
            completion.lease_id,
            now.timestamp(),
        )?;
        if stored.version != completion.expected_version {
            return Err(worker_state_conflict(&stored));
        }
        if stored.cancel_requested
            && !matches!(
                completion.final_state,
                JobState::Cancelled | JobState::Failed
            )
        {
            return Err(worker_state_conflict(&stored));
        }

        validate_managed_completion(
            &transaction,
            self.object_root.as_path(),
            &stored,
            completion,
        )?;
        if stored.run.transition(completion.final_state).is_err() {
            return Err(worker_state_conflict(&stored));
        }
        completion.evidence.apply_to_run(&mut stored.run);
        stored
            .run
            .validate()
            .map_err(|_| StoreError::InvalidRunEvidence)?;
        update_job_cas(&transaction, &mut stored)?;
        transaction.execute(
            r#"
            INSERT INTO run_completions(run_id, document, document_sha256, created_at)
            VALUES (?1, ?2, ?3, ?4)
            "#,
            params![
                completion.run_id.to_string(),
                document,
                document_sha256,
                now.timestamp(),
            ],
        )?;
        transaction.execute(
            "UPDATE worker_claims SET revoked_at = ?1 WHERE run_id = ?2 AND revoked_at IS NULL",
            params![now.timestamp(), completion.run_id.to_string()],
        )?;
        let cleanup_deadline = now
            .timestamp()
            .saturating_add(CLEANUP_RESERVATION_TTL_SECONDS);
        transaction.execute(
            r#"
            INSERT INTO run_cleanup_obligations(
                run_id, job_id, lease_id, state_version, final_state,
                completion_sha256, terminal_acknowledged_at, cleanup_deadline_at,
                reservation_released_at, release_reason, cleanup_failure_code,
                failure_observed_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, NULL, NULL, NULL, NULL)
            "#,
            params![
                completion.run_id.to_string(),
                stored.job.id.to_string(),
                completion.lease_id.to_string(),
                as_i64(stored.version),
                job_state_token(stored.run.state)?,
                document_sha256,
                now.timestamp(),
                cleanup_deadline,
            ],
        )?;
        let changed = transaction.execute(
            r#"
            UPDATE leases SET phase = ?1, expires_at = ?2
            WHERE id = ?3 AND run_id = ?4 AND job_id = ?5
              AND released_at IS NULL AND phase = ?6
            "#,
            params![
                LEASE_PHASE_CLEANUP_PENDING,
                cleanup_deadline,
                completion.lease_id.to_string(),
                completion.run_id.to_string(),
                stored.job.id.to_string(),
                LEASE_PHASE_EXECUTION,
            ],
        )?;
        if changed != 1 {
            return Err(StoreError::InvalidTransition);
        }
        transaction.commit()?;
        Ok(stored)
    }

    pub fn get_completion(&self, run_id: Uuid) -> StoreResult<StoredCompletion> {
        let connection = self.connection()?;
        get_completion_tx(&connection, run_id)?.ok_or(StoreError::NotFound)
    }

    /// Persist immutable evidence that the worker removed (or never created)
    /// the exact job-owned root after receiving the terminal completion ACK.
    pub fn record_cleanup(
        &self,
        worker_credential: &str,
        run_credential: &str,
        receipt: &CleanupReceiptV1,
    ) -> StoreResult<StoredCleanup> {
        receipt
            .validate()
            .map_err(|_| StoreError::InvalidCleanupReceipt)?;
        let document = serde_json::to_string(receipt)?;
        let document_sha256 = bytes_sha256(document.as_bytes());
        let received_at = timestamp(Utc::now().timestamp())?;
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        expire_leases(&transaction, received_at.timestamp())?;
        let node_id = authorize_completion_receipt_tx(
            &transaction,
            worker_credential,
            run_credential,
            receipt.run_id,
            receipt.lease_id,
            received_at.timestamp(),
        )?;
        let stored = get_job_by_run_id(&transaction, receipt.run_id)?;
        if stored.run.node_id != Some(node_id)
            || stored.run.state != receipt.terminal_ack.final_state
            || stored.version != receipt.terminal_ack.state_version
        {
            return Err(StoreError::InvalidCleanupReceipt);
        }
        let obligation = get_cleanup_obligation_tx(&transaction, receipt.run_id)?
            .ok_or(StoreError::InvalidCleanupReceipt)?;
        if obligation.job_id != stored.job.id
            || obligation.run_id != receipt.run_id
            || obligation.lease_id != receipt.lease_id
            || obligation.state_version != receipt.terminal_ack.state_version
            || obligation.final_state != receipt.terminal_ack.final_state
            || obligation.completion_sha256 != receipt.terminal_ack.completion_sha256
            || obligation.terminal_acknowledged_at != receipt.terminal_ack.acknowledged_at
        {
            return Err(StoreError::InvalidCleanupReceipt);
        }
        let completion = transaction
            .query_row(
                r#"
                SELECT document_sha256, created_at FROM run_completions
                WHERE run_id = ?1
                "#,
                [receipt.run_id.to_string()],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
            )
            .optional()?
            .ok_or(StoreError::InvalidCleanupReceipt)?;
        if completion.0 != receipt.terminal_ack.completion_sha256
            || timestamp(completion.1)? != receipt.terminal_ack.acknowledged_at
        {
            return Err(StoreError::InvalidCleanupReceipt);
        }

        if let Some((existing_document, existing_digest, existing_received_at)) = transaction
            .query_row(
                r#"
                SELECT document, document_sha256, received_at FROM run_cleanups
                WHERE run_id = ?1
                "#,
                [receipt.run_id.to_string()],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, i64>(2)?,
                    ))
                },
            )
            .optional()?
        {
            if existing_digest != document_sha256 || existing_document != document {
                return Err(StoreError::CleanupConflict);
            }
            if receipt.outcome == cyc_protocol::JobRootCleanupOutcomeV1::Removed {
                release_cleanup_reservation_tx(
                    &transaction,
                    receipt.run_id,
                    receipt.lease_id,
                    received_at.timestamp(),
                )?;
            }
            transaction.commit()?;
            return Ok(StoredCleanup {
                receipt: serde_json::from_str(&existing_document)?,
                received_at: timestamp(existing_received_at)?,
            });
        }

        transaction.execute(
            r#"
            INSERT INTO run_cleanups(run_id, document, document_sha256, received_at)
            VALUES (?1, ?2, ?3, ?4)
            "#,
            params![
                receipt.run_id.to_string(),
                document,
                document_sha256,
                received_at.timestamp(),
            ],
        )?;
        if receipt.outcome == cyc_protocol::JobRootCleanupOutcomeV1::Removed {
            release_cleanup_reservation_tx(
                &transaction,
                receipt.run_id,
                receipt.lease_id,
                received_at.timestamp(),
            )?;
        }
        transaction.commit()?;
        Ok(StoredCleanup {
            receipt: receipt.clone(),
            received_at,
        })
    }

    pub fn get_cleanup(&self, run_id: Uuid) -> StoreResult<Option<StoredCleanup>> {
        let connection = self.connection()?;
        get_cleanup_tx(&connection, run_id)
    }

    /// Coherent cleanup status read. Deadline recovery runs first and commits;
    /// the returned job/completion/receipt/obligation then come from one
    /// transaction so API clients cannot observe a torn terminal ACK.
    pub fn get_cleanup_snapshot(&self, id: Uuid) -> StoreResult<CleanupSnapshot> {
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        expire_leases(&transaction, Utc::now().timestamp())?;
        let stored = get_job_prefer_job_id(&transaction, id)?;
        let cleanup = get_cleanup_tx(&transaction, stored.run.id)?;
        let completion = get_completion_tx(&transaction, stored.run.id)?;
        let obligation = get_cleanup_obligation_tx(&transaction, stored.run.id)?;
        transaction.commit()?;
        Ok(CleanupSnapshot {
            stored,
            cleanup,
            completion,
            obligation,
        })
    }

    #[allow(clippy::too_many_arguments)]
    fn worker_transition_inner(
        &self,
        worker_credential: &str,
        run_credential: &str,
        run_id: Uuid,
        lease_id: Uuid,
        expected_version: u64,
        next: JobState,
        evidence: RunEvidence,
    ) -> StoreResult<StoredJob> {
        let now = Utc::now();
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        expire_leases(&transaction, now.timestamp())?;
        authorize_run_tx(
            &transaction,
            worker_credential,
            run_credential,
            run_id,
            lease_id,
            now.timestamp(),
        )?;
        let mut stored = get_job_by_run_id(&transaction, run_id)?;
        if stored.version != expected_version {
            return Err(worker_state_conflict(&stored));
        }
        if stored.cancel_requested && !matches!(next, JobState::Cancelled | JobState::Failed) {
            return Err(worker_state_conflict(&stored));
        }
        if !next.is_terminal()
            && (evidence.exit_code.is_some()
                || evidence.error.is_some()
                || evidence.artifact_ids.is_some())
        {
            return Err(StoreError::InvalidRunEvidence);
        }
        if let Some(ids) = evidence.artifact_ids.as_ref() {
            ensure_artifacts_belong_to_run(&transaction, run_id, ids)?;
        }
        if stored.run.transition(next).is_err() {
            return Err(worker_state_conflict(&stored));
        }
        apply_run_evidence(&mut stored.run, evidence);
        stored
            .run
            .validate()
            .map_err(|_| StoreError::InvalidRunEvidence)?;
        update_job_cas(&transaction, &mut stored)?;
        if stored.run.state.is_terminal() {
            transaction.execute(
                "UPDATE worker_claims SET revoked_at = ?1 WHERE run_id = ?2 AND revoked_at IS NULL",
                params![now.timestamp(), run_id.to_string()],
            )?;
            release_lease(&transaction, Some(lease_id), now.timestamp())?;
        }
        transaction.commit()?;
        Ok(stored)
    }

    /// Store one immutable content-addressed snapshot outside SQLite. The
    /// digest is over `data` exactly as received, including the zstd frame.
    pub fn put_snapshot(
        &self,
        digest: &str,
        declared_size: u64,
        data: &[u8],
    ) -> StoreResult<SnapshotMetadataV1> {
        let candidate = SnapshotMetadataV1::new(digest.to_owned(), declared_size, Utc::now());
        candidate
            .validate()
            .map_err(|_| StoreError::InvalidUpload)?;
        let actual_size = u64::try_from(data.len()).unwrap_or(u64::MAX);
        if actual_size > MAX_SNAPSHOT_ARCHIVE_BYTES {
            return Err(StoreError::SnapshotQuotaExceeded);
        }
        if actual_size != declared_size {
            return Err(StoreError::InvalidUpload);
        }
        let actual_digest = format!("sha256:{}", bytes_sha256(data));
        if actual_digest != digest {
            return Err(StoreError::DigestMismatch);
        }

        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        if let Some(existing) = get_snapshot(&transaction, digest)? {
            if existing.metadata.size_bytes != declared_size
                || existing.metadata.api_version != SNAPSHOT_API_VERSION
                || existing.metadata.format != SNAPSHOT_ARCHIVE_FORMAT
            {
                return Err(StoreError::UploadConflict);
            }
            verify_snapshot_object(&self.snapshot_root, &existing)?;
            transaction.commit()?;
            return Ok(existing.metadata);
        }

        let relative = generated_snapshot_relative_path(digest)?;
        write_immutable_snapshot(&self.snapshot_root, &relative, data, digest)?;
        // SQLite stores snapshot creation time as epoch seconds. Return the
        // same canonical precision so an idempotent PUT is byte-for-byte
        // stable with a later metadata read.
        let now = timestamp(Utc::now().timestamp())?;
        transaction.execute(
            r#"
            INSERT INTO snapshots(
                digest, size, api_version, archive_format, relative_path, created_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            "#,
            params![
                digest,
                as_i64(declared_size),
                SNAPSHOT_API_VERSION,
                SNAPSHOT_ARCHIVE_FORMAT,
                relative.to_string_lossy(),
                now.timestamp(),
            ],
        )?;
        transaction.commit()?;
        Ok(SnapshotMetadataV1::new(
            digest.to_owned(),
            declared_size,
            now,
        ))
    }

    pub fn get_snapshot_metadata(&self, digest: &str) -> StoreResult<SnapshotMetadataV1> {
        cyc_protocol::validate_snapshot_digest(digest).map_err(|_| StoreError::InvalidUpload)?;
        let connection = self.connection()?;
        let stored = get_snapshot(&connection, digest)?.ok_or(StoreError::NotFound)?;
        verify_snapshot_object(&self.snapshot_root, &stored)?;
        Ok(stored.metadata)
    }

    /// Bind a worker download to the live worker credential, one-time run
    /// credential, lease, run owner, and the exact digest/size in JobSpec.
    #[allow(clippy::too_many_arguments)]
    pub fn authorize_snapshot_download(
        &self,
        worker_credential: &str,
        run_credential: &str,
        run_id: Uuid,
        lease_id: Uuid,
        requested_digest: &str,
    ) -> StoreResult<SnapshotDownload> {
        cyc_protocol::validate_snapshot_digest(requested_digest)
            .map_err(|_| StoreError::InvalidUpload)?;
        let now = Utc::now();
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        expire_leases(&transaction, now.timestamp())?;
        authorize_run_tx(
            &transaction,
            worker_credential,
            run_credential,
            run_id,
            lease_id,
            now.timestamp(),
        )?;
        let stored_job = get_job_by_run_id(&transaction, run_id)?;
        let expected_size = match &stored_job.job.source {
            SourceSpec::Snapshot {
                digest,
                size_bytes: Some(size_bytes),
            } if digest == requested_digest => *size_bytes,
            _ => return Err(StoreError::RunUnauthorized),
        };
        let stored = get_snapshot(&transaction, requested_digest)?.ok_or(StoreError::NotFound)?;
        if stored.metadata.size_bytes != expected_size {
            return Err(StoreError::DigestMismatch);
        }
        let path = verify_snapshot_object(&self.snapshot_root, &stored)?;
        let metadata = stored.metadata;
        transaction.commit()?;
        Ok(SnapshotDownload { metadata, path })
    }

    #[allow(clippy::too_many_arguments)]
    pub fn put_log_chunk(
        &self,
        worker_credential: &str,
        run_credential: &str,
        run_id: Uuid,
        lease_id: Uuid,
        stream: &str,
        offset: u64,
        expected_sha256: &str,
        data: &[u8],
    ) -> StoreResult<LogChunk> {
        if !matches!(stream, "stdout" | "stderr")
            || !valid_sha256(expected_sha256)
            || data.is_empty()
        {
            return Err(StoreError::InvalidUpload);
        }
        let actual = bytes_sha256(data);
        if actual != expected_sha256 {
            return Err(StoreError::DigestMismatch);
        }
        let now = Utc::now();
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        expire_leases(&transaction, now.timestamp())?;
        authorize_run_tx(
            &transaction,
            worker_credential,
            run_credential,
            run_id,
            lease_id,
            now.timestamp(),
        )?;
        if let Some(existing) = get_log_chunk(&transaction, run_id, stream, offset)? {
            if existing.sha256 == expected_sha256
                && existing.length == u64::try_from(data.len()).unwrap_or(u64::MAX)
            {
                transaction.commit()?;
                return Ok(existing);
            }
            return Err(StoreError::UploadConflict);
        }
        let (total_bytes, total_chunks) = transaction.query_row(
            r#"
            SELECT COALESCE(SUM(chunk_length), 0), COUNT(*)
            FROM log_chunks WHERE run_id = ?1
            "#,
            [run_id.to_string()],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
        )?;
        let upload_bytes = u64::try_from(data.len()).unwrap_or(u64::MAX);
        if as_u64(total_bytes).saturating_add(upload_bytes) > MAX_RUN_LOG_BYTES
            || as_u64(total_chunks) >= MAX_RUN_LOG_CHUNKS
        {
            return Err(StoreError::LogQuotaExceeded);
        }
        let next_offset = transaction.query_row(
            r#"
            SELECT COALESCE(SUM(chunk_length), 0) FROM log_chunks
            WHERE run_id = ?1 AND stream = ?2
            "#,
            params![run_id.to_string(), stream],
            |row| row.get::<_, i64>(0),
        )?;
        if as_u64(next_offset) != offset {
            return Err(StoreError::UploadOffset);
        }
        let stored = get_job_by_run_id(&transaction, run_id)?;
        let relative =
            generated_log_relative_path(stored.job.id, run_id, stream, offset, expected_sha256);
        write_immutable_object(&self.object_root, &relative, data, expected_sha256)?;
        transaction.execute(
            r#"
            INSERT INTO log_chunks(
                run_id, stream, chunk_offset, chunk_length, sha256, relative_path, created_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            "#,
            params![
                run_id.to_string(),
                stream,
                as_i64(offset),
                as_i64(upload_bytes),
                expected_sha256,
                relative.to_string_lossy(),
                now.timestamp(),
            ],
        )?;
        transaction.commit()?;
        Ok(LogChunk {
            run_id,
            stream: stream.to_owned(),
            offset,
            length: upload_bytes,
            sha256: expected_sha256.to_owned(),
            created_at: now,
        })
    }

    pub fn list_log_chunks(&self, id: Uuid) -> StoreResult<Vec<LogChunk>> {
        let connection = self.connection()?;
        let stored = get_job_prefer_job_id(&connection, id)?;
        let mut statement = connection.prepare(
            r#"
            SELECT stream, chunk_offset, chunk_length, sha256, created_at
            FROM log_chunks WHERE run_id = ?1 ORDER BY stream, chunk_offset
            "#,
        )?;
        let rows = statement
            .query_map([stored.run.id.to_string()], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, i64>(4)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        rows.into_iter()
            .map(|row| {
                Ok(LogChunk {
                    run_id: stored.run.id,
                    stream: row.0,
                    offset: as_u64(row.1),
                    length: as_u64(row.2),
                    sha256: row.3,
                    created_at: timestamp(row.4)?,
                })
            })
            .collect()
    }

    pub fn read_log(&self, id: Uuid, stream: &str) -> StoreResult<Vec<u8>> {
        if !matches!(stream, "stdout" | "stderr") {
            return Err(StoreError::InvalidUpload);
        }
        let connection = self.connection()?;
        let stored = get_job_prefer_job_id(&connection, id)?;
        let mut statement = connection.prepare(
            r#"
            SELECT chunk_offset, chunk_length, sha256, relative_path
            FROM log_chunks WHERE run_id = ?1 AND stream = ?2 ORDER BY chunk_offset
            "#,
        )?;
        let rows = statement
            .query_map(params![stored.run.id.to_string(), stream], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        let mut output = Vec::new();
        for (offset, length, sha256, relative) in rows {
            if as_u64(offset) != u64::try_from(output.len()).unwrap_or(u64::MAX) {
                return Err(StoreError::UploadOffset);
            }
            let bytes = read_generated_object(&self.object_root, Path::new(&relative))?;
            if u64::try_from(bytes.len()).unwrap_or(u64::MAX) != as_u64(length)
                || bytes_sha256(&bytes) != sha256
            {
                return Err(StoreError::DigestMismatch);
            }
            output.extend_from_slice(&bytes);
        }
        Ok(output)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn put_artifact(
        &self,
        worker_credential: &str,
        run_credential: &str,
        run_id: Uuid,
        lease_id: Uuid,
        artifact_id: Uuid,
        name: &str,
        expected_sha256: &str,
        data: &[u8],
    ) -> StoreResult<StoredArtifact> {
        if !valid_artifact_name(name) || !valid_sha256(expected_sha256) {
            return Err(StoreError::InvalidUpload);
        }
        let actual = bytes_sha256(data);
        if actual != expected_sha256 {
            return Err(StoreError::DigestMismatch);
        }
        let now = Utc::now();
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        expire_leases(&transaction, now.timestamp())?;
        authorize_run_tx(
            &transaction,
            worker_credential,
            run_credential,
            run_id,
            lease_id,
            now.timestamp(),
        )?;
        if let Some(existing) = get_artifact(&transaction, artifact_id)? {
            if existing.run_id == run_id
                && existing.sha256 == expected_sha256
                && existing.size == u64::try_from(data.len()).unwrap_or(u64::MAX)
                && existing.name == name
            {
                transaction.commit()?;
                return Ok(existing);
            }
            return Err(StoreError::UploadConflict);
        }
        let (total_bytes, total_count) = transaction.query_row(
            r#"
            SELECT COALESCE(SUM(size), 0), COUNT(*)
            FROM artifacts WHERE run_id = ?1
            "#,
            [run_id.to_string()],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
        )?;
        let upload_bytes = u64::try_from(data.len()).unwrap_or(u64::MAX);
        if as_u64(total_bytes).saturating_add(upload_bytes) > MAX_RUN_ARTIFACT_BYTES
            || as_u64(total_count) >= u64::from(MAX_RUN_ARTIFACT_COUNT)
        {
            return Err(StoreError::ArtifactQuotaExceeded);
        }
        let stored = get_job_by_run_id(&transaction, run_id)?;
        let relative = generated_artifact_relative_path(stored.job.id, run_id, artifact_id);
        write_immutable_object(&self.object_root, &relative, data, expected_sha256)?;
        transaction.execute(
            r#"
            INSERT INTO artifacts(id, run_id, name, size, sha256, relative_path, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            "#,
            params![
                artifact_id.to_string(),
                run_id.to_string(),
                name,
                as_i64(upload_bytes),
                expected_sha256,
                relative.to_string_lossy(),
                now.timestamp(),
            ],
        )?;
        transaction.commit()?;
        Ok(StoredArtifact {
            id: artifact_id,
            run_id,
            name: name.to_owned(),
            size: upload_bytes,
            sha256: expected_sha256.to_owned(),
            created_at: now,
        })
    }

    pub fn list_artifacts(&self, id: Uuid) -> StoreResult<Vec<StoredArtifact>> {
        let connection = self.connection()?;
        let stored = get_job_prefer_job_id(&connection, id)?;
        let mut statement = connection.prepare(
            r#"
            SELECT id, name, size, sha256, created_at FROM artifacts
            WHERE run_id = ?1 ORDER BY created_at, id
            "#,
        )?;
        let rows = statement
            .query_map([stored.run.id.to_string()], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, i64>(4)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        rows.into_iter()
            .map(|row| {
                Ok(StoredArtifact {
                    id: Uuid::parse_str(&row.0)?,
                    run_id: stored.run.id,
                    name: row.1,
                    size: as_u64(row.2),
                    sha256: row.3,
                    created_at: timestamp(row.4)?,
                })
            })
            .collect()
    }

    pub fn read_artifact(
        &self,
        id: Uuid,
        artifact_id: Uuid,
    ) -> StoreResult<(StoredArtifact, Vec<u8>)> {
        let connection = self.connection()?;
        let stored = get_job_prefer_job_id(&connection, id)?;
        let artifact = get_artifact(&connection, artifact_id)?.ok_or(StoreError::NotFound)?;
        if artifact.run_id != stored.run.id {
            return Err(StoreError::NotFound);
        }
        let relative = connection.query_row(
            "SELECT relative_path FROM artifacts WHERE id = ?1",
            [artifact_id.to_string()],
            |row| row.get::<_, String>(0),
        )?;
        let bytes = read_generated_object(&self.object_root, Path::new(&relative))?;
        if u64::try_from(bytes.len()).unwrap_or(u64::MAX) != artifact.size
            || bytes_sha256(&bytes) != artifact.sha256
        {
            return Err(StoreError::DigestMismatch);
        }
        Ok((artifact, bytes))
    }

    pub fn get_job(&self, id: Uuid) -> StoreResult<StoredJob> {
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        expire_leases(&transaction, Utc::now().timestamp())?;
        let stored = get_job_prefer_job_id(&transaction, id)?;
        transaction.commit()?;
        Ok(stored)
    }

    pub fn get_job_by_job_id(&self, job_id: Uuid) -> StoreResult<StoredJob> {
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        expire_leases(&transaction, Utc::now().timestamp())?;
        let stored = get_job_by_job_id(&transaction, job_id)?;
        transaction.commit()?;
        Ok(stored)
    }

    pub fn get_job_by_run_id(&self, run_id: Uuid) -> StoreResult<StoredJob> {
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        expire_leases(&transaction, Utc::now().timestamp())?;
        let stored = get_job_by_run_id(&transaction, run_id)?;
        transaction.commit()?;
        Ok(stored)
    }

    pub fn list_jobs(&self, limit: usize) -> StoreResult<Vec<StoredJob>> {
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        expire_leases(&transaction, Utc::now().timestamp())?;
        let jobs = list_jobs_tx(&transaction, limit)?;
        transaction.commit()?;
        Ok(jobs)
    }

    pub fn transition_run(
        &self,
        run_id: Uuid,
        expected_version: u64,
        next: JobState,
    ) -> StoreResult<StoredJob> {
        self.transition_run_with_evidence(run_id, expected_version, next, RunEvidence::default())
    }

    pub fn transition_run_with_evidence(
        &self,
        run_id: Uuid,
        expected_version: u64,
        next: JobState,
        evidence: RunEvidence,
    ) -> StoreResult<StoredJob> {
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        expire_leases(&transaction, Utc::now().timestamp())?;
        let mut stored = get_job_by_run_id(&transaction, run_id)?;
        if stored.version != expected_version {
            return Err(StoreError::VersionConflict {
                current_version: stored.version,
            });
        }
        if stored.cancel_requested && !matches!(next, JobState::Cancelled | JobState::Failed) {
            return Err(StoreError::CancellationPending);
        }
        if !next.is_terminal()
            && (evidence.exit_code.is_some()
                || evidence.error.is_some()
                || evidence.artifact_ids.is_some())
        {
            return Err(StoreError::InvalidRunEvidence);
        }
        stored
            .run
            .transition(next)
            .map_err(|_| StoreError::InvalidTransition)?;
        apply_run_evidence(&mut stored.run, evidence);
        stored
            .run
            .validate()
            .map_err(|_| StoreError::InvalidRunEvidence)?;
        update_job_cas(&transaction, &mut stored)?;
        if stored.run.state.is_terminal() {
            release_lease(&transaction, stored.lease_id, Utc::now().timestamp())?;
        }
        transaction.commit()?;
        Ok(stored)
    }

    pub fn cancel_job(&self, id: Uuid, expected_version: Option<u64>) -> StoreResult<StoredJob> {
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        expire_leases(&transaction, Utc::now().timestamp())?;
        let mut stored = get_job_prefer_job_id(&transaction, id)?;
        if let Some(expected) = expected_version {
            if stored.version != expected {
                return Err(StoreError::VersionConflict {
                    current_version: stored.version,
                });
            }
        }

        match stored.run.state {
            JobState::Queued => {
                stored
                    .run
                    .transition(JobState::Cancelled)
                    .map_err(|_| StoreError::InvalidTransition)?;
            }
            JobState::Preparing | JobState::Running | JobState::Verifying => {
                if stored.cancel_requested {
                    transaction.commit()?;
                    return Ok(stored);
                }
                stored.cancel_requested = true;
            }
            JobState::Succeeded | JobState::Failed | JobState::Cancelled => {
                return Err(StoreError::InvalidTransition);
            }
        }

        stored
            .run
            .validate()
            .map_err(|_| StoreError::InvalidRunEvidence)?;
        update_job_cas(&transaction, &mut stored)?;
        if stored.run.state == JobState::Cancelled {
            release_lease(&transaction, stored.lease_id, Utc::now().timestamp())?;
        }
        transaction.commit()?;
        Ok(stored)
    }

    /// Extend an active run reservation from a worker heartbeat. This is
    /// intentionally independent of the job CAS version.
    pub fn renew_lease(&self, run_id: Uuid) -> StoreResult<LeaseRenewal> {
        let now = Utc::now();
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        expire_leases(&transaction, now.timestamp())?;
        let stored = get_job_by_run_id(&transaction, run_id)?;
        if stored.run.state.is_terminal() {
            return Err(StoreError::InvalidTransition);
        }
        if stored.cancel_requested {
            return Err(StoreError::CancellationPending);
        }
        let lease_id = stored.lease_id.ok_or(StoreError::InvalidTransition)?;
        let renewed_at = now.timestamp().saturating_add(CLAIM_TTL_SECONDS);
        let changed = transaction.execute(
            r#"
            UPDATE leases SET expires_at = MAX(expires_at, ?1)
            WHERE id = ?2 AND run_id = ?3 AND released_at IS NULL AND expires_at > ?4
              AND phase IN ('execution', 'legacy')
            "#,
            params![
                renewed_at,
                lease_id.to_string(),
                run_id.to_string(),
                now.timestamp(),
            ],
        )?;
        if changed != 1 {
            return Err(StoreError::InvalidTransition);
        }
        let expires_at = transaction.query_row(
            "SELECT expires_at FROM leases WHERE id = ?1",
            [lease_id.to_string()],
            |row| row.get::<_, i64>(0),
        )?;
        transaction.commit()?;
        Ok(LeaseRenewal {
            run_id,
            lease_id,
            expires_at: timestamp(expires_at)?,
        })
    }

    pub fn reap_expired_leases(&self) -> StoreResult<u64> {
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let expired = expire_leases(&transaction, Utc::now().timestamp())?;
        transaction.commit()?;
        Ok(expired)
    }

    #[cfg(test)]
    fn active_lease_count(&self, node_id: Uuid) -> StoreResult<u64> {
        let now = Utc::now().timestamp();
        let value = self.connection()?.query_row(
            r#"
            SELECT COUNT(*) FROM leases
            WHERE node_id = ?1 AND released_at IS NULL
              AND (expires_at > ?2 OR phase = ?3)
            "#,
            params![node_id.to_string(), now, LEASE_PHASE_CLEANUP_PENDING],
            |row| row.get::<_, i64>(0),
        )?;
        Ok(as_u64(value))
    }
}

#[derive(Clone, Copy)]
enum NodeWriteAuthority {
    /// Controller/admin paths may replace all three state documents.
    Controller,
    /// Worker probes may create initial config, then only replace inventory and
    /// telemetry on subsequent reports.
    Worker,
    /// Enrollment probes establish inventory and initial config but must not
    /// count as evidence that the installed daemon is alive.
    PairingProbe,
}

fn load_node_component<T: DeserializeOwned>(
    connection: &Connection,
    table: &str,
    node_id: Uuid,
) -> StoreResult<Option<T>> {
    debug_assert!(matches!(
        table,
        "node_configs" | "node_inventories" | "node_telemetry"
    ));
    let document = connection
        .query_row(
            &format!("SELECT document FROM {table} WHERE node_id = ?1"),
            [node_id.to_string()],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    document
        .map(|document| serde_json::from_str(&document).map_err(StoreError::from))
        .transpose()
}

fn upsert_node_tx(
    transaction: &Transaction<'_>,
    node: &Node,
    authority: NodeWriteAuthority,
) -> StoreResult<()> {
    let received_at = if matches!(authority, NodeWriteAuthority::PairingProbe) {
        DateTime::<Utc>::from_timestamp(0, 0).expect("Unix epoch is valid")
    } else {
        Utc::now()
    };
    let incoming_config = NodeConfig::from_node(node);
    let inventory = NodeInventory::from_node(node);
    let mut telemetry = NodeTelemetry::from_node(node, received_at);
    if matches!(authority, NodeWriteAuthority::PairingProbe) {
        telemetry.status = cyc_protocol::NodeStatus::Offline;
    }
    incoming_config.validate()?;
    inventory.validate()?;
    telemetry.validate(&inventory)?;

    let existing_config = load_node_component::<NodeConfig>(transaction, "node_configs", node.id)?;
    let existing_config_revision = transaction
        .query_row(
            "SELECT revision FROM node_configs WHERE node_id = ?1",
            [node.id.to_string()],
            |row| row.get::<_, i64>(0),
        )
        .optional()?
        .unwrap_or_default();
    let existing_inventory =
        load_node_component::<NodeInventory>(transaction, "node_inventories", node.id)?;
    let existing_inventory_revision = transaction
        .query_row(
            "SELECT revision FROM node_inventories WHERE node_id = ?1",
            [node.id.to_string()],
            |row| row.get::<_, i64>(0),
        )
        .optional()?
        .unwrap_or_default();
    let config = match (authority, existing_config.as_ref()) {
        (NodeWriteAuthority::Worker | NodeWriteAuthority::PairingProbe, Some(existing)) => {
            existing.clone()
        }
        (
            NodeWriteAuthority::Controller
            | NodeWriteAuthority::Worker
            | NodeWriteAuthority::PairingProbe,
            None,
        ) => incoming_config,
        (NodeWriteAuthority::Controller, Some(_)) => incoming_config,
    };
    let material_changed = existing_config.as_ref() != Some(&config)
        || existing_inventory.as_ref() != Some(&inventory);
    let config_revision = if matches!(authority, NodeWriteAuthority::Controller)
        && existing_config
            .as_ref()
            .is_some_and(|existing| existing != &config)
    {
        existing_config_revision.saturating_add(1)
    } else {
        existing_config_revision
    };
    let current_revision = transaction
        .query_row(
            "SELECT revision FROM nodes WHERE id = ?1",
            [node.id.to_string()],
            |row| row.get::<_, i64>(0),
        )
        .optional()?
        .unwrap_or_default();
    let next_revision = if material_changed {
        current_revision.saturating_add(1)
    } else {
        current_revision
    };
    let view = NodeMergeView::merge(
        node.id,
        config.clone(),
        inventory.clone(),
        telemetry.clone(),
        received_at,
        received_at,
        Duration::from_secs(u64::try_from(NODE_FRESHNESS_SECONDS).unwrap_or_default()),
    )?;
    let document = serde_json::to_string(&view.to_node()?)?;
    let now = received_at.to_rfc3339();

    transaction.execute(
        r#"
        INSERT INTO nodes(id, document, updated_at, revision) VALUES (?1, ?2, ?3, ?4)
        ON CONFLICT(id) DO UPDATE SET
            document=excluded.document,
            updated_at=excluded.updated_at,
            revision=excluded.revision
        "#,
        params![node.id.to_string(), document, now, next_revision],
    )?;
    if !matches!(
        authority,
        NodeWriteAuthority::Worker | NodeWriteAuthority::PairingProbe
    ) || existing_config.is_none()
    {
        transaction.execute(
            r#"
            INSERT INTO node_configs(node_id, document, updated_at, revision) VALUES (?1, ?2, ?3, ?4)
            ON CONFLICT(node_id) DO UPDATE SET
                document=excluded.document,
                updated_at=excluded.updated_at,
                revision=excluded.revision
            "#,
            params![
                node.id.to_string(),
                serde_json::to_string(&config)?,
                now,
                config_revision
            ],
        )?;
    }
    let inventory_document = serde_json::to_string(&inventory)?;
    let inventory_revision = if existing_inventory
        .as_ref()
        .is_some_and(|existing| existing != &inventory)
    {
        existing_inventory_revision.saturating_add(1)
    } else {
        existing_inventory_revision
    };
    transaction.execute(
        r#"
        INSERT INTO node_inventories(
            node_id, document, updated_at, revision, digest, observed_at
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        ON CONFLICT(node_id) DO UPDATE SET
            document=excluded.document,
            updated_at=excluded.updated_at,
            revision=excluded.revision,
            digest=excluded.digest,
            observed_at=excluded.observed_at
        "#,
        params![
            node.id.to_string(),
            inventory_document,
            now,
            inventory_revision,
            format!(
                "sha256:{}",
                bytes_sha256(serde_json::to_string(&inventory)?.as_bytes())
            ),
            telemetry.observed_at.to_rfc3339(),
        ],
    )?;
    transaction.execute(
        r#"
        INSERT INTO node_telemetry(
            node_id, document, received_at, boot_generation, boot_id, sequence, observed_at
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
        ON CONFLICT(node_id) DO UPDATE SET
            document=excluded.document,
            received_at=excluded.received_at,
            boot_generation=excluded.boot_generation,
            boot_id=excluded.boot_id,
            sequence=excluded.sequence,
            observed_at=excluded.observed_at
        "#,
        params![
            node.id.to_string(),
            serde_json::to_string(&telemetry)?,
            now,
            as_i64(telemetry.boot_generation),
            telemetry.boot_id.to_string(),
            as_i64(telemetry.sequence),
            telemetry.observed_at.to_rfc3339(),
        ],
    )?;
    if material_changed {
        increment_meta(transaction, "fleet_revision")?;
    }
    Ok(())
}

fn upsert_legacy_probe_tx(transaction: &Transaction<'_>, node: &Node) -> StoreResult<()> {
    let boot_id = transaction
        .query_row(
            "SELECT boot_id FROM node_telemetry WHERE node_id = ?1",
            [node.id.to_string()],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    if boot_id
        .as_deref()
        .map(Uuid::parse_str)
        .transpose()?
        .is_some_and(|boot_id| !boot_id.is_nil())
    {
        return Ok(());
    }
    upsert_node_tx(transaction, node, NodeWriteAuthority::Worker)
}

fn random_secret() -> String {
    format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple())
}

fn valid_pairing_operation_key(value: &str) -> bool {
    (1..=128).contains(&value.len())
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b':' | b'-'))
}

fn validate_reserved_policy_labels(config: &NodeConfig) -> StoreResult<()> {
    if let Some(value) = config.labels.get("cyc.policy.allowedJobKinds") {
        let allowed = [
            "build",
            "test",
            "lint",
            "batch",
            "gpu",
            "container",
            "shell",
            // Transitional alias emitted by an older preview UI. It maps to
            // JobKind::Shell; new clients must write `shell`.
            "service",
        ];
        if !value.is_empty()
            && value
                .split(',')
                .any(|kind| kind.is_empty() || !allowed.contains(&kind))
        {
            return Err(StoreError::InvalidNodeConfig);
        }
    }
    if let Some(value) = config.labels.get("cyc.policy.resource") {
        let value: serde_json::Value =
            serde_json::from_str(value).map_err(|_| StoreError::InvalidNodeConfig)?;
        let object = value.as_object().ok_or(StoreError::InvalidNodeConfig)?;
        if object.keys().any(|key| {
            !matches!(
                key.as_str(),
                "cpuLimitPercent" | "maximumParallelJobs" | "memoryLimitBytes"
            )
        }) || object.get("cpuLimitPercent").is_some_and(|value| {
            !value.is_null() && value.as_u64().is_none_or(|value| value == 0 || value > 100)
        }) || object.get("maximumParallelJobs").is_some_and(|value| {
            !value.is_null()
                && value
                    .as_u64()
                    .is_none_or(|value| value == 0 || value > 1_024)
        }) || object
            .get("memoryLimitBytes")
            .is_some_and(|value| !value.is_null() && value.as_u64().is_none_or(|value| value == 0))
        {
            return Err(StoreError::InvalidNodeConfig);
        }
    }
    if let Some(value) = config.labels.get("cyc.policy.battery") {
        let value: serde_json::Value =
            serde_json::from_str(value).map_err(|_| StoreError::InvalidNodeConfig)?;
        let object = value.as_object().ok_or(StoreError::InvalidNodeConfig)?;
        if object.len() != 1
            || object
                .get("allowOnBattery")
                .and_then(|value| value.as_bool())
                .is_none()
        {
            return Err(StoreError::InvalidNodeConfig);
        }
    }
    Ok(())
}

fn effective_capacity_policy(config: &NodeConfig) -> StoreResult<cyc_protocol::CapacityPolicy> {
    validate_reserved_policy_labels(config)?;
    let mut capacity = config.capacity.clone();
    if capacity.allowed_job_kinds.is_empty() {
        if let Some(value) = config.labels.get("cyc.policy.allowedJobKinds") {
            for kind in value.split(',').filter(|kind| !kind.is_empty()) {
                capacity.allowed_job_kinds.insert(match kind {
                    "shell" | "service" => JobKind::Shell,
                    "build" => JobKind::Build,
                    "test" => JobKind::Test,
                    "lint" => JobKind::Lint,
                    "container" => JobKind::Container,
                    "gpu" => JobKind::Gpu,
                    "batch" => JobKind::Batch,
                    _ => return Err(StoreError::InvalidNodeConfig),
                });
            }
        }
    }
    if let Some(value) = config.labels.get("cyc.policy.resource") {
        let value: serde_json::Value =
            serde_json::from_str(value).map_err(|_| StoreError::InvalidNodeConfig)?;
        if capacity.max_cpu_percent.is_none() {
            capacity.max_cpu_percent = value
                .get("cpuLimitPercent")
                .and_then(serde_json::Value::as_u64)
                .and_then(|value| u8::try_from(value).ok());
        }
        if capacity.max_concurrent_jobs == 1 {
            capacity.max_concurrent_jobs = value
                .get("maximumParallelJobs")
                .and_then(serde_json::Value::as_u64)
                .and_then(|value| u32::try_from(value).ok())
                .unwrap_or(capacity.max_concurrent_jobs);
        }
        if capacity.memory_limit_mib.is_none() {
            capacity.memory_limit_mib = value
                .get("memoryLimitBytes")
                .and_then(serde_json::Value::as_u64)
                .map(|bytes| bytes.saturating_add(1_048_575) / 1_048_576);
        }
    }
    if !capacity.allow_on_battery {
        if let Some(value) = config.labels.get("cyc.policy.battery") {
            let value: serde_json::Value =
                serde_json::from_str(value).map_err(|_| StoreError::InvalidNodeConfig)?;
            capacity.allow_on_battery = value
                .get("allowOnBattery")
                .and_then(serde_json::Value::as_bool)
                .unwrap_or(false);
        }
    }
    capacity
        .validate()
        .map_err(|_| StoreError::InvalidNodeConfig)?;
    Ok(capacity)
}

fn derive_pairing_code(
    seed: &str,
    operation_key: &str,
    pairing_id: Uuid,
    intended_node_id: Uuid,
    created_at: i64,
) -> String {
    let mut digest = Sha256::new();
    digest.update(b"cyc-pairing-code-v1\0");
    digest.update(seed.as_bytes());
    digest.update(b"\0");
    digest.update(operation_key.as_bytes());
    digest.update(b"\0");
    digest.update(pairing_id.as_bytes());
    digest.update(intended_node_id.as_bytes());
    digest.update(created_at.to_be_bytes());
    let digest = digest.finalize();
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn secret_hash(secret: &str) -> String {
    bytes_sha256(secret.as_bytes())
}

fn bytes_sha256(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn valid_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn authenticate_worker_tx(
    transaction: &Transaction<'_>,
    credential: &str,
    now: i64,
) -> StoreResult<Uuid> {
    let hash = secret_hash(credential);
    let node_id = transaction
        .query_row(
            r#"
            SELECT wc.node_id
            FROM worker_credentials wc
            JOIN pairings p ON p.id = wc.pairing_id
            JOIN nodes n ON n.id = wc.node_id
            WHERE wc.credential_hash = ?1
              AND wc.activated_at IS NOT NULL
              AND wc.revoked_at IS NULL
              AND p.used_at IS NOT NULL
              AND p.acknowledged_at IS NOT NULL
              AND p.revoked_at IS NULL
              AND p.failed_at IS NULL
              AND p.failure_code IS NULL
              AND p.node_id = wc.node_id
              AND p.intended_node_id = wc.node_id
              AND 1 = (
                  SELECT COUNT(*) FROM worker_credentials other
                  WHERE other.pairing_id = p.id
              )
            "#,
            [hash.clone()],
            |row| row.get::<_, String>(0),
        )
        .optional()?
        .ok_or(StoreError::WorkerUnauthorized)?;
    transaction.execute(
        "UPDATE worker_credentials SET last_used_at = ?1 WHERE credential_hash = ?2",
        params![now, hash],
    )?;
    Ok(Uuid::parse_str(&node_id)?)
}

fn authorize_run_tx(
    transaction: &Transaction<'_>,
    worker_credential: &str,
    run_credential: &str,
    run_id: Uuid,
    lease_id: Uuid,
    now: i64,
) -> StoreResult<Uuid> {
    let node_id = authenticate_worker_tx(transaction, worker_credential, now)?;
    let claim_node = transaction
        .query_row(
            r#"
            SELECT c.node_id FROM worker_claims c
            JOIN leases l ON l.id = c.lease_id AND l.run_id = c.run_id
            WHERE c.run_id = ?1 AND c.lease_id = ?2 AND c.credential_hash = ?3
              AND c.revoked_at IS NULL AND c.expires_at > ?4
              AND l.released_at IS NULL AND l.expires_at > ?4
              AND l.phase IN ('execution', 'legacy')
            "#,
            params![
                run_id.to_string(),
                lease_id.to_string(),
                secret_hash(run_credential),
                now,
            ],
            |row| row.get::<_, String>(0),
        )
        .optional()?
        .ok_or(StoreError::RunUnauthorized)?;
    if Uuid::parse_str(&claim_node)? != node_id {
        return Err(StoreError::RunUnauthorized);
    }
    Ok(node_id)
}

/// Authenticate a completion receipt against the stable worker credential and
/// the original run secret without requiring the claim to remain active. This
/// is used only to acknowledge an already committed, same-digest retry.
fn authorize_completion_receipt_tx(
    transaction: &Transaction<'_>,
    worker_credential: &str,
    run_credential: &str,
    run_id: Uuid,
    lease_id: Uuid,
    now: i64,
) -> StoreResult<Uuid> {
    let node_id = authenticate_worker_tx(transaction, worker_credential, now)?;
    let claim_node = transaction
        .query_row(
            r#"
            SELECT node_id FROM worker_claims
            WHERE run_id = ?1 AND lease_id = ?2 AND credential_hash = ?3
            "#,
            params![
                run_id.to_string(),
                lease_id.to_string(),
                secret_hash(run_credential),
            ],
            |row| row.get::<_, String>(0),
        )
        .optional()?
        .ok_or(StoreError::RunUnauthorized)?;
    if Uuid::parse_str(&claim_node)? != node_id {
        return Err(StoreError::RunUnauthorized);
    }
    Ok(node_id)
}

fn ensure_artifacts_belong_to_run(
    transaction: &Transaction<'_>,
    run_id: Uuid,
    artifact_ids: &[Uuid],
) -> StoreResult<()> {
    for artifact_id in artifact_ids {
        let owner = transaction
            .query_row(
                "SELECT run_id FROM artifacts WHERE id = ?1",
                [artifact_id.to_string()],
                |row| row.get::<_, String>(0),
            )
            .optional()?
            .ok_or(StoreError::InvalidRunEvidence)?;
        if Uuid::parse_str(&owner)? != run_id {
            return Err(StoreError::InvalidRunEvidence);
        }
    }
    Ok(())
}

fn validate_managed_completion(
    transaction: &Transaction<'_>,
    object_root: &Path,
    stored: &StoredJob,
    completion: &RunCompletion,
) -> StoreResult<()> {
    let node_id = stored.run.node_id.ok_or(StoreError::RunUnauthorized)?;
    let node_document = transaction
        .query_row(
            "SELECT document FROM nodes WHERE id = ?1",
            [node_id.to_string()],
            |row| row.get::<_, String>(0),
        )
        .optional()?
        .ok_or(StoreError::RunUnauthorized)?;
    let node: Node = serde_json::from_str(&node_document)?;
    if !matches!(&node.transport, NodeTransport::Managed { .. }) {
        return Err(StoreError::RunUnauthorized);
    }

    validate_execution_source(
        &stored.job.source,
        completion.final_state,
        completion.evidence.error.as_deref(),
        &completion.execution,
    )?;
    validate_step_evidence(&stored.job, node.os, completion)?;

    let stdout = verify_stream_evidence(
        transaction,
        object_root,
        completion.run_id,
        "stdout",
        &completion.execution.streams.stdout,
    )?;
    let stderr = verify_stream_evidence(
        transaction,
        object_root,
        completion.run_id,
        "stderr",
        &completion.execution.streams.stderr,
    )?;
    if stdout.0.saturating_add(stderr.0) > MAX_RUN_LOG_BYTES
        || stdout.1.saturating_add(stderr.1) > MAX_RUN_LOG_CHUNKS
    {
        return Err(StoreError::InvalidRunEvidence);
    }

    validate_artifact_manifest(transaction, object_root, completion)?;
    Ok(())
}

fn validate_execution_source(
    source: &SourceSpec,
    final_state: JobState,
    _error: Option<&str>,
    execution: &ExecutionEvidence,
) -> StoreResult<()> {
    let observed = &execution.source;
    match source {
        SourceSpec::Git {
            repository,
            revision,
        } => {
            if observed.kind != "git"
                || observed.repository != *repository
                || observed.requested_revision != *revision
            {
                return Err(StoreError::InvalidRunEvidence);
            }
            let incomplete = observed.resolved_revision.is_empty() && observed.tree.is_empty();
            if incomplete {
                if final_state == JobState::Succeeded
                    || !matches!(
                        execution.termination.reason,
                        TerminationReason::SourcePreparationFailed
                            | TerminationReason::CancelRequested
                            | TerminationReason::LeaseLost
                            | TerminationReason::TimedOut
                            | TerminationReason::TransportFailure
                    )
                {
                    return Err(StoreError::InvalidRunEvidence);
                }
            } else if observed.resolved_revision != *revision
                || !valid_object_id(&observed.tree)
                || !observed.git_version.starts_with("git version ")
            {
                return Err(StoreError::InvalidRunEvidence);
            }
        }
        SourceSpec::Snapshot { digest, .. } => {
            if observed.kind != "snapshot"
                || observed.repository != "snapshot"
                || observed.requested_revision != *digest
                || observed.git_version != "not-applicable"
            {
                return Err(StoreError::InvalidRunEvidence);
            }
            let unresolved = observed.resolved_revision.is_empty() && observed.tree.is_empty();
            if unresolved {
                if final_state == JobState::Succeeded
                    || !matches!(
                        execution.termination.reason,
                        TerminationReason::SourcePreparationFailed
                            | TerminationReason::CancelRequested
                            | TerminationReason::LeaseLost
                            | TerminationReason::TimedOut
                            | TerminationReason::TransportFailure
                    )
                {
                    return Err(StoreError::InvalidRunEvidence);
                }
            } else if observed.resolved_revision != *digest || observed.tree != *digest {
                return Err(StoreError::InvalidRunEvidence);
            }
        }
    }
    Ok(())
}

fn validate_step_evidence(
    job: &JobSpec,
    os: OperatingSystem,
    completion: &RunCompletion,
) -> StoreResult<()> {
    let steps = &completion.execution.steps;
    if steps.len() > job.steps.len()
        || (completion.final_state == JobState::Succeeded && steps.len() != job.steps.len())
        || ((completion.execution.source.resolved_revision.is_empty()
            && completion.execution.source.tree.is_empty())
            && !steps.is_empty())
    {
        return Err(StoreError::InvalidRunEvidence);
    }
    let default_shell = match os {
        OperatingSystem::Windows => Shell::Powershell,
        OperatingSystem::Linux => Shell::Bash,
        OperatingSystem::Macos => Shell::Zsh,
    };
    let started_at = completion.evidence.started_at;
    let finished_at = completion
        .evidence
        .finished_at
        .ok_or(StoreError::InvalidRunEvidence)?;
    let mut previous_finished = None;
    for (observed, expected) in steps.iter().zip(&job.steps) {
        if observed.name != expected.name
            || observed.shell != expected.shell.unwrap_or(default_shell)
            || started_at.is_some_and(|started| observed.started_at < started)
            || observed.finished_at > finished_at
            || previous_finished.is_some_and(|finished| observed.started_at < finished)
        {
            return Err(StoreError::InvalidRunEvidence);
        }
        previous_finished = Some(observed.finished_at);
    }
    if completion.final_state == JobState::Cancelled
        && !matches!(
            completion.execution.termination.reason,
            TerminationReason::CancelRequested
                | TerminationReason::TimedOut
                | TerminationReason::LeaseLost
        )
    {
        return Err(StoreError::InvalidRunEvidence);
    }
    Ok(())
}

fn verify_stream_evidence(
    transaction: &Transaction<'_>,
    object_root: &Path,
    run_id: Uuid,
    stream: &str,
    expected: &StreamEvidence,
) -> StoreResult<(u64, u64)> {
    let mut statement = transaction.prepare(
        r#"
        SELECT chunk_offset, chunk_length, sha256, relative_path
        FROM log_chunks WHERE run_id = ?1 AND stream = ?2 ORDER BY chunk_offset
        "#,
    )?;
    let rows = statement
        .query_map(params![run_id.to_string(), stream], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let mut hasher = Sha256::new();
    let mut byte_count = 0_u64;
    let mut chunk_count = 0_u64;
    for (offset, length, sha256, relative_path) in rows {
        let length = as_u64(length);
        if as_u64(offset) != byte_count || length == 0 || !valid_sha256(&sha256) {
            return Err(StoreError::InvalidRunEvidence);
        }
        let bytes = read_generated_object(object_root, Path::new(&relative_path))?;
        if u64::try_from(bytes.len()).unwrap_or(u64::MAX) != length
            || bytes_sha256(&bytes) != sha256
        {
            return Err(StoreError::DigestMismatch);
        }
        hasher.update(&bytes);
        byte_count = byte_count.saturating_add(length);
        chunk_count = chunk_count.saturating_add(1);
    }
    let digest = hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    if expected.byte_count != byte_count
        || expected.chunk_count != chunk_count
        || expected.sha256 != digest
    {
        return Err(StoreError::InvalidRunEvidence);
    }
    Ok((byte_count, chunk_count))
}

fn validate_artifact_manifest(
    transaction: &Transaction<'_>,
    object_root: &Path,
    completion: &RunCompletion,
) -> StoreResult<()> {
    let mut statement = transaction.prepare(
        r#"
        SELECT id, name, size, sha256, relative_path
        FROM artifacts WHERE run_id = ?1 ORDER BY id
        "#,
    )?;
    let rows = statement
        .query_map([completion.run_id.to_string()], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    if rows.len() != completion.artifacts.len() {
        return Err(StoreError::InvalidRunEvidence);
    }
    let manifests = completion
        .artifacts
        .iter()
        .map(|artifact| (artifact.id, artifact))
        .collect::<BTreeMap<_, _>>();
    let mut total_bytes = 0_u64;
    let mut ids = BTreeSet::new();
    for (id, name, size, sha256, relative_path) in rows {
        let id = Uuid::parse_str(&id)?;
        let size = as_u64(size);
        let manifest = manifests.get(&id).ok_or(StoreError::InvalidRunEvidence)?;
        if !ids.insert(id)
            || manifest.run_id != completion.run_id
            || manifest.relative_path != name
            || manifest.size_bytes != size
            || manifest.sha256 != sha256
            || manifest.media_type.is_some()
        {
            return Err(StoreError::InvalidRunEvidence);
        }
        let bytes = read_generated_object(object_root, Path::new(&relative_path))?;
        if u64::try_from(bytes.len()).unwrap_or(u64::MAX) != size || bytes_sha256(&bytes) != sha256
        {
            return Err(StoreError::DigestMismatch);
        }
        total_bytes = total_bytes.saturating_add(size);
    }
    if u64::try_from(manifests.len()).unwrap_or(u64::MAX) > u64::from(MAX_RUN_ARTIFACT_COUNT)
        || total_bytes > MAX_RUN_ARTIFACT_BYTES
    {
        return Err(StoreError::InvalidRunEvidence);
    }
    Ok(())
}

fn valid_object_id(value: &str) -> bool {
    matches!(value.len(), 40 | 64)
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn valid_artifact_name(name: &str) -> bool {
    name.len() <= 512
        && validate_portable_relative_path(name).is_ok()
        && !name.split('/').any(|segment| segment == ".git")
}

fn get_snapshot(connection: &Connection, digest: &str) -> StoreResult<Option<StoredSnapshot>> {
    let row = connection
        .query_row(
            r#"
            SELECT size, api_version, archive_format, relative_path, created_at
            FROM snapshots WHERE digest = ?1
            "#,
            [digest],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, i64>(4)?,
                ))
            },
        )
        .optional()?;
    row.map(|(size, api_version, format, relative_path, created_at)| {
        let metadata = SnapshotMetadataV1 {
            api_version,
            format,
            digest: digest.to_owned(),
            size_bytes: as_u64(size),
            created_at: timestamp(created_at)?,
        };
        metadata.validate().map_err(|_| StoreError::InvalidUpload)?;
        Ok(StoredSnapshot {
            metadata,
            relative_path: PathBuf::from(relative_path),
        })
    })
    .transpose()
}

fn generated_snapshot_relative_path(digest: &str) -> StoreResult<PathBuf> {
    let hex = cyc_protocol::snapshot_digest_hex(digest).map_err(|_| StoreError::InvalidUpload)?;
    Ok(PathBuf::from("sha256").join(format!("{hex}.tar.zst")))
}

fn metadata_is_reparse(metadata: &fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;
        metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
    }
    #[cfg(not(windows))]
    {
        let _ = metadata;
        false
    }
}

fn require_direct_directory(path: &Path) -> StoreResult<()> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() || metadata_is_reparse(&metadata) {
        return Err(StoreError::InvalidUpload);
    }
    Ok(())
}

fn prepare_snapshot_parent(root: &Path, relative: &Path) -> StoreResult<PathBuf> {
    let path = safe_object_path(root, relative)?;
    fs::create_dir_all(root)?;
    require_direct_directory(root)?;
    let parent = path.parent().ok_or(StoreError::InvalidUpload)?;
    fs::create_dir_all(parent)?;
    require_direct_directory(parent)?;
    let canonical_root = fs::canonicalize(root)?;
    let canonical_parent = fs::canonicalize(parent)?;
    if !canonical_parent.starts_with(&canonical_root) {
        return Err(StoreError::InvalidUpload);
    }
    Ok(path)
}

fn verify_snapshot_object(root: &Path, stored: &StoredSnapshot) -> StoreResult<PathBuf> {
    use std::io::Read;

    let path = safe_object_path(root, &stored.relative_path)?;
    require_direct_directory(root)?;
    let parent = path.parent().ok_or(StoreError::InvalidUpload)?;
    require_direct_directory(parent)?;
    let canonical_root = fs::canonicalize(root)?;
    let canonical_parent = fs::canonicalize(parent)?;
    if !canonical_parent.starts_with(&canonical_root) {
        return Err(StoreError::InvalidUpload);
    }
    let file_metadata = fs::symlink_metadata(&path)?;
    if !file_metadata.is_file()
        || file_metadata.file_type().is_symlink()
        || metadata_is_reparse(&file_metadata)
        || file_metadata.len() != stored.metadata.size_bytes
    {
        return Err(StoreError::DigestMismatch);
    }
    let mut file = fs::File::open(&path)?;
    let mut hasher = Sha256::new();
    let mut observed = 0_u64;
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let length = file.read(&mut buffer)?;
        if length == 0 {
            break;
        }
        observed = observed.saturating_add(u64::try_from(length).unwrap_or(u64::MAX));
        if observed > stored.metadata.size_bytes {
            return Err(StoreError::DigestMismatch);
        }
        hasher.update(&buffer[..length]);
    }
    let actual = format!(
        "sha256:{}",
        hasher
            .finalize()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>()
    );
    if observed != stored.metadata.size_bytes || actual != stored.metadata.digest {
        return Err(StoreError::DigestMismatch);
    }
    Ok(path)
}

fn write_immutable_snapshot(
    root: &Path,
    relative: &Path,
    bytes: &[u8],
    expected_digest: &str,
) -> StoreResult<()> {
    use std::io::Write;

    let path = prepare_snapshot_parent(root, relative)?;
    if path.exists() {
        let existing = fs::read(&path)?;
        if u64::try_from(existing.len()).unwrap_or(u64::MAX) <= MAX_SNAPSHOT_ARCHIVE_BYTES
            && format!("sha256:{}", bytes_sha256(&existing)) == expected_digest
            && existing == bytes
        {
            return Ok(());
        }
        return Err(StoreError::UploadConflict);
    }
    let parent = path.parent().ok_or(StoreError::InvalidUpload)?;
    let temporary = parent.join(format!(".{}.snapshot.tmp", Uuid::new_v4()));
    let result = (|| -> StoreResult<()> {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);

        #[cfg(unix)]
        {
            fs::hard_link(&temporary, &path)?;
            fs::File::open(parent)?.sync_all()?;
            fs::remove_file(&temporary)?;
            fs::File::open(parent)?.sync_all()?;
        }
        #[cfg(windows)]
        {
            // Windows rename is create-new for a destination that already
            // exists, so it cannot silently replace an immutable object.
            fs::rename(&temporary, &path)?;
        }
        #[cfg(not(any(unix, windows)))]
        compile_error!("snapshot atomic installation requires Unix or Windows");
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
        if path.exists() {
            let existing = fs::read(&path)?;
            if format!("sha256:{}", bytes_sha256(&existing)) == expected_digest && existing == bytes
            {
                return Ok(());
            }
        }
    }
    result
}

fn generated_log_relative_path(
    job_id: Uuid,
    run_id: Uuid,
    stream: &str,
    offset: u64,
    sha256: &str,
) -> PathBuf {
    PathBuf::from(job_id.to_string())
        .join(run_id.to_string())
        .join("logs")
        .join(stream)
        .join(format!("{offset:020}-{sha256}.chunk"))
}

fn generated_artifact_relative_path(job_id: Uuid, run_id: Uuid, artifact_id: Uuid) -> PathBuf {
    PathBuf::from(job_id.to_string())
        .join(run_id.to_string())
        .join("artifacts")
        .join(format!("{artifact_id}.bin"))
}

fn safe_object_path(root: &Path, relative: &Path) -> StoreResult<PathBuf> {
    if relative.is_absolute()
        || relative
            .components()
            .any(|component| !matches!(component, std::path::Component::Normal(_)))
    {
        return Err(StoreError::InvalidUpload);
    }
    Ok(root.join(relative))
}

fn write_immutable_object(
    root: &Path,
    relative: &Path,
    bytes: &[u8],
    expected_sha256: &str,
) -> StoreResult<()> {
    let path = safe_object_path(root, relative)?;
    let parent = path.parent().ok_or(StoreError::InvalidUpload)?;
    fs::create_dir_all(parent)?;
    if path.exists() {
        let existing = fs::read(&path)?;
        if bytes_sha256(&existing) == expected_sha256 && existing == bytes {
            return Ok(());
        }
        return Err(StoreError::UploadConflict);
    }
    let temporary = parent.join(format!(".{}.tmp", Uuid::new_v4()));
    let result = (|| -> StoreResult<()> {
        use std::io::Write;
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        fs::rename(&temporary, &path)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn read_generated_object(root: &Path, relative: &Path) -> StoreResult<Vec<u8>> {
    fs::read(safe_object_path(root, relative)?).map_err(StoreError::from)
}

fn get_log_chunk(
    connection: &Connection,
    run_id: Uuid,
    stream: &str,
    offset: u64,
) -> StoreResult<Option<LogChunk>> {
    let row = connection
        .query_row(
            r#"
            SELECT chunk_length, sha256, created_at FROM log_chunks
            WHERE run_id = ?1 AND stream = ?2 AND chunk_offset = ?3
            "#,
            params![run_id.to_string(), stream, as_i64(offset)],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?,
                ))
            },
        )
        .optional()?;
    row.map(|row| {
        Ok(LogChunk {
            run_id,
            stream: stream.to_owned(),
            offset,
            length: as_u64(row.0),
            sha256: row.1,
            created_at: timestamp(row.2)?,
        })
    })
    .transpose()
}

fn get_artifact(connection: &Connection, artifact_id: Uuid) -> StoreResult<Option<StoredArtifact>> {
    let row = connection
        .query_row(
            "SELECT run_id, name, size, sha256, created_at FROM artifacts WHERE id = ?1",
            [artifact_id.to_string()],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, i64>(4)?,
                ))
            },
        )
        .optional()?;
    row.map(|row| {
        Ok(StoredArtifact {
            id: artifact_id,
            run_id: Uuid::parse_str(&row.0)?,
            name: row.1,
            size: as_u64(row.2),
            sha256: row.3,
            created_at: timestamp(row.4)?,
        })
    })
    .transpose()
}

fn unique_queued_run(transaction: &Transaction<'_>, job_id: Uuid) -> StoreResult<Run> {
    for _ in 0..16 {
        let run = Run::queued(job_id);
        if run.id == job_id {
            continue;
        }
        let occupied = transaction
            .query_row(
                "SELECT 1 FROM jobs WHERE job_id = ?1 OR run_id = ?1",
                [run.id.to_string()],
                |_row| Ok(()),
            )
            .optional()?
            .is_some();
        if !occupied {
            return Ok(run);
        }
    }
    Err(StoreError::Conflict)
}

fn effective_gpu_request(job: &JobSpec) -> Option<GpuResourceRequest> {
    job.effective_resource_request().gpu.or_else(|| {
        (job.kind == JobKind::Gpu).then_some(GpuResourceRequest {
            device_id: None,
            vendor: None,
            vram_mib: 0,
            exclusive: true,
        })
    })
}

fn select_gpu_reservation(
    nodes: &[SchedulingNodeRecord],
    node_id: Uuid,
    request: Option<&GpuResourceRequest>,
) -> StoreResult<Option<(String, GpuResourceRequest)>> {
    let Some(request) = request else {
        return Ok(None);
    };
    let scheduling = nodes
        .iter()
        .find(|record| record.scheduling.node.id == node_id)
        .map(|record| &record.scheduling)
        .ok_or(StoreError::PlanStale)?;
    let selected = scheduling
        .node
        .resources
        .gpus
        .iter()
        .enumerate()
        .filter(|(index, gpu)| {
            gpu.allocatable
                && gpu.available_vram_mib >= request.vram_mib
                && request.vendor.is_none_or(|vendor| vendor == gpu.vendor)
                && request.device_id.as_deref().is_none_or(|requested| {
                    scheduling
                        .gpu_device_ids
                        .get(*index)
                        .and_then(Option::as_deref)
                        == Some(requested)
                })
                && (!request.exclusive
                    || scheduling
                        .gpu_active_reservations
                        .get(*index)
                        .copied()
                        .unwrap_or_default()
                        == 0)
        })
        .max_by(|(left_index, left), (right_index, right)| {
            left.available_vram_mib
                .cmp(&right.available_vram_mib)
                // A lower stable index wins a capacity tie.
                .then_with(|| right_index.cmp(left_index))
        });
    let Some((index, _)) = selected else {
        // Scheduling and reservation happen under the same IMMEDIATE
        // transaction. Reaching this branch means stored state was invalid,
        // not a recoverable race.
        return Err(StoreError::InvalidTransition);
    };
    let device_id = scheduling
        .gpu_device_ids
        .get(index)
        .cloned()
        .flatten()
        .ok_or(StoreError::InvalidTransition)?;
    Ok(Some((device_id, request.clone())))
}

fn apply_run_evidence(run: &mut Run, evidence: RunEvidence) {
    if run.state.is_terminal() {
        run.exit_code = evidence.exit_code;
        run.error = evidence.error;
    }
    if let Some(artifact_ids) = evidence.artifact_ids {
        run.artifact_ids = artifact_ids;
    }
}

fn worker_state_conflict(stored: &StoredJob) -> StoreError {
    StoreError::WorkerStateConflict {
        current_version: stored.version,
        cancel_requested: stored.cancel_requested,
        current_state: stored.run.state,
    }
}

/// One-time, idempotent upgrade from the legacy mixed `nodes.document` model.
/// The legacy row remains as a compatibility mirror/index, while all reads
/// after migration are composed from the three authoritative documents.
fn migrate_legacy_node_documents(connection: &Connection) -> StoreResult<()> {
    let rows = {
        let mut statement = connection.prepare("SELECT id, document, updated_at FROM nodes")?;
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };
    for (id, document, updated_at) in rows {
        let node: Node = serde_json::from_str(&document)?;
        if node.id.to_string() != id {
            return Err(StoreError::NodeIdentityMismatch);
        }
        let received_at = DateTime::parse_from_rfc3339(&updated_at)
            .map_err(|_| StoreError::Timestamp)?
            .with_timezone(&Utc);
        let config = NodeConfig::from_node(&node);
        let inventory = NodeInventory::from_node(&node);
        let telemetry = NodeTelemetry::from_node(&node, received_at);
        connection.execute(
            "INSERT OR IGNORE INTO node_configs(node_id, document, updated_at) VALUES (?1, ?2, ?3)",
            params![id, serde_json::to_string(&config)?, updated_at],
        )?;
        connection.execute(
            "INSERT OR IGNORE INTO node_inventories(node_id, document, updated_at) VALUES (?1, ?2, ?3)",
            params![id, serde_json::to_string(&inventory)?, updated_at],
        )?;
        connection.execute(
            "INSERT OR IGNORE INTO node_telemetry(node_id, document, received_at) VALUES (?1, ?2, ?3)",
            params![id, serde_json::to_string(&telemetry)?, updated_at],
        )?;
    }
    Ok(())
}

fn backfill_node_report_metadata(connection: &Connection) -> StoreResult<()> {
    let rows = {
        let mut statement = connection.prepare(
            r#"
            SELECT i.node_id, i.document, i.updated_at, i.digest, i.observed_at,
                   t.document, t.received_at, t.boot_generation, t.boot_id, t.observed_at
            FROM node_inventories i
            JOIN node_telemetry t ON t.node_id = i.node_id
            "#,
        )?;
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, String>(5)?,
                    row.get::<_, String>(6)?,
                    row.get::<_, i64>(7)?,
                    row.get::<_, String>(8)?,
                    row.get::<_, String>(9)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };
    for (
        node_id,
        inventory_document,
        inventory_updated_at,
        inventory_digest,
        inventory_observed_at,
        telemetry_document,
        telemetry_received_at,
        boot_generation,
        boot_id,
        telemetry_observed_at,
    ) in rows
    {
        let telemetry: NodeTelemetry = serde_json::from_str(&telemetry_document)?;
        let missing_inventory_observed_at =
            inventory_observed_at.is_empty() || inventory_observed_at.starts_with("1970-01-01");
        if inventory_digest.is_empty() || missing_inventory_observed_at {
            connection.execute(
                r#"
                UPDATE node_inventories SET digest = ?1, observed_at = ?2
                WHERE node_id = ?3
                "#,
                params![
                    if inventory_digest.is_empty() {
                        format!("sha256:{}", bytes_sha256(inventory_document.as_bytes()))
                    } else {
                        inventory_digest
                    },
                    if missing_inventory_observed_at {
                        telemetry.observed_at.to_rfc3339()
                    } else {
                        inventory_observed_at
                    },
                    node_id,
                ],
            )?;
        }
        if boot_id.is_empty()
            || telemetry_observed_at.starts_with("1970-01-01")
            || (boot_generation == 0 && telemetry.boot_generation > 0)
        {
            connection.execute(
                r#"
                UPDATE node_telemetry SET
                    boot_generation = CASE WHEN boot_generation = 0 THEN ?1 ELSE boot_generation END,
                    boot_id = COALESCE(NULLIF(boot_id, ''), ?2),
                    observed_at = ?3
                WHERE node_id = ?4
                "#,
                params![
                    as_i64(telemetry.boot_generation),
                    Uuid::nil().to_string(),
                    telemetry.observed_at.to_rfc3339(),
                    node_id
                ],
            )?;
        }
        // Parsing this also proves historical controller receive evidence is
        // usable before a strict NodeReport becomes authoritative.
        DateTime::parse_from_rfc3339(&telemetry_received_at).map_err(|_| StoreError::Timestamp)?;
        DateTime::parse_from_rfc3339(&inventory_updated_at).map_err(|_| StoreError::Timestamp)?;
    }
    Ok(())
}

fn ensure_column(
    connection: &Connection,
    table: &str,
    column: &str,
    definition: &str,
) -> StoreResult<()> {
    let mut statement = connection.prepare(&format!("PRAGMA table_info({table})"))?;
    let columns = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?;
    if !columns.iter().any(|existing| existing == column) {
        connection.execute_batch(&format!(
            "ALTER TABLE {table} ADD COLUMN {column} {definition}"
        ))?;
    }
    Ok(())
}

/// Backfill pre-protocol terminal completions without pretending that their
/// already-released reservation proves workspace removal.  A historical
/// `removed` receipt is trusted; every other legacy early release remains
/// visible as bounded failure evidence.
/// Backfill only when one historical, durably-used plan proves the exact
/// canonical job and selected node. Missing, malformed, or multiple plan rows
/// remain explicit legacy NULLs; the migration never synthesizes authority.
fn migrate_job_plan_bindings(connection: &mut Connection) -> StoreResult<()> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    transaction.execute_batch(
        r#"
        DROP TRIGGER IF EXISTS jobs_require_plan_binding_insert;
        DROP TRIGGER IF EXISTS jobs_plan_binding_immutable;
        "#,
    )?;
    let legacy_rows = {
        let mut statement = transaction.prepare(
            r#"
            SELECT job_id, job, run
            FROM jobs
            WHERE plan_binding IS NULL
            ORDER BY created_at, run_id
            "#,
        )?;
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };

    for (stored_job_id, job_document, run_document) in legacy_rows {
        let Ok(job_id) = Uuid::parse_str(&stored_job_id) else {
            continue;
        };
        let Ok(job) = serde_json::from_str::<JobSpec>(&job_document) else {
            continue;
        };
        let Ok(run) = serde_json::from_str::<Run>(&run_document) else {
            continue;
        };
        if job.id != job_id
            || run.job_id != job.id
            || job.validate().is_err()
            || normalize_job_spec(&job) != job
        {
            continue;
        }

        let plan_ids = {
            let mut statement = transaction.prepare(
                r#"
                SELECT id FROM plans
                WHERE job_id = ?1 AND used_at IS NOT NULL
                ORDER BY id
                LIMIT 2
                "#,
            )?;
            let rows = statement
                .query_map([job_id.to_string()], |row| row.get::<_, String>(0))?
                .collect::<Result<Vec<_>, _>>()?;
            rows
        };
        if plan_ids.len() != 1 {
            continue;
        }
        let Ok(plan_id) = Uuid::parse_str(&plan_ids[0]) else {
            continue;
        };
        let Ok(plan) = get_plan(&transaction, plan_id) else {
            continue;
        };
        let Some(used_at) = plan.used_at else {
            continue;
        };
        if used_at < plan.binding.created_at
            || used_at >= plan.binding.expires_at
            || plan.binding.validate(Some(&job), None).is_err()
            || run.node_id != Some(plan.binding.decision.node_id)
            || run
                .placement
                .as_ref()
                .and_then(|placement| placement.selected_node_id)
                != run.node_id
        {
            continue;
        }

        transaction.execute(
            "UPDATE jobs SET plan_binding = ?1 WHERE job_id = ?2 AND plan_binding IS NULL",
            params![serde_json::to_string(&plan.binding)?, job_id.to_string()],
        )?;
    }
    // Old rows may remain NULL only when their historical evidence is absent
    // or ambiguous. Trigger replacement shares this migration transaction, so
    // a crash cannot expose a window where new unbound jobs can be inserted.
    // The update guard permits a replacement only after the exact immutable
    // attempt was appended; arbitrary binding mutation still fails closed.
    transaction.execute_batch(
        r#"
        CREATE TRIGGER jobs_require_plan_binding_insert
        BEFORE INSERT ON jobs
        WHEN CASE
            WHEN NEW.plan_binding IS NULL THEN 1
            WHEN json_valid(NEW.plan_binding) = 0 OR json_valid(NEW.run) = 0 THEN 1
            WHEN json_extract(NEW.plan_binding, '$.apiVersion')
                    IS NOT 'cyc.dev/placement-plan-binding/v1' THEN 1
            WHEN json_extract(NEW.plan_binding, '$.jobId') IS NOT NEW.job_id THEN 1
            WHEN json_extract(NEW.plan_binding, '$.decision.nodeId')
                    IS NOT json_extract(NEW.run, '$.nodeId') THEN 1
            ELSE 0
        END
        BEGIN
            SELECT RAISE(ABORT, 'a valid job-bound plan_binding is required for new jobs');
        END;
        CREATE TRIGGER jobs_plan_binding_immutable
        BEFORE UPDATE OF plan_binding ON jobs
        WHEN OLD.plan_binding IS NOT NEW.plan_binding AND CASE
            WHEN NEW.plan_binding IS NULL THEN 1
            WHEN json_valid(NEW.plan_binding) = 0 OR json_valid(NEW.run) = 0 THEN 1
            WHEN json_extract(NEW.plan_binding, '$.apiVersion')
                    IS NOT 'cyc.dev/placement-plan-binding/v1' THEN 1
            WHEN json_extract(NEW.plan_binding, '$.jobId') IS NOT NEW.job_id THEN 1
            WHEN json_extract(NEW.plan_binding, '$.decision.nodeId')
                    IS NOT json_extract(NEW.run, '$.nodeId') THEN 1
            WHEN NOT EXISTS (
                SELECT 1 FROM job_placement_attempts a
                WHERE a.run_id = NEW.run_id
                  AND a.plan_binding IS NEW.plan_binding
                  AND a.plan_id = json_extract(NEW.plan_binding, '$.planId')
                  AND a.node_id = json_extract(NEW.plan_binding, '$.decision.nodeId')
                  AND a.attempt = (
                    SELECT MAX(latest.attempt) FROM job_placement_attempts latest
                    WHERE latest.run_id = NEW.run_id
                  )
            ) THEN 1
            ELSE 0
        END
        BEGIN
            SELECT RAISE(ABORT, 'plan_binding replacement lacks an immutable placement attempt');
        END;
        "#,
    )?;
    transaction.commit()?;
    Ok(())
}

/// Seed the append-only placement-attempt ledger for databases created before
/// dispatch reselection existed. Invalid or unbound legacy rows stay explicit
/// rather than receiving synthesized authority.
fn migrate_job_placement_attempts(connection: &mut Connection) -> StoreResult<()> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let rows = {
        let mut statement = transaction.prepare(
            r#"
            SELECT run_id, job, plan_binding
            FROM jobs
            WHERE plan_binding IS NOT NULL
              AND NOT EXISTS (
                SELECT 1 FROM job_placement_attempts a
                WHERE a.run_id = jobs.run_id
              )
            ORDER BY created_at, run_id
            "#,
        )?;
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };
    for (run_id, job_document, binding_document) in rows {
        let Ok(run_id) = Uuid::parse_str(&run_id) else {
            continue;
        };
        let Ok(job) = serde_json::from_str::<JobSpec>(&job_document) else {
            continue;
        };
        let Ok(binding) = serde_json::from_str::<PlacementPlanBindingV1>(&binding_document) else {
            continue;
        };
        if binding.validate(Some(&job), None).is_err() {
            continue;
        }
        insert_placement_attempt_tx(&transaction, run_id, &binding, PLACEMENT_ATTEMPT_INITIAL)?;
    }
    transaction.commit()?;
    Ok(())
}

fn migrate_cleanup_reservation_schema(connection: &mut Connection) -> StoreResult<()> {
    type LegacyCleanupRow = (
        String,
        String,
        String,
        i64,
        String,
        String,
        i64,
        Option<i64>,
        Option<String>,
    );

    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let rows = {
        let mut statement = transaction.prepare(
            r#"
            SELECT c.run_id, j.job_id, j.lease_id, j.version, j.run,
                   c.document_sha256, c.created_at, l.released_at, rc.document
            FROM run_completions c
            JOIN jobs j ON j.run_id = c.run_id
            JOIN leases l ON l.id = j.lease_id
            LEFT JOIN run_cleanups rc ON rc.run_id = c.run_id
            WHERE NOT EXISTS(
                SELECT 1 FROM run_cleanup_obligations o WHERE o.run_id = c.run_id
            )
            ORDER BY c.created_at, c.run_id
            "#,
        )?;
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                    row.get(7)?,
                    row.get(8)?,
                ))
            })?
            .collect::<Result<Vec<LegacyCleanupRow>, _>>()?;
        rows
    };

    let now = Utc::now().timestamp();
    for row in rows {
        let run: Run = serde_json::from_str(&row.4)?;
        if !run.state.is_terminal() || run.id.to_string() != row.0 {
            return Err(StoreError::InvalidRunEvidence);
        }
        let legacy_cleanup = row
            .8
            .as_deref()
            .map(serde_json::from_str::<CleanupReceiptV1>)
            .transpose()?;
        let has_removed_receipt = legacy_cleanup.as_ref().is_some_and(|cleanup| {
            cleanup.outcome == cyc_protocol::JobRootCleanupOutcomeV1::Removed
        });
        let deadline = row
            .6
            .saturating_add(CLEANUP_RESERVATION_TTL_SECONDS)
            .max(now);
        let (release_reason, failure_code, failure_observed_at) = if row.7.is_some() {
            if has_removed_receipt {
                (Some(CLEANUP_RELEASE_REMOVED), None, None)
            } else {
                (
                    Some(CLEANUP_RELEASE_LEGACY),
                    Some(CLEANUP_FAILURE_LEGACY),
                    row.7,
                )
            }
        } else {
            (None, None, None)
        };
        transaction.execute(
            r#"
            INSERT INTO run_cleanup_obligations(
                run_id, job_id, lease_id, state_version, final_state,
                completion_sha256, terminal_acknowledged_at, cleanup_deadline_at,
                reservation_released_at, release_reason, cleanup_failure_code,
                failure_observed_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
            "#,
            params![
                row.0,
                row.1,
                row.2,
                row.3,
                job_state_token(run.state)?,
                row.5,
                row.6,
                deadline,
                row.7,
                release_reason,
                failure_code,
                failure_observed_at,
            ],
        )?;
        if row.7.is_none() {
            transaction.execute(
                r#"
                UPDATE leases SET phase = ?1, expires_at = ?2
                WHERE id = ?3 AND run_id = ?4 AND released_at IS NULL
                "#,
                params![LEASE_PHASE_CLEANUP_PENDING, deadline, row.2, row.0],
            )?;
        }
    }
    transaction.commit()?;
    Ok(())
}

/// Add the two-phase pairing columns atomically. Rows created by a controller
/// that predates this migration were already usable credentials, so only those
/// pre-existing rows are backfilled as activated/acknowledged. A normal startup
/// must never promote a newly staged credential merely because its column is
/// NULL after a crash.
fn migrate_pairing_ack_schema(connection: &mut Connection) -> StoreResult<()> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let had_activated = table_has_column(&transaction, "worker_credentials", "activated_at")?;
    let had_acknowledged = table_has_column(&transaction, "pairings", "acknowledged_at")?;

    if !had_activated {
        transaction
            .execute_batch("ALTER TABLE worker_credentials ADD COLUMN activated_at INTEGER")?;
    }
    if !had_acknowledged {
        transaction.execute_batch("ALTER TABLE pairings ADD COLUMN acknowledged_at INTEGER")?;
    }

    if !had_activated || !had_acknowledged {
        transaction.execute(
            r#"
            UPDATE worker_credentials SET activated_at = created_at
            WHERE activated_at IS NULL
            "#,
            [],
        )?;
        transaction.execute(
            r#"
            UPDATE pairings SET acknowledged_at = used_at
            WHERE acknowledged_at IS NULL AND used_at IS NOT NULL
              AND node_id = intended_node_id
              AND EXISTS(SELECT 1 FROM nodes n WHERE n.id = pairings.node_id)
              AND EXISTS(
                  SELECT 1 FROM worker_credentials wc
                  WHERE wc.pairing_id = pairings.id
                    AND wc.node_id = pairings.node_id
                    AND wc.activated_at IS NOT NULL
                    AND wc.revoked_at IS NULL
              )
            "#,
            [],
        )?;
    }

    // Older credential rotation revoked the superseded Ready credential but
    // left its pairing unrevoked. Repair only that exact historical shape:
    // one node-bound active credential with revocation evidence and a complete
    // consumed/acknowledged pairing. Ambiguous or partially bound rows remain
    // untouched and are rejected by authoritative status classification.
    transaction.execute(
        r#"
        UPDATE pairings
        SET revoked_at = (
            SELECT wc.revoked_at
            FROM worker_credentials wc
            WHERE wc.pairing_id = pairings.id
              AND wc.node_id = pairings.node_id
              AND wc.activated_at IS NOT NULL
              AND wc.revoked_at IS NOT NULL
        )
        WHERE revoked_at IS NULL
          AND used_at IS NOT NULL
          AND acknowledged_at IS NOT NULL
          AND node_id = intended_node_id
          AND EXISTS(SELECT 1 FROM nodes n WHERE n.id = pairings.node_id)
          AND 1 = (
              SELECT COUNT(*) FROM worker_credentials wc
              WHERE wc.pairing_id = pairings.id
          )
          AND 1 = (
              SELECT COUNT(*) FROM worker_credentials wc
              WHERE wc.pairing_id = pairings.id
                AND wc.node_id = pairings.node_id
                AND wc.activated_at IS NOT NULL
                AND wc.revoked_at IS NOT NULL
          )
        "#,
        [],
    )?;

    transaction.execute_batch(
        r#"
        CREATE UNIQUE INDEX IF NOT EXISTS worker_credentials_one_active_node_idx
        ON worker_credentials(node_id)
        WHERE activated_at IS NOT NULL AND revoked_at IS NULL;
        "#,
    )?;
    transaction.commit()?;
    Ok(())
}

/// Add durable pairing-failure evidence as one atomic schema transition. A
/// partially migrated schema or row is ambiguous and therefore rejected rather
/// than repaired by guessing which half was authoritative.
fn migrate_pairing_failure_schema(connection: &mut Connection) -> StoreResult<()> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let had_failed_at = table_has_column(&transaction, "pairings", "failed_at")?;
    let had_failure_code = table_has_column(&transaction, "pairings", "failure_code")?;

    match (had_failed_at, had_failure_code) {
        (false, false) => transaction.execute_batch(
            r#"
            ALTER TABLE pairings ADD COLUMN failed_at INTEGER;
            ALTER TABLE pairings ADD COLUMN failure_code TEXT;
            "#,
        )?,
        (true, true) => {}
        _ => return Err(StoreError::InvalidPairingFailureState),
    }

    {
        let mut statement = transaction.prepare(
            r#"
            SELECT
                failed_at, failure_code, used_at, acknowledged_at, node_id,
                EXISTS(
                    SELECT 1 FROM worker_credentials wc
                    WHERE wc.pairing_id = pairings.id
                )
            FROM pairings
            WHERE failed_at IS NOT NULL OR failure_code IS NOT NULL
            "#,
        )?;
        let rows = statement.query_map([], |row| {
            Ok((
                row.get::<_, Option<i64>>(0)?,
                row.get::<_, Option<String>>(1)?,
                row.get::<_, Option<i64>>(2)?,
                row.get::<_, Option<i64>>(3)?,
                row.get::<_, Option<String>>(4)?,
                row.get::<_, i64>(5)? != 0,
            ))
        })?;
        for row in rows {
            let (
                failed_at,
                failure_code,
                used_at,
                acknowledged_at,
                node_id,
                has_worker_credentials,
            ) = row?;
            let (failed_at, _) = pairing_failure_state(failed_at, failure_code.as_deref())?;
            if failed_at.is_some()
                && (used_at.is_some()
                    || acknowledged_at.is_some()
                    || node_id.is_some()
                    || has_worker_credentials)
            {
                return Err(StoreError::InvalidPairingFailureState);
            }
        }
    }

    transaction.commit()?;
    Ok(())
}

fn pairing_failure_state(
    failed_at: Option<i64>,
    failure_code: Option<&str>,
) -> StoreResult<(Option<DateTime<Utc>>, Option<PairingFailureCodeV1>)> {
    match (failed_at, failure_code) {
        (None, None) => Ok((None, None)),
        (Some(failed_at), Some(failure_code)) => {
            let failed_at =
                timestamp(failed_at).map_err(|_| StoreError::InvalidPairingFailureState)?;
            let failure_code = pairing_failure_code(failure_code)?;
            Ok((Some(failed_at), Some(failure_code)))
        }
        _ => Err(StoreError::InvalidPairingFailureState),
    }
}

fn pairing_failure_code(value: &str) -> StoreResult<PairingFailureCodeV1> {
    match value {
        "provisioning_failed" => Ok(PairingFailureCodeV1::ProvisioningFailed),
        "worker_install_failed" => Ok(PairingFailureCodeV1::WorkerInstallFailed),
        "worker_pairing_failed" => Ok(PairingFailureCodeV1::WorkerPairingFailed),
        "worker_health_check_failed" => Ok(PairingFailureCodeV1::WorkerHealthCheckFailed),
        _ => Err(StoreError::InvalidPairingFailureState),
    }
}

fn pairing_failure_code_name(value: PairingFailureCodeV1) -> &'static str {
    match value {
        PairingFailureCodeV1::ProvisioningFailed => "provisioning_failed",
        PairingFailureCodeV1::WorkerInstallFailed => "worker_install_failed",
        PairingFailureCodeV1::WorkerPairingFailed => "worker_pairing_failed",
        PairingFailureCodeV1::WorkerHealthCheckFailed => "worker_health_check_failed",
    }
}

#[derive(Debug, Clone, Copy)]
struct PairingCredentialState {
    total: i64,
    staged_unrevoked: i64,
    active_unrevoked: i64,
    staged_revoked: i64,
    active_revoked: i64,
}

#[allow(clippy::too_many_arguments)]
fn classify_pairing_phase(
    intended_node_id: Uuid,
    node_id: Option<Uuid>,
    expires_at: DateTime<Utc>,
    consumed: bool,
    acknowledged: bool,
    revoked: bool,
    failed: bool,
    node_exists: bool,
    credentials: PairingCredentialState,
    now: DateTime<Utc>,
) -> StoreResult<PairingPhaseV1> {
    if credentials.total < 0
        || credentials.staged_unrevoked < 0
        || credentials.active_unrevoked < 0
        || credentials.staged_revoked < 0
        || credentials.active_revoked < 0
        || credentials.staged_unrevoked
            + credentials.active_unrevoked
            + credentials.staged_revoked
            + credentials.active_revoked
            != credentials.total
    {
        return Err(StoreError::InvalidPairingFailureState);
    }

    let clean_pending =
        !consumed && !acknowledged && node_id.is_none() && credentials.total == 0 && !failed;
    let clean_failed =
        failed && !consumed && !acknowledged && node_id.is_none() && credentials.total == 0;
    let exact_node = node_id == Some(intended_node_id) && node_exists;
    let exact_consumed = !failed
        && consumed
        && !acknowledged
        && exact_node
        && credentials.total == 1
        && if revoked {
            credentials.staged_revoked == 1
        } else {
            credentials.staged_unrevoked == 1
        };
    let exact_ready = !failed
        && consumed
        && acknowledged
        && exact_node
        && credentials.total == 1
        && if revoked {
            credentials.active_revoked == 1
        } else {
            credentials.active_unrevoked == 1
        };

    if !clean_pending && !clean_failed && !exact_consumed && !exact_ready {
        return Err(StoreError::InvalidPairingFailureState);
    }
    if revoked {
        return Ok(PairingPhaseV1::Revoked);
    }
    if exact_ready {
        return Ok(PairingPhaseV1::Ready);
    }
    if exact_consumed {
        return Ok(PairingPhaseV1::Consumed);
    }
    if clean_failed {
        return Ok(PairingPhaseV1::Failed);
    }
    if expires_at <= now {
        return Ok(PairingPhaseV1::Expired);
    }
    Ok(PairingPhaseV1::Pending)
}

fn table_has_column(transaction: &Transaction<'_>, table: &str, column: &str) -> StoreResult<bool> {
    let mut statement = transaction.prepare(&format!("PRAGMA table_info({table})"))?;
    let columns = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(columns.iter().any(|existing| existing == column))
}

fn increment_meta(transaction: &Transaction<'_>, key: &str) -> StoreResult<()> {
    let changed = if key == "fleet_revision" {
        transaction.execute(
            "UPDATE controller_meta SET value = value + 1 WHERE key = ?1 AND value < ?2",
            params![key, as_i64(MAX_SAFE_JSON_INTEGER)],
        )?
    } else {
        transaction.execute(
            "UPDATE controller_meta SET value = value + 1 WHERE key = ?1",
            [key],
        )?
    };
    if changed != 1 {
        return if key == "fleet_revision" {
            Err(StoreError::InvalidFleetRevision)
        } else {
            Err(StoreError::NotFound)
        };
    }
    Ok(())
}

fn get_meta(transaction: &Transaction<'_>, key: &str) -> StoreResult<i64> {
    Ok(transaction.query_row(
        "SELECT value FROM controller_meta WHERE key = ?1",
        [key],
        |row| row.get(0),
    )?)
}

fn node_view_from_documents(
    id: String,
    config: String,
    inventory: String,
    telemetry: String,
    received_at: String,
    now: DateTime<Utc>,
) -> StoreResult<NodeMergeView> {
    let received_at = DateTime::parse_from_rfc3339(&received_at)
        .map_err(|_| StoreError::Timestamp)?
        .with_timezone(&Utc);
    NodeMergeView::merge(
        Uuid::parse_str(&id)?,
        serde_json::from_str(&config)?,
        serde_json::from_str(&inventory)?,
        serde_json::from_str(&telemetry)?,
        received_at,
        now,
        Duration::from_secs(u64::try_from(NODE_FRESHNESS_SECONDS).unwrap_or_default()),
    )
    .map_err(StoreError::from)
}

fn list_all_node_views(
    connection: &Connection,
    now: DateTime<Utc>,
) -> StoreResult<Vec<NodeMergeView>> {
    let mut statement = connection.prepare(
        r#"
        SELECT n.id, c.document, i.document, t.document, t.received_at
        FROM nodes n
        JOIN node_configs c ON c.node_id = n.id
        JOIN node_inventories i ON i.node_id = n.id
        JOIN node_telemetry t ON t.node_id = n.id
        ORDER BY t.received_at DESC
        "#,
    )?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    rows.into_iter()
        .map(|row| node_view_from_documents(row.0, row.1, row.2, row.3, row.4, now))
        .collect()
}

fn list_jobs_tx(transaction: &Transaction<'_>, limit: usize) -> StoreResult<Vec<StoredJob>> {
    let rows = {
        let mut statement = transaction.prepare(
            r#"
            SELECT job, run, version, cancel_requested, lease_id, plan_binding
            FROM jobs ORDER BY updated_at DESC LIMIT ?1
            "#,
        )?;
        let rows = statement
            .query_map([limit.min(500) as i64], job_row)?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };
    rows.into_iter().map(decode_job_row).collect()
}

fn read_fleet_snapshot_tx(
    transaction: &Transaction<'_>,
    fleet_revision: u64,
    observed_at: DateTime<Utc>,
    recent_job_limit: usize,
) -> StoreResult<FleetSnapshot> {
    let nodes = list_all_node_views(transaction, observed_at)?
        .into_iter()
        .map(|view| view.to_node().map_err(StoreError::from))
        .collect::<StoreResult<Vec<_>>>()?;
    let node_views = list_fleet_node_views_tx(transaction, observed_at)?;
    let recent_jobs = list_jobs_tx(transaction, recent_job_limit)?;
    Ok(FleetSnapshot {
        fleet_revision,
        observed_at,
        nodes,
        node_views,
        recent_jobs,
    })
}

fn read_safe_fleet_revision(transaction: &Transaction<'_>) -> StoreResult<u64> {
    u64::try_from(get_meta(transaction, "fleet_revision")?)
        .ok()
        .filter(|revision| *revision <= MAX_SAFE_JSON_INTEGER)
        .ok_or(StoreError::InvalidFleetRevision)
}

fn parse_rfc3339(value: &str) -> StoreResult<DateTime<Utc>> {
    Ok(DateTime::parse_from_rfc3339(value)
        .map_err(|_| StoreError::Timestamp)?
        .with_timezone(&Utc))
}

fn list_fleet_node_views_tx(
    transaction: &Transaction<'_>,
    now: DateTime<Utc>,
) -> StoreResult<Vec<FleetNodeView>> {
    type FleetRow = (
        String,
        String,
        String,
        i64,
        String,
        String,
        i64,
        String,
        String,
        String,
        String,
        String,
    );
    let rows = {
        let mut statement = transaction.prepare(
            r#"
            SELECT n.id,
                   c.document, c.updated_at, c.revision,
                   i.document, i.updated_at, i.revision, i.digest, i.observed_at,
                   t.document, t.received_at, t.observed_at
            FROM nodes n
            JOIN node_configs c ON c.node_id = n.id
            JOIN node_inventories i ON i.node_id = n.id
            JOIN node_telemetry t ON t.node_id = n.id
            ORDER BY t.received_at DESC, n.id
            "#,
        )?;
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                    row.get(7)?,
                    row.get(8)?,
                    row.get(9)?,
                    row.get(10)?,
                    row.get(11)?,
                ))
            })?
            .collect::<Result<Vec<FleetRow>, _>>()?;
        rows
    };
    let scheduling = fresh_available_nodes(transaction, now)?;
    let reservations = list_fleet_reservations(transaction, now.timestamp())?;
    let mut result = Vec::with_capacity(rows.len());
    for row in rows {
        let node_id = Uuid::parse_str(&row.0)?;
        let config: NodeConfig = serde_json::from_str(&row.1)?;
        let inventory: NodeInventory = serde_json::from_str(&row.4)?;
        let telemetry: NodeTelemetry = serde_json::from_str(&row.9)?;
        let received_at = parse_rfc3339(&row.10)?;
        let merged = NodeMergeView::merge(
            node_id,
            config.clone(),
            inventory.clone(),
            telemetry.clone(),
            received_at,
            now,
            Duration::from_secs(u64::try_from(NODE_FRESHNESS_SECONDS).unwrap_or_default()),
        )?;
        let node_reservations = reservations.get(&node_id).cloned().unwrap_or_default();
        let reserved_slots = node_reservations.iter().fold(0_u32, |total, reservation| {
            total.saturating_add(reservation.slots)
        });
        let capacity = effective_capacity_policy(&config)?;
        let configured = capacity.max_concurrent_jobs;
        let containment_max_safe = inventory.containment.max_safe_slots;
        let effective = configured.min(containment_max_safe);
        let effective_resources = scheduling
            .iter()
            .find(|record| record.scheduling.node.id == node_id)
            .map(|record| record.scheduling.node.resources.clone())
            .unwrap_or_else(|| {
                merged
                    .to_node()
                    .map(|node| node.resources)
                    .unwrap_or_default()
            });
        let mut availability_reasons = availability_reasons(&merged);
        if configured > containment_max_safe {
            availability_reasons.push(format!(
                "configured slots {configured} clamped by containment maxSafeSlots {containment_max_safe}"
            ));
        }
        if reserved_slots > 0 {
            availability_reasons.push(format!("{reserved_slots} execution slots reserved"));
        }
        if matches!(telemetry.power_source, cyc_protocol::PowerSource::Battery)
            && !capacity.allow_on_battery
        {
            availability_reasons.push("battery power is disallowed by policy".to_owned());
        }
        if capacity
            .max_cpu_percent
            .is_some_and(|maximum| telemetry.load.cpu_percent > maximum)
        {
            availability_reasons.push(format!(
                "CPU {}% exceeds policy maximum {}%",
                telemetry.load.cpu_percent,
                capacity.max_cpu_percent.unwrap_or_default()
            ));
        }
        if capacity
            .max_cpu_ewma_percent
            .is_some_and(|maximum| telemetry.cpu_ewma_percent > maximum)
        {
            availability_reasons.push(format!(
                "CPU EWMA {}% exceeds policy maximum {}%",
                telemetry.cpu_ewma_percent,
                capacity.max_cpu_ewma_percent.unwrap_or_default()
            ));
        }
        let memory_used_percent = if inventory.memory_mib == 0 {
            100
        } else {
            u8::try_from(
                inventory
                    .memory_mib
                    .saturating_sub(telemetry.available_memory_mib)
                    .saturating_mul(100)
                    .saturating_div(inventory.memory_mib)
                    .min(100),
            )
            .unwrap_or(100)
        };
        if capacity
            .max_memory_percent
            .is_some_and(|maximum| memory_used_percent > maximum)
        {
            availability_reasons.push(format!(
                "memory use {memory_used_percent}% exceeds policy maximum {}%",
                capacity.max_memory_percent.unwrap_or_default()
            ));
        }
        if telemetry.temperature_c.is_some()
            && capacity.max_temperature_c.is_some()
            && telemetry.temperature_c > capacity.max_temperature_c
        {
            availability_reasons.push(format!(
                "temperature {} C exceeds policy maximum {} C",
                telemetry.temperature_c.unwrap_or_default(),
                capacity.max_temperature_c.unwrap_or_default()
            ));
        }
        if reserved_slots >= effective {
            availability_reasons.push("no effective execution slots remain".to_owned());
        }
        result.push(FleetNodeView {
            node_id,
            config: FleetDocument {
                document: config,
                revision: Some(row.3),
                digest: None,
                observed_at: parse_rfc3339(&row.2)?,
                received_at: parse_rfc3339(&row.2)?,
            },
            inventory: FleetDocument {
                document: inventory,
                revision: Some(row.6),
                digest: Some(row.7),
                observed_at: parse_rfc3339(&row.8)?,
                received_at: parse_rfc3339(&row.5)?,
            },
            telemetry: FleetDocument {
                document: telemetry,
                revision: None,
                digest: None,
                observed_at: parse_rfc3339(&row.11)?,
                received_at,
            },
            availability: merged.availability,
            availability_reasons,
            effective_slots: FleetSlotView {
                configured,
                containment_max_safe,
                effective,
                reserved: reserved_slots,
                available: effective.saturating_sub(reserved_slots),
            },
            effective_resources,
            reservations: node_reservations,
        });
    }
    Ok(result)
}

fn availability_reasons(view: &NodeMergeView) -> Vec<String> {
    match view.availability {
        cyc_protocol::NodeAvailability::Available => Vec::new(),
        cyc_protocol::NodeAvailability::Degraded => {
            vec!["worker reports degraded health".to_owned()]
        }
        cyc_protocol::NodeAvailability::Draining => {
            vec!["controller or worker is draining new work".to_owned()]
        }
        cyc_protocol::NodeAvailability::Disabled => {
            vec!["node is disabled by controller configuration".to_owned()]
        }
        cyc_protocol::NodeAvailability::Offline => {
            vec!["worker reports offline".to_owned()]
        }
        cyc_protocol::NodeAvailability::Stale => vec![format!(
            "last accepted telemetry is older than {NODE_FRESHNESS_SECONDS} seconds"
        )],
    }
}

fn list_fleet_reservations(
    transaction: &Transaction<'_>,
    now: i64,
) -> StoreResult<BTreeMap<Uuid, Vec<FleetReservationView>>> {
    let rows = {
        let mut statement = transaction.prepare(
            r#"
            SELECT l.node_id, l.id, l.run_id, l.job_id, l.phase, l.slots,
                   l.cpu_cores, l.memory_mib, l.disk_mib, l.expires_at,
                   g.device_id, COALESCE(g.vram_mib, 0), COALESCE(g.exclusive, 0)
            FROM leases l
            LEFT JOIN lease_gpu_reservations g ON g.lease_id = l.id
            WHERE l.released_at IS NULL
              AND (l.expires_at > ?1 OR l.phase = ?2)
            ORDER BY l.node_id, l.created_at, l.id
            "#,
        )?;
        let rows = statement
            .query_map(params![now, LEASE_PHASE_CLEANUP_PENDING], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, i64>(5)?,
                    row.get::<_, i64>(6)?,
                    row.get::<_, i64>(7)?,
                    row.get::<_, i64>(8)?,
                    row.get::<_, i64>(9)?,
                    row.get::<_, Option<String>>(10)?,
                    row.get::<_, i64>(11)?,
                    row.get::<_, i64>(12)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };
    let mut result = BTreeMap::<Uuid, Vec<FleetReservationView>>::new();
    for row in rows {
        result
            .entry(Uuid::parse_str(&row.0)?)
            .or_default()
            .push(FleetReservationView {
                lease_id: Uuid::parse_str(&row.1)?,
                run_id: Uuid::parse_str(&row.2)?,
                job_id: Uuid::parse_str(&row.3)?,
                phase: row.4,
                slots: u32::try_from(as_u64(row.5)).unwrap_or(u32::MAX),
                cpu_cores: u32::try_from(as_u64(row.6)).unwrap_or(u32::MAX),
                memory_mib: as_u64(row.7),
                disk_mib: as_u64(row.8),
                gpu_device_id: row.10,
                gpu_vram_mib: as_u64(row.11),
                gpu_exclusive: row.12 != 0,
                expires_at: timestamp(row.9)?,
            });
    }
    Ok(result)
}

struct SchedulingNodeRecord {
    scheduling: SchedulingNode,
    revision: i64,
}

fn fresh_available_nodes(
    transaction: &Transaction<'_>,
    now: DateTime<Utc>,
) -> StoreResult<Vec<SchedulingNodeRecord>> {
    let mut statement = transaction.prepare(
        r#"
        SELECT DISTINCT
            n.id, c.document, i.document, t.document, t.received_at, n.revision
        FROM nodes n
        JOIN node_configs c ON c.node_id = n.id
        JOIN node_inventories i ON i.node_id = n.id
        JOIN node_telemetry t ON t.node_id = n.id
        JOIN worker_credentials wc ON wc.node_id = n.id
            AND wc.activated_at IS NOT NULL AND wc.revoked_at IS NULL
        JOIN pairings p ON p.id = wc.pairing_id
        WHERE p.used_at IS NOT NULL AND p.acknowledged_at IS NOT NULL
          AND p.revoked_at IS NULL
          AND p.failed_at IS NULL AND p.failure_code IS NULL
          AND p.node_id = n.id AND p.intended_node_id = n.id
          AND 1 = (
              SELECT COUNT(*) FROM worker_credentials other
              WHERE other.pairing_id = p.id
          )
        ORDER BY t.received_at DESC
        "#,
    )?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, i64>(5)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;

    let reservations = active_reservations(transaction, now.timestamp())?;
    let gpu_reservations = active_gpu_reservations(transaction, now.timestamp())?;
    let mut nodes = Vec::new();
    for (id, config, inventory, telemetry, received_at, revision) in rows {
        let view = node_view_from_documents(id, config, inventory, telemetry, received_at, now)?;
        let mut node = view.to_node()?;
        if !matches!(&node.transport, NodeTransport::Managed { .. }) {
            continue;
        }
        let capacity = effective_capacity_policy(&view.config)?;
        if let Some(limit) = capacity.allocatable_cpu_cores {
            node.resources.available_cpu_cores = node.resources.available_cpu_cores.min(limit);
        }
        if let Some(percent) = capacity.allocatable_cpu_percent {
            let limit = u64::from(node.resources.logical_cpu_cores)
                .saturating_mul(u64::from(percent))
                / 100;
            node.resources.available_cpu_cores = node
                .resources
                .available_cpu_cores
                .min(u32::try_from(limit).unwrap_or(u32::MAX));
        }
        if let Some(limit) = capacity.memory_limit_mib {
            node.resources.available_memory_mib = node.resources.available_memory_mib.min(limit);
        }
        let reserved = reservations.get(&node.id);
        if let Some(reserved) = reservations.get(&node.id) {
            node.resources.available_cpu_cores = node
                .resources
                .available_cpu_cores
                .saturating_sub(u32::try_from(reserved.cpu_cores).unwrap_or(u32::MAX));
            node.resources.available_memory_mib = node
                .resources
                .available_memory_mib
                .saturating_sub(reserved.memory_mib);
            node.resources.available_disk_mib = node
                .resources
                .available_disk_mib
                .saturating_sub(reserved.disk_mib);
            node.load.queue_depth = node
                .load
                .queue_depth
                .saturating_add(u32::try_from(reserved.count).unwrap_or(u32::MAX));
        }
        let gpu_device_ids = view
            .telemetry
            .gpus
            .iter()
            .enumerate()
            .map(|(index, telemetry)| {
                view.inventory
                    .gpus
                    .get(index)
                    .and_then(|inventory| inventory.stable_id.clone())
                    .or_else(|| telemetry.stable_id.clone())
                    .or_else(|| Some(format!("gpu-index-{index}")))
            })
            .collect::<Vec<_>>();
        let mut detailed_gpu_reservations = 0_u64;
        let mut gpu_active_reservations = vec![0_u32; node.resources.gpus.len()];
        for (index, gpu) in node.resources.gpus.iter_mut().enumerate() {
            let Some(device_id) = gpu_device_ids.get(index).and_then(Option::as_deref) else {
                continue;
            };
            if let Some(reserved_gpu) = gpu_reservations.get(&(node.id, device_id.to_owned())) {
                detailed_gpu_reservations =
                    detailed_gpu_reservations.saturating_add(u64::from(reserved_gpu.count));
                gpu_active_reservations[index] = reserved_gpu.count;
                gpu.available_vram_mib =
                    gpu.available_vram_mib.saturating_sub(reserved_gpu.vram_mib);
                if reserved_gpu.exclusive {
                    gpu.allocatable = false;
                    gpu.available_vram_mib = 0;
                }
            }
        }
        if reserved.is_some_and(|reserved| reserved.gpu_reservations > detailed_gpu_reservations) {
            // Legacy leases had no stable device binding. Conservatively make
            // every device unavailable rather than risking overlap.
            for gpu in &mut node.resources.gpus {
                gpu.allocatable = false;
                gpu.available_vram_mib = 0;
            }
        }
        let memory_used_percent = if view.inventory.memory_mib == 0 {
            100
        } else {
            let used = view
                .inventory
                .memory_mib
                .saturating_sub(view.telemetry.available_memory_mib);
            u8::try_from(
                used.saturating_mul(100)
                    .saturating_div(view.inventory.memory_mib)
                    .min(100),
            )
            .unwrap_or(100)
        };
        nodes.push(SchedulingNodeRecord {
            scheduling: SchedulingNode {
                node,
                allowed_job_kinds: capacity.allowed_job_kinds,
                allow_on_battery: capacity.allow_on_battery,
                on_battery: matches!(
                    view.telemetry.power_source,
                    cyc_protocol::PowerSource::Battery
                ),
                cpu_ewma_percent: view.telemetry.cpu_ewma_percent,
                memory_used_percent,
                temperature_c: view.telemetry.temperature_c,
                max_cpu_percent: capacity.max_cpu_percent,
                max_cpu_ewma_percent: capacity.max_cpu_ewma_percent,
                max_memory_percent: capacity.max_memory_percent,
                max_temperature_c: capacity.max_temperature_c,
                configured_max_slots: capacity.max_concurrent_jobs,
                containment_max_safe_slots: view.inventory.containment.max_safe_slots,
                active_slots: u32::try_from(reserved.map_or(0, |reserved| reserved.slots))
                    .unwrap_or(u32::MAX),
                gpu_device_ids,
                gpu_active_reservations,
            },
            revision,
        });
    }
    Ok(nodes)
}

fn active_gpu_reservations(
    transaction: &Transaction<'_>,
    now: i64,
) -> StoreResult<BTreeMap<(Uuid, String), GpuReservationTotals>> {
    let mut statement = transaction.prepare(
        r#"
        SELECT l.node_id, g.device_id, SUM(g.vram_mib), MAX(g.exclusive), COUNT(*)
        FROM lease_gpu_reservations g
        JOIN leases l ON l.id = g.lease_id
        WHERE l.released_at IS NULL
          AND (l.expires_at > ?1 OR l.phase = ?2)
        GROUP BY l.node_id, g.device_id
        "#,
    )?;
    let rows = statement
        .query_map(params![now, LEASE_PHASE_CLEANUP_PENDING], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, i64>(3)?,
                row.get::<_, i64>(4)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    rows.into_iter()
        .map(|row| {
            Ok((
                (Uuid::parse_str(&row.0)?, row.1),
                GpuReservationTotals {
                    vram_mib: as_u64(row.2),
                    exclusive: row.3 != 0,
                    count: u32::try_from(as_u64(row.4)).unwrap_or(u32::MAX),
                },
            ))
        })
        .collect()
}

fn active_reservations(
    transaction: &Transaction<'_>,
    now: i64,
) -> StoreResult<BTreeMap<Uuid, ReservationTotals>> {
    let mut statement = transaction.prepare(
        r#"
        SELECT node_id, SUM(slots), SUM(cpu_cores), SUM(memory_mib), SUM(disk_mib),
               SUM(gpu_reserved), COUNT(*)
        FROM leases
        WHERE released_at IS NULL
          AND (expires_at > ?1 OR phase = ?2)
        GROUP BY node_id
        "#,
    )?;
    let rows = statement
        .query_map(params![now, LEASE_PHASE_CLEANUP_PENDING], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, i64>(3)?,
                row.get::<_, i64>(4)?,
                row.get::<_, i64>(5)?,
                row.get::<_, i64>(6)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    rows.into_iter()
        .map(|row| {
            Ok((
                Uuid::parse_str(&row.0)?,
                ReservationTotals {
                    slots: as_u64(row.1),
                    cpu_cores: as_u64(row.2),
                    memory_mib: as_u64(row.3),
                    disk_mib: as_u64(row.4),
                    gpu_reservations: as_u64(row.5),
                    count: as_u64(row.6),
                },
            ))
        })
        .collect()
}

fn expire_leases(transaction: &Transaction<'_>, now: i64) -> StoreResult<u64> {
    let mut count = reap_expired_cleanup_reservations_tx(transaction, now)?;
    let expired = {
        let mut statement = transaction.prepare(
            r#"
            SELECT id, run_id, phase FROM leases
            WHERE released_at IS NULL AND expires_at <= ?1 AND phase != ?2
            ORDER BY expires_at, id
            "#,
        )?;
        let rows = statement
            .query_map(params![now, LEASE_PHASE_CLEANUP_PENDING], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };

    for (lease_id, run_id, phase) in expired {
        let lease_id = Uuid::parse_str(&lease_id)?;
        let run_id = Uuid::parse_str(&run_id)?;
        match get_job_by_run_id(transaction, run_id) {
            Ok(mut stored)
                if phase == LEASE_PHASE_DISPATCH && stored.run.state == JobState::Queued =>
            {
                // Dispatch never began, so no worker owns execution. Clear the
                // stale active target before the same transaction attempts a
                // fresh, auditable placement. Execution leases take the
                // terminal branch below and are never migrated.
                stored.run.node_id = None;
                stored.run.placement = None;
                update_job_cas(transaction, &mut stored)?;
            }
            Ok(mut stored) if !stored.run.state.is_terminal() => {
                // Execution and historical legacy leases are never migrated.
                // Their expiry is terminal because work may have started.
                stored
                    .run
                    .transition(JobState::Failed)
                    .map_err(|_| StoreError::InvalidTransition)?;
                stored.run.exit_code = None;
                stored.run.error =
                    Some("worker execution lease expired before completion".to_owned());
                stored
                    .run
                    .validate()
                    .map_err(|_| StoreError::InvalidRunEvidence)?;
                update_job_cas(transaction, &mut stored)?;
            }
            Ok(_) | Err(StoreError::NotFound) => {}
            Err(error) => return Err(error),
        }
        transaction.execute(
            "UPDATE worker_claims SET revoked_at = ?1 WHERE run_id = ?2 AND revoked_at IS NULL",
            params![now, run_id.to_string()],
        )?;
        release_lease(transaction, Some(lease_id), now)?;
        count = count.saturating_add(1);
    }
    redispatch_queued_jobs(transaction, now, &Scheduler::default())?;
    Ok(count)
}

fn reap_expired_cleanup_reservations_tx(
    transaction: &Transaction<'_>,
    now: i64,
) -> StoreResult<u64> {
    let run_ids = {
        let mut statement = transaction.prepare(
            r#"
            SELECT run_id FROM run_cleanup_obligations
            WHERE reservation_released_at IS NULL AND cleanup_deadline_at <= ?1
            ORDER BY cleanup_deadline_at, run_id
            "#,
        )?;
        let rows = statement
            .query_map([now], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };

    let mut reaped = 0_u64;
    for run_id in run_ids {
        let run_id = Uuid::parse_str(&run_id)?;
        let obligation = get_cleanup_obligation_tx(transaction, run_id)?
            .ok_or(StoreError::InvalidRunEvidence)?;
        let stored = get_job_by_run_id(transaction, run_id)?;
        let completion =
            get_completion_tx(transaction, run_id)?.ok_or(StoreError::InvalidRunEvidence)?;
        let lease_binding = transaction
            .query_row(
                "SELECT run_id, job_id, phase FROM leases WHERE id = ?1 AND released_at IS NULL",
                [obligation.lease_id.to_string()],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                    ))
                },
            )
            .optional()?;
        let proven_terminal = stored.run.state.is_terminal()
            && stored.job.id == obligation.job_id
            && stored.run.id == obligation.run_id
            && stored.lease_id == Some(obligation.lease_id)
            && stored.version == obligation.state_version
            && stored.run.state == obligation.final_state
            && completion.sha256 == obligation.completion_sha256
            && completion.created_at == obligation.terminal_acknowledged_at
            && lease_binding.as_ref().is_some_and(|binding| {
                binding.0 == obligation.run_id.to_string()
                    && binding.1 == obligation.job_id.to_string()
                    && binding.2 == LEASE_PHASE_CLEANUP_PENDING
            });
        if !proven_terminal {
            // Never free capacity on inference. A corrupt/mismatched binding
            // remains held for operator investigation rather than being
            // mislabeled as successful cleanup.
            transaction.execute(
                r#"
                UPDATE run_cleanup_obligations SET
                    cleanup_failure_code = COALESCE(cleanup_failure_code, ?1),
                    failure_observed_at = COALESCE(failure_observed_at, ?2)
                WHERE run_id = ?3 AND reservation_released_at IS NULL
                "#,
                params![CLEANUP_FAILURE_DEADLINE, now, run_id.to_string()],
            )?;
            continue;
        }
        let changed = transaction.execute(
            r#"
            UPDATE run_cleanup_obligations SET
                reservation_released_at = ?1,
                release_reason = ?2,
                cleanup_failure_code = ?3,
                failure_observed_at = ?1
            WHERE run_id = ?4 AND lease_id = ?5
              AND reservation_released_at IS NULL
              AND cleanup_deadline_at <= ?1
            "#,
            params![
                now,
                CLEANUP_RELEASE_DEADLINE,
                CLEANUP_FAILURE_DEADLINE,
                obligation.run_id.to_string(),
                obligation.lease_id.to_string(),
            ],
        )?;
        if changed != 1 {
            continue;
        }
        release_lease(transaction, Some(obligation.lease_id), now)?;
        reaped = reaped.saturating_add(1);
    }
    Ok(reaped)
}

fn redispatch_queued_jobs(
    transaction: &Transaction<'_>,
    now: i64,
    scheduler: &Scheduler,
) -> StoreResult<()> {
    let mut reactivated_reservation = false;
    let rows = {
        let mut statement = transaction.prepare(
            r#"
            SELECT j.job, j.run, j.version, j.cancel_requested, j.lease_id,
                   j.plan_binding
            FROM jobs j
            LEFT JOIN leases l ON l.id = j.lease_id
            WHERE j.cancel_requested = 0
              AND (
                l.id IS NULL OR l.released_at IS NOT NULL OR l.expires_at <= ?1
              )
            ORDER BY j.created_at, j.run_id
            "#,
        )?;
        let rows = statement
            .query_map([now], job_row)?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };
    for row in rows {
        let mut stored = decode_job_row(row)?;
        if stored.run.state != JobState::Queued {
            continue;
        }
        let Some(lease_id) = stored.lease_id else {
            // Truly pre-lease historical jobs retain their old behavior.
            continue;
        };
        let observed_at = timestamp(now)?;
        let nodes = fresh_available_nodes(transaction, observed_at)?;
        let contexts = nodes
            .iter()
            .map(|record| record.scheduling.clone())
            .collect::<Vec<_>>();
        let decision = match scheduler.schedule_contexts_at(&stored.job, &contexts, observed_at) {
            Ok(decision) => decision,
            Err(ScheduleError::NoEligibleNodes { explanation }) => {
                if stored.run.node_id.is_some()
                    || stored.run.placement.as_ref() != Some(&explanation)
                {
                    stored.run.node_id = None;
                    stored.run.placement = Some(explanation);
                    update_job_cas(transaction, &mut stored)?;
                }
                continue;
            }
            Err(error) => return Err(StoreError::Schedule(error)),
        };
        let node_revision = nodes
            .iter()
            .find(|record| record.scheduling.node.id == decision.node_id)
            .map(|record| record.revision)
            .ok_or(StoreError::PlanStale)?;
        let replacement_binding = new_plan_binding(
            &stored.job,
            canonical_job_digest(&stored.job)?,
            decision.clone(),
            observed_at,
            get_meta(transaction, "fleet_revision")?,
            node_revision,
            get_meta(transaction, "policy_revision")?,
        )?;
        insert_plan_tx(transaction, &replacement_binding, Some(observed_at))?;
        insert_placement_attempt_tx(
            transaction,
            stored.run.id,
            &replacement_binding,
            PLACEMENT_ATTEMPT_DISPATCH_EXPIRED,
        )?;
        let resources = stored.job.effective_resource_request();
        let gpu_request = effective_gpu_request(&stored.job);
        let gpu_reservation =
            select_gpu_reservation(&nodes, decision.node_id, gpu_request.as_ref())?;
        let changed = transaction.execute(
            r#"
            UPDATE leases SET
                node_id = ?1, cpu_cores = ?2, memory_mib = ?3, disk_mib = ?4,
                gpu_reserved = ?5, slots = ?6, phase = ?7,
                expires_at = ?8, released_at = NULL
            WHERE id = ?9 AND run_id = ?10
              AND (released_at IS NOT NULL OR expires_at <= ?11)
            "#,
            params![
                decision.node_id.to_string(),
                i64::from(resources.cpu_cores),
                as_i64(resources.memory_mib),
                as_i64(resources.disk_mib),
                i64::from(gpu_request.is_some()),
                i64::from(resources.slots),
                LEASE_PHASE_DISPATCH,
                now.saturating_add(DISPATCH_TTL_SECONDS),
                lease_id.to_string(),
                stored.run.id.to_string(),
                now,
            ],
        )?;
        if changed != 1 {
            return Err(StoreError::InvalidTransition);
        }
        transaction.execute(
            "DELETE FROM lease_gpu_reservations WHERE lease_id = ?1",
            [lease_id.to_string()],
        )?;
        if let Some((device_id, request)) = gpu_reservation {
            transaction.execute(
                r#"
                INSERT INTO lease_gpu_reservations(lease_id, device_id, vram_mib, exclusive)
                VALUES (?1, ?2, ?3, ?4)
                "#,
                params![
                    lease_id.to_string(),
                    device_id,
                    as_i64(request.vram_mib),
                    i64::from(request.exclusive),
                ],
            )?;
        }
        stored.run.node_id = Some(decision.node_id);
        stored.run.placement = Some(decision.explanation);
        stored.plan_binding = Some(replacement_binding);
        update_job_cas(transaction, &mut stored)?;
        reactivated_reservation = true;
    }
    if reactivated_reservation {
        // A released dispatch consumes capacity again as soon as its lease is
        // rearmed. Keep every reactivation in this pass under one fleet
        // revision change so cached snapshots and pre-recovery plans cannot
        // mistake the new reservation for the state they originally observed.
        increment_meta(transaction, "fleet_revision")?;
    }
    Ok(())
}

fn new_plan_binding(
    job: &JobSpec,
    job_digest: String,
    decision: PlacementDecision,
    created_at: DateTime<Utc>,
    fleet_revision: i64,
    node_revision: i64,
    policy_revision: i64,
) -> StoreResult<PlacementPlanBindingV1> {
    let binding = PlacementPlanBindingV1 {
        api_version: PLACEMENT_PLAN_BINDING_API_VERSION.to_owned(),
        plan_id: Uuid::new_v4(),
        job_id: job.id,
        job_digest,
        created_at,
        expires_at: created_at + chrono::Duration::seconds(PLAN_TTL_SECONDS),
        fleet_revision,
        node_revision,
        policy_revision,
        decision: PlacementPlanDecisionV1 {
            node_id: decision.node_id,
            score: decision.score,
            explanation: decision.explanation,
        },
    };
    binding
        .validate(Some(job), Some(created_at))
        .map_err(|_| StoreError::InvalidPlanBinding)?;
    Ok(binding)
}

fn insert_placement_attempt_tx(
    transaction: &Transaction<'_>,
    run_id: Uuid,
    binding: &PlacementPlanBindingV1,
    reason: &str,
) -> StoreResult<u64> {
    if !matches!(
        reason,
        PLACEMENT_ATTEMPT_INITIAL | PLACEMENT_ATTEMPT_DISPATCH_EXPIRED
    ) {
        return Err(StoreError::InvalidPlanBinding);
    }
    binding
        .validate(None, None)
        .map_err(|_| StoreError::InvalidPlanBinding)?;
    let stored_job_id = transaction
        .query_row(
            "SELECT job_id FROM jobs WHERE run_id = ?1",
            [run_id.to_string()],
            |row| row.get::<_, String>(0),
        )
        .optional()?
        .ok_or(StoreError::NotFound)?;
    if Uuid::parse_str(&stored_job_id)? != binding.job_id {
        return Err(StoreError::InvalidPlanBinding);
    }
    let attempt = transaction.query_row(
        r#"
        SELECT COALESCE(MAX(attempt), 0) + 1
        FROM job_placement_attempts WHERE run_id = ?1
        "#,
        [run_id.to_string()],
        |row| row.get::<_, i64>(0),
    )?;
    let attempt = u64::try_from(attempt).map_err(|_| StoreError::InvalidPlanBinding)?;
    let changed = transaction.execute(
        r#"
        INSERT INTO job_placement_attempts(
            run_id, attempt, plan_id, node_id, plan_binding, reason, created_at
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
        "#,
        params![
            run_id.to_string(),
            as_i64(attempt),
            binding.plan_id.to_string(),
            binding.decision.node_id.to_string(),
            serde_json::to_string(binding)?,
            reason,
            binding.created_at.timestamp(),
        ],
    )?;
    if changed != 1 {
        return Err(StoreError::InvalidPlanBinding);
    }
    Ok(attempt)
}

fn insert_plan_tx(
    transaction: &Transaction<'_>,
    binding: &PlacementPlanBindingV1,
    used_at: Option<DateTime<Utc>>,
) -> StoreResult<()> {
    binding
        .validate(None, None)
        .map_err(|_| StoreError::InvalidPlanBinding)?;
    transaction.execute(
        r#"
        INSERT INTO plans(
            id, job_id, decision, created_at, job_digest, expires_at,
            fleet_revision, node_revision, policy_revision, used_at
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
        "#,
        params![
            binding.plan_id.to_string(),
            binding.job_id.to_string(),
            serde_json::to_string(&binding.decision)?,
            binding.created_at.timestamp(),
            binding.job_digest,
            binding.expires_at.timestamp(),
            binding.fleet_revision,
            binding.node_revision,
            binding.policy_revision,
            used_at.map(|value| value.timestamp()),
        ],
    )?;
    Ok(())
}

fn get_plan(connection: &Connection, plan_id: Uuid) -> StoreResult<StoredPlan> {
    let row = connection
        .query_row(
            r#"
            SELECT job_id, job_digest, decision, created_at, expires_at,
                   fleet_revision, node_revision, policy_revision, used_at
            FROM plans WHERE id = ?1
            "#,
            [plan_id.to_string()],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, i64>(4)?,
                    row.get::<_, i64>(5)?,
                    row.get::<_, i64>(6)?,
                    row.get::<_, i64>(7)?,
                    row.get::<_, Option<i64>>(8)?,
                ))
            },
        )
        .optional()?
        .ok_or(StoreError::NotFound)?;
    let binding = PlacementPlanBindingV1 {
        api_version: PLACEMENT_PLAN_BINDING_API_VERSION.to_owned(),
        plan_id,
        job_id: Uuid::parse_str(&row.0)?,
        job_digest: row.1,
        decision: serde_json::from_str(&row.2)?,
        created_at: timestamp(row.3)?,
        expires_at: timestamp(row.4)?,
        fleet_revision: row.5,
        node_revision: row.6,
        policy_revision: row.7,
    };
    binding
        .validate(None, None)
        .map_err(|_| StoreError::InvalidPlanBinding)?;
    Ok(StoredPlan {
        binding,
        used_at: row.8.map(timestamp).transpose()?,
    })
}

fn get_completion_tx(
    connection: &Connection,
    run_id: Uuid,
) -> StoreResult<Option<StoredCompletion>> {
    connection
        .query_row(
            r#"
            SELECT document, document_sha256, created_at
            FROM run_completions WHERE run_id = ?1
            "#,
            [run_id.to_string()],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?,
                ))
            },
        )
        .optional()?
        .map(|(document, sha256, created_at)| {
            Ok(StoredCompletion {
                completion: serde_json::from_str(&document)?,
                sha256,
                created_at: timestamp(created_at)?,
            })
        })
        .transpose()
}

fn get_cleanup_tx(connection: &Connection, run_id: Uuid) -> StoreResult<Option<StoredCleanup>> {
    connection
        .query_row(
            r#"
            SELECT document, received_at FROM run_cleanups WHERE run_id = ?1
            "#,
            [run_id.to_string()],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
        )
        .optional()?
        .map(|(document, received_at)| {
            Ok(StoredCleanup {
                receipt: serde_json::from_str(&document)?,
                received_at: timestamp(received_at)?,
            })
        })
        .transpose()
}

fn get_cleanup_obligation_tx(
    connection: &Connection,
    run_id: Uuid,
) -> StoreResult<Option<StoredCleanupObligation>> {
    type ObligationRow = (
        String,
        String,
        i64,
        String,
        String,
        i64,
        i64,
        Option<i64>,
        Option<String>,
        Option<String>,
        Option<i64>,
    );
    connection
        .query_row(
            r#"
            SELECT job_id, lease_id, state_version, final_state,
                   completion_sha256, terminal_acknowledged_at,
                   cleanup_deadline_at, reservation_released_at,
                   release_reason, cleanup_failure_code, failure_observed_at
            FROM run_cleanup_obligations WHERE run_id = ?1
            "#,
            [run_id.to_string()],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                    row.get(7)?,
                    row.get(8)?,
                    row.get(9)?,
                    row.get(10)?,
                ))
            },
        )
        .optional()?
        .map(|row: ObligationRow| {
            let failure_observed_at = row.10.map(timestamp).transpose()?;
            let cleanup_failure = match (row.9.as_deref(), failure_observed_at) {
                (Some(code), Some(observed_at)) => Some(CleanupFailureV1 {
                    code: cleanup_failure_code(code)?,
                    observed_at,
                }),
                (None, None) => None,
                _ => return Err(StoreError::InvalidRunEvidence),
            };
            Ok(StoredCleanupObligation {
                job_id: Uuid::parse_str(&row.0)?,
                run_id,
                lease_id: Uuid::parse_str(&row.1)?,
                state_version: as_u64(row.2),
                final_state: parse_job_state_token(&row.3)?,
                completion_sha256: row.4,
                terminal_acknowledged_at: timestamp(row.5)?,
                cleanup_deadline_at: timestamp(row.6)?,
                reservation_released_at: row.7.map(timestamp).transpose()?,
                release_reason: row.8.as_deref().map(cleanup_release_reason).transpose()?,
                cleanup_failure,
            })
        })
        .transpose()
}

type JobDatabaseRow = (String, String, i64, i64, Option<String>, Option<String>);

fn job_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<JobDatabaseRow> {
    Ok((
        row.get(0)?,
        row.get(1)?,
        row.get(2)?,
        row.get(3)?,
        row.get(4)?,
        row.get(5)?,
    ))
}

fn decode_job_row(row: JobDatabaseRow) -> StoreResult<StoredJob> {
    let job: JobSpec = serde_json::from_str(&row.0)?;
    let run: Run = serde_json::from_str(&row.1)?;
    if run.job_id != job.id {
        return Err(StoreError::InvalidPlanBinding);
    }
    let plan_binding = row
        .5
        .map(|document| {
            let binding: PlacementPlanBindingV1 = serde_json::from_str(&document)?;
            binding
                .validate(Some(&job), None)
                .map_err(|_| StoreError::InvalidPlanBinding)?;
            if run.node_id.is_some() && run.node_id != Some(binding.decision.node_id) {
                return Err(StoreError::InvalidPlanBinding);
            }
            if run.node_id.is_none() && run.state != JobState::Queued {
                return Err(StoreError::InvalidPlanBinding);
            }
            Ok(binding)
        })
        .transpose()?;
    Ok(StoredJob {
        job,
        run,
        plan_binding,
        version: as_u64(row.2),
        cancel_requested: row.3 != 0,
        lease_id: row.4.map(|value| Uuid::parse_str(&value)).transpose()?,
    })
}

fn get_job_by_job_id(connection: &Connection, job_id: Uuid) -> StoreResult<StoredJob> {
    let row = connection
        .query_row(
            r#"
            SELECT job, run, version, cancel_requested, lease_id, plan_binding
            FROM jobs WHERE job_id = ?1
            "#,
            [job_id.to_string()],
            job_row,
        )
        .optional()?
        .ok_or(StoreError::NotFound)?;
    decode_job_row(row)
}

fn get_job_by_run_id(connection: &Connection, run_id: Uuid) -> StoreResult<StoredJob> {
    let row = connection
        .query_row(
            r#"
            SELECT job, run, version, cancel_requested, lease_id, plan_binding
            FROM jobs WHERE run_id = ?1
            "#,
            [run_id.to_string()],
            job_row,
        )
        .optional()?
        .ok_or(StoreError::NotFound)?;
    decode_job_row(row)
}

fn get_job_prefer_job_id(connection: &Connection, id: Uuid) -> StoreResult<StoredJob> {
    match get_job_by_job_id(connection, id) {
        Ok(stored) => Ok(stored),
        Err(StoreError::NotFound) => get_job_by_run_id(connection, id),
        Err(error) => Err(error),
    }
}

fn update_job_cas(transaction: &Transaction<'_>, stored: &mut StoredJob) -> StoreResult<()> {
    let previous_version = stored.version;
    let next_version = previous_version.saturating_add(1);
    let changed = transaction.execute(
        r#"
        UPDATE jobs SET run = ?1, cancel_requested = ?2, version = ?3,
                        updated_at = ?4, plan_binding = ?5
        WHERE run_id = ?6 AND version = ?7
        "#,
        params![
            serde_json::to_string(&stored.run)?,
            i64::from(stored.cancel_requested),
            as_i64(next_version),
            Utc::now().to_rfc3339(),
            stored
                .plan_binding
                .as_ref()
                .map(serde_json::to_string)
                .transpose()?,
            stored.run.id.to_string(),
            as_i64(previous_version),
        ],
    )?;
    if changed != 1 {
        let current = transaction
            .query_row(
                "SELECT version FROM jobs WHERE run_id = ?1",
                [stored.run.id.to_string()],
                |row| row.get::<_, i64>(0),
            )
            .optional()?
            .map(as_u64)
            .ok_or(StoreError::NotFound)?;
        return Err(StoreError::VersionConflict {
            current_version: current,
        });
    }
    stored.version = next_version;
    Ok(())
}

fn release_cleanup_reservation_tx(
    transaction: &Transaction<'_>,
    run_id: Uuid,
    lease_id: Uuid,
    now: i64,
) -> StoreResult<()> {
    let current =
        get_cleanup_obligation_tx(transaction, run_id)?.ok_or(StoreError::InvalidCleanupReceipt)?;
    if current.lease_id != lease_id {
        return Err(StoreError::InvalidCleanupReceipt);
    }
    if current.reservation_released_at.is_none() {
        let changed = transaction.execute(
            r#"
            UPDATE run_cleanup_obligations SET
                reservation_released_at = ?1, release_reason = ?2
            WHERE run_id = ?3 AND lease_id = ?4
              AND reservation_released_at IS NULL
            "#,
            params![
                now,
                CLEANUP_RELEASE_REMOVED,
                run_id.to_string(),
                lease_id.to_string(),
            ],
        )?;
        if changed != 1 {
            return Err(StoreError::InvalidCleanupReceipt);
        }
    }
    release_lease(transaction, Some(lease_id), now)?;
    Ok(())
}

fn release_lease(
    transaction: &Transaction<'_>,
    lease_id: Option<Uuid>,
    now: i64,
) -> StoreResult<bool> {
    if let Some(lease_id) = lease_id {
        let changed = transaction.execute(
            "UPDATE leases SET released_at = ?1 WHERE id = ?2 AND released_at IS NULL",
            params![now, lease_id.to_string()],
        )?;
        if changed > 0 {
            increment_meta(transaction, "fleet_revision")?;
            return Ok(true);
        }
    }
    Ok(false)
}

fn job_state_token(state: JobState) -> StoreResult<String> {
    serde_json::to_value(state)?
        .as_str()
        .map(str::to_owned)
        .ok_or(StoreError::InvalidRunEvidence)
}

fn parse_job_state_token(value: &str) -> StoreResult<JobState> {
    serde_json::from_value(serde_json::Value::String(value.to_owned())).map_err(StoreError::from)
}

fn cleanup_release_reason(value: &str) -> StoreResult<CleanupReservationReleaseReasonV1> {
    match value {
        CLEANUP_RELEASE_REMOVED => Ok(CleanupReservationReleaseReasonV1::RemovedReceipt),
        CLEANUP_RELEASE_DEADLINE => Ok(CleanupReservationReleaseReasonV1::DeadlineRecovery),
        CLEANUP_RELEASE_LEGACY => Ok(CleanupReservationReleaseReasonV1::LegacyMigration),
        _ => Err(StoreError::InvalidRunEvidence),
    }
}

fn cleanup_failure_code(value: &str) -> StoreResult<CleanupFailureCodeV1> {
    match value {
        CLEANUP_FAILURE_DEADLINE => Ok(CleanupFailureCodeV1::RemovedReceiptDeadlineExceeded),
        CLEANUP_FAILURE_LEGACY => Ok(CleanupFailureCodeV1::LegacyReleaseWithoutCleanupEvidence),
        _ => Err(StoreError::InvalidRunEvidence),
    }
}

fn timestamp(value: i64) -> StoreResult<DateTime<Utc>> {
    DateTime::from_timestamp(value, 0).ok_or(StoreError::Timestamp)
}

fn as_i64(value: u64) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}

fn as_u64(value: i64) -> u64 {
    u64::try_from(value).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use cyc_protocol::worker::{
        ArtifactMetadata, ExecutionEvidence, ExecutionSourceEvidence, NodeReportRequest,
        RunEvidence as WorkerRunEvidence, RunStreamsEvidence, StepExecutionEvidence,
        StreamEvidence, TerminationEvidence, TerminationReason, WORKER_API_VERSION,
    };
    use cyc_protocol::{
        Architecture, Capability, CredentialRef, GpuDevice, GpuRequirement, GpuVendor, JobKind,
        JobRootCleanupOutcomeV1, JobStep, NodeResources, NodeStatus, NodeTransport,
        OperatingSystem, SourceSpec, TerminalCompletionAckV1, CLEANUP_API_VERSION,
    };

    use super::*;

    fn test_directory(label: &str) -> PathBuf {
        // macOS returns a temporary path rooted at `/var`, a symlink to
        // `/private/var`. Resolve only the test fixture root so production
        // storage validation can continue rejecting symlink components.
        #[cfg(unix)]
        let root = fs::canonicalize(std::env::temp_dir())
            .expect("canonicalize the existing system temporary directory");
        #[cfg(not(unix))]
        let root = std::env::temp_dir();
        root.join(format!("cyc-store-{label}-{}", Uuid::new_v4()))
    }

    fn node() -> Node {
        let mut node = Node::new(
            "test-worker",
            NodeTransport::Managed {
                endpoint: "https://controller.example:47832".to_owned(),
                credential_ref: CredentialRef::new("controller-db:managed-worker"),
            },
            OperatingSystem::Windows,
            Architecture::X86_64,
        );
        node.status = NodeStatus::Online;
        node.resources = NodeResources {
            logical_cpu_cores: 8,
            available_cpu_cores: 8,
            memory_mib: 16_384,
            available_memory_mib: 12_288,
            disk_mib: 100_000,
            available_disk_mib: 80_000,
            gpus: Vec::new(),
        };
        node
    }

    fn job() -> JobSpec {
        JobSpec::new(
            JobKind::Build,
            SourceSpec::Git {
                repository: "https://example.invalid/repository.git".to_owned(),
                revision: "0123456789abcdef0123456789abcdef01234567".to_owned(),
            },
            vec![JobStep::new("build", "cargo build --locked")],
        )
    }

    fn snapshot_job(digest: String, size_bytes: u64) -> JobSpec {
        JobSpec::new(
            JobKind::Test,
            SourceSpec::Snapshot {
                digest,
                size_bytes: Some(size_bytes),
            },
            vec![JobStep::new("check", "echo snapshot")],
        )
    }

    struct TestPairedWorker {
        pairing_id: Uuid,
        credential: String,
    }

    fn pair_worker(store: &Store, worker: &Node) -> TestPairedWorker {
        let pairing = store.create_pairing_for(Some(worker.id)).unwrap();
        let credential = random_secret();
        let digest = secret_hash(&credential);
        let paired = store
            .consume_pairing(
                &pairing.code,
                pairing.id,
                pairing.intended_node_id,
                &digest,
                worker,
            )
            .unwrap();
        assert_eq!(paired.node_id, worker.id);
        let replay = store
            .consume_pairing(
                &pairing.code,
                pairing.id,
                pairing.intended_node_id,
                &digest,
                worker,
            )
            .unwrap();
        assert!(replay.replayed);
        store
            .acknowledge_pairing(&credential, pairing.id, worker.id, &digest)
            .unwrap();
        assert!(store.claim_job(&credential, worker).unwrap().is_none());
        TestPairedWorker {
            pairing_id: paired.pairing_id,
            credential,
        }
    }

    fn node_report(worker: &Node, boot_id: Uuid, sequence: u64) -> NodeReportRequest {
        node_report_generation(worker, 0, boot_id, sequence)
    }

    fn node_report_generation(
        worker: &Node,
        boot_generation: u64,
        boot_id: Uuid,
        sequence: u64,
    ) -> NodeReportRequest {
        let observed_at = Utc::now();
        let mut telemetry = NodeTelemetry::from_node(worker, observed_at);
        telemetry.status = NodeStatus::Online;
        telemetry.boot_generation = boot_generation;
        telemetry.boot_id = boot_id;
        telemetry.sequence = sequence;
        NodeReportRequest {
            api_version: WORKER_API_VERSION.to_owned(),
            inventory: Some(NodeInventory::from_node(worker)),
            telemetry,
        }
    }

    fn empty_stream() -> StreamEvidence {
        StreamEvidence {
            byte_count: 0,
            sha256: bytes_sha256(&[]),
            truncated: false,
            chunk_count: 0,
        }
    }

    fn complete_empty_managed_run(
        store: &Store,
        worker: &Node,
        paired: &TestPairedWorker,
    ) -> (WorkerClaim, StoredJob, TerminalCompletionAckV1) {
        complete_empty_managed_run_as(store, worker, paired, JobState::Succeeded)
    }

    fn complete_empty_managed_run_as(
        store: &Store,
        worker: &Node,
        paired: &TestPairedWorker,
        final_state: JobState,
    ) -> (WorkerClaim, StoredJob, TerminalCompletionAckV1) {
        assert!(final_state.is_terminal());
        store
            .submit_job(&job(), None, &Scheduler::default())
            .unwrap();
        let claim = store
            .claim_job(&paired.credential, worker)
            .unwrap()
            .unwrap();
        let running = store
            .worker_transition(
                &paired.credential,
                &claim.run_credential,
                claim.stored.run.id,
                claim.lease_id,
                claim.stored.version,
                JobState::Running,
            )
            .unwrap();
        let started_at = running.run.started_at.unwrap();
        let finished_at = Utc::now();
        let (exit_code, error, termination_reason, steps) = match final_state {
            JobState::Succeeded => (
                Some(0),
                None,
                TerminationReason::Exited,
                vec![StepExecutionEvidence {
                    index: 0,
                    name: "build".to_owned(),
                    shell: Shell::Powershell,
                    started_at,
                    finished_at,
                    exit_code: Some(0),
                    termination: TerminationReason::Exited,
                }],
            ),
            JobState::Failed => (
                Some(1),
                Some("fixture execution failed".to_owned()),
                TerminationReason::ExecutionFailed,
                vec![StepExecutionEvidence {
                    index: 0,
                    name: "build".to_owned(),
                    shell: Shell::Powershell,
                    started_at,
                    finished_at,
                    exit_code: Some(1),
                    termination: TerminationReason::ExecutionFailed,
                }],
            ),
            JobState::Cancelled => (None, None, TerminationReason::CancelRequested, Vec::new()),
            _ => unreachable!("terminal state asserted above"),
        };
        let completion = RunCompletion {
            run_id: running.run.id,
            lease_id: claim.lease_id,
            expected_version: running.version,
            final_state,
            evidence: WorkerRunEvidence {
                started_at: Some(started_at),
                finished_at: Some(finished_at),
                exit_code,
                error,
                artifact_ids: Vec::new(),
            },
            execution: ExecutionEvidence {
                source: ExecutionSourceEvidence {
                    kind: "git".to_owned(),
                    repository: "https://example.invalid/repository.git".to_owned(),
                    requested_revision: "0123456789abcdef0123456789abcdef01234567".to_owned(),
                    resolved_revision: "0123456789abcdef0123456789abcdef01234567".to_owned(),
                    tree: "abcdef0123456789abcdef0123456789abcdef01".to_owned(),
                    git_version: "git version 2.45.0".to_owned(),
                },
                steps,
                streams: RunStreamsEvidence {
                    stdout: empty_stream(),
                    stderr: empty_stream(),
                },
                termination: TerminationEvidence {
                    reason: termination_reason,
                    process_tree_terminated: true,
                    forced_kill: false,
                    root_exit_code: exit_code,
                    signal: None,
                    observed_at: finished_at,
                },
            },
            artifacts: Vec::new(),
        };
        let completed = store
            .worker_complete_managed(&paired.credential, &claim.run_credential, &completion)
            .unwrap();
        let stored_completion = store.get_completion(completed.run.id).unwrap();
        let terminal_ack = TerminalCompletionAckV1 {
            run_id: completed.run.id,
            lease_id: claim.lease_id,
            completion_sha256: stored_completion.sha256,
            state_version: completed.version,
            final_state: completed.run.state,
            acknowledged_at: stored_completion.created_at,
        };
        (claim, completed, terminal_ack)
    }

    fn removed_cleanup_receipt(ack: TerminalCompletionAckV1) -> CleanupReceiptV1 {
        CleanupReceiptV1 {
            api_version: CLEANUP_API_VERSION.to_owned(),
            run_id: ack.run_id,
            lease_id: ack.lease_id,
            relative_root: format!("jobs/{}", ack.run_id),
            outcome: JobRootCleanupOutcomeV1::Removed,
            job_root_deleted: true,
            observed_at: Utc::now().max(ack.acknowledged_at),
            terminal_ack: ack,
        }
    }

    #[test]
    fn canonical_digest_is_stable_and_sensitive() {
        let first = job();
        let mut same = first.clone();
        same.requirements.min_cpu_cores = Some(1);
        assert_eq!(
            canonical_job_digest(&first).unwrap(),
            canonical_job_digest(&same).unwrap()
        );
        same.steps[0].script.push_str(" --release");
        assert_ne!(
            canonical_job_digest(&first).unwrap(),
            canonical_job_digest(&same).unwrap()
        );
    }

    #[test]
    fn snapshot_objects_are_immutable_bounded_and_run_bound() {
        let store = Store::in_memory().unwrap();
        let archive = b"raw tar.zst fixture bytes";
        let digest = format!("sha256:{}", bytes_sha256(archive));
        let size = archive.len() as u64;
        let metadata = store.put_snapshot(&digest, size, archive).unwrap();
        assert_eq!(metadata.digest, digest);
        assert_eq!(metadata.size_bytes, size);
        assert_eq!(
            store.put_snapshot(&digest, size, archive).unwrap(),
            metadata
        );
        assert!(matches!(
            store.put_snapshot(&format!("sha256:{}", "f".repeat(64)), size, archive),
            Err(StoreError::DigestMismatch)
        ));
        assert!(matches!(
            store.put_snapshot(&digest, size + 1, archive),
            Err(StoreError::InvalidUpload)
        ));

        let worker = node();
        let paired = pair_worker(&store, &worker);
        store
            .submit_job(
                &snapshot_job(digest.clone(), size),
                None,
                &Scheduler::default(),
            )
            .unwrap();
        let claim = store
            .claim_job(&paired.credential, &worker)
            .unwrap()
            .unwrap();
        let download = store
            .authorize_snapshot_download(
                &paired.credential,
                &claim.run_credential,
                claim.stored.run.id,
                claim.lease_id,
                &digest,
            )
            .unwrap();
        assert_eq!(download.metadata, metadata);
        assert_eq!(fs::read(download.path).unwrap(), archive);

        let wrong_digest = format!("sha256:{}", "e".repeat(64));
        assert!(matches!(
            store.authorize_snapshot_download(
                &paired.credential,
                &claim.run_credential,
                claim.stored.run.id,
                claim.lease_id,
                &wrong_digest,
            ),
            Err(StoreError::RunUnauthorized)
        ));

        let mut other = node();
        other.id = Uuid::new_v4();
        other.name = "other-worker".to_owned();
        let other_paired = pair_worker(&store, &other);
        assert!(matches!(
            store.authorize_snapshot_download(
                &other_paired.credential,
                &claim.run_credential,
                claim.stored.run.id,
                claim.lease_id,
                &digest,
            ),
            Err(StoreError::RunUnauthorized)
        ));
    }

    #[test]
    fn snapshot_success_evidence_binds_requested_resolved_and_tree_digest() {
        let digest = format!("sha256:{}", "c".repeat(64));
        let source = SourceSpec::Snapshot {
            digest: digest.clone(),
            size_bytes: Some(42),
        };
        let mut execution = ExecutionEvidence {
            source: ExecutionSourceEvidence {
                kind: "snapshot".to_owned(),
                repository: "snapshot".to_owned(),
                requested_revision: digest.clone(),
                resolved_revision: digest.clone(),
                tree: digest.clone(),
                git_version: "not-applicable".to_owned(),
            },
            steps: Vec::new(),
            streams: RunStreamsEvidence {
                stdout: empty_stream(),
                stderr: empty_stream(),
            },
            termination: TerminationEvidence {
                reason: TerminationReason::Exited,
                process_tree_terminated: true,
                forced_kill: false,
                root_exit_code: Some(0),
                signal: None,
                observed_at: Utc::now(),
            },
        };
        validate_execution_source(&source, JobState::Succeeded, None, &execution).unwrap();
        execution.source.resolved_revision.clear();
        execution.source.tree.clear();
        assert!(matches!(
            validate_execution_source(&source, JobState::Succeeded, None, &execution),
            Err(StoreError::InvalidRunEvidence)
        ));
        execution.source.resolved_revision = digest;
        execution.source.tree = format!("sha256:{}", "d".repeat(64));
        assert!(matches!(
            validate_execution_source(&source, JobState::Failed, Some("step failed"), &execution),
            Err(StoreError::InvalidRunEvidence)
        ));
    }

    #[test]
    fn unpaired_or_revoked_nodes_are_never_placement_candidates() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        store.upsert_node(&worker).unwrap();
        assert!(matches!(
            store.create_plan(&job(), &Scheduler::default()),
            Err(StoreError::Schedule(ScheduleError::NoEligibleNodes { .. }))
        ));

        let paired = pair_worker(&store, &worker);
        assert!(store.create_plan(&job(), &Scheduler::default()).is_ok());
        store.revoke_pairing(paired.pairing_id).unwrap();
        let mut next = job();
        next.id = Uuid::new_v4();
        assert!(matches!(
            store.create_plan(&next, &Scheduler::default()),
            Err(StoreError::Schedule(ScheduleError::NoEligibleNodes { .. }))
        ));
    }

    #[test]
    fn plan_digest_revision_and_single_use_are_enforced() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let _paired = pair_worker(&store, &worker);
        let scheduler = Scheduler::default();
        let job = job();
        let plan = store.create_plan(&job, &scheduler).unwrap();
        assert_eq!(plan.binding.job_digest, canonical_job_digest(&job).unwrap());
        assert!(plan.binding.expires_at > plan.binding.created_at);

        let mut changed = job.clone();
        changed.steps[0].script.push_str(" --release");
        assert!(matches!(
            store.submit_job(&changed, Some(plan.binding.plan_id), &scheduler),
            Err(StoreError::PlanDigestMismatch)
        ));

        let mut explicit_defaults = job.clone();
        explicit_defaults.requirements.min_cpu_cores = Some(1);
        let submitted = store
            .submit_job(&explicit_defaults, Some(plan.binding.plan_id), &scheduler)
            .unwrap();
        assert_eq!(submitted.version, 0);
        assert_eq!(submitted.job.requirements.min_cpu_cores, Some(1));
        assert!(matches!(
            store.submit_job(&job, Some(plan.binding.plan_id), &scheduler),
            Err(StoreError::Conflict)
        ));
    }

    #[test]
    fn config_or_inventory_revision_invalidates_a_plan() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let mut changed = worker.clone();
        changed.capabilities.insert(Capability::new("tool.changed"));
        let _paired = pair_worker(&store, &changed);
        let scheduler = Scheduler::default();
        let job = job();
        let plan = store.create_plan(&job, &scheduler).unwrap();
        store.upsert_node(&worker).unwrap();
        assert!(matches!(
            store.submit_job(&job, Some(plan.binding.plan_id), &scheduler),
            Err(StoreError::PlanStale)
        ));
    }

    #[test]
    fn telemetry_refresh_keeps_revisions_and_same_node_plan_valid() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let paired = pair_worker(&store, &worker);
        let scheduler = Scheduler::default();
        let job = job();
        let plan = store.create_plan(&job, &scheduler).unwrap();
        let original_binding = plan.binding.clone();
        let revisions_before = store
            .connection()
            .unwrap()
            .query_row(
                r#"
                SELECT n.revision,
                       (SELECT value FROM controller_meta WHERE key = 'fleet_revision')
                FROM nodes n WHERE n.id = ?1
                "#,
                [worker.id.to_string()],
                |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
            )
            .unwrap();

        let mut refreshed = worker.clone();
        refreshed.resources.available_cpu_cores = 1;
        refreshed.resources.available_memory_mib = 4_096;
        refreshed.load.cpu_percent = 99;
        assert!(store
            .claim_job(&paired.credential, &refreshed)
            .unwrap()
            .is_none());
        let revisions_after = store
            .connection()
            .unwrap()
            .query_row(
                r#"
                SELECT n.revision,
                       (SELECT value FROM controller_meta WHERE key = 'fleet_revision')
                FROM nodes n WHERE n.id = ?1
                "#,
                [worker.id.to_string()],
                |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
            )
            .unwrap();
        assert_eq!(revisions_after, revisions_before);

        let submitted = store
            .submit_job(&job, Some(plan.binding.plan_id), &scheduler)
            .unwrap();
        assert_eq!(submitted.run.node_id, Some(worker.id));
        assert_eq!(submitted.plan_binding.as_ref(), Some(&original_binding));
        assert_ne!(
            submitted.run.placement.as_ref(),
            Some(&original_binding.decision.explanation)
        );
        assert!(submitted
            .run
            .placement
            .as_ref()
            .unwrap()
            .candidates
            .iter()
            .find(|candidate| candidate.node_id == worker.id)
            .unwrap()
            .score_components
            .iter()
            .any(|component| component.key == "cpu_headroom" && component.value == 2));
    }

    #[test]
    fn submit_rechecks_latest_telemetry_and_rejects_changed_selection() {
        let store = Store::in_memory().unwrap();
        let mut preferred = node();
        preferred.priority = 1_000;
        let preferred_pair = pair_worker(&store, &preferred);
        let mut fallback = node();
        fallback.id = Uuid::new_v4();
        fallback.name = "fallback".to_owned();
        fallback.priority = 0;
        let _fallback_pair = pair_worker(&store, &fallback);
        let scheduler = Scheduler::default();
        let job = job();
        let plan = store.create_plan(&job, &scheduler).unwrap();
        assert_eq!(plan.binding.decision.node_id, preferred.id);

        let mut saturated = preferred.clone();
        saturated.resources.available_cpu_cores = 0;
        saturated.load.cpu_percent = 100;
        assert!(store
            .claim_job(&preferred_pair.credential, &saturated)
            .unwrap()
            .is_none());
        assert!(matches!(
            store.submit_job(&job, Some(plan.binding.plan_id), &scheduler),
            Err(StoreError::PlanStale)
        ));
        let refreshed = store.create_plan(&job, &scheduler).unwrap();
        assert_eq!(refreshed.binding.decision.node_id, fallback.id);
    }

    #[test]
    fn heartbeat_freshness_does_not_invalidate_a_plan() {
        let store = Store::in_memory().unwrap();
        let mut worker = node();
        let _paired = pair_worker(&store, &worker);
        let scheduler = Scheduler::default();
        let job = job();
        let plan = store.create_plan(&job, &scheduler).unwrap();

        worker.last_seen_at = Some(Utc::now() + chrono::Duration::seconds(1));
        store.upsert_node(&worker).unwrap();
        store.touch_node(worker.id).unwrap();
        let submitted = store
            .submit_job(&job, Some(plan.binding.plan_id), &scheduler)
            .unwrap();
        assert_eq!(submitted.run.node_id, Some(worker.id));
    }

    fn persistent_bound_job(label: &str) -> (PathBuf, PathBuf, Store, StoredJob) {
        let directory = test_directory(label);
        std::fs::create_dir_all(&directory).unwrap();
        let database = directory.join("controller.db");
        let store = Store::open(&database).unwrap();
        let worker = node();
        let _paired = pair_worker(&store, &worker);
        let submitted = store
            .submit_job(&job(), None, &Scheduler::default())
            .unwrap();
        (directory, database, store, submitted)
    }

    fn expose_legacy_null_binding(store: &Store, job_id: Uuid) {
        let connection = store.connection().unwrap();
        connection
            .execute_batch("DROP TRIGGER IF EXISTS jobs_plan_binding_immutable;")
            .unwrap();
        assert_eq!(
            connection
                .execute(
                    "UPDATE jobs SET plan_binding = NULL WHERE job_id = ?1",
                    [job_id.to_string()],
                )
                .unwrap(),
            1
        );
    }

    #[test]
    fn controller_authored_binding_survives_restart_get_and_list() {
        let (directory, database, store, submitted) = persistent_bound_job("plan-binding-restart");
        let expected = submitted.plan_binding.clone().unwrap();
        assert_eq!(
            store
                .connection()
                .unwrap()
                .query_row(
                    "SELECT COUNT(*) FROM plans WHERE id = ?1 AND used_at IS NOT NULL",
                    [expected.plan_id.to_string()],
                    |row| row.get::<_, i64>(0),
                )
                .unwrap(),
            1
        );
        drop(store);

        let reopened = Store::open(&database).unwrap();
        assert_eq!(
            reopened
                .get_job_by_job_id(submitted.job.id)
                .unwrap()
                .plan_binding,
            Some(expected.clone())
        );
        assert_eq!(
            reopened.list_jobs(10).unwrap()[0].plan_binding,
            Some(expected)
        );
        drop(reopened);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn migration_backfills_only_one_validated_used_plan() {
        let (directory, database, store, submitted) =
            persistent_bound_job("plan-binding-migrate-exact");
        let expected = submitted.plan_binding.clone().unwrap();
        expose_legacy_null_binding(&store, submitted.job.id);
        drop(store);

        let reopened = Store::open(&database).unwrap();
        assert_eq!(
            reopened
                .get_job_by_job_id(submitted.job.id)
                .unwrap()
                .plan_binding,
            Some(expected)
        );
        drop(reopened);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn migration_leaves_ambiguous_or_missing_evidence_explicitly_legacy() {
        for (label, ambiguous) in [
            ("plan-binding-migrate-ambiguous", true),
            ("plan-binding-migrate-none", false),
        ] {
            let (directory, database, store, submitted) = persistent_bound_job(label);
            let binding = submitted.plan_binding.as_ref().unwrap();
            {
                let connection = store.connection().unwrap();
                if ambiguous {
                    connection
                        .execute(
                            r#"
                            INSERT INTO plans(
                                id, job_id, decision, created_at, job_digest, expires_at,
                                fleet_revision, node_revision, policy_revision, used_at
                            )
                            SELECT ?1, job_id, decision, created_at, job_digest, expires_at,
                                   fleet_revision, node_revision, policy_revision, used_at
                            FROM plans WHERE id = ?2
                            "#,
                            params![Uuid::new_v4().to_string(), binding.plan_id.to_string()],
                        )
                        .unwrap();
                } else {
                    connection
                        .execute(
                            "DELETE FROM plans WHERE job_id = ?1",
                            [submitted.job.id.to_string()],
                        )
                        .unwrap();
                }
            }
            expose_legacy_null_binding(&store, submitted.job.id);
            drop(store);

            let reopened = Store::open(&database).unwrap();
            assert_eq!(
                reopened
                    .get_job_by_job_id(submitted.job.id)
                    .unwrap()
                    .plan_binding,
                None
            );
            drop(reopened);
            std::fs::remove_dir_all(directory).unwrap();
        }
    }

    #[test]
    fn plan_use_job_and_lease_commit_or_rollback_together() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let _paired = pair_worker(&store, &worker);
        let scheduler = Scheduler::default();
        let first_job = job();
        let plan = store.create_plan(&first_job, &scheduler).unwrap();
        store
            .connection()
            .unwrap()
            .execute_batch(
                r#"
                CREATE TRIGGER abort_plan_use BEFORE UPDATE OF used_at ON plans
                WHEN NEW.used_at IS NOT NULL
                BEGIN SELECT RAISE(ABORT, 'injected plan-use crash'); END;
                "#,
            )
            .unwrap();
        assert!(matches!(
            store.submit_job(&first_job, Some(plan.binding.plan_id), &scheduler),
            Err(StoreError::Database(_))
        ));
        let connection = store.connection().unwrap();
        assert_eq!(
            connection
                .query_row("SELECT COUNT(*) FROM jobs", [], |row| row.get::<_, i64>(0))
                .unwrap(),
            0
        );
        assert_eq!(
            connection
                .query_row("SELECT COUNT(*) FROM leases", [], |row| row
                    .get::<_, i64>(0))
                .unwrap(),
            0
        );
        assert_eq!(
            connection
                .query_row(
                    "SELECT used_at FROM plans WHERE id = ?1",
                    [plan.binding.plan_id.to_string()],
                    |row| row.get::<_, Option<i64>>(0),
                )
                .unwrap(),
            None
        );
        connection
            .execute_batch(
                r#"
                DROP TRIGGER abort_plan_use;
                CREATE TRIGGER abort_job_insert BEFORE INSERT ON jobs
                BEGIN SELECT RAISE(ABORT, 'injected job crash'); END;
                "#,
            )
            .unwrap();
        let plans_before = connection
            .query_row("SELECT COUNT(*) FROM plans", [], |row| row.get::<_, i64>(0))
            .unwrap();
        drop(connection);
        let mut second_job = job();
        second_job.id = Uuid::new_v4();
        assert!(matches!(
            store.submit_job(&second_job, None, &scheduler),
            Err(StoreError::Database(_))
        ));
        let connection = store.connection().unwrap();
        assert_eq!(
            connection
                .query_row("SELECT COUNT(*) FROM plans", [], |row| row.get::<_, i64>(0))
                .unwrap(),
            plans_before
        );
        assert_eq!(
            connection
                .query_row("SELECT COUNT(*) FROM jobs", [], |row| row.get::<_, i64>(0))
                .unwrap(),
            0
        );
        assert_eq!(
            connection
                .query_row("SELECT COUNT(*) FROM leases", [], |row| row
                    .get::<_, i64>(0))
                .unwrap(),
            0
        );
    }

    #[test]
    fn immutable_binding_and_decode_reject_database_tampering() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let _paired = pair_worker(&store, &worker);
        let submitted = store
            .submit_job(&job(), None, &Scheduler::default())
            .unwrap();
        let mut tampered = submitted.plan_binding.clone().unwrap();
        tampered.decision.node_id = Uuid::new_v4();
        assert!(matches!(
            store.connection().unwrap().execute(
                "UPDATE jobs SET plan_binding = ?1 WHERE job_id = ?2",
                params![
                    serde_json::to_string(&tampered).unwrap(),
                    submitted.job.id.to_string()
                ],
            ),
            Err(rusqlite::Error::SqliteFailure(_, _))
        ));
        let connection = store.connection().unwrap();
        connection
            .execute_batch("DROP TRIGGER jobs_plan_binding_immutable;")
            .unwrap();
        connection
            .execute(
                "UPDATE jobs SET plan_binding = ?1 WHERE job_id = ?2",
                params![
                    serde_json::to_string(&tampered).unwrap(),
                    submitted.job.id.to_string()
                ],
            )
            .unwrap();
        drop(connection);
        assert!(matches!(
            store.get_job_by_job_id(submitted.job.id),
            Err(StoreError::InvalidPlanBinding)
        ));
    }

    #[test]
    fn insert_trigger_rejects_null_malformed_and_mismatched_plan_bindings() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let _paired = pair_worker(&store, &worker);
        let submitted = store
            .submit_job(&job(), None, &Scheduler::default())
            .unwrap();
        let valid_but_bound_to_existing_job =
            serde_json::to_string(submitted.plan_binding.as_ref().unwrap()).unwrap();
        let connection = store.connection().unwrap();

        for plan_binding in [
            None,
            Some("not-json"),
            Some("{}"),
            Some(valid_but_bound_to_existing_job.as_str()),
        ] {
            let inserted = connection.execute(
                r#"
                INSERT INTO jobs(
                    run_id, job_id, job, run, created_at, updated_at,
                    version, cancel_requested, lease_id, plan_binding
                )
                SELECT ?1, ?2, job, run, created_at, updated_at,
                       version, cancel_requested, NULL, ?3
                FROM jobs WHERE job_id = ?4
                "#,
                params![
                    Uuid::new_v4().to_string(),
                    Uuid::new_v4().to_string(),
                    plan_binding,
                    submitted.job.id.to_string(),
                ],
            );
            assert!(matches!(
                inserted,
                Err(rusqlite::Error::SqliteFailure(_, _))
            ));
        }
        assert_eq!(
            connection
                .query_row("SELECT COUNT(*) FROM jobs", [], |row| row.get::<_, i64>(0))
                .unwrap(),
            1
        );
    }

    #[test]
    fn fleet_snapshot_pins_revision_nodes_views_and_jobs_across_concurrent_write() {
        let directory = test_directory("fleet-snapshot");
        std::fs::create_dir_all(&directory).unwrap();
        let database = directory.join("controller.db");
        let reader = Store::open(&database).unwrap();
        let first = node();
        let _paired = pair_worker(&reader, &first);
        let writer = Store::open(&database).unwrap();

        let mut connection = reader.connection().unwrap();
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Deferred)
            .unwrap();
        // This first read establishes the WAL snapshot before another
        // controller connection commits a second node.
        let pinned_revision = read_safe_fleet_revision(&transaction).unwrap();
        let mut second = node();
        second.id = Uuid::new_v4();
        second.name = "concurrent-writer".to_owned();
        writer.upsert_node(&second).unwrap();
        writer
            .submit_job(&job(), None, &Scheduler::default())
            .unwrap();

        let observed_at = Utc::now();
        let snapshot =
            read_fleet_snapshot_tx(&transaction, pinned_revision, observed_at, 20).unwrap();
        assert_eq!(snapshot.fleet_revision, pinned_revision);
        assert_eq!(snapshot.nodes.len(), 1);
        assert_eq!(snapshot.node_views.len(), 1);
        assert_eq!(snapshot.nodes[0].id, snapshot.node_views[0].node_id);
        assert!(snapshot.recent_jobs.is_empty());
        assert!(snapshot
            .node_views
            .iter()
            .all(|view| view.config.received_at <= snapshot.observed_at
                && view.inventory.received_at <= snapshot.observed_at
                && view.telemetry.received_at <= snapshot.observed_at));
        transaction.commit().unwrap();
        drop(connection);

        let latest = reader.fleet_snapshot(20).unwrap();
        assert!(latest.fleet_revision > snapshot.fleet_revision);
        assert_eq!(latest.nodes.len(), 2);
        assert_eq!(latest.node_views.len(), 2);
        assert_eq!(latest.recent_jobs.len(), 1);
        assert!(latest.observed_at >= snapshot.observed_at);
        drop(writer);
        drop(reader);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn fleet_snapshot_rejects_non_javascript_safe_revision() {
        let store = Store::in_memory().unwrap();
        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE controller_meta SET value = ?1 WHERE key = 'fleet_revision'",
                [as_i64(MAX_SAFE_JSON_INTEGER.saturating_add(1))],
            )
            .unwrap();
        assert!(matches!(
            store.fleet_snapshot(20),
            Err(StoreError::InvalidFleetRevision)
        ));
    }

    #[test]
    fn gpu_lease_prevents_concurrent_oversell() {
        let store = Store::in_memory().unwrap();
        let mut worker = node();
        worker.resources.gpus.push(GpuDevice {
            vendor: GpuVendor::Nvidia,
            model: "test gpu".to_owned(),
            total_vram_mib: 8_192,
            available_vram_mib: 8_192,
            allocatable: true,
        });
        let _paired = pair_worker(&store, &worker);
        let scheduler = Scheduler::default();
        let mut first = job();
        first.kind = JobKind::Gpu;
        first.requirements.gpu = Some(GpuRequirement {
            vendor: Some(GpuVendor::Nvidia),
            min_vram_mib: Some(4_096),
            exclusive: true,
        });
        store.submit_job(&first, None, &scheduler).unwrap();
        assert_eq!(store.active_lease_count(worker.id).unwrap(), 1);

        let mut second = first.clone();
        second.id = Uuid::new_v4();
        assert!(matches!(
            store.submit_job(&second, None, &scheduler),
            Err(StoreError::Schedule(ScheduleError::NoEligibleNodes { .. }))
        ));
    }

    #[test]
    fn run_updates_use_cas_and_running_cancel_is_a_request() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let _paired = pair_worker(&store, &worker);
        let scheduler = Scheduler::default();
        let submitted = store.submit_job(&job(), None, &scheduler).unwrap();
        let preparing = store
            .transition_run(submitted.run.id, 0, JobState::Preparing)
            .unwrap();
        let running = store
            .transition_run(preparing.run.id, preparing.version, JobState::Running)
            .unwrap();
        assert!(matches!(
            store.transition_run(running.run.id, 0, JobState::Failed),
            Err(StoreError::VersionConflict { .. })
        ));
        let cancelling = store
            .cancel_job(running.run.id, Some(running.version))
            .unwrap();
        assert_eq!(cancelling.run.state, JobState::Running);
        assert!(cancelling.cancel_requested);
        assert_eq!(store.active_lease_count(worker.id).unwrap(), 1);

        assert!(matches!(
            store.transition_run(cancelling.run.id, cancelling.version, JobState::Verifying),
            Err(StoreError::CancellationPending)
        ));
        assert!(matches!(
            store.transition_run_with_evidence(
                cancelling.run.id,
                cancelling.version,
                JobState::Succeeded,
                RunEvidence {
                    exit_code: Some(0),
                    ..RunEvidence::default()
                },
            ),
            Err(StoreError::CancellationPending)
        ));
        let unchanged = store.get_job_by_run_id(cancelling.run.id).unwrap();
        assert_eq!(unchanged.version, cancelling.version);
        assert!(unchanged.cancel_requested);

        let failed = store
            .transition_run_with_evidence(
                cancelling.run.id,
                cancelling.version,
                JobState::Failed,
                RunEvidence {
                    error: Some("worker acknowledged cancellation".to_owned()),
                    ..RunEvidence::default()
                },
            )
            .unwrap();
        assert_eq!(failed.run.state, JobState::Failed);
        assert!(failed.cancel_requested);
        assert_eq!(store.active_lease_count(worker.id).unwrap(), 0);
    }

    #[test]
    fn terminal_states_require_valid_worker_evidence() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let _paired = pair_worker(&store, &worker);
        let submitted = store
            .submit_job(&job(), None, &Scheduler::default())
            .unwrap();
        let preparing = store
            .transition_run(submitted.run.id, submitted.version, JobState::Preparing)
            .unwrap();
        let running = store
            .transition_run(preparing.run.id, preparing.version, JobState::Running)
            .unwrap();

        assert!(matches!(
            store.transition_run(running.run.id, running.version, JobState::Succeeded),
            Err(StoreError::InvalidRunEvidence)
        ));
        let unchanged = store.get_job_by_run_id(running.run.id).unwrap();
        assert_eq!(unchanged.version, running.version);
        assert_eq!(store.active_lease_count(worker.id).unwrap(), 1);

        let succeeded = store
            .transition_run_with_evidence(
                running.run.id,
                running.version,
                JobState::Succeeded,
                RunEvidence {
                    exit_code: Some(0),
                    artifact_ids: Some(vec![Uuid::new_v4()]),
                    ..RunEvidence::default()
                },
            )
            .unwrap();
        assert_eq!(succeeded.run.state, JobState::Succeeded);
        assert_eq!(succeeded.run.exit_code, Some(0));
        assert!(succeeded.run.validate().is_ok());
        assert_eq!(store.active_lease_count(worker.id).unwrap(), 0);
    }

    #[test]
    fn preparing_cancel_waits_for_worker_acknowledgement() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let _paired = pair_worker(&store, &worker);
        let submitted = store
            .submit_job(&job(), None, &Scheduler::default())
            .unwrap();
        let preparing = store
            .transition_run(submitted.run.id, submitted.version, JobState::Preparing)
            .unwrap();
        let cancelling = store
            .cancel_job(preparing.job.id, Some(preparing.version))
            .unwrap();
        assert_eq!(cancelling.run.state, JobState::Preparing);
        assert!(cancelling.cancel_requested);
        assert_eq!(store.active_lease_count(worker.id).unwrap(), 1);
    }

    #[test]
    fn queued_cancel_releases_lease_and_increments_version() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let _paired = pair_worker(&store, &worker);
        let submitted = store
            .submit_job(&job(), None, &Scheduler::default())
            .unwrap();
        let cancelled = store
            .cancel_job(submitted.run.id, Some(submitted.version))
            .unwrap();
        assert_eq!(cancelled.run.state, JobState::Cancelled);
        assert_eq!(cancelled.version, 1);
        assert_eq!(store.active_lease_count(worker.id).unwrap(), 0);
    }

    #[test]
    fn lease_renewal_does_not_change_job_version() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let paired = pair_worker(&store, &worker);
        store
            .submit_job(&job(), None, &Scheduler::default())
            .unwrap();
        let claim = store
            .claim_job(&paired.credential, &worker)
            .unwrap()
            .unwrap();
        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE leases SET expires_at = ?1 WHERE id = ?2",
                params![
                    Utc::now().timestamp().saturating_add(60),
                    claim.lease_id.to_string()
                ],
            )
            .unwrap();
        let renewed = store.renew_lease(claim.stored.run.id).unwrap();
        assert!(renewed.expires_at > Utc::now() + chrono::Duration::seconds(60));
        assert_eq!(
            store
                .get_job_by_run_id(claim.stored.run.id)
                .unwrap()
                .version,
            claim.stored.version
        );
    }

    #[test]
    fn expired_dispatch_requeues_and_reselects_without_failing_the_run() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let _paired = pair_worker(&store, &worker);
        let submitted = store
            .submit_job(&job(), None, &Scheduler::default())
            .unwrap();
        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE leases SET expires_at = ?1 WHERE id = ?2",
                params![
                    Utc::now().timestamp().saturating_sub(1),
                    submitted.lease_id.unwrap().to_string()
                ],
            )
            .unwrap();

        assert_eq!(store.reap_expired_leases().unwrap(), 1);
        let redispatched = store.get_job_by_run_id(submitted.run.id).unwrap();
        assert_eq!(redispatched.run.state, JobState::Queued);
        assert_eq!(redispatched.run.node_id, Some(worker.id));
        assert_eq!(redispatched.lease_id, submitted.lease_id);
        assert!(redispatched.version >= submitted.version + 2);
        let (phase, expires_at) = store
            .connection()
            .unwrap()
            .query_row(
                "SELECT phase, expires_at FROM leases WHERE id = ?1",
                [submitted.lease_id.unwrap().to_string()],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
            )
            .unwrap();
        assert_eq!(phase, LEASE_PHASE_DISPATCH);
        assert!(expires_at > Utc::now().timestamp());
        assert_eq!(store.active_lease_count(worker.id).unwrap(), 1);
    }

    #[test]
    fn expired_unclaimed_dispatch_reselects_available_node_and_preserves_attempt_history() {
        let store = Store::in_memory().unwrap();
        let mut selected = node();
        selected.priority = 1_000;
        let _selected_pair = pair_worker(&store, &selected);
        let mut fallback = node();
        fallback.id = Uuid::new_v4();
        fallback.name = "fallback".to_owned();
        fallback.priority = 0;
        let _fallback_pair = pair_worker(&store, &fallback);
        let submitted = store
            .submit_job(&job(), None, &Scheduler::default())
            .unwrap();
        let original_binding = submitted.plan_binding.clone().unwrap();
        assert_eq!(original_binding.decision.node_id, selected.id);

        selected.status = cyc_protocol::NodeStatus::Offline;
        store.upsert_node(&selected).unwrap();
        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE leases SET expires_at = ?1 WHERE id = ?2",
                params![
                    Utc::now().timestamp().saturating_sub(1),
                    submitted.lease_id.unwrap().to_string()
                ],
            )
            .unwrap();

        assert_eq!(store.reap_expired_leases().unwrap(), 1);
        let queued = store.get_job_by_run_id(submitted.run.id).unwrap();
        assert_eq!(queued.run.state, JobState::Queued);
        assert_eq!(queued.run.node_id, Some(fallback.id));
        let replacement_binding = queued.plan_binding.unwrap();
        assert_eq!(replacement_binding.decision.node_id, fallback.id);
        assert_ne!(replacement_binding.plan_id, original_binding.plan_id);
        assert_eq!(store.active_lease_count(selected.id).unwrap(), 0);
        assert_eq!(store.active_lease_count(fallback.id).unwrap(), 1);
        let connection = store.connection().unwrap();
        let mut statement = connection
            .prepare(
                r#"
                SELECT attempt, plan_id, node_id, reason
                FROM job_placement_attempts WHERE run_id = ?1 ORDER BY attempt
                "#,
            )
            .unwrap();
        let attempts = statement
            .query_map([submitted.run.id.to_string()], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                ))
            })
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert_eq!(attempts.len(), 2);
        assert_eq!(attempts[0].0, 1);
        assert_eq!(attempts[0].1, original_binding.plan_id.to_string());
        assert_eq!(attempts[0].2, selected.id.to_string());
        assert_eq!(attempts[0].3, PLACEMENT_ATTEMPT_INITIAL);
        assert_eq!(attempts[1].0, 2);
        assert_eq!(attempts[1].1, replacement_binding.plan_id.to_string());
        assert_eq!(attempts[1].2, fallback.id.to_string());
        assert_eq!(attempts[1].3, PLACEMENT_ATTEMPT_DISPATCH_EXPIRED);
    }

    #[test]
    fn expired_unclaimed_dispatch_uses_current_scores_instead_of_original_binding() {
        let store = Store::in_memory().unwrap();
        let mut selected = node();
        selected.priority = 1_000;
        let _selected_pair = pair_worker(&store, &selected);
        let mut higher_later = node();
        higher_later.id = Uuid::new_v4();
        higher_later.name = "higher-later".to_owned();
        higher_later.priority = 0;
        let _higher_pair = pair_worker(&store, &higher_later);
        let submitted = store
            .submit_job(&job(), None, &Scheduler::default())
            .unwrap();
        let original_binding = submitted.plan_binding.clone().unwrap();
        assert_eq!(original_binding.decision.node_id, selected.id);

        higher_later.priority = 2_000;
        store.upsert_node(&higher_later).unwrap();
        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE leases SET expires_at = ?1 WHERE id = ?2",
                params![
                    Utc::now().timestamp().saturating_sub(1),
                    submitted.lease_id.unwrap().to_string()
                ],
            )
            .unwrap();

        assert_eq!(store.reap_expired_leases().unwrap(), 1);
        let rearmed = store.get_job_by_run_id(submitted.run.id).unwrap();
        assert_eq!(rearmed.run.node_id, Some(higher_later.id));
        assert_eq!(
            rearmed.plan_binding.as_ref().unwrap().decision.node_id,
            higher_later.id
        );
        assert_ne!(
            rearmed.plan_binding.as_ref().unwrap().plan_id,
            original_binding.plan_id
        );
        assert_eq!(store.active_lease_count(selected.id).unwrap(), 0);
        assert_eq!(store.active_lease_count(higher_later.id).unwrap(), 1);
    }

    #[test]
    fn dispatch_reselection_advances_fleet_revision_and_stales_old_plan() {
        let store = Store::in_memory().unwrap();
        let mut selected = node();
        selected.priority = 1_000;
        let _selected_pair = pair_worker(&store, &selected);
        let mut fallback = node();
        fallback.id = Uuid::new_v4();
        fallback.name = "fallback".to_owned();
        fallback.priority = 0;
        let _fallback_pair = pair_worker(&store, &fallback);

        let submitted = store
            .submit_job(&job(), None, &Scheduler::default())
            .unwrap();
        assert_eq!(submitted.run.node_id, Some(selected.id));
        selected.status = cyc_protocol::NodeStatus::Offline;
        store.upsert_node(&selected).unwrap();

        // Pin an unrelated manual plan immediately before the expired
        // dispatch is moved. The reservation release/reselection must advance
        // fleet authority and invalidate this pre-recovery view.
        let mut waiting_job = job();
        waiting_job.placement_policy = cyc_protocol::PlacementPolicy::Manual;
        waiting_job.preferred_node_id = Some(fallback.id);
        let waiting_plan = store
            .create_plan(&waiting_job, &Scheduler::default())
            .unwrap();
        assert_eq!(waiting_plan.binding.decision.node_id, fallback.id);
        let revision_before = store.fleet_snapshot(20).unwrap().fleet_revision;
        assert_eq!(waiting_plan.binding.fleet_revision, as_i64(revision_before));

        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE leases SET expires_at = ?1 WHERE id = ?2",
                params![
                    Utc::now().timestamp().saturating_sub(1),
                    submitted.lease_id.unwrap().to_string()
                ],
            )
            .unwrap();
        assert_eq!(store.reap_expired_leases().unwrap(), 1);

        let revision_after = store.fleet_snapshot(20).unwrap().fleet_revision;
        assert!(revision_after > revision_before);
        assert_eq!(store.active_lease_count(selected.id).unwrap(), 0);
        assert_eq!(store.active_lease_count(fallback.id).unwrap(), 1);
        let rearmed = store.get_job_by_run_id(submitted.run.id).unwrap();
        assert_eq!(rearmed.run.node_id, Some(fallback.id));
        assert_ne!(rearmed.plan_binding, submitted.plan_binding);
        assert!(matches!(
            store.submit_job(
                &waiting_job,
                Some(waiting_plan.binding.plan_id),
                &Scheduler::default()
            ),
            Err(StoreError::PlanStale)
        ));
    }

    #[test]
    fn worker_claim_requires_the_binding_selected_node() {
        let store = Store::in_memory().unwrap();
        let mut selected = node();
        selected.priority = 1_000;
        let _selected_pair = pair_worker(&store, &selected);
        let mut other = node();
        other.id = Uuid::new_v4();
        other.name = "other".to_owned();
        other.priority = 0;
        let other_pair = pair_worker(&store, &other);
        let submitted = store
            .submit_job(&job(), None, &Scheduler::default())
            .unwrap();
        assert_eq!(
            submitted.plan_binding.as_ref().unwrap().decision.node_id,
            selected.id
        );
        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE leases SET node_id = ?1 WHERE id = ?2",
                params![
                    other.id.to_string(),
                    submitted.lease_id.unwrap().to_string()
                ],
            )
            .unwrap();
        assert!(matches!(
            store.claim_job(&other_pair.credential, &other),
            Err(StoreError::InvalidPlanBinding)
        ));
    }

    #[test]
    fn claim_cas_promotes_same_dispatch_lease_to_execution_ttl() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let paired = pair_worker(&store, &worker);
        let submitted = store
            .submit_job(&job(), None, &Scheduler::default())
            .unwrap();
        let lease_id = submitted.lease_id.unwrap();
        let (dispatch_phase, dispatch_expiry) = store
            .connection()
            .unwrap()
            .query_row(
                "SELECT phase, expires_at FROM leases WHERE id = ?1",
                [lease_id.to_string()],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
            )
            .unwrap();
        assert_eq!(dispatch_phase, LEASE_PHASE_DISPATCH);
        assert!(dispatch_expiry <= Utc::now().timestamp() + DISPATCH_TTL_SECONDS);

        let claim = store
            .claim_job(&paired.credential, &worker)
            .unwrap()
            .unwrap();
        assert_eq!(claim.lease_id, lease_id);
        let (execution_phase, execution_expiry) = store
            .connection()
            .unwrap()
            .query_row(
                "SELECT phase, expires_at FROM leases WHERE id = ?1",
                [lease_id.to_string()],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
            )
            .unwrap();
        assert_eq!(execution_phase, LEASE_PHASE_EXECUTION);
        assert!(execution_expiry > dispatch_expiry);
        assert!(execution_expiry <= Utc::now().timestamp() + CLAIM_TTL_SECONDS);
    }

    #[test]
    fn job_ids_must_not_collide_with_existing_run_ids() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let _paired = pair_worker(&store, &worker);
        let submitted = store
            .submit_job(&job(), None, &Scheduler::default())
            .unwrap();
        assert_eq!(
            store.get_job_by_job_id(submitted.job.id).unwrap().run.id,
            submitted.run.id
        );
        assert_eq!(
            store.get_job_by_run_id(submitted.run.id).unwrap().job.id,
            submitted.job.id
        );

        let mut colliding = job();
        colliding.id = submitted.run.id;
        assert!(matches!(
            store.submit_job(&colliding, None, &Scheduler::default()),
            Err(StoreError::Conflict)
        ));
    }

    #[test]
    fn file_databases_use_wal() {
        let directory = test_directory("wal");
        std::fs::create_dir_all(&directory).unwrap();
        let database = directory.join("controller.db");
        let store = Store::open(&database).unwrap();
        assert_eq!(store.journal_mode().unwrap().to_ascii_lowercase(), "wal");
        crate::auth::preflight_database_layout(&database).unwrap();
        drop(store);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn file_database_open_rejects_prepositioned_weak_state() {
        let directory = test_directory("weak-state");
        std::fs::create_dir_all(&directory).unwrap();
        let database = directory.join("controller.db");
        std::fs::write(&database, b"known database bytes").unwrap();

        assert!(matches!(
            Store::open(&database),
            Err(StoreError::StorageSecurity(_))
        ));
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn pairing_hashes_secrets_and_credentials_are_node_isolated() {
        let store = Store::in_memory().unwrap();
        let first = node();
        let mut second = node();
        second.id = Uuid::new_v4();
        second.name = "second-worker".to_owned();
        let first_pair = pair_worker(&store, &first);
        let second_pair = pair_worker(&store, &second);
        assert_eq!(
            store.authenticate_worker(&first_pair.credential).unwrap(),
            first.id
        );
        assert_eq!(
            store.authenticate_worker(&second_pair.credential).unwrap(),
            second.id
        );

        let database_text = store
            .connection()
            .unwrap()
            .query_row(
                "SELECT group_concat(credential_hash, ',') FROM worker_credentials",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap();
        assert!(!database_text.contains(&first_pair.credential));
        assert!(!database_text.contains(&second_pair.credential));
        store.revoke_pairing(first_pair.pairing_id).unwrap();
        assert!(matches!(
            store.authenticate_worker(&first_pair.credential),
            Err(StoreError::WorkerUnauthorized)
        ));
        assert_eq!(
            store.authenticate_worker(&second_pair.credential).unwrap(),
            second.id
        );
    }

    #[test]
    fn enrollment_probe_is_stale_until_the_daemon_claims() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let pairing = store.create_pairing_for(Some(worker.id)).unwrap();
        let credential = random_secret();
        let digest = secret_hash(&credential);
        store
            .consume_pairing(
                &pairing.code,
                pairing.id,
                pairing.intended_node_id,
                &digest,
                &worker,
            )
            .unwrap();
        store
            .acknowledge_pairing(&credential, pairing.id, worker.id, &digest)
            .unwrap();

        let paired_view = store.list_node_views().unwrap().remove(0);
        assert_eq!(paired_view.received_at.timestamp(), 0);
        assert_eq!(
            paired_view.telemetry.status,
            cyc_protocol::NodeStatus::Offline
        );
        assert_eq!(
            paired_view.availability,
            cyc_protocol::NodeAvailability::Stale
        );

        assert!(store.claim_job(&credential, &worker).unwrap().is_none());
        let daemon_view = store.list_node_views().unwrap().remove(0);
        assert!(daemon_view.received_at > Utc::now() - chrono::Duration::seconds(5));
        assert_eq!(
            daemon_view.telemetry.status,
            cyc_protocol::NodeStatus::Online
        );
        assert_eq!(
            daemon_view.availability,
            cyc_protocol::NodeAvailability::Available
        );
    }

    #[test]
    fn node_report_is_identity_bound_and_monotonic_across_boots() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let paired = pair_worker(&store, &worker);
        let first_boot = Uuid::new_v4();
        let first = node_report(&worker, first_boot, 1);
        let accepted = store
            .record_node_report(&paired.credential, &first)
            .unwrap();
        assert!(accepted.accepted);
        assert_eq!(accepted.node_id, worker.id);
        let first_received_at = accepted.received_at;
        let first_digest = accepted.inventory_digest.clone();
        let first_revision = accepted.inventory_revision;
        let first_inventory_times = store
            .connection()
            .unwrap()
            .query_row(
                "SELECT updated_at, observed_at FROM node_inventories WHERE node_id = ?1",
                [worker.id.to_string()],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .unwrap();

        let mut replay = first.clone();
        replay.telemetry.load.cpu_percent = 99;
        replay.telemetry.observed_at += chrono::Duration::seconds(30);
        let replayed = store
            .record_node_report(&paired.credential, &replay)
            .unwrap();
        assert!(!replayed.accepted);
        assert_eq!(replayed.received_at, first_received_at);
        let persisted = store.list_node_views().unwrap().remove(0);
        assert_ne!(persisted.telemetry.load.cpu_percent, 99);
        assert_eq!(persisted.received_at, first_received_at);

        let mut second = first.clone();
        second.inventory = None;
        second.telemetry.sequence = 2;
        second.telemetry.observed_at += chrono::Duration::seconds(1);
        let second = store
            .record_node_report(&paired.credential, &second)
            .unwrap();
        assert!(second.accepted);
        assert_eq!(second.inventory_revision, first_revision);
        assert_eq!(second.inventory_digest, first_digest);
        let second_inventory_times = store
            .connection()
            .unwrap()
            .query_row(
                "SELECT updated_at, observed_at FROM node_inventories WHERE node_id = ?1",
                [worker.id.to_string()],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .unwrap();
        assert_eq!(second_inventory_times, first_inventory_times);

        let mut changed_inventory = node_report(&worker, first_boot, 3);
        changed_inventory.inventory.as_mut().unwrap().cpu_model = "new model".to_owned();
        let changed = store
            .record_node_report(&paired.credential, &changed_inventory)
            .unwrap();
        assert!(changed.accepted);
        assert_eq!(changed.inventory_revision, first_revision + 1);
        assert_ne!(changed.inventory_digest, first_digest);

        let second_boot = Uuid::new_v4();
        let rebooted = node_report(&worker, second_boot, 1);
        let rebooted = store
            .record_node_report(&paired.credential, &rebooted)
            .unwrap();
        assert!(rebooted.accepted);
        assert_eq!(rebooted.telemetry_boot_id, second_boot);
        assert_eq!(rebooted.telemetry_sequence, 1);

        let mut retired_boot = node_report(&worker, first_boot, 4);
        retired_boot.telemetry.load.cpu_percent = 99;
        let retired_boot = store
            .record_node_report(&paired.credential, &retired_boot)
            .unwrap();
        assert!(!retired_boot.accepted);
        assert_eq!(retired_boot.telemetry_boot_id, second_boot);
        assert_eq!(retired_boot.telemetry_sequence, 1);
        assert_eq!(retired_boot.received_at, rebooted.received_at);
        assert_ne!(
            store
                .list_node_views()
                .unwrap()
                .remove(0)
                .telemetry
                .load
                .cpu_percent,
            99
        );
    }

    #[test]
    fn retired_node_report_boots_remain_rejected_after_restart() {
        let directory = test_directory("retired-report-boot");
        std::fs::create_dir_all(&directory).unwrap();
        let database = directory.join("controller.db");
        let store = Store::open(&database).unwrap();
        let worker = node();
        let paired = pair_worker(&store, &worker);
        let first_boot = Uuid::new_v4();
        let second_boot = Uuid::new_v4();
        store
            .record_node_report(&paired.credential, &node_report(&worker, first_boot, 1))
            .unwrap();
        let current = store
            .record_node_report(&paired.credential, &node_report(&worker, second_boot, 1))
            .unwrap();
        drop(store);

        let reopened = Store::open(&database).unwrap();
        let mut late = node_report(&worker, first_boot, 2);
        late.telemetry.load.cpu_percent = 99;
        let rejected = reopened
            .record_node_report(&paired.credential, &late)
            .unwrap();
        assert!(!rejected.accepted);
        assert_eq!(rejected.telemetry_boot_id, second_boot);
        assert_eq!(rejected.telemetry_sequence, 1);
        assert_eq!(rejected.received_at, current.received_at);
        assert_ne!(
            reopened
                .list_node_views()
                .unwrap()
                .remove(0)
                .telemetry
                .load
                .cpu_percent,
            99
        );
        drop(reopened);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn persisted_boot_generation_rejects_delayed_unseen_and_same_generation_boots() {
        let directory = test_directory("ordered-report-generation");
        std::fs::create_dir_all(&directory).unwrap();
        let database = directory.join("controller.db");
        let store = Store::open(&database).unwrap();
        let worker = node();
        let paired = pair_worker(&store, &worker);
        let first_boot = Uuid::new_v4();
        let second_boot = Uuid::new_v4();
        assert!(
            store
                .record_node_report(
                    &paired.credential,
                    &node_report_generation(&worker, 41, first_boot, 1),
                )
                .unwrap()
                .accepted
        );
        let current = store
            .record_node_report(
                &paired.credential,
                &node_report_generation(&worker, 42, second_boot, 1),
            )
            .unwrap();
        assert!(current.accepted);
        assert_eq!(current.telemetry_boot_generation, 42);
        drop(store);

        let reopened = Store::open(&database).unwrap();
        // This boot id was never observed. Generation ordering, rather than a
        // retired-UUID lookup, is what rejects delayed daemon A after daemon B.
        let delayed_unseen = reopened
            .record_node_report(
                &paired.credential,
                &node_report_generation(&worker, 41, Uuid::new_v4(), 99),
            )
            .unwrap();
        assert!(!delayed_unseen.accepted);
        assert_eq!(delayed_unseen.telemetry_boot_generation, 42);
        assert_eq!(delayed_unseen.telemetry_boot_id, second_boot);

        let same_generation_other_boot = reopened
            .record_node_report(
                &paired.credential,
                &node_report_generation(&worker, 42, Uuid::new_v4(), 2),
            )
            .unwrap();
        assert!(!same_generation_other_boot.accepted);
        let same_sequence = reopened
            .record_node_report(
                &paired.credential,
                &node_report_generation(&worker, 42, second_boot, 1),
            )
            .unwrap();
        assert!(!same_sequence.accepted);
        let legacy_after_modern = reopened
            .record_node_report(
                &paired.credential,
                &node_report(&worker, Uuid::new_v4(), 100),
            )
            .unwrap();
        assert!(!legacy_after_modern.accepted);

        let third_boot = Uuid::new_v4();
        let advanced = reopened
            .record_node_report(
                &paired.credential,
                &node_report_generation(&worker, 43, third_boot, 1),
            )
            .unwrap();
        assert!(advanced.accepted);
        assert_eq!(advanced.telemetry_boot_generation, 43);
        assert_eq!(advanced.telemetry_boot_id, third_boot);
        let stored_generation: i64 = reopened
            .connection()
            .unwrap()
            .query_row(
                "SELECT boot_generation FROM node_telemetry WHERE node_id = ?1",
                [worker.id.to_string()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(stored_generation, 43);
        drop(reopened);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn run_heartbeat_never_refreshes_node_report_freshness() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let paired = pair_worker(&store, &worker);
        let report = node_report(&worker, Uuid::new_v4(), 1);
        let accepted = store
            .record_node_report(&paired.credential, &report)
            .unwrap();
        store
            .submit_job(&job(), None, &Scheduler::default())
            .unwrap();
        let claim = store
            .claim_job(&paired.credential, &worker)
            .unwrap()
            .unwrap();
        store
            .worker_heartbeat(
                &paired.credential,
                &claim.run_credential,
                claim.stored.run.id,
                claim.lease_id,
                claim.stored.version,
                JobState::Preparing,
            )
            .unwrap();
        let received_at = store
            .connection()
            .unwrap()
            .query_row(
                "SELECT received_at FROM node_telemetry WHERE node_id = ?1",
                [worker.id.to_string()],
                |row| row.get::<_, String>(0),
            )
            .unwrap();
        assert_eq!(parse_rfc3339(&received_at).unwrap(), accepted.received_at);
    }

    #[test]
    fn typed_policy_rejection_is_explainable_and_fleet_view_is_additive() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let paired = pair_worker(&store, &worker);
        store
            .record_node_report(&paired.credential, &node_report(&worker, Uuid::new_v4(), 1))
            .unwrap();
        let initial = store.get_node_config(worker.id).unwrap();
        let mut config = initial.config;
        config.capacity.allowed_job_kinds = BTreeSet::from([JobKind::Test]);
        config.capacity.max_concurrent_jobs = 8;
        store
            .update_node_config(worker.id, initial.revision, &config)
            .unwrap();
        let error = store
            .create_plan(&job(), &Scheduler::default())
            .expect_err("build is denied by typed policy");
        let StoreError::Schedule(ScheduleError::NoEligibleNodes { explanation }) = error else {
            panic!("unexpected scheduling result");
        };
        assert!(explanation.candidates[0]
            .rejection_reasons
            .iter()
            .any(|reason| reason.code == cyc_protocol::RejectionCode::PolicyJobKindDenied));

        let view = store.list_fleet_node_views().unwrap().remove(0);
        assert_eq!(view.node_id, worker.id);
        assert_eq!(view.effective_slots.configured, 8);
        assert_eq!(view.effective_slots.containment_max_safe, 1);
        assert_eq!(view.effective_slots.effective, 1);
        assert!(!view.inventory.digest.as_deref().unwrap().is_empty());
        assert!(view
            .availability_reasons
            .iter()
            .any(|reason| reason.contains("clamped")));
    }

    #[test]
    fn node_config_cas_persists_policy_and_worker_probe_cannot_overwrite_it() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let paired = pair_worker(&store, &worker);
        let initial = store.get_node_config(worker.id).unwrap();
        assert_eq!(initial.revision, 0);

        let mut desired = initial.config;
        desired.name = "operator-node".to_owned();
        desired.priority = 777;
        desired.labels.insert(
            "cyc.policy.allowedJobKinds".to_owned(),
            "build,test".to_owned(),
        );
        desired.labels.insert(
            "cyc.policy.resource".to_owned(),
            r#"{"cpuLimitPercent":80,"maximumParallelJobs":2,"memoryLimitBytes":null}"#.to_owned(),
        );
        desired.labels.insert(
            "cyc.policy.battery".to_owned(),
            r#"{"allowOnBattery":false}"#.to_owned(),
        );
        let updated = store.update_node_config(worker.id, 0, &desired).unwrap();
        assert_eq!(updated.revision, 1);
        assert!(matches!(
            store.update_node_config(worker.id, 0, &desired),
            Err(StoreError::NodeConfigVersionConflict {
                current_revision: 1
            })
        ));

        let mut daemon_probe = worker;
        daemon_probe.name = "worker-hostname".to_owned();
        daemon_probe.priority = -999;
        daemon_probe.labels.clear();
        assert!(store
            .claim_job(&paired.credential, &daemon_probe)
            .unwrap()
            .is_none());
        let stored = store.get_node_config(daemon_probe.id).unwrap();
        assert_eq!(stored.revision, 1);
        assert_eq!(stored.config, desired);
    }

    #[test]
    fn pairing_idempotency_survives_restart_without_storing_plaintext_code() {
        let directory = test_directory("pairing-idempotency");
        std::fs::create_dir_all(&directory).unwrap();
        let database = directory.join("controller.db");
        let intended = Uuid::new_v4();
        let operation = "desktop-add-computer:00000000-0000-4000-8000-000000000001";

        let first = Store::open(&database).unwrap();
        let issued = first
            .create_pairing_idempotent(
                operation,
                Some(intended),
                "https://192.0.2.10:47832",
                "-----BEGIN CERTIFICATE-----\nfixture-one\n-----END CERTIFICATE-----\n",
            )
            .unwrap();
        assert!(!issued.replayed);
        let pairing_id = issued.pairing.id;
        let pairing_code = issued.pairing.code.clone();
        let created_at = issued.pairing.created_at;
        drop(issued);
        drop(first);

        let reopened = Store::open(&database).unwrap();
        let replay = reopened
            .create_pairing_idempotent(
                operation,
                Some(intended),
                "https://listener-changed.invalid:47832",
                "-----BEGIN CERTIFICATE-----\nfixture-two\n-----END CERTIFICATE-----\n",
            )
            .unwrap();
        assert!(replay.replayed);
        assert_eq!(replay.pairing.id, pairing_id);
        assert_eq!(replay.pairing.intended_node_id, intended);
        assert_eq!(replay.pairing.created_at, created_at);
        assert_eq!(replay.pairing.code, pairing_code);
        assert_eq!(replay.worker_url, "https://192.0.2.10:47832");
        assert!(replay.certificate_pem.contains("fixture-one"));

        let persisted = reopened
            .connection()
            .unwrap()
            .query_row(
                r#"
                SELECT p.code_hash || ':' || o.operation_key || ':' ||
                       o.worker_url || ':' || o.certificate_pem
                FROM pairings p JOIN pairing_operations o ON o.pairing_id = p.id
                WHERE p.id = ?1
                "#,
                [pairing_id.to_string()],
                |row| row.get::<_, String>(0),
            )
            .unwrap();
        assert!(!persisted.contains(&pairing_code));
        assert!(matches!(
            reopened.create_pairing_idempotent(
                operation,
                Some(Uuid::new_v4()),
                "https://192.0.2.10:47832",
                "certificate"
            ),
            Err(StoreError::PairingIdempotencyMismatch)
        ));

        reopened.revoke_pairing(pairing_id).unwrap();
        assert!(matches!(
            reopened.create_pairing_idempotent(
                operation,
                Some(intended),
                "https://192.0.2.10:47832",
                "certificate"
            ),
            Err(StoreError::PairingIdempotencyFinalized {
                phase: PairingPhaseV1::Revoked
            })
        ));
        drop(reopened);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn corrupt_unconsumed_pairing_never_reexports_secret_or_reports_pending() {
        type PairingShape = (
            Option<i64>,
            Option<i64>,
            Option<String>,
            Option<i64>,
            Option<String>,
            i64,
            String,
        );

        fn pairing_shape(store: &Store, pairing_id: Uuid) -> PairingShape {
            store
                .connection()
                .unwrap()
                .query_row(
                    r#"
                    SELECT
                      p.used_at, p.acknowledged_at, p.node_id,
                      p.failed_at, p.failure_code,
                      (SELECT COUNT(*) FROM worker_credentials wc WHERE wc.pairing_id = p.id),
                      p.code_hash
                    FROM pairings p WHERE p.id = ?1
                    "#,
                    [pairing_id.to_string()],
                    |row| {
                        Ok((
                            row.get::<_, Option<i64>>(0)?,
                            row.get::<_, Option<i64>>(1)?,
                            row.get::<_, Option<String>>(2)?,
                            row.get::<_, Option<i64>>(3)?,
                            row.get::<_, Option<String>>(4)?,
                            row.get::<_, i64>(5)?,
                            row.get::<_, String>(6)?,
                        ))
                    },
                )
                .unwrap()
        }

        fn assert_corruption_is_terminal(
            store: &Store,
            operation: &str,
            intended_node_id: Uuid,
            pairing_id: Uuid,
            pairing_code: &str,
            before: PairingShape,
        ) {
            let status_error = store
                .get_pairing_status(pairing_id)
                .expect_err("corrupt unconsumed state must not be reported as pending");
            assert!(matches!(
                &status_error,
                StoreError::InvalidPairingFailureState
            ));
            assert!(!status_error.to_string().contains(pairing_code));

            let replay_error = match store.create_pairing_idempotent(
                operation,
                Some(intended_node_id),
                "https://changed-listener.invalid:47832",
                "changed certificate",
            ) {
                Ok(_) => panic!("corrupt unconsumed state re-exported a derived code"),
                Err(error) => error,
            };
            assert!(matches!(
                &replay_error,
                StoreError::InvalidPairingFailureState
            ));
            assert!(!replay_error.to_string().contains(pairing_code));
            let after = pairing_shape(store, pairing_id);
            assert_eq!(after, before);
            assert_eq!(after.6, secret_hash(pairing_code));
            assert_ne!(after.6, pairing_code);
        }

        let store = Store::in_memory().unwrap();
        let worker_url = "https://192.0.2.91:47832";
        let certificate = "-----BEGIN CERTIFICATE-----\ncorrupt\n-----END CERTIFICATE-----\n";

        let node_operation = "desktop-add-computer:corrupt-unconsumed-node";
        let node_intended = Uuid::new_v4();
        let node_issued = store
            .create_pairing_idempotent(node_operation, Some(node_intended), worker_url, certificate)
            .unwrap();
        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE pairings SET node_id = ?1 WHERE id = ?2",
                params![
                    Uuid::new_v4().to_string(),
                    node_issued.pairing.id.to_string()
                ],
            )
            .unwrap();
        let node_before = pairing_shape(&store, node_issued.pairing.id);
        assert_corruption_is_terminal(
            &store,
            node_operation,
            node_intended,
            node_issued.pairing.id,
            &node_issued.pairing.code,
            node_before,
        );

        let ack_operation = "desktop-add-computer:corrupt-unconsumed-ack";
        let ack_intended = Uuid::new_v4();
        let ack_issued = store
            .create_pairing_idempotent(ack_operation, Some(ack_intended), worker_url, certificate)
            .unwrap();
        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE pairings SET acknowledged_at = ?1 WHERE id = ?2",
                params![Utc::now().timestamp(), ack_issued.pairing.id.to_string()],
            )
            .unwrap();
        let ack_before = pairing_shape(&store, ack_issued.pairing.id);
        assert_corruption_is_terminal(
            &store,
            ack_operation,
            ack_intended,
            ack_issued.pairing.id,
            &ack_issued.pairing.code,
            ack_before,
        );

        let credential_operation = "desktop-add-computer:corrupt-unconsumed-credential";
        let credential_intended = Uuid::new_v4();
        let credential_issued = store
            .create_pairing_idempotent(
                credential_operation,
                Some(credential_intended),
                worker_url,
                certificate,
            )
            .unwrap();
        store
            .connection()
            .unwrap()
            .execute(
                r#"
                INSERT INTO worker_credentials(
                    id, pairing_id, node_id, credential_hash, created_at,
                    activated_at, last_used_at, revoked_at
                ) VALUES (?1, ?2, ?3, ?4, ?5, NULL, NULL, NULL)
                "#,
                params![
                    Uuid::new_v4().to_string(),
                    credential_issued.pairing.id.to_string(),
                    credential_intended.to_string(),
                    secret_hash("corrupt-unconsumed-staged-credential"),
                    Utc::now().timestamp(),
                ],
            )
            .unwrap();
        let credential_before = pairing_shape(&store, credential_issued.pairing.id);
        assert_corruption_is_terminal(
            &store,
            credential_operation,
            credential_intended,
            credential_issued.pairing.id,
            &credential_issued.pairing.code,
            credential_before,
        );
    }

    #[test]
    fn worker_probe_updates_inventory_and_telemetry_but_not_config() {
        let store = Store::in_memory().unwrap();
        let mut configured = node();
        configured.name = "operator-name".to_owned();
        configured.enabled = false;
        configured.priority = 777;
        configured
            .labels
            .insert("pool".to_owned(), "operator-owned".to_owned());
        let paired = pair_worker(&store, &configured);

        let mut probe = configured.clone();
        probe.name = "worker-hostname".to_owned();
        probe.enabled = true;
        probe.priority = -100;
        probe.labels.clear();
        probe.resources.memory_mib = 32_768;
        probe.resources.available_memory_mib = 20_000;
        probe.load.cpu_percent = 73;
        assert!(store
            .claim_job(&paired.credential, &probe)
            .unwrap()
            .is_none());

        let view = store.list_node_views().unwrap().remove(0);
        assert_eq!(view.config.name, "operator-name");
        assert!(!view.config.enabled);
        assert_eq!(view.config.priority, 777);
        assert_eq!(view.config.labels["pool"], "operator-owned");
        assert_eq!(view.inventory.memory_mib, 32_768);
        assert_eq!(view.telemetry.available_memory_mib, 20_000);
        assert_eq!(view.telemetry.load.cpu_percent, 73);
    }

    #[test]
    fn controller_received_at_not_worker_clock_decides_freshness() {
        let store = Store::in_memory().unwrap();
        let mut worker = node();
        worker.last_seen_at = Some(Utc::now() - chrono::Duration::days(365));
        let _paired = pair_worker(&store, &worker);
        let view = store.list_node_views().unwrap().remove(0);
        assert_eq!(view.telemetry.observed_at, worker.last_seen_at.unwrap());
        assert!(view.received_at > Utc::now() - chrono::Duration::seconds(5));
        assert!(store.create_plan(&job(), &Scheduler::default()).is_ok());

        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE node_telemetry SET received_at = ?1 WHERE node_id = ?2",
                params![
                    (Utc::now() - chrono::Duration::seconds(NODE_FRESHNESS_SECONDS + 1))
                        .to_rfc3339(),
                    worker.id.to_string()
                ],
            )
            .unwrap();
        let mut next = job();
        next.id = Uuid::new_v4();
        assert!(matches!(
            store.create_plan(&next, &Scheduler::default()),
            Err(StoreError::Schedule(ScheduleError::NoEligibleNodes { .. }))
        ));
    }

    #[test]
    fn legacy_node_document_is_migrated_to_split_state() {
        let connection = Connection::open_in_memory().unwrap();
        connection
            .execute_batch(
                r#"
                CREATE TABLE nodes (
                    id TEXT PRIMARY KEY NOT NULL,
                    document TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    revision INTEGER NOT NULL DEFAULT 0
                );
                "#,
            )
            .unwrap();
        let mut legacy = node();
        legacy.name = "legacy-name".to_owned();
        legacy.priority = 321;
        legacy.cached_sources.insert("git:legacy".to_owned());
        legacy.last_seen_at = Some(Utc::now() - chrono::Duration::minutes(10));
        let received_at = Utc::now() - chrono::Duration::seconds(10);
        connection
            .execute(
                "INSERT INTO nodes(id, document, updated_at, revision) VALUES (?1, ?2, ?3, 7)",
                params![
                    legacy.id.to_string(),
                    serde_json::to_string(&legacy).unwrap(),
                    received_at.to_rfc3339()
                ],
            )
            .unwrap();

        let store = Store::from_connection(
            connection,
            std::env::temp_dir().join(format!("cyc-migration-{}", Uuid::new_v4())),
        )
        .unwrap();
        let counts = store
            .connection()
            .unwrap()
            .query_row(
                r#"
                SELECT
                    (SELECT COUNT(*) FROM node_configs),
                    (SELECT COUNT(*) FROM node_inventories),
                    (SELECT COUNT(*) FROM node_telemetry)
                "#,
                [],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, i64>(2)?,
                    ))
                },
            )
            .unwrap();
        assert_eq!(counts, (1, 1, 1));
        let view = store.list_node_views().unwrap().remove(0);
        assert_eq!(view.config.name, "legacy-name");
        assert_eq!(view.config.priority, 321);
        assert_eq!(view.telemetry.cached_sources, legacy.cached_sources);
        assert_eq!(view.telemetry.observed_at, legacy.last_seen_at.unwrap());
        assert_eq!(view.received_at, received_at);
        let revision = store
            .connection()
            .unwrap()
            .query_row(
                "SELECT revision FROM nodes WHERE id = ?1",
                [legacy.id.to_string()],
                |row| row.get::<_, i64>(0),
            )
            .unwrap();
        assert_eq!(revision, 7);
    }

    #[test]
    fn legacy_pairing_credentials_are_backfilled_as_acknowledged_and_active() {
        let connection = Connection::open_in_memory().unwrap();
        connection
            .execute_batch(
                r#"
                CREATE TABLE nodes (
                    id TEXT PRIMARY KEY NOT NULL,
                    document TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE pairings (
                    id TEXT PRIMARY KEY NOT NULL,
                    code_hash TEXT UNIQUE NOT NULL,
                    created_at INTEGER NOT NULL,
                    expires_at INTEGER NOT NULL,
                    used_at INTEGER,
                    revoked_at INTEGER,
                    node_id TEXT,
                    intended_node_id TEXT
                );
                CREATE TABLE worker_credentials (
                    id TEXT PRIMARY KEY NOT NULL,
                    pairing_id TEXT NOT NULL,
                    node_id TEXT NOT NULL,
                    credential_hash TEXT UNIQUE NOT NULL,
                    created_at INTEGER NOT NULL,
                    last_used_at INTEGER,
                    revoked_at INTEGER,
                    FOREIGN KEY(pairing_id) REFERENCES pairings(id)
                );
                "#,
            )
            .unwrap();
        let worker = node();
        let pairing_id = Uuid::new_v4();
        let credential = random_secret();
        let digest = secret_hash(&credential);
        let now = Utc::now();
        connection
            .execute(
                "INSERT INTO nodes(id, document, updated_at) VALUES (?1, ?2, ?3)",
                params![
                    worker.id.to_string(),
                    serde_json::to_string(&worker).unwrap(),
                    now.to_rfc3339(),
                ],
            )
            .unwrap();
        connection
            .execute(
                r#"
                INSERT INTO pairings(
                    id, code_hash, created_at, expires_at, used_at, revoked_at,
                    node_id, intended_node_id
                ) VALUES (?1, ?2, ?3, ?4, ?3, NULL, ?5, ?5)
                "#,
                params![
                    pairing_id.to_string(),
                    secret_hash("legacy-one-time-code"),
                    now.timestamp(),
                    (now + chrono::Duration::minutes(10)).timestamp(),
                    worker.id.to_string(),
                ],
            )
            .unwrap();
        connection
            .execute(
                r#"
                INSERT INTO worker_credentials(
                    id, pairing_id, node_id, credential_hash, created_at,
                    last_used_at, revoked_at
                ) VALUES (?1, ?2, ?3, ?4, ?5, NULL, NULL)
                "#,
                params![
                    Uuid::new_v4().to_string(),
                    pairing_id.to_string(),
                    worker.id.to_string(),
                    digest,
                    now.timestamp(),
                ],
            )
            .unwrap();

        let store = Store::from_connection(
            connection,
            std::env::temp_dir().join(format!("cyc-pairing-migration-{}", Uuid::new_v4())),
        )
        .unwrap();
        assert_eq!(store.authenticate_worker(&credential).unwrap(), worker.id);
        let status = store.get_pairing_status(pairing_id).unwrap();
        assert_eq!(status.phase, PairingPhaseV1::Ready);
        assert_eq!(status.acknowledged_at, status.consumed_at);
        assert!(status.failed_at.is_none());
        assert!(status.failure_code.is_none());
        let failure_columns = {
            let connection = store.connection().unwrap();
            let mut statement = connection.prepare("PRAGMA table_info(pairings)").unwrap();
            statement
                .query_map([], |row| row.get::<_, String>(1))
                .unwrap()
                .collect::<Result<Vec<_>, _>>()
                .unwrap()
        };
        assert!(failure_columns.iter().any(|name| name == "failed_at"));
        assert!(failure_columns.iter().any(|name| name == "failure_code"));
        let timestamps = store
            .connection()
            .unwrap()
            .query_row(
                r#"
                SELECT wc.created_at, wc.activated_at, p.used_at, p.acknowledged_at
                FROM worker_credentials wc
                JOIN pairings p ON p.id = wc.pairing_id
                WHERE wc.pairing_id = ?1
                "#,
                [pairing_id.to_string()],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, i64>(3)?,
                    ))
                },
            )
            .unwrap();
        assert_eq!(timestamps.0, timestamps.1);
        assert_eq!(timestamps.2, timestamps.3);
    }

    #[test]
    fn migration_marks_exact_legacy_rotated_ready_pairing_revoked() {
        let directory = test_directory("legacy-rotated-ready-pairing");
        std::fs::create_dir_all(&directory).unwrap();
        let database = directory.join("controller.db");
        let worker = node();
        let operation = "desktop-add-computer:legacy-rotated-ready";
        let worker_url = "https://192.0.2.85:47832";
        let certificate =
            "-----BEGIN CERTIFICATE-----\nlegacy-rotation\n-----END CERTIFICATE-----\n";
        let store = Store::open(&database).unwrap();
        let issued = store
            .create_pairing_idempotent(operation, Some(worker.id), worker_url, certificate)
            .unwrap();
        let credential = random_secret();
        let digest = secret_hash(&credential);
        store
            .consume_pairing(
                &issued.pairing.code,
                issued.pairing.id,
                issued.pairing.intended_node_id,
                &digest,
                &worker,
            )
            .unwrap();
        store
            .acknowledge_pairing(&credential, issued.pairing.id, worker.id, &digest)
            .unwrap();

        let legacy_revoked_at = Utc::now().timestamp();
        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE worker_credentials SET revoked_at = ?1 WHERE pairing_id = ?2",
                params![legacy_revoked_at, issued.pairing.id.to_string()],
            )
            .unwrap();
        assert!(matches!(
            store.get_pairing_status(issued.pairing.id),
            Err(StoreError::InvalidPairingFailureState)
        ));
        drop(store);

        let reopened = Store::open(&database).unwrap();
        let status = reopened.get_pairing_status(issued.pairing.id).unwrap();
        assert_eq!(status.phase, PairingPhaseV1::Revoked);
        assert_eq!(status.revoked_at.unwrap().timestamp(), legacy_revoked_at);
        assert!(matches!(
            reopened
                .create_pairing_idempotent(operation, Some(worker.id), worker_url, certificate,),
            Err(StoreError::PairingIdempotencyFinalized {
                phase: PairingPhaseV1::Revoked
            })
        ));
        assert!(matches!(
            reopened.authenticate_worker(&credential),
            Err(StoreError::WorkerUnauthorized)
        ));
        drop(reopened);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn lease_phase_migration_backfills_only_active_claims_as_execution() {
        let directory = test_directory("lease-phase-migration");
        std::fs::create_dir_all(&directory).unwrap();
        let database = directory.join("controller.db");
        let store = Store::open(&database).unwrap();
        let worker = node();
        let paired = pair_worker(&store, &worker);
        store
            .submit_job(&job(), None, &Scheduler::default())
            .unwrap();
        let claim = store
            .claim_job(&paired.credential, &worker)
            .unwrap()
            .unwrap();
        let legacy_id = Uuid::new_v4();
        store
            .connection()
            .unwrap()
            .execute_batch(&format!(
                r#"
                UPDATE leases SET phase = 'legacy' WHERE id = '{}';
                INSERT INTO leases(
                    id, run_id, job_id, node_id, cpu_cores, memory_mib, disk_mib,
                    gpu_reserved, slots, phase, created_at, expires_at, released_at
                ) VALUES(
                    '{legacy_id}', '{}', '{}', '{}', 1, 0, 0,
                    0, 1, 'legacy', {}, {}, NULL
                );
                "#,
                claim.lease_id,
                Uuid::new_v4(),
                Uuid::new_v4(),
                worker.id,
                Utc::now().timestamp(),
                Utc::now().timestamp() + 300,
            ))
            .unwrap();
        drop(store);

        let reopened = Store::open(&database).unwrap();
        let claimed_phase = reopened
            .connection()
            .unwrap()
            .query_row(
                "SELECT phase FROM leases WHERE id = ?1",
                [claim.lease_id.to_string()],
                |row| row.get::<_, String>(0),
            )
            .unwrap();
        let untouched_legacy = reopened
            .connection()
            .unwrap()
            .query_row(
                "SELECT phase FROM leases WHERE id = ?1",
                [legacy_id.to_string()],
                |row| row.get::<_, String>(0),
            )
            .unwrap();
        assert_eq!(claimed_phase, LEASE_PHASE_EXECUTION);
        assert_eq!(untouched_legacy, LEASE_PHASE_LEGACY);
        drop(reopened);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn cleanup_migration_marks_legacy_early_release_without_faking_receipt() {
        let directory = test_directory("cleanup-legacy-migration");
        std::fs::create_dir_all(&directory).unwrap();
        let database = directory.join("controller.db");
        let store = Store::open(&database).unwrap();
        let worker = node();
        let paired = pair_worker(&store, &worker);
        let (_claim, completed, _ack) = complete_empty_managed_run(&store, &worker, &paired);
        let released_at = Utc::now().timestamp();
        store
            .connection()
            .unwrap()
            .execute_batch(&format!(
                r#"
                DELETE FROM run_cleanup_obligations WHERE run_id = '{}';
                UPDATE leases SET released_at = {released_at}, phase = 'execution'
                WHERE id = '{}';
                "#,
                completed.run.id,
                completed.lease_id.unwrap()
            ))
            .unwrap();
        drop(store);

        let reopened = Store::open(&database).unwrap();
        let snapshot = reopened.get_cleanup_snapshot(completed.job.id).unwrap();
        assert!(snapshot.cleanup.is_none());
        let obligation = snapshot.obligation.unwrap();
        assert_eq!(
            obligation.release_reason,
            Some(CleanupReservationReleaseReasonV1::LegacyMigration)
        );
        assert_eq!(
            obligation.cleanup_failure.unwrap().code,
            CleanupFailureCodeV1::LegacyReleaseWithoutCleanupEvidence
        );
        drop(reopened);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn repairing_a_node_preserves_identity_preferences_and_rotates_credentials() {
        let store = Store::in_memory().unwrap();
        let mut first_probe = node();
        first_probe.name = "operator-name".to_owned();
        first_probe.priority = 900;
        first_probe
            .labels
            .insert("pool".to_owned(), "primary".to_owned());
        first_probe
            .cached_sources
            .insert("git:stale-source".to_owned());
        let first_pairing = store.create_pairing_for(Some(first_probe.id)).unwrap();
        let first_credential = random_secret();
        let first_digest = secret_hash(&first_credential);
        let first = store
            .consume_pairing(
                &first_pairing.code,
                first_pairing.id,
                first_pairing.intended_node_id,
                &first_digest,
                &first_probe,
            )
            .unwrap();
        assert_eq!(
            store.get_pairing_status(first_pairing.id).unwrap().phase,
            PairingPhaseV1::Consumed
        );
        assert!(matches!(
            store.authenticate_worker(&first_credential),
            Err(StoreError::WorkerUnauthorized)
        ));
        store
            .acknowledge_pairing(
                &first_credential,
                first_pairing.id,
                first_probe.id,
                &first_digest,
            )
            .unwrap();
        assert_eq!(
            store.get_pairing_status(first_pairing.id).unwrap().phase,
            PairingPhaseV1::Ready
        );

        let second_pairing = store.create_pairing_for(Some(first_probe.id)).unwrap();
        let mut repaired_probe = node();
        repaired_probe.id = first_probe.id;
        repaired_probe.name = "hostname-after-reinstall".to_owned();
        repaired_probe.resources.available_memory_mib = 8_192;
        repaired_probe
            .cached_sources
            .insert("git:fresh-source".to_owned());
        let second_credential = random_secret();
        let second_digest = secret_hash(&second_credential);
        let second = store
            .consume_pairing(
                &second_pairing.code,
                second_pairing.id,
                second_pairing.intended_node_id,
                &second_digest,
                &repaired_probe,
            )
            .unwrap();

        assert_eq!(first.node_id, second.node_id);
        assert_eq!(second.node_id, first_probe.id);
        // Consuming a repair must not create an outage: the old credential is
        // the sole active identity until the staged replacement is ACKed.
        assert_eq!(
            store.authenticate_worker(&first_credential).unwrap(),
            first_probe.id
        );
        assert!(matches!(
            store.authenticate_worker(&second_credential),
            Err(StoreError::WorkerUnauthorized)
        ));
        assert_eq!(
            store.get_pairing_status(second_pairing.id).unwrap().phase,
            PairingPhaseV1::Consumed
        );
        store
            .acknowledge_pairing(
                &second_credential,
                second_pairing.id,
                first_probe.id,
                &second_digest,
            )
            .unwrap();
        assert!(matches!(
            store.authenticate_worker(&first_credential),
            Err(StoreError::WorkerUnauthorized)
        ));
        assert_eq!(
            store.authenticate_worker(&second_credential).unwrap(),
            first_probe.id
        );
        let nodes = store.list_nodes().unwrap();
        assert_eq!(nodes.len(), 1);
        assert_eq!(nodes[0].name, "operator-name");
        assert_eq!(nodes[0].priority, 900);
        assert_eq!(nodes[0].labels["pool"], "primary");
        assert_eq!(nodes[0].resources.available_memory_mib, 8_192);
        assert_eq!(
            nodes[0].cached_sources,
            BTreeSet::from(["git:fresh-source".to_owned()])
        );
        assert_eq!(
            store.get_pairing_status(first_pairing.id).unwrap().phase,
            PairingPhaseV1::Revoked
        );
        assert_eq!(
            store.get_pairing_status(second_pairing.id).unwrap().phase,
            PairingPhaseV1::Ready
        );

        let clear_pairing = store.create_pairing_for(Some(first_probe.id)).unwrap();
        let mut clear_probe = node();
        clear_probe.id = first_probe.id;
        let clear_credential = random_secret();
        let clear_digest = secret_hash(&clear_credential);
        let cleared = store
            .consume_pairing(
                &clear_pairing.code,
                clear_pairing.id,
                clear_pairing.intended_node_id,
                &clear_digest,
                &clear_probe,
            )
            .unwrap();
        assert_eq!(cleared.node_id, first_probe.id);
        store
            .acknowledge_pairing(
                &clear_credential,
                clear_pairing.id,
                first_probe.id,
                &clear_digest,
            )
            .unwrap();
        assert!(store.list_nodes().unwrap()[0].cached_sources.is_empty());
    }

    #[test]
    fn pairing_consume_response_and_ack_loss_retries_converge_exactly_once() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let pairing = store.create_pairing_for(Some(worker.id)).unwrap();
        let credential = random_secret();
        let digest = secret_hash(&credential);

        // The first transaction commits, but the caller may lose its response.
        let first = store
            .consume_pairing(
                &pairing.code,
                pairing.id,
                pairing.intended_node_id,
                &digest,
                &worker,
            )
            .unwrap();
        assert!(!first.replayed);
        assert_eq!(
            store.get_pairing_status(pairing.id).unwrap().phase,
            PairingPhaseV1::Consumed
        );
        assert!(matches!(
            store.authenticate_worker(&credential),
            Err(StoreError::WorkerUnauthorized)
        ));

        let replay = store
            .consume_pairing(
                &pairing.code,
                pairing.id,
                pairing.intended_node_id,
                &digest,
                &worker,
            )
            .unwrap();
        assert!(replay.replayed);
        assert_eq!(replay.pairing_id, first.pairing_id);
        assert_eq!(replay.node_id, first.node_id);
        assert_eq!(replay.credential_sha256, first.credential_sha256);
        assert_eq!(replay.consumed_at, first.consumed_at);
        let rows: i64 = store
            .connection()
            .unwrap()
            .query_row(
                "SELECT COUNT(*) FROM worker_credentials WHERE pairing_id = ?1",
                [pairing.id.to_string()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(rows, 1);

        // ACK can commit while its response is lost. Replaying it is stable.
        let first_ack = store
            .acknowledge_pairing(&credential, pairing.id, worker.id, &digest)
            .unwrap();
        let replayed_ack = store
            .acknowledge_pairing(&credential, pairing.id, worker.id, &digest)
            .unwrap();
        assert_eq!(replayed_ack, first_ack);
        assert_eq!(
            store.get_pairing_status(pairing.id).unwrap().phase,
            PairingPhaseV1::Ready
        );
        assert_eq!(store.authenticate_worker(&credential).unwrap(), worker.id);
        let active: i64 = store
            .connection()
            .unwrap()
            .query_row(
                r#"
                SELECT COUNT(*) FROM worker_credentials
                WHERE node_id = ?1 AND activated_at IS NOT NULL AND revoked_at IS NULL
                "#,
                [worker.id.to_string()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(active, 1);
    }

    #[test]
    fn pairing_retry_rejects_wrong_hash_node_and_expired_code() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let pairing = store.create_pairing_for(Some(worker.id)).unwrap();
        let credential = random_secret();
        let digest = secret_hash(&credential);
        store
            .consume_pairing(
                &pairing.code,
                pairing.id,
                pairing.intended_node_id,
                &digest,
                &worker,
            )
            .unwrap();

        assert!(matches!(
            store.consume_pairing(
                &pairing.code,
                pairing.id,
                pairing.intended_node_id,
                &"f".repeat(64),
                &worker,
            ),
            Err(StoreError::PairingBindingMismatch)
        ));
        let mut other_node = worker.clone();
        other_node.id = Uuid::new_v4();
        assert!(matches!(
            store.consume_pairing(
                &pairing.code,
                pairing.id,
                other_node.id,
                &digest,
                &other_node,
            ),
            Err(StoreError::PairingBindingMismatch)
        ));
        assert!(matches!(
            store.acknowledge_pairing(&credential, pairing.id, worker.id, &"f".repeat(64),),
            Err(StoreError::PairingAcknowledgementUnavailable)
        ));
        assert!(matches!(
            store.acknowledge_pairing(&credential, pairing.id, other_node.id, &digest),
            Err(StoreError::PairingAcknowledgementUnavailable)
        ));

        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE pairings SET expires_at = ?1 WHERE id = ?2",
                params![
                    (Utc::now() - chrono::Duration::seconds(1)).timestamp(),
                    pairing.id.to_string()
                ],
            )
            .unwrap();
        assert!(matches!(
            store.consume_pairing(
                &pairing.code,
                pairing.id,
                pairing.intended_node_id,
                &digest,
                &worker,
            ),
            Err(StoreError::PairingUnavailable)
        ));
        assert!(matches!(
            store.preauthorize_pairing(&pairing.code),
            Err(StoreError::PairingUnavailable)
        ));
        // Expiry closes the one-time code but must not strand a worker that
        // already committed the matching local config and now needs to ACK.
        store
            .acknowledge_pairing(&credential, pairing.id, worker.id, &digest)
            .unwrap();
        assert_eq!(
            store.get_pairing_status(pairing.id).unwrap().phase,
            PairingPhaseV1::Ready
        );
    }

    #[test]
    fn ready_classification_rejects_missing_node_and_misbound_credential() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let operation = "desktop-add-computer:ready-invariant";
        let worker_url = "https://192.0.2.81:47832";
        let certificate = "-----BEGIN CERTIFICATE-----\nready\n-----END CERTIFICATE-----\n";
        let issued = store
            .create_pairing_idempotent(operation, Some(worker.id), worker_url, certificate)
            .unwrap();
        let credential = random_secret();
        let digest = secret_hash(&credential);
        store
            .consume_pairing(
                &issued.pairing.code,
                issued.pairing.id,
                issued.pairing.intended_node_id,
                &digest,
                &worker,
            )
            .unwrap();
        store
            .acknowledge_pairing(&credential, issued.pairing.id, worker.id, &digest)
            .unwrap();
        assert_eq!(
            store.get_pairing_status(issued.pairing.id).unwrap().phase,
            PairingPhaseV1::Ready
        );
        assert!(matches!(
            store.create_pairing_idempotent(operation, Some(worker.id), worker_url, certificate,),
            Err(StoreError::PairingIdempotencyFinalized {
                phase: PairingPhaseV1::Ready
            })
        ));

        let mut other = node();
        other.id = Uuid::new_v4();
        store.upsert_node(&other).unwrap();
        store
            .connection()
            .unwrap()
            .execute(
                r#"
                UPDATE worker_credentials SET node_id = ?1, last_used_at = 123
                WHERE pairing_id = ?2
                "#,
                params![other.id.to_string(), issued.pairing.id.to_string()],
            )
            .unwrap();

        assert!(matches!(
            store.get_pairing_status(issued.pairing.id),
            Err(StoreError::InvalidPairingFailureState)
        ));
        assert!(matches!(
            store.create_pairing_idempotent(operation, Some(worker.id), worker_url, certificate,),
            Err(StoreError::InvalidPairingFailureState)
        ));
        assert!(matches!(
            store.authenticate_worker(&credential),
            Err(StoreError::WorkerUnauthorized)
        ));
        let last_used_after_misbind = store
            .connection()
            .unwrap()
            .query_row(
                "SELECT last_used_at FROM worker_credentials WHERE pairing_id = ?1",
                [issued.pairing.id.to_string()],
                |row| row.get::<_, Option<i64>>(0),
            )
            .unwrap();
        assert_eq!(last_used_after_misbind, Some(123));

        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE worker_credentials SET node_id = ?1 WHERE pairing_id = ?2",
                params![worker.id.to_string(), issued.pairing.id.to_string()],
            )
            .unwrap();
        store
            .connection()
            .unwrap()
            .execute("DELETE FROM nodes WHERE id = ?1", [worker.id.to_string()])
            .unwrap();

        assert!(matches!(
            store.get_pairing_status(issued.pairing.id),
            Err(StoreError::InvalidPairingFailureState)
        ));
        assert!(matches!(
            store.create_pairing_idempotent(operation, Some(worker.id), worker_url, certificate,),
            Err(StoreError::InvalidPairingFailureState)
        ));
        assert!(matches!(
            store.authenticate_worker(&credential),
            Err(StoreError::WorkerUnauthorized)
        ));
        let last_used_after_node_delete = store
            .connection()
            .unwrap()
            .query_row(
                "SELECT last_used_at FROM worker_credentials WHERE pairing_id = ?1",
                [issued.pairing.id.to_string()],
                |row| row.get::<_, Option<i64>>(0),
            )
            .unwrap();
        assert_eq!(last_used_after_node_delete, Some(123));
    }

    #[test]
    fn authoritative_pairing_classification_rejects_corrupt_consumed_and_ready_shapes() {
        type AuthoritativeShape = (
            Option<i64>,
            Option<i64>,
            Option<i64>,
            Option<i64>,
            Option<String>,
            Option<String>,
            String,
            Vec<(String, String, Option<i64>, Option<i64>, Option<i64>)>,
        );

        #[derive(Clone, Copy)]
        enum Corruption {
            MissingNode,
            MissingCredential,
            MisboundCredential,
            ExtraCredential,
            WrongActivation,
            CredentialRevoked,
        }

        impl Corruption {
            fn label(self) -> &'static str {
                match self {
                    Self::MissingNode => "missing-node",
                    Self::MissingCredential => "missing-credential",
                    Self::MisboundCredential => "misbound-credential",
                    Self::ExtraCredential => "extra-credential",
                    Self::WrongActivation => "wrong-activation",
                    Self::CredentialRevoked => "credential-revoked",
                }
            }
        }

        fn shape(store: &Store, pairing_id: Uuid) -> AuthoritativeShape {
            let connection = store.connection().unwrap();
            let pairing = connection
                .query_row(
                    r#"
                    SELECT used_at, acknowledged_at, revoked_at, failed_at,
                           failure_code, node_id, code_hash
                    FROM pairings WHERE id = ?1
                    "#,
                    [pairing_id.to_string()],
                    |row| {
                        Ok((
                            row.get::<_, Option<i64>>(0)?,
                            row.get::<_, Option<i64>>(1)?,
                            row.get::<_, Option<i64>>(2)?,
                            row.get::<_, Option<i64>>(3)?,
                            row.get::<_, Option<String>>(4)?,
                            row.get::<_, Option<String>>(5)?,
                            row.get::<_, String>(6)?,
                        ))
                    },
                )
                .unwrap();
            let credentials = {
                let mut statement = connection
                    .prepare(
                        r#"
                        SELECT id, node_id, activated_at, last_used_at, revoked_at
                        FROM worker_credentials
                        WHERE pairing_id = ?1
                        ORDER BY id
                        "#,
                    )
                    .unwrap();
                statement
                    .query_map([pairing_id.to_string()], |row| {
                        Ok((
                            row.get::<_, String>(0)?,
                            row.get::<_, String>(1)?,
                            row.get::<_, Option<i64>>(2)?,
                            row.get::<_, Option<i64>>(3)?,
                            row.get::<_, Option<i64>>(4)?,
                        ))
                    })
                    .unwrap()
                    .collect::<Result<Vec<_>, _>>()
                    .unwrap()
            };
            (
                pairing.0,
                pairing.1,
                pairing.2,
                pairing.3,
                pairing.4,
                pairing.5,
                pairing.6,
                credentials,
            )
        }

        fn assert_case(ready: bool, corruption: Corruption) {
            let store = Store::in_memory().unwrap();
            let worker = node();
            let phase = if ready { "ready" } else { "consumed" };
            let operation = format!(
                "desktop-add-computer:authoritative-{phase}-{}",
                corruption.label()
            );
            let worker_url = "https://192.0.2.83:47832";
            let certificate =
                "-----BEGIN CERTIFICATE-----\nauthoritative\n-----END CERTIFICATE-----\n";
            let issued = store
                .create_pairing_idempotent(&operation, Some(worker.id), worker_url, certificate)
                .unwrap();
            let credential = random_secret();
            let digest = secret_hash(&credential);
            store
                .consume_pairing(
                    &issued.pairing.code,
                    issued.pairing.id,
                    issued.pairing.intended_node_id,
                    &digest,
                    &worker,
                )
                .unwrap();
            if ready {
                store
                    .acknowledge_pairing(&credential, issued.pairing.id, worker.id, &digest)
                    .unwrap();
            }

            match corruption {
                Corruption::MissingNode => {
                    store
                        .connection()
                        .unwrap()
                        .execute("DELETE FROM nodes WHERE id = ?1", [worker.id.to_string()])
                        .unwrap();
                }
                Corruption::MissingCredential => {
                    store
                        .connection()
                        .unwrap()
                        .execute(
                            "DELETE FROM worker_credentials WHERE pairing_id = ?1",
                            [issued.pairing.id.to_string()],
                        )
                        .unwrap();
                }
                Corruption::MisboundCredential => {
                    let mut other = node();
                    other.id = Uuid::new_v4();
                    store.upsert_node(&other).unwrap();
                    store
                        .connection()
                        .unwrap()
                        .execute(
                            "UPDATE worker_credentials SET node_id = ?1 WHERE pairing_id = ?2",
                            params![other.id.to_string(), issued.pairing.id.to_string()],
                        )
                        .unwrap();
                }
                Corruption::ExtraCredential => {
                    store
                        .connection()
                        .unwrap()
                        .execute(
                            r#"
                            INSERT INTO worker_credentials(
                                id, pairing_id, node_id, credential_hash, created_at,
                                activated_at, last_used_at, revoked_at
                            ) VALUES (?1, ?2, ?3, ?4, ?5, NULL, NULL, NULL)
                            "#,
                            params![
                                Uuid::new_v4().to_string(),
                                issued.pairing.id.to_string(),
                                worker.id.to_string(),
                                secret_hash(&format!("extra-{}-{phase}", corruption.label())),
                                Utc::now().timestamp(),
                            ],
                        )
                        .unwrap();
                }
                Corruption::WrongActivation => {
                    let activated_at = if ready {
                        None
                    } else {
                        Some(Utc::now().timestamp())
                    };
                    store
                        .connection()
                        .unwrap()
                        .execute(
                            "UPDATE worker_credentials SET activated_at = ?1 WHERE pairing_id = ?2",
                            params![activated_at, issued.pairing.id.to_string()],
                        )
                        .unwrap();
                }
                Corruption::CredentialRevoked => {
                    store
                        .connection()
                        .unwrap()
                        .execute(
                            "UPDATE worker_credentials SET revoked_at = ?1 WHERE pairing_id = ?2",
                            params![Utc::now().timestamp(), issued.pairing.id.to_string()],
                        )
                        .unwrap();
                }
            }

            let before = shape(&store, issued.pairing.id);
            assert_eq!(before.6, secret_hash(&issued.pairing.code));
            assert_ne!(before.6, issued.pairing.code);

            let status_error = store
                .get_pairing_status(issued.pairing.id)
                .expect_err("corrupt lifecycle must not have an authoritative status");
            assert!(matches!(
                &status_error,
                StoreError::InvalidPairingFailureState
            ));
            assert!(!status_error.to_string().contains(&issued.pairing.code));

            let replay_error = match store.create_pairing_idempotent(
                &operation,
                Some(worker.id),
                worker_url,
                certificate,
            ) {
                Ok(_) => panic!("corrupt lifecycle re-exported a derived pairing code"),
                Err(error) => error,
            };
            assert!(matches!(
                &replay_error,
                StoreError::InvalidPairingFailureState
            ));
            assert!(!replay_error.to_string().contains(&issued.pairing.code));

            let failure_error = store
                .fail_pairing(issued.pairing.id, PairingFailureCodeV1::WorkerPairingFailed)
                .expect_err("corrupt lifecycle must not be classified as a valid terminal phase");
            assert!(matches!(
                &failure_error,
                StoreError::InvalidPairingFailureState
            ));
            assert!(!failure_error.to_string().contains(&issued.pairing.code));
            assert_eq!(shape(&store, issued.pairing.id), before);
        }

        for ready in [false, true] {
            for corruption in [
                Corruption::MissingNode,
                Corruption::MissingCredential,
                Corruption::MisboundCredential,
                Corruption::ExtraCredential,
                Corruption::WrongActivation,
                Corruption::CredentialRevoked,
            ] {
                assert_case(ready, corruption);
            }
        }
    }

    #[test]
    fn revoked_overlay_accepts_exact_pending_consumed_ready_and_failed_shapes() {
        fn assert_revoked_replay(
            store: &Store,
            operation: &str,
            requested_node_id: Uuid,
            pairing_id: Uuid,
        ) {
            assert_eq!(
                store.get_pairing_status(pairing_id).unwrap().phase,
                PairingPhaseV1::Revoked
            );
            assert!(matches!(
                store.create_pairing_idempotent(
                    operation,
                    Some(requested_node_id),
                    "https://changed.invalid:47832",
                    "changed certificate",
                ),
                Err(StoreError::PairingIdempotencyFinalized {
                    phase: PairingPhaseV1::Revoked
                })
            ));
        }

        let store = Store::in_memory().unwrap();
        let worker_url = "https://192.0.2.84:47832";
        let certificate = "-----BEGIN CERTIFICATE-----\nrevocation\n-----END CERTIFICATE-----\n";

        let pending_node_id = Uuid::new_v4();
        let pending_operation = "desktop-add-computer:revoked-pending";
        let pending = store
            .create_pairing_idempotent(
                pending_operation,
                Some(pending_node_id),
                worker_url,
                certificate,
            )
            .unwrap();
        store.revoke_pairing(pending.pairing.id).unwrap();
        assert_revoked_replay(
            &store,
            pending_operation,
            pending_node_id,
            pending.pairing.id,
        );

        let consumed_worker = node();
        let consumed_operation = "desktop-add-computer:revoked-consumed";
        let consumed = store
            .create_pairing_idempotent(
                consumed_operation,
                Some(consumed_worker.id),
                worker_url,
                certificate,
            )
            .unwrap();
        let consumed_credential = random_secret();
        let consumed_digest = secret_hash(&consumed_credential);
        store
            .consume_pairing(
                &consumed.pairing.code,
                consumed.pairing.id,
                consumed.pairing.intended_node_id,
                &consumed_digest,
                &consumed_worker,
            )
            .unwrap();
        store.revoke_pairing(consumed.pairing.id).unwrap();
        assert_revoked_replay(
            &store,
            consumed_operation,
            consumed_worker.id,
            consumed.pairing.id,
        );

        let mut ready_worker = node();
        ready_worker.id = Uuid::new_v4();
        let ready_operation = "desktop-add-computer:revoked-ready";
        let ready = store
            .create_pairing_idempotent(
                ready_operation,
                Some(ready_worker.id),
                worker_url,
                certificate,
            )
            .unwrap();
        let ready_credential = random_secret();
        let ready_digest = secret_hash(&ready_credential);
        store
            .consume_pairing(
                &ready.pairing.code,
                ready.pairing.id,
                ready.pairing.intended_node_id,
                &ready_digest,
                &ready_worker,
            )
            .unwrap();
        store
            .acknowledge_pairing(
                &ready_credential,
                ready.pairing.id,
                ready_worker.id,
                &ready_digest,
            )
            .unwrap();
        store.revoke_pairing(ready.pairing.id).unwrap();
        assert_revoked_replay(&store, ready_operation, ready_worker.id, ready.pairing.id);

        let failed_node_id = Uuid::new_v4();
        let failed_operation = "desktop-add-computer:revoked-failed";
        let failed = store
            .create_pairing_idempotent(
                failed_operation,
                Some(failed_node_id),
                worker_url,
                certificate,
            )
            .unwrap();
        store
            .fail_pairing(failed.pairing.id, PairingFailureCodeV1::WorkerInstallFailed)
            .unwrap();
        store.revoke_pairing(failed.pairing.id).unwrap();
        assert_revoked_replay(&store, failed_operation, failed_node_id, failed.pairing.id);
    }

    #[test]
    fn ack_requires_consumed_exact_binding_and_existing_node_without_mutation() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let old = pair_worker(&store, &worker);
        let pairing = store.create_pairing_for(Some(worker.id)).unwrap();
        let credential = random_secret();
        let digest = secret_hash(&credential);
        let consumed = store
            .consume_pairing(
                &pairing.code,
                pairing.id,
                pairing.intended_node_id,
                &digest,
                &worker,
            )
            .unwrap();
        assert!(store.preauthorize_pairing_ack(&credential).is_ok());

        let assert_unmutated = || {
            let state = store
                .connection()
                .unwrap()
                .query_row(
                    r#"
                    SELECT
                      (SELECT revoked_at FROM worker_credentials WHERE pairing_id = ?1),
                      (SELECT activated_at FROM worker_credentials
                       WHERE pairing_id = ?2 AND credential_hash = ?3),
                      (SELECT revoked_at FROM worker_credentials
                       WHERE pairing_id = ?2 AND credential_hash = ?3),
                      (SELECT acknowledged_at FROM pairings WHERE id = ?2)
                    "#,
                    params![old.pairing_id.to_string(), pairing.id.to_string(), digest],
                    |row| {
                        Ok((
                            row.get::<_, Option<i64>>(0)?,
                            row.get::<_, Option<i64>>(1)?,
                            row.get::<_, Option<i64>>(2)?,
                            row.get::<_, Option<i64>>(3)?,
                        ))
                    },
                )
                .unwrap();
            assert_eq!(state, (None, None, None, None));
        };

        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE pairings SET intended_node_id = ?1 WHERE id = ?2",
                params![Uuid::new_v4().to_string(), pairing.id.to_string()],
            )
            .unwrap();
        assert!(matches!(
            store.preauthorize_pairing_ack(&credential),
            Err(StoreError::PairingAcknowledgementUnavailable)
        ));
        assert!(matches!(
            store.acknowledge_pairing(&credential, pairing.id, worker.id, &digest),
            Err(StoreError::PairingAcknowledgementUnavailable)
        ));
        assert_unmutated();

        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE pairings SET intended_node_id = ?1 WHERE id = ?2",
                params![worker.id.to_string(), pairing.id.to_string()],
            )
            .unwrap();
        store
            .connection()
            .unwrap()
            .execute("DELETE FROM nodes WHERE id = ?1", [worker.id.to_string()])
            .unwrap();
        assert!(matches!(
            store.preauthorize_pairing_ack(&credential),
            Err(StoreError::PairingAcknowledgementUnavailable)
        ));
        assert!(matches!(
            store.acknowledge_pairing(&credential, pairing.id, worker.id, &digest),
            Err(StoreError::PairingAcknowledgementUnavailable)
        ));
        assert_unmutated();

        store.upsert_node(&worker).unwrap();
        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE pairings SET used_at = NULL WHERE id = ?1",
                [pairing.id.to_string()],
            )
            .unwrap();
        assert!(matches!(
            store.preauthorize_pairing_ack(&credential),
            Err(StoreError::PairingAcknowledgementUnavailable)
        ));
        assert!(matches!(
            store.acknowledge_pairing(&credential, pairing.id, worker.id, &digest),
            Err(StoreError::PairingAcknowledgementUnavailable)
        ));
        assert_unmutated();

        let mut other = node();
        other.id = Uuid::new_v4();
        store.upsert_node(&other).unwrap();
        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE pairings SET used_at = ?1 WHERE id = ?2",
                params![consumed.consumed_at.timestamp(), pairing.id.to_string()],
            )
            .unwrap();
        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE worker_credentials SET node_id = ?1 WHERE pairing_id = ?2",
                params![other.id.to_string(), pairing.id.to_string()],
            )
            .unwrap();
        assert!(matches!(
            store.preauthorize_pairing_ack(&credential),
            Err(StoreError::PairingAcknowledgementUnavailable)
        ));
        assert!(matches!(
            store.acknowledge_pairing(&credential, pairing.id, worker.id, &digest),
            Err(StoreError::PairingAcknowledgementUnavailable)
        ));
        assert_unmutated();

        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE worker_credentials SET node_id = ?1 WHERE pairing_id = ?2",
                params![worker.id.to_string(), pairing.id.to_string()],
            )
            .unwrap();
        store
            .connection()
            .unwrap()
            .execute(
                r#"
                INSERT INTO worker_credentials(
                    id, pairing_id, node_id, credential_hash, created_at,
                    activated_at, last_used_at, revoked_at
                ) VALUES (?1, ?2, ?3, ?4, ?5, NULL, NULL, NULL)
                "#,
                params![
                    Uuid::new_v4().to_string(),
                    pairing.id.to_string(),
                    worker.id.to_string(),
                    secret_hash("corrupt-extra-ack-credential"),
                    Utc::now().timestamp(),
                ],
            )
            .unwrap();
        assert!(matches!(
            store.preauthorize_pairing_ack(&credential),
            Err(StoreError::PairingAcknowledgementUnavailable)
        ));
        assert!(matches!(
            store.acknowledge_pairing(&credential, pairing.id, worker.id, &digest),
            Err(StoreError::PairingAcknowledgementUnavailable)
        ));
        assert_unmutated();
    }

    #[test]
    fn pairing_pending_invariant_and_exact_consumed_replay_are_enforced() {
        let store = Store::in_memory().unwrap();

        let node_corrupt_worker = node();
        let node_corrupt = store
            .create_pairing_for(Some(node_corrupt_worker.id))
            .unwrap();
        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE pairings SET node_id = ?1 WHERE id = ?2",
                params![Uuid::new_v4().to_string(), node_corrupt.id.to_string()],
            )
            .unwrap();
        let node_corrupt_before = store
            .connection()
            .unwrap()
            .query_row(
                r#"
                SELECT used_at, acknowledged_at, node_id,
                  (SELECT COUNT(*) FROM worker_credentials wc WHERE wc.pairing_id = pairings.id)
                FROM pairings WHERE id = ?1
                "#,
                [node_corrupt.id.to_string()],
                |row| {
                    Ok((
                        row.get::<_, Option<i64>>(0)?,
                        row.get::<_, Option<i64>>(1)?,
                        row.get::<_, Option<String>>(2)?,
                        row.get::<_, i64>(3)?,
                    ))
                },
            )
            .unwrap();
        assert!(matches!(
            store.preauthorize_pairing(&node_corrupt.code),
            Err(StoreError::PairingUnavailable)
        ));
        assert!(matches!(
            store.consume_pairing(
                &node_corrupt.code,
                node_corrupt.id,
                node_corrupt.intended_node_id,
                &secret_hash("node-corrupt-new-credential"),
                &node_corrupt_worker,
            ),
            Err(StoreError::PairingUnavailable)
        ));
        let node_corrupt_after = store
            .connection()
            .unwrap()
            .query_row(
                r#"
                SELECT used_at, acknowledged_at, node_id,
                  (SELECT COUNT(*) FROM worker_credentials wc WHERE wc.pairing_id = pairings.id)
                FROM pairings WHERE id = ?1
                "#,
                [node_corrupt.id.to_string()],
                |row| {
                    Ok((
                        row.get::<_, Option<i64>>(0)?,
                        row.get::<_, Option<i64>>(1)?,
                        row.get::<_, Option<String>>(2)?,
                        row.get::<_, i64>(3)?,
                    ))
                },
            )
            .unwrap();
        assert_eq!(node_corrupt_after, node_corrupt_before);
        assert!(!store
            .list_nodes()
            .unwrap()
            .iter()
            .any(|node| node.id == node_corrupt_worker.id));

        let ack_corrupt_worker = node();
        let ack_corrupt = store
            .create_pairing_for(Some(ack_corrupt_worker.id))
            .unwrap();
        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE pairings SET acknowledged_at = ?1 WHERE id = ?2",
                params![Utc::now().timestamp(), ack_corrupt.id.to_string()],
            )
            .unwrap();
        let ack_corrupt_before = store
            .connection()
            .unwrap()
            .query_row(
                "SELECT used_at, acknowledged_at, node_id FROM pairings WHERE id = ?1",
                [ack_corrupt.id.to_string()],
                |row| {
                    Ok((
                        row.get::<_, Option<i64>>(0)?,
                        row.get::<_, Option<i64>>(1)?,
                        row.get::<_, Option<String>>(2)?,
                    ))
                },
            )
            .unwrap();
        assert!(matches!(
            store.preauthorize_pairing(&ack_corrupt.code),
            Err(StoreError::PairingUnavailable)
        ));
        assert!(matches!(
            store.consume_pairing(
                &ack_corrupt.code,
                ack_corrupt.id,
                ack_corrupt.intended_node_id,
                &secret_hash("ack-corrupt-new-credential"),
                &ack_corrupt_worker,
            ),
            Err(StoreError::PairingUnavailable)
        ));
        let ack_corrupt_after = store
            .connection()
            .unwrap()
            .query_row(
                "SELECT used_at, acknowledged_at, node_id FROM pairings WHERE id = ?1",
                [ack_corrupt.id.to_string()],
                |row| {
                    Ok((
                        row.get::<_, Option<i64>>(0)?,
                        row.get::<_, Option<i64>>(1)?,
                        row.get::<_, Option<String>>(2)?,
                    ))
                },
            )
            .unwrap();
        assert_eq!(ack_corrupt_after, ack_corrupt_before);
        assert!(!store
            .list_nodes()
            .unwrap()
            .iter()
            .any(|node| node.id == ack_corrupt_worker.id));

        let credential_corrupt_worker = node();
        let credential_corrupt = store
            .create_pairing_for(Some(credential_corrupt_worker.id))
            .unwrap();
        store
            .connection()
            .unwrap()
            .execute(
                r#"
                INSERT INTO worker_credentials(
                    id, pairing_id, node_id, credential_hash, created_at,
                    activated_at, last_used_at, revoked_at
                ) VALUES (?1, ?2, ?3, ?4, ?5, NULL, NULL, NULL)
                "#,
                params![
                    Uuid::new_v4().to_string(),
                    credential_corrupt.id.to_string(),
                    credential_corrupt_worker.id.to_string(),
                    secret_hash("preexisting-pending-credential"),
                    Utc::now().timestamp(),
                ],
            )
            .unwrap();
        assert!(matches!(
            store.preauthorize_pairing(&credential_corrupt.code),
            Err(StoreError::PairingUnavailable)
        ));
        assert!(matches!(
            store.consume_pairing(
                &credential_corrupt.code,
                credential_corrupt.id,
                credential_corrupt.intended_node_id,
                &secret_hash("credential-corrupt-new-credential"),
                &credential_corrupt_worker,
            ),
            Err(StoreError::PairingUnavailable)
        ));
        let credential_corrupt_shape = store
            .connection()
            .unwrap()
            .query_row(
                r#"
                SELECT used_at, acknowledged_at, node_id,
                  (SELECT COUNT(*) FROM worker_credentials wc WHERE wc.pairing_id = pairings.id)
                FROM pairings WHERE id = ?1
                "#,
                [credential_corrupt.id.to_string()],
                |row| {
                    Ok((
                        row.get::<_, Option<i64>>(0)?,
                        row.get::<_, Option<i64>>(1)?,
                        row.get::<_, Option<String>>(2)?,
                        row.get::<_, i64>(3)?,
                    ))
                },
            )
            .unwrap();
        assert_eq!(credential_corrupt_shape, (None, None, None, 1));
        assert!(!store
            .list_nodes()
            .unwrap()
            .iter()
            .any(|node| node.id == credential_corrupt_worker.id));

        let consumed_worker = node();
        let consumed_pairing = store.create_pairing_for(Some(consumed_worker.id)).unwrap();
        let consumed_credential = random_secret();
        let consumed_digest = secret_hash(&consumed_credential);
        let consumed = store
            .consume_pairing(
                &consumed_pairing.code,
                consumed_pairing.id,
                consumed_pairing.intended_node_id,
                &consumed_digest,
                &consumed_worker,
            )
            .unwrap();
        assert!(store.preauthorize_pairing(&consumed_pairing.code).is_ok());
        let replay = store
            .consume_pairing(
                &consumed_pairing.code,
                consumed_pairing.id,
                consumed_pairing.intended_node_id,
                &consumed_digest,
                &consumed_worker,
            )
            .unwrap();
        assert!(replay.replayed);
        assert_eq!(replay.consumed_at, consumed.consumed_at);

        store
            .connection()
            .unwrap()
            .execute(
                r#"
                INSERT INTO worker_credentials(
                    id, pairing_id, node_id, credential_hash, created_at,
                    activated_at, last_used_at, revoked_at
                ) VALUES (?1, ?2, ?3, ?4, ?5, NULL, NULL, NULL)
                "#,
                params![
                    Uuid::new_v4().to_string(),
                    consumed_pairing.id.to_string(),
                    consumed_worker.id.to_string(),
                    secret_hash("extra-consumed-credential"),
                    Utc::now().timestamp(),
                ],
            )
            .unwrap();
        assert!(matches!(
            store.preauthorize_pairing(&consumed_pairing.code),
            Err(StoreError::PairingUnavailable)
        ));
        assert!(matches!(
            store.consume_pairing(
                &consumed_pairing.code,
                consumed_pairing.id,
                consumed_pairing.intended_node_id,
                &consumed_digest,
                &consumed_worker,
            ),
            Err(StoreError::PairingUnavailable)
        ));
        let consumed_shape = store
            .connection()
            .unwrap()
            .query_row(
                r#"
                SELECT used_at, acknowledged_at, node_id,
                  (SELECT COUNT(*) FROM worker_credentials wc WHERE wc.pairing_id = pairings.id)
                FROM pairings WHERE id = ?1
                "#,
                [consumed_pairing.id.to_string()],
                |row| {
                    Ok((
                        row.get::<_, Option<i64>>(0)?,
                        row.get::<_, Option<i64>>(1)?,
                        row.get::<_, Option<String>>(2)?,
                        row.get::<_, i64>(3)?,
                    ))
                },
            )
            .unwrap();
        assert_eq!(consumed_shape.0, Some(consumed.consumed_at.timestamp()));
        assert!(consumed_shape.1.is_none());
        assert_eq!(consumed_shape.2, Some(consumed_worker.id.to_string()));
        assert_eq!(consumed_shape.3, 2);

        let ready_worker = node();
        let ready_pairing = store.create_pairing_for(Some(ready_worker.id)).unwrap();
        let ready_credential = random_secret();
        let ready_digest = secret_hash(&ready_credential);
        store
            .consume_pairing(
                &ready_pairing.code,
                ready_pairing.id,
                ready_pairing.intended_node_id,
                &ready_digest,
                &ready_worker,
            )
            .unwrap();
        store
            .acknowledge_pairing(
                &ready_credential,
                ready_pairing.id,
                ready_worker.id,
                &ready_digest,
            )
            .unwrap();
        assert!(matches!(
            store.preauthorize_pairing(&ready_pairing.code),
            Err(StoreError::PairingUnavailable)
        ));
        assert!(matches!(
            store.consume_pairing(
                &ready_pairing.code,
                ready_pairing.id,
                ready_pairing.intended_node_id,
                &ready_digest,
                &ready_worker,
            ),
            Err(StoreError::PairingUnavailable)
        ));
    }

    #[test]
    fn pairing_status_distinguishes_pending_expired_and_revoked() {
        let store = Store::in_memory().unwrap();
        let pending = store.create_pairing().unwrap();
        assert_eq!(
            store.get_pairing_status(pending.id).unwrap().phase,
            PairingPhaseV1::Pending
        );
        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE pairings SET expires_at = ?1 WHERE id = ?2",
                params![
                    (Utc::now() - chrono::Duration::seconds(1)).timestamp(),
                    pending.id.to_string()
                ],
            )
            .unwrap();
        assert_eq!(
            store.get_pairing_status(pending.id).unwrap().phase,
            PairingPhaseV1::Expired
        );
        store.revoke_pairing(pending.id).unwrap();
        assert_eq!(
            store.get_pairing_status(pending.id).unwrap().phase,
            PairingPhaseV1::Revoked
        );
    }

    #[test]
    fn pending_pairing_failure_is_bounded_idempotent_and_blocks_enrollment() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let pairing = store.create_pairing_for(Some(worker.id)).unwrap();

        store
            .fail_pairing(pairing.id, PairingFailureCodeV1::WorkerInstallFailed)
            .unwrap();
        let first = store.get_pairing_status(pairing.id).unwrap();
        assert_eq!(first.phase, PairingPhaseV1::Failed);
        assert_eq!(
            first.failure_code,
            Some(PairingFailureCodeV1::WorkerInstallFailed)
        );
        let first_failed_at = first.failed_at.unwrap();

        store
            .fail_pairing(pairing.id, PairingFailureCodeV1::WorkerInstallFailed)
            .unwrap();
        assert_eq!(
            store.get_pairing_status(pairing.id).unwrap().failed_at,
            Some(first_failed_at)
        );
        assert!(matches!(
            store.fail_pairing(pairing.id, PairingFailureCodeV1::WorkerPairingFailed),
            Err(StoreError::PairingFailureMismatch)
        ));
        assert!(matches!(
            store.preauthorize_pairing(&pairing.code),
            Err(StoreError::PairingUnavailable)
        ));

        let credential = random_secret();
        assert!(matches!(
            store.consume_pairing(
                &pairing.code,
                pairing.id,
                pairing.intended_node_id,
                &secret_hash(&credential),
                &worker,
            ),
            Err(StoreError::PairingUnavailable)
        ));

        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE pairings SET expires_at = ?1 WHERE id = ?2",
                params![
                    (Utc::now() - chrono::Duration::seconds(1)).timestamp(),
                    pairing.id.to_string()
                ],
            )
            .unwrap();
        assert_eq!(
            store.get_pairing_status(pairing.id).unwrap().phase,
            PairingPhaseV1::Failed
        );
    }

    #[test]
    fn failed_idempotent_pairing_cannot_reexport_its_bundle() {
        let store = Store::in_memory().unwrap();
        let operation = "desktop-add-computer:failed-replay";
        let intended = Uuid::new_v4();
        let issued = store
            .create_pairing_idempotent(
                operation,
                Some(intended),
                "https://192.0.2.10:47832",
                "-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----\n",
            )
            .unwrap();
        store
            .fail_pairing(issued.pairing.id, PairingFailureCodeV1::ProvisioningFailed)
            .unwrap();
        assert!(matches!(
            store.create_pairing_idempotent(
                operation,
                Some(intended),
                "https://listener-changed.invalid:47832",
                "different certificate",
            ),
            Err(StoreError::PairingIdempotencyFinalized {
                phase: PairingPhaseV1::Failed
            })
        ));
    }

    #[test]
    fn pairing_failure_rejects_every_other_terminal_phase() {
        let store = Store::in_memory().unwrap();

        let expired = store.create_pairing().unwrap();
        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE pairings SET expires_at = ?1 WHERE id = ?2",
                params![
                    (Utc::now() - chrono::Duration::seconds(1)).timestamp(),
                    expired.id.to_string()
                ],
            )
            .unwrap();
        assert!(matches!(
            store.fail_pairing(expired.id, PairingFailureCodeV1::ProvisioningFailed),
            Err(StoreError::PairingFailureFinalized {
                phase: PairingPhaseV1::Expired
            })
        ));

        let revoked = store.create_pairing().unwrap();
        store.revoke_pairing(revoked.id).unwrap();
        assert!(matches!(
            store.fail_pairing(revoked.id, PairingFailureCodeV1::ProvisioningFailed),
            Err(StoreError::PairingFailureFinalized {
                phase: PairingPhaseV1::Revoked
            })
        ));

        let worker = node();
        let consumed = store.create_pairing_for(Some(worker.id)).unwrap();
        let credential = random_secret();
        let digest = secret_hash(&credential);
        store
            .consume_pairing(
                &consumed.code,
                consumed.id,
                consumed.intended_node_id,
                &digest,
                &worker,
            )
            .unwrap();
        assert!(matches!(
            store.fail_pairing(consumed.id, PairingFailureCodeV1::WorkerPairingFailed),
            Err(StoreError::PairingFailureFinalized {
                phase: PairingPhaseV1::Consumed
            })
        ));
        store
            .acknowledge_pairing(&credential, consumed.id, worker.id, &digest)
            .unwrap();
        assert!(matches!(
            store.fail_pairing(consumed.id, PairingFailureCodeV1::WorkerHealthCheckFailed),
            Err(StoreError::PairingFailureFinalized {
                phase: PairingPhaseV1::Ready
            })
        ));
    }

    #[test]
    fn revoking_failed_pairing_retains_failure_evidence_but_hides_failed_phase() {
        let store = Store::in_memory().unwrap();
        let pairing = store.create_pairing().unwrap();
        store
            .fail_pairing(pairing.id, PairingFailureCodeV1::WorkerHealthCheckFailed)
            .unwrap();
        let failed = store.get_pairing_status(pairing.id).unwrap();

        store.revoke_pairing(pairing.id).unwrap();
        let revoked = store.get_pairing_status(pairing.id).unwrap();
        assert_eq!(revoked.phase, PairingPhaseV1::Revoked);
        assert_eq!(revoked.failed_at, failed.failed_at);
        assert_eq!(revoked.failure_code, failed.failure_code);
        assert!(matches!(
            store.fail_pairing(pairing.id, PairingFailureCodeV1::WorkerHealthCheckFailed),
            Err(StoreError::PairingFailureFinalized {
                phase: PairingPhaseV1::Revoked
            })
        ));
    }

    #[test]
    fn pairing_failure_corruption_fails_closed() {
        let store = Store::in_memory().unwrap();
        let pairing = store.create_pairing().unwrap();
        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE pairings SET failed_at = ?1 WHERE id = ?2",
                params![Utc::now().timestamp(), pairing.id.to_string()],
            )
            .unwrap();
        assert!(matches!(
            store.get_pairing_status(pairing.id),
            Err(StoreError::InvalidPairingFailureState)
        ));
        assert!(matches!(
            store.fail_pairing(pairing.id, PairingFailureCodeV1::ProvisioningFailed),
            Err(StoreError::InvalidPairingFailureState)
        ));

        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE pairings SET failure_code = 'unbounded_failure' WHERE id = ?1",
                [pairing.id.to_string()],
            )
            .unwrap();
        assert!(matches!(
            store.get_pairing_status(pairing.id),
            Err(StoreError::InvalidPairingFailureState)
        ));
    }

    #[test]
    fn corrupted_consumed_failure_cannot_authorize_or_acknowledge() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let pairing = store.create_pairing_for(Some(worker.id)).unwrap();
        let credential = random_secret();
        let digest = secret_hash(&credential);
        store
            .consume_pairing(
                &pairing.code,
                pairing.id,
                pairing.intended_node_id,
                &digest,
                &worker,
            )
            .unwrap();
        store
            .connection()
            .unwrap()
            .execute(
                r#"
                UPDATE pairings SET failed_at = ?1, failure_code = 'worker_pairing_failed'
                WHERE id = ?2
                "#,
                params![Utc::now().timestamp(), pairing.id.to_string()],
            )
            .unwrap();

        assert!(matches!(
            store.preauthorize_pairing_ack(&credential),
            Err(StoreError::PairingAcknowledgementUnavailable)
        ));
        assert!(matches!(
            store.acknowledge_pairing(&credential, pairing.id, worker.id, &digest),
            Err(StoreError::PairingAcknowledgementUnavailable)
        ));
    }

    #[test]
    fn extra_pairing_credentials_cannot_authenticate_report_or_schedule() {
        type CapabilityState = (
            Option<i64>,
            i64,
            String,
            String,
            String,
            Option<i64>,
            Option<i64>,
            Option<i64>,
            Option<i64>,
            Option<String>,
            Option<i64>,
        );

        #[derive(Clone, Copy)]
        enum ExtraKind {
            Staged,
            Revoked,
            Misbound,
        }

        impl ExtraKind {
            fn label(self) -> &'static str {
                match self {
                    Self::Staged => "staged",
                    Self::Revoked => "revoked",
                    Self::Misbound => "misbound",
                }
            }
        }

        fn capability_state(
            store: &Store,
            pairing_id: Uuid,
            credential_hash: &str,
            extra_id: Uuid,
        ) -> CapabilityState {
            store
                .connection()
                .unwrap()
                .query_row(
                    r#"
                    SELECT
                        wc.last_used_at,
                        n.revision,
                        i.document,
                        t.document,
                        t.received_at,
                        p.used_at,
                        p.acknowledged_at,
                        p.revoked_at,
                        p.failed_at,
                        p.failure_code,
                        (
                            SELECT extra.last_used_at FROM worker_credentials extra
                            WHERE extra.id = ?3
                        )
                    FROM worker_credentials wc
                    JOIN pairings p ON p.id = wc.pairing_id
                    JOIN nodes n ON n.id = wc.node_id
                    JOIN node_inventories i ON i.node_id = n.id
                    JOIN node_telemetry t ON t.node_id = n.id
                    WHERE wc.pairing_id = ?1 AND wc.credential_hash = ?2
                    "#,
                    params![
                        pairing_id.to_string(),
                        credential_hash,
                        extra_id.to_string()
                    ],
                    |row| {
                        Ok((
                            row.get::<_, Option<i64>>(0)?,
                            row.get::<_, i64>(1)?,
                            row.get::<_, String>(2)?,
                            row.get::<_, String>(3)?,
                            row.get::<_, String>(4)?,
                            row.get::<_, Option<i64>>(5)?,
                            row.get::<_, Option<i64>>(6)?,
                            row.get::<_, Option<i64>>(7)?,
                            row.get::<_, Option<i64>>(8)?,
                            row.get::<_, Option<String>>(9)?,
                            row.get::<_, Option<i64>>(10)?,
                        ))
                    },
                )
                .unwrap()
        }

        for kind in [ExtraKind::Staged, ExtraKind::Revoked, ExtraKind::Misbound] {
            let store = Store::in_memory().unwrap();
            let worker = node();
            let paired = pair_worker(&store, &worker);
            let boot_id = Uuid::new_v4();
            store
                .record_node_report(&paired.credential, &node_report(&worker, boot_id, 1))
                .unwrap();
            assert!(store.create_plan(&job(), &Scheduler::default()).is_ok());

            let credential_hash = secret_hash(&paired.credential);
            store
                .connection()
                .unwrap()
                .execute(
                    "UPDATE worker_credentials SET last_used_at = 123 WHERE credential_hash = ?1",
                    [&credential_hash],
                )
                .unwrap();

            let extra_id = Uuid::new_v4();
            let now = Utc::now().timestamp();
            let (extra_node_id, activated_at, revoked_at) = match kind {
                ExtraKind::Staged => (worker.id, None, None),
                ExtraKind::Revoked => (worker.id, Some(now), Some(now)),
                ExtraKind::Misbound => (Uuid::new_v4(), None, None),
            };
            store
                .connection()
                .unwrap()
                .execute(
                    r#"
                    INSERT INTO worker_credentials(
                        id, pairing_id, node_id, credential_hash, created_at,
                        activated_at, last_used_at, revoked_at
                    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, NULL, ?7)
                    "#,
                    params![
                        extra_id.to_string(),
                        paired.pairing_id.to_string(),
                        extra_node_id.to_string(),
                        secret_hash(&format!("capability-extra-{}", kind.label())),
                        now,
                        activated_at,
                        revoked_at,
                    ],
                )
                .unwrap();

            let before = capability_state(&store, paired.pairing_id, &credential_hash, extra_id);
            assert_eq!(before.0, Some(123));
            assert!(before.10.is_none());

            assert!(matches!(
                store.authenticate_worker(&paired.credential),
                Err(StoreError::WorkerUnauthorized)
            ));
            assert!(matches!(
                store.record_node_report(&paired.credential, &node_report(&worker, boot_id, 2),),
                Err(StoreError::WorkerUnauthorized)
            ));
            assert!(matches!(
                store.create_plan(&job(), &Scheduler::default()),
                Err(StoreError::Schedule(ScheduleError::NoEligibleNodes { .. }))
            ));
            assert!(matches!(
                store.get_pairing_status(paired.pairing_id),
                Err(StoreError::InvalidPairingFailureState)
            ));
            assert_eq!(
                capability_state(&store, paired.pairing_id, &credential_hash, extra_id,),
                before,
                "{} extra mutated capability state",
                kind.label()
            );
        }
    }

    #[test]
    fn failed_pairing_credential_cannot_authenticate_report_schedule_or_migrate() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let paired = pair_worker(&store, &worker);
        store
            .record_node_report(&paired.credential, &node_report(&worker, Uuid::new_v4(), 1))
            .unwrap();
        assert!(store.create_plan(&job(), &Scheduler::default()).is_ok());
        let last_used_before_failure = store
            .connection()
            .unwrap()
            .query_row(
                "SELECT last_used_at FROM worker_credentials WHERE pairing_id = ?1",
                [paired.pairing_id.to_string()],
                |row| row.get::<_, Option<i64>>(0),
            )
            .unwrap();

        store
            .connection()
            .unwrap()
            .execute(
                r#"
                UPDATE pairings
                SET failed_at = ?1, failure_code = 'worker_health_check_failed'
                WHERE id = ?2
                "#,
                params![Utc::now().timestamp(), paired.pairing_id.to_string()],
            )
            .unwrap();

        assert!(matches!(
            store.authenticate_worker(&paired.credential),
            Err(StoreError::WorkerUnauthorized)
        ));
        assert!(matches!(
            store.record_node_report(&paired.credential, &node_report(&worker, Uuid::new_v4(), 2)),
            Err(StoreError::WorkerUnauthorized)
        ));
        assert!(matches!(
            store.create_plan(&job(), &Scheduler::default()),
            Err(StoreError::Schedule(ScheduleError::NoEligibleNodes { .. }))
        ));
        let last_used_after_failure = store
            .connection()
            .unwrap()
            .query_row(
                "SELECT last_used_at FROM worker_credentials WHERE pairing_id = ?1",
                [paired.pairing_id.to_string()],
                |row| row.get::<_, Option<i64>>(0),
            )
            .unwrap();
        assert_eq!(last_used_after_failure, last_used_before_failure);
        assert!(matches!(
            store.get_pairing_status(paired.pairing_id),
            Err(StoreError::InvalidPairingFailureState)
        ));
        let mut connection = store.connection().unwrap();
        assert!(matches!(
            migrate_pairing_failure_schema(&mut connection),
            Err(StoreError::InvalidPairingFailureState)
        ));
    }

    #[test]
    fn corrupt_nominal_pending_pairing_with_node_or_credential_is_not_mutated() {
        let store = Store::in_memory().unwrap();
        let node_bound = store.create_pairing().unwrap();
        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE pairings SET node_id = ?1 WHERE id = ?2",
                params![Uuid::new_v4().to_string(), node_bound.id.to_string()],
            )
            .unwrap();

        assert!(matches!(
            store.fail_pairing(node_bound.id, PairingFailureCodeV1::WorkerPairingFailed),
            Err(StoreError::InvalidPairingFailureState)
        ));
        let node_bound_failure = store
            .connection()
            .unwrap()
            .query_row(
                "SELECT failed_at, failure_code FROM pairings WHERE id = ?1",
                [node_bound.id.to_string()],
                |row| {
                    Ok((
                        row.get::<_, Option<i64>>(0)?,
                        row.get::<_, Option<String>>(1)?,
                    ))
                },
            )
            .unwrap();
        assert_eq!(node_bound_failure, (None, None));

        let credential_bound = store.create_pairing().unwrap();
        store
            .connection()
            .unwrap()
            .execute(
                r#"
                INSERT INTO worker_credentials(
                    id, pairing_id, node_id, credential_hash, created_at,
                    activated_at, last_used_at, revoked_at
                ) VALUES (?1, ?2, ?3, ?4, ?5, NULL, NULL, NULL)
                "#,
                params![
                    Uuid::new_v4().to_string(),
                    credential_bound.id.to_string(),
                    credential_bound.intended_node_id.to_string(),
                    secret_hash("staged-corrupt-pending-credential"),
                    Utc::now().timestamp(),
                ],
            )
            .unwrap();

        assert!(matches!(
            store.fail_pairing(
                credential_bound.id,
                PairingFailureCodeV1::WorkerInstallFailed
            ),
            Err(StoreError::InvalidPairingFailureState)
        ));
        let credential_bound_failure = store
            .connection()
            .unwrap()
            .query_row(
                "SELECT failed_at, failure_code FROM pairings WHERE id = ?1",
                [credential_bound.id.to_string()],
                |row| {
                    Ok((
                        row.get::<_, Option<i64>>(0)?,
                        row.get::<_, Option<String>>(1)?,
                    ))
                },
            )
            .unwrap();
        assert_eq!(credential_bound_failure, (None, None));
    }

    #[test]
    fn failed_pairing_with_only_staged_credential_fails_runtime_and_migration_validation() {
        let store = Store::in_memory().unwrap();
        let pairing = store.create_pairing().unwrap();
        store
            .connection()
            .unwrap()
            .execute(
                r#"
                INSERT INTO worker_credentials(
                    id, pairing_id, node_id, credential_hash, created_at,
                    activated_at, last_used_at, revoked_at
                ) VALUES (?1, ?2, ?3, ?4, ?5, NULL, NULL, NULL)
                "#,
                params![
                    Uuid::new_v4().to_string(),
                    pairing.id.to_string(),
                    pairing.intended_node_id.to_string(),
                    secret_hash("staged-corrupt-failed-credential"),
                    Utc::now().timestamp(),
                ],
            )
            .unwrap();
        store
            .connection()
            .unwrap()
            .execute(
                r#"
                UPDATE pairings
                SET failed_at = ?1, failure_code = 'provisioning_failed'
                WHERE id = ?2
                "#,
                params![Utc::now().timestamp(), pairing.id.to_string()],
            )
            .unwrap();

        assert!(matches!(
            store.get_pairing_status(pairing.id),
            Err(StoreError::InvalidPairingFailureState)
        ));
        let mut connection = store.connection().unwrap();
        assert!(matches!(
            migrate_pairing_failure_schema(&mut connection),
            Err(StoreError::InvalidPairingFailureState)
        ));
    }

    #[test]
    fn partial_pairing_failure_schema_is_rejected() {
        let connection = Connection::open_in_memory().unwrap();
        connection
            .execute_batch(
                r#"
                CREATE TABLE pairings (
                    id TEXT PRIMARY KEY NOT NULL,
                    code_hash TEXT UNIQUE NOT NULL,
                    created_at INTEGER NOT NULL,
                    expires_at INTEGER NOT NULL,
                    used_at INTEGER,
                    acknowledged_at INTEGER,
                    revoked_at INTEGER,
                    node_id TEXT,
                    intended_node_id TEXT,
                    failed_at INTEGER
                );
                "#,
            )
            .unwrap();
        assert!(matches!(
            Store::from_connection(
                connection,
                std::env::temp_dir().join(format!("cyc-partial-failure-{}", Uuid::new_v4()))
            ),
            Err(StoreError::InvalidPairingFailureState)
        ));
    }

    #[test]
    fn unknown_pairing_failure_code_blocks_database_migration() {
        let connection = Connection::open_in_memory().unwrap();
        connection
            .execute_batch(
                r#"
                CREATE TABLE pairings (
                    id TEXT PRIMARY KEY NOT NULL,
                    code_hash TEXT UNIQUE NOT NULL,
                    created_at INTEGER NOT NULL,
                    expires_at INTEGER NOT NULL,
                    used_at INTEGER,
                    acknowledged_at INTEGER,
                    revoked_at INTEGER,
                    node_id TEXT,
                    intended_node_id TEXT,
                    failed_at INTEGER,
                    failure_code TEXT
                );
                "#,
            )
            .unwrap();
        let pairing_id = Uuid::new_v4();
        let intended_node_id = Uuid::new_v4();
        connection
            .execute(
                r#"
                INSERT INTO pairings(
                    id, code_hash, created_at, expires_at, intended_node_id,
                    failed_at, failure_code
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?3, 'unbounded_failure')
                "#,
                params![
                    pairing_id.to_string(),
                    secret_hash("migration-corruption"),
                    Utc::now().timestamp(),
                    (Utc::now() + chrono::Duration::minutes(10)).timestamp(),
                    intended_node_id.to_string(),
                ],
            )
            .unwrap();
        assert!(matches!(
            Store::from_connection(
                connection,
                std::env::temp_dir().join(format!("cyc-invalid-failure-{}", Uuid::new_v4()))
            ),
            Err(StoreError::InvalidPairingFailureState)
        ));
    }

    #[test]
    fn consume_and_failure_race_has_exactly_one_terminal_winner() {
        let directory = test_directory("pairing-failure-race");
        std::fs::create_dir_all(&directory).unwrap();
        let database = directory.join("controller.db");
        let first_store = Store::from_connection(
            Connection::open(&database).unwrap(),
            directory.join("first-objects"),
        )
        .unwrap();
        let second_store = Store::from_connection(
            Connection::open(&database).unwrap(),
            directory.join("second-objects"),
        )
        .unwrap();
        let worker = node();
        let pairing = first_store.create_pairing_for(Some(worker.id)).unwrap();
        let pairing_id = pairing.id;
        let intended_node_id = pairing.intended_node_id;
        let pairing_code = pairing.code.clone();
        let credential = random_secret();
        let digest = secret_hash(&credential);
        let barrier = Arc::new(std::sync::Barrier::new(3));

        let consume_barrier = barrier.clone();
        let consume_worker = worker.clone();
        let consume = std::thread::spawn(move || {
            consume_barrier.wait();
            first_store.consume_pairing(
                &pairing_code,
                pairing_id,
                intended_node_id,
                &digest,
                &consume_worker,
            )
        });
        let fail_barrier = barrier.clone();
        let failure = std::thread::spawn(move || {
            fail_barrier.wait();
            second_store.fail_pairing(pairing_id, PairingFailureCodeV1::WorkerPairingFailed)
        });
        barrier.wait();
        let consume = consume.join().unwrap();
        let failure = failure.join().unwrap();

        assert_ne!(consume.is_ok(), failure.is_ok());
        let verification = Store::from_connection(
            Connection::open(&database).unwrap(),
            directory.join("verification-objects"),
        )
        .unwrap();
        match verification.get_pairing_status(pairing_id).unwrap().phase {
            PairingPhaseV1::Consumed => {
                assert!(consume.is_ok());
                assert!(matches!(
                    failure,
                    Err(StoreError::PairingFailureFinalized {
                        phase: PairingPhaseV1::Consumed
                    })
                ));
            }
            PairingPhaseV1::Failed => {
                assert!(failure.is_ok());
                assert!(matches!(consume, Err(StoreError::PairingUnavailable)));
            }
            phase => panic!("unexpected pairing race phase: {phase:?}"),
        }
        drop(verification);
        drop(pairing);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn concurrent_dual_connection_claim_is_single_winner_and_run_secret_isolated() {
        let directory = test_directory("concurrent-claim");
        std::fs::create_dir_all(&directory).unwrap();
        let database = directory.join("controller.db");
        let store = Store::open(&database).unwrap();
        let worker = node();
        let paired = pair_worker(&store, &worker);
        store
            .submit_job(&job(), None, &Scheduler::default())
            .unwrap();
        let barrier = Arc::new(std::sync::Barrier::new(3));
        let mut handles = Vec::new();
        for _ in 0..2 {
            let store = Store::open(&database).unwrap();
            let worker = worker.clone();
            let credential = paired.credential.clone();
            let barrier = barrier.clone();
            handles.push(std::thread::spawn(move || {
                barrier.wait();
                store.claim_job(&credential, &worker)
            }));
        }
        barrier.wait();
        let results = handles
            .into_iter()
            .map(|handle| handle.join().unwrap().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(results.iter().filter(|claim| claim.is_some()).count(), 1);
        let claim = results.into_iter().flatten().next().unwrap();
        assert_eq!(claim.stored.run.state, JobState::Preparing);
        assert_eq!(claim.stored.version, 1);

        let wrong_run_secret = random_secret();
        assert!(matches!(
            store.worker_heartbeat(
                &paired.credential,
                &wrong_run_secret,
                claim.stored.run.id,
                claim.lease_id,
                claim.stored.version,
                JobState::Preparing,
            ),
            Err(StoreError::RunUnauthorized)
        ));
        drop(store);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn concurrent_dual_connection_submit_reservation_has_one_winner() {
        let directory = test_directory("concurrent-submit");
        std::fs::create_dir_all(&directory).unwrap();
        let database = directory.join("controller.db");
        let primary = Store::open(&database).unwrap();
        let worker = node();
        let _paired = pair_worker(&primary, &worker);
        let barrier = Arc::new(std::sync::Barrier::new(3));
        let mut handles = Vec::new();
        for _ in 0..2 {
            let store = Store::open(&database).unwrap();
            let barrier = barrier.clone();
            let mut target = job();
            target.id = Uuid::new_v4();
            handles.push(std::thread::spawn(move || {
                barrier.wait();
                store.submit_job(&target, None, &Scheduler::default())
            }));
        }
        barrier.wait();
        let results = handles
            .into_iter()
            .map(|handle| handle.join().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
        assert_eq!(primary.active_lease_count(worker.id).unwrap(), 1);
        assert!(results.iter().any(|result| matches!(
            result,
            Err(StoreError::Schedule(ScheduleError::NoEligibleNodes { .. }))
        )));
        drop(primary);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn managed_run_heartbeat_cas_cancel_and_completion_close_the_lease() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let paired = pair_worker(&store, &worker);
        store
            .submit_job(&job(), None, &Scheduler::default())
            .unwrap();
        let claim = store
            .claim_job(&paired.credential, &worker)
            .unwrap()
            .unwrap();
        let heartbeat = store
            .worker_heartbeat(
                &paired.credential,
                &claim.run_credential,
                claim.stored.run.id,
                claim.lease_id,
                claim.stored.version,
                JobState::Preparing,
            )
            .unwrap();
        assert!(!heartbeat.stored.cancel_requested);
        let running = store
            .worker_transition(
                &paired.credential,
                &claim.run_credential,
                claim.stored.run.id,
                claim.lease_id,
                claim.stored.version,
                JobState::Running,
            )
            .unwrap();
        assert!(matches!(
            store.worker_transition(
                &paired.credential,
                &claim.run_credential,
                claim.stored.run.id,
                claim.lease_id,
                claim.stored.version,
                JobState::Verifying,
            ),
            Err(StoreError::WorkerStateConflict { .. })
        ));
        let cancelling = store
            .cancel_job(running.job.id, Some(running.version))
            .unwrap();
        let heartbeat = store
            .worker_heartbeat(
                &paired.credential,
                &claim.run_credential,
                claim.stored.run.id,
                claim.lease_id,
                running.version,
                JobState::Running,
            )
            .unwrap();
        assert!(heartbeat.stored.cancel_requested);
        assert_eq!(heartbeat.stored.version, cancelling.version);
        let cancelled = store
            .worker_complete(
                &paired.credential,
                &claim.run_credential,
                claim.stored.run.id,
                claim.lease_id,
                cancelling.version,
                JobState::Cancelled,
                RunEvidence::default(),
            )
            .unwrap();
        assert_eq!(cancelled.run.state, JobState::Cancelled);
        assert_eq!(store.active_lease_count(worker.id).unwrap(), 0);
        assert!(matches!(
            store.worker_heartbeat(
                &paired.credential,
                &claim.run_credential,
                claim.stored.run.id,
                claim.lease_id,
                cancelled.version,
                JobState::Cancelled,
            ),
            Err(StoreError::RunUnauthorized | StoreError::InvalidTransition)
        ));
    }

    #[test]
    fn worker_uploads_are_digest_checked_idempotent_and_path_safe() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let paired = pair_worker(&store, &worker);
        store
            .submit_job(&job(), None, &Scheduler::default())
            .unwrap();
        let claim = store
            .claim_job(&paired.credential, &worker)
            .unwrap()
            .unwrap();
        let bytes = b"hello from worker\n";
        let digest = bytes_sha256(bytes);
        assert!(matches!(
            store.put_log_chunk(
                &paired.credential,
                &claim.run_credential,
                claim.stored.run.id,
                claim.lease_id,
                "stdout",
                0,
                &"0".repeat(64),
                bytes,
            ),
            Err(StoreError::DigestMismatch)
        ));
        let first = store
            .put_log_chunk(
                &paired.credential,
                &claim.run_credential,
                claim.stored.run.id,
                claim.lease_id,
                "stdout",
                0,
                &digest,
                bytes,
            )
            .unwrap();
        let duplicate = store
            .put_log_chunk(
                &paired.credential,
                &claim.run_credential,
                claim.stored.run.id,
                claim.lease_id,
                "stdout",
                0,
                &digest,
                bytes,
            )
            .unwrap();
        assert_eq!(first.sha256, duplicate.sha256);
        assert_eq!(
            store.read_log(claim.stored.run.id, "stdout").unwrap(),
            bytes
        );

        let artifact_id = Uuid::new_v4();
        assert!(matches!(
            store.put_artifact(
                &paired.credential,
                &claim.run_credential,
                claim.stored.run.id,
                claim.lease_id,
                artifact_id,
                "../escape.bin",
                &digest,
                bytes,
            ),
            Err(StoreError::InvalidUpload)
        ));
        let artifact = store
            .put_artifact(
                &paired.credential,
                &claim.run_credential,
                claim.stored.run.id,
                claim.lease_id,
                artifact_id,
                "target/output.bin",
                &digest,
                bytes,
            )
            .unwrap();
        assert_eq!(artifact.sha256, digest);
        let (_, downloaded) = store
            .read_artifact(claim.stored.run.id, artifact_id)
            .unwrap();
        assert_eq!(downloaded, bytes);
    }

    #[test]
    fn managed_completion_is_exact_atomic_persisted_and_same_digest_idempotent() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let paired = pair_worker(&store, &worker);
        store
            .submit_job(&job(), None, &Scheduler::default())
            .unwrap();
        let claim = store
            .claim_job(&paired.credential, &worker)
            .unwrap()
            .unwrap();
        let running = store
            .worker_transition(
                &paired.credential,
                &claim.run_credential,
                claim.stored.run.id,
                claim.lease_id,
                claim.stored.version,
                JobState::Running,
            )
            .unwrap();

        let stdout = b"managed stdout\n";
        let stdout_digest = bytes_sha256(stdout);
        store
            .put_log_chunk(
                &paired.credential,
                &claim.run_credential,
                running.run.id,
                claim.lease_id,
                "stdout",
                0,
                &stdout_digest,
                stdout,
            )
            .unwrap();
        let artifact_bytes = b"verified artifact";
        let artifact_digest = bytes_sha256(artifact_bytes);
        let artifact = store
            .put_artifact(
                &paired.credential,
                &claim.run_credential,
                running.run.id,
                claim.lease_id,
                Uuid::new_v4(),
                "target/output.bin",
                &artifact_digest,
                artifact_bytes,
            )
            .unwrap();

        let started_at = running.run.started_at.unwrap();
        let finished_at = Utc::now();
        let completion = RunCompletion {
            run_id: running.run.id,
            lease_id: claim.lease_id,
            expected_version: running.version,
            final_state: JobState::Succeeded,
            evidence: WorkerRunEvidence {
                started_at: Some(started_at),
                finished_at: Some(finished_at),
                exit_code: Some(0),
                error: None,
                artifact_ids: vec![artifact.id],
            },
            execution: ExecutionEvidence {
                source: ExecutionSourceEvidence {
                    kind: "git".to_owned(),
                    repository: "https://example.invalid/repository.git".to_owned(),
                    requested_revision: "0123456789abcdef0123456789abcdef01234567".to_owned(),
                    resolved_revision: "0123456789abcdef0123456789abcdef01234567".to_owned(),
                    tree: "abcdef0123456789abcdef0123456789abcdef01".to_owned(),
                    git_version: "git version 2.45.0".to_owned(),
                },
                steps: vec![StepExecutionEvidence {
                    index: 0,
                    name: "build".to_owned(),
                    shell: Shell::Powershell,
                    started_at,
                    finished_at,
                    exit_code: Some(0),
                    termination: TerminationReason::Exited,
                }],
                streams: RunStreamsEvidence {
                    stdout: StreamEvidence {
                        byte_count: u64::try_from(stdout.len()).unwrap(),
                        sha256: stdout_digest,
                        truncated: false,
                        chunk_count: 1,
                    },
                    stderr: empty_stream(),
                },
                termination: TerminationEvidence {
                    reason: TerminationReason::Exited,
                    process_tree_terminated: true,
                    forced_kill: false,
                    root_exit_code: Some(0),
                    signal: None,
                    observed_at: finished_at,
                },
            },
            artifacts: vec![ArtifactMetadata {
                id: artifact.id,
                run_id: artifact.run_id,
                relative_path: artifact.name,
                size_bytes: artifact.size,
                sha256: artifact.sha256,
                media_type: None,
                created_at: artifact.created_at,
            }],
        };
        completion.validate().unwrap();

        for invalid in [
            {
                let mut value = completion.clone();
                value.execution.source.repository = "https://example.invalid/swapped.git".into();
                value
            },
            {
                let mut value = completion.clone();
                value.execution.steps[0].name = "swapped".into();
                value
            },
            {
                let mut value = completion.clone();
                value.execution.streams.stdout.sha256 = "a".repeat(64);
                value
            },
            {
                let mut value = completion.clone();
                value.artifacts[0].sha256 = "b".repeat(64);
                value
            },
        ] {
            assert!(matches!(
                store.worker_complete_managed(&paired.credential, &claim.run_credential, &invalid,),
                Err(StoreError::InvalidRunEvidence)
            ));
            let unchanged = store.get_job_by_run_id(running.run.id).unwrap();
            assert_eq!(unchanged.run.state, JobState::Running);
            assert_eq!(unchanged.version, running.version);
            assert!(matches!(
                store.get_completion(running.run.id),
                Err(StoreError::NotFound)
            ));
        }

        let completed = store
            .worker_complete_managed(&paired.credential, &claim.run_credential, &completion)
            .unwrap();
        assert_eq!(completed.run.state, JobState::Succeeded);
        // Terminal evidence is durable, but capacity remains reserved until
        // the exact post-ACK `removed` cleanup receipt (or deadline recovery).
        assert_eq!(store.active_lease_count(worker.id).unwrap(), 1);
        let obligation = store
            .get_cleanup_snapshot(running.run.id)
            .unwrap()
            .obligation
            .unwrap();
        assert_eq!(obligation.job_id, completed.job.id);
        assert_eq!(obligation.run_id, completed.run.id);
        assert_eq!(obligation.lease_id, claim.lease_id);
        assert_eq!(obligation.state_version, completed.version);
        assert!(obligation.reservation_released_at.is_none());
        let receipt = store.get_completion(running.run.id).unwrap();
        assert_eq!(receipt.completion, completion);
        assert_eq!(
            receipt.sha256,
            bytes_sha256(serde_json::to_string(&completion).unwrap().as_bytes())
        );
        assert!(receipt.created_at <= Utc::now());
        assert!(store
            .connection()
            .unwrap()
            .query_row(
                "SELECT revoked_at IS NOT NULL FROM worker_claims WHERE run_id = ?1",
                [running.run.id.to_string()],
                |row| row.get::<_, bool>(0),
            )
            .unwrap());

        let retry = store
            .worker_complete_managed(&paired.credential, &claim.run_credential, &completion)
            .unwrap();
        assert_eq!(retry.version, completed.version);
        let mut different_receipt = completion.clone();
        different_receipt.execution.streams.stdout.truncated = true;
        assert!(matches!(
            store.worker_complete_managed(
                &paired.credential,
                &claim.run_credential,
                &different_receipt,
            ),
            Err(StoreError::WorkerStateConflict { .. })
        ));
    }

    #[test]
    fn removed_cleanup_is_exact_atomic_idempotent_and_releases_capacity() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let paired = pair_worker(&store, &worker);
        let (claim, completed, ack) = complete_empty_managed_run(&store, &worker, &paired);
        assert_eq!(store.active_lease_count(worker.id).unwrap(), 1);

        let mut wrong = removed_cleanup_receipt(ack.clone());
        wrong.terminal_ack.state_version = wrong.terminal_ack.state_version.saturating_add(1);
        assert!(matches!(
            store.record_cleanup(&paired.credential, &claim.run_credential, &wrong),
            Err(StoreError::InvalidCleanupReceipt)
        ));
        assert!(store.get_cleanup(completed.run.id).unwrap().is_none());
        assert_eq!(store.active_lease_count(worker.id).unwrap(), 1);

        // Inject a failure after the receipt INSERT but before lease release.
        // SQLite must roll the whole IMMEDIATE transaction back.
        store
            .connection()
            .unwrap()
            .execute_batch(&format!(
                r#"
                CREATE TRIGGER fail_cleanup_release
                BEFORE UPDATE OF released_at ON leases
                WHEN OLD.id = '{}' AND NEW.released_at IS NOT NULL
                BEGIN
                    SELECT RAISE(ABORT, 'injected cleanup release crash');
                END;
                "#,
                claim.lease_id
            ))
            .unwrap();
        let receipt = removed_cleanup_receipt(ack);
        assert!(matches!(
            store.record_cleanup(&paired.credential, &claim.run_credential, &receipt),
            Err(StoreError::Database(_))
        ));
        assert!(store.get_cleanup(completed.run.id).unwrap().is_none());
        assert_eq!(store.active_lease_count(worker.id).unwrap(), 1);
        store
            .connection()
            .unwrap()
            .execute_batch("DROP TRIGGER fail_cleanup_release")
            .unwrap();

        let first = store
            .record_cleanup(&paired.credential, &claim.run_credential, &receipt)
            .unwrap();
        let duplicate = store
            .record_cleanup(&paired.credential, &claim.run_credential, &receipt)
            .unwrap();
        assert_eq!(first.receipt, duplicate.receipt);
        assert_eq!(store.active_lease_count(worker.id).unwrap(), 0);
        let snapshot = store.get_cleanup_snapshot(completed.job.id).unwrap();
        let obligation = snapshot.obligation.unwrap();
        assert_eq!(
            obligation.release_reason,
            Some(CleanupReservationReleaseReasonV1::RemovedReceipt)
        );
        assert!(obligation.reservation_released_at.is_some());
        assert!(obligation.cleanup_failure.is_none());
        let cleanup_rows: i64 = store
            .connection()
            .unwrap()
            .query_row(
                "SELECT COUNT(*) FROM run_cleanups WHERE run_id = ?1",
                [completed.run.id.to_string()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(cleanup_rows, 1);

        let mut next = job();
        next.id = Uuid::new_v4();
        assert!(store.submit_job(&next, None, &Scheduler::default()).is_ok());
    }

    #[test]
    fn failed_and_cancelled_terminal_reports_also_hold_until_removed() {
        for final_state in [JobState::Failed, JobState::Cancelled] {
            let store = Store::in_memory().unwrap();
            let worker = node();
            let paired = pair_worker(&store, &worker);
            let (claim, completed, ack) =
                complete_empty_managed_run_as(&store, &worker, &paired, final_state);
            assert_eq!(completed.run.state, final_state);
            assert_eq!(store.active_lease_count(worker.id).unwrap(), 1);
            let obligation = store
                .get_cleanup_snapshot(completed.run.id)
                .unwrap()
                .obligation
                .unwrap();
            assert_eq!(obligation.final_state, final_state);
            assert!(obligation.reservation_released_at.is_none());

            let receipt = removed_cleanup_receipt(ack);
            store
                .record_cleanup(&paired.credential, &claim.run_credential, &receipt)
                .unwrap();
            assert_eq!(store.active_lease_count(worker.id).unwrap(), 0);
        }
    }

    #[test]
    fn not_created_receipt_keeps_capacity_until_deadline_recovery() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let paired = pair_worker(&store, &worker);
        let (claim, completed, ack) = complete_empty_managed_run(&store, &worker, &paired);
        let mut receipt = removed_cleanup_receipt(ack);
        receipt.outcome = JobRootCleanupOutcomeV1::NotCreated;
        receipt.job_root_deleted = false;
        store
            .record_cleanup(&paired.credential, &claim.run_credential, &receipt)
            .unwrap();
        assert_eq!(store.active_lease_count(worker.id).unwrap(), 1);

        let mut conflicting_removed = receipt.clone();
        conflicting_removed.outcome = JobRootCleanupOutcomeV1::Removed;
        conflicting_removed.job_root_deleted = true;
        assert!(matches!(
            store.record_cleanup(
                &paired.credential,
                &claim.run_credential,
                &conflicting_removed,
            ),
            Err(StoreError::CleanupConflict)
        ));
        assert_eq!(store.active_lease_count(worker.id).unwrap(), 1);

        let past = Utc::now().timestamp().saturating_sub(1);
        store
            .connection()
            .unwrap()
            .execute(
                r#"
                UPDATE run_cleanup_obligations SET cleanup_deadline_at = ?1
                WHERE run_id = ?2
                "#,
                params![past, completed.run.id.to_string()],
            )
            .unwrap();
        assert_eq!(store.reap_expired_leases().unwrap(), 1);
        assert_eq!(store.active_lease_count(worker.id).unwrap(), 0);
        let obligation = store
            .get_cleanup_snapshot(completed.run.id)
            .unwrap()
            .obligation
            .unwrap();
        assert_eq!(
            obligation.release_reason,
            Some(CleanupReservationReleaseReasonV1::DeadlineRecovery)
        );
        assert_eq!(
            obligation.cleanup_failure.unwrap().code,
            CleanupFailureCodeV1::RemovedReceiptDeadlineExceeded
        );
    }

    #[test]
    fn cleanup_deadline_recovery_survives_restart_without_faking_removed() {
        let directory = test_directory("cleanup-deadline-restart");
        std::fs::create_dir_all(&directory).unwrap();
        let database = directory.join("controller.db");
        let store = Store::open(&database).unwrap();
        let worker = node();
        let paired = pair_worker(&store, &worker);
        let (_claim, completed, _ack) = complete_empty_managed_run(&store, &worker, &paired);
        let past = Utc::now().timestamp().saturating_sub(1);
        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE run_cleanup_obligations SET cleanup_deadline_at = ?1 WHERE run_id = ?2",
                params![past, completed.run.id.to_string()],
            )
            .unwrap();
        drop(store);

        let reopened = Store::open(&database).unwrap();
        assert_eq!(reopened.reap_expired_leases().unwrap(), 1);
        assert_eq!(reopened.active_lease_count(worker.id).unwrap(), 0);
        let snapshot = reopened.get_cleanup_snapshot(completed.job.id).unwrap();
        assert!(snapshot.cleanup.is_none());
        let obligation = snapshot.obligation.unwrap();
        assert_eq!(
            obligation.release_reason,
            Some(CleanupReservationReleaseReasonV1::DeadlineRecovery)
        );
        assert!(obligation.reservation_released_at.is_some());
        assert_eq!(
            obligation.cleanup_failure.unwrap().code,
            CleanupFailureCodeV1::RemovedReceiptDeadlineExceeded
        );
        let mut next = job();
        next.id = Uuid::new_v4();
        assert!(reopened
            .submit_job(&next, None, &Scheduler::default())
            .is_ok());
        drop(reopened);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn cleanup_job_binding_mismatch_never_releases_capacity() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let paired = pair_worker(&store, &worker);
        let (claim, completed, ack) = complete_empty_managed_run(&store, &worker, &paired);
        let past = Utc::now().timestamp().saturating_sub(1);
        store
            .connection()
            .unwrap()
            .execute_batch(&format!(
                r#"
                UPDATE run_cleanup_obligations
                SET job_id = '{}', cleanup_deadline_at = {past}
                WHERE run_id = '{}';
                UPDATE leases SET expires_at = {past}
                WHERE id = '{}';
                "#,
                Uuid::new_v4(),
                completed.run.id,
                completed.lease_id.unwrap(),
            ))
            .unwrap();
        let receipt = removed_cleanup_receipt(ack);
        assert!(matches!(
            store.record_cleanup(&paired.credential, &claim.run_credential, &receipt),
            Err(StoreError::InvalidCleanupReceipt)
        ));
        assert_eq!(store.reap_expired_leases().unwrap(), 0);
        assert_eq!(store.active_lease_count(worker.id).unwrap(), 1);
        assert!(store.get_cleanup(completed.run.id).unwrap().is_none());
        let obligation = store
            .get_cleanup_snapshot(completed.run.id)
            .unwrap()
            .obligation
            .unwrap();
        assert!(obligation.release_reason.is_none());
        assert!(obligation.reservation_released_at.is_none());
        assert_eq!(
            obligation.cleanup_failure.unwrap().code,
            CleanupFailureCodeV1::RemovedReceiptDeadlineExceeded
        );
        let mut next = job();
        next.id = Uuid::new_v4();
        assert!(matches!(
            store.submit_job(&next, None, &Scheduler::default()),
            Err(StoreError::Schedule(ScheduleError::NoEligibleNodes { .. }))
        ));
    }

    #[test]
    fn concurrent_duplicate_removed_receipts_converge_to_one_release() {
        let directory = test_directory("cleanup-concurrent");
        std::fs::create_dir_all(&directory).unwrap();
        let database = directory.join("controller.db");
        let primary = Store::open(&database).unwrap();
        let worker = node();
        let paired = pair_worker(&primary, &worker);
        let (claim, completed, ack) = complete_empty_managed_run(&primary, &worker, &paired);
        let receipt = removed_cleanup_receipt(ack);
        let barrier = Arc::new(std::sync::Barrier::new(3));
        let mut handles = Vec::new();
        for _ in 0..2 {
            let store = Store::open(&database).unwrap();
            let barrier = barrier.clone();
            let receipt = receipt.clone();
            let worker_credential = paired.credential.clone();
            let run_credential = claim.run_credential.clone();
            handles.push(std::thread::spawn(move || {
                barrier.wait();
                store.record_cleanup(&worker_credential, &run_credential, &receipt)
            }));
        }
        barrier.wait();
        for result in handles.into_iter().map(|handle| handle.join().unwrap()) {
            assert!(result.is_ok(), "duplicate cleanup failed: {result:?}");
        }
        assert_eq!(primary.active_lease_count(worker.id).unwrap(), 0);
        let rows: i64 = primary
            .connection()
            .unwrap()
            .query_row(
                "SELECT COUNT(*) FROM run_cleanups WHERE run_id = ?1",
                [completed.run.id.to_string()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(rows, 1);
        let obligation = primary
            .get_cleanup_snapshot(completed.run.id)
            .unwrap()
            .obligation
            .unwrap();
        assert_eq!(
            obligation.release_reason,
            Some(CleanupReservationReleaseReasonV1::RemovedReceipt)
        );
        drop(primary);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn server_enforces_per_run_log_and_artifact_aggregate_quotas() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let paired = pair_worker(&store, &worker);
        store
            .submit_job(&job(), None, &Scheduler::default())
            .unwrap();
        let claim = store
            .claim_job(&paired.credential, &worker)
            .unwrap()
            .unwrap();
        let byte = b"x";
        let digest = bytes_sha256(byte);

        store
            .connection()
            .unwrap()
            .execute(
                r#"
                INSERT INTO log_chunks(
                    run_id, stream, chunk_offset, chunk_length, sha256, relative_path, created_at
                ) VALUES (?1, 'stderr', 0, ?2, ?3, 'quota-fixture', ?4)
                "#,
                params![
                    claim.stored.run.id.to_string(),
                    as_i64(MAX_RUN_LOG_BYTES),
                    "a".repeat(64),
                    Utc::now().timestamp(),
                ],
            )
            .unwrap();
        assert!(matches!(
            store.put_log_chunk(
                &paired.credential,
                &claim.run_credential,
                claim.stored.run.id,
                claim.lease_id,
                "stdout",
                0,
                &digest,
                byte,
            ),
            Err(StoreError::LogQuotaExceeded)
        ));
        store
            .connection()
            .unwrap()
            .execute(
                "DELETE FROM log_chunks WHERE run_id = ?1",
                [claim.stored.run.id.to_string()],
            )
            .unwrap();
        {
            let mut connection = store.connection().unwrap();
            let transaction = connection.transaction().unwrap();
            for offset in 0..MAX_RUN_LOG_CHUNKS {
                transaction
                    .execute(
                        r#"
                        INSERT INTO log_chunks(
                            run_id, stream, chunk_offset, chunk_length, sha256,
                            relative_path, created_at
                        ) VALUES (?1, 'stderr', ?2, 1, ?3, ?4, ?5)
                        "#,
                        params![
                            claim.stored.run.id.to_string(),
                            as_i64(offset),
                            "a".repeat(64),
                            format!("quota-{offset}"),
                            Utc::now().timestamp(),
                        ],
                    )
                    .unwrap();
            }
            transaction.commit().unwrap();
        }
        assert!(matches!(
            store.put_log_chunk(
                &paired.credential,
                &claim.run_credential,
                claim.stored.run.id,
                claim.lease_id,
                "stdout",
                0,
                &digest,
                byte,
            ),
            Err(StoreError::LogQuotaExceeded)
        ));

        store
            .connection()
            .unwrap()
            .execute(
                r#"
                INSERT INTO artifacts(id, run_id, name, size, sha256, relative_path, created_at)
                VALUES (?1, ?2, 'quota.bin', ?3, ?4, 'quota-artifact', ?5)
                "#,
                params![
                    Uuid::new_v4().to_string(),
                    claim.stored.run.id.to_string(),
                    as_i64(MAX_RUN_ARTIFACT_BYTES),
                    "a".repeat(64),
                    Utc::now().timestamp(),
                ],
            )
            .unwrap();
        assert!(matches!(
            store.put_artifact(
                &paired.credential,
                &claim.run_credential,
                claim.stored.run.id,
                claim.lease_id,
                Uuid::new_v4(),
                "target/new.bin",
                &digest,
                byte,
            ),
            Err(StoreError::ArtifactQuotaExceeded)
        ));
        store
            .connection()
            .unwrap()
            .execute(
                "DELETE FROM artifacts WHERE run_id = ?1",
                [claim.stored.run.id.to_string()],
            )
            .unwrap();
        {
            let mut connection = store.connection().unwrap();
            let transaction = connection.transaction().unwrap();
            for index in 0..MAX_RUN_ARTIFACT_COUNT {
                transaction
                    .execute(
                        r#"
                        INSERT INTO artifacts(
                            id, run_id, name, size, sha256, relative_path, created_at
                        ) VALUES (?1, ?2, ?3, 0, ?4, ?5, ?6)
                        "#,
                        params![
                            Uuid::new_v4().to_string(),
                            claim.stored.run.id.to_string(),
                            format!("quota-{index}.bin"),
                            bytes_sha256(&[]),
                            format!("quota-artifact-{index}"),
                            Utc::now().timestamp(),
                        ],
                    )
                    .unwrap();
            }
            transaction.commit().unwrap();
        }
        assert!(matches!(
            store.put_artifact(
                &paired.credential,
                &claim.run_credential,
                claim.stored.run.id,
                claim.lease_id,
                Uuid::new_v4(),
                "target/count.bin",
                &digest,
                byte,
            ),
            Err(StoreError::ArtifactQuotaExceeded)
        ));
    }

    #[test]
    fn expired_managed_claim_fails_run_and_revokes_run_secret() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let paired = pair_worker(&store, &worker);
        store
            .submit_job(&job(), None, &Scheduler::default())
            .unwrap();
        let claim = store
            .claim_job(&paired.credential, &worker)
            .unwrap()
            .unwrap();
        let past = Utc::now().timestamp().saturating_sub(1);
        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE leases SET expires_at = ?1 WHERE id = ?2",
                params![past, claim.lease_id.to_string()],
            )
            .unwrap();
        assert_eq!(store.reap_expired_leases().unwrap(), 1);
        let failed = store.get_job_by_run_id(claim.stored.run.id).unwrap();
        assert_eq!(failed.run.state, JobState::Failed);
        assert!(matches!(
            store.worker_heartbeat(
                &paired.credential,
                &claim.run_credential,
                claim.stored.run.id,
                claim.lease_id,
                failed.version,
                JobState::Failed,
            ),
            Err(StoreError::RunUnauthorized | StoreError::InvalidTransition)
        ));
    }
}
