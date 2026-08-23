#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-UninstallLocations {
    $installRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\', '/')
    $registryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ClusterYourCodex'
    $dataRoot = Join-Path $env:LOCALAPPDATA 'ClusterYourCodex'
    if (Test-Path -LiteralPath $registryPath) {
        $registration = Get-ItemProperty -LiteralPath $registryPath -ErrorAction Stop
        if ($registration.InstallLocation) {
            $recordedInstall = [System.IO.Path]::GetFullPath([string]$registration.InstallLocation).TrimEnd('\', '/')
            if (-not [string]::Equals(
                $installRoot,
                $recordedInstall,
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
                throw 'The uninstall registration points at a different installation.'
            }
        }
        if ($registration.DataLocation) {
            $dataRoot = [System.IO.Path]::GetFullPath([string]$registration.DataLocation).TrimEnd('\', '/')
        }
    }
    return [PSCustomObject]@{
        installRoot = $installRoot
        dataRoot = $dataRoot
        coordinator = Join-Path $PSScriptRoot 'Invoke-ClusterYourCodexLifecycle.ps1'
    }
}

$locations = Get-UninstallLocations
if (-not (Test-Path -LiteralPath $locations.coordinator -PathType Leaf)) {
    throw 'Installed per-user lifecycle coordinator is missing.'
}
try {
    & $locations.coordinator `
        -Action Uninstall `
        -InstallRoot $locations.installRoot `
        -DataRoot $locations.dataRoot `
        -Quiet:$Quiet | Out-Host
    exit $LASTEXITCODE
} catch {
    Write-Error $_
    exit 1
}
