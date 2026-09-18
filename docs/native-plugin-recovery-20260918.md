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

The local Codex home also had nine historical `cluster-*.toml` agent routes
and `rules/cluster.rules`; each referenced the removed `cluster-orchestrator`
skill or the obsolete `C:\\CodexCluster\\cluster.ps1` runner. Those active
entries were disabled with timestamped `.disabled-*` backups. The native
plugin and its MCP tools are now the only active ClusterYourCodex execution
path.

## Evidence

The follow-up installation check found the plugin absent from the active CLI
registration and reinstalled it. Its source was then moved out of the temporary
directory into a persistent marketplace and re-registered. The CLI reported
`installed=true` and `enabled=true`; both the source payload and plugin cache
passed the integrity and MCP startup probes. Keep the marketplace directory
after installation. These probes do not establish a new remote-worker run or
prove that an already-open desktop session has reloaded the plugin.

- `scripts/Test-NativeCodexPlugin.ps1`: pass (`cyc.dev/native-plugin-integrity/v1`)
- `packaging/windows/Test-McpDeployment.mjs`: pass, protocol
  `2025-06-18`, eight tools listed
- `pnpm --filter @clusteryourcodex/codex-mcp test`: 7 files / 48 tests passed
- `pnpm --filter @clusteryourcodex/codex-mcp build`: pass
- `git diff --check`: pass

The published `v0.0.1` tag and assets were not modified. The local
`provisioning.rs` formatting change remains an uncommitted user change.

## Packaged Setup evidence audit

Downloaded artifact `windows-setup-acceptance` from
[run 35305044214](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/35305044214)
after its successful completion. Artifact ID: `10531993072`; GitHub archive
digest: `sha256:6dbef9dd789c577d02ddbc9d6895129ad02ee8bbafa71a3d3269f300dd153475`.

- The retained checkout was PR merge ref
  `d4416cdbf810746f747d8dda276d6173c56146ea`, not the PR head SHA. Its tree
  `9a9cdf2b5710cff1344b83de0db453b4ad829a53` matches merged commit
  `5bff3de0ca00918e554406ab74912be33406ee72` exactly.
- `result.json` reports `status=passed`. All 11 recorded operations exited 0,
  including silent Setup, two repairs with a running Controller, the installed
  uninstaller, and repeated uninstall. The check list includes TLS identity
  preservation, retired journals, restored tasks/firewall, and preserved data.
- `cleanup.json` reports `productUninstallCompleted=true`, no primary failure,
  no cleanup failures, and no uncertain process termination.
- Downloaded `result.json` SHA-256:
  `9bad7a7b9ba8b159c60b0f617288e1f0149b45d339f616932206626d1fc98c1d`.
- Downloaded `cleanup.json` SHA-256:
  `cc0cb2cf726e7a7b72e3bd8666094e97b1215dd2aff350a3cb16a7dbda5a1f3a`.

The runner log identifies **Windows Server 2025** (`windows-2025-vs2026`).
Setup was `NotSigned`. This proves the recorded hosted lifecycle, not Issue #2's
clean Windows 11 smoke, GUI/tray behavior, or a signed upgrade/rollback path.
The artifact retains summary receipts and runner-local log paths, not the full
referenced operation logs; those paths are not downloadable evidence themselves.
