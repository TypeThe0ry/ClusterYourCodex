#requires -Version 5.1

$testScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$testRepositoryRoot = Split-Path -Parent $testScriptRoot
$readinessScript = Join-Path $testScriptRoot 'Test-GAReadiness.ps1'
$readinessSource = Get-Content -LiteralPath $readinessScript -Raw
$workflowPath = Join-Path $testRepositoryRoot '.github/workflows/ga.yml'
$workflowSource = Get-Content -LiteralPath $workflowPath -Raw
$expectedCommitForTest = ('a' * 40) -join ''
$rawLogShaForTest = ('b' * 64) -join ''

$issue3GateNamesForTest = @(
    'linuxSystemdUserServicePackage',
    'macosLaunchAgentPackage',
    'linuxX64ReleaseArtifact',
    'macosX64ReleaseArtifact',
    'macosArm64ReleaseArtifact',
    'platformNativeShells',
    'platformNativeProcessGroups',
    'crossPlatformPathAclTests',
    'liveMacosRun'
)

$issue5GateNamesForTest = @(
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

# ContractOnly executes the same static workflow contract used by CI. Dot-source
# afterwards exposes the assertion helpers for focused unit tests without
# attempting the version/evidence/governance gates.
$contractOutput = @(& $readinessScript -RepositoryRoot $testRepositoryRoot -ContractOnly -Json)
$contractResult = ($contractOutput -join "`n") | ConvertFrom-Json
. $readinessScript -RepositoryRoot $testRepositoryRoot -ContractOnly -Json | Out-Null

function New-TestIssueEvidence {
    param(
        [string]$Provider = 'external-lab',
        [string]$HostType = 'macos-native'
    )

    $gates = [ordered]@{}
    foreach ($gate in ($issue3GateNamesForTest + $issue5GateNamesForTest | Select-Object -Unique)) {
        $gates[$gate] = $true
    }
    $record = [ordered]@{
        status = 'passed'
        sourceCommit = $expectedCommitForTest
        provider = $Provider
        hostType = $HostType
        evidenceId = 'ga-issue3-live-20260830'
        rawLog = [ordered]@{
            url = 'https://evidence.example.invalid/ga/issue3.log'
            sha256 = $rawLogShaForTest
        }
        gates = $gates
    }
    return (($record | ConvertTo-Json -Depth 10) | ConvertFrom-Json)
}

function Assert-TestThrows {
    param([Parameter(Mandatory = $true)][scriptblock]$ScriptBlock)

    $threw = $false
    try {
        & $ScriptBlock
    } catch {
        $threw = $true
    }
    $threw | Should Be $true
}

Describe 'GA evidence issue acceptance contract' {
    It 'keeps the workflow contract enabled in contract-only mode' {
        $contractResult.status | Should Be 'contract-only'
        ([string]$contractResult.checks[0].name) | Should Be 'workflow-contract'
    }

    It 'wires both issue records and their canonical fields into the gate' {
        $readinessSource | Should Match 'Assert-GaIssueEvidence -Evidence \$evidence -Path ''issue3'''
        $readinessSource | Should Match 'Assert-GaIssueEvidence -Evidence \$evidence -Path ''issue5'''
        foreach ($field in @('sourceCommit', 'provider', 'hostType', 'evidenceId', 'rawLog', 'sha256', 'gates')) {
            $readinessSource | Should Match ([regex]::Escape($field))
        }
        foreach ($gate in ($issue3GateNamesForTest + $issue5GateNamesForTest | Select-Object -Unique)) {
            $readinessSource | Should Match ([regex]::Escape($gate))
            $workflowSource | Should Match ([regex]::Escape($gate))
        }
        $workflowSource | Should Match 'valid_issue_evidence'
        $workflowSource | Should Match '\.issue3'
        $workflowSource | Should Match '\.issue5'
    }

    It 'accepts a complete source-bound issue 3 evidence record' {
        $record = New-TestIssueEvidence
        $result = Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue3 = $record }) `
            -Path 'issue3' -Description 'Issue #3 test evidence' -ExpectedCommit $expectedCommitForTest `
            -RequiredGates $issue3GateNamesForTest
        $result.status | Should Be 'passed'
        $result.rawLog.sha256 | Should Be $rawLogShaForTest
    }

    It 'accepts a complete source-bound issue 5 evidence record' {
        $record = New-TestIssueEvidence -Provider 'linux-lab' -HostType 'linux-native'
        $result = Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue5 = $record }) `
            -Path 'issue5' -Description 'Issue #5 test evidence' -ExpectedCommit $expectedCommitForTest `
            -RequiredGates $issue5GateNamesForTest
        $result.status | Should Be 'passed'
    }

    It 'rejects a record with no raw log even when all gates are true' {
        $record = New-TestIssueEvidence
        [void]$record.PSObject.Properties.Remove('rawLog')
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue3 = $record }) `
                -Path 'issue3' -Description 'Issue #3 test evidence' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue3GateNamesForTest
        }
    }

    It 'rejects a mismatched source commit' {
        $record = New-TestIssueEvidence
        $record.sourceCommit = ('c' * 40) -join ''
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue3 = $record }) `
                -Path 'issue3' -Description 'Issue #3 test evidence' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue3GateNamesForTest
        }
    }

    It 'rejects GitHub-hosted provider metadata' {
        $record = New-TestIssueEvidence -Provider 'github-actions'
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue3 = $record }) `
                -Path 'issue3' -Description 'Issue #3 test evidence' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue3GateNamesForTest
        }
    }

    It 'rejects a non-HTTPS raw log URL and malformed digest' {
        $record = New-TestIssueEvidence
        $record.rawLog.url = 'http://evidence.example.invalid/ga/issue3.log'
        $record.rawLog.sha256 = 'not-a-sha256'
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue3 = $record }) `
                -Path 'issue3' -Description 'Issue #3 test evidence' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue3GateNamesForTest
        }
    }

    It 'rejects any missing or false per-item gate' {
        $record = New-TestIssueEvidence
        $record.gates.liveMacosRun = $false
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue3 = $record }) `
                -Path 'issue3' -Description 'Issue #3 test evidence' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue3GateNamesForTest
        }
        $record = New-TestIssueEvidence
        [void]$record.gates.PSObject.Properties.Remove('liveMacosRun')
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue3 = $record }) `
                -Path 'issue3' -Description 'Issue #3 test evidence' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue3GateNamesForTest
        }
    }

    It 'requires issue evidence independently of issue closure metadata' {
        $closedIssuesOnly = [pscustomobject]@{
            status = 'passed'
            issues = @(
                [pscustomobject]@{ number = 2; state = 'closed' }
                [pscustomobject]@{ number = 3; state = 'closed' }
                [pscustomobject]@{ number = 5; state = 'closed' }
            )
        }
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence $closedIssuesOnly `
                -Path 'issue3' -Description 'Issue #3 test evidence' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue3GateNamesForTest
        }
    }
}
