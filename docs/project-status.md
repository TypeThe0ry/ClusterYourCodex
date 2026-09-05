# ClusterYourCodex project status

This is the repository's durable progress record. It is intentionally based on
the current checkout and live GitHub state, rather than on chat history. Update
it in the same pull request as every implementation, CI, packaging, or release
change.

- **Snapshot date:** 2026-09-06
- **Repository:** [TypeThe0ry/ClusterYourCodex](https://github.com/TypeThe0ry/ClusterYourCodex)
- **Snapshot baseline:** `origin/main` at `4407cfc` (merged PR #45, complete desktop localization; latest tagged product candidate remains preview.89)
- **Current candidate version:** `0.1.0-preview.89` (`v0.1.0-preview.89` points to `e8691ac92603da3b883e9312915650fbba68eb35`)
- **Latest published release:** [`v0.1.0-preview.85`](https://github.com/TypeThe0ry/ClusterYourCodex/releases/tag/v0.1.0-preview.85), promoted unchanged to **stable-testing** (`isPrerelease=false`); preview.86 and preview.87 are cancelled superseded candidates, preview.88 is superseded, and preview.89 is the active tagged prerelease candidate
- **Release channels:** `v0.1.0-preview.85` is the current immutable
  stable-testing build. Its embedded version remains a preview and Certified GA remains blocked by
  the open Issue #2, #3, and #5 acceptance gates.

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
| Controller, protocol, scheduler, CLI | Rust controller/worker/protocol/scheduler crates and typed workload placement | Preview.89 producer jobs and Rust tests pass on `e8691ac`; merged-main CI for `886387f` is tracked by [run 33994706589](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/33994706589) | Live cross-node GUI/MCP round trip |
| Windows desktop and tray host | Tauri 2 desktop, native controller proxy, bundled MCP runtime, per-user integration path | Windows packaging/static contracts and preview artifact jobs | Clean Windows 11 VM lifecycle, packaged tray acceptance, production Authenticode |
| Windows worker path | Current-user controller/worker task and data-directory ACL model; installer repair/rollback plumbing | Windows packaging tests plus hosted controller/worker round trip in preview.89 [run 33992231739](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/33992231739) | Independent real Windows controller-to-Windows-worker run with retained logs/artifacts |
| Linux worker packages | Linux x64 and arm64 Worker Kit archives, native shell/process-group paths, and systemd lifecycle packages | Tagged Linux artifact jobs, Worker Kit native/structural checks, and the preview.83 exact-SHA P1 controller/worker job | Repeat exact-SHA/native validation for each candidate; Issue #3's remaining platform gate is macOS |
| macOS Worker Kits | x64 and arm64 archives, manifest/checksum/publisher-key contract, macOS capability reporting | Tagged macOS artifact jobs and kit contract checks | Real macOS host, LaunchAgent install/start/stop/restart, managed live run, and round trip |
| Add Computer and credentials | GUI onboarding model, native credential-vault boundary, host-key fingerprint flow, password/agent/private-key paths | Static contract and local source review | Live authentication and cross-node GUI/MCP acceptance on supported hosts |
| Desktop UX and localization | One state-aware three-step first-run path with a single contextual setup CTA, compact Add Computer form, collapsed advanced verification, quiet offline top bar, and persistent English/Simplified Chinese/Spanish/Japanese selection across dashboard, tasks, rules, integration evidence, provisioning, errors, and credential recovery | Chrome visual/interaction audit of the local `origin/main` UI plus four-language home/integration/computer checks, `html[lang]` persistence, zero console errors, 95 desktop tests, workspace lint/test/build, and preview.89 release contract checks | Keep the catalog review loop running for newly introduced backend diagnostics and confirm translated wording with native-language reviewers |
| Hostile-workload isolation | Linux dedicated identity/cgroup reconciliation hardening; Windows/macOS capability reporting and fail-closed scheduling boundary | Linux unit/native probes and static contracts | Windows Job Object + protected external guard, macOS external reconciliation, and a complete three-platform hostile matrix (Issue #5) |
| Public release pipeline | Version identity, signed-kit metadata, SBOM/provenance/index validation, protected GA workflow | Main CI and preview producer jobs | All applicable issue gates, external evidence, protected production review, and independent post-download verification |

The word “implemented” above describes code present in the repository. The
“evidence” column is the only basis for claiming a capability is tested. A
packaged archive or hosted smoke test does not substitute for a real host,
service-manager, credential, or cross-node acceptance gate.

## Current CI and release state

- Merged-main source `886387fab368eea080388326fad55aeea5f3c41a` has CI run [`33994706589`](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/33994706589), CodeQL run [`33994706572`](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/33994706572), and dependency security run [`33994706614`](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/33994706614); dependency security is green and the CI/CodeQL conclusions are retained here as the live snapshot.
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
- The preview.89 candidate simplifies the offline top-bar state and moves
  first-run setup to one contextual CTA and moves provisioning error codes
  behind a localized technical-details disclosure;
   tagged workflow [`33992231739`](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/33992231739) is the active prerelease producer and still requires completion plus post-download asset verification before its release status is final.
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
- The previously published preview.85 candidate was downloaded into a clean directory after publication.
  All 23 assets, 11 SHA-256 sidecars/SHA256SUMS records, 10 release-index
  records, the CycloneDX SBOM, and all 10 GitHub provenance attestations were
  independently verified. The exact Release was then promoted to
  **stable-testing** by changing only its GitHub prerelease flag and notes; its
  tag, product version, source commit, and asset bytes were preserved. This
  does not satisfy or bypass Certified GA.

## Open issue gates

### [Issue #2 — Windows one-click installer and desktop host](https://github.com/TypeThe0ry/ClusterYourCodex/issues/2)

The Windows-first implementation and packaging contracts are present. The open
acceptance items are a clean Windows 11 standard/admin/non-ASCII profile and
lifecycle matrix (Install → Repair → Upgrade → Rollback → Uninstall), a live
Windows controller-to-worker round trip, packaged tray/one-click acceptance,
and production Authenticode evidence.

### [Issue #3 — Heterogeneous Linux and macOS worker packages](https://github.com/TypeThe0ry/ClusterYourCodex/issues/3)

Linux x64/arm64 and macOS x64/arm64 packages are built and structurally
verified. Issue #3 stays open until a real macOS host proves the LaunchAgent
lifecycle and managed controller round trip; CI archive creation alone is not
runtime evidence.

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
