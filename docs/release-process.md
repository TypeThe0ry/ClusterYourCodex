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
./scripts/Set-ProductVersion.ps1 -Version 0.1.0-preview.13
./scripts/Test-VersionConsistency.ps1 -ExpectedTag v0.1.0-preview.13
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
8. Let the tag workflow build a draft/prerelease; never upload hand-repacked
   binaries.
9. Download published artifacts into a clean directory, verify sidecars/index,
   run fresh deployment and supported upgrade acceptance, and retain logs.
10. Approve the final `production` draft-creation deployment only after all
    producer and acceptance jobs have passed.
11. Publish/retain as prerelease only after artifact acceptance.
12. Update issues with the exact tag, commit, workflow run, exit codes, elapsed
   time, artifact hashes, cleanup state, and any unverified gate.

## GA transition

GA is not a rename of an RC asset. It is built from the approved exact source
through the protected stable workflow with production signing and independent
post-download verification. Missing signing credentials, clean Windows 11
capacity, live worker capacity, or a required governance control blocks GA;
it does not convert a partial result into success.
