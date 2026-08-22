# Packaging and developer-preview artifacts

ClusterYourCodex is Windows-first but keeps one cross-platform product model.
The self-contained Windows developer-preview payload is:

```text
ClusterYourCodex.exe   Tauri 2 GUI
cyc-controller.exe    per-user loopback controller
cyc-worker.exe        optional per-user managed worker
cyc.exe               diagnostics, bootstrap, and recovery CLI
integrations/          installer-owned Codex marketplace and plugin
  codex-marketplace/plugins/cluster-your-codex/mcp/runtime/node.exe
                       bundled private runtime for the Codex MCP bridge
```

The React application is the shared renderer. Tauri is the intended native
host on Windows, Linux, and macOS; the current self-contained native GUI archive
is Windows-only. The host proxies controller requests so the renderer never
receives the long-lived bearer token. The renderer can send only a typed
`method/path/body` envelope. The native host owns the fixed
`http://127.0.0.1:47831` origin, reads the token from the fixed platform data
root, injects only its own headers, uses no proxy or redirects, and exposes an
explicit route allowlist.

## Windows lifecycle

The current developer preview installs per-user from a self-contained bootstrap
ZIP under:

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

## Linux and macOS preview posture

- The Linux x64 preview is a portable native archive containing
  `cyc-controller`, `cyc-worker`, and `cyc`. It does not install a systemd unit
  or create XDG state automatically.
- The macOS x64 and arm64 previews are portable controller/CLI archives. They
  contain `cyc-controller` and `cyc`, but deliberately omit `cyc-worker`.
  Managed execution on macOS remains fail-closed until a containment backend
  can prove that the complete process tree has terminated.
- Future Linux lifecycle packaging is expected to use a systemd user service
  and XDG data/state directories. Future macOS lifecycle packaging is expected
  to use a LaunchAgent and Application Support/Logs directories.
- The same controller protocol, data ownership, rollback, and evidence rules
  remain the cross-platform contract; an archive does not claim that a future
  service lifecycle is already implemented.

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
marketplaces, or other plugins. The MCP package contains a compiled TypeScript
entry and production dependencies. The Windows self-contained preview also
bundles a private Node runtime whose copied bytes are hash-recorded in the
preview manifest and `SHA256SUMS`; the standalone integration preview instead
requires Node.js 20 or newer on `PATH`. A native MCP binary can replace it later
without changing tool contracts.

Install, upgrade, repair, and uninstall record only non-secret owned resources
and hashes. Uninstall removes those exact resources and preserves user data by
default. `-PurgeData` is the explicit destructive option.

Tauri 2 has a current-user NSIS target in source configuration, but the release
workflow does not build or publish it. The bootstrap ZIP is the implemented
developer-preview lifecycle. It must not be described as a signed, single-file,
one-click Windows installer.

## Published developer-preview set

The release workflow publishes the following preview archives:

| Artifact suffix | Contents | Current use |
| --- | --- | --- |
| `windows-x64-preview.zip` | `cyc-controller.exe`, `cyc-worker.exe`, `cyc.exe` | Portable native controller/worker/CLI preview |
| `linux-x64-preview.tar.gz` | `cyc-controller`, `cyc-worker`, `cyc` | Portable native controller/worker/CLI preview |
| `macos-x64-preview.tar.gz` | `cyc-controller`, `cyc` | Native Intel controller/CLI preview; worker omitted |
| `macos-arm64-preview.tar.gz` | `cyc-controller`, `cyc` | Native Apple Silicon controller/CLI preview; worker omitted |
| `integration-preview.zip` | Compiled renderer and Codex marketplace/plugin | Integration assets only; no native application or installer |
| `windows-x64-self-contained-preview.zip` | GUI, controller, worker, CLI, bootstrap, Codex integration, private Node runtime | Windows-first extracted bootstrap preview |

Every platform/integration archive contains `PREVIEW-NOTICE.md`,
`platform-status.json`, and `release-manifest.json`. Each archive also has an
adjacent SHA-256 sidecar. The release-index job downloads all six producer
artifacts, verifies every sidecar against the downloaded bytes, rejects missing
or duplicate expected assets, and emits a combined `SHA256SUMS` plus
`release-index.json`. A tagged draft prerelease depends on that index job and
publishes only its verified assembled output.

All native Rust release jobs run full-workspace `cargo fmt`, `cargo clippy`, and
`cargo test` before their release build. Windows, Linux, macOS Intel, and macOS
Apple Silicon binaries are built on native runners. Staging checks the native
binary format and architecture, verifies Unix executable bits, and runs native
`--version` and `--help` smoke checks for every binary that will be shipped.
The self-contained Windows job also checks the GUI PE architecture and reruns
the Windows bootstrap lifecycle tests before creating its archive.

These are unsigned and unattested developer previews. The workflow does not
produce or claim code signing, Apple notarization, a one-click NSIS installer,
an SBOM, provenance/attestations, automatic update support, or a stable-release
support policy. Checksums and JSON inventories establish byte identity within
the workflow output; they are not a substitute for those missing release
controls. Windows/Linux managed workers execute trusted jobs as the worker OS
account and are not hostile-workload or multi-tenant sandboxes. See
[`managed-worker-protocol.md`](managed-worker-protocol.md) for the execution and
containment contract.
