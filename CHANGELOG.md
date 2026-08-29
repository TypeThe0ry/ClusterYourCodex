# Changelog

All notable user-visible changes are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and product versions
follow Semantic Versioning. Protocol schema identifiers such as `cyc.dev/v1`
are versioned independently from the product.

## [Unreleased]

## [0.1.0-preview.24] - 2026-08-29

### Fixed

- Hardened the Windows profile/path matrix for PowerShell 5.1 and Windows 11
  ARM64 x64 emulation by validating compatibility junctions through the native
  `fsutil` mount-point contract and rejecting ambiguous or unsafe targets.
- Kept production Scheduled Tasks on `InteractiveToken` while adding an
  explicitly guarded `S4U` principal only for the non-interactive disposable
  profile-matrix harness.
- Added Linux hostile-isolation native probe documentation and reproducible
  cleanup evidence without widening the runtime readiness gate.
## [0.1.0-preview.23] - 2026-08-27

### Fixed

- Normalized Windows profile compatibility junction targets across Win32 and
  NT namespace projections, while keeping unknown reparse points fail-closed.
- Preserved the primary profile-matrix case failure when cleanup also fails and
  added scheduled-task state, result, runtime, action, and process diagnostics.

## [0.1.0-preview.22] - 2026-08-26

### Fixed

- Kept the Windows profile-matrix reparse-point guard fail-closed while
  allowing only the operating system's known legacy compatibility junctions
  during disposable profile cleanup.

## [0.1.0-preview.21] - 2026-08-26

### Fixed

- Shortened the disposable profile-matrix local-user description to stay within
  Windows `New-LocalUser`'s 48-character limit, restoring the clean Windows 11
  ARM64 standard/admin/non-ASCII profile acceptance matrix.

## [0.1.0-preview.20] - 2026-08-26

### Fixed

- Fixed the clean Windows 11 profile-matrix release invocation so Windows
  PowerShell receives all four `CaseName` values as one quoted argument instead
  of expanding them into positional arguments under x64 emulation.

## [0.1.0-preview.19] - 2026-08-26

### Fixed

- Added regression coverage proving every macOS hostile-isolation runtime gate
  fails closed when native containment and external reconciliation are absent.
- Fixed the Windows 11 profile-matrix release invocation to accept all four cases
  as a PowerShell array and normalized comma-separated CLI input for compatibility.

## [0.1.0-preview.18] - 2026-08-26

### Added

- Added a clean Windows 11 profile/path acceptance matrix covering standard
  and administrator accounts with ASCII and non-ASCII profiles. Each case runs
  the complete Install → Repair → Uninstall lifecycle under a loaded disposable
  user profile and publishes a JSON receipt with SID/path evidence.
- Added a reusable Windows Authenticode boundary contract and signed-artifact
  verifier. Preview builds remain explicitly unsigned; GA can require a valid
  chain and trusted timestamp for Setup and the narrow elevated helper.

## [0.1.0-preview.17] - 2026-08-26

### Fixed

- Release identity now validates that the current preview has a changelog
  heading, exact predecessor comparison link, and a complete set of version
  link definitions, preventing stale release-note metadata from reaching a
  tagged prerelease.

- Corrected the Keep a Changelog comparison links so the `Unreleased` range
  starts at `v0.1.0-preview.16` and every published preview heading resolves to
  its exact predecessor tag.

## [0.1.0-preview.16] - 2026-08-26

### Added

- macOS managed-process startup now probes the native process inventory and
  verifies the dedicated process group with `proc_listpgrppids` instead of
  treating every non-Linux Unix target as unsupported. The signed macOS Worker
  Kit remains runtime-gated until the native LaunchAgent lifecycle acceptance
  is completed.

## [0.1.0-preview.15] - 2026-08-26

### Fixed

- Windows silent Setup now launches the non-elevated lifecycle through the
  hidden `nsExec` process boundary instead of NSIS `ExecWait`, which could
  briefly expose a PowerShell console under Windows 11 ARM64 x64 emulation.
- Silent Setup diagnostics now capture the visible PowerShell executable,
  command line, parent process, window title, handle, and window class before
  terminating the failed process tree.

## [0.1.0-preview.14] - 2026-08-26

### Fixed

- Corrected the Windows packaging regression guard for the elevated helper's
  hidden-host argument so the PowerShell 5.1 static test evaluates the literal
  `$encodedLoader` token without runtime variable interpolation.

## [0.1.0-preview.13] - 2026-08-26

### Fixed

- Windows firewall-only elevation now passes an explicit `-WindowStyle Hidden`
  argument in addition to the hidden process-start setting. This prevents a
  transient elevated PowerShell console during silent Setup on clean Windows
  11 ARM64 x64 emulation.
- Added a regression assertion for the elevated helper's explicit hidden host
  flag.

## [0.1.0-preview.12] - 2026-08-26

### Fixed

- Windows fresh-deployment repair smoke now waits for an exclusive handle on
  the installed CLI before applying its deliberate corruption fixture. This
  removes the transient executable-lock race observed under clean Windows 11
  ARM64 x64 emulation while keeping the repair proof deterministic.
- Added a packaging regression assertion for the exclusive file-unlock gate.

## [0.1.0-preview.11] - 2026-08-26

### Fixed

- Windows silent Setup now passes `-WindowStyle Hidden` to the nested
  Windows PowerShell bootstrap process as well as the NSIS coordinator. This
  closes the transient console-window race observed under clean Windows 11
  ARM64 x64 emulation.
- Added a static regression assertion that the nested bootstrap host remains
  hidden in the packaged lifecycle path.

## [0.1.0-preview.10] - 2026-08-26

### Fixed

- Windows controller readiness now tolerates the slower first start and HTTP
  response path of the x64 binaries under clean Windows 11 ARM64 emulation,
  while retaining bounded connect, I/O, and overall readiness deadlines.
- Added static regression assertions for the ARM64-compatible readiness
  timeouts so the loopback smoke cannot silently regress to native-only timing.

## [0.1.0-preview.9] - 2026-08-26

### Fixed

- Windows installer controller readiness now sends the validated loopback
  authority (`127.0.0.1:47831`) in its direct TCP health probe. The controller
  rejects a host header without the bound port, which previously made the
  clean self-contained deployment smoke fail even when the process was
  listening.
- Added a regression assertion for the port-qualified health-probe authority.

## [0.1.0-preview.8] - 2026-08-26

### Fixed

- Windows installer controller readiness now probes the loopback health
  endpoint through a direct TCP request instead of inheriting ambient HTTP
  proxy behavior from PowerShell. This keeps the clean Windows 11 ARM64
  x64-emulation acceptance path deterministic while preserving the strict
  loopback-only bind contract.
- Added a packaging regression guard for the direct controller health probe.

## [0.1.0-preview.7] - 2026-08-26

### Fixed

- Windows silent Setup uninstall now passes a null managed-worker plan to the
  core cleanup path instead of dereferencing the absent Install/Repair plan
  after the firewall transaction has completed.
- Added a packaging regression guard for the uninstall lifecycle path so a
  successful firewall mutation cannot be followed by a PowerShell null-plan
  failure that leaves the installed product behind.

## [0.1.0-preview.6] - 2026-08-25

### Added

- Typed enrollment and pairing lifecycle contracts now persist terminal
  failures as `Failed` rather than losing recovery state.
- Worker Kit export has a native, secret-free lifecycle with schema-backed
  manifests and deterministic path-safety checks for Windows, Linux, and
  macOS system aliases.

### Changed

- Controller network planning now resolves one immutable private-LAN plan for
  PlanOnly, Install, Repair, and runtime use, with a .NET fallback when the
  optional Windows NetTCPIP cmdlet is unavailable.
- Windows lifecycle cleanup tolerates a managed process exiting between the
  process snapshot and the stop request while still surfacing real failures.
- Controller identity verification enforces the exact typed multi-SAN set and
  pairing recovery distinguishes Pending, Consumed, Ready, Failed, and
  Revoked states.

### Security

- Enrollment listener, bind/public host, firewall, and persisted identity
  metadata now share the same validated network plan; arbitrary wildcard
  listeners and unsafe path-chain entries fail closed.
- Issue #5 hostile-isolation production readiness remains explicitly false
  until independent OS-level isolation proofs are complete.

## [0.1.0-preview.5] - 2026-08-25

### Fixed

- Windows worker boot-generation allocation now allows enough bounded time
  for the serialized, ACL-protected state replacements performed by multiple
  legitimate concurrent daemon starts. The `v0.1.0-preview.4` release
  workflow failed closed when the eighth contender exceeded the previous
  30-second bound on a clean Windows runner; no release was published.

## [0.1.0-preview.4] - 2026-08-25

### Fixed

- macOS x64 and arm64 release runners now provision and verify Homebrew
  OpenSSL 3 before generating Ed25519-signed Worker Kits; both macOS jobs in
  the `v0.1.0-preview.3` release workflow had failed closed on the runner's
  non-OpenSSL-3 default command.
- The release signing-boundary regression script now runs under both
  PowerShell 7 and Windows PowerShell 5.1 and verifies the macOS OpenSSL 3
  prerequisite explicitly.

## [0.1.0-preview.3] - 2026-08-25

### Added

- Desktop system tray with close-to-tray, explicit Quit, and second-launch
  focus behavior.
- macOS Worker Kit lifecycle packaging foundation with an explicit fail-closed
  managed-execution gate.
- Password, native SSH-agent, and path-safety-validated local private-key
  onboarding, including transient passphrase handling and secret-free recovery
  states.
- Opt-in hostile-isolation protocol/readiness reporting and an internally
  native-tested Linux dedicated-identity/cgroup-v2 mechanism. Independent
  review keeps every production hostile backend fail-closed and publishes no
  schedulable hostile capability until issue #5's remaining isolation proofs
  and native guards are complete.
- Single-source product version and prerelease tag/version validation.
- Rust 1.88.0 workspace/desktop MSRV gates, commit-pinned GitHub Actions,
  dependency security automation, preliminary CycloneDX release-asset SBOM,
  and tagged-build provenance attestation.
- User installation, worker onboarding, integration, compatibility,
  troubleshooting, support, and release-process documentation.

### Changed

- Codex automatic placement now uses the atomic `fleet_plan_submit` path;
  `fleet_plan` is for preview and `fleet_submit` for explicit plan recovery.
- Desktop native subsystems degrade to stable error states rather than
  panicking when per-user data paths or native managers cannot initialize.
- Codex integration repair now reports rollback/recovery failures explicitly
  and recovers only an unambiguous, validated backup.

### Security

- Rotated the prerelease Worker Kit Ed25519 publisher key to
  `cyc-release-2026-02`; the private key now exists only as a
  `production-signing` environment secret guarded by a required reviewer, a
  wait timer, disabled administrator bypass, and a `v*` tag deployment policy.
  Branch-triggered manual release runs fail closed, and runner key files
  receive verified private permissions before any secret byte is written.
- Stable release remains blocked until production Authenticode signing, full
  dependency/payload SBOM and notices, supported upgrade evidence, live
  platform acceptance, and remaining release-governance gates pass. All builds
  before that point remain prereleases.

## [0.1.0-preview.2] - 2026-08-24

### Added

- Self-contained Windows developer-preview package and NSIS Setup.
- Transactional install, repair, uninstall, Codex integration, worker task,
  firewall, and additive `AGENTS.md` lifecycle.
- Windows and Linux signed Worker Kits and fresh-deployment smoke coverage.

[Unreleased]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.24...HEAD
[0.1.0-preview.24]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.23...v0.1.0-preview.24
[0.1.0-preview.23]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.22...v0.1.0-preview.23
[0.1.0-preview.22]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.21...v0.1.0-preview.22
[0.1.0-preview.21]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.20...v0.1.0-preview.21
[0.1.0-preview.20]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.19...v0.1.0-preview.20
[0.1.0-preview.19]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.18...v0.1.0-preview.19
[0.1.0-preview.18]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.17...v0.1.0-preview.18
[0.1.0-preview.17]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.16...v0.1.0-preview.17
[0.1.0-preview.16]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.15...v0.1.0-preview.16
[0.1.0-preview.15]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.14...v0.1.0-preview.15
[0.1.0-preview.14]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.13...v0.1.0-preview.14
[0.1.0-preview.13]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.12...v0.1.0-preview.13
[0.1.0-preview.12]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.11...v0.1.0-preview.12
[0.1.0-preview.11]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.10...v0.1.0-preview.11
[0.1.0-preview.10]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.9...v0.1.0-preview.10
[0.1.0-preview.9]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.8...v0.1.0-preview.9
[0.1.0-preview.8]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.7...v0.1.0-preview.8
[0.1.0-preview.7]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.6...v0.1.0-preview.7
[0.1.0-preview.6]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.5...v0.1.0-preview.6
[0.1.0-preview.5]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.4...v0.1.0-preview.5
[0.1.0-preview.4]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.3...v0.1.0-preview.4
[0.1.0-preview.3]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.2...v0.1.0-preview.3
[0.1.0-preview.2]: https://github.com/TypeThe0ry/ClusterYourCodex/releases/tag/v0.1.0-preview.2
