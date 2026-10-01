# VMware installed scheduled-task round-trip — 2026-10-01

This is a separate CLI-only acceptance record for the installed Windows
candidate. VMware was operated exclusively with `vmrun`; no Computer Use or
VMware GUI automation was used. The VM is a full clone of the existing
Windows 11 validation image, not a blank Windows installation. The raw
validation workspace remains outside Git on the D drive.

## Boundary and setup

- VM: `D:\ClusterYourCodex-validation\vmware-ga-rerun-20261001\`
- Candidate Setup: CI run `36811133742`
- Setup SHA-256:
  `36b392e9ef2d33409919665209dd750d1860f3b296611173469b545a64f52732`
- Installed `bootstrap.ps1` SHA-256:
  `89db4d04b22a8bea892c75166d234eeba61e3d7fe90dd82151f2bff41a75fe4b`
- Lifecycle diagnostic package manifest SHA-256:
  `4a24df28fcea3d026e17b169efb151fc55ac56baa2e90305f68f3f1907ead243`

The first attempt was made while the guest was at the login screen. The
Interactive scheduled task correctly did not run there (`0x41303`, task has
not run), so that attempt was not counted. A temporary, private autologon
configuration was then applied through `vmrun`; its credential file was
deleted by the guest script and is not present in Git or this record. The
per-user install and data roots were reset, and the post-logon Setup run
completed with exit code `0`. Its diagnostic reported `status=succeeded`,
`lastStage=complete`, `coreSucceeded=true`, and `firewallVerified=true`.

## Installed probes

The installed controller then passed:

- `GET http://127.0.0.1:47831/v1/health`: HTTP `200`, API `cyc.dev/v1`,
  controller version `0.0.1`, database `ok`.
- `cyc discover --timeout-ms 1500 --pretty`: exit code `0`, one controller
  candidate on UDP `47830`, `credentialsTransmitted=false`, and
  `pairingRequired=true`.
- Managed-worker listener `47832` and controller loopback listener `47831`;
  the installed controller process owned both.
- Scheduled task `ClusterYourCodex Controller`: running.
- Enabled Private-profile firewall rules for the managed worker and LAN
  discovery.

## Installed worker round-trip

The installed `cyc.exe`, `cyc-controller.exe`, and `cyc-worker.exe` were used
by the guest's existing Windows controller/worker round-trip harness. The
recorded result was `status=passed`, process exit code `0`, and the observed
state sequence was:

```text
queued → running → succeeded
```

All 15 checks passed: private job-root ACL, controller health, TLS identity,
pairing readiness, node report, job claim, heartbeat window, completion, logs,
artifact, cleanup, route trace, process cleanup, and secret scan. The job ran
for 8 seconds and its job root was deleted by the cleanup receipt. Sanitized
raw evidence is retained at:

```text
D:\ClusterYourCodex-validation\vmware-ga-rerun-20261001\installed-roundtrip-result.json
D:\ClusterYourCodex-validation\vmware-ga-rerun-20261001\installed-roundtrip-checks.json
```

This proves an installed same-host Windows controller/worker job, not the
Windows↔Windows, Windows↔Linux, or Linux↔Linux cross-machine matrix; those
records remain in
[`cross-platform-validation-20260927.md`](cross-platform-validation-20260927.md).
It also does not prove version-changing Upgrade, interrupted Rollback,
production signing, or a blank-guest GA lifecycle. Those Issue #2 gates remain
open. Native macOS runtime validation remains deferred by request.
