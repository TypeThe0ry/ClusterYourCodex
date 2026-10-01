# VMware clean full-clone lifecycle — 2026-10-01

This record captures the strongest Windows validation completed after the
earlier linked-clone run exposed inherited state. VMware was controlled only
with the command-line `vmrun` tool; no Computer Use or VMware GUI automation
was used. The original validation VM was not modified.

## Test boundary and inputs

- Source image: the existing Windows 11 validation image under
  `D:\ClusterYourCodex-validation\windows11-cluster-cli-20260924\`.
- Test VM: a separate full clone under
  `D:\ClusterYourCodex-validation\vmware-ga-full-20261001\`.
- Candidate Setup: the Windows setup artifact from CI run `36811133742`.
- Setup SHA-256:
  `36b392e9ef2d33409919665209dd750d1860f3b296611173469b545a64f52732`.
- Extracted/package `bootstrap.ps1` SHA-256:
  `89db4d04b22a8bea892c75166d234eeba61e3d7fe90dd82151f2bff41a75fe4b`
  (the installed file matched this digest).
- Package manifest SHA-256 observed by the lifecycle diagnostic:
  `4a24df28fcea3d026e17b169efb151fc55ac56baa2e90305f68f3f1907ead243`.

Guest credentials and all raw VM/diagnostic files remain outside Git under the
D-drive validation workspace. No token, password, pairing material, or private
key is included here.

## Results

### Install

The full clone was reset to an empty per-user install/data state before the
test. Silent Setup completed with exit code `0`. The guest lifecycle diagnostic
reported `status=succeeded`, `lastStage=complete`, `coreSucceeded=true`, and
`firewallVerified=true`.

The installed product then passed all of the following command-line probes:

- `GET http://127.0.0.1:47831/v1/health`: HTTP `200`, API `cyc.dev/v1`,
  controller version `0.0.1`, database `ok`.
- Managed-worker TCP listener: `192.168.6.136:47832` listening and owned by
  the installed controller process; controller loopback `127.0.0.1:47831`
  listening as well.
- LAN discovery: `cyc discover --timeout-ms 1500 --pretty` exited `0` and
  returned a controller candidate at `192.168.6.136` on UDP `47830`.
  The response advertised `cyc.dev/discovery/v1`, role `controller`, service
  `clusteryourcodex`, version `0.0.1`, and the worker URL. It explicitly
  reported `credentialsTransmitted=false` and `pairingRequired=true`.
- Both owned Private-profile firewall rules were enabled: the managed-worker
  TCP rule and the LAN-discovery UDP rule.
- The installed bootstrap file digest matched the extracted package digest;
  the installed manifest and controller executable were present.

### Repair / repeated install

Running the same Setup candidate again against the installed clone completed
with exit code `0`. The second lifecycle diagnostic again reached `complete`
with `coreSucceeded=true` and `firewallVerified=true`. This verifies the
idempotent Repair path against a real installed state rather than only a
fixture or hosted CI process.

### Uninstall

The installed `Uninstall-ClusterYourCodex.ps1 -Quiet` wrapper completed with
exit code `0`. Post-uninstall probes confirmed:

- the per-user install root no longer exists;
- the install manifest no longer exists;
- the controller/worker processes are gone;
- the ClusterYourCodex scheduled task is gone;
- the owned firewall rules are gone; and
- the per-user uninstall registry entry is gone.

The data root remains by design with the controller database, jobs, TLS state,
and token so user data is not silently destroyed by uninstall. This is the
documented data-preservation boundary, not an incomplete uninstall.

## What this does not prove

This run proves clean current-candidate Install, repeated Install/Repair,
health, listener readiness, credential-free same-L2 discovery, and Uninstall
on a Windows 11 full clone. It does not yet prove a version-changing
`Upgrade`, an interrupted-install `Rollback`, or a worker job submitted
through the installed scheduled-task instance. Those remain explicit Issue #2
gates. The independent Windows↔Windows, Windows↔Linux, Linux↔Linux, and
LAN-discovery records remain in
[`cross-platform-validation-20260927.md`](cross-platform-validation-20260927.md).
Native macOS runtime validation remains deferred under Issue #3 by request.

The stable `v0.0.1` tag and release assets were not changed.
