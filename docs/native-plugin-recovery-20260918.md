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

The supported installation path is now `scripts/Install-NativeCodexPlugin.ps1`.
It creates a self-contained marketplace, registers it with the native Codex
CLI, installs the plugin, and runs both integrity and MCP tools-list probes.
Installing directly from `plugins/cluster-your-codex` is not sufficient because
the repository source intentionally does not contain the bundled Node runtime.

If Codex retained an empty or partial marketplace directory after a failed
install, the installer automatically moves it to a timestamped sibling backup,
rebuilds the native payload, and then verifies the registered plugin. Use
`-Repair` to force the same rebuild for an otherwise complete directory.

```powershell
powershell -ExecutionPolicy Bypass -File scripts/Install-NativeCodexPlugin.ps1 `
  -MarketplaceRoot "$env:USERPROFILE/.codex/marketplaces/clusteryourcodex" `
  -Repair
```

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

## Re-registration after a lost native registration — 2026-09-18

The desktop integration error was reproduced again after the Codex CLI lost
the local plugin registration. The cache directory still existed, but
`codex plugin list --json` contained no `cluster-your-codex@clusteryourcodex`
entry. The cache alone is not an active native plugin installation.

The recovery was repeated with a fresh marketplace directory at
`D:\\Projects\\ClusterYourCodex\\.native-plugin-marketplace-repair-20260918`
using `scripts/Install-NativeCodexPlugin.ps1`. The CLI now reports:

- `cluster-your-codex@clusteryourcodex`, version `0.0.1`;
- `installed: true`, `enabled: true`, source `local`;
- the bundled `node.exe` and Node license present in the installed payload.

Post-install evidence was collected from the installed cache, not the source
checkout:

- `Test-NativeCodexPlugin.ps1`: pass;
- `Test-McpDeployment.mjs`: protocol `2025-06-18`, 8 tools listed;
- `pnpm --filter @clusteryourcodex/codex-mcp test`: 48/48 passed;
- `pnpm --filter @clusteryourcodex/codex-mcp build`: pass;
- active Codex skill and plugin roots contain no `clustor`,
  `cluster-orchestrator`, or legacy `orchestrator` content.

This confirms the repair path is native plugin registration plus integrity and
MCP probes. It does not rely on a legacy orchestrator skill or a source-style
plugin copy without its bundled runtime.
