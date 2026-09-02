#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$IdentityCliPath
)

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

function Read-CycPackagingUtf8Json {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
    return Convert-CycPackagingJson -Raw $utf8Strict.GetString($bytes)
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

$nullAgentsTransactionNoOpsSucceeded = $true
try {
    Complete-CycAgentsInstallTransaction -Transaction $null
    Rollback-CycAgentsInstallTransaction -Transaction $null
    Apply-CycAgentsRemovalTransaction -Transaction $null
    Rollback-CycAgentsRemovalTransaction -Transaction $null
    Complete-CycAgentsRemovalTransaction -Transaction $null
} catch {
    $nullAgentsTransactionNoOpsSucceeded = $false
}
Assert-True $nullAgentsTransactionNoOpsSucceeded 'disabled AGENTS.md integration safely skips every absent transaction phase'

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('cyc-packaging-test-' + [Guid]::NewGuid().ToString('N'))
$payload = Join-Path $testRoot 'payload'
$install = Join-Path $testRoot 'install'
$data = Join-Path $testRoot 'data'
$codexHome = Join-Path $testRoot 'codex-home'
try {
    [void](New-Item -ItemType Directory -Path $testRoot -Force)
    $largeManifestPath = Join-Path $testRoot 'large-install-manifest.json'
    $largeManifestJson = '{"schemaVersion":"cyc.dev/windows-install-manifest/v1","padding":"' + ('x' * (2MB)) + '"}'
    [System.IO.File]::WriteAllText($largeManifestPath, $largeManifestJson, [System.Text.UTF8Encoding]::new($false))
    $largeManifest = Read-InstallManifest -ManifestPath $largeManifestPath
    Assert-True ($largeManifest.schemaVersion -eq $script:ManifestSchema) 'install manifest reader accepts a valid self-contained manifest larger than the obsolete 2 MiB cap'

    $oversizedManifestPath = Join-Path $testRoot 'oversized-install-manifest.json'
    $oversizedManifest = [System.IO.File]::Open($oversizedManifestPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try { $oversizedManifest.SetLength($script:MaxInstallManifestBytes + 1) } finally { $oversizedManifest.Dispose() }
    Assert-ThrowsLike `
        -Action { [void](Read-InstallManifest -ManifestPath $oversizedManifestPath) } `
        -Pattern 'unexpectedly large' `
        -Message 'install manifest reader retains a hard maximum size bound'

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
        -WorkerPublicHost '192.168.50.10' `
        -WorkerBindHost '192.168.50.10' `
        -WorkerInterfaceIndex 7 `
        -WorkerControllerHostName 'controller-test' `
        -WorkerPrivateAddress @('192.168.50.10', 'fd12:3456:789a::10')

    Assert-True ($plan.schemaVersion -eq 'cyc.dev/windows-install-manifest/v1') 'plan schema'
    Assert-True ($plan.files.Count -eq @(Get-PayloadFiles -Root $payload).Count) 'all payload files are owned'
    Assert-True ($plan.files.sha256 -notcontains $null) 'every file has a digest'
    Assert-True ($plan.tasks[0].action.arguments -match '^--bind 127\.0\.0\.1:47831 ') 'controller bind is explicit loopback'
    Assert-True ($plan.tasks[0].action.arguments -match '--database "[^\"]+\\controller\.db"') 'controller database path is explicit'
    Assert-True ($plan.tasks[0].action.arguments -match '--token-file "[^\"]+\\controller\.token"') 'controller gets only the token file path'
    Assert-True ($plan.tasks[0].action.arguments -match '--worker-bind 192\.168\.50\.10:47832') 'managed-worker TLS listener has one explicit private bind'
    Assert-True ($plan.tasks[0].action.arguments -notmatch '--worker-bind (?:0\.0\.0\.0|\[?::\]?):') 'managed-worker TLS listener never uses a wildcard bind'
    Assert-True ($plan.tasks[0].action.arguments -match '--worker-public-url "https://192\.168\.50\.10:47832"') 'managed-worker public URL is explicit'
    Assert-True ($plan.tasks[0].action.arguments -match '--worker-cert "[^\"]+\\tls\\managed-worker-v2\\controller\.crt\.pem"') 'controller receives only the versioned certificate path'
    Assert-True ($plan.tasks[0].action.arguments -match '--worker-key "[^\"]+\\tls\\managed-worker-v2\\controller\.key\.pem"') 'controller receives only the versioned private-key path'
    Assert-True ($plan.tasks[0].action.arguments -notmatch '(?i)Bearer|authorization|--token\s') 'controller task has no raw token'
    Assert-True $plan.managedWorker.enabled 'managed worker is enabled by default'
    Assert-True ([string]$plan.managedWorker.networkPlan.schemaVersion -ceq 'cyc.dev/windows-managed-worker-network/v1') 'managed worker has a versioned immutable network plan'
    Assert-True ([int]$plan.managedWorker.networkPlan.selectedInterfaceIndex -eq 7) 'network plan records the selected interface'
    Assert-True ([string]$plan.managedWorker.bindHost -ceq '192.168.50.10') 'managed worker bind host is exact'
    Assert-True ([string]::Join(',', @($plan.managedWorker.networkPlan.privateAddresses)) -ceq '192.168.50.10,fd12:3456:789a::10') 'network plan records the canonical selected private-address set'
    Assert-True ([string]::Join(',', @($plan.managedWorker.identityHosts)) -ceq '127.0.0.1,192.168.50.10,::1,controller-test,fd12:3456:789a::10') 'identity SAN set is exact, canonical, and complete'
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

    $networkConfigurations = @(
        [PSCustomObject]@{
            InterfaceIndex = 3
            NetAdapter = [PSCustomObject]@{ Status = 'Up' }
            IPv4DefaultGateway = $null
            IPv6DefaultGateway = $null
            NetIPv4Interface = [PSCustomObject]@{ InterfaceMetric = 1 }
            NetIPv6Interface = $null
            IPv4Address = @([PSCustomObject]@{ IPAddress = '10.1.2.3'; AddressState = 'Preferred'; SkipAsSource = $false })
            IPv6Address = @()
        },
        [PSCustomObject]@{
            InterfaceIndex = 8
            NetAdapter = [PSCustomObject]@{ Status = 'Up' }
            IPv4DefaultGateway = [PSCustomObject]@{ NextHop = '192.168.80.1' }
            IPv6DefaultGateway = $null
            NetIPv4Interface = [PSCustomObject]@{ InterfaceMetric = 50 }
            NetIPv6Interface = $null
            IPv4Address = @([PSCustomObject]@{ IPAddress = '192.168.80.10'; AddressState = 'Preferred'; SkipAsSource = $false })
            IPv6Address = @()
        },
        [PSCustomObject]@{
            InterfaceIndex = 7
            NetAdapter = [PSCustomObject]@{ Status = 'Up' }
            IPv4DefaultGateway = [PSCustomObject]@{ NextHop = '192.168.50.1' }
            IPv6DefaultGateway = $null
            NetIPv4Interface = [PSCustomObject]@{ InterfaceMetric = 20 }
            NetIPv6Interface = [PSCustomObject]@{ InterfaceMetric = 25 }
            IPv4Address = @(
                [PSCustomObject]@{ IPAddress = '192.168.50.11'; AddressState = 'Preferred'; SkipAsSource = $false },
                [PSCustomObject]@{ IPAddress = '192.168.50.10'; AddressState = 'Preferred'; SkipAsSource = $false },
                [PSCustomObject]@{ IPAddress = '192.0.2.10'; AddressState = 'Preferred'; SkipAsSource = $false }
            )
            IPv6Address = @(
                [PSCustomObject]@{ IPAddress = 'fd12:3456:789a::10'; AddressState = 'Preferred'; SkipAsSource = $false },
                [PSCustomObject]@{ IPAddress = 'fe80::10'; AddressState = 'Preferred'; SkipAsSource = $false }
            )
        }
    )
    $discoveredNetworkPlan = New-CycDiscoveredManagedWorkerNetworkPlan `
        -RequestedPublicHost 'controller.test' `
        -ListenPort 47832 `
        -Configurations $networkConfigurations
    Assert-True ([int]$discoveredNetworkPlan.selectedInterfaceIndex -eq 7) 'network discovery deterministically prefers default route, metric, then interface index'
    Assert-True ([string]$discoveredNetworkPlan.bindHost -ceq '192.168.50.10') 'network discovery deterministically chooses the canonical IPv4 bind on the selected interface'
    Assert-True ([string]::Join(',', @($discoveredNetworkPlan.privateAddresses)) -ceq '192.168.50.10,192.168.50.11,fd12:3456:789a::10') 'network discovery includes only selected-interface RFC1918 and ULA addresses'
    $requestedAddressPlan = New-CycDiscoveredManagedWorkerNetworkPlan `
        -RequestedPublicHost '10.1.2.3' `
        -ListenPort 47832 `
        -Configurations $networkConfigurations
    Assert-True ([int]$requestedAddressPlan.selectedInterfaceIndex -eq 3 -and [string]$requestedAddressPlan.bindHost -ceq '10.1.2.3') 'an assigned requested private IP deterministically selects its owning interface and exact bind'
    Assert-ThrowsLike `
        -Action {
            [void](New-CycManagedWorkerNetworkPlan `
                -InterfaceIndex 7 `
                -BindHost '0.0.0.0' `
                -PublicHost 'controller.test' `
                -ControllerHostName 'controller-test' `
                -PrivateAddresses @('192.168.50.10') `
                -ListenPort 47832)
        } `
        -Pattern 'RFC1918|ULA' `
        -Message 'wildcard worker bind is rejected before task construction'
    Assert-ThrowsLike `
        -Action {
            [void](New-CycDiscoveredManagedWorkerNetworkPlan `
                -RequestedPublicHost '192.0.2.10' `
                -ListenPort 47832 `
                -Configurations $networkConfigurations)
        } `
        -Pattern 'RFC1918|ULA' `
        -Message 'public IP literals are rejected as managed-worker public hosts'

    $reusableManifest = [PSCustomObject]@{
        productVersion = $script:ProductVersion
        managedWorker = [PSCustomObject]@{
            enabled = $true
            networkPlan = $plan.managedWorker.networkPlan
        }
    }
    $reusedNetworkPlan = Resolve-CycManagedWorkerNetworkPlan `
        -ExistingManifest $reusableManifest `
        -ListenPort 47999
    Assert-True (($reusedNetworkPlan | ConvertTo-Json -Depth 6 -Compress) -ceq
        ($plan.managedWorker.networkPlan | ConvertTo-Json -Depth 6 -Compress)) 'repair reuses the complete immutable network plan without rediscovery or default-port drift'
    Assert-ThrowsLike `
        -Action {
            [void](Resolve-CycManagedWorkerNetworkPlan `
                -ExistingManifest $reusableManifest `
                -RequestedPublicHost '192.168.50.11' `
                -ExplicitBindHost '192.168.50.11' `
                -ExplicitInterfaceIndex 7 `
                -ExplicitControllerHostName 'controller-test' `
                -ExplicitPrivateAddresses @('192.168.50.10', '192.168.50.11', 'fd12:3456:789a::10') `
                -ListenPort 47832)
        } `
        -Pattern 'immutable managed-worker network plan' `
        -Message 'repair rejects any replacement of the immutable network plan'
    Assert-True ($null -eq (Get-CycReusableManagedWorkerNetworkPlan -Manifest ([PSCustomObject]@{
        productVersion = '0.1.0-preview.3'
        managedWorker = [PSCustomObject]@{ enabled = $true }
    }))) 'explicit preview.3 legacy state is eligible for versioned identity migration'
    Assert-ThrowsLike `
        -Action {
            [void](Get-CycReusableManagedWorkerNetworkPlan -Manifest ([PSCustomObject]@{
                productVersion = $script:ProductVersion
                managedWorker = [PSCustomObject]@{ enabled = $true }
            }))
        } `
        -Pattern 'missing its immutable network plan' `
        -Message 'current manifests without a network plan fail closed instead of rediscovering'

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
    Assert-True ($source -match 'Assert-CycTaskSnapshotOwnership') 'Scheduled Task lifecycle has an explicit ownership preflight'
    Assert-True ($source -match 'Get-CycTaskExpectedExecutable') 'Scheduled Task ownership binds the task name to its install-root executable'
    Assert-True ($source -match 'action working directory does not match the requested install root') 'Scheduled Task ownership binds the working directory to the install root'
    Assert-True ($source -match 'principal SID does not match the initiating SID') 'Scheduled Task ownership binds the principal to the initiating SID'
    Assert-True ($source -match 'Register-CycTask[\s\S]+ExpectedInstallRoot') 'task replacement receives an explicit expected install root'
    Assert-True ($source -match 'Unregister-CycTask[\s\S]+ExpectedInstallRoot') 'task removal receives an explicit expected install root'
    Assert-True ($source -match 'Restore-CycTaskSnapshots[\s\S]+ExpectedInstallRoot') 'task rollback receives an explicit expected install root'
    Assert-True ($source -match 'function Resolve-CycScheduledTaskAccountName' -and
        $source -match 'Test-CycScheduledTaskAccountNameSidBinding' -and
        $source -match 'ProfileList\\' -and
        $source -match 'ProfileImagePath' -and
        $source -match 'Unable to resolve a SID-bound Scheduled Task account name') 'production Scheduled Task identities resolve from immutable SIDs with fail-closed name binding'
    $registerTaskFunction = [regex]::Match($source, 'function Register-CycTask[\s\S]+?function Unregister-CycTask')
    Assert-True ($registerTaskFunction.Success -and
        $registerTaskFunction.Value -match 'Resolve-CycScheduledTaskAccountName' -and
        $registerTaskFunction.Value -match 'ConvertTo-CycTaskSnapshotSid' -and
        $registerTaskFunction.Value -notmatch 'WindowsIdentity\]::GetCurrent\(\)\.Name') 'production task registration never trusts WindowsIdentity.Name directly'

    # Task ownership fixture: the lifecycle helpers must accept an exact
    # current-user/root binding, while rejecting a foreign SID, executable, or
    # working directory before Stop/Register/Unregister can be reached.
    $taskProbeRoot = Join-Path $testRoot 'task-probe-owned'
    $taskProbeForeignRoot = Join-Path $testRoot 'task-probe-foreign'
    $taskProbeSid = Get-CurrentUserSid
    $taskProbeDisplayName = [string]([System.Security.Principal.WindowsIdentity]::GetCurrent()).Name
    $taskProbeAccountName = Resolve-CycScheduledTaskAccountName `
        -Sid $taskProbeSid `
        -FallbackUserName $taskProbeDisplayName
    Assert-True (-not [string]::IsNullOrWhiteSpace($taskProbeAccountName)) 'current-user Scheduled Task account resolver returns a canonical account name'
    Assert-True (Test-CycScheduledTaskAccountNameSidBinding `
        -AccountName $taskProbeAccountName `
        -ExpectedSid $taskProbeSid) 'current-user Scheduled Task account resolver round-trips to the immutable SID'
    $taskProbeForeignSid = [regex]::Replace($taskProbeSid, '-\d+$', '-1002')
    if ($taskProbeForeignSid -ceq $taskProbeSid) { $taskProbeForeignSid = 'S-1-5-18' }
    $taskProbeAction = [PSCustomObject]@{
        executable = Join-Path $taskProbeRoot 'cyc-controller.exe'
        arguments = '--fixture'
        workingDirectory = $taskProbeRoot
    }
    $taskProbeSnapshot = [PSCustomObject]@{
        name = $script:ControllerTaskName
        xml = '<Task />'
        taskPath = '\'
        principalSid = $taskProbeSid
        triggerSids = @($taskProbeSid)
        action = $taskProbeAction
        wasRunning = $false
    }
    [void](Assert-CycTaskActionBinding `
        -Name $script:ControllerTaskName `
        -InstallRoot $taskProbeRoot `
        -Action $taskProbeAction)
    [void](Assert-CycTaskSnapshotOwnership `
        -Snapshot $taskProbeSnapshot `
        -InstallRoot $taskProbeRoot `
        -ExpectedSid $taskProbeSid)
    $foreignTaskSnapshot = [PSCustomObject]@{
        name = $taskProbeSnapshot.name
        xml = $taskProbeSnapshot.xml
        taskPath = $taskProbeSnapshot.taskPath
        principalSid = $taskProbeForeignSid
        triggerSids = @($taskProbeForeignSid)
        action = $taskProbeSnapshot.action
        wasRunning = $taskProbeSnapshot.wasRunning
    }
    Assert-ThrowsLike `
        -Action {
            [void](Assert-CycTaskSnapshotOwnership `
                -Snapshot $foreignTaskSnapshot `
                -InstallRoot $taskProbeRoot `
                -ExpectedSid $taskProbeSid)
        } `
        -Pattern 'principal SID' `
        -Message 'task ownership rejects a different principal SID'
    $wrongRootSnapshot = [PSCustomObject]@{
        name = $taskProbeSnapshot.name
        xml = $taskProbeSnapshot.xml
        taskPath = $taskProbeSnapshot.taskPath
        principalSid = $taskProbeSnapshot.principalSid
        triggerSids = @($taskProbeSnapshot.triggerSids)
        action = $taskProbeSnapshot.action
        wasRunning = $taskProbeSnapshot.wasRunning
    }
    Assert-ThrowsLike `
        -Action {
            [void](Assert-CycTaskSnapshotOwnership `
                -Snapshot $wrongRootSnapshot `
                -InstallRoot $taskProbeForeignRoot `
                -ExpectedSid $taskProbeSid)
        } `
        -Pattern 'install root' `
        -Message 'task ownership rejects an executable outside the requested install root'
    $wrongWorkingDirectoryAction = [PSCustomObject]@{
        executable = $taskProbeAction.executable
        arguments = $taskProbeAction.arguments
        workingDirectory = $taskProbeForeignRoot
    }
    $wrongWorkingDirectorySnapshot = [PSCustomObject]@{
        name = $taskProbeSnapshot.name
        xml = $taskProbeSnapshot.xml
        taskPath = $taskProbeSnapshot.taskPath
        principalSid = $taskProbeSnapshot.principalSid
        triggerSids = @($taskProbeSnapshot.triggerSids)
        action = $wrongWorkingDirectoryAction
        wasRunning = $taskProbeSnapshot.wasRunning
    }
    Assert-ThrowsLike `
        -Action {
            [void](Assert-CycTaskSnapshotOwnership `
                -Snapshot $wrongWorkingDirectorySnapshot `
                -InstallRoot $taskProbeRoot `
                -ExpectedSid $taskProbeSid)
        } `
        -Pattern 'working directory' `
        -Message 'task ownership rejects a working directory outside the requested install root'

    # Stub only the Scheduled Task cmdlets for a no-side-effect positive and
    # foreign-task negative lifecycle check.  The foreign task must be left
    # untouched when Unregister or Register is asked to act on its name.
    function New-CycTaskProbeLiveTask {
        param(
            [Parameter(Mandatory = $true)][string]$Sid,
            [Parameter(Mandatory = $true)][string]$Root,
            [string]$Arguments = '--fixture'
        )
        return [PSCustomObject]@{
            TaskPath = '\'
            Principal = [PSCustomObject]@{ UserId = $Sid }
            Triggers = @([PSCustomObject]@{ UserId = $Sid })
            Actions = @([PSCustomObject]@{
                Execute = Join-Path $Root 'cyc-controller.exe'
                Arguments = $Arguments
                WorkingDirectory = $Root
            })
            State = 'Running'
        }
    }
    $script:CycTaskProbeTask = New-CycTaskProbeLiveTask `
        -Sid $taskProbeSid `
        -Root $taskProbeRoot
    $script:CycTaskProbeStopCount = 0
    $script:CycTaskProbeUnregisterCount = 0
    $script:CycTaskProbeRegisterCount = 0
    $script:CycTaskProbeRegisteredAction = $null
    $script:CycTaskProbeRegisteredTrigger = $null
    $script:CycTaskProbeRegisteredPrincipal = $null
    function Get-ScheduledTask {
        param([string]$TaskName, [string]$TaskPath, [string]$ErrorAction)
        return $script:CycTaskProbeTask
    }
    function Export-ScheduledTask {
        param([string]$TaskName, [string]$TaskPath)
        return '<Task />'
    }
    function Stop-ScheduledTask {
        param([string]$TaskName, [string]$TaskPath, [string]$ErrorAction)
        $script:CycTaskProbeStopCount++
    }
    function Unregister-ScheduledTask {
        param([string]$TaskName, [string]$TaskPath, [switch]$Confirm)
        $script:CycTaskProbeUnregisterCount++
    }
    function Register-ScheduledTask {
        param(
            [string]$TaskName,
            [string]$TaskPath,
            $Action,
            $Trigger,
            $Principal,
            $Settings,
            [string]$Description,
            [switch]$Force
        )
        $script:CycTaskProbeRegisterCount++
        $script:CycTaskProbeRegisteredAction = $Action
        $script:CycTaskProbeRegisteredTrigger = $Trigger
        $script:CycTaskProbeRegisteredPrincipal = $Principal
    }
    function New-ScheduledTaskAction {
        param(
            [string]$Execute,
            [string]$Argument,
            [string]$WorkingDirectory
        )
        return [PSCustomObject]@{
            Execute = $Execute
            Arguments = $Argument
            WorkingDirectory = $WorkingDirectory
        }
    }
    function New-ScheduledTaskTrigger {
        param(
            [switch]$AtLogOn,
            [string]$User
        )
        return [PSCustomObject]@{
            UserId = $User
            AtLogOn = [bool]$AtLogOn
        }
    }
    function New-ScheduledTaskPrincipal {
        param(
            [string]$UserId,
            [string]$LogonType,
            [string]$RunLevel
        )
        return [PSCustomObject]@{
            UserId = $UserId
            LogonType = $LogonType
            RunLevel = $RunLevel
        }
    }
    function New-ScheduledTaskSettingsSet {
        param(
            [string]$MultipleInstances,
            [switch]$AllowStartIfOnBatteries,
            [switch]$DontStopIfGoingOnBatteries,
            [switch]$StartWhenAvailable,
            [int]$RestartCount,
            [TimeSpan]$RestartInterval,
            [TimeSpan]$ExecutionTimeLimit
        )
        return [PSCustomObject]@{
            MultipleInstances = $MultipleInstances
            RestartCount = $RestartCount
            RestartInterval = $RestartInterval
            ExecutionTimeLimit = $ExecutionTimeLimit
        }
    }
    try {
        # Positive path: the exact SID/root binding reaches both lifecycle
        # operations.
        Unregister-CycTask `
            -Name $script:ControllerTaskName `
            -ExpectedInstallRoot $taskProbeRoot `
            -ExpectedSid $taskProbeSid
        Assert-True ($script:CycTaskProbeStopCount -eq 1 -and
            $script:CycTaskProbeUnregisterCount -eq 1) 'owned task can be stopped and unregistered after preflight'

        # Foreign principal: no stop/unregister side effect and no forceful
        # replacement attempt.
        $script:CycTaskProbeTask = New-CycTaskProbeLiveTask `
            -Sid $taskProbeForeignSid `
            -Root $taskProbeForeignRoot `
            -Arguments '--foreign'
        $stopBeforeForeign = $script:CycTaskProbeStopCount
        $unregisterBeforeForeign = $script:CycTaskProbeUnregisterCount
        Assert-ThrowsLike `
            -Action {
                Unregister-CycTask `
                    -Name $script:ControllerTaskName `
                    -ExpectedInstallRoot $taskProbeRoot `
                    -ExpectedSid $taskProbeSid
            } `
            -Pattern 'principal SID|ownership validation failed' `
            -Message 'foreign task is rejected before Unregister stop/remove'
        Assert-True ($script:CycTaskProbeStopCount -eq $stopBeforeForeign -and
            $script:CycTaskProbeUnregisterCount -eq $unregisterBeforeForeign) 'foreign task remains untouched by Unregister'
        $registerBeforeForeign = $script:CycTaskProbeRegisterCount
        Assert-ThrowsLike `
            -Action {
                Register-CycTask `
                    -Name $script:ControllerTaskName `
                    -Action $taskProbeAction `
                    -ExpectedInstallRoot $taskProbeRoot `
                    -ExpectedSid $taskProbeSid
            } `
            -Pattern 'principal SID|ownership validation failed' `
            -Message 'foreign task is rejected before forceful Register replacement'
        Assert-True ($script:CycTaskProbeRegisterCount -eq $registerBeforeForeign) 'foreign task is not overwritten by Register'

        # Production path: exercise Register-CycTask with the profile-matrix
        # bridge disabled.  The Scheduled Task cmdlets are stubbed above so
        # this proves the resolver, trigger, and principal receive one
        # canonical SID-bound account without mutating the host scheduler.
        $script:CycTaskProbeTask = New-CycTaskProbeLiveTask `
            -Sid $taskProbeSid `
            -Root $taskProbeRoot
        Register-CycTask `
            -Name $script:ControllerTaskName `
            -Action $taskProbeAction `
            -ExpectedInstallRoot $taskProbeRoot `
            -ExpectedSid $taskProbeSid
        Assert-True ($script:CycTaskProbeRegisterCount -eq ($registerBeforeForeign + 1)) 'production task registration reaches Register-ScheduledTask after SID preflight'
        Assert-True ($null -ne $script:CycTaskProbeRegisteredTrigger -and
            (Test-CycScheduledTaskAccountNameSidBinding `
                -AccountName ([string]$script:CycTaskProbeRegisteredTrigger.UserId) `
                -ExpectedSid $taskProbeSid)) 'production task trigger account round-trips to the initiating SID'
        Assert-True ($null -ne $script:CycTaskProbeRegisteredPrincipal -and
            (Test-CycScheduledTaskAccountNameSidBinding `
                -AccountName ([string]$script:CycTaskProbeRegisteredPrincipal.UserId) `
                -ExpectedSid $taskProbeSid) -and
            [string]$script:CycTaskProbeRegisteredPrincipal.LogonType -ceq 'Interactive') 'production task principal is canonical SID-bound Interactive identity'
    } finally {
        Remove-Item Function:\Get-ScheduledTask -Force -ErrorAction SilentlyContinue
        Remove-Item Function:\Export-ScheduledTask -Force -ErrorAction SilentlyContinue
        Remove-Item Function:\Stop-ScheduledTask -Force -ErrorAction SilentlyContinue
        Remove-Item Function:\Unregister-ScheduledTask -Force -ErrorAction SilentlyContinue
        Remove-Item Function:\Register-ScheduledTask -Force -ErrorAction SilentlyContinue
        Remove-Item Function:\New-ScheduledTaskAction -Force -ErrorAction SilentlyContinue
        Remove-Item Function:\New-ScheduledTaskTrigger -Force -ErrorAction SilentlyContinue
        Remove-Item Function:\New-ScheduledTaskPrincipal -Force -ErrorAction SilentlyContinue
        Remove-Item Function:\New-ScheduledTaskSettingsSet -Force -ErrorAction SilentlyContinue
        Remove-Item Function:\New-CycTaskProbeLiveTask -Force -ErrorAction SilentlyContinue
        Remove-Variable CycTaskProbeTask, CycTaskProbeStopCount, CycTaskProbeUnregisterCount, CycTaskProbeRegisterCount, `
            CycTaskProbeRegisteredAction, CycTaskProbeRegisteredTrigger, CycTaskProbeRegisteredPrincipal `
            -Scope Script -ErrorAction SilentlyContinue
    }
    Assert-True ($source -match 'AreAccessRulesProtected') 'ACL inheritance is verified'
    Assert-True ($source -match "S-1-5-32-544[\s\S]+ReadAndExecute") 'install ACL grants BUILTIN Administrators only the read/execute access needed by over-the-shoulder elevation'
    Assert-True ($source -match 'Set-PrivateDirectoryAcl -Path \$Plan\.installRoot -AllowAdministratorsReadAndExecute[\s\S]+Set-PrivateDirectoryAcl -Path \$Plan\.dataRoot') 'only the install tree, never private data/TLS state, receives the administrator read contract'
    Assert-True ($source -match 'Assert-SafePurgeTarget') 'recursive purge is guarded'
    Assert-True ($source -match 'Stop-CycRuntime') 'owned runtime is stopped before replacement'
    Assert-True ($source -match 'Get-Process -Id \$process\.Id -ErrorAction SilentlyContinue') 'runtime stop tolerates a process exiting between snapshot and stop'
    Assert-True ($source -match 'Restore-FileRollbackSnapshot') 'failed replacement has file rollback'
    Assert-True ($source -match 'Restore-CycTaskSnapshots') 'failed replacement has task rollback'
    $installCoreSource = [regex]::Match($source, 'function Invoke-InstallOrRepairCore[\s\S]+?function Invoke-InstallOrRepair')
    Assert-True ($installCoreSource.Success -and
        $installCoreSource.Value -match '\$rollbackFailures[\s\S]+try \{\s*Stop-CycRuntime' -and
        $installCoreSource.Value -match "rollbackFailures\.Add\('runtime'\)") 'install rollback continues after runtime teardown failure'
    Assert-True ($source -match 'Wait-CycTaskStable') 'Scheduled Tasks require a stable running window'
    Assert-True ($source -match 'LastTaskResult') 'Scheduled Task health checks LastTaskResult'
    Assert-True ($source -match 'Test-CycControllerLoopbackHealth') 'controller readiness uses the direct loopback health probe'
    Assert-True ($source -match 'System\.Net\.Sockets\.TcpClient') 'controller readiness bypasses ambient HTTP proxy configuration'
    Assert-True ($source -match 'Host:\s*127\.0\.0\.1:47831') 'controller readiness sends the port-qualified loopback authority'
    Assert-True ($source -match 'Wait-CycControllerReady \{[\s\S]*?TimeoutSeconds = 60') 'controller readiness allows bounded ARM64 emulation startup time'
    Assert-True ($source -match 'connectWaitHandle\.WaitOne\(5000\)') 'controller readiness allows bounded ARM64 emulation connect time'
    Assert-True ($source -match '\$stream\.ReadTimeout = 5000') 'controller readiness allows bounded ARM64 emulation response time'
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
    Assert-True ($source -match 'function Assert-CycExistingPrivateDirectory') 'lifecycle recovery has a verify-only private-root preflight'
    Assert-True ($source -match 'function Assert-CycPrivateStateTree') 'transaction journals are validated as a complete private state tree'
    Assert-True ($source -match 'Recover-CycAgentsTransactions[\s\S]+Assert-CycPrivateStateTree') 'journal recovery validates private state before enumerating records'
    Assert-True ($source -match 'New-FileRollbackSnapshot[\s\S]+Set-PrivateDirectoryAcl -Path \$transactionRoot') 'new rollback snapshots publish an exact private ACL before recovery can consume them'
    $codexOnlyTransactionRootSource = [regex]::Match($source, 'function New-CycCodexOnlyTransactionRoot[\s\S]+?function Remove-CycCodexOnlyTransactionRoot')
    Assert-True ($codexOnlyTransactionRootSource.Success -and
        $codexOnlyTransactionRootSource.Value -match 'Assert-CycPrivateStateTree -Root \$transactionsRoot' -and
        $codexOnlyTransactionRootSource.Value -match 'Set-PrivateDirectoryAcl -Path \$transactionsRoot' -and
        $codexOnlyTransactionRootSource.Value -match 'Set-PrivateDirectoryAcl -Path \$transactionRoot') 'Codex-only transaction roots verify existing state and publish exact private ACLs for new roots'
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
        -Action Install `
        -CodexResult $fakeIntegrationResult `
        -AgentsResult $agentsInstalled
    $agentsReceipt = Read-InstallManifest -ManifestPath $agentsReceiptPath
    Assert-True ([string]$agentsReceipt.coreCommit.state -ceq 'pending') 'install manifest remains provisional until runtime and AGENTS readiness finish'
    Assert-True (($agentsReceipt.managedWorker.networkPlan | ConvertTo-Json -Depth 6 -Compress) -ceq
        ($plan.managedWorker.networkPlan | ConvertTo-Json -Depth 6 -Compress)) 'install manifest persists the complete immutable network plan without projection drift'
    Assert-True ([string]$agentsReceipt.managedWorker.tlsDirectory -like '*\tls\managed-worker-v2') 'install manifest records the versioned managed-worker identity directory'
    [void](Complete-CycInstallCoreCommit -Plan $plan -Action Install)
    $agentsReceipt = Read-InstallManifest -ManifestPath $agentsReceiptPath
    Assert-True ([string]$agentsReceipt.coreCommit.state -ceq 'committed') 'final install core marker is published explicitly'
    Assert-True ([string]$agentsReceipt.coreCommit.committedAtUtc -match '^\d{4}-\d{2}-\d{2}T') 'final install core marker records a durable commit timestamp'
    $coreCommitFunctionMatch = [regex]::Match(
        $source,
        'function Complete-CycInstallCoreCommit[\s\S]+?(?=function Set-CycObjectPropertyValue)'
    )
    Assert-True $coreCommitFunctionMatch.Success 'core commit function is available for commit-boundary regression checks'
    $coreCommitFunctionSource = [string]$coreCommitFunctionMatch.Value
    $coreCommitWriteIndex = $coreCommitFunctionSource.LastIndexOf('Write-DurableAtomicJson', [StringComparison]::Ordinal)
    Assert-True ($coreCommitWriteIndex -ge 0) 'core commit uses the durable atomic writer as its commit point'
    $coreCommitPostWrite = $coreCommitFunctionSource.Substring($coreCommitWriteIndex)
    Assert-True ($coreCommitPostWrite -notmatch 'Read-InstallManifest') 'core commit performs no fallible manifest reopen after the durable atomic commit point'
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
    Set-PrivateDirectoryAcl -Path $freshCrashData
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
    Set-PrivateDirectoryAcl -Path $upgradeData
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
    Set-PrivateDirectoryAcl -Path $finalizeData
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

    $installAclRoot = Join-Path $testRoot 'install-acl-smoke'
    $installAclController = Join-Path $installAclRoot 'cyc-controller.exe'
    [void](New-Item -ItemType Directory -Path $installAclRoot -Force)
    [System.IO.File]::WriteAllText($installAclController, 'fixture-controller')
    Set-PrivateDirectoryAcl -Path $installAclRoot -AllowAdministratorsReadAndExecute
    foreach ($installAclPath in @($installAclRoot, $installAclController)) {
        Assert-PrivatePathAcl -Path $installAclPath -AllowAdministratorsReadAndExecute
    }
    $controllerAcl = Get-FileSystemAclPortable -Item (Get-Item -LiteralPath $installAclController -Force)
    $administratorsRules = @($controllerAcl.GetAccessRules(
        $true,
        $true,
        [System.Security.Principal.SecurityIdentifier]
    ) | Where-Object { $_.IdentityReference.Value -eq 'S-1-5-32-544' })
    Assert-True ($administratorsRules.Count -eq 1) 'installed controller grants exactly one BUILTIN Administrators ACE for over-the-shoulder firewall verification'
    $expectedAdministratorReadRights = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute -bor
        [System.Security.AccessControl.FileSystemRights]::Synchronize
    Assert-True ($administratorsRules[0].FileSystemRights -eq $expectedAdministratorReadRights) 'over-the-shoulder administrator receives exact ReadAndExecute plus normalized Synchronize rights only'
    Assert-True ((Get-FileHash -LiteralPath $installAclController -Algorithm SHA256).Hash -match '^[0-9A-F]{64}$') 'controller remains hash-readable under the install-root ACL contract'
    $privateAclRejectedInstallAcl = $false
    try { Assert-PrivatePathAcl -Path $installAclController } catch { $privateAclRejectedInstallAcl = $true }
    Assert-True $privateAclRejectedInstallAcl 'data/TLS private ACL verification does not silently accept the install-root Administrators ACE'

    $fakeIdentityCli = Join-Path $testRoot 'fake-identity.ps1'
    @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Remaining)
$ErrorActionPreference = 'Stop'
if ($Remaining.Count -lt 2 -or $Remaining[0] -ne 'identity') { exit 2 }
$hosts = @()
for ($argumentIndex = 0; $argumentIndex -lt $Remaining.Count; $argumentIndex++) {
    if ($Remaining[$argumentIndex] -eq '--host') {
        if ($argumentIndex + 1 -ge $Remaining.Count) { exit 6 }
        $hosts += [string]$Remaining[$argumentIndex + 1]
        $argumentIndex++
    }
}
if ($hosts.Count -lt 1) { exit 7 }
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
        apiVersion = 'cyc.dev/identity/v1'
        certificate = '\\?\' + $certificate
        privateKey = '\\?\' + $key
        sha256Fingerprint = ('a' * 64)
        subjectAltNames = [object[]]$hosts
        notBefore = '2026-01-01T00:00:00Z'
        notAfter = '2036-01-01T00:00:00Z'
        valid = $true
    } | ConvertTo-Json -Compress
    exit 0
}
if ($Remaining[1] -eq 'verify') {
    $certificateIndex = [Array]::IndexOf($Remaining, '--certificate')
    $privateKeyIndex = [Array]::IndexOf($Remaining, '--private-key')
    if ($certificateIndex -lt 0 -or $certificateIndex + 1 -ge $Remaining.Count -or
        $privateKeyIndex -lt 0 -or $privateKeyIndex + 1 -ge $Remaining.Count) { exit 5 }
    [ordered]@{
        apiVersion = 'cyc.dev/identity/v1'
        certificate = '\\?\' + [System.IO.Path]::GetFullPath($Remaining[$certificateIndex + 1])
        privateKey = '\\?\' + [System.IO.Path]::GetFullPath($Remaining[$privateKeyIndex + 1])
        sha256Fingerprint = ('a' * 64)
        subjectAltNames = [object[]]$hosts
        notBefore = '2026-01-01T00:00:00Z'
        notAfter = '2036-01-01T00:00:00Z'
        valid = $true
    } | ConvertTo-Json -Compress
    exit 0
}
exit 4
'@ | Set-Content -LiteralPath $fakeIdentityCli -Encoding UTF8
    $plan.managedWorker.identityCli = $fakeIdentityCli
    $identityFirst = Ensure-CycTlsIdentity -Plan $plan
    Assert-True $identityFirst.created 'fresh install creates one controller TLS identity'
    Assert-True ([string]$identityFirst.fingerprint -ceq ('a' * 64)) 'fresh install accepts the real identity CLI v1 metadata contract'
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

    $legacyIdentityRoot = Join-Path $testRoot 'legacy-identity-migration'
    $legacyTlsRoot = Join-Path $legacyIdentityRoot 'tls'
    $legacyVersionedTls = Join-Path $legacyTlsRoot 'managed-worker-v2'
    [void](New-Item -ItemType Directory -Path $legacyTlsRoot -Force)
    $legacyCertificate = Join-Path $legacyTlsRoot 'controller.crt.pem'
    $legacyPrivateKey = Join-Path $legacyTlsRoot 'controller.key.pem'
    [byte[]]$legacyCertificateBytes = [Text.Encoding]::UTF8.GetBytes('legacy-certificate-preserve-exactly')
    [byte[]]$legacyPrivateKeyBytes = [Text.Encoding]::UTF8.GetBytes('legacy-private-key-preserve-exactly')
    [System.IO.File]::WriteAllBytes($legacyCertificate, $legacyCertificateBytes)
    [System.IO.File]::WriteAllBytes($legacyPrivateKey, $legacyPrivateKeyBytes)
    $legacyMigrationPlan = [PSCustomObject]@{
        dataRoot = $legacyIdentityRoot
        managedWorker = [PSCustomObject]@{
            enabled = $true
            networkPlan = $plan.managedWorker.networkPlan
            identityVersion = 'managed-worker-v2'
            identityHosts = [object[]]@($plan.managedWorker.identityHosts)
            tlsRoot = $legacyTlsRoot
            tlsDirectory = $legacyVersionedTls
            certificatePath = Join-Path $legacyVersionedTls 'controller.crt.pem'
            privateKeyPath = Join-Path $legacyVersionedTls 'controller.key.pem'
            legacyTlsCertificatePath = $legacyCertificate
            legacyTlsPrivateKeyPath = $legacyPrivateKey
            identityCli = $fakeIdentityCli
        }
    }
    $legacyMigrationResult = Ensure-CycTlsIdentity -Plan $legacyMigrationPlan
    Assert-True ($legacyMigrationResult.created -and $legacyMigrationResult.migratedFromLegacy -and
        $legacyMigrationResult.legacyIdentityPreserved) 'legacy prerelease identity migrates into a separate versioned identity directory'
    Assert-BytesEqual $legacyCertificateBytes ([System.IO.File]::ReadAllBytes($legacyCertificate)) 'legacy migration preserves the predecessor certificate byte-for-byte'
    Assert-BytesEqual $legacyPrivateKeyBytes ([System.IO.File]::ReadAllBytes($legacyPrivateKey)) 'legacy migration preserves the predecessor private key byte-for-byte'
    Remove-NewCycTlsIdentity -Plan $legacyMigrationPlan -IdentityResult $legacyMigrationResult
    Assert-True (-not (Test-Path -LiteralPath $legacyVersionedTls)) 'identity rollback removes only the newly created versioned directory'
    Assert-BytesEqual $legacyCertificateBytes ([System.IO.File]::ReadAllBytes($legacyCertificate)) 'identity rollback leaves the legacy certificate intact'
    Assert-BytesEqual $legacyPrivateKeyBytes ([System.IO.File]::ReadAllBytes($legacyPrivateKey)) 'identity rollback leaves the legacy private key intact'

    $partialLegacyRoot = Join-Path $testRoot 'partial-legacy-identity'
    $partialLegacyTlsRoot = Join-Path $partialLegacyRoot 'tls'
    [void](New-Item -ItemType Directory -Path $partialLegacyTlsRoot -Force)
    [System.IO.File]::WriteAllText((Join-Path $partialLegacyTlsRoot 'controller.crt.pem'), 'partial-legacy-certificate')
    $partialLegacyPlan = [PSCustomObject]@{
        dataRoot = $partialLegacyRoot
        managedWorker = [PSCustomObject]@{
            enabled = $true
            networkPlan = $plan.managedWorker.networkPlan
            identityVersion = 'managed-worker-v2'
            identityHosts = [object[]]@($plan.managedWorker.identityHosts)
            tlsRoot = $partialLegacyTlsRoot
            tlsDirectory = Join-Path $partialLegacyTlsRoot 'managed-worker-v2'
            certificatePath = Join-Path $partialLegacyTlsRoot 'managed-worker-v2\controller.crt.pem'
            privateKeyPath = Join-Path $partialLegacyTlsRoot 'managed-worker-v2\controller.key.pem'
            legacyTlsCertificatePath = Join-Path $partialLegacyTlsRoot 'controller.crt.pem'
            legacyTlsPrivateKeyPath = Join-Path $partialLegacyTlsRoot 'controller.key.pem'
            identityCli = $fakeIdentityCli
        }
    }
    Assert-ThrowsLike `
        -Action { [void](Ensure-CycTlsIdentity -Plan $partialLegacyPlan) } `
        -Pattern 'Legacy controller TLS identity is incomplete' `
        -Message 'partial legacy prerelease identities fail closed without creating a replacement'
    Assert-True (-not (Test-Path -LiteralPath $partialLegacyPlan.managedWorker.tlsDirectory)) 'partial legacy rejection performs no versioned identity mutation'

    Assert-ThrowsLike `
        -Action {
            [void](Assert-CycIdentityMetadata `
                -Metadata ([PSCustomObject]@{
                    certificatePath = 'C:\legacy.crt.pem'
                    privateKeyPath = 'C:\legacy.key.pem'
                    sha256Fingerprint = ('b' * 64)
                }) `
                -ExpectedCertificatePath 'C:\legacy.crt.pem' `
                -ExpectedPrivateKeyPath 'C:\legacy.key.pem' `
                -ExpectedHosts @('192.168.50.10') `
                -Operation init)
        } `
        -Pattern 'incomplete metadata' `
        -Message 'bootstrap rejects the obsolete mock-only identity metadata contract'

    $normalizedHostMetadata = [PSCustomObject]@{
        apiVersion = 'cyc.dev/identity/v1'
        certificate = '\\?\' + [System.IO.Path]::GetFullPath($plan.managedWorker.certificatePath)
        privateKey = '\\?\' + [System.IO.Path]::GetFullPath($plan.managedWorker.privateKeyPath)
        sha256Fingerprint = ('c' * 64)
        subjectAltNames = [object[]]@('::1')
        notBefore = '2026-01-01T00:00:00Z'
        notAfter = '2036-01-01T00:00:00Z'
        valid = $true
    }
    Assert-True ((Assert-CycIdentityMetadata `
        -Metadata $normalizedHostMetadata `
        -ExpectedCertificatePath $plan.managedWorker.certificatePath `
        -ExpectedPrivateKeyPath $plan.managedWorker.privateKeyPath `
        -ExpectedHosts @('0:0:0:0:0:0:0:1') `
        -Operation verify) -ceq ('c' * 64)) 'identity SAN comparison accepts equivalent expanded and compressed IPv6 forms'
    $normalizedHostMetadata.subjectAltNames = [object[]]@('example.com')
    Assert-True ((Assert-CycIdentityMetadata `
        -Metadata $normalizedHostMetadata `
        -ExpectedCertificatePath $plan.managedWorker.certificatePath `
        -ExpectedPrivateKeyPath $plan.managedWorker.privateKeyPath `
        -ExpectedHosts @('EXAMPLE.COM.') `
        -Operation verify) -ceq ('c' * 64)) 'identity SAN comparison accepts DNS case and trailing-dot normalization'
    $normalizedHostMetadata.subjectAltNames = [object[]]@('example.com', 'unexpected.example')
    Assert-ThrowsLike `
        -Action {
            [void](Assert-CycIdentityMetadata `
                -Metadata $normalizedHostMetadata `
                -ExpectedCertificatePath $plan.managedWorker.certificatePath `
                -ExpectedPrivateKeyPath $plan.managedWorker.privateKeyPath `
                -ExpectedHosts @('example.com') `
                -Operation verify)
        } `
        -Pattern 'exact immutable SAN set' `
        -Message 'identity verification rejects certificates with an unexpected extra SAN'

    if (-not [string]::IsNullOrWhiteSpace($IdentityCliPath)) {
        $resolvedIdentityCli = [string](Resolve-Path -LiteralPath $IdentityCliPath -ErrorAction Stop).ProviderPath
        Assert-True ([System.IO.Path]::GetFileName($resolvedIdentityCli) -ieq 'cyc.exe') 'production identity contract test uses cyc.exe'
        $realIdentityRoot = Join-Path $testRoot 'real-identity'
        $realIdentityTlsRoot = Join-Path $realIdentityRoot 'tls'
        $realIdentityTls = Join-Path $realIdentityTlsRoot 'managed-worker-v2'
        $realNetworkPlan = New-CycManagedWorkerNetworkPlan `
            -InterfaceIndex 7 `
            -BindHost '192.168.50.10' `
            -PublicHost 'controller.test' `
            -ControllerHostName 'controller-test' `
            -PrivateAddresses @('192.168.50.10', 'fd12:3456:789a::10') `
            -ListenPort 47832
        $realIdentityPlan = [PSCustomObject]@{
            dataRoot = $realIdentityRoot
            managedWorker = [PSCustomObject]@{
                enabled = $true
                networkPlan = $realNetworkPlan
                identityVersion = 'managed-worker-v2'
                identityHosts = [object[]]@($realNetworkPlan.identityHosts)
                tlsRoot = $realIdentityTlsRoot
                tlsDirectory = $realIdentityTls
                certificatePath = Join-Path $realIdentityTls 'controller.crt.pem'
                privateKeyPath = Join-Path $realIdentityTls 'controller.key.pem'
                legacyTlsCertificatePath = Join-Path $realIdentityTlsRoot 'controller.crt.pem'
                legacyTlsPrivateKeyPath = Join-Path $realIdentityTlsRoot 'controller.key.pem'
                identityCli = $resolvedIdentityCli
            }
        }
        $realIdentityFirst = Ensure-CycTlsIdentity -Plan $realIdentityPlan
        Assert-True $realIdentityFirst.created 'production cyc.exe creates a controller TLS identity through bootstrap'
        Assert-True ([string]$realIdentityFirst.fingerprint -cmatch '^[0-9a-f]{64}$') 'production cyc.exe metadata is accepted by bootstrap'
        $realCertificateHash = (Get-FileHash -LiteralPath $realIdentityPlan.managedWorker.certificatePath -Algorithm SHA256).Hash
        $realPrivateKeyHash = (Get-FileHash -LiteralPath $realIdentityPlan.managedWorker.privateKeyPath -Algorithm SHA256).Hash
        $realIdentitySecond = Ensure-CycTlsIdentity -Plan $realIdentityPlan
        Assert-True (-not $realIdentitySecond.created) 'production cyc.exe repair verifies instead of rotating the identity'
        Assert-True ([string]$realIdentitySecond.fingerprint -ceq [string]$realIdentityFirst.fingerprint) 'production identity fingerprint is stable across repair'
        Assert-True ((Get-FileHash -LiteralPath $realIdentityPlan.managedWorker.certificatePath -Algorithm SHA256).Hash -ceq $realCertificateHash) 'production identity certificate is byte-stable across repair'
        Assert-True ((Get-FileHash -LiteralPath $realIdentityPlan.managedWorker.privateKeyPath -Algorithm SHA256).Hash -ceq $realPrivateKeyHash) 'production identity private key is byte-stable across repair'
    }

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
        -CodexHome $codexOnlyHome `
        -DisableManagedWorkerListener
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
        -Action Install `
        -CodexResult $codexOnlyInitialResult `
        -AgentsResult $codexOnlyDisabledAgents
    # The Codex-only entrypoint is a verify-only lifecycle boundary.  Seed the
    # fixture with the same protected roots a real install publishes so the
    # first recovery/preflight check exercises the plugin gate rather than
    # failing on an intentionally weak test directory ACL.
    Set-PrivateDirectoryAcl -Path $codexOnlyInstall -AllowAdministratorsReadAndExecute
    Set-PrivateDirectoryAcl -Path $codexOnlyData

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
    # Uninstall now has the same verify-only private-root preflight as install
    # and IntegrateCodex. Protect this legacy cleanup fixture before invoking
    # the external Codex failure path so the assertion reaches that gate.
    Set-PrivateDirectoryAcl -Path $codexInstall -AllowAdministratorsReadAndExecute
    Set-PrivateDirectoryAcl -Path $codexData
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
    $mcpSdk = Join-Path $mcpDeploy 'node_modules\@modelcontextprotocol\sdk'
    $nodeRuntime = Get-ValidatedNodeExecutable
    $nodeLicense = Join-Path $testRoot 'LICENSE.node'
    $preview = Join-Path $testRoot 'preview'
    $workerKits = Join-Path $testRoot 'worker-kits'
    [void](New-Item -ItemType Directory -Path $rootTarget, $desktopTarget, (Join-Path $mcpDeploy 'dist'), $mcpSdk -Force)
    foreach ($name in @('cyc-controller.exe', 'cyc-worker.exe', 'cyc.exe')) {
        [System.IO.File]::WriteAllText((Join-Path $rootTarget $name), "release-$name")
    }
    [System.IO.File]::WriteAllText((Join-Path $desktopTarget 'ClusterYourCodex.exe'), 'release-gui')
    [System.IO.File]::WriteAllText((Join-Path $mcpDeploy 'dist\server.js'), 'release-mcp')
    [System.IO.File]::WriteAllText((Join-Path $mcpDeploy 'package.json'), '{}')
    [System.IO.File]::WriteAllText((Join-Path $mcpSdk 'package.json'), '{"name":"@modelcontextprotocol/sdk","version":"1.30.0"}')
    [System.IO.File]::WriteAllText($nodeLicense, 'node-license')
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $productVersion = (Get-Content -LiteralPath (Join-Path $repoRoot 'VERSION') -Raw).Trim()
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
    $allWorkerKitTargets = @(
        'windows-x86_64',
        'linux-x86_64',
        'linux-aarch64',
        'macos-x86_64',
        'macos-aarch64'
    )
    foreach ($target in $allWorkerKitTargets) {
        & (Join-Path $repoRoot 'packaging\worker-kits\New-WorkerKit.ps1') `
            -Target $target `
            -WorkerExecutable (Join-Path $rootTarget 'cyc-worker.exe') `
            -OutputDirectory (Join-Path $workerKits "artifact-$target") `
            -SigningKeyPath $fixtureSigningKey `
            -SigningKeyId 'cyc-release-2026-02' `
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
        -SourceTag "v$productVersion" `
        -OutputRoot $preview | Out-Null
    Assert-True (Test-Path -LiteralPath (Join-Path $preview 'bootstrap.ps1') -PathType Leaf) 'preview contains bootstrap'
    Assert-True (Test-Path -LiteralPath (Join-Path $preview 'Install-ClusterYourCodex.cmd') -PathType Leaf) 'preview contains double-click installer'
    Assert-True (Test-Path -LiteralPath (Join-Path $preview 'LICENSE') -PathType Leaf) 'preview contains product license'
    Assert-True (Test-Path -LiteralPath (Join-Path $preview 'payload\ClusterYourCodex.exe') -PathType Leaf) 'preview contains GUI'
    Assert-True (Test-Path -LiteralPath (Join-Path $preview 'payload\cyc-worker.exe') -PathType Leaf) 'preview contains worker'
    Assert-True (Test-Path -LiteralPath (Join-Path $preview 'payload\installer\bootstrap.ps1') -PathType Leaf) 'preview installs its bootstrap for repair/uninstall'
    Assert-True (Test-Path -LiteralPath (Join-Path $preview 'payload\installer\Uninstall-ClusterYourCodex.ps1') -PathType Leaf) 'preview installs the elevated uninstaller launcher'
    Assert-True (Test-Path -LiteralPath (Join-Path $preview 'payload\integrations\codex\cluster-agents-block.md') -PathType Leaf) 'preview contains the public managed AGENTS.md block template'
    foreach ($target in $allWorkerKitTargets) {
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
    Assert-True ([string]$previewManifest.productVersion -ceq $productVersion) 'preview manifest binds root product VERSION'
    Assert-True ([string]$previewManifest.releaseChannel -ceq 'prerelease') 'preview manifest records prerelease channel'
    Assert-True ([string]$previewManifest.sourceTag -ceq "v$productVersion") 'preview manifest binds the exact prerelease source tag'
    Assert-True (@($previewManifest.workerKits).Count -eq $allWorkerKitTargets.Count) 'preview manifest binds all worker kits'
    foreach ($workerKit in @($previewManifest.workerKits)) {
        Assert-True ([string]$workerKit.version -ceq $productVersion) "preview rejects worker-kit product-version drift for $($workerKit.target)"
    }
    $stagedMcpRoot = Join-Path $preview 'payload\integrations\codex-marketplace\plugins\cluster-your-codex\mcp'
    Assert-True (Test-Path -LiteralPath (Join-Path $stagedMcpRoot 'node_modules\@modelcontextprotocol\sdk\package.json') -PathType Leaf) 'preview contains the declared MCP production dependency'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $stagedMcpRoot 'node_modules\.pnpm'))) 'preview never stages pnpm virtual-store metadata'
    Assert-True (-not @(Get-ChildItem -LiteralPath $stagedMcpRoot -Recurse -Force | Where-Object {
        $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint
    }).Count) 'preview MCP deployment contains no reparse points'
    $mcpPackageManifest = Get-Content -LiteralPath (Join-Path $repoRoot 'plugins\cluster-your-codex\mcp\package.json') -Raw | ConvertFrom-Json
    $mcpProductionDependencyNames = @($mcpPackageManifest.dependencies.PSObject.Properties | ForEach-Object { $_.Name })
    $mcpDevelopmentOnlyDependencyNames = @(
        $mcpPackageManifest.devDependencies.PSObject.Properties |
            ForEach-Object { $_.Name } |
            Where-Object { $mcpProductionDependencyNames -notcontains $_ }
    )
    foreach ($developmentDependencyName in $mcpDevelopmentOnlyDependencyNames) {
        Assert-True `
            (-not (Test-Path -LiteralPath (Join-Path (Join-Path $stagedMcpRoot 'node_modules') $developmentDependencyName))) `
            "preview MCP deployment excludes source-declared development dependency '$developmentDependencyName'"
    }
    $longestPreviewPath = @($previewManifest.files | ForEach-Object { ([string]$_.path).Length } | Measure-Object -Maximum).Maximum
    Assert-True ([int]$longestPreviewPath -le 190) 'preview package remains within the Setup package-relative path budget'
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

    $previewManifestBeforeOverlapChecks = (Get-FileHash -LiteralPath (Join-Path $preview 'preview-manifest.json') -Algorithm SHA256).Hash
    foreach ($overlappingOutput in @(
        (Join-Path $preview 'nested-output\ClusterYourCodex-Setup.exe'),
        $testRoot
    )) {
        Assert-ThrowsLike `
            -Action {
                & (Join-Path $PSScriptRoot 'New-SetupExecutable.ps1') `
                    -PackageRoot $preview `
                    -OutputPath $overlappingOutput `
                    -MakeNsisPath $fakeMakeNsis `
                    -Force | Out-Null
            } `
            -Pattern 'must be outside' `
            -Message 'setup builder rejects output/package overlap in either direction before staging or deletion'
    }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $preview 'nested-output'))) 'rejected in-package setup output creates no package entry'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $preview 'preview-manifest.json') -Algorithm SHA256).Hash -ceq $previewManifestBeforeOverlapChecks) 'overlap rejection leaves the package manifest untouched'

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
    $diagnosticRoot = Join-Path $testRoot 'setup-lifecycle-diagnostic'
    [void](New-Item -ItemType Directory -Path $diagnosticRoot -Force)
    $diagnosticPath = Join-Path $diagnosticRoot 'lifecycle.json'
    $oldDiagnosticEnvironment = [string]$env:CYC_SETUP_DIAGNOSTIC_LOG
    try {
        $env:CYC_SETUP_DIAGNOSTIC_LOG = $diagnosticPath
        $diagnosticFailure = try { throw 'cyc-structured-diagnostic-marker-路径' } catch { $_ }
        Write-CycLifecycleDiagnostic -Status failed -Result $null -Failure $diagnosticFailure
        $failedDiagnostic = Read-CycPackagingUtf8Json -Path $diagnosticPath
        Assert-True ([string]$failedDiagnostic.schemaVersion -ceq 'cyc.dev/setup-lifecycle-diagnostic/v1') 'lifecycle writes the versioned structured failure diagnostic'
        Assert-True ([string]$failedDiagnostic.status -ceq 'failed') 'lifecycle failure diagnostic records failed status'
        Assert-True ([string]$failedDiagnostic.lastStage -ceq 'entry') 'lifecycle failure diagnostic retains the last completed coordinator stage'
        Assert-True ([string]$failedDiagnostic.error.message -ceq 'cyc-structured-diagnostic-marker-路径') 'lifecycle failure diagnostic retains the UTF-8 root message independent of the system code page'

        Write-CycLifecycleDiagnostic `
            -Status succeeded `
            -Result ([PSCustomObject]@{ action = 'Install'; status = 'installed'; resumed = $false; firewallVerified = $true; coreSucceeded = $true }) `
            -Failure $null
        $successDiagnostic = Read-CycPackagingUtf8Json -Path $diagnosticPath
        Assert-True ([string]$successDiagnostic.status -ceq 'succeeded') 'lifecycle atomically replaces the diagnostic after success'
        Assert-True ([bool]$successDiagnostic.result.coreSucceeded) 'lifecycle success diagnostic retains core verification'
    } finally {
        if ([string]::IsNullOrEmpty($oldDiagnosticEnvironment)) {
            Remove-Item Env:CYC_SETUP_DIAGNOSTIC_LOG -ErrorAction SilentlyContinue
        } else {
            $env:CYC_SETUP_DIAGNOSTIC_LOG = $oldDiagnosticEnvironment
        }
    }
    $bootstrapFailure = $null
    try {
        [void](Invoke-CycBootstrapProcess -Arguments @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-Command',
            "[Console]::Error.WriteLine('cyc-bootstrap-diagnostic-marker'); exit 37"
        ))
    } catch { $bootstrapFailure = $_ }
    Assert-True ($bootstrapFailure -and $bootstrapFailure.Exception.Message -match 'core lifecycle failed with exit code 37') 'lifecycle reports the native bootstrap exit code'
    Assert-True ($bootstrapFailure.Exception.Message -match 'cyc-bootstrap-diagnostic-marker') 'lifecycle retains bounded bootstrap stderr in the root failure'
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
        -TransactionId ([Guid]::NewGuid().ToString('N')) `
        -ExistingManifest $reusableManifest
    Assert-True ($typedCoordinatorPlan.managedWorker.firewall.lifecycle -eq 'external-elevated-helper') 'coordinator obtains a typed manifest-validated plan before UAC'
    Assert-True (($typedCoordinatorPlan.managedWorker.networkPlan | ConvertTo-Json -Depth 6 -Compress) -ceq
        ($plan.managedWorker.networkPlan | ConvertTo-Json -Depth 6 -Compress)) 'PlanOnly coordinator reuses the installed immutable network plan exactly'
    $typedBootstrapArguments = Get-CycBootstrapArguments `
        -BootstrapPath $bootstrap `
        -Operation Repair `
        -Binding $binding `
        -Roots ([PSCustomObject]@{ installRoot = $install; dataRoot = $data }) `
        -TransactionId ([Guid]::NewGuid().ToString('N')) `
        -RequestSha256 ('d' * 64) `
        -ManagedWorker $typedCoordinatorPlan.managedWorker
    function Get-TypedBootstrapArgumentValue {
        param([Parameter(Mandatory = $true)][string]$Name)
        $positions = @()
        for ($argumentIndex = 0; $argumentIndex -lt $typedBootstrapArguments.Count; $argumentIndex++) {
            if ([string]$typedBootstrapArguments[$argumentIndex] -ceq $Name) { $positions += $argumentIndex }
        }
        Assert-True ($positions.Count -eq 1 -and $positions[0] + 1 -lt $typedBootstrapArguments.Count) "typed core argv contains exactly one $Name value"
        return [string]$typedBootstrapArguments[$positions[0] + 1]
    }
    $propagatedNetworkPlan = New-CycManagedWorkerNetworkPlan `
        -InterfaceIndex ([int](Get-TypedBootstrapArgumentValue '-WorkerInterfaceIndex')) `
        -BindHost (Get-TypedBootstrapArgumentValue '-WorkerBindHost') `
        -PublicHost (Get-TypedBootstrapArgumentValue '-WorkerPublicHost') `
        -ControllerHostName (Get-TypedBootstrapArgumentValue '-WorkerControllerHostName') `
        -PrivateAddresses @((Get-TypedBootstrapArgumentValue '-WorkerPrivateAddress').Split(',')) `
        -ListenPort ([int](Get-TypedBootstrapArgumentValue '-WorkerListenPort'))
    Assert-True (($propagatedNetworkPlan | ConvertTo-Json -Depth 6 -Compress) -ceq
        ($typedCoordinatorPlan.managedWorker.networkPlan | ConvertTo-Json -Depth 6 -Compress)) 'core argv propagates every typed network-plan field without rediscovery'
    Remove-Item Function:\Get-TypedBootstrapArgumentValue -Force
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

    $expiredRequest = Convert-CycPackagingJson ($validRequest | ConvertTo-Json -Depth 6)
    $expiredRequest.createdAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-20).ToString('o')
    $expiredRequest.deadlineUtc = [DateTimeOffset]::UtcNow.AddMinutes(-10).ToString('o')
    $expiredRequest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestPath -Encoding UTF8
    $expiredRequestObject = Convert-CycPackagingJson (Get-Content -LiteralPath $requestPath -Raw)
    $expiredRequestHash = (Get-FileHash -LiteralPath $requestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-ThrowsLike -Pattern 'expired' -Message 'normal elevation rejects an expired firewall request' -Action {
        [void](Assert-CycFirewallRequestBinding `
            -Request $expiredRequestObject `
            -RequestFile $requestPath `
            -ExpectedRequestHash $expiredRequestHash `
            -ObservedHelperHash $helperHash `
            -ExpectedHelperHash $helperHash `
            -ProfileResolver $profileResolver `
            -ExchangeBaseResolver $exchangeResolver)
    }
    [void](Assert-CycFirewallRequestBinding `
        -Request $expiredRequestObject `
        -RequestFile $requestPath `
        -ExpectedRequestHash $expiredRequestHash `
        -ObservedHelperHash $helperHash `
        -ExpectedHelperHash $helperHash `
        -ProfileResolver $profileResolver `
        -ExchangeBaseResolver $exchangeResolver `
        -AllowExpiredRecovery)
    $validRequest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestPath -Encoding UTF8
    $requestObject = Convert-CycPackagingJson (Get-Content -LiteralPath $requestPath -Raw)
    $requestHash = (Get-FileHash -LiteralPath $requestPath -Algorithm SHA256).Hash.ToLowerInvariant()

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
    Assert-True ((Get-CycFirewallBoundRecoveryAction -State $null -Action Rollback -JournalPhase prepared) -eq 'RollbackWithoutState') 'recovery can close a prepared transaction that never created helper state'
    $state | Add-Member -NotePropertyName phase -NotePropertyValue 'prepared'
    Assert-True ((Get-CycFirewallBoundRecoveryAction -State $state -Action Rollback -JournalPhase prepared) -eq 'Rollback') 'recovery can restore a prepared persisted transaction'
    Assert-ThrowsLike -Pattern 'incompatible helper state' -Message 'recovery cannot finalize a transaction that was never applied' -Action {
        [void](Get-CycFirewallBoundRecoveryAction -State $state -Action Finalize -JournalPhase coreApplied)
    }
    $state.phase = 'applied'
    Assert-True ((Get-CycFirewallBoundRecoveryAction -State $state -Action Finalize -JournalPhase coreApplied) -eq 'Finalize') 'recovery can finalize only an applied persisted transaction'
    $state.phase = 'rolledBack'
    Assert-True ((Get-CycFirewallBoundRecoveryAction -State $state -Action Finalize -JournalPhase coreApplied) -eq 'ReapplyThenFinalize') 'core-applied recovery re-establishes an exact request after helper timeout rollback'
    $state.phase = 'applying'
    Assert-True ((Get-CycFirewallBoundRecoveryAction -State $state -Action Finalize -JournalPhase coreApplied) -eq 'ReapplyThenFinalize') 'core-applied recovery can resume after crashing during exact reapply'
    $state.phase = 'rollbackFailed'
    Assert-True ((Get-CycFirewallBoundRecoveryAction -State $state -Action Finalize -JournalPhase coreApplied) -eq 'ReapplyThenFinalize') 'core-applied recovery can converge an exact desired state after rollback failure without a receipt'
    Assert-True ((Get-CycFirewallBoundRecoveryAction -State $state -Action Rollback -JournalPhase prepared) -eq 'Rollback') 'prepared recovery retries an exact snapshot restore after rollback failure'
    Assert-True ((Get-CycFirewallBoundRecoveryAction -State $state -Action Rollback -JournalPhase firewallApplied) -eq 'Rollback') 'firewall-applied recovery retries an exact snapshot restore after rollback failure'
    $state.phase = 'applying'
    Assert-True ((Get-CycFirewallBoundRecoveryAction -State $state -Action Rollback -JournalPhase firewallApplied) -eq 'Rollback') 'firewall-applied recovery resumes an interrupted snapshot restore'
    $state.phase = 'verified'
    Assert-True ((Get-CycFirewallBoundRecoveryAction -State $state -Action Finalize -JournalPhase coreApplied) -eq 'Finalize') 'core-applied recovery only verifies an already committed helper state'
    $state.phase = 'applied'
    Assert-ThrowsLike -Pattern 'requires persisted helper state' -Message 'recovery cannot finalize without persisted helper state' -Action {
        [void](Get-CycFirewallBoundRecoveryAction -State $null -Action Finalize -JournalPhase coreApplied)
    }
    Assert-ThrowsLike -Pattern 'requires persisted helper state' -Message 'firewall-applied rollback fails closed when its original snapshot is missing' -Action {
        [void](Get-CycFirewallBoundRecoveryAction -State $null -Action Rollback -JournalPhase firewallApplied)
    }
    Assert-ThrowsLike -Pattern 'must be supplied together' -Message 'recovery rejects CLI action and phase without exact journal evidence' -Action {
        [void](Assert-CycFirewallRecoveryArguments `
            -Action Rollback `
            -JournalPhase prepared `
            -JournalPath '' `
            -ExpectedJournalSha256 '')
    }
    Assert-ThrowsLike -Pattern 'if and only if' -Message 'recovery finalize is valid exactly for coreApplied' -Action {
        [void](Assert-CycFirewallRecoveryArguments `
            -Action Finalize `
            -JournalPhase prepared `
            -JournalPath 'C:\fixture\firewall-lifecycle.json' `
            -ExpectedJournalSha256 ('a' * 64))
    }
    Assert-True ((Get-CycFirewallHelperRecoveryAction -FinalizeSignal:$false -RollbackSignal:$false -Expired:$true) -eq 'Rollback') 'helper timeout selects rollback after install failure or coordinator crash'
    Assert-True ((Get-CycFirewallHelperRecoveryAction -FinalizeSignal:$true -RollbackSignal:$false -Expired:$false) -eq 'Finalize') 'helper finalizes only on explicit coordinator commit'
    $replacementDigestFixture = ('b' * 64)
    $replacementReceiptFixture = [PSCustomObject]@{ result = 'rollbackFailed' }
    Assert-True ((Get-CycLifecycleResponseReplacementWaitDigest `
                -Receipt $replacementReceiptFixture `
                -Sha256BeforeRead $replacementDigestFixture `
                -Sha256AfterRead $replacementDigestFixture `
                -ExpectedResult verified) -ceq $replacementDigestFixture) 'Finalize waits for replacement of a stable old rollbackFailed response'
    Assert-True ((Get-CycLifecycleResponseReplacementWaitDigest `
                -Receipt $replacementReceiptFixture `
                -Sha256BeforeRead $replacementDigestFixture `
                -Sha256AfterRead $replacementDigestFixture `
                -ExpectedResult rolledBack) -ceq $replacementDigestFixture) 'Rollback waits for replacement of a stable old rollbackFailed response'
    $replacementReceiptFixture.result = 'rolledBack'
    Assert-True ($null -eq (Get-CycLifecycleResponseReplacementWaitDigest `
                -Receipt $replacementReceiptFixture `
                -Sha256BeforeRead $replacementDigestFixture `
                -Sha256AfterRead $replacementDigestFixture `
                -ExpectedResult rolledBack)) 'Rollback immediately consumes an already-matching rolledBack response after private-publication crash'
    Assert-True ((Get-CycLifecycleResponseReplacementWaitDigest `
                -Receipt $replacementReceiptFixture `
                -Sha256BeforeRead $replacementDigestFixture `
                -Sha256AfterRead $replacementDigestFixture `
                -ExpectedResult verified) -ceq $replacementDigestFixture) 'Finalize waits for a stale rolledBack response to become verified'
    Assert-True ($null -eq (Get-CycLifecycleResponseReplacementWaitDigest `
                -Receipt $replacementReceiptFixture `
                -Sha256BeforeRead $replacementDigestFixture `
                -Sha256AfterRead ('c' * 64) `
                -ExpectedResult verified)) 'response sampling race never waits on a digest that was not stable across parsing'
    $waitReplacementFixture = Join-Path $testRoot 'wait-replacement-receipt.json'
    '{"result":"rollbackFailed"}' | Set-Content -LiteralPath $waitReplacementFixture -Encoding UTF8
    $waitReplacementDigest = (Get-FileHash -LiteralPath $waitReplacementFixture -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-True (-not (Wait-CycLifecycleFile `
                -Path $waitReplacementFixture `
                -Deadline ([DateTimeOffset]::UtcNow) `
                -PreviousSha256 $waitReplacementDigest)) 'recovery wait does not accept an already-existing rollbackFailed receipt before replacement'
    Assert-ThrowsLike -Pattern 'digest is invalid' -Message 'replacement wait rejects malformed prior receipt digests' -Action {
        [void](Wait-CycLifecycleFile `
            -Path $waitReplacementFixture `
            -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(1)) `
            -PreviousSha256 'not-a-digest')
    }
    '{"result":"verified"}' | Set-Content -LiteralPath $waitReplacementFixture -Encoding UTF8
    Assert-True (Wait-CycLifecycleFile `
            -Path $waitReplacementFixture `
            -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(1)) `
            -PreviousSha256 $waitReplacementDigest) 'recovery wait observes atomic receipt replacement rather than stale filename existence'

    $recoveryFixtureRoot = Join-Path $testRoot 'recovery-helper-fixture'
    [void](New-Item -ItemType Directory -Path $recoveryFixtureRoot -Force)
    $recoveryFixtureHelper = Join-Path $recoveryFixtureRoot 'Invoke-ClusterYourCodexFirewall.ps1'
    $recoveryFixtureRequest = Join-Path $recoveryFixtureRoot 'request.json'
    $recoveryFixtureJournalPath = Join-Path $recoveryFixtureRoot 'journal.json'
    Copy-Item -LiteralPath $firewallScript -Destination $recoveryFixtureHelper -Force
    $recoveryFixtureTransaction = [Guid]::NewGuid().ToString('N')
    $recoveryFixturePackageHash = ('6' * 64)
    $recoveryFixtureProgramHash = ('7' * 64)
    $recoveryFixtureInstallRoot = Join-Path ([string]$binding.localAppData) 'Programs\ClusterYourCodex'
    $recoveryFixtureDataRoot = Join-Path ([string]$binding.localAppData) 'ClusterYourCodex'
    $recoveryFixtureRequestObject = [PSCustomObject][ordered]@{
        schemaVersion = 'cyc.dev/windows-firewall-request/v1'
        transactionId = $recoveryFixtureTransaction
        requestNonce = ('5' * 64)
        action = 'Apply'
        createdAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-2).ToString('o')
        deadlineUtc = [DateTimeOffset]::UtcNow.AddMinutes(10).ToString('o')
        initiatorSid = [string]$binding.sid
        initiatorProfile = [string]$binding.profile
        initiatorLocalAppData = [string]$binding.localAppData
        installRoot = $recoveryFixtureInstallRoot
        program = Join-Path $recoveryFixtureInstallRoot 'cyc-controller.exe'
        programSha256 = $recoveryFixtureProgramHash
        port = 47832
        ruleName = 'ClusterYourCodex.ManagedWorker.' + ([string]$binding.sid).Replace('-', '_')
        displayName = 'ClusterYourCodex Managed Worker'
        group = 'ClusterYourCodex'
        ruleDescription = 'ClusterYourCodex owned managed-worker TLS listener'
        remoteAddress = 'LocalSubnet'
        exchangeRoot = $recoveryFixtureRoot
        packageManifestSha256 = $recoveryFixturePackageHash
        packageExecutable = $lifecycleScript
        helperAuthenticodeRequired = $false
    }
    Write-CycLifecycleAtomicJson -Path $recoveryFixtureRequest -Value $recoveryFixtureRequestObject
    $recoveryFixtureJournal = [PSCustomObject][ordered]@{
        schemaVersion = 'cyc.dev/windows-external-lifecycle/v1'
        transactionId = $recoveryFixtureTransaction
        action = 'Install'
        phase = 'prepared'
        initiatorSid = [string]$binding.sid
        initiatorProfile = [string]$binding.profile
        initiatorLocalAppData = [string]$binding.localAppData
        installRoot = $recoveryFixtureInstallRoot
        dataRoot = $recoveryFixtureDataRoot
        exchangeRoot = $recoveryFixtureRoot
        requestPath = $recoveryFixtureRequest
        requestSha256 = (Get-FileHash -LiteralPath $recoveryFixtureRequest -Algorithm SHA256).Hash.ToLowerInvariant()
        helperSha256 = (Get-FileHash -LiteralPath $recoveryFixtureHelper -Algorithm SHA256).Hash.ToLowerInvariant()
        privateReceiptPath = Join-Path $recoveryFixtureRoot ($recoveryFixtureTransaction + '.receipt.json')
        packageManifestSha256 = $recoveryFixturePackageHash
        updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    Write-CycLifecycleAtomicJson -Path $recoveryFixtureJournalPath -Value $recoveryFixtureJournal
    $recoveryLaunchMarker = Join-Path $recoveryFixtureRoot 'launch.marker'
    $fakeRecoveryStarter = {
        param(
            $helperPath, $boundRequestPath, $boundRequestHash, $boundHelperHash,
            $boundAuthenticode, $boundRecoveryAction, $boundJournalPhase,
            $boundJournalPath, $boundJournalHash
        )
        [System.IO.File]::WriteAllText(
            $recoveryLaunchMarker,
            ([string]::Join('|', @(
                $helperPath, $boundRequestPath, $boundRequestHash, $boundHelperHash,
                $boundAuthenticode, $boundRecoveryAction, $boundJournalPhase,
                $boundJournalPath, $boundJournalHash
            ))),
            (New-Object System.Text.UTF8Encoding($false))
        )
        return [PSCustomObject]@{ fixture = $true }
    }.GetNewClosure()
    $recoveryLaunch = Start-CycFirewallRecoveryElevationIfNeeded `
        -Journal $recoveryFixtureJournal `
        -JournalPath $recoveryFixtureJournalPath `
        -Request $recoveryFixtureRequestObject `
        -RecoveryAction Rollback `
        -ElevationStarter $fakeRecoveryStarter
    Assert-True ([bool]$recoveryLaunch.started) 'a missing recovery helper lock relaunches the exact bound helper'
    Assert-True ((Get-Content -LiteralPath $recoveryLaunchMarker -Raw) -match '\|False\|Rollback\|prepared\|.+\|[0-9a-f]{64}$') 'recovery relaunch receives the exact journal-bound rollback action and digest'
    Remove-Item -LiteralPath $recoveryLaunchMarker -Force
    $recoveryLockStream = New-Object System.IO.FileStream(
        (Join-Path $recoveryFixtureRoot 'helper.lock'),
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    try {
        $recoveryFixtureJournal.phase = 'coreApplied'
        $recoveryFixtureJournal.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Write-CycLifecycleAtomicJson -Path $recoveryFixtureJournalPath -Value $recoveryFixtureJournal
        $activeRecovery = Start-CycFirewallRecoveryElevationIfNeeded `
            -Journal $recoveryFixtureJournal `
            -JournalPath $recoveryFixtureJournalPath `
            -Request $recoveryFixtureRequestObject `
            -RecoveryAction Finalize `
            -ElevationStarter $fakeRecoveryStarter
        Assert-True (-not [bool]$activeRecovery.started) 'an existing helper lock prevents duplicate recovery elevation'
        Assert-True (-not (Test-Path -LiteralPath $recoveryLaunchMarker)) 'an active helper consumes the recovery signal without launching a duplicate helper'
    } finally {
        $recoveryLockStream.Dispose()
    }
    $recoveryFixtureJournal.phase = 'prepared'
    $recoveryFixtureJournal.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    Write-CycLifecycleAtomicJson -Path $recoveryFixtureJournalPath -Value $recoveryFixtureJournal
    Add-Content -LiteralPath $recoveryFixtureHelper -Value '# tamper'
    Assert-ThrowsLike -Pattern 'helper changed' -Message 'recovery rejects a copied helper whose digest no longer matches the journal' -Action {
        [void](Start-CycFirewallRecoveryElevationIfNeeded `
            -Journal $recoveryFixtureJournal `
            -JournalPath $recoveryFixtureJournalPath `
            -Request $recoveryFixtureRequestObject `
            -RecoveryAction Rollback `
            -ElevationStarter $fakeRecoveryStarter)
    }

    $publicRecoveryTransaction = [Guid]::NewGuid().ToString('N')
    $publicRecoveryLocalAppData = Join-Path $testRoot 'recovery-user-localappdata'
    $publicRecoveryDataRoot = Join-Path $publicRecoveryLocalAppData 'ClusterYourCodex'
    $publicRecoveryInstallerRoot = Join-Path $publicRecoveryDataRoot '.installer'
    $publicRecoveryReceiptRoot = Join-Path $publicRecoveryInstallerRoot 'firewall-receipts'
    [void](New-Item -ItemType Directory -Path $publicRecoveryReceiptRoot -Force)
    $publicRecoveryExchange = Join-Path `
        (Join-Path `
            (Join-Path ([Environment]::GetFolderPath('CommonDocuments')) 'ClusterYourCodex-Firewall') `
            ([string]$binding.sid).Replace('-', '_')) `
        $publicRecoveryTransaction
    $publicRecoveryJournalPath = Join-Path $publicRecoveryExchange 'recovery-journal.json'
    try {
        [void](New-Item -ItemType Directory -Path $publicRecoveryExchange -Force)
        $publicRecoveryHelper = Join-Path $publicRecoveryExchange 'Invoke-ClusterYourCodexFirewall.ps1'
        $publicRecoveryRequestPath = Join-Path $publicRecoveryExchange 'request.json'
        Copy-Item -LiteralPath $firewallScript -Destination $publicRecoveryHelper -Force
        $publicRecoveryRequest = [ordered]@{
            schemaVersion = 'cyc.dev/windows-firewall-request/v1'
            transactionId = $publicRecoveryTransaction
            requestNonce = ('7' * 64)
            action = 'Apply'
            createdAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-20).ToString('o')
            deadlineUtc = [DateTimeOffset]::UtcNow.AddMinutes(-10).ToString('o')
            initiatorSid = [string]$binding.sid
            initiatorProfile = [string]$binding.profile
            initiatorLocalAppData = $publicRecoveryLocalAppData
            installRoot = Join-Path $publicRecoveryLocalAppData 'Programs\ClusterYourCodex'
            program = Join-Path $publicRecoveryLocalAppData 'Programs\ClusterYourCodex\cyc-controller.exe'
            programSha256 = ('8' * 64)
            port = 47832
            ruleName = 'ClusterYourCodex.ManagedWorker.' + ([string]$binding.sid).Replace('-', '_')
            displayName = 'ClusterYourCodex Managed Worker'
            group = 'ClusterYourCodex'
            ruleDescription = 'ClusterYourCodex owned managed-worker TLS listener'
            remoteAddress = 'LocalSubnet'
            exchangeRoot = $publicRecoveryExchange
            packageManifestSha256 = ('9' * 64)
            packageExecutable = $lifecycleScript
            helperAuthenticodeRequired = $false
        }
        $publicRecoveryRequest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $publicRecoveryRequestPath -Encoding UTF8
        $publicRecoveryRequestHash = (Get-FileHash -LiteralPath $publicRecoveryRequestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $publicRecoveryHelperHash = (Get-FileHash -LiteralPath $publicRecoveryHelper -Algorithm SHA256).Hash.ToLowerInvariant()
        $publicRecoveryJournal = [ordered]@{
            schemaVersion = 'cyc.dev/windows-external-lifecycle/v1'
            transactionId = $publicRecoveryTransaction
            action = 'Install'
            phase = 'prepared'
            initiatorSid = [string]$binding.sid
            initiatorProfile = [string]$binding.profile
            initiatorLocalAppData = $publicRecoveryLocalAppData
            installRoot = [string]$publicRecoveryRequest.installRoot
            dataRoot = $publicRecoveryDataRoot
            exchangeRoot = $publicRecoveryExchange
            requestPath = $publicRecoveryRequestPath
            requestSha256 = $publicRecoveryRequestHash
            helperSha256 = $publicRecoveryHelperHash
            privateReceiptPath = Join-Path $publicRecoveryReceiptRoot ($publicRecoveryTransaction + '.json')
            packageManifestSha256 = [string]$publicRecoveryRequest.packageManifestSha256
            updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        # GetNewClosure executes in a dynamic module, so capture the helper
        # implementation explicitly instead of relying on script-scope function
        # lookup from inside that module.
        $firewallAtomicJsonWriter = ${function:Write-CycFirewallAtomicJson}
        $writePublicRecoveryJournal = {
            param([string]$Phase)
            $publicRecoveryJournal.phase = $Phase
            $publicRecoveryJournal.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            & $firewallAtomicJsonWriter -Path $publicRecoveryJournalPath -Value $publicRecoveryJournal
            return (Get-FileHash -LiteralPath $publicRecoveryJournalPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }.GetNewClosure()
        $publicRecoveryJournalHash = & $writePublicRecoveryJournal prepared
        $script:RecoveryRollbackObserved = $false
        $script:RecoveryFinalizeObserved = $false
        $script:RecoveryReapplyActions = @()
        function Test-CycFirewallAdministrator { return $true }
        function Get-CycFirewallOriginalSnapshot { param($Request) return [ordered]@{ existed = $false } }
        function Set-CycExactFirewallDesiredState {
            param($Request)
            $script:RecoveryReapplyActions += [string]$Request.action
        }
        function Restore-CycExactFirewallSnapshot {
            param($Request, $Snapshot)
            $script:RecoveryRollbackObserved = $true
        }
        function Test-CycFirewallDesiredState {
            param($Request, [switch]$Final)
            if ($Final) { $script:RecoveryFinalizeObserved = $true }
            return $true
        }
        $rollbackRecoveryResult = Invoke-CycFirewallElevatedTransaction `
            -BoundRequestPath $publicRecoveryRequestPath `
            -RequestHash $publicRecoveryRequestHash `
            -HelperHash $publicRecoveryHelperHash `
            -RecoveryAction Rollback `
            -RecoveryJournalPhase prepared `
            -RecoveryJournalPath $publicRecoveryJournalPath `
            -ExpectedRecoveryJournalSha256 $publicRecoveryJournalHash `
            -VerifiedHelperPath $publicRecoveryHelper
        Assert-True ([string]$rollbackRecoveryResult.result -ceq 'rolledBack') 'an expired transaction with a dead helper produces a durable rollback receipt'
        Assert-True (-not $script:RecoveryRollbackObserved) 'prepared recovery without helper state is a no-op rollback'
        $rollbackRecoveryState = Read-CycFirewallJson `
            -Path (Join-Path $publicRecoveryExchange 'state.json') `
            -MaximumBytes 65536 `
            -Label 'rollback recovery state fixture'
        Assert-True ([string]$rollbackRecoveryState.phase -ceq 'rolledBack') 'dead-helper rollback persists the terminal state before exit'

        $preCoreFailureReceipt = New-CycFirewallReceipt `
            -Request $publicRecoveryRequest `
            -RequestHash $publicRecoveryRequestHash `
            -Result rollbackFailed `
            -FailureCode 'helper-and-rollback-failure'
        $preCoreResponsePath = Join-Path $publicRecoveryExchange 'response.json'
        foreach ($preCorePhase in @('prepared', 'firewallApplied')) {
            $rollbackRecoveryState.phase = 'rollbackFailed'
            Write-CycFirewallAtomicJson -Path (Join-Path $publicRecoveryExchange 'state.json') -Value $rollbackRecoveryState
            Write-CycFirewallAtomicJson -Path $preCoreResponsePath -Value $preCoreFailureReceipt
            $preCoreFailureResponseHash = (Get-FileHash -LiteralPath $preCoreResponsePath -Algorithm SHA256).Hash.ToLowerInvariant()
            $publicRecoveryJournalHash = & $writePublicRecoveryJournal $preCorePhase
            $script:RecoveryRollbackObserved = $false
            $script:RecoveryFinalizeObserved = $false
            $script:RecoveryReapplyActions = @()
            $preCoreRecoveryResult = Invoke-CycFirewallElevatedTransaction `
                -BoundRequestPath $publicRecoveryRequestPath `
                -RequestHash $publicRecoveryRequestHash `
                -HelperHash $publicRecoveryHelperHash `
                -RecoveryAction Rollback `
                -RecoveryJournalPhase $preCorePhase `
                -RecoveryJournalPath $publicRecoveryJournalPath `
                -ExpectedRecoveryJournalSha256 $publicRecoveryJournalHash `
                -VerifiedHelperPath $publicRecoveryHelper
            Assert-True ([string]$preCoreRecoveryResult.result -ceq 'rolledBack') "$preCorePhase rollbackFailed recovery converges to a durable snapshot rollback"
            Assert-True $script:RecoveryRollbackObserved "$preCorePhase rollbackFailed recovery retries the exact persisted snapshot restore"
            Assert-True ($script:RecoveryReapplyActions.Count -eq 0 -and -not $script:RecoveryFinalizeObserved) "$preCorePhase rollback recovery never applies or finalizes the request"
            Assert-True ((Get-FileHash -LiteralPath $preCoreResponsePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $preCoreFailureResponseHash) "$preCorePhase rollback recovery atomically replaces the old rollbackFailed receipt"
            $preCoreRecoveredState = Read-CycFirewallJson `
                -Path (Join-Path $publicRecoveryExchange 'state.json') `
                -MaximumBytes 65536 `
                -Label "$preCorePhase recovered rollback state fixture"
            Assert-True ([string]$preCoreRecoveredState.phase -ceq 'rolledBack') "$preCorePhase rollback recovery durably commits rolledBack state"
            [void](Assert-CycFirewallReceiptBinding `
                -Receipt $preCoreRecoveryResult `
                -Request $publicRecoveryRequest `
                -RequestHash $publicRecoveryRequestHash)
        }

        $rollbackRecoveryState.phase = 'applied'
        $rollbackRecoveryState.appliedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Write-CycFirewallAtomicJson -Path (Join-Path $publicRecoveryExchange 'state.json') -Value $rollbackRecoveryState
        $publicRecoveryJournalHash = & $writePublicRecoveryJournal coreApplied
        $rolledBackResponsePath = Join-Path $publicRecoveryExchange 'response.json'
        $rolledBackResponseHash = (Get-FileHash -LiteralPath $rolledBackResponsePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:RecoveryFinalizeObserved = $false
        $script:RecoveryRollbackObserved = $false
        $script:RecoveryReapplyActions = @()
        $appliedWithRolledBackResponseResult = Invoke-CycFirewallElevatedTransaction `
            -BoundRequestPath $publicRecoveryRequestPath `
            -RequestHash $publicRecoveryRequestHash `
            -HelperHash $publicRecoveryHelperHash `
            -RecoveryAction Finalize `
            -RecoveryJournalPhase coreApplied `
            -RecoveryJournalPath $publicRecoveryJournalPath `
            -ExpectedRecoveryJournalSha256 $publicRecoveryJournalHash `
            -VerifiedHelperPath $publicRecoveryHelper
        Assert-True ([string]$appliedWithRolledBackResponseResult.result -ceq 'verified') 'core-applied recovery supersedes a stale rolledBack response after desired state was already applied'
        Assert-True ($script:RecoveryReapplyActions.Count -eq 0 -and $script:RecoveryFinalizeObserved -and -not $script:RecoveryRollbackObserved) 'applied state with a stale rolledBack response finalizes without repeating mutation'
        Assert-True ((Get-FileHash -LiteralPath $rolledBackResponsePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $rolledBackResponseHash) 'verified finalization atomically replaces the old rolledBack response'

        Remove-Item -LiteralPath $rolledBackResponsePath -Force
        $rollbackRecoveryState.phase = 'rolledBack'
        $rollbackRecoveryState.appliedAtUtc = $null
        Write-CycFirewallAtomicJson -Path (Join-Path $publicRecoveryExchange 'state.json') -Value $rollbackRecoveryState
        $script:RecoveryFinalizeObserved = $false
        $script:RecoveryRollbackObserved = $false
        $script:RecoveryReapplyActions = @()
        $publicRecoveryJournalHash = & $writePublicRecoveryJournal coreApplied
        $reapplyApplyResult = Invoke-CycFirewallElevatedTransaction `
            -BoundRequestPath $publicRecoveryRequestPath `
            -RequestHash $publicRecoveryRequestHash `
            -HelperHash $publicRecoveryHelperHash `
            -RecoveryAction Finalize `
            -RecoveryJournalPhase coreApplied `
            -RecoveryJournalPath $publicRecoveryJournalPath `
            -ExpectedRecoveryJournalSha256 $publicRecoveryJournalHash `
            -VerifiedHelperPath $publicRecoveryHelper
        Assert-True ([string]$reapplyApplyResult.result -ceq 'verified') 'core-applied recovery re-applies an Apply request after a durable helper rollback without a response'
        Assert-True ($script:RecoveryReapplyActions.Count -eq 1 -and [string]$script:RecoveryReapplyActions[0] -ceq 'Apply') 'core-applied Apply recovery executes the exact bound desired-state mutation once'
        Assert-True $script:RecoveryFinalizeObserved 'core-applied Apply recovery performs final desired-state verification'
        Assert-True (-not $script:RecoveryRollbackObserved) 'successful core-applied Apply recovery does not restore the pre-transaction snapshot'
        $reapplyApplyState = Read-CycFirewallJson `
            -Path (Join-Path $publicRecoveryExchange 'state.json') `
            -MaximumBytes 65536 `
            -Label 're-applied Apply recovery state fixture'
        Assert-True ([string]$reapplyApplyState.phase -ceq 'verified') 'core-applied Apply recovery durably commits verified state'
        [void](Assert-CycFirewallReceiptBinding `
            -Receipt $reapplyApplyResult `
            -Request $publicRecoveryRequest `
            -RequestHash $publicRecoveryRequestHash)
        $verifiedApplyResponsePath = Join-Path $publicRecoveryExchange 'response.json'
        $verifiedApplyResponseHash = (Get-FileHash -LiteralPath $verifiedApplyResponsePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:RecoveryFinalizeObserved = $false
        $script:RecoveryRollbackObserved = $false
        $script:RecoveryReapplyActions = @()
        $replayedApplyResult = Invoke-CycFirewallElevatedTransaction `
            -BoundRequestPath $publicRecoveryRequestPath `
            -RequestHash $publicRecoveryRequestHash `
            -HelperHash $publicRecoveryHelperHash `
            -RecoveryAction Finalize `
            -RecoveryJournalPhase coreApplied `
            -RecoveryJournalPath $publicRecoveryJournalPath `
            -ExpectedRecoveryJournalSha256 $publicRecoveryJournalHash `
            -VerifiedHelperPath $publicRecoveryHelper
        Assert-True ([string]$replayedApplyResult.result -ceq 'verified') 'verified Apply recovery response is replayable'
        Assert-True ($script:RecoveryReapplyActions.Count -eq 0 -and -not $script:RecoveryRollbackObserved -and -not $script:RecoveryFinalizeObserved) 'verified response replay precedes all mutation and verification work'
        Assert-True ((Get-FileHash -LiteralPath $verifiedApplyResponsePath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $verifiedApplyResponseHash) 'verified response replay leaves the durable receipt byte-identical'

        Remove-Item -LiteralPath $verifiedApplyResponsePath -Force
        $script:RecoveryFinalizeObserved = $false
        $script:RecoveryRollbackObserved = $false
        $script:RecoveryReapplyActions = @()
        $verifiedWithoutResponseResult = Invoke-CycFirewallElevatedTransaction `
            -BoundRequestPath $publicRecoveryRequestPath `
            -RequestHash $publicRecoveryRequestHash `
            -HelperHash $publicRecoveryHelperHash `
            -RecoveryAction Finalize `
            -RecoveryJournalPhase coreApplied `
            -RecoveryJournalPath $publicRecoveryJournalPath `
            -ExpectedRecoveryJournalSha256 $publicRecoveryJournalHash `
            -VerifiedHelperPath $publicRecoveryHelper
        Assert-True ([string]$verifiedWithoutResponseResult.result -ceq 'verified') 'verified-state-before-response recovery republishes a bound receipt'
        Assert-True ($script:RecoveryReapplyActions.Count -eq 0 -and -not $script:RecoveryRollbackObserved -and $script:RecoveryFinalizeObserved) 'verified-state-before-response recovery verifies without reapplying or rolling back'

        Remove-Item -LiteralPath $verifiedApplyResponsePath -Force
        $verifiedApplyState = Read-CycFirewallJson `
            -Path (Join-Path $publicRecoveryExchange 'state.json') `
            -MaximumBytes 65536 `
            -Label 'verified Apply recovery state fixture'
        $verifiedApplyState.phase = 'applying'
        $verifiedApplyState.appliedAtUtc = $null
        Write-CycFirewallAtomicJson -Path (Join-Path $publicRecoveryExchange 'state.json') -Value $verifiedApplyState
        $script:RecoveryFinalizeObserved = $false
        $script:RecoveryRollbackObserved = $false
        $script:RecoveryReapplyActions = @()
        $reapplyApplyingApplyResult = Invoke-CycFirewallElevatedTransaction `
            -BoundRequestPath $publicRecoveryRequestPath `
            -RequestHash $publicRecoveryRequestHash `
            -HelperHash $publicRecoveryHelperHash `
            -RecoveryAction Finalize `
            -RecoveryJournalPhase coreApplied `
            -RecoveryJournalPath $publicRecoveryJournalPath `
            -ExpectedRecoveryJournalSha256 $publicRecoveryJournalHash `
            -VerifiedHelperPath $publicRecoveryHelper
        Assert-True ([string]$reapplyApplyingApplyResult.result -ceq 'verified') 'core-applied recovery resumes an Apply request from a durable applying state'
        Assert-True ($script:RecoveryReapplyActions.Count -eq 1 -and [string]$script:RecoveryReapplyActions[0] -ceq 'Apply') 'core-applied applying-state recovery replays the exact Apply mutation once'
        Assert-True ($script:RecoveryFinalizeObserved -and -not $script:RecoveryRollbackObserved) 'successful applying-state Apply recovery verifies without snapshot restoration'

        Remove-Item -LiteralPath $verifiedApplyResponsePath -Force
        $rollbackFailedApplyState = Read-CycFirewallJson `
            -Path (Join-Path $publicRecoveryExchange 'state.json') `
            -MaximumBytes 65536 `
            -Label 'rollbackFailed Apply recovery state fixture'
        $rollbackFailedApplyState.phase = 'rollbackFailed'
        Write-CycFirewallAtomicJson -Path (Join-Path $publicRecoveryExchange 'state.json') -Value $rollbackFailedApplyState
        $rollbackFailedApplyReceipt = New-CycFirewallReceipt `
            -Request $publicRecoveryRequest `
            -RequestHash $publicRecoveryRequestHash `
            -Result rollbackFailed `
            -FailureCode 'helper-and-rollback-failure'
        Write-CycFirewallAtomicJson -Path $verifiedApplyResponsePath -Value $rollbackFailedApplyReceipt
        $rollbackFailedApplyResponseHash = (Get-FileHash -LiteralPath $verifiedApplyResponsePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:RecoveryFinalizeObserved = $false
        $script:RecoveryRollbackObserved = $false
        $script:RecoveryReapplyActions = @()
        $rollbackFailedApplyResult = Invoke-CycFirewallElevatedTransaction `
            -BoundRequestPath $publicRecoveryRequestPath `
            -RequestHash $publicRecoveryRequestHash `
            -HelperHash $publicRecoveryHelperHash `
            -RecoveryAction Finalize `
            -RecoveryJournalPhase coreApplied `
            -RecoveryJournalPath $publicRecoveryJournalPath `
            -ExpectedRecoveryJournalSha256 $publicRecoveryJournalHash `
            -VerifiedHelperPath $publicRecoveryHelper
        Assert-True ([string]$rollbackFailedApplyResult.result -ceq 'verified') 'core-applied Apply recovery supersedes an exact rollbackFailed response after converging desired state'
        Assert-True ($script:RecoveryReapplyActions.Count -eq 1 -and [string]$script:RecoveryReapplyActions[0] -ceq 'Apply') 'rollbackFailed Apply response recovery executes the exact mutation once'
        Assert-True ($script:RecoveryFinalizeObserved -and -not $script:RecoveryRollbackObserved) 'successful rollbackFailed Apply response recovery verifies without snapshot restoration'
        Assert-True ((Get-FileHash -LiteralPath $verifiedApplyResponsePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $rollbackFailedApplyResponseHash) 'verified Apply recovery atomically replaces the old rollbackFailed receipt bytes'
        [void](Assert-CycFirewallReceiptBinding `
            -Receipt $rollbackFailedApplyResult `
            -Request $publicRecoveryRequest `
            -RequestHash $publicRecoveryRequestHash)

        Remove-Item -LiteralPath $verifiedApplyResponsePath -Force
        $appliedWithOldFailureState = Read-CycFirewallJson `
            -Path (Join-Path $publicRecoveryExchange 'state.json') `
            -MaximumBytes 65536 `
            -Label 'applied state with old rollbackFailed response fixture'
        $appliedWithOldFailureState.phase = 'applied'
        Write-CycFirewallAtomicJson -Path (Join-Path $publicRecoveryExchange 'state.json') -Value $appliedWithOldFailureState
        Write-CycFirewallAtomicJson -Path $verifiedApplyResponsePath -Value $rollbackFailedApplyReceipt
        $script:RecoveryFinalizeObserved = $false
        $script:RecoveryRollbackObserved = $false
        $script:RecoveryReapplyActions = @()
        $appliedWithOldFailureResult = Invoke-CycFirewallElevatedTransaction `
            -BoundRequestPath $publicRecoveryRequestPath `
            -RequestHash $publicRecoveryRequestHash `
            -HelperHash $publicRecoveryHelperHash `
            -RecoveryAction Finalize `
            -RecoveryJournalPhase coreApplied `
            -RecoveryJournalPath $publicRecoveryJournalPath `
            -ExpectedRecoveryJournalSha256 $publicRecoveryJournalHash `
            -VerifiedHelperPath $publicRecoveryHelper
        Assert-True ([string]$appliedWithOldFailureResult.result -ceq 'verified') 'recovery replaces an old rollbackFailed response after reapply already persisted applied state'
        Assert-True ($script:RecoveryReapplyActions.Count -eq 0 -and $script:RecoveryFinalizeObserved -and -not $script:RecoveryRollbackObserved) 'applied-state recovery finalizes without repeating the exact mutation'

        Remove-Item -LiteralPath $verifiedApplyResponsePath -Force
        $finalFailureState = Read-CycFirewallJson `
            -Path (Join-Path $publicRecoveryExchange 'state.json') `
            -MaximumBytes 65536 `
            -Label 'final verification failure state fixture'
        $finalFailureState.phase = 'applied'
        Write-CycFirewallAtomicJson -Path (Join-Path $publicRecoveryExchange 'state.json') -Value $finalFailureState
        Write-CycFirewallAtomicJson -Path $verifiedApplyResponsePath -Value $rollbackFailedApplyReceipt
        $visibleFailureReceiptHashBeforeFinalFailure = (Get-FileHash -LiteralPath $verifiedApplyResponsePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:RecoveryFinalizeObserved = $false
        $script:RecoveryRollbackObserved = $false
        $script:RecoveryReapplyActions = @()
        $originalTestFirewallDesiredState = ${function:Test-CycFirewallDesiredState}
        try {
            Set-Item -Path Function:Test-CycFirewallDesiredState -Value {
                param($Request, [switch]$Final)
                if ($Final) {
                    $script:RecoveryFinalizeObserved = $true
                    throw 'injected-final-verification-failure'
                }
                return $true
            }
            Assert-ThrowsLike -Pattern 'injected-final-verification-failure' -Message 'an applied state with an old failure receipt compensates a failed final verification' -Action {
                [void](Invoke-CycFirewallElevatedTransaction `
                    -BoundRequestPath $publicRecoveryRequestPath `
                    -RequestHash $publicRecoveryRequestHash `
                    -HelperHash $publicRecoveryHelperHash `
                    -RecoveryAction Finalize `
                    -RecoveryJournalPhase coreApplied `
                    -RecoveryJournalPath $publicRecoveryJournalPath `
                    -ExpectedRecoveryJournalSha256 $publicRecoveryJournalHash `
                    -VerifiedHelperPath $publicRecoveryHelper)
            }
        } finally {
            Set-Item -Path Function:Test-CycFirewallDesiredState -Value $originalTestFirewallDesiredState
        }
        Assert-True ($script:RecoveryFinalizeObserved -and $script:RecoveryRollbackObserved) 'failed final verification reopens the visible failure receipt and restores the exact snapshot'
        Assert-True ($script:RecoveryReapplyActions.Count -eq 0) 'failed final verification does not repeat an already-applied mutation'
        $finalFailureTerminalState = Read-CycFirewallJson `
            -Path (Join-Path $publicRecoveryExchange 'state.json') `
            -MaximumBytes 65536 `
            -Label 'final verification failure terminal state fixture'
        Assert-True ([string]$finalFailureTerminalState.phase -ceq 'rolledBack') 'failed final verification durably records rolledBack after compensation'
        $finalFailureReceipt = Read-CycFirewallJson `
            -Path $verifiedApplyResponsePath `
            -MaximumBytes 32768 `
            -Label 'final verification failure receipt fixture'
        Assert-True ([string]$finalFailureReceipt.result -ceq 'rolledBack' -and [string]$finalFailureReceipt.failureCode -ceq 'helper-failure') 'failed final verification replaces the old failure response with a compensated rollback receipt'
        Assert-True ((Get-FileHash -LiteralPath $verifiedApplyResponsePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $visibleFailureReceiptHashBeforeFinalFailure) 'failed final verification atomically replaces the still-visible old failure receipt'

        Remove-Item -LiteralPath $verifiedApplyResponsePath -Force
        Remove-Item -LiteralPath (Join-Path $publicRecoveryExchange 'state.json') -Force
        $script:RecoveryRollbackObserved = $false
        $publicRecoveryJournalHash = & $writePublicRecoveryJournal firewallApplied
        Assert-ThrowsLike -Pattern 'requires persisted helper state' -Message 'firewall-applied recovery never snapshots the already-mutated current rule as original' -Action {
            [void](Invoke-CycFirewallElevatedTransaction `
                -BoundRequestPath $publicRecoveryRequestPath `
                -RequestHash $publicRecoveryRequestHash `
                -HelperHash $publicRecoveryHelperHash `
                -RecoveryAction Rollback `
                -RecoveryJournalPhase firewallApplied `
                -RecoveryJournalPath $publicRecoveryJournalPath `
                -ExpectedRecoveryJournalSha256 $publicRecoveryJournalHash `
                -VerifiedHelperPath $publicRecoveryHelper)
        }
        Assert-True (-not $script:RecoveryRollbackObserved) 'missing firewall-applied state fails before any rollback mutation'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $publicRecoveryExchange 'response.json'))) 'missing firewall-applied state cannot mint a terminal receipt'

        $rollbackRecoveryState.phase = 'applied'
        $rollbackRecoveryState.appliedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Write-CycFirewallAtomicJson -Path (Join-Path $publicRecoveryExchange 'state.json') -Value $rollbackRecoveryState
        $publicRecoveryJournalHash = & $writePublicRecoveryJournal coreApplied
        $finalizeRecoveryResult = Invoke-CycFirewallElevatedTransaction `
            -BoundRequestPath $publicRecoveryRequestPath `
            -RequestHash $publicRecoveryRequestHash `
            -HelperHash $publicRecoveryHelperHash `
            -RecoveryAction Finalize `
            -RecoveryJournalPhase coreApplied `
            -RecoveryJournalPath $publicRecoveryJournalPath `
            -ExpectedRecoveryJournalSha256 $publicRecoveryJournalHash `
            -VerifiedHelperPath $publicRecoveryHelper
        Assert-True ([string]$finalizeRecoveryResult.result -ceq 'verified') 'an expired applied transaction with a dead helper produces a durable verified receipt'
        Assert-True $script:RecoveryFinalizeObserved 'dead-helper finalize verifies the final desired firewall state'
        $finalizeRecoveryState = Read-CycFirewallJson `
            -Path (Join-Path $publicRecoveryExchange 'state.json') `
            -MaximumBytes 65536 `
            -Label 'finalize recovery state fixture'
        Assert-True ([string]$finalizeRecoveryState.phase -ceq 'verified') 'dead-helper finalize persists the verified terminal state before exit'
        $finalizeRecoveryState.phase = 'applied'
        Write-CycFirewallAtomicJson -Path (Join-Path $publicRecoveryExchange 'state.json') -Value $finalizeRecoveryState
        $publicRecoveryJournalHash = & $writePublicRecoveryJournal prepared
        Assert-ThrowsLike -Pattern 'does not match the requested recovery action' -Message 'rollback cannot reuse an existing verified response' -Action {
            [void](Invoke-CycFirewallElevatedTransaction `
                -BoundRequestPath $publicRecoveryRequestPath `
                -RequestHash $publicRecoveryRequestHash `
                -HelperHash $publicRecoveryHelperHash `
                -RecoveryAction Rollback `
                -RecoveryJournalPhase prepared `
                -RecoveryJournalPath $publicRecoveryJournalPath `
                -ExpectedRecoveryJournalSha256 $publicRecoveryJournalHash `
                -VerifiedHelperPath $publicRecoveryHelper)
        }

        Remove-Item -LiteralPath (Join-Path $publicRecoveryExchange 'response.json') -Force
        $staleJournalHash = $publicRecoveryJournalHash
        Add-Content -LiteralPath $publicRecoveryJournalPath -Value ' '
        Assert-ThrowsLike -Pattern 'journal changed' -Message 'elevated recovery hashes and parses the exact same coordinator-approved journal bytes' -Action {
            [void](Invoke-CycFirewallElevatedTransaction `
                -BoundRequestPath $publicRecoveryRequestPath `
                -RequestHash $publicRecoveryRequestHash `
                -HelperHash $publicRecoveryHelperHash `
                -RecoveryAction Rollback `
                -RecoveryJournalPhase prepared `
                -RecoveryJournalPath $publicRecoveryJournalPath `
                -ExpectedRecoveryJournalSha256 $staleJournalHash `
                -VerifiedHelperPath $publicRecoveryHelper)
        }

        $publicRecoveryJournalHash = & $writePublicRecoveryJournal coreApplied
        $finalizeRecoveryState.phase = 'applied'
        Write-CycFirewallAtomicJson -Path (Join-Path $publicRecoveryExchange 'state.json') -Value $finalizeRecoveryState
        $script:RecoveryRollbackObserved = $false
        $originalFirewallAtomicWriter = ${function:Write-CycFirewallAtomicJson}
        $script:CycFirewallAtomicWriterFixture = $originalFirewallAtomicWriter
        $script:CycFirewallInjectedResponsePath = Resolve-CycFirewallPath (Join-Path $publicRecoveryExchange 'response.json')
        try {
            Set-Item -Path Function:Write-CycFirewallAtomicJson -Value {
                param(
                    [Parameter(Mandatory = $true)][string]$Path,
                    [Parameter(Mandatory = $true)]$Value,
                    [int]$Depth = 10
                )
                & $script:CycFirewallAtomicWriterFixture -Path $Path -Value $Value -Depth $Depth
                if ([string]::Equals(
                    (Resolve-CycFirewallPath $Path),
                    $script:CycFirewallInjectedResponsePath,
                    [System.StringComparison]::OrdinalIgnoreCase
                )) {
                    throw 'injected-after-response-commit'
                }
            }
            Assert-ThrowsLike -Pattern 'injected-after-response-commit' -Message 'a post-response exception is surfaced without compensating a committed terminal state' -Action {
                [void](Invoke-CycFirewallElevatedTransaction `
                    -BoundRequestPath $publicRecoveryRequestPath `
                    -RequestHash $publicRecoveryRequestHash `
                    -HelperHash $publicRecoveryHelperHash `
                    -RecoveryAction Finalize `
                    -RecoveryJournalPhase coreApplied `
                    -RecoveryJournalPath $publicRecoveryJournalPath `
                    -ExpectedRecoveryJournalSha256 $publicRecoveryJournalHash `
                    -VerifiedHelperPath $publicRecoveryHelper)
            }
        } finally {
            Set-Item -Path Function:Write-CycFirewallAtomicJson -Value $originalFirewallAtomicWriter
            Remove-Variable -Scope Script -Name CycFirewallAtomicWriterFixture -ErrorAction SilentlyContinue
            Remove-Variable -Scope Script -Name CycFirewallInjectedResponsePath -ErrorAction SilentlyContinue
        }
        $postResponseFailureState = Read-CycFirewallJson `
            -Path (Join-Path $publicRecoveryExchange 'state.json') `
            -MaximumBytes 65536 `
            -Label 'post-response recovery state fixture'
        Assert-True ([string]$postResponseFailureState.phase -ceq 'verified') 'terminal verified state is durable before the response is published'
        Assert-True (Test-Path -LiteralPath (Join-Path $publicRecoveryExchange 'response.json') -PathType Leaf) 'response became externally visible before the injected post-commit exception'
        Assert-True (-not $script:RecoveryRollbackObserved) 'catch never rolls back after terminal state and response publication'

        $publicRecoveryResponsePath = Join-Path $publicRecoveryExchange 'response.json'
        Remove-Item -LiteralPath $publicRecoveryResponsePath -Force
        $publicRecoveryRequest.action = 'Remove'
        $publicRecoveryRequest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $publicRecoveryRequestPath -Encoding UTF8
        $publicRecoveryRequestHash = (Get-FileHash -LiteralPath $publicRecoveryRequestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $publicRecoveryJournal.action = 'Uninstall'
        $publicRecoveryJournal.requestSha256 = $publicRecoveryRequestHash
        $removeRecoveryState = $postResponseFailureState
        $removeRecoveryState.requestSha256 = $publicRecoveryRequestHash
        $removeRecoveryState.phase = 'rolledBack'
        $removeRecoveryState.appliedAtUtc = $null
        Write-CycFirewallAtomicJson -Path (Join-Path $publicRecoveryExchange 'state.json') -Value $removeRecoveryState
        $publicRecoveryJournalHash = & $writePublicRecoveryJournal coreApplied
        $script:RecoveryFinalizeObserved = $false
        $script:RecoveryRollbackObserved = $false
        $script:RecoveryReapplyActions = @()
        $reapplyRemoveResult = Invoke-CycFirewallElevatedTransaction `
            -BoundRequestPath $publicRecoveryRequestPath `
            -RequestHash $publicRecoveryRequestHash `
            -HelperHash $publicRecoveryHelperHash `
            -RecoveryAction Finalize `
            -RecoveryJournalPhase coreApplied `
            -RecoveryJournalPath $publicRecoveryJournalPath `
            -ExpectedRecoveryJournalSha256 $publicRecoveryJournalHash `
            -VerifiedHelperPath $publicRecoveryHelper
        Assert-True ([string]$reapplyRemoveResult.result -ceq 'verified') 'core-applied recovery re-applies a Remove request after a durable helper rollback without a response'
        Assert-True ($script:RecoveryReapplyActions.Count -eq 1 -and [string]$script:RecoveryReapplyActions[0] -ceq 'Remove') 'core-applied Remove recovery executes the exact bound desired-state mutation once'
        Assert-True ($script:RecoveryFinalizeObserved -and -not $script:RecoveryRollbackObserved) 'successful core-applied Remove recovery verifies without snapshot restoration'
        $reapplyRemoveState = Read-CycFirewallJson `
            -Path (Join-Path $publicRecoveryExchange 'state.json') `
            -MaximumBytes 65536 `
            -Label 're-applied Remove recovery state fixture'
        Assert-True ([string]$reapplyRemoveState.phase -ceq 'verified') 'core-applied Remove recovery durably commits verified state'
        [void](Assert-CycFirewallReceiptBinding `
            -Receipt $reapplyRemoveResult `
            -Request $publicRecoveryRequest `
            -RequestHash $publicRecoveryRequestHash)

        Remove-Item -LiteralPath $publicRecoveryResponsePath -Force
        $reapplyRemoveState.phase = 'applying'
        $reapplyRemoveState.appliedAtUtc = $null
        Write-CycFirewallAtomicJson -Path (Join-Path $publicRecoveryExchange 'state.json') -Value $reapplyRemoveState
        $script:RecoveryFinalizeObserved = $false
        $script:RecoveryRollbackObserved = $false
        $script:RecoveryReapplyActions = @()
        $reapplyApplyingRemoveResult = Invoke-CycFirewallElevatedTransaction `
            -BoundRequestPath $publicRecoveryRequestPath `
            -RequestHash $publicRecoveryRequestHash `
            -HelperHash $publicRecoveryHelperHash `
            -RecoveryAction Finalize `
            -RecoveryJournalPhase coreApplied `
            -RecoveryJournalPath $publicRecoveryJournalPath `
            -ExpectedRecoveryJournalSha256 $publicRecoveryJournalHash `
            -VerifiedHelperPath $publicRecoveryHelper
        Assert-True ([string]$reapplyApplyingRemoveResult.result -ceq 'verified') 'core-applied recovery resumes a Remove request from a durable applying state'
        Assert-True ($script:RecoveryReapplyActions.Count -eq 1 -and [string]$script:RecoveryReapplyActions[0] -ceq 'Remove') 'core-applied applying-state recovery replays the exact Remove mutation once'
        Assert-True ($script:RecoveryFinalizeObserved -and -not $script:RecoveryRollbackObserved) 'successful applying-state Remove recovery verifies without snapshot restoration'

        Remove-Item -LiteralPath $publicRecoveryResponsePath -Force
        $rollbackFailedRemoveState = Read-CycFirewallJson `
            -Path (Join-Path $publicRecoveryExchange 'state.json') `
            -MaximumBytes 65536 `
            -Label 'rollbackFailed Remove recovery state fixture'
        $rollbackFailedRemoveState.phase = 'rollbackFailed'
        Write-CycFirewallAtomicJson -Path (Join-Path $publicRecoveryExchange 'state.json') -Value $rollbackFailedRemoveState
        $rollbackFailedRemoveReceipt = New-CycFirewallReceipt `
            -Request $publicRecoveryRequest `
            -RequestHash $publicRecoveryRequestHash `
            -Result rollbackFailed `
            -FailureCode 'helper-and-rollback-failure'
        Write-CycFirewallAtomicJson -Path $publicRecoveryResponsePath -Value $rollbackFailedRemoveReceipt
        $rollbackFailedRemoveResponseHash = (Get-FileHash -LiteralPath $publicRecoveryResponsePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:RecoveryFinalizeObserved = $false
        $script:RecoveryRollbackObserved = $false
        $script:RecoveryReapplyActions = @()
        $rollbackFailedRemoveResult = Invoke-CycFirewallElevatedTransaction `
            -BoundRequestPath $publicRecoveryRequestPath `
            -RequestHash $publicRecoveryRequestHash `
            -HelperHash $publicRecoveryHelperHash `
            -RecoveryAction Finalize `
            -RecoveryJournalPhase coreApplied `
            -RecoveryJournalPath $publicRecoveryJournalPath `
            -ExpectedRecoveryJournalSha256 $publicRecoveryJournalHash `
            -VerifiedHelperPath $publicRecoveryHelper
        Assert-True ([string]$rollbackFailedRemoveResult.result -ceq 'verified') 'core-applied Remove recovery supersedes an exact rollbackFailed response after converging desired state'
        Assert-True ($script:RecoveryReapplyActions.Count -eq 1 -and [string]$script:RecoveryReapplyActions[0] -ceq 'Remove') 'rollbackFailed Remove response recovery executes the exact mutation once'
        Assert-True ($script:RecoveryFinalizeObserved -and -not $script:RecoveryRollbackObserved) 'successful rollbackFailed Remove response recovery verifies without snapshot restoration'
        Assert-True ((Get-FileHash -LiteralPath $publicRecoveryResponsePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $rollbackFailedRemoveResponseHash) 'verified Remove recovery atomically replaces the old rollbackFailed receipt bytes'
        [void](Assert-CycFirewallReceiptBinding `
            -Receipt $rollbackFailedRemoveResult `
            -Request $publicRecoveryRequest `
            -RequestHash $publicRecoveryRequestHash)

        Write-CycFirewallAtomicJson -Path $publicRecoveryResponsePath -Value $rollbackFailedRemoveReceipt
        $visibleFailureReceiptHashBeforeInjectedReapply = (Get-FileHash -LiteralPath $publicRecoveryResponsePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $reapplyFailureState = Read-CycFirewallJson `
            -Path (Join-Path $publicRecoveryExchange 'state.json') `
            -MaximumBytes 65536 `
            -Label 'reapply failure recovery state fixture'
        $reapplyFailureState.phase = 'rolledBack'
        $reapplyFailureState.appliedAtUtc = $null
        Write-CycFirewallAtomicJson -Path (Join-Path $publicRecoveryExchange 'state.json') -Value $reapplyFailureState
        $script:RecoveryFinalizeObserved = $false
        $script:RecoveryRollbackObserved = $false
        $script:RecoveryReapplyActions = @()
        $originalSetExactFirewallDesiredState = ${function:Set-CycExactFirewallDesiredState}
        try {
            Set-Item -Path Function:Set-CycExactFirewallDesiredState -Value {
                param($Request)
                $script:RecoveryReapplyActions += [string]$Request.action
                throw 'injected-reapply-failure-after-mutation'
            }
            Assert-ThrowsLike -Pattern 'injected-reapply-failure-after-mutation' -Message 'a failed core-applied reapply surfaces its original failure after compensation' -Action {
                [void](Invoke-CycFirewallElevatedTransaction `
                    -BoundRequestPath $publicRecoveryRequestPath `
                    -RequestHash $publicRecoveryRequestHash `
                    -HelperHash $publicRecoveryHelperHash `
                    -RecoveryAction Finalize `
                    -RecoveryJournalPhase coreApplied `
                    -RecoveryJournalPath $publicRecoveryJournalPath `
                    -ExpectedRecoveryJournalSha256 $publicRecoveryJournalHash `
                    -VerifiedHelperPath $publicRecoveryHelper)
            }
        } finally {
            Set-Item -Path Function:Set-CycExactFirewallDesiredState -Value $originalSetExactFirewallDesiredState
        }
        Assert-True ($script:RecoveryReapplyActions.Count -eq 1 -and [string]$script:RecoveryReapplyActions[0] -ceq 'Remove') 'failed reapply attempted only the exact bound Remove mutation'
        Assert-True $script:RecoveryRollbackObserved 'failed reapply restores the exact pre-transaction firewall snapshot'
        $failedReapplyState = Read-CycFirewallJson `
            -Path (Join-Path $publicRecoveryExchange 'state.json') `
            -MaximumBytes 65536 `
            -Label 'failed reapply terminal state fixture'
        Assert-True ([string]$failedReapplyState.phase -ceq 'rolledBack') 'failed reapply durably records rolledBack state after compensation'
        $failedReapplyReceipt = Read-CycFirewallJson `
            -Path $publicRecoveryResponsePath `
            -MaximumBytes 32768 `
            -Label 'failed reapply receipt fixture'
        Assert-True ([string]$failedReapplyReceipt.result -ceq 'rolledBack' -and [string]$failedReapplyReceipt.failureCode -ceq 'helper-failure') 'failed reapply publishes the exact helper-failure rollback receipt'
        Assert-True ((Get-FileHash -LiteralPath $publicRecoveryResponsePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $visibleFailureReceiptHashBeforeInjectedReapply) 'failed reapply atomically replaces the still-visible old rollbackFailed receipt after compensation'
        [void](Assert-CycFirewallReceiptBinding `
            -Receipt $failedReapplyReceipt `
            -Request $publicRecoveryRequest `
            -RequestHash $publicRecoveryRequestHash)
    } finally {
        if (Test-Path -LiteralPath $publicRecoveryExchange) {
            Remove-Item -LiteralPath $publicRecoveryExchange -Recurse -Force
        }
    }

    $resumeBinding = Get-CycInitiatorBinding
    $resumeRoots = [PSCustomObject]@{
        installRoot = Resolve-CycLifecyclePath $install
        dataRoot = Resolve-CycLifecyclePath $data
    }
    $resumePrivateReceiptRoot = Join-Path $resumeRoots.dataRoot '.installer\firewall-receipts'
    $resumeExchangeRoot = Join-Path `
        (Join-Path `
            (Join-Path ([Environment]::GetFolderPath('CommonDocuments')) 'ClusterYourCodex-Firewall') `
            ([string]$resumeBinding.sid).Replace('-', '_')) `
        $transactionId
    $resumeProgram = Join-Path $resumeRoots.installRoot 'cyc-controller.exe'
    $resumeProgramSha256 = ('b' * 64)
    $resumeReceiptSha256 = ('d' * 64)
    $resumeRuleName = 'ClusterYourCodex.ManagedWorker.' + ([string]$resumeBinding.sid).Replace('-', '_')
    $resumeJournal = [PSCustomObject][ordered]@{
        schemaVersion = 'cyc.dev/windows-external-lifecycle/v1'
        transactionId = $transactionId
        action = 'Install'
        phase = 'coreApplied'
        initiatorSid = [string]$resumeBinding.sid
        initiatorProfile = [string]$resumeBinding.profile
        initiatorLocalAppData = [string]$resumeBinding.localAppData
        installRoot = [string]$resumeRoots.installRoot
        dataRoot = [string]$resumeRoots.dataRoot
        exchangeRoot = $resumeExchangeRoot
        requestPath = Join-Path $resumeExchangeRoot 'request.json'
        requestSha256 = $requestHash
        helperSha256 = ('e' * 64)
        privateReceiptPath = Join-Path $resumePrivateReceiptRoot ($transactionId + '.json')
        packageManifestSha256 = ('c' * 64)
        updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $resumeReceipt = [PSCustomObject][ordered]@{
        schemaVersion = 'cyc.dev/windows-firewall-receipt/v1'
        transactionId = $transactionId
        requestSha256 = $requestHash
        action = 'Apply'
        result = 'verified'
        failureCode = $null
        initiatorSid = [string]$resumeBinding.sid
        initiatorProfile = [string]$resumeBinding.profile
        initiatorLocalAppData = [string]$resumeBinding.localAppData
        ruleName = $resumeRuleName
        program = $resumeProgram
        programSha256 = $resumeProgramSha256
        port = 47832
        verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $pendingManifest = [PSCustomObject][ordered]@{
        schemaVersion = 'cyc.dev/windows-install-manifest/v1'
        installRoot = [string]$resumeRoots.installRoot
        dataRoot = [string]$resumeRoots.dataRoot
        initiator = [PSCustomObject][ordered]@{
            sid = [string]$resumeBinding.sid
            profile = [string]$resumeBinding.profile
            localAppData = [string]$resumeBinding.localAppData
        }
        coreCommit = [PSCustomObject][ordered]@{
            schemaVersion = 'cyc.dev/windows-core-commit/v1'
            action = 'Install'
            state = 'committed'
            transactionId = $transactionId
            requestSha256 = $requestHash
            committedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        files = @([PSCustomObject][ordered]@{
            relativePath = 'cyc-controller.exe'
            sha256 = $resumeProgramSha256
        })
        managedWorker = [PSCustomObject][ordered]@{
            firewall = [PSCustomObject][ordered]@{
                enabled = $true
                lifecycle = 'external-elevated-helper'
                transactionId = $transactionId
                requestSha256 = $requestHash
                receiptSha256 = $null
                state = 'pending'
                name = $resumeRuleName
                program = $resumeProgram
                port = 47832
                appliedAtUtc = $null
            }
        }
    }
    $resumeRequest = [PSCustomObject][ordered]@{
        schemaVersion = 'cyc.dev/windows-firewall-request/v1'
        transactionId = $transactionId
        requestNonce = ('9' * 64)
        action = 'Apply'
        createdAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-2).ToString('o')
        deadlineUtc = [DateTimeOffset]::UtcNow.AddMinutes(10).ToString('o')
        initiatorSid = [string]$resumeBinding.sid
        initiatorProfile = [string]$resumeBinding.profile
        initiatorLocalAppData = [string]$resumeBinding.localAppData
        installRoot = [string]$resumeRoots.installRoot
        program = $resumeProgram
        programSha256 = $resumeProgramSha256
        port = 47832
        ruleName = $resumeRuleName
        displayName = 'ClusterYourCodex Managed Worker'
        group = 'ClusterYourCodex'
        ruleDescription = 'ClusterYourCodex owned managed-worker TLS listener'
        remoteAddress = 'LocalSubnet'
        exchangeRoot = $resumeExchangeRoot
        packageManifestSha256 = [string]$resumeJournal.packageManifestSha256
        packageExecutable = $lifecycleScript
        helperAuthenticodeRequired = $false
    }

    Assert-True ((Get-CycFirewallResumeDecision -Journal $null -Receipt $null -Manifest $null -RequestedAction Install) -eq 'Start') 'an installation without a lifecycle journal starts a new transaction'
    [void](Assert-CycLifecycleJournal `
        -Journal $resumeJournal `
        -Binding $resumeBinding `
        -Roots $resumeRoots `
        -PrivateReceiptRoot $resumePrivateReceiptRoot)
    Assert-True (Test-CycFirewallRequestJournalBinding -Request $resumeRequest -Journal $resumeJournal) 'recovered request binds to the exact lifecycle journal'
    $resumeJournal.phase = 'firewallApplied'
    Assert-True (Test-CycLifecycleCoreCommitAfterImage -Journal $resumeJournal -Manifest $pendingManifest -Request $resumeRequest) 'firewallApplied Install promotes only from the exact committed-core pending-firewall manifest after-image'
    $pendingManifest.coreCommit.state = 'pending'
    $pendingManifest.coreCommit.committedAtUtc = $null
    Assert-True (-not (Test-CycLifecycleCoreCommitAfterImage -Journal $resumeJournal -Manifest $pendingManifest -Request $resumeRequest)) 'a provisional manifest written before runtime readiness cannot prove core commit'
    $pendingManifest.coreCommit.state = 'committed'
    $pendingManifest.coreCommit.committedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    $pendingManifest.coreCommit.requestSha256 = ('2' * 64)
    Assert-True (-not (Test-CycLifecycleCoreCommitAfterImage -Journal $resumeJournal -Manifest $pendingManifest -Request $resumeRequest)) 'core commit marker must bind to the exact immutable request'
    $pendingManifest.coreCommit.requestSha256 = $requestHash
    $pendingManifest.files[0].sha256 = ('1' * 64)
    Assert-True (-not (Test-CycLifecycleCoreCommitAfterImage -Journal $resumeJournal -Manifest $pendingManifest -Request $resumeRequest)) 'pending manifest with a different controller digest cannot prove core commit'
    $pendingManifest.files[0].sha256 = $resumeProgramSha256
    $resumeJournal.action = 'Uninstall'
    $resumeRequest.action = 'Remove'
    Assert-True (Test-CycLifecycleCoreCommitAfterImage -Journal $resumeJournal -Manifest $null -Request $resumeRequest) 'firewallApplied Uninstall promotes when the exact Remove request has an absent manifest after-image'
    Assert-True (-not (Test-CycLifecycleCoreCommitAfterImage -Journal $resumeJournal -Manifest $pendingManifest -Request $resumeRequest)) 'Uninstall with a surviving manifest cannot prove core commit'
    $resumeJournal.action = 'Install'
    $resumeJournal.phase = 'coreApplied'
    $resumeRequest.action = 'Apply'
    $receiptPublishRoot = Join-Path $testRoot 'atomic-firewall-receipt'
    [void](New-Item -ItemType Directory -Path $receiptPublishRoot -Force)
    $receiptPublishSource = Join-Path $receiptPublishRoot 'response.json'
    $receiptPublishDestination = Join-Path $receiptPublishRoot 'durable.json'
    [System.IO.File]::WriteAllText(
        $receiptPublishSource,
        (($resumeReceipt | ConvertTo-Json -Depth 8 -Compress) + "`n"),
        (New-Object System.Text.UTF8Encoding($false))
    )
    [System.IO.File]::WriteAllText($receiptPublishDestination, '{', (New-Object System.Text.UTF8Encoding($false)))
    $publishedFixtureReceipt = Publish-CycLifecycleReceiptAtomic `
        -SourcePath $receiptPublishSource `
        -DestinationPath $receiptPublishDestination `
        -Request $resumeRequest `
        -RequestHash $requestHash
    Assert-True ([string]$publishedFixtureReceipt.receipt.result -ceq 'verified') 'atomic receipt publication replaces a truncated private cache from exact exchange evidence'
    Assert-True ([string]$publishedFixtureReceipt.sha256 -ceq ((Get-FileHash -LiteralPath $receiptPublishDestination -Algorithm SHA256).Hash.ToLowerInvariant())) 'atomic receipt publication reports the digest of the exact committed bytes'
    Assert-True ((Get-CycFirewallResumeDecision -Journal $resumeJournal -Receipt $resumeReceipt -Manifest $pendingManifest -ReceiptSha256 $resumeReceiptSha256 -RequestedAction Install) -eq 'Commit') 'response loss resumes at receipt commit without another firewall mutation'

    $pendingManifest.managedWorker.firewall.state = 'applied'
    $pendingManifest.managedWorker.firewall.receiptSha256 = $resumeReceiptSha256
    $pendingManifest.managedWorker.firewall.appliedAtUtc = [string]$resumeReceipt.verifiedAtUtc
    Assert-True ((Get-CycFirewallResumeDecision -Journal $resumeJournal -Receipt $resumeReceipt -Manifest $pendingManifest -ReceiptSha256 $resumeReceiptSha256 -RequestedAction Install) -eq 'Complete') 'a committed in-progress transaction converges without repeating firewall or core work'
    Assert-True ((Get-CycFirewallResumeDecision -Journal $resumeJournal -Receipt $resumeReceipt -Manifest $pendingManifest -ReceiptSha256 $resumeReceiptSha256 -RequestedAction Repair) -eq 'Reject') 'an in-progress transaction cannot be replaced by a different lifecycle action'
    $pendingManifest.managedWorker.firewall.receiptSha256 = 'not-a-digest'
    Assert-True (-not (Test-CycAppliedFirewallManifestBinding -Manifest $pendingManifest -Journal $resumeJournal -Receipt $resumeReceipt -ReceiptSha256 'not-a-digest')) 'applied manifest binding rejects equal but malformed receipt digests'
    $pendingManifest.managedWorker.firewall.receiptSha256 = $resumeReceiptSha256.ToUpperInvariant()
    Assert-True (-not (Test-CycAppliedFirewallManifestBinding -Manifest $pendingManifest -Journal $resumeJournal -Receipt $resumeReceipt -ReceiptSha256 $resumeReceiptSha256.ToUpperInvariant())) 'applied manifest binding rejects uppercase receipt digests'
    $pendingManifest.managedWorker.firewall.receiptSha256 = $resumeReceiptSha256
    $pendingManifest.managedWorker.firewall.appliedAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(1).ToString('o')
    Assert-True (-not (Test-CycAppliedFirewallManifestBinding -Manifest $pendingManifest -Journal $resumeJournal -Receipt $resumeReceipt -ReceiptSha256 $resumeReceiptSha256)) 'applied manifest binding requires the receipt verification timestamp'
    $pendingManifest.managedWorker.firewall.appliedAtUtc = [string]$resumeReceipt.verifiedAtUtc
    $resumeReceipt.failureCode = 'unexpected-success-failure'
    Assert-True (-not (Test-CycFirewallReceiptJournalBinding -Receipt $resumeReceipt -Journal $resumeJournal)) 'verified receipt binding rejects a non-null failure code'
    $resumeReceipt.failureCode = $null
    $resumeReceipt.verifiedAtUtc = 'not-a-timestamp'
    Assert-True (-not (Test-CycFirewallReceiptJournalBinding -Receipt $resumeReceipt -Journal $resumeJournal)) 'receipt binding rejects a malformed verification timestamp'
    $resumeReceipt.verifiedAtUtc = [string]$pendingManifest.managedWorker.firewall.appliedAtUtc

    $resumeJournal.phase = 'complete'
    Assert-True ((Get-CycFirewallResumeDecision -Journal $resumeJournal -Receipt $resumeReceipt -Manifest $pendingManifest -ReceiptSha256 $resumeReceiptSha256 -RequestedAction Repair) -eq 'RetireThenStart') 'completed Install permits a new Repair transaction'
    Assert-True ((Get-CycFirewallResumeDecision -Journal $resumeJournal -Receipt $resumeReceipt -Manifest $pendingManifest -ReceiptSha256 $resumeReceiptSha256 -RequestedAction Install) -eq 'RetireThenStart') 'completed Install permits a distinct repeated Install transaction'
    $resumeReceipt.requestSha256 = ('f' * 64)
    Assert-True ((Get-CycFirewallResumeDecision -Journal $resumeJournal -Receipt $resumeReceipt -Manifest $pendingManifest -ReceiptSha256 $resumeReceiptSha256 -RequestedAction Repair) -eq 'Reject') 'cross-action restart rejects a receipt not bound to the completed transaction'
    $resumeReceipt.requestSha256 = $requestHash
    $pendingManifest.managedWorker.firewall.receiptSha256 = ('a' * 64)
    Assert-True ((Get-CycFirewallResumeDecision -Journal $resumeJournal -Receipt $resumeReceipt -Manifest $pendingManifest -ReceiptSha256 $resumeReceiptSha256 -RequestedAction Repair) -eq 'Reject') 'completed transaction rejects a manifest bound to a different receipt digest'
    $pendingManifest.managedWorker.firewall.receiptSha256 = $resumeReceiptSha256
    $pendingManifest.managedWorker.firewall.enabled = 'false'
    Assert-True ((Get-CycFirewallResumeDecision -Journal $resumeJournal -Receipt $resumeReceipt -Manifest $pendingManifest -ReceiptSha256 $resumeReceiptSha256 -RequestedAction Repair) -eq 'Reject') 'firewall manifest requires a real true Boolean instead of a truthy string'
    $pendingManifest.managedWorker.firewall.enabled = $true

    $resumeJournal.action = 'Repair'
    $pendingManifest.coreCommit.action = 'Repair'
    Assert-True ((Get-CycFirewallResumeDecision -Journal $resumeJournal -Receipt $resumeReceipt -Manifest $pendingManifest -ReceiptSha256 $resumeReceiptSha256 -RequestedAction Uninstall) -eq 'RetireThenStart') 'completed Repair permits a new Uninstall transaction'
    Assert-True ((Get-CycFirewallResumeDecision -Journal $resumeJournal -Receipt $resumeReceipt -Manifest $pendingManifest -ReceiptSha256 $resumeReceiptSha256 -RequestedAction Repair) -eq 'RetireThenStart') 'completed Repair permits a distinct repeated Repair transaction'

    $resumeJournal.action = 'Uninstall'
    $resumeReceipt.action = 'Remove'
    Assert-True ((Get-CycFirewallResumeDecision -Journal $resumeJournal -Receipt $resumeReceipt -Manifest $null -ReceiptSha256 $resumeReceiptSha256 -RequestedAction Install) -eq 'RetireThenStart') 'completed Uninstall without an installed manifest permits a new Install transaction'
    Assert-True ((Get-CycFirewallResumeDecision -Journal $resumeJournal -Receipt $resumeReceipt -Manifest $null -ReceiptSha256 $resumeReceiptSha256 -RequestedAction Uninstall) -eq 'RetireThenStart') 'completed Uninstall can be retired before an idempotent repeated Uninstall'
    Assert-True ((Get-CycFirewallResumeDecision -Journal $resumeJournal -Receipt $resumeReceipt -Manifest $pendingManifest -ReceiptSha256 $resumeReceiptSha256 -RequestedAction Install) -eq 'Reject') 'completed Uninstall with a surviving installed manifest fails closed'

    $resumeJournal.phase = 'coreApplied'
    Assert-True ((Get-CycFirewallResumeDecision -Journal $resumeJournal -Receipt $resumeReceipt -Manifest $null -ReceiptSha256 $resumeReceiptSha256 -RequestedAction Uninstall) -eq 'Complete') 'in-progress Uninstall with a verified Remove receipt and no manifest converges'
    Assert-True ((Get-CycFirewallResumeDecision -Journal $resumeJournal -Receipt $resumeReceipt -Manifest $pendingManifest -ReceiptSha256 $resumeReceiptSha256 -RequestedAction Uninstall) -eq 'Reject') 'in-progress Uninstall refuses completion while the manifest survives'
    $resumeJournal.action = 'Install'
    $pendingManifest.coreCommit.action = 'Install'
    $resumeReceipt.action = 'Apply'
    $resumeReceipt.result = 'rollbackFailed'
    $resumeReceipt.failureCode = 'helper-and-rollback-failure'
    Assert-True ((Get-CycFirewallResumeDecision -Journal $resumeJournal -Receipt $resumeReceipt -Manifest $null -ReceiptSha256 $resumeReceiptSha256 -RequestedAction Install) -eq 'Resume') 'exact coreApplied rollbackFailed evidence resumes finalization instead of deadlocking'
    Assert-True ((Get-CycFirewallResumeDecision -Journal $resumeJournal -Receipt $resumeReceipt -Manifest $null -ReceiptSha256 $resumeReceiptSha256 -RequestedAction Repair) -eq 'Reject') 'rollbackFailed recovery remains bound to the exact lifecycle action'
    $resumeJournal.phase = 'firewallApplied'
    Assert-True ((Get-CycFirewallResumeDecision -Journal $resumeJournal -Receipt $resumeReceipt -Manifest $null -ReceiptSha256 $resumeReceiptSha256 -RequestedAction Install) -eq 'Resume') 'firewall-applied rollbackFailed evidence resumes exact pre-core snapshot rollback'
    Assert-True ((Get-CycFirewallResumeDecision -Journal $resumeJournal -Receipt $resumeReceipt -Manifest $null -ReceiptSha256 $resumeReceiptSha256 -RequestedAction Repair) -eq 'Reject') 'pre-core rollbackFailed recovery cannot cross lifecycle actions'
    $resumeJournal.phase = 'prepared'
    Assert-True ((Get-CycFirewallResumeDecision -Journal $resumeJournal -Receipt $resumeReceipt -Manifest $null -ReceiptSha256 $resumeReceiptSha256 -RequestedAction Install) -eq 'Resume') 'prepared rollbackFailed evidence resumes exact snapshot rollback'
    foreach ($preCoreRequestedAction in @('Install', 'Repair')) {
        $preCoreRollbackRouting = Get-CycLifecycleRecoveryRouting `
            -Journal $resumeJournal `
            -Receipt $resumeReceipt `
            -Manifest $null `
            -Request $resumeRequest `
            -RequestedAction $preCoreRequestedAction
        Assert-True ([bool]$preCoreRollbackRouting.cleanupPending) "prepared rollbackFailed Apply is cleanup-owned before requested $preCoreRequestedAction"
        Assert-True ([string]$preCoreRollbackRouting.resumeAction -ceq 'Install') "requested $preCoreRequestedAction first resumes the exact predecessor Install rollback"
        Assert-True ([string]$preCoreRollbackRouting.deferredAction -ceq $preCoreRequestedAction) "requested $preCoreRequestedAction cannot false-succeed as removed after pre-core rollback"
        $preCoreNoReceiptRouting = Get-CycLifecycleRecoveryRouting `
            -Journal $resumeJournal `
            -Receipt $null `
            -Manifest $null `
            -Request $resumeRequest `
            -RequestedAction $preCoreRequestedAction
        Assert-True ([string]$preCoreNoReceiptRouting.resumeAction -ceq 'Install') "prepared Apply without a receipt resumes its exact Install action before $preCoreRequestedAction"
        Assert-True ([string]$preCoreNoReceiptRouting.deferredAction -ceq $preCoreRequestedAction) "prepared Apply without a receipt preserves requested $preCoreRequestedAction through rollback and cleanup"

        $simulatedRecoveredApplyReceipt = New-CycFirewallReceipt `
            -Request $resumeRequest `
            -RequestHash $requestHash `
            -Result rolledBack `
            -FailureCode 'coordinator-cancelled-or-timed-out'
        $simulatedCleanupEvidence = Get-CycRolledBackNoManifestCleanupEvidence `
            -Journal $resumeJournal `
            -Receipt $simulatedRecoveredApplyReceipt `
            -Manifest $null `
            -Request $resumeRequest `
            -RequestedAction $preCoreRequestedAction
        $simulatedDeferredAction = Get-CycLifecycleDeferredAction `
            -RequestedAction $preCoreRequestedAction `
            -CurrentDeferredAction ([string]$preCoreNoReceiptRouting.deferredAction) `
            -CleanupEvidence $simulatedCleanupEvidence
        $simulatedCleanupTransactionAction = Get-CycLifecycleTransactionAction `
            -RequestedAction $preCoreRequestedAction `
            -CleanupEvidence $simulatedCleanupEvidence
        $simulatedPostCleanup = Get-CycLifecyclePostTransactionDecision `
            -RequestedAction $preCoreRequestedAction `
            -TransactionAction $simulatedCleanupTransactionAction `
            -DeferredAction $simulatedDeferredAction `
            -FirewallVerified $true
        Assert-True ([bool]$simulatedPostCleanup.continueRequestedAction) "verified Remove continues into requested $preCoreRequestedAction instead of returning removed"
        Assert-True ($null -eq $simulatedPostCleanup.terminalAction) "cleanup cannot be reported as terminal success for requested $preCoreRequestedAction"
        Assert-True ([string]$simulatedPostCleanup.nextAction -ceq $preCoreRequestedAction) "post-cleanup control flow re-enters requested $preCoreRequestedAction"
        $simulatedFinalAction = Get-CycLifecycleTransactionAction `
            -RequestedAction ([string]$simulatedPostCleanup.nextAction) `
            -CleanupEvidence $null
        $simulatedFinalManifest = Convert-CycPackagingJson ($pendingManifest | ConvertTo-Json -Depth 12)
        $simulatedFinalManifest.coreCommit.action = $simulatedFinalAction
        Assert-True ([string]$simulatedFinalAction -ceq $preCoreRequestedAction) "final transaction remains requested $preCoreRequestedAction after cleanup"
        Assert-True ([string]$simulatedFinalManifest.coreCommit.action -ceq $preCoreRequestedAction) "final manifest records requested $preCoreRequestedAction rather than Uninstall"
    }
    $resumeJournal.phase = 'firewallApplied'
    foreach ($preCoreRequestedAction in @('Install', 'Repair')) {
        foreach ($preCoreReceipt in @($null, $resumeReceipt)) {
            $firewallAppliedRouting = Get-CycLifecycleRecoveryRouting `
                -Journal $resumeJournal `
                -Receipt $preCoreReceipt `
                -Manifest $null `
                -Request $resumeRequest `
                -RequestedAction $preCoreRequestedAction
            Assert-True ([string]$firewallAppliedRouting.resumeAction -ceq 'Install') "firewallApplied pre-core Apply resumes exact Install before $preCoreRequestedAction"
            Assert-True ([string]$firewallAppliedRouting.deferredAction -ceq $preCoreRequestedAction) "firewallApplied pre-core Apply preserves $preCoreRequestedAction through rollback and verified Remove"
        }
    }
    $resumeJournal.phase = 'prepared'
    $preCoreUninstallRouting = Get-CycLifecycleRecoveryRouting `
        -Journal $resumeJournal `
        -Receipt $resumeReceipt `
        -Manifest $null `
        -Request $resumeRequest `
        -RequestedAction Uninstall
    Assert-True ([string]$preCoreUninstallRouting.resumeAction -ceq 'Install') 'requested Uninstall first finishes the exact predecessor Apply rollback'
    Assert-True ([string]::IsNullOrWhiteSpace([string]$preCoreUninstallRouting.deferredAction)) 'the verified Remove cleanup itself satisfies a requested Uninstall'
    $preCoreVerifiedReceipt = New-CycFirewallReceipt `
        -Request $resumeRequest `
        -RequestHash $requestHash `
        -Result verified
    $preCoreVerifiedRouting = Get-CycLifecycleRecoveryRouting `
        -Journal $resumeJournal `
        -Receipt $preCoreVerifiedReceipt `
        -Manifest $null `
        -Request $resumeRequest `
        -RequestedAction Install
    Assert-True (-not [bool]$preCoreVerifiedRouting.cleanupPending) 'verified pre-core Apply without a manifest is not reinterpreted as rolled-back cleanup'
    Assert-True ((Get-CycFirewallResumeDecision `
                -Journal $resumeJournal `
                -Receipt $preCoreVerifiedReceipt `
                -Manifest $null `
                -ReceiptSha256 ('2' * 64) `
                -RequestedAction Install) -eq 'Reject') 'verified Apply without its manifest after-image fails closed'
    $resumeJournal.phase = 'coreApplied'
    Assert-ThrowsLike `
        -Action {
            [void](Get-CycLifecycleRecoveryRouting `
                -Journal $resumeJournal `
                -Receipt $resumeReceipt `
                -Manifest $null `
                -Request $resumeRequest `
                -RequestedAction Install)
        } `
        -Pattern 'coreApplied Apply transaction cannot be recovered safely' `
        -Message 'coreApplied Apply without its exact manifest after-image fails closed'
    $resumeJournal.phase = 'coreApplied'
    $resumeReceipt.result = 'rolledBack'
    $resumeReceipt.failureCode = 'coordinator-cancelled-or-timed-out'
    Assert-True ((Get-CycFirewallResumeDecision -Journal $resumeJournal -Receipt $resumeReceipt -Manifest $null -ReceiptSha256 $resumeReceiptSha256 -RequestedAction Install) -eq 'RetireAbortedThenStart') 'an exactly bound rolledBack transaction can be retired before retry'
    Assert-True ((Get-CycFirewallResumeDecision -Journal $resumeJournal -Receipt $resumeReceipt -Manifest $null -ReceiptSha256 $resumeReceiptSha256 -RequestedAction Uninstall) -eq 'RetireAbortedThenStart') 'an aborted Install transaction can retire before cleanup Uninstall'
    $resumeJournal.action = 'Repair'
    Assert-True ((Get-CycFirewallResumeDecision -Journal $resumeJournal -Receipt $resumeReceipt -Manifest $null -ReceiptSha256 $resumeReceiptSha256 -RequestedAction Uninstall) -eq 'RetireAbortedThenStart') 'an aborted Repair transaction can retire before cleanup Uninstall'
    $resumeJournal.action = 'Uninstall'
    $resumeRequest.action = 'Remove'
    $resumeReceipt.action = 'Remove'
    $rolledBackUninstallRetry = Get-CycRolledBackUninstallRetryEvidence `
        -Journal $resumeJournal `
        -Receipt $resumeReceipt `
        -Manifest $null `
        -Request $resumeRequest `
        -RequestedAction Uninstall
    Assert-True ($null -ne $rolledBackUninstallRetry) 'rolled-back Uninstall with an absent manifest retains exact evidence for a second Remove transaction'
    Assert-True ([string]$rolledBackUninstallRetry.programSha256 -ceq $resumeProgramSha256) 'rolled-back Uninstall retry preserves the request-bound controller digest'
    Assert-True ([string]$rolledBackUninstallRetry.predecessorTransactionId -ceq [string]$resumeJournal.transactionId) 'rolled-back Uninstall retry preserves the exact predecessor transaction identity'
    Assert-True ([string]$rolledBackUninstallRetry.predecessorRequestSha256 -ceq [string]$resumeJournal.requestSha256) 'rolled-back Uninstall retry preserves the exact predecessor request digest'
    Assert-True ($null -eq (Get-CycRolledBackUninstallRetryEvidence -Journal $resumeJournal -Receipt $resumeReceipt -Manifest $pendingManifest -Request $resumeRequest -RequestedAction Uninstall)) 'a surviving manifest does not use the absent-manifest firewall retry path'
    foreach ($crossAction in @('Install', 'Repair')) {
        $crossActionRetry = Get-CycRolledBackUninstallRetryEvidence `
            -Journal $resumeJournal `
            -Receipt $resumeReceipt `
            -Manifest $null `
            -Request $resumeRequest `
            -RequestedAction $crossAction
        Assert-True ($null -ne $crossActionRetry) "rolled-back Uninstall cleanup survives a later $crossAction request"
        Assert-True ([string]$crossActionRetry.cleanupLifecycleAction -ceq 'Uninstall') "$crossAction is ordered behind an Uninstall cleanup transaction"
        Assert-True ([string]$crossActionRetry.cleanupFirewallAction -ceq 'Remove') "$crossAction is ordered behind an exact Remove mutation"
        Assert-True ((Get-CycLifecycleTransactionAction -RequestedAction $crossAction -CleanupEvidence $crossActionRetry) -ceq 'Uninstall') "$crossAction cannot replace a pending cleanup tombstone with Apply"
        Assert-True ((Get-CycLifecycleDeferredAction -RequestedAction $crossAction -CurrentDeferredAction $null -CleanupEvidence $crossActionRetry) -ceq $crossAction) "$crossAction remains scheduled after cleanup evidence switches the effective transaction to Uninstall"
        $crossActionRouting = Get-CycLifecycleRecoveryRouting `
            -Journal $resumeJournal `
            -Receipt $resumeReceipt `
            -Manifest $null `
            -Request $resumeRequest `
            -RequestedAction $crossAction
        Assert-True ([bool]$crossActionRouting.cleanupPending) "$crossAction recognizes the outstanding exact Uninstall cleanup obligation"
        Assert-True ([string]$crossActionRouting.resumeAction -ceq 'Uninstall') "$crossAction resumes the old Uninstall state machine before its own action"
        Assert-True ([string]$crossActionRouting.deferredAction -ceq $crossAction) "$crossAction remains deferred until verified Remove completion"
    }
    Assert-ThrowsLike `
        -Action {
            [void](Get-CycLifecycleRecoveryRouting `
                -Journal $resumeJournal `
                -Receipt $resumeReceipt `
                -Manifest $null `
                -Request $null `
                -RequestedAction Install)
        } `
        -Pattern 'exact immutable request evidence' `
        -Message 'a rolled-back no-manifest Uninstall with missing request evidence fails closed without retiring its tombstone'

    # Integration regression for the second orphan Remove: a prepared
    # Uninstall with no manifest and an exact rollbackFailed receipt first
    # resumes snapshot rollback.  Once recovery atomically publishes
    # rolledBack, completion must retain a durable predecessor tombstone until
    # a successor Remove journal replaces it by compare-and-swap.
    $orphanRetryRoot = Join-Path $testRoot 'prepared-rollbackfailed-orphan-remove'
    [void](New-Item -ItemType Directory -Path $orphanRetryRoot -Force)
    $orphanRetryJournalPath = Join-Path $orphanRetryRoot 'firewall-lifecycle.json'
    $orphanRetryRequestPath = Join-Path $orphanRetryRoot 'request.json'
    $orphanRetryReceiptPath = Join-Path $orphanRetryRoot 'receipt.json'
    $orphanRetryRequest = Convert-CycPackagingJson ($resumeRequest | ConvertTo-Json -Depth 12)
    $orphanRetryRequest.action = 'Remove'
    $orphanRetryRequest.exchangeRoot = $orphanRetryRoot
    Write-CycLifecycleAtomicJson -Path $orphanRetryRequestPath -Value $orphanRetryRequest
    $orphanRetryRequestSha256 = Get-CycLifecycleSha256 -Path $orphanRetryRequestPath
    $orphanRetryJournal = Convert-CycPackagingJson ($resumeJournal | ConvertTo-Json -Depth 12)
    $orphanRetryJournal.action = 'Uninstall'
    $orphanRetryJournal.phase = 'prepared'
    $orphanRetryJournal.exchangeRoot = $orphanRetryRoot
    $orphanRetryJournal.requestPath = $orphanRetryRequestPath
    $orphanRetryJournal.requestSha256 = $orphanRetryRequestSha256
    $orphanRetryJournal.privateReceiptPath = $orphanRetryReceiptPath
    $orphanRetryJournal.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    Write-CycLifecycleAtomicJson -Path $orphanRetryJournalPath -Value $orphanRetryJournal
    $orphanRollbackFailedReceipt = New-CycFirewallReceipt `
        -Request $orphanRetryRequest `
        -RequestHash $orphanRetryRequestSha256 `
        -Result rollbackFailed `
        -FailureCode 'helper-and-rollback-failure'
    Write-CycLifecycleAtomicJson -Path $orphanRetryReceiptPath -Value $orphanRollbackFailedReceipt
    $orphanRollbackFailedReceiptSha256 = Get-CycLifecycleSha256 -Path $orphanRetryReceiptPath
    Assert-True ((Get-CycFirewallResumeDecision `
                -Journal $orphanRetryJournal `
                -Receipt $orphanRollbackFailedReceipt `
                -Manifest $null `
                -ReceiptSha256 $orphanRollbackFailedReceiptSha256 `
                -RequestedAction Uninstall) -eq 'Resume') 'prepared absent-manifest Remove with rollbackFailed evidence resumes exact pre-core rollback'

    $orphanRecoveredReceipt = New-CycFirewallReceipt `
        -Request $orphanRetryRequest `
        -RequestHash $orphanRetryRequestSha256 `
        -Result rolledBack `
        -FailureCode 'coordinator-cancelled-or-timed-out'
    Write-CycLifecycleAtomicJson -Path $orphanRetryReceiptPath -Value $orphanRecoveredReceipt
    Assert-True (Test-CycFirewallRequestJournalBinding -Request $orphanRetryRequest -Journal $orphanRetryJournal) 'prepared orphan retry request remains exactly bound to its Uninstall journal'
    Assert-True (Test-CycFirewallReceiptJournalBinding -Receipt $orphanRecoveredReceipt -Journal $orphanRetryJournal) 'published rolledBack recovery receipt remains exactly bound to its Uninstall journal'
    $orphanRetryCompletion = Complete-CycPreCoreFirewallRecovery `
        -Journal $orphanRetryJournal `
        -Receipt $orphanRecoveredReceipt `
        -Manifest $null `
        -Request $orphanRetryRequest `
        -RequestedAction Uninstall `
        -JournalPath $orphanRetryJournalPath
    Assert-True ($null -ne $orphanRetryCompletion.retryEvidence) 'pre-core rolledBack recovery retains immutable orphan Remove retry evidence'
    Assert-True ([string]$orphanRetryCompletion.replaceCompletedTransactionId -ceq [string]$orphanRetryJournal.transactionId) 'pre-core recovery binds successor CAS to the exact predecessor transaction'
    Assert-True ([string]$orphanRetryCompletion.replaceCompletedRequestSha256 -ceq $orphanRetryRequestSha256) 'pre-core recovery binds successor CAS to the exact predecessor request bytes'
    $orphanRetryTombstone = Read-CycLifecycleJson -Path $orphanRetryJournalPath -MaximumBytes 65536 -Label 'rolled-back Uninstall retry tombstone'
    Assert-True ([string]$orphanRetryTombstone.phase -ceq 'complete') 'pre-core rolledBack recovery durably commits a completed predecessor tombstone'
    $orphanRetryAfterCrashReceipt = Read-CycLifecycleJson -Path $orphanRetryReceiptPath -MaximumBytes 32768 -Label 'rolled-back Uninstall retry receipt'
    $orphanRetryAfterCrashRequest = Read-CycLifecycleJson -Path $orphanRetryRequestPath -MaximumBytes 32768 -Label 'rolled-back Uninstall retry request'
    Assert-True ($null -ne (Get-CycRolledBackUninstallRetryEvidence -Journal $orphanRetryTombstone -Receipt $orphanRetryAfterCrashReceipt -Manifest $null -Request $orphanRetryAfterCrashRequest -RequestedAction Uninstall)) 'a crash before successor publication reconstructs retry evidence from the retained exact request and receipt'

    foreach ($crossAction in @('Install', 'Repair')) {
        # Persist a separate copy so each requested action independently proves
        # the tombstone -> Remove CAS ordering and the crash gap before CAS.
        $crossRoot = Join-Path $testRoot ('rolledback-uninstall-before-' + $crossAction.ToLowerInvariant())
        [void](New-Item -ItemType Directory -Path $crossRoot -Force)
        $crossJournalPath = Join-Path $crossRoot 'firewall-lifecycle.json'
        $crossRequestPath = Join-Path $crossRoot 'request.json'
        $crossReceiptPath = Join-Path $crossRoot 'receipt.json'
        $crossRequest = Convert-CycPackagingJson ($orphanRetryAfterCrashRequest | ConvertTo-Json -Depth 12)
        $crossRequest.exchangeRoot = $crossRoot
        Write-CycLifecycleAtomicJson -Path $crossRequestPath -Value $crossRequest
        $crossRequestSha256 = Get-CycLifecycleSha256 -Path $crossRequestPath
        $crossJournal = Convert-CycPackagingJson ($orphanRetryTombstone | ConvertTo-Json -Depth 12)
        $crossJournal.exchangeRoot = $crossRoot
        $crossJournal.requestPath = $crossRequestPath
        $crossJournal.requestSha256 = $crossRequestSha256
        $crossJournal.privateReceiptPath = $crossReceiptPath
        $crossJournal.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Write-CycLifecycleAtomicJson -Path $crossJournalPath -Value $crossJournal
        $crossReceipt = New-CycFirewallReceipt `
            -Request $crossRequest `
            -RequestHash $crossRequestSha256 `
            -Result rolledBack `
            -FailureCode 'coordinator-cancelled-or-timed-out'
        Write-CycLifecycleAtomicJson -Path $crossReceiptPath -Value $crossReceipt

        $crossEvidence = Get-CycRolledBackNoManifestCleanupEvidence `
            -Journal $crossJournal `
            -Receipt $crossReceipt `
            -Manifest $null `
            -Request $crossRequest `
            -RequestedAction $crossAction
        $crossRouting = Get-CycLifecycleRecoveryRouting `
            -Journal $crossJournal `
            -Receipt $crossReceipt `
            -Manifest $null `
            -Request $crossRequest `
            -RequestedAction $crossAction
        Assert-True ([string]$crossRouting.resumeAction -ceq 'Uninstall') "$crossAction resumes the predecessor Uninstall rather than starting Apply"
        Assert-True ([string]$crossRouting.deferredAction -ceq $crossAction) "$crossAction stays deferred behind durable cleanup"
        $crossJournalHashBeforeCrash = Get-CycLifecycleSha256 -Path $crossJournalPath
        $crossAfterCrash = Read-CycLifecycleJson -Path $crossJournalPath -MaximumBytes 65536 -Label "$crossAction cleanup tombstone after simulated crash"
        Assert-True ([string]$crossAfterCrash.phase -ceq 'complete') "$crossAction crash before successor CAS retains the completed cleanup tombstone"
        Assert-True ((Get-CycLifecycleSha256 -Path $crossJournalPath) -ceq $crossJournalHashBeforeCrash) "$crossAction routing does not retire or mutate cleanup evidence before successor CAS"
        Assert-True ($null -ne (Get-CycRolledBackNoManifestCleanupEvidence -Journal $crossAfterCrash -Receipt $crossReceipt -Manifest $null -Request $crossRequest -RequestedAction $crossAction)) "$crossAction reconstructs cleanup after the retirement-to-successor crash gap"

        $successorTransactionId = [Guid]::NewGuid().ToString('N')
        $successorExchange = Join-Path $crossRoot 'successor-remove'
        [void](New-Item -ItemType Directory -Path $successorExchange -Force)
        $successorRequestPath = Join-Path $successorExchange 'request.json'
        $successorReceiptPath = Join-Path $successorExchange 'receipt.json'
        $successorRequest = Convert-CycPackagingJson ($crossRequest | ConvertTo-Json -Depth 12)
        $successorRequest.transactionId = $successorTransactionId
        $successorRequest.requestNonce = ('8' * 64)
        $successorRequest.action = 'Remove'
        $successorRequest.createdAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        $successorRequest.deadlineUtc = [DateTimeOffset]::UtcNow.AddMinutes(10).ToString('o')
        $successorRequest.exchangeRoot = $successorExchange
        Write-CycLifecycleAtomicJson -Path $successorRequestPath -Value $successorRequest
        $successorRequestSha256 = Get-CycLifecycleSha256 -Path $successorRequestPath
        $successorJournal = Convert-CycPackagingJson ($crossAfterCrash | ConvertTo-Json -Depth 12)
        $successorJournal.transactionId = $successorTransactionId
        $successorJournal.action = Get-CycLifecycleTransactionAction -RequestedAction $crossAction -CleanupEvidence $crossEvidence
        $successorJournal.phase = 'prepared'
        $successorJournal.exchangeRoot = $successorExchange
        $successorJournal.requestPath = $successorRequestPath
        $successorJournal.requestSha256 = $successorRequestSha256
        $successorJournal.privateReceiptPath = $successorReceiptPath
        $successorJournal.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Write-CycLifecycleActiveJournal `
            -Path $crossJournalPath `
            -Value $successorJournal `
            -ExpectedCompletedTransactionId ([string]$crossAfterCrash.transactionId) `
            -ExpectedCompletedRequestSha256 ([string]$crossAfterCrash.requestSha256) `
            -ExpectedCompletedAction ([string]$crossAfterCrash.action)
        $publishedSuccessor = Read-CycLifecycleJson -Path $crossJournalPath -MaximumBytes 65536 -Label "$crossAction successor Remove journal"
        Assert-True ([string]$publishedSuccessor.action -ceq 'Uninstall') "$crossAction successor CAS publishes Uninstall, never Apply"
        Assert-True ([string]$successorRequest.action -ceq 'Remove') "$crossAction successor firewall request is Remove"
        Assert-True (Test-CycFirewallRequestJournalBinding -Request $successorRequest -Journal $publishedSuccessor) "$crossAction successor Remove request is exactly bound to its journal"

        $publishedSuccessor.phase = 'coreApplied'
        $publishedSuccessor.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Write-CycLifecycleAtomicJson -Path $crossJournalPath -Value $publishedSuccessor
        $successorVerifiedReceipt = New-CycFirewallReceipt `
            -Request $successorRequest `
            -RequestHash $successorRequestSha256 `
            -Result verified
        Write-CycLifecycleAtomicJson -Path $successorReceiptPath -Value $successorVerifiedReceipt
        Assert-True ((Get-CycFirewallResumeDecision `
                    -Journal $publishedSuccessor `
                    -Receipt $successorVerifiedReceipt `
                    -Manifest $null `
                    -ReceiptSha256 (Get-CycLifecycleSha256 -Path $successorReceiptPath) `
                    -RequestedAction Uninstall) -eq 'Complete') "$crossAction deferred action can continue only after a verified successor Remove"
        $publishedSuccessor.phase = 'complete'
        $publishedSuccessor.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Write-CycLifecycleAtomicJson -Path $crossJournalPath -Value $publishedSuccessor
        [void](Remove-CycCompletedLifecycleJournal `
            -Path $crossJournalPath `
            -TransactionId $successorTransactionId `
            -ExpectedAction Uninstall `
            -ExpectedRequestSha256 $successorRequestSha256)
        Assert-True (-not (Test-Path -LiteralPath $crossJournalPath)) "$crossAction begins only after verified Remove cleanup retires durably"
    }

    # Compatibility regression for the old buggy coordinator that could CAS a
    # pending cleanup tombstone directly to Apply.  If that persisted Apply is
    # prepared and then rolls back with no manifest, its snapshot may have
    # restored the orphan.  A later action must conservatively run a separately
    # journaled verified Remove; Uninstall must never report unchanged here.
    foreach ($legacyApplyAction in @('Install', 'Repair')) {
        $legacyRoot = Join-Path $testRoot ('legacy-rolledback-apply-' + $legacyApplyAction.ToLowerInvariant())
        [void](New-Item -ItemType Directory -Path $legacyRoot -Force)
        $legacyJournalPath = Join-Path $legacyRoot 'firewall-lifecycle.json'
        $legacyRequestPath = Join-Path $legacyRoot 'request.json'
        $legacyReceiptPath = Join-Path $legacyRoot 'receipt.json'
        $legacyRequest = Convert-CycPackagingJson ($resumeRequest | ConvertTo-Json -Depth 12)
        $legacyRequest.transactionId = [Guid]::NewGuid().ToString('N')
        $legacyRequest.requestNonce = ('5' * 64)
        $legacyRequest.action = 'Apply'
        $legacyRequest.createdAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        $legacyRequest.deadlineUtc = [DateTimeOffset]::UtcNow.AddMinutes(10).ToString('o')
        $legacyRequest.exchangeRoot = $legacyRoot
        Write-CycLifecycleAtomicJson -Path $legacyRequestPath -Value $legacyRequest
        $legacyRequestSha256 = Get-CycLifecycleSha256 -Path $legacyRequestPath
        $legacyJournal = Convert-CycPackagingJson ($resumeJournal | ConvertTo-Json -Depth 12)
        $legacyJournal.transactionId = [string]$legacyRequest.transactionId
        $legacyJournal.action = $legacyApplyAction
        $legacyJournal.phase = 'prepared'
        $legacyJournal.exchangeRoot = $legacyRoot
        $legacyJournal.requestPath = $legacyRequestPath
        $legacyJournal.requestSha256 = $legacyRequestSha256
        $legacyJournal.privateReceiptPath = $legacyReceiptPath
        $legacyJournal.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Write-CycLifecycleAtomicJson -Path $legacyJournalPath -Value $legacyJournal
        $legacyRolledBackReceipt = New-CycFirewallReceipt `
            -Request $legacyRequest `
            -RequestHash $legacyRequestSha256 `
            -Result rolledBack `
            -FailureCode 'coordinator-cancelled-or-timed-out'
        Write-CycLifecycleAtomicJson -Path $legacyReceiptPath -Value $legacyRolledBackReceipt

        $legacyUninstallRouting = Get-CycLifecycleRecoveryRouting `
            -Journal $legacyJournal `
            -Receipt $legacyRolledBackReceipt `
            -Manifest $null `
            -Request $legacyRequest `
            -RequestedAction Uninstall
        Assert-True ([bool]$legacyUninstallRouting.cleanupPending) "$legacyApplyAction rolledBack Apply with no manifest is conservatively owned cleanup state"
        Assert-True ([string]$legacyUninstallRouting.resumeAction -ceq $legacyApplyAction) "$legacyApplyAction rolledBack Apply is retired only from its exact predecessor action"
        Assert-True ([string]::IsNullOrWhiteSpace([string]$legacyUninstallRouting.deferredAction)) "$legacyApplyAction rolledBack Apply can satisfy a requested Uninstall directly through cleanup"
        $legacyDeferredRouting = Get-CycLifecycleRecoveryRouting `
            -Journal $legacyJournal `
            -Receipt $legacyRolledBackReceipt `
            -Manifest $null `
            -Request $legacyRequest `
            -RequestedAction $legacyApplyAction
        Assert-True ([string]$legacyDeferredRouting.deferredAction -ceq $legacyApplyAction) "$legacyApplyAction retry is deferred until the restored-rule uncertainty is removed"
        $legacyCleanupEvidence = Get-CycRolledBackNoManifestCleanupEvidence `
            -Journal $legacyJournal `
            -Receipt $legacyRolledBackReceipt `
            -Manifest $null `
            -Request $legacyRequest `
            -RequestedAction Uninstall
        Assert-True ($null -ne $legacyCleanupEvidence) "$legacyApplyAction rolledBack Apply yields exact request-bound cleanup evidence"
        Assert-True ((Get-CycLifecycleTransactionAction -RequestedAction Uninstall -CleanupEvidence $legacyCleanupEvidence) -ceq 'Uninstall') "$legacyApplyAction rolledBack Apply forces verified Remove instead of unchanged Uninstall"
        Assert-True ((Get-CycLifecycleDeferredAction -RequestedAction $legacyApplyAction -CurrentDeferredAction $null -CleanupEvidence $legacyCleanupEvidence) -ceq $legacyApplyAction) "$legacyApplyAction is restored as the deferred action when rollback evidence appears only after recovery"

        $legacyRollbackFailedReceipt = New-CycFirewallReceipt `
            -Request $legacyRequest `
            -RequestHash $legacyRequestSha256 `
            -Result rollbackFailed `
            -FailureCode 'helper-and-rollback-failure'
        $legacyRollbackFailedRouting = Get-CycLifecycleRecoveryRouting `
            -Journal $legacyJournal `
            -Receipt $legacyRollbackFailedReceipt `
            -Manifest $null `
            -Request $legacyRequest `
            -RequestedAction Uninstall
        $legacyJournalHashBeforeRecovery = Get-CycLifecycleSha256 -Path $legacyJournalPath
        Assert-True ((Get-CycFirewallResumeDecision `
                    -Journal $legacyJournal `
                    -Receipt $legacyRollbackFailedReceipt `
                    -Manifest $null `
                    -ReceiptSha256 ('4' * 64) `
                    -RequestedAction ([string]$legacyRollbackFailedRouting.resumeAction)) -eq 'Resume') "$legacyApplyAction rollbackFailed cross-action resumes exact snapshot rollback before Uninstall"
        Assert-True ((Get-CycLifecycleSha256 -Path $legacyJournalPath) -ceq $legacyJournalHashBeforeRecovery) "$legacyApplyAction rollbackFailed routing preserves the active journal until recovery publishes rolledBack"

        $legacyCompletion = Complete-CycPreCoreFirewallRecovery `
            -Journal $legacyJournal `
            -Receipt $legacyRolledBackReceipt `
            -Manifest $null `
            -Request $legacyRequest `
            -RequestedAction Uninstall `
            -JournalPath $legacyJournalPath
        Assert-True ($null -ne $legacyCompletion.retryEvidence) "$legacyApplyAction rolledBack Apply commits a durable cleanup tombstone"
        $legacyTombstone = Read-CycLifecycleJson -Path $legacyJournalPath -MaximumBytes 65536 -Label "$legacyApplyAction rolledBack Apply tombstone"
        Assert-True ([string]$legacyTombstone.phase -ceq 'complete') "$legacyApplyAction rolledBack Apply tombstone survives until Remove successor CAS"

        $legacyRemoveTransactionId = [Guid]::NewGuid().ToString('N')
        $legacyRemoveRoot = Join-Path $legacyRoot 'successor-remove'
        [void](New-Item -ItemType Directory -Path $legacyRemoveRoot -Force)
        $legacyRemoveRequestPath = Join-Path $legacyRemoveRoot 'request.json'
        $legacyRemoveReceiptPath = Join-Path $legacyRemoveRoot 'receipt.json'
        $legacyRemoveRequest = Convert-CycPackagingJson ($legacyRequest | ConvertTo-Json -Depth 12)
        $legacyRemoveRequest.transactionId = $legacyRemoveTransactionId
        $legacyRemoveRequest.requestNonce = ('3' * 64)
        $legacyRemoveRequest.action = 'Remove'
        $legacyRemoveRequest.createdAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        $legacyRemoveRequest.deadlineUtc = [DateTimeOffset]::UtcNow.AddMinutes(10).ToString('o')
        $legacyRemoveRequest.exchangeRoot = $legacyRemoveRoot
        Write-CycLifecycleAtomicJson -Path $legacyRemoveRequestPath -Value $legacyRemoveRequest
        $legacyRemoveRequestSha256 = Get-CycLifecycleSha256 -Path $legacyRemoveRequestPath
        $legacyRemoveJournal = Convert-CycPackagingJson ($legacyTombstone | ConvertTo-Json -Depth 12)
        $legacyRemoveJournal.transactionId = $legacyRemoveTransactionId
        $legacyRemoveJournal.action = 'Uninstall'
        $legacyRemoveJournal.phase = 'prepared'
        $legacyRemoveJournal.exchangeRoot = $legacyRemoveRoot
        $legacyRemoveJournal.requestPath = $legacyRemoveRequestPath
        $legacyRemoveJournal.requestSha256 = $legacyRemoveRequestSha256
        $legacyRemoveJournal.privateReceiptPath = $legacyRemoveReceiptPath
        $legacyRemoveJournal.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Write-CycLifecycleActiveJournal `
            -Path $legacyJournalPath `
            -Value $legacyRemoveJournal `
            -ExpectedCompletedTransactionId ([string]$legacyCompletion.replaceCompletedTransactionId) `
            -ExpectedCompletedRequestSha256 ([string]$legacyCompletion.replaceCompletedRequestSha256) `
            -ExpectedCompletedAction ([string]$legacyCompletion.replaceCompletedAction)
        Assert-True (Test-CycFirewallRequestJournalBinding -Request $legacyRemoveRequest -Journal $legacyRemoveJournal) "$legacyApplyAction uncertainty is replaced by an exact successor Remove journal"
        $legacyRemoveJournal.phase = 'coreApplied'
        $legacyRemoveJournal.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Write-CycLifecycleAtomicJson -Path $legacyJournalPath -Value $legacyRemoveJournal
        $legacyVerifiedRemove = New-CycFirewallReceipt `
            -Request $legacyRemoveRequest `
            -RequestHash $legacyRemoveRequestSha256 `
            -Result verified
        Write-CycLifecycleAtomicJson -Path $legacyRemoveReceiptPath -Value $legacyVerifiedRemove
        Assert-True ((Get-CycFirewallResumeDecision `
                    -Journal $legacyRemoveJournal `
                    -Receipt $legacyVerifiedRemove `
                    -Manifest $null `
                    -ReceiptSha256 (Get-CycLifecycleSha256 -Path $legacyRemoveReceiptPath) `
                    -RequestedAction Uninstall) -eq 'Complete') "$legacyApplyAction persisted rollback converges through verified Remove, never unchanged"
        $legacyRemoveJournal.phase = 'complete'
        $legacyRemoveJournal.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Write-CycLifecycleAtomicJson -Path $legacyJournalPath -Value $legacyRemoveJournal
        [void](Remove-CycCompletedLifecycleJournal `
            -Path $legacyJournalPath `
            -TransactionId $legacyRemoveTransactionId `
            -ExpectedAction Uninstall `
            -ExpectedRequestSha256 $legacyRemoveRequestSha256)
        Assert-True (-not (Test-Path -LiteralPath $legacyJournalPath)) "$legacyApplyAction legacy rollback cleanup retires only after verified Remove"
    }

    $orphanSuccessor = Convert-CycPackagingJson ($orphanRetryTombstone | ConvertTo-Json -Depth 12)
    $orphanSuccessor.transactionId = [Guid]::NewGuid().ToString('N')
    $orphanSuccessor.requestSha256 = ('7' * 64)
    $orphanSuccessor.phase = 'prepared'
    Write-CycLifecycleActiveJournal `
        -Path $orphanRetryJournalPath `
        -Value $orphanSuccessor `
        -ExpectedCompletedTransactionId ([string]$orphanRetryCompletion.replaceCompletedTransactionId) `
        -ExpectedCompletedRequestSha256 ([string]$orphanRetryCompletion.replaceCompletedRequestSha256) `
        -ExpectedCompletedAction ([string]$orphanRetryCompletion.replaceCompletedAction)
    $orphanPublished = Read-CycLifecycleJson -Path $orphanRetryJournalPath -MaximumBytes 65536 -Label 'rolled-back Uninstall successor journal'
    Assert-True ([string]$orphanPublished.transactionId -ceq [string]$orphanSuccessor.transactionId) 'successor Remove journal atomically replaces the retained rolled-back Uninstall tombstone'

    # A firewallApplied Remove plus absent manifest is the exact durable core
    # after-image.  rollbackFailed must not force pre-core retirement here: the
    # coordinator promotes to coreApplied and accepts only a verified Remove.
    $promotedRemoveRoot = Join-Path $testRoot 'firewallapplied-promoted-remove'
    [void](New-Item -ItemType Directory -Path $promotedRemoveRoot -Force)
    $promotedRemoveRequestPath = Join-Path $promotedRemoveRoot 'request.json'
    $promotedRemoveJournalPath = Join-Path $promotedRemoveRoot 'firewall-lifecycle.json'
    $promotedRemoveRequest = Convert-CycPackagingJson ($resumeRequest | ConvertTo-Json -Depth 12)
    $promotedRemoveRequest.action = 'Remove'
    $promotedRemoveRequest.exchangeRoot = $promotedRemoveRoot
    Write-CycLifecycleAtomicJson -Path $promotedRemoveRequestPath -Value $promotedRemoveRequest
    $promotedRemoveRequestSha256 = Get-CycLifecycleSha256 -Path $promotedRemoveRequestPath
    $promotedRemoveJournal = Convert-CycPackagingJson ($resumeJournal | ConvertTo-Json -Depth 12)
    $promotedRemoveJournal.action = 'Uninstall'
    $promotedRemoveJournal.phase = 'firewallApplied'
    $promotedRemoveJournal.exchangeRoot = $promotedRemoveRoot
    $promotedRemoveJournal.requestPath = $promotedRemoveRequestPath
    $promotedRemoveJournal.requestSha256 = $promotedRemoveRequestSha256
    $promotedRemoveJournal.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    $promotedRollbackFailedReceipt = New-CycFirewallReceipt `
        -Request $promotedRemoveRequest `
        -RequestHash $promotedRemoveRequestSha256 `
        -Result rollbackFailed `
        -FailureCode 'helper-and-rollback-failure'
    Assert-True (Test-CycLifecycleCoreCommitAfterImage -Journal $promotedRemoveJournal -Manifest $null -Request $promotedRemoveRequest) 'firewallApplied absent-manifest Remove proves the exact committed Uninstall after-image despite rollbackFailed helper evidence'
    $promotedRemoveJournal.phase = 'coreApplied'
    Write-CycLifecycleAtomicJson -Path $promotedRemoveJournalPath -Value $promotedRemoveJournal
    $persistedPromotedRemove = Read-CycLifecycleJson -Path $promotedRemoveJournalPath -MaximumBytes 65536 -Label 'promoted Remove lifecycle journal'
    Assert-True ([string]$persistedPromotedRemove.phase -ceq 'coreApplied') 'firewallApplied absent-manifest Remove promotion is durable before helper finalization'
    $promotedVerifiedReceipt = New-CycFirewallReceipt `
        -Request $promotedRemoveRequest `
        -RequestHash $promotedRemoveRequestSha256 `
        -Result verified
    Assert-True ([string]$promotedVerifiedReceipt.action -ceq 'Remove') 'promoted Uninstall finalization remains bound to Remove'
    Assert-True ((Get-CycFirewallResumeDecision `
                -Journal $persistedPromotedRemove `
                -Receipt $promotedVerifiedReceipt `
                -Manifest $null `
                -ReceiptSha256 ('6' * 64) `
                -RequestedAction Uninstall) -eq 'Complete') 'promoted coreApplied Uninstall completes only after a verified Remove with no manifest'
    $resumeJournal.action = 'Repair'
    $resumeRequest.action = 'Apply'
    $resumeReceipt.action = 'Apply'
    $resumeJournal.phase = 'complete'
    Assert-True ((Get-CycFirewallResumeDecision -Journal $resumeJournal -Receipt $resumeReceipt -Manifest $null -ReceiptSha256 $resumeReceiptSha256 -RequestedAction Install) -eq 'RetireAbortedThenStart') 'a crash between rolledBack tombstone write and retirement remains convergent'
    $resumeJournal.action = 'Install'
    $resumeJournal.phase = 'coreApplied'
    $resumeReceipt.result = 'verified'
    $resumeReceipt.failureCode = $null

    $resumeJournal | Add-Member -NotePropertyName unexpectedField -NotePropertyValue 'reject-me'
    Assert-ThrowsLike `
        -Action {
            [void](Assert-CycLifecycleJournal `
                -Journal $resumeJournal `
                -Binding $resumeBinding `
                -Roots $resumeRoots `
                -PrivateReceiptRoot $resumePrivateReceiptRoot)
        } `
        -Pattern 'unsupported or missing field' `
        -Message 'lifecycle journal rejects every unsupported field before using persisted paths'
    $resumeJournal.PSObject.Properties.Remove('unexpectedField')

    $journalCasRoot = Join-Path $testRoot 'lifecycle-journal-cas'
    [void](New-Item -ItemType Directory -Path $journalCasRoot -Force)
    $journalCasPath = Join-Path $journalCasRoot 'firewall-lifecycle.json'
    $resumeJournal.phase = 'complete'
    Write-CycLifecycleAtomicJson -Path $journalCasPath -Value $resumeJournal
    $journalCasOriginalHash = Get-CycLifecycleSha256 -Path $journalCasPath
    $nextJournal = Convert-CycPackagingJson ($resumeJournal | ConvertTo-Json -Depth 12)
    $nextJournal.transactionId = [Guid]::NewGuid().ToString('N')
    $nextJournal.requestSha256 = ('9' * 64)
    $nextJournal.action = 'Repair'
    $nextJournal.phase = 'prepared'
    Assert-ThrowsLike `
        -Action {
            Write-CycLifecycleActiveJournal `
                -Path $journalCasPath `
                -Value $nextJournal `
                -ExpectedCompletedTransactionId ('0' * 32) `
                -ExpectedCompletedRequestSha256 $requestHash `
                -ExpectedCompletedAction Install
        } `
        -Pattern 'changed before the next transaction' `
        -Message 'journal compare-and-swap rejects a stale completed transaction identity'
    Assert-True ((Get-CycLifecycleSha256 -Path $journalCasPath) -ceq $journalCasOriginalHash) 'failed lifecycle compare-and-swap preserves the previous journal bytes'
    Write-CycLifecycleActiveJournal `
        -Path $journalCasPath `
        -Value $nextJournal `
        -ExpectedCompletedTransactionId $transactionId `
        -ExpectedCompletedRequestSha256 $requestHash `
        -ExpectedCompletedAction Install
    $writtenNextJournal = Read-CycLifecycleJson -Path $journalCasPath -MaximumBytes 65536 -Label 'CAS test lifecycle journal'
    Assert-True ([string]$writtenNextJournal.transactionId -ceq [string]$nextJournal.transactionId) 'journal compare-and-swap installs the new active transaction only after the terminal identity matches'
    Assert-ThrowsLike `
        -Action {
            [void](Remove-CycCompletedLifecycleJournal `
                -Path $journalCasPath `
                -TransactionId ([string]$nextJournal.transactionId) `
                -ExpectedAction Repair `
                -ExpectedRequestSha256 ([string]$nextJournal.requestSha256))
        } `
        -Pattern 'not the completed active transaction' `
        -Message 'an in-progress lifecycle journal cannot be retired'
    $nextJournal.phase = 'complete'
    Write-CycLifecycleAtomicJson -Path $journalCasPath -Value $nextJournal
    $journalCasCompleteHash = Get-CycLifecycleSha256 -Path $journalCasPath
    Assert-ThrowsLike `
        -Action {
            [void](Remove-CycCompletedLifecycleJournal `
                -Path $journalCasPath `
                -TransactionId ([string]$nextJournal.transactionId) `
                -ExpectedAction Repair `
                -ExpectedRequestSha256 ('8' * 64))
        } `
        -Pattern 'not the completed active transaction' `
        -Message 'completed lifecycle retirement rejects a stale request digest'
    Assert-True ((Get-CycLifecycleSha256 -Path $journalCasPath) -ceq $journalCasCompleteHash) 'failed completed-journal retirement preserves the terminal journal bytes'
    Assert-True (Remove-CycCompletedLifecycleJournal `
        -Path $journalCasPath `
        -TransactionId ([string]$nextJournal.transactionId) `
        -ExpectedAction Repair `
        -ExpectedRequestSha256 ([string]$nextJournal.requestSha256)) 'exact terminal journal identity can be retired'
    Assert-True (-not (Test-Path -LiteralPath $journalCasPath)) 'completed lifecycle retirement removes only the fixed active journal'

    $heldLifecycleMutex = Enter-CycLifecycleMutex -Sid ([string]$resumeBinding.sid) -TimeoutSeconds 5
    try {
        $escapedLifecycleScript = $lifecycleScript.Replace("'", "''")
        $mutexProbeSource = @"
`$ErrorActionPreference = 'Stop'
. '$escapedLifecycleScript' -Action Install
`$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
try {
    `$probeMutex = Enter-CycLifecycleMutex -Sid `$sid -TimeoutSeconds 1
    try { exit 41 } finally { Exit-CycLifecycleMutex -Mutex `$probeMutex }
} catch {
    if (`$_.Exception.Message -ceq 'Another ClusterYourCodex install, repair, or uninstall is still active.') { exit 0 }
    exit 42
}
"@
        $encodedMutexProbe = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($mutexProbeSource))
        $mutexProbe = Start-Process `
            -FilePath $windowsPowerShell `
            -ArgumentList @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-EncodedCommand', $encodedMutexProbe
            ) `
            -WorkingDirectory $testRoot `
            -WindowStyle Hidden `
            -Wait `
            -PassThru
        Assert-True ($mutexProbe.ExitCode -eq 0) 'a second Windows process cannot enter the same per-SID lifecycle mutex'
    } finally {
        Exit-CycLifecycleMutex -Mutex $heldLifecycleMutex
    }

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
    $bootstrapSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'bootstrap.ps1') -Raw
    $previewPayloadSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'New-PreviewPayload.ps1') -Raw
    $workerInstallerSource = Get-Content -LiteralPath (Join-Path $repoRoot 'packaging\worker-kits\windows\Install-Worker.ps1') -Raw
    $workerKitsHarnessSource = Get-Content -LiteralPath (Join-Path $repoRoot 'packaging\worker-kits\Test-WorkerKits.ps1') -Raw
    $uninstallerSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Uninstall-ClusterYourCodex.ps1') -Raw
    $desktopIntegrationSource = Get-Content -LiteralPath (Join-Path $repoRoot 'apps\desktop\src-tauri\src\integration.rs') -Raw
    Assert-True (([regex]::Matches($lifecycleSource, '(?i)-Verb\s+RunAs')).Count -eq 1) 'coordinator contains exactly one firewall-only elevation site'
    Assert-True ($lifecycleSource -match 'Start-CycFirewallOnlyElevation') 'only the narrow firewall helper crosses UAC'
    Assert-True ($lifecycleSource -match 'Start-CycFirewallRecoveryElevationIfNeeded') 'dead-helper recovery relaunches only the transaction-bound helper'
    Assert-True ($lifecycleSource -match 'Test-CycLifecycleHelperLockHeld') 'recovery avoids duplicating a helper that still owns the transaction lock'
    Assert-True ($lifecycleSource -match 'EncodedCommand[\s\S]{0,80}encodedLoader') 'UAC starts a fixed captured-byte verifier instead of a user-writable helper file'
    Assert-True ($lifecycleSource -notmatch 'ExecutionPolicy[^\r\n]+-File[^\r\n]+\$HelperPath') 'UAC never directly executes the copied helper through -File'
    Assert-True ($lifecycleSource -match 'Get-AuthenticodeSignature\s+-Content\s+`?\$helperBytes') 'GA elevation verifies Authenticode over the same captured helper bytes it executes'
    Assert-True ($lifecycleSource -match '\[ScriptBlock\]::Create\(`?\$helperText\)') 'only digest-verified captured helper text becomes executable'
    Assert-True ($firewallSource -match "ValidateSet\('Rollback', 'Finalize'\).*RecoveryAction") 'elevated recovery exposes only rollback or finalize actions'
    Assert-True ($lifecycleSource -match 'function Read-CycLifecycleJson' -and
        $lifecycleSource -match '\[System\.IO\.File\]::ReadAllBytes\(\$resolved\)' -and
        $lifecycleSource -match 'New-Object System\.Text\.UTF8Encoding\(\$false,\s*\$true\)' -and
        $lifecycleSource -match '\$hasUtf8Bom' -and
        $lifecycleSource -match '0xEF' -and $lifecycleSource -match '0xBB' -and $lifecycleSource -match '0xBF' -and
        $lifecycleSource -notmatch 'Get-Content[^\r\n]+ConvertFrom-Json') 'lifecycle coordinator reads file-backed JSON as strict UTF-8 bytes with BOM support'
    Assert-True ($firewallSource -match 'function Read-CycFirewallJson' -and
        $firewallSource -match '\[System\.IO\.File\]::ReadAllBytes\(\$resolved\)' -and
        $firewallSource -match 'New-Object System\.Text\.UTF8Encoding\(\$false,\s*\$true\)' -and
        $firewallSource -match '\$hasUtf8Bom' -and
        $firewallSource -match '0xEF' -and $firewallSource -match '0xBB' -and $firewallSource -match '0xBF' -and
        $firewallSource -notmatch 'Get-Content[^\r\n]+ConvertFrom-Json') 'firewall helper reads file-backed JSON as strict UTF-8 bytes with BOM support'
    $helperProbeStdout = Join-Path $testRoot 'helper-normal-entry.stdout.log'
    $helperProbeStderr = Join-Path $testRoot 'helper-normal-entry.stderr.log'
    $helperProbePath64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($firewallScript))
    $helperProbeMissing64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
        (Join-Path $testRoot ('missing-normal-request-' + [Guid]::NewGuid().ToString('N') + '.json'))
    ))
    $helperProbeSource = @"
`$ErrorActionPreference = 'Stop'
`$helperPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$helperProbePath64'))
`$missingRequest = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$helperProbeMissing64'))
`$helperBytes = [IO.File]::ReadAllBytes(`$helperPath)
`$helperText = (New-Object Text.UTF8Encoding(`$false, `$true)).GetString(`$helperBytes)
`$hasher = [Security.Cryptography.SHA256]::Create()
try { `$helperHash = ([BitConverter]::ToString(`$hasher.ComputeHash(`$helperBytes))).Replace('-', '').ToLowerInvariant() }
finally { `$hasher.Dispose() }
`$verifiedBlock = [ScriptBlock]::Create(`$helperText)
& `$verifiedBlock -RequestPath `$missingRequest -ExpectedRequestSha256 ('0' * 64) -ExpectedHelperSha256 `$helperHash -VerifiedHelperPath `$helperPath
exit 91
"@
    $helperProbeEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($helperProbeSource))
    $helperProbe = Start-Process `
        -FilePath $windowsPowerShell `
        -ArgumentList @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-EncodedCommand', $helperProbeEncoded
        ) `
        -WorkingDirectory $testRoot `
        -WindowStyle Hidden `
        -RedirectStandardOutput $helperProbeStdout `
        -RedirectStandardError $helperProbeStderr `
        -Wait `
        -PassThru
    $helperProbeOutput = ((Get-Content -LiteralPath $helperProbeStdout -Raw -ErrorAction SilentlyContinue) +
        (Get-Content -LiteralPath $helperProbeStderr -Raw -ErrorAction SilentlyContinue))
    Assert-True ($helperProbe.ExitCode -eq 1) 'captured helper normal mode reaches its fail-closed administrator/request guard'
    Assert-True ($helperProbeOutput -notmatch "RecoveryAction[\s\S]+does not belong to the set") 'normal non-recovery helper entry does not bind empty strings through ValidateSet'
    Assert-True ($firewallSource -match 'AllowExpiredRecovery') 'expired requests are accepted only through the explicit bound recovery path'
    Assert-True ($firewallSource -match 'Read-CycFirewallDigestBoundJson') 'elevated helper hashes and parses request and journal from one captured byte sequence'
    Assert-True ($firewallSource -match 'ExpectedRecoveryJournalSha256') 'recovery is bound to the coordinator-approved lifecycle journal digest'
    Assert-True ($firewallSource -match 'ReapplyThenFinalize') 'core-applied recovery explicitly re-establishes a timed-out or interrupted desired firewall state'
    Assert-True ($previewPayloadSource -match 'function Read-CycPreviewUtf8Json' -and
        $previewPayloadSource -match '\[System\.IO\.File\]::ReadAllBytes' -and
        $previewPayloadSource -match 'New-Object System\.Text\.UTF8Encoding\(\$false,\s*\$true\)' -and
        $previewPayloadSource -match '0xEF' -and $previewPayloadSource -match '0xBB' -and $previewPayloadSource -match '0xBF' -and
        $previewPayloadSource -notmatch 'Get-Content[^\r\n]+ConvertFrom-Json') 'preview payload staging reads metadata as strict UTF-8 with BOM support'
    Assert-True ($workerInstallerSource -match 'function Read-WorkerUtf8Json' -and
        $workerInstallerSource -match '\[System\.IO\.File\]::ReadAllBytes' -and
        $workerInstallerSource -match 'New-Object System\.Text\.UTF8Encoding\(\$false,\s*\$true\)' -and
        $workerInstallerSource -match '0xEF' -and $workerInstallerSource -match '0xBB' -and $workerInstallerSource -match '0xBF' -and
        $workerInstallerSource -notmatch 'Get-Content[^\r\n]+ConvertFrom-Json') 'Windows worker repair reads state and manifests as strict UTF-8 with BOM support'
    $workerHashFunction = [regex]::Match($workerInstallerSource, 'function Get-CycWorkerFileHash[\s\S]+?function Test-Ed25519Signature')
    Assert-True ($workerHashFunction.Success -and
        $workerHashFunction.Value -match 'SHA256\]::Create' -and
        $workerHashFunction.Value -match 'ComputeHash\(\$stream\)' -and
        $workerHashFunction.Value -match 'OpenRead\(\$LiteralPath\)' -and
        $workerHashFunction.Value -match '\$sha256\.Dispose\(\)' -and
        $workerHashFunction.Value -match '\$stream\.Dispose\(\)') 'Windows worker installer hashes kit files through its module-independent streaming SHA-256 helper'
    Assert-True (([regex]::Matches($workerInstallerSource, '(?m)^\s*(?!#).*Get-CycWorkerFileHash\s+-LiteralPath')).Count -ge 4) 'Windows worker installer routes every file-integrity check through the streaming SHA-256 helper'
    Assert-True (([regex]::Matches($workerInstallerSource, '(?m)^\s*(?!#).*Get-FileHash\s+-LiteralPath')).Count -eq 0) 'Windows worker installer has no direct Get-FileHash dependency under -NoProfile'
    Assert-True ($workerKitsHarnessSource -match 'function Read-CycWorkerKitsUtf8Json' -and
        $workerKitsHarnessSource -match '\[System\.IO\.File\]::ReadAllBytes' -and
        $workerKitsHarnessSource -match 'New-Object System\.Text\.UTF8Encoding\(\$false,\s*\$true\)' -and
        $workerKitsHarnessSource -match '0xEF' -and $workerKitsHarnessSource -match '0xBB' -and $workerKitsHarnessSource -match '0xBF' -and
        $workerKitsHarnessSource -notmatch 'Get-Content[^\r\n]+ConvertFrom-Json') 'worker-kit validation reads metadata as strict UTF-8 with BOM support'
    Assert-True ($firewallSource -match '\[System\.IO\.File\]::Replace\(') 'firewall state and receipts use native same-volume atomic replacement'
    Assert-True ($firewallSource -notmatch '(?m)^\s*Move-Item\s+-LiteralPath\s+\$temporary') 'firewall atomic writer does not emulate replacement with non-atomic Move-Item -Force'
    Assert-True ($lifecycleSource -match 'CycMaxInstallManifestBytes\s*=\s*16MB') 'lifecycle coordinator accepts the bounded self-contained install manifest size'
    Assert-True ($desktopIntegrationSource -match 'MAX_INSTALL_MANIFEST:\s*u64\s*=\s*16\s*\*\s*1024\s*\*\s*1024') 'desktop integration accepts the same bounded self-contained install manifest size'
    Assert-True ($lifecycleSource -match 'CYC_SETUP_DIAGNOSTIC_LOG') 'lifecycle writes a harness-bound structured Setup diagnostic'
    Assert-True ($lifecycleSource -match 'cyc\.dev/setup-lifecycle-diagnostic/v1') 'lifecycle diagnostic has a versioned schema'
    Assert-True ($lifecycleSource -match 'lastStage\s*=\s*\$script:CycLifecycleDiagnosticStage') 'lifecycle diagnostic identifies the last coordinator stage reached'
    Assert-True ($lifecycleSource -match '\$systemPowerShell\s+@(?:Arguments|hiddenArguments)\s+2>\s*\$stderrPath') 'lifecycle preserves bounded bootstrap stderr without Windows PowerShell NativeCommandError promotion'
    Assert-True ($lifecycleSource -match '\$hiddenArguments\s*=\s*@\(\x27-WindowStyle\x27,\s*\x27Hidden\x27\)\s*\+\s*\$Arguments[\s\S]+\$systemPowerShell\s+@hiddenArguments') 'nested bootstrap PowerShell remains hidden under ARM64 emulation'
    Assert-True ($lifecycleSource -match 'InitiatingSid[\s\S]+InitiatingProfile[\s\S]+InitiatingLocalAppData') 'core calls retain the initiating SID/profile binding'
    Assert-True ($lifecycleSource -match "Global\\ClusterYourCodex\.WindowsLifecycle\.v1\.") 'one global per-SID mutex serializes install, repair, and uninstall across Windows sessions'
    Assert-True ($lifecycleSource -match 'Write-CycLifecycleActiveJournal') 'a new lifecycle transaction uses compare-and-swap replacement of a verified completed journal'
    Assert-True ($lifecycleSource -match "return 'RetireThenStart'") 'completed transactions retire before a distinct lifecycle action starts'
    Assert-True ($lifecycleSource -match "return 'RetireAbortedThenStart'") 'rolled-back transactions retire before any later lifecycle action starts'
    Assert-True ($lifecycleSource -match 'Test-CycPendingFirewallManifestBinding') 'receipt recovery commits only an exactly bound pending manifest'
    Assert-True ($lifecycleSource -match 'Test-CycLifecycleCoreCommitAfterImage') 'recovery reconciles the core-commit crash window from an exact request-bound after-image'
    Assert-True ($lifecycleSource -match "receiptAllowsCorePromotion[\s\S]+rollbackFailed") 'an exact rollbackFailed receipt no longer blocks core after-image promotion'
    Assert-True ($lifecycleSource -match 'PreviousSha256') 'rollbackFailed recovery waits for atomic response replacement rather than stale filename existence'
    Assert-True ($lifecycleSource -match 'Get-CycRolledBackUninstallRetryEvidence') 'a rolled-back Uninstall with an absent manifest is retried from exact immutable firewall evidence'
    Assert-True ($lifecycleSource -match 'uninstall-firewall-retry') 'repeated Uninstall cannot report unchanged while its previous firewall rollback remains outstanding'
    Assert-True ($lifecycleSource -match 'coreManagedWorker\s*=\s*if\s*\(\$transactionAction\s+-in\s+@\(''Install'',\s*''Repair''\)\)[\s\S]+-ManagedWorker\s+\$coreManagedWorker') 'Uninstall core invocation does not dereference a null install plan'
    Assert-True ($lifecycleSource -match 'Publish-CycLifecycleReceiptAtomic') 'private firewall receipts are published by same-directory atomic replacement'
    Assert-True ($lifecycleSource -match '\[System\.IO\.File\]::Replace\(') 'lifecycle journal replacement uses the native same-volume atomic replace primitive'
    Assert-True ($lifecycleSource -match 'Remove-CycCompletedLifecycleJournal[\s\S]+-ExpectedRequestSha256') 'normal and resumed completion retire only the expected terminal transaction'
    Assert-True ($lifecycleSource -match 'function Assert-CycCreationPathNoReparse' -and
        $lifecycleSource -match 'Assert-CycCreationPathNoReparse\s+-Path\s+\$base' -and
        $lifecycleSource -match 'Assert-CycCreationPathNoReparse\s+-Path\s+\$parent') 'lifecycle checks every existing ancestor before creating private directories or durable files'
    Assert-True ($uninstallerSource -notmatch '(?i)-Verb\s+RunAs|-Elevated') 'uninstaller stays in initiating HKCU/profile context'
    Assert-True ($uninstallerSource -match 'Invoke-ClusterYourCodexLifecycle\.ps1') 'uninstaller delegates only the firewall sub-step to the coordinator'
    Assert-True ($firewallSource -notmatch '(?i)Invoke-Expression|cmd\.exe|Start-Process|&\s+\$Request') 'elevated helper has no arbitrary command or script channel'
    Assert-True ($firewallSource -match 'Profile Private[\s\S]+Protocol TCP[\s\S]+RemoteAddress LocalSubnet') 'helper fixes Private/TCP/LocalSubnet scope'
    Assert-True ($firewallSource -match 'Restore-CycExactFirewallSnapshot') 'helper retains a durable rollback path for core failure and timeout'

    # Scheduled-task principal contract: production stays InteractiveToken.
    # Disposable profiles use only the explicit elevated registration gate;
    # the product runtime path remains unchanged and is still started.
    Assert-True ($bootstrapSource -match "ValidateSet\('Interactive', 'S4U'\)") 'bootstrap exposes only the two known Scheduled Task logon types'
    Assert-True ($bootstrapSource -match '\$ProfileMatrixTestMode[\s\S]+requires ScheduledTaskLogonType S4U') 'bootstrap keeps its unused S4U test-mode guard fail closed'
    Assert-True ($bootstrapSource -match 'elseif \(\$ScheduledTaskLogonType -cne ''Interactive''\)') 'bootstrap rejects non-Interactive task principals outside profile-matrix test mode'
    Assert-True ($bootstrapSource -match 'New-ScheduledTaskPrincipal[\s\S]+-LogonType \$LogonType[\s\S]+-RunLevel Limited') 'bootstrap registers the validated task principal and retains least privilege'
    Assert-True ($bootstrapSource -match 'function Assert-CycCreationPathNoReparse' -and
        $bootstrapSource -match 'Assert-CycCreationPathNoReparse\s+-Path\s+\$directory' -and
        $bootstrapSource -match 'Assert-CycCreationPathNoReparse\s+-Path\s+\$parent') 'bootstrap checks every existing ancestor before creating private state or payload parents'
    Assert-True ($bootstrapSource -match 'taskLogonType\s*=\s*\$script:ScheduledTaskLogonType') 'bootstrap records the selected task principal in the install manifest'
    Assert-True ($bootstrapSource -match 'taskRuntime\s*=\s*\[ordered\]@') 'bootstrap records task runtime gating separately from the production logon type'
    Assert-True ($bootstrapSource -match 'parent-elevated-registration-v1[\s\S]+not-started') 'bootstrap has an explicit parent-elevated registration-only gate'
    Assert-True ($bootstrapSource -match 'ProfileMatrixTaskHelperMode[\s\S]+requires its explicit test switch') 'bootstrap requires an explicit helper-mode switch in addition to the IPC declaration'
    Assert-True ($bootstrapSource -match 'Invoke-CycProfileMatrixTaskGate[\s\S]+requestId') 'bootstrap binds gated task registration to a request/response exchange'
    Assert-True ($bootstrapSource -match 'accountSid\s*=\s*\[string\]\$identity\.User\.Value') 'bootstrap carries the immutable profile-matrix account SID beside the display name'
    Assert-True ($bootstrapSource -match "ValidateSet\('Register', 'Unregister', 'Restore'\)") 'bootstrap task gate includes a dedicated restore operation'
    Assert-True ($bootstrapSource -match 'cyc\.dev/windows-profile-matrix-task-request/v2') 'bootstrap restore requests use the versioned structured task IPC contract'
    Assert-True ($bootstrapSource -match 'windows-profile-matrix-task-helper/v1' -and
        $bootstrapSource -match 'observedTaskPath' -and
        $bootstrapSource -match 'observedPrincipalSid' -and
        $bootstrapSource -match 'observedTriggerSids') 'bootstrap cross-binds helper response schema and restored task identity'
    $restoreTaskFunction = [regex]::Match($bootstrapSource, 'function Restore-CycTaskSnapshots[\s\S]+?function Wait-CycTaskStable')
    Assert-True ($restoreTaskFunction.Success -and
        $restoreTaskFunction.Value -match 'Invoke-CycProfileMatrixTaskGate[\s\S]+-Operation Restore' -and
        $restoreTaskFunction.Value -match 'ProfileMatrixTaskGate' -and
        $restoreTaskFunction.Value -match 'wasRunning' -and
        $restoreTaskFunction.Value -match 'Validate') 'bootstrap rollback validates task snapshots before using the parent restore gate'
    $restoreGatePrefix = if ($restoreTaskFunction.Success) {
        $restoreTaskFunction.Value.Substring(0, $restoreTaskFunction.Value.IndexOf("if (`$script:ProfileMatrixTaskGate -ne 'none')", [StringComparison]::Ordinal))
    } else { '' }
    Assert-True ($restoreTaskFunction.Success -and
        $restoreTaskFunction.Value -match 'Register-ScheduledTask[\s\S]+-Xml' -and
        $restoreTaskFunction.Value -match 'Start-ScheduledTask' -and
        $restoreGatePrefix -notmatch 'Register-ScheduledTask[\s\S]+-Xml' -and
        $restoreGatePrefix -notmatch 'Start-ScheduledTask') 'bootstrap raw XML restore and task start remain production-only'
    $payloadEnumerator = [regex]::Match($bootstrapSource, 'function Get-PayloadFiles[\s\S]+?function Get-CycSha256Hex')
    Assert-True ($payloadEnumerator.Success -and $payloadEnumerator.Value -match 'Stack\[string\]' -and
        $payloadEnumerator.Value -match 'Get-ChildItem -LiteralPath \$current' -and
        $payloadEnumerator.Value -notmatch 'Get-ChildItem -LiteralPath \$bundle -Recurse') 'bootstrap walks payload directories without recursively following reparse points'
    $fileHashFunction = [regex]::Match($bootstrapSource, 'function Get-CycFileHash[\s\S]+?function ConvertTo-CycStrictRelativePath')
    Assert-True ($fileHashFunction.Success -and
        $fileHashFunction.Value -match 'SHA256\]::Create' -and
        $fileHashFunction.Value -match 'ComputeHash\(\$stream\)' -and
        $fileHashFunction.Value -match 'OpenRead\(\$LiteralPath\)') 'bootstrap hashes files through its module-independent streaming SHA-256 helper'
    Assert-True (([regex]::Matches($bootstrapSource, 'Get-CycFileHash\s+-LiteralPath')).Count -ge 6) 'bootstrap routes every file-integrity check through the streaming SHA-256 helper'
    foreach ($atomicName in @('Write-CycDurableAtomicBytes', 'Write-DurableAtomicJson')) {
        $atomicWriter = [regex]::Match($bootstrapSource, "function $atomicName[\s\S]+?function ")
        Assert-True ($atomicWriter.Success -and
            $atomicWriter.Value -match '\$backupStream\s*=\s*\[System\.IO\.FileStream\]::new' -and
            $atomicWriter.Value -match '\[System\.IO\.FileMode\]::CreateNew' -and
            $atomicWriter.Value -match '\$backupPrepared\s*=\s*\$true' -and
            $atomicWriter.Value -match '\[System\.IO\.File\]::Replace\(\$temporary,\s*\$Path,\s*\$backup' -and
            $atomicWriter.Value -match '\$operationError') "$atomicName pre-creates the backup and preserves the primary failure"
    }
    Assert-True ($bootstrapSource -match 'if \(\$script:ProfileMatrixTaskGate -eq ''none''\)[\s\S]+Start-ScheduledTask') 'bootstrap keeps task start on the normal production path only'
    Assert-True ($bootstrapSource -match 'enabled = \$true; logonType = \$script:ScheduledTaskLogonType') 'bootstrap binds enabled controller plan entries to the selected task principal'

    $nsis = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'ClusterYourCodex.nsi') -Raw
    Assert-True ($nsis -match 'RequestExecutionLevel user') 'Setup.exe remains in the initiating user token'
    Assert-True ($nsis -notmatch 'RequestExecutionLevel admin') 'Setup.exe never switches LOCALAPPDATA/HKCU to an over-the-shoulder admin'
    Assert-True ($nsis -match 'File /r "\$\{CYC_PACKAGE_ROOT\}\\\*\.\*"') 'Setup.exe embeds the complete self-contained package'
    Assert-True ($nsis -notmatch 'SetOutPath "\$PLUGINSDIR\\cyc-package"') 'Setup.exe never extracts the package beneath the long plugin-directory path'
    Assert-True ($nsis -match 'GetLogicalDrives') 'Setup.exe probes the current logical-drive mask before short-path mapping'
    Assert-True ($nsis -match '\.cyc-subst-owner') 'Setup.exe creates a private mapping-ownership sentinel'
    Assert-True ($nsis -match 'Call CycVerifyMappingOwnership[\s\S]+StrCpy \$CycMappingOwned "1"') 'Setup.exe verifies the sentinel before claiming a subst mapping'
    Assert-True ($nsis -match 'ClearErrors\s+SetOutPath "\$CycMappedDrive\\p"\s+IfErrors cyc_package_extraction_failed\s+ClearErrors\s+File /r[\s\S]+IfErrors') 'Setup.exe checks short output-path creation before checking package extraction'
    Assert-True ($nsis -match '-PackageRoot "\$CycMappedDrive\\p"') 'Setup.exe passes the short package root to lifecycle validation'
    Assert-True ($nsis -match 'Function CycCleanupShortStaging[\s\S]+SetOutPath "\$PLUGINSDIR"[\s\S]+CycVerifyMappingOwnership[\s\S]+subst\.exe[\s\S]+/D') 'Setup.exe leaves the mapped drive and revalidates ownership before detaching it'
    Assert-True ($nsis -match 'cyc_cleanup_package_failed:[\s\S]+CYC_RECORD_CLEANUP_FAILURE[\s\S]+Goto cyc_cleanup_done[\s\S]+cyc_cleanup_reverify_mapping:') 'Setup.exe retains its verified mapping when package cleanup fails so GUI-end cleanup can retry'
    Assert-True ($nsis -match 'IfFileExists "\$CycMappedDrive\\p" cyc_cleanup_package_failed') 'Setup.exe confirms the staged package root is absent before detaching its mapping'
    Assert-True ($nsis -match 'Function \.onGUIEnd[\s\S]+Call CycCleanupShortStaging') 'Setup.exe has an idempotent GUI-end cleanup backstop'
    Assert-True ($nsis -match 'CYC_MAX_PACKAGE_RELATIVE_PATH[\s\S]+exceeds the supported 190-character limit') 'Setup.exe compile fails closed when the package path budget is exceeded'
    Assert-True ($nsis -match 'Invoke-ClusterYourCodexLifecycle\.ps1[\s\S]+-PackageManifest ') 'Setup.exe invokes the coordinator and manifest validation gate'
    Assert-True ($nsis -match 'nsExec::ExecToStack[\s\S]+powershell\.exe" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden[\s\S]+Pop \$0[\s\S]+Pop \$1') 'silent Setup uses the hidden nsExec process boundary for the non-elevated lifecycle PowerShell console'
    Assert-True ($nsis -notmatch '(?m)^\s*ExecWait\s+') 'silent Setup does not use the NSIS ExecWait console path'
    Assert-True ($nsis -match 'StrCmp \$0 "error" cyc_lifecycle_launch_failed') 'silent Setup distinguishes nsExec launch failure from a lifecycle exit code'
    Assert-True ($lifecycleSource -match 'Start-Process[\s\S]+-Verb RunAs -WindowStyle Hidden -PassThru') 'firewall-only elevation hides its PowerShell console after UAC consent'
    Assert-True ($lifecycleSource -match ("'-WindowStyle',\s*'Hidden'[\s\S]+'-EncodedCommand',\s*" + [regex]::Escape('$encodedLoader'))) 'elevated firewall helper passes an explicit hidden host flag under ARM64 emulation'
    $lifecycleHashFunction = [regex]::Match($lifecycleSource, 'function Get-CycLifecycleSha256[\s\S]+?function Get-CycInitiatorBinding')
    Assert-True ($lifecycleHashFunction.Success -and
        $lifecycleHashFunction.Value -match 'SHA256\]::Create' -and
        $lifecycleHashFunction.Value -match 'ComputeHash\(\$stream\)' -and
        $lifecycleHashFunction.Value -match 'OpenRead\(\$Path\)') 'lifecycle coordinator hashes transaction files without PowerShell module auto-loading'
    $firewallHashFunction = [regex]::Match($firewallSource, 'function Get-CycFirewallSha256[\s\S]+?function Assert-CycFirewallExactProperties')
    Assert-True ($firewallHashFunction.Success -and
        $firewallHashFunction.Value -match 'SHA256\]::Create' -and
        $firewallHashFunction.Value -match 'ComputeHash\(\$stream\)' -and
        $firewallHashFunction.Value -match 'OpenRead\(\$Path\)') 'elevated firewall helper hashes receipts without PowerShell module auto-loading'
    Assert-True ($nsis -match 'SetErrorLevel \$0') 'Setup.exe preserves bootstrap failure status'
    Assert-True ($nsis -match 'MessageBox[\s\S]+/SD IDOK') 'silent Setup failure never blocks on an interactive message box'
    Assert-True ($nsis -match 'IfSilent silent_complete[\s\S]+Exec[\s\S]+silent_complete:') 'silent Setup success never launches the GUI'
    Assert-True ($nsis -notmatch '(?i)Bearer|authorization|--token\s') 'Setup.exe has no raw secret channel'
    $setupBuilder = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'New-SetupExecutable.ps1') -Raw
    Assert-True ($setupBuilder -match 'Assert-CycPackageManifest') 'Setup builder validates the staged payload before embedding it'
    Assert-True ($setupBuilder -match 'Get-AuthenticodeSignature') 'Setup builder reports the signing state honestly'
    Assert-True ($setupBuilder -match 'RequireRuntimeSignature') 'GA setup can enforce Authenticode at runtime after signing'
    Assert-True ($setupBuilder -match "Get-FileHash.+SHA256") 'Setup builder emits a SHA-256 sidecar'
    Assert-True ($setupBuilder -match 'candidateRoots[\s\S]+IsNullOrWhiteSpace') 'Setup builder tolerates a missing ProgramFiles(x86) environment variable'
    Assert-True ($setupBuilder -match 'SpecialFolder\]::ProgramFilesX86') 'Setup builder uses the OS Program Files x86 folder when environment variables are incomplete'
    Assert-True ($setupBuilder -match 'subst\.exe') 'Setup builder maps long package roots to a short NSIS source path'
    Assert-True ($setupBuilder -match 'maximumPackageRelativePath\s*=\s*190') 'Setup builder enforces the 190-character package-relative path budget'
    Assert-True ($setupBuilder -match 'Test-SetupPathEqualOrDescendant[\s\S]+must be outside') 'Setup builder rejects output/package overlap before source staging or deletion'
    Assert-True ($setupBuilder -match '/DCYC_MAX_PACKAGE_RELATIVE_PATH=\$\(\$packagePathMetrics\.longestRelativePathLength\)') 'Setup builder passes the measured package path budget into NSIS'
    Assert-True ($setupBuilder.IndexOf('$validationPackageRoot = $candidateRoot', [StringComparison]::Ordinal) -lt $setupBuilder.IndexOf('Assert-CycPackageManifest', [StringComparison]::Ordinal)) 'Setup builder establishes short source staging before manifest validation'
    Assert-True ($setupBuilder.IndexOf('if ($null -ne $primaryFailure)', [StringComparison]::Ordinal) -lt $setupBuilder.IndexOf('if ($null -ne $cleanupFailure)', [StringComparison]::Ordinal)) 'Setup builder preserves its primary failure ahead of subst cleanup failure'
    $freshDeploymentSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Test-FreshDeployment.ps1') -Raw
    $freshHashFunction = [regex]::Match($freshDeploymentSource, 'function Get-CycFileHash[\s\S]+?function Resolve-FreshPath')
    Assert-True ($freshHashFunction.Success -and
        $freshHashFunction.Value -match 'SHA256\]::Create' -and
        $freshHashFunction.Value -match 'ComputeHash\(\$stream\)' -and
        $freshHashFunction.Value -match 'OpenRead\(\$LiteralPath\)') 'fresh deployment smoke hashes files without relying on Windows PowerShell module auto-loading'
    Assert-True (([regex]::Matches($freshDeploymentSource, '(?m)^\s*(?!#).*Get-CycFileHash\s+-LiteralPath')).Count -ge 4) 'fresh deployment smoke routes every file-integrity check through the streaming SHA-256 helper'
    Assert-True ($freshDeploymentSource -match 'function Read-FreshUtf8Json' -and
        $freshDeploymentSource -match '\[System\.IO\.File\]::ReadAllBytes' -and
        $freshDeploymentSource -match 'UTF8Encoding' -and
        $freshDeploymentSource -notmatch 'Get-Content[^\r\n]+ConvertFrom-Json') 'fresh deployment smoke decodes package/install manifests as strict UTF-8 instead of the Windows PowerShell ANSI default'
    Assert-True ($freshDeploymentSource -match 'function ConvertTo-FreshNativeArgument' -and
        $freshDeploymentSource -match 'function Invoke-FreshPowerShell' -and
        $freshDeploymentSource -match 'WaitForExit\(100\)' -and
        $freshDeploymentSource -match 'taskkill\.exe' -and
        $freshDeploymentSource -match 'timed out after \$TimeoutSeconds') 'fresh deployment lifecycle children have bounded process-tree termination'
    Assert-True ($freshDeploymentSource -match 'LifecycleTimeoutSeconds' -and
        ([regex]::Matches($freshDeploymentSource, 'TimeoutSeconds \$LifecycleTimeoutSeconds')).Count -ge 5) 'fresh deployment applies the bounded lifecycle timeout to plan/install/repair/uninstall/cleanup'
    Assert-True (-not $freshDeploymentSource.Contains("'-Confirm:`$false'")) 'fresh deployment smoke never serializes a false SwitchParameter through powershell.exe -File'
    Assert-True ($freshDeploymentSource -match "'-NoLogo', '-NoProfile', '-NonInteractive'") 'fresh deployment smoke launches a clean non-interactive Windows PowerShell child'
    Assert-True ($freshDeploymentSource -match "'-WorkerConfig',\s+\`$workerConfig") 'fresh deployment smoke keeps the worker config beneath its isolated data root'
    Assert-True (-not $freshDeploymentSource.Contains("'-PurgeData'")) 'fresh deployment smoke preserves isolated product data before harness-owned cleanup'
    Assert-True ($freshDeploymentSource -match 'Remove-FreshOwnedIsolationRoot') 'fresh deployment smoke cleans only its validated harness-owned isolation root'
    Assert-True ($freshDeploymentSource -match 'Remove-FreshOwnedWorkRoot[\s\S]+reparse point') 'fresh deployment work-root cleanup rejects nested reparse points'
    Assert-True ($freshDeploymentSource -match 'Wait-FreshFileUnlocked[\s\S]+FileShare\]::None') 'fresh deployment waits for transient executable handles before repair mutation'
    Assert-True ($freshDeploymentSource -match 'repair precondition corrupts the installed CLI[\s\S]+repair restores the exact packaged CLI bytes') 'fresh deployment Repair restores a deliberately corrupted production file'
    Assert-True ($freshDeploymentSource -match "'ClusterYourCodex Controller', 'ClusterYourCodex Worker'") 'fresh deployment smoke protects both fixed product task names'
    Assert-True ($freshDeploymentSource -match "ValidateSet\('Interactive', 'S4U'\)") 'fresh deployment smoke exposes only the two known Scheduled Task logon types'
    Assert-True ($freshDeploymentSource -match '\$ProfileMatrixTestMode[\s\S]+requires ScheduledTaskLogonType S4U') 'fresh deployment smoke keeps its S4U test-mode guard fail closed'
    Assert-True ($freshDeploymentSource -match '-not \$ProfileMatrixTestMode[\s\S]+-cne ''Interactive''') 'fresh deployment smoke rejects S4U outside profile-matrix test mode'
    Assert-True ($freshDeploymentSource -match '\$common\s*\+=\s*@\([\s\S]+-ProfileMatrixTestMode[\s\S]+-ScheduledTaskLogonType') 'fresh deployment smoke forwards explicit test-mode flags only when requested'
    Assert-True ($freshDeploymentSource -match 'ProfileMatrixTaskHelperMode[\s\S]+\$common\s*\+=\s*''-ProfileMatrixTaskHelperMode''') 'fresh deployment smoke forwards the explicit parent-helper switch only when requested'
    Assert-True ($freshDeploymentSource -match '\$uninstallArguments[\s\S]+ProfileMatrixTaskHelperMode[\s\S]+\$uninstallArguments\s*\+=\s*''-ProfileMatrixTaskHelperMode''') 'fresh deployment smoke forwards the parent-helper switch during uninstall'
    Assert-True ($freshDeploymentSource -match '\$cleanupArguments[\s\S]+ProfileMatrixTaskHelperMode[\s\S]+\$cleanupArguments\s*\+=\s*''-ProfileMatrixTaskHelperMode''') 'fresh deployment smoke forwards the parent-helper switch during failure cleanup'
    Assert-True ($freshDeploymentSource -match 'expectedTaskLogonType\s*=\s*if\s*\(\$ProfileMatrixTestMode\)[\s\S]+S4U[\s\S]+Interactive') 'fresh deployment smoke verifies S4U only for profile-matrix and Interactive otherwise'
    Assert-True ($freshDeploymentSource -match 'Assert-FreshTaskPrincipal') 'fresh deployment smoke verifies the persisted Scheduled Task principal after install and repair'
    Assert-True ($freshDeploymentSource -match 'fresh deployment runner starts without pre-existing product tasks') 'fresh deployment smoke fails closed around pre-existing product tasks'
    Assert-True ($freshDeploymentSource -match 'New-FreshIsolationOwnerMarker[\s\S]+cyc\.dev/fresh-deployment-owner/v1') 'fresh deployment smoke creates a schema-bound owner marker before using its isolated root'
    Assert-True ($freshDeploymentSource -match '\$isolatedRootExistedAtStart[\s\S]+did not exist before this harness run') 'fresh deployment smoke rejects a pre-existing isolated root before any lifecycle mutation'
    Assert-True ($freshDeploymentSource -match 'Assert-FreshIsolationOwnerMarker[\s\S]+Remove-FreshOwnedIsolationRoot') 'fresh deployment cleanup validates the owner marker before recursive root removal'
    $freshMarkerFunction = [regex]::Match($freshDeploymentSource, 'function New-FreshIsolationOwnerMarker[\s\S]+?function Assert-FreshIsolationOwnerMarker')
    Assert-True ($freshMarkerFunction.Success -and
        $freshMarkerFunction.Value -match '\$rootCreated\s*=\s*\$false' -and
        $freshMarkerFunction.Value -match 'catch\s*\{' -and
        $freshMarkerFunction.Value -match 'Remove-Item -LiteralPath \$markerPath' -and
        $freshMarkerFunction.Value -match 'Preserve the marker/ownership failure') 'fresh deployment owner-marker creation has bounded failure cleanup without masking the primary error'
    Assert-True ($freshDeploymentSource -match 'Get-ScheduledTask[\s\S]+-TaskPath ''\\''') 'fresh deployment task inventory is scoped to the root Task Scheduler path'
    Assert-True ($freshDeploymentSource -match 'Get-FreshLifecycleState[\s\S]+lifecycleOwned') 'fresh deployment cleanup derives ownership from observed lifecycle state'
    Assert-True ($freshDeploymentSource -match '\$installAttempted\s*=\s*\$true[\s\S]+\$installed\s*=\s*\$true[\s\S]+Invoke-FreshPowerShell[\s\S]+-Label ''install''') 'fresh deployment arms failure cleanup before invoking the install child'
    Assert-True ($freshDeploymentSource -match '\$uninstallAttempted\s*=\s*\$true[\s\S]+Assert-FreshLifecycleAbsent[\s\S]+\$uninstalled\s*=\s*\$true') 'fresh deployment marks uninstall complete only after lifecycle postconditions pass'
    Assert-True ($freshDeploymentSource -match 'failure cleanup[\s\S]+final lifecycle postcondition') 'fresh deployment verifies cleanup postconditions before and after owned-root removal'
    $preRootCheckIndex = $freshDeploymentSource.IndexOf("Label = 'pre-root-removal lifecycle'", [StringComparison]::Ordinal)
    $ownedRootRemovalIndex = $freshDeploymentSource.IndexOf('Remove-FreshOwnedIsolationRoot -Root', [StringComparison]::Ordinal)
    Assert-True ($preRootCheckIndex -ge 0 -and $ownedRootRemovalIndex -gt $preRootCheckIndex) 'fresh deployment proves lifecycle absence before deleting the synthetic root'
    $setupSilentSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Test-SetupSilent.ps1') -Raw
    $setupSilentHashFunction = [regex]::Match($setupSilentSource, 'function Get-CycFileHash[\s\S]+?function Test-SetupSilentPrivateLanAddress')
    Assert-True ($setupSilentHashFunction.Success -and
        $setupSilentHashFunction.Value -match 'SHA256\]::Create' -and
        $setupSilentHashFunction.Value -match 'ComputeHash\(\$stream\)' -and
        $setupSilentHashFunction.Value -match 'OpenRead\(\$LiteralPath\)') 'silent Setup smoke hashes files without relying on Windows PowerShell module auto-loading'
    Assert-True (([regex]::Matches($setupSilentSource, '(?m)^\s*(?!#).*Get-CycFileHash\s+-LiteralPath')).Count -ge 13) 'silent Setup smoke routes every file-integrity check through the streaming SHA-256 helper'
    Assert-True ($setupSilentSource -match 'MaximumInstallManifestBytes\s*=\s*16MB') 'silent Setup smoke accepts the bounded self-contained install manifest size'
    Assert-True ($setupSilentSource -match 'ConvertTo-SetupSilentSid') 'silent Setup canonicalizes Scheduled Task identities to SIDs'
    Assert-True ($setupSilentSource -match 'Export-ScheduledTask[\s\S]+Assert-SetupSilentTaskIdentityXml') 'silent Setup verifies the persisted Scheduled Task identity definition'
    Assert-True ($setupSilentSource -match 'LogonTrigger[\s\S]+triggerSid') 'silent Setup binds the logon trigger to the initiating SID'
    Assert-True ($setupSilentSource -notmatch '\$principalMatches|ExpectedIdentity') 'silent Setup never authorizes a Scheduled Task by raw account-name equality'
    Assert-True ($setupSilentSource -match 'NTAccount\(\$IdentityText\)[\s\S]+Translate\(\[System\.Security\.Principal\.SecurityIdentifier\]\)') 'silent Setup translates account-name representations to a canonical SID'
    Assert-True ($setupSilentSource -match 'StartsWith\(''S-''[\s\S]+SecurityIdentifier\(\$IdentityText\)') 'silent Setup validates SID-looking values without an account-name fallback'
    Assert-True ($setupSilentSource -match 'taskNamespace\s*=\s*''http://schemas\.microsoft\.com/windows/2004/02/mit/task''') 'silent Setup accepts only the Task Scheduler XML namespace'
    Assert-True ($setupSilentSource -match 'foreignElements\.Count\s+-ne\s+0') 'silent Setup rejects elements from foreign XML namespaces'
    Assert-True ($setupSilentSource -match 'principalElements\[0\]\.NamespaceURI\s+-cne\s+\$taskNamespace') 'silent Setup requires the sole principal to use the Task Scheduler namespace'
    Assert-True ($setupSilentSource -match 'triggerElements\[0\]\.NamespaceURI\s+-cne\s+\$taskNamespace') 'silent Setup requires the sole logon trigger to use the Task Scheduler namespace'
    Assert-True ($setupSilentSource -match 'principalElements\.Count\s+-ne\s+1[\s\S]+principalGroupIds\.Count\s+-ne\s+0') 'silent Setup rejects missing, duplicate, or group principals'
    Assert-True ($setupSilentSource -match 'triggerElements\.Count\s+-ne\s+1[\s\S]+LogonTrigger[\s\S]+triggerUserIds\.Count\s+-ne\s+1') 'silent Setup requires one account-bound logon trigger'
    Assert-True ($setupSilentSource -match 'Invoke-SetupSilentTaskIdentityContractSelfTest[\s\S]+foreign-namespace principal sibling[\s\S]+foreign-namespace logon trigger') 'silent Setup executes positive and foreign-namespace identity fixtures before installation'
    Assert-True ($setupSilentSource -match 'Get-ScheduledTask[\s\S]+-TaskPath ''\\''[\s\S]+Export-ScheduledTask[\s\S]+-TaskPath ''\\''') 'silent Setup scopes task identity checks to the root task path'
    Assert-True ($setupSilentSource -match 'operations\s*=\s*\$operations\.ToArray\(\)') 'silent Setup materializes its generic operation list before result serialization on Windows PowerShell 5.1'
    Assert-True ($setupSilentSource -notmatch 'operations\s*=\s*@\(\$operations\)') 'silent Setup avoids the Windows PowerShell 5.1 generic-list array-subexpression binder failure'
    $operationListCompatibilityProbe = New-Object System.Collections.Generic.List[object]
    [void]$operationListCompatibilityProbe.Add([PSCustomObject]@{ label = 'probe'; exitCode = 0 })
    $operationResultCompatibilityProbe = [PSCustomObject]@{
        operations = $operationListCompatibilityProbe.ToArray()
    }
    Assert-True (@($operationResultCompatibilityProbe.operations).Count -eq 1) 'generic operation list materializes into one result entry'
    Assert-True ([string]$operationResultCompatibilityProbe.operations[0].label -ceq 'probe') 'materialized generic operation result preserves its fields'
    $genericListProbeSource = @'
$ErrorActionPreference = 'Stop'
foreach ($expectedCount in @(0, 1, 2)) {
    $operations = New-Object System.Collections.Generic.List[object]
    for ($index = 0; $index -lt $expectedCount; $index++) {
        [void]$operations.Add([PSCustomObject]@{
            index = $index
            label = "operation-$index"
        })
    }
    $result = [PSCustomObject]@{
        operations = $operations.ToArray()
    }
    if (-not ($result.operations -is [object[]])) {
        throw "operations is not Object[] for count $expectedCount"
    }
    if ($result.operations.Count -ne $expectedCount) {
        throw "operations count changed for count $expectedCount"
    }
    for ($index = 0; $index -lt $expectedCount; $index++) {
        if ([int]$result.operations[$index].index -ne $index) {
            throw "operations order changed at index $index"
        }
    }
    $json = $result | ConvertTo-Json -Depth 4 -Compress
    if ($expectedCount -eq 0 -and $json -notmatch '"operations":\[\]') {
        throw 'empty operations did not remain a JSON array'
    }
    if ($expectedCount -gt 0 -and $json -notmatch '"operations":\[') {
        throw "non-empty operations did not remain a JSON array for count $expectedCount"
    }
}
exit 0
'@
    $genericListProbeEncoded = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($genericListProbeSource)
    )
    $genericListProbe = Start-Process `
        -FilePath $windowsPowerShell `
        -ArgumentList @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-EncodedCommand', $genericListProbeEncoded
        ) `
        -WorkingDirectory $testRoot `
        -WindowStyle Hidden `
        -Wait `
        -PassThru
    Assert-True ($genericListProbe.ExitCode -eq 0) 'Windows PowerShell 5.1 materializes the silent Setup operation list as a stable Object array'
    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $currentIdentityName = [string]$currentIdentity.Name
    $currentIdentitySid = [string]$currentIdentity.User.Value
    $qualifiedSid = (New-Object System.Security.Principal.NTAccount($currentIdentityName)).Translate(
        [System.Security.Principal.SecurityIdentifier]
    ).Value
    Assert-True ([string]$qualifiedSid -ceq $currentIdentitySid) 'Windows resolves the initiating qualified account to its canonical SID'
    $identityParts = @($currentIdentityName -split '\\', 2)
    if ($identityParts.Count -eq 2 -and
        [string]::Equals($identityParts[0], $env:COMPUTERNAME, [System.StringComparison]::OrdinalIgnoreCase)) {
        $bareSid = (New-Object System.Security.Principal.NTAccount($identityParts[1])).Translate(
            [System.Security.Principal.SecurityIdentifier]
        ).Value
        Assert-True ([string]$bareSid -ceq $currentIdentitySid) 'Windows resolves the bare local account representation returned by ScheduledTasks CIM'
    }
    Assert-True ($setupSilentSource -notmatch '(?<!@)\(Get-SetupSilent(?:TaskSnapshot|FirewallSnapshot|Listeners|ProductProcesses)\)\.Count') 'silent Setup smoke array-wraps zero-or-one item function output before Count'
    Assert-True ($setupSilentSource -match "Get-Process -Name @\('ClusterYourCodex', 'cyc', 'cyc-controller', 'cyc-worker'\)") 'silent Setup smoke inventories and reaps the cyc.exe CLI process by its Windows ProcessName'
    Assert-True ($setupSilentSource -match 'Invoke-SetupSilentProbes[\s\S]+Stop-SetupSilentOwnedProcesses[\s\S]+before Repair tamper') 'silent Setup smoke reaps probe processes before mutating the installed CLI'
    Assert-True ($setupSilentSource -match 'Get-ScheduledTask[\s\S]+Stop-ScheduledTask[\s\S]+installPrefix') 'silent Setup smoke stops only disposable install owned Scheduled Tasks before reaping processes'
    Assert-True ($setupSilentSource -match 'Re-enumerate after every termination[\s\S]+deadline[\s\S]+AddSeconds\(20\)') 'silent Setup smoke closes the Scheduled Task restart race with bounded process re-enumeration'
    Assert-True ($setupSilentSource -match 'EnvironmentVariables[\s\S]+CYC_SETUP_DIAGNOSTIC_LOG') 'silent Setup smoke injects the structured lifecycle diagnostic path into Setup.exe'
    Assert-True ($setupSilentSource -match 'Read-SetupSilentJson[\s\S]+ReadAllBytes[\s\S]+UTF8Encoding\(\$false,\s*\$true\)') 'silent Setup reads lifecycle diagnostics as strict UTF-8 independently of the Windows ANSI code page'
    Assert-True ($setupSilentSource -match 'Read-SetupSilentJson[\s\S]+\$offset[\s\S]+0xEF[\s\S]+0xBB[\s\S]+0xBF') 'silent Setup accepts both BOM-bearing and BOM-less strict UTF-8 JSON'
    Assert-True ($setupSilentSource -match 'primaryFailure\s*=\s*if\s*\(\$primaryFailure\)') 'silent Setup cleanup receipt preserves the primary failure independently of cleanup'
    Assert-True ($setupSilentSource.IndexOf('if ($primaryFailure) { throw $primaryFailure }', [StringComparison]::Ordinal) -lt $setupSilentSource.IndexOf('if ($cleanupFailures.Count -gt 0)', [StringComparison]::Ordinal)) 'silent Setup preserves the primary lifecycle exception ahead of secondary cleanup failures'
    Assert-True ($setupSilentSource -match 'CYC_DISPOSABLE_WINDOWS') 'silent Setup smoke requires an explicit disposable-environment sentinel'
    Assert-True ($setupSilentSource -match '\[string\]\$PackageRoot') 'silent Setup smoke binds Repair to the matching staged package'
    Assert-True ($setupSilentSource -match "ArgumentList\s+@?\('?'/S") 'silent Setup smoke executes the real case-sensitive NSIS /S path'
    Assert-True ($setupSilentSource -match 'does not launch the GUI') 'silent Setup smoke rejects an unexpected GUI launch'
    Assert-True ($setupSilentSource -match 'AssertNoNewVisiblePowerShellWindow') 'silent Setup smoke polls for transient PowerShell consoles while Setup is running'
    Assert-True ($setupSilentSource -match 'Get-CimInstance[\s\S]+ParentProcessId[\s\S]+windowClass') 'silent Setup records executable, command-line, parent, and window-class evidence for a visible PowerShell regression'
    Assert-True ($setupSilentSource -match 'Assert-SetupSilentTreeHasNoReparsePoints') 'silent Setup cleanup rejects nested reparse points before recursive deletion'
    Assert-True ($setupSilentSource -match 'Action.+Repair|''Repair''') 'silent Setup smoke exercises Repair after installation'
    Assert-True ($setupSilentSource -match 'installed uninstaller|Uninstall-ClusterYourCodex\.ps1') 'silent Setup smoke invokes the installed uninstaller'
    Assert-True ($setupSilentSource -match 'restores the pre-test Scheduled Task state') 'silent Setup smoke verifies Scheduled Task restoration'
    Assert-True ($setupSilentSource -match 'restores the pre-test firewall state') 'silent Setup smoke verifies firewall restoration'
    $releaseWorkflow = Get-Content -LiteralPath (Join-Path $repoRoot '.github\workflows\release.yml') -Raw
    Assert-True (([regex]::Matches($releaseWorkflow, 'name:\s*Test full Rust workspace')).Count -eq 2) 'release runs the native workspace suite in the platform matrix and self-contained Windows job without a redundant integration-bundle copy'
    Assert-True ($releaseWorkflow -match 'Get-Command\s+-Name [\x27\x22]makensis\.exe[\x27\x22].+CommandType Application') 'release workflow resolves the NSIS compiler through the runner command table'
    Assert-True ($releaseWorkflow -match 'NSIS\\Bin\\makensis\.exe') 'release workflow accepts the NSIS Bin compiler layout'
    Assert-True ($releaseWorkflow -match 'lib\\nsis\\tools\\makensis\.exe') 'release workflow accepts the Chocolatey NSIS tools layout'
    Assert-True ($releaseWorkflow -match 'lib\\nsis\.install\\tools\\makensis\.exe') 'release workflow accepts the Chocolatey nsis.install tools layout'
    Assert-True ($releaseWorkflow -match 'NSIS installation completed but makensis\.exe was not found') 'release workflow validates its resolved NSIS compiler path'
    Assert-True ($releaseWorkflow -match 'New-SetupExecutable\.ps1[\s\S]+-MakeNsisPath \$makeNsis') 'release workflow passes the resolved NSIS compiler into Setup.exe staging'
    Assert-True ($releaseWorkflow -match 'ZipFileExtensions\]::CreateEntryFromFile') 'release ZIP creation explicitly includes forced and hidden files instead of Compress-Archive omission semantics'
    Assert-True ($releaseWorkflow -match 'Expand-Archive[\s\S]+Get-CycArchiveInventory[\s\S]+exact forced/hidden package tree') 'release expands the final ZIP and compares its exact tree and bytes with staging'
    Assert-True ($releaseWorkflow -match 'integration archive file count mismatch') 'integration preview ZIP validates its complete extracted file tree'
    Assert-True ($releaseWorkflow -match 'integration archive tree/bytes mismatch') 'integration preview ZIP validates extracted file bytes'
    Assert-True ($releaseWorkflow -match 'integration archive is missing required hidden entry') 'integration preview ZIP retains hidden Codex marketplace/plugin entries'
    Assert-True ($releaseWorkflow -match 'provenance-subjects/\*') 'release provenance attests the immutable payload set before metadata finalization'
    Assert-True ($releaseWorkflow -match 'bundleSha256 = \$bundleHash') 'release index records the exact attestation bundle digest'
    Assert-True ($releaseWorkflow -match 'clusteryourcodex-post-archive-[\s\S]+NewGuid') 'post-archive smoke uses a fresh GUID extraction root instead of recursively deleting a fixed runner path'
    Assert-True ($releaseWorkflow -match 'Test-FreshDeployment\.ps1[\s\S]+-PackageRoot \$extractedPackage') 'fresh deployment smoke runs against the just-created ZIP after extraction'
    Assert-True ($releaseWorkflow -match 'windows11-acceptance:[\s\S]+timeout-minutes:\s*120') 'ARM64 acceptance job has a finite hosted-runner timeout'
    Assert-True ($releaseWorkflow -match 'Test-FreshDeployment\.ps1[\s\S]+-LifecycleTimeoutSeconds\s+900') 'ARM64 fresh-deployment smoke receives an explicit bounded child timeout'
    Assert-True ($releaseWorkflow -match 'Test-SetupSilent\.ps1[\s\S]+-LifecycleTimeoutSeconds\s+900') 'ARM64 silent Setup smoke receives an explicit bounded child timeout'
    Assert-True ($releaseWorkflow -match 'Test-WindowsProfileMatrix\.ps1[\s\S]+-ChildTimeoutSeconds\s+900') 'ARM64 profile matrix receives an explicit bounded child timeout'
    Assert-True ($releaseWorkflow -match 'Test-FreshDeployment\.ps1[\s\S]+-WorkRoot \$freshWorkRoot[\s\S]+-KeepWorkRoot') 'fresh deployment smoke retains a job-owned diagnostic work root'
    Assert-True ($releaseWorkflow -match 'Upload fresh deployment diagnostics[\s\S]+if: always\(\)') 'fresh deployment diagnostics upload runs even when the lifecycle smoke fails'
    Assert-True ($releaseWorkflow -match 'CYC_DISPOSABLE_WINDOWS:[\s\S]+Test-SetupSilent\.ps1[\s\S]+-PackageRoot \$preview[\s\S]+-DisposableEnvironment') 'release workflow runs silent Setup only inside the disposable Windows runner'
    Assert-True ($releaseWorkflow -match 'Upload silent Setup diagnostics[\s\S]+if: always\(\)') 'release workflow retains silent Setup diagnostics on success and failure'
    Assert-True (([regex]::Matches($releaseWorkflow, 'pnpm --filter @clusteryourcodex/codex-mcp deploy')).Count -eq 2) 'release builds exactly two MCP deployment artifacts'
    Assert-True (([regex]::Matches($releaseWorkflow, '--config\.node-linker=hoisted')).Count -eq 2) 'both release MCP deployments use a flat hoisted dependency layout'
    Assert-True (([regex]::Matches($releaseWorkflow, '--config\.inject-workspace-packages=true')).Count -eq 2) 'both release MCP deployments use modern injected workspace packages'
    Assert-True (([regex]::Matches($releaseWorkflow, 'codex-mcp deploy[^\r\n]*--frozen-lockfile')).Count -eq 2) 'both release MCP deployments are bound to the committed lockfile'
    Assert-True (-not [regex]::IsMatch($releaseWorkflow, 'codex-mcp deploy[^\r\n]*--legacy')) 'release never uses the legacy pnpm deploy path'
    Assert-True (([regex]::Matches($releaseWorkflow, "node_modules\\\.pnpm'")).Count -eq 2) 'both release MCP deployments explicitly remove bounded pnpm metadata before staging'
    Assert-True (([regex]::Matches($releaseWorkflow, 'node packaging/windows/Test-McpDeployment\.mjs \$mcpDeploy')).Count -eq 2) 'both release MCP deployments pass a real initialize and tools/list smoke test'
    $mcpDeploymentSmoke = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Test-McpDeployment.mjs') -Raw
    Assert-True ($mcpDeploymentSmoke -match 'CYC_MCP_SELF_TEST:\s*"1"[\s\S]+NODE_OPTIONS:\s*""[\s\S]+NODE_PATH:\s*""') 'MCP deployment smoke isolates runtime resolution and receipt state'
    Assert-True ($mcpDeploymentSmoke -match '"initialize"[\s\S]+notifications/initialized[\s\S]+"tools/list"') 'MCP deployment smoke performs the complete protocol handshake'
    Assert-True ($mcpDeploymentSmoke -match 'EXPECTED_TOOLS') 'MCP deployment smoke checks the exact public tool surface'
    Assert-True ($mcpDeploymentSmoke -match 'STABILITY_WINDOW_MS[\s\S]+unexpectedTermination[\s\S]+child\.exitCode') 'MCP deployment smoke rejects a server that exits after returning expected responses'
    Assert-True ($mcpDeploymentSmoke.IndexOf('await stopChild();', [StringComparison]::Ordinal) -lt $mcpDeploymentSmoke.IndexOf('process.stdout.write(`${JSON.stringify(smokeResult)}', [StringComparison]::Ordinal)) 'MCP deployment smoke reports success only after lifecycle and shutdown checks pass'

    # The Windows profile/path acceptance harness is intentionally split into a
    # controller and a per-user child. Keep a static contract here so the
    # release workflow cannot silently drop the four-case matrix while the live
    # test remains reserved for a clean disposable Windows runner.
    $profileMatrix = Join-Path $PSScriptRoot 'Test-WindowsProfileMatrix.ps1'
    $profileMatrixChild = Join-Path $PSScriptRoot 'Test-WindowsProfileMatrixChild.ps1'
    Assert-True (Test-Path -LiteralPath $profileMatrix -PathType Leaf) 'Windows profile matrix controller exists'
    Assert-True (Test-Path -LiteralPath $profileMatrixChild -PathType Leaf) 'Windows profile matrix child exists'
    foreach ($profileScript in @($profileMatrix, $profileMatrixChild)) {
        $parseTokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $profileScript,
            [ref]$parseTokens,
            [ref]$parseErrors
        )
        Assert-True (@($parseErrors).Count -eq 0) "profile matrix script parses: $([System.IO.Path]::GetFileName($profileScript))"
    }
    $profileMatrixSource = Get-Content -LiteralPath $profileMatrix -Raw
    $profileMatrixChildSource = Get-Content -LiteralPath $profileMatrixChild -Raw
    Assert-True ($profileMatrixSource -match 'function Read-ProfileMatrixUtf8Json' -and
        $profileMatrixSource -match '\[System\.IO\.File\]::ReadAllBytes' -and
        $profileMatrixSource -match 'UTF8Encoding' -and
        $profileMatrixSource -notmatch 'Get-Content[^\r\n]+ConvertFrom-Json') 'profile matrix decodes every file-backed JSON boundary as strict UTF-8 instead of the Windows PowerShell ANSI default'
    Assert-True ($bootstrapSource -match 'function Read-CycUtf8Json' -and
        $bootstrapSource -match '\[System\.IO\.File\]::ReadAllBytes' -and
        $bootstrapSource -match 'UTF8Encoding' -and
        $bootstrapSource -notmatch 'Get-Content[^\r\n]+ConvertFrom-Json') 'bootstrap decodes durable and profile-matrix JSON as strict UTF-8 instead of the Windows PowerShell ANSI default'
    foreach ($case in @('standard-ascii', 'administrator-ascii', 'standard-non-ascii', 'administrator-non-ascii')) {
        Assert-True ($profileMatrixSource -match [regex]::Escape($case)) "profile matrix declares $case"
    }
    Assert-True ($profileMatrixSource -match '\$normalizedCaseNames' -and $profileMatrixSource -match '-split') 'profile matrix normalizes comma-separated CaseName values before strict validation'
    Assert-True ($releaseWorkflow -match "-CaseName '[^']*,[^']*,[^']*,[^']*'") 'release workflow passes profile matrix cases as one quoted comma-separated Windows PowerShell argument'
    Assert-True ($profileMatrixSource -match 'New-LocalUser') 'profile matrix creates disposable local users without shelling a password through argv'
    Assert-True ($profileMatrixSource -match 'Start-Process[\s\S]+Credential[\s\S]+LoadUserProfile') 'profile matrix launches each child with a loaded user profile'
    Assert-True ($profileMatrixSource -match 'ChildTimeoutSeconds' -and
        $profileMatrixSource -match 'WaitForExit\(100\)' -and
        $profileMatrixSource -match 'taskkill\.exe' -and
        $profileMatrixSource -match 'child timed out after \$ChildTimeoutSeconds') 'profile matrix child lifetimes have bounded process-tree termination'
    Assert-True ($profileMatrixSource -notmatch '@\(& \$windowsPowerShell \@childArguments') 'profile matrix current-user mode does not use an unbounded synchronous child invocation'
    Assert-True ($profileMatrixSource -match 'Add-LocalGroupMember') 'profile matrix exercises an administrator account'
    Assert-True ($profileMatrixSource -match 'Remove-LocalUser') 'profile matrix removes disposable local users'
    Assert-True ($profileMatrixSource -match 'Win32_UserProfile') 'profile matrix removes created user profiles by SID'
    Assert-True ($profileMatrixSource -match 'ProfileList\\' -and
        $profileMatrixSource -match 'ProfileImagePath' -and
        $profileMatrixSource -match 'Get-ProfileMatrixProfilePathForSid') 'profile matrix resolves Unicode profile paths from the SID-bound ProfileList registry before CIM fallback'
    Assert-True ($profileMatrixSource -match 'robocopy') 'profile matrix stages a private package copy for alternate users'
    Assert-True ($profileMatrixSource -match 'Test-ProfileMatrixKnownCompatibilityJunction') 'profile matrix recognizes only the OS-created profile compatibility junctions'
    Assert-True ($profileMatrixSource -match 'Normalize-ProfileMatrixLinkTarget' -and
        $profileMatrixSource -match 'ResolvedTarget' -and
        $profileMatrixSource -match 'LinkTarget') 'profile matrix normalizes all PowerShell link-target projections'
    Assert-True ($profileMatrixSource -match '\\\?\?\\' -and
        $profileMatrixSource -match 'DosDevices') 'profile matrix normalizes NT/Win32 junction target prefixes'
    Assert-True ($profileMatrixSource -match 'AllowKnownCompatibilityJunctions') 'profile matrix scopes compatibility-junction allowance to the disposable profile cleanup path'
    Assert-True ($profileMatrixSource -match 'Remove-ProfileMatrixKnownCompatibilityJunctions') 'profile matrix removes known compatibility junctions before recursive profile cleanup'
    Assert-True ($profileMatrixSource -match "'Application Data'" -and $profileMatrixSource -match "'Documents\\My Music'" -and
        $profileMatrixSource -match "'AppData\\Local\\Application Data'" -and
        $profileMatrixSource -match "'AppData\\LocalLow\\Application Data'" -and
        $profileMatrixSource -match "'AppData\\Roaming\\Application Data'" -and
        $profileMatrixSource -match "'AppData\\Local\\History'") 'profile matrix names the legacy, nested local, roaming, History, and Documents compatibility junction allow-list explicitly'
    Assert-True ($profileMatrixSource -match '\$knownTargets' -and $profileMatrixSource -match 'LinkType') 'profile matrix validates compatibility-junction targets instead of allowing arbitrary reparse points'
    Assert-True ($profileMatrixSource -match 'ConvertFrom-ProfileMatrixFsutilReparseOutput') 'profile matrix has a deterministic native fsutil reparse transcript parser'
    Assert-True ($profileMatrixSource -match 'Get-ProfileMatrixNativeReparseInfo[\s\S]+fsutil\.exe[\s\S]+reparsepoint query') 'profile matrix uses the native fsutil fallback when PowerShell link metadata is absent'
    Assert-True ($profileMatrixSource -match 'a0000003') 'profile matrix accepts only the Windows mount-point junction reparse tag'
    Assert-True ($profileMatrixSource -match '(?i)GLOBALROOT[\\/]|\\bDevice[\\/]|Volume\\{|UNC[\\/]') 'profile matrix rejects device, volume, GLOBALROOT, and UNC reparse targets'
    Assert-True ($profileMatrixSource -match 'tagMatches\.Count -ne 1[\s\S]+uniqueTargets\.Count -ne 1') 'profile matrix rejects ambiguous or malformed native reparse metadata'
    Assert-True ($profileMatrixSource -match 'invalidTargetProjection[\s\S]+return \$false') 'profile matrix rejects malformed link projections instead of ignoring them'
    Assert-True ($profileMatrixSource -match 'IPC path escaped its case root' -and $profileMatrixSource -match 'IPC path is a reparse point') 'profile matrix confines elevated-helper IPC to the case root without following links'
    Assert-True ($profileMatrixSource -match 'cyc\.dev/windows-profile-matrix-task-request/v2' -and
        $profileMatrixSource -match 'cyc\.dev/windows-profile-matrix-task-snapshot/v1' -and
        $profileMatrixSource -match "operation -notin @\('Register', 'Unregister', 'Restore'\)") 'profile matrix parent helper validates the structured restore operation contract'
    Assert-True ($profileMatrixSource -match 'function Resolve-ProfileMatrixAccountName' -and
        $profileMatrixSource -match 'function Test-AccountNameSidBinding' -and
        $profileMatrixSource -match 'accountBinding\s*=\s*''sid-bound-display-mismatch''' -and
        $profileMatrixSource -match 'credentialAccount\s*=\s*Resolve-ProfileMatrixAccountName' -and
        $profileMatrixSource -match 'requestAccountSidValue' -and
        $profileMatrixSource -match 'accountSid') 'profile matrix resolves scheduler credentials from immutable SIDs and records Unicode display mismatches'
    Assert-True ($profileMatrixSource -match '\$actionProperty' -and
        $profileMatrixSource -match 'action binding for \$operation' -and
        $profileMatrixSource -match 'snapshotProperty') 'profile matrix parent helper binds action and snapshot fields to their operation'
    Assert-True ($profileMatrixSource -match 'raw XML in a restore request' -and
        $profileMatrixSource -match 'wasRunning to be a JSON boolean' -and
        $profileMatrixSource -match 'registration-only rollback cannot restore a running task') 'profile matrix restore rejects raw XML and running-task snapshots'
    Assert-True ($profileMatrixSource -match 'requestedSet' -and $profileMatrixSource -match 'defaultSet') 'CurrentUserOnly validates the exact four-case set instead of count alone'
    $profileAtomicWriter = [regex]::Match(
        $profileMatrixSource,
        'function Write-ProfileMatrixAtomicJson[\s\S]+?function Get-ProfileMatrixTaskRequestProperty'
    )
    Assert-True ($profileAtomicWriter.Success) 'profile matrix exposes a bounded atomic JSON writer contract'
    Assert-True ($profileAtomicWriter.Value -match '\$backup\s*=\s*Join-Path' -and
        $profileAtomicWriter.Value -match '\[System\.IO\.File\]::Replace\(\$temporary,\s*\$Path,\s*\$backup' -and
        $profileAtomicWriter.Value -notmatch '\[System\.IO\.File\]::Replace\(\$temporary,\s*\$Path,\s*\$null') 'profile matrix atomic writer supplies a valid backup path to File.Replace'
    Assert-True ($profileAtomicWriter.Value -match '\$backupStream\s*=\s*\[System\.IO\.FileStream\]::new' -and
        $profileAtomicWriter.Value -match '\$backupStream[\s\S]+\[System\.IO\.FileMode\]::CreateNew' -and
        $profileAtomicWriter.Value -match '\$backupPrepared\s*=\s*\$true') 'profile matrix atomic writer pre-creates a same-volume backup placeholder before File.Replace'
    Assert-True ($profileMatrixSource -match 'taskkill\.exe[\s\S]+/PID \$process\.Id[\s\S]+/T[\s\S]+/F' -and
        $profileMatrixSource -match '\$process\.WaitForExit\(30000\)' -and
        $profileMatrixSource -match 'did not exit after cleanup') 'profile matrix reaps a child after helper/IPC failure before profile cleanup'
    Assert-True ($profileMatrixSource -match '\$process\.Refresh\(\)' -and
        $profileMatrixSource -match 'child receipt' -and
        $profileMatrixSource -match '\$rawExitCode' -and
        $profileMatrixSource -match 'candidateExitCode') 'profile matrix handles null Start-Process exit-code projections with a receipt-backed fallback'
    Assert-True ($profileMatrixSource -match 'Wait-ProfileMatrixAdminMembership' -and
        $profileMatrixSource -match 'Get-LocalGroupMember -SID' -and
        $profileMatrixSource -match 'administrator-membership\.json') 'profile matrix waits for SID-bound administrator membership propagation and preserves evidence'
    Assert-True ($profileMatrixSource -match 'Add-LocalGroupMember[\s\S]+-Member \$newUser') 'profile matrix binds administrator membership to the created LocalUser object'
    Assert-True ($profileMatrixSource -match 'Assert-ProfileMatrixTaskOwnership' -and
        ([regex]::Matches($profileMatrixSource, '-TaskPath ''\\''').Count -ge 4)) 'profile matrix binds task ownership checks and task operations to the root task path'
    Assert-True ($profileMatrixSource -match 'observedPrincipalSid' -and
        $profileMatrixSource -match 'observedTriggerSids' -and
        $profileMatrixSource -match 'observedAction') 'profile matrix helper evidence records the verified task identity and action binding'
    Assert-True ($profileMatrixSource -match 'primary child/verification error' -and
        $profileMatrixSource -match 'profile cleanup error') 'profile matrix preserves the primary case failure when cleanup also fails'
    Assert-True ($profileMatrixSource -match 'profile cleanup failed for \$Sid after bounded retries' -and
        $profileMatrixSource -match 'profile cleanup postcondition still has profile or directory state') 'profile matrix turns residual profile state into a bounded cleanup failure'
    Assert-True ($profileMatrixSource -match 'Stack\[string\]' -and $profileMatrixSource -match 'Get-ChildItem -LiteralPath \$current -Force') 'profile matrix walks regular directories without traversing allowed junctions'
    Assert-True ($profileMatrixSource -match 'Remove-ProfileMatrixKnownCompatibilityJunctions[\s\S]+\$links[\s\S]+Sort-Object \{ \$_.Length \} -Descending') 'profile cleanup removes nested compatibility junctions deepest-first'
    Assert-True ($profileMatrixChildSource -match 'Test-FreshDeployment\.ps1') 'profile matrix child runs the complete install/repair/uninstall lifecycle harness'
    Assert-True ($profileMatrixChildSource -match 'USERPROFILE') 'profile matrix child records the effective USERPROFILE'
    Assert-True ($profileMatrixChildSource -match 'LOCALAPPDATA') 'profile matrix child records the effective LOCALAPPDATA'
    Assert-True ($profileMatrixChildSource -match 'isAdministrator') 'profile matrix child records administrator membership'
    Assert-True ($profileMatrixChildSource -match 'Get-LocalGroupMember[\s\S]+-SID' -and
        $profileMatrixChildSource -match 'administratorMembershipSource' -and
        $profileMatrixChildSource -match 'administratorMembershipLocalGroup' -and
        $profileMatrixChildSource -match 'administratorMembershipTokenGroupSids' -and
        $profileMatrixChildSource -match "'query-error'") 'profile matrix child uses a SID-backed local-group fallback when a filtered token omits administrator membership and records both evidence paths'
    Assert-True ($profileMatrixChildSource -match 'nonAsciiProfile') 'profile matrix child records non-ASCII profile evidence'
    Assert-True ($profileMatrixChildSource -match "'-ScheduledTaskLogonType', 'Interactive'") 'profile matrix child registers the production Interactive task principal'
    Assert-True ($profileMatrixChildSource -match "taskLogonType = 'Interactive'") 'profile matrix child receipt records the production task principal'
    Assert-True ($profileMatrixChildSource -match 'UseParentTaskHelper') 'profile matrix child has an explicit elevated task helper gate'
    Assert-True ($profileMatrixChildSource -match 'ProfileMatrixTaskHelperMode') 'profile matrix child forwards the explicit helper-mode switch'
    Assert-True ($profileMatrixChildSource -match 'parent-elevated-registration-only') 'profile matrix child records the gated registration-only runtime semantics'
    Assert-True ($profileMatrixChildSource -match 'task-helper-evidence\.json') 'profile matrix child preserves helper request/response evidence'

    $profileWorkflowNeedle = 'Test-WindowsProfileMatrix\.ps1'
    Assert-True ($releaseWorkflow -match $profileWorkflowNeedle) 'release workflow invokes the Windows profile/path matrix'
    Assert-True ($releaseWorkflow -match 'standard-ascii[\s\S]+administrator-ascii[\s\S]+standard-non-ascii[\s\S]+administrator-non-ascii') 'release workflow retains all four Windows profile matrix cases'

    $authenticodeBoundary = Join-Path $repoRoot 'scripts\Test-WindowsAuthenticodeBoundary.ps1'
    Assert-True (Test-Path -LiteralPath $authenticodeBoundary -PathType Leaf) 'Windows Authenticode boundary contract script exists'
    $authenticodeSource = Get-Content -LiteralPath $authenticodeBoundary -Raw
    Assert-True ($authenticodeSource -match 'Get-AuthenticodeSignature') 'Authenticode boundary script reads the platform signature status'
    Assert-True ($authenticodeSource -match 'RequireValid') 'Authenticode boundary script has a strict signed-artifact mode'
    Assert-True ($authenticodeSource -match 'RequireTimestamp') 'Authenticode boundary script can require a trusted timestamp'
    Assert-True ($authenticodeSource -match 'repository-contract') 'Authenticode boundary script has a repository contract mode'

    $forbiddenPnpmDeploy = Join-Path $testRoot 'mcp-deploy-forbidden-pnpm'
    Copy-Item -LiteralPath $mcpDeploy -Destination $forbiddenPnpmDeploy -Recurse
    [void](New-Item -ItemType Directory -Path (Join-Path $forbiddenPnpmDeploy 'node_modules\.pnpm') -Force)
    [System.IO.File]::WriteAllText((Join-Path $forbiddenPnpmDeploy 'node_modules\.pnpm\lock.yaml'), 'fixture')
    $forbiddenPnpmOutput = Join-Path $testRoot 'forbidden-pnpm-preview'
    Assert-ThrowsLike `
        -Action {
            & (Join-Path $PSScriptRoot 'New-PreviewPayload.ps1') `
                -RepositoryRoot $repoRoot `
                -RootCargoTarget $rootTarget `
                -DesktopCargoTarget $desktopTarget `
                -McpDeployRoot $forbiddenPnpmDeploy `
                -NodeExecutable $nodeRuntime `
                -NodeLicense $nodeLicense `
                -WorkerKitsRoot $workerKits `
                -OutputRoot $forbiddenPnpmOutput | Out-Null
        } `
        -Pattern 'forbidden \.pnpm entry' `
        -Message 'preview staging rejects pnpm virtual-store metadata before copying inputs'
    Assert-True (-not (Test-Path -LiteralPath $forbiddenPnpmOutput)) 'invalid MCP deploy is rejected before creating the preview output root'

    $forbiddenDevelopmentDeploy = Join-Path $testRoot 'mcp-deploy-forbidden-development-dependency'
    Copy-Item -LiteralPath $mcpDeploy -Destination $forbiddenDevelopmentDeploy -Recurse
    $scopedDevelopmentPackage = Join-Path $forbiddenDevelopmentDeploy 'node_modules\@types\node'
    [void](New-Item -ItemType Directory -Path $scopedDevelopmentPackage -Force)
    [System.IO.File]::WriteAllText(
        (Join-Path $scopedDevelopmentPackage 'package.json'),
        '{"name":"@types/node","version":"24.10.0"}'
    )
    $forbiddenDevelopmentOutput = Join-Path $testRoot 'forbidden-development-dependency-preview'
    Assert-ThrowsLike `
        -Action {
            & (Join-Path $PSScriptRoot 'New-PreviewPayload.ps1') `
                -RepositoryRoot $repoRoot `
                -RootCargoTarget $rootTarget `
                -DesktopCargoTarget $desktopTarget `
                -McpDeployRoot $forbiddenDevelopmentDeploy `
                -NodeExecutable $nodeRuntime `
                -NodeLicense $nodeLicense `
                -WorkerKitsRoot $workerKits `
                -OutputRoot $forbiddenDevelopmentOutput | Out-Null
        } `
        -Pattern "development-only package '@types/node'" `
        -Message 'preview staging rejects a leaked scoped development dependency before copying inputs'
    Assert-True (-not (Test-Path -LiteralPath $forbiddenDevelopmentOutput)) 'scoped development dependency is rejected before creating the preview output root'

    $earlyExitMcpDeploy = Join-Path $testRoot 'mcp-deploy-early-exit'
    [void](New-Item -ItemType Directory -Path (Join-Path $earlyExitMcpDeploy 'dist') -Force)
    @'
const readline = require("node:readline");
const tools = [
  "fleet_cancel", "fleet_info", "fleet_job", "fleet_plan",
  "fleet_plan_submit", "fleet_snapshot_upload", "fleet_submit",
  "workspace_snapshot_pack",
].map((name) => ({ name }));
const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on("line", (line) => {
  const request = JSON.parse(line);
  if (request.method === "initialize") {
    process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: request.id, result: { protocolVersion: "2025-06-18" } }) + "\n");
  } else if (request.method === "tools/list") {
    process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: request.id, result: { tools } }) + "\n", () => {
      setTimeout(() => process.exit(0), 10);
    });
  }
});
'@ | Set-Content -LiteralPath (Join-Path $earlyExitMcpDeploy 'dist\server.js') -Encoding ASCII
    $savedErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $earlyExitSmokeOutput = @(& $nodeRuntime (Join-Path $PSScriptRoot 'Test-McpDeployment.mjs') $earlyExitMcpDeploy 2>&1)
        $earlyExitSmokeCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    Assert-True ($earlyExitSmokeCode -ne 0) 'MCP deployment smoke rejects a server that exits immediately after tools/list'
    Assert-True ((@($earlyExitSmokeOutput | ForEach-Object { [string]$_ }) -join "`n") -match 'exited before the probe completed') 'MCP early-exit rejection reports the lifecycle failure'

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
