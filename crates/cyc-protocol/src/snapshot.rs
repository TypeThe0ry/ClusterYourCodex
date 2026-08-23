//! Versioned source-snapshot archive contract.
//!
//! A snapshot is one deterministic `tar.zst` file. Its identity is the
//! SHA-256 of the archive bytes exactly as uploaded (not the tar payload, an
//! extracted tree, or a JSON wrapper). `sizeBytes` is part of every assignment
//! and must match those same archive bytes exactly.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;

pub const SNAPSHOT_API_VERSION: &str = "cyc.dev/snapshot/v1";
pub const SNAPSHOT_ARCHIVE_FORMAT: &str = "tar+zstd";
pub const SNAPSHOT_MEDIA_TYPE: &str = "application/vnd.cyc.snapshot.tar+zstd";

/// Maximum compressed archive accepted by the controller and worker.
pub const MAX_SNAPSHOT_ARCHIVE_BYTES: u64 = 64 * 1024 * 1024;
/// Maximum number of regular files plus explicit directory entries.
pub const MAX_SNAPSHOT_ENTRIES: u64 = 10_000;
/// Maximum size of one extracted regular file.
pub const MAX_SNAPSHOT_FILE_BYTES: u64 = 64 * 1024 * 1024;
/// Maximum sum of all extracted regular-file bytes.
pub const MAX_SNAPSHOT_EXPANDED_BYTES: u64 = 512 * 1024 * 1024;
/// Maximum portable UTF-8 archive path length.
pub const MAX_SNAPSHOT_PATH_BYTES: usize = 1_024;

#[derive(Debug, Error, Clone, Eq, PartialEq)]
pub enum SnapshotContractError {
    #[error("snapshot digest must be sha256 followed by 64 lowercase hex digits")]
    InvalidDigest,
    #[error("snapshot sizeBytes must be in the supported bounded range")]
    InvalidSize,
    #[error("snapshot API version is unsupported")]
    InvalidVersion,
    #[error("snapshot archive format is unsupported")]
    InvalidFormat,
}

pub fn validate_snapshot_digest(value: &str) -> Result<(), SnapshotContractError> {
    let Some(hex) = value.strip_prefix("sha256:") else {
        return Err(SnapshotContractError::InvalidDigest);
    };
    if hex.len() != 64
        || !hex
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(SnapshotContractError::InvalidDigest);
    }
    Ok(())
}

pub fn snapshot_digest_hex(value: &str) -> Result<&str, SnapshotContractError> {
    validate_snapshot_digest(value)?;
    Ok(&value["sha256:".len()..])
}

pub fn validate_snapshot_size(size_bytes: u64) -> Result<(), SnapshotContractError> {
    if !(1..=MAX_SNAPSHOT_ARCHIVE_BYTES).contains(&size_bytes) {
        return Err(SnapshotContractError::InvalidSize);
    }
    Ok(())
}

/// Immutable controller metadata for one content-addressed archive.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SnapshotMetadataV1 {
    pub api_version: String,
    pub format: String,
    pub digest: String,
    pub size_bytes: u64,
    pub created_at: DateTime<Utc>,
}

impl SnapshotMetadataV1 {
    pub fn new(digest: String, size_bytes: u64, created_at: DateTime<Utc>) -> Self {
        Self {
            api_version: SNAPSHOT_API_VERSION.to_owned(),
            format: SNAPSHOT_ARCHIVE_FORMAT.to_owned(),
            digest,
            size_bytes,
            created_at,
        }
    }

    pub fn validate(&self) -> Result<(), SnapshotContractError> {
        if self.api_version != SNAPSHOT_API_VERSION {
            return Err(SnapshotContractError::InvalidVersion);
        }
        if self.format != SNAPSHOT_ARCHIVE_FORMAT {
            return Err(SnapshotContractError::InvalidFormat);
        }
        validate_snapshot_digest(&self.digest)?;
        validate_snapshot_size(self.size_bytes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn digest_and_size_bind_bounded_raw_archive_identity() {
        let digest = format!("sha256:{}", "a".repeat(64));
        assert_eq!(snapshot_digest_hex(&digest).unwrap(), "a".repeat(64));
        assert!(validate_snapshot_digest(&format!("sha256:{}", "A".repeat(64))).is_err());
        assert!(validate_snapshot_size(0).is_err());
        assert!(validate_snapshot_size(MAX_SNAPSHOT_ARCHIVE_BYTES + 1).is_err());
    }

    #[test]
    fn metadata_is_strict_and_versioned() {
        let metadata =
            SnapshotMetadataV1::new(format!("sha256:{}", "b".repeat(64)), 42, Utc::now());
        metadata.validate().unwrap();
        let mut value = serde_json::to_value(metadata).unwrap();
        value["unexpected"] = serde_json::json!(true);
        assert!(serde_json::from_value::<SnapshotMetadataV1>(value).is_err());
    }
}
