# Current GitHub and preview release audit — 2026-10-03

This is the current release record for `TypeThe0ry/ClusterYourCodex`. The live
GitHub repository, CI runs, and command-line VMware evidence are authoritative;
older audit files are historical context only.

## Current candidate and exact-commit evidence

- PR #183 (`ec4ec8f49af4d31ad79d5a02c7c143c846918956`) fixed the Windows
  profile-matrix scheduler deadlock. Disposable Task Scheduler probes now stay
  in the elevated parent helper, shutdown remains bounded and exact-process
  scoped, and same-name foreign tasks are rejected before `-Force` replacement.
  Candidate run [37057151914](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/37057151914)
  passed the Windows desktop/bridge, Setup, bounded Rust, cross-platform Rust,
  Worker Kit, security, and live Windows controller/worker checks.
- PR #184 (`dcf4a6dbf7c3f1287e86da80397ac4d75f766f5c`) synchronized every
  product surface to `0.1.0-preview.106`. Its candidate checks
  [37062423830](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/37062423830)
  and packaged Setup checks
  [37062423747](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/37062423747)
  passed.
- PR #185 (`3402b5ba24229300ed51464638be0793b50225c0`) recorded the final
  preview.106 audit baseline and the VMware evidence on `origin/main`.
- The first attempt of tagged workflow
  [37067050549](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/37067050549)
  stopped at the exact-commit identity gate because the matching `main` push CI
  had not completed. After that push run succeeded, the full tagged workflow
  was rerun. Its Windows x64 self-contained job passed Setup, fresh deployment,
  silent Setup lifecycle, and asset staging; the release-index/provenance job
  and the publish job also passed.
- GitHub now publishes
  [`v0.1.0-preview.106`](https://github.com/TypeThe0ry/ClusterYourCodex/releases/tag/v0.1.0-preview.106)
  as a non-draft prerelease at `2026-10-03T00:06:21Z`. The Release contains 23
  assets. All 11 downloaded per-asset SHA-256 sidecars matched their payloads
  in `D:\ClusterYourCodex-validation\preview106`, including Setup.exe,
  `release-index.json`, portable/self-contained archives, Worker Kits, and the
  SBOM metadata. The tag dereferences to
  `dcf4a6dbf7c3f1287e86da80397ac4d75f766f5c`.

## Command-line VMware and cross-platform evidence

The D-drive Windows 11 VMware guest (build 26200, launched and exercised with
`vmrun`/VIX only) started from a clean product state. Preview.105 Setup exited
zero, the controller health endpoint returned HTTP 200 with `database: ok`,
ports 47831/47832 listened, and LAN discovery returned
`credentialsTransmitted: false` with explicit pairing required. The installed
controller/worker harness then passed the complete queued → running →
succeeded round trip, artifact/log verification, cleanup, process cleanup, and
secret scan. Sanitized checks are retained outside Git at
`D:\ClusterYourCodex-validation\guest-exchange\vm-roundtrip-checks-20261003.json`.

Independent evidence also covers Windows controller ↔ Linux worker and Linux
controller ↔ Linux worker. macOS managed-runtime validation is intentionally
deferred. These results prove usable preview paths, not every GA lifecycle gate.

## Remaining issue boundaries

Issue [#2](https://github.com/TypeThe0ry/ClusterYourCodex/issues/2) remains open:
hosted CI and the VMware run do not replace a genuinely blank current-source
VM matrix of Install → Repair → N-1→N Upgrade → interrupted Rollback →
Uninstall, a separate guest-worker acceptance, and remaining signing/tray GA
requirements.

Issue [#3](https://github.com/TypeThe0ry/ClusterYourCodex/issues/3) remains open:
native macOS LaunchAgent activation, managed controller/worker round-trip,
detached descendant cleanup, and PID-reuse process-identity evidence are not
claimed by package-only checks.

The stable [`v0.0.1`](https://github.com/TypeThe0ry/ClusterYourCodex/releases/tag/v0.0.1)
tag remains immutable at
`e4fbaef04b764268fa038311d85573b18b549f9`. No stable tag or stable asset is
modified by preview work.
