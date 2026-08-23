# ClusterYourCodex

**Give Codex more computers.** ClusterYourCodex lets Codex place build, test,
container, GPU, and batch workloads on the best compatible computer in a
user-owned fleet, then return verified logs and artifacts.

> Status: early Windows-first development. The protocol and execution model are
> intentionally platform-neutral so Linux and macOS workers can follow without
> redesigning the core.

## Product boundary

ClusterYourCodex distributes the executable work that Codex initiates. It does
not distribute OpenAI-hosted model inference and it is not a remote-desktop or
general-purpose cluster administration product.

## Architecture

```text
Codex Desktop / CLI
        |
Codex Plugin + MCP bridge
        |
ClusterYourCodex Controller  <---- Desktop GUI
        |
Scheduler / queue / source / artifacts / trust
        |
Windows, Linux, and later macOS workers
```

The first release is composed of:

- `cyc-controller`: local API, persistent jobs, scheduling, and execution state.
- `cyc-worker`: capability probe and managed-worker bootstrap foundation.
- `cyc-cli`: diagnostics and operator fallback.
- `cyc-protocol`: versioned cross-platform domain model.
- `cyc-scheduler`: compatibility filtering and explainable placement.
- `apps/desktop`: Windows-first desktop interface.
- `plugins/cluster-your-codex`: Codex Skill and MCP bridge.

## Design rules

- No built-in host names, IP addresses, drive letters, users, or fixed fleet size.
- Codex never receives worker passwords, private keys, or raw secret material.
- Codex submits typed workload requirements; the Controller uses current
  telemetry and reservations to atomically choose and reserve a worker. Codex
  does not select a node from a stale status snapshot unless the user explicitly
  requests manual placement.
- Every run records its source identity, selected node and reason, native exit
  code, elapsed time, logs, verification, and artifact hashes.
- Jobs own their workspaces. Cancellation and cleanup never touch unrelated
  files or processes.
- Existing global `AGENTS.md` content is preserved byte-for-byte outside one
  uniquely marked ClusterYourCodex block. Install/Repair updates only that
  block after plugin activation is verified, and Uninstall removes only that
  block with durable journaling, compare-and-swap, and fail-closed drift checks.
- The GUI can finish or repair only the Codex-facing step through the
  non-elevated `bootstrap.ps1 -Action IntegrateCodex` receipt interface. It
  verifies the exact installed/enabled plugin version and local source before
  touching the managed block; it does not restart the controller or modify a
  service, Scheduled Task, firewall rule, or worker configuration.

See [`docs/adr/0001-product-boundary.md`](docs/adr/0001-product-boundary.md)
for the initial architecture decision. The next execution and distribution
gates are defined in
[`docs/managed-worker-protocol.md`](docs/managed-worker-protocol.md) and
[`docs/packaging.md`](docs/packaging.md).
