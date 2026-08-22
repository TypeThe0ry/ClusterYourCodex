# Packaging direction

ClusterYourCodex is Windows-first but keeps one cross-platform product model.
The intended private-preview package is:

```text
ClusterYourCodex.exe   Tauri 2 GUI
cyc-controller.exe    per-user loopback controller
cyc-worker.exe        optional per-user managed worker
cyc.exe               diagnostics, bootstrap, and recovery CLI
integrations/          installer-owned Codex marketplace and plugin
  codex-marketplace/plugins/cluster-your-codex/mcp/runtime/node.exe
                       bundled private runtime for the Codex MCP bridge
```

The React application is the shared renderer. Tauri is the native host on
Windows, Linux, and macOS; it proxies controller requests so the renderer never
receives the long-lived bearer token. The renderer can send only a typed
`method/path/body` envelope. The native host owns the fixed
`http://127.0.0.1:47831` origin, reads the token from the fixed platform data
root, injects only its own headers, uses no proxy or redirects, and exposes an
explicit route allowlist.

## Windows lifecycle

The current private preview installs per-user from a portable bootstrap ZIP
under:

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

`packaging/windows/bootstrap.ps1` is the current lifecycle engine. It stops
only the product tasks and processes whose executable path is inside the owned
install root before replacing binaries. Each upgrade snapshots the prior
owned files and task XML under a protected transaction directory; a failed
copy, task registration, or start restores both. The controller task receives
explicit loopback/database/token-*file* arguments. Secret token content is
never placed in task arguments, environment variables, the manifest, or logs.

The installer restricts the full data directory to the current user SID and
SYSTEM before the controller creates its database or token. The controller
then independently requires the database, SQLite WAL/SHM/journal sidecars, and
the sibling `jobs` object root to remain non-reparse state with that exact
private ownership/ACL contract. Existing weak or prepositioned state fails
closed; new files are created only after the parent is protected and are
post-hardened before startup completes. ACL failure aborts installation.
Tokens never appear in arguments, environment variables, installer state,
diagnostics, or logs.

## Planned Linux and macOS lifecycle

- Linux packages will use a systemd user service and XDG data/state directories.
- macOS packages will use a LaunchAgent and Application Support/Logs directories.
- The same controller/worker protocol, data ownership, rollback, and evidence
  rules are intended to apply on every platform.

## Codex integration

The installer owns a dedicated local marketplace and installs the plugin from
there. The Windows payload contract is a complete marketplace root at:

```text
payload/integrations/codex-marketplace/
  .agents/plugins/marketplace.json
  plugins/cluster-your-codex/**
```

When the Codex CLI is available, bootstrap runs
`codex plugin marketplace add <marketplace-root>` and
`codex plugin add cluster-your-codex@clusteryourcodex`. Integration is best
effort so an unavailable or older Codex CLI does not fail the core install; the
manifest records whether it was attempted and uninstall reverses the owned
registrations. The installer does not overwrite global `AGENTS.md`, personal
marketplaces, or other plugins. The current MCP package contains a compiled
TypeScript entry, production dependencies, and a bundled private Node runtime
whose copied bytes are hash-recorded in the preview manifest and `SHA256SUMS`;
a native MCP binary can replace it later without changing tool contracts.

Install, upgrade, repair, and uninstall record only non-secret owned resources
and hashes. Uninstall removes those exact resources and preserves user data by
default. `-PurgeData` is the explicit destructive option.

Tauri 2 is configured for a current-user NSIS target. The bootstrap and
portable payload are the private-preview lifecycle; wiring that payload into a
signed, single-file NSIS release and validating clean Windows 11
install/upgrade/uninstall remain release gates rather than assumed results.

## Preview artifact gate

The current workflow produces unsigned, unattested developer-preview archives
and checksum files. It does not yet satisfy the stable-release gate below.

Tagged builds must produce native Windows, Linux, macOS x64, and macOS arm64
artifacts where supported, plus `SHA256SUMS`, a release manifest, SBOM, and
provenance. Windows signing and a clean Windows 11 install/upgrade/uninstall
smoke are required before calling an installer stable.

Until the managed execution acceptance gate in
[`managed-worker-protocol.md`](managed-worker-protocol.md) passes, packaged
workers are labelled probe/developer artifacts rather than executable workers.
