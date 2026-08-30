#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$IndexPath,
    [Parameter(Mandatory = $true)][string]$PrivateKeyPath,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-SignatureInput {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw "Stable index signing assertion failed: $Message" }
}

$resolvedIndex = [System.IO.Path]::GetFullPath($IndexPath)
$resolvedPrivateKey = [System.IO.Path]::GetFullPath($PrivateKeyPath)
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = "$resolvedIndex.sig"
}
$resolvedOutput = [System.IO.Path]::GetFullPath($OutputPath)

Assert-SignatureInput (Test-Path -LiteralPath $resolvedIndex -PathType Leaf) "stable index exists: $resolvedIndex"
Assert-SignatureInput (Test-Path -LiteralPath $resolvedPrivateKey -PathType Leaf) "private key exists: $resolvedPrivateKey"
Assert-SignatureInput ([string]::Equals([System.IO.Path]::GetFileName($resolvedIndex), 'release-index.json', [System.StringComparison]::Ordinal)) 'index filename is release-index.json'
Assert-SignatureInput (-not [string]::Equals($resolvedIndex, $resolvedPrivateKey, [System.StringComparison]::OrdinalIgnoreCase)) 'index and private-key paths are distinct'
Assert-SignatureInput (-not [string]::Equals($resolvedIndex, $resolvedOutput, [System.StringComparison]::OrdinalIgnoreCase)) 'signature output never overwrites release-index.json'

try {
    $index = Get-Content -LiteralPath $resolvedIndex -Raw -ErrorAction Stop | ConvertFrom-Json
} catch {
    throw "Stable index is not valid JSON: $($_.Exception.Message)"
}
Assert-SignatureInput ([string]$index.schemaVersion -ceq 'cyc.dev/release-index/v1') 'index schemaVersion is cyc.dev/release-index/v1'
Assert-SignatureInput ([string]$index.releaseKind -ceq 'stable') 'index releaseKind is stable'
Assert-SignatureInput ([string]$index.releaseChannel -ceq 'stable') 'index releaseChannel is stable'
Assert-SignatureInput (($index.unsigned -is [bool]) -and -not $index.unsigned) 'index unsigned=false is present after stable assembly'

$indexBytes = [System.IO.File]::ReadAllBytes($resolvedIndex)
$indexHash = (Get-FileHash -LiteralPath $resolvedIndex -Algorithm SHA256).Hash.ToLowerInvariant()
$rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(3072)
try {
    $privateKeyXml = Get-Content -LiteralPath $resolvedPrivateKey -Raw -ErrorAction Stop
    Assert-SignatureInput ($privateKeyXml -match '<D>[^<]+</D>') 'private key XML contains a private exponent'
    $rsa.FromXmlString($privateKeyXml)
    Assert-SignatureInput ($rsa.KeySize -ge 3072) "private key is at least 3072-bit (observed $($rsa.KeySize))"
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($indexBytes)
    $oid = [System.Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256')
    $signatureBytes = $rsa.SignHash($hash, $oid)
} finally {
    $rsa.Dispose()
}

$directory = Split-Path -Parent $resolvedOutput
[void](New-Item -ItemType Directory -Path $directory -Force)
$envelope = [ordered]@{
    schemaVersion = 'cyc.dev/release-index-signature/v1'
    algorithm = 'RSA-PKCS1-SHA256'
    keyId = 'clusteryourcodex-stable-index-2026'
    file = 'release-index.json'
    indexSha256 = $indexHash
    signature = [Convert]::ToBase64String($signatureBytes)
    signedAtUtc = [DateTime]::UtcNow.ToString('o')
}
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($resolvedOutput, ($envelope | ConvertTo-Json -Depth 8), $utf8)

[ordered]@{
    schemaVersion = 'cyc.dev/stable-index-signing/v1'
    status = 'passed'
    indexPath = $resolvedIndex
    signaturePath = $resolvedOutput
    indexSha256 = $indexHash
    keyId = [string]$envelope.keyId
    algorithm = [string]$envelope.algorithm
} | ConvertTo-Json -Depth 8 -Compress
