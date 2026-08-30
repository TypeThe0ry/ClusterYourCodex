#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepositoryRoot,

    [string]$ExpectedTag,

    [string]$ExpectedCommit,

    [string]$EvidencePath,

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
    Assert-GaString -Object $node -Path 'status' -Expected 'passed' -Description $Description
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

function Assert-GaWorkflowContract {
    $workflow = Get-GaText -RelativePath '.github/workflows/ga.yml'
    foreach ($needle in @(
        'workflow_dispatch:',
        'source_tag:',
        'evidence_url:',
        'evidence_sha256:',
        'Test-GAReadiness.ps1',
        'environment: production'
    )) {
        Assert-GaCondition $workflow.Contains($needle) "GA workflow contains '$needle'"
    }
    Assert-GaCondition ($workflow -notmatch '(?m)^\s*push:\s*$') 'GA workflow is manually dispatched and does not auto-publish from a tag push'
    Assert-GaCondition ($workflow -notmatch '(?m)^\s*runs-on:\s*(?:macos|windows)[^\r\n]*$') 'GA workflow does not use macOS/Windows hosted runners as live acceptance evidence'
    Assert-GaCondition ($workflow -notmatch '(?i)macos-latest|windows-latest|windows-11-arm|softprops/action-gh-release') 'GA workflow does not turn hosted smoke or a prerelease publisher into GA evidence'
    Assert-GaCondition ($workflow -match '(?m)^\s*required:\s*true\s*$') 'GA workflow has required manual inputs'
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

    foreach ($number in @(2, 3, 5)) {
        $matches = @($nodes | Where-Object { [string]$_.number -ceq [string]$number })
        Assert-GaCondition ($matches.Count -eq 1) "live issue snapshot contains exactly one issue #$number"
        $state = [string](Get-GaProperty -Object $matches[0] -Path 'state' -Description "issue #$number")
        Assert-GaCondition ($state.Equals('closed', [System.StringComparison]::OrdinalIgnoreCase)) "issue #$number must be closed before GA (observed '$state')"
    }
}

function Assert-GaControlsSnapshot {
    param([Parameter(Mandatory = $true)][object]$Controls)

    $protected = Get-GaProperty -Object $Controls -Path 'branchProtection.protected' -Description 'repository branch protection'
    Assert-GaCondition (($protected -is [bool]) -and $protected) 'the default branch must be protected before GA'

    $environment = Get-GaProperty -Object $Controls -Path 'productionEnvironment' -Description 'production environment'
    $environmentName = [string](Get-GaProperty -Object $environment -Path 'name' -Description 'production environment')
    Assert-GaCondition ($environmentName.Equals('production', [System.StringComparison]::Ordinal)) "the GA environment must be named 'production' (observed '$environmentName')"
    $canAdminsBypass = Get-GaProperty -Object $environment -Path 'can_admins_bypass' -Description 'production environment'
    Assert-GaCondition (($canAdminsBypass -is [bool]) -and -not $canAdminsBypass) 'production environment administrator bypass must be disabled'

    $rules = @(Get-GaProperty -Object $environment -Path 'protection_rules' -Description 'production environment')
    Assert-GaCondition ($rules.Count -gt 0) 'production environment must have protection rules'
    Assert-GaCondition (@($rules | Where-Object { [string]$_.type -ceq 'required_reviewers' }).Count -gt 0) 'production environment must require a reviewer'
    Assert-GaCondition (@($rules | Where-Object { [string]$_.type -ceq 'wait_timer' }).Count -gt 0) 'production environment must have a wait timer'

    $policies = @(Get-GaProperty -Object $Controls -Path 'deploymentBranchPolicies.branch_policies' -Description 'production deployment branch policy')
    $tagPolicies = @($policies | Where-Object { [string]$_.type -ceq 'tag' -and [string]$_.name -ceq 'v*' })
    Assert-GaCondition ($tagPolicies.Count -gt 0) "production environment must allow only the configured v* tag policy"
}

Assert-GaWorkflowContract
$checks = New-Object System.Collections.Generic.List[object]
[void]$checks.Add([ordered]@{
    name = 'workflow-contract'
    status = 'passed'
    message = 'manual stable gate requires external evidence and has no hosted acceptance/publisher path'
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
    Assert-GaCondition (-not [string]::IsNullOrWhiteSpace($IssueSnapshotPath)) 'IssueSnapshotPath is required'
    Assert-GaCondition (-not [string]::IsNullOrWhiteSpace($ControlsPath)) 'ControlsPath is required'

    $versionCheckPath = Join-Path $RepositoryRoot 'scripts/Test-VersionConsistency.ps1'
    Assert-GaCondition (Test-Path -LiteralPath $versionCheckPath -PathType Leaf) 'version consistency gate exists'
    $versionOutput = @(& $versionCheckPath -SourceTag $ExpectedTag -SkipNegativeTests -Json)
    if ($LASTEXITCODE -ne 0) {
        throw "GA readiness assertion failed: stable version consistency gate exited with $LASTEXITCODE."
    }
    $versionResult = $versionOutput -join "`n" | ConvertFrom-Json
    Assert-GaString -Object $versionResult -Path 'releaseChannel' -Expected 'stable' -Description 'stable version identity'
    Assert-GaString -Object $versionResult -Path 'productVersion' -Expected $ExpectedTag.Substring(1) -Description 'stable version identity'
    [void]$checks.Add([ordered]@{
        name = 'stable-version-identity'
        status = 'passed'
        message = "VERSION and product surfaces match $ExpectedTag"
    })

    $evidence = Get-GaJson -Path $EvidencePath -Description 'external GA evidence manifest'
    Assert-GaString -Object $evidence -Path 'schemaVersion' -Expected 'cyc.dev/ga-evidence/v1' -Description 'external GA evidence manifest'
    Assert-GaString -Object $evidence -Path 'status' -Expected 'passed' -Description 'external GA evidence manifest'
    Assert-GaString -Object $evidence -Path 'productVersion' -Expected $ExpectedTag.Substring(1) -Description 'external GA evidence manifest'
    Assert-GaString -Object $evidence -Path 'sourceTag' -Expected $ExpectedTag -Description 'external GA evidence manifest'
    $evidenceCommit = [string](Get-GaProperty -Object $evidence -Path 'sourceCommit' -Description 'external GA evidence manifest')
    Assert-GaCondition ($evidenceCommit.Equals($ExpectedCommit, [System.StringComparison]::OrdinalIgnoreCase)) 'external GA evidence sourceCommit matches the reviewed stable source commit'
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
    Assert-GaString -Object $evidence -Path 'artifactVerification.status' -Expected 'passed' -Description 'independent post-download artifact verification'
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
