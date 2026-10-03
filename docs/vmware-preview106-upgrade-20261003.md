# VMware preview.106 upgrade and live round-trip — 2026-10-03

This record captures the command-line-only validation of the published
`v0.1.0-preview.106` Windows Setup in the disposable D-drive VMware guest. The
guest was already running the published `v0.1.0-preview.105`; no credentials,
private keys, or guest configuration secrets are stored in this repository.

## Upgrade result

- Setup source: the published Release asset `ClusterYourCodex-Setup.exe`.
- Downloaded Setup SHA-256:
  `4c5118341f1d9cd20a33082e9d9ed4df3ce137ea3b0c7596521a84f0c62e2745`.
- Transport and execution used `vmrun` to start the guest and the in-process
  VIX helper for guest file transfer/process execution; Computer Use was not
  used.
- Guest Setup exit code: `0`.
- Installed manifest changed from `0.1.0-preview.105` to
  `0.1.0-preview.106`.
- Controller health after the upgrade returned HTTP 200 with:

  ```json
  {"status":"ok","apiVersion":"cyc.dev/v1","controllerVersion":"0.1.0-preview.106","database":"ok"}
  ```

- The sanitized result is retained outside Git at
  `D:\ClusterYourCodex-validation\guest-exchange\preview106-upgrade-result-20261003.json`.

## Post-upgrade runtime checks

The installed preview.106 controller and worker completed the live same-host
round trip with exit code `0`. All 14 checks were true:

`privateJobRootAcl`, `controllerHealth`, `tlsIdentity`, `pairingReady`,
`nodeReport`, `jobClaimed`, `heartbeatWindow`, `completion`, `logs`, `artifact`,
`cleanup`, `routeTrace`, `processCleanup`, and `secretScan`.

The observed state sequence was `queued → running → succeeded`; cleanup
reported `removed` and `jobRootDeleted=true`. This is same-host Windows live
fixture evidence, not clean-VM GA, production-signing, or cross-machine proof.

The post-upgrade credential-free LAN discovery probe also passed. It returned
`cyc.dev/discovery/v1`, controller version `0.1.0-preview.106`,
`credentialsTransmitted=false`, and explicit pairing still required. The
sanitized result is retained outside Git at
`D:\ClusterYourCodex-validation\guest-exchange\preview106-discovery-result-20261003.json`.

## Boundaries

This run proves a real preview.105 → preview.106 upgrade and a usable Windows
controller/worker path in the existing disposable guest. It does not close
Issue #2: a blank current-source Windows 11 VM with the full
Install → Repair → N-1→N Upgrade → interrupted Rollback → Uninstall matrix,
independent guest-worker acceptance, and remaining signing/tray requirements
are still outstanding.
