# Compatibility and security boundary

## Preview matrix

| Component | Platform/architecture | Current state |
|---|---|---|
| Controller + desktop | Windows x64 | Implemented/CI packaged prerelease; preview.73 passed clean Windows 11 ARM64 x64-emulation profile acceptance for standard/admin × ASCII/non-ASCII; preview.74 carries the selector-discovery/exit-count guard; native Windows x64 clean-profile and live controller/worker acceptance pending |
| Controller + CLI portable | Linux x64 | Developer artifact |
| Managed worker | Windows x64 | Implemented/CI for trusted jobs; live two-machine/auth acceptance pending |
| Managed worker | Linux x64 | Implemented/CI for trusted jobs; live two-machine/auth acceptance pending |
| Managed worker kit | Linux aarch64 | Built/cross-validated; hardware acceptance tracked |
| Controller/CLI/worker portable | macOS x64/arm64 | Experimental native archive; trusted process-group backend implemented, package activation runtime-gated |
| Signed exact-five Worker Kit | macOS x64/arm64 | Packaged; lifecycle validation only, LaunchAgent/live readiness false |
| Managed execution | macOS x64/arm64 | Fail-closed until LaunchAgent lifecycle acceptance; hostile tier remains unavailable |

The exact matrix in each published archive's `platform-status.json` is
authoritative for that asset.

## Managed Worker Kit contract

The Windows, Linux, and macOS Worker Kit installers consume the same signed
`cyc.dev/worker-kit/v1` envelope. Before touching an install root, data root,
workspace, or service definition, each platform requires the exact five normal
files (`cyc-worker`/`cyc-worker.exe`, its lifecycle script, `worker-kit.json`,
`worker-kit.sig`, and `SHA256SUMS`), the target-specific product/OS/architecture,
and the ordered worker/lifecycle entries in `manifest.files`. Each manifest
entry is checked against the local payload's size and SHA-256; the detached
signature and all four checksum entries are checked separately. The Linux
systemd, macOS LaunchAgent, and Windows Scheduled Task layers therefore share
one fail-closed payload contract even though their service activation and
process-group cleanup remain native to each operating system.

The repository Worker Kit test mutates a signed fixture's product identity and
re-signs it, then asserts that Linux rejects the contract-invalid kit before
creating any state. This is a local static/lifecycle regression check, not
evidence of a live Linux, macOS, or Windows clean-host run. macOS LaunchAgent
activation and Windows clean-VM evidence remain external acceptance gates.

## Controller topology

The controller runs with the Codex execution session. A remote Mac can control
a Codex session hosted on Windows without becoming the controller. Workers
connect to that Windows controller.

## Workload trust

Current workers execute native steps as the worker account. Windows Job Objects,
Linux process/descendant tracking, and the macOS native process-group probe
provide trusted-job lifecycle cleanup; they do not
create a multi-tenant hostile-workload boundary. A same-account job may access
resources available to that account. Submit only repositories and commands you
trust until opt-in isolated execution is released and proven.

The internal Linux dedicated-identity/cgroup-v2 mechanism has one native P1
mechanism test, but independent review identified additional escape, identity,
resource, and reconciliation proofs required before it can be enabled. The
preview therefore fails every configured hostile backend closed and publishes
no hostile scheduling capability. A Windows hostile-workload external guard is
not implemented; the native process-group backends are trusted-job lifecycle
cleanup, not hostile-workload guards.

## Authentication

- Controller/MCP: native loopback token boundary; no bearer token in renderer
  or MCP tool inputs.
- Worker channel: controller identity, enrollment/pairing, and TLS.
- SSH onboarding: strict host-key verification before password, native-agent,
  or local private-key authentication. Accepted remembered passwords use the
  Windows native credential vault. Private-key passphrases remain transient;
  the durable journal stores only a redacted, revalidated key-path policy.
- The three SSH authentication paths are implementation/fixture/CI verified,
  not yet live-server accepted across the declared Windows/Linux matrix.
- Non-Windows controller vault support remains tracked work; the supported
  preview controller is Windows.

## Release channels

- `preview`, `alpha`, `beta`, `rc`: GitHub prereleases, never stable claims.
- stable SemVer: blocked until production signing, full dependency/payload SBOM
  and notices, independent attestation verification, supported upgrade,
  Windows 11 profile acceptance, live two-worker E2E, governance, and all
  declared-scope issue gates pass. The prerelease release-asset SBOM and tagged
  provenance do not satisfy those broader GA gates.

The preview.73 hosted Windows 11 ARM64 x64-emulation matrix is valid
prerelease evidence (standard/admin × ASCII/non-ASCII, all four cases passed).
The next preview.74 adds a native-selector discovery and positive test-count
guard; its tagged workflow must pass before it becomes release evidence. Neither
hosted matrix replaces the independent externally retained clean-VM evidence
required by the stable GA manifest.

Native Issue #5 evidence producers should invoke
`scripts/Test-Issue5Selector.py` on the matching Linux, Windows, or macOS host.
The guard performs `cargo test --list`, rejects missing or duplicate positive
selectors, executes the exact locked selector, and requires a parsed summary
with at least one passed test and zero failures. A Cargo exit code of zero with
`running 0 tests` is rejected and must never be promoted into a GA evidence row.

### GA evidence manifest contract

Stable publication requires more than closed GitHub issues. The externally
captured `cyc.dev/ga-evidence/v1` manifest must include source-bound,
externally retained `issue2`, `issue3`, and `issue5` records. Every record needs
`status: "passed"`, the reviewed `sourceCommit`, non-empty `provider`,
`hostType`, and `evidenceId`, plus a `rawLog` object containing an absolute
HTTPS `url` and a 64-character `sha256`. Providers and host types identifying
GitHub Actions or hosted runners are not accepted.

Each `evidenceId` is a bounded portable filename component (letters, digits,
`.`, `_`, and `-` only); path separators and traversal syntax are rejected
before a raw-log path is constructed.

Each `rawLog` must additionally bind the command and external node to
ISO-8601 start/end times, `exitCode: 0`, integer passed/failed/ignored test
counts, and `cleanup: true`. The counts are bounded to `0..1,000,000,000`,
`tests.passed` must be greater than zero for Issues #2 and #3, and
`tests.failed` must be zero. The GA workflow downloads each URL with
`scripts/Test-GARawLogs.ps1`, rejects redirects and oversized responses,
recomputes the SHA-256 over the retained bytes, and parses the retained file as
one non-empty JSON object using `cyc.dev/ga-raw-log/v1`. That content must be
`status: "passed"`, repeat the reviewed `sourceCommit`, `issue`, and
`evidenceId`, and cross-bind the normalized command, `node` (or the compatible
`host` alias), timestamps, integer `exitCode`, all three test counts, and
`cleanup` to the manifest descriptor. The downloader records the parsed
content with `contentVerified: true`; the readiness gate parses the downloaded
file again and checks it against that recorded content, so an arbitrary,
empty, fractional, oversized, or relabelled log cannot satisfy the digest
check alone.

Issue #5 is validated as a platform matrix rather than as nine independent
booleans. Its `rawLog` must enumerate Linux, Windows, and macOS exactly once
under `platforms`, and its `markers` array must retain every source-bound
gate marker. The issue's `gates` map contains structured evidence objects:
platform-specific gates bind one platform, exact test selector, exact locked
`cyc-worker` command, and `rawLogMarkers`; matrix gates bind all three
platforms, one nested run per platform, and each run's `rawLogMarkers`. Every
gate/run evidence object also binds a bounded `runId` and `node`, external
`provider` and `hostType`, `status: "passed"`, integer `exitCode: 0`, positive
`tests.passed`, zero `tests.failed`, non-negative integer `tests.ignored` (all
three counts bounded to `0..1,000,000,000`), and chronological ISO-8601
`startedAt`/`endedAt` instants. Each nested run binds
an external execution row to its exact test selector and locked command; the
raw-log verifier cross-binds the provenance fields as well as the markers. For
the downloaded Issue #5 JSON envelope, `markers` is also required to be a
unique non-empty string array retaining every manifest marker; plain text
marker hits outside a parsed, source-bound envelope do not count.
The compatibility aliases `selector` and `markers` are accepted only when
they exactly match canonical `testSelector` and `rawLogMarkers` values; any
conflicting duplicate field fails closed.
Both marker spellings must be JSON arrays of non-empty native strings; marker
arrays are unique using ordinal, case-sensitive comparison. Scalars, numeric or
boolean entries, blank values, and duplicate entries are rejected before any
marker is normalized.
Each matrix gate also requires unique `runId` values and keeps every run ID
bound to one platform across the complete Issue #5 record. Provenance
identifiers and retained marker entries remain JSON strings; duplicates,
blank markers, and numeric/boolean/null substitutions fail closed.
The Linux row uses
`isolation::tests::linux_live_dedicated_identity_credential_and_residual_reconciliation`
with `--ignored --exact --nocapture`; the Windows row uses the positive native
containment selector
`isolation::tests::windows_native_containment_job_object_and_guard`; and the
macOS row uses the positive live reconciliation selector
`isolation::tests::macos_live_external_reconciliation`. The
`*_fail_closed_at_every_runtime_gate` Windows/macOS tests are regression
coverage for unavailable backends only; they are explicitly rejected as GA
completion evidence and cannot satisfy the native containment gates.
All rows use `--manifest-path`, `-p cyc-worker`, `--lib`, and `--locked`, and
must end in their exact selector. The marker format is
`CYC-GA-ISSUE5|platform=<platform>|selector=<selector>|commandSha256=<digest>|gate=<gate>|status=passed`;
the digest covers the normalized command. A restart row must also include a
platform-native residual marker: Linux uses `residual_empty`,
`residualCgroupVerified=1`, or `residualIdentityProcessesVerified=1`; Windows
requires `residualJobObjectVerified=1`; and macOS requires
`residualExternalReconciliationVerified=1`. A generic `residual_empty` marker
does not satisfy the Windows or macOS row. The downloader searches for every
marker in the downloaded log and records `markersVerified: true` plus
`gateEvidence`; the readiness gate cross-binds the verified platform, selector,
command, and marker sets. A generic Linux `cargo test --workspace --locked`
run therefore cannot satisfy the Windows, macOS, or restart rows even when an
older manifest supplies every Issue #5 gate as `true`.

The platform-native marker contract is closed as well. The Windows single-host
gates must retain `windowsExecutionIdentityVerified=1`,
`windowsJobObjectVerified=1`, and `windowsProtectedExternalGuardVerified=1`;
the macOS single-host gate must retain
`macosExternalReconciliationVerified=1`. On every three-platform matrix row,
`jobsCannotAlterGuardState` must retain
`linuxGuardTamperRejected=1`, `windowsGuardTamperRejected=1`, and
`macosGuardTamperRejected=1` on the corresponding runs, while
`jobsCannotReadWorkerCredentials` must retain
`linuxWorkerCredentialIsolationVerified=1`,
`windowsWorkerCredentialIsolationVerified=1`, and
`macosWorkerCredentialIsolationVerified=1`. The aggregate matrix marker set
must retain each run marker. Restart residual proof remains platform-specific:
Linux accepts its cgroup/identity residual markers, Windows requires
`residualJobObjectVerified=1`, and macOS requires
`residualExternalReconciliationVerified=1`.

Issue #2 and Issue #3 retain their boolean `gates` maps, and every required
entry must be `true`; the map is a closed set, so unknown or missing gate keys
fail validation. Issue #5 uses the structured gate matrix described above.
Issue #2 covers the Tauri desktop host/tray, native renderer proxy,
per-user tasks, SID-scoped data ACL, bundled MCP/marketplace payload,
transactional install/repair/upgrade/rollback/uninstall, clean Windows 11 VM,
live Windows controller/worker round trip, and production Authenticode setup
and helper, signed N-1 to N upgrade, interrupted-upgrade rollback, downgrade
policy, and absence of an open unwaived P0/P1 blocker. Issue #3 covers the
Linux systemd user-service package, macOS LaunchAgent package, Linux x64/macOS
x64/macOS arm64 release artifacts,
platform-native shells and process groups, cross-platform path/ACL tests, and
a live macOS run plus the live Linux controller/worker round trip and
macOS Developer ID signing/notarization. Issue #5 covers Linux dedicated identity plus cgroup-v2
reconciliation, Windows isolated identity plus Job Object and protected
external guard, macOS external reconciliation, denial of guard-state and
worker-credential access, and restart-time residual-process reconciliation.
The exact gate keys are enforced by `scripts/Test-GAReadiness.ps1` and are
rechecked by `.github/workflows/ga.yml` before the stable publisher runs; a
closed issue without those records and true gates remains blocked. The live
issue snapshot also requires the canonical title, `state_reason=completed`,
and the repository issue URL, so a duplicate or "not planned" closure cannot
satisfy GA.

The stable publisher additionally compares the requested attestation signer
repository and workflow against the protected `production` environment values
`CYC_GA_TRUSTED_BUILDER_REPO`, `CYC_GA_TRUSTED_BUILDER_WORKFLOW`, and
`CYC_GA_TRUSTED_BUILDER_DIGEST`. Dispatch signer values must match these
protected policy values exactly, and the publisher passes the pinned digest to
`gh attestation verify`; the prerelease publisher cannot nominate itself as the
stable builder.
