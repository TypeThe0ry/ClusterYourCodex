#requires -Version 5.1
$bootstrapPath = Join-Path $PSScriptRoot 'bootstrap.ps1'

Describe 'Windows payload staging paths' {
    It 'installs a valid long target path without extending its filename past MAX_PATH' {
        . $bootstrapPath
        $source = Join-Path $TestDrive 'source.txt'
        [IO.File]::WriteAllText($source, 'verified payload')
        $testRoot = (Get-Item TestDrive:\).FullName
        $parent = Join-Path $testRoot ('p' * (180 - $testRoot.Length - 1))
        $target = Join-Path $parent (('f' * 56) + '.map')
        $target.Length | Should BeLessThan 260
        ($target.Length + 45) | Should BeGreaterThan 259
        $hash = (Get-CycFileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
        Install-PlannedFiles -Plan ([pscustomobject]@{files = @(
            [pscustomobject]@{sourcePath=$source; targetPath=$target; sha256=$hash; relativePath='long-payload.map'}
        )})
        [IO.File]::ReadAllText($target) | Should Be 'verified payload'
        @(Get-ChildItem -LiteralPath $parent -Force).Count | Should Be 1
    }

    It 'retains the installed file when source integrity validation fails' {
        . $bootstrapPath
        $source = Join-Path $TestDrive 'changed.txt'
        $target = Join-Path $TestDrive 'installed.txt'
        [IO.File]::WriteAllText($source, 'unexpected payload')
        [IO.File]::WriteAllText($target, 'previous payload')
        $plan = [pscustomobject]@{files = @(
            [pscustomobject]@{sourcePath=$source; targetPath=$target; sha256=('0' * 64); relativePath='changed.txt'}
        )}
        { Install-PlannedFiles -Plan $plan } | Should Throw
        [IO.File]::ReadAllText($target) | Should Be 'previous payload'
    }
}
