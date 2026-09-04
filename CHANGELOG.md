# Changelog

All notable user-visible changes are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and product versions
follow Semantic Versioning. Protocol schema identifiers such as `cyc.dev/v1`
are versioned independently from the product.

## [Unreleased]

## [0.1.0-preview.82] - 2026-09-05

### Fixed

- Give the Windows controller/worker live acceptance fixture bounded cold-start
  headroom by raising its disposable JobSpec timeout from 60 to 300 seconds;
  the production worker and step timeout semantics remain unchanged.
- Raise the CI and tagged-preview harness deadline to 360 seconds so a slow
  hosted Windows PowerShell/JIT startup cannot be reported as a false negative
  after the fixture's own fail-closed timeout has been extended.

### Tests

- Main CI run 33914624727 passed all ten Linux, macOS, Windows, MSRV, native
  worker-kit, desktop, and live controller/worker jobs.
- Exact-SHA P1 validation at commit 5f796697794165cd4a282ddcfd9755176c524621
  passed Rust 1.98 fmt, clippy, workspace tests/build, and the live Linux
  controller/worker round trip with route, artifact, cleanup, and secret-scan
  checks enabled.

## [0.1.0-preview.81] - 2026-09-04

### Fixed

- Align the tagged developer-preview workflow with the repository's strict
  `preview.N`, `alpha.N`, `beta.N`, and `rc.N` prerelease contract, including
  rejection of leading-zero identifiers and stable/dev tags.
- Normalize every nested raw-log verification timestamp to invariant UTC ISO
  before Windows PowerShell 5.1 serialization, preventing legacy `/Date(...)\/`
  values from invalidating otherwise valid GA evidence.

### Tests

- Add a PowerShell 5.1/7 regression covering nested timestamp arrays, culture
  independence, and fail-closed handling of unspecified `DateTime` values.

## [0.1.0-preview.80] - 2026-09-04

### Fixed

- Allow the Linux controller/worker live round-trip probe to consume three
  prebuilt executable binaries through `CYC_BIN`, `CYC_CONTROLLER_BIN`, and
  `CYC_WORKER_BIN` without requiring Cargo on the acceptance host.

### Tests

- Retain the exact-SHA P1 live round-trip path for hosts that validate signed
  release binaries without a local Rust toolchain.

## [0.1.0-preview.79] - 2026-09-04

### Fixed

- Verify annotated prerelease tags through an isolated fetched ref because the
  GitHub checkout action rewrites the normal tag ref to the detached commit.
- Verify stable GA source tags through the same isolated fetched ref in both
  protected GA jobs, so a future manual stable dispatch cannot be blocked by
  checkout ref rewriting.
- Wait for truthful scheduler CPU headroom before submitting the Windows live
  controller/worker round-trip job, avoiding transient capacity conflicts while
  preserving fail-closed resource accounting.

### Tests

- Add a Windows round-trip regression for the scheduler headroom wait and run
  the full cross-platform CI plus independent P1 validation at this commit.

## [0.1.0-preview.78] - 2026-09-04

### Fixed

- Bind Issue #2 and Issue #3 raw-log gate records to their manifest provenance,
  including source commit, execution host, run identity, command, timestamps,
  test counts, and command-derived markers; require the structured blocker
  inventory on the only gate that can consume it.
- Emit invariant UTC timestamps from the PowerShell 5.1 raw-log verifier so
  `DateTime` materialization cannot turn valid ISO-8601 evidence into
  culture-local strings.
- Make Linux and macOS worker-kit interrupted-rollback fixtures reach the
  `after-marker-removal` tombstone path with a pairing worker that writes its
  protected config before returning the injected failure; retain the bad-kit
  repair regression separately.

### Tests

- Add a PowerShell 5.1/7 regression for invariant raw-log timestamp output and
  complete the Linux/macOS worker-kit lifecycle matrix with watchdog evidence.

## [0.1.0-preview.77] - 2026-09-04

### Fixed

- Make Linux worker-service uninstall transactional: stop the owned service,
  stage its unit beside the original, restore the exact bytes when
  `daemon-reload` fails, and retire the staging file only after the manager
  accepts the removal.
- Fail closed when a Linux `systemd` manager or macOS `launchctl` cannot prove
  that an owned worker service is stopped before uninstall removes its files.

### Tests

- Add Linux regressions for active-service disable failures and daemon-reload
  rollback, plus a macOS LaunchAgent bootout-failure retry fixture.
- Bound tagged-preview artifact, indexing, and publication jobs with explicit
  timeouts so a runner-side hang cannot block the prerelease pipeline forever.

## [0.1.0-preview.76] - 2026-09-04

### Added

- Add a Windows controller-to-worker live round-trip probe to the CI and
  tagged-prerelease paths, including protected job-root ACLs, TLS pairing,
  snapshot transfer, heartbeat/completion, artifact integrity, process-tree
  cleanup, and secret-scan evidence.
- Add a fail-closed Issue #5 selector guard that requires an exact native
  platform test selector and rejects empty or receipt-only test runs.

### Fixed

- Bind the external hostile-guard runner to a shell-free, bounded helper
  lifecycle with native exit-status checks, timeout termination/reaping, and
  identity-bound protected receipts.
- Handle the Windows ARM64 x64-emulation profile helper's transiently missing
  `Process.ExitCode` by refreshing the process and consuming only a validated
  child receipt fallback; malformed or missing receipts remain failures.
- Preserve the dependency-security gate during npm advisory API outages with a
  strict OSV fallback over the installed pnpm graph; unknown or unavailable
  advisory results remain fail-closed.

### Documentation

- Keep clean-VM, cross-machine, production-signing, macOS LaunchAgent, and
  hostile-workload isolation evidence explicitly marked as pending GA gates.

## [0.1.0-preview.75] - 2026-09-04

### Fixed

- Serialize the direct worker-helper process tests with the Linux child-process
  guard so test-only subprocesses cannot be mistaken for managed descendants
  during process-tree cleanup.
- Reject malformed or lower worker-kit SemVer candidates before a new upgrade
  transaction mutates files or scheduled-task state, while preserving equal-
  version repair as an idempotent operation.
- Bound Linux managed process-tree cleanup after a root exit: retain a short
  quiescence probe, adopt late descendants, and preserve the graceful
  termination window before fail-closed escalation.
- Extend worker-kit fixture coverage for canonical prerelease ordering,
  numeric-versus-text precedence, malformed-version rejection, interrupted
  rollback, and downgrade rejection.

### Documentation

- Document the IPv4-only precondition for the live Linux controller-to-worker
  round-trip harness and keep the remaining macOS, Windows, and hostile-
  isolation acceptance gates explicit.

## [0.1.0-preview.74] - 2026-09-03

### Changed

- Refresh the compatibility and roadmap matrix for preview.74 and document the
  native-selector discovery/positive test-count guard alongside the Windows
  ARM64 child-receipt exit-code fallback. The tagged preview workflow remains
  the source of truth for the next hosted acceptance result.

## [0.1.0-preview.73] - 2026-09-03

### Fixed

- Allow `scripts/Test-GARawLogs.ps1 -ContractOnly` to run without runtime
  evidence/download parameters, while retaining explicit validation for all
  required inputs during a real raw-log verification run.
- Add a regression test covering the parameter-free contract-only invocation.

## [0.1.0-preview.72] - 2026-09-03

### Fixed

- Bound the development controller proxy to the same native route allowlist,
  validating raw request targets before URL normalization and rejecting encoded
  path traversal, slash, backslash, malformed-percent, and unknown routes.
- Added regression coverage proving encoded dot segments never reach the
  upstream controller and that client job identifiers remain native-route safe.
- Opened child stdout/stderr log files before hostile identity hand-off without
  following final symlinks or Windows reparse points, then carried the handles
  through reader tasks so path replacement cannot redirect evidence output.
- Added Unix symlink-race regression coverage for process log destinations.
- Hardened GA raw-log evidence to require a source-bound JSON envelope, positive
  bounded test counts, zero exit status, cleanup confirmation, and content/hash
  cross-binding across readiness and preview-publisher checks.

## [0.1.0-preview.71] - 2026-09-03

### Fixed

- Made the Windows profile-matrix task-helper IPC tolerate transient
  `File.Replace` sharing violations on ARM64 x64 emulation with a bounded,
  fail-closed retry window, preserving atomic evidence and response commits.
- Added a packaging regression assertion that keeps the lock-specific retry
  contract present in future Windows profile-matrix changes.
- Pinned the transitive `fast-uri` runtime dependency to `3.1.6`, closing the
  four newly published high-severity URL-normalization advisories.

## [0.1.0-preview.70] - 2026-09-02

### Fixed

- Pinned the transitive `qs` runtime dependency to `6.16.0` through the
  workspace override and refreshed the lockfile, closing the published
  denial-of-service advisories for `qs` parsing and stringification.

## [0.1.0-preview.69] - 2026-09-02

### Fixed

- Hardened Linux user-systemd and macOS LaunchAgent lifecycle paths so
  pre-existing service directories, units, and plists are verify-only: weak,
  symlinked, or foreign-owned state fails closed before transaction recovery or
  installation can adopt it.
- Added regression coverage for weak and foreign service state, preserving
  path-binding errors and proving that rejected lifecycle attempts leave worker
  binaries, manifests, credentials, markers, logs, and service state intact.

## [0.1.0-preview.68] - 2026-09-02

### Fixed

- Kept the worker isolation code clean under the minimum supported Rust 1.88
  clippy profile by using captured format arguments in external-guard and
  Linux identity diagnostics. This removes an MSRV-only lint failure without
  changing the fail-closed isolation behavior.

## [0.1.0-preview.67] - 2026-09-02

### Fixed

- Made Issue #5 marker validation type-sensitive and fail-closed across the
  PowerShell, raw-log, Python, and stable-publisher paths: marker fields must
  be unique JSON string arrays, and scalar/numeric/blank/duplicate values are
  rejected.
- Bound the positive Windows/macOS Issue #5 selectors to explicit native
  identity, containment, tamper, credential-isolation, and platform-specific
  restart markers so a canonical selector alone cannot satisfy GA.

## [0.1.0-preview.66] - 2026-09-02

### Fixed

- Closed the GA evidence contract for legacy Issue #2/#3 boolean gate maps:
  unknown keys are rejected by both readiness validators and the stable
  publisher contract.
- Separated Issue #5 positive native Windows/macOS acceptance selectors from
  fail-closed unavailable-backend regressions, and required a platform-native
  residual-process marker on every restart matrix row.

## [0.1.0-preview.65] - 2026-09-02

### Fixed

- Made the Windows worker-kit installer independent of PowerShell module
  auto-loading by routing every manifest, signature, payload, and staged-copy
  digest through a streaming .NET SHA-256 helper. The managed-worker
  `powershell.exe -NoProfile` boundary now remains verifiable even when
  `Get-FileHash` is unavailable.

## [0.1.0-preview.64] - 2026-09-02

### Fixed

- Made Windows package, fresh-deployment, and silent-Setup integrity checks
  independent of PowerShell module auto-loading by using a streaming .NET
  SHA-256 helper. Clean `pwsh` to Windows PowerShell 5.1 child boundaries now
  validate manifests and lifecycle payloads consistently.
- Applied the same module-independent hashing boundary to the lifecycle
  coordinator and elevated firewall helper so Setup/repair/rollback receipts
  remain verifiable when launched from a PowerShell Core environment.

## [0.1.0-preview.63] - 2026-09-02

### Fixed

- Bounded every Windows fresh-deployment and profile-matrix child process,
  including process-tree termination and receipt-backed exit handling, so a
  hung acceptance child cannot strand a hosted runner or suppress diagnostics.
- Added explicit finite timeouts to the Windows x64 and ARM64 release
  acceptance jobs, including the silent Setup and four-case profile matrix.
- Hardened existing private transaction/config roots across the Windows,
  Linux, and macOS worker-kit installers with verify-only owner/mode/ACL and
  reparse-point preflights before journal or manifest reads.

## [0.1.0-preview.62] - 2026-09-02

### Fixed

- Hardened Windows worker-kit installation and lifecycle transactions against
  reparse-point ancestors when a destination or rollback path is created.
- Made existing Windows private roots verify-only with an exact protected ACL;
  weak or foreign roots are rejected without repair or mutation.
- Applied the same verify-only owner/mode contract to Linux and macOS worker
  roots and added regression fixtures for weak pre-positioned directories.
- Restored Linux user linger on every pre-activation failure and retained the
  runtime-gated fail-closed boundary when a user systemd manager is absent.
- Made the Windows reparse-point fixture cleanup safe in non-interactive
  PowerShell so the managed worker-kit gate cannot fail on a confirmation
  prompt after a successful assertion.

## [0.1.0-preview.61] - 2026-09-02

### Fixed

- Made Linux and macOS worker-kit first-install rollback crash-recoverable:
  transaction journals are retired through an atomic intermediate path and a
  tombstone preserves recovery intent if the process stops after ownership
  marker removal.
- Added fail-closed validation for active, retired, and tombstone transaction
  metadata, including schema, installer identity, marker state, and committed
  state before any cleanup is resumed.
- Added deterministic interrupted-rollback/re-entry fixtures for both worker
  kit installers, including secret-redaction checks and post-recovery residue
  assertions.

## [0.1.0-preview.60] - 2026-09-02

### Fixed

- Terminated Codex and MCP child processes on pipe extraction, reader-thread,
  wait, and timeout failures so native desktop integration cannot strand a
  background process after an error.
- Kept Windows runtime teardown failures inside the Install/Repair rollback
  transaction so file, task, and integration compensations continue and report
  incomplete rollback explicitly.
- Prevented Linux and macOS worker-kit first-install failures from leaving
  ownership markers that could authorize later cleanup, and made marker-only
  installs fail closed when the authoritative manifest is missing.
- Added explicit Linux systemd process-group teardown and macOS LaunchAgent
  process-group policy to the worker-kit contracts.
- Rejected control-character paths and prevented hostile Linux identity handoff
  from taking ownership of guard receipts inside worker or job scopes.

## [0.1.0-preview.59] - 2026-09-02

### Documentation

- Clarified the distinction between the preview.58 hosted Windows 11 ARM64
  x64-emulation profile matrix (all standard/admin × ASCII/non-ASCII cases
  passed) and the independent clean-VM, native Windows x64, and live-fleet
  evidence that remains required for GA.
- Synchronized the roadmap, compatibility table, support boundary, and release
  checklist so prerelease evidence is not presented as stable certification.

### Fixed

- Stabilized the concurrent controller reservation regression test by refreshing
  its fixture heartbeat after independent SQLite connections finish opening;
  slow Windows runners no longer turn the reservation-atomicity test into an
  unrelated stale-node failure.

## [0.1.0-preview.58] - 2026-09-01

### Fixed

- Hardened Issue #5 provenance schema parity by rejecting non-string run
  identifiers, nodes, providers, and host types before normalization.
- Bound every Issue #5 execution `runId` to one platform, rejected duplicate
  IDs inside a matrix, and made aggregate and retained marker arrays unique,
  non-empty string collections.
- Synchronized the raw-log publisher, stable jq contract, and PowerShell
  readiness verifier with the stricter run and marker binding rules.

## [0.1.0-preview.57] - 2026-09-01

### Fixed

- Fixed Issue #5 raw-log verification for matrix gates by applying provenance
  matching only to single-platform gate records and retaining array shape for
  single-marker evidence.
- Rejected conflicting `testSelector`/`selector` and
  `rawLogMarkers`/`markers` compatibility aliases instead of silently choosing
  one spelling, and aligned the stable jq contract with the same rule.
- Added chronological ISO-8601 timestamp ordering to the stable jq evidence
  contract and regression coverage for the corrected downloaded-evidence path.

## [0.1.0-preview.56] - 2026-09-01

### Fixed

- Hardened Issue #5 GA evidence so every platform gate/run carries a
  source-bound run identifier, external node/provider metadata, successful
  exit status, test counts, and chronological timestamps; raw-log verification
  now cross-binds that provenance instead of accepting marker-only rows.

## [0.1.0-preview.55] - 2026-09-01

### Fixed

- Converted the Windows Credential Manager `CredReadW` result to `NonNull`
  before dereferencing so malformed native output fails closed.
- Removed the MCP runtime-receipt test's filesystem check-then-use pattern so
  receipt assertions do not introduce a TOCTOU race.

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

[Unreleased]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.82...HEAD
[0.1.0-preview.82]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.81...v0.1.0-preview.82
[0.1.0-preview.81]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.80...v0.1.0-preview.81
[0.1.0-preview.80]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.79...v0.1.0-preview.80
[0.1.0-preview.79]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.78...v0.1.0-preview.79
[0.1.0-preview.78]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.77...v0.1.0-preview.78
[0.1.0-preview.77]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.76...v0.1.0-preview.77
[0.1.0-preview.76]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.75...v0.1.0-preview.76
[0.1.0-preview.75]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.74...v0.1.0-preview.75
[0.1.0-preview.74]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.73...v0.1.0-preview.74
[0.1.0-preview.73]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.72...v0.1.0-preview.73
[0.1.0-preview.72]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.71...v0.1.0-preview.72
[0.1.0-preview.71]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.70...v0.1.0-preview.71
[0.1.0-preview.70]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.69...v0.1.0-preview.70
[0.1.0-preview.69]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.68...v0.1.0-preview.69
[0.1.0-preview.68]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.67...v0.1.0-preview.68
[0.1.0-preview.67]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.66...v0.1.0-preview.67
[0.1.0-preview.66]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.65...v0.1.0-preview.66
[0.1.0-preview.65]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.64...v0.1.0-preview.65
[0.1.0-preview.64]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.63...v0.1.0-preview.64
[0.1.0-preview.63]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.62...v0.1.0-preview.63
[0.1.0-preview.62]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.61...v0.1.0-preview.62
[0.1.0-preview.61]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.60...v0.1.0-preview.61
[0.1.0-preview.60]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.59...v0.1.0-preview.60
[0.1.0-preview.59]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.58...v0.1.0-preview.59
[0.1.0-preview.58]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.57...v0.1.0-preview.58
[0.1.0-preview.57]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.56...v0.1.0-preview.57
[0.1.0-preview.56]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.55...v0.1.0-preview.56
[0.1.0-preview.55]: https://github.com/TypeThe0ry/ClusterYourCodex/compare/v0.1.0-preview.54...v0.1.0-preview.55
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
