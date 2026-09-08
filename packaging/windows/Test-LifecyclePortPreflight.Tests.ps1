#requires -Version 5.1
. (Join-Path $PSScriptRoot 'Invoke-ClusterYourCodexLifecycle.ps1')

Describe 'Controller storage preflight' {
    It 'accepts a new data root without creating it' {
        $root = Join-Path $TestDrive 'new-data'
        Assert-CycControllerStoragePreflight -RequestedDataRoot $root
        Test-Path -LiteralPath $root | Should Be $false
    }

    It 'rejects orphaned objects and preserves their content' {
        $root = Join-Path $TestDrive 'orphan-objects'
        $objects = Join-Path $root 'jobs'
        New-Item -ItemType Directory -Path $objects -Force | Out-Null
        $receipt = Join-Path $objects 'receipt.txt'
        [IO.File]::WriteAllText($receipt, 'retained')
        { Assert-CycControllerStoragePreflight -RequestedDataRoot $root } | Should Throw 'exists without controller.db'
        [IO.File]::ReadAllText($receipt) | Should Be 'retained'
    }

    It 'rejects even an empty orphaned object root' {
        $root = Join-Path $TestDrive 'empty-objects'
        New-Item -ItemType Directory -Path (Join-Path $root 'jobs') -Force | Out-Null
        { Assert-CycControllerStoragePreflight -RequestedDataRoot $root } | Should Throw 'exists without controller.db'
        Test-Path -LiteralPath (Join-Path $root 'jobs') | Should Be $true
    }

    It 'rejects orphaned WAL and SHM files' {
        foreach ($name in @('controller.db-wal', 'controller.db-shm')) {
            $root = Join-Path $TestDrive $name
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $root $name), 'retained')
            { Assert-CycControllerStoragePreflight -RequestedDataRoot $root } | Should Throw 'exists without controller.db'
        }
    }

    It 'leaves existing database validation to the controller' {
        $root = Join-Path $TestDrive 'existing-database'
        New-Item -ItemType Directory -Path (Join-Path $root 'jobs') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'controller.db'), 'fixture-not-a-real-database')
        Assert-CycControllerStoragePreflight -RequestedDataRoot $root
    }
}

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
