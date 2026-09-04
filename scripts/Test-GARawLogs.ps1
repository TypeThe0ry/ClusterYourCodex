#requires -Version 5.1

[CmdletBinding()]
param(
    # These are required for a real download/verification run, but remain
    # optional at binding time so `-ContractOnly` can exercise the parser
    # contract without touching the filesystem or an external URL.
    [string]$EvidencePath,
    [string]$OutputDirectory,
    [string]$ExpectedCommit,
    [switch]$ContractOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$MaximumRawLogBytes = 64MB
$MaximumRawLogTestCount = [long]1000000000
$GaRawLogContentSchema = 'cyc.dev/ga-raw-log/v1'
$GaIssue3GateContractPath = Join-Path $PSScriptRoot 'ga-issue3-gate-contract.json'
if (-not (Test-Path -LiteralPath $GaIssue3GateContractPath -PathType Leaf)) {
    throw "GA raw-log assertion failed: Issue #3 semantic gate contract is missing: $GaIssue3GateContractPath"
}
try {
    $GaIssue3GateContract = ([System.IO.File]::ReadAllText($GaIssue3GateContractPath) | ConvertFrom-Json)
} catch {
    throw "GA raw-log assertion failed: Issue #3 semantic gate contract is not valid JSON: $($_.Exception.Message)"
}
if ($null -eq $GaIssue3GateContract -or
    [string]$GaIssue3GateContract.schemaVersion -cne 'cyc.dev/ga-issue3-gate-contract/v1' -or
    $null -eq $GaIssue3GateContract.gates -or
    $GaIssue3GateContract.gates -is [System.Array]) {
    throw 'GA raw-log assertion failed: Issue #3 semantic gate contract has an invalid schema.'
}

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
$GaIssue2GateNames = @(
    'tauriDesktopHostTray',
    'rendererNativeControllerProxy',
    'perUserScheduledTasks',
    'sidScopedDataDirAcl',
    'bundledMcpInstallerMarketplace',
    'installRepairUpgradeRollbackUninstall',
    'cleanWindows11Vm',
    'liveWindowsControllerWorkerRoundTrip',
    'productionAuthenticodeSetupHelper',
    'signedNMinus1ToNUpgrade',
    'interruptedUpgradeRollback',
    'downgradePolicy',
    'noOpenUnwaivedP0P1Blocker'
)
$GaIssue3GateNames = @(
    'linuxSystemdUserServicePackage',
    'macosLaunchAgentPackage',
    'linuxX64ReleaseArtifact',
    'macosX64ReleaseArtifact',
    'macosArm64ReleaseArtifact',
    'platformNativeShells',
    'platformNativeProcessGroups',
    'crossPlatformPathAclTests',
    'liveMacosRun',
    'liveLinuxControllerWorkerRoundTrip',
    'macosDeveloperIdSigningNotarization'
)
$GaIssue23GateNames = [ordered]@{
    issue2 = $GaIssue2GateNames
    issue3 = $GaIssue3GateNames
}
$GaIssue5ExpectedSelectors = [ordered]@{
    linux = 'isolation::tests::linux_live_dedicated_identity_credential_and_residual_reconciliation'
    windows = 'isolation::tests::windows_native_containment_job_object_and_guard'
    macos = 'isolation::tests::macos_live_external_reconciliation'
}
$GaIssue5DisallowedSelectors = [ordered]@{
    windows = @('isolation::tests::windows_external_json_contract_is_fail_closed_at_every_runtime_gate')
    macos = @('isolation::tests::macos_external_reconciliation_is_fail_closed_at_every_runtime_gate')
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
    windowsIsolatedExecutionIdentity = @('windowsExecutionIdentityVerified=1')
    windowsJobObject = @('windowsJobObjectVerified=1')
    windowsProtectedExternalGuard = @('windowsProtectedExternalGuardVerified=1')
    macosExternalReconciliation = @('macosExternalReconciliationVerified=1')
}
$GaIssue5PlatformGateMarkerPrefixes = [ordered]@{
    jobsCannotAlterGuardState = [ordered]@{
        linux = @('linuxGuardTamperRejected=1')
        windows = @('windowsGuardTamperRejected=1')
        macos = @('macosGuardTamperRejected=1')
    }
    jobsCannotReadWorkerCredentials = [ordered]@{
        linux = @('linuxWorkerCredentialIsolationVerified=1')
        windows = @('windowsWorkerCredentialIsolationVerified=1')
        macos = @('macosWorkerCredentialIsolationVerified=1')
    }
}
$GaIssue5ResidualMarkerPrefixes = [ordered]@{
    # ``residual_empty`` is a Linux cgroup marker.  External platforms must
    # prove their native process-scope/guard reconciliation explicitly.
    linux = @('residual_empty', 'residualCgroupVerified=1', 'residualIdentityProcessesVerified=1')
    windows = @('residualJobObjectVerified=1')
    macos = @('residualExternalReconciliationVerified=1')
}
$GaIssue5RunIdentifierPattern = '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'
$GaIssue5IsoInstantPattern = '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^\s]+(Z|[+-][0-9]{2}:[0-9]{2})$'
$GaBlockerInventorySchema = 'cyc.dev/ga-blocker-inventory/v1'
$GaBlockerRepository = 'TypeThe0ry/ClusterYourCodex'
$GaBlockerEvidenceIdPattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
$GaBlockerPriorityLabelPattern = '^(?:(?:priority|severity)(?:[:/_\-\s]+))?p([01])$'

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

function Test-RawLogInteger {
    param([Parameter(Mandatory = $true)][object]$Value)

    return ($Value -is [byte]) -or
        ($Value -is [sbyte]) -or
        ($Value -is [int16]) -or
        ($Value -is [uint16]) -or
        ($Value -is [int32]) -or
        ($Value -is [uint32]) -or
        ($Value -is [int64]) -or
        ($Value -is [uint64])
}

function Assert-RawLogCount {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Description,
        [bool]$RequirePositive = $false
    )

    Assert-RawLogCondition (Test-RawLogInteger -Value $Value) "$Description must be an integer"
    try {
        [decimal]$numeric = $Value
    } catch {
        throw "GA raw-log assertion failed: $Description is outside the supported integer range."
    }
    Assert-RawLogCondition ($numeric -ge 0) "$Description must be non-negative"
    Assert-RawLogCondition ($numeric -le [decimal]$MaximumRawLogTestCount) "$Description must not exceed $MaximumRawLogTestCount"
    if ($RequirePositive) {
        Assert-RawLogCondition ($numeric -gt 0) "$Description must be greater than zero"
    }
    return [long]$numeric
}

function Convert-RawLogInstant {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-RawLogCondition ($Value -is [string] -or
        $Value -is [DateTime] -or $Value -is [DateTimeOffset]) "$Description must be an ISO-8601 instant"
    try {
        if ($Value -is [DateTimeOffset]) {
            return [DateTimeOffset]$Value
        }
        if ($Value -is [DateTime]) {
            Assert-RawLogCondition ($Value.Kind -ne [DateTimeKind]::Unspecified) "$Description must carry an explicit UTC offset"
            return [DateTimeOffset]$Value
        }

        $text = [string]$Value
        Assert-RawLogCondition ($text -match '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$') "$Description must include a UTC designator or numeric offset"
        return [DateTimeOffset]::Parse(
            $text,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
    } catch {
        throw "GA raw-log assertion failed: $Description must be a valid ISO-8601 instant with an explicit offset."
    }
}

function Format-RawLogInstantUtc {
    param(
        [Parameter(Mandatory = $true)][DateTimeOffset]$Value
    )

    return $Value.ToUniversalTime().ToString(
        'yyyy-MM-dd''T''HH:mm:ss.fffffff''Z''',
        [Globalization.CultureInfo]::InvariantCulture
    )
}

function Convert-RawLogJsonValueToInvariantIso {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ($null -eq $Value) { return $null }

    # Windows PowerShell 5.1 materializes ISO JSON timestamps as DateTime.
    # Formatting at the output boundary prevents ConvertTo-Json from emitting
    # culture-dependent text or its legacy /Date(...)\/ representation.
    if ($Value -is [DateTimeOffset]) {
        return Format-RawLogInstantUtc -Value ([DateTimeOffset]$Value)
    }
    if ($Value -is [DateTime]) {
        Assert-RawLogCondition ($Value.Kind -ne [DateTimeKind]::Unspecified) "$Description must carry an explicit UTC offset"
        return Format-RawLogInstantUtc -Value ([DateTimeOffset]$Value)
    }

    if ($Value -is [System.Array]) {
        $items = New-Object System.Collections.ArrayList
        for ($index = 0; $index -lt $Value.Count; $index++) {
            $item = Convert-RawLogJsonValueToInvariantIso `
                -Value $Value[$index] `
                -Description "$Description[$index]"
            [void]$items.Add($item)
        }
        return ,$items.ToArray()
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $properties = [ordered]@{}
        foreach ($entry in $Value.GetEnumerator()) {
            $name = [string]$entry.Key
            $properties[$name] = Convert-RawLogJsonValueToInvariantIso `
                -Value $entry.Value `
                -Description "$Description.$name"
        }
        return [pscustomobject]$properties
    }

    if ($Value -is [pscustomobject]) {
        $properties = [ordered]@{}
        foreach ($property in @($Value.PSObject.Properties)) {
            $name = [string]$property.Name
            $properties[$name] = Convert-RawLogJsonValueToInvariantIso `
                -Value $property.Value `
                -Description "$Description.$name"
        }
        return [pscustomobject]$properties
    }

    return $Value
}

function Normalize-RawLogCommand {
    param([Parameter(Mandatory = $true)][string]$Command)

    return [regex]::Replace($Command.Trim(), '\s+', ' ')
}

function Assert-RawLogDescriptor {
    param(
        [Parameter(Mandatory = $true)][object]$RawLog,
        [Parameter(Mandatory = $true)][string]$IssueName,
        [Parameter(Mandatory = $true)][string]$Description,
        [bool]$RequirePositivePassed = $true
    )

    Assert-RawLogCondition (($RawLog -is [pscustomobject]) -and -not ($RawLog -is [System.Array])) "$Description.rawLog is a JSON object"
    $command = Get-RawLogProperty -Object $RawLog -Path 'command' -Description $Description
    Assert-RawLogCondition ($command -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$command)) "$Description.rawLog.command is a non-empty string"
    $node = Get-RawLogProperty -Object $RawLog -Path 'node' -Description $Description
    Assert-RawLogCondition ($node -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$node)) "$Description.rawLog.node is a non-empty string"
    Assert-RawLogCondition ([string]$node -notmatch '(?i)github|actions|hosted|runner') "$Description.rawLog.node must identify an external host"

    $startedAt = Convert-RawLogInstant -Value (Get-RawLogProperty -Object $RawLog -Path 'startedAt' -Description $Description) -Description "$Description.rawLog.startedAt"
    $endedAt = Convert-RawLogInstant -Value (Get-RawLogProperty -Object $RawLog -Path 'endedAt' -Description $Description) -Description "$Description.rawLog.endedAt"
    Assert-RawLogCondition ($endedAt -ge $startedAt) "$Description.rawLog.endedAt must not precede startedAt"

    $exitCode = Get-RawLogProperty -Object $RawLog -Path 'exitCode' -Description $Description
    Assert-RawLogCondition ((Test-RawLogInteger -Value $exitCode) -and [decimal]$exitCode -eq 0) "$Description.rawLog.exitCode must be integer 0"
    $tests = Get-RawLogProperty -Object $RawLog -Path 'tests' -Description $Description
    Assert-RawLogCondition (($tests -is [pscustomobject]) -and -not ($tests -is [System.Array])) "$Description.rawLog.tests is a JSON object"
    foreach ($field in @('passed', 'failed', 'ignored')) {
        $count = Get-RawLogProperty -Object $tests -Path $field -Description "$Description.rawLog.tests"
        [void](Assert-RawLogCount -Value $count -Description "$Description.rawLog.tests.$field" -RequirePositive ($RequirePositivePassed -and $field -ceq 'passed'))
    }
    Assert-RawLogCondition ([decimal]$tests.failed -eq 0) "$Description.rawLog.tests.failed must be zero"
    $cleanup = Get-RawLogProperty -Object $RawLog -Path 'cleanup' -Description $Description
    Assert-RawLogCondition (($cleanup -is [bool]) -and $cleanup) "$Description.rawLog.cleanup must be boolean true"
    return $RawLog
}

function Assert-RawLogExactObjectPropertySet {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string[]]$Required,
        [Parameter(Mandatory = $false)][string[]]$Optional = @(),
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-RawLogCondition (($Object -is [pscustomobject]) -and -not ($Object -is [System.Array])) "$Description must be a JSON object"
    $allowed = @($Required + $Optional | Select-Object -Unique)
    foreach ($requiredName in $Required) {
        Assert-RawLogCondition ($null -ne $Object.PSObject.Properties[$requiredName]) "$Description is missing required property '$requiredName'"
    }
    foreach ($property in @($Object.PSObject.Properties)) {
        Assert-RawLogCondition (@($allowed | Where-Object { $_ -ceq [string]$property.Name }).Count -eq 1) "$Description contains unknown property '$($property.Name)'"
    }
}

function Get-RawLogBlockerPriorityLabels {
    param(
        [Parameter(Mandatory = $true)][object]$Labels,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-RawLogCondition ($Labels -is [System.Array]) "$Description.labels must be a JSON array"
    $seenNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $priorities = New-Object System.Collections.Generic.List[string]
    foreach ($label in @($Labels)) {
        Assert-RawLogCondition (($label -is [pscustomobject]) -and -not ($label -is [System.Array])) "$Description.labels entries must be JSON objects"
        $nameProperty = $label.PSObject.Properties['name']
        Assert-RawLogCondition ($null -ne $nameProperty) "$Description.labels entries must contain name"
        Assert-RawLogCondition ($nameProperty.Value -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$nameProperty.Value)) "$Description.labels.name must be a non-empty string"
        $name = ([string]$nameProperty.Value).Trim()
        Assert-RawLogCondition ($seenNames.Add($name)) "$Description.labels must not contain duplicate label names"
        $match = [regex]::Match($name, $GaBlockerPriorityLabelPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            $priority = 'P' + $match.Groups[1].Value
            Assert-RawLogCondition (-not (@($priorities | Where-Object { $_ -ceq $priority }).Count -gt 0)) "$Description.labels must not declare the same P0/P1 priority more than once"
            [void]$priorities.Add($priority)
        }
    }
    return $priorities.ToArray()
}

function Assert-RawLogBlockerReviewer {
    param(
        [Parameter(Mandatory = $true)][object]$Reviewer,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-RawLogExactObjectPropertySet -Object $Reviewer -Required @('id', 'login') -Description $Description
    $id = Get-RawLogProperty -Object $Reviewer -Path 'id' -Description $Description
    Assert-RawLogCondition ((Test-RawLogInteger -Value $id) -and [decimal]$id -gt 0) "$Description.id must be a positive integer"
    $login = Get-RawLogProperty -Object $Reviewer -Path 'login' -Description $Description
    Assert-RawLogCondition ($login -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$login)) "$Description.login must be a non-empty string"
    Assert-RawLogCondition ([string]$login -notmatch '[\r\n]') "$Description.login must not contain newlines"
    return [pscustomobject]@{ id = [long]$id; login = [string]$login }
}

function Assert-RawLogBlockerInventory {
    param(
        [Parameter(Mandatory = $true)][object]$Inventory,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-RawLogExactObjectPropertySet -Object $Inventory `
        -Required @('schemaVersion', 'status', 'sourceCommit', 'evidenceId', 'repository', 'reviewer', 'reviewedAt', 'expiresAt', 'api', 'issues', 'waivers') `
        -Description $Description
    Assert-RawLogCondition ([string]$Inventory.schemaVersion -ceq $GaBlockerInventorySchema) "$Description.schemaVersion must be $GaBlockerInventorySchema"
    Assert-RawLogCondition ([string]$Inventory.status -ceq 'passed') "$Description.status must be passed"
    $sourceCommit = Get-RawLogProperty -Object $Inventory -Path 'sourceCommit' -Description $Description
    Assert-RawLogCondition ($sourceCommit -is [string] -and [string]$sourceCommit -match '^[0-9a-fA-F]{40}$') "$Description.sourceCommit must be a full commit SHA"
    Assert-RawLogCondition ([string]$sourceCommit -ieq $ExpectedCommit) "$Description.sourceCommit must match ExpectedCommit"
    Assert-RawLogCondition ([string]$Inventory.repository -ceq $GaBlockerRepository) "$Description.repository must be $GaBlockerRepository"
    $evidenceId = Get-RawLogProperty -Object $Inventory -Path 'evidenceId' -Description $Description
    Assert-RawLogCondition ($evidenceId -is [string] -and [string]$evidenceId -match $GaBlockerEvidenceIdPattern) "$Description.evidenceId must be a bounded portable identifier"

    $reviewer = Assert-RawLogBlockerReviewer -Reviewer (Get-RawLogProperty -Object $Inventory -Path 'reviewer' -Description $Description) -Description "$Description.reviewer"
    $reviewedAt = Convert-RawLogInstant -Value (Get-RawLogProperty -Object $Inventory -Path 'reviewedAt' -Description $Description) -Description "$Description.reviewedAt"
    $expiresAt = Convert-RawLogInstant -Value (Get-RawLogProperty -Object $Inventory -Path 'expiresAt' -Description $Description) -Description "$Description.expiresAt"
    $now = [DateTimeOffset]::UtcNow
    Assert-RawLogCondition ($reviewedAt -le $now) "$Description.reviewedAt must not be in the future"
    Assert-RawLogCondition ($expiresAt -gt $now) "$Description.expiresAt must be in the future"
    Assert-RawLogCondition ($expiresAt -gt $reviewedAt) "$Description.expiresAt must be later than reviewedAt"

    $api = Get-RawLogProperty -Object $Inventory -Path 'api' -Description $Description
    Assert-RawLogExactObjectPropertySet -Object $api `
        -Required @('provider', 'endpoint', 'requestedState', 'complete', 'incomplete', 'hasNextPage', 'pageCount', 'totalCount', 'returnedCount', 'capturedAt', 'sourceCommit', 'error') `
        -Description "$Description.api"
    Assert-RawLogCondition ([string]$api.provider -ceq 'github-rest-api') "$Description.api.provider must be github-rest-api"
    Assert-RawLogCondition ([string]$api.requestedState -ceq 'open') "$Description.api.requestedState must be open"
    $endpoint = Get-RawLogProperty -Object $api -Path 'endpoint' -Description "$Description.api"
    $endpointUri = $null
    Assert-RawLogCondition ($endpoint -is [string] -and [Uri]::TryCreate([string]$endpoint, [UriKind]::Absolute, [ref]$endpointUri)) "$Description.api.endpoint must be an absolute URL"
    Assert-RawLogCondition ($endpointUri.Scheme.Equals('https', [StringComparison]::OrdinalIgnoreCase) -and $endpointUri.Host.Equals('api.github.com', [StringComparison]::OrdinalIgnoreCase)) "$Description.api.endpoint must use api.github.com over HTTPS"
    Assert-RawLogCondition ([string]::IsNullOrWhiteSpace($endpointUri.UserInfo) -and [string]::IsNullOrWhiteSpace($endpointUri.Query) -and [string]::IsNullOrWhiteSpace($endpointUri.Fragment)) "$Description.api.endpoint must not contain credentials, query parameters, or fragments"
    Assert-RawLogCondition ($endpointUri.AbsolutePath.TrimEnd('/') -ceq '/repos/TypeThe0ry/ClusterYourCodex/issues') "$Description.api.endpoint must target the canonical repository issues endpoint"
    foreach ($booleanField in @('complete', 'incomplete', 'hasNextPage')) {
        $booleanValue = Get-RawLogProperty -Object $api -Path $booleanField -Description "$Description.api"
        Assert-RawLogCondition ($booleanValue -is [bool]) "$Description.api.$booleanField must be boolean"
    }
    Assert-RawLogCondition ([bool]$api.complete -and -not [bool]$api.incomplete -and -not [bool]$api.hasNextPage) "$Description.api must be complete without a next page"
    [void](Assert-RawLogCount -Value (Get-RawLogProperty -Object $api -Path 'pageCount' -Description "$Description.api") -Description "$Description.api.pageCount" -RequirePositive $true)
    $totalCount = Assert-RawLogCount -Value (Get-RawLogProperty -Object $api -Path 'totalCount' -Description "$Description.api") -Description "$Description.api.totalCount"
    $returnedCount = Assert-RawLogCount -Value (Get-RawLogProperty -Object $api -Path 'returnedCount' -Description "$Description.api") -Description "$Description.api.returnedCount"
    $capturedAt = Convert-RawLogInstant -Value (Get-RawLogProperty -Object $api -Path 'capturedAt' -Description "$Description.api") -Description "$Description.api.capturedAt"
    Assert-RawLogCondition ($capturedAt -le $now) "$Description.api.capturedAt must not be in the future"
    $apiCommit = Get-RawLogProperty -Object $api -Path 'sourceCommit' -Description "$Description.api"
    Assert-RawLogCondition ($apiCommit -is [string] -and [string]$apiCommit -match '^[0-9a-fA-F]{40}$' -and [string]$apiCommit -ieq $ExpectedCommit) "$Description.api.sourceCommit must match ExpectedCommit"
    $apiError = Get-RawLogProperty -Object $api -Path 'error' -Description "$Description.api"
    Assert-RawLogCondition ($null -eq $apiError -or ($apiError -is [string] -and [string]::IsNullOrWhiteSpace([string]$apiError))) "$Description.api.error must be null or empty"

    $issues = $Inventory.PSObject.Properties['issues'].Value
    Assert-RawLogCondition ($issues -is [System.Array]) "$Description.issues must be a JSON array"
    Assert-RawLogCondition ([long]$returnedCount -eq [long]$issues.Count -and [long]$totalCount -eq [long]$issues.Count) "$Description.api issue counts must match the snapshot"
    $seenIssueNumbers = New-Object 'System.Collections.Generic.HashSet[long]'
    $blockers = New-Object System.Collections.Generic.List[object]
    foreach ($issue in @($issues)) {
        Assert-RawLogExactObjectPropertySet -Object $issue -Required @('number', 'state', 'title', 'html_url', 'labels') -Description "$Description.issues entry"
        $number = Get-RawLogProperty -Object $issue -Path 'number' -Description "$Description.issues entry"
        Assert-RawLogCondition ((Test-RawLogInteger -Value $number) -and [decimal]$number -gt 0 -and $seenIssueNumbers.Add([long]$number)) "$Description.issues.number must be a unique positive integer"
        Assert-RawLogCondition ([string]$issue.state -ceq 'open') "$Description.issues #$number.state must be open"
        Assert-RawLogCondition ($issue.title -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$issue.title)) "$Description.issues #$number.title must be non-empty"
        Assert-RawLogCondition ([string]$issue.html_url -ceq "https://github.com/$GaBlockerRepository/issues/$number") "$Description.issues #$number.html_url must be canonical"
        $priorityLabels = @(Get-RawLogBlockerPriorityLabels -Labels $issue.PSObject.Properties['labels'].Value -Description "$Description.issues #$number")
        Assert-RawLogCondition ($priorityLabels.Count -le 1) "$Description.issues #$number must have at most one P0/P1 label"
        if ($priorityLabels.Count -eq 1) { [void]$blockers.Add([pscustomobject]@{ number = [long]$number; priority = [string]$priorityLabels[0] }) }
    }

    $waivers = $Inventory.PSObject.Properties['waivers'].Value
    Assert-RawLogCondition ($waivers -is [System.Array]) "$Description.waivers must be a JSON array"
    $seenWaiverNumbers = New-Object 'System.Collections.Generic.HashSet[long]'
    $blockerNumberSet = New-Object 'System.Collections.Generic.HashSet[long]'
    foreach ($blocker in $blockers.ToArray()) { [void]$blockerNumberSet.Add([long]$blocker.number) }
    foreach ($waiver in @($waivers)) {
        Assert-RawLogExactObjectPropertySet -Object $waiver -Required @('issueNumber', 'scope', 'sourceCommit', 'expiresAt', 'reviewer', 'status', 'reason') -Description "$Description.waivers entry"
        $waiverNumber = Get-RawLogProperty -Object $waiver -Path 'issueNumber' -Description "$Description.waivers entry"
        Assert-RawLogCondition ((Test-RawLogInteger -Value $waiverNumber) -and [decimal]$waiverNumber -gt 0 -and $seenWaiverNumbers.Add([long]$waiverNumber)) "$Description.waivers.issueNumber must be a unique positive integer"
        Assert-RawLogCondition ($blockerNumberSet.Contains([long]$waiverNumber)) "$Description.waivers may only reference an open P0/P1 issue"
        $scope = Get-RawLogProperty -Object $waiver -Path 'scope' -Description "$Description.waivers #$waiverNumber"
        Assert-RawLogExactObjectPropertySet -Object $scope -Required @('repository', 'channel', 'issueNumber') -Description "$Description.waivers #$waiverNumber.scope"
        Assert-RawLogCondition ([string]$scope.repository -ceq $GaBlockerRepository -and [string]$scope.channel -ceq 'stable') "$Description.waivers #$waiverNumber.scope must bind stable repository scope"
        $scopeNumber = Get-RawLogProperty -Object $scope -Path 'issueNumber' -Description "$Description.waivers #$waiverNumber.scope"
        Assert-RawLogCondition ((Test-RawLogInteger -Value $scopeNumber) -and [long]$scopeNumber -eq [long]$waiverNumber) "$Description.waivers #$waiverNumber.scope.issueNumber must match issueNumber"
        $waiverCommit = Get-RawLogProperty -Object $waiver -Path 'sourceCommit' -Description "$Description.waivers #$waiverNumber"
        Assert-RawLogCondition ($waiverCommit -is [string] -and [string]$waiverCommit -match '^[0-9a-fA-F]{40}$' -and [string]$waiverCommit -ieq $ExpectedCommit) "$Description.waivers #$waiverNumber.sourceCommit must match ExpectedCommit"
        $waiverExpiresAt = Convert-RawLogInstant -Value (Get-RawLogProperty -Object $waiver -Path 'expiresAt' -Description "$Description.waivers #$waiverNumber") -Description "$Description.waivers #$waiverNumber.expiresAt"
        Assert-RawLogCondition ($waiverExpiresAt -gt $now -and $waiverExpiresAt -le $expiresAt) "$Description.waivers #$waiverNumber.expiresAt must be valid and within inventory expiry"
        $waiverReviewer = Assert-RawLogBlockerReviewer -Reviewer (Get-RawLogProperty -Object $waiver -Path 'reviewer' -Description "$Description.waivers #$waiverNumber") -Description "$Description.waivers #$waiverNumber.reviewer"
        Assert-RawLogCondition ($waiverReviewer.id -eq $reviewer.id -and $waiverReviewer.login -ceq $reviewer.login) "$Description.waivers #$waiverNumber.reviewer must match inventory reviewer"
        Assert-RawLogCondition ([string]$waiver.status -ceq 'active') "$Description.waivers #$waiverNumber.status must be active"
        Assert-RawLogCondition ($waiver.reason -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$waiver.reason)) "$Description.waivers #$waiverNumber.reason must be non-empty"
    }
    foreach ($blocker in $blockers.ToArray()) {
        $matches = @($waivers | Where-Object { [long]$_.issueNumber -eq [long]$blocker.number })
        Assert-RawLogCondition ($matches.Count -eq 1) "$Description must contain one active waiver for open $($blocker.priority) issue #$($blocker.number)"
    }
    Assert-RawLogCondition ($seenWaiverNumbers.Count -eq $blockers.Count) "$Description.waivers must cover exactly the P0/P1 blockers"
}

function Get-RawLogIssue23GateMarkers {
    param(
        [Parameter(Mandatory = $true)][object]$GateEvidence,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-RawLogCondition (($GateEvidence -is [pscustomobject]) -and -not ($GateEvidence -is [System.Array])) "$Description is a JSON object"
    $canonicalProperty = $GateEvidence.PSObject.Properties['rawLogMarkers']
    $aliasProperty = $GateEvidence.PSObject.Properties['markers']
    Assert-RawLogCondition ($null -ne $canonicalProperty -or $null -ne $aliasProperty) "$Description.rawLogMarkers is required"
    if ($null -ne $canonicalProperty) {
        Assert-RawLogCondition ($canonicalProperty.Value -is [System.Array]) "$Description.rawLogMarkers is a JSON array"
    }
    if ($null -ne $aliasProperty) {
        Assert-RawLogCondition ($aliasProperty.Value -is [System.Array]) "$Description.markers is a JSON array"
    }
    if ($null -ne $canonicalProperty -and $null -ne $aliasProperty) {
        $canonical = @($canonicalProperty.Value)
        $alias = @($aliasProperty.Value)
        Assert-RawLogCondition ($canonical.Count -eq $alias.Count) "$Description.rawLogMarkers and markers aliases have the same length"
        for ($index = 0; $index -lt $canonical.Count; $index++) {
            Assert-RawLogCondition (($canonical[$index] -is [string]) -and ($alias[$index] -is [string])) "$Description.rawLogMarkers and markers aliases entries are both strings"
            Assert-RawLogCondition ([string]$canonical[$index] -ceq [string]$alias[$index]) "$Description.rawLogMarkers and markers aliases must match exactly"
        }
    }
    if ($null -ne $canonicalProperty) {
        $markers = [object[]]@($canonicalProperty.Value)
    } else {
        $markers = [object[]]@($aliasProperty.Value)
    }
    Assert-RawLogCondition ($markers.Count -gt 0) "$Description.rawLogMarkers is non-empty"
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($marker in $markers) {
        Assert-RawLogCondition ($marker -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$marker)) "$Description.rawLogMarkers entries are non-empty strings"
        Assert-RawLogCondition ($seen.Add([string]$marker)) "$Description.rawLogMarkers entries are unique"
    }
    return $markers
}

function Get-RawLogIssue23GateSelector {
    param(
        [Parameter(Mandatory = $true)][object]$GateEvidence,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $canonicalProperty = $GateEvidence.PSObject.Properties['testSelector']
    $aliasProperty = $GateEvidence.PSObject.Properties['selector']
    Assert-RawLogCondition ($null -ne $canonicalProperty -or $null -ne $aliasProperty) "$Description.testSelector is required"
    if ($null -ne $canonicalProperty -and $null -ne $aliasProperty) {
        Assert-RawLogCondition (($canonicalProperty.Value -is [string]) -and ($aliasProperty.Value -is [string])) "$Description.testSelector and selector aliases are strings"
        Assert-RawLogCondition ([string]$canonicalProperty.Value -ceq [string]$aliasProperty.Value) "$Description.testSelector and selector aliases must match exactly"
    }
    $selector = if ($null -ne $canonicalProperty) { $canonicalProperty.Value } else { $aliasProperty.Value }
    Assert-RawLogCondition ($selector -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$selector)) "$Description.testSelector is a non-empty string"
    return [string]$selector
}

function Get-RawLogIssue23GateMarker {
    param(
        [Parameter(Mandatory = $true)][string]$IssueName,
        [Parameter(Mandatory = $true)][string]$Gate,
        [Parameter(Mandatory = $true)][string]$Command
    )

    $commandDigest = Get-RawLogIssue5CommandSha256 -Command $Command
    return "CYC-GA-$($IssueName.ToUpperInvariant())|gate=$Gate|commandSha256=$commandDigest|status=passed"
}

function Get-RawLogIssue3GateContract {
    param(
        [Parameter(Mandatory = $true)][string]$Gate,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $property = $GaIssue3GateContract.gates.PSObject.Properties[$Gate]
    Assert-RawLogCondition ($null -ne $property) "$Description has a reviewed Issue #3 semantic contract"
    $contract = $property.Value
    Assert-RawLogCondition (($contract -is [pscustomobject]) -and -not ($contract -is [System.Array])) "$Description semantic contract is a JSON object"
    foreach ($field in @('platform', 'platforms', 'architectures', 'operation', 'commandPatterns', 'selectorPatterns')) {
        Assert-RawLogCondition ($null -ne $contract.PSObject.Properties[$field]) "$Description semantic contract is missing '$field'"
    }
    return $contract
}

function Get-RawLogIssue3SemanticMarker {
    param(
        [Parameter(Mandatory = $true)][string]$Gate,
        [Parameter(Mandatory = $true)][string]$Platform,
        [Parameter(Mandatory = $true)][string]$Architecture,
        [Parameter(Mandatory = $true)][string]$Operation,
        [Parameter(Mandatory = $true)][string[]]$Platforms
    )

    $platformToken = @($Platforms | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object) -join ','
    return "CYC-GA-ISSUE3|gate=$Gate|platform=$Platform|architecture=$Architecture|operation=$Operation|platforms=$platformToken|status=passed"
}

function Assert-RawLogIssue3GateSemantics {
    param(
        [Parameter(Mandatory = $true)][string]$Gate,
        [Parameter(Mandatory = $true)][object]$GateEvidence,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$Selector,
        [Parameter(Mandatory = $true)][object[]]$Markers,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $contract = Get-RawLogIssue3GateContract -Gate $Gate -Description $Description
    $platform = Get-RawLogProperty -Object $GateEvidence -Path 'platform' -Description $Description
    $architecture = Get-RawLogProperty -Object $GateEvidence -Path 'architecture' -Description $Description
    $operation = Get-RawLogProperty -Object $GateEvidence -Path 'operation' -Description $Description
    $platformsProperty = $GateEvidence.PSObject.Properties['platforms']
    Assert-RawLogCondition ($null -ne $platformsProperty) "$Description.platforms is required"
    $platformsValue = $platformsProperty.Value
    Assert-RawLogCondition ($platform -is [string] -and [string]$platform -ceq ([string]$platform).ToLowerInvariant()) "$Description.platform must be a lower-case string"
    Assert-RawLogCondition ($architecture -is [string] -and [string]$architecture -ceq ([string]$architecture).ToLowerInvariant()) "$Description.architecture must be a lower-case string"
    Assert-RawLogCondition ($operation -is [string] -and [string]$operation -ceq ([string]$operation).ToLowerInvariant()) "$Description.operation must be a lower-case string"
    Assert-RawLogCondition ($platform -ceq [string]$contract.platform) "$Description.platform must equal the reviewed semantic platform '$($contract.platform)'"
    $allowedArchitectures = @($contract.architectures | ForEach-Object { [string]$_ })
    Assert-RawLogCondition ($allowedArchitectures.Count -gt 0 -and @($allowedArchitectures | Where-Object { $_ -ceq [string]$architecture }).Count -eq 1) "$Description.architecture is not allowed for Issue #3.$Gate"
    Assert-RawLogCondition ($operation -ceq [string]$contract.operation) "$Description.operation must equal the reviewed semantic operation '$($contract.operation)'"
    Assert-RawLogCondition (($platformsValue -is [System.Array]) -and $platformsValue.Count -gt 0) "$Description.platforms must be a non-empty JSON array"
    $actualPlatforms = @($platformsValue | ForEach-Object { Assert-RawLogCondition ($_ -is [string]) "$Description.platforms entries must be strings"; [string]$_ })
    Assert-RawLogCondition (@($actualPlatforms | Where-Object { $_ -cne $_.ToLowerInvariant() }).Count -eq 0) "$Description.platforms entries must be lower-case"
    $actualPlatformSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($item in $actualPlatforms) {
        Assert-RawLogCondition ($actualPlatformSet.Add($item)) "$Description.platforms must not contain duplicates"
    }
    $expectedPlatforms = @($contract.platforms | ForEach-Object { [string]$_ } | Sort-Object)
    $normalizedActualPlatforms = @($actualPlatforms | Sort-Object)
    Assert-RawLogCondition (($normalizedActualPlatforms -join ',') -ceq ($expectedPlatforms -join ',')) "$Description.platforms must equal the reviewed platform set '$($expectedPlatforms -join ',')'"

    foreach ($pattern in @($contract.commandPatterns)) {
        Assert-RawLogCondition ($pattern -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$pattern)) "$Description semantic command pattern must be non-empty"
        try {
            $matches = [regex]::IsMatch($Command, [string]$pattern)
        } catch {
            throw "GA raw-log assertion failed: $Description semantic command pattern is invalid: $($_.Exception.Message)"
        }
        Assert-RawLogCondition $matches "$Description.command must satisfy Issue #3.$Gate semantic pattern '$pattern'"
    }
    foreach ($pattern in @($contract.selectorPatterns)) {
        Assert-RawLogCondition ($pattern -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$pattern)) "$Description semantic selector pattern must be non-empty"
        try {
            $matches = [regex]::IsMatch($Selector, [string]$pattern)
        } catch {
            throw "GA raw-log assertion failed: $Description semantic selector pattern is invalid: $($_.Exception.Message)"
        }
        Assert-RawLogCondition $matches "$Description.testSelector must satisfy Issue #3.$Gate semantic pattern '$pattern'"
    }
    $semanticMarker = Get-RawLogIssue3SemanticMarker `
        -Gate $Gate `
        -Platform ([string]$platform) `
        -Architecture ([string]$architecture) `
        -Operation ([string]$operation) `
        -Platforms $actualPlatforms
    Assert-RawLogCondition (@($Markers | Where-Object { [string]$_ -ceq $semanticMarker }).Count -eq 1) "$Description.rawLogMarkers must contain the semantic Issue #3 marker"
    return [pscustomobject]@{
        platform = [string]$platform
        architecture = [string]$architecture
        operation = [string]$operation
        platforms = $actualPlatforms
        semanticMarker = $semanticMarker
    }
}

function Assert-RawLogIssue23GateEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$ManifestIssue,
        [Parameter(Mandatory = $true)][string]$IssueName,
        [Parameter(Mandatory = $true)][string]$Gate,
        [Parameter(Mandatory = $true)][object]$GateEvidence,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-RawLogExactObjectPropertySet -Object $GateEvidence `
        -Required @('status', 'gateId', 'sourceCommit', 'provider', 'hostType', 'evidenceId', 'runId', 'node', 'exitCode', 'tests', 'startedAt', 'endedAt', 'command') `
        -Optional @('testSelector', 'selector', 'rawLogMarkers', 'markers', 'blockerInventory', 'platform', 'architecture', 'operation', 'platforms') `
        -Description $Description
    $status = Get-RawLogProperty -Object $GateEvidence -Path 'status' -Description $Description
    Assert-RawLogCondition (($status -is [bool]) -and $status) "$Description.status must be boolean true"
    $gateId = Get-RawLogProperty -Object $GateEvidence -Path 'gateId' -Description $Description
    Assert-RawLogCondition ($gateId -is [string] -and [string]$gateId -ceq "$IssueName.$Gate") "$Description.gateId must equal '$IssueName.$Gate'"
    $sourceCommit = Get-RawLogProperty -Object $GateEvidence -Path 'sourceCommit' -Description $Description
    Assert-RawLogCondition ($sourceCommit -is [string] -and [string]$sourceCommit -match '^[0-9a-fA-F]{40}$') "$Description.sourceCommit must be a full commit SHA"
    Assert-RawLogCondition ([string]$sourceCommit -ieq $ExpectedCommit) "$Description.sourceCommit must match ExpectedCommit"
    $manifestEvidenceId = [string](Get-RawLogProperty -Object $ManifestIssue -Path 'evidenceId' -Description $Description)
    foreach ($field in @('provider', 'hostType', 'evidenceId', 'runId', 'node', 'command')) {
        $value = Get-RawLogProperty -Object $GateEvidence -Path $field -Description $Description
        Assert-RawLogCondition ($value -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$value)) "$Description.$field must be a non-empty string"
    }
    $provider = [string](Get-RawLogProperty -Object $GateEvidence -Path 'provider' -Description $Description)
    $hostType = [string](Get-RawLogProperty -Object $GateEvidence -Path 'hostType' -Description $Description)
    $node = [string](Get-RawLogProperty -Object $GateEvidence -Path 'node' -Description $Description)
    foreach ($fieldValue in @(@('provider', $provider), @('hostType', $hostType), @('node', $node))) {
        Assert-RawLogCondition ($fieldValue[1] -notmatch '(?i)github|actions|hosted|runner') "$Description.$($fieldValue[0]) must identify an external execution surface"
    }
    $gateEvidenceId = [string](Get-RawLogProperty -Object $GateEvidence -Path 'evidenceId' -Description $Description)
    Assert-RawLogCondition ($gateEvidenceId -ceq $manifestEvidenceId) "$Description.evidenceId must match the issue evidenceId"
    $selector = Get-RawLogIssue23GateSelector -GateEvidence $GateEvidence -Description $Description
    $command = [string](Get-RawLogProperty -Object $GateEvidence -Path 'command' -Description $Description)
    # ConvertFrom-Json in Windows PowerShell 5.1 materializes ISO-8601 values
    # as DateTime instances.  Never cast those directly to [string]: that uses
    # the current culture and drops the timezone, producing e.g. `08/30/2026
    # 14:00:00`, which cannot be consumed by the workflow's ISO contract.  Parse
    # through the same strict instant validator used by the descriptor and
    # emit one invariant, explicit-offset representation for every gate record.
    $startedAt = Convert-RawLogInstant `
        -Value (Get-RawLogProperty -Object $GateEvidence -Path 'startedAt' -Description $Description) `
        -Description "$Description.startedAt"
    $endedAt = Convert-RawLogInstant `
        -Value (Get-RawLogProperty -Object $GateEvidence -Path 'endedAt' -Description $Description) `
        -Description "$Description.endedAt"
    Assert-RawLogCondition ($endedAt -ge $startedAt) "$Description.endedAt must not precede startedAt"
    $markers = Get-RawLogIssue23GateMarkers -GateEvidence $GateEvidence -Description $Description
    $semanticContract = $null
    if ($IssueName -ceq 'issue3') {
        $semanticContract = Assert-RawLogIssue3GateSemantics `
            -Gate $Gate `
            -GateEvidence $GateEvidence `
            -Command $command `
            -Selector $selector `
            -Markers @($markers) `
            -Description $Description
    }
    $expectedMarker = Get-RawLogIssue23GateMarker -IssueName $IssueName -Gate $Gate -Command $command
    Assert-RawLogCondition (@($markers | Where-Object { [string]$_ -ceq $expectedMarker }).Count -eq 1) "$Description.rawLogMarkers must contain the command-bound gate marker"
    [void](Assert-RawLogIssue5RunProvenance -Run $GateEvidence -Description $Description)
    if ($IssueName -ceq 'issue2' -and $Gate -ceq 'noOpenUnwaivedP0P1Blocker') {
        $inventoryProperty = $GateEvidence.PSObject.Properties['blockerInventory']
        Assert-RawLogCondition ($null -ne $inventoryProperty) "$Description.blockerInventory is required for noOpenUnwaivedP0P1Blocker"
        Assert-RawLogBlockerInventory -Inventory $inventoryProperty.Value -ExpectedCommit $ExpectedCommit -Description "$Description.blockerInventory"
    }
    $result = [pscustomobject]@{
        gate = $Gate
        status = $true
        gateId = "$IssueName.$Gate"
        sourceCommit = [string]$sourceCommit
        provider = $provider
        hostType = $hostType
        evidenceId = $gateEvidenceId
        runId = [string](Get-RawLogProperty -Object $GateEvidence -Path 'runId' -Description $Description)
        node = $node
        exitCode = [int64](Get-RawLogProperty -Object $GateEvidence -Path 'exitCode' -Description $Description)
        tests = (Get-RawLogProperty -Object $GateEvidence -Path 'tests' -Description $Description)
        startedAt = Format-RawLogInstantUtc -Value $startedAt
        endedAt = Format-RawLogInstantUtc -Value $endedAt
        testSelector = $selector
        command = $command
        markers = @($markers)
    }
    if ($IssueName -ceq 'issue2' -and $Gate -ceq 'noOpenUnwaivedP0P1Blocker') {
        $result | Add-Member -MemberType NoteProperty -Name blockerInventory -Value $GateEvidence.blockerInventory
    }
    if ($IssueName -ceq 'issue3') {
        foreach ($propertyName in @('platform', 'architecture', 'operation', 'platforms')) {
            $result | Add-Member -MemberType NoteProperty -Name $propertyName -Value $semanticContract.$propertyName
        }
    }
    return $result
}

function Assert-RawLogIssue23Evidence {
    param(
        [Parameter(Mandatory = $true)][object]$Issue,
        [Parameter(Mandatory = $true)][string]$IssueName,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-RawLogCondition $GaIssue23GateNames.Contains([string]$IssueName) "$Description has a reviewed Issue #2/#3 name"
    $gates = Get-RawLogProperty -Object $Issue -Path 'gates' -Description $Description
    Assert-RawLogCondition (($gates -is [pscustomobject]) -and -not ($gates -is [System.Array])) "$Description.gates is a JSON object"
    $expectedGates = @($GaIssue23GateNames[[string]$IssueName])
    Assert-RawLogCondition (@($gates.PSObject.Properties).Count -eq $expectedGates.Count) "$Description.gates contains exactly the reviewed gate keys"
    foreach ($property in @($gates.PSObject.Properties)) {
        Assert-RawLogCondition ($expectedGates -contains [string]$property.Name) "$Description.gates contains only reviewed gate names"
    }
    $records = New-Object System.Collections.Generic.List[object]
    $markers = New-Object System.Collections.Generic.List[string]
    foreach ($gate in $expectedGates) {
        $gateEvidence = Get-RawLogProperty -Object $gates -Path $gate -Description $Description
        $record = Assert-RawLogIssue23GateEvidence -ManifestIssue $Issue -IssueName $IssueName -Gate $gate -GateEvidence $gateEvidence -ExpectedCommit $ExpectedCommit -Description "$Description.gates.$gate"
        [void]$records.Add($record)
        foreach ($marker in @($record.markers)) {
            if (-not (@($markers | Where-Object { [string]$_ -ceq [string]$marker }).Count -gt 0)) {
                [void]$markers.Add([string]$marker)
            }
        }
    }
    $rawLog = Get-RawLogProperty -Object $Issue -Path 'rawLog' -Description $Description
    $rawMarkers = Get-RawLogProperty -Object $rawLog -Path 'markers' -Description $Description
    Assert-RawLogCondition (($rawMarkers -is [System.Array]) -and $rawMarkers.Count -gt 0) "$Description.rawLog.markers is a non-empty JSON array"
    $seenRawMarkers = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($marker in @($rawMarkers)) {
        Assert-RawLogCondition ($marker -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$marker)) "$Description.rawLog.markers entries are non-empty strings"
        Assert-RawLogCondition ($seenRawMarkers.Add([string]$marker)) "$Description.rawLog.markers entries are unique"
    }
    foreach ($marker in $markers.ToArray()) {
        Assert-RawLogCondition (@($rawMarkers | Where-Object { [string]$_ -ceq [string]$marker }).Count -eq 1) "$Description.rawLog.markers must retain '$marker'"
    }
    return [pscustomobject]@{ gates = $records.ToArray(); markers = $markers.ToArray() }
}

function Assert-RawLogIssue23Content {
    param(
        [Parameter(Mandatory = $true)][object]$Content,
        [Parameter(Mandatory = $true)][object]$ManifestIssue,
        [Parameter(Mandatory = $true)][string]$IssueName,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $manifestContract = Assert-RawLogIssue23Evidence -Issue $ManifestIssue -IssueName $IssueName -ExpectedCommit $ExpectedCommit -Description "$Description.manifest"
    $contentGates = Get-RawLogProperty -Object $Content -Path 'gates' -Description $Description
    Assert-RawLogCondition (($contentGates -is [pscustomobject]) -and -not ($contentGates -is [System.Array])) "$Description.gates is a JSON object"
    Assert-RawLogCondition (@($contentGates.PSObject.Properties).Count -eq $manifestContract.gates.Count) "$Description.gates retains every reviewed gate"
    foreach ($manifestGate in @($manifestContract.gates)) {
        $gateName = [string]$manifestGate.gate
        $contentGateProperty = $contentGates.PSObject.Properties[$gateName]
        Assert-RawLogCondition ($null -ne $contentGateProperty) "$Description.gates.$gateName is present"
        $contentGate = $contentGateProperty.Value
        Assert-RawLogCondition (($contentGate -is [pscustomobject]) -and -not ($contentGate -is [System.Array])) "$Description.gates.$gateName is an object"
        # Re-run the complete gate verifier over the downloaded envelope.  This
        # keeps provider/host/run/selector provenance and command-bound marker
        # checks independent from the manifest-side validation above.
        $contentGateContract = Assert-RawLogIssue23GateEvidence `
            -ManifestIssue $ManifestIssue `
            -IssueName $IssueName `
            -Gate $gateName `
            -GateEvidence $contentGate `
            -ExpectedCommit $ExpectedCommit `
            -Description "$Description.gates.$gateName"
        foreach ($field in @('provider', 'hostType', 'evidenceId', 'runId', 'node', 'testSelector')) {
            Assert-RawLogCondition ([string]$contentGateContract.$field -ceq [string]$manifestGate.$field) "$Description.gates.$gateName.$field must match the manifest"
        }
        if ($IssueName -ceq 'issue3') {
            foreach ($field in @('platform', 'architecture', 'operation')) {
                Assert-RawLogCondition ([string]$contentGateContract.$field -ceq [string]$manifestGate.$field) "$Description.gates.$gateName.$field must match the manifest"
            }
            $manifestPlatforms = @($manifestGate.platforms | ForEach-Object { [string]$_ })
            $contentPlatforms = @($contentGateContract.platforms | ForEach-Object { [string]$_ })
            Assert-RawLogCondition (($contentPlatforms -join ',') -ceq ($manifestPlatforms -join ',')) "$Description.gates.$gateName.platforms must match the manifest"
        }
        $contentCommand = [string]$contentGateContract.command
        Assert-RawLogCondition ((Normalize-RawLogCommand -Command $contentCommand).Equals((Normalize-RawLogCommand -Command ([string]$manifestGate.command)), [StringComparison]::Ordinal)) "$Description.gates.$gateName.command must match the manifest"
        $contentMarkers = @($contentGateContract.markers)
        foreach ($marker in @($manifestGate.markers)) {
            Assert-RawLogCondition (@($contentMarkers | Where-Object { [string]$_ -ceq [string]$marker }).Count -eq 1) "$Description.gates.$gateName.rawLogMarkers must retain '$marker'"
        }
    }
    $contentMarkers = Get-RawLogProperty -Object $Content -Path 'markers' -Description $Description
    Assert-RawLogCondition (($contentMarkers -is [System.Array]) -and $contentMarkers.Count -gt 0) "$Description.markers is a non-empty JSON array"
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($marker in @($contentMarkers)) {
        Assert-RawLogCondition ($marker -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$marker)) "$Description.markers entries are non-empty strings"
        Assert-RawLogCondition ($seen.Add([string]$marker)) "$Description.markers entries are unique"
    }
    foreach ($marker in @($manifestContract.markers)) {
        Assert-RawLogCondition (@($contentMarkers | Where-Object { [string]$_ -ceq [string]$marker }).Count -eq 1) "$Description.markers must retain '$marker'"
    }
}

function Get-RawLogContentJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-RawLogCondition (Test-Path -LiteralPath $Path -PathType Leaf) "$Description exists: $Path"
    $item = Get-Item -LiteralPath $Path -Force
    Assert-RawLogCondition (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and -not $item.PSIsContainer) "$Description is a regular file"
    Assert-RawLogCondition ([long]$item.Length -gt 0) "$Description is not empty"
    Assert-RawLogCondition ([long]$item.Length -le [long]$MaximumRawLogBytes) "$Description is within the 64 MiB limit"
    try {
        $text = [IO.File]::ReadAllText($Path)
    } catch {
        throw "GA raw-log assertion failed: $Description could not be read: $($_.Exception.Message)"
    }
    Assert-RawLogCondition (-not [string]::IsNullOrWhiteSpace($text)) "$Description is not whitespace-only"
    try {
        $content = $text | ConvertFrom-Json
    } catch {
        throw "GA raw-log assertion failed: $Description is not valid JSON: $($_.Exception.Message)"
    }
    Assert-RawLogCondition ($null -ne $content -and ($content -is [pscustomobject]) -and -not ($content -is [System.Array])) "$Description must be one JSON object"
    return $content
}

function Assert-RawLogContent {
    param(
        [Parameter(Mandatory = $true)][object]$Content,
        [Parameter(Mandatory = $true)][object]$ManifestIssue,
        [Parameter(Mandatory = $true)][string]$IssueName,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [Parameter(Mandatory = $true)][string]$EvidenceId,
        [Parameter(Mandatory = $true)][string]$Description,
        [bool]$RequirePositivePassed = $true
    )

    Assert-RawLogCondition ($null -ne $Content -and ($Content -is [pscustomobject]) -and -not ($Content -is [System.Array])) "$Description must be one JSON object"
    Assert-RawLogCondition ([string](Get-RawLogProperty -Object $Content -Path 'schemaVersion' -Description $Description) -ceq $GaRawLogContentSchema) "$Description.schemaVersion must be $GaRawLogContentSchema"
    Assert-RawLogCondition ([string](Get-RawLogProperty -Object $Content -Path 'status' -Description $Description) -ceq 'passed') "$Description.status must be passed"

    $contentCommit = Get-RawLogProperty -Object $Content -Path 'sourceCommit' -Description $Description
    Assert-RawLogCondition ($contentCommit -is [string] -and [string]$contentCommit -match '^[0-9a-fA-F]{40}$') "$Description.sourceCommit must be a full 40-character commit SHA"
    Assert-RawLogCondition ([string]$contentCommit -ieq $ExpectedCommit) "$Description.sourceCommit must match ExpectedCommit"
    $contentIssue = Get-RawLogProperty -Object $Content -Path 'issue' -Description $Description
    Assert-RawLogCondition ($contentIssue -is [string] -and [string]$contentIssue -ceq $IssueName) "$Description.issue must match $IssueName"
    $contentEvidenceId = Get-RawLogProperty -Object $Content -Path 'evidenceId' -Description $Description
    Assert-RawLogCondition ($contentEvidenceId -is [string] -and [string]$contentEvidenceId -ceq $EvidenceId) "$Description.evidenceId must match the manifest"

    $manifestRawLog = Get-RawLogProperty -Object $ManifestIssue -Path 'rawLog' -Description $Description
    [void](Assert-RawLogDescriptor -RawLog $manifestRawLog -IssueName $IssueName -Description "$Description.manifest" -RequirePositivePassed $RequirePositivePassed)
    $manifestCommand = [string](Get-RawLogProperty -Object $manifestRawLog -Path 'command' -Description $Description)
    $contentCommand = Get-RawLogProperty -Object $Content -Path 'command' -Description $Description
    Assert-RawLogCondition ($contentCommand -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$contentCommand)) "$Description.command must be a non-empty string"
    Assert-RawLogCondition ((Normalize-RawLogCommand -Command ([string]$contentCommand)).Equals((Normalize-RawLogCommand -Command $manifestCommand), [StringComparison]::Ordinal)) "$Description.command must match the manifest command"

    $manifestNode = [string](Get-RawLogProperty -Object $manifestRawLog -Path 'node' -Description $Description)
    $nodeProperty = $Content.PSObject.Properties['node']
    $hostProperty = $Content.PSObject.Properties['host']
    $hasNode = $null -ne $nodeProperty
    $hasHost = $null -ne $hostProperty
    if ($hasNode) {
        Assert-RawLogCondition ($nodeProperty.Value -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$nodeProperty.Value)) "$Description.node must be a non-empty string"
    }
    if ($hasHost) {
        Assert-RawLogCondition ($hostProperty.Value -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$hostProperty.Value)) "$Description.host must be a non-empty string"
    }
    Assert-RawLogCondition ($hasNode -or $hasHost) "$Description must contain a non-empty node or host"
    if ($hasNode -and $hasHost) {
        Assert-RawLogCondition ([string]$nodeProperty.Value -ceq [string]$hostProperty.Value) "$Description.node and $Description.host must agree"
    }
    $boundNode = if ($hasNode) { [string]$nodeProperty.Value } else { [string]$hostProperty.Value }
    Assert-RawLogCondition ($boundNode -ceq $manifestNode) "$Description.node/host must match the manifest node"
    Assert-RawLogCondition ($boundNode -notmatch '(?i)github|actions|hosted|runner') "$Description.node/host must identify an external host"

    $manifestStartedAt = Convert-RawLogInstant -Value (Get-RawLogProperty -Object $manifestRawLog -Path 'startedAt' -Description $Description) -Description "$Description.manifest.startedAt"
    $manifestEndedAt = Convert-RawLogInstant -Value (Get-RawLogProperty -Object $manifestRawLog -Path 'endedAt' -Description $Description) -Description "$Description.manifest.endedAt"
    $contentStartedAt = Convert-RawLogInstant -Value (Get-RawLogProperty -Object $Content -Path 'startedAt' -Description $Description) -Description "$Description.startedAt"
    $contentEndedAt = Convert-RawLogInstant -Value (Get-RawLogProperty -Object $Content -Path 'endedAt' -Description $Description) -Description "$Description.endedAt"
    Assert-RawLogCondition ($contentEndedAt -ge $contentStartedAt) "$Description.endedAt must not precede startedAt"
    Assert-RawLogCondition ($contentStartedAt.UtcDateTime.Ticks -eq $manifestStartedAt.UtcDateTime.Ticks) "$Description.startedAt must match the manifest"
    Assert-RawLogCondition ($contentEndedAt.UtcDateTime.Ticks -eq $manifestEndedAt.UtcDateTime.Ticks) "$Description.endedAt must match the manifest"

    $manifestExitCode = Get-RawLogProperty -Object $manifestRawLog -Path 'exitCode' -Description $Description
    $contentExitCode = Get-RawLogProperty -Object $Content -Path 'exitCode' -Description $Description
    Assert-RawLogCondition ((Test-RawLogInteger -Value $contentExitCode) -and [decimal]$contentExitCode -eq 0) "$Description.exitCode must be integer 0"
    Assert-RawLogCondition ((Test-RawLogInteger -Value $manifestExitCode) -and [decimal]$manifestExitCode -eq 0) "$Description.manifest.exitCode must be integer 0"
    Assert-RawLogCondition ([decimal]$contentExitCode -eq [decimal]$manifestExitCode) "$Description.exitCode must match the manifest"

    $manifestTests = Get-RawLogProperty -Object $manifestRawLog -Path 'tests' -Description $Description
    $contentTests = Get-RawLogProperty -Object $Content -Path 'tests' -Description $Description
    Assert-RawLogCondition (($contentTests -is [pscustomobject]) -and -not ($contentTests -is [System.Array])) "$Description.tests must be a JSON object"
    Assert-RawLogCondition (($manifestTests -is [pscustomobject]) -and -not ($manifestTests -is [System.Array])) "$Description.manifest.tests must be a JSON object"
    foreach ($field in @('passed', 'failed', 'ignored')) {
        $contentCount = Get-RawLogProperty -Object $contentTests -Path $field -Description "$Description.tests"
        $manifestCount = Get-RawLogProperty -Object $manifestTests -Path $field -Description "$Description.manifest.tests"
        [void](Assert-RawLogCount -Value $contentCount -Description "$Description.tests.$field" -RequirePositive ($RequirePositivePassed -and $field -ceq 'passed'))
        [void](Assert-RawLogCount -Value $manifestCount -Description "$Description.manifest.tests.$field" -RequirePositive ($RequirePositivePassed -and $field -ceq 'passed'))
        Assert-RawLogCondition ([decimal]$contentCount -eq [decimal]$manifestCount) "$Description.tests.$field must match the manifest"
    }
    Assert-RawLogCondition ([decimal]$contentTests.failed -eq 0) "$Description.tests.failed must be zero"
    $manifestCleanup = Get-RawLogProperty -Object $manifestRawLog -Path 'cleanup' -Description $Description
    $contentCleanup = Get-RawLogProperty -Object $Content -Path 'cleanup' -Description $Description
    Assert-RawLogCondition (($contentCleanup -is [bool]) -and $contentCleanup) "$Description.cleanup must be boolean true"
    Assert-RawLogCondition (($manifestCleanup -is [bool]) -and $manifestCleanup) "$Description.manifest.cleanup must be boolean true"
    Assert-RawLogCondition ([bool]$contentCleanup -eq [bool]$manifestCleanup) "$Description.cleanup must match the manifest"

    if ($IssueName -ceq 'issue5') {
        $manifestMarkers = Get-RawLogProperty -Object $manifestRawLog -Path 'markers' -Description $Description
        $contentMarkers = Get-RawLogProperty -Object $Content -Path 'markers' -Description $Description
        Assert-RawLogCondition (($contentMarkers -is [System.Array]) -and $contentMarkers.Count -gt 0) "$Description.markers must be a non-empty JSON array"
        $seenContentMarkers = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($marker in @($contentMarkers)) {
            Assert-RawLogCondition ($marker -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$marker)) "$Description.markers entries must be non-empty strings"
            Assert-RawLogCondition ($seenContentMarkers.Add([string]$marker)) "$Description.markers entries must be unique"
        }
        foreach ($marker in @($manifestMarkers)) {
            Assert-RawLogCondition (@($contentMarkers | Where-Object { [string]$_ -ceq [string]$marker }).Count -eq 1) "$Description.markers must retain the manifest marker '$marker'"
        }
    } elseif ($IssueName -ceq 'issue2' -or $IssueName -ceq 'issue3') {
        [void](Assert-RawLogIssue23Content `
            -Content $Content `
            -ManifestIssue $ManifestIssue `
            -IssueName $IssueName `
            -ExpectedCommit $ExpectedCommit `
            -Description $Description)
    }
    return $Content
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
    Assert-RawLogCondition ((Test-RawLogInteger -Value $exitCode) -and [decimal]$exitCode -eq 0) "$Description.exitCode is integer zero"

    $tests = Get-RawLogProperty -Object $Run -Path 'tests' -Description $Description
    Assert-RawLogCondition (($tests -is [pscustomobject]) -and -not ($tests -is [System.Array])) "$Description.tests is a JSON object"
    foreach ($countName in @('passed', 'failed', 'ignored')) {
        Assert-RawLogCondition ($null -ne $tests.PSObject.Properties[$countName]) "$Description.tests.$countName is required"
        $count = $tests.PSObject.Properties[$countName].Value
        [void](Assert-RawLogCount -Value $count -Description "$Description.tests.$countName" -RequirePositive ($countName -ceq 'passed'))
    }
    Assert-RawLogCondition ([decimal]$tests.PSObject.Properties['failed'].Value -eq 0) "$Description.tests.failed is zero"

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
        startedAt = Format-RawLogInstantUtc -Value $startedAt
        endedAt = Format-RawLogInstantUtc -Value $endedAt
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

    return Normalize-RawLogCommand -Command $Command
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
    # Keep raw-log verification type-sensitive with the manifest validator:
    # scalars, non-string entries, and duplicate markers are malformed evidence,
    # not values to coerce into a valid array.
    if ($null -ne $canonicalProperty) {
        Assert-RawLogCondition ($canonicalProperty.Value -is [System.Array]) "$Description.rawLogMarkers is a JSON array"
    }
    if ($null -ne $aliasProperty) {
        Assert-RawLogCondition ($aliasProperty.Value -is [System.Array]) "$Description.markers is a JSON array"
    }
    $canonicalMarkers = if ($null -ne $canonicalProperty) { @($canonicalProperty.Value) } else { $null }
    $aliasMarkers = if ($null -ne $aliasProperty) { @($aliasProperty.Value) } else { $null }
    if ($null -ne $canonicalProperty -and $null -ne $aliasProperty) {
        Assert-RawLogCondition ($canonicalMarkers.Count -eq $aliasMarkers.Count) "$Description.rawLogMarkers and markers aliases have the same length"
        for ($index = 0; $index -lt $canonicalMarkers.Count; $index++) {
            Assert-RawLogCondition (($canonicalMarkers[$index] -is [string]) -and ($aliasMarkers[$index] -is [string])) "$Description.rawLogMarkers and markers aliases entries are both strings"
            Assert-RawLogCondition ($canonicalMarkers[$index] -ceq $aliasMarkers[$index]) "$Description.rawLogMarkers and markers aliases must match exactly"
        }
    }
    # Keep a single marker as an array; PowerShell unwraps one-element arrays
    # when a conditional expression is assigned directly.
    $markers = if ($null -ne $canonicalProperty) { @($canonicalMarkers) } else { @($aliasMarkers) }
    Assert-RawLogCondition (($null -ne $markers) -and ($markers -is [System.Array]) -and $markers.Count -gt 0) "$Description.rawLogMarkers is a non-empty array"
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($marker in @($markers)) {
        Assert-RawLogCondition ($marker -is [string] -and -not [string]::IsNullOrWhiteSpace($marker)) "$Description.rawLogMarkers entries are non-empty strings"
        Assert-RawLogCondition ($seen.Add([string]$marker)) "$Description.rawLogMarkers entries are unique"
    }
    return [string[]]@($markers)
}

function Assert-RawLogIssue5PositiveSelector {
    param(
        [Parameter(Mandatory = $true)][string]$Platform,
        [Parameter(Mandatory = $true)][string]$Selector,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $normalizedPlatform = $Platform.ToLowerInvariant()
    if ($GaIssue5DisallowedSelectors.Contains($normalizedPlatform)) {
        foreach ($disallowed in @($GaIssue5DisallowedSelectors[$normalizedPlatform])) {
            Assert-RawLogCondition (-not $Selector.Equals([string]$disallowed, [StringComparison]::Ordinal)) "$Description.testSelector '$Selector' is a fail-closed regression selector, not positive native containment evidence"
        }
    }
    Assert-RawLogCondition ($GaIssue5ExpectedSelectors.Contains($normalizedPlatform)) "$Description.testSelector has no reviewed positive selector for platform '$normalizedPlatform'"
    Assert-RawLogCondition ($Selector.Equals([string]$GaIssue5ExpectedSelectors[$normalizedPlatform], [StringComparison]::Ordinal)) "$Description.testSelector must be the exact positive native '$normalizedPlatform' selector"
}

function Assert-RawLogIssue5RequiredMarkers {
    param(
        [Parameter(Mandatory = $true)][string[]]$Markers,
        [Parameter(Mandatory = $true)][string]$Gate,
        [Parameter(Mandatory = $true)][string]$Platform,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $requiredPrefixes = @()
    if ($GaIssue5RequiredMarkerPrefixes.Contains($Gate)) {
        $requiredPrefixes = @($GaIssue5RequiredMarkerPrefixes[$Gate])
    }
    if ($requiredPrefixes.Count -gt 0) {
        foreach ($prefix in $requiredPrefixes) {
            $matched = @($Markers | Where-Object {
                    $candidate = [string]$_
                    $candidate.Equals($prefix, [StringComparison]::Ordinal) -or
                    $candidate.StartsWith($prefix, [StringComparison]::Ordinal)
                })
            Assert-RawLogCondition ($matched.Count -gt 0) "$Description.rawLogMarkers contains a native marker beginning with '$prefix'"
        }
    }
    if ($GaIssue5PlatformGateMarkerPrefixes.Contains($Gate)) {
        $markerPlatforms = if ($Platform -ceq 'multi-platform') { @($GaIssue5Platforms) } else { @($Platform.ToLowerInvariant()) }
        foreach ($markerPlatform in $markerPlatforms) {
            Assert-RawLogCondition ($GaIssue5PlatformGateMarkerPrefixes[$Gate].Contains($markerPlatform)) "$Description.rawLogMarkers has no reviewed platform marker contract for '$Gate' on '$markerPlatform'"
            foreach ($prefix in @($GaIssue5PlatformGateMarkerPrefixes[$Gate][$markerPlatform])) {
                $matched = @($Markers | Where-Object {
                        $candidate = [string]$_
                        $candidate.Equals($prefix, [StringComparison]::Ordinal) -or
                        $candidate.StartsWith($prefix, [StringComparison]::Ordinal)
                    })
                Assert-RawLogCondition ($matched.Count -gt 0) "$Description.rawLogMarkers contains the '$markerPlatform' native marker beginning with '$prefix'"
            }
        }
    }
    if ($Gate -ceq 'restartResidualProcessReconciliation') {
        $markerPlatforms = if ($Platform -ceq 'multi-platform') { @($GaIssue5Platforms) } else { @($Platform.ToLowerInvariant()) }
        foreach ($markerPlatform in $markerPlatforms) {
            Assert-RawLogCondition ($GaIssue5ResidualMarkerPrefixes.Contains($markerPlatform)) "$Description.rawLogMarkers has no reviewed residual marker contract for platform '$markerPlatform'"
            $anyMatched = @()
            foreach ($prefix in @($GaIssue5ResidualMarkerPrefixes[$markerPlatform])) {
                $anyMatched += @($Markers | Where-Object {
                        $candidate = [string]$_
                        $candidate.Equals($prefix, [StringComparison]::Ordinal) -or
                        $candidate.StartsWith($prefix, [StringComparison]::Ordinal)
                    })
            }
            Assert-RawLogCondition ($anyMatched.Count -gt 0) "$Description.rawLogMarkers must contain a native residual-process reconciliation marker for platform '$markerPlatform'"
        }
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
    Assert-RawLogIssue5PositiveSelector -Platform $platform -Selector $selector -Description "$Description.gates.$Gate"
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
        Assert-RawLogIssue5PositiveSelector -Platform $platform -Selector $selector -Description "$Description.gates.$Gate.runs.$platform"
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
    $seenRawMarkers = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($rawMarker in @($rawMarkers)) {
        Assert-RawLogCondition ($rawMarker -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$rawMarker)) "$Description.markers entries are non-empty strings"
        $rawMarkerText = [string]$rawMarker
        Assert-RawLogCondition ($seenRawMarkers.Add($rawMarkerText)) "$Description.markers entries are unique"
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

if ($ContractOnly) {
    # Keep the parser/contract helpers dot-sourceable for focused regression
    # tests without touching the filesystem or making an external request.
    return
}

Assert-RawLogCondition (-not [string]::IsNullOrWhiteSpace($EvidencePath)) 'EvidencePath is required unless -ContractOnly is used'
Assert-RawLogCondition (-not [string]::IsNullOrWhiteSpace($OutputDirectory)) 'OutputDirectory is required unless -ContractOnly is used'
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
    [void](Assert-RawLogDescriptor -RawLog $rawLog -IssueName $issueName -Description $issueName -RequirePositivePassed $true)
    $urlText = [string](Get-RawLogProperty -Object $rawLog -Path 'url' -Description $issueName)
    $uri = $null
    Assert-RawLogCondition ([Uri]::TryCreate($urlText, [UriKind]::Absolute, [ref]$uri)) "$issueName.rawLog.url is an absolute URL"
    Assert-RawLogCondition ($uri.Scheme.Equals('https', [StringComparison]::OrdinalIgnoreCase)) "$issueName.rawLog.url uses HTTPS"
    Assert-RawLogCondition (-not [string]::IsNullOrWhiteSpace($uri.Host) -and [string]::IsNullOrWhiteSpace($uri.UserInfo)) "$issueName.rawLog.url has a host and no embedded credentials"
    Assert-RawLogCondition (-not $seenUrls.ContainsKey($uri.AbsoluteUri)) "raw log URL is unique: $urlText"
    $seenUrls[$uri.AbsoluteUri] = $true
    $expectedHash = [string](Get-RawLogProperty -Object $rawLog -Path 'sha256' -Description $issueName)
    Assert-RawLogCondition ($expectedHash -match '^[0-9a-fA-F]{64}$') "$issueName.rawLog.sha256 is a SHA-256 digest"

    $issue23Contract = $null
    $issue5Contract = $null
    if ($issueName -ceq 'issue2' -or $issueName -ceq 'issue3') {
        # Issue #2/#3 are structured per-gate evidence records.  Validate the
        # manifest before downloading so a raw-log URL cannot be used to hide
        # a missing/ambiguous acceptance gate.
        $issue23Contract = Assert-RawLogIssue23Evidence `
            -Issue $issue `
            -IssueName $issueName `
            -ExpectedCommit $ExpectedCommit `
            -Description $issueName
    } elseif ($issueName -ceq 'issue5') {
        $issue5Contract = Assert-RawLogIssue5Evidence -Issue $issue -Description 'issue5'
    }

    $logPath = Join-Path $outputRoot "$evidenceId.log"
    [long]$bytes = Save-RawLogFromHttps -Uri $uri -Destination $logPath
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $logPath).Hash.ToLowerInvariant()
    Assert-RawLogCondition ($actualHash -ceq $expectedHash.ToLowerInvariant()) "$issueName raw log bytes match rawLog.sha256"
    $downloadedContent = Get-RawLogContentJson -Path $logPath -Description "$issueName raw log content"
    [void](Assert-RawLogContent `
        -Content $downloadedContent `
        -ManifestIssue $issue `
        -IssueName $issueName `
        -ExpectedCommit $ExpectedCommit `
        -EvidenceId $evidenceId `
        -Description "$issueName raw log content" `
        -RequirePositivePassed $true)
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
        contentVerified = $true
        content = $downloadedContent
    }
    if ($issueName -ceq 'issue5') {
        $record.markersVerified = $true
        $record.platforms = $issue5Contract.platforms
        $record.markers = $issue5Contract.markers
        $record.gateEvidence = $issue5Contract.gates
    } elseif ($issueName -ceq 'issue2' -or $issueName -ceq 'issue3') {
        $record.markersVerified = $true
        $record.markers = $issue23Contract.markers
        $record.gateEvidence = $issue23Contract.gates
    }
    $recordForOutput = Convert-RawLogJsonValueToInvariantIso `
        -Value $record `
        -Description "$issueName verification record"
    Write-RawLogAtomicText `
        -Path (Join-Path $outputRoot "$evidenceId.verification.json") `
        -Text ($recordForOutput | ConvertTo-Json -Depth 20) `
        -Encoding (New-Object System.Text.UTF8Encoding($false))
    [void]$records.Add($recordForOutput)
}

$result = [ordered]@{
    schemaVersion = 'cyc.dev/ga-raw-log-verification/v1'
    status = 'passed'
    sourceCommit = $ExpectedCommit.ToLowerInvariant()
    records = $records.ToArray()
}
$resultForOutput = Convert-RawLogJsonValueToInvariantIso `
    -Value $result `
    -Description 'raw-log verification result'
$resultJson = $resultForOutput | ConvertTo-Json -Depth 20 -Compress
Write-RawLogAtomicText `
    -Path (Join-Path $outputRoot 'raw-log-verification.json') `
    -Text $resultJson `
    -Encoding (New-Object System.Text.UTF8Encoding($false))
$resultJson
