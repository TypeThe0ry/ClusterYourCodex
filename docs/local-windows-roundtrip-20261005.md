# Local Windows controller/worker round trip — 2026-10-05

This record captures a fresh, self-contained live round trip executed from the
current Windows checkout after the public `v0.1.0-preview.111` install. It is
supplemental evidence for Issue #2 and contains no passwords, bearer tokens,
private keys, or worker enrollment material.

## Command and boundary

The repository harness was run with Windows PowerShell and a disposable D-drive
work root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  scripts/Test-WindowsControllerWorkerRoundTrip.ps1 `
  -RepositoryRoot D:\Projects\ClusterYourCodex\installer-path-fix `
  -WorkRoot D:\ClusterYourCodex-validation\preview111-roundtrip-20261005 `
  -KeepEvidence -TimeoutSeconds 240
```

The checkout was clean at commit `60bb863` when the probe started. The harness
creates an isolated controller database, TLS identity, worker configuration,
pairing state, job workspace, and cleanup boundary; it does not reuse the
installed controller database or remembered worker credentials.

## Result

The run returned the acceptance line **`windows controller/worker live
round-trip passed`**. The observed state sequence was:

```text
queued -> running -> succeeded
```

All fourteen checks in the result receipt were true:

- private job-root ACL;
- controller health and TLS identity;
- pairing readiness and node report;
- job claim, heartbeat, completion, logs, and artifact;
- cleanup, route trace, process cleanup, and secret scan.

The generated artifact contained:

```text
roundtrip-output
roundtrip-step-complete
```

Its SHA-256 was
`7A628A8467FEA26C070C97C2BE9ECBAD371A2D279443A8726EFB651AB3BC34B0`.
The cleanup receipt reported `status=removed`, `jobRootDeleted=true`, and the
reservation was released after the terminal acknowledgement.

## What this proves and what it does not

This is current-source live Windows controller/worker evidence, independent of
the installed production data directory. It complements the public-preview
Windows and Linux worker jobs recorded in
[`local-install-preview111-20261005.md`](local-install-preview111-20261005.md).

It does **not** close the remaining Issue #2 gates: a clean Windows 11 guest
running the complete version-changing `Install → Repair → Upgrade → Rollback →
Uninstall` matrix, production Authenticode signatures for Setup and the helper,
or final packaged one-click/tray acceptance. Issue #2 remains open and
`v0.1.0-preview.111` remains a prerelease.

The VMware guest was started through `vmrun` CLI for this validation session.
VMware Tools rejected anonymous guest operations, so no guest-side result is
claimed from this session and no password was guessed or recorded.
