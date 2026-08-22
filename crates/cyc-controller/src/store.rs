use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use chrono::{DateTime, Utc};
use cyc_protocol::worker::{ExecutionEvidence, RunCompletion, StreamEvidence, TerminationReason};
use cyc_protocol::{
    canonical_job_digest, normalize_job_spec, validate_portable_relative_path, JobKind, JobSpec,
    JobState, Node, NodeTransport, OperatingSystem, Run, Shell, SourceSpec,
};
use cyc_scheduler::{PlacementDecision, ScheduleError, Scheduler};
use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use sha2::{Digest, Sha256};
use thiserror::Error;
use uuid::Uuid;

pub const PLAN_TTL_SECONDS: i64 = 60;
pub const NODE_FRESHNESS_SECONDS: i64 = 120;
pub const POLICY_REVISION: i64 = 2;
pub const PAIRING_TTL_SECONDS: i64 = 600;
pub const CLAIM_TTL_SECONDS: i64 = 90;
pub const MAX_RUN_LOG_BYTES: u64 = 16 * 1024 * 1024;
pub const MAX_RUN_LOG_CHUNKS: u64 = 4_096;
pub const MAX_RUN_ARTIFACT_BYTES: u64 = 64 * 1024 * 1024;
pub const MAX_RUN_ARTIFACT_COUNT: u32 = 1_000;
const DEFAULT_LEASE_SECONDS: u64 = 900;
const LEASE_GRACE_SECONDS: u64 = 300;

#[derive(Debug, Error)]
pub enum StoreError {
    #[error("controller storage security validation failed")]
    StorageSecurity(#[source] anyhow::Error),
    #[error("database operation failed")]
    Database(#[from] rusqlite::Error),
    #[error("stored document is invalid")]
    Document(#[from] serde_json::Error),
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
    #[error("placement failed")]
    Schedule(#[from] ScheduleError),
    #[error("worker authentication failed")]
    WorkerUnauthorized,
    #[error("pairing code is expired, used, or revoked")]
    PairingUnavailable,
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
    #[error("controller object storage failed")]
    Io(#[from] std::io::Error),
}

pub type StoreResult<T> = Result<T, StoreError>;

#[derive(Clone)]
pub struct Store {
    connection: Arc<Mutex<Connection>>,
    object_root: Arc<PathBuf>,
}

#[derive(Debug, Clone)]
pub struct StoredJob {
    pub job: JobSpec,
    pub run: Run,
    pub version: u64,
    pub cancel_requested: bool,
    pub lease_id: Option<Uuid>,
}

#[derive(Debug, Clone)]
pub struct StoredPlan {
    pub id: Uuid,
    pub job_id: Uuid,
    pub job_digest: String,
    pub decision: PlacementDecision,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
    pub fleet_revision: i64,
    pub node_revision: i64,
    pub policy_revision: i64,
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
#[derive(Clone)]
pub struct PairingSecret {
    pub id: Uuid,
    pub code: String,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}

// Deliberately not `Debug`: this value owns the worker's plaintext credential.
#[derive(Clone)]
pub struct PairedWorker {
    pub pairing_id: Uuid,
    pub node_id: Uuid,
    pub credential: String,
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
pub struct StoredCompletion {
    pub completion: RunCompletion,
    pub sha256: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Default)]
struct ReservationTotals {
    cpu_cores: u64,
    memory_mib: u64,
    disk_mib: u64,
    gpu_reservations: u64,
    count: u64,
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
        let store = Self {
            connection: Arc::new(Mutex::new(connection)),
            object_root: Arc::new(object_root),
        };
        store.migrate()?;
        Ok(store)
    }

    fn connection(&self) -> StoreResult<MutexGuard<'_, Connection>> {
        self.connection.lock().map_err(|_| StoreError::Poisoned)
    }

    fn migrate(&self) -> StoreResult<()> {
        let connection = self.connection()?;
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

            CREATE TABLE IF NOT EXISTS nodes (
                id TEXT PRIMARY KEY NOT NULL,
                document TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                revision INTEGER NOT NULL DEFAULT 0
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
                lease_id TEXT
            );
            CREATE TABLE IF NOT EXISTS leases (
                id TEXT PRIMARY KEY NOT NULL,
                run_id TEXT UNIQUE NOT NULL,
                job_id TEXT NOT NULL,
                node_id TEXT NOT NULL,
                cpu_cores INTEGER NOT NULL,
                memory_mib INTEGER NOT NULL,
                disk_mib INTEGER NOT NULL,
                gpu_reserved INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                expires_at INTEGER NOT NULL,
                released_at INTEGER
            );
            CREATE INDEX IF NOT EXISTS jobs_updated_at_idx ON jobs(updated_at DESC);
            CREATE INDEX IF NOT EXISTS leases_active_node_idx
                ON leases(node_id, expires_at, released_at);

            CREATE TABLE IF NOT EXISTS pairings (
                id TEXT PRIMARY KEY NOT NULL,
                code_hash TEXT UNIQUE NOT NULL,
                created_at INTEGER NOT NULL,
                expires_at INTEGER NOT NULL,
                used_at INTEGER,
                revoked_at INTEGER,
                node_id TEXT
            );
            CREATE INDEX IF NOT EXISTS pairings_expiry_idx
                ON pairings(expires_at, used_at, revoked_at);

            CREATE TABLE IF NOT EXISTS worker_credentials (
                id TEXT PRIMARY KEY NOT NULL,
                pairing_id TEXT NOT NULL,
                node_id TEXT NOT NULL,
                credential_hash TEXT UNIQUE NOT NULL,
                created_at INTEGER NOT NULL,
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

            CREATE TABLE IF NOT EXISTS run_completions (
                run_id TEXT PRIMARY KEY NOT NULL,
                document TEXT NOT NULL,
                document_sha256 TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                FOREIGN KEY(run_id) REFERENCES jobs(run_id)
            );
            "#,
        )?;

        connection.execute(
            "INSERT OR IGNORE INTO controller_identity(singleton, id) VALUES (1, ?1)",
            [Uuid::new_v4().to_string()],
        )?;

        ensure_column(
            &connection,
            "nodes",
            "revision",
            "INTEGER NOT NULL DEFAULT 0",
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
        upsert_node_tx(&transaction, node)?;
        transaction.commit()?;
        Ok(())
    }

    /// Refresh node liveness without invalidating placement plans. Scheduling
    /// material must continue to flow through `upsert_node`.
    pub fn touch_node(&self, node_id: Uuid) -> StoreResult<()> {
        let connection = self.connection()?;
        let changed = connection.execute(
            "UPDATE nodes SET updated_at = ?1 WHERE id = ?2",
            params![Utc::now().to_rfc3339(), node_id.to_string()],
        )?;
        if changed == 0 {
            return Err(StoreError::NotFound);
        }
        Ok(())
    }

    pub fn list_nodes(&self) -> StoreResult<Vec<Node>> {
        let connection = self.connection()?;
        list_all_nodes(&connection)
    }

    pub fn create_pairing(&self) -> StoreResult<PairingSecret> {
        let now = Utc::now();
        let pairing = PairingSecret {
            id: Uuid::new_v4(),
            code: random_secret(),
            created_at: now,
            expires_at: now + chrono::Duration::seconds(PAIRING_TTL_SECONDS),
        };
        let hash = secret_hash(&pairing.code);
        self.connection()?.execute(
            r#"
            INSERT INTO pairings(id, code_hash, created_at, expires_at, used_at, revoked_at, node_id)
            VALUES (?1, ?2, ?3, ?4, NULL, NULL, NULL)
            "#,
            params![
                pairing.id.to_string(),
                hash,
                pairing.created_at.timestamp(),
                pairing.expires_at.timestamp(),
            ],
        )?;
        Ok(pairing)
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
                SELECT 1 FROM pairings
                WHERE code_hash = ?1 AND used_at IS NULL AND revoked_at IS NULL
                  AND expires_at > ?2
                "#,
                params![secret_hash(code), Utc::now().timestamp()],
                |_| Ok(()),
            )
            .optional()?;
        available.ok_or(StoreError::PairingUnavailable)
    }

    /// Atomically consume a one-time pairing code, bind it to the probed node,
    /// and persist only the hash of the newly issued long-lived credential.
    pub fn consume_pairing(&self, code: &str, node: &Node) -> StoreResult<PairedWorker> {
        if !matches!(&node.transport, NodeTransport::Managed { .. }) {
            return Err(StoreError::InvalidManagedNode);
        }
        let now = Utc::now().timestamp();
        let code_hash = secret_hash(code);
        let credential = random_secret();
        let credential_hash = secret_hash(&credential);
        let credential_id = Uuid::new_v4();
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let pairing_id = transaction
            .query_row(
                r#"
                SELECT id FROM pairings
                WHERE code_hash = ?1 AND used_at IS NULL AND revoked_at IS NULL AND expires_at > ?2
                "#,
                params![code_hash, now],
                |row| row.get::<_, String>(0),
            )
            .optional()?
            .ok_or(StoreError::PairingUnavailable)?;
        let pairing_id = Uuid::parse_str(&pairing_id)?;

        upsert_node_tx(&transaction, node)?;
        // Pairing the same stable node again is credential rotation. Old
        // credentials are revoked before the replacement is committed.
        transaction.execute(
            "UPDATE worker_credentials SET revoked_at = ?1 WHERE node_id = ?2 AND revoked_at IS NULL",
            params![now, node.id.to_string()],
        )?;
        transaction.execute(
            r#"
            INSERT INTO worker_credentials(
                id, pairing_id, node_id, credential_hash, created_at, last_used_at, revoked_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, NULL, NULL)
            "#,
            params![
                credential_id.to_string(),
                pairing_id.to_string(),
                node.id.to_string(),
                credential_hash,
                now,
            ],
        )?;
        let changed = transaction.execute(
            r#"
            UPDATE pairings SET used_at = ?1, node_id = ?2
            WHERE id = ?3 AND used_at IS NULL AND revoked_at IS NULL AND expires_at > ?1
            "#,
            params![now, node.id.to_string(), pairing_id.to_string()],
        )?;
        if changed != 1 {
            return Err(StoreError::PairingUnavailable);
        }
        transaction.commit()?;
        Ok(PairedWorker {
            pairing_id,
            node_id: node.id,
            credential,
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
        let hash = secret_hash(credential);
        let now = Utc::now().timestamp();
        let connection = self.connection()?;
        let node_id = connection
            .query_row(
                r#"
                SELECT node_id FROM worker_credentials
                WHERE credential_hash = ?1 AND revoked_at IS NULL
                "#,
                [hash],
                |row| row.get::<_, String>(0),
            )
            .optional()?
            .ok_or(StoreError::WorkerUnauthorized)?;
        connection.execute(
            "UPDATE worker_credentials SET last_used_at = ?1 WHERE credential_hash = ?2",
            params![now, secret_hash(credential)],
        )?;
        Ok(Uuid::parse_str(&node_id)?)
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
        let now = Utc::now();
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        expire_leases(&transaction, now.timestamp())?;
        let nodes_with_revisions = fresh_available_nodes(&transaction, now)?;
        let nodes = nodes_with_revisions
            .iter()
            .map(|(node, _)| node.clone())
            .collect::<Vec<_>>();
        let decision = scheduler.schedule(&normalized_job, &nodes)?;
        let node_revision = nodes_with_revisions
            .iter()
            .find(|(node, _)| node.id == decision.node_id)
            .map(|(_, revision)| *revision)
            .ok_or(StoreError::PlanStale)?;
        let fleet_revision = get_meta(&transaction, "fleet_revision")?;
        let policy_revision = get_meta(&transaction, "policy_revision")?;
        let plan = StoredPlan {
            id: Uuid::new_v4(),
            job_id: job.id,
            job_digest: digest,
            decision,
            created_at: now,
            expires_at: now + chrono::Duration::seconds(PLAN_TTL_SECONDS),
            fleet_revision,
            node_revision,
            policy_revision,
            used_at: None,
        };
        transaction.execute(
            r#"
            INSERT INTO plans(
                id, job_id, decision, created_at, job_digest, expires_at,
                fleet_revision, node_revision, policy_revision, used_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, NULL)
            "#,
            params![
                plan.id.to_string(),
                plan.job_id.to_string(),
                serde_json::to_string(&plan.decision)?,
                plan.created_at.timestamp(),
                plan.job_digest,
                plan.expires_at.timestamp(),
                plan.fleet_revision,
                plan.node_revision,
                plan.policy_revision,
            ],
        )?;
        transaction.commit()?;
        Ok(plan)
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
        let now = Utc::now();
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
            .map(|(node, _)| node.clone())
            .collect::<Vec<_>>();
        let current_fleet_revision = get_meta(&transaction, "fleet_revision")?;
        let current_policy_revision = get_meta(&transaction, "policy_revision")?;

        let decision = if let Some(plan_id) = plan_id {
            let plan = get_plan(&transaction, plan_id)?;
            if plan.job_id != job.id || plan.job_digest != digest {
                return Err(StoreError::PlanDigestMismatch);
            }
            if plan.used_at.is_some() {
                return Err(StoreError::PlanStale);
            }
            if plan.expires_at <= now {
                return Err(StoreError::PlanExpired);
            }
            if plan.fleet_revision != current_fleet_revision
                || plan.policy_revision != current_policy_revision
            {
                return Err(StoreError::PlanStale);
            }
            let current_node_revision = nodes_with_revisions
                .iter()
                .find(|(node, _)| node.id == plan.decision.node_id)
                .map(|(_, revision)| *revision)
                .ok_or(StoreError::PlanStale)?;
            if current_node_revision != plan.node_revision {
                return Err(StoreError::PlanStale);
            }
            let refreshed = scheduler.schedule(&normalized_job, &nodes)?;
            if refreshed.node_id != plan.decision.node_id {
                return Err(StoreError::PlanStale);
            }
            refreshed
        } else {
            scheduler.schedule(&normalized_job, &nodes)?
        };

        let mut run = unique_queued_run(&transaction, job.id)?;
        run.node_id = Some(decision.node_id);
        run.placement = Some(decision.explanation);
        let lease_id = Uuid::new_v4();
        let lease_seconds = lease_duration_seconds(&normalized_job);
        let gpu_reserved = i64::from(job.kind == JobKind::Gpu || job.requirements.gpu.is_some());
        transaction.execute(
            r#"
            INSERT INTO leases(
                id, run_id, job_id, node_id, cpu_cores, memory_mib, disk_mib,
                gpu_reserved, created_at, expires_at, released_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, NULL)
            "#,
            params![
                lease_id.to_string(),
                run.id.to_string(),
                job.id.to_string(),
                decision.node_id.to_string(),
                i64::from(job.requirements.min_cpu_cores.unwrap_or(1)),
                as_i64(job.requirements.min_memory_mib.unwrap_or_default()),
                as_i64(job.requirements.min_disk_mib.unwrap_or_default()),
                gpu_reserved,
                now.timestamp(),
                now.timestamp().saturating_add(as_i64(lease_seconds)),
            ],
        )?;

        let now_text = now.to_rfc3339();
        transaction.execute(
            r#"
            INSERT INTO jobs(
                run_id, job_id, job, run, created_at, updated_at,
                version, cancel_requested, lease_id
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?5, 0, 0, ?6)
            "#,
            params![
                run.id.to_string(),
                job.id.to_string(),
                serde_json::to_string(&normalized_job)?,
                serde_json::to_string(&run)?,
                now_text,
                lease_id.to_string(),
            ],
        )?;

        if let Some(plan_id) = plan_id {
            let changed = transaction.execute(
                "UPDATE plans SET used_at = ?1 WHERE id = ?2 AND used_at IS NULL",
                params![now.timestamp(), plan_id.to_string()],
            )?;
            if changed != 1 {
                return Err(StoreError::PlanStale);
            }
        }
        transaction.commit()?;
        Ok(StoredJob {
            job: normalized_job,
            run,
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
        upsert_node_tx(&transaction, observed_node)?;

        let rows = {
            let mut statement = transaction.prepare(
                r#"
                SELECT j.job, j.run, j.version, j.cancel_requested, j.lease_id
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
            UPDATE leases SET expires_at = ?1
            WHERE id = ?2 AND run_id = ?3 AND released_at IS NULL
            "#,
            params![
                expires_at.timestamp(),
                lease_id.to_string(),
                stored.run.id.to_string(),
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
        transaction.execute(
            "UPDATE nodes SET updated_at = ?1 WHERE id = ?2",
            params![
                now.to_rfc3339(),
                stored
                    .run
                    .node_id
                    .ok_or(StoreError::RunUnauthorized)?
                    .to_string(),
            ],
        )?;
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
    /// idempotent even after the claim and lease have been released.
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
        release_lease(&transaction, Some(completion.lease_id), now.timestamp())?;
        transaction.commit()?;
        Ok(stored)
    }

    pub fn get_completion(&self, run_id: Uuid) -> StoreResult<StoredCompletion> {
        let connection = self.connection()?;
        let (document, sha256, created_at) = connection
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
            .ok_or(StoreError::NotFound)?;
        Ok(StoredCompletion {
            completion: serde_json::from_str(&document)?,
            sha256,
            created_at: timestamp(created_at)?,
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
        let rows = {
            let mut statement = transaction.prepare(
                r#"
                SELECT job, run, version, cancel_requested, lease_id
                FROM jobs ORDER BY updated_at DESC LIMIT ?1
                "#,
            )?;
            let rows = statement
                .query_map([limit.min(500) as i64], job_row)?
                .collect::<Result<Vec<_>, _>>()?;
            rows
        };
        let jobs = rows
            .into_iter()
            .map(decode_job_row)
            .collect::<StoreResult<Vec<_>>>()?;
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
        let renewed_at = now
            .timestamp()
            .saturating_add(as_i64(lease_duration_seconds(&stored.job)));
        let changed = transaction.execute(
            r#"
            UPDATE leases SET expires_at = MAX(expires_at, ?1)
            WHERE id = ?2 AND run_id = ?3 AND released_at IS NULL AND expires_at > ?4
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
            WHERE node_id = ?1 AND released_at IS NULL AND expires_at > ?2
            "#,
            params![node_id.to_string(), now],
            |row| row.get::<_, i64>(0),
        )?;
        Ok(as_u64(value))
    }
}

fn scheduling_material_equal(left: &Node, right: &Node) -> bool {
    let mut left = left.clone();
    let mut right = right.clone();
    left.last_seen_at = None;
    right.last_seen_at = None;
    left == right
}

fn upsert_node_tx(transaction: &Transaction<'_>, node: &Node) -> StoreResult<()> {
    let document = serde_json::to_string(node)?;
    let existing = transaction
        .query_row(
            "SELECT document, revision FROM nodes WHERE id = ?1",
            [node.id.to_string()],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
        )
        .optional()?;
    let (current_revision, material_changed) = match existing {
        Some((existing, revision)) => {
            let existing: Node = serde_json::from_str(&existing)?;
            (revision, !scheduling_material_equal(&existing, node))
        }
        None => (0, true),
    };
    let next_revision = if material_changed {
        current_revision.saturating_add(1)
    } else {
        current_revision
    };
    transaction.execute(
        r#"
        INSERT INTO nodes(id, document, updated_at, revision) VALUES (?1, ?2, ?3, ?4)
        ON CONFLICT(id) DO UPDATE SET
            document=excluded.document,
            updated_at=excluded.updated_at,
            revision=excluded.revision
        "#,
        params![
            node.id.to_string(),
            document,
            Utc::now().to_rfc3339(),
            next_revision
        ],
    )?;
    if material_changed {
        increment_meta(transaction, "fleet_revision")?;
    }
    Ok(())
}

fn random_secret() -> String {
    format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple())
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
            SELECT node_id FROM worker_credentials
            WHERE credential_hash = ?1 AND revoked_at IS NULL
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
            SELECT node_id FROM worker_claims
            WHERE run_id = ?1 AND lease_id = ?2 AND credential_hash = ?3
              AND revoked_at IS NULL AND expires_at > ?4
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
    error: Option<&str>,
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
            // Snapshot transfer is intentionally not part of the managed LAN
            // preview. The only acceptable receipt proves that the worker
            // rejected it before executing any step.
            if final_state != JobState::Failed
                || execution.termination.reason != TerminationReason::SourcePreparationFailed
                || observed.kind != "snapshot"
                || observed.repository != "snapshot"
                || observed.requested_revision != *digest
                || !observed.resolved_revision.is_empty()
                || !observed.tree.is_empty()
                || observed.git_version != "not-applicable"
                || error.is_none_or(|message| !message.contains(digest))
            {
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

fn lease_duration_seconds(job: &JobSpec) -> u64 {
    let execution_bound = job.timeout_seconds.unwrap_or_else(|| {
        job.steps
            .iter()
            .map(|step| step.timeout_seconds.unwrap_or(DEFAULT_LEASE_SECONDS))
            .fold(0_u64, u64::saturating_add)
    });
    execution_bound.saturating_add(LEASE_GRACE_SECONDS)
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

fn increment_meta(transaction: &Transaction<'_>, key: &str) -> StoreResult<()> {
    transaction.execute(
        "UPDATE controller_meta SET value = value + 1 WHERE key = ?1",
        [key],
    )?;
    Ok(())
}

fn get_meta(transaction: &Transaction<'_>, key: &str) -> StoreResult<i64> {
    Ok(transaction.query_row(
        "SELECT value FROM controller_meta WHERE key = ?1",
        [key],
        |row| row.get(0),
    )?)
}

fn list_all_nodes(connection: &Connection) -> StoreResult<Vec<Node>> {
    let mut statement =
        connection.prepare("SELECT document FROM nodes ORDER BY updated_at DESC")?;
    let documents = statement
        .query_map([], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    documents
        .into_iter()
        .map(|document| serde_json::from_str(&document).map_err(StoreError::from))
        .collect()
}

fn fresh_available_nodes(
    transaction: &Transaction<'_>,
    now: DateTime<Utc>,
) -> StoreResult<Vec<(Node, i64)>> {
    let mut statement = transaction.prepare(
        r#"
        SELECT DISTINCT n.document, n.updated_at, n.revision
        FROM nodes n
        JOIN worker_credentials wc ON wc.node_id = n.id AND wc.revoked_at IS NULL
        JOIN pairings p ON p.id = wc.pairing_id
        WHERE p.used_at IS NOT NULL AND p.revoked_at IS NULL
        ORDER BY n.updated_at DESC
        "#,
    )?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;

    let reservations = active_reservations(transaction, now.timestamp())?;
    let mut nodes = Vec::new();
    for (document, updated_at, revision) in rows {
        let updated_at = DateTime::parse_from_rfc3339(&updated_at)
            .map_err(|_| StoreError::Timestamp)?
            .with_timezone(&Utc);
        if now.signed_duration_since(updated_at).num_seconds() > NODE_FRESHNESS_SECONDS {
            continue;
        }
        let mut node: Node = serde_json::from_str(&document)?;
        if !matches!(&node.transport, NodeTransport::Managed { .. }) {
            continue;
        }
        if let Some(reserved) = reservations.get(&node.id) {
            // Preview invariant: a managed node owns exactly one active slot.
            // This keeps claim/resource accounting deterministic until the
            // protocol grows explicit per-node concurrency declarations.
            if reserved.count > 0 {
                continue;
            }
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
            if reserved.gpu_reservations > 0 {
                for gpu in &mut node.resources.gpus {
                    gpu.allocatable = false;
                    gpu.available_vram_mib = 0;
                }
            }
        }
        nodes.push((node, revision));
    }
    Ok(nodes)
}

fn active_reservations(
    transaction: &Transaction<'_>,
    now: i64,
) -> StoreResult<BTreeMap<Uuid, ReservationTotals>> {
    let mut statement = transaction.prepare(
        r#"
        SELECT node_id, SUM(cpu_cores), SUM(memory_mib), SUM(disk_mib),
               SUM(gpu_reserved), COUNT(*)
        FROM leases
        WHERE released_at IS NULL AND expires_at > ?1
        GROUP BY node_id
        "#,
    )?;
    let rows = statement
        .query_map([now], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, i64>(3)?,
                row.get::<_, i64>(4)?,
                row.get::<_, i64>(5)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    rows.into_iter()
        .map(|row| {
            Ok((
                Uuid::parse_str(&row.0)?,
                ReservationTotals {
                    cpu_cores: as_u64(row.1),
                    memory_mib: as_u64(row.2),
                    disk_mib: as_u64(row.3),
                    gpu_reservations: as_u64(row.4),
                    count: as_u64(row.5),
                },
            ))
        })
        .collect()
}

fn expire_leases(transaction: &Transaction<'_>, now: i64) -> StoreResult<u64> {
    let expired = {
        let mut statement = transaction.prepare(
            r#"
            SELECT id, run_id FROM leases
            WHERE released_at IS NULL AND expires_at <= ?1
            ORDER BY expires_at, id
            "#,
        )?;
        let rows = statement
            .query_map([now], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };

    let mut count = 0_u64;
    for (lease_id, run_id) in expired {
        let lease_id = Uuid::parse_str(&lease_id)?;
        let run_id = Uuid::parse_str(&run_id)?;
        match get_job_by_run_id(transaction, run_id) {
            Ok(mut stored) if !stored.run.state.is_terminal() => {
                stored
                    .run
                    .transition(JobState::Failed)
                    .map_err(|_| StoreError::InvalidTransition)?;
                stored.run.exit_code = None;
                stored.run.error = Some("worker lease expired before completion".to_owned());
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
    Ok(count)
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
    Ok(StoredPlan {
        id: plan_id,
        job_id: Uuid::parse_str(&row.0)?,
        job_digest: row.1,
        decision: serde_json::from_str(&row.2)?,
        created_at: timestamp(row.3)?,
        expires_at: timestamp(row.4)?,
        fleet_revision: row.5,
        node_revision: row.6,
        policy_revision: row.7,
        used_at: row.8.map(timestamp).transpose()?,
    })
}

type JobDatabaseRow = (String, String, i64, i64, Option<String>);

fn job_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<JobDatabaseRow> {
    Ok((
        row.get(0)?,
        row.get(1)?,
        row.get(2)?,
        row.get(3)?,
        row.get(4)?,
    ))
}

fn decode_job_row(row: JobDatabaseRow) -> StoreResult<StoredJob> {
    Ok(StoredJob {
        job: serde_json::from_str(&row.0)?,
        run: serde_json::from_str(&row.1)?,
        version: as_u64(row.2),
        cancel_requested: row.3 != 0,
        lease_id: row.4.map(|value| Uuid::parse_str(&value)).transpose()?,
    })
}

fn get_job_by_job_id(connection: &Connection, job_id: Uuid) -> StoreResult<StoredJob> {
    let row = connection
        .query_row(
            r#"
            SELECT job, run, version, cancel_requested, lease_id
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
            SELECT job, run, version, cancel_requested, lease_id
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
        UPDATE jobs SET run = ?1, cancel_requested = ?2, version = ?3, updated_at = ?4
        WHERE run_id = ?5 AND version = ?6
        "#,
        params![
            serde_json::to_string(&stored.run)?,
            i64::from(stored.cancel_requested),
            as_i64(next_version),
            Utc::now().to_rfc3339(),
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

fn release_lease(
    transaction: &Transaction<'_>,
    lease_id: Option<Uuid>,
    now: i64,
) -> StoreResult<()> {
    if let Some(lease_id) = lease_id {
        transaction.execute(
            "UPDATE leases SET released_at = ?1 WHERE id = ?2 AND released_at IS NULL",
            params![now, lease_id.to_string()],
        )?;
    }
    Ok(())
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
        ArtifactMetadata, ExecutionEvidence, ExecutionSourceEvidence,
        RunEvidence as WorkerRunEvidence, RunStreamsEvidence, StepExecutionEvidence,
        StreamEvidence, TerminationEvidence, TerminationReason,
    };
    use cyc_protocol::{
        Architecture, CredentialRef, GpuDevice, GpuRequirement, GpuVendor, JobKind, JobStep,
        NodeResources, NodeStatus, NodeTransport, OperatingSystem, SourceSpec,
    };

    use super::*;

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

    fn pair_worker(store: &Store, worker: &Node) -> PairedWorker {
        let pairing = store.create_pairing().unwrap();
        let paired = store.consume_pairing(&pairing.code, worker).unwrap();
        assert_eq!(paired.node_id, worker.id);
        assert!(matches!(
            store.consume_pairing(&pairing.code, worker),
            Err(StoreError::PairingUnavailable)
        ));
        paired
    }

    fn empty_stream() -> StreamEvidence {
        StreamEvidence {
            byte_count: 0,
            sha256: bytes_sha256(&[]),
            truncated: false,
            chunk_count: 0,
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
        assert_eq!(plan.job_digest, canonical_job_digest(&job).unwrap());
        assert!(plan.expires_at > plan.created_at);

        let mut changed = job.clone();
        changed.steps[0].script.push_str(" --release");
        assert!(matches!(
            store.submit_job(&changed, Some(plan.id), &scheduler),
            Err(StoreError::PlanDigestMismatch)
        ));

        let mut explicit_defaults = job.clone();
        explicit_defaults.requirements.min_cpu_cores = Some(1);
        let submitted = store
            .submit_job(&explicit_defaults, Some(plan.id), &scheduler)
            .unwrap();
        assert_eq!(submitted.version, 0);
        assert_eq!(submitted.job.requirements.min_cpu_cores, Some(1));
        assert!(matches!(
            store.submit_job(&job, Some(plan.id), &scheduler),
            Err(StoreError::Conflict)
        ));
    }

    #[test]
    fn node_revision_invalidates_a_plan() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let mut changed = worker.clone();
        changed.load.cpu_percent = 1;
        let _paired = pair_worker(&store, &changed);
        let scheduler = Scheduler::default();
        let job = job();
        let plan = store.create_plan(&job, &scheduler).unwrap();
        store.upsert_node(&worker).unwrap();
        assert!(matches!(
            store.submit_job(&job, Some(plan.id), &scheduler),
            Err(StoreError::PlanStale)
        ));
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
        let submitted = store.submit_job(&job, Some(plan.id), &scheduler).unwrap();
        assert_eq!(submitted.run.node_id, Some(worker.id));
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
    fn lease_duration_uses_overall_or_sequential_step_upper_bound() {
        let mut job = job();
        job.steps = vec![
            JobStep {
                timeout_seconds: Some(60),
                ..JobStep::new("one", "one")
            },
            JobStep {
                timeout_seconds: Some(90),
                ..JobStep::new("two", "two")
            },
        ];
        assert_eq!(lease_duration_seconds(&job), 150 + LEASE_GRACE_SECONDS);
        job.timeout_seconds = Some(120);
        assert_eq!(lease_duration_seconds(&job), 120 + LEASE_GRACE_SECONDS);
    }

    #[test]
    fn lease_renewal_does_not_change_job_version() {
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
                    Utc::now().timestamp().saturating_add(60),
                    submitted.lease_id.unwrap().to_string()
                ],
            )
            .unwrap();
        let renewed = store.renew_lease(submitted.run.id).unwrap();
        assert!(renewed.expires_at > Utc::now() + chrono::Duration::seconds(60));
        assert_eq!(
            store.get_job_by_run_id(submitted.run.id).unwrap().version,
            submitted.version
        );
    }

    #[test]
    fn expired_lease_atomically_fails_run_and_releases_capacity() {
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
        let expired = store.get_job_by_run_id(submitted.run.id).unwrap();
        assert_eq!(expired.run.state, JobState::Failed);
        assert!(expired
            .run
            .error
            .as_deref()
            .unwrap()
            .contains("lease expired"));
        assert_eq!(expired.version, submitted.version + 1);
        assert_eq!(store.active_lease_count(worker.id).unwrap(), 0);

        let mut next = job();
        next.id = Uuid::new_v4();
        assert!(store.submit_job(&next, None, &Scheduler::default()).is_ok());
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
        let directory = std::env::temp_dir().join(format!("cyc-store-{}", Uuid::new_v4()));
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
        let directory = std::env::temp_dir().join(format!("cyc-store-{}", Uuid::new_v4()));
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
    fn concurrent_claim_is_single_winner_and_run_secret_isolated() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        let paired = pair_worker(&store, &worker);
        store
            .submit_job(&job(), None, &Scheduler::default())
            .unwrap();
        let barrier = Arc::new(std::sync::Barrier::new(3));
        let mut handles = Vec::new();
        for _ in 0..2 {
            let store = store.clone();
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
        assert_eq!(store.active_lease_count(worker.id).unwrap(), 0);
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
