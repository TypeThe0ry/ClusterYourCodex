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
- `plugins/codex`: Codex Skill and MCP bridge.

## Design rules

- No built-in host names, IP addresses, drive letters, users, or fixed fleet size.
- Codex never receives worker passwords, private keys, or raw secret material.
- Every run records its source identity, selected node and reason, native exit
  code, elapsed time, logs, verification, and artifact hashes.
- Jobs own their workspaces. Cancellation and cleanup never touch unrelated
  files or processes.
- Existing `AGENTS.md` content is preserved; managed integration is additive.

See [`docs/adr/0001-product-boundary.md`](docs/adr/0001-product-boundary.md)
for the initial architecture decision.

