#requires -Version 5.1

$testRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptPath = Join-Path $testRoot 'Test-GARequiredChecks.ps1'

$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors
) | Out-Null
if (@($parseErrors).Count -ne 0) {
    throw ('Test-GARequiredChecks.ps1 is not parseable: ' + (@($parseErrors | ForEach-Object { $_.Message }) -join '; '))
}

# ContractOnly imports the functions without making live GitHub API calls.
. $scriptPath -ContractOnly

$testCommit = ('a' * 40)
$testRepository = 'TypeThe0ry/ClusterYourCodex'
$testRunId = 2001
$testWorkflowId = 339880591
$testNames = @(
    'check-one',
    'check-two',
    'check-three'
)

function Convert-TestGaObject {
    param([Parameter(Mandatory = $true)][object]$Value)

    # Round-trip through JSON so the fixture follows the same DateTime
    # materialization behavior as ConvertFrom-Json on PowerShell 5.1/7.
    return (($Value | ConvertTo-Json -Depth 30) | ConvertFrom-Json)
}

function New-TestGaRun {
    param(
        [Parameter(Mandatory = $true)][long]$Id,
        [Parameter(Mandatory = $true)][long]$RunNumber,
        [string]$Status = 'completed',
        [AllowNull()][object]$Conclusion = 'success',
        [string]$HeadSha = $testCommit,
        [string]$CreatedAt = '2026-09-05T00:00:00Z',
        [string]$UpdatedAt = '2026-09-05T00:10:00Z'
    )

    return [ordered]@{
        id = $Id
        name = 'CI'
        workflow_id = $testWorkflowId
        head_branch = 'main'
        head_sha = $HeadSha
        path = '.github/workflows/ci.yml'
        run_number = $RunNumber
        run_attempt = 1
        event = 'push'
        status = $Status
        conclusion = $Conclusion
        created_at = $CreatedAt
        updated_at = $UpdatedAt
        html_url = "https://github.com/$testRepository/actions/runs/$Id"
    }
}

function New-TestGaJob {
    param(
        [Parameter(Mandatory = $true)][long]$Id,
        [Parameter(Mandatory = $true)][string]$Name,
        [long]$RunId = $testRunId,
        [string]$HeadSha = $testCommit,
        [string]$Status = 'completed',
        [string]$Conclusion = 'success'
    )

    return [ordered]@{
        id = $Id
        run_id = $RunId
        name = $Name
        head_sha = $HeadSha
        status = $Status
        conclusion = $Conclusion
        started_at = '2026-09-05T00:01:00Z'
        completed_at = '2026-09-05T00:02:00Z'
        html_url = "https://github.com/$testRepository/actions/runs/$RunId/job/$Id"
    }
}

function New-TestGaCheckRun {
    param(
        [Parameter(Mandatory = $true)][long]$Id,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][long]$JobId,
        [long]$RunId = $testRunId,
        [string]$HeadSha = $testCommit,
        [string]$Status = 'completed',
        [AllowNull()][object]$Conclusion = 'success',
        [AllowNull()][object]$CompletedAt = '2026-09-05T00:02:00Z'
    )

    return [ordered]@{
        id = $Id
        name = $Name
        head_sha = $HeadSha
        status = $Status
        conclusion = $Conclusion
        started_at = '2026-09-05T00:01:00Z'
        completed_at = $CompletedAt
        details_url = "https://github.com/$testRepository/actions/runs/$RunId/job/$JobId"
        app = [ordered]@{ slug = 'github-actions' }
    }
}

function Assert-TestGaThrows {
    param([Parameter(Mandatory = $true)][ScriptBlock]$ScriptBlock)

    # Pester 3.4's Should Throw assertion is unreliable when that legacy
    # module is loaded in PowerShell 7.  Explicitly invoke/catch instead so
    # the negative contract tests behave identically on PS5.1 and pwsh.
    $threw = $false
    try {
        & $ScriptBlock | Out-Null
    } catch {
        $threw = $true
    }
    $threw | Should Be $true
}

function New-TestGaDocuments {
    param(
        [string[]]$Names = $testNames,
        [switch]$IncludeOlderRun,
        [switch]$IncludeUnrelatedInProgressCheck
    )

    $jobs = [Collections.Generic.List[object]]::new()
    $checks = [Collections.Generic.List[object]]::new()
    $jobId = 3000
    $checkId = 4000
    foreach ($name in $Names) {
        [void]$jobs.Add((New-TestGaJob -Id $jobId -Name $name))
        [void]$checks.Add((New-TestGaCheckRun -Id $checkId -Name $name -JobId $jobId))
        $jobId++
        $checkId++
    }

    $runs = [Collections.Generic.List[object]]::new()
    [void]$runs.Add((New-TestGaRun -Id $testRunId -RunNumber 20))
    if ($IncludeOlderRun) {
        [void]$runs.Add((New-TestGaRun -Id 2000 -RunNumber 19 -CreatedAt '2026-09-04T00:00:00Z' -UpdatedAt '2026-09-04T00:10:00Z'))
    }
    if ($IncludeUnrelatedInProgressCheck) {
        [void]$checks.Add((New-TestGaCheckRun -Id 4999 -Name 'unrelated preview check' -JobId 4998 -RunId 2999 -Status 'in_progress' -Conclusion $null -CompletedAt $null))
    }

    return [ordered]@{
        Runs = Convert-TestGaObject ([ordered]@{
                total_count = $runs.Count
                workflow_runs = @($runs.ToArray())
            })
        Jobs = Convert-TestGaObject ([ordered]@{
                total_count = $jobs.Count
                jobs = @($jobs.ToArray())
            })
        Checks = Convert-TestGaObject ([ordered]@{
                total_count = $checks.Count
                check_runs = @($checks.ToArray())
            })
    }
}

function Invoke-TestGaProof {
    param(
        [Parameter(Mandatory = $true)][object]$Documents,
        [string[]]$Names = $testNames
    )

    return Invoke-GaRequiredChecksFromDocuments `
        -RunListDocument $Documents.Runs `
        -JobsDocument $Documents.Jobs `
        -CheckRunsDocument $Documents.Checks `
        -ExpectedCommit $testCommit `
        -Repository $testRepository `
        -RequiredCheckNames $Names
}

Describe 'GA exact-source required-check proof' {
    It 'is parseable on the host and exposes the reviewed ten-check default contract' {
        @($parseErrors).Count | Should Be 0
        $names = @(Get-GaRequiredCheckNames)
        $names.Count | Should Be 10
        $names[0] | Should Be 'Product version identity'
        $names[9] | Should Be 'Desktop, Windows host, and Codex bridge'

        $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
        if ($null -eq $pwsh) { $pwsh = Get-Command powershell -ErrorAction Stop }
        & $pwsh.Source -NoLogo -NoProfile -NonInteractive -File $scriptPath -ContractOnly | Out-Null
        $LASTEXITCODE | Should Be 0
    }

    It 'accepts complete exact-source run, job, and check-run evidence' {
        $documents = New-TestGaDocuments
        $result = Invoke-TestGaProof -Documents $documents
        $result.status | Should Be 'passed'
        $result.sourceCommit | Should Be $testCommit
        $result.workflow.runId | Should Be $testRunId
        $result.counts.required | Should Be 3
        $result.counts.observedJobs | Should Be 3
        $result.counts.observedCheckRunsForSelectedRun | Should Be 3
        $result.counts.passed | Should Be 3
        @($result.requiredChecks).Count | Should Be 3
    }

    It 'accepts an unrelated in-progress check without treating it as the selected CI run' {
        $documents = New-TestGaDocuments -IncludeUnrelatedInProgressCheck
        $result = Invoke-TestGaProof -Documents $documents
        $result.status | Should Be 'passed'
        $result.workflow.runId | Should Be $testRunId
    }

    It 'keeps a one-check override as an array on Windows PowerShell 5.1' {
        $oneName = @('only-check')
        $documents = New-TestGaDocuments -Names $oneName
        $result = Invoke-TestGaProof -Documents $documents -Names $oneName
        $result.status | Should Be 'passed'
        $result.counts.required | Should Be 1
        $result.counts.observedJobs | Should Be 1
        $result.counts.observedCheckRunsForSelectedRun | Should Be 1
        @($result.requiredChecks).Count | Should Be 1
        $result.requiredChecks[0].name | Should Be 'only-check'
    }

    It 'emits the v1 proof schema and requires REST list envelopes' {
        $documents = New-TestGaDocuments
        $result = Invoke-TestGaProof -Documents $documents
        $result.schemaVersion | Should Be 'cyc.dev/ga-required-checks/v1'
        $result.status | Should Be 'passed'
        foreach ($key in @('repository', 'sourceCommit', 'workflow', 'requiredChecks', 'counts', 'checkedAt')) {
            ($result.Contains($key)) | Should Be $true
        }
        @($result.Keys).Count | Should Be 8

        $documents = New-TestGaDocuments
        $documents.Runs = Convert-TestGaObject ([ordered]@{ workflow_runs = @($documents.Runs.workflow_runs) })
        Assert-TestGaThrows { Invoke-TestGaProof -Documents $documents }

        $documents = New-TestGaDocuments
        $documents.Jobs = @($documents.Jobs.jobs)
        Assert-TestGaThrows { Invoke-TestGaProof -Documents $documents }
    }

    It 'rejects a newer failed run instead of falling back to an older successful run' {
        $documents = New-TestGaDocuments -IncludeOlderRun
        $newerFailed = New-TestGaRun -Id 2010 -RunNumber 21 -Status 'completed' -Conclusion 'failure' -CreatedAt '2026-09-05T01:00:00Z' -UpdatedAt '2026-09-05T01:10:00Z'
        $runs = @($documents.Runs.workflow_runs) + @((Convert-TestGaObject $newerFailed))
        $documents.Runs = Convert-TestGaObject ([ordered]@{ total_count = $runs.Count; workflow_runs = $runs })
        Assert-TestGaThrows { Invoke-TestGaProof -Documents $documents }
    }

    It 'rejects a job whose head SHA is not the reviewed source commit' {
        $documents = New-TestGaDocuments
        $documents.Jobs.jobs[0].head_sha = ('b' * 40)
        Assert-TestGaThrows { Invoke-TestGaProof -Documents $documents }
    }

    It 'rejects missing or unexpected job names rather than accepting a partial set' {
        $documents = New-TestGaDocuments
        $documents.Jobs.jobs = @($documents.Jobs.jobs | Where-Object { $_.name -ne 'check-two' })
        $documents.Jobs.total_count = 2
        Assert-TestGaThrows { Invoke-TestGaProof -Documents $documents }

        $documents = New-TestGaDocuments
        $extraJob = New-TestGaJob -Id 3999 -Name 'unreviewed job'
        $documents.Jobs.jobs = @($documents.Jobs.jobs) + @((Convert-TestGaObject $extraJob))
        $documents.Jobs.total_count = 4
        Assert-TestGaThrows { Invoke-TestGaProof -Documents $documents }
    }

    It 'rejects duplicate check names and a check URL bound to another run' {
        $documents = New-TestGaDocuments
        $documents.Checks.check_runs[1].name = $documents.Checks.check_runs[0].name
        Assert-TestGaThrows { Invoke-TestGaProof -Documents $documents }

        $documents = New-TestGaDocuments
        $documents.Checks.check_runs[0].details_url = 'https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/9999/job/3000'
        Assert-TestGaThrows { Invoke-TestGaProof -Documents $documents }
    }

    It 'rejects incomplete or duplicate API pagination' {
        $documents = New-TestGaDocuments -IncludeOlderRun
        $pages = @(
            (Convert-TestGaObject ([ordered]@{ total_count = 2; workflow_runs = @($documents.Runs.workflow_runs[0]) })),
            (Convert-TestGaObject ([ordered]@{ total_count = 2; workflow_runs = @($documents.Runs.workflow_runs[1]) }))
        )
        $documents.Runs = $pages
        $result = Invoke-TestGaProof -Documents $documents
        $result.workflow.runId | Should Be $testRunId

        $documents = New-TestGaDocuments -IncludeOlderRun
        $documents.Runs = @((Convert-TestGaObject ([ordered]@{ total_count = 2; workflow_runs = @($documents.Runs.workflow_runs[0]) })))
        Assert-TestGaThrows { Invoke-TestGaProof -Documents $documents }

        $documents = New-TestGaDocuments -IncludeOlderRun
        $duplicatePage = Convert-TestGaObject ([ordered]@{ total_count = 2; workflow_runs = @($documents.Runs.workflow_runs[0]) })
        $documents.Runs = @($duplicatePage, $duplicatePage)
        Assert-TestGaThrows { Invoke-TestGaProof -Documents $documents }
    }

    It 'rejects non-HTTPS, credential-bearing, or fragment-bearing evidence URLs' {
        $documents = New-TestGaDocuments
        $documents.Jobs.jobs[0].html_url = 'https://user:password@github.com/TypeThe0ry/ClusterYourCodex/actions/runs/2001/job/3000#log'
        Assert-TestGaThrows { Invoke-TestGaProof -Documents $documents }

        $documents = New-TestGaDocuments
        $documents.Checks.check_runs[0].details_url = 'http://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/2001/job/3000'
        Assert-TestGaThrows { Invoke-TestGaProof -Documents $documents }
    }

    It 'runs through the offline CLI file interface and returns a JSON proof' {
        $documents = New-TestGaDocuments -Names (Get-GaRequiredCheckNames)
        $tempDirectory = Join-Path ([IO.Path]::GetTempPath()) ('cyc-ga-required-checks-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempDirectory -Force | Out-Null
        try {
            $runPath = Join-Path $tempDirectory 'runs.json'
            $jobsPath = Join-Path $tempDirectory 'jobs.json'
            $checksPath = Join-Path $tempDirectory 'checks.json'
            ($documents.Runs | ConvertTo-Json -Depth 30) | Set-Content -LiteralPath $runPath -Encoding UTF8
            ($documents.Jobs | ConvertTo-Json -Depth 30) | Set-Content -LiteralPath $jobsPath -Encoding UTF8
            ($documents.Checks | ConvertTo-Json -Depth 30) | Set-Content -LiteralPath $checksPath -Encoding UTF8

            $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
            if ($null -eq $pwsh) { $pwsh = Get-Command powershell -ErrorAction Stop }
            $output = @(& $pwsh.Source -NoLogo -NoProfile -NonInteractive -File $scriptPath `
                -Repository $testRepository `
                -ExpectedCommit $testCommit `
                -RunListPath $runPath `
                -JobsPath $jobsPath `
                -CheckRunsPath $checksPath `
                -Json)
            $LASTEXITCODE | Should Be 0
            $result = ($output -join "`n") | ConvertFrom-Json
            $result.status | Should Be 'passed'
            $result.counts.required | Should Be 10
            $result.workflow.runId | Should Be $testRunId
        } finally {
            if (Test-Path -LiteralPath $tempDirectory) {
                Remove-Item -LiteralPath $tempDirectory -Recurse -Force
            }
        }
    }

    It 'requires all three offline API documents as one provenance set' {
        Assert-TestGaThrows { Invoke-GaRequiredChecks -ExpectedCommit $testCommit -RunListPath 'missing-runs.json' }
    }

    It 'rejects unsafe live API route selectors before invoking gh' {
        Assert-TestGaThrows {
            Invoke-GaRequiredChecks -ExpectedCommit $testCommit -Repository 'TypeThe0ry/ClusterYourCodex?redirect=1'
        }
        Assert-TestGaThrows {
            Invoke-GaRequiredChecks -ExpectedCommit $testCommit -Repository $testRepository -Workflow 'ci.yml?head_sha=other'
        }
        Assert-TestGaThrows {
            Invoke-GaRequiredChecks -ExpectedCommit ($testCommit + '?head_sha=other') -Repository $testRepository
        }
    }
}
