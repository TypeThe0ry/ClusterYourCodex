[CmdletBinding()]
param(
    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
    [string]$BackupRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$codexRoot = [System.IO.Path]::GetFullPath($CodexHome)
if (-not (Test-Path -LiteralPath $codexRoot -PathType Container)) {
    Write-Output ([ordered]@{ schemaVersion = 'cyc.dev/legacy-skill-cleanup/v1'; status = 'pass'; moved = @() } | ConvertTo-Json -Compress)
    exit 0
}

$backup = if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
    Join-Path $codexRoot ('.legacy-skill-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
} else { [System.IO.Path]::GetFullPath($BackupRoot) }

$legacyNames = @('clustor', 'cluster-orchestrator', 'orchestrator')
$roots = @(
    (Join-Path $codexRoot 'skills'),
    (Join-Path $codexRoot 'marketplaces'),
    (Join-Path $codexRoot 'plugins')
) | Where-Object { Test-Path -LiteralPath $_ -PathType Container }

$targets = @()
foreach ($root in $roots) {
    $targets += @(Get-ChildItem -LiteralPath $root -Directory -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $legacyNames -contains $_.Name.ToLowerInvariant() })
}

$moved = @()
foreach ($target in ($targets | Sort-Object FullName -Unique)) {
    $relative = $target.FullName.Substring($codexRoot.Length).TrimStart('\', '/')
    $destination = Join-Path $backup $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Move-Item -LiteralPath $target.FullName -Destination $destination
    $moved += [ordered]@{ source = $target.FullName; backup = $destination }
}

Write-Output ([ordered]@{
    schemaVersion = 'cyc.dev/legacy-skill-cleanup/v1'
    status = 'pass'
    moved = @($moved)
    backupRoot = if ($moved.Count -gt 0) { $backup } else { $null }
} | ConvertTo-Json -Compress)
