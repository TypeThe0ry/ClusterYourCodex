# VMware CLI recheck — 2026-10-01

This record captures a command-line-only recheck of the provisioned D-drive
Windows 11 validation guest. It is supporting evidence for the Windows-first
preview, not a clean-VM GA claim. No guest credentials, pairing material, or
tokens are stored in Git.

## Procedure

- Started and stopped the guest with VMware `vmrun`; no Computer Use or GUI
  automation was used.
- Waited for VMware Tools, confirmed the guest address, and invoked the
  installed `cyc.exe` through `vmrun`.
- Copied only sanitized command output back to the host evidence directory
  `D:\ClusterYourCodex-validation\vmware-clean-setup-20260930\`.
- Repeated the probe against the D-drive validation VM on 2026-10-01 with
  `vmrun` only. The guest received `192.168.6.132`; the candidate Setup
  payload was present, but the prior rollback had removed the install root and
  product tasks. The sanitized inspection set is retained outside Git under
  `D:\ClusterYourCodex-validation\vmware-clean-lifecycle-20261001\`.

## Results

- Controller health: `http://127.0.0.1:47831/v1/health` returned
  `{"status":"ok","apiVersion":"cyc.dev/v1","controllerVersion":"0.0.1","database":"ok"}`.
- Managed-worker listener: a guest-side TCP probe to `192.168.6.131:47832`
  returned `tcpTestSucceeded=true`.
- LAN discovery: `cyc discover --timeout-ms 1500 --pretty` exited `0` and
  returned a controller candidate on UDP `47830`, API `cyc.dev/discovery/v1`,
  service `clusteryourcodex`, version `0.0.1`, and worker URL
  `https://192.168.6.131:47832`.
- Discovery returned `credentialsTransmitted=false` and
  `pairingRequired=true`; enrollment therefore remains an explicit step.
- The VM was soft-powered off after the probes; `vmrun list` reported zero
  running VMs.

## Interactive-session boundary

The repeated CLI inspection found no logged-on user: `quser` reported no
session and `qwinsta` showed only the services session plus an unnamed console
session. Winlogon had `AutoAdminLogon=0` and no stored default password. A
guest `runProgramInGuest -interactive` attempt therefore returned
`The specified guest user must be logged in interactively to perform this
operation`.

This prevents a `vmrun`-only run from proving the product's default
Interactive scheduled-task lifecycle. The VM was cleanly soft-stopped
(`cleanShutdown=TRUE`, `softPowerOff=TRUE`); this is an environment/session
boundary, not a reason to relax the installer task-health or ACL checks.

## Session-channel follow-up

The follow-up tried a second command-line-only channel without using VMware
GUI control:

- `vmrun typeKeystrokesInGuest` was rejected by the host with
  `Insufficient permissions in the host operating system`.
- An initial guest `runProgramInGuest` attempt to enable Remote Desktop did not
  change `fDenyTSConnections` and produced no listener. A later explicitly
  credentialed guest PowerShell command did have the required administrative
  token: it set `fDenyTSConnections=0`, started TermService, and a TCP `3389`
  listener was confirmed from the host. Launching `mstsc.exe` still did not
  produce a stable logged-on guest session, so it is not counted as product
  lifecycle evidence.
- A temporary host RDP credential was used only for this probe, then removed
  immediately with Windows Credential Manager. The RDP client and VM were
  stopped afterward; no credential or RDP material is retained in Git.

The host-side keyboard channel remains unavailable, and the RDP attempt did
not yield a stable interactive session under this image. Completing Issue #2
still requires a VM provisioning channel that supplies a repeatable interactive
Windows logon (or a separately approved test-image bootstrap), not a
product-side relaxation of the per-user Interactive task contract.

## Current-source ACL proof

After the session-channel probe, the exact current `packaging/windows/bootstrap.ps1`
was copied into the guest and executed through VMware Tools. The probe's source
SHA-256 was recorded outside Git. Two focused cases passed under Windows
PowerShell 5.1:

- A fresh transaction child beneath an inheritance-enabled parent was created
  with protected ACLs and zero inherited ACEs.
- An already-existing weak child was rejected by `New-CycPrivateDirectory`
  without changing its security descriptor.

This directly confirms the current fail-closed helper contract. It does not
turn the provisioned VM into a clean lifecycle acceptance run, and it does not
justify auto-repairing an existing weak transaction tree.

## Boundary

This recheck does not prove the missing Issue #2 clean-guest
Install → Repair → Upgrade → Rollback → Uninstall matrix or an
installed-package worker job in the provisioned guest. Hosted CI and the
sanitized disposable-host records remain the authoritative live Windows and
Linux controller/worker evidence. The cross-platform
Windows↔Windows, Windows↔Linux, and Linux↔Linux records remain in
[cross-platform-validation-20260927.md](cross-platform-validation-20260927.md);
native macOS runtime validation remains deferred under Issue #3.

The stable `v0.0.1` tag and its release assets remain immutable at
`e4fbaef04b764268fa038311d85573b18b549f9`.
