#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Install', 'Repair', 'Uninstall')]
    [string]$Action = 'Install',

    [string]$BundleRoot = $PSScriptRoot,

    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\ClusterYourCodexWorker'),

    [string]$DataRoot = (Join-Path $env:LOCALAPPDATA 'ClusterYourCodex\worker'),

    [string]$WorkspaceRoot = (Join-Path $env:LOCALAPPDATA 'ClusterYourCodex\worker\workspace'),

    [string]$EnrollmentFile,

    [ValidateSet('Auto', 'User', 'System')]
    [string]$Scope = 'Auto',

    [switch]$AllowOnBattery,

    [switch]$PairOnly,

    [switch]$PurgeData,

    [ValidateSet('None', 'AfterPair', 'AfterServiceRegistration', 'BeforeManifestWrite')]
    [string]$FailureInjection = 'None'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Schema = 'cyc.dev/windows-worker-install/v1'
$script:KitSchema = 'cyc.dev/worker-kit/v1'
$script:SignatureSchema = 'cyc.dev/worker-kit-signature/v1'
$script:PublisherKeyId = 'cyc-release-2026-02'
$script:PublisherPublicKeyBase64 = '__CYC_PUBLISHER_PUBLIC_KEY_BASE64__'
$script:TaskName = 'ClusterYourCodex Worker'
$script:MarkerName = '.clusteryourcodex-worker-owned'
$script:TransactionName = '.repair-transaction'
$script:TransactionSchema = 'cyc.dev/windows-worker-repair-transaction/v1'

function Resolve-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
}

function Test-ReparsePoint {
    param([Parameter(Mandatory = $true)][System.IO.FileSystemInfo]$Item)
    return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Assert-PathChainNoReparse {
    param([Parameter(Mandatory = $true)][string]$Path)
    $current = Resolve-NormalizedPath $Path
    while ($current -and (Test-Path -LiteralPath $current)) {
        $item = Get-Item -LiteralPath $current -Force
        if (Test-ReparsePoint $item) { throw "Path contains a reparse point: $current" }
        $parent = Split-Path -Parent $current
        if ($parent -eq $current) { break }
        $current = $parent
    }
}

function New-PrivateAcl {
    param([Parameter(Mandatory = $true)][bool]$Directory)
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $userSid = $identity.User
    $systemSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    $acl = if ($Directory) {
        New-Object System.Security.AccessControl.DirectorySecurity
    } else {
        New-Object System.Security.AccessControl.FileSecurity
    }
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($userSid)
    $inheritance = if ($Directory) {
        [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    } else {
        [System.Security.AccessControl.InheritanceFlags]::None
    }
    foreach ($sid in @($userSid, $systemSid)) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $sid,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        [void]$acl.AddAccessRule($rule)
    }
    return $acl
}

function Set-AclPortable {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileSystemInfo]$Item,
        [Parameter(Mandatory = $true)][System.Security.AccessControl.FileSystemSecurity]$Acl
    )
    if ($null -ne $Item.PSObject.Methods['SetAccessControl']) {
        $Item.SetAccessControl($Acl)
    } elseif ($Item.PSIsContainer) {
        [System.IO.FileSystemAclExtensions]::SetAccessControl([System.IO.DirectoryInfo]$Item, $Acl)
    } else {
        [System.IO.FileSystemAclExtensions]::SetAccessControl([System.IO.FileInfo]$Item, $Acl)
    }
}

function Protect-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    Assert-PathChainNoReparse -Path $Path
    [void](New-Item -ItemType Directory -Path $Path -Force)
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer -or (Test-ReparsePoint $item)) {
        throw "Private path is not a normal directory: $Path"
    }
    Set-AclPortable -Item $item -Acl (New-PrivateAcl -Directory $true)
}

function Protect-File {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or (Test-ReparsePoint $item)) {
        throw "Private path is not a normal file: $Path"
    }
    Set-AclPortable -Item $item -Acl (New-PrivateAcl -Directory $false)
}

function Test-ByteArrayEqual {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Left,
        [Parameter(Mandatory = $true)][byte[]]$Right
    )
    if ($Left.Length -ne $Right.Length) { return $false }
    $difference = 0
    for ($index = 0; $index -lt $Left.Length; $index++) {
        $difference = $difference -bor ($Left[$index] -bxor $Right[$index])
    }
    return ($difference -eq 0)
}

function Test-Ed25519Signature {
    param(
        [Parameter(Mandatory = $true)][byte[]]$PublicKey,
        [Parameter(Mandatory = $true)][byte[]]$Message,
        [Parameter(Mandatory = $true)][byte[]]$Signature
    )
    if (-not ('ClusterYourCodex.WorkerKitEd25519' -as [type])) {
        $source = @'
using System;
using System.Numerics;
using System.Security.Cryptography;

namespace ClusterYourCodex
{
    public static class WorkerKitEd25519
    {
        private sealed class Point
        {
            internal readonly BigInteger X, Y, Z, T;
            internal Point(BigInteger x, BigInteger y, BigInteger z, BigInteger t)
            { X = M(x); Y = M(y); Z = M(z); T = M(t); }
        }

        private static readonly BigInteger Q = (BigInteger.One << 255) - 19;
        private static readonly BigInteger L = (BigInteger.One << 252) +
            BigInteger.Parse("27742317777372353535851937790883648493");
        private static readonly BigInteger D = M(-121665 * Inv(new BigInteger(121666)));
        private static readonly BigInteger I = BigInteger.ModPow(2, (Q - 1) / 4, Q);
        private static readonly Point Identity = new Point(0, 1, 1, 0);

        private static BigInteger M(BigInteger value)
        {
            value %= Q;
            return value.Sign < 0 ? value + Q : value;
        }

        private static BigInteger Inv(BigInteger value)
        { return BigInteger.ModPow(M(value), Q - 2, Q); }

        private static BigInteger Little(byte[] bytes)
        {
            byte[] positive = new byte[bytes.Length + 1];
            Buffer.BlockCopy(bytes, 0, positive, 0, bytes.Length);
            return new BigInteger(positive);
        }

        private static Point Decode(byte[] encoded)
        {
            if (encoded == null || encoded.Length != 32) return null;
            byte[] copy = (byte[])encoded.Clone();
            int sign = copy[31] >> 7;
            copy[31] &= 0x7f;
            BigInteger y = Little(copy);
            if (y >= Q) return null;
            BigInteger y2 = M(y * y);
            BigInteger x2 = M((y2 - 1) * Inv(D * y2 + 1));
            BigInteger x = BigInteger.ModPow(x2, (Q + 3) / 8, Q);
            if (M(x * x - x2) != 0) x = M(x * I);
            if (M(x * x - x2) != 0 || (x.IsZero && sign != 0)) return null;
            if ((x.IsEven ? 0 : 1) != sign) x = Q - x;
            return new Point(x, y, 1, x * y);
        }

        private static Point Add(Point p, Point q)
        {
            BigInteger a = M((p.Y - p.X) * (q.Y - q.X));
            BigInteger b = M((p.Y + p.X) * (q.Y + q.X));
            BigInteger c = M(2 * D * p.T * q.T);
            BigInteger d = M(2 * p.Z * q.Z);
            BigInteger e = M(b - a), f = M(d - c), g = M(d + c), h = M(b + a);
            return new Point(e * f, g * h, f * g, e * h);
        }

        private static Point Double(Point p)
        {
            BigInteger a = M(p.X * p.X), b = M(p.Y * p.Y), c = M(2 * p.Z * p.Z);
            BigInteger d = M(-a), e = M((p.X + p.Y) * (p.X + p.Y) - a - b);
            BigInteger g = M(d + b), f = M(g - c), h = M(d - b);
            return new Point(e * f, g * h, f * g, e * h);
        }

        private static Point Multiply(Point p, BigInteger scalar)
        {
            Point result = Identity;
            while (scalar > 0)
            {
                if (!scalar.IsEven) result = Add(result, p);
                p = Double(p);
                scalar >>= 1;
            }
            return result;
        }

        private static bool Equal(Point p, Point q)
        { return M(p.X * q.Z - q.X * p.Z).IsZero && M(p.Y * q.Z - q.Y * p.Z).IsZero; }

        private static bool PrimeOrder(Point p)
        { return p != null && !Equal(p, Identity) && Equal(Multiply(p, L), Identity); }

        public static bool Verify(byte[] publicKey, byte[] message, byte[] signature)
        {
            try
            {
                if (publicKey == null || publicKey.Length != 32 || signature == null || signature.Length != 64)
                    return false;
                byte[] rBytes = new byte[32], sBytes = new byte[32];
                Buffer.BlockCopy(signature, 0, rBytes, 0, 32);
                Buffer.BlockCopy(signature, 32, sBytes, 0, 32);
                BigInteger s = Little(sBytes);
                if (s >= L) return false;
                Point a = Decode(publicKey), r = Decode(rBytes);
                if (!PrimeOrder(a) || !PrimeOrder(r)) return false;
                byte[] hashInput = new byte[64 + message.Length];
                Buffer.BlockCopy(rBytes, 0, hashInput, 0, 32);
                Buffer.BlockCopy(publicKey, 0, hashInput, 32, 32);
                Buffer.BlockCopy(message, 0, hashInput, 64, message.Length);
                byte[] digest;
                using (SHA512 sha = SHA512.Create()) { digest = sha.ComputeHash(hashInput); }
                BigInteger h = Little(digest) % L;
                byte[] baseEncoded = new byte[32];
                baseEncoded[0] = 0x58;
                for (int index = 1; index < 32; index++) baseEncoded[index] = 0x66;
                Point b = Decode(baseEncoded);
                return Equal(Multiply(b, s), Add(r, Multiply(a, h)));
            }
            catch { return false; }
        }
    }
}
'@
        # BigInteger lives in System.Numerics on Windows PowerShell/.NET Framework
        # and is type-forwarded to System.Runtime.Numerics on PowerShell 7/.NET.
        # Resolve the assembly that actually owns the loaded type so the same
        # verifier works under both hosts without relying on a runtime-specific
        # assembly name.
        $references = @(
            ([System.Numerics.BigInteger].Assembly).Location,
            ([System.Security.Cryptography.SHA512].Assembly).Location
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
        if ($references.Count -eq 0) {
            $references = @('System.Numerics.dll', 'System.Security.dll')
        }
        Add-Type -TypeDefinition $source -ReferencedAssemblies $references -ErrorAction Stop
    }
    return [ClusterYourCodex.WorkerKitEd25519]::Verify($PublicKey, $Message, $Signature)
}

function Read-KitManifest {
    param([Parameter(Mandatory = $true)][string]$Root)
    $path = Join-Path $Root 'worker-kit.json'
    $signaturePath = Join-Path $Root 'worker-kit.sig'
    $checksumsPath = Join-Path $Root 'SHA256SUMS'
    $expectedKitNames = @('cyc-worker.exe', 'Install-Worker.ps1', 'worker-kit.json', 'worker-kit.sig', 'SHA256SUMS') | Sort-Object
    $kitEntries = @(Get-ChildItem -LiteralPath $Root -Force)
    $actualKitNames = @($kitEntries | ForEach-Object { $_.Name } | Sort-Object)
    if ($kitEntries.Count -ne $expectedKitNames.Count -or
        (($actualKitNames -join "`n") -cne ($expectedKitNames -join "`n")) -or
        @($kitEntries | Where-Object { $_.PSIsContainer -or (Test-ReparsePoint $_) }).Count -ne 0) {
        throw 'Worker kit file set must contain exactly five normal files.'
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'worker-kit.json is missing.' }
    if (-not (Test-Path -LiteralPath $signaturePath -PathType Leaf)) { throw 'worker-kit.sig is missing.' }
    if (-not (Test-Path -LiteralPath $checksumsPath -PathType Leaf)) { throw 'SHA256SUMS is missing.' }
    $item = Get-Item -LiteralPath $path -Force
    $checksumsItem = Get-Item -LiteralPath $checksumsPath -Force
    $signatureItem = Get-Item -LiteralPath $signaturePath -Force
    if ((Test-ReparsePoint $item) -or $item.Length -gt 1MB -or
        (Test-ReparsePoint $signatureItem) -or $signatureItem.Length -gt 16KB -or
        (Test-ReparsePoint $checksumsItem) -or $checksumsItem.Length -gt 64KB) {
        throw 'Worker-kit metadata is invalid.'
    }
    $checksumMap = @{}
    $checksumLines = @(Get-Content -LiteralPath $checksumsPath)
    if ($checksumLines.Count -ne 4) { throw 'SHA256SUMS must contain exactly four signed-kit files.' }
    foreach ($line in $checksumLines) {
        if ($line -notmatch '^([0-9A-Fa-f]{64})  ([0-9A-Za-z._-]+)$') {
            throw 'SHA256SUMS contains an invalid entry.'
        }
        $name = $Matches[2]
        if ($checksumMap.ContainsKey($name)) { throw "Duplicate checksum entry: $name" }
        $checksumMap[$name] = $Matches[1].ToLowerInvariant()
    }
    $expectedNames = @('cyc-worker.exe', 'Install-Worker.ps1', 'worker-kit.json', 'worker-kit.sig')
    foreach ($name in $expectedNames) {
        if (-not $checksumMap.ContainsKey($name)) { throw "Missing checksum entry: $name" }
        $candidate = Join-Path $Root $name
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw "Worker kit file is missing: $name" }
        $candidateItem = Get-Item -LiteralPath $candidate -Force
        if (Test-ReparsePoint $candidateItem) { throw "Worker kit file is a reparse point: $name" }
        $candidateHash = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($candidateHash -ne $checksumMap[$name]) { throw "Worker kit checksum failed: $name" }
    }
    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $manifestBytes = [System.IO.File]::ReadAllBytes($path)
    $signatureEnvelopeBytes = [System.IO.File]::ReadAllBytes($signaturePath)
    if ($manifestBytes.Length -eq 0 -or $manifestBytes[$manifestBytes.Length - 1] -ne 0x0a -or
        $manifestBytes -contains 0x0d -or $signatureEnvelopeBytes.Length -eq 0 -or
        $signatureEnvelopeBytes[$signatureEnvelopeBytes.Length - 1] -ne 0x0a -or
        $signatureEnvelopeBytes -contains 0x0d) {
        throw 'Worker-kit signed metadata is not canonical UTF-8 JSON plus LF.'
    }
    try {
        $manifestText = $strictUtf8.GetString($manifestBytes)
        $signatureEnvelopeText = $strictUtf8.GetString($signatureEnvelopeBytes)
        $manifest = $manifestText | ConvertFrom-Json
        $signatureEnvelope = $signatureEnvelopeText | ConvertFrom-Json
    } catch {
        throw 'Worker-kit signed metadata is not valid UTF-8 JSON.'
    }
    $canonicalManifest = [System.Text.Encoding]::UTF8.GetBytes(($manifest | ConvertTo-Json -Depth 8 -Compress) + "`n")
    $canonicalEnvelope = [System.Text.Encoding]::UTF8.GetBytes(($signatureEnvelope | ConvertTo-Json -Depth 4 -Compress) + "`n")
    if (-not (Test-ByteArrayEqual -Left $manifestBytes -Right $canonicalManifest) -or
        -not (Test-ByteArrayEqual -Left $signatureEnvelopeBytes -Right $canonicalEnvelope)) {
        throw 'Worker-kit signed metadata is not canonical.'
    }
    if (@($signatureEnvelope.PSObject.Properties).Count -ne 6 -or
        $signatureEnvelope.schemaVersion -ne $script:SignatureSchema -or
        $signatureEnvelope.algorithm -ne 'Ed25519' -or
        $signatureEnvelope.keyId -ne $script:PublisherKeyId -or
        $signatureEnvelope.signedObject -ne 'worker-kit.json' -or
        [string]$signatureEnvelope.manifestSha256 -notmatch '^[0-9a-f]{64}$' -or
        [string]$signatureEnvelope.signature -notmatch '^[A-Za-z0-9+/]{86}==$') {
        throw 'Worker-kit publisher signature envelope is invalid.'
    }
    try {
        $signatureBytes = [Convert]::FromBase64String([string]$signatureEnvelope.signature)
    } catch {
        throw 'Worker-kit publisher signature encoding is invalid.'
    }
    if ($signatureBytes.Length -ne 64) { throw 'Worker-kit publisher signature length is invalid.' }
    $manifestDigest = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($manifestDigest -cne [string]$signatureEnvelope.manifestSha256) {
        throw 'Worker-kit publisher signature is not bound to this manifest.'
    }
    try {
        $publisherPublicKey = [Convert]::FromBase64String($script:PublisherPublicKeyBase64)
    } catch {
        throw 'Worker-kit publisher trust root is invalid.'
    }
    if ($publisherPublicKey.Length -ne 32 -or
        [Convert]::ToBase64String($publisherPublicKey) -cne $script:PublisherPublicKeyBase64) {
        throw 'Worker-kit publisher trust root is invalid.'
    }
    if (-not (Test-Ed25519Signature -PublicKey $publisherPublicKey -Message $manifestBytes -Signature $signatureBytes)) {
        throw 'Worker-kit publisher signature verification failed.'
    }
    if ($manifest.schemaVersion -ne $script:KitSchema -or $manifest.os -ne 'windows' -or
        $manifest.target -ne 'windows-x86_64' -or $manifest.architecture -ne 'x86_64') {
        throw 'Worker kit does not target Windows.'
    }
    $worker = @($manifest.files | Where-Object { $_.role -eq 'worker' })
    $lifecycle = @($manifest.files | Where-Object { $_.role -eq 'lifecycle' })
    if (@($manifest.files).Count -ne 2 -or $worker.Count -ne 1 -or
        $worker[0].path -ne 'cyc-worker.exe' -or $lifecycle.Count -ne 1 -or
        $lifecycle[0].path -ne 'Install-Worker.ps1') {
        throw 'Worker kit must contain exactly one cyc-worker.exe payload.'
    }
    $binary = Join-Path $Root 'cyc-worker.exe'
    if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { throw 'cyc-worker.exe is missing.' }
    $binaryItem = Get-Item -LiteralPath $binary -Force
    if ((Test-ReparsePoint $binaryItem) -or $binaryItem.Length -ne [long]$worker[0].sizeBytes) {
        throw 'cyc-worker.exe size or file type is invalid.'
    }
    $actual = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne [string]$worker[0].sha256 -or $actual -ne $checksumMap['cyc-worker.exe']) {
        throw 'cyc-worker.exe failed SHA-256 verification.'
    }
    $stream = [System.IO.File]::Open($binary, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $reader = New-Object System.IO.BinaryReader($stream)
        if ($reader.ReadUInt16() -ne 0x5a4d) { throw 'cyc-worker.exe is not a PE executable.' }
        $stream.Position = 0x3c
        $peOffset = $reader.ReadInt32()
        if ($peOffset -lt 0 -or $peOffset + 6 -gt $stream.Length) { throw 'cyc-worker.exe has an invalid PE header.' }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550 -or $reader.ReadUInt16() -ne 0x8664) {
            throw 'cyc-worker.exe is not a Windows x64 executable.'
        }
    } finally {
        $stream.Dispose()
    }
    return [PSCustomObject]@{ manifest = $manifest; binary = $binary; sha256 = $actual }
}

function Get-WorkerTaskSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string]$Config,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][ValidateSet('User', 'System')][string]$ResolvedScope
    )
    $tasks = @(Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue |
        Where-Object { $null -ne $_ })
    if ($tasks.Count -eq 0) { return $null }
    $rootTasks = @($tasks | Where-Object {
        $null -ne $_.PSObject.Properties['TaskPath'] -and [string]$_.TaskPath -ceq '\'
    })
    if ($rootTasks.Count -ne 1 -or $tasks.Count -ne $rootTasks.Count) {
        throw 'Worker scheduled task name is already claimed outside the installer-owned root task path.'
    }
    $task = $rootTasks[0]
    Assert-WorkerTaskOwnership `
        -Task $task `
        -Executable $Executable `
        -Config $Config `
        -WorkingDirectory $WorkingDirectory `
        -ResolvedScope $ResolvedScope
    return [PSCustomObject]@{
        Xml = Export-ScheduledTask -TaskName $script:TaskName -TaskPath '\'
        WasRunning = ([string]$task.State -eq 'Running')
    }
}

function Restore-WorkerTask {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string]$Config,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][ValidateSet('User', 'System')][string]$ResolvedScope
    )
    Register-ScheduledTask -TaskName $script:TaskName -TaskPath '\' -Xml $Snapshot.Xml -Force | Out-Null
    $restored = Get-WorkerTaskSnapshot `
        -Executable $Executable `
        -Config $Config `
        -WorkingDirectory $WorkingDirectory `
        -ResolvedScope $ResolvedScope
    if ($null -eq $restored) { throw 'Worker scheduled task rollback did not restore an owned task.' }
    if ($Snapshot.WasRunning) {
        Start-ScheduledTask -TaskName $script:TaskName -TaskPath '\'
        Wait-WorkerTaskRunning -TaskName $script:TaskName
    }
}

function Register-WorkerTask {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string]$Config,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][ValidateSet('User', 'System')][string]$ResolvedScope,
        [Parameter(Mandatory = $true)][bool]$PermitBattery
    )
    $taskAction = New-ScheduledTaskAction -Execute $Executable -Argument ('run --config "' + $Config + '"') -WorkingDirectory $WorkingDirectory
    if ($ResolvedScope -eq 'System') {
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    } else {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
        $principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
    }
    $settingsParameters = @{
        MultipleInstances = 'IgnoreNew'
        StartWhenAvailable = $true
        RestartCount = 3
        RestartInterval = (New-TimeSpan -Minutes 1)
        ExecutionTimeLimit = [TimeSpan]::Zero
    }
    if ($PermitBattery) {
        $settingsParameters.AllowStartIfOnBatteries = $true
        $settingsParameters.DontStopIfGoingOnBatteries = $true
    }
    $settings = New-ScheduledTaskSettingsSet @settingsParameters
    Register-ScheduledTask -TaskName $script:TaskName -TaskPath '\' -Action $taskAction -Trigger $trigger -Principal $principal -Settings $settings -Description 'ClusterYourCodex managed worker' -Force | Out-Null
    $registered = Get-WorkerTaskSnapshot `
        -Executable $Executable `
        -Config $Config `
        -WorkingDirectory $WorkingDirectory `
        -ResolvedScope $ResolvedScope
    if ($null -eq $registered) { throw 'Worker scheduled task registration did not produce an owned task.' }
}

function Test-IsAdministrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-ServiceScope {
    param([Parameter(Mandatory = $true)][ValidateSet('Auto', 'User', 'System')][string]$RequestedScope)
    if ($RequestedScope -eq 'Auto') {
        if (Test-IsAdministrator) { return 'System' }
        return 'User'
    }
    if ($RequestedScope -eq 'System' -and -not (Test-IsAdministrator)) {
        throw 'System worker scope requires an elevated administrator SSH session.'
    }
    return $RequestedScope
}

function Resolve-AccountSid {
    param([Parameter(Mandatory = $true)][string]$Account)
    if ([string]::IsNullOrWhiteSpace($Account)) { return $null }
    if ($Account -match '^S-[0-9-]+$') {
        try { return (New-Object System.Security.Principal.SecurityIdentifier($Account)).Value } catch { return $null }
    }
    if ($Account -ieq 'SYSTEM' -or $Account -ieq 'NT AUTHORITY\SYSTEM') {
        return 'S-1-5-18'
    }
    try {
        $translated = (New-Object System.Security.Principal.NTAccount($Account)).Translate(
            [System.Security.Principal.SecurityIdentifier]
        )
        return $translated.Value
    } catch {
        return $null
    }
}

function Get-ExpectedWorkerTaskPrincipalSid {
    param([Parameter(Mandatory = $true)][ValidateSet('User', 'System')][string]$ResolvedScope)
    if ($ResolvedScope -eq 'System') { return 'S-1-5-18' }
    return [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Assert-WorkerTaskOwnership {
    param(
        [Parameter(Mandatory = $true)]$Task,
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string]$Config,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][ValidateSet('User', 'System')][string]$ResolvedScope
    )
    if ([string]$Task.TaskPath -cne '\') {
        throw 'Worker scheduled task is outside the installer-owned root task path.'
    }
    $actions = @($Task.Actions)
    if ($actions.Count -ne 1) { throw 'Worker scheduled task action set is not installer-owned.' }
    $action = $actions[0]
    $actualExecutable = Resolve-NormalizedPath ([string]$action.Execute)
    $actualWorkingDirectory = Resolve-NormalizedPath ([string]$action.WorkingDirectory)
    $expectedArguments = 'run --config "' + $Config + '"'
    if (-not [string]::Equals($actualExecutable, $Executable, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$action.Arguments, $expectedArguments, [System.StringComparison]::Ordinal) -or
        -not [string]::Equals($actualWorkingDirectory, $WorkingDirectory, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Worker scheduled task action is not bound to the installer-owned worker roots.'
    }
    $principal = if ($null -ne $Task.Principal) { [string]$Task.Principal.UserId } else { '' }
    $actualPrincipalSid = Resolve-AccountSid $principal
    $expectedPrincipalSid = Get-ExpectedWorkerTaskPrincipalSid -ResolvedScope $ResolvedScope
    if ([string]::IsNullOrWhiteSpace($actualPrincipalSid) -or
        -not [string]::Equals($actualPrincipalSid, $expectedPrincipalSid, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Worker scheduled task principal is not bound to the current installer identity.'
    }
}

function Wait-WorkerTaskRunning {
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [int]$TimeoutSeconds = 10
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $task = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction Stop
        if ([string]$task.State -eq 'Running') { return }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    $details = Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue
    $lastResult = if ($details) { [string]$details.LastTaskResult } else { 'unknown' }
    throw "Worker task did not remain running (state=$([string]$task.State), lastResult=$lastResult)."
}

function Stop-AndRemoveTask {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string]$Config,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][ValidateSet('User', 'System')][string]$ResolvedScope
    )
    $snapshot = Get-WorkerTaskSnapshot `
        -Executable $Executable `
        -Config $Config `
        -WorkingDirectory $WorkingDirectory `
        -ResolvedScope $ResolvedScope
    if ($null -ne $snapshot) {
        Stop-ScheduledTask -TaskName $script:TaskName -TaskPath '\' -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $script:TaskName -TaskPath '\' -Confirm:$false
        if ($null -ne (Get-WorkerTaskSnapshot `
                -Executable $Executable `
                -Config $Config `
                -WorkingDirectory $WorkingDirectory `
                -ResolvedScope $ResolvedScope)) {
            throw 'Worker scheduled task remained after installer-owned removal.'
        }
    }
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )
    $temporary = $Path + '.new-' + [Guid]::NewGuid().ToString('N')
    try {
        [System.IO.File]::WriteAllText($temporary, (($Value | ConvertTo-Json -Depth 8) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
        Protect-File -Path $temporary
        Move-Item -LiteralPath $temporary -Destination $Path -Force
        Protect-File -Path $Path
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Read-WorkerUtf8Json {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label,
        [int64]$MaximumBytes = 1MB
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label is missing."
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -le 0 -or $item.Length -gt $MaximumBytes) {
        throw "$Label is not a bounded regular file."
    }
    try {
        [byte[]]$bytes = [System.IO.File]::ReadAllBytes($item.FullName)
        $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
        $offset = if ($bytes.Length -ge 3 -and
            $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
        $raw = $utf8Strict.GetString($bytes, $offset, $bytes.Length - $offset)
        $converter = Get-Command ConvertFrom-Json -CommandType Cmdlet -ErrorAction Stop
        if ($converter.Parameters.ContainsKey('DateKind')) {
            return ConvertFrom-Json -InputObject $raw -DateKind String
        }
        return ConvertFrom-Json -InputObject $raw
    } catch {
        throw "$Label contains invalid UTF-8 JSON."
    }
}

function Get-WorkerIdentityFiles {
    param([Parameter(Mandatory = $true)][string]$DataRoot)
    if (-not (Test-Path -LiteralPath $DataRoot -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $DataRoot -Force -File | Where-Object {
        $_.Name -eq 'config.json' -or
        $_.Name.StartsWith('config.', [System.StringComparison]::OrdinalIgnoreCase) -or
        $_.Name.EndsWith('.credential', [System.StringComparison]::OrdinalIgnoreCase)
    })
}

function Assert-TransactionTreeSafe {
    param(
        [Parameter(Mandatory = $true)][string]$TransactionRoot,
        [Parameter(Mandatory = $true)][string]$DataRoot
    )
    $resolvedTransaction = Resolve-NormalizedPath $TransactionRoot
    $resolvedData = Resolve-NormalizedPath $DataRoot
    $prefix = $resolvedData + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedTransaction.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals((Split-Path -Leaf $resolvedTransaction), $script:TransactionName, [System.StringComparison]::Ordinal)) {
        throw 'Worker repair transaction path escaped the owned data root.'
    }
    if (-not (Test-Path -LiteralPath $resolvedTransaction -PathType Container)) {
        throw 'Worker repair transaction directory is missing.'
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $resolvedTransaction -Force -Recurse)) {
        if (Test-ReparsePoint $item) { throw 'Worker repair transaction contains a reparse point.' }
    }
}

function Remove-WorkerTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$TransactionRoot,
        [Parameter(Mandatory = $true)][string]$DataRoot
    )
    if (-not (Test-Path -LiteralPath $TransactionRoot)) { return }
    Assert-TransactionTreeSafe -TransactionRoot $TransactionRoot -DataRoot $DataRoot
    Remove-Item -LiteralPath (Resolve-NormalizedPath $TransactionRoot) -Recurse -Force
}

function Remove-WorkerTransactionStaging {
    param(
        [Parameter(Mandatory = $true)][string]$StagingRoot,
        [Parameter(Mandatory = $true)][string]$DataRoot
    )
    if (-not (Test-Path -LiteralPath $StagingRoot)) { return }
    $resolvedStaging = Resolve-NormalizedPath $StagingRoot
    $resolvedData = Resolve-NormalizedPath $DataRoot
    $prefix = $resolvedData + [System.IO.Path]::DirectorySeparatorChar
    $leaf = Split-Path -Leaf $resolvedStaging
    if (-not $resolvedStaging.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not $leaf.StartsWith(($script:TransactionName + '.new-'), [System.StringComparison]::Ordinal)) {
        throw 'Worker repair transaction staging path escaped the owned data root.'
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $resolvedStaging -Force -Recurse)) {
        if (Test-ReparsePoint $item) { throw 'Worker repair transaction staging contains a reparse point.' }
    }
    Remove-Item -LiteralPath $resolvedStaging -Recurse -Force
}

function New-WorkerTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$TransactionRoot,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$InstallManifestPath,
        [Parameter(Mandatory = $true)][string]$WorkerBinaryPath,
        $TaskSnapshot
    )
    if (Test-Path -LiteralPath $TransactionRoot) {
        throw 'A worker repair transaction is already present.'
    }
    $stagingRoot = $TransactionRoot + '.new-' + [Guid]::NewGuid().ToString('N')
    try {
        Protect-Directory -Path $stagingRoot
        $identityRoot = Join-Path $stagingRoot 'identity'
        Protect-Directory -Path $identityRoot

        foreach ($source in @(Get-WorkerIdentityFiles -DataRoot $DataRoot)) {
            if (Test-ReparsePoint $source) { throw 'Worker identity storage contains a reparse point.' }
            $destination = Join-Path $identityRoot $source.Name
            Copy-Item -LiteralPath $source.FullName -Destination $destination
            Protect-File -Path $destination
        }

        $manifestExisted = Test-Path -LiteralPath $InstallManifestPath -PathType Leaf
        if ((Test-Path -LiteralPath $InstallManifestPath) -and -not $manifestExisted) {
            throw 'Existing install manifest is not a regular file.'
        }
        if ($manifestExisted) {
            $manifestItem = Get-Item -LiteralPath $InstallManifestPath -Force
            if (Test-ReparsePoint $manifestItem) { throw 'Existing install manifest is a reparse point.' }
            $manifestBackup = Join-Path $stagingRoot 'install-manifest.json'
            Copy-Item -LiteralPath $InstallManifestPath -Destination $manifestBackup
            Protect-File -Path $manifestBackup
        }

        $binaryExisted = Test-Path -LiteralPath $WorkerBinaryPath -PathType Leaf
        if ((Test-Path -LiteralPath $WorkerBinaryPath) -and -not $binaryExisted) {
            throw 'Existing worker binary is not a regular file.'
        }
        if ($binaryExisted) {
            $binaryItem = Get-Item -LiteralPath $WorkerBinaryPath -Force
            if (Test-ReparsePoint $binaryItem) { throw 'Existing worker binary is a reparse point.' }
            $binaryBackup = Join-Path $stagingRoot 'cyc-worker.exe'
            Copy-Item -LiteralPath $WorkerBinaryPath -Destination $binaryBackup
            Protect-File -Path $binaryBackup
        }

        $taskExisted = $null -ne $TaskSnapshot
        if ($taskExisted) {
            $taskXml = Join-Path $stagingRoot 'task.xml'
            [System.IO.File]::WriteAllText($taskXml, [string]$TaskSnapshot.Xml, (New-Object System.Text.UTF8Encoding($false)))
            Protect-File -Path $taskXml
        }
        Write-JsonAtomic -Path (Join-Path $stagingRoot 'state.json') -Value ([ordered]@{
            schemaVersion = $script:TransactionSchema
            binaryExisted = [bool]$binaryExisted
            manifestExisted = [bool]$manifestExisted
            taskExisted = [bool]$taskExisted
            taskWasRunning = [bool]($taskExisted -and $TaskSnapshot.WasRunning)
        })
        [System.IO.Directory]::Move($stagingRoot, $TransactionRoot)
    } catch {
        if (Test-Path -LiteralPath $stagingRoot) {
            Remove-WorkerTransactionStaging -StagingRoot $stagingRoot -DataRoot $DataRoot
        }
        throw
    }
}

function Restore-WorkerTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$TransactionRoot,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$InstallManifestPath,
        [Parameter(Mandatory = $true)][string]$WorkerBinaryPath,
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][ValidateSet('User', 'System')][string]$ResolvedScope
    )
    Assert-TransactionTreeSafe -TransactionRoot $TransactionRoot -DataRoot $DataRoot
    $statePath = Join-Path $TransactionRoot 'state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { throw 'Worker repair transaction state is missing.' }
    $stateItem = Get-Item -LiteralPath $statePath -Force
    if ((Test-ReparsePoint $stateItem) -or $stateItem.Length -le 0 -or $stateItem.Length -gt 64KB) {
        throw 'Worker repair transaction state is unsafe.'
    }
    $state = Read-WorkerUtf8Json -Path $statePath -Label 'Worker repair transaction state' -MaximumBytes 64KB
    if ($state.schemaVersion -ne $script:TransactionSchema) { throw 'Unsupported worker repair transaction state.' }

    Stop-AndRemoveTask `
        -Executable $WorkerBinaryPath `
        -Config (Join-Path $DataRoot 'config.json') `
        -WorkingDirectory $WorkspaceRoot `
        -ResolvedScope $ResolvedScope

    foreach ($current in @(Get-WorkerIdentityFiles -DataRoot $DataRoot)) {
        if (Test-ReparsePoint $current) { throw 'Refusing to replace a reparse point in worker identity storage.' }
        Remove-Item -LiteralPath $current.FullName -Force
    }
    $identityRoot = Join-Path $TransactionRoot 'identity'
    if (-not (Test-Path -LiteralPath $identityRoot -PathType Container)) {
        throw 'Worker repair transaction identity snapshot is missing.'
    }
    foreach ($saved in @(Get-ChildItem -LiteralPath $identityRoot -Force -File)) {
        if (Test-ReparsePoint $saved) { throw 'Worker repair identity snapshot contains a reparse point.' }
        $destination = Join-Path $DataRoot $saved.Name
        Copy-Item -LiteralPath $saved.FullName -Destination $destination
        Protect-File -Path $destination
    }

    if (Test-Path -LiteralPath $InstallManifestPath) {
        $manifestItem = Get-Item -LiteralPath $InstallManifestPath -Force
        if ($manifestItem.PSIsContainer -or (Test-ReparsePoint $manifestItem)) {
            throw 'Refusing to replace an unsafe install manifest during rollback.'
        }
        Remove-Item -LiteralPath $InstallManifestPath -Force
    }
    if ([bool]$state.manifestExisted) {
        $manifestBackup = Join-Path $TransactionRoot 'install-manifest.json'
        if (-not (Test-Path -LiteralPath $manifestBackup -PathType Leaf)) { throw 'Install manifest rollback copy is missing.' }
        Copy-Item -LiteralPath $manifestBackup -Destination $InstallManifestPath
        Protect-File -Path $InstallManifestPath
    }

    if (Test-Path -LiteralPath $WorkerBinaryPath) {
        $binaryItem = Get-Item -LiteralPath $WorkerBinaryPath -Force
        if ($binaryItem.PSIsContainer -or (Test-ReparsePoint $binaryItem)) {
            throw 'Refusing to replace an unsafe worker binary during rollback.'
        }
        Remove-Item -LiteralPath $WorkerBinaryPath -Force
    }
    if ([bool]$state.binaryExisted) {
        $binaryBackup = Join-Path $TransactionRoot 'cyc-worker.exe'
        if (-not (Test-Path -LiteralPath $binaryBackup -PathType Leaf)) { throw 'Worker binary rollback copy is missing.' }
        Copy-Item -LiteralPath $binaryBackup -Destination $WorkerBinaryPath
        Protect-File -Path $WorkerBinaryPath
    }

    if ([bool]$state.taskExisted) {
        $taskXmlPath = Join-Path $TransactionRoot 'task.xml'
        if (-not (Test-Path -LiteralPath $taskXmlPath -PathType Leaf)) { throw 'Scheduled task rollback copy is missing.' }
        $taskSnapshot = [PSCustomObject]@{
            Xml = [System.IO.File]::ReadAllText($taskXmlPath)
            WasRunning = [bool]$state.taskWasRunning
        }
        Restore-WorkerTask `
            -Snapshot $taskSnapshot `
            -Executable $WorkerBinaryPath `
            -Config (Join-Path $DataRoot 'config.json') `
            -WorkingDirectory $WorkspaceRoot `
            -ResolvedScope $ResolvedScope
    }
    Remove-WorkerTransaction -TransactionRoot $TransactionRoot -DataRoot $DataRoot
}

function Invoke-FailureInjection {
    param(
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Actual
    )
    if ($Actual -eq $Expected) { throw "Injected worker repair failure at $Expected." }
}

function Assert-DefaultDataPurgeTarget {
    param([Parameter(Mandatory = $true)][string]$Path)
    $expected = Resolve-NormalizedPath (Join-Path $env:LOCALAPPDATA 'ClusterYourCodex\worker')
    $actual = Resolve-NormalizedPath $Path
    if (-not [string]::Equals($expected, $actual, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'PurgeData is limited to the default installer-owned worker data root.'
    }
    Assert-PathChainNoReparse -Path $actual
    $marker = Join-Path $actual $script:MarkerName
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf) -or
        (Test-ReparsePoint (Get-Item -LiteralPath $marker -Force))) {
        throw 'PurgeData requires the installer ownership marker.'
    }
}

$bundle = Resolve-NormalizedPath $BundleRoot
$install = Resolve-NormalizedPath $InstallRoot
$data = Resolve-NormalizedPath $DataRoot
$workspace = Resolve-NormalizedPath $WorkspaceRoot
foreach ($argumentPath in @($bundle, $install, $data, $workspace)) {
    if ($argumentPath.Contains('"') -or $argumentPath.Contains("`r") -or $argumentPath.Contains("`n")) {
        throw 'Worker installer paths must not contain quotes or line breaks.'
    }
}
$manifestPath = Join-Path $data 'install-manifest.json'
$configPath = Join-Path $data 'config.json'
$workerPath = Join-Path $install 'cyc-worker.exe'
$markerPath = Join-Path $data $script:MarkerName
$transactionPath = Join-Path $data $script:TransactionName
$resolvedScope = Resolve-ServiceScope -RequestedScope $Scope
$ownedInstallation = $false
if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
    $markerItem = Get-Item -LiteralPath $markerPath -Force
    if (-not (Test-ReparsePoint $markerItem)) {
        $ownedInstallation = ((Get-Content -LiteralPath $markerPath -Raw).Trim() -eq $script:Schema)
    }
}
if (Test-Path -LiteralPath $data -PathType Container) {
    foreach ($stagingDirectory in @(Get-ChildItem -LiteralPath $data -Force -Directory | Where-Object {
        $_.Name.StartsWith(($script:TransactionName + '.new-'), [System.StringComparison]::Ordinal)
    })) {
        if (-not $ownedInstallation) { throw 'Found worker repair staging without a valid ownership marker.' }
        Remove-WorkerTransactionStaging -StagingRoot $stagingDirectory.FullName -DataRoot $data
    }
}
if (Test-Path -LiteralPath $transactionPath) {
    if (-not $ownedInstallation) { throw 'Found a worker repair transaction without a valid ownership marker.' }
    $commitPath = Join-Path $transactionPath 'committed'
    if (Test-Path -LiteralPath $commitPath -PathType Leaf) {
        $commitItem = Get-Item -LiteralPath $commitPath -Force
        if (Test-ReparsePoint $commitItem) { throw 'Worker repair commit marker is a reparse point.' }
        Remove-WorkerTransaction -TransactionRoot $transactionPath -DataRoot $data
    } else {
        Restore-WorkerTransaction `
            -TransactionRoot $transactionPath `
            -DataRoot $data `
            -InstallManifestPath $manifestPath `
            -WorkerBinaryPath $workerPath `
            -WorkspaceRoot $workspace `
            -ResolvedScope $resolvedScope
    }
}
if ($ownedInstallation -and (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    $recordedManifestItem = Get-Item -LiteralPath $manifestPath -Force
    if ((Test-ReparsePoint $recordedManifestItem) -or $recordedManifestItem.Length -gt 1MB) {
        throw 'Existing install manifest is unsafe.'
    }
    $recordedManifest = Read-WorkerUtf8Json -Path $manifestPath -Label 'Existing worker install manifest'
    if ($recordedManifest.schemaVersion -ne $script:Schema -or
        -not [string]::Equals((Resolve-NormalizedPath $recordedManifest.installRoot), $install, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals((Resolve-NormalizedPath $recordedManifest.dataRoot), $data, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals((Resolve-NormalizedPath $recordedManifest.workspaceRoot), $workspace, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals((Resolve-NormalizedPath $recordedManifest.workerBinary), $workerPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Installer paths do not match the existing owned installation.'
    }
}
$previousTask = Get-WorkerTaskSnapshot `
    -Executable $workerPath `
    -Config $configPath `
    -WorkingDirectory $workspace `
    -ResolvedScope $resolvedScope

if ($Action -eq 'Uninstall') {
    if (-not $ownedInstallation) {
        [PSCustomObject]@{ schemaVersion = $script:Schema; action = 'uninstall'; succeeded = $true; alreadyAbsent = $true; dataPreserved = $true } | ConvertTo-Json
        return
    }
    Stop-AndRemoveTask `
        -Executable $workerPath `
        -Config $configPath `
        -WorkingDirectory $workspace `
        -ResolvedScope $resolvedScope
    if (Test-Path -LiteralPath $workerPath -PathType Leaf) { Remove-Item -LiteralPath $workerPath -Force }
    if (Test-Path -LiteralPath $install -PathType Container) {
        $remaining = @(Get-ChildItem -LiteralPath $install -Force)
        if ($remaining.Count -eq 0) { Remove-Item -LiteralPath $install -Force }
    }
    if ($PurgeData) {
        Assert-DefaultDataPurgeTarget -Path $data
        Remove-Item -LiteralPath $data -Recurse -Force
    }
    [PSCustomObject]@{ schemaVersion = $script:Schema; action = 'uninstall'; succeeded = $true; dataPreserved = (-not $PurgeData) } | ConvertTo-Json
    return
}

if (-not $ownedInstallation -and ($previousTask -or (Test-Path -LiteralPath $workerPath))) {
    throw 'Refusing to overwrite a worker or scheduled task not owned by this installer.'
}

$kit = Read-KitManifest -Root $bundle
Protect-Directory -Path $install
Protect-Directory -Path $data
Protect-Directory -Path $workspace
if (-not (Test-Path -LiteralPath $markerPath)) {
    [System.IO.File]::WriteAllText($markerPath, "cyc.dev/windows-worker-install/v1`n", (New-Object System.Text.UTF8Encoding($false)))
    Protect-File -Path $markerPath
}

$configExistedBeforePair = $false
if (Test-Path -LiteralPath $configPath) {
    $configItem = Get-Item -LiteralPath $configPath -Force
    if ($configItem.PSIsContainer -or (Test-ReparsePoint $configItem)) {
        throw 'Worker config path is not a regular file.'
    }
    $configExistedBeforePair = $true
}
$temporaryWorker = $workerPath + '.new-' + [Guid]::NewGuid().ToString('N')
$transactionActive = $false
$transactionCommitted = $false
try {
    Copy-Item -LiteralPath $kit.binary -Destination $temporaryWorker
    if ((Get-FileHash -LiteralPath $temporaryWorker -Algorithm SHA256).Hash.ToLowerInvariant() -ne $kit.sha256) {
        throw 'Staged worker failed SHA-256 verification.'
    }
    Protect-File -Path $temporaryWorker

    New-WorkerTransaction `
        -TransactionRoot $transactionPath `
        -DataRoot $data `
        -InstallManifestPath $manifestPath `
        -WorkerBinaryPath $workerPath `
        -TaskSnapshot $previousTask
    $transactionActive = $true

    Stop-AndRemoveTask `
        -Executable $workerPath `
        -Config $configPath `
        -WorkingDirectory $workspace `
        -ResolvedScope $resolvedScope
    if (Test-Path -LiteralPath $workerPath) {
        $existingWorker = Get-Item -LiteralPath $workerPath -Force
        if ($existingWorker.PSIsContainer -or (Test-ReparsePoint $existingWorker)) {
            throw 'Existing worker binary became unsafe during repair.'
        }
        Remove-Item -LiteralPath $workerPath -Force
    }
    Move-Item -LiteralPath $temporaryWorker -Destination $workerPath
    Protect-File -Path $workerPath

    if ($EnrollmentFile) {
        $sourceEnrollment = Resolve-NormalizedPath $EnrollmentFile
        if (-not (Test-Path -LiteralPath $sourceEnrollment -PathType Leaf)) { throw 'Enrollment file is missing.' }
        $sourceItem = Get-Item -LiteralPath $sourceEnrollment -Force
        if ((Test-ReparsePoint $sourceItem) -or $sourceItem.Length -le 0 -or $sourceItem.Length -gt 2MB) {
            throw 'Enrollment file is invalid.'
        }
        $protectedEnrollment = Join-Path $data ('enrollment-' + [Guid]::NewGuid().ToString('N') + '.json')
        try {
            Copy-Item -LiteralPath $sourceEnrollment -Destination $protectedEnrollment
            Protect-File -Path $protectedEnrollment
            $pairArguments = @(
                'pair',
                '--enrollment-file', $protectedEnrollment,
                '--config', $configPath,
                '--workspace-root', $workspace
            )
            if ($configExistedBeforePair) { $pairArguments += '--repair' }
            & $workerPath @pairArguments | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Worker pairing failed (exit=$LASTEXITCODE)." }
            Invoke-FailureInjection -Expected 'AfterPair' -Actual $FailureInjection
        } finally {
            if (Test-Path -LiteralPath $protectedEnrollment) { Remove-Item -LiteralPath $protectedEnrollment -Force }
            if (Test-Path -LiteralPath $sourceEnrollment) { Remove-Item -LiteralPath $sourceEnrollment -Force }
        }
    }
    $paired = Test-Path -LiteralPath $configPath -PathType Leaf
    if ((Test-Path -LiteralPath $configPath) -and -not $paired) {
        throw 'Worker config path exists but is not a regular file.'
    }
    if ($EnrollmentFile -and -not $paired) {
        throw 'Worker pairing completed without producing its protected config.'
    }
    $service = 'not_enabled'
    if ($paired) {
        Protect-File -Path $configPath
        & $workerPath status --config $configPath | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Worker status check failed (exit=$LASTEXITCODE)." }
    }
    if ($paired -and -not $PairOnly) {
        Register-WorkerTask -Executable $workerPath -Config $configPath -WorkingDirectory $workspace -ResolvedScope $resolvedScope -PermitBattery ([bool]$AllowOnBattery)
        Start-ScheduledTask -TaskName $script:TaskName -TaskPath '\'
        Wait-WorkerTaskRunning -TaskName $script:TaskName
        Invoke-FailureInjection -Expected 'AfterServiceRegistration' -Actual $FailureInjection
        $service = 'scheduled_task'
        $serviceEnabled = $true
    } else {
        $serviceEnabled = $false
    }

    $installManifest = [ordered]@{
        schemaVersion = $script:Schema
        version = $kit.manifest.version
        installedAt = [DateTime]::UtcNow.ToString('o')
        installRoot = $install
        dataRoot = $data
        workspaceRoot = $workspace
        workerBinary = $workerPath
        workerSha256 = $kit.sha256
        paired = [bool]$paired
        serviceEnabled = [bool]$serviceEnabled
        taskName = if ($serviceEnabled) { $script:TaskName } else { $null }
        scope = $resolvedScope.ToLowerInvariant()
        allowOnBattery = [bool]$AllowOnBattery
        pairOnly = [bool]$PairOnly
    }
    Invoke-FailureInjection -Expected 'BeforeManifestWrite' -Actual $FailureInjection
    Write-JsonAtomic -Path $manifestPath -Value $installManifest
    $commitPath = Join-Path $transactionPath 'committed'
    [System.IO.File]::WriteAllText($commitPath, "committed`n", (New-Object System.Text.UTF8Encoding($false)))
    Protect-File -Path $commitPath
    $transactionCommitted = $true
    $transactionActive = $false
    try {
        Remove-WorkerTransaction -TransactionRoot $transactionPath -DataRoot $data
    } catch {
        # A durable commit marker makes cleanup retryable on the next invocation.
    }
    [PSCustomObject]@{ schemaVersion = $script:Schema; action = $Action.ToLowerInvariant(); succeeded = $true; paired = [bool]$paired; service = $service; serviceEnabled = [bool]$serviceEnabled; scope = $resolvedScope.ToLowerInvariant(); allowOnBattery = [bool]$AllowOnBattery; version = $kit.manifest.version } | ConvertTo-Json
} catch {
    $originalFailure = $_
    if ($transactionActive -and -not $transactionCommitted) {
        try {
            Restore-WorkerTransaction `
                -TransactionRoot $transactionPath `
                -DataRoot $data `
                -InstallManifestPath $manifestPath `
                -WorkerBinaryPath $workerPath `
                -WorkspaceRoot $workspace `
                -ResolvedScope $resolvedScope
            $transactionActive = $false
        } catch {
            throw 'Worker repair failed and the protected rollback transaction could not be restored.'
        }
    }
    throw $originalFailure
} finally {
    if (Test-Path -LiteralPath $temporaryWorker) { Remove-Item -LiteralPath $temporaryWorker -Force }
}
