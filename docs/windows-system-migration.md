# Windows user-owned state to SYSTEM migration

Status: implementation plan, not an available installer action or accepted live migration.

Implemented building blocks: `WorkerConfig::relocated` and
`runtime::relocate_pairing_ledger` build validated in-memory documents without
credential reads, filesystem writes, or network calls. They preserve identity
fields, validate old ledger ownership bindings before rewriting, reject pending
pairing/cleanup, and validate the new ledger. They are not yet connected to a
migration journal or CLI. `migration::relocate_identity_documents` now validates
config, acknowledged ledger identity, and boot generation together, preserving
the boot-generation document byte-for-byte. No target documents are returned
when any input is invalid. Durable boot-generation copying, source ACL verification,
quiescence, task switching, recovery, and live acceptance remain to implement.

## Why ordinary Repair is insufficient

The legacy failure mode has a SYSTEM task pointing at user-owned worker state.
The new installer correctly creates SYSTEM-owned state, but ordinary Repair
binds one owner, one data root, and one task action. Neither relaxing its ACL
validation nor copying its repair journal implements a cross-root migration.

## Identity-preserving state

- Keep controllerId, nodeId, workerUrl, certificatePem, protocol and heartbeat
  settings unchanged. Do not re-enroll or mint a replacement node identity.
- Rewrite config workspaceRoot and credentialFile to verified target roots.
- Copy credential bytes without displaying them. Worker credentials are private
  UTF-8 files, not user-bound DPAPI ciphertext. Controller SSH credentials are
  a separate Credential Manager concern and must not be migrated.
- Parse the pairing ledger and rewrite its credentialFile and
  previousCredentialFile entries to direct children of the new config directory.
  Preserve record IDs, digests, states, and timestamps; copy every referenced
  credential after validation, not just the current one.
- Preserve boot-generation state. The first target startup must advance it;
  resetting generation can make valid new telemetry look obsolete.
- Do not copy lock ownership. Acquire locks with both old and new instances
  stopped. Reject pending repair journals until their original recovery finishes.
- Regenerate the installation manifest for the new roots. Keep the old task
  XML and old files as rollback evidence.

## Required transactional sequence

1. Validate explicit old roots/owner SID, marker, manifest, binary hash, and
   task executable/config/working-directory binding. Reject reparse points and
   unsupported schemas. Do not take ownership of the old tree.
2. Ensure no active lease, foreground worker, pairing operation, unresolved run,
   quarantine, or external reconciliation obligation exists. Disable/stop only
   the verified task and preserve its prior state.
3. Create a protected SYSTEM migration journal with both roots, bounded file
   inventory, source hashes, old task XML, and durable phase. No secrets in logs.
4. Copy validated identity files with stable source reads into newly protected
   SYSTEM destinations. Rewrite only the documented path fields. Preserve old
   source data. An empty new workspace is allowed only after residual-work checks;
   completed historical work may remain archived in the old workspace.
5. Run worker status under SYSTEM and verify identity and protected credentials.
   This is local validation, not proof of controller authentication.
6. Replace only the still-matching old task with the new installer-owned binding.
   Reuse the existing identity without an enrollment document.
7. Require a fresh same-node heartbeat with advanced generation, a task stop/start
   cycle, and a real job with verified exit, logs, and artifact hash.
8. Commit the journal only after verification. On failure, stop/remove only the
   new binding and restore the original XML/state; retain target evidence and all
   original data. Interrupted operations must resume or roll back from the journal.

## Code references

- `crates/cyc-worker/src/config.rs`: WorkerConfig and boot generation.
- `crates/cyc-worker/src/security.rs`: credential file/owner contract.
- `crates/cyc-worker/src/runtime.rs`: pairing ledger and residual reconciliation.
- `crates/cyc-secrets/src/windows.rs`: separate controller Credential Manager store.
- `packaging/worker-kits/windows/Install-Worker.ps1`: task ownership and same-root repair journal.

Native SYSTEM ACL acceptance is already recorded in project-status.md. It does
not prove any of the migration sequence above; do not label this plan complete.
