#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Assert-BytesEqual {
    param([byte[]]$Expected, [byte[]]$Actual, [string]$Message)
    if ($Expected.Length -ne $Actual.Length) {
        throw "ASSERTION FAILED: $Message (length $($Expected.Length) != $($Actual.Length))"
    }
    for ($index = 0; $index -lt $Expected.Length; $index++) {
        if ($Expected[$index] -ne $Actual[$index]) {
            throw "ASSERTION FAILED: $Message (byte $index differs)"
        }
    }
}

function Assert-ThrowsLike {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Message
    )
    $matched = $false
    $observed = ''
    try { [void](& $Action) } catch {
        $observed = $_.Exception.Message
        $matched = $observed -match $Pattern
    }
    Assert-True $matched "$Message (observed: $observed)"
}

function Convert-CycPackagingJson {
    param([Parameter(Mandatory = $true)][string]$Raw)

    $converter = Get-Command ConvertFrom-Json -CommandType Cmdlet -ErrorAction Stop
    if ($converter.Parameters.ContainsKey('DateKind')) {
        return ConvertFrom-Json -InputObject $Raw -DateKind String
    }
    return ConvertFrom-Json -InputObject $Raw
}

function Write-FakeCodexPluginList {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [string]$Version = '0.1.0',
        [bool]$Installed = $true,
        [bool]$Enabled = $true
    )
    [ordered]@{
        installed = @([ordered]@{
            pluginId = 'cluster-your-codex@clusteryourcodex'
            name = 'cluster-your-codex'
            marketplaceName = 'clusteryourcodex'
            version = $Version
            installed = $Installed
            enabled = $Enabled
            source = [ordered]@{
                source = 'local'
                path = $SourcePath
            }
        })
        available = @()
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
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
$codexHome = Join-Path $testRoot 'codex-home'
try {
    [void](New-Item -ItemType Directory -Path $payload -Force)
    foreach ($name in @('ClusterYourCodex.exe', 'cyc-controller.exe', 'cyc.exe', 'cyc-worker.exe')) {
        [System.IO.File]::WriteAllText((Join-Path $payload $name), "fixture-$name")
    }
    [void](New-Item -ItemType Directory -Path (Join-Path $payload 'installer') -Force)
    [System.IO.File]::WriteAllText((Join-Path $payload 'installer\bootstrap.ps1'), 'fixture-bootstrap')
    [System.IO.File]::WriteAllText(
        (Join-Path $payload 'installer\Uninstall-ClusterYourCodex.ps1'),
        'fixture-uninstaller'
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $payload 'installer\Invoke-ClusterYourCodexLifecycle.ps1'),
        'fixture-lifecycle'
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $payload 'installer\Invoke-ClusterYourCodexFirewall.ps1'),
        'fixture-firewall-helper'
    )
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
    [System.IO.File]::WriteAllText(
        (Join-Path $plugin '.codex-plugin\plugin.json'),
        '{"name":"cluster-your-codex","version":"0.1.0"}',
        [System.Text.UTF8Encoding]::new($false)
    )
    $agentsTemplateFixture = Join-Path $payload 'integrations\codex\cluster-agents-block.md'
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $agentsTemplateFixture) -Force)
    Copy-Item `
        -LiteralPath (Join-Path $PSScriptRoot 'cluster-agents-block.md') `
        -Destination $agentsTemplateFixture
    $publicAgentsTemplate = Get-Content -LiteralPath $agentsTemplateFixture -Raw
    Assert-True ($publicAgentsTemplate -match 'cluster_your_codex.+MCP') 'managed AGENTS.md template tells Codex sessions how to reach the plugin tools'
    Assert-True ($publicAgentsTemplate -match 'fleet_plan.+fleet_plan_submit') 'managed template routes typed requirements through controller-owned planning and reservation'
    Assert-True ($publicAgentsTemplate -match 'Controller, not the language model, owns') 'managed template forbids LLM-owned stale-snapshot placement'
    Assert-True ($publicAgentsTemplate -notmatch '(?i)(password\s*[:=]|bearer\s+[A-Za-z0-9]|(?:\d{1,3}\.){3}\d{1,3})') 'managed AGENTS.md template contains no password, token, or private address value'

    $plan = Get-InstallPlan `
        -BundleRoot $payload `
        -InstallRoot $install `
        -DataRoot $data `
        -EnableWorker `
        -WorkerConfig (Join-Path $data 'worker\config.json') `
        -CodexHome $codexHome `
        -WorkerPublicHost '192.0.2.10'

    Assert-True ($plan.schemaVersion -eq 'cyc.dev/windows-install-manifest/v1') 'plan schema'
    Assert-True ($plan.files.Count -eq @(Get-PayloadFiles -Root $payload).Count) 'all payload files are owned'
    Assert-True ($plan.files.sha256 -notcontains $null) 'every file has a digest'
    Assert-True ($plan.tasks[0].action.arguments -match '^--bind 127\.0\.0\.1:47831 ') 'controller bind is explicit loopback'
    Assert-True ($plan.tasks[0].action.arguments -match '--database "[^\"]+\\controller\.db"') 'controller database path is explicit'
    Assert-True ($plan.tasks[0].action.arguments -match '--token-file "[^\"]+\\controller\.token"') 'controller gets only the token file path'
    Assert-True ($plan.tasks[0].action.arguments -match '--worker-bind 0\.0\.0\.0:47832') 'managed-worker TLS listener is enabled by default'
    Assert-True ($plan.tasks[0].action.arguments -match '--worker-public-url "https://192\.0\.2\.10:47832"') 'managed-worker public URL is explicit'
    Assert-True ($plan.tasks[0].action.arguments -match '--worker-cert "[^\"]+\\tls\\controller\.crt\.pem"') 'controller receives only the certificate path'
    Assert-True ($plan.tasks[0].action.arguments -match '--worker-key "[^\"]+\\tls\\controller\.key\.pem"') 'controller receives only the private-key path'
    Assert-True ($plan.tasks[0].action.arguments -notmatch '(?i)Bearer|authorization|--token\s') 'controller task has no raw token'
    Assert-True $plan.managedWorker.enabled 'managed worker is enabled by default'
    Assert-True $plan.managedWorker.firewall.enabled 'LocalSubnet firewall rule is enabled by default'
    Assert-True ($plan.managedWorker.firewall.name -match '^ClusterYourCodex\.ManagedWorker\.S_1_5_') 'firewall rule is scoped to the installing SID'
    Assert-True ($plan.managedWorker.firewall.lifecycle -eq 'external-elevated-helper') 'firewall mutation is delegated outside the per-user core'
    Assert-True ($plan.initiator.sid -eq (Get-CurrentUserSid)) 'plan binds the exact initiating SID'
    Assert-True ($plan.initiator.profile -eq (Resolve-NormalizedPath $env:USERPROFILE)) 'plan preserves the initiating profile'
    Assert-True $plan.uninstallRegistration.enabled 'formal uninstall registration is enabled by default'
    Assert-True ($plan.uninstallRegistration.uninstallString -match 'Uninstall-ClusterYourCodex\.ps1') 'uninstall registration uses the installed per-user launcher'
    Assert-True ($plan.tasks[1].action.arguments -match '^run --config ') 'worker gets only its config path'
    Assert-True ($plan.tasks[1].action.arguments -notmatch '(?i)token|secret|credential') 'worker task has no secret material'
    Assert-True $plan.codexIntegration.available 'complete marketplace payload is detected'
    Assert-True ($plan.codexIntegration.plugin -eq 'cluster-your-codex@clusteryourcodex') 'Codex plugin identity'
    Assert-True ($plan.codexIntegration.marketplaceManifest.EndsWith('.agents\plugins\marketplace.json')) 'complete marketplace root contract'
    Assert-True $plan.agentsIntegration.enabled 'global AGENTS.md additive integration is enabled by default'
    Assert-True ($plan.agentsIntegration.agentsPath -eq (Join-Path $codexHome 'AGENTS.md')) 'global AGENTS.md is scoped to the selected Codex home'
    Assert-True ($plan.agentsIntegration.templateRelativePath -eq 'integrations/codex/cluster-agents-block.md') 'managed block template is an owned payload file'

    $pluginFixture = Join-Path $plugin '.mcp.json'
    Remove-Item -LiteralPath $pluginFixture -Force
    $partialMarketplaceRejected = $false
    try {
        [void](Get-InstallPlan -BundleRoot $payload -InstallRoot $install -DataRoot $data -CodexHome $codexHome)
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
    Assert-True ($source -match 'Resolve-CodexCli') 'Codex integration probes executable candidates instead of trusting Get-Command'
    Assert-True ($source -match 'Test-CycCodexPluginActive') 'Codex registration is verified against the active plugin list'
    Assert-True ($source -match 'pluginVerified[\s\S]+Start-CycAgentsInstallTransaction') 'managed AGENTS.md installation is gated on verified plugin activation'
    Assert-True ($source -match "OpenAI\\Codex\\bin") 'Store-packaged Codex app-managed CLI location is discovered'
    Assert-True ($source -match 'CODEX_CLI_PATH') 'explicit Codex CLI path is preferred when supplied'
    Assert-True ($source -match 'Ensure-CycTlsIdentity') 'installer creates or verifies the controller TLS identity'
    Assert-True ($source -match "'identity', 'verify'") 'repair verifies TLS key/certificate/SAN instead of rotating it'
    Assert-True ($source -match 'RemoteAddress LocalSubnet') 'firewall scope is LocalSubnet only'
    Assert-True ($source -match 'Profile Private') 'firewall scope is Private profile only'
    Assert-True ($source -match 'Get-CycUninstallRegistrationSnapshot') 'uninstall registration participates in rollback'
    Assert-True ($source -match 'CLUSTERYOURCODEX-MANAGED:BEGIN') 'global AGENTS.md integration uses a unique begin marker'
    Assert-True ($source -match 'Get-CycAgentsMarkerState') 'managed markers are structurally validated'
    Assert-True ($source -match 'Write-CycDurableAtomicBytes') 'global AGENTS.md updates use an atomic durable writer'
    Assert-True ($source -match 'Start-CycAgentsInstallTransaction') 'global AGENTS.md uses a durable prepared install journal'
    Assert-True ($source -match 'Recover-CycAgentsTransactions') 'global AGENTS.md transactions reconcile on lifecycle restart'
    Assert-True ($source -match 'Set-CycAgentsContentCas') 'global AGENTS.md mutation uses compare-and-swap guards'
    Assert-True ($source -match 'Enter-CycAgentsMutex') 'global AGENTS.md lifecycle uses a product-wide serial boundary'
    Assert-True ($source -match 'Prepare-CycAgentsRemoval') 'global AGENTS.md uninstall uses a recoverable prepared checkpoint'
    $installCoreStart = $source.IndexOf('function Invoke-InstallOrRepairCore')
    $installCoreEnd = $source.IndexOf('function Invoke-InstallOrRepair', $installCoreStart + 1)
    $installCoreBody = $source.Substring($installCoreStart, $installCoreEnd - $installCoreStart)
    Assert-True ($installCoreBody -notmatch 'Set-CycFirewallRule|New-NetFirewallRule|Remove-CycFirewallRule') 'unelevated install/repair core has no firewall mutation call'
    $uninstallCoreStart = $source.IndexOf('function Invoke-UninstallCore')
    $uninstallCoreEnd = $source.IndexOf('function Invoke-Uninstall', $uninstallCoreStart + 1)
    $uninstallCoreBody = $source.Substring($uninstallCoreStart, $uninstallCoreEnd - $uninstallCoreStart)
    Assert-True ($uninstallCoreBody -notmatch 'Set-CycFirewallRule|New-NetFirewallRule|Remove-CycFirewallRule') 'unelevated uninstall core has no firewall mutation call'

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

    # Global AGENTS.md integration is tested only in this isolated Codex home.
    # The fixture is intentionally large, CRLF-terminated internally, and has
    # no trailing newline so removal must restore every original byte.
    $agentsSandbox = Join-Path $testRoot 'agents-integration'
    $agentsPath = Join-Path $agentsSandbox 'AGENTS.md'
    [void](New-Item -ItemType Directory -Path $agentsSandbox -Force)
    $agentsPlan = [PSCustomObject]@{
        agentsIntegration = [PSCustomObject]@{
            enabled = $true
            codexHome = $agentsSandbox
            agentsPath = $agentsPath
            templatePath = $agentsTemplateFixture
            templateRelativePath = 'integrations/codex/cluster-agents-block.md'
        }
    }
    $verifiedPluginReceipt = [PSCustomObject]@{
        pluginVerified = $true
        succeeded = $true
    }
    $largeOriginalText = "# Existing global rules`r`n" +
        ((1..20000 | ForEach-Object { "preserve-rule-$($_.ToString('D5'))`r`n" }) -join '') +
        'tail-without-newline'
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [byte[]]$largeOriginalBytes = $utf8NoBom.GetBytes($largeOriginalText)
    [System.IO.File]::WriteAllBytes($agentsPath, $largeOriginalBytes)
    $agentsInstalled = Install-CycAgentsManagedBlock -TestHarness -Plan $agentsPlan -OldManifest $null
    Assert-True $agentsInstalled.installed 'existing global AGENTS.md receives one managed block'
    Assert-True $agentsInstalled.changed 'first managed-block install changes the file'
    Assert-True ($agentsInstalled.previousFileSha256 -eq (Get-CycSha256Hex -Bytes $largeOriginalBytes)) 'receipt records the exact previous AGENTS.md digest'
    Assert-True ($agentsInstalled.blockSha256 -match '^[0-9a-f]{64}$') 'receipt records the managed block digest'
    $originalManifestPath = $plan.manifestPath
    $agentsReceiptPath = Join-Path $testRoot 'agents-receipt\install-manifest.json'
    $plan.manifestPath = $agentsReceiptPath
    $fakeIntegrationResult = [PSCustomObject]@{
        attempted = $true; cliFound = $true; succeeded = $true
        marketplaceAdded = $true; pluginAdded = $true; pluginVerified = $true
        pluginVerificationExitCode = 0
        pluginExitCode = 0; marketplaceExitCode = 0
    }
    Write-InstallManifest `
        -Plan $plan `
        -CodexResult $fakeIntegrationResult `
        -AgentsResult $agentsInstalled
    $agentsReceipt = Get-Content -LiteralPath $agentsReceiptPath -Raw | ConvertFrom-Json
    Assert-True ($agentsReceipt.agentsIntegration.previousFileSha256 -eq $agentsInstalled.previousFileSha256) 'install manifest records previous AGENTS.md state'
    Assert-True ($agentsReceipt.agentsIntegration.blockSha256 -eq $agentsInstalled.blockSha256) 'install manifest records the installed managed-block digest'
    Assert-True $agentsReceipt.codexIntegration.pluginVerified 'install manifest records the verified active-plugin receipt'
    $plan.manifestPath = $originalManifestPath
    $installedDocument = Get-CycStrictTextDocument -Path $agentsPath
    $installedMarkers = Get-CycAgentsMarkerState -Document $installedDocument
    Assert-True $installedMarkers.present 'installed AGENTS.md has one complete marker pair'
    Assert-True ($installedMarkers.blockText -match "`r`n") 'managed block follows the existing CRLF convention'

    $repairManifest = [PSCustomObject]@{ agentsIntegration = $agentsInstalled }
    [byte[]]$beforeRepair = [System.IO.File]::ReadAllBytes($agentsPath)
    $agentsRepaired = Install-CycAgentsManagedBlock -TestHarness -Plan $agentsPlan -OldManifest $repairManifest
    [byte[]]$afterRepair = [System.IO.File]::ReadAllBytes($agentsPath)
    Assert-True (-not $agentsRepaired.changed) 'repair is idempotent when the template has not changed'
    Assert-BytesEqual $beforeRepair $afterRepair 'idempotent repair does not rewrite global AGENTS.md bytes'

    $updatedAgentsTemplate = Join-Path $testRoot 'updated-cluster-agents-block.md'
    $publicAgentsTemplate.Replace(
        '<!-- CLUSTERYOURCODEX-MANAGED:END -->',
        "- Record a controller-owned placement receipt.`r`n<!-- CLUSTERYOURCODEX-MANAGED:END -->"
    ) | Set-Content -LiteralPath $updatedAgentsTemplate -Encoding UTF8
    $agentsPlan.agentsIntegration.templatePath = $updatedAgentsTemplate
    $agentsUpdated = Install-CycAgentsManagedBlock -TestHarness `
        -Plan $agentsPlan `
        -OldManifest ([PSCustomObject]@{ agentsIntegration = $agentsRepaired })
    Assert-True $agentsUpdated.changed 'repair replaces only the owned block when its template changes'
    Assert-True ($agentsUpdated.blockSha256 -ne $agentsRepaired.blockSha256) 'repair receipt records the updated block digest'
    $agentsPlan.agentsIntegration.templatePath = $agentsTemplateFixture

    $largeRemoval = Get-CycAgentsRemovalPlan -Record $agentsUpdated
    Remove-CycAgentsManagedBlock -RemovalPlan $largeRemoval
    Assert-BytesEqual $largeOriginalBytes ([System.IO.File]::ReadAllBytes($agentsPath)) 'uninstall restores large CRLF/no-final-newline AGENTS.md byte-for-byte'

    # UTF-8 BOM is retained through install, repair-compatible parsing, and
    # exact uninstall restoration.
    $bomText = "# BOM rules`r`nkeep-this-byte-for-byte"
    [byte[]]$bomBody = $utf8NoBom.GetBytes($bomText)
    [byte[]]$bomOriginal = New-Object byte[] (3 + $bomBody.Length)
    [byte[]]$utf8Bom = @(0xef, 0xbb, 0xbf)
    [System.Buffer]::BlockCopy($utf8Bom, 0, $bomOriginal, 0, 3)
    [System.Buffer]::BlockCopy($bomBody, 0, $bomOriginal, 3, $bomBody.Length)
    [System.IO.File]::WriteAllBytes($agentsPath, $bomOriginal)
    $bomInstalled = Install-CycAgentsManagedBlock -TestHarness -Plan $agentsPlan -OldManifest $null
    [byte[]]$bomManaged = [System.IO.File]::ReadAllBytes($agentsPath)
    Assert-True ($bomManaged[0] -eq 0xef -and $bomManaged[1] -eq 0xbb -and $bomManaged[2] -eq 0xbf) 'UTF-8 BOM remains present after install'
    Remove-CycAgentsManagedBlock -RemovalPlan (Get-CycAgentsRemovalPlan -Record $bomInstalled)
    Assert-BytesEqual $bomOriginal ([System.IO.File]::ReadAllBytes($agentsPath)) 'UTF-8 BOM AGENTS.md is restored byte-for-byte'

    # A Codex home that had no AGENTS.md gets one, and uninstall deletes it
    # only when no non-owned content remains.
    Remove-Item -LiteralPath $agentsPath -Force
    $absentInstalled = Install-CycAgentsManagedBlock -TestHarness -Plan $agentsPlan -OldManifest $null
    Assert-True (Test-Path -LiteralPath $agentsPath -PathType Leaf) 'absent global AGENTS.md is created'
    $absentRemoval = Get-CycAgentsRemovalPlan -Record $absentInstalled
    Assert-True $absentRemoval.afterAbsent 'uninstall records deletion for an originally absent empty file'
    Remove-CycAgentsManagedBlock -RemovalPlan $absentRemoval
    Assert-True (-not (Test-Path -LiteralPath $agentsPath)) 'uninstall deletes an originally absent block-only AGENTS.md'

    [System.IO.File]::WriteAllBytes($agentsPath, [byte[]]@())
    $emptyExistingInstalled = Install-CycAgentsManagedBlock -TestHarness -Plan $agentsPlan -OldManifest $null
    Remove-CycAgentsManagedBlock -RemovalPlan (Get-CycAgentsRemovalPlan -Record $emptyExistingInstalled)
    Assert-True ((Test-Path -LiteralPath $agentsPath -PathType Leaf) -and
        (Get-Item -LiteralPath $agentsPath).Length -eq 0) 'uninstall preserves an originally existing empty AGENTS.md'

    # The uninstall record is two-phase so a process restart can reconcile
    # either the before-image or the already-applied after-image.
    [System.IO.File]::WriteAllBytes($agentsPath, $largeOriginalBytes)
    $checkpointInstalled = Install-CycAgentsManagedBlock -TestHarness -Plan $agentsPlan -OldManifest $null
    $checkpointManifestPath = Join-Path $testRoot 'agents-cleanup-checkpoint.json'
    $checkpointManifest = [PSCustomObject]@{ agentsIntegration = $checkpointInstalled }
    $checkpointRemoval = Get-CycAgentsRemovalPlan -Record $checkpointInstalled
    Prepare-CycAgentsRemoval `
        -Manifest $checkpointManifest `
        -ManifestPath $checkpointManifestPath `
        -RemovalPlan $checkpointRemoval
    $preparedManifest = Get-Content -LiteralPath $checkpointManifestPath -Raw | ConvertFrom-Json
    Assert-True ($preparedManifest.agentsIntegration.cleanup.phase -eq 'prepared') 'uninstall durably checkpoints the expected before/after AGENTS.md hashes'
    Remove-CycAgentsManagedBlock -RemovalPlan $checkpointRemoval
    $restartRemoval = Get-CycAgentsRemovalPlan -Record $preparedManifest.agentsIntegration
    Assert-True $restartRemoval.alreadyApplied 'uninstall restart recognizes an already-applied AGENTS.md after-image'
    Complete-CycAgentsRemoval `
        -Manifest $preparedManifest `
        -ManifestPath $checkpointManifestPath `
        -RemovalPlan $restartRemoval
    $completedManifest = Get-Content -LiteralPath $checkpointManifestPath -Raw | ConvertFrom-Json
    Assert-True ($completedManifest.agentsIntegration.cleanup.phase -eq 'completed') 'uninstall restart completes the durable AGENTS.md cleanup checkpoint'
    Assert-BytesEqual $largeOriginalBytes ([System.IO.File]::ReadAllBytes($agentsPath)) 'prepared cleanup reconciliation preserves the exact original file'

    # User content added outside the owned range after install is preserved.
    [System.IO.File]::WriteAllBytes($agentsPath, $largeOriginalBytes)
    $outsideEditInstalled = Install-CycAgentsManagedBlock -TestHarness -Plan $agentsPlan -OldManifest $null
    [System.IO.File]::AppendAllText($agentsPath, "`r`n# user-added-after-install", $utf8NoBom)
    Remove-CycAgentsManagedBlock -RemovalPlan (Get-CycAgentsRemovalPlan -Record $outsideEditInstalled)
    $expectedOutsideText = $largeOriginalText + "`r`n# user-added-after-install"
    Assert-BytesEqual ($utf8NoBom.GetBytes($expectedOutsideText)) ([System.IO.File]::ReadAllBytes($agentsPath)) 'uninstall preserves edits outside the owned block'

    # Half, duplicate, and drifted markers fail closed without touching bytes.
    $halfMarkerBytes = $utf8NoBom.GetBytes("# existing`r`n$($script:AgentsBeginMarker)`r`npartial")
    [System.IO.File]::WriteAllBytes($agentsPath, $halfMarkerBytes)
    $halfRejected = $false
    try { [void](Install-CycAgentsManagedBlock -TestHarness -Plan $agentsPlan -OldManifest $null) } catch {
        $halfRejected = ($_.Exception.Message -match 'half-present')
    }
    Assert-True $halfRejected 'half-present managed marker pair fails closed'
    Assert-BytesEqual $halfMarkerBytes ([System.IO.File]::ReadAllBytes($agentsPath)) 'half-marker rejection leaves AGENTS.md untouched'

    $templateText = (Read-CycAgentsTemplate -Path $agentsTemplateFixture).text.Replace("`n", "`r`n")
    $duplicateBytes = $utf8NoBom.GetBytes("# existing`r`n$templateText`r`n$templateText")
    [System.IO.File]::WriteAllBytes($agentsPath, $duplicateBytes)
    $duplicateRejected = $false
    try { [void](Install-CycAgentsManagedBlock -TestHarness -Plan $agentsPlan -OldManifest $null) } catch {
        $duplicateRejected = ($_.Exception.Message -match 'duplicate|nested')
    }
    Assert-True $duplicateRejected 'duplicate managed markers fail closed'
    Assert-BytesEqual $duplicateBytes ([System.IO.File]::ReadAllBytes($agentsPath)) 'duplicate-marker rejection leaves AGENTS.md untouched'

    [System.IO.File]::WriteAllBytes($agentsPath, $largeOriginalBytes)
    $driftInstalled = Install-CycAgentsManagedBlock -TestHarness -Plan $agentsPlan -OldManifest $null
    $driftText = [System.IO.File]::ReadAllText($agentsPath).Replace(
        'ClusterYourCodex is registered and enabled',
        'ClusterYourCodex block was edited'
    )
    [System.IO.File]::WriteAllText($agentsPath, $driftText, $utf8NoBom)
    [byte[]]$driftBytes = [System.IO.File]::ReadAllBytes($agentsPath)
    $driftRejected = $false
    try { [void](Get-CycAgentsRemovalPlan -Record $driftInstalled) } catch {
        $driftRejected = ($_.Exception.Message -match 'drifted')
    }
    Assert-True $driftRejected 'managed-block drift makes uninstall fail closed'
    Assert-BytesEqual $driftBytes ([System.IO.File]::ReadAllBytes($agentsPath)) 'drift rejection does not damage user content'

    [System.IO.File]::WriteAllBytes($agentsPath, $largeOriginalBytes)
    $malformedRecordInstalled = Install-CycAgentsManagedBlock -TestHarness -Plan $agentsPlan -OldManifest $null
    $malformedRecord = $malformedRecordInstalled | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $malformedRecord.PSObject.Properties.Remove('baseFileExisted')
    [byte[]]$beforeMalformedRecord = [System.IO.File]::ReadAllBytes($agentsPath)
    $malformedRecordRejected = $false
    try { [void](Get-CycAgentsRemovalPlan -Record $malformedRecord) } catch {
        $malformedRecordRejected = ($_.Exception.Message -match 'missing')
    }
    Assert-True $malformedRecordRejected 'malformed AGENTS.md ownership metadata fails closed'
    Assert-BytesEqual $beforeMalformedRecord ([System.IO.File]::ReadAllBytes($agentsPath)) 'malformed ownership metadata leaves AGENTS.md untouched'

    # A later installation failure reverses only the owned range. Content
    # added outside that range during the rollback window is retained.
    [System.IO.File]::WriteAllBytes($agentsPath, $bomOriginal)
    $agentsTransaction = Join-Path $testRoot 'agents-rollback-transaction'
    [void](New-Item -ItemType Directory -Path $agentsTransaction -Force)
    $preparedAgents = Start-CycAgentsInstallTransaction `
        -Plan $agentsPlan `
        -OldManifest $null `
        -TransactionRoot $agentsTransaction `
        -PluginReceipt $verifiedPluginReceipt
    [System.IO.File]::AppendAllText($agentsPath, "`r`n# concurrent-user-rule", $utf8NoBom)
    Rollback-CycAgentsInstallTransaction -Transaction $preparedAgents
    [byte[]]$expectedRollbackBytes = New-Object byte[] ($bomOriginal.Length + $utf8NoBom.GetByteCount("`r`n# concurrent-user-rule"))
    [System.Buffer]::BlockCopy($bomOriginal, 0, $expectedRollbackBytes, 0, $bomOriginal.Length)
    [byte[]]$concurrentBytes = $utf8NoBom.GetBytes("`r`n# concurrent-user-rule")
    [System.Buffer]::BlockCopy($concurrentBytes, 0, $expectedRollbackBytes, $bomOriginal.Length, $concurrentBytes.Length)
    Assert-BytesEqual $expectedRollbackBytes ([System.IO.File]::ReadAllBytes($agentsPath)) 'installation rollback preserves the original bytes and outside edit'

    # Fresh-install crash after AGENTS.md mutation but before install-manifest
    # publication is reconciled from the durable prepared journal.
    $freshCrashData = Join-Path $testRoot 'fresh-crash-data'
    $freshCrashRoot = Join-Path $freshCrashData '.installer\transactions\fresh-crash'
    $freshCrashManifest = Join-Path $freshCrashData '.installer\install-manifest.json'
    Remove-Item -LiteralPath $agentsPath -Force
    [void](New-Item -ItemType Directory -Path $freshCrashRoot -Force)
    $freshCrash = Start-CycAgentsInstallTransaction `
        -Plan $agentsPlan `
        -OldManifest $null `
        -TransactionRoot $freshCrashRoot `
        -PluginReceipt $verifiedPluginReceipt
    $freshJournal = Read-CycAgentsJournal -Path $freshCrash.journalPath
    Assert-True ($freshJournal.phase -eq 'applied') 'fresh crash fixture has an applied journal before manifest publication'
    Assert-True ($freshJournal.originalExisted -eq $false) 'journal records original AGENTS.md existence'
    foreach ($digestName in @('beforeImageSha256', 'afterImageSha256', 'templateSha256', 'blockSha256', 'prefixSha256')) {
        Assert-True ([string]$freshJournal.$digestName -match '^[0-9a-f]{64}$') "journal records $digestName"
    }
    $freshRecovery = @(Recover-CycAgentsTransactions -DataRoot $freshCrashData -ManifestPath $freshCrashManifest)
    Assert-True ($freshRecovery.Count -eq 1 -and $freshRecovery[0].action -eq 'rolled-back-install') 'fresh crash without manifest rolls back on restart'
    Assert-True (-not (Test-Path -LiteralPath $agentsPath)) 'fresh crash recovery removes only the transaction-owned block-only file'

    # Upgrade crash uses the old manifest as the authority and replaces only
    # the new block with the previous block, retaining outside concurrent edits.
    [System.IO.File]::WriteAllBytes($agentsPath, $largeOriginalBytes)
    $upgradeBase = Install-CycAgentsManagedBlock -TestHarness -Plan $agentsPlan -OldManifest $null
    [byte[]]$upgradeBefore = [System.IO.File]::ReadAllBytes($agentsPath)
    $upgradeData = Join-Path $testRoot 'upgrade-crash-data'
    $upgradeManifestPath = Join-Path $upgradeData '.installer\install-manifest.json'
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $upgradeManifestPath) -Force)
    [ordered]@{
        schemaVersion = 'cyc.dev/windows-install-manifest/v1'
        agentsIntegration = $upgradeBase
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $upgradeManifestPath -Encoding UTF8
    $upgradeTemplate = Join-Path $testRoot 'upgrade-crash-template.md'
    $publicAgentsTemplate.Replace(
        '<!-- CLUSTERYOURCODEX-MANAGED:END -->',
        "- Upgrade crash fixture.`r`n<!-- CLUSTERYOURCODEX-MANAGED:END -->"
    ) | Set-Content -LiteralPath $upgradeTemplate -Encoding UTF8
    $agentsPlan.agentsIntegration.templatePath = $upgradeTemplate
    $upgradeRoot = Join-Path $upgradeData '.installer\transactions\upgrade-crash'
    [void](New-Item -ItemType Directory -Path $upgradeRoot -Force)
    $upgradeCrash = Start-CycAgentsInstallTransaction `
        -Plan $agentsPlan `
        -OldManifest ([PSCustomObject]@{ agentsIntegration = $upgradeBase }) `
        -TransactionRoot $upgradeRoot `
        -PluginReceipt $verifiedPluginReceipt
    [byte[]]$upgradeOutside = $utf8NoBom.GetBytes("`r`n# upgrade-window-user-edit")
    [System.IO.File]::AppendAllText($agentsPath, "`r`n# upgrade-window-user-edit", $utf8NoBom)
    $upgradeRecovery = @(Recover-CycAgentsTransactions -DataRoot $upgradeData -ManifestPath $upgradeManifestPath)
    Assert-True ($upgradeRecovery.Count -eq 1 -and $upgradeRecovery[0].action -eq 'rolled-back-install') 'upgrade crash before new manifest restores the prior owned block'
    [byte[]]$upgradeExpected = New-Object byte[] ($upgradeBefore.Length + $upgradeOutside.Length)
    [System.Buffer]::BlockCopy($upgradeBefore, 0, $upgradeExpected, 0, $upgradeBefore.Length)
    [System.Buffer]::BlockCopy($upgradeOutside, 0, $upgradeExpected, $upgradeBefore.Length, $upgradeOutside.Length)
    Assert-BytesEqual $upgradeExpected ([System.IO.File]::ReadAllBytes($agentsPath)) 'upgrade crash recovery preserves outside concurrent edits byte-for-byte'
    $agentsPlan.agentsIntegration.templatePath = $agentsTemplateFixture
    Remove-CycAgentsManagedBlock -RemovalPlan (Get-CycAgentsRemovalPlan -Record $upgradeBase)

    # A matching newly published manifest finalizes, rather than rolls back,
    # an applied transaction after restart.
    [System.IO.File]::WriteAllBytes($agentsPath, $largeOriginalBytes)
    $finalizeData = Join-Path $testRoot 'finalize-crash-data'
    $finalizeRoot = Join-Path $finalizeData '.installer\transactions\finalize-crash'
    $finalizeManifestPath = Join-Path $finalizeData '.installer\install-manifest.json'
    [void](New-Item -ItemType Directory -Path $finalizeRoot -Force)
    $finalizeTx = Start-CycAgentsInstallTransaction `
        -Plan $agentsPlan `
        -OldManifest $null `
        -TransactionRoot $finalizeRoot `
        -PluginReceipt $verifiedPluginReceipt
    [ordered]@{
        schemaVersion = 'cyc.dev/windows-install-manifest/v1'
        agentsIntegration = $finalizeTx.record
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $finalizeManifestPath -Encoding UTF8
    $finalized = @(Recover-CycAgentsTransactions -DataRoot $finalizeData -ManifestPath $finalizeManifestPath)
    Assert-True ($finalized.Count -eq 1 -and $finalized[0].action -eq 'finalized-install') 'matching manifest finalizes an applied AGENTS.md install transaction'
    Assert-True ((Read-CycAgentsJournal -Path $finalizeTx.journalPath).phase -eq 'committed') 'finalized journal is durably committed'
    Assert-True (Test-CycAgentsRecordPresent -Record $finalizeTx.record) 'finalization retains the verified managed block'
    Remove-CycAgentsManagedBlock -RemovalPlan (Get-CycAgentsRemovalPlan -Record $finalizeTx.record)

    # For an originally absent file, a user write after the uninstall plan is
    # computed defeats the CAS delete. Replanning removes only the owned range.
    Remove-Item -LiteralPath $agentsPath -Force
    $absentWithUser = Install-CycAgentsManagedBlock -TestHarness -Plan $agentsPlan -OldManifest $null
    $staleDeletePlan = Get-CycAgentsRemovalPlan -Record $absentWithUser
    [System.IO.File]::AppendAllText($agentsPath, "`r`n# user-created-content", $utf8NoBom)
    [byte[]]$beforeStaleDelete = [System.IO.File]::ReadAllBytes($agentsPath)
    $staleDeleteRejected = $false
    try { Remove-CycAgentsManagedBlock -RemovalPlan $staleDeletePlan } catch {
        $staleDeleteRejected = ($_.Exception.Message -match 'compare-and-swap')
    }
    Assert-True $staleDeleteRejected 'stale block-only deletion fails its expected-after-image CAS'
    Assert-BytesEqual $beforeStaleDelete ([System.IO.File]::ReadAllBytes($agentsPath)) 'stale delete does not remove newly added user content'
    Remove-CycAgentsManagedBlock -RemovalPlan (Get-CycAgentsRemovalPlan -Record $absentWithUser)
    Assert-True ((Get-Content -LiteralPath $agentsPath -Raw) -eq "`r`n# user-created-content") 'replanned uninstall preserves content added to an originally absent file byte-for-byte'

    # Uninstall rollback inserts only the verified owned range. A file created
    # by the user after block-only deletion is retained.
    Remove-Item -LiteralPath $agentsPath -Force
    $uninstallRollbackInstalled = Install-CycAgentsManagedBlock -TestHarness -Plan $agentsPlan -OldManifest $null
    $uninstallRollbackPlan = Get-CycAgentsRemovalPlan -Record $uninstallRollbackInstalled
    $uninstallRollbackRoot = Join-Path $testRoot 'uninstall-rollback-transaction'
    [void](New-Item -ItemType Directory -Path $uninstallRollbackRoot -Force)
    $uninstallRollbackTx = Start-CycAgentsRemovalTransaction `
        -Record $uninstallRollbackInstalled `
        -RemovalPlan $uninstallRollbackPlan `
        -TransactionRoot $uninstallRollbackRoot
    Apply-CycAgentsRemovalTransaction -Transaction $uninstallRollbackTx
    [System.IO.File]::WriteAllText($agentsPath, '# user-file-after-delete', $utf8NoBom)
    Rollback-CycAgentsRemovalTransaction -Transaction $uninstallRollbackTx
    Assert-True ((Get-Content -LiteralPath $agentsPath -Raw) -match '# user-file-after-delete') 'uninstall rollback preserves a newly created user file'
    Assert-True (Test-CycAgentsRecordPresent -Record $uninstallRollbackInstalled) 'uninstall rollback restores the owned block without whole-file replacement'
    Remove-CycAgentsManagedBlock -RemovalPlan (Get-CycAgentsRemovalPlan -Record $uninstallRollbackInstalled)
    Assert-True ((Get-Content -LiteralPath $agentsPath -Raw) -eq '# user-file-after-delete') 'cleanup after uninstall rollback still preserves user content'

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

    $fakeIdentityCli = Join-Path $testRoot 'fake-identity.ps1'
    @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Remaining)
$ErrorActionPreference = 'Stop'
if ($Remaining.Count -lt 2 -or $Remaining[0] -ne 'identity') { exit 2 }
if ($Remaining[1] -eq 'init') {
    $outputIndex = [Array]::IndexOf($Remaining, '--output-dir')
    if ($outputIndex -lt 0 -or $outputIndex + 1 -ge $Remaining.Count) { exit 3 }
    $root = [System.IO.Path]::GetFullPath($Remaining[$outputIndex + 1])
    [void](New-Item -ItemType Directory -Path $root -Force)
    $certificate = Join-Path $root 'controller.crt.pem'
    $key = Join-Path $root 'controller.key.pem'
    [System.IO.File]::WriteAllText($certificate, 'fixture-certificate')
    [System.IO.File]::WriteAllText($key, 'fixture-private-key')
    [ordered]@{
        certificatePath = $certificate
        privateKeyPath = $key
        sha256Fingerprint = ('a' * 64)
        sans = @('192.0.2.10')
    } | ConvertTo-Json -Compress
    exit 0
}
if ($Remaining[1] -eq 'verify') {
    [ordered]@{ sha256Fingerprint = ('a' * 64); sans = @('192.0.2.10') } |
        ConvertTo-Json -Compress
    exit 0
}
exit 4
'@ | Set-Content -LiteralPath $fakeIdentityCli -Encoding UTF8
    $plan.managedWorker.identityCli = $fakeIdentityCli
    $identityFirst = Ensure-CycTlsIdentity -Plan $plan
    Assert-True $identityFirst.created 'fresh install creates one controller TLS identity'
    Assert-True ((Test-Path -LiteralPath $plan.managedWorker.certificatePath -PathType Leaf) -and
        (Test-Path -LiteralPath $plan.managedWorker.privateKeyPath -PathType Leaf)) 'TLS identity creates both files'
    $identitySecond = Ensure-CycTlsIdentity -Plan $plan
    Assert-True (-not $identitySecond.created) 'repair verifies and preserves the existing TLS identity'
    Remove-Item -LiteralPath $plan.managedWorker.privateKeyPath -Force
    $partialIdentityRejected = $false
    try { [void](Ensure-CycTlsIdentity -Plan $plan) } catch {
        $partialIdentityRejected = ($_.Exception.Message -match 'incomplete')
    }
    Assert-True $partialIdentityRejected 'repair rejects an incomplete TLS identity without rotation'
    Assert-True (Test-Path -LiteralPath $plan.managedWorker.certificatePath -PathType Leaf) 'incomplete identity failure preserves the remaining certificate for diagnosis'

    $registrationRoot = 'HKCU:\Software\ClusterYourCodexPackagingTests'
    $registrationPath = Join-Path $registrationRoot ([Guid]::NewGuid().ToString('N'))
    $plan.uninstallRegistration.registryPath = $registrationPath
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $plan.uninstallRegistration.installedBootstrap) -Force)
    [System.IO.File]::WriteAllText($plan.uninstallRegistration.installedBootstrap, 'fixture-bootstrap')
    [System.IO.File]::WriteAllText($plan.uninstallRegistration.uninstallerPath, 'fixture-uninstaller')
    try {
        $registrationBefore = Get-CycUninstallRegistrationSnapshot -RegistryPath $registrationPath
        Assert-True (-not $registrationBefore.existed) 'uninstall registration starts absent in its isolated key'
        Set-CycUninstallRegistration -Plan $plan
        $registration = Get-ItemProperty -LiteralPath $registrationPath
        Assert-True ($registration.InstallLocation -eq $plan.installRoot) 'uninstall registration binds the exact install root'
        Assert-True ($registration.DataLocation -eq $plan.dataRoot) 'uninstall registration binds the exact data root'
        Assert-True ($registration.UninstallString -notmatch '(?i)token|secret|credential') 'uninstall command has no secret material'
        $registrationSnapshot = Get-CycUninstallRegistrationSnapshot -RegistryPath $registrationPath
        Set-ItemProperty -LiteralPath $registrationPath -Name DisplayName -Value 'tampered'
        Restore-CycUninstallRegistrationSnapshot -RegistryPath $registrationPath -Snapshot $registrationSnapshot
        Assert-True ((Get-ItemProperty -LiteralPath $registrationPath).DisplayName -eq 'ClusterYourCodex') 'uninstall registration rollback restores exact values'
        Remove-CycUninstallRegistration -RegistryPath $registrationPath -ExpectedInstallRoot $plan.installRoot
        Assert-True (-not (Test-Path -LiteralPath $registrationPath)) 'owned uninstall registration is removed idempotently'
    } finally {
        if (Test-Path -LiteralPath $registrationPath) {
            Remove-Item -LiteralPath $registrationPath -Recurse -Force
        }
        if ((Test-Path -LiteralPath $registrationRoot) -and
            -not (Get-ChildItem -LiteralPath $registrationRoot | Select-Object -First 1)) {
            Remove-Item -LiteralPath $registrationRoot -Force
        }
    }

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

    # Registration exit code alone is not activation. The block gate requires
    # an exact enabled plugin receipt from `codex plugin list --json`.
    $fakeActivationBin = Join-Path $testRoot 'fake-activation-codex-bin'
    $fakeActivationCodex = Join-Path $fakeActivationBin 'codex.cmd'
    [void](New-Item -ItemType Directory -Path $fakeActivationBin -Force)
    [System.IO.File]::WriteAllText(
        $fakeActivationCodex,
        "@echo off`r`nif /I `"%1`"==`"--version`" echo codex-cli 0.149.0-test& exit /b 0`r`nif /I `"%1`"==`"plugin`" if /I `"%2`"==`"list`" echo {`"installed`":[],`"available`":[]}& exit /b 0`r`nexit /b 0`r`n"
    )
    $activationPlan = [PSCustomObject]@{
        codexIntegration = [PSCustomObject]@{
            enabled = $true
            marketplaceManifest = (Join-Path $marketplace 'marketplace.json')
            marketplaceRoot = (Join-Path $payload 'integrations\codex-marketplace')
            plugin = 'cluster-your-codex@clusteryourcodex'
        }
    }
    $oldActivationCli = $env:CYC_CODEX_CLI
    $oldPluginListPath = $env:CYC_FAKE_PLUGIN_LIST
    try {
        $env:CYC_CODEX_CLI = $fakeActivationCodex
        $inactiveResult = Invoke-CodexIntegration -Plan $activationPlan -Operation Install
        Assert-True ($inactiveResult.marketplaceAdded -and $inactiveResult.pluginAdded) 'activation fixture registration commands succeed'
        Assert-True (-not $inactiveResult.pluginVerified -and -not $inactiveResult.succeeded) 'missing enabled plugin receipt fails activation verification'
        $inactiveHome = Join-Path $testRoot 'inactive-plugin-codex-home'
        $inactiveAgentsPlan = [PSCustomObject]@{
            agentsIntegration = [PSCustomObject]@{
                enabled = $true
                codexHome = $inactiveHome
                agentsPath = (Join-Path $inactiveHome 'AGENTS.md')
                templatePath = $agentsTemplateFixture
                templateRelativePath = 'integrations/codex/cluster-agents-block.md'
            }
        }
        $inactiveRecord = New-CycDisabledAgentsIntegrationRecord `
            -Plan $inactiveAgentsPlan `
            -Reason 'plugin-activation-unverified'
        Assert-True (-not $inactiveRecord.installed) 'failed plugin activation is recorded as not installed'
        Assert-True (-not (Test-Path -LiteralPath $inactiveAgentsPlan.agentsIntegration.agentsPath)) 'failed plugin activation does not create a global AGENTS.md block'

        $activationPluginList = Join-Path $testRoot 'active-plugin-list.json'
        [ordered]@{
            installed = @([ordered]@{
                pluginId = 'cluster-your-codex@clusteryourcodex'
                name = 'cluster-your-codex'
                marketplaceName = 'clusteryourcodex'
                version = '0.1.0'
                installed = $true
                enabled = $true
                source = [ordered]@{
                    source = 'local'
                    path = (Join-Path $payload 'integrations\codex-marketplace\plugins\cluster-your-codex')
                }
            })
            available = @()
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $activationPluginList -Encoding UTF8
        $env:CYC_FAKE_PLUGIN_LIST = $activationPluginList
        [System.IO.File]::WriteAllText(
            $fakeActivationCodex,
            "@echo off`r`nif /I `"%1`"==`"--version`" echo codex-cli 0.149.0-test& exit /b 0`r`nif /I `"%1`"==`"plugin`" if /I `"%2`"==`"list`" type `"%CYC_FAKE_PLUGIN_LIST%`"& exit /b 0`r`nexit /b 0`r`n"
        )
        $activeResult = Invoke-CodexIntegration -Plan $activationPlan -Operation Install
        Assert-True ($activeResult.succeeded -and $activeResult.pluginVerified) 'exact installed and enabled plugin receipt passes activation verification'
        Assert-True ($activeResult.pluginVersion -eq '0.1.0') 'active-plugin receipt records the exact manifest version'
        Assert-True ([string]::Equals(
            $activeResult.pluginSourcePath,
            (Join-Path $payload 'integrations\codex-marketplace\plugins\cluster-your-codex'),
            [System.StringComparison]::OrdinalIgnoreCase
        )) 'active-plugin receipt records the exact local source path'
    } finally {
        if ($null -eq $oldActivationCli) {
            Remove-Item Env:\CYC_CODEX_CLI -ErrorAction SilentlyContinue
        } else {
            $env:CYC_CODEX_CLI = $oldActivationCli
        }
        if ($null -eq $oldPluginListPath) {
            Remove-Item Env:\CYC_FAKE_PLUGIN_LIST -ErrorAction SilentlyContinue
        } else {
            $env:CYC_FAKE_PLUGIN_LIST = $oldPluginListPath
        }
    }

    # The GUI-facing IntegrateCodex action is deliberately non-elevated and
    # Codex-only: it verifies the already-active plugin, journals the additive
    # AGENTS.md range, publishes its manifest receipt, and emits one JSON line.
    $codexOnlyInstall = Join-Path $testRoot 'codex-only-install'
    $codexOnlyData = Join-Path $testRoot 'codex-only-data'
    $codexOnlyHome = Join-Path $testRoot 'codex-only-home'
    $codexOnlyPlan = Get-InstallPlan `
        -BundleRoot $payload `
        -InstallRoot $codexOnlyInstall `
        -DataRoot $codexOnlyData `
        -CodexHome $codexOnlyHome
    Install-PlannedFiles -Plan $codexOnlyPlan
    $codexOnlyInitialResult = [PSCustomObject]@{
        attempted = $true
        cliFound = $true
        succeeded = $true
        marketplaceAdded = $true
        pluginAdded = $true
        pluginVerified = $true
        pluginVerificationExitCode = 0
        pluginVerificationReason = 'verified'
        pluginVersion = '0.1.0'
        pluginSourceType = 'local'
        pluginSourcePath = (Join-Path $codexOnlyPlan.codexIntegration.marketplaceRoot 'plugins\cluster-your-codex')
        pluginExitCode = 0
        marketplaceExitCode = 0
    }
    $codexOnlyDisabledAgents = New-CycDisabledAgentsIntegrationRecord `
        -Plan $codexOnlyPlan `
        -Reason 'deferred-gui-integration'
    Write-InstallManifest `
        -Plan $codexOnlyPlan `
        -CodexResult $codexOnlyInitialResult `
        -AgentsResult $codexOnlyDisabledAgents

    $codexOnlyFakeBin = Join-Path $testRoot 'codex-only-fake-bin'
    $codexOnlyFakeCli = Join-Path $codexOnlyFakeBin 'codex.cmd'
    $codexOnlyPluginList = Join-Path $testRoot 'codex-only-plugin-list.json'
    [void](New-Item -ItemType Directory -Path $codexOnlyFakeBin -Force)
    [System.IO.File]::WriteAllText(
        $codexOnlyFakeCli,
        "@echo off`r`nif /I `"%1`"==`"--version`" echo codex-cli 0.149.0-test& exit /b 0`r`nif /I `"%1`"==`"plugin`" if /I `"%2`"==`"list`" type `"%CYC_FAKE_PLUGIN_LIST%`"& exit /b 0`r`nexit /b 12`r`n"
    )
    $codexOnlySource = Join-Path $codexOnlyPlan.codexIntegration.marketplaceRoot 'plugins\cluster-your-codex'
    $oldCodexOnlyCli = $env:CYC_CODEX_CLI
    $oldCodexOnlyList = $env:CYC_FAKE_PLUGIN_LIST
    try {
        $env:CYC_CODEX_CLI = $codexOnlyFakeCli
        $env:CYC_FAKE_PLUGIN_LIST = $codexOnlyPluginList

        # Version drift is rejected before a journal or AGENTS.md write.
        Write-FakeCodexPluginList `
            -Path $codexOnlyPluginList `
            -SourcePath $codexOnlySource `
            -Version '9.9.9'
        [byte[]]$beforePluginFailureManifest = [System.IO.File]::ReadAllBytes($codexOnlyPlan.manifestPath)
        $pluginVersionRejected = $false
        try {
            [void](Invoke-CycCodexOnlyIntegration `
                -InstallRoot $codexOnlyInstall `
                -DataRoot $codexOnlyData `
                -CodexHome $codexOnlyHome `
                -CodexCliPath $codexOnlyFakeCli)
        } catch {
            $pluginVersionRejected = ($_.Exception.Message -match 'version-mismatch')
        }
        Assert-True $pluginVersionRejected 'IntegrateCodex rejects an active plugin with a mismatched list version'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $codexOnlyHome 'AGENTS.md'))) 'plugin verification failure writes no AGENTS.md block'
        Assert-BytesEqual $beforePluginFailureManifest ([System.IO.File]::ReadAllBytes($codexOnlyPlan.manifestPath)) 'plugin verification failure leaves the install manifest unchanged'

        Write-FakeCodexPluginList -Path $codexOnlyPluginList -SourcePath $codexOnlySource
        $codexOnlyInstalledTemplate = Join-Path $codexOnlyInstall 'integrations\codex\cluster-agents-block.md'
        [byte[]]$ownedTemplateBytes = [System.IO.File]::ReadAllBytes($codexOnlyInstalledTemplate)
        [System.IO.File]::AppendAllText($codexOnlyInstalledTemplate, "`r`n# tampered")
        $templateTamperRejected = $false
        $templateTamperError = ''
        try {
            [void](Invoke-CycCodexOnlyIntegration `
                -InstallRoot $codexOnlyInstall `
                -DataRoot $codexOnlyData `
                -CodexHome $codexOnlyHome `
                -CodexCliPath $codexOnlyFakeCli)
        } catch {
            $templateTamperError = $_.Exception.Message
            $templateTamperRejected = ($_.Exception.Message -match 'metadata changed|SHA-256 validation')
        }
        Assert-True $templateTamperRejected "IntegrateCodex validates the installed AGENTS.md template against the installer manifest ($templateTamperError)"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $codexOnlyHome 'AGENTS.md'))) 'tampered installed template is rejected before AGENTS.md mutation'
        [System.IO.File]::WriteAllBytes($codexOnlyInstalledTemplate, $ownedTemplateBytes)

        # The marketplace payload is an exact one-to-one catalog gate before
        # any Codex CLI process or global AGENTS.md transaction can start.
        $catalogFile = Join-Path $codexOnlySource '.mcp.json'
        [byte[]]$catalogFileBytes = [System.IO.File]::ReadAllBytes($catalogFile)
        Remove-Item -LiteralPath $catalogFile -Force
        Assert-ThrowsLike -Pattern 'missing' -Message 'missing marketplace files fail closed' -Action {
            Get-CycCodexOnlyInstallState -InstallRoot $codexOnlyInstall -DataRoot $codexOnlyData -CodexHome $codexOnlyHome
        }
        [System.IO.File]::WriteAllBytes($catalogFile, $catalogFileBytes)

        $extraCatalogFile = Join-Path $codexOnlySource 'mcp\dist\unowned.js'
        [System.IO.File]::WriteAllText($extraCatalogFile, '// extra')
        Assert-ThrowsLike -Pattern 'extra file' -Message 'extra marketplace files fail closed' -Action {
            Get-CycCodexOnlyInstallState -InstallRoot $codexOnlyInstall -DataRoot $codexOnlyData -CodexHome $codexOnlyHome
        }
        Remove-Item -LiteralPath $extraCatalogFile -Force

        [byte[]]$sameLengthTamper = [byte[]]$catalogFileBytes.Clone()
        $sameLengthTamper[0] = $sameLengthTamper[0] -bxor 1
        [System.IO.File]::WriteAllBytes($catalogFile, $sameLengthTamper)
        Assert-ThrowsLike -Pattern 'SHA-256' -Message 'same-length marketplace tampering fails closed' -Action {
            Get-CycCodexOnlyInstallState -InstallRoot $codexOnlyInstall -DataRoot $codexOnlyData -CodexHome $codexOnlyHome
        }
        [System.IO.File]::WriteAllBytes($catalogFile, $catalogFileBytes)

        [byte[]]$catalogManifestBytes = [System.IO.File]::ReadAllBytes($codexOnlyPlan.manifestPath)
        $duplicateCatalogManifest = Read-InstallManifest -ManifestPath $codexOnlyPlan.manifestPath
        $duplicateCatalogEntry = @($duplicateCatalogManifest.files | Where-Object {
            [string]$_.relativePath -eq 'integrations/codex-marketplace/plugins/cluster-your-codex/.mcp.json'
        })[0]
        $duplicateCatalogManifest.files = @($duplicateCatalogManifest.files) + @($duplicateCatalogEntry)
        Write-DurableAtomicJson -Path $codexOnlyPlan.manifestPath -Value $duplicateCatalogManifest -Depth 20
        Assert-ThrowsLike -Pattern 'duplicate' -Message 'duplicate marketplace receipts fail closed' -Action {
            Get-CycCodexOnlyInstallState -InstallRoot $codexOnlyInstall -DataRoot $codexOnlyData -CodexHome $codexOnlyHome
        }
        [System.IO.File]::WriteAllBytes($codexOnlyPlan.manifestPath, $catalogManifestBytes)

        $invalidPathManifest = Read-InstallManifest -ManifestPath $codexOnlyPlan.manifestPath
        $invalidPathEntry = @($invalidPathManifest.files | Where-Object {
            [string]$_.relativePath -eq 'integrations/codex-marketplace/plugins/cluster-your-codex/.mcp.json'
        })[0]
        $invalidPathEntry.relativePath = 'integrations/codex-marketplace/../escape.json'
        Write-DurableAtomicJson -Path $codexOnlyPlan.manifestPath -Value $invalidPathManifest -Depth 20
        Assert-ThrowsLike -Pattern 'path segment' -Message 'non-strict marketplace receipt paths fail closed' -Action {
            Get-CycCodexOnlyInstallState -InstallRoot $codexOnlyInstall -DataRoot $codexOnlyData -CodexHome $codexOnlyHome
        }
        [System.IO.File]::WriteAllBytes($codexOnlyPlan.manifestPath, $catalogManifestBytes)

        $junctionTarget = Join-Path $testRoot 'junction-target'
        $junctionPath = Join-Path $codexOnlySource 'mcp\dist\reparse-dir'
        [void](New-Item -ItemType Directory -Path $junctionTarget -Force)
        [void](New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget -Force)
        try {
            Assert-ThrowsLike -Pattern 'reparse' -Message 'marketplace reparse points fail closed' -Action {
                Get-CycCodexOnlyInstallState -InstallRoot $codexOnlyInstall -DataRoot $codexOnlyData -CodexHome $codexOnlyHome
            }
        } finally {
            Remove-Item -LiteralPath $junctionPath -Force
        }

        [void](New-Item -ItemType Directory -Path $codexOnlyHome -Force)
        [System.IO.File]::WriteAllText(
            (Join-Path $codexOnlyHome 'AGENTS.md'),
            "# user-owned-rule`r`n",
            $utf8NoBom
        )
        $poisonCli = Join-Path $testRoot 'poison-codex.cmd'
        $poisonCliMarker = Join-Path $testRoot 'poison-codex-ran.txt'
        [System.IO.File]::WriteAllText(
            $poisonCli,
            "@echo off`r`necho poison>`"$poisonCliMarker`"`r`nexit /b 99`r`n"
        )
        $env:CYC_CODEX_CLI = $poisonCli

        $firstCodexReceipt = Invoke-CycCodexOnlyIntegration `
            -InstallRoot $codexOnlyInstall `
            -DataRoot $codexOnlyData `
            -CodexHome $codexOnlyHome `
            -CodexCliPath $codexOnlyFakeCli
        Assert-True ($firstCodexReceipt.schemaVersion -eq 'cyc.dev/codex-integration-receipt/v1') 'IntegrateCodex emits the versioned machine receipt schema'
        Assert-True ($firstCodexReceipt.status -eq 'installed') 'first IntegrateCodex call reports installed'
        Assert-True ($firstCodexReceipt.pluginVersion -eq '0.1.0') 'IntegrateCodex receipt reports the strictly verified plugin version'
        Assert-True ($firstCodexReceipt.agentsBlockSha256 -match '^[0-9a-f]{64}$') 'IntegrateCodex receipt reports the managed block digest'
        Assert-True ($firstCodexReceipt.payloadCatalogSha256 -match '^[0-9a-f]{64}$' -and
            $firstCodexReceipt.buildCatalogSha256 -match '^[0-9a-f]{64}$' -and
            $firstCodexReceipt.installManifestSha256 -match '^[0-9a-f]{64}$') 'IntegrateCodex receipt binds payload, build catalog, and manifest digests'
        Assert-True (-not (Test-Path -LiteralPath $poisonCliMarker)) 'IntegrateCodex ignores poisoned CLI discovery environment and uses the exact native CLI path'
        $codexOnlyAgentsPath = Join-Path $codexOnlyHome 'AGENTS.md'
        Assert-True (Test-Path -LiteralPath $codexOnlyAgentsPath -PathType Leaf) 'IntegrateCodex creates AGENTS.md only after plugin verification'
        $firstCodexManifest = Read-InstallManifest -ManifestPath $codexOnlyPlan.manifestPath
        Assert-True ($firstCodexManifest.codexIntegration.integrateCodexReceipt.agentsBlockSha256 -eq $firstCodexReceipt.agentsBlockSha256) 'installer manifest records the public IntegrateCodex receipt'
        Assert-True ($firstCodexManifest.codexIntegration.pluginSourceType -eq 'local') 'installer manifest records the verified local plugin source'
        Assert-True ($firstCodexManifest.agentsIntegration.transactionId -match '^codex-only-') 'installer manifest binds AGENTS.md ownership to the durable transaction id'

        [byte[]]$beforeIdempotentCodex = [System.IO.File]::ReadAllBytes($codexOnlyAgentsPath)
        $secondCodexReceipt = Invoke-CycCodexOnlyIntegration `
            -InstallRoot $codexOnlyInstall `
            -DataRoot $codexOnlyData `
            -CodexHome $codexOnlyHome `
            -CodexCliPath $codexOnlyFakeCli
        Assert-True ($secondCodexReceipt.status -eq 'unchanged') 'repeated IntegrateCodex repair is idempotent'
        Assert-BytesEqual $beforeIdempotentCodex ([System.IO.File]::ReadAllBytes($codexOnlyAgentsPath)) 'idempotent IntegrateCodex does not rewrite AGENTS.md bytes'

        $strictAgentsRecord = (Read-InstallManifest -ManifestPath $codexOnlyPlan.manifestPath).agentsIntegration
        $strictAgentsEvidence = Get-CycStrictAgentsEvidence -Record $strictAgentsRecord
        Assert-True ($strictAgentsEvidence.agentsFileSha256 -eq $secondCodexReceipt.agentsFileSha256 -and
            $strictAgentsEvidence.agentsExternalSha256 -eq $secondCodexReceipt.agentsExternalSha256 -and
            $strictAgentsEvidence.agentsOwnedRangeSha256 -eq $secondCodexReceipt.agentsOwnedRangeSha256) 'read-only AGENTS.md verifier binds full, external, and owned-range evidence'
        [byte[]]$strictAgentsBytes = [System.IO.File]::ReadAllBytes($codexOnlyAgentsPath)
        $strictAgentsText = [System.IO.File]::ReadAllText($codexOnlyAgentsPath, $utf8NoBom)

        [System.IO.File]::WriteAllText(
            $codexOnlyAgentsPath,
            $strictAgentsText.Replace('# user-owned-rule', '# user-owned-drift'),
            $utf8NoBom
        )
        Assert-ThrowsLike -Pattern 'drifted' -Message 'external AGENTS.md byte drift fails the read-only verifier' -Action {
            Get-CycStrictAgentsEvidence -Record $strictAgentsRecord
        }
        [System.IO.File]::WriteAllBytes($codexOnlyAgentsPath, $strictAgentsBytes)

        [System.IO.File]::WriteAllText(
            $codexOnlyAgentsPath,
            $strictAgentsText.Replace('ClusterYourCodex', 'ClusterYourCodey'),
            $utf8NoBom
        )
        Assert-ThrowsLike -Pattern 'drifted' -Message 'managed block drift fails the read-only verifier' -Action {
            Get-CycStrictAgentsEvidence -Record $strictAgentsRecord
        }
        [System.IO.File]::WriteAllBytes($codexOnlyAgentsPath, $strictAgentsBytes)

        [System.IO.File]::AppendAllText(
            $codexOnlyAgentsPath,
            "`r`n" + (Read-CycAgentsTemplate -Path $codexOnlyInstalledTemplate).text.Replace("`n", "`r`n"),
            $utf8NoBom
        )
        Assert-ThrowsLike -Pattern 'drifted|exactly one' -Message 'duplicate managed blocks fail the read-only verifier' -Action {
            Get-CycStrictAgentsEvidence -Record $strictAgentsRecord
        }
        [System.IO.File]::WriteAllBytes($codexOnlyAgentsPath, $strictAgentsBytes)

        $badEvidenceRecord = $strictAgentsRecord | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        $badEvidenceRecord.externalSha256 = '0' * 64
        Assert-ThrowsLike -Pattern 'drifted' -Message 'manifest AGENTS.md evidence tampering fails closed' -Action {
            Get-CycStrictAgentsEvidence -Record $badEvidenceRecord
        }

        # Simulate a staged template upgrade and a crash after its AGENTS.md
        # after-image is durable but before the new manifest receipt exists.
        $installedCodexTemplate = $codexOnlyInstalledTemplate
        $upgradedCodexTemplate = (Get-Content -LiteralPath $installedCodexTemplate -Raw).Replace(
            '<!-- CLUSTERYOURCODEX-MANAGED:END -->',
            "- IntegrateCodex crash-recovery fixture.`r`n<!-- CLUSTERYOURCODEX-MANAGED:END -->"
        )
        [System.IO.File]::WriteAllText($installedCodexTemplate, $upgradedCodexTemplate, $utf8NoBom)
        $upgradeCodexManifest = Read-InstallManifest -ManifestPath $codexOnlyPlan.manifestPath
        $templateReceipts = @($upgradeCodexManifest.files | Where-Object {
            [string]$_.relativePath -eq 'integrations/codex/cluster-agents-block.md'
        })
        Assert-True ($templateReceipts.Count -eq 1) 'upgrade fixture has one owned template receipt'
        $templateReceipts[0].sha256 = (Get-FileHash -LiteralPath $installedCodexTemplate -Algorithm SHA256).Hash.ToLowerInvariant()
        $templateReceipts[0].length = [long](Get-Item -LiteralPath $installedCodexTemplate).Length
        $upgradeCodexManifest.buildCatalogSha256 = Get-CycFileCatalogDigest -Entries @($upgradeCodexManifest.files)
        $upgradeCodexManifest.codexIntegration.buildCatalogSha256 = $upgradeCodexManifest.buildCatalogSha256
        Write-DurableAtomicJson -Path $codexOnlyPlan.manifestPath -Value $upgradeCodexManifest -Depth 20

        $crashState = Get-CycCodexOnlyInstallState `
            -InstallRoot $codexOnlyInstall `
            -DataRoot $codexOnlyData `
            -CodexHome $codexOnlyHome
        $crashRoot = New-CycCodexOnlyTransactionRoot -DataRoot $codexOnlyData
        $crashTransaction = Start-CycAgentsInstallTransaction `
            -Plan $crashState.plan `
            -OldManifest $crashState.manifest `
            -TransactionRoot $crashRoot `
            -PluginReceipt $verifiedPluginReceipt
        [System.IO.File]::AppendAllText($codexOnlyAgentsPath, "`r`n# user-edit-during-integrate-crash", $utf8NoBom)
        Assert-True ((Read-CycAgentsJournal -Path $crashTransaction.journalPath).phase -eq 'applied') 'IntegrateCodex crash fixture stops after the durable AGENTS.md after-image'
        $repairedCodexReceipt = Invoke-CycCodexOnlyIntegration `
            -InstallRoot $codexOnlyInstall `
            -DataRoot $codexOnlyData `
            -CodexHome $codexOnlyHome `
            -CodexCliPath $codexOnlyFakeCli
        Assert-True ($repairedCodexReceipt.status -eq 'repaired') 'IntegrateCodex restart reconciles the crash and repairs the owned block'
        $repairedCodexText = [System.IO.File]::ReadAllText($codexOnlyAgentsPath, $utf8NoBom)
        Assert-True ($repairedCodexText -match 'IntegrateCodex crash-recovery fixture') 'repair installs the new controller-owned template'
        Assert-True ($repairedCodexText.EndsWith('# user-edit-during-integrate-crash', [System.StringComparison]::Ordinal)) 'crash rollback and repair preserve the outside concurrent edit'

        # Native GUI contract: success is exactly one bounded JSON object on
        # stdout; source drift is nonzero with empty stdout and no file write.
        $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $nativeManifestSha = (Get-FileHash -LiteralPath $codexOnlyPlan.manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $nativeError = Join-Path $testRoot 'integrate-codex-native.stderr'
        $nativeOutput = @(& $windowsPowerShell `
            -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File $bootstrap `
            -Action IntegrateCodex `
            -InstallRoot $codexOnlyInstall `
            -DataRoot $codexOnlyData `
            -CodexHome $codexOnlyHome `
            -CodexCliPath $codexOnlyFakeCli `
            -ExpectedInstallManifestSha256 $nativeManifestSha 2> $nativeError)
        $nativeExit = $LASTEXITCODE
        $nativeErrorText = if (Test-Path -LiteralPath $nativeError) { Get-Content -LiteralPath $nativeError -Raw } else { '' }
        Assert-True ($nativeExit -eq 0 -and $nativeOutput.Count -eq 1) "native IntegrateCodex succeeds with exactly one stdout line (exit=$nativeExit count=$($nativeOutput.Count) stderr=$nativeErrorText)"
        Assert-True ([System.Text.Encoding]::UTF8.GetByteCount([string]$nativeOutput[0]) -le 4096) 'native IntegrateCodex stdout receipt is bounded'
        $nativeReceipt = [string]$nativeOutput[0] | ConvertFrom-Json
        Assert-True ($nativeReceipt.status -eq 'unchanged' -and
            $nativeReceipt.schemaVersion -eq 'cyc.dev/codex-integration-receipt/v1') 'native IntegrateCodex stdout is the documented JSON schema'

        Write-FakeCodexPluginList `
            -Path $codexOnlyPluginList `
            -SourcePath (Join-Path $testRoot 'wrong-plugin-source')
        [byte[]]$beforeNativeFailureAgents = [System.IO.File]::ReadAllBytes($codexOnlyAgentsPath)
        $nativeFailureError = Join-Path $testRoot 'integrate-codex-native-failure.stderr'
        $previousNativeErrorPreference = $ErrorActionPreference
        try {
            # Windows PowerShell 5.1 promotes a child process's redirected
            # stderr to NativeCommandError when the caller uses Stop.
            $ErrorActionPreference = 'Continue'
            $nativeFailureOutput = @(& $windowsPowerShell `
                -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
                -File $bootstrap `
                -Action IntegrateCodex `
                -InstallRoot $codexOnlyInstall `
                -DataRoot $codexOnlyData `
                -CodexHome $codexOnlyHome `
                -CodexCliPath $codexOnlyFakeCli `
                -ExpectedInstallManifestSha256 $nativeManifestSha 2> $nativeFailureError)
            $nativeFailureExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousNativeErrorPreference
        }
        Assert-True ($nativeFailureExit -ne 0 -and $nativeFailureOutput.Count -eq 0) 'native IntegrateCodex failure is nonzero with empty stdout'
        Assert-BytesEqual $beforeNativeFailureAgents ([System.IO.File]::ReadAllBytes($codexOnlyAgentsPath)) 'native plugin-source failure does not write AGENTS.md'
        Assert-True ((Get-Content -LiteralPath $nativeFailureError -Raw).Length -le 4096) 'native IntegrateCodex stderr is bounded'

        $codexOnlyFunctionStart = $source.IndexOf('function Invoke-CycCodexOnlyIntegration')
        $codexOnlyFunctionEnd = $source.IndexOf('function Assert-CycFirewallReceiptProperties', $codexOnlyFunctionStart)
        Assert-True ($codexOnlyFunctionStart -ge 0 -and $codexOnlyFunctionEnd -gt $codexOnlyFunctionStart) 'Codex-only entrypoint has an auditable function boundary'
        $codexOnlyFunctionBody = $source.Substring(
            $codexOnlyFunctionStart,
            $codexOnlyFunctionEnd - $codexOnlyFunctionStart
        )
        Assert-True ($codexOnlyFunctionBody -notmatch '(?i)Register-CycTask|Unregister-CycTask|ScheduledTask|Firewall|Stop-CycRuntime|Ensure-CycTlsIdentity|controller\.exe|cyc-controller') 'IntegrateCodex entrypoint has no controller, service, task, firewall, or TLS lifecycle call'
    } finally {
        if ($null -eq $oldCodexOnlyCli) {
            Remove-Item Env:\CYC_CODEX_CLI -ErrorAction SilentlyContinue
        } else {
            $env:CYC_CODEX_CLI = $oldCodexOnlyCli
        }
        if ($null -eq $oldCodexOnlyList) {
            Remove-Item Env:\CYC_FAKE_PLUGIN_LIST -ErrorAction SilentlyContinue
        } else {
            $env:CYC_FAKE_PLUGIN_LIST = $oldCodexOnlyList
        }
    }

    $fakeCodexBin = Join-Path $testRoot 'fake-codex-bin'
    $fakeCodex = Join-Path $fakeCodexBin 'codex.cmd'
    $fakeCodexLog = Join-Path $testRoot 'fake-codex.log'
    [void](New-Item -ItemType Directory -Path $fakeCodexBin -Force)
    [System.IO.File]::WriteAllText(
        $fakeCodex,
        "@echo off`r`nif /I `"%1`"==`"--version`" echo codex-cli 0.149.0-test& exit /b 0`r`necho %*>>`"%CYC_FAKE_CODEX_LOG%`"`r`nif /I `"%2`"==`"marketplace`" if /I `"%3`"==`"remove`" exit /b 9`r`nexit /b 0`r`n"
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
    $oldCodexCli = $env:CYC_CODEX_CLI
    try {
        $env:PATH = $fakeCodexBin + [System.IO.Path]::PathSeparator + $oldPath
        $env:CYC_FAKE_CODEX_LOG = $fakeCodexLog
        $env:CYC_CODEX_CLI = $fakeCodex
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
            "@echo off`r`nif /I `"%1`"==`"--version`" echo codex-cli 0.149.0-test& exit /b 0`r`necho %*>>`"%CYC_FAKE_CODEX_LOG%`"`r`nexit /b 0`r`n"
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
        if ($null -eq $oldCodexCli) {
            Remove-Item Env:\CYC_CODEX_CLI -ErrorAction SilentlyContinue
        } else {
            $env:CYC_CODEX_CLI = $oldCodexCli
        }
    }

    $rootTarget = Join-Path $testRoot 'root-target'
    $desktopTarget = Join-Path $testRoot 'desktop-target'
    $mcpDeploy = Join-Path $testRoot 'mcp-deploy'
    $nodeRuntime = Get-ValidatedNodeExecutable
    $nodeLicense = Join-Path $testRoot 'LICENSE.node'
    $preview = Join-Path $testRoot 'preview'
    $workerKits = Join-Path $testRoot 'worker-kits'
    [void](New-Item -ItemType Directory -Path $rootTarget, $desktopTarget, (Join-Path $mcpDeploy 'dist') -Force)
    foreach ($name in @('cyc-controller.exe', 'cyc-worker.exe', 'cyc.exe')) {
        [System.IO.File]::WriteAllText((Join-Path $rootTarget $name), "release-$name")
    }
    [System.IO.File]::WriteAllText((Join-Path $desktopTarget 'ClusterYourCodex.exe'), 'release-gui')
    [System.IO.File]::WriteAllText((Join-Path $mcpDeploy 'dist\server.js'), 'release-mcp')
    [System.IO.File]::WriteAllText((Join-Path $mcpDeploy 'package.json'), '{}')
    [System.IO.File]::WriteAllText($nodeLicense, 'node-license')
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $opensslCommand = Get-Command openssl -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $openssl = if ($opensslCommand) { [string]$opensslCommand.Source } elseif (Test-Path -LiteralPath 'C:\Program Files\Git\usr\bin\openssl.exe') { 'C:\Program Files\Git\usr\bin\openssl.exe' } else { throw 'OpenSSL fixture tool is unavailable.' }
    $fixtureSigningKey = Join-Path $testRoot 'worker-kit-fixture-private.pem'
    $fixturePublicDer = Join-Path $testRoot 'worker-kit-fixture-public.der'
    $fixturePublicKey = Join-Path $testRoot 'worker-kit-fixture-public.b64'
    & $openssl genpkey -algorithm ED25519 -out $fixtureSigningKey
    if ($LASTEXITCODE -ne 0) { throw 'Failed to generate preview worker-kit fixture signing key.' }
    & $openssl pkey -in $fixtureSigningKey -pubout -outform DER -out $fixturePublicDer
    if ($LASTEXITCODE -ne 0) { throw 'Failed to derive preview worker-kit fixture public key.' }
    $fixturePublicDerBytes = [System.IO.File]::ReadAllBytes($fixturePublicDer)
    if ($fixturePublicDerBytes.Length -ne 44) { throw 'Preview worker-kit fixture key is not Ed25519.' }
    [System.IO.File]::WriteAllText(
        $fixturePublicKey,
        [Convert]::ToBase64String([byte[]]$fixturePublicDerBytes[12..43]) + "`n",
        (New-Object System.Text.UTF8Encoding($false))
    )
    foreach ($target in @('windows-x86_64', 'linux-x86_64', 'linux-aarch64')) {
        & (Join-Path $repoRoot 'packaging\worker-kits\New-WorkerKit.ps1') `
            -Target $target `
            -WorkerExecutable (Join-Path $rootTarget 'cyc-worker.exe') `
            -OutputDirectory (Join-Path $workerKits "artifact-$target") `
            -SigningKeyPath $fixtureSigningKey `
            -SigningKeyId 'cyc-release-2026-01' `
            -TrustedPublicKeyPath $fixturePublicKey | Out-Null
    }
    $sourceMcpManifest = Join-Path $repoRoot 'plugins\cluster-your-codex\.mcp.json'
    $sourceMcpHash = (Get-FileHash -LiteralPath $sourceMcpManifest -Algorithm SHA256).Hash
    & (Join-Path $PSScriptRoot 'New-PreviewPayload.ps1') `
        -RepositoryRoot $repoRoot `
        -RootCargoTarget $rootTarget `
        -DesktopCargoTarget $desktopTarget `
        -McpDeployRoot $mcpDeploy `
        -NodeExecutable $nodeRuntime `
        -NodeLicense $nodeLicense `
        -WorkerKitsRoot $workerKits `
        -OutputRoot $preview | Out-Null
    Assert-True (Test-Path -LiteralPath (Join-Path $preview 'bootstrap.ps1') -PathType Leaf) 'preview contains bootstrap'
    Assert-True (Test-Path -LiteralPath (Join-Path $preview 'Install-ClusterYourCodex.cmd') -PathType Leaf) 'preview contains double-click installer'
    Assert-True (Test-Path -LiteralPath (Join-Path $preview 'LICENSE') -PathType Leaf) 'preview contains product license'
    Assert-True (Test-Path -LiteralPath (Join-Path $preview 'payload\ClusterYourCodex.exe') -PathType Leaf) 'preview contains GUI'
    Assert-True (Test-Path -LiteralPath (Join-Path $preview 'payload\cyc-worker.exe') -PathType Leaf) 'preview contains worker'
    Assert-True (Test-Path -LiteralPath (Join-Path $preview 'payload\installer\bootstrap.ps1') -PathType Leaf) 'preview installs its bootstrap for repair/uninstall'
    Assert-True (Test-Path -LiteralPath (Join-Path $preview 'payload\installer\Uninstall-ClusterYourCodex.ps1') -PathType Leaf) 'preview installs the elevated uninstaller launcher'
    Assert-True (Test-Path -LiteralPath (Join-Path $preview 'payload\integrations\codex\cluster-agents-block.md') -PathType Leaf) 'preview contains the public managed AGENTS.md block template'
    foreach ($target in @('windows-x86_64', 'linux-x86_64', 'linux-aarch64')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $preview "payload\worker-kits\$target\worker-kit.json") -PathType Leaf) "preview contains $target worker kit"
        Assert-True (Test-Path -LiteralPath (Join-Path $preview "payload\worker-kits\$target\worker-kit.sig") -PathType Leaf) "preview contains $target publisher signature"
        Assert-True (Test-Path -LiteralPath (Join-Path $preview "payload\worker-kits\$target\SHA256SUMS") -PathType Leaf) "preview contains $target worker-kit checksums"
    }
    Assert-True (Test-Path -LiteralPath (Join-Path $preview 'payload\integrations\codex-marketplace\.agents\plugins\marketplace.json') -PathType Leaf) 'preview contains marketplace manifest'
    Assert-True (Test-Path -LiteralPath (Join-Path $preview 'payload\integrations\codex-marketplace\plugins\cluster-your-codex\mcp\dist\server.js') -PathType Leaf) 'preview contains deployable MCP'
    Assert-True (Test-Path -LiteralPath (Join-Path $preview 'payload\integrations\codex-marketplace\plugins\cluster-your-codex\mcp\runtime\node.exe') -PathType Leaf) 'preview contains private Node runtime'
    Assert-True (Test-Path -LiteralPath (Join-Path $preview 'payload\integrations\codex-marketplace\plugins\cluster-your-codex\mcp\runtime\LICENSE.node.txt') -PathType Leaf) 'preview contains Node license'
    $stagedMcp = Get-Content -LiteralPath (Join-Path $preview 'payload\integrations\codex-marketplace\plugins\cluster-your-codex\.mcp.json') -Raw | ConvertFrom-Json
    Assert-True ($stagedMcp.mcpServers.cluster_your_codex.command -eq './mcp/runtime/node.exe') 'staged MCP uses private Node'
    Assert-True ((Get-FileHash -LiteralPath $sourceMcpManifest -Algorithm SHA256).Hash -eq $sourceMcpHash) 'source MCP manifest remains unchanged'
    $previewManifest = Get-Content -LiteralPath (Join-Path $preview 'preview-manifest.json') -Raw | ConvertFrom-Json
    Assert-True (@($previewManifest.workerKits).Count -eq 3) 'preview manifest binds all worker kits'
    $agentsTemplateRecord = @($previewManifest.files | Where-Object { $_.path -eq 'payload/integrations/codex/cluster-agents-block.md' })
    Assert-True ($agentsTemplateRecord.Count -eq 1) 'preview manifest owns exactly one managed AGENTS.md template'
    Assert-True ($agentsTemplateRecord[0].sha256 -eq (Get-FileHash -LiteralPath (Join-Path $preview 'payload\integrations\codex\cluster-agents-block.md') -Algorithm SHA256).Hash.ToLowerInvariant()) 'preview manifest hashes the managed AGENTS.md template'
    Assert-CycPackageManifest `
        -Root $preview `
        -ManifestPath (Join-Path $preview 'preview-manifest.json') `
        -PayloadRoot (Join-Path $preview 'payload')

    # Exercise the actual setup-builder command path without making this test
    # depend on a machine-wide NSIS installation. The stub accepts NSIS-style
    # defines and writes a valid PE-shaped output from the Windows command host.
    $fakeMakeNsis = Join-Path $testRoot 'fake-makensis.cmd'
    @'
@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "output="
set "expectOutput="
for %%A in (%*) do (
    set "argument=%%~A"
    if defined expectOutput (
        set "output=!argument!"
        set "expectOutput="
    ) else if /I "!argument!"=="/DCYC_OUTPUT" (
        set "expectOutput=1"
    )
)
if "!output!"=="" exit /b 2
copy /Y "%ComSpec%" "!output!" >nul
exit /b !ERRORLEVEL!
'@ | Set-Content -LiteralPath $fakeMakeNsis -Encoding ASCII
    $setupOutput = Join-Path $testRoot 'setup-output\ClusterYourCodex-Setup.exe'
    $setupResult = @(& (Join-Path $PSScriptRoot 'New-SetupExecutable.ps1') `
        -PackageRoot $preview `
        -OutputPath $setupOutput `
        -MakeNsisPath $fakeMakeNsis `
        -Force)
    Assert-True (Test-Path -LiteralPath $setupOutput -PathType Leaf) 'setup builder passes a non-empty output path to NSIS'
    Assert-True (Test-Path -LiteralPath ($setupOutput + '.sha256') -PathType Leaf) 'setup builder writes its SHA-256 sidecar'
    Assert-True ($setupResult.Count -eq 1 -and [string]$setupResult[0].setupPath -eq $setupOutput) 'setup builder returns the generated setup path'

    $tamperedPackage = Join-Path $testRoot 'tampered-package'
    Copy-Item -LiteralPath $preview -Destination $tamperedPackage -Recurse
    [System.IO.File]::AppendAllText((Join-Path $tamperedPackage 'payload\ClusterYourCodex.exe'), 'tampered')
    $tamperedPackageRejected = $false
    try {
        Assert-CycPackageManifest `
            -Root $tamperedPackage `
            -ManifestPath (Join-Path $tamperedPackage 'preview-manifest.json') `
            -PayloadRoot (Join-Path $tamperedPackage 'payload')
    } catch { $tamperedPackageRejected = ($_.Exception.Message -match 'SHA-256|metadata') }
    Assert-True $tamperedPackageRejected 'tampered setup payload is rejected before install planning'
    $productLicenseHash = (Get-FileHash -LiteralPath (Join-Path $preview 'LICENSE') -Algorithm SHA256).Hash.ToLowerInvariant()
    $productLicenseRecord = @($previewManifest.files | Where-Object { $_.path -eq 'LICENSE' })
    Assert-True ($productLicenseRecord.Count -eq 1) 'preview manifest owns the product license'
    Assert-True ($productLicenseRecord[0].sha256 -eq $productLicenseHash) 'preview manifest hashes the product license'
    $previewChecksums = Get-Content -LiteralPath (Join-Path $preview 'SHA256SUMS') -Raw
    Assert-True ($previewChecksums -match 'preview-manifest\.json') 'checksums cover preview manifest'
    Assert-True ($previewChecksums -match "(?m)^$productLicenseHash  LICENSE`r?$") 'checksums cover the product license'
    foreach ($relative in @(
        'Invoke-ClusterYourCodexLifecycle.ps1',
        'Invoke-ClusterYourCodexFirewall.ps1',
        'payload/installer/Invoke-ClusterYourCodexLifecycle.ps1',
        'payload/installer/Invoke-ClusterYourCodexFirewall.ps1'
    )) {
        $record = @($previewManifest.files | Where-Object { [string]$_.path -ceq $relative })
        $stagedPath = Join-Path $preview $relative.Replace('/', '\')
        Assert-True ($record.Count -eq 1 -and (Test-Path -LiteralPath $stagedPath -PathType Leaf)) "package includes $relative exactly once"
        Assert-True ([string]$record[0].sha256 -ceq (Get-FileHash -LiteralPath $stagedPath -Algorithm SHA256).Hash.ToLowerInvariant()) "package hashes $relative"
    }

    $lifecycleScript = Join-Path $PSScriptRoot 'Invoke-ClusterYourCodexLifecycle.ps1'
    $firewallScript = Join-Path $PSScriptRoot 'Invoke-ClusterYourCodexFirewall.ps1'
    . $lifecycleScript -Action Install -BundleRoot $payload -PackageRoot $preview -PackageManifest (Join-Path $preview 'preview-manifest.json')
    . $firewallScript -RequestPath 'C:\fixture\request.json' -ExpectedRequestSha256 ('0' * 64) -ExpectedHelperSha256 ('0' * 64)
    $binding = Get-CycInitiatorBinding
    $typedCoordinatorPlan = Get-CycValidatedInstallPlan `
        -BootstrapFile $bootstrap `
        -RequestedBundleRoot (Join-Path $preview 'payload') `
        -RequestedPackageRoot $preview `
        -RequestedPackageManifest (Join-Path $preview 'preview-manifest.json') `
        -RequestedPackageExecutable $lifecycleScript `
        -SignatureRequired $false `
        -Binding $binding `
        -Roots ([PSCustomObject]@{ installRoot = $install; dataRoot = $data }) `
        -TransactionId ([Guid]::NewGuid().ToString('N'))
    Assert-True ($typedCoordinatorPlan.managedWorker.firewall.lifecycle -eq 'external-elevated-helper') 'coordinator obtains a typed manifest-validated plan before UAC'
    $fakeBinding = [PSCustomObject]@{
        sid = 'S-1-5-21-100-200-300-1001'
        profile = 'C:\Users\InitiatingUser'
        localAppData = 'C:\Users\InitiatingUser\AppData\Local'
    }
    $fakeRoots = Assert-CycDefaultPerUserRoots `
        -Binding $fakeBinding `
        -RequestedInstallRoot 'C:\Users\InitiatingUser\AppData\Local\Programs\ClusterYourCodex' `
        -RequestedDataRoot 'C:\Users\InitiatingUser\AppData\Local\ClusterYourCodex'
    Assert-True ($fakeRoots.installRoot -like 'C:\Users\InitiatingUser\*') 'simulated over-the-shoulder admin cannot redirect the initiating profile'

    $transactionId = [Guid]::NewGuid().ToString('N')
    $exchangeBase = Join-Path $testRoot 'firewall-exchange'
    $sidExchange = Join-Path $exchangeBase $binding.sid.Replace('-', '_')
    $requestExchange = Join-Path $sidExchange $transactionId
    [void](New-Item -ItemType Directory -Path $requestExchange -Force)
    $requestPath = Join-Path $requestExchange 'request.json'
    $validRequest = [ordered]@{
        schemaVersion = 'cyc.dev/windows-firewall-request/v1'
        transactionId = $transactionId
        requestNonce = ('a' * 64)
        action = 'Apply'
        createdAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        deadlineUtc = [DateTimeOffset]::UtcNow.AddMinutes(10).ToString('o')
        initiatorSid = $binding.sid
        initiatorProfile = $binding.profile
        initiatorLocalAppData = $binding.localAppData
        installRoot = Join-Path $binding.localAppData 'Programs\ClusterYourCodex'
        program = Join-Path $binding.localAppData 'Programs\ClusterYourCodex\cyc-controller.exe'
        programSha256 = ('b' * 64)
        port = 47832
        ruleName = 'ClusterYourCodex.ManagedWorker.' + $binding.sid.Replace('-', '_')
        displayName = 'ClusterYourCodex Managed Worker'
        group = 'ClusterYourCodex'
        ruleDescription = 'ClusterYourCodex owned managed-worker TLS listener'
        remoteAddress = 'LocalSubnet'
        exchangeRoot = $requestExchange
        packageManifestSha256 = ('c' * 64)
        packageExecutable = $lifecycleScript
        helperAuthenticodeRequired = $false
    }
    $validRequest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestPath -Encoding UTF8
    $requestObject = Convert-CycPackagingJson (Get-Content -LiteralPath $requestPath -Raw)
    $requestHash = (Get-FileHash -LiteralPath $requestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $helperHash = (Get-FileHash -LiteralPath $firewallScript -Algorithm SHA256).Hash.ToLowerInvariant()
    $profileResolver = { param($sid) $binding.profile }.GetNewClosure()
    $exchangeResolver = { param($sid) $sidExchange }.GetNewClosure()
    [void](Assert-CycFirewallRequestBinding `
        -Request $requestObject `
        -RequestFile $requestPath `
        -ExpectedRequestHash $requestHash `
        -ObservedHelperHash $helperHash `
        -ExpectedHelperHash $helperHash `
        -ProfileResolver $profileResolver `
        -ExchangeBaseResolver $exchangeResolver)

    Add-Content -LiteralPath $requestPath -Value 'tamper'
    Assert-ThrowsLike -Pattern 'changed' -Message 'helper rejects request tamper after coordinator approval' -Action {
        [void](Assert-CycFirewallRequestBinding `
            -Request $requestObject `
            -RequestFile $requestPath `
            -ExpectedRequestHash $requestHash `
            -ObservedHelperHash $helperHash `
            -ExpectedHelperHash $helperHash `
            -ProfileResolver $profileResolver `
            -ExchangeBaseResolver $exchangeResolver)
    }
    $validRequest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestPath -Encoding UTF8
    $requestObject = Convert-CycPackagingJson (Get-Content -LiteralPath $requestPath -Raw)
    $requestHash = (Get-FileHash -LiteralPath $requestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-ThrowsLike -Pattern 'helper or request digest' -Message 'helper rejects a package helper hash mismatch' -Action {
        [void](Assert-CycFirewallRequestBinding `
            -Request $requestObject `
            -RequestFile $requestPath `
            -ExpectedRequestHash $requestHash `
            -ObservedHelperHash ('d' * 64) `
            -ExpectedHelperHash $helperHash `
            -ProfileResolver $profileResolver `
            -ExchangeBaseResolver $exchangeResolver)
    }
    $badProgram = Convert-CycPackagingJson (Get-Content -LiteralPath $requestPath -Raw)
    $badProgram.program = 'C:\Windows\System32\cmd.exe'
    $badProgram | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestPath -Encoding UTF8
    $badProgramHash = (Get-FileHash -LiteralPath $requestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-ThrowsLike -Pattern 'fixed product paths' -Message 'helper rejects an arbitrary program path' -Action {
        [void](Assert-CycFirewallRequestBinding `
            -Request $badProgram `
            -RequestFile $requestPath `
            -ExpectedRequestHash $badProgramHash `
            -ObservedHelperHash $helperHash `
            -ExpectedHelperHash $helperHash `
            -ProfileResolver $profileResolver `
            -ExchangeBaseResolver $exchangeResolver)
    }
    $badRule = Convert-CycPackagingJson (Get-Content -LiteralPath $requestPath -Raw)
    $badRule.program = [string]$validRequest.program
    $badRule.ruleName = 'ArbitraryRule'
    Assert-ThrowsLike -Pattern 'fixed rule identity' -Message 'helper rejects an arbitrary rule name' -Action {
        [void](Assert-CycFirewallRequestShape -Request $badRule)
    }
    $badPort = Convert-CycPackagingJson (Get-Content -LiteralPath $requestPath -Raw)
    $badPort.program = [string]$validRequest.program
    $badPort.port = 70000
    Assert-ThrowsLike -Pattern 'metadata' -Message 'helper rejects an out-of-range TCP port' -Action {
        [void](Assert-CycFirewallRequestShape -Request $badPort)
    }
    $validRequest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestPath -Encoding UTF8
    $requestObject = Convert-CycPackagingJson (Get-Content -LiteralPath $requestPath -Raw)
    $requestHash = (Get-FileHash -LiteralPath $requestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $wrongProfileResolver = { param($sid) 'C:\Users\ElevatedAdmin' }
    Assert-ThrowsLike -Pattern 'SID and profile binding' -Message 'different elevated account/profile binding fails closed' -Action {
        [void](Assert-CycFirewallRequestBinding `
            -Request $requestObject `
            -RequestFile $requestPath `
            -ExpectedRequestHash $requestHash `
            -ObservedHelperHash $helperHash `
            -ExpectedHelperHash $helperHash `
            -ProfileResolver $wrongProfileResolver `
            -ExchangeBaseResolver $exchangeResolver)
    }
    $state = [PSCustomObject]@{
        schemaVersion = 'cyc.dev/windows-firewall-state/v1'
        transactionId = $transactionId
        requestSha256 = $requestHash
    }
    [void](Assert-CycFirewallReplayBinding -State $state -TransactionId $transactionId -RequestSha256 $requestHash)
    Assert-ThrowsLike -Pattern 'replay' -Message 'transaction replay with a different request is rejected' -Action {
        [void](Assert-CycFirewallReplayBinding -State $state -TransactionId $transactionId -RequestSha256 ('e' * 64))
    }
    Assert-True ((Get-CycFirewallHelperRecoveryAction -FinalizeSignal:$false -RollbackSignal:$false -Expired:$true) -eq 'Rollback') 'helper timeout selects rollback after install failure or coordinator crash'
    Assert-True ((Get-CycFirewallHelperRecoveryAction -FinalizeSignal:$true -RollbackSignal:$false -Expired:$false) -eq 'Finalize') 'helper finalizes only on explicit coordinator commit'

    $resumeJournal = [PSCustomObject]@{
        schemaVersion = 'cyc.dev/windows-external-lifecycle/v1'
        action = 'Install'
        transactionId = $transactionId
        requestSha256 = $requestHash
        phase = 'coreApplied'
    }
    $resumeReceipt = [PSCustomObject]@{
        transactionId = $transactionId
        requestSha256 = $requestHash
        result = 'verified'
    }
    $pendingManifest = [PSCustomObject]@{
        managedWorker = [PSCustomObject]@{
            firewall = [PSCustomObject]@{ transactionId = $transactionId; state = 'pending' }
        }
    }
    Assert-True ((Get-CycFirewallResumeDecision -Journal $resumeJournal -Receipt $resumeReceipt -Manifest $pendingManifest -RequestedAction Install) -eq 'Commit') 'response loss resumes at receipt commit without another firewall mutation'
    $pendingManifest.managedWorker.firewall.state = 'applied'
    Assert-True ((Get-CycFirewallResumeDecision -Journal $resumeJournal -Receipt $resumeReceipt -Manifest $pendingManifest -RequestedAction Install) -eq 'Complete') 'repeated install after committed response is idempotent'

    $wrapper = Get-Content -LiteralPath (Join-Path $preview 'Install-ClusterYourCodex.cmd') -Raw
    Assert-True ($wrapper -match '%~dp0') 'wrapper resolves its own directory'
    Assert-True ($wrapper -match 'exit /b %CYC_EXIT_CODE%') 'wrapper propagates install failure'
    Assert-True ($wrapper -notmatch '(?i)-Verb\s+RunAs|--elevated') 'portable wrapper never elevates the whole lifecycle'
    Assert-True ($wrapper -match 'Invoke-ClusterYourCodexLifecycle\.ps1') 'portable wrapper uses the per-user coordinator'
    Assert-True ($wrapper -match '-PackageManifest "%CYC_PREVIEW_ROOT%preview-manifest\.json"') 'wrapper verifies the package manifest before install'
    Assert-True ($wrapper -match 'explorer\.exe "%LOCALAPPDATA%\\Programs\\ClusterYourCodex\\ClusterYourCodex\.exe"') 'wrapper launches installed GUI through Explorer'
    Assert-True ($wrapper -notmatch '(?i)Bearer|authorization|--token\s') 'wrapper contains no raw secret channel'

    $lifecycleSource = Get-Content -LiteralPath $lifecycleScript -Raw
    $firewallSource = Get-Content -LiteralPath $firewallScript -Raw
    $uninstallerSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Uninstall-ClusterYourCodex.ps1') -Raw
    Assert-True (([regex]::Matches($lifecycleSource, '(?i)-Verb\s+RunAs')).Count -eq 1) 'coordinator contains exactly one firewall-only elevation site'
    Assert-True ($lifecycleSource -match 'Start-CycFirewallOnlyElevation') 'only the narrow firewall helper crosses UAC'
    Assert-True ($lifecycleSource -match 'InitiatingSid[\s\S]+InitiatingProfile[\s\S]+InitiatingLocalAppData') 'core calls retain the initiating SID/profile binding'
    Assert-True ($uninstallerSource -notmatch '(?i)-Verb\s+RunAs|-Elevated') 'uninstaller stays in initiating HKCU/profile context'
    Assert-True ($uninstallerSource -match 'Invoke-ClusterYourCodexLifecycle\.ps1') 'uninstaller delegates only the firewall sub-step to the coordinator'
    Assert-True ($firewallSource -notmatch '(?i)Invoke-Expression|cmd\.exe|Start-Process|&\s+\$Request') 'elevated helper has no arbitrary command or script channel'
    Assert-True ($firewallSource -match 'Profile Private[\s\S]+Protocol TCP[\s\S]+RemoteAddress LocalSubnet') 'helper fixes Private/TCP/LocalSubnet scope'
    Assert-True ($firewallSource -match 'Restore-CycExactFirewallSnapshot') 'helper retains a durable rollback path for core failure and timeout'

    $nsis = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'ClusterYourCodex.nsi') -Raw
    Assert-True ($nsis -match 'RequestExecutionLevel user') 'Setup.exe remains in the initiating user token'
    Assert-True ($nsis -notmatch 'RequestExecutionLevel admin') 'Setup.exe never switches LOCALAPPDATA/HKCU to an over-the-shoulder admin'
    Assert-True ($nsis -match 'File /r "\$\{CYC_PACKAGE_ROOT\}\\\*\.\*"') 'Setup.exe embeds the complete self-contained package'
    Assert-True ($nsis -match 'Invoke-ClusterYourCodexLifecycle\.ps1[\s\S]+-PackageManifest ') 'Setup.exe invokes the coordinator and manifest validation gate'
    Assert-True ($nsis -match 'SetErrorLevel \$0') 'Setup.exe preserves bootstrap failure status'
    Assert-True ($nsis -notmatch '(?i)Bearer|authorization|--token\s') 'Setup.exe has no raw secret channel'
    $setupBuilder = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'New-SetupExecutable.ps1') -Raw
    Assert-True ($setupBuilder -match 'Assert-CycPackageManifest') 'Setup builder validates the staged payload before embedding it'
    Assert-True ($setupBuilder -match 'Get-AuthenticodeSignature') 'Setup builder reports the signing state honestly'
    Assert-True ($setupBuilder -match 'RequireRuntimeSignature') 'GA setup can enforce Authenticode at runtime after signing'
    Assert-True ($setupBuilder -match "Get-FileHash.+SHA256") 'Setup builder emits a SHA-256 sidecar'
    Assert-True ($setupBuilder -match 'candidateRoots[\s\S]+IsNullOrWhiteSpace') 'Setup builder tolerates a missing ProgramFiles(x86) environment variable'
    Assert-True ($setupBuilder -match 'SpecialFolder\]::ProgramFilesX86') 'Setup builder uses the OS Program Files x86 folder when environment variables are incomplete'
    Assert-True ($setupBuilder -match 'subst\.exe') 'Setup builder maps long package roots to a short NSIS source path'
    $freshDeploymentSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Test-FreshDeployment.ps1') -Raw
    Assert-True (-not $freshDeploymentSource.Contains("'-Confirm:`$false'")) 'fresh deployment smoke never serializes a false SwitchParameter through powershell.exe -File'
    Assert-True ($freshDeploymentSource -match "'-NoLogo', '-NoProfile', '-NonInteractive'") 'fresh deployment smoke launches a clean non-interactive Windows PowerShell child'
    $releaseWorkflow = Get-Content -LiteralPath (Join-Path $repoRoot '.github\workflows\release.yml') -Raw
    Assert-True ($releaseWorkflow -match 'NSIS installation completed but makensis\.exe was not found') 'release workflow validates its explicit NSIS compiler path'
    Assert-True ($releaseWorkflow -match 'New-SetupExecutable\.ps1[\s\S]+-MakeNsisPath \$makeNsis') 'release workflow passes the resolved NSIS compiler into Setup.exe staging'

    [System.IO.File]::AppendAllText((Join-Path $workerKits 'artifact-linux-x86_64\cyc-worker'), 'tampered')
    $tamperedPreview = Join-Path $testRoot 'tampered-preview'
    $tamperedKitRejected = $false
    try {
        & (Join-Path $PSScriptRoot 'New-PreviewPayload.ps1') `
            -RepositoryRoot $repoRoot `
            -RootCargoTarget $rootTarget `
            -DesktopCargoTarget $desktopTarget `
            -McpDeployRoot $mcpDeploy `
            -NodeExecutable $nodeRuntime `
            -NodeLicense $nodeLicense `
            -WorkerKitsRoot $workerKits `
            -OutputRoot $tamperedPreview | Out-Null
    } catch {
        $tamperedKitRejected = ($_.Exception.Message -match 'SHA-256 validation')
    }
    Assert-True $tamperedKitRejected 'tampered worker kit is rejected before preview staging succeeds'

    Write-Output 'Windows packaging static/plan tests passed.'
} finally {
    $resolvedTestRoot = Resolve-NormalizedPath $testRoot
    $resolvedTemp = Resolve-NormalizedPath ([System.IO.Path]::GetTempPath())
    [void](Assert-ChildPath -Root $resolvedTemp -Candidate $resolvedTestRoot)
    if (Test-Path -LiteralPath $resolvedTestRoot) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
