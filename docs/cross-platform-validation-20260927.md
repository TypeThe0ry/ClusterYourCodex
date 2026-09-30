# Cross-platform validation — 2026-09-30 update

This record follows the current repository and the requested validation order:
Windows↔Windows, Windows↔Linux, Linux↔Linux, then LAN discovery and setup
convenience. macOS native runtime validation is intentionally deferred; Issue
#3 stays open for that work.

## Results

| Path | Result | Evidence and boundary |
| --- | --- | --- |
| Windows controller ↔ Windows worker | **Pass** | The installed same-host round trip remains green, and a second independent run now uses the VMware Windows controller (`192.168.6.132`) with the Windows host worker. The controller issued a separate enrollment, the scheduler selected the host node by `os.windows`, the job succeeded with exit code 0, and the downloaded artifact contained `windows-windows-complete` (SHA-256 `e13448ec22062b370bdd7b1b35c8731fa3f815de8d544985e46ed375e7ab2d2e`). Evidence is retained under `D:\ClusterYourCodex-validation\windows-windows-cross-20260928b\`. The current-source Windows guest also completed the self-contained controller/worker fixture with every check green (`queued → running → succeeded`, 8-second run, cleanup and secret scan); sanitized result evidence is retained under `D:\ClusterYourCodex-validation\vmware-windows-roundtrip-20260928\successful\`. |
| Windows controller ↔ Linux worker | **Pass** | A current-source Windows 11 VMware controller (`192.168.6.132`) issued a one-time enrollment bundle to an independent Linux x86_64 worker container on Docker host networking. The worker paired, reported capabilities, claimed the submitted snapshot job, completed it with exit code 0, and the controller artifact download contained `windows-linux-complete`. Evidence is retained under `D:\ClusterYourCodex-validation\windows-linux-cross-20260928\`; credentials are outside Git. |
| Linux controller ↔ Linux worker | **Pass** | Two independent Linux containers on Docker network `172.31.0.0/24` completed TLS identity, pairing, heartbeat, scheduling, execution, and artifact flow. Sanitized run data is retained under `D:\ClusterYourCodex-validation\linux-linux-cross-20260927`. This is a disposable two-container validation, not a physical-host acceptance. |
| LAN discovery | **Implemented in CLI and desktop Add Computer, unit-tested, and live-probed** | The controller announces credential-free metadata on UDP `47830`; `cyc discover` and the native desktop bridge send a broadcast probe and return candidates. The Add Computer wizard now offers **Scan local network**, pre-filling only the selected SSH host/display name. A fresh current-source Windows controller returned a positive candidate for `127.0.0.1` with the expected API version, role, service, version, and worker URL. The response never contains tokens, pairing codes, keys, or database paths. Pairing remains an explicit short-lived enrollment operation. The current installed candidate in the D-drive VMware guest also answered `cyc discover --timeout-ms 1500 --pretty` with exit code `0`, candidate `192.168.6.131`, `credentialsTransmitted=false`, and `pairingRequired=true`; sanitized output is retained as `cyc-discover-158.txt` under `D:\\ClusterYourCodex-validation\\vmware-clean-setup-20260930\\`. The product candidate owns the UDP rule transactionally. |
| macOS native runtime | **Deferred by request** | Package/build checks remain covered by CI, but native LaunchAgent and live round-trip evidence is intentionally not asserted here. Issue #3 remains open. |

## LAN discovery and one-click flow

Start a controller with the normal worker endpoint. It will answer the local
probe automatically; no extra daemon or credential is required. A current
Windows install owns the UDP discovery rule and the worker TCP rule in one
transaction, with exact `Private`/`LocalSubnet` scope and rollback of both.
From the controller machine:

```powershell
cyc discover --timeout-ms 1500 --pretty
cyc discover --address 192.168.1.63 --timeout-ms 500 --pretty
```

Discovery is only a candidate list. The desktop **Scan local network** action
shows the address and can pre-fill the SSH host field; it still asks the
operator to verify the SSH host-key fingerprint and runs the existing install →
pair → start → probe workflow. This keeps convenience separate from trust: a
random LAN device cannot enroll by merely answering a UDP packet.

The current probe is an IPv4 broadcast on the local layer-2 segment. It does
not enumerate routed subnets or claim cross-router discovery. The Windows
candidate's transactional helper validates both the TCP worker rule and UDP
`47830` rule before mutation, snapshots both, and restores both on rollback;
the v1 worker-only request remains a recovery-only compatibility path. A strict
network policy, an older pre-dual-rule installation, or a clean-VM lifecycle
failure can still make an otherwise healthy controller invisible. In that case,
use the manual host field or the explicit `--address` probe. The remaining
clean-VM installer lifecycle gate is tracked in Issue #2 and is intentionally
not hidden behind a green loopback test.

## Verification commands

```powershell
cargo fmt --all -- --check
cargo test -p cyc-protocol -p cyc-controller -p cyc-cli
cargo check -p cyc-controller -p cyc-cli
pnpm --filter @clusteryourcodex/desktop lint
pnpm --filter @clusteryourcodex/desktop test
cargo check --manifest-path apps/desktop/src-tauri/Cargo.toml --lib
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

The guest fixture is a same-VM runtime proof only. It does not close the clean
Windows 11 installer lifecycle gate in Issue #2: signed Setup, additive
N-1→N upgrade, interrupted rollback/downgrade, and packaged tray acceptance are
still separate requirements.
