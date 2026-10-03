# Current GitHub and preview release audit — 2026-10-03

This is the current release record for `TypeThe0ry/ClusterYourCodex`. The live
GitHub repository, CI runs, and command-line VMware evidence are authoritative;
older audit files are historical context only.

## Current candidate and exact-commit evidence

- PR #190 (`1db7b619bcf4f12bb9b40d0a334ba9edada759a3`) merged the bounded
  Windows Task Scheduler lifecycle fix.
- PR #191 (`29bbe9b301b1a85e30b3e7d79d9b843627466dbe`) merged the
  `0.1.0-preview.107` release preparation. The exact-SHA `main` CI run
  `37113630162` succeeded on attempt 2.
- The attempted preview.107 tag workflow
  `37117855967` was rejected because the release metadata lacked the required
  compare links; no preview.107 Release was published. The preview.107 tag,
  where present, is treated as immutable source metadata only and not as a
  published public asset in this audit.
- PR #192 (`478005eb074ad30bcf221e45b0ca1bf1a6bfd060`) merged the
  `0.1.0-preview.108` release preparation. Its exact-SHA `main` CI run
  `37120683845` completed successfully, including Windows desktop/bridge,
  bounded Windows Rust, Worker Kits, cross-platform Rust, security checks, and
  the Windows controller/worker live round-trip. Preview.108 is still not
  tagged or published at this audit point.
- The latest published public build remains
  [`v0.1.0-preview.106`](https://github.com/TypeThe0ry/ClusterYourCodex/releases/tag/v0.1.0-preview.106).

The command-line VMware candidate evidence for preview.107 is recorded in
[the preview.107 candidate record](vmware-preview107-candidate-20261003.md).
It is deliberately kept separate from the published preview.106 evidence and
must not be presented as a tagged preview.107 asset.

- PR #183 (`ec4ec8f49af4d31ad79d5a02c7c143c846918956`) fixed the Windows
  profile-matrix scheduler deadlock. Disposable Task Scheduler probes now stay
  in the elevated parent helper, shutdown remains bounded and exact-process
  scoped, and same-name foreign tasks are rejected before `-Force` replacement.
  Candidate run [37057151914](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/37057151914)
  passed the Windows desktop/bridge, Setup, bounded Rust, cross-platform Rust,
  Worker Kit, security, and live Windows controller/worker checks.
- PR #184 (`dcf4a6dbf7c3f1287e86da80397ac4d75f766f5c`) synchronized every
  product surface to `0.1.0-preview.106`. Its candidate checks
  [37062423830](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/37062423830)
  and packaged Setup checks
  [37062423747](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/37062423747)
  passed.
- PR #185 (`3402b5ba24229300ed51464638be0793b50225c0`) recorded the final
  preview.106 audit baseline and the VMware evidence on `origin/main`.
- The first attempt of tagged workflow
  [37067050549](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/37067050549)
  stopped at the exact-commit identity gate because the matching `main` push CI
  had not completed. After that push run succeeded, the full tagged workflow
  was rerun. Its Windows x64 self-contained job passed Setup, fresh deployment,
  silent Setup lifecycle, and asset staging; the release-index/provenance job
  and the publish job also passed.
- GitHub publishes
  [`v0.1.0-preview.106`](https://github.com/TypeThe0ry/ClusterYourCodex/releases/tag/v0.1.0-preview.106)
  as a non-draft prerelease at `2026-10-03T00:06:21Z`. The Release contains 23
  assets. All 11 downloaded per-asset SHA-256 sidecars matched their payloads
  in `D:\ClusterYourCodex-validation\preview106`, including Setup.exe,
  `release-index.json`, portable/self-contained archives, Worker Kits, and the
  SBOM metadata. The tag dereferences to
  `dcf4a6dbf7c3f1287e86da80397ac4d75f766f5c`.
- The optional clean Windows 11 ARM64 x64-emulation job
  `111079962921` completed with `failure` after the fresh-deployment Repair
  child hit its 900-second bound (`bootstrap repair timed out after 900
  seconds`). The job is `continue-on-error`, so this did not turn the release
  run or published assets into a false failure; it also does not count as ARM64
  acceptance. Its diagnostic artifact is `11259418732`.

## Command-line VMware and cross-platform evidence

The D-drive Windows 11 VMware guest (build 26200, launched and exercised with
`vmrun`/VIX only) started with preview.105 installed. The published preview.106
Setup then exited zero, the install manifest changed to preview.106, and the
controller health endpoint returned HTTP 200 with `database: ok`. The upgraded
controller/worker harness passed all 14 checks across the complete queued →
running → succeeded round trip, artifact/log verification, cleanup, process
cleanup, and secret scan. A post-upgrade credential-free discovery probe
returned version preview.106 with explicit pairing required. The full
record is in [the VMware preview.106 upgrade record](vmware-preview106-upgrade-20261003.md);
sanitized JSON remains outside Git under
`D:\ClusterYourCodex-validation\guest-exchange`.

After that upgrade run, the same guest was uninstalled, verified with no
install root or product tasks, and then installed again from the published
preview.106 Setup. A deterministic `cyc.exe` byte mutation was repaired by a
second Setup `/S` run: the Repair exit code was `0`, the exact original hash
was restored, and controller health remained good. The installed controller
and worker then passed the same 14-check live round trip, credential-free
discovery passed, and quiet uninstall exited zero with the install root and
product tasks absent afterward. See the [fresh VMware lifecycle record](vmware-preview106-fresh-lifecycle-20261003.md)
for timestamps, hashes, and sanitized evidence paths.

The later preview.107 candidate run also completed install, deterministic
Repair, same-host round trip, credential-free discovery, and quiet uninstall;
its exact hashes and acceptance boundary are recorded in
[the candidate record](vmware-preview107-candidate-20261003.md). Because that
run used the PR #191 candidate Setup and a full clone/reset image rather than a
blank Windows installation, it is not a GA lifecycle claim.

Independent evidence also covers Windows controller ↔ Linux worker and Linux
controller ↔ Linux worker. macOS managed-runtime validation is intentionally
deferred. These results prove usable preview paths, not every GA lifecycle gate.

## Remaining issue boundaries

Issue [#2](https://github.com/TypeThe0ry/ClusterYourCodex/issues/2) remains open:
hosted CI and the VMware run do not replace a genuinely blank current-source
VM matrix of Install → Repair → N-1→N Upgrade → interrupted Rollback →
Uninstall, a separate guest-worker acceptance, and remaining signing/tray GA
requirements.

Issue [#3](https://github.com/TypeThe0ry/ClusterYourCodex/issues/3) remains open:
native macOS LaunchAgent activation, managed controller/worker round-trip,
detached descendant cleanup, and PID-reuse process-identity evidence are not
claimed by package-only checks.

The stable [`v0.0.1`](https://github.com/TypeThe0ry/ClusterYourCodex/releases/tag/v0.0.1)
tag remains immutable at
`e4fbaef04b764268fa038311d85573b18b549f9f`. No stable tag or stable asset is
modified by preview work.
