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
   workspaces. The repository CI and tagged Unix artifact jobs also run
   `scripts/Test-WorkerKitsNative.sh` on Linux, macOS Intel, and macOS arm64
   to verify each signed Worker Kit's canonical five-file, manifest, checksum,
   publisher-key, and Ed25519 contract without mutating a service manager.
   The tagged Linux arm64 cross-compile job runs the explicit structural
   verifier mode after a `readelf` AArch64 check; this is not counted as native
   arm64 execution evidence.
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
The manifest and stable-bundle endpoints are additionally checked by
`scripts/Test-ExternalHttpsUrl.py`: they must resolve to globally routable
addresses, contain no embedded credentials or fragments, and return directly
over HTTPS (`curl --max-redirs 0`). Raw-log materialization refuses existing
targets, reparse points, and directories, writes to a fresh same-directory
temporary file, and atomically publishes the result without overwriting an
existing evidence file.

Issue #5 has an additional, fail-closed evidence contract because its nine
gates are a cross-platform hostile-workload matrix. Its `rawLog` descriptor
must contain `platforms: ["linux", "windows", "macos"]` and a non-empty
`markers` array. The issue's `gates` map is structured evidence: each
platform-specific gate records `status: true`, its exact `platform`, exact
`testSelector`, exact locked `command`, and `rawLogMarkers`; each matrix gate
records `status: true`, all three `platforms`, one nested `runs` object per
platform, and the marker set for those runs. Every gate/run evidence object
also carries source-bound provenance: a bounded `runId` and `node`, external
`provider` and `hostType`, `status: "passed"`, integer `exitCode: 0`, positive
`tests.passed`, zero `tests.failed`, non-negative `tests.ignored`, and explicit
ISO-8601 `startedAt`/`endedAt` instants in chronological order. The downloader
cross-binds these fields instead of accepting a marker-only or relabelled run.
The legacy `selector` and `markers` aliases may be supplied for compatibility,
but if they appear alongside canonical `testSelector` or `rawLogMarkers` they
must be the same values byte-for-byte; conflicting spellings fail closed.
Every nested run carries its exact selector, command, and raw-log markers. The required selectors are the Linux ignored native probe
`isolation::tests::linux_live_dedicated_identity_credential_and_residual_reconciliation`,
the positive Windows native containment probe
`isolation::tests::windows_native_containment_job_object_and_guard`,
and the positive macOS live reconciliation probe
`isolation::tests::macos_live_external_reconciliation`. The existing
`windows_external_json_contract_is_fail_closed_at_every_runtime_gate` and
`macos_external_reconciliation_is_fail_closed_at_every_runtime_gate` tests are
unavailability regressions, not native containment acceptance, and the GA
validators reject them as completion evidence.
Commands must select `cyc-worker`'s library target with `--locked` and
`--exact --nocapture`; the Linux row additionally requires `--ignored` and
all rows must end in their exact selector. A workspace-wide
`cargo test --workspace --locked` command is not evidence for any Issue #5
row. Linux, Windows, and macOS each have to carry their platform-specific
gates plus the guard-state, worker-credential, and restart residual-process
gates.

For `restartResidualProcessReconciliation`, every platform row must carry a
native residual marker in addition to its source-bound marker. Linux accepts
`residual_empty`, `residualCgroupVerified=1`, or
`residualIdentityProcessesVerified=1`; Windows accepts
`residualJobObjectVerified=1` or `residualProcessGroupVerified=1`; macOS
accepts `residualProcessGroupVerified=1` or
`residualExternalReconciliationVerified=1`. A generic Linux-style
`residual_empty` marker cannot be relabelled as Windows or macOS proof.

Within each three-platform matrix, `runId` values are unique. Across gates a
run may be reused only for the same platform; a single execution identifier
cannot be relabelled from Linux to Windows or macOS. Provenance identifiers
are required to remain JSON strings (numeric, boolean, and null values are
rejected before normalization), and aggregate or retained marker arrays must
contain unique, non-empty strings.

Every run/gate pair has a marker in the corresponding `rawLogMarkers` array
and in the raw-log descriptor's `markers` array, of the form
`CYC-GA-ISSUE5|platform=<platform>|selector=<selector>|commandSha256=<digest>|gate=<gate>|status=passed`.
The marker digest is over the normalized exact command. `Test-GARawLogs.ps1`
requires every source-bound marker in the manifest, searches for every marker
in the downloaded bytes, and emits `markersVerified: true` plus the verified
`gateEvidence` records. `Test-GAReadiness.ps1` cross-binds those records back
to the manifest, so setting all nine gates to `true`, relabelling a single
Linux log, or omitting a semantic native marker cannot satisfy the Windows,
macOS, or restart gates.

The Issue #2 and Issue #3 `gates` objects remain fail-closed legacy maps: every
required gate is a JSON boolean with value `true`; a missing, unknown,
non-boolean, or false gate fails the manifest. The gate objects are closed sets
and are rechecked by both the PowerShell readiness verifier and the stable
publisher's JQ contract. Issue #5 uses the structured gate matrix above.
Issue #2 requires `tauriDesktopHostTray`, `rendererNativeControllerProxy`,
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
`macosDeveloperIdSigningNotarization`. Issue #5 requires structured entries
for `linuxDedicatedExecutionIdentity`,
`linuxCgroupV2Reconciliation`, `windowsIsolatedExecutionIdentity`,
`windowsJobObject`, `windowsProtectedExternalGuard`,
`macosExternalReconciliation`, `jobsCannotAlterGuardState`,
`jobsCannotReadWorkerCredentials`, and
`restartResidualProcessReconciliation`. The readiness script and the stable
publisher's cross-bind step validate the same fields independently, so a
closed Issue #2, #3, or #5 with absent or unverifiable evidence cannot pass.

Each other top-level host record must identify a non-GitHub-hosted provider,
`hostType`, source commit, and an `evidenceId`; unknown scalar metadata is
rejected so a new record cannot silently bypass the same identity checks. The
workflow contract is checked structurally (trigger, inputs, job dependencies,
environments, permissions, and publisher placement), and both the readiness
script and its version helper must exit with code zero before their JSON is
accepted. Stable bundle ZIP validation rejects empty or `.` path components,
namespace/device paths, and case-folded duplicate names before extraction.
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
