[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PluginRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = [System.IO.Path]::GetFullPath($PluginRoot)
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    throw "Native Codex plugin root does not exist: $root"
}

$required = @(
    '.codex-plugin/plugin.json',
    '.mcp.json',
    'skills/cluster-your-codex/SKILL.md',
    'mcp/dist/server.js',
    'mcp/runtime/node.exe',
    'mcp/runtime/LICENSE.node.txt'
)
foreach ($relative in $required) {
    $path = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Native Codex plugin payload is incomplete; missing $relative"
    }
    if ((Get-Item -LiteralPath $path).Length -le 0) {
        throw "Native Codex plugin payload is incomplete; empty $relative"
    }
}

$manifest = Get-Content -Raw (Join-Path $root '.codex-plugin/plugin.json') | ConvertFrom-Json
if ($manifest.name -ne 'cluster-your-codex') { throw "Unexpected plugin name: $($manifest.name)" }
if ([string]::IsNullOrWhiteSpace([string]$manifest.version)) { throw 'Plugin manifest has no version.' }
$mcp = Get-Content -Raw (Join-Path $root '.mcp.json') | ConvertFrom-Json
$server = $mcp.mcpServers.cluster_your_codex
if ($null -eq $server) { throw 'Plugin manifest does not declare cluster_your_codex.' }
if ($server.command -ne './mcp/runtime/node.exe') { throw 'Plugin must use its bundled Node runtime.' }

$legacy = @(Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '(?i)cluster.?orchestr|clustor|orchestrator' })
if ($legacy.Count -ne 0) { throw 'Legacy orchestrator skill content remains in the native plugin payload.' }

Write-Output ([ordered]@{
    schemaVersion = 'cyc.dev/native-plugin-integrity/v1'
    status = 'pass'
    plugin = $manifest.name
    version = [string]$manifest.version
    requiredFiles = $required.Count
    bundledRuntime = $true
} | ConvertTo-Json -Compress)
