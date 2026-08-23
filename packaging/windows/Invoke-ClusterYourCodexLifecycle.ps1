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
$script:CycFirewallRuleGroup = 'ClusterYourCodex'
$script:CycFirewallRuleDescription = 'ClusterYourCodex owned managed-worker TLS listener'
$script:CycFirewallDisplayName = 'ClusterYourCodex Managed Worker'
$script:CycFirewallExchangeDirectory = 'ClusterYourCodex-Firewall'
$script:CycBootstrapName = 'bootstrap.ps1'
$script:CycFirewallHelperName = 'Invoke-ClusterYourCodexFirewall.ps1'

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

function Assert-CycLifecycleExactProperties {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Label
    )
    [string[]]$actual = @($Object.PSObject.Properties.Name)
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
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $bytes = $utf8.GetBytes(($Value | ConvertTo-Json -Depth $Depth -Compress) + "`n")
    $stream = $null
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
        Move-Item -LiteralPath $temporary -Destination $resolved -Force
    } finally {
        if ($stream) { $stream.Dispose() }
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
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

function Get-CycFirewallResumeDecision {
    param(
        $Journal,
        $Receipt,
        $Manifest,
        [Parameter(Mandatory = $true)][string]$RequestedAction
    )
    if (-not $Journal) { return 'Start' }
    if ([string]$Journal.schemaVersion -cne $script:CycLifecycleJournalSchema -or
        [string]$Journal.action -cne $RequestedAction) {
        return 'Reject'
    }
    if ($Receipt) {
        if ([string]$Receipt.transactionId -cne [string]$Journal.transactionId -or
            [string]$Receipt.requestSha256 -cne [string]$Journal.requestSha256) {
            return 'Reject'
        }
        if ([string]$Receipt.result -ceq 'verified') {
            if ($RequestedAction -eq 'Uninstall') { return 'Complete' }
            if ($Manifest -and $Manifest.PSObject.Properties['managedWorker'] -and
                $Manifest.managedWorker.PSObject.Properties['firewall'] -and
                [string]$Manifest.managedWorker.firewall.transactionId -ceq [string]$Journal.transactionId -and
                [string]$Manifest.managedWorker.firewall.state -ceq 'applied') {
                return 'Complete'
            }
            return 'Commit'
        }
        if ([string]$Receipt.result -cin @('rolledBack', 'rollbackFailed')) { return 'Restart' }
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
        [string]$Receipt.result -cnotin @('verified', 'rolledBack', 'rollbackFailed')) {
        throw 'Firewall receipt is not bound to the exact approved request.'
    }
    return $Receipt
}

function Wait-CycLifecycleFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][DateTimeOffset]$Deadline,
        [System.Diagnostics.Process]$Process
    )
    do {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return $true }
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
        [Parameter(Mandatory = $true)][string]$HelperHash
    )
    foreach ($value in @($HelperPath, $RequestPath, $RequestHash, $HelperHash)) {
        Assert-CycLifecycleSafeString -Value $value -Label 'Firewall elevation argument'
    }
    $systemPowerShell = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
        $HelperPath + '" -RequestPath "' + $RequestPath +
        '" -ExpectedRequestSha256 ' + $RequestHash +
        ' -ExpectedHelperSha256 ' + $HelperHash
    # This is the only RunAs call in the complete product lifecycle. The
    # coordinator itself, bootstrap, HKCU work, tasks, files, and Codex state
    # always remain in the initiating user process.
    return Start-Process -FilePath $systemPowerShell -ArgumentList $arguments -Verb RunAs -PassThru
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
    $output = @(& $systemPowerShell @Arguments)
    if ($LASTEXITCODE -ne 0) { throw "ClusterYourCodex core lifecycle failed with exit code $LASTEXITCODE." }
    return $output
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

function Invoke-ClusterYourCodexLifecycle {
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
    $oldManifest = Read-CycLifecycleJson -Path $manifestPath -MaximumBytes 2MB -Label 'Install manifest'
    $oldReceipt = $null
    if ($oldJournal -and $oldJournal.PSObject.Properties['privateReceiptPath']) {
        $candidateReceipt = Resolve-CycLifecyclePath ([string]$oldJournal.privateReceiptPath)
        $receiptPrefix = (Resolve-CycLifecyclePath $privateReceiptRoot) + [System.IO.Path]::DirectorySeparatorChar
        if (-not $candidateReceipt.StartsWith($receiptPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Lifecycle journal receipt escaped the private receipt root.'
        }
        $oldReceipt = Read-CycLifecycleJson -Path $candidateReceipt -MaximumBytes 32768 -Label 'Durable firewall receipt'
    }
    if ($oldJournal -and -not $oldReceipt -and
        $oldJournal.PSObject.Properties['exchangeRoot'] -and
        $oldJournal.PSObject.Properties['requestPath']) {
        $exchangeResponse = Join-Path ([string]$oldJournal.exchangeRoot) 'response.json'
        $exchangeRequest = Read-CycLifecycleJson `
            -Path ([string]$oldJournal.requestPath) `
            -MaximumBytes 32768 `
            -Label 'Recovered firewall request'
        $candidateResponse = Read-CycLifecycleJson `
            -Path $exchangeResponse `
            -MaximumBytes 32768 `
            -Label 'Recovered firewall receipt'
        if ($exchangeRequest -and $candidateResponse) {
            [void](Assert-CycFirewallReceipt `
                -Receipt $candidateResponse `
                -Request $exchangeRequest `
                -RequestHash ([string]$oldJournal.requestSha256))
            $recoveredReceiptPath = Resolve-CycLifecyclePath ([string]$oldJournal.privateReceiptPath)
            Copy-Item -LiteralPath $exchangeResponse -Destination $recoveredReceiptPath -Force
            $oldReceipt = Read-CycLifecycleJson `
                -Path $recoveredReceiptPath `
                -MaximumBytes 32768 `
                -Label 'Recovered durable firewall receipt'
        }
    }
    $resumeDecision = Get-CycFirewallResumeDecision `
        -Journal $oldJournal `
        -Receipt $oldReceipt `
        -Manifest $oldManifest `
        -RequestedAction $Action
    if ($resumeDecision -eq 'Reject') { throw 'Existing firewall lifecycle journal does not belong to this user/action.' }
    if ($resumeDecision -eq 'Commit') {
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
        $oldJournal.phase = 'complete'
        $oldJournal.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Write-CycLifecycleAtomicJson -Path $journalPath -Value $oldJournal
        return [PSCustomObject]@{ action = $Action; status = 'unchanged'; resumed = $true; firewallVerified = $true }
    }
    if ($resumeDecision -eq 'Complete') {
        [void](Assert-CycInitiatorStillCurrent -Binding ([PSCustomObject]@{
            sid = [string]$oldJournal.initiatorSid
            profile = [string]$oldJournal.initiatorProfile
            localAppData = [string]$oldJournal.initiatorLocalAppData
        }))
        return [PSCustomObject]@{ action = $Action; status = 'unchanged'; resumed = $true; firewallVerified = $true }
    }
    if ($oldJournal -and $resumeDecision -in @('Restart', 'Resume') -and
        $oldJournal.PSObject.Properties['exchangeRoot']) {
        $oldExchange = Resolve-CycLifecyclePath ([string]$oldJournal.exchangeRoot)
        if (Test-Path -LiteralPath $oldExchange -PathType Container) {
            try {
                Write-CycLifecycleSignal -Path (Join-Path $oldExchange 'rollback.signal')
                $oldDeadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
                [void](Wait-CycLifecycleFile `
                    -Path (Join-Path $oldExchange 'response.json') `
                    -Deadline $oldDeadline)
            } catch { }
        }
    }

    $transactionId = [Guid]::NewGuid().ToString('N')
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($FirewallTimeoutSeconds)
    $plan = $null
    $programSha = $null
    $port = 47832
    $packageDigest = ('0' * 64)
    if ($Action -in @('Install', 'Repair')) {
        if (-not (Test-Path -LiteralPath $BundleRoot -PathType Container)) { throw 'BundleRoot is missing.' }
        if (-not (Test-Path -LiteralPath $PackageManifest -PathType Leaf)) { throw 'Package manifest is missing.' }
        $packageDigest = Get-CycLifecycleSha256 -Path $PackageManifest
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
    } else {
        if (-not $oldManifest) {
            return [PSCustomObject]@{ action = 'Uninstall'; status = 'unchanged'; resumed = $false; firewallVerified = $true }
        }
        if ($oldManifest.PSObject.Properties['initiator']) {
            [void](Assert-CycInitiatorStillCurrent -Binding ([PSCustomObject]@{
                sid = [string]$oldManifest.initiator.sid
                profile = [string]$oldManifest.initiator.profile
                localAppData = [string]$oldManifest.initiator.localAppData
            }))
        }
        $controllerRecord = @($oldManifest.files | Where-Object { [string]$_.relativePath -ceq 'cyc-controller.exe' })
        if ($controllerRecord.Count -ne 1) { throw 'Installed manifest has no unique controller executable.' }
        $programSha = [string]$controllerRecord[0].sha256
        $port = [int]$oldManifest.managedWorker.listenPort
        $packageDigest = Get-CycLifecycleSha256 -Path $manifestPath
    }

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
    Write-CycLifecycleAtomicJson -Path $journalPath -Value $journal

    $helperProcess = $null
    $coreSucceeded = $false
    try {
        $helperProcess = Start-CycFirewallOnlyElevation `
            -HelperPath $exchange.helper `
            -RequestPath $exchange.request `
            -RequestHash $requestHash `
            -HelperHash $helperHash
        if (-not (Wait-CycLifecycleFile -Path (Join-Path $exchange.root 'ready.signal') -Deadline $deadline -Process $helperProcess)) {
            throw 'Elevated firewall helper did not reach the prepared state.'
        }
        Write-CycLifecycleSignal -Path (Join-Path $exchange.root 'apply.signal')
        if (-not (Wait-CycLifecycleFile -Path (Join-Path $exchange.root 'applied.signal') -Deadline $deadline -Process $helperProcess)) {
            throw 'Elevated firewall helper did not apply and verify its bounded mutation.'
        }
        $journal.phase = 'firewallApplied'
        $journal.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Write-CycLifecycleAtomicJson -Path $journalPath -Value $journal

        [void](Assert-CycInitiatorStillCurrent -Binding $binding)
        $coreArgs = Get-CycBootstrapArguments `
            -BootstrapPath $bootstrap `
            -Operation $Action `
            -Binding $binding `
            -Roots $roots `
            -TransactionId $transactionId `
            -RequestSha256 $requestHash
        [void](Invoke-CycBootstrapProcess -Arguments $coreArgs)
        $coreSucceeded = $true
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
    Copy-Item -LiteralPath $exchange.response -Destination $privateReceiptPath -Force
    if ((Get-CycLifecycleSha256 -Path $privateReceiptPath) -cne (Get-CycLifecycleSha256 -Path $exchange.response)) {
        throw 'Durable firewall receipt copy failed integrity verification.'
    }
    if ($Action -in @('Install', 'Repair')) {
        Invoke-CycCommitFirewallReceipt `
            -BootstrapPath (Join-Path $roots.installRoot 'installer\bootstrap.ps1') `
            -Binding $binding `
            -Roots $roots `
            -TransactionId $transactionId `
            -ReceiptPath $privateReceiptPath
    }
    $journal.phase = 'complete'
    $journal.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    Write-CycLifecycleAtomicJson -Path $journalPath -Value $journal

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

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $result = Invoke-ClusterYourCodexLifecycle
        if (-not $Quiet) { $result }
        exit 0
    } catch {
        [Console]::Error.WriteLine(([string]$_.Exception.Message).Replace("`r", ' ').Replace("`n", ' '))
        exit 1
    }
}
