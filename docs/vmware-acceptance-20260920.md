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
