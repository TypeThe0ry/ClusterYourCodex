# Windows preview.95 local controller/worker round-trip

This is the source-bound acceptance record for the core usability goal. It was
run after the preview.95 version candidate was committed, using the rebuilt
Windows controller and worker. It contains no credentials.

## Run identity

- **Host:** Windows x64 development host
- **Source commit:** `f61c1c7cc3a9e9437cac1e5714d9154f6702c0c9`
- **Binaries:** `cyc-controller` and `cyc-worker`, rebuilt from the preview.95
  checkout
- **Probe:** `scripts/Test-WindowsControllerWorkerRoundTrip.ps1`
- **Evidence root:**
  `C:\Users\admin\AppData\Local\Temp\cyc-windows-controller-worker-roundtrip.0040b16045814f3a8ac9fcd3b59595ae`
- **Result:** `status=passed`, observed states `queued → running → succeeded`,
  run duration 8 seconds

## Verified path

All retained checks were true:

- private job-root ACL;
- controller health and TLS identity;
- one-time worker pairing and ready acknowledgement;
- worker node report and job claim;
- heartbeat window and native completion;
- stdout/stderr logs and result artifact digest;
- route trace, cleanup receipt, process reaping, and secret scan.

This proves the current Windows controller/worker core path for preview.95. It
does not close the separate clean-VM, packaged GUI Add Computer, production
signing, real macOS LaunchAgent, cross-machine, or hostile-workload gates.
