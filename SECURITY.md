# Security policy

ClusterYourCodex executes user-approved commands on user-owned computers. This
makes credential isolation, source provenance, and cleanup ownership core
security properties rather than optional hardening.

## Reporting

Report vulnerabilities through GitHub private vulnerability reporting for this
repository. Private reporting is enabled on the public repository. Do not open
a public issue containing credentials, private topology, or an unpatched
exploit.

## Supported versions

Only the newest published prerelease receives security fixes while the product
is pre-GA. Stable support windows will be published before the first stable
release. A prerelease is not promoted to stable while a known, applicable
critical or high-severity advisory remains unresolved.

## Required invariants

- Codex and MCP payloads never contain raw worker credentials.
- Host or worker identity changes fail closed until the user confirms them.
- Every remote operation runs in a job-owned workspace.
- Logs and diagnostic bundles are redacted before export.
- Source snapshots exclude common secret and environment files by default.
- Retries are limited to classified transient failures.
- GitHub Actions are pinned to immutable commit SHAs and dependency advisories
  are checked for both Rust lockfiles and the pnpm workspace.

## Target-scoped advisory dispositions

`GHSA-wrw7-89jp-8q8g` applies to `glib` versions below 0.20. The Tauri 2.11
Linux GTK backend currently resolves `glib 0.18.5`, but that backend is not in
the declared or published product scope: the desktop host is Windows x64 only,
and the Windows and macOS target graphs contain no `glib` package. The alert is
therefore dismissed as `not_used` for the current prerelease scope rather than
misrepresented as an upgraded dependency. It must be re-opened and resolved
before a Linux desktop-host artifact is declared or published; target-scope
proof is retained in the exact-SHA release evidence.
