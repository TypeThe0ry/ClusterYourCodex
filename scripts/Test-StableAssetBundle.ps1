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

function Assert-StableSafeName {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-StableBundle (-not [string]::IsNullOrWhiteSpace($Name)) "$Description is present"
    Assert-StableBundle ($Name -notmatch '[\x00-\x1f\x7f]' -and
        $Name -notmatch '[/\\]' -and $Name -notmatch '^[A-Za-z]:' -and
        $Name -notin @('.', '..')) "$Description is a safe basename: $Name"
}

function Get-StableSha256 {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-StableRegularFile -Path $Path -Description $Description
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
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

$rootEntries = @(Get-ChildItem -LiteralPath $BundleRoot -Force -ErrorAction Stop)
foreach ($entry in $rootEntries) {
    Assert-StableBundle (-not $entry.PSIsContainer) "stable bundle contains no nested directories: $($entry.Name)"
    Assert-StableBundle (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) "stable bundle entry is not a reparse point: $($entry.Name)"
}

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
Assert-StableBundle (($index.unsigned -is [bool]) -and -not $index.unsigned) 'stable release-index must not be marked unsigned'
Assert-StableBundle (($index.unattested -is [bool]) -and -not $index.unattested) 'stable release-index must not be unattested'
$sourceRefProperty = $index.PSObject.Properties['sourceRef']
if ($null -ne $sourceRefProperty) {
    Assert-StableBundle ([string]$sourceRefProperty.Value -ceq "refs/tags/$ExpectedTag") 'release-index sourceRef matches the stable tag ref'
}

$provenance = $index.provenance
Assert-StableBundle ($null -ne $provenance) 'stable release-index contains a provenance object'
Assert-StableBundle (($provenance.attested -is [bool]) -and $provenance.attested) 'stable release-index must carry attested provenance'
Assert-StableBundle ([string]$provenance.provider -ceq 'github-artifact-attestations') 'stable release-index provenance provider is GitHub artifact attestations'
Assert-StableBundle ([string]$provenance.predicateType -ceq 'https://slsa.dev/provenance/v1') 'stable release-index provenance predicate is SLSA v1'
Assert-StableBundle (-not [string]::IsNullOrWhiteSpace([string]$provenance.attestationId)) 'stable provenance attestationId is present'
Assert-StableBundle ([string]$provenance.attestationUrl -match '^https://[^\s]+$') 'stable provenance attestationUrl is an HTTPS URL'
$provenanceBundleName = [string]$provenance.bundleName
Assert-StableSafeName -Name $provenanceBundleName -Description 'stable provenance bundleName'
Assert-StableBundle ($provenanceBundleName -notin @('release-index.json', 'release-index.json.sha256', 'SHA256SUMS')) 'provenance bundleName is not reserved metadata'
$provenanceBundlePath = Join-Path $BundleRoot $provenanceBundleName
$provenanceBundleHash = Get-StableSha256 -Path $provenanceBundlePath -Description 'stable provenance bundle'
Assert-StableBundle ([string]$provenance.bundleSha256 -match '^[0-9a-fA-F]{64}$') 'stable provenance bundleSha256 is a SHA-256 digest'
Assert-StableBundle ($provenanceBundleHash -ceq ([string]$provenance.bundleSha256).ToLowerInvariant()) 'stable provenance bundleSha256 verifies'

$records = @($index.artifacts | Sort-Object name)
Assert-StableBundle ($records.Count -gt 0) 'stable release-index contains at least one artifact'
$seen = @{}
$sidecarSeen = @{}
$recordByName = @{}
foreach ($record in $records) {
    Assert-StableBundle ($null -ne $record) 'artifact record is present'
    $name = [string]$record.name
    Assert-StableSafeName -Name $name -Description 'artifact name'
    Assert-StableBundle ($name -notin @('release-index.json', 'release-index.json.sha256', 'SHA256SUMS', $provenanceBundleName)) "artifact name is not reserved metadata: $name"
    Assert-StableBundle (-not $seen.ContainsKey($name.ToLowerInvariant())) "artifact names are unique: $name"
    Assert-StableBundle (-not $sidecarSeen.ContainsKey($name.ToLowerInvariant())) "artifact name does not collide with an earlier sidecar: $name"
    $seen[$name.ToLowerInvariant()] = $true
    $assetPath = Join-Path $BundleRoot $name
    Assert-StableRegularFile -Path $assetPath -Description "artifact $name"
    $actualHash = Get-StableSha256 -Path $assetPath -Description "artifact $name"
    Assert-StableBundle ([string]$record.sha256 -match '^[0-9a-fA-F]{64}$') "artifact sha256 is valid: $name"
    Assert-StableBundle ($actualHash -ceq ([string]$record.sha256).ToLowerInvariant()) "artifact digest matches release-index: $name"
    Assert-StableBundle ($record.PSObject.Properties['bytes'] -ne $null) "artifact byte count is present: $name"
    Assert-StableBundle (([long]$record.bytes -ge 0) -and ([long]$record.bytes -eq (Get-Item -LiteralPath $assetPath).Length)) "artifact byte count matches: $name"
    $sidecarName = [string]$record.sidecar
    Assert-StableBundle ($sidecarName -ceq "$name.sha256") "artifact sidecar name is canonical: $name"
    Assert-StableSafeName -Name $sidecarName -Description "artifact sidecar name"
    Assert-StableBundle (-not $sidecarSeen.ContainsKey($sidecarName.ToLowerInvariant())) "artifact sidecar names are unique: $sidecarName"
    Assert-StableBundle (-not $seen.ContainsKey($sidecarName.ToLowerInvariant())) "artifact sidecar does not collide with an artifact: $sidecarName"
    $sidecarSeen[$sidecarName.ToLowerInvariant()] = $true
    $sidecarPath = Join-Path $BundleRoot $sidecarName
    Assert-StableRegularFile -Path $sidecarPath -Description "artifact sidecar $sidecarName"
    $sidecar = (Get-Content -LiteralPath $sidecarPath -Raw).Trim()
    Assert-StableBundle ($sidecar -match '^(?<hash>[0-9a-fA-F]{64})  (?<name>[^/\\\r\n]+)$') "artifact sidecar is canonical: $sidecarName"
    Assert-StableBundle ($Matches.name -ceq $name -and $Matches.hash.ToLowerInvariant() -ceq $actualHash) "artifact sidecar verifies: $name"
    $recordByName[$name.ToLowerInvariant()] = $record
}
Assert-StableBundle (-not $seen.ContainsKey($provenanceBundleName.ToLowerInvariant()) -and
    -not $sidecarSeen.ContainsKey($provenanceBundleName.ToLowerInvariant())) 'provenance bundle does not collide with an indexed asset or sidecar'

$sbom = $index.sbom
Assert-StableBundle ($null -ne $sbom) 'stable release-index contains an SBOM descriptor'
Assert-StableBundle ([string]$sbom.format -ceq 'CycloneDX') 'stable SBOM format is CycloneDX'
Assert-StableBundle ([string]$sbom.specVersion -ceq '1.6') 'stable SBOM specVersion is 1.6'
$sbomName = [string]$sbom.name
Assert-StableSafeName -Name $sbomName -Description 'stable SBOM name'
Assert-StableBundle ([string]$sbom.sha256 -match '^[0-9a-fA-F]{64}$') 'stable SBOM sha256 is a SHA-256 digest'
$sbomRecords = @($records | Where-Object { [string]$_.name -ceq $sbomName -and [string]$_.kind -ceq 'sbom' })
Assert-StableBundle ($sbomRecords.Count -eq 1) 'stable release-index contains exactly one indexed CycloneDX SBOM artifact'
Assert-StableBundle ([string]$sbomRecords[0].format -ceq 'CycloneDX') 'indexed SBOM artifact format is CycloneDX'
Assert-StableBundle ([string]$sbomRecords[0].specVersion -ceq '1.6') 'indexed SBOM artifact specVersion is 1.6'
Assert-StableBundle ([string]$sbomRecords[0].sha256 -ieq [string]$sbom.sha256) 'release-index SBOM descriptor digest matches its artifact record'
$sbomPath = Join-Path $BundleRoot $sbomName
try {
    $sbomDocument = Get-Content -LiteralPath $sbomPath -Raw | ConvertFrom-Json
} catch {
    throw "Stable SBOM is not valid JSON: $($_.Exception.Message)"
}
Assert-StableBundle ([string]$sbomDocument.bomFormat -ceq 'CycloneDX') 'stable SBOM bomFormat is CycloneDX'
Assert-StableBundle ([string]$sbomDocument.specVersion -ceq '1.6') 'stable SBOM document specVersion is 1.6'
$components = @($sbomDocument.components)
Assert-StableBundle ($components.Count -eq ($records.Count - 1)) 'stable SBOM contains exactly one component for every non-SBOM payload artifact'
$componentNames = @{}
foreach ($component in $components) {
    $componentName = [string]$component.name
    Assert-StableSafeName -Name $componentName -Description 'stable SBOM component name'
    Assert-StableBundle (-not $componentNames.ContainsKey($componentName.ToLowerInvariant())) "stable SBOM component names are unique: $componentName"
    $componentNames[$componentName.ToLowerInvariant()] = $true
    $componentHashes = @($component.hashes | Where-Object { [string]$_.alg -ceq 'SHA-256' })
    Assert-StableBundle ($componentHashes.Count -eq 1) "stable SBOM component has one SHA-256 hash: $componentName"
    Assert-StableBundle ([string]$componentHashes[0].content -match '^[0-9a-fA-F]{64}$') "stable SBOM component hash is valid: $componentName"
    Assert-StableBundle ($recordByName.ContainsKey($componentName.ToLowerInvariant())) "stable SBOM component maps to an indexed artifact: $componentName"
    Assert-StableBundle ([string]$recordByName[$componentName.ToLowerInvariant()].sha256 -ieq [string]$componentHashes[0].content) "stable SBOM component digest matches artifact: $componentName"
}
foreach ($record in @($records | Where-Object { [string]$_.name -cne $sbomName })) {
    Assert-StableBundle ($componentNames.ContainsKey(([string]$record.name).ToLowerInvariant())) "stable SBOM includes artifact: $($record.name)"
}

$noticeRecords = @($records | Where-Object { [string]$_.name -match '(?i)(third[-_ ]?party.*notices?|(^|[-_.])notices?([-. _]|$))' })
Assert-StableBundle ($noticeRecords.Count -gt 0) 'stable bundle contains a third-party notices artifact'
foreach ($noticeRecord in $noticeRecords) {
    Assert-StableBundle ((Get-Item -LiteralPath (Join-Path $BundleRoot ([string]$noticeRecord.name))).Length -gt 0) "third-party notices artifact is non-empty: $($noticeRecord.name)"
}

$subjectNodes = @($provenance.subjects)
Assert-StableBundle (($provenance.subjectCount -is [int] -or $provenance.subjectCount -is [long]) -and ([long]$provenance.subjectCount -gt 0)) 'stable provenance subjectCount is a positive integer'
Assert-StableBundle ([long]$provenance.subjectCount -eq $subjectNodes.Count) 'stable provenance subjectCount matches subjects'
$subjectSeen = @{}
foreach ($subject in $subjectNodes) {
    Assert-StableBundle ($null -ne $subject) 'stable provenance subject is present'
    $subjectName = [string]$subject.name
    Assert-StableSafeName -Name $subjectName -Description 'stable provenance subject name'
    Assert-StableBundle (-not $subjectSeen.ContainsKey($subjectName.ToLowerInvariant())) "stable provenance subject names are unique: $subjectName"
    $subjectSeen[$subjectName.ToLowerInvariant()] = $true
    Assert-StableBundle ($recordByName.ContainsKey($subjectName.ToLowerInvariant())) "stable provenance subject maps to an indexed artifact: $subjectName"
    Assert-StableBundle ([string]$subject.sha256 -match '^[0-9a-fA-F]{64}$') "stable provenance subject digest is valid: $subjectName"
    Assert-StableBundle ([string]$recordByName[$subjectName.ToLowerInvariant()].sha256 -ieq [string]$subject.sha256) "stable provenance subject digest matches artifact: $subjectName"
    Assert-StableBundle (([long]$subject.bytes -ge 0) -and ([long]$subject.bytes -eq [long]$recordByName[$subjectName.ToLowerInvariant()].bytes)) "stable provenance subject byte count matches artifact: $subjectName"
}
Assert-StableBundle ($subjectSeen.Count -eq $recordByName.Count) 'stable provenance subject set covers exactly all indexed payload artifacts'

$indexHash = Get-StableSha256 -Path $indexPath -Description 'release-index'
$indexSidecar = (Get-Content -LiteralPath $indexSidecarPath -Raw).Trim()
Assert-StableBundle ($indexSidecar -match '^(?<hash>[0-9a-fA-F]{64})  release-index\.json$') 'release-index sidecar is canonical'
Assert-StableBundle ($Matches.hash.ToLowerInvariant() -ceq $indexHash) 'release-index sidecar verifies'
$sumLines = @(Get-Content -LiteralPath $sumsPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
Assert-StableBundle ($sumLines.Count -eq ($records.Count + 1)) 'SHA256SUMS contains exactly every artifact and release-index'
$sumSeen = @{}
foreach ($line in $sumLines) {
    $text = ([string]$line).Trim()
    Assert-StableBundle ($text -match '^(?<hash>[0-9a-fA-F]{64})  (?<name>[^/\\\r\n]+)$') "SHA256SUMS line is canonical: $text"
    $sumName = [string]$Matches.name
    Assert-StableBundle (-not $sumSeen.ContainsKey($sumName.ToLowerInvariant())) "SHA256SUMS names are unique: $sumName"
    $sumSeen[$sumName.ToLowerInvariant()] = $true
    Assert-StableBundle ($sumName -ceq 'release-index.json' -or $recordByName.ContainsKey($sumName.ToLowerInvariant())) "SHA256SUMS name is an indexed artifact or release-index: $sumName"
    $sumPath = Join-Path $BundleRoot $sumName
    Assert-StableBundle (Test-Path -LiteralPath $sumPath -PathType Leaf) "SHA256SUMS target exists: $sumName"
    $sumHash = Get-StableSha256 -Path $sumPath -Description "SHA256SUMS target $sumName"
    Assert-StableBundle ($sumHash -ceq $Matches.hash.ToLowerInvariant()) "SHA256SUMS verifies: $sumName"
}
foreach ($expectedName in @($records | ForEach-Object { [string]$_.name }) + 'release-index.json') {
    Assert-StableBundle ($sumSeen.ContainsKey($expectedName.ToLowerInvariant())) "SHA256SUMS includes: $expectedName"
}

$expectedFiles = @{}
foreach ($record in $records) {
    $expectedFiles[[string]$record.name.ToLowerInvariant()] = $true
    $expectedFiles[[string]$record.sidecar.ToLowerInvariant()] = $true
}
foreach ($metadataName in @('release-index.json', 'release-index.json.sha256', 'SHA256SUMS', $provenanceBundleName)) {
    $expectedFiles[$metadataName.ToLowerInvariant()] = $true
}
$actualFiles = @($rootEntries | ForEach-Object { [string]$_.Name })
Assert-StableBundle ($actualFiles.Count -eq $expectedFiles.Count) 'stable bundle top-level file set has no extras or omissions'
foreach ($actualName in $actualFiles) {
    Assert-StableBundle ($expectedFiles.ContainsKey($actualName.ToLowerInvariant())) "stable bundle top-level file is indexed or required metadata: $actualName"
}

$result = [ordered]@{
    schemaVersion = 'cyc.dev/stable-bundle-verification/v1'
    status = 'passed'
    releaseChannel = 'stable'
    sourceTag = $ExpectedTag
    sourceCommit = $ExpectedCommit.ToLowerInvariant()
    artifactCount = $records.Count
    indexSha256 = $indexHash
    provenanceBundleName = $provenanceBundleName
    provenanceBundleSha256 = $provenanceBundleHash
    publishableAssets = @(
        @($records | ForEach-Object { [string]$_.name }) +
        @($records | ForEach-Object { [string]$_.sidecar }) +
        @('release-index.json', 'release-index.json.sha256', 'SHA256SUMS')
    )
}
if ($Json) {
    $result | ConvertTo-Json -Depth 8 -Compress
} else {
    $result
}
