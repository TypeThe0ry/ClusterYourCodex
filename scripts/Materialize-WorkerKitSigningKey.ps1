#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-CycWindows {
    return [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [Runtime.InteropServices.OSPlatform]::Windows
    )
}

function Assert-CycPrivateKeyPermissions {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (Test-CycWindows) {
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
        $security = [IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]::new($Path))
        $owner = [Security.Principal.SecurityIdentifier]$security.GetOwner(
            [Security.Principal.SecurityIdentifier]
        )
        if ($owner.Value -cne $currentSid.Value) {
            throw 'Signing-key file owner is not the current runner SID.'
        }
        if (-not $security.AreAccessRulesProtected) {
            throw 'Signing-key file still inherits access rules.'
        }

        $required = @{
            $currentSid.Value = $false
            $systemSid.Value = $false
        }
        $rules = $security.GetAccessRules(
            $true,
            $true,
            [Security.Principal.SecurityIdentifier]
        )
        foreach ($rule in $rules) {
            $sid = ([Security.Principal.SecurityIdentifier]$rule.IdentityReference).Value
            if ($rule.IsInherited -or
                $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
                -not $required.ContainsKey($sid)) {
                throw "Signing-key file contains an unauthorized access rule for SID $sid."
            }
            $required[$sid] = $true
        }
        if ($required.Values -contains $false) {
            throw 'Signing-key file is missing the runner or SYSTEM access rule.'
        }
        return
    }

    $expected = [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite
    $actual = [IO.File]::GetUnixFileMode($Path)
    if ($actual -ne $expected) {
        throw "Signing-key file mode must be 0600 (observed: $actual)."
    }
}

$encoded = [Environment]::GetEnvironmentVariable('CYC_SIGNING_KEY_PEM_B64', 'Process')
if ([string]::IsNullOrWhiteSpace($encoded)) {
    throw 'CYC_WORKER_KIT_SIGNING_KEY_PEM_B64 is required; unsigned worker kits are forbidden.'
}

$bytes = $null
$fullPath = $null
try {
    try {
        $bytes = [Convert]::FromBase64String($encoded)
    }
    catch {
        throw 'CYC_WORKER_KIT_SIGNING_KEY_PEM_B64 is not valid Base64.'
    }
    if ($bytes.Length -lt 64 -or $bytes.Length -gt 65536) {
        throw 'Worker-kit signing key length is invalid.'
    }

    $fullPath = [IO.Path]::GetFullPath($OutputPath)
    $parentPath = [IO.Path]::GetDirectoryName($fullPath)
    if ([string]::IsNullOrWhiteSpace($parentPath) -or
        -not (Test-Path -LiteralPath $parentPath -PathType Container)) {
        throw 'Signing-key output parent must be an existing directory.'
    }
    $parent = Get-Item -LiteralPath $parentPath -Force
    if (($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Signing-key output parent must not be a symlink or reparse point.'
    }
    if (Test-Path -LiteralPath $fullPath) {
        throw 'Signing-key output path must not already exist.'
    }

    # Create an empty exclusive file, lock down its permissions, then write the
    # secret. No private-key byte exists on disk before the ACL/mode is verified.
    $stream = [IO.File]::Open(
        $fullPath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    $stream.Dispose()

    if (Test-CycWindows) {
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
        $security = [Security.AccessControl.FileSecurity]::new()
        $security.SetOwner($currentSid)
        $security.SetAccessRuleProtection($true, $false)
        foreach ($sid in @($currentSid, $systemSid)) {
            $security.AddAccessRule(
                [Security.AccessControl.FileSystemAccessRule]::new(
                    $sid,
                    [Security.AccessControl.FileSystemRights]::FullControl,
                    [Security.AccessControl.AccessControlType]::Allow
                )
            )
        }
        [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($fullPath), $security)
    }
    else {
        $privateMode = [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite
        [IO.File]::SetUnixFileMode($fullPath, $privateMode)
    }
    Assert-CycPrivateKeyPermissions -Path $fullPath

    $stream = [IO.File]::Open(
        $fullPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    try {
        $stream.SetLength(0)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }

    if ((Get-Item -LiteralPath $fullPath -Force).Length -ne $bytes.Length) {
        throw 'Signing-key file length verification failed.'
    }
    Assert-CycPrivateKeyPermissions -Path $fullPath
}
catch {
    if (-not [string]::IsNullOrWhiteSpace($fullPath) -and
        (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        [IO.File]::Delete($fullPath)
    }
    throw
}
finally {
    if ($null -ne $bytes) {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
    $encoded = $null
}
