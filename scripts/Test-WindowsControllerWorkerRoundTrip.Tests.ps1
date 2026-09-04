#requires -Version 5.1

$testRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$probePath = Join-Path $testRoot 'Test-WindowsControllerWorkerRoundTrip.ps1'
$probeSource = [IO.File]::ReadAllText($probePath)

Describe 'Windows controller/worker live round-trip probe contract' {
    It 'is parseable by the host PowerShell parser' {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $probePath,
            [ref]$tokens,
            [ref]$errors
        ) | Out-Null
        @($errors).Count | Should Be 0
    }

    It 'has an explicit Windows and RFC1918 fail-closed boundary' {
        $probeSource | Should Match 'Test-IsWindowsHost'
        $probeSource | Should Match 'Test-PrivateIpv4'
        $probeSource | Should Match 'requires a Windows host'
        $probeSource | Should Match 'no assigned RFC1918 IPv4 address'
        $probeSource | Should Match 'worker-public-url'
        $probeSource | Should Match 'Protect-PrivateDirectory'
        $probeSource | Should Match 'privateJobRootAcl'
    }

    It 'passes the shell-only self-test without starting a daemon' {
        $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
        if ($null -eq $pwsh) { $pwsh = Get-Command powershell -ErrorAction Stop }
        & $pwsh.Source -NoLogo -NoProfile -NonInteractive -File $probePath -SelfTest | Out-Null
        $LASTEXITCODE | Should Be 0
    }

    It 'keeps credentials in files and scans before removing them' {
        $probeSource | Should Match '--token-file'
        $probeSource | Should Not Match '--token\s+'
        $scanIndex = $probeSource.IndexOf('function Scan-SecretLeaks', [StringComparison]::Ordinal)
        $removeIndex = $probeSource.IndexOf('foreach ($path in @($script:State.ControllerToken', [StringComparison]::Ordinal)
        ($scanIndex -ge 0) | Should Be $true
        ($removeIndex -ge 0) | Should Be $true
        ($scanIndex -lt $removeIndex) | Should Be $true
    }

    It 'records cleanup and refuses to promote clean VM or signing evidence' {
        $probeSource | Should Match 'jobRootDeleted'
        $probeSource | Should Match 'processCleanup'
        $probeSource | Should Match 'secretScan'
        $probeSource | Should Match 'not clean-VM, production-signing'
    }

    It 'cleans process trees on Windows PowerShell 5.1 and fails closed when inspection is unavailable' {
        $probeSource | Should Match 'Get-ProcessTreeSnapshot'
        $probeSource | Should Match 'Get-CimInstance -ClassName Win32_Process'
        $probeSource | Should Match 'taskkill\.exe'
        $probeSource | Should Match 'ProcessIds\.Count -gt 0'
        $probeSource | Should Match 'foreach \(\$childPid in @\(\$beforeTree\.ProcessIds\)\)'
        $probeSource | Should Match 'if \(-not \$beforeTree\.Available\) \{ \$clean = \$false \}'
    }

    It 'waits for truthful scheduler CPU headroom before submitting the live job' {
        $probeSource | Should Match 'function Wait-NodeCapacity'
        $probeSource | Should Match 'effectiveResources\.availableCpuCores'
        $probeSource | Should Match 'fleet-capacity-'
        $probeSource | Should Match 'Wait-NodeCapacity -MinimumCpuCores 1'
        $probeSource | Should Match 'never exposed .*allocatable CPU core'
    }
}
