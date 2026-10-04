# Current audit — 2026-10-05

This audit records the repository and local runtime state after PR #206. It is
an evidence ledger, not a release declaration.

## Source and release identity

- `origin/main`: `a5f38d9f51107ea3e31d910ec3c32238053f7e14`
- Latest public developer build: [`v0.1.0-preview.111`](https://github.com/TypeThe0ry/ClusterYourCodex/releases/tag/v0.1.0-preview.111), non-draft prerelease
- Stable tag: `v0.0.1` → `e4fbaef04b764268fa038311d85573b18b549f9`
- Open pull requests: none
- Open issues: [#2](https://github.com/TypeThe0ry/ClusterYourCodex/issues/2) and [#3](https://github.com/TypeThe0ry/ClusterYourCodex/issues/3)

The stable tag was compared locally and against the remote ref during this
audit. It remains immutable.

## Browser renderer boundary

PR #206 makes the browser preview explicit. Vite can proxy read-only health and
fleet requests, but only the Tauri host exposes the native integration bridge.
When that bridge is absent, the renderer shows **Browser preview** and disables
Codex plugin install/repair, SSH credential storage, provisioning, plugin
checks, and the full proof run. This prevents a browser click from producing a
misleading generic “integration operation failed” message. Native desktop
operation is unchanged.

## Local Windows and Linux evidence

The public preview.111 Setup was installed on the current Windows controller.
The controller health endpoint reported `status=ok`, `apiVersion=cyc.dev/v1`,
and `database=ok`. The native plugin contract, integrity, and MCP probes passed.

The fresh same-host Windows controller/worker run reached
`queued → running → succeeded`; all 14 checks passed, including artifact
verification, process cleanup, and secret scanning. The sanitized record is
[`local-windows-roundtrip-20261005.md`](local-windows-roundtrip-20261005.md).

The NUC Linux worker completed a preview.111 proof job with exit code 0 and a
verified artifact. The local install evidence, including the Windows and NUC
job results, is in
[`local-install-preview111-20261005.md`](local-install-preview111-20261005.md).

At the latest observation the NUC was online. Helio remained network-reachable
but its worker heartbeat was stale and ports 47831/47832 were not accepting
connections; no new Helio runtime success is claimed from that observation.
The safe recovery path is native desktop re-enrollment, not plaintext secrets
in a shell command or repository artifact.

## Remaining release gates

Issue #2 remains open for a clean current-source Windows 11 VM run of
`Install → Repair → Upgrade → Rollback → Uninstall`, plus production
Authenticode signatures for Setup/helper and final packaged/tray acceptance.
Hosted CI, a provisioned guest, and the same-host round trip are supporting
evidence only.

Issue #3 remains open for native macOS LaunchAgent lifecycle, managed
macOS controller/worker execution, detached-descendant and PID-reuse checks,
and any required signing/notarization. macOS runtime support is not claimed.

Until those gates have direct evidence, `v0.1.0-preview.111` must remain a
prerelease and `v0.0.1` must remain untouched.
