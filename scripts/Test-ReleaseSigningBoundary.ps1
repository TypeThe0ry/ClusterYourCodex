[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath($RepositoryRoot)
$workflowPath = Join-Path $root '.github\workflows\release.yml'
$readmePath = Join-Path $root 'packaging\worker-kits\README.md'
$workflow = [IO.File]::ReadAllText($workflowPath)
$readme = [IO.File]::ReadAllText($readmePath)
$lines = [IO.File]::ReadAllLines($workflowPath)

if ($workflow -notmatch "github\.ref_type\s*\}\}\s*'\s*-cne\s*'tag'" -or
    $workflow -notmatch 'IsNullOrWhiteSpace\(\[string\]\$env:CYC_SOURCE_TAG\)') {
    throw 'Release identity does not fail closed for a non-tag or empty source tag.'
}
if ($workflow -notmatch 'workflow_dispatch') {
    throw 'Release signing-boundary regression test expects the explicit manual-run gate.'
}

$secretNeedle = 'secrets.CYC_WORKER_KIT_SIGNING_KEY_PEM_B64'
$secretLines = @(
    for ($index = 0; $index -lt $lines.Length; $index++) {
        if ($lines[$index].Contains($secretNeedle, [StringComparison]::Ordinal)) {
            $index
        }
    }
)
if ($secretLines.Count -eq 0) {
    throw 'Release workflow no longer contains a production signing-key consumer.'
}

$consumerJobs = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($secretLine in $secretLines) {
    $jobStart = -1
    for ($index = $secretLine; $index -ge 0; $index--) {
        if ($lines[$index] -match '^  ([A-Za-z0-9_-]+):\s*$') {
            $jobStart = $index
            break
        }
    }
    if ($jobStart -lt 0) {
        throw "Could not identify the signing-key consumer job near line $($secretLine + 1)."
    }

    $jobEnd = $lines.Length
    for ($index = $jobStart + 1; $index -lt $lines.Length; $index++) {
        if ($lines[$index] -match '^  [A-Za-z0-9_-]+:\s*$') {
            $jobEnd = $index
            break
        }
    }
    $jobName = ([regex]::Match($lines[$jobStart], '^  ([A-Za-z0-9_-]+):')).Groups[1].Value
    [void]$consumerJobs.Add($jobName)
    $job = [string]::Join("`n", $lines[$jobStart..($jobEnd - 1)])
    if ($job -notmatch '(?m)^    environment: production-signing\s*$') {
        throw "Signing-key consumer job '$jobName' is not protected by production-signing."
    }
    if ($job -notmatch "(?m)^    if: github\.ref_type == 'tag' && needs\.release-identity\.outputs\.source_tag != ''\s*$") {
        throw "Signing-key consumer job '$jobName' is not exact-tag-only."
    }
    if ($job -notmatch 'Materialize-WorkerKitSigningKey\.ps1') {
        throw "Signing-key consumer job '$jobName' bypasses the private-file materializer."
    }
}

$consumerJobNames = @($consumerJobs.GetEnumerator() | Sort-Object)
if ($consumerJobs.Count -ne 2 -or
    -not $consumerJobs.Contains('rust-artifacts') -or
    -not $consumerJobs.Contains('linux-arm64-worker-kit')) {
    throw "Unexpected production signing-key consumer set: $($consumerJobNames -join ', ')."
}

if ($readme -notmatch 'production-signing` environment secret' -or
    $readme -notmatch 'gh secret set CYC_WORKER_KIT_SIGNING_KEY_PEM_B64 --env production-signing' -or
    $readme -match '(?m)^Production releases require repository secret') {
    throw 'Worker-kit key-provisioning documentation does not require the protected environment secret.'
}

$criticalPaths = @(
    'crates\cyc-provision\src\worker_kit.rs',
    'packaging\worker-kits\New-WorkerKit.ps1',
    'packaging\worker-kits\windows\Install-Worker.ps1',
    'packaging\worker-kits\linux\install-worker.sh',
    'packaging\worker-kits\macos\install-worker.sh',
    'packaging\windows\New-PreviewPayload.ps1'
)
foreach ($relativePath in $criticalPaths) {
    $content = [IO.File]::ReadAllText((Join-Path $root $relativePath))
    if ($content -notmatch 'cyc-release-2026-02' -or
        $content -match 'cyc-release-2026-01') {
        throw "Publisher key rotation is inconsistent in $relativePath."
    }
}
$publicKeyPath = Join-Path $root 'crates\cyc-provision\publisher_keys\cyc-release-2026-02.pub'
$publicKey = [IO.File]::ReadAllText($publicKeyPath).Trim()
$publicBytes = [Convert]::FromBase64String($publicKey)
if ($publicBytes.Length -ne 32) {
    throw 'Pinned Ed25519 public key is not exactly 32 raw bytes.'
}

Write-Output (
    "Release signing boundary: passed (consumers: {0}; publisher key: cyc-release-2026-02)" -f
    ($consumerJobNames -join ', ')
)
