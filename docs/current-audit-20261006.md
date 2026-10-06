# Release promotion audit — 2026-10-06

This record documents the explicitly requested promotion of the already-built
`v0.1.0-preview.113` payload to the latest public GitHub Release without
claiming cryptographic stable-GA signing.

## Public release

- Release: [ClusterYourCodex v0.1.0 (unsigned public release)](https://github.com/TypeThe0ry/ClusterYourCodex/releases/tag/v0.1.0-preview.113)
- Immutable payload tag: `v0.1.0-preview.113`
- GitHub `prerelease`: `false`
- GitHub `draft`: `false`
- Asset count: 23
- Release published: `2026-10-05T14:07:33Z`
- Source commit: `d8b24773521ed237f792890f8691e1fbfb36cecf`

The payload tag is intentionally unchanged. Its manifests and executable
version strings continue to identify `0.1.0-preview.113`; only the GitHub
Release channel was promoted so the existing usable build is the latest public
download. No asset was renamed, rebuilt, or re-hashed during promotion.

## What the release claims

The release is usable for the supported Windows Controller/Desktop, Windows
Worker, Linux x64 Worker, Windows → Linux and Linux → Linux execution paths,
Codex MCP integration, LAN discovery, worker pairing, scheduling, logs,
cleanup, and artifact hashes. The existing CI, installation, controller/worker,
and plugin evidence remains bound to the exact payload tag above.

The Setup is unsigned. Users must verify `ClusterYourCodex-Setup.exe.sha256`
before launch and may see an unknown-publisher warning. This promotion does
not claim Authenticode, Developer ID, notarization, or signed stable-GA
provenance.

## Repository state

- Open pull requests: 0
- Open issues: 0
- Immutable historical stable tag `v0.0.1`: unchanged
- No new Issue was created by this release promotion
