# VMware CLI installation record — 2026-09-24

This record captures the disposable Windows validation VM created on 2026-09-24.
It is intentionally separate from the stable release and does not modify the
published `v0.0.1` tag or its assets.

## Host and media

- VMware Workstation CLI: `vmrun` 1.17.0.25688693
- Validation storage: `D:\ClusterYourCodex-validation`
- Windows media: Windows 11 25H2 English x64 multi-edition ISO
- ISO size: `8,471,603,200` bytes
- ISO SHA-256:
  `768984706B909479417B2368438909440F2967FF05C6A9195ED2667254E465E3`
- The ISO was downloaded from Microsoft's Windows 11 download page and the
  hash matches the English x64 value shown by Microsoft's verification panel.

## VM created and started

The existing retry VM was left untouched. A full VMware clone was created at
the following disposable path (the path is intentionally local and is not
embedded in product payloads):

```text
<validation-root>\windows11-cluster-cli-20260924\
```

The cloned VM was configured with:

- Windows 11 64-bit guest profile
- 8 GiB RAM and 4 vCPUs
- EFI firmware
- NAT networking
- the verified ISO attached as a CD-ROM
- the cloned disk kept as the VM's isolated writable disk

It was started entirely through the VMware CLI:

```powershell
vmrun -T ws start "<validation-root>\windows11-cluster-cli-20260924\ClusterYourCodex-Windows11-CLI.vmx" nogui
vmrun -T ws list
vmrun -T ws checkToolsState "<validation-root>\windows11-cluster-cli-20260924\ClusterYourCodex-Windows11-CLI.vmx"
```

Observed results:

- `start` exit code: `0`
- `vmrun list`: the new VM was registered as running alongside the existing
  VM; the existing VM was not stopped or changed
- `checkToolsState`: `installed`
- `getGuestIPAddress -wait`: returned a NAT guest address
- A guest command executed through `vmrun -gu/-gp` and copied back to the host
  successfully (`runProgramInGuest` and `CopyFileFromGuestToHost` both returned
  success).
- The guest probe reported Windows 11 Pro build `26200`, a running
  `vmtoolsd.exe`, and the `cyc.exe`, `cyc-controller.exe`, and `cyc-worker.exe`
  payload files from product version `0.0.1`.
- The `ClusterYourCodex Controller` scheduled task was present. The probe saw
  no product listener at that moment, so this VM record does not claim a live
  controller/worker round trip.

## Acceptance boundary

This proves that VMware CLI can create and boot an isolated, Tools-enabled
Windows guest from the D-drive validation area. It is not, by itself, proof of
the complete clean-guest lifecycle (`Install -> Repair -> Upgrade -> Rollback
-> Uninstall`) or a live ClusterYourCodex worker job. Those gates still need a
guest credential/bootstrap channel and must be recorded separately when they
are completed.

## Blank-disk installation attempt

After the cloned-guest probe, a separate blank 80 GiB VMDK was created with
`scripts/New-ClusterYourCodexWindowsVm.ps1`. The verified Windows ISO and the
existing private `answer.iso` (containing `Autounattend.xml`) were attached and
the VM was started through `vmrun -T ws start ... nogui`.

The attempt was stopped after VMware reported the same optical-media failure on
both the generated SATA CD-ROM and an IDE CD-ROM configuration:

```text
DISKUTIL: ide1:0 : capacity=0 logical sector size=2048
Guest: Status upon boot failure: No Media
No operating system was found
```

The ISO is independently readable by Windows (`UDF`, 8,471,603,200 bytes) and
its SHA-256 matches the Microsoft-published value above. Therefore this
attempt is recorded as a VMware optical-media/CLI environment failure, not as
a completed Windows installation. The blank-disk VM was powered off and left
in its disposable D-drive directory for repeatable diagnosis; no existing VM
or stable release artifact was modified.

## Optical-media isolation follow-up — 2026-09-25

To distinguish an ISO filesystem problem from a VMware virtual-drive problem,
the verified ISO contents were copied to a disposable D-drive staging directory
and rebuilt inside a Linux container with an ISO9660/Joliet image and both BIOS
and UEFI El Torito boot entries. The rebuilt image was independently mounted by
Windows as `CDFS` and measured `8,467,810,304` bytes. It was then attached to
the same blank VM's single IDE CD-ROM after removing the extra CD-ROM and
`autodetect`/`clientDevice` entries. VMware still reported:

```text
DISKUTIL: ide1:0 : capacity=0 logical sector size=2048
Guest: Status upon boot failure: No Media
```

The same `capacity=0` result was also reproduced with VMware's own
`windows.iso`, and the rebuilt CDFS image produced the same result when moved
from IDE to SATA. This rules out the source ISO's UDF layout, the duplicate
CD-ROM configuration, and the controller choice as causes. The remaining
diagnosis is a host-specific VMware Workstation 26.0.1 virtual CD-ROM path
failure. The rebuilt ISO and the disposable minimal VM remain under
`D:\ClusterYourCodex-validation`; neither is a product release artifact. No
clean-VM installation or lifecycle pass is claimed from this experiment.

