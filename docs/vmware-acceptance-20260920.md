# VMware Windows acceptance bootstrap — 2026-09-20

## Media

- Source: Microsoft Windows 11 download page (25H2, Chinese Simplified, x64 multi-edition ISO)
- Local path (redacted): `<validation-root>\Windows11.iso`
- Size: `8,543,608,832` bytes
- SHA-256: `7408581E67BC455EBAAFB9230E531ABF45B1C8864A22114A1B03893F897102E4`
- Microsoft published SHA-256 for Chinese Simplified x64: `7408581E67BC455EBAAFB9230E531ABF45B1C8864A22114A1B03893F897102E4`

## VM

- VMX (redacted): `<validation-root>\windows11-clean\ClusterYourCodex-Windows11-Clean.vmx`
- Disk (redacted): `<validation-root>\windows11-clean\ClusterYourCodex-Windows11-Clean.vmdk`
- Firmware: EFI with Secure Boot enabled
- Resources: 4 vCPU, 8192 MB RAM, 80 GB virtual disk
- Storage: dedicated validation volume
- Start command template: `vmrun -T ws start "<vmx-path>" nogui`

## Observed evidence

On 2026-09-20, VMware Workstation reported:

```text
Total running VMs: 1
<validation-root>\windows11-clean\ClusterYourCodex-Windows11-Clean.vmx
```

The first bootstrap attempt exposed two Windows PowerShell/VMX portability defects in the new helper:

1. `utf8NoBOM` is not a valid `Set-Content -Encoding` value in Windows PowerShell 5.1. The helper now writes UTF-8 without BOM through `System.IO.File`.
2. VMX paths must use native Windows separators; JSON-style doubled backslashes made the disk/ISO unresolved. The helper now emits native paths.

Both fixes are included in PR #99. The VM was initially powered on, but later console/log inspection found an EFI CD-ROM boot timeout, VMware `Transport (VMDB) error -14`, and `No operating system was found`. `vmrun list` therefore proves only that the VMware process was registered, not that the guest booted. Windows installation and the full clean-VM lifecycle acceptance remain separate steps and are not claimed by this bootstrap record.

The current VM state is a reproducible bootstrap failure requiring a new start/ISO attachment check before guest installation can proceed. No ClusterYourCodex installer was run inside the guest, and no clean-VM install, repair, rollback, upgrade, or uninstall result is recorded here.

## Command-line retry — 2026-09-21

The retry was performed entirely with VMware CLI (`vmrun`), without GUI automation:

- A fresh VM was created at `<validation-root>\windows11-clean-retry-20260921` using `scripts/New-ClusterYourCodexWindowsVm.ps1`.
- The original VM and the fresh VM both started with `vmrun -T ws start ... nogui` and returned exit code `0`.
- The same ISO was tested from its validation-volume path, from a system-volume temporary copy with the identical SHA-256, and as a mounted Windows virtual DVD (raw CD-ROM configuration).
- Every variant registered a running `vmware-vmx` process, but the guest log ended with:

```text
CDROM: Connecting sata0:1 ...
Guest: Status upon boot failure: No Media
Guest: About to do EFI boot: EFI VMware Virtual SATA CDROM Drive (1.0)
Guest: Status upon boot failure: Timeout
```

After each attempt, `vmrun -T ws stop ... hard` returned the host to `Total running VMs: 0`. The Windows ISO itself is readable by Windows (`Mount-DiskImage` exposes `CCCOMA_X64FRE_ZH-CN_DV9` and `<mounted-iso-root>\efi\boot\bootx64.efi`), and its hash remains the Microsoft-published value above. These observations identify an optical-media boot failure but do not establish its root cause; they are not evidence of a successful Windows guest boot. The Windows 11 clean-VM installer/lifecycle gate therefore remains open.

Host-specific paths in this record are redacted placeholders, not literal commands or unmodified CLI output. Media hashes, exit codes, and boot errors are retained unchanged.

## Disposable-path retry — 2026-09-22

A disposable copy was created on the D drive with native single-backslash VMX
paths for both the VMDK and ISO. The attempt again used VMware CLI only:

- `vmrun -T ws start ... nogui` returned exit code `0`.
- `vmrun -T ws list` reported the VM as running.
- `vmware.log` recorded `Guest: Status upon boot failure: No Media`, then
  `EFI VMware Virtual SATA CDROM Drive (1.0)` and `Status upon boot failure:
  Time out`.
- `vmrun -T ws stop ... hard` returned the host to zero running VMs.

This confirms a reproducible EFI optical-media boot failure even after the
path correction. No Windows guest boot or installer lifecycle result is
claimed; Issue #2 remains open.

## No-prompt EFI experiment — 2026-09-22

A subsequent CLI-only experiment replaced the EFI El Torito boot image in the
disposable ISO copy with Microsoft's `efisys_noprompt.bin` from the original
media. Before writing, the embedded image at LBA 555 was SHA-256 compared with
the original `efisys.bin`; the image lengths matched. The original downloaded
ISO was not modified. The disposable ISO is modified test media and must not be
represented as matching the original Microsoft whole-ISO hash.

The new boot log progressed beyond the former CD-ROM timeout:

```text
2026-09-22T15:51:07.508Z Guest: Firmware has transitioned to runtime.
2026-09-22T15:51:09.055Z Guest: PVSCSI: driver StorPort v1.3.15.0 starts.
2026-09-22T15:51:09.056Z Guest: Driver=pvscsii, Version=1.3.15.0
```

This supports an unattended optical-boot prompt timeout as the previous
blocker, rather than proving unreadable media. It proves progress into Windows
boot code, not completion of Setup. CLI `captureScreen` failed because guest
login is required. The disposable VM was stopped and `vmrun list` confirmed
zero running VMs. Next work is unattended Setup and guest-side installer
lifecycle evidence; Issue #2 remains open.

## Setup screen diagnosis — 2026-09-23 (Asia/Singapore)

The installed Workstation also provides `vmcli.exe`. Unlike the attempted
`vmrun captureScreen`, its `MKS captureScreenshot <filename>` command succeeded
without guest credentials or VMware Tools. This supplies a CLI-only diagnostic
path before the guest OS is installed:

```powershell
& $vmcli $vmx MKS captureScreenshot $diagnosticPng
```

The captured Windows 11 Setup screen is the **Product key** page, with the
built-in **I don't have a product key** option visible. This is direct evidence
that Setup has booted and is awaiting input; the earlier small VMDK size alone
did not establish a firmware or hardware-requirement failure. A separate private
answer ISO had already been attached, but unattended installation has not been
proven: determine whether Setup consumed the answer file and how to suppress
this prompt through supported installation settings. Do not publish the answer
file, guest credentials, or screenshots containing them.

VMware logs also reported `SecureBootModeDisabled`; successful vTPM provisioning
has not been established. These remain separate checks, not a proven explanation
for the currently observed product-key prompt. No hardware-check bypass or
Windows activation workaround was applied. No ClusterYourCodex installer has
run inside this guest yet, so Issue #2 remains open.

### Confirmed next blocker: TPM 2.0

CLI keyboard delivery was verified using `MKS sendKeyEvent 0x2b0007 0`
(Tab) and `0x280007 0` (Enter). The HID encoding uses the keyboard usage
in the upper word and usage page 7 in the lower word. `sendKeySequence`
accepts literal text; `{TAB}` is not a verified special-key syntax.

After selecting the built-in **I don't have a product key** option, Setup
explicitly displayed **This PC must support TPM 2.0**. This establishes an
actual hardware-requirement blocker, rather than an inference from disk size.

A powered-off disposable-VM experiment added `vtpm.present = "TRUE"`.
Power-on failed with these VMware log messages:

```text
msg.vtpm.poweron.notEncrypted: The virtual machine must be encrypted.
msg.vtpm.initfail: Virtual TPM initialization failed.
```

The experimental setting was removed, and `vmrun list` confirmed zero running
VMs. `vmcli VM Create` with `windows11-64` also produced a separate probe VM
without TPM/encryption entries; selecting a guest type alone does not provision
the required device. Next work requires a supported command-line provisioning
path for encrypted vTPM state. No Windows hardware checks were bypassed.

## Disposable compatibility installation — 2026-09-23

The earlier no-bypass observations above describe earlier attempts. To unblock
application testing without claiming supported Windows 11 hardware compliance,
the disposable VM was subsequently booted through `vmrun ... start ... nogui`.
Using `vmcli MKS sendKeyEvent`, Shift+F10 opened the guest WinPE command prompt.
The following command succeeded **inside the disposable guest**, not the host:

```text
reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f
```

After choosing Setup's built-in no-product-key option, Setup passed the TPM
screen but displayed no disks with the legacy `lsilogic` SCSI controller.
The VM was stopped, its VMX backed up, and the same existing VMDK attached as
`sata0:0` instead of `scsi0:0`. After reboot and reapplying the guest-only TPM
exception, unattended Setup proceeded to **Installing Windows 11, 5%**.
`New-ClusterYourCodexWindowsVm.ps1` now uses SATA for the installation disk.

This proves installation began, not that the OS installation or application
lifecycle finished. The VM remains a compatibility test environment with a
documented TPM exception; it does not establish Windows 11 hardware compliance.
No activation mechanism was changed. The original downloaded ISO, host OS,
published release, and other VM disks were not modified by this experiment.

### First boot and network configuration

Windows completed its installation phases and reached region/keyboard OOBE.
The unspecified default network adapter produced no usable network on that
screen. Changing it to `e1000e` alone failed VM power-on with
`msg.pci.noslotavail: No PCIe slot available for Ethernet0`. Adding a PCI bridge
and a `pcieRootPort` bridge with eight functions, and clearing the old Ethernet
PCI slot assignment, restored successful power-on. OOBE then advanced beyond
the network-driver page to checking updates. The VM helper now emits this
adapter/bridge combination as well as the SATA disk attachment.

This is guest installation/OOBE evidence, not a completed desktop login,
application installation, or live ClusterYourCodex job result.
