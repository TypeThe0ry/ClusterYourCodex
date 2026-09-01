# Linux hostile-isolation native probe

`scripts/test-linux-hostile-isolation.sh` is a reproducible acceptance probe
for the **experimental** Linux dedicated-identity/cgroup-v2 mechanism.  It runs
the ignored Rust test
`isolation::tests::linux_live_dedicated_identity_credential_and_residual_reconciliation`
on a native Linux worker, while creating one unique system account and
disposable cgroup-v2 children for the run.

The probe is evidence collection for issue #5.  A passing probe is **not** a
claim that hostile-workload isolation is production-ready, and it does not
enable the backend in packaged workers.  The runtime continues to report
`ready=false` until the complete escape, identity, resource, and
reconciliation proof set is independently reviewed.

## Preconditions

Run on the Linux worker itself (not through an SSH foreground process):

- Bash, Cargo/Rust, and the standard `useradd`/`groupadd`/`userdel`/
  `groupdel` utilities are installed.
- The process is `root`.
- A writable unified cgroup-v2 hierarchy is mounted at `/sys/fs/cgroup`.
- The `pids` controller is available and enabled for child cgroups.  The
  `cgroup.kill`, `cgroup.events`, `cgroup.procs`, `cgroup.threads`, and
  `pids.max` files must be available on a newly created child (the cgroup-v2
  root itself may not expose all of those files).
- The checkout contains the workspace `Cargo.toml` and the locked dependency
  graph.

The script checks every prerequisite before creating the temporary identity.
It does not read controller credentials, SSH configuration, environment
secrets, or worker configuration files.

## Usage

From a clean checkout:

```bash
sudo ./scripts/test-linux-hostile-isolation.sh \
  --repo /srv/codex-worker/jobs/<run-id>/repo \
  --work-root /srv/codex-worker/jobs/<run-id>/hostile-probe
```

When run from the checkout, `--repo` defaults to the current directory (a
relative repository path is resolved before the test).  `--work-root` must be
an absolute path.  Its default is
`$TMPDIR/clusteryourcodex-linux-hostile-isolation` (or
`/tmp/clusteryourcodex-linux-hostile-isolation` when `TMPDIR` is unset).  The
generated job directory is the only directory retained/used for probe
artifacts.

The native command is intentionally exact and ignored:

```bash
cargo test --manifest-path /path/to/ClusterYourCodex/Cargo.toml \
  -p cyc-worker --lib --locked -- \
  --ignored --exact --nocapture \
  isolation::tests::linux_live_dedicated_identity_credential_and_residual_reconciliation
```

The script exports `CYC_TEST_HOSTILE_LIVE_UID` and
`CYC_TEST_HOSTILE_LIVE_GID` only in the test process.  Cargo build output is
placed under the job-owned `target/` directory, so the checkout is not used as
a shared incremental build tree.

## Evidence layout

Each invocation creates a mode-0700 directory such as:

```text
<work-root>/linux-hostile.<random>/
  manifest.json
  result.json
  logs/
    preflight.log
    native-test.log
    cleanup.log
  target/                 # Cargo target/cache for this probe
```

`manifest.json` records the source checkout, source SHA when available,
controller list, temporary UID/GID, exact test command, and artifact paths.
`result.json` records native and cleanup exit codes, timestamps, explicit
residue-verification booleans, and
`nativeProbeMarkers.cgroupThreadsBoundaryVerified`.  The manifest records the
complete cgroup control inventory, including `cgroup.threads`, plus the
preflight marker.  No passwords, private keys, tokens, or worker credential
contents are written to these files.

The exit trap:

1. re-scans only direct `cyc-hostile-*` children that were absent from the
   preflight snapshot; unexpected files or symlinks are recorded as residue
   and are never followed;
2. writes `cgroup.kill`, waits for `cgroup.procs`/`cgroup.threads`/
   `cgroup.events` to become empty, and removes each empty job-owned cgroup
   with `rmdir`;
3. terminates and verifies any process still using the temporary UID;
4. removes the temporary user and group and verifies that both names are gone;
5. removes only the empty identity-home direct child of the generated job
   directory; and
6. publishes `result.json` while retaining the logs for review.

Pre-existing entries matching the prefix are recorded and never touched.  The
script never follows symlinks or recursively deletes the operator-selected
work root, checkout, or a fixed system path.

## Interpreting a run

- `finalExitCode=0`, `testExitCode=0`, `cleanupExitCode=0`, and both residue
  flags set to `1` are required for a clean evidence record.
- A non-zero native test code is a failed probe even if cleanup succeeds.
- A zero native code with a non-zero cleanup code is also a failed evidence
  record; inspect `logs/cleanup.log` before rerunning.
- A preflight failure means no hostile test was run.  Fix the worker's root,
  cgroup delegation, or toolchain state and start a new job directory.

Retain the manifest, result, and logs as an evidence bundle.  A reviewer must
still assess delegated-cgroup escape paths, identity exclusivity, resource
limits, race/reconciliation behavior, and production packaging before changing
the runtime gate or closing issue #5.

## Receipt and live-check behavior

The Linux reconciliation receipt is a durable, identity-bound startup record.
Claim-time validation checks its protocol, node, backend, generation, and
success flags, but does not expire the worker when its `reconciled_at` timestamp
is older than 15 minutes.  Every claim still performs live checks of
`cgroup.procs`, `cgroup.threads`, `cgroup.events`, the dedicated execution
identity, every ancestor/leaf cgroup control, and `pids.max`.  The 15-minute
freshness rule remains for external-guard receipts, where no equivalent
in-process Linux probe corroborates the durable record.

The native test emits `cgroup.threads_escape=blocked` after attempting both
process and thread membership escapes.  A successful result sets the manifest
and result native probe markers for the `cgroup.threads` control and boundary
check.

## Cleanup after an interrupted shell

The trap handles normal exits, `SIGINT`, and `SIGTERM`.  If the host is powered
off during the probe, use the retained `manifest.json` and `logs/cleanup.log`
to identify the generated job.  Re-run the script only after confirming the
previous process is gone; do not remove arbitrary `/sys/fs/cgroup` entries.
