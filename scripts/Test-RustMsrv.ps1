#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

function Get-CycManifestRustVersion {
    param([Parameter(Mandatory = $true)][string]$ManifestPath)

    $text = [IO.File]::ReadAllText($ManifestPath)
    $matches = [regex]::Matches(
        $text,
        '(?m)^rust-version\s*=\s*"(?<version>[0-9]+\.[0-9]+(?:\.[0-9]+)?)"\s*$'
    )
    if ($matches.Count -ne 1) {
        throw "Expected exactly one rust-version in $ManifestPath; found $($matches.Count)."
    }
    return [version]$matches[0].Groups['version'].Value
}

function Get-CycResolvedMaximumRustVersion {
    param([Parameter(Mandatory = $true)][string]$ManifestPath)

    $metadataText = & cargo metadata --locked --format-version 1 --manifest-path $ManifestPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "cargo metadata failed for ${ManifestPath}:`n$($metadataText -join [Environment]::NewLine)"
    }
    $metadata = ($metadataText -join [Environment]::NewLine) | ConvertFrom-Json
    $requirements = @(
        $metadata.packages |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.rust_version) } |
            ForEach-Object {
                [pscustomobject]@{
                    Name = [string]$_.name
                    Version = [string]$_.version
                    RustVersion = [version][string]$_.rust_version
                }
            }
    )
    if ($requirements.Count -eq 0) {
        throw "No resolved package declared rust_version for $ManifestPath."
    }
    $maximum = $requirements | Sort-Object RustVersion -Descending | Select-Object -First 1
    $atMaximum = @(
        $requirements |
            Where-Object { $_.RustVersion -eq $maximum.RustVersion } |
            Sort-Object Name, Version |
            ForEach-Object { "$($_.Name)@$($_.Version)" }
    )
    return [pscustomobject]@{
        Maximum = $maximum.RustVersion
        Packages = $atMaximum
    }
}

$checks = @(
    [pscustomobject]@{
        Name = 'workspace'
        Manifest = Join-Path $RepositoryRoot 'Cargo.toml'
    },
    [pscustomobject]@{
        Name = 'desktop'
        Manifest = Join-Path $RepositoryRoot 'apps\desktop\src-tauri\Cargo.toml'
    }
)

$results = foreach ($check in $checks) {
    if (-not (Test-Path -LiteralPath $check.Manifest -PathType Leaf)) {
        throw "Rust manifest is missing: $($check.Manifest)"
    }
    $declared = Get-CycManifestRustVersion -ManifestPath $check.Manifest
    $resolved = Get-CycResolvedMaximumRustVersion -ManifestPath $check.Manifest
    if ($declared -lt $resolved.Maximum) {
        throw "$($check.Name) declares Rust $declared but its locked dependency graph requires at least Rust $($resolved.Maximum) ($($resolved.Packages -join ', '))."
    }
    [pscustomobject]@{
        graph = $check.Name
        declaredMsrv = $declared.ToString(2)
        maximumLockedRequirement = $resolved.Maximum.ToString(2)
        packagesAtMaximum = $resolved.Packages
    }
}

if ($Json) {
    $results | ConvertTo-Json -Depth 4 -Compress
} else {
    $results | Format-Table -AutoSize
    Write-Host 'Rust MSRV consistency checks passed.'
}
