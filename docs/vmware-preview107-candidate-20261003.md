# VMware preview.107 candidate validation — 2026-10-03

This record documents a command-line-only VMware/VIX run against the
`v0.1.0-preview.107` Windows candidate built from PR #191. It is a candidate
record, not evidence for the later published/tagged asset: the Setup came from
PR #191 head `ffb222c769ee03cc266b6a4824a51648d22ded0b`, and its SHA-256 is
`d4e40de25b5cc62eb6226c844498c181ab2c31fefed7d6aa022e58d149aae96d`.
The guest was a disposable D-drive Windows 11 image with the product already
present; it was not a blank Windows installation. VMware was controlled only
with `vmrun` and the in-process VIX helper. Computer Use was not used, and
credentials remain outside Git.

## Install and Repair

The candidate Setup installed successfully (`installExitCode=0`) and reported
`0.1.0-preview.107` in the installed manifest. The controller health result
was:

```json
{"status":"ok","apiVersion":"cyc.dev/v1","controllerVersion":"0.1.0-preview.107","database":"ok"}
```

The Repair path was exercised after a deterministic byte mutation of the
installed executable. The exact hashes were:

| observation | SHA-256 |
| --- | --- |
| before mutation | `da3dccc673a64e3ffa7cacc1f1efe1f8dd71c8312bd740dc2fdb7dafb1cc6471` |
| tampered fixture | `be92573a87963b0e948398be794b133c0ff49db20141fbe9802387b6ea088c4b` |
| after Repair | `da3dccc673a64e3ffa7cacc1f1efe1f8dd71c8312bd740dc2fdb7dafb1cc6471` |

Repair exited `0`, restored the exact pre-mutation hash, and left the
controller health result good. The sanitized source result is retained outside
Git at
`D:\ClusterYourCodex-validation\guest-exchange\preview107-install-repair-result.json`.

## Live round trip

The installed candidate completed the same-host controller/worker fixture with
exit code `0`. All fourteen checks were true:

`privateJobRootAcl`, `controllerHealth`, `tlsIdentity`, `pairingReady`,
`nodeReport`, `jobClaimed`, `heartbeatWindow`, `completion`, `logs`, `artifact`,
`cleanup`, `routeTrace`, `processCleanup`, and `secretScan`.

The observed state sequence was `queued → running → succeeded`; the run lasted
8 seconds. Cleanup reported `removed` and `jobRootDeleted=true`, and the
process-cleanup and secret-scan checks passed. The sanitized records are
retained outside Git at:

- `D:\ClusterYourCodex-validation\guest-exchange\preview107-roundtrip-result.json`
- `D:\ClusterYourCodex-validation\guest-exchange\preview107-roundtrip-checks.json`

This is same-host Windows fixture evidence. The record explicitly does not
claim clean-VM, production-signing, or cross-machine acceptance.

## Credential-free discovery

The candidate answered the local discovery probe with API
`cyc.dev/discovery/v1`, role `controller`, service `clusteryourcodex`, and
version `0.1.0-preview.107`. The response set
`credentialsTransmitted=false` and `pairingRequired=true`. Discovery therefore
provided a candidate endpoint without transmitting credentials; host-key
verification and the normal explicit pairing flow remain required. The raw
sanitized discovery object is embedded in the install/repair result outside
Git; no address, username, password, token, or machine identifier is copied
into this repository.

## Uninstall

Quiet uninstall exited `0`. Afterward, the install root was absent, product
scheduled tasks were absent, and the data root remained, matching the
non-purge uninstall contract. The sanitized result is retained outside Git at
`D:\ClusterYourCodex-validation\guest-exchange\preview107-uninstall-result.json`.

## Acceptance boundary

This candidate run proves useful Windows install, deterministic Repair, live
same-host round trip, credential-free discovery, and quiet uninstall behavior
for the PR #191 build. It is not a published/tagged preview.107 asset and does
not close Issue #2: a genuinely blank current-source Windows 11 matrix,
independent guest-worker acceptance, interrupted rollback/downgrade, and
remaining signing/tray/one-click GA requirements are still outstanding. Issue
#3 remains open; native macOS runtime validation is deferred by request.
