[CmdletBinding()]
param(
    [string]$WorkflowRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 evaluates parameter default expressions before
# $PSScriptRoot is populated for some -File invocations. Resolve the default
# after parameter binding so this gate is reliable both directly and when it
# is invoked by Test-VersionConsistency.ps1.
if ([string]::IsNullOrWhiteSpace($WorkflowRoot)) {
    $WorkflowRoot = Join-Path (Split-Path -Parent $PSScriptRoot) '.github\workflows'
}

$resolvedRoot = (Resolve-Path -LiteralPath $WorkflowRoot).Path
$workflowFiles = @(Get-ChildItem -LiteralPath $resolvedRoot -File | Where-Object {
        $_.Extension -in '.yml', '.yaml'
    } | Sort-Object FullName)

if ($workflowFiles.Count -eq 0) {
    throw 'No GitHub Actions workflow files were found.'
}

$remoteUseCount = 0
$failures = [System.Collections.Generic.List[string]]::new()
foreach ($file in $workflowFiles) {
    $lineNumber = 0
    # ReadAllLines closes the file before validation begins. The lazy ReadLines
    # enumerator can retain a Windows handle long enough to break negative-fixture
    # cleanup when this gate is invoked repeatedly in the same process.
    foreach ($line in [System.IO.File]::ReadAllLines($file.FullName)) {
        $lineNumber++
        $match = [regex]::Match(
            $line,
            '^\s*(?:-\s*)?uses:\s*(?<value>[^\s#]+)\s*(?:#.*)?$',
            [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
        )
        if (-not $match.Success) { continue }

        $value = $match.Groups['value'].Value
        if ($value.StartsWith('./', [System.StringComparison]::Ordinal) -or
            $value.StartsWith('docker://', [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $remoteUseCount++
        if ($value -notmatch '^[^@\s]+@[0-9a-fA-F]{40}$') {
            # Workflow files are enumerated directly beneath $resolvedRoot, so
            # Name is the stable relative path and remains compatible with the
            # .NET Framework runtime used by Windows PowerShell 5.1.
            $relative = $file.Name
            $failures.Add("${relative}:${lineNumber}: remote action is not pinned to a full commit SHA")
        }
    }
}

if ($remoteUseCount -eq 0) {
    throw 'No remote GitHub Actions references were found.'
}

if ($failures.Count -ne 0) {
    throw ("GitHub Actions pin validation failed:`n" + ($failures -join "`n"))
}

Write-Output "GitHub Actions pin validation passed ($remoteUseCount remote references)."
