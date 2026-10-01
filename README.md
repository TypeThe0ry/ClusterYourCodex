# ClusterYourCodex

> **Give Codex more computers.**

ClusterYourCodex is a Codex-first controller and worker fleet for distributing builds, tests, batch jobs, containers, and GPU work across computers you own. The Controller chooses a compatible worker from current telemetry and reservations, then returns verified logs and artifact hashes to the Codex session.

[![Stable release](https://img.shields.io/github/v/release/TypeThe0ry/ClusterYourCodex?label=stable&sort=semver)](https://github.com/TypeThe0ry/ClusterYourCodex/releases) [![Latest prerelease](https://img.shields.io/github/v/release/TypeThe0ry/ClusterYourCodex?include_prereleases&label=latest%20preview&sort=semver)](https://github.com/TypeThe0ry/ClusterYourCodex/releases) [![CI](https://github.com/TypeThe0ry/ClusterYourCodex/actions/workflows/ci.yml/badge.svg)](https://github.com/TypeThe0ry/ClusterYourCodex/actions) [![License](https://img.shields.io/github/license/TypeThe0ry/ClusterYourCodex)](LICENSE)

![ClusterYourCodex execution flow](docs/assets/cluster-your-codex-flow.svg)

> **Repository snapshot:** `main` contains the published `v0.0.1` stable line;
> current fixes are delivered as prerelease candidates until their acceptance
> evidence is complete. The published `v0.0.1` tag and assets are immutable.

## Start here

| Goal | Action |
| --- | --- |
| Use the published baseline | Install [`v0.0.1`](https://github.com/TypeThe0ry/ClusterYourCodex/releases/tag/v0.0.1) |
| Use the current Codex integration fix | Use the [source-checkout repair](#codex-plugin-integrity); the published preview predates this fix |
| Recover a broken native plugin | Run the [one-command repair](#codex-plugin-integrity) below |
| Verify a checkout | Run the [native plugin checks](#native-plugin-checks) |

## Status at a glance

### Clean Windows VM: first application launch

![ClusterYourCodex running in a clean Windows VM, with the first-run Windows firewall prompt](docs/assets/windows-vm-first-launch.png)

On 2026-09-23, a local diagnostic installer containing the `v0.0.1` binaries
and a bootstrap path-length fix installed successfully in the clean VM
(exit 0). The desktop rendered its Chinese empty-fleet home screen, and the
controller health endpoint returned HTTP 200 with a healthy database. The
screenshot includes the first-run Windows firewall prompt; it does not prove
remote worker connectivity. This diagnostic package is not the published
installer or a current-source release candidate. See the
[installation evidence and remaining checks](docs/windows-vm-install-20260923.md).

![Validation status](docs/assets/validation-status.svg)

### What the test effect means

The green cards above are backed by repeatable checks, not a decorative claim:

- **Native plugin:** the integrity contract, bundled runtime, MCP protocol probe, and 48-test MCP suite pass on the Windows controller host. See the [cache verification record](docs/native-plugin-cache-verification-20260919.md).
- **Hosted CI:** the current candidate exercises Rust on Windows/Linux/macOS, native Linux/macOS Worker Kits, dependency/security checks, and the Windows controller/bridge path. See [GitHub Actions](https://github.com/TypeThe0ry/ClusterYourCodex/actions) for the run history.
- **Acceptance status:** the current source has an independent VMware Windows-controller → Windows-host-worker live job, a VMware Windows-controller → independent Linux-worker live job, and an independent Linux-controller → Linux-worker live job. LAN discovery is credential-free and paired enrollment remains explicit. The Windows VM uses a guest-only TPM-check exception and modified no-prompt media, so it does not prove Windows 11 hardware compliance. Native macOS managed-runtime validation is intentionally deferred; [Issue #3](https://github.com/TypeThe0ry/ClusterYourCodex/issues/3) remains open.
- **LAN discovery boundary:** automatic discovery is an IPv4 broadcast on the local layer-2 segment; it does not enumerate routed subnets. The Windows candidate now provisions UDP `47830` beside the worker TCP rule in one transactional firewall lifecycle, while legacy v1 transactions remain recoverable. A clean current-source VM install/repair/rollback/uninstall matrix is still an open Issue #2 gate, so manual host entry remains the fallback if a pre-dual-rule installation or a strict network policy blocks discovery.

This distinction keeps the README useful: a passing package test proves the package contract, while a clean-VM or live-worker claim requires the corresponding runtime evidence.

### Recorded candidate test results

#### Current repository audit — 2026-10-01

The current `main` includes PR #157's transactional LAN discovery firewall
path, PR #158's native PowerShell runtime-ownership repair, PR #159's audit
documentation, PR #160's final-main reference correction, and PR #163's
inherited-ACL regression coverage plus a usable worker-address probe. Resolve
the exact live `origin/main` ref with the reproduction commands in the [current
audit record](docs/current-audit-20261001.md) instead of copying a hash into
this document. The candidate CI matrix and Windows Setup
acceptance both passed (runs [36749204624](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/36749204624)
and [36749204684](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/36749204684)).
The latest PR #163 candidate matrix also passed, including the Windows
controller/worker live round trip and packaged acceptance. The detailed record
is in the [2026-10-01 audit](docs/current-audit-20261001.md), the
[2026-09-30 audit](docs/current-audit-20260930.md)
and the [runtime repair note](docs/windows-runtime-repair-20261001.md).

The D-drive VMware guest is provisioned rather than clean. The current Setup
candidate exited `0`, reached a successful lifecycle diagnostic, returned
controller health HTTP 200/database `ok`, and answered a credential-free LAN
discovery probe. Its installed-package worker round-trip harness stopped before
the worker job proof, so hosted CI remains the authoritative live round-trip
evidence. Keep Issue #2 open until a genuinely clean Windows 11 guest completes
Install → Repair → Upgrade → Rollback → Uninstall and a live worker job.
The latest [`vmrun`-only recheck](docs/vmware-cli-recheck-20261001.md) also
confirmed that the guest can be started, inspected, and soft-stopped cleanly,
but has no interactive logon session for the default Interactive scheduled
task. That session limitation is recorded rather than hidden behind a green
fixture result.
An additional CLI-only session-channel probe confirmed that host keyboard
injection is blocked. A credentialed guest command could enable a temporary
RDP listener, but the host RDP attempt did not produce a stable interactive
session; the validation boundary is documented in the [recheck record](docs/vmware-cli-recheck-20261001.md).
The same recheck then executed the exact current Windows ACL helper in the guest:
fresh transaction children were protected without inherited ACEs, while an
existing weak child was rejected without mutation. This confirms the fail-closed
ACL contract, but does not replace clean-VM lifecycle evidence.

#### Historical repository audit — 2026-09-23

The authoritative source is the live `origin/main` ref; resolve its current
commit with the audit commands below. The audit record tracks the merged
documentation corrections after PR #122 fixed Windows staging failures caused
by long temporary paths. Its completed
candidate checks passed the Windows Setup acceptance run
[`35805960001`](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/35805960001)
and the platform/security checks in
[`35805960000`](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/35805960000).
The later PR #131 candidate run
[`35870549904`](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/35870549904)
also completed successfully and was merged as
`83de510bca30cf6116a20ced105b86ec3e2e9ba5`. PR #133 then recorded a
CLI-created VMware guest, and PR #135 recorded the separate blank-disk media
boundary; both documentation PRs passed the full candidate matrix. Resolve the
live `origin/main` ref with the audit command below instead of relying on a
copied commit hash; PR #137's merge commit is recorded in the audit document.
An in-progress check is not counted as a completed pass.

There are currently no open pull requests. Issues [#2](https://github.com/TypeThe0ry/ClusterYourCodex/issues/2)
and [#3](https://github.com/TypeThe0ry/ClusterYourCodex/issues/3) remain open
because their final runtime gates are still specific and independently
unproven: a current-source clean Windows 11 lifecycle for #2, and a native
macOS LaunchAgent plus managed controller/worker round trip for #3. Hosted CI
and package probes are recorded as evidence, but are not substituted for those
runtime gates. See the [current live audit record](docs/current-audit-20261001.md),
the [2026-09-30 audit](docs/current-audit-20260930.md)
and the historical [2026-09-23 audit](docs/current-audit-20260923.md).

The stable `v0.0.1` tag and assets remain unchanged at
`e4fbaef04b764268fa038311d85573b18b549f9f`. The table below summarizes the
current evidence and is not an automatically refreshed dashboard.

| Test layer | Current result | What was observed |
| --- | --- | --- |
| Rust controller/workspace | PASS | Windows, Ubuntu, and macOS jobs completed successfully |
| Native Worker Kits | PASS | Linux x64 plus macOS x64/arm64 package checks completed |
| Security and dependency gates | PASS | CodeQL, RustSec, Cargo deny, and pnpm audit completed |
| Windows controller/bridge job | PASS | Candidate CI completed the Windows controller/worker live round trip |
| D-drive VMware acceptance | PARTIAL | Current Setup install/repair diagnostics and health pass on the provisioned guest; LAN discovery returns a controller candidate without credentials. A complete clean-VM lifecycle and installed-package worker job are not yet proven. See the [runtime repair note](docs/windows-runtime-repair-20261001.md) and [cross-platform validation](docs/cross-platform-validation-20260927.md). |

The diagrams summarize the evidence categories; they are not application screenshots or an automatically refreshed test dashboard. Runtime acceptance remains open until the corresponding evidence is recorded.

| Area | State | Evidence |
| --- | --- | --- |
| Native Codex plugin | Ready | Registration, bundled runtime integrity, and MCP 8-tool smoke pass on Windows |
| Windows controller/worker | Preview-ready | Hosted CI controller/worker round-trip is green; clean-VM GA evidence remains open |
| Linux worker kit | Preview-ready | Native Linux kit build and contract verification pass |
| macOS worker kits | Package-ready | Intel and Apple Silicon kits build and verify; PR #131's containment tests pass in hosted CI, while live managed execution on a customer Mac remains gated |
| Stable release | `v0.0.1` unchanged | New work stays prerelease until the real GA gates in Issues [#2](https://github.com/TypeThe0ry/ClusterYourCodex/issues/2) and [#3](https://github.com/TypeThe0ry/ClusterYourCodex/issues/3) are evidenced |

### Choose the right channel

| You need | Use | What it means |
| --- | --- | --- |
| A published baseline | [`v0.0.1`](https://github.com/TypeThe0ry/ClusterYourCodex/releases/tag/v0.0.1) | Immutable stable assets; no native-plugin recovery fixes |
| A published preview | [v0.1.0-preview.102](https://github.com/TypeThe0ry/ClusterYourCodex/releases/tag/v0.1.0-preview.102) | Latest published preview; it predates the fixes currently on `main` |
| Source development | `main` or a feature branch | Run the checks below before packaging; do not call a preview stable |

For installation fixes and their verification, see the
[native plugin recovery record](docs/native-plugin-recovery-20260918.md).
For current acceptance gaps, see [project status](docs/project-status.md).

## What you get

- **One Windows-first desktop flow:** add a computer, connect Codex, run a check.
- **Typed scheduling:** requirements are filtered against capabilities; current load and reservations decide the best eligible worker.
- **Evidence by default:** every run records placement, native exit status, logs, cleanup state, and artifact SHA-256 values.
- **Portable workers:** Linux and macOS Worker Kits share the same protocol; managed runtime support remains platform-gated.
- **Credential boundaries:** passwords, keys, and bearer tokens stay behind native vault/config references and never enter JobSpec payloads or Codex calls.

## The shortest useful mental model

```text
Codex session
    -> native ClusterYourCodex plugin + MCP bridge
    -> local Controller (typed requirements, reservations, receipts)
    -> Windows / Linux / macOS Worker
    -> exit status + logs + SHA-256 artifact evidence
```

The Controller owns placement. The model supplies requirements and consumes
verified results; it does not pick a worker from a stale snapshot or receive
worker credentials.

## Current release

**Stable: [v0.0.1](https://github.com/TypeThe0ry/ClusterYourCodex/releases/tag/v0.0.1)**

Download [Windows Setup](https://github.com/TypeThe0ry/ClusterYourCodex/releases/download/v0.0.1/ClusterYourCodex-Setup.exe) and its [SHA-256 sidecar](https://github.com/TypeThe0ry/ClusterYourCodex/releases/download/v0.0.1/ClusterYourCodex-Setup.exe.sha256). The release includes the Windows desktop/controller, Codex plugin, self-contained ZIP, Linux/macOS Worker Kits, SBOM, checksums, and provenance.

Windows binaries are currently code-unsigned; verify the sidecar before running Setup. The supported execution boundary is trusted, single-user workloads. Hostile-workload isolation is outside the current product scope; see the decision in [Issue #5](https://github.com/TypeThe0ry/ClusterYourCodex/issues/5). Closing that proposal does not enable the isolated tier.

### Codex plugin integrity

The current Windows installer and integration-preview pipeline ship the native
`cluster-your-codex@clusteryourcodex` plugin with its private Node runtime. The
installer validates the manifest, MCP bridge, runtime, marketplace binding, and
file hashes before registering the plugin. The recovery fixes are in the
repository, not the published `v0.0.1` or `v0.1.0-preview.102` assets. As of
2026-09-19, installing the latest published preview is not a verified remedy
for this error. Use the source-checkout repair below until an installer built
from the corrected source is published; do not copy a plugin directory from a
different build.

For a source-checkout recovery, use an up-to-date checkout with the documented
development dependencies installed and run from its root. This path requires
build tools; it is not the dependency-free Setup experience. Use the native
Codex CLI registration path. Keep
the generated marketplace under a persistent Codex-owned directory; a temporary
marketplace can be deleted by cleanup jobs and make an otherwise healthy plugin
look missing on the next launch:

```powershell
$marketplace = Join-Path $env:USERPROFILE '.codex/marketplaces/clusteryourcodex'
powershell -ExecutionPolicy Bypass -File scripts/Install-NativeCodexPlugin.ps1 `
  -MarketplaceRoot $marketplace
```

If that directory was left empty or partial by an interrupted install, the
installer automatically moves it to a timestamped recoverable backup,
rebuilds the native payload, and runs the integrity and MCP probes. Pass
`-Repair` when you also want to force-rebuild an otherwise complete directory
(for example after an interrupted upgrade):

```powershell
powershell -ExecutionPolicy Bypass -File scripts/Install-NativeCodexPlugin.ps1 `
  -MarketplaceRoot $marketplace -Repair
```

The recovery path uses the bundled MCP runtime and does not install or depend
on legacy `clustor`, `cluster-orchestrator`, or `orchestrator` skills. Each install
also removes exact-name legacy skill directories from the Codex home into a
timestamped recoverable backup before registering the native plugin. See the recorded verification in
[`docs/native-plugin-recovery-20260918.md`](docs/native-plugin-recovery-20260918.md).

### Native plugin checks

From a repository checkout, these commands verify both the contract and the
exact cached payload used by Codex:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/Test-NativeCodexPluginContract.ps1
powershell -ExecutionPolicy Bypass -File scripts/Test-NativeCodexPlugin.ps1 `
  -PluginRoot "$env:USERPROFILE/.codex/plugins/cache/clusteryourcodex/cluster-your-codex/0.0.1"
pnpm --filter @clusteryourcodex/codex-mcp test -- --run
```

The current recovery record is [`docs/native-plugin-cache-verification-20260919.md`](docs/native-plugin-cache-verification-20260919.md); it records the
6-file cache check, the MCP `2025-06-18` / 8-tool probe, and the 48-test MCP
suite. A failed cache check should be repaired, not bypassed.

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
4. In **Add Computer**, choose **Scan local network** to find running CYC controllers, or enter the worker host manually. Selecting a candidate only pre-fills the SSH host; verify the host-key fingerprint, then run install, pair, start, and probe.
5. Open **Advanced verification** and run **Full Run Check**. Then ask Codex to run a real build or test.

To find controllers already running on the same private LAN, use **Scan local
network** in Add Computer or run `cyc discover --pretty`. Both paths send a
credential-free UDP probe and return only metadata candidates; neither pairs
automatically or transmits an SSH password. Verify the SSH host key, then use
the normal Add Computer flow for install, pairing, and the first probe. The
protocol and current validation boundaries are recorded in
[`docs/cross-platform-validation-20260927.md`](docs/cross-platform-validation-20260927.md).

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
- [Cross-platform validation and LAN discovery](docs/cross-platform-validation-20260927.md)
- [Current VMware candidate install probe](docs/vmware-current-candidate-install-20261001.md)

Open acceptance work is tracked in [#2](https://github.com/TypeThe0ry/ClusterYourCodex/issues/2)
and [#3](https://github.com/TypeThe0ry/ClusterYourCodex/issues/3). Hosted CI and
portable archives do not substitute for the native Windows/macOS runtime gates
called out in those issues.

## Project boundary

ClusterYourCodex distributes executable work that Codex initiates. It is not a remote desktop, generic cluster administrator, or multi-tenant hostile-code sandbox. See [ADR 0001](docs/adr/0001-product-boundary.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

## License

See [LICENSE](LICENSE).
