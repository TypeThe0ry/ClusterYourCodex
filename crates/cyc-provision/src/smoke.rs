use sha2::{Digest, Sha256};
use uuid::Uuid;

const SMOKE_OPERATION_NAME: &str = "run_smoke_check";

/// Stable idempotency key for one provisioning cycle's managed smoke run.
///
/// This spelling is persisted indirectly through controller job identity. It
/// must not change when the smoke workflow is split into prepare and poll
/// phases, otherwise a restart could submit a second job.
#[must_use]
pub fn canonical_smoke_operation_id(record_id: Uuid, cycle: u32) -> String {
    format!("{record_id}:{cycle}:{SMOKE_OPERATION_NAME}")
}

/// Deterministic controller job identity for one provisioning smoke run.
///
/// The UUID shape intentionally matches the historical desktop smoke helper:
/// the first 128 bits of SHA-256 with RFC variant and version-five bits set.
#[must_use]
pub fn canonical_smoke_job_id(record_id: Uuid, cycle: u32) -> Uuid {
    let digest = Sha256::digest(canonical_smoke_operation_id(record_id, cycle).as_bytes());
    let mut bytes = [0_u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x50;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Uuid::from_bytes(bytes)
}

#[cfg(test)]
mod tests {
    use super::{canonical_smoke_job_id, canonical_smoke_operation_id};
    use uuid::Uuid;

    #[test]
    fn canonical_identity_is_stable_and_domain_separated_by_cycle() {
        let record_id = Uuid::parse_str("01234567-89ab-cdef-0123-456789abcdef").unwrap();
        assert_eq!(
            canonical_smoke_operation_id(record_id, 7),
            "01234567-89ab-cdef-0123-456789abcdef:7:run_smoke_check"
        );

        let job_id = canonical_smoke_job_id(record_id, 7);
        assert_eq!(
            job_id,
            Uuid::parse_str("68ece739-bedf-5597-a4a2-b73e0a291ea5").unwrap()
        );
        assert_eq!(job_id.get_version_num(), 5);
        assert_ne!(job_id, canonical_smoke_job_id(record_id, 8));
        assert_eq!(job_id, canonical_smoke_job_id(record_id, 7));
    }
}
