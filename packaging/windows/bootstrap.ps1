#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Install', 'Repair', 'Uninstall', 'IntegrateCodex', 'CommitFirewall')]
    [string]$Action = 'Install',

    [string]$BundleRoot,

    [string]$PackageRoot,

    [string]$PackageManifest,

    [string]$PackageExecutable,

    [switch]$RequirePackageSignature,

    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\ClusterYourCodex'),

    [string]$DataRoot = (Join-Path $env:LOCALAPPDATA 'ClusterYourCodex'),

    [switch]$EnableWorker,

    [string]$WorkerConfig = (Join-Path $env:LOCALAPPDATA 'ClusterYourCodex\worker\config.json'),

    [string]$WorkerPublicHost,

    [string]$WorkerBindHost,

    [ValidateRange(0, 2147483647)]
    [int]$WorkerInterfaceIndex = 0,

    [string]$WorkerControllerHostName,

    [string[]]$WorkerPrivateAddress,

    [ValidateRange(1, 65535)]
    [int]$WorkerListenPort = 47832,

    [switch]$DisableManagedWorkerListener,

    [switch]$SkipFirewall,

    [switch]$DeferFirewall,

    [string]$InitiatingSid,

    [string]$InitiatingProfile,

    [string]$InitiatingLocalAppData,

    [string]$FirewallTransactionId,

    [string]$FirewallRequestSha256,

    [string]$FirewallReceiptPath,

    [switch]$SkipCodexIntegration,

    [string]$CodexHome,

    [string]$CodexCliPath,

    [string]$ExpectedInstallManifestSha256,

    [ValidateRange(1, 30)]
    [int]$MutexTimeoutSeconds = 10,

    [ValidateRange(10, 90)]
    [int]$ActionTimeoutSeconds = 60,

    [switch]$SkipUninstallRegistration,

    [string]$UninstallerPath,

    [switch]$PurgeData,

    [switch]$PlanOnly,

    # The product uses an interactive-token task so the controller stays in
    # the initiating user's session. The disposable profile matrix has a
    # separate parent-elevated registration gate because a
    # CreateProcessWithLogonW child has no Winlogon token; production
    # invocations still fail closed if they request a non-interactive principal.
    [ValidateSet('Interactive', 'S4U')]
    [string]$ScheduledTaskLogonType = 'Interactive',

    [switch]$ProfileMatrixTestMode,

    # Test-only bridge: the elevated profile-matrix parent may register the
    # production Interactive task on behalf of a disposable child. The bridge
    # is rejected unless this explicit switch and the bound IPC declaration are
    # both present.
    [switch]$ProfileMatrixTaskHelperMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 does not reliably populate $PSScriptRoot while
# evaluating param-block default expressions for a script launched with
# `-File`. Resolve the default only after parameter binding completes.
if ([string]::IsNullOrWhiteSpace($BundleRoot)) {
    $BundleRoot = Join-Path $PSScriptRoot 'payload'
}

$script:ManifestSchema = 'cyc.dev/windows-install-manifest/v1'
$script:ProductVersion = '0.1.0-preview.63'
$script:CoreCommitSchema = 'cyc.dev/windows-core-commit/v1'
$script:MaxInstallManifestBytes = 16MB
$script:ControllerTaskName = 'ClusterYourCodex Controller'
$script:WorkerTaskName = 'ClusterYourCodex Worker'
$script:FirewallRuleGroup = 'ClusterYourCodex'
$script:FirewallRuleDescription = 'ClusterYourCodex owned managed-worker TLS listener'
$script:FirewallReceiptSchema = 'cyc.dev/windows-firewall-receipt/v1'
$script:FirewallLifecycleName = 'external-elevated-helper'
$script:ManagedWorkerNetworkPlanSchema = 'cyc.dev/windows-managed-worker-network/v1'
$script:ManagedWorkerIdentityVersion = 'managed-worker-v2'
$script:UninstallRegistryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ClusterYourCodex'
$script:RequiredExecutables = @('ClusterYourCodex.exe', 'cyc-controller.exe', 'cyc.exe')
$script:AgentsBeginMarker = '<!-- CLUSTERYOURCODEX-MANAGED:BEGIN -->'
$script:AgentsEndMarker = '<!-- CLUSTERYOURCODEX-MANAGED:END -->'
$script:AgentsIntegrationSchema = 'cyc.dev/agents-managed-block/v1'
$script:AgentsJournalSchema = 'cyc.dev/agents-transaction/v1'
$script:AgentsTemplateRelativePath = 'integrations/codex/cluster-agents-block.md'
$script:MaxAgentsFileBytes = 16MB
$script:AgentsMutexName = 'Local\ClusterYourCodex.GlobalAgents.v1'
$script:CodexOnlyReceiptSchema = 'cyc.dev/codex-integration-receipt/v1'
$script:CodexPluginId = 'cluster-your-codex@clusteryourcodex'
$script:CodexPluginRelativePath = 'integrations/codex-marketplace/plugins/cluster-your-codex'
$script:CodexPluginManifestRelativePath = 'integrations/codex-marketplace/plugins/cluster-your-codex/.codex-plugin/plugin.json'
$script:CodexMarketplaceManifestRelativePath = 'integrations/codex-marketplace/.agents/plugins/marketplace.json'
$script:MaxCodexOnlyReceiptBytes = 4096
$script:FileCatalogSchema = 'cyc.dev/file-catalog/v1'
$script:CodexMarketplaceRelativeRoot = 'integrations/codex-marketplace'
$script:CodexMarketplacePrefix = 'integrations/codex-marketplace/'

# Windows PowerShell 5.1 treats BOM-less JSON read through Get-Content as
# ANSI.  Durable installer files are emitted as strict UTF-8 without a BOM,
# and profile-matrix IPC carries Unicode account/profile paths.  Decode bytes
# explicitly at every file-backed JSON boundary so ARM64/x64-emulation and
# non-ASCII profiles retain the exact values that were written.
function Read-CycUtf8Json {
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

if ($ProfileMatrixTestMode) {
    if ($ScheduledTaskLogonType -cne 'S4U') {
        throw 'ProfileMatrixTestMode requires ScheduledTaskLogonType S4U.'
    }
} elseif ($ScheduledTaskLogonType -cne 'Interactive') {
    throw 'ScheduledTaskLogonType S4U is restricted to ProfileMatrixTestMode.'
}
$script:ScheduledTaskLogonType = $ScheduledTaskLogonType

# A disposable profile launched with CreateProcessWithLogonW has no Winlogon
# session.  Registering the production InteractiveToken task from that token
# therefore returns Access is denied on clean Windows 11 images.  The profile
# matrix can opt into a narrowly-scoped parent-helper gate: the elevated
# matrix controller performs the exact same Interactive registration, while
# this process verifies the request/response and deliberately skips runtime
# start.  No normal product invocation can enter this path accidentally.
$script:ProfileMatrixTaskGate = 'none'
$script:ProfileMatrixTaskRuntime = 'started'
$script:ProfileMatrixTaskGateEvidencePath = $null
$script:ProfileMatrixTaskRequestPath = $null
$script:ProfileMatrixTaskResponsePath = $null

$profileMatrixGate = [string]$env:CYC_PROFILE_MATRIX_TASK_GATE
if (-not [string]::IsNullOrWhiteSpace($profileMatrixGate)) {
    if (-not $ProfileMatrixTaskHelperMode) {
        throw 'Profile-matrix task helper mode requires its explicit test switch.'
    }
    if ($profileMatrixGate -cne 'parent-elevated-registration-v1') {
        throw 'Unknown CYC_PROFILE_MATRIX_TASK_GATE value.'
    }
    $gateEvidencePath = [string]$env:CYC_PROFILE_MATRIX_TASK_GATE_EVIDENCE
    $gateRequestPath = [string]$env:CYC_PROFILE_MATRIX_TASK_REQUEST
    $gateResponsePath = [string]$env:CYC_PROFILE_MATRIX_TASK_RESPONSE
    foreach ($gatePath in @($gateEvidencePath, $gateRequestPath, $gateResponsePath)) {
        if ([string]::IsNullOrWhiteSpace($gatePath) -or
            -not [System.IO.Path]::IsPathRooted($gatePath)) {
            throw 'Profile-matrix task gate requires absolute evidence, request, and response paths.'
        }
    }
    if (-not (Test-Path -LiteralPath $gateEvidencePath -PathType Leaf)) {
        throw 'Profile-matrix task gate evidence declaration is missing.'
    }
    try {
        $gateDeclaration = Read-CycUtf8Json -Path $gateEvidencePath
    } catch {
        throw "Profile-matrix task gate evidence is not valid JSON: $($_.Exception.Message)"
    }
    $gateSchema = $gateDeclaration.PSObject.Properties['schemaVersion']
    $gateMode = $gateDeclaration.PSObject.Properties['mode']
    $gateSid = $gateDeclaration.PSObject.Properties['sid']
    $gateLogonType = $gateDeclaration.PSObject.Properties['requestedTaskLogonType']
    $gateRequest = $gateDeclaration.PSObject.Properties['requestPath']
    $gateResponse = $gateDeclaration.PSObject.Properties['responsePath']
    $currentSid = [string]([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    if ($null -eq $gateSchema -or [string]$gateSchema.Value -cne 'cyc.dev/windows-profile-matrix-task-gate/v1' -or
        $null -eq $gateMode -or [string]$gateMode.Value -cne 'parent-elevated-registration-only' -or
        $null -eq $gateSid -or [string]$gateSid.Value -cne $currentSid -or
        $null -eq $gateLogonType -or [string]$gateLogonType.Value -cne 'Interactive' -or
        $null -eq $gateRequest -or [string]$gateRequest.Value -cne $gateRequestPath -or
        $null -eq $gateResponse -or [string]$gateResponse.Value -cne $gateResponsePath) {
        throw 'Profile-matrix task gate evidence does not bind the current SID, Interactive principal, and IPC paths.'
    }
    $script:ProfileMatrixTaskGate = 'parent-elevated-registration-v1'
    $script:ProfileMatrixTaskRuntime = 'not-started'
    $script:ProfileMatrixTaskGateEvidencePath = $gateEvidencePath
    $script:ProfileMatrixTaskRequestPath = $gateRequestPath
    $script:ProfileMatrixTaskResponsePath = $gateResponsePath
} elseif ($ProfileMatrixTaskHelperMode) {
    throw 'Profile-matrix task helper mode requires its bound IPC declaration.'
}

function Resolve-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $volumeRoot = [System.IO.Path]::GetPathRoot($full)
    if ([string]::Equals($full, $volumeRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $volumeRoot
    }
    return $full.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
}

function Get-CycChildPrefix {
    param([Parameter(Mandatory = $true)][string]$Root)
    $rootPath = Resolve-NormalizedPath $Root
    if ($rootPath.EndsWith([string][System.IO.Path]::DirectorySeparatorChar) -or
        $rootPath.EndsWith([string][System.IO.Path]::AltDirectorySeparatorChar)) {
        return $rootPath
    }
    return $rootPath + [System.IO.Path]::DirectorySeparatorChar
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
    $prefix = Get-CycChildPrefix $rootPath
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
    return $pathValue.Substring((Get-CycChildPrefix $rootPath).Length).Replace('\', '/')
}

function Test-ReparsePoint {
    param([Parameter(Mandatory = $true)][System.IO.FileSystemInfo]$Item)
    return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Assert-CycCreationPathNoReparse {
    <#
    Check every existing component before creating a missing leaf. The
    existing-path verifier below deliberately requires all components to be
    present, so it cannot protect New-Item/FileStream calls from a junction
    that already exists in a parent of a not-yet-created path.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    $current = Resolve-NormalizedPath $Path
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (Test-ReparsePoint $item) {
                throw "Creation path contains a reparse point: $current"
            }
        }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) { break }
        $current = $parent
    }
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
    # Do not use Get-ChildItem -Recurse here. Windows PowerShell 5.1 can
    # follow a directory junction before the returned item is inspected,
    # allowing a hostile payload to enumerate outside the bundle. Walk only
    # regular directories and reject every reparse point before descending.
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($bundle)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        $currentItem = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (Test-ReparsePoint $currentItem) {
            throw "Bundle payload contains a reparse point: $current"
        }
        foreach ($item in @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)) {
            if (Test-ReparsePoint $item) {
                throw "Bundle payload contains a reparse point: $($item.FullName)"
            }
            if ($item.PSIsContainer) {
                $pending.Push($item.FullName)
            } else {
                Write-Output $item
            }
        }
    }
}

function Get-CycSha256Hex {
    param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][byte[]]$Bytes)
    if ($null -eq $Bytes) { $Bytes = [byte[]]@() }
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha256.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }
}

function ConvertTo-CycStrictRelativePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -gt 4096 -or
        $Path.Contains('\') -or $Path.Contains(':') -or
        $Path.StartsWith('/', [System.StringComparison]::Ordinal) -or
        $Path.EndsWith('/', [System.StringComparison]::Ordinal) -or
        $Path -match '[\x00-\x1f\x7f]' -or [System.IO.Path]::IsPathRooted($Path)) {
        throw "Install manifest contains an invalid strict relative path: $Path"
    }
    $segments = @($Path.Split('/'))
    if ($segments.Count -eq 0 -or @($segments | Where-Object {
        [string]::IsNullOrEmpty($_) -or $_ -ceq '.' -or $_ -ceq '..'
    }).Count -gt 0) {
        throw "Install manifest contains an invalid path segment: $Path"
    }
    return [string]::Join('/', $segments)
}

function Get-CycFileCatalogDigest {
    param([Parameter(Mandatory = $true)][object[]]$Entries)
    [string[]]$paths = @($Entries | ForEach-Object { [string]$_.relativePath })
    [Array]::Sort($paths, [System.StringComparer]::Ordinal)
    $byPath = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($entry in $Entries) { $byPath.Add([string]$entry.relativePath, $entry) }
    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append($script:FileCatalogSchema).Append("`n")
    foreach ($path in $paths) {
        $entry = $byPath[$path]
        [void]$builder.Append($path).Append("`n")
        [void]$builder.Append([string]$entry.sha256).Append("`n")
        [void]$builder.Append(([long]$entry.length).ToString([System.Globalization.CultureInfo]::InvariantCulture)).Append("`n")
    }
    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    return Get-CycSha256Hex -Bytes $utf8.GetBytes($builder.ToString())
}

function Get-CycManifestFileCatalog {
    param([Parameter(Mandatory = $true)]$Manifest)
    $filesProperty = $Manifest.PSObject.Properties['files']
    if (-not $filesProperty) { throw 'Install manifest has no files catalog.' }
    $entries = @($filesProperty.Value)
    if ($entries.Count -lt 1 -or $entries.Count -gt 100000) {
        throw 'Install manifest files catalog is empty or unbounded.'
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $validated = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $entries) {
        if (-not $entry) { throw 'Install manifest contains a null file receipt.' }
        [string[]]$propertyNames = @($entry.PSObject.Properties.Name)
        [Array]::Sort($propertyNames, [System.StringComparer]::Ordinal)
        if ([string]::Join(',', $propertyNames) -cne 'length,relativePath,sha256') {
            throw 'Install manifest file receipts must contain only length, relativePath, and sha256.'
        }
        if (-not ($entry.relativePath -is [string]) -or -not ($entry.sha256 -is [string]) -or
            [string]$entry.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            -not ($entry.length -is [byte] -or $entry.length -is [int16] -or
                $entry.length -is [int32] -or $entry.length -is [int64]) -or
            [long]$entry.length -lt 0) {
            throw 'Install manifest contains invalid file integrity metadata.'
        }
        $relative = ConvertTo-CycStrictRelativePath -Path ([string]$entry.relativePath)
        if (-not $seen.Add($relative)) {
            throw "Install manifest contains a duplicate file receipt: $relative"
        }
        [void]$validated.Add([PSCustomObject][ordered]@{
            relativePath = $relative
            sha256 = [string]$entry.sha256
            length = [long]$entry.length
        })
    }
    [object[]]$all = [object[]]::new($validated.Count)
    $validated.CopyTo($all, 0)
    $payload = @($all | Where-Object {
        ([string]$_.relativePath).StartsWith($script:CodexMarketplacePrefix, [System.StringComparison]::Ordinal)
    })
    if ($payload.Count -lt 1) { throw 'Install manifest has no Codex marketplace payload catalog.' }
    $buildDigest = Get-CycFileCatalogDigest -Entries $all
    $payloadDigest = Get-CycFileCatalogDigest -Entries $payload
    $recordedBuild = Get-CycObjectProperty -Object $Manifest -Name 'buildCatalogSha256'
    $recordedPayload = Get-CycObjectProperty -Object $Manifest -Name 'codexPayloadCatalogSha256'
    if ($null -ne $recordedBuild -and [string]$recordedBuild -cne $buildDigest) {
        throw 'Install manifest build-catalog digest does not match its file receipts.'
    }
    if ($null -ne $recordedPayload -and [string]$recordedPayload -cne $payloadDigest) {
        throw 'Install manifest Codex payload-catalog digest does not match its file receipts.'
    }
    return [PSCustomObject]@{
        entries = $all
        payloadEntries = $payload
        buildCatalogSha256 = $buildDigest
        payloadCatalogSha256 = $payloadDigest
    }
}

function Assert-CycNoReparsePathChain {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Candidate,
        [ValidateSet('File', 'Directory')][string]$LeafType
    )
    $rootPath = Resolve-NormalizedPath $Root
    $target = Assert-ChildPath -Root $rootPath -Candidate $Candidate
    if (-not (Test-Path -LiteralPath $rootPath -PathType Container) -or
        (Test-ReparsePoint (Get-Item -LiteralPath $rootPath -Force))) {
        throw 'Integrity root must be a real directory.'
    }
    $relative = $target.Substring((Get-CycChildPrefix $rootPath).Length)
    $segments = @($relative.Split(@(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ), [System.StringSplitOptions]::RemoveEmptyEntries))
    if ($segments.Count -eq 0) { throw 'Integrity path must be below its root.' }
    $current = $rootPath
    for ($index = 0; $index -lt $segments.Count; $index++) {
        $current = Join-Path $current $segments[$index]
        $isLeaf = $index -eq ($segments.Count - 1)
        $expectedType = if ($isLeaf) { $LeafType } else { 'Directory' }
        $exists = if ($expectedType -eq 'File') {
            Test-Path -LiteralPath $current -PathType Leaf
        } else {
            Test-Path -LiteralPath $current -PathType Container
        }
        if (-not $exists) { throw "Integrity path is missing: $current" }
        $item = Get-Item -LiteralPath $current -Force
        if (Test-ReparsePoint $item) { throw "Integrity path contains a reparse point: $current" }
    }
    return $target
}

function Assert-CycCodexPayloadCatalog {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )
    $install = Resolve-NormalizedPath $InstallRoot
    $catalog = Get-CycManifestFileCatalog -Manifest $Manifest
    $marketplaceRoot = Assert-CycNoReparsePathChain `
        -Root $install `
        -Candidate (Join-Path $install $script:CodexMarketplaceRelativeRoot.Replace('/', '\')) `
        -LeafType Directory
    $expected = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $expectedDirectories = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($entry in $catalog.payloadEntries) {
        [void]$expected.Add([string]$entry.relativePath, $entry)
        $relativeToMarketplace = ([string]$entry.relativePath).Substring($script:CodexMarketplacePrefix.Length)
        $parts = @($relativeToMarketplace.Split('/'))
        for ($index = 1; $index -lt $parts.Count; $index++) {
            [void]$expectedDirectories.Add([string]::Join('/', $parts[0..($index - 1)]))
        }
    }
    $actual = [System.Collections.Generic.Dictionary[string, string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($item in @(Get-ChildItem -LiteralPath $marketplaceRoot -Recurse -Force)) {
        if (Test-ReparsePoint $item) {
            throw "Installed Codex marketplace contains a reparse point: $($item.FullName)"
        }
        if ($item.PSIsContainer) {
            $directoryRelative = Get-RelativeOwnedPath -Root $marketplaceRoot -Path $item.FullName
            if (-not $expectedDirectories.Contains($directoryRelative)) {
                throw "Installed Codex marketplace contains an extra directory: $directoryRelative"
            }
            continue
        }
        $relative = Get-RelativeOwnedPath -Root $install -Path $item.FullName
        if ($actual.ContainsKey($relative)) {
            throw "Installed Codex marketplace contains a case-colliding file: $relative"
        }
        $actual.Add($relative, $item.FullName)
    }
    if ($actual.Count -ne $expected.Count) {
        throw 'Installed Codex marketplace has missing or extra files.'
    }
    foreach ($pair in $actual.GetEnumerator()) {
        if (-not $expected.ContainsKey($pair.Key)) {
            throw "Installed Codex marketplace contains an extra file: $($pair.Key)"
        }
        $entry = $expected[$pair.Key]
        if ([string]$entry.relativePath -cne [string]$pair.Key) {
            throw "Installed Codex marketplace path casing drifted: $($pair.Key)"
        }
        $path = Assert-CycNoReparsePathChain -Root $install -Candidate $pair.Value -LeafType File
        $item = Get-Item -LiteralPath $path -Force
        if ([long]$item.Length -ne [long]$entry.length -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$entry.sha256) {
            throw "Installed Codex marketplace file failed length/SHA-256 verification: $($pair.Key)"
        }
    }
    return $catalog
}

function Get-CycObjectProperty {
    param(
        $Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) {
        return $Object.$Name
    }
    return $Default
}

function Enter-CycAgentsMutex {
    param([ValidateRange(1, 300)][int]$TimeoutSeconds = 120)
    $created = $false
    $mutex = [System.Threading.Mutex]::new($false, $script:AgentsMutexName, [ref]$created)
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
        } catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw 'Timed out waiting for the ClusterYourCodex global AGENTS.md transaction lock.'
        }
        return $mutex
    } catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-CycAgentsMutex {
    param($Mutex)
    if ($Mutex) {
        try { $Mutex.ReleaseMutex() } finally { $Mutex.Dispose() }
    }
}

function Assert-CycAgentsIntegrationRecord {
    param([Parameter(Mandatory = $true)]$Record)
    if ([string](Get-CycObjectProperty -Object $Record -Name 'schemaVersion') -cne
        $script:AgentsIntegrationSchema) {
        throw 'The recorded global AGENTS.md integration schema is unsupported.'
    }
    foreach ($required in @(
        'enabled', 'installed', 'path', 'codexHome', 'templateRelativePath',
        'templateSha256', 'encoding', 'baseFileExisted', 'baseFileSha256', 'baseFileLength',
        'installedFileSha256', 'installedFileLength', 'blockSha256',
        'prefixSha256', 'ownedPrefixBase64'
    )) {
        if (-not $Record.PSObject.Properties[$required]) {
            throw "The global AGENTS.md integration record is missing '$required'."
        }
    }
    if (-not [bool]$Record.enabled -or -not [bool]$Record.installed -or
        [string]::IsNullOrWhiteSpace([string]$Record.path) -or
        [string]::IsNullOrWhiteSpace([string]$Record.codexHome) -or
        [string]$Record.templateRelativePath -cne $script:AgentsTemplateRelativePath -or
        [string]$Record.encoding -cnotin @('utf8', 'utf8-bom', 'utf16-le', 'utf16-be') -or
        [long]$Record.baseFileLength -lt 0 -or [long]$Record.installedFileLength -lt 0) {
        throw 'The global AGENTS.md integration record has invalid metadata.'
    }
    foreach ($hashName in @('templateSha256', 'installedFileSha256', 'blockSha256', 'prefixSha256')) {
        if ([string]$Record.$hashName -cnotmatch '^[0-9a-f]{64}$') {
            throw "The global AGENTS.md integration record has an invalid $hashName."
        }
    }
    $baseHash = Get-CycObjectProperty -Object $Record -Name 'baseFileSha256'
    if ([bool]$Record.baseFileExisted) {
        if ([string]$baseHash -cnotmatch '^[0-9a-f]{64}$') {
            throw 'The global AGENTS.md integration record has an invalid base-file digest.'
        }
    } elseif ($null -ne $baseHash -and -not [string]::IsNullOrEmpty([string]$baseHash)) {
        throw 'An originally absent global AGENTS.md must not have a base-file digest.'
    }
    try {
        [byte[]]$prefixBytes = [System.Convert]::FromBase64String([string]$Record.ownedPrefixBase64)
        if ((Get-CycSha256Hex -Bytes $prefixBytes) -cne [string]$Record.prefixSha256) {
            throw 'digest mismatch'
        }
    } catch {
        throw 'The global AGENTS.md integration record has an invalid owned prefix.'
    }
    $extendedNames = @('externalSha256', 'externalLength', 'ownedRangeSha256', 'transactionId')
    $extendedCount = @($extendedNames | Where-Object { $Record.PSObject.Properties[$_] }).Count
    if ($extendedCount -ne 0 -and $extendedCount -ne $extendedNames.Count) {
        throw 'The global AGENTS.md integration record has a partial integrity-evidence extension.'
    }
    if ($extendedCount -eq $extendedNames.Count -and (
        [string]$Record.externalSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        [long]$Record.externalLength -lt 0 -or
        [string]$Record.ownedRangeSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$Record.transactionId -cnotmatch '^[0-9A-Za-z-]{1,128}$')) {
        throw 'The global AGENTS.md integration record has invalid extended integrity evidence.'
    }
}

function Resolve-CycCodexHome {
    param([string]$RequestedHome)
    $candidate = $RequestedHome
    if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $env:CODEX_HOME }
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
            throw 'USERPROFILE or an explicit CodexHome is required for global AGENTS.md integration.'
        }
        $candidate = Join-Path $env:USERPROFILE '.codex'
    }
    if (-not [System.IO.Path]::IsPathRooted($candidate) -or
        $candidate.Contains('"') -or $candidate.Contains("`r") -or $candidate.Contains("`n")) {
        throw 'CodexHome must be an absolute path without quotes or line breaks.'
    }
    $resolved = Resolve-NormalizedPath $candidate
    if (Test-Path -LiteralPath $resolved) {
        if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
            throw "CodexHome is not a directory: $resolved"
        }
        if (Test-ReparsePoint (Get-Item -LiteralPath $resolved -Force)) {
            throw 'CodexHome must not be a reparse point.'
        }
    }
    return $resolved
}

function Get-CycStrictTextDocument {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateRange(1, 67108864)][long]$MaxBytes = $script:MaxAgentsFileBytes
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return [PSCustomObject]@{
            path = $Path
            existed = $false
            bytes = [byte[]]@()
            text = ''
            encoding = [System.Text.UTF8Encoding]::new($false, $true)
            encodingName = 'utf8'
            preamble = [byte[]]@()
        }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "AGENTS.md path is not a regular file: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ((Test-ReparsePoint $item) -or $item.Length -gt $MaxBytes) {
        throw 'AGENTS.md must be a bounded regular file, not a reparse point.'
    }
    [byte[]]$bytes = [System.IO.File]::ReadAllBytes($Path)
    [byte[]]$preamble = @()
    $offset = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) {
        $encoding = [System.Text.UTF8Encoding]::new($false, $true)
        $encodingName = 'utf8-bom'
        $preamble = [byte[]]@(0xef, 0xbb, 0xbf)
        $offset = 3
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xff -and $bytes[1] -eq 0xfe) {
        $encoding = [System.Text.UnicodeEncoding]::new($false, $false, $true)
        $encodingName = 'utf16-le'
        $preamble = [byte[]]@(0xff, 0xfe)
        $offset = 2
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xfe -and $bytes[1] -eq 0xff) {
        $encoding = [System.Text.UnicodeEncoding]::new($true, $false, $true)
        $encodingName = 'utf16-be'
        $preamble = [byte[]]@(0xfe, 0xff)
        $offset = 2
    } else {
        $encoding = [System.Text.UTF8Encoding]::new($false, $true)
        $encodingName = 'utf8'
    }
    $bodyLength = $bytes.Length - $offset
    [byte[]]$body = New-Object byte[] $bodyLength
    if ($bodyLength -gt 0) {
        [System.Buffer]::BlockCopy($bytes, $offset, $body, 0, $bodyLength)
    }
    try { $text = $encoding.GetString($body) } catch {
        throw "AGENTS.md has invalid or unsupported text encoding: $Path"
    }
    if ($text.Contains("`0")) {
        throw 'AGENTS.md contains NUL characters and cannot be managed safely.'
    }
    return [PSCustomObject]@{
        path = $Path
        existed = $true
        bytes = $bytes
        text = $text
        encoding = $encoding
        encodingName = $encodingName
        preamble = $preamble
    }
}

function ConvertTo-CycDocumentBytes {
    param(
        [Parameter(Mandatory = $true)]$Document,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )
    [byte[]]$body = $Document.encoding.GetBytes($Text)
    [byte[]]$preamble = $Document.preamble
    [byte[]]$result = New-Object byte[] ($preamble.Length + $body.Length)
    if ($preamble.Length -gt 0) {
        [System.Buffer]::BlockCopy($preamble, 0, $result, 0, $preamble.Length)
    }
    if ($body.Length -gt 0) {
        [System.Buffer]::BlockCopy($body, 0, $result, $preamble.Length, $body.Length)
    }
    # Keep an empty byte array as a byte-array value instead of letting the
    # PowerShell pipeline erase it into $null.
    return ,$result
}

function Get-CycStringIndexes {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Value
    )
    $indexes = New-Object System.Collections.Generic.List[int]
    $offset = 0
    while ($offset -le $Text.Length - $Value.Length) {
        $index = $Text.IndexOf($Value, $offset, [System.StringComparison]::Ordinal)
        if ($index -lt 0) { break }
        [void]$indexes.Add($index)
        $offset = $index + $Value.Length
    }
    return @($indexes)
}

function Get-CycAgentsMarkerState {
    param([Parameter(Mandatory = $true)]$Document)
    $beginIndexes = @(Get-CycStringIndexes -Text $Document.text -Value $script:AgentsBeginMarker)
    $endIndexes = @(Get-CycStringIndexes -Text $Document.text -Value $script:AgentsEndMarker)
    if (($beginIndexes.Count -eq 0) -xor ($endIndexes.Count -eq 0)) {
        throw 'Global AGENTS.md has a half-present ClusterYourCodex managed marker pair.'
    }
    if ($beginIndexes.Count -gt 1 -or $endIndexes.Count -gt 1) {
        throw 'Global AGENTS.md has duplicate or nested ClusterYourCodex managed markers.'
    }
    if ($beginIndexes.Count -eq 1 -and $beginIndexes[0] -ge $endIndexes[0]) {
        throw 'Global AGENTS.md has an invalid ClusterYourCodex managed marker order.'
    }
    if ($beginIndexes.Count -eq 0) {
        return [PSCustomObject]@{ present = $false; beginIndex = -1; endExclusive = -1; blockText = $null }
    }
    $endExclusive = $endIndexes[0] + $script:AgentsEndMarker.Length
    return [PSCustomObject]@{
        present = $true
        beginIndex = [int]$beginIndexes[0]
        endExclusive = [int]$endExclusive
        blockText = $Document.text.Substring($beginIndexes[0], $endExclusive - $beginIndexes[0])
    }
}

function Read-CycAgentsTemplate {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "ClusterYourCodex AGENTS.md block template is missing: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ((Test-ReparsePoint $item) -or $item.Length -lt 1 -or $item.Length -gt 64KB) {
        throw 'ClusterYourCodex AGENTS.md block template must be a bounded regular file.'
    }
    [byte[]]$bytes = [System.IO.File]::ReadAllBytes($Path)
    $offset = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and
        $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) { 3 } else { 0 }
    [byte[]]$body = New-Object byte[] ($bytes.Length - $offset)
    if ($body.Length -gt 0) { [System.Buffer]::BlockCopy($bytes, $offset, $body, 0, $body.Length) }
    $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
    try { $text = $strictUtf8.GetString($body) } catch {
        throw 'ClusterYourCodex AGENTS.md block template must be valid UTF-8.'
    }
    $normalized = $text.Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd([char[]]@("`n"))
    $beginIndexes = @(Get-CycStringIndexes -Text $normalized -Value $script:AgentsBeginMarker)
    $endIndexes = @(Get-CycStringIndexes -Text $normalized -Value $script:AgentsEndMarker)
    if ($beginIndexes.Count -ne 1 -or $endIndexes.Count -ne 1 -or
        $beginIndexes[0] -ne 0 -or
        ($endIndexes[0] + $script:AgentsEndMarker.Length) -ne $normalized.Length) {
        throw 'ClusterYourCodex AGENTS.md block template must contain exactly one complete outer marker pair.'
    }
    return [PSCustomObject]@{
        text = $normalized
        sha256 = Get-CycSha256Hex -Bytes $bytes
    }
}

function Get-CycDocumentNewline {
    param([Parameter(Mandatory = $true)]$Document)
    if ($Document.text.Contains("`r`n")) { return "`r`n" }
    if ($Document.text.Contains("`n")) { return "`n" }
    if ($Document.text.Contains("`r")) { return "`r" }
    return "`r`n"
}

function Get-CycOwnedAgentsPrefix {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Newline
    )
    if ($Text.Length -eq 0) { return '' }
    $double = $Newline + $Newline
    if ($Text.EndsWith($double, [System.StringComparison]::Ordinal)) { return '' }
    if ($Text.EndsWith($Newline, [System.StringComparison]::Ordinal)) { return $Newline }
    return $double
}

function Write-CycDurableAtomicBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][byte[]]$Bytes
    )
    if ($null -eq $Bytes) { $Bytes = [byte[]]@() }
    $directory = Split-Path -Parent $Path
    if (Test-Path -LiteralPath $directory) {
        $directoryItem = Get-Item -LiteralPath $directory -Force
        if (-not $directoryItem.PSIsContainer -or (Test-ReparsePoint $directoryItem)) {
            throw "AGENTS.md parent must be a real directory: $directory"
        }
    } else {
        Assert-CycCreationPathNoReparse -Path $directory
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    if (Test-Path -LiteralPath $Path) {
        $targetItem = Get-Item -LiteralPath $Path -Force
        if ($targetItem.PSIsContainer -or (Test-ReparsePoint $targetItem)) {
            throw 'AGENTS.md target must be a regular file, not a directory or reparse point.'
        }
    }
    $leaf = Split-Path -Leaf $Path
    $temporary = Join-Path $directory ($leaf + '.cyc-tmp-' + [Guid]::NewGuid().ToString('N'))
    $backup = Join-Path $directory ($leaf + '.cyc-bak-' + [Guid]::NewGuid().ToString('N'))
    $stream = $null
    $backupStream = $null
    $backupCreated = $false
    $backupPrepared = $false
    $committed = $false
    $operationError = $null
    try {
        $stream = [System.IO.FileStream]::new(
            $temporary,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None,
            4096,
            [System.IO.FileOptions]::WriteThrough
        )
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            # Windows PowerShell/.NET Framework requires the backup operand of
            # File.Replace to already be a same-volume regular file.  Passing
            # a merely planned path fails after the temporary payload was
            # durably written, so create and flush the unique sibling first.
            $backupStream = [System.IO.FileStream]::new(
                $backup,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None,
                1,
                [System.IO.FileOptions]::WriteThrough
            )
            $backupCreated = $true
            $backupStream.Flush($true)
            $backupPrepared = $true
            $backupStream.Dispose()
            $backupStream = $null
            [System.IO.File]::Replace($temporary, $Path, $backup, $true)
        } else {
            [System.IO.File]::Move($temporary, $Path)
        }
        # Replace/move is the commit point.  Mark it before the post-commit
        # flush so a failure reopening the destination cannot leak the backup.
        $committed = $true
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
    } catch {
        # Preserve the writer's primary failure even if best-effort cleanup
        # below encounters a second, unrelated failure.
        $operationError = $_
        throw
    } finally {
        $cleanupError = $null
        if ($stream) {
            try { $stream.Dispose() } catch {
                $cleanupError = $_
            }
        }
        if ($backupStream) {
            try { $backupStream.Dispose() } catch {
                if ($null -eq $cleanupError) { $cleanupError = $_ }
            }
        }
        try {
            if (Test-Path -LiteralPath $temporary) {
                Remove-Item -LiteralPath $temporary -Force
            }
        } catch {
            if ($null -eq $cleanupError) { $cleanupError = $_ }
        }
        try {
            if (($committed -or $backupCreated -or $backupPrepared) -and
                (Test-Path -LiteralPath $backup)) {
                Remove-Item -LiteralPath $backup -Force
            }
        } catch {
            if ($null -eq $cleanupError) { $cleanupError = $_ }
        }
        if ($null -ne $cleanupError -and $null -eq $operationError) {
            throw $cleanupError
        }
    }
}

function New-CycDisabledAgentsIntegrationRecord {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [string]$Reason = 'plugin-not-active'
    )
    return [PSCustomObject][ordered]@{
        schemaVersion = $script:AgentsIntegrationSchema
        enabled = $false
        installed = $false
        path = $Plan.agentsIntegration.agentsPath
        codexHome = $Plan.agentsIntegration.codexHome
        templateRelativePath = $Plan.agentsIntegration.templateRelativePath
        activationRequired = $true
        reason = $Reason
        changed = $false
    }
}

function Get-CycAgentsInstallMutation {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        $OldManifest,
        $PluginReceipt
    )
    $oldRecord = if ($OldManifest -and $OldManifest.PSObject.Properties['agentsIntegration']) {
        $OldManifest.agentsIntegration
    } else { $null }
    $oldInstalled = [bool](
        $oldRecord -and
        (Get-CycObjectProperty -Object $oldRecord -Name 'enabled' -Default $false) -and
        (Get-CycObjectProperty -Object $oldRecord -Name 'installed' -Default $false)
    )
    if (-not $Plan.agentsIntegration.enabled) {
        if ($oldInstalled) {
            throw 'Repair cannot disable an existing managed AGENTS.md block; uninstall it first.'
        }
        return [PSCustomObject]@{
            disabled = $true
            record = New-CycDisabledAgentsIntegrationRecord -Plan $Plan -Reason 'integration-disabled'
        }
    }

    $agentsPath = Resolve-NormalizedPath $Plan.agentsIntegration.agentsPath
    if ($oldInstalled) {
        Assert-CycAgentsIntegrationRecord -Record $oldRecord
        $oldPath = Resolve-NormalizedPath ([string](Get-CycObjectProperty -Object $oldRecord -Name 'path'))
        if (-not [string]::Equals($oldPath, $agentsPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'CodexHome changed while a managed AGENTS.md block is installed; repair fails closed.'
        }
    }

    $template = Read-CycAgentsTemplate -Path $Plan.agentsIntegration.templatePath
    $document = Get-CycStrictTextDocument -Path $agentsPath
    $markerState = Get-CycAgentsMarkerState -Document $document
    if ($markerState.present -and -not $oldInstalled) {
        throw 'Global AGENTS.md already contains an unowned ClusterYourCodex marker pair.'
    }
    if (-not $markerState.present -and $oldInstalled) {
        throw 'The recorded ClusterYourCodex block is missing from global AGENTS.md.'
    }

    $previousFileSha256 = if ($document.existed) { Get-CycSha256Hex -Bytes $document.bytes } else { $null }
    $newline = if ($markerState.present) {
        Get-CycDocumentNewline -Document ([PSCustomObject]@{ text = $markerState.blockText })
    } else {
        Get-CycDocumentNewline -Document $document
    }
    $canonicalBlock = $template.text.Replace("`n", $newline)
    [byte[]]$canonicalBlockBytes = $document.encoding.GetBytes($canonicalBlock)
    $blockSha256 = Get-CycSha256Hex -Bytes $canonicalBlockBytes

    if ($markerState.present) {
        $expectedEncoding = [string](Get-CycObjectProperty -Object $oldRecord -Name 'encoding')
        if ($expectedEncoding -cne [string]$document.encodingName) {
            throw 'Global AGENTS.md encoding changed while its managed block was installed.'
        }
        [byte[]]$currentBlockBytes = $document.encoding.GetBytes($markerState.blockText)
        $recordedBlockHash = [string](Get-CycObjectProperty -Object $oldRecord -Name 'blockSha256')
        if ($recordedBlockHash -cnotmatch '^[0-9a-f]{64}$' -or
            (Get-CycSha256Hex -Bytes $currentBlockBytes) -cne $recordedBlockHash) {
            throw 'The ClusterYourCodex managed block has drifted; repair fails closed.'
        }
        $prefixBase64 = [string](Get-CycObjectProperty -Object $oldRecord -Name 'ownedPrefixBase64')
        try {
            [byte[]]$prefixBytes = [System.Convert]::FromBase64String($prefixBase64)
            $ownedPrefix = $document.encoding.GetString($prefixBytes)
        } catch {
            throw 'The recorded ClusterYourCodex AGENTS.md prefix is invalid.'
        }
        $prefixStart = $markerState.beginIndex - $ownedPrefix.Length
        if ($prefixStart -lt 0 -or
            $document.text.Substring($prefixStart, $ownedPrefix.Length) -cne $ownedPrefix) {
            throw 'The separator before the ClusterYourCodex managed block has drifted.'
        }
        $outputText = $document.text.Substring(0, $markerState.beginIndex) +
            $canonicalBlock + $document.text.Substring($markerState.endExclusive)
        $externalText = $document.text.Substring(0, $prefixStart) +
            $document.text.Substring($markerState.endExclusive)
        $baseFileExisted = [bool](Get-CycObjectProperty -Object $oldRecord -Name 'baseFileExisted')
        $baseFileSha256 = Get-CycObjectProperty -Object $oldRecord -Name 'baseFileSha256'
        $baseFileLength = Get-CycObjectProperty -Object $oldRecord -Name 'baseFileLength' -Default 0
        $operation = 'Replaced'
    } else {
        $ownedPrefix = Get-CycOwnedAgentsPrefix -Text $document.text -Newline $newline
        $outputText = $document.text + $ownedPrefix + $canonicalBlock
        $externalText = $document.text
        $baseFileExisted = [bool]$document.existed
        $baseFileSha256 = $previousFileSha256
        $baseFileLength = [long]$document.bytes.Length
        $operation = 'Added'
    }

    [byte[]]$ownedPrefixBytes = $document.encoding.GetBytes($ownedPrefix)
    [byte[]]$ownedRangeBytes = $document.encoding.GetBytes($ownedPrefix + $canonicalBlock)
    [byte[]]$externalBytes = ConvertTo-CycDocumentBytes -Document $document -Text $externalText
    [byte[]]$outputBytes = ConvertTo-CycDocumentBytes -Document $document -Text $outputText
    $installedFileSha256 = Get-CycSha256Hex -Bytes $outputBytes
    $changed = (-not $document.existed) -or
        $document.bytes.Length -ne $outputBytes.Length -or
        $previousFileSha256 -cne $installedFileSha256
    if (-not $changed) {
        $operation = 'Unchanged'
    }
    $prefixSha256 = Get-CycSha256Hex -Bytes $ownedPrefixBytes
    $record = [PSCustomObject][ordered]@{
        schemaVersion = $script:AgentsIntegrationSchema
        enabled = $true
        installed = $true
        path = $agentsPath
        codexHome = $Plan.agentsIntegration.codexHome
        templateRelativePath = $Plan.agentsIntegration.templateRelativePath
        templateSha256 = $template.sha256
        encoding = $document.encodingName
        baseFileExisted = $baseFileExisted
        baseFileSha256 = $baseFileSha256
        baseFileLength = [long]$baseFileLength
        previousFileExisted = [bool]$document.existed
        previousFileSha256 = $previousFileSha256
        previousFileLength = [long]$document.bytes.Length
        installedFileSha256 = $installedFileSha256
        installedFileLength = [long]$outputBytes.Length
        blockSha256 = $blockSha256
        prefixSha256 = $prefixSha256
        ownedPrefixBase64 = [System.Convert]::ToBase64String($ownedPrefixBytes)
        externalSha256 = Get-CycSha256Hex -Bytes $externalBytes
        externalLength = [long]$externalBytes.Length
        ownedRangeSha256 = Get-CycSha256Hex -Bytes $ownedRangeBytes
        pluginActivationVerified = [bool]($PluginReceipt -and
            (Get-CycObjectProperty -Object $PluginReceipt -Name 'pluginVerified' -Default $false))
        pluginActivationMethod = if ($PluginReceipt) { 'codex-plugin-list-json' } else { 'direct-test-harness' }
        operation = $operation
        changed = [bool]$changed
        installedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    return [PSCustomObject]@{
        disabled = $false
        oldRecord = $oldRecord
        oldInstalled = $oldInstalled
        document = $document
        beforeExisted = [bool]$document.existed
        beforeSha256 = $previousFileSha256
        beforeBytes = [byte[]]$document.bytes
        afterExisted = $true
        afterSha256 = $installedFileSha256
        afterBytes = [byte[]]$outputBytes
        templateSha256 = $template.sha256
        blockSha256 = $blockSha256
        prefixSha256 = $prefixSha256
        record = $record
    }
}

function Set-CycAgentsContentCas {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][bool]$ExpectedExisted,
        [AllowNull()][string]$ExpectedSha256,
        [Parameter(Mandatory = $true)][bool]$NewExisted,
        [AllowNull()][AllowEmptyCollection()][byte[]]$NewBytes
    )
    $mutex = Enter-CycAgentsMutex
    try {
        $current = Get-CycStrictTextDocument -Path $Path
        $currentHash = if ($current.existed) { Get-CycSha256Hex -Bytes $current.bytes } else { $null }
        if ([bool]$current.existed -ne $ExpectedExisted -or
            ($ExpectedExisted -and $currentHash -cne [string]$ExpectedSha256)) {
            throw 'Global AGENTS.md compare-and-swap precondition failed.'
        }
        if ($NewExisted) {
            if ($null -eq $NewBytes) { $NewBytes = [byte[]]@() }
            Write-CycDurableAtomicBytes -Path $Path -Bytes $NewBytes
        } elseif ($ExpectedExisted) {
            # Product lifecycle calls are serialized by the named mutex, and
            # deletion is permitted only for the exact expected after-image.
            $lastCheck = Get-CycStrictTextDocument -Path $Path
            if (-not $lastCheck.existed -or
                (Get-CycSha256Hex -Bytes $lastCheck.bytes) -cne [string]$ExpectedSha256) {
                throw 'Global AGENTS.md changed before compare-and-swap deletion.'
            }
            $item = Get-Item -LiteralPath $Path -Force
            if ($item.PSIsContainer -or (Test-ReparsePoint $item)) {
                throw 'Refusing to delete a non-regular AGENTS.md.'
            }
            Remove-Item -LiteralPath $Path -Force
        }
        $verified = Get-CycStrictTextDocument -Path $Path
        if ([bool]$verified.existed -ne $NewExisted) {
            throw 'Global AGENTS.md compare-and-swap existence verification failed.'
        }
        if ($NewExisted) {
            $expectedNewHash = Get-CycSha256Hex -Bytes $NewBytes
            if ((Get-CycSha256Hex -Bytes $verified.bytes) -cne $expectedNewHash) {
                throw 'Global AGENTS.md compare-and-swap digest verification failed.'
            }
        }
    } finally {
        Exit-CycAgentsMutex -Mutex $mutex
    }
}

function Read-CycAgentsJournal {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Global AGENTS.md transaction journal is missing: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ((Test-ReparsePoint $item) -or $item.Length -lt 2 -or $item.Length -gt 2MB) {
        throw 'Global AGENTS.md transaction journal is not a bounded regular file.'
    }
    try { $journal = Read-CycUtf8Json -Path $Path } catch {
        throw 'Global AGENTS.md transaction journal contains invalid JSON.'
    }
    if ([string](Get-CycObjectProperty -Object $journal -Name 'schemaVersion') -cne $script:AgentsJournalSchema -or
        [string](Get-CycObjectProperty -Object $journal -Name 'operation') -cnotin @('InstallOrRepair', 'Uninstall') -or
        [string](Get-CycObjectProperty -Object $journal -Name 'phase') -cnotin @('prepared', 'applied', 'committed', 'rolled-back')) {
        throw 'Global AGENTS.md transaction journal metadata is unsupported.'
    }
    foreach ($name in @('agentsPath', 'codexHome', 'beforeExisted', 'beforeLength',
        'beforeImageSha256', 'afterExisted', 'afterLength', 'afterImageSha256')) {
        if (-not $journal.PSObject.Properties[$name]) {
            throw "Global AGENTS.md transaction journal is missing '$name'."
        }
    }
    $codexHome = Resolve-CycCodexHome -RequestedHome ([string]$journal.codexHome)
    $expectedPath = Resolve-NormalizedPath (Join-Path $codexHome 'AGENTS.md')
    if (-not [string]::Equals(
        $expectedPath,
        (Resolve-NormalizedPath ([string]$journal.agentsPath)),
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Global AGENTS.md transaction journal contains an invalid target path.'
    }
    return $journal
}

function Get-CycAgentsJournalImages {
    param(
        [Parameter(Mandatory = $true)]$Journal,
        [Parameter(Mandatory = $true)][string]$JournalPath
    )
    $root = Split-Path -Parent $JournalPath
    $beforePath = Join-Path $root 'before.bin'
    $afterPath = Join-Path $root 'after.bin'
    foreach ($entry in @(
        [PSCustomObject]@{ path = $beforePath; hash = [string]$Journal.beforeImageSha256; length = [long]$Journal.beforeLength },
        [PSCustomObject]@{ path = $afterPath; hash = [string]$Journal.afterImageSha256; length = [long]$Journal.afterLength }
    )) {
        if (-not (Test-Path -LiteralPath $entry.path -PathType Leaf)) {
            throw 'Global AGENTS.md transaction image is missing.'
        }
        $imageItem = Get-Item -LiteralPath $entry.path -Force
        if ((Test-ReparsePoint $imageItem) -or $imageItem.Length -ne $entry.length -or
            $entry.hash -cnotmatch '^[0-9a-f]{64}$') {
            throw 'Global AGENTS.md transaction image metadata is invalid.'
        }
        [byte[]]$imageBytes = [System.IO.File]::ReadAllBytes($entry.path)
        if ((Get-CycSha256Hex -Bytes $imageBytes) -cne $entry.hash) {
            throw 'Global AGENTS.md transaction image failed SHA-256 validation.'
        }
    }
    return [PSCustomObject]@{
        beforePath = $beforePath
        afterPath = $afterPath
        beforeBytes = [System.IO.File]::ReadAllBytes($beforePath)
        afterBytes = [System.IO.File]::ReadAllBytes($afterPath)
    }
}

function Set-CycAgentsJournalPhase {
    param(
        [Parameter(Mandatory = $true)][string]$JournalPath,
        [Parameter(Mandatory = $true)]$Journal,
        [ValidateSet('prepared', 'applied', 'committed', 'rolled-back')][string]$Phase
    )
    $Journal.phase = $Phase
    $property = switch ($Phase) {
        'applied' { 'appliedAtUtc' }
        'committed' { 'committedAtUtc' }
        'rolled-back' { 'rolledBackAtUtc' }
        default { 'preparedAtUtc' }
    }
    $value = [DateTime]::UtcNow.ToString('o')
    if ($Journal.PSObject.Properties[$property]) { $Journal.$property = $value }
    else { $Journal | Add-Member -NotePropertyName $property -NotePropertyValue $value }
    Write-DurableAtomicJson -Path $JournalPath -Value $Journal -Depth 20
    # File.Replace publishes a fresh sibling whose ACL may be inherited from
    # the parent. Re-assert the private transaction tree after every journal
    # phase transition so restart recovery can verify before it reads again.
    Set-PrivateDirectoryAcl -Path (Split-Path -Parent $JournalPath)
}

function Start-CycAgentsInstallTransaction {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        $OldManifest,
        [Parameter(Mandatory = $true)][string]$TransactionRoot,
        $PluginReceipt,
        [switch]$AllowUnverifiedTestHarness
    )
    $mutation = Get-CycAgentsInstallMutation -Plan $Plan -OldManifest $OldManifest -PluginReceipt $PluginReceipt
    if ($mutation.disabled) {
        return [PSCustomObject]@{ disabled = $true; record = $mutation.record }
    }
    if (-not [bool]($PluginReceipt -and
        (Get-CycObjectProperty -Object $PluginReceipt -Name 'pluginVerified' -Default $false)) -and
        -not $AllowUnverifiedTestHarness) {
        throw 'Global AGENTS.md integration requires a verified active-plugin receipt.'
    }
    $transactionId = Split-Path -Leaf (Resolve-NormalizedPath $TransactionRoot)
    if ([string]::IsNullOrWhiteSpace($transactionId) -or
        $transactionId -cnotmatch '^[0-9A-Za-z-]{1,128}$') {
        throw 'Global AGENTS.md transaction identifier is invalid.'
    }
    if ($mutation.record.PSObject.Properties['transactionId']) {
        $mutation.record.transactionId = $transactionId
    } else {
        $mutation.record | Add-Member -NotePropertyName transactionId -NotePropertyValue $transactionId
    }
    $root = Join-Path (Resolve-NormalizedPath $TransactionRoot) 'global-agents'
    if (Test-Path -LiteralPath (Join-Path $root 'journal.json')) {
        throw 'A global AGENTS.md transaction already exists in this installer transaction.'
    }
    Assert-CycCreationPathNoReparse -Path $root
    [void](New-Item -ItemType Directory -Path $root -Force)
    $beforePath = Join-Path $root 'before.bin'
    $afterPath = Join-Path $root 'after.bin'
    Write-CycDurableAtomicBytes -Path $beforePath -Bytes $mutation.beforeBytes
    Write-CycDurableAtomicBytes -Path $afterPath -Bytes $mutation.afterBytes
    $journalPath = Join-Path $root 'journal.json'
    $journal = [PSCustomObject][ordered]@{
        schemaVersion = $script:AgentsJournalSchema
        operation = 'InstallOrRepair'
        phase = 'prepared'
        preparedAtUtc = [DateTime]::UtcNow.ToString('o')
        transactionId = $transactionId
        agentsPath = $mutation.record.path
        codexHome = $mutation.record.codexHome
        originalExisted = [bool]$mutation.beforeExisted
        beforeExisted = [bool]$mutation.beforeExisted
        beforeFileSha256 = $mutation.beforeSha256
        beforeLength = [long]$mutation.beforeBytes.Length
        beforeImageSha256 = Get-CycSha256Hex -Bytes $mutation.beforeBytes
        afterExisted = $true
        afterFileSha256 = $mutation.afterSha256
        afterLength = [long]$mutation.afterBytes.Length
        afterImageSha256 = Get-CycSha256Hex -Bytes $mutation.afterBytes
        templateSha256 = $mutation.templateSha256
        blockSha256 = $mutation.blockSha256
        prefixSha256 = $mutation.prefixSha256
        previousRecord = $mutation.oldRecord
        receipt = $mutation.record
    }
    # before.bin and after.bin are durable before the prepared journal is
    # published. AGENTS.md is not mutated until that journal verifies.
    Write-DurableAtomicJson -Path $journalPath -Value $journal -Depth 20
    Set-PrivateDirectoryAcl -Path $root
    $prepared = Read-CycAgentsJournal -Path $journalPath
    $transaction = [PSCustomObject]@{
        disabled = $false
        root = $root
        journalPath = $journalPath
        journal = $prepared
        record = $mutation.record
    }
    try {
        [void](Get-CycAgentsJournalImages -Journal $prepared -JournalPath $journalPath)
        if ([string]$prepared.templateSha256 -cne [string]$mutation.templateSha256 -or
            [string]$prepared.blockSha256 -cne [string]$mutation.blockSha256 -or
            [string]$prepared.prefixSha256 -cne [string]$mutation.prefixSha256) {
            throw 'Global AGENTS.md prepared journal digest verification failed.'
        }
        if ($mutation.record.changed) {
            Set-CycAgentsContentCas `
                -Path $mutation.record.path `
                -ExpectedExisted ([bool]$mutation.beforeExisted) `
                -ExpectedSha256 $mutation.beforeSha256 `
                -NewExisted $true `
                -NewBytes $mutation.afterBytes
        }
        $verified = Get-CycStrictTextDocument -Path $mutation.record.path
        $verifiedState = Get-CycAgentsMarkerState -Document $verified
        if (-not $verifiedState.present -or
            (Get-CycSha256Hex -Bytes $verified.bytes) -cne [string]$mutation.afterSha256 -or
            (Get-CycSha256Hex -Bytes $verified.encoding.GetBytes($verifiedState.blockText)) -cne [string]$mutation.blockSha256) {
            throw 'Global AGENTS.md managed-block transaction verification failed.'
        }
        Set-CycAgentsJournalPhase -JournalPath $journalPath -Journal $prepared -Phase applied
        return $transaction
    } catch {
        $failure = $_
        try {
            Rollback-CycAgentsInstallTransaction -Transaction $transaction
        } catch {
            throw "Global AGENTS.md transaction failed and its range rollback is incomplete; the journal was retained. Original failure: $($failure.Exception.Message)"
        }
        throw $failure
    }
}

function Complete-CycAgentsInstallTransaction {
    # A disabled integration intentionally has no transaction to commit. Keep
    # the no-op contract reachable instead of letting parameter binding reject
    # the null value before the guard below executes.
    param($Transaction)
    if (-not $Transaction -or $Transaction.disabled) { return }
    $journal = Read-CycAgentsJournal -Path $Transaction.journalPath
    if ([string]$journal.operation -cne 'InstallOrRepair') {
        throw 'Cannot commit a non-install AGENTS.md transaction as an install.'
    }
    Set-CycAgentsJournalPhase -JournalPath $Transaction.journalPath -Journal $journal -Phase committed
}

function Test-CycAgentsRecordPresent {
    param([Parameter(Mandatory = $true)]$Record)
    try {
        Assert-CycAgentsIntegrationRecord -Record $Record
        $document = Get-CycStrictTextDocument -Path ([string]$Record.path)
        if (-not $document.existed -or [string]$document.encodingName -cne [string]$Record.encoding) { return $false }
        $state = Get-CycAgentsMarkerState -Document $document
        if (-not $state.present) { return $false }
        [byte[]]$blockBytes = $document.encoding.GetBytes($state.blockText)
        if ((Get-CycSha256Hex -Bytes $blockBytes) -cne [string]$Record.blockSha256) { return $false }
        [byte[]]$prefixBytes = [Convert]::FromBase64String([string]$Record.ownedPrefixBase64)
        $prefix = $document.encoding.GetString($prefixBytes)
        $start = $state.beginIndex - $prefix.Length
        return $start -ge 0 -and $document.text.Substring($start, $prefix.Length) -ceq $prefix
    } catch { return $false }
}

function Get-CycStrictAgentsEvidence {
    param([Parameter(Mandatory = $true)]$Record)
    Assert-CycAgentsIntegrationRecord -Record $Record
    foreach ($name in @('externalSha256', 'externalLength', 'ownedRangeSha256', 'transactionId')) {
        if (-not $Record.PSObject.Properties[$name]) {
            throw "Global AGENTS.md evidence is missing '$name'."
        }
    }
    $document = Get-CycStrictTextDocument -Path ([string]$Record.path)
    if (-not $document.existed -or [string]$document.encodingName -cne [string]$Record.encoding -or
        [long]$document.bytes.Length -ne [long]$Record.installedFileLength -or
        (Get-CycSha256Hex -Bytes $document.bytes) -cne [string]$Record.installedFileSha256) {
        throw 'Global AGENTS.md full-file receipt drifted.'
    }
    $state = Get-CycAgentsMarkerState -Document $document
    if (-not $state.present) { throw 'Global AGENTS.md does not contain exactly one managed block.' }
    [byte[]]$blockBytes = $document.encoding.GetBytes($state.blockText)
    if ((Get-CycSha256Hex -Bytes $blockBytes) -cne [string]$Record.blockSha256) {
        throw 'Global AGENTS.md managed-block digest drifted.'
    }
    try {
        [byte[]]$prefixBytes = [Convert]::FromBase64String([string]$Record.ownedPrefixBase64)
        $prefixText = $document.encoding.GetString($prefixBytes)
    } catch {
        throw 'Global AGENTS.md owned prefix is invalid.'
    }
    if ((Get-CycSha256Hex -Bytes $prefixBytes) -cne [string]$Record.prefixSha256) {
        throw 'Global AGENTS.md owned-prefix digest drifted.'
    }
    $prefixStart = $state.beginIndex - $prefixText.Length
    if ($prefixStart -lt 0 -or
        $document.text.Substring($prefixStart, $prefixText.Length) -cne $prefixText) {
        throw 'Global AGENTS.md owned prefix is no longer adjacent to the managed block.'
    }
    [byte[]]$ownedRangeBytes = $document.encoding.GetBytes($prefixText + $state.blockText)
    if ((Get-CycSha256Hex -Bytes $ownedRangeBytes) -cne [string]$Record.ownedRangeSha256) {
        throw 'Global AGENTS.md owned-range digest drifted.'
    }
    $externalText = $document.text.Substring(0, $prefixStart) +
        $document.text.Substring($state.endExclusive)
    [byte[]]$externalBytes = ConvertTo-CycDocumentBytes -Document $document -Text $externalText
    if ([long]$externalBytes.Length -ne [long]$Record.externalLength -or
        (Get-CycSha256Hex -Bytes $externalBytes) -cne [string]$Record.externalSha256) {
        throw 'Global AGENTS.md bytes outside the managed range drifted.'
    }
    return [PSCustomObject][ordered]@{
        agentsFileSha256 = [string]$Record.installedFileSha256
        agentsBlockSha256 = [string]$Record.blockSha256
        agentsExternalSha256 = [string]$Record.externalSha256
        agentsOwnedRangeSha256 = [string]$Record.ownedRangeSha256
    }
}

function Test-CycManifestOwnsAgentsReceipt {
    param($Manifest, [Parameter(Mandatory = $true)]$Receipt)
    if (-not $Manifest -or -not $Manifest.PSObject.Properties['agentsIntegration']) { return $false }
    $record = $Manifest.agentsIntegration
    foreach ($name in @('path', 'installedFileSha256', 'blockSha256', 'templateSha256')) {
        if ([string](Get-CycObjectProperty -Object $record -Name $name) -cne
            [string](Get-CycObjectProperty -Object $Receipt -Name $name)) { return $false }
    }
    $receiptTransactionId = [string](Get-CycObjectProperty -Object $Receipt -Name 'transactionId')
    if (-not [string]::IsNullOrWhiteSpace($receiptTransactionId) -and
        [string](Get-CycObjectProperty -Object $record -Name 'transactionId') -cne $receiptTransactionId) {
        return $false
    }
    return [bool](Get-CycObjectProperty -Object $record -Name 'installed' -Default $false)
}

function Rollback-CycAgentsInstallTransaction {
    param($Transaction)
    if (-not $Transaction -or $Transaction.disabled) { return }
    $journalPath = [string]$Transaction.journalPath
    $journal = Read-CycAgentsJournal -Path $journalPath
    if ([string]$journal.operation -cne 'InstallOrRepair') {
        throw 'Cannot roll back a non-install AGENTS.md transaction as an install.'
    }
    if ([string]$journal.phase -ceq 'rolled-back') { return }
    if ([string]$journal.phase -ceq 'committed') {
        throw 'A committed global AGENTS.md install transaction cannot be rolled back.'
    }
    $images = Get-CycAgentsJournalImages -Journal $journal -JournalPath $journalPath
    $current = Get-CycStrictTextDocument -Path ([string]$journal.agentsPath)
    $currentHash = if ($current.existed) { Get-CycSha256Hex -Bytes $current.bytes } else { $null }
    $matchesBefore = [bool]$current.existed -eq [bool]$journal.beforeExisted -and
        ((-not [bool]$journal.beforeExisted) -or $currentHash -ceq [string]$journal.beforeFileSha256)
    if ($matchesBefore) {
        Set-CycAgentsJournalPhase -JournalPath $journalPath -Journal $journal -Phase 'rolled-back'
        return
    }
    $receipt = $journal.receipt
    if ([string]$receipt.operation -ceq 'Added') {
        $state = Get-CycAgentsMarkerState -Document $current
        if (-not $state.present) {
            Set-CycAgentsJournalPhase -JournalPath $journalPath -Journal $journal -Phase 'rolled-back'
            return
        }
    } elseif ([string]$receipt.operation -in @('Replaced', 'Unchanged') -and
        $journal.previousRecord -and (Test-CycAgentsRecordPresent -Record $journal.previousRecord)) {
        Set-CycAgentsJournalPhase -JournalPath $journalPath -Journal $journal -Phase 'rolled-back'
        return
    }
    if (-not (Test-CycAgentsRecordPresent -Record $receipt)) {
        throw 'Global AGENTS.md no longer contains the exact transaction-owned block; rollback fails closed.'
    }
    if ([string]$receipt.operation -ceq 'Added') {
        $removal = Get-CycAgentsRemovalPlan -Record $receipt
        Remove-CycAgentsManagedBlock -RemovalPlan $removal
    } elseif ([string]$receipt.operation -in @('Replaced', 'Unchanged')) {
        if (-not [bool]$journal.beforeExisted) {
            throw 'A replace transaction has no valid before-image.'
        }
        $beforeDocument = Get-CycStrictTextDocument -Path $images.beforePath
        $beforeState = Get-CycAgentsMarkerState -Document $beforeDocument
        if (-not $beforeState.present) {
            throw 'The replace transaction before-image has no owned block.'
        }
        $current = Get-CycStrictTextDocument -Path ([string]$journal.agentsPath)
        $currentState = Get-CycAgentsMarkerState -Document $current
        if (-not $currentState.present) {
            throw 'The replacement block disappeared before rollback.'
        }
        $restoredText = $current.text.Substring(0, $currentState.beginIndex) +
            $beforeState.blockText + $current.text.Substring($currentState.endExclusive)
        [byte[]]$restoredBytes = ConvertTo-CycDocumentBytes -Document $current -Text $restoredText
        Set-CycAgentsContentCas `
            -Path ([string]$journal.agentsPath) `
            -ExpectedExisted $true `
            -ExpectedSha256 (Get-CycSha256Hex -Bytes $current.bytes) `
            -NewExisted $true `
            -NewBytes $restoredBytes
        if ($journal.previousRecord -and -not (Test-CycAgentsRecordPresent -Record $journal.previousRecord)) {
            throw 'The previous managed AGENTS.md block could not be verified after rollback.'
        }
    } else {
        throw 'Global AGENTS.md transaction has an unsupported mutation operation.'
    }
    Set-CycAgentsJournalPhase -JournalPath $journalPath -Journal $journal -Phase 'rolled-back'
}

function Install-CycAgentsManagedBlock {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        $OldManifest,
        [switch]$TestHarness
    )
    if (-not $TestHarness) {
        throw 'Direct AGENTS.md mutation is reserved for the isolated packaging test harness; use the plugin-gated lifecycle.'
    }
    if (-not $Plan.agentsIntegration.enabled) {
        return (Get-CycAgentsInstallMutation -Plan $Plan -OldManifest $OldManifest).record
    }
    $mutex = Enter-CycAgentsMutex
    $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('cyc-agents-direct-' + [Guid]::NewGuid().ToString('N'))
    $transaction = $null
    $preserveTemporary = $false
    try {
        Assert-CycCreationPathNoReparse -Path $temporaryRoot
        [void](New-Item -ItemType Directory -Path $temporaryRoot -Force)
        $transaction = Start-CycAgentsInstallTransaction `
            -Plan $Plan `
            -OldManifest $OldManifest `
            -TransactionRoot $temporaryRoot `
            -AllowUnverifiedTestHarness
        Complete-CycAgentsInstallTransaction -Transaction $transaction
        return $transaction.record
    } catch {
        if (-not $transaction) {
            $pendingJournal = Join-Path $temporaryRoot 'global-agents\journal.json'
            if (Test-Path -LiteralPath $pendingJournal -PathType Leaf) {
                $transaction = [PSCustomObject]@{ disabled = $false; journalPath = $pendingJournal }
            }
        }
        if ($transaction -and -not $transaction.disabled) {
            try { Rollback-CycAgentsInstallTransaction -Transaction $transaction } catch {
                $preserveTemporary = $true
            }
        }
        throw
    } finally {
        if (-not $preserveTemporary -and (Test-Path -LiteralPath $temporaryRoot -PathType Container)) {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
        }
        Exit-CycAgentsMutex -Mutex $mutex
    }
}

function Get-CycAgentsRemovalPlan {
    param([Parameter(Mandatory = $true)]$Record)
    if (-not [bool](Get-CycObjectProperty -Object $Record -Name 'enabled' -Default $false) -or
        -not [bool](Get-CycObjectProperty -Object $Record -Name 'installed' -Default $false)) {
        return [PSCustomObject]@{ required = $false; alreadyApplied = $true }
    }
    Assert-CycAgentsIntegrationRecord -Record $Record
    $cleanup = Get-CycObjectProperty -Object $Record -Name 'cleanup'
    if ($cleanup -and [string](Get-CycObjectProperty -Object $cleanup -Name 'phase') -ceq 'completed') {
        return [PSCustomObject]@{
            required = $false
            alreadyApplied = $true
            completed = $true
            path = [string](Get-CycObjectProperty -Object $Record -Name 'path')
        }
    }

    $codexHome = Resolve-CycCodexHome -RequestedHome ([string](Get-CycObjectProperty -Object $Record -Name 'codexHome'))
    $agentsPath = Resolve-NormalizedPath ([string](Get-CycObjectProperty -Object $Record -Name 'path'))
    $expectedPath = Resolve-NormalizedPath (Join-Path $codexHome 'AGENTS.md')
    if (-not [string]::Equals($agentsPath, $expectedPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The install manifest contains an invalid global AGENTS.md path.'
    }

    $prepared = $cleanup -and [string](Get-CycObjectProperty -Object $cleanup -Name 'phase') -ceq 'prepared'
    $document = Get-CycStrictTextDocument -Path $agentsPath
    $currentSha256 = if ($document.existed) { Get-CycSha256Hex -Bytes $document.bytes } else { $null }
    if ($prepared) {
        $expectedAfterAbsent = [bool](Get-CycObjectProperty -Object $cleanup -Name 'afterAbsent')
        $expectedAfterSha256 = Get-CycObjectProperty -Object $cleanup -Name 'afterFileSha256'
        $matchesAfter = if ($expectedAfterAbsent) {
            -not $document.existed
        } else {
            $document.existed -and $currentSha256 -ceq [string]$expectedAfterSha256
        }
        if ($matchesAfter) {
            return [PSCustomObject]@{
                required = $true
                alreadyApplied = $true
                path = $agentsPath
                beforeFileSha256 = Get-CycObjectProperty -Object $cleanup -Name 'beforeFileSha256'
                afterFileSha256 = $expectedAfterSha256
                afterAbsent = $expectedAfterAbsent
            }
        }
        if (-not $document.existed -or
            $currentSha256 -cne [string](Get-CycObjectProperty -Object $cleanup -Name 'beforeFileSha256')) {
            throw 'Global AGENTS.md drifted after uninstall cleanup was prepared.'
        }
    }
    if (-not $document.existed) {
        throw 'Global AGENTS.md is missing while its managed block is still recorded.'
    }
    $recordedEncoding = [string](Get-CycObjectProperty -Object $Record -Name 'encoding')
    if ($recordedEncoding -cne [string]$document.encodingName) {
        throw 'Global AGENTS.md encoding drifted before uninstall.'
    }
    $markerState = Get-CycAgentsMarkerState -Document $document
    if (-not $markerState.present) {
        throw 'The ClusterYourCodex managed block is missing from global AGENTS.md.'
    }
    [byte[]]$blockBytes = $document.encoding.GetBytes($markerState.blockText)
    $recordedBlockHash = [string](Get-CycObjectProperty -Object $Record -Name 'blockSha256')
    if ($recordedBlockHash -cnotmatch '^[0-9a-f]{64}$' -or
        (Get-CycSha256Hex -Bytes $blockBytes) -cne $recordedBlockHash) {
        throw 'The ClusterYourCodex managed block drifted before uninstall.'
    }
    try {
        [byte[]]$prefixBytes = [System.Convert]::FromBase64String(
            [string](Get-CycObjectProperty -Object $Record -Name 'ownedPrefixBase64')
        )
        $ownedPrefix = $document.encoding.GetString($prefixBytes)
    } catch {
        throw 'The recorded ClusterYourCodex AGENTS.md prefix is invalid.'
    }
    $removeStart = $markerState.beginIndex - $ownedPrefix.Length
    if ($removeStart -lt 0 -or
        $document.text.Substring($removeStart, $ownedPrefix.Length) -cne $ownedPrefix) {
        throw 'The separator before the ClusterYourCodex managed block drifted before uninstall.'
    }
    $remainingText = $document.text.Remove(
        $removeStart,
        $markerState.endExclusive - $removeStart
    )
    $baseFileExisted = [bool](Get-CycObjectProperty -Object $Record -Name 'baseFileExisted')
    $afterAbsent = (-not $baseFileExisted) -and [string]::IsNullOrWhiteSpace($remainingText)
    [byte[]]$afterBytes = if ($afterAbsent) {
        [byte[]]@()
    } else {
        ConvertTo-CycDocumentBytes -Document $document -Text $remainingText
    }
    return [PSCustomObject]@{
        required = $true
        alreadyApplied = $false
        path = $agentsPath
        beforeFileSha256 = $currentSha256
        afterFileSha256 = if ($afterAbsent) { $null } else { Get-CycSha256Hex -Bytes $afterBytes }
        afterAbsent = [bool]$afterAbsent
        afterBytes = $afterBytes
    }
}

function Set-CycAgentsCleanupState {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)]$Cleanup
    )
    if (-not $Manifest.PSObject.Properties['agentsIntegration']) {
        throw 'Install manifest has no global AGENTS.md integration record.'
    }
    if ($Manifest.agentsIntegration.PSObject.Properties['cleanup']) {
        $Manifest.agentsIntegration.cleanup = $Cleanup
    } else {
        $Manifest.agentsIntegration | Add-Member -NotePropertyName cleanup -NotePropertyValue $Cleanup
    }
    Write-DurableAtomicJson -Path $ManifestPath -Value $Manifest -Depth 12
}

function Prepare-CycAgentsRemoval {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)]$RemovalPlan
    )
    if (-not $RemovalPlan.required -or $RemovalPlan.alreadyApplied) { return }
    $cleanup = [PSCustomObject][ordered]@{
        phase = 'prepared'
        preparedAtUtc = [DateTime]::UtcNow.ToString('o')
        beforeFileSha256 = $RemovalPlan.beforeFileSha256
        afterFileSha256 = $RemovalPlan.afterFileSha256
        afterAbsent = $RemovalPlan.afterAbsent
    }
    Set-CycAgentsCleanupState -Manifest $Manifest -ManifestPath $ManifestPath -Cleanup $cleanup
}

function Remove-CycAgentsManagedBlock {
    param([Parameter(Mandatory = $true)]$RemovalPlan)
    if (-not $RemovalPlan.required -or $RemovalPlan.alreadyApplied) { return }
    if ($RemovalPlan.afterAbsent) {
        Set-CycAgentsContentCas `
            -Path $RemovalPlan.path `
            -ExpectedExisted $true `
            -ExpectedSha256 $RemovalPlan.beforeFileSha256 `
            -NewExisted $false `
            -NewBytes $null
    } else {
        Set-CycAgentsContentCas `
            -Path $RemovalPlan.path `
            -ExpectedExisted $true `
            -ExpectedSha256 $RemovalPlan.beforeFileSha256 `
            -NewExisted $true `
            -NewBytes $RemovalPlan.afterBytes
    }
}

function Complete-CycAgentsRemoval {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)]$RemovalPlan
    )
    if (-not $RemovalPlan.required) { return }
    $cleanup = [PSCustomObject][ordered]@{
        phase = 'completed'
        completedAtUtc = [DateTime]::UtcNow.ToString('o')
        beforeFileSha256 = $RemovalPlan.beforeFileSha256
        afterFileSha256 = $RemovalPlan.afterFileSha256
        afterAbsent = $RemovalPlan.afterAbsent
    }
    Set-CycAgentsCleanupState -Manifest $Manifest -ManifestPath $ManifestPath -Cleanup $cleanup
}

function Start-CycAgentsRemovalTransaction {
    param(
        [Parameter(Mandatory = $true)]$Record,
        [Parameter(Mandatory = $true)]$RemovalPlan,
        [Parameter(Mandatory = $true)][string]$TransactionRoot
    )
    if (-not $RemovalPlan.required -or $RemovalPlan.alreadyApplied) {
        return [PSCustomObject]@{ disabled = $true }
    }
    Assert-CycAgentsIntegrationRecord -Record $Record
    $document = Get-CycStrictTextDocument -Path $RemovalPlan.path
    $documentHash = if ($document.existed) { Get-CycSha256Hex -Bytes $document.bytes } else { $null }
    if (-not $document.existed -or $documentHash -cne [string]$RemovalPlan.beforeFileSha256) {
        throw 'Global AGENTS.md changed before the uninstall transaction could be prepared.'
    }
    $state = Get-CycAgentsMarkerState -Document $document
    if (-not $state.present) { throw 'The uninstall transaction has no managed block to own.' }
    [byte[]]$prefixBytes = [Convert]::FromBase64String([string]$Record.ownedPrefixBase64)
    $prefix = $document.encoding.GetString($prefixBytes)
    $removeStart = $state.beginIndex - $prefix.Length
    if ($removeStart -lt 0 -or $document.text.Substring($removeStart, $prefix.Length) -cne $prefix) {
        throw 'The uninstall transaction cannot prove its owned separator.'
    }
    $removeEnd = $state.endExclusive
    $ownedRange = $document.text.Substring($removeStart, $removeEnd - $removeStart)
    $left = $document.text.Substring(0, $removeStart)
    $right = $document.text.Substring($removeEnd)
    $anchorLength = 256
    $leftAnchor = if ($left.Length -gt $anchorLength) {
        $left.Substring($left.Length - $anchorLength)
    } else { $left }
    $rightAnchor = if ($right.Length -gt $anchorLength) {
        $right.Substring(0, $anchorLength)
    } else { $right }

    $root = Join-Path (Resolve-NormalizedPath $TransactionRoot) 'global-agents-uninstall'
    if (Test-Path -LiteralPath (Join-Path $root 'journal.json')) {
        throw 'A global AGENTS.md uninstall transaction already exists here.'
    }
    Assert-CycCreationPathNoReparse -Path $root
    [void](New-Item -ItemType Directory -Path $root -Force)
    $beforePath = Join-Path $root 'before.bin'
    $afterPath = Join-Path $root 'after.bin'
    [byte[]]$afterBytes = if ($RemovalPlan.afterAbsent) { New-Object byte[] 0 } else { [byte[]]$RemovalPlan.afterBytes }
    Write-CycDurableAtomicBytes -Path $beforePath -Bytes $document.bytes
    Write-CycDurableAtomicBytes -Path $afterPath -Bytes $afterBytes
    $journalPath = Join-Path $root 'journal.json'
    $journal = [PSCustomObject][ordered]@{
        schemaVersion = $script:AgentsJournalSchema
        operation = 'Uninstall'
        phase = 'prepared'
        preparedAtUtc = [DateTime]::UtcNow.ToString('o')
        transactionId = Split-Path -Leaf (Resolve-NormalizedPath $TransactionRoot)
        agentsPath = [string]$Record.path
        codexHome = [string]$Record.codexHome
        originalExisted = [bool]$Record.baseFileExisted
        beforeExisted = $true
        beforeFileSha256 = $documentHash
        beforeLength = [long]$document.bytes.Length
        beforeImageSha256 = Get-CycSha256Hex -Bytes $document.bytes
        afterExisted = -not [bool]$RemovalPlan.afterAbsent
        afterFileSha256 = $RemovalPlan.afterFileSha256
        afterLength = [long]$afterBytes.Length
        afterImageSha256 = Get-CycSha256Hex -Bytes $afterBytes
        blockSha256 = [string]$Record.blockSha256
        prefixSha256 = [string]$Record.prefixSha256
        ownedRangeBase64 = [Convert]::ToBase64String($document.encoding.GetBytes($ownedRange))
        leftAnchorBase64 = [Convert]::ToBase64String($document.encoding.GetBytes($leftAnchor))
        rightAnchorBase64 = [Convert]::ToBase64String($document.encoding.GetBytes($rightAnchor))
        receipt = $Record
    }
    Write-DurableAtomicJson -Path $journalPath -Value $journal -Depth 20
    Set-PrivateDirectoryAcl -Path $root
    $prepared = Read-CycAgentsJournal -Path $journalPath
    [void](Get-CycAgentsJournalImages -Journal $prepared -JournalPath $journalPath)
    return [PSCustomObject]@{
        disabled = $false
        root = $root
        journalPath = $journalPath
        journal = $prepared
        record = $Record
        removalPlan = $RemovalPlan
    }
}

function Apply-CycAgentsRemovalTransaction {
    param($Transaction)
    if (-not $Transaction -or $Transaction.disabled) { return }
    $journal = Read-CycAgentsJournal -Path $Transaction.journalPath
    if ([string]$journal.operation -cne 'Uninstall' -or [string]$journal.phase -cne 'prepared') {
        throw 'Global AGENTS.md uninstall transaction is not prepared.'
    }
    Remove-CycAgentsManagedBlock -RemovalPlan $Transaction.removalPlan
    Set-CycAgentsJournalPhase -JournalPath $Transaction.journalPath -Journal $journal -Phase applied
}

function Find-CycAgentsRollbackInsertionIndex {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$LeftAnchor,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RightAnchor
    )
    if ($LeftAnchor.Length -gt 0 -and $RightAnchor.Length -gt 0) {
        $combined = $LeftAnchor + $RightAnchor
        $matches = @(Get-CycStringIndexes -Text $Text -Value $combined)
        if ($matches.Count -eq 1) { return [int]($matches[0] + $LeftAnchor.Length) }
    } elseif ($LeftAnchor.Length -gt 0) {
        $matches = @(Get-CycStringIndexes -Text $Text -Value $LeftAnchor)
        if ($matches.Count -eq 1) { return [int]($matches[0] + $LeftAnchor.Length) }
    } elseif ($RightAnchor.Length -gt 0) {
        $matches = @(Get-CycStringIndexes -Text $Text -Value $RightAnchor)
        if ($matches.Count -eq 1) { return [int]$matches[0] }
    } else {
        return 0
    }
    throw 'Global AGENTS.md rollback anchor is missing or ambiguous; user content is preserved unchanged.'
}

function Rollback-CycAgentsRemovalTransaction {
    param($Transaction)
    if (-not $Transaction -or $Transaction.disabled) { return }
    $journalPath = [string]$Transaction.journalPath
    $journal = Read-CycAgentsJournal -Path $journalPath
    if ([string]$journal.operation -cne 'Uninstall') {
        throw 'Cannot roll back a non-uninstall AGENTS.md transaction as an uninstall.'
    }
    if ([string]$journal.phase -ceq 'rolled-back') { return }
    if ([string]$journal.phase -ceq 'committed') {
        throw 'A committed global AGENTS.md uninstall transaction cannot be rolled back.'
    }
    [void](Get-CycAgentsJournalImages -Journal $journal -JournalPath $journalPath)
    if (Test-CycAgentsRecordPresent -Record $journal.receipt) {
        Set-CycAgentsJournalPhase -JournalPath $journalPath -Journal $journal -Phase 'rolled-back'
        return
    }
    $current = Get-CycStrictTextDocument -Path ([string]$journal.agentsPath)
    $state = Get-CycAgentsMarkerState -Document $current
    if ($state.present) {
        throw 'A non-owned managed marker pair appeared during uninstall rollback; rollback fails closed.'
    }
    $encoding = $current.encoding
    if ([string]$current.encodingName -cne [string]$journal.receipt.encoding) {
        # An absent after-image has no encoding to preserve. Use the receipt's
        # before-image encoding by decoding the validated before image file.
        if (-not $current.existed) {
            $images = Get-CycAgentsJournalImages -Journal $journal -JournalPath $journalPath
            $beforeDocument = Get-CycStrictTextDocument -Path $images.beforePath
            $encoding = $beforeDocument.encoding
            $current = [PSCustomObject]@{
                existed = $false; bytes = [byte[]]@(); text = ''
                encoding = $beforeDocument.encoding
                encodingName = $beforeDocument.encodingName
                preamble = $beforeDocument.preamble
            }
        } else {
            throw 'Global AGENTS.md encoding changed during uninstall rollback.'
        }
    }
    try {
        $ownedRange = $encoding.GetString([Convert]::FromBase64String([string]$journal.ownedRangeBase64))
        $leftAnchor = $encoding.GetString([Convert]::FromBase64String([string]$journal.leftAnchorBase64))
        $rightAnchor = $encoding.GetString([Convert]::FromBase64String([string]$journal.rightAnchorBase64))
    } catch {
        throw 'Global AGENTS.md uninstall rollback anchor metadata is invalid.'
    }
    $insertAt = Find-CycAgentsRollbackInsertionIndex `
        -Text $current.text `
        -LeftAnchor $leftAnchor `
        -RightAnchor $rightAnchor
    $restoredText = $current.text.Insert($insertAt, $ownedRange)
    [byte[]]$restoredBytes = ConvertTo-CycDocumentBytes -Document $current -Text $restoredText
    $currentHash = if ($current.existed) { Get-CycSha256Hex -Bytes $current.bytes } else { $null }
    Set-CycAgentsContentCas `
        -Path ([string]$journal.agentsPath) `
        -ExpectedExisted ([bool]$current.existed) `
        -ExpectedSha256 $currentHash `
        -NewExisted $true `
        -NewBytes $restoredBytes
    if (-not (Test-CycAgentsRecordPresent -Record $journal.receipt)) {
        throw 'Global AGENTS.md owned range could not be verified after uninstall rollback.'
    }
    Set-CycAgentsJournalPhase -JournalPath $journalPath -Journal $journal -Phase 'rolled-back'
}

function Complete-CycAgentsRemovalTransaction {
    param($Transaction)
    if (-not $Transaction -or $Transaction.disabled) { return }
    $journal = Read-CycAgentsJournal -Path $Transaction.journalPath
    Set-CycAgentsJournalPhase -JournalPath $Transaction.journalPath -Journal $journal -Phase committed
}

function Recover-CycAgentsTransactions {
    param(
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )
    $resolvedData = Assert-CycExistingPrivateDirectory -Path $DataRoot
    $installerRoot = Join-Path $resolvedData '.installer'
    $transactionsRoot = Join-Path $installerRoot 'transactions'
    if (-not (Test-Path -LiteralPath $transactionsRoot -PathType Container)) { return @() }
    # Do not trust or enumerate a journal until the complete private state
    # hierarchy has passed the exact owner/DACL/reparse-point contract.
    [void](Assert-CycExistingPrivateDirectory -Path $installerRoot)
    Assert-CycPrivateStateTree -Root $transactionsRoot
    $manifest = Read-InstallManifest -ManifestPath $ManifestPath
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($journalItem in @(Get-ChildItem -LiteralPath $transactionsRoot -Filter journal.json -File -Recurse -Force |
        Sort-Object FullName)) {
        [void](Assert-ChildPath -Root $transactionsRoot -Candidate $journalItem.FullName)
        $journal = Read-CycAgentsJournal -Path $journalItem.FullName
        if ([string]$journal.phase -in @('committed', 'rolled-back')) { continue }
        $transaction = [PSCustomObject]@{
            disabled = $false
            journalPath = $journalItem.FullName
            journal = $journal
            record = $journal.receipt
        }
        if ([string]$journal.operation -ceq 'InstallOrRepair') {
            if ((Test-CycManifestOwnsAgentsReceipt -Manifest $manifest -Receipt $journal.receipt) -and
                (Test-CycAgentsRecordPresent -Record $journal.receipt)) {
                Complete-CycAgentsInstallTransaction -Transaction $transaction
                [void]$results.Add([PSCustomObject]@{ journal = $journalItem.FullName; action = 'finalized-install' })
            } else {
                Rollback-CycAgentsInstallTransaction -Transaction $transaction
                [void]$results.Add([PSCustomObject]@{ journal = $journalItem.FullName; action = 'rolled-back-install' })
            }
        } else {
            $cleanupCompleted = [bool]($manifest -and $manifest.PSObject.Properties['agentsIntegration'] -and
                $manifest.agentsIntegration.PSObject.Properties['cleanup'] -and
                [string]$manifest.agentsIntegration.cleanup.phase -ceq 'completed')
            if ($cleanupCompleted -and -not (Test-CycAgentsRecordPresent -Record $journal.receipt)) {
                Complete-CycAgentsRemovalTransaction -Transaction $transaction
                [void]$results.Add([PSCustomObject]@{ journal = $journalItem.FullName; action = 'finalized-uninstall' })
            } else {
                Rollback-CycAgentsRemovalTransaction -Transaction $transaction
                if ($manifest -and $manifest.PSObject.Properties['agentsIntegration']) {
                    $rolledBackCleanup = [PSCustomObject][ordered]@{
                        phase = 'rolled-back'
                        rolledBackAtUtc = [DateTime]::UtcNow.ToString('o')
                    }
                    Set-CycAgentsCleanupState `
                        -Manifest $manifest `
                        -ManifestPath $ManifestPath `
                        -Cleanup $rolledBackCleanup
                }
                [void]$results.Add([PSCustomObject]@{ journal = $journalItem.FullName; action = 'rolled-back-uninstall' })
            }
        }
    }
    return @($results | ForEach-Object { $_ })
}

function ConvertTo-SafePackageRelativePath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        $RelativePath.Contains('\') -or $RelativePath.Contains(':') -or
        $RelativePath.Contains("`0") -or $RelativePath.StartsWith('/') -or
        $RelativePath.EndsWith('/')) {
        throw "Package manifest contains an unsafe path: $RelativePath"
    }
    $segments = @($RelativePath.Split('/'))
    if ($segments.Count -eq 0 -or @($segments | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0) {
        throw "Package manifest contains an unsafe path: $RelativePath"
    }
    return ($segments -join [System.IO.Path]::DirectorySeparatorChar)
}

function Assert-CycPackageManifest {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$PayloadRoot
    )
    $packageRoot = Resolve-NormalizedPath $Root
    $manifestFile = Assert-ChildPath -Root $packageRoot -Candidate $ManifestPath
    $payload = Assert-ChildPath -Root $packageRoot -Candidate $PayloadRoot
    if (-not (Test-Path -LiteralPath $manifestFile -PathType Leaf)) {
        throw "Package manifest is missing: $manifestFile"
    }
    $manifestItem = Get-Item -LiteralPath $manifestFile -Force
    if ((Test-ReparsePoint $manifestItem) -or $manifestItem.Length -gt 8MB) {
        throw 'Package manifest must be a bounded regular file, not a reparse point.'
    }
    try { $manifest = Read-CycUtf8Json -Path $manifestFile } catch {
        throw 'Package manifest contains invalid JSON.'
    }
    if ($manifest.schemaVersion -cne 'cyc.dev/windows-preview/v1') {
        throw 'Unsupported Windows package manifest schema.'
    }
    $productVersionProperty = $manifest.PSObject.Properties['productVersion']
    $releaseChannelProperty = $manifest.PSObject.Properties['releaseChannel']
    $sourceTagProperty = $manifest.PSObject.Properties['sourceTag']
    if ($null -eq $productVersionProperty -or
        [string]$productVersionProperty.Value -cne $script:ProductVersion -or
        $null -eq $releaseChannelProperty -or
        [string]$releaseChannelProperty.Value -cne 'prerelease' -or
        $null -eq $sourceTagProperty) {
        throw 'Windows package manifest release identity is invalid.'
    }
    if ($null -ne $sourceTagProperty.Value -and
        [string]$sourceTagProperty.Value -cne "v$($script:ProductVersion)") {
        throw 'Windows package manifest source tag does not match the product version.'
    }
    $entries = @($manifest.files)
    if ($entries.Count -lt 1 -or $entries.Count -gt 20000) {
        throw 'Package manifest contains an invalid number of files.'
    }
    $seen = @{}
    foreach ($entry in $entries) {
        $relative = [string]$entry.path
        $key = $relative.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            throw "Package manifest contains a case-insensitive duplicate: $relative"
        }
        $seen[$key] = $true
        $nativeRelative = ConvertTo-SafePackageRelativePath -RelativePath $relative
        $candidate = Assert-ChildPath -Root $packageRoot -Candidate (Join-Path $packageRoot $nativeRelative)
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Package manifest entry is missing: $relative"
        }
        $item = Get-Item -LiteralPath $candidate -Force
        if ((Test-ReparsePoint $item) -or [long]$entry.length -ne [long]$item.Length -or
            ([string]$entry.sha256) -cnotmatch '^[0-9a-f]{64}$') {
            throw "Package manifest metadata is invalid for: $relative"
        }
        $actualHash = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -cne [string]$entry.sha256) {
            throw "Package payload failed SHA-256 validation: $relative"
        }
    }
    foreach ($payloadFile in Get-PayloadFiles -Root $payload) {
        $relative = Get-RelativeOwnedPath -Root $packageRoot -Path $payloadFile.FullName
        if (-not $seen.ContainsKey($relative.ToLowerInvariant())) {
            throw "Package payload is not covered by the manifest: $relative"
        }
    }
    foreach ($requiredOuterFile in @(
        'bootstrap.ps1',
        'Install-ClusterYourCodex.cmd',
        'Invoke-ClusterYourCodexLifecycle.ps1',
        'Invoke-ClusterYourCodexFirewall.ps1'
    )) {
        if (-not $seen.ContainsKey($requiredOuterFile.ToLowerInvariant())) {
            throw "Package manifest does not cover $requiredOuterFile."
        }
    }
}

function Assert-CycPackageSignature {
    param([Parameter(Mandatory = $true)][string]$Executable)
    $path = Resolve-NormalizedPath $Executable
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'Signed setup executable is missing.'
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $path
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
        -not $signature.SignerCertificate) {
        throw "Setup Authenticode verification failed: $($signature.Status)"
    }
}

function Get-CurrentUserSid {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $identity.User -or [string]::IsNullOrWhiteSpace($identity.User.Value)) {
        throw 'The current Windows account has no stable SID.'
    }
    return [string]$identity.User.Value
}

function Test-CycScheduledTaskAccountNameSidBinding {
    param(
        [string]$AccountName,
        [Parameter(Mandatory = $true)][string]$ExpectedSid
    )
    if ([string]::IsNullOrWhiteSpace($AccountName)) { return $false }
    try {
        $observedSid = ([System.Security.Principal.NTAccount]::new($AccountName)).Translate(
            [System.Security.Principal.SecurityIdentifier]
        ).Value
        return [string]::Equals(
            [string]$observedSid,
            [string]$ExpectedSid,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    } catch {
        return $false
    }
}

function Resolve-CycScheduledTaskAccountName {
    param(
        [Parameter(Mandatory = $true)][string]$Sid,
        [string]$FallbackUserName
    )

    try {
        $normalizedSid = ([System.Security.Principal.SecurityIdentifier]::new($Sid)).Value
    } catch {
        throw "Unable to resolve Scheduled Task identity '$Sid' to a canonical SID."
    }

    # WindowsIdentity.Name is a display projection and can be mojibaked for
    # non-ASCII local accounts under the ARM64/x64 PowerShell combination.
    # Resolve the scheduler credential from the immutable SID first, then
    # verify the returned account name maps back to that exact SID.
    # ProfileList is a UTF-16, SID-bound source that avoids the lossy WMI
    # account-name projection.  A newly-created local profile normally uses
    # the account leaf as its SAM name, so try that canonical candidate before
    # the translated/display fallbacks.
    try {
        $profileKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\' + $normalizedSid
        $profileRecord = Get-ItemProperty -LiteralPath $profileKey -ErrorAction Stop
        $profileRawPath = [string]$profileRecord.ProfileImagePath
        if (-not [string]::IsNullOrWhiteSpace($profileRawPath)) {
            $profilePath = [Environment]::ExpandEnvironmentVariables($profileRawPath)
            $profileLeaf = Split-Path -Leaf ([System.IO.Path]::GetFullPath($profilePath).TrimEnd('\', '/'))
            if (-not [string]::IsNullOrWhiteSpace($profileLeaf)) {
                $profileAccount = if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) {
                    '{0}\{1}' -f [string]$env:COMPUTERNAME, $profileLeaf
                } else { $profileLeaf }
                if (Test-CycScheduledTaskAccountNameSidBinding `
                        -AccountName $profileAccount `
                        -ExpectedSid $normalizedSid) {
                    return [string]$profileAccount
                }
            }
        }
    } catch { }

    try {
        $translated = ([System.Security.Principal.SecurityIdentifier]::new($normalizedSid)).Translate(
            [System.Security.Principal.NTAccount]
        ).Value
        if (Test-CycScheduledTaskAccountNameSidBinding `
                -AccountName ([string]$translated) `
                -ExpectedSid $normalizedSid) {
            return [string]$translated
        }
    } catch { }

    # The short-lived profile-matrix account can be visible through the local
    # SAM before SecurityIdentifier.Translate observes it.  CIM provides a
    # second SID-bound lookup without trusting the lossy display projection.
    try {
        $account = Get-CimInstance `
            -ClassName Win32_UserAccount `
            -Filter ("SID='{0}'" -f $normalizedSid) `
            -ErrorAction Stop |
            Select-Object -First 1
        if ($null -ne $account -and
            -not [string]::IsNullOrWhiteSpace([string]$account.Domain) -and
            -not [string]::IsNullOrWhiteSpace([string]$account.Name)) {
            $cimAccount = '{0}\{1}' -f [string]$account.Domain, [string]$account.Name
            if (Test-CycScheduledTaskAccountNameSidBinding `
                    -AccountName $cimAccount `
                    -ExpectedSid $normalizedSid) {
                return $cimAccount
            }
        }
    } catch { }

    # A fallback is accepted only after the same SID round-trip check.  This
    # keeps a mojibaked or foreign display name from reaching Task Scheduler.
    if (-not [string]::IsNullOrWhiteSpace($FallbackUserName)) {
        $fallback = [string]$FallbackUserName
        $candidates = if ($fallback.Contains('\')) {
            @($fallback)
        } elseif (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) {
            @('{0}\{1}' -f [string]$env:COMPUTERNAME, $fallback)
        } else {
            @($fallback)
        }
        foreach ($candidate in $candidates) {
            if (Test-CycScheduledTaskAccountNameSidBinding `
                    -AccountName $candidate `
                    -ExpectedSid $normalizedSid) {
                return [string]$candidate
            }
        }
    }

    throw "Unable to resolve a SID-bound Scheduled Task account name for '$normalizedSid'."
}

function Get-CycInitiatorBinding {
    param(
        [string]$RequestedSid,
        [string]$RequestedProfile,
        [string]$RequestedLocalAppData
    )
    $sid = Get-CurrentUserSid
    if ([string]::IsNullOrWhiteSpace($env:USERPROFILE) -or
        [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'The initiating user profile is incomplete.'
    }
    $profile = Resolve-NormalizedPath $env:USERPROFILE
    $localAppData = Resolve-NormalizedPath $env:LOCALAPPDATA
    if (-not [string]::IsNullOrWhiteSpace($RequestedSid) -and $RequestedSid -cne $sid) {
        throw 'The initiating SID changed before the per-user core lifecycle ran.'
    }
    if (-not [string]::IsNullOrWhiteSpace($RequestedProfile) -and
        -not [string]::Equals(
            (Resolve-NormalizedPath $RequestedProfile),
            $profile,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'The initiating profile changed before the per-user core lifecycle ran.'
    }
    if (-not [string]::IsNullOrWhiteSpace($RequestedLocalAppData) -and
        -not [string]::Equals(
            (Resolve-NormalizedPath $RequestedLocalAppData),
            $localAppData,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'The initiating LOCALAPPDATA changed before the per-user core lifecycle ran.'
    }
    return [PSCustomObject]@{
        sid = $sid
        profile = $profile
        localAppData = $localAppData
    }
}

function Assert-CycManifestInitiatorBinding {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$CurrentBinding
    )
    if (-not $Manifest.PSObject.Properties['initiator']) { return }
    $record = $Manifest.initiator
    if ([string]$record.sid -cne [string]$CurrentBinding.sid -or
        -not [string]::Equals(
            (Resolve-NormalizedPath ([string]$record.profile)),
            [string]$CurrentBinding.profile,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        -not [string]::Equals(
            (Resolve-NormalizedPath ([string]$record.localAppData)),
            [string]$CurrentBinding.localAppData,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'Installed state belongs to a different initiating SID or profile.'
    }
}

function ConvertTo-CycCanonicalHost {
    param(
        [Parameter(Mandatory = $true)][string]$HostValue,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ($HostValue.Length -gt 255 -or $HostValue -match '[\x00-\x1f\x7f]' -or
        -not $HostValue.IsNormalized([Text.NormalizationForm]::FormC)) {
        throw "$Label is not a portable DNS name or IP literal."
    }
    $value = $HostValue.Trim([char[]]@(' '))
    if ([string]::IsNullOrWhiteSpace($value) -or $value -cmatch '[^\x20-\x7e]') {
        throw "$Label is not a portable DNS name or IP literal."
    }
    $parsedAddress = $null
    if ([System.Net.IPAddress]::TryParse($value, [ref]$parsedAddress)) {
        if ($value.Contains('%') -or $parsedAddress.IsIPv4MappedToIPv6) {
            throw "$Label must not use a scoped or IPv4-mapped IPv6 literal."
        }
        return $parsedAddress.ToString().ToLowerInvariant()
    }

    if ($value.EndsWith('.', [System.StringComparison]::Ordinal)) {
        $value = $value.Substring(0, $value.Length - 1)
    }
    if ([string]::IsNullOrWhiteSpace($value) -or $value.Length -gt 253 -or
        $value.EndsWith('.', [System.StringComparison]::Ordinal)) {
        throw "$Label is not a portable DNS name or IP literal."
    }
    foreach ($dnsLabel in @($value.Split('.'))) {
        if ($dnsLabel.Length -lt 1 -or $dnsLabel.Length -gt 63 -or
            $dnsLabel -cnotmatch '^(?:[A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]{0,61}[A-Za-z0-9])$') {
            throw "$Label is not a portable DNS name or IP literal."
        }
    }
    return $value.ToLowerInvariant()
}

function ConvertTo-CycCanonicalIpAddress {
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $canonical = ConvertTo-CycCanonicalHost -HostValue $Address -Label $Label
    $parsedAddress = $null
    if (-not [System.Net.IPAddress]::TryParse($canonical, [ref]$parsedAddress)) {
        throw "$Label must be an IP literal."
    }
    return $parsedAddress.ToString().ToLowerInvariant()
}

function Test-CycPrivateLanAddress {
    param([Parameter(Mandatory = $true)][string]$Address)
    $parsedAddress = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsedAddress)) { return $false }
    $bytes = $parsedAddress.GetAddressBytes()
    if ($parsedAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        return $bytes[0] -eq 10 -or
            ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
            ($bytes[0] -eq 192 -and $bytes[1] -eq 168)
    }
    if ($parsedAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
        return ($bytes[0] -band 0xfe) -eq 0xfc
    }
    return $false
}

function Get-CycSortedUniqueHosts {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Hosts)
    $values = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $hostIndex = 0
    foreach ($hostValue in $Hosts) {
        $canonical = ConvertTo-CycCanonicalHost `
            -HostValue ([string]$hostValue) `
            -Label "Identity host at index $hostIndex"
        if ($seen.Add($canonical)) { [void]$values.Add($canonical) }
        $hostIndex++
    }
    $values.Sort([System.StringComparer]::Ordinal)
    return ,$values.ToArray()
}

function Get-CycNetworkConfigurationProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $null
}

function Get-CycNetworkInterfaceMetric {
    param([Parameter(Mandatory = $true)]$Configuration)
    $metrics = @()
    foreach ($interfaceProperty in @('NetIPv4Interface', 'NetIPv6Interface')) {
        $interface = Get-CycNetworkConfigurationProperty -Object $Configuration -Name $interfaceProperty
        if ($interface -and $interface.PSObject.Properties['InterfaceMetric']) {
            $candidate = 0
            if ([int]::TryParse([string]$interface.InterfaceMetric, [ref]$candidate) -and $candidate -ge 0) {
                $metrics += $candidate
            }
        }
    }
    if ($metrics.Count -eq 0) { return [int]::MaxValue }
    return [int](($metrics | Measure-Object -Minimum).Minimum)
}

function Get-CycPrivateNetworkCandidates {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Configurations)
    $candidates = @()
    foreach ($configuration in $Configurations) {
        $adapter = Get-CycNetworkConfigurationProperty -Object $configuration -Name 'NetAdapter'
        $status = if ($adapter) { [string](Get-CycNetworkConfigurationProperty -Object $adapter -Name 'Status') } else { '' }
        if ($status -cne 'Up') { continue }
        $interfaceIndex = 0
        $rawInterfaceIndex = Get-CycNetworkConfigurationProperty -Object $configuration -Name 'InterfaceIndex'
        if ($null -eq $rawInterfaceIndex -and $adapter) {
            $rawInterfaceIndex = Get-CycNetworkConfigurationProperty -Object $adapter -Name 'ifIndex'
        }
        if (-not [int]::TryParse([string]$rawInterfaceIndex, [ref]$interfaceIndex) -or $interfaceIndex -lt 1) {
            continue
        }
        $hasDefaultGateway = $null -ne (Get-CycNetworkConfigurationProperty -Object $configuration -Name 'IPv4DefaultGateway') -or
            $null -ne (Get-CycNetworkConfigurationProperty -Object $configuration -Name 'IPv6DefaultGateway')
        $metric = Get-CycNetworkInterfaceMetric -Configuration $configuration
        foreach ($propertyName in @('IPv4Address', 'IPv6Address')) {
            foreach ($addressRecord in @(Get-CycNetworkConfigurationProperty -Object $configuration -Name $propertyName)) {
                if (-not $addressRecord) { continue }
                $addressState = [string](Get-CycNetworkConfigurationProperty -Object $addressRecord -Name 'AddressState')
                if ($addressState -notin @('Preferred', 'Deprecated')) {
                    continue
                }
                $skipAsSource = Get-CycNetworkConfigurationProperty -Object $addressRecord -Name 'SkipAsSource'
                if (-not ($skipAsSource -is [bool]) -or [bool]$skipAsSource) { continue }
                $rawAddress = [string](Get-CycNetworkConfigurationProperty -Object $addressRecord -Name 'IPAddress')
                if ([string]::IsNullOrWhiteSpace($rawAddress)) { continue }
                try { $canonicalAddress = ConvertTo-CycCanonicalIpAddress -Address $rawAddress -Label 'LAN address' } catch { continue }
                if (-not (Test-CycPrivateLanAddress -Address $canonicalAddress)) { continue }
                $parsedAddress = [System.Net.IPAddress]::Parse($canonicalAddress)
                $candidates += [PSCustomObject]@{
                    interfaceIndex = $interfaceIndex
                    defaultRank = if ($hasDefaultGateway) { 0 } else { 1 }
                    interfaceMetric = $metric
                    familyRank = if ($parsedAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) { 0 } else { 1 }
                    address = $canonicalAddress
                }
            }
        }
    }
    return @($candidates)
}

function Get-CycFallbackNetworkConfigurations {
    # The NetTCPIP PowerShell module is absent on some stripped-down Windows
    # images (including the GitHub Windows packaging runner).  Keep discovery
    # fail-closed, but use the .NET networking surface as an equivalent
    # read-only source instead of making a valid private-LAN install depend on
    # one optional cmdlet module.
    $configurations = New-Object System.Collections.Generic.List[object]
    foreach ($adapter in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($adapter.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) {
            continue
        }
        try { $properties = $adapter.GetIPProperties() } catch { continue }
        $ipv4Properties = $null
        $ipv6Properties = $null
        try { $ipv4Properties = $properties.GetIPv4Properties() } catch { }
        try { $ipv6Properties = $properties.GetIPv6Properties() } catch { }
        $interfaceIndex = 0
        if ($ipv4Properties) {
            $interfaceIndex = [int]$ipv4Properties.Index
        } elseif ($ipv6Properties) {
            $interfaceIndex = [int]$ipv6Properties.Index
        }
        if ($interfaceIndex -lt 1) { continue }

        $ipv4Addresses = @($properties.UnicastAddresses | Where-Object {
            $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
        } | ForEach-Object {
            [PSCustomObject]@{
                IPAddress = [string]$_.Address
                AddressState = 'Preferred'
                SkipAsSource = $false
            }
        })
        $ipv6Addresses = @($properties.UnicastAddresses | Where-Object {
            $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6
        } | ForEach-Object {
            [PSCustomObject]@{
                IPAddress = [string]$_.Address
                AddressState = 'Preferred'
                SkipAsSource = $false
            }
        })
        if ($ipv4Addresses.Count -eq 0 -and $ipv6Addresses.Count -eq 0) { continue }

        $ipv4Gateway = @($properties.GatewayAddresses | Where-Object {
            $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
        } | Select-Object -First 1 | ForEach-Object {
            [PSCustomObject]@{ NextHop = [string]$_.Address }
        })
        $ipv6Gateway = @($properties.GatewayAddresses | Where-Object {
            $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6
        } | Select-Object -First 1 | ForEach-Object {
            [PSCustomObject]@{ NextHop = [string]$_.Address }
        })
        $metric = [int]::MaxValue
        $configurations.Add([PSCustomObject]@{
            InterfaceIndex = $interfaceIndex
            NetAdapter = [PSCustomObject]@{ Status = 'Up'; ifIndex = $interfaceIndex }
            IPv4DefaultGateway = if ($ipv4Gateway.Count -gt 0) { $ipv4Gateway[0] } else { $null }
            IPv6DefaultGateway = if ($ipv6Gateway.Count -gt 0) { $ipv6Gateway[0] } else { $null }
            NetIPv4Interface = [PSCustomObject]@{ InterfaceMetric = $metric }
            NetIPv6Interface = [PSCustomObject]@{ InterfaceMetric = $metric }
            IPv4Address = $ipv4Addresses
            IPv6Address = $ipv6Addresses
        })
    }
    return @($configurations.ToArray())
}

function New-CycManagedWorkerNetworkPlan {
    param(
        [Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$InterfaceIndex,
        [Parameter(Mandatory = $true)][string]$BindHost,
        [Parameter(Mandatory = $true)][string]$PublicHost,
        [Parameter(Mandatory = $true)][string]$ControllerHostName,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$PrivateAddresses,
        [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$ListenPort
    )
    $canonicalBindHost = ConvertTo-CycCanonicalIpAddress -Address $BindHost -Label 'WorkerBindHost'
    if (-not (Test-CycPrivateLanAddress -Address $canonicalBindHost)) {
        throw 'WorkerBindHost must be an RFC1918 IPv4 or ULA IPv6 address.'
    }
    $canonicalPublicHost = ConvertTo-CycCanonicalHost -HostValue $PublicHost -Label 'WorkerPublicHost'
    $publicAddress = $null
    if ([System.Net.IPAddress]::TryParse($canonicalPublicHost, [ref]$publicAddress) -and
        -not [string]::Equals($canonicalPublicHost, $canonicalBindHost, [System.StringComparison]::Ordinal)) {
        throw 'An IP-literal WorkerPublicHost must exactly match WorkerBindHost.'
    }
    $canonicalControllerHostName = ConvertTo-CycCanonicalHost `
        -HostValue $ControllerHostName `
        -Label 'Controller host name'
    $controllerAddress = $null
    if ([System.Net.IPAddress]::TryParse($canonicalControllerHostName, [ref]$controllerAddress)) {
        throw 'Controller host name must be a portable DNS hostname.'
    }
    [string[]]$canonicalPrivateAddresses = Get-CycSortedUniqueHosts -Hosts @($PrivateAddresses)
    if ($canonicalPrivateAddresses.Count -lt 1) {
        throw 'The selected interface has no RFC1918 or ULA address.'
    }
    foreach ($privateAddress in $canonicalPrivateAddresses) {
        $parsedPrivateAddress = $null
        if (-not [System.Net.IPAddress]::TryParse($privateAddress, [ref]$parsedPrivateAddress) -or
            -not (Test-CycPrivateLanAddress -Address $privateAddress)) {
            throw 'WorkerPrivateAddress contains a non-private or non-IP value.'
        }
    }
    if ($canonicalPrivateAddresses -cnotcontains $canonicalBindHost) {
        throw 'WorkerBindHost is not part of the selected interface private-address set.'
    }
    [string[]]$identityHosts = Get-CycSortedUniqueHosts -Hosts @(
        $canonicalPrivateAddresses + @('127.0.0.1', '::1', $canonicalControllerHostName, $canonicalPublicHost)
    )
    if ($identityHosts.Count -lt 4 -or $identityHosts.Count -gt 32) {
        throw 'The immutable controller identity SAN set must contain between 4 and 32 hosts.'
    }
    return [PSCustomObject][ordered]@{
        schemaVersion = $script:ManagedWorkerNetworkPlanSchema
        identityVersion = $script:ManagedWorkerIdentityVersion
        selectedInterfaceIndex = $InterfaceIndex
        controllerHostName = $canonicalControllerHostName
        bindHost = $canonicalBindHost
        publicHost = $canonicalPublicHost
        listenPort = $ListenPort
        privateAddresses = [object[]]$canonicalPrivateAddresses
        identityHosts = [object[]]$identityHosts
    }
}

function Assert-CycManagedWorkerNetworkPlan {
    param([Parameter(Mandatory = $true)]$NetworkPlan)
    [string[]]$expectedProperties = @(
        'bindHost', 'controllerHostName', 'identityHosts', 'identityVersion', 'listenPort',
        'privateAddresses', 'publicHost', 'schemaVersion', 'selectedInterfaceIndex'
    )
    [string[]]$actualProperties = @($NetworkPlan.PSObject.Properties.Name)
    [Array]::Sort($expectedProperties, [System.StringComparer]::Ordinal)
    [Array]::Sort($actualProperties, [System.StringComparer]::Ordinal)
    $interfaceIndexValue = $NetworkPlan.selectedInterfaceIndex
    $listenPortValue = $NetworkPlan.listenPort
    if ([string]::Join(',', $actualProperties) -cne [string]::Join(',', $expectedProperties) -or
        [string]$NetworkPlan.schemaVersion -cne $script:ManagedWorkerNetworkPlanSchema -or
        [string]$NetworkPlan.identityVersion -cne $script:ManagedWorkerIdentityVersion -or
        -not ($NetworkPlan.schemaVersion -is [string]) -or
        -not ($NetworkPlan.identityVersion -is [string]) -or
        -not ($NetworkPlan.bindHost -is [string]) -or
        -not ($NetworkPlan.publicHost -is [string]) -or
        -not ($NetworkPlan.controllerHostName -is [string]) -or
        -not ($interfaceIndexValue -is [int] -or $interfaceIndexValue -is [long]) -or
        -not ($listenPortValue -is [int] -or $listenPortValue -is [long]) -or
        -not ($NetworkPlan.privateAddresses -is [System.Array]) -or
        -not ($NetworkPlan.identityHosts -is [System.Array])) {
        throw 'Managed-worker network plan is malformed or unsupported.'
    }
    $normalized = New-CycManagedWorkerNetworkPlan `
        -InterfaceIndex ([int]$NetworkPlan.selectedInterfaceIndex) `
        -BindHost ([string]$NetworkPlan.bindHost) `
        -PublicHost ([string]$NetworkPlan.publicHost) `
        -ControllerHostName ([string]$NetworkPlan.controllerHostName) `
        -PrivateAddresses @($NetworkPlan.privateAddresses | ForEach-Object { [string]$_ }) `
        -ListenPort ([int]$NetworkPlan.listenPort)
    if ([string]$NetworkPlan.bindHost -cne [string]$normalized.bindHost -or
        [string]$NetworkPlan.publicHost -cne [string]$normalized.publicHost -or
        [string]$NetworkPlan.controllerHostName -cne [string]$normalized.controllerHostName) {
        throw 'Managed-worker network plan hosts are not canonical.'
    }
    [string[]]$rawPrivateAddresses = @($NetworkPlan.privateAddresses | ForEach-Object { [string]$_ })
    [string[]]$reportedPrivateAddresses = @(
        $rawPrivateAddresses | ForEach-Object {
            ConvertTo-CycCanonicalIpAddress -Address ([string]$_) -Label 'WorkerPrivateAddress'
        }
    )
    [Array]::Sort($reportedPrivateAddresses, [System.StringComparer]::Ordinal)
    if ([string]::Join("`n", $rawPrivateAddresses) -cne [string]::Join("`n", $reportedPrivateAddresses) -or
        $reportedPrivateAddresses.Count -ne @($normalized.privateAddresses).Count -or
        [string]::Join("`n", $reportedPrivateAddresses) -cne
            [string]::Join("`n", @($normalized.privateAddresses))) {
        throw 'Managed-worker network plan private-address set is not exact.'
    }
    [string[]]$rawIdentityHosts = @($NetworkPlan.identityHosts | ForEach-Object { [string]$_ })
    [string[]]$reportedIdentityHosts = Get-CycSortedUniqueHosts -Hosts @(
        $rawIdentityHosts
    )
    if ([string]::Join("`n", $rawIdentityHosts) -cne [string]::Join("`n", $reportedIdentityHosts) -or
        $reportedIdentityHosts.Count -ne @($NetworkPlan.identityHosts).Count -or
        [string]::Join("`n", $reportedIdentityHosts) -cne [string]::Join("`n", @($normalized.identityHosts))) {
        throw 'Managed-worker network plan identity SAN set is not exact.'
    }
    return $normalized
}

function Get-CycReusableManagedWorkerNetworkPlan {
    param([AllowNull()]$Manifest)
    if (-not $Manifest) {
        return $null
    }
    if (-not $Manifest.PSObject.Properties['managedWorker'] -or
        -not $Manifest.managedWorker.PSObject.Properties['enabled'] -or
        -not ($Manifest.managedWorker.enabled -is [bool])) {
        throw 'Installed manifest managed-worker state is malformed.'
    }
    if (-not [bool]$Manifest.managedWorker.enabled) { return $null }
    if (-not $Manifest.managedWorker.PSObject.Properties['networkPlan']) {
        if ([string]$Manifest.productVersion -cmatch '^0\.1\.0-preview\.[123]$') {
            # preview.1-preview.3 used a wildcard listener and a one-host identity
            # under data\tls. The v1 network plan intentionally migrates into a
            # separate identity directory so core rollback can restore that exact
            # predecessor without any in-place certificate rotation.
            return $null
        }
        throw 'Installed managed-worker state is missing its immutable network plan.'
    }
    return Assert-CycManagedWorkerNetworkPlan -NetworkPlan $Manifest.managedWorker.networkPlan
}

function New-CycDiscoveredManagedWorkerNetworkPlan {
    param(
        [string]$RequestedPublicHost,
        [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$ListenPort,
        [AllowNull()][object[]]$Configurations
    )
    $controllerHostName = ConvertTo-CycCanonicalHost `
        -HostValue ([System.Net.Dns]::GetHostName()) `
        -Label 'Controller host name'
    $requestedHost = if ([string]::IsNullOrWhiteSpace($RequestedPublicHost)) {
        $null
    } else {
        ConvertTo-CycCanonicalHost -HostValue $RequestedPublicHost -Label 'WorkerPublicHost'
    }
    $requestedAddress = $null
    if ($requestedHost -and [System.Net.IPAddress]::TryParse($requestedHost, [ref]$requestedAddress) -and
        -not (Test-CycPrivateLanAddress -Address $requestedHost)) {
        throw 'An IP-literal WorkerPublicHost must be an assigned RFC1918 or ULA address.'
    }
    if ($null -eq $Configurations) {
        $netIpConfiguration = Get-Command -Name 'Get-NetIPConfiguration' -CommandType Cmdlet -ErrorAction SilentlyContinue
        if ($netIpConfiguration) {
            try { $Configurations = @(Get-NetIPConfiguration -Detailed -ErrorAction Stop) } catch { $Configurations = $null }
        }
        if ($null -eq $Configurations) {
            $Configurations = @(Get-CycFallbackNetworkConfigurations)
        }
    }
    $candidates = @(Get-CycPrivateNetworkCandidates -Configurations @($Configurations))
    if ($candidates.Count -eq 0) {
        throw 'No active RFC1918 IPv4 or ULA IPv6 interface is available for the managed-worker listener.'
    }
    if ($requestedAddress) {
        $requestedCandidates = @($candidates | Where-Object { [string]$_.address -ceq $requestedHost })
        if ($requestedCandidates.Count -eq 0) {
            throw 'WorkerPublicHost is not assigned to an active private-LAN interface.'
        }
        $selectedInterfaceIndex = [int](@($requestedCandidates | Sort-Object `
            @{ Expression = 'defaultRank'; Ascending = $true },
            @{ Expression = 'interfaceMetric'; Ascending = $true },
            @{ Expression = 'interfaceIndex'; Ascending = $true } | Select-Object -First 1)[0].interfaceIndex)
    } else {
        $selectedInterfaceIndex = [int](@($candidates | Sort-Object `
            @{ Expression = 'defaultRank'; Ascending = $true },
            @{ Expression = 'interfaceMetric'; Ascending = $true },
            @{ Expression = 'interfaceIndex'; Ascending = $true },
            @{ Expression = 'familyRank'; Ascending = $true },
            @{ Expression = 'address'; Ascending = $true } | Select-Object -First 1)[0].interfaceIndex)
    }
    $selectedCandidates = @($candidates | Where-Object { [int]$_.interfaceIndex -eq $selectedInterfaceIndex })
    [string[]]$privateAddresses = Get-CycSortedUniqueHosts -Hosts @(
        $selectedCandidates | ForEach-Object { [string]$_.address }
    )
    $bindHost = if ($requestedAddress) {
        $requestedHost
    } else {
        [string](@($selectedCandidates | Sort-Object `
            @{ Expression = 'familyRank'; Ascending = $true },
            @{ Expression = 'address'; Ascending = $true } | Select-Object -First 1)[0].address)
    }
    $publicHost = if ($requestedHost) { $requestedHost } else { $bindHost }
    return New-CycManagedWorkerNetworkPlan `
        -InterfaceIndex $selectedInterfaceIndex `
        -BindHost $bindHost `
        -PublicHost $publicHost `
        -ControllerHostName $controllerHostName `
        -PrivateAddresses $privateAddresses `
        -ListenPort $ListenPort
}

function Resolve-CycManagedWorkerNetworkPlan {
    param(
        [AllowNull()]$ExistingManifest,
        [string]$RequestedPublicHost,
        [string]$ExplicitBindHost,
        [ValidateRange(0, 2147483647)][int]$ExplicitInterfaceIndex,
        [string]$ExplicitControllerHostName,
        [AllowNull()][string[]]$ExplicitPrivateAddresses,
        [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$ListenPort
    )
    $reusable = Get-CycReusableManagedWorkerNetworkPlan -Manifest $ExistingManifest
    $explicitPrivateAddresses = @($ExplicitPrivateAddresses | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    })
    $explicitPrivateAddressCount = $explicitPrivateAddresses.Count
    $hasExplicit = -not [string]::IsNullOrWhiteSpace($ExplicitBindHost) -or
        $ExplicitInterfaceIndex -ne 0 -or
        -not [string]::IsNullOrWhiteSpace($ExplicitControllerHostName) -or
        $explicitPrivateAddressCount -gt 0
    $explicit = $null
    if ($hasExplicit) {
        if ([string]::IsNullOrWhiteSpace($ExplicitBindHost) -or
            $ExplicitInterfaceIndex -lt 1 -or
            [string]::IsNullOrWhiteSpace($ExplicitControllerHostName) -or
            $explicitPrivateAddressCount -lt 1 -or
            [string]::IsNullOrWhiteSpace($RequestedPublicHost)) {
            throw 'Explicit managed-worker network-plan fields must be supplied together.'
        }
        $explicit = New-CycManagedWorkerNetworkPlan `
            -InterfaceIndex $ExplicitInterfaceIndex `
            -BindHost $ExplicitBindHost `
            -PublicHost $RequestedPublicHost `
            -ControllerHostName $ExplicitControllerHostName `
            -PrivateAddresses $explicitPrivateAddresses `
            -ListenPort $ListenPort
    }
    if ($reusable) {
        if ($explicit) {
            $reusedJson = $reusable | ConvertTo-Json -Depth 6 -Compress
            $explicitJson = $explicit | ConvertTo-Json -Depth 6 -Compress
            if ($reusedJson -cne $explicitJson) {
                throw 'Repair attempted to replace the immutable managed-worker network plan.'
            }
        } elseif (-not [string]::IsNullOrWhiteSpace($RequestedPublicHost) -and
            (ConvertTo-CycCanonicalHost -HostValue $RequestedPublicHost -Label 'WorkerPublicHost') -cne
                [string]$reusable.publicHost) {
            throw 'Repair attempted to replace the immutable WorkerPublicHost.'
        }
        return $reusable
    }
    if ($explicit) { return $explicit }
    return New-CycDiscoveredManagedWorkerNetworkPlan `
        -RequestedPublicHost $RequestedPublicHost `
        -ListenPort $ListenPort
}

function ConvertTo-WorkerPublicOrigin {
    param(
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][int]$Port
    )
    $urlHost = if ([Uri]::CheckHostName($HostName) -eq [UriHostNameType]::IPv6) {
        "[$HostName]"
    } else {
        $HostName
    }
    return "https://${urlHost}:$Port"
}

function ConvertTo-CycSocketAddress {
    param(
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][int]$Port
    )
    $socketHost = if ([Uri]::CheckHostName($HostName) -eq [UriHostNameType]::IPv6) {
        "[$HostName]"
    } else { $HostName }
    return "${socketHost}:$Port"
}

function Get-CycFirewallRuleName {
    $sidSuffix = (Get-CurrentUserSid).Replace('-', '_')
    return "ClusterYourCodex.ManagedWorker.$sidSuffix"
}

function Get-InstallPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [switch]$EnableWorker,
        [string]$WorkerConfig,
        [switch]$SkipCodexIntegration,
        [string]$CodexHome,
        [string]$WorkerPublicHost,
        [string]$WorkerBindHost,
        [ValidateRange(0, 2147483647)][int]$WorkerInterfaceIndex = 0,
        [string]$WorkerControllerHostName,
        [AllowNull()][string[]]$WorkerPrivateAddress,
        [ValidateRange(1, 65535)][int]$WorkerListenPort = 47832,
        [switch]$DisableManagedWorkerListener,
        [switch]$SkipFirewall,
        [switch]$DeferFirewall,
        [AllowNull()]$ExistingManifest,
        [string]$InitiatingSid,
        [string]$InitiatingProfile,
        [string]$InitiatingLocalAppData,
        [string]$FirewallTransactionId,
        [string]$FirewallRequestSha256,
        [switch]$SkipUninstallRegistration,
        [string]$UninstallerPath
    )
    $bundle = Resolve-NormalizedPath $BundleRoot
    $install = Resolve-NormalizedPath $InstallRoot
    $data = Resolve-NormalizedPath $DataRoot
    $initiator = Get-CycInitiatorBinding `
        -RequestedSid $InitiatingSid `
        -RequestedProfile $InitiatingProfile `
        -RequestedLocalAppData $InitiatingLocalAppData
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA is required for the current-user Windows install.'
    }
    $localAppData = [string]$initiator.localAppData
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
    $installedBootstrapRelative = 'installer/bootstrap.ps1'
    $installedUninstallWrapperRelative = 'installer/Uninstall-ClusterYourCodex.ps1'
    $installedLifecycleRelative = 'installer/Invoke-ClusterYourCodexLifecycle.ps1'
    $installedFirewallHelperRelative = 'installer/Invoke-ClusterYourCodexFirewall.ps1'
    foreach ($requiredInstallerFile in @(
        $installedBootstrapRelative,
        $installedUninstallWrapperRelative,
        $installedLifecycleRelative,
        $installedFirewallHelperRelative
    )) {
        if (-not $SkipUninstallRegistration -and -not ($files.relativePath -contains $requiredInstallerFile)) {
            throw "Uninstall registration requires $requiredInstallerFile in the bundle payload."
        }
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
    $buildCatalogSha256 = Get-CycFileCatalogDigest -Entries @($files)
    $codexPayloadCatalogSha256 = if ($hasCodexMarketplace) {
        Get-CycFileCatalogDigest -Entries @($files | Where-Object {
            ([string]$_.relativePath).StartsWith($script:CodexMarketplacePrefix, [System.StringComparison]::Ordinal)
        })
    } else { $null }
    $agentsTemplateFiles = @($files | Where-Object {
        [string]::Equals(
            [string]$_.relativePath,
            $script:AgentsTemplateRelativePath,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    })
    if ($agentsTemplateFiles.Count -ne 1) {
        throw "Bundle payload must contain exactly one $($script:AgentsTemplateRelativePath)."
    }
    [void](Read-CycAgentsTemplate -Path $agentsTemplateFiles[0].sourcePath)
    $resolvedCodexHome = Resolve-CycCodexHome -RequestedHome $CodexHome
    $agentsPath = Join-Path $resolvedCodexHome 'AGENTS.md'
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
    $managedWorkerEnabled = -not [bool]$DisableManagedWorkerListener
    $firewallDesired = $managedWorkerEnabled -and -not [bool]$SkipFirewall
    if (-not [string]::IsNullOrWhiteSpace($FirewallTransactionId) -and
        $FirewallTransactionId -cnotmatch '^[0-9a-f]{32}$') {
        throw 'Deferred firewall lifecycle transaction identifier is invalid.'
    }
    if (-not [string]::IsNullOrWhiteSpace($FirewallRequestSha256) -and
        $FirewallRequestSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Deferred firewall lifecycle request digest is invalid.'
    }
    $networkPlan = if ($managedWorkerEnabled) {
        Resolve-CycManagedWorkerNetworkPlan `
            -ExistingManifest $ExistingManifest `
            -RequestedPublicHost $WorkerPublicHost `
            -ExplicitBindHost $WorkerBindHost `
            -ExplicitInterfaceIndex $WorkerInterfaceIndex `
            -ExplicitControllerHostName $WorkerControllerHostName `
            -ExplicitPrivateAddresses $WorkerPrivateAddress `
            -ListenPort $WorkerListenPort
    } else { $null }
    $publicHost = if ($networkPlan) { [string]$networkPlan.publicHost } else { $null }
    $resolvedWorkerListenPort = if ($networkPlan) { [int]$networkPlan.listenPort } else { $WorkerListenPort }
    $workerPublicUrl = if ($managedWorkerEnabled) {
        ConvertTo-WorkerPublicOrigin -HostName $publicHost -Port $resolvedWorkerListenPort
    } else { $null }
    $tlsRoot = Join-Path $data 'tls'
    $tlsDirectory = Join-Path $tlsRoot $script:ManagedWorkerIdentityVersion
    $tlsCertificate = Join-Path $tlsDirectory 'controller.crt.pem'
    $tlsPrivateKey = Join-Path $tlsDirectory 'controller.key.pem'
    $legacyTlsCertificate = Join-Path $tlsRoot 'controller.crt.pem'
    $legacyTlsPrivateKey = Join-Path $tlsRoot 'controller.key.pem'
    $controllerArguments = '--bind 127.0.0.1:47831 --database "' + $controllerDatabase + '" --token-file "' + $controllerTokenFile + '"'
    if ($managedWorkerEnabled) {
        $controllerArguments += ' --worker-bind ' + (ConvertTo-CycSocketAddress `
            -HostName ([string]$networkPlan.bindHost) `
            -Port $resolvedWorkerListenPort)
        $controllerArguments += ' --worker-public-url "' + $workerPublicUrl + '"'
        $controllerArguments += ' --worker-cert "' + $tlsCertificate + '"'
        $controllerArguments += ' --worker-key "' + $tlsPrivateKey + '"'
    }
    $controllerAction = [PSCustomObject]@{
        executable = Join-Path $install 'cyc-controller.exe'
        arguments = $controllerArguments
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
    $installedBootstrap = Join-Path $install $installedBootstrapRelative
    $installedUninstallWrapper = Join-Path $install $installedUninstallWrapperRelative
    $resolvedUninstaller = if ([string]::IsNullOrWhiteSpace($UninstallerPath)) {
        $installedUninstallWrapper
    } else {
        $candidate = Resolve-NormalizedPath $UninstallerPath
        [void](Assert-ChildPath -Root $install -Candidate $candidate)
        if ($candidate.Contains('"') -or $candidate.Contains("`r") -or $candidate.Contains("`n")) {
            throw 'UninstallerPath must not contain quotes or line breaks.'
        }
        $candidate
    }
    if ([System.IO.Path]::GetExtension($resolvedUninstaller) -ieq '.ps1') {
        $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $uninstallCommand = '"' + $powerShell + '" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "' +
            $resolvedUninstaller + '"'
        $quietUninstallCommand = $uninstallCommand + ' -Quiet'
    } else {
        $uninstallCommand = '"' + $resolvedUninstaller + '"'
        $quietUninstallCommand = '"' + $resolvedUninstaller + '" /S'
    }
    [PSCustomObject]@{
        schemaVersion = $script:ManifestSchema
        action = 'InstallOrRepair'
        initiator = $initiator
        installRoot = $install
        dataRoot = $data
        manifestPath = Join-Path $data '.installer\install-manifest.json'
        buildCatalogSha256 = $buildCatalogSha256
        codexPayloadCatalogSha256 = $codexPayloadCatalogSha256
        files = $files
        tasks = @(
            [PSCustomObject]@{ name = $script:ControllerTaskName; action = $controllerAction; enabled = $true; logonType = $script:ScheduledTaskLogonType },
            [PSCustomObject]@{ name = $script:WorkerTaskName; action = $workerAction; enabled = [bool]$EnableWorker; logonType = $script:ScheduledTaskLogonType }
        )
        workerConfig = $workerConfigPath
        managedWorker = [PSCustomObject]@{
            enabled = $managedWorkerEnabled
            networkPlan = $networkPlan
            identityVersion = if ($networkPlan) { [string]$networkPlan.identityVersion } else { $null }
            identityHosts = if ($networkPlan) { [object[]]@($networkPlan.identityHosts) } else { [object[]]@() }
            bindHost = if ($networkPlan) { [string]$networkPlan.bindHost } else { $null }
            publicHost = $publicHost
            publicUrl = $workerPublicUrl
            listenPort = $resolvedWorkerListenPort
            tlsRoot = $tlsRoot
            tlsDirectory = $tlsDirectory
            certificatePath = $tlsCertificate
            privateKeyPath = $tlsPrivateKey
            legacyTlsCertificatePath = $legacyTlsCertificate
            legacyTlsPrivateKeyPath = $legacyTlsPrivateKey
            identityCli = Join-Path $install 'cyc.exe'
            firewall = [PSCustomObject]@{
                enabled = $firewallDesired
                name = Get-CycFirewallRuleName
                displayName = 'ClusterYourCodex Managed Worker'
                group = $script:FirewallRuleGroup
                description = $script:FirewallRuleDescription
                lifecycle = if ($firewallDesired) { $script:FirewallLifecycleName } else { 'disabled' }
                state = if ($firewallDesired) { 'pending' } else { 'disabled' }
                transactionId = if ($firewallDesired) { $FirewallTransactionId } else { $null }
                requestSha256 = if ($firewallDesired) { $FirewallRequestSha256 } else { $null }
                program = $controllerAction.executable
                port = $resolvedWorkerListenPort
                profile = 'Private'
                remoteAddress = 'LocalSubnet'
                protocol = 'TCP'
            }
        }
        uninstallRegistration = [PSCustomObject]@{
            enabled = -not [bool]$SkipUninstallRegistration
            registryPath = $script:UninstallRegistryPath
            uninstallString = $uninstallCommand
            quietUninstallString = $quietUninstallCommand
            installedBootstrap = $installedBootstrap
            uninstallerPath = $resolvedUninstaller
        }
        codexIntegration = [PSCustomObject]@{
            enabled = (-not [bool]$SkipCodexIntegration) -and $hasCodexMarketplace
            available = $hasCodexMarketplace
            marketplaceRoot = $marketplaceRoot
            marketplaceManifest = Join-Path $marketplaceRoot '.agents\plugins\marketplace.json'
            plugin = 'cluster-your-codex@clusteryourcodex'
        }
        agentsIntegration = [PSCustomObject]@{
            schemaVersion = $script:AgentsIntegrationSchema
            enabled = (-not [bool]$SkipCodexIntegration) -and $hasCodexMarketplace
            available = $true
            codexHome = $resolvedCodexHome
            agentsPath = $agentsPath
            templatePath = $agentsTemplateFiles[0].targetPath
            templateSourcePath = $agentsTemplateFiles[0].sourcePath
            templateRelativePath = $script:AgentsTemplateRelativePath
        }
    }
}

function New-PrivateFileSystemAcl {
    param(
        [Parameter(Mandatory = $true)][bool]$Directory,
        [switch]$AllowAdministratorsReadAndExecute
    )
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
    if ($AllowAdministratorsReadAndExecute) {
        $administratorsSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
        $readAndExecute = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute
        [void]$privateAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $administratorsSid, $readAndExecute, $inheritance, $propagation, $allow
        )))
    }
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
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$AllowAdministratorsReadAndExecute
    )
    $item = Get-Item -LiteralPath $Path -Force
    if (Test-ReparsePoint $item) {
        throw "Owned ACL path must not be a reparse point: $($item.FullName)"
    }
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $userSid = $identity.User.Value
    $expected = @{}
    $expected[$userSid] = [PSCustomObject]@{
        seen = $false
        rights = [System.Security.AccessControl.FileSystemRights]::FullControl
    }
    $expected['S-1-5-18'] = [PSCustomObject]@{
        seen = $false
        rights = [System.Security.AccessControl.FileSystemRights]::FullControl
    }
    if ($AllowAdministratorsReadAndExecute) {
        $administratorReadRights = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute -bor
            [System.Security.AccessControl.FileSystemRights]::Synchronize
        $expected['S-1-5-32-544'] = [PSCustomObject]@{
            seen = $false
            # FileSystemAccessRule normalizes an Allow ACE by adding Synchronize.
            rights = $administratorReadRights
        }
    }
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
    if ($rules.Count -ne $expected.Count) {
        throw "Unexpected ACE count on $($item.FullName)"
    }
    $requiredInheritance = if ($item.PSIsContainer) {
        [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    } else {
        [System.Security.AccessControl.InheritanceFlags]::None
    }
    foreach ($rule in $rules) {
        $ruleSid = $rule.IdentityReference.Value
        if (-not $expected.ContainsKey($ruleSid) -or [bool]$expected[$ruleSid].seen) {
            throw "Unexpected or duplicate principal on $($item.FullName)"
        }
        if ($rule.IsInherited -or
            $rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or
            $rule.InheritanceFlags -ne $requiredInheritance -or
            $rule.PropagationFlags -ne [System.Security.AccessControl.PropagationFlags]::None -or
            $rule.FileSystemRights -ne $expected[$ruleSid].rights) {
            throw "Unexpected access rule on $($item.FullName)"
        }
        $expected[$ruleSid].seen = $true
    }
    if (@($expected.Values | Where-Object { -not [bool]$_.seen }).Count -ne 0) {
        throw "Required principal is missing from $($item.FullName)"
    }
}

function Assert-CycExistingPrivateDirectory {
    <#
    Verify-only preflight for lifecycle/recovery entry points.  This helper is
    intentionally distinct from Set-PrivateDirectoryAcl: an existing weak
    directory is evidence of foreign or tampered state and must not be repaired
    after a journal/manifest has already been read.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$AllowAdministratorsReadAndExecute
    )
    $resolved = Resolve-NormalizedPath $Path
    if (-not (Test-Path -LiteralPath $resolved)) { return $resolved }
    Assert-CycCreationPathNoReparse -Path $resolved
    $item = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or (Test-ReparsePoint $item)) {
        throw "Existing private path is not a normal directory: $resolved"
    }
    Assert-PrivatePathAcl `
        -Path $resolved `
        -AllowAdministratorsReadAndExecute:$AllowAdministratorsReadAndExecute
    return $resolved
}

function Assert-CycPrivateStateTree {
    <#
    Verify every existing transaction/journal descendant before it can be
    enumerated, parsed, removed, or used for rollback.  The tree is created by
    the installer with the same exact protected ACL as the surrounding data
    root; any weak, inherited, foreign, or reparse-point entry fails closed.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [switch]$AllowAdministratorsReadAndExecute
    )
    $resolved = Resolve-NormalizedPath $Root
    if (-not (Test-Path -LiteralPath $resolved)) { return }
    $rootItem = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or (Test-ReparsePoint $rootItem)) {
        throw "Private transaction state root is not a normal directory: $resolved"
    }
    Assert-PrivatePathAcl `
        -Path $resolved `
        -AllowAdministratorsReadAndExecute:$AllowAdministratorsReadAndExecute
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($resolved)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        foreach ($child in @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)) {
            if (Test-ReparsePoint $child) {
                throw "Private transaction state contains a reparse point: $($child.FullName)"
            }
            Assert-PrivatePathAcl `
                -Path $child.FullName `
                -AllowAdministratorsReadAndExecute:$AllowAdministratorsReadAndExecute
            if ($child.PSIsContainer) { $pending.Push($child.FullName) }
        }
    }
}

function Set-PrivatePathAcl {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileSystemInfo]$Item,
        [switch]$AllowAdministratorsReadAndExecute
    )
    if (Test-ReparsePoint $Item) {
        throw "Owned ACL path must not be a reparse point: $($Item.FullName)"
    }
    $replacement = New-PrivateFileSystemAcl `
        -Directory ([bool]$Item.PSIsContainer) `
        -AllowAdministratorsReadAndExecute:$AllowAdministratorsReadAndExecute
    Set-FileSystemAclPortable -Item $Item -Acl $replacement
    Assert-PrivatePathAcl `
        -Path $Item.FullName `
        -AllowAdministratorsReadAndExecute:$AllowAdministratorsReadAndExecute
}

function Set-PrivateDirectoryAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$AllowAdministratorsReadAndExecute
    )
    $directory = Resolve-NormalizedPath $Path
    Assert-CycCreationPathNoReparse -Path $directory
    [void](New-Item -ItemType Directory -Path $directory -Force)
    $root = Get-Item -LiteralPath $directory -Force
    if (-not $root.PSIsContainer) { throw "Private ACL root is not a directory: $directory" }
    Set-PrivatePathAcl `
        -Item $root `
        -AllowAdministratorsReadAndExecute:$AllowAdministratorsReadAndExecute

    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($directory)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        foreach ($child in @(Get-ChildItem -LiteralPath $current -Force)) {
            Set-PrivatePathAcl `
                -Item $child `
                -AllowAdministratorsReadAndExecute:$AllowAdministratorsReadAndExecute
            if ($child.PSIsContainer) { $pending.Push($child.FullName) }
        }
    }
}

function Invoke-CycIdentityCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
        throw "Identity CLI is missing: $Executable"
    }
    try {
        $lines = @(& $Executable @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } catch {
        throw 'Controller TLS identity command failed to start.'
    }
    $raw = [string]::Join([Environment]::NewLine, @($lines | ForEach-Object { [string]$_ }))
    if ($raw.Length -gt 1MB) {
        throw 'Controller TLS identity command returned oversized output.'
    }
    if ($exitCode -ne 0) {
        throw "Controller TLS identity command failed (exit=$exitCode)."
    }
    try { return $raw | ConvertFrom-Json } catch {
        throw 'Controller TLS identity command returned invalid JSON.'
    }
}

function Resolve-CycIdentityReportedPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $candidate = $Path
    if ($candidate.StartsWith('\\?\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $candidate = '\\' + $candidate.Substring(8)
    } elseif ($candidate.StartsWith('\\?\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $candidate = $candidate.Substring(4)
        if ($candidate -cnotmatch '^[A-Za-z]:[\\/]') {
            throw 'Controller TLS identity command returned an unsupported extended path.'
        }
    } elseif ($candidate.StartsWith('\\.\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Controller TLS identity command returned a device path.'
    }
    return Resolve-NormalizedPath $candidate
}

function Assert-CycIdentityMetadata {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Metadata,
        [Parameter(Mandatory = $true)][string]$ExpectedCertificatePath,
        [Parameter(Mandatory = $true)][string]$ExpectedPrivateKeyPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ExpectedHosts,
        [Parameter(Mandatory = $true)][ValidateSet('init', 'verify')][string]$Operation
    )
    if ($null -eq $Metadata) {
        throw "Controller TLS identity $Operation returned incomplete metadata."
    }
    [string[]]$expectedProperties = @(
        'apiVersion',
        'certificate',
        'privateKey',
        'sha256Fingerprint',
        'subjectAltNames',
        'notBefore',
        'notAfter',
        'valid'
    )
    [string[]]$actualProperties = @($Metadata.PSObject.Properties.Name)
    [Array]::Sort($expectedProperties, [System.StringComparer]::Ordinal)
    [Array]::Sort($actualProperties, [System.StringComparer]::Ordinal)
    if ([string]::Join(',', $actualProperties) -cne [string]::Join(',', $expectedProperties)) {
        throw "Controller TLS identity $Operation returned incomplete metadata."
    }
    if ([string]$Metadata.apiVersion -cne 'cyc.dev/identity/v1' -or
        -not ($Metadata.valid -is [bool]) -or
        -not [bool]$Metadata.valid -or
        -not ($Metadata.subjectAltNames -is [System.Array]) -or
        [string]::IsNullOrWhiteSpace([string]$Metadata.notBefore) -or
        [string]::IsNullOrWhiteSpace([string]$Metadata.notAfter)) {
        throw "Controller TLS identity $Operation returned invalid metadata."
    }

    try {
        $reportedCertificatePath = Resolve-CycIdentityReportedPath ([string]$Metadata.certificate)
        $reportedPrivateKeyPath = Resolve-CycIdentityReportedPath ([string]$Metadata.privateKey)
    } catch {
        throw "Controller TLS identity $Operation returned invalid output paths."
    }
    if (-not [string]::Equals(
            $reportedCertificatePath,
            (Resolve-NormalizedPath $ExpectedCertificatePath),
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        -not [string]::Equals(
            $reportedPrivateKeyPath,
            (Resolve-NormalizedPath $ExpectedPrivateKeyPath),
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        throw "Controller TLS identity $Operation returned unexpected output paths."
    }

    $fingerprint = [string]$Metadata.sha256Fingerprint
    if ($fingerprint -cnotmatch '^[0-9a-f]{64}$') {
        throw "Controller TLS identity $Operation omitted its safe fingerprint."
    }
    [string[]]$subjectAltNames = @($Metadata.subjectAltNames | ForEach-Object { [string]$_ })
    [string[]]$canonicalSubjectAltNames = Get-CycSortedUniqueHosts -Hosts $subjectAltNames
    [string[]]$canonicalExpectedHosts = Get-CycSortedUniqueHosts -Hosts @($ExpectedHosts)
    if ($subjectAltNames.Count -ne $canonicalSubjectAltNames.Count -or
        $canonicalExpectedHosts.Count -lt 1 -or
        [string]::Join("`n", $canonicalSubjectAltNames) -cne
            [string]::Join("`n", $canonicalExpectedHosts)) {
        throw "Controller TLS identity $Operation did not bind the exact immutable SAN set."
    }
    return $fingerprint
}

function Ensure-CycTlsIdentity {
    param([Parameter(Mandatory = $true)]$Plan)
    if (-not $Plan.managedWorker.enabled) {
        return [PSCustomObject]@{
            enabled = $false
            created = $false
            fingerprint = $null
            identityVersion = $null
            legacyIdentityPreserved = $false
            migratedFromLegacy = $false
        }
    }
    $certificatePath = Resolve-NormalizedPath $Plan.managedWorker.certificatePath
    $privateKeyPath = Resolve-NormalizedPath $Plan.managedWorker.privateKeyPath
    $tlsRoot = Resolve-NormalizedPath $Plan.managedWorker.tlsRoot
    $tlsDirectory = Resolve-NormalizedPath $Plan.managedWorker.tlsDirectory
    $legacyCertificatePath = Resolve-NormalizedPath $Plan.managedWorker.legacyTlsCertificatePath
    $legacyPrivateKeyPath = Resolve-NormalizedPath $Plan.managedWorker.legacyTlsPrivateKeyPath
    [void](Assert-ChildPath -Root $Plan.dataRoot -Candidate $tlsRoot)
    [void](Assert-ChildPath -Root $tlsRoot -Candidate $tlsDirectory)
    [void](Assert-ChildPath -Root $tlsDirectory -Candidate $certificatePath)
    [void](Assert-ChildPath -Root $tlsDirectory -Candidate $privateKeyPath)
    [void](Assert-ChildPath -Root $tlsRoot -Candidate $legacyCertificatePath)
    [void](Assert-ChildPath -Root $tlsRoot -Candidate $legacyPrivateKeyPath)
    [string[]]$identityHosts = @($Plan.managedWorker.networkPlan.identityHosts | ForEach-Object { [string]$_ })
    [string[]]$canonicalIdentityHosts = Get-CycSortedUniqueHosts -Hosts $identityHosts
    if ($identityHosts.Count -ne $canonicalIdentityHosts.Count -or
        [string]::Join("`n", $identityHosts) -cne [string]::Join("`n", $canonicalIdentityHosts)) {
        throw 'Managed-worker identity hosts do not match the canonical immutable network plan.'
    }

    $legacyCertificateExists = Test-Path -LiteralPath $legacyCertificatePath -PathType Leaf
    $legacyPrivateKeyExists = Test-Path -LiteralPath $legacyPrivateKeyPath -PathType Leaf
    if ((Test-Path -LiteralPath $legacyCertificatePath) -and -not $legacyCertificateExists) {
        throw 'Legacy controller TLS certificate path is not a regular file.'
    }
    if ((Test-Path -LiteralPath $legacyPrivateKeyPath) -and -not $legacyPrivateKeyExists) {
        throw 'Legacy controller TLS private-key path is not a regular file.'
    }
    if ($legacyCertificateExists -xor $legacyPrivateKeyExists) {
        throw 'Legacy controller TLS identity is incomplete; refusing an implicit migration.'
    }
    $legacyIdentityPreserved = $legacyCertificateExists -and $legacyPrivateKeyExists
    $certificateExists = Test-Path -LiteralPath $certificatePath -PathType Leaf
    $privateKeyExists = Test-Path -LiteralPath $privateKeyPath -PathType Leaf
    if ((Test-Path -LiteralPath $certificatePath) -and -not $certificateExists) {
        throw 'Controller TLS certificate path is not a regular file.'
    }
    if ((Test-Path -LiteralPath $privateKeyPath) -and -not $privateKeyExists) {
        throw 'Controller TLS private-key path is not a regular file.'
    }
    if ($certificateExists -xor $privateKeyExists) {
        throw 'Controller TLS identity is incomplete; refusing an implicit certificate rotation.'
    }

    Assert-CycCreationPathNoReparse -Path $tlsRoot
    [void](New-Item -ItemType Directory -Path $tlsRoot -Force)
    Set-PrivateDirectoryAcl -Path $tlsRoot
    Assert-CycCreationPathNoReparse -Path $tlsDirectory
    [void](New-Item -ItemType Directory -Path $tlsDirectory -Force)
    Set-PrivateDirectoryAcl -Path $tlsDirectory
    $created = $false
    try {
        if (-not $certificateExists) {
            [string[]]$initArguments = @('identity', 'init', '--output-dir', $tlsDirectory)
            foreach ($identityHost in $canonicalIdentityHosts) {
                $initArguments += @('--host', $identityHost)
            }
            $result = Invoke-CycIdentityCommand `
                -Executable $Plan.managedWorker.identityCli `
                -Arguments $initArguments
            $created = $true
            [void](Assert-CycIdentityMetadata `
                -Metadata $result `
                -ExpectedCertificatePath $certificatePath `
                -ExpectedPrivateKeyPath $privateKeyPath `
                -ExpectedHosts $canonicalIdentityHosts `
                -Operation init)
        }
        if (-not (Test-Path -LiteralPath $certificatePath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $privateKeyPath -PathType Leaf)) {
            throw 'Controller TLS identity files were not created atomically.'
        }
        Set-PrivateDirectoryAcl -Path $tlsDirectory
        [string[]]$verifyArguments = @(
            'identity', 'verify',
            '--certificate', $certificatePath,
            '--private-key', $privateKeyPath
        )
        foreach ($identityHost in $canonicalIdentityHosts) {
            $verifyArguments += @('--host', $identityHost)
        }
        $verifyArguments += '--json'
        $verification = Invoke-CycIdentityCommand `
            -Executable $Plan.managedWorker.identityCli `
            -Arguments $verifyArguments
        $fingerprint = Assert-CycIdentityMetadata `
            -Metadata $verification `
            -ExpectedCertificatePath $certificatePath `
            -ExpectedPrivateKeyPath $privateKeyPath `
            -ExpectedHosts $canonicalIdentityHosts `
            -Operation verify
        return [PSCustomObject]@{
            enabled = $true
            created = $created
            fingerprint = $fingerprint
            identityVersion = [string]$Plan.managedWorker.identityVersion
            legacyIdentityPreserved = $legacyIdentityPreserved
            migratedFromLegacy = $created -and $legacyIdentityPreserved
        }
    } catch {
        $failure = $_
        if ($created -or (-not $certificateExists -and -not $privateKeyExists)) {
            foreach ($path in @($privateKeyPath, $certificatePath)) {
                if (Test-Path -LiteralPath $path -PathType Leaf) {
                    Remove-Item -LiteralPath $path -Force
                }
            }
            if (Test-Path -LiteralPath $tlsDirectory -PathType Container) {
                $tlsDirectoryItem = Get-Item -LiteralPath $tlsDirectory -Force
                if (-not (Test-ReparsePoint $tlsDirectoryItem) -and
                    -not (Get-ChildItem -LiteralPath $tlsDirectory -Force | Select-Object -First 1)) {
                    Remove-Item -LiteralPath $tlsDirectory -Force
                }
            }
        }
        throw $failure
    }
}

function Remove-NewCycTlsIdentity {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        $IdentityResult
    )
    if (-not $IdentityResult -or -not $IdentityResult.created) { return }
    foreach ($path in @($Plan.managedWorker.privateKeyPath, $Plan.managedWorker.certificatePath)) {
        $owned = Assert-ChildPath -Root $Plan.managedWorker.tlsDirectory -Candidate $path
        if (Test-Path -LiteralPath $owned -PathType Leaf) {
            Remove-Item -LiteralPath $owned -Force
        }
    }
    $versionDirectory = Resolve-NormalizedPath $Plan.managedWorker.tlsDirectory
    [void](Assert-ChildPath -Root $Plan.managedWorker.tlsRoot -Candidate $versionDirectory)
    if (Test-Path -LiteralPath $versionDirectory -PathType Container) {
        $versionItem = Get-Item -LiteralPath $versionDirectory -Force
        if (-not (Test-ReparsePoint $versionItem) -and
            -not (Get-ChildItem -LiteralPath $versionDirectory -Force | Select-Object -First 1)) {
            Remove-Item -LiteralPath $versionDirectory -Force
        }
    }
}

function Test-IsAdministrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-OwnedCycFirewallRule {
    param([Parameter(Mandatory = $true)][string]$Name)
    $rules = @(Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue)
    if ($rules.Count -gt 1) {
        throw "More than one firewall rule uses the owned name $Name."
    }
    if ($rules.Count -eq 0) { return $null }
    $rule = $rules[0]
    if ([string]$rule.Group -ne $script:FirewallRuleGroup -or
        [string]$rule.Description -ne $script:FirewallRuleDescription) {
        throw "Firewall rule name collision: $Name is not owned by ClusterYourCodex."
    }
    return $rule
}

function Get-CycFirewallSnapshot {
    param([Parameter(Mandatory = $true)]$Firewall)
    $rule = Get-OwnedCycFirewallRule -Name $Firewall.name
    if (-not $rule) {
        return [PSCustomObject]@{ existed = $false; name = $Firewall.name }
    }
    $port = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
    $address = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
    $application = Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
    return [PSCustomObject]@{
        existed = $true
        name = [string]$rule.Name
        displayName = [string]$rule.DisplayName
        enabled = [string]$rule.Enabled
        profile = [string]$rule.Profile
        direction = [string]$rule.Direction
        action = [string]$rule.Action
        protocol = [string]$port.Protocol
        localPort = [string]$port.LocalPort
        remoteAddress = @($address.RemoteAddress)
        program = [string]$application.Program
    }
}

function Remove-CycFirewallRule {
    param([Parameter(Mandatory = $true)][string]$Name)
    $rule = Get-OwnedCycFirewallRule -Name $Name
    if ($rule) {
        Remove-NetFirewallRule -Name $Name -ErrorAction Stop
    }
}

function Set-CycFirewallRule {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][bool]$Enabled
    )
    if (-not (Test-IsAdministrator)) {
        throw 'Managed-worker firewall configuration requires the one-time elevated installer.'
    }
    $firewall = $Plan.managedWorker.firewall
    Remove-CycFirewallRule -Name $firewall.name
    if (-not $Enabled) { return }
    New-NetFirewallRule `
        -Name $firewall.name `
        -DisplayName $firewall.displayName `
        -Group $firewall.group `
        -Description $firewall.description `
        -Direction Inbound `
        -Action Allow `
        -Enabled True `
        -Profile Private `
        -Protocol TCP `
        -LocalPort $Plan.managedWorker.listenPort `
        -RemoteAddress LocalSubnet `
        -Program $Plan.tasks[0].action.executable `
        -EdgeTraversalPolicy Block | Out-Null
    $rule = Get-OwnedCycFirewallRule -Name $firewall.name
    if (-not $rule) { throw 'Managed-worker firewall rule was not created.' }
    $port = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
    $address = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
    $application = Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
    if ([string]$rule.Enabled -ne 'True' -or
        [string]$rule.Direction -ne 'Inbound' -or
        [string]$rule.Action -ne 'Allow' -or
        [string]$rule.Profile -notmatch '^(2|Private)$' -or
        [string]$port.Protocol -notmatch '^(6|TCP)$' -or
        [string]$port.LocalPort -ne [string]$Plan.managedWorker.listenPort -or
        @($address.RemoteAddress) -notcontains 'LocalSubnet' -or
        -not [string]::Equals(
            (Resolve-NormalizedPath ([string]$application.Program)),
            (Resolve-NormalizedPath $Plan.tasks[0].action.executable),
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'Managed-worker firewall rule failed post-install verification.'
    }
}

function Restore-CycFirewallSnapshot {
    param([Parameter(Mandatory = $true)]$Snapshot)
    Remove-CycFirewallRule -Name $Snapshot.name
    if (-not $Snapshot.existed) { return }
    New-NetFirewallRule `
        -Name $Snapshot.name `
        -DisplayName $Snapshot.displayName `
        -Group $script:FirewallRuleGroup `
        -Description $script:FirewallRuleDescription `
        -Direction $Snapshot.direction `
        -Action $Snapshot.action `
        -Enabled $Snapshot.enabled `
        -Profile $Snapshot.profile `
        -Protocol $Snapshot.protocol `
        -LocalPort $Snapshot.localPort `
        -RemoteAddress $Snapshot.remoteAddress `
        -Program $Snapshot.program `
        -EdgeTraversalPolicy Block | Out-Null
}

function Get-CycUninstallRegistrationSnapshot {
    param([Parameter(Mandatory = $true)][string]$RegistryPath)
    if (-not (Test-Path -LiteralPath $RegistryPath)) {
        return [PSCustomObject]@{ existed = $false; values = @() }
    }
    $key = Get-Item -LiteralPath $RegistryPath -ErrorAction Stop
    $values = @($key.GetValueNames() | ForEach-Object {
        [PSCustomObject]@{
            name = [string]$_
            kind = [string]$key.GetValueKind($_)
            value = $key.GetValue(
                $_,
                $null,
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
            )
        }
    })
    return [PSCustomObject]@{ existed = $true; values = $values }
}

function Restore-CycUninstallRegistrationSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$RegistryPath,
        [Parameter(Mandatory = $true)]$Snapshot
    )
    if (Test-Path -LiteralPath $RegistryPath) {
        Remove-Item -LiteralPath $RegistryPath -Recurse -Force
    }
    if (-not $Snapshot.existed) { return }
    [void](New-Item -Path $RegistryPath -Force)
    foreach ($entry in $Snapshot.values) {
        New-ItemProperty `
            -LiteralPath $RegistryPath `
            -Name $entry.name `
            -Value $entry.value `
            -PropertyType $entry.kind `
            -Force | Out-Null
    }
}

function Set-CycUninstallRegistration {
    param([Parameter(Mandatory = $true)]$Plan)
    if (-not $Plan.uninstallRegistration.enabled) { return }
    if (-not (Test-Path -LiteralPath $Plan.uninstallRegistration.installedBootstrap -PathType Leaf)) {
        throw 'Installed bootstrap is missing; refusing a broken uninstall registration.'
    }
    if (-not (Test-Path -LiteralPath $Plan.uninstallRegistration.uninstallerPath -PathType Leaf)) {
        throw 'Installed uninstaller is missing; refusing a broken uninstall registration.'
    }
    $estimatedKilobytes = [Math]::Ceiling(
        (@($Plan.files | Measure-Object -Property length -Sum).Sum) / 1KB
    )
    [void](New-Item -Path $Plan.uninstallRegistration.registryPath -Force)
    $properties = [ordered]@{
        DisplayName = 'ClusterYourCodex'
        DisplayVersion = $script:ProductVersion
        Publisher = 'TypeThe0ry'
        URLInfoAbout = 'https://github.com/TypeThe0ry/ClusterYourCodex'
        InstallLocation = $Plan.installRoot
        DataLocation = $Plan.dataRoot
        DisplayIcon = (Join-Path $Plan.installRoot 'ClusterYourCodex.exe')
        UninstallString = $Plan.uninstallRegistration.uninstallString
        QuietUninstallString = $Plan.uninstallRegistration.quietUninstallString
    }
    foreach ($entry in $properties.GetEnumerator()) {
        New-ItemProperty -LiteralPath $Plan.uninstallRegistration.registryPath `
            -Name $entry.Key -Value $entry.Value -PropertyType String -Force | Out-Null
    }
    foreach ($entry in @(
        @{ Name = 'NoModify'; Value = 1 },
        @{ Name = 'NoRepair'; Value = 1 },
        @{ Name = 'EstimatedSize'; Value = [int][Math]::Min($estimatedKilobytes, [int]::MaxValue) }
    )) {
        New-ItemProperty -LiteralPath $Plan.uninstallRegistration.registryPath `
            -Name $entry.Name -Value $entry.Value -PropertyType DWord -Force | Out-Null
    }
}

function Remove-CycUninstallRegistration {
    param(
        [Parameter(Mandatory = $true)][string]$RegistryPath,
        [Parameter(Mandatory = $true)][string]$ExpectedInstallRoot
    )
    if (-not (Test-Path -LiteralPath $RegistryPath)) { return }
    $registration = Get-ItemProperty -LiteralPath $RegistryPath -ErrorAction Stop
    if (-not $registration.InstallLocation -or
        -not [string]::Equals(
            (Resolve-NormalizedPath ([string]$registration.InstallLocation)),
            (Resolve-NormalizedPath $ExpectedInstallRoot),
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or [string]$registration.Publisher -ne 'TypeThe0ry') {
        throw 'Uninstall registry key is not owned by this ClusterYourCodex installation.'
    }
    Remove-Item -LiteralPath $RegistryPath -Recurse -Force
}

function Read-InstallManifest {
    param([Parameter(Mandatory = $true)][string]$ManifestPath)
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { return $null }
    $item = Get-Item -LiteralPath $ManifestPath -Force
    if ($item.Length -gt $script:MaxInstallManifestBytes) { throw 'Install manifest is unexpectedly large.' }
    $manifest = Read-CycUtf8Json -Path $ManifestPath
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
        Assert-CycCreationPathNoReparse -Path $parent
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

function Invoke-CycProfileMatrixTaskGate {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Register', 'Unregister', 'Restore')][string]$Operation,
        [Parameter(Mandatory = $true)][string]$Name,
        $Action,
        $Snapshot
    )

    if ($script:ProfileMatrixTaskGate -cne 'parent-elevated-registration-v1') {
        throw 'Profile-matrix task gate was requested without its validated parent-helper declaration.'
    }
    $requestId = [Guid]::NewGuid().ToString('N')
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    if ($Operation -eq 'Restore' -and $null -eq $Snapshot) {
        throw 'Profile-matrix restore requires a structured task snapshot.'
    }
    if ($Operation -ne 'Restore' -and $null -ne $Snapshot) {
        throw "Profile-matrix $Operation does not accept a task snapshot."
    }
    $request = [ordered]@{
        schemaVersion = 'cyc.dev/windows-profile-matrix-task-request/v2'
        requestId = $requestId
        operation = $Operation
        taskName = $Name
        sid = [string]$identity.User.Value
        account = [string]$identity.Name
        # WindowsIdentity.Name is only a display projection and may be
        # mojibaked for non-ASCII local accounts under ARM64/x64 emulation.
        # Carry the immutable SID explicitly so the elevated parent helper can
        # bind the request without relying on that lossy account string.
        accountSid = [string]$identity.User.Value
        logonType = 'Interactive'
        action = if ($null -ne $Action) {
            [ordered]@{
                executable = [string]$Action.executable
                arguments = [string]$Action.arguments
                workingDirectory = [string]$Action.workingDirectory
            }
        } else { $null }
        snapshot = if ($Operation -eq 'Restore') {
            [ordered]@{
                schemaVersion = 'cyc.dev/windows-profile-matrix-task-snapshot/v1'
                name = [string]$Snapshot.name
                taskPath = [string]$Snapshot.taskPath
                principalSid = [string]$Snapshot.principalSid
                triggerSids = @($Snapshot.triggerSids | ForEach-Object { [string]$_ })
                action = [ordered]@{
                    executable = [string]$Snapshot.action.executable
                    arguments = [string]$Snapshot.action.arguments
                    workingDirectory = [string]$Snapshot.action.workingDirectory
                }
                wasRunning = [bool]$Snapshot.wasRunning
            }
        } else { $null }
        requestedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    # Write-DurableAtomicJson is intentionally used for the request so the
    # elevated controller never parses a partially-written command.
    Write-DurableAtomicJson `
        -Path $script:ProfileMatrixTaskRequestPath `
        -Value $request `
        -Depth 8

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(60)
    do {
        if (Test-Path -LiteralPath $script:ProfileMatrixTaskResponsePath -PathType Leaf) {
            try {
                $response = Read-CycUtf8Json -Path $script:ProfileMatrixTaskResponsePath
            } catch {
                $response = $null
            }
            if ($null -ne $response -and
                [string]$response.requestId -ceq $requestId) {
                if ([string]$response.schemaVersion -cne 'cyc.dev/windows-profile-matrix-task-helper/v1') {
                    throw 'Profile-matrix parent task helper returned an unknown response schema.'
                }
                if ([string]$response.operation -cne $Operation -or
                    [string]$response.taskName -cne $Name -or
                    [string]$response.sid -cne [string]$identity.User.Value) {
                    throw "Profile-matrix parent task helper returned a response bound to a different operation, task, or SID."
                }
                if ([string]$response.status -cne 'passed') {
                    throw "Profile-matrix parent task helper failed $Operation for $($Name): $([string]$response.error)"
                }
                if ($Operation -eq 'Restore') {
                    if ([string]$response.runtime -cne 'not-started' -or
                        $response.restoredRunning -isnot [bool] -or
                        [bool]$response.restoredRunning) {
                        throw 'Profile-matrix restore response did not preserve registration-only runtime semantics.'
                    }
                    if ([string]$response.observedTaskPath -cne '\' -or
                        [string]$response.observedPrincipalSid -cne [string]$identity.User.Value -or
                        $response.observedTriggerSids -isnot [System.Array] -or
                        @($response.observedTriggerSids).Count -ne 1 -or
                        [string]$response.observedTriggerSids[0] -cne [string]$identity.User.Value) {
                        throw 'Profile-matrix restore response did not preserve task identity bindings.'
                    }
                    $observedAction = $response.PSObject.Properties['observedAction']
                    if ($null -eq $observedAction -or $null -eq $observedAction.Value -or
                        -not [string]::Equals([string]$observedAction.Value.executable, [string]$Snapshot.action.executable, [System.StringComparison]::OrdinalIgnoreCase) -or
                        -not [string]::Equals([string]$observedAction.Value.arguments, [string]$Snapshot.action.arguments, [System.StringComparison]::Ordinal) -or
                        -not [string]::Equals([string]$observedAction.Value.workingDirectory, [string]$Snapshot.action.workingDirectory, [System.StringComparison]::OrdinalIgnoreCase)) {
                        throw 'Profile-matrix restore response action does not match the requested snapshot.'
                    }
                }
                return $response
            }
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw "Profile-matrix parent task helper timed out for $Operation $Name. request=$($script:ProfileMatrixTaskRequestPath) response=$($script:ProfileMatrixTaskResponsePath)"
}

function ConvertTo-CycTaskSnapshotSid {
    param([Parameter(Mandatory = $true)][string]$Identity)
    $value = $Identity.Trim()
    if ($value -match '^S-\d-\d+(?:-\d+)+$') { return $value }
    try {
        return ([System.Security.Principal.NTAccount]::new($value)).Translate(
            [System.Security.Principal.SecurityIdentifier]
        ).Value
    } catch {
        throw "Unable to resolve Scheduled Task identity '$Identity' to a SID."
    }
}

function Get-CycTaskExpectedExecutable {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )
    $root = Resolve-NormalizedPath $InstallRoot
    if ([string]::Equals($Name, $script:ControllerTaskName, [System.StringComparison]::Ordinal)) {
        return Join-Path $root 'cyc-controller.exe'
    }
    if ([string]::Equals($Name, $script:WorkerTaskName, [System.StringComparison]::Ordinal)) {
        return Join-Path $root 'cyc-worker.exe'
    }
    throw "Scheduled Task $Name is not a ClusterYourCodex-owned task name."
}

function Assert-CycTaskActionBinding {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)]$Action
    )
    $prefix = "Scheduled Task $Name ownership validation failed"
    if ($null -eq $Action -or $Action -is [System.Array]) {
        throw ($prefix + ': action is not a single object.')
    }
    $executable = [string]$Action.executable
    $workingDirectory = [string]$Action.workingDirectory
    if ([string]::IsNullOrWhiteSpace($executable) -or
        [string]::IsNullOrWhiteSpace($workingDirectory)) {
        throw ($prefix + ': action executable and working directory are required.')
    }
    try {
        $root = Resolve-NormalizedPath $InstallRoot
        $expectedExecutable = Resolve-NormalizedPath (Get-CycTaskExpectedExecutable -Name $Name -InstallRoot $root)
        $actualExecutable = Resolve-NormalizedPath $executable
        $actualWorkingDirectory = Resolve-NormalizedPath $workingDirectory
    } catch {
        throw ($prefix + ': action paths could not be normalized.')
    }
    if (-not [string]::Equals(
            $actualExecutable,
            $expectedExecutable,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        throw ($prefix + ': action executable does not match the requested install root.')
    }
    if (-not [string]::Equals(
            $actualWorkingDirectory,
            $root,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        throw ($prefix + ': action working directory does not match the requested install root.')
    }
    return [PSCustomObject]@{
        executable = $actualExecutable
        arguments = [string]$Action.arguments
        workingDirectory = $actualWorkingDirectory
    }
}

function Assert-CycTaskSnapshotOwnership {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [string]$ExpectedSid
    )
    $prefix = 'Scheduled Task ownership validation failed'
    $currentSid = Get-CurrentUserSid
    if ([string]::IsNullOrWhiteSpace($ExpectedSid)) { $ExpectedSid = $currentSid }
    try {
        $ExpectedSid = ConvertTo-CycTaskSnapshotSid -Identity $ExpectedSid
    } catch {
        throw ($prefix + ': initiating SID could not be resolved.')
    }
    if (-not [string]::Equals(
            $ExpectedSid,
            $currentSid,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        throw ($prefix + ': expected SID does not match the current Windows account.')
    }
    if ($null -eq $Snapshot -or $Snapshot -is [System.Array]) {
        throw ($prefix + ': task snapshot is not a single object.')
    }
    $name = [string]$Snapshot.name
    if (-not [string]::Equals($name, $script:ControllerTaskName, [System.StringComparison]::Ordinal) -and
        -not [string]::Equals($name, $script:WorkerTaskName, [System.StringComparison]::Ordinal)) {
        throw ($prefix + ': task name is not owned by ClusterYourCodex.')
    }
    if ([string]$Snapshot.taskPath -cne '\') {
        throw ($prefix + ': task is outside the root Task Scheduler path.')
    }
    $principalSid = [string]$Snapshot.principalSid
    if ([string]::IsNullOrWhiteSpace($principalSid) -or
        -not [string]::Equals($principalSid, $ExpectedSid, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ($prefix + ': task principal SID does not match the initiating SID.')
    }
    $triggerSids = $Snapshot.triggerSids
    if ($triggerSids -isnot [System.Array] -or @($triggerSids).Count -ne 1 -or
        [string]::IsNullOrWhiteSpace([string]$triggerSids[0]) -or
        -not [string]::Equals([string]$triggerSids[0], $ExpectedSid, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ($prefix + ': task logon trigger SID does not match the initiating SID.')
    }
    [void](Assert-CycTaskActionBinding -Name $name -InstallRoot $InstallRoot -Action $Snapshot.action)
    return $Snapshot
}

function Get-CycTaskSnapshotByName {
    param([Parameter(Mandatory = $true)][string]$Name)
    $tasks = @(Get-ScheduledTask -TaskName $Name -TaskPath '\' -ErrorAction SilentlyContinue)
    if ($tasks.Count -gt 1) {
        throw "Multiple root Scheduled Tasks found for $Name."
    }
    $task = $tasks | Select-Object -First 1
    if ($null -eq $task) { return $null }

    $taskActionsProperty = $task.PSObject.Properties['Actions']
    $taskActions = @(
        if ($null -ne $taskActionsProperty -and $null -ne $taskActionsProperty.Value) {
            $taskActionsProperty.Value | Select-Object -First 1
        }
    )
    if ($taskActions.Count -ne 1) { throw "Scheduled Task $Name has no single action to snapshot." }
    $workingDirectoryProperty = $taskActions[0].PSObject.Properties['WorkingDirectory']

    $taskTriggersProperty = $task.PSObject.Properties['Triggers']
    $taskTriggers = @(
        if ($null -ne $taskTriggersProperty -and $null -ne $taskTriggersProperty.Value) {
            $taskTriggersProperty.Value
        }
    )
    $triggerSids = @($taskTriggers | ForEach-Object {
            $userProperty = $_.PSObject.Properties['UserId']
            if ($null -ne $userProperty -and -not [string]::IsNullOrWhiteSpace([string]$userProperty.Value)) {
                ConvertTo-CycTaskSnapshotSid ([string]$userProperty.Value)
            }
        })
    if ($triggerSids.Count -ne 1) {
        throw "Scheduled Task $Name must have exactly one logon trigger identity to snapshot."
    }

    $principalProperty = $task.PSObject.Properties['Principal']
    $principal = if ($null -ne $principalProperty) { $principalProperty.Value } else { $null }
    $principalUserProperty = if ($null -ne $principal) { $principal.PSObject.Properties['UserId'] } else { $null }
    if ($null -eq $principalUserProperty -or
        [string]::IsNullOrWhiteSpace([string]$principalUserProperty.Value)) {
        throw "Scheduled Task $Name has no principal identity to snapshot."
    }
    $stateProperty = $task.PSObject.Properties['State']
    $xml = Export-ScheduledTask -TaskName $Name -TaskPath '\'
    return [PSCustomObject]@{
        name = $Name
        xml = $xml
        taskPath = [string]$task.TaskPath
        principalSid = ConvertTo-CycTaskSnapshotSid ([string]$principalUserProperty.Value)
        triggerSids = $triggerSids
        action = [PSCustomObject]@{
            executable = [string]$taskActions[0].Execute
            arguments = [string]$taskActions[0].Arguments
            workingDirectory = if ($null -ne $workingDirectoryProperty) {
                [string]$workingDirectoryProperty.Value
            } else { '' }
        }
        wasRunning = ($null -ne $stateProperty -and [string]$stateProperty.Value -eq 'Running')
    }
}

function Assert-CycLiveTaskOwnership {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [string]$ExpectedSid
    )
    $snapshot = Get-CycTaskSnapshotByName -Name $Name
    if ($null -eq $snapshot) { return $null }
    return Assert-CycTaskSnapshotOwnership `
        -Snapshot $snapshot `
        -InstallRoot $InstallRoot `
        -ExpectedSid $ExpectedSid
}

function Register-CycTask {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Action,
        [Parameter(Mandatory = $true)][string]$ExpectedInstallRoot,
        [string]$ExpectedSid,
        [ValidateSet('Interactive', 'S4U')]
        [string]$LogonType = $script:ScheduledTaskLogonType
    )
    if ($ProfileMatrixTestMode -and $LogonType -cne 'S4U') {
        throw 'Legacy profile-matrix test mode requires the S4U test principal.'
    }
    if (-not $ProfileMatrixTestMode -and $LogonType -cne 'Interactive') {
        throw 'Production task registration requires the Interactive principal.'
    }
    [void](Assert-CycTaskActionBinding -Name $Name -InstallRoot $ExpectedInstallRoot -Action $Action)
    [void](Assert-CycLiveTaskOwnership -Name $Name -InstallRoot $ExpectedInstallRoot -ExpectedSid $ExpectedSid)
    if ($script:ProfileMatrixTaskGate -ne 'none') {
        [void](Invoke-CycProfileMatrixTaskGate -Operation Register -Name $Name -Action $Action)
        return
    }
    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $taskSid = if ([string]::IsNullOrWhiteSpace($ExpectedSid)) {
        Get-CurrentUserSid
    } else {
        ConvertTo-CycTaskSnapshotSid -Identity $ExpectedSid
    }
    $currentSid = Get-CurrentUserSid
    if (-not [string]::Equals(
            [string]$taskSid,
            [string]$currentSid,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'Scheduled Task registration identity does not match the current Windows account.'
    }
    $identity = Resolve-CycScheduledTaskAccountName `
        -Sid $taskSid `
        -FallbackUserName ([string]$currentIdentity.Name)
    $taskAction = New-ScheduledTaskAction `
        -Execute $Action.executable `
        -Argument $Action.arguments `
        -WorkingDirectory $Action.workingDirectory
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
    $principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType $LogonType -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet `
        -MultipleInstances IgnoreNew `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero)
    # Re-check directly before the forceful replacement.  A task with the
    # product name but another owner/install root must never be overwritten.
    [void](Assert-CycLiveTaskOwnership -Name $Name -InstallRoot $ExpectedInstallRoot -ExpectedSid $ExpectedSid)
    Register-ScheduledTask `
        -TaskName $Name `
        -TaskPath '\' `
        -Action $taskAction `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description 'ClusterYourCodex per-user background component' `
        -Force | Out-Null
}

function Unregister-CycTask {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ExpectedInstallRoot,
        [string]$ExpectedSid
    )
    $snapshot = Assert-CycLiveTaskOwnership `
        -Name $Name `
        -InstallRoot $ExpectedInstallRoot `
        -ExpectedSid $ExpectedSid
    if ($script:ProfileMatrixTaskGate -ne 'none') {
        [void](Invoke-CycProfileMatrixTaskGate -Operation Unregister -Name $Name)
        return
    }
    if ($null -ne $snapshot) {
        Stop-ScheduledTask -TaskName $Name -TaskPath '\' -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $Name -TaskPath '\' -Confirm:$false
    }
}

function Get-CycTaskSnapshots {
    param(
        [Parameter(Mandatory = $true)][string]$ExpectedInstallRoot,
        [string]$ExpectedSid
    )
    $snapshots = @()
    foreach ($name in @($script:ControllerTaskName, $script:WorkerTaskName)) {
        $snapshot = Get-CycTaskSnapshotByName -Name $name
        if ($null -ne $snapshot) {
            [void](Assert-CycTaskSnapshotOwnership `
                -Snapshot $snapshot `
                -InstallRoot $ExpectedInstallRoot `
                -ExpectedSid $ExpectedSid)
            $snapshots += $snapshot
        }
    }
    return $snapshots
}

function Stop-CycRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [string]$ExpectedSid
    )
    foreach ($name in @($script:WorkerTaskName, $script:ControllerTaskName)) {
        $snapshot = Assert-CycLiveTaskOwnership `
            -Name $name `
            -InstallRoot $InstallRoot `
            -ExpectedSid $ExpectedSid
        if ($null -ne $snapshot) {
            Stop-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction SilentlyContinue
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
            try {
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
            } catch {
                # A scheduled-task process can exit between the snapshot and
                # the stop request. Treat that narrow race as already stopped,
                # but preserve access-denied and other real failures.
                if (Get-Process -Id $process.Id -ErrorAction SilentlyContinue) {
                    throw
                }
            }
            Wait-Process -Id $process.Id -Timeout 15 -ErrorAction SilentlyContinue
        }
    }
}

function Assert-CycListenPortsAvailable {
    param([Parameter(Mandatory = $true)][int[]]$Ports)
    foreach ($port in @($Ports | Sort-Object -Unique)) {
        $listeners = @(Get-NetTCPConnection `
            -State Listen `
            -LocalPort $port `
            -ErrorAction SilentlyContinue)
        if ($listeners.Count -gt 0) {
            $owners = @($listeners | ForEach-Object { [int]$_.OwningProcess } | Sort-Object -Unique)
            throw "TCP port $port is already listening (PID $($owners -join ','))."
        }
    }
}

function Restore-CycTaskSnapshots {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Snapshots,
        [Parameter(Mandatory = $true)][string]$ExpectedInstallRoot,
        [string]$ExpectedSid
    )

    # Validate every captured task before unregistering either name.  This is
    # the rollback boundary: a same-name task introduced by another user or
    # installation must remain untouched rather than being used as a restore
    # target.
    $validatedSnapshots = @()
    foreach ($snapshot in @($Snapshots)) {
        [void](Assert-CycTaskSnapshotOwnership `
            -Snapshot $snapshot `
            -InstallRoot $ExpectedInstallRoot `
            -ExpectedSid $ExpectedSid)
        $validatedSnapshots += $snapshot
    }

    if ($script:ProfileMatrixTaskGate -ne 'none') {
        $validated = @()
        $seen = @{}
        $currentSid = [string]([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        foreach ($snapshot in @($Snapshots)) {
            if ($null -eq $snapshot -or $snapshot -is [System.Array]) {
                throw 'Profile-matrix rollback received a non-object task snapshot.'
            }
            $name = [string]$snapshot.name
            if ($name -notin @($script:ControllerTaskName, $script:WorkerTaskName) -or $seen.ContainsKey($name)) {
                throw "Profile-matrix rollback received an invalid or duplicate task snapshot: $name"
            }
            $seen[$name] = $true
            if ([string]$snapshot.taskPath -cne '\' -or
                [string]$snapshot.principalSid -notmatch '^S-\d-\d+(?:-\d+)+$' -or
                [string]$snapshot.principalSid -cne $currentSid -or
                $snapshot.triggerSids -isnot [System.Array] -or @($snapshot.triggerSids).Count -ne 1 -or
                [string]$snapshot.triggerSids[0] -notmatch '^S-\d-\d+(?:-\d+)+$' -or
                [string]$snapshot.triggerSids[0] -cne $currentSid -or
                $snapshot.action -is [System.Array] -or $null -eq $snapshot.action -or
                [string]::IsNullOrWhiteSpace([string]$snapshot.action.executable) -or
                [string]::IsNullOrWhiteSpace([string]$snapshot.action.workingDirectory) -or
                $snapshot.wasRunning -isnot [bool]) {
                throw "Profile-matrix rollback received an invalid task snapshot for $name."
            }
            if ([bool]$snapshot.wasRunning) {
                throw 'Profile-matrix registration-only rollback cannot restore a running task.'
            }
            $validated += [PSCustomObject]@{
                name = $name
                taskPath = '\'
                principalSid = [string]$snapshot.principalSid
                triggerSids = @([string]$snapshot.triggerSids[0])
                action = [PSCustomObject]@{
                    executable = [string]$snapshot.action.executable
                    arguments = [string]$snapshot.action.arguments
                    workingDirectory = [string]$snapshot.action.workingDirectory
                }
                wasRunning = $false
            }
        }
        # Validate the complete snapshot set before unregistering anything so
        # malformed rollback data cannot destroy the pre-existing task state.
        foreach ($name in @($script:WorkerTaskName, $script:ControllerTaskName)) {
            Unregister-CycTask `
                -Name $name `
                -ExpectedInstallRoot $ExpectedInstallRoot `
                -ExpectedSid $ExpectedSid
        }
        foreach ($snapshot in @($validated)) {
            [void](Invoke-CycProfileMatrixTaskGate -Operation Restore -Name $snapshot.name -Snapshot $snapshot)
        }
        return
    }
    foreach ($name in @($script:WorkerTaskName, $script:ControllerTaskName)) {
        Unregister-CycTask `
            -Name $name `
            -ExpectedInstallRoot $ExpectedInstallRoot `
            -ExpectedSid $ExpectedSid
    }
    foreach ($snapshot in $validatedSnapshots) {
        # Registration-only rollback expects the task to be absent after the
        # ownership-checked unregister above.  Omitting -Force makes a race
        # with a foreign task fail closed instead of overwriting it.
        [void](Assert-CycLiveTaskOwnership `
            -Name ([string]$snapshot.name) `
            -InstallRoot $ExpectedInstallRoot `
            -ExpectedSid $ExpectedSid)
        Register-ScheduledTask -TaskName $snapshot.name -TaskPath '\' -Xml $snapshot.xml | Out-Null
        if ($snapshot.wasRunning) {
            Start-ScheduledTask -TaskName $snapshot.name -TaskPath '\'
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
    $lastObservedState = 'missing'
    $lastObservedResult = $null
    $lastObservedRunTime = $null
    $lastObservedAction = $null
    $lastObservedProcess = $null
    do {
        $task = Get-ScheduledTask -TaskName $Name -TaskPath '\' -ErrorAction SilentlyContinue
        if ($task) {
            $lastObservedState = [string]$task.State
            $actionsProperty = $task.PSObject.Properties['Actions']
            if ($null -ne $actionsProperty -and $null -ne $actionsProperty.Value) {
                $action = @($actionsProperty.Value | Select-Object -First 1)
                if ($action.Count -eq 1) {
                    $lastObservedAction = (([string]$action[0].Execute) + ' ' + ([string]$action[0].Arguments)).Trim()
                    $executableName = Split-Path -Leaf ([string]$action[0].Execute)
                    if (-not [string]::IsNullOrWhiteSpace($executableName)) {
                        $executableName = [System.IO.Path]::GetFileNameWithoutExtension($executableName)
                        $lastObservedProcess = (@(Get-Process -Name $executableName -ErrorAction SilentlyContinue |
                            Select-Object -First 5 |
                            ForEach-Object { "#$($_.Id)" })) -join ','
                        if ([string]::IsNullOrWhiteSpace($lastObservedProcess)) { $lastObservedProcess = 'absent' }
                    }
                }
            }
            try {
                $taskInfo = Get-ScheduledTaskInfo -TaskName $Name -TaskPath '\' -ErrorAction Stop
                $lastObservedResult = [long]$taskInfo.LastTaskResult
                $lastObservedRunTime = [string]$taskInfo.LastRunTime
            } catch {
                $lastObservedResult = 'unavailable'
                $lastObservedRunTime = 'unavailable'
            }
        } else {
            $lastObservedState = 'missing'
            $lastObservedProcess = 'unavailable'
        }
        if ($task -and [string]$task.State -eq 'Running') {
            if (-not $runningSince) { $runningSince = [DateTime]::UtcNow }
            if (([DateTime]::UtcNow - $runningSince).TotalSeconds -ge $StableSeconds) {
                $taskInfo = Get-ScheduledTaskInfo -TaskName $Name -TaskPath '\' -ErrorAction Stop
                $lastResult = [long]$taskInfo.LastTaskResult
                if ($lastResult -notin @(0, 267009)) {
                    throw "Scheduled Task reported failure while running: $Name (result=$lastResult, state=$lastObservedState, lastRun=$lastObservedRunTime, process=$lastObservedProcess, action=$lastObservedAction)"
                }
                return
            }
        } else {
            $runningSince = $null
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Scheduled Task did not remain healthy for $StableSeconds seconds: $Name (state=$lastObservedState, lastResult=$lastObservedResult, lastRun=$lastObservedRunTime, process=$lastObservedProcess, action=$lastObservedAction)"
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
    # x64 binaries under Windows 11 ARM64 emulation can take materially longer
    # to start and answer their first request than native x64. Keep readiness
    # bounded, but do not turn a slow first start into a false install failure.
    param([int]$TimeoutSeconds = 60)

    function Test-CycControllerLoopbackHealth {
        $client = New-Object System.Net.Sockets.TcpClient
        $stream = $null
        $connectWaitHandle = $null
        try {
            $connect = $client.BeginConnect('127.0.0.1', 47831, $null, $null)
            $connectWaitHandle = $connect.AsyncWaitHandle
            if (-not $connectWaitHandle.WaitOne(5000)) {
                return $false
            }
            $client.EndConnect($connect)
            $stream = $client.GetStream()
            $stream.ReadTimeout = 5000
            $stream.WriteTimeout = 5000

            # The controller validates the complete loopback authority,
            # including its bound port.  Keep this probe proxy-independent,
            # but send the same Host value a normal URI request would produce.
            $request = [Text.Encoding]::ASCII.GetBytes(
                "GET /v1/health HTTP/1.1`r`nHost: 127.0.0.1:47831`r`nConnection: close`r`n`r`n"
            )
            $stream.Write($request, 0, $request.Length)
            $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
            try {
                $response = $reader.ReadToEnd()
            } finally {
                $reader.Dispose()
            }

            $separator = $response.IndexOf("`r`n`r`n", [StringComparison]::Ordinal)
            if ($separator -lt 0) {
                return $false
            }
            $headers = $response.Substring(0, $separator)
            if ($headers -notmatch '(?m)^HTTP/1\.1 200(?:\s|$)') {
                return $false
            }
            $body = $response.Substring($separator + 4)
            if ([string]::IsNullOrWhiteSpace($body) -or $body.Length -gt 1MB) {
                return $false
            }
            try {
                $health = $body | ConvertFrom-Json
            } catch {
                return $false
            }
            return ([string]$health.status -ceq 'ok' -and
                -not [string]::IsNullOrWhiteSpace([string]$health.apiVersion))
        } catch {
            return $false
        } finally {
            if ($stream) { $stream.Dispose() }
            if ($connectWaitHandle) { $connectWaitHandle.Dispose() }
            $client.Dispose()
        }
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (Test-CycControllerLoopbackHealth) { return }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Controller failed the loopback health check.'
}

function Wait-CycManagedWorkerListenerReady {
    param(
        [Parameter(Mandatory = $true)]$ManagedWorker,
        [int]$TimeoutSeconds = 15
    )
    if (-not $ManagedWorker.enabled) { return }
    try {
        $expectedCertificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
            $ManagedWorker.certificatePath
        )
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $expectedHash = [Convert]::ToBase64String(
                $sha256.ComputeHash($expectedCertificate.RawData)
            )
        } finally {
            $sha256.Dispose()
            $expectedCertificate.Dispose()
        }
    } catch {
        throw 'Managed-worker TLS certificate could not be loaded for readiness verification.'
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $client = $null
        $stream = $null
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $async = $client.BeginConnect(
                [string]$ManagedWorker.bindHost,
                [int]$ManagedWorker.listenPort,
                $null,
                $null
            )
            if (-not $async.AsyncWaitHandle.WaitOne(1000)) {
                throw 'TLS listener connect timed out.'
            }
            $client.EndConnect($async)
            $callback = {
                param($sender, $certificate, $chain, $errors)
                if (-not $certificate) { return $false }
                $remote = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certificate)
                $hash = [System.Security.Cryptography.SHA256]::Create()
                try {
                    $actual = [Convert]::ToBase64String($hash.ComputeHash($remote.RawData))
                    return [string]::Equals($actual, $expectedHash, [System.StringComparison]::Ordinal)
                } finally {
                    $hash.Dispose()
                    $remote.Dispose()
                }
            }.GetNewClosure()
            $stream = New-Object System.Net.Security.SslStream($client.GetStream(), $false, $callback)
            $stream.AuthenticateAsClient([string]$ManagedWorker.publicHost)
            if ($stream.IsAuthenticated -and $stream.IsEncrypted) { return }
        } catch {
            # Startup is bounded and retried without serializing certificate data.
        } finally {
            if ($stream) { $stream.Dispose() }
            if ($client) { $client.Dispose() }
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Managed-worker TLS listener failed certificate-pinned readiness verification.'
}

function New-FileRollbackSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        $OldManifest
    )
    $transactionsRoot = Join-Path $Plan.dataRoot '.installer\transactions'
    $transactionRoot = Join-Path $transactionsRoot ([Guid]::NewGuid().ToString('N'))
    [void](Assert-ChildPath -Root $transactionsRoot -Candidate $transactionRoot)
    Assert-CycCreationPathNoReparse -Path $transactionsRoot
    Set-PrivateDirectoryAcl -Path $transactionsRoot
    Assert-CycCreationPathNoReparse -Path $transactionRoot
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
            Assert-CycCreationPathNoReparse -Path (Split-Path -Parent $backup)
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
    # Snapshot roots and every copied descendant are durable private state. A
    # later recovery pass must verify them before reading a journal, so
    # normalize the exact protected ACL after all copies are present.
    Set-PrivateDirectoryAcl -Path $transactionRoot
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
    if (Test-Path -LiteralPath $Snapshot.root -PathType Container) {
        Assert-CycPrivateStateTree -Root $Snapshot.root
    }
    foreach ($record in $Snapshot.files) {
        if ($record.existed) {
            Assert-CycCreationPathNoReparse -Path (Split-Path -Parent $record.targetPath)
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $record.targetPath) -Force)
            $temporary = $record.targetPath + '.cyc-rollback-' + [Guid]::NewGuid().ToString('N')
            Copy-Item -LiteralPath $record.backupPath -Destination $temporary -Force
            Move-Item -LiteralPath $temporary -Destination $record.targetPath -Force
        } elseif (Test-Path -LiteralPath $record.targetPath -PathType Leaf) {
            Remove-Item -LiteralPath $record.targetPath -Force
        }
    }
    if ($Snapshot.manifestExisted) {
        Assert-CycCreationPathNoReparse -Path (Split-Path -Parent $Snapshot.manifestPath)
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
        Assert-CycPrivateStateTree -Root $target
        # Exact transaction target was proven beneath the installer-owned root.
        Remove-Item -LiteralPath $target -Recurse -Force
    }
    if ((Test-Path -LiteralPath $Snapshot.transactionsRoot -PathType Container) -and
        -not (Get-ChildItem -LiteralPath $Snapshot.transactionsRoot -Force | Select-Object -First 1)) {
        Remove-Item -LiteralPath $Snapshot.transactionsRoot -Force
    }
}

function Get-CodexCliCandidates {
    $candidates = New-Object System.Collections.Generic.List[string]

    foreach ($value in @($env:CYC_CODEX_CLI, $env:CODEX_CLI_PATH)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            [void]$candidates.Add([string]$value)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $managedBin = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
        if (Test-Path -LiteralPath $managedBin -PathType Container) {
            foreach ($directory in @(Get-ChildItem -LiteralPath $managedBin -Directory -Force -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTimeUtc -Descending)) {
                [void]$candidates.Add((Join-Path $directory.FullName 'codex.exe'))
            }
            [void]$candidates.Add((Join-Path $managedBin 'codex.exe'))
        }
    }

    $homeRoot = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        [string]$env:CODEX_HOME
    } elseif (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        Join-Path $env:USERPROFILE '.codex'
    } else {
        $null
    }
    if ($homeRoot) {
        [void]$candidates.Add((Join-Path $homeRoot 'plugins\.plugin-appserver\codex.exe'))
    }

    foreach ($command in @(Get-Command codex -All -CommandType Application, ExternalScript -ErrorAction SilentlyContinue)) {
        if ($command.Source) {
            [void]$candidates.Add([string]$command.Source)
        }
    }

    $seen = @{}
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        try { $fullPath = [System.IO.Path]::GetFullPath($candidate) } catch { continue }
        $key = $fullPath.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $fullPath
        }
    }
}

function Invoke-CycBoundedCodexProcess {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [ValidateRange(100, 90000)][int]$TimeoutMilliseconds = 20000
    )
    $path = Resolve-NormalizedPath $Executable
    if (-not [System.IO.Path]::IsPathRooted($path) -or $path.Contains('"') -or
        $path.Contains("`r") -or $path.Contains("`n")) {
        throw 'Codex CLI path is not a strict absolute executable path.'
    }
    $extension = [System.IO.Path]::GetExtension($path)
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    if ($extension -ieq '.cmd' -or $extension -ieq '.bat') {
        if ($path -match '[%!]') { throw 'Test CLI script path contains unsupported expansion characters.' }
        $start.FileName = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
        $start.Arguments = '/d /s /c ""' + $path + '" ' + ([string]::Join(' ', $Arguments)) + '"'
    } else {
        $start.FileName = $path
        $start.Arguments = [string]::Join(' ', $Arguments)
    }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Codex CLI process did not start.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            try { $process.Kill() } catch { }
            try { $process.WaitForExit() } catch { }
            throw 'Codex CLI process exceeded its bounded verification timeout.'
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        return [PSCustomObject]@{
            exitCode = [int]$process.ExitCode
            stdout = [string]$stdout
            stderr = [string]$stderr
        }
    } finally {
        $process.Dispose()
    }
}

function Resolve-CodexCli {
    param(
        [string]$RequestedPath,
        [ValidateRange(100, 30000)][int]$TimeoutMilliseconds = 10000
    )
    # The Store-packaged desktop can expose a WindowsApps resource through
    # Get-Command even when that path cannot be launched by an external
    # installer. Probe each candidate and continue to the app-managed CLI
    # under LocalAppData instead of treating a regular file as availability.
    $candidates = if ([string]::IsNullOrWhiteSpace($RequestedPath)) {
        @(Get-CodexCliCandidates)
    } else {
        if (-not [System.IO.Path]::IsPathRooted($RequestedPath) -or
            $RequestedPath.Contains('"') -or $RequestedPath.Contains("`r") -or $RequestedPath.Contains("`n")) {
            throw 'IntegrateCodex requires an exact absolute Codex CLI path from the native host.'
        }
        @((Resolve-NormalizedPath $RequestedPath))
    }
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        try {
            $volumeRoot = [System.IO.Path]::GetPathRoot((Resolve-NormalizedPath $candidate))
            [void](Assert-CycNoReparsePathChain -Root $volumeRoot -Candidate $candidate -LeafType File)
            $probe = Invoke-CycBoundedCodexProcess `
                -Executable $candidate `
                -Arguments @('--version') `
                -TimeoutMilliseconds $TimeoutMilliseconds
            if ($probe.exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($probe.stdout) -and
                $probe.stdout.Length -le 256 -and -not $probe.stdout.Contains("`0")) {
                return [PSCustomObject]@{ Source = (Resolve-NormalizedPath $candidate) }
            }
        } catch {
            # Candidate is present but not executable in this security context.
        }
    }
    return $null
}

function Resolve-CycComparablePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $candidate = $Path.Trim()
    if ($candidate.StartsWith('\\?\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $candidate = '\\' + $candidate.Substring(8)
    } elseif ($candidate.StartsWith('\\?\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $candidate = $candidate.Substring(4)
    }
    return Resolve-NormalizedPath $candidate
}

function Read-CycCodexPluginManifest {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "ClusterYourCodex plugin manifest is missing: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ((Test-ReparsePoint $item) -or $item.Length -lt 2 -or $item.Length -gt 256KB) {
        throw 'ClusterYourCodex plugin manifest must be a bounded regular file.'
    }
    [byte[]]$bytes = [System.IO.File]::ReadAllBytes($Path)
    $offset = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and
        $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) { 3 } else { 0 }
    [byte[]]$body = New-Object byte[] ($bytes.Length - $offset)
    if ($body.Length -gt 0) { [System.Buffer]::BlockCopy($bytes, $offset, $body, 0, $body.Length) }
    $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
    try { $raw = $strictUtf8.GetString($body) } catch {
        throw 'ClusterYourCodex plugin manifest must be valid UTF-8.'
    }
    try { $manifest = $raw | ConvertFrom-Json } catch {
        throw 'ClusterYourCodex plugin manifest contains invalid JSON.'
    }
    $nameProperty = $manifest.PSObject.Properties['name']
    $versionProperty = $manifest.PSObject.Properties['version']
    if (-not $nameProperty -or -not ($nameProperty.Value -is [string]) -or
        [string]$nameProperty.Value -cne 'cluster-your-codex' -or
        -not $versionProperty -or -not ($versionProperty.Value -is [string]) -or
        [string]$versionProperty.Value -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
        throw 'ClusterYourCodex plugin manifest has an invalid name or semantic version.'
    }
    return [PSCustomObject]@{
        name = [string]$nameProperty.Value
        version = [string]$versionProperty.Value
        path = Resolve-NormalizedPath $Path
        sha256 = Get-CycSha256Hex -Bytes $bytes
    }
}

function Get-CycCodexPluginExpectation {
    param(
        [Parameter(Mandatory = $true)][string]$MarketplaceRoot,
        [string]$PluginId = $script:CodexPluginId
    )
    if ($PluginId -cne $script:CodexPluginId) {
        throw 'Unexpected ClusterYourCodex plugin identity.'
    }
    $marketplace = Assert-CycRealDirectory -Path $MarketplaceRoot -Label 'Codex marketplace'
    $sourcePath = Assert-CycRealDirectory `
        -Path (Assert-ChildPath `
            -Root $marketplace `
            -Candidate (Join-Path $marketplace 'plugins\cluster-your-codex')) `
        -Label 'ClusterYourCodex plugin source'
    $pluginManifest = Read-CycCodexPluginManifest `
        -Path (Join-Path $sourcePath '.codex-plugin\plugin.json')
    return [PSCustomObject]@{
        pluginId = $PluginId
        pluginName = 'cluster-your-codex'
        marketplaceName = 'clusteryourcodex'
        marketplaceRoot = $marketplace
        sourceType = 'local'
        sourcePath = $sourcePath
        version = $pluginManifest.version
        pluginManifestPath = $pluginManifest.path
        pluginManifestSha256 = $pluginManifest.sha256
    }
}

function New-CycInactivePluginVerification {
    param(
        [int]$ExitCode,
        [Parameter(Mandatory = $true)][string]$Reason
    )
    return [PSCustomObject]@{
        active = $false
        exitCode = $ExitCode
        reason = $Reason
        pluginVersion = $null
        sourceType = $null
        sourcePath = $null
    }
}

function Test-CycCodexPluginActive {
    param(
        [Parameter(Mandatory = $true)]$Codex,
        [Parameter(Mandatory = $true)]$ExpectedPlugin,
        [ValidateRange(100, 30000)][int]$TimeoutMilliseconds = 20000
    )
    try {
        $result = Invoke-CycBoundedCodexProcess `
            -Executable ([string]$Codex.Source) `
            -Arguments @('plugin', 'list', '--json') `
            -TimeoutMilliseconds $TimeoutMilliseconds
        $exitCode = [int]$result.exitCode
        $raw = [string]$result.stdout
    } catch {
        return New-CycInactivePluginVerification -ExitCode -1 -Reason 'plugin-list-launch-failed'
    }
    if ($exitCode -ne 0) {
        return New-CycInactivePluginVerification -ExitCode $exitCode -Reason 'plugin-list-nonzero'
    }
    if ([string]::IsNullOrWhiteSpace($raw) -or $raw.Length -gt 1MB) {
        return New-CycInactivePluginVerification -ExitCode $exitCode -Reason 'plugin-list-unbounded-or-empty'
    }
    try { $listing = $raw | ConvertFrom-Json } catch {
        return New-CycInactivePluginVerification -ExitCode $exitCode -Reason 'plugin-list-invalid-json'
    }
    $installedProperty = $listing.PSObject.Properties['installed']
    if (-not $installedProperty -or -not ($installedProperty.Value -is [System.Array])) {
        return New-CycInactivePluginVerification -ExitCode $exitCode -Reason 'plugin-list-missing-installed-array'
    }
    $installedEntries = @($installedProperty.Value)
    if ($installedEntries.Count -gt 10000) {
        return New-CycInactivePluginVerification -ExitCode $exitCode -Reason 'plugin-list-too-many-entries'
    }
    $matches = @($installedEntries | Where-Object {
        $_ -and $_.PSObject.Properties['pluginId'] -and
        $_.PSObject.Properties['pluginId'].Value -is [string] -and
        [string]$_.PSObject.Properties['pluginId'].Value -ceq [string]$ExpectedPlugin.pluginId
    })
    if ($matches.Count -ne 1) {
        return New-CycInactivePluginVerification -ExitCode $exitCode -Reason 'plugin-id-missing-or-duplicate'
    }
    $entry = $matches[0]
    foreach ($booleanName in @('installed', 'enabled')) {
        $property = $entry.PSObject.Properties[$booleanName]
        if (-not $property -or -not ($property.Value -is [bool]) -or -not [bool]$property.Value) {
            return New-CycInactivePluginVerification -ExitCode $exitCode -Reason ("plugin-$booleanName-not-true")
        }
    }
    foreach ($stringCheck in @(
        [PSCustomObject]@{ name = 'name'; expected = [string]$ExpectedPlugin.pluginName },
        [PSCustomObject]@{ name = 'marketplaceName'; expected = [string]$ExpectedPlugin.marketplaceName },
        [PSCustomObject]@{ name = 'version'; expected = [string]$ExpectedPlugin.version }
    )) {
        $property = $entry.PSObject.Properties[$stringCheck.name]
        if (-not $property -or -not ($property.Value -is [string]) -or
            [string]$property.Value -cne $stringCheck.expected) {
            return New-CycInactivePluginVerification `
                -ExitCode $exitCode `
                -Reason ("plugin-$($stringCheck.name)-mismatch")
        }
    }
    $sourceProperty = $entry.PSObject.Properties['source']
    if (-not $sourceProperty -or -not $sourceProperty.Value) {
        return New-CycInactivePluginVerification -ExitCode $exitCode -Reason 'plugin-source-missing'
    }
    $source = $sourceProperty.Value
    $sourceTypeProperty = $source.PSObject.Properties['source']
    $sourcePathProperty = $source.PSObject.Properties['path']
    if (-not $sourceTypeProperty -or -not ($sourceTypeProperty.Value -is [string]) -or
        [string]$sourceTypeProperty.Value -cne [string]$ExpectedPlugin.sourceType -or
        -not $sourcePathProperty -or -not ($sourcePathProperty.Value -is [string])) {
        return New-CycInactivePluginVerification -ExitCode $exitCode -Reason 'plugin-source-metadata-mismatch'
    }
    try {
        $actualSourcePath = Resolve-CycComparablePath ([string]$sourcePathProperty.Value)
        $expectedSourcePath = Resolve-CycComparablePath ([string]$ExpectedPlugin.sourcePath)
    } catch {
        return New-CycInactivePluginVerification -ExitCode $exitCode -Reason 'plugin-source-path-invalid'
    }
    if (-not [string]::Equals(
        $actualSourcePath,
        $expectedSourcePath,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        return New-CycInactivePluginVerification -ExitCode $exitCode -Reason 'plugin-source-path-mismatch'
    }
    return [PSCustomObject]@{
        active = $true
        exitCode = $exitCode
        reason = 'verified'
        pluginVersion = [string]$entry.version
        sourceType = [string]$source.source
        sourcePath = $actualSourcePath
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
            pluginVerified = $false
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
            pluginVerified = $false
            pluginRemoved = $true
            marketplaceRemoved = $true
            pluginExitCode = $null
            marketplaceExitCode = $null
        }
    }
    if ($Operation -eq 'Uninstall' -and -not $CleanupCheckpoint) {
        throw 'Codex integration cleanup requires a durable manifest checkpoint callback.'
    }
    $codex = Resolve-CodexCli
    if (-not $codex) {
        return [PSCustomObject]@{
            operation = $Operation
            required = $true
            attempted = $false
            cliFound = $false
            succeeded = $false
            marketplaceAdded = $false
            pluginAdded = $false
            pluginVerified = $false
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
                pluginVerified = $false
                pluginRemoved = $false
                marketplaceRemoved = $false
                pluginExitCode = $null
                marketplaceExitCode = $null
            }
        }
        $expectedPlugin = Get-CycCodexPluginExpectation `
            -MarketplaceRoot $Plan.codexIntegration.marketplaceRoot `
            -PluginId $Plan.codexIntegration.plugin
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
        $verification = if ($marketplaceAdded -and $pluginAdded) {
            Test-CycCodexPluginActive -Codex $codex -ExpectedPlugin $expectedPlugin
        } else {
            [PSCustomObject]@{
                active = $false
                exitCode = $null
                reason = 'registration-failed'
                pluginVersion = $null
                sourceType = $null
                sourcePath = $null
            }
        }
        return [PSCustomObject]@{
            operation = $Operation
            required = $true
            attempted = $true
            cliFound = $true
            succeeded = ($marketplaceAdded -and $pluginAdded -and $verification.active)
            marketplaceAdded = $marketplaceAdded
            pluginAdded = $pluginAdded
            pluginVerified = [bool]$verification.active
            pluginVerificationExitCode = $verification.exitCode
            pluginVerificationReason = $verification.reason
            pluginVersion = $verification.pluginVersion
            pluginSourceType = $verification.sourceType
            pluginSourcePath = $verification.sourcePath
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
                pluginVerified = $false
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
                pluginVerified = $false
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
        pluginVerified = $false
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
    Assert-CycCreationPathNoReparse -Path $directory
    [void](New-Item -ItemType Directory -Path $directory -Force)
    $leaf = Split-Path -Leaf $Path
    $temporary = Join-Path $directory ($leaf + '.tmp-' + [Guid]::NewGuid().ToString('N'))
    $backup = Join-Path $directory ($leaf + '.bak-' + [Guid]::NewGuid().ToString('N'))
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $bytes = $utf8.GetBytes(($Value | ConvertTo-Json -Depth $Depth))
    $stream = $null
    $backupStream = $null
    $backupCreated = $false
    $backupPrepared = $false
    $committed = $false
    $operationError = $null
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
            # Windows PowerShell/.NET Framework requires the backup operand of
            # File.Replace to already be a same-volume regular file.  Passing
            # a merely planned path fails after the temporary JSON was
            # durably written, so create and flush the unique sibling first.
            $backupStream = [System.IO.FileStream]::new(
                $backup,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None,
                1,
                [System.IO.FileOptions]::WriteThrough
            )
            $backupCreated = $true
            $backupStream.Flush($true)
            $backupPrepared = $true
            $backupStream.Dispose()
            $backupStream = $null
            [System.IO.File]::Replace($temporary, $Path, $backup, $true)
        } else {
            [System.IO.File]::Move($temporary, $Path)
        }

        # The flushed same-directory replace/move above is the commit point.
        # Do not reopen the destination afterwards: an AV/share race after a
        # successful commit must never make callers compensate durable state.
        $committed = $true
    } catch {
        # Preserve the writer's primary failure even if best-effort cleanup
        # below encounters a second, unrelated failure.
        $operationError = $_
        throw
    } finally {
        $cleanupError = $null
        if ($stream) {
            try { $stream.Dispose() } catch {
                $cleanupError = $_
            }
        }
        if ($backupStream) {
            try { $backupStream.Dispose() } catch {
                if ($null -eq $cleanupError) { $cleanupError = $_ }
            }
        }
        try {
            if (Test-Path -LiteralPath $temporary) {
                Remove-Item -LiteralPath $temporary -Force
            }
        } catch {
            if ($null -eq $cleanupError) { $cleanupError = $_ }
        }
        try {
            if (($committed -or $backupCreated -or $backupPrepared) -and
                (Test-Path -LiteralPath $backup)) {
                Remove-Item -LiteralPath $backup -Force
            }
        } catch {
            if ($null -eq $cleanupError) { $cleanupError = $_ }
        }
        if ($null -ne $cleanupError -and $null -eq $operationError) {
            throw $cleanupError
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
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Repair')][string]$Action,
        [Parameter(Mandatory = $true)]$CodexResult,
        [Parameter(Mandatory = $true)]$AgentsResult,
        $TlsIdentityResult
    )
    $manifestDirectory = Split-Path -Parent $Plan.manifestPath
    Assert-CycCreationPathNoReparse -Path $manifestDirectory
    [void](New-Item -ItemType Directory -Path $manifestDirectory -Force)
    $record = [ordered]@{
        schemaVersion = $script:ManifestSchema
        productVersion = $script:ProductVersion
        installedAtUtc = [DateTime]::UtcNow.ToString('o')
        installRoot = $Plan.installRoot
        dataRoot = $Plan.dataRoot
        initiator = [ordered]@{
            sid = [string]$Plan.initiator.sid
            profile = [string]$Plan.initiator.profile
            localAppData = [string]$Plan.initiator.localAppData
        }
        coreCommit = [ordered]@{
            schemaVersion = $script:CoreCommitSchema
            action = $Action
            state = 'pending'
            transactionId = if ($Plan.managedWorker.firewall.enabled) {
                $Plan.managedWorker.firewall.transactionId
            } else { $null }
            requestSha256 = if ($Plan.managedWorker.firewall.enabled) {
                $Plan.managedWorker.firewall.requestSha256
            } else { $null }
            committedAtUtc = $null
        }
        buildCatalogSha256 = $Plan.buildCatalogSha256
        codexPayloadCatalogSha256 = $Plan.codexPayloadCatalogSha256
        files = @($Plan.files | ForEach-Object {
            [ordered]@{ relativePath = $_.relativePath; sha256 = $_.sha256; length = $_.length }
        })
        taskLogonType = $script:ScheduledTaskLogonType
        taskRuntime = [ordered]@{
            mode = $script:ProfileMatrixTaskRuntime
            gate = $script:ProfileMatrixTaskGate
            evidencePath = $script:ProfileMatrixTaskGateEvidencePath
        }
        tasks = @($Plan.tasks | Where-Object enabled | ForEach-Object { $_.name })
        managedWorker = [ordered]@{
            enabled = $Plan.managedWorker.enabled
            networkPlan = if ($Plan.managedWorker.enabled) {
                [ordered]@{
                    schemaVersion = [string]$Plan.managedWorker.networkPlan.schemaVersion
                    identityVersion = [string]$Plan.managedWorker.networkPlan.identityVersion
                    selectedInterfaceIndex = [int]$Plan.managedWorker.networkPlan.selectedInterfaceIndex
                    controllerHostName = [string]$Plan.managedWorker.networkPlan.controllerHostName
                    bindHost = [string]$Plan.managedWorker.networkPlan.bindHost
                    publicHost = [string]$Plan.managedWorker.networkPlan.publicHost
                    listenPort = [int]$Plan.managedWorker.networkPlan.listenPort
                    privateAddresses = [object[]]@($Plan.managedWorker.networkPlan.privateAddresses)
                    identityHosts = [object[]]@($Plan.managedWorker.networkPlan.identityHosts)
                }
            } else { $null }
            identityVersion = $Plan.managedWorker.identityVersion
            identityHosts = [object[]]@($Plan.managedWorker.identityHosts)
            bindHost = $Plan.managedWorker.bindHost
            publicHost = $Plan.managedWorker.publicHost
            publicUrl = $Plan.managedWorker.publicUrl
            listenPort = $Plan.managedWorker.listenPort
            tlsDirectory = $Plan.managedWorker.tlsDirectory
            certificatePath = $Plan.managedWorker.certificatePath
            privateKeyPath = $Plan.managedWorker.privateKeyPath
            certificateFingerprint = if ($TlsIdentityResult) { $TlsIdentityResult.fingerprint } else { $null }
            legacyIdentityPreserved = if ($TlsIdentityResult) {
                [bool](Get-CycObjectProperty `
                    -Object $TlsIdentityResult `
                    -Name 'legacyIdentityPreserved' `
                    -Default $false)
            } else { $false }
            migratedFromLegacy = if ($TlsIdentityResult) {
                [bool](Get-CycObjectProperty `
                    -Object $TlsIdentityResult `
                    -Name 'migratedFromLegacy' `
                    -Default $false)
            } else { $false }
            firewall = [ordered]@{
                enabled = $Plan.managedWorker.firewall.enabled
                name = $Plan.managedWorker.firewall.name
                group = $Plan.managedWorker.firewall.group
                description = $Plan.managedWorker.firewall.description
                lifecycle = $Plan.managedWorker.firewall.lifecycle
                state = $Plan.managedWorker.firewall.state
                transactionId = $Plan.managedWorker.firewall.transactionId
                requestSha256 = $Plan.managedWorker.firewall.requestSha256
                program = $Plan.managedWorker.firewall.program
                port = $Plan.managedWorker.firewall.port
                profile = $Plan.managedWorker.firewall.profile
                remoteAddress = $Plan.managedWorker.firewall.remoteAddress
                protocol = $Plan.managedWorker.firewall.protocol
                receiptSha256 = $null
                appliedAtUtc = $null
            }
        }
        uninstallRegistration = [ordered]@{
            enabled = $Plan.uninstallRegistration.enabled
            registryPath = $Plan.uninstallRegistration.registryPath
            uninstallerPath = $Plan.uninstallRegistration.uninstallerPath
        }
        codexIntegration = [ordered]@{
            enabled = $Plan.codexIntegration.enabled
            available = $Plan.codexIntegration.available
            marketplaceRoot = $Plan.codexIntegration.marketplaceRoot
            plugin = $Plan.codexIntegration.plugin
            payloadCatalogSha256 = $Plan.codexPayloadCatalogSha256
            buildCatalogSha256 = $Plan.buildCatalogSha256
            attempted = $CodexResult.attempted
            cliFound = $CodexResult.cliFound
            succeeded = $CodexResult.succeeded
            marketplaceAdded = $CodexResult.marketplaceAdded
            pluginAdded = $CodexResult.pluginAdded
            pluginVerified = [bool](Get-CycObjectProperty -Object $CodexResult -Name 'pluginVerified' -Default $false)
            pluginVerificationExitCode = Get-CycObjectProperty -Object $CodexResult -Name 'pluginVerificationExitCode'
            pluginVerificationReason = Get-CycObjectProperty -Object $CodexResult -Name 'pluginVerificationReason'
            pluginVersion = Get-CycObjectProperty -Object $CodexResult -Name 'pluginVersion'
            pluginSourceType = Get-CycObjectProperty -Object $CodexResult -Name 'pluginSourceType'
            pluginSourcePath = Get-CycObjectProperty -Object $CodexResult -Name 'pluginSourcePath'
            pluginExitCode = $CodexResult.pluginExitCode
            marketplaceExitCode = $CodexResult.marketplaceExitCode
        }
        agentsIntegration = $AgentsResult
    }
    Write-DurableAtomicJson -Path $Plan.manifestPath -Value $record -Depth 12
}

function Complete-CycInstallCoreCommit {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Repair')][string]$Action
    )
    $manifest = Read-InstallManifest -ManifestPath $Plan.manifestPath
    if (-not $manifest -or -not $manifest.PSObject.Properties['coreCommit']) {
        throw 'Install core commit marker is missing.'
    }
    $marker = $manifest.coreCommit
    [string[]]$actual = @($marker.PSObject.Properties.Name)
    [string[]]$expected = @(
        'action', 'committedAtUtc', 'requestSha256', 'schemaVersion', 'state', 'transactionId'
    )
    [Array]::Sort($actual, [System.StringComparer]::Ordinal)
    [Array]::Sort($expected, [System.StringComparer]::Ordinal)
    if ([string]::Join(',', $actual) -cne [string]::Join(',', $expected) -or
        [string]$marker.schemaVersion -cne $script:CoreCommitSchema -or
        [string]$marker.action -cne $Action -or
        [string]$marker.state -cnotin @('pending', 'committed')) {
        throw 'Install core commit marker is invalid.'
    }
    if ($Plan.managedWorker.firewall.enabled) {
        if ([string]$marker.transactionId -cne [string]$Plan.managedWorker.firewall.transactionId -or
            [string]$marker.requestSha256 -cne [string]$Plan.managedWorker.firewall.requestSha256) {
            throw 'Install core commit marker is not bound to the deferred firewall transaction.'
        }
    } elseif ($null -ne $marker.transactionId -or $null -ne $marker.requestSha256) {
        throw 'Install core commit marker unexpectedly contains a firewall binding.'
    }
    if ([string]$marker.state -ceq 'committed') {
        $committedAt = [DateTimeOffset]::MinValue
        if ([string]$marker.committedAtUtc -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}(?:Z|[+-]\d{2}:\d{2})$' -or
            -not [DateTimeOffset]::TryParse(
                [string]$marker.committedAtUtc,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind,
                [ref]$committedAt
            )) {
            throw 'Committed install core marker has an invalid commit timestamp.'
        }
        return $manifest
    }
    if ($null -ne $marker.committedAtUtc) {
        throw 'Pending install core commit marker already has a commit timestamp.'
    }
    $marker.state = 'committed'
    $marker.committedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    Write-DurableAtomicJson -Path $Plan.manifestPath -Value $manifest -Depth 20
    # The durable atomic replace above is the core commit point. Do not reopen
    # the manifest here: a transient post-commit read failure must never make
    # the caller compensate an already committed install. The lifecycle
    # coordinator independently reads and validates this exact after-image
    # before it commits the deferred firewall transaction.
    return $manifest
}

function Set-CycObjectPropertyValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )
    if ($Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Assert-CycRealDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $resolved = Resolve-NormalizedPath $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        throw "$Label directory is missing: $resolved"
    }
    if (Test-ReparsePoint (Get-Item -LiteralPath $resolved -Force)) {
        throw "$Label directory must not be a reparse point."
    }
    return $resolved
}

function Assert-CycInstalledManifestFile {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )
    $fileProperty = $Manifest.PSObject.Properties['files']
    if (-not $fileProperty) {
        throw 'Install manifest has no owned-file receipt.'
    }
    $matches = @(@($fileProperty.Value) | Where-Object {
        $_ -and $_.PSObject.Properties['relativePath'] -and
        $_.PSObject.Properties['relativePath'].Value -is [string] -and
        [string]::Equals(
            [string]$_.PSObject.Properties['relativePath'].Value,
            $RelativePath,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    })
    if ($matches.Count -ne 1) {
        throw "Install manifest must own exactly one $RelativePath."
    }
    $entry = $matches[0]
    $hash = [string](Get-CycObjectProperty -Object $entry -Name 'sha256')
    $length = Get-CycObjectProperty -Object $entry -Name 'length' -Default -1
    if ($hash -cnotmatch '^[0-9a-f]{64}$' -or [long]$length -lt 0) {
        throw "Install manifest has invalid integrity metadata for $RelativePath."
    }
    $nativeRelative = $RelativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $target = Assert-ChildPath -Root $InstallRoot -Candidate (Join-Path $InstallRoot $nativeRelative)
    $rootPath = Resolve-NormalizedPath $InstallRoot
    $relativeTarget = $target.Substring((Get-CycChildPrefix $rootPath).Length)
    $segments = @($relativeTarget.Split(@(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ), [System.StringSplitOptions]::RemoveEmptyEntries))
    $ancestor = $rootPath
    for ($index = 0; $index -lt ($segments.Count - 1); $index++) {
        $ancestor = Join-Path $ancestor $segments[$index]
        if (-not (Test-Path -LiteralPath $ancestor -PathType Container) -or
            (Test-ReparsePoint (Get-Item -LiteralPath $ancestor -Force))) {
            throw "Installed owned file has a missing or reparse-point parent: $RelativePath"
        }
    }
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
        throw "Installed owned file is missing: $RelativePath"
    }
    $item = Get-Item -LiteralPath $target -Force
    if ((Test-ReparsePoint $item) -or $item.Length -ne [long]$length) {
        throw "Installed owned file metadata changed: $RelativePath"
    }
    $actualHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -cne $hash) {
        throw "Installed owned file failed SHA-256 validation: $RelativePath"
    }
    return $target
}

function Get-CycCodexOnlyInstallState {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [string]$CodexHome,
        [string]$ExpectedInstallManifestSha256
    )
    $install = Assert-CycRealDirectory -Path $InstallRoot -Label 'InstallRoot'
    $data = Assert-CycRealDirectory -Path $DataRoot -Label 'DataRoot'
    $installerRoot = Assert-CycRealDirectory -Path (Join-Path $data '.installer') -Label 'Installer state'
    $manifestPath = Assert-ChildPath -Root $installerRoot -Candidate (Join-Path $installerRoot 'install-manifest.json')
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw 'IntegrateCodex requires an existing ClusterYourCodex install manifest.'
    }
    $manifestItem = Get-Item -LiteralPath $manifestPath -Force
    if ((Test-ReparsePoint $manifestItem) -or
        $manifestItem.Length -lt 2 -or
        $manifestItem.Length -gt $script:MaxInstallManifestBytes) {
        throw 'ClusterYourCodex install manifest must be a bounded regular file.'
    }
    [byte[]]$manifestBytes = [System.IO.File]::ReadAllBytes($manifestPath)
    $manifestSha256 = Get-CycSha256Hex -Bytes $manifestBytes
    if (-not [string]::IsNullOrWhiteSpace($ExpectedInstallManifestSha256) -and
        ([string]$ExpectedInstallManifestSha256 -cnotmatch '^[0-9a-f]{64}$' -or
            [string]$ExpectedInstallManifestSha256 -cne $manifestSha256)) {
        throw 'IntegrateCodex install-manifest digest does not match the native verifier receipt.'
    }
    $manifest = Read-InstallManifest -ManifestPath $manifestPath
    foreach ($rootName in @('installRoot', 'dataRoot')) {
        $property = $manifest.PSObject.Properties[$rootName]
        if (-not $property -or -not ($property.Value -is [string]) -or
            [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            throw "Install manifest is missing a valid $rootName."
        }
    }
    if (-not [string]::Equals(
        (Resolve-NormalizedPath ([string]$manifest.installRoot)),
        $install,
        [System.StringComparison]::OrdinalIgnoreCase
    ) -or -not [string]::Equals(
        (Resolve-NormalizedPath ([string]$manifest.dataRoot)),
        $data,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'IntegrateCodex install/data roots do not match the install manifest.'
    }
    if (-not $manifest.PSObject.Properties['codexIntegration']) {
        throw 'Install manifest has no Codex plugin integration receipt.'
    }
    $codexRecord = $manifest.codexIntegration
    if ([string](Get-CycObjectProperty -Object $codexRecord -Name 'plugin') -cne $script:CodexPluginId) {
        throw 'Install manifest contains an unexpected Codex plugin identity.'
    }
    $marketplaceProperty = $codexRecord.PSObject.Properties['marketplaceRoot']
    if (-not $marketplaceProperty -or -not ($marketplaceProperty.Value -is [string]) -or
        [string]::IsNullOrWhiteSpace([string]$marketplaceProperty.Value)) {
        throw 'Install manifest has no valid Codex marketplace root.'
    }
    $expectedMarketplace = Assert-CycRealDirectory `
        -Path (Assert-ChildPath `
            -Root $install `
            -Candidate (Join-Path $install 'integrations\codex-marketplace')) `
        -Label 'Codex marketplace'
    if (-not [string]::Equals(
        (Resolve-NormalizedPath ([string](Get-CycObjectProperty -Object $codexRecord -Name 'marketplaceRoot'))),
        $expectedMarketplace,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Install manifest Codex marketplace root does not match this installation.'
    }
    $catalog = Assert-CycCodexPayloadCatalog -Manifest $manifest -InstallRoot $install
    foreach ($catalogBinding in @(
        [PSCustomObject]@{ name = 'payloadCatalogSha256'; value = $catalog.payloadCatalogSha256 },
        [PSCustomObject]@{ name = 'buildCatalogSha256'; value = $catalog.buildCatalogSha256 }
    )) {
        $recorded = Get-CycObjectProperty -Object $codexRecord -Name $catalogBinding.name
        if ($null -ne $recorded -and [string]$recorded -cne [string]$catalogBinding.value) {
            throw "Install manifest Codex integration $($catalogBinding.name) drifted."
        }
    }

    $templatePath = Assert-CycInstalledManifestFile `
        -Manifest $manifest `
        -InstallRoot $install `
        -RelativePath $script:AgentsTemplateRelativePath
    [void](Read-CycAgentsTemplate -Path $templatePath)
    [void](Assert-CycInstalledManifestFile `
        -Manifest $manifest `
        -InstallRoot $install `
        -RelativePath $script:CodexMarketplaceManifestRelativePath)
    $pluginManifestPath = Assert-CycInstalledManifestFile `
        -Manifest $manifest `
        -InstallRoot $install `
        -RelativePath $script:CodexPluginManifestRelativePath
    $expectedPlugin = Get-CycCodexPluginExpectation `
        -MarketplaceRoot $expectedMarketplace `
        -PluginId $script:CodexPluginId
    if (-not [string]::Equals(
        (Resolve-NormalizedPath $pluginManifestPath),
        (Resolve-NormalizedPath $expectedPlugin.pluginManifestPath),
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Installed plugin manifest path is inconsistent.'
    }

    $requestedHome = $CodexHome
    if ([string]::IsNullOrWhiteSpace($requestedHome) -and
        $manifest.PSObject.Properties['agentsIntegration']) {
        $recordedHome = Get-CycObjectProperty -Object $manifest.agentsIntegration -Name 'codexHome'
        if ($recordedHome -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$recordedHome)) {
            $requestedHome = [string]$recordedHome
        }
    }
    $resolvedHome = Resolve-CycCodexHome -RequestedHome $requestedHome
    return [PSCustomObject]@{
        installRoot = $install
        dataRoot = $data
        manifestPath = $manifestPath
        manifestSha256 = $manifestSha256
        buildCatalogSha256 = $catalog.buildCatalogSha256
        payloadCatalogSha256 = $catalog.payloadCatalogSha256
        manifest = $manifest
        expectedPlugin = $expectedPlugin
        plan = [PSCustomObject]@{
            codexIntegration = [PSCustomObject]@{
                enabled = $true
                available = $true
                marketplaceRoot = $expectedMarketplace
                marketplaceManifest = Join-Path $expectedMarketplace '.agents\plugins\marketplace.json'
                plugin = $script:CodexPluginId
            }
            agentsIntegration = [PSCustomObject]@{
                schemaVersion = $script:AgentsIntegrationSchema
                enabled = $true
                available = $true
                codexHome = $resolvedHome
                agentsPath = Join-Path $resolvedHome 'AGENTS.md'
                templatePath = $templatePath
                templateRelativePath = $script:AgentsTemplateRelativePath
            }
        }
    }
}

function New-CycCodexOnlyTransactionRoot {
    param([Parameter(Mandatory = $true)][string]$DataRoot)
    $installerRoot = Assert-CycRealDirectory -Path (Join-Path $DataRoot '.installer') -Label 'Installer state'
    $transactionsRoot = Join-Path $installerRoot 'transactions'
    if (Test-Path -LiteralPath $transactionsRoot) {
        [void](Assert-CycRealDirectory -Path $transactionsRoot -Label 'Installer transactions')
        # An existing transaction tree has already crossed the verify-only
        # recovery boundary. Re-check it before creating a new child so a
        # foreign or weakened journal can never be hidden by this entrypoint.
        Assert-CycPrivateStateTree -Root $transactionsRoot
    } else {
        Assert-CycCreationPathNoReparse -Path $transactionsRoot
        [void](New-Item -ItemType Directory -Path $transactionsRoot)
        [void](Assert-CycRealDirectory -Path $transactionsRoot -Label 'Installer transactions')
        # New-Item creates an inherited ACL even when the parent is private on
        # some Windows profiles. Publish the exact private state-root ACL
        # before any transaction child is created or later recovery can read.
        Set-PrivateDirectoryAcl -Path $transactionsRoot
    }
    $transactionRoot = Assert-ChildPath `
        -Root $transactionsRoot `
        -Candidate (Join-Path $transactionsRoot ('codex-only-' + [Guid]::NewGuid().ToString('N')))
    Assert-CycCreationPathNoReparse -Path $transactionRoot
    [void](New-Item -ItemType Directory -Path $transactionRoot)
    [void](Assert-CycRealDirectory -Path $transactionRoot -Label 'Codex-only transaction')
    # Protect the newly-created child explicitly; relying on parent ACL
    # inheritance is not portable across Windows account/profile policies.
    Set-PrivateDirectoryAcl -Path $transactionRoot
    return $transactionRoot
}

function Remove-CycCodexOnlyTransactionRoot {
    param(
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$TransactionRoot
    )
    $transactionsRoot = Resolve-NormalizedPath (Join-Path $DataRoot '.installer\transactions')
    $target = Assert-ChildPath -Root $transactionsRoot -Candidate $TransactionRoot
    if ((Split-Path -Leaf $target) -cnotmatch '^codex-only-[0-9a-f]{32}$') {
        throw 'Refusing to clean a transaction not owned by IntegrateCodex.'
    }
    if (Test-Path -LiteralPath $target -PathType Container) {
        $item = Get-Item -LiteralPath $target -Force
        if (Test-ReparsePoint $item) {
            throw 'Refusing to clean a reparse-point transaction directory.'
        }
        # The exact absolute target and owned name were proven before this
        # only recursive cleanup in the Codex-only lifecycle.
        Remove-Item -LiteralPath $target -Recurse -Force
    }
}

function New-CycCodexOnlyReceipt {
    param(
        [ValidateSet('installed', 'repaired', 'unchanged')][string]$Status,
        [Parameter(Mandatory = $true)]$PluginVerification,
        [Parameter(Mandatory = $true)]$AgentsRecord,
        [Parameter(Mandatory = $true)]$InstallState,
        [Parameter(Mandatory = $true)]$AgentsEvidence
    )
    $version = [string](Get-CycObjectProperty -Object $PluginVerification -Name 'pluginVersion')
    $blockHash = [string](Get-CycObjectProperty -Object $AgentsRecord -Name 'blockSha256')
    if ($version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$' -or
        $blockHash -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$InstallState.payloadCatalogSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$InstallState.buildCatalogSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$InstallState.manifestSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$AgentsEvidence.agentsFileSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$AgentsEvidence.agentsExternalSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$AgentsEvidence.agentsOwnedRangeSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Cannot publish an invalid Codex-only integration receipt.'
    }
    return [PSCustomObject][ordered]@{
        schemaVersion = $script:CodexOnlyReceiptSchema
        status = $Status
        pluginId = $script:CodexPluginId
        pluginVersion = $version
        agentsBlockSha256 = $blockHash
        payloadCatalogSha256 = [string]$InstallState.payloadCatalogSha256
        buildCatalogSha256 = [string]$InstallState.buildCatalogSha256
        installManifestSha256 = [string]$InstallState.manifestSha256
        agentsFileSha256 = [string]$AgentsEvidence.agentsFileSha256
        agentsExternalSha256 = [string]$AgentsEvidence.agentsExternalSha256
        agentsOwnedRangeSha256 = [string]$AgentsEvidence.agentsOwnedRangeSha256
    }
}

function Set-CycCodexOnlyManifestReceipt {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$PluginVerification,
        [Parameter(Mandatory = $true)]$AgentsRecord,
        [Parameter(Mandatory = $true)]$Receipt
    )
    if (-not $Manifest.PSObject.Properties['codexIntegration']) {
        throw 'Install manifest has no Codex integration object to update.'
    }
    $codexRecord = $Manifest.codexIntegration
    Set-CycObjectPropertyValue -Object $codexRecord -Name 'succeeded' -Value $true
    Set-CycObjectPropertyValue -Object $codexRecord -Name 'pluginVerified' -Value $true
    Set-CycObjectPropertyValue -Object $codexRecord -Name 'pluginVerificationExitCode' -Value ([int]$PluginVerification.exitCode)
    Set-CycObjectPropertyValue -Object $codexRecord -Name 'pluginVerificationReason' -Value 'verified'
    Set-CycObjectPropertyValue -Object $codexRecord -Name 'pluginVersion' -Value ([string]$PluginVerification.pluginVersion)
    Set-CycObjectPropertyValue -Object $codexRecord -Name 'pluginSourceType' -Value ([string]$PluginVerification.sourceType)
    Set-CycObjectPropertyValue -Object $codexRecord -Name 'pluginSourcePath' -Value ([string]$PluginVerification.sourcePath)
    Set-CycObjectPropertyValue -Object $codexRecord -Name 'verifiedAtUtc' -Value ([DateTime]::UtcNow.ToString('o'))
    $manifestReceipt = [PSCustomObject][ordered]@{
        schemaVersion = $Receipt.schemaVersion
        status = $Receipt.status
        pluginId = $Receipt.pluginId
        pluginVersion = $Receipt.pluginVersion
        agentsBlockSha256 = $Receipt.agentsBlockSha256
        payloadCatalogSha256 = $Receipt.payloadCatalogSha256
        buildCatalogSha256 = $Receipt.buildCatalogSha256
        installManifestSha256 = $Receipt.installManifestSha256
        agentsFileSha256 = $Receipt.agentsFileSha256
        agentsExternalSha256 = $Receipt.agentsExternalSha256
        agentsOwnedRangeSha256 = $Receipt.agentsOwnedRangeSha256
        recordedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    Set-CycObjectPropertyValue -Object $codexRecord -Name 'integrateCodexReceipt' -Value $manifestReceipt
    Set-CycObjectPropertyValue -Object $Manifest -Name 'agentsIntegration' -Value $AgentsRecord
}

function ConvertTo-CycCodexOnlyReceiptJson {
    param([Parameter(Mandatory = $true)]$Receipt)
    $json = $Receipt | ConvertTo-Json -Compress -Depth 6
    if ([string]::IsNullOrWhiteSpace($json) -or $json.Contains("`r") -or $json.Contains("`n") -or
        [System.Text.Encoding]::UTF8.GetByteCount($json) -gt $script:MaxCodexOnlyReceiptBytes) {
        throw 'Codex-only integration receipt is not a single bounded JSON object.'
    }
    return $json
}

function Invoke-CycCodexOnlyIntegration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [string]$CodexHome,
        [Parameter(Mandatory = $true)][string]$CodexCliPath,
        [string]$ExpectedInstallManifestSha256,
        [ValidateRange(1, 30)][int]$MutexTimeoutSeconds = 10,
        [ValidateRange(10, 90)][int]$ActionTimeoutSeconds = 60
    )
    $data = Resolve-NormalizedPath $DataRoot
    $manifestPath = Join-Path $data '.installer\install-manifest.json'
    $deadline = [DateTime]::UtcNow.AddSeconds($ActionTimeoutSeconds)
    $mutexBudget = [Math]::Max(1, [Math]::Min(
        $MutexTimeoutSeconds,
        [int][Math]::Floor(($deadline - [DateTime]::UtcNow).TotalSeconds)
    ))
    $mutex = Enter-CycAgentsMutex -TimeoutSeconds $mutexBudget
    $transactionRoot = $null
    $transaction = $null
    $receipt = $null
    $preserveTransaction = $false
    try {
        # Recovery is allowed to read/write only after the existing private
        # install/data roots have been verified without repairing them.
        [void](Assert-CycExistingPrivateDirectory -Path $InstallRoot -AllowAdministratorsReadAndExecute)
        [void](Assert-CycExistingPrivateDirectory -Path $data)
        # Validate the product-owned manifest container before any recovery
        # logic is allowed to trust a journal or manifest path.
        $state = Get-CycCodexOnlyInstallState `
            -InstallRoot $InstallRoot `
            -DataRoot $data `
            -CodexHome $CodexHome `
            -ExpectedInstallManifestSha256 $ExpectedInstallManifestSha256
        [void](Recover-CycAgentsTransactions -DataRoot $data -ManifestPath $manifestPath)
        # Recovery can finalize a manifest receipt, so read the authoritative
        # state again before plugin verification and mutation planning.
        $state = Get-CycCodexOnlyInstallState `
            -InstallRoot $InstallRoot `
            -DataRoot $data `
            -CodexHome $CodexHome
        $remainingMs = [int][Math]::Floor(($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if ($remainingMs -lt 1000) { throw 'IntegrateCodex action deadline expired before Codex verification.' }
        $codex = Resolve-CodexCli `
            -RequestedPath $CodexCliPath `
            -TimeoutMilliseconds ([Math]::Min(10000, $remainingMs))
        if (-not $codex) {
            throw 'Codex CLI is unavailable; the global AGENTS.md block was not changed.'
        }
        $verification = Test-CycCodexPluginActive `
            -Codex $codex `
            -ExpectedPlugin $state.expectedPlugin `
            -TimeoutMilliseconds ([Math]::Min(20000, [Math]::Max(100, [int][Math]::Floor(($deadline - [DateTime]::UtcNow).TotalMilliseconds))))
        if (-not $verification.active) {
            throw "Codex plugin activation receipt failed strict verification ($($verification.reason)); the global AGENTS.md block was not changed."
        }
        if (($deadline - [DateTime]::UtcNow).TotalSeconds -lt 10) {
            throw 'IntegrateCodex action deadline leaves insufficient time to begin a durable AGENTS.md transaction.'
        }

        $oldInstalled = [bool]($state.manifest.PSObject.Properties['agentsIntegration'] -and
            (Get-CycObjectProperty -Object $state.manifest.agentsIntegration -Name 'installed' -Default $false))
        $transactionRoot = New-CycCodexOnlyTransactionRoot -DataRoot $state.dataRoot
        $transaction = Start-CycAgentsInstallTransaction `
            -Plan $state.plan `
            -OldManifest $state.manifest `
            -TransactionRoot $transactionRoot `
            -PluginReceipt ([PSCustomObject]@{
                pluginVerified = $true
                succeeded = $true
                pluginVersion = $verification.pluginVersion
                pluginSourceType = $verification.sourceType
                pluginSourcePath = $verification.sourcePath
            })
        $status = if (-not $oldInstalled) {
            'installed'
        } elseif ([bool]$transaction.record.changed) {
            'repaired'
        } else {
            'unchanged'
        }
        $agentsEvidence = Get-CycStrictAgentsEvidence -Record $transaction.record
        $receipt = New-CycCodexOnlyReceipt `
            -Status $status `
            -PluginVerification $verification `
            -AgentsRecord $transaction.record `
            -InstallState $state `
            -AgentsEvidence $agentsEvidence
        Set-CycCodexOnlyManifestReceipt `
            -Manifest $state.manifest `
            -PluginVerification $verification `
            -AgentsRecord $transaction.record `
            -Receipt $receipt
        Write-DurableAtomicJson -Path $state.manifestPath -Value $state.manifest -Depth 20
        $published = Read-InstallManifest -ManifestPath $state.manifestPath
        if (-not (Test-CycManifestOwnsAgentsReceipt -Manifest $published -Receipt $transaction.record) -or
            -not (Test-CycAgentsRecordPresent -Record $transaction.record)) {
            throw 'Codex-only manifest/AGENTS.md commit verification failed.'
        }
        [void](Get-CycStrictAgentsEvidence -Record $published.agentsIntegration)
        Complete-CycAgentsInstallTransaction -Transaction $transaction
        try { Remove-CycCodexOnlyTransactionRoot -DataRoot $state.dataRoot -TransactionRoot $transactionRoot } catch {
            # A committed journal is safe to retain for later housekeeping.
        }
        return $receipt
    } catch {
        $failure = $_
        if (-not $transaction -and $transactionRoot) {
            $pendingJournal = Join-Path $transactionRoot 'global-agents\journal.json'
            if (Test-Path -LiteralPath $pendingJournal -PathType Leaf) {
                try {
                    $pending = Read-CycAgentsJournal -Path $pendingJournal
                    $transaction = [PSCustomObject]@{
                        disabled = $false
                        journalPath = $pendingJournal
                        record = $pending.receipt
                    }
                } catch {
                    $preserveTransaction = $true
                }
            }
        }
        if ($transaction) {
            try {
                [void](Recover-CycAgentsTransactions -DataRoot $data -ManifestPath $manifestPath)
                $latestManifest = Read-InstallManifest -ManifestPath $manifestPath
                if ((Test-CycManifestOwnsAgentsReceipt -Manifest $latestManifest -Receipt $transaction.record) -and
                    (Test-CycAgentsRecordPresent -Record $transaction.record)) {
                    try { Remove-CycCodexOnlyTransactionRoot -DataRoot $data -TransactionRoot $transactionRoot } catch { }
                    return $receipt
                }
                try { Remove-CycCodexOnlyTransactionRoot -DataRoot $data -TransactionRoot $transactionRoot } catch { }
            } catch {
                $preserveTransaction = $true
                throw "IntegrateCodex failed and its owned-range recovery is incomplete; the transaction was retained. Original failure: $($failure.Exception.Message)"
            }
        }
        throw $failure
    } finally {
        if ($transactionRoot -and -not $transaction -and -not $preserveTransaction) {
            try { Remove-CycCodexOnlyTransactionRoot -DataRoot $data -TransactionRoot $transactionRoot } catch { }
        }
        Exit-CycAgentsMutex -Mutex $mutex
    }
}

function Assert-CycFirewallReceiptProperties {
    param([Parameter(Mandatory = $true)]$Receipt)
    [string[]]$actual = @($Receipt.PSObject.Properties.Name)
    [string[]]$expected = @(
        'action', 'failureCode', 'initiatorLocalAppData', 'initiatorProfile',
        'initiatorSid', 'port', 'program', 'programSha256', 'requestSha256',
        'result', 'ruleName', 'schemaVersion', 'transactionId', 'verifiedAtUtc'
    )
    [Array]::Sort($actual, [System.StringComparer]::Ordinal)
    [Array]::Sort($expected, [System.StringComparer]::Ordinal)
    if ([string]::Join(',', $actual) -cne [string]::Join(',', $expected)) {
        throw 'Firewall receipt contains unsupported or missing fields.'
    }
}

function Invoke-CycCommitFirewallReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$ReceiptPath,
        [Parameter(Mandatory = $true)][string]$TransactionId,
        [Parameter(Mandatory = $true)]$CurrentBinding
    )
    if ($TransactionId -cnotmatch '^[0-9a-f]{32}$') {
        throw 'Firewall commit transaction identifier is invalid.'
    }
    $install = Resolve-NormalizedPath $InstallRoot
    $data = Resolve-NormalizedPath $DataRoot
    $manifestPath = Join-Path $data '.installer\install-manifest.json'
    $manifest = Read-InstallManifest -ManifestPath $manifestPath
    if (-not $manifest) { throw 'Firewall commit requires the installed manifest.' }
    Assert-CycManifestInitiatorBinding -Manifest $manifest -CurrentBinding $CurrentBinding
    if (-not $manifest.PSObject.Properties['managedWorker'] -or
        -not $manifest.managedWorker.PSObject.Properties['firewall']) {
        throw 'Installed manifest has no deferred firewall record.'
    }
    $firewall = $manifest.managedWorker.firewall
    if (-not [bool]$firewall.enabled -or
        [string]$firewall.lifecycle -cne $script:FirewallLifecycleName -or
        [string]$firewall.transactionId -cne $TransactionId -or
        [string]$firewall.requestSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Installed manifest is not awaiting this firewall transaction.'
    }
    $receiptsRoot = Resolve-NormalizedPath (Join-Path $data '.installer\firewall-receipts')
    $receiptFile = Assert-ChildPath -Root $receiptsRoot -Candidate $ReceiptPath
    if (-not (Test-Path -LiteralPath $receiptFile -PathType Leaf)) {
        throw 'Durable firewall receipt is missing.'
    }
    $receiptItem = Get-Item -LiteralPath $receiptFile -Force
    if ((Test-ReparsePoint $receiptItem) -or $receiptItem.Length -lt 2 -or $receiptItem.Length -gt 32768) {
        throw 'Durable firewall receipt must be a bounded regular file.'
    }
    try { $receipt = Read-CycUtf8Json -Path $receiptFile } catch {
        throw 'Durable firewall receipt contains invalid JSON.'
    }
    Assert-CycFirewallReceiptProperties -Receipt $receipt
    $controllerRecord = @($manifest.files | Where-Object { [string]$_.relativePath -ceq 'cyc-controller.exe' })
    if ($controllerRecord.Count -ne 1) { throw 'Installed manifest has no unique controller binary.' }
    if ([string]$receipt.schemaVersion -cne $script:FirewallReceiptSchema -or
        [string]$receipt.result -cne 'verified' -or
        [string]$receipt.action -cne 'Apply' -or
        [string]$receipt.transactionId -cne $TransactionId -or
        [string]$receipt.requestSha256 -cne [string]$firewall.requestSha256 -or
        [string]$receipt.initiatorSid -cne [string]$CurrentBinding.sid -or
        -not [string]::Equals((Resolve-NormalizedPath ([string]$receipt.initiatorProfile)), [string]$CurrentBinding.profile, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals((Resolve-NormalizedPath ([string]$receipt.initiatorLocalAppData)), [string]$CurrentBinding.localAppData, [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]$receipt.ruleName -cne [string]$firewall.name -or
        [int]$receipt.port -ne [int]$firewall.port -or
        -not [string]::Equals((Resolve-NormalizedPath ([string]$receipt.program)), (Resolve-NormalizedPath ([string]$firewall.program)), [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]$receipt.programSha256 -cne [string]$controllerRecord[0].sha256) {
        throw 'Firewall receipt is not bound to the exact installed plan.'
    }
    $receiptHash = (Get-FileHash -LiteralPath $receiptFile -Algorithm SHA256).Hash.ToLowerInvariant()
    if ([string]$firewall.state -ceq 'applied') {
        if ([string]$firewall.receiptSha256 -cne $receiptHash) {
            throw 'A different firewall receipt is already committed.'
        }
        return [PSCustomObject]@{ status = 'unchanged'; transactionId = $TransactionId; receiptSha256 = $receiptHash }
    }
    if ([string]$firewall.state -cne 'pending') {
        throw 'Firewall manifest state is not commit-eligible.'
    }
    $firewall.state = 'applied'
    $firewall.receiptSha256 = $receiptHash
    $firewall.appliedAtUtc = [string]$receipt.verifiedAtUtc
    Write-DurableAtomicJson -Path $manifestPath -Value $manifest -Depth 20
    return [PSCustomObject]@{ status = 'applied'; transactionId = $TransactionId; receiptSha256 = $receiptHash }
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

function Invoke-InstallOrRepairCore {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)]$Plan)
    if ($PlanOnly) { return $Plan }
    if ($Plan.managedWorker.firewall.enabled -and
        (-not $DeferFirewall -or
         [string]$Plan.managedWorker.firewall.lifecycle -cne $script:FirewallLifecycleName -or
         [string]$Plan.managedWorker.firewall.transactionId -cnotmatch '^[0-9a-f]{32}$' -or
         [string]$Plan.managedWorker.firewall.requestSha256 -cnotmatch '^[0-9a-f]{64}$')) {
        throw 'Per-user core install requires a valid deferred firewall-only transaction.'
    }
    if ($Plan.tasks[1].enabled -and -not (Test-Path -LiteralPath $Plan.workerConfig -PathType Leaf)) {
        throw 'Worker task requested but the paired worker config does not exist.'
    }
    if (-not $PSCmdlet.ShouldProcess($Plan.installRoot, "$Action ClusterYourCodex")) { return }

    $oldManifest = Read-InstallManifest -ManifestPath $Plan.manifestPath
    # Snapshot and validate existing product tasks before touching ACLs or any
    # other lifecycle resource.  A same-name task from another SID/root is a
    # hard stop for Install/Repair.
    $taskSnapshots = @(Get-CycTaskSnapshots `
        -ExpectedInstallRoot $Plan.installRoot `
        -ExpectedSid $Plan.initiator.sid)
    # The elevated firewall-only helper may run as a different administrator
    # during over-the-shoulder UAC. It needs read/execute access to hash the
    # request-bound controller, but receives no write/delete/control rights.
    Set-PrivateDirectoryAcl -Path $Plan.installRoot -AllowAdministratorsReadAndExecute
    Set-PrivateDirectoryAcl -Path $Plan.dataRoot
    Stop-CycRuntime `
        -InstallRoot $Plan.installRoot `
        -ExpectedSid $Plan.initiator.sid
    $requiredPorts = @(47831)
    if ($Plan.managedWorker.enabled) { $requiredPorts += [int]$Plan.managedWorker.listenPort }
    Assert-CycListenPortsAvailable -Ports $requiredPorts
    $rollback = $null
    $agentsTransaction = $null
    $agentsResult = $null
    $codexResult = $null
    $tlsIdentityResult = $null
    $uninstallRegistrationSnapshot = $null
    $preserveRollbackSnapshot = $false
    $coreCommitPublished = $false
    try {
        $rollback = New-FileRollbackSnapshot -Plan $Plan -OldManifest $oldManifest
        Install-PlannedFiles -Plan $Plan
        Set-PrivateDirectoryAcl -Path $Plan.installRoot -AllowAdministratorsReadAndExecute
        Set-PrivateDirectoryAcl -Path $Plan.dataRoot

        $tlsIdentityResult = Ensure-CycTlsIdentity -Plan $Plan

        if ($Plan.uninstallRegistration.enabled) {
            $uninstallRegistrationSnapshot = Get-CycUninstallRegistrationSnapshot `
                -RegistryPath $Plan.uninstallRegistration.registryPath
            Set-CycUninstallRegistration -Plan $Plan
        }

        if ($oldManifest) {
            Remove-OwnedFiles `
                -Manifest $oldManifest `
                -ExpectedInstallRoot $Plan.installRoot `
                -KeepRelativePaths @($Plan.files.relativePath)
        }

        Register-CycTask `
            -Name $script:ControllerTaskName `
            -Action $Plan.tasks[0].action `
            -ExpectedInstallRoot $Plan.installRoot `
            -ExpectedSid $Plan.initiator.sid
        if ($Plan.tasks[1].enabled) {
            Register-CycTask `
                -Name $script:WorkerTaskName `
                -Action $Plan.tasks[1].action `
                -ExpectedInstallRoot $Plan.installRoot `
                -ExpectedSid $Plan.initiator.sid
        } else {
            Unregister-CycTask `
                -Name $script:WorkerTaskName `
                -ExpectedInstallRoot $Plan.installRoot `
                -ExpectedSid $Plan.initiator.sid
        }

        $codexResult = Invoke-CodexIntegration -Plan $Plan -Operation Install
        $oldAgentsInstalled = [bool]($oldManifest -and
            $oldManifest.PSObject.Properties['agentsIntegration'] -and
            (Get-CycObjectProperty -Object $oldManifest.agentsIntegration -Name 'installed' -Default $false))
        if ($Plan.agentsIntegration.enabled -and
            [bool](Get-CycObjectProperty -Object $codexResult -Name 'pluginVerified' -Default $false)) {
            $agentsTransaction = Start-CycAgentsInstallTransaction `
                -Plan $Plan `
                -OldManifest $oldManifest `
                -TransactionRoot $rollback.root `
                -PluginReceipt $codexResult
            $agentsResult = $agentsTransaction.record
        } elseif ($oldAgentsInstalled) {
            throw 'Codex plugin activation could not be verified; Repair left the previous managed AGENTS.md block unchanged.'
        } else {
            $reason = if (-not $Plan.agentsIntegration.enabled) {
                'integration-disabled'
            } elseif (-not $codexResult.cliFound) {
                'codex-cli-unavailable'
            } else {
                'plugin-activation-unverified'
            }
            $agentsResult = New-CycDisabledAgentsIntegrationRecord -Plan $Plan -Reason $reason
        }
        Write-InstallManifest `
            -Plan $Plan `
            -Action $Action `
            -CodexResult $codexResult `
            -AgentsResult $agentsResult `
            -TlsIdentityResult $tlsIdentityResult
        if ($script:ProfileMatrixTaskGate -eq 'none') {
            Start-ScheduledTask -TaskName $script:ControllerTaskName -TaskPath '\'
            Wait-CycTaskStable -Name $script:ControllerTaskName -StableSeconds 2
            Wait-CycControllerReady
            Wait-CycManagedWorkerListenerReady -ManagedWorker $Plan.managedWorker
            Wait-CycTaskStable -Name $script:ControllerTaskName -StableSeconds 1
            if ($Plan.tasks[1].enabled) {
                Start-ScheduledTask -TaskName $script:WorkerTaskName -TaskPath '\'
                Wait-CycTaskStable -Name $script:WorkerTaskName -StableSeconds 3
                Test-CycWorkerStatus -Action $Plan.tasks[1].action -Config $Plan.workerConfig
                Wait-CycTaskStable -Name $script:WorkerTaskName -StableSeconds 1
            }
        }
        Complete-CycAgentsInstallTransaction -Transaction $agentsTransaction
        [void](Complete-CycInstallCoreCommit -Plan $Plan -Action $Action)
        $coreCommitPublished = $true
    } catch {
        $failure = $_
        $rollbackFailures = New-Object System.Collections.Generic.List[string]
        try {
            Stop-CycRuntime `
                -InstallRoot $Plan.installRoot `
                -ExpectedSid $Plan.initiator.sid
        } catch {
            # Runtime teardown is part of rollback, not a prerequisite for
            # the remaining compensating actions.  Continue restoring files,
            # tasks, and integrations so a stop/access error cannot strand a
            # partially replaced install without its rollback attempt.
            [void]$rollbackFailures.Add('runtime')
        }
        $oldCodexSucceeded = $false
        if ($oldManifest -and $oldManifest.PSObject.Properties['codexIntegration'] -and
            $oldManifest.codexIntegration.PSObject.Properties['succeeded']) {
            $oldCodexSucceeded = [bool]$oldManifest.codexIntegration.succeeded
        }
        if ($codexResult -and
            ($codexResult.succeeded -or $codexResult.marketplaceAdded -or $codexResult.pluginAdded) -and
            -not $oldCodexSucceeded) {
            try {
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
            } catch { [void]$rollbackFailures.Add('Codex integration') }
        }
        if ($uninstallRegistrationSnapshot) {
            try {
                Restore-CycUninstallRegistrationSnapshot `
                    -RegistryPath $Plan.uninstallRegistration.registryPath `
                    -Snapshot $uninstallRegistrationSnapshot
            } catch { [void]$rollbackFailures.Add('uninstall registration') }
        }
        try { Remove-NewCycTlsIdentity -Plan $Plan -IdentityResult $tlsIdentityResult } catch {
            [void]$rollbackFailures.Add('new TLS identity')
        }
        if (-not $agentsTransaction -and $rollback) {
            $pendingAgentsJournal = Join-Path $rollback.root 'global-agents\journal.json'
            if (Test-Path -LiteralPath $pendingAgentsJournal -PathType Leaf) {
                $agentsTransaction = [PSCustomObject]@{
                    disabled = $false
                    journalPath = $pendingAgentsJournal
                }
            }
        }
        if ($agentsTransaction) {
            try { Rollback-CycAgentsInstallTransaction -Transaction $agentsTransaction } catch {
                [void]$rollbackFailures.Add('global AGENTS.md')
            }
        }
        if ($rollback) {
            try { Restore-FileRollbackSnapshot -Snapshot $rollback } catch {
                [void]$rollbackFailures.Add('installed files')
            }
        }
        try {
            Restore-CycTaskSnapshots `
                -Snapshots $taskSnapshots `
                -ExpectedInstallRoot $Plan.installRoot `
                -ExpectedSid $Plan.initiator.sid
        } catch {
            [void]$rollbackFailures.Add('Scheduled Tasks')
        }
        if ($rollbackFailures.Count -gt 0) {
            $preserveRollbackSnapshot = $true
            throw "Installation failed and rollback was incomplete for: $($rollbackFailures -join ', '). Original failure: $($failure.Exception.Message)"
        }
        throw $failure
    } finally {
        if ($rollback -and -not $preserveRollbackSnapshot) {
            try { Remove-FileRollbackSnapshot -Snapshot $rollback } catch {
                # Once the exact core marker is committed, rollback snapshots
                # are housekeeping only. Never report core failure or ask the
                # coordinator to compensate an already-committed install.
                if (-not $coreCommitPublished) { $preserveRollbackSnapshot = $true }
            }
        }
    }
    [PSCustomObject]@{
        action = $Action
        installRoot = $Plan.installRoot
        dataRoot = $Plan.dataRoot
        controllerTask = $script:ControllerTaskName
        workerTaskEnabled = $Plan.tasks[1].enabled
        codexIntegration = $codexResult
        agentsIntegration = $agentsResult
    }
}

function Invoke-InstallOrRepair {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)]$Plan)
    if ($PlanOnly) { return Invoke-InstallOrRepairCore -Plan $Plan }
    $mutex = Enter-CycAgentsMutex
    try {
        [void](Assert-CycExistingPrivateDirectory `
            -Path $Plan.installRoot `
            -AllowAdministratorsReadAndExecute)
        [void](Assert-CycExistingPrivateDirectory -Path $Plan.dataRoot)
        [void](Recover-CycAgentsTransactions -DataRoot $Plan.dataRoot -ManifestPath $Plan.manifestPath)
        return Invoke-InstallOrRepairCore -Plan $Plan
    } finally {
        Exit-CycAgentsMutex -Mutex $mutex
    }
}

function Invoke-UninstallCore {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$DataRoot
    )
    $install = Resolve-NormalizedPath $InstallRoot
    $data = Resolve-NormalizedPath $DataRoot
    [void](Assert-CycExistingPrivateDirectory `
        -Path $install `
        -AllowAdministratorsReadAndExecute)
    [void](Assert-CycExistingPrivateDirectory -Path $data)
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
    $currentBinding = Get-CycInitiatorBinding `
        -RequestedSid $InitiatingSid `
        -RequestedProfile $InitiatingProfile `
        -RequestedLocalAppData $InitiatingLocalAppData
    Assert-CycManifestInitiatorBinding -Manifest $manifest -CurrentBinding $currentBinding
    # Perform the task ownership preflight before Codex/AGENTS cleanup.  This
    # keeps Uninstall fail-closed without mutating shared integration state when
    # a same-name task belongs to another SID or install root.
    $taskSnapshots = @(Get-CycTaskSnapshots `
        -ExpectedInstallRoot $install `
        -ExpectedSid $currentBinding.sid)
    $agentsRecord = if ($manifest.PSObject.Properties['agentsIntegration']) {
        $manifest.agentsIntegration
    } else { $null }
    # Validate marker ownership and drift before removing the Codex plugin or
    # changing any local lifecycle resource.
    $agentsPreflight = if ($agentsRecord) {
        Get-CycAgentsRemovalPlan -Record $agentsRecord
    } else {
        [PSCustomObject]@{ required = $false; alreadyApplied = $true }
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
        agentsIntegration = $agentsRecord
        agentsCleanupRequired = [bool]$agentsPreflight.required
        managedWorker = if ($manifest.PSObject.Properties['managedWorker']) {
            $manifest.managedWorker
        } else { $null }
        uninstallRegistration = if ($manifest.PSObject.Properties['uninstallRegistration']) {
            $manifest.uninstallRegistration
        } else { $null }
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
        # Re-check immediately before the first external mutation to narrow the
        # task replacement race after the initial preflight.
        [void](Get-CycTaskSnapshots `
            -ExpectedInstallRoot $install `
            -ExpectedSid $currentBinding.sid)
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

    # Re-read the durable cleanup checkpoint before making local lifecycle
    # changes so a rollback never resurrects stale plugin cleanup state.
    $manifest = Read-InstallManifest -ManifestPath $manifestPath
    $agentsRecord = if ($manifest.PSObject.Properties['agentsIntegration']) {
        $manifest.agentsIntegration
    } else { $null }
    $agentsRemovalPlan = if ($agentsRecord) {
        Get-CycAgentsRemovalPlan -Record $agentsRecord
    } else {
        [PSCustomObject]@{ required = $false; alreadyApplied = $true }
    }
    $uninstallRollbackPlan = [PSCustomObject]@{
        installRoot = $install
        dataRoot = $data
        manifestPath = $manifestPath
        files = @($manifest.files)
    }
    $fileSnapshot = New-FileRollbackSnapshot -Plan $uninstallRollbackPlan -OldManifest $manifest
    $agentsRemovalTransaction = if ($agentsRecord -and $agentsRemovalPlan.required -and
        -not $agentsRemovalPlan.alreadyApplied) {
        Start-CycAgentsRemovalTransaction `
            -Record $agentsRecord `
            -RemovalPlan $agentsRemovalPlan `
            -TransactionRoot $fileSnapshot.root
    } else { $null }
    $uninstallRegistrationSnapshot = $null
    $preserveUninstallSnapshot = $false
    try {
        if ($agentsRemovalPlan.required) {
            Prepare-CycAgentsRemoval `
                -Manifest $manifest `
                -ManifestPath $manifestPath `
                -RemovalPlan $agentsRemovalPlan
            if ($agentsRemovalTransaction) {
                Apply-CycAgentsRemovalTransaction -Transaction $agentsRemovalTransaction
            }
            Complete-CycAgentsRemoval `
                -Manifest $manifest `
                -ManifestPath $manifestPath `
                -RemovalPlan $agentsRemovalPlan
        }
        if ($plan.uninstallRegistration -and $plan.uninstallRegistration.enabled) {
            $uninstallRegistrationSnapshot = Get-CycUninstallRegistrationSnapshot `
                -RegistryPath $plan.uninstallRegistration.registryPath
        }

        Unregister-CycTask `
            -Name $script:WorkerTaskName `
            -ExpectedInstallRoot $install `
            -ExpectedSid $currentBinding.sid
        Unregister-CycTask `
            -Name $script:ControllerTaskName `
            -ExpectedInstallRoot $install `
            -ExpectedSid $currentBinding.sid
        Stop-CycRuntime `
            -InstallRoot $install `
            -ExpectedSid $currentBinding.sid
        Remove-OwnedFiles -Manifest $manifest -ExpectedInstallRoot $install

        if ($plan.uninstallRegistration -and $plan.uninstallRegistration.enabled) {
            Remove-CycUninstallRegistration `
                -RegistryPath $plan.uninstallRegistration.registryPath `
                -ExpectedInstallRoot $install
        }

        Complete-CycAgentsRemovalTransaction -Transaction $agentsRemovalTransaction
        # Manifest absence is the external uninstall commit marker. Publish it
        # only after the AGENTS.md removal journal is durably committed.
        if (-not $PurgeData) {
            Remove-Item -LiteralPath $manifestPath -Force
        }
    } catch {
        $failure = $_
        $rollbackFailures = New-Object System.Collections.Generic.List[string]
        if ($uninstallRegistrationSnapshot) {
            try {
                Restore-CycUninstallRegistrationSnapshot `
                    -RegistryPath $plan.uninstallRegistration.registryPath `
                    -Snapshot $uninstallRegistrationSnapshot
            } catch { [void]$rollbackFailures.Add('uninstall registration') }
        }
        if ($agentsRemovalTransaction) {
            try { Rollback-CycAgentsRemovalTransaction -Transaction $agentsRemovalTransaction } catch {
                [void]$rollbackFailures.Add('global AGENTS.md')
            }
        }
        try { Restore-FileRollbackSnapshot -Snapshot $fileSnapshot } catch {
            [void]$rollbackFailures.Add('installed files')
        }
        try {
            Restore-CycTaskSnapshots `
                -Snapshots $taskSnapshots `
                -ExpectedInstallRoot $install `
                -ExpectedSid $currentBinding.sid
        } catch {
            [void]$rollbackFailures.Add('Scheduled Tasks')
        }
        if ($rollbackFailures.Count -eq 0) {
            try { Remove-FileRollbackSnapshot -Snapshot $fileSnapshot } catch {
                [void]$rollbackFailures.Add('transaction cleanup')
            }
        }
        if ($rollbackFailures.Count -gt 0) {
            $preserveUninstallSnapshot = $true
            throw "Uninstall failed and rollback was incomplete for: $($rollbackFailures -join ', '). Original failure: $($failure.Exception.Message)"
        }
        throw $failure
    }

    if (-not $preserveUninstallSnapshot) {
        try { Remove-FileRollbackSnapshot -Snapshot $fileSnapshot } catch {
            # A retained transaction snapshot is housekeeping. For non-purge
            # uninstall the absent manifest is already the durable core marker;
            # for purge the data-root removal below consumes the snapshot too.
        }
    }
    if ($PurgeData) {
        $purgeTarget = Assert-SafePurgeTarget -DataRoot $data -Manifest $manifest
        # The exact resolved target is checked above before the only recursive delete.
        Remove-Item -LiteralPath $purgeTarget -Recurse -Force
    } else {
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
        agentsIntegration = [PSCustomObject]@{
            required = [bool]$agentsRemovalPlan.required
            removed = [bool]($agentsRemovalPlan.required -or
                (Get-CycObjectProperty -Object $agentsRemovalPlan -Name 'completed' -Default $false))
            path = if ($agentsRemovalPlan.PSObject.Properties['path']) { $agentsRemovalPlan.path } else { $null }
        }
    }
}

function Invoke-Uninstall {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$DataRoot
    )
    if ($PlanOnly) { return Invoke-UninstallCore -InstallRoot $InstallRoot -DataRoot $DataRoot }
    $data = Resolve-NormalizedPath $DataRoot
    $manifestPath = Join-Path $data '.installer\install-manifest.json'
    $mutex = Enter-CycAgentsMutex
    try {
        [void](Assert-CycExistingPrivateDirectory `
            -Path (Resolve-NormalizedPath $InstallRoot) `
            -AllowAdministratorsReadAndExecute)
        [void](Assert-CycExistingPrivateDirectory -Path $data)
        [void](Recover-CycAgentsTransactions -DataRoot $data -ManifestPath $manifestPath)
        return Invoke-UninstallCore -InstallRoot $InstallRoot -DataRoot $data
    } finally {
        Exit-CycAgentsMutex -Mutex $mutex
    }
}

function Invoke-ClusterYourCodexBootstrap {
    if ($Action -eq 'IntegrateCodex') {
        if ($PlanOnly) {
            throw 'IntegrateCodex is a machine-verifiable commit action and does not support PlanOnly.'
        }
        if ([string]::IsNullOrWhiteSpace($CodexCliPath) -or
            $ExpectedInstallManifestSha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw 'IntegrateCodex requires the native host exact Codex CLI path and install-manifest digest.'
        }
        return Invoke-CycCodexOnlyIntegration `
            -InstallRoot $InstallRoot `
            -DataRoot $DataRoot `
            -CodexHome $CodexHome `
            -CodexCliPath $CodexCliPath `
            -ExpectedInstallManifestSha256 $ExpectedInstallManifestSha256 `
            -MutexTimeoutSeconds $MutexTimeoutSeconds `
            -ActionTimeoutSeconds $ActionTimeoutSeconds
    }
    if ($Action -eq 'CommitFirewall') {
        if ([string]::IsNullOrWhiteSpace($FirewallReceiptPath) -or
            $FirewallTransactionId -cnotmatch '^[0-9a-f]{32}$') {
            throw 'CommitFirewall requires the transaction id and durable receipt path.'
        }
        $binding = Get-CycInitiatorBinding `
            -RequestedSid $InitiatingSid `
            -RequestedProfile $InitiatingProfile `
            -RequestedLocalAppData $InitiatingLocalAppData
        return Invoke-CycCommitFirewallReceipt `
            -InstallRoot $InstallRoot `
            -DataRoot $DataRoot `
            -ReceiptPath $FirewallReceiptPath `
            -TransactionId $FirewallTransactionId `
            -CurrentBinding $binding
    }
    $packageIntegrityConfigured = -not [string]::IsNullOrWhiteSpace($PackageRoot) -or
        -not [string]::IsNullOrWhiteSpace($PackageManifest)
    if ($packageIntegrityConfigured) {
        if ([string]::IsNullOrWhiteSpace($PackageRoot) -or
            [string]::IsNullOrWhiteSpace($PackageManifest)) {
            throw 'PackageRoot and PackageManifest are required together.'
        }
        Assert-CycPackageManifest `
            -Root $PackageRoot `
            -ManifestPath $PackageManifest `
            -PayloadRoot $BundleRoot
    }
    if ($RequirePackageSignature) {
        if ([string]::IsNullOrWhiteSpace($PackageExecutable)) {
            throw 'RequirePackageSignature requires PackageExecutable.'
        }
        Assert-CycPackageSignature -Executable $PackageExecutable
    }
    if ($Action -eq 'Uninstall') {
        if (-not $DeferFirewall) {
            $manifest = Read-InstallManifest -ManifestPath (Join-Path (Resolve-NormalizedPath $DataRoot) '.installer\install-manifest.json')
            if ($manifest -and $manifest.PSObject.Properties['managedWorker'] -and
                $manifest.managedWorker.PSObject.Properties['firewall'] -and
                [bool]$manifest.managedWorker.firewall.enabled) {
                throw 'Per-user core uninstall requires the deferred firewall-only coordinator.'
            }
        }
        return Invoke-Uninstall -InstallRoot $InstallRoot -DataRoot $DataRoot
    }
    $resolvedInstallRoot = Resolve-NormalizedPath $InstallRoot
    $resolvedDataRoot = Resolve-NormalizedPath $DataRoot
    $existingManifest = Read-InstallManifest `
        -ManifestPath (Join-Path $resolvedDataRoot '.installer\install-manifest.json')
    if ($existingManifest -and
        (-not [string]::Equals(
                (Resolve-NormalizedPath ([string]$existingManifest.installRoot)),
                $resolvedInstallRoot,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -or
         -not [string]::Equals(
                (Resolve-NormalizedPath ([string]$existingManifest.dataRoot)),
                $resolvedDataRoot,
                [System.StringComparison]::OrdinalIgnoreCase
            ))) {
        throw 'Installed manifest roots do not match the requested lifecycle roots.'
    }
    [string[]]$workerPrivateAddressValues = @(
        @($WorkerPrivateAddress) | ForEach-Object {
            @(([string]$_).Split(',')) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        }
    )
    $plan = Get-InstallPlan `
        -BundleRoot $BundleRoot `
        -InstallRoot $resolvedInstallRoot `
        -DataRoot $resolvedDataRoot `
        -EnableWorker:$EnableWorker `
        -WorkerConfig $WorkerConfig `
        -SkipCodexIntegration:$SkipCodexIntegration `
        -CodexHome $CodexHome `
        -WorkerPublicHost $WorkerPublicHost `
        -WorkerBindHost $WorkerBindHost `
        -WorkerInterfaceIndex $WorkerInterfaceIndex `
        -WorkerControllerHostName $WorkerControllerHostName `
        -WorkerPrivateAddress $workerPrivateAddressValues `
        -WorkerListenPort $WorkerListenPort `
        -DisableManagedWorkerListener:$DisableManagedWorkerListener `
        -SkipFirewall:$SkipFirewall `
        -DeferFirewall:$DeferFirewall `
        -ExistingManifest $existingManifest `
        -InitiatingSid $InitiatingSid `
        -InitiatingProfile $InitiatingProfile `
        -InitiatingLocalAppData $InitiatingLocalAppData `
        -FirewallTransactionId $FirewallTransactionId `
        -FirewallRequestSha256 $FirewallRequestSha256 `
        -SkipUninstallRegistration:$SkipUninstallRegistration `
        -UninstallerPath $UninstallerPath
    return Invoke-InstallOrRepair -Plan $plan
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($Action -eq 'IntegrateCodex') {
        try {
            $codexReceipt = Invoke-ClusterYourCodexBootstrap
            $receiptJson = ConvertTo-CycCodexOnlyReceiptJson -Receipt $codexReceipt
            [Console]::Out.WriteLine($receiptJson)
            exit 0
        } catch {
            $message = [string]$_.Exception.Message
            $message = $message.Replace("`r", ' ').Replace("`n", ' ')
            if ($message.Length -gt 2048) { $message = $message.Substring(0, 2048) }
            [Console]::Error.WriteLine($message)
            exit 1
        }
    }
    Invoke-ClusterYourCodexBootstrap
}
