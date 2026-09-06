# ClusterYourCodex project status

This is the repository's durable progress record. It is intentionally based on
the current checkout and live GitHub state, rather than on chat history. Update
it in the same pull request as every implementation, CI, packaging, or release
change.

- **Snapshot date:** 2026-09-06
- **Repository:** [TypeThe0ry/ClusterYourCodex](https://github.com/TypeThe0ry/ClusterYourCodex)
- **Snapshot baseline:** `origin/main` at `84260a6b92b3ea12c2b570429883c056e8fdcea5` (tagged `v0.1.0-preview.91` core-usability candidate)
- **Latest published preview:** [`v0.1.0-preview.90`](https://github.com/TypeThe0ry/ClusterYourCodex/releases/tag/v0.1.0-preview.90), published from the annotated tag at the merged SHA; GitHub reports `isPrerelease=true` and `isDraft=false`
- **Current tagged candidate:** [`v0.1.0-preview.91`](https://github.com/TypeThe0ry/ClusterYourCodex/releases/tag/v0.1.0-preview.91) is tagged at the snapshot baseline; its release workflow [`34031465581`](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/34031465581) is still running the clean Windows 11 ARM64 profile matrix, so the public release remains preview.90 until that workflow reaches a publishable terminal state.
- **Previous stable-testing exception:** [`v0.1.0-preview.85`](https://github.com/TypeThe0ry/ClusterYourCodex/releases/tag/v0.1.0-preview.85) remains immutable **stable-testing** (`isPrerelease=false`) for the explicitly authorized test channel. Its embedded product version is still a preview; it is not Certified GA.
- **Release channels:** preview.90 is the current public prerelease. Certified GA remains blocked by the open Issue #2, #3, and #5 acceptance gates; no `prerelease=false` Certified GA release has been created.

## Current delivery goal: core usability before polish

The active delivery goal is deliberately narrower than the full GA checklist:
prove that a user can start the controller, add a computer, retain the SSH
credential through the native boundary, install and pair a worker, submit a
typed job, and receive the result and logs. This gate has priority over
non-blocking bug cleanup, visual polish, and additional PR splitting. Those
items move to the feedback backlog after the core path is usable.

Fresh local evidence for the current candidate includes Windows Credential
Manager round-trip (`1 passed`), provisioning state-machine coverage (`25
passed`), SSH transport coverage (`13 passed`), and a Windows
controller/worker job round trip with exit code `0`. The browser preview is
useful for UI inspection, but Add Computer and native integration actions
require the Tauri desktop bridge; a browser `bridge_unavailable` result is an
environment boundary, not a successful provisioning run.

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
| Windows worker path | Current-user controller/worker task and data-directory ACL model; installer repair/rollback plumbing | Windows packaging tests plus live controller/worker round trip in merged-main [run 34008302124](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/34008302124); clean Windows 11 ARM64 x64-emulation lifecycle/profile matrix passed in tagged [release run 34009492657](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/34009492657) | Independent real Windows controller-to-Windows-worker run with retained logs/artifacts |
| Linux worker packages | Linux x64 and arm64 Worker Kit archives, native shell/process-group paths, and systemd lifecycle packages | Tagged Linux artifact jobs, Worker Kit native/structural checks, and the preview.83 exact-SHA P1 controller/worker job | Repeat exact-SHA/native validation for each candidate; Issue #3's remaining platform gate is macOS |
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
