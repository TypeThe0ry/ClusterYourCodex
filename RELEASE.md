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
- [ ] `release-index.json.sig` verifies with the pinned production public key;
      `unsigned=false` is never accepted as a self-declared trust decision.
- [ ] Artifact attestation/provenance verifies independently after download.
- [ ] Each Issue #2/#3/#5 raw log is downloaded from its HTTPS URL, retained,
      re-hashed, and cross-bound to its external command/node, timestamps,
      exit code, test counts, and cleanup result.
- [ ] Protected branch/tag rules and an approved production release environment
      are active.
- [ ] Independent externally retained clean Windows 11
      standard/admin/non-ASCII profile/lifecycle matrix passes and is bound
      into the GA evidence manifest; the preview.58 hosted ARM64
      x64-emulation matrix is prerelease evidence only.
- [ ] Signed `N-1 -> N` upgrade, interrupted upgrade rollback, downgrade policy,
      Repair, and Uninstall pass.
- [ ] Real Windows-controller to Windows-worker and Linux-worker GUI/MCP source,
      build, logs, cancellation, cleanup, and artifact round trips pass.
- [ ] No open unwaived P0/P1 blocker applies to the declared stable scope.
- [ ] Stable tag was built through the gated stable path and the GitHub release
      is `prerelease: false`.
- [ ] The stable payload builder, signer workflow, and Sigstore certificate
      identity are explicit GA inputs bound to the exact stable tag; the
      prerelease `release.yml` publisher is never accepted as the stable signer.
- [ ] Protected `production` environment secrets
      `CYC_GA_TRUSTED_BUILDER_REPO`, `CYC_GA_TRUSTED_BUILDER_WORKFLOW`, and
      `CYC_GA_TRUSTED_BUILDER_DIGEST` are configured; dispatch signer inputs
      match them exactly, the digest is a full workflow commit SHA, and the
      signer identifies an external repository.

The protected GA publisher enforces these checks mechanically: the stable
`release-index.json` must have a detached RSA-PKCS1-SHA256 signature verified by
the pinned `scripts/stable-index-public-key.xml`, carry a hashed attestation
bundle whose subjects match every indexed payload, include a schema-shaped
CycloneDX 1.6 SBOM and UTF-8 `THIRD-PARTY-NOTICES.txt`, and have an exact
top-level file and `SHA256SUMS` set. The publisher cross-binds the external
evidence manifest's `artifactVerification.indexSha256` to the downloaded index,
verifies each payload with `gh attestation verify` against the exact stable
tag/commit and trusted signer identity, and uploads only the validator's
allow-listed release files.
