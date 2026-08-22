# Windows packaging

`bootstrap.ps1` is the current-user lifecycle engine used by the future NSIS
custom action and by portable/private-preview bundles. It never accepts a raw
controller token and never places a token in argv, environment variables,
task definitions, manifests, or logs.

## Payload layout

```text
payload/
  ClusterYourCodex.exe
  cyc-controller.exe
  cyc-worker.exe                 optional unless -EnableWorker is used
  cyc.exe
  integrations/codex-marketplace/
    .agents/plugins/marketplace.json
    plugins/cluster-your-codex/  complete plugin directory
      mcp/runtime/node.exe       bundled private MCP runtime
      mcp/runtime/LICENSE.node.txt
```

## Commands

```powershell
# Show a deterministic plan without changing the machine.
.\bootstrap.ps1 -Action Install -PlanOnly

# Install or idempotently upgrade/repair the current-user installation.
.\bootstrap.ps1 -Action Install
.\bootstrap.ps1 -Action Repair

# Enable the worker only after pairing created its protected config file.
.\bootstrap.ps1 -Action Repair -EnableWorker

# Remove installer-owned files and tasks; keep controller/worker data.
.\bootstrap.ps1 -Action Uninstall

# Explicit destructive cleanup of the manifest-recorded default data root.
.\bootstrap.ps1 -Action Uninstall -PurgeData

# Pure PowerShell 5.1 static and install-plan tests.
.\Test-WindowsPackaging.ps1
```

## Release staging

Build the root Rust binaries and the Tauri native host in release mode, then
create a production-only MCP deployment and assemble a repeatable,
checksum-recorded preview:

```powershell
pnpm --filter @clusteryourcodex/codex-mcp deploy --prod --legacy "$env:RUNNER_TEMP\cyc-mcp"
$node = (Get-Command node -CommandType Application).Source
$nodeLicense = Join-Path (Split-Path -Parent $node) 'LICENSE'
if (-not (Test-Path -LiteralPath $nodeLicense)) {
  throw 'The selected Node distribution must include its matching LICENSE file.'
}
.\packaging\windows\New-PreviewPayload.ps1 `
  -McpDeployRoot "$env:RUNNER_TEMP\cyc-mcp" `
  -NodeExecutable $node `
  -NodeLicense $nodeLicense `
  -OutputRoot ".\artifacts\ClusterYourCodex-Windows-x64"
```

The output root contains `bootstrap.ps1`, `SHA256SUMS`, a non-secret preview
manifest, a double-click `Install-ClusterYourCodex.cmd`, and the complete
`payload/` expected by bootstrap. The wrapper resolves its directory with
`%~dp0`, installs for the current user, returns PowerShell's exit code, and
pauses on failure. On success it launches the installed GUI. The staged plugin
uses its bundled, license-accompanied private Node runtime rather than PATH
`node`; only the staged `.mcp.json` is rewritten. The runtime and license
hashes are recorded in `preview-manifest.json` and `SHA256SUMS`; release
staging does not fetch an unverified replacement license. The current Tauri
NSIS contains the GUI only; it does **not** invoke bootstrap yet.

Treat this ZIP as a self-contained Windows developer preview. It installs the
loopback controller, GUI, CLI, worker binary, and best-effort Codex integration.
Managed-worker TLS onboarding and the GUI setup actions are not connected yet.
Keep the extracted preview directory to run
`.\bootstrap.ps1 -Action Uninstall`; this preview does not yet register an
installed uninstaller.

The controller and worker run as least-privilege, current-user Scheduled Tasks
with `Interactive` logon, `IgnoreNew`, bounded restart, and no embedded secret.
Codex marketplace/plugin registration is best effort: a missing or older Codex
CLI does not fail the core install. The script never edits global `AGENTS.md`.
