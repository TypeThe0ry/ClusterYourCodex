# Changelog

All notable user-visible changes are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and product versions
follow Semantic Versioning. Protocol schema identifiers such as `cyc.dev/v1`
are versioned independently from the product.

## [Unreleased]

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

[Unreleased]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.6...HEAD
[0.1.0-preview.6]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.5...v0.1.0-preview.6
[0.1.0-preview.5]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.4...v0.1.0-preview.5
[0.1.0-preview.4]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.3...v0.1.0-preview.4
[0.1.0-preview.3]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.2...v0.1.0-preview.3
[0.1.0-preview.2]: https://github.com/TypeThe0ry/ClusterYourCodex/releases/tag/v0.1.0-preview.2
