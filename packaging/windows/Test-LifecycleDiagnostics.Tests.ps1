#requires -Version 5.1
$lifecyclePath = Join-Path $PSScriptRoot 'Invoke-ClusterYourCodexLifecycle.ps1'

Describe 'Default lifecycle failure diagnostics' {
    It 'retains a failure in existing private installer state without an environment override' {
        $saved = $env:CYC_SETUP_DIAGNOSTIC_LOG
        try {
            $env:CYC_SETUP_DIAGNOSTIC_LOG = $null
            $data = Join-Path $TestDrive 'data'
            $private = Join-Path $data '.installer'
            New-Item -ItemType Directory -Path $private -Force | Out-Null
            . $lifecyclePath -DataRoot $data
            Set-CycLifecycleDiagnosticStage -Stage 'core-applying'
            try { throw 'fixture failure' } catch { $failure = $_ }
            Write-CycLifecycleDiagnostic -Status failed -Result $null -Failure $failure
            $record = Get-Content (Join-Path $private 'last-lifecycle-diagnostic.json') -Raw | ConvertFrom-Json
            $record.status | Should Be 'failed'
            $record.lastStage | Should Be 'core-applying'
            $record.error.message | Should Be 'fixture failure'
        } finally { $env:CYC_SETUP_DIAGNOSTIC_LOG = $saved }
    }

    It 'does not create an unprotected state directory during an early failure' {
        $saved = $env:CYC_SETUP_DIAGNOSTIC_LOG
        try {
            $env:CYC_SETUP_DIAGNOSTIC_LOG = $null
            $missing = Join-Path $TestDrive 'missing'
            . $lifecyclePath -DataRoot $missing
            Write-CycLifecycleDiagnostic -Status failed -Result $null -Failure $null
            Test-Path -LiteralPath $missing | Should Be $false
        } finally { $env:CYC_SETUP_DIAGNOSTIC_LOG = $saved }
    }
}
