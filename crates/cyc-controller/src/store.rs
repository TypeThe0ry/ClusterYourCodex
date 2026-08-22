use std::collections::BTreeMap;
use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use chrono::{DateTime, Utc};
use cyc_protocol::{JobKind, JobSpec, JobState, Node, Run};
use cyc_scheduler::{PlacementDecision, ScheduleError, Scheduler};
use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use serde_json::Value;
use sha2::{Digest, Sha256};
use thiserror::Error;
use uuid::Uuid;

pub const PLAN_TTL_SECONDS: i64 = 60;
pub const NODE_FRESHNESS_SECONDS: i64 = 120;
pub const POLICY_REVISION: i64 = 2;
const DEFAULT_LEASE_SECONDS: u64 = 900;
const LEASE_GRACE_SECONDS: u64 = 300;

#[derive(Debug, Error)]
pub enum StoreError {
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
    #[error("plan has expired")]
    PlanExpired,
    #[error("plan no longer matches controller state")]
    PlanStale,
    #[error("plan JobSpec digest does not match")]
    PlanDigestMismatch,
    #[error("placement failed")]
    Schedule(#[from] ScheduleError),
}

pub type StoreResult<T> = Result<T, StoreError>;

#[derive(Clone)]
pub struct Store {
    connection: Arc<Mutex<Connection>>,
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
        Self::from_connection(Connection::open(path)?)
    }

    pub fn in_memory() -> StoreResult<Self> {
        Self::from_connection(Connection::open_in_memory()?)
    }

    fn from_connection(connection: Connection) -> StoreResult<Self> {
        connection.busy_timeout(Duration::from_secs(5))?;
        connection.pragma_update(None, "foreign_keys", "ON")?;
        connection.pragma_update(None, "journal_mode", "WAL")?;
        connection.pragma_update(None, "synchronous", "NORMAL")?;
        let store = Self {
            connection: Arc::new(Mutex::new(connection)),
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
            "#,
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

    pub fn journal_mode(&self) -> StoreResult<String> {
        Ok(self
            .connection()?
            .query_row("PRAGMA journal_mode", [], |row| row.get(0))?)
    }

    pub fn upsert_node(&self, node: &Node) -> StoreResult<()> {
        let document = serde_json::to_string(node)?;
        let mut connection = self.connection()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
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
            increment_meta(&transaction, "fleet_revision")?;
        }
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

pub fn canonical_job_digest(job: &JobSpec) -> StoreResult<String> {
    let value = serde_json::to_value(normalize_job_spec(job))?;
    let mut canonical = Vec::new();
    write_canonical_json(&value, &mut canonical)?;
    let digest = Sha256::digest(canonical);
    Ok(digest.iter().map(|byte| format!("{byte:02x}")).collect())
}

pub fn normalize_job_spec(job: &JobSpec) -> JobSpec {
    let mut normalized = job.clone();
    if normalized.requirements.min_cpu_cores.is_none() {
        normalized.requirements.min_cpu_cores = Some(1);
    }
    normalized
}

fn scheduling_material_equal(left: &Node, right: &Node) -> bool {
    let mut left = left.clone();
    let mut right = right.clone();
    left.last_seen_at = None;
    right.last_seen_at = None;
    left == right
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

fn write_canonical_json(value: &Value, output: &mut Vec<u8>) -> StoreResult<()> {
    match value {
        Value::Null | Value::Bool(_) | Value::Number(_) | Value::String(_) => {
            serde_json::to_writer(&mut *output, value)?;
        }
        Value::Array(values) => {
            output.push(b'[');
            for (index, value) in values.iter().enumerate() {
                if index > 0 {
                    output.push(b',');
                }
                write_canonical_json(value, output)?;
            }
            output.push(b']');
        }
        Value::Object(values) => {
            output.push(b'{');
            let mut keys = values.keys().collect::<Vec<_>>();
            keys.sort_unstable();
            for (index, key) in keys.into_iter().enumerate() {
                if index > 0 {
                    output.push(b',');
                }
                serde_json::to_writer(&mut *output, key)?;
                output.push(b':');
                write_canonical_json(&values[key], output)?;
            }
            output.push(b'}');
        }
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
    let mut statement = transaction
        .prepare("SELECT document, updated_at, revision FROM nodes ORDER BY updated_at DESC")?;
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
    use cyc_protocol::{
        Architecture, GpuDevice, GpuRequirement, GpuVendor, JobKind, JobStep, NodeResources,
        NodeStatus, NodeTransport, OperatingSystem, SourceSpec,
    };

    use super::*;

    fn node() -> Node {
        let mut node = Node::new(
            "test-worker",
            NodeTransport::Local,
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
                revision: "0123456789abcdef".to_owned(),
            },
            vec![JobStep::new("build", "cargo build --locked")],
        )
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
    fn plan_digest_revision_and_single_use_are_enforced() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        store.upsert_node(&worker).unwrap();
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
        store.upsert_node(&changed).unwrap();
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
        store.upsert_node(&worker).unwrap();
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
        store.upsert_node(&worker).unwrap();
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
        store.upsert_node(&worker).unwrap();
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
        store.upsert_node(&worker).unwrap();
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
        store.upsert_node(&worker).unwrap();
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
        store.upsert_node(&worker).unwrap();
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
        store.upsert_node(&worker).unwrap();
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
        store.upsert_node(&worker).unwrap();
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
        store.upsert_node(&node()).unwrap();
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
        let store = Store::open(directory.join("controller.db")).unwrap();
        assert_eq!(store.journal_mode().unwrap().to_ascii_lowercase(), "wal");
        drop(store);
        std::fs::remove_dir_all(directory).unwrap();
    }
}
