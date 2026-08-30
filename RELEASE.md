# Release checklist

This file is the operator checklist. `docs/release-process.md` explains the
policy and evidence model.

## Every prerelease

- [ ] `VERSION` is a prerelease SemVer and all product version fields match.
- [ ] Tag is exactly `v$(Get-Content VERSION)`.
- [ ] Stable tags are rejected by the prerelease workflow.
- [ ] Worker Kit signing uses only the protected `production-signing`
      environment secret; required review, disabled administrator bypass,
      wait timer, and `v*` tag-only deployment policy are verified.
- [ ] Working tree is clean and the tag names an immutable reviewed commit.
- [ ] Rust fmt, clippy, workspace tests, Tauri tests, frontend lint/test/build,
      Windows packaging tests, and Worker Kit tests pass.
- [ ] Windows Setup/fresh deployment validates Install, Repair, Uninstall,
      task/firewall restoration, controller/worker/CLI, and Codex integration.
- [ ] Windows and Linux live acceptance evidence is attached or the missing
      hardware gate is listed as a known prerelease limitation.
- [ ] Every primary producer artifact and the release-asset SBOM has an adjacent
      SHA-256 sidecar and is represented in `release-index.json`; checksum and
      index metadata files are not recursively self-indexed.
- [ ] `productVersion`, `releaseChannel`, source tag, and source SHA match every
      manifest and runtime `--version` result.
- [ ] Release is marked `prerelease: true`.
- [ ] Changelog and open-issue status are updated with exact evidence.

## Stable/GA additional gates

- [ ] Production Authenticode publisher and timestamp validate on every owned
      Windows executable/script that crosses a trust boundary.
- [ ] macOS assets, if supported, have Developer ID signing and notarization.
- [ ] SPDX/CycloneDX SBOM and third-party notices cover all package payloads.
- [ ] Artifact attestation/provenance verifies independently after download.
- [ ] Protected branch/tag rules and an approved production release environment
      are active.
- [ ] Clean Windows 11 standard/admin/non-ASCII profile matrix passes.
- [ ] Signed `N-1 -> N` upgrade, interrupted upgrade rollback, downgrade policy,
      Repair, and Uninstall pass.
- [ ] Real Windows-controller to Windows-worker and Linux-worker GUI/MCP source,
      build, logs, cancellation, cleanup, and artifact round trips pass.
- [ ] No open unwaived P0/P1 blocker applies to the declared stable scope.
- [ ] Stable tag was built through the gated stable path and the GitHub release
      is `prerelease: false`.

The protected GA publisher enforces these checks mechanically: the stable
`release-index.json` must be signed, carry a hashed attestation bundle whose
subjects match every indexed payload, include a complete CycloneDX 1.6 SBOM and
non-empty third-party notices artifact, and have an exact top-level file and
`SHA256SUMS` set. The publisher cross-binds the external evidence manifest's
`artifactVerification.indexSha256` to the downloaded index, verifies each
payload with `gh attestation verify` against the exact stable tag/commit, and
uploads only the validator's allow-listed release files.
