# Windows preview.94 local controller/worker round-trip

This is a sanitized source-bound acceptance record for the core usability
goal. It was run from the preview.94 checkout after enabling HTTP/2 in the
shared rustls-backed reqwest client. It does not contain credentials.

## Run identity

- **Host:** Windows x64 development host
- **Binaries:** `cyc-controller` and `cyc-worker`, rebuilt from the preview.94
  checkout
- **Probe:** `scripts/Test-WindowsControllerWorkerRoundTrip.ps1`
- **Evidence root:**
  `C:\Users\admin\AppData\Local\Temp\ClusterYourCodex-preview93-live-20260907b\cyc-windows-controller-worker-roundtrip.47316f52d95d4b8faa3b303b576db80b`
- **Result marker:** `windows controller/worker live round-trip passed`

## Verified path

The rebuilt binaries completed the shortest usable execution path:

- disposable controller identity and private state;
- one-time worker pairing and ready acknowledgement;
- worker node report and fleet visibility;
- snapshot pack/upload/status;
- job submission and worker placement;
- `queued` → `running` → `succeeded` with native exit code `0`;
- heartbeat observation during the run;
- stdout and stderr downloads;
- result artifact download and digest verification;
- cleanup receipt and process reaping.

## Root cause found during this run

The first run of the preview.93 source candidate negotiated HTTP/2 with the
controller but had reqwest's `http2` feature disabled. hyper-util then reached
its HTTP/2-disabled panic branch during worker pairing. Preview.94 enables the
feature in the workspace dependency and the rerun completed the entire path
above without a panic.

This proves the controller/worker core path on Windows. It does not close the
separate clean-VM, packaged GUI Add Computer, real macOS LaunchAgent, or
hostile-workload isolation gates; those remain explicit release-boundary work.
