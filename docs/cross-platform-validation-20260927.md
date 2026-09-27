# Cross-platform validation — 2026-09-28

This record follows the current repository and the requested validation order:
Windows↔Windows, Windows↔Linux, Linux↔Linux, then LAN discovery and setup
convenience. macOS native runtime validation is intentionally deferred; Issue
#3 stays open for that work.

## Results

| Path | Result | Evidence and boundary |
| --- | --- | --- |
| Windows controller ↔ Windows worker | **Pass** | The installed same-host round trip remains green, and a second independent run now uses the VMware Windows controller (`192.168.6.132`) with the Windows host worker. The controller issued a separate enrollment, the scheduler selected the host node by `os.windows`, the job succeeded with exit code 0, and the downloaded artifact contained `windows-windows-complete` (SHA-256 `e13448ec22062b370bdd7b1b35c8731fa3f815de8d544985e46ed375e7ab2d2e`). Evidence is retained under `D:\ClusterYourCodex-validation\windows-windows-cross-20260928b\`. |
| Windows controller ↔ Linux worker | **Pass** | A current-source Windows 11 VMware controller (`192.168.6.132`) issued a one-time enrollment bundle to an independent Linux x86_64 worker container on Docker host networking. The worker paired, reported capabilities, claimed the submitted snapshot job, completed it with exit code 0, and the controller artifact download contained `windows-linux-complete`. Evidence is retained under `D:\ClusterYourCodex-validation\windows-linux-cross-20260928\`; credentials are outside Git. |
| Linux controller ↔ Linux worker | **Pass** | Two independent Linux containers on Docker network `172.31.0.0/24` completed TLS identity, pairing, heartbeat, scheduling, execution, and artifact flow. Sanitized run data is retained under `D:\ClusterYourCodex-validation\linux-linux-cross-20260927`. This is a disposable two-container validation, not a physical-host acceptance. |
| LAN discovery | **Implemented, unit-tested, and CLI-probed** | The controller announces credential-free metadata on UDP `47830`; `cyc discover` sends a broadcast or explicit unicast probe and returns candidates. The response never contains tokens, pairing codes, keys, or database paths. Pairing remains an explicit short-lived enrollment operation. An explicit probe against the VM returned the contract-shaped empty candidate list when no controller beacon was reachable from that interface. |
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
checkout and selected the paired node for the submitted job. The Windows↔Linux
run used the same current-source binaries, a VMware Windows controller, and an
independent Linux x86_64 container; its downloaded artifact was 22 bytes with
SHA-256 `c1945425350d40968e2680c607f2e3e0c297341138c8590ca1ea94ceae68c991`.
The disposable containers and Docker network are stopped after validation.
The D-drive evidence directories are intentionally outside Git and may contain
protected test credentials; they must never be copied into an issue, PR,
README, or log bundle.
