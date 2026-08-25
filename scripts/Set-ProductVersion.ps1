#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Version,
    [string]$RepositoryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

function Assert-CycStrictSemVer {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-(?<pre>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$') {
        throw "Product version must be canonical SemVer without build metadata: $Value"
    }
    if ($Matches.pre) {
        foreach ($identifier in $Matches.pre.Split('.')) {
            if ($identifier -cmatch '^[0-9]+$' -and $identifier.Length -gt 1 -and $identifier.StartsWith('0')) {
                throw "Numeric prerelease identifiers must not have leading zeroes: $Value"
            }
        }
    }
}

function Resolve-CycRepositoryPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $root = [System.IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\', '/')
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $root $Path))
    if (-not $candidate.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Version target escaped the repository root: $Path"
    }
    return $candidate
}

function Set-CycUtf8NoBomText {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $path = Resolve-CycRepositoryPath -Path $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Version target is missing: $RelativePath"
    }
    $item = Get-Item -LiteralPath $path -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to update a reparse-point version target: $RelativePath"
    }
    if ($PSCmdlet.ShouldProcess($path, "set ClusterYourCodex product version to $Version")) {
        [System.IO.File]::WriteAllText($path, $Text, (New-Object System.Text.UTF8Encoding($false)))
    }
}

function Set-CycSingleMatch {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][scriptblock]$Replacement
    )

    $path = Resolve-CycRepositoryPath -Path $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Version target is missing: $RelativePath"
    }
    $text = [System.IO.File]::ReadAllText($path)
    $regex = New-Object System.Text.RegularExpressions.Regex(
        $Pattern,
        ([System.Text.RegularExpressions.RegexOptions]::Multiline -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
    )
    $matches = $regex.Matches($text)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one product-version field in $RelativePath; found $($matches.Count)."
    }
    $updated = $regex.Replace($text, $Replacement, 1)
    Set-CycUtf8NoBomText -RelativePath $RelativePath -Text $updated
}

function Set-CycJsonVersion {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    Set-CycSingleMatch -RelativePath $RelativePath `
        -Pattern '^(?<indent>\s*)"version"\s*:\s*"[^"]+"(?<comma>,?)\s*$' `
        -Replacement { param($match) "$($match.Groups['indent'].Value)`"version`": `"$Version`"$($match.Groups['comma'].Value)" }
}

function Set-CycCargoPackageVersion {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Section
    )

    $path = Resolve-CycRepositoryPath -Path $RelativePath
    $text = [System.IO.File]::ReadAllText($path)
    $escaped = [System.Text.RegularExpressions.Regex]::Escape($Section)
    $header = [System.Text.RegularExpressions.Regex]::Match($text, ('(?m)^\[{0}\]\r?$' -f $escaped))
    if (-not $header.Success) { throw "Cargo section [$Section] is missing from $RelativePath." }
    $sectionStart = $header.Index + $header.Length
    $remaining = $text.Substring($sectionStart)
    $nextHeader = [System.Text.RegularExpressions.Regex]::Match($remaining, '(?m)^\[[^\r\n]+\]\r?$')
    $sectionLength = if ($nextHeader.Success) { $nextHeader.Index } else { $remaining.Length }
    $sectionText = $remaining.Substring(0, $sectionLength)
    $versionMatch = [System.Text.RegularExpressions.Regex]::Match(
        $sectionText,
        '(?m)^(?<prefix>version\s*=\s*)"[^"]+"(?<suffix>\s*)$'
    )
    if (-not $versionMatch.Success -or
        [System.Text.RegularExpressions.Regex]::Matches($sectionText, '(?m)^version\s*=').Count -ne 1) {
        throw "Expected one package version in [$Section] of $RelativePath."
    }
    $replacement = $versionMatch.Groups['prefix'].Value + '"' + $Version + '"' + $versionMatch.Groups['suffix'].Value
    $globalIndex = $sectionStart + $versionMatch.Index
    $updated = $text.Substring(0, $globalIndex) + $replacement + $text.Substring($globalIndex + $versionMatch.Length)
    Set-CycUtf8NoBomText -RelativePath $RelativePath -Text $updated
}

function Set-CycCargoLockPackages {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string[]]$PackageNames
    )

    $path = Resolve-CycRepositoryPath -Path $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Cargo lock is missing: $RelativePath"
    }
    $text = [System.IO.File]::ReadAllText($path)
    foreach ($packageName in $PackageNames) {
        $escapedName = [System.Text.RegularExpressions.Regex]::Escape($packageName)
        $pattern = '(?ms)(^\[\[package\]\]\s*\r?\nname\s*=\s*"{0}"\s*\r?\nversion\s*=\s*)"[^"]+"' -f $escapedName
        $regex = New-Object System.Text.RegularExpressions.Regex($pattern, [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
        if ($regex.Matches($text).Count -ne 1) {
            throw "Expected one $packageName package block in $RelativePath."
        }
        $text = $regex.Replace($text, { param($match) $match.Groups[1].Value + '"' + $Version + '"' }, 1)
    }
    Set-CycUtf8NoBomText -RelativePath $RelativePath -Text $text
}

$Version = $Version.Trim()
Assert-CycStrictSemVer -Value $Version
$RepositoryRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)

Set-CycUtf8NoBomText -RelativePath 'VERSION' -Text ($Version + "`n")
Set-CycCargoPackageVersion -RelativePath 'Cargo.toml' -Section 'workspace.package'
Set-CycCargoPackageVersion -RelativePath 'apps/desktop/src-tauri/Cargo.toml' -Section 'package'

foreach ($jsonPath in @(
    'package.json',
    'apps/desktop/package.json',
    'apps/desktop/src-tauri/tauri.conf.json',
    'plugins/cluster-your-codex/.codex-plugin/plugin.json',
    'plugins/cluster-your-codex/mcp/package.json'
)) {
    Set-CycJsonVersion -RelativePath $jsonPath
}

Set-CycSingleMatch -RelativePath 'plugins/cluster-your-codex/mcp/src/runtime-receipt.ts' `
    -Pattern '^export const MCP_BRIDGE_VERSION = "[^"]+" as const;\s*$' `
    -Replacement { 'export const MCP_BRIDGE_VERSION = "' + $Version + '" as const;' }
Set-CycSingleMatch -RelativePath 'plugins/cluster-your-codex/mcp/src/server.ts' `
    -Pattern '^\s*\{ name: "cluster-your-codex", version: "[^"]+" \},\s*$' `
    -Replacement { param($match) ($match.Value -replace 'version: "[^"]+"', ('version: "' + $Version + '"')) }
Set-CycSingleMatch -RelativePath 'packaging/windows/bootstrap.ps1' `
    -Pattern '^\s*\$script:ProductVersion\s*=\s*''[^'']+''\s*$' `
    -Replacement { param($match) ($match.Value -replace "'[^']+'", "'$Version'") }

$workspacePackages = @(
    'cyc-cli', 'cyc-controller', 'cyc-protocol', 'cyc-provision',
    'cyc-scheduler', 'cyc-secrets', 'cyc-ssh', 'cyc-worker'
)
Set-CycCargoLockPackages -RelativePath 'Cargo.lock' -PackageNames $workspacePackages
Set-CycCargoLockPackages -RelativePath 'apps/desktop/src-tauri/Cargo.lock' `
    -PackageNames @('clusteryourcodex-desktop-host', 'cyc-protocol', 'cyc-provision', 'cyc-secrets', 'cyc-ssh')

& (Resolve-CycRepositoryPath -Path 'scripts/Test-VersionConsistency.ps1') `
    -RepositoryRoot $RepositoryRoot `
    -SkipNegativeTests | Out-Null

[PSCustomObject]@{
    productVersion = $Version
    releaseChannel = if ($Version.Contains('-')) { 'prerelease' } else { 'stable' }
    sourceTag = "v$Version"
}
