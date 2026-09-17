[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutputRoot,
    [string]$NodeLicense
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
    $mcpManifest = Join-Path $plugin '.mcp.json'
    $mcpConfiguration = Get-Content -Raw -LiteralPath $mcpManifest | ConvertFrom-Json
    if ($null -eq $mcpConfiguration.mcpServers.cluster_your_codex) {
        throw 'Plugin .mcp.json is missing mcpServers.cluster_your_codex.'
    }
    $mcpConfiguration.mcpServers.cluster_your_codex.command = './mcp/runtime/node.exe'
    $mcpConfiguration | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $mcpManifest -Encoding UTF8
    $nodeExecutable = (Get-Command node.exe -CommandType Application -ErrorAction Stop).Source
    $nodeLicense = if ([string]::IsNullOrWhiteSpace($NodeLicense)) {
        Join-Path (Split-Path -Parent $nodeExecutable) 'LICENSE'
    } else {
        [System.IO.Path]::GetFullPath($NodeLicense)
    }
    if (-not (Test-Path -LiteralPath $nodeLicense -PathType Leaf)) {
        throw "The selected Node distribution is missing its matching LICENSE file: $nodeLicense"
    }
    $runtime = Join-Path $mcp 'runtime'
    New-Item -ItemType Directory -Path $runtime -Force | Out-Null
    Copy-Item -LiteralPath $nodeExecutable -Destination (Join-Path $runtime 'node.exe') -Force
    Copy-Item -LiteralPath $nodeLicense -Destination (Join-Path $runtime 'LICENSE.node.txt') -Force
    # Workspace symlinks cannot survive copying into the native plugin cache.
    $links = @(Get-ChildItem -LiteralPath $destination -Recurse -Force |
        Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 })
    if ($links.Count -ne 0) { throw 'Deployment contains links instead of portable files.' }
    & node (Join-Path $repo 'packaging/windows/Test-McpDeployment.mjs') $mcp
    if ($LASTEXITCODE -ne 0) { throw 'Prepared plugin failed the MCP startup/tools-list probe.' }
    & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File (Join-Path $repo 'scripts/Test-NativeCodexPlugin.ps1') `
        -PluginRoot $plugin
    if ($LASTEXITCODE -ne 0) { throw 'Prepared plugin failed the native payload integrity probe.' }
    Write-Output "Prepared native marketplace: $destination"
    Write-Output 'Register this persistent directory with codex plugin marketplace add, then codex plugin add cluster-your-codex@clusteryourcodex.'
} finally {
    Pop-Location
}
