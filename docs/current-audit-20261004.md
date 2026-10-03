# Current audit — 2026-10-04

## Source and merge

- PR #195, `fix(windows): bind profile helper evidence to case root`, merged
  into `origin/main` at `22a2f6fa993aa9e25e47a814395e485a3dba90d7`.
- The PR passed the complete required CI set, including Windows bounded-process
  tests, Windows Setup acceptance, Desktop/Codex bridge live round-trip,
  CodeQL, RustSec, Cargo deny, pnpm audit, MSRV, and Linux/macOS Worker Kits.
- The next tagged candidate is `v0.1.0-preview.109`; it is intentionally a
  prerelease. Stable `v0.0.1` remains at
  `e4fbaef04b764268fa038311d85573b18b549f9` both locally and remotely.

## ARM64 profile-matrix repair

The preview.108 ARM64 job failed in the profile-matrix child after the fresh
deployment itself had succeeded. The helper-mode path referenced an undefined
`$caseRoot` and then looked for parent evidence under the child work directory.
PR #195 adds an explicit `ProfileMatrixCaseRoot`, requires
`<case>\fresh-deployment` to be its direct child, and recursively flattens the
legacy Windows PowerShell `Value`/`Count` JSON projection before validating
helper records. The source contract also protects the regression with a static
PowerShell test.

## D-drive VMware CLI evidence

The published `v0.1.0-preview.108` Setup was copied into the D-drive Windows 11
validation guest and repaired through VIX, without Computer Use or VMware GUI
automation. The guest returned Setup exit code `0`. The installed manifest and
all four product binaries reported preview.108; controller health returned
`status=ok`, API `cyc.dev/v1`, and database `ok`; the Controller task was
Running; listeners existed on loopback `47831` and managed-worker `47832`; and
`cyc discover` returned one candidate with `credentialsTransmitted=false` and
`pairingRequired=true`.

The installed same-host fixture then returned exit code `0`, observed
`queued -> running -> succeeded`, 14/14 checks passed, and
`jobRootDeleted=true`. Sanitized records are retained outside Git at:

```text
D:\ClusterYourCodex-validation\preview108-public-20261003\preview108-installed-evidence-20261004.json
D:\ClusterYourCodex-validation\preview108-public-20261003\preview108-roundtrip-result-20261004b.json
D:\ClusterYourCodex-validation\preview108-public-20261003\preview108-roundtrip-checks-20261004.json
```

This is installed same-host Windows evidence. It does not claim a blank-VM
Install → Repair → Upgrade → Rollback → Uninstall matrix or replace the
Windows↔Windows, Windows↔Linux, Linux↔Linux, and native macOS acceptance
boundaries already recorded in the repository. Issues #2 and #3 remain open.
