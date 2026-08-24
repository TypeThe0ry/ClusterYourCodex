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

$package = Resolve-FreshPath $PackageRoot
$work = Resolve-FreshPath $WorkRoot
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
$controllerTaskBefore = @(Get-ScheduledTask -TaskName 'ClusterYourCodex Controller' -ErrorAction SilentlyContinue | ForEach-Object {
    $_ | Export-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath
})

try {
    $plan = Invoke-FreshPowerShell -Bootstrap $bootstrap -Arguments ($common + @('-PlanOnly')) -LogRoot $logRoot -Label 'plan'
    Assert-FreshTest ($plan.exitCode -eq 0) 'manifest-bound install plan succeeds'
    $previewManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-FreshTest ([string]$previewManifest.schemaVersion -eq 'cyc.dev/windows-preview/v1') 'preview manifest schema is recognized'

    [void](Invoke-FreshPowerShell -Bootstrap $bootstrap -Arguments $common -LogRoot $logRoot -Label 'install')
    $installed = $true
    foreach ($relative in @('ClusterYourCodex.exe', 'cyc-controller.exe', 'cyc-worker.exe', 'cyc.exe', 'installer/bootstrap.ps1')) {
        [void](Assert-InstalledFile -Root $installRoot -RelativePath $relative)
    }
    $installedManifestPath = Join-Path $dataRoot '.installer\install-manifest.json'
    Assert-FreshTest (Test-Path -LiteralPath $installedManifestPath -PathType Leaf) 'install manifest is durable'
    $installedManifest = Get-Content -LiteralPath $installedManifestPath -Raw | ConvertFrom-Json
    Assert-FreshTest ([string]$installedManifest.schemaVersion -eq 'cyc.dev/windows-install-manifest/v1') 'installed manifest schema is recognized'
    Assert-FreshTest ([string]$installedManifest.installRoot -eq $installRoot) 'manifest binds the isolated install root'
    Assert-FreshTest ([string]$installedManifest.dataRoot -eq $dataRoot) 'manifest binds the isolated data root'
    Assert-FreshTest (-not [bool]$installedManifest.managedWorker.enabled) 'managed worker is disabled for isolated smoke'

    & (Join-Path $installRoot 'cyc-controller.exe') '--version' *> (Join-Path $logRoot 'controller-version.log')
    Assert-FreshTest ($LASTEXITCODE -eq 0) 'installed controller --version succeeds'
    & (Join-Path $installRoot 'cyc-worker.exe') 'probe' '--workspace' $work '--pretty' *> (Join-Path $logRoot 'worker-probe.log')
    Assert-FreshTest ($LASTEXITCODE -eq 0) 'installed worker probe succeeds'
    & (Join-Path $installRoot 'cyc.exe') '--help' *> (Join-Path $logRoot 'cli-help.log')
    Assert-FreshTest ($LASTEXITCODE -eq 0) 'installed CLI --help succeeds'

    $repairArguments = @($common)
    $repairArguments[1] = 'Repair'
    [void](Invoke-FreshPowerShell -Bootstrap $bootstrap -Arguments $repairArguments -LogRoot $logRoot -Label 'repair')
    $repairedManifest = Get-Content -LiteralPath $installedManifestPath -Raw | ConvertFrom-Json
    Assert-FreshTest ([string]$repairedManifest.schemaVersion -eq 'cyc.dev/windows-install-manifest/v1') 'repair keeps a valid manifest'

    $uninstallArguments = @(
        '-Action', 'Uninstall',
        '-InstallRoot', $installRoot,
        '-DataRoot', $dataRoot,
        '-DisableManagedWorkerListener',
        '-SkipFirewall',
        '-SkipCodexIntegration',
        '-SkipUninstallRegistration',
        '-PurgeData'
    )
    [void](Invoke-FreshPowerShell -Bootstrap $bootstrap -Arguments $uninstallArguments -LogRoot $logRoot -Label 'uninstall')
    $uninstalled = $true
    Assert-FreshTest (-not (Test-Path -LiteralPath $installRoot)) 'uninstall removes the isolated install root'
    Assert-FreshTest (-not (Test-Path -LiteralPath $dataRoot)) 'purging uninstall removes the isolated data root'

    $controllerTaskAfter = @(Get-ScheduledTask -TaskName 'ClusterYourCodex Controller' -ErrorAction SilentlyContinue | ForEach-Object {
        $_ | Export-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath
    })
    Assert-FreshTest (($controllerTaskBefore -join "`n") -ceq ($controllerTaskAfter -join "`n")) 'uninstall restores the controller task state'

    [PSCustomObject]@{
        schemaVersion = 'cyc.dev/fresh-deployment-test/v1'
        status = 'passed'
        packageRoot = $package
        installRoot = $installRoot
        dataRoot = $dataRoot
        steps = @('plan', 'install', 'controller-version', 'worker-probe', 'cli-help', 'repair', 'uninstall')
        logs = $logRoot
    } | ConvertTo-Json -Depth 6
} finally {
    if ($installed -and -not $uninstalled) {
        try {
            $cleanupArguments = @(
                '-Action', 'Uninstall',
                '-InstallRoot', $installRoot,
                '-DataRoot', $dataRoot,
                '-DisableManagedWorkerListener',
                '-SkipFirewall',
                '-SkipCodexIntegration',
                '-SkipUninstallRegistration',
                '-PurgeData'
            )
            [void](Invoke-FreshPowerShell -Bootstrap $bootstrap -Arguments $cleanupArguments -LogRoot $logRoot -Label 'cleanup')
        } catch {
            Write-Warning "fresh deployment cleanup failed: $($_.Exception.Message)"
        }
    }
    if (-not $KeepWorkRoot -and (Test-Path -LiteralPath $work)) {
        $resolvedWork = Resolve-FreshPath $work
        $tempRoot = Resolve-FreshPath ([System.IO.Path]::GetTempPath())
        if ($resolvedWork.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedWork -Recurse -Force
        } else {
            Write-Warning "preserving work root outside the temp directory: $resolvedWork"
        }
    }
    if (Test-Path -LiteralPath $isolatedRoot -PathType Container) {
        $remaining = @(Get-ChildItem -LiteralPath $isolatedRoot -Force -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) {
            Remove-Item -LiteralPath $isolatedRoot -Force
        } else {
            Write-Warning "preserving non-empty isolated root after cleanup: $isolatedRoot"
        }
    }
}
