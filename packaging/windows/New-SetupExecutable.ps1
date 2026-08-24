#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PackageRoot,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [string]$MakeNsisPath,
    [switch]$RequireRuntimeSignature,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Dot-sourcing bootstrap.ps1 can replace the dynamic value of $PSScriptRoot
# under Windows PowerShell 5.1. Preserve this script's location before loading
# shared helpers so the NSIS source remains resolvable later in the build.
# bootstrap.ps1 has its own param block, so preserve every builder input before
# importing it as well; dot-sourcing otherwise replaces matching variables in
# this script scope.
$setupScriptRoot = [string]$PSScriptRoot
$requestedPackageRoot = [string]$PackageRoot
$requestedOutputPath = [string]$OutputPath
$requestedMakeNsisPath = [string]$MakeNsisPath
$requestedRequireRuntimeSignature = [bool]$RequireRuntimeSignature
$requestedForce = [bool]$Force
if ([string]::IsNullOrWhiteSpace($setupScriptRoot)) {
    throw 'New-SetupExecutable.ps1 must be launched from a script file path.'
}
$bootstrapScript = Join-Path -Path $setupScriptRoot -ChildPath 'bootstrap.ps1'
# The bootstrap script defines a default BundleRoot with its own dynamic
# $PSScriptRoot. Supply a harmless non-empty value because this caller imports
# helpers only and Windows PowerShell 5.1 can leave that automatic value blank.
. $bootstrapScript -BundleRoot $setupScriptRoot

function Resolve-SetupPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $resolved = [System.IO.Path]::GetFullPath($Path)
    if ($resolved.Contains('"') -or $resolved.Contains("`r") -or $resolved.Contains("`n")) {
        throw 'NSIS input and output paths must not contain quotes or line breaks.'
    }
    return $resolved
}

function Resolve-MakeNsis {
    param([string]$RequestedPath)
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $candidate = Resolve-SetupPath -Path $RequestedPath.Trim()
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "makensis.exe was not found: $candidate"
        }
        return $candidate
    }
    $commands = @(Get-Command makensis.exe -CommandType Application -All -ErrorAction SilentlyContinue)
    foreach ($command in $commands) {
        # ApplicationInfo differs between Windows PowerShell and pwsh, and
        # Chocolatey can expose a shim with one or more blank properties.
        foreach ($propertyName in @('Path', 'Source', 'Definition')) {
            $property = $command.PSObject.Properties[$propertyName]
            if ($null -eq $property) { continue }
            $commandPath = [string]$property.Value
            if ([string]::IsNullOrWhiteSpace($commandPath)) { continue }
            $commandPath = $commandPath.Trim()
            if (Test-Path -LiteralPath $commandPath -PathType Leaf) {
                return (Resolve-SetupPath -Path $commandPath)
            }
        }
    }
    $candidateRoots = @(
        [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles),
        [string]${env:ProgramFiles(x86)},
        [string]$env:ProgramFiles
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $seenRoots = @{}
    foreach ($root in $candidateRoots) {
        $normalizedRoot = $root.Trim()
        if (-not $seenRoots.ContainsKey($normalizedRoot)) {
            $seenRoots[$normalizedRoot] = $true
            $candidate = Join-Path -Path $normalizedRoot -ChildPath 'NSIS\makensis.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return (Resolve-SetupPath -Path $candidate)
            }
        }
    }
    throw 'makensis.exe is required to build ClusterYourCodex-Setup.exe.'
}

$package = Resolve-SetupPath -Path $requestedPackageRoot
$output = Resolve-SetupPath -Path $requestedOutputPath
$manifest = Join-Path $package 'preview-manifest.json'
$payload = Join-Path $package 'payload'
Assert-CycPackageManifest -Root $package -ManifestPath $manifest -PayloadRoot $payload

$outputParent = Split-Path -Parent $output
[void](New-Item -ItemType Directory -Path $outputParent -Force)
if (Test-Path -LiteralPath $output) {
    if (-not $requestedForce) { throw "Setup output already exists: $output" }
    Remove-Item -LiteralPath $output -Force
}

$makeNsis = Resolve-MakeNsis -RequestedPath $requestedMakeNsisPath
$script = Resolve-SetupPath -Path (Join-Path -Path $setupScriptRoot -ChildPath 'ClusterYourCodex.nsi')
$arguments = @(
    '/V4',
    "/DCYC_PACKAGE_ROOT=$package",
    "/DCYC_OUTPUT=$output"
)
if ($requestedRequireRuntimeSignature) { $arguments += '/DCYC_REQUIRE_SIGNATURE=1' }
$arguments += $script
$outputLines = @(& $makeNsis @arguments 2>&1)
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    $tail = @($outputLines | Select-Object -Last 20 | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    throw "makensis.exe failed (exit=$exitCode).`n$tail"
}
if (-not (Test-Path -LiteralPath $output -PathType Leaf)) {
    throw 'makensis.exe returned success without producing Setup.exe.'
}
$bytes = [System.IO.File]::ReadAllBytes($output)
if ($bytes.Length -lt 4096 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) {
    throw 'Generated setup is not a valid PE executable.'
}
$hash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
$sidecar = "$hash  $([System.IO.Path]::GetFileName($output))"
$sidecarPath = $output + '.sha256'
$sidecar | Set-Content -LiteralPath $sidecarPath -Encoding ASCII -NoNewline
[PSCustomObject]@{
    setupPath = $output
    sha256 = $hash
    sidecarPath = $sidecarPath
    authenticodeStatus = [string](Get-AuthenticodeSignature -LiteralPath $output).Status
}
