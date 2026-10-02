# VMware current-candidate lifecycle probe — 2026-10-02

This record captures two command-line-only VMware runs against the disposable
full clone under `D:\ClusterYourCodex-validation\vmware-ga-full-20261001\`.
VMware was controlled with `vmrun` and VMware Tools/VIX; no Computer Use or
VMware GUI automation was used. The clone is an existing Windows 11 validation
image, not a blank Windows installation, so this is supporting Issue #2
evidence rather than a clean-VM GA claim.

## Candidate and reset

- The first probe used the passing Windows Setup acceptance artifact
  (`36811133742`), SHA-256
  `36b392e9ef2d33409919665209dd750d1860f3b296611173469b545a64f52732`.
- The stronger second probe used the exact Setup artifact built from merged
  `main` commit `8bf2c4d676e368d9302ace1156f22bc3c867f46d` by Windows Setup
  acceptance run `36954089310`, SHA-256
  `1b35b55ff99d5e57629d66c0e3e0fab62bca9d9beb3f2ebac5d1485cd074110b`.
  Its lifecycle diagnostic recorded package manifest SHA-256
  `f3d0ae97a683e189138e3862a07a88213a82417bbdea06a191df02df991b191b`.
- A disposable guest reset removed the product-owned per-user install and data
  roots before installation. The reset reported both roots absent and stopped
  no unrelated process.
- Guest credentials and raw VM/VIX files remain outside Git under the D-drive
  validation workspace.

## Observed results

The current-`main` probe repeated the reset and all lifecycle operations below;
the first probe is retained as supporting history only.

### Install

The silent Setup invocation (`/S`) returned exit code `0`. Its lifecycle
diagnostic reported:

- `status=succeeded`
- `requestedAction=Install`
- `lastStage=complete`
- `coreSucceeded=true`
- `firewallVerified=true`

The installed controller health endpoint returned the expected healthy JSON
with `database=ok`. `cyc discover --timeout-ms 1500 --pretty` returned a
controller candidate on UDP `47830`, with `credentialsTransmitted=false` and
`pairingRequired=true`. The discovery response therefore confirms the
credential-free LAN scan and preserves explicit host-key/credential/pairing
trust boundaries.

### Same-version repair-equivalent path

A second silent Setup invocation against the installed clone returned exit code
`0` and another `status=succeeded` / `lastStage=complete` diagnostic with both
core and firewall checks true. This is the product's idempotent same-version
Setup path, recorded as Repair-equivalent behavior; it is not a version-changing
upgrade.

### Installed Windows controller/worker job

The installed binaries then ran the disposable Windows controller/worker
round-trip. The result was `status=passed`, exit code `0`, and all 14 reported
checks were true: private job ACL, controller health, TLS identity, pairing,
node report, claim, heartbeat, completion, logs, artifact, cleanup, route
trace, process cleanup, and secret scan. The observed states were
`queued → running → succeeded`, and the cleanup receipt removed the owned job
root. This is same-host Windows evidence, not cross-machine evidence.

### Uninstall and shutdown

The installed `installer/Uninstall-ClusterYourCodex.ps1 -Quiet` wrapper returned
exit code `0`. The final guest state reported:

- product install root absent;
- user data root preserved;
- ClusterYourCodex scheduled tasks absent; and
- product-owned firewall rules absent.

The VM was then soft-stopped with `vmrun`; the host reported zero running VMs.

## Boundary

This run strengthens current Setup, same-version Repair-equivalent, discovery,
same-host worker, and uninstall evidence. It does **not** prove a blank Windows
11 guest, Authenticode-signed Setup/helper, a real N-1 → N upgrade, interrupted
upgrade rollback, or an installed worker job across separate machines. Those
remain explicit Issue #2 gates. Windows↔Windows, Windows↔Linux, and
Linux↔Linux cross-machine records are maintained separately in
[`cross-platform-validation-20260927.md`](cross-platform-validation-20260927.md).
Native macOS runtime validation remains deferred under Issue #3.

The stable `v0.0.1` tag and release assets were not changed.
