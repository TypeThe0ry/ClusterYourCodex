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
    if (-not $Repair -and -not $completeMarketplace) {
        throw "MarketplaceRoot exists but is incomplete; rerun with -Repair to preserve it as a backup and rebuild: $marketplace"
    }
    if (-not $completeMarketplace) {
        $backup = "$marketplace.incomplete-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Move-Item -LiteralPath $marketplace -Destination $backup
        Write-Output "Moved incomplete marketplace to recoverable backup: $backup"
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

& $codex plugin marketplace add $marketplace --json
if ($LASTEXITCODE -ne 0) { throw 'Codex native marketplace registration failed.' }
& $codex plugin add 'cluster-your-codex@clusteryourcodex' --json
if ($LASTEXITCODE -ne 0) { throw 'Codex native plugin installation failed.' }

$registration = & $codex plugin list --json | ConvertFrom-Json
$installed = @(@($registration.installed) | Where-Object {
    $_.pluginId -eq 'cluster-your-codex@clusteryourcodex' -and
    $_.installed -eq $true -and $_.enabled -eq $true
})
if ($installed.Count -ne 1) { throw 'Native plugin registration is missing or disabled.' }

$installedRoot = [System.IO.Path]::GetFullPath([string]$installed[0].source.path)
& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File (Join-Path $repo 'scripts/Test-NativeCodexPlugin.ps1') `
    -PluginRoot $installedRoot
if ($LASTEXITCODE -ne 0) { throw 'Installed native plugin failed integrity verification.' }

$node = Join-Path $installedRoot 'mcp/runtime/node.exe'
$mcp = Join-Path $installedRoot 'mcp'
& $node (Join-Path $repo 'packaging/windows/Test-McpDeployment.mjs') $mcp
if ($LASTEXITCODE -ne 0) { throw 'Installed native MCP bridge failed the tools-list probe.' }

Write-Output ([ordered]@{
    schemaVersion = 'cyc.dev/native-plugin-install/v1'
    status = 'pass'
    marketplaceRoot = $marketplace
    installedRoot = $installedRoot
    pluginId = 'cluster-your-codex@clusteryourcodex'
} | ConvertTo-Json -Compress)
