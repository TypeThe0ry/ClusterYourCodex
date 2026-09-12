#requires -Version 5.1
[CmdletBinding()]
param([string]$PrivateFunctionSource)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Native SYSTEM ACL acceptance requires an elevated administrator.'
}
if (-not $PrivateFunctionSource) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Install-Worker.ps1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Installer syntax invalid.' }
    $names = @('Resolve-NormalizedPath', 'Test-ReparsePoint', 'Assert-PathChainNoReparse',
        'Assert-CreationPathNoReparse', 'Get-PrivatePrincipalSids', 'Get-PrivateOwnerSid', 'New-PrivateAcl',
        'Set-AclPortable', 'Assert-PrivateAcl', 'Protect-Directory', 'Protect-File')
    $PrivateFunctionSource = ($names | ForEach-Object {
        $name = $_
        $matches = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true))
        if ($matches.Count -ne 1) { throw "Missing installer function $name" }
        $matches[0].Extent.Text
    }) -join "`n"
}
. ([scriptblock]::Create($PrivateFunctionSource))
$root = Join-Path $env:ProgramData ('ClusterYourCodex-native-acl-' + [Guid]::NewGuid().ToString('N'))
Protect-Directory -Path $root
$helperPath = Join-Path $root 'probe.ps1'
$receiptPath = Join-Path $root 'receipt.json'
$body = @'
$ErrorActionPreference = 'Stop'
if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18') { throw 'Wrong runtime identity' }
$data = Join-Path $PSScriptRoot 'private-data'
Protect-Directory -Path $data
$file = Join-Path $data 'probe.txt'
[IO.File]::WriteAllText($file, 'CYC_SYSTEM_ACL_PROBE')
Protect-File -Path $file -NewlyCreated
Protect-Directory -Path $data
Protect-File -Path $file
$acl = Get-Acl -LiteralPath $file
$receipt = @{ sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value; owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value; protected = $acl.AreAccessRulesProtected; ruleCount = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])).Count; contentMatches = ([IO.File]::ReadAllText($file) -ceq 'CYC_SYSTEM_ACL_PROBE') }
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'receipt.json'), ($receipt | ConvertTo-Json))
'@
[IO.File]::WriteAllText($helperPath, ($PrivateFunctionSource + "`n" + $body), (New-Object Text.UTF8Encoding($false)))
Protect-File -Path $helperPath -NewlyCreated
$taskName = 'ClusterYourCodex Native ACL ' + [Guid]::NewGuid().ToString('N')
$registered = $false
try {
    $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $helperPath + '"')
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $taskPrincipal -Settings $settings | Out-Null
    $registered = $true
    Start-ScheduledTask -TaskName $taskName
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    do {
        Start-Sleep -Seconds 1
        $task = Get-ScheduledTask -TaskName $taskName
        if ((Test-Path -LiteralPath $receiptPath) -and $task.State -notin @('Running', 'Queued')) { break }
        [Console]::Error.WriteLine('CYC_NATIVE_SYSTEM_ACL_WAIT')
    } while ([DateTime]::UtcNow -lt $deadline)
    $info = Get-ScheduledTaskInfo -TaskName $taskName
    if ($task.State -in @('Running', 'Queued') -or $info.LastTaskResult -ne 0 -or -not (Test-Path -LiteralPath $receiptPath)) {
        throw "Native SYSTEM ACL probe did not pass; evidence: $root"
    }
    $receipt = [IO.File]::ReadAllText($receiptPath) | ConvertFrom-Json
    if ($receipt.sid -cne 'S-1-5-18' -or $receipt.owner -cne 'S-1-5-18' -or -not $receipt.protected -or $receipt.ruleCount -ne 1 -or -not $receipt.contentMatches) {
        throw "Native SYSTEM ACL receipt invalid; evidence: $root"
    }
    [pscustomobject]@{ passed = $true; evidence = $root; sid = $receipt.sid; owner = $receipt.owner; ruleCount = $receipt.ruleCount } | ConvertTo-Json -Compress
} finally {
    if ($registered) {
        $task = Get-ScheduledTask -TaskName $taskName
        if ($task.State -in @('Running', 'Queued')) { Stop-ScheduledTask -TaskName $taskName }
        $task = Get-ScheduledTask -TaskName $taskName
        if ($task.State -notin @('Running', 'Queued')) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false }
    }
    # Preserve the tiny protected evidence tree; never touch existing worker data.
}
