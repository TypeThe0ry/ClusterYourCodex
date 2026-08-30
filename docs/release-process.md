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
10. Let the final `preview-publication` job run only after all producer and
    acceptance jobs have passed. It is deliberately separate from the
    protected stable `production` environment and can publish only a
    `prerelease: true` release.
11. Publish/retain as prerelease only after artifact acceptance; the stable
    `production` environment is reserved for the independent GA workflow.
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

Issue closure is only a live repository-state gate; it is not evidence that an
acceptance item ran. The manifest must also contain top-level `issue2`,
`issue3`, and `issue5` objects. Each issue object is accepted only when all of
these fields
are present and valid:

- `status` is exactly `passed`;
- `sourceCommit` is the exact reviewed 40-character source SHA;
- `provider` and `hostType` are non-empty external identifiers and do not name
  GitHub Actions, a hosted runner, or an equivalent hosted execution surface;
- `evidenceId` is a bounded portable filename identifier (letters, digits,
  `.`, `_`, and `-` only; no path separators); and
- `rawLog.url` is an absolute HTTPS URL and `rawLog.sha256` is its 64-character
  SHA-256 digest.

The retained `rawLog` descriptor must also record the exact command and
external node, ISO-8601 `startedAt`/`endedAt` instants, integer `exitCode=0`,
non-negative `tests.passed`/`tests.failed`/`tests.ignored` counts with
`tests.failed=0`, and `cleanup=true`. The readiness workflow runs
`scripts/Test-GARawLogs.ps1`, downloads every HTTPS log without following
redirects, enforces the size limit, recomputes SHA-256 over the downloaded
bytes, and retains a per-log verification record. A URL plus a syntactically
valid digest is therefore insufficient without the matching downloaded bytes.

The `gates` object is fail-closed: every required gate is a JSON boolean with
value `true`; a missing, non-boolean, or false gate fails the manifest. Issue
#2 requires `tauriDesktopHostTray`, `rendererNativeControllerProxy`,
`perUserScheduledTasks`, `sidScopedDataDirAcl`,
`bundledMcpInstallerMarketplace`, `installRepairUpgradeRollbackUninstall`,
`cleanWindows11Vm`, `liveWindowsControllerWorkerRoundTrip`, and
`productionAuthenticodeSetupHelper`, `signedNMinus1ToNUpgrade`,
`interruptedUpgradeRollback`, `downgradePolicy`, and
`noOpenUnwaivedP0P1Blocker`. Issue #3 requires
`linuxSystemdUserServicePackage`, `macosLaunchAgentPackage`,
`linuxX64ReleaseArtifact`, `macosX64ReleaseArtifact`,
`macosArm64ReleaseArtifact`, `platformNativeShells`,
`platformNativeProcessGroups`, `crossPlatformPathAclTests`, and `liveMacosRun`.
It also requires `liveLinuxControllerWorkerRoundTrip` and
`macosDeveloperIdSigningNotarization`.
Issue #5 requires `linuxDedicatedExecutionIdentity`,
`linuxCgroupV2Reconciliation`, `windowsIsolatedExecutionIdentity`,
`windowsJobObject`, `windowsProtectedExternalGuard`,
`macosExternalReconciliation`, `jobsCannotAlterGuardState`,
`jobsCannotReadWorkerCredentials`, and
`restartResidualProcessReconciliation`. The readiness script and the stable
publisher's cross-bind step validate the same fields independently, so a
closed Issue #2, #3, or #5 with absent or unverifiable evidence cannot pass.

Each other host record must identify a non-GitHub-hosted provider and an
`evidenceId`.
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
check. It requires a detached RSA-PKCS1-SHA256 signature envelope at
`release-index.json.sig`; the signature is verified against the pinned public
key in `scripts/stable-index-public-key.xml`, so `unsigned=false` is only an
assertion after cryptographic verification. The bundle also needs an HTTPS
provenance receipt with a locally hashed attestation bundle, an exact top-level
file set (payloads, their sidecars, index metadata, signature, checksum file,
and the receipt), and an exact `SHA256SUMS` set that covers every payload,
`release-index.json`, and the detached signature. The index's provenance
subjects must cover exactly the indexed payload digests and strictly typed byte
counts. A CycloneDX 1.6 SBOM must be schema-shaped with metadata/tool and
dependency-graph entries, parse successfully, and contain one SHA-256 component
for every non-SBOM payload. A UTF-8 `THIRD-PARTY-NOTICES.txt` with an explicit
license/copyright declaration is required. The publisher re-downloads the GA
evidence manifest and compares its `artifactVerification.indexSha256` with the
downloaded stable index before it invokes `gh attestation verify` for every
payload using the exact source tag, commit, and pinned signer identity. Only
the validated payloads, sidecars, signature, and required release metadata are
uploaded; the attestation receipt remains verification input rather than an
unindexed extra release asset. The stable payload ZIP and its Sigstore
attestation must come from a reviewed stable builder. The manual GA dispatch
therefore requires `attestation_signer_repo`, `attestation_signer_workflow`,
and `attestation_cert_identity` inputs. The protected `production` environment
must also set `CYC_GA_TRUSTED_BUILDER_REPO` and
`CYC_GA_TRUSTED_BUILDER_WORKFLOW`, and `CYC_GA_TRUSTED_BUILDER_DIGEST`.
Dispatch values are rejected unless they match those protected policy values
exactly; the digest must be a full workflow commit SHA, the repository must be
external, and the certificate identity must bind to the exact source tag. The
prerelease `release.yml` workflow is explicitly rejected. This keeps the
producer explicit instead of treating the
prerelease publisher as a stable attestation authority.
