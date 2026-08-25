# Codex integration

## Trust boundary

Codex calls a local MCP bridge. The bridge reads the controller token from a
native-owned file and connects only to the loopback controller. The renderer
and Codex tool schemas do not expose controller URLs, bearer tokens, worker
passwords, private keys, or raw credential objects.

The installer registers and enables the local marketplace plugin, then updates
only the uniquely marked ClusterYourCodex range in the global `AGENTS.md`.
Unrelated bytes remain unchanged. Repair and uninstall use durable journaling,
compare-and-swap, and drift checks.

## Verify

1. Open ClusterYourCodex and inspect **Codex integration**.
2. If prompted, select **Install/Repair Plugin**.
3. Restart Codex once after a plugin or managed-instruction change.
4. Start a new Codex task and ask it to list the available computers.
5. For meaningful automatic work, the expected MCP sequence is:

   ```text
   fleet_info
   workspace_snapshot_pack (for dirty/non-Git source when needed)
   fleet_snapshot_upload    (when a snapshot is used)
   fleet_plan_submit        (atomic plan + reserve + submit)
   fleet_job                (poll to terminal evidence)
   ```

   `fleet_plan` alone previews/explains placement. `fleet_submit` is reserved
   for submitting the exact unchanged JobSpec against an explicit existing
   plan during manual recovery.
6. Run **Integration Self Test** and **Full Run Check**. Connected status
   requires a fresh MCP runtime receipt that was verified against the native
   controller; an installed manifest by itself is not proof of a live bridge.

## Repair boundary

The GUI's Codex-only repair path may verify/install the plugin and update its
managed `AGENTS.md` block. It cannot restart the controller, alter a worker,
change a service/Scheduled Task, mutate a firewall rule, or replace TLS
identity. Use the installer Repair lifecycle for those resources.
