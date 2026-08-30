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

function Get-StableNonNegativeInt64 {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Description
    )

    # ConvertFrom-Json can represent a JSON number as Int32 or Int64, but it
    # must never silently coerce null, strings, floating point values, or an
    # overflowing unsigned value into a byte count.  Metadata is part of the
    # release contract, so reject every non-integral representation.
    Assert-StableBundle ($null -ne $Value) "$Description is present"
    $typeName = [string]$Value.GetType().FullName
    Assert-StableBundle ($typeName -in @(
        'System.Byte', 'System.SByte', 'System.Int16', 'System.UInt16',
        'System.Int32', 'System.UInt32', 'System.Int64'
    )) "$Description is an integer JSON number"
    try {
        $result = [long]$Value
    } catch {
        throw "Stable asset bundle assertion failed: $Description does not fit Int64."
    }
    Assert-StableBundle ($result -ge 0) "$Description is non-negative"
    return $result
}

function Test-StableIndexSignature {
    param(
        [Parameter(Mandatory = $true)][string]$IndexPath,
        [Parameter(Mandatory = $true)][string]$SignaturePath,
        [Parameter(Mandatory = $true)][string]$PublicKeyPath,
        [Parameter(Mandatory = $true)][string]$IndexSha256
    )

    Assert-StableRegularFile -Path $SignaturePath -Description 'release-index signature'
    Assert-StableRegularFile -Path $PublicKeyPath -Description 'stable release-index public key'
    try {
        $envelope = Get-Content -LiteralPath $SignaturePath -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        throw "Stable release-index signature is not valid JSON: $($_.Exception.Message)"
    }
    Assert-StableBundle ([string]$envelope.schemaVersion -ceq 'cyc.dev/release-index-signature/v1') 'release-index signature schemaVersion is v1'
    Assert-StableBundle ([string]$envelope.algorithm -ceq 'RSA-PKCS1-SHA256') 'release-index signature algorithm is RSA-PKCS1-SHA256'
    Assert-StableBundle ([string]$envelope.keyId -ceq 'clusteryourcodex-stable-index-2026') 'release-index signature keyId is the pinned production key'
    Assert-StableBundle ([string]$envelope.file -ceq 'release-index.json') 'release-index signature names release-index.json'
    Assert-StableBundle ([string]$envelope.indexSha256 -match '^[0-9a-fA-F]{64}$') 'release-index signature indexSha256 is a SHA-256 digest'
    Assert-StableBundle ([string]$envelope.indexSha256 -ieq $IndexSha256) 'release-index signature binds the exact release-index bytes'
    $signatureText = [string]$envelope.signature
    Assert-StableBundle ($signatureText -match '^[A-Za-z0-9+/]+={0,2}$' -and
        ($signatureText.Length % 4) -eq 0) 'release-index signature is canonical base64'
    $rsa = $null
    try {
        $signatureBytes = [Convert]::FromBase64String($signatureText)
        $indexBytes = [System.IO.File]::ReadAllBytes($IndexPath)
        $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(3072)
        $rsa.FromXmlString((Get-Content -LiteralPath $PublicKeyPath -Raw -ErrorAction Stop))
        $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($indexBytes)
        $oid = [System.Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256')
        $valid = $rsa.VerifyHash($hash, $oid, $signatureBytes)
    } catch {
        throw "Stable release-index signature verification failed: $($_.Exception.Message)"
    } finally {
        if ($null -ne $rsa) { $rsa.Dispose() }
    }
    Assert-StableBundle $valid 'release-index signature verifies with the pinned public key'
    return [PSCustomObject]@{
        schemaVersion = [string]$envelope.schemaVersion
        algorithm = [string]$envelope.algorithm
        keyId = [string]$envelope.keyId
        indexSha256 = $IndexSha256.ToLowerInvariant()
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

$rootEntries = @(Get-ChildItem -LiteralPath $BundleRoot -Force -ErrorAction Stop)
foreach ($entry in $rootEntries) {
    Assert-StableBundle (-not $entry.PSIsContainer) "stable bundle contains no nested directories: $($entry.Name)"
    Assert-StableBundle (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) "stable bundle entry is not a reparse point: $($entry.Name)"
}

$indexPath = Join-Path $BundleRoot 'release-index.json'
$indexSidecarPath = Join-Path $BundleRoot 'release-index.json.sha256'
$indexSignaturePath = Join-Path $BundleRoot 'release-index.json.sig'
$sumsPath = Join-Path $BundleRoot 'SHA256SUMS'
foreach ($path in @($indexPath, $indexSidecarPath, $indexSignaturePath, $sumsPath)) {
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

$indexHash = Get-StableSha256 -Path $indexPath -Description 'release-index'
$indexSignature = Test-StableIndexSignature `
    -IndexPath $indexPath `
    -SignaturePath $indexSignaturePath `
    -PublicKeyPath (Join-Path $PSScriptRoot 'stable-index-public-key.xml') `
    -IndexSha256 $indexHash

$provenance = $index.provenance
Assert-StableBundle ($null -ne $provenance) 'stable release-index contains a provenance object'
Assert-StableBundle (($provenance.attested -is [bool]) -and $provenance.attested) 'stable release-index must carry attested provenance'
Assert-StableBundle ([string]$provenance.provider -ceq 'github-artifact-attestations') 'stable release-index provenance provider is GitHub artifact attestations'
Assert-StableBundle ([string]$provenance.predicateType -ceq 'https://slsa.dev/provenance/v1') 'stable release-index provenance predicate is SLSA v1'
Assert-StableBundle (-not [string]::IsNullOrWhiteSpace([string]$provenance.attestationId)) 'stable provenance attestationId is present'
Assert-StableBundle ([string]$provenance.attestationUrl -match '^https://[^\s]+$') 'stable provenance attestationUrl is an HTTPS URL'
$provenanceBundleName = [string]$provenance.bundleName
Assert-StableSafeName -Name $provenanceBundleName -Description 'stable provenance bundleName'
Assert-StableBundle ($provenanceBundleName -notin @('release-index.json', 'release-index.json.sha256', 'release-index.json.sig', 'SHA256SUMS')) 'provenance bundleName is not reserved metadata'
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
    Assert-StableBundle ($name -notin @('release-index.json', 'release-index.json.sha256', 'release-index.json.sig', 'SHA256SUMS', $provenanceBundleName)) "artifact name is not reserved metadata: $name"
    Assert-StableBundle (-not $seen.ContainsKey($name.ToLowerInvariant())) "artifact names are unique: $name"
    Assert-StableBundle (-not $sidecarSeen.ContainsKey($name.ToLowerInvariant())) "artifact name does not collide with an earlier sidecar: $name"
    $seen[$name.ToLowerInvariant()] = $true
    $assetPath = Join-Path $BundleRoot $name
    Assert-StableRegularFile -Path $assetPath -Description "artifact $name"
    $actualHash = Get-StableSha256 -Path $assetPath -Description "artifact $name"
    Assert-StableBundle ([string]$record.sha256 -match '^[0-9a-fA-F]{64}$') "artifact sha256 is valid: $name"
    Assert-StableBundle ($actualHash -ceq ([string]$record.sha256).ToLowerInvariant()) "artifact digest matches release-index: $name"
    $recordBytes = Get-StableNonNegativeInt64 -Value $record.bytes -Description "artifact byte count: $name"
    Assert-StableBundle ($recordBytes -eq (Get-Item -LiteralPath $assetPath).Length) "artifact byte count matches: $name"
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
$serialNumber = [string]$sbomDocument.serialNumber
Assert-StableBundle ($serialNumber -match '^urn:uuid:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') 'stable SBOM serialNumber is a UUID URN'
$sbomVersion = Get-StableNonNegativeInt64 -Value $sbomDocument.version -Description 'stable SBOM version'
Assert-StableBundle ($sbomVersion -gt 0) 'stable SBOM version is positive'
$sbomMetadata = $sbomDocument.metadata
Assert-StableBundle ($null -ne $sbomMetadata) 'stable SBOM metadata is present'
$metadataTimestamp = [string]$sbomMetadata.timestamp
try { [void][DateTimeOffset]::Parse($metadataTimestamp, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) } catch { throw 'Stable SBOM metadata timestamp is not an ISO-8601 instant.' }
$metadataComponent = $sbomMetadata.component
Assert-StableBundle ($null -ne $metadataComponent) 'stable SBOM metadata component is present'
Assert-StableBundle ([string]$metadataComponent.type -ceq 'application') 'stable SBOM metadata component type is application'
Assert-StableBundle (-not [string]::IsNullOrWhiteSpace([string]$metadataComponent.name)) 'stable SBOM metadata component has a name'
Assert-StableBundle (-not [string]::IsNullOrWhiteSpace([string]$metadataComponent.version)) 'stable SBOM metadata component has a version'
$rootBomRef = [string]$metadataComponent.'bom-ref'
Assert-StableBundle (-not [string]::IsNullOrWhiteSpace($rootBomRef) -and $rootBomRef -notmatch '[\r\n]') 'stable SBOM metadata component bom-ref is present'
$metadataTools = @($sbomMetadata.tools)
Assert-StableBundle ($metadataTools.Count -gt 0) 'stable SBOM records at least one generation tool'
foreach ($tool in $metadataTools) {
    Assert-StableBundle ($null -ne $tool -and -not [string]::IsNullOrWhiteSpace([string]$tool.vendor) -and
        -not [string]::IsNullOrWhiteSpace([string]$tool.name) -and
        -not [string]::IsNullOrWhiteSpace([string]$tool.version)) 'stable SBOM tool has vendor, name, and version'
}
$components = @($sbomDocument.components)
Assert-StableBundle ($components.Count -eq ($records.Count - 1)) 'stable SBOM contains exactly one component for every non-SBOM payload artifact'
$componentNames = @{}
$componentRefs = @{}
foreach ($component in $components) {
    Assert-StableBundle ($null -ne $component) 'stable SBOM component is present'
    Assert-StableBundle ([string]$component.type -ceq 'file') "stable SBOM component type is file: $([string]$component.name)"
    $bomRef = [string]$component.'bom-ref'
    Assert-StableBundle (-not [string]::IsNullOrWhiteSpace($bomRef) -and $bomRef -notmatch '[\r\n]') 'stable SBOM component bom-ref is present'
    Assert-StableBundle (-not $componentRefs.ContainsKey($bomRef)) "stable SBOM bom-ref is unique: $bomRef"
    $componentRefs[$bomRef] = $true
    $componentName = [string]$component.name
    Assert-StableSafeName -Name $componentName -Description 'stable SBOM component name'
    Assert-StableBundle (-not $componentNames.ContainsKey($componentName.ToLowerInvariant())) "stable SBOM component names are unique: $componentName"
    $componentNames[$componentName.ToLowerInvariant()] = $true
    $componentHashes = @($component.hashes | Where-Object { [string]$_.alg -ceq 'SHA-256' })
    Assert-StableBundle ($componentHashes.Count -eq 1) "stable SBOM component has one SHA-256 hash: $componentName"
    Assert-StableBundle ([string]$componentHashes[0].content -match '^[0-9a-fA-F]{64}$') "stable SBOM component hash is valid: $componentName"
    Assert-StableBundle (-not [string]::IsNullOrWhiteSpace([string]$component.version)) "stable SBOM component version is present: $componentName"
    Assert-StableBundle ($recordByName.ContainsKey($componentName.ToLowerInvariant())) "stable SBOM component maps to an indexed artifact: $componentName"
    Assert-StableBundle ([string]$recordByName[$componentName.ToLowerInvariant()].sha256 -ieq [string]$componentHashes[0].content) "stable SBOM component digest matches artifact: $componentName"
}
foreach ($record in @($records | Where-Object { [string]$_.name -cne $sbomName })) {
    Assert-StableBundle ($componentNames.ContainsKey(([string]$record.name).ToLowerInvariant())) "stable SBOM includes artifact: $($record.name)"
}
$sbomDependencies = @($sbomDocument.dependencies)
Assert-StableBundle ($sbomDependencies.Count -gt 0) 'stable SBOM contains a dependency graph'
$dependencyRefs = @{}
foreach ($dependency in $sbomDependencies) {
    $dependencyRef = [string]$dependency.ref
    Assert-StableBundle (-not [string]::IsNullOrWhiteSpace($dependencyRef)) 'stable SBOM dependency ref is present'
    Assert-StableBundle (-not $dependencyRefs.ContainsKey($dependencyRef)) "stable SBOM dependency refs are unique: $dependencyRef"
    $dependencyRefs[$dependencyRef] = $true
    Assert-StableBundle ($dependencyRef -eq $rootBomRef -or $componentRefs.ContainsKey($dependencyRef)) "stable SBOM dependency ref maps to a declared component: $dependencyRef"
    foreach ($dependsOn in @($dependency.dependsOn)) {
        Assert-StableBundle ($componentRefs.ContainsKey([string]$dependsOn)) "stable SBOM dependency edge maps to a declared component: $dependsOn"
    }
}
$rootDependency = @($sbomDependencies | Where-Object { [string]$_.ref -ceq $rootBomRef })
Assert-StableBundle ($rootDependency.Count -eq 1) 'stable SBOM has exactly one application dependency root'
foreach ($componentRef in @($componentRefs.Keys)) {
    Assert-StableBundle (@($rootDependency[0].dependsOn | Where-Object { [string]$_ -ceq $componentRef }).Count -eq 1) "stable SBOM root depends on component: $componentRef"
}

$noticeRecords = @($records | Where-Object { [string]$_.name -ceq 'THIRD-PARTY-NOTICES.txt' })
Assert-StableBundle ($noticeRecords.Count -eq 1) 'stable bundle contains exactly one canonical THIRD-PARTY-NOTICES.txt artifact'
$noticePath = Join-Path $BundleRoot 'THIRD-PARTY-NOTICES.txt'
Assert-StableRegularFile -Path $noticePath -Description 'third-party notices artifact'
try {
    $noticeBytes = [System.IO.File]::ReadAllBytes($noticePath)
    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $noticeText = $strictUtf8.GetString($noticeBytes)
} catch {
    throw "Stable third-party notices artifact is not strict UTF-8 text: $($_.Exception.Message)"
}
Assert-StableBundle (-not [string]::IsNullOrWhiteSpace($noticeText)) 'third-party notices artifact is non-empty text'
Assert-StableBundle ($noticeText -match '(?im)^\uFEFF?\s*(SPDX-License-Identifier|Copyright|License)\b') 'third-party notices artifact contains a license/copyright declaration'

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
    $subjectBytes = Get-StableNonNegativeInt64 -Value $subject.bytes -Description "stable provenance subject byte count: $subjectName"
    $indexedSubjectBytes = Get-StableNonNegativeInt64 `
        -Value $recordByName[$subjectName.ToLowerInvariant()].bytes `
        -Description "indexed artifact byte count: $subjectName"
    Assert-StableBundle ($subjectBytes -eq $indexedSubjectBytes) "stable provenance subject byte count matches artifact: $subjectName"
}
Assert-StableBundle ($subjectSeen.Count -eq $recordByName.Count) 'stable provenance subject set covers exactly all indexed payload artifacts'

$indexSidecar = (Get-Content -LiteralPath $indexSidecarPath -Raw).Trim()
Assert-StableBundle ($indexSidecar -match '^(?<hash>[0-9a-fA-F]{64})  release-index\.json$') 'release-index sidecar is canonical'
Assert-StableBundle ($Matches.hash.ToLowerInvariant() -ceq $indexHash) 'release-index sidecar verifies'
$sumLines = @(Get-Content -LiteralPath $sumsPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
Assert-StableBundle ($sumLines.Count -eq ($records.Count + 2)) 'SHA256SUMS contains exactly every artifact, release-index, and signature'
$sumSeen = @{}
foreach ($line in $sumLines) {
    $text = ([string]$line).Trim()
    Assert-StableBundle ($text -match '^(?<hash>[0-9a-fA-F]{64})  (?<name>[^/\\\r\n]+)$') "SHA256SUMS line is canonical: $text"
    $sumName = [string]$Matches.name
    Assert-StableBundle (-not $sumSeen.ContainsKey($sumName.ToLowerInvariant())) "SHA256SUMS names are unique: $sumName"
    $sumSeen[$sumName.ToLowerInvariant()] = $true
    Assert-StableBundle ($sumName -in @('release-index.json', 'release-index.json.sig') -or $recordByName.ContainsKey($sumName.ToLowerInvariant())) "SHA256SUMS name is an indexed artifact, release-index, or signature: $sumName"
    $sumPath = Join-Path $BundleRoot $sumName
    Assert-StableBundle (Test-Path -LiteralPath $sumPath -PathType Leaf) "SHA256SUMS target exists: $sumName"
    $sumHash = Get-StableSha256 -Path $sumPath -Description "SHA256SUMS target $sumName"
    Assert-StableBundle ($sumHash -ceq $Matches.hash.ToLowerInvariant()) "SHA256SUMS verifies: $sumName"
}
foreach ($expectedName in @($records | ForEach-Object { [string]$_.name }) + @('release-index.json', 'release-index.json.sig')) {
    Assert-StableBundle ($sumSeen.ContainsKey($expectedName.ToLowerInvariant())) "SHA256SUMS includes: $expectedName"
}

$expectedFiles = @{}
foreach ($record in $records) {
    $expectedFiles[[string]$record.name.ToLowerInvariant()] = $true
    $expectedFiles[[string]$record.sidecar.ToLowerInvariant()] = $true
}
foreach ($metadataName in @('release-index.json', 'release-index.json.sha256', 'release-index.json.sig', 'SHA256SUMS', $provenanceBundleName)) {
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
    indexSignature = $indexSignature
    publishableAssets = @(
        @($records | ForEach-Object { [string]$_.name }) +
        @($records | ForEach-Object { [string]$_.sidecar }) +
        @('release-index.json', 'release-index.json.sha256', 'release-index.json.sig', 'SHA256SUMS')
    )
}
if ($Json) {
    $result | ConvertTo-Json -Depth 8 -Compress
} else {
    $result
}
