[CmdletBinding()]
param(
    [string]$InstallScript,
    [string]$CleanupScript
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($InstallScript)) {
    $InstallScript = Join-Path $PSScriptRoot 'Install-NativeCodexPlugin.ps1'
}
if ([string]::IsNullOrWhiteSpace($CleanupScript)) {
    $CleanupScript = Join-Path $PSScriptRoot 'Remove-LegacyCodexSkills.ps1'
}

foreach ($path in @($InstallScript, $CleanupScript)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Native plugin contract input is missing: $path"
    }
}

$install = Get-Content -Raw -LiteralPath $InstallScript
$cleanup = Get-Content -Raw -LiteralPath $CleanupScript

$requiredInstallFragments = @(
    "cluster-your-codex@clusteryourcodex",
    "Prepare-NativeCodexPlugin.ps1",
    "Test-NativeCodexPlugin.ps1",
    "Test-McpDeployment.mjs",
    "mcp/runtime/node.exe",
    "plugin remove",
    "plugin marketplace add",
    "plugin add",
    "installedPath",
    "Codex plugin cache failed integrity verification"
)
foreach ($fragment in $requiredInstallFragments) {
    if ($install.IndexOf($fragment, [System.StringComparison]::Ordinal) -lt 0) {
        throw "Install script is missing native plugin contract fragment: $fragment"
    }
}

if ($install -match '(?i)skills[\\/]cluster.?orchestr') {
    throw 'Install script still references a legacy orchestrator skill path.'
}

foreach ($fragment in @('clusterorchestrator', 'clustor', 'orchestrator')) {
    if ($cleanup.IndexOf($fragment, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "Cleanup script does not cover legacy name: $fragment"
    }
}

Write-Output ([ordered]@{
    schemaVersion = 'cyc.dev/native-plugin-contract/v1'
    status = 'pass'
    nativePluginId = 'cluster-your-codex@clusteryourcodex'
    legacyNamesCovered = @('clustor', 'cluster-orchestrator', 'orchestrator')
    mcpProbe = 'packaging/windows/Test-McpDeployment.mjs'
    reinstall = 'remove-before-add'
} | ConvertTo-Json -Compress)
