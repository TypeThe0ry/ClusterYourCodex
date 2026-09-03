# Live Linux controller/worker round-trip acceptance

`scripts/test-linux-controller-worker-roundtrip.sh` is the live acceptance
probe for the managed-worker path. It starts the workspace-built
`cyc-controller` with its loopback user API and a TLS worker listener on an
assigned RFC1918 IPv4 address, creates a disposable TLS identity/database/token,
creates and consumes a one-time pairing bundle with `cyc-worker pair`, runs a
real worker daemon, submits a snapshot-backed `JobSpec`, and waits for a
successful terminal run.

The probe is intentionally Linux-only. Its live path checks `uname -s` before
starting anything and exits closed on Windows, macOS, Git Bash, or another
non-Linux shell. A genuine WSL Linux kernel can pass that platform check only
when its own `/proc`, private-network, process, and toolchain prerequisites are
actually present. `--self-test` is safe to run from any shell, but it only
checks Bash helpers; it is not a live acceptance result.

## Preconditions

Run from a Linux checkout with:

- `cargo` and the workspace lockfile available (the script builds
  `cyc-cli`, `cyc-controller`, and `cyc-worker` when matching binaries are not
  supplied with `CYC_BIN`, `CYC_CONTROLLER_BIN`, and `CYC_WORKER_BIN`);
- `python3`, Bash, and ordinary Linux `proc`, network, file, and process
  utilities;
- `/proc` process topology and the Linux child-subreaper operation available
  to the worker; and
- at least one assigned private IPv4 address in `10/8`, `172.16/12`, or
  `192.168/16`. The controller rejects a loopback worker bind, so an address
  is selected from `ip -o -4 addr show scope global up` (or `hostname -I` as a
  fallback) instead of being hard-coded.

The controller API remains on `127.0.0.1`; the selected private address is
used only for the worker TLS listener and certificate SAN. Two free ports are
chosen immediately before launch. The script does not reuse a developer's
controller database, token, certificate, worker config, or workspace.

## Commands

Shell-only checks on any host:

```bash
bash -n scripts/test-linux-controller-worker-roundtrip.sh
bash scripts/test-linux-controller-worker-roundtrip.sh --self-test
```

Live Linux acceptance:

```bash
bash scripts/test-linux-controller-worker-roundtrip.sh \
  --repo "$PWD" \
  --work-root /tmp \
  --timeout 180 \
  --keep-evidence
```

`--repo` and `--work-root` accept relative inputs but are canonicalized before
the run. The timeout covers the live flow after the binaries have been built;
the accepted range is 30..3600 seconds. Without `--keep-evidence`, a passing
run removes its own disposable root after all checks. A failed run always
retains a sanitized root so the original logs and JSON evidence can be
inspected; a passing `--keep-evidence` run also retains that sanitized root.

## Acceptance checks

The generated `result.json` records booleans for each check without storing a
token, pairing code, worker credential, or private key. The probe verifies:

1. TLS identity generation/verification, protected token/bundle/config/
   credential modes, and loopback/private listener startup;
2. pairing status `ready`, plus controller trace routes for `pair` and
   `pair/ack`;
3. a worker node report in `/v1/fleet` and its trace route;
4. a claimed run bound to the paired node, with every run state observed by
   the poller recorded in `job-poll.log`/`result.json`, and a run duration long
   enough to cross the five-second heartbeat cadence;
5. a heartbeat route in the controller trace, followed by complete and
   cleanup routes;
6. uploaded stdout/stderr logs and the `result.txt` artifact, including exact
   bytes and SHA-256 metadata; and
7. a `removed` cleanup status with `jobRootDeleted=true`, a matching terminal
   acknowledgement, and no remaining `workspace/jobs/<run-id>` directory.

The controller is started with `RUST_LOG=debug` by default so its
`TraceLayer` records route paths without request bodies or authorization
headers. `CYC_ROUNDTRIP_RUST_LOG` and `CYC_ROUNDTRIP_WORKER_LOG` can lower or
raise verbosity when diagnosing a runner, but lowering controller logging can
make the route evidence check fail closed.

The secret scan compares the temporary token, TLS private key, pairing code,
and worker credential against the generated logs/evidence, rejects private-key
PEM and credential-bearing HTTP markers, and runs before the files are
removed. The token is passed to `cyc` only through `--token-file`; no secret
value is placed in argv or the command log. Cleanup signals only recorded,
start-time/executable-matched PIDs: `SIGINT`, then bounded `SIGTERM`, then
`SIGKILL` as a last resort. It refuses PID reuse/mismatch and refuses to
remove a path outside the unique `cyc-linux-controller-worker-roundtrip.*`
child of `--work-root`.

## Real-environment gaps

This probe cannot manufacture a Linux process-containment or private-network
environment. A Windows checkout, a Git Bash shell, a Linux container with only
loopback networking, missing `/proc`, unavailable `PR_SET_CHILD_SUBREAPER`,
uncached cargo dependencies, or a runner without `python3` is reported as a
failed precondition rather than being represented as a live pass. Those cases
still permit `bash -n` and `--self-test`; they do not satisfy this acceptance
gate.
