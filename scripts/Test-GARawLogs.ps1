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

function Test-RawLogGlobalAddress {
    param([Parameter(Mandatory = $true)][System.Net.IPAddress]$Address)

    if ([System.Net.IPAddress]::IsLoopback($Address)) { return $false }
    if ($Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6 -and $Address.IsIPv4MappedToIPv6) {
        return Test-RawLogGlobalAddress -Address $Address.MapToIPv4()
    }
    if ($Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        $bytes = $Address.GetAddressBytes()
        $first = [int]$bytes[0]
        $second = [int]$bytes[1]
        if ($first -eq 0 -or $first -eq 10 -or $first -eq 127 -or $first -ge 224) { return $false }
        if ($first -eq 100 -and $second -ge 64 -and $second -le 127) { return $false }
        if ($first -eq 169 -and $second -eq 254) { return $false }
        if ($first -eq 172 -and $second -ge 16 -and $second -le 31) { return $false }
        if ($first -eq 192 -and ($second -eq 0 -or $second -eq 168)) { return $false }
        if ($first -eq 198 -and ($second -eq 18 -or $second -eq 19)) { return $false }
        if ($first -eq 203 -and $second -eq 0 -and $bytes[2] -eq 113) { return $false }
        return $true
    }

    $bytes = $Address.GetAddressBytes()
    if ($bytes.Length -eq 16) {
        # ff00::/8 (multicast), fe80::/10 (link-local), fc00::/7 (ULA),
        # fec0::/10 (site-local), 2001:db8::/32 (documentation), and ::/128.
        if ($bytes[0] -eq 0xff) { return $false }
        if ($bytes[0] -eq 0xfe -and ($bytes[1] -band 0xc0) -eq 0x80) { return $false }
        if ($bytes[0] -eq 0xfe -and ($bytes[1] -band 0xc0) -eq 0xc0) { return $false }
        if (($bytes[0] -band 0xfe) -eq 0xfc) { return $false }
        if ($bytes[0] -eq 0x20 -and $bytes[1] -eq 0x01 -and $bytes[2] -eq 0x0d -and $bytes[3] -eq 0xb8) { return $false }
        $allZero = $true
        foreach ($byte in $bytes) { if ($byte -ne 0) { $allZero = $false; break } }
        if ($allZero) { return $false }
    }
    return $true
}

function Assert-RawLogExternalHost {
    param([Parameter(Mandatory = $true)][string]$Url)

    $uri = $null
    Assert-RawLogCondition ([System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri)) 'raw log URL parses as an absolute URI'
    Assert-RawLogCondition ($uri.Scheme.Equals('https', [System.StringComparison]::OrdinalIgnoreCase)) 'raw log URL uses HTTPS'
    Assert-RawLogCondition ([string]::IsNullOrWhiteSpace($uri.UserInfo)) 'raw log URL has no embedded credentials'
    Assert-RawLogCondition ([string]::IsNullOrWhiteSpace($uri.Fragment)) 'raw log URL must not contain a fragment'
    $hostName = $uri.DnsSafeHost
    Assert-RawLogCondition (-not [string]::IsNullOrWhiteSpace($hostName)) 'raw log URL has a DNS host'
    try {
        $addresses = @([System.Net.Dns]::GetHostAddresses($hostName))
    } catch {
        throw "GA raw-log assertion failed: raw log host DNS resolution failed for '$hostName': $($_.Exception.Message)"
    }
    Assert-RawLogCondition ($addresses.Count -gt 0) "raw log host resolves to at least one address: $hostName"
    foreach ($address in $addresses) {
        Assert-RawLogCondition (Test-RawLogGlobalAddress -Address $address) "raw log host resolves only to globally routable addresses (host='$hostName', address='$address')"
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
    Assert-RawLogExternalHost -Url ([string]$Uri.AbsoluteUri)
    $request = [Net.HttpWebRequest]::Create($Uri)
    $request.Method = 'GET'
    $request.AllowAutoRedirect = $false
    $request.Timeout = 300000
    $request.ReadWriteTimeout = 300000
    $request.MaximumResponseHeadersLength = 64
    $response = $null
    $inputStream = $null
    $outputStream = $null
    $temporaryPath = $null
    $moved = $false
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
        $destinationPath = [IO.Path]::GetFullPath($Destination)
        $destinationDirectory = [IO.Path]::GetDirectoryName($destinationPath)
        Assert-RawLogCondition (-not [string]::IsNullOrWhiteSpace($destinationDirectory)) 'raw log destination has a parent directory'
        Assert-RawLogCondition (Test-Path -LiteralPath $destinationDirectory -PathType Container) "raw log destination directory exists: $destinationDirectory"
        $destinationDirectoryItem = Get-Item -LiteralPath $destinationDirectory -Force
        Assert-RawLogCondition (($destinationDirectoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "raw log destination directory is not a reparse point: $destinationDirectory"
        if (Test-Path -LiteralPath $destinationPath) {
            $existingDestination = Get-Item -LiteralPath $destinationPath -Force
            Assert-RawLogCondition (($existingDestination.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and -not $existingDestination.PSIsContainer) "raw log destination is not a reparse point or directory: $destinationPath"
            throw "GA raw-log assertion failed: refusing to overwrite an existing raw log destination: $destinationPath"
        }

        # Download into a fresh same-directory file and atomically rename it.
        # CreateNew plus a final existence check prevents an attacker from
        # replacing an evidence path with a symlink/reparse point between the
        # initial validation and the write/rename.
        $leaf = [IO.Path]::GetFileName($destinationPath)
        for ($attempt = 0; $attempt -lt 5; $attempt++) {
            $candidate = Join-Path $destinationDirectory ('.' + $leaf + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
            if (-not (Test-Path -LiteralPath $candidate)) {
                $temporaryPath = $candidate
                break
            }
        }
        Assert-RawLogCondition (-not [string]::IsNullOrWhiteSpace($temporaryPath)) 'raw log temporary destination is available'
        $inputStream = $response.GetResponseStream()
        $outputStream = [IO.File]::Open(
            $temporaryPath,
            [IO.FileMode]::CreateNew,
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
        $outputStream.Dispose()
        $outputStream = $null
        if (Test-Path -LiteralPath $destinationPath) {
            $racedDestination = Get-Item -LiteralPath $destinationPath -Force
            Assert-RawLogCondition (($racedDestination.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and -not $racedDestination.PSIsContainer) "raw log destination appeared as a normal file during download: $destinationPath"
            throw "GA raw-log assertion failed: raw log destination appeared during download: $destinationPath"
        }
        [IO.File]::Move($temporaryPath, $destinationPath)
        $moved = $true
        return $total
    } finally {
        if ($null -ne $outputStream) { $outputStream.Dispose() }
        if (-not $moved -and $null -ne $temporaryPath -and (Test-Path -LiteralPath $temporaryPath)) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne $inputStream) { $inputStream.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
    }
}

function Write-RawLogAtomicText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][System.Text.Encoding]$Encoding
    )

    $destinationPath = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($destinationPath)
    Assert-RawLogCondition (-not [string]::IsNullOrWhiteSpace($directory) -and (Test-Path -LiteralPath $directory -PathType Container)) "atomic output directory exists: $directory"
    $directoryItem = Get-Item -LiteralPath $directory -Force
    Assert-RawLogCondition (($directoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "atomic output directory is not a reparse point: $directory"
    if (Test-Path -LiteralPath $destinationPath) {
        $existing = Get-Item -LiteralPath $destinationPath -Force
        Assert-RawLogCondition (($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and -not $existing.PSIsContainer) "atomic output target is not a reparse point or directory: $destinationPath"
        throw "GA raw-log assertion failed: refusing to overwrite an existing output target: $destinationPath"
    }

    $leaf = [IO.Path]::GetFileName($destinationPath)
    $temporaryPath = Join-Path $directory ('.' + $leaf + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $moved = $false
    try {
        [IO.File]::WriteAllText($temporaryPath, $Text, $Encoding)
        if (Test-Path -LiteralPath $destinationPath) {
            throw "GA raw-log assertion failed: output target appeared during atomic write: $destinationPath"
        }
        [IO.File]::Move($temporaryPath, $destinationPath)
        $moved = $true
    } finally {
        if (-not $moved -and (Test-Path -LiteralPath $temporaryPath)) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
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
    Write-RawLogAtomicText `
        -Path (Join-Path $outputRoot "$evidenceId.verification.json") `
        -Text ($record | ConvertTo-Json -Depth 8) `
        -Encoding (New-Object System.Text.UTF8Encoding($false))
    [void]$records.Add($record)
}

$result = [ordered]@{
    schemaVersion = 'cyc.dev/ga-raw-log-verification/v1'
    status = 'passed'
    sourceCommit = $ExpectedCommit.ToLowerInvariant()
    records = $records.ToArray()
}
$resultJson = $result | ConvertTo-Json -Depth 10 -Compress
Write-RawLogAtomicText `
    -Path (Join-Path $outputRoot 'raw-log-verification.json') `
    -Text $resultJson `
    -Encoding (New-Object System.Text.UTF8Encoding($false))
$resultJson
