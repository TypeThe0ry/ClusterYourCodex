use std::{
    path::Path,
    sync::{Mutex, MutexGuard},
    time::Duration as StdDuration,
};

use chrono::{DateTime, Duration, SecondsFormat, Utc};
use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};
use thiserror::Error;
use uuid::Uuid;

use crate::{ComputerRecord, RecordValidationError};

const SCHEMA_VERSION: i64 = 1;

/// Synchronous SQLite checkpoint store. Tauri can own this behind its normal
/// managed state and call it from blocking commands without an async runtime.
pub struct ProvisioningStore {
    connection: Mutex<Connection>,
}

impl ProvisioningStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, StoreError> {
        Self::from_connection(Connection::open(path)?)
    }

    pub fn in_memory() -> Result<Self, StoreError> {
        Self::from_connection(Connection::open_in_memory()?)
    }

    fn from_connection(connection: Connection) -> Result<Self, StoreError> {
        connection.busy_timeout(StdDuration::from_secs(5))?;
        connection.execute_batch("PRAGMA foreign_keys = ON;")?;
        let version: i64 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
        if version > SCHEMA_VERSION {
            return Err(StoreError::UnsupportedSchema(version));
        }
        if version == 0 {
            connection.execute_batch(
                "BEGIN IMMEDIATE;
                 CREATE TABLE IF NOT EXISTS provision_computers (
                   id TEXT PRIMARY KEY NOT NULL,
                   revision INTEGER NOT NULL CHECK (revision > 0),
                   created_at TEXT NOT NULL,
                   updated_at TEXT NOT NULL,
                   document TEXT NOT NULL
                 );
                 CREATE INDEX IF NOT EXISTS idx_provision_computers_updated
                   ON provision_computers(updated_at DESC);
                 PRAGMA user_version = 1;
                 COMMIT;",
            )?;
        }
        Ok(Self {
            connection: Mutex::new(connection),
        })
    }

    pub fn insert(&self, record: &ComputerRecord) -> Result<(), StoreError> {
        record.validate()?;
        if record.revision != 1 {
            return Err(StoreError::InvalidInitialRevision);
        }
        let document = serde_json::to_string(record)?;
        let connection = self.lock()?;
        let result = connection.execute(
            "INSERT INTO provision_computers(id, revision, created_at, updated_at, document)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                record.id.to_string(),
                revision_to_i64(record.revision)?,
                timestamp_text(record.created_at),
                timestamp_text(record.updated_at),
                document,
            ],
        );
        match result {
            Ok(_) => Ok(()),
            Err(error)
                if error.sqlite_error_code() == Some(rusqlite::ErrorCode::ConstraintViolation) =>
            {
                Err(StoreError::AlreadyExists(record.id))
            }
            Err(error) => Err(StoreError::Sqlite(error)),
        }
    }

    pub fn get(&self, id: Uuid) -> Result<ComputerRecord, StoreError> {
        let connection = self.lock()?;
        load_record(&connection, id)
    }

    pub fn list(&self) -> Result<Vec<ComputerRecord>, StoreError> {
        let connection = self.lock()?;
        let mut statement = connection.prepare(
            "SELECT id, revision, created_at, updated_at, document
             FROM provision_computers
             ORDER BY updated_at DESC, id ASC",
        )?;
        let mut rows = statement.query([])?;
        let mut records = Vec::new();
        while let Some(row) = rows.next()? {
            let id_text: String = row.get(0)?;
            let revision: i64 = row.get(1)?;
            let created_at: String = row.get(2)?;
            let updated_at: String = row.get(3)?;
            let document: String = row.get(4)?;
            let id = Uuid::parse_str(&id_text).map_err(|_| StoreError::CorruptRecord)?;
            records.push(parse_record(
                id,
                revision,
                &created_at,
                &updated_at,
                &document,
            )?);
        }
        Ok(records)
    }

    pub(crate) fn save_cas(
        &self,
        mut record: ComputerRecord,
        expected_revision: u64,
    ) -> Result<ComputerRecord, StoreError> {
        if record.revision != expected_revision {
            return Err(StoreError::Conflict {
                expected: expected_revision,
                actual: Some(record.revision),
            });
        }

        let mut connection = self.lock()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let current = load_record(&transaction, record.id)?;
        if current.revision != expected_revision {
            return Err(StoreError::Conflict {
                expected: expected_revision,
                actual: Some(current.revision),
            });
        }
        if current.id != record.id
            || current.intended_node_id != record.intended_node_id
            || current.created_at != record.created_at
        {
            return Err(StoreError::ImmutableFieldChanged);
        }

        record.revision = expected_revision
            .checked_add(1)
            .ok_or(StoreError::RevisionOverflow)?;
        record.updated_at = monotonic_now(current.updated_at);
        record.validate()?;
        let document = serde_json::to_string(&record)?;
        let changed = transaction.execute(
            "UPDATE provision_computers
             SET revision = ?1, updated_at = ?2, document = ?3
             WHERE id = ?4 AND revision = ?5",
            params![
                revision_to_i64(record.revision)?,
                timestamp_text(record.updated_at),
                document,
                record.id.to_string(),
                revision_to_i64(expected_revision)?,
            ],
        )?;
        if changed != 1 {
            return Err(StoreError::Conflict {
                expected: expected_revision,
                actual: None,
            });
        }
        transaction.commit()?;
        Ok(record)
    }

    pub(crate) fn delete_cas(&self, id: Uuid, expected_revision: u64) -> Result<(), StoreError> {
        let connection = self.lock()?;
        let changed = connection.execute(
            "DELETE FROM provision_computers WHERE id = ?1 AND revision = ?2",
            params![id.to_string(), revision_to_i64(expected_revision)?],
        )?;
        if changed == 1 {
            return Ok(());
        }
        let actual = connection
            .query_row(
                "SELECT revision FROM provision_computers WHERE id = ?1",
                [id.to_string()],
                |row| row.get::<_, i64>(0),
            )
            .optional()?
            .map(revision_from_i64)
            .transpose()?;
        if actual.is_none() {
            Err(StoreError::NotFound(id))
        } else {
            Err(StoreError::Conflict {
                expected: expected_revision,
                actual,
            })
        }
    }

    fn lock(&self) -> Result<MutexGuard<'_, Connection>, StoreError> {
        self.connection.lock().map_err(|_| StoreError::LockPoisoned)
    }
}

fn load_record(connection: &Connection, id: Uuid) -> Result<ComputerRecord, StoreError> {
    let row = connection
        .query_row(
            "SELECT revision, created_at, updated_at, document
             FROM provision_computers WHERE id = ?1",
            [id.to_string()],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                ))
            },
        )
        .optional()?
        .ok_or(StoreError::NotFound(id))?;
    parse_record(id, row.0, &row.1, &row.2, &row.3)
}

fn parse_record(
    id: Uuid,
    revision: i64,
    created_at: &str,
    updated_at: &str,
    document: &str,
) -> Result<ComputerRecord, StoreError> {
    let record: ComputerRecord =
        serde_json::from_str(document).map_err(|_| StoreError::CorruptRecord)?;
    if record.id != id
        || record.revision != revision_from_i64(revision)?
        || record.created_at != parse_timestamp(created_at)?
        || record.updated_at != parse_timestamp(updated_at)?
    {
        return Err(StoreError::CorruptRecord);
    }
    record.validate().map_err(StoreError::Validation)?;
    Ok(record)
}

fn timestamp_text(value: DateTime<Utc>) -> String {
    value.to_rfc3339_opts(SecondsFormat::Nanos, true)
}

fn parse_timestamp(value: &str) -> Result<DateTime<Utc>, StoreError> {
    DateTime::parse_from_rfc3339(value)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|_| StoreError::CorruptRecord)
}

fn revision_to_i64(revision: u64) -> Result<i64, StoreError> {
    i64::try_from(revision).map_err(|_| StoreError::RevisionOverflow)
}

fn revision_from_i64(revision: i64) -> Result<u64, StoreError> {
    u64::try_from(revision).map_err(|_| StoreError::CorruptRecord)
}

fn monotonic_now(previous: DateTime<Utc>) -> DateTime<Utc> {
    let now = Utc::now();
    if now > previous {
        now
    } else {
        previous + Duration::microseconds(1)
    }
}

#[derive(Debug, Error)]
pub enum StoreError {
    #[error("provisioning database error: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("provisioning record serialization failed: {0}")]
    Serialization(#[from] serde_json::Error),
    #[error("provisioning record validation failed: {0}")]
    Validation(#[from] RecordValidationError),
    #[error("computer {0} was not found")]
    NotFound(Uuid),
    #[error("computer {0} already exists")]
    AlreadyExists(Uuid),
    #[error("provisioning revision conflict (expected {expected}, actual {actual:?})")]
    Conflict { expected: u64, actual: Option<u64> },
    #[error("provisioning database schema {0} is newer than this application")]
    UnsupportedSchema(i64),
    #[error("provisioning store lock was poisoned")]
    LockPoisoned,
    #[error("provisioning record is corrupt")]
    CorruptRecord,
    #[error("initial provisioning revision must be one")]
    InvalidInitialRevision,
    #[error("immutable provisioning identity changed")]
    ImmutableFieldChanged,
    #[error("provisioning revision overflow")]
    RevisionOverflow,
}
