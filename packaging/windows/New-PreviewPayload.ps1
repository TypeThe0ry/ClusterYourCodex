#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string]$RootCargoTarget = (Join-Path $RepositoryRoot 'target\release'),
    [string]$DesktopCargoTarget = (Join-Path $RepositoryRoot 'apps\desktop\src-tauri\target\release'),
    [Parameter(Mandatory = $true)][string]$McpDeployRoot,
    [Parameter(Mandatory = $true)][string]$NodeExecutable,
    [Parameter(Mandatory = $true)][string]$NodeLicense,
    [string]$WorkerKitsRoot,
    [string]$SourceTag = [string]$env:CYC_SOURCE_TAG,
    [Parameter(Mandatory = $true)][string]$OutputRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Test-CycPreviewPrivateLanAddress {
    param([Parameter(Mandatory = $true)][string]$Address)
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsed)) { return $false }
    $bytes = $parsed.GetAddressBytes()
    if ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        return $bytes[0] -eq 10 -or
            ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
            ($bytes[0] -eq 192 -and $bytes[1] -eq 168)
    }
    return $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6 -and
        (($bytes[0] -band 0xfe) -eq 0xfc)
}

function Copy-RequiredFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Required preview input is missing: $Source"
    }
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force)
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Test-ReparsePoint {
    param([Parameter(Mandatory = $true)][System.IO.FileSystemInfo]$Item)
    return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Assert-ValidMcpDeploy {
    param(
        [Parameter(Mandatory = $true)][string]$DeployRoot,
        [Parameter(Mandatory = $true)][string]$SourcePackageManifest
    )

    if (-not (Test-Path -LiteralPath $SourcePackageManifest -PathType Leaf)) {
        throw "MCP source package manifest is missing: $SourcePackageManifest"
    }
    $package = Get-Content -LiteralPath $SourcePackageManifest -Raw | ConvertFrom-Json
    $dependenciesProperty = $package.PSObject.Properties['dependencies']
    if ($null -eq $dependenciesProperty -or $null -eq $dependenciesProperty.Value) {
        throw 'MCP source package manifest must declare production dependencies.'
    }
    $dependencyNames = @($dependenciesProperty.Value.PSObject.Properties | ForEach-Object { $_.Name })
    if ($dependencyNames.Count -eq 0) {
        throw 'MCP source package manifest must declare at least one production dependency.'
    }
    $developmentDependencyNames = @()
    $developmentDependenciesProperty = $package.PSObject.Properties['devDependencies']
    if ($null -ne $developmentDependenciesProperty -and
        $null -ne $developmentDependenciesProperty.Value) {
        $developmentDependencyNames = @(
            $developmentDependenciesProperty.Value.PSObject.Properties |
                ForEach-Object { $_.Name } |
                Where-Object { $dependencyNames -notcontains $_ }
        )
    }

    if (-not (Test-Path -LiteralPath $DeployRoot -PathType Container)) {
        throw "McpDeployRoot does not exist: $DeployRoot"
    }
    $deployRootItem = Get-Item -LiteralPath $DeployRoot -Force
    if (Test-ReparsePoint $deployRootItem) {
        throw 'McpDeployRoot must not be a reparse point.'
    }

    $pendingDirectories = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $pendingDirectories.Push($deployRootItem)
    while ($pendingDirectories.Count -gt 0) {
        $directory = $pendingDirectories.Pop()
        foreach ($item in Get-ChildItem -LiteralPath $directory.FullName -Force) {
            if (Test-ReparsePoint $item) {
                throw "McpDeployRoot contains a reparse point: $($item.FullName)"
            }
            if ($item.Name -ieq '.pnpm') {
                throw "McpDeployRoot contains a forbidden .pnpm entry: $($item.FullName)"
            }
            if ($item.PSIsContainer) {
                $pendingDirectories.Push($item)
            }
        }
    }

    $server = Join-Path $DeployRoot 'dist\server.js'
    if (-not (Test-Path -LiteralPath $server -PathType Leaf)) {
        throw 'McpDeployRoot must contain the compiled dist/server.js.'
    }
    $nodeModulesRoot = Join-Path $DeployRoot 'node_modules'
    foreach ($dependencyName in $dependencyNames) {
        $dependencyPath = Join-Path $nodeModulesRoot $dependencyName
        if (-not (Test-Path -LiteralPath $dependencyPath -PathType Container)) {
            throw "McpDeployRoot is missing production dependency '$dependencyName': $dependencyPath"
        }
    }
    foreach ($developmentDependencyName in $developmentDependencyNames) {
        $developmentDependencyPath = Join-Path $nodeModulesRoot $developmentDependencyName
        if (Test-Path -LiteralPath $developmentDependencyPath) {
            throw "McpDeployRoot contains development-only package '$developmentDependencyName': $developmentDependencyPath"
        }
    }
}

function Copy-ValidatedWorkerKits {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion
    )

    $sourceRootPath = Resolve-FullPath $SourceRoot
    if (-not (Test-Path -LiteralPath $sourceRootPath -PathType Container)) {
        throw "WorkerKitsRoot does not exist: $sourceRootPath"
    }
    $sourceRootItem = Get-Item -LiteralPath $sourceRootPath -Force
    if (Test-ReparsePoint $sourceRootItem) {
        throw 'WorkerKitsRoot must not be a reparse point.'
    }
    foreach ($item in Get-ChildItem -LiteralPath $sourceRootPath -Recurse -Force) {
        if (Test-ReparsePoint $item) {
            throw "WorkerKitsRoot contains a reparse point: $($item.FullName)"
        }
    }

    # Ship every generated platform kit in the controller payload. macOS
    # lifecycle activation remains independently fail-closed by both the
    # provisioner and installer containment gates, but users must still be
    # able to export, verify, preinstall, pair, repair, and uninstall the kit.
    $expectedTargets = @(
        'windows-x86_64',
        'linux-x86_64',
        'linux-aarch64',
        'macos-x86_64',
        'macos-aarch64'
    )
    $records = New-Object System.Collections.Generic.List[object]
    $seenTargets = @{}
    $manifests = @(Get-ChildItem -LiteralPath $sourceRootPath -File -Recurse -Filter 'worker-kit.json' -Force)
    foreach ($manifestFile in $manifests) {
        $kitRoot = $manifestFile.Directory.FullName
        $manifest = Get-Content -LiteralPath $manifestFile.FullName -Raw | ConvertFrom-Json
        if ([string]$manifest.schemaVersion -cne 'cyc.dev/worker-kit/v1') {
            throw "Unsupported worker-kit manifest schema: $($manifestFile.FullName)"
        }
        if ([string]$manifest.version -cne $ExpectedVersion) {
            throw "Worker kit '$($manifestFile.FullName)' version does not match product VERSION $ExpectedVersion."
        }
        $target = [string]$manifest.target
        if ($expectedTargets -cnotcontains $target) {
            throw "Unsupported worker-kit target '$target'."
        }
        if ($seenTargets.ContainsKey($target)) {
            throw "Duplicate worker-kit target '$target'."
        }

        $binaryName = if ($target -eq 'windows-x86_64') { 'cyc-worker.exe' } else { 'cyc-worker' }
        $installerName = if ($target -eq 'windows-x86_64') { 'Install-Worker.ps1' } else { 'install-worker.sh' }
        $expectedFiles = @($binaryName, $installerName, 'worker-kit.json', 'worker-kit.sig', 'SHA256SUMS')
        $actualItems = @(Get-ChildItem -LiteralPath $kitRoot -Force)
        if (@($actualItems | Where-Object { $_.PSIsContainer }).Count -ne 0) {
            throw "Worker kit '$target' must not contain directories."
        }
        $actualNames = @($actualItems | ForEach-Object { $_.Name })
        if ($actualNames.Count -ne $expectedFiles.Count) {
            throw "Worker kit '$target' must contain exactly five files."
        }
        foreach ($expectedFile in $expectedFiles) {
            if ($actualNames -cnotcontains $expectedFile) {
                throw "Worker kit '$target' is missing $expectedFile."
            }
        }

        $checksumPath = Join-Path $kitRoot 'SHA256SUMS'
        $checksumLines = @(Get-Content -LiteralPath $checksumPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($checksumLines.Count -ne 4) {
            throw "Worker kit '$target' must declare exactly four checksums."
        }
        $checksums = @{}
        foreach ($line in $checksumLines) {
            if ($line -cnotmatch '^(?<hash>[0-9a-f]{64})  (?<name>[^/\\]+)$') {
                throw "Malformed checksum in worker kit '$target'."
            }
            $fileName = [string]$Matches.name
            if (@($binaryName, $installerName, 'worker-kit.json', 'worker-kit.sig') -cnotcontains $fileName -or
                $checksums.ContainsKey($fileName)) {
                throw "Unexpected or duplicate checksum entry '$fileName' in worker kit '$target'."
            }
            $checksums[$fileName] = [string]$Matches.hash
        }
        foreach ($fileName in @($binaryName, $installerName, 'worker-kit.json', 'worker-kit.sig')) {
            if (-not $checksums.ContainsKey($fileName)) {
                throw "Worker kit '$target' has no checksum for $fileName."
            }
            $actualHash = (Get-FileHash -LiteralPath (Join-Path $kitRoot $fileName) -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actualHash -cne $checksums[$fileName]) {
                throw "Worker kit '$target' failed SHA-256 validation for $fileName."
            }
        }

        $signaturePath = Join-Path $kitRoot 'worker-kit.sig'
        $signature = Get-Content -LiteralPath $signaturePath -Raw | ConvertFrom-Json
        if (@($signature.PSObject.Properties).Count -ne 6 -or
            [string]$signature.schemaVersion -cne 'cyc.dev/worker-kit-signature/v1' -or
            [string]$signature.algorithm -cne 'Ed25519' -or
            [string]$signature.keyId -cne 'cyc-release-2026-02' -or
            [string]$signature.signedObject -cne 'worker-kit.json' -or
            [string]$signature.manifestSha256 -cne $checksums['worker-kit.json'] -or
            [string]$signature.signature -cnotmatch '^[A-Za-z0-9+/]{86}==$') {
            throw "Worker kit '$target' publisher signature envelope is invalid."
        }

        $manifestEntries = @($manifest.files)
        if ($manifestEntries.Count -ne 2) {
            throw "Worker kit '$target' manifest must describe exactly two payload files."
        }
        foreach ($fileName in @($binaryName, $installerName)) {
            $entry = @($manifestEntries | Where-Object { [string]$_.path -ceq $fileName })
            if ($entry.Count -ne 1) {
                throw "Worker kit '$target' manifest has an invalid entry for $fileName."
            }
            $item = Get-Item -LiteralPath (Join-Path $kitRoot $fileName) -Force
            if ([long]$entry[0].sizeBytes -ne [long]$item.Length -or
                [string]$entry[0].sha256 -cne [string]$checksums[$fileName]) {
                throw "Worker kit '$target' manifest metadata mismatch for $fileName."
            }
        }

        $destination = Join-Path $DestinationRoot $target
        if (Test-Path -LiteralPath $destination) {
            throw "Worker-kit destination already exists: $destination"
        }
        [void](New-Item -ItemType Directory -Path $destination -Force)
        foreach ($fileName in $expectedFiles) {
            Copy-RequiredFile -Source (Join-Path $kitRoot $fileName) -Destination (Join-Path $destination $fileName)
        }
        $seenTargets[$target] = $true
        [void]$records.Add([ordered]@{
            target = $target
            version = [string]$manifest.version
            manifestSha256 = [string]$checksums['worker-kit.json']
            workerSha256 = [string]$checksums[$binaryName]
        })
    }

    foreach ($target in $expectedTargets) {
        if (-not $seenTargets.ContainsKey($target)) {
            throw "WorkerKitsRoot is missing required target '$target'."
        }
    }
    return @($records | Sort-Object target)
}

$repo = Resolve-FullPath $RepositoryRoot
$versionCheckArguments = @{
    RepositoryRoot = $repo
    RequirePrerelease = $true
    SkipNegativeTests = $true
    Json = $true
}
if (-not [string]::IsNullOrWhiteSpace($SourceTag)) {
    $versionCheckArguments.SourceTag = $SourceTag.Trim()
}
$releaseIdentity = (& (Join-Path $repo 'scripts\Test-VersionConsistency.ps1') @versionCheckArguments) |
    ConvertFrom-Json
$productVersion = [string]$releaseIdentity.productVersion
$releaseChannel = [string]$releaseIdentity.releaseChannel
$sourceTagValue = if ($null -eq $releaseIdentity.sourceTag) { $null } else { [string]$releaseIdentity.sourceTag }
$rootTarget = Resolve-FullPath $RootCargoTarget
$desktopTarget = Resolve-FullPath $DesktopCargoTarget
$mcpDeploy = Resolve-FullPath $McpDeployRoot
$nodeExecutablePath = Resolve-FullPath $NodeExecutable
$nodeLicensePath = Resolve-FullPath $NodeLicense
$output = Resolve-FullPath $OutputRoot
$mcpPackageManifest = Join-Path $repo 'plugins\cluster-your-codex\mcp\package.json'
Assert-ValidMcpDeploy -DeployRoot $mcpDeploy -SourcePackageManifest $mcpPackageManifest
if (-not (Test-Path -LiteralPath $nodeExecutablePath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $nodeLicensePath -PathType Leaf)) {
    throw 'NodeExecutable and its matching NodeLicense must both be regular files.'
}
$nodeArch = [string](& $nodeExecutablePath -p 'process.arch')
$nodeVersion = [string](& $nodeExecutablePath -p 'process.version')
if ($LASTEXITCODE -ne 0 -or $nodeArch.Trim() -ne 'x64' -or
    [int]($nodeVersion.Trim().TrimStart('v').Split('.')[0]) -lt 20) {
    throw 'Windows x64 preview requires a working private Node.js 20+ x64 runtime.'
}
if (Test-Path -LiteralPath $output) {
    if (Get-ChildItem -LiteralPath $output -Force | Select-Object -First 1) {
        throw "OutputRoot must not already contain files: $output"
    }
} else {
    [void](New-Item -ItemType Directory -Path $output -Force)
}

$payload = Join-Path $output 'payload'
[void](New-Item -ItemType Directory -Path $payload -Force)
foreach ($name in @('cyc-controller.exe', 'cyc-worker.exe', 'cyc.exe')) {
    Copy-RequiredFile -Source (Join-Path $rootTarget $name) -Destination (Join-Path $payload $name)
}
Copy-RequiredFile `
    -Source (Join-Path $desktopTarget 'ClusterYourCodex.exe') `
    -Destination (Join-Path $payload 'ClusterYourCodex.exe')
Copy-RequiredFile `
    -Source (Join-Path $PSScriptRoot 'bootstrap.ps1') `
    -Destination (Join-Path $output 'bootstrap.ps1')
Copy-RequiredFile `
    -Source (Join-Path $PSScriptRoot 'Install-ClusterYourCodex.cmd') `
    -Destination (Join-Path $output 'Install-ClusterYourCodex.cmd')
Copy-RequiredFile `
    -Source (Join-Path $PSScriptRoot 'Invoke-ClusterYourCodexLifecycle.ps1') `
    -Destination (Join-Path $output 'Invoke-ClusterYourCodexLifecycle.ps1')
Copy-RequiredFile `
    -Source (Join-Path $PSScriptRoot 'Invoke-ClusterYourCodexFirewall.ps1') `
    -Destination (Join-Path $output 'Invoke-ClusterYourCodexFirewall.ps1')
Copy-RequiredFile `
    -Source (Join-Path $PSScriptRoot 'README.md') `
    -Destination (Join-Path $output 'README.md')
Copy-RequiredFile `
    -Source (Join-Path $PSScriptRoot 'bootstrap.ps1') `
    -Destination (Join-Path $payload 'installer\bootstrap.ps1')
Copy-RequiredFile `
    -Source (Join-Path $PSScriptRoot 'Uninstall-ClusterYourCodex.ps1') `
    -Destination (Join-Path $payload 'installer\Uninstall-ClusterYourCodex.ps1')
Copy-RequiredFile `
    -Source (Join-Path $PSScriptRoot 'Invoke-ClusterYourCodexLifecycle.ps1') `
    -Destination (Join-Path $payload 'installer\Invoke-ClusterYourCodexLifecycle.ps1')
Copy-RequiredFile `
    -Source (Join-Path $PSScriptRoot 'Invoke-ClusterYourCodexFirewall.ps1') `
    -Destination (Join-Path $payload 'installer\Invoke-ClusterYourCodexFirewall.ps1')
Copy-RequiredFile `
    -Source (Join-Path $PSScriptRoot 'cluster-agents-block.md') `
    -Destination (Join-Path $payload 'integrations\codex\cluster-agents-block.md')
Copy-RequiredFile `
    -Source (Join-Path $repo 'LICENSE') `
    -Destination (Join-Path $output 'LICENSE')

$marketplace = Join-Path $payload 'integrations\codex-marketplace'
Copy-RequiredFile `
    -Source (Join-Path $repo '.agents\plugins\marketplace.json') `
    -Destination (Join-Path $marketplace '.agents\plugins\marketplace.json')
$pluginSource = Join-Path $repo 'plugins\cluster-your-codex'
$pluginTarget = Join-Path $marketplace 'plugins\cluster-your-codex'
[void](New-Item -ItemType Directory -Path $pluginTarget -Force)
foreach ($relative in @('.codex-plugin', 'skills')) {
    $source = Join-Path $pluginSource $relative
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        throw "Required plugin directory is missing: $source"
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path $pluginTarget $relative) -Recurse -Force
}
$sourceMcpManifest = Join-Path $pluginSource '.mcp.json'
if (-not (Test-Path -LiteralPath $sourceMcpManifest -PathType Leaf)) {
    throw "Required plugin manifest is missing: $sourceMcpManifest"
}
$sourceMcpHash = (Get-FileHash -LiteralPath $sourceMcpManifest -Algorithm SHA256).Hash
$stagedMcpManifest = Join-Path $pluginTarget '.mcp.json'
$mcpConfiguration = Get-Content -LiteralPath $sourceMcpManifest -Raw | ConvertFrom-Json
if (-not $mcpConfiguration.mcpServers.cluster_your_codex) {
    throw 'Plugin .mcp.json is missing mcpServers.cluster_your_codex.'
}
$mcpConfiguration.mcpServers.cluster_your_codex.command = './mcp/runtime/node.exe'
$mcpConfiguration | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $stagedMcpManifest -Encoding UTF8
if ((Get-FileHash -LiteralPath $sourceMcpManifest -Algorithm SHA256).Hash -ne $sourceMcpHash) {
    throw 'Source plugin .mcp.json changed during preview staging.'
}
Copy-Item -LiteralPath $mcpDeploy -Destination (Join-Path $pluginTarget 'mcp') -Recurse -Force
Copy-RequiredFile `
    -Source $nodeExecutablePath `
    -Destination (Join-Path $pluginTarget 'mcp\runtime\node.exe')
Copy-RequiredFile `
    -Source $nodeLicensePath `
    -Destination (Join-Path $pluginTarget 'mcp\runtime\LICENSE.node.txt')

$workerKitRecords = @()
if (-not [string]::IsNullOrWhiteSpace($WorkerKitsRoot)) {
    $workerKitRecords = @(Copy-ValidatedWorkerKits `
        -SourceRoot $WorkerKitsRoot `
        -DestinationRoot (Join-Path $payload 'worker-kits') `
        -ExpectedVersion $productVersion)
}

$files = @(Get-ChildItem -LiteralPath $output -File -Recurse -Force | Sort-Object FullName)
$records = @($files | ForEach-Object {
    $relative = $_.FullName.Substring($output.Length + 1).Replace('\', '/')
    [ordered]@{
        path = $relative
        length = [long]$_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
})
$manifest = [ordered]@{
    schemaVersion = 'cyc.dev/windows-preview/v1'
    productVersion = $productVersion
    releaseChannel = $releaseChannel
    sourceTag = $sourceTagValue
    createdAtUtc = [DateTime]::UtcNow.ToString('o')
    architecture = 'x86_64-pc-windows-msvc'
    nodeVersion = $nodeVersion.Trim()
    workerKits = $workerKitRecords
    files = $records
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $output 'preview-manifest.json') -Encoding UTF8
$checksumRecords = @(Get-ChildItem -LiteralPath $output -File -Recurse -Force | Sort-Object FullName | ForEach-Object {
    $relative = $_.FullName.Substring($output.Length + 1).Replace('\', '/')
    $digest = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$digest  $relative"
})
$checksumRecords | Set-Content -LiteralPath (Join-Path $output 'SHA256SUMS') -Encoding ASCII

# Reuse the installer planner as the final payload-layout and private-network
# acceptance check. The transient typed plan is inspected in-process and is
# never serialized into the public preview package.
$previewPlanNonce = [Guid]::NewGuid().ToString('N')
$previewPlanInstallRoot = Join-Path $env:LOCALAPPDATA "Programs\ClusterYourCodex-PreviewPlan-$previewPlanNonce"
$previewPlanDataRoot = Join-Path $env:LOCALAPPDATA "ClusterYourCodex-PreviewPlan-$previewPlanNonce"
$previewPlans = @(& (Join-Path $output 'bootstrap.ps1') `
    -Action Install `
    -BundleRoot $payload `
    -InstallRoot $previewPlanInstallRoot `
    -DataRoot $previewPlanDataRoot `
    -WorkerConfig (Join-Path $previewPlanDataRoot 'worker\config.json') `
    -PlanOnly)
if ($previewPlans.Count -ne 1) { throw 'Installer PlanOnly did not return exactly one typed plan.' }
$previewPlan = $previewPlans[0]
if (-not [bool]$previewPlan.managedWorker.enabled -or
    [string]$previewPlan.managedWorker.networkPlan.schemaVersion -cne 'cyc.dev/windows-managed-worker-network/v1' -or
    [int]$previewPlan.managedWorker.networkPlan.selectedInterfaceIndex -lt 1 -or
    -not (Test-CycPreviewPrivateLanAddress ([string]$previewPlan.managedWorker.networkPlan.bindHost)) -or
    [string]$previewPlan.managedWorker.networkPlan.bindHost -cin @('0.0.0.0', '::', '127.0.0.1', '::1') -or
    [string]$previewPlan.tasks[0].action.arguments -match '(?:^|\s)--worker-bind\s+(?:0\.0\.0\.0|\[?::\]?):' -or
    -not ([string]$previewPlan.managedWorker.tlsDirectory).EndsWith(
        '\tls\managed-worker-v2',
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'Installer PlanOnly did not produce a private, non-wildcard, versioned managed-worker plan.'
}
Write-Output $output
