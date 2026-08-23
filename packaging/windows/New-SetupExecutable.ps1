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

. (Join-Path $PSScriptRoot 'bootstrap.ps1')

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
        $candidate = Resolve-SetupPath $RequestedPath
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "makensis.exe was not found: $candidate"
        }
        return $candidate
    }
    $command = Get-Command makensis.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($command) { return [string]$command.Source }
    foreach ($candidate in @(
        (Join-Path ${env:ProgramFiles(x86)} 'NSIS\makensis.exe'),
        (Join-Path $env:ProgramFiles 'NSIS\makensis.exe')
    )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    throw 'makensis.exe is required to build ClusterYourCodex-Setup.exe.'
}

$package = Resolve-SetupPath $PackageRoot
$output = Resolve-SetupPath $OutputPath
$manifest = Join-Path $package 'preview-manifest.json'
$payload = Join-Path $package 'payload'
Assert-CycPackageManifest -Root $package -ManifestPath $manifest -PayloadRoot $payload

$outputParent = Split-Path -Parent $output
[void](New-Item -ItemType Directory -Path $outputParent -Force)
if (Test-Path -LiteralPath $output) {
    if (-not $Force) { throw "Setup output already exists: $output" }
    Remove-Item -LiteralPath $output -Force
}

$makeNsis = Resolve-MakeNsis -RequestedPath $MakeNsisPath
$script = Resolve-SetupPath (Join-Path $PSScriptRoot 'ClusterYourCodex.nsi')
$arguments = @(
    '/V4',
    "/DCYC_PACKAGE_ROOT=$package",
    "/DCYC_OUTPUT=$output"
)
if ($RequireRuntimeSignature) { $arguments += '/DCYC_REQUIRE_SIGNATURE=1' }
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
