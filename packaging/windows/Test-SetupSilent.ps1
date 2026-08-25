#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SetupPath,

    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [string]$WorkRoot = (Join-Path ([System.IO.Path]::GetTempPath()) ('clusteryourcodex-setup-silent-' + [Guid]::NewGuid().ToString('N'))),

    [switch]$DisposableEnvironment,

    [switch]$KeepWorkRoot,

    [ValidateRange(60, 2400)]
    [int]$LifecycleTimeoutSeconds = 2100
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ControllerTaskName = 'ClusterYourCodex Controller'
$script:WorkerTaskName = 'ClusterYourCodex Worker'
$script:FirewallGroup = 'ClusterYourCodex'
$script:FirewallDescription = 'ClusterYourCodex owned managed-worker TLS listener'
$script:UninstallRegistryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ClusterYourCodex'
$script:InstallManifestSchema = 'cyc.dev/windows-install-manifest/v1'
$script:PreviewManifestSchema = 'cyc.dev/windows-preview/v1'
$script:LifecycleJournalSchema = 'cyc.dev/windows-external-lifecycle/v1'
$script:FirewallReceiptSchema = 'cyc.dev/windows-firewall-receipt/v1'
$script:CoreCommitSchema = 'cyc.dev/windows-core-commit/v1'
$script:FirewallLifecycleName = 'external-elevated-helper'
$script:MaximumInstallManifestBytes = 16MB
$script:MaximumFirewallReceiptBytes = 32768
$script:BoundedProcessTerminationUncertain = $false

function Assert-SetupSilent {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw "silent Setup assertion failed: $Message"
    }
}

function ConvertTo-SetupSilentSid {
    param([Parameter(Mandatory = $true)][string]$IdentityText)

    if ([string]::IsNullOrWhiteSpace($IdentityText) -or
        [regex]::IsMatch($IdentityText, '[\x00-\x1F\x7F]')) {
        throw 'Scheduled Task identity is blank or malformed.'
    }

    try {
        if ($IdentityText.StartsWith('S-', [System.StringComparison]::OrdinalIgnoreCase)) {
            # A SID-looking value must be a structurally valid SID. Never
            # reinterpret an invalid SID as an account name.
            $sid = New-Object System.Security.Principal.SecurityIdentifier($IdentityText)
        } else {
            $account = New-Object System.Security.Principal.NTAccount($IdentityText)
            $sid = $account.Translate([System.Security.Principal.SecurityIdentifier])
        }
    } catch {
        throw 'Scheduled Task identity could not be resolved to a stable SID.'
    }

    if (-not $sid -or [string]::IsNullOrWhiteSpace([string]$sid.Value)) {
        throw 'Scheduled Task identity resolved without a stable SID.'
    }
    return [string]$sid.Value
}

function Assert-SetupSilentTaskIdentityXml {
    param(
        [Parameter(Mandatory = $true)][xml]$TaskXml,
        [Parameter(Mandatory = $true)][string]$ExpectedSid
    )

    $taskNamespace = 'http://schemas.microsoft.com/windows/2004/02/mit/task'
    if (-not $TaskXml.DocumentElement -or
        [string]$TaskXml.DocumentElement.LocalName -cne 'Task' -or
        [string]$TaskXml.DocumentElement.NamespaceURI -cne $taskNamespace) {
        throw 'Scheduled Task XML uses an unexpected root or namespace.'
    }

    $namespaceManager = New-Object System.Xml.XmlNamespaceManager($TaskXml.NameTable)
    $namespaceManager.AddNamespace('task', $taskNamespace)

    $foreignElements = @($TaskXml.SelectNodes("//*[namespace-uri() != '$taskNamespace']"))
    if ($foreignElements.Count -ne 0) {
        throw 'Scheduled Task XML contains an element outside the Task Scheduler namespace.'
    }

    $principalContainers = @($TaskXml.SelectNodes('/task:Task/task:Principals', $namespaceManager))
    if ($principalContainers.Count -ne 1) {
        throw 'Scheduled Task XML must contain exactly one principals container.'
    }
    $principalElements = @($principalContainers[0].SelectNodes('*'))
    if ($principalElements.Count -ne 1 -or
        [string]$principalElements[0].LocalName -cne 'Principal' -or
        [string]$principalElements[0].NamespaceURI -cne $taskNamespace) {
        throw 'Scheduled Task XML must contain exactly one principal.'
    }
    $principalChildElements = @($principalElements[0].SelectNodes('*'))
    $principalUserIds = @($principalChildElements | Where-Object {
        [string]$_.LocalName -ceq 'UserId' -and [string]$_.NamespaceURI -ceq $taskNamespace
    })
    $principalGroupIds = @($principalChildElements | Where-Object {
        [string]$_.LocalName -ceq 'GroupId' -and [string]$_.NamespaceURI -ceq $taskNamespace
    })
    if ($principalUserIds.Count -ne 1 -or $principalGroupIds.Count -ne 0) {
        throw 'Scheduled Task XML must contain exactly one user principal.'
    }

    $triggerContainers = @($TaskXml.SelectNodes('/task:Task/task:Triggers', $namespaceManager))
    if ($triggerContainers.Count -ne 1) {
        throw 'Scheduled Task XML must contain exactly one triggers container.'
    }
    $triggerElements = @($triggerContainers[0].SelectNodes('*'))
    if ($triggerElements.Count -ne 1 -or
        [string]$triggerElements[0].LocalName -cne 'LogonTrigger' -or
        [string]$triggerElements[0].NamespaceURI -cne $taskNamespace) {
        throw 'Scheduled Task XML must contain exactly one logon trigger.'
    }
    $triggerChildElements = @($triggerElements[0].SelectNodes('*'))
    $triggerUserIds = @($triggerChildElements | Where-Object {
        [string]$_.LocalName -ceq 'UserId' -and [string]$_.NamespaceURI -ceq $taskNamespace
    })
    if ($triggerUserIds.Count -ne 1) {
        throw 'Scheduled Task XML logon trigger must contain exactly one UserId.'
    }

    $expectedSidValue = ConvertTo-SetupSilentSid -IdentityText $ExpectedSid
    $principalSid = ConvertTo-SetupSilentSid -IdentityText ([string]$principalUserIds[0].InnerText)
    $triggerSid = ConvertTo-SetupSilentSid -IdentityText ([string]$triggerUserIds[0].InnerText)
    if (-not [string]::Equals($principalSid, $expectedSidValue, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Scheduled Task XML principal SID does not match the initiating SID.'
    }
    if (-not [string]::Equals($triggerSid, $expectedSidValue, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Scheduled Task XML logon trigger SID does not match the initiating SID.'
    }

    return [PSCustomObject]@{
        principalSid = $principalSid
        triggerSid = $triggerSid
    }
}

function Invoke-SetupSilentTaskIdentityContractSelfTest {
    $fixtureSid = 'S-1-5-18'
    $taskNamespace = 'http://schemas.microsoft.com/windows/2004/02/mit/task'
    $validXmlText = @"
<Task xmlns="$taskNamespace">
  <Principals>
    <Principal id="Author">
      <UserId>$fixtureSid</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Triggers>
    <LogonTrigger>
      <UserId>$fixtureSid</UserId>
      <Enabled>true</Enabled>
    </LogonTrigger>
  </Triggers>
</Task>
"@

    [xml]$validXml = $validXmlText
    [void](Assert-SetupSilentTaskIdentityXml -TaskXml $validXml -ExpectedSid $fixtureSid)

    $rejectedFixtures = [ordered]@{
        'foreign-namespace principal sibling' = $validXmlText.Replace(
            '</Principals>',
            '<evil:Principal xmlns:evil="urn:cyc:test:evil" /></Principals>'
        )
        'foreign-namespace logon trigger' = $validXmlText.Replace(
            '<LogonTrigger>',
            '<evil:LogonTrigger xmlns:evil="urn:cyc:test:evil">'
        ).Replace('</LogonTrigger>', '</evil:LogonTrigger>')
        'foreign-namespace principal child' = $validXmlText.Replace(
            '<LogonType>InteractiveToken</LogonType>',
            '<evil:UserId xmlns:evil="urn:cyc:test:evil">S-1-5-19</evil:UserId><LogonType>InteractiveToken</LogonType>'
        )
        'multiple principals' = $validXmlText.Replace(
            '</Principals>',
            "<Principal><UserId>$fixtureSid</UserId></Principal></Principals>"
        )
        'group principal' = $validXmlText.Replace(
            "<UserId>$fixtureSid</UserId>",
            "<UserId>$fixtureSid</UserId><GroupId>S-1-5-32-545</GroupId>"
        )
        'boot trigger' = $validXmlText.Replace('LogonTrigger', 'BootTrigger')
        'multiple triggers' = $validXmlText.Replace(
            '</Triggers>',
            "<LogonTrigger><UserId>$fixtureSid</UserId></LogonTrigger></Triggers>"
        )
        'wrong namespace' = $validXmlText.Replace($taskNamespace, 'urn:cyc:test:wrong-task')
        'wrong principal SID' = $validXmlText.Replace(
            "<UserId>$fixtureSid</UserId>",
            '<UserId>S-1-5-19</UserId>'
        )
    }

    foreach ($fixture in $rejectedFixtures.GetEnumerator()) {
        [xml]$fixtureXml = [string]$fixture.Value
        $rejected = $false
        try {
            [void](Assert-SetupSilentTaskIdentityXml -TaskXml $fixtureXml -ExpectedSid $fixtureSid)
        } catch {
            $rejected = $true
        }
        Assert-SetupSilent $rejected ("identity contract rejects " + [string]$fixture.Key)
    }
}

function Resolve-SetupSilentPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A required path is empty.' }
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Test-SetupSilentPathEqual {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )
    return [string]::Equals(
        (Resolve-SetupSilentPath $Left),
        (Resolve-SetupSilentPath $Right),
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Assert-SetupSilentChildPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Candidate
    )
    $rootPath = Resolve-SetupSilentPath $Root
    $candidatePath = Resolve-SetupSilentPath $Candidate
    $prefix = $rootPath + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidatePath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "path escaped its expected root: $candidatePath"
    }
    return $candidatePath
}

function Assert-SetupSilentTreeHasNoReparsePoints {
    param([Parameter(Mandatory = $true)][string]$Root)

    $resolvedRoot = Resolve-SetupSilentPath $Root
    if (-not (Test-Path -LiteralPath $resolvedRoot)) {
        return
    }
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        throw "cleanup tree is not a directory: $resolvedRoot"
    }

    # Scan without descending through any link/junction. Remove-Item -Recurse
    # is used only after the complete harness-owned tree is proven ordinary.
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($resolvedRoot)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        $currentItem = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($currentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "cleanup tree contains a reparse point: $current"
        }
        foreach ($child in @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)) {
            if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "cleanup tree contains a reparse point: $($child.FullName)"
            }
            if ($child.PSIsContainer) {
                $pending.Push($child.FullName)
            }
        }
    }
}

function Assert-SetupSilentOwnedRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Parent
    )
    $resolved = Resolve-SetupSilentPath $Path
    $expectedPath = Resolve-SetupSilentPath $Expected
    $parentPath = Resolve-SetupSilentPath $Parent
    if (-not (Test-SetupSilentPathEqual -Left $resolved -Right $expectedPath)) {
        throw "cleanup path is not the exact disposable product root: $resolved"
    }
    [void](Assert-SetupSilentChildPath -Root $parentPath -Candidate $resolved)
    if ([System.IO.Path]::GetPathRoot($resolved).TrimEnd('\') -ieq $resolved.TrimEnd('\')) {
        throw "cleanup path is a volume root: $resolved"
    }
    if (Test-Path -LiteralPath $resolved) {
        $item = Get-Item -LiteralPath $resolved -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "cleanup root is a reparse point: $resolved"
        }
        Assert-SetupSilentTreeHasNoReparsePoints -Root $resolved
    }
    return $resolved
}

function Read-SetupSilentJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int64]$MaximumBytes = 4MB
    )
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -le 0 -or $item.Length -gt $MaximumBytes) {
        throw "JSON file is not a bounded regular file: $Path"
    }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $converter = Get-Command ConvertFrom-Json -CommandType Cmdlet -ErrorAction Stop
        if ($converter.Parameters.ContainsKey('DateKind')) {
            return ConvertFrom-Json -InputObject $raw -DateKind String
        }
        return ConvertFrom-Json -InputObject $raw
    } catch {
        throw "JSON file is invalid: $Path"
    }
}

function Assert-SetupSilentExactProperties {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Label
    )
    [string[]]$actualNames = @($Object.PSObject.Properties.Name)
    [string[]]$expectedNames = @($Expected)
    [Array]::Sort($actualNames, [System.StringComparer]::Ordinal)
    [Array]::Sort($expectedNames, [System.StringComparer]::Ordinal)
    Assert-SetupSilent `
        ([string]::Join(',', $actualNames) -ceq [string]::Join(',', $expectedNames)) `
        "$Label contains exactly the supported fields"
}

function Get-SetupSilentFirewallReceiptSnapshot {
    param([Parameter(Mandatory = $true)][string]$DataRoot)
    $receiptRoot = Resolve-SetupSilentPath (Join-Path $DataRoot '.installer\firewall-receipts')
    Assert-SetupSilent (Test-Path -LiteralPath $receiptRoot -PathType Container) 'durable firewall receipt directory exists'
    $rootItem = Get-Item -LiteralPath $receiptRoot -Force
    Assert-SetupSilent (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) 'durable firewall receipt directory is not a reparse point'

    $records = @()
    foreach ($item in @(Get-ChildItem -LiteralPath $receiptRoot -Force | Sort-Object Name)) {
        Assert-SetupSilent (-not $item.PSIsContainer) "firewall receipt directory contains only files: $($item.Name)"
        Assert-SetupSilent (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) "firewall receipt is not a reparse point: $($item.Name)"
        Assert-SetupSilent ($item.Name -cmatch '^[0-9a-f]{32}\.json$') "firewall receipt filename is a transaction id: $($item.Name)"
        Assert-SetupSilent ($item.Length -gt 0 -and $item.Length -le $script:MaximumFirewallReceiptBytes) "firewall receipt is bounded: $($item.Name)"
        $records += [PSCustomObject]@{
            path = Resolve-SetupSilentPath $item.FullName
            name = [string]$item.Name
            transactionId = [System.IO.Path]::GetFileNameWithoutExtension($item.Name)
            sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    return @($records)
}

function Assert-SetupSilentReceiptSnapshotPreserved {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Before,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$After,
        [Parameter(Mandatory = $true)][string]$Label
    )
    foreach ($old in @($Before)) {
        $matches = @($After | Where-Object {
            [string]::Equals([string]$_.path, [string]$old.path, [System.StringComparison]::OrdinalIgnoreCase)
        })
        Assert-SetupSilent ($matches.Count -eq 1) "$Label preserves receipt $([string]$old.name)"
        Assert-SetupSilent ([string]$matches[0].sha256 -ceq [string]$old.sha256) "$Label preserves receipt bytes $([string]$old.name)"
    }
}

function Assert-SetupSilentFirewallReceipt {
    param(
        [Parameter(Mandatory = $true)][string]$ReceiptPath,
        [Parameter(Mandatory = $true)][ValidateSet('Apply', 'Remove')][string]$ExpectedAction,
        [Parameter(Mandatory = $true)][string]$ExpectedTransactionId,
        [Parameter(Mandatory = $true)][string]$ExpectedRequestSha256,
        [Parameter(Mandatory = $true)][string]$ExpectedReceiptSha256,
        [Parameter(Mandatory = $true)][string]$ExpectedProgramSha256,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedSid,
        [Parameter(Mandatory = $true)][string]$ExpectedProfile,
        [Parameter(Mandatory = $true)][string]$ExpectedLocalAppData,
        [Parameter(Mandatory = $true)][string]$ExpectedRuleName
    )
    $receiptFile = Resolve-SetupSilentPath $ReceiptPath
    $receipt = Read-SetupSilentJson -Path $receiptFile -MaximumBytes $script:MaximumFirewallReceiptBytes
    Assert-SetupSilentExactProperties -Object $receipt -Label 'durable firewall receipt' -Expected @(
        'action', 'failureCode', 'initiatorLocalAppData', 'initiatorProfile',
        'initiatorSid', 'port', 'program', 'programSha256', 'requestSha256',
        'result', 'ruleName', 'schemaVersion', 'transactionId', 'verifiedAtUtc'
    )
    Assert-SetupSilent ([string]$receipt.schemaVersion -ceq $script:FirewallReceiptSchema) 'durable firewall receipt schema is current'
    Assert-SetupSilent ([string]$receipt.transactionId -cmatch '^[0-9a-f]{32}$') 'durable firewall receipt has a canonical transaction id'
    Assert-SetupSilent ([string]$receipt.transactionId -ceq $ExpectedTransactionId) 'durable firewall receipt transaction matches the lifecycle'
    Assert-SetupSilent ([System.IO.Path]::GetFileName($receiptFile) -ceq ($ExpectedTransactionId + '.json')) 'durable firewall receipt filename matches the transaction'
    Assert-SetupSilent ([string]$receipt.requestSha256 -cmatch '^[0-9a-f]{64}$') 'durable firewall receipt has a canonical request digest'
    Assert-SetupSilent ([string]$receipt.requestSha256 -ceq $ExpectedRequestSha256) 'durable firewall receipt binds the request digest'
    Assert-SetupSilent ([string]$receipt.action -ceq $ExpectedAction) "durable firewall receipt records $ExpectedAction"
    Assert-SetupSilent ([string]$receipt.result -ceq 'verified') 'durable firewall receipt records verified success'
    Assert-SetupSilent ([string]::IsNullOrWhiteSpace([string]$receipt.failureCode)) 'verified firewall receipt has no failure code'
    Assert-SetupSilent ([string]$receipt.initiatorSid -ceq $ExpectedSid) 'durable firewall receipt binds the initiating SID'
    Assert-SetupSilent (Test-SetupSilentPathEqual -Left ([string]$receipt.initiatorProfile) -Right $ExpectedProfile) 'durable firewall receipt binds the initiating profile'
    Assert-SetupSilent (Test-SetupSilentPathEqual -Left ([string]$receipt.initiatorLocalAppData) -Right $ExpectedLocalAppData) 'durable firewall receipt binds LOCALAPPDATA'
    Assert-SetupSilent ([string]$receipt.ruleName -ceq $ExpectedRuleName) 'durable firewall receipt binds the owned rule name'
    Assert-SetupSilent (Test-SetupSilentPathEqual -Left ([string]$receipt.program) -Right (Join-Path $InstallRoot 'cyc-controller.exe')) 'durable firewall receipt binds the installed controller path'
    Assert-SetupSilent ([string]$receipt.programSha256 -cmatch '^[0-9a-f]{64}$') 'durable firewall receipt has a canonical controller digest'
    Assert-SetupSilent ([string]$receipt.programSha256 -ceq $ExpectedProgramSha256) 'durable firewall receipt binds the installed controller digest'
    Assert-SetupSilent ([int]$receipt.port -eq 47832) 'durable firewall receipt binds the managed-worker port'
    $verifiedAt = [DateTimeOffset]::MinValue
    Assert-SetupSilent ([DateTimeOffset]::TryParse([string]$receipt.verifiedAtUtc, [ref]$verifiedAt)) 'durable firewall receipt has a valid verification timestamp'
    $actualReceiptSha256 = (Get-FileHash -LiteralPath $receiptFile -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-SetupSilent ($actualReceiptSha256 -ceq $ExpectedReceiptSha256) 'durable firewall receipt bytes match the committed digest'
    return [PSCustomObject]@{
        path = $receiptFile
        sha256 = $actualReceiptSha256
        transactionId = [string]$receipt.transactionId
        requestSha256 = [string]$receipt.requestSha256
        action = [string]$receipt.action
        receipt = $receipt
    }
}

function Assert-SetupSilentJournalRetiredOrComplete {
    param(
        [Parameter(Mandatory = $true)][string]$JournalPath,
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Repair', 'Uninstall')][string]$ExpectedAction,
        [Parameter(Mandatory = $true)][string]$ExpectedTransactionId,
        [Parameter(Mandatory = $true)][string]$ExpectedRequestSha256,
        [Parameter(Mandatory = $true)][string]$ExpectedReceiptPath,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedSid,
        [Parameter(Mandatory = $true)][string]$ExpectedProfile,
        [Parameter(Mandatory = $true)][string]$ExpectedLocalAppData
    )
    if (-not (Test-Path -LiteralPath $JournalPath)) { return 'absent' }
    Assert-SetupSilent (Test-Path -LiteralPath $JournalPath -PathType Leaf) 'firewall lifecycle journal tombstone is a regular-file candidate'

    $journal = Read-SetupSilentJson -Path $JournalPath -MaximumBytes 65536
    Assert-SetupSilentExactProperties -Object $journal -Label 'firewall lifecycle journal tombstone' -Expected @(
        'action', 'dataRoot', 'exchangeRoot', 'helperSha256', 'initiatorLocalAppData',
        'initiatorProfile', 'initiatorSid', 'installRoot', 'packageManifestSha256',
        'phase', 'privateReceiptPath', 'requestPath', 'requestSha256', 'schemaVersion',
        'transactionId', 'updatedAtUtc'
    )
    Assert-SetupSilent ([string]$journal.schemaVersion -ceq $script:LifecycleJournalSchema) 'firewall lifecycle journal tombstone schema is current'
    Assert-SetupSilent ([string]$journal.phase -ceq 'complete') 'firewall lifecycle journal is retired or a complete tombstone'
    Assert-SetupSilent ([string]$journal.action -ceq $ExpectedAction) 'firewall lifecycle journal tombstone records the completed action'
    Assert-SetupSilent ([string]$journal.transactionId -ceq $ExpectedTransactionId) 'firewall lifecycle journal tombstone binds the completed transaction'
    Assert-SetupSilent ([string]$journal.requestSha256 -ceq $ExpectedRequestSha256) 'firewall lifecycle journal tombstone binds the request digest'
    Assert-SetupSilent ([string]$journal.helperSha256 -cmatch '^[0-9a-f]{64}$') 'firewall lifecycle journal tombstone binds the helper digest'
    Assert-SetupSilent ([string]$journal.packageManifestSha256 -cmatch '^[0-9a-f]{64}$') 'firewall lifecycle journal tombstone binds the package digest'
    Assert-SetupSilent ([string]$journal.initiatorSid -ceq $ExpectedSid) 'firewall lifecycle journal tombstone binds the initiating SID'
    Assert-SetupSilent (Test-SetupSilentPathEqual -Left ([string]$journal.initiatorProfile) -Right $ExpectedProfile) 'firewall lifecycle journal tombstone binds the initiating profile'
    Assert-SetupSilent (Test-SetupSilentPathEqual -Left ([string]$journal.initiatorLocalAppData) -Right $ExpectedLocalAppData) 'firewall lifecycle journal tombstone binds LOCALAPPDATA'
    Assert-SetupSilent (Test-SetupSilentPathEqual -Left ([string]$journal.installRoot) -Right $InstallRoot) 'firewall lifecycle journal tombstone binds the install root'
    Assert-SetupSilent (Test-SetupSilentPathEqual -Left ([string]$journal.dataRoot) -Right $DataRoot) 'firewall lifecycle journal tombstone binds the data root'
    Assert-SetupSilent (Test-SetupSilentPathEqual -Left ([string]$journal.privateReceiptPath) -Right $ExpectedReceiptPath) 'firewall lifecycle journal tombstone binds the durable receipt path'

    $commonDocuments = [Environment]::GetFolderPath('CommonDocuments')
    Assert-SetupSilent (-not [string]::IsNullOrWhiteSpace($commonDocuments)) 'Public Documents is available for journal validation'
    $expectedExchangeRoot = Join-Path (Join-Path (Join-Path $commonDocuments 'ClusterYourCodex-Firewall') $ExpectedSid.Replace('-', '_')) $ExpectedTransactionId
    Assert-SetupSilent (Test-SetupSilentPathEqual -Left ([string]$journal.exchangeRoot) -Right $expectedExchangeRoot) 'firewall lifecycle journal tombstone binds the per-user exchange root'
    Assert-SetupSilent (Test-SetupSilentPathEqual -Left ([string]$journal.requestPath) -Right (Join-Path $expectedExchangeRoot 'request.json')) 'firewall lifecycle journal tombstone binds the transaction request path'
    if (Test-Path -LiteralPath ([string]$journal.requestPath) -PathType Leaf) {
        $requestHash = (Get-FileHash -LiteralPath ([string]$journal.requestPath) -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-SetupSilent ($requestHash -ceq $ExpectedRequestSha256) 'firewall lifecycle journal tombstone request evidence is unchanged'
    } else {
        Assert-SetupSilent ($ExpectedAction -cne 'Uninstall') 'completed Uninstall tombstone retains its request evidence'
    }
    $updatedAt = [DateTimeOffset]::MinValue
    Assert-SetupSilent ([DateTimeOffset]::TryParse([string]$journal.updatedAtUtc, [ref]$updatedAt)) 'firewall lifecycle journal tombstone has a valid update timestamp'
    return 'complete'
}

function Assert-SetupSilentAppliedLifecycleEvidence {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Repair')][string]$ExpectedAction,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedSid,
        [Parameter(Mandatory = $true)][string]$ExpectedProfile,
        [Parameter(Mandatory = $true)][string]$ExpectedLocalAppData,
        [Parameter(Mandatory = $true)][string]$ExpectedRuleName
    )
    $firewall = $Manifest.managedWorker.firewall
    Assert-SetupSilent (($firewall.enabled -is [bool]) -and [bool]$firewall.enabled) "$ExpectedAction manifest enables the managed-worker firewall with a real Boolean"
    Assert-SetupSilent ([string]$firewall.lifecycle -ceq $script:FirewallLifecycleName) "$ExpectedAction manifest uses the external firewall lifecycle"
    Assert-SetupSilent ([string]$firewall.state -ceq 'applied') "$ExpectedAction manifest commits the firewall receipt"
    Assert-SetupSilent ([string]$firewall.transactionId -cmatch '^[0-9a-f]{32}$') "$ExpectedAction manifest records a transaction id"
    Assert-SetupSilent ([string]$firewall.requestSha256 -cmatch '^[0-9a-f]{64}$') "$ExpectedAction manifest records a request digest"
    Assert-SetupSilent ([string]$firewall.receiptSha256 -cmatch '^[0-9a-f]{64}$') "$ExpectedAction manifest records a receipt digest"
    Assert-SetupSilent ([string]$firewall.name -ceq $ExpectedRuleName) "$ExpectedAction manifest records the owned firewall rule"

    $controllerRecord = Get-SetupSilentManifestFile -Manifest $Manifest -RelativePath 'cyc-controller.exe'
    $receiptPath = Join-Path (Join-Path $DataRoot '.installer\firewall-receipts') (([string]$firewall.transactionId) + '.json')
    $receiptEvidence = Assert-SetupSilentFirewallReceipt `
        -ReceiptPath $receiptPath `
        -ExpectedAction Apply `
        -ExpectedTransactionId ([string]$firewall.transactionId) `
        -ExpectedRequestSha256 ([string]$firewall.requestSha256) `
        -ExpectedReceiptSha256 ([string]$firewall.receiptSha256) `
        -ExpectedProgramSha256 ([string]$controllerRecord.sha256) `
        -InstallRoot $InstallRoot `
        -ExpectedSid $ExpectedSid `
        -ExpectedProfile $ExpectedProfile `
        -ExpectedLocalAppData $ExpectedLocalAppData `
        -ExpectedRuleName $ExpectedRuleName
    $journalState = Assert-SetupSilentJournalRetiredOrComplete `
        -JournalPath (Join-Path $DataRoot '.installer\firewall-lifecycle.json') `
        -ExpectedAction $ExpectedAction `
        -ExpectedTransactionId ([string]$firewall.transactionId) `
        -ExpectedRequestSha256 ([string]$firewall.requestSha256) `
        -ExpectedReceiptPath $receiptPath `
        -InstallRoot $InstallRoot `
        -DataRoot $DataRoot `
        -ExpectedSid $ExpectedSid `
        -ExpectedProfile $ExpectedProfile `
        -ExpectedLocalAppData $ExpectedLocalAppData
    return [PSCustomObject]@{
        lifecycleAction = $ExpectedAction
        transactionId = [string]$firewall.transactionId
        requestSha256 = [string]$firewall.requestSha256
        receiptPath = [string]$receiptEvidence.path
        receiptSha256 = [string]$receiptEvidence.sha256
        journalState = [string]$journalState
    }
}

function ConvertTo-SetupSilentNativeArgument {
    param([AllowEmptyString()][string]$Argument)
    if ($null -eq $Argument -or $Argument.Length -eq 0) { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') {
            $slashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($slashes * 2) + 1)))
            [void]$builder.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) {
            [void]$builder.Append(('\' * $slashes))
            $slashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($slashes -gt 0) { [void]$builder.Append(('\' * ($slashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-SetupSilentBoundedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$LogRoot,
        [Parameter(Mandatory = $true)][string]$Label,
        [ValidateRange(1, 2400)][int]$TimeoutSeconds = 120,
        [string]$WorkingDirectory,
        [hashtable]$EnvironmentVariables = @{},
        [switch]$AssertNoNewVisiblePowerShellWindow
    )
    $resolvedExecutable = Resolve-SetupSilentPath $FilePath
    if (-not (Test-Path -LiteralPath $resolvedExecutable -PathType Leaf)) {
        throw "$Label executable is missing: $resolvedExecutable"
    }
    [void](New-Item -ItemType Directory -Path $LogRoot -Force)
    $stdoutPath = Join-Path $LogRoot ($Label + '.stdout.log')
    $stderrPath = Join-Path $LogRoot ($Label + '.stderr.log')
    $start = [DateTimeOffset]::UtcNow
    $process = $null
    $powerShellPidsBefore = New-Object 'System.Collections.Generic.HashSet[int]'
    if ($AssertNoNewVisiblePowerShellWindow) {
        foreach ($existingPowerShell in @(Get-Process -Name powershell -ErrorAction SilentlyContinue)) {
            [void]$powerShellPidsBefore.Add([int]$existingPowerShell.Id)
        }
    }
    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $resolvedExecutable
        $startInfo.Arguments = [string]::Join(' ', @($ArgumentList | ForEach-Object {
            ConvertTo-SetupSilentNativeArgument -Argument ([string]$_)
        }))
        $startInfo.WorkingDirectory = if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            Split-Path -Parent $resolvedExecutable
        } else {
            Resolve-SetupSilentPath $WorkingDirectory
        }
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($entry in $EnvironmentVariables.GetEnumerator()) {
            $name = [string]$entry.Key
            $value = [string]$entry.Value
            if ([string]::IsNullOrWhiteSpace($name) -or $name -match '[=\x00-\x1f\x7f]') {
                throw "$Label contains an invalid environment-variable name."
            }
            if ($value -match '[\x00]') { throw "$Label contains an invalid environment-variable value." }
            $startInfo.EnvironmentVariables[$name] = $value
        }

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw "$Label could not start." }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
        $visiblePowerShellPid = $null
        $timedOut = $false
        while (-not $process.WaitForExit(100)) {
            if ($AssertNoNewVisiblePowerShellWindow) {
                foreach ($candidate in @(Get-Process -Name powershell -ErrorAction SilentlyContinue)) {
                    if (-not $powerShellPidsBefore.Contains([int]$candidate.Id) -and
                        [int64]$candidate.MainWindowHandle -ne 0) {
                        $visiblePowerShellPid = [int]$candidate.Id
                        break
                    }
                }
                if ($null -ne $visiblePowerShellPid) { break }
            }
            if ([DateTimeOffset]::UtcNow -ge $deadline) {
                $timedOut = $true
                break
            }
        }
        if ($timedOut -or $null -ne $visiblePowerShellPid) {
            $taskKill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
            $taskKillExit = -1
            try {
                & $taskKill /PID $process.Id /T /F *> $null
                $taskKillExit = [int]$LASTEXITCODE
            } catch { }
            $terminated = $false
            try { $terminated = [bool]$process.WaitForExit(30000) } catch { $terminated = $false }
            if ($taskKillExit -ne 0 -or -not $terminated) {
                $script:BoundedProcessTerminationUncertain = $true
            }
            if ($null -ne $visiblePowerShellPid) {
                throw "$Label displayed a transient PowerShell console during silent execution (pid=$visiblePowerShellPid)."
            }
            throw "$Label timed out after $TimeoutSeconds seconds (pid=$($process.Id))."
        }
        $process.WaitForExit()
        $stdout = [string]$stdoutTask.GetAwaiter().GetResult()
        $stderr = [string]$stderrTask.GetAwaiter().GetResult()
        $utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
        [System.IO.File]::WriteAllText($stdoutPath, $stdout, $utf8)
        [System.IO.File]::WriteAllText($stderrPath, $stderr, $utf8)
        $exitCode = [int]$process.ExitCode
        $elapsed = ([DateTimeOffset]::UtcNow - $start).TotalSeconds
        if ($exitCode -ne 0) {
            $tail = if ([string]::IsNullOrWhiteSpace($stderr)) { '' } else {
                ([string]::Join(' ', @($stderr -split "`r?`n" | Select-Object -Last 20))).Trim()
            }
            throw "$Label failed with exit $exitCode after $([Math]::Round($elapsed, 2)) seconds. stderr=$tail"
        }
        return [PSCustomObject]@{
            label = $Label
            exitCode = $exitCode
            elapsedSeconds = [Math]::Round($elapsed, 3)
            stdout = $stdoutPath
            stderr = $stderrPath
        }
    } finally {
        if ($process) { $process.Dispose() }
    }
}

function Get-SetupSilentTaskSnapshot {
    $records = @()
    foreach ($name in @($script:ControllerTaskName, $script:WorkerTaskName)) {
        $tasks = @(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)
        foreach ($task in $tasks) {
            $records += [PSCustomObject]@{
                name = $name
                taskPath = [string]$task.TaskPath
                state = [string]$task.State
                xml = [string](Export-ScheduledTask -TaskName $name -TaskPath $task.TaskPath)
            }
        }
    }
    return @($records | Sort-Object name, taskPath)
}

function Get-SetupSilentFirewallRules {
    return @(Get-NetFirewallRule -Group $script:FirewallGroup -ErrorAction SilentlyContinue | Sort-Object Name)
}

function Get-SetupSilentFirewallSnapshot {
    return @(
        Get-SetupSilentFirewallRules | ForEach-Object {
            $rule = $_
            $port = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue
            $address = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue
            $application = Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue
            [PSCustomObject]@{
                name = [string]$rule.Name
                displayName = [string]$rule.DisplayName
                description = [string]$rule.Description
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
    )
}

function Get-SetupSilentListeners {
    return @(
        foreach ($port in @(47831, 47832)) {
            Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue
        }
    )
}

function Get-SetupSilentProductProcesses {
    return @(
        Get-Process -Name @('ClusterYourCodex', 'cyc-controller', 'cyc-worker') -ErrorAction SilentlyContinue |
            ForEach-Object {
                $candidateProcess = $_
                $path = $null
                try { $path = Resolve-SetupSilentPath $candidateProcess.Path } catch { $path = $null }
                [PSCustomObject]@{
                    id = [int]$candidateProcess.Id
                    name = [string]$candidateProcess.ProcessName
                    path = $path
                }
            }
    )
}

function Wait-SetupSilentController {
    param([int]$TimeoutSeconds = 45)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            $health = Invoke-RestMethod `
                -Uri 'http://127.0.0.1:47831/v1/health' `
                -Method Get `
                -TimeoutSec 2 `
                -UseBasicParsing
            if ([string]$health.status -ceq 'ok' -and $health.apiVersion) { return $health }
        } catch { }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'silent Setup controller did not become healthy.'
}

function Wait-SetupSilentPortsReleased {
    param([int]$TimeoutSeconds = 30)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (@(Get-SetupSilentListeners).Count -eq 0) { return }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    $remaining = @(Get-SetupSilentListeners | ForEach-Object { "$($_.LocalAddress):$($_.LocalPort)/$($_.OwningProcess)" })
    throw "product listener ports were not released: $($remaining -join ', ')"
}

function Get-SetupSilentManifestFile {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )
    $normalizedRelativePath = $RelativePath.Replace('\', '/')
    $records = @($Manifest.files | Where-Object {
        [string]::Equals(
            ([string]$_.relativePath).Replace('\', '/'),
            $normalizedRelativePath,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    })
    if ($records.Count -ne 1) { throw "install manifest has no unique file record for $RelativePath" }
    return $records[0]
}

function Assert-SetupSilentManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Repair')][string]$ExpectedAction,
        [Parameter(Mandatory = $true)][string]$ExpectedSid,
        [Parameter(Mandatory = $true)][string]$ExpectedProfile,
        [Parameter(Mandatory = $true)][string]$ExpectedLocalAppData
    )
    $manifest = Read-SetupSilentJson -Path $ManifestPath -MaximumBytes $script:MaximumInstallManifestBytes
    Assert-SetupSilent ([string]$manifest.schemaVersion -ceq $script:InstallManifestSchema) 'durable install manifest schema is current'
    Assert-SetupSilent (Test-SetupSilentPathEqual -Left ([string]$manifest.installRoot) -Right $InstallRoot) 'install manifest binds the default install root'
    Assert-SetupSilent (Test-SetupSilentPathEqual -Left ([string]$manifest.dataRoot) -Right $DataRoot) 'install manifest binds the default data root'
    Assert-SetupSilent ([string]$manifest.initiator.sid -ceq $ExpectedSid) 'install manifest binds the initiating SID'
    Assert-SetupSilent (Test-SetupSilentPathEqual -Left ([string]$manifest.initiator.profile) -Right $ExpectedProfile) 'install manifest binds the initiating profile'
    Assert-SetupSilent (Test-SetupSilentPathEqual -Left ([string]$manifest.initiator.localAppData) -Right $ExpectedLocalAppData) 'install manifest binds LOCALAPPDATA'
    Assert-SetupSilent ($null -ne $manifest.PSObject.Properties['coreCommit']) 'install manifest contains a core commit marker'
    Assert-SetupSilentExactProperties -Object $manifest.coreCommit -Label 'install core commit marker' -Expected @(
        'action', 'committedAtUtc', 'requestSha256', 'schemaVersion', 'state', 'transactionId'
    )
    Assert-SetupSilent ([string]$manifest.coreCommit.schemaVersion -ceq $script:CoreCommitSchema) 'install core commit marker schema is current'
    Assert-SetupSilent ([string]$manifest.coreCommit.action -ceq $ExpectedAction) "install core commit marker records $ExpectedAction"
    Assert-SetupSilent ([string]$manifest.coreCommit.state -ceq 'committed') 'install core commit marker records durable completion'
    Assert-SetupSilent ([string]$manifest.coreCommit.transactionId -ceq [string]$manifest.managedWorker.firewall.transactionId) 'install core commit marker binds the firewall transaction'
    Assert-SetupSilent ([string]$manifest.coreCommit.requestSha256 -ceq [string]$manifest.managedWorker.firewall.requestSha256) 'install core commit marker binds the firewall request'
    $coreCommittedAt = [DateTimeOffset]::MinValue
    Assert-SetupSilent (
        [string]$manifest.coreCommit.committedAtUtc -cmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}(?:Z|[+-]\d{2}:\d{2})$' -and
        [DateTimeOffset]::TryParse(
            [string]$manifest.coreCommit.committedAtUtc,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$coreCommittedAt
        )
    ) 'install core commit marker has a strict round-trip timestamp'

    $files = @($manifest.files)
    Assert-SetupSilent ($files.Count -gt 0) 'install manifest contains files'
    foreach ($record in $files) {
        $relative = ([string]$record.relativePath).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        Assert-SetupSilent (-not [System.IO.Path]::IsPathRooted($relative)) "manifest file is relative: $relative"
        $target = Assert-SetupSilentChildPath -Root $InstallRoot -Candidate (Join-Path $InstallRoot $relative)
        Assert-SetupSilent (Test-Path -LiteralPath $target -PathType Leaf) "installed file exists: $relative"
        $item = Get-Item -LiteralPath $target -Force
        Assert-SetupSilent (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) "installed file is not a reparse point: $relative"
        Assert-SetupSilent ([int64]$item.Length -eq [int64]$record.length) "installed file length matches: $relative"
        $actualHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-SetupSilent ($actualHash -ceq ([string]$record.sha256).ToLowerInvariant()) "installed file SHA-256 matches: $relative"
    }
    foreach ($required in @(
        'ClusterYourCodex.exe',
        'cyc-controller.exe',
        'cyc-worker.exe',
        'cyc.exe',
        'installer\bootstrap.ps1',
        'installer\Invoke-ClusterYourCodexLifecycle.ps1',
        'installer\Uninstall-ClusterYourCodex.ps1'
    )) {
        [void](Get-SetupSilentManifestFile -Manifest $manifest -RelativePath $required)
    }
    return $manifest
}

function Assert-SetupSilentControllerTask {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedSid
    )
    $controllerTasks = @(Get-ScheduledTask -TaskName $script:ControllerTaskName -TaskPath '\' -ErrorAction SilentlyContinue)
    $workerTasks = @(Get-ScheduledTask -TaskName $script:WorkerTaskName -TaskPath '\' -ErrorAction SilentlyContinue)
    Assert-SetupSilent ($controllerTasks.Count -eq 1) 'controller Scheduled Task is installed exactly once'
    Assert-SetupSilent ($workerTasks.Count -eq 0) 'unpaired local worker task remains absent'
    $task = $controllerTasks[0]
    Assert-SetupSilent ([string]$task.TaskPath -ceq '\') 'controller task is registered at the root task path'
    $actions = @($task.Actions)
    Assert-SetupSilent ($actions.Count -eq 1) 'controller Scheduled Task has exactly one action'
    $expectedExecutable = Join-Path $InstallRoot 'cyc-controller.exe'
    Assert-SetupSilent (Test-SetupSilentPathEqual -Left ([string]$actions[0].Execute) -Right $expectedExecutable) 'controller task is bound to the installed executable'
    Assert-SetupSilent (Test-SetupSilentPathEqual -Left ([string]$actions[0].WorkingDirectory) -Right $InstallRoot) 'controller task working directory is the install root'
    Assert-SetupSilent ([string]$actions[0].Arguments -match '(?:^|\s)--bind\s+127\.0\.0\.1:47831(?:\s|$)') 'controller task binds the loopback API'
    Assert-SetupSilent ([string]$actions[0].Arguments -match '(?:^|\s)--worker-bind\s+0\.0\.0\.0:47832(?:\s|$)') 'controller task binds the managed-worker listener'
    # The ScheduledTasks CIM provider may display the same principal as a SID,
    # qualified NTAccount, UPN, or bare local account. Compare only canonical
    # SIDs, then independently verify the persisted task definition.
    $principalSid = ConvertTo-SetupSilentSid -IdentityText ([string]$task.Principal.UserId)
    Assert-SetupSilent (
        [string]::Equals($principalSid, $ExpectedSid, [System.StringComparison]::OrdinalIgnoreCase)
    ) 'controller task principal SID is the initiating SID'
    [xml]$taskXml = Export-ScheduledTask `
        -TaskName $script:ControllerTaskName `
        -TaskPath '\' `
        -ErrorAction Stop
    [void](Assert-SetupSilentTaskIdentityXml -TaskXml $taskXml -ExpectedSid $ExpectedSid)
    Assert-SetupSilent ([string]$task.Principal.RunLevel -match '^(Limited|0)$') 'controller task uses limited run level'
    Assert-SetupSilent ([string]$task.Principal.LogonType -match '^(Interactive|InteractiveToken|3)$') 'controller task uses interactive logon'
    Assert-SetupSilent ([string]$task.State -ceq 'Running') 'controller task is running'
    $info = Get-ScheduledTaskInfo -TaskName $script:ControllerTaskName -TaskPath '\' -ErrorAction Stop
    Assert-SetupSilent ([long]$info.LastTaskResult -in @(0, 267009)) 'controller task reports a healthy last result'
    return $task
}

function Assert-SetupSilentControllerRuntime {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)
    $health = Wait-SetupSilentController
    Assert-SetupSilent ([string]$health.status -ceq 'ok') 'controller loopback health succeeds'
    $apiListeners = @(Get-NetTCPConnection -State Listen -LocalPort 47831 -ErrorAction SilentlyContinue)
    $workerListeners = @(Get-NetTCPConnection -State Listen -LocalPort 47832 -ErrorAction SilentlyContinue)
    Assert-SetupSilent ($apiListeners.Count -ge 1) 'controller loopback listener is active'
    Assert-SetupSilent ($workerListeners.Count -ge 1) 'managed-worker TLS listener is active'
    Assert-SetupSilent (@($apiListeners | Where-Object { [string]$_.LocalAddress -eq '127.0.0.1' }).Count -ge 1) 'controller API is bound to IPv4 loopback'
    $expectedExecutable = Join-Path $InstallRoot 'cyc-controller.exe'
    $owners = @($apiListeners + $workerListeners | ForEach-Object { [int]$_.OwningProcess } | Sort-Object -Unique)
    Assert-SetupSilent ($owners.Count -eq 1) 'both listeners belong to one controller process'
    $process = Get-Process -Id $owners[0] -ErrorAction Stop
    Assert-SetupSilent (Test-SetupSilentPathEqual -Left $process.Path -Right $expectedExecutable) 'listener owner is the installed controller'
    return [PSCustomObject]@{ health = $health; processId = $owners[0] }
}

function Assert-SetupSilentFirewall {
    param([Parameter(Mandatory = $true)]$Manifest)
    $firewall = $Manifest.managedWorker.firewall
    Assert-SetupSilent ([bool]$Manifest.managedWorker.enabled) 'managed-worker listener is enabled'
    Assert-SetupSilent ([bool]$firewall.enabled) 'managed-worker firewall is enabled'
    Assert-SetupSilent ([string]$firewall.state -ceq 'applied') 'managed-worker firewall receipt is committed'
    Assert-SetupSilent ([string]$firewall.receiptSha256 -match '^[0-9a-f]{64}$') 'managed-worker firewall receipt has a SHA-256 digest'
    $rules = @(Get-NetFirewallRule -Name ([string]$firewall.name) -ErrorAction SilentlyContinue)
    Assert-SetupSilent ($rules.Count -eq 1) 'owned managed-worker firewall rule exists exactly once'
    $rule = $rules[0]
    $port = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
    $address = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
    $application = Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
    Assert-SetupSilent ([string]$rule.Group -ceq $script:FirewallGroup) 'firewall group is owned by ClusterYourCodex'
    Assert-SetupSilent ([string]$rule.DisplayName -ceq 'ClusterYourCodex Managed Worker') 'firewall display name is current'
    Assert-SetupSilent ([string]$rule.Description -ceq $script:FirewallDescription) 'firewall description proves ownership'
    Assert-SetupSilent ([string]$rule.Enabled -ceq 'True') 'firewall rule is enabled'
    Assert-SetupSilent ([string]$rule.Direction -ceq 'Inbound') 'firewall rule is inbound'
    Assert-SetupSilent ([string]$rule.Action -ceq 'Allow') 'firewall rule allows traffic'
    Assert-SetupSilent ([string]$rule.Profile -match '^(2|Private)$') 'firewall rule is Private-profile only'
    Assert-SetupSilent ([string]$port.Protocol -match '^(6|TCP)$') 'firewall rule is TCP'
    Assert-SetupSilent ([string]$port.LocalPort -ceq '47832') 'firewall rule exposes only port 47832'
    Assert-SetupSilent (@($address.RemoteAddress) -contains 'LocalSubnet') 'firewall rule is LocalSubnet only'
    Assert-SetupSilent (Test-SetupSilentPathEqual -Left ([string]$application.Program) -Right ([string]$firewall.program)) 'firewall rule is bound to the installed controller'
    return $rule
}

function Assert-SetupSilentUninstallRegistration {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$DataRoot
    )
    Assert-SetupSilent (Test-Path -LiteralPath $script:UninstallRegistryPath) 'Apps & Features registration exists'
    $registration = Get-ItemProperty -LiteralPath $script:UninstallRegistryPath -ErrorAction Stop
    Assert-SetupSilent ([string]$registration.DisplayName -ceq 'ClusterYourCodex') 'uninstall registration has the product name'
    Assert-SetupSilent ([string]$registration.Publisher -ceq 'TypeThe0ry') 'uninstall registration has the expected publisher'
    Assert-SetupSilent (Test-SetupSilentPathEqual -Left ([string]$registration.InstallLocation) -Right $InstallRoot) 'uninstall registration binds the install root'
    Assert-SetupSilent (Test-SetupSilentPathEqual -Left ([string]$registration.DataLocation) -Right $DataRoot) 'uninstall registration binds the data root'
    Assert-SetupSilent (Test-SetupSilentPathEqual -Left ([string]$registration.DisplayIcon) -Right (Join-Path $InstallRoot 'ClusterYourCodex.exe')) 'uninstall registration icon is installed'
    Assert-SetupSilent ([string]$registration.UninstallString -match [regex]::Escape((Join-Path $InstallRoot 'installer\Uninstall-ClusterYourCodex.ps1'))) 'uninstall command invokes the installed uninstaller'
    Assert-SetupSilent ([string]$registration.QuietUninstallString -match '(?:^|\s)-Quiet(?:\s|$)') 'quiet uninstall command is registered'
    Assert-SetupSilent ([int]$registration.NoModify -eq 1 -and [int]$registration.NoRepair -eq 1) 'Apps & Features modification and repair buttons are disabled'
    return $registration
}

function Invoke-SetupSilentProbes {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$WorkRoot,
        [Parameter(Mandatory = $true)][string]$LogRoot,
        [Parameter(Mandatory = $true)][string]$Prefix
    )
    $results = @()
    $results += Invoke-SetupSilentBoundedProcess `
        -FilePath (Join-Path $InstallRoot 'cyc-controller.exe') `
        -ArgumentList @('--version') `
        -LogRoot $LogRoot `
        -Label ($Prefix + '-controller-version') `
        -TimeoutSeconds 60
    $workerWorkspace = Join-Path $WorkRoot ($Prefix + '-worker-probe')
    [void](New-Item -ItemType Directory -Path $workerWorkspace -Force)
    $results += Invoke-SetupSilentBoundedProcess `
        -FilePath (Join-Path $InstallRoot 'cyc-worker.exe') `
        -ArgumentList @('probe', '--workspace', $workerWorkspace, '--pretty') `
        -LogRoot $LogRoot `
        -Label ($Prefix + '-worker-probe') `
        -TimeoutSeconds 120
    $results += Invoke-SetupSilentBoundedProcess `
        -FilePath (Join-Path $InstallRoot 'cyc.exe') `
        -ArgumentList @('--help') `
        -LogRoot $LogRoot `
        -Label ($Prefix + '-cli-help') `
        -TimeoutSeconds 60
    return @($results)
}

function Stop-SetupSilentOwnedProcesses {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)
    foreach ($process in Get-Process -Name @('ClusterYourCodex', 'cyc-controller', 'cyc-worker') -ErrorAction SilentlyContinue) {
        $path = $null
        try { $path = Resolve-SetupSilentPath $process.Path } catch { $path = $null }
        if ($path -and $path.StartsWith($InstallRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
            Wait-Process -Id $process.Id -Timeout 15 -ErrorAction SilentlyContinue
        }
    }
}

function Remove-SetupSilentOwnedTasks {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)
    foreach ($name in @($script:WorkerTaskName, $script:ControllerTaskName)) {
        $tasks = @(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)
        foreach ($task in $tasks) {
            $actions = @($task.Actions)
            if ($actions.Count -ne 1) { throw "refusing to remove task with ambiguous actions: $name" }
            $execute = Resolve-SetupSilentPath ([string]$actions[0].Execute)
            if (-not $execute.StartsWith($InstallRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "refusing to remove a task not owned by the disposable install: $name"
            }
            Stop-ScheduledTask -TaskName $name -TaskPath $task.TaskPath -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $name -TaskPath $task.TaskPath -Confirm:$false -ErrorAction Stop
        }
    }
}

function Remove-SetupSilentOwnedFirewall {
    param(
        [Parameter(Mandatory = $true)][string]$ExpectedProgram,
        [Parameter(Mandatory = $true)][string]$ExpectedRuleName
    )
    $rules = @(Get-NetFirewallRule -Name $ExpectedRuleName -ErrorAction SilentlyContinue)
    foreach ($rule in $rules) {
        $port = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
        $application = Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
        if ([string]$rule.Group -cne $script:FirewallGroup -or
            [string]$rule.Description -cne $script:FirewallDescription -or
            [string]$port.LocalPort -cne '47832' -or
            -not (Test-SetupSilentPathEqual -Left ([string]$application.Program) -Right $ExpectedProgram)) {
            throw "refusing to remove a firewall rule not owned by the disposable install: $ExpectedRuleName"
        }
        Remove-NetFirewallRule -Name ([string]$rule.Name) -ErrorAction Stop
    }
}

function Remove-SetupSilentOwnedRegistration {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)
    if (-not (Test-Path -LiteralPath $script:UninstallRegistryPath)) { return }
    $registration = Get-ItemProperty -LiteralPath $script:UninstallRegistryPath -ErrorAction Stop
    if ([string]$registration.Publisher -cne 'TypeThe0ry' -or
        -not (Test-SetupSilentPathEqual -Left ([string]$registration.InstallLocation) -Right $InstallRoot)) {
        throw 'refusing to remove an uninstall key not owned by the disposable install'
    }
    Remove-Item -LiteralPath $script:UninstallRegistryPath -Recurse -Force -ErrorAction Stop
}

if (-not $DisposableEnvironment -or [string]$env:CYC_DISPOSABLE_WINDOWS -cne '1') {
    throw 'Test-SetupSilent.ps1 requires an explicitly marked disposable Windows environment.'
}
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Silent Setup smoke requires Windows.'
}
[void](Invoke-SetupSilentTaskIdentityContractSelfTest)

$setup = Resolve-SetupSilentPath $SetupPath
$package = Resolve-SetupSilentPath $PackageRoot
$work = Resolve-SetupSilentPath $WorkRoot
$workExistedAtStart = Test-Path -LiteralPath $work
$logRoot = Join-Path $work 'logs'
$lifecycleDiagnosticPath = Join-Path $logRoot 'setup-lifecycle.json'
$localAppData = Resolve-SetupSilentPath $env:LOCALAPPDATA
$profile = Resolve-SetupSilentPath $env:USERPROFILE
$installRoot = Resolve-SetupSilentPath (Join-Path $localAppData 'Programs\ClusterYourCodex')
$dataRoot = Resolve-SetupSilentPath (Join-Path $localAppData 'ClusterYourCodex')
$manifestPath = Join-Path $dataRoot '.installer\install-manifest.json'
$journalPath = Join-Path $dataRoot '.installer\firewall-lifecycle.json'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$identitySid = [string]$identity.User.Value
$expectedRuleName = 'ClusterYourCodex.ManagedWorker.' + $identitySid.Replace('-', '_')
$expectedController = Join-Path $installRoot 'cyc-controller.exe'

$allowedTempRoots = New-Object System.Collections.Generic.List[string]
[void]$allowedTempRoots.Add((Resolve-SetupSilentPath ([System.IO.Path]::GetTempPath())))
if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    [void]$allowedTempRoots.Add((Resolve-SetupSilentPath $env:RUNNER_TEMP))
}
$workRootAccepted = $false
$workDirectTempChild = $false
foreach ($tempRoot in @($allowedTempRoots | Sort-Object -Unique)) {
    try {
        [void](Assert-SetupSilentChildPath -Root $tempRoot -Candidate $work)
        $workRootAccepted = $true
        if (Test-SetupSilentPathEqual -Left (Split-Path -Parent $work) -Right $tempRoot) {
            $workDirectTempChild = $true
        }
    } catch { }
}
Assert-SetupSilent $workRootAccepted 'work root is beneath the OS temp or GitHub runner temp root'
if (-not $KeepWorkRoot) {
    Assert-SetupSilent (-not $workExistedAtStart) 'auto-cleaned work root did not exist before this harness run'
    Assert-SetupSilent $workDirectTempChild 'auto-cleaned work root is a direct child of an approved temporary root'
    Assert-SetupSilent ((Split-Path -Leaf $work) -match '^clusteryourcodex-setup-silent-[0-9a-f]{32}$') 'auto-cleaned work root uses the harness-owned GUID name'
}
[void](Assert-SetupSilentChildPath -Root $localAppData -Candidate $installRoot)
[void](Assert-SetupSilentChildPath -Root $localAppData -Candidate $dataRoot)
Assert-SetupSilent (-not $work.StartsWith($installRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) 'work root is outside the install root'
Assert-SetupSilent (-not $work.StartsWith($dataRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) 'work root is outside the data root'

Assert-SetupSilent (Test-Path -LiteralPath $setup -PathType Leaf) "Setup.exe exists: $setup"
$setupItem = Get-Item -LiteralPath $setup -Force
Assert-SetupSilent (($setupItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) 'Setup.exe is not a reparse point'
$setupBytes = [System.IO.File]::ReadAllBytes($setup)
Assert-SetupSilent ($setupBytes.Length -ge 4096 -and $setupBytes[0] -eq 0x4d -and $setupBytes[1] -eq 0x5a) 'Setup.exe is a PE executable'
$sidecarPath = $setup + '.sha256'
Assert-SetupSilent (Test-Path -LiteralPath $sidecarPath -PathType Leaf) 'Setup.exe SHA-256 sidecar exists'
$setupHash = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToLowerInvariant()
$sidecarLine = (Get-Content -LiteralPath $sidecarPath -Raw).Trim()
Assert-SetupSilent ($sidecarLine -match '^[0-9a-fA-F]{64}  [^/\\\r\n]+$') 'Setup.exe sidecar has the canonical format'
$expectedSidecar = "$setupHash  $([System.IO.Path]::GetFileName($setup))"
Assert-SetupSilent ([string]::Equals($sidecarLine, $expectedSidecar, [System.StringComparison]::OrdinalIgnoreCase)) 'Setup.exe sidecar matches the executable'
$signatureStatus = [string](Get-AuthenticodeSignature -LiteralPath $setup).Status

Assert-SetupSilent (Test-Path -LiteralPath $package -PathType Container) 'matching staged package exists'
$packageItem = Get-Item -LiteralPath $package -Force
Assert-SetupSilent (($packageItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) 'matching staged package is not a reparse point'
$packageManifest = Join-Path $package 'preview-manifest.json'
$packagePayload = Join-Path $package 'payload'
$packageCoordinator = Join-Path $package 'Invoke-ClusterYourCodexLifecycle.ps1'
Assert-SetupSilent (Test-Path -LiteralPath $packageManifest -PathType Leaf) 'matching preview manifest exists'
Assert-SetupSilent (Test-Path -LiteralPath $packagePayload -PathType Container) 'matching payload exists'
Assert-SetupSilent (Test-Path -LiteralPath $packageCoordinator -PathType Leaf) 'matching lifecycle coordinator exists'
$previewManifest = Read-SetupSilentJson -Path $packageManifest -MaximumBytes 8MB
Assert-SetupSilent ([string]$previewManifest.schemaVersion -ceq $script:PreviewManifestSchema) 'matching preview manifest schema is current'
$expectedPackageManifestSha256 = (Get-FileHash -LiteralPath $packageManifest -Algorithm SHA256).Hash.ToLowerInvariant()

$taskBefore = @(Get-SetupSilentTaskSnapshot)
$firewallBefore = @(Get-SetupSilentFirewallSnapshot)
$listenersBefore = @(Get-SetupSilentListeners)
$processesBefore = @(Get-SetupSilentProductProcesses)
Assert-SetupSilent (-not (Test-Path -LiteralPath $installRoot)) 'disposable install root starts absent'
Assert-SetupSilent (-not (Test-Path -LiteralPath $dataRoot)) 'disposable data root starts absent'
Assert-SetupSilent (-not (Test-Path -LiteralPath $script:UninstallRegistryPath)) 'uninstall registration starts absent'
Assert-SetupSilent ($taskBefore.Count -eq 0) 'product Scheduled Tasks start absent'
Assert-SetupSilent ($firewallBefore.Count -eq 0) 'product firewall rules start absent'
Assert-SetupSilent ($listenersBefore.Count -eq 0) 'product ports start unused'
Assert-SetupSilent ($processesBefore.Count -eq 0) 'product processes start absent'
$preflightComplete = $true

[void](New-Item -ItemType Directory -Path $logRoot -Force)
if (Test-Path -LiteralPath $lifecycleDiagnosticPath) {
    $staleDiagnostic = Get-Item -LiteralPath $lifecycleDiagnosticPath -Force -ErrorAction Stop
    Assert-SetupSilent (-not $staleDiagnostic.PSIsContainer -and
        ($staleDiagnostic.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) 'stale Setup lifecycle diagnostic is a regular file before removal'
    [System.IO.File]::Delete($lifecycleDiagnosticPath)
}
Assert-SetupSilent (-not (Test-Path -LiteralPath $lifecycleDiagnosticPath)) 'Setup lifecycle diagnostic starts absent for this invocation'
$operations = New-Object System.Collections.Generic.List[object]
$primaryFailure = $null
$cleanupFailures = New-Object System.Collections.Generic.List[string]
$result = $null
$formalUninstallCompleted = $false

try {
    $setupInvocationStartedAt = [DateTimeOffset]::UtcNow
    $operations.Add((Invoke-SetupSilentBoundedProcess `
        -FilePath $setup `
        -ArgumentList @('/S') `
        -LogRoot $logRoot `
        -Label 'setup-silent' `
        -TimeoutSeconds $LifecycleTimeoutSeconds `
        -WorkingDirectory (Split-Path -Parent $setup) `
        -AssertNoNewVisiblePowerShellWindow `
        -EnvironmentVariables @{ CYC_SETUP_DIAGNOSTIC_LOG = $lifecycleDiagnosticPath }))

    $setupLifecycleDiagnostic = Read-SetupSilentJson -Path $lifecycleDiagnosticPath -MaximumBytes 1MB
    Assert-SetupSilent ([string]$setupLifecycleDiagnostic.schemaVersion -ceq 'cyc.dev/setup-lifecycle-diagnostic/v1') 'Setup lifecycle diagnostic schema is current'
    Assert-SetupSilent ([string]$setupLifecycleDiagnostic.status -ceq 'succeeded') 'Setup lifecycle reports success independently of the NSIS exit code'
    Assert-SetupSilent ([string]$setupLifecycleDiagnostic.requestedAction -ceq 'Install') 'Setup lifecycle diagnostic binds the Install action'
    Assert-SetupSilent ([string]$setupLifecycleDiagnostic.packageManifestSha256 -ceq $expectedPackageManifestSha256) 'Setup.exe installed the exact supplied self-contained package manifest'
    $diagnosticRecordedAt = [DateTimeOffset]::MinValue
    Assert-SetupSilent ([string]$setupLifecycleDiagnostic.recordedAtUtc -cmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}(?:Z|[+-]\d{2}:\d{2})$' -and
        [DateTimeOffset]::TryParse(
            [string]$setupLifecycleDiagnostic.recordedAtUtc,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$diagnosticRecordedAt
        )) 'Setup lifecycle diagnostic has a strict round-trip timestamp'
    Assert-SetupSilent ($diagnosticRecordedAt -ge $setupInvocationStartedAt -and $diagnosticRecordedAt -le [DateTimeOffset]::UtcNow.AddMinutes(1)) 'Setup lifecycle diagnostic was freshly written by this invocation'

    # NSIS uses Exec for the interactive success launch. Give that asynchronous
    # branch a deterministic window so this assertion catches regressions.
    Start-Sleep -Seconds 2
    $guiProcesses = @(Get-SetupSilentProductProcesses | Where-Object {
        [string]$_.name -ceq 'ClusterYourCodex' -and $_.path -and
        $_.path.StartsWith($installRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
    })
    Assert-SetupSilent ($guiProcesses.Count -eq 0) 'Setup.exe /S does not launch the GUI'

    $manifest = Assert-SetupSilentManifest `
        -ManifestPath $manifestPath `
        -InstallRoot $installRoot `
        -DataRoot $dataRoot `
        -ExpectedAction Install `
        -ExpectedSid $identitySid `
        -ExpectedProfile $profile `
        -ExpectedLocalAppData $localAppData
    [void](Assert-SetupSilentUninstallRegistration -InstallRoot $installRoot -DataRoot $dataRoot)
    [void](Assert-SetupSilentControllerTask -InstallRoot $installRoot -ExpectedSid $identitySid)
    $runtime = Assert-SetupSilentControllerRuntime -InstallRoot $installRoot
    [void](Assert-SetupSilentFirewall -Manifest $manifest)
    $installLifecycleEvidence = Assert-SetupSilentAppliedLifecycleEvidence `
        -Manifest $manifest `
        -ExpectedAction Install `
        -InstallRoot $installRoot `
        -DataRoot $dataRoot `
        -ExpectedSid $identitySid `
        -ExpectedProfile $profile `
        -ExpectedLocalAppData $localAppData `
        -ExpectedRuleName $expectedRuleName
    $receiptsAfterInstall = @(Get-SetupSilentFirewallReceiptSnapshot -DataRoot $dataRoot)
    Assert-SetupSilent ($receiptsAfterInstall.Count -eq 1) 'Install publishes exactly one durable firewall receipt in a fresh profile'
    Assert-SetupSilent ([string]$receiptsAfterInstall[0].transactionId -ceq [string]$installLifecycleEvidence.transactionId) 'Install receipt inventory contains the committed transaction'
    foreach ($probe in @(Invoke-SetupSilentProbes -InstallRoot $installRoot -WorkRoot $work -LogRoot $logRoot -Prefix 'installed')) {
        $operations.Add($probe)
    }

    $certificatePath = Resolve-SetupSilentPath ([string]$manifest.managedWorker.certificatePath)
    $privateKeyPath = Resolve-SetupSilentPath ([string]$manifest.managedWorker.privateKeyPath)
    [void](Assert-SetupSilentChildPath -Root $dataRoot -Candidate $certificatePath)
    [void](Assert-SetupSilentChildPath -Root $dataRoot -Candidate $privateKeyPath)
    Assert-SetupSilent (Test-Path -LiteralPath $certificatePath -PathType Leaf) 'TLS certificate exists before Repair'
    Assert-SetupSilent (Test-Path -LiteralPath $privateKeyPath -PathType Leaf) 'TLS private key exists before Repair'
    $certificateHashBefore = (Get-FileHash -LiteralPath $certificatePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $privateKeyHashBefore = (Get-FileHash -LiteralPath $privateKeyPath -Algorithm SHA256).Hash.ToLowerInvariant()

    $cliRecord = Get-SetupSilentManifestFile -Manifest $manifest -RelativePath 'cyc.exe'
    $cliPath = Join-Path $installRoot 'cyc.exe'
    $tamperBytes = [System.Text.Encoding]::UTF8.GetBytes("`ncyc-repair-regression-$([Guid]::NewGuid().ToString('N'))")
    $stream = [System.IO.File]::Open($cliPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    try { $stream.Write($tamperBytes, 0, $tamperBytes.Length) } finally { $stream.Dispose() }
    $tamperedHash = (Get-FileHash -LiteralPath $cliPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-SetupSilent ($tamperedHash -cne ([string]$cliRecord.sha256).ToLowerInvariant()) 'Repair fixture actually changes the installed CLI'

    $operations.Add((Invoke-SetupSilentBoundedProcess `
        -FilePath $windowsPowerShell `
        -ArgumentList @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $packageCoordinator,
            '-Action', 'Repair',
            '-BundleRoot', $packagePayload,
            '-PackageRoot', $package,
            '-PackageManifest', $packageManifest,
            '-PackageExecutable', $setup,
            '-NoLaunch', '-Quiet'
        ) `
        -LogRoot $logRoot `
        -Label 'repair' `
        -TimeoutSeconds $LifecycleTimeoutSeconds `
        -WorkingDirectory $package))

    $manifestAfterRepair = Assert-SetupSilentManifest `
        -ManifestPath $manifestPath `
        -InstallRoot $installRoot `
        -DataRoot $dataRoot `
        -ExpectedAction Repair `
        -ExpectedSid $identitySid `
        -ExpectedProfile $profile `
        -ExpectedLocalAppData $localAppData
    $cliHashAfterRepair = (Get-FileHash -LiteralPath $cliPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-SetupSilent ($cliHashAfterRepair -ceq ([string]$cliRecord.sha256).ToLowerInvariant()) 'Repair restores the corrupted installed CLI'
    Assert-SetupSilent ((Get-FileHash -LiteralPath $certificatePath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $certificateHashBefore) 'Repair preserves the TLS certificate identity'
    Assert-SetupSilent ((Get-FileHash -LiteralPath $privateKeyPath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $privateKeyHashBefore) 'Repair preserves the TLS private key identity'
    [void](Assert-SetupSilentControllerTask -InstallRoot $installRoot -ExpectedSid $identitySid)
    $runtimeAfterRepair = Assert-SetupSilentControllerRuntime -InstallRoot $installRoot
    [void](Assert-SetupSilentFirewall -Manifest $manifestAfterRepair)
    [void](Assert-SetupSilentUninstallRegistration -InstallRoot $installRoot -DataRoot $dataRoot)
    $firstRepairLifecycleEvidence = Assert-SetupSilentAppliedLifecycleEvidence `
        -Manifest $manifestAfterRepair `
        -ExpectedAction Repair `
        -InstallRoot $installRoot `
        -DataRoot $dataRoot `
        -ExpectedSid $identitySid `
        -ExpectedProfile $profile `
        -ExpectedLocalAppData $localAppData `
        -ExpectedRuleName $expectedRuleName
    Assert-SetupSilent ([string]$firstRepairLifecycleEvidence.transactionId -cne [string]$installLifecycleEvidence.transactionId) 'first Repair uses a new firewall transaction'
    $receiptsAfterFirstRepair = @(Get-SetupSilentFirewallReceiptSnapshot -DataRoot $dataRoot)
    Assert-SetupSilentReceiptSnapshotPreserved -Before $receiptsAfterInstall -After $receiptsAfterFirstRepair -Label 'first Repair'
    Assert-SetupSilent ($receiptsAfterFirstRepair.Count -eq ($receiptsAfterInstall.Count + 1)) 'first Repair adds exactly one durable firewall receipt'
    Assert-SetupSilent (@($receiptsAfterFirstRepair | Where-Object { [string]$_.transactionId -ceq [string]$firstRepairLifecycleEvidence.transactionId }).Count -eq 1) 'first Repair receipt inventory contains the new transaction'
    foreach ($probe in @(Invoke-SetupSilentProbes -InstallRoot $installRoot -WorkRoot $work -LogRoot $logRoot -Prefix 'repaired')) {
        $operations.Add($probe)
    }

    $secondTamperBytes = [System.Text.Encoding]::UTF8.GetBytes("`ncyc-second-repair-regression-$([Guid]::NewGuid().ToString('N'))")
    $secondTamperStream = [System.IO.File]::Open($cliPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    try { $secondTamperStream.Write($secondTamperBytes, 0, $secondTamperBytes.Length) } finally { $secondTamperStream.Dispose() }
    $secondTamperedHash = (Get-FileHash -LiteralPath $cliPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-SetupSilent ($secondTamperedHash -cne ([string]$cliRecord.sha256).ToLowerInvariant()) 'second Repair fixture changes the installed CLI again'

    $operations.Add((Invoke-SetupSilentBoundedProcess `
        -FilePath $windowsPowerShell `
        -ArgumentList @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $packageCoordinator,
            '-Action', 'Repair',
            '-BundleRoot', $packagePayload,
            '-PackageRoot', $package,
            '-PackageManifest', $packageManifest,
            '-PackageExecutable', $setup,
            '-NoLaunch', '-Quiet'
        ) `
        -LogRoot $logRoot `
        -Label 'repair-second' `
        -TimeoutSeconds $LifecycleTimeoutSeconds `
        -WorkingDirectory $package))

    $manifestAfterSecondRepair = Assert-SetupSilentManifest `
        -ManifestPath $manifestPath `
        -InstallRoot $installRoot `
        -DataRoot $dataRoot `
        -ExpectedAction Repair `
        -ExpectedSid $identitySid `
        -ExpectedProfile $profile `
        -ExpectedLocalAppData $localAppData
    $cliRecordAfterSecondRepair = Get-SetupSilentManifestFile -Manifest $manifestAfterSecondRepair -RelativePath 'cyc.exe'
    $cliHashAfterSecondRepair = (Get-FileHash -LiteralPath $cliPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-SetupSilent ($cliHashAfterSecondRepair -ceq ([string]$cliRecordAfterSecondRepair.sha256).ToLowerInvariant()) 'second Repair restores the corrupted installed CLI again'
    Assert-SetupSilent ((Get-FileHash -LiteralPath $certificatePath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $certificateHashBefore) 'second Repair preserves the TLS certificate identity'
    Assert-SetupSilent ((Get-FileHash -LiteralPath $privateKeyPath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $privateKeyHashBefore) 'second Repair preserves the TLS private key identity'
    [void](Assert-SetupSilentControllerTask -InstallRoot $installRoot -ExpectedSid $identitySid)
    $runtimeAfterSecondRepair = Assert-SetupSilentControllerRuntime -InstallRoot $installRoot
    [void](Assert-SetupSilentFirewall -Manifest $manifestAfterSecondRepair)
    [void](Assert-SetupSilentUninstallRegistration -InstallRoot $installRoot -DataRoot $dataRoot)
    $secondRepairLifecycleEvidence = Assert-SetupSilentAppliedLifecycleEvidence `
        -Manifest $manifestAfterSecondRepair `
        -ExpectedAction Repair `
        -InstallRoot $installRoot `
        -DataRoot $dataRoot `
        -ExpectedSid $identitySid `
        -ExpectedProfile $profile `
        -ExpectedLocalAppData $localAppData `
        -ExpectedRuleName $expectedRuleName
    Assert-SetupSilent ([string]$secondRepairLifecycleEvidence.transactionId -cne [string]$firstRepairLifecycleEvidence.transactionId) 'second Repair uses another new firewall transaction'
    Assert-SetupSilent ([string]$secondRepairLifecycleEvidence.transactionId -cne [string]$installLifecycleEvidence.transactionId) 'second Repair does not reuse the Install transaction'
    $receiptsAfterSecondRepair = @(Get-SetupSilentFirewallReceiptSnapshot -DataRoot $dataRoot)
    Assert-SetupSilentReceiptSnapshotPreserved -Before $receiptsAfterFirstRepair -After $receiptsAfterSecondRepair -Label 'second Repair'
    Assert-SetupSilent ($receiptsAfterSecondRepair.Count -eq ($receiptsAfterFirstRepair.Count + 1)) 'second Repair adds exactly one durable firewall receipt'
    Assert-SetupSilent (@($receiptsAfterSecondRepair | Where-Object { [string]$_.transactionId -ceq [string]$secondRepairLifecycleEvidence.transactionId }).Count -eq 1) 'second Repair receipt inventory contains the new transaction'

    $installedUninstaller = Join-Path $installRoot 'installer\Uninstall-ClusterYourCodex.ps1'
    Assert-SetupSilent (Test-Path -LiteralPath $installedUninstaller -PathType Leaf) 'installed uninstaller exists before product uninstall'
    $operations.Add((Invoke-SetupSilentBoundedProcess `
        -FilePath $windowsPowerShell `
        -ArgumentList @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $installedUninstaller, '-Quiet'
        ) `
        -LogRoot $logRoot `
        -Label 'installed-uninstaller' `
        -TimeoutSeconds $LifecycleTimeoutSeconds `
        -WorkingDirectory $work))
    $formalUninstallCompleted = $true
    Wait-SetupSilentPortsReleased

    Assert-SetupSilent (-not (Test-Path -LiteralPath $installRoot)) 'installed uninstaller removes the install root'
    Assert-SetupSilent (-not (Test-Path -LiteralPath $script:UninstallRegistryPath)) 'installed uninstaller removes Apps & Features registration'
    Assert-SetupSilent (@(Get-SetupSilentProductProcesses).Count -eq 0) 'installed uninstaller stops product processes'
    Assert-SetupSilent (@(Get-SetupSilentListeners).Count -eq 0) 'installed uninstaller releases product ports'
    $taskAfterProductUninstall = @(Get-SetupSilentTaskSnapshot)
    $firewallAfterProductUninstall = @(Get-SetupSilentFirewallSnapshot)
    Assert-SetupSilent (($taskBefore | ConvertTo-Json -Depth 6 -Compress) -ceq ($taskAfterProductUninstall | ConvertTo-Json -Depth 6 -Compress)) 'installed uninstaller restores the pre-test Scheduled Task state'
    Assert-SetupSilent (($firewallBefore | ConvertTo-Json -Depth 6 -Compress) -ceq ($firewallAfterProductUninstall | ConvertTo-Json -Depth 6 -Compress)) 'installed uninstaller restores the pre-test firewall state'
    Assert-SetupSilent (Test-Path -LiteralPath $dataRoot -PathType Container) 'default installed uninstaller preserves user data'

    $receiptsAfterUninstall = @(Get-SetupSilentFirewallReceiptSnapshot -DataRoot $dataRoot)
    Assert-SetupSilentReceiptSnapshotPreserved -Before $receiptsAfterSecondRepair -After $receiptsAfterUninstall -Label 'Uninstall'
    Assert-SetupSilent ($receiptsAfterUninstall.Count -eq ($receiptsAfterSecondRepair.Count + 1)) 'Uninstall adds exactly one durable firewall receipt'
    $newUninstallReceipts = @($receiptsAfterUninstall | Where-Object {
        $candidate = $_
        @($receiptsAfterSecondRepair | Where-Object {
            [string]::Equals([string]$_.path, [string]$candidate.path, [System.StringComparison]::OrdinalIgnoreCase)
        }).Count -eq 0
    })
    Assert-SetupSilent ($newUninstallReceipts.Count -eq 1) 'Uninstall publishes one new transaction receipt'
    $uninstallReceiptPreview = Read-SetupSilentJson -Path $newUninstallReceipts[0].path -MaximumBytes $script:MaximumFirewallReceiptBytes
    $controllerRecordBeforeUninstall = Get-SetupSilentManifestFile -Manifest $manifestAfterSecondRepair -RelativePath 'cyc-controller.exe'
    $uninstallReceiptEvidence = Assert-SetupSilentFirewallReceipt `
        -ReceiptPath $newUninstallReceipts[0].path `
        -ExpectedAction Remove `
        -ExpectedTransactionId ([string]$newUninstallReceipts[0].transactionId) `
        -ExpectedRequestSha256 ([string]$uninstallReceiptPreview.requestSha256) `
        -ExpectedReceiptSha256 ([string]$newUninstallReceipts[0].sha256) `
        -ExpectedProgramSha256 ([string]$controllerRecordBeforeUninstall.sha256) `
        -InstallRoot $installRoot `
        -ExpectedSid $identitySid `
        -ExpectedProfile $profile `
        -ExpectedLocalAppData $localAppData `
        -ExpectedRuleName $expectedRuleName
    $uninstallJournalState = Assert-SetupSilentJournalRetiredOrComplete `
        -JournalPath $journalPath `
        -ExpectedAction Uninstall `
        -ExpectedTransactionId ([string]$uninstallReceiptEvidence.transactionId) `
        -ExpectedRequestSha256 ([string]$uninstallReceiptEvidence.requestSha256) `
        -ExpectedReceiptPath ([string]$uninstallReceiptEvidence.path) `
        -InstallRoot $installRoot `
        -DataRoot $dataRoot `
        -ExpectedSid $identitySid `
        -ExpectedProfile $profile `
        -ExpectedLocalAppData $localAppData

    # The installed uninstaller removes itself. Reuse the matching staged
    # coordinator to prove the already-absent path returns before elevation.
    $operations.Add((Invoke-SetupSilentBoundedProcess `
        -FilePath $windowsPowerShell `
        -ArgumentList @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $packageCoordinator,
            '-Action', 'Uninstall',
            '-NoLaunch', '-Quiet'
        ) `
        -LogRoot $logRoot `
        -Label 'uninstall-repeated' `
        -TimeoutSeconds $LifecycleTimeoutSeconds `
        -WorkingDirectory $package))
    $receiptsAfterRepeatedUninstall = @(Get-SetupSilentFirewallReceiptSnapshot -DataRoot $dataRoot)
    Assert-SetupSilentReceiptSnapshotPreserved -Before $receiptsAfterUninstall -After $receiptsAfterRepeatedUninstall -Label 'repeated Uninstall'
    Assert-SetupSilent ($receiptsAfterRepeatedUninstall.Count -eq $receiptsAfterUninstall.Count) 'repeated Uninstall is receipt-idempotent and does not invoke another firewall mutation'
    $repeatedUninstallJournalState = Assert-SetupSilentJournalRetiredOrComplete `
        -JournalPath $journalPath `
        -ExpectedAction Uninstall `
        -ExpectedTransactionId ([string]$uninstallReceiptEvidence.transactionId) `
        -ExpectedRequestSha256 ([string]$uninstallReceiptEvidence.requestSha256) `
        -ExpectedReceiptPath ([string]$uninstallReceiptEvidence.path) `
        -InstallRoot $installRoot `
        -DataRoot $dataRoot `
        -ExpectedSid $identitySid `
        -ExpectedProfile $profile `
        -ExpectedLocalAppData $localAppData
    Assert-SetupSilent (-not (Test-Path -LiteralPath $installRoot)) 'repeated Uninstall leaves the install root absent'
    Assert-SetupSilent (-not (Test-Path -LiteralPath $manifestPath)) 'repeated Uninstall leaves the install manifest absent'
    Assert-SetupSilent (-not (Test-Path -LiteralPath $script:UninstallRegistryPath)) 'repeated Uninstall leaves Apps & Features registration absent'
    $taskAfterRepeatedUninstall = @(Get-SetupSilentTaskSnapshot)
    $firewallAfterRepeatedUninstall = @(Get-SetupSilentFirewallSnapshot)
    Assert-SetupSilent (($taskBefore | ConvertTo-Json -Depth 6 -Compress) -ceq ($taskAfterRepeatedUninstall | ConvertTo-Json -Depth 6 -Compress)) 'repeated Uninstall leaves the exact Scheduled Task state restored'
    Assert-SetupSilent (($firewallBefore | ConvertTo-Json -Depth 6 -Compress) -ceq ($firewallAfterRepeatedUninstall | ConvertTo-Json -Depth 6 -Compress)) 'repeated Uninstall leaves the exact firewall state restored'

    $ownedData = Assert-SetupSilentOwnedRoot -Path $dataRoot -Expected $dataRoot -Parent $localAppData
    Remove-Item -LiteralPath $ownedData -Recurse -Force -ErrorAction Stop
    Assert-SetupSilent (-not (Test-Path -LiteralPath $dataRoot)) 'disposable test harness removes preserved user data separately from product uninstall'

    $result = [PSCustomObject]@{
        schemaVersion = 'cyc.dev/setup-silent-test/v1'
        status = 'passed'
        setupPath = $setup
        setupSha256 = $setupHash
        authenticodeStatus = $signatureStatus
        packageRoot = $package
        packageManifestSha256 = (Get-FileHash -LiteralPath $packageManifest -Algorithm SHA256).Hash.ToLowerInvariant()
        installRoot = $installRoot
        dataRoot = $dataRoot
        controllerProcessIdBeforeRepair = $runtime.processId
        controllerProcessIdAfterRepair = $runtimeAfterRepair.processId
        controllerProcessIdAfterSecondRepair = $runtimeAfterSecondRepair.processId
        lifecycleEvidence = [ordered]@{
            install = $installLifecycleEvidence
            firstRepair = $firstRepairLifecycleEvidence
            secondRepair = $secondRepairLifecycleEvidence
            uninstall = [ordered]@{
                transactionId = [string]$uninstallReceiptEvidence.transactionId
                requestSha256 = [string]$uninstallReceiptEvidence.requestSha256
                receiptPath = [string]$uninstallReceiptEvidence.path
                receiptSha256 = [string]$uninstallReceiptEvidence.sha256
                journalState = [string]$uninstallJournalState
                repeatedJournalState = [string]$repeatedUninstallJournalState
            }
        }
        # Windows PowerShell 5.1 cannot bind @($genericListOfObject) while
        # constructing a PSCustomObject ("Argument types do not match").
        # Materialize the generic list explicitly before result serialization.
        operations = $operations.ToArray()
        steps = @(
            'setup-sidecar',
            'setup-silent',
            'no-gui-launch',
            'install-manifest-file-hashes',
            'controller-task',
            'controller-health',
            'managed-worker-listener',
            'firewall-filters',
            'apps-and-features',
            'worker-probe',
            'cli-help',
            'repair-corrupted-file',
            'repair-preserves-tls-identity',
            'repair-repeat-corrupted-file',
            'repair-repeat-preserves-tls-identity',
            'lifecycle-transaction-receipts',
            'lifecycle-complete-journal-retirement',
            'installed-uninstaller',
            'uninstall-remove-receipt',
            'uninstall-preserves-apply-receipts',
            'uninstall-repeat-idempotent',
            'task-restore',
            'firewall-restore',
            'product-preserves-data',
            'harness-cleans-disposable-data'
        )
        logs = $logRoot
    }
} catch {
    $primaryFailure = $_
} finally {
    if ($preflightComplete -and $script:BoundedProcessTerminationUncertain) {
        [void]$cleanupFailures.Add('a timed-out lifecycle process could not be proven terminated; destructive fallback cleanup was skipped on the disposable runner')
    } elseif ($preflightComplete) {
        if (-not $formalUninstallCompleted -and (Test-Path -LiteralPath $installRoot -PathType Container)) {
            $fallbackUninstaller = Join-Path $installRoot 'installer\Uninstall-ClusterYourCodex.ps1'
            if (Test-Path -LiteralPath $fallbackUninstaller -PathType Leaf) {
                try {
                    [void](Invoke-SetupSilentBoundedProcess `
                        -FilePath $windowsPowerShell `
                        -ArgumentList @(
                            '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                            '-File', $fallbackUninstaller, '-Quiet'
                        ) `
                        -LogRoot $logRoot `
                        -Label 'cleanup-installed-uninstaller' `
                        -TimeoutSeconds $LifecycleTimeoutSeconds `
                        -WorkingDirectory $work)
                } catch {
                    [void]$cleanupFailures.Add("formal cleanup uninstall failed: $($_.Exception.Message)")
                }
            }
        }
        try { Stop-SetupSilentOwnedProcesses -InstallRoot $installRoot } catch {
            [void]$cleanupFailures.Add("owned process cleanup failed: $($_.Exception.Message)")
        }
        try { Remove-SetupSilentOwnedTasks -InstallRoot $installRoot } catch {
            [void]$cleanupFailures.Add("owned Scheduled Task cleanup failed: $($_.Exception.Message)")
        }
        try { Remove-SetupSilentOwnedFirewall -ExpectedProgram $expectedController -ExpectedRuleName $expectedRuleName } catch {
            [void]$cleanupFailures.Add("owned firewall cleanup failed: $($_.Exception.Message)")
        }
        try { Remove-SetupSilentOwnedRegistration -InstallRoot $installRoot } catch {
            [void]$cleanupFailures.Add("owned uninstall registration cleanup failed: $($_.Exception.Message)")
        }
        foreach ($entry in @(
            [PSCustomObject]@{ path = $installRoot; expected = $installRoot },
            [PSCustomObject]@{ path = $dataRoot; expected = $dataRoot }
        )) {
            if (Test-Path -LiteralPath $entry.path) {
                try {
                    $owned = Assert-SetupSilentOwnedRoot -Path $entry.path -Expected $entry.expected -Parent $localAppData
                    Remove-Item -LiteralPath $owned -Recurse -Force -ErrorAction Stop
                } catch {
                    [void]$cleanupFailures.Add("owned path cleanup failed for $($entry.path): $($_.Exception.Message)")
                }
            }
        }
        try { Wait-SetupSilentPortsReleased -TimeoutSeconds 30 } catch {
            [void]$cleanupFailures.Add($_.Exception.Message)
        }
        try {
            Assert-SetupSilent (@(Get-SetupSilentTaskSnapshot).Count -eq $taskBefore.Count) 'cleanup restores the pre-test Scheduled Task count'
            Assert-SetupSilent (@(Get-SetupSilentFirewallSnapshot).Count -eq $firewallBefore.Count) 'cleanup restores the pre-test firewall count'
            Assert-SetupSilent (-not (Test-Path -LiteralPath $script:UninstallRegistryPath)) 'cleanup leaves no uninstall registration'
            Assert-SetupSilent (-not (Test-Path -LiteralPath $installRoot)) 'cleanup leaves no install root'
            Assert-SetupSilent (-not (Test-Path -LiteralPath $dataRoot)) 'cleanup leaves no data root'
            Assert-SetupSilent (@(Get-SetupSilentListeners).Count -eq $listenersBefore.Count) 'cleanup restores the pre-test listener count'
            Assert-SetupSilent (@(Get-SetupSilentProductProcesses).Count -eq $processesBefore.Count) 'cleanup restores the pre-test process count'
        } catch {
            [void]$cleanupFailures.Add("final cleanup verification failed: $($_.Exception.Message)")
        }
    }

    $cleanupRecord = [ordered]@{
        schemaVersion = 'cyc.dev/setup-silent-cleanup/v1'
        preflightComplete = $preflightComplete
        productUninstallCompleted = $formalUninstallCompleted
        boundedProcessTerminationUncertain = $script:BoundedProcessTerminationUncertain
        failures = @($cleanupFailures)
        primaryFailure = if ($primaryFailure) {
            [ordered]@{
                message = [string]$primaryFailure.Exception.Message
                exceptionType = [string]$primaryFailure.Exception.GetType().FullName
                fullyQualifiedErrorId = [string]$primaryFailure.FullyQualifiedErrorId
                scriptStackTrace = [string]$primaryFailure.ScriptStackTrace
                positionMessage = [string]$primaryFailure.InvocationInfo.PositionMessage
            }
        } else { $null }
        verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    try {
        if (Test-Path -LiteralPath $work -PathType Container) {
            $cleanupRecord | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $work 'cleanup.json') -Encoding UTF8
        }
    } catch {
        [void]$cleanupFailures.Add("cleanup receipt write failed: $($_.Exception.Message)")
    }
}

if ($primaryFailure) { throw $primaryFailure }
if ($cleanupFailures.Count -gt 0) {
    throw "silent Setup cleanup was incomplete: $($cleanupFailures -join ' | ')."
}
if (-not $result) { throw 'silent Setup smoke produced no result.' }

$result | ConvertTo-Json -Depth 8

if (-not $KeepWorkRoot -and (Test-Path -LiteralPath $work -PathType Container)) {
    $workDeleteAccepted = $false
    foreach ($tempRoot in @($allowedTempRoots | Sort-Object -Unique)) {
        try {
            [void](Assert-SetupSilentChildPath -Root $tempRoot -Candidate $work)
            $workDeleteAccepted = $true
            break
        } catch { }
    }
    Assert-SetupSilent $workDeleteAccepted 'work root remains beneath an approved temporary root'
    Assert-SetupSilent (-not $workExistedAtStart) 'work root was created by this harness run'
    Assert-SetupSilent $workDirectTempChild 'work root remains a direct child of an approved temporary root'
    Assert-SetupSilent ((Split-Path -Leaf $work) -match '^clusteryourcodex-setup-silent-[0-9a-f]{32}$') 'work root retains the harness-owned GUID name'
    Assert-SetupSilentTreeHasNoReparsePoints -Root $work
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction Stop
}
