# Linux preview.91 live controller/worker round-trip

This is a retained, sanitized acceptance record for the current preview. It
was produced from the tagged `v0.1.0-preview.91` Linux x64 binaries and the
repository's `scripts/test-linux-controller-worker-roundtrip.sh` probe.

## Run identity

- **Worker:** ThinkPad P1, Linux x86_64, `192.168.1.62`
- **Controller source:** `v0.1.0-preview.91`, source commit
  `84260a6b92b3ea12c2b570429883c056e8fdcea5`
- **Binary source:** published Linux x64 preview archive; no Cargo build was
  performed on the worker because its root filesystem had only about 526 MiB
  free before the run.
- **Probe job root:**
  `/srv/codex-worker/jobs/cyc-linux-preview91-live-20260906-155615`
- **Sanitized evidence root:**
  `/srv/codex-worker/jobs/cyc-linux-preview91-live-20260906-155615/cyc-linux-controller-worker-roundtrip.aIhGdv`
- **Probe exit code:** `0`
- **Result status:** `passed`

## Verified path

The live probe completed all of the core worker path on the real P1 host:

- controller TLS identity and disposable controller state;
- one-time worker pairing and pair acknowledgement;
- worker node report and controller fleet visibility;
- snapshot pack/upload/status;
- job submission and claimed placement on the paired worker;
- `queued` → `running` → `succeeded` state observation;
- heartbeat route during an 8-second run;
- stdout/stderr log download and verification;
- result artifact download and SHA-256 verification;
- complete and cleanup routes;
- credential-leak scan and process cleanup.

The probe result recorded `cleanupStatus=removed`, `pairReady=true`,
`nodeReported=true`, `claimObserved=true`, `heartbeatObserved=true`,
`completeObserved=true`, `cleanupObserved=true`, `logsVerified=true`,
`artifactsVerified=true`, `credentialLeakScan=true`, and
`processesCleaned=true`.

## Boundary

This proves the real Linux controller/worker protocol and task round-trip for
the tagged preview on P1. It does not by itself prove the Windows desktop
Add Computer GUI, a macOS LaunchAgent host, or hostile-workload isolation.
Those remain separate acceptance gates and are not silently promoted by this
Linux result.
