# Changelog

All notable user-visible changes are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and product versions
follow Semantic Versioning. Protocol schema identifiers such as `cyc.dev/v1`
are versioned independently from the product.

## [Unreleased]

## [0.1.0-preview.54] - 2026-09-01

### Fixed

- Hardened hostile-workload isolation receipts so Linux claim-time checks use
  live cgroup, identity, control-boundary, and resource evidence instead of
  treating the startup receipt timestamp as a worker lifetime limit.
- Extended Linux cgroup-v2 reconciliation to track both `cgroup.procs` and
  `cgroup.threads`, including explicit escape-attempt evidence for both
  membership interfaces.
- Bound Issue #5 GA evidence to exact per-platform selectors, locked commands,
  source-bound markers, native identity/cgroup markers, three-platform matrix
  runs, and downloaded raw-log marker verification.
- Hardened the stable-publisher shell contract with a Bash-safe jq heredoc and
  an independent SHA-256 check for every retained Issue #5 command marker.

## [0.1.0-preview.53] - 2026-09-01

### Added

- Added a native Linux/macOS Worker Kit contract verifier that checks the
  exact five-file package, strict manifest/checksum bindings, executable bits,
  native target identity, and Ed25519 publisher signature without mutating
  systemd or LaunchAgent state.
- Added native Linux, Intel macOS, and Apple Silicon macOS Worker Kit CI
  coverage and invoked the same verifier from tagged Unix preview staging.
- Aligned native verification with the lifecycle installer's canonical JSON
  contract and publisher key id, and added explicit Linux arm64
  cross-compiled package-contract verification without overstating native
  execution evidence.

## [0.1.0-preview.52] - 2026-09-01

### Fixed

- Decoded Windows PowerShell 5.1 profile-matrix IPC, manifests, receipts, and
  evidence as strict UTF-8, preserving non-ASCII user/profile paths on the
  Windows 11 ARM64 x64-emulation acceptance path.
- Added regression coverage for explicit UTF-8 JSON decoding in the profile
  matrix, bootstrap, and fresh-deployment lifecycle harnesses.
- Extended strict UTF-8 file decoding with BOM support to the lifecycle
  coordinator, elevated firewall helper, silent Setup smoke, preview payload
  staging, and Windows worker repair/kit validation paths.
- Retained SID-bound scheduled-task identity resolution and round-trip
  validation from preview.51.

## [0.1.0-preview.51] - 2026-09-01

### Fixed

- Resolved production Scheduled Task identities from immutable account SIDs
  with SID round-trip validation and a fail-closed CIM fallback, so non-ASCII
  account display-name mojibake cannot reach Task Scheduler.
- Added packaging regression coverage for the production resolver and the
  direct `WindowsIdentity.Name` bypass.

## [0.1.0-preview.50] - 2026-09-01

### Fixed

- Kept the profile-matrix helper's legacy request path StrictMode-safe when an
  older child omits the optional `accountSid` field, while retaining the
  SID-bound account evidence for current requests.

## [0.1.0-preview.49] - 2026-09-01

### Fixed

- Bound Windows profile-matrix task registration and disposable-user
  credentials to the immutable account SID, with a translation fallback for
  short-lived local SAM propagation windows.
- Preserved the account display value as diagnostic evidence so ARM64/x64
  PowerShell Unicode projection differences cannot reject an otherwise
  SID-bound non-ASCII profile case.
- Added static regression coverage for the explicit account-SID request field,
  SID-derived scheduler credential, and display-mismatch evidence binding.

## [0.1.0-preview.48] - 2026-09-01

### Fixed

- Raised the Windows-only PowerShell containment integration-test ceiling to
  five minutes to absorb hosted-runner Defender/JIT cold-start variance while
  keeping production step timeouts unchanged.

## [0.1.0-preview.47] - 2026-09-01

### Fixed

- Cross-check administrator profile cases against the well-known local
  Administrators SID when ARM64/x64-emulated filtered tokens omit that group
  from `WindowsIdentity.Groups`, and retain token/SAM membership evidence in
  the child receipt.
- Added static regression coverage for both membership evidence paths and
  fail-closed query-error handling.

## [0.1.0-preview.46] - 2026-09-01

### Fixed

- Bound Windows profile-matrix administrator setup to the created local-user
  SID and wait for consecutive Administrators-group observations before
  creating the child logon token, eliminating ARM64 x64-emulation races that
  misclassified administrator profiles as standard users.
- Retained administrator-membership evidence in the profile-matrix receipt
  and added static regression coverage for the SID-bound propagation gate.

## [0.1.0-preview.45] - 2026-09-01

### Fixed

- Closed a Windows silent-Setup cleanup race by stopping only tasks proven to
  belong to the disposable install root, then re-enumerating owned processes
  after the Scheduled Task restart policy has been quiesced.
- Added static regression coverage for the task-restart cleanup and exit-code
  reconciliation paths so future packaging changes fail closed before release.

## [0.1.0-preview.44] - 2026-08-31

### Fixed

- Made the Windows self-contained preview resolve the NSIS compiler through
  PATH/Chocolatey shims and all supported package layouts, so Setup.exe
  staging no longer assumes a single Program Files location.
- Added release-contract regression coverage for the NSIS PATH, `NSIS\\Bin`,
  and `nsis.install` tool layouts while retaining fail-closed discovery.

## [0.1.0-preview.43] - 2026-08-31

### Fixed

- Bound Linux and macOS worker lifecycle cleanup to the install manifest's
  authoritative install, data, workspace, log, and LaunchAgent roots; requests
  with mismatched roots now fail closed before service or file mutation.
- Added sentinel and zero-call regression coverage for path-binding failures so
  unrelated same-named files and services remain untouched.
- Recorded the Linux systemd unit path in the install manifest and reject
  lifecycle calls whose XDG_CONFIG_HOME would redirect cleanup to a foreign
  same-named unit.
- Bound Windows Scheduled Task lifecycle operations to the current user SID,
  owned install root, executable, and working directory; foreign-principal and
  foreign-root fixtures now fail closed before mutation.
- Applied the same root-task-path, SID, executable, arguments, and working
  directory ownership preflight to the standalone Windows worker kit; a
  same-named foreign task is rejected before stop, unregister, or rollback.
- Pinned the external hostile-isolation guard executable by SHA-256 and bound
  the digest through invocation and receipt attestation validation; hostile
  runtime scheduling remains fail-closed until the production containment gates
  are independently accepted.
- Made the Windows profile matrix recognize Administrators membership in a
  filtered, non-elevated token while retaining a separate elevation signal;
  administrator cases now remain stable on UAC-filtered ARM64 runners.

## [0.1.0-preview.42] - 2026-08-31

### Fixed

- Hardened Windows profile-matrix exit-code handling so a null parent Process.ExitCode is reconciled from the validated child receipt and fails closed when the receipt is missing or malformed.
- Kept all public preview artifacts prerelease while GA readiness remains gated by independently verifiable Issue #2, #3, and #5 evidence.

## [0.1.0-preview.41] - 2026-08-31

### Fixed

- Hardened the protected GA workflow with an indentation-aware semantic
  contract, exact manual inputs and job dependencies, explicit helper exit-code
  checks, globally routable HTTPS endpoint validation, redirect rejection, and
  stable-bundle ZIP path normalization.
- Made retained GA raw-log materialization fail closed against existing files,
  reparse points, path traversal, private/loopback hosts, and partial writes by
  using fresh same-directory files and atomic publication.
- Completed Windows profile-matrix lifecycle hardening: parent-owned task
  registration consumes IPC requests before publishing responses, orphan
  backups are cleaned, newly created work roots are removed on every failure
  path, and scheduled-task principals/triggers are bound to the expected SID
  and root task path.
- Kept every tagged build public and prerelease; stable publication remains
  blocked on the independent external GA evidence and issue-completion gates.

## [0.1.0-preview.40] - 2026-08-31

### Fixed

- Hardened Windows profile-matrix task registration and rollback with a
  structured v2 IPC contract, operation-bound responses, schema-validated
  snapshots, root task-path scoping, and production-only raw XML restoration.
- Made the fresh-deployment lifecycle harness ownership-safe: isolated roots
  now require a schema-bound marker, pre-existing roots are rejected, cleanup
  is armed before child lifecycle calls, and lifecycle postconditions are
  proven before and after synthetic-root removal.
- Added bounded profile cleanup retries and exact-case-set validation so a
  delayed Windows profile unload or a mismatched matrix request cannot be
  reported as a passing acceptance run.
- Extended GA readiness with source-bound retained raw logs, strict Issue
  #2/#3/#5 gate objects, protected external stable-builder attestation inputs,
  and digest/path cross-checks. Public preview tags remain non-draft
  prereleases; stable publication remains a separate evidence-gated path.
- Extended the worker pairing transaction lock wait without weakening the
  underlying lock or changing its critical section, eliminating the observed
  concurrent repair timeout flake under slow ACL/file replacement.

## [0.1.0-preview.39] - 2026-08-30

### Fixed

- Separated public prerelease publication into the dedicated
  `preview-publication` environment. Tagged previews no longer deadlock on
  the stable `production` environment's prevent-self-review rule, while the
  independent GA workflow keeps `production` protected and stable-only.
- Updated the release-process, roadmap, and version-consistency contracts to
  enforce the preview/stable environment boundary.

## [0.1.0-preview.38] - 2026-08-30

### Fixed

- Tightened the worker API schema for `stateUpdateResponse.run` by binding it
  to the concrete `Run` wire contract, including strict run-state,
  placement-explanation, rejection-code, and artifact fields.
- Added a protocol regression test and JSON Schema validation coverage so
  missing required run fields and unknown sensitive fields fail closed.
- Revalidated the full Rust workspace on the P1 worker at the exact candidate
  commit; tagged builds remain public GitHub prereleases while stable GA gates
  are still open.

## [0.1.0-preview.37] - 2026-08-30

### Fixed

- Reaped the installed `cyc.exe` CLI probe before the Repair tamper fixture;
  Windows reports its executable as ProcessName `cyc`, so the lifecycle smoke
  now inventories and stops it alongside the controller and worker binaries.
- Added regression assertions that both initial-install and first-Repair probe
  phases leave no owned process holding an install-file handle.
- Reissued the candidate as a public prerelease after preview.35 exposed the
  Windows clean-profile file-lock failure; stable GA evidence remains separate.

## [0.1.0-preview.36] - 2026-08-30

### Fixed

- Accepted the Windows 11 `AppData\Local\History` compatibility junction
  emitted by a fresh profile, binding it to the exact in-profile
  `AppData\Local\Microsoft\Windows\History` target before cleanup.
- Added an explicit static regression assertion for the History alias so the
  Profile Matrix remains fail-closed for unknown reparse points.
- Hardened the stable GA evidence contract with source-bound Issue #2 gates,
  canonical closed-issue snapshot checks, HTTPS evidence-host validation, and
  bounded evidence downloads. Tagged builds remain public GitHub prereleases.

## [0.1.0-preview.35] - 2026-08-30

### Fixed

- Closed the Windows packaging regression-coverage gap by explicitly locking
  the nested `AppData\Roaming\Application Data` compatibility junction in the
  static Profile Matrix guard alongside the Local and LocalLow aliases.
- Kept the candidate as a public GitHub prerelease while preview.34 remains
  available for comparison and the independent stable GA gates stay open.

## [0.1.0-preview.34] - 2026-08-30

### Fixed

- Extended the Windows profile-matrix compatibility-junction allow-list to
  cover the nested `AppData\Local`, `AppData\LocalLow`, and `AppData\Roaming`
  `Application Data` aliases emitted by a fresh Windows profile. Each alias
  remains recursively discovered, mount-point-tag checked, and bound to an
  exact target inside the same disposable profile before cleanup.
- Added a packaging regression assertion for the nested aliases so a hosted
  clean-profile run cannot regress into treating OS-created junctions as
  package-owned reparse points.
- Reissued the public candidate after preview.32 exposed the nested alias
  during the Windows 11 ARM64 profile matrix; tagged builds remain public
  GitHub prereleases while the independent GA gates are still open.

## [0.1.0-preview.33] - 2026-08-30

### Fixed

- Added a fail-closed canonical GA evidence contract for Issue #3 and Issue
  #5. Readiness and the protected stable publisher now require source-bound,
  externally retained evidence with HTTPS/SHA-256 raw logs and every
  platform-specific acceptance gate set to boolean `true`.
- Added Pester coverage for issue evidence shape, source binding, external
  provider restrictions, raw-log integrity, and missing or false acceptance
  gates. Closing a GitHub issue alone cannot satisfy stable-release readiness.
- Kept tagged public builds as non-draft GitHub prereleases; a stable Release
  remains blocked until the independent Windows, macOS, hostile-isolation, and
  governance gates have real retained evidence.

## [0.1.0-preview.32] - 2026-08-30

### Fixed

- Corrected Windows profile-matrix atomic JSON persistence for Windows
  PowerShell/.NET Framework by pre-creating a same-volume backup file before
  calling `File.Replace`, eliminating the misleading legal-path failure seen
  in the preview.30 ARM64 compatibility run.
- Kept profile child-process reaping, recursive compatibility-junction
  validation, strict task ownership evidence, and fail-closed cleanup from the
  previous preview while preserving the primary failure when cleanup also
  fails.
- Reissued the public candidate as preview.32 after cancelling the affected
  preview.31 workflow; tagged public builds remain GitHub prereleases until
  the independent stable GA gates pass.

## [0.1.0-preview.31] - 2026-08-30

### Fixed

- Fixed Windows profile-matrix IPC persistence on Windows PowerShell/.NET by
  using a flushed, create-new temporary file and a real same-directory backup
  path for `File.Replace`; child processes are reaped before profile cleanup,
  and cleanup failures remain visible alongside the primary case failure.
- Added strict Scheduled Task ownership and action evidence checks so the
  elevated profile-matrix helper can only register and remove the exact root
  task bound to the disposable profile SID and package directory.
- Hardened Linux Worker Kit preinstall validation to require the exact signed
  five-file kit, target-specific manifest identity, ordered payload entries, and
  local size/digest matches before any worker or systemd state is changed.
- Tightened the protected GA publisher's final governance snapshot, annotated
  tag binding, attestation signer policy, detached stable-index signature, and
  post-publication byte-for-byte asset re-download checks. Public tagged builds
  remain GitHub prereleases until the true stable GA gates pass.

## [0.1.0-preview.30] - 2026-08-30

### Fixed

- Hardened the protected stable GA path: branch protection snapshots now use
  the authoritative branch endpoint and fail closed on API errors.
- Bound stable bundles to an exact top-level asset set, complete `SHA256SUMS`,
  a signed CycloneDX 1.6 SBOM, non-empty third-party notices, and provenance
  subjects whose digests and byte counts match every indexed payload.
- Added stable-publisher cross-binding of the external GA evidence index hash
  and cryptographic `gh attestation verify` checks for every stable payload;
  tagged public builds remain prereleases until those gates pass.

## [0.1.0-preview.29] - 2026-08-30

### Added

- Added the protected GA stable publisher path, requiring an externally built stable bundle with exact source, sidecars, release-index, and attested provenance before `gh release create` verifies a public non-prerelease release.

### Fixed

- Strengthened stable bundle verification so every `SHA256SUMS` entry is parsed, unique, present, and digest-checked before publication.

## [0.1.0-preview.28] - 2026-08-30

### Fixed

- Replaced Windows `Compress-Archive` integration packaging with explicit hidden-entry ZIP creation so `.agents`, `.codex-plugin`, and `.mcp.json` survive extraction.
- Added post-archive integration tree, byte, and required-hidden-entry verification before any preview artifact is uploaded.
- Bound tagged prerelease provenance to an immutable payload subject set and record the attestation id, URL, bundle digest, subject count, and subject digests in `release-index.json`.
- Clarified that tagged previews are public prereleases; stable publication remains behind the protected GA evidence workflow.

## [0.1.0-preview.27] - 2026-08-29

### Fixed

- Restored Windows 11 ARM64 disposable-profile acceptance by registering the production Interactive Scheduled Task principal without starting it from the non-interactive harness.
- Narrowed profile cleanup compatibility handling to the OS-owned Documents `My Music`, `My Pictures`, and `My Videos` junctions after exact native mount-point target validation.
- Hardened Linux hostile-isolation claim, execution, and reconciliation checks against residual processes sharing the dedicated execution identity and writable ancestor cgroup controls.
- Made tagged preview releases public GitHub prereleases after their gated producer and acceptance jobs complete.

## [0.1.0-preview.26] - 2026-08-29

### Fixed

- Added explicit macOS native process-group inventory so controller payloads distinguish macOS lifecycle reconciliation from unsupported containment.
- Kept hostile-workload isolation fail-closed while preserving platform-specific worker capability reporting.

## [0.1.0-preview.25] - 2026-08-29

### Fixed

- Fixed Linux hostile-isolation startup ordering so the disposable cgroup-v2 child is created and its control boundary is validated before worker/credential boundary checks.
- Expanded the Linux native acceptance probe to prove dedicated identity execution, credential/guard protection, cgroup escape blocking, residual reconciliation, and cleanup when run on a configured worker.

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

[Unreleased]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.54...HEAD
[0.1.0-preview.54]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.53...v0.1.0-preview.54
[0.1.0-preview.53]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.52...v0.1.0-preview.53
[0.1.0-preview.52]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.51...v0.1.0-preview.52
[0.1.0-preview.51]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.50...v0.1.0-preview.51
[0.1.0-preview.50]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.49...v0.1.0-preview.50
[0.1.0-preview.49]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.48...v0.1.0-preview.49
[0.1.0-preview.48]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.47...v0.1.0-preview.48
[0.1.0-preview.47]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.46...v0.1.0-preview.47
[0.1.0-preview.46]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.45...v0.1.0-preview.46
[0.1.0-preview.45]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.44...v0.1.0-preview.45
[0.1.0-preview.44]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.43...v0.1.0-preview.44
[0.1.0-preview.43]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.42...v0.1.0-preview.43
[0.1.0-preview.42]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.41...v0.1.0-preview.42
[0.1.0-preview.41]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.40...v0.1.0-preview.41
[0.1.0-preview.40]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.39...v0.1.0-preview.40
[0.1.0-preview.39]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.38...v0.1.0-preview.39
[0.1.0-preview.38]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.37...v0.1.0-preview.38
[0.1.0-preview.37]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.36...v0.1.0-preview.37
[0.1.0-preview.36]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.35...v0.1.0-preview.36
[0.1.0-preview.35]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.34...v0.1.0-preview.35
[0.1.0-preview.34]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.33...v0.1.0-preview.34
[0.1.0-preview.33]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.32...v0.1.0-preview.33
[0.1.0-preview.32]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.31...v0.1.0-preview.32
[0.1.0-preview.31]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.30...v0.1.0-preview.31
[0.1.0-preview.30]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.29...v0.1.0-preview.30
[0.1.0-preview.29]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.28...v0.1.0-preview.29
[0.1.0-preview.28]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.27...v0.1.0-preview.28
[0.1.0-preview.27]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.26...v0.1.0-preview.27
[0.1.0-preview.26]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.25...v0.1.0-preview.26
[0.1.0-preview.25]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.24...v0.1.0-preview.25
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
