#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$Repository = '',
    [string]$ExpectedCommit = '',
    [string]$Workflow = 'ci.yml',
    [string]$WorkflowName = 'CI',
    [string]$WorkflowPath = '.github/workflows/ci.yml',
    [string]$Branch = 'main',
    [string]$Event = 'push',
    [string]$RunListPath = '',
    [string]$JobsPath = '',
    [string]$CheckRunsPath = '',
    [string[]]$RequiredCheckNames = $null,
    [switch]$ContractOnly,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This is the reviewed check contract for .github/workflows/ci.yml at the
# current GA boundary.  The list is deliberately explicit: silently accepting
# a renamed, removed, or newly added CI job would turn an exact-source proof
# into a best-effort status check.
$script:GaRequiredChecksSchema = 'cyc.dev/ga-required-checks/v1'
$script:GaRequiredChecksInputSchema = 'cyc.dev/ga-required-checks-input/v1'
$script:GaRequiredCheckWorkflowPath = '.github/workflows/ci.yml'
$script:GaRequiredCheckWorkflowName = 'CI'
$script:GaRequiredCheckBranch = 'main'
$script:GaRequiredCheckEvent = 'push'
$script:GaDefaultRequiredCheckNames = @(
    'Product version identity',
    'Minimum supported Rust 1.88.0 (workspace)',
    'Minimum supported Rust 1.88.0 (desktop)',
    'Rust (ubuntu-latest)',
    'Rust (windows-latest)',
    'Rust (macos-latest)',
    'Native Worker Kit (linux-x64)',
    'Native Worker Kit (macos-x64)',
    'Native Worker Kit (macos-arm64)',
    'Desktop, Windows host, and Codex bridge'
)

function Assert-GaRequiredCondition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw "GA required-check assertion failed: $Message"
    }
}

function Test-GaRequiredInteger {
    param([Parameter(Mandatory = $true)][object]$Value)

    return ($Value -is [byte]) -or
        ($Value -is [sbyte]) -or
        ($Value -is [int16]) -or
        ($Value -is [uint16]) -or
        ($Value -is [int32]) -or
        ($Value -is [uint32]) -or
        ($Value -is [int64]) -or
        ($Value -is [uint64])
}

function Get-GaRequiredProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-GaRequiredCondition ($null -ne $Object) "$Description must be an object"
    $property = $Object.PSObject.Properties[$Name]
    Assert-GaRequiredCondition ($null -ne $property) "$Description is missing required property '$Name'"
    return $property.Value
}

function Assert-GaRequiredString {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Description,
        [switch]$AllowEmpty
    )

    $value = Get-GaRequiredProperty -Object $Object -Name $Name -Description $Description
    Assert-GaRequiredCondition ($value -is [string]) "$Description.$Name must be a JSON string"
    if (-not $AllowEmpty) {
        Assert-GaRequiredCondition (-not [string]::IsNullOrWhiteSpace([string]$value)) "$Description.$Name must be non-empty"
    }
    return [string]$value
}

function Assert-GaRequiredInteger {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Description,
        [long]$Minimum = [long]::MinValue
    )

    $value = Get-GaRequiredProperty -Object $Object -Name $Name -Description $Description
    Assert-GaRequiredCondition (Test-GaRequiredInteger -Value $value) "$Description.$Name must be a JSON integer"
    try {
        [decimal]$numeric = $value
    } catch {
        throw "GA required-check assertion failed: $Description.$Name is outside the supported integer range"
    }
    Assert-GaRequiredCondition ($numeric -ge [decimal]$Minimum) "$Description.$Name must be at least $Minimum"
    return [long]$numeric
}

function Assert-GaRequiredSha {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $value = Assert-GaRequiredString -Object $Object -Name $Name -Description $Description
    Assert-GaRequiredCondition ($value -cmatch '^[0-9a-fA-F]{40}$') "$Description.$Name must be a full 40-character commit SHA"
    return $value
}

function Convert-GaRequiredInstant {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $value = Get-GaRequiredProperty -Object $Object -Name $Name -Description $Description
    if ($value -is [DateTimeOffset]) {
        return [DateTimeOffset]$value
    }
    if ($value -is [DateTime]) {
        Assert-GaRequiredCondition ($value.Kind -ne [DateTimeKind]::Unspecified) "$Description.$Name must carry an explicit UTC offset"
        return [DateTimeOffset]$value
    }
    Assert-GaRequiredCondition ($value -is [string]) "$Description.$Name must be an ISO-8601 instant with an explicit UTC offset"
    $text = [string]$value
    Assert-GaRequiredCondition (
        $text -cmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$'
    ) "$Description.$Name must be an ISO-8601 instant with an explicit UTC offset"
    try {
        return [DateTimeOffset]::Parse(
            $text,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
    } catch {
        throw "GA required-check assertion failed: $Description.$Name must be a valid ISO-8601 instant"
    }
}

function Assert-GaRequiredUrl {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $value = Assert-GaRequiredString -Object $Object -Name $Name -Description $Description
    $uri = $null
    $valid = [Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri)
    Assert-GaRequiredCondition ($valid -and $uri.Scheme -ceq 'https' -and -not [string]::IsNullOrWhiteSpace($uri.Host)) "$Description.$Name must be an absolute HTTPS URL"
    Assert-GaRequiredCondition ([string]::IsNullOrEmpty($uri.UserInfo)) "$Description.$Name must not contain embedded credentials"
    Assert-GaRequiredCondition ([string]::IsNullOrEmpty($uri.Fragment)) "$Description.$Name must not contain a URL fragment"
    return $value
}

function Get-GaRequiredCheckNames {
    param([string[]]$Names)

    # Keep the result an array even when a caller supplies exactly one name;
    # Windows PowerShell otherwise unwraps the `if` output and StrictMode then
    # makes a scalar `.Count` access fail.
    $selected = @(if ($null -eq $Names -or $Names.Count -eq 0) {
            @($script:GaDefaultRequiredCheckNames)
        } else {
            @($Names)
        })

    Assert-GaRequiredCondition ($selected.Count -gt 0) 'required check contract must contain at least one check'
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $selected) {
        Assert-GaRequiredCondition ($name -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$name)) 'required check names must be non-empty strings'
        Assert-GaRequiredCondition ($seen.Add([string]$name)) "required check contract contains duplicate '$name'"
    }
    return $selected
}

function Read-GaRequiredJsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-GaRequiredCondition (-not [string]::IsNullOrWhiteSpace($Path)) "$Description path is required"
    Assert-GaRequiredCondition (Test-Path -LiteralPath $Path -PathType Leaf) "$Description does not exist: $Path"
    $item = Get-Item -LiteralPath $Path -Force
    Assert-GaRequiredCondition (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "$Description must not be a reparse point: $Path"
    Assert-GaRequiredCondition ($item.Length -le 64MB) "$Description exceeds the 64 MiB size limit: $Path"
    try {
        return [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    } catch {
        throw "$Description is not valid JSON: $($_.Exception.Message)"
    }
}

function Invoke-GaRequiredGhApi {
    param([Parameter(Mandatory = $true)][string]$Endpoint)

    $gh = Get-Command gh -ErrorAction SilentlyContinue
    Assert-GaRequiredCondition ($null -ne $gh) 'live validation requires the GitHub CLI (gh)'
    $output = @(& $gh.Source api --paginate --slurp --method GET $Endpoint 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "gh api failed for $Endpoint with exit code ${exitCode}: $($output -join ' ')"
    }
    $text = $output -join "`n"
    try {
        return $text | ConvertFrom-Json
    } catch {
        throw "gh api returned invalid JSON for ${Endpoint}: $($_.Exception.Message)"
    }
}

function Get-GaRequiredApiItems {
    param(
        [Parameter(Mandatory = $true)][object]$Document,
        [Parameter(Mandatory = $true)][string]$ItemProperty,
        [Parameter(Mandatory = $true)][string]$Description
    )

    # gh api --paginate --slurp returns one object for a single page and an
    # array of objects for multiple pages.  Accept exactly those two shapes;
    # accepting a raw item array would lose total_count/pagination evidence.
    # An if-expression unwraps a one-element array on Windows PowerShell.
    # The explicit array type keeps the page collection countable on PS5.1.
    [object[]]$pages = @($Document)
    Assert-GaRequiredCondition ($pages.Count -gt 0) "$Description must contain at least one API page"
    [long]$totalCount = 0
    $hasTotalCount = $false
    $items = [Collections.Generic.List[object]]::new()

    foreach ($page in $pages) {
        $total = Assert-GaRequiredInteger -Object $page -Name 'total_count' -Description $Description -Minimum 0
        if (-not $hasTotalCount) {
            $totalCount = $total
            $hasTotalCount = $true
        } else {
            Assert-GaRequiredCondition ($total -eq $totalCount) "$Description pages disagree on total_count"
        }
        $array = @(Get-GaRequiredProperty -Object $page -Name $ItemProperty -Description $Description)
        Assert-GaRequiredCondition ($array -is [Array]) "$Description.$ItemProperty must be a JSON array"
        foreach ($item in @($array)) {
            Assert-GaRequiredCondition ($null -ne $item -and $item -isnot [string]) "$Description.$ItemProperty entries must be JSON objects"
            [void]$items.Add($item)
        }
    }

    Assert-GaRequiredCondition $hasTotalCount "$Description total_count is missing"
    $seenIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in $items) {
        $id = Assert-GaRequiredInteger -Object $item -Name 'id' -Description $Description -Minimum 1
        Assert-GaRequiredCondition ($seenIds.Add([string]$id)) "$Description contains duplicate id '$id' across API pages"
    }
    Assert-GaRequiredCondition ($items.Count -eq $totalCount) "$Description pagination is incomplete: total_count=$totalCount, returned=$($items.Count)"
    return [pscustomobject]@{
        TotalCount = [long]$totalCount
        Items = @($items.ToArray())
    }
}

function Convert-GaRequiredWorkflowRun {
    param(
        [Parameter(Mandatory = $true)][object]$Run,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $created = Convert-GaRequiredInstant -Object $Run -Name 'created_at' -Description $Description
    $updated = Convert-GaRequiredInstant -Object $Run -Name 'updated_at' -Description $Description
    Assert-GaRequiredCondition ($updated -ge $created) "$Description.updated_at must not precede created_at"
    $conclusionProperty = $Run.PSObject.Properties['conclusion']
    Assert-GaRequiredCondition ($null -ne $conclusionProperty) "$Description is missing required property 'conclusion'"
    $conclusion = $conclusionProperty.Value
    if ($null -ne $conclusion) {
        Assert-GaRequiredCondition ($conclusion -is [string] -and $conclusion -cmatch '^[a-z_]+$') "$Description.conclusion must be a valid GitHub status string or null"
    }

    return [pscustomobject][ordered]@{
        id = Assert-GaRequiredInteger -Object $Run -Name 'id' -Description $Description -Minimum 1
        name = Assert-GaRequiredString -Object $Run -Name 'name' -Description $Description
        workflow_id = Assert-GaRequiredInteger -Object $Run -Name 'workflow_id' -Description $Description -Minimum 1
        head_branch = Assert-GaRequiredString -Object $Run -Name 'head_branch' -Description $Description
        head_sha = Assert-GaRequiredSha -Object $Run -Name 'head_sha' -Description $Description
        path = Assert-GaRequiredString -Object $Run -Name 'path' -Description $Description
        run_number = Assert-GaRequiredInteger -Object $Run -Name 'run_number' -Description $Description -Minimum 1
        run_attempt = Assert-GaRequiredInteger -Object $Run -Name 'run_attempt' -Description $Description -Minimum 1
        event = Assert-GaRequiredString -Object $Run -Name 'event' -Description $Description
        status = Assert-GaRequiredString -Object $Run -Name 'status' -Description $Description
        conclusion = if ($null -eq $conclusion) { $null } else { [string]$conclusion }
        created_at = $created.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
        updated_at = $updated.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
        created_ticks = $created.UtcTicks
        updated_ticks = $updated.UtcTicks
        html_url = Assert-GaRequiredUrl -Object $Run -Name 'html_url' -Description $Description
    }
}

function Convert-GaRequiredJob {
    param(
        [Parameter(Mandatory = $true)][object]$Job,
        [Parameter(Mandatory = $true)][long]$ExpectedRunId,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $started = Convert-GaRequiredInstant -Object $Job -Name 'started_at' -Description $Description
    $completed = Convert-GaRequiredInstant -Object $Job -Name 'completed_at' -Description $Description
    Assert-GaRequiredCondition ($completed -ge $started) "$Description.completed_at must not precede started_at"
    $runId = Assert-GaRequiredInteger -Object $Job -Name 'run_id' -Description $Description -Minimum 1
    Assert-GaRequiredCondition ($runId -eq $ExpectedRunId) "$Description.run_id must match the selected workflow run"
    $status = Assert-GaRequiredString -Object $Job -Name 'status' -Description $Description
    $conclusion = Assert-GaRequiredString -Object $Job -Name 'conclusion' -Description $Description
    Assert-GaRequiredCondition ($status -ceq 'completed') "$Description.status must be completed"
    Assert-GaRequiredCondition ($conclusion -ceq 'success') "$Description.conclusion must be success"
    $headSha = Assert-GaRequiredSha -Object $Job -Name 'head_sha' -Description $Description
    Assert-GaRequiredCondition ($headSha.Equals($ExpectedCommit, [StringComparison]::OrdinalIgnoreCase)) "$Description.head_sha must match the expected source commit"

    return [pscustomobject][ordered]@{
        id = Assert-GaRequiredInteger -Object $Job -Name 'id' -Description $Description -Minimum 1
        run_id = $runId
        name = Assert-GaRequiredString -Object $Job -Name 'name' -Description $Description
        head_sha = $headSha
        status = $status
        conclusion = $conclusion
        started_at = $started.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
        completed_at = $completed.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
        html_url = Assert-GaRequiredUrl -Object $Job -Name 'html_url' -Description $Description
    }
}

function Convert-GaRequiredCheckRun {
    param(
        [Parameter(Mandatory = $true)][object]$CheckRun,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $started = Convert-GaRequiredInstant -Object $CheckRun -Name 'started_at' -Description $Description
    $completedProperty = $CheckRun.PSObject.Properties['completed_at']
    Assert-GaRequiredCondition ($null -ne $completedProperty) "$Description is missing required property 'completed_at'"
    $completed = $null
    if ($null -ne $completedProperty.Value) {
        $completed = Convert-GaRequiredInstant -Object $CheckRun -Name 'completed_at' -Description $Description
        Assert-GaRequiredCondition ($completed -ge $started) "$Description.completed_at must not precede started_at"
    }
    $status = Assert-GaRequiredString -Object $CheckRun -Name 'status' -Description $Description
    Assert-GaRequiredCondition ($status -cmatch '^[a-z_]+$') "$Description.status must be a valid GitHub status string"
    $conclusionProperty = $CheckRun.PSObject.Properties['conclusion']
    Assert-GaRequiredCondition ($null -ne $conclusionProperty) "$Description is missing required property 'conclusion'"
    $conclusion = $conclusionProperty.Value
    if ($null -ne $conclusion) {
        Assert-GaRequiredCondition ($conclusion -is [string] -and $conclusion -cmatch '^[a-z_]+$') "$Description.conclusion must be a valid GitHub status string or null"
        $conclusion = [string]$conclusion
    }
    $headSha = Assert-GaRequiredSha -Object $CheckRun -Name 'head_sha' -Description $Description
    Assert-GaRequiredCondition ($headSha.Equals($ExpectedCommit, [StringComparison]::OrdinalIgnoreCase)) "$Description.head_sha must match the expected source commit"
    $app = Get-GaRequiredProperty -Object $CheckRun -Name 'app' -Description $Description
    $slug = Assert-GaRequiredString -Object $app -Name 'slug' -Description "$Description.app"

    $detailsUrl = Assert-GaRequiredUrl -Object $CheckRun -Name 'details_url' -Description $Description
    $jobMatch = [regex]::Match($detailsUrl, '/actions/runs/(?<run>[0-9]+)/job/(?<job>[0-9]+)$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    Assert-GaRequiredCondition ($jobMatch.Success) "$Description.details_url must identify a GitHub Actions workflow job"
    $jobRunId = [long]$jobMatch.Groups['run'].Value
    $jobId = [long]$jobMatch.Groups['job'].Value
    Assert-GaRequiredCondition ($jobRunId -gt 0 -and $jobId -gt 0) "$Description.details_url contains invalid workflow/job identifiers"

    return [pscustomobject][ordered]@{
        id = Assert-GaRequiredInteger -Object $CheckRun -Name 'id' -Description $Description -Minimum 1
        name = Assert-GaRequiredString -Object $CheckRun -Name 'name' -Description $Description
        head_sha = $headSha
        status = $status
        conclusion = $conclusion
        appSlug = $slug
        started_at = $started.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
        completed_at = if ($null -eq $completed) { $null } else { $completed.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture) }
        details_url = $detailsUrl
        workflow_run_id = $jobRunId
        job_id = $jobId
    }
}

function Get-GaRequiredCheckRunBinding {
    param(
        [Parameter(Mandatory = $true)][object]$CheckRun,
        [Parameter(Mandatory = $true)][string]$Description
    )

    # Parse the Actions run/job identity before validating completion fields.
    # A commit can legitimately contain unrelated checks that are still
    # running; those checks must be ignored after their URL is structurally
    # validated rather than making the selected CI proof fail on a null
    # completed_at value.
    $detailsUrl = Assert-GaRequiredUrl -Object $CheckRun -Name 'details_url' -Description $Description
    $match = [regex]::Match(
        $detailsUrl,
        '/actions/runs/(?<run>[0-9]+)/job/(?<job>[0-9]+)$',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    Assert-GaRequiredCondition ($match.Success) "$Description.details_url must identify a GitHub Actions workflow job"
    $runId = [long]$match.Groups['run'].Value
    $jobId = [long]$match.Groups['job'].Value
    Assert-GaRequiredCondition ($runId -gt 0 -and $jobId -gt 0) "$Description.details_url contains invalid workflow/job identifiers"
    return [pscustomobject]@{
        WorkflowRunId = $runId
        JobId = $jobId
    }
}

function Invoke-GaRequiredChecksFromDocuments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$RunListDocument,
        [Parameter(Mandatory = $true)][object]$JobsDocument,
        [Parameter(Mandatory = $true)][object]$CheckRunsDocument,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [string]$Repository = 'offline/local',
        [string]$WorkflowName = $script:GaRequiredCheckWorkflowName,
        [string]$WorkflowPath = $script:GaRequiredCheckWorkflowPath,
        [string]$Branch = $script:GaRequiredCheckBranch,
        [string]$Event = $script:GaRequiredCheckEvent,
        [string[]]$RequiredCheckNames = $null
    )

    Assert-GaRequiredCondition ($ExpectedCommit -cmatch '^[0-9a-fA-F]{40}$') 'ExpectedCommit must be a full 40-character commit SHA'
    Assert-GaRequiredCondition (-not [string]::IsNullOrWhiteSpace($Repository)) 'Repository must be non-empty'
    Assert-GaRequiredCondition (-not [string]::IsNullOrWhiteSpace($WorkflowName)) 'WorkflowName must be non-empty'
    Assert-GaRequiredCondition (-not [string]::IsNullOrWhiteSpace($WorkflowPath)) 'WorkflowPath must be non-empty'
    Assert-GaRequiredCondition (-not [string]::IsNullOrWhiteSpace($Branch)) 'Branch must be non-empty'
    Assert-GaRequiredCondition (-not [string]::IsNullOrWhiteSpace($Event)) 'Event must be non-empty'
    # A PowerShell function unwraps a one-element array on return.  Keep the
    # contract as an array at every call site so PS5.1 does not lose Count or
    # array semantics when a caller supplies exactly one required check.
    $requiredNames = @(Get-GaRequiredCheckNames -Names $RequiredCheckNames)

    $runPage = Get-GaRequiredApiItems -Document $RunListDocument -ItemProperty 'workflow_runs' -Description 'workflow run list'
    $runs = [Collections.Generic.List[object]]::new()
    $runIndex = 0
    foreach ($runItem in $runPage.Items) {
        $run = Convert-GaRequiredWorkflowRun -Run $runItem -Description "workflow run $runIndex"
        Assert-GaRequiredCondition ($run.name -ceq $WorkflowName) "workflow run $($run.id) has unexpected workflow name '$($run.name)'"
        Assert-GaRequiredCondition ($run.path -ceq $WorkflowPath) "workflow run $($run.id) has unexpected workflow path '$($run.path)'"
        Assert-GaRequiredCondition ($run.head_branch -ceq $Branch) "workflow run $($run.id) is not on branch '$Branch'"
        Assert-GaRequiredCondition ($run.event -ceq $Event) "workflow run $($run.id) is not a '$Event' run"
        [void]$runs.Add($run)
        $runIndex++
    }

    $matchingRuns = @($runs | Where-Object {
            $_.head_sha.Equals($ExpectedCommit, [StringComparison]::OrdinalIgnoreCase)
        })
    Assert-GaRequiredCondition ($matchingRuns.Count -gt 0) "no $WorkflowName run is bound to source commit $ExpectedCommit"
    $latestRun = @(
        $matchingRuns | Sort-Object `
            @{ Expression = 'run_number'; Descending = $true }, `
            @{ Expression = 'run_attempt'; Descending = $true }, `
            @{ Expression = 'updated_ticks'; Descending = $true }, `
            @{ Expression = 'id'; Descending = $true }
    )[0]
    Assert-GaRequiredCondition ($latestRun.status -ceq 'completed') "latest CI run $($latestRun.id) for $ExpectedCommit is not completed (status='$($latestRun.status)')"
    Assert-GaRequiredCondition ($latestRun.conclusion -ceq 'success') "latest CI run $($latestRun.id) for $ExpectedCommit did not pass (conclusion='$($latestRun.conclusion)')"

    $jobPage = Get-GaRequiredApiItems -Document $JobsDocument -ItemProperty 'jobs' -Description "jobs for workflow run $($latestRun.id)"
    $jobs = [Collections.Generic.List[object]]::new()
    foreach ($jobItem in $jobPage.Items) {
        $job = Convert-GaRequiredJob -Job $jobItem -ExpectedRunId $latestRun.id -ExpectedCommit $ExpectedCommit -Description "workflow run $($latestRun.id) job"
        [void]$jobs.Add($job)
    }
    $jobNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $jobIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($job in $jobs) {
        Assert-GaRequiredCondition ($jobNames.Add($job.name)) "workflow run $($latestRun.id) contains duplicate job name '$($job.name)'"
        Assert-GaRequiredCondition ($jobIds.Add([string]$job.id)) "workflow run $($latestRun.id) contains duplicate job id '$($job.id)'"
    }
    $missingJobs = @($requiredNames | Where-Object { -not $jobNames.Contains($_) })
    $unexpectedJobs = @($jobs | Where-Object { $_.name -notin $requiredNames })
    Assert-GaRequiredCondition ($missingJobs.Count -eq 0) "workflow run $($latestRun.id) is missing required jobs: $($missingJobs -join ', ')"
    Assert-GaRequiredCondition ($unexpectedJobs.Count -eq 0 -and $jobs.Count -eq $requiredNames.Count) "workflow run $($latestRun.id) has an unexpected job set (observed=$($jobs.Count), required=$($requiredNames.Count))"

    $checkPage = Get-GaRequiredApiItems -Document $CheckRunsDocument -ItemProperty 'check_runs' -Description "check runs for source commit $ExpectedCommit"
    $checks = [Collections.Generic.List[object]]::new()
    foreach ($checkItem in $checkPage.Items) {
        $binding = Get-GaRequiredCheckRunBinding -CheckRun $checkItem -Description 'source check run'
        if ($binding.WorkflowRunId -ne $latestRun.id) {
            continue
        }
        $check = Convert-GaRequiredCheckRun -CheckRun $checkItem -ExpectedCommit $ExpectedCommit -Description 'source check run'
        [void]$checks.Add($check)
    }
    $selectedChecks = @($checks | Where-Object { $_.workflow_run_id -eq $latestRun.id })
    $selectedNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $selectedIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($check in $selectedChecks) {
        Assert-GaRequiredCondition ($selectedNames.Add($check.name)) "workflow run $($latestRun.id) contains duplicate check-run name '$($check.name)'"
        Assert-GaRequiredCondition ($selectedIds.Add([string]$check.id)) "workflow run $($latestRun.id) contains duplicate check-run id '$($check.id)'"
        Assert-GaRequiredCondition ($check.status -ceq 'completed') "required check '$($check.name)' in workflow run $($latestRun.id) is not completed"
        Assert-GaRequiredCondition ($check.conclusion -ceq 'success') "required check '$($check.name)' in workflow run $($latestRun.id) did not pass"
        Assert-GaRequiredCondition ($check.appSlug -ceq 'github-actions') "required check '$($check.name)' in workflow run $($latestRun.id) is not produced by GitHub Actions"
        Assert-GaRequiredCondition ($null -ne $check.completed_at) "required check '$($check.name)' in workflow run $($latestRun.id) has no completion timestamp"
        Assert-GaRequiredCondition ($jobIds.Contains([string]$check.job_id)) "check run '$($check.name)' does not bind to a job in workflow run $($latestRun.id)"
    }
    $missingChecks = @($requiredNames | Where-Object { -not $selectedNames.Contains($_) })
    $unexpectedChecks = @($selectedChecks | Where-Object { $_.name -notin $requiredNames })
    Assert-GaRequiredCondition ($missingChecks.Count -eq 0) "workflow run $($latestRun.id) is missing required check-runs: $($missingChecks -join ', ')"
    Assert-GaRequiredCondition ($unexpectedChecks.Count -eq 0 -and $selectedChecks.Count -eq $requiredNames.Count) "workflow run $($latestRun.id) has an unexpected check-run set (observed=$($selectedChecks.Count), required=$($requiredNames.Count))"

    $checkByName = @{}
    foreach ($check in $selectedChecks) { $checkByName[$check.name] = $check }
    $proofChecks = @(
        foreach ($name in $requiredNames) {
            $check = $checkByName[$name]
            [ordered]@{
                name = $name
                checkRunId = [long]$check.id
                jobId = [long]$check.job_id
                status = $check.status
                conclusion = $check.conclusion
                headSha = $check.head_sha
                detailsUrl = $check.details_url
                startedAt = $check.started_at
                completedAt = $check.completed_at
            }
        }
    )

    return [ordered]@{
        schemaVersion = $script:GaRequiredChecksSchema
        status = 'passed'
        repository = $Repository
        sourceCommit = $ExpectedCommit.ToLowerInvariant()
        workflow = [ordered]@{
            name = $latestRun.name
            path = $latestRun.path
            branch = $latestRun.head_branch
            event = $latestRun.event
            runId = [long]$latestRun.id
            runNumber = [long]$latestRun.run_number
            runAttempt = [long]$latestRun.run_attempt
            headSha = $latestRun.head_sha.ToLowerInvariant()
            status = $latestRun.status
            conclusion = $latestRun.conclusion
            createdAt = $latestRun.created_at
            updatedAt = $latestRun.updated_at
            url = $latestRun.html_url
        }
        requiredChecks = @($proofChecks)
        counts = [ordered]@{
            required = $requiredNames.Count
            observedJobs = $jobs.Count
            observedCheckRunsForSelectedRun = $selectedChecks.Count
            passed = $proofChecks.Count
        }
        checkedAt = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
    }
}

function Invoke-GaRequiredChecks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [string]$Repository = '',
        [string]$Workflow = 'ci.yml',
        [string]$WorkflowName = $script:GaRequiredCheckWorkflowName,
        [string]$WorkflowPath = $script:GaRequiredCheckWorkflowPath,
        [string]$Branch = $script:GaRequiredCheckBranch,
        [string]$Event = $script:GaRequiredCheckEvent,
        [string]$RunListPath = '',
        [string]$JobsPath = '',
        [string]$CheckRunsPath = '',
        [string[]]$RequiredCheckNames = $null
    )

    # Offline provenance contract: RunListPath, JobsPath, and CheckRunsPath
    # are the three raw GitHub REST list responses captured with
    # `gh api --paginate --slurp`.  Each file is either one REST envelope or
    # the array of page envelopes produced by --slurp; a pre-built proof/report
    # object is intentionally not accepted.  All three files are required as
    # one set so the selected run, its jobs, and commit check-runs cannot be
    # mixed from separate provenance captures.
    #
    # Live mode binds the same documents to these endpoints:
    #   actions/workflows/{Workflow}/runs?branch={Branch}&event={Event}&head_sha={ExpectedCommit}
    #   actions/runs/{selectedRunId}/jobs
    #   commits/{ExpectedCommit}/check-runs

    if ([string]::IsNullOrWhiteSpace($Repository)) {
        $Repository = [string]$env:GITHUB_REPOSITORY
    }
    if ([string]::IsNullOrWhiteSpace($Repository)) {
        $Repository = 'offline/local'
    }
    # Validate the commit before constructing any live REST route.  The SHA is
    # interpolated into the endpoint, so accepting arbitrary text here would
    # turn a proof helper into a query/path injection surface even though the
    # document pipeline rejects it later.
    Assert-GaRequiredCondition ($ExpectedCommit -cmatch '^[0-9a-fA-F]{40}$') 'ExpectedCommit must be a full 40-character commit SHA'
    $pathArguments = @($RunListPath, $JobsPath, $CheckRunsPath)
    $offlineCount = @($pathArguments | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count
    Assert-GaRequiredCondition ($offlineCount -eq 0 -or $offlineCount -eq 3) 'RunListPath, JobsPath, and CheckRunsPath must be supplied together'

    if ($offlineCount -eq 3) {
        $runDocument = Read-GaRequiredJsonFile -Path $RunListPath -Description 'workflow run list'
        $jobsDocument = Read-GaRequiredJsonFile -Path $JobsPath -Description 'workflow jobs'
        $checkRunsDocument = Read-GaRequiredJsonFile -Path $CheckRunsPath -Description 'workflow check runs'
    } else {
        Assert-GaRequiredCondition ($Repository -match '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') "Repository must be owner/name (observed '$Repository')"
        Assert-GaRequiredCondition ($Workflow -match '^[A-Za-z0-9_.-]+$') "Workflow must be a workflow filename or numeric id (observed '$Workflow')"
        Assert-GaRequiredCondition ($Branch -notmatch '[\r\n]') 'Branch must not contain line breaks'
        $encodedBranch = [Uri]::EscapeDataString($Branch)
        $encodedEvent = [Uri]::EscapeDataString($Event)
        $runEndpoint = "repos/$Repository/actions/workflows/$Workflow/runs?branch=$encodedBranch&event=$encodedEvent&head_sha=$ExpectedCommit&per_page=100"
        $runDocument = Invoke-GaRequiredGhApi -Endpoint $runEndpoint
        $runPage = Get-GaRequiredApiItems -Document $runDocument -ItemProperty 'workflow_runs' -Description 'workflow run list'
        Assert-GaRequiredCondition ($runPage.Items.Count -gt 0) "GitHub returned no workflow runs for source commit $ExpectedCommit"
        # Select the run before making the dependent API requests.  The same
        # strict selector is intentionally repeated in the document pipeline.
        $candidateRuns = @($runPage.Items | ForEach-Object { Convert-GaRequiredWorkflowRun -Run $_ -Description 'workflow run' } | Where-Object {
                $_.name -ceq $WorkflowName -and $_.path -ceq $WorkflowPath -and $_.head_branch -ceq $Branch -and $_.event -ceq $Event -and $_.head_sha.Equals($ExpectedCommit, [StringComparison]::OrdinalIgnoreCase)
            })
        Assert-GaRequiredCondition ($candidateRuns.Count -gt 0) "GitHub returned no matching $WorkflowName run for source commit $ExpectedCommit"
        $selectedRun = @(
            $candidateRuns | Sort-Object `
                @{ Expression = 'run_number'; Descending = $true }, `
                @{ Expression = 'run_attempt'; Descending = $true }, `
                @{ Expression = 'updated_ticks'; Descending = $true }, `
                @{ Expression = 'id'; Descending = $true }
        )[0]
        $jobsEndpoint = "repos/$Repository/actions/runs/$($selectedRun.id)/jobs?per_page=100"
        $checkRunsEndpoint = "repos/$Repository/commits/$ExpectedCommit/check-runs?per_page=100"
        $jobsDocument = Invoke-GaRequiredGhApi -Endpoint $jobsEndpoint
        $checkRunsDocument = Invoke-GaRequiredGhApi -Endpoint $checkRunsEndpoint
    }

    return Invoke-GaRequiredChecksFromDocuments `
        -RunListDocument $runDocument `
        -JobsDocument $jobsDocument `
        -CheckRunsDocument $checkRunsDocument `
        -ExpectedCommit $ExpectedCommit `
        -Repository $Repository `
        -WorkflowName $WorkflowName `
        -WorkflowPath $WorkflowPath `
        -Branch $Branch `
        -Event $Event `
        -RequiredCheckNames $RequiredCheckNames
}

if (-not $ContractOnly) {
    $report = Invoke-GaRequiredChecks `
        -ExpectedCommit $(if ([string]::IsNullOrWhiteSpace($ExpectedCommit)) { [string]$env:CYC_GA_SOURCE_COMMIT } else { $ExpectedCommit }) `
        -Repository $Repository `
        -Workflow $Workflow `
        -WorkflowName $WorkflowName `
        -WorkflowPath $WorkflowPath `
        -Branch $Branch `
        -Event $Event `
        -RunListPath $RunListPath `
        -JobsPath $JobsPath `
        -CheckRunsPath $CheckRunsPath `
        -RequiredCheckNames $RequiredCheckNames

    if ($Json) {
        $report | ConvertTo-Json -Depth 20 -Compress
    } else {
        Write-Output (
            'GA required checks passed: workflow run {0} ({1}) at source {2}; {3} checks verified.' -f
            $report.workflow.runId,
            $report.workflow.url,
            $report.sourceCommit,
            $report.counts.passed
        )
    }
}
