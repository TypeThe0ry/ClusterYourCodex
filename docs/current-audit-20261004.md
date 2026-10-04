# Current audit — 2026-10-04

## Preview.110 candidate after PR #197

PR #197 is merged into `origin/main` at
`c9984dd509de2dd254fd4452a4e2731583caccaa`. The next candidate is
`v0.1.0-preview.110`, with the Windows profile-matrix queue/recovery hardening,
bounded Task Scheduler query child, and Fresh Deployment phase-trace evidence.
It must remain a prerelease until a tagged candidate proves the ARM64 matrix;
the preview.109 failure did not establish a single IPC root cause. Issues #2
and #3 remain open. Stable `v0.0.1` remains immutable at
`e4fbaef04b764268fa038311d85573b18b549f9`.

## Preview.109 published and VMware validation

The exact tagged source commit is
`9721c144fa19f95d6ece8c062740dee0f6eaf3db` (the PR #196 merge). Release
workflow `37149273717` published
[`v0.1.0-preview.109`](https://github.com/TypeThe0ry/ClusterYourCodex/releases/tag/v0.1.0-preview.109)
at `2026-10-03T21:38:10Z` as a non-draft prerelease with 23 assets. The
release-index, provenance, and publication jobs passed. A fresh D-drive
download under
`D:\\ClusterYourCodex-validation\\preview109-public-20261004\\` matched all
11 per-asset `.sha256` sidecars and every entry in `SHA256SUMS`; no stable
asset or tag was changed.

The same public Setup was installed in the D-drive Windows 11 VMware guest
through VIX CLI only. On a clean snapshot the installer returned exit code 0;
the installed controller reported `0.1.0-preview.109`, health returned
`status=ok`, `apiVersion=cyc.dev/v1`, and `database=ok`, and `cyc discover`
found the guest controller with `credentialsTransmitted=false` and
`pairingRequired=true`. The live same-host controller/worker fixture returned
`queued -> running -> succeeded` with all 14 checks true and
`jobRootDeleted=true`. Sanitized evidence is retained outside Git at
`D:\\ClusterYourCodex-validation\\preview109-public-20261004\\guest\\`.

The optional clean Windows 11 ARM64 x64-emulation job reached a terminal
non-blocking failure in its profile matrix: the `standard-ascii` child timed
out after 900 seconds while the lifecycle was still in its second
task-gate/repair-uninstall boundary. Fresh deployment and silent Setup passed;
this is retained as an unresolved lifecycle boundary, not counted as a pass.
Diagnostics are retained outside Git under
`D:\\ClusterYourCodex-validation\\preview109-arm64-diagnostics-20261004\\`.
The preview remains a prerelease.
Issues #2 and #3 remain open, and stable `v0.0.1` remains immutable at
`e4fbaef04b764268fa038311d85573b18b549f9`.

## Source and merge

- PR #195, `fix(windows): bind profile helper evidence to case root`, merged
  into `origin/main` at `22a2f6fa993aa9e25e47a814395e485a3dba90d7`.
- The PR passed the complete required CI set, including Windows bounded-process
  tests, Windows Setup acceptance, Desktop/Codex bridge live round-trip,
  CodeQL, RustSec, Cargo deny, pnpm audit, MSRV, and Linux/macOS Worker Kits.
- The published candidate is `v0.1.0-preview.109`; it is intentionally a
  prerelease. The follow-up IPC fix must use the next preview number rather
  than replacing this immutable release. Stable `v0.0.1` remains at
  `e4fbaef04b764268fa038311d85573b18b549f9` both locally and remotely.

## ARM64 profile-matrix repair

The preview.108 ARM64 job failed in the profile-matrix child after the fresh
deployment itself had succeeded. The helper-mode path referenced an undefined
`$caseRoot` and then looked for parent evidence under the child work directory.
PR #195 adds an explicit `ProfileMatrixCaseRoot`, requires
`<case>\fresh-deployment` to be its direct child, and recursively flattens the
legacy Windows PowerShell `Value`/`Count` JSON projection before validating
helper records. The source contract also protects the regression with a static
PowerShell test.

The tagged preview.109 ARM64 run then exposed a second boundary, but did not
prove a single root cause. Durable helper evidence contains the install pair
at `22:37:58Z`/`22:38:00Z` and the repair pair at
`22:47:13Z`/`22:47:14Z`; the approximately 553-second gap occurs before the
repair Controller registration, and no normal Uninstall helper pair was
recorded. That is consistent with a slow repair preflight or Task Scheduler
query as well as an IPC problem. The follow-up fix therefore hardens this
test-only IPC to a case-root-confined directory queue with one immutable
`request-<requestId>.json` / `response-<requestId>.json` pair per operation,
atomically claims requests into `processing/`, and retains them until the
response is committed. It is defensive recovery, not proof that the original
timeout was caused by file reuse. A new prerelease candidate with phase
timestamps and a successful ARM64 matrix is required before claiming this
boundary is repaired.

## D-drive VMware CLI evidence

The published `v0.1.0-preview.108` Setup was copied into the D-drive Windows 11
validation guest and repaired through VIX, without Computer Use or VMware GUI
automation. The guest returned Setup exit code `0`. The installed manifest and
all four product binaries reported preview.108; controller health returned
`status=ok`, API `cyc.dev/v1`, and database `ok`; the Controller task was
Running; listeners existed on loopback `47831` and managed-worker `47832`; and
`cyc discover` returned one candidate with `credentialsTransmitted=false` and
`pairingRequired=true`.

The installed same-host fixture then returned exit code `0`, observed
`queued -> running -> succeeded`, 14/14 checks passed, and
`jobRootDeleted=true`. Sanitized records are retained outside Git at:

```text
D:\ClusterYourCodex-validation\preview108-public-20261003\preview108-installed-evidence-20261004.json
D:\ClusterYourCodex-validation\preview108-public-20261003\preview108-roundtrip-result-20261004b.json
D:\ClusterYourCodex-validation\preview108-public-20261003\preview108-roundtrip-checks-20261004.json
```

This is installed same-host Windows evidence. It does not claim a blank-VM
Install → Repair → Upgrade → Rollback → Uninstall matrix or replace the
Windows↔Windows, Windows↔Linux, Linux↔Linux, and native macOS acceptance
boundaries already recorded in the repository. Issues #2 and #3 remain open.
