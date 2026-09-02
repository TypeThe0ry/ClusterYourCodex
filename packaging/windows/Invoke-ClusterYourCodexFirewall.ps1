#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RequestPath,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedRequestSha256,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedHelperSha256,
    [string]$RecoveryAction,
    [string]$RecoveryJournalPhase,
    [string]$RecoveryJournalPath,
    [string]$ExpectedRecoveryJournalSha256,
    [string]$VerifiedHelperPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This is intentionally the complete elevated surface. It accepts one bounded
# request document and can only create/replace/remove one product-owned inbound
# TCP rule. It cannot launch a caller-selected command or script.
$script:CycFirewallRequestSchema = 'cyc.dev/windows-firewall-request/v1'
$script:CycFirewallStateSchema = 'cyc.dev/windows-firewall-state/v1'
$script:CycFirewallReceiptSchema = 'cyc.dev/windows-firewall-receipt/v1'
$script:CycLifecycleJournalSchema = 'cyc.dev/windows-external-lifecycle/v1'
$script:CycFirewallRuleGroup = 'ClusterYourCodex'
$script:CycFirewallRuleDescription = 'ClusterYourCodex owned managed-worker TLS listener'
$script:CycFirewallDisplayName = 'ClusterYourCodex Managed Worker'
$script:CycFirewallExchangeDirectory = 'ClusterYourCodex-Firewall'
$script:CycFirewallHelperName = 'Invoke-ClusterYourCodexFirewall.ps1'

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
    $stream = $null
    $sha256 = $null
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        return ([System.BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $sha256) { $sha256.Dispose() }
    }
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
        [byte[]]$bytes = [System.IO.File]::ReadAllBytes($resolved)
        $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
        $hasUtf8Bom = $bytes.Length -ge 3 -and
            $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        $raw = if ($hasUtf8Bom) {
            $utf8Strict.GetString($bytes, 3, $bytes.Length - 3)
        } else {
            $utf8Strict.GetString($bytes)
        }
        $converter = Get-Command ConvertFrom-Json -CommandType Cmdlet -ErrorAction Stop
        if ($converter.Parameters.ContainsKey('DateKind')) {
            return ConvertFrom-Json -InputObject $raw -DateKind String
        }
        return ConvertFrom-Json -InputObject $raw
    } catch {
        throw "$Label contains invalid JSON."
    }
}

function Read-CycFirewallDigestBoundJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedSha256,
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

    $stream = $null
    $memory = $null
    $sha = $null
    try {
        # Keep the exact file handle non-writable until both the digest and JSON
        # object have been derived from the same captured bytes. This avoids a
        # hash-then-reopen recovery evidence race across the UAC boundary.
        $stream = New-Object System.IO.FileStream(
            $resolved,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        if ($stream.Length -lt 2 -or $stream.Length -gt $MaximumBytes) {
            throw "$Label must be a bounded regular file."
        }
        $memory = New-Object System.IO.MemoryStream
        $stream.CopyTo($memory)
        [byte[]]$bytes = $memory.ToArray()
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $observed = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
        if ($observed -cne $ExpectedSha256) {
            throw "$Label changed after the unelevated coordinator approved it."
        }
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $hasUtf8Bom = $bytes.Length -ge 3 -and
            $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        $raw = if ($hasUtf8Bom) {
            $utf8.GetString($bytes, 3, $bytes.Length - 3)
        } else {
            $utf8.GetString($bytes)
        }
        $converter = Get-Command ConvertFrom-Json -CommandType Cmdlet -ErrorAction Stop
        $value = if ($converter.Parameters.ContainsKey('DateKind')) {
            ConvertFrom-Json -InputObject $raw -DateKind String
        } else {
            ConvertFrom-Json -InputObject $raw
        }
        return [PSCustomObject]@{
            path = $resolved
            sha256 = $observed
            value = $value
        }
    } catch {
        if ($_.Exception.Message -like "$Label *") { throw }
        throw "$Label contains invalid JSON."
    } finally {
        if ($sha) { $sha.Dispose() }
        if ($memory) { $memory.Dispose() }
        if ($stream) { $stream.Dispose() }
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
    $backup = Join-Path $parent ('.cyc-fw-' + [Guid]::NewGuid().ToString('N') + '.bak')
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
            if (($destination.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
                $destination.PSIsContainer) {
                throw 'Firewall transaction output must be a regular file.'
            }
            [System.IO.File]::Replace($temporary, $resolved, $backup, $true)
        } else {
            [System.IO.File]::Move($temporary, $resolved)
        }
        # Replace/move is the commit point. Cleanup after this point is strictly
        # best effort so an AV/share race cannot trigger compensating rollback
        # after the terminal document is already durable and visible.
        $committed = $true
    } finally {
        if ($stream) { $stream.Dispose() }
        try {
            if (Test-Path -LiteralPath $temporary) {
                Remove-Item -LiteralPath $temporary -Force
            }
        } catch { }
        if ($committed) {
            try {
                if (Test-Path -LiteralPath $backup) {
                    Remove-Item -LiteralPath $backup -Force
                }
            } catch { }
        }
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
        [string]$ObservedRequestHash,
        [scriptblock]$ProfileResolver,
        [scriptblock]$ExchangeBaseResolver,
        [switch]$AllowExpiredRecovery
    )
    [void](Assert-CycFirewallRequestShape -Request $Request)
    if ($ExpectedRequestHash -cnotmatch '^[0-9a-f]{64}$' -or
        $ObservedHelperHash -cne $ExpectedHelperHash) {
        throw 'Firewall helper or request digest is not the package-bound value.'
    }
    $requestFilePath = Resolve-CycFirewallPath $RequestFile
    $approvedRequestHash = if ([string]::IsNullOrWhiteSpace($ObservedRequestHash)) {
        Get-CycFirewallSha256 -Path $requestFilePath
    } else {
        $ObservedRequestHash
    }
    if ($approvedRequestHash -cnotmatch '^[0-9a-f]{64}$' -or
        $approvedRequestHash -cne $ExpectedRequestHash) {
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
    if (-not $AllowExpiredRecovery -and
        [DateTimeOffset]::UtcNow -gt [DateTimeOffset]::Parse([string]$Request.deadlineUtc)) {
        throw 'Firewall request expired before elevation completed.'
    }
    return $Request
}

function Assert-CycFirewallRecoveryArguments {
    param(
        [string]$Action,
        [string]$JournalPhase,
        [string]$JournalPath,
        [string]$ExpectedJournalSha256
    )
    $present = @(
        -not [string]::IsNullOrWhiteSpace($Action),
        -not [string]::IsNullOrWhiteSpace($JournalPhase),
        -not [string]::IsNullOrWhiteSpace($JournalPath),
        -not [string]::IsNullOrWhiteSpace($ExpectedJournalSha256)
    )
    $presentCount = @($present | Where-Object { $_ }).Count
    if ($presentCount -eq 0) { return $false }
    if ($presentCount -ne 4) {
        throw 'Firewall recovery action, lifecycle phase, journal path, and journal digest must be supplied together.'
    }
    if ($Action -cnotin @('Rollback', 'Finalize') -or
        $JournalPhase -cnotin @('prepared', 'firewallApplied', 'coreApplied') -or
        $ExpectedJournalSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Firewall recovery arguments are invalid.'
    }
    Assert-CycFirewallPlainValue -Value $JournalPath -Label 'RecoveryJournalPath'
    if (($Action -ceq 'Finalize') -ne ($JournalPhase -ceq 'coreApplied')) {
        throw 'Firewall recovery finalize is permitted if and only if the bound lifecycle phase is coreApplied.'
    }
    return $true
}

function Assert-CycFirewallRecoveryJournalBinding {
    param(
        [Parameter(Mandatory = $true)]$Journal,
        [Parameter(Mandatory = $true)][string]$JournalFile,
        [Parameter(Mandatory = $true)][string]$JournalHash,
        [Parameter(Mandatory = $true)]$Request,
        [Parameter(Mandatory = $true)][string]$RequestFile,
        [Parameter(Mandatory = $true)][string]$RequestHash,
        [Parameter(Mandatory = $true)][string]$HelperFile,
        [Parameter(Mandatory = $true)][string]$HelperHash,
        [Parameter(Mandatory = $true)][ValidateSet('Rollback', 'Finalize')][string]$RecoveryAction,
        [Parameter(Mandatory = $true)][ValidateSet('prepared', 'firewallApplied', 'coreApplied')][string]$RecoveryJournalPhase
    )
    Assert-CycFirewallExactProperties -Object $Journal -Label 'Firewall lifecycle journal' -Expected @(
        'action', 'dataRoot', 'exchangeRoot', 'helperSha256', 'initiatorLocalAppData',
        'initiatorProfile', 'initiatorSid', 'installRoot', 'packageManifestSha256',
        'phase', 'privateReceiptPath', 'requestPath', 'requestSha256', 'schemaVersion',
        'transactionId', 'updatedAtUtc'
    )
    if ($JournalHash -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$Journal.schemaVersion -cne $script:CycLifecycleJournalSchema -or
        [string]$Journal.transactionId -cnotmatch '^[0-9a-f]{32}$' -or
        [string]$Journal.transactionId -cne [string]$Request.transactionId -or
        [string]$Journal.action -cnotin @('Install', 'Repair', 'Uninstall') -or
        [string]$Journal.phase -cne $RecoveryJournalPhase -or
        [string]$Journal.requestSha256 -cne $RequestHash -or
        [string]$Journal.helperSha256 -cne $HelperHash -or
        [string]$Journal.packageManifestSha256 -cne [string]$Request.packageManifestSha256) {
        throw 'Firewall lifecycle journal metadata is not bound to the approved recovery.'
    }
    if (([string]$Request.action -ceq 'Apply' -and [string]$Journal.action -cnotin @('Install', 'Repair')) -or
        ([string]$Request.action -ceq 'Remove' -and [string]$Journal.action -cne 'Uninstall')) {
        throw 'Firewall lifecycle journal action does not match the approved firewall request.'
    }
    if (($RecoveryAction -ceq 'Finalize') -ne ([string]$Journal.phase -ceq 'coreApplied')) {
        throw 'Firewall lifecycle journal permits finalize if and only if core is applied.'
    }

    $updatedAt = [DateTimeOffset]::MinValue
    $timestampStyle = [System.Globalization.DateTimeStyles]::RoundtripKind
    if ([string]$Journal.updatedAtUtc -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}(?:Z|[+-]\d{2}:\d{2})$' -or
        -not [DateTimeOffset]::TryParse(
            [string]$Journal.updatedAtUtc,
            [System.Globalization.CultureInfo]::InvariantCulture,
            $timestampStyle,
            [ref]$updatedAt
        )) {
        throw 'Firewall lifecycle journal timestamp is invalid.'
    }

    foreach ($field in @(
        'initiatorProfile', 'initiatorLocalAppData', 'installRoot', 'dataRoot',
        'exchangeRoot', 'requestPath', 'privateReceiptPath'
    )) {
        Assert-CycFirewallPlainValue -Value ([string]$Journal.$field) -Label "journal.$field"
    }
    $localAppData = Resolve-CycFirewallPath ([string]$Request.initiatorLocalAppData)
    $dataRoot = Resolve-CycFirewallPath (Join-Path $localAppData 'ClusterYourCodex')
    $installerRoot = Resolve-CycFirewallPath (Join-Path $dataRoot '.installer')
    $exchange = Resolve-CycFirewallPath ([string]$Request.exchangeRoot)
    $expectedHelper = Resolve-CycFirewallPath (Join-Path $exchange $script:CycFirewallHelperName)
    $expectedPrivateReceipt = Resolve-CycFirewallPath (
        Join-Path (Join-Path $installerRoot 'firewall-receipts') (([string]$Request.transactionId) + '.json')
    )
    $pathBindings = @(
        # Recovery evidence is a digest-bound, coordinator-published copy in
        # the public transaction exchange. The private lifecycle journal stays
        # under the initiating user's data root and may be unreadable to an
        # over-the-shoulder administrator. Every path *inside* the published
        # journal remains bound to the initiating user's real private roots.
        [PSCustomObject]@{ actual = Resolve-CycFirewallPath $JournalFile; expected = Resolve-CycFirewallPath (Join-Path $exchange 'recovery-journal.json') }
        [PSCustomObject]@{ actual = Resolve-CycFirewallPath ([string]$Journal.installRoot); expected = Resolve-CycFirewallPath ([string]$Request.installRoot) }
        [PSCustomObject]@{ actual = Resolve-CycFirewallPath ([string]$Journal.dataRoot); expected = $dataRoot }
        [PSCustomObject]@{ actual = Resolve-CycFirewallPath ([string]$Journal.exchangeRoot); expected = $exchange }
        [PSCustomObject]@{ actual = Resolve-CycFirewallPath ([string]$Journal.requestPath); expected = Resolve-CycFirewallPath $RequestFile }
        [PSCustomObject]@{ actual = Resolve-CycFirewallPath ([string]$Journal.privateReceiptPath); expected = $expectedPrivateReceipt }
        [PSCustomObject]@{ actual = Resolve-CycFirewallPath $HelperFile; expected = $expectedHelper }
    )
    foreach ($binding in $pathBindings) {
        if (-not [string]::Equals(
            [string]$binding.actual,
            [string]$binding.expected,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            throw 'Firewall lifecycle journal paths are not bound to the exact recovery transaction.'
        }
    }
    if ([string]$Journal.initiatorSid -cne [string]$Request.initiatorSid -or
        -not [string]::Equals(
            (Resolve-CycFirewallPath ([string]$Journal.initiatorProfile)),
            (Resolve-CycFirewallPath ([string]$Request.initiatorProfile)),
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        -not [string]::Equals(
            (Resolve-CycFirewallPath ([string]$Journal.initiatorLocalAppData)),
            $localAppData,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'Firewall lifecycle journal initiator is not bound to the approved request.'
    }
    return $Journal
}

function Test-CycFirewallAdministrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-CycFirewallAuthenticode {
    param(
        [Parameter(Mandatory = $true)]$Request,
        [Parameter(Mandatory = $true)][string]$HelperPath,
        [switch]$Recovery
    )
    if (-not [bool]$Request.helperAuthenticodeRequired) { return }
    $signedPaths = if ($Recovery) { @($HelperPath) } else { @($HelperPath, [string]$Request.packageExecutable) }
    foreach ($path in $signedPaths) {
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

function Assert-CycFirewallStateShape {
    param([Parameter(Mandatory = $true)]$State)
    Assert-CycFirewallExactProperties -Object $State -Label 'Firewall state' -Expected @(
        'appliedAtUtc', 'helperProcessId', 'original', 'phase', 'preparedAtUtc',
        'requestSha256', 'schemaVersion', 'transactionId'
    )
    if ([string]$State.phase -cnotin @('prepared', 'applying', 'applied', 'verified', 'rolledBack', 'rollbackFailed') -or
        -not ($State.helperProcessId -is [byte] -or $State.helperProcessId -is [int16] -or
            $State.helperProcessId -is [int32] -or $State.helperProcessId -is [int64]) -or
        [long]$State.helperProcessId -lt 1) {
        throw 'Firewall state metadata is invalid.'
    }
    $preparedAt = [DateTimeOffset]::MinValue
    $timestampStyle = [System.Globalization.DateTimeStyles]::RoundtripKind
    if ([string]$State.preparedAtUtc -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}(?:Z|[+-]\d{2}:\d{2})$' -or
        -not [DateTimeOffset]::TryParse(
            [string]$State.preparedAtUtc,
            [System.Globalization.CultureInfo]::InvariantCulture,
            $timestampStyle,
            [ref]$preparedAt
        )) {
        throw 'Firewall state preparation timestamp is invalid.'
    }
    if ($null -ne $State.appliedAtUtc) {
        $appliedAt = [DateTimeOffset]::MinValue
        if ([string]$State.appliedAtUtc -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}(?:Z|[+-]\d{2}:\d{2})$' -or
            -not [DateTimeOffset]::TryParse(
                [string]$State.appliedAtUtc,
                [System.Globalization.CultureInfo]::InvariantCulture,
                $timestampStyle,
                [ref]$appliedAt
            )) {
            throw 'Firewall state apply timestamp is invalid.'
        }
    }
    if (-not ($State.original.existed -is [bool])) {
        throw 'Firewall rollback snapshot existence marker must be Boolean.'
    }
    if ([bool]$State.original.existed) {
        Assert-CycFirewallExactProperties -Object $State.original -Label 'Firewall rollback snapshot' -Expected @('enabled', 'existed', 'port')
        if ([string]$State.original.enabled -cnotin @('True', 'False') -or
            -not ($State.original.port -is [byte] -or $State.original.port -is [int16] -or
                $State.original.port -is [int32] -or $State.original.port -is [int64]) -or
            [long]$State.original.port -lt 1 -or [long]$State.original.port -gt 65535) {
            throw 'Firewall rollback snapshot metadata is invalid.'
        }
    } else {
        Assert-CycFirewallExactProperties -Object $State.original -Label 'Firewall rollback snapshot' -Expected @('existed')
    }
    return $State
}

function Get-CycFirewallBoundRecoveryAction {
    param(
        [AllowNull()]$State,
        [Parameter(Mandatory = $true)][ValidateSet('Rollback', 'Finalize')][string]$Action,
        [Parameter(Mandatory = $true)][ValidateSet('prepared', 'firewallApplied', 'coreApplied')][string]$JournalPhase
    )
    if ($JournalPhase -eq 'prepared') {
        if ($Action -ne 'Rollback') {
            throw 'A prepared lifecycle transaction can only be recovered by rollback.'
        }
        if (-not $State) { return 'RollbackWithoutState' }
        if ([string]$State.phase -cin @('prepared', 'applying', 'applied', 'rolledBack', 'rollbackFailed')) { return 'Rollback' }
        throw 'Prepared lifecycle recovery found an incompatible helper state.'
    }
    if ($JournalPhase -eq 'firewallApplied') {
        if ($Action -ne 'Rollback') {
            throw 'A firewall-applied lifecycle transaction can only be recovered by rollback.'
        }
        if (-not $State) {
            throw 'Firewall-applied recovery requires persisted helper state.'
        }
        if ([string]$State.phase -cin @('applying', 'applied', 'rolledBack', 'rollbackFailed')) { return 'Rollback' }
        throw 'Firewall-applied lifecycle recovery found an incompatible helper state.'
    }
    if ($Action -ne 'Finalize') {
        throw 'A core-applied lifecycle transaction can only be recovered by finalize.'
    }
    if (-not $State) { throw 'Core-applied recovery requires persisted helper state.' }
    if ([string]$State.phase -cin @('rolledBack', 'rollbackFailed', 'applying')) {
        # The core transaction is already durable, so a helper that rolled its
        # firewall mutation back after timing out must re-establish the exact
        # request before it can publish the final verified receipt. "applying"
        # is included because recovery itself may crash after making its intent
        # durable and while Set-CycExactFirewallDesiredState is in flight.
        return 'ReapplyThenFinalize'
    }
    if ([string]$State.phase -cin @('applied', 'verified')) { return 'Finalize' }
    throw 'Core-applied lifecycle recovery found an incompatible helper state.'
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

function Assert-CycFirewallReceiptBinding {
    param(
        [Parameter(Mandatory = $true)]$Receipt,
        [Parameter(Mandatory = $true)]$Request,
        [Parameter(Mandatory = $true)][string]$RequestHash
    )
    Assert-CycFirewallExactProperties -Object $Receipt -Label 'Firewall receipt' -Expected @(
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
        -not [string]::Equals(
            (Resolve-CycFirewallPath ([string]$Receipt.initiatorProfile)),
            (Resolve-CycFirewallPath ([string]$Request.initiatorProfile)),
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        -not [string]::Equals(
            (Resolve-CycFirewallPath ([string]$Receipt.initiatorLocalAppData)),
            (Resolve-CycFirewallPath ([string]$Request.initiatorLocalAppData)),
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        [string]$Receipt.ruleName -cne [string]$Request.ruleName -or
        -not [string]::Equals(
            (Resolve-CycFirewallPath ([string]$Receipt.program)),
            (Resolve-CycFirewallPath ([string]$Request.program)),
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        [string]$Receipt.programSha256 -cne [string]$Request.programSha256 -or
        [int]$Receipt.port -ne [int]$Request.port -or
        [string]$Receipt.result -cnotin @('verified', 'rolledBack', 'rollbackFailed') -or
        -not $failureBindingValid -or -not $timestampValid) {
        throw 'Firewall receipt is not bound to the exact approved request.'
    }
    return $Receipt
}

function Invoke-CycFirewallElevatedTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$BoundRequestPath,
        [Parameter(Mandatory = $true)][string]$RequestHash,
        [Parameter(Mandatory = $true)][string]$HelperHash,
        [ValidateSet('Rollback', 'Finalize')][string]$RecoveryAction,
        [ValidateSet('prepared', 'firewallApplied', 'coreApplied')][string]$RecoveryJournalPhase,
        [string]$RecoveryJournalPath,
        [string]$ExpectedRecoveryJournalSha256,
        [string]$VerifiedHelperPath
    )
    $isRecovery = Assert-CycFirewallRecoveryArguments `
        -Action $RecoveryAction `
        -JournalPhase $RecoveryJournalPhase `
        -JournalPath $RecoveryJournalPath `
        -ExpectedJournalSha256 $ExpectedRecoveryJournalSha256
    if (-not (Test-CycFirewallAdministrator)) {
        throw 'The firewall helper must run elevated.'
    }
    $executingHelperPath = if ([string]::IsNullOrWhiteSpace($VerifiedHelperPath)) {
        [string]$PSCommandPath
    } else {
        $VerifiedHelperPath
    }
    if ([string]::IsNullOrWhiteSpace($executingHelperPath)) {
        throw 'The executing firewall helper path is unavailable.'
    }
    Assert-CycFirewallPlainValue -Value $executingHelperPath -Label 'VerifiedHelperPath'
    $executingHelperPath = Resolve-CycFirewallPath $executingHelperPath
    $observedHelperHash = Get-CycFirewallSha256 -Path $executingHelperPath
    $requestCapture = Read-CycFirewallDigestBoundJson `
        -Path $BoundRequestPath `
        -ExpectedSha256 $RequestHash `
        -MaximumBytes 32768 `
        -Label 'Firewall request'
    $request = $requestCapture.value
    [void](Assert-CycFirewallRequestBinding `
        -Request $request `
        -RequestFile $requestCapture.path `
        -ExpectedRequestHash $RequestHash `
        -ObservedRequestHash $requestCapture.sha256 `
        -ObservedHelperHash $observedHelperHash `
        -ExpectedHelperHash $HelperHash `
        -AllowExpiredRecovery:$isRecovery)
    Assert-CycFirewallAuthenticode `
        -Request $request `
        -HelperPath $executingHelperPath `
        -Recovery:$isRecovery

    $exchange = Resolve-CycFirewallPath ([string]$request.exchangeRoot)
    $expectedHelperPath = Resolve-CycFirewallPath (Join-Path $exchange $script:CycFirewallHelperName)
    if (-not [string]::Equals(
        $executingHelperPath,
        $expectedHelperPath,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'The executing firewall helper is not the transaction-owned exchange copy.'
    }
    if ($isRecovery) {
        $journalCapture = Read-CycFirewallDigestBoundJson `
            -Path $RecoveryJournalPath `
            -ExpectedSha256 $ExpectedRecoveryJournalSha256 `
            -MaximumBytes 65536 `
            -Label 'Firewall lifecycle journal'
        [void](Assert-CycFirewallRecoveryJournalBinding `
            -Journal $journalCapture.value `
            -JournalFile $journalCapture.path `
            -JournalHash $journalCapture.sha256 `
            -Request $request `
            -RequestFile $requestCapture.path `
            -RequestHash $RequestHash `
            -HelperFile $executingHelperPath `
            -HelperHash $HelperHash `
            -RecoveryAction $RecoveryAction `
            -RecoveryJournalPhase $RecoveryJournalPhase)
    }

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
    $terminalStateCommitted = $false
    $responseWasVisible = $false
    try {
        $stateExists = Test-Path -LiteralPath $statePath -PathType Leaf
        $boundRecoveryAction = $null
        if ($stateExists) {
            $state = Read-CycFirewallJson -Path $statePath -MaximumBytes 65536 -Label 'Firewall state'
            [void](Assert-CycFirewallStateShape -State $state)
            [void](Assert-CycFirewallReplayBinding `
                -State $state `
                -TransactionId ([string]$request.transactionId) `
                -RequestSha256 $RequestHash)
            $snapshot = $state.original
            $applied = [string]$state.phase -cin @('applying', 'applied')
            $terminalStateCommitted = [string]$state.phase -cin @('verified', 'rolledBack', 'rollbackFailed')
        } else {
            if ($isRecovery) {
                $boundRecoveryAction = Get-CycFirewallBoundRecoveryAction `
                    -State $null `
                    -Action $RecoveryAction `
                    -JournalPhase $RecoveryJournalPhase
            }
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

        if ($isRecovery) {
            if (-not $boundRecoveryAction) {
                $boundRecoveryAction = Get-CycFirewallBoundRecoveryAction `
                    -State $state `
                    -Action $RecoveryAction `
                    -JournalPhase $RecoveryJournalPhase
            }
        }

        # Recovery intent and its digest-bound lifecycle evidence are validated
        # before this replay fast path. A durable response is authoritative only
        # together with the matching terminal state; legacy response-before-state
        # windows are reconciled here before returning.
        $supersedeFailedReceipt = $false
        if (Test-Path -LiteralPath $responsePath -PathType Leaf) {
            $responseWasVisible = $true
            $existingReceipt = Read-CycFirewallJson -Path $responsePath -MaximumBytes 32768 -Label 'Firewall receipt'
            [void](Assert-CycFirewallReceiptBinding `
                -Receipt $existingReceipt `
                -Request $request `
                -RequestHash $RequestHash)
            $supersedeFailedReceipt = $isRecovery -and (
                ($RecoveryAction -eq 'Finalize' -and
                    $RecoveryJournalPhase -eq 'coreApplied' -and
                    $boundRecoveryAction -in @('ReapplyThenFinalize', 'Finalize') -and
                    [string]$existingReceipt.result -cin @('rolledBack', 'rollbackFailed')) -or
                ($RecoveryAction -eq 'Rollback' -and
                    $RecoveryJournalPhase -in @('prepared', 'firewallApplied') -and
                    $boundRecoveryAction -eq 'Rollback' -and
                    [string]$existingReceipt.result -ceq 'rollbackFailed')
            )
            if (-not $supersedeFailedReceipt) {
                $expectedExistingResult = if ($isRecovery -and $RecoveryAction -eq 'Rollback') {
                    'rolledBack'
                } else {
                    'verified'
                }
                if ([string]$existingReceipt.result -cne $expectedExistingResult) {
                    throw 'Finalized firewall transaction result does not match the requested recovery action.'
                }
                $expectedTerminalPhase = if ($expectedExistingResult -eq 'verified') { 'verified' } else { 'rolledBack' }
                if ([string]$state.phase -cne $expectedTerminalPhase) {
                    if ($expectedTerminalPhase -eq 'verified') {
                        [void](Test-CycFirewallDesiredState -Request $request -Final)
                    } elseif ($boundRecoveryAction -ne 'RollbackWithoutState') {
                        Restore-CycExactFirewallSnapshot -Request $request -Snapshot $snapshot
                        $applied = $false
                    }
                    $state.phase = $expectedTerminalPhase
                    Write-CycFirewallAtomicJson -Path $statePath -Value $state
                    $terminalStateCommitted = $true
                }
                return $existingReceipt
            }
        }

        if ($isRecovery) {
            [System.IO.File]::WriteAllText((Join-Path $exchange 'ready.signal'), '', (New-Object System.Text.UTF8Encoding($false)))
            if ($RecoveryAction -eq 'Finalize') {
                if ($boundRecoveryAction -eq 'ReapplyThenFinalize') {
                    # rolledBack is a terminal state for the previous helper,
                    # not for this digest-bound coreApplied recovery attempt.
                    # Make the new mutation intent durable before allowing the
                    # catch path to treat it as rollback-requiring.
                    $alreadyDurablyApplying = [string]$state.phase -ceq 'applying'
                    if (-not $alreadyDurablyApplying) { $applied = $false }
                    $state.phase = 'applying'
                    $state.appliedAtUtc = $null
                    Write-CycFirewallAtomicJson -Path $statePath -Value $state
                    # The old failed receipt remains on disk until the
                    # replacement is committed atomically, but after this
                    # durable reopen it no longer suppresses compensation.
                    $responseWasVisible = $false
                    $terminalStateCommitted = $false
                    $applied = $true
                    Set-CycExactFirewallDesiredState -Request $request
                    [void](Test-CycFirewallDesiredState -Request $request)
                    $state.phase = 'applied'
                    $state.appliedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
                    Write-CycFirewallAtomicJson -Path $statePath -Value $state
                } elseif ($supersedeFailedReceipt) {
                    # A previous reapply may have crashed after persisting
                    # applied/verified but before replacing its old failure
                    # receipt. Final verification now owns that replacement.
                    $responseWasVisible = $false
                }
                [void](Test-CycFirewallDesiredState -Request $request -Final)
                $state.phase = 'verified'
                Write-CycFirewallAtomicJson -Path $statePath -Value $state
                $terminalStateCommitted = $true
                $receipt = New-CycFirewallReceipt -Request $request -RequestHash $RequestHash -Result 'verified'
                Write-CycFirewallAtomicJson -Path $responsePath -Value $receipt
                return $receipt
            }
            if ($boundRecoveryAction -ne 'RollbackWithoutState') {
                if ([string]$state.phase -ceq 'rollbackFailed') {
                    # Reopen the failed compensation durably. If recovery dies
                    # during the exact snapshot restore, "applying" makes the
                    # next bound Rollback retry the idempotent restore.
                    $state.phase = 'applying'
                    $state.appliedAtUtc = $null
                    Write-CycFirewallAtomicJson -Path $statePath -Value $state
                    $terminalStateCommitted = $false
                }
                if ($supersedeFailedReceipt) {
                    # Keep the old failure receipt durable until replacement,
                    # but no longer let it suppress compensation after reopen.
                    $responseWasVisible = $false
                }
                if ([string]$state.phase -cne 'rolledBack') {
                    $applied = $true
                    Restore-CycExactFirewallSnapshot -Request $request -Snapshot $snapshot
                    $applied = $false
                }
            }
            $applied = $false
            $state.phase = 'rolledBack'
            Write-CycFirewallAtomicJson -Path $statePath -Value $state
            $terminalStateCommitted = $true
            $receipt = New-CycFirewallReceipt `
                -Request $request `
                -RequestHash $RequestHash `
                -Result 'rolledBack' `
                -FailureCode 'coordinator-cancelled-or-timed-out'
            Write-CycFirewallAtomicJson -Path $responsePath -Value $receipt
            return $receipt
        }

        [System.IO.File]::WriteAllText((Join-Path $exchange 'ready.signal'), '', (New-Object System.Text.UTF8Encoding($false)))
        $deadline = [DateTimeOffset]::Parse([string]$request.deadlineUtc)
        $applySignal = Wait-CycFirewallSignal -ExchangeRoot $exchange -Names @('rollback.signal', 'apply.signal') -Deadline $deadline
        if ($applySignal -ne 'apply.signal') {
            $state.phase = 'rolledBack'
            Write-CycFirewallAtomicJson -Path $statePath -Value $state
            $terminalStateCommitted = $true
            $receipt = New-CycFirewallReceipt -Request $request -RequestHash $RequestHash -Result 'rolledBack' -FailureCode 'cancelled-before-apply'
            Write-CycFirewallAtomicJson -Path $responsePath -Value $receipt
            return $receipt
        }

        $state.phase = 'applying'
        Write-CycFirewallAtomicJson -Path $statePath -Value $state
        # Treat the mutation as rollback-requiring before entering the cmdlet;
        # a partially successful Set operation must not escape recovery.
        $applied = $true
        Set-CycExactFirewallDesiredState -Request $request
        [void](Test-CycFirewallDesiredState -Request $request)
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
            $state.phase = 'verified'
            Write-CycFirewallAtomicJson -Path $statePath -Value $state
            $terminalStateCommitted = $true
            $receipt = New-CycFirewallReceipt -Request $request -RequestHash $RequestHash -Result 'verified'
            Write-CycFirewallAtomicJson -Path $responsePath -Value $receipt
            return $receipt
        }

        Restore-CycExactFirewallSnapshot -Request $request -Snapshot $snapshot
        $applied = $false
        $state.phase = 'rolledBack'
        Write-CycFirewallAtomicJson -Path $statePath -Value $state
        $terminalStateCommitted = $true
        $receipt = New-CycFirewallReceipt -Request $request -RequestHash $RequestHash -Result 'rolledBack' -FailureCode 'coordinator-cancelled-or-timed-out'
        Write-CycFirewallAtomicJson -Path $responsePath -Value $receipt
        return $receipt
    } catch {
        $failure = $_
        if (-not $responseWasVisible -and -not $terminalStateCommitted -and $applied -and $snapshot) {
            try {
                Restore-CycExactFirewallSnapshot -Request $request -Snapshot $snapshot
            } catch {
                $state.phase = 'rollbackFailed'
                try {
                    Write-CycFirewallAtomicJson -Path $statePath -Value $state
                    $terminalStateCommitted = $true
                    $receipt = New-CycFirewallReceipt -Request $request -RequestHash $RequestHash -Result 'rollbackFailed' -FailureCode 'helper-and-rollback-failure'
                    Write-CycFirewallAtomicJson -Path $responsePath -Value $receipt
                } catch { }
                throw "Firewall helper failed and rollback failed closed. Original failure: $($failure.Exception.Message)"
            }
            $applied = $false
            $state.phase = 'rolledBack'
            Write-CycFirewallAtomicJson -Path $statePath -Value $state
            $terminalStateCommitted = $true
            $receipt = New-CycFirewallReceipt -Request $request -RequestHash $RequestHash -Result 'rolledBack' -FailureCode 'helper-failure'
            Write-CycFirewallAtomicJson -Path $responsePath -Value $receipt
        }
        throw $failure
    } finally {
        if ($lock) { $lock.Dispose() }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $transactionArguments = @{
            BoundRequestPath = $RequestPath
            RequestHash      = $ExpectedRequestSha256
            HelperHash       = $ExpectedHelperSha256
        }
        $hasAnyRecoveryArgument = -not (
            [string]::IsNullOrWhiteSpace($RecoveryAction) -and
            [string]::IsNullOrWhiteSpace($RecoveryJournalPhase) -and
            [string]::IsNullOrWhiteSpace($RecoveryJournalPath) -and
            [string]::IsNullOrWhiteSpace($ExpectedRecoveryJournalSha256)
        )
        if ($hasAnyRecoveryArgument) {
            $transactionArguments.RecoveryAction = $RecoveryAction
            $transactionArguments.RecoveryJournalPhase = $RecoveryJournalPhase
            $transactionArguments.RecoveryJournalPath = $RecoveryJournalPath
            $transactionArguments.ExpectedRecoveryJournalSha256 = $ExpectedRecoveryJournalSha256
        }
        if (-not [string]::IsNullOrWhiteSpace($VerifiedHelperPath)) {
            $transactionArguments.VerifiedHelperPath = $VerifiedHelperPath
        }
        $result = Invoke-CycFirewallElevatedTransaction @transactionArguments
        if ([string]$result.result -ceq 'verified' -or
            (-not [string]::IsNullOrWhiteSpace($RecoveryAction) -and
                [string]$result.result -ceq 'rolledBack')) { exit 0 }
        exit 2
    } catch {
        [Console]::Error.WriteLine(([string]$_.Exception.Message).Replace("`r", ' ').Replace("`n", ' '))
        exit 1
    }
}
