#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Install-Worker.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Installer syntax invalid.' }
# This is an ordering contract, not evidence of a native SYSTEM repair.
# The administrator must return from dispatch before touching SYSTEM-owned roots.
$dispatchCalls = @($ast.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
    $node.GetCommandName() -eq 'Invoke-SystemWorkerLifecycle'
}, $true))
$preflightCalls = @($ast.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
    $node.GetCommandName() -eq 'Assert-ExistingPrivateDirectory'
}, $true))
if ($dispatchCalls.Count -ne 1 -or $preflightCalls.Count -ne 3) {
    throw 'Unexpected SYSTEM dispatch or lifecycle preflight structure.'
}
foreach ($call in $preflightCalls) {
    if ($dispatchCalls[0].Extent.EndOffset -ge $call.Extent.StartOffset) {
        throw 'SYSTEM dispatch must precede every root ownership preflight.'
    }
}
$dispatchBlock = $dispatchCalls[0].Parent.Parent
if ($dispatchBlock -isnot [System.Management.Automation.Language.StatementBlockAst] -or
    $dispatchBlock.Statements[-1] -isnot [System.Management.Automation.Language.ReturnStatementAst]) {
    throw 'Administrator dispatch must return before root ownership preflight.'
}
$names = @('Invoke-SystemWorkerLifecycle', 'Resolve-NormalizedPath', 'Test-ReparsePoint', 'Assert-PathChainNoReparse',
    'Assert-CreationPathNoReparse', 'Get-PrivatePrincipalSids', 'Get-PrivateOwnerSid', 'New-PrivateAcl', 'Set-AclPortable',
    'Assert-PrivateAcl', 'Protect-Directory', 'Protect-File')
foreach ($name in $names) {
    $found = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true))
    if ($found.Count -ne 1) { throw "Missing function $name" }
    . ([scriptblock]::Create($found[0].Extent.Text))
}
# Task Scheduler is a fixture. Filesystem and private ACL operations are real;
# this test does not claim to launch an actual SYSTEM process.
$script:mode = 'success'
$script:isAdmin = $true
$script:registered = $false
$script:stopped = $false
$script:workdir = ''
function Test-IsAdministrator { return $script:isAdmin }
function Read-KitManifest {
    param($Root)
    $script:validatedRoots += $Root
    if ($script:mode -eq 'reject-copy' -and $script:validatedRoots.Count -eq 2) { throw 'Copied kit validation rejected fixture' }
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'worker-kit.sig'))) { throw 'Missing signature fixture' }
}
function Read-WorkerUtf8Json { param($Path, $Label, $MaximumBytes) return ([System.IO.File]::ReadAllText($Path) | ConvertFrom-Json) }
function New-ScheduledTaskAction {
    param($Execute, $Argument, $WorkingDirectory)
    if ($Argument -notmatch '^-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "[^"]+lifecycle.ps1"$') { throw 'Unexpected task arguments' }
    $script:workdir = $WorkingDirectory
    return @{ Execute = $Execute; Argument = $Argument }
}
function New-ScheduledTaskPrincipal {
    param($UserId, $LogonType, $RunLevel)
    if ($UserId -cne 'SYSTEM' -or $LogonType -cne 'ServiceAccount' -or $RunLevel -cne 'Highest') { throw 'Wrong service identity' }
    return @{}
}
function New-ScheduledTaskSettingsSet { param($MultipleInstances, $ExecutionTimeLimit, [switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries) return @{} }
function Register-ScheduledTask {
    param($TaskName, $TaskPath, $Action, $Principal, $Settings)
    if ($script:validatedRoots.Count -ne 2 -or $script:validatedRoots[1] -cne (Join-Path $script:workdir 'kit')) {
        throw 'Copied kit was not validated before dispatch'
    }
    $script:registered = $true
}
function Start-ScheduledTask {
    param($TaskName, $TaskPath)
    $request = [System.IO.File]::ReadAllText((Join-Path $script:workdir 'request.json')) | ConvertFrom-Json
    if ($request.Scope -cne 'System' -or -not $request.PairOnly) { throw 'Lost lifecycle parameters' }
    if (@(Get-ChildItem -LiteralPath $request.BundleRoot -File).Count -ne 5) { throw 'Kit copy incomplete' }
    if ($request.EnrollmentFile -cne (Join-Path $script:workdir 'enrollment.json')) { throw 'Enrollment was not staged locally' }
    if ([System.IO.File]::ReadAllText($request.EnrollmentFile) -cne 'synthetic-enrollment-fixture') { throw 'Enrollment bytes changed' }
    Assert-PrivateAcl -Item (Get-Item -LiteralPath $request.EnrollmentFile) -Directory $false
    $helperErrors = $null
    $helperTokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:workdir 'lifecycle.ps1'), [ref]$helperTokens, [ref]$helperErrors)
    if ($helperErrors.Count) { throw 'Generated SYSTEM helper syntax invalid' }
    if ($script:mode -in @('timeout', 'crash')) { return }
    $result = @{ succeeded = ($script:mode -eq 'success'); output = 'fixture lifecycle receipt'; line = 12 }
    [System.IO.File]::WriteAllText((Join-Path $script:workdir 'result.json'), ($result | ConvertTo-Json))
}
function Get-ScheduledTask {
    param($TaskName, $TaskPath, $ErrorAction)
    $script:pollCount++
    return [pscustomobject]@{ State = $(if ($script:mode -eq 'timeout' -and -not $script:stopped -and $script:pollCount -gt 1) { 'Running' } else { 'Ready' }) }
}
function Get-ScheduledTaskInfo {
    param($TaskName, $TaskPath)
    return [pscustomobject]@{
        LastRunTime = $(if ($script:mode -eq 'timeout') { [DateTime]::MinValue } else { [DateTime]::Now })
        LastTaskResult = $(if ($script:mode -eq 'success') { 0 } else { 1 })
    }
}
function Stop-ScheduledTask { param($TaskName, $TaskPath, $ErrorAction) $script:stopped = $true }
function Unregister-ScheduledTask { param($TaskName, $TaskPath, $Confirm) $script:registered = $false }

$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('cyc-system-dispatch-test-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $fixtureRoot)
$bundle = Join-Path $fixtureRoot 'source'
[void](New-Item -ItemType Directory -Path $bundle)
foreach ($name in @('Install-Worker.ps1', 'cyc-worker.exe', 'worker-kit.json', 'worker-kit.sig', 'SHA256SUMS')) {
    [System.IO.File]::WriteAllText((Join-Path $bundle $name), 'fixture')
}
$enrollment = Join-Path $fixtureRoot 'source-enrollment.json'
[System.IO.File]::WriteAllText($enrollment, 'synthetic-enrollment-fixture')
foreach ($mode in @('success', 'failure', 'timeout', 'crash')) {
    $script:mode = $mode
    $script:stopped = $false
    $script:pollCount = 0
    $script:validatedRoots = @()
    $parameters = @{ BundleRoot = $bundle; Scope = 'System'; Action = 'Install'; PairOnly = $true; EnrollmentFile = $enrollment }
    $failed = $false
    $failureMessage = ''
    $output = ''
    $priorStderr = [Console]::Error
    $capturedStderr = New-Object System.IO.StringWriter
    $timeout = if ($mode -eq 'timeout') { 6 } else { 1 }
    try {
        [Console]::SetError($capturedStderr)
        $output = Invoke-SystemWorkerLifecycle -Parameters $parameters -HandoffParent $fixtureRoot -TimeoutSeconds $timeout
    }
    catch { $failed = $true; $failureMessage = $_.Exception.Message }
    finally { [Console]::SetError($priorStderr) }
    if ($failed -ne ($mode -ne 'success')) { throw "Unexpected outcome for $mode (message=$failureMessage; output=$($output | Out-String); roots=$($script:validatedRoots -join '|'); workdir=$script:workdir)" }
    if ($script:registered) { throw "Scheduler task leaked for $mode" }
    if ($mode -eq 'crash' -and ($failureMessage -notmatch 'exited without a receipt' -or $script:stopped)) {
        throw 'A completed failed helper without a receipt must fail immediately, not time out or be stopped again'
    }
    if ($mode -eq 'success') {
        if ($output -cne 'fixture lifecycle receipt' -or (Test-Path -LiteralPath $script:workdir)) { throw 'Success receipt/cleanup failed' }
    } elseif (-not (Test-Path -LiteralPath (Join-Path $script:workdir 'request.json'))) { throw 'Failure evidence was discarded' }
    if ($mode -eq 'timeout' -and -not $script:stopped) { throw 'Timed-out helper was not stopped' }
    if ($mode -eq 'timeout' -and $capturedStderr.ToString().Trim() -cne 'CYC_SYSTEM_LIFECYCLE_WAIT') {
        throw 'Missing or nonconstant SSH keepalive marker'
    }
    $capturedStderr.Dispose()
}
if (-not (Test-Path -LiteralPath $enrollment)) { throw 'Original enrollment was removed by handoff' }
$script:mode = 'reject-copy'
$script:validatedRoots = @()
$rejectedCopy = $false
try { Invoke-SystemWorkerLifecycle -Parameters @{ BundleRoot = $bundle } -HandoffParent $fixtureRoot }
catch { $rejectedCopy = $_.Exception.Message -eq 'Copied kit validation rejected fixture' }
if (-not $rejectedCopy -or $script:registered) { throw 'Rejected copied kit reached dispatch' }
$script:isAdmin = $false
$denied = $false
try { Invoke-SystemWorkerLifecycle -Parameters @{ BundleRoot = $bundle } -HandoffParent $fixtureRoot } catch { $denied = $true }
if (-not $denied -or $script:registered) { throw 'Non-admin dispatch was not rejected' }
# Execute the exact production request decoder in Windows PowerShell 5.1,
# without replacing the helper's SYSTEM identity guard or invoking a lifecycle.
$helpers = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
        $node.Value.Contains("SYSTEM_LIFECYCLE_FAILED") -and $node.Value.Contains('$request =')
}, $true))
if ($helpers.Count -ne 1) { throw 'Missing generated helper source' }
$decoder = [regex]::Match($helpers[0].Value, '(?m)^\s*\$request = [^\r\n]+').Value
$encodingRoot = Join-Path $fixtureRoot 'encoding'
[void](New-Item -ItemType Directory -Path $encodingRoot)
$unicodePath = 'C:\' + [char]0x6d4b + [char]0x8bd5 + '\worker'
$requestText = @{ DataRoot = $unicodePath; EnrollmentFile = ($unicodePath + '\enrollment.json') } | ConvertTo-Json
[System.IO.File]::WriteAllText((Join-Path $encodingRoot 'request.json'), $requestText, (New-Object System.Text.UTF8Encoding($false)))
$decoderScript = '$ErrorActionPreference = "Stop"' + "`n" + $decoder + "`n" +
    '[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot "decoded.json"), ($request | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))'
$decoderPath = Join-Path $encodingRoot 'decode.ps1'
[System.IO.File]::WriteAllText($decoderPath, $decoderScript)
& (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -File $decoderPath
if ($LASTEXITCODE -ne 0) { throw 'Windows PowerShell request decoding failed' }
$decoded = [System.IO.File]::ReadAllText((Join-Path $encodingRoot 'decoded.json')) | ConvertFrom-Json
if ($decoded.DataRoot -cne $unicodePath -or $decoded.EnrollmentFile -cne ($unicodePath + '\enrollment.json')) {
    throw 'Non-ASCII lifecycle paths changed during decoding'
}
Write-Output "SYSTEM lifecycle dispatch fixture passed; evidence retained at $fixtureRoot"
