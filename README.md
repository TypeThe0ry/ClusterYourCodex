# ClusterYourCodex

> **Give Codex more computers.**

ClusterYourCodex is a Codex-first controller and worker fleet for computers you
own. It places build, test, batch, container, and GPU work on a compatible
worker, then returns native exit status, logs, cleanup state, and artifact
hashes to the Codex session.

[![Stable release](https://img.shields.io/github/v/release/TypeThe0ry/ClusterYourCodex?label=stable&sort=semver)](https://github.com/TypeThe0ry/ClusterYourCodex/releases) [![Latest prerelease](https://img.shields.io/github/v/release/TypeThe0ry/ClusterYourCodex?include_prereleases&label=latest%20preview&sort=semver)](https://github.com/TypeThe0ry/ClusterYourCodex/releases) [![CI](https://github.com/TypeThe0ry/ClusterYourCodex/actions/workflows/ci.yml/badge.svg)](https://github.com/TypeThe0ry/ClusterYourCodex/actions) [![License](https://img.shields.io/github/license/TypeThe0ry/ClusterYourCodex)](LICENSE)

![ClusterYourCodex execution flow](docs/assets/cluster-your-codex-flow.svg)

## Current public status

The current public download is **[ClusterYourCodex v0.1.0 (unsigned public release)](https://github.com/TypeThe0ry/ClusterYourCodex/releases/tag/v0.1.0-preview.113)**. The immutable payload tag remains `v0.1.0-preview.113`, so the binaries, manifests, checksums, and product version stay internally consistent; GitHub marks the release as the latest non-prerelease download. It carries the Windows stale-`AGENTS.md` receipt recovery fix, macOS descendant-identity tracking, native integration diagnostics, Windows shortcut refresh, profile-matrix transport hardening, and the dependency/test-fixture updates merged after preview.111.

This is an intentionally **unsigned public release**. Windows may show an
unknown-publisher warning. Verify the adjacent SHA-256 sidecar before launch.
No Authenticode, Developer ID, or cryptographic stable-GA signing claim is made.

| Area | Status |
| --- | --- |
| Windows x64 desktop/controller | Public unsigned release; install, repair, plugin registration, health, and controller/worker checks are available. |
| Linux x64 worker | Public Worker Kit and Windows → Linux validation path. |
| macOS x64 / arm64 worker packages | Worker Kits build and verify; native managed-runtime acceptance is deferred until a real macOS LaunchAgent/containment run exists. |
| LAN discovery | Credential-free metadata discovery on the local IPv4 broadcast segment; pairing and SSH approval remain explicit. |
| Live deployment | The v0.1.0 public release is the final runnable build for the current scope. The Windows controller/plugin/MCP path and the retained NUC Linux proof are verified with their exact build labels; Windows ↔ Linux and Linux ↔ Linux evidence is preserved. Helio remains a separately re-enrollable worker and is not counted as a fresh proof until its heartbeat is current. |
| Supported release scope | Windows controller/desktop and Linux workers are runnable. macOS packages are published for inspection but managed macOS execution remains fail-closed until native containment and LaunchAgent evidence exist. |

For the authoritative commit, workflow runs, VM evidence, and release decision, see
the [release promotion audit](docs/current-audit-20261006.md), the [VMware record](docs/vmware-preview111-20261004.md), the [live deployment record](docs/live-deployment-preview111-20261004.md), and [project status](docs/project-status.md). The records identify the exact build they exercised; historical preview.111 evidence is not silently relabeled as preview.113 evidence.

## Install the public Windows build

1. Download Windows Setup for the latest public release from the [releases page](https://github.com/TypeThe0ry/ClusterYourCodex/releases) and its matching `.sha256` sidecar.
2. Verify the download before running it:

   ~~~powershell
   $setup = Resolve-Path .\ClusterYourCodex-Setup.exe
   $actual = (Get-FileHash -Algorithm SHA256 $setup).Hash.ToLowerInvariant()
   $expected = ((Get-Content "$setup.sha256" -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
   if ($actual -cne $expected) { throw 'SHA-256 mismatch' }
   ~~~

3. Run Setup. Per-user files are installed under
   %LOCALAPPDATA%\Programs\ClusterYourCodex; the desktop and native Codex
   plugin are registered together.
4. Open **Add Computer**. Use **Scan local network** to prefill a running CYC
   controller, or enter a worker host manually. Confirm the SSH host-key
   fingerprint, then install, pair, start, and probe the worker.
5. Run **Advanced verification → Full Run Check**, then ask Codex to execute a
   real build or test.

The installer is currently code-unsigned. Keep the sidecar beside Setup and
verify it before launch. The supported execution boundary is a trusted,
single-user workload; hostile multi-tenant isolation is outside this release.

## What the UI does

The desktop keeps the main path short:

- **Add Computer** discovers or registers a worker, checks reachability, and
  guides SSH installation and explicit pairing.
- **Run Check** reports health, plugin state, worker capabilities, and a real
  controller-to-worker probe.
- The activity view shows placement, queue/running/succeeded state, logs,
  cleanup, and artifact verification for each run.

![First launch in a clean Windows VM](docs/assets/windows-vm-first-launch.png)

The screenshot shows the first-run Windows firewall prompt and the empty-fleet
home screen. It demonstrates the desktop rendering and first launch only; it is
not proof of remote-worker connectivity. The validation diagram below is a
summary of recorded checks, not a live dashboard.

![Validation status summary](docs/assets/validation-status.svg)

## LAN discovery and credentials

**Scan local network** sends a credential-free UDP discovery probe on the local
IPv4 layer-2 segment (UDP 47830). It returns metadata such as address, role,
version, and pairing readiness. It does not enumerate routed subnets, transmit
an SSH password, or pair a machine automatically.

Host-key approval, SSH credentials, worker installation, and pairing are still
explicit steps. Passwords, private keys, and bearer tokens stay behind native
vault/config references and never enter JobSpec, MCP payloads, logs, or Codex
messages. Windows may remember a password in Credential Manager; other
controllers use an explicit session-only path when no persistent native vault
is available.

See the [cross-platform validation and discovery record](docs/cross-platform-validation-20260927.md)
and the [SSH onboarding harness](docs/provisioning-ssh-e2e-20261001.md).

## Native Codex plugin recovery

If Codex reports **“The installed Codex payload or its build catalog failed
integrity verification”** or **“built-in Codex plugin payload is missing or
incomplete”**, repair the native payload from a source checkout. This is a
build-tool path, not a dependency-free Setup shortcut:

~~~powershell
$marketplace = Join-Path $env:USERPROFILE '.codex/marketplaces/clusteryourcodex'
powershell -ExecutionPolicy Bypass -File scripts/Install-NativeCodexPlugin.ps1 -MarketplaceRoot $marketplace -Repair
~~~

The script backs up an interrupted or partial marketplace, rebuilds the
payload, verifies the manifest and hashes, probes the bundled MCP runtime, and
registers the native plugin. It removes exact-name legacy clustor,
cluster-orchestrator, and orchestrator skill directories into a recoverable
timestamped backup; it does not rely on those skills.

Verify the contract and cached payload with:

~~~powershell
powershell -ExecutionPolicy Bypass -File scripts/Test-NativeCodexPluginContract.ps1
$pluginRoot = Join-Path $env:LOCALAPPDATA 'Programs/ClusterYourCodex/integrations/codex-marketplace/plugins/cluster-your-codex'
powershell -ExecutionPolicy Bypass -File scripts/Test-NativeCodexPlugin.ps1 -PluginRoot $pluginRoot
pnpm --filter @clusteryourcodex/codex-mcp test -- --run
~~~

The [plugin recovery record](docs/native-plugin-recovery-20260918.md) and
[cache verification record](docs/native-plugin-cache-verification-20260919.md)
contain the detailed probes and expected boundaries. A failed integrity check
should be repaired, not bypassed.

## How work is placed

~~~text
Codex session
    -> native ClusterYourCodex plugin + MCP bridge
    -> local Controller (requirements, telemetry, reservations)
    -> Windows / Linux / macOS Worker
    -> exit status + logs + SHA-256 artifact evidence
~~~

The Controller chooses a compatible worker from current capabilities, load, and
reservations. The model supplies requirements and consumes verified results; it
does not choose a worker from a stale snapshot and never receives worker
credentials.

The repository is organized around cyc-controller (API, persistence,
scheduling, and lifecycle), cyc-worker (inventory, pairing, execution),
cyc-cli (diagnostics), cyc-protocol (portable contracts), cyc-scheduler
(explainable placement), apps/desktop, and the native
plugins/cluster-your-codex package.

## Validation boundaries

Hosted CI covers Rust on Windows/Linux/macOS, Worker Kit packaging, security
checks, the desktop bridge, and Windows controller/worker fixtures. D-drive
VMware evidence covers Windows Setup, health, repair, uninstall, discovery, and
same-host live round trips. Independent Windows ↔ Linux and Linux ↔ Linux
records are retained in the validation docs.

The supported Windows/Linux path is runnable and is covered by hosted CI,
VMware Setup/Repair/Uninstall evidence, and cross-node round-trip records.
The remaining non-blocking release evidence is a clean guest matrix covering
Install → Repair → versioned Upgrade → interrupted Rollback → Uninstall, plus
production Authenticode/tray signing. macOS remains deliberately fail-closed:
its packages can be inspected, but managed execution is not enabled without a
native LaunchAgent/containment proof. Issues #2 and #3 are closed for the
declared Windows/Linux runnable scope. The exact evidence and remaining
Certified GA boundaries are recorded in the [release checklist](RELEASE.md)
and [current audit](docs/current-audit-20261005.md).

## Develop

~~~powershell
git clone https://github.com/TypeThe0ry/ClusterYourCodex.git
cd ClusterYourCodex
pnpm install --frozen-lockfile
cargo fmt --all -- --check
cargo test --workspace
pnpm -r lint
pnpm -r test
pnpm -r build
~~~

Use pnpm dev for the browser renderer. For the native desktop, use
pnpm --filter @clusteryourcodex/desktop tauri:dev with Rust and the Tauri
Windows prerequisites installed. Packaging, acceptance, and release rules are
in [docs/packaging.md](docs/packaging.md) and [docs/release-process.md](docs/release-process.md).

The browser renderer can read controller health and fleet data through its
loopback development proxy, but it does not receive the native Tauri bridge.
Plugin install/repair, SSH provisioning, and full-run checks are therefore
disabled in the browser preview and clearly marked as desktop-only. Use the
native command above (or the packaged app) for those actions; this keeps
credentials and host-side operations out of browser JavaScript.

## Documentation map

- [Windows getting started](docs/getting-started-windows.md)
- [Add a Windows computer](docs/add-windows-computer.md)
- [Add a Linux computer](docs/add-linux-computer.md)
- [Codex integration](docs/codex-integration.md)
- [Upgrade, repair, rollback, uninstall](docs/upgrade-rollback.md)
- [Compatibility and security boundary](docs/compatibility.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Cross-platform validation and LAN discovery](docs/cross-platform-validation-20260927.md)
- [Current audit](docs/current-audit-20261005.md)
- [Live deployment evidence](docs/live-deployment-preview111-20261004.md)
- [Local Windows live round trip](docs/local-windows-roundtrip-20261005.md)
- [Project status](docs/project-status.md)
- [Changelog](CHANGELOG.md)
- [Contributing](CONTRIBUTING.md)

## Product boundary and license

ClusterYourCodex distributes executable work initiated by Codex. It is not a
remote desktop, generic cluster administrator, or hostile-code sandbox. See
[ADR 0001](docs/adr/0001-product-boundary.md) for the product boundary and
[LICENSE](LICENSE) for licensing terms.
