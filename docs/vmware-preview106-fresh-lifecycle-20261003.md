# VMware preview.106 fresh lifecycle — 2026-10-03

This record adds a second command-line-only VMware run for the published
`v0.1.0-preview.106` Windows Setup. It is deliberately separate from the
preview.105 → preview.106 upgrade record: the guest was first left with no
installed product, then installed, exercised, and uninstalled again. VMware
was controlled with `vmrun` and the in-process VIX helper; Computer Use was
not used. Credentials remain outside Git.

## Fresh install

Before this run, the guest uninstall result recorded:

- install root absent;
- `ClusterYourCodex Controller` task absent;
- product data root retained, as required by the non-purge uninstall path.

The published Setup asset was then copied into the guest and launched with
`/S`. The Setup SHA-256 was
`4c5118341f1d9cd20a33082e9d9ed4df3ce137ea3b0c7596521a84f0c62e2745`.
The installer exited `0` at `2026-10-03T02:58:22Z`; the installed manifest
reported `0.1.0-preview.106`, the install root existed, and the controller
health endpoint returned HTTP 200 with `database: ok`.

The sanitized host-side result is retained outside Git at
`D:\ClusterYourCodex-validation\guest-exchange\preview106-fresh-install-result-20261003.json`.
The helper used for this probe contains a historical field named
`fromVersion`; the precondition and postcondition above are the authoritative
fresh-install evidence for this run.

## Installed live round trip

The installed preview.106 controller and worker completed a real same-host
round trip with exit code `0`. All 14 checks were true:

`privateJobRootAcl`, `controllerHealth`, `tlsIdentity`, `pairingReady`,
`nodeReport`, `jobClaimed`, `heartbeatWindow`, `completion`, `logs`, `artifact`,
`cleanup`, `routeTrace`, `processCleanup`, and `secretScan`.

The observed state sequence was `queued → running → succeeded`; the cleanup
receipt reported `removed` and `jobRootDeleted=true`. The sanitized records
are retained outside Git at:

- `D:\ClusterYourCodex-validation\guest-exchange\preview106-fresh-roundtrip-result-20261003.json`
- `D:\ClusterYourCodex-validation\guest-exchange\preview106-fresh-roundtrip-checks-20261003.json`

The credential-free discovery probe also passed, returning
`cyc.dev/discovery/v1`, controller version `0.1.0-preview.106`,
`credentialsTransmitted=false`, and explicit pairing still required. Its
sanitized result is retained at
`D:\ClusterYourCodex-validation\guest-exchange\preview106-fresh-discovery-result-20261003.json`.

## Uninstall

The installed uninstaller was run with `-Quiet`. It exited `0` at
`2026-10-03T03:07:40Z`. The postcondition showed:

- install root absent;
- Controller and Worker scheduled tasks absent;
- product data root retained (non-purge uninstall semantics).

The sanitized result is retained outside Git at
`D:\ClusterYourCodex-validation\guest-exchange\preview106-fresh-uninstall-result-20261003.json`.
A final guest probe after the uninstall observed no product processes, no
product tasks, and no installed executables.

## Acceptance boundary

This is strong real-VM evidence for `Install → live Windows round trip →
Uninstall` on the published preview.106 Setup, in addition to the separate
preview.105 → preview.106 upgrade record. It is not a claim that Issue #2 is
closed: a blank current-source VM still needs the complete Repair, signed
N-1 → N upgrade, interrupted rollback/downgrade, independent guest-worker,
and remaining tray/signing acceptance gates. The optional Windows 11 ARM64
x64-emulation Repair timeout remains separately recorded in the current audit.
