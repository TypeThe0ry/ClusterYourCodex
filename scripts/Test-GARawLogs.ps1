#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EvidencePath,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [Parameter(Mandatory = $true)][string]$ExpectedCommit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$MaximumRawLogBytes = 64MB

function Assert-RawLogCondition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw "GA raw-log assertion failed: $Message"
    }
}

function Get-RawLogProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )
    $current = $Object
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $current) {
            throw "GA raw-log assertion failed: $Description is missing '$Path'."
        }
        $property = $current.PSObject.Properties[$part]
        if ($null -eq $property) {
            throw "GA raw-log assertion failed: $Description is missing '$Path'."
        }
        $current = $property.Value
    }
    return $current
}

function Get-RawLogJson {
    param([Parameter(Mandatory = $true)][string]$Path)

    Assert-RawLogCondition (Test-Path -LiteralPath $Path -PathType Leaf) "evidence manifest exists: $Path"
    $item = Get-Item -LiteralPath $Path -Force
    Assert-RawLogCondition (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "evidence manifest is not a reparse point: $Path"
    Assert-RawLogCondition ([long]$item.Length -le [long]$MaximumRawLogBytes) 'evidence manifest is within the 64 MiB limit'
    try {
        return [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    } catch {
        throw "GA raw-log assertion failed: evidence manifest is not valid JSON: $($_.Exception.Message)"
    }
}

function Save-RawLogFromHttps {
    param(
        [Parameter(Mandatory = $true)][Uri]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    # Do not follow an unvalidated redirect to a different host or scheme. The
    # evidence URL is expected to be the canonical HTTPS object itself.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $request = [Net.HttpWebRequest]::Create($Uri)
    $request.Method = 'GET'
    $request.AllowAutoRedirect = $false
    $request.Timeout = 300000
    $request.ReadWriteTimeout = 300000
    $request.MaximumResponseHeadersLength = 64
    $response = $null
    $inputStream = $null
    $outputStream = $null
    try {
        try {
            $response = [Net.HttpWebResponse]$request.GetResponse()
        } catch [Net.WebException] {
            $webResponse = $_.Exception.Response
            if ($null -ne $webResponse) {
                throw "raw log URL returned HTTP status $([int]$webResponse.StatusCode)"
            }
            throw "raw log URL request failed: $($_.Exception.Message)"
        }
        Assert-RawLogCondition ($response.StatusCode -eq [Net.HttpStatusCode]::OK) "raw log URL returned HTTP $([int]$response.StatusCode)"
        if ($response.ContentLength -ge 0) {
            Assert-RawLogCondition ([long]$response.ContentLength -le [long]$MaximumRawLogBytes) 'raw log Content-Length is within the 64 MiB limit'
        }
        $inputStream = $response.GetResponseStream()
        $outputStream = [IO.File]::Open(
            $Destination,
            [IO.FileMode]::Create,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        $buffer = New-Object byte[] 65536
        [long]$total = 0
        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $total += $read
            Assert-RawLogCondition ($total -le [long]$MaximumRawLogBytes) 'downloaded raw log exceeds the 64 MiB limit'
            $outputStream.Write($buffer, 0, $read)
        }
        $outputStream.Flush()
        return $total
    } finally {
        if ($null -ne $outputStream) { $outputStream.Dispose() }
        if ($null -ne $inputStream) { $inputStream.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
    }
}

Assert-RawLogCondition ($ExpectedCommit -match '^[0-9a-fA-F]{40}$') 'ExpectedCommit must be a full 40-character SHA'
$evidence = Get-RawLogJson -Path $EvidencePath
Assert-RawLogCondition ([string]$evidence.schemaVersion -ceq 'cyc.dev/ga-evidence/v1') 'evidence schemaVersion is v1'
Assert-RawLogCondition ([string]$evidence.status -ceq 'passed') 'evidence status is passed'
$manifestCommit = [string](Get-RawLogProperty -Object $evidence -Path 'sourceCommit' -Description 'evidence manifest')
Assert-RawLogCondition ($manifestCommit -match '^[0-9a-fA-F]{40}$' -and
    $manifestCommit.Equals($ExpectedCommit, [StringComparison]::OrdinalIgnoreCase)) 'evidence sourceCommit matches ExpectedCommit'

$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $outputRoot) {
    $rootItem = Get-Item -LiteralPath $outputRoot -Force
    Assert-RawLogCondition ($rootItem.PSIsContainer -and ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "raw-log output directory is a normal directory: $outputRoot"
} else {
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
}

$records = New-Object System.Collections.Generic.List[object]
$seenIds = @{}
$seenUrls = @{}
foreach ($issueName in @('issue2', 'issue3', 'issue5')) {
    $issue = Get-RawLogProperty -Object $evidence -Path $issueName -Description 'evidence manifest'
    $evidenceId = [string](Get-RawLogProperty -Object $issue -Path 'evidenceId' -Description $issueName)
    # The evidence ID is used as a filename below. Reject separators and
    # traversal syntax before constructing any path from the external manifest.
    Assert-RawLogCondition ($evidenceId -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') "$issueName.evidenceId is a bounded portable filename"
    Assert-RawLogCondition (-not $seenIds.ContainsKey($evidenceId)) "evidenceId is unique: $evidenceId"
    $seenIds[$evidenceId] = $true

    $rawLog = Get-RawLogProperty -Object $issue -Path 'rawLog' -Description $issueName
    $urlText = [string](Get-RawLogProperty -Object $rawLog -Path 'url' -Description $issueName)
    $uri = $null
    Assert-RawLogCondition ([Uri]::TryCreate($urlText, [UriKind]::Absolute, [ref]$uri)) "$issueName.rawLog.url is an absolute URL"
    Assert-RawLogCondition ($uri.Scheme.Equals('https', [StringComparison]::OrdinalIgnoreCase)) "$issueName.rawLog.url uses HTTPS"
    Assert-RawLogCondition (-not [string]::IsNullOrWhiteSpace($uri.Host) -and [string]::IsNullOrWhiteSpace($uri.UserInfo)) "$issueName.rawLog.url has a host and no embedded credentials"
    Assert-RawLogCondition (-not $seenUrls.ContainsKey($uri.AbsoluteUri)) "raw log URL is unique: $urlText"
    $seenUrls[$uri.AbsoluteUri] = $true
    $expectedHash = [string](Get-RawLogProperty -Object $rawLog -Path 'sha256' -Description $issueName)
    Assert-RawLogCondition ($expectedHash -match '^[0-9a-fA-F]{64}$') "$issueName.rawLog.sha256 is a SHA-256 digest"

    $logPath = Join-Path $outputRoot "$evidenceId.log"
    [long]$bytes = Save-RawLogFromHttps -Uri $uri -Destination $logPath
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $logPath).Hash.ToLowerInvariant()
    Assert-RawLogCondition ($actualHash -ceq $expectedHash.ToLowerInvariant()) "$issueName raw log bytes match rawLog.sha256"
    $record = [ordered]@{
        issue = $issueName
        evidenceId = $evidenceId
        url = $urlText
        expectedSha256 = $expectedHash.ToLowerInvariant()
        actualSha256 = $actualHash
        bytes = $bytes
        path = $logPath
        status = 'passed'
    }
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $outputRoot "$evidenceId.verification.json") -Encoding UTF8
    [void]$records.Add($record)
}

$result = [ordered]@{
    schemaVersion = 'cyc.dev/ga-raw-log-verification/v1'
    status = 'passed'
    sourceCommit = $ExpectedCommit.ToLowerInvariant()
    records = $records.ToArray()
}
$resultJson = $result | ConvertTo-Json -Depth 10 -Compress
$resultJson | Set-Content -LiteralPath (Join-Path $outputRoot 'raw-log-verification.json') -Encoding UTF8
$resultJson
