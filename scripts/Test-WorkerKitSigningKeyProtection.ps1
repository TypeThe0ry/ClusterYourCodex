#requires -Version 7.0

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Materialize-WorkerKitSigningKey.ps1'
$testPath = Join-Path (
    [IO.Path]::GetTempPath()
) "cyc-signing-key-protection-$([guid]::NewGuid().ToString('N')).pem"
$previous = [Environment]::GetEnvironmentVariable('CYC_SIGNING_KEY_PEM_B64', 'Process')

try {
    $fixture = [byte[]]::new(80)
    for ($index = 0; $index -lt $fixture.Length; $index++) {
        $fixture[$index] = [byte](($index * 17 + 3) % 251)
    }
    [Environment]::SetEnvironmentVariable(
        'CYC_SIGNING_KEY_PEM_B64',
        [Convert]::ToBase64String($fixture),
        'Process'
    )

    & $scriptPath -OutputPath $testPath
    if (-not (Test-Path -LiteralPath $testPath -PathType Leaf)) {
        throw 'Signing-key protection test did not create its fixture.'
    }
    $materialized = [IO.File]::ReadAllBytes($testPath)
    if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
            $fixture,
            $materialized
        )) {
        throw 'Signing-key protection test observed a byte mismatch.'
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
            [Runtime.InteropServices.OSPlatform]::Windows
        )) {
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
        $security = [IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]::new($testPath))
        if (-not $security.AreAccessRulesProtected) {
            throw 'Signing-key protection test found inherited Windows access rules.'
        }
        $rules = $security.GetAccessRules(
            $true,
            $true,
            [Security.Principal.SecurityIdentifier]
        )
        $observed = @($rules | ForEach-Object {
                ([Security.Principal.SecurityIdentifier]$_.IdentityReference).Value
            } | Sort-Object -Unique)
        $expected = @($currentSid.Value, $systemSid.Value) | Sort-Object -Unique
        if (($observed -join "`n") -cne ($expected -join "`n")) {
            throw 'Signing-key protection test found an unexpected Windows principal.'
        }
    }
    else {
        $expectedMode = [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite
        if ([IO.File]::GetUnixFileMode($testPath) -ne $expectedMode) {
            throw 'Signing-key protection test did not observe mode 0600.'
        }
    }

    [Array]::Clear($materialized, 0, $materialized.Length)
    [Array]::Clear($fixture, 0, $fixture.Length)
    Write-Output 'Worker-kit signing-key private-file protection: passed'
}
finally {
    [Environment]::SetEnvironmentVariable('CYC_SIGNING_KEY_PEM_B64', $previous, 'Process')
    if (Test-Path -LiteralPath $testPath -PathType Leaf) {
        [IO.File]::Delete($testPath)
    }
}
