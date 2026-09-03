#requires -Version 5.1
[CmdletBinding()]
param(
    # Issue #2's cross-version lifecycle fixture is opt-in because it is a
    # local, fixture-only regression run.  The normal packaging gate remains
    # deterministic and does not imply Authenticode, clean-VM, or external GA
    # evidence.
    [switch]$RunUpgradeRollbackFixtures
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Convert-CycWorkerKitsJsonText {
    param([Parameter(Mandatory = $true)][string]$Raw)

    $converter = Get-Command ConvertFrom-Json -CommandType Cmdlet -ErrorAction Stop
    if ($converter.Parameters.ContainsKey('DateKind')) {
        return ConvertFrom-Json -InputObject $Raw -DateKind String
    }
    return ConvertFrom-Json -InputObject $Raw
}

function Read-CycWorkerKitsUtf8Json {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int64]$MaximumBytes = 4MB
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or
        ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -le 0 -or $item.Length -gt $MaximumBytes) {
        throw "JSON fixture is not a bounded regular file: $Path"
    }
    try {
        [byte[]]$bytes = [System.IO.File]::ReadAllBytes($item.FullName)
        $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
        $offset = if ($bytes.Length -ge 3 -and
            $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
        return Convert-CycWorkerKitsJsonText -Raw (
            $utf8Strict.GetString($bytes, $offset, $bytes.Length - $offset)
        )
    } catch {
        throw "JSON fixture contains invalid UTF-8: $Path"
    }
}

$windowsInstaller = Join-Path $PSScriptRoot 'windows\Install-Worker.ps1'
$linuxInstaller = Join-Path $PSScriptRoot 'linux\install-worker.sh'
$macosInstaller = Join-Path $PSScriptRoot 'macos\install-worker.sh'
$builder = Join-Path $PSScriptRoot 'New-WorkerKit.ps1'
$workerInstallerSource = [System.IO.File]::ReadAllText($windowsInstaller, [System.Text.Encoding]::UTF8)
$workerHashFunctionMatch = [regex]::Match(
    $workerInstallerSource,
    'function Get-CycWorkerFileHash[\s\S]+?function Test-Ed25519Signature'
)
if (-not $workerHashFunctionMatch.Success) {
    throw 'Windows worker installer is missing its module-independent streaming hash helper.'
}
$workerHashFunctionSource = $workerHashFunctionMatch.Value.Substring(
    0,
    $workerHashFunctionMatch.Value.IndexOf('function Test-Ed25519Signature', [StringComparison]::Ordinal)
)
foreach ($scriptPath in @($windowsInstaller, $builder)) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) {
        throw "PowerShell parse failed for $scriptPath`: $($errors[0].Message)"
    }
}

$gitBash = 'C:\Program Files\Git\bin\bash.exe'
$bashPath = if (Test-Path -LiteralPath $gitBash -PathType Leaf) {
    $gitBash
} else {
    $candidate = Get-Command bash -ErrorAction SilentlyContinue
    if ($candidate -and $candidate.Source -notlike '*\Windows\System32\bash.exe') { $candidate.Source } else { $null }
}
if ($bashPath) {
    & $bashPath -n $linuxInstaller
    if ($LASTEXITCODE -ne 0) { throw 'Linux worker installer failed bash -n.' }
    & $bashPath -n $macosInstaller
    if ($LASTEXITCODE -ne 0) { throw 'macOS worker installer failed bash -n.' }
}

$temporary = Join-Path ([System.IO.Path]::GetTempPath()) ('cyc-worker-kit-test-' + [Guid]::NewGuid().ToString('N'))
$previousSigningKeyPath = [string]$env:CYC_WORKER_KIT_SIGNING_KEY_PATH
$previousSigningKeyId = [string]$env:CYC_WORKER_KIT_SIGNING_KEY_ID
$previousTrustedPublicKeyPath = [string]$env:CYC_WORKER_KIT_TRUSTED_PUBLIC_KEY_PATH
$previousTestPrivateKey = [string]$env:CYC_WORKER_KIT_TEST_PRIVATE_KEY
try {
    [void](New-Item -ItemType Directory -Path $temporary)
    $opensslCommand = Get-Command openssl -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $openssl = if ($opensslCommand) { [string]$opensslCommand.Source } elseif (Test-Path -LiteralPath 'C:\Program Files\Git\usr\bin\openssl.exe') { 'C:\Program Files\Git\usr\bin\openssl.exe' } else { throw 'OpenSSL fixture tool is unavailable.' }
    $fixturePrivate = Join-Path $temporary 'fixture-ed25519-private.pem'
    $fixturePublicDer = Join-Path $temporary 'fixture-ed25519-public.der'
    $fixturePublicPem = Join-Path $temporary 'fixture-ed25519-public.pem'
    $fixturePublicRaw = Join-Path $temporary 'fixture-ed25519-public.b64'
    & $openssl genpkey -algorithm ED25519 -out $fixturePrivate
    if ($LASTEXITCODE -ne 0) { throw 'Failed to generate the test-only Ed25519 fixture key.' }
    & $openssl pkey -in $fixturePrivate -pubout -outform DER -out $fixturePublicDer
    if ($LASTEXITCODE -ne 0) { throw 'Failed to derive the test-only Ed25519 fixture public key.' }
    & $openssl pkey -in $fixturePrivate -pubout -out $fixturePublicPem
    if ($LASTEXITCODE -ne 0) { throw 'Failed to export the test-only Ed25519 fixture public key.' }
    $publicDer = [System.IO.File]::ReadAllBytes($fixturePublicDer)
    if ($publicDer.Length -ne 44) { throw 'Unexpected Ed25519 fixture public-key encoding.' }
    [System.IO.File]::WriteAllText(
        $fixturePublicRaw,
        [Convert]::ToBase64String([byte[]]$publicDer[12..43]) + "`n",
        (New-Object System.Text.UTF8Encoding($false))
    )
    $env:CYC_WORKER_KIT_SIGNING_KEY_PATH = $fixturePrivate
    $env:CYC_WORKER_KIT_SIGNING_KEY_ID = 'cyc-release-2026-02'
    $env:CYC_WORKER_KIT_TRUSTED_PUBLIC_KEY_PATH = $fixturePublicRaw
    $env:CYC_WORKER_KIT_TEST_PRIVATE_KEY = $fixturePrivate

    # The managed-worker lifecycle invokes Install-Worker.ps1 through a
    # Windows PowerShell -NoProfile child.  Exercise the hash helper in that
    # exact boundary with module discovery disabled so a future regression to
    # Get-FileHash is caught before a release artifact is published.
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
        throw 'Windows PowerShell 5.1 is required for the worker-kit -NoProfile hash probe.'
    }
    $hashProbePath = Join-Path $temporary 'worker-installer-hash-probe.txt'
    $hashProbeContent = "module-independent worker hash probe`n"
    [System.IO.File]::WriteAllText($hashProbePath, $hashProbeContent, (New-Object System.Text.UTF8Encoding($false)))
    $hashProbeSha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashProbeExpected = ([System.BitConverter]::ToString(
            $hashProbeSha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($hashProbeContent))
        )).Replace('-', '').ToLowerInvariant()
    } finally {
        $hashProbeSha.Dispose()
    }
    $hashProbePath64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($hashProbePath))
    $hashProbeSource = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
`$env:PSModulePath = 'C:\__cyc_missing_worker_modules__'
function Get-FileHash { throw 'Get-FileHash was called by the worker installer hash probe.' }
$workerHashFunctionSource
`$probePath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$hashProbePath64'))
`$observed = (Get-CycWorkerFileHash -LiteralPath `$probePath -Algorithm SHA256).Hash.ToLowerInvariant()
if (`$observed -cne '$hashProbeExpected') { throw "Worker hash probe mismatch: `$observed" }
"@
    $hashProbeEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($hashProbeSource))
    $hashProbeStdout = Join-Path $temporary 'worker-installer-hash-probe.stdout.log'
    $hashProbeStderr = Join-Path $temporary 'worker-installer-hash-probe.stderr.log'
    $hashProbe = Start-Process `
        -FilePath $windowsPowerShell `
        -ArgumentList @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-EncodedCommand', $hashProbeEncoded
        ) `
        -WorkingDirectory $temporary `
        -WindowStyle Hidden `
        -RedirectStandardOutput $hashProbeStdout `
        -RedirectStandardError $hashProbeStderr `
        -Wait `
        -PassThru
    $hashProbeStdoutText = if (Test-Path -LiteralPath $hashProbeStdout -PathType Leaf) {
        [System.IO.File]::ReadAllText($hashProbeStdout)
    } else { '' }
    $hashProbeStderrText = if (Test-Path -LiteralPath $hashProbeStderr -PathType Leaf) {
        [System.IO.File]::ReadAllText($hashProbeStderr)
    } else { '' }
    $hashProbeOutput = ($hashProbeStdoutText + $hashProbeStderrText).Trim()
    if ($hashProbe.ExitCode -ne 0) {
        throw "Windows worker installer -NoProfile hash probe failed (exit=$($hashProbe.ExitCode)): $hashProbeOutput"
    }

    $fakeWorker = Join-Path $temporary 'fake-worker.bin'
    [System.IO.File]::WriteAllBytes($fakeWorker, [byte[]](0..255))
    $windowsOutput = Join-Path $temporary 'windows'
    $result = & $builder -Target windows-x86_64 -WorkerExecutable $fakeWorker -OutputDirectory $windowsOutput -Version '0.1.0-test.1' | ConvertFrom-Json
    if ($result.schemaVersion -ne 'cyc.dev/worker-kit-build/v1') { throw 'Unexpected builder result schema.' }
    $manifest = Read-CycWorkerKitsUtf8Json -Path (Join-Path $windowsOutput 'worker-kit.json')
    if ($manifest.schemaVersion -ne 'cyc.dev/worker-kit/v1' -or $manifest.os -ne 'windows') { throw 'Windows manifest is invalid.' }
    $actual = (Get-FileHash -LiteralPath (Join-Path $windowsOutput 'cyc-worker.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($manifest.files[0].sha256 -ne $actual) { throw 'Windows worker digest mismatch.' }
    $signatureEnvelope = Read-CycWorkerKitsUtf8Json -Path (Join-Path $windowsOutput 'worker-kit.sig') -MaximumBytes 64KB
    if ($signatureEnvelope.schemaVersion -ne 'cyc.dev/worker-kit-signature/v1' -or
        $signatureEnvelope.algorithm -ne 'Ed25519' -or
        $signatureEnvelope.keyId -ne 'cyc-release-2026-02' -or
        $signatureEnvelope.signedObject -ne 'worker-kit.json') {
        throw 'Worker-kit publisher signature envelope is invalid.'
    }
    $rawSignature = Join-Path $temporary 'worker-kit-signature.raw'
    [System.IO.File]::WriteAllBytes($rawSignature, [Convert]::FromBase64String([string]$signatureEnvelope.signature))
    & $openssl pkeyutl -verify -rawin -pubin -inkey $fixturePublicPem `
        -in (Join-Path $windowsOutput 'worker-kit.json') -sigfile $rawSignature
    if ($LASTEXITCODE -ne 0) { throw 'Worker-kit publisher signature did not verify.' }
    $sumNames = @(Get-Content -LiteralPath (Join-Path $windowsOutput 'SHA256SUMS') |
        ForEach-Object { ($_ -split '  ', 2)[1] })
    if (($sumNames -join ',') -cne 'cyc-worker.exe,Install-Worker.ps1,worker-kit.json,worker-kit.sig') {
        throw 'Worker-kit checksums do not bind the exact signed file set.'
    }
    $repositoryVersionPath = Join-Path $PSScriptRoot '..\..\VERSION'
    $repositoryVersion = [IO.File]::ReadAllText($repositoryVersionPath, [Text.Encoding]::UTF8).TrimEnd("`n")
    $defaultVersionOutput = Join-Path $temporary 'default-version'
    $defaultVersionResult = & $builder `
        -Target linux-x86_64 `
        -WorkerExecutable $fakeWorker `
        -OutputDirectory $defaultVersionOutput | ConvertFrom-Json
    $defaultVersionManifest = Read-CycWorkerKitsUtf8Json -Path (Join-Path $defaultVersionOutput 'worker-kit.json')
    if ($defaultVersionResult.version -cne $repositoryVersion -or
        $defaultVersionManifest.version -cne $repositoryVersion) {
        throw 'Worker-kit omitted -Version does not derive its identity from repository VERSION.'
    }
    $savedSigningKey = [string]$env:CYC_WORKER_KIT_SIGNING_KEY_PATH
    try {
        $env:CYC_WORKER_KIT_SIGNING_KEY_PATH = ''
        $missingKeyRejected = $false
        try {
            $null = & $builder -Target windows-x86_64 -WorkerExecutable $fakeWorker `
                -OutputDirectory (Join-Path $temporary 'missing-signing-key') `
                -SigningKeyId 'cyc-release-2026-02' -TrustedPublicKeyPath $fixturePublicRaw
        } catch {
            $missingKeyRejected = $true
        }
        if (-not $missingKeyRejected) { throw 'Builder emitted an unsigned worker kit.' }
    } finally {
        $env:CYC_WORKER_KIT_SIGNING_KEY_PATH = $savedSigningKey
    }
    $foreignPrivate = Join-Path $temporary 'foreign-ed25519-private.pem'
    & $openssl genpkey -algorithm ED25519 -out $foreignPrivate
    if ($LASTEXITCODE -ne 0) { throw 'Failed to generate the foreign publisher fixture.' }
    $foreignKeyRejected = $false
    try {
        $null = & $builder -Target windows-x86_64 -WorkerExecutable $fakeWorker `
            -OutputDirectory (Join-Path $temporary 'foreign-signing-key') `
            -SigningKeyPath $foreignPrivate -SigningKeyId 'cyc-release-2026-02' `
            -TrustedPublicKeyPath $fixturePublicRaw
    } catch {
        $foreignKeyRejected = $true
    }
    if (-not $foreignKeyRejected) { throw 'Builder accepted a non-pinned publisher key.' }
    $nonEmptyRejected = $false
    try {
        $null = & $builder -Target windows-x86_64 -WorkerExecutable $fakeWorker -OutputDirectory $windowsOutput -Version '0.1.0-test.1'
    } catch {
        $nonEmptyRejected = $true
    }
    if (-not $nonEmptyRejected) { throw 'Builder accepted a non-empty output directory.' }

    $windowsSmokeKit = Join-Path $temporary 'windows-smoke-kit'
    $windowsFixtureBinary = Join-Path $env:SystemRoot 'System32\where.exe'
    $null = & $builder `
        -Target windows-x86_64 `
        -WorkerExecutable $windowsFixtureBinary `
        -OutputDirectory $windowsSmokeKit `
        -Version '0.1.0-test.1'
    $windowsSmokeInstall = Join-Path $temporary 'windows-smoke-install'
    $windowsSmokeData = Join-Path $temporary 'windows-smoke-data'
    $windowsSmokeWorkspace = Join-Path $temporary 'windows-smoke-workspace'
    $windowsSmokeInstaller = Join-Path $windowsSmokeKit 'Install-Worker.ps1'
    function Get-ScheduledTask { param($TaskName, $TaskPath, $ErrorAction) return $null }
    function Stop-ScheduledTask { param($TaskName, $TaskPath, $ErrorAction) }
    function Unregister-ScheduledTask { param($TaskName, $TaskPath, [switch]$Confirm) }
    try {
        $unexpectedKitFile = Join-Path $windowsSmokeKit 'unexpected.txt'
        [System.IO.File]::WriteAllText($unexpectedKitFile, "unexpected`n", (New-Object System.Text.UTF8Encoding($false)))
        $unexpectedFileRejected = $false
        try {
            $null = . $windowsSmokeInstaller `
                -Action Install `
                -BundleRoot $windowsSmokeKit `
                -InstallRoot $windowsSmokeInstall `
                -DataRoot $windowsSmokeData `
                -WorkspaceRoot $windowsSmokeWorkspace `
                -Scope User `
                -Confirm:$false
        } catch {
            $unexpectedFileRejected = $true
        } finally {
            Remove-Item -LiteralPath $unexpectedKitFile -Force
        }
        if (-not $unexpectedFileRejected -or
            (Test-Path -LiteralPath $windowsSmokeInstall) -or
            (Test-Path -LiteralPath $windowsSmokeData) -or
            (Test-Path -LiteralPath $windowsSmokeWorkspace)) {
            throw 'Windows worker installer accepted an unexpected kit entry or mutated state before verification.'
        }

        # A missing destination must not allow New-Item to follow an existing
        # junction in an ancestor. Keep a sentinel outside the intended roots
        # and prove the installer fails before creating anything through it.
        $reparseTarget = Join-Path $temporary 'windows-reparse-target'
        $reparseParent = Join-Path $temporary 'windows-reparse-parent'
        $reparseJunction = Join-Path $reparseParent 'redirect'
        $reparseSentinel = Join-Path $reparseTarget 'sentinel.txt'
        [void](New-Item -ItemType Directory -Path $reparseTarget)
        [void](New-Item -ItemType Directory -Path $reparseParent)
        [System.IO.File]::WriteAllText($reparseSentinel, "unchanged`n", (New-Object System.Text.UTF8Encoding($false)))
        $sentinelBefore = (Get-FileHash -LiteralPath $reparseSentinel -Algorithm SHA256).Hash
        try {
            [void](New-Item -ItemType Junction -Path $reparseJunction -Target $reparseTarget)
            $reparseInstall = Join-Path $reparseJunction 'new-install'
            $reparseData = Join-Path $temporary 'windows-reparse-data'
            $reparseWorkspace = Join-Path $temporary 'windows-reparse-workspace'
            $reparseRejected = $false
            try {
                $null = . $windowsSmokeInstaller `
                    -Action Install `
                    -BundleRoot $windowsSmokeKit `
                    -InstallRoot $reparseInstall `
                    -DataRoot $reparseData `
                    -WorkspaceRoot $reparseWorkspace `
                    -Scope User `
                    -Confirm:$false
            } catch {
                $reparseRejected = $true
            }
            if (-not $reparseRejected -or
                (Test-Path -LiteralPath $reparseInstall) -or
                (Test-Path -LiteralPath (Join-Path $reparseTarget 'new-install')) -or
                (Get-FileHash -LiteralPath $reparseSentinel -Algorithm SHA256).Hash -ne $sentinelBefore) {
                throw 'Windows worker installer followed a reparse ancestor while creating a missing root.'
            }
        } finally {
            if (Test-Path -LiteralPath $reparseJunction) {
                # Windows PowerShell can prompt when Remove-Item targets a
                # junction, which makes the non-interactive CI harness fail
                # even though the fixture itself passed.  Use the native
                # junction-aware rmdir command so cleanup never follows the
                # link or requires a confirmation prompt.
                & $env:ComSpec /d /c rmdir /q "$reparseJunction"
                if ($LASTEXITCODE -ne 0 -and (Test-Path -LiteralPath $reparseJunction)) {
                    throw "Failed to remove the Windows reparse fixture junction: $reparseJunction"
                }
            }
        }

        # Existing trust-root state is verify-only. A pre-existing directory
        # with the normal inherited temporary-folder ACL must be rejected and
        # left byte-for-byte/ACL-for-ACL unchanged rather than silently
        # repaired into an installer-owned root.
        $weakRoot = Join-Path $temporary 'windows-weak-existing-root'
        $weakSentinel = Join-Path $weakRoot 'sentinel.txt'
        [void](New-Item -ItemType Directory -Path $weakRoot)
        [System.IO.File]::WriteAllText($weakSentinel, "weak-state`n", (New-Object System.Text.UTF8Encoding($false)))
        $weakAclBefore = (Get-Acl -LiteralPath $weakRoot).Sddl
        $weakSentinelBefore = (Get-FileHash -LiteralPath $weakSentinel -Algorithm SHA256).Hash
        $weakRejected = $false
        try {
            $null = . $windowsSmokeInstaller `
                -Action Install `
                -BundleRoot $windowsSmokeKit `
                -InstallRoot $weakRoot `
                -DataRoot (Join-Path $temporary 'windows-weak-data') `
                -WorkspaceRoot (Join-Path $temporary 'windows-weak-workspace') `
                -Scope User `
                -Confirm:$false
        } catch {
            $weakRejected = $true
        }
        if (-not $weakRejected -or
            (Get-Acl -LiteralPath $weakRoot).Sddl -cne $weakAclBefore -or
            (Get-FileHash -LiteralPath $weakSentinel -Algorithm SHA256).Hash -ne $weakSentinelBefore -or
            (Test-Path -LiteralPath (Join-Path $temporary 'windows-weak-data')) -or
            (Test-Path -LiteralPath (Join-Path $temporary 'windows-weak-workspace'))) {
            throw 'Windows worker installer repaired or mutated an existing weak private root.'
        }

        $preinstallReceipt = . $windowsSmokeInstaller `
            -Action Install `
            -BundleRoot $windowsSmokeKit `
            -InstallRoot $windowsSmokeInstall `
            -DataRoot $windowsSmokeData `
            -WorkspaceRoot $windowsSmokeWorkspace `
            -Scope User `
            -AllowOnBattery `
            -Confirm:$false | ConvertFrom-Json
        if (-not $preinstallReceipt.succeeded -or $preinstallReceipt.paired) {
            throw 'Windows preinstall did not stop at the unpaired service-disabled boundary.'
        }
        if (-not (Test-Path -LiteralPath (Join-Path $windowsSmokeInstall 'cyc-worker.exe') -PathType Leaf) -or
            (Test-Path -LiteralPath (Join-Path $windowsSmokeData 'config.json'))) {
            throw 'Windows preinstall file state is invalid.'
        }
        $preinstallManifest = Read-CycWorkerKitsUtf8Json -Path (Join-Path $windowsSmokeData 'install-manifest.json')
        if ($preinstallManifest.paired -or $preinstallManifest.serviceEnabled) {
            throw 'Windows preinstall manifest incorrectly reports a paired service.'
        }
        if ($preinstallManifest.scope -ne 'user' -or -not $preinstallManifest.allowOnBattery) {
            throw 'Windows preinstall did not persist the selected service/battery policy.'
        }
    } finally {
        Remove-Item Function:\Get-ScheduledTask -Force
        Remove-Item Function:\Stop-ScheduledTask -Force
        Remove-Item Function:\Unregister-ScheduledTask -Force
    }

    function New-FakeWindowsWorker {
        param(
            [Parameter(Mandatory = $true)][string]$OutputPath,
            [Parameter(Mandatory = $true)][string]$Version
        )
        $compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw 'The Windows x64 C# compiler fixture is unavailable.' }
        $sourcePath = [System.IO.Path]::ChangeExtension($OutputPath, '.cs')
        $source = @'
using System;
using System.IO;
using System.Text;
using System.Threading;

internal static class Program
{
    private const string Version = "__VERSION__";

    private static string Value(string[] args, string name)
    {
        for (int i = 0; i + 1 < args.Length; i++)
            if (String.Equals(args[i], name, StringComparison.Ordinal)) return args[i + 1];
        return null;
    }

    private static string CredentialFromConfig(string path)
    {
        string text = File.ReadAllText(path, Encoding.UTF8);
        const string marker = "\"credentialFile\":\"";
        int start = text.IndexOf(marker, StringComparison.Ordinal);
        if (start < 0) return null;
        start += marker.Length;
        int end = text.IndexOf('"', start);
        if (end < 0) return null;
        return text.Substring(start, end - start).Replace("\\\\", "\\");
    }

    private static string JsonEscape(string value)
    {
        return value.Replace("\\", "\\\\").Replace("\"", "\\\"");
    }

    private static int Main(string[] args)
    {
        if (args.Length == 0) return 2;
        if (args[0] == "pair")
        {
            string config = Value(args, "--config");
            string enrollment = Value(args, "--enrollment-file");
            string workspace = Value(args, "--workspace-root");
            bool repair = Array.IndexOf(args, "--repair") >= 0;
            if (String.IsNullOrEmpty(config) || String.IsNullOrEmpty(enrollment) ||
                String.IsNullOrEmpty(workspace) || !File.Exists(enrollment)) return 3;
            bool existed = File.Exists(config);
            if (existed != repair) return 4;
            string previous = existed ? CredentialFromConfig(config) : null;
            string credential = Path.Combine(Path.GetDirectoryName(config), "config." + Guid.NewGuid().ToString("N") + ".credential");
            File.WriteAllText(credential, "WINDOWS_SECRET_DO_NOT_LOG\n", new UTF8Encoding(false));
            string json = "{\"paired\":true,\"worker\":\"" + Version + "\",\"repair\":" +
                (repair ? "true" : "false") + ",\"workspaceRoot\":\"" + JsonEscape(workspace) +
                "\",\"credentialFile\":\"" + JsonEscape(credential) + "\"}\n";
            File.WriteAllText(config, json, new UTF8Encoding(false));
            if (!String.IsNullOrEmpty(previous) && !String.Equals(previous, credential, StringComparison.OrdinalIgnoreCase))
                File.Delete(previous);
            return 0;
        }
        if (args[0] == "status")
        {
            string config = Value(args, "--config");
            if (String.IsNullOrEmpty(config) || !File.Exists(config)) return 5;
            string credential = CredentialFromConfig(config);
            return !String.IsNullOrEmpty(credential) && File.Exists(credential) ? 0 : 6;
        }
        if (args[0] == "run")
        {
            Thread.Sleep(60000);
            return 0;
        }
        return 2;
    }
}
'@.Replace('__VERSION__', $Version)
        [System.IO.File]::WriteAllText($sourcePath, $source, (New-Object System.Text.UTF8Encoding($false)))
        & $compiler /nologo /target:exe /platform:x64 ("/out:$OutputPath") $sourcePath
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
            throw 'Failed to compile the Windows transactional worker fixture.'
        }
    }

    $windowsOldWorker = Join-Path $temporary 'fake-windows-worker-old.exe'
    $windowsUpgradeWorker = Join-Path $temporary 'fake-windows-worker-upgrade.exe'
    New-FakeWindowsWorker -OutputPath $windowsOldWorker -Version 'old'
    New-FakeWindowsWorker -OutputPath $windowsUpgradeWorker -Version 'upgrade'
    $windowsOldKit = Join-Path $temporary 'windows-transaction-old'
    $windowsUpgradeKit = Join-Path $temporary 'windows-transaction-upgrade'
    $null = & $builder -Target windows-x86_64 -WorkerExecutable $windowsOldWorker -OutputDirectory $windowsOldKit -Version '0.1.0-test.1'
    $null = & $builder -Target windows-x86_64 -WorkerExecutable $windowsUpgradeWorker -OutputDirectory $windowsUpgradeKit -Version '0.1.0-test.2'
    $windowsOldInstaller = Join-Path $windowsOldKit 'Install-Worker.ps1'
    $windowsUpgradeInstaller = Join-Path $windowsUpgradeKit 'Install-Worker.ps1'

    $windowsTransactionInstall = Join-Path $temporary 'windows-transaction-install'
    $windowsTransactionData = Join-Path $temporary 'windows-transaction-data'
    $windowsTransactionWorkspace = Join-Path $temporary 'windows-transaction-workspace'
    $script:FakeTaskExists = $false
    $script:FakeTaskRunning = $false
    $script:FakeTaskXml = $null
    $script:FakeTaskGeneration = 0
    $script:FakeTaskPath = '\'
    $script:FakeTaskAction = $null
    $script:FakeTaskPrincipal = $null
    $script:FakeTaskStopCount = 0
    $script:FakeTaskUnregisterCount = 0
    $script:FakeTaskRegisterCount = 0
    function Get-ScheduledTask {
        param($TaskName, $TaskPath, $ErrorAction)
        if (-not $script:FakeTaskExists) { return $null }
        if ($PSBoundParameters.ContainsKey('TaskPath') -and [string]$TaskPath -cne [string]$script:FakeTaskPath) { return $null }
        return [PSCustomObject]@{
            State = if ($script:FakeTaskRunning) { 'Running' } else { 'Ready' }
            TaskPath = $script:FakeTaskPath
            Actions = @($script:FakeTaskAction)
            Principal = $script:FakeTaskPrincipal
        }
    }
    function Export-ScheduledTask { param($TaskName, $TaskPath) if ([string]$TaskPath -cne [string]$script:FakeTaskPath) { throw 'Fake task path mismatch.' }; return $script:FakeTaskXml }
    function Stop-ScheduledTask { param($TaskName, $TaskPath, $ErrorAction) $script:FakeTaskStopCount++; $script:FakeTaskRunning = $false }
    function Unregister-ScheduledTask { param($TaskName, $TaskPath, [switch]$Confirm) $script:FakeTaskUnregisterCount++; $script:FakeTaskExists = $false; $script:FakeTaskRunning = $false }
    function Start-ScheduledTask { param($TaskName, $TaskPath) if (-not $script:FakeTaskExists) { throw 'Fake task is absent.' }; $script:FakeTaskRunning = $true }
    function Get-ScheduledTaskInfo { param($TaskName, $TaskPath, $ErrorAction) return [PSCustomObject]@{ LastTaskResult = 0 } }
    function New-ScheduledTaskAction { param($Execute, $Argument, $WorkingDirectory) return [PSCustomObject]@{ Execute = $Execute; Arguments = $Argument; WorkingDirectory = $WorkingDirectory } }
    function New-ScheduledTaskTrigger { param([switch]$AtStartup, [switch]$AtLogOn, $User) return [PSCustomObject]@{} }
    function New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel) return [PSCustomObject]@{ UserId = $UserId } }
    function New-ScheduledTaskSettingsSet {
        param($MultipleInstances, $StartWhenAvailable, $RestartCount, $RestartInterval, $ExecutionTimeLimit, $AllowStartIfOnBatteries, $DontStopIfGoingOnBatteries)
        return [PSCustomObject]@{}
    }
    function Register-ScheduledTask {
        param($TaskName, $TaskPath, $Xml, $Action, $Trigger, $Principal, $Settings, $Description, [switch]$Force)
        if ([string]$TaskPath -cne '\') { throw 'Fake task must be registered in the root task path.' }
        $script:FakeTaskRegisterCount++
        $script:FakeTaskExists = $true
        $script:FakeTaskRunning = $false
        $script:FakeTaskPath = [string]$TaskPath
        if ($PSBoundParameters.ContainsKey('Xml')) {
            $script:FakeTaskXml = [string]$Xml
        } else {
            $script:FakeTaskGeneration++
            $script:FakeTaskXml = "<Task generation=`"$($script:FakeTaskGeneration)`" />"
            $script:FakeTaskAction = $Action
            $script:FakeTaskPrincipal = $Principal
        }
        return [PSCustomObject]@{}
    }
    try {
        $null = . $windowsOldInstaller `
            -Action Install `
            -BundleRoot $windowsOldKit `
            -InstallRoot $windowsTransactionInstall `
            -DataRoot $windowsTransactionData `
            -WorkspaceRoot $windowsTransactionWorkspace `
            -Scope User `
            -Confirm:$false
        $initialEnrollment = Join-Path $temporary 'windows-initial-enrollment.json'
        [System.IO.File]::WriteAllText($initialEnrollment, "WINDOWS_ENROLLMENT_SECRET_DO_NOT_LOG`n", (New-Object System.Text.UTF8Encoding($false)))
        $initialReceipt = . $windowsOldInstaller `
            -Action Repair `
            -BundleRoot $windowsOldKit `
            -InstallRoot $windowsTransactionInstall `
            -DataRoot $windowsTransactionData `
            -WorkspaceRoot $windowsTransactionWorkspace `
            -EnrollmentFile $initialEnrollment `
            -Scope User `
            -Confirm:$false | ConvertFrom-Json
        if (-not $initialReceipt.paired -or -not $initialReceipt.serviceEnabled -or -not $script:FakeTaskRunning) {
            throw 'Windows transactional fixture did not reach the Ready state.'
        }

        $installedWorker = Join-Path $windowsTransactionInstall 'cyc-worker.exe'
        $installedConfig = Join-Path $windowsTransactionData 'config.json'
        $installedManifest = Join-Path $windowsTransactionData 'install-manifest.json'
        $baselineInstallManifest = Read-CycWorkerKitsUtf8Json -Path $installedManifest
        if ([string]$baselineInstallManifest.version -cne '0.1.0-test.1' -or
            -not [bool]$baselineInstallManifest.paired -or
            -not [bool]$baselineInstallManifest.serviceEnabled) {
            throw 'Windows N-1 fixture did not publish a paired, service-enabled install manifest.'
        }
        $baselineCredentialPath = (Read-CycWorkerKitsUtf8Json -Path $installedConfig).credentialFile
        $baseline = [ordered]@{
            worker = (Get-FileHash -LiteralPath $installedWorker -Algorithm SHA256).Hash
            config = (Get-FileHash -LiteralPath $installedConfig -Algorithm SHA256).Hash
            credential = (Get-FileHash -LiteralPath $baselineCredentialPath -Algorithm SHA256).Hash
            manifest = (Get-FileHash -LiteralPath $installedManifest -Algorithm SHA256).Hash
            taskXml = $script:FakeTaskXml
        }

        # A same-named task outside the root task path, or with a foreign
        # principal/action, must be rejected before stop/unregister or any
        # installer-owned file is mutated.
        $baselineTaskPath = $script:FakeTaskPath
        $baselineTaskAction = $script:FakeTaskAction
        $baselineTaskPrincipal = $script:FakeTaskPrincipal
        $baselineTaskStopCount = $script:FakeTaskStopCount
        $baselineTaskUnregisterCount = $script:FakeTaskUnregisterCount
        $baselineTaskRegisterCount = $script:FakeTaskRegisterCount
        function Assert-ForeignWorkerTaskRejected {
            param([Parameter(Mandatory = $true)][string]$Label)
            $beforeWorker = (Get-FileHash -LiteralPath $installedWorker -Algorithm SHA256).Hash
            $beforeConfig = (Get-FileHash -LiteralPath $installedConfig -Algorithm SHA256).Hash
            $beforeManifest = (Get-FileHash -LiteralPath $installedManifest -Algorithm SHA256).Hash
            $rejected = $false
            try {
                $null = . $windowsUpgradeInstaller `
                    -Action Repair `
                    -BundleRoot $windowsUpgradeKit `
                    -InstallRoot $windowsTransactionInstall `
                    -DataRoot $windowsTransactionData `
                    -WorkspaceRoot $windowsTransactionWorkspace `
                    -Scope User `
                    -Confirm:$false
            } catch {
                $rejected = $true
            }
            if (-not $rejected) { throw "Foreign worker task fixture was accepted: $Label" }
            if ((Get-FileHash -LiteralPath $installedWorker -Algorithm SHA256).Hash -ne $beforeWorker -or
                (Get-FileHash -LiteralPath $installedConfig -Algorithm SHA256).Hash -ne $beforeConfig -or
                (Get-FileHash -LiteralPath $installedManifest -Algorithm SHA256).Hash -ne $beforeManifest -or
                $script:FakeTaskStopCount -ne $baselineTaskStopCount -or
                $script:FakeTaskUnregisterCount -ne $baselineTaskUnregisterCount -or
                $script:FakeTaskRegisterCount -ne $baselineTaskRegisterCount -or
                -not $script:FakeTaskExists) {
                throw "Foreign worker task fixture mutated installer state: $Label"
            }
        }
        $script:FakeTaskPath = '\Foreign\'
        Assert-ForeignWorkerTaskRejected -Label 'foreign task path'
        $script:FakeTaskPath = $baselineTaskPath
        $script:FakeTaskPrincipal = [PSCustomObject]@{ UserId = 'S-1-5-21-1-2-3-9999' }
        Assert-ForeignWorkerTaskRejected -Label 'foreign task principal'
        $script:FakeTaskPrincipal = $baselineTaskPrincipal
        $script:FakeTaskAction = [PSCustomObject]@{
            Execute = $installedWorker
            Arguments = 'run --config "' + $installedConfig + '"'
            WorkingDirectory = (Join-Path $temporary 'foreign-worker-workspace')
        }
        Assert-ForeignWorkerTaskRejected -Label 'foreign task working directory'
        $script:FakeTaskAction = $baselineTaskAction

        foreach ($injection in @('AfterPair', 'AfterServiceRegistration', 'BeforeManifestWrite')) {
            $arguments = @{
                Action = 'Repair'
                BundleRoot = $windowsUpgradeKit
                InstallRoot = $windowsTransactionInstall
                DataRoot = $windowsTransactionData
                WorkspaceRoot = $windowsTransactionWorkspace
                Scope = 'User'
                FailureInjection = $injection
                Confirm = $false
            }
            if ($injection -eq 'AfterPair') {
                $repairEnrollment = Join-Path $temporary 'windows-repair-enrollment.json'
                [System.IO.File]::WriteAllText($repairEnrollment, "WINDOWS_ENROLLMENT_SECRET_DO_NOT_LOG`n", (New-Object System.Text.UTF8Encoding($false)))
                $arguments.EnrollmentFile = $repairEnrollment
            }
            $failed = $false
            $failureText = ''
            try {
                $failureText = (. $windowsUpgradeInstaller @arguments 2>&1 | Out-String)
            } catch {
                $failed = $true
                $failureText += $_.Exception.Message
            }
            if (-not $failed) { throw "Windows failure injection did not fail at $injection." }
            if ($failureText -match 'WINDOWS_.*SECRET_DO_NOT_LOG') { throw 'Windows repair failure leaked secret material.' }
            if ((Get-FileHash -LiteralPath $installedWorker -Algorithm SHA256).Hash -ne $baseline.worker -or
                (Get-FileHash -LiteralPath $installedConfig -Algorithm SHA256).Hash -ne $baseline.config -or
                (Get-FileHash -LiteralPath $baselineCredentialPath -Algorithm SHA256).Hash -ne $baseline.credential -or
                (Get-FileHash -LiteralPath $installedManifest -Algorithm SHA256).Hash -ne $baseline.manifest) {
                throw "Windows repair did not restore old bytes at $injection."
            }
            & $installedWorker status --config $installedConfig | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Windows restored worker was not usable at $injection." }
            if (@(Get-ChildItem -LiteralPath $windowsTransactionData -Filter 'config.*.credential' -File).Count -ne 1 -or
                -not $script:FakeTaskExists -or -not $script:FakeTaskRunning -or $script:FakeTaskXml -ne $baseline.taskXml -or
                (Test-Path -LiteralPath (Join-Path $windowsTransactionData '.repair-transaction'))) {
                throw "Windows repair did not restore old identity/service state at $injection."
            }
        }

        if ($RunUpgradeRollbackFixtures) {
            Write-Output '[fixture-only][fail-closed] Windows upgrade fixtures use the pinned local Ed25519 test key and mocked Scheduled Task state; they do not prove Authenticode, a clean Windows 11 VM, or any external GA gate.'
            if (-not (Get-Command New-WorkerTransaction -CommandType Function -ErrorAction SilentlyContinue)) {
                throw '[fixture-only] Windows upgrade fixture cannot access the existing New-WorkerTransaction hook.'
            }

            # Simulate a process interruption after the new worker/config have
            # been written but before the transaction is committed.  The
            # protected journal is created by the production helper itself;
            # only the interrupted after-image is fixture data.  Re-entering
            # the N-1 installer must restore the old identity, binary,
            # manifest version, and running task before retrying the repair.
            Write-Output '[fixture-only] interrupted upgrade rollback: seeding the existing protected transaction hook and an interrupted N after-image.'
            $interruptedTransaction = Join-Path $windowsTransactionData '.repair-transaction'
            $interruptedCredential = Join-Path $windowsTransactionData 'config.interrupted.credential'
            $interruptedSnapshot = [PSCustomObject]@{
                Xml = $baseline.taskXml
                WasRunning = $true
            }
            New-WorkerTransaction `
                -TransactionRoot $interruptedTransaction `
                -DataRoot $windowsTransactionData `
                -InstallManifestPath $installedManifest `
                -WorkerBinaryPath $installedWorker `
                -TaskSnapshot $interruptedSnapshot

            Copy-Item -LiteralPath (Join-Path $windowsUpgradeKit 'cyc-worker.exe') -Destination $installedWorker -Force
            [System.IO.File]::WriteAllText(
                $interruptedCredential,
                "WINDOWS_INTERRUPTED_SECRET_DO_NOT_LOG`n",
                (New-Object System.Text.UTF8Encoding($false))
            )
            Protect-File -Path $interruptedCredential -NewlyCreated
            $interruptedConfig = [ordered]@{
                paired = $true
                worker = 'upgrade'
                repair = $true
                workspaceRoot = $windowsTransactionWorkspace
                credentialFile = $interruptedCredential
            }
            [System.IO.File]::WriteAllText(
                $installedConfig,
                (($interruptedConfig | ConvertTo-Json -Depth 8 -Compress) + "`n"),
                (New-Object System.Text.UTF8Encoding($false))
            )
            # The kit manifest and the installed manifest intentionally have
            # different schemas.  Start from the committed N-1 install
            # manifest so the seeded after-image exercises the production
            # install-manifest recovery contract rather than inventing a
            # kit-shaped state file.
            $interruptedManifest = ($baselineInstallManifest | ConvertTo-Json -Depth 8 -Compress) | ConvertFrom-Json
            $interruptedManifest.version = '0.1.0-test.2'
            $interruptedManifest.workerSha256 = (Get-FileHash `
                    -LiteralPath (Join-Path $windowsUpgradeKit 'cyc-worker.exe') `
                    -Algorithm SHA256).Hash.ToLowerInvariant()
            [System.IO.File]::WriteAllText(
                $installedManifest,
                (($interruptedManifest | ConvertTo-Json -Depth 8 -Compress) + "`n"),
                (New-Object System.Text.UTF8Encoding($false))
            )
            Remove-Item -LiteralPath $baselineCredentialPath -Force
            $script:FakeTaskExists = $false
            $script:FakeTaskRunning = $false

            $recoveryArguments = @{
                Action = 'Repair'
                BundleRoot = $windowsOldKit
                InstallRoot = $windowsTransactionInstall
                DataRoot = $windowsTransactionData
                WorkspaceRoot = $windowsTransactionWorkspace
                Scope = 'User'
                Confirm = $false
            }
            $recoveryText = ''
            $recoveryReceipt = $null
            try {
                $recoveryText = (. $windowsOldInstaller @recoveryArguments 2>&1 | Out-String)
                $recoveryReceipt = $recoveryText | ConvertFrom-Json
            } catch {
                $recoveryText += $_.Exception.Message
            }
            if ($recoveryText -match 'WINDOWS_.*SECRET_DO_NOT_LOG') {
                throw '[fixture-only] interrupted upgrade recovery leaked fixture credential material.'
            }
            $recoveredConfig = Read-CycWorkerKitsUtf8Json -Path $installedConfig
            $recoveredManifest = Read-CycWorkerKitsUtf8Json -Path $installedManifest
            if ($null -eq $recoveryReceipt -or
                [string]$recoveryReceipt.version -cne '0.1.0-test.1' -or
                [string]$recoveredManifest.version -cne '0.1.0-test.1' -or
                [string]$recoveredManifest.workerSha256 -cne [string]$baselineInstallManifest.workerSha256 -or
                [string]$recoveredConfig.worker -cne 'old' -or
                (Get-FileHash -LiteralPath $installedWorker -Algorithm SHA256).Hash -ne $baseline.worker -or
                (Get-FileHash -LiteralPath $installedConfig -Algorithm SHA256).Hash -ne $baseline.config -or
                (Get-FileHash -LiteralPath $baselineCredentialPath -Algorithm SHA256).Hash -ne $baseline.credential -or
                @((Get-ChildItem -LiteralPath $windowsTransactionData -Filter 'config.*.credential' -File)).Count -ne 1 -or
                -not $script:FakeTaskExists -or -not $script:FakeTaskRunning -or
                [string]::IsNullOrWhiteSpace([string]$script:FakeTaskXml) -or
                (Test-Path -LiteralPath $interruptedTransaction)) {
                throw '[fixture-only] interrupted upgrade rollback did not restore the complete N-1 state before re-entry.'
            }
            Write-Output '[fixture-only][fail-closed] interrupted upgrade rollback passed: the seeded transaction was reconciled before the N-1 repair retry.'
        }

        $routineConfig = (Get-FileHash -LiteralPath $installedConfig -Algorithm SHA256).Hash
        $routineCredential = (Get-FileHash -LiteralPath $baselineCredentialPath -Algorithm SHA256).Hash
        $routineReceipt = . $windowsUpgradeInstaller `
            -Action Repair `
            -BundleRoot $windowsUpgradeKit `
            -InstallRoot $windowsTransactionInstall `
            -DataRoot $windowsTransactionData `
            -WorkspaceRoot $windowsTransactionWorkspace `
            -Scope User `
            -Confirm:$false | ConvertFrom-Json
        if (-not $routineReceipt.paired -or -not $routineReceipt.serviceEnabled -or -not $script:FakeTaskRunning -or
            (Get-FileHash -LiteralPath $installedConfig -Algorithm SHA256).Hash -ne $routineConfig -or
            (Get-FileHash -LiteralPath $baselineCredentialPath -Algorithm SHA256).Hash -ne $routineCredential -or
            (Get-FileHash -LiteralPath $installedWorker -Algorithm SHA256).Hash -eq $baseline.worker) {
            throw 'Windows Ready-node routine repair did not preserve identity while swapping the worker.'
        }
        $routineManifest = Read-CycWorkerKitsUtf8Json -Path $installedManifest
        if ([string]$routineReceipt.version -cne '0.1.0-test.2' -or
            [string]$routineManifest.version -cne '0.1.0-test.2' -or
            [string]$routineManifest.workerSha256 -ne (Get-FileHash `
                    -LiteralPath $installedWorker -Algorithm SHA256).Hash.ToLowerInvariant()) {
            throw 'Windows N-1 to N fixture did not commit the candidate kit version and digest.'
        }
        if ($RunUpgradeRollbackFixtures) {
            Write-Output '[fixture-only][fail-closed] signed N-1 to N upgrade passed: detached fixture signatures were verified, the worker changed, and the paired identity was preserved.'

            # A downgrade must be rejected before any transaction or task
            # mutation.  This invokes the real fixture installer so a future
            # version gate becomes a regression check.  The current preview
            # intentionally has no downgrade gate; in that state this block
            # fails closed with the observed acceptance rather than silently
            # treating a downgrade as passing evidence.
            Write-Output '[fixture-only] downgrade rejection: invoking the N-1 installer against the committed N state; acceptance is a fail-closed regression.'
            $downgradeWorkerBefore = (Get-FileHash -LiteralPath $installedWorker -Algorithm SHA256).Hash
            $downgradeConfigBefore = (Get-FileHash -LiteralPath $installedConfig -Algorithm SHA256).Hash
            $downgradeCredentialBefore = (Get-FileHash -LiteralPath $baselineCredentialPath -Algorithm SHA256).Hash
            $downgradeManifestBefore = (Get-FileHash -LiteralPath $installedManifest -Algorithm SHA256).Hash
            $downgradeTaskXmlBefore = $script:FakeTaskXml
            $downgradeText = ''
            $downgradeReceipt = $null
            try {
                $downgradeText = (. $windowsOldInstaller @recoveryArguments 2>&1 | Out-String)
                try { $downgradeReceipt = $downgradeText | ConvertFrom-Json } catch { $downgradeReceipt = $null }
            } catch {
                $downgradeText += $_.Exception.Message
            }
            if ($downgradeText -match 'WINDOWS_.*SECRET_DO_NOT_LOG') {
                throw '[fixture-only] downgrade rejection leaked fixture credential material.'
            }
            if ($null -ne $downgradeReceipt) {
                throw "[fixture-only][fail-closed] downgrade rejection failed: N-1 installer was accepted after N was committed (receipt version=$([string]$downgradeReceipt.version))."
            }
            if ($downgradeText -notmatch '(?i)downgrade|older.*(version|kit)|version.*(older|downgrade)|newer.*(installed|already)') {
                throw "[fixture-only][fail-closed] downgrade rejection failed: installer failed without an explicit version-policy error ($($downgradeText.Trim()))."
            }
            if ((Get-FileHash -LiteralPath $installedWorker -Algorithm SHA256).Hash -ne $downgradeWorkerBefore -or
                (Get-FileHash -LiteralPath $installedConfig -Algorithm SHA256).Hash -ne $downgradeConfigBefore -or
                (Get-FileHash -LiteralPath $baselineCredentialPath -Algorithm SHA256).Hash -ne $downgradeCredentialBefore -or
                (Get-FileHash -LiteralPath $installedManifest -Algorithm SHA256).Hash -ne $downgradeManifestBefore -or
                -not $script:FakeTaskExists -or -not $script:FakeTaskRunning -or
                -not [string]::Equals($script:FakeTaskXml, $downgradeTaskXmlBefore, [StringComparison]::Ordinal) -or
                (Test-Path -LiteralPath (Join-Path $windowsTransactionData '.repair-transaction'))) {
                throw '[fixture-only][fail-closed] downgrade rejection mutated the committed N state.'
            }
            Write-Output '[fixture-only][fail-closed] downgrade rejection passed: the explicit older-version policy rejected the candidate before mutation.'
            Write-Output '[fixture-only][fail-closed] Issue #2 local upgrade fixtures passed; Authenticode, clean Windows 11 VM, live controller/worker, and externally retained signed GA evidence remain unverified.'
        }
    } finally {
        foreach ($functionName in @(
            'Get-ScheduledTask', 'Export-ScheduledTask', 'Stop-ScheduledTask', 'Unregister-ScheduledTask',
            'Start-ScheduledTask', 'Get-ScheduledTaskInfo', 'New-ScheduledTaskAction',
            'New-ScheduledTaskTrigger', 'New-ScheduledTaskPrincipal', 'New-ScheduledTaskSettingsSet',
            'Register-ScheduledTask', 'Assert-ForeignWorkerTaskRejected'
        )) {
            Remove-Item -LiteralPath ("Function:\" + $functionName) -Force -ErrorAction SilentlyContinue
        }
    }

    $linuxOutput = Join-Path $temporary 'linux'
    $null = & $builder -Target linux-aarch64 -WorkerExecutable $fakeWorker -OutputDirectory $linuxOutput -Version '0.1.0-test.1'
    $linuxManifest = Read-CycWorkerKitsUtf8Json -Path (Join-Path $linuxOutput 'worker-kit.json')
    if ($linuxManifest.os -ne 'linux' -or $linuxManifest.architecture -ne 'aarch64') { throw 'Linux manifest is invalid.' }

    foreach ($macosTarget in @('macos-x86_64', 'macos-aarch64')) {
        $macosOutput = Join-Path $temporary $macosTarget
        $macosBuild = & $builder `
            -Target $macosTarget `
            -WorkerExecutable $fakeWorker `
            -OutputDirectory $macosOutput `
            -Version '0.1.0-test.1' | ConvertFrom-Json
        if ($macosBuild.target -cne $macosTarget -or $macosBuild.version -cne '0.1.0-test.1') {
            throw "macOS worker-kit build receipt is invalid for $macosTarget."
        }
        $macosManifestPath = Join-Path $macosOutput 'worker-kit.json'
        $macosManifest = Read-CycWorkerKitsUtf8Json -Path $macosManifestPath
        $expectedArchitecture = if ($macosTarget.EndsWith('aarch64', [StringComparison]::Ordinal)) { 'aarch64' } else { 'x86_64' }
        if ($macosManifest.schemaVersion -cne 'cyc.dev/worker-kit/v1' -or
            $macosManifest.target -cne $macosTarget -or
            $macosManifest.os -cne 'macos' -or
            $macosManifest.architecture -cne $expectedArchitecture) {
            throw "macOS manifest is invalid for $macosTarget."
        }
        $macosFiles = @(Get-ChildItem -LiteralPath $macosOutput -Force)
        $macosFileNames = @($macosFiles | ForEach-Object Name | Sort-Object -CaseSensitive)
        $expectedMacosFiles = @('cyc-worker', 'install-worker.sh', 'SHA256SUMS', 'worker-kit.json', 'worker-kit.sig') | Sort-Object -CaseSensitive
        if ($macosFiles.Count -ne 5 -or ($macosFileNames -join ',') -cne ($expectedMacosFiles -join ',') -or
            @($macosFiles | Where-Object { -not $_.PSIsContainer -and (($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) }).Count -ne 0) {
            throw "macOS kit does not contain the exact five normal files for $macosTarget."
        }
        $macosManifestNames = @($macosManifest.files | ForEach-Object path)
        if (($macosManifestNames -join ',') -cne 'cyc-worker,install-worker.sh') {
            throw "macOS manifest does not bind the exact payload/lifecycle pair for $macosTarget."
        }
        foreach ($entry in $macosManifest.files) {
            $entryPath = Join-Path $macosOutput ([string]$entry.path)
            $entryHash = (Get-FileHash -LiteralPath $entryPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ([long]$entry.sizeBytes -ne (Get-Item -LiteralPath $entryPath).Length -or
                [string]$entry.sha256 -cne $entryHash) {
                throw "macOS manifest payload binding is invalid for $macosTarget/$($entry.path)."
            }
        }
        $macosSumNames = @(Get-Content -LiteralPath (Join-Path $macosOutput 'SHA256SUMS') |
            ForEach-Object { ($_ -split '  ', 2)[1] })
        if (($macosSumNames -join ',') -cne 'cyc-worker,install-worker.sh,worker-kit.json,worker-kit.sig') {
            throw "macOS checksums do not bind the exact four signed-kit inputs for $macosTarget."
        }
        foreach ($sumLine in Get-Content -LiteralPath (Join-Path $macosOutput 'SHA256SUMS')) {
            $parts = $sumLine -split '  ', 2
            $sumPath = Join-Path $macosOutput $parts[1]
            if ($parts[0] -cne (Get-FileHash -LiteralPath $sumPath -Algorithm SHA256).Hash.ToLowerInvariant()) {
                throw "macOS checksum mismatch for $macosTarget/$($parts[1])."
            }
        }
        $macosSignature = Read-CycWorkerKitsUtf8Json `
            -Path (Join-Path $macosOutput 'worker-kit.sig') -MaximumBytes 64KB
        if ($macosSignature.manifestSha256 -cne (Get-FileHash -LiteralPath $macosManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()) {
            throw "macOS signature envelope does not bind the manifest for $macosTarget."
        }
        $macosRawSignature = Join-Path $temporary ("$macosTarget-signature.raw")
        [IO.File]::WriteAllBytes($macosRawSignature, [Convert]::FromBase64String([string]$macosSignature.signature))
        & $openssl pkeyutl -verify -rawin -pubin -inkey $fixturePublicPem `
            -in $macosManifestPath -sigfile $macosRawSignature
        if ($LASTEXITCODE -ne 0) { throw "macOS publisher signature did not verify for $macosTarget." }
        $generatedMacosInstaller = [IO.File]::ReadAllText((Join-Path $macosOutput 'install-worker.sh'))
        if ($generatedMacosInstaller.Contains('__CYC_PUBLISHER_PUBLIC_KEY_BASE64__') -or
            -not $generatedMacosInstaller.Contains([IO.File]::ReadAllText($fixturePublicRaw).Trim())) {
            throw "macOS lifecycle trust root was not materialized exactly once for $macosTarget."
        }
    }

    if ($bashPath) {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $goodWorker = Join-Path $temporary 'fake-linux-worker'
        $upgradeWorker = Join-Path $temporary 'fake-linux-worker-upgrade'
        $badWorker = Join-Path $temporary 'fake-linux-worker-bad'
        [System.IO.File]::WriteAllText($goodWorker, @'
#!/usr/bin/env bash
set -euo pipefail
command_name="${1:-}"
shift || true
case "$command_name" in
  pair)
    config=''
    workspace=''
    repair=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --config) config="$2"; shift 2 ;;
        --enrollment-file) test -s "$2"; shift 2 ;;
        --workspace-root) workspace="$2"; shift 2 ;;
        --repair) repair=1; shift ;;
        *) exit 2 ;;
      esac
    done
    [[ "$workspace" == /* ]] || exit 3
    if [[ -e "$config" ]]; then
      [[ "$repair" -eq 1 ]] || exit 4
      old_credential="$(sed -n 's/.*"credentialFile":"\([^"]*\)".*/\1/p' "$config")"
      [[ -n "$old_credential" ]] || exit 6
    else
      [[ "$repair" -eq 0 ]] || exit 5
      old_credential=''
    fi
    credential="${config%.json}.$$.credential"
    printf '%s\n' 'LINUX_SECRET_DO_NOT_LOG' >"$credential"
    chmod 0600 "$credential"
    printf '{"paired":true,"worker":"good","workspaceRoot":"%s","repair":%s,"credentialFile":"%s"}\n' "$workspace" "$([[ "$repair" -eq 1 ]] && printf true || printf false)" "$credential" >"$config"
    if [[ -n "$old_credential" && "$old_credential" != "$credential" ]]; then rm -f -- "$old_credential"; fi
    ;;
  status|run) exit 0 ;;
  *) exit 2 ;;
esac
'@.TrimStart(), $utf8NoBom)
        [System.IO.File]::WriteAllText($upgradeWorker, ((Get-Content -LiteralPath $goodWorker -Raw) + "`n# upgraded worker fixture`n"), $utf8NoBom)
        [System.IO.File]::WriteAllText($badWorker, @'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  pair) exit 0 ;;
  status) exit 42 ;;
  run) exit 0 ;;
  *) exit 2 ;;
esac
'@.TrimStart(), $utf8NoBom)
        $goodKit = Join-Path $temporary 'linux-smoke-good'
        $upgradeKit = Join-Path $temporary 'linux-smoke-upgrade'
        $badKit = Join-Path $temporary 'linux-smoke-bad'
        $null = & $builder -Target linux-x86_64 -WorkerExecutable $goodWorker -OutputDirectory $goodKit -Version '0.1.0-test.1'
        $null = & $builder -Target linux-x86_64 -WorkerExecutable $upgradeWorker -OutputDirectory $upgradeKit -Version '0.1.0-test.2'
        $null = & $builder -Target linux-x86_64 -WorkerExecutable $badWorker -OutputDirectory $badKit -Version '0.1.0-test.2'
        $smoke = Join-Path $temporary 'linux-smoke.sh'
        [System.IO.File]::WriteAllText($smoke, @'
#!/usr/bin/env bash
set -euo pipefail
root="$(cygpath -u "$1")"
export HOME="$root/home"
export XDG_DATA_HOME="$root/xdg-data"
export XDG_CONFIG_HOME="$root/xdg-config"
export CYC_FAKE_SYSTEMD_ROOT="$root/fake-systemd"
mkdir -p "$HOME" "$root/fake-bin" "$root/fake-root-bin" "$CYC_FAKE_SYSTEMD_ROOT"
: >"$CYC_FAKE_SYSTEMD_ROOT/systemctl.log"
: >"$CYC_FAKE_SYSTEMD_ROOT/loginctl.log"
cat >"$root/fake-bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$CYC_FAKE_SYSTEMD_ROOT/systemctl.log"
if [[ "${1:-}" == --user ]]; then shift; fi
command_name="${1:-}"
shift || true
case "$command_name" in
  show-environment)
    [[ "${CYC_FAKE_USER_SYSTEMD_MODE:-ready}" != no-bus ]]
    ;;
  daemon-reload) ;;
  is-enabled) test -f "$CYC_FAKE_SYSTEMD_ROOT/service-enabled" ;;
  is-active) test -f "$CYC_FAKE_SYSTEMD_ROOT/service-active" ;;
  enable)
    : >"$CYC_FAKE_SYSTEMD_ROOT/service-enabled"
    if [[ "${1:-}" == --now ]]; then : >"$CYC_FAKE_SYSTEMD_ROOT/service-active"; fi
    ;;
  disable)
    rm -f -- "$CYC_FAKE_SYSTEMD_ROOT/service-enabled"
    if [[ "${1:-}" == --now ]]; then rm -f -- "$CYC_FAKE_SYSTEMD_ROOT/service-active"; fi
    ;;
  start) : >"$CYC_FAKE_SYSTEMD_ROOT/service-active" ;;
  stop) rm -f -- "$CYC_FAKE_SYSTEMD_ROOT/service-active" ;;
  *) exit 2 ;;
esac
EOF
cat >"$root/fake-bin/loginctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$CYC_FAKE_SYSTEMD_ROOT/loginctl.log"
case "${1:-}" in
  show-user)
    if [[ -f "$CYC_FAKE_SYSTEMD_ROOT/linger-enabled" ]]; then printf 'yes\n'; else printf 'no\n'; fi
    ;;
  enable-linger)
    [[ "${CYC_FAKE_USER_SYSTEMD_MODE:-ready}" != no-linger ]] || exit 1
    : >"$CYC_FAKE_SYSTEMD_ROOT/linger-enabled"
    ;;
  disable-linger)
    rm -f -- "$CYC_FAKE_SYSTEMD_ROOT/linger-enabled"
    ;;
  *) exit 2 ;;
esac
EOF
cat >"$root/fake-root-bin/id" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  -u) printf '0\n' ;;
  -un) printf 'root\n' ;;
  *) exit 2 ;;
esac
EOF
cat >"$root/fake-bin/install" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
directory=0
mode=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) directory=1; shift ;;
    -m) mode="$2"; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
if [[ "$directory" -eq 1 ]]; then
  mkdir -p -- "$@"
  if [[ -n "$mode" ]]; then chmod "$mode" -- "$@"; fi
  # Git Bash/MSYS cannot project a Windows DACL as a stable 0700 mode after
  # the child installer changes its umask. Leave a test-only marker for the
  # stat shim below so newly-created private roots still exercise the exact
  # mode contract without weakening the production installer.
  if [[ "$mode" == 0700 ]]; then
    for path in "$@"; do
      : >"$path/.cyc-worker-kit-test-mode-0700"
      chmod 0600 -- "$path/.cyc-worker-kit-test-mode-0700"
    done
  fi
else
  source="$1"
  destination="$2"
  cp -- "$source" "$destination"
  if [[ "$mode" == 0700 || "$mode" == 0755 ]]; then chmod +x "$destination" || true; fi
fi
EOF
chmod +x "$root/fake-bin/systemctl"
chmod +x "$root/fake-bin/loginctl"
chmod +x "$root/fake-bin/install"
chmod +x "$root/fake-root-bin/id"
cat >"$root/fake-bin/stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == -c && $# -ge 3 ]]; then
  path="${@: -1}"
  if [[ "${2:-}" == '%a' && "$path" == */.cyc-worker-kit-test-mode-0700 ]]; then
    printf '600\n'
    exit 0
  fi
  if [[ "${2:-}" == '%u' && "$path" == */.cyc-worker-kit-test-mode-0700 && "${CYC_WORKER_KIT_TEST_ROOT_MODE:-0}" == 1 ]]; then
    printf '0\n'
    exit 0
  fi
  if [[ "${2:-}" == '%u' && "${CYC_WORKER_KIT_TEST_ROOT_MODE:-0}" == 1 && "$path" == */.repair-transaction* ]]; then
    printf '0\n'
    exit 0
  fi
  if [[ "${2:-}" == '%u' && "${CYC_WORKER_KIT_TEST_FOREIGN_SERVICE:-0}" == 1 && "$path" == */clusteryourcodex-worker.service ]]; then
    printf '4294967294\n'
    exit 0
  fi
  if [[ "${2:-}" == '%a' && "$path" == *'/.repair-transaction'* && -f "$path" ]]; then
    printf '600\n'
    exit 0
  fi
  if [[ "${2:-}" == '%a' && "$path" == */clusteryourcodex-worker.service && -n "${CYC_WORKER_KIT_TEST_SERVICE_MODE:-}" ]]; then
    printf '%s\n' "$CYC_WORKER_KIT_TEST_SERVICE_MODE"
    exit 0
  fi
  if [[ "${2:-}" == '%a' && "$path" == */config.json && -n "${CYC_WORKER_KIT_TEST_CONFIG_MODE:-}" ]]; then
    printf '%s\n' "$CYC_WORKER_KIT_TEST_CONFIG_MODE"
    exit 0
  fi
  # Git Bash on Windows does not retain POSIX modes for regular files. The
  # production installers nevertheless require private transaction files to
  # be 0600, so project the fixture's transaction tree to the expected mode
  # while leaving the production implementation unchanged.
  if [[ "${2:-}" == '%a' && "$path" == */.repair-transaction* ]]; then
    if [[ -d "$path" ]]; then printf '700\n'; else printf '600\n'; fi
    exit 0
  fi
  if [[ -f "$path/.cyc-worker-kit-test-mode-0700" ]]; then
    if [[ "${2:-}" == '%a' ]]; then
      printf '700\n'
      exit 0
    fi
    if [[ "${2:-}" == '%u' && "${CYC_WORKER_KIT_TEST_ROOT_MODE:-0}" == 1 ]]; then
      printf '0\n'
      exit 0
    fi
  fi
fi
exec /usr/bin/stat "$@"
EOF
chmod +x "$root/fake-bin/stat"
export PATH="$root/fake-bin:$PATH"
export CYC_WORKER_KIT_TEST_CONFIG_MODE=600
export CYC_WORKER_KIT_TEST_SERVICE_MODE=600
good="$root/linux-smoke-good"
upgrade="$root/linux-smoke-upgrade"
bad="$root/linux-smoke-bad"
chmod +x "$good/cyc-worker" "$good/install-worker.sh" "$upgrade/cyc-worker" "$upgrade/install-worker.sh" "$bad/cyc-worker" "$bad/install-worker.sh"

# Existing private roots are verify-only. A deliberately weak directory must
# be rejected without chmod/chown or any child state being created.
weak_existing="$root/linux-weak-existing"
mkdir -p "$weak_existing"
printf '%s\n' 'LINUX_WEAK_STATE_SENTINEL' >"$weak_existing/sentinel.txt"
chmod 0777 "$weak_existing"
weak_mode_before="$(stat -c '%a' -- "$weak_existing")"
weak_sentinel_before="$(sha256sum -- "$weak_existing/sentinel.txt" | awk '{print $1}')"
set +e
"$good/install-worker.sh" install \
  --bundle-root "$good" \
  --install-root "$weak_existing" \
  --data-root "$root/linux-weak-data" \
  --workspace-root "$root/linux-weak-workspace" \
  --scope user \
  >"$root/linux-weak.stdout" 2>"$root/linux-weak.stderr"
weak_exit=$?
set -e
test "$weak_exit" -ne 0
grep -q 'Existing private directory is weak or owned by another identity' "$root/linux-weak.stderr"
test "$(stat -c '%a' -- "$weak_existing")" = "$weak_mode_before"
test "$(sha256sum -- "$weak_existing/sentinel.txt" | awk '{print $1}')" = "$weak_sentinel_before"
test ! -e "$root/linux-weak-data"
test ! -e "$root/linux-weak-workspace"

# A cryptographically valid kit whose signed product identity is tampered must
# still be rejected by the Linux contract verifier before any local state is
# created. The previous verifier only checked schema/os/architecture text and
# would accept this signed-but-contract-invalid manifest.
invalid_contract="$root/linux-contract-invalid"
cp -a -- "$good" "$invalid_contract"
fixture_private="$(cygpath -u "$CYC_WORKER_KIT_TEST_PRIVATE_KEY")"
test_python=''
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; assert sys.version_info >= (3, 8)' >/dev/null 2>&1; then
    test_python="$(command -v "$candidate")"
    break
  fi
done
test -n "$test_python"
"$test_python" - "$invalid_contract/worker-kit.json" <<'PY'
import json
import sys
from collections import OrderedDict
from pathlib import Path

manifest_path = Path(sys.argv[1])
manifest = json.loads(manifest_path.read_bytes().decode('utf-8'), object_pairs_hook=OrderedDict)
manifest['product'] = 'Tampered Worker Product'
manifest_path.write_bytes((json.dumps(manifest, ensure_ascii=False, separators=(',', ':')) + '\n').encode('utf-8'))
PY
openssl pkeyutl -sign -rawin -inkey "$fixture_private" \
  -in "$invalid_contract/worker-kit.json" -out "$invalid_contract/worker-kit.sig.raw"
"$test_python" - "$invalid_contract/worker-kit.json" \
  "$invalid_contract/worker-kit.sig.raw" \
  "$invalid_contract/worker-kit.sig" \
  "$invalid_contract/SHA256SUMS" <<'PY'
import base64
import hashlib
import json
import sys
from collections import OrderedDict
from pathlib import Path

manifest_path, signature_raw_path, signature_path, checksums_path = map(Path, sys.argv[1:])
signature = signature_raw_path.read_bytes()
envelope = OrderedDict([
    ('schemaVersion', 'cyc.dev/worker-kit-signature/v1'),
    ('algorithm', 'Ed25519'),
    ('keyId', 'cyc-release-2026-02'),
    ('signedObject', 'worker-kit.json'),
    ('manifestSha256', hashlib.sha256(manifest_path.read_bytes()).hexdigest()),
    ('signature', base64.b64encode(signature).decode('ascii')),
])
signature_path.write_bytes((json.dumps(envelope, separators=(',', ':')) + '\n').encode('utf-8'))
sum_names = ('cyc-worker', 'install-worker.sh', 'worker-kit.json', 'worker-kit.sig')
checksums_path.write_bytes(
    ''.join(f"{hashlib.sha256((checksums_path.parent / name).read_bytes()).hexdigest()}  {name}\n" for name in sum_names).encode('utf-8')
)
signature_raw_path.unlink()
PY
set +e
HOME="$root/invalid-home" "$invalid_contract/install-worker.sh" install \
  --bundle-root "$invalid_contract" \
  --install-root "$root/invalid-install" \
  --data-root "$root/invalid-data" \
  --workspace-root "$root/invalid-workspace" \
  --scope user \
  >"$root/invalid-contract.stdout" 2>"$root/invalid-contract.stderr"
invalid_contract_exit=$?
set -e
test "$invalid_contract_exit" -ne 0
grep -q 'Worker-kit publisher signature verification failed.' "$root/invalid-contract.stderr"
test ! -e "$root/invalid-install"
test ! -e "$root/invalid-data"
test ! -e "$root/invalid-workspace"

# Linux paths must reject every C0/DEL control character before realpath,
# systemd quoting, or JSON manifest generation. A TAB is a valid shell byte
# but is not a safe lifecycle path component.
control_path="${root}/linux-control"$'\t'"root"
set +e
"$good/install-worker.sh" install \
  --bundle-root "$good" \
  --install-root "$control_path" \
  --data-root "$root/linux-control-data" \
  --workspace-root "$root/linux-control-workspace" \
  --scope user \
  >"$root/linux-control.stdout" 2>"$root/linux-control.stderr"
control_path_exit=$?
set -e
test "$control_path_exit" -ne 0
grep -q 'Control characters are not allowed in paths.' "$root/linux-control.stderr"
test ! -e "$control_path"
test ! -e "$root/linux-control-data"
test ! -e "$root/linux-control-workspace"

# A failed first install must remove the newly-created ownership marker along
# with the restored transaction, otherwise a later call could treat the empty
# state as an owned installation.
first_failure_install="$root/linux-first-failure-install"
first_failure_data="$root/linux-first-failure-data"
first_failure_workspace="$root/linux-first-failure-workspace"
set +e
"$good/install-worker.sh" install \
  --bundle-root "$good" \
  --install-root "$first_failure_install" \
  --data-root "$first_failure_data" \
  --workspace-root "$first_failure_workspace" \
  --scope user \
  --failure-injection before-manifest-write \
  >"$root/linux-first-failure.stdout" 2>"$root/linux-first-failure.stderr"
first_failure_exit=$?
set -e
test "$first_failure_exit" -ne 0
test ! -e "$first_failure_data/.clusteryourcodex-worker-owned"
test ! -e "$first_failure_data/.repair-transaction"
test ! -e "$first_failure_install/cyc-worker"
test ! -e "$first_failure_data/install-manifest.json"

# If rollback is interrupted after removing the first-install marker, the
# sidecar tombstone keeps the journal resumable. Re-entry must consume both
# records before starting the next install, with no ownership state left over.
interrupted_install="$root/linux-interrupted-install"
interrupted_data="$root/linux-interrupted-data"
interrupted_workspace="$root/linux-interrupted-workspace"
interrupted_enrollment="$root/linux-interrupted-enrollment.json"
interrupted_fake_systemd="$root/fake-systemd-interrupted"
mkdir -p "$interrupted_fake_systemd"
printf '%s\n' 'LINUX_INTERRUPTED_ENROLLMENT_SECRET_DO_NOT_LOG' >"$interrupted_enrollment"
set +e
CYC_FAKE_SYSTEMD_ROOT="$interrupted_fake_systemd" "$bad/install-worker.sh" install \
  --bundle-root "$bad" \
  --install-root "$interrupted_install" \
  --data-root "$interrupted_data" \
  --workspace-root "$interrupted_workspace" \
  --scope user \
  --enrollment "$interrupted_enrollment" \
  --failure-injection after-marker-removal \
  >"$root/linux-interrupted.stdout" 2>"$root/linux-interrupted.stderr"
interrupted_exit=$?
set -e
test "$interrupted_exit" -ne 0
grep -q 'Injected worker repair failure at after-marker-removal' "$root/linux-interrupted.stderr"
! grep -q 'LINUX_.*SECRET_DO_NOT_LOG' "$root/linux-interrupted.stdout" "$root/linux-interrupted.stderr"
test ! -e "$interrupted_enrollment"
test ! -e "$interrupted_data/.clusteryourcodex-worker-owned"
test -d "$interrupted_data/.repair-transaction"
test -f "$interrupted_data/.repair-transaction.tombstone"
test "$(cat "$interrupted_data/.repair-transaction.tombstone")" = 'cyc.dev/linux-worker-repair-tombstone/v1'

interrupted_recovered="$(CYC_FAKE_SYSTEMD_ROOT="$interrupted_fake_systemd" "$good/install-worker.sh" install \
  --bundle-root "$good" \
  --install-root "$interrupted_install" \
  --data-root "$interrupted_data" \
  --workspace-root "$interrupted_workspace" \
  --scope user)"
printf '%s' "$interrupted_recovered" | grep -q '"paired":false'
test -x "$interrupted_install/cyc-worker"
test -f "$interrupted_data/.clusteryourcodex-worker-owned"
test -f "$interrupted_data/install-manifest.json"
test ! -e "$interrupted_data/.repair-transaction"
test ! -e "$interrupted_data/.repair-transaction.tombstone"
test ! -e "$interrupted_data/.repair-transaction.removing"
test ! -e "$CYC_FAKE_SYSTEMD_ROOT/linger-enabled"

# Root + auto resolves to system scope without probing or modifying a user
# manager. This is an unpaired preinstall, so it must not touch systemd.
root_login_lines_before="$(wc -l <"$CYC_FAKE_SYSTEMD_ROOT/loginctl.log")"
root_systemctl_lines_before="$(wc -l <"$CYC_FAKE_SYSTEMD_ROOT/systemctl.log")"
root_receipt="$(CYC_WORKER_KIT_TEST_ROOT_MODE=1 PATH="$root/fake-root-bin:$PATH" "$good/install-worker.sh" install \
  --bundle-root "$good" \
  --install-root "$root/root-auto-install" \
  --data-root "$root/root-auto-data" \
  --workspace-root "$root/root-auto-workspace")"
printf '%s' "$root_receipt" | grep -q '"scope":"system"'
printf '%s' "$root_receipt" | grep -q '"serviceEnabled":false'
root_login_lines_after="$(wc -l <"$CYC_FAKE_SYSTEMD_ROOT/loginctl.log")"
root_systemctl_lines_after="$(wc -l <"$CYC_FAKE_SYSTEMD_ROOT/systemctl.log")"
test "$root_login_lines_before" = "$root_login_lines_after"
test "$root_systemctl_lines_before" = "$root_systemctl_lines_after"

preinstall="$(/bin/sh "$good/install-worker.sh" -- install --bundle-root "$good")"
printf '%s' "$preinstall" | grep -q '"paired":false'
worker="$HOME/.local/lib/clusteryourcodex-worker/cyc-worker"
data="$XDG_DATA_HOME/clusteryourcodex/worker"
test -x "$worker"
test ! -e "$data/config.json"
test ! -e "$XDG_CONFIG_HOME/systemd/user/clusteryourcodex-worker.service"
printf '{"enrollment":"one-time"}\n' >"$root/enrollment.json"
activation="$("$good/install-worker.sh" repair --bundle-root "$good" --enrollment "$root/enrollment.json" --pair-only)"
printf '%s' "$activation" | grep -q '"paired":true'
printf '%s' "$activation" | grep -q '"serviceEnabled":false'
test -x "$worker"
test -s "$data/config.json"
grep -q '"repair":false' "$data/config.json"
test ! -e "$root/enrollment.json"
test ! -e "$XDG_CONFIG_HOME/systemd/user/clusteryourcodex-worker.service"
printf '{"enrollment":"rotation"}\n' >"$root/enrollment-rotation.json"
rotation="$("$good/install-worker.sh" repair --bundle-root "$good" --enrollment "$root/enrollment-rotation.json" --pair-only)"
printf '%s' "$rotation" | grep -q '"paired":true'
grep -q '"repair":true' "$data/config.json"
test ! -e "$root/enrollment-rotation.json"

# An existing paired config is verify-only. A weak mode must fail before the
# repair transaction or systemd is touched, and the installer must not repair
# the pre-positioned file in place.
paired_config_mode_before="$(stat -c '%a' -- "$data/config.json")"
test "$paired_config_mode_before" = 600
paired_config_hash_before="$(sha256sum "$data/config.json" | awk '{print $1}')"
paired_worker_hash_before="$(sha256sum "$worker" | awk '{print $1}')"
paired_manifest_hash_before="$(sha256sum "$data/install-manifest.json" | awk '{print $1}')"
paired_systemctl_lines_before="$(wc -l <"$CYC_FAKE_SYSTEMD_ROOT/systemctl.log" | tr -d '[:space:]')"
paired_loginctl_lines_before="$(wc -l <"$CYC_FAKE_SYSTEMD_ROOT/loginctl.log" | tr -d '[:space:]')"
chmod 0644 "$data/config.json"
export CYC_WORKER_KIT_TEST_CONFIG_MODE=644
set +e
"$good/install-worker.sh" repair --bundle-root "$good" --scope user \
  >"$root/linux-weak-config.stdout" 2>"$root/linux-weak-config.stderr"
weak_config_exit=$?
set -e
test "$weak_config_exit" -ne 0
grep -q 'Existing worker config is weak or owned by another identity' "$root/linux-weak-config.stderr"
test "$(stat -c '%a' -- "$data/config.json")" = 644
test "$(sha256sum "$data/config.json" | awk '{print $1}')" = "$paired_config_hash_before"
test "$(sha256sum "$worker" | awk '{print $1}')" = "$paired_worker_hash_before"
test "$(sha256sum "$data/install-manifest.json" | awk '{print $1}')" = "$paired_manifest_hash_before"
test "$(wc -l <"$CYC_FAKE_SYSTEMD_ROOT/systemctl.log" | tr -d '[:space:]')" = "$paired_systemctl_lines_before"
test "$(wc -l <"$CYC_FAKE_SYSTEMD_ROOT/loginctl.log" | tr -d '[:space:]')" = "$paired_loginctl_lines_before"
chmod 0600 "$data/config.json"
export CYC_WORKER_KIT_TEST_CONFIG_MODE=600

# A non-root auto/user activation must fail before worker/config/manifest
# mutation when linger exists or can be enabled but the user bus is absent.
worker_before_user_failure="$(sha256sum "$worker" | awk '{print $1}')"
config_before_user_failure="$(sha256sum "$data/config.json" | awk '{print $1}')"
manifest_before_user_failure="$(sha256sum "$data/install-manifest.json" | awk '{print $1}')"
set +e
CYC_FAKE_USER_SYSTEMD_MODE=no-bus "$good/install-worker.sh" repair --bundle-root "$good" \
  >"$root/user-systemd-failure.stdout" 2>"$root/user-systemd-failure.stderr"
user_systemd_exit=$?
set -e
test "$user_systemd_exit" -eq 78
grep -q 'CYC-LINUX-USER-SYSTEMD-UNAVAILABLE' "$root/user-systemd-failure.stderr"
grep -q -- '--scope system' "$root/user-systemd-failure.stderr"
test "$(sha256sum "$worker" | awk '{print $1}')" = "$worker_before_user_failure"
test "$(sha256sum "$data/config.json" | awk '{print $1}')" = "$config_before_user_failure"
test "$(sha256sum "$data/install-manifest.json" | awk '{print $1}')" = "$manifest_before_user_failure"
test ! -e "$XDG_CONFIG_HOME/systemd/user/clusteryourcodex-worker.service"
test ! -e "$CYC_FAKE_SYSTEMD_ROOT/linger-enabled"

enabled="$("$good/install-worker.sh" repair --bundle-root "$good")"
printf '%s' "$enabled" | grep -q '"serviceEnabled":true'
unit="$XDG_CONFIG_HOME/systemd/user/clusteryourcodex-worker.service"
test -s "$unit"
test -f "$CYC_FAKE_SYSTEMD_ROOT/linger-enabled"
test -f "$CYC_FAKE_SYSTEMD_ROOT/service-enabled"
test -f "$CYC_FAKE_SYSTEMD_ROOT/service-active"
grep -q -- '--user show-environment' "$CYC_FAKE_SYSTEMD_ROOT/systemctl.log"
grep -q '^KillMode=control-group$' "$unit"

# Existing user-systemd service state is verify-only. A weak unit parent must
# fail before marker/journal/worker/config/service mutation, and a foreign or
# weak existing unit must fail before the transaction can copy or remove it.
service_dir="$(dirname -- "$unit")"
service_dir_mode_marker="$service_dir/.cyc-worker-kit-test-mode-0700"
service_preflight_worker_hash_before="$(sha256sum "$worker" | awk '{print $1}')"
service_preflight_config_hash_before="$(sha256sum "$data/config.json" | awk '{print $1}')"
service_preflight_manifest_hash_before="$(sha256sum "$data/install-manifest.json" | awk '{print $1}')"
service_preflight_unit_hash_before="$(sha256sum "$unit" | awk '{print $1}')"
service_preflight_marker_hash_before="$(sha256sum "$data/.clusteryourcodex-worker-owned" | awk '{print $1}')"
service_preflight_systemctl_lines_before="$(wc -l <"$CYC_FAKE_SYSTEMD_ROOT/systemctl.log" | tr -d '[:space:]')"
service_preflight_loginctl_lines_before="$(wc -l <"$CYC_FAKE_SYSTEMD_ROOT/loginctl.log" | tr -d '[:space:]')"
rm -f -- "$service_dir_mode_marker"
chmod 0777 -- "$service_dir"
service_dir_mode_before="$(stat -c '%a' -- "$service_dir")"
set +e
"$good/install-worker.sh" repair --bundle-root "$good" --scope user \
  >"$root/linux-weak-service-dir.stdout" 2>"$root/linux-weak-service-dir.stderr"
weak_service_dir_exit=$?
set -e
test "$weak_service_dir_exit" -ne 0
grep -q 'Existing user service directory is weak or owned by another identity' "$root/linux-weak-service-dir.stderr"
# The weak pre-positioned parent must remain exactly as supplied; the installer
# is forbidden from chmod-adopting it during repair. Git Bash may project 0777
# as 0755, so compare against the observed preflight mode rather than a literal.
test "$(stat -c '%a' -- "$service_dir")" = "$service_dir_mode_before"
test "$(sha256sum "$worker" | awk '{print $1}')" = "$service_preflight_worker_hash_before"
test "$(sha256sum "$data/config.json" | awk '{print $1}')" = "$service_preflight_config_hash_before"
test "$(sha256sum "$data/install-manifest.json" | awk '{print $1}')" = "$service_preflight_manifest_hash_before"
test "$(sha256sum "$unit" | awk '{print $1}')" = "$service_preflight_unit_hash_before"
test "$(sha256sum "$data/.clusteryourcodex-worker-owned" | awk '{print $1}')" = "$service_preflight_marker_hash_before"
test "$(wc -l <"$CYC_FAKE_SYSTEMD_ROOT/systemctl.log" | tr -d '[:space:]')" = "$service_preflight_systemctl_lines_before"
test "$(wc -l <"$CYC_FAKE_SYSTEMD_ROOT/loginctl.log" | tr -d '[:space:]')" = "$service_preflight_loginctl_lines_before"
test ! -e "$data/.repair-transaction"
test ! -e "$data/.repair-transaction.tombstone"
chmod 0700 -- "$service_dir"
: >"$service_dir_mode_marker"
chmod 0600 -- "$service_dir_mode_marker"

set +e
CYC_WORKER_KIT_TEST_FOREIGN_SERVICE=1 "$good/install-worker.sh" repair --bundle-root "$good" --scope user \
  >"$root/linux-foreign-service.stdout" 2>"$root/linux-foreign-service.stderr"
foreign_service_exit=$?
set -e
test "$foreign_service_exit" -ne 0
grep -q 'Existing user service unit is weak or owned by another identity' "$root/linux-foreign-service.stderr"
test "$(sha256sum "$worker" | awk '{print $1}')" = "$service_preflight_worker_hash_before"
test "$(sha256sum "$data/config.json" | awk '{print $1}')" = "$service_preflight_config_hash_before"
test "$(sha256sum "$data/install-manifest.json" | awk '{print $1}')" = "$service_preflight_manifest_hash_before"
test "$(sha256sum "$unit" | awk '{print $1}')" = "$service_preflight_unit_hash_before"
test "$(sha256sum "$data/.clusteryourcodex-worker-owned" | awk '{print $1}')" = "$service_preflight_marker_hash_before"
test "$(wc -l <"$CYC_FAKE_SYSTEMD_ROOT/systemctl.log" | tr -d '[:space:]')" = "$service_preflight_systemctl_lines_before"
test "$(wc -l <"$CYC_FAKE_SYSTEMD_ROOT/loginctl.log" | tr -d '[:space:]')" = "$service_preflight_loginctl_lines_before"
test ! -e "$data/.repair-transaction"
test ! -e "$data/.repair-transaction.tombstone"

set +e
CYC_WORKER_KIT_TEST_SERVICE_MODE=644 "$good/install-worker.sh" repair --bundle-root "$good" --scope user \
  >"$root/linux-weak-service-unit.stdout" 2>"$root/linux-weak-service-unit.stderr"
weak_service_unit_exit=$?
set -e
test "$weak_service_unit_exit" -ne 0
grep -q 'Existing user service unit is weak or owned by another identity' "$root/linux-weak-service-unit.stderr"
test "$(sha256sum "$worker" | awk '{print $1}')" = "$service_preflight_worker_hash_before"
test "$(sha256sum "$data/config.json" | awk '{print $1}')" = "$service_preflight_config_hash_before"
test "$(sha256sum "$data/install-manifest.json" | awk '{print $1}')" = "$service_preflight_manifest_hash_before"
test "$(sha256sum "$unit" | awk '{print $1}')" = "$service_preflight_unit_hash_before"
test "$(sha256sum "$data/.clusteryourcodex-worker-owned" | awk '{print $1}')" = "$service_preflight_marker_hash_before"
test "$(wc -l <"$CYC_FAKE_SYSTEMD_ROOT/systemctl.log" | tr -d '[:space:]')" = "$service_preflight_systemctl_lines_before"
test "$(wc -l <"$CYC_FAKE_SYSTEMD_ROOT/loginctl.log" | tr -d '[:space:]')" = "$service_preflight_loginctl_lines_before"
test ! -e "$data/.repair-transaction"
test ! -e "$data/.repair-transaction.tombstone"

# An ownership marker without its manifest is not sufficient authority to
# remove a computed same-named systemd unit. The lifecycle must fail closed
# before invoking systemd or changing the worker, config, or unit.
missing_manifest_backup="$root/linux-missing-manifest.backup"
cp -- "$data/install-manifest.json" "$missing_manifest_backup"
missing_manifest_worker_hash="$(sha256sum "$worker" | awk '{print $1}')"
missing_manifest_config_hash="$(sha256sum "$data/config.json" | awk '{print $1}')"
missing_manifest_unit_hash="$(sha256sum "$unit" | awk '{print $1}')"
missing_manifest_systemctl_lines="$(wc -l <"$CYC_FAKE_SYSTEMD_ROOT/systemctl.log" | tr -d '[:space:]')"
rm -f -- "$data/install-manifest.json"
set +e
"$good/install-worker.sh" uninstall --bundle-root "$good" --scope user \
  >"$root/linux-missing-manifest.stdout" 2>"$root/linux-missing-manifest.stderr"
missing_manifest_exit=$?
set -e
test "$missing_manifest_exit" -ne 0
test ! -s "$root/linux-missing-manifest.stdout"
grep -q 'Owned worker install manifest is missing or unsafe.' "$root/linux-missing-manifest.stderr"
test -f "$data/.clusteryourcodex-worker-owned"
test -f "$worker"
test -f "$unit"
test "$(sha256sum "$worker" | awk '{print $1}')" = "$missing_manifest_worker_hash"
test "$(sha256sum "$data/config.json" | awk '{print $1}')" = "$missing_manifest_config_hash"
test "$(sha256sum "$unit" | awk '{print $1}')" = "$missing_manifest_unit_hash"
test "$(wc -l <"$CYC_FAKE_SYSTEMD_ROOT/systemctl.log" | tr -d '[:space:]')" = "$missing_manifest_systemctl_lines"
cp -- "$missing_manifest_backup" "$data/install-manifest.json"
rm -f -- "$missing_manifest_backup"

# Ready-node repair is one transaction. A normal repair does not rotate the
# credential; injected failures after pair, service registration, and before
# manifest commit must restore every old byte and the active/enabled state.
baseline_worker="$(sha256sum "$worker" | awk '{print $1}')"
baseline_config="$(sha256sum "$data/config.json" | awk '{print $1}')"
baseline_manifest="$(sha256sum "$data/install-manifest.json" | awk '{print $1}')"
baseline_unit="$(sha256sum "$unit" | awk '{print $1}')"
baseline_credential_path="$(sed -n 's/.*"credentialFile":"\([^"]*\)".*/\1/p' "$data/config.json")"
test -f "$baseline_credential_path"
baseline_credential="$(sha256sum "$baseline_credential_path" | awk '{print $1}')"

for injection in after-pair after-service-registration before-manifest-write; do
  enrollment_args=()
  if [[ "$injection" == after-pair ]]; then
    printf '%s\n' 'LINUX_ENROLLMENT_SECRET_DO_NOT_LOG' >"$root/enrollment-$injection.json"
    enrollment_args=(--enrollment "$root/enrollment-$injection.json")
  fi
  set +e
  "$upgrade/install-worker.sh" repair --bundle-root "$upgrade" \
    "${enrollment_args[@]}" --failure-injection "$injection" \
    >"$root/$injection.stdout" 2>"$root/$injection.stderr"
  injection_exit=$?
  set -e
  test "$injection_exit" -ne 0
  ! grep -q 'LINUX_.*SECRET_DO_NOT_LOG' "$root/$injection.stdout" "$root/$injection.stderr"
  test "$(sha256sum "$worker" | awk '{print $1}')" = "$baseline_worker"
  test "$(sha256sum "$data/config.json" | awk '{print $1}')" = "$baseline_config"
  test "$(sha256sum "$data/install-manifest.json" | awk '{print $1}')" = "$baseline_manifest"
  test "$(sha256sum "$unit" | awk '{print $1}')" = "$baseline_unit"
  test "$(sha256sum "$baseline_credential_path" | awk '{print $1}')" = "$baseline_credential"
  "$worker" status --config "$data/config.json" >/dev/null
  test "$(find "$data" -maxdepth 1 -type f -name 'config.*.credential' | wc -l)" -eq 1
  test -f "$CYC_FAKE_SYSTEMD_ROOT/service-enabled"
  test -f "$CYC_FAKE_SYSTEMD_ROOT/service-active"
  test ! -e "$data/.repair-transaction"
done

# Existing ownership is bound to the install manifest roots. A lifecycle call
# with a different install/workspace root must fail before service removal and
# leave unrelated same-named files untouched.
bound_install_root="$(dirname "$worker")"
bound_workspace_root="$data/workspace"
bound_systemctl_lines="$(wc -l <"$CYC_FAKE_SYSTEMD_ROOT/systemctl.log" | tr -d '[:space:]')"
bound_loginctl_lines="$(wc -l <"$CYC_FAKE_SYSTEMD_ROOT/loginctl.log" | tr -d '[:space:]')"
bound_worker_hash="$(sha256sum "$worker" | awk '{print $1}')"
bound_config_hash="$(sha256sum "$data/config.json" | awk '{print $1}')"
bound_manifest_hash="$(sha256sum "$data/install-manifest.json" | awk '{print $1}')"
bound_unit_hash="$(sha256sum "$unit" | awk '{print $1}')"
bound_credential_hash="$(sha256sum "$baseline_credential_path" | awk '{print $1}')"

assert_linux_manifest_binding_failure() {
  local label="$1" requested_install_root="$2" requested_workspace_root="$3" sentinel="$4"
  set +e
  "$good/install-worker.sh" uninstall --bundle-root "$good" \
    --install-root "$requested_install_root" \
    --data-root "$data" \
    --workspace-root "$requested_workspace_root" \
    --scope user \
    >"$root/$label.stdout" 2>"$root/$label.stderr"
  local binding_exit=$?
  set -e
  test "$binding_exit" -ne 0
  test ! -s "$root/$label.stdout"
  grep -q 'Installer paths do not match the existing owned installation.' "$root/$label.stderr"
  test "$(sha256sum "$worker" | awk '{print $1}')" = "$bound_worker_hash"
  test "$(sha256sum "$data/config.json" | awk '{print $1}')" = "$bound_config_hash"
  test "$(sha256sum "$data/install-manifest.json" | awk '{print $1}')" = "$bound_manifest_hash"
  test "$(sha256sum "$unit" | awk '{print $1}')" = "$bound_unit_hash"
  test "$(sha256sum "$baseline_credential_path" | awk '{print $1}')" = "$bound_credential_hash"
  test "$(wc -l <"$CYC_FAKE_SYSTEMD_ROOT/systemctl.log" | tr -d '[:space:]')" = "$bound_systemctl_lines"
  test "$(wc -l <"$CYC_FAKE_SYSTEMD_ROOT/loginctl.log" | tr -d '[:space:]')" = "$bound_loginctl_lines"
  test -f "$CYC_FAKE_SYSTEMD_ROOT/service-enabled"
  test -f "$CYC_FAKE_SYSTEMD_ROOT/service-active"
  test ! -e "$data/.repair-transaction"
  test -f "$sentinel"
  test "$(cat "$sentinel")" = 'LINUX_PATH_BINDING_SENTINEL'
}

wrong_install_root="$root/linux-wrong-install"
install -d -m 0700 -- "$wrong_install_root"
printf '%s\n' 'LINUX_PATH_BINDING_SENTINEL' >"$wrong_install_root/cyc-worker"
chmod +x "$wrong_install_root/cyc-worker"
assert_linux_manifest_binding_failure \
  linux-wrong-install \
  "$wrong_install_root" \
  "$bound_workspace_root" \
  "$wrong_install_root/cyc-worker"

wrong_workspace_root="$root/linux-wrong-workspace"
install -d -m 0700 -- "$wrong_workspace_root"
printf '%s\n' 'LINUX_PATH_BINDING_SENTINEL' >"$wrong_workspace_root/worker-sentinel"
assert_linux_manifest_binding_failure \
  linux-wrong-workspace \
  "$bound_install_root" \
  "$wrong_workspace_root" \
  "$wrong_workspace_root/worker-sentinel"

# A changed XDG_CONFIG_HOME must not redirect cleanup to a same-named foreign
# user unit. The service path is recorded in the owned manifest and checked
# before any systemd command or file mutation.
wrong_xdg_config="$root/xdg-config-foreign"
wrong_xdg_unit="$wrong_xdg_config/systemd/user/clusteryourcodex-worker.service"
mkdir -p "$(dirname "$wrong_xdg_unit")"
printf '%s\n' 'LINUX_XDG_PATH_BINDING_SENTINEL' >"$wrong_xdg_unit"
xdg_systemctl_lines_before="$(wc -l <"$CYC_FAKE_SYSTEMD_ROOT/systemctl.log" | tr -d '[:space:]')"
xdg_worker_hash_before="$(sha256sum "$worker" | awk '{print $1}')"
xdg_manifest_hash_before="$(sha256sum "$data/install-manifest.json" | awk '{print $1}')"
set +e
XDG_CONFIG_HOME="$wrong_xdg_config" "$good/install-worker.sh" uninstall --bundle-root "$good" \
  --install-root "$bound_install_root" \
  --data-root "$data" \
  --workspace-root "$bound_workspace_root" \
  --scope user \
  >"$root/xdg-path-binding.stdout" 2>"$root/xdg-path-binding.stderr"
xdg_binding_exit=$?
set -e
test "$xdg_binding_exit" -ne 0
grep -q 'Installer service path does not match the existing owned installation.' "$root/xdg-path-binding.stderr"
test "$(sha256sum "$worker" | awk '{print $1}')" = "$xdg_worker_hash_before"
test "$(sha256sum "$data/install-manifest.json" | awk '{print $1}')" = "$xdg_manifest_hash_before"
test "$(wc -l <"$CYC_FAKE_SYSTEMD_ROOT/systemctl.log" | tr -d '[:space:]')" = "$xdg_systemctl_lines_before"
test -f "$wrong_xdg_unit"
test "$(cat "$wrong_xdg_unit")" = 'LINUX_XDG_PATH_BINDING_SENTINEL'

before="$(sha256sum "$worker" | awk '{print $1}')"

# Routine Ready -> Repair keeps the existing identity and credential while it
# atomically swaps the binary/unit and returns a paired, running receipt.
routine_config_before="$(sha256sum "$data/config.json" | awk '{print $1}')"
routine_credential_before="$(sha256sum "$baseline_credential_path" | awk '{print $1}')"
routine="$($upgrade/install-worker.sh repair --bundle-root "$upgrade")"
printf '%s' "$routine" | grep -q '"paired":true'
printf '%s' "$routine" | grep -q '"serviceEnabled":true'
test "$(sha256sum "$data/config.json" | awk '{print $1}')" = "$routine_config_before"
test "$(sha256sum "$baseline_credential_path" | awk '{print $1}')" = "$routine_credential_before"
test "$(sha256sum "$worker" | awk '{print $1}')" != "$baseline_worker"
test -f "$CYC_FAKE_SYSTEMD_ROOT/service-enabled"
test -f "$CYC_FAKE_SYSTEMD_ROOT/service-active"

before="$(sha256sum "$worker" | awk '{print $1}')"
if "$bad/install-worker.sh" repair --bundle-root "$bad" >/dev/null 2>&1; then
  printf 'Expected bad-worker repair to fail.\n' >&2
  exit 1
fi
after="$(sha256sum "$worker" | awk '{print $1}')"
test "$before" = "$after"
"$good/install-worker.sh" repair --bundle-root "$good" >/dev/null
"$good/install-worker.sh" uninstall --bundle-root "$good" >/dev/null
test ! -e "$worker"
test -s "$data/config.json"
"$good/install-worker.sh" install --bundle-root "$good" >/dev/null
"$good/install-worker.sh" uninstall --bundle-root "$good" --purge-data >/dev/null
test ! -e "$data"
'@.TrimStart(), $utf8NoBom)
        & $bashPath $smoke $temporary
        if ($LASTEXITCODE -ne 0) { throw 'Linux worker lifecycle smoke test failed.' }

        $macosGoodKit = Join-Path $temporary 'macos-smoke-good'
        $macosUpgradeKit = Join-Path $temporary 'macos-smoke-upgrade'
        $macosBadKit = Join-Path $temporary 'macos-smoke-bad'
        $null = & $builder -Target macos-x86_64 -WorkerExecutable $goodWorker -OutputDirectory $macosGoodKit -Version '0.1.0-test.1'
        $null = & $builder -Target macos-x86_64 -WorkerExecutable $upgradeWorker -OutputDirectory $macosUpgradeKit -Version '0.1.0-test.2'
        $null = & $builder -Target macos-x86_64 -WorkerExecutable $badWorker -OutputDirectory $macosBadKit -Version '0.1.0-test.2'
        $macosSmoke = Join-Path $temporary 'macos-smoke.sh'
        [System.IO.File]::WriteAllText($macosSmoke, @'
#!/usr/bin/env bash
set -euo pipefail
root="$(cygpath -u "$1")"
export HOME="$root/macos-home"
mkdir -p "$HOME" "$root/fake-macos-bin"

export CYC_REAL_PYTHON="$(command -v python)"
test -n "$CYC_REAL_PYTHON"
cat >"$root/fake-macos-bin/python3" <<'PYTHON_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
translated=()
for value in "$@"; do
  if [[ "$value" == /?/* && -e "$value" ]]; then
    translated+=("$(cygpath -w "$value")")
  else
    translated+=("$value")
  fi
done
exec "$CYC_REAL_PYTHON" "${translated[@]}"
PYTHON_WRAPPER
cat >"$root/fake-macos-bin/uname" <<'UNAME_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  -s) printf '%s\n' Darwin ;;
  -m) printf '%s\n' x86_64 ;;
  *) printf '%s\n' Darwin ;;
esac
UNAME_WRAPPER
cat >"$root/fake-macos-bin/shasum" <<'SHASUM_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -a && "${2:-}" == 256 && $# -eq 3 ]] || exit 2
sha256sum "$3"
SHASUM_WRAPPER
cat >"$root/fake-macos-bin/chmod" <<'CHMOD_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
mode="${1:-}"
shift || true
/usr/bin/chmod "$mode" "$@"
if [[ "$mode" == 0700 ]]; then
  for path in "$@"; do
    [[ "$path" != -* ]] || continue
    : >"$path/.cyc-worker-kit-test-mode-0700"
    /usr/bin/chmod 0600 -- "$path/.cyc-worker-kit-test-mode-0700"
  done
fi
CHMOD_WRAPPER
cat >"$root/fake-macos-bin/stat" <<'STAT_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == -c && $# -ge 3 ]]; then
  path="${@: -1}"
  if [[ "${2:-}" == '%a' && "$path" == */.cyc-worker-kit-test-mode-0700 ]]; then
    printf '600\n'
    exit 0
  fi
  if [[ "${2:-}" == '%u' && "$path" == */.cyc-worker-kit-test-mode-0700 && "${CYC_WORKER_KIT_TEST_ROOT_MODE:-0}" == 1 ]]; then
    printf '0\n'
    exit 0
  fi
  if [[ "${2:-}" == '%a' && "$path" == *'/.repair-transaction'* && -f "$path" ]]; then
    printf '600\n'
    exit 0
  fi
  if [[ "${2:-}" == '%a' && "$path" == */config.json && -n "${CYC_WORKER_KIT_TEST_CONFIG_MODE:-}" ]]; then
    printf '%s\n' "$CYC_WORKER_KIT_TEST_CONFIG_MODE"
    exit 0
  fi
  if [[ "${2:-}" == '%a' && "$path" == */.repair-transaction* ]]; then
    if [[ -d "$path" ]]; then printf '700\n'; else printf '600\n'; fi
    exit 0
  fi
  if [[ "${2:-}" == '%a' && -f "$path/.cyc-worker-kit-test-mode-0700" ]]; then
    printf '700\n'
    exit 0
  fi
fi
exec /usr/bin/stat "$@"
STAT_WRAPPER
cat >"$root/fake-macos-bin/launchctl" <<'LAUNCHCTL_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$CYC_FAKE_LAUNCHCTL_LOG"
case "${1:-}" in
  print) exit 1 ;;
  bootout|bootstrap|kickstart) exit 0 ;;
  *) exit 0 ;;
esac
LAUNCHCTL_WRAPPER
export CYC_FAKE_LAUNCHCTL_LOG="$root/fake-launchctl.log"
: >"$CYC_FAKE_LAUNCHCTL_LOG"
chmod +x "$root/fake-macos-bin/python3" "$root/fake-macos-bin/uname" "$root/fake-macos-bin/shasum" "$root/fake-macos-bin/launchctl"
chmod +x "$root/fake-macos-bin/chmod" "$root/fake-macos-bin/stat"
export PATH="$root/fake-macos-bin:$PATH"
export CYC_WORKER_KIT_TEST_CONFIG_MODE=600

good="$root/macos-smoke-good"
upgrade="$root/macos-smoke-upgrade"
bad="$root/macos-smoke-bad"
chmod +x "$good/cyc-worker" "$good/install-worker.sh" "$upgrade/cyc-worker" "$upgrade/install-worker.sh"
chmod +x "$bad/cyc-worker" "$bad/install-worker.sh"
install_root="$root/macos-install"
data_root="$root/macos-data"
workspace_root="$root/macos-workspace"
logs_root="$root/macos-logs"
common=(--install-root "$install_root" --data-root "$data_root" --workspace-root "$workspace_root" --logs-root "$logs_root")

# Existing macOS private roots are verify-only. The fake-Darwin harness uses
# the host stat implementation, so this also proves the mode/owner check is
# portable across the native BSD and GNU stat spellings.
weak_existing="$root/macos-weak-existing"
mkdir -p "$weak_existing"
printf '%s\n' 'MACOS_WEAK_STATE_SENTINEL' >"$weak_existing/sentinel.txt"
chmod 0777 "$weak_existing"
weak_mode_before="$(stat -c '%a' -- "$weak_existing")"
weak_sentinel_before="$(sha256sum -- "$weak_existing/sentinel.txt" | awk '{print $1}')"
set +e
"$good/install-worker.sh" install \
  --bundle-root "$good" \
  --install-root "$weak_existing" \
  --data-root "$root/macos-weak-data" \
  --workspace-root "$root/macos-weak-workspace" \
  --logs-root "$root/macos-weak-logs" \
  >"$root/macos-weak.stdout" 2>"$root/macos-weak.stderr"
weak_exit=$?
set -e
test "$weak_exit" -ne 0
grep -q 'Existing private directory is weak or owned by another identity' "$root/macos-weak.stderr"
test "$(stat -c '%a' -- "$weak_existing")" = "$weak_mode_before"
test "$(sha256sum -- "$weak_existing/sentinel.txt" | awk '{print $1}')" = "$weak_sentinel_before"
test ! -e "$root/macos-weak-data"
test ! -e "$root/macos-weak-workspace"
test ! -e "$root/macos-weak-logs"

# An existing LaunchAgents parent is also verify-only. A weak parent must fail
# before any lifecycle root, marker, plist, or launchctl state is adopted.
weak_launch_home="$root/macos-weak-launch-home"
weak_launch_parent="$weak_launch_home/Library/LaunchAgents"
weak_launch_install="$root/macos-weak-launch-install"
weak_launch_data="$root/macos-weak-launch-data"
weak_launch_workspace="$root/macos-weak-launch-workspace"
weak_launch_logs="$root/macos-weak-launch-logs"
mkdir -p "$weak_launch_parent"
printf '%s\n' 'MACOS_WEAK_LAUNCHAGENTS_SENTINEL' >"$weak_launch_parent/sentinel.txt"
chmod 0777 "$weak_launch_parent"
weak_launch_parent_hash_before="$(sha256sum -- "$weak_launch_parent/sentinel.txt" | awk '{print $1}')"
weak_launch_parent_mode_before="$(stat -c '%a' -- "$weak_launch_parent")"
weak_launchctl_lines_before="$(wc -l <"$CYC_FAKE_LAUNCHCTL_LOG" | tr -d '[:space:]')"
set +e
HOME="$weak_launch_home" "$good/install-worker.sh" install \
  --bundle-root "$good" \
  --install-root "$weak_launch_install" \
  --data-root "$weak_launch_data" \
  --workspace-root "$weak_launch_workspace" \
  --logs-root "$weak_launch_logs" \
  >"$root/macos-weak-launch-parent.stdout" 2>"$root/macos-weak-launch-parent.stderr"
weak_launch_parent_exit=$?
set -e
test "$weak_launch_parent_exit" -ne 0
grep -q 'Existing LaunchAgents directory is weak or owned by another identity' "$root/macos-weak-launch-parent.stderr"
test "$(stat -c '%a' -- "$weak_launch_parent")" = "$weak_launch_parent_mode_before"
test "$(sha256sum -- "$weak_launch_parent/sentinel.txt" | awk '{print $1}')" = "$weak_launch_parent_hash_before"
test "$(wc -l <"$CYC_FAKE_LAUNCHCTL_LOG" | tr -d '[:space:]')" = "$weak_launchctl_lines_before"
test ! -e "$weak_launch_install/cyc-worker"
test ! -e "$weak_launch_data"
test ! -e "$weak_launch_workspace"
test ! -e "$weak_launch_logs"

# With a private LaunchAgents parent, an existing weak plist is rejected before
# it can be booted out or replaced by a repair transaction.
weak_plist_home="$root/macos-weak-plist-home"
weak_plist_parent="$weak_plist_home/Library/LaunchAgents"
weak_plist_path="$weak_plist_parent/dev.clusteryourcodex.worker.plist"
weak_plist_install="$root/macos-weak-plist-install"
weak_plist_data="$root/macos-weak-plist-data"
weak_plist_workspace="$root/macos-weak-plist-workspace"
weak_plist_logs="$root/macos-weak-plist-logs"
mkdir -p "$weak_plist_parent"
chmod 0700 "$weak_plist_parent"
printf '%s\n' 'MACOS_WEAK_PLIST_SENTINEL' >"$weak_plist_path"
chmod 0644 "$weak_plist_path"
weak_plist_hash_before="$(sha256sum -- "$weak_plist_path" | awk '{print $1}')"
weak_plist_mode_before="$(stat -c '%a' -- "$weak_plist_path")"
weak_plist_parent_mode_before="$(stat -c '%a' -- "$weak_plist_parent")"
weak_plist_launchctl_lines_before="$(wc -l <"$CYC_FAKE_LAUNCHCTL_LOG" | tr -d '[:space:]')"
set +e
HOME="$weak_plist_home" "$good/install-worker.sh" install \
  --bundle-root "$good" \
  --install-root "$weak_plist_install" \
  --data-root "$weak_plist_data" \
  --workspace-root "$weak_plist_workspace" \
  --logs-root "$weak_plist_logs" \
  >"$root/macos-weak-plist.stdout" 2>"$root/macos-weak-plist.stderr"
weak_plist_exit=$?
set -e
test "$weak_plist_exit" -ne 0
grep -q 'Existing LaunchAgent is weak or owned by another identity' "$root/macos-weak-plist.stderr"
test "$(stat -c '%a' -- "$weak_plist_parent")" = "$weak_plist_parent_mode_before"
test "$(stat -c '%a' -- "$weak_plist_path")" = "$weak_plist_mode_before"
test "$(sha256sum -- "$weak_plist_path" | awk '{print $1}')" = "$weak_plist_hash_before"
test "$(wc -l <"$CYC_FAKE_LAUNCHCTL_LOG" | tr -d '[:space:]')" = "$weak_plist_launchctl_lines_before"
test ! -e "$weak_plist_install/cyc-worker"
test ! -e "$weak_plist_data"
test ! -e "$weak_plist_workspace"
test ! -e "$weak_plist_logs"

# This deterministic fake-Darwin fixture exercises only the transaction
# state-machine re-entry path; it does not claim live macOS LaunchAgent
# evidence while the containment gate remains closed.
interrupted_install="$root/macos-interrupted-install"
interrupted_data="$root/macos-interrupted-data"
interrupted_workspace="$root/macos-interrupted-workspace"
interrupted_logs="$root/macos-interrupted-logs"
interrupted_enrollment="$root/macos-interrupted-enrollment.json"
printf '%s\n' 'MACOS_INTERRUPTED_ENROLLMENT_SECRET_DO_NOT_LOG' >"$interrupted_enrollment"
set +e
"$bad/install-worker.sh" install --bundle-root "$bad" \
  --install-root "$interrupted_install" \
  --data-root "$interrupted_data" \
  --workspace-root "$interrupted_workspace" \
  --logs-root "$interrupted_logs" \
  --enrollment "$interrupted_enrollment" \
  --pair-only \
  --failure-injection after-marker-removal \
  >"$root/macos-interrupted.stdout" 2>"$root/macos-interrupted.stderr"
interrupted_exit=$?
set -e
test "$interrupted_exit" -ne 0
grep -q 'Injected worker repair failure at after-marker-removal' "$root/macos-interrupted.stderr"
! grep -q 'MACOS_.*SECRET_DO_NOT_LOG' "$root/macos-interrupted.stdout" "$root/macos-interrupted.stderr"
test ! -e "$interrupted_enrollment"
test ! -e "$interrupted_data/.clusteryourcodex-worker-owned"
test ! -e "$interrupted_logs/.clusteryourcodex-worker-logs-owned"
test -d "$interrupted_data/.repair-transaction"
test -f "$interrupted_data/.repair-transaction.tombstone"
test "$(cat "$interrupted_data/.repair-transaction.tombstone")" = 'cyc.dev/macos-worker-repair-tombstone/v1'

interrupted_recovered="$($good/install-worker.sh install --bundle-root "$good" \
  --install-root "$interrupted_install" \
  --data-root "$interrupted_data" \
  --workspace-root "$interrupted_workspace" \
  --logs-root "$interrupted_logs")"
printf '%s' "$interrupted_recovered" | grep -q '"paired":false'
test -x "$interrupted_install/cyc-worker"
test -f "$interrupted_data/.clusteryourcodex-worker-owned"
test -f "$interrupted_logs/.clusteryourcodex-worker-logs-owned"
test -f "$interrupted_data/install-manifest.json"
test ! -e "$interrupted_data/.repair-transaction"
test ! -e "$interrupted_data/.repair-transaction.tombstone"
test ! -e "$interrupted_data/.repair-transaction.removing"

# A failed first macOS install must remove both newly-created ownership
# markers along with the restored transaction, even while LaunchAgent
# activation remains gated.
first_failure_install="$root/macos-first-failure-install"
first_failure_data="$root/macos-first-failure-data"
first_failure_workspace="$root/macos-first-failure-workspace"
first_failure_logs="$root/macos-first-failure-logs"
set +e
$good/install-worker.sh install --bundle-root "$good" \
  --install-root "$first_failure_install" \
  --data-root "$first_failure_data" \
  --workspace-root "$first_failure_workspace" \
  --logs-root "$first_failure_logs" \
  --failure-injection before-manifest-write \
  >"$root/macos-first-failure.stdout" 2>"$root/macos-first-failure.stderr"
first_failure_exit=$?
set -e
test "$first_failure_exit" -ne 0
test ! -e "$first_failure_data/.clusteryourcodex-worker-owned"
test ! -e "$first_failure_logs/.clusteryourcodex-worker-logs-owned"
test ! -e "$first_failure_data/.repair-transaction"
test ! -e "$first_failure_install/cyc-worker"
test ! -e "$first_failure_data/install-manifest.json"

# Safe, enrollment-free preinstall is idempotent and remains dormant.
preinstall="$($good/install-worker.sh install --bundle-root "$good" "${common[@]}")"
grep -q '"succeeded":true' <<<"$preinstall"
grep -q '"paired":false' <<<"$preinstall"
grep -q '"serviceEnabled":false' <<<"$preinstall"
grep -q '"service":"not_enabled"' <<<"$preinstall"
test -x "$install_root/cyc-worker"
test -s "$data_root/install-manifest.json"
test ! -e "$data_root/config.json"
test ! -e "$HOME/Library/LaunchAgents/dev.clusteryourcodex.worker.plist"
$good/install-worker.sh install --bundle-root "$good" "${common[@]}" >/dev/null

# PairOnly is explicitly allowed. It may execute pair/status, but it must not
# create a LaunchAgent or start the long-running worker process.
printf '%s\n' 'MACOS_ENROLLMENT_SECRET_DO_NOT_LOG' >"$root/macos-enrollment.json"
pair_only="$($good/install-worker.sh repair --bundle-root "$good" "${common[@]}" \
  --enrollment "$root/macos-enrollment.json" --pair-only 2>"$root/macos-pair.stderr")"
grep -q '"paired":true' <<<"$pair_only"
grep -q '"service":"not_enabled"' <<<"$pair_only"
grep -q '"serviceEnabled":false' <<<"$pair_only"
test ! -e "$root/macos-enrollment.json"
test -s "$data_root/config.json"
test "$(find "$data_root" -maxdepth 1 -name '*.credential' -type f | wc -l | tr -d '[:space:]')" -eq 1
test ! -s "$root/macos-pair.stderr"
! grep -R -q 'MACOS_ENROLLMENT_SECRET_DO_NOT_LOG' "$root"/*.stdout "$root"/*.stderr 2>/dev/null
test ! -e "$HOME/Library/LaunchAgents/dev.clusteryourcodex.worker.plist"
! pgrep -f -- "$install_root/cyc-worker run" >/dev/null 2>&1

# Existing paired config is verify-only on the PairOnly path as well. A weak
# pre-positioned config must fail without chmod, transaction, worker, manifest,
# or LaunchAgent mutation.
mac_paired_config_mode_before="$(stat -c '%a' "$data_root/config.json")"
test "$mac_paired_config_mode_before" = 600
mac_paired_config_hash_before="$(shasum -a 256 "$data_root/config.json" | awk '{print $1}')"
mac_paired_worker_hash_before="$(shasum -a 256 "$install_root/cyc-worker" | awk '{print $1}')"
mac_paired_manifest_hash_before="$(shasum -a 256 "$data_root/install-manifest.json" | awk '{print $1}')"
mac_paired_launchctl_lines_before="$(wc -l <"$CYC_FAKE_LAUNCHCTL_LOG" | tr -d '[:space:]')"
chmod 0644 "$data_root/config.json"
export CYC_WORKER_KIT_TEST_CONFIG_MODE=644
set +e
$good/install-worker.sh repair --bundle-root "$good" "${common[@]}" --pair-only \
  >"$root/macos-weak-config.stdout" 2>"$root/macos-weak-config.stderr"
mac_weak_config_exit=$?
set -e
test "$mac_weak_config_exit" -ne 0
grep -q 'Existing worker config is weak or owned by another identity' "$root/macos-weak-config.stderr"
test "$(stat -c '%a' "$data_root/config.json")" = 644
test "$(shasum -a 256 "$data_root/config.json" | awk '{print $1}')" = "$mac_paired_config_hash_before"
test "$(shasum -a 256 "$install_root/cyc-worker" | awk '{print $1}')" = "$mac_paired_worker_hash_before"
test "$(shasum -a 256 "$data_root/install-manifest.json" | awk '{print $1}')" = "$mac_paired_manifest_hash_before"
test "$(wc -l <"$CYC_FAKE_LAUNCHCTL_LOG" | tr -d '[:space:]')" = "$mac_paired_launchctl_lines_before"
test ! -e "$data_root/.repair-transaction"
test ! -e "$HOME/Library/LaunchAgents/dev.clusteryourcodex.worker.plist"
chmod 0600 "$data_root/config.json"
export CYC_WORKER_KIT_TEST_CONFIG_MODE=600

# A service-enabling repair is a machine-recognizable, exit-78 fail-closed
# boundary and cannot mutate the paired installation.
baseline_worker="$(shasum -a 256 "$install_root/cyc-worker" | awk '{print $1}')"
baseline_config="$(shasum -a 256 "$data_root/config.json" | awk '{print $1}')"
baseline_manifest="$(shasum -a 256 "$data_root/install-manifest.json" | awk '{print $1}')"
set +e
$upgrade/install-worker.sh repair --bundle-root "$upgrade" "${common[@]}" \
  >"$root/macos-gated.stdout" 2>"$root/macos-gated.stderr"
gated_exit=$?
set -e
test "$gated_exit" -eq 78
grep -q 'CYC-MACOS-WORKER-CONTAINMENT-UNAVAILABLE' "$root/macos-gated.stderr"
test ! -s "$root/macos-gated.stdout"
test "$(shasum -a 256 "$install_root/cyc-worker" | awk '{print $1}')" = "$baseline_worker"
test "$(shasum -a 256 "$data_root/config.json" | awk '{print $1}')" = "$baseline_config"
test "$(shasum -a 256 "$data_root/install-manifest.json" | awk '{print $1}')" = "$baseline_manifest"
test ! -e "$HOME/Library/LaunchAgents/dev.clusteryourcodex.worker.plist"
test ! -e "$data_root/.repair-transaction"

# The safe PairOnly transaction rolls all bytes back when pairing fails after
# credential rotation and leaves no service/process surface behind.
printf '%s\n' 'MACOS_REPAIR_SECRET_DO_NOT_LOG' >"$root/macos-repair-enrollment.json"
set +e
$upgrade/install-worker.sh repair --bundle-root "$upgrade" "${common[@]}" \
  --enrollment "$root/macos-repair-enrollment.json" --pair-only \
  --failure-injection after-pair \
  >"$root/macos-injected.stdout" 2>"$root/macos-injected.stderr"
injected_exit=$?
set -e
test "$injected_exit" -ne 0
grep -q 'Injected worker repair failure at after-pair' "$root/macos-injected.stderr"
! grep -q 'MACOS_.*SECRET_DO_NOT_LOG' "$root/macos-injected.stdout" "$root/macos-injected.stderr"
test "$(shasum -a 256 "$install_root/cyc-worker" | awk '{print $1}')" = "$baseline_worker"
test "$(shasum -a 256 "$data_root/config.json" | awk '{print $1}')" = "$baseline_config"
test "$(shasum -a 256 "$data_root/install-manifest.json" | awk '{print $1}')" = "$baseline_manifest"
test "$(find "$data_root" -maxdepth 1 -name '*.credential' -type f | wc -l | tr -d '[:space:]')" -eq 1
test ! -e "$data_root/.repair-transaction"
test ! -e "$HOME/Library/LaunchAgents/dev.clusteryourcodex.worker.plist"
! pgrep -f -- "$install_root/cyc-worker run" >/dev/null 2>&1

# A routine PairOnly repair is idempotent, remains gated, and may atomically
# refresh the dormant binary without rotating the existing identity.
credential_before="$(find "$data_root" -maxdepth 1 -name '*.credential' -type f | head -n 1)"
routine="$($upgrade/install-worker.sh repair --bundle-root "$upgrade" "${common[@]}" --pair-only)"
grep -q '"paired":true' <<<"$routine"
grep -q '"serviceEnabled":false' <<<"$routine"
test "$credential_before" = "$(find "$data_root" -maxdepth 1 -name '*.credential' -type f | head -n 1)"
test "$(shasum -a 256 "$install_root/cyc-worker" | awk '{print $1}')" != "$baseline_worker"
test ! -e "$HOME/Library/LaunchAgents/dev.clusteryourcodex.worker.plist"

# A macOS ownership marker without its manifest is not sufficient authority
# to boot out or delete a computed same-named LaunchAgent. Keep a sentinel at
# that path and assert that no launchctl operation occurs.
mac_missing_manifest_backup="$root/macos-missing-manifest.backup"
cp "$data_root/install-manifest.json" "$mac_missing_manifest_backup"
mac_missing_launch_agent="$HOME/Library/LaunchAgents/dev.clusteryourcodex.worker.plist"
mkdir -p "$(dirname "$mac_missing_launch_agent")"
chmod 0700 "$(dirname "$mac_missing_launch_agent")"
printf '%s\n' 'MACOS_MISSING_MANIFEST_SENTINEL' >"$mac_missing_launch_agent"
chmod 0600 "$mac_missing_launch_agent"
mac_missing_manifest_worker_hash="$(shasum -a 256 "$install_root/cyc-worker" | awk '{print $1}')"
mac_missing_manifest_config_hash="$(shasum -a 256 "$data_root/config.json" | awk '{print $1}')"
mac_missing_manifest_launchctl_lines="$(wc -l <"$CYC_FAKE_LAUNCHCTL_LOG" | tr -d '[:space:]')"
rm -f "$data_root/install-manifest.json"
set +e
$upgrade/install-worker.sh uninstall --bundle-root "$upgrade" "${common[@]}" \
  >"$root/macos-missing-manifest.stdout" 2>"$root/macos-missing-manifest.stderr"
mac_missing_manifest_exit=$?
set -e
test "$mac_missing_manifest_exit" -ne 0
test ! -s "$root/macos-missing-manifest.stdout"
grep -q 'Owned worker install manifest is missing or unsafe.' "$root/macos-missing-manifest.stderr"
test -f "$data_root/.clusteryourcodex-worker-owned"
test -f "$install_root/cyc-worker"
test "$(shasum -a 256 "$install_root/cyc-worker" | awk '{print $1}')" = "$mac_missing_manifest_worker_hash"
test "$(shasum -a 256 "$data_root/config.json" | awk '{print $1}')" = "$mac_missing_manifest_config_hash"
test "$(wc -l <"$CYC_FAKE_LAUNCHCTL_LOG" | tr -d '[:space:]')" = "$mac_missing_manifest_launchctl_lines"
test -f "$mac_missing_launch_agent"
test "$(cat "$mac_missing_launch_agent")" = 'MACOS_MISSING_MANIFEST_SENTINEL'
cp "$mac_missing_manifest_backup" "$data_root/install-manifest.json"
rm -f "$mac_missing_manifest_backup" "$mac_missing_launch_agent"

# Existing ownership is bound to every macOS lifecycle root. Changing the
# install, logs, or HOME-derived LaunchAgent root must fail before any
# uninstall operation touches the paired installation or the sentinel.
mac_install_root="$install_root"
mac_workspace_root="$workspace_root"
mac_launch_agent_path="$HOME/Library/LaunchAgents/dev.clusteryourcodex.worker.plist"
mac_launchctl_lines="$(wc -l <"$CYC_FAKE_LAUNCHCTL_LOG" | tr -d '[:space:]')"
mac_worker_hash="$(shasum -a 256 "$install_root/cyc-worker" | awk '{print $1}')"
mac_config_hash="$(shasum -a 256 "$data_root/config.json" | awk '{print $1}')"
mac_manifest_hash="$(shasum -a 256 "$data_root/install-manifest.json" | awk '{print $1}')"

assert_macos_manifest_binding_failure() {
  local label="$1" requested_home="$2" requested_install_root="$3" requested_logs_root="$4" sentinel="$5"
  set +e
  HOME="$requested_home" "$upgrade/install-worker.sh" uninstall --bundle-root "$upgrade" \
    --install-root "$requested_install_root" \
    --data-root "$data_root" \
    --workspace-root "$workspace_root" \
    --logs-root "$requested_logs_root" \
    --scope user \
    >"$root/$label.stdout" 2>"$root/$label.stderr"
  local binding_exit=$?
  set -e
  test "$binding_exit" -ne 0
  test ! -s "$root/$label.stdout"
  grep -q 'Installer paths do not match the existing owned installation.' "$root/$label.stderr"
  test "$(shasum -a 256 "$install_root/cyc-worker" | awk '{print $1}')" = "$mac_worker_hash"
  test "$(shasum -a 256 "$data_root/config.json" | awk '{print $1}')" = "$mac_config_hash"
  test "$(shasum -a 256 "$data_root/install-manifest.json" | awk '{print $1}')" = "$mac_manifest_hash"
  test "$(wc -l <"$CYC_FAKE_LAUNCHCTL_LOG" | tr -d '[:space:]')" = "$mac_launchctl_lines"
  test ! -e "$data_root/.repair-transaction"
  test -f "$sentinel"
  test "$(cat "$sentinel")" = 'MACOS_PATH_BINDING_SENTINEL'
  test ! -e "$mac_launch_agent_path"
}

wrong_macos_install_root="$root/macos-wrong-install"
mkdir -p "$wrong_macos_install_root"
chmod 0700 "$wrong_macos_install_root"
printf '%s\n' 'MACOS_PATH_BINDING_SENTINEL' >"$wrong_macos_install_root/cyc-worker"
chmod +x "$wrong_macos_install_root/cyc-worker"
assert_macos_manifest_binding_failure \
  macos-wrong-install \
  "$HOME" \
  "$wrong_macos_install_root" \
  "$logs_root" \
  "$wrong_macos_install_root/cyc-worker"

wrong_macos_logs_root="$root/macos-wrong-logs"
mkdir -p "$wrong_macos_logs_root"
chmod 0700 "$wrong_macos_logs_root"
printf '%s\n' 'MACOS_PATH_BINDING_SENTINEL' >"$wrong_macos_logs_root/log-sentinel"
assert_macos_manifest_binding_failure \
  macos-wrong-logs \
  "$HOME" \
  "$mac_install_root" \
  "$wrong_macos_logs_root" \
  "$wrong_macos_logs_root/log-sentinel"

wrong_macos_home="$root/macos-wrong-home"
wrong_macos_launch_agent="$wrong_macos_home/Library/LaunchAgents/dev.clusteryourcodex.worker.plist"
mkdir -p "$(dirname "$wrong_macos_launch_agent")"
chmod 0700 "$(dirname "$wrong_macos_launch_agent")"
printf '%s\n' 'MACOS_PATH_BINDING_SENTINEL' >"$wrong_macos_launch_agent"
chmod 0600 "$wrong_macos_launch_agent"
assert_macos_manifest_binding_failure \
  macos-wrong-launchagent \
  "$wrong_macos_home" \
  "$mac_install_root" \
  "$logs_root" \
  "$wrong_macos_launch_agent"

# Uninstall is repeatable and preserves paired data, workspace, and logs by
# default while removing only installer-owned executable/service material.
uninstall_one="$($upgrade/install-worker.sh uninstall --bundle-root "$upgrade" "${common[@]}")"
grep -q '"dataPreserved":true' <<<"$uninstall_one"
test ! -e "$install_root/cyc-worker"
test -s "$data_root/config.json"
test -d "$workspace_root"
test -d "$logs_root"
test ! -e "$HOME/Library/LaunchAgents/dev.clusteryourcodex.worker.plist"
uninstall_two="$($upgrade/install-worker.sh uninstall --bundle-root "$upgrade" "${common[@]}")"
grep -q '"succeeded":true' <<<"$uninstall_two"
test -s "$data_root/config.json"
test ! -e "$install_root/cyc-worker"

# Default macOS roots deliberately exercise spaces in Application Support and
# bind explicit purge to the installer-owned Data, workspace, and Logs roots.
export HOME="$root/macos-default-home"
mkdir -p "$HOME"
$good/install-worker.sh install --bundle-root "$good" >/dev/null
default_program="$HOME/Library/Application Support/ClusterYourCodex/Worker/Program"
default_data="$HOME/Library/Application Support/ClusterYourCodex/Worker/Data"
default_logs="$HOME/Library/Logs/ClusterYourCodex/Worker"
test -x "$default_program/cyc-worker"
test -d "$default_data/workspace"
test -s "$default_data/install-manifest.json"
test -s "$default_logs/.clusteryourcodex-worker-logs-owned"
$good/install-worker.sh uninstall --bundle-root "$good" --purge-data >/dev/null
test ! -e "$default_program/cyc-worker"
test ! -e "$default_data"
test ! -e "$default_logs"
'@.TrimStart(), $utf8NoBom)
        & $bashPath $macosSmoke $temporary
        if ($LASTEXITCODE -ne 0) { throw 'macOS worker gated lifecycle fixture failed.' }
    }

    foreach ($content in @(
        (Get-Content -LiteralPath $windowsInstaller -Raw),
        (Get-Content -LiteralPath $linuxInstaller -Raw),
        (Get-Content -LiteralPath $macosInstaller -Raw)
    )) {
        if ($content -match '(?i)sshpass|plink\s+-pw|password-bearing|pairingCode') {
            throw 'Worker lifecycle script contains a forbidden credential transport surface.'
        }
    }
    $windowsSource = Get-Content -LiteralPath $windowsInstaller -Raw
    foreach ($requiredPattern in @('SHA256SUMS', 'Get-WorkerTaskSnapshot', 'Restore-WorkerTask', 'New-WorkerTransaction', 'Restore-WorkerTransaction', 'TransactionSchema', 'AfterPair', 'AfterServiceRegistration', 'BeforeManifestWrite', 'Assert-DefaultDataPurgeTarget', 'Resolve-ServiceScope', 'Resolve-AccountSid', 'Assert-WorkerTaskOwnership', 'Wait-WorkerTaskRunning', 'ServiceAccount', 'TaskPath', 'WorkingDirectory', 'worker scheduled task principal', '--workspace-root', '--repair', 'configExistedBeforePair', 'expectedKitNames', 'actualKitNames', 'exactly five normal files', 'Assert-CreationPathNoReparse', 'GetPathRoot', 'Assert-PrivateAcl', 'Assert-ExistingPrivateDirectory', 'Assert-PrivateStateTree', 'NewlyCreated')) {
        if ($windowsSource -notmatch [regex]::Escape($requiredPattern)) {
            throw "Windows worker installer is missing rollback/integrity guard: $requiredPattern"
        }
    }
    $linuxSource = Get-Content -LiteralPath $linuxInstaller -Raw
    foreach ($requiredPattern in @('exec /bin/bash "$0" "$@"', '== --', 'sha256sum --check --strict', 'reject_link_chain', 'private_dir', 'verify_private_dir_existing', 'verify_private_file_existing', 'verify_private_state_tree', 'path_mode', 'path_owner', 'verify_private_config', 'verify_private_service_path_existing', 'Existing private directory is weak or owned by another identity', 'Existing user service directory is weak or owned by another identity', 'Existing user service unit is weak or owned by another identity', 'Existing worker config is weak or owned by another identity', 'Private transaction state root is not a normal directory', 'committed=0', 'begin_transaction', 'restore_transaction', 'TRANSACTION_SCHEMA', 'TRANSACTION_TOMBSTONE_SCHEMA', 'TRANSACTION_TOMBSTONE_RETIRED', 'TRANSACTION_RETIRE_NAME', 'assert_transaction_retirement_tree_safe', 'rollback_tombstone_valid_for_transaction', 'validate_retired_transaction', 'after-pair', 'after-service-registration', 'before-manifest-write', 'after-marker-removal', 'remove_service', 'service_path_for_scope', 'servicePath', 'Installer service path does not match the existing owned installation.', 'loginctl enable-linger', 'require_user_systemd_ready', 'systemctl --user show-environment', 'CYC-LINUX-USER-SYSTEMD-UNAVAILABLE', 'EXIT_USER_SYSTEMD_UNAVAILABLE=78', '--pair-only', '--allow-on-battery', '--workspace-root', '--repair', 'config_existed_before_pair', 'expected_names', 'worker-kit file set', 'manifest target', 'expected_files', 'manifest payload digest', 'validate_owned_manifest', 'Installer paths do not match the existing owned installation.', 'installRoot', 'dataRoot', 'workspaceRoot', 'KillMode=control-group', 'marker-existed', 'marker-existed=0', 'Owned worker install manifest is missing or unsafe.')) {
        if ($linuxSource -notmatch [regex]::Escape($requiredPattern)) {
            throw "Linux worker installer is missing rollback/integrity guard: $requiredPattern"
        }
    }
    $macosSource = Get-Content -LiteralPath $macosInstaller -Raw
    foreach ($requiredPattern in @(
         'cyc.dev/macos-worker-install/v1',
         'cyc.dev/macos-worker-repair-transaction/v1',
         'cyc.dev/macos-worker-repair-tombstone/v1',
         'TRANSACTION_TOMBSTONE_SCHEMA',
         'TRANSACTION_TOMBSTONE_RETIRED',
         'TRANSACTION_RETIRE_NAME',
         'assert_transaction_retirement_tree_safe',
         'rollback_tombstone_valid_for_transaction',
         'validate_retired_transaction',
        'exec /bin/bash "$0" "$@"',
        '== --',
        'readonly MACOS_WORKER_CONTAINMENT_READY=0',
        'EXIT_RUNTIME_GATED=78',
        'CYC-MACOS-WORKER-CONTAINMENT-UNAVAILABLE',
        'CYC-MACOS-PLATFORM-REQUIRED',
        'CYC-MACOS-LAUNCHAGENT-USER-SCOPE-REQUIRED',
        'Library/Application Support/ClusterYourCodex/Worker',
         'Library/Logs/ClusterYourCodex/Worker',
         'Library/LaunchAgents',
         'path_mode',
         'path_owner',
         'verify_private_dir_existing',
         'verify_private_file_existing',
         'verify_private_launch_agent_path_existing',
         'verify_private_state_tree',
         'verify_private_config',
         'Existing private directory is weak or owned by another identity',
         'Existing LaunchAgents directory is weak or owned by another identity',
         'Existing LaunchAgent is weak or owned by another identity',
         'Existing worker config is weak or owned by another identity',
         'Private transaction state root is not a normal directory',
        'dev.clusteryourcodex.worker',
        'launchctl bootstrap',
        'launchctl bootout',
        'launchctl kickstart',
        'launchctl print',
        'ProgramArguments',
        'StandardOutPath',
        'StandardErrorPath',
        'KeepAlive',
        'AbandonProcessGroup',
        'ProcessType',
        'verify_worker_kit_signature',
        'SHA256SUMS must contain exactly four signed-kit files',
        'begin_transaction',
        'restore_transaction',
         'after-pair',
         'after-launchagent-registration',
         'before-manifest-write',
         'after-marker-removal',
        '--pair-only',
        '--allow-on-battery',
        '--workspace-root',
        '--repair',
        'config_existed_before_pair',
        'runtimeGated',
        'containmentReady',
        'validate_owned_manifest',
        'Installer paths do not match the existing owned installation.',
        'installRoot',
        'dataRoot',
        'workspaceRoot',
        'logsRoot',
         'launchAgent',
         'marker-existed',
         'marker-existed=0',
         'committed=0',
        'Owned worker install manifest is missing or unsafe.'
    )) {
        if ($macosSource -notmatch [regex]::Escape($requiredPattern)) {
            throw "macOS worker installer is missing lifecycle/gating guard: $requiredPattern"
        }
    }
    if ($macosSource -match '(?m)^\s*(?:export\s+)?MACOS_WORKER_CONTAINMENT_READY=\$\{' -or
        $macosSource -match 'CYC_MACOS.*CONTAINMENT.*(?:override|enable)') {
        throw 'macOS worker containment gate is externally overrideable.'
    }
    Write-Output 'worker-kit packaging tests passed'
} finally {
    $env:CYC_WORKER_KIT_SIGNING_KEY_PATH = $previousSigningKeyPath
    $env:CYC_WORKER_KIT_SIGNING_KEY_ID = $previousSigningKeyId
    $env:CYC_WORKER_KIT_TRUSTED_PUBLIC_KEY_PATH = $previousTrustedPublicKeyPath
    $env:CYC_WORKER_KIT_TEST_PRIVATE_KEY = $previousTestPrivateKey
    if (Test-Path -LiteralPath $temporary) {
        $resolved = [System.IO.Path]::GetFullPath($temporary)
        $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        if (-not $resolved.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing to clean a worker-kit test path outside the temp root.'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
