#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [string]$WorkRoot = (Join-Path ([System.IO.Path]::GetTempPath()) ('clusteryourcodex-fresh-' + [Guid]::NewGuid().ToString('N'))),

    [switch]$KeepWorkRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-FreshTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw "fresh deployment assertion failed: $Message"
    }
}

function Resolve-FreshPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Remove-FreshOwnedIsolationRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Suffix
    )

    if ($Suffix -cnotmatch '^[0-9a-f]{32}$') {
        throw "invalid fresh deployment isolation suffix: $Suffix"
    }
    $resolvedRoot = Resolve-FreshPath $Root
    $localAppData = Resolve-FreshPath $env:LOCALAPPDATA
    $localAppDataItem = Get-Item -LiteralPath $localAppData -Force
    if (($localAppDataItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "refusing to remove a fresh deployment root beneath redirected LOCALAPPDATA: $localAppData"
    }
    $expectedLeaf = "ClusterYourCodex-fresh-$Suffix"
    $expectedRoot = Resolve-FreshPath (Join-Path $localAppData $expectedLeaf)
    if (-not [string]::Equals($resolvedRoot, $expectedRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals((Split-Path -Parent $resolvedRoot), $localAppData, [System.StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedRoot) -cne $expectedLeaf) {
        throw "refusing to remove an unowned fresh deployment root: $resolvedRoot"
    }
    if (-not (Test-Path -LiteralPath $resolvedRoot)) {
        return
    }
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        throw "fresh deployment isolation root is not a directory: $resolvedRoot"
    }

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

function Invoke-FreshPowerShell {
    param(
        [Parameter(Mandatory = $true)][string]$Bootstrap,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$LogRoot,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $stdoutPath = Join-Path $LogRoot ($Label + '.stdout.log')
    $stderrPath = Join-Path $LogRoot ($Label + '.stderr.log')
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Assert-FreshTest (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf) 'Windows PowerShell 5.1 is installed'

    $commandArguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $Bootstrap
    ) + $Arguments
    $output = @(& $windowsPowerShell @commandArguments 1> $stdoutPath 2> $stderrPath)
    $exitCode = $LASTEXITCODE
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
        output = $output
    }
}

function Assert-InstalledFile {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )
    $path = Join-Path $Root ($RelativePath.Replace('/', '\'))
    Assert-FreshTest (Test-Path -LiteralPath $path -PathType Leaf) "installed file exists: $RelativePath"
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
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
# Do not append a serialized `-Confirm:$false` token here. Windows PowerShell
# 5.1 treats that native argv token as a String when a script is launched with
# `powershell.exe -File`, then fails to bind it to SwitchParameter. This child
# starts with -NoProfile and the default ConfirmPreference (High), while the
# lifecycle's ConfirmImpact is Medium, so the non-interactive smoke remains
# non-prompting without forwarding the common parameter.
$installed = $false
$uninstalled = $false
$bodySucceeded = $false
$productTaskNames = @('ClusterYourCodex Controller', 'ClusterYourCodex Worker')

try {
    $productTasksBefore = @($productTaskNames | ForEach-Object {
        Get-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue
    })
    Assert-FreshTest ($productTasksBefore.Count -eq 0) 'fresh deployment runner starts without pre-existing product tasks'

    $plan = Invoke-FreshPowerShell -Bootstrap $bootstrap -Arguments ($common + @('-PlanOnly')) -LogRoot $logRoot -Label 'plan'
    Assert-FreshTest ($plan.exitCode -eq 0) 'manifest-bound install plan succeeds'
    $previewManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-FreshTest ([string]$previewManifest.schemaVersion -eq 'cyc.dev/windows-preview/v1') 'preview manifest schema is recognized'
    Assert-FreshTest ([string]$previewManifest.productVersion -match '^[0-9]+\.[0-9]+\.[0-9]+-(preview|alpha|beta|rc)\.[0-9]+$') 'preview manifest carries a strict prerelease product version'
    Assert-FreshTest ([string]$previewManifest.releaseChannel -ceq 'prerelease') 'preview manifest release channel remains prerelease'
    Assert-FreshTest ($null -eq $previewManifest.sourceTag -or [string]$previewManifest.sourceTag -ceq "v$($previewManifest.productVersion)") 'preview manifest source tag is absent or exactly vPRODUCT_VERSION'

    [void](Invoke-FreshPowerShell -Bootstrap $bootstrap -Arguments $common -LogRoot $logRoot -Label 'install')
    $installed = $true
    foreach ($relative in @('ClusterYourCodex.exe', 'cyc-controller.exe', 'cyc-worker.exe', 'cyc.exe', 'installer/bootstrap.ps1')) {
        [void](Assert-InstalledFile -Root $installRoot -RelativePath $relative)
    }
    $installedManifestPath = Join-Path $dataRoot '.installer\install-manifest.json'
    Assert-FreshTest (Test-Path -LiteralPath $installedManifestPath -PathType Leaf) 'install manifest is durable'
    $installedManifest = Get-Content -LiteralPath $installedManifestPath -Raw | ConvertFrom-Json
    Assert-FreshTest ([string]$installedManifest.schemaVersion -eq 'cyc.dev/windows-install-manifest/v1') 'installed manifest schema is recognized'
    Assert-FreshTest ([string]$installedManifest.productVersion -ceq [string]$previewManifest.productVersion) 'installed manifest preserves the package product version'
    Assert-FreshTest ([string]$installedManifest.installRoot -eq $installRoot) 'manifest binds the isolated install root'
    Assert-FreshTest ([string]$installedManifest.dataRoot -eq $dataRoot) 'manifest binds the isolated data root'
    Assert-FreshTest (-not [bool]$installedManifest.managedWorker.enabled) 'managed worker is disabled for isolated smoke'
    $installedControllerTasks = @(Get-ScheduledTask -TaskName 'ClusterYourCodex Controller' -ErrorAction SilentlyContinue)
    $installedWorkerTasks = @(Get-ScheduledTask -TaskName 'ClusterYourCodex Worker' -ErrorAction SilentlyContinue)
    Assert-FreshTest ($installedControllerTasks.Count -eq 1) 'install registers exactly one controller task'
    Assert-FreshTest ($installedWorkerTasks.Count -eq 0) 'disabled managed worker does not leave a worker task'
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
    $installedCliSha256 = (Get-FileHash -LiteralPath $installedCliPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $installedCliBytes = [System.IO.File]::ReadAllBytes($installedCliPath)
    Assert-FreshTest ($installedCliBytes.Length -gt 4096) 'installed CLI is large enough for a deterministic repair mutation'
    Wait-FreshFileUnlocked -Path $installedCliPath
    $mutationOffset = $installedCliBytes.Length - 1
    $installedCliBytes[$mutationOffset] = $installedCliBytes[$mutationOffset] -bxor 0xff
    [System.IO.File]::WriteAllBytes($installedCliPath, $installedCliBytes)
    $mutatedCliSha256 = (Get-FileHash -LiteralPath $installedCliPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-FreshTest ($mutatedCliSha256 -cne $installedCliSha256) 'repair precondition corrupts the installed CLI'

    $repairArguments = @($common)
    $repairArguments[1] = 'Repair'
    [void](Invoke-FreshPowerShell -Bootstrap $bootstrap -Arguments $repairArguments -LogRoot $logRoot -Label 'repair')
    $repairedManifest = Get-Content -LiteralPath $installedManifestPath -Raw | ConvertFrom-Json
    Assert-FreshTest ([string]$repairedManifest.schemaVersion -eq 'cyc.dev/windows-install-manifest/v1') 'repair keeps a valid manifest'
    $repairedCliSha256 = (Get-FileHash -LiteralPath $installedCliPath -Algorithm SHA256).Hash.ToLowerInvariant()
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
    [void](Invoke-FreshPowerShell -Bootstrap $bootstrap -Arguments $uninstallArguments -LogRoot $logRoot -Label 'uninstall')
    $uninstalled = $true
    Assert-FreshTest (-not (Test-Path -LiteralPath $installRoot)) 'uninstall removes the isolated install root'
    Assert-FreshTest (Test-Path -LiteralPath $dataRoot -PathType Container) 'uninstall preserves the isolated data root by default'
    Assert-FreshTest (-not (Test-Path -LiteralPath $installedManifestPath)) 'uninstall removes the install manifest while preserving product data'

    $productTasksAfter = @($productTaskNames | ForEach-Object {
        Get-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue
    })
    Assert-FreshTest ($productTasksAfter.Count -eq 0) 'uninstall restores the clean product task state'

    $bodySucceeded = $true
    [PSCustomObject]@{
        schemaVersion = 'cyc.dev/fresh-deployment-test/v1'
        status = 'passed'
        packageRoot = $package
        installRoot = $installRoot
        dataRoot = $dataRoot
        steps = @('plan', 'install', 'controller-version', 'worker-probe', 'cli-help', 'repair-corrupted-cli', 'uninstall')
        logs = $logRoot
    } | ConvertTo-Json -Depth 6
} finally {
    $postTestCleanupFailures = New-Object System.Collections.Generic.List[string]
    if ($installed -and -not $uninstalled) {
        try {
            $cleanupArguments = @(
                '-Action', 'Uninstall',
                '-InstallRoot', $installRoot,
                '-DataRoot', $dataRoot,
                '-DisableManagedWorkerListener',
                '-SkipFirewall',
                '-SkipCodexIntegration',
                '-SkipUninstallRegistration'
            )
            [void](Invoke-FreshPowerShell -Bootstrap $bootstrap -Arguments $cleanupArguments -LogRoot $logRoot -Label 'cleanup')
        } catch {
            Write-Warning "fresh deployment cleanup failed: $($_.Exception.Message)"
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
    try {
        Remove-FreshOwnedIsolationRoot -Root $isolatedRoot -Suffix $suffix
    } catch {
        $message = "owned-root cleanup failed: $($_.Exception.Message)"
        if ($bodySucceeded) { [void]$postTestCleanupFailures.Add($message) } else { Write-Warning $message }
    }
    if ($bodySucceeded -and $postTestCleanupFailures.Count -gt 0) {
        throw "fresh deployment post-test cleanup failed: $($postTestCleanupFailures -join '; ')"
    }
}
