# Goal: core usability before polish

Status: active (revised 2026-09-07)

## Priority

The current delivery priority is the smallest end-to-end path that a user can
actually run:

1. start the local controller and open the desktop UI;
2. add a computer over SSH;
3. approve its host key and keep the SSH credential in the native vault;
4. install, pair, and observe the worker;
5. let the controller place a typed Codex job on the available computer; and
6. return the job state, logs, artifact metadata, and cleanup result.

This goal deliberately puts non-blocking defect cleanup, visual polish, and
additional PR splitting after the usable path. Those items are collected from
operator feedback once the core flow is exercised on a packaged build.

## Delivery mode

This is an outcome-first milestone, not a promise that every edge-case defect
is already closed. Work stays focused on the shortest path that proves the
product can be used: connect one worker, keep its credential inside the native
vault, pair it, run one typed job, and return its evidence. A defect that does
not block that path is recorded for the follow-up feedback goal instead of
displacing the usable path.

The operator-facing order is therefore:

1. ship a runnable prerelease candidate;
2. let the operator exercise the packaged flow;
3. capture the exact stage, version, and redacted diagnostics for each report;
4. promote only reproducible blockers into the core work queue.

The next-stage feedback plan is tracked in
[`user-feedback-loop.md`](user-feedback-loop.md).

## Acceptance signal

The goal is considered usable when one packaged Windows controller/desktop and
one reachable Windows or Linux worker complete the above path with a retained
receipt. The browser preview may validate navigation and translations, but it
is not allowed to claim SSH credential storage or worker provisioning because
those actions belong to the native desktop bridge.

## Release rule

Every public build produced while this goal is in progress remains a GitHub
prerelease (`isPrerelease=true`, `isDraft=false`). A stable Release requires
the independent Windows, Linux, macOS, signing, and hostile-workload gates in
[`docs/release-process.md`](../release-process.md); this goal does not waive
those gates.

## Evidence discipline

Each update records the exact checkout, product version, command, exit status,
and retained evidence path in the repository. Credentials, tokens, private
keys, and passphrases are never written to these records.
