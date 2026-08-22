#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Get-ValidatedNodeExecutable {
    param(
        [string]$ExpectedVersion = 'v24.19.0',
        [string]$ExpectedArchitecture = 'x64'
    )

    $commands = @(Get-Command -Name 'node.exe' -CommandType Application -All -ErrorAction Stop)
    $seen = @{}
    $observed = New-Object System.Collections.Generic.List[string]
    foreach ($command in $commands) {
        $candidate = [string]$command.Path
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            $candidate = [string]$command.Source
        }
        if ([string]::IsNullOrWhiteSpace($candidate) -or
            -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }

        $resolved = [string](Resolve-Path -LiteralPath $candidate -ErrorAction Stop).ProviderPath
        if ([System.IO.Path]::GetFileName($resolved) -ine 'node.exe' -or $seen.ContainsKey($resolved)) {
            continue
        }
        $seen[$resolved] = $true

        try {
            $identityOutput = @(& $resolved --print 'JSON.stringify({version:process.version,architecture:process.arch})' 2>&1)
            $identityExitCode = $LASTEXITCODE
            $identity = (($identityOutput | ForEach-Object { [string]$_ }) -join '').Trim() | ConvertFrom-Json
            $version = [string]$identity.version
            $architecture = [string]$identity.architecture
            [void]$observed.Add("$resolved ($version, $architecture, exit $identityExitCode)")
            if ($identityExitCode -eq 0 -and
                $version -eq $ExpectedVersion -and
                $architecture -eq $ExpectedArchitecture) {
                return $resolved
            }
        } catch {
            [void]$observed.Add("$resolved (identity probe failed: $($_.Exception.Message))")
        }
    }

    $details = if ($observed.Count -gt 0) { $observed -join '; ' } else { 'no usable node.exe candidates' }
    throw "No node.exe Application matched Node.js $ExpectedVersion/$ExpectedArchitecture. Observed: $details"
}

$bootstrap = Join-Path $PSScriptRoot 'bootstrap.ps1'
. $bootstrap

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('cyc-packaging-test-' + [Guid]::NewGuid().ToString('N'))
$payload = Join-Path $testRoot 'payload'
$install = Join-Path $testRoot 'install'
$data = Join-Path $testRoot 'data'
try {
    [void](New-Item -ItemType Directory -Path $payload -Force)
    foreach ($name in @('ClusterYourCodex.exe', 'cyc-controller.exe', 'cyc.exe', 'cyc-worker.exe')) {
        [System.IO.File]::WriteAllText((Join-Path $payload $name), "fixture-$name")
    }
    $marketplace = Join-Path $payload 'integrations\codex-marketplace\.agents\plugins'
    $plugin = Join-Path $payload 'integrations\codex-marketplace\plugins\cluster-your-codex'
    [void](New-Item -ItemType Directory -Path $marketplace -Force)
    [void](New-Item -ItemType Directory -Path $plugin -Force)
    [System.IO.File]::WriteAllText((Join-Path $marketplace 'marketplace.json'), '{"name":"clusteryourcodex"}')
    $requiredPluginFixtures = @(
        '.codex-plugin\plugin.json',
        '.mcp.json',
        'skills\cluster-your-codex\SKILL.md',
        'mcp\dist\server.js',
        'mcp\runtime\node.exe',
        'mcp\runtime\LICENSE.node.txt'
    )
    foreach ($relative in $requiredPluginFixtures) {
        $fixture = Join-Path $plugin $relative
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $fixture) -Force)
        [System.IO.File]::WriteAllText($fixture, "fixture-$relative")
    }

    $plan = Get-InstallPlan `
        -BundleRoot $payload `
        -InstallRoot $install `
        -DataRoot $data `
        -EnableWorker `
        -WorkerConfig (Join-Path $data 'worker\config.json')

    Assert-True ($plan.schemaVersion -eq 'cyc.dev/windows-install-manifest/v1') 'plan schema'
    Assert-True ($plan.files.Count -eq @(Get-PayloadFiles -Root $payload).Count) 'all payload files are owned'
    Assert-True ($plan.files.sha256 -notcontains $null) 'every file has a digest'
    Assert-True ($plan.tasks[0].action.arguments -match '^--bind 127\.0\.0\.1:47831 ') 'controller bind is explicit loopback'
    Assert-True ($plan.tasks[0].action.arguments -match '--database "[^\"]+\\controller\.db"') 'controller database path is explicit'
    Assert-True ($plan.tasks[0].action.arguments -match '--token-file "[^\"]+\\controller\.token"') 'controller gets only the token file path'
    Assert-True ($plan.tasks[0].action.arguments -notmatch '(?i)Bearer|authorization|--token\s') 'controller task has no raw token'
    Assert-True ($plan.tasks[1].action.arguments -match '^run --config ') 'worker gets only its config path'
    Assert-True ($plan.tasks[1].action.arguments -notmatch '(?i)token|secret|credential') 'worker task has no secret material'
    Assert-True $plan.codexIntegration.available 'complete marketplace payload is detected'
    Assert-True ($plan.codexIntegration.plugin -eq 'cluster-your-codex@clusteryourcodex') 'Codex plugin identity'
    Assert-True ($plan.codexIntegration.marketplaceManifest.EndsWith('.agents\plugins\marketplace.json')) 'complete marketplace root contract'

    $pluginFixture = Join-Path $plugin '.mcp.json'
    Remove-Item -LiteralPath $pluginFixture -Force
    $partialMarketplaceRejected = $false
    try {
        [void](Get-InstallPlan -BundleRoot $payload -InstallRoot $install -DataRoot $data)
    } catch { $partialMarketplaceRejected = $true }
    Assert-True $partialMarketplaceRejected 'partial marketplace payload is rejected'
    [System.IO.File]::WriteAllText($pluginFixture, 'fixture')

    $source = Get-Content -LiteralPath $bootstrap -Raw
    Assert-True ($source -notmatch '(?i)CYC_CONTROLLER_TOKEN=') 'no token environment injection'
    Assert-True ($source -notmatch '(?i)--token\s') 'no raw token command argument'
    Assert-True ($source -match 'AreAccessRulesProtected') 'ACL inheritance is verified'
    Assert-True ($source -match 'Assert-SafePurgeTarget') 'recursive purge is guarded'
    Assert-True ($source -match 'Stop-CycRuntime') 'owned runtime is stopped before replacement'
    Assert-True ($source -match 'Restore-FileRollbackSnapshot') 'failed replacement has file rollback'
    Assert-True ($source -match 'Restore-CycTaskSnapshots') 'failed replacement has task rollback'
    Assert-True ($source -match 'Wait-CycTaskStable') 'Scheduled Tasks require a stable running window'
    Assert-True ($source -match 'LastTaskResult') 'Scheduled Task health checks LastTaskResult'
    Assert-True ($source -match 'Test-CycWorkerStatus') 'worker readiness runs cyc-worker status'
    Assert-True ($source -match 'Write-CodexCleanupState') 'failed Codex cleanup is persisted for retry'
    Assert-True ($source -match 'Write-DurableAtomicJson') 'Codex cleanup checkpoints use an atomic writer'
    Assert-True ($source -match 'Flush\(\$true\)') 'Codex cleanup checkpoints force durable file flushes'
    Assert-True ($source -match 'CleanupCheckpoint') 'Codex cleanup checkpoints after each successful external step'

    [void](New-Item -ItemType Directory -Path $install -Force)
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $plan.manifestPath) -Force)
    [System.IO.File]::WriteAllText((Join-Path $install 'cyc-controller.exe'), 'old-controller')
    [System.IO.File]::WriteAllText($plan.manifestPath, 'old-manifest')
    $oldManifest = [PSCustomObject]@{
        files = @([PSCustomObject]@{ relativePath = 'cyc-controller.exe' })
    }
    $rollback = New-FileRollbackSnapshot -Plan $plan -OldManifest $oldManifest
    [System.IO.File]::WriteAllText((Join-Path $install 'cyc-controller.exe'), 'new-controller')
    [System.IO.File]::WriteAllText((Join-Path $install 'cyc.exe'), 'new-cli')
    [System.IO.File]::WriteAllText($plan.manifestPath, 'new-manifest')
    Restore-FileRollbackSnapshot -Snapshot $rollback
    Assert-True ((Get-Content -LiteralPath (Join-Path $install 'cyc-controller.exe') -Raw) -eq 'old-controller') 'old binary is restored'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $install 'cyc.exe'))) 'new binary is removed on rollback'
    Assert-True ((Get-Content -LiteralPath $plan.manifestPath -Raw) -eq 'old-manifest') 'old manifest is restored'
    Remove-FileRollbackSnapshot -Snapshot $rollback

    $escaped = $false
    try {
        [void](Assert-ChildPath -Root $install -Candidate (Join-Path $install '..\outside.txt'))
    } catch { $escaped = $true }
    Assert-True $escaped 'path traversal is rejected'

    $absentUninstall = Invoke-Uninstall `
        -InstallRoot (Join-Path $testRoot 'absent-install') `
        -DataRoot (Join-Path $testRoot 'absent-data')
    Assert-True $absentUninstall.alreadyAbsent 'repeated default uninstall is an idempotent no-op'
    Assert-True $absentUninstall.dataPreserved 'idempotent uninstall does not remove unowned data'

    $aclRoot = Join-Path $testRoot 'acl-smoke'
    $aclChild = Join-Path $aclRoot 'sensitive'
    $aclFile = Join-Path $aclChild 'controller.token'
    [void](New-Item -ItemType Directory -Path $aclChild -Force)
    [System.IO.File]::WriteAllText($aclFile, 'fixture-token')
    foreach ($aclPath in @($aclRoot, $aclChild, $aclFile)) {
        $grant = if ((Get-Item -LiteralPath $aclPath -Force).PSIsContainer) {
            '*S-1-1-0:(OI)(CI)(R)'
        } else {
            '*S-1-1-0:(R)'
        }
        & icacls.exe $aclPath /grant $grant *> $null
        Assert-True ($LASTEXITCODE -eq 0) 'test fixture injects an explicit Everyone Allow ACE'
    }
    Set-PrivateDirectoryAcl -Path $aclRoot
    foreach ($aclPath in @($aclRoot, $aclChild, $aclFile)) {
        Assert-PrivatePathAcl -Path $aclPath
    }
    & icacls.exe $aclFile /grant '*S-1-1-0:(R)' *> $null
    Assert-True ($LASTEXITCODE -eq 0) 'test fixture injects an explicit Everyone Allow ACE'
    $weakAclRejected = $false
    try { Assert-PrivatePathAcl -Path $aclFile } catch { $weakAclRejected = $true }
    Assert-True $weakAclRejected 'repair detects a regressed sensitive-file DACL'
    Set-PrivateDirectoryAcl -Path $aclRoot
    Assert-PrivatePathAcl -Path $aclFile

    $script:FakeTaskResult = 267009
    function Get-ScheduledTask { [PSCustomObject]@{ State = 'Running' } }
    function Get-ScheduledTaskInfo { [PSCustomObject]@{ LastTaskResult = $script:FakeTaskResult } }
    try {
        Wait-CycTaskStable -Name 'fixture-task' -TimeoutSeconds 1 -StableSeconds 0
        $script:FakeTaskResult = 5
        $taskFailureDetected = $false
        try { Wait-CycTaskStable -Name 'fixture-task' -TimeoutSeconds 1 -StableSeconds 0 } catch { $taskFailureDetected = $true }
        Assert-True $taskFailureDetected 'non-success LastTaskResult fails task readiness'
    } finally {
        Remove-Item Function:\Get-ScheduledTask -Force
        Remove-Item Function:\Get-ScheduledTaskInfo -Force
        Remove-Variable FakeTaskResult -Scope Script -ErrorAction SilentlyContinue
    }

    $fakeWorker = Join-Path $testRoot 'fake-worker.cmd'
    [System.IO.File]::WriteAllText(
        $fakeWorker,
        "@echo off`r`necho {`"paired`":true,`"credentialProtected`":true}`r`nexit /b 0`r`n"
    )
    Test-CycWorkerStatus `
        -Action ([PSCustomObject]@{ executable = $fakeWorker }) `
        -Config (Join-Path $data 'worker\config.json')

    $fakeCodexBin = Join-Path $testRoot 'fake-codex-bin'
    $fakeCodex = Join-Path $fakeCodexBin 'codex.cmd'
    $fakeCodexLog = Join-Path $testRoot 'fake-codex.log'
    [void](New-Item -ItemType Directory -Path $fakeCodexBin -Force)
    [System.IO.File]::WriteAllText(
        $fakeCodex,
        "@echo off`r`necho %*>>`"%CYC_FAKE_CODEX_LOG%`"`r`nif /I `"%2`"==`"marketplace`" if /I `"%3`"==`"remove`" exit /b 9`r`nexit /b 0`r`n"
    )
    $codexInstall = Join-Path $testRoot 'codex-install'
    $codexData = Join-Path $testRoot 'codex-data'
    $codexManifest = Join-Path $codexData '.installer\install-manifest.json'
    [void](New-Item -ItemType Directory -Path $codexInstall, (Split-Path -Parent $codexManifest) -Force)
    [System.IO.File]::WriteAllText((Join-Path $codexInstall 'cyc.exe'), 'owned-cli')
    [ordered]@{
        schemaVersion = 'cyc.dev/windows-install-manifest/v1'
        installRoot = $codexInstall
        dataRoot = $codexData
        files = @([ordered]@{ relativePath = 'cyc.exe'; sha256 = 'fixture'; length = 9 })
        tasks = @()
        codexIntegration = [ordered]@{
            enabled = $true
            available = $true
            marketplaceRoot = (Join-Path $codexInstall 'integrations\codex-marketplace')
            plugin = 'cluster-your-codex@clusteryourcodex'
            attempted = $true
            cliFound = $true
            succeeded = $true
            marketplaceAdded = $true
            pluginAdded = $true
        }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $codexManifest -Encoding UTF8
    $oldPath = $env:PATH
    $oldCodexLog = $env:CYC_FAKE_CODEX_LOG
    try {
        $env:PATH = $fakeCodexBin + [System.IO.Path]::PathSeparator + $oldPath
        $env:CYC_FAKE_CODEX_LOG = $fakeCodexLog
        $cleanupFailureDetected = $false
        try { [void](Invoke-Uninstall -InstallRoot $codexInstall -DataRoot $codexData) } catch { $cleanupFailureDetected = $true }
        Assert-True $cleanupFailureDetected 'Codex cleanup failure makes uninstall explicitly fail'
        Assert-True (Test-Path -LiteralPath (Join-Path $codexInstall 'cyc.exe') -PathType Leaf) 'core install remains intact after Codex cleanup failure'
        Assert-True (Test-Path -LiteralPath $codexManifest -PathType Leaf) 'manifest remains for Codex cleanup retry'
        $pendingManifest = Get-Content -LiteralPath $codexManifest -Raw | ConvertFrom-Json
        Assert-True $pendingManifest.codexIntegration.cleanup.pluginRemoved 'successful plugin removal is recorded'
        Assert-True (-not $pendingManifest.codexIntegration.cleanup.marketplaceRemoved) 'failed marketplace removal is recorded'
        Assert-True (-not $pendingManifest.codexIntegration.cleanup.succeeded) 'partial cleanup is not reported as success'

        [System.IO.File]::WriteAllText(
            $fakeCodex,
            "@echo off`r`necho %*>>`"%CYC_FAKE_CODEX_LOG%`"`r`nexit /b 0`r`n"
        )
        $retryPlan = [PSCustomObject]@{ codexIntegration = $pendingManifest.codexIntegration }
        $retryCheckpoint = {
            param($result)
            Write-CodexCleanupState `
                -Manifest $pendingManifest `
                -ManifestPath $codexManifest `
                -Result $result
        }
        $retryResult = Invoke-CodexIntegration `
            -Plan $retryPlan `
            -Operation Uninstall `
            -CleanupCheckpoint $retryCheckpoint
        Assert-True $retryResult.succeeded 'Codex cleanup retry succeeds'
        Assert-True $retryResult.pluginRemoved 'retry preserves the completed plugin-removal step'
        Assert-True $retryResult.marketplaceRemoved 'retry completes marketplace removal'
        $codexCalls = @(Get-Content -LiteralPath $fakeCodexLog)
        Assert-True ($codexCalls.Count -eq 3) 'retry skips the already successful plugin-removal step'
        Assert-True ($codexCalls[-1] -match '^plugin marketplace remove ') 'retry invokes only pending marketplace cleanup'

        # Simulate a process interruption immediately after the first external
        # cleanup succeeds and its manifest checkpoint becomes durable. A new
        # invocation must load that checkpoint and skip the completed step.
        Clear-Content -LiteralPath $fakeCodexLog
        [ordered]@{
            schemaVersion = 'cyc.dev/windows-install-manifest/v1'
            installRoot = $codexInstall
            dataRoot = $codexData
            files = @([ordered]@{ relativePath = 'cyc.exe'; sha256 = 'fixture'; length = 9 })
            tasks = @()
            codexIntegration = [ordered]@{
                enabled = $true
                available = $true
                marketplaceRoot = (Join-Path $codexInstall 'integrations\codex-marketplace')
                plugin = 'cluster-your-codex@clusteryourcodex'
                attempted = $true
                cliFound = $true
                succeeded = $true
                marketplaceAdded = $true
                pluginAdded = $true
            }
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $codexManifest -Encoding UTF8
        $interruptManifest = Read-InstallManifest -ManifestPath $codexManifest
        $interruptPlan = [PSCustomObject]@{ codexIntegration = $interruptManifest.codexIntegration }
        $interruptCheckpoint = {
            param($result)
            Write-CodexCleanupState `
                -Manifest $interruptManifest `
                -ManifestPath $codexManifest `
                -Result $result
            throw 'simulated interruption after durable plugin checkpoint'
        }
        $interruptionObserved = $false
        try {
            [void](Invoke-CodexIntegration `
                -Plan $interruptPlan `
                -Operation Uninstall `
                -CleanupCheckpoint $interruptCheckpoint)
        } catch {
            $interruptionObserved = ($_.Exception.Message -match 'simulated interruption')
        }
        Assert-True $interruptionObserved 'test interrupts immediately after the first durable cleanup checkpoint'
        $afterInterruption = Read-InstallManifest -ManifestPath $codexManifest
        Assert-True $afterInterruption.codexIntegration.cleanup.pluginRemoved 'first cleanup step survives interruption'
        Assert-True (-not $afterInterruption.codexIntegration.cleanup.marketplaceRemoved) 'unstarted cleanup step remains pending'
        Assert-True (@(Get-Content -LiteralPath $fakeCodexLog).Count -eq 1) 'interruption happens before marketplace removal starts'

        $restartManifest = Read-InstallManifest -ManifestPath $codexManifest
        $restartPlan = [PSCustomObject]@{ codexIntegration = $restartManifest.codexIntegration }
        $restartCheckpoint = {
            param($result)
            Write-CodexCleanupState `
                -Manifest $restartManifest `
                -ManifestPath $codexManifest `
                -Result $result
        }
        $restartResult = Invoke-CodexIntegration `
            -Plan $restartPlan `
            -Operation Uninstall `
            -CleanupCheckpoint $restartCheckpoint
        Assert-True $restartResult.succeeded 'restart completes pending Codex cleanup'
        $restartCalls = @(Get-Content -LiteralPath $fakeCodexLog)
        Assert-True ($restartCalls.Count -eq 2) 'restart runs only one additional external cleanup step'
        Assert-True ($restartCalls[0] -match '^plugin remove ') 'first process removes the plugin'
        Assert-True ($restartCalls[1] -match '^plugin marketplace remove ') 'restart skips plugin removal and removes marketplace'
        $afterRestart = Read-InstallManifest -ManifestPath $codexManifest
        Assert-True $afterRestart.codexIntegration.cleanup.succeeded 'restart completion is durably checkpointed'
        Assert-True (-not @(Get-ChildItem -LiteralPath (Split-Path -Parent $codexManifest) -Filter '*.tmp-*').Count) 'no checkpoint temp file remains'
        Assert-True (-not @(Get-ChildItem -LiteralPath (Split-Path -Parent $codexManifest) -Filter '*.bak-*').Count) 'no checkpoint backup file remains'
    } finally {
        $env:PATH = $oldPath
        if ($null -eq $oldCodexLog) {
            Remove-Item Env:\CYC_FAKE_CODEX_LOG -ErrorAction SilentlyContinue
        } else {
            $env:CYC_FAKE_CODEX_LOG = $oldCodexLog
        }
    }

    $rootTarget = Join-Path $testRoot 'root-target'
    $desktopTarget = Join-Path $testRoot 'desktop-target'
    $mcpDeploy = Join-Path $testRoot 'mcp-deploy'
    $nodeRuntime = Get-ValidatedNodeExecutable
    $nodeLicense = Join-Path $testRoot 'LICENSE.node'
    $preview = Join-Path $testRoot 'preview'
    [void](New-Item -ItemType Directory -Path $rootTarget, $desktopTarget, (Join-Path $mcpDeploy 'dist') -Force)
    foreach ($name in @('cyc-controller.exe', 'cyc-worker.exe', 'cyc.exe')) {
        [System.IO.File]::WriteAllText((Join-Path $rootTarget $name), "release-$name")
    }
    [System.IO.File]::WriteAllText((Join-Path $desktopTarget 'ClusterYourCodex.exe'), 'release-gui')
    [System.IO.File]::WriteAllText((Join-Path $mcpDeploy 'dist\server.js'), 'release-mcp')
    [System.IO.File]::WriteAllText((Join-Path $mcpDeploy 'package.json'), '{}')
    [System.IO.File]::WriteAllText($nodeLicense, 'node-license')
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $sourceMcpManifest = Join-Path $repoRoot 'plugins\cluster-your-codex\.mcp.json'
    $sourceMcpHash = (Get-FileHash -LiteralPath $sourceMcpManifest -Algorithm SHA256).Hash
    & (Join-Path $PSScriptRoot 'New-PreviewPayload.ps1') `
        -RepositoryRoot $repoRoot `
        -RootCargoTarget $rootTarget `
        -DesktopCargoTarget $desktopTarget `
        -McpDeployRoot $mcpDeploy `
        -NodeExecutable $nodeRuntime `
        -NodeLicense $nodeLicense `
        -OutputRoot $preview | Out-Null
    Assert-True (Test-Path -LiteralPath (Join-Path $preview 'bootstrap.ps1') -PathType Leaf) 'preview contains bootstrap'
    Assert-True (Test-Path -LiteralPath (Join-Path $preview 'Install-ClusterYourCodex.cmd') -PathType Leaf) 'preview contains double-click installer'
    Assert-True (Test-Path -LiteralPath (Join-Path $preview 'LICENSE') -PathType Leaf) 'preview contains product license'
    Assert-True (Test-Path -LiteralPath (Join-Path $preview 'payload\ClusterYourCodex.exe') -PathType Leaf) 'preview contains GUI'
    Assert-True (Test-Path -LiteralPath (Join-Path $preview 'payload\cyc-worker.exe') -PathType Leaf) 'preview contains worker'
    Assert-True (Test-Path -LiteralPath (Join-Path $preview 'payload\integrations\codex-marketplace\.agents\plugins\marketplace.json') -PathType Leaf) 'preview contains marketplace manifest'
    Assert-True (Test-Path -LiteralPath (Join-Path $preview 'payload\integrations\codex-marketplace\plugins\cluster-your-codex\mcp\dist\server.js') -PathType Leaf) 'preview contains deployable MCP'
    Assert-True (Test-Path -LiteralPath (Join-Path $preview 'payload\integrations\codex-marketplace\plugins\cluster-your-codex\mcp\runtime\node.exe') -PathType Leaf) 'preview contains private Node runtime'
    Assert-True (Test-Path -LiteralPath (Join-Path $preview 'payload\integrations\codex-marketplace\plugins\cluster-your-codex\mcp\runtime\LICENSE.node.txt') -PathType Leaf) 'preview contains Node license'
    $stagedMcp = Get-Content -LiteralPath (Join-Path $preview 'payload\integrations\codex-marketplace\plugins\cluster-your-codex\.mcp.json') -Raw | ConvertFrom-Json
    Assert-True ($stagedMcp.mcpServers.cluster_your_codex.command -eq './mcp/runtime/node.exe') 'staged MCP uses private Node'
    Assert-True ((Get-FileHash -LiteralPath $sourceMcpManifest -Algorithm SHA256).Hash -eq $sourceMcpHash) 'source MCP manifest remains unchanged'
    $previewManifest = Get-Content -LiteralPath (Join-Path $preview 'preview-manifest.json') -Raw | ConvertFrom-Json
    $productLicenseHash = (Get-FileHash -LiteralPath (Join-Path $preview 'LICENSE') -Algorithm SHA256).Hash.ToLowerInvariant()
    $productLicenseRecord = @($previewManifest.files | Where-Object { $_.path -eq 'LICENSE' })
    Assert-True ($productLicenseRecord.Count -eq 1) 'preview manifest owns the product license'
    Assert-True ($productLicenseRecord[0].sha256 -eq $productLicenseHash) 'preview manifest hashes the product license'
    $previewChecksums = Get-Content -LiteralPath (Join-Path $preview 'SHA256SUMS') -Raw
    Assert-True ($previewChecksums -match 'preview-manifest\.json') 'checksums cover preview manifest'
    Assert-True ($previewChecksums -match "(?m)^$productLicenseHash  LICENSE`r?$") 'checksums cover the product license'
    $wrapper = Get-Content -LiteralPath (Join-Path $preview 'Install-ClusterYourCodex.cmd') -Raw
    Assert-True ($wrapper -match '%~dp0') 'wrapper resolves its own directory'
    Assert-True ($wrapper -match 'exit /b %CYC_EXIT_CODE%') 'wrapper propagates install failure'
    Assert-True ($wrapper -match 'start "" "%LOCALAPPDATA%\\Programs\\ClusterYourCodex\\ClusterYourCodex\.exe"') 'wrapper launches installed GUI'
    Assert-True ($wrapper -notmatch '(?i)Bearer|authorization|--token\s') 'wrapper contains no raw secret channel'

    Write-Output 'Windows packaging static/plan tests passed.'
} finally {
    $resolvedTestRoot = Resolve-NormalizedPath $testRoot
    $resolvedTemp = Resolve-NormalizedPath ([System.IO.Path]::GetTempPath())
    [void](Assert-ChildPath -Root $resolvedTemp -Candidate $resolvedTestRoot)
    if (Test-Path -LiteralPath $resolvedTestRoot) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
