# ADR 0001: Codex-first multi-computer execution

- Status: Accepted
- Date: 2026-08-22

## Context

Codex can perform substantial local work such as compilation, testing,
container builds, data transforms, and GPU-assisted compute. A single execution
host can be incompatible, busy, or underpowered while users already own other
Windows, Linux, or macOS computers that could run the work.

## Decision

ClusterYourCodex will let Codex submit a versioned `JobSpec` to a local
controller. The controller discovers machine capabilities, filters incompatible
nodes, selects a node using an explainable policy, reserves resources, executes
the job in a job-owned workspace, verifies it, and returns logs and artifacts.

The product remains Codex-first:

- Codex Plugin, Skill, and MCP are the primary task entry point.
- The GUI configures computers, policies, tasks, and outputs.
- A CLI exists for diagnostics and recovery, not as the primary product.
- Internal API separation exists to provide compatibility across Codex releases,
  not to broaden the initial product into an unrelated orchestration platform.

The Windows controller ships first. Domain types, storage, scheduling, and
worker contracts must not assume Windows-only paths or shells.

## Connection modes

The public product will support two connection families:

1. Managed Worker pairing for a low-friction installation experience.
2. Existing SSH for advanced users and legacy fleet import.

Credential material remains owned by the controller credential provider. Codex
and MCP messages receive opaque credential references only.

## Consequences

- Current fixed-node scripts become an importable legacy adapter, not core data.
- Placement decisions must expose accepted candidates, rejection reasons, and
  score components.
- Job directories, source identity, leases, state transitions, logs, artifacts,
  and cleanup ownership are first-class records.
- The installer must be additive and reversible.

