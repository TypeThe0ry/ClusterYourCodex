# Windows controller/worker core round-trip — current HEAD

This record is bound to the current checkout after the active-run guard path
fix. It is the highest-value usability evidence for the active core-loop goal
and contains no credentials.

## Run identity

- **Checkout:** `D:\Projects\ClusterYourCodex\ClusterYourCodex`
- **Source commit:** `456ce11307f7458304e369ad423cfffcb0ac6065`
- **Product binaries:** `cyc`, `cyc-controller`, and `cyc-worker` rebuilt with
  `cargo build --locked -p cyc-cli -p cyc-controller -p cyc-worker --release`
- **Probe:** `scripts/Test-WindowsControllerWorkerRoundTrip.ps1`
- **Host:** Windows x64 development host
- **Evidence root:**
  `C:\Users\admin\AppData\Local\Temp\ClusterYourCodex-core-roundtrip-head-long-path-81f3bdf1259c400c8ffa81088545574c\cyc-windows-controller-worker-roundtrip.82666de838db4301aacf5877513fdb8f`
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
