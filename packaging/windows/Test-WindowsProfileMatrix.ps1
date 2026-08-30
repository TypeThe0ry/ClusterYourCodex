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
    [switch]$RequireWindows11
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
            try { $backupStream.Flush($true) } finally { $backupStream.Dispose() }
            $backupPrepared = $true
            [System.IO.File]::Replace($temporary, $Path, $backup, $true)
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
            if (($committed -or $backupPrepared) -and (Test-Path -LiteralPath $backup)) {
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
    $profile = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop |
        Where-Object { [string]$_.SID -ceq $Sid } |
        Select-Object -First 1
    if ($null -eq $profile -or [string]::IsNullOrWhiteSpace([string]$profile.LocalPath)) {
        throw "profile-matrix task helper could not resolve profile path for SID $Sid."
    }
    return Resolve-ProfileMatrixPath ([string]$profile.LocalPath)
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
    $observedLogonType = $null
    $ownership = $null
    try {
        $request = Get-Content -LiteralPath $RequestPath -Raw -ErrorAction Stop | ConvertFrom-Json
        if ([string]$request.schemaVersion -cne 'cyc.dev/windows-profile-matrix-task-request/v1' -or
            [string]$request.requestId -notmatch '^[0-9a-f]{32}$' -or
            [string]$request.sid -cne $Sid -or
            [string]$request.logonType -cne 'Interactive' -or
            [string]$request.taskName -notin @('ClusterYourCodex Controller', 'ClusterYourCodex Worker')) {
            throw 'profile-matrix task helper rejected an unbound task request.'
        }
        $account = "$env:COMPUTERNAME\$UserName"
        if ([string]$request.account -cne $account) {
            throw "profile-matrix task helper rejected account identity $([string]$request.account)."
        }
        $operation = [string]$request.operation
        if ($operation -cne 'Register' -and $operation -cne 'Unregister') {
            throw "profile-matrix task helper rejected operation $operation."
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
                -Action $taskAction `
                -Trigger $trigger `
                -Principal $principal `
                -Settings $settings `
                -Description 'ClusterYourCodex per-user background component' `
                -Force | Out-Null
            $task = Get-ScheduledTask -TaskName ([string]$request.taskName) -TaskPath '\' -ErrorAction Stop
            $ownership = Assert-ProfileMatrixTaskOwnership -Task $task -Sid $Sid -ExpectedAction $action
            $observedLogonType = [string]$task.Principal.LogonType
            if ($observedLogonType -notin @('Interactive', 'InteractiveToken', '3')) {
                throw "profile-matrix task helper observed unexpected task logon type $observedLogonType."
            }
        } else {
            $task = Get-ScheduledTask -TaskName ([string]$request.taskName) -TaskPath '\' -ErrorAction SilentlyContinue
            if ($null -ne $task) {
                $ownership = Assert-ProfileMatrixTaskOwnership -Task $task -Sid $Sid
                Stop-ScheduledTask -TaskName ([string]$request.taskName) -TaskPath '\' -ErrorAction SilentlyContinue
                Unregister-ScheduledTask -TaskName ([string]$request.taskName) -TaskPath '\' -Confirm:$false -ErrorAction Stop
            }
            if ($null -ne (Get-ScheduledTask -TaskName ([string]$request.taskName) -TaskPath '\' -ErrorAction SilentlyContinue)) {
                throw "profile-matrix task helper could not remove $([string]$request.taskName)."
            }
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
        runtime = 'not-started'
        error = $errorMessage
        completedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    try {
        $history = @()
        if (Test-Path -LiteralPath $EvidencePath -PathType Leaf) {
            try { $history = @(Get-Content -LiteralPath $EvidencePath -Raw | ConvertFrom-Json) } catch { $history = @() }
        }
        Write-ProfileMatrixAtomicJson -Path $EvidencePath -Value @($history + $record)
        Write-ProfileMatrixAtomicJson -Path $ResponsePath -Value $record
    } finally {
        Remove-Item -LiteralPath $RequestPath -Force -ErrorAction SilentlyContinue
    }
    return $true
}

function Remove-ProfileMatrixTaskHelperTasks {
    param([Parameter(Mandatory = $true)][string]$Sid)
    $profilePath = Get-ProfileMatrixProfilePathForSid -Sid $Sid
    foreach ($taskName in @('ClusterYourCodex Controller', 'ClusterYourCodex Worker')) {
        $task = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
        if ($null -eq $task) { continue }
        [void](Assert-ProfileMatrixTaskOwnership -Task $task -Sid $Sid)
        Stop-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false -ErrorAction Stop
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
    if (@($RequestedCases).Count -eq 4) { return $expected }
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
    $profile = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object { [string]$_.SID -ceq $Sid } |
        Select-Object -First 1
    if ($null -eq $profile) { return }
    if ([bool]$profile.Loaded) {
        Write-Warning "profile $Sid remains loaded; leaving its directory for the OS to reclaim"
        return
    }
    $localPath = [string]$profile.LocalPath
    $base = Resolve-ProfileMatrixPath (Join-Path $env:SystemDrive 'Users')
    $resolved = Resolve-ProfileMatrixPath $localPath
    $leaf = Split-Path -Leaf $resolved
    if (-not [string]::Equals((Split-Path -Parent $resolved), $base, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals($leaf, $UserName, [System.StringComparison]::Ordinal)) {
        throw "refusing to remove unexpected user profile path: $resolved"
    }
    if (Test-Path -LiteralPath $resolved) {
        Test-ProfileMatrixReparseFree -Root $resolved -AllowKnownCompatibilityJunctions
        Remove-ProfileMatrixKnownCompatibilityJunctions -ProfileRoot $resolved
        Test-ProfileMatrixReparseFree -Root $resolved
    }
    try { Remove-CimInstance -InputObject $profile -ErrorAction Stop } catch { Write-Warning "profile WMI removal failed for ${Sid}: $($_.Exception.Message)" }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue }
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
$cases = New-Object System.Collections.Generic.List[object]
$startedAt = [DateTimeOffset]::UtcNow
$failure = $null
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
                if ($isAdmin) { Add-LocalGroupMember -Group $adminGroup -Member $userName -ErrorAction Stop }
                $credential = [System.Management.Automation.PSCredential]::new("$env:COMPUTERNAME\$userName", $password)
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
            if ($CurrentUserOnly) {
                $output = @(& $windowsPowerShell @childArguments 1> $stdoutPath 2> $stderrPath)
                $exitCode = $LASTEXITCODE
            } else {
                $childArguments += @('-UseParentTaskHelper')
                $startArguments = $childArguments | ForEach-Object { ConvertTo-ProfileMatrixArgument ([string]$_) }
                $process = Start-Process -FilePath $windowsPowerShell -ArgumentList $startArguments -Credential $credential -LoadUserProfile -WorkingDirectory $caseRoot -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
                $output = @()
                # The disposable account cannot cross the task scheduler's
                # InteractiveToken boundary. Keep registration in the
                # elevated controller, but only for the exact request emitted
                # by the child and only while that child is alive.
                $taskRequestPath = Join-Path $caseRoot 'task-registration-request.json'
                $taskResponsePath = Join-Path $caseRoot 'task-registration-response.json'
                $taskHelperEvidencePath = Join-Path $caseRoot 'task-helper-evidence.json'
                while (-not $process.HasExited) {
                    [void](Invoke-ProfileMatrixTaskHelperRequest `
                        -CaseRoot $caseRoot `
                        -RequestPath $taskRequestPath `
                        -ResponsePath $taskResponsePath `
                        -EvidencePath $taskHelperEvidencePath `
                        -Sid $sid `
                        -UserName $userName)
                    Start-Sleep -Milliseconds 100
                }
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
                $process.WaitForExit()
                $exitCode = $process.ExitCode
            }
            if ($exitCode -ne 0) {
                $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw } else { '' }
                $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
                throw "case $case child exited $exitCode. stdout=$stdout stderr=$stderr"
            }
            Assert-ProfileMatrix (Test-Path -LiteralPath $receiptPath -PathType Leaf) "case $case wrote a receipt"
            $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
            Assert-ProfileMatrix ([string]$receipt.status -ceq 'passed') "case $case receipt is passed"
            Assert-ProfileMatrix ([string]$receipt.caseName -ceq $case) "case $case receipt binds the case name"
            Assert-ProfileMatrix ([string]$receipt.sid -ceq $sid) "case $case receipt binds the expected SID"
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
                        Stop-Process -Id $process.Id -Force -ErrorAction Stop
                        [void]$process.WaitForExit(10000)
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
                    try { Remove-ProfileMatrixTaskHelperTasks -Sid $sid } catch {
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
    $failure = $_
}

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
    error = if ($null -eq $failure) { $null } else { [string]$failure.Exception.Message }
}
$resultPath = Join-Path $work 'profile-matrix.json'
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 12 -Compress

if ($null -ne $failure) { throw $failure }
if (-not $KeepWorkRoot -and (Test-Path -LiteralPath $work)) {
    Test-ProfileMatrixReparseFree -Root $work
    Remove-Item -LiteralPath $work -Recurse -Force
}
