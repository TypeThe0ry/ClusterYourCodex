#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$tokens = $null
$parseErrors = $null
$installer = Join-Path $PSScriptRoot 'Install-Worker.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'Installer syntax errors.' }
$functions = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-PrivatePrincipalSids'
}, $true))
if ($functions.Count -ne 1) { throw 'Expected exactly one principal-set helper.' }
# Load only this pure helper; do not execute installer lifecycle operations.
. ([scriptblock]::Create($functions[0].Extent.Text))
$systemPrincipals = @(Get-PrivatePrincipalSids -UserSid 'S-1-5-18')
if ($systemPrincipals.Count -ne 1 -or $systemPrincipals[0] -cne 'S-1-5-18') {
    throw 'SYSTEM must have exactly one allowlisted principal.'
}
$user = 'S-1-5-21-100-200-300-1001'
$userPrincipals = @(Get-PrivatePrincipalSids -UserSid $user)
if ($userPrincipals.Count -ne 2 -or $user -notin $userPrincipals -or 'S-1-5-18' -notin $userPrincipals) {
    throw 'User scope must retain the user and SYSTEM, with no extra principals.'
}
Write-Output 'Private principal SID tests passed (SYSTEM and user).'
