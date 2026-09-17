[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutputRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = Split-Path $PSScriptRoot -Parent
$destination = [System.IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $destination) {
    throw 'OutputRoot must be a new directory; existing plugin sources are never overwritten.'
}
foreach ($command in @('pnpm', 'node')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command is missing: $command"
    }
}

Push-Location $repo
try {
    & pnpm --filter @clusteryourcodex/codex-mcp build
    if ($LASTEXITCODE -ne 0) { throw 'MCP build failed; run pnpm install --frozen-lockfile first.' }
    $plugin = Join-Path $destination 'plugins/cluster-your-codex'
    $catalog = Join-Path $destination '.agents/plugins'
    New-Item -ItemType Directory -Path $plugin, $catalog -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo '.agents/plugins/marketplace.json') -Destination $catalog
    $source = Join-Path $repo 'plugins/cluster-your-codex'
    foreach ($name in @('.codex-plugin', 'skills', '.mcp.json')) {
        Copy-Item -LiteralPath (Join-Path $source $name) -Destination $plugin -Recurse
    }
    $mcp = Join-Path $plugin 'mcp'
    & pnpm --filter @clusteryourcodex/codex-mcp deploy --prod --config.node-linker=hoisted --config.inject-workspace-packages=true --frozen-lockfile $mcp
    if ($LASTEXITCODE -ne 0) { throw 'Production dependency deployment failed.' }
    # Workspace symlinks cannot survive copying into the native plugin cache.
    $links = @(Get-ChildItem -LiteralPath $destination -Recurse -Force |
        Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 })
    if ($links.Count -ne 0) { throw 'Deployment contains links instead of portable files.' }
    & node (Join-Path $repo 'packaging/windows/Test-McpDeployment.mjs') $mcp
    if ($LASTEXITCODE -ne 0) { throw 'Prepared plugin failed the MCP startup/tools-list probe.' }
    Write-Output "Prepared native marketplace: $destination"
    Write-Output 'Register this persistent directory with codex plugin marketplace add, then codex plugin add cluster-your-codex@clusteryourcodex.'
} finally {
    Pop-Location
}
