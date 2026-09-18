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

The installed plugin remains native-only. Legacy orchestrator names are
cleanup targets and are not execution providers.
