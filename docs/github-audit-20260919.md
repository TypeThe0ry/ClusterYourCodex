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

## Pull-request dispositions

| Item | Decision | Reason |
| --- | --- | --- |
| [#94 native plugin recovery docs](https://github.com/TypeThe0ry/ClusterYourCodex/pull/94) | Superseded | Its documentation is retained and updated on the current branch; the later #96 integration contract covers the active installer/test path. |
| [#96 native plugin cleanup and MCP contract](https://github.com/TypeThe0ry/ClusterYourCodex/pull/96) | Merged | GitHub reports merge commit `cc6452b2c365523b056f11fa9af7feb747e3545c`, merged at 2026-09-19 02:11:28 UTC. |
| [#97 native plugin repair record](https://github.com/TypeThe0ry/ClusterYourCodex/pull/97) | Open; auto-merge enabled | At the follow-up audit, head `728b488` had 17 successful checks and one running desktop check. Run `35416205713`, job `105825486622`, was executing managed-worker-kit validation. This is not evidence of a failure or a completed merge. |

## Acceptance versus release gates

Issue #2 explicitly requires the desktop/tray, native controller proxy,
per-user tasks, SID ACLs, bundled MCP/marketplace, reversible install lifecycle,
and a clean Windows 11 VM smoke. Production Authenticode and signed upgrade
evidence are additional GA requirements in `docs/packaging.md`, not additional
checkboxes in the issue body. The missing clean-VM lifecycle evidence alone
is sufficient to keep the issue open.

Issue #3 explicitly requires Linux systemd and macOS LaunchAgent packages,
three platform artifacts, native shells/process groups, path/ACL tests, and a
live macOS run. Building a macOS kit on a hosted runner does not prove the last
requirement. Neither issue is obsolete or superseded.

## Current native-plugin evidence

- `cluster-your-codex@clusteryourcodex`, version `0.0.1`, installed and enabled;
- local marketplace registration is present after a clean remove-before-add
  recovery; `codex plugin marketplace list` reports `clusteryourcodex` and the
  installed record points to that local source;
- native payload integrity: 6/6 required files present and non-empty;
- MCP probe: protocol `2025-06-18`, 8 tools;
- MCP package tests: 7 files / 48 tests passed;
- 2026-09-19 10:17 local rerun: forced repair moved the previous marketplace
  aside, rebuilt the native payload, verified the exact installed cache, and
  passed the 8-tool MCP probe again;
- the active Codex roots were checked after cleanup and contain no legacy
  `clustor`, `cluster-orchestrator`, or `orchestrator` skill directories;
- desktop Rust integration tests: 35 passed;
- active legacy `clustor`, `cluster-orchestrator`, and `orchestrator` skill
  directories: 0.

The native verifier now rejects a partial skill, bridge, bundled runtime, or
Node license instead of allowing the desktop to report a false healthy state.
