[CmdletBinding()]
param(
    [string]$RepositoryRoot,

    [string[]]$Path = @(),

    [switch]$RequireValid,

    [switch]$RequireTimestamp,

    [string]$ExpectedSubject,

    [string]$ExpectedIssuer,

    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-AuthenticodeBoundary {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw "Windows Authenticode boundary assertion failed: $Message"
    }
}

function Resolve-AuthenticodeBoundaryPath {
    param([Parameter(Mandatory = $true)][string]$Value)
    return [System.IO.Path]::GetFullPath($Value).TrimEnd('\', '/')
}

function Get-AuthenticodeReceipt {
    param([Parameter(Mandatory = $true)][string]$FilePath)

    Assert-AuthenticodeBoundary (Test-Path -LiteralPath $FilePath -PathType Leaf) "file exists: $FilePath"
    $signature = Get-AuthenticodeSignature -LiteralPath $FilePath -ErrorAction Stop
    $signer = $signature.SignerCertificate
    $timestamp = $signature.TimeStamperCertificate
    $status = [string]$signature.Status
    $receipt = [ordered]@{
        path = $FilePath
        status = $status
        statusMessage = [string]$signature.StatusMessage
        signerSubject = if ($null -eq $signer) { $null } else { [string]$signer.Subject }
        signerIssuer = if ($null -eq $signer) { $null } else { [string]$signer.Issuer }
        signerThumbprint = if ($null -eq $signer) { $null } else { [string]$signer.Thumbprint }
        signerNotBefore = if ($null -eq $signer) { $null } else { $signer.NotBefore.ToUniversalTime().ToString('o') }
        signerNotAfter = if ($null -eq $signer) { $null } else { $signer.NotAfter.ToUniversalTime().ToString('o') }
        timestamped = $null -ne $timestamp
        timestampSubject = if ($null -eq $timestamp) { $null } else { [string]$timestamp.Subject }
        timestampIssuer = if ($null -eq $timestamp) { $null } else { [string]$timestamp.Issuer }
        timestampNotAfter = if ($null -eq $timestamp) { $null } else { $timestamp.NotAfter.ToUniversalTime().ToString('o') }
    }

    if ($RequireValid) {
        Assert-AuthenticodeBoundary ($signature.Status -eq [System.Management.Automation.SignatureStatus]::Valid) "$FilePath has a valid Authenticode chain (observed=$status)"
        Assert-AuthenticodeBoundary ($null -ne $signer) "$FilePath has a signer certificate"
        if (-not [string]::IsNullOrWhiteSpace($ExpectedSubject)) {
            Assert-AuthenticodeBoundary ([string]$signer.Subject -like $ExpectedSubject) "$FilePath signer subject matches '$ExpectedSubject' (observed=$($signer.Subject))"
        }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedIssuer)) {
            Assert-AuthenticodeBoundary ([string]$signer.Issuer -like $ExpectedIssuer) "$FilePath signer issuer matches '$ExpectedIssuer' (observed=$($signer.Issuer))"
        }
    } else {
        Assert-AuthenticodeBoundary (
            $signature.Status -in @(
                [System.Management.Automation.SignatureStatus]::Valid,
                [System.Management.Automation.SignatureStatus]::NotSigned
            )
        ) "$FilePath is either validly signed or explicitly unsigned (observed=$status)"
    }

    if ($RequireTimestamp) {
        Assert-AuthenticodeBoundary ($null -ne $timestamp) "$FilePath contains a trusted Authenticode timestamp"
    }
    return [PSCustomObject]$receipt
}

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}
$root = Resolve-AuthenticodeBoundaryPath $RepositoryRoot

$checks = New-Object System.Collections.Generic.List[object]
if ($Path.Count -eq 0) {
    $nsis = Join-Path $root 'packaging\windows\ClusterYourCodex.nsi'
    $bootstrap = Join-Path $root 'packaging\windows\bootstrap.ps1'
    $firewall = Join-Path $root 'packaging\windows\Invoke-ClusterYourCodexFirewall.ps1'
    $packagingDocs = Join-Path $root 'docs\packaging.md'
    $releaseWorkflow = Join-Path $root '.github\workflows\release.yml'
    foreach ($file in @($nsis, $bootstrap, $firewall, $packagingDocs, $releaseWorkflow)) {
        Assert-AuthenticodeBoundary (Test-Path -LiteralPath $file -PathType Leaf) "boundary source exists: $file"
    }
    $nsisSource = Get-Content -LiteralPath $nsis -Raw
    $bootstrapSource = Get-Content -LiteralPath $bootstrap -Raw
    $firewallSource = Get-Content -LiteralPath $firewall -Raw
    $docsSource = Get-Content -LiteralPath $packagingDocs -Raw
    $workflowSource = Get-Content -LiteralPath $releaseWorkflow -Raw
    foreach ($check in @(
        @{ name = 'unelevated-nsis'; condition = $nsisSource -match '(?m)^RequestExecutionLevel user\s*$'; message = 'NSIS remains per-user and does not silently move the whole installer to elevation' },
        @{ name = 'runtime-signature-switch'; condition = $nsisSource -match 'CYC_REQUIRE_SIGNATURE' -and $bootstrapSource -match 'RequirePackageSignature'; message = 'the runtime has an explicit package-signature switch' },
        @{ name = 'setup-signature-verifier'; condition = $bootstrapSource -match 'Get-AuthenticodeSignature' -and $bootstrapSource -match 'Assert-CycPackageSignature'; message = 'bootstrap verifies the Setup Authenticode signature before the protected path' },
        @{ name = 'helper-signature-verifier'; condition = $firewallSource -match 'helperAuthenticodeRequired' -and $firewallSource -match 'Assert-CycFirewallAuthenticode' -and $firewallSource -match 'Get-AuthenticodeSignature'; message = 'the elevated firewall helper verifies the narrow Authenticode boundary' },
        @{ name = 'ga-documentation'; condition = $docsSource -match 'GA must Authenticode-sign both\s*Setup and the helper'; message = 'packaging documentation states the GA signing requirement' },
        @{ name = 'release-boundary-test'; condition = $workflowSource -match 'Test-WindowsAuthenticodeBoundary\.ps1'; message = 'the release workflow runs the Authenticode boundary contract test' }
    )) {
        Assert-AuthenticodeBoundary ([bool]$check.condition) ([string]$check.message)
        [void]$checks.Add([ordered]@{ name = $check.name; status = 'passed'; message = $check.message })
    }
} else {
    foreach ($candidate in $Path) {
        $resolved = Resolve-AuthenticodeBoundaryPath $candidate
        [void]$checks.Add((Get-AuthenticodeReceipt -FilePath $resolved))
    }
}

$result = [ordered]@{
    schemaVersion = 'cyc.dev/windows-authenticode-gate/v1'
    status = 'passed'
    mode = if ($Path.Count -eq 0) { 'repository-contract' } elseif ($RequireValid) { 'signed-artifact' } else { 'preview-artifact' }
    requireValid = [bool]$RequireValid
    requireTimestamp = [bool]$RequireTimestamp
    expectedSubject = if ([string]::IsNullOrWhiteSpace($ExpectedSubject)) { $null } else { $ExpectedSubject }
    expectedIssuer = if ([string]::IsNullOrWhiteSpace($ExpectedIssuer)) { $null } else { $ExpectedIssuer }
    checks = $checks.ToArray()
}
$json = $result | ConvertTo-Json -Depth 10
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $output = Resolve-AuthenticodeBoundaryPath $OutputPath
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $output) -Force)
    $json | Set-Content -LiteralPath $output -Encoding UTF8
}
$json
