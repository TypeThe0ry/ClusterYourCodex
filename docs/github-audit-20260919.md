# GitHub issue and pull-request audit — 2026-09-19

This record is based on the live `TypeThe0ry/ClusterYourCodex` repository and
does not alter the published `v0.0.1` tag or its assets.

## Open issues

| Item | Decision | Reason |
| --- | --- | --- |
| [#2 Windows one-click installer and desktop host](https://github.com/TypeThe0ry/ClusterYourCodex/issues/2) | Keep open | The Windows preview path is implemented and repeatedly tested, but the issue still requires the complete clean-machine lifecycle, production Authenticode signing, packaged tray/one-click acceptance, and signed upgrade/rollback evidence. |
| [#3 Heterogeneous Linux and macOS worker packages](https://github.com/TypeThe0ry/ClusterYourCodex/issues/3) | Keep open | Linux/macOS packages build and verify, but native macOS LaunchAgent lifecycle and live managed macOS controller/worker evidence are not proven. The current fleet has no reachable macOS worker. |

These are acceptance trackers, not stale implementation tickets. Closing them
would make the stable-readiness record inaccurate, so the current evidence was
added to the issue threads instead.

## Open pull requests

| Item | Decision | Reason |
| --- | --- | --- |
| [#94 native plugin recovery docs](https://github.com/TypeThe0ry/ClusterYourCodex/pull/94) | Superseded | Its documentation is retained and updated on the current branch; the later #96 integration contract covers the active installer/test path. |
| [#96 native plugin cleanup and MCP contract](https://github.com/TypeThe0ry/ClusterYourCodex/pull/96) | Merge candidate | It is the active implementation line. CI and Windows Setup acceptance must finish before merge. |

## Current native-plugin evidence

- `cluster-your-codex@clusteryourcodex`, version `0.0.1`, installed and enabled;
- native payload integrity: 6/6 required files present and non-empty;
- MCP probe: protocol `2025-06-18`, 8 tools;
- MCP package tests: 7 files / 48 tests passed;
- desktop Rust integration tests: 35 passed;
- active legacy `clustor`, `cluster-orchestrator`, and `orchestrator` skill
  directories: 0.

The native verifier now rejects a partial skill, bridge, bundled runtime, or
Node license instead of allowing the desktop to report a false healthy state.
