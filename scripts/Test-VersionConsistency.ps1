#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [Alias('ExpectedTag')][string]$SourceTag = '',
    [switch]$RequirePrerelease,
    [switch]$SkipNegativeTests,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

function Assert-CycStrictSemVer {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-(?<pre>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$') {
        throw "Product version must be canonical SemVer without build metadata: $Value"
    }
    if ($Matches.pre) {
        foreach ($identifier in $Matches.pre.Split('.')) {
            if ($identifier -cmatch '^[0-9]+$' -and $identifier.Length -gt 1 -and $identifier.StartsWith('0')) {
                throw "Numeric prerelease identifiers must not have leading zeroes: $Value"
            }
        }
    }
}

function Get-CycProductVersion {
    param([Parameter(Mandatory = $true)][string]$Root)

    $path = Join-Path $Root 'VERSION'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "VERSION is missing: $path"
    }
    $item = Get-Item -LiteralPath $path -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -lt 2 -or $item.Length -gt 256) {
        throw 'VERSION must be a small regular file.'
    }
    $bytes = [System.IO.File]::ReadAllBytes($path)
    if ($bytes[-1] -ne 0x0a -or @($bytes | Where-Object { $_ -eq 0x0a }).Count -ne 1 -or
        @($bytes | Where-Object { $_ -eq 0x0d -or $_ -eq 0x00 }).Count -ne 0) {
        throw 'VERSION must contain exactly one UTF-8 line terminated by one LF.'
    }
    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    try { $version = $strictUtf8.GetString($bytes, 0, $bytes.Length - 1) } catch {
        throw 'VERSION is not valid UTF-8.'
    }
    Assert-CycStrictSemVer -Value $version
    return $version
}

function Assert-CycReleaseIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [string]$Tag,
        [bool]$PrereleaseRequired
    )

    Assert-CycStrictSemVer -Value $Version
    $isPrerelease = $Version.Contains('-')
    if ($PrereleaseRequired -and -not $isPrerelease) {
        throw "Stable product version is forbidden by this prerelease gate: $Version"
    }
    if ($PrereleaseRequired -and
        $Version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-(preview|alpha|beta|rc)\.(0|[1-9][0-9]*)$') {
        throw "Prerelease workflow versions must use preview.N, alpha.N, beta.N, or rc.N: $Version"
    }
    if (-not [string]::IsNullOrWhiteSpace($Tag)) {
        if (-not $isPrerelease) {
            throw "Stable tags are forbidden by the prerelease workflow: $Tag"
        }
        if ($Tag -cne "v$Version") {
            throw "Source tag does not match VERSION: expected v$Version, got $Tag"
        }
        if ($Tag -cnotmatch '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-(preview|alpha|beta|rc)\.(0|[1-9][0-9]*)$') {
            throw "Source tag is not a strict prerelease SemVer tag: $Tag"
        }
    }
    if ($isPrerelease) { return 'prerelease' }
    return 'stable'
}

function Get-CycText {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )
    $path = Join-Path $Root $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Version-bearing file is missing: $RelativePath"
    }
    return [System.IO.File]::ReadAllText($path)
}

function Assert-CycRegexVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Expected
    )

    $text = Get-CycText -Root $Root -RelativePath $RelativePath
    $regex = New-Object System.Text.RegularExpressions.Regex(
        $Pattern,
        ([System.Text.RegularExpressions.RegexOptions]::Multiline -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
    )
    $matches = $regex.Matches($text)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one product-version field in $RelativePath; found $($matches.Count)."
    }
    $actual = [string]$matches[0].Groups['version'].Value
    if ($actual -cne $Expected) {
        throw "Product version mismatch in ${RelativePath}: expected $Expected, got $actual"
    }
}

function Assert-CycJsonVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Expected
    )

    $text = Get-CycText -Root $Root -RelativePath $RelativePath
    try { $value = $text | ConvertFrom-Json } catch { throw "Invalid JSON in ${RelativePath}: $($_.Exception.Message)" }
    $property = $value.PSObject.Properties['version']
    if ($null -eq $property -or -not ($property.Value -is [string]) -or [string]$property.Value -cne $Expected) {
        throw "Product version mismatch in ${RelativePath}: expected $Expected"
    }
}

function Assert-CycCargoPackageVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Section,
        [Parameter(Mandatory = $true)][string]$Expected
    )

    $text = Get-CycText -Root $Root -RelativePath $RelativePath
    $escaped = [System.Text.RegularExpressions.Regex]::Escape($Section)
    $header = [System.Text.RegularExpressions.Regex]::Match($text, ('(?m)^\[{0}\]\r?$' -f $escaped))
    if (-not $header.Success) { throw "Cargo section [$Section] is missing from $RelativePath." }
    $remaining = $text.Substring($header.Index + $header.Length)
    $nextHeader = [System.Text.RegularExpressions.Regex]::Match($remaining, '(?m)^\[[^\r\n]+\]\r?$')
    $sectionText = if ($nextHeader.Success) { $remaining.Substring(0, $nextHeader.Index) } else { $remaining }
    $matches = [System.Text.RegularExpressions.Regex]::Matches(
        $sectionText,
        '(?m)^version\s*=\s*"(?<version>[^"]+)"\s*$'
    )
    if ($matches.Count -ne 1 -or [string]$matches[0].Groups['version'].Value -cne $Expected) {
        throw "Product version mismatch in [$Section] of ${RelativePath}: expected $Expected"
    }
}

function Assert-CycCargoLockVersions {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string[]]$PackageNames,
        [Parameter(Mandatory = $true)][string]$Expected
    )

    $text = Get-CycText -Root $Root -RelativePath $RelativePath
    foreach ($packageName in $PackageNames) {
        $escaped = [System.Text.RegularExpressions.Regex]::Escape($packageName)
        $pattern = '(?ms)^\[\[package\]\]\s*\r?\nname\s*=\s*"{0}"\s*\r?\nversion\s*=\s*"(?<version>[^"]+)"' -f $escaped
        $matches = [System.Text.RegularExpressions.Regex]::Matches($text, $pattern)
        if ($matches.Count -ne 1 -or [string]$matches[0].Groups['version'].Value -cne $Expected) {
            throw "Cargo lock product version mismatch for $packageName in ${RelativePath}."
        }
    }
}

function Assert-CycReleaseWorkflowIdentity {
    param([Parameter(Mandatory = $true)][string]$Root)

    $workflow = Get-CycText -Root $Root -RelativePath '.github/workflows/release.yml'
    $ciWorkflow = Get-CycText -Root $Root -RelativePath '.github/workflows/ci.yml'
    $gaWorkflowScript = Join-Path $Root 'scripts/Test-GAReadiness.ps1'
    if (-not (Test-Path -LiteralPath $gaWorkflowScript -PathType Leaf)) {
        throw 'Protected stable GA readiness gate script is missing.'
    }
    & $gaWorkflowScript -RepositoryRoot $Root -ContractOnly | Out-Null
    if (-not $?) {
        throw 'Protected stable GA readiness gate contract failed.'
    }
    $sourceTagBinding = 'CYC_SOURCE_TAG: ${{ github.ref_type == ''tag'' && github.ref_name || '''' }}'
    if ($workflow -notmatch '(?m)^\s*CYC_RELEASE_CHANNEL:\s*prerelease\s*$' -or
        -not $workflow.Contains($sourceTagBinding) -or
        $workflow -notmatch '(?m)^\s*-?\s*.*Test-VersionConsistency\.ps1' -or
        $workflow -notmatch '(?m)^\s*RequirePrerelease\s*=\s*\$true\s*$' -or
        $workflow -notmatch '(?m)^\s*\$arguments\.SourceTag\s*=\s*\[string\]\$env:CYC_SOURCE_TAG\s*$') {
        throw 'Release workflow is missing its fail-closed prerelease identity gate.'
    }
    # Keep the shell-side source-tag check in lockstep with
    # Assert-CycReleaseIdentity.  A preview workflow must accept every
    # supported prerelease channel (preview/alpha/beta/rc) while rejecting
    # leading-zero identifiers and stable/dev tags before provenance fetch.
    $strictPrereleaseTagPattern = '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-(preview|alpha|beta|rc)\.(0|[1-9][0-9]*)$'
    $strictPrereleaseTagGate = 'if [[ ! "$CYC_SOURCE_TAG" =~ ' + $strictPrereleaseTagPattern + ' ]]; then'
    if (-not $workflow.Contains($strictPrereleaseTagGate)) {
        throw 'Release workflow source-tag validation is not aligned with the strict prerelease channel contract.'
    }

    $releaseJob = [System.Text.RegularExpressions.Regex]::Match(
        $workflow,
        '(?ms)^  github-release:\s*\r?\n(?<body>.*?)(?=^  [0-9A-Za-z_-]+:\s*\r?$|\z)'
    )
    if (-not $releaseJob.Success -or
        $releaseJob.Groups['body'].Value -notmatch "(?m)^\s*if:\s*github\.ref_type\s*==\s*'tag'\s*&&\s*needs\.release-identity\.outputs\.source_tag\s*!=\s*''\s*$" -or
        $releaseJob.Groups['body'].Value -notmatch '(?m)^\s*environment:\s*preview-publication\s*$' -or
        $releaseJob.Groups['body'].Value -notmatch '(?m)^\s*draft:\s*false\s*$' -or
        $releaseJob.Groups['body'].Value -notmatch '(?m)^\s*prerelease:\s*true\s*$') {
        throw 'GitHub preview publishing must remain preview-publication-environment-bound, tag-bound, public, and prerelease-only.'
    }

    $windows11AcceptanceJob = [System.Text.RegularExpressions.Regex]::Match(
        $workflow,
        '(?ms)^  windows11-acceptance:\s*\r?\n(?<body>.*?)(?=^  [0-9A-Za-z_-]+:\s*\r?$|\z)'
    )
    if (-not $windows11AcceptanceJob.Success -or
        $windows11AcceptanceJob.Groups['body'].Value -notmatch '(?m)^\s*needs:\s*\[release-identity, windows-preview\]\s*$' -or
        $windows11AcceptanceJob.Groups['body'].Value -notmatch '(?m)^\s*runs-on:\s*windows-11-arm\s*$' -or
        $windows11AcceptanceJob.Groups['body'].Value -notmatch '(?m)^\s*CYC_DISPOSABLE_WINDOWS:\s*["'']1["'']\s*$' -or
        $windows11AcceptanceJob.Groups['body'].Value -notmatch '(?m)^\s*-File\s+\.\\packaging\\windows\\Test-FreshDeployment\.ps1\s*`?\s*$' -or
        $windows11AcceptanceJob.Groups['body'].Value -notmatch '(?m)^\s*-File\s+\.\\packaging\\windows\\Test-SetupSilent\.ps1\s*`?\s*$' -or
        $windows11AcceptanceJob.Groups['body'].Value -notmatch "(?m)^\s*acceptance\s*=\s*'clean-windows-11-arm64-x64-emulation'\s*$" -or
        $windows11AcceptanceJob.Groups['body'].Value -notmatch '(?m)^\s*x64Native\s*=\s*\$false\s*$') {
        throw 'Release workflow is missing clean Windows 11 ARM64 x64-emulation compatibility acceptance.'
    }

    $releaseIndexJob = [System.Text.RegularExpressions.Regex]::Match(
        $workflow,
        '(?ms)^  release-index:\s*\r?\n(?<body>.*?)(?=^  [0-9A-Za-z_-]+:\s*\r?$|\z)'
    )
    if (-not $releaseIndexJob.Success -or
        $releaseIndexJob.Groups['body'].Value -notmatch '(?m)^\s*needs:\s*\[[^\]\r\n]*msrv[^\]\r\n]*windows11-acceptance[^\]\r\n]*\]\s*$') {
        throw 'Release indexing and publication must be blocked by MSRV and Windows 11 compatibility acceptance.'
    }

    foreach ($workflowContract in @(
        [PSCustomObject]@{ Name = 'CI'; Text = $ciWorkflow },
        [PSCustomObject]@{ Name = 'release'; Text = $workflow }
    )) {
        $msrvJob = [System.Text.RegularExpressions.Regex]::Match(
            $workflowContract.Text,
            '(?ms)^  msrv:\s*\r?\n(?<body>.*?)(?=^  [0-9A-Za-z_-]+:\s*\r?$|\z)'
        )
        if (-not $msrvJob.Success -or
            $msrvJob.Groups['body'].Value -notmatch '(?m)^\s*RUSTUP_TOOLCHAIN:\s*1\.88\.0\s*$' -or
            $msrvJob.Groups['body'].Value -notmatch 'dtolnay/rust-toolchain@2eae45db285e407f22119950686d47e1101e071b\s+#\s+1\.88\.0' -or
            $msrvJob.Groups['body'].Value -notmatch '(?m)^\s*run:\s*\.\/scripts\/Test-RustMsrv\.ps1\s*$' -or
            $msrvJob.Groups['body'].Value -notmatch '(?m)^\s*run:\s*cargo check --workspace --locked\s*$' -or
            $msrvJob.Groups['body'].Value -notmatch '(?m)^\s*run:\s*cargo check --locked --manifest-path apps/desktop/src-tauri/Cargo\.toml\s*$') {
            throw "$($workflowContract.Name) workflow is missing the exact Rust 1.88.0 workspace/desktop MSRV gates."
        }
    }

    foreach ($requiredReleaseContract in @(
        'macos-x86_64',
        'macos-aarch64',
        'runtimeGated = $true',
        'containmentReady = $false',
        'liveReady = $false',
        'Expected nine preview artifact sidecars',
        "bomFormat = 'CycloneDX'",
        "specVersion = '1.6'",
        'unsigned = $true',
        'unattested = -not $taggedForAttestation',
        'provenanceSubjectRoot',
        'subject-path: provenance-subjects/*',
        'bundleSha256 = $bundleHash',
        'actions/attest-build-provenance@96278af6caaf10aea03fd8d33a09a777ca52d62f'
    )) {
        if (-not $workflow.Contains($requiredReleaseContract)) {
            throw "Release workflow is missing its macOS/SBOM/provenance contract: $requiredReleaseContract"
        }
    }
    if ($workflow -match '(?m)^\s*unattested\s*=\s*\$true\s*$') {
        throw 'Release index must not claim every tagged asset remains unattested.'
    }

    $blocks = [System.Text.RegularExpressions.Regex]::Matches(
        $workflow,
        "(?ms)schemaVersion\s*=\s*'cyc\.dev/(?<kind>platform-status|release-manifest|release-index)/v1'(?<body>.*?)ConvertTo-Json"
    )
    if ($blocks.Count -ne 7) {
        throw "Expected seven release status/manifest/index metadata blocks; found $($blocks.Count)."
    }
    $expectedCounts = @{ 'platform-status' = 3; 'release-manifest' = 3; 'release-index' = 1 }
    foreach ($kind in $expectedCounts.Keys) {
        if (@($blocks | Where-Object { $_.Groups['kind'].Value -ceq $kind }).Count -ne $expectedCounts[$kind]) {
            throw "Release workflow has an unexpected number of $kind metadata blocks."
        }
    }
    foreach ($block in $blocks) {
        $body = [string]$block.Groups['body'].Value
        if ($body -notmatch '(?m)^\s*productVersion\s*=\s*\[string\]\$env:CYC_PRODUCT_VERSION\s*$') {
            throw "Release $($block.Groups['kind'].Value) metadata does not bind productVersion to VERSION."
        }
        if ($body -notmatch '(?m)^\s*releaseChannel\s*=\s*\[string\]\$env:CYC_RELEASE_CHANNEL\s*$') {
            throw "Release $($block.Groups['kind'].Value) metadata does not bind the prerelease channel."
        }
        if ($body -notmatch '(?m)^\s*sourceTag\s*=\s*if\s*\(\[string\]::IsNullOrWhiteSpace\(\[string\]\$env:CYC_SOURCE_TAG\)\)\s*\{\s*\$null\s*\}\s*else\s*\{\s*\[string\]\$env:CYC_SOURCE_TAG\s*\}\s*$') {
            throw "Release $($block.Groups['kind'].Value) metadata does not bind the validated source tag."
        }
    }
}

function Invoke-CycConsistencyCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string]$Tag,
        [bool]$PrereleaseRequired
    )

    $pinGate = Join-Path $Root 'scripts/Test-GitHubActionPins.ps1'
    if (-not (Test-Path -LiteralPath $pinGate -PathType Leaf)) {
        throw 'GitHub Action pin gate is missing.'
    }
    & $pinGate -WorkflowRoot (Join-Path $Root '.github/workflows') | Out-Null

    $version = Get-CycProductVersion -Root $Root
    $channel = Assert-CycReleaseIdentity -Version $version -Tag $Tag -PrereleaseRequired $PrereleaseRequired

    Assert-CycCargoPackageVersion -Root $Root -RelativePath 'Cargo.toml' `
        -Section 'workspace.package' -Expected $version
    Assert-CycCargoPackageVersion -Root $Root -RelativePath 'apps/desktop/src-tauri/Cargo.toml' `
        -Section 'package' -Expected $version
    foreach ($jsonPath in @(
        'package.json',
        'apps/desktop/package.json',
        'apps/desktop/src-tauri/tauri.conf.json',
        'plugins/cluster-your-codex/.codex-plugin/plugin.json',
        'plugins/cluster-your-codex/mcp/package.json'
    )) {
        Assert-CycJsonVersion -Root $Root -RelativePath $jsonPath -Expected $version
    }
    Assert-CycRegexVersion -Root $Root -RelativePath 'plugins/cluster-your-codex/mcp/src/runtime-receipt.ts' `
        -Pattern '^export const MCP_BRIDGE_VERSION = "(?<version>[^"]+)" as const;\s*$' -Expected $version
    Assert-CycRegexVersion -Root $Root -RelativePath 'plugins/cluster-your-codex/mcp/src/server.ts' `
        -Pattern '^\s*\{ name: "cluster-your-codex", version: "(?<version>[^"]+)" \},\s*$' -Expected $version
    Assert-CycRegexVersion -Root $Root -RelativePath 'packaging/windows/bootstrap.ps1' `
        -Pattern '^\s*\$script:ProductVersion\s*=\s*''(?<version>[^'']+)''\s*$' -Expected $version

    $workerKitBuilder = Get-CycText -Root $Root -RelativePath 'packaging/worker-kits/New-WorkerKit.ps1'
    if ($workerKitBuilder -notmatch "Join-Path.+\.\.[\\/]\.\.[\\/]VERSION" -or
        $workerKitBuilder -match "\[string\]\s*\$Version\s*=\s*'[^']+'") {
        throw 'Worker-kit default version must derive from root VERSION without a hard-coded fallback.'
    }

    Assert-CycCargoLockVersions -Root $Root -RelativePath 'Cargo.lock' `
        -PackageNames @('cyc-cli', 'cyc-controller', 'cyc-protocol', 'cyc-provision', 'cyc-scheduler', 'cyc-secrets', 'cyc-ssh', 'cyc-worker') `
        -Expected $version
    Assert-CycCargoLockVersions -Root $Root -RelativePath 'apps/desktop/src-tauri/Cargo.lock' `
        -PackageNames @('clusteryourcodex-desktop-host', 'cyc-protocol', 'cyc-provision', 'cyc-secrets', 'cyc-ssh') `
        -Expected $version
    Assert-CycReleaseWorkflowIdentity -Root $Root

    return [PSCustomObject]@{
        productVersion = $version
        releaseChannel = $channel
        sourceTag = if ([string]::IsNullOrWhiteSpace($Tag)) { $null } else { $Tag }
    }
}

function Assert-CycExpectedFailure {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Description,
        [string]$ExpectedMessagePattern
    )
    $failed = $false
    $failureMessage = $null
    try {
        [void](& $Action)
    } catch {
        $failed = $true
        $failureMessage = [string]$_.Exception.Message
    }
    if (-not $failed) { throw "Negative version test did not fail closed: $Description" }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedMessagePattern) -and
        $failureMessage -notmatch $ExpectedMessagePattern) {
        throw "Negative version test failed for the wrong reason ($Description): $failureMessage"
    }
}

$RepositoryRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
$result = Invoke-CycConsistencyCheck `
    -Root $RepositoryRoot `
    -Tag $SourceTag.Trim() `
    -PrereleaseRequired ([bool]$RequirePrerelease)

if (-not $SkipNegativeTests) {
    Assert-CycExpectedFailure `
        -Description 'mismatched prerelease tag' `
        -Action { Assert-CycReleaseIdentity -Version $result.productVersion -Tag 'v9.9.9-preview.9' -PrereleaseRequired $true }
    Assert-CycExpectedFailure `
        -Description 'stable tag in prerelease workflow' `
        -Action { Assert-CycReleaseIdentity -Version '1.0.0' -Tag 'v1.0.0' -PrereleaseRequired $true }
    Assert-CycExpectedFailure `
        -Description 'unsupported prerelease channel' `
        -Action { Assert-CycReleaseIdentity -Version '1.0.0-dev.1' -Tag 'v1.0.0-dev.1' -PrereleaseRequired $true }

    $fixture = Join-Path ([System.IO.Path]::GetTempPath()) ('cyc-version-negative-' + [Guid]::NewGuid().ToString('N'))
    try {
        foreach ($relativePath in @(
            'VERSION', 'Cargo.toml', 'Cargo.lock', 'package.json',
            'apps/desktop/package.json', 'apps/desktop/src-tauri/Cargo.toml',
            'apps/desktop/src-tauri/Cargo.lock', 'apps/desktop/src-tauri/tauri.conf.json',
            'plugins/cluster-your-codex/.codex-plugin/plugin.json',
            'plugins/cluster-your-codex/mcp/package.json',
            'plugins/cluster-your-codex/mcp/src/runtime-receipt.ts',
            'plugins/cluster-your-codex/mcp/src/server.ts',
            'packaging/windows/bootstrap.ps1',
            'packaging/worker-kits/New-WorkerKit.ps1',
            '.github/workflows/ci.yml',
            '.github/workflows/release.yml',
            '.github/workflows/ga.yml',
            'scripts/Test-GAReadiness.ps1',
            'scripts/Test-ExternalHttpsUrl.py',
            'scripts/Test-GitHubActionPins.ps1'
        )) {
            $destination = Join-Path $fixture $relativePath
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force)
            Copy-Item -LiteralPath (Join-Path $RepositoryRoot $relativePath) -Destination $destination
        }
        $mismatchPath = Join-Path $fixture 'plugins/cluster-your-codex/mcp/package.json'
        $mismatch = [System.IO.File]::ReadAllText($mismatchPath).Replace(
            '"version": "' + $result.productVersion + '"',
            '"version": "9.9.9-preview.9"'
        )
        [System.IO.File]::WriteAllText($mismatchPath, $mismatch, (New-Object System.Text.UTF8Encoding($false)))
        Assert-CycExpectedFailure `
            -Description 'one product manifest differs from VERSION' `
            -Action { Invoke-CycConsistencyCheck -Root $fixture -Tag '' -PrereleaseRequired $true }

        Copy-Item `
            -LiteralPath (Join-Path $RepositoryRoot 'plugins/cluster-your-codex/mcp/package.json') `
            -Destination $mismatchPath `
            -Force

        $fixtureWorkflowPath = Join-Path $fixture '.github/workflows/release.yml'
        $workflowText = [System.IO.File]::ReadAllText($fixtureWorkflowPath)
        $workflowMismatch = $workflowText.Replace(
            'productVersion = [string]$env:CYC_PRODUCT_VERSION',
            "productVersion = '9.9.9-preview.9'"
        )
        if ($workflowMismatch -ceq $workflowText) {
            throw 'Negative release-metadata fixture could not be constructed.'
        }
        [System.IO.File]::WriteAllText(
            $fixtureWorkflowPath,
            $workflowMismatch,
            (New-Object System.Text.UTF8Encoding($false))
        )
        Assert-CycExpectedFailure `
            -Description 'release metadata does not derive productVersion from the validated VERSION' `
            -Action { Invoke-CycConsistencyCheck -Root $fixture -Tag '' -PrereleaseRequired $true }
        Copy-Item `
            -LiteralPath (Join-Path $RepositoryRoot '.github/workflows/release.yml') `
            -Destination $fixtureWorkflowPath `
            -Force

        $workflowText = [System.IO.File]::ReadAllText($fixtureWorkflowPath)
        $workflowUnpinned = $workflowText.Replace(
            'actions/checkout@11d5960a326750d5838078e36cf38b85af677262',
            'actions/checkout@v4'
        )
        if ($workflowUnpinned -ceq $workflowText) {
            throw 'Negative GitHub Action pin fixture could not be constructed.'
        }
        [System.IO.File]::WriteAllText(
            $fixtureWorkflowPath,
            $workflowUnpinned,
            (New-Object System.Text.UTF8Encoding($false))
        )
        Assert-CycExpectedFailure `
            -Description 'a remote GitHub Action is not commit-pinned' `
            -ExpectedMessagePattern 'GitHub Actions pin validation failed:' `
            -Action { Invoke-CycConsistencyCheck -Root $fixture -Tag '' -PrereleaseRequired $true }
        Copy-Item `
            -LiteralPath (Join-Path $RepositoryRoot '.github/workflows/release.yml') `
            -Destination $fixtureWorkflowPath `
            -Force

        $fixtureGaWorkflowPath = Join-Path $fixture '.github/workflows/ga.yml'
        $gaWorkflowText = [System.IO.File]::ReadAllText($fixtureGaWorkflowPath)
        $gaWorkflowAuto = $gaWorkflowText.Replace(
            'workflow_dispatch:',
            'push:'
        )
        if ($gaWorkflowAuto -ceq $gaWorkflowText) {
            throw 'Negative GA workflow fixture could not be constructed.'
        }
        [System.IO.File]::WriteAllText(
            $fixtureGaWorkflowPath,
            $gaWorkflowAuto,
            (New-Object System.Text.UTF8Encoding($false))
        )
        Assert-CycExpectedFailure `
            -Description 'stable GA workflow is not manual and fail-closed' `
            -ExpectedMessagePattern "GA workflow contains 'workflow_dispatch:'" `
            -Action { Invoke-CycConsistencyCheck -Root $fixture -Tag '' -PrereleaseRequired $true }
        Copy-Item `
            -LiteralPath (Join-Path $RepositoryRoot '.github/workflows/ga.yml') `
            -Destination $fixtureGaWorkflowPath `
            -Force


        $workflowText = [System.IO.File]::ReadAllText($fixtureWorkflowPath)
        $workflowAlwaysUnattested = $workflowText.Replace(
            'unattested = -not $taggedForAttestation',
            'unattested = $true'
        )
        if ($workflowAlwaysUnattested -ceq $workflowText) {
            throw 'Negative release-attestation fixture could not be constructed.'
        }
        [System.IO.File]::WriteAllText(
            $fixtureWorkflowPath,
            $workflowAlwaysUnattested,
            (New-Object System.Text.UTF8Encoding($false))
        )
        Assert-CycExpectedFailure `
            -Description 'tagged release index remains hard-coded as unattested' `
            -Action { Invoke-CycConsistencyCheck -Root $fixture -Tag '' -PrereleaseRequired $true }
        Copy-Item `
            -LiteralPath (Join-Path $RepositoryRoot '.github/workflows/release.yml') `
            -Destination $fixtureWorkflowPath `
            -Force

        $fixtureCiPath = Join-Path $fixture '.github/workflows/ci.yml'
        $ciWorkflowText = [System.IO.File]::ReadAllText($fixtureCiPath)
        $ciMsrvMismatch = $ciWorkflowText.Replace('RUSTUP_TOOLCHAIN: 1.88.0', 'RUSTUP_TOOLCHAIN: 1.89.0')
        if ($ciMsrvMismatch -ceq $ciWorkflowText) {
            throw 'Negative MSRV fixture could not be constructed.'
        }
        [System.IO.File]::WriteAllText(
            $fixtureCiPath,
            $ciMsrvMismatch,
            (New-Object System.Text.UTF8Encoding($false))
        )
        Assert-CycExpectedFailure `
            -Description 'CI MSRV toolchain differs from the declared Rust 1.88 baseline' `
            -ExpectedMessagePattern 'CI workflow is missing the exact Rust 1\.88\.0 workspace/desktop MSRV gates' `
            -Action { Invoke-CycConsistencyCheck -Root $fixture -Tag '' -PrereleaseRequired $true }
        Copy-Item `
            -LiteralPath (Join-Path $RepositoryRoot '.github/workflows/ci.yml') `
            -Destination $fixtureCiPath `
            -Force

        $fixtureVersionPath = Join-Path $fixture 'VERSION'
        [System.IO.File]::WriteAllText(
            $fixtureVersionPath,
            $result.productVersion + "`r`n",
            (New-Object System.Text.UTF8Encoding($false))
        )
        Assert-CycExpectedFailure `
            -Description 'VERSION uses CRLF instead of its canonical single LF' `
            -Action { Invoke-CycConsistencyCheck -Root $fixture -Tag '' -PrereleaseRequired $true }

        $versionPayload = (New-Object System.Text.UTF8Encoding($false)).GetBytes($result.productVersion + "`n")
        $bomPayload = New-Object byte[] ($versionPayload.Length + 3)
        $bomPayload[0] = 0xef
        $bomPayload[1] = 0xbb
        $bomPayload[2] = 0xbf
        [Array]::Copy($versionPayload, 0, $bomPayload, 3, $versionPayload.Length)
        [System.IO.File]::WriteAllBytes($fixtureVersionPath, $bomPayload)
        Assert-CycExpectedFailure `
            -Description 'VERSION contains a UTF-8 BOM' `
            -Action { Invoke-CycConsistencyCheck -Root $fixture -Tag '' -PrereleaseRequired $true }

        [System.IO.File]::WriteAllText(
            $fixtureVersionPath,
            $result.productVersion,
            (New-Object System.Text.UTF8Encoding($false))
        )
        Assert-CycExpectedFailure `
            -Description 'VERSION omits its required terminal LF' `
            -Action { Invoke-CycConsistencyCheck -Root $fixture -Tag '' -PrereleaseRequired $true }
    } finally {
        if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
    }
}

$result | Add-Member `
    -NotePropertyName negativeTests `
    -NotePropertyValue $(if ($SkipNegativeTests) { 'skipped' } else { 'passed' })

if ($Json) {
    $result | ConvertTo-Json -Compress
} else {
    $result
}
