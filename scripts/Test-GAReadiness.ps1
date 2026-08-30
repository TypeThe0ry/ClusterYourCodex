#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepositoryRoot,

    [string]$ExpectedTag,

    [string]$ExpectedCommit,

    [string]$EvidencePath,

    [string]$RawLogVerificationPath,

    [string]$IssueSnapshotPath,

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
    Assert-GaCondition (($exitCode -is [int] -or $exitCode -is [long]) -and [long]$exitCode -eq 0) "$Description.rawLog.exitCode must be integer 0 (observed '$exitCode')"
    $tests = Get-GaProperty -Object $rawLog -Path 'tests' -Description $Description
    Assert-GaCondition (($tests -is [pscustomobject]) -and -not ($tests -is [System.Array])) "$Description.rawLog.tests must be a JSON object"
    foreach ($field in @('passed', 'failed', 'ignored')) {
        $count = Get-GaProperty -Object $tests -Path $field -Description "$Description.rawLog.tests"
        Assert-GaCondition (($count -is [int] -or $count -is [long]) -and [long]$count -ge 0) "$Description.rawLog.tests.$field must be a non-negative integer"
    }
    Assert-GaCondition ([long]$tests.failed -eq 0) "$Description.rawLog.tests.failed must be zero"
    $cleanup = Get-GaProperty -Object $rawLog -Path 'cleanup' -Description $Description
    Assert-GaCondition (($cleanup -is [bool]) -and $cleanup) "$Description.rawLog.cleanup must be boolean true"

    $gates = Get-GaProperty -Object $node -Path 'gates' -Description $Description
    Assert-GaCondition (($gates -is [pscustomobject]) -and -not ($gates -is [System.Array])) "$Description.gates must be a JSON object"
    foreach ($gate in $RequiredGates) {
        Assert-GaTrue -Object $node -Path "gates.$gate" -Description $Description
    }
    return $node
}

function Assert-GaWorkflowContract {
    $workflow = Get-GaText -RelativePath '.github/workflows/ga.yml'
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
    )) {
        Assert-GaCondition $workflow.Contains($needle) "GA workflow contains '$needle'"
    }
    Assert-GaCondition ($workflow -notmatch '(?m)^\s*push:\s*$') 'GA workflow is manually dispatched and does not auto-publish from a tag push'
    Assert-GaCondition ($workflow -notmatch '(?m)^\s*runs-on:\s*(?:macos|windows)[^\r\n]*$') 'GA workflow does not use macOS/Windows hosted runners as live acceptance evidence'
    Assert-GaCondition ($workflow -notmatch '(?i)macos-latest|windows-latest|windows-11-arm|softprops/action-gh-release') 'GA workflow does not turn hosted smoke or a prerelease publisher into GA evidence'
    Assert-GaCondition ($workflow -match '(?m)^\s*required:\s*true\s*$') 'GA workflow has required manual inputs'
    Assert-GaCondition ($workflow -match 'gh release create[\s\S]+--verify-tag') 'GA workflow contains a protected stable publisher with exact-tag verification'
    Assert-GaCondition ($workflow -match 'isPrerelease == false[\s\S]+isDraft == false') 'GA workflow verifies the published release is stable and public'
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
    Assert-GaCondition (-not [string]::IsNullOrWhiteSpace($ControlsPath)) 'ControlsPath is required'

    $versionCheckPath = Join-Path $RepositoryRoot 'scripts/Test-VersionConsistency.ps1'
    Assert-GaCondition (Test-Path -LiteralPath $versionCheckPath -PathType Leaf) 'version consistency gate exists'
    $versionOutput = @(& $versionCheckPath -RepositoryRoot $RepositoryRoot -SourceTag $ExpectedTag -SkipNegativeTests -Json)
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

    [void](Assert-GaIssueEvidence -Evidence $evidence -Path 'issue2' -Description 'Issue #2 Windows installer and desktop-host evidence' -ExpectedCommit $ExpectedCommit -RequiredGates $GaIssue2GateNames)
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
        message = 'Issue #5 evidence is source-bound, externally retained, and every acceptance gate is true'
    })

    $issues = Get-GaJson -Path $IssueSnapshotPath -Description 'live issue snapshot'
    Assert-GaIssueSnapshot -Snapshot $issues
    [void]$checks.Add([ordered]@{
        name = 'issue-gates'
        status = 'passed'
        message = 'Issues #2, #3, and #5 are closed in the live repository snapshot'
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
