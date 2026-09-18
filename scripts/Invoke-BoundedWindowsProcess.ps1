[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string[]]$ArgumentList = @(),
    [ValidateRange(1, 3600)][int]$TimeoutSeconds = 30,
    [string]$WorkingDirectory = (Get-Location).Path,
    [string]$EvidenceRoot = $env:RUNNER_TEMP
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$resolvedFile = (Resolve-Path -LiteralPath $FilePath -ErrorAction Stop).Path
$resolvedWork = (Resolve-Path -LiteralPath $WorkingDirectory -ErrorAction Stop).Path
$evidence = if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) { $resolvedWork } else { $EvidenceRoot }
New-Item -ItemType Directory -Path $evidence -Force | Out-Null
$suffix = [Guid]::NewGuid().ToString('N')
$stdoutPath = Join-Path $evidence "bounded-$suffix.stdout.log"
$stderrPath = Join-Path $evidence "bounded-$suffix.stderr.log"
$process = $null
try {
$argumentString = ($ArgumentList -join ' ')
$process = Start-Process -FilePath $resolvedFile -ArgumentList $argumentString `
        -WorkingDirectory $resolvedWork -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
        $killExit = 1
        if (Test-Path -LiteralPath $taskkill -PathType Leaf) {
            & $taskkill /PID $process.Id /T /F *> $null
            $killExit = $LASTEXITCODE
        }
        try { [void]$process.WaitForExit(30000) } catch { }
        $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw } else { '' }
        $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
        throw "bounded process timed out after $TimeoutSeconds seconds (pid=$($process.Id), taskkillExit=$killExit). stdout=$stdout stderr=$stderr"
    }
    $process.Refresh()
    $exitCode = [int]$process.ExitCode
    if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw }
    if (Test-Path -LiteralPath $stderrPath) { $err = Get-Content -LiteralPath $stderrPath -Raw; if ($err) { [Console]::Error.Write($err) } }
    if ($exitCode -ne 0) { throw "$resolvedFile exited with code $exitCode" }
} finally {
    if ($null -ne $process) { $process.Dispose() }
}
