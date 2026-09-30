#requires -Version 5.1
# Exercise the production request factory, not a hand-authored deserialized
# fixture. No process, service, firewall or product profile is changed.
. (Join-Path $PSScriptRoot 'Invoke-ClusterYourCodexLifecycle.ps1') -PackageExecutable 'C:\fixture\Setup.exe'

Describe 'Fresh and recovered lifecycle request binding' {
    BeforeEach {
        $binding = [PSCustomObject]@{
            sid = 'S-1-5-21-100-200-300-1001'
            profile = 'C:\Users\Fixture'
            localAppData = 'C:\Users\Fixture\AppData\Local'
        }
        $roots = [PSCustomObject]@{
            installRoot = Join-Path $binding.localAppData 'Programs\ClusterYourCodex'
            dataRoot = Join-Path $binding.localAppData 'ClusterYourCodex'
        }
        $transactionId = '0123456789abcdef0123456789abcdef'
        $exchange = [PSCustomObject]@{ root = 'C:\fixture\exchange' }
        $request = New-CycFirewallRequest -Binding $binding -Roots $roots -Exchange $exchange `
            -TransactionId $transactionId -FirewallAction Apply -ProgramSha256 ('b' * 64) `
            -PackageDigest ('c' * 64) -Port 47832 -Deadline ([DateTimeOffset]::UtcNow.AddMinutes(10))
        $journal = [PSCustomObject]@{
            action = 'Install'
            transactionId = $transactionId
            requestSha256 = ('d' * 64)
            initiatorSid = $binding.sid
            initiatorProfile = $binding.profile
            initiatorLocalAppData = $binding.localAppData
            installRoot = $roots.installRoot
            dataRoot = $roots.dataRoot
            exchangeRoot = $exchange.root
            packageManifestSha256 = ('c' * 64)
        }
        $manifest = [PSCustomObject]@{
            schemaVersion = 'cyc.dev/windows-install-manifest/v1'
            installRoot = $roots.installRoot
            dataRoot = $roots.dataRoot
            initiator = $binding
            coreCommit = [PSCustomObject]@{
                schemaVersion = 'cyc.dev/windows-core-commit/v1'
                action = 'Install'
                state = 'committed'
                transactionId = $transactionId
                requestSha256 = $journal.requestSha256
                committedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            }
            files = @([PSCustomObject]@{ relativePath = 'cyc-controller.exe'; sha256 = ('b' * 64) })
            managedWorker = [PSCustomObject]@{
                firewall = [PSCustomObject]@{
                    enabled = $true
                    lifecycle = 'external-elevated-helper'
                    transactionId = $transactionId
                    requestSha256 = $journal.requestSha256
                    state = 'pending'
                    receiptSha256 = $null
                    appliedAtUtc = $null
                    name = $request.ruleName
                    program = $request.program
                    port = $request.port
                    discoveryName = $request.discoveryRuleName
                    discoveryPort = $request.discoveryPort
                }
            }
        }
    }

    It 'binds the fresh production v2 request before it is read from JSON' {
        Test-CycFirewallRequestJournalBinding -Request $request -Journal $journal | Should Be $true
        Test-CycLifecycleCoreCommitAfterImage -Journal $journal -Manifest $manifest -Request $request | Should Be $true
    }

    It 'binds the same durable request after restart without changing its wire shape' {
        $path = Join-Path $TestDrive 'request.json'
        Write-CycLifecycleAtomicJson -Path $path -Value $request
        $recovered = Read-CycLifecycleJson -Path $path -MaximumBytes 32768 -Label 'Fixture request'
        ($request | ConvertTo-Json -Depth 8 -Compress) | Should Be ($recovered | ConvertTo-Json -Depth 8 -Compress)
        Test-CycFirewallRequestJournalBinding -Request $recovered -Journal $journal | Should Be $true
        Test-CycLifecycleCoreCommitAfterImage -Journal $journal -Manifest $manifest -Request $recovered | Should Be $true
    }

    It 'accepts both fresh and recovered Remove requests only with an absent manifest' {
        $remove = New-CycFirewallRequest -Binding $binding -Roots $roots -Exchange $exchange `
            -TransactionId $transactionId -FirewallAction Remove -ProgramSha256 ('b' * 64) `
            -PackageDigest ('c' * 64) -Port 47832 -Deadline ([DateTimeOffset]::UtcNow.AddMinutes(10))
        $journal.action = 'Uninstall'
        $recovered = $remove | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        foreach ($candidate in @($remove, $recovered)) {
            Test-CycFirewallRequestJournalBinding -Request $candidate -Journal $journal | Should Be $true
            Test-CycLifecycleCoreCommitAfterImage -Journal $journal -Manifest $null -Request $candidate | Should Be $true
            Test-CycLifecycleCoreCommitAfterImage -Journal $journal -Manifest $manifest -Request $candidate | Should Be $false
        }
    }

    It 'rejects missing, wrong or extra discovery fields after normalization' {
        $wrongPort = $request | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $wrongPort.discoveryPort = 47831
        Test-CycFirewallRequestJournalBinding -Request $wrongPort -Journal $journal | Should Be $false
        $missing = $request | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $missing.PSObject.Properties.Remove('discoveryRuleName')
        Test-CycFirewallRequestJournalBinding -Request $missing -Journal $journal | Should Be $false
        $extra = $request | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $extra | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
        Test-CycFirewallRequestJournalBinding -Request $extra -Journal $journal | Should Be $false
        $manifest.managedWorker.firewall.discoveryPort = 47831
        Test-CycLifecycleCoreCommitAfterImage -Journal $journal -Manifest $manifest -Request $request | Should Be $false
    }

}
