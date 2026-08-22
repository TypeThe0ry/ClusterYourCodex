use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard};

use chrono::Utc;
use cyc_protocol::{JobSpec, JobState, Node, Run};
use cyc_scheduler::PlacementDecision;
use rusqlite::{params, Connection, OptionalExtension};
use thiserror::Error;
use uuid::Uuid;

#[derive(Debug, Error)]
pub enum StoreError {
    #[error("database operation failed")]
    Database(#[from] rusqlite::Error),
    #[error("stored document is invalid")]
    Document(#[from] serde_json::Error),
    #[error("stored identifier is invalid")]
    Identifier(#[from] uuid::Error),
    #[error("controller database lock is poisoned")]
    Poisoned,
    #[error("job or plan does not exist")]
    NotFound,
    #[error("job already exists")]
    Conflict,
    #[error("invalid state transition")]
    InvalidTransition,
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
}

#[derive(Debug, Clone)]
pub struct StoredPlan {
    pub job_id: Uuid,
    pub decision: PlacementDecision,
}

impl Store {
    pub fn open(path: impl AsRef<Path>) -> StoreResult<Self> {
        let connection = Connection::open(path)?;
        Self::from_connection(connection)
    }

    pub fn in_memory() -> StoreResult<Self> {
        Self::from_connection(Connection::open_in_memory()?)
    }

    fn from_connection(connection: Connection) -> StoreResult<Self> {
        connection.pragma_update(None, "foreign_keys", "ON")?;
        connection.busy_timeout(std::time::Duration::from_secs(5))?;
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
        self.connection()?.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS nodes (
                id          TEXT PRIMARY KEY NOT NULL,
                document    TEXT NOT NULL,
                updated_at  TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS plans (
                id          TEXT PRIMARY KEY NOT NULL,
                job_id      TEXT NOT NULL,
                decision    TEXT NOT NULL,
                created_at  TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS jobs (
                run_id      TEXT PRIMARY KEY NOT NULL,
                job_id      TEXT UNIQUE NOT NULL,
                job         TEXT NOT NULL,
                run         TEXT NOT NULL,
                created_at  TEXT NOT NULL,
                updated_at  TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS jobs_updated_at_idx ON jobs(updated_at DESC);
            "#,
        )?;
        Ok(())
    }

    pub fn ping(&self) -> StoreResult<()> {
        self.connection()?
            .query_row("SELECT 1", [], |_row| Ok(()))?;
        Ok(())
    }

    pub fn upsert_node(&self, node: &Node) -> StoreResult<()> {
        let document = serde_json::to_string(node)?;
        self.connection()?.execute(
            r#"
            INSERT INTO nodes(id, document, updated_at) VALUES (?1, ?2, ?3)
            ON CONFLICT(id) DO UPDATE SET document=excluded.document, updated_at=excluded.updated_at
            "#,
            params![node.id.to_string(), document, Utc::now().to_rfc3339()],
        )?;
        Ok(())
    }

    pub fn list_nodes(&self) -> StoreResult<Vec<Node>> {
        let connection = self.connection()?;
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

    pub fn insert_plan(
        &self,
        plan_id: Uuid,
        job_id: Uuid,
        decision: &PlacementDecision,
    ) -> StoreResult<()> {
        self.connection()?.execute(
            "INSERT INTO plans(id, job_id, decision, created_at) VALUES (?1, ?2, ?3, ?4)",
            params![
                plan_id.to_string(),
                job_id.to_string(),
                serde_json::to_string(decision)?,
                Utc::now().to_rfc3339()
            ],
        )?;
        Ok(())
    }

    pub fn get_plan(&self, plan_id: Uuid) -> StoreResult<StoredPlan> {
        let row = self
            .connection()?
            .query_row(
                "SELECT job_id, decision FROM plans WHERE id = ?1",
                [plan_id.to_string()],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()?
            .ok_or(StoreError::NotFound)?;
        Ok(StoredPlan {
            job_id: Uuid::parse_str(&row.0)?,
            decision: serde_json::from_str(&row.1)?,
        })
    }

    pub fn insert_job(&self, job: &JobSpec, run: &Run) -> StoreResult<()> {
        let connection = self.connection()?;
        let now = Utc::now().to_rfc3339();
        match connection.execute(
            r#"
            INSERT INTO jobs(run_id, job_id, job, run, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?5)
            "#,
            params![
                run.id.to_string(),
                job.id.to_string(),
                serde_json::to_string(job)?,
                serde_json::to_string(run)?,
                now,
            ],
        ) {
            Ok(_) => Ok(()),
            Err(error)
                if error.sqlite_error_code() == Some(rusqlite::ErrorCode::ConstraintViolation) =>
            {
                Err(StoreError::Conflict)
            }
            Err(error) => Err(error.into()),
        }
    }

    pub fn get_job(&self, id: Uuid) -> StoreResult<StoredJob> {
        let row = self
            .connection()?
            .query_row(
                "SELECT job, run FROM jobs WHERE run_id = ?1 OR job_id = ?1 LIMIT 1",
                [id.to_string()],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()?
            .ok_or(StoreError::NotFound)?;
        Ok(StoredJob {
            job: serde_json::from_str(&row.0)?,
            run: serde_json::from_str(&row.1)?,
        })
    }

    pub fn list_jobs(&self, limit: usize) -> StoreResult<Vec<StoredJob>> {
        let connection = self.connection()?;
        let mut statement =
            connection.prepare("SELECT job, run FROM jobs ORDER BY updated_at DESC LIMIT ?1")?;
        let rows = statement
            .query_map([limit.min(500) as i64], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        rows.into_iter()
            .map(|(job, run)| {
                Ok(StoredJob {
                    job: serde_json::from_str(&job)?,
                    run: serde_json::from_str(&run)?,
                })
            })
            .collect()
    }

    pub fn cancel_job(&self, id: Uuid) -> StoreResult<StoredJob> {
        let mut stored = self.get_job(id)?;
        stored
            .run
            .transition(JobState::Cancelled)
            .map_err(|_| StoreError::InvalidTransition)?;
        let changed = self.connection()?.execute(
            "UPDATE jobs SET run = ?1, updated_at = ?2 WHERE run_id = ?3",
            params![
                serde_json::to_string(&stored.run)?,
                Utc::now().to_rfc3339(),
                stored.run.id.to_string()
            ],
        )?;
        if changed == 0 {
            return Err(StoreError::NotFound);
        }
        Ok(stored)
    }
}

#[cfg(test)]
mod tests {
    use cyc_protocol::{
        Architecture, JobKind, JobStep, NodeResources, NodeStatus, NodeTransport, OperatingSystem,
        SourceSpec,
    };
    use cyc_scheduler::Scheduler;

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
    fn persists_nodes_plans_jobs_and_cancellation() {
        let store = Store::in_memory().unwrap();
        let worker = node();
        store.upsert_node(&worker).unwrap();
        assert_eq!(store.list_nodes().unwrap(), vec![worker.clone()]);

        let job = job();
        let decision = Scheduler::default().schedule(&job, &[worker]).unwrap();
        let plan_id = Uuid::new_v4();
        store.insert_plan(plan_id, job.id, &decision).unwrap();
        let plan = store.get_plan(plan_id).unwrap();
        assert_eq!(plan.job_id, job.id);
        assert_eq!(plan.decision, decision);

        let mut run = Run::queued(job.id);
        run.node_id = Some(decision.node_id);
        run.placement = Some(decision.explanation);
        store.insert_job(&job, &run).unwrap();
        assert_eq!(store.get_job(run.id).unwrap().run, run);
        assert!(matches!(
            store.insert_job(&job, &Run::queued(job.id)),
            Err(StoreError::Conflict)
        ));

        let cancelled = store.cancel_job(run.id).unwrap();
        assert_eq!(cancelled.run.state, JobState::Cancelled);
        assert!(cancelled.run.finished_at.is_some());
        assert!(matches!(
            store.cancel_job(run.id),
            Err(StoreError::InvalidTransition)
        ));
    }
}
