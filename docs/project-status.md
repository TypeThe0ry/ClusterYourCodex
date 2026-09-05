# ClusterYourCodex project status

This is the repository's durable progress record. It is intentionally based on
the current checkout and live GitHub state, rather than on chat history. Update
it in the same pull request as every implementation, CI, packaging, or release
change.

- **Snapshot date:** 2026-09-05
- **Repository:** [TypeThe0ry/ClusterYourCodex](https://github.com/TypeThe0ry/ClusterYourCodex)
- **Snapshot baseline:** `main` at `911dd58ec2da2488a1a5e5d5ed0a6fb17dd79e58`
- **Current candidate version:** `0.1.0-preview.85`
- **Latest published release:** [`v0.1.0-preview.83`](https://github.com/TypeThe0ry/ClusterYourCodex/releases/tag/v0.1.0-preview.83)
- **Stable release:** not enabled; the GA workflow remains blocked by the open
  Issue #2, #3, and #5 acceptance gates.

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
| Controller, protocol, scheduler, CLI | Rust controller/worker/protocol/scheduler crates and typed workload placement | Main CI, Rust tests, and version checks pass on `911dd58` | Live cross-node GUI/MCP round trip |
| Windows desktop and tray host | Tauri 2 desktop, native controller proxy, bundled MCP runtime, per-user integration path | Windows packaging/static contracts and preview artifact jobs | Clean Windows 11 VM lifecycle, packaged tray acceptance, production Authenticode |
| Windows worker path | Current-user controller/worker task and data-directory ACL model; installer repair/rollback plumbing | Windows packaging tests and hosted preview acceptance | Real Windows controller-to-Windows-worker run with retained logs/artifacts |
| Linux worker packages | Linux x64 and arm64 Worker Kit archives, native shell/process-group paths, and systemd lifecycle packages | Tagged Linux artifact jobs, Worker Kit native/structural checks, and the preview.83 exact-SHA P1 controller/worker job | Repeat exact-SHA/native validation for each candidate; Issue #3's remaining platform gate is macOS |
| macOS Worker Kits | x64 and arm64 archives, manifest/checksum/publisher-key contract, macOS capability reporting | Tagged macOS artifact jobs and kit contract checks | Real macOS host, LaunchAgent install/start/stop/restart, managed live run, and round trip |
| Add Computer and credentials | GUI onboarding model, native credential-vault boundary, host-key fingerprint flow, password/agent/private-key paths | Static contract and local source review | Live authentication and cross-node GUI/MCP acceptance on supported hosts |
| Hostile-workload isolation | Linux dedicated identity/cgroup reconciliation hardening; Windows/macOS capability reporting and fail-closed scheduling boundary | Linux unit/native probes and static contracts | Windows Job Object + protected external guard, macOS external reconciliation, and a complete three-platform hostile matrix (Issue #5) |
| Public release pipeline | Version identity, signed-kit metadata, SBOM/provenance/index validation, protected GA workflow | Main CI and preview producer jobs | All applicable issue gates, external evidence, protected production review, and independent post-download verification |

The word “implemented” above describes code present in the repository. The
“evidence” column is the only basis for claiming a capability is tested. A
packaged archive or hosted smoke test does not substitute for a real host,
service-manager, credential, or cross-node acceptance gate.

## Current CI and release state

- Main CI run [`33945591426`](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/33945591426) and dependency security run [`33945591423`](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/33945591423) passed for `911dd58`.
- The tagged [`v0.1.0-preview.84` workflow](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/33946635188) completed with one failure: **Clean Windows 11 ARM64 compatibility acceptance (x64 emulation)**. The first `standard-ascii` child timed out after 900 seconds while the elevated helper was cleaning up an auto-started `AtLogOn` task runtime. Producer jobs passed, but publication was skipped, so preview.84 is not a published release.
- The repair branch replaces the unbounded PowerShell task-unregister path with bounded native scheduler deletion, reaps the exact validated task executable, and preserves flattened helper-history evidence. The tagged workflow must pass this acceptance job before the next public preview is published.
- All public preview tags are non-draft GitHub releases with `prerelease=true`. No stable tag or `prerelease=false` release is allowed while the gates below remain open.

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
6. Keep stable blocked until the protected GA workflow validates the external
   evidence manifest, issue closure, governance, production signing, and
   independent post-download checks described in [`RELEASE.md`](../RELEASE.md)
   and [`docs/release-process.md`](release-process.md).

The next update must replace the snapshot metadata and CI links with the exact
merged commit, preview tag, workflow run, and retained evidence; it must not
rewrite this file from memory or silently convert an unverified gate into a
pass.
