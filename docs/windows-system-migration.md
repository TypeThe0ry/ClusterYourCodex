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

`stage_identity_documents` can now write caller-supplied, digest-validated bytes
into an exclusively created private target. It revalidates target documents and
inventory, requires the current credential, rejects unreferenced inputs, and
preserves exact bytes. A protected `.migration-stage.json` records file hashes
and copying/staged status with `activationAllowed=false`. It rejects retries
against any existing root and retains partial output for recovery inspection.
It does not read old files: the coordinator still must establish stable source
handles, old-owner ACL verification, quiescence, and recovery before exposing
this through a migration command. Staging is not a service migration receipt.

Inspect a protected staging directory as its owning identity:

```powershell
cyc-worker migration-status --config C:\ProgramData\ClusterYourCodex\worker\config.json --pretty
```

This command is read-only. A `copying` receipt reports zero verified files and
never implies completion. A `staged` receipt is accepted only after bounded
reads, private ACL checks, strict schemas, current credential/ledger binding,
exact file inventory and all recorded SHA-256 checks. Extra entries, missing
files, path traversal and changed contents fail with a nonzero exit. Public
output contains only phase, verified-file count and `activationAllowed=false`;
no credentials or identity documents. This is an inspection command, not the
unfinished migration/rollback coordinator or evidence of controller authentication.

On Windows, `security::LockedMigrationSource` now pins source files and ancestor
directories with native read handles. The file denies write/delete sharing;
ancestor handles deny delete sharing to prevent path rebinding. It verifies the
explicit old-owner SID against the existing parent/file ACL contract using only
the verify action, and performs bounded reads without printing contents. The
coordinator must retain these handles through staging and derive the SID from
verified installation metadata; this primitive does not establish quiescence,
acquire pairing/run locks, or switch tasks. Linux/macOS have no equivalent
migration-source API yet and must not silently inherit Windows acceptance.

`migration::LockedMigrationInputs::open(...).stage()` now connects the pinned
source files to protected staging. It reads config, ledger and generation under
the explicit old-owner contract, retains handles for all present referenced
credentials, and keeps them alive through target verification. Credential buffers
are cleared when the snapshot is dropped, including error paths. The coordinator
must still stop/verify the original task and reconcile pending work first; this
API alone does not authorize activation or implement rollback of a task switch.

Normal config load/write and pair entry now reject any `.migration-stage.json`
entry (including malformed files or links). Consequently `run`, `status`, and
`pair` cannot consume an unfinished staging directory. `migration-status` uses
its dedicated read-only parser and remains available. The future coordinator
must retire staging explicitly as part of its durable activation/rollback
sequence; changing the receipt's phase alone does not enable the worker.

Pinned-input acquisition and staging both perform read-only residual checks:
reject old repair transaction/staging entries, verify workspace ACLs against the
old owner, reject any containment quarantine entry, and reject nonempty job roots
(including unfinished cleanup directories). No residual is removed or treated
as completed history. This does not replace live task/process/lease checks or
external hostile-isolation reconciliation; those are coordinator responsibilities.

## Why ordinary Repair is insufficient

### Fresh named instance alternative (implementation in progress)

The Windows installer now accepts `-InstanceName <name>` (1-32 ASCII lowercase
letters/digits/hyphens, first character alphanumeric). Named instances derive
separate install/data/workspace roots and use `ClusterYourCodex Worker - <name>`
as the task name. System roots are below Program Files/ProgramData; user roots
are below LocalAppData. An instance-specific ownership marker rejects a root
belonging to another instance before transaction recovery. The SYSTEM handoff
preserves the instance parameter. Omitting it retains the legacy default task,
roots and marker.

New repair journals bind the task name. Named instances reject missing or
foreign journal bindings before stopping a task or restoring files; legacy
unbound journals remain valid only for the default task. Mock task-selection
tests execute the real snapshot/removal/restoration functions with legacy,
alpha and beta tasks, confirming that alpha operations leave both other tasks
unchanged. These mocks do not establish Task Scheduler or process persistence.

Always supply the same instance name and scope for Install, Repair and
Uninstall. Arbitrary custom roots and PurgeData are rejected for named
instances. Uninstall preserves data. This is a fresh identity path, not an
identity-preserving migration and not permission to stop/remove an old task.

Layout/name validation and WhatIf entry tests pass on Windows PowerShell 5.1,
as does the existing SYSTEM dispatch fixture. The full Worker Kit regression
started before final edits also passed. Exact-commit CI, signed-kit publication,
remote enrollment transfer and native
persistent-service acceptance remain pending. No named instance has been
deployed by this change.

The source GUI advanced form, native request/view DTOs, durable computer
configuration and Windows SSH lifecycle arguments now carry windowsInstanceName.
The field is optional for old records. Named configurations reject custom
workspaces; non-Windows lifecycle use is rejected. Four locale labels and the
frontend's 105 tests/type checks/production build pass. The running desktop
has not been replaced, so this is source integration, not live GUI acceptance.
All 43 provisioning library tests pass, including legacy-record decoding,
named-instance serialization round trip, invalid names and workspace conflict
rejection and Windows lifecycle instance argument selection. Native cargo check
and cargo check --tests pass. All 81 native library tests pass, including the
native store-reopen test;
neither compile checks nor simulated SSH prove remote installation acceptance.

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
  Preserve record IDs, digests, states, and timestamps. The document conversion
  returns a deduplicated source/target/digest inventory and rejects conflicting
  digests for one path. The current credential is required. Historical entries
  may already be absent after completed cleanup: never recreate them. Validate
  and copy any still-present referenced credential through the protected
  transaction, not by an unbounded directory copy.
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
