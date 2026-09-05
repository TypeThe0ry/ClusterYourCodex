#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [string]$WorkRoot = (Join-Path ([System.IO.Path]::GetTempPath()) ('clusteryourcodex-profile-matrix-' + [Guid]::NewGuid().ToString('N'))),

    [string[]]$CaseName = @('standard-ascii', 'administrator-ascii', 'standard-non-ascii', 'administrator-non-ascii'),

    [switch]$KeepWorkRoot,

    # A non-elevated local smoke runs only the effective current-user case.
    # The full four-case matrix still requires an elevated controller so it can
    # create and remove disposable local accounts.
    [switch]$CurrentUserOnly,

    # CI uses this as a fail-closed gate instead of relying only on the caller's
    # job naming or runner label.
    [switch]$RequireWindows11,

    # A disposable profile child must never be allowed to strand the elevated
    # controller.  The parent keeps the helper IPC loop and child lifetime
    # bounded, then kills the complete child process tree on timeout.
    [ValidateRange(60, 2400)]
    [int]$ChildTimeoutSeconds = 900
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# PowerShell treats a comma-separated value passed after a [string[]]
# parameter as one string when the script is launched from a command line.
# Accept both repeated/array values and the documented comma-separated form,
# then validate the normalized cases explicitly so callers get the same strict
# allow-list without a surprising parameter-binding failure.
$allowedCaseNames = @(
    'standard-ascii'
    'administrator-ascii'
    'standard-non-ascii'
    'administrator-non-ascii'
)
$normalizedCaseNames = New-Object System.Collections.Generic.List[string]
foreach ($rawCaseName in @($CaseName)) {
    foreach ($candidate in ([string]$rawCaseName -split ',')) {
        $trimmed = $candidate.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if ($allowedCaseNames -notcontains $trimmed) {
            throw "CaseName must be one of: $($allowedCaseNames -join ', '); got '$trimmed'."
        }
        [void]$normalizedCaseNames.Add($trimmed)
    }
}
if ($normalizedCaseNames.Count -eq 0) {
    throw 'CaseName must contain at least one profile-matrix case.'
}
$CaseName = @($normalizedCaseNames)

function Assert-ProfileMatrix {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw "Windows profile matrix assertion failed: $Message"
    }
}

# Windows PowerShell 5.1 decodes BOM-less files with the active ANSI code
# page when Get-Content is used.  Profile-matrix IPC is deliberately emitted
# as strict UTF-8 without a BOM, so read every JSON boundary explicitly with
# a strict UTF-8 decoder before ConvertFrom-Json.  This keeps Unicode account
# names and profile paths intact on ARM64/x64-emulation runners.
function Read-ProfileMatrixUtf8Json {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
    $raw = $utf8Strict.GetString($bytes)
    if ($raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF) {
        $raw = $raw.Substring(1)
    }
    $converter = Get-Command ConvertFrom-Json -CommandType Cmdlet -ErrorAction Stop
    if ($converter.Parameters.ContainsKey('DateKind')) {
        return ConvertFrom-Json -InputObject $raw -DateKind String
    }
    return ConvertFrom-Json -InputObject $raw
}

function Resolve-ProfileMatrixPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Normalize-ProfileMatrixLinkTarget {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)]$Value
    )

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $text = $text.Trim().Trim([char]0).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    # Windows may expose a junction target through the NT namespace rather
    # than the Win32 namespace. Normalize only the well-known wrappers; do
    # not accept arbitrary device paths or UNC targets for this allow-list.
    $hadNamespacePrefix = $false
    foreach ($prefix in @('\??\', '\DosDevices\', '\\?\', '\\.\')) {
        if ($text.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $text = $text.Substring($prefix.Length)
            $hadNamespacePrefix = $true
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($text) -or $text.StartsWith('\', [System.StringComparison]::Ordinal)) {
        return $null
    }
    # A namespace-wrapped target is only accepted when it resolves to a local
    # drive path. Reject volume/device/GLOBALROOT/UNC forms before the normal
    # relative-path handling; otherwise a value such as \??\Volume{...} could
    # be misinterpreted as a path beneath the profile root.
    if ($hadNamespacePrefix -and $text -notmatch '^[A-Za-z]:[\\/]') {
        return $null
    }
    if ($text -match '^(?i:GLOBALROOT[\\/]|Device[\\/]|Volume\{|UNC[\\/])') {
        return $null
    }
    if (-not [System.IO.Path]::IsPathRooted($text)) {
        $text = Join-Path $BasePath $text
    }
    try {
        return Resolve-ProfileMatrixPath $text
    } catch {
        return $null
    }
}

function Get-ProfileMatrixLinkTargets {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileSystemInfo]$Item,
        [Parameter(Mandatory = $true)][string]$BasePath,
        [ref]$Invalid
    )

    if ($null -ne $Invalid) { $Invalid.Value = $false }
    $observed = New-Object System.Collections.Generic.List[string]
    foreach ($propertyName in @('Target', 'ResolvedTarget', 'LinkTarget')) {
        try {
            $property = $Item.PSObject.Properties[$propertyName]
            if ($null -eq $property -or $null -eq $property.Value) { continue }
            foreach ($rawValue in @($property.Value)) {
                if ($null -eq $rawValue) { continue }
                $candidate = $rawValue
                # A provider can expose a link target as a FileSystemInfo object;
                # prefer its full path over the object's formatted ToString().
                $fullNameProperty = $candidate.PSObject.Properties['FullName']
                if ($null -ne $fullNameProperty -and -not [string]::IsNullOrWhiteSpace([string]$fullNameProperty.Value)) {
                    $candidate = $fullNameProperty.Value
                }
                $normalized = Normalize-ProfileMatrixLinkTarget -BasePath $BasePath -Value $candidate
                # A present but malformed projection is evidence against the
                # allow-list. Do not silently discard GLOBALROOT/UNC/device or
                # an otherwise ambiguous provider value just because another
                # projection happened to look valid.
                if ($null -eq $normalized) {
                    if ($null -ne $Invalid) { $Invalid.Value = $true }
                    continue
                }
                [void]$observed.Add($normalized)
            }
        } catch {
            if ($null -ne $Invalid) { $Invalid.Value = $true }
        }
    }
    return @($observed | Sort-Object -Unique)
}

function ConvertFrom-ProfileMatrixFsutilReparseOutput {
    <#
    Windows PowerShell 5.1 (including the x64 emulation host on Windows 11
    ARM64) does not project the FileSystemInfo LinkType/Target properties for
    the compatibility junctions that Windows creates in a new profile.  Keep
    the parser separate from the fsutil process invocation so its rules stay
    deterministic and can be exercised with a captured fsutil transcript.

    The parser deliberately accepts only a single mount-point tag and a
    single NT/Win32 path wrapper.  A missing/ambiguous tag or target is an
    unknown reparse point, not an allow-list match.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory = $true)][string]$BasePath
    )

    $text = [string]::Join([Environment]::NewLine, @($Lines | ForEach-Object { [string]$_ }))
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    # fsutil's labels are localized, but the tag is emitted as a hexadecimal
    # value. Restrict the match to a line that contains the word "tag" rather
    # than accepting an arbitrary 0x... value from the reparse data dump.
    $tagMatches = [regex]::Matches(
        $text,
        '(?im)^\s*[^:\r\n]*\btag\b[^:\r\n]*:\s*0x(?<tag>[0-9a-f]+)\b'
    )
    if ($tagMatches.Count -ne 1) { return $null }
    $tag = $tagMatches[0].Groups['tag'].Value.ToLowerInvariant()
    # IO_REPARSE_TAG_MOUNT_POINT (name-surrogate junction) is 0xA0000003.
    if ($tag -cne 'a0000003') { return $null }

    # Do not depend on the localized "Substitute Name"/"Print Name" labels.
    # The NT/Win32 wrappers are stable and occur only for the path fields in
    # fsutil output. Collect every wrapped path and require all observations to
    # normalize to one exact target.
    $targetMatches = [regex]::Matches(
        $text,
        '(?im)(?<target>(?:\\\?\?\\|\\DosDevices\\|\\\\\?\\|\\\\\.\\)[^\r\n]+)'
    )
    if ($targetMatches.Count -eq 0) { return $null }
    $targets = New-Object System.Collections.Generic.List[string]
    foreach ($match in $targetMatches) {
        $rawTarget = [string]$match.Groups['target'].Value.Trim()
        $normalized = Normalize-ProfileMatrixLinkTarget -BasePath $BasePath -Value $rawTarget
        if ($null -eq $normalized) { return $null }
        [void]$targets.Add($normalized)
    }
    $uniqueTargets = @($targets | Sort-Object -Unique)
    if ($uniqueTargets.Count -ne 1) { return $null }

    return [PSCustomObject]@{
        tag = $tag
        target = [string]$uniqueTargets[0]
        source = 'fsutil'
    }
}

function Get-ProfileMatrixNativeReparseInfo {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BasePath
    )

    $fsutil = Join-Path $env:SystemRoot 'System32\fsutil.exe'
    if (-not (Test-Path -LiteralPath $fsutil -PathType Leaf)) { return $null }
    try {
        # fsutil inserts a blank separator line; filter it before binding the
        # strict string-array parser (PS5.1 rejects an empty scalar argument).
        $lines = @(& $fsutil reparsepoint query $Path 2>&1 |
            ForEach-Object { [string]$_ } |
            Where-Object { $_.Length -gt 0 })
        $exitCode = $LASTEXITCODE
    } catch {
        return $null
    }
    if ($exitCode -ne 0) { return $null }
    return ConvertFrom-ProfileMatrixFsutilReparseOutput -Lines $lines -BasePath $BasePath
}

function Test-ProfileMatrixKnownCompatibilityJunction {
    param(
        [Parameter(Mandatory = $true)][string]$ProfileRoot,
        [Parameter(Mandatory = $true)][System.IO.FileSystemInfo]$Item
    )

    # A fresh Windows profile contains legacy-compatibility junctions such as
    # "Application Data" and the Documents\My * links. They are created by
    # the OS, not by the package under test. Keep the exception narrow: only
    # an explicitly named path below a real C:\Users\<name> profile root, and
    # only when its target is the exact in-profile destination we expect.
    $usersRoot = Resolve-ProfileMatrixPath (Join-Path $env:SystemDrive 'Users')
    $resolvedProfileRoot = Resolve-ProfileMatrixPath $ProfileRoot
    if (-not [string]::Equals((Split-Path -Parent $resolvedProfileRoot), $usersRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    if (-not ([string]$Item.FullName).StartsWith($resolvedProfileRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    $knownTargets = @{
        'Application Data' = 'AppData\Roaming'
        'Cookies' = 'AppData\Local\Microsoft\Windows\INetCookies'
        # Windows 11 may materialize the legacy History alias under Local.
        # It is an OS-created compatibility junction, not package content;
        # bind it to the exact same-profile destination before cleanup.
        'AppData\Local\History' = 'AppData\Local\Microsoft\Windows\History'
        'Local Settings' = 'AppData\Local'
        'My Documents' = 'Documents'
        'NetHood' = 'AppData\Roaming\Microsoft\Windows\Network Shortcuts'
        'PrintHood' = 'AppData\Roaming\Microsoft\Windows\Printer Shortcuts'
        'Recent' = 'AppData\Roaming\Microsoft\Windows\Recent'
        'SendTo' = 'AppData\Roaming\Microsoft\Windows\SendTo'
        'Start Menu' = 'AppData\Roaming\Microsoft\Windows\Start Menu'
        'Templates' = 'AppData\Roaming\Microsoft\Windows\Templates'
        'Documents\My Music' = 'Music'
        'Documents\My Pictures' = 'Pictures'
        'Documents\My Videos' = 'Videos'
        # Windows also materializes the legacy Application Data alias inside
        # the per-user local profile roots. These are compatibility junctions
        # created by the OS, not package content; keep the paths explicit and
        # bind each target back to the same profile root.
        'AppData\Local\Application Data' = 'AppData\Local'
        'AppData\LocalLow\Application Data' = 'AppData\LocalLow'
        'AppData\Roaming\Application Data' = 'AppData\Roaming'
    }
    $relativeSource = ([string]$Item.FullName).Substring($resolvedProfileRoot.Length).TrimStart([char[]]@('\', '/'))
    if (-not $knownTargets.ContainsKey($relativeSource)) { return $false }
    $linkTypeProperty = $Item.PSObject.Properties['LinkType']
    # Windows PowerShell 5.1 has no LinkType projection. If the property is
    # present, keep the old strict check; if it is absent/blank, the native
    # fsutil fallback below is the authoritative type check.
    if ($null -ne $linkTypeProperty -and
        -not [string]::IsNullOrWhiteSpace([string]$linkTypeProperty.Value) -and
        -not [string]::Equals([string]$linkTypeProperty.Value, 'Junction', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    $expectedTarget = Resolve-ProfileMatrixPath (Join-Path $resolvedProfileRoot $knownTargets[$relativeSource])
    $basePath = Split-Path -Parent ([string]$Item.FullName)
    $invalidTargetProjection = $false
    $targets = @(Get-ProfileMatrixLinkTargets -Item $Item -BasePath $basePath -Invalid ([ref]$invalidTargetProjection))
    if ($invalidTargetProjection -or $targets.Count -gt 1) {
        return $false
    }
    if ($targets.Count -eq 1) {
        # A projected target is useful on PowerShell 7, but still require a
        # native mount-point tag whenever fsutil is available. This prevents a
        # provider-supplied Target property from widening the exception to an
        # arbitrary reparse type.
        $native = Get-ProfileMatrixNativeReparseInfo -Path ([string]$Item.FullName) -BasePath $basePath
        if ($null -eq $native) { return $false }
        return [string]::Equals([string]$targets[0], $expectedTarget, [System.StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals([string]$native.target, $expectedTarget, [System.StringComparison]::OrdinalIgnoreCase)
    }

    # PS5.1's missing projections land here. Native output must independently
    # prove both the mount-point tag and the exact in-profile destination.
    $fallback = Get-ProfileMatrixNativeReparseInfo -Path ([string]$Item.FullName) -BasePath $basePath
    if ($null -eq $fallback) { return $false }
    return [string]::Equals([string]$fallback.target, $expectedTarget, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-ProfileMatrixReparseFree {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [switch]$AllowKnownCompatibilityJunctions
    )
    $resolved = Resolve-ProfileMatrixPath $Root
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) { return }
    $rootItem = Get-Item -LiteralPath $resolved -Force
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "profile matrix refuses a reparse point: $resolved"
    }

    # Walk regular directories ourselves instead of using -Recurse. This
    # guarantees that an allowed OS compatibility junction is not traversed
    # into, while every unexpected reparse point still fails closed before any
    # caller can recursively delete or copy the tree.
    $pending = New-Object System.Collections.Generic.Stack[string]
    $pending.Push($resolved)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $current -Force)) {
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                if ($AllowKnownCompatibilityJunctions -and
                    (Test-ProfileMatrixKnownCompatibilityJunction -ProfileRoot $resolved -Item $item)) {
                    continue
                }
                throw "profile matrix refuses a reparse point: $($item.FullName)"
            }
            if ($item.PSIsContainer) {
                $pending.Push([string]$item.FullName)
            }
        }
    }
}

function Add-ProfileMatrixUsersModify {
    param([Parameter(Mandatory = $true)][string]$Path)
    $acl = Get-Acl -LiteralPath $Path
    $users = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        $users,
        [System.Security.AccessControl.FileSystemRights]::Modify,
        [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
            [System.Security.AccessControl.InheritanceFlags]::ObjectInherit,
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    [void]$acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-ProfileMatrixAdminGroupName {
    return ([System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')).Translate(
        [System.Security.Principal.NTAccount]
    ).Value.Split('\')[-1]
}

function Resolve-ProfileMatrixAccountName {
    param(
        [Parameter(Mandatory = $true)][string]$Sid,
        [string]$FallbackUserName
    )

    function Test-AccountNameSidBinding {
        param(
            [string]$AccountName,
            [string]$ExpectedSid
        )
        if ([string]::IsNullOrWhiteSpace($AccountName)) { return $false }
        try {
            $observedSid = ([System.Security.Principal.NTAccount]::new($AccountName)).Translate(
                [System.Security.Principal.SecurityIdentifier]
            ).Value
            return [string]$observedSid -ceq $ExpectedSid
        } catch {
            return $false
        }
    }

    # A freshly-created local profile's directory name is returned by the
    # SID-bound ProfileList registry value without the lossy WMI account-name
    # projection.  Prefer that leaf when it round-trips to the expected SID;
    # this also covers ARM64/x64 LocalAccounts builds that mojibake
    # NTAccount.Translate results while the SAM entry is still converging.
    try {
        $profilePath = Get-ProfileMatrixProfilePathForSid -Sid $Sid
        $profileLeaf = Split-Path -Leaf $profilePath
        if (-not [string]::IsNullOrWhiteSpace($profileLeaf)) {
            $profileAccount = '{0}\{1}' -f $env:COMPUTERNAME, $profileLeaf
            if (Test-AccountNameSidBinding -AccountName $profileAccount -ExpectedSid $Sid) {
                return $profileAccount
            }
        }
    } catch { }

    # WindowsIdentity.Name is a display projection and can be mojibaked for
    # non-ASCII local accounts under the ARM64/x64 PowerShell combination.
    # Resolve the scheduler credential from the immutable SID instead. The
    # WMI fallback covers LocalAccounts projections that cannot translate a
    # freshly-created SID during the short SAM propagation window.
    try {
        $translated = ([System.Security.Principal.SecurityIdentifier]::new($Sid)).Translate(
            [System.Security.Principal.NTAccount]
        ).Value
        if (Test-AccountNameSidBinding -AccountName ([string]$translated) -ExpectedSid $Sid) {
            return [string]$translated
        }
    } catch { }
    try {
        $account = Get-CimInstance -ClassName Win32_UserAccount -Filter ("SID='{0}'" -f $Sid) -ErrorAction Stop |
            Select-Object -First 1
        if ($null -ne $account -and
            -not [string]::IsNullOrWhiteSpace([string]$account.Domain) -and
            -not [string]::IsNullOrWhiteSpace([string]$account.Name)) {
            $cimAccount = '{0}\{1}' -f [string]$account.Domain, [string]$account.Name
            if (Test-AccountNameSidBinding -AccountName $cimAccount -ExpectedSid $Sid) {
                return $cimAccount
            }
        }
    } catch { }
    if (-not [string]::IsNullOrWhiteSpace($FallbackUserName)) {
        $fallbackAccount = '{0}\{1}' -f $env:COMPUTERNAME, $FallbackUserName
        if (Test-AccountNameSidBinding -AccountName $fallbackAccount -ExpectedSid $Sid) {
            return $fallbackAccount
        }
    }
    throw "profile matrix could not resolve account name for SID $Sid."
}

function ConvertTo-ProfileMatrixSecureString {
    $plain = 'Cyc-' + [Guid]::NewGuid().ToString('N') + '-Aa9!'
    return ConvertTo-SecureString -String $plain -AsPlainText -Force
}

function ConvertTo-ProfileMatrixArgument {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Write-ProfileMatrixAtomicJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )
    $directory = Split-Path -Parent $Path
    [void](New-Item -ItemType Directory -Path $directory -Force)
    $leaf = Split-Path -Leaf $Path
    $temporary = Join-Path $directory ($leaf + '.tmp-' + [Guid]::NewGuid().ToString('N'))
    # Windows PowerShell/.NET Framework requires a real, same-volume backup
    # path for File.Replace; a null or merely planned (nonexistent) path can
    # abort the helper before it emits its response. Keep the backup sibling
    # unique and remove it after a successful atomic commit.
    $backup = Join-Path $directory ($leaf + '.bak-' + [Guid]::NewGuid().ToString('N'))
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $bytes = $utf8.GetBytes(($Value | ConvertTo-Json -Depth 12))
    $stream = $null
    $backupCreated = $false
    $backupPrepared = $false
    $committed = $false
    try {
        $stream = [System.IO.FileStream]::new(
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

        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            # Windows PowerShell/.NET Framework requires the backup operand of
            # File.Replace to already be a same-volume regular file.  Passing
            # a merely planned path produces the misleading "path is not of a
            # legal form" ArgumentException after all earlier checks passed.
            $backupStream = [System.IO.FileStream]::new(
                $backup,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None,
                1,
                [System.IO.FileOptions]::WriteThrough
            )
            $backupCreated = $true
            try { $backupStream.Flush($true) } finally { $backupStream.Dispose() }
            $backupPrepared = $true
            # The child reads the previous response/evidence file with the
            # default FileShare.Read flags.  On Windows ARM64 x64 emulation
            # the read handle can remain open for a short interval after the
            # JSON parser returns, so File.Replace may report a sharing
            # violation even though the protocol is otherwise healthy.  Keep
            # the replace atomic, but retry only the two Win32 lock HRESULTs
            # (or their localized equivalent) with a bounded backoff.  Any
            # other error, or a lock that outlives the bound, remains a hard
            # failure and cannot be hidden by this compatibility path.
            $replaceCommitted = $false
            $replaceAttempts = 40
            for ($replaceAttempt = 0; $replaceAttempt -lt $replaceAttempts; $replaceAttempt++) {
                try {
                    [System.IO.File]::Replace($temporary, $Path, $backup, $true)
                    $replaceCommitted = $true
                    break
                } catch {
                    $sharingViolation = $false
                    $exception = $_.Exception
                    while ($null -ne $exception) {
                        $hresult = 0L
                        try { $hresult = [int64]$exception.HResult } catch { }
                        $message = [string]$exception.Message
                        if ($hresult -eq -2147024864 -or $hresult -eq -2147024863 -or
                            $hresult -eq 32 -or $hresult -eq 33 -or
                            $message -match '(?i)used by another process|sharing violation|lock violation') {
                            $sharingViolation = $true
                            break
                        }
                        $exception = $exception.InnerException
                    }
                    if (-not $sharingViolation -or $replaceAttempt -ge ($replaceAttempts - 1)) {
                        throw
                    }
                    Start-Sleep -Milliseconds ([Math]::Min(250, 25 * ($replaceAttempt + 1)))
                }
            }
            if (-not $replaceCommitted) {
                throw "profile matrix atomic replacement did not commit after $replaceAttempts attempts."
            }
        } else {
            [System.IO.File]::Move($temporary, $Path)
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
            if (($committed -or $backupCreated -or $backupPrepared) -and (Test-Path -LiteralPath $backup)) {
                Remove-Item -LiteralPath $backup -Force
            }
        } catch { }
    }
}

function Get-ProfileMatrixTaskRequestProperty {
    param(
        [Parameter(Mandatory = $true)]$Request,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $property = $Request.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        throw "profile-matrix task request is missing '$Name'."
    }
    return $property.Value
}

function Get-ProfileMatrixProfilePathForSid {
    param([Parameter(Mandatory = $true)][string]$Sid)
    # Win32_UserProfile.LocalPath is a display projection.  On the hosted
    # Windows ARM64 runner, the x64 WMI provider can decode a non-ASCII local
    # profile through the active ANSI code page more than once, producing a
    # different (mojibaked) path from the one visible to the child token.  The
    # ProfileList registry value is the canonical UTF-16 source for this
    # SID-bound path, so prefer it and only use CIM as a compatibility fallback.
    $normalizedSid = ([System.Security.Principal.SecurityIdentifier]::new($Sid)).Value
    $registryError = $null
    $cimError = $null
    $profileKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\' + $normalizedSid
    try {
        $record = Get-ItemProperty -LiteralPath $profileKey -ErrorAction Stop
        $rawPath = [string]$record.ProfileImagePath
        if (-not [string]::IsNullOrWhiteSpace($rawPath)) {
            $expanded = [Environment]::ExpandEnvironmentVariables($rawPath)
            $resolved = Resolve-ProfileMatrixPath $expanded
            $base = Resolve-ProfileMatrixPath (Join-Path $env:SystemDrive 'Users')
            if ([string]::Equals((Split-Path -Parent $resolved), $base, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $resolved
            }
            throw "profile-matrix registry profile path is outside the Users root: $resolved"
        }
    } catch {
        $registryError = [string]$_.Exception.Message
    }

    try {
        $profile = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop |
            Where-Object { [string]$_.SID -ceq $normalizedSid } |
            Select-Object -First 1
        if ($null -ne $profile -and -not [string]::IsNullOrWhiteSpace([string]$profile.LocalPath)) {
            $resolvedCimPath = Resolve-ProfileMatrixPath ([string]$profile.LocalPath)
            $base = Resolve-ProfileMatrixPath (Join-Path $env:SystemDrive 'Users')
            if ([string]::Equals((Split-Path -Parent $resolvedCimPath), $base, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $resolvedCimPath
            }
            throw "profile-matrix CIM profile path is outside the Users root: $resolvedCimPath"
        }
    } catch {
        $cimError = [string]$_.Exception.Message
    }
    $detail = if ($registryError -or $cimError) {
        " registry=$registryError cim=$cimError"
    } else { '' }
    throw "profile-matrix task helper could not resolve profile path for SID $normalizedSid.$detail"
}

function Assert-ProfileMatrixTaskAction {
    param(
        [Parameter(Mandatory = $true)]$Request,
        [Parameter(Mandatory = $true)][string]$Sid,
        [Parameter(Mandatory = $true)][string]$UserName
    )
    $action = Get-ProfileMatrixTaskRequestProperty -Request $Request -Name 'action'
    $executable = Resolve-ProfileMatrixPath ([string](Get-ProfileMatrixTaskRequestProperty -Request $action -Name 'executable'))
    $arguments = [string](Get-ProfileMatrixTaskRequestProperty -Request $action -Name 'arguments')
    $workingDirectory = Resolve-ProfileMatrixPath ([string](Get-ProfileMatrixTaskRequestProperty -Request $action -Name 'workingDirectory'))
    if ($arguments.Contains("`r") -or $arguments.Contains("`n") -or $executable.Contains('"')) {
        throw 'profile-matrix task helper rejected quoted or multiline action data.'
    }
    $profileRoot = Get-ProfileMatrixProfilePathForSid -Sid $Sid
    $localAppData = Resolve-ProfileMatrixPath (Join-Path $profileRoot 'AppData\Local')
    $programRoot = Split-Path -Parent $executable
    $leaf = Split-Path -Leaf $executable
    if (-not $executable.StartsWith($localAppData + '\ClusterYourCodex-fresh-', [System.StringComparison]::OrdinalIgnoreCase) -or
        $executable -notmatch '(?i)\\ClusterYourCodex-fresh-[0-9a-f]{32}\\program\\cyc-(controller|worker)\.exe$' -or
        $workingDirectory -notmatch '(?i)\\ClusterYourCodex-fresh-[0-9a-f]{32}\\program$' -or
        -not [string]::Equals($workingDirectory, $programRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "profile-matrix task helper rejected action outside the disposable profile install root: $executable"
    }
    $expectedLeaf = if ([string]$Request.taskName -ceq 'ClusterYourCodex Controller') { 'cyc-controller.exe' } else { 'cyc-worker.exe' }
    if ([string]$leaf -cne $expectedLeaf) {
        throw "profile-matrix task helper rejected $($Request.taskName) action $leaf."
    }
    foreach ($path in @($executable, $programRoot)) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "profile-matrix task helper rejected a reparse-point action path: $path"
        }
    }
    return [PSCustomObject]@{
        executable = $executable
        arguments = $arguments
        workingDirectory = $workingDirectory
    }
}

function Assert-ProfileMatrixTaskSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Request,
        [Parameter(Mandatory = $true)][string]$Sid,
        [Parameter(Mandatory = $true)][string]$UserName
    )

    $snapshot = Get-ProfileMatrixTaskRequestProperty -Request $Request -Name 'snapshot'
    if (($snapshot -is [System.Array]) -or $snapshot -isnot [pscustomobject]) {
        throw 'profile-matrix task helper rejected a non-object task snapshot.'
    }
    $schemaProperty = $snapshot.PSObject.Properties['schemaVersion']
    if ($null -eq $schemaProperty -or [string]$schemaProperty.Value -cne 'cyc.dev/windows-profile-matrix-task-snapshot/v1') {
        throw 'profile-matrix task helper rejected an unknown task snapshot schema.'
    }
    if ($null -ne $snapshot.PSObject.Properties['xml']) {
        throw 'profile-matrix task helper rejects raw XML in a restore request.'
    }
    $name = [string](Get-ProfileMatrixTaskRequestProperty -Request $snapshot -Name 'name')
    if ($name -cne [string]$Request.taskName) {
        throw 'profile-matrix task helper rejected a snapshot for a different task.'
    }
    $taskPath = [string](Get-ProfileMatrixTaskRequestProperty -Request $snapshot -Name 'taskPath')
    if ($taskPath -cne '\') {
        throw "profile-matrix task helper rejected a snapshot outside the root task path: $taskPath"
    }
    $principalSid = ConvertTo-ProfileMatrixSid ([string](Get-ProfileMatrixTaskRequestProperty -Request $snapshot -Name 'principalSid'))
    if ($principalSid -cne $Sid) {
        throw 'profile-matrix task helper rejected a snapshot with a different principal SID.'
    }
    $triggerSidsValue = Get-ProfileMatrixTaskRequestProperty -Request $snapshot -Name 'triggerSids'
    if ($triggerSidsValue -isnot [System.Array] -or @($triggerSidsValue).Count -ne 1) {
        throw 'profile-matrix task helper requires exactly one snapshot logon trigger SID.'
    }
    $triggerSids = @($triggerSidsValue | ForEach-Object {
            ConvertTo-ProfileMatrixSid ([string]$_)
        })
    if ($triggerSids[0] -cne $Sid) {
        throw 'profile-matrix task helper rejected a snapshot with a different trigger SID.'
    }
    $runningProperty = $snapshot.PSObject.Properties['wasRunning']
    if ($null -eq $runningProperty -or $runningProperty.Value -isnot [bool]) {
        throw 'profile-matrix task helper requires wasRunning to be a JSON boolean.'
    }
    if ([bool]$runningProperty.Value) {
        throw 'profile-matrix registration-only rollback cannot restore a running task.'
    }
    $snapshotAction = Get-ProfileMatrixTaskRequestProperty -Request $snapshot -Name 'action'
    $actionRequest = [pscustomobject]@{
        taskName = [string]$Request.taskName
        action = $snapshotAction
    }
    $action = Assert-ProfileMatrixTaskAction -Request $actionRequest -Sid $Sid -UserName $UserName
    return [PSCustomObject]@{
        name = $name
        taskPath = $taskPath
        principalSid = $principalSid
        triggerSids = $triggerSids
        action = $action
        wasRunning = [bool]$runningProperty.Value
    }
}

function ConvertTo-ProfileMatrixSid {
    param([Parameter(Mandatory = $true)][string]$Identity)

    $value = $Identity.Trim()
    if ($value -match '^S-\d-\d+(?:-\d+)+$') { return $value }
    try {
        return ([System.Security.Principal.NTAccount]::new($value)).Translate(
            [System.Security.Principal.SecurityIdentifier]
        ).Value
    } catch {
        throw "profile-matrix task helper could not resolve task identity '$Identity' to a SID."
    }
}

function Get-ProfileMatrixLocalPrincipalSid {
    param([Parameter(Mandatory = $true)]$Principal)

    # Microsoft.PowerShell.LocalAccounts returns LocalPrincipal objects on
    # Windows PowerShell 5.1 and a slightly different projection on the
    # ARM64 PowerShell host. Prefer the native SID property, then resolve the
    # displayed account name as a deterministic fallback. Never compare
    # localized names when the security identifier is available.
    $sidProperty = $Principal.PSObject.Properties['SID']
    if ($null -ne $sidProperty -and $null -ne $sidProperty.Value) {
        $rawSid = $sidProperty.Value
        if ($rawSid -is [System.Security.Principal.SecurityIdentifier]) {
            return $rawSid.Value
        }
        $sidText = ([string]$rawSid).Trim()
        if ($sidText -match '^S-\d-\d+(?:-\d+)+$') {
            return $sidText
        }
    }
    $nameProperty = $Principal.PSObject.Properties['Name']
    if ($null -ne $nameProperty -and -not [string]::IsNullOrWhiteSpace([string]$nameProperty.Value)) {
        try {
            return ([System.Security.Principal.NTAccount]::new([string]$nameProperty.Value)).Translate(
                [System.Security.Principal.SecurityIdentifier]
            ).Value
        } catch {
            # An unresolved member is evidence against the expected
            # membership; the caller records it and keeps polling.
        }
    }
    return $null
}

function Wait-ProfileMatrixAdminMembership {
    param(
        [Parameter(Mandatory = $true)][string]$GroupName,
        [Parameter(Mandatory = $true)][string]$MemberSid,
        [Parameter(Mandatory = $true)][string]$MemberName,
        [Parameter(Mandatory = $true)][string]$EvidencePath
    )

    $groupSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $startedAt = [DateTimeOffset]::UtcNow
    $observedSids = @()
    $observedNames = @()
    $lastError = $null
    $stableMatches = 0
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        try {
            # Query the group by its well-known SID so localized group names
            # and x64-emulated LocalAccounts projections cannot change the
            # meaning of this acceptance check.
            $members = @(Get-LocalGroupMember -SID $groupSid -ErrorAction Stop)
            $observedSids = @(
                $members |
                    ForEach-Object { Get-ProfileMatrixLocalPrincipalSid -Principal $_ } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                    Sort-Object -Unique
            )
            $observedNames = @(
                $members |
                    ForEach-Object { [string]$_.Name } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    Sort-Object -Unique
            )
            if (@($observedSids | Where-Object { $_ -ceq $MemberSid }).Count -gt 0) {
                $stableMatches++
            } else {
                $stableMatches = 0
            }
            # Require two consecutive observations. This closes the small SAM
            # propagation window seen when a disposable account is added to
            # Administrators immediately before LogonUser/Start-Process.
            if ($stableMatches -ge 2) {
                $endedAt = [DateTimeOffset]::UtcNow
                $record = [ordered]@{
                    schemaVersion = 'cyc.dev/windows-profile-matrix-admin-membership/v1'
                    status = 'passed'
                    groupName = $GroupName
                    groupSid = $groupSid.Value
                    memberName = $MemberName
                    memberSid = $MemberSid
                    attempts = $attempt + 1
                    stableMatches = $stableMatches
                    observedMemberSids = @($observedSids)
                    observedMemberNames = @($observedNames)
                    startedAt = $startedAt.ToString('o')
                    endedAt = $endedAt.ToString('o')
                }
                Write-ProfileMatrixAtomicJson -Path $EvidencePath -Value $record
                # Give the logon/token path one additional scheduler turn after
                # the membership has converged before launching the child.
                Start-Sleep -Milliseconds 500
                return $record
            }
        } catch {
            $lastError = [string]$_.Exception.Message
            $stableMatches = 0
        }
        if ($attempt -lt 39) { Start-Sleep -Milliseconds 250 }
    }

    $endedAt = [DateTimeOffset]::UtcNow
    $failure = [ordered]@{
        schemaVersion = 'cyc.dev/windows-profile-matrix-admin-membership/v1'
        status = 'failed'
        groupName = $GroupName
        groupSid = $groupSid.Value
        memberName = $MemberName
        memberSid = $MemberSid
        attempts = 40
        stableMatches = $stableMatches
        observedMemberSids = @($observedSids)
        observedMemberNames = @($observedNames)
        startedAt = $startedAt.ToString('o')
        endedAt = $endedAt.ToString('o')
        error = $lastError
    }
    try { Write-ProfileMatrixAtomicJson -Path $EvidencePath -Value $failure } catch { }
    throw "administrator membership did not converge for $MemberName ($MemberSid) in $GroupName; observed=$($observedSids -join ',') error=$lastError"
}

function Assert-ProfileMatrixTaskOwnership {
    param(
        [Parameter(Mandatory = $true)]$Task,
        [Parameter(Mandatory = $true)][string]$Sid,
        $ExpectedAction
    )

    $taskPath = [string]$Task.TaskPath
    if ($taskPath -cne '\') {
        throw "profile-matrix task helper rejected task outside the root task path: $taskPath"
    }
    $principalUserId = [string]$Task.Principal.UserId
    if ([string]::IsNullOrWhiteSpace($principalUserId) -or
        (ConvertTo-ProfileMatrixSid -Identity $principalUserId) -cne $Sid) {
        throw "profile-matrix task helper rejected task principal ownership for SID $Sid."
    }

    $triggerUsers = @(
        foreach ($trigger in @($Task.Triggers)) {
            $userProperty = $trigger.PSObject.Properties['UserId']
            if ($null -ne $userProperty -and -not [string]::IsNullOrWhiteSpace([string]$userProperty.Value)) {
                [string]$userProperty.Value
            }
        }
    )
    if ($triggerUsers.Count -eq 0 -or
        (@($triggerUsers | Where-Object { (ConvertTo-ProfileMatrixSid -Identity $_) -ceq $Sid }).Count -eq 0)) {
        throw "profile-matrix task helper rejected task logon trigger ownership for SID $Sid."
    }

    $taskAction = @($Task.Actions | Select-Object -First 1)
    if ($taskAction.Count -eq 0) { throw 'profile-matrix task helper rejected a task without an action.' }
    $taskExecutable = Resolve-ProfileMatrixPath ([string]$taskAction[0].Execute)
    $taskArguments = [string]$taskAction[0].Arguments
    $workingDirectoryProperty = $taskAction[0].PSObject.Properties['WorkingDirectory']
    $taskWorkingDirectory = ''
    if ($null -ne $workingDirectoryProperty -and
        -not [string]::IsNullOrWhiteSpace([string]$workingDirectoryProperty.Value)) {
        $taskWorkingDirectory = Resolve-ProfileMatrixPath ([string]$workingDirectoryProperty.Value)
    }
    $profileRoot = Get-ProfileMatrixProfilePathForSid -Sid $Sid
    $localAppData = Resolve-ProfileMatrixPath (Join-Path $profileRoot 'AppData\Local')
    $ownedPrefix = $localAppData + '\ClusterYourCodex-fresh-'
    if (-not $taskExecutable.StartsWith($ownedPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        $taskExecutable -notmatch '(?i)\\ClusterYourCodex-fresh-[0-9a-f]{32}\\program\\cyc-(controller|worker)\.exe$' -or
        [string]::IsNullOrWhiteSpace($taskWorkingDirectory) -or
        $taskWorkingDirectory -notmatch '(?i)\\ClusterYourCodex-fresh-[0-9a-f]{32}\\program$' -or
        -not [string]::Equals($taskWorkingDirectory, (Split-Path -Parent $taskExecutable), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "profile-matrix task helper rejected task action outside the disposable profile install root: $taskExecutable"
    }
    if ($null -ne $ExpectedAction) {
        if (-not [string]::Equals($taskExecutable, [string]$ExpectedAction.executable, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals($taskArguments, [string]$ExpectedAction.arguments, [System.StringComparison]::Ordinal) -or
            -not [string]::Equals($taskWorkingDirectory, [string]$ExpectedAction.workingDirectory, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'profile-matrix task helper observed a task action different from the request.'
        }
    }
    return [PSCustomObject]@{
        taskPath = $taskPath
        principalSid = (ConvertTo-ProfileMatrixSid -Identity $principalUserId)
        triggerSids = @($triggerUsers | ForEach-Object { ConvertTo-ProfileMatrixSid -Identity $_ })
        executable = $taskExecutable
        arguments = $taskArguments
        workingDirectory = $taskWorkingDirectory
    }
}

function Get-ProfileMatrixOwnedTaskProcesses {
    param(
        [Parameter(Mandatory = $true)][string]$Executable
    )

    $expectedExecutable = Resolve-ProfileMatrixPath $Executable
    $matches = New-Object System.Collections.Generic.List[object]
    foreach ($process in @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)) {
        $pathProperty = $process.PSObject.Properties['ExecutablePath']
        if ($null -eq $pathProperty -or [string]::IsNullOrWhiteSpace([string]$pathProperty.Value)) {
            continue
        }
        $observedExecutable = $null
        try { $observedExecutable = Resolve-ProfileMatrixPath ([string]$pathProperty.Value) } catch { continue }
        if ([string]::Equals($observedExecutable, $expectedExecutable, [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]$matches.Add($process)
        }
    }
    return $matches.ToArray()
}

function Stop-ProfileMatrixOwnedTaskRuntime {
    param(
        [Parameter(Mandatory = $true)]$Ownership,
        [ValidateRange(5, 120)][int]$TimeoutSeconds = 30
    )

    # Registering an AtLogOn task while the disposable account is already
    # logged on can cause Task Scheduler to start it immediately on some
    # Windows builds. Never leave that process running while the child waits
    # for the registration response, and never kill a process until the exact
    # action executable has been validated by Assert-ProfileMatrixTaskOwnership.
    $expectedExecutable = Resolve-ProfileMatrixPath ([string]$Ownership.executable)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $processes = @(Get-ProfileMatrixOwnedTaskProcesses -Executable $expectedExecutable)
        if ($processes.Count -eq 0) { return }
        foreach ($process in $processes) {
            $processId = 0
            try { $processId = [int]$process.ProcessId } catch { }
            if ($processId -le 0) {
                throw 'profile-matrix task helper observed an owned task process without a valid PID.'
            }

            # Bind validation and termination to one native process handle.
            # A bare taskkill PID can target an unrelated replacement process
            # if the owned process exits and Windows reuses its PID between
            # enumeration and termination.
            $boundProcess = $null
            try {
                $boundProcess = [System.Diagnostics.Process]::GetProcessById($processId)
                [void]$boundProcess.Handle
                $observedExecutable = Resolve-ProfileMatrixPath ([string]$boundProcess.MainModule.FileName)
                $observedStart = $boundProcess.StartTime.ToUniversalTime()
                $expectedStart = ([DateTime]$process.CreationDate).ToUniversalTime()
                if (-not [string]::Equals($observedExecutable, $expectedExecutable, [System.StringComparison]::OrdinalIgnoreCase) -or
                    [Math]::Abs(($observedStart - $expectedStart).TotalSeconds) -gt 1) {
                    continue
                }
                $boundProcess.Kill()
                if (-not $boundProcess.WaitForExit(10000)) {
                    throw "profile-matrix task helper could not terminate handle-bound owned task process $processId."
                }
            } catch [System.ArgumentException] {
                # The owned process exited before a handle could be acquired.
                continue
            } finally {
                if ($null -ne $boundProcess) { $boundProcess.Dispose() }
            }
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    $remaining = @(Get-ProfileMatrixOwnedTaskProcesses -Executable ([string]$Ownership.executable))
    if ($remaining.Count -gt 0) {
        $remainingIds = @($remaining | ForEach-Object { [string]$_.ProcessId }) -join ','
        throw "profile-matrix task helper could not prove owned task runtime termination (pids=$remainingIds)."
    }
}

function Invoke-ProfileMatrixBoundedTaskRemoval {
    param(
        [Parameter(Mandatory = $true)][string]$CaseRoot,
        [Parameter(Mandatory = $true)][ValidateSet('ClusterYourCodex Controller', 'ClusterYourCodex Worker')][string]$TaskName,
        [ValidateRange(5, 120)][int]$TimeoutSeconds = 30
    )

    # The PowerShell task-unregister API can wait indefinitely when Task
    # Scheduler has a still-running AtLogOn instance in the disposable user's
    # session. Use the native schtasks delete operation in a separately bounded
    # process instead; the task action was already validated and reaped by the
    # caller.
    $resolvedCaseRoot = Resolve-ProfileMatrixPath $CaseRoot
    if (-not (Test-Path -LiteralPath $resolvedCaseRoot -PathType Container)) {
        throw "profile-matrix task removal case root does not exist: $resolvedCaseRoot"
    }
    $schtasks = Join-Path $env:SystemRoot 'System32\schtasks.exe'
    $taskKill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    if (-not (Test-Path -LiteralPath $schtasks -PathType Leaf) -or
        -not (Test-Path -LiteralPath $taskKill -PathType Leaf)) {
        throw 'profile-matrix task removal requires schtasks.exe and taskkill.exe.'
    }
    $taskIdentifier = '\' + $TaskName
    $arguments = '/Delete /TN "{0}" /F' -f $taskIdentifier.Replace('"', '')
    $suffix = [Guid]::NewGuid().ToString('N')
    $stdoutPath = Join-Path $resolvedCaseRoot ("task-removal-$suffix.stdout.log")
    $stderrPath = Join-Path $resolvedCaseRoot ("task-removal-$suffix.stderr.log")
    $schedulerProcess = $null
    try {
        $schedulerProcess = Start-Process `
            -FilePath $schtasks `
            -ArgumentList $arguments `
            -WorkingDirectory $resolvedCaseRoot `
            -WindowStyle Hidden `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -PassThru
        if (-not $schedulerProcess.WaitForExit($TimeoutSeconds * 1000)) {
            $taskKillExit = -1
            try {
                & $taskKill /PID $schedulerProcess.Id /T /F *> $null
                $taskKillExit = [int]$LASTEXITCODE
            } catch { }
            $terminated = $false
            try { $terminated = [bool]$schedulerProcess.WaitForExit(30000) } catch { }
            if (-not $terminated) {
                throw "profile-matrix task removal command did not terminate (pid=$($schedulerProcess.Id), taskkillExit=$taskKillExit)."
            }
            throw "profile-matrix task removal timed out after $TimeoutSeconds seconds (task=$TaskName, taskkillExit=$taskKillExit)."
        }
        try { $schedulerProcess.Refresh() } catch { }
        $exitCode = [int]$schedulerProcess.ExitCode
        if ($exitCode -ne 0) {
            # A concurrent cleanup can win the race after ownership was
            # validated. Treat that narrow case as already absent; a task that
            # remains present is still a hard failure with captured diagnostics.
            $remaining = @(Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue)
            if ($remaining.Count -gt 0) {
                $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw } else { '' }
                $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
                throw "profile-matrix task removal failed for $TaskName with schtasks exit $exitCode. stdout=$stdout stderr=$stderr"
            }
        }
        return [PSCustomObject]@{
            taskName = $TaskName
            command = "$schtasks $arguments"
            exitCode = $exitCode
            stdout = $stdoutPath
            stderr = $stderrPath
        }
    } finally {
        if ($null -ne $schedulerProcess) { $schedulerProcess.Dispose() }
    }
}

function Get-ProfileMatrixTaskHelperHistoryRecords {
    param([Parameter(Mandatory = $true)]$Value)

    # Windows PowerShell can deserialize a prior JSON array through a generic
    # List projection ({value: [...], Count: n}) when the file was written by a
    # one-element pipeline. Flatten that compatibility shape while retaining
    # only actual versioned helper records. This keeps durable evidence a plain
    # JSON array instead of allowing wrapper objects to nest on every request.
    $entries = if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $Value
    } else {
        @($Value)
    }
    foreach ($entry in $entries) {
        if ($null -eq $entry) { continue }
        $valueProperty = $entry.PSObject.Properties['value']
        $countProperty = $entry.PSObject.Properties['Count']
        $schemaProperty = $entry.PSObject.Properties['schemaVersion']
        if ($null -ne $valueProperty -and $null -ne $countProperty -and $null -eq $schemaProperty) {
            foreach ($nested in @(Get-ProfileMatrixTaskHelperHistoryRecords -Value $valueProperty.Value)) {
                $nested
            }
            continue
        }
        $entry
    }
}

function Invoke-ProfileMatrixTaskHelperRequest {
    param(
        [Parameter(Mandatory = $true)][string]$CaseRoot,
        [Parameter(Mandatory = $true)][string]$RequestPath,
        [Parameter(Mandatory = $true)][string]$ResponsePath,
        [Parameter(Mandatory = $true)][string]$EvidencePath,
        [Parameter(Mandatory = $true)][string]$Sid,
        [Parameter(Mandatory = $true)][string]$UserName
    )
    $resolvedCaseRoot = Resolve-ProfileMatrixPath $CaseRoot
    foreach ($ipcPath in @($RequestPath, $ResponsePath, $EvidencePath)) {
        $resolvedIpcPath = Resolve-ProfileMatrixPath $ipcPath
        if (-not $resolvedIpcPath.StartsWith($resolvedCaseRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "profile-matrix task helper IPC path escaped its case root: $resolvedIpcPath"
        }
        if (Test-Path -LiteralPath $resolvedIpcPath) {
            $ipcItem = Get-Item -LiteralPath $resolvedIpcPath -Force -ErrorAction Stop
            if (($ipcItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "profile-matrix task helper IPC path is a reparse point: $resolvedIpcPath"
            }
        }
    }
    if (-not (Test-Path -LiteralPath $RequestPath -PathType Leaf)) { return $false }
    $request = $null
    $status = 'failed'
    $errorMessage = $null
    $operation = 'unknown'
    $observedLogonType = $null
    $ownership = $null
    $expectedAccount = $null
    $requestAccount = $null
    $requestAccountSidValue = $null
    $accountBinding = 'unresolved'
    try {
        $request = Read-ProfileMatrixUtf8Json -Path $RequestPath
        if ([string]$request.schemaVersion -cne 'cyc.dev/windows-profile-matrix-task-request/v2' -or
            [string]$request.requestId -notmatch '^[0-9a-f]{32}$' -or
            [string]$request.sid -cne $Sid -or
            [string]$request.logonType -cne 'Interactive' -or
            [string]$request.taskName -notin @('ClusterYourCodex Controller', 'ClusterYourCodex Worker')) {
            throw 'profile-matrix task helper rejected an unbound task request.'
        }
        $requestAccount = [string]$request.account
        if ([string]::IsNullOrWhiteSpace($requestAccount)) {
            throw 'profile-matrix task helper rejected an empty account identity.'
        }
        $expectedAccount = Resolve-ProfileMatrixAccountName -Sid $Sid -FallbackUserName $UserName
        $accountSidProperty = $request.PSObject.Properties['accountSid']
        if ($null -ne $accountSidProperty) {
            $declaredAccountSid = [string]$accountSidProperty.Value
            if ($declaredAccountSid -cne $Sid) {
                throw "profile-matrix task helper rejected account SID binding $declaredAccountSid."
            }
            $requestAccountSidValue = $declaredAccountSid
            $accountBinding = 'request-account-sid'
        } else {
            $requestAccountSid = $null
            try {
                $requestAccountSid = ConvertTo-ProfileMatrixSid -Identity $requestAccount
            } catch { }
            if ($null -ne $requestAccountSid) {
                if ($requestAccountSid -cne $Sid) {
                    throw "profile-matrix task helper rejected account identity $requestAccount (SID $requestAccountSid)."
                }
                $accountBinding = 'legacy-request-account-sid'
            } elseif ([string]::Equals($requestAccount, $expectedAccount, [System.StringComparison]::OrdinalIgnoreCase)) {
                $accountBinding = 'canonical-account'
            } else {
                # Keep the SID from the request and the SID-derived account
                # used below as the security boundary. WindowsIdentity.Name
                # can be a lossy display string for Unicode local accounts on
                # ARM64/x64 emulation, so a name-only mismatch is diagnostic
                # rather than a reason to reject a request already bound to
                # the expected SID.
                $accountBinding = 'sid-bound-display-mismatch'
            }
        }
        $account = $expectedAccount
        $operation = [string]$request.operation
        if ($operation -notin @('Register', 'Unregister', 'Restore')) {
            throw "profile-matrix task helper rejected operation $operation."
        }
        $actionProperty = $request.PSObject.Properties['action']
        if ($null -eq $actionProperty -or
            ($operation -eq 'Register' -and $null -eq $actionProperty.Value) -or
            ($operation -ne 'Register' -and $null -ne $actionProperty.Value)) {
            throw "profile-matrix task helper rejected action binding for $operation."
        }
        $snapshotProperty = $request.PSObject.Properties['snapshot']
        if ($null -eq $snapshotProperty -or
            ($operation -eq 'Restore' -and $null -eq $snapshotProperty.Value) -or
            ($operation -ne 'Restore' -and $null -ne $snapshotProperty.Value)) {
            throw "profile-matrix task helper rejected an unexpected snapshot for $operation."
        }
        if ($operation -eq 'Register') {
            $action = Assert-ProfileMatrixTaskAction -Request $request -Sid $Sid -UserName $UserName
            $taskAction = New-ScheduledTaskAction `
                -Execute $action.executable `
                -Argument $action.arguments `
                -WorkingDirectory $action.workingDirectory
            $trigger = New-ScheduledTaskTrigger -AtLogOn -User $account
            $principal = New-ScheduledTaskPrincipal -UserId $account -LogonType Interactive -RunLevel Limited
            $settings = New-ScheduledTaskSettingsSet `
                -MultipleInstances IgnoreNew `
                -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries `
                -StartWhenAvailable `
                -RestartCount 3 `
                -RestartInterval (New-TimeSpan -Minutes 1) `
                -ExecutionTimeLimit ([TimeSpan]::Zero)
            Register-ScheduledTask `
                -TaskName ([string]$request.taskName) `
                -TaskPath '\' `
                -Action $taskAction `
                -Trigger $trigger `
                -Principal $principal `
                -Settings $settings `
                -Description 'ClusterYourCodex per-user background component' `
                -Force | Out-Null
            $task = Get-ScheduledTask -TaskName ([string]$request.taskName) -TaskPath '\' -ErrorAction Stop
            $ownership = Assert-ProfileMatrixTaskOwnership -Task $task -Sid $Sid -ExpectedAction $action
            [void](Stop-ProfileMatrixOwnedTaskRuntime -Ownership $ownership)
            $observedLogonType = [string]$task.Principal.LogonType
            if ($observedLogonType -notin @('Interactive', 'InteractiveToken', '3')) {
                throw "profile-matrix task helper observed unexpected task logon type $observedLogonType."
            }
        } elseif ($operation -eq 'Unregister') {
            $task = Get-ScheduledTask -TaskName ([string]$request.taskName) -TaskPath '\' -ErrorAction SilentlyContinue
            if ($null -ne $task) {
                $ownership = Assert-ProfileMatrixTaskOwnership -Task $task -Sid $Sid
                [void](Stop-ProfileMatrixOwnedTaskRuntime -Ownership $ownership)
                [void](Invoke-ProfileMatrixBoundedTaskRemoval -CaseRoot $resolvedCaseRoot -TaskName ([string]$request.taskName))
                [void](Stop-ProfileMatrixOwnedTaskRuntime -Ownership $ownership)
            }
            if ($null -ne (Get-ScheduledTask -TaskName ([string]$request.taskName) -TaskPath '\' -ErrorAction SilentlyContinue)) {
                throw "profile-matrix task helper could not remove $([string]$request.taskName)."
            }
        } else {
            $snapshot = Assert-ProfileMatrixTaskSnapshot -Request $request -Sid $Sid -UserName $UserName
            $action = $snapshot.action
            $taskAction = New-ScheduledTaskAction `
                -Execute $action.executable `
                -Argument $action.arguments `
                -WorkingDirectory $action.workingDirectory
            $account = if (-not [string]::IsNullOrWhiteSpace($expectedAccount)) {
                $expectedAccount
            } else {
                Resolve-ProfileMatrixAccountName -Sid $Sid -FallbackUserName $UserName
            }
            $trigger = New-ScheduledTaskTrigger -AtLogOn -User $account
            $principal = New-ScheduledTaskPrincipal -UserId $account -LogonType Interactive -RunLevel Limited
            $settings = New-ScheduledTaskSettingsSet `
                -MultipleInstances IgnoreNew `
                -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries `
                -StartWhenAvailable `
                -RestartCount 3 `
                -RestartInterval (New-TimeSpan -Minutes 1) `
                -ExecutionTimeLimit ([TimeSpan]::Zero)
            Register-ScheduledTask `
                -TaskName ([string]$request.taskName) `
                -TaskPath '\' `
                -Action $taskAction `
                -Trigger $trigger `
                -Principal $principal `
                -Settings $settings `
                -Description 'ClusterYourCodex per-user background component' `
                -Force | Out-Null
            $task = Get-ScheduledTask -TaskName ([string]$request.taskName) -TaskPath '\' -ErrorAction Stop
            $ownership = Assert-ProfileMatrixTaskOwnership -Task $task -Sid $Sid -ExpectedAction $action
            if (-not [string]::Equals([string]$ownership.taskPath, [string]$snapshot.taskPath, [System.StringComparison]::Ordinal)) {
                throw 'profile-matrix task helper observed a restored task outside the snapshot task path.'
            }
            if ([string]$ownership.principalSid -cne [string]$snapshot.principalSid -or
                @($ownership.triggerSids | Where-Object { $_ -ceq $Sid }).Count -ne 1) {
                throw 'profile-matrix task helper observed a restored task with different identity bindings.'
            }
            [void](Stop-ProfileMatrixOwnedTaskRuntime -Ownership $ownership)
            $restoredRunning = $false
        }
        $status = 'passed'
    } catch {
        $errorMessage = [string]$_.Exception.Message
    }
    $requestId = if ($null -ne $request) { [string]$request.requestId } else { [Guid]::NewGuid().ToString('N') }
    $record = [ordered]@{
        schemaVersion = 'cyc.dev/windows-profile-matrix-task-helper/v1'
        requestId = $requestId
        operation = if ($null -ne $request) { [string]$request.operation } else { 'unknown' }
        taskName = if ($null -ne $request) { [string]$request.taskName } else { 'unknown' }
        sid = $Sid
        status = $status
        observedLogonType = $observedLogonType
        observedTaskPath = if ($null -ne $ownership) { [string]$ownership.taskPath } else { $null }
        observedPrincipalSid = if ($null -ne $ownership) { [string]$ownership.principalSid } else { $null }
        observedTriggerSids = if ($null -ne $ownership) { @($ownership.triggerSids) } else { @() }
        observedAction = if ($null -ne $ownership) {
            [ordered]@{
                executable = [string]$ownership.executable
                arguments = [string]$ownership.arguments
                workingDirectory = [string]$ownership.workingDirectory
            }
        } else { $null }
        expectedAccount = $expectedAccount
        requestAccount = $requestAccount
        accountSid = $requestAccountSidValue
        accountBinding = $accountBinding
        runtime = 'not-started'
        restoredRunning = if ($operation -ceq 'Restore' -and $status -ceq 'passed') { $false } else { $null }
        error = $errorMessage
        completedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $requestRemoved = $false
    try {
        $history = New-Object System.Collections.Generic.List[object]
        if (Test-Path -LiteralPath $EvidencePath -PathType Leaf) {
            try {
                foreach ($historyRecord in @(Get-ProfileMatrixTaskHelperHistoryRecords -Value (Read-ProfileMatrixUtf8Json -Path $EvidencePath))) {
                    [void]$history.Add($historyRecord)
                }
            } catch { $history = New-Object System.Collections.Generic.List[object] }
        }
        [void]$history.Add($record)
        $historyArray = [object[]]::new($history.Count)
        $history.CopyTo($historyArray)
        Write-ProfileMatrixAtomicJson -Path $EvidencePath -Value (,$historyArray)
        # Consume the request before publishing the response. The child may
        # observe the response and immediately publish its next request; an
        # unconditional finally-time delete would then remove that new request.
        Remove-Item -LiteralPath $RequestPath -Force -ErrorAction Stop
        $requestRemoved = $true
        Write-ProfileMatrixAtomicJson -Path $ResponsePath -Value $record
    } finally {
        if (-not $requestRemoved) {
            Remove-Item -LiteralPath $RequestPath -Force -ErrorAction SilentlyContinue
        }
    }
    return $true
}

function Remove-ProfileMatrixTaskHelperTasks {
    param(
        [Parameter(Mandatory = $true)][string]$CaseRoot,
        [Parameter(Mandatory = $true)][string]$Sid
    )
    $profilePath = Get-ProfileMatrixProfilePathForSid -Sid $Sid
    foreach ($taskName in @('ClusterYourCodex Controller', 'ClusterYourCodex Worker')) {
        $task = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
        if ($null -eq $task) { continue }
        $ownership = Assert-ProfileMatrixTaskOwnership -Task $task -Sid $Sid
        [void](Stop-ProfileMatrixOwnedTaskRuntime -Ownership $ownership)
        [void](Invoke-ProfileMatrixBoundedTaskRemoval -CaseRoot $CaseRoot -TaskName $taskName)
        [void](Stop-ProfileMatrixOwnedTaskRuntime -Ownership $ownership)
        if ($null -ne (Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue)) {
            throw "profile-matrix task helper could not remove owned task $taskName."
        }
    }
}

function Get-ProfileMatrixExpectedCurrentCase {
    param([Parameter(Mandatory = $true)][string[]]$RequestedCases)

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
    $adminSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $isAdmin = $principal.IsInRole($adminSid)
    $profile = Resolve-ProfileMatrixPath $env:USERPROFILE
    $suffix = if ($profile -match '[^\u0000-\u007f]') { 'non-ascii' } else { 'ascii' }
    $prefix = if ($isAdmin) { 'administrator' } else { 'standard' }
    $expected = "$prefix-$suffix"

    # The default four-case list is convenient for the full run. In
    # CurrentUserOnly mode a caller may also explicitly select exactly the
    # effective case, but never a case that contradicts the current token.
    # Do not accept an arbitrary four-item list: count-only validation could
    # silently discard the caller's requested cases and run a different case.
    $requestedSet = @($RequestedCases | Sort-Object -Unique)
    $defaultSet = @($allowedCaseNames | Sort-Object -Unique)
    if ($requestedSet.Count -eq $defaultSet.Count -and
        @($defaultSet | Where-Object { $requestedSet -notcontains $_ }).Count -eq 0) {
        return $expected
    }
    if (@($RequestedCases).Count -ne 1 -or $RequestedCases[0] -cne $expected) {
        throw "CurrentUserOnly requires the effective current-user case '$expected'."
    }
    return [string]$RequestedCases[0]
}

function Remove-ProfileMatrixKnownCompatibilityJunctions {
    param([Parameter(Mandatory = $true)][string]$ProfileRoot)

    $resolved = Resolve-ProfileMatrixPath $ProfileRoot
    $pending = New-Object System.Collections.Generic.Stack[string]
    $links = New-Object System.Collections.Generic.List[string]
    $pending.Push($resolved)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $current -Force)) {
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                if (-not (Test-ProfileMatrixKnownCompatibilityJunction -ProfileRoot $resolved -Item $item)) {
                    throw "profile matrix refuses an unexpected profile reparse point during cleanup: $($item.FullName)"
                }
                # Record the link and never recurse through it. Nested
                # Documents\My * junctions are removed before their parent
                # directory is considered for the final recursive cleanup.
                [void]$links.Add([string]$item.FullName)
                continue
            }
            if ($item.PSIsContainer) { $pending.Push([string]$item.FullName) }
        }
    }
    foreach ($linkPath in @($links | Sort-Object { $_.Length } -Descending)) {
        # Remove the link itself, never its target. Do this before the final
        # recursive profile deletion because Windows PowerShell 5.1 may walk
        # directory junctions when -Recurse is used.
        if (Test-Path -LiteralPath $linkPath -PathType Container) {
            Remove-Item -LiteralPath $linkPath -Force -ErrorAction Stop
        } elseif (Test-Path -LiteralPath $linkPath) {
            Remove-Item -LiteralPath $linkPath -Force -ErrorAction Stop
        }
    }
}

function Remove-ProfileMatrixUserProfile {
    param(
        [Parameter(Mandatory = $true)][string]$Sid,
        [Parameter(Mandatory = $true)][string]$UserName
    )
    $profile = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop |
        Where-Object { [string]$_.SID -ceq $Sid } |
        Select-Object -First 1
    if ($null -eq $profile) { return }
    # Reuse the SID-bound registry resolver instead of trusting the same
    # mojibaked CIM LocalPath projection that the parent task helper avoids.
    $localPath = Get-ProfileMatrixProfilePathForSid -Sid $Sid
    $base = Resolve-ProfileMatrixPath (Join-Path $env:SystemDrive 'Users')
    $resolved = Resolve-ProfileMatrixPath $localPath
    $leaf = Split-Path -Leaf $resolved
    if (-not [string]::Equals((Split-Path -Parent $resolved), $base, [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::IsNullOrWhiteSpace($leaf)) {
        throw "refusing to remove unexpected user profile path: $resolved"
    }
    # Profile unload and WMI deletion can lag behind child-process reaping on
    # Windows. Retry the complete removal/postcondition sequence for a bounded
    # interval, and turn any residual state into a case failure instead of a
    # warning that the matrix would otherwise report as passed.
    $lastFailure = $null
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        try {
            $current = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop |
                Where-Object { [string]$_.SID -ceq $Sid } |
                Select-Object -First 1
            if ($null -ne $current) {
                if ([bool]$current.Loaded) {
                    throw "profile $Sid remains loaded"
                }
                Remove-CimInstance -InputObject $current -ErrorAction Stop
            }
            if (Test-Path -LiteralPath $resolved) {
                Test-ProfileMatrixReparseFree -Root $resolved -AllowKnownCompatibilityJunctions
                Remove-ProfileMatrixKnownCompatibilityJunctions -ProfileRoot $resolved
                Test-ProfileMatrixReparseFree -Root $resolved
                Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
            }
            $remaining = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop |
                Where-Object { [string]$_.SID -ceq $Sid } |
                Select-Object -First 1
            if ($null -eq $remaining -and -not (Test-Path -LiteralPath $resolved)) {
                return
            }
            throw "profile cleanup postcondition still has profile or directory state"
        } catch {
            $lastFailure = [string]$_.Exception.Message
            if ($attempt -lt 19) {
                Start-Sleep -Milliseconds 250
            }
        }
    }
    throw "profile cleanup failed for $Sid after bounded retries: $lastFailure"
}

$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
if ($RequireWindows11) {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    Assert-ProfileMatrix ([string]$os.Caption -match '\bWindows 11\b') "Windows 11 is required (observed: $([string]$os.Caption))"
}
if (-not $CurrentUserOnly) {
    Assert-ProfileMatrix $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator) 'profile matrix requires an elevated controller'
}

$cases = New-Object System.Collections.Generic.List[object]
$startedAt = [DateTimeOffset]::UtcNow
$package = $null
$work = $null
$stage = $null
$workExistedAtStart = $false
$result = $null
$resultPath = $null
$failure = $null
$failureMessage = $null

try {
    $package = Resolve-ProfileMatrixPath $PackageRoot
    Assert-ProfileMatrix (Test-Path -LiteralPath $package -PathType Container) "package root exists: $package"
    Test-ProfileMatrixReparseFree -Root $package
    $work = Resolve-ProfileMatrixPath $WorkRoot
    $workExistedAtStart = Test-Path -LiteralPath $work
    if ($workExistedAtStart -and -not $KeepWorkRoot) {
        throw "work root already exists; choose a fresh path or pass -KeepWorkRoot: $work"
    }
    if ($workExistedAtStart) { Test-ProfileMatrixReparseFree -Root $work }
    [void](New-Item -ItemType Directory -Path $work -Force)
    Add-ProfileMatrixUsersModify -Path $work
    $stage = Join-Path $work 'package'
    if (Test-Path -LiteralPath $stage) {
        Test-ProfileMatrixReparseFree -Root $stage
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
    [void](New-Item -ItemType Directory -Path $stage -Force)
    Add-ProfileMatrixUsersModify -Path $stage
    & (Join-Path $env:SystemRoot 'System32\robocopy.exe') $package $stage /E /COPY:DAT /DCOPY:DAT /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP *> (Join-Path $work 'package-copy.log')
    $copyExit = $LASTEXITCODE
    if ($copyExit -gt 7) { throw "profile matrix package staging failed with robocopy exit $copyExit" }
    Test-ProfileMatrixReparseFree -Root $stage

    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $child = Join-Path $PSScriptRoot 'Test-WindowsProfileMatrixChild.ps1'
    Assert-ProfileMatrix (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf) 'Windows PowerShell 5.1 is installed'
    Assert-ProfileMatrix (Test-Path -LiteralPath $child -PathType Leaf) 'profile matrix child harness exists'
    $adminGroup = Get-ProfileMatrixAdminGroupName
    $runCases = if ($CurrentUserOnly) {
        @(Get-ProfileMatrixExpectedCurrentCase -RequestedCases $CaseName)
    } else {
        @($CaseName)
    }

    try {
    foreach ($case in $runCases) {
        $caseId = [Guid]::NewGuid().ToString('N')
        $shortId = $caseId.Substring(0, 6)
        $isAdmin = $case.StartsWith('administrator-', [System.StringComparison]::Ordinal)
        $isNonAscii = $case.EndsWith('-non-ascii', [System.StringComparison]::Ordinal)
        $userName = if ($CurrentUserOnly) { [string]$identity.Name.Split('\')[-1] } elseif ($isNonAscii) { "cyc测$shortId" } else { "cycpm$shortId" }
        $password = $null
        $credential = $null
        $sid = $null
        $membershipEvidencePath = $null
        $caseRoot = Join-Path $work $case
        if (Test-Path -LiteralPath $caseRoot) {
            Test-ProfileMatrixReparseFree -Root $caseRoot
            Remove-Item -LiteralPath $caseRoot -Recurse -Force
        }
        $stdoutPath = Join-Path $caseRoot 'child.stdout.log'
        $stderrPath = Join-Path $caseRoot 'child.stderr.log'
        $receiptPath = Join-Path $caseRoot 'receipt.json'
        [void](New-Item -ItemType Directory -Path $caseRoot -Force)
        Add-ProfileMatrixUsersModify -Path $caseRoot
        $caseFailureRecord = $null
        $caseCleanupFailureMessage = $null
        $process = $null
        try {
            if ($CurrentUserOnly) {
                $sid = [string]$identity.User.Value
            } else {
                $password = ConvertTo-ProfileMatrixSecureString
                $newUser = New-LocalUser -Name $userName -Password $password -Description 'ClusterYourCodex profile-matrix account' -AccountNeverExpires -UserMayNotChangePassword -PasswordNeverExpires -ErrorAction Stop
                $sid = [string]$newUser.SID.Value
                if ($isAdmin) {
                    # Bind membership to the LocalUser/SID object rather than
                    # a localized or otherwise ambiguous display name. Then
                    # wait for two consecutive SAM observations before
                    # creating the child logon token; ARM64 x64 emulation can
                    # otherwise launch a token before the group change is
                    # visible and falsely report an administrator case as a
                    # standard user.
                    Add-LocalGroupMember -Group $adminGroup -Member $newUser -ErrorAction Stop
                    $membershipEvidencePath = Join-Path $caseRoot 'administrator-membership.json'
                    [void](Wait-ProfileMatrixAdminMembership `
                        -GroupName $adminGroup `
                        -MemberSid $sid `
                        -MemberName "$env:COMPUTERNAME\$userName" `
                        -EvidencePath $membershipEvidencePath)
                }
                $credentialAccount = Resolve-ProfileMatrixAccountName -Sid $sid -FallbackUserName $userName
                $credential = [System.Management.Automation.PSCredential]::new($credentialAccount, $password)
            }
            $childArguments = @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-File', $child,
                '-CaseName', $case,
                '-PackageRoot', $stage,
                '-WorkRoot', $caseRoot,
                '-ExpectedSid', $sid,
                '-ReceiptPath', $receiptPath
            )
            $startArguments = $childArguments | ForEach-Object { ConvertTo-ProfileMatrixArgument ([string]$_) }
            $startParameters = @{
                FilePath = $windowsPowerShell
                ArgumentList = $startArguments
                WorkingDirectory = $caseRoot
                WindowStyle = 'Hidden'
                RedirectStandardOutput = $stdoutPath
                RedirectStandardError = $stderrPath
                PassThru = $true
            }
            if (-not $CurrentUserOnly) {
                $childArguments += @('-UseParentTaskHelper')
                $startArguments = $childArguments | ForEach-Object { ConvertTo-ProfileMatrixArgument ([string]$_) }
                $startParameters.ArgumentList = $startArguments
                $startParameters.Credential = $credential
                $startParameters.LoadUserProfile = $true
            }
            $process = Start-Process @startParameters
            # The disposable account cannot cross the task scheduler's
            # InteractiveToken boundary. Keep registration in the elevated
            # controller, but only for the exact request emitted by the child
            # and only while that child is alive.
            $taskRequestPath = Join-Path $caseRoot 'task-registration-request.json'
            $taskResponsePath = Join-Path $caseRoot 'task-registration-response.json'
            $taskHelperEvidencePath = Join-Path $caseRoot 'task-helper-evidence.json'
            $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ChildTimeoutSeconds)
            $timedOut = $false
            while (-not $process.HasExited) {
                if (-not $CurrentUserOnly) {
                    [void](Invoke-ProfileMatrixTaskHelperRequest `
                        -CaseRoot $caseRoot `
                        -RequestPath $taskRequestPath `
                        -ResponsePath $taskResponsePath `
                        -EvidencePath $taskHelperEvidencePath `
                        -Sid $sid `
                        -UserName $userName)
                }
                if ([DateTimeOffset]::UtcNow -ge $deadline) {
                    $timedOut = $true
                    break
                }
                # Wait on the process handle for a bounded slice instead of
                # sleeping blindly; this observes exit promptly while keeping
                # the IPC/deadline loop responsive on slow emulated runners.
                [void]$process.WaitForExit(100)
            }
            if ($timedOut) {
                $taskKill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
                $taskKillExit = -1
                try {
                    & $taskKill /PID $process.Id /T /F *> $null
                    $taskKillExit = [int]$LASTEXITCODE
                } catch { }
                $terminated = $false
                try { $terminated = [bool]$process.WaitForExit(30000) } catch { }
                if ($taskKillExit -ne 0 -or -not $terminated) {
                    throw "case $case child timed out after $ChildTimeoutSeconds seconds and process termination was not proven (pid=$($process.Id), taskkillExit=$taskKillExit)."
                }
                throw "case $case child timed out after $ChildTimeoutSeconds seconds (pid=$($process.Id))."
            }
            if (-not $CurrentUserOnly) {
                # Drain one final request after the child exits so a request
                # emitted immediately before process termination is never left
                # without a durable helper response.
                for ($drain = 0; $drain -lt 20; $drain++) {
                    $handled = Invoke-ProfileMatrixTaskHelperRequest `
                        -CaseRoot $caseRoot `
                        -RequestPath $taskRequestPath `
                        -ResponsePath $taskResponsePath `
                        -EvidencePath $taskHelperEvidencePath `
                        -Sid $sid `
                        -UserName $userName
                    if (-not $handled -and -not (Test-Path -LiteralPath $taskRequestPath -PathType Leaf)) { break }
                    Start-Sleep -Milliseconds 100
                }
            }
            $process.WaitForExit()
            # Start-Process -Credential on ARM64 Windows can return a Process
            # wrapper whose ExitCode projection is temporarily null even after
            # WaitForExit() (the child has already published its receipt).
            # Refresh and use the child receipt as an independently written
            # exit-status fallback; a missing or malformed receipt remains a
            # hard failure below.
            try { $process.Refresh() } catch { }
            $rawExitCode = $process.ExitCode
            if ($null -ne $rawExitCode) {
                $exitCode = [int]$rawExitCode
            } else {
                $exitCode = $null
                if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
                    try {
                        $childReceipt = Read-ProfileMatrixUtf8Json -Path $receiptPath
                        $candidateExitCode = $childReceipt.exitCode
                        $parsedExitCode = 0
                        if ($null -ne $candidateExitCode -and [int]::TryParse([string]$candidateExitCode, [ref]$parsedExitCode)) {
                            $exitCode = [int]$parsedExitCode
                        }
                    } catch {
                        $exitCode = $null
                    }
                }
                if ($null -eq $exitCode) { $exitCode = 1 }
            }
            if ($exitCode -ne 0) {
                $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw } else { '' }
                $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
                throw "case $case child exited $exitCode. stdout=$stdout stderr=$stderr"
            }
            Assert-ProfileMatrix (Test-Path -LiteralPath $receiptPath -PathType Leaf) "case $case wrote a receipt"
            $receipt = Read-ProfileMatrixUtf8Json -Path $receiptPath
            Assert-ProfileMatrix ([string]$receipt.status -ceq 'passed') "case $case receipt is passed"
            Assert-ProfileMatrix ([string]$receipt.caseName -ceq $case) "case $case receipt binds the case name"
            Assert-ProfileMatrix ([string]$receipt.sid -ceq $sid) "case $case receipt binds the expected SID"
            if ($isAdmin) {
                Assert-ProfileMatrix ($null -ne $membershipEvidencePath -and
                    (Test-Path -LiteralPath $membershipEvidencePath -PathType Leaf)) "case $case preserves administrator membership evidence"
                $membershipEvidence = Read-ProfileMatrixUtf8Json -Path $membershipEvidencePath
                Assert-ProfileMatrix ([string]$membershipEvidence.status -ceq 'passed') "case $case administrator membership evidence is passed"
                Assert-ProfileMatrix ([string]$membershipEvidence.memberSid -ceq $sid) "case $case administrator membership evidence binds the expected SID"
                $receipt | Add-Member -NotePropertyName administratorMembershipEvidence -NotePropertyValue $membershipEvidencePath -Force
            }
            if (-not $CurrentUserOnly) {
                Assert-ProfileMatrix ([string]$receipt.taskRegistration -ceq 'parent-elevated-helper') "case $case uses the elevated task-registration helper"
                Assert-ProfileMatrix ([string]$receipt.taskRuntime -ceq 'not-started') "case $case records that non-interactive task runtime was not started"
                Assert-ProfileMatrix ([string]$receipt.taskGate -ceq 'parent-elevated-registration-v1') "case $case records the explicit task gate"
                Assert-ProfileMatrix (Test-Path -LiteralPath ([string]$receipt.taskGateEvidence) -PathType Leaf) "case $case preserves task-gate evidence"
                Assert-ProfileMatrix (Test-Path -LiteralPath ([string]$receipt.taskHelperEvidence) -PathType Leaf) "case $case preserves elevated-helper evidence"
            }
            [void]$cases.Add($receipt)
        } catch {
            # Preserve the primary child/verification error so a later profile
            # cleanup problem cannot replace the useful root cause.
            $caseFailureRecord = $_
        } finally {
            # A helper/IPC exception can happen while the disposable child is
            # still waiting for a response. Terminate and reap it before
            # touching the account/profile so no process keeps the profile
            # loaded into the next matrix case.
            if ($null -ne $process) {
                try {
                    if (-not $process.HasExited) {
                        # Test-WindowsProfileMatrixChild can own a nested
                        # Test-FreshDeployment powershell process. Kill the
                        # complete tree, then prove the root child is reaped
                        # before deleting its user/profile.
                        $taskKill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
                        try { & $taskKill /PID $process.Id /T /F *> $null } catch { }
                        [void]$process.WaitForExit(30000)
                    }
                    if (-not $process.HasExited) {
                        throw "profile matrix child process $($process.Id) did not exit after cleanup."
                    }
                } catch {
                    $message = "child process cleanup failed: $([string]$_.Exception.Message)"
                    if ([string]::IsNullOrWhiteSpace($caseCleanupFailureMessage)) {
                        $caseCleanupFailureMessage = $message
                    } else {
                        $caseCleanupFailureMessage += "; $message"
                    }
                }
            }
            if (-not $CurrentUserOnly) {
                if ($null -ne $sid) {
                    try { Remove-ProfileMatrixTaskHelperTasks -CaseRoot $caseRoot -Sid $sid } catch {
                        $message = "task cleanup failed: $([string]$_.Exception.Message)"
                        if ([string]::IsNullOrWhiteSpace($caseCleanupFailureMessage)) {
                            $caseCleanupFailureMessage = $message
                        } else {
                            $caseCleanupFailureMessage += "; $message"
                        }
                    }
                }
                if ($isAdmin -and $null -ne $sid) {
                    try { Remove-LocalGroupMember -Group $adminGroup -Member $userName -ErrorAction Stop } catch {
                        $message = "administrator membership cleanup failed: $([string]$_.Exception.Message)"
                        if ([string]::IsNullOrWhiteSpace($caseCleanupFailureMessage)) {
                            $caseCleanupFailureMessage = $message
                        } else {
                            $caseCleanupFailureMessage += "; $message"
                        }
                    }
                }
                try { Remove-LocalUser -Name $userName -ErrorAction Stop } catch {
                    $message = "user cleanup failed: $([string]$_.Exception.Message)"
                    if ([string]::IsNullOrWhiteSpace($caseCleanupFailureMessage)) {
                        $caseCleanupFailureMessage = $message
                    } else {
                        $caseCleanupFailureMessage += "; $message"
                    }
                }
                if ($null -ne $sid) {
                    try {
                        Remove-ProfileMatrixUserProfile -Sid $sid -UserName $userName
                    } catch {
                        $message = [string]$_.Exception.Message
                        if ([string]::IsNullOrWhiteSpace($caseCleanupFailureMessage)) {
                            $caseCleanupFailureMessage = $message
                        } else {
                            $caseCleanupFailureMessage += "; $message"
                        }
                    }
                }
            }
        }
        if ($null -ne $caseCleanupFailureMessage) {
            if ($null -ne $caseFailureRecord) {
                throw ("$([string]$caseFailureRecord.Exception.Message); profile cleanup error: $caseCleanupFailureMessage")
            }
            throw "case $case profile cleanup failed: $caseCleanupFailureMessage"
        }
        if ($null -ne $caseFailureRecord) { throw $caseFailureRecord }
    }
} catch {
    if ($null -eq $failure) {
        $failure = $_
        $failureMessage = [string]$_.Exception.Message
    } elseif ([string]::IsNullOrWhiteSpace($failureMessage)) {
        $failureMessage = [string]$failure.Exception.Message
    }
}

try {
    $endedAt = [DateTimeOffset]::UtcNow
    $result = [ordered]@{
        schemaVersion = 'cyc.dev/windows-profile-matrix/v1'
        status = if ($null -eq $failure) { 'passed' } else { 'failed' }
        packageRoot = $package
        stagedPackageRoot = $stage
        workRoot = $work
        startedAt = $startedAt.ToString('o')
        endedAt = $endedAt.ToString('o')
        cases = $cases.ToArray()
        error = if ($null -eq $failure) { $null } else { $failureMessage }
    }
    if ($null -ne $work -and (Test-Path -LiteralPath $work -PathType Container)) {
        $resultPath = Join-Path $work 'profile-matrix.json'
        $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resultPath -Encoding UTF8
    }
} catch {
    if ($null -eq $failure) {
        $failure = $_
        $failureMessage = [string]$_.Exception.Message
    } else {
        $failureMessage = "$failureMessage; result publication error: $([string]$_.Exception.Message)"
    }
}

} catch {
    if ($null -eq $failure) {
        $failure = $_
        $failureMessage = [string]$_.Exception.Message
    } elseif ([string]::IsNullOrWhiteSpace($failureMessage)) {
        $failureMessage = [string]$failure.Exception.Message
    } else {
        $failureMessage += "; profile matrix orchestration error: $([string]$_.Exception.Message)"
    }
} finally {
    # WorkRoot belongs to this controller only when it was absent before the
    # run. Keep cleanup in an outer finally so setup, case execution, and
    # result publication failures cannot bypass it. Never replace the primary
    # error with a later cleanup failure.
    if (-not $KeepWorkRoot -and -not $workExistedAtStart -and
        $null -ne $work -and -not [string]::IsNullOrWhiteSpace([string]$work) -and
        (Test-Path -LiteralPath $work)) {
        try {
            Test-ProfileMatrixReparseFree -Root $work
            Remove-Item -LiteralPath $work -Recurse -Force
        } catch {
            $cleanupMessage = [string]$_.Exception.Message
            if ($null -eq $failure) {
                $failure = $_
                $failureMessage = $cleanupMessage
            } else {
                if ([string]::IsNullOrWhiteSpace($failureMessage)) {
                    $failureMessage = [string]$failure.Exception.Message
                }
                $failureMessage += "; profile matrix work-root cleanup error: $cleanupMessage"
            }
        }
    }
}

if ($null -ne $result) {
    $result.status = if ($null -eq $failure) { 'passed' } else { 'failed' }
    $result.error = if ($null -eq $failure) { $null } else { $failureMessage }
    if ($null -ne $work -and (Test-Path -LiteralPath $work -PathType Container)) {
        try {
            if ([string]::IsNullOrWhiteSpace([string]$resultPath)) {
                $resultPath = Join-Path $work 'profile-matrix.json'
            }
            $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resultPath -Encoding UTF8
        } catch {
            $message = [string]$_.Exception.Message
            if ($null -eq $failure) {
                $failure = $_
                $failureMessage = "result publication error: $message"
                $result.status = 'failed'
                $result.error = $failureMessage
            } else {
                if ([string]::IsNullOrWhiteSpace($failureMessage)) {
                    $failureMessage = [string]$failure.Exception.Message
                }
                $failureMessage += "; result publication error: $message"
                $result.status = 'failed'
                $result.error = $failureMessage
            }
        }
    }
    $result | ConvertTo-Json -Depth 12 -Compress
}

if ($null -ne $failure) {
    if ([string]::IsNullOrWhiteSpace($failureMessage)) {
        throw $failure
    }
    throw $failureMessage
}
