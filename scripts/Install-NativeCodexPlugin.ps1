[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$MarketplaceRoot,
    [string]$CodexPath,
    [switch]$Repair
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = Split-Path $PSScriptRoot -Parent
$marketplace = [System.IO.Path]::GetFullPath($MarketplaceRoot)
if (Test-Path -LiteralPath $marketplace) {
    $marketplaceManifest = Join-Path $marketplace '.agents/plugins/marketplace.json'
    $marketplacePlugin = Join-Path $marketplace 'plugins/cluster-your-codex'
    $requiredMarketplaceFiles = @(
        $marketplaceManifest,
        (Join-Path $marketplacePlugin '.codex-plugin/plugin.json'),
        (Join-Path $marketplacePlugin '.mcp.json'),
        (Join-Path $marketplacePlugin 'skills/cluster-your-codex/SKILL.md'),
        (Join-Path $marketplacePlugin 'mcp/dist/server.js'),
        (Join-Path $marketplacePlugin 'mcp/runtime/node.exe'),
        (Join-Path $marketplacePlugin 'mcp/runtime/LICENSE.node.txt')
    )
    $completeMarketplace = (@($requiredMarketplaceFiles | Where-Object {
        -not (Test-Path -LiteralPath $_ -PathType Leaf) -or
        (Get-Item -LiteralPath $_).Length -le 0
    }).Count -eq 0)
    # A partial marketplace is never usable. Recover it automatically so the
    # user-facing installer can repair the opaque Codex "payload missing or
    # incomplete" state without requiring a second command or a hidden flag.
    # The old tree is moved aside before rebuilding and remains recoverable.
    # Repair is deliberately a full replacement, even when the previous tree
    # looks structurally complete. A complete tree can still be stale (for
    # example, its build/payload catalog may belong to an older release), and
    # reusing it is what produces the opaque integrity-verification failure.
    # Move the entire tree first so the operation remains recoverable.
    if ($Repair -or -not $completeMarketplace) {
        $backup = "$marketplace.incomplete-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Move-Item -LiteralPath $marketplace -Destination $backup
        $kind = if ($completeMarketplace) { 'previous' } else { 'incomplete' }
        Write-Output "Moved $kind marketplace to recoverable backup: $backup"
    }
}

$codex = if ([string]::IsNullOrWhiteSpace($CodexPath)) {
    (Get-Command codex -CommandType Application -All -ErrorAction Stop |
        Select-Object -First 1).Source
} else {
    [System.IO.Path]::GetFullPath($CodexPath)
}
if (-not (Test-Path -LiteralPath $codex -PathType Leaf)) {
    throw "Codex CLI does not exist: $codex"
}

# Remove only the exact legacy skill names before registering the native plugin.
# The cleanup is recoverable and leaves unrelated user skills untouched.
& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File (Join-Path $repo 'scripts/Remove-LegacyCodexSkills.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Legacy Codex skill cleanup failed.' }

# Verify the active Codex home is clean before registering the native plugin.
# Backups are intentionally outside these active roots and remain recoverable.
$codexRoot = Split-Path (Split-Path $marketplace -Parent) -Parent
$activeLegacyRoots = @(
    (Join-Path $codexRoot 'skills'),
    (Join-Path $codexRoot 'marketplaces'),
    (Join-Path $codexRoot 'plugins')
) | Where-Object { Test-Path -LiteralPath $_ -PathType Container }
$activeLegacy = @($activeLegacyRoots | ForEach-Object {
    Get-ChildItem -LiteralPath $_ -Directory -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '(?i)^(clustor|cluster[\s_-]*orchestrator|orchestrator)([\s_-].*)?$' }
})
if ($activeLegacy.Count -ne 0) {
    throw "Legacy Codex skill content remains active after cleanup: $($activeLegacy.FullName -join ', ')"
}

if (-not (Test-Path -LiteralPath (Join-Path $marketplace 'plugins/cluster-your-codex/.codex-plugin/plugin.json') -PathType Leaf)) {
    & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File (Join-Path $repo 'scripts/Prepare-NativeCodexPlugin.ps1') `
        -OutputRoot $marketplace
    if ($LASTEXITCODE -ne 0) { throw 'Native plugin preparation failed.' }
}

$preparedPlugin = Join-Path $marketplace 'plugins/cluster-your-codex'
& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File (Join-Path $repo 'scripts/Test-NativeCodexPlugin.ps1') `
    -PluginRoot $preparedPlugin
if ($LASTEXITCODE -ne 0) { throw 'Prepared native plugin failed integrity verification.' }

# Codex caches local plugin payloads by marketplace/plugin/version.  Re-adding
# the same version without removing it first can leave a stale partial cache in
# place, which surfaces as "payload missing or incomplete" even when the source
# marketplace is complete.  Remove the exact plugin registration first; a
# missing registration is harmless and does not abort repair.
& $codex plugin remove 'cluster-your-codex@clusteryourcodex' --json 2>$null
if ($LASTEXITCODE -ne 0) {
    # Older Codex builds return non-zero when the plugin is not installed.  The
    # subsequent add is still the authoritative operation, so continue.
    Write-Output 'No existing native plugin registration to remove; continuing with a clean add.'
}

& $codex plugin marketplace add $marketplace --json
if ($LASTEXITCODE -ne 0) { throw 'Codex native marketplace registration failed.' }
$addOutput = & $codex plugin add 'cluster-your-codex@clusteryourcodex' --json 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { throw "Codex native plugin installation failed: $addOutput" }
$addRecord = $addOutput | ConvertFrom-Json
$installedCacheRoot = [string]$addRecord.installedPath
if ([string]::IsNullOrWhiteSpace($installedCacheRoot)) {
    throw 'Codex native plugin installation returned no installedPath; refusing an unverified cache.'
}
$installedCacheRoot = [System.IO.Path]::GetFullPath($installedCacheRoot)
if (-not (Test-Path -LiteralPath $installedCacheRoot -PathType Container)) {
    throw "Codex native plugin cache does not exist: $installedCacheRoot"
}

$registration = & $codex plugin list --json | ConvertFrom-Json
$installed = @(@($registration.installed) | Where-Object {
    $_.pluginId -eq 'cluster-your-codex@clusteryourcodex' -and
    $_.installed -eq $true -and $_.enabled -eq $true
})
if ($installed.Count -ne 1) { throw 'Native plugin registration is missing or disabled.' }

$installedRoot = [System.IO.Path]::GetFullPath([string]$installed[0].source.path)
if (-not ($installedRoot -eq [System.IO.Path]::GetFullPath($preparedPlugin))) {
    throw "Codex registered an unexpected native plugin source: $installedRoot"
}
& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File (Join-Path $repo 'scripts/Test-NativeCodexPlugin.ps1') `
    -PluginRoot $installedRoot
if ($LASTEXITCODE -ne 0) { throw 'Installed native plugin failed integrity verification.' }

# Codex executes the copied cache payload, not the marketplace source. Verify
# that exact cache path as well; a successful registration with a truncated
# cache must never be reported as a healthy install.
& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File (Join-Path $repo 'scripts/Test-NativeCodexPlugin.ps1') `
    -PluginRoot $installedCacheRoot
if ($LASTEXITCODE -ne 0) { throw 'Codex plugin cache failed integrity verification.' }

$node = Join-Path $installedCacheRoot 'mcp/runtime/node.exe'
$mcp = Join-Path $installedCacheRoot 'mcp'
& $node (Join-Path $repo 'packaging/windows/Test-McpDeployment.mjs') $mcp
if ($LASTEXITCODE -ne 0) { throw 'Installed native MCP bridge failed the tools-list probe.' }

Write-Output ([ordered]@{
    schemaVersion = 'cyc.dev/native-plugin-install/v1'
    status = 'pass'
    marketplaceRoot = $marketplace
    installedRoot = $installedRoot
    installedCacheRoot = $installedCacheRoot
    pluginId = 'cluster-your-codex@clusteryourcodex'
} | ConvertTo-Json -Compress)
