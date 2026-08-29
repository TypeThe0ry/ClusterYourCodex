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
        [Parameter(Mandatory = $true)][string]$BasePath
    )

    $observed = New-Object System.Collections.Generic.List[string]
    foreach ($propertyName in @('Target', 'ResolvedTarget', 'LinkTarget')) {
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
            if ($null -ne $normalized) { [void]$observed.Add($normalized) }
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
    # "Application Data". They are created by the OS, not by the package
    # under test. Keep the exception narrow: only a direct child of a real
    # C:\Users\<name> profile root, only the documented junction name, and
    # only when its target is the exact in-profile destination we expect.
    $usersRoot = Resolve-ProfileMatrixPath (Join-Path $env:SystemDrive 'Users')
    $resolvedProfileRoot = Resolve-ProfileMatrixPath $ProfileRoot
    if (-not [string]::Equals((Split-Path -Parent $resolvedProfileRoot), $usersRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    if (-not [string]::Equals((Split-Path -Parent ([string]$Item.FullName)), $resolvedProfileRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
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
    }
    if (-not $knownTargets.ContainsKey([string]$Item.Name)) { return $false }
    $linkTypeProperty = $Item.PSObject.Properties['LinkType']
    # Windows PowerShell 5.1 has no LinkType projection. If the property is
    # present, keep the old strict check; if it is absent/blank, the native
    # fsutil fallback below is the authoritative type check.
    if ($null -ne $linkTypeProperty -and
        -not [string]::IsNullOrWhiteSpace([string]$linkTypeProperty.Value) -and
        -not [string]::Equals([string]$linkTypeProperty.Value, 'Junction', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    $expectedTarget = Resolve-ProfileMatrixPath (Join-Path $resolvedProfileRoot $knownTargets[[string]$Item.Name])
    $basePath = Split-Path -Parent ([string]$Item.FullName)
    $targets = @(Get-ProfileMatrixLinkTargets -Item $Item -BasePath $basePath)
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
    foreach ($item in @(Get-ChildItem -LiteralPath $resolved -Force)) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
            continue
        }
        if (-not (Test-ProfileMatrixKnownCompatibilityJunction -ProfileRoot $resolved -Item $item)) {
            throw "profile matrix refuses an unexpected profile reparse point during cleanup: $($item.FullName)"
        }
        # Remove the link itself, never its target. Do this before the final
        # recursive profile deletion because Windows PowerShell 5.1 may walk
        # directory junctions when -Recurse is used.
        Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
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
                $startArguments = $childArguments | ForEach-Object { ConvertTo-ProfileMatrixArgument ([string]$_) }
                $process = Start-Process -FilePath $windowsPowerShell -ArgumentList $startArguments -Credential $credential -LoadUserProfile -WorkingDirectory $caseRoot -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -Wait -PassThru
                $output = @()
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
            [void]$cases.Add($receipt)
        } catch {
            # Preserve the primary child/verification error so a later profile
            # cleanup problem cannot replace the useful root cause.
            $caseFailureRecord = $_
        } finally {
            if (-not $CurrentUserOnly) {
                if ($isAdmin -and $null -ne $sid) {
                    try { Remove-LocalGroupMember -Group $adminGroup -Member $userName -ErrorAction SilentlyContinue } catch { }
                }
                try { Remove-LocalUser -Name $userName -ErrorAction SilentlyContinue } catch { }
                if ($null -ne $sid) {
                    try {
                        Remove-ProfileMatrixUserProfile -Sid $sid -UserName $userName
                    } catch {
                        $caseCleanupFailureMessage = [string]$_.Exception.Message
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
