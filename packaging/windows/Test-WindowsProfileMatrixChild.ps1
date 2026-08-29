#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('standard-ascii', 'administrator-ascii', 'standard-non-ascii', 'administrator-non-ascii')]
    [string]$CaseName,

    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [Parameter(Mandatory = $true)]
    [string]$WorkRoot,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^S-1-5-21(?:-[0-9]+){4}$')]
    [string]$ExpectedSid,

    [Parameter(Mandatory = $true)]
    [string]$ReceiptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Test-NonAscii {
    param([Parameter(Mandatory = $true)][string]$Value)
    return $Value -match '[^\u0000-\u007f]'
}

function Test-ProfileMatrixDescendantPath {
    param(
        [Parameter(Mandatory = $true)][string]$Parent,
        [Parameter(Mandatory = $true)][string]$Child
    )
    $parentRoot = $Parent.TrimEnd('\', '/') + '\'
    return $Child.StartsWith($parentRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
$profile = Resolve-ProfileMatrixPath $env:USERPROFILE
$localAppData = Resolve-ProfileMatrixPath $env:LOCALAPPDATA
$temp = Resolve-ProfileMatrixPath $env:TEMP
$package = Resolve-ProfileMatrixPath $PackageRoot
$work = Resolve-ProfileMatrixPath $WorkRoot
$receipt = Resolve-ProfileMatrixPath $ReceiptPath
$expectedAdmin = $CaseName.StartsWith('administrator-', [System.StringComparison]::Ordinal)
$expectedNonAscii = $CaseName.EndsWith('-non-ascii', [System.StringComparison]::Ordinal)
$adminSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
$isAdmin = $principal.IsInRole($adminSid)
$isElevated = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)

Assert-ProfileMatrix (Test-Path -LiteralPath $package -PathType Container) "package root exists: $package"
Assert-ProfileMatrix (Test-Path -LiteralPath $work -PathType Container) "work root exists: $work"
Assert-ProfileMatrix (-not [string]::IsNullOrWhiteSpace([string]$identity.User.Value)) 'current identity has a SID'
Assert-ProfileMatrix ([string]$identity.User.Value -ceq $ExpectedSid) "current identity SID matches expected SID (expected=$ExpectedSid observed=$([string]$identity.User.Value))"
Assert-ProfileMatrix ($isAdmin -eq $expectedAdmin) "administrator membership matches case (expected=$expectedAdmin observed=$isAdmin)"
if ($expectedNonAscii) {
    Assert-ProfileMatrix (Test-NonAscii $profile) "USERPROFILE is non-ASCII for $CaseName (observed=$profile)"
} else {
    Assert-ProfileMatrix (-not (Test-NonAscii $profile)) "USERPROFILE is ASCII for $CaseName (observed=$profile)"
}
Assert-ProfileMatrix (Test-ProfileMatrixDescendantPath -Parent $profile -Child $localAppData) "LOCALAPPDATA belongs to USERPROFILE (observed=$localAppData)"
Assert-ProfileMatrix (Test-ProfileMatrixDescendantPath -Parent $localAppData -Child $temp) "TEMP belongs to LOCALAPPDATA (observed=$temp)"

$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
Assert-ProfileMatrix (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf) 'Windows PowerShell 5.1 is installed'
$freshTest = Join-Path $PSScriptRoot 'Test-FreshDeployment.ps1'
Assert-ProfileMatrix (Test-Path -LiteralPath $freshTest -PathType Leaf) 'fresh deployment harness exists'

$logRoot = Join-Path $work 'logs'
[void](New-Item -ItemType Directory -Path $logRoot -Force)
$freshWork = Join-Path $work 'fresh-deployment'
$stdoutPath = Join-Path $logRoot 'fresh-deployment.stdout.log'
$stderrPath = Join-Path $logRoot 'fresh-deployment.stderr.log'
$arguments = @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $freshTest,
    '-PackageRoot', $package,
    '-WorkRoot', $freshWork,
    '-KeepWorkRoot',
    # The parent launches this disposable account with CreateProcessWithLogonW
    # from a non-interactive CI session.  A production InteractiveToken task
    # would correctly refuse that missing Winlogon session, so the profile
    # matrix uses bootstrap's explicitly guarded S4U test principal while the
    # regular fresh-deployment and Setup tests continue to exercise
    # InteractiveToken by default.
    '-ProfileMatrixTestMode',
    '-ScheduledTaskLogonType', 'S4U'
)

$startedAt = [DateTimeOffset]::UtcNow
$output = @(& $windowsPowerShell @arguments 1> $stdoutPath 2> $stderrPath)
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw } else { '' }
    $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
    throw "fresh deployment failed for $CaseName with exit $exitCode. stdout=$stdout stderr=$stderr"
}
$endedAt = [DateTimeOffset]::UtcNow

$result = [ordered]@{
    schemaVersion = 'cyc.dev/windows-profile-matrix-case/v1'
    status = 'passed'
    caseName = $CaseName
    sid = [string]$identity.User.Value
    expectedSid = $ExpectedSid
    account = [string]$identity.Name
    isAdministrator = [bool]$isAdmin
    isElevated = [bool]$isElevated
    userProfile = $profile
    localAppData = $localAppData
    temp = $temp
    nonAsciiProfile = [bool](Test-NonAscii $profile)
    taskLogonType = 'S4U'
    taskLogonTypeReason = 'non-interactive-profile-matrix-harness'
    packageRoot = $package
    workRoot = $work
    freshDeploymentWorkRoot = $freshWork
    startedAt = $startedAt.ToString('o')
    endedAt = $endedAt.ToString('o')
    exitCode = [int]$exitCode
    logs = [ordered]@{
        stdout = $stdoutPath
        stderr = $stderrPath
    }
    outputLines = @($output | ForEach-Object { [string]$_ })
}
$parent = Split-Path -Parent $receipt
[void](New-Item -ItemType Directory -Path $parent -Force)
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receipt -Encoding UTF8
$result | ConvertTo-Json -Depth 8 -Compress
