#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$installer = Join-Path $PSScriptRoot 'Install-Worker.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Installer parse failed.' }
$layoutFunction = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-WorkerInstanceLayout'
}, $true)
if ($null -eq $layoutFunction) { throw 'Missing instance layout function.' }
. ([scriptblock]::Create($layoutFunction.Extent.Text))
$bindingFunction = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-WorkerTransactionInstance'
}, $true)
if ($null -eq $bindingFunction) { throw 'Missing transaction binding validator.' }
. ([scriptblock]::Create($bindingFunction.Extent.Text))
Assert-WorkerTransactionInstance -State ([pscustomobject]@{}) -ExpectedTaskName 'ClusterYourCodex Worker'
Assert-WorkerTransactionInstance -State ([pscustomobject]@{taskName='ClusterYourCodex Worker - alpha'}) -ExpectedTaskName 'ClusterYourCodex Worker - alpha'
foreach ($badState in @([pscustomobject]@{}, [pscustomobject]@{taskName='ClusterYourCodex Worker - beta'}, [pscustomobject]@{taskName=$null})) {
    $rejected = $false
    try { Assert-WorkerTransactionInstance -State $badState -ExpectedTaskName 'ClusterYourCodex Worker - alpha' }
    catch { $rejected = $true }
    if (-not $rejected) { throw 'Named transaction accepted a missing or foreign instance binding.' }
}
$a = Get-WorkerInstanceLayout -Name 'alpha' -InstallBase 'C:\Programs' -DataBase 'C:\Data'
$b = Get-WorkerInstanceLayout -Name 'beta' -InstallBase 'C:\Programs' -DataBase 'C:\Data'
foreach ($key in @('InstallRoot', 'DataRoot', 'WorkspaceRoot')) {
    if ($a[$key] -eq $b[$key]) { throw "Instances share $key." }
}
if ($a.WorkspaceRoot -ne (Join-Path $a.DataRoot 'workspace')) { throw 'Workspace is not instance-owned.' }
foreach ($name in @('Alpha', '../escape', 'alpha/beta', 'alpha\beta', 'a*', 'a?', 'a b', ('a' * 33))) {
    $rejected = $false
    try { $null = Get-WorkerInstanceLayout -Name $name -InstallBase 'C:\Programs' -DataBase 'C:\Data' }
    catch { $rejected = $true }
    if (-not $rejected) { throw "Invalid instance name accepted: $name" }
}
# WhatIf exercises the actual entry path without filesystem or task mutations.
& {
    . $installer -Scope User -WhatIf
    if ($script:TaskName -cne 'ClusterYourCodex Worker' -or $script:OwnerMarkerValue -cne 'cyc.dev/windows-worker-install/v1') {
        throw 'Default task or marker compatibility changed.'
    }
}
& {
    . $installer -Scope User -InstanceName alpha -WhatIf
    if ($script:TaskName -cne 'ClusterYourCodex Worker - alpha' -or $script:OwnerMarkerValue -cne 'cyc.dev/windows-worker-install/v1:alpha') {
        throw 'Named task or marker binding is incorrect.'
    }
    if ($DataRoot -notlike '*\worker-instances\alpha' -or $InstallRoot -notlike '*\ClusterYourCodexWorker-instances\alpha') {
        throw 'Named roots were not propagated through the entry point.'
    }
}
$rejected = $false
try { & $installer -Scope User -InstanceName alpha -DataRoot 'C:\wrong-instance-root' -WhatIf }
catch { $rejected = $_.Exception.Message -like '*dedicated default roots*' }
if (-not $rejected) { throw 'Named instance accepted an unrelated root.' }
$rejected = $false
try { & $installer -Scope User -InstanceName alpha -PurgeData -WhatIf }
catch { $rejected = $_.Exception.Message -like '*preserves data*' }
if (-not $rejected) { throw 'Named instance accepted data purge.' }
& {
    foreach ($functionName in @('Get-WorkerTaskSnapshot', 'Stop-AndRemoveTask', 'Restore-WorkerTask')) {
        $definition = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
        }, $true)
        if ($null -eq $definition) { throw "Missing task function: $functionName" }
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $script:TaskName = 'ClusterYourCodex Worker - alpha'
    $script:fixtureTasks = @{
        'ClusterYourCodex Worker' = '<legacy />'
        'ClusterYourCodex Worker - beta' = '<beta />'
        'ClusterYourCodex Worker - alpha' = '<alpha />'
    }
    $script:taskTouches = [Collections.Generic.List[string]]::new()
    function Get-ScheduledTask {
        param($TaskName, $TaskPath, $ErrorAction)
        if ($script:fixtureTasks.ContainsKey($TaskName)) { [pscustomobject]@{TaskPath='\'; State='Ready'} }
    }
    function Export-ScheduledTask { param($TaskName, $TaskPath) $script:fixtureTasks[$TaskName] }
    function Assert-WorkerTaskOwnership { param($Task, $Executable, $Config, $WorkingDirectory, $ResolvedScope) }
    function Stop-ScheduledTask { param($TaskName, $TaskPath, $ErrorAction) $script:taskTouches.Add($TaskName) }
    function Unregister-ScheduledTask {
        param($TaskName, $TaskPath, [switch]$Confirm)
        $script:taskTouches.Add($TaskName)
        $script:fixtureTasks.Remove($TaskName)
    }
    function Register-ScheduledTask {
        param($TaskName, $TaskPath, $Xml, [switch]$Force)
        $script:taskTouches.Add($TaskName)
        $script:fixtureTasks[$TaskName] = $Xml
    }
    $taskArguments = @{Executable='C:\fixture\worker.exe'; Config='C:\fixture\config.json'; WorkingDirectory='C:\fixture\workspace'; ResolvedScope='User'}
    $snapshot = Get-WorkerTaskSnapshot @taskArguments
    if ($snapshot.Xml -cne '<alpha />') { throw 'Snapshot selected a different instance.' }
    Stop-AndRemoveTask @taskArguments
    if ($script:fixtureTasks.ContainsKey($script:TaskName)) { throw 'Selected task was not removed.' }
    Restore-WorkerTask -Snapshot $snapshot @taskArguments
    if ($script:fixtureTasks[$script:TaskName] -cne '<alpha />') { throw 'Selected task was not restored.' }
    if ($script:fixtureTasks['ClusterYourCodex Worker'] -cne '<legacy />' -or $script:fixtureTasks['ClusterYourCodex Worker - beta'] -cne '<beta />') {
        throw 'Lifecycle changed another instance.'
    }
    if ($script:taskTouches.Count -ne 3 -or @($script:taskTouches | Where-Object { $_ -cne $script:TaskName }).Count) {
        throw 'Lifecycle touched an unexpected task name.'
    }
}
Write-Output 'Windows worker instance layout, transaction and task-selection tests passed (mock tasks; no live task changes).'
