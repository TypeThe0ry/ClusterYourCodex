# Windows packaging

`Invoke-ClusterYourCodexLifecycle.ps1` is the unelevated current-user
coordinator used by NSIS and portable previews. `bootstrap.ps1` is its
per-user core; `Invoke-ClusterYourCodexFirewall.ps1` is the only elevated
surface. None accepts a raw
controller token and never places a token in argv, environment variables,
task definitions, manifests, or logs.

## Payload layout

```text
payload/
  ClusterYourCodex.exe
  cyc-controller.exe
  cyc-worker.exe                 optional unless -EnableWorker is used
  cyc.exe
  installer/
    bootstrap.ps1
    Invoke-ClusterYourCodexLifecycle.ps1
    Invoke-ClusterYourCodexFirewall.ps1
    Uninstall-ClusterYourCodex.ps1
  worker-kits/
    windows-x86_64/              SSH bootstrap kit for Windows workers
    linux-x86_64/                SSH bootstrap kit for Linux x64 workers
    linux-aarch64/               SSH bootstrap kit for Linux arm64 workers
  integrations/codex-marketplace/
    .agents/plugins/marketplace.json
    plugins/cluster-your-codex/  complete plugin directory
      mcp/runtime/node.exe       bundled private MCP runtime
      mcp/runtime/LICENSE.node.txt
  integrations/codex/
    cluster-agents-block.md      public global AGENTS.md managed block
```

## Commands

```powershell
# Show a deterministic plan without changing the machine.
.\bootstrap.ps1 -Action Install -PlanOnly

# Install or idempotently repair through the split-elevation coordinator.
.\Invoke-ClusterYourCodexLifecycle.ps1 -Action Install `
  -BundleRoot .\payload -PackageRoot . `
  -PackageManifest .\preview-manifest.json
.\Invoke-ClusterYourCodexLifecycle.ps1 -Action Repair `
  -BundleRoot .\payload -PackageRoot . `
  -PackageManifest .\preview-manifest.json

# Non-elevated GUI bridge after plugin install/self-test. This touches only the
# Codex plugin receipt, global AGENTS.md managed block, and install manifest.
.\bootstrap.ps1 -Action IntegrateCodex `
  -InstallRoot "$env:LOCALAPPDATA\Programs\ClusterYourCodex" `
  -DataRoot "$env:LOCALAPPDATA\ClusterYourCodex" `
  -CodexHome "$env:USERPROFILE\.codex"

# Remove installer-owned files and tasks while keeping the initiating HKCU and
# profile context. Only firewall removal prompts for UAC.
& "$env:LOCALAPPDATA\Programs\ClusterYourCodex\installer\Uninstall-ClusterYourCodex.ps1"

# Pure PowerShell 5.1 static and install-plan tests.
.\Test-WindowsPackaging.ps1
```

## Release staging

Build the root Rust binaries and the Tauri native host in release mode, then
create a production-only MCP deployment and assemble a repeatable,
checksum-recorded preview:

```powershell
$mcpDeploy = "$env:RUNNER_TEMP\cyc-mcp"
pnpm --filter @clusteryourcodex/codex-mcp deploy --prod `
  --config.node-linker=hoisted `
  --config.inject-workspace-packages=true `
  --frozen-lockfile `
  $mcpDeploy
if ($LASTEXITCODE -ne 0) { throw 'pnpm production deployment failed.' }
$pnpmMetadata = Join-Path $mcpDeploy 'node_modules\.pnpm'
if (Test-Path -LiteralPath $pnpmMetadata) {
  $metadataDirectory = Get-Item -LiteralPath $pnpmMetadata -Force
  if (-not $metadataDirectory.PSIsContainer -or
      ($metadataDirectory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Unexpected pnpm metadata directory in $pnpmMetadata"
  }
  $metadataEntries = @(Get-ChildItem -LiteralPath $pnpmMetadata -Force)
  if ($metadataEntries.Count -ne 1 -or
      $metadataEntries[0].PSIsContainer -or
      $metadataEntries[0].Name -cne 'lock.yaml' -or
      ($metadataEntries[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Unexpected pnpm metadata layout in $pnpmMetadata"
  }
  Remove-Item -LiteralPath $metadataEntries[0].FullName -Force
  Remove-Item -LiteralPath $metadataDirectory.FullName -Force
}
if (Test-Path -LiteralPath $pnpmMetadata) {
  throw "Failed to remove pnpm metadata directory: $pnpmMetadata"
}
node .\packaging\windows\Test-McpDeployment.mjs $mcpDeploy
if ($LASTEXITCODE -ne 0) { throw 'Deployed MCP runtime smoke test failed.' }
$node = (Get-Command node -CommandType Application).Source
$nodeLicense = Join-Path (Split-Path -Parent $node) 'LICENSE'
if (-not (Test-Path -LiteralPath $nodeLicense)) {
  throw 'The selected Node distribution must include its matching LICENSE file.'
}
.\packaging\windows\New-PreviewPayload.ps1 `
  -McpDeployRoot "$env:RUNNER_TEMP\cyc-mcp" `
  -NodeExecutable $node `
  -NodeLicense $nodeLicense `
  -WorkerKitsRoot "$env:RUNNER_TEMP\cyc-managed-worker-kits" `
  -OutputRoot ".\artifacts\ClusterYourCodex-Windows-x64"

# Requires makensis.exe (NSIS). Embeds the exact manifest-validated preview.
.\packaging\windows\New-SetupExecutable.ps1 `
  -PackageRoot ".\artifacts\ClusterYourCodex-Windows-x64" `
  -OutputPath ".\artifacts\ClusterYourCodex-Setup.exe"
```

The output root contains the coordinator, firewall-only helper,
`bootstrap.ps1`, `SHA256SUMS`, a non-secret preview manifest, a double-click
`Install-ClusterYourCodex.cmd`, and the complete `payload/`. The wrapper resolves
its directory with `%~dp0`, remains unelevated, verifies
`preview-manifest.json`, binds the initiating SID/profile/LOCALAPPDATA, and
requests exactly one UAC prompt for the fixed firewall transaction. Per-user
files, HKCU registration, Codex integration, and Scheduled Tasks never switch
to an over-the-shoulder administrator profile. On success it launches
the installed GUI. The staged plugin
uses its bundled, license-accompanied private Node runtime rather than PATH
`node`; only the staged `.mcp.json` is rewritten. The runtime and license
hashes are recorded in `preview-manifest.json` and `SHA256SUMS`; release
staging does not fetch an unverified replacement license.

The release workflow uses pnpm 11's modern production deploy with a hoisted
dependency tree and injected workspace packages. It accepts only pnpm's
deployment metadata directory when it contains exactly one regular `lock.yaml`
file, removes that exact metadata before staging, and runs the deployed MCP
initialize and tool-list smoke test. `New-PreviewPayload.ps1` then rejects
reparse points, `.pnpm` directories, source-declared development-only packages, or
missing production dependencies before copying any preview input. When
`-WorkerKitsRoot` is supplied, staging requires all three supported worker-kit
targets, revalidates their exact file sets, manifests, lengths, and SHA-256
allowlists, requires each canonical manifest's detached Ed25519 publisher
signature envelope and pinned key id, then records their identities in
`preview-manifest.json`. Cryptographic Ed25519 verification occurs in the
controller before SSH staging; preview staging preserves the already signed
five-file kit byte-for-byte.

The ZIP and `ClusterYourCodex-Setup.exe` contain the same self-contained Windows
developer preview. Installation discovers one active private-LAN interface,
persists a versioned immutable network plan, creates or verifies the matching
non-rotating controller TLS identity, starts the loopback API plus one explicit
RFC1918/ULA managed-worker listener, adds one product-owned inbound TCP rule
restricted to the Private profile and `LocalSubnet`, installs the
GUI/CLI/Worker Kits/Codex integration, and registers a per-user uninstaller in
Windows Apps & Features. The listener never binds `0.0.0.0`, `::`, loopback,
link-local, or a public IP. The controller independently rejects those binds,
an IP-literal public origin that differs from the bind, and a public-origin
port that differs from the listener port.

The persisted `cyc.dev/windows-managed-worker-network/v1` plan records the
selected interface index, controller hostname, exact bind/public host and
port, all RFC1918/ULA addresses on that interface, and the exact certificate
SAN set. Automatic selection is deterministic: active interface with a
default gateway first, then interface metric and index; the bind prefers IPv4
and then canonical address order. The SAN set is the canonical union of IPv4
loopback, IPv6 loopback, controller hostname, public host, and every selected
private address. Readiness connects to the explicit bind while TLS authenticates
the public host.

PlanOnly, the unelevated coordinator, and the per-user core pass the same typed
plan without rediscovery. Repair reuses it exactly and rejects replacement or
malformed plan state. Identities live under
`%LOCALAPPDATA%\ClusterYourCodex\tls\managed-worker-v2`; migration from the
legacy prerelease `tls\controller.*.pem` pair creates the new versioned identity
without modifying the predecessor, so rollback can restore the old task and
files. A partial legacy or current identity fails closed. Repair preserves both
the immutable plan and versioned identity bytes. Uninstall preserves
controller/worker data unless `-PurgeData` is explicitly supplied.

The coordinator durably records `prepared -> firewallApplied -> coreApplied ->
complete`. The helper snapshots only the exact product rule, applies and
verifies it, then remains elevated until the unelevated core signals finalize
or rollback. Core failure, cancellation, or timeout restores the verified prior
rule. Its final receipt binds the transaction, request digest, initiating
SID/profile, program hash, port, and rule identity. The core manifest stays
`pending` until that receipt is committed. Matching response-loss replay is
idempotent; changed SID/profile, request/helper hash, rule collision, or receipt
fails closed.

`New-SetupExecutable.ps1` revalidates every staged length and SHA-256 before
embedding the package, emits a checksum sidecar, and reports the Authenticode
state. Developer preview executables remain explicitly code-unsigned; GA Authenticode signing
and post-sign verification remain a release gate rather than a claimed result.
That code-signing status is separate from the Worker Kit publisher signatures.
The unsigned developer preview constrains elevation through strict validation
and a package-manifest-bound helper hash, but this does not authenticate a
user-writable script to the administrator. GA must Authenticode-sign both Setup
and the narrow helper. `-RequirePackageSignature` makes the helper verify both
before mutation; that signed-helper gate is mandatory for a GA
over-the-shoulder guarantee.

The controller and worker run as least-privilege, current-user Scheduled Tasks
with `Interactive` logon, `IgnoreNew`, bounded restart, and no embedded secret.
Codex marketplace/plugin registration is best effort: a missing or older Codex
CLI does not fail the core install. The AGENTS.md integration is stricter: Setup
and Repair require `codex plugin list --json` to confirm the exact plugin is
installed and enabled, with its exact manifest version and owned local source,
before they manage one marked block in global
`%CODEX_HOME%\AGENTS.md` (or `%USERPROFILE%\.codex\AGENTS.md`). A missing or
failed registration leaves that block absent until a later successful Repair.
Before mutation, the installer durably journals the before/after images and
their file/template/block/prefix digests. Product lifecycle calls share one
named mutex; writes and deletes use compare-and-swap preconditions. Restart and
rollback reverse only the proven owned range, preserve concurrent edits outside
it, and fail closed while retaining an ambiguous transaction.
Uninstall removes only the verified owned block and preserves all other user
content; an originally absent block-only file is removed. The install manifest
records previous-file, template, block, and resulting-file SHA-256 values.

`-Action IntegrateCodex` is the machine-facing GUI completion/repair boundary.
It never invokes controller, worker, TLS, firewall, service, or Scheduled Task
lifecycle code. On success it exits zero and stdout is exactly one compact JSON
object of at most 4096 UTF-8 bytes:

```json
{"schemaVersion":"cyc.dev/codex-integration-receipt/v1","status":"unchanged","pluginId":"cluster-your-codex@clusteryourcodex","pluginVersion":"0.1.0-preview.6","agentsBlockSha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}
```

`status` is `installed`, `repaired`, or `unchanged`. Failure exits nonzero,
leaves stdout empty, and emits one bounded stderr line. Plugin-list, source,
version, or installed-payload verification failures happen before any AGENTS.md
transaction is started.

## Fresh-environment deployment test

After extracting a Windows self-contained preview, run the real Windows
PowerShell 5.1 bootstrap lifecycle in an isolated per-user directory:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\packaging\windows\Test-FreshDeployment.ps1 `
  -PackageRoot C:\path\to\ClusterYourCodex-preview
```

The test validates the manifest-bound plan, performs an actual Install, starts
the controller, probes the worker and CLI, runs Repair, then Purge-Uninstalls
and verifies the scheduled-task state is restored. The smoke intentionally
disables the managed listener/firewall and Codex external integration so it
does not change shared network or Codex state. Use `-KeepWorkRoot` to retain
bounded logs for troubleshooting.

The release workflow also runs the real NSIS `Setup.exe /S` path on its
disposable `windows-latest` runner. That complementary test exercises the
default per-user install roots, controller Scheduled Task, managed-worker
listener, firewall rule, Apps & Features registration, Repair, and the
installed uninstaller. It verifies that silent mode launches no GUI and that
tasks, firewall state, ports, registration, and per-user paths return to their
clean pre-test state. Both the explicit switch and disposable-runner sentinel
are required:

```powershell
$env:CYC_DISPOSABLE_WINDOWS = '1'
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\packaging\windows\Test-SetupSilent.ps1 `
  -SetupPath C:\path\to\ClusterYourCodex-Setup.exe `
  -PackageRoot C:\path\to\ClusterYourCodex-preview `
  -DisposableEnvironment `
  -KeepWorkRoot
```

Do not run that test on an account with an existing ClusterYourCodex install.
It deliberately fails its preflight unless product tasks, firewall rules,
ports, uninstall registration, install root, and data root are all absent.
The product uninstaller preserves user data by design; deletion of that newly
created data root is a separate, tightly bounded test-harness cleanup step.
