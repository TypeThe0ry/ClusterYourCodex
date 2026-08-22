#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string]$RootCargoTarget = (Join-Path $RepositoryRoot 'target\release'),
    [string]$DesktopCargoTarget = (Join-Path $RepositoryRoot 'apps\desktop\src-tauri\target\release'),
    [Parameter(Mandatory = $true)][string]$McpDeployRoot,
    [Parameter(Mandatory = $true)][string]$NodeExecutable,
    [Parameter(Mandatory = $true)][string]$NodeLicense,
    [Parameter(Mandatory = $true)][string]$OutputRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Copy-RequiredFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Required preview input is missing: $Source"
    }
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force)
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

$repo = Resolve-FullPath $RepositoryRoot
$rootTarget = Resolve-FullPath $RootCargoTarget
$desktopTarget = Resolve-FullPath $DesktopCargoTarget
$mcpDeploy = Resolve-FullPath $McpDeployRoot
$nodeExecutablePath = Resolve-FullPath $NodeExecutable
$nodeLicensePath = Resolve-FullPath $NodeLicense
$output = Resolve-FullPath $OutputRoot
if (-not (Test-Path -LiteralPath $nodeExecutablePath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $nodeLicensePath -PathType Leaf)) {
    throw 'NodeExecutable and its matching NodeLicense must both be regular files.'
}
$nodeArch = [string](& $nodeExecutablePath -p 'process.arch')
$nodeVersion = [string](& $nodeExecutablePath -p 'process.version')
if ($LASTEXITCODE -ne 0 -or $nodeArch.Trim() -ne 'x64' -or
    [int]($nodeVersion.Trim().TrimStart('v').Split('.')[0]) -lt 20) {
    throw 'Windows x64 preview requires a working private Node.js 20+ x64 runtime.'
}
if (Test-Path -LiteralPath $output) {
    if (Get-ChildItem -LiteralPath $output -Force | Select-Object -First 1) {
        throw "OutputRoot must not already contain files: $output"
    }
} else {
    [void](New-Item -ItemType Directory -Path $output -Force)
}

$payload = Join-Path $output 'payload'
[void](New-Item -ItemType Directory -Path $payload -Force)
foreach ($name in @('cyc-controller.exe', 'cyc-worker.exe', 'cyc.exe')) {
    Copy-RequiredFile -Source (Join-Path $rootTarget $name) -Destination (Join-Path $payload $name)
}
Copy-RequiredFile `
    -Source (Join-Path $desktopTarget 'ClusterYourCodex.exe') `
    -Destination (Join-Path $payload 'ClusterYourCodex.exe')
Copy-RequiredFile `
    -Source (Join-Path $PSScriptRoot 'bootstrap.ps1') `
    -Destination (Join-Path $output 'bootstrap.ps1')
Copy-RequiredFile `
    -Source (Join-Path $PSScriptRoot 'Install-ClusterYourCodex.cmd') `
    -Destination (Join-Path $output 'Install-ClusterYourCodex.cmd')
Copy-RequiredFile `
    -Source (Join-Path $PSScriptRoot 'README.md') `
    -Destination (Join-Path $output 'README.md')
Copy-RequiredFile `
    -Source (Join-Path $repo 'LICENSE') `
    -Destination (Join-Path $output 'LICENSE')

$marketplace = Join-Path $payload 'integrations\codex-marketplace'
Copy-RequiredFile `
    -Source (Join-Path $repo '.agents\plugins\marketplace.json') `
    -Destination (Join-Path $marketplace '.agents\plugins\marketplace.json')
$pluginSource = Join-Path $repo 'plugins\cluster-your-codex'
$pluginTarget = Join-Path $marketplace 'plugins\cluster-your-codex'
[void](New-Item -ItemType Directory -Path $pluginTarget -Force)
foreach ($relative in @('.codex-plugin', 'skills')) {
    $source = Join-Path $pluginSource $relative
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        throw "Required plugin directory is missing: $source"
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path $pluginTarget $relative) -Recurse -Force
}
$sourceMcpManifest = Join-Path $pluginSource '.mcp.json'
if (-not (Test-Path -LiteralPath $sourceMcpManifest -PathType Leaf)) {
    throw "Required plugin manifest is missing: $sourceMcpManifest"
}
$sourceMcpHash = (Get-FileHash -LiteralPath $sourceMcpManifest -Algorithm SHA256).Hash
$stagedMcpManifest = Join-Path $pluginTarget '.mcp.json'
$mcpConfiguration = Get-Content -LiteralPath $sourceMcpManifest -Raw | ConvertFrom-Json
if (-not $mcpConfiguration.mcpServers.cluster_your_codex) {
    throw 'Plugin .mcp.json is missing mcpServers.cluster_your_codex.'
}
$mcpConfiguration.mcpServers.cluster_your_codex.command = './mcp/runtime/node.exe'
$mcpConfiguration | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $stagedMcpManifest -Encoding UTF8
if ((Get-FileHash -LiteralPath $sourceMcpManifest -Algorithm SHA256).Hash -ne $sourceMcpHash) {
    throw 'Source plugin .mcp.json changed during preview staging.'
}
if (-not (Test-Path -LiteralPath (Join-Path $mcpDeploy 'dist\server.js') -PathType Leaf)) {
    throw 'McpDeployRoot must contain the compiled dist/server.js.'
}
Copy-Item -LiteralPath $mcpDeploy -Destination (Join-Path $pluginTarget 'mcp') -Recurse -Force
Copy-RequiredFile `
    -Source $nodeExecutablePath `
    -Destination (Join-Path $pluginTarget 'mcp\runtime\node.exe')
Copy-RequiredFile `
    -Source $nodeLicensePath `
    -Destination (Join-Path $pluginTarget 'mcp\runtime\LICENSE.node.txt')

$files = @(Get-ChildItem -LiteralPath $output -File -Recurse -Force | Sort-Object FullName)
$records = @($files | ForEach-Object {
    $relative = $_.FullName.Substring($output.Length + 1).Replace('\', '/')
    [ordered]@{
        path = $relative
        length = [long]$_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
})
$manifest = [ordered]@{
    schemaVersion = 'cyc.dev/windows-preview/v1'
    createdAtUtc = [DateTime]::UtcNow.ToString('o')
    architecture = 'x86_64-pc-windows-msvc'
    nodeVersion = $nodeVersion.Trim()
    files = $records
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $output 'preview-manifest.json') -Encoding UTF8
$checksumRecords = @(Get-ChildItem -LiteralPath $output -File -Recurse -Force | Sort-Object FullName | ForEach-Object {
    $relative = $_.FullName.Substring($output.Length + 1).Replace('\', '/')
    $digest = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$digest  $relative"
})
$checksumRecords | Set-Content -LiteralPath (Join-Path $output 'SHA256SUMS') -Encoding ASCII

# Reuse the installer planner as the final payload-layout acceptance check.
& (Join-Path $output 'bootstrap.ps1') -Action Install -BundleRoot $payload -PlanOnly | Out-Null
Write-Output $output
