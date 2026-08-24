#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Repair', 'Uninstall')]
    [string]$Action = 'Install',

    [string]$BundleRoot,
    [string]$PackageRoot,
    [string]$PackageManifest,
    [string]$PackageExecutable,
    [switch]$RequirePackageSignature,

    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\ClusterYourCodex'),
    [string]$DataRoot = (Join-Path $env:LOCALAPPDATA 'ClusterYourCodex'),
    [switch]$Quiet,
    [switch]$NoLaunch,
    [ValidateRange(60, 2100)][int]$FirewallTimeoutSeconds = 1800
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CycLifecycleJournalSchema = 'cyc.dev/windows-external-lifecycle/v1'
$script:CycFirewallRequestSchema = 'cyc.dev/windows-firewall-request/v1'
$script:CycFirewallReceiptSchema = 'cyc.dev/windows-firewall-receipt/v1'
$script:CycCoreCommitSchema = 'cyc.dev/windows-core-commit/v1'
$script:CycFirewallRuleGroup = 'ClusterYourCodex'
$script:CycFirewallRuleDescription = 'ClusterYourCodex owned managed-worker TLS listener'
$script:CycFirewallDisplayName = 'ClusterYourCodex Managed Worker'
$script:CycFirewallLifecycleName = 'external-elevated-helper'
$script:CycFirewallExchangeDirectory = 'ClusterYourCodex-Firewall'
$script:CycBootstrapName = 'bootstrap.ps1'
$script:CycFirewallHelperName = 'Invoke-ClusterYourCodexFirewall.ps1'
$script:CycMaxInstallManifestBytes = 16MB
$script:CycLifecycleDiagnosticStage = 'entry'
$script:CycLifecyclePackageManifestSha256 = $null

function Set-CycLifecycleDiagnosticStage {
    param([Parameter(Mandatory = $true)][ValidatePattern('^[a-z][a-z0-9-]{0,63}$')][string]$Stage)
    $script:CycLifecycleDiagnosticStage = $Stage
}

function Resolve-CycLifecyclePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ([string]::Equals($full, $root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $root
    }
    return $full.TrimEnd('\', '/')
}

function Assert-CycLifecycleSafeString {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 4096 -or
        $Value.Contains('"') -or $Value.Contains("`r") -or $Value.Contains("`n") -or
        $Value -match '[\x00-\x1f\x7f]') {
        throw "$Label contains unsupported characters."
    }
}

function ConvertTo-CycLifecycleDiagnosticText {
    param(
        [AllowNull()]$Value,
        [ValidateRange(1, 32768)][int]$MaximumCharacters = 16384
    )
    if ($null -eq $Value) { return $null }
    $text = [string]$Value
    if ($text.Length -le $MaximumCharacters) { return $text }
    return $text.Substring($text.Length - $MaximumCharacters)
}

function Write-CycLifecycleDiagnostic {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('succeeded', 'failed')][string]$Status,
        [AllowNull()]$Result,
        [AllowNull()][System.Management.Automation.ErrorRecord]$Failure
    )

    $requestedPath = [string]$env:CYC_SETUP_DIAGNOSTIC_LOG
    if ([string]::IsNullOrWhiteSpace($requestedPath) -or $requestedPath.Length -gt 4096 -or
        $requestedPath.Contains('"') -or $requestedPath.Contains("`r") -or $requestedPath.Contains("`n") -or
        $requestedPath -match '[\x00-\x1f\x7f]') {
        return
    }

    $temporaryPath = $null
    $backupPath = $null
    try {
        $destination = [System.IO.Path]::GetFullPath($requestedPath)
        $directory = [System.IO.Path]::GetDirectoryName($destination)
        if ([string]::IsNullOrWhiteSpace($directory) -or
            -not (Test-Path -LiteralPath $directory -PathType Container)) {
            return
        }
        $directoryItem = Get-Item -LiteralPath $directory -Force
        if (($directoryItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return }
        if (Test-Path -LiteralPath $destination) {
            $destinationItem = Get-Item -LiteralPath $destination -Force
            if ($destinationItem.PSIsContainer -or
                ($destinationItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                return
            }
        }

        $errorRecord = if ($Failure) {
            [ordered]@{
                message = ConvertTo-CycLifecycleDiagnosticText $Failure.Exception.Message
                exceptionType = ConvertTo-CycLifecycleDiagnosticText $Failure.Exception.GetType().FullName 1024
                fullyQualifiedErrorId = ConvertTo-CycLifecycleDiagnosticText $Failure.FullyQualifiedErrorId 4096
                scriptStackTrace = ConvertTo-CycLifecycleDiagnosticText $Failure.ScriptStackTrace
                positionMessage = ConvertTo-CycLifecycleDiagnosticText $Failure.InvocationInfo.PositionMessage
            }
        } else { $null }
        $resultRecord = if ($Result) {
            [ordered]@{
                action = ConvertTo-CycLifecycleDiagnosticText $Result.action 128
                status = ConvertTo-CycLifecycleDiagnosticText $Result.status 128
                resumed = [bool]$Result.resumed
                firewallVerified = [bool]$Result.firewallVerified
                coreSucceeded = if ($Result.PSObject.Properties['coreSucceeded']) { [bool]$Result.coreSucceeded } else { $null }
            }
        } else { $null }
        $record = [ordered]@{
            schemaVersion = 'cyc.dev/setup-lifecycle-diagnostic/v1'
            status = $Status
            requestedAction = $Action
            lastStage = $script:CycLifecycleDiagnosticStage
            packageManifestSha256 = $script:CycLifecyclePackageManifestSha256
            result = $resultRecord
            error = $errorRecord
            recordedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        $json = $record | ConvertTo-Json -Depth 8
        $temporaryPath = Join-Path $directory ('.cyc-setup-lifecycle-' + $PID + '-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        [System.IO.File]::WriteAllText($temporaryPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            # Windows PowerShell and PowerShell 7 bind a null backup argument
            # differently. A real same-directory backup keeps Replace atomic
            # on both runtimes; it is removed immediately after the swap.
            $backupPath = Join-Path $directory ('.cyc-setup-lifecycle-' + $PID + '-' + [Guid]::NewGuid().ToString('N') + '.bak')
            [System.IO.File]::Replace($temporaryPath, $destination, $backupPath)
            $temporaryPath = $null
            [System.IO.File]::Delete($backupPath)
            $backupPath = $null
        } else {
            [System.IO.File]::Move($temporaryPath, $destination)
            $temporaryPath = $null
        }
    } catch {
        # Diagnostics are best-effort and must never replace the lifecycle result.
    } finally {
        if ($temporaryPath -and (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) {
            try { [System.IO.File]::Delete($temporaryPath) } catch { }
        }
        if ($backupPath -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            try { [System.IO.File]::Delete($backupPath) } catch { }
        }
    }
}

function Assert-CycLifecycleExactProperties {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Label
    )
    [string[]]$actual = if ($Object -is [System.Collections.IDictionary]) {
        @($Object.Keys | ForEach-Object { [string]$_ })
    } else {
        @($Object.PSObject.Properties.Name)
    }
    [string[]]$wanted = @($Expected)
    [Array]::Sort($actual, [System.StringComparer]::Ordinal)
    [Array]::Sort($wanted, [System.StringComparer]::Ordinal)
    if ([string]::Join(',', $actual) -cne [string]::Join(',', $wanted)) {
        throw "$Label contains an unsupported or missing field."
    }
}

function Get-CycLifecycleSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Get-CycInitiatorBinding {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $identity.User -or [string]::IsNullOrWhiteSpace($identity.User.Value)) {
        throw 'The initiating Windows account has no stable SID.'
    }
    if ([string]::IsNullOrWhiteSpace($env:USERPROFILE) -or
        [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'The initiating user profile is incomplete.'
    }
    $profile = Resolve-CycLifecyclePath $env:USERPROFILE
    $localAppData = Resolve-CycLifecyclePath $env:LOCALAPPDATA
    return [PSCustomObject]@{
        sid = [string]$identity.User.Value
        profile = $profile
        localAppData = $localAppData
    }
}

function Assert-CycInitiatorStillCurrent {
    param([Parameter(Mandatory = $true)]$Binding)
    $current = Get-CycInitiatorBinding
    if ([string]$current.sid -cne [string]$Binding.sid -or
        -not [string]::Equals([string]$current.profile, [string]$Binding.profile, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$current.localAppData, [string]$Binding.localAppData, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Initiating SID or profile changed during the lifecycle transaction.'
    }
    return $current
}

function Enter-CycLifecycleMutex {
    param(
        [Parameter(Mandatory = $true)][string]$Sid,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 30
    )
    if ($Sid -cnotmatch '^S-1-[0-9-]+$') {
        throw 'Cannot create the lifecycle mutex for an invalid initiating SID.'
    }
    $name = 'Global\ClusterYourCodex.WindowsLifecycle.v1.' + $Sid.Replace('-', '_')
    $mutex = [System.Threading.Mutex]::new($false, $name)
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
        } catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw 'Another ClusterYourCodex install, repair, or uninstall is still active.'
        }
        return $mutex
    } catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-CycLifecycleMutex {
    param([AllowNull()][System.Threading.Mutex]$Mutex)
    if (-not $Mutex) { return }
    try { $Mutex.ReleaseMutex() } finally { $Mutex.Dispose() }
}

function Assert-CycDefaultPerUserRoots {
    param(
        [Parameter(Mandatory = $true)]$Binding,
        [Parameter(Mandatory = $true)][string]$RequestedInstallRoot,
        [Parameter(Mandatory = $true)][string]$RequestedDataRoot
    )
    $install = Resolve-CycLifecyclePath $RequestedInstallRoot
    $data = Resolve-CycLifecyclePath $RequestedDataRoot
    $expectedInstall = Resolve-CycLifecyclePath (Join-Path $Binding.localAppData 'Programs\ClusterYourCodex')
    $expectedData = Resolve-CycLifecyclePath (Join-Path $Binding.localAppData 'ClusterYourCodex')
    if (-not [string]::Equals($install, $expectedInstall, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals($data, $expectedData, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'One-click lifecycle paths must remain in the initiating user profile.'
    }
    return [PSCustomObject]@{ installRoot = $install; dataRoot = $data }
}

function New-CycPrivateDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$InitiatorSid,
        [switch]$IncludeAdministrators
    )
    $resolved = Resolve-CycLifecyclePath $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $resolved -Force)
    }
    $item = Get-Item -LiteralPath $resolved -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Lifecycle state directory must not be a reparse point.'
    }
    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    $owner = New-Object System.Security.Principal.SecurityIdentifier($InitiatorSid)
    $security.SetOwner($owner)
    $rights = [System.Security.AccessControl.FileSystemRights]::FullControl
    $inheritance = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    foreach ($sid in @($InitiatorSid, 'S-1-5-18')) {
        [void]$security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            (New-Object System.Security.Principal.SecurityIdentifier($sid)),
            $rights, $inheritance, $propagation, $allow
        )))
    }
    if ($IncludeAdministrators) {
        [void]$security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')),
            $rights, $inheritance, $propagation, $allow
        )))
    }
    if ($null -ne $item.PSObject.Methods['SetAccessControl']) {
        $item.SetAccessControl($security)
    } else {
        [System.IO.FileSystemAclExtensions]::SetAccessControl([System.IO.DirectoryInfo]$item, $security)
    }
    return $resolved
}

function Write-CycLifecycleAtomicJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value,
        [int]$Depth = 12
    )
    $resolved = Resolve-CycLifecyclePath $Path
    $parent = Split-Path -Parent $resolved
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw 'Lifecycle journal parent is missing.'
    }
    $temporary = Join-Path $parent ('.cyc-lifecycle-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $backup = Join-Path $parent ('.cyc-lifecycle-' + [Guid]::NewGuid().ToString('N') + '.bak')
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $bytes = $utf8.GetBytes(($Value | ConvertTo-Json -Depth $Depth -Compress) + "`n")
    $stream = $null
    $committed = $false
    try {
        $stream = New-Object System.IO.FileStream(
            $temporary,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None,
            4096,
            [System.IO.FileOptions]::WriteThrough
        )
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        if (Test-Path -LiteralPath $resolved) {
            $destination = Get-Item -LiteralPath $resolved -Force
            if ($destination.PSIsContainer -or
                ($destination.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Lifecycle journal destination must be a regular file.'
            }
            [System.IO.File]::Replace($temporary, $resolved, $backup, $true)
        } else {
            [System.IO.File]::Move($temporary, $resolved)
        }
        # The temporary file was flushed through before the same-directory
        # atomic replace/move.  The replace is the commit point.  Never perform
        # another fallible open after that point: an AV/share lock must not make
        # callers compensate a transition that is already durable on disk.
        $committed = $true
    } finally {
        if ($stream) { try { $stream.Dispose() } catch { } }
        try {
            if (Test-Path -LiteralPath $temporary) {
                Remove-Item -LiteralPath $temporary -Force
            }
        } catch { }
        try {
            if ($committed -and (Test-Path -LiteralPath $backup)) {
                Remove-Item -LiteralPath $backup -Force
            }
        } catch { }
    }
}

function Publish-CycLifecycleReceiptAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)]$Request,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{64}$')][string]$RequestHash
    )
    $source = Resolve-CycLifecyclePath $SourcePath
    $destination = Resolve-CycLifecyclePath $DestinationPath
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw 'Firewall receipt source is missing.'
    }
    $sourceItem = Get-Item -LiteralPath $source -Force
    if (($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $sourceItem.Length -lt 2 -or $sourceItem.Length -gt 32768) {
        throw 'Firewall receipt source must be a bounded regular file.'
    }
    $destinationParent = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
        throw 'Durable firewall receipt directory is missing.'
    }
    if (Test-Path -LiteralPath $destination) {
        $destinationItem = Get-Item -LiteralPath $destination -Force
        if ($destinationItem.PSIsContainer -or
            ($destinationItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Durable firewall receipt destination must be a regular file.'
        }
    }

    # Capture, parse, validate, hash, and publish the same byte sequence.  This
    # avoids both Copy-Item truncation windows and a source-swap TOCTOU between
    # receipt validation and publication.
    $bytes = [System.IO.File]::ReadAllBytes($source)
    if ($bytes.Length -lt 2 -or $bytes.Length -gt 32768) {
        throw 'Firewall receipt source must be a bounded regular file.'
    }
    try {
        $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
        $raw = $utf8Strict.GetString($bytes)
        $converter = Get-Command ConvertFrom-Json -CommandType Cmdlet -ErrorAction Stop
        $receipt = if ($converter.Parameters.ContainsKey('DateKind')) {
            ConvertFrom-Json -InputObject $raw -DateKind String
        } else {
            ConvertFrom-Json -InputObject $raw
        }
    } catch {
        throw 'Firewall receipt source contains invalid UTF-8 JSON.'
    }
    [void](Assert-CycFirewallReceipt -Receipt $receipt -Request $Request -RequestHash $RequestHash)
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = ([System.BitConverter]::ToString($hasher.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $hasher.Dispose()
    }

    $temporary = Join-Path $destinationParent ('.cyc-receipt-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $backup = Join-Path $destinationParent ('.cyc-receipt-' + [Guid]::NewGuid().ToString('N') + '.bak')
    $stream = $null
    $committed = $false
    try {
        $stream = New-Object System.IO.FileStream(
            $temporary,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None,
            4096,
            [System.IO.FileOptions]::WriteThrough
        )
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        if (Test-Path -LiteralPath $destination) {
            [System.IO.File]::Replace($temporary, $destination, $backup, $true)
        } else {
            [System.IO.File]::Move($temporary, $destination)
        }
        $committed = $true
    } finally {
        if ($stream) { try { $stream.Dispose() } catch { } }
        try {
            if (Test-Path -LiteralPath $temporary) {
                Remove-Item -LiteralPath $temporary -Force
            }
        } catch { }
        try {
            if ($committed -and (Test-Path -LiteralPath $backup)) {
                Remove-Item -LiteralPath $backup -Force
            }
        } catch { }
    }
    return [PSCustomObject]@{ receipt = $receipt; sha256 = $digest; path = $destination }
}

function Read-CycLifecycleJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][long]$MaximumBytes,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $resolved = Resolve-CycLifecyclePath $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { return $null }
    $item = Get-Item -LiteralPath $resolved -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -lt 2 -or $item.Length -gt $MaximumBytes) {
        throw "$Label must be a bounded regular file."
    }
    try {
        $raw = Get-Content -LiteralPath $resolved -Raw
        $converter = Get-Command ConvertFrom-Json -CommandType Cmdlet -ErrorAction Stop
        if ($converter.Parameters.ContainsKey('DateKind')) {
            return ConvertFrom-Json -InputObject $raw -DateKind String
        }
        return ConvertFrom-Json -InputObject $raw
    } catch {
        throw "$Label contains invalid JSON."
    }
}

function Assert-CycLifecycleJournal {
    param(
        [Parameter(Mandatory = $true)]$Journal,
        [Parameter(Mandatory = $true)]$Binding,
        [Parameter(Mandatory = $true)]$Roots,
        [Parameter(Mandatory = $true)][string]$PrivateReceiptRoot
    )
    Assert-CycLifecycleExactProperties -Object $Journal -Label 'Firewall lifecycle journal' -Expected @(
        'action', 'dataRoot', 'exchangeRoot', 'helperSha256', 'initiatorLocalAppData',
        'initiatorProfile', 'initiatorSid', 'installRoot', 'packageManifestSha256',
        'phase', 'privateReceiptPath', 'requestPath', 'requestSha256', 'schemaVersion',
        'transactionId', 'updatedAtUtc'
    )
    if ([string]$Journal.schemaVersion -cne $script:CycLifecycleJournalSchema -or
        [string]$Journal.transactionId -cnotmatch '^[0-9a-f]{32}$' -or
        [string]$Journal.action -cnotin @('Install', 'Repair', 'Uninstall') -or
        [string]$Journal.phase -cnotin @('prepared', 'firewallApplied', 'coreApplied', 'complete') -or
        [string]$Journal.requestSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$Journal.helperSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$Journal.packageManifestSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Firewall lifecycle journal metadata is invalid.'
    }
    [void](Assert-CycInitiatorStillCurrent -Binding ([PSCustomObject]@{
        sid = [string]$Journal.initiatorSid
        profile = [string]$Journal.initiatorProfile
        localAppData = [string]$Journal.initiatorLocalAppData
    }))
    if (-not [string]::Equals(
            (Resolve-CycLifecyclePath ([string]$Journal.installRoot)),
            (Resolve-CycLifecyclePath ([string]$Roots.installRoot)),
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        -not [string]::Equals(
            (Resolve-CycLifecyclePath ([string]$Journal.dataRoot)),
            (Resolve-CycLifecyclePath ([string]$Roots.dataRoot)),
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'Firewall lifecycle journal roots do not match this per-user installation.'
    }
    $commonDocuments = [Environment]::GetFolderPath('CommonDocuments')
    if ([string]::IsNullOrWhiteSpace($commonDocuments)) {
        throw 'Public Documents is unavailable.'
    }
    $expectedExchangeRoot = Join-Path `
        (Join-Path `
            (Join-Path $commonDocuments $script:CycFirewallExchangeDirectory) `
            ([string]$Binding.sid).Replace('-', '_')) `
        ([string]$Journal.transactionId)
    $exchangeRoot = Resolve-CycLifecyclePath ([string]$Journal.exchangeRoot)
    if (-not [string]::Equals(
            $exchangeRoot,
            (Resolve-CycLifecyclePath $expectedExchangeRoot),
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        -not [string]::Equals(
            (Resolve-CycLifecyclePath ([string]$Journal.requestPath)),
            (Resolve-CycLifecyclePath (Join-Path $exchangeRoot 'request.json')),
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        -not [string]::Equals(
            (Resolve-CycLifecyclePath ([string]$Journal.privateReceiptPath)),
            (Resolve-CycLifecyclePath (Join-Path $PrivateReceiptRoot (([string]$Journal.transactionId) + '.json'))),
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'Firewall lifecycle journal paths are not bound to its transaction.'
    }
    return $Journal
}

function Remove-CycCompletedLifecycleJournal {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TransactionId,
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Repair', 'Uninstall')][string]$ExpectedAction,
        [Parameter(Mandatory = $true)][string]$ExpectedRequestSha256,
        [switch]$BestEffort
    )
    try {
        $current = Read-CycLifecycleJson -Path $Path -MaximumBytes 65536 -Label 'Firewall lifecycle journal'
        if (-not $current -or [string]$current.schemaVersion -cne $script:CycLifecycleJournalSchema -or
            [string]$current.transactionId -cne $TransactionId -or
            [string]$current.action -cne $ExpectedAction -or
            [string]$current.requestSha256 -cne $ExpectedRequestSha256 -or
            [string]$current.phase -cne 'complete') {
            throw 'Refusing to retire a lifecycle journal that is not the completed active transaction.'
        }
        Remove-Item -LiteralPath (Resolve-CycLifecyclePath $Path) -Force
        if (Test-Path -LiteralPath (Resolve-CycLifecyclePath $Path)) {
            throw 'Completed lifecycle journal remained present after retirement.'
        }
        return $true
    } catch {
        if ($BestEffort) { return $false }
        throw
    }
}

function Write-CycLifecycleActiveJournal {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value,
        [string]$ExpectedCompletedTransactionId,
        [string]$ExpectedCompletedRequestSha256,
        [string]$ExpectedCompletedAction
    )
    $current = Read-CycLifecycleJson -Path $Path -MaximumBytes 65536 -Label 'Firewall lifecycle journal'
    if ([string]::IsNullOrWhiteSpace($ExpectedCompletedTransactionId)) {
        if ($current) {
            throw 'Refusing to overwrite an active lifecycle transaction.'
        }
    } else {
        if (-not $current -or [string]$current.schemaVersion -cne $script:CycLifecycleJournalSchema -or
            [string]$current.phase -cne 'complete' -or
            [string]$current.transactionId -cne $ExpectedCompletedTransactionId -or
            [string]$current.requestSha256 -cne $ExpectedCompletedRequestSha256 -or
            [string]$current.action -cne $ExpectedCompletedAction) {
            throw 'Completed lifecycle transaction changed before the next transaction could replace it.'
        }
    }
    Write-CycLifecycleAtomicJson -Path $Path -Value $Value
}

function Test-CycFirewallReceiptJournalBinding {
    param(
        [AllowNull()]$Receipt,
        [Parameter(Mandatory = $true)]$Journal
    )
    if (-not $Receipt) { return $false }
    try {
        Assert-CycLifecycleExactProperties -Object $Receipt -Label 'Firewall receipt' -Expected @(
            'action', 'failureCode', 'initiatorLocalAppData', 'initiatorProfile',
            'initiatorSid', 'port', 'program', 'programSha256', 'requestSha256',
            'result', 'ruleName', 'schemaVersion', 'transactionId', 'verifiedAtUtc'
        )
        $expectedAction = if ([string]$Journal.action -ceq 'Uninstall') { 'Remove' } else { 'Apply' }
        $expectedProgram = Resolve-CycLifecyclePath (Join-Path ([string]$Journal.installRoot) 'cyc-controller.exe')
        $expectedRule = 'ClusterYourCodex.ManagedWorker.' + ([string]$Journal.initiatorSid).Replace('-', '_')
        $verifiedAt = [DateTimeOffset]::MinValue
        $timestampStyle = [System.Globalization.DateTimeStyles]::RoundtripKind
        $timestampValid = (
            [string]$Receipt.verifiedAtUtc -cmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}(?:Z|[+-]\d{2}:\d{2})$' -and
            [DateTimeOffset]::TryParse(
                [string]$Receipt.verifiedAtUtc,
                [System.Globalization.CultureInfo]::InvariantCulture,
                $timestampStyle,
                [ref]$verifiedAt
            )
        )
        $failureBindingValid = switch ([string]$Receipt.result) {
            'verified' { $null -eq $Receipt.failureCode; break }
            'rolledBack' {
                [string]$Receipt.failureCode -cin @(
                    'cancelled-before-apply',
                    'coordinator-cancelled-or-timed-out',
                    'helper-failure'
                )
                break
            }
            'rollbackFailed' {
                [string]$Receipt.failureCode -ceq 'helper-and-rollback-failure'
                break
            }
            default { $false }
        }
        return (
            [string]$Receipt.schemaVersion -ceq $script:CycFirewallReceiptSchema -and
            [string]$Receipt.transactionId -ceq [string]$Journal.transactionId -and
            [string]$Receipt.requestSha256 -ceq [string]$Journal.requestSha256 -and
            [string]$Receipt.action -ceq $expectedAction -and
            [string]$Receipt.result -cin @('verified', 'rolledBack', 'rollbackFailed') -and
            $failureBindingValid -and
            $timestampValid -and
            [string]$Receipt.initiatorSid -ceq [string]$Journal.initiatorSid -and
            [string]::Equals(
                (Resolve-CycLifecyclePath ([string]$Receipt.initiatorProfile)),
                (Resolve-CycLifecyclePath ([string]$Journal.initiatorProfile)),
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and
            [string]::Equals(
                (Resolve-CycLifecyclePath ([string]$Receipt.initiatorLocalAppData)),
                (Resolve-CycLifecyclePath ([string]$Journal.initiatorLocalAppData)),
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and
            [string]::Equals(
                (Resolve-CycLifecyclePath ([string]$Receipt.program)),
                $expectedProgram,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and
            [string]$Receipt.programSha256 -cmatch '^[0-9a-f]{64}$' -and
            [int]$Receipt.port -ge 1 -and [int]$Receipt.port -le 65535 -and
            [string]$Receipt.ruleName -ceq $expectedRule
        )
    } catch {
        return $false
    }
}

function Test-CycInstallCoreCommitBinding {
    param(
        [AllowNull()]$Manifest,
        [Parameter(Mandatory = $true)]$Journal
    )
    try {
        if (-not $Manifest -or -not $Manifest.PSObject.Properties['coreCommit']) { return $false }
        $marker = $Manifest.coreCommit
        Assert-CycLifecycleExactProperties -Object $marker -Label 'Install core commit marker' -Expected @(
            'action', 'committedAtUtc', 'requestSha256', 'schemaVersion', 'state', 'transactionId'
        )
        $committedAt = [DateTimeOffset]::MinValue
        $timestampStyle = [System.Globalization.DateTimeStyles]::RoundtripKind
        return (
            [string]$marker.schemaVersion -ceq $script:CycCoreCommitSchema -and
            [string]$marker.action -ceq [string]$Journal.action -and
            [string]$marker.state -ceq 'committed' -and
            [string]$marker.transactionId -ceq [string]$Journal.transactionId -and
            [string]$marker.requestSha256 -ceq [string]$Journal.requestSha256 -and
            [string]$marker.committedAtUtc -cmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}(?:Z|[+-]\d{2}:\d{2})$' -and
            [DateTimeOffset]::TryParse(
                [string]$marker.committedAtUtc,
                [System.Globalization.CultureInfo]::InvariantCulture,
                $timestampStyle,
                [ref]$committedAt
            )
        )
    } catch {
        return $false
    }
}

function Test-CycAppliedFirewallManifestBinding {
    param(
        [AllowNull()]$Manifest,
        [Parameter(Mandatory = $true)]$Journal,
        [Parameter(Mandatory = $true)]$Receipt,
        [Parameter(Mandatory = $true)][string]$ReceiptSha256
    )
    try {
        if (-not (Test-CycInstallCoreCommitBinding -Manifest $Manifest -Journal $Journal) -or
            -not $Manifest.PSObject.Properties['managedWorker'] -or
            -not $Manifest.managedWorker.PSObject.Properties['firewall'] -or
            -not $Manifest.PSObject.Properties['initiator'] -or
            -not $Manifest.PSObject.Properties['files']) {
            return $false
        }
        $firewall = $Manifest.managedWorker.firewall
        $controllerRecords = @($Manifest.files | Where-Object {
            [string]$_.relativePath -ceq 'cyc-controller.exe'
        })
        return (
            $ReceiptSha256 -cmatch '^[0-9a-f]{64}$' -and
            [string]$Manifest.schemaVersion -ceq 'cyc.dev/windows-install-manifest/v1' -and
            [string]::Equals(
                (Resolve-CycLifecyclePath ([string]$Manifest.installRoot)),
                (Resolve-CycLifecyclePath ([string]$Journal.installRoot)),
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and
            [string]::Equals(
                (Resolve-CycLifecyclePath ([string]$Manifest.dataRoot)),
                (Resolve-CycLifecyclePath ([string]$Journal.dataRoot)),
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and
            [string]$Manifest.initiator.sid -ceq [string]$Journal.initiatorSid -and
            [string]::Equals(
                (Resolve-CycLifecyclePath ([string]$Manifest.initiator.profile)),
                (Resolve-CycLifecyclePath ([string]$Journal.initiatorProfile)),
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and
            [string]::Equals(
                (Resolve-CycLifecyclePath ([string]$Manifest.initiator.localAppData)),
                (Resolve-CycLifecyclePath ([string]$Journal.initiatorLocalAppData)),
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and
            ($firewall.enabled -is [bool]) -and [bool]$firewall.enabled -and
            [string]$firewall.lifecycle -ceq $script:CycFirewallLifecycleName -and
            [string]$firewall.transactionId -ceq [string]$Journal.transactionId -and
            [string]$firewall.requestSha256 -ceq [string]$Journal.requestSha256 -and
            [string]$firewall.receiptSha256 -cmatch '^[0-9a-f]{64}$' -and
            [string]$firewall.receiptSha256 -ceq $ReceiptSha256 -and
            [string]$firewall.state -ceq 'applied' -and
            [string]$firewall.appliedAtUtc -ceq [string]$Receipt.verifiedAtUtc -and
            [string]$firewall.name -ceq [string]$Receipt.ruleName -and
            [string]::Equals(
                (Resolve-CycLifecyclePath ([string]$firewall.program)),
                (Resolve-CycLifecyclePath ([string]$Receipt.program)),
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and
            [int]$firewall.port -eq [int]$Receipt.port -and
            $controllerRecords.Count -eq 1 -and
            [string]$controllerRecords[0].sha256 -ceq [string]$Receipt.programSha256
        )
    } catch {
        return $false
    }
}

function Test-CycPendingFirewallManifestBinding {
    param(
        [AllowNull()]$Manifest,
        [Parameter(Mandatory = $true)]$Journal,
        [Parameter(Mandatory = $true)]$Receipt
    )
    try {
        if (-not (Test-CycInstallCoreCommitBinding -Manifest $Manifest -Journal $Journal) -or
            -not $Manifest.PSObject.Properties['managedWorker'] -or
            -not $Manifest.managedWorker.PSObject.Properties['firewall'] -or
            -not $Manifest.PSObject.Properties['initiator'] -or
            -not $Manifest.PSObject.Properties['files']) {
            return $false
        }
        $firewall = $Manifest.managedWorker.firewall
        $controllerRecords = @($Manifest.files | Where-Object {
            [string]$_.relativePath -ceq 'cyc-controller.exe'
        })
        return (
            [string]$Manifest.schemaVersion -ceq 'cyc.dev/windows-install-manifest/v1' -and
            [string]::Equals(
                (Resolve-CycLifecyclePath ([string]$Manifest.installRoot)),
                (Resolve-CycLifecyclePath ([string]$Journal.installRoot)),
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and
            [string]::Equals(
                (Resolve-CycLifecyclePath ([string]$Manifest.dataRoot)),
                (Resolve-CycLifecyclePath ([string]$Journal.dataRoot)),
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and
            [string]$Manifest.initiator.sid -ceq [string]$Journal.initiatorSid -and
            [string]::Equals(
                (Resolve-CycLifecyclePath ([string]$Manifest.initiator.profile)),
                (Resolve-CycLifecyclePath ([string]$Journal.initiatorProfile)),
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and
            [string]::Equals(
                (Resolve-CycLifecyclePath ([string]$Manifest.initiator.localAppData)),
                (Resolve-CycLifecyclePath ([string]$Journal.initiatorLocalAppData)),
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and
            ($firewall.enabled -is [bool]) -and [bool]$firewall.enabled -and
            [string]$firewall.lifecycle -ceq $script:CycFirewallLifecycleName -and
            [string]$firewall.transactionId -ceq [string]$Journal.transactionId -and
            [string]$firewall.requestSha256 -ceq [string]$Journal.requestSha256 -and
            [string]$firewall.state -ceq 'pending' -and
            $null -eq $firewall.receiptSha256 -and
            $null -eq $firewall.appliedAtUtc -and
            [string]$firewall.name -ceq [string]$Receipt.ruleName -and
            [string]::Equals(
                (Resolve-CycLifecyclePath ([string]$firewall.program)),
                (Resolve-CycLifecyclePath ([string]$Receipt.program)),
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and
            [int]$firewall.port -eq [int]$Receipt.port -and
            $controllerRecords.Count -eq 1 -and
            [string]$controllerRecords[0].sha256 -ceq [string]$Receipt.programSha256
        )
    } catch {
        return $false
    }
}

function Test-CycFirewallRequestJournalBinding {
    param(
        [AllowNull()]$Request,
        [Parameter(Mandatory = $true)]$Journal
    )
    try {
        if (-not $Request) { return $false }
        Assert-CycLifecycleExactProperties -Object $Request -Label 'Recovered firewall request' -Expected @(
            'action', 'createdAtUtc', 'deadlineUtc', 'displayName', 'exchangeRoot',
            'group', 'helperAuthenticodeRequired', 'initiatorLocalAppData',
            'initiatorProfile', 'initiatorSid', 'installRoot', 'packageExecutable',
            'packageManifestSha256', 'port', 'program', 'programSha256',
            'remoteAddress', 'requestNonce', 'ruleDescription', 'ruleName',
            'schemaVersion', 'transactionId'
        )
        $createdAt = [DateTimeOffset]::MinValue
        $deadlineAt = [DateTimeOffset]::MinValue
        $timestampStyle = [System.Globalization.DateTimeStyles]::RoundtripKind
        $expectedAction = if ([string]$Journal.action -ceq 'Uninstall') { 'Remove' } else { 'Apply' }
        $expectedRule = 'ClusterYourCodex.ManagedWorker.' + ([string]$Journal.initiatorSid).Replace('-', '_')
        return (
            [string]$Request.schemaVersion -ceq $script:CycFirewallRequestSchema -and
            [string]$Request.transactionId -ceq [string]$Journal.transactionId -and
            [string]$Request.requestNonce -cmatch '^[0-9a-f]{64}$' -and
            [string]$Request.action -ceq $expectedAction -and
            [string]$Request.initiatorSid -ceq [string]$Journal.initiatorSid -and
            [string]::Equals(
                (Resolve-CycLifecyclePath ([string]$Request.initiatorProfile)),
                (Resolve-CycLifecyclePath ([string]$Journal.initiatorProfile)),
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and
            [string]::Equals(
                (Resolve-CycLifecyclePath ([string]$Request.initiatorLocalAppData)),
                (Resolve-CycLifecyclePath ([string]$Journal.initiatorLocalAppData)),
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and
            [string]::Equals(
                (Resolve-CycLifecyclePath ([string]$Request.installRoot)),
                (Resolve-CycLifecyclePath ([string]$Journal.installRoot)),
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and
            [string]::Equals(
                (Resolve-CycLifecyclePath ([string]$Request.exchangeRoot)),
                (Resolve-CycLifecyclePath ([string]$Journal.exchangeRoot)),
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and
            [string]::Equals(
                (Resolve-CycLifecyclePath ([string]$Request.program)),
                (Resolve-CycLifecyclePath (Join-Path ([string]$Journal.installRoot) 'cyc-controller.exe')),
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and
            [string]$Request.programSha256 -cmatch '^[0-9a-f]{64}$' -and
            [string]$Request.packageManifestSha256 -ceq [string]$Journal.packageManifestSha256 -and
            [int]$Request.port -ge 1 -and [int]$Request.port -le 65535 -and
            [string]$Request.ruleName -ceq $expectedRule -and
            [string]$Request.displayName -ceq $script:CycFirewallDisplayName -and
            [string]$Request.group -ceq $script:CycFirewallRuleGroup -and
            [string]$Request.ruleDescription -ceq $script:CycFirewallRuleDescription -and
            [string]$Request.remoteAddress -ceq 'LocalSubnet' -and
            ($Request.helperAuthenticodeRequired -is [bool]) -and
            [string]$Request.createdAtUtc -cmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}(?:Z|[+-]\d{2}:\d{2})$' -and
            [DateTimeOffset]::TryParse(
                [string]$Request.createdAtUtc,
                [System.Globalization.CultureInfo]::InvariantCulture,
                $timestampStyle,
                [ref]$createdAt
            ) -and
            [string]$Request.deadlineUtc -cmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}(?:Z|[+-]\d{2}:\d{2})$' -and
            [DateTimeOffset]::TryParse(
                [string]$Request.deadlineUtc,
                [System.Globalization.CultureInfo]::InvariantCulture,
                $timestampStyle,
                [ref]$deadlineAt
            ) -and
            $deadlineAt -gt $createdAt -and
            ($deadlineAt - $createdAt).TotalMinutes -le 35
        )
    } catch {
        return $false
    }
}

function Test-CycPendingFirewallManifestRequestBinding {
    param(
        [AllowNull()]$Manifest,
        [Parameter(Mandatory = $true)]$Journal,
        [AllowNull()]$Request
    )
    try {
        if (-not (Test-CycFirewallRequestJournalBinding -Request $Request -Journal $Journal) -or
            -not (Test-CycInstallCoreCommitBinding -Manifest $Manifest -Journal $Journal) -or
            [string]$Journal.action -cnotin @('Install', 'Repair') -or
            [string]$Request.action -cne 'Apply' -or
            -not $Manifest -or -not $Manifest.PSObject.Properties['managedWorker'] -or
            -not $Manifest.managedWorker.PSObject.Properties['firewall'] -or
            -not $Manifest.PSObject.Properties['initiator'] -or
            -not $Manifest.PSObject.Properties['files']) {
            return $false
        }
        $firewall = $Manifest.managedWorker.firewall
        $controllerRecords = @($Manifest.files | Where-Object {
            [string]$_.relativePath -ceq 'cyc-controller.exe'
        })
        return (
            [string]$Manifest.schemaVersion -ceq 'cyc.dev/windows-install-manifest/v1' -and
            [string]::Equals(
                (Resolve-CycLifecyclePath ([string]$Manifest.installRoot)),
                (Resolve-CycLifecyclePath ([string]$Journal.installRoot)),
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and
            [string]::Equals(
                (Resolve-CycLifecyclePath ([string]$Manifest.dataRoot)),
                (Resolve-CycLifecyclePath ([string]$Journal.dataRoot)),
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and
            [string]$Manifest.initiator.sid -ceq [string]$Journal.initiatorSid -and
            [string]::Equals(
                (Resolve-CycLifecyclePath ([string]$Manifest.initiator.profile)),
                (Resolve-CycLifecyclePath ([string]$Journal.initiatorProfile)),
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and
            [string]::Equals(
                (Resolve-CycLifecyclePath ([string]$Manifest.initiator.localAppData)),
                (Resolve-CycLifecyclePath ([string]$Journal.initiatorLocalAppData)),
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and
            ($firewall.enabled -is [bool]) -and [bool]$firewall.enabled -and
            [string]$firewall.lifecycle -ceq $script:CycFirewallLifecycleName -and
            [string]$firewall.transactionId -ceq [string]$Journal.transactionId -and
            [string]$firewall.requestSha256 -ceq [string]$Journal.requestSha256 -and
            [string]$firewall.state -ceq 'pending' -and
            $null -eq $firewall.receiptSha256 -and
            $null -eq $firewall.appliedAtUtc -and
            [string]$firewall.name -ceq [string]$Request.ruleName -and
            [string]::Equals(
                (Resolve-CycLifecyclePath ([string]$firewall.program)),
                (Resolve-CycLifecyclePath ([string]$Request.program)),
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and
            [int]$firewall.port -eq [int]$Request.port -and
            $controllerRecords.Count -eq 1 -and
            [string]$controllerRecords[0].sha256 -ceq [string]$Request.programSha256
        )
    } catch {
        return $false
    }
}

function Test-CycLifecycleCoreCommitAfterImage {
    param(
        [Parameter(Mandatory = $true)]$Journal,
        [AllowNull()]$Manifest,
        [AllowNull()]$Request
    )
    if ([string]$Journal.action -cin @('Install', 'Repair')) {
        return Test-CycPendingFirewallManifestRequestBinding `
            -Manifest $Manifest `
            -Journal $Journal `
            -Request $Request
    }
    if ([string]$Journal.action -ceq 'Uninstall') {
        return (-not $Manifest) -and
            (Test-CycFirewallRequestJournalBinding -Request $Request -Journal $Journal) -and
            [string]$Request.action -ceq 'Remove'
    }
    return $false
}

function Get-CycRolledBackUninstallRetryEvidence {
    param(
        [AllowNull()]$Journal,
        [AllowNull()]$Receipt,
        [AllowNull()]$Manifest,
        [AllowNull()]$Request,
        [Parameter(Mandatory = $true)][string]$RequestedAction
    )
    if ($RequestedAction -cne 'Uninstall' -or -not $Journal -or -not $Receipt -or -not $Request -or $Manifest -or
        [string]$Journal.action -cne 'Uninstall' -or
        [string]$Receipt.result -cne 'rolledBack' -or
        [string]$Request.action -cne 'Remove' -or
        -not (Test-CycFirewallReceiptJournalBinding -Receipt $Receipt -Journal $Journal) -or
        -not (Test-CycFirewallRequestJournalBinding -Request $Request -Journal $Journal)) {
        return $null
    }
    if ([string]$Request.programSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$Request.packageManifestSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        [int]$Request.port -lt 1 -or [int]$Request.port -gt 65535) {
        throw 'Rolled-back Uninstall retry evidence is malformed.'
    }
    return [PSCustomObject]@{
        predecessorTransactionId = [string]$Journal.transactionId
        predecessorRequestSha256 = [string]$Journal.requestSha256
        predecessorAction = [string]$Journal.action
        programSha256 = [string]$Request.programSha256
        packageManifestSha256 = [string]$Request.packageManifestSha256
        port = [int]$Request.port
    }
}

function Complete-CycPreCoreFirewallRecovery {
    param(
        [Parameter(Mandatory = $true)]$Journal,
        [Parameter(Mandatory = $true)]$Receipt,
        [AllowNull()]$Manifest,
        [Parameter(Mandatory = $true)]$Request,
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Repair', 'Uninstall')][string]$RequestedAction,
        [Parameter(Mandatory = $true)][string]$JournalPath
    )
    $retryEvidence = Get-CycRolledBackUninstallRetryEvidence `
        -Journal $Journal `
        -Receipt $Receipt `
        -Manifest $Manifest `
        -Request $Request `
        -RequestedAction $RequestedAction

    # The complete write is the predecessor tombstone commit point.  If an
    # absent-manifest Uninstall needs another Remove, leave these exact journal
    # bytes in place until Write-CycLifecycleActiveJournal replaces them by CAS.
    # A crash before successor publication can therefore reconstruct the retry
    # from the immutable request and atomically published rolledBack receipt.
    $Journal.phase = 'complete'
    $Journal.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    Write-CycLifecycleAtomicJson -Path $JournalPath -Value $Journal
    if ($retryEvidence) {
        return [PSCustomObject]@{
            retryEvidence = $retryEvidence
            replaceCompletedTransactionId = [string]$Journal.transactionId
            replaceCompletedRequestSha256 = [string]$Journal.requestSha256
            replaceCompletedAction = [string]$Journal.action
        }
    }

    [void](Remove-CycCompletedLifecycleJournal `
        -Path $JournalPath `
        -TransactionId ([string]$Journal.transactionId) `
        -ExpectedAction ([string]$Journal.action) `
        -ExpectedRequestSha256 ([string]$Journal.requestSha256))
    return [PSCustomObject]@{
        retryEvidence = $null
        replaceCompletedTransactionId = $null
        replaceCompletedRequestSha256 = $null
        replaceCompletedAction = $null
    }
}

function Get-CycFirewallResumeDecision {
    param(
        $Journal,
        $Receipt,
        $Manifest,
        [string]$ReceiptSha256,
        [Parameter(Mandatory = $true)][string]$RequestedAction
    )
    if (-not $Journal) { return 'Start' }
    if ([string]$Journal.schemaVersion -cne $script:CycLifecycleJournalSchema -or
        [string]$Journal.action -cnotin @('Install', 'Repair', 'Uninstall')) {
        return 'Reject'
    }
    if ($Receipt -and -not (Test-CycFirewallReceiptJournalBinding -Receipt $Receipt -Journal $Journal)) {
        return 'Reject'
    }
    if ($Receipt -and [string]$Receipt.result -ceq 'rollbackFailed') {
        if ([string]$Journal.phase -cin @('prepared', 'firewallApplied', 'coreApplied') -and
            [string]$Journal.action -ceq $RequestedAction) {
            # Before core commit, retry the exact persisted snapshot rollback.
            # After core commit, re-establish the exact desired firewall state.
            # Both paths replace the prior failed-compensation receipt only
            # after their corresponding state transition is durable.
            return 'Resume'
        }
        return 'Reject'
    }
    if ($Receipt -and [string]$Receipt.result -ceq 'rolledBack') {
        return 'RetireAbortedThenStart'
    }
    if ([string]$Journal.phase -ceq 'complete') {
        if (-not $Receipt -or [string]$Receipt.result -cne 'verified' -or
            $ReceiptSha256 -cnotmatch '^[0-9a-f]{64}$') {
            return 'Reject'
        }
        if ([string]$Journal.action -cin @('Install', 'Repair')) {
            if (Test-CycAppliedFirewallManifestBinding `
                -Manifest $Manifest `
                -Journal $Journal `
                -Receipt $Receipt `
                -ReceiptSha256 $ReceiptSha256) {
                return 'RetireThenStart'
            }
            return 'Reject'
        }
        if ([string]$Journal.action -ceq 'Uninstall' -and -not $Manifest) {
            return 'RetireThenStart'
        }
        return 'Reject'
    }
    if ([string]$Journal.action -cne $RequestedAction) { return 'Reject' }
    if ($Receipt) {
        if ([string]$Receipt.result -ceq 'verified') {
            if ($RequestedAction -eq 'Uninstall') {
                if (-not $Manifest) { return 'Complete' }
                return 'Reject'
            }
            if (Test-CycAppliedFirewallManifestBinding `
                -Manifest $Manifest `
                -Journal $Journal `
                -Receipt $Receipt `
                -ReceiptSha256 $ReceiptSha256) {
                return 'Complete'
            }
            if (Test-CycPendingFirewallManifestBinding `
                -Manifest $Manifest `
                -Journal $Journal `
                -Receipt $Receipt) {
                return 'Commit'
            }
            return 'Reject'
        }
        return 'Reject'
    }
    if ([string]$Journal.phase -cin @('firewallApplied', 'coreApplied')) { return 'Resume' }
    return 'Restart'
}

function Assert-CycFirewallReceipt {
    param(
        [Parameter(Mandatory = $true)]$Receipt,
        [Parameter(Mandatory = $true)]$Request,
        [Parameter(Mandatory = $true)][string]$RequestHash
    )
    Assert-CycLifecycleExactProperties -Object $Receipt -Label 'Firewall receipt' -Expected @(
        'action', 'failureCode', 'initiatorLocalAppData', 'initiatorProfile',
        'initiatorSid', 'port', 'program', 'programSha256', 'requestSha256',
        'result', 'ruleName', 'schemaVersion', 'transactionId', 'verifiedAtUtc'
    )
    $verifiedAt = [DateTimeOffset]::MinValue
    $timestampStyle = [System.Globalization.DateTimeStyles]::RoundtripKind
    $timestampValid = (
        [string]$Receipt.verifiedAtUtc -cmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}(?:Z|[+-]\d{2}:\d{2})$' -and
        [DateTimeOffset]::TryParse(
            [string]$Receipt.verifiedAtUtc,
            [System.Globalization.CultureInfo]::InvariantCulture,
            $timestampStyle,
            [ref]$verifiedAt
        )
    )
    $failureBindingValid = switch ([string]$Receipt.result) {
        'verified' { $null -eq $Receipt.failureCode; break }
        'rolledBack' {
            [string]$Receipt.failureCode -cin @(
                'cancelled-before-apply',
                'coordinator-cancelled-or-timed-out',
                'helper-failure'
            )
            break
        }
        'rollbackFailed' {
            [string]$Receipt.failureCode -ceq 'helper-and-rollback-failure'
            break
        }
        default { $false }
    }
    if ([string]$Receipt.schemaVersion -cne $script:CycFirewallReceiptSchema -or
        [string]$Receipt.transactionId -cne [string]$Request.transactionId -or
        [string]$Receipt.requestSha256 -cne $RequestHash -or
        [string]$Receipt.action -cne [string]$Request.action -or
        [string]$Receipt.initiatorSid -cne [string]$Request.initiatorSid -or
        -not [string]::Equals((Resolve-CycLifecyclePath ([string]$Receipt.initiatorProfile)), (Resolve-CycLifecyclePath ([string]$Request.initiatorProfile)), [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals((Resolve-CycLifecyclePath ([string]$Receipt.initiatorLocalAppData)), (Resolve-CycLifecyclePath ([string]$Request.initiatorLocalAppData)), [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]$Receipt.ruleName -cne [string]$Request.ruleName -or
        [string]$Receipt.program -cne [string]$Request.program -or
        [string]$Receipt.programSha256 -cne [string]$Request.programSha256 -or
        [int]$Receipt.port -ne [int]$Request.port -or
        [string]$Receipt.result -cnotin @('verified', 'rolledBack', 'rollbackFailed') -or
        -not $failureBindingValid -or -not $timestampValid) {
        throw 'Firewall receipt is not bound to the exact approved request.'
    }
    return $Receipt
}

function Get-CycLifecycleResponseReplacementWaitDigest {
    param(
        [Parameter(Mandatory = $true)]$Receipt,
        [Parameter(Mandatory = $true)][string]$Sha256BeforeRead,
        [Parameter(Mandatory = $true)][string]$Sha256AfterRead,
        [Parameter(Mandatory = $true)][ValidateSet('verified', 'rolledBack')][string]$ExpectedResult
    )
    foreach ($digest in @($Sha256BeforeRead, $Sha256AfterRead)) {
        if ($digest -cnotmatch '^[0-9a-f]{64}$') {
            throw 'Pre-recovery response digest is invalid.'
        }
    }
    if ($Sha256BeforeRead -cne $Sha256AfterRead -or
        [string]$Receipt.result -ceq $ExpectedResult) {
        return $null
    }
    if ([string]$Receipt.result -cin @('rolledBack', 'rollbackFailed')) {
        return $Sha256AfterRead
    }
    return $null
}

function Wait-CycLifecycleFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][DateTimeOffset]$Deadline,
        [System.Diagnostics.Process]$Process,
        [string]$PreviousSha256
    )
    if (-not [string]::IsNullOrWhiteSpace($PreviousSha256) -and
        $PreviousSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Previous lifecycle file digest is invalid.'
    }
    do {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            if ([string]::IsNullOrWhiteSpace($PreviousSha256)) { return $true }
            try {
                if ((Get-CycLifecycleSha256 -Path $Path) -cne $PreviousSha256) { return $true }
            } catch {
                # Atomic replacement can make the path transiently unreadable;
                # retry until the bounded deadline or process exit below.
            }
        }
        if ($Process -and $Process.HasExited) { return $false }
        Start-Sleep -Milliseconds 200
    } while ([DateTimeOffset]::UtcNow -lt $Deadline)
    return $false
}

function Write-CycLifecycleSignal {
    param([Parameter(Mandatory = $true)][string]$Path)
    [System.IO.File]::WriteAllText($Path, '', (New-Object System.Text.UTF8Encoding($false)))
}

function Start-CycFirewallOnlyElevation {
    param(
        [Parameter(Mandatory = $true)][string]$HelperPath,
        [Parameter(Mandatory = $true)][string]$RequestPath,
        [Parameter(Mandatory = $true)][string]$RequestHash,
        [Parameter(Mandatory = $true)][string]$HelperHash,
        [Parameter(Mandatory = $true)][bool]$RequireHelperAuthenticode,
        [ValidateSet('Rollback', 'Finalize')][string]$RecoveryAction,
        [ValidateSet('prepared', 'firewallApplied', 'coreApplied')][string]$RecoveryJournalPhase,
        [string]$RecoveryJournalPath,
        [string]$ExpectedRecoveryJournalSha256
    )
    foreach ($value in @($HelperPath, $RequestPath, $RequestHash, $HelperHash)) {
        Assert-CycLifecycleSafeString -Value $value -Label 'Firewall elevation argument'
    }
    $isRecovery = -not [string]::IsNullOrWhiteSpace($RecoveryAction)
    if ($isRecovery -ne (-not [string]::IsNullOrWhiteSpace($RecoveryJournalPhase)) -or
        $isRecovery -ne (-not [string]::IsNullOrWhiteSpace($RecoveryJournalPath)) -or
        $isRecovery -ne (-not [string]::IsNullOrWhiteSpace($ExpectedRecoveryJournalSha256))) {
        throw 'Firewall recovery action, phase, journal path, and journal digest must be supplied together.'
    }
    if ($isRecovery) {
        foreach ($value in @($RecoveryJournalPath, $ExpectedRecoveryJournalSha256)) {
            Assert-CycLifecycleSafeString -Value $value -Label 'Firewall recovery elevation argument'
        }
        if ($ExpectedRecoveryJournalSha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw 'Firewall recovery journal digest is invalid.'
        }
    }

    function ConvertTo-CycElevationLiteral {
        param([AllowEmptyString()][string]$Value)
        return "'" + $Value.Replace("'", "''") + "'"
    }
    $helperLiteral = ConvertTo-CycElevationLiteral (Resolve-CycLifecyclePath $HelperPath)
    $requestLiteral = ConvertTo-CycElevationLiteral (Resolve-CycLifecyclePath $RequestPath)
    $requestHashLiteral = ConvertTo-CycElevationLiteral $RequestHash
    $helperHashLiteral = ConvertTo-CycElevationLiteral $HelperHash
    $recoveryActionLiteral = ConvertTo-CycElevationLiteral $(if ($isRecovery) { $RecoveryAction } else { '' })
    $recoveryPhaseLiteral = ConvertTo-CycElevationLiteral $(if ($isRecovery) { $RecoveryJournalPhase } else { '' })
    $recoveryJournalLiteral = ConvertTo-CycElevationLiteral $(if ($isRecovery) { Resolve-CycLifecyclePath $RecoveryJournalPath } else { '' })
    $recoveryJournalHashLiteral = ConvertTo-CycElevationLiteral $(if ($isRecovery) { $ExpectedRecoveryJournalSha256 } else { '' })
    $requireAuthenticodeLiteral = if ($RequireHelperAuthenticode) { '$true' } else { '$false' }

    # Never ask elevated PowerShell to execute a user-writable -File directly.
    # The encoded verifier captures the helper bytes, validates their digest
    # (and, for GA, Authenticode over those same bytes), then executes exactly
    # that captured byte sequence.  This closes both pre-validation execution
    # and helper-path TOCTOU windows.
    $loader = @"
`$ErrorActionPreference = 'Stop'
`$helperPath = $helperLiteral
`$requestPath = $requestLiteral
`$expectedRequestHash = $requestHashLiteral
`$expectedHelperHash = $helperHashLiteral
`$recoveryAction = $recoveryActionLiteral
`$recoveryPhase = $recoveryPhaseLiteral
`$recoveryJournalPath = $recoveryJournalLiteral
`$expectedRecoveryJournalHash = $recoveryJournalHashLiteral
`$requireAuthenticode = $requireAuthenticodeLiteral
function Get-CycCapturedSha256([byte[]]`$Bytes) {
    `$sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString(`$sha.ComputeHash(`$Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { `$sha.Dispose() }
}
function Read-CycCapturedRegularFile([string]`$Path, [long]`$MaximumBytes, [string]`$Label) {
    if (-not (Test-Path -LiteralPath `$Path -PathType Leaf)) { throw "`$Label is missing." }
    `$item = Get-Item -LiteralPath `$Path -Force
    if ((`$item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
        `$item.Length -lt 2 -or `$item.Length -gt `$MaximumBytes) {
        throw "`$Label must be a bounded regular file."
    }
    return ,([System.IO.File]::ReadAllBytes(`$Path))
}
`$helperBytes = Read-CycCapturedRegularFile `$helperPath 1MB 'Firewall helper'
if ((Get-CycCapturedSha256 `$helperBytes) -cne `$expectedHelperHash) { throw 'Firewall helper digest changed before elevation.' }
`$requestBytes = Read-CycCapturedRegularFile `$requestPath 32768 'Firewall request'
if ((Get-CycCapturedSha256 `$requestBytes) -cne `$expectedRequestHash) { throw 'Firewall request digest changed before elevation.' }
if (-not [string]::IsNullOrWhiteSpace(`$recoveryAction)) {
    `$journalBytes = Read-CycCapturedRegularFile `$recoveryJournalPath 65536 'Firewall recovery journal'
    if ((Get-CycCapturedSha256 `$journalBytes) -cne `$expectedRecoveryJournalHash) { throw 'Firewall recovery journal digest changed before elevation.' }
}
if (`$requireAuthenticode) {
    `$signature = Get-AuthenticodeSignature -Content `$helperBytes -SourcePathOrExtension `$helperPath -ErrorAction Stop
    if (`$signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or -not `$signature.SignerCertificate) {
        throw 'GA firewall elevation requires valid Authenticode on the captured narrow helper.'
    }
}
`$utf8 = New-Object System.Text.UTF8Encoding(`$false, `$true)
`$helperText = `$utf8.GetString(`$helperBytes)
`$helperBlock = [ScriptBlock]::Create(`$helperText)
`$invoke = @{
    RequestPath = `$requestPath
    ExpectedRequestSha256 = `$expectedRequestHash
    ExpectedHelperSha256 = `$expectedHelperHash
    VerifiedHelperPath = `$helperPath
}
if (-not [string]::IsNullOrWhiteSpace(`$recoveryAction)) {
    `$invoke.RecoveryAction = `$recoveryAction
    `$invoke.RecoveryJournalPhase = `$recoveryPhase
    `$invoke.RecoveryJournalPath = `$recoveryJournalPath
    `$invoke.ExpectedRecoveryJournalSha256 = `$expectedRecoveryJournalHash
}
& `$helperBlock @invoke
"@
    $encodedLoader = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($loader))
    $systemPowerShell = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-EncodedCommand', $encodedLoader
    )
    # This is the only RunAs call in the complete product lifecycle. The
    # coordinator itself, bootstrap, HKCU work, tasks, files, and Codex state
    # always remain in the initiating user process.
    return Start-Process -FilePath $systemPowerShell -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru
}

function Test-CycLifecycleHelperLockHeld {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = $null
    try {
        $stream = New-Object System.IO.FileStream(
            (Resolve-CycLifecyclePath $Path),
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        return $false
    } catch [System.IO.IOException] {
        return $true
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Start-CycFirewallRecoveryElevationIfNeeded {
    param(
        [Parameter(Mandatory = $true)]$Journal,
        [Parameter(Mandatory = $true)][string]$JournalPath,
        [Parameter(Mandatory = $true)]$Request,
        [Parameter(Mandatory = $true)][ValidateSet('Rollback', 'Finalize')][string]$RecoveryAction,
        [scriptblock]$ElevationStarter
    )
    $exchange = Resolve-CycLifecyclePath ([string]$Journal.exchangeRoot)
    $journalPhase = [string]$Journal.phase
    if ($journalPhase -cnotin @('prepared', 'firewallApplied', 'coreApplied') -or
        ($RecoveryAction -eq 'Finalize') -ne ($journalPhase -eq 'coreApplied')) {
        throw 'Recovered firewall action does not match the persisted lifecycle phase.'
    }
    if (-not (Test-CycFirewallRequestJournalBinding -Request $Request -Journal $Journal)) {
        throw 'Recovered firewall request is not exactly bound to the lifecycle journal.'
    }
    $resolvedJournalPath = Resolve-CycLifecyclePath $JournalPath
    if (-not (Test-Path -LiteralPath $resolvedJournalPath -PathType Leaf)) {
        throw 'Recovered lifecycle journal is missing.'
    }
    $journalItem = Get-Item -LiteralPath $resolvedJournalPath -Force
    if (($journalItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $journalItem.Length -lt 2 -or $journalItem.Length -gt 65536) {
        throw 'Recovered lifecycle journal must be a bounded regular file.'
    }
    $currentJournal = Read-CycLifecycleJson `
        -Path $resolvedJournalPath `
        -MaximumBytes 65536 `
        -Label 'Recovered lifecycle journal'
    if (-not $currentJournal -or
        [string]$currentJournal.transactionId -cne [string]$Journal.transactionId -or
        [string]$currentJournal.requestSha256 -cne [string]$Journal.requestSha256 -or
        [string]$currentJournal.action -cne [string]$Journal.action -or
        [string]$currentJournal.phase -cne [string]$Journal.phase) {
        throw 'Recovered lifecycle journal changed before recovery elevation.'
    }
    # The private data root deliberately excludes an over-the-shoulder admin.
    # Publish a strict, digest-bound recovery evidence copy into the transaction
    # exchange, whose ACL already grants only the initiator, Administrators, and
    # SYSTEM.  The elevated verifier/helper both consume these exact bytes.
    $recoveryJournalPath = Resolve-CycLifecyclePath (Join-Path $exchange 'recovery-journal.json')
    Write-CycLifecycleAtomicJson -Path $recoveryJournalPath -Value $currentJournal
    $journalHash = Get-CycLifecycleSha256 -Path $recoveryJournalPath
    $helperPath = Resolve-CycLifecyclePath (Join-Path $exchange $script:CycFirewallHelperName)
    $requestPath = Resolve-CycLifecyclePath ([string]$Journal.requestPath)
    foreach ($candidate in @(
        [PSCustomObject]@{ path = $helperPath; label = 'Recovered firewall helper'; maximum = 1MB },
        [PSCustomObject]@{ path = $requestPath; label = 'Recovered firewall request'; maximum = 32768 }
    )) {
        if (-not (Test-Path -LiteralPath $candidate.path -PathType Leaf)) {
            throw "$($candidate.label) is missing."
        }
        $item = Get-Item -LiteralPath $candidate.path -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $item.Length -lt 2 -or $item.Length -gt [long]$candidate.maximum) {
            throw "$($candidate.label) must be a bounded regular file."
        }
    }
    if ((Get-CycLifecycleSha256 -Path $helperPath) -cne [string]$Journal.helperSha256) {
        throw 'Recovered firewall helper changed after the transaction was prepared.'
    }
    if ((Get-CycLifecycleSha256 -Path $requestPath) -cne [string]$Journal.requestSha256) {
        throw 'Recovered firewall request changed after the transaction was prepared.'
    }

    $lockPath = Join-Path $exchange 'helper.lock'
    if (Test-CycLifecycleHelperLockHeld -Path $lockPath) {
        return [PSCustomObject]@{ started = $false; process = $null; helperPath = $helperPath }
    }
    $process = if ($ElevationStarter) {
        & $ElevationStarter `
            $helperPath `
            $requestPath `
            ([string]$Journal.requestSha256) `
            ([string]$Journal.helperSha256) `
            ([bool]$Request.helperAuthenticodeRequired) `
            $RecoveryAction `
            $journalPhase `
            $recoveryJournalPath `
            $journalHash
    } else {
        Start-CycFirewallOnlyElevation `
            -HelperPath $helperPath `
            -RequestPath $requestPath `
            -RequestHash ([string]$Journal.requestSha256) `
            -HelperHash ([string]$Journal.helperSha256) `
            -RequireHelperAuthenticode ([bool]$Request.helperAuthenticodeRequired) `
            -RecoveryAction $RecoveryAction `
            -RecoveryJournalPhase $journalPhase `
            -RecoveryJournalPath $recoveryJournalPath `
            -ExpectedRecoveryJournalSha256 $journalHash
    }
    return [PSCustomObject]@{ started = $true; process = $process; helperPath = $helperPath }
}

function Get-CycBootstrapArguments {
    param(
        [Parameter(Mandatory = $true)][string]$BootstrapPath,
        [Parameter(Mandatory = $true)][string]$Operation,
        [Parameter(Mandatory = $true)]$Binding,
        [Parameter(Mandatory = $true)]$Roots,
        [string]$TransactionId,
        [string]$RequestSha256,
        [switch]$Plan
    )
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $BootstrapPath,
        '-Action', $Operation,
        '-InstallRoot', $Roots.installRoot,
        '-DataRoot', $Roots.dataRoot,
        '-DeferFirewall',
        '-InitiatingSid', $Binding.sid,
        '-InitiatingProfile', $Binding.profile,
        '-InitiatingLocalAppData', $Binding.localAppData
    )
    if (-not [string]::IsNullOrWhiteSpace($TransactionId)) {
        $arguments += @('-FirewallTransactionId', $TransactionId)
    }
    if (-not [string]::IsNullOrWhiteSpace($RequestSha256)) {
        $arguments += @('-FirewallRequestSha256', $RequestSha256)
    }
    if ($Plan) { $arguments += '-PlanOnly' }
    if ($Operation -in @('Install', 'Repair')) {
        $arguments += @('-BundleRoot', $BundleRoot)
        if (-not [string]::IsNullOrWhiteSpace($PackageRoot)) {
            $arguments += @('-PackageRoot', $PackageRoot, '-PackageManifest', $PackageManifest)
        }
        if ($RequirePackageSignature) {
            $arguments += @('-RequirePackageSignature', '-PackageExecutable', $PackageExecutable)
        }
    }
    return ,$arguments
}

function Invoke-CycBootstrapProcess {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $systemPowerShell = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
    $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ('.cyc-bootstrap-stderr-' + $PID + '-' + [Guid]::NewGuid().ToString('N') + '.log')
    try {
        # Windows PowerShell 5.1 promotes a native stderr record to a
        # terminating NativeCommandError when the caller uses Stop. Redirect
        # the native stream to an exact private temp file so we can preserve
        # the real exit code and bounded diagnostic without changing argv.
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $stdout = @(& $systemPowerShell @Arguments 2> $stderrPath)
            $exitCode = [int]$LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
            @([System.IO.File]::ReadAllLines($stderrPath))
        } else { @() }
        $output = @($stdout) + @($stderr)
        if ($exitCode -ne 0) {
            $tail = [string]::Join(' | ', @(
                $output |
                    ForEach-Object { ([string]$_).Trim() } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    Select-Object -Last 20
            ))
            if ($tail.Length -gt 16384) { $tail = $tail.Substring($tail.Length - 16384) }
            $detail = if ([string]::IsNullOrWhiteSpace($tail)) { '' } else { " Detail: $tail" }
            throw "ClusterYourCodex core lifecycle failed with exit code $exitCode.$detail"
        }
        return $output
    } finally {
        if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
            try { [System.IO.File]::Delete($stderrPath) } catch { }
        }
    }
}

function Get-CycValidatedInstallPlan {
    param(
        [Parameter(Mandatory = $true)][string]$BootstrapFile,
        [Parameter(Mandatory = $true)][string]$RequestedBundleRoot,
        [Parameter(Mandatory = $true)][string]$RequestedPackageRoot,
        [Parameter(Mandatory = $true)][string]$RequestedPackageManifest,
        [Parameter(Mandatory = $true)][string]$RequestedPackageExecutable,
        [Parameter(Mandatory = $true)][bool]$SignatureRequired,
        [Parameter(Mandatory = $true)]$Binding,
        [Parameter(Mandatory = $true)]$Roots,
        [Parameter(Mandatory = $true)][string]$TransactionId
    )
    # Dot-source inside this function scope only. This gives the coordinator a
    # typed plan while keeping bootstrap's parameter variables out of the
    # coordinator scope. Package hash and optional Authenticode gates run before
    # any elevation is requested.
    . $BootstrapFile
    Assert-CycPackageManifest `
        -Root $RequestedPackageRoot `
        -ManifestPath $RequestedPackageManifest `
        -PayloadRoot $RequestedBundleRoot
    if ($SignatureRequired) {
        Assert-CycPackageSignature -Executable $RequestedPackageExecutable
    }
    return Get-InstallPlan `
        -BundleRoot $RequestedBundleRoot `
        -InstallRoot $Roots.installRoot `
        -DataRoot $Roots.dataRoot `
        -DeferFirewall `
        -InitiatingSid $Binding.sid `
        -InitiatingProfile $Binding.profile `
        -InitiatingLocalAppData $Binding.localAppData `
        -FirewallTransactionId $TransactionId
}

function New-CycFirewallExchange {
    param(
        [Parameter(Mandatory = $true)]$Binding,
        [Parameter(Mandatory = $true)][string]$TransactionId,
        [Parameter(Mandatory = $true)][string]$HelperSource
    )
    $commonDocuments = [Environment]::GetFolderPath('CommonDocuments')
    if ([string]::IsNullOrWhiteSpace($commonDocuments)) { throw 'Public Documents is unavailable.' }
    $base = Join-Path $commonDocuments $script:CycFirewallExchangeDirectory
    if (-not (Test-Path -LiteralPath $base -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $base -Force)
    }
    $sidRoot = Join-Path $base $Binding.sid.Replace('-', '_')
    [void](New-CycPrivateDirectory -Path $sidRoot -InitiatorSid $Binding.sid -IncludeAdministrators)
    $exchange = Join-Path $sidRoot $TransactionId
    [void](New-CycPrivateDirectory -Path $exchange -InitiatorSid $Binding.sid -IncludeAdministrators)
    $helper = Join-Path $exchange $script:CycFirewallHelperName
    Copy-Item -LiteralPath $HelperSource -Destination $helper -Force
    return [PSCustomObject]@{
        root = Resolve-CycLifecyclePath $exchange
        helper = Resolve-CycLifecyclePath $helper
        request = Join-Path $exchange 'request.json'
        response = Join-Path $exchange 'response.json'
    }
}

function New-CycFirewallRequest {
    param(
        [Parameter(Mandatory = $true)]$Binding,
        [Parameter(Mandatory = $true)]$Roots,
        [Parameter(Mandatory = $true)]$Exchange,
        [Parameter(Mandatory = $true)][string]$TransactionId,
        [Parameter(Mandatory = $true)][ValidateSet('Apply', 'Remove')][string]$FirewallAction,
        [Parameter(Mandatory = $true)][string]$ProgramSha256,
        [Parameter(Mandatory = $true)][string]$PackageDigest,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][DateTimeOffset]$Deadline
    )
    $packageExecutableValue = if ([string]::IsNullOrWhiteSpace($PackageExecutable)) {
        Resolve-CycLifecyclePath $PSCommandPath
    } else { Resolve-CycLifecyclePath $PackageExecutable }
    return [ordered]@{
        schemaVersion = $script:CycFirewallRequestSchema
        transactionId = $TransactionId
        requestNonce = ([Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N'))
        action = $FirewallAction
        createdAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        deadlineUtc = $Deadline.ToString('o')
        initiatorSid = $Binding.sid
        initiatorProfile = $Binding.profile
        initiatorLocalAppData = $Binding.localAppData
        installRoot = $Roots.installRoot
        program = Join-Path $Roots.installRoot 'cyc-controller.exe'
        programSha256 = $ProgramSha256
        port = $Port
        ruleName = 'ClusterYourCodex.ManagedWorker.' + $Binding.sid.Replace('-', '_')
        displayName = $script:CycFirewallDisplayName
        group = $script:CycFirewallRuleGroup
        ruleDescription = $script:CycFirewallRuleDescription
        remoteAddress = 'LocalSubnet'
        exchangeRoot = $Exchange.root
        packageManifestSha256 = $PackageDigest
        packageExecutable = $packageExecutableValue
        helperAuthenticodeRequired = [bool]$RequirePackageSignature
    }
}

function Invoke-CycCommitFirewallReceipt {
    param(
        [Parameter(Mandatory = $true)][string]$BootstrapPath,
        [Parameter(Mandatory = $true)]$Binding,
        [Parameter(Mandatory = $true)]$Roots,
        [Parameter(Mandatory = $true)][string]$TransactionId,
        [Parameter(Mandatory = $true)][string]$ReceiptPath
    )
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $BootstrapPath,
        '-Action', 'CommitFirewall',
        '-InstallRoot', $Roots.installRoot,
        '-DataRoot', $Roots.dataRoot,
        '-InitiatingSid', $Binding.sid,
        '-InitiatingProfile', $Binding.profile,
        '-InitiatingLocalAppData', $Binding.localAppData,
        '-FirewallTransactionId', $TransactionId,
        '-FirewallReceiptPath', $ReceiptPath
    )
    [void](Invoke-CycBootstrapProcess -Arguments $arguments)
}

function Invoke-ClusterYourCodexLifecycleCore {
    Set-CycLifecycleDiagnosticStage -Stage 'binding'
    $binding = Get-CycInitiatorBinding
    $roots = Assert-CycDefaultPerUserRoots `
        -Binding $binding `
        -RequestedInstallRoot $InstallRoot `
        -RequestedDataRoot $DataRoot
    $bootstrap = Resolve-CycLifecyclePath (Join-Path $PSScriptRoot $script:CycBootstrapName)
    $helperSource = Resolve-CycLifecyclePath (Join-Path $PSScriptRoot $script:CycFirewallHelperName)
    foreach ($required in @($bootstrap, $helperSource)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Lifecycle package file is missing: $required"
        }
    }
    if ([string]::IsNullOrWhiteSpace($BundleRoot)) { $script:BundleRoot = Join-Path $PSScriptRoot 'payload' }
    if ([string]::IsNullOrWhiteSpace($PackageRoot) -and $Action -in @('Install', 'Repair')) {
        $script:PackageRoot = Resolve-CycLifecyclePath $PSScriptRoot
        $script:PackageManifest = Join-Path $script:PackageRoot 'preview-manifest.json'
    }
    foreach ($path in @($roots.installRoot, $roots.dataRoot, $bootstrap, $helperSource)) {
        Assert-CycLifecycleSafeString -Value $path -Label 'Lifecycle path'
    }

    Set-CycLifecycleDiagnosticStage -Stage 'state-preparing'
    [void](New-CycPrivateDirectory -Path $roots.dataRoot -InitiatorSid $binding.sid)
    $installerState = New-CycPrivateDirectory `
        -Path (Join-Path $roots.dataRoot '.installer') `
        -InitiatorSid $binding.sid
    $journalPath = Join-Path $installerState 'firewall-lifecycle.json'
    $manifestPath = Join-Path $installerState 'install-manifest.json'
    $privateReceiptRoot = New-CycPrivateDirectory `
        -Path (Join-Path $installerState 'firewall-receipts') `
        -InitiatorSid $binding.sid

    $oldJournal = Read-CycLifecycleJson -Path $journalPath -MaximumBytes 65536 -Label 'Firewall lifecycle journal'
    if ($oldJournal) {
        [void](Assert-CycLifecycleJournal `
            -Journal $oldJournal `
            -Binding $binding `
            -Roots $roots `
            -PrivateReceiptRoot $privateReceiptRoot)
        if ($Action -in @('Install', 'Repair') -and
            [string]$oldJournal.packageManifestSha256 -cmatch '^[0-9a-f]{64}$') {
            $script:CycLifecyclePackageManifestSha256 = [string]$oldJournal.packageManifestSha256
        }
    }
    $oldManifest = Read-CycLifecycleJson `
        -Path $manifestPath `
        -MaximumBytes $script:CycMaxInstallManifestBytes `
        -Label 'Install manifest'
    $oldReceipt = $null
    $oldReceiptSha256 = $null
    $oldRequest = $null
    if ($oldJournal) {
        $oldRequest = Read-CycLifecycleJson `
            -Path ([string]$oldJournal.requestPath) `
            -MaximumBytes 32768 `
            -Label 'Recovered firewall request'
        if ($oldRequest) {
            if ((Get-CycLifecycleSha256 -Path ([string]$oldJournal.requestPath)) -cne [string]$oldJournal.requestSha256) {
                throw 'Lifecycle journal request evidence changed.'
            }
        } elseif ([string]$oldJournal.phase -cne 'complete') {
            throw 'Lifecycle journal request evidence is missing.'
        }
    }
    $privateReceiptFailure = $null
    if ($oldJournal -and $oldJournal.PSObject.Properties['privateReceiptPath']) {
        $candidateReceipt = Resolve-CycLifecyclePath ([string]$oldJournal.privateReceiptPath)
        $receiptPrefix = (Resolve-CycLifecyclePath $privateReceiptRoot) + [System.IO.Path]::DirectorySeparatorChar
        if (-not $candidateReceipt.StartsWith($receiptPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Lifecycle journal receipt escaped the private receipt root.'
        }
        try {
            $oldReceipt = Read-CycLifecycleJson -Path $candidateReceipt -MaximumBytes 32768 -Label 'Durable firewall receipt'
        } catch {
            # A crash during an older non-atomic Copy-Item publication may have
            # left this private cache truncated.  Do not trust it, but allow an
            # exact request-bound exchange response to repair it below.
            $privateReceiptFailure = $_
            $oldReceipt = $null
        }
        if ($oldReceipt) {
            if ($oldRequest) {
                [void](Assert-CycFirewallReceipt `
                    -Receipt $oldReceipt `
                    -Request $oldRequest `
                    -RequestHash ([string]$oldJournal.requestSha256))
            }
            $oldReceiptSha256 = Get-CycLifecycleSha256 -Path $candidateReceipt
        }
    }
    if ($oldJournal -and -not $oldReceipt -and
        $oldJournal.PSObject.Properties['exchangeRoot'] -and
        $oldJournal.PSObject.Properties['requestPath'] -and $oldRequest) {
        $exchangeResponse = Join-Path ([string]$oldJournal.exchangeRoot) 'response.json'
        $candidateResponse = Read-CycLifecycleJson `
            -Path $exchangeResponse `
            -MaximumBytes 32768 `
            -Label 'Recovered firewall receipt'
        if ($oldRequest -and $candidateResponse) {
            $recoveredReceiptPath = Resolve-CycLifecyclePath ([string]$oldJournal.privateReceiptPath)
            $publishedReceipt = Publish-CycLifecycleReceiptAtomic `
                -SourcePath $exchangeResponse `
                -DestinationPath $recoveredReceiptPath `
                -Request $oldRequest `
                -RequestHash ([string]$oldJournal.requestSha256)
            $oldReceipt = $publishedReceipt.receipt
            $oldReceiptSha256 = [string]$publishedReceipt.sha256
            $privateReceiptFailure = $null
        }
    }
    if ($privateReceiptFailure -and -not $oldReceipt) {
        throw $privateReceiptFailure
    }
    # The core process may commit and exit in the narrow window before the
    # coordinator records coreApplied.  Reconcile only from an exact durable
    # core after-image bound to the immutable request: a pending install/repair
    # manifest, or manifest absence for uninstall.  Persist the promotion before
    # asking the elevated helper to finalize so recovery phase is no longer a
    # caller-supplied assertion.
    $receiptAllowsCorePromotion = -not $oldReceipt -or
        [string]$oldReceipt.result -ceq 'rollbackFailed'
    if ($oldJournal -and $receiptAllowsCorePromotion -and
        [string]$oldJournal.phase -ceq 'firewallApplied' -and
        [string]$oldJournal.action -ceq $Action) {
        $coreCommitObserved = Test-CycLifecycleCoreCommitAfterImage `
            -Journal $oldJournal `
            -Manifest $oldManifest `
            -Request $oldRequest
        if ($coreCommitObserved) {
            $oldJournal.phase = 'coreApplied'
            $oldJournal.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            Write-CycLifecycleAtomicJson -Path $journalPath -Value $oldJournal
        }
    }
    $resumeDecision = Get-CycFirewallResumeDecision `
        -Journal $oldJournal `
        -Receipt $oldReceipt `
        -Manifest $oldManifest `
        -ReceiptSha256 $oldReceiptSha256 `
        -RequestedAction $Action
    Set-CycLifecycleDiagnosticStage -Stage 'state-evaluated'
    if ($resumeDecision -eq 'Reject') { throw 'Existing firewall lifecycle journal does not belong to this user/action.' }
    $replaceCompletedTransactionId = $null
    $replaceCompletedRequestSha256 = $null
    $replaceCompletedAction = $null
    $rolledBackUninstallRetry = $null
    if ($resumeDecision -eq 'RetireThenStart') {
        $replaceCompletedTransactionId = [string]$oldJournal.transactionId
        $replaceCompletedRequestSha256 = [string]$oldJournal.requestSha256
        $replaceCompletedAction = [string]$oldJournal.action
    }
    if ($resumeDecision -eq 'Commit') {
        Set-CycLifecycleDiagnosticStage -Stage 'resume-commit'
        $oldBinding = [PSCustomObject]@{
            sid = [string]$oldJournal.initiatorSid
            profile = [string]$oldJournal.initiatorProfile
            localAppData = [string]$oldJournal.initiatorLocalAppData
        }
        [void](Assert-CycInitiatorStillCurrent -Binding $oldBinding)
        Invoke-CycCommitFirewallReceipt `
            -BootstrapPath (Join-Path $roots.installRoot 'installer\bootstrap.ps1') `
            -Binding $oldBinding `
            -Roots $roots `
            -TransactionId ([string]$oldJournal.transactionId) `
            -ReceiptPath ([string]$oldJournal.privateReceiptPath)
        $oldManifest = Read-CycLifecycleJson `
            -Path $manifestPath `
            -MaximumBytes $script:CycMaxInstallManifestBytes `
            -Label 'Install manifest'
        if (-not (Test-CycAppliedFirewallManifestBinding `
                -Manifest $oldManifest `
                -Journal $oldJournal `
                -Receipt $oldReceipt `
                -ReceiptSha256 $oldReceiptSha256)) {
            throw 'Committed firewall receipt did not produce the expected applied manifest state.'
        }
        # Publish the terminal lifecycle phase only after the committed
        # manifest has been re-read and exactly validated.  A lock/torn-read
        # failure remains resumable at Commit instead of becoming a bad
        # terminal tombstone.
        $oldJournal.phase = 'complete'
        $oldJournal.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Write-CycLifecycleAtomicJson -Path $journalPath -Value $oldJournal
        [void](Remove-CycCompletedLifecycleJournal `
            -Path $journalPath `
            -TransactionId ([string]$oldJournal.transactionId) `
            -ExpectedAction ([string]$oldJournal.action) `
            -ExpectedRequestSha256 ([string]$oldJournal.requestSha256) `
            -BestEffort)
        Set-CycLifecycleDiagnosticStage -Stage 'complete'
        return [PSCustomObject]@{ action = $Action; status = 'unchanged'; resumed = $true; firewallVerified = $true }
    }
    if ($resumeDecision -eq 'Complete') {
        $oldJournal.phase = 'complete'
        $oldJournal.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Write-CycLifecycleAtomicJson -Path $journalPath -Value $oldJournal
        [void](Remove-CycCompletedLifecycleJournal `
            -Path $journalPath `
            -TransactionId ([string]$oldJournal.transactionId) `
            -ExpectedAction ([string]$oldJournal.action) `
            -ExpectedRequestSha256 ([string]$oldJournal.requestSha256) `
            -BestEffort)
        Set-CycLifecycleDiagnosticStage -Stage 'complete'
        return [PSCustomObject]@{ action = $Action; status = 'unchanged'; resumed = $true; firewallVerified = $true }
    }
    if ($resumeDecision -eq 'RetireAbortedThenStart') {
        $rolledBackUninstallRetry = Get-CycRolledBackUninstallRetryEvidence `
            -Journal $oldJournal `
            -Receipt $oldReceipt `
            -Manifest $oldManifest `
            -Request $oldRequest `
            -RequestedAction $Action
        $oldJournal.phase = 'complete'
        $oldJournal.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Write-CycLifecycleAtomicJson -Path $journalPath -Value $oldJournal
        if ($rolledBackUninstallRetry) {
            # Keep the completed tombstone until the successor Remove journal
            # atomically replaces it. A crash anywhere before that CAS must
            # retain enough immutable evidence to retry orphan cleanup.
            $replaceCompletedTransactionId = [string]$oldJournal.transactionId
            $replaceCompletedRequestSha256 = [string]$oldJournal.requestSha256
            $replaceCompletedAction = [string]$oldJournal.action
        } else {
            [void](Remove-CycCompletedLifecycleJournal `
                -Path $journalPath `
                -TransactionId ([string]$oldJournal.transactionId) `
                -ExpectedAction ([string]$oldJournal.action) `
                -ExpectedRequestSha256 ([string]$oldJournal.requestSha256))
        }
        $oldJournal = $null
        $oldReceipt = $null
        $oldReceiptSha256 = $null
    }
    if ($oldJournal -and $resumeDecision -in @('Restart', 'Resume') -and
        $oldJournal.PSObject.Properties['exchangeRoot']) {
        $oldExchange = Resolve-CycLifecyclePath ([string]$oldJournal.exchangeRoot)
        if (-not (Test-Path -LiteralPath $oldExchange -PathType Container)) {
            throw 'Incomplete firewall lifecycle exchange is missing; recovery cannot continue.'
        }
        $recoverCoreApplied = [string]$oldJournal.phase -ceq 'coreApplied'
        $recoveryAction = if ($recoverCoreApplied) { 'Finalize' } else { 'Rollback' }
        $recoverySignal = if ($recoverCoreApplied) { 'finalize.signal' } else { 'rollback.signal' }
        $expectedRecoveryResult = if ($recoverCoreApplied) { 'verified' } else { 'rolledBack' }
        $oldResponsePath = Join-Path $oldExchange 'response.json'
        $previousRecoveryResponseSha256 = $null
        if ($oldReceipt -and
            [string]$oldReceipt.result -ceq 'rollbackFailed' -and
            (Test-Path -LiteralPath $oldResponsePath -PathType Leaf)) {
            $exchangeResponseSha256BeforeRead = Get-CycLifecycleSha256 -Path $oldResponsePath
            $currentExchangeResponse = Read-CycLifecycleJson `
                -Path $oldResponsePath `
                -MaximumBytes 32768 `
                -Label 'Pre-recovery firewall receipt'
            $exchangeResponseSha256AfterRead = Get-CycLifecycleSha256 -Path $oldResponsePath
            [void](Assert-CycFirewallReceipt `
                -Receipt $currentExchangeResponse `
                -Request $oldRequest `
                -RequestHash ([string]$oldJournal.requestSha256))
            # A response already matching this recovery action is consumed as
            # is. A stable older failure response must be atomically replaced
            # before the coordinator accepts the filename again.
            $previousRecoveryResponseSha256 = Get-CycLifecycleResponseReplacementWaitDigest `
                -Receipt $currentExchangeResponse `
                -Sha256BeforeRead $exchangeResponseSha256BeforeRead `
                -Sha256AfterRead $exchangeResponseSha256AfterRead `
                -ExpectedResult $expectedRecoveryResult
        }
        Write-CycLifecycleSignal -Path (Join-Path $oldExchange $recoverySignal)
        Set-CycLifecycleDiagnosticStage -Stage 'recovery-helper-evaluating'
        $recoveryLaunch = Start-CycFirewallRecoveryElevationIfNeeded `
            -Journal $oldJournal `
            -JournalPath $journalPath `
            -Request $oldRequest `
            -RecoveryAction $recoveryAction
        if ([bool]$recoveryLaunch.started) {
            Set-CycLifecycleDiagnosticStage -Stage 'recovery-helper-started'
        } else {
            Set-CycLifecycleDiagnosticStage -Stage 'recovery-helper-active'
        }
        $oldDeadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
        if (-not (Wait-CycLifecycleFile `
                -Path $oldResponsePath `
                -Deadline $oldDeadline `
                -PreviousSha256 $previousRecoveryResponseSha256)) {
            throw 'Incomplete firewall lifecycle did not publish a bounded recovery receipt.'
        }
        $recoveryReceipt = Read-CycLifecycleJson `
            -Path $oldResponsePath `
            -MaximumBytes 32768 `
            -Label 'Recovered firewall receipt'
        [void](Assert-CycFirewallReceipt `
            -Receipt $recoveryReceipt `
            -Request $oldRequest `
            -RequestHash ([string]$oldJournal.requestSha256))
        if ([string]$recoveryReceipt.result -cne $expectedRecoveryResult) {
            throw "Incomplete firewall lifecycle recovery returned $([string]$recoveryReceipt.result) instead of $expectedRecoveryResult."
        }
        if ([bool]$recoveryLaunch.started) {
            if (-not $recoveryLaunch.process -or -not $recoveryLaunch.process.WaitForExit(30000)) {
                throw 'Recovered firewall helper did not exit in bounded time.'
            }
            # The original helper may win the narrow lock-probe -> RunAs race.
            # In that case the recovery process exits on lock contention while
            # the original process publishes the exact request-bound receipt.
            # The validated durable receipt above is the transaction authority.
        }
        $recoveredReceiptPath = Resolve-CycLifecyclePath ([string]$oldJournal.privateReceiptPath)
        $publishedRecoveryReceipt = Publish-CycLifecycleReceiptAtomic `
            -SourcePath $oldResponsePath `
            -DestinationPath $recoveredReceiptPath `
            -Request $oldRequest `
            -RequestHash ([string]$oldJournal.requestSha256)
        $recoveryReceipt = $publishedRecoveryReceipt.receipt
        $recoveredReceiptSha256 = [string]$publishedRecoveryReceipt.sha256
        if ($recoverCoreApplied) {
            if ([string]$oldJournal.action -cin @('Install', 'Repair')) {
                Invoke-CycCommitFirewallReceipt `
                    -BootstrapPath (Join-Path $roots.installRoot 'installer\bootstrap.ps1') `
                    -Binding $binding `
                    -Roots $roots `
                    -TransactionId ([string]$oldJournal.transactionId) `
                    -ReceiptPath $recoveredReceiptPath
                $oldManifest = Read-CycLifecycleJson `
                    -Path $manifestPath `
                    -MaximumBytes $script:CycMaxInstallManifestBytes `
                    -Label 'Install manifest'
                if (-not (Test-CycAppliedFirewallManifestBinding `
                        -Manifest $oldManifest `
                        -Journal $oldJournal `
                        -Receipt $recoveryReceipt `
                        -ReceiptSha256 $recoveredReceiptSha256)) {
                    throw 'Recovered firewall commit did not produce the expected applied manifest state.'
                }
            } elseif ($oldManifest) {
                throw 'Recovered Uninstall completed its firewall mutation while the install manifest still exists.'
            }
            $oldJournal.phase = 'complete'
            $oldJournal.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            Write-CycLifecycleAtomicJson -Path $journalPath -Value $oldJournal
            [void](Remove-CycCompletedLifecycleJournal `
                -Path $journalPath `
                -TransactionId ([string]$oldJournal.transactionId) `
                -ExpectedAction ([string]$oldJournal.action) `
                -ExpectedRequestSha256 ([string]$oldJournal.requestSha256) `
                -BestEffort)
            Set-CycLifecycleDiagnosticStage -Stage 'complete'
            return [PSCustomObject]@{ action = $Action; status = 'unchanged'; resumed = $true; firewallVerified = $true }
        }
        # A pre-core rollback is normally terminal.  Uninstall is the one
        # exception: core may already have removed the install manifest while
        # the helper restored a snapshot that still contains the managed rule.
        # Derive the retry only from the exact request-bound receipt that was
        # atomically published above, then retain the completed predecessor as
        # a tombstone until a successor Remove journal replaces it by CAS.
        # Crashes before that replacement therefore keep the full immutable
        # request + receipt evidence needed to retry orphan cleanup.
        $preCoreRecoveryCompletion = Complete-CycPreCoreFirewallRecovery `
            -Journal $oldJournal `
            -Receipt $recoveryReceipt `
            -Manifest $oldManifest `
            -Request $oldRequest `
            -RequestedAction $Action `
            -JournalPath $journalPath
        $rolledBackUninstallRetry = $preCoreRecoveryCompletion.retryEvidence
        $replaceCompletedTransactionId = $preCoreRecoveryCompletion.replaceCompletedTransactionId
        $replaceCompletedRequestSha256 = $preCoreRecoveryCompletion.replaceCompletedRequestSha256
        $replaceCompletedAction = $preCoreRecoveryCompletion.replaceCompletedAction
        $oldJournal = $null
        $oldReceipt = $null
        $oldReceiptSha256 = $null
    }

    $transactionId = [Guid]::NewGuid().ToString('N')
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($FirewallTimeoutSeconds)
    $plan = $null
    $programSha = $null
    $port = 47832
    $packageDigest = ('0' * 64)
    if ($Action -in @('Install', 'Repair')) {
        Set-CycLifecycleDiagnosticStage -Stage 'plan-validating'
        if (-not (Test-Path -LiteralPath $BundleRoot -PathType Container)) { throw 'BundleRoot is missing.' }
        if (-not (Test-Path -LiteralPath $PackageManifest -PathType Leaf)) { throw 'Package manifest is missing.' }
        $packageDigest = Get-CycLifecycleSha256 -Path $PackageManifest
        $script:CycLifecyclePackageManifestSha256 = $packageDigest
        $plan = Get-CycValidatedInstallPlan `
            -BootstrapFile $bootstrap `
            -RequestedBundleRoot $BundleRoot `
            -RequestedPackageRoot $PackageRoot `
            -RequestedPackageManifest $PackageManifest `
            -RequestedPackageExecutable $(if ([string]::IsNullOrWhiteSpace($PackageExecutable)) { $PSCommandPath } else { $PackageExecutable }) `
            -SignatureRequired ([bool]$RequirePackageSignature) `
            -Binding $binding `
            -Roots $roots `
            -TransactionId $transactionId
        if (-not $plan) { throw 'Core planner returned no install plan.' }
        $controllerRecord = @($plan.files | Where-Object { [string]$_.relativePath -ceq 'cyc-controller.exe' })
        if ($controllerRecord.Count -ne 1) { throw 'Install plan has no unique controller executable.' }
        $programSha = [string]$controllerRecord[0].sha256
        $port = [int]$plan.managedWorker.listenPort
        Set-CycLifecycleDiagnosticStage -Stage 'plan-validated'
    } else {
        if (-not $oldManifest) {
            if ($rolledBackUninstallRetry) {
                # The previous Remove transaction restored its snapshot after
                # core Uninstall had already removed the manifest. Re-issue an
                # independently journaled Remove from the immutable old request
                # evidence instead of declaring an orphaned rule "unchanged".
                $programSha = [string]$rolledBackUninstallRetry.programSha256
                $port = [int]$rolledBackUninstallRetry.port
                $packageDigest = [string]$rolledBackUninstallRetry.packageManifestSha256
                Set-CycLifecycleDiagnosticStage -Stage 'uninstall-firewall-retry'
            } else {
                if (-not [string]::IsNullOrWhiteSpace($replaceCompletedTransactionId)) {
                    [void](Remove-CycCompletedLifecycleJournal `
                        -Path $journalPath `
                        -TransactionId $replaceCompletedTransactionId `
                        -ExpectedAction $replaceCompletedAction `
                        -ExpectedRequestSha256 $replaceCompletedRequestSha256 `
                        -BestEffort)
                }
                Set-CycLifecycleDiagnosticStage -Stage 'complete'
                return [PSCustomObject]@{ action = 'Uninstall'; status = 'unchanged'; resumed = $false; firewallVerified = $true }
            }
        } elseif ($oldManifest.PSObject.Properties['initiator']) {
            [void](Assert-CycInitiatorStillCurrent -Binding ([PSCustomObject]@{
                sid = [string]$oldManifest.initiator.sid
                profile = [string]$oldManifest.initiator.profile
                localAppData = [string]$oldManifest.initiator.localAppData
            }))
        }
        if ($oldManifest) {
            $controllerRecord = @($oldManifest.files | Where-Object { [string]$_.relativePath -ceq 'cyc-controller.exe' })
            if ($controllerRecord.Count -ne 1) { throw 'Installed manifest has no unique controller executable.' }
            $programSha = [string]$controllerRecord[0].sha256
            $port = [int]$oldManifest.managedWorker.listenPort
            $packageDigest = Get-CycLifecycleSha256 -Path $manifestPath
        }
    }

    Set-CycLifecycleDiagnosticStage -Stage 'exchange-preparing'
    $exchange = New-CycFirewallExchange `
        -Binding $binding `
        -TransactionId $transactionId `
        -HelperSource $helperSource
    $request = New-CycFirewallRequest `
        -Binding $binding `
        -Roots $roots `
        -Exchange $exchange `
        -TransactionId $transactionId `
        -FirewallAction $(if ($Action -eq 'Uninstall') { 'Remove' } else { 'Apply' }) `
        -ProgramSha256 $programSha `
        -PackageDigest $packageDigest `
        -Port $port `
        -Deadline $deadline
    Write-CycLifecycleAtomicJson -Path $exchange.request -Value $request
    $requestHash = Get-CycLifecycleSha256 -Path $exchange.request
    $helperHash = Get-CycLifecycleSha256 -Path $exchange.helper
    $privateReceiptPath = Join-Path $privateReceiptRoot ($transactionId + '.json')
    $journal = [ordered]@{
        schemaVersion = $script:CycLifecycleJournalSchema
        transactionId = $transactionId
        action = $Action
        phase = 'prepared'
        initiatorSid = $binding.sid
        initiatorProfile = $binding.profile
        initiatorLocalAppData = $binding.localAppData
        installRoot = $roots.installRoot
        dataRoot = $roots.dataRoot
        exchangeRoot = $exchange.root
        requestPath = $exchange.request
        requestSha256 = $requestHash
        helperSha256 = $helperHash
        privateReceiptPath = $privateReceiptPath
        packageManifestSha256 = $packageDigest
        updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    Write-CycLifecycleActiveJournal `
        -Path $journalPath `
        -Value $journal `
        -ExpectedCompletedTransactionId $replaceCompletedTransactionId `
        -ExpectedCompletedRequestSha256 $replaceCompletedRequestSha256 `
        -ExpectedCompletedAction $replaceCompletedAction
    Set-CycLifecycleDiagnosticStage -Stage 'exchange-prepared'

    $helperProcess = $null
    $coreSucceeded = $false
    try {
        Set-CycLifecycleDiagnosticStage -Stage 'elevation-starting'
        $helperProcess = Start-CycFirewallOnlyElevation `
            -HelperPath $exchange.helper `
            -RequestPath $exchange.request `
            -RequestHash $requestHash `
            -HelperHash $helperHash `
            -RequireHelperAuthenticode ([bool]$request.helperAuthenticodeRequired)
        Set-CycLifecycleDiagnosticStage -Stage 'elevation-started'
        if (-not (Wait-CycLifecycleFile -Path (Join-Path $exchange.root 'ready.signal') -Deadline $deadline -Process $helperProcess)) {
            throw 'Elevated firewall helper did not reach the prepared state.'
        }
        Set-CycLifecycleDiagnosticStage -Stage 'helper-ready'
        Write-CycLifecycleSignal -Path (Join-Path $exchange.root 'apply.signal')
        if (-not (Wait-CycLifecycleFile -Path (Join-Path $exchange.root 'applied.signal') -Deadline $deadline -Process $helperProcess)) {
            throw 'Elevated firewall helper did not apply and verify its bounded mutation.'
        }
        $journal.phase = 'firewallApplied'
        $journal.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Write-CycLifecycleAtomicJson -Path $journalPath -Value $journal
        Set-CycLifecycleDiagnosticStage -Stage 'firewall-applied'

        [void](Assert-CycInitiatorStillCurrent -Binding $binding)
        $coreArgs = Get-CycBootstrapArguments `
            -BootstrapPath $bootstrap `
            -Operation $Action `
            -Binding $binding `
            -Roots $roots `
            -TransactionId $transactionId `
            -RequestSha256 $requestHash
        Set-CycLifecycleDiagnosticStage -Stage 'core-applying'
        [void](Invoke-CycBootstrapProcess -Arguments $coreArgs)
        $coreManifest = Read-CycLifecycleJson `
            -Path $manifestPath `
            -MaximumBytes $script:CycMaxInstallManifestBytes `
            -Label 'Install manifest'
        $coreAfterImageValid = Test-CycLifecycleCoreCommitAfterImage `
            -Journal $journal `
            -Manifest $coreManifest `
            -Request $request
        if (-not $coreAfterImageValid) {
            throw 'Core lifecycle did not publish the exact request-bound durable after-image.'
        }
        $coreSucceeded = $true
        Set-CycLifecycleDiagnosticStage -Stage 'core-applied'
        $journal.phase = 'coreApplied'
        $journal.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Write-CycLifecycleAtomicJson -Path $journalPath -Value $journal
        Write-CycLifecycleSignal -Path (Join-Path $exchange.root 'finalize.signal')
    } catch {
        $failure = $_
        try { Write-CycLifecycleSignal -Path (Join-Path $exchange.root 'rollback.signal') } catch { }
        if ($helperProcess) {
            try { [void]$helperProcess.WaitForExit(30000) } catch { }
        }
        throw $failure
    }

    if (-not (Wait-CycLifecycleFile -Path $exchange.response -Deadline $deadline -Process $helperProcess)) {
        throw 'Firewall helper did not publish its durable final verification receipt.'
    }
    $receipt = Read-CycLifecycleJson -Path $exchange.response -MaximumBytes 32768 -Label 'Firewall receipt'
    [void](Assert-CycFirewallReceipt -Receipt $receipt -Request $request -RequestHash $requestHash)
    if ([string]$receipt.result -cne 'verified') {
        throw 'Firewall mutation was not durably verified; lifecycle remains retryable.'
    }
    if (-not $helperProcess.WaitForExit(30000)) {
        throw 'Firewall helper published a receipt but did not exit in bounded time.'
    }
    if ($helperProcess.ExitCode -ne 0) {
        throw "Firewall helper exited with code $($helperProcess.ExitCode) after publishing its receipt."
    }
    Set-CycLifecycleDiagnosticStage -Stage 'receipt-verified'
    $publishedReceipt = Publish-CycLifecycleReceiptAtomic `
        -SourcePath $exchange.response `
        -DestinationPath $privateReceiptPath `
        -Request $request `
        -RequestHash $requestHash
    $receipt = $publishedReceipt.receipt
    $privateReceiptSha256 = [string]$publishedReceipt.sha256
    if ($Action -in @('Install', 'Repair')) {
        Invoke-CycCommitFirewallReceipt `
            -BootstrapPath (Join-Path $roots.installRoot 'installer\bootstrap.ps1') `
            -Binding $binding `
            -Roots $roots `
            -TransactionId $transactionId `
            -ReceiptPath $privateReceiptPath
        $committedManifest = Read-CycLifecycleJson `
            -Path $manifestPath `
            -MaximumBytes $script:CycMaxInstallManifestBytes `
            -Label 'Install manifest'
        if (-not (Test-CycAppliedFirewallManifestBinding `
                -Manifest $committedManifest `
                -Journal $journal `
                -Receipt $receipt `
                -ReceiptSha256 $privateReceiptSha256)) {
            throw 'Firewall commit did not produce the expected applied manifest state.'
        }
    } elseif (Test-Path -LiteralPath $manifestPath) {
        throw 'Uninstall completed its firewall mutation while the install manifest still exists.'
    }
    $journal.phase = 'complete'
    $journal.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    Write-CycLifecycleAtomicJson -Path $journalPath -Value $journal
    [void](Remove-CycCompletedLifecycleJournal `
        -Path $journalPath `
        -TransactionId $transactionId `
        -ExpectedAction $Action `
        -ExpectedRequestSha256 $requestHash `
        -BestEffort)
    Set-CycLifecycleDiagnosticStage -Stage 'complete'

    if ($Action -eq 'Install' -and -not $NoLaunch) {
        $gui = Join-Path $roots.installRoot 'ClusterYourCodex.exe'
        if (Test-Path -LiteralPath $gui -PathType Leaf) {
            Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList ('"' + $gui + '"') | Out-Null
        }
    }
    return [PSCustomObject]@{
        action = $Action
        status = if ($Action -eq 'Repair') { 'repaired' } elseif ($Action -eq 'Uninstall') { 'removed' } else { 'installed' }
        resumed = $false
        firewallVerified = $true
        coreSucceeded = $coreSucceeded
    }
}

function Invoke-ClusterYourCodexLifecycle {
    $binding = Get-CycInitiatorBinding
    $mutex = Enter-CycLifecycleMutex -Sid ([string]$binding.sid)
    try {
        return Invoke-ClusterYourCodexLifecycleCore
    } finally {
        Exit-CycLifecycleMutex -Mutex $mutex
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $result = Invoke-ClusterYourCodexLifecycle
        Write-CycLifecycleDiagnostic -Status succeeded -Result $result -Failure $null
        if (-not $Quiet) { $result }
        exit 0
    } catch {
        $failure = $_
        Write-CycLifecycleDiagnostic -Status failed -Result $null -Failure $failure
        [Console]::Error.WriteLine(([string]$failure.Exception.Message).Replace("`r", ' ').Replace("`n", ' '))
        exit 1
    }
}
