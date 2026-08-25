# ClusterYourCodex

**Give Codex more computers.** ClusterYourCodex lets Codex place build, test,
container, GPU, and batch workloads on the best compatible computer in a
user-owned fleet, then return verified logs and artifacts.

> **Release status:** Windows-first prerelease. The Windows controller/desktop
> and trusted-job Windows/Linux worker paths are implemented and CI-verified,
> but password/agent/private-key live authentication and cross-node GUI/MCP
> acceptance are still pending. macOS x64/arm64 archives and signed Worker Kits
> are packaged, but managed execution remains `runtimeGated=true`,
> `containmentReady=false`, and `liveReady=false`. Prerelease installers remain
> code-unsigned. Verify the published SHA-256 sidecar before running one.

## Windows preview setup and acceptance path

The flow below is the implemented preview workflow and the procedure for
collecting live acceptance evidence. It is not a claim that every SSH
authentication mode, worker OS, or cross-node path has already passed on real
hardware.

1. Open [GitHub Releases](https://github.com/TypeThe0ry/ClusterYourCodex/releases)
   and download `ClusterYourCodex-Setup.exe` plus its adjacent `.sha256` file
   from the newest **Prerelease**.
2. Verify the installer before opening it:

   ```powershell
   $setup = Resolve-Path .\ClusterYourCodex-Setup.exe
   $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $setup).Hash.ToLowerInvariant()
   $expected = ((Get-Content "$setup.sha256" -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
   if ($actual -cne $expected) { throw 'ClusterYourCodex installer hash mismatch' }
   ```

3. Run Setup. It installs per-user files below
   `%LOCALAPPDATA%\Programs\ClusterYourCodex`, preserves unrelated global
   `AGENTS.md` content, registers the local Codex plugin, and opens the GUI.
4. In **Add Computer**, enter the worker host and SSH user, then choose the
   implemented password, native SSH-agent, or validated local-private-key path.
   Compare and approve the displayed host-key fingerprint, then exercise the
   install, pair, start, and probe stages. Accepted remembered passwords are
   stored only in the native credential vault; passwords, key passphrases, and
   keys never enter Codex tool calls.
5. Run **Full Run Check**, restart Codex once when prompted, then ask Codex to
   run a meaningful build or test. Preserve the resulting source, placement,
   native-exit, log, artifact, and cleanup evidence; a successful run proves
   that exact environment, not the still-pending global live-acceptance matrix.

Rerun the exact same-version Setup for the verified Repair path. Installing a
newer prerelease over an older one is an experimental upgrade-acceptance path;
supported signed `N-1 -> N`, interrupted-upgrade rollback, and downgrade policy
remain GA gates. Uninstall from Windows **Installed apps**; user data is
preserved by default. See the
[Windows getting-started guide](docs/getting-started-windows.md),
[compatibility matrix](docs/compatibility.md), and
[troubleshooting guide](docs/troubleshooting.md) before reporting a failure.

## Product boundary

ClusterYourCodex distributes the executable work that Codex initiates. It does
not distribute OpenAI-hosted model inference and it is not a remote-desktop or
general-purpose cluster administration product.

## Architecture

```text
Codex Desktop / CLI
        |
Codex Plugin + MCP bridge
        |
ClusterYourCodex Controller  <---- Desktop GUI
        |
Scheduler / queue / source / artifacts / trust
        |
        Windows/Linux workers; runtime-gated macOS Worker Kits
```

The first release is composed of:

- `cyc-controller`: local API, persistent jobs, scheduling, and execution state.
- `cyc-worker`: capability probe and managed-worker bootstrap foundation.
- `cyc-cli`: diagnostics and operator fallback.
- `cyc-protocol`: versioned cross-platform domain model.
- `cyc-scheduler`: compatibility filtering and explainable placement.
- `apps/desktop`: Windows-first desktop interface.
- `plugins/cluster-your-codex`: Codex Skill and MCP bridge.

## Declared preview topology

```text
Mac/Windows/Linux remote UI (optional)
                |
       Codex session host
       Windows controller + GUI
          /              \
 Windows worker       Linux worker
```

The controller follows the computer on which the Codex execution session runs,
not necessarily the screen being used to control it. A Mac can therefore be a
remote control surface while a Windows PC runs Codex and ClusterYourCodex.
The topology is implemented and CI-tested; live password/agent/private-key and
Windows-controller-to-Windows/Linux-worker acceptance remains pending.

The current worker boundary is **trusted, single-user workloads**. A submitted
step executes with the worker account's authority. It is not a multi-tenant or
hostile-code sandbox; do not submit untrusted third-party workloads until the
opt-in isolation milestone is complete. The preview reports all configured
hostile backends as unready, publishes no hostile scheduling capabilities, and
fails closed before hostile execution on Linux, Windows, and macOS.

## Design rules

- No built-in host names, IP addresses, drive letters, users, or fixed fleet size.
- Codex never receives worker passwords, private keys, or raw secret material.
- Codex submits typed workload requirements; the Controller uses current
  telemetry and reservations to atomically choose and reserve a worker. Codex
  does not select a node from a stale status snapshot unless the user explicitly
  requests manual placement.
- Every run records its source identity, selected node and reason, native exit
  code, elapsed time, logs, verification, and artifact hashes.
- Jobs own their workspaces. Cancellation and cleanup never touch unrelated
  files or processes.
- Existing global `AGENTS.md` content is preserved byte-for-byte outside one
  uniquely marked ClusterYourCodex block. Install/Repair updates only that
  block after plugin activation is verified, and Uninstall removes only that
  block with durable journaling, compare-and-swap, and fail-closed drift checks.
- The GUI can finish or repair only the Codex-facing step through the
  non-elevated `bootstrap.ps1 -Action IntegrateCodex` receipt interface. It
  verifies the exact installed/enabled plugin version and local source before
  touching the managed block; it does not restart the controller or modify a
  service, Scheduled Task, firewall rule, or worker configuration.

See [`docs/adr/0001-product-boundary.md`](docs/adr/0001-product-boundary.md)
for the initial architecture decision. The next execution and distribution
gates are defined in
[`docs/managed-worker-protocol.md`](docs/managed-worker-protocol.md) and
[`docs/packaging.md`](docs/packaging.md).

## Documentation

- [Install on Windows](docs/getting-started-windows.md)
- [Add a Windows computer](docs/add-windows-computer.md)
- [Add a Linux computer](docs/add-linux-computer.md)
- [Verify Codex integration](docs/codex-integration.md)
- [Upgrade, repair, rollback, and uninstall](docs/upgrade-rollback.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Compatibility and security boundary](docs/compatibility.md)
- [Release process and prerelease policy](docs/release-process.md)
- [Changelog](CHANGELOG.md)
- [Support policy](SUPPORT.md)
