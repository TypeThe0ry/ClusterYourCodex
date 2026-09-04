#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$WorkRoot,
    [ValidateRange(30, 3600)]
    [int]$TimeoutSeconds = 180,
    [switch]$KeepEvidence,
    [switch]$SelfTest,
    [string]$CycBin,
    [string]$ControllerBin,
    [string]$WorkerBin,
    [string]$CargoTargetDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This probe is deliberately self-contained.  It does not use the installed
# controller data directory, remembered credentials, Scheduled Tasks, or a
# pre-existing worker config.  The only live network it needs is a private
# address already assigned to this Windows host: the controller rejects a
# loopback worker listener by contract.
$script:State = [ordered]@{
    RootCreated = $false
    Passed = $false
    Failure = $null
    JobRoot = $null
    WorkRoot = $null
    RepositoryRoot = $null
    LogRoot = $null
    EvidenceRoot = $null
    IdentityRoot = $null
    WorkerRoot = $null
    WorkspaceRoot = $null
    SourceRoot = $null
    DownloadRoot = $null
    ControllerDb = $null
    ControllerToken = $null
    Certificate = $null
    PrivateKey = $null
    Enrollment = $null
    WorkerConfig = $null
    SnapshotArchive = $null
    JobSpec = $null
    ControllerUrl = $null
    WorkerUrl = $null
    WorkerIp = $null
    WorkerPort = $null
    ControllerPort = $null
    PairingId = $null
    NodeId = $null
    JobId = $null
    RunId = $null
    WorkerCredential = $null
    StagedCredential = $null
    FinalJob = $null
    Cleanup = $null
    RunDurationSeconds = $null
    ProcessesStopped = $false
    ObservedStates = [System.Collections.Generic.List[string]]::new()
    OwnedProcesses = [System.Collections.Generic.List[object]]::new()
    Checks = [ordered]@{
        privateJobRootAcl = $false
        controllerHealth = $false
        tlsIdentity = $false
        pairingReady = $false
        nodeReport = $false
        jobClaimed = $false
        heartbeatWindow = $false
        completion = $false
        logs = $false
        artifact = $false
        cleanup = $false
        routeTrace = $false
        processCleanup = $false
        secretScan = $false
    }
}

function Fail-RoundTrip {
    param([Parameter(Mandatory)][string]$Message)
    throw $Message
}

function Test-IsWindowsHost {
    $platform = [Environment]::OSVersion.Platform
    return $platform -eq [PlatformID]::Win32NT
}

function Test-PrivateIpv4 {
    param([Parameter(Mandatory)][string]$Address)
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Address, [ref]$parsed)) { return $false }
    if ($parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $false }
    $bytes = $parsed.GetAddressBytes()
    if ($bytes[0] -eq 10) { return $true }
    if ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) { return $true }
    return $bytes[0] -eq 192 -and $bytes[1] -eq 168
}

function Get-PrivateIpv4Address {
    $candidates = @()
    try {
        $candidates = @(Get-NetIPAddress -AddressFamily IPv4 -Type Unicast -ErrorAction Stop |
            Select-Object -ExpandProperty IPAddress)
    } catch {
        # A minimal Windows image may not expose NetTCPIP cmdlets.  The live
        # path stays fail-closed rather than falling back to a guessed address.
        $candidates = @()
    }
    foreach ($candidate in $candidates) {
        if (Test-PrivateIpv4 -Address ([string]$candidate)) {
            return [string]$candidate
        }
    }
    Fail-RoundTrip 'no assigned RFC1918 IPv4 address is available for the worker TLS listener'
}

function Get-FreeTcpPort {
    param([Parameter(Mandatory)][string]$Address)
    $ip = [Net.IPAddress]::Parse($Address)
    $listener = [Net.Sockets.TcpListener]::new($ip, 0)
    try {
        $listener.Start()
        return ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally {
        $listener.Stop()
    }
}

function Test-ValidGuid {
    param([AllowNull()][string]$Value)
    $parsed = [Guid]::Empty
    return [Guid]::TryParse($Value, [ref]$parsed)
}

function Test-DirectDirectory {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Label)
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if (-not $item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        Fail-RoundTrip "$Label must be a direct directory"
    }
    return $item.FullName
}

function Resolve-DirectFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Label)
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $item = Get-Item -LiteralPath $resolved.Path -ErrorAction Stop
    if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        Fail-RoundTrip "$Label must be a direct regular file"
    }
    return $item.FullName
}

function Assert-DirectOwnedFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail-RoundTrip "$Label does not exist"
    }
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail-RoundTrip "$Label is a reparse point"
    }
    return $item
}

function Protect-PrivateDirectory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-IsWindowsHost)) { return }

    $item = [IO.DirectoryInfo]::new($Path)
    $item.Refresh()
    if (-not $item.Exists -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        Fail-RoundTrip 'job root must be a direct directory before ACL hardening'
    }
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $replacement = [Security.AccessControl.DirectorySecurity]::new()
    $replacement.SetOwner($user)
    $replacement.SetAccessRuleProtection($true, $false)
    foreach ($principal in @($user, $system)) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $principal,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow)
        [void]$replacement.AddAccessRule($rule)
    }
    if ($item.PSObject.Methods.Name -contains 'SetAccessControl') {
        $item.SetAccessControl($replacement)
    } else {
        [IO.FileSystemAclExtensions]::SetAccessControl($item, $replacement)
    }

    # Re-read after the write. Windows PowerShell can cache the original
    # descriptor on a FileSystemInfo instance.
    $item = [IO.DirectoryInfo]::new($Path)
    $item.Refresh()
    if ($item.PSObject.Methods.Name -contains 'GetAccessControl') {
        $acl = $item.GetAccessControl()
    } else {
        $acl = [IO.FileSystemAclExtensions]::GetAccessControl($item)
    }
    if (-not $acl.AreAccessRulesProtected -or
        $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $user.Value) {
        Fail-RoundTrip 'job root ACL is not protected and owned by the current user'
    }
    $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    if ($rules.Count -ne 2) { Fail-RoundTrip 'job root ACL did not reduce to the current user and SYSTEM' }
    $expected = @{$user.Value = $false; 'S-1-5-18' = $false}
    foreach ($rule in $rules) {
        $sid = $rule.IdentityReference.Value
        if (-not $expected.ContainsKey($sid) -or $expected[$sid] -or $rule.IsInherited -or
            $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            $rule.InheritanceFlags -ne $inheritance -or
            $rule.PropagationFlags -ne [Security.AccessControl.PropagationFlags]::None -or
            [int64]$rule.FileSystemRights -ne 0x001F01FFL) {
            Fail-RoundTrip 'job root ACL did not match the exact current-user and SYSTEM allowlist'
        }
        $expected[$sid] = $true
    }
    if ($expected.Values -contains $false) { Fail-RoundTrip 'job root ACL missed a required principal' }
    $script:State.Checks.privateJobRootAcl = $true
}

function ConvertTo-WindowsArgument {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $slashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($slashes * 2) + 1)))
            [void]$builder.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) { [void]$builder.Append(('\' * $slashes)); $slashes = 0 }
        [void]$builder.Append($character)
    }
    if ($slashes -gt 0) { [void]$builder.Append(('\' * ($slashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function New-ProcessStartInfo {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [hashtable]$Environment
    )
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $argumentProperty = $psi.PSObject.Properties['ArgumentList']
    if ($null -ne $argumentProperty) {
        foreach ($argument in $ArgumentList) { [void]$psi.ArgumentList.Add([string]$argument) }
    } else {
        $psi.Arguments = (($ArgumentList | ForEach-Object { ConvertTo-WindowsArgument ([string]$_) }) -join ' ')
    }
    if ($null -ne $Environment) {
        foreach ($key in $Environment.Keys) { $psi.EnvironmentVariables[[string]$key] = [string]$Environment[$key] }
    }
    return $psi
}

function Write-Utf8NoBom {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Invoke-CapturedCommand {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$StdoutPath,
        [Parameter(Mandatory)][string]$StderrPath,
        [Parameter(Mandatory)][int]$Timeout,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [hashtable]$Environment
    )
    $psi = New-ProcessStartInfo -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory -Environment $Environment
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    if (-not $process.Start()) { Fail-RoundTrip "failed to start $Label" }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $timedOut = -not $process.WaitForExit($Timeout * 1000)
    if ($timedOut) {
        [void](Stop-ProcessTreeWithFallback -Process $process)
        $process.WaitForExit(5000)
    }
    $stdoutComplete = $stdoutTask.Wait(5000)
    $stderrComplete = $stderrTask.Wait(5000)
    $drainTimedOut = -not ($stdoutComplete -and $stderrComplete)
    $stdout = if ($stdoutComplete) {
        $stdoutTask.GetAwaiter().GetResult()
    } else {
        '[stdout drain timed out; process tree cleanup is not proven]'
    }
    $stderr = if ($stderrComplete) {
        $stderrTask.GetAwaiter().GetResult()
    } else {
        '[stderr drain timed out; process tree cleanup is not proven]'
    }
    Write-Utf8NoBom -Path $StdoutPath -Content $stdout
    Write-Utf8NoBom -Path $StderrPath -Content $stderr
    $exitCode = if ($timedOut -or $drainTimedOut) { 124 } else { $process.ExitCode }
    $process.Dispose()
    return [pscustomobject]@{
        Label = $Label
        ExitCode = $exitCode
        TimedOut = $timedOut
        OutputDrainTimedOut = $drainTimedOut
    }
}

function Invoke-TaskkillTree {
    param([Parameter(Mandatory)][int]$ProcessId)
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = if ([string]::IsNullOrWhiteSpace([string]$env:SystemRoot)) {
        'taskkill.exe'
    } else {
        Join-Path $env:SystemRoot 'System32\taskkill.exe'
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $arguments = @('/PID', [string]$ProcessId, '/T', '/F')
    $argumentProperty = $psi.PSObject.Properties['ArgumentList']
    if ($null -ne $argumentProperty) {
        foreach ($argument in $arguments) { [void]$psi.ArgumentList.Add($argument) }
    } else {
        $psi.Arguments = (($arguments | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' ')
    }
    $killer = [Diagnostics.Process]::new()
    $killer.StartInfo = $psi
    try {
        if (-not $killer.Start()) { return $false }
        $stdoutTask = $killer.StandardOutput.ReadToEndAsync()
        $stderrTask = $killer.StandardError.ReadToEndAsync()
        $finished = $killer.WaitForExit(10000)
        if (-not $finished) { try { $killer.Kill() } catch {} }
        $stdoutComplete = $stdoutTask.Wait(5000)
        $stderrComplete = $stderrTask.Wait(5000)
        if (-not ($stdoutComplete -and $stderrComplete)) { return $false }
        [void]$stdoutTask.GetAwaiter().GetResult()
        [void]$stderrTask.GetAwaiter().GetResult()
        return $finished
    } catch {
        return $false
    } finally {
        try { $killer.Dispose() } catch {}
    }
}

function Stop-ProcessTreeWithFallback {
    param([Parameter(Mandatory)][Diagnostics.Process]$Process)
    try {
        if ($Process.HasExited) { return $true }
    } catch {
        return $false
    }
    try {
        # Process.Kill(bool) is available on the .NET runtime used by pwsh.
        # Windows PowerShell 5.1 falls through to taskkill /T /F instead of
        # silently leaving a worker-launched powershell.exe behind.
        $Process.Kill($true)
        return $true
    } catch {}
    $killed = Invoke-TaskkillTree -ProcessId $Process.Id
    try { if ($Process.HasExited) { return $true } } catch {}
    return $killed
}

function Start-OwnedProcess {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$StdoutPath,
        [Parameter(Mandatory)][string]$StderrPath,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [hashtable]$Environment
    )
    $psi = New-ProcessStartInfo -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory -Environment $Environment
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    if (-not $process.Start()) { Fail-RoundTrip "failed to start $Label" }
    $record = [pscustomobject]@{
        Label = $Label
        FilePath = (Resolve-DirectFile -Path $FilePath -Label "$Label executable")
        Process = $process
        Pid = $process.Id
        StartTimeUtc = $process.StartTime.ToUniversalTime()
        StdoutTask = $process.StandardOutput.ReadToEndAsync()
        StderrTask = $process.StandardError.ReadToEndAsync()
        StdoutPath = $StdoutPath
        StderrPath = $StderrPath
    }
    $script:State.OwnedProcesses.Add($record)
    return $record
}

function Flush-OwnedProcess {
    param([Parameter(Mandatory)]$Record)
    if (-not $Record.StdoutTask.Wait(5000) -or -not $Record.StderrTask.Wait(5000)) {
        Fail-RoundTrip "output drain timed out for $($Record.Label); process cleanup is not proven"
    }
    $stdout = $Record.StdoutTask.GetAwaiter().GetResult()
    $stderr = $Record.StderrTask.GetAwaiter().GetResult()
    Write-Utf8NoBom -Path $Record.StdoutPath -Content $stdout
    Write-Utf8NoBom -Path $Record.StderrPath -Content $stderr
}

function Test-OwnedProcessAlive {
    param([Parameter(Mandatory)]$Record)
    try { return -not $Record.Process.HasExited } catch { return $false }
}

function Test-RecordedProcessIdentity {
    param([Parameter(Mandatory)]$Record)
    try {
        $current = Get-Process -Id $Record.Pid -ErrorAction Stop
        $path = $current.Path
        if ([string]::IsNullOrWhiteSpace([string]$path)) { return $false }
        $resolved = (Resolve-Path -LiteralPath $path -ErrorAction Stop).Path
        if (-not [string]::Equals($resolved, $Record.FilePath, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        $delta = [Math]::Abs(($current.StartTime.ToUniversalTime() - $Record.StartTimeUtc).TotalSeconds)
        return $delta -lt 2
    } catch {
        return $false
    }
}

function Get-ProcessTreeSnapshot {
    param([Parameter(Mandatory)][int]$RootPid)
    try {
        $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
    } catch {
        return [pscustomobject]@{ Available = $false; ProcessIds = @() }
    }
    $children = @{}
    foreach ($process in $processes) {
        $parentPid = [int]$process.ParentProcessId
        if (-not $children.ContainsKey($parentPid)) {
            $children[$parentPid] = [System.Collections.Generic.List[int]]::new()
        }
        [void]$children[$parentPid].Add([int]$process.ProcessId)
    }
    $descendants = [System.Collections.Generic.HashSet[int]]::new()
    $queue = [System.Collections.Generic.Queue[int]]::new()
    $queue.Enqueue($RootPid)
    while ($queue.Count -gt 0) {
        $parentPid = $queue.Dequeue()
        if (-not $children.ContainsKey($parentPid)) { continue }
        foreach ($childPid in $children[$parentPid]) {
            if ($descendants.Add($childPid)) { $queue.Enqueue($childPid) }
        }
    }
    return [pscustomobject]@{ Available = $true; ProcessIds = @($descendants) }
}

function Stop-OwnedProcesses {
    if ($script:State.ProcessesStopped) { return $script:State.Checks.processCleanup }
    $clean = $true
    foreach ($record in @($script:State.OwnedProcesses)) {
        $beforeTree = Get-ProcessTreeSnapshot -RootPid $record.Pid
        if (-not $beforeTree.Available) { $clean = $false }
        try {
            if (-not $record.Process.HasExited) {
                if (-not (Test-RecordedProcessIdentity -Record $record)) {
                    $clean = $false
                } elseif (-not (Stop-ProcessTreeWithFallback -Process $record.Process)) {
                    $clean = $false
                }
                [void]$record.Process.WaitForExit(10000)
            }
            if (-not $record.Process.HasExited) { $clean = $false }
        } catch { $clean = $false }
        try { Flush-OwnedProcess -Record $record } catch { $clean = $false }
        try {
            $stillThere = Get-Process -Id $record.Pid -ErrorAction SilentlyContinue
            if ($null -ne $stillThere) { $clean = $false }
        } catch { $clean = $false }
        # If the root exited before taskkill ran, Windows may re-parent a
        # surviving child and it would no longer appear beneath the root PID.
        # Check every PID observed before termination so that this case cannot
        # be reported as clean merely because the parent disappeared.
        foreach ($childPid in @($beforeTree.ProcessIds)) {
            try {
                if ($null -ne (Get-Process -Id ([int]$childPid) -ErrorAction SilentlyContinue)) { $clean = $false }
            } catch { $clean = $false }
        }
        $afterTree = Get-ProcessTreeSnapshot -RootPid $record.Pid
        if (-not $afterTree.Available -or $afterTree.ProcessIds.Count -gt 0) { $clean = $false }
    }
    $script:State.Checks.processCleanup = $clean
    if ($clean) { $script:State.ProcessesStopped = $true }
    return $clean
}

function Get-JsonDocument {
    param([Parameter(Mandatory)][string]$Path)
    Assert-DirectOwnedFile -Path $Path -Label 'JSON evidence file' | Out-Null
    try { return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json) }
    catch { Fail-RoundTrip "invalid JSON in $Path" }
}

function Get-JsonField {
    param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][string]$Path)
    $value = $Document
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $value) { return $null }
        $property = $value.PSObject.Properties[$part]
        if ($null -eq $property) { return $null }
        $value = $property.Value
    }
    return $value
}

function Invoke-CycJson {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$Authenticated
    )
    $prefix = @('--controller', $script:State.ControllerUrl)
    if ($Authenticated) { $prefix += @('--token-file', $script:State.ControllerToken) }
    $stdout = Join-Path $script:State.EvidenceRoot "$Label.stdout.json"
    $stderr = Join-Path $script:State.LogRoot "$Label.stderr.log"
    $result = Invoke-CapturedCommand -Label $Label -FilePath $script:State.CycBin `
        -ArgumentList ($prefix + $Arguments) -StdoutPath $stdout -StderrPath $stderr `
        -Timeout ([Math]::Min($script:State.TimeoutSeconds, 120)) -WorkingDirectory $script:State.RepositoryRoot
    if ($result.ExitCode -ne 0) { Fail-RoundTrip "$Label failed (exit $($result.ExitCode)); inspect evidence/logs" }
    return Get-JsonDocument -Path $stdout
}

function Wait-TcpListener {
    param([Parameter(Mandatory)][string]$Address, [Parameter(Mandatory)][int]$Port, [Parameter(Mandatory)][int]$Seconds)
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $client = [Net.Sockets.TcpClient]::new()
        try {
            $task = $client.ConnectAsync($Address, $Port)
            if ($task.Wait(1000) -and $client.Connected) { return $true }
        } catch {} finally { $client.Dispose() }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Wait-ControllerHealth {
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    $last = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $last = Invoke-CycJson -Label 'controller-health' -Arguments @('health')
            if ([string](Get-JsonField $last 'status') -ceq 'ok') {
                $script:State.Checks.controllerHealth = $true
                return
            }
        } catch {}
        Start-Sleep -Milliseconds 250
    }
    Fail-RoundTrip 'controller health did not become ready before timeout'
}

function Wait-PairReady {
    $deadline = [DateTime]::UtcNow.AddSeconds($script:State.TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $status = Invoke-CycJson -Label 'pair-status' -Arguments @('pair', 'status', $script:State.PairingId) -Authenticated
            $phase = [string](Get-JsonField $status 'phase')
            if ($phase -in @('failed', 'expired', 'revoked')) { Fail-RoundTrip "pairing entered terminal phase $phase" }
            if ($phase -ceq 'ready' -and (Get-JsonField $status 'ready') -eq $true -and
                [string](Get-JsonField $status 'nodeId') -ceq $script:State.NodeId) {
                $script:State.Checks.pairingReady = $true
                return
            }
        } catch {
            if ($_.Exception.Message -like 'pairing entered terminal phase*') { throw }
        }
        Start-Sleep -Milliseconds 500
    }
    Fail-RoundTrip 'pairing did not become ready before timeout'
}

function Wait-NodeReport {
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not (Test-OwnedProcessAlive -Record $script:State.WorkerProcess)) {
            Fail-RoundTrip 'worker process exited before node report'
        }
        try {
            $fleet = Invoke-CycJson -Label 'fleet' -Arguments @('nodes') -Authenticated
            foreach ($node in @((Get-JsonField $fleet 'nodes'))) {
                $lastSeen = [DateTimeOffset]::MinValue
                [void][DateTimeOffset]::TryParse([string](Get-JsonField $node 'lastSeenAt'), [ref]$lastSeen)
                $fresh = $lastSeen -ne [DateTimeOffset]::MinValue -and
                    ([DateTimeOffset]::UtcNow - $lastSeen).TotalSeconds -ge 0 -and
                    ([DateTimeOffset]::UtcNow - $lastSeen).TotalSeconds -le 15
                if ([string](Get-JsonField $node 'id') -ceq $script:State.NodeId -and
                    [string](Get-JsonField $node 'status') -ceq 'online' -and $fresh) {
                    $script:State.Checks.nodeReport = $true
                    return
                }
            }
        } catch {}
        Start-Sleep -Milliseconds 500
    }
    Fail-RoundTrip 'worker node report did not appear in controller fleet'
}

function Wait-NodeCapacity {
    param(
        [ValidateRange(1, 4096)]
        [int]$MinimumCpuCores = 1
    )

    # A hosted Windows runner can still be CPU-saturated for a short period
    # after the release binaries finish compiling. The worker deliberately
    # reports zero allocatable cores while its measured load leaves less than
    # one whole core. Treating that truthful report as a permanent submit
    # failure makes this live round-trip flaky. Wait for the same fresh fleet
    # view that the controller will use, then submit only after the requested
    # minimum headroom is visible. This preserves the fail-closed scheduler
    # contract and keeps the bounded timeout/retry evidence in the job root.
    $deadline = [DateTime]::UtcNow.AddSeconds($script:State.TimeoutSeconds)
    $pollIndex = 0
    $lastAvailable = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not (Test-OwnedProcessAlive -Record $script:State.WorkerProcess)) {
            Fail-RoundTrip 'worker process exited while waiting for schedulable capacity'
        }
        $pollIndex++
        try {
            $fleet = Invoke-CycJson -Label ("fleet-capacity-{0:d4}" -f $pollIndex) `
                -Arguments @('nodes') -Authenticated
            foreach ($view in @((Get-JsonField $fleet 'nodeViews'))) {
                if ($null -eq $view -or [string](Get-JsonField $view 'nodeId') -cne $script:State.NodeId) {
                    continue
                }
                $available = Get-JsonField $view 'effectiveResources.availableCpuCores'
                if ($null -eq $available) {
                    $available = Get-JsonField $view 'telemetry.document.availableCpuCores'
                }
                if ($null -eq $available) { continue }
                try { $lastAvailable = [int64]$available } catch { continue }
                if ($lastAvailable -ge $MinimumCpuCores) { return }
            }
        } catch {
            # The controller/worker pair is still live; transient fleet
            # polling errors are retried until the same bounded deadline.
        }
        Start-Sleep -Seconds 1
    }
    $observed = if ($null -eq $lastAvailable) { 'unknown' } else { [string]$lastAvailable }
    Fail-RoundTrip "worker never exposed $MinimumCpuCores allocatable CPU core(s) before timeout (last observed: $observed)"
}

function Get-RunDurationSeconds {
    param([Parameter(Mandatory)]$Run)
    $started = [DateTimeOffset]::Parse([string](Get-JsonField $Run 'startedAt'))
    $finished = [DateTimeOffset]::Parse([string](Get-JsonField $Run 'finishedAt'))
    $seconds = ($finished - $started).TotalSeconds
    if ($seconds -lt 0) { Fail-RoundTrip 'run finished before it started' }
    return [int][Math]::Floor($seconds)
}

function Wait-JobTerminal {
    $deadline = [DateTime]::UtcNow.AddSeconds($script:State.TimeoutSeconds)
    $pollIndex = 0
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not (Test-OwnedProcessAlive -Record $script:State.WorkerProcess)) {
            Fail-RoundTrip 'worker process exited before job reached a terminal state'
        }
        $pollIndex++
        try {
            $job = Invoke-CycJson -Label ("job-poll-{0:d4}" -f $pollIndex) -Arguments @('jobs', $script:State.JobId) -Authenticated
            $state = [string](Get-JsonField $job 'run.state')
            if (-not $script:State.ObservedStates.Contains($state)) { $script:State.ObservedStates.Add($state) }
            if ($state -in @('preparing', 'running', 'verifying', 'succeeded', 'failed', 'cancelled') -and
                [string](Get-JsonField $job 'run.nodeId') -ceq $script:State.NodeId) {
                $script:State.Checks.jobClaimed = $true
            }
            if ($state -in @('succeeded', 'failed', 'cancelled')) {
                if ($state -cne 'succeeded') { Fail-RoundTrip "job reached non-success terminal state $state" }
                $script:State.FinalJob = $job
                $script:State.RunDurationSeconds = Get-RunDurationSeconds -Run (Get-JsonField $job 'run')
                if ($script:State.RunDurationSeconds -lt 6) { Fail-RoundTrip 'run duration was too short to exercise the heartbeat window' }
                $script:State.Checks.heartbeatWindow = $true
                $script:State.Checks.completion = $true
                return
            }
            if ($state -notin @('queued', 'preparing', 'running', 'verifying')) {
                Fail-RoundTrip "unknown run state from controller: $state"
            }
        } catch {
            if ($_.Exception.Message -like 'job reached non-success*' -or
                $_.Exception.Message -like 'unknown run state*' -or
                $_.Exception.Message -like 'run duration*') { throw }
        }
        Start-Sleep -Seconds 1
    }
    Fail-RoundTrip 'job did not reach terminal state before timeout'
}

function Invoke-CleanupRequest {
    $uri = "$($script:State.ControllerUrl)/v1/jobs/$($script:State.JobId)/cleanup"
    $token = (Get-Content -LiteralPath $script:State.ControllerToken -Raw).Trim()
    $headers = @{ Authorization = "Bearer $token"; Accept = 'application/json' }
    try {
        $document = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -TimeoutSec 10 -ErrorAction Stop
        $path = Join-Path $script:State.EvidenceRoot 'cleanup.json'
        Write-Utf8NoBom -Path $path -Content ($document | ConvertTo-Json -Depth 20)
        return $document
    } catch {
        Fail-RoundTrip 'controller cleanup request failed'
    }
}

function Wait-CleanupReceipt {
    $deadline = [DateTime]::UtcNow.AddSeconds($script:State.TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $cleanup = Invoke-CleanupRequest
            if ([string](Get-JsonField $cleanup 'status') -ceq 'removed' -and
                (Get-JsonField $cleanup 'jobRootDeleted') -eq $true) {
                if ([string](Get-JsonField $cleanup 'jobId') -cne $script:State.JobId -or
                    [string](Get-JsonField $cleanup 'runId') -cne $script:State.RunId -or
                    [string](Get-JsonField $cleanup 'relativeRoot') -cne "jobs/$($script:State.RunId)" -or
                    [string](Get-JsonField $cleanup 'terminalAck.finalState') -cne 'succeeded' -or
                    [string](Get-JsonField $cleanup 'terminalAck.runId') -cne $script:State.RunId) {
                    Fail-RoundTrip 'cleanup receipt did not retain the terminal run binding'
                }
                $jobRoot = Join-Path $script:State.WorkspaceRoot (Join-Path 'jobs' $script:State.RunId)
                if (Test-Path -LiteralPath $jobRoot) { Fail-RoundTrip 'worker job root remains after removed cleanup receipt' }
                $script:State.Cleanup = $cleanup
                $script:State.Checks.cleanup = $true
                return
            }
        } catch {
            if ($_.Exception.Message -like 'cleanup receipt*' -or $_.Exception.Message -like 'worker job root*') { throw }
        }
        Start-Sleep -Milliseconds 500
    }
    Fail-RoundTrip 'controller never recorded a removed cleanup receipt'
}

function Scan-SecretLeaks {
    $secretBytes = [System.Collections.Generic.List[byte[]]]::new()
    $secretPaths = @($script:State.ControllerToken, $script:State.PrivateKey, $script:State.Enrollment, $script:State.WorkerCredential, $script:State.StagedCredential) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) }
    foreach ($path in $secretPaths) {
        try {
            $bytes = [IO.File]::ReadAllBytes($path)
            if ($bytes.Length -ge 16) { $secretBytes.Add($bytes) }
            if ([IO.Path]::GetFileName($path) -ieq 'enrollment.json') {
                try {
                    $pairing = (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).pairingCode
                    if ($pairing -and ([string]$pairing).Length -ge 16) { $secretBytes.Add([Text.Encoding]::UTF8.GetBytes([string]$pairing)) }
                } catch {}
            }
        } catch {}
    }
    $roots = @($script:State.LogRoot, $script:State.EvidenceRoot)
    $extra = @($script:State.JobSpec, (Join-Path $script:State.JobRoot 'manifest.json'), (Join-Path $script:State.JobRoot 'result.json'))
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $files = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue)
        foreach ($file in $files) { $extra += $file.FullName }
    }
    foreach ($path in @($extra | Select-Object -Unique)) {
        if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        if ($secretPaths -contains $path) { continue }
        $data = [IO.File]::ReadAllBytes($path)
        foreach ($secret in $secretBytes) {
            if ($secret.Length -le $data.Length) {
                for ($offset = 0; $offset -le ($data.Length - $secret.Length); $offset++) {
                    $match = $true
                    for ($index = 0; $index -lt $secret.Length; $index++) {
                        if ($data[$offset + $index] -cne $secret[$index]) { $match = $false; break }
                    }
                    if ($match) { Fail-RoundTrip 'secret value appeared in logs or evidence' }
                }
            }
        }
        $text = [Text.Encoding]::UTF8.GetString($data).ToLowerInvariant()
        if ($text.Contains('-----begin private key-----') -or $text.Contains('-----begin rsa private key-----') -or
            $text.Contains('x-cyc-run-credential') -or $text.Contains('authorization: pairing') -or
            $text -match '"pairingcode"\s*:') {
            Fail-RoundTrip 'credential-bearing marker appeared in logs or evidence'
        }
    }
    $script:State.Checks.secretScan = $true
}

function Write-Manifest {
    $manifest = [ordered]@{
        schema = 'cyc.dev/windows-controller-worker-roundtrip-manifest/v1'
        hostOs = [Environment]::OSVersion.VersionString
        hostArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        repository = $script:State.RepositoryRoot
        workRoot = $script:State.WorkRoot
        jobRoot = $script:State.JobRoot
        evidence = $script:State.EvidenceRoot
        controllerUrl = $script:State.ControllerUrl
        workerUrl = $script:State.WorkerUrl
        workerAddress = $script:State.WorkerIp
        controllerPort = $script:State.ControllerPort
        workerPort = $script:State.WorkerPort
        timeoutSeconds = $script:State.TimeoutSeconds
        heartbeatIntervalSeconds = 5
        createdAt = [DateTimeOffset]::UtcNow.ToString('o')
        acceptanceBoundary = 'same-host Windows live fixture; not clean-VM, production-signing, or cross-machine evidence'
    }
    Write-Utf8NoBom -Path (Join-Path $script:State.JobRoot 'manifest.json') -Content ($manifest | ConvertTo-Json -Depth 8)
}

function Write-Result {
    param([Parameter(Mandatory)][string]$Status)
    $result = [ordered]@{
        schema = 'cyc.dev/windows-controller-worker-roundtrip-result/v1'
        status = $Status
        failure = $script:State.Failure
        sourceCommit = ((git -C $script:State.RepositoryRoot rev-parse HEAD 2>$null) | Select-Object -First 1)
        hostOs = [Environment]::OSVersion.VersionString
        hostArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        jobRoot = $script:State.JobRoot
        checks = $script:State.Checks
        observedStates = @($script:State.ObservedStates)
        jobId = $script:State.JobId
        runId = $script:State.RunId
        nodeId = $script:State.NodeId
        runDurationSeconds = $script:State.RunDurationSeconds
        cleanup = $script:State.Cleanup
        acceptanceBoundary = 'same-host Windows live fixture; not clean-VM, production-signing, or cross-machine evidence'
    }
    if ($script:State.EvidenceRoot -and (Test-Path -LiteralPath $script:State.EvidenceRoot -PathType Container)) {
        Write-Utf8NoBom -Path (Join-Path $script:State.JobRoot 'result.json') -Content ($result | ConvertTo-Json -Depth 20)
    }
    return $result
}

function Assert-RouteTrace {
    foreach ($record in @($script:State.OwnedProcesses)) {
        try { Flush-OwnedProcess -Record $record } catch {}
    }
    $text = ''
    foreach ($path in @(Get-ChildItem -LiteralPath $script:State.LogRoot -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)) {
        $text += "`n" + (Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue)
    }
    $required = @('/worker/v1/pair', '/worker/v1/pair/ack', '/worker/v1/node-report', '/worker/v1/claim', '/heartbeat', '/complete', '/cleanup')
    foreach ($route in $required) {
        if (-not $text.Contains($route)) { Fail-RoundTrip "controller trace did not show $route" }
    }
    $script:State.Checks.routeTrace = $true
}

function Invoke-SelfTest {
    if ((Test-PrivateIpv4 '10.0.0.1') -ne $true -or (Test-PrivateIpv4 '172.16.1.1') -ne $true -or (Test-PrivateIpv4 '192.168.1.1') -ne $true) {
        Fail-RoundTrip 'self-test private IPv4 positive cases failed'
    }
    if ((Test-PrivateIpv4 '127.0.0.1') -or (Test-PrivateIpv4 '169.254.1.1') -or (Test-PrivateIpv4 '8.8.8.8')) {
        Fail-RoundTrip 'self-test accepted a non-private IPv4 address'
    }
    $quoted = ConvertTo-WindowsArgument 'C:\Program Files\ClusterYourCodex\cyc.exe'
    if ($quoted -cne '"C:\Program Files\ClusterYourCodex\cyc.exe"') { Fail-RoundTrip 'self-test Windows argument quoting failed' }
    $root = Join-Path ([IO.Path]::GetTempPath()) ("cyc-windows-roundtrip-selftest." + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    try {
        $path = Join-Path $root 'fixture.json'
        Write-Utf8NoBom -Path $path -Content '{"status":"ok"}'
        [void](Get-JsonDocument -Path $path)
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Output 'Windows controller/worker round-trip self-test passed.'
}

function Initialize-RoundTrip {
    if ([string]::IsNullOrWhiteSpace($script:State.RepositoryRoot)) {
        $script:State.RepositoryRoot = Join-Path (Split-Path -Parent $PSScriptRoot) ''
    }
    $script:State.RepositoryRoot = Test-DirectDirectory -Path ((Resolve-Path -LiteralPath $script:State.RepositoryRoot).Path) -Label 'repository root'
    if (-not (Test-Path -LiteralPath (Join-Path $script:State.RepositoryRoot 'Cargo.toml') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $script:State.RepositoryRoot 'crates/cyc-controller') -PathType Container) -or
        -not (Test-Path -LiteralPath (Join-Path $script:State.RepositoryRoot 'crates/cyc-worker') -PathType Container)) {
        Fail-RoundTrip 'repository root is not a ClusterYourCodex checkout'
    }
    if ([string]::IsNullOrWhiteSpace($script:State.WorkRoot)) {
        $script:State.WorkRoot = Join-Path ([IO.Path]::GetTempPath()) 'ClusterYourCodex-roundtrip'
    }
    if (-not (Test-Path -LiteralPath $script:State.WorkRoot)) { New-Item -ItemType Directory -Path $script:State.WorkRoot -Force | Out-Null }
    $script:State.WorkRoot = Test-DirectDirectory -Path ((Resolve-Path -LiteralPath $script:State.WorkRoot).Path) -Label 'work root'
    $candidate = Join-Path $script:State.WorkRoot ("cyc-windows-controller-worker-roundtrip." + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $candidate -ErrorAction Stop | Out-Null
    $script:State.JobRoot = Test-DirectDirectory -Path $candidate -Label 'job root'
    $script:State.RootCreated = $true
    Protect-PrivateDirectory -Path $script:State.JobRoot
    # identity, worker, and workspace are intentionally left absent.  The
    # product commands create each of those roots with their own exact
    # current-user/SYSTEM private DACL; precreating them here would inherit
    # the temporary parent ACL and make the live check fail for the wrong
    # reason.
    foreach ($name in @('logs', 'evidence', 'source', 'evidence/downloads')) {
        New-Item -ItemType Directory -Path (Join-Path $script:State.JobRoot $name) -Force | Out-Null
    }
    $script:State.LogRoot = Join-Path $script:State.JobRoot 'logs'
    $script:State.EvidenceRoot = Join-Path $script:State.JobRoot 'evidence'
    $script:State.IdentityRoot = Join-Path $script:State.JobRoot 'identity'
    $script:State.WorkerRoot = Join-Path $script:State.JobRoot 'worker'
    $script:State.WorkspaceRoot = Join-Path $script:State.JobRoot 'workspace'
    $script:State.SourceRoot = Join-Path $script:State.JobRoot 'source'
    $script:State.DownloadRoot = Join-Path $script:State.EvidenceRoot 'downloads'
    $script:State.ControllerDb = Join-Path $script:State.JobRoot 'controller.db'
    $script:State.ControllerToken = Join-Path $script:State.JobRoot 'controller.token'
    $script:State.Certificate = Join-Path $script:State.IdentityRoot 'controller.crt.pem'
    $script:State.PrivateKey = Join-Path $script:State.IdentityRoot 'controller.key.pem'
    $script:State.Enrollment = Join-Path $script:State.JobRoot 'enrollment.json'
    $script:State.WorkerConfig = Join-Path $script:State.WorkerRoot 'worker.json'
    $script:State.SnapshotArchive = Join-Path $script:State.JobRoot 'source.tar.zst'
    $script:State.JobSpec = Join-Path $script:State.JobRoot 'job.json'
    $script:State.TimeoutSeconds = $TimeoutSeconds
    Write-Manifest
}

function Resolve-Binaries {
    $allProvided = -not [string]::IsNullOrWhiteSpace($script:State.CycBin) -and
        -not [string]::IsNullOrWhiteSpace($script:State.ControllerBin) -and
        -not [string]::IsNullOrWhiteSpace($script:State.WorkerBin)
    if (-not $allProvided) {
        $target = if ([string]::IsNullOrWhiteSpace($CargoTargetDirectory)) {
            Join-Path $script:State.RepositoryRoot 'target/debug'
        } else { $CargoTargetDirectory }
        if (-not [IO.Path]::IsPathRooted($target)) { $target = Join-Path $script:State.RepositoryRoot $target }
        $build = Invoke-CapturedCommand -Label 'cargo-build' -FilePath 'cargo.exe' `
            -ArgumentList @('build', '--locked', '--manifest-path', (Join-Path $script:State.RepositoryRoot 'Cargo.toml'), '-p', 'cyc-cli', '-p', 'cyc-controller', '-p', 'cyc-worker') `
            -StdoutPath (Join-Path $script:State.EvidenceRoot 'cargo-build.stdout.log') `
            -StderrPath (Join-Path $script:State.LogRoot 'cargo-build.stderr.log') -Timeout 1800 -WorkingDirectory $script:State.RepositoryRoot
        if ($build.ExitCode -ne 0) { Fail-RoundTrip 'cargo build failed; inspect cargo-build evidence' }
        if ([string]::IsNullOrWhiteSpace($script:State.CycBin)) { $script:State.CycBin = Join-Path $target 'cyc.exe' }
        if ([string]::IsNullOrWhiteSpace($script:State.ControllerBin)) { $script:State.ControllerBin = Join-Path $target 'cyc-controller.exe' }
        if ([string]::IsNullOrWhiteSpace($script:State.WorkerBin)) { $script:State.WorkerBin = Join-Path $target 'cyc-worker.exe' }
    }
    $script:State.CycBin = Resolve-DirectFile -Path $script:State.CycBin -Label 'cyc executable'
    $script:State.ControllerBin = Resolve-DirectFile -Path $script:State.ControllerBin -Label 'controller executable'
    $script:State.WorkerBin = Resolve-DirectFile -Path $script:State.WorkerBin -Label 'worker executable'
    $versions = @()
    foreach ($binary in @($script:State.CycBin, $script:State.ControllerBin, $script:State.WorkerBin)) {
        $probe = Invoke-CapturedCommand -Label 'version-probe' -FilePath $binary -ArgumentList @('--version') `
            -StdoutPath (Join-Path $script:State.EvidenceRoot ((Split-Path -Leaf $binary) + '.version.txt')) `
            -StderrPath (Join-Path $script:State.LogRoot ((Split-Path -Leaf $binary) + '.version.stderr.log')) `
            -Timeout 30 -WorkingDirectory $script:State.RepositoryRoot
        if ($probe.ExitCode -ne 0) { Fail-RoundTrip "version probe failed for $binary" }
        $versions += (Get-Content -LiteralPath (Join-Path $script:State.EvidenceRoot ((Split-Path -Leaf $binary) + '.version.txt')) -Raw).Trim()
    }
    Write-Utf8NoBom -Path (Join-Path $script:State.EvidenceRoot 'toolchain-versions.txt') -Content (($versions -join "`n") + "`n")
}

function Invoke-LiveRoundTrip {
    if (-not (Test-IsWindowsHost)) { Fail-RoundTrip 'live Windows round-trip requires a Windows host; refusing to represent another OS as Windows evidence' }
    Resolve-Binaries
    $script:State.WorkerIp = Get-PrivateIpv4Address
    $script:State.ControllerPort = Get-FreeTcpPort -Address '127.0.0.1'
    $script:State.WorkerPort = Get-FreeTcpPort -Address $script:State.WorkerIp
    $script:State.ControllerUrl = "http://127.0.0.1:$($script:State.ControllerPort)"
    $script:State.WorkerUrl = "https://$($script:State.WorkerIp):$($script:State.WorkerPort)"
    Write-Manifest

    $identity = Invoke-CapturedCommand -Label 'identity-init' -FilePath $script:State.CycBin `
        -ArgumentList @('identity', 'init', '--output-dir', $script:State.IdentityRoot, '--host', $script:State.WorkerIp) `
        -StdoutPath (Join-Path $script:State.EvidenceRoot 'identity-init.stdout.json') -StderrPath (Join-Path $script:State.LogRoot 'identity-init.stderr.log') `
        -Timeout 30 -WorkingDirectory $script:State.RepositoryRoot
    if ($identity.ExitCode -ne 0) { Fail-RoundTrip 'identity init failed' }
    $verify = Invoke-CapturedCommand -Label 'identity-verify' -FilePath $script:State.CycBin `
        -ArgumentList @('identity', 'verify', '--certificate', $script:State.Certificate, '--private-key', $script:State.PrivateKey, '--host', $script:State.WorkerIp, '--json') `
        -StdoutPath (Join-Path $script:State.EvidenceRoot 'identity-verify.stdout.json') -StderrPath (Join-Path $script:State.LogRoot 'identity-verify.stderr.log') `
        -Timeout 30 -WorkingDirectory $script:State.RepositoryRoot
    if ($verify.ExitCode -ne 0) { Fail-RoundTrip 'identity verify failed' }
    Assert-DirectOwnedFile -Path $script:State.Certificate -Label 'TLS certificate' | Out-Null
    Assert-DirectOwnedFile -Path $script:State.PrivateKey -Label 'TLS private key' | Out-Null
    $script:State.Checks.tlsIdentity = $true

    $controllerEnvironment = @{ RUST_LOG = 'debug' }
    $script:State.ControllerProcess = Start-OwnedProcess -Label 'controller' -FilePath $script:State.ControllerBin `
        -ArgumentList @('--bind', "127.0.0.1:$($script:State.ControllerPort)", '--database', $script:State.ControllerDb, '--token-file', $script:State.ControllerToken, `
            '--worker-bind', "$($script:State.WorkerIp):$($script:State.WorkerPort)", '--worker-public-url', $script:State.WorkerUrl, '--worker-cert', $script:State.Certificate, '--worker-key', $script:State.PrivateKey) `
        -StdoutPath (Join-Path $script:State.LogRoot 'controller.stdout.log') -StderrPath (Join-Path $script:State.LogRoot 'controller.stderr.log') `
        -WorkingDirectory $script:State.RepositoryRoot -Environment $controllerEnvironment
    Wait-ControllerHealth
    if (-not (Wait-TcpListener -Address $script:State.WorkerIp -Port $script:State.WorkerPort -Seconds 15)) {
        Fail-RoundTrip 'worker TLS listener did not become reachable before pairing'
    }
    Assert-DirectOwnedFile -Path $script:State.ControllerToken -Label 'controller token' | Out-Null
    $token = (Get-Content -LiteralPath $script:State.ControllerToken -Raw).Trim()
    if ($token.Length -lt 32 -or $token.Length -gt 256) { Fail-RoundTrip 'controller token length is outside the protocol bound' }

    $pair = Invoke-CycJson -Label 'pair-create' -Arguments @('pair', 'create', '--output', $script:State.Enrollment, '--operation-id', ("windows-live-roundtrip-" + [Guid]::NewGuid().ToString('N'))) -Authenticated
    $script:State.PairingId = [string](Get-JsonField $pair 'pairingId')
    $script:State.NodeId = [string](Get-JsonField $pair 'intendedNodeId')
    if (-not (Test-ValidGuid $script:State.PairingId) -or -not (Test-ValidGuid $script:State.NodeId)) { Fail-RoundTrip 'pair create returned invalid identifiers' }
    Assert-DirectOwnedFile -Path $script:State.Enrollment -Label 'enrollment bundle' | Out-Null
    $script:State.StagedCredential = Join-Path $script:State.WorkerRoot ("worker.$($script:State.PairingId).credential")

    $paired = Invoke-CapturedCommand -Label 'worker-pair' -FilePath $script:State.WorkerBin `
        -ArgumentList @('pair', '--enrollment-file', $script:State.Enrollment, '--config', $script:State.WorkerConfig, '--workspace-root', $script:State.WorkspaceRoot) `
        -StdoutPath (Join-Path $script:State.EvidenceRoot 'worker-pair.stdout.log') -StderrPath (Join-Path $script:State.LogRoot 'worker-pair.stderr.log') `
        -Timeout 60 -WorkingDirectory $script:State.RepositoryRoot
    if ($paired.ExitCode -ne 0) { Fail-RoundTrip 'worker pair failed' }
    Wait-PairReady
    $workerStatus = Invoke-CycJson -Label 'worker-status-paired' -Arguments @('pair', 'status', $script:State.PairingId) -Authenticated
    if ([string](Get-JsonField $workerStatus 'phase') -cne 'ready') { Fail-RoundTrip 'pairing status was not ready after worker pair' }
    $workerConfig = Get-JsonDocument -Path $script:State.WorkerConfig
    $script:State.WorkerCredential = [string](Get-JsonField $workerConfig 'credentialFile')
    if (-not [IO.Path]::IsPathRooted($script:State.WorkerCredential)) {
        $script:State.WorkerCredential = Join-Path $script:State.WorkerRoot $script:State.WorkerCredential
    }
    $script:State.WorkerCredential = (Resolve-Path -LiteralPath $script:State.WorkerCredential).Path
    if (-not $script:State.WorkerCredential.StartsWith($script:State.WorkerRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { Fail-RoundTrip 'worker credential path escaped pairing-owned directory' }
    Assert-DirectOwnedFile -Path $script:State.WorkerCredential -Label 'worker credential' | Out-Null

    $script:State.WorkerProcess = Start-OwnedProcess -Label 'worker' -FilePath $script:State.WorkerBin `
        -ArgumentList @('run', '--config', $script:State.WorkerConfig) -StdoutPath (Join-Path $script:State.LogRoot 'worker.stdout.log') `
        -StderrPath (Join-Path $script:State.LogRoot 'worker.stderr.log') -WorkingDirectory $script:State.RepositoryRoot `
        -Environment @{ RUST_LOG = 'info' }
    Wait-NodeReport

    Write-Utf8NoBom -Path (Join-Path $script:State.SourceRoot 'input.txt') -Content "roundtrip-input`r`n"
    $packed = Invoke-CycJson -Label 'snapshot-pack' -Arguments @('snapshot', 'pack', '--source', $script:State.SourceRoot, '--output', $script:State.SnapshotArchive)
    $digest = [string](Get-JsonField $packed 'digest')
    $size = [int64](Get-JsonField $packed 'sizeBytes')
    if ($digest -notmatch '^sha256:[0-9a-f]{64}$' -or $size -le 0) { Fail-RoundTrip 'snapshot pack returned invalid metadata' }
    $uploaded = Invoke-CycJson -Label 'snapshot-upload' -Arguments @('snapshot', 'upload', '--archive', $script:State.SnapshotArchive) -Authenticated
    $snapshotStatus = Invoke-CycJson -Label 'snapshot-status' -Arguments @('snapshot', 'status', $digest) -Authenticated
    if ((Get-JsonField $snapshotStatus 'available') -ne $true) { Fail-RoundTrip 'uploaded snapshot was not available' }

    Wait-NodeCapacity -MinimumCpuCores 1

    $script:State.JobId = [Guid]::NewGuid().ToString()
    $powershellStep = @'
$ErrorActionPreference = 'Stop'
[Console]::Out.WriteLine('roundtrip-step-start')
[IO.File]::WriteAllText((Join-Path (Get-Location) 'result.txt'), "roundtrip-output`r`n", [Text.UTF8Encoding]::new($false))
Start-Sleep -Seconds 8
[IO.File]::AppendAllText((Join-Path (Get-Location) 'result.txt'), "roundtrip-step-complete`r`n", [Text.UTF8Encoding]::new($false))
[Console]::Out.WriteLine('roundtrip-step-complete')
'@
    $job = [ordered]@{
        apiVersion = 'cyc.dev/v1'
        id = $script:State.JobId
        kind = 'test'
        source = [ordered]@{ type = 'snapshot'; digest = $digest; sizeBytes = $size }
        steps = @([ordered]@{ name = 'controller-worker-roundtrip'; shell = 'powershell'; script = $powershellStep })
        artifacts = [ordered]@{ include = @('result.txt'); exclude = @('.git/**') }
        # Hosted Windows runners can spend several minutes starting the first
        # contained Windows PowerShell process while Defender/JIT and the
        # suspended-to-job-object hand-off are cold.  Keep this acceptance
        # fixture finite, but do not let a 60-second application timeout turn
        # a successful eight-second step into a false negative.  Production
        # job/step timeouts remain unchanged; this is only the live gate's
        # deliberately bounded test payload.
        timeoutSeconds = 300
        placementPolicy = 'balanced'
    }
    Write-Utf8NoBom -Path $script:State.JobSpec -Content ($job | ConvertTo-Json -Depth 20)
    $submitted = Invoke-CycJson -Label 'job-submit' -Arguments @('submit', '--file', $script:State.JobSpec) -Authenticated
    if ([string](Get-JsonField $submitted 'job.id') -cne $script:State.JobId) { Fail-RoundTrip 'controller changed submitted job id' }
    $script:State.RunId = [string](Get-JsonField $submitted 'run.id')
    if (-not (Test-ValidGuid $script:State.RunId)) { Fail-RoundTrip 'controller returned invalid run id' }
    Wait-JobTerminal

    $stdout = Join-Path $script:State.DownloadRoot 'stdout.log'
    $stderr = Join-Path $script:State.DownloadRoot 'stderr.log'
    [void](Invoke-CycJson -Label 'stdout-download' -Arguments @('logs', $script:State.JobId, '--stream', 'stdout', '--output', $stdout) -Authenticated)
    [void](Invoke-CycJson -Label 'stderr-download' -Arguments @('logs', $script:State.JobId, '--stream', 'stderr', '--output', $stderr) -Authenticated)
    $stdoutText = Get-Content -LiteralPath $stdout -Raw
    if (-not $stdoutText.Contains('roundtrip-step-start') -or -not $stdoutText.Contains('roundtrip-step-complete')) { Fail-RoundTrip 'downloaded stdout missed step markers' }
    $script:State.Checks.logs = $true
    $artifacts = Invoke-CycJson -Label 'artifact-list' -Arguments @('artifacts', $script:State.JobId) -Authenticated
    $artifact = @((Get-JsonField $artifacts 'artifacts')) | Where-Object { [string](Get-JsonField $_ 'name') -ceq 'result.txt' } | Select-Object -First 1
    if ($null -eq $artifact) { Fail-RoundTrip 'result.txt artifact was not listed' }
    $artifactId = [string](Get-JsonField $artifact 'id')
    if (-not (Test-ValidGuid $artifactId)) { Fail-RoundTrip 'result.txt artifact id is invalid' }
    $artifactPath = Join-Path $script:State.DownloadRoot 'result.txt'
    [void](Invoke-CycJson -Label 'artifact-download' -Arguments @('artifacts', $script:State.JobId, '--artifact-id', $artifactId, '--output', $artifactPath) -Authenticated)
    $expected = "roundtrip-output`r`nroundtrip-step-complete`r`n"
    $actual = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($artifactPath))
    if ($actual -cne $expected) { Fail-RoundTrip 'downloaded artifact bytes did not match expected Windows output' }
    $script:State.Checks.artifact = $true
    Wait-CleanupReceipt
    Stop-OwnedProcesses | Out-Null
    Assert-RouteTrace
    Scan-SecretLeaks
    $script:State.Passed = $true
    Write-Utf8NoBom -Path (Join-Path $script:State.EvidenceRoot 'acceptance.txt') -Content "windows controller/worker live round-trip passed`n"
}

function Complete-RoundTrip {
    param([int]$OriginalExitCode)
    if (-not $script:State.RootCreated) { return $OriginalExitCode }
    try { Stop-OwnedProcesses | Out-Null } catch { $script:State.Checks.processCleanup = $false }
    try { Scan-SecretLeaks } catch { $script:State.Checks.secretScan = $false; if (-not $script:State.Failure) { $script:State.Failure = $_.Exception.Message } }
    foreach ($path in @($script:State.ControllerToken, $script:State.PrivateKey, $script:State.Enrollment, $script:State.WorkerCredential, $script:State.StagedCredential)) {
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { continue }
        try { Remove-Item -LiteralPath $path -Force -ErrorAction Stop } catch { if (-not $script:State.Failure) { $script:State.Failure = 'owned secret-file cleanup failed' } }
    }
    try { Write-Result -Status $(if ($script:State.Passed -and -not $script:State.Failure) { 'passed' } else { 'failed' }) | Out-Null } catch {}
    $success = $script:State.Passed -and -not $script:State.Failure -and $script:State.Checks.processCleanup -and $script:State.Checks.secretScan
    if ($success -and -not $KeepEvidence) {
        try {
            $jobItem = Get-Item -LiteralPath $script:State.JobRoot -ErrorAction Stop
            $workItem = Get-Item -LiteralPath $script:State.WorkRoot -ErrorAction Stop
            if (($jobItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                ($workItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                $jobItem.Parent.FullName -cne $workItem.FullName -or
                $jobItem.Name -notlike 'cyc-windows-controller-worker-roundtrip.*') {
                Fail-RoundTrip 'refused unsafe evidence-root removal'
            }
            Remove-Item -LiteralPath $script:State.JobRoot -Recurse -Force -ErrorAction Stop
            Write-Output 'PASS: Windows controller/worker live round-trip complete; temporary evidence removed.'
        } catch {
            $script:State.Failure = 'safe evidence-root removal failed'
            Write-Error ("FAIL: round-trip passed but evidence was retained at {0}" -f $script:State.JobRoot)
            return 1
        }
    } elseif ($success) {
        Write-Output ("PASS: Windows controller/worker live round-trip complete; sanitized evidence retained at {0}" -f $script:State.JobRoot)
    } else {
        Write-Error ("FAIL: Windows controller/worker live round-trip did not pass; sanitized evidence retained at {0}" -f $script:State.JobRoot)
    }
    if ($OriginalExitCode -ne 0 -or -not $success) { return 1 }
    return 0
}

if ($SelfTest) {
    Invoke-SelfTest
    exit 0
}

$exitCode = 0
try {
    $script:State.RepositoryRoot = $RepositoryRoot
    $script:State.WorkRoot = $WorkRoot
    $script:State.CycBin = $CycBin
    $script:State.ControllerBin = $ControllerBin
    $script:State.WorkerBin = $WorkerBin
    Initialize-RoundTrip
    Invoke-LiveRoundTrip
} catch {
    $script:State.Failure = $_.Exception.Message
    $exitCode = 1
} finally {
    $exitCode = Complete-RoundTrip -OriginalExitCode $exitCode
}
if ($exitCode -ne 0) { exit $exitCode }
