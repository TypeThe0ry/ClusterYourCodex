# Current GitHub and preview release audit — 2026-10-03

This is the current release record for `TypeThe0ry/ClusterYourCodex`. It uses
the live GitHub repository and published assets as the authority; older audit
records remain historical context only.

## Published source and workflow evidence

- `origin/main`: `c152f701432ce07a91f292e2ac325236883b60c5` (PR #181 squash
  merge).
- Exact push CI: [run 37023051938](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/37023051938),
  successful. It covered Windows/Linux/macOS Rust, MSRV, Worker Kits, CodeQL,
  dependency security, desktop integration, and the Windows controller/worker
  live round trip.
- Preview release workflow: [run 37023139818](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/37023139818),
  successful. Its first attempt was correctly fail-closed because push CI was
  still running; the same tagged run was rerun after exact CI completed.
- Published release: [`v0.1.0-preview.105`](https://github.com/TypeThe0ry/ClusterYourCodex/releases/tag/v0.1.0-preview.105),
  non-draft prerelease, published at `2026-10-02T17:26:17Z`.

## Asset and integrity evidence

The release contains Windows Setup, Windows x64 portable and self-contained
archives, Linux x64, macOS x64/arm64 previews, managed Worker Kits, a
CycloneDX 1.6 SBOM, `release-index.json`, provenance, and `SHA256SUMS`.

The following assets were downloaded to
`D:\ClusterYourCodex-validation\preview-105` and matched their sidecars:

| Asset | SHA-256 verification |
| --- | --- |
| `ClusterYourCodex-Setup.exe` | PASS |
| `ClusterYourCodex-v0.1.0-preview.105-windows-x64-self-contained-preview.zip` | PASS |
| `release-index.json` | PASS |

The release index binds `sourceTag=v0.1.0-preview.105` to
`sourceCommit=c152f701432ce07a91f292e2ac325236883b60c5`, marks the release as
`developer-preview`, includes GitHub artifact provenance, and keeps macOS kits
`runtimeGated=true`, `containmentReady=false`, and `liveReady=false`.

## Issue boundaries

Issue [#2](https://github.com/TypeThe0ry/ClusterYourCodex/issues/2) remains
open. Hosted CI and the optional clean Windows 11 ARM64 x64-emulation job are
useful evidence, but they do not replace a current-source clean VM matrix of
Install → Repair → N-1→N Upgrade → interrupted Rollback → Uninstall plus an
independent guest-worker job. The D-drive VMware verification is still a
full-clone/headless diagnostic boundary, not blank-guest GA proof.

Issue [#3](https://github.com/TypeThe0ry/ClusterYourCodex/issues/3) remains
open and intentionally deferred per the current scope: native macOS
LaunchAgent activation, managed controller/worker round-trip, detached
descendant cleanup, and process-identity/PID-reuse evidence are not claimed by
the hosted package checks.

The stable [`v0.0.1`](https://github.com/TypeThe0ry/ClusterYourCodex/releases/tag/v0.0.1)
tag remains immutable at
`e4fbaef04b764268fa038311d85573b18b549f9`. No stable tag or stable asset was
modified while publishing preview.105.
