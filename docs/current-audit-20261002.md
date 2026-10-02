# Live Cross-Platform Audit — 2026-10-02

This record documents the first real SSH onboarding run against the current
controller source. The target was disposable and was destroyed after the run;
no password, bearer token, private key, or enrollment material is stored in
the repository.

## Linux SSH onboarding

The acceptance target was an Ubuntu 24.04 systemd container started with
Docker CLI on the D-drive validation workspace. The harness used the signed
Linux x86_64 Worker Kit from the published preview and the current native
`Ssh2Transport`; it did not use a fake transport or fixture boundary.

The successful run exercised the complete chain:

1. SSH password authentication and host-key observation.
2. Explicit host-key approval against the out-of-band SHA-256 fingerprint.
3. Remote Linux inventory and signed Worker Kit staging.
4. Controller enrollment, worker TLS startup, and heartbeat reconciliation.
5. A real controller-to-worker full-run job with stdout/stderr chunk hashes,
   the snapshot-input marker, and the proof artifact hash.
6. Multi-step teardown, including remote uninstall, pairing revocation, and
   durable-record deletion.

The private report (outside Git) recorded `finalState=ready` and
`removed=true`; the test process exited `0` after 16.25 seconds. The target
was powered down and removed after the run. This is real Windows-controller →
Linux-worker SSH evidence, but it is not evidence for a clean Windows guest or
for native macOS execution.

## Fixes exposed by the live run

The run found two source-level defects that static package checks did not catch:

- Linux and Windows full-run job scripts validated `input.txt` but did not
  emit the snapshot-input line that the log verifier requires. The scripts now
  print the validated input before the execution marker.
- The Linux Worker Kit generated a quoted `WorkingDirectory=` value that
  systemd rejected as non-absolute on the Ubuntu target. The installer now
  emits systemd-safe escaped paths without surrounding quotes. Existing
  preview artifacts still contain the old script and must not be presented as
  proof of the repaired behavior until a new signed preview is built.

The ignored live harness also now drives the intentional multi-request Remove
checkpoint until the durable record is actually gone. A one-call cleanup was
previously reported as a false failure after the remote uninstall had already
completed.

## Remaining gates

- Issue #2 remains open for a clean current-source Windows 11
  Install → Repair → Upgrade → Rollback → Uninstall matrix, a clean-guest live
  worker job, and the remaining installer signing/tray requirements.
- Issue #3 remains open for native macOS LaunchAgent lifecycle,
  controller/worker execution, and macOS detached-descendant cleanup.
- The stable `v0.0.1` tag and assets remain immutable.

## Reproduction boundary

The run used only disposable paths under `D:\\ClusterYourCodex-validation` and
the repository's ignored live test:

```powershell
$env:CYC_PROVISIONING_E2E_CONFIG = 'D:\\ClusterYourCodex-validation\\ssh-live-20261002\\live-config.json'
cargo test --locked --manifest-path apps/desktop/src-tauri/Cargo.toml --lib `
  provisioning::provisioning_e2e::live_ssh_provisioning -- --ignored --nocapture
```

The config and password file are intentionally not committed. Replace them
with a new disposable target and fresh private files for every local run.
