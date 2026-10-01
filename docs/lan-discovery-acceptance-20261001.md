# LAN discovery and automatic provisioning boundary — 2026-10-01

This record describes what “automatic detection/configuration” means in the
current Windows-first product. Native macOS runtime validation is deferred by
request. The cross-machine runtime records remain in
[`cross-platform-validation-20260927.md`](cross-platform-validation-20260927.md).

## What is automatic

1. A running CYC controller answers a credential-free UDP `47830` probe with
   versioned metadata. The announcement identifies the service and controller
   role; it never contains a password, token, pairing code, private key, or
   database path.
2. The desktop Add Computer wizard scans the local IPv4 L2 segment when it
   opens. Choosing a candidate fills the SSH host and a default display name.
3. After the user verifies the host key and supplies/chooses credentials, the
   existing provisioning state machine performs remote platform discovery,
   worker-kit staging/install, one-time enrollment, service enablement,
   heartbeat wait, smoke check, and staging cleanup.
4. Remembered password credentials are stored only after successful
   authentication and only when the user selected the remember option. Private
   keys and agent sessions remain session-only; discovery itself is always
   credential-free.

## What remains explicit

- Discovery advertises controllers, not worker-only machines. A controller can
  answer discovery even when it has no managed worker endpoint.
- The discovered UDP source port is `47830`, not SSH port `22`. Selecting a
  candidate does not consume `workerPublicUrl`, change the SSH port, install a
  worker, or pair it automatically. This is intentional: LAN metadata is a
  candidate hint, not a trust decision.
- The native desktop scan sends one IPv4 limited broadcast (`255.255.255.255`)
  and filters responses to private/loopback/link-local peers. It does not
  enumerate routed subnets, directed broadcasts, or IPv6. Manual host entry or
  an explicit CLI address remains the fallback for isolated networks.
- The current desktop tests cover the parser/native bridge contracts; there is
  not yet a packaged GUI E2E for opening Add Computer, selecting a candidate,
  entering credentials, and completing install/pair/probe.

## Verification

The following targeted checks passed from the current source checkout:

| Check | Result | Boundary |
| --- | --- | --- |
| Desktop discovery + provisioning API tests | 24/24 | Vitest/API bridge tests; not packaged GUI E2E |
| Protocol/controller discovery tests | 3/3 | Credential-free announcement, validation, private probe |
| Native desktop LAN discovery tests | 2/2 | Loopback/synthetic beacon and timeout bounds |
| Provisioning library suite | 45/45 | In-process/fake-driver ordering, redaction, retry, cleanup, rollback |

The D-drive VMware acceptance also live-probed an installed controller with
`cyc discover`: exit code `0`, a controller candidate, and
`credentialsTransmitted=false` plus `pairingRequired=true`. The installed
scheduled-task controller/worker harness passed `queued → running → succeeded`
with all 15 checks green; its sanitized evidence is recorded in
[`vmware-installed-task-roundtrip-20261001.md`](vmware-installed-task-roundtrip-20261001.md).

The Windows↔Windows, Windows↔Linux, and Linux↔Linux runtime paths are recorded
as separate retained evidence in
[`cross-platform-validation-20260927.md`](cross-platform-validation-20260927.md).
No macOS native runtime claim is made here.
