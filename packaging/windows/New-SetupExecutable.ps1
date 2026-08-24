#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PackageRoot,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [string]$MakeNsisPath,
    [switch]$RequireRuntimeSignature,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Dot-sourcing bootstrap.ps1 can replace the dynamic value of $PSScriptRoot
# under Windows PowerShell 5.1. Preserve this script's location before loading
# shared helpers so the NSIS source remains resolvable later in the build.
# bootstrap.ps1 has its own param block, so preserve every builder input before
# importing it as well; dot-sourcing otherwise replaces matching variables in
# this script scope.
$setupScriptRoot = [string]$PSScriptRoot
$requestedPackageRoot = [string]$PackageRoot
$requestedOutputPath = [string]$OutputPath
$requestedMakeNsisPath = [string]$MakeNsisPath
$requestedRequireRuntimeSignature = [bool]$RequireRuntimeSignature
$requestedForce = [bool]$Force
if ([string]::IsNullOrWhiteSpace($setupScriptRoot)) {
    throw 'New-SetupExecutable.ps1 must be launched from a script file path.'
}
$bootstrapScript = Join-Path -Path $setupScriptRoot -ChildPath 'bootstrap.ps1'
# The bootstrap script defines a default BundleRoot with its own dynamic
# $PSScriptRoot. Supply a harmless non-empty value because this caller imports
# helpers only and Windows PowerShell 5.1 can leave that automatic value blank.
. $bootstrapScript -BundleRoot $setupScriptRoot

function Resolve-SetupPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $resolved = [System.IO.Path]::GetFullPath($Path)
    if ($resolved.Contains('"') -or $resolved.Contains("`r") -or $resolved.Contains("`n")) {
        throw 'NSIS input and output paths must not contain quotes or line breaks.'
    }
    return $resolved
}

function Test-SetupPathEqualOrDescendant {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Candidate
    )
    $rootPath = (Resolve-SetupPath -Path $Root).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $candidatePath = (Resolve-SetupPath -Path $Candidate).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    if ([string]::Equals($rootPath, $candidatePath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    return $candidatePath.StartsWith(
        $rootPath + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Resolve-MakeNsis {
    param([string]$RequestedPath)
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $candidate = Resolve-SetupPath -Path $RequestedPath.Trim()
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "makensis.exe was not found: $candidate"
        }
        return $candidate
    }
    $commands = @(Get-Command makensis.exe -CommandType Application -All -ErrorAction SilentlyContinue)
    foreach ($command in $commands) {
        # ApplicationInfo differs between Windows PowerShell and pwsh, and
        # Chocolatey can expose a shim with one or more blank properties.
        foreach ($propertyName in @('Path', 'Source', 'Definition')) {
            $property = $command.PSObject.Properties[$propertyName]
            if ($null -eq $property) { continue }
            $commandPath = [string]$property.Value
            if ([string]::IsNullOrWhiteSpace($commandPath)) { continue }
            $commandPath = $commandPath.Trim()
            if (Test-Path -LiteralPath $commandPath -PathType Leaf) {
                return (Resolve-SetupPath -Path $commandPath)
            }
        }
    }
    $candidateRoots = @(
        [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles),
        [string]${env:ProgramFiles(x86)},
        [string]$env:ProgramFiles
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $seenRoots = @{}
    foreach ($root in $candidateRoots) {
        $normalizedRoot = $root.Trim()
        if (-not $seenRoots.ContainsKey($normalizedRoot)) {
            $seenRoots[$normalizedRoot] = $true
            $candidate = Join-Path -Path $normalizedRoot -ChildPath 'NSIS\makensis.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return (Resolve-SetupPath -Path $candidate)
            }
        }
    }
    throw 'makensis.exe is required to build ClusterYourCodex-Setup.exe.'
}

function Get-SetupSha256Hex {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Get-CycPackagePathMetrics {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][ValidateRange(1, 259)][int]$MaximumRelativePath
    )
    $normalizedRoot = [System.IO.Path]::GetFullPath($Root)
    $rootPrefix = $normalizedRoot.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar
    $longestRelativePath = $null
    $longestRelativePathLength = -1
    $entryCount = 0
    foreach ($item in Get-ChildItem -LiteralPath $normalizedRoot -Recurse -Force) {
        $fullPath = [System.IO.Path]::GetFullPath([string]$item.FullName)
        if (-not $fullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Package enumeration escaped the package root: $fullPath"
        }
        $relativePath = $fullPath.Substring($rootPrefix.Length).Replace('\', '/')
        $relativePathLength = $relativePath.Length
        $entryCount++
        if ($relativePathLength -gt $longestRelativePathLength) {
            $longestRelativePath = $relativePath
            $longestRelativePathLength = $relativePathLength
        }
    }
    if ($entryCount -eq 0) {
        throw 'The setup package is empty.'
    }
    if ($longestRelativePathLength -gt $MaximumRelativePath) {
        throw (
            ('The setup package exceeds the {0}-character package-relative path limit: ' +
            'length={1}, path={2}') -f
            $MaximumRelativePath,
            $longestRelativePathLength,
            $longestRelativePath
        )
    }
    return [PSCustomObject]@{
        entryCount = $entryCount
        maximumRelativePath = $MaximumRelativePath
        longestRelativePath = $longestRelativePath
        longestRelativePathLength = $longestRelativePathLength
    }
}

$package = Resolve-SetupPath -Path $requestedPackageRoot
$output = Resolve-SetupPath -Path $requestedOutputPath
$makeNsis = Resolve-MakeNsis -RequestedPath $requestedMakeNsisPath
$script = Resolve-SetupPath -Path (Join-Path -Path $setupScriptRoot -ChildPath 'ClusterYourCodex.nsi')
$sidecarOutput = $output + '.sha256'
foreach ($artifactPath in @($output, $sidecarOutput)) {
    if ((Test-SetupPathEqualOrDescendant -Root $package -Candidate $artifactPath) -or
        (Test-SetupPathEqualOrDescendant -Root $artifactPath -Candidate $package)) {
        throw 'Setup output and sidecar must be outside, and must not contain, the package root.'
    }
}
foreach ($protectedBuilderInput in @($makeNsis, $script)) {
    if ([string]::Equals($output, $protectedBuilderInput, [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($sidecarOutput, $protectedBuilderInput, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Setup output and sidecar must not replace a builder executable or source script.'
    }
}
$nsisPackageRoot = $package
$validationPackageRoot = $package
$maximumPackageRelativePath = 190
$packagePathMetrics = $null
$substExe = $null
$substDrive = $null
$substMappingOwned = $false
$substOwnershipManifestHash = $null
$primaryFailure = $null
$cleanupFailure = $null
try {
    try {
        # NSIS and Windows PowerShell 5.1 both use MAX_PATH-sensitive APIs in
        # this build path. Map first, then validate and enumerate exclusively
        # through the short alias so a valid package is never rejected merely
        # because the controller checkout is deep.
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            $substCommand = Get-Command -Name 'subst.exe' -CommandType Application -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($null -eq $substCommand) {
                throw 'subst.exe is required to provide NSIS short-path source staging.'
            }
            $substExe = [string]$substCommand.Path
            if ([string]::IsNullOrWhiteSpace($substExe)) {
                $substExe = [string]$substCommand.Source
            }
            if ([string]::IsNullOrWhiteSpace($substExe)) {
                throw 'subst.exe was discovered but its executable path is unavailable.'
            }
            $originalManifest = Join-Path -Path $package -ChildPath 'preview-manifest.json'
            if (-not (Test-Path -LiteralPath $originalManifest -PathType Leaf)) {
                throw "Package manifest is missing: $originalManifest"
            }
            # This shallow pre-map digest is an ownership token, not package
            # validation. Full manifest validation still runs only through the
            # verified short alias below.
            $substOwnershipManifestHash = Get-SetupSha256Hex -Path $originalManifest
            $lastSubstExitCode = $null
            foreach ($letter in @('Z', 'Y', 'X', 'W', 'V', 'U', 'T', 'S', 'R', 'Q')) {
                $candidateRoot = "${letter}:\"
                if ([Environment]::GetLogicalDrives() -contains $candidateRoot) { continue }
                $candidateDrive = "${letter}:"
                & $substExe $candidateDrive $package *> $null
                $candidateExitCode = $LASTEXITCODE
                if ($candidateExitCode -ne 0) {
                    $lastSubstExitCode = $candidateExitCode
                    continue
                }
                # A zero exit after an empty-drive check means this process
                # created the mapping. Mark it owned before any later check so
                # a validation failure still removes only this mapping.
                $substDrive = $candidateDrive
                $substMappingOwned = $true
                $validationPackageRoot = $candidateRoot
                $shortManifest = Join-Path -Path $validationPackageRoot -ChildPath 'preview-manifest.json'
                if (-not (Test-Path -LiteralPath $shortManifest -PathType Leaf)) {
                    throw 'The temporary package mapping does not expose preview-manifest.json.'
                }
                if ((Get-SetupSha256Hex -Path $shortManifest) -cne $substOwnershipManifestHash) {
                    throw 'The temporary package mapping did not resolve to the requested package root.'
                }
                $nsisPackageRoot = $substDrive
                break
            }
            if (-not $substMappingOwned) {
                $detail = if ($null -eq $lastSubstExitCode) {
                    'all candidate drive letters Z through Q are occupied'
                } else {
                    "the last subst.exe attempt exited with $lastSubstExitCode"
                }
                throw "No verified drive letter is available for NSIS short-path source staging: $detail."
            }
        }

        $manifest = Join-Path -Path $validationPackageRoot -ChildPath 'preview-manifest.json'
        $payload = Join-Path -Path $validationPackageRoot -ChildPath 'payload'
        Assert-CycPackageManifest `
            -Root $validationPackageRoot `
            -ManifestPath $manifest `
            -PayloadRoot $payload
        $packagePathMetrics = Get-CycPackagePathMetrics `
            -Root $validationPackageRoot `
            -MaximumRelativePath $maximumPackageRelativePath

        $outputParent = Split-Path -Parent $output
        [void](New-Item -ItemType Directory -Path $outputParent -Force)
        if (Test-Path -LiteralPath $output) {
            if (-not $requestedForce) { throw "Setup output already exists: $output" }
            Remove-Item -LiteralPath $output -Force
        }

        $arguments = @(
            '/V4',
            "/DCYC_PACKAGE_ROOT=$nsisPackageRoot",
            "/DCYC_OUTPUT=$output",
            "/DCYC_MAX_PACKAGE_RELATIVE_PATH=$($packagePathMetrics.longestRelativePathLength)"
        )
        if ($requestedRequireRuntimeSignature) { $arguments += '/DCYC_REQUIRE_SIGNATURE=1' }
        $arguments += $script
        $outputLines = @(& $makeNsis @arguments 2>&1)
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $tail = @($outputLines | Select-Object -Last 20 | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
            throw "makensis.exe failed (exit=$exitCode).`n$tail"
        }
    } catch {
        $primaryFailure = $_
    }
} finally {
    if ($substMappingOwned -and -not [string]::IsNullOrWhiteSpace($substDrive)) {
        try {
            $ownedManifest = Join-Path -Path "${substDrive}\" -ChildPath 'preview-manifest.json'
            if ([string]::IsNullOrWhiteSpace($substOwnershipManifestHash) -or
                -not (Test-Path -LiteralPath $ownedManifest -PathType Leaf) -or
                (Get-SetupSha256Hex -Path $ownedManifest) -cne
                    $substOwnershipManifestHash) {
                throw 'Refusing to remove the temporary package mapping because its ownership can no longer be verified.'
            }
            & $substExe $substDrive '/D' *> $null
            $substCleanupExitCode = $LASTEXITCODE
            if ($substCleanupExitCode -ne 0) {
                throw "subst.exe failed to remove the temporary package mapping (exit=$substCleanupExitCode)."
            }
            $substMappingOwned = $false
        } catch {
            $cleanupFailure = $_
        }
    }
}
if ($null -ne $primaryFailure) {
    if ($null -ne $cleanupFailure) {
        Write-Warning "The setup build also failed to remove its owned subst mapping: $($cleanupFailure.Exception.Message)"
    }
    throw $primaryFailure
}
if ($null -ne $cleanupFailure) {
    throw $cleanupFailure
}
if (-not (Test-Path -LiteralPath $output -PathType Leaf)) {
    throw 'makensis.exe returned success without producing Setup.exe.'
}
$bytes = [System.IO.File]::ReadAllBytes($output)
if ($bytes.Length -lt 4096 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) {
    throw 'Generated setup is not a valid PE executable.'
}
$hash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
$sidecar = "$hash  $([System.IO.Path]::GetFileName($output))"
$sidecarPath = $sidecarOutput
$sidecar | Set-Content -LiteralPath $sidecarPath -Encoding ASCII -NoNewline
[PSCustomObject]@{
    setupPath = $output
    sha256 = $hash
    sidecarPath = $sidecarPath
    authenticodeStatus = [string](Get-AuthenticodeSignature -LiteralPath $output).Status
    maxPackageRelativePath = [int]$packagePathMetrics.longestRelativePathLength
    longestPackageRelativePath = [string]$packagePathMetrics.longestRelativePath
}
