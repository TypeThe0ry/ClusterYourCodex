#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Install', 'Repair', 'Uninstall')]
    [string]$Action = 'Install',

    [string]$BundleRoot = (Join-Path $PSScriptRoot 'payload'),

    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\ClusterYourCodex'),

    [string]$DataRoot = (Join-Path $env:LOCALAPPDATA 'ClusterYourCodex'),

    [switch]$EnableWorker,

    [string]$WorkerConfig = (Join-Path $env:LOCALAPPDATA 'ClusterYourCodex\worker\config.json'),

    [switch]$SkipCodexIntegration,

    [switch]$PurgeData,

    [switch]$PlanOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ManifestSchema = 'cyc.dev/windows-install-manifest/v1'
$script:ControllerTaskName = 'ClusterYourCodex Controller'
$script:WorkerTaskName = 'ClusterYourCodex Worker'
$script:RequiredExecutables = @('ClusterYourCodex.exe', 'cyc-controller.exe', 'cyc.exe')

function Resolve-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
}

function Assert-ChildPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Candidate,
        [switch]$AllowRoot
    )
    $rootPath = Resolve-NormalizedPath $Root
    $candidatePath = Resolve-NormalizedPath $Candidate
    if ($AllowRoot -and [string]::Equals($rootPath, $candidatePath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $candidatePath
    }
    $prefix = $rootPath + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidatePath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes the owned root: $candidatePath"
    }
    return $candidatePath
}

function Get-RelativeOwnedPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $rootPath = Resolve-NormalizedPath $Root
    $pathValue = Assert-ChildPath -Root $rootPath -Candidate $Path
    return $pathValue.Substring($rootPath.Length + 1).Replace('\', '/')
}

function Test-ReparsePoint {
    param([Parameter(Mandatory = $true)][System.IO.FileSystemInfo]$Item)
    return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-PayloadFiles {
    param([Parameter(Mandatory = $true)][string]$Root)
    $bundle = Resolve-NormalizedPath $Root
    if (-not (Test-Path -LiteralPath $bundle -PathType Container)) {
        throw "Bundle payload directory does not exist: $bundle"
    }
    $rootItem = Get-Item -LiteralPath $bundle -Force
    if (Test-ReparsePoint $rootItem) {
        throw 'Bundle payload root must not be a reparse point.'
    }
    foreach ($item in Get-ChildItem -LiteralPath $bundle -Recurse -Force) {
        if (Test-ReparsePoint $item) {
            throw "Bundle payload contains a reparse point: $($item.FullName)"
        }
        if (-not $item.PSIsContainer) {
            $item
        }
    }
}

function Get-InstallPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [switch]$EnableWorker,
        [string]$WorkerConfig,
        [switch]$SkipCodexIntegration
    )
    $bundle = Resolve-NormalizedPath $BundleRoot
    $install = Resolve-NormalizedPath $InstallRoot
    $data = Resolve-NormalizedPath $DataRoot
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA is required for the current-user Windows install.'
    }
    $localAppData = Resolve-NormalizedPath $env:LOCALAPPDATA
    [void](Assert-ChildPath -Root $localAppData -Candidate $install)
    [void](Assert-ChildPath -Root $localAppData -Candidate $data)
    if ([string]::Equals($install, $data, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'InstallRoot and DataRoot must be different directories.'
    }
    $separator = [System.IO.Path]::DirectorySeparatorChar
    if ($install.StartsWith($data + $separator, [System.StringComparison]::OrdinalIgnoreCase) -or
        $data.StartsWith($install + $separator, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'InstallRoot and DataRoot must not contain one another.'
    }
    $files = @()
    foreach ($source in Get-PayloadFiles -Root $bundle) {
        $relative = Get-RelativeOwnedPath -Root $bundle -Path $source.FullName
        $target = Assert-ChildPath -Root $install -Candidate (Join-Path $install $relative)
        $files += [PSCustomObject]@{
            relativePath = $relative
            sourcePath = $source.FullName
            targetPath = $target
            sha256 = (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            length = [long]$source.Length
        }
    }
    foreach ($required in $script:RequiredExecutables) {
        if (-not ($files.relativePath -contains $required)) {
            throw "Bundle payload is missing required executable: $required"
        }
    }
    if ($EnableWorker -and -not ($files.relativePath -contains 'cyc-worker.exe')) {
        throw 'EnableWorker requires cyc-worker.exe in the bundle payload.'
    }
    $marketplaceManifestRelative = 'integrations/codex-marketplace/.agents/plugins/marketplace.json'
    $pluginPrefix = 'integrations/codex-marketplace/plugins/cluster-your-codex/'
    $hasMarketplaceManifest = $files.relativePath -contains $marketplaceManifestRelative
    $hasPluginFiles = @($files | Where-Object { $_.relativePath.StartsWith($pluginPrefix, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
    if ($hasMarketplaceManifest -xor $hasPluginFiles) {
        throw 'Codex integration payload must contain both marketplace.json and the complete cluster-your-codex plugin.'
    }
    $requiredPluginFiles = @(
        ($pluginPrefix + '.codex-plugin/plugin.json'),
        ($pluginPrefix + '.mcp.json'),
        ($pluginPrefix + 'skills/cluster-your-codex/SKILL.md'),
        ($pluginPrefix + 'mcp/dist/server.js'),
        ($pluginPrefix + 'mcp/runtime/node.exe'),
        ($pluginPrefix + 'mcp/runtime/LICENSE.node.txt')
    )
    if ($hasMarketplaceManifest) {
        foreach ($requiredPluginFile in $requiredPluginFiles) {
            if (-not ($files.relativePath -contains $requiredPluginFile)) {
                throw "Codex integration payload is incomplete: $requiredPluginFile"
            }
        }
    }
    $hasCodexMarketplace = $hasMarketplaceManifest -and $hasPluginFiles
    $workerConfigPath = if ([string]::IsNullOrWhiteSpace($WorkerConfig)) {
        Join-Path $data 'worker\config.json'
    } else {
        Resolve-NormalizedPath $WorkerConfig
    }
    [void](Assert-ChildPath -Root $data -Candidate $workerConfigPath)
    foreach ($argumentPath in @($install, $data, $workerConfigPath)) {
        if ($argumentPath.Contains('"') -or $argumentPath.Contains("`r") -or $argumentPath.Contains("`n")) {
            throw 'Install and configuration paths must not contain quotes or line breaks.'
        }
    }
    $controllerDatabase = Join-Path $data 'controller.db'
    $controllerTokenFile = Join-Path $data 'controller.token'
    $controllerAction = [PSCustomObject]@{
        executable = Join-Path $install 'cyc-controller.exe'
        arguments = '--bind 127.0.0.1:47831 --database "' + $controllerDatabase + '" --token-file "' + $controllerTokenFile + '"'
        workingDirectory = $install
    }
    $workerAction = if ($EnableWorker) {
        [PSCustomObject]@{
            executable = Join-Path $install 'cyc-worker.exe'
            arguments = 'run --config "' + $workerConfigPath.Replace('"', '""') + '"'
            workingDirectory = $install
        }
    } else { $null }
    $marketplaceRoot = Join-Path $install 'integrations\codex-marketplace'
    [PSCustomObject]@{
        schemaVersion = $script:ManifestSchema
        action = 'InstallOrRepair'
        installRoot = $install
        dataRoot = $data
        manifestPath = Join-Path $data '.installer\install-manifest.json'
        files = $files
        tasks = @(
            [PSCustomObject]@{ name = $script:ControllerTaskName; action = $controllerAction; enabled = $true },
            [PSCustomObject]@{ name = $script:WorkerTaskName; action = $workerAction; enabled = [bool]$EnableWorker }
        )
        workerConfig = $workerConfigPath
        codexIntegration = [PSCustomObject]@{
            enabled = (-not [bool]$SkipCodexIntegration) -and $hasCodexMarketplace
            available = $hasCodexMarketplace
            marketplaceRoot = $marketplaceRoot
            marketplaceManifest = Join-Path $marketplaceRoot '.agents\plugins\marketplace.json'
            plugin = 'cluster-your-codex@clusteryourcodex'
        }
    }
}

function New-PrivateFileSystemAcl {
    param([Parameter(Mandatory = $true)][bool]$Directory)
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $sid = $identity.User.Value
    $systemSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    $userSid = New-Object System.Security.Principal.SecurityIdentifier($sid)
    $rights = [System.Security.AccessControl.FileSystemRights]::FullControl
    $inheritance = if ($Directory) {
        [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    } else {
        [System.Security.AccessControl.InheritanceFlags]::None
    }
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $privateAcl = if ($Directory) {
        New-Object System.Security.AccessControl.DirectorySecurity
    } else {
        New-Object System.Security.AccessControl.FileSecurity
    }
    $privateAcl.SetAccessRuleProtection($true, $false)
    $privateAcl.SetOwner($userSid)
    [void]$privateAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        $userSid, $rights, $inheritance, $propagation, $allow
    )))
    [void]$privateAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        $systemSid, $rights, $inheritance, $propagation, $allow
    )))
    return $privateAcl
}

function Get-FileSystemAclPortable {
    param([Parameter(Mandatory = $true)][System.IO.FileSystemInfo]$Item)
    if ($null -ne $Item.PSObject.Methods['GetAccessControl']) {
        return $Item.GetAccessControl()
    }
    if ($Item.PSIsContainer) {
        return [System.IO.FileSystemAclExtensions]::GetAccessControl(
            [System.IO.DirectoryInfo]$Item
        )
    }
    return [System.IO.FileSystemAclExtensions]::GetAccessControl(
        [System.IO.FileInfo]$Item
    )
}

function Set-FileSystemAclPortable {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileSystemInfo]$Item,
        [Parameter(Mandatory = $true)][System.Security.AccessControl.FileSystemSecurity]$Acl
    )
    if ($null -ne $Item.PSObject.Methods['SetAccessControl']) {
        $Item.SetAccessControl($Acl)
        return
    }
    if ($Item.PSIsContainer) {
        [System.IO.FileSystemAclExtensions]::SetAccessControl(
            [System.IO.DirectoryInfo]$Item,
            [System.Security.AccessControl.DirectorySecurity]$Acl
        )
        return
    }
    [System.IO.FileSystemAclExtensions]::SetAccessControl(
        [System.IO.FileInfo]$Item,
        [System.Security.AccessControl.FileSecurity]$Acl
    )
}

function Assert-PrivatePathAcl {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    if (Test-ReparsePoint $item) {
        throw "Owned ACL path must not be a reparse point: $($item.FullName)"
    }
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $userSid = $identity.User.Value
    $expected = @{}
    $expected[$userSid] = $false
    $expected['S-1-5-18'] = $false
    $acl = Get-FileSystemAclPortable -Item $item
    if (-not $acl.AreAccessRulesProtected) {
        throw "ACL inheritance remains enabled on $($item.FullName)"
    }
    $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    if ($owner -ne $userSid) {
        throw "Unexpected ACL owner on $($item.FullName)"
    }
    $rules = @($acl.GetAccessRules(
        $true,
        $true,
        [System.Security.Principal.SecurityIdentifier]
    ))
    if ($rules.Count -ne 2) {
        throw "Unexpected ACE count on $($item.FullName)"
    }
    $requiredInheritance = if ($item.PSIsContainer) {
        [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    } else {
        [System.Security.AccessControl.InheritanceFlags]::None
    }
    foreach ($rule in $rules) {
        $ruleSid = $rule.IdentityReference.Value
        if (-not $expected.ContainsKey($ruleSid) -or $expected[$ruleSid]) {
            throw "Unexpected or duplicate principal on $($item.FullName)"
        }
        if ($rule.IsInherited -or
            $rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or
            $rule.InheritanceFlags -ne $requiredInheritance -or
            $rule.PropagationFlags -ne [System.Security.AccessControl.PropagationFlags]::None -or
            (($rule.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -ne
             [System.Security.AccessControl.FileSystemRights]::FullControl)) {
            throw "Unexpected access rule on $($item.FullName)"
        }
        $expected[$ruleSid] = $true
    }
    if ($expected.Values -contains $false) {
        throw "Required principal is missing from $($item.FullName)"
    }
}

function Set-PrivatePathAcl {
    param([Parameter(Mandatory = $true)][System.IO.FileSystemInfo]$Item)
    if (Test-ReparsePoint $Item) {
        throw "Owned ACL path must not be a reparse point: $($Item.FullName)"
    }
    $replacement = New-PrivateFileSystemAcl -Directory ([bool]$Item.PSIsContainer)
    Set-FileSystemAclPortable -Item $Item -Acl $replacement
    Assert-PrivatePathAcl -Path $Item.FullName
}

function Set-PrivateDirectoryAcl {
    param([Parameter(Mandatory = $true)][string]$Path)
    $directory = Resolve-NormalizedPath $Path
    [void](New-Item -ItemType Directory -Path $directory -Force)
    $root = Get-Item -LiteralPath $directory -Force
    if (-not $root.PSIsContainer) { throw "Private ACL root is not a directory: $directory" }
    Set-PrivatePathAcl -Item $root

    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($directory)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        foreach ($child in @(Get-ChildItem -LiteralPath $current -Force)) {
            Set-PrivatePathAcl -Item $child
            if ($child.PSIsContainer) { $pending.Push($child.FullName) }
        }
    }
}

function Read-InstallManifest {
    param([Parameter(Mandatory = $true)][string]$ManifestPath)
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { return $null }
    $item = Get-Item -LiteralPath $ManifestPath -Force
    if ($item.Length -gt 2MB) { throw 'Install manifest is unexpectedly large.' }
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    if ($manifest.schemaVersion -ne $script:ManifestSchema) {
        throw 'Unsupported install manifest schema.'
    }
    return $manifest
}

function Remove-OwnedFiles {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$ExpectedInstallRoot,
        [string[]]$KeepRelativePaths = @()
    )
    $root = Resolve-NormalizedPath $ExpectedInstallRoot
    if (-not [string]::Equals((Resolve-NormalizedPath $Manifest.installRoot), $root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Manifest install root does not match the requested install root.'
    }
    foreach ($file in @($Manifest.files)) {
        $relative = [string]$file.relativePath
        if ($KeepRelativePaths -contains $relative) { continue }
        $target = Assert-ChildPath -Root $root -Candidate (Join-Path $root $relative)
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            Remove-Item -LiteralPath $target -Force
        }
    }
    if (Test-Path -LiteralPath $root -PathType Container) {
        $directories = @(Get-ChildItem -LiteralPath $root -Directory -Recurse -Force | Sort-Object FullName -Descending)
        foreach ($directory in $directories) {
            if (-not (Get-ChildItem -LiteralPath $directory.FullName -Force | Select-Object -First 1)) {
                Remove-Item -LiteralPath $directory.FullName -Force
            }
        }
        if (-not (Get-ChildItem -LiteralPath $root -Force | Select-Object -First 1)) {
            Remove-Item -LiteralPath $root -Force
        }
    }
}

function Install-PlannedFiles {
    param([Parameter(Mandatory = $true)]$Plan)
    foreach ($file in $Plan.files) {
        $currentHash = (Get-FileHash -LiteralPath $file.sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($currentHash -ne $file.sha256) {
            throw "Bundle payload changed after planning: $($file.relativePath)"
        }
        $parent = Split-Path -Parent $file.targetPath
        [void](New-Item -ItemType Directory -Path $parent -Force)
        $temporary = $file.targetPath + '.cyc-install-' + [Guid]::NewGuid().ToString('N')
        try {
            Copy-Item -LiteralPath $file.sourcePath -Destination $temporary -Force
            $copiedHash = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($copiedHash -ne $file.sha256) {
                throw "Copied payload failed integrity verification: $($file.relativePath)"
            }
            Move-Item -LiteralPath $temporary -Destination $file.targetPath -Force
        } finally {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        }
    }
}

function Register-CycTask {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Action
    )
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $taskAction = New-ScheduledTaskAction `
        -Execute $Action.executable `
        -Argument $Action.arguments `
        -WorkingDirectory $Action.workingDirectory
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
    $principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet `
        -MultipleInstances IgnoreNew `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask `
        -TaskName $Name `
        -Action $taskAction `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description 'ClusterYourCodex per-user background component' `
        -Force | Out-Null
}

function Unregister-CycTask {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $Name -Confirm:$false
    }
}

function Get-CycTaskSnapshots {
    $snapshots = @()
    foreach ($name in @($script:ControllerTaskName, $script:WorkerTaskName)) {
        $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if ($task) {
            $snapshots += [PSCustomObject]@{
                name = $name
                xml = Export-ScheduledTask -TaskName $name
                wasRunning = ([string]$task.State -eq 'Running')
            }
        }
    }
    return $snapshots
}

function Stop-CycRuntime {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)
    foreach ($name in @($script:WorkerTaskName, $script:ControllerTaskName)) {
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        }
    }
    $root = Resolve-NormalizedPath $InstallRoot
    $ownedExecutables = @(
        (Join-Path $root 'ClusterYourCodex.exe'),
        (Join-Path $root 'cyc-controller.exe'),
        (Join-Path $root 'cyc-worker.exe')
    )
    foreach ($process in Get-Process -Name @('ClusterYourCodex', 'cyc-controller', 'cyc-worker') -ErrorAction SilentlyContinue) {
        $processPath = $null
        try { $processPath = $process.Path } catch { $processPath = $null }
        if ($processPath -and ($ownedExecutables -contains (Resolve-NormalizedPath $processPath))) {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
            Wait-Process -Id $process.Id -Timeout 15 -ErrorAction SilentlyContinue
        }
    }
}

function Restore-CycTaskSnapshots {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Snapshots)
    foreach ($name in @($script:WorkerTaskName, $script:ControllerTaskName)) {
        Unregister-CycTask -Name $name
    }
    foreach ($snapshot in $Snapshots) {
        Register-ScheduledTask -TaskName $snapshot.name -Xml $snapshot.xml -Force | Out-Null
        if ($snapshot.wasRunning) {
            Start-ScheduledTask -TaskName $snapshot.name
        }
    }
}

function Wait-CycTaskStable {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$TimeoutSeconds = 15,
        [double]$StableSeconds = 3
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $runningSince = $null
    do {
        $task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
        if ($task -and [string]$task.State -eq 'Running') {
            if (-not $runningSince) { $runningSince = [DateTime]::UtcNow }
            if (([DateTime]::UtcNow - $runningSince).TotalSeconds -ge $StableSeconds) {
                $taskInfo = Get-ScheduledTaskInfo -TaskName $Name -ErrorAction Stop
                $lastResult = [long]$taskInfo.LastTaskResult
                if ($lastResult -notin @(0, 267009)) {
                    throw "Scheduled Task reported failure while running: $Name (result=$lastResult)"
                }
                return
            }
        } else {
            $runningSince = $null
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Scheduled Task did not remain healthy for $StableSeconds seconds: $Name"
}

function Test-CycWorkerStatus {
    param(
        [Parameter(Mandatory = $true)]$Action,
        [Parameter(Mandatory = $true)][string]$Config
    )
    try {
        $lines = @(& $Action.executable status --config $Config 2>$null)
        $exitCode = $LASTEXITCODE
    } catch {
        throw 'cyc-worker status failed during readiness verification.'
    }
    if ($exitCode -ne 0) {
        throw "cyc-worker status failed during readiness verification (exit=$exitCode)."
    }
    $raw = [string]::Join([Environment]::NewLine, @($lines | ForEach-Object { [string]$_ }))
    if ([string]::IsNullOrWhiteSpace($raw) -or $raw.Length -gt 1MB) {
        throw 'cyc-worker status returned an invalid response.'
    }
    try { $status = $raw | ConvertFrom-Json } catch { throw 'cyc-worker status returned invalid JSON.' }
    if (-not $status.paired -or -not $status.credentialProtected) {
        throw 'cyc-worker status did not confirm paired, protected state.'
    }
}

function Wait-CycControllerReady {
    param([int]$TimeoutSeconds = 15)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            $response = Invoke-RestMethod `
                -Uri 'http://127.0.0.1:47831/v1/health' `
                -Method Get `
                -TimeoutSec 1 `
                -UseBasicParsing
            if ($response.status -eq 'ok' -and $response.apiVersion) { return }
        } catch {
            # Controller startup is bounded and retried below without logging response data.
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Controller failed the loopback health check.'
}

function New-FileRollbackSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        $OldManifest
    )
    $transactionsRoot = Join-Path $Plan.dataRoot '.installer\transactions'
    $transactionRoot = Join-Path $transactionsRoot ([Guid]::NewGuid().ToString('N'))
    [void](Assert-ChildPath -Root $transactionsRoot -Candidate $transactionRoot)
    [void](New-Item -ItemType Directory -Path $transactionRoot -Force)
    $relativePaths = @($Plan.files.relativePath)
    if ($OldManifest) { $relativePaths += @($OldManifest.files | ForEach-Object { [string]$_.relativePath }) }
    $relativePaths = @($relativePaths | Sort-Object -Unique)
    $records = @()
    foreach ($relative in $relativePaths) {
        $target = Assert-ChildPath -Root $Plan.installRoot -Candidate (Join-Path $Plan.installRoot $relative)
        $backup = Assert-ChildPath -Root $transactionRoot -Candidate (Join-Path $transactionRoot (Join-Path 'files' $relative))
        $existed = Test-Path -LiteralPath $target -PathType Leaf
        if ((Test-Path -LiteralPath $target) -and -not $existed) {
            throw "Owned file path is not a regular file: $target"
        }
        if ($existed) {
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force)
            Copy-Item -LiteralPath $target -Destination $backup -Force
        }
        $records += [PSCustomObject]@{
            targetPath = $target
            backupPath = $backup
            existed = [bool]$existed
        }
    }
    $manifestBackup = Join-Path $transactionRoot 'install-manifest.json'
    $manifestExisted = Test-Path -LiteralPath $Plan.manifestPath -PathType Leaf
    if ($manifestExisted) {
        Copy-Item -LiteralPath $Plan.manifestPath -Destination $manifestBackup -Force
    }
    return [PSCustomObject]@{
        root = $transactionRoot
        transactionsRoot = $transactionsRoot
        files = $records
        manifestPath = $Plan.manifestPath
        manifestBackup = $manifestBackup
        manifestExisted = [bool]$manifestExisted
    }
}

function Restore-FileRollbackSnapshot {
    param([Parameter(Mandatory = $true)]$Snapshot)
    foreach ($record in $Snapshot.files) {
        if ($record.existed) {
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $record.targetPath) -Force)
            $temporary = $record.targetPath + '.cyc-rollback-' + [Guid]::NewGuid().ToString('N')
            Copy-Item -LiteralPath $record.backupPath -Destination $temporary -Force
            Move-Item -LiteralPath $temporary -Destination $record.targetPath -Force
        } elseif (Test-Path -LiteralPath $record.targetPath -PathType Leaf) {
            Remove-Item -LiteralPath $record.targetPath -Force
        }
    }
    if ($Snapshot.manifestExisted) {
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $Snapshot.manifestPath) -Force)
        Copy-Item -LiteralPath $Snapshot.manifestBackup -Destination $Snapshot.manifestPath -Force
    } elseif (Test-Path -LiteralPath $Snapshot.manifestPath -PathType Leaf) {
        Remove-Item -LiteralPath $Snapshot.manifestPath -Force
    }
}

function Remove-FileRollbackSnapshot {
    param([Parameter(Mandatory = $true)]$Snapshot)
    $target = Assert-ChildPath -Root $Snapshot.transactionsRoot -Candidate $Snapshot.root
    if (Test-Path -LiteralPath $target -PathType Container) {
        # Exact transaction target was proven beneath the installer-owned root.
        Remove-Item -LiteralPath $target -Recurse -Force
    }
    if ((Test-Path -LiteralPath $Snapshot.transactionsRoot -PathType Container) -and
        -not (Get-ChildItem -LiteralPath $Snapshot.transactionsRoot -Force | Select-Object -First 1)) {
        Remove-Item -LiteralPath $Snapshot.transactionsRoot -Force
    }
}

function Invoke-CodexIntegration {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [ValidateSet('Install', 'Uninstall')][string]$Operation,
        [scriptblock]$CleanupCheckpoint
    )
    if (-not $Plan.codexIntegration.enabled) {
        return [PSCustomObject]@{
            operation = $Operation
            required = $false
            attempted = $false
            cliFound = $false
            succeeded = ($Operation -eq 'Uninstall')
            marketplaceAdded = $false
            pluginAdded = $false
            pluginRemoved = $false
            marketplaceRemoved = $false
            pluginExitCode = $null
            marketplaceExitCode = $null
        }
    }

    $previousCleanup = $null
    if ($Operation -eq 'Uninstall' -and $Plan.codexIntegration.PSObject.Properties['cleanup']) {
        $previousCleanup = $Plan.codexIntegration.cleanup
    }
    $pluginRemoved = [bool]($previousCleanup -and
        $previousCleanup.PSObject.Properties['pluginRemoved'] -and
        $previousCleanup.pluginRemoved)
    $marketplaceRemoved = [bool]($previousCleanup -and
        $previousCleanup.PSObject.Properties['marketplaceRemoved'] -and
        $previousCleanup.marketplaceRemoved)
    if ($Operation -eq 'Uninstall' -and $pluginRemoved -and $marketplaceRemoved) {
        return [PSCustomObject]@{
            operation = $Operation
            required = $true
            attempted = $false
            cliFound = $false
            succeeded = $true
            marketplaceAdded = $false
            pluginAdded = $false
            pluginRemoved = $true
            marketplaceRemoved = $true
            pluginExitCode = $null
            marketplaceExitCode = $null
        }
    }
    if ($Operation -eq 'Uninstall' -and -not $CleanupCheckpoint) {
        throw 'Codex integration cleanup requires a durable manifest checkpoint callback.'
    }
    $codex = Get-Command codex -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $codex) {
        return [PSCustomObject]@{
            operation = $Operation
            required = $true
            attempted = $false
            cliFound = $false
            succeeded = $false
            marketplaceAdded = $false
            pluginAdded = $false
            pluginRemoved = $pluginRemoved
            marketplaceRemoved = $marketplaceRemoved
            pluginExitCode = $null
            marketplaceExitCode = $null
        }
    }

    $pluginExitCode = $null
    $marketplaceExitCode = $null
    $marketplaceAdded = $false
    $pluginAdded = $false
    if ($Operation -eq 'Install') {
        if (-not (Test-Path -LiteralPath $Plan.codexIntegration.marketplaceManifest -PathType Leaf)) {
            return [PSCustomObject]@{
                operation = $Operation
                required = $true
                attempted = $false
                cliFound = $true
                succeeded = $false
                marketplaceAdded = $false
                pluginAdded = $false
                pluginRemoved = $false
                marketplaceRemoved = $false
                pluginExitCode = $null
                marketplaceExitCode = $null
            }
        }
        try {
            & $codex.Source plugin marketplace add $Plan.codexIntegration.marketplaceRoot *> $null
            $marketplaceExitCode = $LASTEXITCODE
            $marketplaceAdded = ($marketplaceExitCode -eq 0)
        } catch {
            $marketplaceExitCode = -1
        }
        if ($marketplaceAdded) {
            try {
            & $codex.Source plugin add $Plan.codexIntegration.plugin *> $null
                $pluginExitCode = $LASTEXITCODE
                $pluginAdded = ($pluginExitCode -eq 0)
            } catch {
                $pluginExitCode = -1
            }
        }
        return [PSCustomObject]@{
            operation = $Operation
            required = $true
            attempted = $true
            cliFound = $true
            succeeded = ($marketplaceAdded -and $pluginAdded)
            marketplaceAdded = $marketplaceAdded
            pluginAdded = $pluginAdded
            pluginRemoved = $false
            marketplaceRemoved = $false
            pluginExitCode = $pluginExitCode
            marketplaceExitCode = $marketplaceExitCode
        }
    }

    if (-not $pluginRemoved) {
        try {
            & $codex.Source plugin remove $Plan.codexIntegration.plugin *> $null
            $pluginExitCode = $LASTEXITCODE
            $pluginRemoved = ($pluginExitCode -eq 0)
        } catch {
            $pluginExitCode = -1
        }
        if ($pluginRemoved -and $CleanupCheckpoint) {
            & $CleanupCheckpoint ([PSCustomObject]@{
                operation = $Operation
                required = $true
                attempted = $true
                cliFound = $true
                succeeded = ($pluginRemoved -and $marketplaceRemoved)
                marketplaceAdded = $false
                pluginAdded = $false
                pluginRemoved = $pluginRemoved
                marketplaceRemoved = $marketplaceRemoved
                pluginExitCode = $pluginExitCode
                marketplaceExitCode = $marketplaceExitCode
            })
        }
    }
    if (-not $marketplaceRemoved) {
        try {
            & $codex.Source plugin marketplace remove clusteryourcodex *> $null
            $marketplaceExitCode = $LASTEXITCODE
            $marketplaceRemoved = ($marketplaceExitCode -eq 0)
        } catch {
            $marketplaceExitCode = -1
        }
        if ($marketplaceRemoved -and $CleanupCheckpoint) {
            & $CleanupCheckpoint ([PSCustomObject]@{
                operation = $Operation
                required = $true
                attempted = $true
                cliFound = $true
                succeeded = ($pluginRemoved -and $marketplaceRemoved)
                marketplaceAdded = $false
                pluginAdded = $false
                pluginRemoved = $pluginRemoved
                marketplaceRemoved = $marketplaceRemoved
                pluginExitCode = $pluginExitCode
                marketplaceExitCode = $marketplaceExitCode
            })
        }
    }
    return [PSCustomObject]@{
        operation = $Operation
        required = $true
        attempted = $true
        cliFound = $true
        succeeded = ($pluginRemoved -and $marketplaceRemoved)
        marketplaceAdded = $false
        pluginAdded = $false
        pluginRemoved = $pluginRemoved
        marketplaceRemoved = $marketplaceRemoved
        pluginExitCode = $pluginExitCode
        marketplaceExitCode = $marketplaceExitCode
    }
}

function Write-DurableAtomicJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value,
        [ValidateRange(2, 100)][int]$Depth = 10
    )
    $directory = Split-Path -Parent $Path
    [void](New-Item -ItemType Directory -Path $directory -Force)
    $leaf = Split-Path -Leaf $Path
    $temporary = Join-Path $directory ($leaf + '.tmp-' + [Guid]::NewGuid().ToString('N'))
    $backup = Join-Path $directory ($leaf + '.bak-' + [Guid]::NewGuid().ToString('N'))
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $bytes = $utf8.GetBytes(($Value | ConvertTo-Json -Depth $Depth))
    $stream = $null
    $committed = $false
    try {
        $stream = [System.IO.FileStream]::new(
            $temporary,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None,
            4096,
            [System.IO.FileOptions]::WriteThrough
        )
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null

        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [System.IO.File]::Replace($temporary, $Path, $backup, $true)
        } else {
            [System.IO.File]::Move($temporary, $Path)
        }

        # Flush the installed record after the atomic rename/replace before a
        # later external cleanup command is allowed to run.
        $stream = [System.IO.FileStream]::new(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::Read,
            4096,
            [System.IO.FileOptions]::WriteThrough
        )
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        $committed = $true
    } finally {
        if ($stream) { $stream.Dispose() }
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        if ($committed -and (Test-Path -LiteralPath $backup)) {
            Remove-Item -LiteralPath $backup -Force
        }
    }
}

function Write-CodexCleanupState {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)]$Result
    )
    $cleanup = [PSCustomObject][ordered]@{
        attemptedAtUtc = [DateTime]::UtcNow.ToString('o')
        attempted = $Result.attempted
        cliFound = $Result.cliFound
        succeeded = $Result.succeeded
        pluginRemoved = $Result.pluginRemoved
        marketplaceRemoved = $Result.marketplaceRemoved
        pluginExitCode = $Result.pluginExitCode
        marketplaceExitCode = $Result.marketplaceExitCode
    }
    if ($Manifest.codexIntegration.PSObject.Properties['cleanup']) {
        $Manifest.codexIntegration.cleanup = $cleanup
    } else {
        $Manifest.codexIntegration | Add-Member -NotePropertyName cleanup -NotePropertyValue $cleanup
    }
    Write-DurableAtomicJson -Path $ManifestPath -Value $Manifest -Depth 10
}

function Write-InstallManifest {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)]$CodexResult
    )
    $manifestDirectory = Split-Path -Parent $Plan.manifestPath
    [void](New-Item -ItemType Directory -Path $manifestDirectory -Force)
    $record = [ordered]@{
        schemaVersion = $script:ManifestSchema
        productVersion = '0.1.0'
        installedAtUtc = [DateTime]::UtcNow.ToString('o')
        installRoot = $Plan.installRoot
        dataRoot = $Plan.dataRoot
        files = @($Plan.files | ForEach-Object {
            [ordered]@{ relativePath = $_.relativePath; sha256 = $_.sha256; length = $_.length }
        })
        tasks = @($Plan.tasks | Where-Object enabled | ForEach-Object { $_.name })
        codexIntegration = [ordered]@{
            enabled = $Plan.codexIntegration.enabled
            available = $Plan.codexIntegration.available
            marketplaceRoot = $Plan.codexIntegration.marketplaceRoot
            plugin = $Plan.codexIntegration.plugin
            attempted = $CodexResult.attempted
            cliFound = $CodexResult.cliFound
            succeeded = $CodexResult.succeeded
            marketplaceAdded = $CodexResult.marketplaceAdded
            pluginAdded = $CodexResult.pluginAdded
            pluginExitCode = $CodexResult.pluginExitCode
            marketplaceExitCode = $CodexResult.marketplaceExitCode
        }
    }
    $temporary = $Plan.manifestPath + '.tmp'
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $Plan.manifestPath -Force
}

function Assert-SafePurgeTarget {
    param(
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)]$Manifest
    )
    $target = Resolve-NormalizedPath $DataRoot
    $recorded = Resolve-NormalizedPath $Manifest.dataRoot
    $defaultRoot = Resolve-NormalizedPath (Join-Path $env:LOCALAPPDATA 'ClusterYourCodex')
    if (-not [string]::Equals($target, $recorded, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals($target, $defaultRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'PurgeData is allowed only for the manifest-recorded default data directory.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $target '.installer\install-manifest.json') -PathType Leaf)) {
        throw 'PurgeData requires the owned install manifest.'
    }
    return $target
}

function Invoke-InstallOrRepair {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)]$Plan)
    if ($PlanOnly) { return $Plan }
    if ($Plan.tasks[1].enabled -and -not (Test-Path -LiteralPath $Plan.workerConfig -PathType Leaf)) {
        throw 'Worker task requested but the paired worker config does not exist.'
    }
    if (-not $PSCmdlet.ShouldProcess($Plan.installRoot, "$Action ClusterYourCodex")) { return }

    $oldManifest = Read-InstallManifest -ManifestPath $Plan.manifestPath
    Set-PrivateDirectoryAcl -Path $Plan.installRoot
    Set-PrivateDirectoryAcl -Path $Plan.dataRoot
    $taskSnapshots = @(Get-CycTaskSnapshots)
    Stop-CycRuntime -InstallRoot $Plan.installRoot
    $rollback = $null
    $codexResult = $null
    try {
        $rollback = New-FileRollbackSnapshot -Plan $Plan -OldManifest $oldManifest
        Install-PlannedFiles -Plan $Plan
        Set-PrivateDirectoryAcl -Path $Plan.installRoot
        Set-PrivateDirectoryAcl -Path $Plan.dataRoot

        if ($oldManifest) {
            Remove-OwnedFiles `
                -Manifest $oldManifest `
                -ExpectedInstallRoot $Plan.installRoot `
                -KeepRelativePaths @($Plan.files.relativePath)
        }

        Register-CycTask -Name $script:ControllerTaskName -Action $Plan.tasks[0].action
        if ($Plan.tasks[1].enabled) {
            Register-CycTask -Name $script:WorkerTaskName -Action $Plan.tasks[1].action
        } else {
            Unregister-CycTask -Name $script:WorkerTaskName
        }

        $codexResult = Invoke-CodexIntegration -Plan $Plan -Operation Install
        Write-InstallManifest -Plan $Plan -CodexResult $codexResult
        Start-ScheduledTask -TaskName $script:ControllerTaskName
        Wait-CycTaskStable -Name $script:ControllerTaskName -StableSeconds 2
        Wait-CycControllerReady
        Wait-CycTaskStable -Name $script:ControllerTaskName -StableSeconds 1
        if ($Plan.tasks[1].enabled) {
            Start-ScheduledTask -TaskName $script:WorkerTaskName
            Wait-CycTaskStable -Name $script:WorkerTaskName -StableSeconds 3
            Test-CycWorkerStatus -Action $Plan.tasks[1].action -Config $Plan.workerConfig
            Wait-CycTaskStable -Name $script:WorkerTaskName -StableSeconds 1
        }
    } catch {
        $failure = $_
        Stop-CycRuntime -InstallRoot $Plan.installRoot
        $oldCodexSucceeded = $false
        if ($oldManifest -and $oldManifest.PSObject.Properties['codexIntegration'] -and
            $oldManifest.codexIntegration.PSObject.Properties['succeeded']) {
            $oldCodexSucceeded = [bool]$oldManifest.codexIntegration.succeeded
        }
        if ($codexResult -and
            ($codexResult.succeeded -or $codexResult.marketplaceAdded -or $codexResult.pluginAdded) -and
            -not $oldCodexSucceeded) {
            $rollbackManifest = Read-InstallManifest -ManifestPath $Plan.manifestPath
            if (-not $rollbackManifest) {
                throw 'Codex rollback requires the durable install manifest.'
            }
            $rollbackPlan = [PSCustomObject]@{
                codexIntegration = $rollbackManifest.codexIntegration
            }
            $rollbackManifestPath = $Plan.manifestPath
            $rollbackCheckpoint = {
                param($result)
                Write-CodexCleanupState `
                    -Manifest $rollbackManifest `
                    -ManifestPath $rollbackManifestPath `
                    -Result $result
            }
            [void](Invoke-CodexIntegration `
                -Plan $rollbackPlan `
                -Operation Uninstall `
                -CleanupCheckpoint $rollbackCheckpoint)
        }
        if ($rollback) { Restore-FileRollbackSnapshot -Snapshot $rollback }
        Restore-CycTaskSnapshots -Snapshots $taskSnapshots
        throw $failure
    } finally {
        if ($rollback) { Remove-FileRollbackSnapshot -Snapshot $rollback }
    }
    [PSCustomObject]@{
        action = $Action
        installRoot = $Plan.installRoot
        dataRoot = $Plan.dataRoot
        controllerTask = $script:ControllerTaskName
        workerTaskEnabled = $Plan.tasks[1].enabled
        codexIntegration = $codexResult
    }
}

function Invoke-Uninstall {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$DataRoot
    )
    $install = Resolve-NormalizedPath $InstallRoot
    $data = Resolve-NormalizedPath $DataRoot
    $manifestPath = Join-Path $data '.installer\install-manifest.json'
    $manifest = Read-InstallManifest -ManifestPath $manifestPath
    if (-not $manifest) {
        if ($PurgeData) {
            throw 'PurgeData requires the owned install manifest.'
        }
        return [PSCustomObject]@{
            action = 'Uninstall'
            installRoot = $install
            dataRoot = $data
            dataPreserved = $true
            alreadyAbsent = $true
        }
    }
    $codexCleanupRequired = $false
    if ($manifest.codexIntegration -and $manifest.codexIntegration.enabled) {
        $hasStepRecords = $manifest.codexIntegration.PSObject.Properties['marketplaceAdded'] -and
            $manifest.codexIntegration.PSObject.Properties['pluginAdded']
        if ($hasStepRecords) {
            $codexCleanupRequired = [bool](
                $manifest.codexIntegration.marketplaceAdded -or
                $manifest.codexIntegration.pluginAdded -or
                $manifest.codexIntegration.PSObject.Properties['cleanup']
            )
        } else {
            $codexCleanupRequired = [bool](
                ($manifest.codexIntegration.PSObject.Properties['attempted'] -and $manifest.codexIntegration.attempted) -or
                ($manifest.codexIntegration.PSObject.Properties['succeeded'] -and $manifest.codexIntegration.succeeded) -or
                $manifest.codexIntegration.PSObject.Properties['cleanup']
            )
        }
    }
    $plan = [PSCustomObject]@{
        action = 'Uninstall'
        installRoot = $install
        dataRoot = $data
        manifestPath = $manifestPath
        tasks = @($manifest.tasks)
        files = @($manifest.files)
        purgeData = [bool]$PurgeData
        preserveData = -not [bool]$PurgeData
        codexIntegration = $manifest.codexIntegration
        codexCleanupRequired = $codexCleanupRequired
    }
    if ($PlanOnly) { return $plan }
    if (-not $PSCmdlet.ShouldProcess($install, 'Uninstall ClusterYourCodex')) { return }

    $codexResult = [PSCustomObject]@{
        operation = 'Uninstall'
        required = $false
        attempted = $false
        cliFound = $false
        succeeded = $true
        marketplaceAdded = $false
        pluginAdded = $false
        pluginRemoved = $false
        marketplaceRemoved = $false
        pluginExitCode = $null
        marketplaceExitCode = $null
    }
    if ($codexCleanupRequired) {
        $checkpoint = {
            param($result)
            Write-CodexCleanupState -Manifest $manifest -ManifestPath $manifestPath -Result $result
        }
        $codexResult = Invoke-CodexIntegration `
            -Plan $plan `
            -Operation Uninstall `
            -CleanupCheckpoint $checkpoint
        Write-CodexCleanupState -Manifest $manifest -ManifestPath $manifestPath -Result $codexResult
        if (-not $codexResult.succeeded) {
            throw 'Codex integration cleanup failed; installation was left intact and uninstall can be retried.'
        }
    }

    Unregister-CycTask -Name $script:WorkerTaskName
    Unregister-CycTask -Name $script:ControllerTaskName
    Stop-CycRuntime -InstallRoot $install
    Remove-OwnedFiles -Manifest $manifest -ExpectedInstallRoot $install

    if ($PurgeData) {
        $purgeTarget = Assert-SafePurgeTarget -DataRoot $data -Manifest $manifest
        # The exact resolved target is checked above before the only recursive delete.
        Remove-Item -LiteralPath $purgeTarget -Recurse -Force
    } else {
        Remove-Item -LiteralPath $manifestPath -Force
        $manifestDirectory = Split-Path -Parent $manifestPath
        if ((Test-Path -LiteralPath $manifestDirectory -PathType Container) -and
            -not (Get-ChildItem -LiteralPath $manifestDirectory -Force | Select-Object -First 1)) {
            Remove-Item -LiteralPath $manifestDirectory -Force
        }
    }
    [PSCustomObject]@{
        action = 'Uninstall'
        installRoot = $install
        dataRoot = $data
        dataPreserved = -not [bool]$PurgeData
        alreadyAbsent = $false
        codexIntegration = $codexResult
    }
}

function Invoke-ClusterYourCodexBootstrap {
    if ($Action -eq 'Uninstall') {
        return Invoke-Uninstall -InstallRoot $InstallRoot -DataRoot $DataRoot
    }
    $plan = Get-InstallPlan `
        -BundleRoot $BundleRoot `
        -InstallRoot $InstallRoot `
        -DataRoot $DataRoot `
        -EnableWorker:$EnableWorker `
        -WorkerConfig $WorkerConfig `
        -SkipCodexIntegration:$SkipCodexIntegration
    return Invoke-InstallOrRepair -Plan $plan
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-ClusterYourCodexBootstrap
}
