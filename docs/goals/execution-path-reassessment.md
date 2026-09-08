# Execution path reassessment

Date: 2026-09-08. Inspected baseline: `83af38c`.
Status: source-backed assessment, not a new execution backend or live acceptance.

## Outcome and constraints

The outcome remains Add Computer, native credential retention, worker setup,
typed job placement, and verified result/log/artifact return. Packaging and
transport choices are revisable; existing code is not a reason to retain them.
Preserving user data, keeping secrets out of jobs/logs, and reporting actual
native exits remain requirements. Public builds remain prereleases until GA.

## What the current source establishes

- `crates/cyc-ssh/src/lib.rs`: `RemoteSession` offers fixed command execution
  and bounded file transfer. `exec_fixed` waits for channel completion and
  returns stdout, stderr, and exit status. This interface does not provide a
  durable detached job, reconnect receipt, scheduler reservation, or cancel API.
- `crates/cyc-provision/src/ssh_driver.rs`: SSH is already used for discovery,
  kit transfer, lifecycle execution, and enrollment delivery.
- `crates/cyc-provision/src/engine.rs`: installation, enrollment, pairing, and
  service enablement have persistent checkpoints. These are implementation
  choices, not proof that every OS lifecycle works in the user's environment.
- `crates/cyc-controller/src/worker_api.rs`: the worker protocol already exposes
  claim, lease heartbeat, cancellation observation, logs, completion, cleanup,
  and artifact upload. Replacing the transport must preserve these semantics.

## Alternatives

| Path | Reused capability | New work / risk | Decision |
| --- | --- | --- | --- |
| Repair the managed path | Vault, SSH discovery, persistent provisioning, worker execution and result protocol | Resolve the actual native installation/onboarding failure; platform acceptance still required | Current delivery path |
| SSH-direct typed jobs | Vault, pinned host keys, SSH and file transfer | Durable remote job identity, reconnect, cancellation, resource reservations, bounded logs/artifacts, cleanup across OSes | Candidate, not established as faster |
| Optional per-job runner over SSH | Existing worker job semantics where separable | Runner lifecycle without resident service, recovery and controller connectivity must be proven | Bounded experiment before any migration |

No measured performance comparison exists yet. Do not claim SSH-direct is
faster or simpler end-to-end just because the initial command is shorter.
Likewise, do not require a full installer rebuild for every runtime experiment.
An isolated portable acceptance run can distinguish runtime failure from
installer failure, but cannot count as successful one-click installation.

## Decision and next acceptance

### Packaged preflight evidence

The downloaded preview.100 self-contained `bootstrap.ps1` was run with
`-PlanOnly`, its explicit package root, `payload` bundle root, and
`preview-manifest.json`. It exited 0 and returned `InstallOrRepair` with the
default per-user install/data roots. This proves package planning succeeds in
the current session. It does not execute installation, task registration,
firewall changes, or worker provisioning, and does not explain the earlier
core-application rollback. The existing transaction evidence was not changed.

Do not replace the execution architecture on speculation. First isolate the
native core failure using the packaged payload and retained lifecycle evidence.
Use the existing credentials/records without duplicating computers. Complete
one real cross-node typed job and retain native exit, logs, artifact digest,
reservation release, and cleanup evidence. Keep Windows/Linux/macOS results
separate; one host is not universal platform acceptance.

If persistent service setup remains the blocker, evaluate a per-job runner
behind an explicit experimental backend. Its acceptance must include a dropped
SSH connection, reconnect without duplicate execution, cancellation of the
owned job tree, controller restart reconciliation, and artifact retrieval.
Adopt it only after comparing those results and implementation cost with the
managed path. Do not remove existing worker support, migrate saved computers,
or report macOS readiness merely to make an experiment pass.
