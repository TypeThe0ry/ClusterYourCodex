# Packaging and developer-preview artifacts

ClusterYourCodex is Windows-first but keeps one cross-platform product model.
The self-contained Windows developer-preview payload is:

```text
ClusterYourCodex.exe   Tauri 2 GUI
cyc-controller.exe    per-user loopback controller
cyc-worker.exe        optional per-user managed worker
cyc.exe               diagnostics, bootstrap, and recovery CLI
integrations/          installer-owned Codex marketplace and plugin
  codex-marketplace/plugins/cluster-your-codex/mcp/runtime/node.exe
                       bundled private runtime for the Codex MCP bridge
  codex/cluster-agents-block.md
                       public managed global AGENTS.md block template
```

The React application is the shared renderer. Tauri is the intended native
host on Windows, Linux, and macOS; the current self-contained native GUI archive
is Windows-only. The host proxies controller requests so the renderer never
receives the long-lived bearer token. The renderer can send only a typed
`method/path/body` envelope. The native host owns the fixed
`http://127.0.0.1:47831` origin, reads the token from the fixed platform data
root, injects only its own headers, uses no proxy or redirects, and exposes an
explicit route allowlist.

## Windows lifecycle

The current developer preview installs per-user from a self-contained bootstrap
ZIP under:

```text
%LOCALAPPDATA%\Programs\ClusterYourCodex
```

Mutable state remains under:

```text
%LOCALAPPDATA%\ClusterYourCodex
```

Controller and optional worker use per-user Scheduled Tasks with
`InteractiveToken`, least privilege, `IgnoreNew`, and bounded restart policy.
They do not depend on the GUI process remaining open. A SYSTEM service is a
later opt-in for dedicated machines, not the default.

`packaging/windows/Invoke-ClusterYourCodexLifecycle.ps1` is the unelevated
coordinator. NSIS uses `RequestExecutionLevel user`, the portable wrapper never
relaunches itself, and Apps & Features starts an unelevated uninstaller. The
coordinator captures the initiating SID, profile, and `LOCALAPPDATA`; every
file, HKCU entry, Codex mutation, and per-user Scheduled Task remains bound to
that identity even when UAC credentials belong to a different administrator.
Only `Invoke-ClusterYourCodexFirewall.ps1` is elevated, exactly once per fresh
lifecycle attempt.

The helper accepts a single manifest-hashed request and no command channel. It
derives the rule name from the initiating SID and permits only one inbound,
Allow, enabled, Private-profile, TCP, `LocalSubnet` rule for the exact
`cyc-controller.exe` path and bounded port. It rejects a changed SID/profile,
helper/request tamper, replay mismatch, rule-name collision, program mismatch,
or malformed scope. It durably snapshots the prior owned rule, applies and
verifies the desired state, and stays alive while the unelevated core runs. A
core failure/cancellation/timeout signals rollback; success signals a final
program-hash and rule verification. The manifest records the firewall as
`pending` until a transaction-bound helper receipt is committed. Response-loss
replay and commit are idempotent; ambiguous state stays retryable rather than
being reported as installed.

`packaging/windows/bootstrap.ps1` is the per-user core. It rejects a managed
listener lifecycle that was not marked `-DeferFirewall`, and install/repair/
uninstall core functions contain no firewall mutation. It stops only product
tasks and processes whose executable path is inside the owned install root
before replacing binaries. Each upgrade snapshots the prior owned files and
task XML under a protected transaction directory; a failed copy, task
registration, or start restores both. The controller task receives explicit
loopback/database/token-*file* arguments. Secret token content is never placed
in task arguments, environment variables, the manifest, or logs.

The installer restricts the full data directory to the current user SID and
SYSTEM before the controller creates its database or token. The controller
then independently requires the database, SQLite WAL/SHM/journal sidecars, and
the sibling `jobs` object root to remain non-reparse state with that exact
private ownership/ACL contract. Existing weak or prepositioned state fails
closed; new files are created only after the parent is protected and are
post-hardened before startup completes. ACL failure aborts installation.
Tokens never appear in arguments, environment variables, installer state,
diagnostics, or logs.

The developer preview is still code-unsigned. Hash-binding and the narrow
surface constrain behavior but do not authenticate a user-writable PowerShell
helper to an over-the-shoulder administrator. GA must Authenticode-sign both
Setup and the helper; the runtime `-RequirePackageSignature` path verifies both
before the helper mutates the firewall. Until that gate is satisfied, this is a
truthfully labelled preview rather than a signed cross-user elevation claim.

### Windows profile and path acceptance

The clean Windows acceptance job also runs
`packaging/windows/Test-WindowsProfileMatrix.ps1`. It creates disposable local
accounts for `standard-ascii`, `administrator-ascii`, `standard-non-ascii`, and
`administrator-non-ascii`, launches the child harness with
`Start-Process -Credential -LoadUserProfile`, and records the effective SID,
administrator membership, `USERPROFILE`, `LOCALAPPDATA`, and `TEMP`. Each case
runs the complete Install → Repair (corrupted CLI) → Uninstall lifecycle from a
private staged package copy. Credentials are held only in-memory as a
`PSCredential`; they are never placed in command arguments, files, or logs.
The controller removes the disposable account and its profile by SID after the
case, while retaining a job-owned JSON receipt and logs for CI diagnostics.
For UAC-filtered or ARM64/x64-emulated logon tokens whose
`WindowsIdentity.Groups` projection omits the Administrators SID, the child
cross-checks the local SAM by the well-known Administrators SID and records the
membership source and observed SIDs in its receipt; a failed SAM query remains
fail-closed for administrator cases.

A disposable profile launched by a non-interactive CI session cannot obtain the
Winlogon token required to register or start a production `InteractiveToken`
task. The profile-matrix child therefore opts into the explicit
`parent-elevated-registration-v1` test gate (which also requires the explicit
`-ProfileMatrixTaskHelperMode` switch). Bootstrap keeps the production
`Interactive` principal in its manifest, emits a durable request containing the
exact disposable-profile action, and waits for the elevated matrix controller
to validate and register the task. The controller records the request,
response, observed principal, and cleanup in job-owned evidence, and the task
is deliberately never started. Install, Repair, and Uninstall still run in the
child profile; the normal fresh-deployment, Setup, Repair, and user-install
paths continue to register and start `InteractiveToken` tasks directly. S4U is
kept as an unused, explicitly guarded compatibility value and is never inferred
from a runner label, job name, or non-interactive host.

The profile/path matrix also treats compatibility junctions as an explicit
allow-list, not as generic reparse points. On Windows PowerShell 5.1, where
`LinkType`/`Target` projections may be absent, it queries `fsutil reparsepoint
query`, requires the native mount-point tag `0xA0000003`, and requires every
reported target to normalize to the exact expected in-profile destination.
Device, volume, `GLOBALROOT`, UNC, ambiguous, and unknown-tag targets fail
closed before cleanup or recursive traversal.

The repository contract can be checked locally without creating accounts:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\scripts\Test-WindowsAuthenticodeBoundary.ps1
```

For a signed GA artifact, the same gate accepts explicit paths and requires a
valid chain and timestamp without exposing certificate material in logs:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\scripts\Test-WindowsAuthenticodeBoundary.ps1 `
  -Path .\ClusterYourCodex-Setup.exe,.\Invoke-ClusterYourCodexFirewall.ps1 `
  -RequireValid -RequireTimestamp
```

## Linux and macOS preview posture

- The Linux x64 preview is a portable native archive containing
  `cyc-controller`, `cyc-worker`, and `cyc`. It does not install a systemd unit
  or create XDG state automatically.
- Separately, the Ed25519 publisher-signed and integrity-bound Linux managed Worker Kit includes
  `install-worker.sh`. Non-root `--scope auto` uses a user unit only after
  linger and the user manager bus pass a preflight. A missing user manager or
  unavailable linger permission fails before worker/config/manifest/unit
  mutation with exit `78` and
  `[CYC-LINUX-USER-SYSTEMD-UNAVAILABLE]`; root `--scope auto` uses system scope.
  A linger setting enabled by the failed preflight is rolled back when the
  subsequent user-bus probe cannot connect.
- Linux performs the same exact-five-file and manifest payload contract checks
  as the Windows and macOS installers before preinstall: the signed manifest
  must identify `ClusterYourCodex Managed Worker`, the host's exact
  `linux-x86_64` or `linux-aarch64` target, and the ordered `cyc-worker` plus
  `install-worker.sh` worker/lifecycle entries with matching size and SHA-256.
  A valid publisher signature over a contract-invalid manifest is rejected
  before any worker, config, manifest, or systemd unit mutation.
- Linux's opt-in dedicated-execution-identity/cgroup-v2 hostile-isolation
  mechanism passed an internal native P1 test. Independent review still
  requires additional escape, identity, resource, and reconciliation proofs,
  so release binaries reject configured hostile execution, report it unready,
  and publish no hostile scheduling capability. The ordinary worker lifecycle
  remains a trusted single-user executor, not a hostile or multi-tenant sandbox.
- The macOS x64 and arm64 portable previews contain `cyc-controller`,
  `cyc-worker`, and `cyc`. Release packaging also produces publisher-signed,
  exact-five-file macOS Worker Kits containing `cyc-worker`,
  `install-worker.sh`, `worker-kit.json`, `worker-kit.sig`, and `SHA256SUMS`.
  The lifecycle script uses the macOS LaunchAgent/Application Support/Logs
  contract, but managed execution remains `runtimeGated=true`,
  `containmentReady=false`, and `liveReady=false` until a containment backend
  and native live acceptance prove complete process-tree termination.
- A future standalone Linux GUI installer may reuse the Worker Kit's systemd
  lifecycle and XDG state contract. A future standalone macOS GUI installer may
  reuse the now-packaged Worker Kit lifecycle; the lifecycle itself does not
  make managed execution ready.
- The same controller protocol, data ownership, rollback, and evidence rules
  remain the cross-platform contract; an archive does not claim that a future
  service lifecycle is already implemented.

## Codex integration

The installer owns a dedicated local marketplace and installs the plugin from
there. The Windows payload contract is a complete marketplace root at:

```text
payload/integrations/codex-marketplace/
  .agents/plugins/marketplace.json
  plugins/cluster-your-codex/**
payload/integrations/codex/cluster-agents-block.md
```

Before any Codex CLI side effect, both bootstrap and the desktop verifier bind
the installed `integrations/codex-marketplace/**` tree to
`install-manifest.json`. The catalog is exact: normalized relative paths must
be unique, no file or ancestor may be a symlink/reparse point, and missing,
extra, length-mismatched, or SHA-256-mismatched entries fail closed. The
canonical `cyc.dev/file-catalog/v1` digest is recorded separately for the full
build and Codex payload catalogs.

When the Codex CLI is available, bootstrap runs the exact canonical CLI path
selected and validated by the desktop native layer with
`plugin marketplace add <marketplace-root>` and
`plugin add cluster-your-codex@clusteryourcodex`, then requires
`codex plugin list --json` to report exactly one matching plugin whose
`installed` and `enabled` fields are JSON booleans set to true, whose version
matches the installed `.codex-plugin/plugin.json`, and whose local source path
matches this installation's owned marketplace. Registration is best effort so
an unavailable or older Codex CLI does not fail the core install, but an
unverified plugin never causes an AGENTS.md
block to be written. The manifest records the inactive state, and a later GUI
Repair repeats registration and installs the block only after activation is
verified. Uninstall reverses only registrations recorded as owned. Bootstrap
then appends or replaces exactly one
`CLUSTERYOURCODEX-MANAGED` block in the selected global
`%CODEX_HOME%\AGENTS.md` (default `%USERPROFILE%\.codex\AGENTS.md`) so later
Codex sessions know they can dispatch suitable work through the plugin. It
preserves all bytes outside that range, rejects duplicate/nested/half-present
markers, and serializes product lifecycle operations with a bounded named-mutex
wait and one action deadline. Before
the first AGENTS.md write it durably publishes a prepared journal with bounded
before/after images, original existence, and before/after/template/block/prefix
digests. Restart reconciliation finalizes a manifest-owned after-image or
reverses only the proven owned range; concurrent edits outside the range are
retained, while malformed or ambiguous state fails closed with the transaction
left for diagnosis. Repair is idempotent. Uninstall uses the same compare-and-
swap and range-ownership rules; an originally absent block-only file is deleted
only while it still matches the expected image, and unrelated user edits remain.
Personal marketplaces and other plugins are never modified. The MCP package
contains a compiled TypeScript entry and production dependencies. The Windows
self-contained preview also
bundles a private Node runtime whose copied bytes are hash-recorded in the
preview manifest and `SHA256SUMS`; the standalone integration preview instead
requires Node.js 20 or newer on `PATH`. A native MCP binary can replace it later
without changing tool contracts.

The desktop launches `bootstrap.ps1` only with the Windows PowerShell resolved
from `GetSystemDirectoryW`; it does not trust `PATH` or `SystemRoot`. Every
ancestor is checked for reparse points and the verified bootstrap file handle
remains open without write/delete sharing from SHA-256 verification until the
child exits, closing the hash-to-execution swap window.

After the GUI has completed plugin registration and its plugin self-test, it
can commit or repair only the Codex-facing receipt without elevation:

```powershell
"$SystemPowerShell" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File "$InstallRoot\installer\bootstrap.ps1" `
  -Action IntegrateCodex `
  -InstallRoot "$InstallRoot" `
  -DataRoot "$DataRoot" `
  -CodexHome "$CodexHome" `
  -CodexCliPath "$ExactCanonicalCodexCli" `
  -ExpectedInstallManifestSha256 "$InstallManifestSha256" `
  -MutexTimeoutSeconds 10 `
  -ActionTimeoutSeconds 60
```

`IntegrateCodex` acquires the same global lifecycle mutex, reconciles durable
AGENTS.md journals, revalidates the complete marketplace tree against the
installer manifest, strictly verifies the already-active plugin list using the
same exact CLI path, applies the additive AGENTS.md transaction, and atomically
records the new ownership receipt in `install-manifest.json`. It never registers or removes
a plugin and never changes the controller, service, Scheduled Tasks, firewall,
TLS identity, or worker state. Success exits zero and writes exactly one compact
JSON object (at most 4096 UTF-8 bytes) to stdout:

```json
{"schemaVersion":"cyc.dev/codex-integration-receipt/v1","status":"installed","pluginId":"cluster-your-codex@clusteryourcodex","pluginVersion":"<product-version>","agentsBlockSha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","payloadCatalogSha256":"1111111111111111111111111111111111111111111111111111111111111111","buildCatalogSha256":"2222222222222222222222222222222222222222222222222222222222222222","installManifestSha256":"3333333333333333333333333333333333333333333333333333333333333333","agentsFileSha256":"4444444444444444444444444444444444444444444444444444444444444444","agentsExternalSha256":"5555555555555555555555555555555555555555555555555555555555555555","agentsOwnedRangeSha256":"6666666666666666666666666666666666666666666666666666666666666666"}
```

`<product-version>` above means the exact value from the repository `VERSION`
and installed manifest; it is not a literal runtime value.

`status` is `installed`, `repaired`, or `unchanged`. Failure exits nonzero,
keeps stdout empty, writes one bounded error line to stderr, and performs no
AGENTS.md write when plugin or manifest verification fails. A crash after the
AGENTS.md after-image but before manifest publication is range-rolled back on
restart; a manifest-owned after-image is finalized.

Desktop status treats installation as healthy only when the payload/build
catalogs and the manifest-owned global AGENTS transaction all verify read-only:
the configured path and template, exactly one managed block, prefix and owned
range, full-file digest, and the preserved external-byte digest must match.
`agentsIntegrated` plus the catalog/build digests are exposed in native status;
Connected and Full Run eligibility require that gate, so missing or drifted
AGENTS evidence is never displayed as Done. An already-exact plugin and
unchanged AGENTS file produces `status=unchanged`, `changed=false`, and no
restart marker. A restart marker is written only when the installed
marketplace/plugin/runtime build actually changes.

An active, non-self-test Codex MCP runtime starts a five-second unreferenced,
single-flight controller verification loop after initialize plus `tools/list`.
Only a successful authenticated `fleet` response advances
`controllerVerifiedAt`; failed checks leave the prior proof intact and process
cleanup stops the timer. Desktop-owned self-test sessions never publish or
overwrite the active-runtime receipt.

Install, upgrade, repair, and uninstall record only non-secret owned resources
and hashes. Uninstall removes those exact resources and preserves user data by
default. `-PurgeData` is the explicit destructive option. The presence of an
upgrade transaction path is not supported `N-1 -> N` evidence; cross-version
upgrade, interrupted rollback, and downgrade policy remain acceptance gates.

The release workflow builds and publishes a code-unsigned developer-preview
`ClusterYourCodex-Setup.exe` with NSIS from the exact manifest-bound Windows
payload. It is a one-click preview installer, not a signed GA release. GA still
requires Authenticode signing of Setup and the firewall-only helper, plus
post-sign signature and payload verification.
The absence of Authenticode does not make managed Worker Kits unsigned: every
Windows/Linux/macOS Worker Kit has a detached Ed25519 publisher signature over
its canonical manifest. Controller/release packaging pins and verifies the
repository public key; the lifecycle binds the exact bytes through SHA-256, the
exact five-file set, the four-entry `SHA256SUMS`, signature envelope, key id,
and manifest digest. The remote shell does not independently implement
Ed25519. A signed macOS kit remains runtime-gated; payload authenticity is not
containment or live-execution evidence.

## Published developer-preview set

The release workflow publishes the following preview assets:

| Artifact suffix | Contents | Current use |
| --- | --- | --- |
| `windows-x64-preview.zip` | `cyc-controller.exe`, `cyc-worker.exe`, `cyc.exe` | Portable native controller/worker/CLI preview |
| `linux-x64-preview.tar.gz` | `cyc-controller`, `cyc-worker`, `cyc` | Portable native controller/worker/CLI preview |
| `macos-x64-preview.tar.gz` | `cyc-controller`, `cyc-worker`, `cyc`, signed Worker Kit | Native Intel portable preview; managed execution runtime-gated |
| `macos-arm64-preview.tar.gz` | `cyc-controller`, `cyc-worker`, `cyc`, signed Worker Kit | Native Apple Silicon portable preview; managed execution runtime-gated |
| `worker-kit-macos-x64-preview.tar.gz` | Exact-five signed macOS x64 Worker Kit | Lifecycle/package validation only; containment/live readiness false |
| `worker-kit-macos-arm64-preview.tar.gz` | Exact-five signed macOS arm64 Worker Kit | Lifecycle/package validation only; containment/live readiness false |
| `integration-preview.zip` | Compiled renderer and Codex marketplace/plugin | Integration assets only; no native application or installer |
| `windows-x64-self-contained-preview.zip` | GUI, controller, worker, CLI, bootstrap, Codex integration, private Node runtime, five managed Worker Kits | Windows-first extracted bootstrap preview |
| `ClusterYourCodex-Setup.exe` | NSIS wrapper embedding the exact self-contained Windows preview payload | Unsigned one-click developer-preview Setup; GA signing gate remains open |

Every portable platform/integration archive, excluding the standalone Worker
Kit tarballs, contains `PREVIEW-NOTICE.md`, `platform-status.json`, and
`release-manifest.json`. Every primary asset in the table has an adjacent
SHA-256 sidecar. The release-index job downloads all producer artifacts,
requires and verifies exactly nine producer sidecars, rejects missing or
duplicate expected assets, and generates a CycloneDX 1.6 release-asset SBOM
with its own sidecar, a combined `SHA256SUMS`, and `release-index.json` plus its
sidecar. A tagged public prerelease depends on that index job and publishes only
its verified assembled output; every tagged preview remains `prerelease: true`
until the separate protected GA workflow approves a stable release.

All native Rust release jobs run full-workspace `cargo fmt`, `cargo clippy`, and
`cargo test` before their release build. Windows, Linux, macOS Intel, and macOS
Apple Silicon binaries are built on native runners. Staging checks the native
binary format and architecture, verifies Unix executable bits, and runs native
`--version` and `--help` smoke checks for every binary that will be shipped.
The self-contained Windows job also checks the GUI PE architecture and reruns
the Windows bootstrap lifecycle tests before creating its archive.

These remain code-unsigned developer previews. Tagged prerelease runs generate
a CycloneDX 1.6 **release-asset inventory** SBOM and use GitHub artifact build
provenance for the immutable payload assets staged under `provenance-subjects/*`;
the release index records the attestation id, URL, bundle digest, subject count,
and subject digests, and flips to `unattested=false` only after complete
attestation evidence exists. The index and checksum files are integrity metadata
written after the payload attestation. Manual `workflow_dispatch` artifacts
remain explicitly `unattested=true`. These
controls do not claim Authenticode, Apple signing/notarization, a full
dependency/payload SBOM, third-party notices, independent post-download
provenance verification, automatic update support, or stable-release support.
Worker-kit publisher signatures authenticate the worker payload manifest, but
are not Authenticode or a hostile-execution/containment claim.
Windows/Linux managed workers execute trusted jobs as the worker OS
account and are not hostile-workload or multi-tenant sandboxes. See
[`managed-worker-protocol.md`](managed-worker-protocol.md) for the execution and
containment contract.
