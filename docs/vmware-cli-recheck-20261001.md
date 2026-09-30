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

## Boundary

This recheck does not prove the missing Issue #2 clean-guest
Install → Repair → Upgrade → Rollback → Uninstall matrix or an
installed-package worker job in the provisioned guest. Hosted CI remains the
authoritative live Windows controller/worker evidence. The cross-platform
Windows↔Windows, Windows↔Linux, and Linux↔Linux records remain in
[cross-platform-validation-20260927.md](cross-platform-validation-20260927.md);
native macOS runtime validation remains deferred under Issue #3.

The stable `v0.0.1` tag and its release assets remain immutable at
`e4fbaef04b764268fa038311d85573b18b549f9`.
