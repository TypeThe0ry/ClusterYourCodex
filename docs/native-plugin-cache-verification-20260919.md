# Native Plugin Cache Verification (2026-09-19)

The native integration now verifies both payload locations involved in a local
Codex plugin install:

1. the repository-prepared marketplace source at
   `~/.codex/marketplaces/clusteryourcodex`; and
2. the exact `installedPath` returned by `codex plugin add`, normally under
   `~/.codex/plugins/cache/clusteryourcodex/cluster-your-codex/<version>`.

`scripts/Install-NativeCodexPlugin.ps1` fails closed when `installedPath` is
missing, absent, or incomplete. It runs `Test-NativeCodexPlugin.ps1` against
both roots and runs `Test-McpDeployment.mjs` against the copied cache runtime,
which is the payload Codex executes.

The recovery run on this date:

- moved the previous marketplace to a timestamped recoverable backup;
- removed no unrelated skills and found no active `clustor`,
  `cluster-orchestrator`, or `orchestrator` directory;
- rebuilt and registered `cluster-your-codex@clusteryourcodex` version `0.0.1`;
- passed native payload integrity for source and cache; and
- passed the MCP startup probe with all 8 native fleet tools.

The same recovery was rerun from a fresh Codex marketplace registration at
2026-09-19 09:25 (local time). Before the rerun, `codex plugin marketplace
list` contained only `openai-curated`; after the installer completed it listed
`clusteryourcodex`, and `codex plugin list --json` reported
`cluster-your-codex@clusteryourcodex` as installed and enabled with a local
marketplace source. This closes the registration-state failure mode behind the
desktop message that the built-in plugin payload is missing or incomplete.

The post-recovery checks were repeated against the exact cache path returned by
`codex plugin add`: native integrity passed, the MCP probe returned protocol
`2025-06-18` and all 8 tools, and the repository MCP suite passed 7 files / 48
tests. The previous marketplace tree was retained as a timestamped
`*.incomplete-*` backup by the installer.

The installed plugin remains native-only. Legacy orchestrator names are
cleanup targets and are not execution providers.

## Current rerun

At 2026-09-19 10:17 (local time), the recovery path was run again with
`-Repair` against the persistent Codex marketplace. The previous marketplace
was moved to a timestamped recoverable backup before preparation. The rerun
confirmed all of the following:

- the active Codex home contains no `clustor`, `cluster-orchestrator`, or
  `orchestrator` skill directory;
- the native registration is installed and enabled as
  `cluster-your-codex@clusteryourcodex`;
- the exact Codex cache path returned by `plugin add` passes the 6-file
  integrity check;
- the bundled Node runtime starts the MCP bridge and exposes all 8 native
  fleet tools; and
- the MCP package suite passes 7 files / 48 tests.

This is the supported repair path for the desktop error that reports a missing
or incomplete built-in Codex plugin payload. It removes the stale registration
before adding the rebuilt native plugin and validates the copied cache rather
than trusting the marketplace source alone.
