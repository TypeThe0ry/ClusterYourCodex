#requires -Version 5.1

$testScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$testRepositoryRoot = Split-Path -Parent $testScriptRoot
$readinessScript = Join-Path $testScriptRoot 'Test-GAReadiness.ps1'
$readinessSource = Get-Content -LiteralPath $readinessScript -Raw
$rawLogScript = Join-Path $testScriptRoot 'Test-GARawLogs.ps1'
$rawLogSource = Get-Content -LiteralPath $rawLogScript -Raw
$workflowPath = Join-Path $testRepositoryRoot '.github/workflows/ga.yml'
$workflowSource = Get-Content -LiteralPath $workflowPath -Raw
$expectedCommitForTest = ('a' * 40) -join ''
$rawLogShaForTest = ('b' * 64) -join ''

$issue2GateNamesForTest = @(
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

$issue3GateNamesForTest = @(
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
    foreach ($gate in ($issue2GateNamesForTest + $issue3GateNamesForTest + $issue5GateNamesForTest | Select-Object -Unique)) {
        $gates[$gate] = $true
    }
    $record = [ordered]@{
        status = 'passed'
        sourceCommit = $expectedCommitForTest
        provider = $Provider
        hostType = $HostType
        evidenceId = 'ga-issue2-live-20260830'
        rawLog = [ordered]@{
            url = 'https://evidence.example.invalid/ga/issue3.log'
            sha256 = $rawLogShaForTest
            command = 'cargo test --workspace --locked'
            node = 'p1-linux-native'
            startedAt = '2026-08-30T14:00:00Z'
            endedAt = '2026-08-30T14:01:00Z'
            exitCode = 0
            tests = [ordered]@{ passed = 42; failed = 0; ignored = 1 }
            cleanup = $true
        }
        gates = $gates
    }
    return (($record | ConvertTo-Json -Depth 10) | ConvertFrom-Json)
}

function New-TestIssue5Evidence {
    $record = New-TestIssueEvidence -Provider 'issue5-matrix-lab' -HostType 'external-native-matrix'
    $record.evidenceId = 'ga-issue5-matrix-20260830'
    $record.rawLog.command = 'issue5-evidence-matrix'
    $record.rawLog.node = 'issue5-matrix-coordinator'
    $record.rawLog | Add-Member -MemberType NoteProperty -Name platforms -Value @('linux', 'windows', 'macos')

    $runs = New-Object System.Collections.Generic.List[object]
    foreach ($platform in @('linux', 'windows', 'macos')) {
        $selector = [string]$GaIssue5ExpectedSelectors[$platform]
        $manifestPath = if ($platform -ceq 'windows') { 'C:\src\ClusterYourCodex\Cargo.toml' } else { '/srv/ClusterYourCodex/Cargo.toml' }
        $flags = if ($platform -ceq 'linux') { '--ignored --exact --nocapture' } else { '--exact --nocapture' }
        $command = "cargo test --manifest-path $manifestPath -p cyc-worker --lib --locked -- $flags $selector"
        $gates = @($GaIssue5PlatformGateNames[$platform] + $GaIssue5MatrixGateNames)
        $markers = @($gates | ForEach-Object {
                Get-GaIssue5Marker -Platform $platform -Selector $selector -Command $command -Gate ([string]$_)
            })
        if ($platform -ceq 'linux') {
            $markers += @('uid=1007', 'gid=1007', 'cgroup_escape=blocked', 'cgroup.threads_escape=blocked', 'residual_empty')
        }
        [void]$runs.Add([ordered]@{
                platform = $platform
                node = "$platform-native-lab"
                testSelector = $selector
                command = $command
                gates = $gates
                markers = $markers
            })
    }
    $runByPlatform = @{}
    foreach ($run in $runs) {
        $runByPlatform[[string]$run.platform] = $run
    }
    $structuredGates = [ordered]@{}
    foreach ($platform in @('linux', 'windows', 'macos')) {
        $run = $runByPlatform[$platform]
        foreach ($gate in @($GaIssue5PlatformGateNames[$platform])) {
            $gateMarkers = @($run.markers | Where-Object { [string]$_ -ceq (Get-GaIssue5Marker -Platform $platform -Selector ([string]$run.testSelector) -Command ([string]$run.command) -Gate $gate) })
            if ($platform -ceq 'linux' -and $gate -ceq 'linuxDedicatedExecutionIdentity') {
                $gateMarkers += @('uid=1007', 'gid=1007')
            }
            if ($platform -ceq 'linux' -and $gate -ceq 'linuxCgroupV2Reconciliation') {
                $gateMarkers += @('cgroup_escape=blocked', 'cgroup.threads_escape=blocked')
            }
            $structuredGates[$gate] = [ordered]@{
                status = $true
                platform = $platform
                testSelector = [string]$run.testSelector
                command = [string]$run.command
                rawLogMarkers = $gateMarkers
            }
        }
    }
    foreach ($gate in $GaIssue5MatrixGateNames) {
        $matrixRuns = New-Object System.Collections.Generic.List[object]
        $matrixMarkers = New-Object System.Collections.Generic.List[string]
        foreach ($platform in @('linux', 'windows', 'macos')) {
            $run = $runByPlatform[$platform]
            $marker = Get-GaIssue5Marker -Platform $platform -Selector ([string]$run.testSelector) -Command ([string]$run.command) -Gate $gate
            $runMarkers = @($marker)
            if ($gate -ceq 'restartResidualProcessReconciliation' -and $platform -ceq 'linux') {
                $runMarkers += 'residual_empty'
            }
            [void]$matrixMarkers.Add($marker)
            foreach ($markerValue in $runMarkers) {
                if (-not (@($matrixMarkers | Where-Object { $_ -ceq $markerValue }).Count -gt 0)) {
                    [void]$matrixMarkers.Add($markerValue)
                }
            }
            [void]$matrixRuns.Add([ordered]@{
                    platform = $platform
                    testSelector = [string]$run.testSelector
                    command = [string]$run.command
                    rawLogMarkers = $runMarkers
                })
        }
        $structuredGates[$gate] = [ordered]@{
            status = $true
            platforms = @('linux', 'windows', 'macos')
            runs = $matrixRuns.ToArray()
            rawLogMarkers = $matrixMarkers.ToArray()
        }
    }
    $record.gates = (($structuredGates | ConvertTo-Json -Depth 20) | ConvertFrom-Json)
    $record.rawLog | Add-Member -MemberType NoteProperty -Name runs -Value $runs.ToArray()
    $record.rawLog | Add-Member -MemberType NoteProperty -Name markers -Value @($structuredGates.Values | ForEach-Object { $_.rawLogMarkers } | Select-Object -Unique)
    return (($record | ConvertTo-Json -Depth 20) | ConvertFrom-Json)
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
        $readinessSource | Should Match 'Assert-GaIssueEvidence -Evidence \$evidence -Path ''issue2'''
        $readinessSource | Should Match 'Assert-GaIssueEvidence -Evidence \$evidence -Path ''issue3'''
        $readinessSource | Should Match 'Assert-GaIssueEvidence -Evidence \$evidence -Path ''issue5'''
        foreach ($field in @('sourceCommit', 'provider', 'hostType', 'evidenceId', 'rawLog', 'sha256', 'gates')) {
            $readinessSource | Should Match ([regex]::Escape($field))
        }
        foreach ($gate in ($issue2GateNamesForTest + $issue3GateNamesForTest + $issue5GateNamesForTest | Select-Object -Unique)) {
            $readinessSource | Should Match ([regex]::Escape($gate))
            $workflowSource | Should Match ([regex]::Escape($gate))
        }
        $workflowSource | Should Match 'valid_issue_evidence'
        $workflowSource | Should Match '\.issue3'
        $workflowSource | Should Match '\.issue5'
        $workflowSource | Should Match 'def valid_issue5'
        $workflowSource | Should Match 'issue5_single_gate_valid'
        $workflowSource | Should Match 'issue5_matrix_gate_valid'
        $workflowSource | Should Match 'issue5-evidence-matrix'
        $workflowSource | Should Not Match 'valid_issue_evidence\(\.issue5'
        $workflowSource | Should Match 'valid_https_url'
        ($workflowSource.IndexOf('test("^https://[^@/?#[:space:]]+([/?#]|$)")') -ge 0) | Should Be $true
        foreach ($field in @('attestation_signer_repo:', 'attestation_signer_workflow:', 'attestation_cert_identity:', 'attestation_signer_digest:', 'CYC_GA_ATTESTATION_SIGNER_REPO: ${{ inputs.attestation_signer_repo }}', 'CYC_GA_ATTESTATION_SIGNER_WORKFLOW: ${{ inputs.attestation_signer_workflow }}', 'CYC_GA_ATTESTATION_CERT_IDENTITY: ${{ inputs.attestation_cert_identity }}', 'CYC_GA_ATTESTATION_SIGNER_DIGEST: ${{ inputs.attestation_signer_digest }}')) {
            $workflowSource | Should Match ([regex]::Escape($field))
        }
        $workflowSource | Should Match 'stable attestation signer must be a stable external builder'
        foreach ($policyName in @('CYC_GA_TRUSTED_BUILDER_REPO', 'CYC_GA_TRUSTED_BUILDER_WORKFLOW', 'CYC_GA_TRUSTED_BUILDER_DIGEST')) {
            $workflowSource | Should Match ([regex]::Escape($policyName))
        }
        $workflowSource | Should Match 'stable attestation signer must be an external repository'
        $workflowSource | Should Match 'does not match protected stable-builder policy'
        $workflowSource | Should Match '--signer-digest'
        ([regex]::Matches($workflowSource, '-RawLogVerificationPath')).Count | Should Be 2
        $workflowSource | Should Match 'resultLines = @\(& ./scripts/Test-GAReadiness\.ps1'
        $workflowSource | Should Match 'Test-ExternalHttpsUrl\.py'
        $workflowSource | Should Match '--max-redirs 0'
        $workflowSource | Should Match 'ConvertFrom-Json'
        $workflowSource | Should Match 'readinessDirectory = Join-Path \$env:RUNNER_TEMP'
        $workflowSource | Should Not Match 'outputDirectory = Join-Path \$env:RUNNER_TEMP ''cyc-ga-readiness\\raw-logs'''
    }

    It 'keeps raw-log verification executable and fail-closed' {
        $rawLogSource | Should Match 'cyc.dev/ga-raw-log-verification/v1'
        $rawLogSource | Should Match 'AllowAutoRedirect = \$false'
        $rawLogSource | Should Match 'MaximumRawLogBytes'
        $rawLogSource | Should Match 'Get-FileHash -Algorithm SHA256'
        $rawLogSource | Should Match '\$actualHash -ceq \$expectedHash'
        $rawLogSource | Should Match '\[IO\.FileMode\]::CreateNew'
        $rawLogSource | Should Match 'Write-RawLogAtomicText'
        $rawLogSource | Should Match 'refusing to overwrite an existing raw log destination'
        $rawLogSource | Should Match 'raw log destination is not a reparse point or directory'
        $rawLogSource | Should Match 'Assert-RawLogExternalHost'
        $rawLogSource | Should Match 'globally routable addresses'
        $rawLogSource | Should Match 'raw log URL must not contain a fragment'
        $rawLogSource | Should Match 'issue2'
        $rawLogSource | Should Match 'issue3'
        $rawLogSource | Should Match 'issue5'
        $rawLogSource | Should Match 'markersVerified'
        $rawLogSource | Should Match 'Assert-RawLogIssue5Evidence'
        $rawLogSource | Should Match 'Assert-RawLogIssue5Markers'
        $rawLogSource | Should Match 'rawLogMarkers'
        $rawLogSource | Should Match 'gateEvidence'
        $rawLogSource | Should Match '--workspace'
        foreach ($markerPrefix in @('uid=', 'gid=', 'cgroup_escape=blocked', 'cgroup.threads_escape=blocked', 'residual_empty')) {
            $rawLogSource | Should Match ([regex]::Escape($markerPrefix))
        }
        $readinessSource | Should Match 'Assert-GaIssue5Evidence'
        $readinessSource | Should Match 'Assert-GaIssue5RawVerification'
        $readinessSource | Should Match 'rawLogMarkers'
        $readinessSource | Should Match 'testSelector'
        $readinessSource | Should Match 'platforms'
        $readinessSource | Should Match 'rawVerificationRootPrefix'
        $readinessSource | Should Match 'downloaded raw-log URL matches'
        $readinessSource | Should Match 'downloaded GA raw-log file hash matches'
    }

    It 'keeps the workflow contract semantic and checks helper exit codes' {
        $workflowSource | Should Match 'readinessExitCode = \$LASTEXITCODE'
        $readinessSource | Should Match 'versionExitCode = \$LASTEXITCODE'
        $readinessSource | Should Match 'Assert-GaWorkflowSemanticContract'

        $missingDispatch = $workflowSource -replace '(?m)^  workflow_dispatch:\s*$', '  push: {}'
        Assert-TestThrows { Assert-GaWorkflowContract -WorkflowText $missingDispatch }

        $optionalInput = [regex]::Replace($workflowSource, '(?m)^        required:\s*true\s*$', '        required: false', 1)
        Assert-TestThrows { Assert-GaWorkflowContract -WorkflowText $optionalInput }

        $wrongPublisherDependency = $workflowSource -replace '(?m)^    if: needs\.ga-readiness\.result == ''success''\s*$', '    if: always()'
        Assert-TestThrows { Assert-GaWorkflowContract -WorkflowText $wrongPublisherDependency }
    }

    It 'ignores whitespace-only and indented comment YAML lines' {
        $lines = @(Get-GaYamlLines -Text "  # ignored comment`n   `n  key: value`n")
        $lines.Count | Should Be 1
        $lines[0].Content | Should Be 'key: value'
    }

    It 'rejects ambiguous stable bundle ZIP path spellings' {
        $workflowSource | Should Match 'path_name = name\[:-1\]'
        $workflowSource | Should Match 'any\(part in'
        $workflowSource | Should Match 'for part in parts'
        $workflowSource | Should Match "normalized = '/'\.join\(lowered_parts\)"
    }

    It 'validates every additional external host record and rejects unknown metadata' {
        $base = [ordered]@{
            schemaVersion = 'cyc.dev/ga-evidence/v1'
            status = 'passed'
            productVersion = '0.1.0'
            sourceTag = 'v0.1.0'
            sourceCommit = $expectedCommitForTest
            issue2 = [pscustomobject]@{}
            issue3 = [pscustomobject]@{}
            issue5 = [pscustomobject]@{}
            windowsCleanVm = [pscustomobject]@{}
            macosLaunchAgent = [pscustomobject]@{}
            windowsAuthenticode = [pscustomobject]@{}
            artifactVerification = [pscustomobject]@{}
            externalBuilder = New-TestIssueEvidence -Provider 'external-builder' -HostType 'linux-native'
        }
        $evidence = (($base | ConvertTo-Json -Depth 12) | ConvertFrom-Json)
        Assert-GaEvidenceHostRecordSet -Evidence $evidence -ExpectedCommit $expectedCommitForTest

        $withUnknown = [ordered]@{}
        foreach ($entry in $base.GetEnumerator()) { $withUnknown[$entry.Key] = $entry.Value }
        $withUnknown.unexpectedMetadata = 'not-a-host-record'
        $evidence = (($withUnknown | ConvertTo-Json -Depth 12) | ConvertFrom-Json)
        Assert-TestThrows { Assert-GaEvidenceHostRecordSet -Evidence $evidence -ExpectedCommit $expectedCommitForTest }
    }

    It 'accepts a complete source-bound issue 3 evidence record' {
        $record = New-TestIssueEvidence
        $result = Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue3 = $record }) `
            -Path 'issue3' -Description 'Issue #3 test evidence' -ExpectedCommit $expectedCommitForTest `
            -RequiredGates $issue3GateNamesForTest
        $result.status | Should Be 'passed'
        $result.rawLog.sha256 | Should Be $rawLogShaForTest
    }

    It 'accepts a complete source-bound issue 2 evidence record' {
        $record = New-TestIssueEvidence -Provider 'windows-lab' -HostType 'windows-clean-vm'
        $result = Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue2 = $record }) `
            -Path 'issue2' -Description 'Issue #2 test evidence' -ExpectedCommit $expectedCommitForTest `
            -RequiredGates $issue2GateNamesForTest
        $result.status | Should Be 'passed'
        $result.gates.cleanWindows11Vm | Should Be $true
    }

    It 'accepts a complete source-bound issue 5 evidence record' {
        $record = New-TestIssue5Evidence
        $result = Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue5 = $record }) `
            -Path 'issue5' -Description 'Issue #5 test evidence' -ExpectedCommit $expectedCommitForTest `
            -RequiredGates $issue5GateNamesForTest
        $result.status | Should Be 'passed'
    }

    It 'rejects a generic Linux cargo test with every Issue #5 gate set true' {
        $record = New-TestIssueEvidence -Provider 'linux-lab' -HostType 'linux-native'
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue5 = $record }) `
                -Path 'issue5' -Description 'Issue #5 generic Linux evidence' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue5GateNamesForTest
        }
    }

    It 'rejects an Issue #5 platform row relabelled to another platform' {
        $record = New-TestIssue5Evidence
        $record.gates.windowsIsolatedExecutionIdentity.platform = 'linux'
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue5 = $record }) `
                -Path 'issue5' -Description 'Issue #5 platform mismatch' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue5GateNamesForTest
        }
    }

    It 'rejects an Issue #5 row with a generic command or wrong exact selector' {
        $record = New-TestIssue5Evidence
        $record.gates.linuxDedicatedExecutionIdentity.command = 'cargo test --workspace --locked'
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue5 = $record }) `
                -Path 'issue5' -Description 'Issue #5 generic command' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue5GateNamesForTest
        }

        $record = New-TestIssue5Evidence
        $record.rawLog.command = 'cargo test --manifest-path /srv/ClusterYourCodex/Cargo.toml -p cyc-worker --lib --locked'
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue5 = $record }) `
                -Path 'issue5' -Description 'Issue #5 aggregate command mismatch' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue5GateNamesForTest
        }

        $record = New-TestIssue5Evidence
        $record.gates.macosExternalReconciliation.testSelector = 'isolation::tests::wrong_selector'
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue5 = $record }) `
                -Path 'issue5' -Description 'Issue #5 selector mismatch' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue5GateNamesForTest
        }
    }

    It 'rejects Issue #5 matrix evidence with a missing native Linux marker' {
        $record = New-TestIssue5Evidence
        $record.gates.linuxCgroupV2Reconciliation.rawLogMarkers = @(
            $record.gates.linuxCgroupV2Reconciliation.rawLogMarkers |
                Where-Object { ([string]$_) -notlike 'cgroup_escape=blocked*' }
        )
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue5 = $record }) `
                -Path 'issue5' -Description 'Issue #5 missing native marker' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue5GateNamesForTest
        }
    }

    It 'rejects an Issue #5 manifest with a missing retained raw-log marker' {
        $record = New-TestIssue5Evidence
        $record.rawLog.markers = @($record.rawLog.markers | Select-Object -Skip 1)
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue5 = $record }) `
                -Path 'issue5' -Description 'Issue #5 marker mismatch' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue5GateNamesForTest
        }
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

    It 'rejects path-bearing evidence identifiers before raw-log materialization' {
        $record = New-TestIssueEvidence
        $record.evidenceId = 'ga/../../escape'
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue3 = $record }) `
                -Path 'issue3' -Description 'Issue #3 test evidence' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue3GateNamesForTest
        }
        $rawLogSource | Should Match 'bounded portable filename'
    }

    It 'rejects raw-log metadata that is not bound to a successful run' {
        $record = New-TestIssueEvidence
        [void]$record.rawLog.PSObject.Properties.Remove('command')
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue3 = $record }) `
                -Path 'issue3' -Description 'Issue #3 test evidence' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue3GateNamesForTest
        }
        $record = New-TestIssueEvidence
        $record.rawLog.tests.failed = 1
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue3 = $record }) `
                -Path 'issue3' -Description 'Issue #3 test evidence' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue3GateNamesForTest
        }
        $record = New-TestIssueEvidence
        $record.rawLog.startedAt = '2026-08-30T14:00:00'
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue3 = $record }) `
                -Path 'issue3' -Description 'Issue #3 test evidence' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue3GateNamesForTest
        }
        $record = New-TestIssueEvidence
        $record.rawLog.endedAt = '2026-08-30T13:59:00Z'
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

    It 'requires canonical completed issue snapshots' {
        $validSnapshot = [pscustomobject]@{
            issues = @(
                [pscustomobject]@{ number = 2; state = 'closed'; state_reason = 'completed'; title = 'Windows one-click installer and desktop host'; html_url = 'https://github.com/TypeThe0ry/ClusterYourCodex/issues/2' }
                [pscustomobject]@{ number = 3; state = 'closed'; state_reason = 'completed'; title = 'Heterogeneous Linux and macOS worker packages'; html_url = 'https://github.com/TypeThe0ry/ClusterYourCodex/issues/3' }
                [pscustomobject]@{ number = 5; state = 'closed'; state_reason = 'completed'; title = 'Opt-in hostile-workload isolation and external process reconciliation'; html_url = 'https://github.com/TypeThe0ry/ClusterYourCodex/issues/5' }
            )
        }
        Assert-GaIssueSnapshot -Snapshot $validSnapshot

        $notPlanned = ($validSnapshot | ConvertTo-Json -Depth 10) | ConvertFrom-Json
        $notPlanned.issues[0].state_reason = 'not planned'
        Assert-TestThrows { Assert-GaIssueSnapshot -Snapshot $notPlanned }

        $wrongTitle = ($validSnapshot | ConvertTo-Json -Depth 10) | ConvertFrom-Json
        $wrongTitle.issues[1].title = 'unrelated issue'
        Assert-TestThrows { Assert-GaIssueSnapshot -Snapshot $wrongTitle }
    }

    It 'requires a concrete production reviewer identity' {
        $controls = [pscustomobject]@{
            defaultBranch = 'main'
            branchProtection = [pscustomobject]@{
                name = 'main'
                protected = $true
                protection = [pscustomobject]@{ enabled = $true }
                protectionDetails = [pscustomobject]@{
                    allow_force_pushes = [pscustomobject]@{ enabled = $false }
                    allow_deletions = [pscustomobject]@{ enabled = $false }
                    enforce_admins = [pscustomobject]@{ enabled = $true }
                }
            }
            productionEnvironment = [pscustomobject]@{
                name = 'production'
                can_admins_bypass = $false
                protection_rules = @(
                    [pscustomobject]@{
                        type = 'required_reviewers'
                        reviewers = @([pscustomobject]@{ type = 'User'; reviewer = [pscustomobject]@{ id = 123; login = 'release-reviewer' } })
                        prevent_self_review = $true
                    }
                    [pscustomobject]@{ type = 'wait_timer'; wait_timer = 15 }
                )
            }
            deploymentBranchPolicies = [pscustomobject]@{
                branch_policies = @([pscustomobject]@{ type = 'tag'; name = 'v*' })
            }
        }
        Assert-GaControlsSnapshot -Controls $controls

        $invalid = ($controls | ConvertTo-Json -Depth 12) | ConvertFrom-Json
        $invalid.productionEnvironment.protection_rules[0].reviewers = @([pscustomobject]@{ type = 'User'; reviewer = [pscustomobject]@{} })
        Assert-TestThrows { Assert-GaControlsSnapshot -Controls $invalid }
    }
}
