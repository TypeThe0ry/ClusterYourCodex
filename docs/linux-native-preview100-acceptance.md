# Linux native preview.100 acceptance — 2026-09-08

## Scope and outcome

Native Linux x86_64 test host, existing password-SSH runner, isolated job-owned directory:
`<job-owned-root>/20260908-preview100-native-acceptance`.
This is a real Linux **unpaired** signed-kit install/repair/uninstall test,
not a fake-systemd fixture and not end-to-end onboarding acceptance.

Public artifact: `ClusterYourCodex-v0.1.0-preview.100-linux-x64-preview.tar.gz`
(16,984,650 bytes), downloaded from GitHub's preview.100 release.
SHA-256 verified against its published sidecar:
`0042c61f61ac2d98b16aee034450262e193a9303ffbd6eedd2a30dc753480a60`.
Only `worker-kit/` was extracted. Its four SHA256SUMS entries passed.
Native `cyc-worker --version` returned `0.1.0-preview.100`.

## Lifecycle evidence

- Install used explicit job-owned install/data/workspace roots, `--scope system`
  and `--pair-only`, without enrollment. Native exit 0; receipt had
  `succeeded=true`, `paired=false`, `serviceEnabled=false`.
- Repair on the same roots succeeded with the same unpaired/service-disabled
  state. The shell continued under `set -e`, establishing native exit 0.
- Uninstall returned `succeeded=true`, `dataPreserved=true`, and exited 0.
  The installed binary was absent afterward; data/workspace remained.
- Independent final checks and version execution exited 0 with
  `CYC_NATIVE_UNPAIRED_LIFECYCLE_VERIFIED`.

The combined repair/uninstall/probe command ended with exit 1 because its last
`systemctl list-unit-files '*clusteryourcodex*'` found zero unit files, after both
lifecycle commands and file assertions had already succeeded. Preserve this
distinction rather than reporting the whole combined command as exit 0.
`install-worker.sh --help` also printed usage but returned 2; no install action
was performed by that command.

## Resources and retained state

The Linux test host had 347,729,920 bytes available before acquisition, and 317,915,136 bytes
after uninstall. No builds, package installations, or unrelated cleanup ran.
The downloaded archive, sidecar, extracted signed kit and test data remain in
the isolated directory. Uninstall removed only its installed executable; it
can be restored from the retained kit. No worker was paired or service enabled.
An additional worker endpoint was unreachable; no action was performed there.

## Still required

GUI Add Computer, product credential storage/reuse, managed enrollment,
systemd enable/restart, fresh controller heartbeat, a dispatched job, logs,
artifact digest and cleanup acknowledgement remain unverified for this host.
This does not validate the current unpublished Windows migration code or
change any macOS/hostile-isolation gate. All new public builds remain prerelease.
