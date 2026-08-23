#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('windows-x86_64', 'linux-x86_64', 'linux-aarch64')]
    [string]$Target,

    [Parameter(Mandatory = $true)]
    [string]$WorkerExecutable,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [string]$Version = '0.1.0',

    [string]$SigningKeyPath,

    [string]$SigningKeyId,

    [string]$TrustedPublicKeyPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Value
    )
    [System.IO.File]::WriteAllText($Path, $Value, (New-Object System.Text.UTF8Encoding($false)))
}

function Resolve-OpenSsl {
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($command in @(Get-Command openssl -CommandType Application -All -ErrorAction SilentlyContinue)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
            [void]$candidates.Add([string]$command.Source)
        }
    }
    foreach ($candidate in @(
        'C:\Program Files\Git\usr\bin\openssl.exe',
        'C:\Program Files\OpenSSL-Win64\bin\openssl.exe',
        'C:\Program Files\OpenSSL\bin\openssl.exe'
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { [void]$candidates.Add($candidate) }
    }
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        $version = @(& $candidate version 2>&1)
        if ($LASTEXITCODE -eq 0 -and (($version | Out-String) -match '^OpenSSL 3\.')) {
            return $candidate
        }
    }
    throw 'OpenSSL 3.x is required to sign an Ed25519 worker kit.'
}

function Read-NormalFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][long]$MaximumBytes,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $resolved = Resolve-NormalizedPath $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "$Label is missing." }
    $item = Get-Item -LiteralPath $resolved -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -le 0 -or $item.Length -gt $MaximumBytes) {
        throw "$Label is not a bounded normal file."
    }
    return $resolved
}

$source = Resolve-NormalizedPath $WorkerExecutable
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    throw "Worker executable not found: $source"
}
$sourceItem = Get-Item -LiteralPath $source -Force
if (($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Worker executable must not be a reparse point.'
}
if ($sourceItem.Length -le 0 -or $sourceItem.Length -gt 512MB) {
    throw 'Worker executable size is invalid.'
}
if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$') {
    throw 'Version must be a SemVer-compatible value.'
}
if ([string]::IsNullOrWhiteSpace($SigningKeyPath)) {
    $SigningKeyPath = [string]$env:CYC_WORKER_KIT_SIGNING_KEY_PATH
}
if ([string]::IsNullOrWhiteSpace($SigningKeyId)) {
    $SigningKeyId = if ([string]::IsNullOrWhiteSpace([string]$env:CYC_WORKER_KIT_SIGNING_KEY_ID)) {
        'cyc-release-2026-01'
    } else { [string]$env:CYC_WORKER_KIT_SIGNING_KEY_ID }
}
if ([string]::IsNullOrWhiteSpace($TrustedPublicKeyPath)) {
    $TrustedPublicKeyPath = if ([string]::IsNullOrWhiteSpace([string]$env:CYC_WORKER_KIT_TRUSTED_PUBLIC_KEY_PATH)) {
        Join-Path $PSScriptRoot '..\..\crates\cyc-provision\publisher_keys\cyc-release-2026-01.pub'
    } else { [string]$env:CYC_WORKER_KIT_TRUSTED_PUBLIC_KEY_PATH }
}
if ($SigningKeyId -notmatch '^[0-9A-Za-z._-]{1,96}$') {
    throw 'SigningKeyId is invalid.'
}
$signingKey = Read-NormalFile -Path $SigningKeyPath -MaximumBytes 64KB -Label 'Signing key'
$trustedPublicKey = Read-NormalFile -Path $TrustedPublicKeyPath -MaximumBytes 1KB -Label 'Trusted public key'
$trustedPublicKeyBase64 = (Get-Content -LiteralPath $trustedPublicKey -Raw).Trim()
if ($trustedPublicKeyBase64 -notmatch '^[A-Za-z0-9+/]{43}=$') {
    throw 'Trusted public key must be one standard padded Base64 Ed25519 raw public key.'
}
$trustedPublicKeyBytes = [Convert]::FromBase64String($trustedPublicKeyBase64)
if ($trustedPublicKeyBytes.Length -ne 32) { throw 'Trusted public key must decode to 32 bytes.' }
$openssl = Resolve-OpenSsl

$publicDerPath = [System.IO.Path]::GetTempFileName()
try {
    & $openssl pkey -in $signingKey -pubout -outform DER -out $publicDerPath 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Signing key is not a usable Ed25519 PKCS#8 private key.' }
    $publicDer = [System.IO.File]::ReadAllBytes($publicDerPath)
    $ed25519SpkiPrefix = [byte[]](0x30,0x2a,0x30,0x05,0x06,0x03,0x2b,0x65,0x70,0x03,0x21,0x00)
    if ($publicDer.Length -ne 44) { throw 'Signing key is not Ed25519.' }
    for ($index = 0; $index -lt $ed25519SpkiPrefix.Length; $index++) {
        if ($publicDer[$index] -ne $ed25519SpkiPrefix[$index]) { throw 'Signing key is not Ed25519.' }
    }
    $derivedPublicKey = [byte[]]$publicDer[12..43]
    if ([Convert]::ToBase64String($derivedPublicKey) -cne $trustedPublicKeyBase64) {
        throw 'Signing private key does not match the pinned publisher public key.'
    }
} finally {
    [System.IO.File]::Delete($publicDerPath)
}

$output = Resolve-NormalizedPath $OutputDirectory
if (Test-Path -LiteralPath $output) {
    $existing = Get-Item -LiteralPath $output -Force
    if (($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Output directory must not be a reparse point.'
    }
    if (-not $existing.PSIsContainer) { throw 'Output path must be a directory.' }
    if (Get-ChildItem -LiteralPath $output -Force | Select-Object -First 1) {
        throw 'Output directory must be empty.'
    }
} else {
    [void](New-Item -ItemType Directory -Path $output)
}

$platform = if ($Target.StartsWith('windows-', [System.StringComparison]::Ordinal)) { 'windows' } else { 'linux' }
$architecture = if ($Target.EndsWith('aarch64', [System.StringComparison]::Ordinal)) { 'aarch64' } else { 'x86_64' }
$binaryName = if ($platform -eq 'windows') { 'cyc-worker.exe' } else { 'cyc-worker' }
$installerSource = if ($platform -eq 'windows') {
    Join-Path (Join-Path $PSScriptRoot 'windows') 'Install-Worker.ps1'
} else {
    Join-Path (Join-Path $PSScriptRoot 'linux') 'install-worker.sh'
}
$installerName = Split-Path -Leaf $installerSource
if (-not (Test-Path -LiteralPath $installerSource -PathType Leaf)) {
    throw "Worker lifecycle script is missing: $installerSource"
}

$binaryTarget = Join-Path $output $binaryName
$installerTarget = Join-Path $output $installerName
Copy-Item -LiteralPath $source -Destination $binaryTarget -Force
Copy-Item -LiteralPath $installerSource -Destination $installerTarget -Force

$publisherKeyPlaceholder = '__CYC_PUBLISHER_PUBLIC_KEY_BASE64__'
$installerText = [System.IO.File]::ReadAllText($installerTarget)
$placeholderOffset = $installerText.IndexOf($publisherKeyPlaceholder)
if ($placeholderOffset -lt 0 -or
    $installerText.IndexOf($publisherKeyPlaceholder, $placeholderOffset + $publisherKeyPlaceholder.Length) -ge 0) {
    throw 'Worker lifecycle script must contain exactly one publisher-key placeholder.'
}
$installerText = $installerText.Replace($publisherKeyPlaceholder, $trustedPublicKeyBase64)
Write-Utf8NoBom -Path $installerTarget -Value $installerText

$binaryHash = (Get-FileHash -LiteralPath $binaryTarget -Algorithm SHA256).Hash.ToLowerInvariant()
$installerHash = (Get-FileHash -LiteralPath $installerTarget -Algorithm SHA256).Hash.ToLowerInvariant()
$manifest = [ordered]@{
    schemaVersion = 'cyc.dev/worker-kit/v1'
    product = 'ClusterYourCodex Managed Worker'
    version = $Version
    target = $Target
    os = $platform
    architecture = $architecture
    files = @(
        [ordered]@{
            path = $binaryName
            sizeBytes = (Get-Item -LiteralPath $binaryTarget).Length
            sha256 = $binaryHash
            role = 'worker'
        },
        [ordered]@{
            path = $installerName
            sizeBytes = (Get-Item -LiteralPath $installerTarget).Length
            sha256 = $installerHash
            role = 'lifecycle'
        }
    )
}
$manifestPath = Join-Path $output 'worker-kit.json'
Write-Utf8NoBom -Path $manifestPath -Value (($manifest | ConvertTo-Json -Depth 8 -Compress) + "`n")
$manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
$detachedSignaturePath = [System.IO.Path]::GetTempFileName()
try {
    & $openssl pkeyutl -sign -rawin -inkey $signingKey -in $manifestPath -out $detachedSignaturePath 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Ed25519 worker-kit signing failed.' }
    $detachedSignature = [System.IO.File]::ReadAllBytes($detachedSignaturePath)
    if ($detachedSignature.Length -ne 64) { throw 'Ed25519 signature length is invalid.' }
} finally {
    [System.IO.File]::Delete($detachedSignaturePath)
}
$signatureEnvelope = [ordered]@{
    schemaVersion = 'cyc.dev/worker-kit-signature/v1'
    algorithm = 'Ed25519'
    keyId = $SigningKeyId
    signedObject = 'worker-kit.json'
    manifestSha256 = $manifestHash
    signature = [Convert]::ToBase64String($detachedSignature)
}
$signaturePath = Join-Path $output 'worker-kit.sig'
Write-Utf8NoBom -Path $signaturePath -Value (($signatureEnvelope | ConvertTo-Json -Depth 4 -Compress) + "`n")
$signatureHash = (Get-FileHash -LiteralPath $signaturePath -Algorithm SHA256).Hash.ToLowerInvariant()
$checksums = @(
    "$binaryHash  $binaryName",
    "$installerHash  $installerName",
    "$manifestHash  worker-kit.json",
    "$signatureHash  worker-kit.sig"
) -join "`n"
Write-Utf8NoBom -Path (Join-Path $output 'SHA256SUMS') -Value ($checksums + "`n")

[PSCustomObject]@{
    schemaVersion = 'cyc.dev/worker-kit-build/v1'
    target = $Target
    version = $Version
    outputDirectory = $output
    manifestSha256 = $manifestHash
    publisherKeyId = $SigningKeyId
    workerSha256 = $binaryHash
} | ConvertTo-Json -Depth 4
