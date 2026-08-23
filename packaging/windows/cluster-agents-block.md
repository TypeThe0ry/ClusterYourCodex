<!-- CLUSTERYOURCODEX-MANAGED:BEGIN -->
## ClusterYourCodex distributed compute

ClusterYourCodex is registered and enabled for this Codex home. When a build, test, static
analysis, container, batch compute, rendering, local model inference, or
data/media task would materially benefit from another computer, submit typed
requirements through the installed `cluster-your-codex` plugin and its
`cluster_your_codex` MCP tools. The Controller, not the language model, owns
placement: call `fleet_plan` and then `fleet_plan_submit` so the Controller uses
its latest telemetry and reservations to atomically select and reserve a
compatible worker. Verify the returned exit code, logs, and artifact hashes.

- Do not select a node from a cached fleet/status snapshot. A specific node may
  be requested only when the user explicitly chooses manual placement.
- Express compatibility, resources, capabilities, and workload constraints as
  typed requirements; let Controller scheduling prefer current availability
  before raw performance.
- Keep tiny, controller-specific, or GUI-coupled work local when transfer and
  startup overhead would cost more than the expected speedup.
- Discover the installed MCP tool schemas at runtime; do not assume a private
  host name, address, credential, workspace, fleet size, or operating system.
- Never place worker credentials or other secrets in prompts, job payloads,
  command arguments, logs, artifacts, or this file.
- Treat a dispatched command as successful only after its native exit status
  and expected outputs have been verified.
<!-- CLUSTERYOURCODEX-MANAGED:END -->
