# Native Codex plugin recovery — 2026-09-18

## 2026-09-19 reinstall verification

The native repair path was rerun from the current repository after the desktop
reported an incomplete built-in payload. The exact legacy skill directories
(`clustor`, `cluster-orchestrator`, and `orchestrator`) were searched under the
active Codex home and none remain. The installer then rebuilt the persistent
marketplace, removed the existing native registration, and added
`cluster-your-codex@clusteryourcodex` again.

The installed cache now passes the six-file payload integrity check, includes
the bundled Node runtime and license, and passes the MCP initialize/tools-list
probe with protocol `2025-06-18` and all eight native tools. The MCP package
suite passes 48/48 tests and the TypeScript production build succeeds.

This verification uses the native Codex plugin registry and MCP bridge only;
the removed legacy skill names are cleanup targets, not execution providers.

## 2026-09-19 cache-repair follow-up

The installer now removes the exact `cluster-your-codex@clusteryourcodex`
registration before adding the rebuilt marketplace again. Codex caches local
plugin payloads by plugin/version, so re-adding a damaged same-version entry
could otherwise keep returning the opaque `payload missing or incomplete`
error even when the marketplace source was complete. The installer also
rejects a registration whose source path is not the freshly prepared native
plugin and then runs the bundled-runtime MCP probe against the installed path.

Verified on the local Windows controller:

- native plugin registration: enabled, version `0.0.1`;
- required payload files: 6/6 present and non-empty;
- MCP protocol: `2025-06-18`;
- MCP tools: 8 listed by the bundled Node runtime;
- MCP package tests: 7 files, 48 tests passed;
- active legacy `clustor`, `cluster-orchestrator`, and `orchestrator` skill
  directories: 0.

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

## Re-registration after the desktop payload error — 2026-09-19

The same local failure was reproduced after the Codex CLI no longer listed the
native plugin. The repair command was rerun with `-Repair`, which moved the
stale marketplace to a timestamped recoverable backup, rebuilt the bundled
marketplace, removed legacy skill directories, and registered the native
plugin again.

Observed verification on the repaired machine:

- `cluster-your-codex@clusteryourcodex`, version `0.0.1`, is installed and enabled;
- the payload integrity probe passed for all six required files;
- the native MCP bridge returned protocol `2025-06-18` and all eight tools;
- no active `clustor`, `cluster-orchestrator`, or `orchestrator` directory remained;
- the MCP package test suite passed: 7 files / 48 tests.

This is the supported recovery for the desktop message “built-in Codex plugin
payload is missing or incomplete”. It uses the native plugin registry and the
bundled MCP runtime; legacy orchestrator skills are not part of the execution
path.

## Desktop verifier hardening — 2026-09-19

The desktop verifier now uses the same completeness boundary as the native
installer. A native registration is accepted only when the source contains a
non-empty plugin skill, MCP bridge, bundled Node runtime, and
`LICENSE.node.txt`, in addition to the manifests and bridge server. Missing
skill or runtime-license files now return `integration_payload_unavailable`
instead of allowing a partial payload to proceed.

Regression evidence:

- Rust integration tests: 35 passed;
- native payload integrity: pass, 6/6 required files;
- bundled MCP deployment probe: protocol `2025-06-18`, 8 tools;
- MCP package tests: 7 files / 48 tests passed;
- clean `-Repair` reinstall: plugin `cluster-your-codex@clusteryourcodex`,
  version `0.0.1`, installed and enabled;
- active legacy `clustor`, `cluster-orchestrator`, and `orchestrator` skill
  directories: 0.
