# VMware VIX acceptance — preview.111 (2026-10-04)

This record covers the independently operated Windows 11 VMware guest used for
the public preview. The guest was controlled through VMware VIX/`vmrun` CLI only;
Computer Use and VMware GUI automation were not used. The VM was reverted to the
`pre-upgrade-20261002` snapshot before installation.

## Public artifact

- Release: [`v0.1.0-preview.111`](https://github.com/TypeThe0ry/ClusterYourCodex/releases/tag/v0.1.0-preview.111)
- Source commit: `833d10f59c0ea5196ae9746b1c7d61f12389e802`
- Tagged release workflow: [37174731863](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/37174731863)
- Exact main-push CI: [37172854585](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/37172854585)
- External download directory: `D:\ClusterYourCodex-validation\preview111-public-20261004`
- Download verification: 11/11 `SHA256SUMS` entries and 11/11 per-asset `.sha256` sidecars matched.

## Guest install and health

The public `ClusterYourCodex-Setup.exe` was copied into the guest and run with
silent setup. VIX reported guest exit code `0`. The retained sanitized evidence
is outside the repository at
`D:\ClusterYourCodex-validation\guest-exchange\preview111-installed-evidence-20261004.json`.

The evidence records:

- installed manifest and product binaries at `0.1.0-preview.111`;
- Controller Scheduled Task `Running`;
- controller health `status=ok`, `apiVersion=cyc.dev/v1`, `database=ok`;
- listeners on `127.0.0.1:47831` and the managed-worker address on `47832`.

## Credential-free discovery

The installed CLI returned exit code `0` for `cyc discover --timeout-ms 2000`.
It found the guest controller as a candidate and recorded:

```text
credentialsTransmitted = false
pairingRequired        = true
```

Discovery is metadata-only on the local IPv4 broadcast segment. The candidate
still requires host-key verification and explicit pairing; the discovery probe
does not send an SSH password or silently enroll a worker.

## Same-host live round trip

The installed controller/worker fixture returned exit code `0`. Retained
sanitized records are:

- `D:\ClusterYourCodex-validation\guest-exchange\preview111-installed-roundtrip-result-20261004.json`
- `D:\ClusterYourCodex-validation\guest-exchange\preview111-installed-roundtrip-checks-20261004.json`

The result observed `queued -> running -> verifying -> succeeded` and passed
all 14 checks: private job-root ACL, controller health, TLS identity, pairing,
node report, claim, heartbeat, completion, logs, artifact, cleanup, route
trace, process cleanup, and secret scan. The job root was deleted and the
reservation was released.

## Boundary

This is strong installed Windows preview evidence, not a claim that every GA
gate is complete. It does not replace a separately retained clean-VM
Install -> Repair -> Upgrade -> Rollback -> Uninstall matrix, signed N-1 -> N
upgrade/interrupted rollback evidence, production Authenticode signing, or
packaged tray/one-click acceptance. Hosted Windows 11 ARM64 x64-emulation
acceptance passed in the tagged workflow, but it is not native ARM hardware
proof. Issues [#2](https://github.com/TypeThe0ry/ClusterYourCodex/issues/2) and
[#3](https://github.com/TypeThe0ry/ClusterYourCodex/issues/3) therefore remain
open, and stable `v0.0.1` remains immutable.
