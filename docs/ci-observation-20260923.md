# Windows CI observation correction — 2026-09-23

Scope: PR #120, commit `028709ea62c76bd1a6e332f88868397cfe85fd18`,
CI run [35792946149](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/35792946149).

## Evidence from attempt 2

- Desktop native integration started at 2026-09-22 22:45:53 UTC.
- Its wrapper emitted five-second heartbeats through 22:55:59 UTC, with
  894 seconds remaining in its internal budget.
- Desktop MSRV emitted a heartbeat at 22:55:57 UTC with 244 seconds remaining.
- Windows workspace tests completed the controller library's 121 tests,
  controller binary's 6 tests, and protocol's 68 tests successfully. The
  package runner advanced to `cyc-provision` at 22:52:32 UTC.
- The workflow was manually cancelled at approximately 22:56:07 UTC,
  before these processes reached their configured deadlines.

These logs do **not** establish a deadlock, a runner outage, or a timeout.
The earlier conversational descriptions of a day-long freeze and a confirmed
`cyc-provision` deadlock were unsupported. UTC timestamps on September 22
correspond to the morning of September 23 in Singapore; a date boundary is
not a day of elapsed runtime. Workflow `updated_at` and an unchanged active
step are not process-level progress measurements. `gh run view --log` declining
to return an unfinished job's logs is not evidence of runner failure.

## Follow-up

Attempt 3 was requested with `gh run rerun 35792946149 --failed`, retaining
successful checks. Its Windows jobs are 106973085337 (desktop), 106973085516
(desktop MSRV), and 106973085752 (workspace). At observation they were running;
no success or failure conclusion is claimed here.

### Final result of attempt 3

The attempt subsequently completed with conclusion `success`. All ten CI jobs
passed, including Windows workspace tests and the Desktop/Windows host/Codex
bridge job (35 minutes 38 seconds). That desktop job completed installation
lifecycle, managed Worker Kits, and the live controller/worker round trip.
PR #120 automatically squash-merged as
`946bbb75faa7d4ee40dfd846e66672af708f992a` after required checks passed.

The native integration step took 8 minutes 56 seconds, below even the former
900-second internal limit. This successful run supports the tested behavior;
it does not prove that raising the timeout fixed a deadlock or was necessary
for this run. The local reproduction below is separate evidence.

A local `cargo test --locked -p cyc-provision -- --test-threads=1` against the
same code completed with exit code 0: 45 unit tests and 27 state-machine tests
passed, with no failures or ignored tests. The cold test-profile build took
6 minutes 57 seconds; the two suites took 0.94 and 0.38 seconds respectively.
Process inspection during compilation showed active `nmake.exe` and `cl.exe`
descendants. The build emitted LNK4099 warnings about missing OpenSSL debug
symbols, but linking and tests succeeded. This local reproduction did not
reproduce a deadlock; it does not prove that the hosted Windows jobs passed.

Allow the active attempt to finish or reach its configured deadline. Diagnose
the resulting logs before changing time budgets or product code. Keep the
published `v0.0.1` tag unchanged. These CI observations do not complete the
clean Windows installer or macOS managed-runtime acceptance requirements.
