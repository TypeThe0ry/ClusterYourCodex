#requires -Version 5.1
. (Join-Path $PSScriptRoot 'Invoke-ClusterYourCodexLifecycle.ps1')

Describe 'Fresh install port preflight' {
    BeforeEach {
        $plan = [PSCustomObject]@{
            managedWorker = [PSCustomObject]@{ enabled = $true; listenPort = 47832 }
        }
        $script:conflictingPort = 0
        Mock Get-NetTCPConnection {
            if ($LocalPort -eq $script:conflictingPort) {
                [PSCustomObject]@{ OwningProcess = 1234 }
            }
        }
    }

    It 'accepts available ports' {
        Assert-CycFreshInstallPortsAvailable -Plan $plan -ExistingManifest $null
        Assert-MockCalled Get-NetTCPConnection -Times 2 -Exactly -Scope It
    }

    It 'rejects a conflicting controller before mutation' {
        $script:conflictingPort = 47831
        { Assert-CycFreshInstallPortsAvailable -Plan $plan -ExistingManifest $null } | Should Throw 'TCP port 47831 is already listening (PID 1234)'
    }

    It 'rejects a conflicting managed listener' {
        $script:conflictingPort = 47832
        { Assert-CycFreshInstallPortsAvailable -Plan $plan -ExistingManifest $null } | Should Throw 'TCP port 47832'
    }

    It 'leaves repair runtime checks to the core rollback boundary' {
        Assert-CycFreshInstallPortsAvailable -Plan $plan -ExistingManifest ([PSCustomObject]@{})
        Assert-MockCalled Get-NetTCPConnection -Times 0 -Exactly -Scope It
    }

    It 'does not require the disabled managed listener port' {
        $plan.managedWorker.enabled = $false
        Assert-CycFreshInstallPortsAvailable -Plan $plan -ExistingManifest $null
        Assert-MockCalled Get-NetTCPConnection -Times 1 -Exactly -Scope It
        Assert-MockCalled Get-NetTCPConnection -Times 0 -Exactly -Scope It -ParameterFilter { $LocalPort -eq 47832 }
    }
}
