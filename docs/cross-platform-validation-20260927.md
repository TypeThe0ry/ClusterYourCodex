# Cross-platform validation — 2026-09-27

This record follows the current repository and the requested validation order:
Windows↔Windows, Windows↔Linux, Linux↔Linux, then LAN discovery and setup
convenience. macOS native runtime validation is intentionally deferred; Issue
#3 stays open for that work.

## Results

| Path | Result | Evidence and boundary |
| --- | --- | --- |
| Windows controller ↔ Windows worker | **Same-host pass** | The installed Windows guest round trip at `D:\ClusterYourCodex-validation\guest-exchange\cli-installed-roundtrip-checks.json` passed health, TLS identity, pairing, node report, claim, heartbeat, completion, logs, artifact, cleanup, route trace, process cleanup, and secret scan. This is not two independent Windows machines. |
| Windows controller ↔ Linux worker | **Not yet proven** | A current-source Windows controller was prepared in the VMware guest, but the guest's strict protected-directory ACL preflight rejected the disposable staging directory before it could issue a usable enrollment bundle. No cross-platform pass is claimed. |
| Linux controller ↔ Linux worker | **Pass** | Two independent Linux containers on Docker network `172.31.0.0/24` completed TLS identity, pairing, heartbeat, scheduling, execution, and artifact flow. Sanitized run data is retained under `D:\ClusterYourCodex-validation\linux-linux-cross-20260927`. This is a disposable two-container validation, not a physical-host acceptance. |
| LAN discovery | **Implemented and unit-tested** | The controller announces credential-free metadata on UDP `47830`; `cyc discover` sends a broadcast or explicit unicast probe and returns candidates. The response never contains tokens, pairing codes, keys, or database paths. Pairing remains an explicit short-lived enrollment operation. |
| macOS native runtime | **Deferred by request** | Package/build checks remain covered by CI, but native LaunchAgent and live round-trip evidence is intentionally not asserted here. Issue #3 remains open. |

## LAN discovery and one-click flow

Start a controller with the normal worker endpoint. It will answer the local
probe automatically; no extra daemon or credential is required. From the
controller machine:

```powershell
cyc discover --timeout-ms 1500 --pretty
cyc discover --address 192.168.1.63 --timeout-ms 500 --pretty
```

Discovery is only a candidate list. The desktop must still show the address,
ask the operator to verify the SSH host-key fingerprint, and run the existing
install → pair → start → probe workflow. This keeps convenience separate from
trust: a random LAN device cannot enroll by merely answering a UDP packet.

## Verification commands

```powershell
cargo fmt --all -- --check
cargo test -p cyc-protocol -p cyc-controller -p cyc-cli
cargo check -p cyc-controller -p cyc-cli
```

The Linux cross-container run used the release binaries built from this
checkout and selected the paired node for the submitted job. The disposable
containers and Docker network were removed after the run. The D-drive evidence
directory is intentionally outside Git and may contain protected test
credentials; it must never be copied into an issue, PR, README, or log bundle.
