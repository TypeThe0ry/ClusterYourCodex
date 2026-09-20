# VMware Windows acceptance bootstrap — 2026-09-20

## Media

- Source: Microsoft Windows 11 download page (25H2, Chinese Simplified, x64 multi-edition ISO)
- Local path: `D:\ClusterYourCodex-validation\Windows11.iso`
- Size: `8,543,608,832` bytes
- SHA-256: `7408581E67BC455EBAAFB9230E531ABF45B1C8864A22114A1B03893F897102E4`
- Microsoft published SHA-256 for Chinese Simplified x64: `7408581E67BC455EBAAFB9230E531ABF45B1C8864A22114A1B03893F897102E4`

## VM

- VMX: `D:\ClusterYourCodex-validation\windows11-clean\ClusterYourCodex-Windows11-Clean.vmx`
- Disk: `D:\ClusterYourCodex-validation\windows11-clean\ClusterYourCodex-Windows11-Clean.vmdk`
- Firmware: EFI with Secure Boot enabled
- Resources: 4 vCPU, 8192 MB RAM, 80 GB virtual disk
- Storage: D drive
- Start command: `vmrun -T ws start "D:\ClusterYourCodex-validation\windows11-clean\ClusterYourCodex-Windows11-Clean.vmx" nogui`

## Observed evidence

On 2026-09-20, VMware Workstation reported:

```text
Total running VMs: 1
D:\ClusterYourCodex-validation\windows11-clean\ClusterYourCodex-Windows11-Clean.vmx
```

The first bootstrap attempt exposed two Windows PowerShell/VMX portability defects in the new helper:

1. `utf8NoBOM` is not a valid `Set-Content -Encoding` value in Windows PowerShell 5.1. The helper now writes UTF-8 without BOM through `System.IO.File`.
2. VMX paths must use native Windows separators; JSON-style doubled backslashes made the disk/ISO unresolved. The helper now emits native paths.

Both fixes are included in PR #99. The VM was initially powered on, but later console/log inspection found an EFI CD-ROM boot timeout, VMware `Transport (VMDB) error -14`, and `No operating system was found`. `vmrun list` therefore proves only that the VMware process was registered, not that the guest booted. Windows installation and the full clean-VM lifecycle acceptance remain separate steps and are not claimed by this bootstrap record.

The current VM state is a reproducible bootstrap failure requiring a new start/ISO attachment check before guest installation can proceed. No ClusterYourCodex installer was run inside the guest, and no clean-VM install, repair, rollback, upgrade, or uninstall result is recorded here.
