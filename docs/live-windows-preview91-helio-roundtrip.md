# Windows preview.91 live controller/worker round-trip

This is a retained, sanitized acceptance record for the current preview. It
was produced on the real Helio Windows host from the tagged
`v0.1.0-preview.91` Windows x64 binaries and the repository's
`scripts/Test-WindowsControllerWorkerRoundTrip.ps1` probe.

## Run identity

- **Worker/controller host:** Helio, Windows x64, `192.168.1.63`
- **Windows build:** `Microsoft Windows NT 10.0.26200.0`
- **Controller/worker version:** `0.1.0-preview.91`
- **Binary source:** published Windows x64 preview archive; no Cargo build was
  performed on the worker.
- **Probe job root:**
  `C:\CodexWorker\jobs\cyc-windows-preview91-live-20260906-235837`
- **Sanitized evidence root:**
  `C:\CodexWorker\jobs\cyc-windows-preview91-live-20260906-235837\cyc-windows-controller-worker-roundtrip.805ddc96b7e54cd2bea49b3c8d6404f2`
- **Probe result:** `windows controller/worker live round-trip passed`

## Verified path

The probe completed the native Windows path on Helio:

- disposable controller TLS identity and local state;
- one-time worker pairing with `phase=ready` and `ready=true`;
- managed worker fleet/node report;
- controller placement selecting the live Windows worker;
- PowerShell worker step with an 8-second execution window;
- `queued` → `running` → `succeeded`, exit code `0`;
- stdout and stderr log download;
- result artifact download (`result.txt`, 43 bytes);
- cleanup status `removed`, `jobRootDeleted=true`, and terminal acknowledgement
  with final state `succeeded`.

The worker inventory reported Windows x64, 32 logical cores, NVIDIA RTX 4070,
worker version `0.1.0-preview.91`, and managed transport. Hostile isolation
remained disabled and fail-closed as expected for the preview boundary.

## Boundary

This proves the real Windows native controller/worker protocol and task
round-trip on Helio. It is a same-host Windows live fixture, not a clean-VM
acceptance, production Authenticode proof, or cross-machine GUI/MCP
acceptance. Those remain separate gates.
