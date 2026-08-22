# Packaging direction

ClusterYourCodex is Windows-first but keeps one cross-platform product model.
The intended private-preview package is:

```text
ClusterYourCodex.exe   Tauri 2 GUI and tray
cyc-controller.exe    per-user loopback controller
cyc-worker.exe        optional per-user managed worker
cyc.exe               diagnostics, bootstrap, and recovery CLI
runtime/node.exe       private runtime for the bundled Codex MCP bridge
integrations/          installer-owned Codex marketplace and plugin
```

The React application is the shared renderer. Tauri is the native host on
Windows, Linux, and macOS; it proxies controller requests so the renderer never
receives the long-lived bearer token.

## Windows lifecycle

The MVP is a current-user NSIS install under:

```text
%LOCALAPPDATA%\Programs\ClusterYourCodex
```

Mutable state remains under:

```text
%LOCALAPPDATA%\ClusterYourCodex
```

Controller and optional worker use per-user Scheduled Tasks with
`InteractiveToken`, least privilege, `IgnoreNew`, and bounded restart policy.
They do not depend on the GUI process remaining open. A SYSTEM service is a
later opt-in for dedicated machines, not the default.

The installer restricts the full data directory to the current user SID and
SYSTEM before the controller creates its database or token. ACL failure aborts
installation. Tokens never appear in arguments, environment variables,
installer state, diagnostics, or logs.

## Linux and macOS lifecycle

- Linux uses a systemd user service and XDG data/state directories.
- macOS uses a LaunchAgent and Application Support/Logs directories.
- The same controller/worker protocol, data ownership, rollback, and evidence
  rules apply on every platform.

## Codex integration

The installer owns a dedicated local marketplace and installs the plugin from
there. It does not overwrite global `AGENTS.md`, personal marketplaces, or
other plugins. The current TypeScript MCP bridge is bundled as a single file
with a checksum-pinned private Node runtime; a native MCP binary can replace it
later without changing tool contracts.

Install, upgrade, repair, and uninstall record only non-secret owned resources
and hashes. Uninstall removes those exact resources and preserves user data by
default. `--purge-data` is the explicit destructive option.

## Release gate

Tagged builds must produce native Windows, Linux, macOS x64, and macOS arm64
artifacts where supported, plus `SHA256SUMS`, a release manifest, SBOM, and
provenance. Windows signing and a clean Windows 11 install/upgrade/uninstall
smoke are required before calling an installer stable.

Until the managed execution acceptance gate in
[`managed-worker-protocol.md`](managed-worker-protocol.md) passes, packaged
workers are labelled probe/developer artifacts rather than executable workers.
