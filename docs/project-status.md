# ClusterYourCodex project status

This is the repository's durable progress record. It is intentionally based on
the current checkout and live GitHub state, rather than on chat history. Update
it in the same pull request as every implementation, CI, packaging, or release
change.

- **Snapshot date:** 2026-09-08
- **Repository:** [TypeThe0ry/ClusterYourCodex](https://github.com/TypeThe0ry/ClusterYourCodex)
- **Snapshot baseline:** published `v0.1.0-preview.100`, source commit `2c269842dbc15934b5cfcf6a4cb3e0844cec3ed5`. Documentation and merge reconciliation may advance beyond this immutable release SHA.
- **Latest published preview:** [`v0.1.0-preview.100`](https://github.com/TypeThe0ry/ClusterYourCodex/releases/tag/v0.1.0-preview.100), published 2026-09-07 17:42:22 UTC by successful tagged workflow [`34128668756`](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/34128668756). GitHub reports `isPrerelease=true`, `isDraft=false`, and 23 assets. Windows self-contained and clean Windows 11 ARM64 compatibility acceptance both passed.
- **Previous stable-testing exception:** [`v0.1.0-preview.85`](https://github.com/TypeThe0ry/ClusterYourCodex/releases/tag/v0.1.0-preview.85) remains immutable **stable-testing** (`isPrerelease=false`) for the explicitly authorized test channel. Its embedded product version is still a preview; it is not Certified GA.
- **Release channels:** preview.100 is the current public prerelease; preview.95 remains an immutable fallback. Certified GA remains separate from operator testing; open Issues #2, #3, and #5 retain their unverified platform, signing, and isolation gates.

## Current delivery goal: core usability before polish

### Candidate CI checkpoint — 2026-09-08

PR #58 head `ff7da71ff8cce24db658ae1049b5406747898f80` passed
CI run `34235712011`. Windows workspace Rust completed successfully in
23m50s. CodeQL and dependency checks also passed. The remaining desktop job
`102093450517` has passed native tests, Clippy, Windows installer lifecycle
validation, and managed worker-kit validation. The kit validation completed at
14:38:32 UTC after 11m07s. The live Windows controller/worker step started at
that timestamp and passed. Downloaded artifact `10061628508` contains a passed
result with all 14 checks true, queued/running/succeeded transitions, and a
37-second task. Downloaded stdout contains both expected step markers. The
43-byte result.txt hashes to
`7a628a8467fea26c070c97c2be9ecbad371a2d279443a8726efb651ab3bc34b0`, matching
the controller artifact record. The result.json SHA-256 is
`2c6a2b7c99137159b4701a48647c1ce3afb78bc7e06271984e8bdd74f92685f4`.
Executed source is the PR merge ref `1f09de019589aef9d3249b45d357b37bf70b872b`;
GitHub confirms parents `2b1a755b1072c63f8e74ac08b695b480bf6a828c` and the
candidate head above. This is same-host Windows live evidence, not remote SSH
installation or persistent-service acceptance.

Auto squash merge is enabled, but seven unresolved review discussions still
block merging. In particular, the current SYSTEM dispatcher still needs review
of copied-kit validation, uninstall dependence on a complete kit, and enrollment
file staging. No discussion or branch protection was bypassed.

The named-instance tests cover layout, task ownership and lifecycle argument
selection with mocked scheduled tasks; the native persistence regression
covers reopening the computer record. Neither proves a newly installed remote
named worker survives a service restart. After signed candidate publication,
that remains the next Windows acceptance step, followed by a fresh task and
retrieved logs/artifact bytes. Local UI copy edits are not part of this CI SHA.

### Live controller check at 2026-09-08 14:04 UTC

The installed ClusterYourCodex MCP reports controller/database healthy and MCP
available, still at preview.100. Its only registered worker, Helio live usability,
is offline with stale telemetry (last accepted at 10:18:26 UTC). The reported
1251 MiB free disk is cached, not a fresh installation-capacity measurement.
The controller retains job `7c09a0be-764b-527a-a31d-1867523b2448` as succeeded,
exit 0, with artifact ID `1cc32963-cbb9-4d5a-9354-de7038fbb583`; this read does
not revalidate artifact bytes or prove ongoing persistent-service availability.
No new job was submitted to the offline worker.

Follow-up runner probes (strict known-host verification, exit 0) confirmed Helio
SSH reachable, approximately 1.5 GB free disk, and no cyc-worker process. The
default worker task is Ready (not Running), principal SYSTEM, last result 1.
Its executable/workspace target sshadmin's LocalAppData directories; installation
root, data root and config.json are owned by WS\sshadmin and are not reparse
points. Default Program Files/ProgramData worker roots and named-instance roots
do not exist. This is a confirmed principal/ownership mismatch consistent with
the worker's current-user owner validation, not a network outage. No task,
credential, ACL or worker data was changed by these probes. Exact failure stderr
under SYSTEM was not reproduced in this read-only check.

Linux fallback probes confirmed P1 reachable (exit 0), but root and the
configured workspace share an ext4 filesystem at 100% use with only 299 MB
available. No alternate persistent data filesystem was found in lsblk. /tmp
is tmpfs and is not a substitute for durable worker-service acceptance. The
queried systemd unit patterns returned no loaded worker units; this does not
prove that no differently named or disabled unit exists. NUC TCP/22 was
unavailable. No cleanup, installation or heavy job was attempted on either node.

The preview.101 debug desktop executable built successfully from the candidate
source. SHA-256: `585fff368c63916a62346db23d9407bd5358fb56dc858415245e12f5f23a51d4`.
It was not launched or installed and is not the signed distribution package.

Local candidate metadata is prepared as `0.1.0-preview.101`; no tag or release
has been created. Published preview.100 remains unchanged. The candidate must
pass exact-version checks and CI before a signed prerelease build is published.
Candidate commit `e0d58b9` passed local native library tests (81), provisioning
library tests (43), desktop tests (105), MCP tests (44), and both JS builds.
Version consistency including negative tests, changelog consistency, release
signing boundary, 63 pinned Actions references, and worker-kit signing-key
private-file protection checks also passed. The private-file check ran under
PowerShell 7 as required; its initial PowerShell 5.1 invocation was rejected
before execution. These results do not replace exact-candidate CI or deployment.

Named-instance implementation commit `f3c199a` is included in PR #58, with
squash auto-merge still enabled. Its CI run `34234534065` ended cancelled;
the current candidate run is `34235712011` for head `ff7da71`. The cancelled
run is not evidence of completed platform acceptance.
The preceding run `34230627688` ended cancelled, not successful, and must not
be cited as completed Windows desktop acceptance.
Local full worker-kit testing completed with exit 0 and
`worker-kit packaging tests passed`. It began before the final edits, so this
does not replace exact-commit CI or live installation acceptance.
All 81 native library tests passed (exit 0), including the new database-reopen
regression for named-instance configuration. The new regression exercises
the real local store with a checkpoint driver, not live SSH credential storage.

### 2026-09-08 concise desktop copy verification

Verified the running UI at `http://127.0.0.1:1420/`: Home shows fleet
counts, computers and recent tasks without the former promotional heading or
subtitle. Tasks shows filters and task rows without the tracking-description
paragraph. Task records and expandable placement details remain available.
The four locale catalogs already exclude the discarded page-copy keys.
A rendered-home regression test now checks the three removed Chinese phrases
and retains status/action content. Desktop tests: 105 passed. This is a UI
content check, not worker installation or release acceptance.

Windows installer named-instance support is now in development as an
alternative to blocking first usability on legacy identity migration. See
[scope and pending checks](windows-system-migration.md#fresh-named-instance-alternative-implementation-in-progress).
The provisioning driver now rejects a Windows instance name on a non-Windows
kit before SSH authentication or kit upload. A Linux fixture regression checks
that no transport events, uploaded files or transient-secret reads occur.
All 43 provisioning library tests now pass, including this regression.
The driver fixture also includes a signed Windows kit and asserts that Install,
Repair and Uninstall preserve the selected instance name, while the default
instance omits that argument. These simulated transport checks pass; they are
not evidence of a live Windows service installation.
Windows instance layout, journal binding and task-selection tests passed again
on the current scripts (mock tasks; no live Scheduled Task changes).
GUI/native bridge configuration propagation is implemented in source but not
deployed. All 105 frontend tests and the frontend build pass. Native cargo
check and cargo check --tests pass. The SYSTEM lifecycle dispatch fixture
passes. The earlier full worker-kit test process finished successfully;
it is not final-tree acceptance. Original worker state
is unchanged. Live named-instance installation/pairing/service/job acceptance
remains required.

### Completed CI for PR head 90bf4ae

Run `34226042054` is now successful, including the Windows desktop job and
its live controller/worker round trip. All PR checks reported pass. Downloaded
artifact `10057535165` (98417 bytes) contains a passed result with 14 true
checks, no failure, and queued/running/succeeded states. The run lasted 38s;
cleanup reports removed, jobRootDeleted true and reservationReleasedAt set.
Job ID: `695b00f1-a384-41de-b05a-eeaca7562fa1`.
Run ID: `68e854ce-a189-4173-9224-968a0c3a7f48`.
Executed merge commit: `158651c7f37660babafce34f32af4029c991b2c2`.
Downloaded result.json SHA-256:
`9ca37076e9a69cc7d13f56400f5c0093fb25fd645c1237a6fd3d3425d559b9e7`.

This is same-host Windows live execution evidence, not cross-machine SSH,
GUI credential persistence, Scheduled Task lifecycle, or GA approval.
PR #58 remained open at observation despite all reported checks passing.
Subsequent commits require their own checks; no new release was published.

Downloaded Windows same-host live execution evidence from successful ancestor
CI run `34224323417` is recorded in
[the round-trip report](windows-ci-roundtrip-34224323417.md). Its merge commit
is bound to PR head `51a1c51`; it is not evidence for newer head `90bf4ae` or
for GUI SSH installation and persistent service acceptance.

### 2026-09-08 Linux discovery capacity formatting

Latest follow-up for exact head `90bf4ae`: Windows Rust job `102060693675`
in run `34226042054` also completed successfully. Its completed log reports
121 worker library tests passed (one ignored; 993.29s) at 12:50:43 UTC and
all nine migration-document tests passed (84.52s) at 12:52:08 UTC. The desktop
job `102060693531` remained active in `Validate managed worker kits`, entered
at 12:52:22 UTC. PR #58 was still open with squash auto-merge enabled; this
observation does not establish whole-run success or a completed merge.
These CI tests do not establish live worker pairing or service persistence.

Linux disk discovery now uses explicit `awk printf "%.0f"` integer formatting,
matching macOS, instead of default numeric printing followed by decimal-point
truncation. This avoids implementation-dependent scientific notation being
truncated or rejected by the integer-only discovery protocol. The available
local Git awk printed the old 100-GiB fixture correctly, so this is a portability
repair, not a reproduced P1 root cause. Five Windows discovery tests passed;
executing the exact updated awk expression with local Git awk returned exact
0-byte, 1-KiB, 100-GiB and 1-TiB fixture values. A Unix-only native awk regression
is included for Linux/macOS CI; its execution is not claimed from Windows.

Subsequent exact-source CI `34226042054` at `90bf4ae` completed both Rust
workspace platform jobs successfully. Completed job logs explicitly report
`native_awk_disk_probe_preserves_large_capacity ... ok` on Linux (job
`102060693779`, 12:28:16 UTC) and macOS (job `102060693571`, 12:28:25 UTC).
This verifies the probe expression on both native CI platforms. Windows,
desktop and Worker Kit jobs were still running at this observation; neither
full CI success nor deployed worker acceptance is implied.

The earlier Windows workspace job `102054930277` in run `34224323417`
completed successfully at 12:30:43 UTC for `51a1c51`. Its completed log reports
all nine migration-document tests passing (91.61s). This is independent Windows
CI evidence for the migration implementation present at that ancestor, not
validation of subsequent commits or live migration of the existing worker.

### 2026-09-08 validation queue deduplication

Live GitHub inspection found several superseded PR #58 CI runs still executing
Windows workspace/desktop tests concurrently. CI, CodeQL and dependency-security
now group pull-request runs by workflow and PR number and cancel superseded
members. Non-PR runs use their unique run ID with cancellation disabled, so main,
tag and scheduled evidence is retained. Release publishing is unchanged.
Action-pin validation (63 references), signing-boundary validation and diff
checks passed. Cancellation behavior still requires a subsequent PR update to
exercise on GitHub; pre-existing runs without this group are not claimed stopped.

### 2026-09-08 strict native credential persistence acceptance

The Windows Credential Manager backend passed an explicit cross-process native
test: write a unique synthetic credential, drop the original secret allocation,
launch a fresh reader process, verify its username/value, delete the owned entry,
and confirm absence. The reader's named test and pass count are checked, not just
its exit code. This strict test fails if the vault is unavailable (including
Windows error 1312); unlike the compatibility test it never silently skips.

Reproduce on an interactive Windows controller:

```powershell
cargo test -p cyc-secrets --locked windows_credential_manager_cross_process_acceptance -- --ignored
```

Native acceptance passed (0.14s), the ordinary crate suite passed (5 tests;
2 explicitly ignored native helper/acceptance entries), scoped Clippy and
format/diff checks passed. Only unique synthetic entries in the test namespace
were created and removed. No existing SSH credential was read or changed.
This proves same-user cross-process persistence, not reboot, another user's
access, real SSH authentication, or completion of GUI onboarding.

### 2026-09-08 native desktop Linux onboarding resumed

The corresponding durable retry regression now closes/reopens SQLite twice:
after a simulated SSH probe failure, and again at host-key approval. It verifies
the same computer/node/cycle and probe operation ID, one retained record, no
credential reference before authentication, and no authentication/install calls
while awaiting approval. The targeted test and all 27 provisioning state-machine
tests passed on Windows; formatting/diff checks passed. This uses a fake SSH
driver and proves recovery semantics, not native password storage or installation.

The running preview.100 native desktop retained a Linux provisioning record
that had failed at SSH connection with `SSH_IO` (revision 3, cycle 0).
An explicit Retry advanced it to the host-key approval checkpoint (revision 6,
cycle 0). The existing record was reused; no new record, credential copy,
installation, enrollment or service activation was performed. This proves
current product SSH connectivity, not password authentication or Linux E2E.
The desktop is awaiting verification/approval of the observed host key.
The controller still reports zero available workers; its sole Windows node
is stale/offline. Existing successful job evidence remains historical.

The overview now keeps operational status visible and diagnostic metadata
collapsed; [content rules](ui-content-policy.md) record that presentation policy.
Desktop type checks, 103 frontend tests and production build passed for that
change. Native provisioning remains the priority over further UI polish.

### 2026-09-08 native Linux public-kit acceptance

P1 completed a native signed preview.100 Worker Kit install → repair → uninstall
with isolated roots and no enrollment. All lifecycle commands succeeded;
independent final assertions/version execution exited 0. The worker remained
unpaired and no service was enabled. Source archive hash, native receipts,
the combined probe's final systemctl exit 1, disk limits and retained artifacts
are recorded in [the native Linux acceptance report](linux-native-preview100-acceptance.md).
This advances native packaging acceptance, not GUI/credential/heartbeat/job E2E.
NUC SSH was unavailable; the controller still reports only stale/offline Helio.

### 2026-09-08 migration residual checks

Locked migration inputs now inspect residuals both at source acquisition and
immediately before target staging. Existing repair/migration transactions,
containment quarantine and retained job roots block copying; source workspace
ACLs must match the old owner. No cleanup is performed. Native targeted residual
tests passed (18.16s), preserving rejected markers/job roots; the ordinary locked
source-to-stage test still passed (50.69s). Scoped Clippy and diff checks passed.
Live task/process/lease checks and external guard reconciliation remain separate
unfinished coordinator requirements.

### 2026-09-08 staging activation boundary

Normal worker config load/write and pairing now reject any migration-stage
entry. This closes the gap where `activationAllowed=false` was only descriptive:
`run`/`status`/`pair` cannot use the staging directory until a future coordinator
explicitly retires it. Dedicated read-only `migration-status` remains available.
The change does not implement task switching or declare the worker available.
All nine migration tests passed (46.95s), including real CLI rejection of run,
status and pair before creation of pairing/generation locks, while inspection
still succeeds. Normal protected config publishing/loading regression passed
separately (8.15s). Scoped Clippy and diff checks passed.

### 2026-09-08 full worker-kit regression completed

The fixed-script run started at `90f21b7` completed with native exit 0 and
`worker-kit packaging tests passed`. Linux and the newly phased macOS lifecycle
fixtures both completed. The test's success cleanup removed its temporary tree
`cyc-worker-kit-test-65ff591954e14688be4b8c66aa39b438`; its Linux watchdog had
already been inspected as exit 0/no timeout. Earlier failed-run evidence remains
separate and retained. This is fixture coverage, not native Linux/macOS service
acceptance or acceptance of all subsequent Rust migration changes.

Windows `LockedMigrationInputs` now joins old-owner-verified, pinned source reads
with protected target staging while retaining all source handles through the
copy. It clears captured credential buffers on completion/error. Source task
quiescence, installation metadata ownership, interrupted transaction recovery
and live task switching still need the migration coordinator.
The native local source-to-stage test passed (exit 0, 39.21s): config and
credential writes were blocked while captured, target inspection verified four
files, and original bytes plus node/controller identity remained unchanged.
Scoped Clippy passed. The initial fixture correctly rejected a non-private
temporary parent; the rerun used a newly provisioned private destination parent.

### 2026-09-08 Windows stable migration-source reads

`LockedMigrationSource` now opens source files with read-only Windows sharing
and retains non-delete-sharing ancestor handles before verifying the explicit
old owner's existing ACLs. It never repairs ownership/permissions. The native
local regression passed: writes, file rename and parent rename fail while held;
bounded reads preserve contents; a wrong owner is rejected without changing
the source; ordinary writes work after release. Targeted test exit 0 (5.44s),
Clippy with denied warnings and diff checks passed. This is a Windows primitive,
not an implemented live SYSTEM migration or a Linux/macOS ownership check.

### 2026-09-08 migration staging inspection CLI

`cyc-worker migration-status --config <absolute config> [--pretty]` now provides
read-only staging inspection. It distinguishes incomplete copying from verified
staging, enforces bounded strict receipts and documents, checks protected files,
validates credential/ledger binding, and verifies every digest and the directory
inventory. It never authorizes activation. Source-owner-aware migration and
task-switch/rollback coordination remain unfinished.
All eight migration tests passed, including a real CLI child invocation,
changed-credential rejection, receipt path-traversal rejection and incomplete
copying inspection. The initial inspection test exposed Windows OsStr being
serialized as a platform object; staging now validates Unicode names and writes
plain JSON strings. The rerun passed in 50.64 seconds. Scoped Clippy passed.
The full packaging run `cyc-worker-kit-test-65ff591954e14688be4b8c66aa39b438`
finished its Linux fixture with exit 0/no timeout/no remaining PIDs and is now
executing the phased macOS fixture. This is not native service acceptance.

### 2026-09-08 protected migration staging

The new staging function validates all caller-supplied credential bytes before
output, exclusively creates a private destination, writes protected files,
re-reads and verifies their hashes, and records copying/staged phases in a
protected receipt. Existing target directories are never adopted or overwritten.
The receipt explicitly has `activationAllowed=false`; no old file is read or
removed, and no task switches. A native local filesystem/ACL integration test
passed for missing/wrong credentials causing no output, exact-byte preservation,
private output, secret-free receipt, and retry refusing an existing target.
This is not a completed source-ACL-aware SYSTEM migration or recovery CLI.

### 2026-09-08 migration credential inventory

Identity document conversion now returns exact credential source/target paths,
expected digests, and required/optional status for transactional copying. The
current credential is required; acknowledged cleanup can legitimately leave
historical references whose files are absent. Repeated references are deduplicated
and conflicting digests abort conversion. This inventory is not Debug/Serialize
and contains no credential bytes. Filesystem verification, protected copying,
durable journal recovery, and task switching remain unfinished.
All seven migration-document integration tests passed, including required-current,
optional-history, duplicate-reference, and conflicting-digest checks. Scoped
Clippy passed with warnings denied; formatting and diff whitespace checks passed.

### 2026-09-08 worker regression and native installation preflight

At source `90f21b7`, `cargo test -p cyc-worker --locked` completed with
native exit 0: 119 unit tests passed, one subprocess helper ignored, and all
six migration-document integration tests passed. The unit suite took 239.90
seconds. This covers pairing recovery, credential rotation, restart generation,
execution and artifact handling locally; it does not prove a persistent remote
worker installation.

The provisioning state-machine integration suite also passed all 26 tests
with native exit 0. Coverage includes durable authentication policy, password
exclusion from serialized records, crash/resume, repair identity preservation,
and smoke response-loss/retry binding. These use test transports, not live SSH
credential-store or remote installation acceptance. MSVC emitted LNK4099
warnings for missing OpenSSL debug symbols; linking and tests succeeded.

A read-only Helio probe still found zero worker processes and the existing
SYSTEM task in Ready state with LastTaskResult 1. Its executable remains in
the SSH user's old LocalAppData installation. C: free space is 1,301,364,736
bytes. A fresh data directory alone is not a valid side-by-side workaround:
the installer uses a fixed task name and verifies its existing path binding
before install, including PairOnly. No task, ACL, credential, or worker data
was changed. Identity-preserving migration remains required for this existing
installation; the new full worker-kit regression is still running separately.

### 2026-09-08 migration document conversion

The combined identity-document conversion now also validates the config against
exactly one acknowledged pairing for its current credential, controller, and
node. Boot-generation parsing is shared with normal startup and rejects unknown
schemas, invalid values, or exhausted signed-64-bit counters. Conversion returns
the original boot-generation bytes, without resetting or incrementing them.
All six migration integration tests passed. This is still an in-memory building
block, not a completed filesystem migration or service switch.
Existing boot-generation restart/orphan-temp and independent-handle concurrency
tests both passed (native exit 0; 66.42 seconds). Scoped Clippy also passed with
warnings denied.

The fixed-source full worker-kit run completed its Linux lifecycle fixture with
`wait_completed=True`, `timeout_marker=NOT_TRIGGERED`, `exit_code=0`, and no
remaining process IDs. Evidence: local temp directory
`cyc-worker-kit-test-95cfd983cfcd47c5a153d2c6db15a0b1`, file
`linux-worker-lifecycle.watchdog.txt`. The same run then failed the macOS
whole-suite watchdog at 600.07 seconds (native suite exit 1). Its retained
files show progress through path-binding checks and into the loaded-LaunchAgent
scenario, rather than a confirmed stationary lifecycle deadlock. The watchdog
terminated its process tree successfully and recorded no remaining PIDs.
The macOS fixture now uses the existing ordered setup/repair/binding/uninstall
phase budgets: 600 seconds per phase, 2400 seconds total, no extension from
duplicate markers, and no successful exit with missing markers. All lifecycle
assertions remain intact; the revised full run is not yet accepted.
This is Windows/Git Bash fixture coverage, not native Linux/macOS service
acceptance.

Implemented no-I/O config and pairing-ledger relocation primitives in cyc-worker.
They preserve all identity fields, rewrite only approved paths, reject pending
pairing/cleanup, and reuse the existing strict ledger validator before/after
conversion. Four native Rust integration tests passed for identity preservation,
pending-state/schema rejection, path escapes/renaming, and invalid or duplicate
ledger records. Scoped worker library/integration-test Clippy with warnings
denied, formatting, and diff checks passed. This is not yet a runnable
migration operation: boot-generation preservation, journal, source verification,
task switching, and rollback still need integration.

The phase-budget full worker-kit run has now passed all three Linux repair
failure/rollback scenarios and reached binding checks (last verified repair at
674 seconds; wrong-install/workspace checks also passed). It remains running;
do not report the whole suite as passed from these partial phase observations.

### 2026-09-08 PR and live controller reconciliation

PR #57 merged its prior head. The SYSTEM lifecycle changes are now PR #58,
based on the resulting main commit, with squash auto-merge enabled subject to
checks. No tag or release was created. The local full worker-kit run remains
in progress against fixed script hashes recorded above/below.

At 10:51:29 UTC, the installed product MCP returned controller/database healthy,
Codex integration available, and the only paired node offline with stale
telemetry (last accepted at 10:18:26 UTC). This agrees with the native process
check; historical task success must not be treated as current readiness.
No task was submitted to the offline node and no credential value was read.

### 2026-09-08 concise UI follow-up

Confirmed the discarded promotional home/task headings are absent from the
current desktop source. Removed the repeated quick-start description above the
action steps. Task filters now distinguish an empty history from no matching
tasks, with equivalent messages in English, Chinese, Spanish, and Japanese.
This frontend-only change does not alter worker lifecycle or release status.

### 2026-09-08 SYSTEM lifecycle dispatcher implementation

Native SYSTEM ACL acceptance now passed on Helio (remote exit 0), using exact
private-ACL functions extracted from the current installer, not mocked identity
or scheduler calls. A real temporary SYSTEM task created/protected/revalidated
a directory and file and read its known non-secret content. Receipt: runtime
SID and owner `S-1-5-18`, protected DACL, exactly one rule. Independent follow-up
found zero native-probe tasks; the original worker task stayed Ready/result 1.
Evidence retained remotely at
`C:\ProgramData\ClusterYourCodex-native-acl-9676d563a0ff4f47afc86bbb70464b66`.
Reproducer: `packaging/worker-kits/windows/Test-SystemPrivateAclNative.ps1`.
Installer SHA256:
`FE4E42584B1EC8C424CBF117F44F1FBA64FB50262953167EDDC4C44F3B362DDC`;
probe SHA256:
`4833EF4D3F807118F52033927653108B233BA362DA7893FB37964B87D40BDBA5`.
This proves the native ACL primitive only, not signed-kit dispatch, pairing,
worker startup, service restart, or full task round-trip acceptance. The probe
retains a tiny protected evidence tree and never edits existing worker data.

Latest read-only Helio recheck: SSH has an elevated administrator token; the
`ClusterYourCodex Worker` task exists with SYSTEM principal, Ready state, and
LastTaskResult 1. No `cyc-worker` process is currently present. The earlier
foreground proof remains historical execution evidence, not current availability.
The controller shell is not elevated. Helio C: free space was 1,309,270,016 bytes;
avoid a full remote debug build or unrelated cleanup. These probes changed no
remote task, process, ACL, pairing, or worker data.

The Windows installer now delegates the entire System-scope lifecycle to a
bounded SYSTEM helper task before accessing worker-owned state. System defaults
use Program Files/ProgramData; User behavior remains logon-scoped. The helper
uses a per-data-root mutex, private request/result files, and the copied verified
five-file kit. The parent waits for actual helper completion and a successful
exit/receipt; failed/timed-out operations retain evidence, while successful
handoffs delete only their exact known files. WhatIf stops before dispatch.

The dispatcher fixture passed under PowerShell 7 and Windows PowerShell 5.1,
covering successful receipt/cleanup, failure evidence retention, timeout stop,
non-admin rejection, SYSTEM task principal, copied kit shape, and generated
helper syntax. Scheduler operations are mocked; private filesystem/ACL actions
are real. No actual SYSTEM process, live migration, or remote persistent worker
acceptance is claimed by these tests. The existing Helio foreground worker and
user-owned data were not modified. Existing task/root conflicts remain explicit;
there is no automatic ownership takeover. The full worker-kit regression failed
at its 600-second `linux-worker-lifecycle` watchdog on Windows/Git Bash. Retained
evidence is in local temp directory
`cyc-worker-kit-test-c007be50b0de40dc93349b5398966b43`: child stderr reached
the expected `before-manifest-write` failure injection, while top-level logs
were empty. This does not establish whether rollback or a later assertion was
still executing. Added fixed phase/elapsed-time markers around repair injection
and path-binding checks without logging secrets or changing the watchdog limit.
No native Linux pass or complete packaging-gate pass is claimed.
The instrumented rerun also exited 1 at 600 seconds; evidence directory:
`cyc-worker-kit-test-13e7b159cfb0492d9f1df890165d453b`. Its phase log now proves
repair-after-pair started at 510s, returned expected failure at 584s, and passed
rollback assertions at 586s. The next injection began at 586s and was killed
by the suite deadline. Thus that rollback completed, and cumulative suite
runtime exhausted the budget; the next injection is still unverified. Do not
diagnose this as a confirmed lifecycle deadlock or mark the suite passed.
The Linux fixture now uses ordered setup/repair/binding/uninstall time budgets
within the same shell, preserving transaction state and every assertion. Each
phase has a 600-second limit; total time is bounded to 2400 seconds. Only the
next declared marker grants a fresh budget; repeats/unknown markers cannot
extend it. Successful early exits that omit required phases are rejected.
PowerShell 7 and Windows PowerShell 5.1 watchdog self-tests passed: ordinary success, exit 23, timeout,
valid phase transition exceeding the old whole-run budget, repeated markers
still timing out, and missing required markers failing. Full lifecycle and
complete platform acceptance remain pending for this watchdog revision.
Independent review found an unfinished-log-line race; the reader now consumes
only newline-terminated records and revisits an incomplete tail. The first
retest exposed a Windows sharing violation from ReadAllText against redirected
stdout (retained helper evidence `3bd6d9d6115f4c7ebaae1f80c0e0c594`); live log
reads now explicitly use FileShare.ReadWrite. Added split-marker regression,
deadline-before-success handling, and persistent failure classification so a
missing phase cannot disappear from the final watchdog evidence.
The corrected shared-reader/split-marker revision passed both PowerShell 7
and Windows PowerShell 5.1 self-tests (native process exit 0), with evidence
directories `cyc-worker-kit-bash-helper-f367f717bb3346bfac0a1aca0701a627` and
`cyc-worker-kit-bash-helper-fe3dd5e7745c4e299b656e1a3d0cb77c`. Generated Linux
shell syntax and git diff whitespace checks also passed. The next full run
must be evaluated separately; these helper checks are not lifecycle acceptance.
The dispatcher now detects a recorded nonzero helper exit without a receipt
instead of waiting the full five minutes. It checks LastRunTime to avoid
mistaking a newly registered, not-yet-started Ready task for a failed execution.
Regression fixtures cover missing-receipt failure and Ready-before-first-run;
this remains fixture evidence, not live SYSTEM installation acceptance.
Independent review identified and fixed Windows PowerShell 5.1's default ANSI
decoding of BOM-less UTF-8 requests and the mismatch between a silent helper
wait and the SSH transport's 15-second inactivity limit. Requests now use
explicit UTF-8, with Chinese-path decoding exercised in real Windows PowerShell
5.1. The parent emits a fixed non-secret stderr marker every five seconds;
the transport source refreshes its progress timer on either stdout or stderr.

### 2026-09-08 completion timestamp reconciliation

Explicit Retry is now offered for the retained JOB_PROGRESS_REGRESSED smoke
failure. The engine requires an existing durable smoke binding and rechecks
that same job/run; it does not rotate enrollment, reinstall, or automatically
retry repeated failures. All 26 provisioning state-machine tests and 103
frontend tests passed, including repeated-terminal-failure/binding reuse and
checkpoint-scoped UI action tests; the frontend production build passed.

Read-only Helio inspection confirmed the separate persistence blocker:
the registered worker task runs as SYSTEM (ServiceAccount, Highest), while
the protected data directory and credential file are owned by the SSH user.
The installed task's last result is 1; the diagnostic foreground worker was
still present as PID 28140. The worker requires owner=current runtime SID.
No ACLs or remote service identity were changed during this check. The exact
task startup stderr has not been captured. Fixing System scope requires the
pairing/lifecycle operations and persistent process to share an identity;
merely switching the run principal or weakening owner checks is insufficient.
The installer now deduplicates its private principal SID set, including the
SYSTEM-only case, with a pure-helper test wired into the worker-kit gate.
Both SYSTEM/user helper cases passed; a real SYSTEM lifecycle is still pending.
The worker's matching ACL creation/verifier also uses a unique principal set.
All eight worker security tests passed: real ordinary-user protected-file
round trips and in-memory Windows ACL cases for SYSTEM/ordinary acceptance,
extra/duplicate/inherited/weak rules, wrong owner, and unprotected DACL rejection.
This does not claim execution under a real SYSTEM process. Installer helper
tests passed in both PowerShell 7 and Windows PowerShell 5.1. The rebuilt native
desktop test suite passed all 80 tests after the recovery change.

Source inspection found a mismatch in the smoke poll validator: the controller
sets `started_at` when entering Running, while `complete_managed_run` applies
the worker's execution timestamps from its validated completion receipt. The
desktop previously rejected this terminal clock handoff as JOB_PROGRESS_REGRESSED.
The validator now permits a changed start timestamp only on a higher-version
nonterminal-to-terminal transition with a present start and a valid run receipt.
Same-version mutations, creation-time changes, live timestamp changes, terminal
rewrites, and invalid time ordering still fail. All 21 full-run tests passed,
including a new clock-handoff regression; formatting passed. Native installation
reconciliation against the retained live job and persistent scheduled-worker
startup remain unverified by this source-only fix. No public build was issued.

### 2026-09-08 minimal workspace UI

The follow-up copy cleanup deletes the six unused promotional page heading /
subtitle keys from all four locale catalogs (24 entries), rather than retaining
hidden copy. A regression test prevents these retired keys from returning.
The task page's previously decorative All / Running / Failed controls now filter
the current task snapshot and expose their selected state to assistive tools.
Running includes preparing, running, and verifying; queued and terminal jobs
remain in All. No controller or execution behavior changes.

Verification: all 102 frontend tests across six suites, TypeScript checks, Vite
production build, and `git diff --check` passed. The in-app browser at localhost
verified the Chinese home/task pages without the removed copy, filtering the
existing successful task out with Failed and restoring it with All. This change
updates source and browser preview; no installer or public release was rebuilt.

Follow-up simplification removes the visible global page-title/subtitle block,
repeated home-card descriptions, and redundant SSH wizard introductions.
Navigation names remain available as screen-reader headings. The global bar
contains only language, connection status, and refresh; Add Computer is scoped
to overview/Computers instead of appearing on unrelated task pages. Home and
task layouts were inspected in Chrome, with the 97 frontend tests passing.

The source UI now uses neutral white/gray surfaces, compact navigation,
graphite primary actions, and an overview statistics strip. The decorative
home hero is removed. First-run guidance is collapsible; fleet and task
information remains visible before the first computer is connected.

Desktop frontend build and all 97 tests (five suites) passed. A live Chrome
preview at `http://127.0.0.1:1420/` verified the home layout, expanding the
three-step guide, opening/closing Add Computer, and switching Chinese to
English. The browser correctly disables provisioning without the secure
native bridge. This is frontend verification, not SSH provisioning acceptance.
The installed preview.100 executable has not been replaced by this UI change.

### 2026-09-08 installed GUI provisioning resume

The multiline-receipt build completed and native rollback succeeded, returning
the retained record to draft at revision 23. Resume reached revision 27 but
failed `HOST_KEY_CHANGED` in `ssh_connecting`: the discovery probe still used
default negotiation even though authentication reconnects were pinned. The
transport now exposes a pin-aware unauthenticated probe, used for existing
records; the state machine still compares the complete key. All 39 library
tests passed, including a probe-routing test proving no authentication call.
Live retry of this follow-up remains pending. No database checkpoint was edited
manually, and the existing record and trust identity were retained.

The isolated-kit native retry reached revision 20 with
`LIFECYCLE_RECEIPT_INVALID`. Remote inspection verified exactly five kit files
and a 9,440,256-byte installed worker executable. The lifecycle command exited
successfully, but Windows emits multiline `ConvertTo-Json` while the driver
parsed only the last line. The parser now accepts the complete final JSON
object, retains strict receipt expectations, and rejects trailing garbage.
All 38 library tests pass. This proves binary installation, not pairing,
service readiness, or job execution; native recovery with the parser fix
remains pending.

Remote diagnosis identified the lifecycle failure: Windows `Install-Worker.ps1`
line 586 rejects the staging root because it contains six files (the five kit
files plus `cyc-discovery.ps1`). The explicit PairOnly diagnostic returned exit
1 before installation. The driver now stages bundles in a dedicated `kit`
child, keeping discovery and enrollment outside the signed file set. Existing
install checkpoints re-stage the verified kit into the new location. All 37
library tests pass, including a strict five-file assertion in the fake remote
lifecycle and layout separation checks for Windows/Linux/macOS. Real remote
acceptance of this fix remains pending. The read-only Helio probe also reported
approximately 1 GB free disk; no unrelated files were removed.

The rebuilt native GUI was launched successfully with the simplified layout
and the existing controller and provisioning records. The retained mismatch
record exposed only rollback/remove, so an explicit retry path now permits
rechecking an already approved host key without deleting the record or changing
trust. All 25 provisioning state-machine tests and 98 frontend tests passed,
including repeated-mismatch rejection and original-key recovery. Live remote
acceptance of this follow-up change advanced the retained Windows record from
revision 11 to 14 (`KIT_IO`) and then 17 (`WORKER_LIFECYCLE_FAILED`, retryable,
at `kit_staged`). The debug executable initially lacked its sibling
`worker-kits` directory; copying the installed preview.100 kits into the debug
output resolved that local packaging omission. The next remote lifecycle call
failed and still needs diagnosis. No host pin was replaced, and no worker is
yet claimed paired or ready. The product MCP `fleet_info` returned controller
and database healthy with an empty fleet before this retry.

The installed native Computers page retained both previous provisioning
records. Retrying the Windows worker checkpoint advanced its revision from 9
to 11 and failed with `HOST_KEY_CHANGED` before authentication. A read-only
SSH host-key advertisement probe found that the saved RSA fingerprint still
matches the server's advertised RSA key; the server also advertises ECDSA and
ED25519. Advertisement is not a substitute for authenticated identity proof.
The source transport now constrains reconnect negotiation to the approved key
type, then retains the exact-key comparison before authentication. RSA uses
SHA-2 signature methods, not SHA-1 fallback. This avoids treating a change in
client default algorithm preference as permission to accept a new key. Native
reconnect with the rebuilt desktop remains to be verified; the installed
preview.100 still contains the old negotiation behavior. No host-key record
was cleared or replaced and no paired worker is claimed yet.

Local verification of the reconnect change: `cargo test -p cyc-ssh --lib
--locked` completed with exit code 0, all 15 tests passed. This includes
approved-key negotiation and verification-before-authentication coverage.
The vendored OpenSSL linker emitted missing debug-PDB warnings, not test
failures. `cargo build --locked --manifest-path apps/desktop/src-tauri/Cargo.toml`
also completed with exit code 0. The new debug desktop binary includes the
reconnect change; live reconnect remains unverified and is the next acceptance
step. The installed executable has not been overwritten.

### 2026-09-08 installation succeeded after local recovery

Following the user's explicit continuing installation authorization, the
hash-verified preview.100 Setup was retried with `/S` and a process-scoped
`CYC_SETUP_DIAGNOSTIC_LOG` pointing into the existing private installer directory.
Setup PID 29692 completed; `retry-20260908-diagnostic.json` reports
`status=succeeded`, `lastStage=complete`, `error=null`, and the install manifest
is retained. The installed controller PID 50188 runs from the default per-user
Programs directory. Its authenticated health API reports preview.100,
`database=ok`, `status=ok`. The installed native GUI was opened and visibly
reports the controller online with the Simplified Chinese three-step home.
The nodes API returns an empty fleet: remote pairing and a cross-node job are
still pending. This is local existing-profile installation evidence, not a
clean-machine or cross-platform GA result. The previous failed attempts below
remain historical evidence; the old development runtime was not restarted.

### 2026-09-08 authorized preview.100 installer retry

The follow-up source fix now checks for `jobs`, `controller.db-wal`, and
`controller.db-shm` without `controller.db` before elevation and core changes.
It reports a recovery action without modifying storage or relaxing the
controller's validation. Five added storage cases and the existing port and
diagnostic tests pass together (12 total); the recovered local data directory
also passes this read-only preflight. The suite is already wired into CI.
This source change is not present in immutable preview.100, and successful
preflight does not establish successful installation or pairing.

Follow-up reproduced a concrete startup failure using the published preview.100
controller with the installer's default database/token paths: native exit 1,
`database security preflight failed`, caused by `refusing pre-existing object
storage without a database`. The default `controller.db` was absent while the
old development object directory `jobs` existed. Windows TaskScheduler
Operational logging was disabled, so no historical task event was available.
The object directory was verified empty (including hidden entries), regular,
and at the exact expected path before being renamed to
`jobs.preinstall-backup-20260908` in the same data directory. No contents were
deleted and no database was fabricated. Restore that directory name only while
the controller is stopped and no new `jobs`/database has been created. This
removes the reproduced startup blocker; installation still needs a successful
retry, and no remaining failures are assumed absent.

After explicit user confirmation, the live controller returned `jobs: []` and
the path-verified development GUI/controller were stopped (PIDs 2368/76204).
Port 47831 was free before launching the hash-verified preview.100 Setup.
Setup PID 17848 started at 16:19:54 local time. Files and an install manifest
briefly appeared, but the transaction ultimately returned `rolledBack` and
the native dialog reported `installation failed (exit 1)`. The final private
installer directory retained the firewall journal/receipts, not an install
manifest. This disproves port conflict as the sole installation blocker.
No successful install or GUI onboarding is claimed. The old development
runtime remains stopped; its binaries and user data were not deleted by the
operator. A diagnostic-enabled retry is needed to recover the core exception;
the immutable preview.100 installer lacks the newer default diagnostic fix.

The installer port-preflight and lifecycle-diagnostic Pester suites are now
included in the Windows CI identity job, using its pinned Pester 3.4 runner.
The combined local invocation passes all seven tests. A live authenticated
`cyc jobs` query to the existing development controller returned `jobs: []`
on 2026-09-08, so no queued/running job was observed at that instant. Recheck
before runtime handover; an empty queue is not an installation receipt.

On 2026-09-08 a live read-only listener check confirmed port 47831 is owned by
the development preview.95 controller (PID 76204, started 2026-09-07), outside
the default installation root. Fresh Setup cannot claim that port. The current
source now detects this conflict before firewall elevation; five focused
Pester tests pass, and invoking the preflight against the real listener returns
the expected conflict without stopping it. This is a confirmed present blocker,
not proof of the lost original preview.100 error. Close the development runtime
before a real installation retry; the immutable preview.100 package does not
contain this new preflight. Repair still stops only its verified owned runtime
inside the existing rollback boundary.

The 2026-09-08 [execution path reassessment](goals/execution-path-reassessment.md)
checks the current SSH and worker interfaces rather than treating the original
architecture as mandatory. SSH-direct is not yet a replacement backend: the
current SSH interface lacks durable job/reconnect/cancel semantics that the
worker protocol already supplies. The immediate delivery path retains that
protocol while isolating installation from runtime acceptance; no additional
platform or GUI completion is claimed by this assessment.

The active delivery goal is deliberately narrower than the full GA checklist:
prove that a user can start the controller, add a computer, retain the SSH
credential through the native boundary, install and pair a worker, submit a
typed job, and receive the result and logs. This gate has priority over
non-blocking bug cleanup, visual polish, and additional PR splitting. Those
items move to the feedback backlog after the core path is usable.

The goal was revised on 2026-09-07 to make the order explicit: ship a runnable
prerelease, let the operator exercise the packaged flow, capture the exact
failing stage and redacted receipt, then promote only core-path blockers. The
next-stage feedback loop is [docs/goals/user-feedback-loop.md](goals/user-feedback-loop.md)
and the repository now exposes a preview-feedback issue template.

Fresh local evidence for the current candidate includes Windows Credential
Manager round-trip (`1 passed`), provisioning state-machine coverage (`25
passed`), SSH transport coverage (`13 passed`), and a Windows
controller/worker job round trip with exit code `0`. The browser preview is
useful for UI inspection, but Add Computer and native integration actions
require the Tauri desktop bridge; a browser `bridge_unavailable` result is an
environment boundary, not a successful provisioning run.

The 2026-09-07 core-usability smoke adds 96 renderer tests, 78 native desktop
host tests, a successful native host compile, a local controller health check,
and Chrome checks for the four shipped locales. The complete source-bound
record is [docs/core-usability-smoke-20260907.md](core-usability-smoke-20260907.md).
The priority remains the usable Add Computer → credential → install/pair →
job/result path; non-blocking defect cleanup and additional PR splitting are
deliberately lower priority until that path is exercised on the packaged host.

The current working tree contains three core-path repairs found during the first
native Helio attempt: the WebView2 `tauri.localhost` bridge now accepts its
`undefined` URL-credential representation, and Windows SSH lifecycle commands
now preserve named PowerShell parameter binding. A direct Helio probe with the
fixed renderer returned a successful worker-install receipt. The Windows SSH
transport also selects the OpenSSL-backed libssh2 backend for modern Linux KEX
compatibility. These changes are included in the published `preview.95`
prerelease; the older `preview.91` binary remains immutable.

The current source also enables HTTP/2 in the shared rustls-backed reqwest
client. A real Windows preview.95 controller/worker probe initially exposed a
hyper-util panic when the controller negotiated HTTP/2; after the feature fix,
the rebuilt binaries passed pairing, node report, snapshot transfer, queued →
running → succeeded, heartbeat, logs, artifact verification, cleanup, and
process reaping. Preview.95 carries this source-bound core fix forward after
the previous tagged artifact workflow was canceled before publication; UI polish and
non-blocking defects remain feedback backlog items.
The committed preview.95 acceptance record is
[live-windows-preview95-local-roundtrip.md](live-windows-preview95-local-roundtrip.md).

## What the product does

ClusterYourCodex is a Windows-first controller, desktop host, plugin, and
worker-kit system that lets Codex submit typed build, test, container, GPU, and
batch workloads. The controller selects a compatible worker from current
telemetry and reservations, executes through the worker account, and returns
source identity, placement reason, native exit status, logs, cleanup state, and
artifact hashes.

The current preview boundary is trusted, single-user execution. Hostile or
multi-tenant workloads are fail-closed and do not receive a schedulable
capability until the opt-in isolation contract in Issue #5 is complete.

## Feature and evidence matrix

| Area | Implemented in the repository | Evidence currently available | Remaining gate |
| --- | --- | --- | --- |
| Controller, protocol, scheduler, CLI | Rust controller/worker/protocol/scheduler crates and typed workload placement | Merged-main CI [run 34008302124](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/34008302124) passed Rust tests on Ubuntu, macOS, and Windows plus the live Windows controller/worker round trip | Live cross-node GUI/MCP round trip |
| Windows desktop and tray host | Tauri 2 desktop, native controller proxy, bundled MCP runtime, per-user integration path | Windows packaging/static contracts and preview artifact jobs | Clean Windows 11 VM lifecycle, packaged tray acceptance, production Authenticode |
| Windows worker path | Current-user controller/worker task and data-directory ACL model; installer repair/rollback plumbing | Windows packaging tests, clean Windows 11 ARM64 x64-emulation lifecycle/profile matrix, and the real preview.91 Helio round-trip recorded in [live-windows-preview91-helio-roundtrip.md](live-windows-preview91-helio-roundtrip.md); preview.95 local controller/worker round-trip is recorded in [live-windows-preview95-local-roundtrip.md](live-windows-preview95-local-roundtrip.md) | Independent cross-machine Windows controller-to-Windows-worker run with retained logs/artifacts; clean-VM and production-signing gates remain separate |
| Linux worker packages | Linux x64 and arm64 Worker Kit archives, native shell/process-group paths, and systemd lifecycle packages | Tagged Linux artifact jobs, Worker Kit native/structural checks, and the real preview.91 P1 controller/worker round-trip recorded in [live-linux-preview91-p1-roundtrip.md](live-linux-preview91-p1-roundtrip.md) | Repeat exact-SHA/native validation for each candidate; Issue #3's remaining platform gate is macOS |
| macOS Worker Kits | x64 and arm64 archives, manifest/checksum/publisher-key contract, macOS capability reporting | Tagged macOS artifact jobs and kit contract checks | Real macOS host, LaunchAgent install/start/stop/restart, managed live run, and round trip |
| Add Computer and credentials | GUI onboarding model, native credential-vault boundary, host-key fingerprint flow, password/agent/private-key paths | Static contract and local source review | Live authentication and cross-node GUI/MCP acceptance on supported hosts |
| Desktop UX and localization | One state-aware three-step first-run path with a single contextual setup CTA, compact Add Computer form, collapsed advanced verification, compact first-run Computers empty state, quiet offline top bar, and persistent English/Simplified Chinese/Spanish/Japanese selection across dashboard, tasks, rules, integration evidence, provisioning, errors, and credential recovery | Chrome visual/interaction audit against the preview.90 candidate, four-language home/integration/computer checks, persistent `html[lang]`, and app-origin logs empty after filtering Chrome-extension noise; 96 desktop tests, workspace lint/test/build, and tagged preview.90 checks | Keep the catalog review loop running for newly introduced backend diagnostics and confirm translated wording with native-language reviewers |
| Hostile-workload isolation | Linux dedicated identity/cgroup reconciliation hardening; Windows/macOS capability reporting and fail-closed scheduling boundary | Linux unit/native probes and static contracts | Windows Job Object + protected external guard, macOS external reconciliation, and a complete three-platform hostile matrix (Issue #5) |
| Public release pipeline | Version identity, signed-kit metadata, SBOM/provenance/index validation, protected GA workflow | Main CI and preview producer jobs | All applicable issue gates, external evidence, protected production review, and independent post-download verification |

The word “implemented” above describes code present in the repository. The
“evidence” column is the only basis for claiming a capability is tested. A
packaged archive or hosted smoke test does not substitute for a real host,
service-manager, credential, or cross-node acceptance gate.

## Current CI and release state

### 2026-09-08: preview.100 available for operator testing

- Local GUI Setup attempt has ended without an installed desktop. Its durable
  lifecycle journal remains at `firewallApplied`, and the matching helper
  response is `rolledBack`. This narrows the failed attempt to the core-apply
  region or its commit validation; it is not evidence of an unresolved firewall
  permission wait. The original core error was not retained, so its exact cause
  remains unknown. Source now defaults lifecycle diagnostics to the existing
  private `.installer/last-lifecycle-diagnostic.json`; it creates no fallback
  directory on an early failure. Two targeted diagnostics tests passed.
  This change is not in the immutable preview.100 installer yet.
- PR run `34178620334` failed during Windows round-trip initialization before
  evidence directories were created; the other jobs passed. The fixture now
  handles newly created Administrators-owned directories on elevated runners
  while preserving current-user-owned directories without ownership writes.
  Unexpected owners remain rejected and the final private ACL is still checked.
  This addresses a likely runner-only regression; hosted rerun is required to
  confirm the cause because the failed run did not retain its original error.
- Native UI/state inspection found the running development desktop is still
  preview.95. Its provisioning journal has two incomplete historical attempts:
  Helio has a stored credential reference and approved host key, but failed at
  `kit_staged` with `WORKER_LIFECYCLE_FAILED` before pairing; P1 failed at
  `ssh_connecting` with `SSH_IO`, without a stored credential or approved key.
  These are not preview.100 outcomes. Resume the existing records rather than
  create duplicate computers. Native UI input was blocked by `PickerHost.exe`
  after activation and one refreshed retry; no provisioning action was submitted.
- Published preview.100 binaries passed a real local Windows controller/worker
  round trip: all 14 checks true, job `queued -> running -> succeeded`, native
  probe exit `0`, and cleanup confirmed. The harness required a DACL-only
  fixture correction for a standard desktop token; the product binaries were
  unchanged. See [source-bound evidence](live-windows-preview100-local-roundtrip.md).
- Tagged workflow `34128668756` completed successfully, including Windows
  self-contained packaging, clean Windows 11 ARM64 x64-emulation fresh
  deployment, silent Setup, and standard/admin/non-ASCII profile acceptance.
- Preview.98 stopped at the outer Windows job timeout; preview.99 stopped at
  a stale static timeout assertion. Neither was published. Preview.100 carries
  the bounded budget and matching contract fix; per-attempt ceilings remain.
- Independent release download verified all 11 SHA-256 sidecars and all 10
  provenance subject hashes in `release-index.json`. The index binds the
  product version and tag to source `2c269842dbc15934b5cfcf6a4cb3e0844cec3ed5`.
  Installer SHA-256:
  `8bf4ed52e8021fef888bb7acecaafcc5d099f4b2a5e87f11bfc6955ee071c9bf`.
  These checks establish artifact consistency, not Authenticode signing.
- PR #56 merged the earlier candidate. PR #57 reconciles its squash merge with
  the preview.100 branch and updates the current download/status documentation.
- Next acceptance action: launch the installed desktop, add one reachable
  worker, save its credential, install/pair, connect Codex, then return a real
  job result and logs. Browser-only UI checks do not satisfy that native path.
  Non-blocking UI polish remains in the feedback backlog.

### Earlier source and release evidence (historical)

- The core-usability candidate merged as PR [#54](https://github.com/TypeThe0ry/ClusterYourCodex/pull/54) at `a103306ec7b2ba8a7b3571fc24317a4876928bf2`. The CI run [`34027758058`](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/34027758058) passed Windows desktop lifecycle and managed worker kits, the Windows controller/worker live round trip, Rust workspace tests on Windows/Ubuntu/macOS, native worker kits, and MSRV. The separate CodeQL run [`34027758039`](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/34027758039) and Dependency security run [`34027758028`](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/34027758028) also passed. The candidate's local evidence also passed the same-host Windows `queued` → `running` → `succeeded` path with heartbeat, logs, artifact, cleanup, and secret scanning.

- Merged-main source `17eec6b6f2c7b81e7333659dff7d9b43ab24c673` (PR [#50](https://github.com/TypeThe0ry/ClusterYourCodex/pull/50)) has CI run [`34008302124`](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/34008302124), CodeQL run [`34008302110`](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/34008302110), and dependency security run [`34008302169`](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/34008302169); all three completed successfully, including the live Windows controller/worker round trip.
- The tagged [`v0.1.0-preview.84` workflow](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/33946635188) completed with one failure: **Clean Windows 11 ARM64 compatibility acceptance (x64 emulation)**. The first `standard-ascii` child timed out after 900 seconds while the elevated helper was cleaning up an auto-started `AtLogOn` task runtime. Producer jobs passed, but publication was skipped, so preview.84 is not a published release.
- The merged preview.85 repair replaces the unbounded PowerShell task-unregister path with bounded native scheduler operations, binds exact-path validation and termination to one process handle, asks Task Scheduler to end running instances before fallback termination, requires a stable no-process window, reaps runtimes after both registration and rollback restoration, and preserves flattened helper-history evidence. Tagged run [`33968855403`](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/33968855403) completed successfully, including Windows x64 native lifecycle checks and clean Windows 11 ARM64 x64-emulation fresh deployment, silent Setup, and standard/admin ASCII/non-ASCII profile acceptance.
- The merged preview.85 source also contains the first Chrome-audited desktop
  simplification and bilingual UI: first use is one three-step path, Add
  Computer keeps only required credentials visible, Advanced verification is
  collapsed by default, and the selected locale persists locally.
- The preview.86 candidate extended localization to every desktop-owned
  surface and removed the duplicate hero Connect Codex action. PR [#36](https://github.com/TypeThe0ry/ClusterYourCodex/pull/36)
  merged as `87fb8d228eab06aa648662aed9a9ad8d4ed9d4fa`.
- The preview.87 candidate made the primary CTA follow controller state so an
  offline first run opens setup instead of a doomed SSH modal, and adds
  Spanish/Japanese catalogs with an explicit English fallback for less common
  forensic evidence. Chrome smoke covered the English, 简体中文, Español, and
  日本語 home/computer flows; runtime bridge errors stayed localized while
  retaining their technical error codes.
- The preview.88 candidate completes the Spanish/Japanese translations for the
  core dashboard, task history, routing rules, Codex integration,
  provisioning, actions, and status labels. PR [#39](https://github.com/TypeThe0ry/ClusterYourCodex/pull/39)
  merged as `f0ca393d910732ece9395245eb6bf659de2fd47d`; local desktop tests,
  workspace lint/test/build, and the Chrome Japanese routing-rules smoke pass.
- The preview.89 candidate simplified the offline top-bar state and moved
  first-run setup to one contextual CTA and provisioning error codes behind a
  localized technical-details disclosure. Its tagged workflow
  [`33992231739`](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/33992231739)
  was cancelled after the Windows 11 ARM64 profile matrix remained inside the
  elevated helper path past the intended 900-second child boundary; no public
  preview.89 Release was created. The follow-up adds bounded CIM provider
  queries before the next tagged candidate is attempted.
- PR [#42](https://github.com/TypeThe0ry/ClusterYourCodex/pull/42) then removed the
  duplicate top-bar **Add computer** button on a true first-run Home screen;
  the contextual **Start** action remains the only primary onboarding entry,
  while the button returns on the Computers page and after setup history exists.
- PR [#45](https://github.com/TypeThe0ry/ClusterYourCodex/pull/45) completes all
  448 catalog keys for Spanish and Japanese, including
  controller/provisioning errors, integration evidence, stale-pass explanations,
  and credential recovery. It merged as `4407cfcebeaf4e83356b30b6a90c72d79f92c046`;
  Chrome checks confirm all four locales switch and persist without console
  errors. The catalog change is on `main` but is not part of tagged preview.89;
  the next preview tag must carry it before any public artifact can claim the
  complete four-language catalog.
- PR [#49](https://github.com/TypeThe0ry/ClusterYourCodex/pull/49) merged as
  `71aa3d70ae5876758f846e5900e9c2ed1c8ac081`. It keeps the Computers screen to
  one Add Computer action, localizes the private-key path example, removes the
  remaining core-flow heartbeat/smoke-check English fallbacks from Spanish and
  Japanese. Desktop tests assert those strings and the 449-key catalog remains
  aligned. The no-ready panel conditional and its compact Chrome verification
  shipped in preview.90 after the candidate was merged and tagged.
- Preview.90 is the first public release containing the compact no-ready panel
  and the complete four-language core-flow catalog. It was merged through PR
  [#50](https://github.com/TypeThe0ry/ClusterYourCodex/pull/50) at
  `17eec6b6f2c7b81e7333659dff7d9b43ab24c673`, tagged as
  [`v0.1.0-preview.90`](https://github.com/TypeThe0ry/ClusterYourCodex/releases/tag/v0.1.0-preview.90),
  and published by tagged workflow
  [`34009492657`](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/34009492657).
  The Release is public (`isPrerelease=true`, `isDraft=false`). Its clean
  Windows 11 ARM64 x64-emulation acceptance job
  `101437742671` passed: fresh deployment completed at `05:57:45Z`/`06:10:39Z`,
  silent Setup completed at `06:40:34Z`, the standard/admin/non-ASCII profile
  matrix completed at `07:31:45Z`, and diagnostics upload completed at
  `07:31:55Z`.
- The next mainline candidate keeps provisioning bridge/SSH failures visible
  inside the Add Computer modal as well as in the page-level status panel. This
  preserves the entered host/user fields for retry and keeps the localized
  error plus technical-details disclosure in the user's active context; it is
  not part of the immutable preview.90 assets until a new prerelease tag is
  published.
- The same candidate is now PR [#54](https://github.com/TypeThe0ry/ClusterYourCodex/pull/54)
  at commit `9cb6fdbc3d72a3656e11faf436dec7f340594dfa`. It removes the duplicate
  error while the wizard is open and shortens protected Windows credential
  staging names. A same-host Windows live round-trip built all three binaries
  from that revision and passed pairing, `queued` → `running` → `succeeded`,
  heartbeat, logs, artifact, cleanup, process cleanup, and secret-scan checks.
  This evidence does not replace cross-node, clean-VM, macOS, or hostile-workload
  acceptance gates.
- Preview.90 post-download verification was retained under the portable
  artifact identifier `release-verification/preview.90-20260906-153326`
  (the absolute verifier path is intentionally omitted). The retained
  directory contains 23 Release assets, 11 per-file SHA-256 sidecars plus
  `SHA256SUMS`, 10 release-index artifact records, the CycloneDX 1.6 SBOM, and
  a provenance attestation with 10 subjects. Every downloaded sidecar and
  `SHA256SUMS` entry matched its local SHA-256 (`shaErrors` empty); the index
  binds product version `0.1.0-preview.90`, source tag, and source commit above.
- The previously published preview.85 candidate was downloaded into a clean directory after publication.
  All 23 assets, 11 SHA-256 sidecars/SHA256SUMS records, 10 release-index
  records, the CycloneDX SBOM, and all 10 GitHub provenance attestations were
  independently verified. The exact Release was then promoted to
  **stable-testing** by changing only its GitHub prerelease flag and notes; its
  tag, product version, source commit, and asset bytes were preserved. This
  does not satisfy or bypass Certified GA.

## Open issue gates

### [Issue #2 — Windows one-click installer and desktop host](https://github.com/TypeThe0ry/ClusterYourCodex/issues/2)

The Windows-first implementation and packaging contracts are present. Preview.90
passed the clean Windows 11 ARM64 x64-emulation fresh deployment, silent Setup,
and standard/admin/non-ASCII profile matrix in tagged workflow
[`34009492657`](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/34009492657)
(job `101437742671`). The open acceptance items are an independently retained
Windows 11 standard/admin/non-ASCII Install → Repair → Upgrade → Rollback →
Uninstall lifecycle, packaged tray/one-click acceptance, production
Authenticode evidence, and an independent live Windows controller-to-worker
run with retained logs/artifacts.

### [Issue #3 — Heterogeneous Linux and macOS worker packages](https://github.com/TypeThe0ry/ClusterYourCodex/issues/3)

Linux x64/arm64 and macOS x64/arm64 packages are built and structurally
verified in preview.90, with checksums, SBOM, and provenance recorded in the
release index. Issue #3 stays open until a real macOS host proves the
LaunchAgent install/start/stop/restart lifecycle and managed controller round
trip; CI archive creation alone is not runtime evidence.

### [Issue #5 — Opt-in hostile-workload isolation and external reconciliation](https://github.com/TypeThe0ry/ClusterYourCodex/issues/5)

The preview deliberately reports `ready=false`, `containmentReady=false`, and
`runtimeGated=true`. Linux identity/cgroup reconciliation is hardened, but the
Windows Job Object/protected external guard, macOS external reconciliation,
restart residual cleanup, and the complete three-platform hostile matrix still
need independent evidence. Issue #5 must remain open until all nine gates pass.

## Release operating rule

1. Implement and test the change in a branch.
2. Open a PR and let required GitHub checks run; do not claim “auto passed” until
   the check conclusions are green for the PR head SHA.
3. Merge only the reviewed PR, then run the exact merged SHA through main CI.
4. Bump `VERSION`, update `CHANGELOG.md`, create an annotated `vX.Y.Z-preview.N`
   tag, and verify the published release is `isPrerelease=true` and
   `isDraft=false`.
5. Download every primary asset and sidecar, verify hashes/index/SBOM/provenance,
   and attach exact evidence to this file and the applicable issues.
6. An explicitly authorized stable-testing promotion may change only the
   verified candidate Release flag; preserve its tag, product version, assets,
   checksums, provenance, and limitations.
7. Keep Certified GA blocked until the protected GA workflow validates the
   external evidence manifest, issue closure, governance, production signing,
   and independent post-download checks described in [`RELEASE.md`](../RELEASE.md)
   and [`docs/release-process.md`](release-process.md).

The next update must replace the snapshot metadata and CI links with the exact
merged commit, preview tag, workflow run, and retained evidence; it must not
rewrite this file from memory or silently convert an unverified gate into a
pass.
