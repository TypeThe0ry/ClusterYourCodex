#requires -Version 5.1

# These tests deliberately exercise only the helper's in-memory contract.  All
# NetSecurity cmdlets are mocked below, so running the suite never changes the
# host firewall or opens a listener.
$firewallScript = Join-Path $PSScriptRoot 'Invoke-ClusterYourCodexFirewall.ps1'
. $firewallScript `
    -RequestPath 'C:\fixture\request.json' `
    -ExpectedRequestSha256 ('0' * 64) `
    -ExpectedHelperSha256 ('0' * 64)

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw "discovery firewall assertion failed: $Message" }
}

function New-DiscoveryFirewallFixtureRequest {
    param(
        [ValidateSet('v1', 'v2')][string]$Version = 'v2',
        [ValidateSet('Apply', 'Remove')][string]$Action = 'Apply'
    )
    $sid = 'S-1-5-21-100-200-300-1001'
    $request = [ordered]@{
        schemaVersion = if ($Version -eq 'v2') { 'cyc.dev/windows-firewall-request/v2' } else { 'cyc.dev/windows-firewall-request/v1' }
        transactionId = '0123456789abcdef0123456789abcdef'
        requestNonce = ('a' * 64)
        action = $Action
        createdAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        deadlineUtc = [DateTimeOffset]::UtcNow.AddMinutes(10).ToString('o')
        initiatorSid = $sid
        initiatorProfile = 'C:\Users\Fixture'
        initiatorLocalAppData = 'C:\Users\Fixture\AppData\Local'
        installRoot = 'C:\Users\Fixture\AppData\Local\Programs\ClusterYourCodex'
        program = 'C:\Users\Fixture\AppData\Local\Programs\ClusterYourCodex\cyc-controller.exe'
        programSha256 = ('b' * 64)
        port = 47832
        ruleName = 'ClusterYourCodex.ManagedWorker.' + $sid.Replace('-', '_')
        displayName = 'ClusterYourCodex Managed Worker'
        group = 'ClusterYourCodex'
        ruleDescription = 'ClusterYourCodex owned managed-worker TLS listener'
        remoteAddress = 'LocalSubnet'
        exchangeRoot = 'C:\Users\Fixture\AppData\Local\Temp\ClusterYourCodex-Firewall\' + $sid.Replace('-', '_') + '\0123456789abcdef0123456789abcdef'
        packageManifestSha256 = ('c' * 64)
        packageExecutable = 'C:\fixture\setup.exe'
        helperAuthenticodeRequired = $false
    }
    if ($Version -eq 'v2') {
        $request.discoveryRuleName = 'ClusterYourCodex.ManagedDiscovery.' + $sid.Replace('-', '_')
        $request.discoveryPort = 47830
    }
    return [PSCustomObject]$request
}

function Add-MockDiscoveryFirewallRule {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Protocol,
        [Parameter(Mandatory = $true)][int]$Port,
        [string]$Enabled = 'True',
        [string]$DisplayName,
        [string]$Description
    )
    $script:MockFirewallRules[$Name] = [PSCustomObject]@{
        Name = $Name
        Group = 'ClusterYourCodex'
        DisplayName = if ($DisplayName) { $DisplayName } else { 'ClusterYourCodex Managed Worker' }
        Description = if ($Description) { $Description } else { 'ClusterYourCodex owned managed-worker TLS listener' }
        Enabled = $Enabled
        Direction = 'Inbound'
        Action = 'Allow'
        Profile = 'Private'
        EdgeTraversalPolicy = 'Block'
        Protocol = $Protocol
        LocalPort = [string]$Port
        RemotePort = 'Any'
        LocalAddress = @('Any')
        RemoteAddress = @('LocalSubnet')
        Program = 'C:\Users\Fixture\AppData\Local\Programs\ClusterYourCodex\cyc-controller.exe'
    }
}

Describe 'Windows LAN discovery firewall contract' {
    BeforeEach {
        $script:MockFirewallRules = @{}
        $script:MockNewFirewallCalls = @()
        $script:MockRemoveFirewallCalls = @()
        $script:MockFailDiscoveryCreate = $false

        Set-Item -Path Function:\Get-NetFirewallRule -Value {
            param($Name, $Group)
            $nameValue = [string](@($Name)[0])
            if (-not [string]::IsNullOrWhiteSpace($nameValue) -and $script:MockFirewallRules.ContainsKey($nameValue)) {
                return $script:MockFirewallRules[$nameValue]
            }
            return @()
        }
        # Pester 3 preserves NetSecurity's CimInstance parameter constraints on
        # a Mock. Override the three read-only filter commands with untyped
        # local functions so our plain in-memory rule records remain fixtures,
        # not fake CimInstances or host firewall state.
        Set-Item -Path Function:\Get-NetFirewallPortFilter -Value {
            param($AssociatedNetFirewallRule)
            $rule = $AssociatedNetFirewallRule
            return [PSCustomObject]@{
                Protocol = [string]$rule.Protocol
                LocalPort = [string]$rule.LocalPort
                RemotePort = [string]$rule.RemotePort
            }
        }
        Set-Item -Path Function:\Get-NetFirewallAddressFilter -Value {
            param($AssociatedNetFirewallRule)
            $rule = $AssociatedNetFirewallRule
            return [PSCustomObject]@{
                LocalAddress = @($rule.LocalAddress)
                RemoteAddress = @($rule.RemoteAddress)
            }
        }
        Set-Item -Path Function:\Get-NetFirewallApplicationFilter -Value {
            param($AssociatedNetFirewallRule)
            $rule = $AssociatedNetFirewallRule
            return [PSCustomObject]@{ Program = [string]$rule.Program }
        }
        Set-Item -Path Function:\New-NetFirewallRule -Value {
            param(
                $Name, $DisplayName, $Group, $Description, $Direction, $Action,
                $Enabled, $Profile, $Protocol, $LocalPort, $RemoteAddress,
                $Program, $EdgeTraversalPolicy
            )
            $protocolValue = [string](@($Protocol)[0])
            $portValue = [int]([string](@($LocalPort)[0]))
            if ($protocolValue -ceq 'UDP' -and $script:MockFailDiscoveryCreate) {
                throw 'fixture-discovery-create-failure'
            }
            $script:MockNewFirewallCalls += [PSCustomObject]@{
                Name = [string](@($Name)[0])
                Protocol = $protocolValue
                Port = $portValue
                Profile = [string](@($Profile)[0])
                RemoteAddress = [string](@($RemoteAddress)[0])
                Program = [string](@($Program)[0])
                EdgeTraversalPolicy = [string](@($EdgeTraversalPolicy)[0])
            }
            Add-MockDiscoveryFirewallRule `
                -Name ([string](@($Name)[0])) `
                -Protocol $protocolValue `
                -Port $portValue `
                -Enabled ([string](@($Enabled)[0])) `
                -DisplayName ([string](@($DisplayName)[0])) `
                -Description ([string](@($Description)[0]))
            return $script:MockFirewallRules[[string](@($Name)[0])]
        }
        Set-Item -Path Function:\Remove-NetFirewallRule -Value {
            param($Name)
            $nameValue = [string](@($Name)[0])
            $script:MockRemoveFirewallCalls += $nameValue
            [void]$script:MockFirewallRules.Remove($nameValue)
        }
    }

    AfterEach {
        # Do not leak the untyped fixture shims into another Pester script run
        # in the same PowerShell process; the real NetSecurity cmdlets remain
        # the default outside this Describe block.
        foreach ($name in @(
            'Get-NetFirewallRule', 'Get-NetFirewallPortFilter',
            'Get-NetFirewallAddressFilter', 'Get-NetFirewallApplicationFilter',
            'New-NetFirewallRule', 'Remove-NetFirewallRule'
        )) {
            Remove-Item -Path ("Function:\" + $name) -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps the legacy v1 request and receipt worker-only' {
        $request = New-DiscoveryFirewallFixtureRequest -Version v1
        { Assert-CycFirewallRequestShape -Request $request } | Should Not Throw
        (Get-CycFirewallRequestSchemaVersion -Request $request) | Should Be 'v1'
        $receipt = New-CycFirewallReceipt -Request $request -RequestHash ('d' * 64) -Result verified
        [void](Assert-CycFirewallReceiptBinding -Receipt $receipt -Request $request -RequestHash ('d' * 64))
        $receipt.schemaVersion | Should Be 'cyc.dev/windows-firewall-receipt/v1'
        (@($receipt.PSObject.Properties.Name) -contains 'discoveryRuleName') | Should Be $false
        (@($receipt.PSObject.Properties.Name) -contains 'discoveryPort') | Should Be $false
    }

    It 'accepts v2 only with its deterministic discovery identity and port' {
        $request = New-DiscoveryFirewallFixtureRequest
        { Assert-CycFirewallRequestShape -Request $request } | Should Not Throw
        (Get-CycFirewallRequestSchemaVersion -Request $request) | Should Be 'v2'
        $receipt = New-CycFirewallReceipt -Request $request -RequestHash ('d' * 64) -Result verified
        [void](Assert-CycFirewallReceiptBinding -Receipt $receipt -Request $request -RequestHash ('d' * 64))
        $receipt.schemaVersion | Should Be 'cyc.dev/windows-firewall-receipt/v2'
        $receipt.discoveryRuleName | Should Be $request.discoveryRuleName
        [int]$receipt.discoveryPort | Should Be 47830

        $badName = New-DiscoveryFirewallFixtureRequest
        $badName.PSObject.Properties['discoveryRuleName'].Value = 'ClusterYourCodex.ManagedDiscovery.Arbitrary'
        $badNameRejected = $false
        try { [void](Assert-CycFirewallRequestShape -Request $badName) } catch { $badNameRejected = $true }
        Assert-True $badNameRejected 'v2 rejects a non-deterministic discovery rule name'

        $badPort = New-DiscoveryFirewallFixtureRequest
        $badPort.PSObject.Properties['discoveryPort'].Value = 47831
        $badPortRejected = $false
        try { [void](Assert-CycFirewallRequestShape -Request $badPort) } catch { $badPortRejected = $true }
        Assert-True $badPortRejected 'v2 rejects a non-fixed discovery port'

        $v1WithDiscovery = New-DiscoveryFirewallFixtureRequest -Version v1
        $v1WithDiscovery | Add-Member -NotePropertyName discoveryRuleName -NotePropertyValue $request.discoveryRuleName
        $v1WithDiscovery | Add-Member -NotePropertyName discoveryPort -NotePropertyValue 47830
        $v1Rejected = $false
        try { [void](Assert-CycFirewallRequestShape -Request $v1WithDiscovery) } catch { $v1Rejected = $true }
        Assert-True $v1Rejected 'legacy v1 rejects v2-only discovery fields'
    }

    It 'applies v2 as exactly two narrow rules with one worker and one UDP discovery rule' {
        $request = New-DiscoveryFirewallFixtureRequest
        Set-CycExactFirewallDesiredState -Request $request
        $script:MockFirewallRules.Keys.Count | Should Be 2
        $script:MockFirewallRules.ContainsKey($request.ruleName) | Should Be $true
        $script:MockFirewallRules.ContainsKey($request.discoveryRuleName) | Should Be $true
        $script:MockNewFirewallCalls.Count | Should Be 2
        $workerCall = @($script:MockNewFirewallCalls | Where-Object { $_.Name -eq $request.ruleName })[0]
        $discoveryCall = @($script:MockNewFirewallCalls | Where-Object { $_.Name -eq $request.discoveryRuleName })[0]
        $workerCall.Protocol | Should Be 'TCP'
        $workerCall.Port | Should Be 47832
        $discoveryCall.Protocol | Should Be 'UDP'
        $discoveryCall.Port | Should Be 47830
        $workerCall.Profile | Should Be 'Private'
        $discoveryCall.Profile | Should Be 'Private'
        $workerCall.RemoteAddress | Should Be 'LocalSubnet'
        $discoveryCall.RemoteAddress | Should Be 'LocalSubnet'
        $workerCall.EdgeTraversalPolicy | Should Be 'Block'
        $discoveryCall.EdgeTraversalPolicy | Should Be 'Block'
    }

    It 'removes both v2 rules as one logical operation' {
        $request = New-DiscoveryFirewallFixtureRequest -Action Remove
        Add-MockDiscoveryFirewallRule -Name $request.ruleName -Protocol TCP -Port 47832
        Add-MockDiscoveryFirewallRule `
            -Name $request.discoveryRuleName `
            -Protocol UDP `
            -Port 47830 `
            -DisplayName 'ClusterYourCodex LAN Discovery' `
            -Description 'ClusterYourCodex owned LAN discovery listener'
        Set-CycExactFirewallDesiredState -Request $request
        $script:MockFirewallRules.Keys.Count | Should Be 0
        @($script:MockRemoveFirewallCalls).Count | Should Be 2
    }

    It 'accepts a legacy worker rule on the previous port so repair can migrate it' {
        $request = New-DiscoveryFirewallFixtureRequest -Version v1
        Add-MockDiscoveryFirewallRule -Name $request.ruleName -Protocol TCP -Port 47831
        $owned = Get-CycOwnedFirewallRule -Request $request
        $owned.port.LocalPort | Should Be '47831'
        $snapshot = Get-CycFirewallOriginalSnapshot -Request $request
        $snapshot.port | Should Be 47831
        Set-CycExactFirewallDesiredState -Request $request
        $script:MockFirewallRules[$request.ruleName].LocalPort | Should Be '47832'
    }

    It 'restores the complete v2 snapshot after a partial discovery-rule failure' {
        $request = New-DiscoveryFirewallFixtureRequest
        $snapshot = [PSCustomObject][ordered]@{
            worker = [PSCustomObject][ordered]@{ existed = $true; enabled = 'False'; port = 47832 }
            discovery = [PSCustomObject][ordered]@{ existed = $false }
        }
        Add-MockDiscoveryFirewallRule -Name $request.ruleName -Protocol TCP -Port 47832
        $script:MockFailDiscoveryCreate = $true
        { Set-CycExactFirewallDesiredState -Request $request } | Should Throw 'fixture-discovery-create-failure'
        $script:MockFailDiscoveryCreate = $false
        Restore-CycExactFirewallSnapshot -Request $request -Snapshot $snapshot
        $script:MockFirewallRules.ContainsKey($request.discoveryRuleName) | Should Be $false
        $restoredWorker = $script:MockFirewallRules[$request.ruleName]
        $restoredWorker | Should Not Be $null
        $restoredWorker.LocalPort | Should Be '47832'
        $restoredWorker.Enabled | Should Be 'False'
    }

    It 'rejects an existing rule with a widened scope or wrong protocol' {
        $request = New-DiscoveryFirewallFixtureRequest
        Add-MockDiscoveryFirewallRule `
            -Name $request.discoveryRuleName `
            -Protocol TCP `
            -Port 47830 `
            -DisplayName 'ClusterYourCodex LAN Discovery' `
            -Description 'ClusterYourCodex owned LAN discovery listener'
        $wrongProtocolRejected = $false
        try { [void](Get-CycOwnedFirewallRule -Request $request -Discovery) } catch { $wrongProtocolRejected = $true }
        Assert-True $wrongProtocolRejected 'discovery rejects a TCP rule on the UDP discovery port'

        $script:MockFirewallRules[$request.discoveryRuleName].Protocol = 'UDP'
        $script:MockFirewallRules[$request.discoveryRuleName].RemoteAddress = @('Any')
        $wrongScopeRejected = $false
        try { [void](Get-CycOwnedFirewallRule -Request $request -Discovery) } catch { $wrongScopeRejected = $true }
        Assert-True $wrongScopeRejected 'discovery rejects a widened remote scope'
    }
}
