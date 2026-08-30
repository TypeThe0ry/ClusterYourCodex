# Release process

## Rule: prerelease until GA evidence is complete

All intermediate public versions use:

```text
vX.Y.Z-preview.N
vX.Y.Z-alpha.N
vX.Y.Z-beta.N
vX.Y.Z-rc.N
```

and must be published with `prerelease: true`. The prerelease workflow rejects
stable `vX.Y.Z` tags. A stable tag is enabled only through a separate protected
GA gate after every applicable item in `RELEASE.md` passes.

## Version identity

`VERSION` is the source value. Ecosystem manifests need their own copied
version fields, so `scripts/Set-ProductVersion.ps1` updates them and
`scripts/Test-VersionConsistency.ps1` verifies they are identical. Product
SemVer changes do not alter protocol schema identifiers.

Before a tag:

```powershell
./scripts/Set-ProductVersion.ps1 -Version 0.1.0-preview.14
./scripts/Test-VersionConsistency.ps1 -ExpectedTag v0.1.0-preview.14
```

The tag, binaries' `--version`, Tauri/package/plugin/MCP versions, installer
DisplayVersion, Worker Kit default, release manifests, and release index must
agree exactly.

## Evidence order

1. Review a clean exact source SHA.
2. Run deterministic local checks.
3. Run native Windows and Linux worker checks on independent exact-SHA
   workspaces.
4. Run CI on the exact SHA.
5. Confirm the Worker Kit publisher key exists only in the protected
   `production-signing` environment, repository-level signing secrets are
   absent, administrator bypass is disabled, and the required-reviewer plus
   `v*` tag policy is active.
6. Create the annotated prerelease tag.
7. Approve the exact-tag `production-signing` deployment only after matching
   its SHA to the reviewed commit.
8. Let the tag workflow build a public prerelease; never upload hand-repacked
   binaries.
9. Download published artifacts into a clean directory, verify sidecars/index,
   run fresh deployment and supported upgrade acceptance, and retain logs.
10. Approve the final `production` prerelease-publication deployment only
    after all producer and acceptance jobs have passed.
11. Publish/retain as prerelease only after artifact acceptance.
12. Update issues with the exact tag, commit, workflow run, exit codes, elapsed
   time, artifact hashes, cleanup state, and any unverified gate.

## GA transition

GA is not a rename of an RC asset. It is built from the approved exact source
through the protected stable workflow with production signing and independent
post-download verification. Missing signing credentials, clean Windows 11
capacity, live worker capacity, or a required governance control blocks GA;
it does not convert a partial result into success.

## Protected stable GA readiness gate

`.github/workflows/ga.yml` is the executable stable gate. It is deliberately
`workflow_dispatch`-only: a tag push never creates a stable release by itself.
The operator must dispatch it against an exact stable `vX.Y.Z` tag and provide
an HTTPS URL plus SHA-256 digest for an externally captured
`cyc.dev/ga-evidence/v1` manifest. The gate checks the tag and every product
version surface, then reads the live state of Issues #2, #3, and #5 and the
repository governance APIs. All three issues must be closed, the default branch
must be protected, and the `production` environment must require review, a wait
timer, administrator-bypass prevention, and its `v*` tag policy.

The evidence manifest must bind to the exact stable tag and 40-character source
SHA and contain passed, retained evidence for:

- a clean Windows VM profile/lifecycle matrix;
- a real macOS host running the LaunchAgent lifecycle and controller round trip;
- valid, timestamped Authenticode signatures for Setup and the narrow elevated
  helper; and
- independent post-download checksum, release-index, and provenance verification.

Each host record must identify a non-GitHub-hosted provider and an `evidenceId`.
The macOS portable smoke in `release.yml`, the Windows ARM64 compatibility job,
and the repository Authenticode contract test remain useful prerelease checks,
but none can satisfy those external GA evidence fields. The protected GA workflow
also requires an HTTPS URL and SHA-256 for an externally built stable asset bundle.
After the readiness job passes, a second `production`-protected job validates that
bundle's stable `release-index.json`, sidecars, and attested provenance, then calls
`gh release create --verify-tag` without `--prerelease` and verifies
`isPrerelease=false` and `isDraft=false`. No stable publisher can run when any
evidence, issue, or governance gate fails.

The stable bundle validator is intentionally stricter than the preview index
check. It requires a signed (`unsigned=false`) stable index, an HTTPS provenance
receipt with a locally hashed attestation bundle, an exact top-level file set
(payloads, their sidecars, index metadata, checksum file, and the receipt), and
an exact `SHA256SUMS` set. The index's provenance subjects must cover exactly the
indexed payload digests and byte counts. A CycloneDX 1.6 SBOM must be indexed,
parse successfully, and contain one SHA-256 component for every non-SBOM
payload. A non-empty third-party notices artifact is also required. The
publisher re-downloads the GA evidence manifest and compares its
`artifactVerification.indexSha256` with the downloaded stable index before it
invokes `gh attestation verify` for every payload using the exact source tag and
commit. Only the validated payloads, sidecars, and required release metadata are
uploaded; the attestation receipt remains verification input rather than an
unindexed extra release asset.
