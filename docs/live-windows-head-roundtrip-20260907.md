# Windows controller/worker core round-trip evidence

This record contains two separately bound acceptance runs. The first is the
historical same-host run for the active-run guard fix. The second is the later
remote persistent-worker run for the preview.101 candidate. Neither record is
presented as evidence for commits outside its stated source identity.

## Run identity

- **Checkout:** a private Windows development checkout
- **Source commit:** `456ce11307f7458304e369ad423cfffcb0ac6065`
- **Product binaries:** `cyc`, `cyc-controller`, and `cyc-worker` rebuilt with
  `cargo build --locked -p cyc-cli -p cyc-controller -p cyc-worker --release`
- **Probe:** `scripts/Test-WindowsControllerWorkerRoundTrip.ps1`
- **Host:** Windows x64 development host
- **Evidence root:** a private, long-path temporary directory retained on the
  development host
- **Result:** `status=passed`, observed states `queued → running → succeeded`,
  run duration 8 seconds, 14/14 checks true

## Verified core path

The retained result records successful:

- private job-root ACL and controller health;
- worker TLS identity and one-time pairing;
- node report, placement, claim, and heartbeat window;
- native completion with stdout/stderr logs;
- result artifact listing, download, and byte verification;
- route trace, terminal cleanup receipt, process reaping, and secret scan.

The work root intentionally used a long temporary path. Before the fix,
Windows `MoveFileExW` applied the legacy `MAX_PATH` limit to the temporary
active-run guard name, leaving the worker permanently parked during `preparing`
and allowing the lease to expire. The worker now converts absolute local and
UNC guard paths to the extended-length `\\?\` namespace before the atomic
rename. The regression unit test
`runtime::tests::active_run_guard_windows_path_conversion_handles_long_and_unc_paths`
and this live round-trip both pass.

## Acceptance boundary

This proves the same-host Windows controller/worker core loop for the current
source commit. It does not close clean-VM, production Authenticode, live
cross-machine GUI Add Computer, real macOS LaunchAgent, or hostile-workload
GA gates. Public builds therefore remain prereleases.

## Remote persistent-worker acceptance — 2026-09-14

The preview.101 candidate also completed the first real cross-machine Windows
controller/worker loop on the LAN. The candidate source was
`bd46c360d2587da05410ce9f64e5ec1ed2a9fd8b`.

- An owned preview.100 user-scope installation was repaired in place. Its
  legacy task incorrectly launched Windows PowerShell with worker arguments;
  Repair replaced it with the installed `cyc-worker.exe` action and preserved
  the existing pairing/configuration.
- The user task now uses passwordless `S4U`, so it remains runnable from an
  SSH-only controller session without an interactive desktop logon.
- After Repair the task remained `Running`, one worker process persisted, and
  the controller received fresh preview.101 inventory and telemetry.
- A performance-planned test job selected the remote Windows worker, moved
  from `queued` to `succeeded`, and returned native exit code 0.
- Reconstructed stdout contained `CYC_PREVIEW101_EXECUTED`; stderr contained
  `CYC_PREVIEW101_STDERR`.
- Downloaded artifact `preview101-proof.txt` contained `CYC_PREVIEW101_OK` and
  SHA-256 `6156e217602d2345ba1f57d86f74175487ecef71cb8a28ab9372485e401ab3c8`,
  exactly matching the controller artifact record.

This closes the minimum usable Windows controller-to-remote-worker execution
loop. It does not claim stable-GA signing, clean-machine upgrade matrices, or
live macOS worker acceptance; preview.101 remains a prerelease.
