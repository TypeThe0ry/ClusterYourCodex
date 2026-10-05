# Current audit — 2026-10-05

This audit records the current repository, release, and local runtime state.
It is an evidence ledger, not a claim that every optional GA gate has been
completed.

## Source and release identity

- Latest public developer build: [`v0.1.0-preview.113`](https://github.com/TypeThe0ry/ClusterYourCodex/releases/tag/v0.1.0-preview.113), a non-draft prerelease built from the final candidate source.
- Preview.113 assets include Windows Setup plus SHA-256 sidecars, Windows and Linux packages, and macOS packages whose managed runtime remains fail-closed.
- Stable tag: `v0.0.1` → `e4fbaef04b764268fa038311d85573b18b549f9` locally and remotely. The tag and its assets are immutable.
- The final candidate includes the merged dependency/test-fixture queue and PR #220's Windows stale-receipt and macOS identity fixes. No new issue was created by this cleanup.

Preview.113 contains the native integration diagnostics, shortcut refresh,
stale-`AGENTS.md` receipt reconciliation, and macOS identity tracking. The
follow-up Windows transport hardening is included in the final candidate
source. Historical preview.111/112 records retain their original build labels
and are not relabeled as preview.113.

## Browser renderer boundary

PR #206 makes the browser preview explicit. Vite can proxy read-only health and
fleet requests, but only the Tauri host exposes the native integration bridge.
When that bridge is absent, the renderer shows **Browser preview** and disables
Codex plugin install/repair, SSH credential storage, provisioning, plugin
checks, and the full proof run. This prevents a browser click from producing a
misleading generic “integration operation failed” message. Native desktop
operation is unchanged.

## Local Windows and Linux evidence

The public preview.113 Setup is the final candidate for the current runnable
scope. The local Windows controller health endpoint reported `status=ok`,
`apiVersion=cyc.dev/v1`, and `database=ok`. The retained native plugin contract,
integrity, and MCP probes passed at the builds identified by their records.
The committed public Setup install is
recorded in [`local-install-preview113-20261005.md`](local-install-preview113-20261005.md).

The retained same-host Windows controller/worker run reached
`queued → running → succeeded`; all 14 checks passed, including artifact
verification, process cleanup, and secret scanning at source `60bb863` after
the preview.111 install. It is not relabeled as preview.113 evidence. The record is
[`local-windows-roundtrip-20261005.md`](local-windows-roundtrip-20261005.md).

The retained NUC Linux proof job completed with exit code 0 and a verified
artifact under the earlier preview.111 installation record. That record is
linked for reproducibility; it is not relabeled as preview.113 evidence. The
current candidate controller install and native plugin probes passed locally.
The record is [`local-install-preview111-20261005.md`](local-install-preview111-20261005.md).

At the latest observation the NUC was online. Helio remained network-reachable
but its worker heartbeat was stale and ports 47831/47832 were not accepting
connections; no new Helio runtime success is claimed from that observation.
The safe recovery path is native desktop re-enrollment, not plaintext secrets
in a shell command or repository artifact.

## Scope and remaining release gates

Issues #2 and #3 were closed on 2026-10-05 for the explicitly declared
Windows/Linux runnable scope. The installer, controller, Codex bridge, repair,
uninstall, LAN discovery, and Windows/Linux round-trip path are runnable and
covered by the published preview and retained evidence.

Certified GA remains a separate, stricter release channel. It still requires a
clean current-source Windows 11 version-changing matrix, production
Authenticode/tray acceptance, and a real macOS LaunchAgent/managed-runtime
run. The macOS worker therefore remains deliberately fail-closed; its
descendant identity and PID-reuse protections are unit-tested, but are not
presented as native macOS acceptance. Until those optional production gates
have direct evidence, `v0.1.0-preview.113` is the final runnable public build
and `v0.0.1` remains untouched.
