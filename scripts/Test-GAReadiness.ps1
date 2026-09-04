#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepositoryRoot,

    [string]$ExpectedTag,

    [string]$ExpectedCommit,

    [string]$EvidencePath,

    [string]$RawLogVerificationPath,

    [string]$IssueSnapshotPath,

    [string]$LiveBlockerSnapshotPath,

    [string]$ControlsPath,

    [switch]$ContractOnly,

    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}
$RepositoryRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
$GaMaximumEvidenceBytes = 64MB
$GaMaximumRawLogTestCount = [long]1000000000
$GaRawLogContentSchema = 'cyc.dev/ga-raw-log/v1'
$GaOpenIssueSnapshotSchema = 'cyc.dev/ga-open-issue-snapshot/v1'
$GaMaximumBlockerInventoryAge = [TimeSpan]::FromHours(24)
$GaIssue3GateContractPath = Join-Path $PSScriptRoot 'ga-issue3-gate-contract.json'
if (-not (Test-Path -LiteralPath $GaIssue3GateContractPath -PathType Leaf)) {
    throw "GA readiness assertion failed: Issue #3 semantic gate contract is missing: $GaIssue3GateContractPath"
}
try {
    $GaIssue3GateContract = ([System.IO.File]::ReadAllText($GaIssue3GateContractPath) | ConvertFrom-Json)
} catch {
    throw "GA readiness assertion failed: Issue #3 semantic gate contract is not valid JSON: $($_.Exception.Message)"
}
if ($null -eq $GaIssue3GateContract -or
    [string]$GaIssue3GateContract.schemaVersion -cne 'cyc.dev/ga-issue3-gate-contract/v2' -or
    $null -eq $GaIssue3GateContract.gates -or
    $GaIssue3GateContract.gates -is [System.Array]) {
    throw 'GA readiness assertion failed: Issue #3 semantic gate contract has an invalid schema.'
}

function Assert-GaCondition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw "GA readiness assertion failed: $Message"
    }
}

function Get-GaText {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $path = Join-Path $RepositoryRoot $RelativePath
    Assert-GaCondition (Test-Path -LiteralPath $path -PathType Leaf) "required file exists: $RelativePath"
    return [System.IO.File]::ReadAllText($path)
}

function Get-GaJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-GaCondition (Test-Path -LiteralPath $Path -PathType Leaf) "$Description exists: $Path"
    $item = Get-Item -LiteralPath $Path -Force
    Assert-GaCondition (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) "$Description is not a reparse point: $Path"
    Assert-GaCondition ([long]$item.Length -le [long]$GaMaximumEvidenceBytes) "$Description exceeds the $([long]$GaMaximumEvidenceBytes)-byte size limit: $Path"
    try {
        return [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
    } catch {
        throw "$Description is not valid JSON: $($_.Exception.Message)"
    }
}

function Get-GaProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $current = $Object
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $current) {
            throw "GA readiness assertion failed: $Description is missing property '$Path'."
        }
        $property = $current.PSObject.Properties[$part]
        if ($null -eq $property) {
            throw "GA readiness assertion failed: $Description is missing property '$Path'."
        }
        $current = $property.Value
    }
    return $current
}

function Test-GaInteger {
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

function Assert-GaRawLogCount {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Description,
        [bool]$RequirePositive = $false
    )

    Assert-GaCondition (Test-GaInteger -Value $Value) "$Description must be an integer"
    try {
        [decimal]$numeric = $Value
    } catch {
        throw "GA readiness assertion failed: $Description is outside the supported integer range."
    }
    Assert-GaCondition ($numeric -ge 0) "$Description must be non-negative"
    Assert-GaCondition ($numeric -le [decimal]$GaMaximumRawLogTestCount) "$Description must not exceed $GaMaximumRawLogTestCount"
    if ($RequirePositive) {
        Assert-GaCondition ($numeric -gt 0) "$Description must be greater than zero"
    }
    return [long]$numeric
}

function Convert-GaRawLogInstant {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-GaCondition ($Value -is [string] -or
        $Value -is [DateTime] -or $Value -is [DateTimeOffset]) "$Description must be an ISO-8601 instant"
    try {
        if ($Value -is [DateTimeOffset]) {
            return [DateTimeOffset]$Value
        }
        if ($Value -is [DateTime]) {
            Assert-GaCondition ($Value.Kind -ne [DateTimeKind]::Unspecified) "$Description must carry an explicit UTC offset"
            return [DateTimeOffset]$Value
        }

        $text = [string]$Value
        Assert-GaCondition ($text -match '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$') "$Description must include a UTC designator or numeric offset"
        return [DateTimeOffset]::Parse(
            $text,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
    } catch {
        throw "GA readiness assertion failed: $Description must be a valid ISO-8601 instant with an explicit offset."
    }
}

function Normalize-GaRawLogCommand {
    param([Parameter(Mandatory = $true)][string]$Command)

    return [regex]::Replace($Command.Trim(), '\s+', ' ')
}

function Assert-GaString {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Description,
        [switch]$CaseInsensitive
    )

    $actual = [string](Get-GaProperty -Object $Object -Path $Path -Description $Description)
    $matches = if ($CaseInsensitive) {
        $actual.Equals($Expected, [System.StringComparison]::OrdinalIgnoreCase)
    } else {
        $actual.Equals($Expected, [System.StringComparison]::Ordinal)
    }
    Assert-GaCondition $matches "$Description.$Path must equal '$Expected' (observed '$actual')"
    return $actual
}

function Assert-GaTrue {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $actual = Get-GaProperty -Object $Object -Path $Path -Description $Description
    Assert-GaCondition (($actual -is [bool]) -and $actual) "$Description.$Path must be boolean true (observed '$actual')"
}

function Assert-GaExternalEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$Evidence,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit
    )

    $node = Get-GaProperty -Object $Evidence -Path $Path -Description $Description
    [void](Assert-GaString -Object $node -Path 'status' -Expected 'passed' -Description $Description)
    $provider = [string](Get-GaProperty -Object $node -Path 'provider' -Description $Description)
    $hostType = [string](Get-GaProperty -Object $node -Path 'hostType' -Description $Description)
    Assert-GaCondition (-not [string]::IsNullOrWhiteSpace($provider)) "$Description.provider must be present"
    Assert-GaCondition (-not [string]::IsNullOrWhiteSpace($hostType)) "$Description.hostType must be present"
    Assert-GaCondition ($provider -notmatch '(?i)github|actions|hosted|runner') "$Description must identify an external host, not a GitHub-hosted runner (provider='$provider')"
    Assert-GaCondition ($hostType -notmatch '(?i)github|actions|hosted|runner') "$Description must identify an external host, not a GitHub-hosted runner (hostType='$hostType')"
    $sourceCommit = [string](Get-GaProperty -Object $node -Path 'sourceCommit' -Description $Description)
    Assert-GaCondition ($sourceCommit -match '^[0-9a-fA-F]{40}$') "$Description.sourceCommit must be a full 40-character commit SHA"
    Assert-GaCondition ($sourceCommit.Equals($ExpectedCommit, [System.StringComparison]::OrdinalIgnoreCase)) "$Description.sourceCommit must match the reviewed stable source commit"
    $evidenceId = [string](Get-GaProperty -Object $node -Path 'evidenceId' -Description $Description)
    Assert-GaCondition (-not [string]::IsNullOrWhiteSpace($evidenceId)) "$Description.evidenceId must identify retained raw evidence"
    return $node
}

$GaEvidenceCoreTopLevelNames = @(
    'schemaVersion',
    'status',
    'productVersion',
    'sourceTag',
    'sourceCommit',
    'issue2',
    'issue3',
    'issue5',
    'windowsCleanVm',
    'macosLaunchAgent',
    'windowsAuthenticode',
    'artifactVerification'
)

function Assert-GaEvidenceHostRecordSet {
    param(
        [Parameter(Mandatory = $true)][object]$Evidence,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit
    )

    # Keep the evidence schema closed for metadata while allowing a future
    # external-host record to be added only when it follows the same identity
    # contract. This makes the documentation's "each other host record"
    # requirement executable instead of relying on three hard-coded paths.
    foreach ($property in @($Evidence.PSObject.Properties)) {
        if ($property.Name -in $GaEvidenceCoreTopLevelNames) {
            continue
        }
        Assert-GaCondition ($property.Name -match '^[A-Za-z][A-Za-z0-9_-]{0,63}$') "external GA evidence has an invalid top-level record name '$($property.Name)'"
        Assert-GaCondition (($property.Value -is [pscustomobject]) -and -not ($property.Value -is [System.Array])) "external GA evidence host record '$($property.Name)' must be a JSON object"
        [void](Assert-GaExternalEvidence -Evidence $Evidence -Path $property.Name -Description "external GA evidence host record '$($property.Name)'" -ExpectedCommit $ExpectedCommit)
    }
}

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

$GaIssue5GateNames = @(
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

# Issue #5 is a platform matrix, not a second copy of the generic
# ``gates: { ...: true }`` contract.  Keep the matrix contract here (and in
# Test-GARawLogs.ps1, which must validate the downloaded bytes) so a single
# Linux cargo invocation cannot be relabelled as Windows/macOS/restart proof.
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
# These are the native Linux probe markers already emitted by the hostile
# isolation test/result.  A marker is matched as a prefix so dynamic values
# such as ``uid=1007`` remain valid while a generic ``ok`` line cannot satisfy
# the gate.  Cross-platform rows still require their source-bound composite
# marker; platform-specific native implementations may add their own detail.
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
    # ``residual_empty`` is emitted by the Linux cgroup probe.  Windows and
    # macOS must carry a native process-scope/guard marker; a generic empty
    # receipt is not containment proof for either external backend.
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

function Assert-GaIssue5RunProvenance {
    param(
        [Parameter(Mandatory = $true)][object]$Run,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-GaCondition (($Run -is [pscustomobject]) -and -not ($Run -is [System.Array])) "$Description must be a JSON object"
    foreach ($required in @('runId', 'node', 'provider', 'hostType', 'status', 'exitCode', 'tests', 'startedAt', 'endedAt')) {
        Assert-GaCondition ($null -ne $Run.PSObject.Properties[$required]) "$Description.$required is required for source-bound run provenance"
    }

    $runIdValue = Get-GaProperty -Object $Run -Path 'runId' -Description $Description
    Assert-GaCondition ($runIdValue -is [string]) "$Description.runId must be a JSON string"
    $runId = [string]$runIdValue
    Assert-GaCondition ($runId -match $GaIssue5RunIdentifierPattern) "$Description.runId must be a bounded portable run identifier"
    $nodeValue = Get-GaProperty -Object $Run -Path 'node' -Description $Description
    Assert-GaCondition ($nodeValue -is [string]) "$Description.node must be a JSON string"
    $node = [string]$nodeValue
    Assert-GaCondition ($node -match $GaIssue5RunIdentifierPattern) "$Description.node must be a bounded portable node identifier"
    Assert-GaCondition ($node -notmatch '(?i)github|actions|hosted|runner') "$Description.node must not identify a GitHub-hosted execution surface"
    $providerValue = Get-GaProperty -Object $Run -Path 'provider' -Description $Description
    $hostTypeValue = Get-GaProperty -Object $Run -Path 'hostType' -Description $Description
    Assert-GaCondition ($providerValue -is [string]) "$Description.provider must be a JSON string"
    Assert-GaCondition ($hostTypeValue -is [string]) "$Description.hostType must be a JSON string"
    $provider = [string]$providerValue
    $hostType = [string]$hostTypeValue
    foreach ($field in @('provider', 'hostType')) {
        $value = if ($field -ceq 'provider') { $provider } else { $hostType }
        Assert-GaCondition (-not [string]::IsNullOrWhiteSpace($value)) "$Description.$field must be a non-empty external identifier"
        Assert-GaCondition ($value -notmatch '(?i)github|actions|hosted|runner') "$Description.$field must not identify a GitHub-hosted execution surface"
    }

    $status = Get-GaProperty -Object $Run -Path 'status' -Description $Description
    $statusPassed = (($status -is [string]) -and ([string]$status).Equals('passed', [System.StringComparison]::Ordinal)) -or (($status -is [bool]) -and $status)
    Assert-GaCondition $statusPassed "$Description.status must be 'passed' (or boolean true for a single-gate record)"

    $exitCode = Get-GaProperty -Object $Run -Path 'exitCode' -Description $Description
    Assert-GaCondition ((Test-GaInteger -Value $exitCode) -and [decimal]$exitCode -eq 0) "$Description.exitCode must be integer zero"

    $tests = Get-GaProperty -Object $Run -Path 'tests' -Description $Description
    Assert-GaCondition (($tests -is [pscustomobject]) -and -not ($tests -is [System.Array])) "$Description.tests must be a JSON object"
    foreach ($countName in @('passed', 'failed', 'ignored')) {
        Assert-GaCondition ($null -ne $tests.PSObject.Properties[$countName]) "$Description.tests.$countName is required"
        $count = $tests.PSObject.Properties[$countName].Value
        [void](Assert-GaRawLogCount -Value $count -Description "$Description.tests.$countName" -RequirePositive ($countName -ceq 'passed'))
    }
    Assert-GaCondition ([decimal]$tests.PSObject.Properties['failed'].Value -eq 0) "$Description.tests.failed must be zero"

    $startedValue = Get-GaProperty -Object $Run -Path 'startedAt' -Description $Description
    $endedValue = Get-GaProperty -Object $Run -Path 'endedAt' -Description $Description
    Assert-GaCondition ($startedValue -is [string] -or $startedValue -is [DateTime] -or $startedValue -is [DateTimeOffset]) "$Description.startedAt must be an ISO-8601 instant with an explicit timezone"
    Assert-GaCondition ($endedValue -is [string] -or $endedValue -is [DateTime] -or $endedValue -is [DateTimeOffset]) "$Description.endedAt must be an ISO-8601 instant with an explicit timezone"
    try {
        if ($startedValue -is [DateTimeOffset]) {
            $startedAt = [DateTimeOffset]$startedValue
        } elseif ($startedValue -is [DateTime]) {
            Assert-GaCondition ($startedValue.Kind -ne [DateTimeKind]::Unspecified) "$Description.startedAt must carry an explicit UTC offset"
            $startedAt = [DateTimeOffset]$startedValue
        } else {
            $startedText = [string]$startedValue
            Assert-GaCondition ($startedText -match $GaIssue5IsoInstantPattern) "$Description.startedAt must include a UTC designator or numeric offset"
            $startedAt = [DateTimeOffset]::Parse($startedText, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        }
        if ($endedValue -is [DateTimeOffset]) {
            $endedAt = [DateTimeOffset]$endedValue
        } elseif ($endedValue -is [DateTime]) {
            Assert-GaCondition ($endedValue.Kind -ne [DateTimeKind]::Unspecified) "$Description.endedAt must carry an explicit UTC offset"
            $endedAt = [DateTimeOffset]$endedValue
        } else {
            $endedText = [string]$endedValue
            Assert-GaCondition ($endedText -match $GaIssue5IsoInstantPattern) "$Description.endedAt must include a UTC designator or numeric offset"
            $endedAt = [DateTimeOffset]::Parse($endedText, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        }
    } catch {
        throw "GA readiness assertion failed: $Description timestamps are not parseable ISO-8601 instants."
    }
    Assert-GaCondition ($endedAt -ge $startedAt) "$Description.endedAt must not precede startedAt"

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

function Assert-GaIssue5RunPlatformBinding {
    param(
        [Parameter(Mandatory = $true)][hashtable]$RunPlatformMap,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Platform,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ($RunPlatformMap.ContainsKey($RunId)) {
        Assert-GaCondition ([string]$RunPlatformMap[$RunId] -ceq $Platform) "$Description.runId '$RunId' must remain bound to platform '$($RunPlatformMap[$RunId])', not '$Platform'"
    } else {
        $RunPlatformMap[$RunId] = $Platform
    }
}

function Assert-GaIssue5RunProvenanceMatch {
    param(
        [Parameter(Mandatory = $true)][object]$ManifestRun,
        [Parameter(Mandatory = $true)][object]$VerifiedRun,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $manifest = Assert-GaIssue5RunProvenance -Run $ManifestRun -Description "$Description.manifest"
    $verified = Assert-GaIssue5RunProvenance -Run $VerifiedRun -Description "$Description.verified"
    foreach ($field in @('runId', 'node', 'provider', 'hostType', 'status', 'startedAt', 'endedAt')) {
        Assert-GaCondition ([string]$verified.$field -ceq [string]$manifest.$field) "$Description.$field must match the source-bound manifest"
    }
    Assert-GaCondition ([int64]$verified.exitCode -eq [int64]$manifest.exitCode) "$Description.exitCode must match the source-bound manifest"
    foreach ($countName in @('passed', 'failed', 'ignored')) {
        Assert-GaCondition ([int64]$verified.tests.PSObject.Properties[$countName].Value -eq [int64]$manifest.tests.PSObject.Properties[$countName].Value) "$Description.tests.$countName must match the source-bound manifest"
    }
    return $verified
}

function Get-GaIssue5OptionalProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-GaIssue5RunSelector {
    param(
        [Parameter(Mandatory = $true)][object]$Run,
        [Parameter(Mandatory = $true)][string]$Description
    )

    # ``testSelector`` is canonical.  ``selector`` is accepted as a read-only
    # compatibility alias for early manifests, but when both spellings are
    # present they must be identical.  Silently preferring one spelling would
    # allow a manifest and a retained raw record to describe different tests.
    $canonicalProperty = $Run.PSObject.Properties['testSelector']
    $aliasProperty = $Run.PSObject.Properties['selector']
    $hasCanonical = $null -ne $canonicalProperty
    $hasAlias = $null -ne $aliasProperty
    if ($hasCanonical -and $hasAlias) {
        Assert-GaCondition ($canonicalProperty.Value -is [string] -and $aliasProperty.Value -is [string]) "$Description.testSelector and selector must both be strings when both are present"
        Assert-GaCondition ([string]$canonicalProperty.Value -ceq [string]$aliasProperty.Value) "$Description.testSelector and selector aliases must match exactly"
    }
    $selector = if ($hasCanonical) { $canonicalProperty.Value } else { Get-GaIssue5OptionalProperty -Object $Run -Name 'selector' }
    Assert-GaCondition ($selector -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$selector)) "$Description.testSelector must be a non-empty string"
    return [string]$selector
}

function Get-GaIssue5GateMarkers {
    param(
        [Parameter(Mandatory = $true)][object]$GateEvidence,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $canonicalProperty = $GateEvidence.PSObject.Properties['rawLogMarkers']
    $aliasProperty = $GateEvidence.PSObject.Properties['markers']
    # Both spellings are compatibility aliases, but the wire contract is
    # intentionally type-sensitive: a scalar, a numeric entry, or a duplicate
    # marker must never be normalized into an apparently valid string array.
    if ($null -ne $canonicalProperty) {
        Assert-GaCondition ($canonicalProperty.Value -is [System.Array]) "$Description.rawLogMarkers must be a JSON array"
    }
    if ($null -ne $aliasProperty) {
        Assert-GaCondition ($aliasProperty.Value -is [System.Array]) "$Description.markers must be a JSON array"
    }
    $canonicalMarkers = if ($null -ne $canonicalProperty) { @($canonicalProperty.Value) } else { $null }
    $aliasMarkers = if ($null -ne $aliasProperty) { @($aliasProperty.Value) } else { $null }
    if ($null -ne $canonicalProperty -and $null -ne $aliasProperty) {
        Assert-GaCondition ($canonicalMarkers.Count -eq $aliasMarkers.Count) "$Description.rawLogMarkers and markers aliases must have the same length"
        for ($index = 0; $index -lt $canonicalMarkers.Count; $index++) {
            Assert-GaCondition (($canonicalMarkers[$index] -is [string]) -and ($aliasMarkers[$index] -is [string])) "$Description.rawLogMarkers and markers aliases entries must both be strings"
            Assert-GaCondition ($canonicalMarkers[$index] -ceq $aliasMarkers[$index]) "$Description.rawLogMarkers and markers aliases must match exactly"
        }
    }
    # A PowerShell conditional expression unwraps a single-element array when
    # assigned directly. Select the aliases with ordinary assignments and an
    # explicit object-array cast so the type-sensitive contract distinguishes
    # an array from a scalar marker.
    if ($null -ne $canonicalProperty) {
        $markers = [object[]]$canonicalMarkers
    } else {
        $markers = [object[]]$aliasMarkers
    }
    Assert-GaCondition (($null -ne $markers) -and ($markers -is [System.Array]) -and $markers.Count -gt 0) "$Description.rawLogMarkers must be a non-empty array"
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($marker in @($markers)) {
        Assert-GaCondition ($marker -is [string] -and -not [string]::IsNullOrWhiteSpace($marker)) "$Description.rawLogMarkers entries must be non-empty strings"
        Assert-GaCondition ($seen.Add([string]$marker)) "$Description.rawLogMarkers entries must be unique"
    }
    return [string[]]@($markers)
}

function Assert-GaIssue5PositiveSelector {
    param(
        [Parameter(Mandatory = $true)][string]$Platform,
        [Parameter(Mandatory = $true)][string]$Selector,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $normalizedPlatform = $Platform.ToLowerInvariant()
    if ($GaIssue5DisallowedSelectors.Contains($normalizedPlatform)) {
        foreach ($disallowed in @($GaIssue5DisallowedSelectors[$normalizedPlatform])) {
            Assert-GaCondition (-not $Selector.Equals([string]$disallowed, [System.StringComparison]::Ordinal)) "$Description.testSelector '$Selector' is a fail-closed regression selector, not positive native containment evidence"
        }
    }
    Assert-GaCondition ($GaIssue5ExpectedSelectors.Contains($normalizedPlatform)) "$Description.testSelector has no reviewed positive selector for platform '$normalizedPlatform'"
    Assert-GaCondition ($Selector.Equals([string]$GaIssue5ExpectedSelectors[$normalizedPlatform], [System.StringComparison]::Ordinal)) "$Description.testSelector must be the exact positive native '$normalizedPlatform' selector"
}

function Assert-GaIssue5RequiredMarkers {
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
                    $candidate.Equals($prefix, [System.StringComparison]::Ordinal) -or
                    $candidate.StartsWith($prefix, [System.StringComparison]::Ordinal)
                })
            Assert-GaCondition ($matched.Count -gt 0) "$Description.rawLogMarkers must contain a native marker beginning with '$prefix'"
        }
    }
    if ($GaIssue5PlatformGateMarkerPrefixes.Contains($Gate)) {
        $markerPlatforms = if ($Platform -ceq 'multi-platform') { @($GaIssue5Platforms) } else { @($Platform.ToLowerInvariant()) }
        foreach ($markerPlatform in $markerPlatforms) {
            Assert-GaCondition ($GaIssue5PlatformGateMarkerPrefixes[$Gate].Contains($markerPlatform)) "$Description.rawLogMarkers has no reviewed platform marker contract for '$Gate' on '$markerPlatform'"
            foreach ($prefix in @($GaIssue5PlatformGateMarkerPrefixes[$Gate][$markerPlatform])) {
                $matched = @($Markers | Where-Object {
                        $candidate = [string]$_
                        $candidate.Equals($prefix, [System.StringComparison]::Ordinal) -or
                        $candidate.StartsWith($prefix, [System.StringComparison]::Ordinal)
                    })
                Assert-GaCondition ($matched.Count -gt 0) "$Description.rawLogMarkers must contain the '$markerPlatform' native marker beginning with '$prefix'"
            }
        }
    }
    if ($Gate -ceq 'restartResidualProcessReconciliation') {
        $markerPlatforms = if ($Platform -ceq 'multi-platform') { @($GaIssue5Platforms) } else { @($Platform.ToLowerInvariant()) }
        foreach ($markerPlatform in $markerPlatforms) {
            Assert-GaCondition ($GaIssue5ResidualMarkerPrefixes.Contains($markerPlatform)) "$Description.rawLogMarkers has no reviewed residual marker contract for platform '$markerPlatform'"
            $anyMatched = @()
            foreach ($prefix in @($GaIssue5ResidualMarkerPrefixes[$markerPlatform])) {
                $anyMatched += @($Markers | Where-Object {
                        $candidate = [string]$_
                        $candidate.Equals($prefix, [System.StringComparison]::Ordinal) -or
                        $candidate.StartsWith($prefix, [System.StringComparison]::Ordinal)
                    })
            }
            Assert-GaCondition ($anyMatched.Count -gt 0) "$Description.rawLogMarkers must contain a native residual-process reconciliation marker for platform '$markerPlatform'"
        }
    }
}

function Assert-GaIssue5SingleGateEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$Gate,
        [Parameter(Mandatory = $true)][object]$GateEvidence,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $false)][hashtable]$RunPlatformMap = $null
    )

    Assert-GaCondition (($GateEvidence -is [pscustomobject]) -and -not ($GateEvidence -is [System.Array])) "$Description.gates.$Gate must be a structured evidence object, not a bare boolean"
    $provenance = Assert-GaIssue5RunProvenance -Run $GateEvidence -Description "$Description.gates.$Gate"
    $status = Get-GaProperty -Object $GateEvidence -Path 'status' -Description "$Description.gates.$Gate"
    Assert-GaCondition (($status -is [bool]) -and $status) "$Description.gates.$Gate.status must be boolean true"
    $platformValue = Get-GaProperty -Object $GateEvidence -Path 'platform' -Description "$Description.gates.$Gate"
    Assert-GaCondition ($platformValue -is [string]) "$Description.gates.$Gate.platform must be a string"
    $platform = ([string]$platformValue).ToLowerInvariant()
    Assert-GaCondition ($GaIssue5GateExpectedPlatforms[$Gate].Count -eq 1) "$Description.gates.$Gate has an invalid single-platform contract"
    Assert-GaCondition ($platform.Equals([string]$GaIssue5GateExpectedPlatforms[$Gate][0], [System.StringComparison]::Ordinal)) "$Description.gates.$Gate.platform must be '$($GaIssue5GateExpectedPlatforms[$Gate][0])'"
    if ($null -ne $RunPlatformMap) {
        Assert-GaIssue5RunPlatformBinding -RunPlatformMap $RunPlatformMap -RunId $provenance.runId -Platform $platform -Description "$Description.gates.$Gate"
    }
    $selector = Get-GaIssue5RunSelector -Run $GateEvidence -Description "$Description.gates.$Gate"
    Assert-GaIssue5PositiveSelector -Platform $platform -Selector $selector -Description "$Description.gates.$Gate"
    $commandValue = Get-GaProperty -Object $GateEvidence -Path 'command' -Description "$Description.gates.$Gate"
    Assert-GaCondition ($commandValue -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$commandValue)) "$Description.gates.$Gate.command must be a non-empty string"
    $command = [string]$commandValue
    Assert-GaIssue5RunCommand -Platform $platform -Selector $selector -Command $command -Description "$Description.gates.$Gate"
    $markers = @(Get-GaIssue5GateMarkers -GateEvidence $GateEvidence -Description "$Description.gates.$Gate")
    $canonicalMarker = Get-GaIssue5Marker -Platform $platform -Selector $selector -Command $command -Gate $Gate
    Assert-GaCondition (@($markers | Where-Object { $_ -ceq $canonicalMarker }).Count -eq 1) "$Description.gates.$Gate.rawLogMarkers must contain the source-bound platform/selector/command marker"
    Assert-GaIssue5RequiredMarkers -Markers $markers -Gate $Gate -Platform $platform -Description "$Description.gates.$Gate"
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
        command = (Normalize-GaIssue5Command -Command $command)
        markers = $markers
    }
}

function Assert-GaIssue5MatrixGateEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$Gate,
        [Parameter(Mandatory = $true)][object]$GateEvidence,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $false)][hashtable]$RunPlatformMap = $null
    )

    Assert-GaCondition (($GateEvidence -is [pscustomobject]) -and -not ($GateEvidence -is [System.Array])) "$Description.gates.$Gate must be a structured evidence object, not a bare boolean"
    $status = Get-GaProperty -Object $GateEvidence -Path 'status' -Description "$Description.gates.$Gate"
    Assert-GaCondition (($status -is [bool]) -and $status) "$Description.gates.$Gate.status must be boolean true"
    $platformValues = Get-GaProperty -Object $GateEvidence -Path 'platforms' -Description "$Description.gates.$Gate"
    Assert-GaCondition (($platformValues -is [System.Array]) -and $platformValues.Count -eq $GaIssue5Platforms.Count) "$Description.gates.$Gate.platforms must list Linux, Windows, and macOS"
    foreach ($platform in $GaIssue5Platforms) {
        Assert-GaCondition (@($platformValues | Where-Object { ([string]$_).ToLowerInvariant() -ceq $platform }).Count -eq 1) "$Description.gates.$Gate.platforms must contain '$platform' exactly once"
    }
    $runs = Get-GaProperty -Object $GateEvidence -Path 'runs' -Description "$Description.gates.$Gate"
    Assert-GaCondition (($runs -is [System.Array]) -and $runs.Count -eq $GaIssue5Platforms.Count) "$Description.gates.$Gate.runs must contain one run for each platform"
    $seenPlatforms = @{}
    $seenRunIds = @{}
    $allMarkers = New-Object System.Collections.Generic.List[string]
    $runRecords = New-Object System.Collections.Generic.List[object]
    foreach ($run in @($runs)) {
        Assert-GaCondition (($run -is [pscustomobject]) -and -not ($run -is [System.Array])) "$Description.gates.$Gate.runs entries must be JSON objects"
        $provenance = Assert-GaIssue5RunProvenance -Run $run -Description "$Description.gates.$Gate.runs"
        $platformValue = Get-GaProperty -Object $run -Path 'platform' -Description "$Description.gates.$Gate.runs"
        Assert-GaCondition ($platformValue -is [string]) "$Description.gates.$Gate.runs.platform must be a string"
        $platform = ([string]$platformValue).ToLowerInvariant()
        Assert-GaCondition ($GaIssue5Platforms -contains $platform) "$Description.gates.$Gate.runs.platform must be linux, windows, or macos"
        Assert-GaCondition (-not $seenPlatforms.ContainsKey($platform)) "$Description.gates.$Gate.runs.platform entries must be unique"
        $seenPlatforms[$platform] = $true
        Assert-GaCondition (-not $seenRunIds.ContainsKey($provenance.runId)) "$Description.gates.$Gate.runs.runId entries must be unique within the matrix gate"
        $seenRunIds[$provenance.runId] = $true
        if ($null -ne $RunPlatformMap) {
            Assert-GaIssue5RunPlatformBinding -RunPlatformMap $RunPlatformMap -RunId $provenance.runId -Platform $platform -Description "$Description.gates.$Gate.runs.$platform"
        }
        $selector = Get-GaIssue5RunSelector -Run $run -Description "$Description.gates.$Gate.runs.$platform"
        Assert-GaIssue5PositiveSelector -Platform $platform -Selector $selector -Description "$Description.gates.$Gate.runs.$platform"
        $commandValue = Get-GaProperty -Object $run -Path 'command' -Description "$Description.gates.$Gate.runs.$platform"
        Assert-GaCondition ($commandValue -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$commandValue)) "$Description.gates.$Gate.runs.$platform.command must be a non-empty string"
        $command = [string]$commandValue
        Assert-GaIssue5RunCommand -Platform $platform -Selector $selector -Command $command -Description "$Description.gates.$Gate.runs.$platform"
        $markers = @(Get-GaIssue5GateMarkers -GateEvidence $run -Description "$Description.gates.$Gate.runs.$platform")
        $canonicalMarker = Get-GaIssue5Marker -Platform $platform -Selector $selector -Command $command -Gate $Gate
        Assert-GaCondition (@($markers | Where-Object { $_ -ceq $canonicalMarker }).Count -eq 1) "$Description.gates.$Gate.runs.$platform.rawLogMarkers must contain the source-bound marker"
        Assert-GaIssue5RequiredMarkers -Markers $markers -Gate $Gate -Platform $platform -Description "$Description.gates.$Gate.runs.$platform"
        foreach ($marker in $markers) {
            if (-not (@($allMarkers | Where-Object { $_ -ceq $marker }).Count -gt 0)) {
                [void]$allMarkers.Add($marker)
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
                command = (Normalize-GaIssue5Command -Command $command)
                markers = $markers
            })
    }
    Assert-GaCondition ($seenPlatforms.Count -eq $GaIssue5Platforms.Count) "$Description.gates.$Gate.runs must cover all required platforms"
    $gateMarkers = @(Get-GaIssue5GateMarkers -GateEvidence $GateEvidence -Description "$Description.gates.$Gate")
    foreach ($marker in $allMarkers) {
        Assert-GaCondition (@($gateMarkers | Where-Object { $_ -ceq $marker }).Count -eq 1) "$Description.gates.$Gate.rawLogMarkers must retain each platform marker"
    }
    Assert-GaIssue5RequiredMarkers -Markers $gateMarkers -Gate $Gate -Platform 'multi-platform' -Description "$Description.gates.$Gate"
    return [pscustomobject]@{
        gate = $Gate
        status = $true
        platforms = @($GaIssue5Platforms)
        markers = $gateMarkers
        runs = $runRecords.ToArray()
    }
}

function Normalize-GaIssue5Command {
    param([Parameter(Mandatory = $true)][string]$Command)

    return [regex]::Replace($Command.Trim(), '\s+', ' ')
}

function Get-GaIssue5CommandSha256 {
    param([Parameter(Mandatory = $true)][string]$Command)

    $sha = New-Object System.Security.Cryptography.SHA256Managed
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes((Normalize-GaIssue5Command -Command $Command))
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-GaIssue5Marker {
    param(
        [Parameter(Mandatory = $true)][string]$Platform,
        [Parameter(Mandatory = $true)][string]$Selector,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$Gate
    )

    $platformText = $Platform.ToLowerInvariant()
    $commandDigest = Get-GaIssue5CommandSha256 -Command $Command
    return "CYC-GA-ISSUE5|platform=$platformText|selector=$Selector|commandSha256=$commandDigest|gate=$Gate|status=passed"
}

function Assert-GaIssue5RunCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Platform,
        [Parameter(Mandatory = $true)][string]$Selector,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $normalized = Normalize-GaIssue5Command -Command $Command
    $selectorPattern = [regex]::Escape($Selector)
    # Permit an absolute checkout path with or without quotes, but require the
    # cargo package, library target, locked dependency graph, and exact
    # selector.  The Linux native probe is ignored because it is an explicit
    # hostile acceptance test; the Windows/macOS selectors are ordinary exact
    # unit/contract selections.  A workspace-wide command is deliberately not
    # a valid substitute for any matrix row.
    $manifestToken = '(?:"[^"]*Cargo\.toml"|''[^'']*Cargo\.toml''|\S*Cargo\.toml)'
    $tail = if ($Platform -ceq 'linux') {
        '--ignored\s+--exact\s+--nocapture'
    } else {
        '--exact\s+--nocapture'
    }
    $pattern = '^cargo(?:\.exe)?\s+test\s+--manifest-path\s+' + $manifestToken +
        '\s+-p\s+cyc-worker\s+--lib\s+--locked\s+--\s+' + $tail +
        '\s+' + $selectorPattern + '$'
    Assert-GaCondition ($normalized -match $pattern) "$Description.command must be the exact locked cyc-worker test command for platform '$Platform' and selector '$Selector' (observed '$Command')"
    Assert-GaCondition ($normalized -notmatch '(?i)(?:^|\s)--workspace(?:\s|$)') "$Description.command must not be a workspace-wide generic test command"
}

function Assert-GaIssue5Evidence {
    param(
        [Parameter(Mandatory = $true)][object]$Node,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string[]]$RequiredGates
    )

    Assert-GaCondition ($RequiredGates.Count -eq $GaIssue5GateNames.Count) "$Description must use the complete Issue #5 gate set"
    foreach ($gate in $GaIssue5GateNames) {
        Assert-GaCondition ($RequiredGates -contains $gate) "$Description.RequiredGates must include '$gate'"
    }

    $gates = Get-GaProperty -Object $Node -Path 'gates' -Description $Description
    Assert-GaCondition (($gates -is [pscustomobject]) -and -not ($gates -is [System.Array])) "$Description.gates must be a JSON object"
    $gateProperties = @($gates.PSObject.Properties)
    Assert-GaCondition ($gateProperties.Count -eq $GaIssue5GateNames.Count) "$Description.gates must contain exactly the nine Issue #5 gate entries"
    foreach ($gateProperty in $gateProperties) {
        Assert-GaCondition ($GaIssue5GateNames -contains [string]$gateProperty.Name) "$Description.gates contains only the reviewed Issue #5 gate names"
    }
    $gateRecords = New-Object System.Collections.Generic.List[object]
    $runPlatformMap = @{}
    foreach ($gate in $GaIssue5GateNames) {
        $gateEvidence = Get-GaProperty -Object $gates -Path $gate -Description "$Description.gates"
        Assert-GaCondition (($gateEvidence -is [pscustomobject]) -and -not ($gateEvidence -is [System.Array])) "$Description.gates.$gate must be a structured evidence object, not a bare boolean"
        $expectedPlatforms = @($GaIssue5GateExpectedPlatforms[$gate])
        if ($expectedPlatforms.Count -eq 1) {
            [void]$gateRecords.Add((Assert-GaIssue5SingleGateEvidence -Gate $gate -GateEvidence $gateEvidence -Description $Description -RunPlatformMap $runPlatformMap))
        } else {
            [void]$gateRecords.Add((Assert-GaIssue5MatrixGateEvidence -Gate $gate -GateEvidence $gateEvidence -Description $Description -RunPlatformMap $runPlatformMap))
        }
    }

    $rawLog = Get-GaProperty -Object $Node -Path 'rawLog' -Description $Description
    $rawCommand = [string](Get-GaProperty -Object $rawLog -Path 'command' -Description $Description)
    Assert-GaCondition ($rawCommand.Equals($GaIssue5AggregateCommand, [System.StringComparison]::Ordinal)) "$Description.rawLog.command must equal '$GaIssue5AggregateCommand'"
    Assert-GaCondition ($rawCommand -notmatch '(?i)(?:^|\s)--workspace(?:\s|$)') "$Description.rawLog.command must not be a workspace-wide generic test command"

    $rawPlatforms = Get-GaProperty -Object $rawLog -Path 'platforms' -Description $Description
    Assert-GaCondition (($rawPlatforms -is [System.Array]) -and $rawPlatforms.Count -eq $GaIssue5Platforms.Count) "$Description.rawLog.platforms must enumerate Linux, Windows, and macOS exactly once"
    $normalizedRawPlatforms = @($rawPlatforms | ForEach-Object { ([string]$_).ToLowerInvariant() })
    foreach ($platform in $GaIssue5Platforms) {
        Assert-GaCondition (@($normalizedRawPlatforms | Where-Object { $_ -ceq $platform }).Count -eq 1) "$Description.rawLog.platforms must contain '$platform' exactly once"
    }

    $rawMarkers = Get-GaProperty -Object $rawLog -Path 'markers' -Description $Description
    Assert-GaCondition (($rawMarkers -is [System.Array]) -and $rawMarkers.Count -gt 0) "$Description.rawLog.markers must be a non-empty array"
    $seenRawMarkers = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($rawMarker in @($rawMarkers)) {
        Assert-GaCondition ($rawMarker -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$rawMarker)) "$Description.rawLog.markers entries must be non-empty strings"
        $rawMarkerText = [string]$rawMarker
        Assert-GaCondition ($seenRawMarkers.Add($rawMarkerText)) "$Description.rawLog.markers entries must be unique"
    }
    foreach ($gateRecord in $gateRecords.ToArray()) {
        foreach ($marker in @($gateRecord.markers)) {
            Assert-GaCondition (@($rawMarkers | Where-Object { [string]$_ -ceq [string]$marker }).Count -eq 1) "$Description.rawLog.markers must retain the source-bound marker for '$($gateRecord.gate)'"
        }
    }

    $allMarkers = New-Object System.Collections.Generic.List[string]
    $seenAllMarkers = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($gateRecord in $gateRecords.ToArray()) {
        foreach ($marker in @($gateRecord.markers)) {
            if ($seenAllMarkers.Add([string]$marker)) {
                [void]$allMarkers.Add([string]$marker)
            }
        }
    }
    return [pscustomobject]@{
        platforms = @($GaIssue5Platforms)
        markers = $allMarkers.ToArray()
        gates = $gateRecords.ToArray()
    }
}

function Assert-GaIssue5RawVerification {
    param(
        [Parameter(Mandatory = $true)][object]$ManifestIssue,
        [Parameter(Mandatory = $true)][object]$RawRecord,
        [Parameter(Mandatory = $true)][string]$Description
    )

    # Rebuild the expected marker set from the already source-bound manifest;
    # never trust marker names copied back by the downloader on their own.
    $manifestContract = Assert-GaIssue5Evidence -Node $ManifestIssue -Description $Description -RequiredGates $GaIssue5GateNames
    $markersVerified = Get-GaProperty -Object $RawRecord -Path 'markersVerified' -Description $Description
    Assert-GaCondition (($markersVerified -is [bool]) -and $markersVerified) "$Description.markersVerified must be boolean true"

    $verifiedPlatforms = Get-GaProperty -Object $RawRecord -Path 'platforms' -Description $Description
    Assert-GaCondition (($verifiedPlatforms -is [System.Array]) -and $verifiedPlatforms.Count -eq $GaIssue5Platforms.Count) "$Description.platforms must cover the Issue #5 platform matrix"
    foreach ($platform in $GaIssue5Platforms) {
        Assert-GaCondition (@($verifiedPlatforms | Where-Object { ([string]$_).ToLowerInvariant() -ceq $platform }).Count -eq 1) "$Description.platforms must contain '$platform' exactly once"
    }

    $verifiedMarkers = Get-GaProperty -Object $RawRecord -Path 'markers' -Description $Description
    Assert-GaCondition (($verifiedMarkers -is [System.Array]) -and $verifiedMarkers.Count -gt 0) "$Description.markers must be a non-empty array"
    $seenVerifiedMarkers = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($verifiedMarker in @($verifiedMarkers)) {
        Assert-GaCondition ($verifiedMarker -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$verifiedMarker)) "$Description.markers entries must be non-empty strings"
        $verifiedMarkerText = [string]$verifiedMarker
        Assert-GaCondition ($seenVerifiedMarkers.Add($verifiedMarkerText)) "$Description.markers entries must be unique"
    }
    foreach ($marker in @($manifestContract.markers)) {
        Assert-GaCondition (@($verifiedMarkers | Where-Object { [string]$_ -ceq [string]$marker }).Count -eq 1) "$Description.markers must contain the source-bound marker '$marker'"
    }

    $verifiedGates = Get-GaProperty -Object $RawRecord -Path 'gateEvidence' -Description $Description
    Assert-GaCondition (($verifiedGates -is [System.Array]) -and $verifiedGates.Count -eq $GaIssue5GateNames.Count) "$Description.gateEvidence must retain one verified record per Issue #5 gate"
    foreach ($manifestGate in @($manifestContract.gates)) {
        $gateName = [string](Get-GaProperty -Object $manifestGate -Path 'gate' -Description $Description)
        $gateMatches = @($verifiedGates | Where-Object { [string](Get-GaProperty -Object $_ -Path 'gate' -Description $Description) -ceq $gateName })
        Assert-GaCondition ($gateMatches.Count -eq 1) "$Description.gateEvidence must retain exactly one '$gateName' record"
        $verifiedGate = $gateMatches[0]
        $verifiedGateStatus = Get-GaProperty -Object $verifiedGate -Path 'status' -Description $Description
        Assert-GaCondition (($verifiedGateStatus -is [bool]) -and $verifiedGateStatus) "$Description.gateEvidence.$gateName.status must be boolean true"
        $verifiedMarkersForGate = @(Get-GaProperty -Object $verifiedGate -Path 'markers' -Description $Description)
        Assert-GaCondition (($verifiedMarkersForGate -is [System.Array]) -and $verifiedMarkersForGate.Count -gt 0) "$Description.gateEvidence.$gateName.markers must be retained"
        $seenVerifiedGateMarkers = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($verifiedGateMarker in @($verifiedMarkersForGate)) {
            Assert-GaCondition ($verifiedGateMarker -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$verifiedGateMarker)) "$Description.gateEvidence.$gateName.markers entries must be non-empty strings"
            $verifiedGateMarkerText = [string]$verifiedGateMarker
            Assert-GaCondition ($seenVerifiedGateMarkers.Add($verifiedGateMarkerText)) "$Description.gateEvidence.$gateName.markers entries must be unique"
        }
        foreach ($marker in @($manifestGate.markers)) {
            Assert-GaCondition (@($verifiedMarkersForGate | Where-Object { [string]$_ -ceq [string]$marker }).Count -eq 1) "$Description.gateEvidence.$gateName.markers must match the manifest"
        }
        $manifestRunsProperty = $manifestGate.PSObject.Properties['runs']
        if ($null -ne $manifestRunsProperty) {
            $manifestPlatforms = Get-GaProperty -Object $manifestGate -Path 'platforms' -Description $Description
            $verifiedPlatformsForGate = Get-GaProperty -Object $verifiedGate -Path 'platforms' -Description $Description
            Assert-GaCondition (($verifiedPlatformsForGate -is [System.Array]) -and $verifiedPlatformsForGate.Count -eq $manifestPlatforms.Count) "$Description.gateEvidence.$gateName.platforms must match the manifest"
            foreach ($platform in @($manifestPlatforms)) {
                Assert-GaCondition (@($verifiedPlatformsForGate | Where-Object { ([string]$_).ToLowerInvariant() -ceq ([string]$platform).ToLowerInvariant() }).Count -eq 1) "$Description.gateEvidence.$gateName.platforms must retain '$platform'"
            }
            $verifiedRuns = Get-GaProperty -Object $verifiedGate -Path 'runs' -Description $Description
            Assert-GaCondition (($verifiedRuns -is [System.Array]) -and $verifiedRuns.Count -eq $GaIssue5Platforms.Count) "$Description.gateEvidence.$gateName.runs must retain one run per platform"
            foreach ($manifestRun in @($manifestRunsProperty.Value)) {
                $manifestPlatform = ([string](Get-GaProperty -Object $manifestRun -Path 'platform' -Description $Description)).ToLowerInvariant()
                $runMatches = @($verifiedRuns | Where-Object { ([string](Get-GaProperty -Object $_ -Path 'platform' -Description $Description)).ToLowerInvariant() -ceq $manifestPlatform })
                Assert-GaCondition ($runMatches.Count -eq 1) "$Description.gateEvidence.$gateName.runs must retain exactly one '$manifestPlatform' run"
                $verifiedRun = $runMatches[0]
                [void](Assert-GaIssue5RunProvenanceMatch -ManifestRun $manifestRun -VerifiedRun $verifiedRun -Description "$Description.gateEvidence.$gateName.runs.$manifestPlatform")
                $manifestSelector = Get-GaIssue5RunSelector -Run $manifestRun -Description $Description
                $verifiedSelector = Get-GaIssue5RunSelector -Run $verifiedRun -Description $Description
                Assert-GaCondition ($verifiedSelector.Equals($manifestSelector, [System.StringComparison]::Ordinal)) "$Description.gateEvidence.$gateName.runs.$manifestPlatform.testSelector must match the manifest"
                $manifestCommand = Normalize-GaIssue5Command -Command ([string](Get-GaProperty -Object $manifestRun -Path 'command' -Description $Description))
                $verifiedCommand = Normalize-GaIssue5Command -Command ([string](Get-GaProperty -Object $verifiedRun -Path 'command' -Description $Description))
                Assert-GaCondition ($verifiedCommand.Equals($manifestCommand, [System.StringComparison]::Ordinal)) "$Description.gateEvidence.$gateName.runs.$manifestPlatform.command must match the manifest"
                $verifiedRunMarkers = @(Get-GaProperty -Object $verifiedRun -Path 'markers' -Description $Description)
                Assert-GaCondition (($verifiedRunMarkers -is [System.Array]) -and $verifiedRunMarkers.Count -gt 0) "$Description.gateEvidence.$gateName.runs.$manifestPlatform.markers must be retained"
                foreach ($marker in @($manifestRun.markers)) {
                    Assert-GaCondition (@($verifiedRunMarkers | Where-Object { [string]$_ -ceq [string]$marker }).Count -eq 1) "$Description.gateEvidence.$gateName.runs.$manifestPlatform.markers must match the manifest"
                }
            }
        } else {
            [void](Assert-GaIssue5RunProvenanceMatch -ManifestRun $manifestGate -VerifiedRun $verifiedGate -Description "$Description.gateEvidence.$gateName")
            $manifestPlatform = ([string](Get-GaProperty -Object $manifestGate -Path 'platform' -Description $Description)).ToLowerInvariant()
            $verifiedPlatform = ([string](Get-GaProperty -Object $verifiedGate -Path 'platform' -Description $Description)).ToLowerInvariant()
            Assert-GaCondition ($verifiedPlatform.Equals($manifestPlatform, [System.StringComparison]::Ordinal)) "$Description.gateEvidence.$gateName.platform must match the manifest"
            $manifestSelector = Get-GaIssue5RunSelector -Run $manifestGate -Description $Description
            $verifiedSelector = Get-GaIssue5RunSelector -Run $verifiedGate -Description $Description
            Assert-GaCondition ($verifiedSelector.Equals($manifestSelector, [System.StringComparison]::Ordinal)) "$Description.gateEvidence.$gateName.testSelector must match the manifest"
            $manifestCommand = Normalize-GaIssue5Command -Command ([string](Get-GaProperty -Object $manifestGate -Path 'command' -Description $Description))
            $verifiedCommand = Normalize-GaIssue5Command -Command ([string](Get-GaProperty -Object $verifiedGate -Path 'command' -Description $Description))
            Assert-GaCondition ($verifiedCommand.Equals($manifestCommand, [System.StringComparison]::Ordinal)) "$Description.gateEvidence.$gateName.command must match the manifest"
        }
    }
}

function Assert-GaIssue23RawVerification {
    param(
        [Parameter(Mandatory = $true)][object]$ManifestIssue,
        [Parameter(Mandatory = $true)][object]$RawRecord,
        [Parameter(Mandatory = $true)][string]$IssueName,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [Parameter(Mandatory = $true)][string]$Description
    )

    # Rebuild the expected per-gate contract from the already validated
    # manifest. The downloader's summary is accepted only when it retains the
    # same gate identity, provenance, command, and marker set.
    $manifestContract = Assert-GaIssue23Evidence `
        -Node $ManifestIssue `
        -IssueName $IssueName `
        -ExpectedCommit $ExpectedCommit `
        -Description $Description

    $markersVerified = Get-GaProperty -Object $RawRecord -Path 'markersVerified' -Description $Description
    Assert-GaCondition (($markersVerified -is [bool]) -and $markersVerified) "$Description.markersVerified must be boolean true"

    $verifiedMarkers = Get-GaProperty -Object $RawRecord -Path 'markers' -Description $Description
    Assert-GaCondition (($verifiedMarkers -is [System.Array]) -and $verifiedMarkers.Count -gt 0) "$Description.markers must be a non-empty array"
    $seenVerifiedMarkers = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($marker in @($verifiedMarkers)) {
        Assert-GaCondition ($marker -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$marker)) "$Description.markers entries must be non-empty strings"
        Assert-GaCondition ($seenVerifiedMarkers.Add([string]$marker)) "$Description.markers entries must be unique"
    }
    foreach ($marker in @($manifestContract.markers)) {
        Assert-GaCondition (@($verifiedMarkers | Where-Object { [string]$_ -ceq [string]$marker }).Count -eq 1) "$Description.markers must retain the source-bound marker '$marker'"
    }

    $verifiedGates = Get-GaProperty -Object $RawRecord -Path 'gateEvidence' -Description $Description
    $expectedGateCount = @($GaIssue23GateNames[$IssueName]).Count
    Assert-GaCondition (($verifiedGates -is [System.Array]) -and $verifiedGates.Count -eq $expectedGateCount) "$Description.gateEvidence must retain one verified record per $IssueName gate"
    foreach ($manifestGate in @($manifestContract.gates)) {
        $gateName = [string](Get-GaProperty -Object $manifestGate -Path 'gate' -Description $Description)
        $gateMatches = @($verifiedGates | Where-Object {
                $gateProperty = $_.PSObject.Properties['gate']
                $null -ne $gateProperty -and [string]$gateProperty.Value -ceq $gateName
            })
        Assert-GaCondition ($gateMatches.Count -eq 1) "$Description.gateEvidence must retain exactly one '$gateName' record"
        $verifiedGate = $gateMatches[0]
        # Validate the retained record as a complete gate object, not just a
        # status bit. This also verifies the command-bound marker digest.
        $verifiedGateContract = Assert-GaIssue23GateEvidence `
            -ManifestIssue $ManifestIssue `
            -IssueName $IssueName `
            -Gate $gateName `
            -GateEvidence $verifiedGate `
            -ExpectedCommit $ExpectedCommit `
            -Description "$Description.gateEvidence.$gateName"
        foreach ($field in @('gateId', 'sourceCommit', 'provider', 'hostType', 'evidenceId', 'runId', 'node', 'testSelector')) {
            Assert-GaCondition ([string]$verifiedGateContract.$field -ceq [string]$manifestGate.$field) "$Description.gateEvidence.$gateName.$field must match the manifest"
        }
        Assert-GaCondition ((Normalize-GaRawLogCommand -Command ([string]$verifiedGateContract.command)).Equals(
                (Normalize-GaRawLogCommand -Command ([string]$manifestGate.command)), [StringComparison]::Ordinal)) "$Description.gateEvidence.$gateName.command must match the manifest"
        if ($IssueName -ceq 'issue3') {
            # The raw summary is an independently materialized object. Rebind
            # every Issue #3 v2 semantic field to the source-bound manifest so
            # a self-consistent but semantically different marker cannot pass.
            foreach ($field in @('platform', 'hostArchitecture', 'architecture', 'target', 'rustTarget', 'kitTarget', 'operation', 'commandId', 'selectorId')) {
                Assert-GaCondition ([string]$verifiedGateContract.$field -ceq [string]$manifestGate.$field) "$Description.gateEvidence.$gateName.$field must match the manifest"
            }
            $manifestCoverage = @($manifestGate.coverageTargets | ForEach-Object { [string]$_ })
            $verifiedCoverage = @($verifiedGateContract.coverageTargets | ForEach-Object { [string]$_ })
            Assert-GaCondition (($verifiedCoverage -join ',') -ceq ($manifestCoverage -join ',')) "$Description.gateEvidence.$gateName.coverageTargets must match the manifest"
            $manifestPlatforms = @($manifestGate.platforms | ForEach-Object { [string]$_ })
            $verifiedPlatforms = @($verifiedGateContract.platforms | ForEach-Object { [string]$_ })
            Assert-GaCondition (($verifiedPlatforms -join ',') -ceq ($manifestPlatforms -join ',')) "$Description.gateEvidence.$gateName.platforms must match the manifest"
        }
        foreach ($marker in @($manifestGate.markers)) {
            Assert-GaCondition (@($verifiedGateContract.markers | Where-Object { [string]$_ -ceq [string]$marker }).Count -eq 1) "$Description.gateEvidence.$gateName.markers must retain the manifest marker '$marker'"
        }
        Assert-GaCondition ((@($verifiedGateContract.markers | Sort-Object) -join "`n") -ceq (@($manifestGate.markers | Sort-Object) -join "`n")) "$Description.gateEvidence.$gateName.markers must match the manifest marker set exactly"
        if ($IssueName -ceq 'issue2' -and $gateName -ceq 'noOpenUnwaivedP0P1Blocker') {
            $manifestInventory = Get-GaProperty -Object $manifestGate -Path 'blockerInventory' -Description $Description
            $verifiedInventory = Get-GaProperty -Object $verifiedGateContract -Path 'blockerInventory' -Description $Description
            $manifestInventoryBinding = Get-GaBlockerInventoryBinding -Inventory $manifestInventory -Description "$Description.gateEvidence.$gateName.manifest.blockerInventory"
            $verifiedInventoryBinding = Get-GaBlockerInventoryBinding -Inventory $verifiedInventory -Description "$Description.gateEvidence.$gateName.verified.blockerInventory"
            Assert-GaCondition ($verifiedInventoryBinding -ceq $manifestInventoryBinding) "$Description.gateEvidence.$gateName.blockerInventory must match the manifest"
        }
        [void](Assert-GaIssue5RunProvenanceMatch -ManifestRun $manifestGate -VerifiedRun $verifiedGate -Description "$Description.gateEvidence.$gateName")
    }
    return $RawRecord
}

function Assert-GaExactGateSet {
    param(
        [Parameter(Mandatory = $true)][object]$Gates,
        [Parameter(Mandatory = $true)][string[]]$RequiredGates,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-GaCondition (($Gates -is [pscustomobject]) -and -not ($Gates -is [System.Array])) "$Description.gates must be a JSON object"
    $expected = @($RequiredGates | ForEach-Object { [string]$_ })
    Assert-GaCondition ($expected.Count -gt 0) "$Description must declare at least one required gate"
    $uniqueExpected = @()
    foreach ($gate in $expected) {
        Assert-GaCondition (-not [string]::IsNullOrWhiteSpace($gate)) "$Description.RequiredGates cannot contain a blank gate name"
        if (@($uniqueExpected | Where-Object { $_ -ceq $gate }).Count -eq 0) {
            $uniqueExpected += $gate
        }
    }
    Assert-GaCondition ($uniqueExpected.Count -eq $expected.Count) "$Description.RequiredGates must not contain duplicate gate names"

    $actual = @($Gates.PSObject.Properties | ForEach-Object { [string]$_.Name })
    Assert-GaCondition ($actual.Count -eq $expected.Count) "$Description.gates must contain exactly the reviewed gate keys"
    foreach ($key in $actual) {
        Assert-GaCondition (@($expected | Where-Object { $_ -ceq $key }).Count -eq 1) "$Description.gates contains unknown gate key '$key'"
    }
    foreach ($gate in $expected) {
        Assert-GaCondition (@($actual | Where-Object { $_ -ceq $gate }).Count -eq 1) "$Description.gates is missing required gate '$gate'"
    }
}

function Assert-GaExactObjectPropertySet {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string[]]$Required,
        [Parameter(Mandatory = $false)][string[]]$Optional = @(),
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-GaCondition (($Object -is [pscustomobject]) -and -not ($Object -is [System.Array])) "$Description must be a JSON object"
    $allowed = @($Required + $Optional | Select-Object -Unique)
    foreach ($requiredName in $Required) {
        Assert-GaCondition ($null -ne $Object.PSObject.Properties[$requiredName]) "$Description is missing required property '$requiredName'"
    }
    foreach ($property in @($Object.PSObject.Properties)) {
        Assert-GaCondition (@($allowed | Where-Object { $_ -ceq [string]$property.Name }).Count -eq 1) "$Description contains unknown property '$($property.Name)'"
    }
}

function Get-GaBlockerPriorityLabels {
    param(
        [Parameter(Mandatory = $true)][object]$Labels,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-GaCondition ($Labels -is [System.Array]) "$Description.labels must be a JSON array"
    $seenNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $priorities = New-Object 'System.Collections.Generic.List[string]'
    foreach ($label in @($Labels)) {
        Assert-GaCondition (($label -is [pscustomobject]) -and -not ($label -is [System.Array])) "$Description.labels entries must be JSON objects"
        $nameProperty = $label.PSObject.Properties['name']
        Assert-GaCondition ($null -ne $nameProperty) "$Description.labels entries must contain name"
        Assert-GaCondition ($nameProperty.Value -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$nameProperty.Value)) "$Description.labels.name must be a non-empty string"
        $name = ([string]$nameProperty.Value).Trim()
        Assert-GaCondition ($seenNames.Add($name)) "$Description.labels must not contain duplicate label names"

        $match = [regex]::Match($name, $GaBlockerPriorityLabelPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            $priority = 'P' + $match.Groups[1].Value
            Assert-GaCondition (-not (@($priorities | Where-Object { $_ -ceq $priority }).Count -gt 0)) "$Description.labels must not declare the same P0/P1 priority more than once"
            [void]$priorities.Add($priority)
        }
    }
    return $priorities.ToArray()
}

function Assert-GaBlockerReviewer {
    param(
        [Parameter(Mandatory = $true)][object]$Reviewer,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-GaExactObjectPropertySet -Object $Reviewer -Required @('id', 'login') -Description $Description
    $id = Get-GaProperty -Object $Reviewer -Path 'id' -Description $Description
    Assert-GaCondition ((Test-GaInteger -Value $id) -and [decimal]$id -gt 0) "$Description.id must be a positive integer"
    $login = Get-GaProperty -Object $Reviewer -Path 'login' -Description $Description
    Assert-GaCondition ($login -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$login)) "$Description.login must be a non-empty string"
    Assert-GaCondition ([string]$login -notmatch '[\r\n]') "$Description.login must not contain newlines"
    return [pscustomobject]@{
        id = [long]$id
        login = [string]$login
    }
}

function Assert-GaBlockerInventory {
    param(
        [Parameter(Mandatory = $true)][object]$Inventory,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-GaExactObjectPropertySet -Object $Inventory `
        -Required @('schemaVersion', 'status', 'sourceCommit', 'evidenceId', 'repository', 'reviewer', 'reviewedAt', 'expiresAt', 'api', 'issues', 'waivers') `
        -Description $Description
    [void](Assert-GaString -Object $Inventory -Path 'schemaVersion' -Expected $GaBlockerInventorySchema -Description $Description)
    [void](Assert-GaString -Object $Inventory -Path 'status' -Expected 'passed' -Description $Description)

    $sourceCommit = Get-GaProperty -Object $Inventory -Path 'sourceCommit' -Description $Description
    Assert-GaCondition ($sourceCommit -is [string] -and [string]$sourceCommit -match '^[0-9a-fA-F]{40}$') "$Description.sourceCommit must be a full 40-character commit SHA"
    Assert-GaCondition ([string]$sourceCommit -ieq $ExpectedCommit) "$Description.sourceCommit must match the reviewed stable source commit"
    [void](Assert-GaString -Object $Inventory -Path 'repository' -Expected $GaBlockerRepository -Description $Description)

    $evidenceId = Get-GaProperty -Object $Inventory -Path 'evidenceId' -Description $Description
    Assert-GaCondition ($evidenceId -is [string] -and [string]$evidenceId -match $GaBlockerEvidenceIdPattern) "$Description.evidenceId must be a bounded portable retained-inventory identifier"

    $reviewer = Assert-GaBlockerReviewer -Reviewer (Get-GaProperty -Object $Inventory -Path 'reviewer' -Description $Description) -Description "$Description.reviewer"
    $reviewedAt = Convert-GaRawLogInstant -Value (Get-GaProperty -Object $Inventory -Path 'reviewedAt' -Description $Description) -Description "$Description.reviewedAt"
    $expiresAt = Convert-GaRawLogInstant -Value (Get-GaProperty -Object $Inventory -Path 'expiresAt' -Description $Description) -Description "$Description.expiresAt"
    $now = [DateTimeOffset]::UtcNow
    Assert-GaCondition ($reviewedAt -le $now) "$Description.reviewedAt must not be in the future"
    Assert-GaCondition ($expiresAt -gt $now) "$Description.expiresAt must be in the future"
    Assert-GaCondition ($expiresAt -gt $reviewedAt) "$Description.expiresAt must be later than reviewedAt"

    $api = Get-GaProperty -Object $Inventory -Path 'api' -Description $Description
    Assert-GaExactObjectPropertySet -Object $api `
        -Required @('provider', 'endpoint', 'requestedState', 'complete', 'incomplete', 'hasNextPage', 'pageCount', 'totalCount', 'returnedCount', 'capturedAt', 'sourceCommit', 'error') `
        -Description "$Description.api"
    [void](Assert-GaString -Object $api -Path 'provider' -Expected 'github-rest-api' -Description "$Description.api")
    [void](Assert-GaString -Object $api -Path 'requestedState' -Expected 'open' -Description "$Description.api")
    $endpointValue = Get-GaProperty -Object $api -Path 'endpoint' -Description "$Description.api"
    Assert-GaCondition ($endpointValue -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$endpointValue)) "$Description.api.endpoint must be a non-empty string"
    $endpointUri = $null
    Assert-GaCondition ([Uri]::TryCreate([string]$endpointValue, [UriKind]::Absolute, [ref]$endpointUri)) "$Description.api.endpoint must be an absolute URL"
    Assert-GaCondition ($endpointUri.Scheme.Equals('https', [StringComparison]::OrdinalIgnoreCase)) "$Description.api.endpoint must use HTTPS"
    Assert-GaCondition ($endpointUri.Host.Equals('api.github.com', [StringComparison]::OrdinalIgnoreCase)) "$Description.api.endpoint must use api.github.com"
    Assert-GaCondition ([string]::IsNullOrWhiteSpace($endpointUri.UserInfo) -and [string]::IsNullOrWhiteSpace($endpointUri.Query) -and [string]::IsNullOrWhiteSpace($endpointUri.Fragment)) "$Description.api.endpoint must not contain credentials, query parameters, or fragments"
    Assert-GaCondition ($endpointUri.AbsolutePath.TrimEnd('/') -ceq '/repos/TypeThe0ry/ClusterYourCodex/issues') "$Description.api.endpoint must target the canonical repository issues endpoint"

    foreach ($booleanField in @('complete', 'incomplete', 'hasNextPage')) {
        $booleanValue = Get-GaProperty -Object $api -Path $booleanField -Description "$Description.api"
        Assert-GaCondition ($booleanValue -is [bool]) "$Description.api.$booleanField must be boolean"
    }
    Assert-GaCondition ([bool]$api.complete) "$Description.api.complete must be true"
    Assert-GaCondition (-not [bool]$api.incomplete) "$Description.api.incomplete must be false"
    Assert-GaCondition (-not [bool]$api.hasNextPage) "$Description.api.hasNextPage must be false"
    [void](Assert-GaRawLogCount -Value (Get-GaProperty -Object $api -Path 'pageCount' -Description "$Description.api") -Description "$Description.api.pageCount" -RequirePositive $true)
    $totalCount = Assert-GaRawLogCount -Value (Get-GaProperty -Object $api -Path 'totalCount' -Description "$Description.api") -Description "$Description.api.totalCount"
    $returnedCount = Assert-GaRawLogCount -Value (Get-GaProperty -Object $api -Path 'returnedCount' -Description "$Description.api") -Description "$Description.api.returnedCount"
    $capturedAt = Convert-GaRawLogInstant -Value (Get-GaProperty -Object $api -Path 'capturedAt' -Description "$Description.api") -Description "$Description.api.capturedAt"
    Assert-GaCondition ($capturedAt -le $now) "$Description.api.capturedAt must not be in the future"
    $apiCommit = Get-GaProperty -Object $api -Path 'sourceCommit' -Description "$Description.api"
    Assert-GaCondition ($apiCommit -is [string] -and [string]$apiCommit -match '^[0-9a-fA-F]{40}$') "$Description.api.sourceCommit must be a full 40-character commit SHA"
    Assert-GaCondition ([string]$apiCommit -ieq $ExpectedCommit) "$Description.api.sourceCommit must match the reviewed stable source commit"
    $apiError = Get-GaProperty -Object $api -Path 'error' -Description "$Description.api"
    Assert-GaCondition ($null -eq $apiError -or ($apiError -is [string] -and [string]::IsNullOrWhiteSpace([string]$apiError))) "$Description.api.error must be null or an empty string"

    # Read array-valued properties through PSObject.Properties.Value.  A
    # command-substitution call to Get-GaProperty enumerates a one-item array
    # in Windows PowerShell, which would turn a valid one-issue snapshot into
    # a scalar before the type check below.
    $issues = $Inventory.PSObject.Properties['issues'].Value
    Assert-GaCondition ($issues -is [System.Array]) "$Description.issues must be a JSON array containing the complete open-issue snapshot"
    Assert-GaCondition ([long]$returnedCount -eq [long]$issues.Count) "$Description.api.returnedCount must equal the issue snapshot length"
    Assert-GaCondition ([long]$totalCount -eq [long]$issues.Count) "$Description.api.totalCount must equal the issue snapshot length"

    $seenIssueNumbers = New-Object 'System.Collections.Generic.HashSet[long]'
    $blockers = New-Object System.Collections.Generic.List[object]
    foreach ($issue in @($issues)) {
        Assert-GaExactObjectPropertySet -Object $issue -Required @('number', 'state', 'title', 'html_url', 'labels') -Description "$Description.issues entry"
        $number = Get-GaProperty -Object $issue -Path 'number' -Description "$Description.issues entry"
        Assert-GaCondition ((Test-GaInteger -Value $number) -and [decimal]$number -gt 0) "$Description.issues.number must be a positive integer"
        Assert-GaCondition ($seenIssueNumbers.Add([long]$number)) "$Description.issues must not contain duplicate issue numbers"
        [void](Assert-GaString -Object $issue -Path 'state' -Expected 'open' -Description "$Description.issues #$number")
        $title = Get-GaProperty -Object $issue -Path 'title' -Description "$Description.issues #$number"
        Assert-GaCondition ($title -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$title)) "$Description.issues #$number.title must be a non-empty string"
        $htmlUrl = Get-GaProperty -Object $issue -Path 'html_url' -Description "$Description.issues #$number"
        $expectedIssueUrl = "https://github.com/$GaBlockerRepository/issues/$number"
        Assert-GaCondition ($htmlUrl -is [string] -and [string]$htmlUrl -ceq $expectedIssueUrl) "$Description.issues #$number.html_url must be the canonical issue URL"
        $labelArray = $issue.PSObject.Properties['labels'].Value
        $priorityLabels = @(Get-GaBlockerPriorityLabels -Labels $labelArray -Description "$Description.issues #$number")
        Assert-GaCondition ($priorityLabels.Count -le 1) "$Description.issues #$number must not carry multiple P0/P1 priority labels"
        if ($priorityLabels.Count -eq 1) {
            [void]$blockers.Add([pscustomobject]@{
                    number = [long]$number
                    priority = [string]$priorityLabels[0]
                })
        }
    }

    $waivers = $Inventory.PSObject.Properties['waivers'].Value
    Assert-GaCondition ($waivers -is [System.Array]) "$Description.waivers must be a JSON array"
    $seenWaiverNumbers = New-Object 'System.Collections.Generic.HashSet[long]'
    $blockerNumberSet = New-Object 'System.Collections.Generic.HashSet[long]'
    foreach ($blocker in $blockers.ToArray()) { [void]$blockerNumberSet.Add([long]$blocker.number) }
    foreach ($waiver in @($waivers)) {
        Assert-GaExactObjectPropertySet -Object $waiver -Required @('issueNumber', 'scope', 'sourceCommit', 'expiresAt', 'reviewer', 'status', 'reason') -Description "$Description.waivers entry"
        $waiverNumber = Get-GaProperty -Object $waiver -Path 'issueNumber' -Description "$Description.waivers entry"
        Assert-GaCondition ((Test-GaInteger -Value $waiverNumber) -and [decimal]$waiverNumber -gt 0) "$Description.waivers.issueNumber must be a positive integer"
        Assert-GaCondition ($seenWaiverNumbers.Add([long]$waiverNumber)) "$Description.waivers must contain at most one active waiver per issue"
        Assert-GaCondition ($blockerNumberSet.Contains([long]$waiverNumber)) "$Description.waivers may only reference an open P0/P1 issue in the snapshot"
        $scope = Get-GaProperty -Object $waiver -Path 'scope' -Description "$Description.waivers #$waiverNumber"
        Assert-GaExactObjectPropertySet -Object $scope -Required @('repository', 'channel', 'issueNumber') -Description "$Description.waivers #$waiverNumber.scope"
        [void](Assert-GaString -Object $scope -Path 'repository' -Expected $GaBlockerRepository -Description "$Description.waivers #$waiverNumber.scope")
        [void](Assert-GaString -Object $scope -Path 'channel' -Expected 'stable' -Description "$Description.waivers #$waiverNumber.scope")
        $scopeNumber = Get-GaProperty -Object $scope -Path 'issueNumber' -Description "$Description.waivers #$waiverNumber.scope"
        Assert-GaCondition ((Test-GaInteger -Value $scopeNumber) -and [long]$scopeNumber -eq [long]$waiverNumber) "$Description.waivers #$waiverNumber.scope.issueNumber must match the waiver issueNumber"
        $waiverCommit = Get-GaProperty -Object $waiver -Path 'sourceCommit' -Description "$Description.waivers #$waiverNumber"
        Assert-GaCondition ($waiverCommit -is [string] -and [string]$waiverCommit -match '^[0-9a-fA-F]{40}$') "$Description.waivers #$waiverNumber.sourceCommit must be a full 40-character commit SHA"
        Assert-GaCondition ([string]$waiverCommit -ieq $ExpectedCommit) "$Description.waivers #$waiverNumber.sourceCommit must match the reviewed stable source commit"
        $waiverExpiresAt = Convert-GaRawLogInstant -Value (Get-GaProperty -Object $waiver -Path 'expiresAt' -Description "$Description.waivers #$waiverNumber") -Description "$Description.waivers #$waiverNumber.expiresAt"
        Assert-GaCondition ($waiverExpiresAt -gt $now) "$Description.waivers #$waiverNumber.expiresAt must be in the future"
        Assert-GaCondition ($waiverExpiresAt -le $expiresAt) "$Description.waivers #$waiverNumber.expiresAt must not outlive the inventory expiry"
        $waiverReviewer = Assert-GaBlockerReviewer -Reviewer (Get-GaProperty -Object $waiver -Path 'reviewer' -Description "$Description.waivers #$waiverNumber") -Description "$Description.waivers #$waiverNumber.reviewer"
        Assert-GaCondition ($waiverReviewer.id -eq $reviewer.id -and $waiverReviewer.login -ceq $reviewer.login) "$Description.waivers #$waiverNumber.reviewer must match the inventory reviewer"
        [void](Assert-GaString -Object $waiver -Path 'status' -Expected 'active' -Description "$Description.waivers #$waiverNumber")
        $reason = Get-GaProperty -Object $waiver -Path 'reason' -Description "$Description.waivers #$waiverNumber"
        Assert-GaCondition ($reason -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$reason)) "$Description.waivers #$waiverNumber.reason must be non-empty"
    }
    foreach ($blocker in $blockers.ToArray()) {
        $matches = @($waivers | Where-Object { [long]$_.issueNumber -eq [long]$blocker.number })
        Assert-GaCondition ($matches.Count -eq 1) "$Description must contain one valid active waiver for open $($blocker.priority) issue #$($blocker.number)"
    }
    Assert-GaCondition ($seenWaiverNumbers.Count -eq $blockers.Count) "$Description.waivers must cover exactly the P0/P1 blockers in the complete open-issue snapshot"

    return [pscustomobject]@{
        schemaVersion = $GaBlockerInventorySchema
        sourceCommit = [string]$sourceCommit
        evidenceId = [string]$evidenceId
        issueCount = [int64]@($issues).Count
        blockerCount = [int64]$blockers.Count
        waiverCount = [int64]$waivers.Count
        reviewer = $reviewer
        expiresAt = $expiresAt
    }
}

function Get-GaIssueSetBinding {
    param(
        [Parameter(Mandatory = $true)][object]$Issues,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-GaCondition ($Issues -is [System.Array]) "$Description must be a JSON array"
    $bindings = New-Object System.Collections.Generic.List[object]
    foreach ($issue in @($Issues | Sort-Object {
                [long](Get-GaProperty -Object $_ -Path 'number' -Description $Description)
            })) {
        $labels = Get-GaProperty -Object $issue -Path 'labels' -Description $Description
        $labelBindings = New-Object System.Collections.Generic.List[string]
        foreach ($label in @($labels | Sort-Object {
                    [string](Get-GaProperty -Object $_ -Path 'name' -Description $Description)
                })) {
            [void]$labelBindings.Add([string](Get-GaProperty -Object $label -Path 'name' -Description $Description))
        }
        [void]$bindings.Add([ordered]@{
                number = [long](Get-GaProperty -Object $issue -Path 'number' -Description $Description)
                state = [string](Get-GaProperty -Object $issue -Path 'state' -Description $Description)
                title = [string](Get-GaProperty -Object $issue -Path 'title' -Description $Description)
                html_url = [string](Get-GaProperty -Object $issue -Path 'html_url' -Description $Description)
                labels = $labelBindings.ToArray()
            })
    }
    return (($bindings.ToArray()) | ConvertTo-Json -Depth 20 -Compress)
}

function Assert-GaOpenIssueSnapshot {
    param(
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-GaExactObjectPropertySet -Object $Snapshot `
        -Required @('schemaVersion', 'sourceCommit', 'capturedAt', 'api', 'issues') `
        -Description $Description
    [void](Assert-GaString -Object $Snapshot -Path 'schemaVersion' -Expected $GaOpenIssueSnapshotSchema -Description $Description)
    $sourceCommit = Get-GaProperty -Object $Snapshot -Path 'sourceCommit' -Description $Description
    Assert-GaCondition ($sourceCommit -is [string] -and [string]$sourceCommit -match '^[0-9a-fA-F]{40}$') "$Description.sourceCommit must be a full 40-character commit SHA"
    Assert-GaCondition ([string]$sourceCommit -ieq $ExpectedCommit) "$Description.sourceCommit must match the reviewed stable source commit"
    $capturedAt = Convert-GaRawLogInstant -Value (Get-GaProperty -Object $Snapshot -Path 'capturedAt' -Description $Description) -Description "$Description.capturedAt"
    $now = [DateTimeOffset]::UtcNow
    Assert-GaCondition ($capturedAt -le $now) "$Description.capturedAt must not be in the future"

    $api = Get-GaProperty -Object $Snapshot -Path 'api' -Description $Description
    Assert-GaExactObjectPropertySet -Object $api `
        -Required @('provider', 'endpoint', 'requestedState', 'complete', 'incomplete', 'hasNextPage', 'pageCount', 'totalCount', 'returnedCount', 'capturedAt', 'sourceCommit', 'error') `
        -Description "$Description.api"
    [void](Assert-GaString -Object $api -Path 'provider' -Expected 'github-rest-api' -Description "$Description.api")
    [void](Assert-GaString -Object $api -Path 'requestedState' -Expected 'open' -Description "$Description.api")
    $endpointValue = Get-GaProperty -Object $api -Path 'endpoint' -Description "$Description.api"
    $endpointUri = $null
    Assert-GaCondition ($endpointValue -is [string] -and [Uri]::TryCreate([string]$endpointValue, [UriKind]::Absolute, [ref]$endpointUri)) "$Description.api.endpoint must be an absolute URL"
    Assert-GaCondition ($endpointUri.Scheme.Equals('https', [StringComparison]::OrdinalIgnoreCase) -and $endpointUri.Host.Equals('api.github.com', [StringComparison]::OrdinalIgnoreCase)) "$Description.api.endpoint must use api.github.com over HTTPS"
    Assert-GaCondition ([string]::IsNullOrWhiteSpace($endpointUri.UserInfo) -and [string]::IsNullOrWhiteSpace($endpointUri.Fragment)) "$Description.api.endpoint must not contain credentials or fragments"
    Assert-GaCondition ($endpointUri.AbsolutePath.TrimEnd('/') -ceq '/repos/TypeThe0ry/ClusterYourCodex/issues') "$Description.api.endpoint must target the canonical repository issues endpoint"
    Assert-GaCondition ($endpointUri.Query -ceq '?state=open&per_page=100') "$Description.api.endpoint must request the complete open issue pages"
    foreach ($booleanField in @('complete', 'incomplete', 'hasNextPage')) {
        $booleanValue = Get-GaProperty -Object $api -Path $booleanField -Description "$Description.api"
        Assert-GaCondition ($booleanValue -is [bool]) "$Description.api.$booleanField must be boolean"
    }
    Assert-GaCondition ([bool]$api.complete) "$Description.api.complete must be true"
    Assert-GaCondition (-not [bool]$api.incomplete) "$Description.api.incomplete must be false"
    Assert-GaCondition (-not [bool]$api.hasNextPage) "$Description.api.hasNextPage must be false"
    [void](Assert-GaRawLogCount -Value (Get-GaProperty -Object $api -Path 'pageCount' -Description "$Description.api") -Description "$Description.api.pageCount" -RequirePositive $true)
    $totalCount = Assert-GaRawLogCount -Value (Get-GaProperty -Object $api -Path 'totalCount' -Description "$Description.api") -Description "$Description.api.totalCount"
    $returnedCount = Assert-GaRawLogCount -Value (Get-GaProperty -Object $api -Path 'returnedCount' -Description "$Description.api") -Description "$Description.api.returnedCount"
    $apiCapturedAt = Convert-GaRawLogInstant -Value (Get-GaProperty -Object $api -Path 'capturedAt' -Description "$Description.api") -Description "$Description.api.capturedAt"
    Assert-GaCondition ($apiCapturedAt -eq $capturedAt) "$Description.api.capturedAt must match capturedAt"
    Assert-GaCondition ($apiCapturedAt -le $now) "$Description.api.capturedAt must not be in the future"
    $apiCommit = Get-GaProperty -Object $api -Path 'sourceCommit' -Description "$Description.api"
    Assert-GaCondition ($apiCommit -is [string] -and [string]$apiCommit -match '^[0-9a-fA-F]{40}$') "$Description.api.sourceCommit must be a full 40-character commit SHA"
    Assert-GaCondition ([string]$apiCommit -ieq $ExpectedCommit) "$Description.api.sourceCommit must match the reviewed stable source commit"
    $apiError = Get-GaProperty -Object $api -Path 'error' -Description "$Description.api"
    Assert-GaCondition ($null -eq $apiError -or ($apiError -is [string] -and [string]::IsNullOrWhiteSpace([string]$apiError))) "$Description.api.error must be null or empty"

    $issues = $Snapshot.PSObject.Properties['issues'].Value
    Assert-GaCondition ($issues -is [System.Array]) "$Description.issues must be a JSON array"
    Assert-GaCondition ([long]$returnedCount -eq [long]$issues.Count) "$Description.api.returnedCount must equal the issue snapshot length"
    Assert-GaCondition ([long]$totalCount -eq [long]$issues.Count) "$Description.api.totalCount must equal the issue snapshot length"
    $seenIssueNumbers = New-Object 'System.Collections.Generic.HashSet[long]'
    foreach ($issue in @($issues)) {
        Assert-GaExactObjectPropertySet -Object $issue -Required @('number', 'state', 'title', 'html_url', 'labels') -Description "$Description.issues entry"
        $number = Get-GaProperty -Object $issue -Path 'number' -Description "$Description.issues entry"
        Assert-GaCondition ((Test-GaInteger -Value $number) -and [decimal]$number -gt 0 -and $seenIssueNumbers.Add([long]$number)) "$Description.issues.number must be a unique positive integer"
        [void](Assert-GaString -Object $issue -Path 'state' -Expected 'open' -Description "$Description.issues #$number")
        $title = Get-GaProperty -Object $issue -Path 'title' -Description "$Description.issues #$number"
        Assert-GaCondition ($title -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$title)) "$Description.issues #$number.title must be a non-empty string"
        [void](Assert-GaString -Object $issue -Path 'html_url' -Expected "https://github.com/$GaBlockerRepository/issues/$number" -Description "$Description.issues #$number")
        # Read the array-valued labels property through PSObject.Properties so
        # Windows PowerShell 5.1 does not unwrap a one-label array while
        # passing it through command substitution.
        $labelArray = $issue.PSObject.Properties['labels'].Value
        Assert-GaCondition ($labelArray -is [System.Array]) "$Description.issues #$number.labels must be a JSON array"
        foreach ($label in @($labelArray)) {
            Assert-GaExactObjectPropertySet -Object $label -Required @('name') -Description "$Description.issues #$number.labels entry"
        }
        [void](Get-GaBlockerPriorityLabels -Labels $labelArray -Description "$Description.issues #$number")
    }

    return [pscustomobject]@{
        schemaVersion = $GaOpenIssueSnapshotSchema
        sourceCommit = [string]$sourceCommit
        capturedAt = $capturedAt
        issues = @($issues)
        issueCount = [int64]$issues.Count
    }
}

function Assert-GaLiveBlockerInventory {
    param(
        [Parameter(Mandatory = $true)][object]$Inventory,
        [Parameter(Mandatory = $true)][object]$LiveSnapshot,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [Parameter(Mandatory = $true)][string]$Description
    )

    [void](Assert-GaBlockerInventory -Inventory $Inventory -ExpectedCommit $ExpectedCommit -Description "$Description.inventory")
    $live = Assert-GaOpenIssueSnapshot -Snapshot $LiveSnapshot -ExpectedCommit $ExpectedCommit -Description "$Description.live"
    $inventoryIssues = $Inventory.PSObject.Properties['issues'].Value
    $inventoryBinding = Get-GaIssueSetBinding -Issues @($inventoryIssues) -Description "$Description.inventory.issues"
    $liveBinding = Get-GaIssueSetBinding -Issues @($live.issues) -Description "$Description.live.issues"
    Assert-GaCondition ($inventoryBinding -ceq $liveBinding) "$Description must match the complete live open-issue snapshot"

    $inventoryApi = Get-GaProperty -Object $Inventory -Path 'api' -Description "$Description.inventory"
    $inventoryCapturedAt = Convert-GaRawLogInstant -Value (Get-GaProperty -Object $inventoryApi -Path 'capturedAt' -Description "$Description.inventory.api") -Description "$Description.inventory.api.capturedAt"
    $age = [DateTimeOffset]::UtcNow - $inventoryCapturedAt
    Assert-GaCondition ($age -ge [TimeSpan]::Zero) "$Description.inventory.api.capturedAt must not be in the future"
    Assert-GaCondition ($age -le $GaMaximumBlockerInventoryAge) "$Description.inventory.api.capturedAt must be no more than $([int]$GaMaximumBlockerInventoryAge.TotalHours) hours old"

    return [pscustomobject]@{
        inventoryEvidenceId = [string](Get-GaProperty -Object $Inventory -Path 'evidenceId' -Description $Description)
        liveCapturedAt = $live.capturedAt
        issueCount = $live.issueCount
        maxAgeHours = [int]$GaMaximumBlockerInventoryAge.TotalHours
    }
}

function Get-GaBlockerInventoryBinding {
    param(
        [Parameter(Mandatory = $true)][object]$Inventory,
        [Parameter(Mandatory = $true)][string]$Description
    )

    # JSON object property order is not semantic.  Build a compact canonical
    # projection before cross-binding the same inventory through the manifest,
    # downloaded envelope, and raw-verification summary.  The caller has
    # already run Assert-GaBlockerInventory, so this projection contains every
    # contract field while ignoring harmless serialization order differences.
    $reviewer = Get-GaProperty -Object $Inventory -Path 'reviewer' -Description $Description
    $api = Get-GaProperty -Object $Inventory -Path 'api' -Description $Description
    $issues = $Inventory.PSObject.Properties['issues'].Value
    $issueBindings = New-Object System.Collections.Generic.List[object]
    foreach ($issue in @($issues | Sort-Object { [long](Get-GaProperty -Object $_ -Path 'number' -Description $Description) })) {
        $labels = $issue.PSObject.Properties['labels'].Value
        $labelBindings = New-Object System.Collections.Generic.List[string]
        foreach ($label in @($labels | Sort-Object { [string](Get-GaProperty -Object $_ -Path 'name' -Description $Description) })) {
            [void]$labelBindings.Add([string](Get-GaProperty -Object $label -Path 'name' -Description $Description))
        }
        [void]$issueBindings.Add([ordered]@{
                number = [long](Get-GaProperty -Object $issue -Path 'number' -Description $Description)
                state = [string](Get-GaProperty -Object $issue -Path 'state' -Description $Description)
                title = [string](Get-GaProperty -Object $issue -Path 'title' -Description $Description)
                html_url = [string](Get-GaProperty -Object $issue -Path 'html_url' -Description $Description)
                labels = $labelBindings.ToArray()
            })
    }

    $waivers = $Inventory.PSObject.Properties['waivers'].Value
    $waiverBindings = New-Object System.Collections.Generic.List[object]
    foreach ($waiver in @($waivers | Sort-Object { [long](Get-GaProperty -Object $_ -Path 'issueNumber' -Description $Description) })) {
        $scope = Get-GaProperty -Object $waiver -Path 'scope' -Description $Description
        $waiverReviewer = Get-GaProperty -Object $waiver -Path 'reviewer' -Description $Description
        $waiverExpiresAt = Convert-GaRawLogInstant -Value (Get-GaProperty -Object $waiver -Path 'expiresAt' -Description $Description) -Description "$Description.waivers.expiresAt"
        [void]$waiverBindings.Add([ordered]@{
                issueNumber = [long](Get-GaProperty -Object $waiver -Path 'issueNumber' -Description $Description)
                scope = [ordered]@{
                    repository = [string](Get-GaProperty -Object $scope -Path 'repository' -Description $Description)
                    channel = [string](Get-GaProperty -Object $scope -Path 'channel' -Description $Description)
                    issueNumber = [long](Get-GaProperty -Object $scope -Path 'issueNumber' -Description $Description)
                }
                sourceCommit = [string](Get-GaProperty -Object $waiver -Path 'sourceCommit' -Description $Description)
                expiresAtTicks = $waiverExpiresAt.UtcDateTime.Ticks
                reviewer = [ordered]@{
                    id = [long](Get-GaProperty -Object $waiverReviewer -Path 'id' -Description $Description)
                    login = [string](Get-GaProperty -Object $waiverReviewer -Path 'login' -Description $Description)
                }
                status = [string](Get-GaProperty -Object $waiver -Path 'status' -Description $Description)
                reason = [string](Get-GaProperty -Object $waiver -Path 'reason' -Description $Description)
            })
    }

    $reviewedAt = Convert-GaRawLogInstant -Value (Get-GaProperty -Object $Inventory -Path 'reviewedAt' -Description $Description) -Description "$Description.reviewedAt"
    $expiresAt = Convert-GaRawLogInstant -Value (Get-GaProperty -Object $Inventory -Path 'expiresAt' -Description $Description) -Description "$Description.expiresAt"
    $apiErrorProperty = $api.PSObject.Properties['error']
    $apiError = if ($null -eq $apiErrorProperty -or $null -eq $apiErrorProperty.Value) { $null } else { [string]$apiErrorProperty.Value }
    $canonical = [ordered]@{
        schemaVersion = [string](Get-GaProperty -Object $Inventory -Path 'schemaVersion' -Description $Description)
        status = [string](Get-GaProperty -Object $Inventory -Path 'status' -Description $Description)
        sourceCommit = [string](Get-GaProperty -Object $Inventory -Path 'sourceCommit' -Description $Description)
        evidenceId = [string](Get-GaProperty -Object $Inventory -Path 'evidenceId' -Description $Description)
        repository = [string](Get-GaProperty -Object $Inventory -Path 'repository' -Description $Description)
        reviewer = [ordered]@{
            id = [long](Get-GaProperty -Object $reviewer -Path 'id' -Description $Description)
            login = [string](Get-GaProperty -Object $reviewer -Path 'login' -Description $Description)
        }
        reviewedAtTicks = $reviewedAt.UtcDateTime.Ticks
        expiresAtTicks = $expiresAt.UtcDateTime.Ticks
        api = [ordered]@{
            provider = [string](Get-GaProperty -Object $api -Path 'provider' -Description $Description)
            endpoint = [string](Get-GaProperty -Object $api -Path 'endpoint' -Description $Description)
            requestedState = [string](Get-GaProperty -Object $api -Path 'requestedState' -Description $Description)
            complete = [bool](Get-GaProperty -Object $api -Path 'complete' -Description $Description)
            incomplete = [bool](Get-GaProperty -Object $api -Path 'incomplete' -Description $Description)
            hasNextPage = [bool](Get-GaProperty -Object $api -Path 'hasNextPage' -Description $Description)
            pageCount = [long](Get-GaProperty -Object $api -Path 'pageCount' -Description $Description)
            totalCount = [long](Get-GaProperty -Object $api -Path 'totalCount' -Description $Description)
            returnedCount = [long](Get-GaProperty -Object $api -Path 'returnedCount' -Description $Description)
            capturedAtTicks = (Convert-GaRawLogInstant -Value (Get-GaProperty -Object $api -Path 'capturedAt' -Description $Description) -Description "$Description.api.capturedAt").UtcDateTime.Ticks
            sourceCommit = [string](Get-GaProperty -Object $api -Path 'sourceCommit' -Description $Description)
            error = $apiError
        }
        issues = $issueBindings.ToArray()
        waivers = $waiverBindings.ToArray()
    }
    return ($canonical | ConvertTo-Json -Depth 30 -Compress)
}

function Assert-GaBlockerGateEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$GateEvidence,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-GaExactObjectPropertySet -Object $GateEvidence `
        -Required @('status', 'sourceCommit', 'evidenceId', 'blockerInventory') `
        -Description $Description
    $status = Get-GaProperty -Object $GateEvidence -Path 'status' -Description $Description
    Assert-GaCondition (($status -is [bool]) -and $status) "$Description.status must be boolean true"
    $sourceCommit = Get-GaProperty -Object $GateEvidence -Path 'sourceCommit' -Description $Description
    Assert-GaCondition ($sourceCommit -is [string] -and [string]$sourceCommit -match '^[0-9a-fA-F]{40}$') "$Description.sourceCommit must be a full 40-character commit SHA"
    Assert-GaCondition ([string]$sourceCommit -ieq $ExpectedCommit) "$Description.sourceCommit must match the reviewed stable source commit"
    $evidenceId = Get-GaProperty -Object $GateEvidence -Path 'evidenceId' -Description $Description
    Assert-GaCondition ($evidenceId -is [string] -and [string]$evidenceId -match $GaBlockerEvidenceIdPattern) "$Description.evidenceId must be a bounded portable retained-inventory identifier"
    [void](Assert-GaBlockerInventory -Inventory (Get-GaProperty -Object $GateEvidence -Path 'blockerInventory' -Description $Description) -ExpectedCommit $ExpectedCommit -Description "$Description.blockerInventory")
    return (Get-GaProperty -Object $GateEvidence -Path 'blockerInventory' -Description $Description)
}

function Get-GaIssue23GateMarker {
    param(
        [Parameter(Mandatory = $true)][string]$IssueName,
        [Parameter(Mandatory = $true)][string]$Gate,
        [Parameter(Mandatory = $true)][string]$Command
    )

    $commandDigest = Get-GaIssue5CommandSha256 -Command $Command
    return "CYC-GA-$($IssueName.ToUpperInvariant())|gate=$Gate|commandSha256=$commandDigest|status=passed"
}

function Get-GaIssue3GateContract {
    param(
        [Parameter(Mandatory = $true)][string]$Gate,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $property = $GaIssue3GateContract.gates.PSObject.Properties[$Gate]
    Assert-GaCondition ($null -ne $property) "$Description has a reviewed Issue #3 semantic contract"
    $contract = $property.Value
    Assert-GaCondition (($contract -is [pscustomobject]) -and -not ($contract -is [System.Array])) "$Description semantic contract is a JSON object"
    foreach ($field in @('platform', 'platforms', 'hostArchitectures', 'architectures', 'target', 'coverageTargets', 'rustTargets', 'kitTargets', 'operation', 'commandId', 'selectorId', 'commandPatterns', 'selectorPatterns')) {
        Assert-GaCondition ($null -ne $contract.PSObject.Properties[$field]) "$Description semantic contract is missing '$field'"
    }
    return $contract
}

function Get-GaIssue3SemanticMarker {
    param(
        [Parameter(Mandatory = $true)][string]$Gate,
        [Parameter(Mandatory = $true)][string]$Platform,
        [Parameter(Mandatory = $true)][string]$HostArchitecture,
        [Parameter(Mandatory = $true)][string]$Architecture,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string[]]$CoverageTargets,
        [Parameter(Mandatory = $true)][string]$RustTarget,
        [Parameter(Mandatory = $true)][string]$KitTarget,
        [Parameter(Mandatory = $true)][string]$Operation,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$Selector
    )

    $coverageToken = @($CoverageTargets | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object) -join ','
    $commandDigest = Get-GaIssue5CommandSha256 -Command $Command
    $selectorDigest = Get-GaIssue5CommandSha256 -Command $Selector
    return "CYC-GA-ISSUE3|v=2|gate=$Gate|target=$Target|platform=$Platform|hostArchitecture=$HostArchitecture|architecture=$Architecture|coverageTargets=$coverageToken|rustTarget=$RustTarget|kitTarget=$KitTarget|operation=$Operation|selectorSha256=$selectorDigest|commandSha256=$commandDigest|status=passed"
}

function Assert-GaIssue3GateSemantics {
    param(
        [Parameter(Mandatory = $true)][string]$Gate,
        [Parameter(Mandatory = $true)][object]$GateEvidence,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$Selector,
        [Parameter(Mandatory = $true)][object[]]$Markers,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $contract = Get-GaIssue3GateContract -Gate $Gate -Description $Description
    $platform = Get-GaProperty -Object $GateEvidence -Path 'platform' -Description $Description
    $hostArchitecture = Get-GaProperty -Object $GateEvidence -Path 'hostArchitecture' -Description $Description
    $architecture = Get-GaProperty -Object $GateEvidence -Path 'architecture' -Description $Description
    $target = Get-GaProperty -Object $GateEvidence -Path 'target' -Description $Description
    $coverageTargetsProperty = $GateEvidence.PSObject.Properties['coverageTargets']
    Assert-GaCondition ($null -ne $coverageTargetsProperty) "$Description.coverageTargets is required"
    $coverageTargetsValue = $coverageTargetsProperty.Value
    $rustTarget = Get-GaProperty -Object $GateEvidence -Path 'rustTarget' -Description $Description
    $kitTarget = Get-GaProperty -Object $GateEvidence -Path 'kitTarget' -Description $Description
    $operation = Get-GaProperty -Object $GateEvidence -Path 'operation' -Description $Description
    $platformsProperty = $GateEvidence.PSObject.Properties['platforms']
    Assert-GaCondition ($null -ne $platformsProperty) "$Description.platforms is required"
    $platformsValue = $platformsProperty.Value
    Assert-GaCondition ($platform -is [string] -and [string]$platform -ceq ([string]$platform).ToLowerInvariant()) "$Description.platform must be a lower-case string"
    Assert-GaCondition ($hostArchitecture -is [string] -and [string]$hostArchitecture -ceq ([string]$hostArchitecture).ToLowerInvariant()) "$Description.hostArchitecture must be a lower-case string"
    Assert-GaCondition ($architecture -is [string] -and [string]$architecture -ceq ([string]$architecture).ToLowerInvariant()) "$Description.architecture must be a lower-case string"
    Assert-GaCondition ($target -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$target)) "$Description.target must be a non-empty string"
    Assert-GaCondition ($rustTarget -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$rustTarget)) "$Description.rustTarget must be a non-empty string"
    Assert-GaCondition ($kitTarget -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$kitTarget)) "$Description.kitTarget must be a non-empty string"
    Assert-GaCondition ($operation -is [string] -and [string]$operation -ceq ([string]$operation).ToLowerInvariant()) "$Description.operation must be a lower-case string"
    Assert-GaCondition ($platform -ceq [string]$contract.platform) "$Description.platform must equal the reviewed semantic platform '$($contract.platform)'"
    $allowedHostArchitectures = @($contract.hostArchitectures | ForEach-Object { [string]$_ })
    Assert-GaCondition ($allowedHostArchitectures.Count -gt 0 -and @($allowedHostArchitectures | Where-Object { $_ -ceq [string]$hostArchitecture }).Count -eq 1) "$Description.hostArchitecture is not allowed for Issue #3.$Gate"
    $allowedArchitectures = @($contract.architectures | ForEach-Object { [string]$_ })
    Assert-GaCondition ($allowedArchitectures.Count -gt 0 -and @($allowedArchitectures | Where-Object { $_ -ceq [string]$architecture }).Count -eq 1) "$Description.architecture is not allowed for Issue #3.$Gate"
    Assert-GaCondition ([string]$target -ceq [string]$contract.target) "$Description.target must equal the reviewed semantic target '$($contract.target)'"
    $allowedRustTargets = @($contract.rustTargets | ForEach-Object { [string]$_ })
    Assert-GaCondition ($allowedRustTargets.Count -gt 0 -and @($allowedRustTargets | Where-Object { $_ -ceq [string]$rustTarget }).Count -eq 1) "$Description.rustTarget is not allowed for Issue #3.$Gate"
    $allowedKitTargets = @($contract.kitTargets | ForEach-Object { [string]$_ })
    Assert-GaCondition ($allowedKitTargets.Count -gt 0 -and @($allowedKitTargets | Where-Object { $_ -ceq [string]$kitTarget }).Count -eq 1) "$Description.kitTarget is not allowed for Issue #3.$Gate"
    Assert-GaCondition ($operation -ceq [string]$contract.operation) "$Description.operation must equal the reviewed semantic operation '$($contract.operation)'"
    Assert-GaCondition (($platformsValue -is [System.Array]) -and $platformsValue.Count -gt 0) "$Description.platforms must be a non-empty JSON array"
    $actualPlatforms = @($platformsValue | ForEach-Object { Assert-GaCondition ($_ -is [string]) "$Description.platforms entries must be strings"; [string]$_ })
    Assert-GaCondition (@($actualPlatforms | Where-Object { $_ -cne $_.ToLowerInvariant() }).Count -eq 0) "$Description.platforms entries must be lower-case"
    $actualPlatformSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($item in $actualPlatforms) {
        Assert-GaCondition ($actualPlatformSet.Add($item)) "$Description.platforms must not contain duplicates"
    }
    $expectedPlatforms = @($contract.platforms | ForEach-Object { [string]$_ } | Sort-Object)
    $normalizedActualPlatforms = @($actualPlatforms | Sort-Object)
    Assert-GaCondition (($normalizedActualPlatforms -join ',') -ceq ($expectedPlatforms -join ',')) "$Description.platforms must equal the reviewed platform set '$($expectedPlatforms -join ',')'"

    Assert-GaCondition (($coverageTargetsValue -is [System.Array]) -and $coverageTargetsValue.Count -gt 0) "$Description.coverageTargets must be a non-empty JSON array"
    $actualCoverageTargets = @($coverageTargetsValue | ForEach-Object {
            Assert-GaCondition ($_ -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$_)) "$Description.coverageTargets entries must be non-empty strings"
            Assert-GaCondition ([string]$_ -ceq ([string]$_).ToLowerInvariant()) "$Description.coverageTargets entries must be lower-case"
            [string]$_
        })
    $coverageSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($item in $actualCoverageTargets) { Assert-GaCondition ($coverageSet.Add($item)) "$Description.coverageTargets must not contain duplicates" }
    $expectedCoverageTargets = @($contract.coverageTargets | ForEach-Object { [string]$_ } | Sort-Object)
    Assert-GaCondition ((@($actualCoverageTargets | Sort-Object) -join ',') -ceq ($expectedCoverageTargets -join ',')) "$Description.coverageTargets must equal the reviewed target set '$($expectedCoverageTargets -join ',')'"

    $commandIdProperty = $GateEvidence.PSObject.Properties['commandId']
    $selectorIdProperty = $GateEvidence.PSObject.Properties['selectorId']
    Assert-GaCondition ($null -ne $commandIdProperty -and $commandIdProperty.Value -is [string] -and [string]$commandIdProperty.Value -ceq [string]$contract.commandId) "$Description.commandId must equal the reviewed command ID '$($contract.commandId)'"
    Assert-GaCondition ($null -ne $selectorIdProperty -and $selectorIdProperty.Value -is [string] -and [string]$selectorIdProperty.Value -ceq [string]$contract.selectorId) "$Description.selectorId must equal the reviewed selector ID '$($contract.selectorId)'"

    foreach ($pattern in @($contract.commandPatterns)) {
        Assert-GaCondition ($pattern -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$pattern)) "$Description semantic command pattern must be non-empty"
        try {
            $matches = [regex]::IsMatch($Command, [string]$pattern)
        } catch {
            throw "GA readiness assertion failed: $Description semantic command pattern is invalid: $($_.Exception.Message)"
        }
        Assert-GaCondition $matches "$Description.command must satisfy Issue #3.$Gate semantic pattern '$pattern'"
    }
    foreach ($pattern in @($contract.selectorPatterns)) {
        Assert-GaCondition ($pattern -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$pattern)) "$Description semantic selector pattern must be non-empty"
        try {
            $matches = [regex]::IsMatch($Selector, [string]$pattern)
        } catch {
            throw "GA readiness assertion failed: $Description semantic selector pattern is invalid: $($_.Exception.Message)"
        }
        Assert-GaCondition $matches "$Description.testSelector must satisfy Issue #3.$Gate semantic pattern '$pattern'"
    }
    $semanticMarker = Get-GaIssue3SemanticMarker `
        -Gate $Gate `
        -Platform ([string]$platform) `
        -HostArchitecture ([string]$hostArchitecture) `
        -Architecture ([string]$architecture) `
        -Target ([string]$target) `
        -CoverageTargets $actualCoverageTargets `
        -RustTarget ([string]$rustTarget) `
        -KitTarget ([string]$kitTarget) `
        -Operation ([string]$operation) `
        -Command $Command `
        -Selector $Selector
    Assert-GaCondition (@($Markers | Where-Object { [string]$_ -ceq $semanticMarker }).Count -eq 1) "$Description.rawLogMarkers must contain the semantic Issue #3 marker"
    return [pscustomobject]@{
        platform = [string]$platform
        hostArchitecture = [string]$hostArchitecture
        architecture = [string]$architecture
        target = [string]$target
        coverageTargets = $actualCoverageTargets
        rustTarget = [string]$rustTarget
        kitTarget = [string]$kitTarget
        operation = [string]$operation
        commandId = [string]$commandIdProperty.Value
        selectorId = [string]$selectorIdProperty.Value
        platforms = $actualPlatforms
        semanticMarker = $semanticMarker
    }
}

function Assert-GaIssue23GateEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$ManifestIssue,
        [Parameter(Mandatory = $true)][string]$IssueName,
        [Parameter(Mandatory = $true)][string]$Gate,
        [Parameter(Mandatory = $true)][object]$GateEvidence,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-GaExactObjectPropertySet -Object $GateEvidence `
        -Required @('status', 'gateId', 'sourceCommit', 'provider', 'hostType', 'evidenceId', 'runId', 'node', 'exitCode', 'tests', 'startedAt', 'endedAt', 'command') `
        -Optional @('gate', 'testSelector', 'selector', 'rawLogMarkers', 'markers', 'blockerInventory', 'platform', 'hostArchitecture', 'architecture', 'target', 'coverageTargets', 'rustTarget', 'kitTarget', 'operation', 'platforms', 'commandId', 'selectorId') `
        -Description $Description
    $status = Get-GaProperty -Object $GateEvidence -Path 'status' -Description $Description
    Assert-GaCondition (($status -is [bool]) -and $status) "$Description.status must be boolean true"
    $gateId = Get-GaProperty -Object $GateEvidence -Path 'gateId' -Description $Description
    Assert-GaCondition ($gateId -is [string] -and [string]$gateId -ceq "$IssueName.$Gate") "$Description.gateId must equal '$IssueName.$Gate'"
    $gateProperty = $GateEvidence.PSObject.Properties['gate']
    if ($null -ne $gateProperty) {
        Assert-GaCondition ($gateProperty.Value -is [string] -and [string]$gateProperty.Value -ceq $Gate) "$Description.gate must equal '$Gate'"
    }
    $sourceCommit = Get-GaProperty -Object $GateEvidence -Path 'sourceCommit' -Description $Description
    Assert-GaCondition ($sourceCommit -is [string] -and [string]$sourceCommit -match '^[0-9a-fA-F]{40}$') "$Description.sourceCommit must be a full commit SHA"
    Assert-GaCondition ([string]$sourceCommit -ieq $ExpectedCommit) "$Description.sourceCommit must match the reviewed stable source commit"
    $manifestEvidenceId = [string](Get-GaProperty -Object $ManifestIssue -Path 'evidenceId' -Description $Description)
    foreach ($field in @('provider', 'hostType', 'evidenceId', 'runId', 'node', 'command')) {
        $value = Get-GaProperty -Object $GateEvidence -Path $field -Description $Description
        Assert-GaCondition ($value -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$value)) "$Description.$field must be a non-empty string"
    }
    foreach ($field in @('provider', 'hostType', 'node')) {
        $value = [string](Get-GaProperty -Object $GateEvidence -Path $field -Description $Description)
        Assert-GaCondition ($value -notmatch '(?i)github|actions|hosted|runner') "$Description.$field must identify an external execution surface"
    }
    $gateEvidenceId = [string](Get-GaProperty -Object $GateEvidence -Path 'evidenceId' -Description $Description)
    Assert-GaCondition ($gateEvidenceId -match $GaBlockerEvidenceIdPattern) "$Description.evidenceId must be a bounded portable retained-evidence identifier"
    Assert-GaCondition ($gateEvidenceId -ceq $manifestEvidenceId) "$Description.evidenceId must match the issue evidenceId"
    $runId = [string](Get-GaProperty -Object $GateEvidence -Path 'runId' -Description $Description)
    $node = [string](Get-GaProperty -Object $GateEvidence -Path 'node' -Description $Description)
    Assert-GaCondition ($runId -match $GaIssue5RunIdentifierPattern) "$Description.runId must be a bounded portable run identifier"
    Assert-GaCondition ($node -match $GaIssue5RunIdentifierPattern) "$Description.node must be a bounded portable node identifier"
    $command = [string](Get-GaProperty -Object $GateEvidence -Path 'command' -Description $Description)
    $selector = Get-GaIssue5RunSelector -Run $GateEvidence -Description $Description
    $markers = @(Get-GaIssue5GateMarkers -GateEvidence $GateEvidence -Description $Description)
    $semanticContract = $null
    if ($IssueName -ceq 'issue3') {
        $semanticContract = Assert-GaIssue3GateSemantics `
            -Gate $Gate `
            -GateEvidence $GateEvidence `
            -Command $command `
            -Selector $selector `
            -Markers $markers `
            -Description $Description
    }
    $expectedMarker = Get-GaIssue23GateMarker -IssueName $IssueName -Gate $Gate -Command $command
    Assert-GaCondition (@($markers | Where-Object { [string]$_ -ceq $expectedMarker }).Count -eq 1) "$Description.rawLogMarkers must contain the command-bound gate marker"
    $provenance = Assert-GaIssue5RunProvenance -Run $GateEvidence -Description $Description

    if ($IssueName -ceq 'issue2' -and $Gate -ceq 'noOpenUnwaivedP0P1Blocker') {
        $inventoryProperty = $GateEvidence.PSObject.Properties['blockerInventory']
        Assert-GaCondition ($null -ne $inventoryProperty) "$Description.blockerInventory is required for noOpenUnwaivedP0P1Blocker"
        [void](Assert-GaBlockerInventory -Inventory $inventoryProperty.Value -ExpectedCommit $ExpectedCommit -Description "$Description.blockerInventory")
    } elseif ($null -ne $GateEvidence.PSObject.Properties['blockerInventory']) {
        Assert-GaCondition $false "$Description.blockerInventory is only permitted on issue2.noOpenUnwaivedP0P1Blocker"
    }

    $result = [pscustomobject]@{
        gate = $Gate
        status = $true
        gateId = "$IssueName.$Gate"
        sourceCommit = [string]$sourceCommit
        provider = [string](Get-GaProperty -Object $GateEvidence -Path 'provider' -Description $Description)
        hostType = [string](Get-GaProperty -Object $GateEvidence -Path 'hostType' -Description $Description)
        evidenceId = $gateEvidenceId
        runId = $runId
        node = $node
         exitCode = [int64]$provenance.exitCode
         tests = $provenance.tests
         startedAt = [string]$provenance.startedAt
         endedAt = [string]$provenance.endedAt
        testSelector = $selector
        command = $command
        markers = $markers
    }
    if ($IssueName -ceq 'issue2' -and $Gate -ceq 'noOpenUnwaivedP0P1Blocker') {
        $result | Add-Member -MemberType NoteProperty -Name blockerInventory -Value $GateEvidence.blockerInventory
    }
    if ($IssueName -ceq 'issue3') {
        foreach ($propertyName in @('platform', 'hostArchitecture', 'architecture', 'target', 'coverageTargets', 'rustTarget', 'kitTarget', 'operation', 'platforms', 'commandId', 'selectorId')) {
            $result | Add-Member -MemberType NoteProperty -Name $propertyName -Value $semanticContract.$propertyName
        }
    }
    return $result
}

function Assert-GaIssue23Evidence {
    param(
        [Parameter(Mandatory = $true)][object]$Node,
        [Parameter(Mandatory = $true)][string]$IssueName,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-GaCondition ($GaIssue23GateNames.Contains($IssueName)) "$Description has a reviewed Issue #2/#3 name"
    $expectedGates = @($GaIssue23GateNames[$IssueName])
    $gates = Get-GaProperty -Object $Node -Path 'gates' -Description $Description
    Assert-GaExactGateSet -Gates $gates -RequiredGates $expectedGates -Description $Description
    $gateRecords = New-Object System.Collections.Generic.List[object]
    $allMarkers = New-Object System.Collections.Generic.List[string]
    foreach ($gate in $expectedGates) {
        $gateEvidence = $gates.PSObject.Properties[$gate].Value
        $gateRecord = Assert-GaIssue23GateEvidence `
            -ManifestIssue $Node `
            -IssueName $IssueName `
            -Gate $gate `
            -GateEvidence $gateEvidence `
            -ExpectedCommit $ExpectedCommit `
            -Description "$Description.gates.$gate"
        [void]$gateRecords.Add($gateRecord)
        foreach ($marker in @($gateRecord.markers)) {
            Assert-GaCondition (-not (@($allMarkers | Where-Object { [string]$_ -ceq [string]$marker }).Count -gt 0)) "$Description gate markers must be unique across gates"
            [void]$allMarkers.Add([string]$marker)
        }
    }

    $rawLog = Get-GaProperty -Object $Node -Path 'rawLog' -Description $Description
    $rawMarkersProperty = $rawLog.PSObject.Properties['markers']
    Assert-GaCondition ($null -ne $rawMarkersProperty -and $rawMarkersProperty.Value -is [System.Array] -and $rawMarkersProperty.Value.Count -gt 0) "$Description.rawLog.markers must be a non-empty JSON array"
    $rawMarkers = @($rawMarkersProperty.Value)
    $seenRawMarkers = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($marker in $rawMarkers) {
        Assert-GaCondition ($marker -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$marker)) "$Description.rawLog.markers entries must be non-empty strings"
        Assert-GaCondition ($seenRawMarkers.Add([string]$marker)) "$Description.rawLog.markers entries must be unique"
    }
    foreach ($marker in $allMarkers.ToArray()) {
        Assert-GaCondition (@($rawMarkers | Where-Object { [string]$_ -ceq [string]$marker }).Count -eq 1) "$Description.rawLog.markers must retain '$marker'"
    }
    return [pscustomobject]@{
        gates = $gateRecords.ToArray()
        markers = $allMarkers.ToArray()
    }
}

function Assert-GaIssueEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$Evidence,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [Parameter(Mandatory = $true)][string[]]$RequiredGates
    )

    $node = Get-GaProperty -Object $Evidence -Path $Path -Description $Description
    Assert-GaCondition (($node -is [pscustomobject]) -and -not ($node -is [System.Array])) "$Description must be a JSON object"
    [void](Assert-GaString -Object $node -Path 'status' -Expected 'passed' -Description $Description)

    $sourceCommitValue = Get-GaProperty -Object $node -Path 'sourceCommit' -Description $Description
    Assert-GaCondition ($sourceCommitValue -is [string]) "$Description.sourceCommit must be a string"
    $sourceCommit = [string]$sourceCommitValue
    Assert-GaCondition ($sourceCommit -match '^[0-9a-fA-F]{40}$') "$Description.sourceCommit must be a full 40-character commit SHA"
    Assert-GaCondition ($sourceCommit.Equals($ExpectedCommit, [System.StringComparison]::OrdinalIgnoreCase)) "$Description.sourceCommit must match the reviewed stable source commit"

    foreach ($field in @('provider', 'hostType', 'evidenceId')) {
        $value = Get-GaProperty -Object $node -Path $field -Description $Description
        Assert-GaCondition ($value -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$value)) "$Description.$field must be a non-empty string"
    }
    $provider = [string](Get-GaProperty -Object $node -Path 'provider' -Description $Description)
    $hostType = [string](Get-GaProperty -Object $node -Path 'hostType' -Description $Description)
    Assert-GaCondition ($provider -notmatch '(?i)github|actions|hosted|runner') "$Description must identify an external provider, not a GitHub-hosted runner (provider='$provider')"
    Assert-GaCondition ($hostType -notmatch '(?i)github|actions|hosted|runner') "$Description must identify an external host, not a GitHub-hosted runner (hostType='$hostType')"
    $evidenceId = [string](Get-GaProperty -Object $node -Path 'evidenceId' -Description $Description)
    # Evidence IDs become filenames in the raw-log verifier. Keep them to a
    # single portable filename component so an untrusted manifest cannot
    # introduce path separators, drive-qualified paths, or traversal segments.
    Assert-GaCondition ($evidenceId -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') "$Description.evidenceId must be a bounded portable retained-evidence identifier"

    $rawLog = Get-GaProperty -Object $node -Path 'rawLog' -Description $Description
    Assert-GaCondition (($rawLog -is [pscustomobject]) -and -not ($rawLog -is [System.Array])) "$Description.rawLog must be a JSON object"
    $rawLogUrlValue = Get-GaProperty -Object $rawLog -Path 'url' -Description $Description
    Assert-GaCondition ($rawLogUrlValue -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$rawLogUrlValue)) "$Description.rawLog.url must be a non-empty string"
    $rawLogUri = $null
    $validRawLogUri = [System.Uri]::TryCreate([string]$rawLogUrlValue, [System.UriKind]::Absolute, [ref]$rawLogUri)
    Assert-GaCondition $validRawLogUri "$Description.rawLog.url must be an absolute URL"
    Assert-GaCondition ($rawLogUri.Scheme.Equals('https', [System.StringComparison]::OrdinalIgnoreCase)) "$Description.rawLog.url must use HTTPS"
    Assert-GaCondition (-not [string]::IsNullOrWhiteSpace($rawLogUri.Host)) "$Description.rawLog.url must include a host"
    Assert-GaCondition ([string]::IsNullOrWhiteSpace($rawLogUri.UserInfo)) "$Description.rawLog.url must not contain embedded credentials"
    $rawLogShaValue = Get-GaProperty -Object $rawLog -Path 'sha256' -Description $Description
    Assert-GaCondition ($rawLogShaValue -is [string] -and [string]$rawLogShaValue -match '^[0-9a-fA-F]{64}$') "$Description.rawLog.sha256 must be a 64-character SHA-256 digest"

    # A URL and a syntactically valid digest are not execution evidence. The
    # retained descriptor must bind the bytes to one concrete external-host
    # invocation. Test-GARawLogs.ps1 downloads each URL and recomputes this
    # digest; these fields bind the downloaded log to the reported run.
    foreach ($field in @('command', 'node')) {
        $value = Get-GaProperty -Object $rawLog -Path $field -Description $Description
        Assert-GaCondition ($value -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$value)) "$Description.rawLog.$field must be a non-empty string"
    }
    Assert-GaCondition ($rawLog.node -notmatch '(?i)github|actions|hosted|runner') "$Description.rawLog.node must identify an external host"
    $parsedInstants = @{}
    foreach ($field in @('startedAt', 'endedAt')) {
        $instantValue = Get-GaProperty -Object $rawLog -Path $field -Description $Description
        # Windows PowerShell's ConvertFrom-Json materializes ISO-8601 values
        # as System.DateTime; PowerShell 7 may preserve them as strings. Both
        # representations are accepted only when they carry an explicit UTC
        # designator/offset and survive strict parsing. An unspecified local
        # clock is not an attributable instant.
        Assert-GaCondition ($instantValue -is [string] -or
            $instantValue -is [DateTime] -or $instantValue -is [DateTimeOffset]) "$Description.rawLog.$field must be an ISO-8601 instant"
        try {
            if ($instantValue -is [DateTimeOffset]) {
                $parsedInstant = [DateTimeOffset]$instantValue
            } elseif ($instantValue -is [DateTime]) {
                Assert-GaCondition ($instantValue.Kind -ne [DateTimeKind]::Unspecified) "$Description.rawLog.$field must carry an explicit UTC offset"
                $parsedInstant = [DateTimeOffset]$instantValue
            } else {
                $instantText = [string]$instantValue
                Assert-GaCondition ($instantText -match '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$') "$Description.rawLog.$field must include a UTC designator or numeric offset"
                $parsedInstant = [DateTimeOffset]::Parse(
                    $instantText,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind
                )
            }
            $parsedInstants[$field] = $parsedInstant
        } catch {
            throw "GA readiness assertion failed: $Description.rawLog.$field must be a valid ISO-8601 instant with an explicit offset."
        }
    }
    Assert-GaCondition ($parsedInstants['endedAt'] -ge $parsedInstants['startedAt']) "$Description.rawLog.endedAt must not precede startedAt"
    $exitCode = Get-GaProperty -Object $rawLog -Path 'exitCode' -Description $Description
    Assert-GaCondition ((Test-GaInteger -Value $exitCode) -and [decimal]$exitCode -eq 0) "$Description.rawLog.exitCode must be integer 0 (observed '$exitCode')"
    $tests = Get-GaProperty -Object $rawLog -Path 'tests' -Description $Description
    Assert-GaCondition (($tests -is [pscustomobject]) -and -not ($tests -is [System.Array])) "$Description.rawLog.tests must be a JSON object"
    foreach ($field in @('passed', 'failed', 'ignored')) {
        $count = Get-GaProperty -Object $tests -Path $field -Description "$Description.rawLog.tests"
        [void](Assert-GaRawLogCount -Value $count -Description "$Description.rawLog.tests.$field" -RequirePositive ($field -ceq 'passed'))
    }
    Assert-GaCondition ([decimal]$tests.failed -eq 0) "$Description.rawLog.tests.failed must be zero"
    $cleanup = Get-GaProperty -Object $rawLog -Path 'cleanup' -Description $Description
    Assert-GaCondition (($cleanup -is [bool]) -and $cleanup) "$Description.rawLog.cleanup must be boolean true"

    $gates = Get-GaProperty -Object $node -Path 'gates' -Description $Description
    Assert-GaCondition (($gates -is [pscustomobject]) -and -not ($gates -is [System.Array])) "$Description.gates must be a JSON object"
    if ($Path -ceq 'issue5') {
        [void](Assert-GaIssue5Evidence -Node $node -Description $Description -RequiredGates $RequiredGates)
    } elseif ($Path -ceq 'issue2' -or $Path -ceq 'issue3') {
        [void](Assert-GaIssue23Evidence -Node $node -IssueName $Path -ExpectedCommit $ExpectedCommit -Description $Description)
    } else {
        Assert-GaExactGateSet -Gates $gates -RequiredGates $RequiredGates -Description $Description
        foreach ($gate in $RequiredGates) {
            Assert-GaTrue -Object $node -Path "gates.$gate" -Description $Description
        }
    }
    return $node
}

function Get-GaRawLogContentJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-GaCondition (Test-Path -LiteralPath $Path -PathType Leaf) "$Description exists: $Path"
    $item = Get-Item -LiteralPath $Path -Force
    Assert-GaCondition (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and -not $item.PSIsContainer) "$Description is a regular file"
    Assert-GaCondition ([long]$item.Length -gt 0) "$Description is not empty"
    Assert-GaCondition ([long]$item.Length -le [long]$GaMaximumEvidenceBytes) "$Description is within the 64 MiB limit"
    try {
        $text = [IO.File]::ReadAllText($Path)
    } catch {
        throw "GA readiness assertion failed: $Description could not be read: $($_.Exception.Message)"
    }
    Assert-GaCondition (-not [string]::IsNullOrWhiteSpace($text)) "$Description is not whitespace-only"
    try {
        $content = $text | ConvertFrom-Json
    } catch {
        throw "GA readiness assertion failed: $Description is not valid JSON: $($_.Exception.Message)"
    }
    Assert-GaCondition ($null -ne $content -and ($content -is [pscustomobject]) -and -not ($content -is [System.Array])) "$Description must be one JSON object"
    return $content
}

function Assert-GaIssue23RawLogContent {
    param(
        [Parameter(Mandatory = $true)][object]$Content,
        [Parameter(Mandatory = $true)][object]$ManifestIssue,
        [Parameter(Mandatory = $true)][string]$IssueName,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [Parameter(Mandatory = $true)][string]$Description
    )

    # Validate the manifest and derive the expected gate set from the closed
    # issue contract. A downloaded envelope is not trusted merely because it
    # repeats the same gate names: every nested record is checked independently
    # and then compared to the source-bound manifest record.
    $manifestContract = Assert-GaIssue23Evidence `
        -Node $ManifestIssue `
        -IssueName $IssueName `
        -ExpectedCommit $ExpectedCommit `
        -Description "$Description.manifest"

    $contentGates = Get-GaProperty -Object $Content -Path 'gates' -Description $Description
    Assert-GaExactGateSet `
        -Gates $contentGates `
        -RequiredGates @($GaIssue23GateNames[$IssueName]) `
        -Description $Description

    foreach ($manifestGate in @($manifestContract.gates)) {
        $gateName = [string](Get-GaProperty -Object $manifestGate -Path 'gate' -Description $Description)
        $contentGateProperty = $contentGates.PSObject.Properties[$gateName]
        Assert-GaCondition ($null -ne $contentGateProperty) "$Description.gates.$gateName is required"
        $contentGate = $contentGateProperty.Value
        $contentGateContract = Assert-GaIssue23GateEvidence `
            -ManifestIssue $ManifestIssue `
            -IssueName $IssueName `
            -Gate $gateName `
            -GateEvidence $contentGate `
            -ExpectedCommit $ExpectedCommit `
            -Description "$Description.gates.$gateName"

        foreach ($field in @('gateId', 'sourceCommit', 'provider', 'hostType', 'evidenceId', 'runId', 'node', 'testSelector')) {
            Assert-GaCondition ([string]$contentGateContract.$field -ceq [string]$manifestGate.$field) "$Description.gates.$gateName.$field must match the manifest"
        }
        $manifestCommand = Normalize-GaRawLogCommand -Command ([string](Get-GaProperty -Object $manifestGate -Path 'command' -Description $Description))
        $contentCommand = Normalize-GaRawLogCommand -Command ([string]$contentGateContract.command)
        Assert-GaCondition ($contentCommand.Equals($manifestCommand, [System.StringComparison]::Ordinal)) "$Description.gates.$gateName.command must match the manifest"
        if ($IssueName -ceq 'issue3') {
            foreach ($field in @('platform', 'hostArchitecture', 'architecture', 'target', 'rustTarget', 'kitTarget', 'operation', 'commandId', 'selectorId')) {
                Assert-GaCondition ([string]$contentGateContract.$field -ceq [string]$manifestGate.$field) "$Description.gates.$gateName.$field must match the manifest"
            }
            $manifestPlatforms = @($manifestGate.platforms | ForEach-Object { [string]$_ })
            $contentPlatforms = @($contentGateContract.platforms | ForEach-Object { [string]$_ })
            Assert-GaCondition (($contentPlatforms -join ',') -ceq ($manifestPlatforms -join ',')) "$Description.gates.$gateName.platforms must match the manifest"
            $manifestCoverage = @($manifestGate.coverageTargets | ForEach-Object { [string]$_ })
            $contentCoverage = @($contentGateContract.coverageTargets | ForEach-Object { [string]$_ })
            Assert-GaCondition (($contentCoverage -join ',') -ceq ($manifestCoverage -join ',')) "$Description.gates.$gateName.coverageTargets must match the manifest"
        }

        # Match exit code, test counts, and timestamps as well as identity. A
        # content envelope with a different run result must not pass merely
        # because its command and marker strings look correct.
        [void](Assert-GaIssue5RunProvenanceMatch `
            -ManifestRun $manifestGate `
            -VerifiedRun $contentGate `
            -Description "$Description.gates.$gateName.provenance")

        foreach ($marker in @($manifestGate.markers)) {
            Assert-GaCondition (@($contentGateContract.markers | Where-Object { [string]$_ -ceq [string]$marker }).Count -eq 1) "$Description.gates.$gateName.rawLogMarkers must retain the manifest marker '$marker'"
        }
        Assert-GaCondition ((@($contentGateContract.markers | Sort-Object) -join "`n") -ceq (@($manifestGate.markers | Sort-Object) -join "`n")) "$Description.gates.$gateName.rawLogMarkers must match the manifest marker set exactly"

        if ($IssueName -ceq 'issue2' -and $gateName -ceq 'noOpenUnwaivedP0P1Blocker') {
            $manifestInventory = Get-GaProperty -Object $manifestGate -Path 'blockerInventory' -Description $Description
            $contentInventory = Get-GaProperty -Object $contentGateContract -Path 'blockerInventory' -Description $Description
            $manifestInventoryBinding = Get-GaBlockerInventoryBinding -Inventory $manifestInventory -Description "$Description.gates.$gateName.manifest.blockerInventory"
            $contentInventoryBinding = Get-GaBlockerInventoryBinding -Inventory $contentInventory -Description "$Description.gates.$gateName.content.blockerInventory"
            Assert-GaCondition ($contentInventoryBinding -ceq $manifestInventoryBinding) "$Description.gates.$gateName.blockerInventory must match the manifest"
        }
    }

    # Read array-valued markers from the property itself. Using command
    # substitution here would unwrap a one-marker array under Windows
    # PowerShell 5.1 and weaken the type-sensitive contract.
    $manifestRawLog = Get-GaProperty -Object $ManifestIssue -Path 'rawLog' -Description $Description
    $manifestMarkersProperty = $manifestRawLog.PSObject.Properties['markers']
    Assert-GaCondition ($null -ne $manifestMarkersProperty -and $manifestMarkersProperty.Value -is [System.Array] -and $manifestMarkersProperty.Value.Count -gt 0) "$Description.manifest.rawLog.markers must be a non-empty JSON array"
    $contentMarkersProperty = $Content.PSObject.Properties['markers']
    Assert-GaCondition ($null -ne $contentMarkersProperty -and $contentMarkersProperty.Value -is [System.Array] -and $contentMarkersProperty.Value.Count -gt 0) "$Description.markers must be a non-empty JSON array"
    $contentMarkers = @($contentMarkersProperty.Value)
    $seenContentMarkers = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($marker in $contentMarkers) {
        Assert-GaCondition ($marker -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$marker)) "$Description.markers entries must be non-empty strings"
        Assert-GaCondition ($seenContentMarkers.Add([string]$marker)) "$Description.markers entries must be unique"
    }
    foreach ($marker in @($manifestMarkersProperty.Value)) {
        Assert-GaCondition (@($contentMarkers | Where-Object { [string]$_ -ceq [string]$marker }).Count -eq 1) "$Description.markers must retain the manifest marker '$marker'"
    }
    Assert-GaCondition ((@($contentMarkers | Sort-Object) -join "`n") -ceq (@($manifestMarkersProperty.Value | Sort-Object) -join "`n")) "$Description.markers must match the manifest marker set exactly"
    return $Content
}

function Assert-GaRawLogContent {
    param(
        [Parameter(Mandatory = $true)][object]$Content,
        [Parameter(Mandatory = $true)][object]$ManifestIssue,
        [Parameter(Mandatory = $true)][string]$IssueName,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [Parameter(Mandatory = $true)][string]$EvidenceId,
        [Parameter(Mandatory = $true)][string]$Description,
        [bool]$RequirePositivePassed = $true
    )

    Assert-GaCondition ($null -ne $Content -and ($Content -is [pscustomobject]) -and -not ($Content -is [System.Array])) "$Description must be one JSON object"
    Assert-GaCondition ([string](Get-GaProperty -Object $Content -Path 'schemaVersion' -Description $Description) -ceq $GaRawLogContentSchema) "$Description.schemaVersion must be $GaRawLogContentSchema"
    Assert-GaCondition ([string](Get-GaProperty -Object $Content -Path 'status' -Description $Description) -ceq 'passed') "$Description.status must be passed"

    $contentCommit = Get-GaProperty -Object $Content -Path 'sourceCommit' -Description $Description
    Assert-GaCondition ($contentCommit -is [string] -and [string]$contentCommit -match '^[0-9a-fA-F]{40}$') "$Description.sourceCommit must be a full 40-character commit SHA"
    Assert-GaCondition ([string]$contentCommit -ieq $ExpectedCommit) "$Description.sourceCommit must match ExpectedCommit"
    $contentIssue = Get-GaProperty -Object $Content -Path 'issue' -Description $Description
    Assert-GaCondition ($contentIssue -is [string] -and [string]$contentIssue -ceq $IssueName) "$Description.issue must match $IssueName"
    $contentEvidenceId = Get-GaProperty -Object $Content -Path 'evidenceId' -Description $Description
    Assert-GaCondition ($contentEvidenceId -is [string] -and [string]$contentEvidenceId -ceq $EvidenceId) "$Description.evidenceId must match the manifest"

    $manifestRawLog = Get-GaProperty -Object $ManifestIssue -Path 'rawLog' -Description $Description
    Assert-GaCondition (($manifestRawLog -is [pscustomobject]) -and -not ($manifestRawLog -is [System.Array])) "$Description.manifest.rawLog must be a JSON object"
    $manifestCommand = Get-GaProperty -Object $manifestRawLog -Path 'command' -Description $Description
    Assert-GaCondition ($manifestCommand -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$manifestCommand)) "$Description.manifest.command must be a non-empty string"
    $contentCommand = Get-GaProperty -Object $Content -Path 'command' -Description $Description
    Assert-GaCondition ($contentCommand -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$contentCommand)) "$Description.command must be a non-empty string"
    Assert-GaCondition ((Normalize-GaRawLogCommand -Command ([string]$contentCommand)).Equals((Normalize-GaRawLogCommand -Command ([string]$manifestCommand)), [StringComparison]::Ordinal)) "$Description.command must match the manifest command"

    $manifestNode = Get-GaProperty -Object $manifestRawLog -Path 'node' -Description $Description
    Assert-GaCondition ($manifestNode -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$manifestNode)) "$Description.manifest.node must be a non-empty string"
    Assert-GaCondition ([string]$manifestNode -notmatch '(?i)github|actions|hosted|runner') "$Description.manifest.node must identify an external host"
    $nodeProperty = $Content.PSObject.Properties['node']
    $hostProperty = $Content.PSObject.Properties['host']
    $hasNode = $null -ne $nodeProperty
    $hasHost = $null -ne $hostProperty
    if ($hasNode) {
        Assert-GaCondition ($nodeProperty.Value -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$nodeProperty.Value)) "$Description.node must be a non-empty string"
    }
    if ($hasHost) {
        Assert-GaCondition ($hostProperty.Value -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$hostProperty.Value)) "$Description.host must be a non-empty string"
    }
    Assert-GaCondition ($hasNode -or $hasHost) "$Description must contain a non-empty node or host"
    if ($hasNode -and $hasHost) {
        Assert-GaCondition ([string]$nodeProperty.Value -ceq [string]$hostProperty.Value) "$Description.node and $Description.host must agree"
    }
    $boundNode = if ($hasNode) { [string]$nodeProperty.Value } else { [string]$hostProperty.Value }
    Assert-GaCondition ($boundNode -ceq [string]$manifestNode) "$Description.node/host must match the manifest node"
    Assert-GaCondition ($boundNode -notmatch '(?i)github|actions|hosted|runner') "$Description.node/host must identify an external host"

    $manifestStartedAt = Convert-GaRawLogInstant -Value (Get-GaProperty -Object $manifestRawLog -Path 'startedAt' -Description $Description) -Description "$Description.manifest.startedAt"
    $manifestEndedAt = Convert-GaRawLogInstant -Value (Get-GaProperty -Object $manifestRawLog -Path 'endedAt' -Description $Description) -Description "$Description.manifest.endedAt"
    $contentStartedAt = Convert-GaRawLogInstant -Value (Get-GaProperty -Object $Content -Path 'startedAt' -Description $Description) -Description "$Description.startedAt"
    $contentEndedAt = Convert-GaRawLogInstant -Value (Get-GaProperty -Object $Content -Path 'endedAt' -Description $Description) -Description "$Description.endedAt"
    Assert-GaCondition ($contentEndedAt -ge $contentStartedAt) "$Description.endedAt must not precede startedAt"
    Assert-GaCondition ($contentStartedAt.UtcDateTime.Ticks -eq $manifestStartedAt.UtcDateTime.Ticks) "$Description.startedAt must match the manifest"
    Assert-GaCondition ($contentEndedAt.UtcDateTime.Ticks -eq $manifestEndedAt.UtcDateTime.Ticks) "$Description.endedAt must match the manifest"

    $manifestExitCode = Get-GaProperty -Object $manifestRawLog -Path 'exitCode' -Description $Description
    $contentExitCode = Get-GaProperty -Object $Content -Path 'exitCode' -Description $Description
    Assert-GaCondition ((Test-GaInteger -Value $manifestExitCode) -and [decimal]$manifestExitCode -eq 0) "$Description.manifest.exitCode must be integer 0"
    Assert-GaCondition ((Test-GaInteger -Value $contentExitCode) -and [decimal]$contentExitCode -eq 0) "$Description.exitCode must be integer 0"
    Assert-GaCondition ([decimal]$contentExitCode -eq [decimal]$manifestExitCode) "$Description.exitCode must match the manifest"

    $manifestTests = Get-GaProperty -Object $manifestRawLog -Path 'tests' -Description $Description
    $contentTests = Get-GaProperty -Object $Content -Path 'tests' -Description $Description
    Assert-GaCondition (($manifestTests -is [pscustomobject]) -and -not ($manifestTests -is [System.Array])) "$Description.manifest.tests must be a JSON object"
    Assert-GaCondition (($contentTests -is [pscustomobject]) -and -not ($contentTests -is [System.Array])) "$Description.tests must be a JSON object"
    foreach ($field in @('passed', 'failed', 'ignored')) {
        $manifestCount = Get-GaProperty -Object $manifestTests -Path $field -Description "$Description.manifest.tests"
        $contentCount = Get-GaProperty -Object $contentTests -Path $field -Description "$Description.tests"
        [void](Assert-GaRawLogCount -Value $manifestCount -Description "$Description.manifest.tests.$field" -RequirePositive ($RequirePositivePassed -and $field -ceq 'passed'))
        [void](Assert-GaRawLogCount -Value $contentCount -Description "$Description.tests.$field" -RequirePositive ($RequirePositivePassed -and $field -ceq 'passed'))
        Assert-GaCondition ([decimal]$contentCount -eq [decimal]$manifestCount) "$Description.tests.$field must match the manifest"
    }
    Assert-GaCondition ([decimal]$manifestTests.failed -eq 0) "$Description.manifest.tests.failed must be zero"
    Assert-GaCondition ([decimal]$contentTests.failed -eq 0) "$Description.tests.failed must be zero"
    $manifestCleanup = Get-GaProperty -Object $manifestRawLog -Path 'cleanup' -Description $Description
    $contentCleanup = Get-GaProperty -Object $Content -Path 'cleanup' -Description $Description
    Assert-GaCondition (($manifestCleanup -is [bool]) -and $manifestCleanup) "$Description.manifest.cleanup must be boolean true"
    Assert-GaCondition (($contentCleanup -is [bool]) -and $contentCleanup) "$Description.cleanup must be boolean true"
    Assert-GaCondition ([bool]$contentCleanup -eq [bool]$manifestCleanup) "$Description.cleanup must match the manifest"

    if ($IssueName -ceq 'issue5') {
        $manifestMarkers = Get-GaProperty -Object $manifestRawLog -Path 'markers' -Description $Description
        $contentMarkers = Get-GaProperty -Object $Content -Path 'markers' -Description $Description
        Assert-GaCondition (($manifestMarkers -is [System.Array]) -and $manifestMarkers.Count -gt 0) "$Description.manifest.markers must be a non-empty JSON array"
        Assert-GaCondition (($contentMarkers -is [System.Array]) -and $contentMarkers.Count -gt 0) "$Description.markers must be a non-empty JSON array"
        $seenContentMarkers = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($marker in @($contentMarkers)) {
            Assert-GaCondition ($marker -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$marker)) "$Description.markers entries must be non-empty strings"
            Assert-GaCondition ($seenContentMarkers.Add([string]$marker)) "$Description.markers entries must be unique"
        }
        foreach ($marker in @($manifestMarkers)) {
            Assert-GaCondition (@($contentMarkers | Where-Object { [string]$_ -ceq [string]$marker }).Count -eq 1) "$Description.markers must retain the manifest marker '$marker'"
        }
    } elseif ($IssueName -ceq 'issue2' -or $IssueName -ceq 'issue3') {
        [void](Assert-GaIssue23RawLogContent `
            -Content $Content `
            -ManifestIssue $ManifestIssue `
            -IssueName $IssueName `
            -ExpectedCommit $ExpectedCommit `
            -Description $Description)
    } else {
        throw "GA readiness assertion failed: $Description.issue '$IssueName' is not a supported issue raw-log contract."
    }
    return $Content
}

function Get-GaRawLogContentBinding {
    param(
        [Parameter(Mandatory = $true)][object]$Content,
        [Parameter(Mandatory = $true)][string]$IssueName,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $nodeProperty = $Content.PSObject.Properties['node']
    $hostProperty = $Content.PSObject.Properties['host']
    $node = if ($null -ne $nodeProperty) { [string]$nodeProperty.Value } else { [string]$hostProperty.Value }
    $startedAt = Convert-GaRawLogInstant -Value (Get-GaProperty -Object $Content -Path 'startedAt' -Description $Description) -Description "$Description.startedAt"
    $endedAt = Convert-GaRawLogInstant -Value (Get-GaProperty -Object $Content -Path 'endedAt' -Description $Description) -Description "$Description.endedAt"
    $tests = Get-GaProperty -Object $Content -Path 'tests' -Description $Description
    $binding = [ordered]@{
        schemaVersion = [string](Get-GaProperty -Object $Content -Path 'schemaVersion' -Description $Description)
        status = [string](Get-GaProperty -Object $Content -Path 'status' -Description $Description)
        sourceCommit = ([string](Get-GaProperty -Object $Content -Path 'sourceCommit' -Description $Description)).ToLowerInvariant()
        issue = [string](Get-GaProperty -Object $Content -Path 'issue' -Description $Description)
        evidenceId = [string](Get-GaProperty -Object $Content -Path 'evidenceId' -Description $Description)
        command = Normalize-GaRawLogCommand -Command ([string](Get-GaProperty -Object $Content -Path 'command' -Description $Description))
        node = $node
        startedAtTicks = $startedAt.UtcDateTime.Ticks
        endedAtTicks = $endedAt.UtcDateTime.Ticks
        exitCode = [long](Get-GaProperty -Object $Content -Path 'exitCode' -Description $Description)
        tests = [ordered]@{
            passed = [long](Get-GaProperty -Object $tests -Path 'passed' -Description $Description)
            failed = [long](Get-GaProperty -Object $tests -Path 'failed' -Description $Description)
            ignored = [long](Get-GaProperty -Object $tests -Path 'ignored' -Description $Description)
        }
        cleanup = [bool](Get-GaProperty -Object $Content -Path 'cleanup' -Description $Description)
    }
    if ($IssueName -ceq 'issue5') {
        $markers = Get-GaProperty -Object $Content -Path 'markers' -Description $Description
        $binding.markers = @($markers | Sort-Object)
    } elseif ($IssueName -ceq 'issue2' -or $IssueName -ceq 'issue3') {
        $markers = Get-GaProperty -Object $Content -Path 'markers' -Description $Description
        $binding.markers = @($markers | Sort-Object)
        $gates = Get-GaProperty -Object $Content -Path 'gates' -Description $Description
        $gateBinding = [ordered]@{}
        foreach ($property in @($gates.PSObject.Properties | Sort-Object Name)) {
            $gate = $property.Value
            $gateTests = Get-GaProperty -Object $gate -Path 'tests' -Description "$Description.gates.$($property.Name)"
            $gateBinding[[string]$property.Name] = [ordered]@{
                status = [bool](Get-GaProperty -Object $gate -Path 'status' -Description $Description)
                gateId = [string](Get-GaProperty -Object $gate -Path 'gateId' -Description $Description)
                sourceCommit = ([string](Get-GaProperty -Object $gate -Path 'sourceCommit' -Description $Description)).ToLowerInvariant()
                provider = [string](Get-GaProperty -Object $gate -Path 'provider' -Description $Description)
                hostType = [string](Get-GaProperty -Object $gate -Path 'hostType' -Description $Description)
                evidenceId = [string](Get-GaProperty -Object $gate -Path 'evidenceId' -Description $Description)
                runId = [string](Get-GaProperty -Object $gate -Path 'runId' -Description $Description)
                node = [string](Get-GaProperty -Object $gate -Path 'node' -Description $Description)
                exitCode = [long](Get-GaProperty -Object $gate -Path 'exitCode' -Description $Description)
                tests = [ordered]@{
                    passed = [long](Get-GaProperty -Object $gateTests -Path 'passed' -Description $Description)
                    failed = [long](Get-GaProperty -Object $gateTests -Path 'failed' -Description $Description)
                    ignored = [long](Get-GaProperty -Object $gateTests -Path 'ignored' -Description $Description)
                }
                startedAt = (Convert-GaRawLogInstant -Value (Get-GaProperty -Object $gate -Path 'startedAt' -Description $Description) -Description $Description).UtcDateTime.Ticks
                endedAt = (Convert-GaRawLogInstant -Value (Get-GaProperty -Object $gate -Path 'endedAt' -Description $Description) -Description $Description).UtcDateTime.Ticks
                testSelector = (Get-GaIssue5RunSelector -Run $gate -Description $Description)
                command = Normalize-GaRawLogCommand -Command ([string](Get-GaProperty -Object $gate -Path 'command' -Description $Description))
                markers = @((Get-GaIssue5GateMarkers -GateEvidence $gate -Description $Description) | Sort-Object)
            }
            if ($IssueName -ceq 'issue3') {
                foreach ($field in @('platform', 'hostArchitecture', 'architecture', 'target', 'coverageTargets', 'rustTarget', 'kitTarget', 'operation', 'commandId', 'selectorId')) {
                    $gateBinding[[string]$property.Name][$field] = Get-GaProperty -Object $gate -Path $field -Description "$Description.gates.$($property.Name)"
                }
            }
            $inventoryProperty = $gate.PSObject.Properties['blockerInventory']
            if ($null -ne $inventoryProperty) {
                $gateBinding[[string]$property.Name].blockerInventory = Get-GaBlockerInventoryBinding `
                    -Inventory $inventoryProperty.Value `
                    -Description "$Description.gates.$($property.Name).blockerInventory"
            }
        }
        $binding.gates = $gateBinding
    }
    return [pscustomobject]$binding
}

function Assert-GaRawLogContentMatch {
    param(
        [Parameter(Mandatory = $true)][object]$Expected,
        [Parameter(Mandatory = $true)][object]$Actual,
        [Parameter(Mandatory = $true)][string]$IssueName,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $expectedBinding = Get-GaRawLogContentBinding -Content $Expected -IssueName $IssueName -Description "$Description.expected"
    $actualBinding = Get-GaRawLogContentBinding -Content $Actual -IssueName $IssueName -Description "$Description.actual"
    $expectedJson = $expectedBinding | ConvertTo-Json -Depth 10 -Compress
    $actualJson = $actualBinding | ConvertTo-Json -Depth 10 -Compress
    Assert-GaCondition ($expectedJson -ceq $actualJson) "$Description must match the parsed downloaded raw-log content"
}

function Get-GaYamlLines {
    param([Parameter(Mandatory = $true)][string]$Text)

    $lines = New-Object System.Collections.Generic.List[object]
    $rawLines = $Text -split '\r?\n'
    for ($index = 0; $index -lt $rawLines.Count; $index++) {
        $raw = [string]$rawLines[$index]
        if ($raw -match '^\s*$' -or $raw -match '^\s*#') {
            continue
        }
        Assert-GaCondition ($raw -notmatch "`t") "GA workflow line $($index + 1) must use spaces, not tabs"
        $indent = $raw.Length - $raw.TrimStart(' ').Length
        [void]$lines.Add([pscustomobject]@{
                Index = $index
                Indent = $indent
                Content = $raw.Substring($indent)
                Raw = $raw
            })
    }
    return $lines.ToArray()
}

function Get-GaYamlSection {
    param(
        [Parameter(Mandatory = $true)][object[]]$Lines,
        [Parameter(Mandatory = $true)][int]$Indent,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $headerPattern = '^' + [regex]::Escape($Key) + '\s*:\s*(?:#.*)?$'
    $headers = @($Lines | Where-Object {
            $_.Indent -eq $Indent -and $_.Content -match $headerPattern
        })
    Assert-GaCondition ($headers.Count -eq 1) "$Description must contain exactly one '${Key}:' mapping at indent $Indent (observed $($headers.Count))"
    $header = $headers[0]
    $next = @($Lines | Where-Object {
            $_.Index -gt $header.Index -and $_.Indent -le $Indent
        } | Select-Object -First 1)
    $endIndex = if ($next.Count -eq 0) { [int]::MaxValue } else { [int]$next[0].Index }
    return [pscustomobject]@{
        Header = $header
        Lines = @($Lines | Where-Object {
                $_.Index -gt $header.Index -and $_.Index -lt $endIndex
            })
        EndIndex = $endIndex
    }
}

function Assert-GaYamlScalar {
    param(
        [Parameter(Mandatory = $true)][object[]]$Lines,
        [Parameter(Mandatory = $true)][int]$Indent,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $pattern = '^' + [regex]::Escape($Key) + '\s*:\s*(?<value>.*?)\s*$'
    $matches = @()
    foreach ($line in $Lines) {
        if ($line.Indent -ne $Indent) {
            continue
        }
        $match = [regex]::Match($line.Content, $pattern)
        if ($match.Success) {
            $matches += [pscustomobject]@{ Value = [string]$match.Groups['value'].Value; Line = $line }
        }
    }
    Assert-GaCondition ($matches.Count -eq 1) "$Description must contain exactly one '${Key}:' scalar at indent $Indent (observed $($matches.Count))"
    Assert-GaCondition ($matches[0].Value.Equals($Expected, [System.StringComparison]::Ordinal)) "$Description.$Key must equal '$Expected' (observed '$($matches[0].Value)')"
}

function Assert-GaWorkflowSemanticContract {
    param([Parameter(Mandatory = $true)][string]$Workflow)

    $lines = @(Get-GaYamlLines -Text $Workflow)
    $on = Get-GaYamlSection -Lines $lines -Indent 0 -Key 'on' -Description 'GA workflow trigger'
    $triggerHeaders = @($on.Lines | Where-Object {
            $_.Indent -eq 2 -and $_.Content -match '^([A-Za-z0-9_-]+)\s*:'
        })
    Assert-GaCondition ($triggerHeaders.Count -eq 1 -and $triggerHeaders[0].Content -match '^workflow_dispatch\s*:') 'GA workflow must expose exactly one workflow_dispatch trigger'
    Assert-GaCondition (@($on.Lines | Where-Object {
                $_.Indent -eq 2 -and $_.Content -match '^push\s*:'
            }).Count -eq 0) 'GA workflow must not define a push trigger in any YAML form'

    $dispatch = Get-GaYamlSection -Lines $on.Lines -Indent 2 -Key 'workflow_dispatch' -Description 'GA workflow trigger'
    $inputs = Get-GaYamlSection -Lines $dispatch.Lines -Indent 4 -Key 'inputs' -Description 'GA workflow dispatch inputs'
    $expectedInputs = @(
        'source_tag',
        'evidence_url',
        'evidence_sha256',
        'stable_assets_url',
        'stable_assets_sha256',
        'attestation_signer_repo',
        'attestation_signer_workflow',
        'attestation_cert_identity',
        'attestation_signer_digest'
    )
    $inputHeaders = @($inputs.Lines | Where-Object {
            $_.Indent -eq 6 -and $_.Content -match '^([A-Za-z0-9_-]+)\s*:'
        })
    $actualInputs = @($inputHeaders | ForEach-Object {
            ([regex]::Match($_.Content, '^([A-Za-z0-9_-]+)\s*:')).Groups[1].Value
        })
    Assert-GaCondition ($actualInputs.Count -eq $expectedInputs.Count -and
        @($actualInputs | Where-Object { $_ -notin $expectedInputs }).Count -eq 0 -and
        @($expectedInputs | Where-Object { $_ -notin $actualInputs }).Count -eq 0) 'GA workflow dispatch inputs must exactly match the reviewed stable gate contract'
    foreach ($inputName in $expectedInputs) {
        $inputSection = Get-GaYamlSection -Lines $inputs.Lines -Indent 6 -Key $inputName -Description 'GA workflow dispatch inputs'
        Assert-GaYamlScalar -Lines $inputSection.Lines -Indent 8 -Key 'required' -Expected 'true' -Description "GA workflow input $inputName"
        Assert-GaYamlScalar -Lines $inputSection.Lines -Indent 8 -Key 'type' -Expected 'string' -Description "GA workflow input $inputName"
    }

    $jobs = Get-GaYamlSection -Lines $lines -Indent 0 -Key 'jobs' -Description 'GA workflow jobs'
    $jobHeaders = @($jobs.Lines | Where-Object {
            $_.Indent -eq 2 -and $_.Content -match '^([A-Za-z0-9_-]+)\s*:'
        })
    $jobNames = @($jobHeaders | ForEach-Object {
            ([regex]::Match($_.Content, '^([A-Za-z0-9_-]+)\s*:')).Groups[1].Value
        })
    Assert-GaCondition ($jobNames.Count -eq 2 -and $jobNames -contains 'ga-readiness' -and $jobNames -contains 'stable-publisher') 'GA workflow must contain exactly ga-readiness and stable-publisher jobs'

    $readiness = Get-GaYamlSection -Lines $jobs.Lines -Indent 2 -Key 'ga-readiness' -Description 'GA readiness job'
    Assert-GaYamlScalar -Lines $readiness.Lines -Indent 4 -Key 'runs-on' -Expected 'ubuntu-latest' -Description 'GA readiness job'
    Assert-GaYamlScalar -Lines $readiness.Lines -Indent 4 -Key 'environment' -Expected 'production' -Description 'GA readiness job'
    $readinessPermissions = Get-GaYamlSection -Lines $readiness.Lines -Indent 4 -Key 'permissions' -Description 'GA readiness job permissions'
    Assert-GaYamlScalar -Lines $readinessPermissions.Lines -Indent 6 -Key 'contents' -Expected 'read' -Description 'GA readiness job permissions'
    Assert-GaYamlScalar -Lines $readinessPermissions.Lines -Indent 6 -Key 'issues' -Expected 'read' -Description 'GA readiness job permissions'
    Assert-GaYamlScalar -Lines $readinessPermissions.Lines -Indent 6 -Key 'actions' -Expected 'read' -Description 'GA readiness job permissions'
    Assert-GaYamlScalar -Lines $readinessPermissions.Lines -Indent 6 -Key 'checks' -Expected 'read' -Description 'GA readiness job permissions'
    Assert-GaCondition (@($readinessPermissions.Lines | Where-Object { $_.Indent -eq 6 -and $_.Content -match '^([A-Za-z0-9_-]+)\s*:' }).Count -eq 4) 'GA readiness job permissions must not grant extra scopes'

    $publisher = Get-GaYamlSection -Lines $jobs.Lines -Indent 2 -Key 'stable-publisher' -Description 'stable publisher job'
    Assert-GaYamlScalar -Lines $publisher.Lines -Indent 4 -Key 'if' -Expected "needs.ga-readiness.result == 'success'" -Description 'stable publisher job'
    Assert-GaYamlScalar -Lines $publisher.Lines -Indent 4 -Key 'needs' -Expected '[ga-readiness]' -Description 'stable publisher job'
    Assert-GaYamlScalar -Lines $publisher.Lines -Indent 4 -Key 'runs-on' -Expected 'ubuntu-latest' -Description 'stable publisher job'
    Assert-GaYamlScalar -Lines $publisher.Lines -Indent 4 -Key 'environment' -Expected 'production' -Description 'stable publisher job'
    $publisherPermissions = Get-GaYamlSection -Lines $publisher.Lines -Indent 4 -Key 'permissions' -Description 'stable publisher job permissions'
    foreach ($permission in @(@('contents', 'write'), @('issues', 'read'), @('attestations', 'read'), @('actions', 'read'), @('checks', 'read'))) {
        Assert-GaYamlScalar -Lines $publisherPermissions.Lines -Indent 6 -Key $permission[0] -Expected $permission[1] -Description 'stable publisher job permissions'
    }
    Assert-GaCondition (@($publisherPermissions.Lines | Where-Object { $_.Indent -eq 6 -and $_.Content -match '^([A-Za-z0-9_-]+)\s*:' }).Count -eq 5) 'stable publisher job permissions must not grant extra scopes'

    $readinessText = ($readiness.Lines | ForEach-Object { $_.Raw }) -join "`n"
    $publisherText = ($publisher.Lines | ForEach-Object { $_.Raw }) -join "`n"
    Assert-GaCondition ($readinessText -notmatch '(?m)^\s*gh release create\b') 'GA readiness job must not publish a release'
    Assert-GaCondition ($publisherText -match 'gh release create[\s\S]+--verify-tag') 'stable publisher must create only the exact verified tag'
    Assert-GaCondition ($publisherText -match 'isPrerelease == false[\s\S]+isDraft == false') 'stable publisher must verify a public non-prerelease release after upload'
}

function Assert-GaWorkflowContract {
    param([string]$WorkflowText)

    $workflow = if ([string]::IsNullOrWhiteSpace($WorkflowText)) {
        Get-GaText -RelativePath '.github/workflows/ga.yml'
    } else {
        $WorkflowText
    }
    # Contract fixtures intentionally pass workflow text without copying every
    # repository helper.  Require the validator file for the real repository
    # contract, while keeping text-only negative fixtures focused on the
    # workflow mutation they are exercising.
    if ([string]::IsNullOrWhiteSpace($WorkflowText)) {
        $externalUrlValidatorPath = Join-Path $RepositoryRoot 'scripts/Test-ExternalHttpsUrl.py'
        Assert-GaCondition (Test-Path -LiteralPath $externalUrlValidatorPath -PathType Leaf) 'external HTTPS URL validator exists'
    }
    foreach ($needle in @(
        'workflow_dispatch:',
        'source_tag:',
        'evidence_url:',
        'evidence_sha256:',
        'stable_assets_url:',
        'stable_assets_sha256:',
        'attestation_signer_repo:',
        'attestation_signer_workflow:',
        'attestation_cert_identity:',
        'attestation_signer_digest:',
        'Test-GAReadiness.ps1',
        'Test-GARequiredChecks.ps1',
        'cyc.dev/ga-ci-runs/v1',
        'ci-run-pages.json',
        'ciSnapshotSha256',
        'LiveBlockerSnapshotPath',
        'cyc.dev/ga-open-issue-snapshot/v1',
        'open-issue-pages.json',
        '--paginate --slurp',
        'blockerSnapshotSha256',
        'Test-GARawLogs.ps1',
        'Test-StableAssetBundle.ps1',
        'stable-publisher:',
        'gh release create',
        'environment: production',
        'attestations: read',
        'CYC_GA_GOVERNANCE_TOKEN',
        'default_branch',
        '@uri',
        'branches/$encoded_branch',
        'branch-protection',
        'defaultBranch: $defaultBranch',
        'branchProtection: ($branch[0]',
        'protected',
        'protectionDetails',
        'protection.enabled',
        'allow_force_pushes',
        'allow_deletions',
        'enforce_admins',
        'prevent_self_review',
        'git cat-file -t',
        'refs/verify/tags/$CYC_GA_SOURCE_TAG',
        'git fetch --no-tags --force origin',
        'source_tag must resolve to an annotated tag',
        'CYC_GA_SOURCE_TAG_OBJECT',
        'resolve_remote_tag_identity',
        'Cross-bind GA evidence to the downloaded stable index',
        'gh attestation verify',
        'CYC_GA_ATTESTATION_SIGNER_REPO',
        'CYC_GA_ATTESTATION_SIGNER_WORKFLOW',
        'CYC_GA_ATTESTATION_CERT_IDENTITY',
        'CYC_GA_ATTESTATION_SIGNER_DIGEST',
        'CYC_GA_TRUSTED_BUILDER_REPO',
        'CYC_GA_TRUSTED_BUILDER_WORKFLOW',
        'CYC_GA_TRUSTED_BUILDER_DIGEST',
        'stable attestation signer must be a stable external builder',
        'stable attestation signer must be an external repository',
        '--signer-repo',
        '--signer-workflow',
        '--cert-identity',
        '--cert-oidc-issuer',
        '--deny-self-hosted-runners',
        '--source-digest',
        '--source-ref',
        'max_bundle_bytes',
        'max-filesize',
        'max_zip_entries',
        'max_entry_uncompressed_bytes',
        'max_total_uncompressed_bytes',
        'release-index.json.sig',
        'gh release download',
        'CYC_GA_FINAL_SNAPSHOT_SHA256',
        'valid_issue_evidence',
        '.issue2',
        '.issue3',
        '.issue5',
        'rawLog.url',
        'rawLog.sha256',
        'rawLog.command',
        'rawLog.node',
        'rawLog.startedAt',
        'rawLog.endedAt',
        'rawLog.exitCode',
        'rawLog.tests',
        'rawLog.cleanup',
        'cyc.dev/ga-raw-log/v1',
        'contentVerified',
        'valid_raw_content',
        'integer_count',
        '1000000000',
        'readinessDirectory = Join-Path',
        'resultLines = @(& ./scripts/Test-GAReadiness.ps1',
        'signedNMinus1ToNUpgrade',
        'interruptedUpgradeRollback',
        'downgradePolicy',
        'noOpenUnwaivedP0P1Blocker',
        'liveLinuxControllerWorkerRoundTrip',
        'macosDeveloperIdSigningNotarization',
        '--connect-timeout 20',
        '--max-time 300',
        '--max-filesize 67108864',
        'tauriDesktopHostTray',
        'linuxSystemdUserServicePackage',
        'linuxDedicatedExecutionIdentity'
        'Test-ExternalHttpsUrl.py'
        '--max-redirs 0'
    )) {
        Assert-GaCondition $workflow.Contains($needle) "GA workflow contains '$needle'"
    }
    Assert-GaCondition ($workflow -notmatch '(?m)^\s*push:\s*$') 'GA workflow is manually dispatched and does not auto-publish from a tag push'
    Assert-GaCondition ($workflow -notmatch '(?m)^\s*runs-on:\s*(?:macos|windows)[^\r\n]*$') 'GA workflow does not use macOS/Windows hosted runners as live acceptance evidence'
    Assert-GaCondition ($workflow -notmatch '(?i)macos-latest|windows-latest|windows-11-arm|softprops/action-gh-release') 'GA workflow does not turn hosted smoke or a prerelease publisher into GA evidence'
    Assert-GaCondition ($workflow -match '(?m)^\s*required:\s*true\s*$') 'GA workflow has required manual inputs'
    Assert-GaCondition ($workflow -match 'gh release create[\s\S]+--verify-tag') 'GA workflow contains a protected stable publisher with exact-tag verification'
    Assert-GaCondition ($workflow -match 'isPrerelease == false[\s\S]+isDraft == false') 'GA workflow verifies the published release is stable and public'
    Assert-GaWorkflowSemanticContract -Workflow $workflow
}

function Assert-GaIssueSnapshot {
    param([Parameter(Mandatory = $true)][object]$Snapshot)

    $nodes = @()
    $issuesProperty = $Snapshot.PSObject.Properties['issues']
    if ($null -ne $issuesProperty) {
        $nodes = @($issuesProperty.Value)
    } elseif ($Snapshot -is [System.Array]) {
        $nodes = @($Snapshot)
    } else {
        $nodes = @($Snapshot)
    }

    $expectedTitles = @{
        2 = 'Windows one-click installer and desktop host'
        3 = 'Heterogeneous Linux and macOS worker packages'
        5 = 'Opt-in hostile-workload isolation and external process reconciliation'
    }
    foreach ($number in @(2, 3, 5)) {
        $matches = @($nodes | Where-Object { [string]$_.number -ceq [string]$number })
        Assert-GaCondition ($matches.Count -eq 1) "live issue snapshot contains exactly one issue #$number"
        $issue = $matches[0]
        Assert-GaCondition ($null -eq $issue.PSObject.Properties['pull_request']) "issue #$number snapshot entry must be an issue, not a pull request"
        $state = [string](Get-GaProperty -Object $issue -Path 'state' -Description "issue #$number")
        Assert-GaCondition ($state.Equals('closed', [System.StringComparison]::OrdinalIgnoreCase)) "issue #$number must be closed before GA (observed '$state')"
        $stateReason = [string](Get-GaProperty -Object $issue -Path 'state_reason' -Description "issue #$number")
        Assert-GaCondition ($stateReason.Equals('completed', [System.StringComparison]::OrdinalIgnoreCase)) "issue #$number must be closed with state_reason=completed before GA (observed '$stateReason')"
        $title = [string](Get-GaProperty -Object $issue -Path 'title' -Description "issue #$number")
        Assert-GaCondition ($title.Equals([string]$expectedTitles[$number], [System.StringComparison]::Ordinal)) "issue #$number title does not match the canonical acceptance issue"
        $htmlUrl = [string](Get-GaProperty -Object $issue -Path 'html_url' -Description "issue #$number")
        $expectedUrl = "https://github.com/TypeThe0ry/ClusterYourCodex/issues/$number"
        Assert-GaCondition ($htmlUrl.Equals($expectedUrl, [System.StringComparison]::OrdinalIgnoreCase)) "issue #$number html_url is not the canonical repository issue URL"
    }
}

function Assert-GaControlsSnapshot {
    param([Parameter(Mandatory = $true)][object]$Controls)

    $defaultBranch = [string](Get-GaProperty -Object $Controls -Path 'defaultBranch' -Description 'repository metadata')
    Assert-GaCondition (-not [string]::IsNullOrWhiteSpace($defaultBranch)) 'repository metadata defaultBranch must be present'
    $branchProtection = Get-GaProperty -Object $Controls -Path 'branchProtection' -Description 'repository branch protection'
    $branchName = [string](Get-GaProperty -Object $branchProtection -Path 'name' -Description 'repository branch protection')
    Assert-GaCondition ($branchName.Equals($defaultBranch, [System.StringComparison]::Ordinal)) 'branch protection snapshot must describe the repository default branch'
    $protected = Get-GaProperty -Object $branchProtection -Path 'protected' -Description 'repository branch protection'
    Assert-GaCondition (($protected -is [bool]) -and $protected) 'the default branch must be protected before GA'
    $protectionApiError = $branchProtection.PSObject.Properties['apiError']
    if ($null -ne $protectionApiError) {
        Assert-GaCondition (-not [bool]$protectionApiError.Value) 'branch protection API snapshot must not contain an error'
    }
    $protectionEnabled = Get-GaProperty -Object $branchProtection -Path 'protection.enabled' -Description 'repository branch protection'
    Assert-GaCondition (($protectionEnabled -is [bool]) -and $protectionEnabled) 'the default branch protection payload must be enabled before GA'
    $protectionDetails = Get-GaProperty -Object $branchProtection -Path 'protectionDetails' -Description 'repository branch protection'
    $protectionDetailsApiError = $protectionDetails.PSObject.Properties['apiError']
    if ($null -ne $protectionDetailsApiError) {
        Assert-GaCondition (-not [bool]$protectionDetailsApiError.Value) 'branch protection details API snapshot must not contain an error'
    }
    $allowForcePushes = Get-GaProperty -Object $protectionDetails -Path 'allow_force_pushes.enabled' -Description 'repository branch protection'
    Assert-GaCondition (($allowForcePushes -is [bool]) -and -not $allowForcePushes) 'the default branch must prohibit force pushes before GA'
    $allowDeletions = Get-GaProperty -Object $protectionDetails -Path 'allow_deletions.enabled' -Description 'repository branch protection'
    Assert-GaCondition (($allowDeletions -is [bool]) -and -not $allowDeletions) 'the default branch must prohibit deletions before GA'
    $enforceAdmins = Get-GaProperty -Object $protectionDetails -Path 'enforce_admins.enabled' -Description 'repository branch protection'
    Assert-GaCondition (($enforceAdmins -is [bool]) -and $enforceAdmins) 'the default branch must enforce protection for administrators before GA'

    $environment = Get-GaProperty -Object $Controls -Path 'productionEnvironment' -Description 'production environment'
    $environmentName = [string](Get-GaProperty -Object $environment -Path 'name' -Description 'production environment')
    Assert-GaCondition ($environmentName.Equals('production', [System.StringComparison]::Ordinal)) "the GA environment must be named 'production' (observed '$environmentName')"
    $canAdminsBypass = Get-GaProperty -Object $environment -Path 'can_admins_bypass' -Description 'production environment'
    Assert-GaCondition (($canAdminsBypass -is [bool]) -and -not $canAdminsBypass) 'production environment administrator bypass must be disabled'

    $rules = @(Get-GaProperty -Object $environment -Path 'protection_rules' -Description 'production environment')
    Assert-GaCondition ($rules.Count -gt 0) 'production environment must have protection rules'
    $reviewerRules = @($rules | Where-Object { [string]$_.type -ceq 'required_reviewers' })
    Assert-GaCondition ($reviewerRules.Count -eq 1) 'production environment must have exactly one required_reviewers rule'
    $reviewerRule = $reviewerRules[0]
    $reviewersProperty = $reviewerRule.PSObject.Properties['reviewers']
    $reviewersValue = $null
    if ($null -ne $reviewersProperty) {
        $reviewersValue = $reviewersProperty.Value
    }
    $reviewerCount = 0
    $hasNullReviewer = $false
    if ($null -ne $reviewersValue) {
        if ($reviewersValue -is [System.Array]) {
            $reviewerCount = $reviewersValue.Length
            $hasNullReviewer = $reviewersValue -contains $null
        } else {
            $reviewerCount = 1
        }
    }
    Assert-GaCondition ($null -ne $reviewersProperty -and $reviewersValue -is [System.Array] -and $reviewerCount -gt 0 -and -not $hasNullReviewer) 'production environment required_reviewers rule must contain a non-empty reviewer list'
    foreach ($reviewer in @($reviewersValue)) {
        Assert-GaCondition (($reviewer -is [pscustomobject]) -and -not ($reviewer -is [System.Array])) 'production environment reviewer entries must be JSON objects'
        $reviewerTypeProperty = $reviewer.PSObject.Properties['type']
        $reviewerType = if ($null -ne $reviewerTypeProperty) { [string]$reviewerTypeProperty.Value } else { '' }
        $validReviewerType = $reviewerType.Equals('User', [System.StringComparison]::OrdinalIgnoreCase) -or
            $reviewerType.Equals('Team', [System.StringComparison]::OrdinalIgnoreCase)
        Assert-GaCondition (($null -ne $reviewerTypeProperty) -and $validReviewerType) 'production environment reviewer entries must identify a User or Team'
        $identityProperty = $reviewer.PSObject.Properties['reviewer']
        Assert-GaCondition ($null -ne $identityProperty -and $identityProperty.Value -is [pscustomobject] -and -not ($identityProperty.Value -is [System.Array])) 'production environment reviewer entries must contain a reviewer identity object'
        $identity = $identityProperty.Value
        $idProperty = $identity.PSObject.Properties['id']
        $idValid = $false
        if ($null -ne $idProperty) {
            $idValid = (($idProperty.Value -is [int] -or $idProperty.Value -is [long]) -and [long]$idProperty.Value -gt 0)
        }
        $loginProperty = $identity.PSObject.Properties['login']
        $nameProperty = $identity.PSObject.Properties['name']
        $loginValid = ($null -ne $loginProperty -and -not [string]::IsNullOrWhiteSpace([string]$loginProperty.Value))
        $nameValid = ($null -ne $nameProperty -and -not [string]::IsNullOrWhiteSpace([string]$nameProperty.Value))
        Assert-GaCondition ($idValid -or $loginValid -or $nameValid) 'production environment reviewer identity must contain a positive id, login, or name'
    }
    $preventSelfReviewProperty = $reviewerRule.PSObject.Properties['prevent_self_review']
    Assert-GaCondition ($null -ne $preventSelfReviewProperty -and $preventSelfReviewProperty.Value -is [bool] -and [bool]$preventSelfReviewProperty.Value) 'production environment required_reviewers rule must prevent self-review'
    $waitRules = @($rules | Where-Object { [string]$_.type -ceq 'wait_timer' })
    Assert-GaCondition ($waitRules.Count -gt 0) 'production environment must have a wait timer'
    $waitTimerProperty = $waitRules[0].PSObject.Properties['wait_timer']
    Assert-GaCondition ($null -ne $waitTimerProperty -and ($waitTimerProperty.Value -is [int] -or $waitTimerProperty.Value -is [long]) -and [long]$waitTimerProperty.Value -gt 0) 'production environment wait_timer must be a positive number of minutes'

    $policies = @(Get-GaProperty -Object $Controls -Path 'deploymentBranchPolicies.branch_policies' -Description 'production deployment branch policy')
    $tagPolicies = @($policies | Where-Object { [string]$_.type -ceq 'tag' -and [string]$_.name -ceq 'v*' })
    Assert-GaCondition ($tagPolicies.Count -eq 1 -and $policies.Count -eq 1) "production environment must allow exactly the configured v* tag policy"
}

Assert-GaWorkflowContract
$checks = New-Object System.Collections.Generic.List[object]
[void]$checks.Add([ordered]@{
    name = 'workflow-contract'
    status = 'passed'
    message = 'manual stable gate requires external evidence and routes publication through the protected stable publisher'
})

if ($ContractOnly) {
    $result = [ordered]@{
        schemaVersion = 'cyc.dev/ga-readiness/v1'
        status = 'contract-only'
        checks = $checks.ToArray()
    }
} else {
    Assert-GaCondition ($ExpectedTag -match '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') "ExpectedTag must be a stable SemVer tag (observed '$ExpectedTag')"
    Assert-GaCondition ($ExpectedCommit -match '^[0-9a-fA-F]{40}$') 'ExpectedCommit must be a full 40-character commit SHA'
    Assert-GaCondition (-not [string]::IsNullOrWhiteSpace($EvidencePath)) 'EvidencePath is required'
    Assert-GaCondition (-not [string]::IsNullOrWhiteSpace($RawLogVerificationPath)) 'RawLogVerificationPath is required'
    Assert-GaCondition (-not [string]::IsNullOrWhiteSpace($IssueSnapshotPath)) 'IssueSnapshotPath is required'
    Assert-GaCondition (-not [string]::IsNullOrWhiteSpace($LiveBlockerSnapshotPath)) 'LiveBlockerSnapshotPath is required'
    Assert-GaCondition (-not [string]::IsNullOrWhiteSpace($ControlsPath)) 'ControlsPath is required'

    $versionCheckPath = Join-Path $RepositoryRoot 'scripts/Test-VersionConsistency.ps1'
    Assert-GaCondition (Test-Path -LiteralPath $versionCheckPath -PathType Leaf) 'version consistency gate exists'
    $versionOutput = @(& $versionCheckPath -RepositoryRoot $RepositoryRoot -SourceTag $ExpectedTag -SkipNegativeTests -Json)
    $versionExitCode = $LASTEXITCODE
    Assert-GaCondition ($versionExitCode -eq 0) "version consistency gate exited with code $versionExitCode"
    $versionResult = $versionOutput -join "`n" | ConvertFrom-Json
    [void](Assert-GaString -Object $versionResult -Path 'releaseChannel' -Expected 'stable' -Description 'stable version identity')
    [void](Assert-GaString -Object $versionResult -Path 'productVersion' -Expected $ExpectedTag.Substring(1) -Description 'stable version identity')
    [void]$checks.Add([ordered]@{
        name = 'stable-version-identity'
        status = 'passed'
        message = "VERSION and product surfaces match $ExpectedTag"
    })

    $evidence = Get-GaJson -Path $EvidencePath -Description 'external GA evidence manifest'
    [void](Assert-GaString -Object $evidence -Path 'schemaVersion' -Expected 'cyc.dev/ga-evidence/v1' -Description 'external GA evidence manifest')
    [void](Assert-GaString -Object $evidence -Path 'status' -Expected 'passed' -Description 'external GA evidence manifest')
    [void](Assert-GaString -Object $evidence -Path 'productVersion' -Expected $ExpectedTag.Substring(1) -Description 'external GA evidence manifest')
    [void](Assert-GaString -Object $evidence -Path 'sourceTag' -Expected $ExpectedTag -Description 'external GA evidence manifest')
    $evidenceCommit = [string](Get-GaProperty -Object $evidence -Path 'sourceCommit' -Description 'external GA evidence manifest')
    Assert-GaCondition ($evidenceCommit.Equals($ExpectedCommit, [System.StringComparison]::OrdinalIgnoreCase)) 'external GA evidence sourceCommit matches the reviewed stable source commit'
    Assert-GaEvidenceHostRecordSet -Evidence $evidence -ExpectedCommit $ExpectedCommit

    $rawVerification = Get-GaJson -Path $RawLogVerificationPath -Description 'downloaded GA raw-log verification'
    [void](Assert-GaString -Object $rawVerification -Path 'schemaVersion' -Expected 'cyc.dev/ga-raw-log-verification/v1' -Description 'downloaded GA raw-log verification')
    [void](Assert-GaString -Object $rawVerification -Path 'status' -Expected 'passed' -Description 'downloaded GA raw-log verification')
    $verificationCommit = [string](Get-GaProperty -Object $rawVerification -Path 'sourceCommit' -Description 'downloaded GA raw-log verification')
    Assert-GaCondition ($verificationCommit.Equals($ExpectedCommit, [System.StringComparison]::OrdinalIgnoreCase)) 'downloaded GA raw-log verification sourceCommit matches the reviewed stable source commit'
    $rawRecords = @(Get-GaProperty -Object $rawVerification -Path 'records' -Description 'downloaded GA raw-log verification')
    Assert-GaCondition ($rawRecords.Count -eq 3) 'downloaded GA raw-log verification must contain exactly three issue records'
    $seenRawIssues = @{}
    $seenRawIds = @{}
    $rawVerificationItem = Get-Item -LiteralPath $RawLogVerificationPath -Force -ErrorAction Stop
    Assert-GaCondition (($rawVerificationItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0 -and -not $rawVerificationItem.PSIsContainer) 'downloaded GA raw-log verification must be a regular file'
    $rawVerificationRoot = $rawVerificationItem.Directory.FullName
    $rawVerificationRootPrefix = $rawVerificationRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    foreach ($rawRecord in $rawRecords) {
        $issueName = [string](Get-GaProperty -Object $rawRecord -Path 'issue' -Description 'downloaded GA raw-log verification record')
        Assert-GaCondition ($issueName -in @('issue2', 'issue3', 'issue5')) "downloaded GA raw-log verification has an allowed issue name: $issueName"
        Assert-GaCondition (-not $seenRawIssues.ContainsKey($issueName)) "downloaded GA raw-log verification issue names are unique: $issueName"
        $seenRawIssues[$issueName] = $true
        $rawId = [string](Get-GaProperty -Object $rawRecord -Path 'evidenceId' -Description 'downloaded GA raw-log verification record')
        Assert-GaCondition (-not $seenRawIds.ContainsKey($rawId)) "downloaded GA raw-log verification evidence IDs are unique: $rawId"
        $seenRawIds[$rawId] = $true
        $manifestIssue = Get-GaProperty -Object $evidence -Path $issueName -Description 'external GA evidence manifest'
        $manifestId = [string](Get-GaProperty -Object $manifestIssue -Path 'evidenceId' -Description "external GA evidence manifest $issueName")
        Assert-GaCondition ($rawId.Equals($manifestId, [System.StringComparison]::Ordinal)) "downloaded GA raw-log evidenceId matches $issueName"
        [void](Assert-GaString -Object $rawRecord -Path 'status' -Expected 'passed' -Description 'downloaded GA raw-log verification record')
        $rawUrl = [string](Get-GaProperty -Object $rawRecord -Path 'url' -Description 'downloaded GA raw-log verification record')
        $manifestRawLog = Get-GaProperty -Object $manifestIssue -Path 'rawLog' -Description "external GA evidence manifest $issueName"
        $manifestUrl = [string](Get-GaProperty -Object $manifestRawLog -Path 'url' -Description "external GA evidence manifest $issueName")
        Assert-GaCondition ($rawUrl.Equals($manifestUrl, [System.StringComparison]::Ordinal)) "downloaded raw-log URL matches $issueName"
        $expectedRawHash = [string](Get-GaProperty -Object $rawRecord -Path 'expectedSha256' -Description 'downloaded GA raw-log verification record')
        $actualRawHash = [string](Get-GaProperty -Object $rawRecord -Path 'actualSha256' -Description 'downloaded GA raw-log verification record')
        Assert-GaCondition ($expectedRawHash -match '^[0-9a-fA-F]{64}$' -and $actualRawHash -match '^[0-9a-fA-F]{64}$' -and $expectedRawHash.Equals($actualRawHash, [System.StringComparison]::OrdinalIgnoreCase)) 'downloaded GA raw-log verification digest matches'
        $manifestRawHash = [string](Get-GaProperty -Object $manifestRawLog -Path 'sha256' -Description "external GA evidence manifest $issueName")
        Assert-GaCondition ($expectedRawHash.Equals($manifestRawHash, [System.StringComparison]::OrdinalIgnoreCase)) "downloaded raw-log digest matches $issueName"
        $rawBytes = Get-GaProperty -Object $rawRecord -Path 'bytes' -Description 'downloaded GA raw-log verification record'
        Assert-GaCondition (($rawBytes -is [int] -or $rawBytes -is [long]) -and [long]$rawBytes -ge 0) 'downloaded GA raw-log byte count must be a non-negative integer'
        $rawPath = [string](Get-GaProperty -Object $rawRecord -Path 'path' -Description 'downloaded GA raw-log verification record')
        $rawFullPath = [IO.Path]::GetFullPath($rawPath)
        Assert-GaCondition ($rawFullPath.StartsWith($rawVerificationRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) 'downloaded GA raw-log path must remain under its verification directory'
        $rawItem = Get-Item -LiteralPath $rawFullPath -Force -ErrorAction Stop
        Assert-GaCondition (($rawItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0 -and -not $rawItem.PSIsContainer) 'downloaded GA raw-log verification path is a regular file'
        Assert-GaCondition ([long]$rawItem.Length -eq [long]$rawBytes) 'downloaded GA raw-log byte count matches the retained file'
        $recomputedRawHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $rawFullPath).Hash
        Assert-GaCondition ($recomputedRawHash.Equals($actualRawHash, [System.StringComparison]::OrdinalIgnoreCase)) 'downloaded GA raw-log file hash matches the verification record'
        $contentVerified = Get-GaProperty -Object $rawRecord -Path 'contentVerified' -Description 'downloaded GA raw-log verification record'
        Assert-GaCondition (($contentVerified -is [bool]) -and $contentVerified) "$issueName downloaded raw-log contentVerified must be boolean true"
        $reportedContent = Get-GaProperty -Object $rawRecord -Path 'content' -Description 'downloaded GA raw-log verification record'
        Assert-GaCondition ($null -ne $reportedContent -and ($reportedContent -is [pscustomobject]) -and -not ($reportedContent -is [System.Array])) "$issueName downloaded raw-log content must be a JSON object"
        $downloadedContent = Get-GaRawLogContentJson -Path $rawFullPath -Description "$issueName downloaded raw-log content"
        [void](Assert-GaRawLogContent `
            -Content $downloadedContent `
            -ManifestIssue $manifestIssue `
            -IssueName $issueName `
            -ExpectedCommit $ExpectedCommit `
            -EvidenceId $manifestId `
            -Description "$issueName downloaded raw-log content" `
            -RequirePositivePassed $true)
        [void](Assert-GaRawLogContent `
            -Content $reportedContent `
            -ManifestIssue $manifestIssue `
            -IssueName $issueName `
            -ExpectedCommit $ExpectedCommit `
            -EvidenceId $manifestId `
            -Description "$issueName reported raw-log content" `
            -RequirePositivePassed $true)
        Assert-GaRawLogContentMatch `
            -Expected $downloadedContent `
            -Actual $reportedContent `
            -IssueName $issueName `
            -Description "$issueName raw-log content binding"
        if ($issueName -ceq 'issue5') {
            Assert-GaIssue5RawVerification -ManifestIssue $manifestIssue -RawRecord $rawRecord -Description 'downloaded GA raw-log verification issue5'
        } elseif ($issueName -ceq 'issue2' -or $issueName -ceq 'issue3') {
            [void](Assert-GaIssue23RawVerification `
                -ManifestIssue $manifestIssue `
                -RawRecord $rawRecord `
                -IssueName $issueName `
                -ExpectedCommit $ExpectedCommit `
                -Description "downloaded GA raw-log verification $issueName")
        }
    }
    Assert-GaCondition ($seenRawIssues.Count -eq 3) 'downloaded GA raw-log verification covers issue2, issue3, and issue5'
    [void](Assert-GaExternalEvidence -Evidence $evidence -Path 'windowsCleanVm' -Description 'Windows clean VM acceptance' -ExpectedCommit $ExpectedCommit)
    [void](Assert-GaExternalEvidence -Evidence $evidence -Path 'macosLaunchAgent' -Description 'macOS LaunchAgent acceptance' -ExpectedCommit $ExpectedCommit)
    [void](Assert-GaExternalEvidence -Evidence $evidence -Path 'windowsAuthenticode' -Description 'Windows Authenticode acceptance' -ExpectedCommit $ExpectedCommit)
    Assert-GaTrue -Object $evidence -Path 'windowsCleanVm.cleanHost' -Description 'Windows clean VM acceptance'
    Assert-GaTrue -Object $evidence -Path 'windowsCleanVm.profileMatrix' -Description 'Windows clean VM acceptance'
    Assert-GaTrue -Object $evidence -Path 'windowsCleanVm.installRepairUpgradeRollbackUninstall' -Description 'Windows clean VM acceptance'
    Assert-GaTrue -Object $evidence -Path 'macosLaunchAgent.launchAgentLifecycle' -Description 'macOS LaunchAgent acceptance'
    Assert-GaTrue -Object $evidence -Path 'macosLaunchAgent.controllerRoundTrip' -Description 'macOS LaunchAgent acceptance'
    Assert-GaTrue -Object $evidence -Path 'macosLaunchAgent.nativeHost' -Description 'macOS LaunchAgent acceptance'
    Assert-GaTrue -Object $evidence -Path 'windowsAuthenticode.setupSigned' -Description 'Windows Authenticode acceptance'
    Assert-GaTrue -Object $evidence -Path 'windowsAuthenticode.helperSigned' -Description 'Windows Authenticode acceptance'
    Assert-GaTrue -Object $evidence -Path 'windowsAuthenticode.timestamped' -Description 'Windows Authenticode acceptance'
    [void](Assert-GaString -Object $evidence -Path 'artifactVerification.status' -Expected 'passed' -Description 'independent post-download artifact verification')
    Assert-GaTrue -Object $evidence -Path 'artifactVerification.downloadedAfterBuild' -Description 'independent post-download artifact verification'
    Assert-GaTrue -Object $evidence -Path 'artifactVerification.sidecarsVerified' -Description 'independent post-download artifact verification'
    Assert-GaTrue -Object $evidence -Path 'artifactVerification.indexVerified' -Description 'independent post-download artifact verification'
    Assert-GaTrue -Object $evidence -Path 'artifactVerification.provenanceVerified' -Description 'independent post-download artifact verification'
    $indexSha = [string](Get-GaProperty -Object $evidence -Path 'artifactVerification.indexSha256' -Description 'independent post-download artifact verification')
    Assert-GaCondition ($indexSha -match '^[0-9a-fA-F]{64}$') 'independent post-download artifact verification indexSha256 must be a SHA-256 digest'
    [void]$checks.Add([ordered]@{
        name = 'external-evidence'
        status = 'passed'
        message = 'Windows clean VM, macOS LaunchAgent, Authenticode, and independent artifact evidence are retained and source-bound'
    })

    $issue2Evidence = Assert-GaIssueEvidence -Evidence $evidence -Path 'issue2' -Description 'Issue #2 Windows installer and desktop-host evidence' -ExpectedCommit $ExpectedCommit -RequiredGates $GaIssue2GateNames
    [void]$checks.Add([ordered]@{
        name = 'issue-2-evidence'
        status = 'passed'
        message = 'Issue #2 evidence is source-bound, externally retained, and every acceptance gate is true'
    })
    [void](Assert-GaIssueEvidence -Evidence $evidence -Path 'issue3' -Description 'Issue #3 heterogeneous worker-package evidence' -ExpectedCommit $ExpectedCommit -RequiredGates $GaIssue3GateNames)
    [void]$checks.Add([ordered]@{
        name = 'issue-3-evidence'
        status = 'passed'
        message = 'Issue #3 evidence is source-bound, externally retained, and every acceptance gate is true'
    })
    [void](Assert-GaIssueEvidence -Evidence $evidence -Path 'issue5' -Description 'Issue #5 hostile-workload isolation evidence' -ExpectedCommit $ExpectedCommit -RequiredGates $GaIssue5GateNames)
    [void]$checks.Add([ordered]@{
        name = 'issue-5-evidence'
        status = 'passed'
        message = 'Issue #5 evidence is source-bound, externally retained, and every platform-matrix gate has verified proof'
    })

    $issues = Get-GaJson -Path $IssueSnapshotPath -Description 'live issue snapshot'
    Assert-GaIssueSnapshot -Snapshot $issues
    [void]$checks.Add([ordered]@{
        name = 'issue-gates'
        status = 'passed'
        message = 'Issues #2, #3, and #5 are closed in the live repository snapshot'
    })

    $liveBlockerSnapshot = Get-GaJson -Path $LiveBlockerSnapshotPath -Description 'live open-issue blocker snapshot'
    $blockerCheck = Assert-GaLiveBlockerInventory `
        -Inventory (Get-GaProperty -Object (Get-GaProperty -Object $issue2Evidence -Path 'gates' -Description 'Issue #2 evidence') -Path 'noOpenUnwaivedP0P1Blocker' -Description 'Issue #2 blocker gate').blockerInventory `
        -LiveSnapshot $liveBlockerSnapshot `
        -ExpectedCommit $ExpectedCommit `
        -Description 'Issue #2 blocker inventory live binding'
    [void]$checks.Add([ordered]@{
        name = 'blocker-inventory-live-binding'
        status = 'passed'
        message = "Issue #2 blocker inventory matches the complete live open-issue snapshot (count=$($blockerCheck.issueCount), maxAgeHours=$($blockerCheck.maxAgeHours))"
    })

    $controls = Get-GaJson -Path $ControlsPath -Description 'live GitHub governance snapshot'
    Assert-GaControlsSnapshot -Controls $controls
    [void]$checks.Add([ordered]@{
        name = 'governance-controls'
        status = 'passed'
        message = 'branch protection, production review/wait rules, administrator bypass, and v* tag policy are verified'
    })

    $result = [ordered]@{
        schemaVersion = 'cyc.dev/ga-readiness/v1'
        status = 'passed'
        sourceTag = $ExpectedTag
        sourceCommit = $ExpectedCommit.ToLowerInvariant()
        productVersion = $ExpectedTag.Substring(1)
        checks = $checks.ToArray()
    }
}

if ($Json) {
    $result | ConvertTo-Json -Depth 10 -Compress
} else {
    $result
}
