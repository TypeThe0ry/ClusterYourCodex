#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BundleRoot,
    [Parameter(Mandatory = $true)][string]$ExpectedTag,
    [Parameter(Mandatory = $true)][string]$ExpectedCommit,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-StableBundle {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw "Stable asset bundle assertion failed: $Message"
    }
}

function Assert-StableRegularFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-StableBundle (Test-Path -LiteralPath $Path -PathType Leaf) "$Description exists: $Path"
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    Assert-StableBundle (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) "$Description is not a reparse point: $Path"
    $linkType = $item.PSObject.Properties['LinkType']
    if ($null -ne $linkType) {
        Assert-StableBundle ([string]::IsNullOrWhiteSpace([string]$linkType.Value)) "$Description is not a symbolic link: $Path"
    }
    $mode = $item.PSObject.Properties['Mode']
    if ($null -ne $mode) {
        Assert-StableBundle ([string]$mode.Value -notmatch 'l') "$Description is not a symbolic link: $Path"
    }
}

$BundleRoot = [System.IO.Path]::GetFullPath($BundleRoot)
Assert-StableBundle (Test-Path -LiteralPath $BundleRoot -PathType Container) "bundle root exists: $BundleRoot"
$bundleRootItem = Get-Item -LiteralPath $BundleRoot -Force -ErrorAction Stop
Assert-StableBundle (($bundleRootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) "bundle root is not a reparse point: $BundleRoot"
$bundleRootLinkType = $bundleRootItem.PSObject.Properties['LinkType']
if ($null -ne $bundleRootLinkType) {
    Assert-StableBundle ([string]::IsNullOrWhiteSpace([string]$bundleRootLinkType.Value)) "bundle root is not a symbolic link: $BundleRoot"
}
Assert-StableBundle ($ExpectedTag -match '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') "ExpectedTag must be stable SemVer (observed '$ExpectedTag')"
Assert-StableBundle ($ExpectedCommit -match '^[0-9a-fA-F]{40}$') 'ExpectedCommit must be a full commit SHA'

$indexPath = Join-Path $BundleRoot 'release-index.json'
$indexSidecarPath = Join-Path $BundleRoot 'release-index.json.sha256'
$sumsPath = Join-Path $BundleRoot 'SHA256SUMS'
foreach ($path in @($indexPath, $indexSidecarPath, $sumsPath)) {
    Assert-StableRegularFile -Path $path -Description 'required metadata'
}

try {
    $index = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json
} catch {
    throw "Stable asset bundle index is not valid JSON: $($_.Exception.Message)"
}

Assert-StableBundle ([string]$index.schemaVersion -ceq 'cyc.dev/release-index/v1') 'release-index schemaVersion is cyc.dev/release-index/v1'
Assert-StableBundle ([string]$index.releaseKind -ceq 'stable') 'release-index releaseKind must be stable'
Assert-StableBundle ([string]$index.releaseChannel -ceq 'stable') 'release-index releaseChannel must be stable'
Assert-StableBundle ([string]$index.productVersion -ceq $ExpectedTag.Substring(1)) 'release-index productVersion matches the stable tag'
Assert-StableBundle ([string]$index.sourceTag -ceq $ExpectedTag) 'release-index sourceTag matches the stable tag'
Assert-StableBundle ([string]$index.sourceCommit -ieq $ExpectedCommit) 'release-index sourceCommit matches the reviewed commit'
Assert-StableBundle (($index.unattested -is [bool]) -and -not $index.unattested) 'stable release-index must not be unattested'
Assert-StableBundle (($index.provenance.attested -is [bool]) -and $index.provenance.attested) 'stable release-index must carry attested provenance'
Assert-StableBundle ([string]$index.provenance.provider -ceq 'github-artifact-attestations') 'stable release-index provenance provider is GitHub artifact attestations'
Assert-StableBundle ([string]$index.provenance.predicateType -ceq 'https://slsa.dev/provenance/v1') 'stable release-index provenance predicate is SLSA v1'

$records = @($index.artifacts | Sort-Object name)
Assert-StableBundle ($records.Count -gt 0) 'stable release-index contains at least one artifact'
$seen = @{}
foreach ($record in $records) {
    $name = [string]$record.name
    Assert-StableBundle (-not [string]::IsNullOrWhiteSpace($name)) 'artifact name is present'
    Assert-StableBundle ($name -notmatch '(^|[\\/])\.\.([\\/]|$)' -and
        $name -notmatch '^[\\/]' -and $name -notmatch '^[A-Za-z]:') "artifact name is relative and non-traversing: $name"
    Assert-StableBundle (-not $seen.ContainsKey($name.ToLowerInvariant())) "artifact names are unique: $name"
    $seen[$name.ToLowerInvariant()] = $true
    $assetPath = Join-Path $BundleRoot $name
    Assert-StableRegularFile -Path $assetPath -Description "artifact $name"
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $assetPath).Hash.ToLowerInvariant()
    Assert-StableBundle ($actualHash -ceq ([string]$record.sha256).ToLowerInvariant()) "artifact digest matches release-index: $name"
    $sidecarName = [string]$record.sidecar
    Assert-StableBundle ($sidecarName -ceq "$name.sha256") "artifact sidecar name is canonical: $name"
    $sidecarPath = Join-Path $BundleRoot $sidecarName
    Assert-StableRegularFile -Path $sidecarPath -Description "artifact sidecar $sidecarName"
    $sidecar = (Get-Content -LiteralPath $sidecarPath -Raw).Trim()
    Assert-StableBundle ($sidecar -match '^(?<hash>[0-9a-fA-F]{64})  (?<name>[^/\\\r\n]+)$') "artifact sidecar is canonical: $sidecarName"
    Assert-StableBundle ($Matches.name -ceq $name -and $Matches.hash.ToLowerInvariant() -ceq $actualHash) "artifact sidecar verifies: $name"
}

$indexHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $indexPath).Hash.ToLowerInvariant()
$indexSidecar = (Get-Content -LiteralPath $indexSidecarPath -Raw).Trim()
Assert-StableBundle ($indexSidecar -match '^(?<hash>[0-9a-fA-F]{64})  release-index\.json$') 'release-index sidecar is canonical'
Assert-StableBundle ($Matches.hash.ToLowerInvariant() -ceq $indexHash) 'release-index sidecar verifies'
$sumLines = @(Get-Content -LiteralPath $sumsPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
Assert-StableBundle ($sumLines.Count -ge ($records.Count + 1)) 'SHA256SUMS contains every artifact and release-index'
$sumSeen = @{}
foreach ($line in $sumLines) {
    $text = ([string]$line).Trim()
    Assert-StableBundle ($text -match '^(?<hash>[0-9a-fA-F]{64})  (?<name>[^/\\\r\n]+)$') "SHA256SUMS line is canonical: $text"
    $sumName = [string]$Matches.name
    Assert-StableBundle (-not $sumSeen.ContainsKey($sumName.ToLowerInvariant())) "SHA256SUMS names are unique: $sumName"
    $sumSeen[$sumName.ToLowerInvariant()] = $true
    $sumPath = Join-Path $BundleRoot $sumName
    Assert-StableBundle (Test-Path -LiteralPath $sumPath -PathType Leaf) "SHA256SUMS target exists: $sumName"
    $sumHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sumPath).Hash.ToLowerInvariant()
    Assert-StableBundle ($sumHash -ceq $Matches.hash.ToLowerInvariant()) "SHA256SUMS verifies: $sumName"
}
foreach ($expectedName in @($records | ForEach-Object { [string]$_.name }) + 'release-index.json') {
    Assert-StableBundle ($sumSeen.ContainsKey($expectedName.ToLowerInvariant())) "SHA256SUMS includes: $expectedName"
}

$result = [ordered]@{
    schemaVersion = 'cyc.dev/stable-bundle-verification/v1'
    status = 'passed'
    releaseChannel = 'stable'
    sourceTag = $ExpectedTag
    sourceCommit = $ExpectedCommit.ToLowerInvariant()
    artifactCount = $records.Count
    indexSha256 = $indexHash
}
if ($Json) {
    $result | ConvertTo-Json -Depth 8 -Compress
} else {
    $result
}
