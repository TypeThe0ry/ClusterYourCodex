#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RequestPath,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedRequestSha256,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedHelperSha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This is intentionally the complete elevated surface. It accepts one bounded
# request document and can only create/replace/remove one product-owned inbound
# TCP rule. It cannot launch a caller-selected command or script.
$script:CycFirewallRequestSchema = 'cyc.dev/windows-firewall-request/v1'
$script:CycFirewallStateSchema = 'cyc.dev/windows-firewall-state/v1'
$script:CycFirewallReceiptSchema = 'cyc.dev/windows-firewall-receipt/v1'
$script:CycFirewallRuleGroup = 'ClusterYourCodex'
$script:CycFirewallRuleDescription = 'ClusterYourCodex owned managed-worker TLS listener'
$script:CycFirewallDisplayName = 'ClusterYourCodex Managed Worker'
$script:CycFirewallExchangeDirectory = 'ClusterYourCodex-Firewall'

function Resolve-CycFirewallPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ([string]::Equals($full, $root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $root
    }
    return $full.TrimEnd('\', '/')
}

function Get-CycFirewallSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Assert-CycFirewallExactProperties {
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

function Assert-CycFirewallPlainValue {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Label,
        [int]$MaximumLength = 4096
    )
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt $MaximumLength -or
        $Value.Contains('"') -or $Value.Contains("`r") -or $Value.Contains("`n") -or
        $Value -match '[\x00-\x1f\x7f]') {
        throw "$Label is invalid."
    }
}

function Read-CycFirewallJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][long]$MaximumBytes,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $resolved = Resolve-CycFirewallPath $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "$Label is missing."
    }
    $item = Get-Item -LiteralPath $resolved -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -lt 2 -or $item.Length -gt $MaximumBytes) {
        throw "$Label must be a bounded regular file."
    }
    try {
        $raw = Get-Content -LiteralPath $resolved -Raw -ErrorAction Stop
        $converter = Get-Command ConvertFrom-Json -CommandType Cmdlet -ErrorAction Stop
        if ($converter.Parameters.ContainsKey('DateKind')) {
            return ConvertFrom-Json -InputObject $raw -DateKind String
        }
        return ConvertFrom-Json -InputObject $raw
    } catch {
        throw "$Label contains invalid JSON."
    }
}

function Write-CycFirewallAtomicJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value,
        [int]$Depth = 10
    )
    $resolved = Resolve-CycFirewallPath $Path
    $parent = Split-Path -Parent $resolved
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw 'Firewall exchange directory disappeared.'
    }
    $temporary = Join-Path $parent ('.cyc-fw-' + [Guid]::NewGuid().ToString('N') + '.tmp')
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

function Get-CycExpectedRuleName {
    param([Parameter(Mandatory = $true)][string]$Sid)
    return 'ClusterYourCodex.ManagedWorker.' + $Sid.Replace('-', '_')
}

function Assert-CycFirewallRequestShape {
    param([Parameter(Mandatory = $true)]$Request)
    Assert-CycFirewallExactProperties -Object $Request -Label 'Firewall request' -Expected @(
        'action', 'createdAtUtc', 'deadlineUtc', 'displayName', 'exchangeRoot',
        'group', 'helperAuthenticodeRequired', 'initiatorLocalAppData',
        'initiatorProfile', 'initiatorSid', 'installRoot', 'packageExecutable',
        'packageManifestSha256', 'port', 'program', 'programSha256',
        'remoteAddress', 'requestNonce', 'ruleDescription', 'ruleName',
        'schemaVersion', 'transactionId'
    )
    if ([string]$Request.schemaVersion -cne $script:CycFirewallRequestSchema -or
        [string]$Request.action -cnotin @('Apply', 'Remove') -or
        [string]$Request.initiatorSid -cnotmatch '^S-1-5-(?:\d+-){1,14}\d+$' -or
        [string]$Request.transactionId -cnotmatch '^[0-9a-f]{32}$' -or
        [string]$Request.requestNonce -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$Request.packageManifestSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$Request.programSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        -not ($Request.port -is [byte] -or $Request.port -is [int16] -or
            $Request.port -is [int32] -or $Request.port -is [int64]) -or
        [long]$Request.port -lt 1 -or [long]$Request.port -gt 65535 -or
        -not ($Request.helperAuthenticodeRequired -is [bool])) {
        throw 'Firewall request metadata is invalid.'
    }
    foreach ($field in @(
        'initiatorProfile', 'initiatorLocalAppData', 'installRoot', 'program',
        'exchangeRoot', 'packageExecutable'
    )) {
        Assert-CycFirewallPlainValue -Value ([string]$Request.$field) -Label $field
    }
    foreach ($field in @('group', 'ruleDescription', 'displayName', 'remoteAddress', 'ruleName')) {
        Assert-CycFirewallPlainValue -Value ([string]$Request.$field) -Label $field -MaximumLength 256
    }
    if ([string]$Request.group -cne $script:CycFirewallRuleGroup -or
        [string]$Request.ruleDescription -cne $script:CycFirewallRuleDescription -or
        [string]$Request.displayName -cne $script:CycFirewallDisplayName -or
        [string]$Request.remoteAddress -cne 'LocalSubnet' -or
        [string]$Request.ruleName -cne (Get-CycExpectedRuleName -Sid ([string]$Request.initiatorSid))) {
        throw 'Firewall request attempts to change the fixed rule identity or scope.'
    }
    $created = [DateTimeOffset]::MinValue
    $deadline = [DateTimeOffset]::MinValue
    $timestampStyle = [System.Globalization.DateTimeStyles]::RoundtripKind
    $createdParsed = [DateTimeOffset]::TryParse(
        [string]$Request.createdAtUtc,
        [System.Globalization.CultureInfo]::InvariantCulture,
        $timestampStyle,
        [ref]$created
    )
    $deadlineParsed = [DateTimeOffset]::TryParse(
        [string]$Request.deadlineUtc,
        [System.Globalization.CultureInfo]::InvariantCulture,
        $timestampStyle,
        [ref]$deadline
    )
    if ([string]$Request.createdAtUtc -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}(?:Z|[+-]\d{2}:\d{2})$' -or
        [string]$Request.deadlineUtc -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}(?:Z|[+-]\d{2}:\d{2})$' -or
        -not $createdParsed -or -not $deadlineParsed) {
        throw 'Firewall request timestamps are invalid.'
    }
    if ($deadline -le $created -or ($deadline - $created).TotalMinutes -gt 35) {
        throw 'Firewall request deadline is invalid.'
    }
    return $Request
}

function Assert-CycFirewallRequestBinding {
    param(
        [Parameter(Mandatory = $true)]$Request,
        [Parameter(Mandatory = $true)][string]$RequestFile,
        [Parameter(Mandatory = $true)][string]$ExpectedRequestHash,
        [Parameter(Mandatory = $true)][string]$ObservedHelperHash,
        [Parameter(Mandatory = $true)][string]$ExpectedHelperHash,
        [scriptblock]$ProfileResolver,
        [scriptblock]$ExchangeBaseResolver
    )
    [void](Assert-CycFirewallRequestShape -Request $Request)
    if ($ExpectedRequestHash -cnotmatch '^[0-9a-f]{64}$' -or
        $ObservedHelperHash -cne $ExpectedHelperHash) {
        throw 'Firewall helper or request digest is not the package-bound value.'
    }
    $requestFilePath = Resolve-CycFirewallPath $RequestFile
    if ((Get-CycFirewallSha256 -Path $requestFilePath) -cne $ExpectedRequestHash) {
        throw 'Firewall request changed after the unelevated coordinator approved it.'
    }
    $profile = Resolve-CycFirewallPath ([string]$Request.initiatorProfile)
    $localAppData = Resolve-CycFirewallPath ([string]$Request.initiatorLocalAppData)
    $installRoot = Resolve-CycFirewallPath ([string]$Request.installRoot)
    $program = Resolve-CycFirewallPath ([string]$Request.program)
    $exchange = Resolve-CycFirewallPath ([string]$Request.exchangeRoot)
    $exchangeBase = if ($ExchangeBaseResolver) {
        Resolve-CycFirewallPath ([string](& $ExchangeBaseResolver ([string]$Request.initiatorSid)))
    } else {
        $commonDocuments = [Environment]::GetFolderPath('CommonDocuments')
        if ([string]::IsNullOrWhiteSpace($commonDocuments)) { throw 'Public Documents is unavailable.' }
        Resolve-CycFirewallPath (Join-Path (Join-Path $commonDocuments $script:CycFirewallExchangeDirectory) ([string]$Request.initiatorSid).Replace('-', '_'))
    }
    $expectedExchange = Resolve-CycFirewallPath (Join-Path $exchangeBase ([string]$Request.transactionId))
    if (-not [string]::Equals(
        $installRoot,
        (Resolve-CycFirewallPath (Join-Path $localAppData 'Programs\ClusterYourCodex')),
        [System.StringComparison]::OrdinalIgnoreCase
    ) -or -not [string]::Equals(
        $program,
        (Resolve-CycFirewallPath (Join-Path $installRoot 'cyc-controller.exe')),
        [System.StringComparison]::OrdinalIgnoreCase
    ) -or -not [string]::Equals(
        $requestFilePath,
        (Resolve-CycFirewallPath (Join-Path $exchange 'request.json')),
        [System.StringComparison]::OrdinalIgnoreCase
    ) -or -not [string]::Equals(
        $exchange,
        $expectedExchange,
        [System.StringComparison]::OrdinalIgnoreCase
    ) -or (Split-Path -Leaf $exchange) -cne [string]$Request.transactionId) {
        throw 'Firewall request is not bound to the initiating profile and fixed product paths.'
    }
    $resolvedProfile = if ($ProfileResolver) {
        [string](& $ProfileResolver ([string]$Request.initiatorSid))
    } else {
        $profileKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\' +
            [string]$Request.initiatorSid
        $profileRecord = Get-ItemProperty -LiteralPath $profileKey -ErrorAction Stop
        [Environment]::ExpandEnvironmentVariables([string]$profileRecord.ProfileImagePath)
    }
    if (-not [string]::Equals(
        (Resolve-CycFirewallPath $resolvedProfile),
        $profile,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Initiating SID and profile binding changed or is invalid.'
    }
    if ([DateTimeOffset]::UtcNow -gt [DateTimeOffset]::Parse([string]$Request.deadlineUtc)) {
        throw 'Firewall request expired before elevation completed.'
    }
    return $Request
}

function Test-CycFirewallAdministrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-CycFirewallAuthenticode {
    param([Parameter(Mandatory = $true)]$Request)
    if (-not [bool]$Request.helperAuthenticodeRequired) { return }
    foreach ($path in @($PSCommandPath, [string]$Request.packageExecutable)) {
        $signature = Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop
        if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
            -not $signature.SignerCertificate) {
            throw 'GA firewall elevation requires valid Authenticode on Setup and the narrow helper.'
        }
    }
}

function Get-CycOwnedFirewallRule {
    param([Parameter(Mandatory = $true)]$Request)
    $rules = @(Get-NetFirewallRule -Name ([string]$Request.ruleName) -ErrorAction SilentlyContinue)
    if ($rules.Count -gt 1) { throw 'Duplicate firewall rule name collision.' }
    if ($rules.Count -eq 0) { return $null }
    $rule = $rules[0]
    if ([string]$rule.Group -cne $script:CycFirewallRuleGroup -or
        [string]$rule.Description -cne $script:CycFirewallRuleDescription) {
        throw 'Firewall rule-name collision is not product-owned.'
    }
    $port = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
    $address = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
    $application = Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
    if ([string]$rule.Direction -notmatch '^(1|Inbound)$' -or
        [string]$rule.Action -notmatch '^(2|Allow)$' -or
        [string]$rule.Profile -notmatch '^(2|Private)$' -or
        [string]$rule.DisplayName -cne $script:CycFirewallDisplayName -or
        [string]$rule.EdgeTraversalPolicy -notmatch '^(0|Block)$' -or
        [string]$port.Protocol -notmatch '^(6|TCP)$' -or
        [string]$port.LocalPort -notmatch '^\d{1,5}$' -or
        [int]$port.LocalPort -lt 1 -or [int]$port.LocalPort -gt 65535 -or
        [string]$port.RemotePort -notmatch '^(Any|0-65535)$' -or
        @($address.LocalAddress).Count -ne 1 -or
        @($address.LocalAddress) -cnotcontains 'Any' -or
        @($address.RemoteAddress).Count -ne 1 -or
        @($address.RemoteAddress) -cnotcontains 'LocalSubnet' -or
        -not [string]::Equals(
            (Resolve-CycFirewallPath ([string]$application.Program)),
            (Resolve-CycFirewallPath ([string]$Request.program)),
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'Existing rule with the product name does not match the fixed product scope.'
    }
    return [PSCustomObject]@{
        rule = $rule
        port = $port
        address = $address
        application = $application
    }
}

function Get-CycFirewallOriginalSnapshot {
    param([Parameter(Mandatory = $true)]$Request)
    $owned = Get-CycOwnedFirewallRule -Request $Request
    if (-not $owned) {
        return [ordered]@{ existed = $false }
    }
    return [ordered]@{
        existed = $true
        enabled = [string]$owned.rule.Enabled
        port = [int]$owned.port.LocalPort
    }
}

function Set-CycExactFirewallDesiredState {
    param([Parameter(Mandatory = $true)]$Request)
    $owned = Get-CycOwnedFirewallRule -Request $Request
    if ($owned) {
        Remove-NetFirewallRule -Name ([string]$Request.ruleName) -ErrorAction Stop
    }
    if ([string]$Request.action -ceq 'Remove') { return }
    New-NetFirewallRule `
        -Name ([string]$Request.ruleName) `
        -DisplayName $script:CycFirewallDisplayName `
        -Group $script:CycFirewallRuleGroup `
        -Description $script:CycFirewallRuleDescription `
        -Direction Inbound `
        -Action Allow `
        -Enabled True `
        -Profile Private `
        -Protocol TCP `
        -LocalPort ([int]$Request.port) `
        -RemoteAddress LocalSubnet `
        -Program ([string]$Request.program) `
        -EdgeTraversalPolicy Block | Out-Null
    $created = Get-CycOwnedFirewallRule -Request $Request
    if (-not $created -or [string]$created.rule.Enabled -ne 'True' -or
        [int]$created.port.LocalPort -ne [int]$Request.port) {
        throw 'Product-owned firewall rule failed apply verification.'
    }
}

function Restore-CycExactFirewallSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Request,
        [Parameter(Mandatory = $true)]$Snapshot
    )
    Assert-CycFirewallExactProperties -Object $Snapshot -Label 'Firewall rollback snapshot' -Expected @(
        if ([bool]$Snapshot.existed) { 'enabled'; 'existed'; 'port' } else { 'existed' }
    )
    $owned = Get-CycOwnedFirewallRule -Request $Request
    if ($owned) { Remove-NetFirewallRule -Name ([string]$Request.ruleName) -ErrorAction Stop }
    if (-not [bool]$Snapshot.existed) { return }
    New-NetFirewallRule `
        -Name ([string]$Request.ruleName) `
        -DisplayName $script:CycFirewallDisplayName `
        -Group $script:CycFirewallRuleGroup `
        -Description $script:CycFirewallRuleDescription `
        -Direction Inbound `
        -Action Allow `
        -Enabled ([string]$Snapshot.enabled) `
        -Profile Private `
        -Protocol TCP `
        -LocalPort ([int]$Snapshot.port) `
        -RemoteAddress LocalSubnet `
        -Program ([string]$Request.program) `
        -EdgeTraversalPolicy Block | Out-Null
    $restored = Get-CycOwnedFirewallRule -Request $Request
    if (-not $restored -or
        [string]$restored.rule.Enabled -cne [string]$Snapshot.enabled -or
        [int]$restored.port.LocalPort -ne [int]$Snapshot.port) {
        throw 'Original product-owned firewall state failed rollback verification.'
    }
}

function Test-CycFirewallDesiredState {
    param(
        [Parameter(Mandatory = $true)]$Request,
        [switch]$Final
    )
    $owned = Get-CycOwnedFirewallRule -Request $Request
    if ([string]$Request.action -ceq 'Remove') {
        if ($owned) { throw 'Firewall rule remains after verified removal.' }
        return $true
    }
    if (-not $owned -or [string]$owned.rule.Enabled -ne 'True' -or
        [int]$owned.port.LocalPort -ne [int]$Request.port) {
        throw 'Firewall rule is absent or disabled after apply.'
    }
    if ($Final) {
        if (-not (Test-Path -LiteralPath ([string]$Request.program) -PathType Leaf) -or
            (Get-CycFirewallSha256 -Path ([string]$Request.program)) -cne [string]$Request.programSha256) {
            throw 'Installed controller does not match the request-bound binary at firewall commit.'
        }
    }
    return $true
}

function Get-CycFirewallHelperRecoveryAction {
    param(
        [bool]$FinalizeSignal,
        [bool]$RollbackSignal,
        [bool]$Expired
    )
    if ($RollbackSignal) { return 'Rollback' }
    if ($FinalizeSignal) { return 'Finalize' }
    if ($Expired) { return 'Rollback' }
    return 'Wait'
}

function Assert-CycFirewallReplayBinding {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$TransactionId,
        [Parameter(Mandatory = $true)][string]$RequestSha256
    )
    if ([string]$State.schemaVersion -cne $script:CycFirewallStateSchema -or
        [string]$State.transactionId -cne $TransactionId -or
        [string]$State.requestSha256 -cne $RequestSha256) {
        throw 'Firewall transaction state replay does not match the approved request.'
    }
    return $State
}

function Wait-CycFirewallSignal {
    param(
        [Parameter(Mandatory = $true)][string]$ExchangeRoot,
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][DateTimeOffset]$Deadline
    )
    do {
        foreach ($name in $Names) {
            if (Test-Path -LiteralPath (Join-Path $ExchangeRoot $name) -PathType Leaf) { return $name }
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTimeOffset]::UtcNow -lt $Deadline)
    return $null
}

function New-CycFirewallReceipt {
    param(
        [Parameter(Mandatory = $true)]$Request,
        [Parameter(Mandatory = $true)][string]$RequestHash,
        [Parameter(Mandatory = $true)][ValidateSet('verified', 'rolledBack', 'rollbackFailed')][string]$Result,
        [string]$FailureCode
    )
    return [ordered]@{
        schemaVersion = $script:CycFirewallReceiptSchema
        transactionId = [string]$Request.transactionId
        requestSha256 = $RequestHash
        action = [string]$Request.action
        result = $Result
        failureCode = if ([string]::IsNullOrWhiteSpace($FailureCode)) { $null } else { $FailureCode }
        initiatorSid = [string]$Request.initiatorSid
        initiatorProfile = [string]$Request.initiatorProfile
        initiatorLocalAppData = [string]$Request.initiatorLocalAppData
        ruleName = [string]$Request.ruleName
        program = [string]$Request.program
        programSha256 = [string]$Request.programSha256
        port = [int]$Request.port
        verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }
}

function Invoke-CycFirewallElevatedTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$BoundRequestPath,
        [Parameter(Mandatory = $true)][string]$RequestHash,
        [Parameter(Mandatory = $true)][string]$HelperHash
    )
    if (-not (Test-CycFirewallAdministrator)) {
        throw 'The firewall helper must run elevated.'
    }
    $observedHelperHash = Get-CycFirewallSha256 -Path $PSCommandPath
    $request = Read-CycFirewallJson -Path $BoundRequestPath -MaximumBytes 32768 -Label 'Firewall request'
    [void](Assert-CycFirewallRequestBinding `
        -Request $request `
        -RequestFile $BoundRequestPath `
        -ExpectedRequestHash $RequestHash `
        -ObservedHelperHash $observedHelperHash `
        -ExpectedHelperHash $HelperHash)
    Assert-CycFirewallAuthenticode -Request $request

    $exchange = Resolve-CycFirewallPath ([string]$request.exchangeRoot)
    $statePath = Join-Path $exchange 'state.json'
    $responsePath = Join-Path $exchange 'response.json'
    $lockPath = Join-Path $exchange 'helper.lock'
    $lock = $null
    try {
        $lock = New-Object System.IO.FileStream(
            $lockPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
    } catch { throw 'Another firewall helper already owns this transaction.' }

    $applied = $false
    $snapshot = $null
    try {
        if (Test-Path -LiteralPath $responsePath -PathType Leaf) {
            $existingReceipt = Read-CycFirewallJson -Path $responsePath -MaximumBytes 32768 -Label 'Firewall receipt'
            if ([string]$existingReceipt.transactionId -cne [string]$request.transactionId -or
                [string]$existingReceipt.requestSha256 -cne $RequestHash -or
                [string]$existingReceipt.result -cne 'verified') {
                throw 'Finalized firewall transaction replay does not match the approved request.'
            }
            return $existingReceipt
        }

        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            $state = Read-CycFirewallJson -Path $statePath -MaximumBytes 65536 -Label 'Firewall state'
            [void](Assert-CycFirewallReplayBinding `
                -State $state `
                -TransactionId ([string]$request.transactionId) `
                -RequestSha256 $RequestHash)
            $snapshot = $state.original
            $applied = [string]$state.phase -cin @('applying', 'applied')
        } else {
            $snapshot = Get-CycFirewallOriginalSnapshot -Request $request
            $state = [ordered]@{
                schemaVersion = $script:CycFirewallStateSchema
                transactionId = [string]$request.transactionId
                requestSha256 = $RequestHash
                phase = 'prepared'
                original = $snapshot
                helperProcessId = $PID
                preparedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
                appliedAtUtc = $null
            }
            Write-CycFirewallAtomicJson -Path $statePath -Value $state
        }
        [System.IO.File]::WriteAllText((Join-Path $exchange 'ready.signal'), '', (New-Object System.Text.UTF8Encoding($false)))
        $deadline = [DateTimeOffset]::Parse([string]$request.deadlineUtc)
        $applySignal = Wait-CycFirewallSignal -ExchangeRoot $exchange -Names @('rollback.signal', 'apply.signal') -Deadline $deadline
        if ($applySignal -ne 'apply.signal') {
            $receipt = New-CycFirewallReceipt -Request $request -RequestHash $RequestHash -Result 'rolledBack' -FailureCode 'cancelled-before-apply'
            Write-CycFirewallAtomicJson -Path $responsePath -Value $receipt
            return $receipt
        }

        $state.phase = 'applying'
        Write-CycFirewallAtomicJson -Path $statePath -Value $state
        Set-CycExactFirewallDesiredState -Request $request
        [void](Test-CycFirewallDesiredState -Request $request)
        $applied = $true
        $state.phase = 'applied'
        $state.appliedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Write-CycFirewallAtomicJson -Path $statePath -Value $state
        [System.IO.File]::WriteAllText((Join-Path $exchange 'applied.signal'), '', (New-Object System.Text.UTF8Encoding($false)))

        $decisionSignal = Wait-CycFirewallSignal -ExchangeRoot $exchange -Names @('rollback.signal', 'finalize.signal') -Deadline $deadline
        $decision = Get-CycFirewallHelperRecoveryAction `
            -FinalizeSignal:($decisionSignal -eq 'finalize.signal') `
            -RollbackSignal:($decisionSignal -eq 'rollback.signal') `
            -Expired:($null -eq $decisionSignal)
        if ($decision -eq 'Finalize') {
            [void](Test-CycFirewallDesiredState -Request $request -Final)
            $receipt = New-CycFirewallReceipt -Request $request -RequestHash $RequestHash -Result 'verified'
            Write-CycFirewallAtomicJson -Path $responsePath -Value $receipt
            $state.phase = 'verified'
            Write-CycFirewallAtomicJson -Path $statePath -Value $state
            return $receipt
        }

        Restore-CycExactFirewallSnapshot -Request $request -Snapshot $snapshot
        $applied = $false
        $receipt = New-CycFirewallReceipt -Request $request -RequestHash $RequestHash -Result 'rolledBack' -FailureCode 'coordinator-cancelled-or-timed-out'
        Write-CycFirewallAtomicJson -Path $responsePath -Value $receipt
        $state.phase = 'rolledBack'
        Write-CycFirewallAtomicJson -Path $statePath -Value $state
        return $receipt
    } catch {
        $failure = $_
        if ($applied -and $snapshot) {
            try {
                Restore-CycExactFirewallSnapshot -Request $request -Snapshot $snapshot
                $receipt = New-CycFirewallReceipt -Request $request -RequestHash $RequestHash -Result 'rolledBack' -FailureCode 'helper-failure'
                Write-CycFirewallAtomicJson -Path $responsePath -Value $receipt
            } catch {
                $receipt = New-CycFirewallReceipt -Request $request -RequestHash $RequestHash -Result 'rollbackFailed' -FailureCode 'helper-and-rollback-failure'
                try { Write-CycFirewallAtomicJson -Path $responsePath -Value $receipt } catch { }
                throw "Firewall helper failed and rollback failed closed. Original failure: $($failure.Exception.Message)"
            }
        }
        throw $failure
    } finally {
        if ($lock) { $lock.Dispose() }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $result = Invoke-CycFirewallElevatedTransaction `
            -BoundRequestPath $RequestPath `
            -RequestHash $ExpectedRequestSha256 `
            -HelperHash $ExpectedHelperSha256
        if ([string]$result.result -ceq 'verified') { exit 0 }
        exit 2
    } catch {
        [Console]::Error.WriteLine(([string]$_.Exception.Message).Replace("`r", ' ').Replace("`n", ' '))
        exit 1
    }
}
