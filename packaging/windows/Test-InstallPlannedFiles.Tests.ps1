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

    It 'snapshots and restores long relative paths without exceeding MAX_PATH' {
        . $bootstrapPath
        $installRoot = Join-Path $TestDrive 'rollback-install'
        $dataRoot = Join-Path $TestDrive 'rollback-data'
        $manifestPath = Join-Path $dataRoot 'install-manifest.json'
        $segments = @(
            'segment-012345678901234567890',
            'segment-abcdefghijklmnopqrstuvwxyz',
            'segment-012345678901234567890',
            'segment-abcdefghijklmnopqrstuvwxyz',
            'segment-012345678901234567890'
        )
        $relative = ($segments -join '\') + '\payload.bin'
        while ((Join-Path $installRoot $relative).Length -ge 250) {
            if ($segments.Count -le 2) { throw 'Unable to construct a MAX_PATH-safe rollback fixture' }
            $segments = @($segments[0..($segments.Count - 2)])
            $relative = ($segments -join '\') + '\payload.bin'
        }
        $target = Join-Path $installRoot $relative
        $target.Length | Should BeLessThan 260
        $transactionPrefixLength = (Join-Path (Join-Path $dataRoot '.installer\transactions') ('0' * 32)).Length
        (($transactionPrefixLength + 8 + $relative.Length) -gt 259) | Should Be $true
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $manifestPath))
        [IO.File]::WriteAllText($target, 'old long payload')
        [IO.File]::WriteAllText($manifestPath, 'old long manifest')
        $plan = [pscustomobject]@{
            installRoot = $installRoot
            dataRoot = $dataRoot
            manifestPath = $manifestPath
            files = @([pscustomobject]@{relativePath = $relative})
        }
        $oldManifest = [pscustomobject]@{
            files = @([pscustomobject]@{relativePath = $relative})
        }

        $rollback = New-FileRollbackSnapshot -Plan $plan -OldManifest $oldManifest
        @($rollback.files | Where-Object { $_.existed }).Count | Should Be 1
        foreach ($record in @($rollback.files | Where-Object { $_.existed })) {
            $record.backupPath.Length | Should BeLessThan 260
            ([IO.Path]::GetFileName($record.backupPath)) | Should Match '^[0-9a-f]{32}\.bak$'
            $record.backupPath | Should Not Match ([regex]::Escape($relative))
        }
        $legacyBackupPath = Join-Path $rollback.root ('files\' + $relative)
        $legacyBackupPath.Length | Should BeGreaterThan 259

        [IO.File]::WriteAllText($target, 'new long payload')
        Restore-FileRollbackSnapshot -Snapshot $rollback
        [IO.File]::ReadAllText($target) | Should Be 'old long payload'
        [IO.File]::ReadAllText($manifestPath) | Should Be 'old long manifest'
        Remove-FileRollbackSnapshot -Snapshot $rollback
        (Test-Path -LiteralPath $rollback.root) | Should Be $false
    }
}
