[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

function Read-Utf8NoBom([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file is missing: $Path"
    }
    return [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false))
}

$versionPath = Join-Path $RepositoryRoot 'VERSION'
$changelogPath = Join-Path $RepositoryRoot 'CHANGELOG.md'
$version = (Read-Utf8NoBom $versionPath).Trim()
$changelog = Read-Utf8NoBom $changelogPath

if ($version -notmatch '^\d+\.\d+\.\d+-(?:alpha|beta|preview|rc)\.\d+$') {
    throw "VERSION must be a prerelease SemVer for this workflow: $version"
}

$versionHeading = "## [$version] - "
if ($changelog.IndexOf($versionHeading, [StringComparison]::Ordinal) -lt 0) {
    throw "CHANGELOG.md is missing the current version heading: $versionHeading"
}

$unreleasedPattern = "(?m)^\[Unreleased\]:\s+https://github\.com/TypeThe0ry/ClusterYourCodex/compare/v$([regex]::Escape($version))\.\.\.HEAD\s*$"
if ($changelog -notmatch $unreleasedPattern) {
    throw "CHANGELOG.md Unreleased comparison does not start at v$version"
}

$definitions = @{}
foreach ($match in [regex]::Matches($changelog, '(?m)^\[([^\]]+)\]:\s+(\S+)\s*$')) {
    $name = $match.Groups[1].Value
    if ($definitions.ContainsKey($name)) {
        throw "CHANGELOG.md contains duplicate link definition: $name"
    }
    $definitions[$name] = $match.Groups[2].Value
}

$headings = @(
    [regex]::Matches($changelog, '(?m)^## \[([^\]]+)\]') |
        ForEach-Object { $_.Groups[1].Value } |
        Where-Object { $_ -ne 'Unreleased' }
)
foreach ($heading in $headings) {
    if (-not $definitions.ContainsKey($heading)) {
        throw "CHANGELOG.md heading has no link definition: $heading"
    }
}

if ($version -match '^(\d+)\.(\d+)\.(\d+)-(preview|alpha|beta|rc)\.(\d+)$') {
    $major = $Matches[1]
    $minor = $Matches[2]
    $patch = $Matches[3]
    $channel = $Matches[4]
    $sequence = [int]$Matches[5]
    if ($sequence -gt 0) {
        $previous = "$major.$minor.$patch-$channel.$($sequence - 1)"
        $expected = "https://github.com/TypeThe0ry/ClusterYourCodex/compare/v$previous...v$version"
        if ($definitions[$version] -cne $expected) {
            throw "Current changelog link is not the exact predecessor comparison: expected $expected"
        }
    }
}

Write-Output "changelog consistency passed: $version"
