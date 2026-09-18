# Native Codex plugin recovery — 2026-09-18

The desktop error `The built-in Codex plugin payload is missing or incomplete`
was reproduced as an unregistered native plugin, not as an MCP bridge or
payload integrity failure. The Codex CLI returned no
`cluster-your-codex@clusteryourcodex` entry before recovery.

## Recovery

1. Generated a fresh self-contained marketplace with
   `scripts/Prepare-NativeCodexPlugin.ps1`.
2. Registered that marketplace with the native Codex CLI:
   `codex plugin marketplace add <marketplace-root>`.
3. Installed the plugin with:
   `codex plugin add cluster-your-codex@clusteryourcodex`.
4. Confirmed the installed registration is enabled and points to the local
   native marketplace source.

The payload includes the plugin manifest, MCP manifest, bridge, bundled Node
runtime, and Node license. No active `clustor` or `cluster-orchestrator` skill
directory exists in the Codex skill roots. The only ClusterYourCodex skill is
the skill shipped by the native plugin itself.

The local Codex home also had nine historical `cluster-*.toml` agent routes
and `rules/cluster.rules`; each referenced the removed `cluster-orchestrator`
skill or the obsolete `C:\\CodexCluster\\cluster.ps1` runner. Those active
entries were disabled with timestamped `.disabled-*` backups. The native
plugin and its MCP tools are now the only active ClusterYourCodex execution
path.

## Evidence

- `scripts/Test-NativeCodexPlugin.ps1`: pass (`cyc.dev/native-plugin-integrity/v1`)
- `packaging/windows/Test-McpDeployment.mjs`: pass, protocol
  `2025-06-18`, eight tools listed
- `pnpm --filter @clusteryourcodex/codex-mcp test`: 7 files / 48 tests passed
- `pnpm --filter @clusteryourcodex/codex-mcp build`: pass
- `git diff --check`: pass

The published `v0.0.1` tag and assets were not modified. The local
`provisioning.rs` formatting change remains an uncommitted user change.
