#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [string]$WorkRoot = (Join-Path ([System.IO.Path]::GetTempPath()) ('clusteryourcodex-fresh-' + [Guid]::NewGuid().ToString('N'))),

    [switch]$KeepWorkRoot,

    # The normal product task principal is InteractiveToken. The legacy
    # ProfileMatrixTestMode/S4U switch remains explicitly guarded for older
    # isolated harnesses, while the current disposable profile matrix uses an
    # elevated parent registration gate and keeps the production principal.
    [ValidateSet('Interactive', 'S4U')]
    [string]$ScheduledTaskLogonType = 'Interactive',

    [switch]$ProfileMatrixTestMode,

    [switch]$ProfileMatrixTaskHelperMode,

    # Every lifecycle child is a disposable acceptance process.  Keep the
    # parent bounded so a hung Windows PowerShell child cannot strand a
    # hosted runner (or skip the diagnostic upload and downstream gates).
    [ValidateRange(60, 2400)]
    [int]$LifecycleTimeoutSeconds = 900
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($ProfileMatrixTestMode -and $ScheduledTaskLogonType -cne 'S4U') {
    throw 'ProfileMatrixTestMode requires ScheduledTaskLogonType S4U.'
}
if (-not $ProfileMatrixTestMode -and $ScheduledTaskLogonType -cne 'Interactive') {
    throw 'ScheduledTaskLogonType S4U is restricted to ProfileMatrixTestMode.'
}

function Assert-FreshTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw "fresh deployment assertion failed: $Message"
    }
}

# The harness is also launched by a pwsh parent as a Windows PowerShell 5.1
# child. That boundary can inherit pwsh's PSModulePath and leave the Windows
# PowerShell utility module unavailable. Use the same module-independent
# streaming implementation as the packaged bootstrap so acceptance checks
# remain deterministic on clean runners.
function Get-CycFileHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][ValidateSet('SHA256')][string]$Algorithm
    )

    if ($Algorithm -cne 'SHA256') {
        throw "Unsupported file hash algorithm: $Algorithm"
    }
    $stream = $null
    $sha256 = $null
    try {
        $stream = [System.IO.File]::OpenRead($LiteralPath)
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        [PSCustomObject]@{
            Algorithm = 'SHA256'
            Hash = ([System.BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '')
            Path = [System.IO.Path]::GetFullPath($LiteralPath)
        }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $sha256) { $sha256.Dispose() }
    }
}

# Windows PowerShell 5.1 decodes BOM-less JSON with the active ANSI code
# page when Get-Content is used.  The package and install manifests are
# emitted as strict UTF-8 without a BOM and can contain a non-ASCII profile
# path, so keep this acceptance harness on the same explicit decoder as the
# production bootstrap/profile-matrix IPC boundary.
function Read-FreshUtf8Json {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
    $raw = $utf8Strict.GetString($bytes)
    if ($raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF) {
        $raw = $raw.Substring(1)
    }
    $converter = Get-Command ConvertFrom-Json -CommandType Cmdlet -ErrorAction Stop
    if ($converter.Parameters.ContainsKey('DateKind')) {
        return ConvertFrom-Json -InputObject $raw -DateKind String
    }
    return ConvertFrom-Json -InputObject $raw
}

function Resolve-FreshPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Resolve-FreshOwnedIsolationRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Suffix
    )

    if ($Suffix -cnotmatch '^[0-9a-f]{32}$') {
        throw "invalid fresh deployment isolation suffix: $Suffix"
    }
    $resolvedRoot = Resolve-FreshPath $Root
    $localAppData = Resolve-FreshPath $env:LOCALAPPDATA
    $localAppDataItem = Get-Item -LiteralPath $localAppData -Force -ErrorAction Stop
    if (($localAppDataItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "refusing to use a fresh deployment root beneath redirected LOCALAPPDATA: $localAppData"
    }
    $expectedLeaf = "ClusterYourCodex-fresh-$Suffix"
    $expectedRoot = Resolve-FreshPath (Join-Path $localAppData $expectedLeaf)
    if (-not [string]::Equals($resolvedRoot, $expectedRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals((Split-Path -Parent $resolvedRoot), $localAppData, [System.StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedRoot) -cne $expectedLeaf) {
        throw "refusing to use an unowned fresh deployment root: $resolvedRoot"
    }
    return $resolvedRoot
}

function New-FreshIsolationOwnerMarker {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Suffix
    )

    $resolvedRoot = Resolve-FreshOwnedIsolationRoot -Root $Root -Suffix $Suffix
    if (Test-Path -LiteralPath $resolvedRoot) {
        throw "fresh deployment isolation root already exists before the harness run: $resolvedRoot"
    }
    # New-Item on Windows PowerShell 5.1 has no LiteralPath parameter. The
    # validated GUID-derived root contains no wildcard metacharacters.
    $rootCreated = $false
    $markerPath = Join-Path $resolvedRoot '.clusteryourcodex-fresh-owner.json'
    try {
        [void](New-Item -ItemType Directory -Path $resolvedRoot -ErrorAction Stop)
        $rootCreated = $true
        $rootItem = Get-Item -LiteralPath $resolvedRoot -Force -ErrorAction Stop
        if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "refusing to use a reparse-point fresh deployment isolation root: $resolvedRoot"
        }
        $marker = [ordered]@{
            schemaVersion = 'cyc.dev/fresh-deployment-owner/v1'
            owner = 'Test-FreshDeployment.ps1'
            root = $resolvedRoot
            suffix = $Suffix
            createdAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        $markerJson = $marker | ConvertTo-Json -Depth 4 -Compress
        [System.IO.File]::WriteAllText(
            $markerPath,
            $markerJson,
            [System.Text.UTF8Encoding]::new($false)
        )
        [void](Assert-FreshIsolationOwnerMarker -Root $resolvedRoot -Suffix $Suffix)
        return $markerPath
    } catch {
        # The caller has not received the marker path yet, so this function is
        # the only owner that can safely roll back a root created by a failed
        # marker transaction. Remove it only while it is still a regular,
        # marker-only directory; leave unexpected/racy content in place for
        # evidence instead of widening cleanup scope.
        if ($rootCreated -and (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
            try {
                $rootItem = Get-Item -LiteralPath $resolvedRoot -Force -ErrorAction Stop
                if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                    if (Test-Path -LiteralPath $markerPath) {
                        Remove-Item -LiteralPath $markerPath -Force -ErrorAction Stop
                    }
                    if (-not (Get-ChildItem -LiteralPath $resolvedRoot -Force -ErrorAction Stop | Select-Object -First 1)) {
                        Remove-Item -LiteralPath $resolvedRoot -Force -ErrorAction Stop
                    }
                }
            } catch {
                # Preserve the marker/ownership failure as the primary error;
                # an unexpected cleanup failure is retained on disk for the
                # outer harness to diagnose.
            }
        }
        throw
    }
}

function Assert-FreshIsolationOwnerMarker {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Suffix
    )

    $resolvedRoot = Resolve-FreshOwnedIsolationRoot -Root $Root -Suffix $Suffix
    $markerPath = Join-Path $resolvedRoot '.clusteryourcodex-fresh-owner.json'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw "fresh deployment isolation owner marker is missing: $markerPath"
    }
    $markerItem = Get-Item -LiteralPath $markerPath -Force -ErrorAction Stop
    if (($markerItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "refusing to trust a reparse-point fresh deployment owner marker: $markerPath"
    }
    try {
        $marker = [System.IO.File]::ReadAllText($markerPath) | ConvertFrom-Json
    } catch {
        throw "fresh deployment isolation owner marker is not valid JSON: $($_.Exception.Message)"
    }
    foreach ($propertyName in @('schemaVersion', 'owner', 'root', 'suffix', 'createdAtUtc')) {
        if ($null -eq $marker.PSObject.Properties[$propertyName]) {
            throw "fresh deployment isolation owner marker is missing $propertyName"
        }
    }
    if ([string]$marker.schemaVersion -cne 'cyc.dev/fresh-deployment-owner/v1' -or
        [string]$marker.owner -cne 'Test-FreshDeployment.ps1' -or
        [string]$marker.root -cne $resolvedRoot -or
        [string]$marker.suffix -cne $Suffix) {
        throw "fresh deployment isolation owner marker does not bind this harness root"
    }
    try {
        [void][DateTimeOffset]::Parse(
            [string]$marker.createdAtUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
    } catch {
        throw "fresh deployment isolation owner marker has an invalid creation timestamp"
    }
    return $markerPath
}

function Remove-FreshOwnedIsolationRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Suffix
    )

    $resolvedRoot = Resolve-FreshOwnedIsolationRoot -Root $Root -Suffix $Suffix
    if (-not (Test-Path -LiteralPath $resolvedRoot)) {
        return
    }
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        throw "fresh deployment isolation root is not a directory: $resolvedRoot"
    }
    [void](Assert-FreshIsolationOwnerMarker -Root $resolvedRoot -Suffix $Suffix)

    # Validate the complete owned tree without traversing a reparse point. The
    # harness, rather than the product uninstaller, owns this synthetic root.
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($resolvedRoot)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        $currentItem = Get-Item -LiteralPath $current -Force
        if (($currentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "refusing to remove a fresh deployment tree containing a reparse point: $current"
        }
        if ($currentItem.PSIsContainer) {
            foreach ($child in @(Get-ChildItem -LiteralPath $current -Force)) {
                if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "refusing to remove a fresh deployment tree containing a reparse point: $($child.FullName)"
                }
                if ($child.PSIsContainer) {
                    $pending.Push($child.FullName)
                }
            }
        }
    }

    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    Assert-FreshTest (-not (Test-Path -LiteralPath $resolvedRoot)) 'the harness removes its owned isolation root'
}

function Remove-FreshOwnedWorkRoot {
    param([Parameter(Mandatory = $true)][string]$Root)

    $resolvedRoot = Resolve-FreshPath $Root
    $tempRoot = Resolve-FreshPath ([System.IO.Path]::GetTempPath())
    $tempItem = Get-Item -LiteralPath $tempRoot -Force -ErrorAction Stop
    if (($tempItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "refusing to remove a work root beneath redirected TEMP: $tempRoot"
    }
    if (-not [string]::Equals((Split-Path -Parent $resolvedRoot), $tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedRoot) -cnotmatch '^clusteryourcodex-fresh-[0-9a-f]{32}$') {
        throw "refusing to remove an unowned fresh deployment work root: $resolvedRoot"
    }
    if (-not (Test-Path -LiteralPath $resolvedRoot)) { return }
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        throw "fresh deployment work root is not a directory: $resolvedRoot"
    }

    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($resolvedRoot)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        $currentItem = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($currentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "refusing to remove a fresh deployment work tree containing a reparse point: $current"
        }
        foreach ($child in @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)) {
            if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "refusing to remove a fresh deployment work tree containing a reparse point: $($child.FullName)"
            }
            if ($child.PSIsContainer) { $pending.Push($child.FullName) }
        }
    }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    Assert-FreshTest (-not (Test-Path -LiteralPath $resolvedRoot)) 'the harness removes its owned work root'
}

function ConvertTo-FreshNativeArgument {
    param([AllowEmptyString()][string]$Argument)
    if ($null -eq $Argument -or $Argument.Length -eq 0) { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }

    # Match CommandLineToArgvW quoting so spaces, quotes, and trailing
    # backslashes in non-ASCII profile/work paths survive powershell.exe -File.
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') {
            $slashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($slashes * 2) + 1)))
            [void]$builder.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) {
            [void]$builder.Append(('\' * $slashes))
            $slashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($slashes -gt 0) { [void]$builder.Append(('\' * ($slashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-FreshPowerShell {
    param(
        [Parameter(Mandatory = $true)][string]$Bootstrap,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$LogRoot,
        [Parameter(Mandatory = $true)][string]$Label,
        [ValidateRange(60, 2400)][int]$TimeoutSeconds = 900
    )

    $stdoutPath = Join-Path $LogRoot ($Label + '.stdout.log')
    $stderrPath = Join-Path $LogRoot ($Label + '.stderr.log')
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Assert-FreshTest (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf) 'Windows PowerShell 5.1 is installed'

    $commandArguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $Bootstrap
    ) + $Arguments
    $startArguments = @($commandArguments | ForEach-Object {
        ConvertTo-FreshNativeArgument -Argument ([string]$_)
    })
    $process = $null
    try {
        $process = Start-Process `
            -FilePath $windowsPowerShell `
            -ArgumentList $startArguments `
            -WorkingDirectory (Split-Path -Parent (Resolve-FreshPath $Bootstrap)) `
            -WindowStyle Hidden `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -PassThru
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
        while (-not $process.WaitForExit(100)) {
            if ([DateTimeOffset]::UtcNow -lt $deadline) { continue }

            $taskKill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
            $taskKillExit = -1
            try {
                & $taskKill /PID $process.Id /T /F *> $null
                $taskKillExit = [int]$LASTEXITCODE
            } catch { }
            $terminated = $false
            try { $terminated = [bool]$process.WaitForExit(30000) } catch { }
            if ($taskKillExit -ne 0 -or -not $terminated) {
                throw "bootstrap $Label timed out after $TimeoutSeconds seconds and process termination was not proven (pid=$($process.Id), taskkillExit=$taskKillExit)."
            }
            throw "bootstrap $Label timed out after $TimeoutSeconds seconds (pid=$($process.Id))."
        }
        $process.WaitForExit()
        try { $process.Refresh() } catch { }
        $exitCode = [int]$process.ExitCode
        if ($exitCode -ne 0) {
            $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
            $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw } else { '' }
            throw "bootstrap $Label failed with exit $exitCode. stdout=$stdout stderr=$stderr"
        }
        return [PSCustomObject]@{
            label = $Label
            exitCode = $exitCode
            stdout = $stdoutPath
            stderr = $stderrPath
        }
    } finally {
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Assert-InstalledFile {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )
    $path = Join-Path $Root ($RelativePath.Replace('/', '\'))
    Assert-FreshTest (Test-Path -LiteralPath $path -PathType Leaf) "installed file exists: $RelativePath"
    return (Get-CycFileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-FreshProductTasks {
    param(
        [Parameter(Mandatory = $true)][string[]]$TaskNames
    )

    $tasks = New-Object 'System.Collections.Generic.List[object]'
    foreach ($taskName in $TaskNames) {
        # Task names are product-owned fixed names. Scope every query to the
        # root Task Scheduler path so an unrelated nested task cannot satisfy
        # (or defeat) this lifecycle proof.
        foreach ($task in @(Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue)) {
            [void]$tasks.Add($task)
        }
    }
    return $tasks.ToArray()
}

function Get-FreshLifecycleState {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$InstallManifestPath,
        [Parameter(Mandatory = $true)][string[]]$TaskNames
    )

    $tasks = @(Get-FreshProductTasks -TaskNames $TaskNames)
    $installRootExists = Test-Path -LiteralPath $InstallRoot
    $dataRootExists = Test-Path -LiteralPath $DataRoot
    $manifestExists = Test-Path -LiteralPath $InstallManifestPath -PathType Leaf
    [PSCustomObject]@{
        installRootExists = [bool]$installRootExists
        dataRootExists = [bool]$dataRootExists
        manifestExists = [bool]$manifestExists
        taskCount = [int]$tasks.Count
        taskNames = @($tasks | ForEach-Object { [string]$_.TaskName })
        # A data root is expected to survive an ordinary Uninstall. The
        # install root, manifest, or fixed product tasks are the cleanup-owned
        # lifecycle state that requires another uninstall attempt.
        lifecycleOwned = [bool]($installRootExists -or $manifestExists -or $tasks.Count -gt 0)
    }
}

function Assert-FreshLifecycleAbsent {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$InstallManifestPath,
        [Parameter(Mandatory = $true)][string[]]$TaskNames,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $state = Get-FreshLifecycleState -InstallRoot $InstallRoot -DataRoot $DataRoot -InstallManifestPath $InstallManifestPath -TaskNames $TaskNames
    Assert-FreshTest (-not $state.installRootExists) ("{0} removes the isolated install root" -f $Label)
    Assert-FreshTest (-not $state.manifestExists) ("{0} removes the install manifest" -f $Label)
    Assert-FreshTest ($state.taskCount -eq 0) ("{0} leaves no product task in the root task path" -f $Label)
    return $state
}

function Normalize-FreshTaskLogonType {
    param([Parameter(Mandatory = $true)][string]$Value)

    switch -Regex ($Value) {
        '^(?:Interactive|InteractiveToken|3)$' { return 'Interactive' }
        '^(?:S4U|4)$' { return 'S4U' }
        default { return $null }
    }
}

function ConvertTo-FreshSid {
    param([Parameter(Mandatory = $true)][string]$Identity)

    $value = $Identity.Trim()
    if ($value -match '^S-\d-\d+(?:-\d+)+$') { return $value }
    try {
        return ([System.Security.Principal.NTAccount]::new($value)).Translate(
            [System.Security.Principal.SecurityIdentifier]
        ).Value
    } catch {
        throw "fresh deployment could not resolve task identity '$Identity' to a SID."
    }
}

function Assert-FreshTaskPrincipal {
    param(
        [Parameter(Mandatory = $true)]$Task,
        [Parameter(Mandatory = $true)][string]$ExpectedLogonType,
        [Parameter(Mandatory = $true)][string]$Label,
        [string]$ExpectedSid
    )

    if ([string]::IsNullOrWhiteSpace($ExpectedSid)) {
        $ExpectedSid = [string]([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    }
    $ExpectedSid = ConvertTo-FreshSid -Identity $ExpectedSid

    $principalProperty = $Task.PSObject.Properties['Principal']
    Assert-FreshTest ($null -ne $principalProperty -and $null -ne $principalProperty.Value) "$Label exposes its task principal"
    $principalUserProperty = $principalProperty.Value.PSObject.Properties['UserId']
    Assert-FreshTest ($null -ne $principalUserProperty -and
        -not [string]::IsNullOrWhiteSpace([string]$principalUserProperty.Value)) "$Label exposes its task principal identity"
    $principalSid = ConvertTo-FreshSid -Identity ([string]$principalUserProperty.Value)
    Assert-FreshTest ($principalSid -ceq $ExpectedSid) "$Label principal identity matches the current SID (expected=$ExpectedSid observed=$principalSid)"
    $logonProperty = $principalProperty.Value.PSObject.Properties['LogonType']
    Assert-FreshTest ($null -ne $logonProperty) "$Label exposes its task logon type"
    $rawLogonType = [string]$logonProperty.Value
    $observed = Normalize-FreshTaskLogonType -Value $rawLogonType
    Assert-FreshTest ($observed -ceq $ExpectedLogonType) "$Label uses the expected task logon type (expected=$ExpectedLogonType observed=$rawLogonType)"

    $triggerSids = @(
        foreach ($trigger in @($Task.Triggers)) {
            $triggerUserProperty = $trigger.PSObject.Properties['UserId']
            if ($null -ne $triggerUserProperty -and
                -not [string]::IsNullOrWhiteSpace([string]$triggerUserProperty.Value)) {
                ConvertTo-FreshSid -Identity ([string]$triggerUserProperty.Value)
            }
        }
    )
    Assert-FreshTest ($triggerSids.Count -eq 1 -and $triggerSids[0] -ceq $ExpectedSid) "$Label has exactly one logon trigger bound to the current SID (expected=$ExpectedSid observed=$($triggerSids -join ', '))"
    return $observed
}

function Wait-FreshFileUnlocked {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$TimeoutSeconds = 60
    )

    if ($TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 300) {
        throw "invalid fresh deployment file-unlock timeout: $TimeoutSeconds"
    }
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastError = ''
    do {
        $stream = $null
        try {
            # Windows 11 ARM64 x64 emulation and endpoint scanners can retain a
            # transient executable handle after a short-lived --help process
            # has returned. Require an exclusive read/write open before the
            # harness mutates the packaged executable for the repair proof.
            $stream = [System.IO.File]::Open(
                $Path,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
            return
        } catch [System.IO.IOException] {
            $lastError = $_.Exception.Message
        } catch [System.UnauthorizedAccessException] {
            $lastError = $_.Exception.Message
        } finally {
            if ($null -ne $stream) {
                $stream.Dispose()
            }
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    throw "fresh deployment file remained locked before repair mutation: $Path; lastError=$lastError"
}

$package = Resolve-FreshPath $PackageRoot
$work = Resolve-FreshPath $WorkRoot
$workExistedAtStart = Test-Path -LiteralPath $work
$payload = Join-Path $package 'payload'
$manifestPath = Join-Path $package 'preview-manifest.json'
$bootstrap = Join-Path $package 'payload\installer\bootstrap.ps1'
$logRoot = Join-Path $work 'logs'
$suffix = [Guid]::NewGuid().ToString('N')
$isolatedRoot = Resolve-FreshPath (Join-Path $env:LOCALAPPDATA "ClusterYourCodex-fresh-$suffix")
$installRoot = Resolve-FreshPath (Join-Path $isolatedRoot 'program')
$dataRoot = Resolve-FreshPath (Join-Path $isolatedRoot 'data')
$workerConfig = Resolve-FreshPath (Join-Path $dataRoot 'worker\config.json')
$installedManifestPath = Join-Path $dataRoot '.installer\install-manifest.json'
$isolatedRootExistedAtStart = Test-Path -LiteralPath $isolatedRoot
$expectedTaskSid = [string]([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)

Assert-FreshTest (Test-Path -LiteralPath $package -PathType Container) "package root exists: $package"
Assert-FreshTest (Test-Path -LiteralPath $payload -PathType Container) 'package payload exists'
Assert-FreshTest (Test-Path -LiteralPath $manifestPath -PathType Leaf) 'package manifest exists'
Assert-FreshTest (Test-Path -LiteralPath $bootstrap -PathType Leaf) 'payload bootstrap exists'
if (-not $KeepWorkRoot) {
    Assert-FreshTest (-not $workExistedAtStart) 'auto-cleaned work root did not exist before this harness run'
    Assert-FreshTest ([string]::Equals((Split-Path -Parent $work), (Resolve-FreshPath ([System.IO.Path]::GetTempPath())), [System.StringComparison]::OrdinalIgnoreCase)) 'auto-cleaned work root is a direct TEMP child'
    Assert-FreshTest ((Split-Path -Leaf $work) -cmatch '^clusteryourcodex-fresh-[0-9a-f]{32}$') 'auto-cleaned work root uses the harness-owned GUID name'
}
[void](New-Item -ItemType Directory -Path $logRoot -Force)

$common = @(
    '-Action', 'Install',
    '-BundleRoot', $payload,
    '-PackageRoot', $package,
    '-PackageManifest', $manifestPath,
    '-PackageExecutable', (Join-Path $package 'bootstrap.ps1'),
    '-InstallRoot', $installRoot,
    '-DataRoot', $dataRoot,
    '-WorkerConfig', $workerConfig,
    '-DisableManagedWorkerListener',
    '-SkipFirewall',
    '-SkipCodexIntegration',
    '-SkipUninstallRegistration'
)
if ($ProfileMatrixTestMode) {
    $common += @(
        '-ProfileMatrixTestMode',
        '-ScheduledTaskLogonType', $ScheduledTaskLogonType
    )
}
if ($ProfileMatrixTaskHelperMode) {
    $common += '-ProfileMatrixTaskHelperMode'
}
# Do not append a serialized `-Confirm:$false` token here. Windows PowerShell
# 5.1 treats that native argv token as a String when a script is launched with
# `powershell.exe -File`, then fails to bind it to SwitchParameter. This child
# starts with -NoProfile and the default ConfirmPreference (High), while the
# lifecycle's ConfirmImpact is Medium, so the non-interactive smoke remains
# non-prompting without forwarding the common parameter.
$installAttempted = $false
$installed = $false
$uninstallAttempted = $false
$uninstalled = $false
$isolatedRootPrepared = $false
$isolatedRootMarkerPath = $null
$bodySucceeded = $false
$productTaskNames = @('ClusterYourCodex Controller', 'ClusterYourCodex Worker')

try {
    Assert-FreshTest (-not $isolatedRootExistedAtStart) 'isolated root did not exist before this harness run'
    $isolatedRootMarkerPath = New-FreshIsolationOwnerMarker -Root $isolatedRoot -Suffix $suffix
    $isolatedRootPrepared = $true
    $productTasksBefore = @(Get-FreshProductTasks -TaskNames $productTaskNames)
    $preInstallState = Get-FreshLifecycleState -InstallRoot $installRoot -DataRoot $dataRoot -InstallManifestPath $installedManifestPath -TaskNames $productTaskNames
    Assert-FreshTest ($productTasksBefore.Count -eq 0) 'fresh deployment runner starts without pre-existing product tasks'
    Assert-FreshTest (-not $preInstallState.lifecycleOwned) 'isolated lifecycle state did not exist before install'

    $plan = Invoke-FreshPowerShell -Bootstrap $bootstrap -Arguments ($common + @('-PlanOnly')) -LogRoot $logRoot -Label 'plan' -TimeoutSeconds $LifecycleTimeoutSeconds
    Assert-FreshTest ($plan.exitCode -eq 0) 'manifest-bound install plan succeeds'
    $previewManifest = Read-FreshUtf8Json -Path $manifestPath
    Assert-FreshTest ([string]$previewManifest.schemaVersion -eq 'cyc.dev/windows-preview/v1') 'preview manifest schema is recognized'
    Assert-FreshTest ([string]$previewManifest.productVersion -match '^[0-9]+\.[0-9]+\.[0-9]+-(preview|alpha|beta|rc)\.[0-9]+$') 'preview manifest carries a strict prerelease product version'
    Assert-FreshTest ([string]$previewManifest.releaseChannel -ceq 'prerelease') 'preview manifest release channel remains prerelease'
    Assert-FreshTest ($null -eq $previewManifest.sourceTag -or [string]$previewManifest.sourceTag -ceq "v$($previewManifest.productVersion)") 'preview manifest source tag is absent or exactly vPRODUCT_VERSION'

    # The child can commit a task/manifest and then fail before returning.
    # Mark cleanup ownership before crossing that process boundary.
    $installAttempted = $true
    $installed = $true
    [void](Invoke-FreshPowerShell -Bootstrap $bootstrap -Arguments $common -LogRoot $logRoot -Label 'install' -TimeoutSeconds $LifecycleTimeoutSeconds)
    foreach ($relative in @('ClusterYourCodex.exe', 'cyc-controller.exe', 'cyc-worker.exe', 'cyc.exe', 'installer/bootstrap.ps1')) {
        [void](Assert-InstalledFile -Root $installRoot -RelativePath $relative)
    }
    Assert-FreshTest (Test-Path -LiteralPath $installedManifestPath -PathType Leaf) 'install manifest is durable'
    $installedManifest = Read-FreshUtf8Json -Path $installedManifestPath
    Assert-FreshTest ([string]$installedManifest.schemaVersion -eq 'cyc.dev/windows-install-manifest/v1') 'installed manifest schema is recognized'
    Assert-FreshTest ([string]$installedManifest.productVersion -ceq [string]$previewManifest.productVersion) 'installed manifest preserves the package product version'
    Assert-FreshTest ([string]$installedManifest.installRoot -eq $installRoot) 'manifest binds the isolated install root'
    Assert-FreshTest ([string]$installedManifest.dataRoot -eq $dataRoot) 'manifest binds the isolated data root'
    Assert-FreshTest (-not [bool]$installedManifest.managedWorker.enabled) 'managed worker is disabled for isolated smoke'
    $installedControllerTasks = @(Get-ScheduledTask -TaskName 'ClusterYourCodex Controller' -TaskPath '\' -ErrorAction SilentlyContinue)
    $installedWorkerTasks = @(Get-ScheduledTask -TaskName 'ClusterYourCodex Worker' -TaskPath '\' -ErrorAction SilentlyContinue)
    Assert-FreshTest ($installedControllerTasks.Count -eq 1) 'install registers exactly one controller task'
    Assert-FreshTest ($installedWorkerTasks.Count -eq 0) 'disabled managed worker does not leave a worker task'
    $expectedTaskLogonType = if ($ProfileMatrixTestMode) { 'S4U' } else { 'Interactive' }
    $observedTaskLogonType = Assert-FreshTaskPrincipal `
        -Task $installedControllerTasks[0] `
        -ExpectedLogonType $expectedTaskLogonType `
        -ExpectedSid $expectedTaskSid `
        -Label 'controller task'
    Assert-FreshTest ([string]$installedControllerTasks[0].TaskPath -eq '\') 'controller task is registered at the expected task path'
    $installedControllerActions = @($installedControllerTasks[0].Actions)
    Assert-FreshTest ($installedControllerActions.Count -eq 1) 'controller task has exactly one action'
    Assert-FreshTest (
        [string]::Equals(
            (Resolve-FreshPath ([string]$installedControllerActions[0].Execute)),
            (Resolve-FreshPath (Join-Path $installRoot 'cyc-controller.exe')),
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) 'controller task action is bound to the isolated installed controller'
    Assert-FreshTest (
        [string]::Equals(
            (Resolve-FreshPath ([string]$installedControllerActions[0].WorkingDirectory)),
            $installRoot,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) 'controller task action uses the isolated install root as its working directory'

    & (Join-Path $installRoot 'cyc-controller.exe') '--version' *> (Join-Path $logRoot 'controller-version.log')
    Assert-FreshTest ($LASTEXITCODE -eq 0) 'installed controller --version succeeds'
    & (Join-Path $installRoot 'cyc-worker.exe') 'probe' '--workspace' $work '--pretty' *> (Join-Path $logRoot 'worker-probe.log')
    Assert-FreshTest ($LASTEXITCODE -eq 0) 'installed worker probe succeeds'
    & (Join-Path $installRoot 'cyc.exe') '--help' *> (Join-Path $logRoot 'cli-help.log')
    Assert-FreshTest ($LASTEXITCODE -eq 0) 'installed CLI --help succeeds'

    $installedCliPath = Join-Path $installRoot 'cyc.exe'
    $installedCliSha256 = (Get-CycFileHash -LiteralPath $installedCliPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $installedCliBytes = [System.IO.File]::ReadAllBytes($installedCliPath)
    Assert-FreshTest ($installedCliBytes.Length -gt 4096) 'installed CLI is large enough for a deterministic repair mutation'
    Wait-FreshFileUnlocked -Path $installedCliPath
    $mutationOffset = $installedCliBytes.Length - 1
    $installedCliBytes[$mutationOffset] = $installedCliBytes[$mutationOffset] -bxor 0xff
    [System.IO.File]::WriteAllBytes($installedCliPath, $installedCliBytes)
    $mutatedCliSha256 = (Get-CycFileHash -LiteralPath $installedCliPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-FreshTest ($mutatedCliSha256 -cne $installedCliSha256) 'repair precondition corrupts the installed CLI'

    $repairArguments = @($common)
    $repairArguments[1] = 'Repair'
    [void](Invoke-FreshPowerShell -Bootstrap $bootstrap -Arguments $repairArguments -LogRoot $logRoot -Label 'repair' -TimeoutSeconds $LifecycleTimeoutSeconds)
    $repairedManifest = Read-FreshUtf8Json -Path $installedManifestPath
    Assert-FreshTest ([string]$repairedManifest.schemaVersion -eq 'cyc.dev/windows-install-manifest/v1') 'repair keeps a valid manifest'
    $repairedControllerTasks = @(Get-ScheduledTask -TaskName 'ClusterYourCodex Controller' -TaskPath '\' -ErrorAction SilentlyContinue)
    Assert-FreshTest ($repairedControllerTasks.Count -eq 1) 'repair keeps exactly one controller task'
    [void](Assert-FreshTaskPrincipal `
        -Task $repairedControllerTasks[0] `
        -ExpectedLogonType $expectedTaskLogonType `
        -ExpectedSid $expectedTaskSid `
        -Label 'repaired controller task')
    $repairedCliSha256 = (Get-CycFileHash -LiteralPath $installedCliPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-FreshTest ($repairedCliSha256 -ceq $installedCliSha256) 'repair restores the exact packaged CLI bytes'
    & $installedCliPath '--help' *> (Join-Path $logRoot 'cli-help-after-repair.log')
    Assert-FreshTest ($LASTEXITCODE -eq 0) 'repaired CLI --help succeeds'

    $uninstallArguments = @(
        '-Action', 'Uninstall',
        '-InstallRoot', $installRoot,
        '-DataRoot', $dataRoot,
        '-DisableManagedWorkerListener',
        '-SkipFirewall',
        '-SkipCodexIntegration',
        '-SkipUninstallRegistration'
    )
    if ($ProfileMatrixTaskHelperMode) {
        $uninstallArguments += '-ProfileMatrixTaskHelperMode'
    }
    $uninstallAttempted = $true
    [void](Invoke-FreshPowerShell -Bootstrap $bootstrap -Arguments $uninstallArguments -LogRoot $logRoot -Label 'uninstall' -TimeoutSeconds $LifecycleTimeoutSeconds)
    # A successful child exit is not the lifecycle proof. Keep cleanup armed
    # until the task, manifest, and install-root postconditions all pass.
    $uninstallPostcondition = @{
        InstallRoot = $installRoot
        DataRoot = $dataRoot
        InstallManifestPath = $installedManifestPath
        TaskNames = $productTaskNames
        Label = 'uninstall'
    }
    [void](Assert-FreshLifecycleAbsent @uninstallPostcondition)
    Assert-FreshTest (Test-Path -LiteralPath $dataRoot -PathType Container) 'uninstall preserves the isolated data root by default'
    $uninstalled = $true

    $bodySucceeded = $true
    [PSCustomObject]@{
        schemaVersion = 'cyc.dev/fresh-deployment-test/v1'
        status = 'passed'
        packageRoot = $package
        installRoot = $installRoot
        dataRoot = $dataRoot
        ownerMarker = $isolatedRootMarkerPath
        taskLogonType = $observedTaskLogonType
        steps = @('plan', 'install', 'controller-version', 'worker-probe', 'cli-help', 'repair-corrupted-cli', 'uninstall')
        logs = $logRoot
    } | ConvertTo-Json -Depth 6
} finally {
    $postTestCleanupFailures = New-Object System.Collections.Generic.List[string]
    if ($isolatedRootPrepared -and $installed -and -not $uninstalled) {
        $cleanupState = $null
        try {
            $cleanupState = Get-FreshLifecycleState -InstallRoot $installRoot -DataRoot $dataRoot -InstallManifestPath $installedManifestPath -TaskNames $productTaskNames
            if (-not $cleanupState.lifecycleOwned) {
                Write-Verbose 'fresh deployment cleanup skipped because no owned lifecycle state remains'
            } else {
                $cleanupArguments = @(
                    '-Action', 'Uninstall',
                    '-InstallRoot', $installRoot,
                    '-DataRoot', $dataRoot,
                    '-DisableManagedWorkerListener',
                    '-SkipFirewall',
                    '-SkipCodexIntegration',
                    '-SkipUninstallRegistration'
                )
                if ($ProfileMatrixTaskHelperMode) {
                    $cleanupArguments += '-ProfileMatrixTaskHelperMode'
                }
                [void](Invoke-FreshPowerShell -Bootstrap $bootstrap -Arguments $cleanupArguments -LogRoot $logRoot -Label 'cleanup' -TimeoutSeconds $LifecycleTimeoutSeconds)
            }
        } catch {
            $message = "fresh deployment cleanup failed: $($_.Exception.Message)"
            if ($bodySucceeded) { [void]$postTestCleanupFailures.Add($message) } else { Write-Warning $message }
        }
        try {
            $cleanupPostcondition = @{
                InstallRoot = $installRoot
                DataRoot = $dataRoot
                InstallManifestPath = $installedManifestPath
                TaskNames = $productTaskNames
                Label = 'failure cleanup'
            }
            [void](Assert-FreshLifecycleAbsent @cleanupPostcondition)
        } catch {
            $message = "fresh deployment lifecycle cleanup postcondition failed: $($_.Exception.Message)"
            if ($bodySucceeded) { [void]$postTestCleanupFailures.Add($message) } else { Write-Warning $message }
        }
    }
    try {
        if (-not $KeepWorkRoot -and (Test-Path -LiteralPath $work)) {
            Assert-FreshTest (-not $workExistedAtStart) 'work root was created by this harness run'
            Remove-FreshOwnedWorkRoot -Root $work
        }
    } catch {
        $message = "work-root cleanup failed: $($_.Exception.Message)"
        if ($bodySucceeded) { [void]$postTestCleanupFailures.Add($message) } else { Write-Warning $message }
    }
    # Prove that no install root, manifest, or product task remains before
    # deleting the synthetic root. Otherwise a failed uninstall could leave a
    # scheduled task pointing at binaries that the harness has already erased.
    $lifecycleClean = $true
    if ($isolatedRootPrepared -and ($installAttempted -or $uninstallAttempted)) {
        try {
            $preRootRemovalPostcondition = @{
                InstallRoot = $installRoot
                DataRoot = $dataRoot
                InstallManifestPath = $installedManifestPath
                TaskNames = $productTaskNames
                Label = 'pre-root-removal lifecycle'
            }
            [void](Assert-FreshLifecycleAbsent @preRootRemovalPostcondition)
        } catch {
            $lifecycleClean = $false
            $message = "fresh deployment pre-root-removal lifecycle postcondition failed: $($_.Exception.Message)"
            if ($bodySucceeded) { [void]$postTestCleanupFailures.Add($message) } else { Write-Warning $message }
        }
    }
    try {
        if ($isolatedRootPrepared -and $lifecycleClean) {
            [void](Assert-FreshIsolationOwnerMarker -Root $isolatedRoot -Suffix $suffix)
            Remove-FreshOwnedIsolationRoot -Root $isolatedRoot -Suffix $suffix
        } elseif ($isolatedRootPrepared) {
            Write-Warning 'owned isolation root retained because lifecycle cleanup did not reach its postcondition'
        }
    } catch {
        $message = "owned-root cleanup failed: $($_.Exception.Message)"
        if ($bodySucceeded) { [void]$postTestCleanupFailures.Add($message) } else { Write-Warning $message }
    }
    if ($isolatedRootPrepared -and ($installAttempted -or $uninstallAttempted)) {
        try {
            $finalLifecyclePostcondition = @{
                InstallRoot = $installRoot
                DataRoot = $dataRoot
                InstallManifestPath = $installedManifestPath
                TaskNames = $productTaskNames
                Label = 'final lifecycle'
            }
            [void](Assert-FreshLifecycleAbsent @finalLifecyclePostcondition)
        } catch {
            $message = "fresh deployment final lifecycle postcondition failed: $($_.Exception.Message)"
            if ($bodySucceeded) { [void]$postTestCleanupFailures.Add($message) } else { Write-Warning $message }
        }
    }
    if ($bodySucceeded -and $postTestCleanupFailures.Count -gt 0) {
        throw "fresh deployment post-test cleanup failed: $($postTestCleanupFailures -join '; ')"
    }
}
