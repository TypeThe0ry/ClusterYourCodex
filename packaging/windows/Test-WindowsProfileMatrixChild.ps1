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
    [string]$ReceiptPath,

    # A disposable standard-user process has no Winlogon token and cannot
    # reliably register an InteractiveToken task. The elevated matrix parent
    # may own that one privileged operation through an explicit, evidenced
    # request/response gate. CurrentUserOnly runs leave this switch off and
    # exercise the ordinary production path directly.
    [switch]$UseParentTaskHelper
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

function ConvertTo-ProfileMatrixMemberSid {
    param([Parameter(Mandatory = $true)]$Member)

    # A filtered UAC token can omit the Administrators SID entirely from the
    # WindowsIdentity.Groups projection. Resolve the member object itself by
    # SID so the acceptance check remains independent of localized names and
    # token filtering.
    $sidProperty = $Member.PSObject.Properties['SID']
    if ($null -ne $sidProperty -and $null -ne $sidProperty.Value) {
        $rawSid = $sidProperty.Value
        if ($rawSid -is [System.Security.Principal.SecurityIdentifier]) {
            return $rawSid.Value
        }
        $sidText = ([string]$rawSid).Trim()
        if ($sidText -match '^S-\d-\d+(?:-\d+)+$') {
            return $sidText
        }
    }
    $nameProperty = $Member.PSObject.Properties['Name']
    if ($null -ne $nameProperty -and -not [string]::IsNullOrWhiteSpace([string]$nameProperty.Value)) {
        try {
            return ([System.Security.Principal.NTAccount]::new([string]$nameProperty.Value)).Translate(
                [System.Security.Principal.SecurityIdentifier]
            ).Value
        } catch {
            # Keep the unresolved member in the query diagnostics; only an
            # exact SID match can satisfy the administrator case.
        }
    }
    return $null
}

function Get-ProfileMatrixLocalAdministratorMembership {
    param(
        [Parameter(Mandatory = $true)][System.Security.Principal.SecurityIdentifier]$AdminGroupSid,
        [Parameter(Mandatory = $true)][string]$ExpectedSid
    )

    $observedSids = @()
    $queryError = $null
    try {
        # Query the local SAM by the well-known Administrators SID. This is a
        # ground-truth fallback for ARM64/x64-emulated logons whose filtered
        # token does not expose the deny-only group through WindowsIdentity.
        $members = @(Get-LocalGroupMember -SID $AdminGroupSid -ErrorAction Stop)
        $observedSids = @(
            $members |
                ForEach-Object { ConvertTo-ProfileMatrixMemberSid -Member $_ } |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                Sort-Object -Unique
        )
    } catch {
        $queryError = [string]$_.Exception.Message
    }
    return [pscustomobject]@{
        isMember = @($observedSids | Where-Object { $_ -ceq $ExpectedSid }).Count -gt 0
        observedSids = @($observedSids)
        queryError = $queryError
    }
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
# A newly created local administrator normally receives a filtered, non-
# elevated token. WindowsPrincipal.IsInRole can therefore return false even
# though the Administrators SID is present as a deny-only group. Membership is
# the profile-matrix contract; keep elevation as a separate observation. Some
# ARM64/x64-emulated logons omit even the deny-only SID from Groups, so the
# local SAM query below is the authoritative fallback for that projection.
$tokenGroupSids = @(
    $identity.Groups |
        ForEach-Object { [string]$_.Value } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique
)
$adminGroupPresent = @($tokenGroupSids | Where-Object { $_ -ceq $adminSid.Value }).Count -gt 0
$tokenAdminRole = [bool]$principal.IsInRole($adminSid)
$localAdminMembership = Get-ProfileMatrixLocalAdministratorMembership `
    -AdminGroupSid $adminSid `
    -ExpectedSid ([string]$identity.User.Value)
$isAdmin = $tokenAdminRole -or $adminGroupPresent -or [bool]$localAdminMembership.isMember
$isElevated = [bool]$principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
$adminMembershipSource = if ($tokenAdminRole) {
    'token-is-in-role'
} elseif ($adminGroupPresent) {
    'token-group-sid'
} elseif ($localAdminMembership.isMember) {
    'local-group-sid'
} elseif (-not [string]::IsNullOrWhiteSpace([string]$localAdminMembership.queryError)) {
    'query-error'
} else {
    'none'
}

Assert-ProfileMatrix (Test-Path -LiteralPath $package -PathType Container) "package root exists: $package"
Assert-ProfileMatrix (Test-Path -LiteralPath $work -PathType Container) "work root exists: $work"
Assert-ProfileMatrix (-not [string]::IsNullOrWhiteSpace([string]$identity.User.Value)) 'current identity has a SID'
Assert-ProfileMatrix ([string]$identity.User.Value -ceq $ExpectedSid) "current identity SID matches expected SID (expected=$ExpectedSid observed=$([string]$identity.User.Value))"
Assert-ProfileMatrix ($isAdmin -eq $expectedAdmin) "administrator membership matches case (expected=$expectedAdmin observed=$isAdmin source=$adminMembershipSource localQueryError=$([string]$localAdminMembership.queryError))"
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
$taskGateEvidencePath = Join-Path $work 'task-gate.json'
$taskRequestPath = Join-Path $work 'task-registration-request.json'
$taskResponsePath = Join-Path $work 'task-registration-response.json'
$taskHelperEvidencePath = Join-Path $work 'task-helper-evidence.json'
$arguments = @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $freshTest,
    '-PackageRoot', $package,
    '-WorkRoot', $freshWork,
    '-KeepWorkRoot',
    # Always request the production Interactive principal. For disposable
    # accounts the parent helper owns registration; this child still verifies
    # the persisted task definition through Test-FreshDeployment.
    '-ScheduledTaskLogonType', 'Interactive'
)
if ($UseParentTaskHelper) {
    $arguments += '-ProfileMatrixTaskHelperMode'
}

$startedAt = [DateTimeOffset]::UtcNow
$oldGate = [string]$env:CYC_PROFILE_MATRIX_TASK_GATE
$oldGateEvidence = [string]$env:CYC_PROFILE_MATRIX_TASK_GATE_EVIDENCE
$oldTaskRequest = [string]$env:CYC_PROFILE_MATRIX_TASK_REQUEST
$oldTaskResponse = [string]$env:CYC_PROFILE_MATRIX_TASK_RESPONSE
try {
    if ($UseParentTaskHelper) {
        $gate = [ordered]@{
            schemaVersion = 'cyc.dev/windows-profile-matrix-task-gate/v1'
            mode = 'parent-elevated-registration-only'
            caseName = $CaseName
            sid = [string]$identity.User.Value
            requestedTaskLogonType = 'Interactive'
            requestPath = $taskRequestPath
            responsePath = $taskResponsePath
            createdAtUtc = [DateTime]::UtcNow.ToString('o')
        }
        $gate | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $taskGateEvidencePath -Encoding UTF8
        $env:CYC_PROFILE_MATRIX_TASK_GATE = 'parent-elevated-registration-v1'
        $env:CYC_PROFILE_MATRIX_TASK_GATE_EVIDENCE = $taskGateEvidencePath
        $env:CYC_PROFILE_MATRIX_TASK_REQUEST = $taskRequestPath
        $env:CYC_PROFILE_MATRIX_TASK_RESPONSE = $taskResponsePath
    }
    $output = @(& $windowsPowerShell @arguments 1> $stdoutPath 2> $stderrPath)
} finally {
    if ($UseParentTaskHelper) {
        $env:CYC_PROFILE_MATRIX_TASK_GATE = $oldGate
        $env:CYC_PROFILE_MATRIX_TASK_GATE_EVIDENCE = $oldGateEvidence
        $env:CYC_PROFILE_MATRIX_TASK_REQUEST = $oldTaskRequest
        $env:CYC_PROFILE_MATRIX_TASK_RESPONSE = $oldTaskResponse
    }
}
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
    administratorMembershipSource = $adminMembershipSource
    administratorMembershipTokenRole = [bool]$tokenAdminRole
    administratorMembershipTokenGroup = [bool]$adminGroupPresent
    administratorMembershipTokenGroupSids = @($tokenGroupSids)
    administratorMembershipLocalGroup = [bool]$localAdminMembership.isMember
    administratorMembershipObservedSids = @($localAdminMembership.observedSids)
    administratorMembershipQueryError = $localAdminMembership.queryError
    isElevated = [bool]$isElevated
    userProfile = $profile
    localAppData = $localAppData
    temp = $temp
    nonAsciiProfile = [bool](Test-NonAscii $profile)
    taskLogonType = 'Interactive'
    taskLogonTypeReason = if ($UseParentTaskHelper) {
        'production-principal-parent-elevated-registration-only'
    } else {
        'production-principal-runtime-verified'
    }
    taskRegistration = if ($UseParentTaskHelper) { 'parent-elevated-helper' } else { 'child-production-path' }
    taskRuntime = if ($UseParentTaskHelper) { 'not-started' } else { 'started' }
    taskGate = if ($UseParentTaskHelper) { 'parent-elevated-registration-v1' } else { 'none' }
    taskGateEvidence = if ($UseParentTaskHelper) { $taskGateEvidencePath } else { $null }
    taskHelperEvidence = if ($UseParentTaskHelper) { $taskHelperEvidencePath } else { $null }
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
