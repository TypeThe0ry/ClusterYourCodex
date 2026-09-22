[CmdletBinding()]
param(
    [ValidateRange(30, 3600)][int]$PackageTimeoutSeconds = 900,
    [string]$WorkingDirectory = (Get-Location).Path,
    [string]$EvidenceRoot = $env:RUNNER_TEMP
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path -LiteralPath $WorkingDirectory -ErrorAction Stop).Path
$cargo = (Get-Command cargo.exe -CommandType Application -ErrorAction Stop).Source
$metadataJson = & $cargo metadata --no-deps --format-version 1 --locked
if ($LASTEXITCODE -ne 0) { throw "cargo metadata failed with exit code $LASTEXITCODE" }
$metadata = $metadataJson | ConvertFrom-Json
$packages = @($metadata.packages | Sort-Object name)
if ($packages.Count -eq 0) { throw 'cargo metadata returned no workspace packages.' }

Write-Output "Windows workspace test plan: $($packages.Count) packages"
foreach ($package in $packages) {
    Write-Output "==> testing package $($package.name)"
    & (Join-Path $root 'scripts\Invoke-BoundedWindowsProcess.ps1') `
        -FilePath $cargo `
        -ArgumentList @('test', '--locked', '-p', [string]$package.name, '--', '--test-threads=1') `
        -TimeoutSeconds $PackageTimeoutSeconds `
        -WorkingDirectory $root `
        -EvidenceRoot $EvidenceRoot
    if ($LASTEXITCODE -ne 0) { throw "package $($package.name) test failed with exit code $LASTEXITCODE" }
}
Write-Output 'Windows workspace package tests completed.'
