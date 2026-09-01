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

# Issue #5 evidence is a three-host matrix.  These constants intentionally
# mirror Test-GAReadiness.ps1: the downloader validates the manifest before it
# makes a request, then validates the retained bytes against the exact marker
# set.  A generic Linux ``cargo test --workspace --locked`` log consequently
# cannot be relabelled as Windows, macOS, or restart evidence.
$GaIssue5Platforms = @('linux', 'windows', 'macos')
$GaIssue5MatrixGateNames = @(
    'jobsCannotAlterGuardState',
    'jobsCannotReadWorkerCredentials',
    'restartResidualProcessReconciliation'
)
$GaIssue5PlatformGateNames = [ordered]@{
    linux = @(
        'linuxDedicatedExecutionIdentity',
        'linuxCgroupV2Reconciliation'
    )
    windows = @(
        'windowsIsolatedExecutionIdentity',
        'windowsJobObject',
        'windowsProtectedExternalGuard'
    )
    macos = @('macosExternalReconciliation')
}
$GaIssue5AllGateNames = @(
    'linuxDedicatedExecutionIdentity',
    'linuxCgroupV2Reconciliation',
    'windowsIsolatedExecutionIdentity',
    'windowsJobObject',
    'windowsProtectedExternalGuard',
    'macosExternalReconciliation',
    'jobsCannotAlterGuardState',
    'jobsCannotReadWorkerCredentials',
    'restartResidualProcessReconciliation'
)
$GaIssue5ExpectedSelectors = [ordered]@{
    linux = 'isolation::tests::linux_live_dedicated_identity_credential_and_residual_reconciliation'
    windows = 'isolation::tests::windows_external_json_contract_is_fail_closed_at_every_runtime_gate'
    macos = 'isolation::tests::macos_external_reconciliation_is_fail_closed_at_every_runtime_gate'
}
$GaIssue5AggregateCommand = 'issue5-evidence-matrix'
$GaIssue5GateExpectedPlatforms = [ordered]@{
    linuxDedicatedExecutionIdentity = @('linux')
    linuxCgroupV2Reconciliation = @('linux')
    windowsIsolatedExecutionIdentity = @('windows')
    windowsJobObject = @('windows')
    windowsProtectedExternalGuard = @('windows')
    macosExternalReconciliation = @('macos')
    jobsCannotAlterGuardState = @('linux', 'windows', 'macos')
    jobsCannotReadWorkerCredentials = @('linux', 'windows', 'macos')
    restartResidualProcessReconciliation = @('linux', 'windows', 'macos')
}
$GaIssue5RequiredMarkerPrefixes = [ordered]@{
    linuxDedicatedExecutionIdentity = @('uid=', 'gid=')
    linuxCgroupV2Reconciliation = @('cgroup_escape=blocked', 'cgroup.threads_escape=blocked')
}
$GaIssue5AnyMarkerPrefixes = [ordered]@{
    restartResidualProcessReconciliation = @('residual_empty', 'residualCgroupVerified=1', 'residualIdentityProcessesVerified=1')
}
$GaIssue5RunIdentifierPattern = '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'
$GaIssue5IsoInstantPattern = '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^\s]+(Z|[+-][0-9]{2}:[0-9]{2})$'

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

function Get-RawLogOptionalProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Assert-RawLogIssue5RunProvenance {
    param(
        [Parameter(Mandatory = $true)][object]$Run,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-RawLogCondition (($Run -is [pscustomobject]) -and -not ($Run -is [System.Array])) "$Description is a JSON object"
    foreach ($required in @('runId', 'node', 'provider', 'hostType', 'status', 'exitCode', 'tests', 'startedAt', 'endedAt')) {
        Assert-RawLogCondition ($null -ne $Run.PSObject.Properties[$required]) "$Description.$required is required for source-bound run provenance"
    }

    $runIdValue = Get-RawLogProperty -Object $Run -Path 'runId' -Description $Description
    Assert-RawLogCondition ($runIdValue -is [string]) "$Description.runId is a JSON string"
    $runId = [string]$runIdValue
    Assert-RawLogCondition ($runId -match $GaIssue5RunIdentifierPattern) "$Description.runId is a bounded portable run identifier"
    $nodeValue = Get-RawLogProperty -Object $Run -Path 'node' -Description $Description
    Assert-RawLogCondition ($nodeValue -is [string]) "$Description.node is a JSON string"
    $node = [string]$nodeValue
    Assert-RawLogCondition ($node -match $GaIssue5RunIdentifierPattern) "$Description.node is a bounded portable node identifier"
    Assert-RawLogCondition ($node -notmatch '(?i)github|actions|hosted|runner') "$Description.node does not identify a GitHub-hosted execution surface"
    $providerValue = Get-RawLogProperty -Object $Run -Path 'provider' -Description $Description
    $hostTypeValue = Get-RawLogProperty -Object $Run -Path 'hostType' -Description $Description
    Assert-RawLogCondition ($providerValue -is [string]) "$Description.provider is a JSON string"
    Assert-RawLogCondition ($hostTypeValue -is [string]) "$Description.hostType is a JSON string"
    $provider = [string]$providerValue
    $hostType = [string]$hostTypeValue
    foreach ($field in @('provider', 'hostType')) {
        $value = if ($field -ceq 'provider') { $provider } else { $hostType }
        Assert-RawLogCondition (-not [string]::IsNullOrWhiteSpace($value)) "$Description.$field is a non-empty external identifier"
        Assert-RawLogCondition ($value -notmatch '(?i)github|actions|hosted|runner') "$Description.$field does not identify a GitHub-hosted execution surface"
    }

    $status = Get-RawLogProperty -Object $Run -Path 'status' -Description $Description
    $statusPassed = (($status -is [string]) -and ([string]$status).Equals('passed', [StringComparison]::Ordinal)) -or (($status -is [bool]) -and $status)
    Assert-RawLogCondition $statusPassed "$Description.status is 'passed' (or boolean true for a single-gate record)"

    $exitCode = Get-RawLogProperty -Object $Run -Path 'exitCode' -Description $Description
    $isInteger = ($exitCode -is [byte]) -or ($exitCode -is [sbyte]) -or ($exitCode -is [int16]) -or ($exitCode -is [uint16]) -or ($exitCode -is [int32]) -or ($exitCode -is [uint32]) -or ($exitCode -is [int64]) -or ($exitCode -is [uint64])
    Assert-RawLogCondition ($isInteger -and ([int64]$exitCode -eq 0)) "$Description.exitCode is integer zero"

    $tests = Get-RawLogProperty -Object $Run -Path 'tests' -Description $Description
    Assert-RawLogCondition (($tests -is [pscustomobject]) -and -not ($tests -is [System.Array])) "$Description.tests is a JSON object"
    foreach ($countName in @('passed', 'failed', 'ignored')) {
        Assert-RawLogCondition ($null -ne $tests.PSObject.Properties[$countName]) "$Description.tests.$countName is required"
        $count = $tests.PSObject.Properties[$countName].Value
        $countIsInteger = ($count -is [byte]) -or ($count -is [sbyte]) -or ($count -is [int16]) -or ($count -is [uint16]) -or ($count -is [int32]) -or ($count -is [uint32]) -or ($count -is [int64]) -or ($count -is [uint64])
        Assert-RawLogCondition ($countIsInteger -and ([int64]$count -ge 0)) "$Description.tests.$countName is a non-negative integer"
    }
    Assert-RawLogCondition ([int64]$tests.PSObject.Properties['passed'].Value -gt 0) "$Description.tests.passed is greater than zero"
    Assert-RawLogCondition ([int64]$tests.PSObject.Properties['failed'].Value -eq 0) "$Description.tests.failed is zero"

    $startedValue = Get-RawLogProperty -Object $Run -Path 'startedAt' -Description $Description
    $endedValue = Get-RawLogProperty -Object $Run -Path 'endedAt' -Description $Description
    Assert-RawLogCondition ($startedValue -is [string] -or $startedValue -is [DateTime] -or $startedValue -is [DateTimeOffset]) "$Description.startedAt is an ISO-8601 instant with an explicit timezone"
    Assert-RawLogCondition ($endedValue -is [string] -or $endedValue -is [DateTime] -or $endedValue -is [DateTimeOffset]) "$Description.endedAt is an ISO-8601 instant with an explicit timezone"
    try {
        if ($startedValue -is [DateTimeOffset]) {
            $startedAt = [DateTimeOffset]$startedValue
        } elseif ($startedValue -is [DateTime]) {
            Assert-RawLogCondition ($startedValue.Kind -ne [DateTimeKind]::Unspecified) "$Description.startedAt carries an explicit UTC offset"
            $startedAt = [DateTimeOffset]$startedValue
        } else {
            $startedText = [string]$startedValue
            Assert-RawLogCondition ($startedText -match $GaIssue5IsoInstantPattern) "$Description.startedAt includes a UTC designator or numeric offset"
            $startedAt = [DateTimeOffset]::Parse($startedText, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        }
        if ($endedValue -is [DateTimeOffset]) {
            $endedAt = [DateTimeOffset]$endedValue
        } elseif ($endedValue -is [DateTime]) {
            Assert-RawLogCondition ($endedValue.Kind -ne [DateTimeKind]::Unspecified) "$Description.endedAt carries an explicit UTC offset"
            $endedAt = [DateTimeOffset]$endedValue
        } else {
            $endedText = [string]$endedValue
            Assert-RawLogCondition ($endedText -match $GaIssue5IsoInstantPattern) "$Description.endedAt includes a UTC designator or numeric offset"
            $endedAt = [DateTimeOffset]::Parse($endedText, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        }
    } catch {
        throw "GA raw-log assertion failed: $Description timestamps are not parseable ISO-8601 instants."
    }
    Assert-RawLogCondition ($endedAt -ge $startedAt) "$Description.endedAt does not precede startedAt"

    return [pscustomobject]@{
        runId = $runId
        node = $node
        provider = $provider
        hostType = $hostType
        status = 'passed'
        exitCode = [int64]$exitCode
        tests = $tests
        startedAt = $startedAt.ToUniversalTime().ToString('yyyy-MM-dd''T''HH:mm:ss.fffffffzzz', [Globalization.CultureInfo]::InvariantCulture)
        endedAt = $endedAt.ToUniversalTime().ToString('yyyy-MM-dd''T''HH:mm:ss.fffffffzzz', [Globalization.CultureInfo]::InvariantCulture)
    }
}

function Assert-RawLogIssue5RunPlatformBinding {
    param(
        [Parameter(Mandatory = $true)][hashtable]$RunPlatformMap,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Platform,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ($RunPlatformMap.ContainsKey($RunId)) {
        Assert-RawLogCondition ([string]$RunPlatformMap[$RunId] -ceq $Platform) "$Description.runId '$RunId' remains bound to platform '$($RunPlatformMap[$RunId])', not '$Platform'"
    } else {
        $RunPlatformMap[$RunId] = $Platform
    }
}

function Get-RawLogIssue5RunSelector {
    param(
        [Parameter(Mandatory = $true)][object]$Run,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $canonicalProperty = $Run.PSObject.Properties['testSelector']
    $aliasProperty = $Run.PSObject.Properties['selector']
    $hasCanonical = $null -ne $canonicalProperty
    $hasAlias = $null -ne $aliasProperty
    if ($hasCanonical -and $hasAlias) {
        Assert-RawLogCondition ($canonicalProperty.Value -is [string] -and $aliasProperty.Value -is [string]) "$Description.testSelector and selector must both be strings when both are present"
        Assert-RawLogCondition ([string]$canonicalProperty.Value -ceq [string]$aliasProperty.Value) "$Description.testSelector and selector aliases must match exactly"
    }
    $selector = if ($hasCanonical) { $canonicalProperty.Value } else { Get-RawLogOptionalProperty -Object $Run -Name 'selector' }
    Assert-RawLogCondition ($selector -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$selector)) "$Description.testSelector is a non-empty string"
    return [string]$selector
}

function Normalize-RawLogIssue5Command {
    param([Parameter(Mandatory = $true)][string]$Command)

    return [regex]::Replace($Command.Trim(), '\s+', ' ')
}

function Get-RawLogIssue5CommandSha256 {
    param([Parameter(Mandatory = $true)][string]$Command)

    $sha = New-Object System.Security.Cryptography.SHA256Managed
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes((Normalize-RawLogIssue5Command -Command $Command))
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-RawLogIssue5Marker {
    param(
        [Parameter(Mandatory = $true)][string]$Platform,
        [Parameter(Mandatory = $true)][string]$Selector,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$Gate
    )

    $commandDigest = Get-RawLogIssue5CommandSha256 -Command $Command
    return "CYC-GA-ISSUE5|platform=$($Platform.ToLowerInvariant())|selector=$Selector|commandSha256=$commandDigest|gate=$Gate|status=passed"
}

function Assert-RawLogIssue5RunCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Platform,
        [Parameter(Mandatory = $true)][string]$Selector,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $normalized = Normalize-RawLogIssue5Command -Command $Command
    $manifestToken = '(?:"[^"]*Cargo\.toml"|''[^'']*Cargo\.toml''|\S*Cargo\.toml)'
    $tail = if ($Platform -ceq 'linux') {
        '--ignored\s+--exact\s+--nocapture'
    } else {
        '--exact\s+--nocapture'
    }
    $pattern = '^cargo(?:\.exe)?\s+test\s+--manifest-path\s+' + $manifestToken +
        '\s+-p\s+cyc-worker\s+--lib\s+--locked\s+--\s+' + $tail +
        '\s+' + [regex]::Escape($Selector) + '$'
    Assert-RawLogCondition ($normalized -match $pattern) "$Description.command is the exact locked cyc-worker selector for platform '$Platform'"
    Assert-RawLogCondition ($normalized -notmatch '(?i)(?:^|\s)--workspace(?:\s|$)') "$Description.command is not a workspace-wide generic test command"
}

function Get-RawLogIssue5GateMarkers {
    param(
        [Parameter(Mandatory = $true)][object]$GateEvidence,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $canonicalProperty = $GateEvidence.PSObject.Properties['rawLogMarkers']
    $aliasProperty = $GateEvidence.PSObject.Properties['markers']
    if ($null -ne $canonicalProperty -and $null -ne $aliasProperty) {
        Assert-RawLogCondition (($canonicalProperty.Value -is [System.Array]) -and ($aliasProperty.Value -is [System.Array])) "$Description.rawLogMarkers and markers must both be arrays when both are present"
        $canonicalMarkers = @($canonicalProperty.Value | ForEach-Object { [string]$_ })
        $aliasMarkers = @($aliasProperty.Value | ForEach-Object { [string]$_ })
        Assert-RawLogCondition ($canonicalMarkers.Count -eq $aliasMarkers.Count) "$Description.rawLogMarkers and markers aliases must have the same length"
        for ($index = 0; $index -lt $canonicalMarkers.Count; $index++) {
            Assert-RawLogCondition ($canonicalMarkers[$index] -ceq $aliasMarkers[$index]) "$Description.rawLogMarkers and markers aliases must match exactly"
        }
    }
    $markerProperty = $canonicalProperty
    if ($null -eq $markerProperty) {
        $markerProperty = $aliasProperty
    }
    if ($null -eq $markerProperty) {
        $markers = $null
    } elseif ($markerProperty.Value -is [System.Array]) {
        $markers = $markerProperty.Value
    } else {
        $markers = @($markerProperty.Value)
    }
    Assert-RawLogCondition (($markers -is [System.Array]) -and $markers.Count -gt 0) "$Description.rawLogMarkers is a non-empty array"
    foreach ($marker in @($markers)) {
        Assert-RawLogCondition ($marker -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$marker)) "$Description.rawLogMarkers entries are non-empty strings"
    }
    return @($markers | ForEach-Object { [string]$_ })
}

function Assert-RawLogIssue5RequiredMarkers {
    param(
        [Parameter(Mandatory = $true)][string[]]$Markers,
        [Parameter(Mandatory = $true)][string]$Gate,
        [Parameter(Mandatory = $true)][string]$Platform,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ($GaIssue5RequiredMarkerPrefixes.Contains($Gate)) {
        foreach ($prefix in @($GaIssue5RequiredMarkerPrefixes[$Gate])) {
            $matched = @($Markers | Where-Object {
                    $candidate = [string]$_
                    $candidate.Equals($prefix, [StringComparison]::Ordinal) -or
                    $candidate.StartsWith($prefix, [StringComparison]::Ordinal)
                })
            Assert-RawLogCondition ($matched.Count -gt 0) "$Description.rawLogMarkers contains a native marker beginning with '$prefix'"
        }
    }
    if ($Platform -ceq 'linux' -and $GaIssue5AnyMarkerPrefixes.Contains($Gate)) {
        $anyMatched = @()
        foreach ($prefix in @($GaIssue5AnyMarkerPrefixes[$Gate])) {
            $anyMatched += @($Markers | Where-Object {
                    $candidate = [string]$_
                    $candidate.Equals($prefix, [StringComparison]::Ordinal) -or
                    $candidate.StartsWith($prefix, [StringComparison]::Ordinal)
                })
        }
        Assert-RawLogCondition ($anyMatched.Count -gt 0) "$Description.rawLogMarkers contains a residual-process reconciliation marker"
    }
}

function Assert-RawLogIssue5SingleGateEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$Gate,
        [Parameter(Mandatory = $true)][object]$GateEvidence,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $false)][hashtable]$RunPlatformMap = $null
    )

    Assert-RawLogCondition (($GateEvidence -is [pscustomobject]) -and -not ($GateEvidence -is [System.Array])) "$Description.gates.$Gate is a structured evidence object, not a bare boolean"
    $provenance = Assert-RawLogIssue5RunProvenance -Run $GateEvidence -Description "$Description.gates.$Gate"
    $status = Get-RawLogProperty -Object $GateEvidence -Path 'status' -Description "$Description.gates.$Gate"
    Assert-RawLogCondition (($status -is [bool]) -and $status) "$Description.gates.$Gate.status is boolean true"
    $platformValue = Get-RawLogProperty -Object $GateEvidence -Path 'platform' -Description "$Description.gates.$Gate"
    Assert-RawLogCondition ($platformValue -is [string]) "$Description.gates.$Gate.platform is a string"
    $platform = ([string]$platformValue).ToLowerInvariant()
    Assert-RawLogCondition ($GaIssue5GateExpectedPlatforms[$Gate].Count -eq 1) "$Description.gates.$Gate has a single-platform contract"
    Assert-RawLogCondition ($platform.Equals([string]$GaIssue5GateExpectedPlatforms[$Gate][0], [StringComparison]::Ordinal)) "$Description.gates.$Gate.platform is '$($GaIssue5GateExpectedPlatforms[$Gate][0])'"
    if ($null -ne $RunPlatformMap) {
        Assert-RawLogIssue5RunPlatformBinding -RunPlatformMap $RunPlatformMap -RunId $provenance.runId -Platform $platform -Description "$Description.gates.$Gate"
    }
    $selector = Get-RawLogIssue5RunSelector -Run $GateEvidence -Description "$Description.gates.$Gate"
    Assert-RawLogCondition ($selector.Equals([string]$GaIssue5ExpectedSelectors[$platform], [StringComparison]::Ordinal)) "$Description.gates.$Gate.testSelector is the exact '$platform' selector"
    $commandValue = Get-RawLogProperty -Object $GateEvidence -Path 'command' -Description "$Description.gates.$Gate"
    Assert-RawLogCondition ($commandValue -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$commandValue)) "$Description.gates.$Gate.command is a non-empty string"
    $command = [string]$commandValue
    Assert-RawLogIssue5RunCommand -Platform $platform -Selector $selector -Command $command -Description "$Description.gates.$Gate"
    $markers = @(Get-RawLogIssue5GateMarkers -GateEvidence $GateEvidence -Description "$Description.gates.$Gate")
    $canonicalMarker = Get-RawLogIssue5Marker -Platform $platform -Selector $selector -Command $command -Gate $Gate
    Assert-RawLogCondition (@($markers | Where-Object { $_ -ceq $canonicalMarker }).Count -eq 1) "$Description.gates.$Gate.rawLogMarkers retains the source-bound platform/selector/command marker"
    Assert-RawLogIssue5RequiredMarkers -Markers $markers -Gate $Gate -Platform $platform -Description "$Description.gates.$Gate"
    return [pscustomobject]@{
        gate = $Gate
        runId = $provenance.runId
        node = $provenance.node
        provider = $provenance.provider
        hostType = $provenance.hostType
        status = $true
        exitCode = $provenance.exitCode
        tests = $provenance.tests
        startedAt = $provenance.startedAt
        endedAt = $provenance.endedAt
        platform = $platform
        selector = $selector
        command = (Normalize-RawLogIssue5Command -Command $command)
        markers = $markers
    }
}

function Assert-RawLogIssue5MatrixGateEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$Gate,
        [Parameter(Mandatory = $true)][object]$GateEvidence,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $false)][hashtable]$RunPlatformMap = $null
    )

    Assert-RawLogCondition (($GateEvidence -is [pscustomobject]) -and -not ($GateEvidence -is [System.Array])) "$Description.gates.$Gate is a structured evidence object, not a bare boolean"
    $status = Get-RawLogProperty -Object $GateEvidence -Path 'status' -Description "$Description.gates.$Gate"
    Assert-RawLogCondition (($status -is [bool]) -and $status) "$Description.gates.$Gate.status is boolean true"
    $platformValues = Get-RawLogProperty -Object $GateEvidence -Path 'platforms' -Description "$Description.gates.$Gate"
    Assert-RawLogCondition (($platformValues -is [System.Array]) -and $platformValues.Count -eq $GaIssue5Platforms.Count) "$Description.gates.$Gate.platforms lists Linux, Windows, and macOS"
    foreach ($platform in $GaIssue5Platforms) {
        Assert-RawLogCondition (@($platformValues | Where-Object { ([string]$_).ToLowerInvariant() -ceq $platform }).Count -eq 1) "$Description.gates.$Gate.platforms contains '$platform' exactly once"
    }

    $runs = Get-RawLogProperty -Object $GateEvidence -Path 'runs' -Description "$Description.gates.$Gate"
    Assert-RawLogCondition (($runs -is [System.Array]) -and $runs.Count -eq $GaIssue5Platforms.Count) "$Description.gates.$Gate.runs contains one run per required platform"
    $seenPlatforms = @{}
    $seenRunIds = @{}
    $allMarkers = New-Object System.Collections.Generic.List[string]
    $runRecords = New-Object System.Collections.Generic.List[object]
    foreach ($run in @($runs)) {
        Assert-RawLogCondition (($run -is [pscustomobject]) -and -not ($run -is [System.Array])) "$Description.gates.$Gate.runs entries are JSON objects"
        $provenance = Assert-RawLogIssue5RunProvenance -Run $run -Description "$Description.gates.$Gate.runs"
        $platformValue = Get-RawLogProperty -Object $run -Path 'platform' -Description "$Description.gates.$Gate.runs"
        Assert-RawLogCondition ($platformValue -is [string]) "$Description.gates.$Gate.runs.platform is a string"
        $platform = ([string]$platformValue).ToLowerInvariant()
        Assert-RawLogCondition ($GaIssue5Platforms -contains $platform) "$Description.gates.$Gate.runs.platform is linux, windows, or macos"
        Assert-RawLogCondition (-not $seenPlatforms.ContainsKey($platform)) "$Description.gates.$Gate.runs.platform entries are unique"
        $seenPlatforms[$platform] = $true
        Assert-RawLogCondition (-not $seenRunIds.ContainsKey($provenance.runId)) "$Description.gates.$Gate.runs.runId entries are unique within the matrix gate"
        $seenRunIds[$provenance.runId] = $true
        if ($null -ne $RunPlatformMap) {
            Assert-RawLogIssue5RunPlatformBinding -RunPlatformMap $RunPlatformMap -RunId $provenance.runId -Platform $platform -Description "$Description.gates.$Gate.runs.$platform"
        }

        $selector = Get-RawLogIssue5RunSelector -Run $run -Description "$Description.gates.$Gate.runs.$platform"
        Assert-RawLogCondition ($selector.Equals([string]$GaIssue5ExpectedSelectors[$platform], [StringComparison]::Ordinal)) "$Description.gates.$Gate.runs.$platform.testSelector is the exact '$platform' selector"
        $commandValue = Get-RawLogProperty -Object $run -Path 'command' -Description "$Description.gates.$Gate.runs.$platform"
        Assert-RawLogCondition ($commandValue -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$commandValue)) "$Description.gates.$Gate.runs.$platform.command is a non-empty string"
        $command = [string]$commandValue
        Assert-RawLogIssue5RunCommand -Platform $platform -Selector $selector -Command $command -Description "$Description.gates.$Gate.runs.$platform"

        $markers = @(Get-RawLogIssue5GateMarkers -GateEvidence $run -Description "$Description.gates.$Gate.runs.$platform")
        $canonicalMarker = Get-RawLogIssue5Marker -Platform $platform -Selector $selector -Command $command -Gate $Gate
        Assert-RawLogCondition (@($markers | Where-Object { $_ -ceq $canonicalMarker }).Count -eq 1) "$Description.gates.$Gate.runs.$platform.rawLogMarkers retains the source-bound marker"
        Assert-RawLogIssue5RequiredMarkers -Markers $markers -Gate $Gate -Platform $platform -Description "$Description.gates.$Gate.runs.$platform"
        foreach ($marker in $markers) {
            if (-not (@($allMarkers | Where-Object { $_ -ceq $marker }).Count -gt 0)) {
                [void]$allMarkers.Add([string]$marker)
            }
        }
        [void]$runRecords.Add([pscustomobject]@{
                runId = $provenance.runId
                node = $provenance.node
                provider = $provenance.provider
                hostType = $provenance.hostType
                status = $provenance.status
                exitCode = $provenance.exitCode
                tests = $provenance.tests
                startedAt = $provenance.startedAt
                endedAt = $provenance.endedAt
                platform = $platform
                selector = $selector
                command = (Normalize-RawLogIssue5Command -Command $command)
                markers = $markers
            })
    }
    Assert-RawLogCondition ($seenPlatforms.Count -eq $GaIssue5Platforms.Count) "$Description.gates.$Gate.runs covers all required platforms"

    $gateMarkers = @(Get-RawLogIssue5GateMarkers -GateEvidence $GateEvidence -Description "$Description.gates.$Gate")
    foreach ($marker in $allMarkers) {
        Assert-RawLogCondition (@($gateMarkers | Where-Object { $_ -ceq $marker }).Count -eq 1) "$Description.gates.$Gate.rawLogMarkers retains each platform marker"
    }
    Assert-RawLogIssue5RequiredMarkers -Markers $gateMarkers -Gate $Gate -Platform 'multi-platform' -Description "$Description.gates.$Gate"
    return [pscustomobject]@{
        gate = $Gate
        status = $true
        platforms = @($GaIssue5Platforms)
        markers = $gateMarkers
        runs = $runRecords.ToArray()
    }
}

function Assert-RawLogIssue5Evidence {
    param(
        [Parameter(Mandatory = $true)][object]$Issue,
        [Parameter(Mandatory = $true)][string]$Description
    )

    # The gate matrix lives on the Issue #5 record.  Keep the ordinary rawLog
    # descriptor as the source-bound download metadata so issue2/issue3 retain
    # their existing shape while this validator can cross-bind all nine gates.
    $rawLog = Get-RawLogProperty -Object $Issue -Path 'rawLog' -Description $Description
    $aggregateCommand = [string](Get-RawLogProperty -Object $rawLog -Path 'command' -Description $Description)
    Assert-RawLogCondition ($aggregateCommand.Equals($GaIssue5AggregateCommand, [StringComparison]::Ordinal)) "$Description.command equals '$GaIssue5AggregateCommand'"
    Assert-RawLogCondition ($aggregateCommand -notmatch '(?i)(?:^|\s)--workspace(?:\s|$)') "$Description.command is not a workspace-wide generic test command"

    $rawPlatforms = Get-RawLogProperty -Object $rawLog -Path 'platforms' -Description $Description
    Assert-RawLogCondition (($rawPlatforms -is [System.Array]) -and $rawPlatforms.Count -eq $GaIssue5Platforms.Count) "$Description.platforms enumerates Linux, Windows, and macOS exactly once"
    $normalizedRawPlatforms = @($rawPlatforms | ForEach-Object { ([string]$_).ToLowerInvariant() })
    foreach ($platform in $GaIssue5Platforms) {
        Assert-RawLogCondition (@($normalizedRawPlatforms | Where-Object { $_ -ceq $platform }).Count -eq 1) "$Description.platforms contains '$platform' exactly once"
    }

    $gates = Get-RawLogProperty -Object $Issue -Path 'gates' -Description $Description
    Assert-RawLogCondition (($gates -is [pscustomobject]) -and -not ($gates -is [System.Array])) "$Description.gates is a JSON object"
    $gateProperties = @($gates.PSObject.Properties)
    Assert-RawLogCondition ($gateProperties.Count -eq $GaIssue5AllGateNames.Count) "$Description.gates contains exactly the nine Issue #5 gate entries"
    foreach ($gateProperty in $gateProperties) {
        Assert-RawLogCondition ($GaIssue5AllGateNames -contains [string]$gateProperty.Name) "$Description.gates contains only the reviewed Issue #5 gate names"
    }
    $gateRecords = New-Object System.Collections.Generic.List[object]
    $runPlatformMap = @{}
    foreach ($gate in $GaIssue5AllGateNames) {
        $gateProperty = $gates.PSObject.Properties[$gate]
        Assert-RawLogCondition ($null -ne $gateProperty) "$Description.gates.$gate is present"
        $gateEvidence = $gateProperty.Value
        $expectedPlatforms = @($GaIssue5GateExpectedPlatforms[$gate])
        if ($expectedPlatforms.Count -eq 1) {
            [void]$gateRecords.Add((Assert-RawLogIssue5SingleGateEvidence -Gate $gate -GateEvidence $gateEvidence -Description $Description -RunPlatformMap $runPlatformMap))
        } else {
            [void]$gateRecords.Add((Assert-RawLogIssue5MatrixGateEvidence -Gate $gate -GateEvidence $gateEvidence -Description $Description -RunPlatformMap $runPlatformMap))
        }
    }

    $rawMarkers = Get-RawLogProperty -Object $rawLog -Path 'markers' -Description $Description
    Assert-RawLogCondition (($rawMarkers -is [System.Array]) -and $rawMarkers.Count -gt 0) "$Description.markers is a non-empty array"
    $seenRawMarkers = @{}
    foreach ($rawMarker in @($rawMarkers)) {
        Assert-RawLogCondition ($rawMarker -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$rawMarker)) "$Description.markers entries are non-empty strings"
        $rawMarkerText = [string]$rawMarker
        Assert-RawLogCondition (-not $seenRawMarkers.ContainsKey($rawMarkerText)) "$Description.markers entries are unique"
        $seenRawMarkers[$rawMarkerText] = $true
    }
    $expectedMarkers = New-Object System.Collections.Generic.List[string]
    foreach ($gateRecord in $gateRecords.ToArray()) {
        foreach ($marker in @($gateRecord.markers)) {
            if (-not (@($expectedMarkers | Where-Object { [string]$_ -ceq [string]$marker }).Count -gt 0)) {
                [void]$expectedMarkers.Add([string]$marker)
            }
            Assert-RawLogCondition (@($rawMarkers | Where-Object { [string]$_ -ceq [string]$marker }).Count -eq 1) "$Description.markers retains the exact expected marker for '$($gateRecord.gate)'"
        }
    }
    return [pscustomobject]@{
        platforms = @($GaIssue5Platforms)
        markers = $expectedMarkers.ToArray()
        gates = $gateRecords.ToArray()
    }
}

function Assert-RawLogIssue5Markers {
    param(
        [Parameter(Mandatory = $true)][object]$RawLog,
        [Parameter(Mandatory = $true)][string]$LogPath,
        [Parameter(Mandatory = $true)][object]$Contract
    )

    Assert-RawLogCondition (Test-Path -LiteralPath $LogPath -PathType Leaf) "Issue #5 raw log exists for marker validation: $LogPath"
    $logText = [IO.File]::ReadAllText($LogPath)
    foreach ($marker in @($Contract.markers)) {
        Assert-RawLogCondition ($logText.IndexOf([string]$marker, [StringComparison]::Ordinal) -ge 0) "Issue #5 raw log contains retained marker '$marker'"
    }
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

    $issue5Contract = $null
    if ($issueName -ceq 'issue5') {
        $issue5Contract = Assert-RawLogIssue5Evidence -Issue $issue -Description 'issue5'
    }

    $logPath = Join-Path $outputRoot "$evidenceId.log"
    [long]$bytes = Save-RawLogFromHttps -Uri $uri -Destination $logPath
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $logPath).Hash.ToLowerInvariant()
    Assert-RawLogCondition ($actualHash -ceq $expectedHash.ToLowerInvariant()) "$issueName raw log bytes match rawLog.sha256"
    if ($issueName -ceq 'issue5') {
        Assert-RawLogIssue5Markers -RawLog $rawLog -LogPath $logPath -Contract $issue5Contract
    }
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
    if ($issueName -ceq 'issue5') {
        $record.markersVerified = $true
        $record.platforms = $issue5Contract.platforms
        $record.markers = $issue5Contract.markers
        $record.gateEvidence = $issue5Contract.gates
    }
    Write-RawLogAtomicText `
        -Path (Join-Path $outputRoot "$evidenceId.verification.json") `
        -Text ($record | ConvertTo-Json -Depth 20) `
        -Encoding (New-Object System.Text.UTF8Encoding($false))
    [void]$records.Add($record)
}

$result = [ordered]@{
    schemaVersion = 'cyc.dev/ga-raw-log-verification/v1'
    status = 'passed'
    sourceCommit = $ExpectedCommit.ToLowerInvariant()
    records = $records.ToArray()
}
$resultJson = $result | ConvertTo-Json -Depth 20 -Compress
Write-RawLogAtomicText `
    -Path (Join-Path $outputRoot 'raw-log-verification.json') `
    -Text $resultJson `
    -Encoding (New-Object System.Text.UTF8Encoding($false))
$resultJson
