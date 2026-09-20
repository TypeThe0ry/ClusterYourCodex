[CmdletBinding()]
param(
    [string]$IsoPath = 'D:\ClusterYourCodex-validation\Windows11.iso',
    [string]$VmRoot = 'D:\ClusterYourCodex-validation\windows11-clean',
    [string]$VmName = 'ClusterYourCodex-Windows11-Clean',
    [int]$MemoryMB = 8192,
    [int]$Processors = 4,
    [int]$DiskGB = 80
)

$ErrorActionPreference = 'Stop'

function Fail([string]$Message) {
    Write-Error $Message
    exit 2
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

$vmwareRoot = 'C:\Program Files\VMware\VMware Workstation'
$vdisk = Join-Path $vmwareRoot 'vmware-vdiskmanager.exe'
$vmrun = Join-Path $vmwareRoot 'vmrun.exe'
if (-not (Test-Path -LiteralPath $vdisk -PathType Leaf)) { Fail "VMware vdisk manager not found: $vdisk" }
if (-not (Test-Path -LiteralPath $vmrun -PathType Leaf)) { Fail "VMware vmrun not found: $vmrun" }
if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) {
    Fail "Windows ISO is missing: $IsoPath. Download or place it there before retrying."
}

$iso = Get-Item -LiteralPath $IsoPath
if ($iso.Length -lt 4GB) { Fail "ISO is unexpectedly small ($($iso.Length) bytes): $IsoPath" }
if ($MemoryMB -lt 4096 -or $Processors -lt 2 -or $DiskGB -lt 64) {
    Fail 'Windows 11 acceptance VM requires at least 4096 MB RAM, 2 processors, and 64 GB disk.'
}

New-Item -ItemType Directory -Path $VmRoot -Force | Out-Null
$diskPath = Join-Path $VmRoot "$VmName.vmdk"
$vmxPath = Join-Path $VmRoot "$VmName.vmx"
if (Test-Path -LiteralPath $vmxPath) { Fail "Refusing to overwrite existing VM: $vmxPath" }

& $vdisk -c -s "${DiskGB}G" -a lsilogic -t 0 $diskPath | Out-Host
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $diskPath -PathType Leaf)) {
    Fail "VMware virtual disk creation failed (exit $LASTEXITCODE)."
}

# VMware Workstation's VMX parser expects native Windows paths. Do not JSON-style
# escape backslashes here; doubled separators make the guest disk/ISO unresolved.
$isoEscaped = $IsoPath
$diskEscaped = $diskPath
$vmx = @"
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "20"
displayName = "$VmName"
guestOS = "windows11-64"
memsize = "$MemoryMB"
numvcpus = "$Processors"
firmware = "efi"
efi.secureBoot.enabled = "TRUE"
chipset.useACPI = "TRUE"
scsi0.present = "TRUE"
scsi0.virtualDev = "lsilogic"
scsi0:0.present = "TRUE"
scsi0:0.fileName = "$diskEscaped"
sata0.present = "TRUE"
sata0:1.present = "TRUE"
sata0:1.deviceType = "cdrom-image"
sata0:1.fileName = "$isoEscaped"
ethernet0.present = "TRUE"
ethernet0.connectionType = "nat"
usb.present = "TRUE"
tools.syncTime = "FALSE"
snapshot.disabled = "FALSE"
"@
Write-Utf8NoBom -Path $vmxPath -Content $vmx

$metadata = [ordered]@{
    schemaVersion = 1
    createdAt = [DateTime]::UtcNow.ToString('o')
    vmx = $vmxPath
    iso = $iso.FullName
    isoSha256 = (Get-FileHash -LiteralPath $iso.FullName -Algorithm SHA256).Hash
    disk = $diskPath
    vmrun = $vmrun
    state = 'created-not-started'
}
$metadata | ConvertTo-Json | ForEach-Object { Write-Utf8NoBom -Path (Join-Path $VmRoot 'acceptance-vm.json') -Content $_ }
Write-Output ("Created VM configuration: {0}`nISO SHA-256: {1}`nStart after review: vmrun -T ws start `"{0}`" gui" -f $vmxPath, $metadata.isoSha256)
