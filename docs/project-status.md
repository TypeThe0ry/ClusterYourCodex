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

### 2026-09-08 minimal workspace UI

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
