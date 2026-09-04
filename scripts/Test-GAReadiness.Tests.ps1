#requires -Version 5.1

$testScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$testRepositoryRoot = Split-Path -Parent $testScriptRoot
$readinessScript = Join-Path $testScriptRoot 'Test-GAReadiness.ps1'
$readinessSource = Get-Content -LiteralPath $readinessScript -Raw
$rawLogScript = Join-Path $testScriptRoot 'Test-GARawLogs.ps1'
$rawLogSource = Get-Content -LiteralPath $rawLogScript -Raw
$selectorGuardScript = Join-Path $testScriptRoot 'Test-Issue5Selector.py'
$selectorGuardSource = Get-Content -LiteralPath $selectorGuardScript -Raw
$selectorGuardModule = Join-Path $testScriptRoot 'issue5_selector_guard.py'
$selectorGuardModuleSource = Get-Content -LiteralPath $selectorGuardModule -Raw
$selectorGuardTests = Join-Path $testScriptRoot 'test_issue5_selector_guard.py'
$selectorGuardTestsSource = Get-Content -LiteralPath $selectorGuardTests -Raw
$linuxIsolationProbe = Join-Path $testScriptRoot 'test-linux-hostile-isolation.sh'
$linuxIsolationProbeSource = Get-Content -LiteralPath $linuxIsolationProbe -Raw
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
. $rawLogScript -EvidencePath (Join-Path $testRepositoryRoot 'missing-ga-evidence.json') `
    -OutputDirectory (Join-Path $testRepositoryRoot 'missing-ga-raw-logs') `
    -ExpectedCommit $expectedCommitForTest -ContractOnly | Out-Null

function New-TestBlockerInventory {
    param(
        [switch]$IncludeWaivedOpenP1,
        [switch]$Expired,
        [switch]$ApiIncomplete
    )

    $issues = @()
    $waivers = @()
    $inventoryExpiry = if ($Expired) { '2020-01-01T00:00:00Z' } else { '2099-12-31T23:59:59Z' }
    if ($IncludeWaivedOpenP1) {
        $issues = @([ordered]@{
                number = 42
                state = 'open'
                title = 'tracked P1 test blocker'
                html_url = 'https://github.com/TypeThe0ry/ClusterYourCodex/issues/42'
                labels = @([ordered]@{ name = 'priority:P1' })
            })
        $waivers = @([ordered]@{
                issueNumber = 42
                scope = [ordered]@{ repository = 'TypeThe0ry/ClusterYourCodex'; channel = 'stable'; issueNumber = 42 }
                sourceCommit = $expectedCommitForTest
                expiresAt = $inventoryExpiry
                reviewer = [ordered]@{ id = 123; login = 'release-reviewer' }
                status = 'active'
                reason = 'temporary migration waiver with explicit review expiry'
            })
    }
    $inventory = [ordered]@{
        schemaVersion = 'cyc.dev/ga-blocker-inventory/v1'
        status = 'passed'
        sourceCommit = $expectedCommitForTest
        evidenceId = 'ga-blocker-inventory-20260830'
        repository = 'TypeThe0ry/ClusterYourCodex'
        reviewer = [ordered]@{ id = 123; login = 'release-reviewer' }
        reviewedAt = '2026-08-30T14:00:00Z'
        expiresAt = $inventoryExpiry
        api = [ordered]@{
            provider = 'github-rest-api'
            endpoint = 'https://api.github.com/repos/TypeThe0ry/ClusterYourCodex/issues'
            requestedState = 'open'
            complete = (-not $ApiIncomplete)
            incomplete = [bool]$ApiIncomplete
            hasNextPage = [bool]$ApiIncomplete
            pageCount = 1
            totalCount = $issues.Count
            returnedCount = $issues.Count
            capturedAt = '2026-08-30T13:59:00Z'
            sourceCommit = $expectedCommitForTest
            error = $null
        }
        issues = $issues
        waivers = $waivers
    }
    return (($inventory | ConvertTo-Json -Depth 20) | ConvertFrom-Json)
}

function New-TestIssueEvidence {
    param(
        [string]$Provider = 'external-lab',
        [string]$HostType = 'macos-native',
        [string[]]$GateNames = $null
    )

    if ($null -eq $GateNames) {
        $GateNames = $issue3GateNamesForTest
    }

    # Issue #2/#3 use a structured per-gate contract.  Keep the fixture
    # source-bound in the same way as production evidence so tests exercise
    # the complete provenance/marker path instead of accidentally accepting
    # the legacy ``gate: true`` shape.
    $issueName = if (@($GateNames | Where-Object { [string]$_ -ceq 'tauriDesktopHostTray' }).Count -gt 0) {
        'issue2'
    } elseif (@($GateNames | Where-Object { [string]$_ -ceq 'linuxSystemdUserServicePackage' }).Count -gt 0) {
        'issue3'
    } else {
        $null
    }
    $evidenceId = if ($issueName) { "ga-$issueName-live-20260830" } else { 'ga-issue5-matrix-20260830' }
    $gates = [ordered]@{}
    $allMarkers = New-Object System.Collections.Generic.List[string]
    foreach ($gate in $GateNames) {
        if ($issueName) {
            $command = "native-$issueName-$gate"
            $marker = Get-GaIssue23GateMarker -IssueName $issueName -Gate ([string]$gate) -Command $command
            $gateEvidence = [ordered]@{
                status = $true
                gateId = "$issueName.$gate"
                sourceCommit = $expectedCommitForTest
                provider = $Provider
                hostType = $HostType
                evidenceId = $evidenceId
                runId = "$issueName-$gate-20260830"
                node = if ($issueName -ceq 'issue2') { 'windows-native-lab' } else { 'macos-native-lab' }
                exitCode = 0
                tests = [ordered]@{ passed = 1; failed = 0; ignored = 0 }
                startedAt = '2026-08-30T14:00:00Z'
                endedAt = '2026-08-30T14:01:00Z'
                testSelector = "$issueName::$gate"
                command = $command
                rawLogMarkers = @($marker)
            }
            if ($issueName -ceq 'issue2' -and [string]$gate -ceq 'noOpenUnwaivedP0P1Blocker') {
                $gateEvidence.blockerInventory = New-TestBlockerInventory -IncludeWaivedOpenP1
            }
            $gates[$gate] = $gateEvidence
            [void]$allMarkers.Add($marker)
        } else {
            $gates[$gate] = $true
        }
    }
    $record = [ordered]@{
        status = 'passed'
        sourceCommit = $expectedCommitForTest
        provider = $Provider
        hostType = $HostType
        evidenceId = $evidenceId
        rawLog = [ordered]@{
            url = "https://evidence.example.invalid/ga/$issueName.log"
            sha256 = $rawLogShaForTest
            command = if ($issueName) { "$issueName-evidence-matrix" } else { 'cargo test --workspace --locked' }
            node = 'p1-linux-native'
            startedAt = '2026-08-30T14:00:00Z'
            endedAt = '2026-08-30T14:01:00Z'
            exitCode = 0
            tests = [ordered]@{ passed = 42; failed = 0; ignored = 1 }
            cleanup = $true
        }
        gates = $gates
    }
    if ($issueName) {
        $record.rawLog.markers = $allMarkers.ToArray()
    }
    return (($record | ConvertTo-Json -Depth 10) | ConvertFrom-Json)
}

function New-TestIssue5Evidence {
    $record = New-TestIssueEvidence -Provider 'issue5-matrix-lab' -HostType 'external-native-matrix' -GateNames $issue5GateNamesForTest
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
        foreach ($gate in $gates) {
            if ($GaIssue5RequiredMarkerPrefixes.Contains([string]$gate)) {
                foreach ($prefix in @($GaIssue5RequiredMarkerPrefixes[[string]$gate])) {
                    $markers += [string]$prefix
                }
            }
            if ($GaIssue5PlatformGateMarkerPrefixes.Contains([string]$gate)) {
                foreach ($prefix in @($GaIssue5PlatformGateMarkerPrefixes[[string]$gate][$platform])) {
                    $markers += [string]$prefix
                }
            }
        }
        if ($platform -ceq 'linux') {
            # Use realistic dynamic identity values for the prefix contract.
            $markers = @($markers | ForEach-Object {
                    if ([string]$_ -ceq 'uid=') { 'uid=1007' }
                    elseif ([string]$_ -ceq 'gid=') { 'gid=1007' }
                    else { $_ }
                })
        }
        $markers += [string]@($GaIssue5ResidualMarkerPrefixes[$platform])[0]
        [void]$runs.Add([ordered]@{
                runId = "issue5-$platform-20260830"
                platform = $platform
                node = "$platform-native-lab"
                provider = 'native-lab'
                hostType = 'external-native'
                status = 'passed'
                exitCode = 0
                tests = [ordered]@{ passed = 42; failed = 0; ignored = 1 }
                startedAt = '2026-08-30T14:00:00Z'
                endedAt = '2026-08-30T14:01:00Z'
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
            if ($GaIssue5RequiredMarkerPrefixes.Contains([string]$gate)) {
                foreach ($prefix in @($GaIssue5RequiredMarkerPrefixes[[string]$gate])) {
                    if ([string]$prefix -ceq 'uid=') { $gateMarkers += 'uid=1007' }
                    elseif ([string]$prefix -ceq 'gid=') { $gateMarkers += 'gid=1007' }
                    else { $gateMarkers += [string]$prefix }
                }
            }
            if ($GaIssue5PlatformGateMarkerPrefixes.Contains([string]$gate)) {
                foreach ($prefix in @($GaIssue5PlatformGateMarkerPrefixes[[string]$gate][$platform])) {
                    $gateMarkers += [string]$prefix
                }
            }
            $structuredGates[$gate] = [ordered]@{
                status = $true
                runId = [string]$run.runId
                platform = $platform
                node = [string]$run.node
                provider = [string]$run.provider
                hostType = [string]$run.hostType
                exitCode = $run.exitCode
                tests = $run.tests
                startedAt = [string]$run.startedAt
                endedAt = [string]$run.endedAt
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
            if ($GaIssue5PlatformGateMarkerPrefixes.Contains([string]$gate)) {
                foreach ($prefix in @($GaIssue5PlatformGateMarkerPrefixes[[string]$gate][$platform])) {
                    $runMarkers += [string]$prefix
                }
            }
            if ($gate -ceq 'restartResidualProcessReconciliation') {
                $runMarkers += [string]@($GaIssue5ResidualMarkerPrefixes[$platform])[0]
            }
            [void]$matrixMarkers.Add($marker)
            foreach ($markerValue in $runMarkers) {
                if (-not (@($matrixMarkers | Where-Object { $_ -ceq $markerValue }).Count -gt 0)) {
                    [void]$matrixMarkers.Add($markerValue)
                }
            }
            [void]$matrixRuns.Add([ordered]@{
                    runId = [string]$run.runId
                    platform = $platform
                    node = [string]$run.node
                    provider = [string]$run.provider
                    hostType = [string]$run.hostType
                    status = [string]$run.status
                    exitCode = $run.exitCode
                    tests = $run.tests
                    startedAt = [string]$run.startedAt
                    endedAt = [string]$run.endedAt
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

function New-TestRawLogContent {
    param(
        [string]$IssueName = 'issue3',
        [object]$Record = $null
    )

    if ($null -eq $Record) {
        $Record = New-TestIssueEvidence
    }
    $rawLog = $Record.rawLog
    $content = [ordered]@{
        schemaVersion = 'cyc.dev/ga-raw-log/v1'
        status = 'passed'
        sourceCommit = $expectedCommitForTest
        issue = $IssueName
        evidenceId = [string]$Record.evidenceId
        command = [string]$rawLog.command
        node = [string]$rawLog.node
        startedAt = '2026-08-30T14:00:00Z'
        endedAt = '2026-08-30T14:01:00Z'
        exitCode = 0
        tests = [ordered]@{
            passed = $rawLog.tests.passed
            failed = $rawLog.tests.failed
            ignored = $rawLog.tests.ignored
        }
        cleanup = $true
    }
    if ($IssueName -ceq 'issue5') {
        $content.markers = @($rawLog.markers)
    } elseif ($IssueName -ceq 'issue2' -or $IssueName -ceq 'issue3') {
        $content.markers = @($rawLog.markers)
        $content.gates = [ordered]@{}
        foreach ($property in @($Record.gates.PSObject.Properties)) {
            $content.gates[[string]$property.Name] = $property.Value
        }
    }
    return (($content | ConvertTo-Json -Depth 20) | ConvertFrom-Json)
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

    It 'requires the native Issue #5 selector guard before accepting a run' {
        $selectorGuardSource | Should Match 'issue5_selector_guard'
        $selectorGuardModuleSource | Should Match 'EXPECTED_SELECTORS'
        $selectorGuardModuleSource | Should Match 'cargo test --list'
        $selectorGuardModuleSource | Should Match 'selector_not_found'
        $selectorGuardModuleSource | Should Match 'selector_ambiguous'
        $selectorGuardModuleSource | Should Match 'tests_passed_zero'
        $selectorGuardModuleSource | Should Match 'host_platform_mismatch'
        $selectorGuardModuleSource | Should Match 'parse_test_result'
        $selectorGuardModuleSource | Should Match '--exact'
        $selectorGuardModuleSource | Should Match '--nocapture'
        $selectorGuardTestsSource | Should Match 'test_nonexistent_selector_fails_before_execution'
        $selectorGuardTestsSource | Should Match 'test_zero_tests_fails_closed'
        $linuxIsolationProbeSource | Should Match 'Test-Issue5Selector\.py'
        $linuxIsolationProbeSource | Should Match 'selectorGuard'
        $linuxIsolationProbeSource | Should Match 'python3'
    }

    It 'wires both issue records and their canonical fields into the gate' {
        $readinessSource | Should Match 'Assert-GaIssueEvidence -Evidence \$evidence -Path ''issue2'''
        $readinessSource | Should Match 'Assert-GaIssueEvidence -Evidence \$evidence -Path ''issue3'''
        $readinessSource | Should Match 'Assert-GaIssueEvidence -Evidence \$evidence -Path ''issue5'''
        foreach ($field in @('sourceCommit', 'provider', 'hostType', 'evidenceId', 'rawLog', 'sha256', 'gates')) {
            $readinessSource | Should Match ([regex]::Escape($field))
        }
        foreach ($field in @('runId', 'node', 'exitCode', 'tests', 'startedAt', 'endedAt', 'Assert-GaIssue5RunProvenance', 'Assert-GaIssue5RunProvenanceMatch')) {
            $readinessSource | Should Match ([regex]::Escape($field))
        }
        foreach ($field in @('runId', 'node', 'exitCode', 'tests', 'startedAt', 'endedAt', 'Assert-RawLogIssue5RunProvenance')) {
            $rawLogSource | Should Match ([regex]::Escape($field))
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
        $workflowSource | Should Match 'issue5_selector_value'
        $workflowSource | Should Match 'issue5_selector_is_positive'
        $workflowSource | Should Match 'issue5_residual_prefixes'
        $workflowSource | Should Match 'issue5_has_native_residual_marker'
        $workflowSource | Should Match 'issue5_required_prefixes'
        $workflowSource | Should Match 'issue5_has_required_markers'
        $workflowSource | Should Match 'gate_keys_exact'
        $readinessSource | Should Match 'Assert-GaExactGateSet'
        $readinessSource | Should Match 'Assert-GaIssue5PositiveSelector'
        $readinessSource | Should Match 'GaIssue5PlatformGateMarkerPrefixes'
        $rawLogSource | Should Match 'Assert-RawLogIssue5PositiveSelector'
        $rawLogSource | Should Match 'GaIssue5PlatformGateMarkerPrefixes'
        $readinessSource | Should Match 'windows_native_containment_job_object_and_guard'
        $readinessSource | Should Match 'macos_live_external_reconciliation'
        $rawLogSource | Should Match 'windows_native_containment_job_object_and_guard'
        $rawLogSource | Should Match 'macos_live_external_reconciliation'
        foreach ($selector in @('windows_external_json_contract_is_fail_closed_at_every_runtime_gate', 'macos_external_reconciliation_is_fail_closed_at_every_runtime_gate')) {
            $readinessSource | Should Match ([regex]::Escape($selector))
            $rawLogSource | Should Match ([regex]::Escape($selector))
            $workflowSource | Should Match ([regex]::Escape($selector))
        }
        $workflowSource | Should Match 'valid_iso_order'
        $workflowSource | Should Match 'parse_iso_instant'
        $workflowSource | Should Match 'ended_at < started_at'
        $workflowSource | Should Match 'valid_raw_content'
        $workflowSource | Should Match 'cyc.dev/ga-raw-log/v1'
        $workflowSource | Should Match 'integer_count'
        $workflowSource | Should Match '1000000000'
        $readinessSource | Should Match 'Assert-GaRawLogContent'
        $readinessSource | Should Match 'Get-GaRawLogContentJson'
        $readinessSource | Should Match 'Assert-GaRawLogContentMatch'
        $rawLogSource | Should Match 'Assert-RawLogContent'
        $rawLogSource | Should Match 'Get-RawLogContentJson'
        $rawLogSource | Should Match 'MaximumRawLogTestCount'
        $readinessSource | Should Match 'rawLogMarkers and markers aliases must match exactly'
        $rawLogSource | Should Match 'rawLogMarkers and markers aliases must match exactly'
        $readinessSource | Should Match 'rawLogMarkers must be a JSON array'
        $rawLogSource | Should Match 'rawLogMarkers is a JSON array'
        $readinessSource | Should Match 'rawLogMarkers entries must be unique'
        $rawLogSource | Should Match 'rawLogMarkers entries are unique'
        $workflowSource | Should Not Match 'valid_issue_evidence\(\.issue5'
        $workflowSource | Should Match 'valid_https_url'
        ($workflowSource.IndexOf('test("^https://[^@/?#[:space:]]+(/[^#[:space:]]*|\\?[^#[:space:]]*)?$")') -ge 0) | Should Be $true
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
        foreach ($markerPrefix in @(
                'uid=', 'gid=', 'cgroup_escape=blocked', 'cgroup.threads_escape=blocked',
                'windowsExecutionIdentityVerified=1', 'windowsJobObjectVerified=1',
                'windowsProtectedExternalGuardVerified=1', 'macosExternalReconciliationVerified=1',
                'linuxGuardTamperRejected=1', 'windowsGuardTamperRejected=1', 'macosGuardTamperRejected=1',
                'linuxWorkerCredentialIsolationVerified=1', 'windowsWorkerCredentialIsolationVerified=1',
                'macosWorkerCredentialIsolationVerified=1', 'residual_empty',
                'residualJobObjectVerified=1', 'residualExternalReconciliationVerified=1')) {
            $rawLogSource | Should Match ([regex]::Escape($markerPrefix))
            $readinessSource | Should Match ([regex]::Escape($markerPrefix))
            $workflowSource | Should Match ([regex]::Escape($markerPrefix))
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

    It 'emits invariant ISO timestamps when PowerShell materializes gate times as DateTime' {
        $manifestIssue = [pscustomobject]@{
            evidenceId = 'issue3-evidence-20260830'
        }
        $command = 'cargo test --locked --workspace'
        $startedAt = [DateTime]::Parse(
            '2026-08-30T14:00:00Z',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind)
        $endedAt = [DateTime]::Parse(
            '2026-08-30T14:01:00Z',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind)
        $gate = [pscustomobject]@{
            status = $true
            gateId = 'issue3.linuxSystemdUserServicePackage'
            sourceCommit = $expectedCommitForTest
            provider = 'ssh-external'
            hostType = 'linux-native'
            evidenceId = $manifestIssue.evidenceId
            runId = 'p1-run-20260830-01'
            node = 'p1'
            exitCode = 0
            tests = [pscustomobject]@{ passed = 1; failed = 0; ignored = 0 }
            startedAt = $startedAt
            endedAt = $endedAt
            testSelector = 'cargo test --locked --workspace'
            command = $command
            rawLogMarkers = @(
                (Get-RawLogIssue23GateMarker -IssueName 'issue3' -Gate 'linuxSystemdUserServicePackage' -Command $command)
            )
        }

        $oldCulture = [Globalization.CultureInfo]::CurrentCulture
        try {
            [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('fr-FR')
            $result = Assert-RawLogIssue23GateEvidence `
                -ManifestIssue $manifestIssue `
                -IssueName 'issue3' `
                -Gate 'linuxSystemdUserServicePackage' `
                -GateEvidence $gate `
                -ExpectedCommit $expectedCommitForTest `
                -Description 'issue3.date-time-regression'
        } finally {
            [Globalization.CultureInfo]::CurrentCulture = $oldCulture
        }

        $result.startedAt | Should Match '^2026-08-30T14:00:00\.\d{7}Z$'
        $result.endedAt | Should Match '^2026-08-30T14:01:00\.\d{7}Z$'
    }

    It 'allows raw-log contract-only checks without runtime parameters' {
        $result = Start-Process -FilePath 'pwsh' -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-File', $rawLogScript, '-ContractOnly'
        ) -Wait -PassThru -NoNewWindow
        $result.ExitCode | Should Be 0
    }

    It 'cryptographically binds Issue #5 marker commandSha256 in the stable publisher' {
        $rawLogIndex = $workflowSource.IndexOf('Test-GARawLogs.ps1')
        $hashIndex = $workflowSource.IndexOf('hashlib.sha256')
        ($rawLogIndex -ge 0 -and $hashIndex -gt $rawLogIndex) | Should Be $true
        $workflowSource | Should Match 'python3 - "\$raw_verification" <<''PY'''
        $workflowSource | Should Match 'gate_evidence'
        $workflowSource | Should Match 'normalized_command'
        $workflowSource | Should Match 're\.compile\(r"\\s\+"\)'
        $workflowSource | Should Match 'hashlib\.sha256\(normalized\.encode\("utf-8"\)\)\.hexdigest\(\)'
        $workflowSource | Should Match 'expected_marker'
        $workflowSource | Should Match 'len\(matches\) != 1'
        $workflowSource | Should Match 'binding_count != 15'
        $workflowSource | Should Match 'raw_verification_contract="\$RUNNER_TEMP/cyc-ga-raw-log-contract\.jq"'
        $workflowSource | Should Match 'cat > "\$raw_verification_contract" <<''JQ'''
        $workflowSource | Should Match 'jq -e --arg commit "\$CYC_GA_SOURCE_COMMIT" --slurpfile manifest "\$evidence_path" \\\r?\n\s*-f "\$raw_verification_contract" "\$raw_verification"'
        $workflowSource | Should Match '(?s)cat > "\$raw_verification_contract" <<''JQ''.*\r?\n\s*\(\$manifest\[0\]\).*\r?\n\s*JQ'
        $workflowSource | Should Match 'stable_ga_contract="\$RUNNER_TEMP/cyc-ga-stable-contract\.jq"'
        $workflowSource | Should Match 'cat > "\$stable_ga_contract" <<''JQ'''
        $workflowSource | Should Match 'jq -e --arg tag "\$CYC_GA_SOURCE_TAG" --arg commit "\$CYC_GA_SOURCE_COMMIT" \\\r?\n\s*-f "\$stable_ga_contract" "\$evidence_path"'
        $workflowSource | Should Not Match '-f -'
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
        $record = New-TestIssueEvidence -GateNames $issue3GateNamesForTest
        $result = Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue3 = $record }) `
            -Path 'issue3' -Description 'Issue #3 test evidence' -ExpectedCommit $expectedCommitForTest `
            -RequiredGates $issue3GateNamesForTest
        $result.status | Should Be 'passed'
        $result.rawLog.sha256 | Should Be $rawLogShaForTest
    }

    It 'accepts a complete source-bound issue 2 evidence record' {
        $record = New-TestIssueEvidence -Provider 'windows-lab' -HostType 'windows-clean-vm' -GateNames $issue2GateNamesForTest
        $result = Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue2 = $record }) `
            -Path 'issue2' -Description 'Issue #2 test evidence' -ExpectedCommit $expectedCommitForTest `
            -RequiredGates $issue2GateNamesForTest
        $result.status | Should Be 'passed'
        $result.gates.cleanWindows11Vm.status | Should Be $true
        $result.gates.noOpenUnwaivedP0P1Blocker.status | Should Be $true
        @($result.gates.noOpenUnwaivedP0P1Blocker.blockerInventory.issues).Count | Should Be 1
    }

    It 'requires a structured source-bound blocker inventory instead of a bare gate boolean' {
        $record = New-TestIssueEvidence -Provider 'windows-lab' -HostType 'windows-clean-vm' -GateNames $issue2GateNamesForTest
        { Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue2 = $record }) `
                -Path 'issue2' -Description 'Issue #2 blocker inventory positive' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue2GateNamesForTest } | Should Not Throw

        $bareBoolean = New-TestIssueEvidence -Provider 'windows-lab' -HostType 'windows-clean-vm' -GateNames $issue2GateNamesForTest
        $bareBoolean.gates.noOpenUnwaivedP0P1Blocker = $true
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue2 = $bareBoolean }) `
                -Path 'issue2' -Description 'Issue #2 bare blocker gate' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue2GateNamesForTest
        }

        $missingInventory = New-TestIssueEvidence -Provider 'windows-lab' -HostType 'windows-clean-vm' -GateNames $issue2GateNamesForTest
        [void]$missingInventory.gates.noOpenUnwaivedP0P1Blocker.PSObject.Properties.Remove('blockerInventory')
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue2 = $missingInventory }) `
                -Path 'issue2' -Description 'Issue #2 missing blocker inventory' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue2GateNamesForTest
        }
    }

    It 'parses P0/P1 labels and binds every waiver to stable scope, source, expiry, and reviewer' {
        $record = New-TestIssueEvidence -Provider 'windows-lab' -HostType 'windows-clean-vm' -GateNames $issue2GateNamesForTest
        $inventory = $record.gates.noOpenUnwaivedP0P1Blocker.blockerInventory
        $inventory.issues[0].labels[0].name = 'severity:P0'
        { Assert-GaBlockerInventory -Inventory $inventory -ExpectedCommit $expectedCommitForTest -Description 'Issue #2 P0 inventory' } | Should Not Throw

        $wrongScope = New-TestIssueEvidence -Provider 'windows-lab' -HostType 'windows-clean-vm' -GateNames $issue2GateNamesForTest
        $wrongScope.gates.noOpenUnwaivedP0P1Blocker.blockerInventory.waivers[0].scope.channel = 'preview'
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue2 = $wrongScope }) `
                -Path 'issue2' -Description 'Issue #2 preview waiver scope' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue2GateNamesForTest
        }

        $wrongReviewer = New-TestIssueEvidence -Provider 'windows-lab' -HostType 'windows-clean-vm' -GateNames $issue2GateNamesForTest
        $wrongReviewer.gates.noOpenUnwaivedP0P1Blocker.blockerInventory.waivers[0].reviewer.login = 'other-reviewer'
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue2 = $wrongReviewer }) `
                -Path 'issue2' -Description 'Issue #2 reviewer mismatch' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue2GateNamesForTest
        }

        $expiredWaiver = New-TestIssueEvidence -Provider 'windows-lab' -HostType 'windows-clean-vm' -GateNames $issue2GateNamesForTest
        $expiredWaiver.gates.noOpenUnwaivedP0P1Blocker.blockerInventory.waivers[0].expiresAt = '2020-01-01T00:00:00Z'
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue2 = $expiredWaiver }) `
                -Path 'issue2' -Description 'Issue #2 expired waiver' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue2GateNamesForTest
        }
    }

    It 'fails closed for incomplete or errored blocker API snapshots' {
        $incomplete = New-TestIssueEvidence -Provider 'windows-lab' -HostType 'windows-clean-vm' -GateNames $issue2GateNamesForTest
        $incomplete.gates.noOpenUnwaivedP0P1Blocker.blockerInventory.api.complete = $false
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue2 = $incomplete }) `
                -Path 'issue2' -Description 'Issue #2 incomplete blocker API' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue2GateNamesForTest
        }

        $nextPage = New-TestIssueEvidence -Provider 'windows-lab' -HostType 'windows-clean-vm' -GateNames $issue2GateNamesForTest
        $nextPage.gates.noOpenUnwaivedP0P1Blocker.blockerInventory.api.hasNextPage = $true
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue2 = $nextPage }) `
                -Path 'issue2' -Description 'Issue #2 paginated blocker API' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue2GateNamesForTest
        }

        $apiError = New-TestIssueEvidence -Provider 'windows-lab' -HostType 'windows-clean-vm' -GateNames $issue2GateNamesForTest
        $apiError.gates.noOpenUnwaivedP0P1Blocker.blockerInventory.api.error = 'rate limit'
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue2 = $apiError }) `
                -Path 'issue2' -Description 'Issue #2 errored blocker API' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue2GateNamesForTest
        }
    }

    It 'requires positive bounded integer raw-log counts for Issue #2 and Issue #3' {
        foreach ($badPassed in @(0, 1.5, [long]1000000001)) {
            $record = New-TestIssueEvidence -GateNames $issue3GateNamesForTest
            $record.rawLog.tests.passed = $badPassed
            Assert-TestThrows {
                Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue3 = $record }) `
                    -Path 'issue3' -Description "Issue #3 invalid passed count $badPassed" -ExpectedCommit $expectedCommitForTest `
                    -RequiredGates $issue3GateNamesForTest
            }
        }
        foreach ($badCount in @{
                field = 'failed'; value = 1.5
            }, @{
                field = 'ignored'; value = [long]1000000001
            }) {
            $record = New-TestIssueEvidence -GateNames $issue2GateNamesForTest
            $record.rawLog.tests.($badCount.field) = $badCount.value
            Assert-TestThrows {
                Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue2 = $record }) `
                    -Path 'issue2' -Description "Issue #2 invalid $($badCount.field) count" -ExpectedCommit $expectedCommitForTest `
                    -RequiredGates $issue2GateNamesForTest
            }
        }
    }

    It 'accepts a parsed source-bound raw-log content envelope' {
        $record = New-TestIssueEvidence -GateNames $issue3GateNamesForTest
        $content = New-TestRawLogContent -IssueName 'issue3' -Record $record
        $result = Assert-GaRawLogContent -Content $content -ManifestIssue $record -IssueName 'issue3' `
            -ExpectedCommit $expectedCommitForTest -EvidenceId $record.evidenceId `
            -Description 'Issue #3 parsed raw-log content'
        $result.schemaVersion | Should Be 'cyc.dev/ga-raw-log/v1'
        $result.tests.passed | Should Be 42
        $binding = Get-GaRawLogContentBinding -Content $content -IssueName 'issue3' -Description 'Issue #3 parsed raw-log content'
        $binding.node | Should Be 'p1-linux-native'
        { Assert-GaRawLogContentMatch -Expected $content -Actual $content -IssueName 'issue3' -Description 'Issue #3 content binding' } | Should Not Throw
    }

    It 'cross-binds Issue #2 raw-log content gates and blocker inventory' {
        $record = New-TestIssueEvidence -Provider 'windows-lab' -HostType 'windows-clean-vm' -GateNames $issue2GateNamesForTest
        $content = New-TestRawLogContent -IssueName 'issue2' -Record $record
        { Assert-GaRawLogContent -Content $content -ManifestIssue $record -IssueName 'issue2' `
                -ExpectedCommit $expectedCommitForTest -EvidenceId $record.evidenceId `
                -Description 'Issue #2 parsed raw-log content' } | Should Not Throw
        { Assert-GaRawLogContentMatch -Expected $content -Actual $content -IssueName 'issue2' `
                -Description 'Issue #2 content binding' } | Should Not Throw

        $wrongProvider = New-TestRawLogContent -IssueName 'issue2' -Record $record
        $wrongProvider.gates.tauriDesktopHostTray.provider = 'different-external-provider'
        Assert-TestThrows {
            Assert-GaRawLogContent -Content $wrongProvider -ManifestIssue $record -IssueName 'issue2' `
                -ExpectedCommit $expectedCommitForTest -EvidenceId $record.evidenceId `
                -Description 'Issue #2 raw content provider mismatch'
        }

        $wrongInventory = New-TestRawLogContent -IssueName 'issue2' -Record $record
        $wrongInventory.gates.noOpenUnwaivedP0P1Blocker.blockerInventory.api.complete = $false
        Assert-TestThrows {
            Assert-GaRawLogContent -Content $wrongInventory -ManifestIssue $record -IssueName 'issue2' `
                -ExpectedCommit $expectedCommitForTest -EvidenceId $record.evidenceId `
                -Description 'Issue #2 raw content incomplete blocker inventory'
        }

        $missingGate = New-TestRawLogContent -IssueName 'issue2' -Record $record
        [void]$missingGate.gates.PSObject.Properties.Remove('noOpenUnwaivedP0P1Blocker')
        Assert-TestThrows {
            Assert-GaRawLogContent -Content $missingGate -ManifestIssue $record -IssueName 'issue2' `
                -ExpectedCommit $expectedCommitForTest -EvidenceId $record.evidenceId `
                -Description 'Issue #2 raw content missing blocker gate'
        }

        $misplacedInventory = New-TestRawLogContent -IssueName 'issue2' -Record $record
        $misplacedInventory.gates.tauriDesktopHostTray | Add-Member -MemberType NoteProperty -Name blockerInventory -Value $record.gates.noOpenUnwaivedP0P1Blocker.blockerInventory
        Assert-TestThrows {
            Assert-GaRawLogContent -Content $misplacedInventory -ManifestIssue $record -IssueName 'issue2' `
                -ExpectedCommit $expectedCommitForTest -EvidenceId $record.evidenceId `
                -Description 'Issue #2 raw content misplaced blocker inventory'
        }
    }

    It 'cross-binds Issue #2 and Issue #3 raw-log verification summaries to every gate' {
        foreach ($case in @(
                @{ issue = 'issue2'; gates = $issue2GateNamesForTest; provider = 'windows-lab'; hostType = 'windows-clean-vm' },
                @{ issue = 'issue3'; gates = $issue3GateNamesForTest; provider = 'macos-lab'; hostType = 'macos-clean-host' }
            )) {
            $record = New-TestIssueEvidence -Provider $case.provider -HostType $case.hostType -GateNames $case.gates
            $manifestContract = Assert-GaIssue23Evidence -Node $record -IssueName $case.issue -ExpectedCommit $expectedCommitForTest -Description "$($case.issue) raw-summary manifest"
            $rawSummary = [pscustomobject]@{
                markersVerified = $true
                markers = $manifestContract.markers
                gateEvidence = $manifestContract.gates
            }
            { Assert-GaIssue23RawVerification -ManifestIssue $record -RawRecord $rawSummary -IssueName $case.issue -ExpectedCommit $expectedCommitForTest -Description "$($case.issue) raw-summary positive" } | Should Not Throw

            $badSummary = (($rawSummary | ConvertTo-Json -Depth 30) | ConvertFrom-Json)
            $badSummary.gateEvidence[0].command = 'tampered-command'
            Assert-TestThrows {
                Assert-GaIssue23RawVerification -ManifestIssue $record -RawRecord $badSummary -IssueName $case.issue -ExpectedCommit $expectedCommitForTest -Description "$($case.issue) raw-summary command mismatch"
            }
            if ($case.issue -ceq 'issue2') {
                $missingInventory = (($rawSummary | ConvertTo-Json -Depth 30) | ConvertFrom-Json)
                $blockerRecord = @($missingInventory.gateEvidence | Where-Object { [string]$_.gate -ceq 'noOpenUnwaivedP0P1Blocker' })[0]
                [void]$blockerRecord.PSObject.Properties.Remove('blockerInventory')
                Assert-TestThrows {
                    Assert-GaIssue23RawVerification -ManifestIssue $record -RawRecord $missingInventory -IssueName $case.issue -ExpectedCommit $expectedCommitForTest -Description "$($case.issue) raw-summary missing blocker inventory"
                }
            }
        }
    }

    It 'keeps the downloader raw-log content validator positive and fail-closed' {
        $record = New-TestIssueEvidence -GateNames $issue3GateNamesForTest
        $content = New-TestRawLogContent -IssueName 'issue3' -Record $record
        { Assert-RawLogContent -Content $content -ManifestIssue $record -IssueName 'issue3' `
                -ExpectedCommit $expectedCommitForTest -EvidenceId $record.evidenceId `
                -Description 'Issue #3 downloader content' } | Should Not Throw
        foreach ($badCount in @(0, 1.5, [long]1000000001)) {
            $badContent = New-TestRawLogContent -IssueName 'issue3' -Record $record
            $badContent.tests.passed = $badCount
            Assert-TestThrows {
                Assert-RawLogContent -Content $badContent -ManifestIssue $record -IssueName 'issue3' `
                    -ExpectedCommit $expectedCommitForTest -EvidenceId $record.evidenceId `
                    -Description "Issue #3 downloader invalid count $badCount"
            }
        }
        $badContent = New-TestRawLogContent -IssueName 'issue3' -Record $record
        $badContent.command = 'different command'
        Assert-TestThrows {
            Assert-RawLogContent -Content $badContent -ManifestIssue $record -IssueName 'issue3' `
                -ExpectedCommit $expectedCommitForTest -EvidenceId $record.evidenceId `
                -Description 'Issue #3 downloader command mismatch'
        }
    }

    It 'requires source-bound Issue #5 markers in the downloaded JSON envelope' {
        $record = New-TestIssue5Evidence
        $content = New-TestRawLogContent -IssueName 'issue5' -Record $record
        { Assert-RawLogContent -Content $content -ManifestIssue $record -IssueName 'issue5' `
                -ExpectedCommit $expectedCommitForTest -EvidenceId $record.evidenceId `
                -Description 'Issue #5 downloader content' } | Should Not Throw

        $missingMarker = New-TestRawLogContent -IssueName 'issue5' -Record $record
        $missingMarker.markers = @($missingMarker.markers | Select-Object -Skip 1)
        Assert-TestThrows {
            Assert-RawLogContent -Content $missingMarker -ManifestIssue $record -IssueName 'issue5' `
                -ExpectedCommit $expectedCommitForTest -EvidenceId $record.evidenceId `
                -Description 'Issue #5 downloader missing marker'
        }

        $duplicateMarker = New-TestRawLogContent -IssueName 'issue5' -Record $record
        $duplicateMarker.markers = @($duplicateMarker.markers) + @($duplicateMarker.markers[0])
        Assert-TestThrows {
            Assert-RawLogContent -Content $duplicateMarker -ManifestIssue $record -IssueName 'issue5' `
                -ExpectedCommit $expectedCommitForTest -EvidenceId $record.evidenceId `
                -Description 'Issue #5 downloader duplicate marker'
        }

        $wrongMarker = New-TestRawLogContent -IssueName 'issue5' -Record $record
        $wrongMarker.markers[0] = 'unbound-marker'
        Assert-TestThrows {
            Assert-RawLogContent -Content $wrongMarker -ManifestIssue $record -IssueName 'issue5' `
                -ExpectedCommit $expectedCommitForTest -EvidenceId $record.evidenceId `
                -Description 'Issue #5 downloader unbound marker'
        }
    }

    It 'rejects empty, arbitrary, and non-object downloaded raw-log content' {
        $path = Join-Path ([IO.Path]::GetTempPath()) ('cyc-ga-raw-content-' + [Guid]::NewGuid().ToString('N') + '.json')
        try {
            Set-Content -LiteralPath $path -Value '' -Encoding UTF8
            Assert-TestThrows { Get-RawLogContentJson -Path $path -Description 'empty raw-log content' }
            Set-Content -LiteralPath $path -Value '{"arbitrary":true}' -Encoding UTF8
            $arbitrary = Get-RawLogContentJson -Path $path -Description 'arbitrary raw-log content'
            Assert-TestThrows {
                Assert-RawLogContent -Content $arbitrary -ManifestIssue (New-TestIssueEvidence) -IssueName 'issue3' `
                    -ExpectedCommit $expectedCommitForTest -EvidenceId 'ga-issue2-live-20260830' `
                    -Description 'arbitrary raw-log content'
            }
            Set-Content -LiteralPath $path -Value '[]' -Encoding UTF8
            Assert-TestThrows { Get-RawLogContentJson -Path $path -Description 'array raw-log content' }
            Set-Content -LiteralPath $path -Value 'not-json' -Encoding UTF8
            Assert-TestThrows { Get-RawLogContentJson -Path $path -Description 'malformed raw-log content' }
        } finally {
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force
            }
        }
    }

    It 'rejects raw-log content command, host, exit, count, source, and cleanup mismatches' {
        $mutations = @(
            @{ field = 'command'; value = 'cargo test --manifest-path /different/Cargo.toml --locked' },
            @{ field = 'node'; value = 'another-external-node' },
            @{ field = 'exitCode'; value = 1 },
            @{ field = 'sourceCommit'; value = ('c' * 40) -join '' },
            @{ field = 'issue'; value = 'issue2' },
            @{ field = 'evidenceId'; value = 'different-evidence' },
            @{ field = 'cleanup'; value = $false }
        )
        foreach ($mutation in $mutations) {
            $record = New-TestIssueEvidence -GateNames $issue3GateNamesForTest
            $content = New-TestRawLogContent -IssueName 'issue3' -Record $record
            $content.($mutation.field) = $mutation.value
            Assert-TestThrows {
                Assert-GaRawLogContent -Content $content -ManifestIssue $record -IssueName 'issue3' `
                    -ExpectedCommit $expectedCommitForTest -EvidenceId $record.evidenceId `
                    -Description "Issue #3 content mismatch $($mutation.field)"
            }
        }
        foreach ($badCount in @(0, 1.5, [long]1000000001)) {
            $record = New-TestIssueEvidence -GateNames $issue3GateNamesForTest
            $content = New-TestRawLogContent -IssueName 'issue3' -Record $record
            $content.tests.passed = $badCount
            Assert-TestThrows {
                Assert-GaRawLogContent -Content $content -ManifestIssue $record -IssueName 'issue3' `
                    -ExpectedCommit $expectedCommitForTest -EvidenceId $record.evidenceId `
                    -Description "Issue #3 content invalid test count $badCount"
            }
        }
        $record = New-TestIssueEvidence -GateNames $issue3GateNamesForTest
        $content = New-TestRawLogContent -IssueName 'issue3' -Record $record
        $content | Add-Member -MemberType NoteProperty -Name host -Value 'p1-linux-native'
        [void]$content.PSObject.Properties.Remove('node')
        { Assert-GaRawLogContent -Content $content -ManifestIssue $record -IssueName 'issue3' `
                -ExpectedCommit $expectedCommitForTest -EvidenceId $record.evidenceId `
                -Description 'Issue #3 host alias content' } | Should Not Throw
        $content.host = 'different-host'
        Assert-TestThrows {
            Assert-GaRawLogContent -Content $content -ManifestIssue $record -IssueName 'issue3' `
                -ExpectedCommit $expectedCommitForTest -EvidenceId $record.evidenceId `
                -Description 'Issue #3 host alias mismatch'
        }
    }

    It 'rejects unknown gate keys in the closed Issue #2 and Issue #3 maps' {
        $record = New-TestIssueEvidence -GateNames $issue2GateNamesForTest
        $record.gates | Add-Member -MemberType NoteProperty -Name 'unreviewedIssue2Gate' -Value $true
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue2 = $record }) `
                -Path 'issue2' -Description 'Issue #2 unknown gate key' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue2GateNamesForTest
        }

        $record = New-TestIssueEvidence -GateNames $issue3GateNamesForTest
        $record.gates | Add-Member -MemberType NoteProperty -Name 'unreviewedIssue3Gate' -Value $true
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue3 = $record }) `
                -Path 'issue3' -Description 'Issue #3 unknown gate key' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue3GateNamesForTest
        }
    }

    It 'accepts a complete source-bound issue 5 evidence record' {
        $record = New-TestIssue5Evidence
        $result = Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue5 = $record }) `
            -Path 'issue5' -Description 'Issue #5 test evidence' -ExpectedCommit $expectedCommitForTest `
            -RequiredGates $issue5GateNamesForTest
        $result.status | Should Be 'passed'
    }

    It 'accepts downloaded Issue #5 verification for single and matrix gates' {
        $manifest = New-TestIssue5Evidence
        $contract = Assert-GaIssue5Evidence -Node $manifest -Description 'Issue #5 raw verification fixture' -RequiredGates $issue5GateNamesForTest
        $rawRecord = [pscustomobject]@{
            markersVerified = $true
            platforms = @('linux', 'windows', 'macos')
            markers = @($contract.markers)
            gateEvidence = @($contract.gates)
        }
        { Assert-GaIssue5RawVerification -ManifestIssue $manifest -RawRecord $rawRecord -Description 'Issue #5 raw verification fixture' } | Should Not Throw
    }

    It 'rejects fail-closed Windows and macOS selectors as Issue #5 completion evidence' {
        $record = New-TestIssue5Evidence
        $record.gates.windowsJobObject.testSelector = 'isolation::tests::windows_external_json_contract_is_fail_closed_at_every_runtime_gate'
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue5 = $record }) `
                -Path 'issue5' -Description 'Issue #5 fail-closed Windows selector' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue5GateNamesForTest
        }

        $record = New-TestIssue5Evidence
        $record.gates.macosExternalReconciliation.testSelector = 'isolation::tests::macos_external_reconciliation_is_fail_closed_at_every_runtime_gate'
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue5 = $record }) `
                -Path 'issue5' -Description 'Issue #5 fail-closed macOS selector' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue5GateNamesForTest
        }
    }

    It 'requires a platform-native residual marker on Windows and macOS restart rows' {
        $record = New-TestIssue5Evidence
        $windowsRun = $record.gates.restartResidualProcessReconciliation.runs[1]
        $windowsRun.rawLogMarkers = @($windowsRun.rawLogMarkers | Where-Object {
                ([string]$_) -cne 'residualJobObjectVerified=1' -and
                ([string]$_) -cne 'residualProcessGroupVerified=1'
            })
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue5 = $record }) `
                -Path 'issue5' -Description 'Issue #5 missing Windows residual marker' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue5GateNamesForTest
        }

        $record = New-TestIssue5Evidence
        $macosRun = $record.gates.restartResidualProcessReconciliation.runs[2]
        $macosRun.rawLogMarkers = @($macosRun.rawLogMarkers | Where-Object {
                ([string]$_) -cne 'residualProcessGroupVerified=1' -and
                ([string]$_) -cne 'residualExternalReconciliationVerified=1'
            })
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue5 = $record }) `
                -Path 'issue5' -Description 'Issue #5 missing macOS residual marker' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue5GateNamesForTest
        }
    }

    It 'rejects conflicting Issue #5 selector and marker aliases' {
        $record = New-TestIssue5Evidence
        $record.gates.windowsJobObject | Add-Member -MemberType NoteProperty -Name selector -Value 'isolation::tests::wrong_selector'
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue5 = $record }) `
                -Path 'issue5' -Description 'Issue #5 selector alias conflict' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue5GateNamesForTest
        }

        $record = New-TestIssue5Evidence
        $record.gates.windowsJobObject | Add-Member -MemberType NoteProperty -Name markers -Value @('conflicting-marker')
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue5 = $record }) `
                -Path 'issue5' -Description 'Issue #5 marker alias conflict' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue5GateNamesForTest
        }
    }

    It 'rejects scalar, non-string, duplicate, and empty Issue #5 gate markers' {
        $record = New-TestIssue5Evidence
        $record.gates.windowsJobObject.rawLogMarkers = 'scalar-marker'
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue5 = $record }) `
                -Path 'issue5' -Description 'Issue #5 scalar gate marker' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue5GateNamesForTest
        }

        $record = New-TestIssue5Evidence
        $record.gates.windowsJobObject | Add-Member -MemberType NoteProperty -Name markers -Value @([int]7)
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue5 = $record }) `
                -Path 'issue5' -Description 'Issue #5 numeric marker alias' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue5GateNamesForTest
        }

        $record = New-TestIssue5Evidence
        $record.gates.windowsJobObject.rawLogMarkers = @($record.gates.windowsJobObject.rawLogMarkers) + @([string]$record.gates.windowsJobObject.rawLogMarkers[0])
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue5 = $record }) `
                -Path 'issue5' -Description 'Issue #5 duplicate gate marker' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue5GateNamesForTest
        }

        $record = New-TestIssue5Evidence
        $record.gates.windowsJobObject.rawLogMarkers = @($record.gates.windowsJobObject.rawLogMarkers) + @('')
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue5 = $record }) `
                -Path 'issue5' -Description 'Issue #5 empty gate marker' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue5GateNamesForTest
        }
    }

    It 'keeps the raw-log marker helper type-sensitive and unique' {
        $record = New-TestIssue5Evidence
        $gate = $record.gates.windowsJobObject
        @(Get-RawLogIssue5GateMarkers -GateEvidence $gate -Description 'raw helper baseline').Count | Should BeGreaterThan 0

        $gate.rawLogMarkers = 'scalar-marker'
        Assert-TestThrows { Get-RawLogIssue5GateMarkers -GateEvidence $gate -Description 'raw helper scalar' }

        $record = New-TestIssue5Evidence
        $gate = $record.gates.windowsJobObject
        $gate | Add-Member -MemberType NoteProperty -Name markers -Value @([int]7)
        Assert-TestThrows { Get-RawLogIssue5GateMarkers -GateEvidence $gate -Description 'raw helper numeric alias' }

        $record = New-TestIssue5Evidence
        $gate = $record.gates.windowsJobObject
        $gate.rawLogMarkers = @($gate.rawLogMarkers) + @([string]$gate.rawLogMarkers[0])
        Assert-TestThrows { Get-RawLogIssue5GateMarkers -GateEvidence $gate -Description 'raw helper duplicate' }

        $record = New-TestIssue5Evidence
        $gate = $record.gates.windowsJobObject
        $gate.rawLogMarkers = @($gate.rawLogMarkers) + @('')
        Assert-TestThrows { Get-RawLogIssue5GateMarkers -GateEvidence $gate -Description 'raw helper empty' }
    }

    It 'requires platform-native Issue #5 markers for Windows and macOS gates' {
        $record = New-TestIssue5Evidence
        $record.gates.windowsJobObject.rawLogMarkers = @($record.gates.windowsJobObject.rawLogMarkers |
            Where-Object { ([string]$_) -cne 'windowsJobObjectVerified=1' })
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue5 = $record }) `
                -Path 'issue5' -Description 'Issue #5 missing Windows Job Object marker' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue5GateNamesForTest
        }

        $record = New-TestIssue5Evidence
        $record.gates.macosExternalReconciliation.rawLogMarkers = @($record.gates.macosExternalReconciliation.rawLogMarkers |
            Where-Object { ([string]$_) -cne 'macosExternalReconciliationVerified=1' })
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue5 = $record }) `
                -Path 'issue5' -Description 'Issue #5 missing macOS native marker' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue5GateNamesForTest
        }

        $record = New-TestIssue5Evidence
        $windowsRun = $record.gates.jobsCannotAlterGuardState.runs[1]
        $windowsRun.rawLogMarkers = @($windowsRun.rawLogMarkers |
            Where-Object { ([string]$_) -cne 'windowsGuardTamperRejected=1' })
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue5 = $record }) `
                -Path 'issue5' -Description 'Issue #5 missing Windows tamper marker' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue5GateNamesForTest
        }
    }

    It 'requires source-bound provenance on every Issue #5 run' {
        $record = New-TestIssue5Evidence
        [void]$record.gates.jobsCannotReadWorkerCredentials.runs[0].PSObject.Properties.Remove('runId')
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue5 = $record }) `
                -Path 'issue5' -Description 'Issue #5 missing run provenance' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue5GateNamesForTest
        }

        $record = New-TestIssue5Evidence
        $record.gates.windowsJobObject.provider = 'github-actions'
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue5 = $record }) `
                -Path 'issue5' -Description 'Issue #5 hosted run provenance' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue5GateNamesForTest
        }

        $record = New-TestIssue5Evidence
        $record.gates.macosExternalReconciliation.tests.failed = 1
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue5 = $record }) `
                -Path 'issue5' -Description 'Issue #5 failed run provenance' -ExpectedCommit $expectedCommitForTest `
            -RequiredGates $issue5GateNamesForTest
        }
    }

    It 'rejects non-string Issue #5 provenance identifiers before normalization' {
        foreach ($field in @('runId', 'node', 'provider', 'hostType')) {
            $record = New-TestIssue5Evidence
            if ($field -ceq 'runId') {
                $record.gates.windowsJobObject.runId = 123
            } elseif ($field -ceq 'node') {
                $record.gates.windowsJobObject.node = $false
            } elseif ($field -ceq 'provider') {
                $record.gates.windowsJobObject.provider = 456
            } else {
                $record.gates.windowsJobObject.hostType = $null
            }
            Assert-TestThrows {
                Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue5 = $record }) `
                    -Path 'issue5' -Description "Issue #5 non-string $field" -ExpectedCommit $expectedCommitForTest `
                    -RequiredGates $issue5GateNamesForTest
            }
        }
    }

    It 'rejects duplicate matrix run IDs and cross-platform run ID reuse' {
        $record = New-TestIssue5Evidence
        $record.gates.jobsCannotAlterGuardState.runs[1].runId = $record.gates.jobsCannotAlterGuardState.runs[0].runId
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue5 = $record }) `
                -Path 'issue5' -Description 'Issue #5 duplicate matrix run ID' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue5GateNamesForTest
        }

        $record = New-TestIssue5Evidence
        $record.gates.windowsJobObject.runId = $record.gates.linuxDedicatedExecutionIdentity.runId
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue5 = $record }) `
                -Path 'issue5' -Description 'Issue #5 cross-platform run ID reuse' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue5GateNamesForTest
        }
    }

    It 'rejects non-string and duplicate aggregate Issue #5 markers' {
        $record = New-TestIssue5Evidence
        $record.rawLog.markers = @($record.rawLog.markers) + @(99)
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue5 = $record }) `
                -Path 'issue5' -Description 'Issue #5 numeric aggregate marker' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue5GateNamesForTest
        }

        $record = New-TestIssue5Evidence
        $record.rawLog.markers = @($record.rawLog.markers) + @([string]$record.rawLog.markers[0])
        Assert-TestThrows {
            Assert-GaIssueEvidence -Evidence ([pscustomobject]@{ issue5 = $record }) `
                -Path 'issue5' -Description 'Issue #5 duplicate aggregate marker' -ExpectedCommit $expectedCommitForTest `
                -RequiredGates $issue5GateNamesForTest
        }
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
