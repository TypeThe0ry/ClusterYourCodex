---
name: cluster-your-codex
description: Use ClusterYourCodex to let Codex distribute meaningful builds, tests, containers, batch work, and GPU workloads across computers connected to the user's local controller. Use when remote compute, another OS, more CPU/RAM/GPU, or parallel execution would materially improve the current Codex task.
---

# ClusterYourCodex

ClusterYourCodex lets Codex use multiple computers owned by the user as one
execution fleet. The local controller owns SSH credentials, host keys, queues,
job directories, and artifacts. Never request or include a password, private
key, token, raw credential object, or credential-bearing command in an MCP tool
call.

## When to use it

Use this skill for meaningful work that benefits from another machine:

- builds and test suites;
- Windows/MSVC or Linux-specific work;
- containers and reproducible isolated runs;
- NVIDIA or other GPU compute;
- batch transforms, rendering, inference, and large data jobs;
- independent tasks that can safely run in parallel.

Keep tiny edits, quick inspections, controller-coupled UI checks, and work whose
transfer/setup cost exceeds its runtime on the current computer.

## Required flow

1. Call `fleet_info` once at the first cluster-relevant step. Treat returned
   health and capabilities as current evidence.
2. Create a versioned JobSpec containing an immutable Git revision or sanitized
   snapshot digest, explicit steps, requirements, timeouts, and expected
   artifacts. Never put credentials in the JobSpec.
3. Call `fleet_plan` before `fleet_submit`. Explain or preserve the controller's
   selected computer and placement reasons.
4. Submit the exact planned JobSpec. Keep source-authoring authority on the
   controller; do not silently replace local source with worker edits.
5. Poll `fleet_job` to a terminal state. A submitted or started job is not a
   success. Require the native exit code and expected artifact evidence.
6. Use `fleet_cancel` only for the job owned by the current task. A cancellation
   request is not complete until `fleet_job` reports a terminal state.

## Job construction

- Prefer `build`, `test`, `lint`, `container`, `gpu`, or `batch` over generic
  `shell` when the intent is known.
- Set hard requirements for OS, architecture, tool capabilities, memory, and
  GPU rather than choosing a computer by name.
- Use `placementPolicy: performance` for performance-sensitive work and
  `balanced` for ordinary compatible work. Use `manual` only when the user
  explicitly chooses a computer.
- Use native PowerShell steps on Windows and Bash steps on Linux. Avoid nested
  shell strings.
- Write outputs only inside the assigned job workspace and request returned
  files through `artifacts.include`.
- Keep retries for transient preparation or transport failures. Do not blindly
  replay a state-changing step after execution has begun.

## Failure handling

- Controller unavailable: tell the user to open ClusterYourCodex and show the
  exact local health failure; do not ask for worker passwords.
- No eligible computer: report the unmet hard capability returned by the plan.
- Deterministic build/test failure: preserve the exit code and diagnostic
  evidence, fix the cause, then create a new job.
- Host-key or authentication failure: stop that placement and surface the
  controller's redacted diagnostic. Never disable host-key verification.
