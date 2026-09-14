#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$installer = Join-Path $PSScriptRoot 'Install-Worker.ps1'
$source = Get-Content -LiteralPath $installer -Raw
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Installer syntax invalid.' }

foreach ($name in @(
    'Test-ReparsePoint',
    'Set-AclPortable',
    'Assert-PrivateAcl',
    'Resolve-NormalizedPath',
    'Resolve-AccountSid',
    'Get-PrivateOwnerSid',
    'Get-PrivatePrincipalSids',
    'Get-ExpectedWorkerTaskPrincipalSid',
    'Assert-WorkerTaskOwnership',
    'Assert-LegacyWorkerTask',
    'Get-WorkerTaskSnapshot',
    'Stop-AndRemoveTask'
)) {
    $definition = @($ast.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true))
    if ($definition.Count -ne 1) { throw "Missing installer function: $name" }
    . ([scriptblock]::Create($definition[0].Extent.Text))
}

$script:TaskName = 'ClusterYourCodex Worker'
$script:OwnerSid = 'S-1-5-21-100-200-300-1001'
$script:Schema = 'cyc.dev/worker-install/v1'
$global:task = $null
$global:taskXml = '<legacy-task />'
$global:touches = [Collections.Generic.List[string]]::new()

function Resolve-AccountSid {
    param([Parameter(Mandatory = $true)][string]$Account)
    if ($Account -match '^S-[0-9-]+$') { return $Account }
    if ($Account -ieq 'sshadmin' -or $Account -ieq 'CONTOSO\sshadmin') { return $script:OwnerSid }
    return $null
}

function New-LegacyTask {
    param(
        [string]$Executable = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'),
        [string]$Arguments = 'run --config "C:\Users\sshadmin\AppData\Local\ClusterYourCodex\worker\config.json"',
        [string]$WorkingDirectory = 'C:\Users\sshadmin\AppData\Local\ClusterYourCodex\worker\workspace',
        [string]$Principal = 'sshadmin',
        [string]$TaskPath = '\',
        [object[]]$Actions = $null
    )
    if ($null -eq $Actions) {
        $Actions = @([pscustomobject]@{
            Execute = $Executable
            Arguments = $Arguments
            WorkingDirectory = $WorkingDirectory
        })
    }
    return [pscustomobject]@{
        TaskPath = $TaskPath
        Actions = $Actions
        Principal = [pscustomobject]@{ UserId = $Principal }
        State = 'Ready'
    }
}

function global:Get-ScheduledTask {
    param([string]$TaskName, [string]$TaskPath, [object]$ErrorAction)
    if ($null -ne $global:task) { return $global:task }
}

function global:Export-ScheduledTask {
    param([string]$TaskName, [string]$TaskPath)
    return $global:taskXml
}

function global:Stop-ScheduledTask {
    param([string]$TaskName, [string]$TaskPath, [object]$ErrorAction)
    $global:touches.Add("stop:$TaskName")
}

function global:Unregister-ScheduledTask {
    param([string]$TaskName, [string]$TaskPath, [switch]$Confirm)
    $global:touches.Add("remove:$TaskName")
    $global:task = $null
}

$config = 'C:\Users\sshadmin\AppData\Local\ClusterYourCodex\worker\config.json'
$workspace = 'C:\Users\sshadmin\AppData\Local\ClusterYourCodex\worker\workspace'
$worker = 'C:\Users\sshadmin\AppData\Local\Programs\ClusterYourCodexWorker\cyc-worker.exe'

# Exact legacy action is recognized and tagged, but native-only inspection stays fail-closed.
$global:task = New-LegacyTask -Executable (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
$probe = @(Get-ScheduledTask -TaskName $script:TaskName -TaskPath '\' -ErrorAction SilentlyContinue)
if ($probe.Count -ne 1 -or [string]$probe[0].TaskPath -cne '\') {
    throw ('Mock scheduler probe failed: ' + ($probe | ConvertTo-Json -Compress))
}
$snapshot = Get-WorkerTaskSnapshot -Executable $worker -Config $config -WorkingDirectory $workspace -ResolvedScope User -AllowLegacyMigration
if ($snapshot.TaskKind -cne 'LegacyPowerShell' -or $snapshot.Xml -cne $global:taskXml) {
    throw 'Exact legacy task was not classified as LegacyPowerShell.'
}
$nativeRejected = $false
try { Get-WorkerTaskSnapshot -Executable $worker -Config $config -WorkingDirectory $workspace -ResolvedScope User }
catch { $nativeRejected = $true }
if (-not $nativeRejected) { throw 'Legacy task was accepted by native-only inspection.' }

# Repair removal can touch only the exact classified legacy task.
$global:touches.Clear()
Stop-AndRemoveTask -Executable $worker -Config $config -WorkingDirectory $workspace -ResolvedScope User -AllowLegacyMigration
if ($global:touches.Count -ne 2 -or $global:touches[0] -cne 'stop:ClusterYourCodex Worker' -or
    $global:touches[1] -cne 'remove:ClusterYourCodex Worker') {
    throw 'Legacy migration did not remove exactly the owned task.'
}

function Assert-RejectedWithoutTouch {
    param([Parameter(Mandatory = $true)]$Candidate, [Parameter(Mandatory = $true)][string]$Label)
    $global:task = $Candidate
    $global:touches.Clear()
    $rejected = $false
    try {
        Get-WorkerTaskSnapshot -Executable $worker -Config $config -WorkingDirectory $workspace -ResolvedScope User -AllowLegacyMigration | Out-Null
    } catch { $rejected = $true }
    if (-not $rejected) { throw "$Label was accepted." }
    if ($global:touches.Count -ne 0) { throw "$Label caused a scheduler mutation." }
}

Assert-RejectedWithoutTouch -Candidate (New-LegacyTask -Arguments 'run --config "C:\foreign\config.json"') -Label 'foreign config binding'
Assert-RejectedWithoutTouch -Candidate (New-LegacyTask -WorkingDirectory 'C:\foreign\workspace') -Label 'foreign workspace binding'
Assert-RejectedWithoutTouch -Candidate (New-LegacyTask -Executable (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\WindowsPowerShell.exe')) -Label 'non-canonical PowerShell executable'
Assert-RejectedWithoutTouch -Candidate (New-LegacyTask -Principal 'S-1-5-18') -Label 'foreign principal'
Assert-RejectedWithoutTouch -Candidate (New-LegacyTask -Actions @(
    [pscustomobject]@{ Execute = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'); Arguments = 'run --config "C:\Users\sshadmin\AppData\Local\ClusterYourCodex\worker\config.json"'; WorkingDirectory = $workspace },
    [pscustomobject]@{ Execute = 'C:\foreign.exe'; Arguments = ''; WorkingDirectory = $workspace }
)) -Label 'extra action'
Assert-RejectedWithoutTouch -Candidate (New-LegacyTask -TaskPath '\Foreign\') -Label 'foreign task path'

# Older repair journals did not persist taskKind. They must remain restorable as native,
# while a new legacy journal explicitly retains the compatibility classification.
if ($source -notmatch '\$null -ne \$state\.PSObject\.Properties\[\x27taskKind\x27\]') {
    throw 'Restore-WorkerTransaction does not safely handle journals without taskKind.'
}
if ($source -notmatch 'taskKind\s*=\s*if \(\$taskExisted') {
    throw 'New repair transactions do not persist taskKind.'
}
if ($source -notmatch 'Assert-WorkerLegacyMigrationBinding') {
    throw 'Repair path is missing legacy identity binding validation.'
}


# The path-binding guard uses comparison values rather than native command
# arguments. This prevents PowerShell from parsing `-or` as a parameter name
# when the guard runs during a real repair.
$bindingFunction = @($ast.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Assert-WorkerLegacyMigrationBinding'
}, $true))[0].Extent.Text
if ($bindingFunction -match '\[string\]::Equals\(\(Resolve-NormalizedPath') {
    throw 'Legacy migration path binding still embeds Resolve-NormalizedPath inside String.Equals.'
}
if ($source -notmatch '\$recordedPath\s*=\s*Resolve-NormalizedPath' -or
    $source -notmatch '\$expectedPath\s*=\s*Resolve-NormalizedPath') {
    throw 'Legacy migration path binding does not normalize both comparison operands.'
}
if ($bindingFunction -match 'if \(Test-ReparsePoint \$markerItem -or') {
    throw 'Legacy migration marker guard passes -or as a native function argument.'
}
if ($source -notmatch 'New-ScheduledTaskPrincipal\s+-UserId\s+\$identity\s+-LogonType\s+S4U\s+-RunLevel\s+Limited') {
    throw 'User-scope workers still require an interactive desktop logon.'
}
Write-Output 'Legacy Windows worker task migration contract tests passed (mock scheduler; no live task changes).'
