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
- A guest `runProgramInGuest` probe could run ordinary user commands, but the
  token was not elevated for system changes. A request to enable Remote
  Desktop returned without a usable listener; the guest registry value
  `fDenyTSConnections` remained `1` and no TCP `3389` listener appeared.
- A temporary host RDP credential was used only for this probe, then removed
  immediately with Windows Credential Manager. The RDP client and VM were
  stopped afterward; no credential or RDP material is retained in Git.

This rules out a second CLI transport under the current non-elevated host and
headless guest setup. Completing Issue #2 still requires a VM provisioning
channel that supplies a real interactive/elevated Windows logon (or a
separately approved test-image bootstrap), not a product-side relaxation of
the per-user Interactive task contract.

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
