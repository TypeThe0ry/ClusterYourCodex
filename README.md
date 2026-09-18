# ClusterYourCodex

> **Give Codex more computers.**

ClusterYourCodex is a Codex-first controller and worker fleet for distributing builds, tests, batch jobs, containers, and GPU work across computers you own. The Controller chooses a compatible worker from current telemetry and reservations, then returns verified logs and artifact hashes to the Codex session.

[![Stable release](https://img.shields.io/github/v/release/TypeThe0ry/ClusterYourCodex?label=stable&sort=semver)](https://github.com/TypeThe0ry/ClusterYourCodex/releases) [![CI](https://github.com/TypeThe0ry/ClusterYourCodex/actions/workflows/ci.yml/badge.svg)](https://github.com/TypeThe0ry/ClusterYourCodex/actions) [![License](https://img.shields.io/github/license/TypeThe0ry/ClusterYourCodex)](LICENSE)

> **Repository snapshot:** `main` contains the published `v0.0.1` stable line;
> current fixes are delivered as prerelease candidates until their acceptance
> evidence is complete. The published `v0.0.1` tag and assets are immutable.

## Status at a glance

| Area | State | Evidence |
| --- | --- | --- |
| Native Codex plugin | Ready | Registration, bundled runtime integrity, and MCP 8-tool smoke pass on Windows |
| Windows controller/worker | Preview-ready | Hosted CI controller/worker round-trip is green; clean-VM GA evidence remains open |
| Linux worker kit | Preview-ready | Native Linux kit build and contract verification pass |
| macOS worker kits | Package-ready | Intel and Apple Silicon kits build and verify; live managed execution remains gated |
| Stable release | `v0.0.1` unchanged | New work stays prerelease until the real GA gates in Issues [#2](https://github.com/TypeThe0ry/ClusterYourCodex/issues/2) and [#3](https://github.com/TypeThe0ry/ClusterYourCodex/issues/3) are evidenced |

The latest merged native-plugin recovery work is tracked in [PR #89](https://github.com/TypeThe0ry/ClusterYourCodex/pull/89); the implementation fix is in [PR #87](https://github.com/TypeThe0ry/ClusterYourCodex/pull/87).
The working tree also preserves any local, uncommitted user changes; release
automation never moves or rewrites the `v0.0.1` tag.

## What you get

- **One Windows-first desktop flow:** add a computer, connect Codex, run a check.
- **Typed scheduling:** requirements are filtered against capabilities; current load and reservations decide the best eligible worker.
- **Evidence by default:** every run records placement, native exit status, logs, cleanup state, and artifact SHA-256 values.
- **Portable workers:** Linux and macOS Worker Kits share the same protocol; managed runtime support remains platform-gated.
- **Credential boundaries:** passwords, keys, and bearer tokens stay behind native vault/config references and never enter JobSpec payloads or Codex calls.

## Current release

**Stable: [v0.0.1](https://github.com/TypeThe0ry/ClusterYourCodex/releases/tag/v0.0.1)**

Download [Windows Setup](https://github.com/TypeThe0ry/ClusterYourCodex/releases/download/v0.0.1/ClusterYourCodex-Setup.exe) and its [SHA-256 sidecar](https://github.com/TypeThe0ry/ClusterYourCodex/releases/download/v0.0.1/ClusterYourCodex-Setup.exe.sha256). The release includes the Windows desktop/controller, Codex plugin, self-contained ZIP, Linux/macOS Worker Kits, SBOM, checksums, and provenance.

Windows binaries are currently code-unsigned; verify the sidecar before running Setup. The supported execution boundary is trusted, single-user workloads. Hostile-workload isolation is outside the current product scope; see the decision in [Issue #5](https://github.com/TypeThe0ry/ClusterYourCodex/issues/5). Closing that proposal does not enable the isolated tier.

### Codex plugin integrity

The current Windows installer and integration-preview pipeline ship the native
`cluster-your-codex@clusteryourcodex` plugin with its private Node runtime. The
installer validates the manifest, MCP bridge, runtime, marketplace binding, and
file hashes before registering the plugin. These fixes are in the current
prerelease candidate; the published `v0.0.1` assets are unchanged. If Codex
reports that the payload is missing or incomplete, install the newest candidate
and run the desktop **Repair** action; do not copy a plugin directory from a
different build.

For a source-checkout recovery, use the native Codex CLI registration path. Keep
the generated marketplace under a persistent Codex-owned directory; a temporary
marketplace can be deleted by cleanup jobs and make an otherwise healthy plugin
look missing on the next launch:

```powershell
$marketplace = Join-Path $env:USERPROFILE '.codex/marketplaces/clusteryourcodex'
powershell -ExecutionPolicy Bypass -File scripts/Install-NativeCodexPlugin.ps1 `
  -MarketplaceRoot $marketplace
```

If that directory was left empty or partial by an interrupted install, add
`-Repair`. The installer moves the incomplete directory to a timestamped
backup, rebuilds the native payload, and runs the integrity and MCP probes:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/Install-NativeCodexPlugin.ps1 `
  -MarketplaceRoot $marketplace -Repair
```

The recovery path uses the bundled MCP runtime and does not install or depend
on legacy `clustor` or `cluster-orchestrator` skills. See the recorded verification in
[`docs/native-plugin-recovery-20260918.md`](docs/native-plugin-recovery-20260918.md).

## Platform status

| Platform | Current delivery |
| --- | --- |
| Windows x64 | Desktop, Controller and Worker; full clean-VM Repair/rollback acceptance remains tracked in [#2](https://github.com/TypeThe0ry/ClusterYourCodex/issues/2). The running-Controller repair race from #68 is fixed and closed. |
| Linux x64 | Worker packages; see the [Linux setup guide](docs/add-linux-computer.md). |
| macOS x64 / arm64 | Worker Kit packages; live managed execution acceptance is still open in [#3](https://github.com/TypeThe0ry/ClusterYourCodex/issues/3). |

## Fast start on Windows

1. Download Setup and the `.sha256` sidecar.
2. Verify the installer:

   ```powershell
   $setup = Resolve-Path .\ClusterYourCodex-Setup.exe
   $actual = (Get-FileHash -Algorithm SHA256 $setup).Hash.ToLowerInvariant()
   $expected = ((Get-Content "$setup.sha256" -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
   if ($actual -cne $expected) { throw 'SHA-256 mismatch' }
   ```

3. Run Setup. It installs per-user files under `%LOCALAPPDATA%\Programs\ClusterYourCodex`, registers the Codex plugin, and opens the desktop.
4. In **Add Computer**, enter the worker host and user, verify the host-key fingerprint, then run install, pair, start, and probe.
5. Open **Advanced verification** and run **Full Run Check**. Then ask Codex to run a real build or test.

## How it works

```text
Codex Desktop / CLI
        |
Codex plugin + MCP bridge
        |
Controller <---- Windows desktop
        |
typed requirements -> scheduler -> reservation
        |
Windows / Linux / macOS workers
        |
verified logs + artifacts
```

The repository is organized around `cyc-controller` (local API, persistence, scheduling, and run lifecycle), `cyc-worker` (inventory, pairing, execution), `cyc-cli` (diagnostics), `cyc-protocol` (portable contracts), `cyc-scheduler` (explainable placement), `apps/desktop`, and `plugins/cluster-your-codex`.

## Development

```powershell
git clone https://github.com/TypeThe0ry/ClusterYourCodex.git
cd ClusterYourCodex
pnpm install --frozen-lockfile
cargo fmt --all -- --check
cargo test --workspace
pnpm -r lint
pnpm -r test
pnpm -r build
```

Run the browser renderer with `pnpm dev`; it is not the installed native app. For the native desktop use `pnpm --filter @clusteryourcodex/desktop tauri:dev` (Rust and the Tauri Windows build prerequisites are required). Packaging and acceptance details live in [docs/packaging.md](docs/packaging.md).

## Documentation

- [Windows getting started](docs/getting-started-windows.md)
- [Add a Windows computer](docs/add-windows-computer.md)
- [Linux worker](docs/add-linux-computer.md)
- [Codex integration](docs/codex-integration.md)
- [Upgrade, repair, rollback, uninstall](docs/upgrade-rollback.md)
- [Compatibility and security boundary](docs/compatibility.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Release process](docs/release-process.md)
- [Changelog](CHANGELOG.md)
- [Project status](docs/project-status.md)

Open acceptance work is tracked in [#2](https://github.com/TypeThe0ry/ClusterYourCodex/issues/2)
and [#3](https://github.com/TypeThe0ry/ClusterYourCodex/issues/3). Hosted CI and
portable archives do not substitute for the native Windows/macOS runtime gates
called out in those issues.

## Project boundary

ClusterYourCodex distributes executable work that Codex initiates. It is not a remote desktop, generic cluster administrator, or multi-tenant hostile-code sandbox. See [ADR 0001](docs/adr/0001-product-boundary.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

## License

See [LICENSE](LICENSE).
