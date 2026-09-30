# Current GitHub Audit — 2026-09-30

This is the post-merge audit for the live `origin/main` state. It records the
evidence that is safe to claim now and keeps the remaining runtime gates
explicit instead of treating hosted CI as a substitute for a clean physical or
virtual machine.

## Repository and release invariants

- `origin/main`: `10243cfd26b8b3faee6a793d5ad9405fd725ab84`
- PR #157: merged before the runtime repair and added transactional LAN
  discovery firewall ownership.
- PR #158: merged at `2026-09-30T17:57:26Z` as
  `8d9fd499bd3312a81dda986985fd2cace09efac0`; it repaired native PowerShell
  runtime ownership checks, scheduler-stop quoting, and the x86-to-native
  PowerShell lifecycle boundary.
- PR #159: merged at `2026-09-30T19:18:33Z` as the final audit-documentation
  merge commit recorded above.
- Open pull requests: none
- Open issues: #2 (Windows one-click installer and desktop host) and #3
  (heterogeneous Linux and macOS worker packages)
- Stable tag `v0.0.1`: `e4fbaef04b764268fa038311d85573b18b549f9f`
- The local tag and `git ls-remote origin refs/tags/v0.0.1` agree. The tag and
  its release assets were not moved or replaced.

## PR #157/#158 and CI evidence

PR #157 (`fix: provision LAN discovery firewall rule`) added the credential-free
UDP discovery path to the Windows Add Computer flow and made the TCP/UDP
firewall transaction rollback-safe. PR #158 (`fix: use native PowerShell for
runtime ownership checks`) fixed two independent Windows acceptance defects:

1. The x86 NSIS launcher could enter 32-bit PowerShell, where `Get-Process.Path`
   is empty for a 64-bit controller. The lifecycle now prefers Sysnative
   native PowerShell and uses exact-path CIM ownership checks with a fail-closed
   fallback.
2. A scheduled-task restart could race the stop/preflight check. The repair
   quotes `/End /TN`, bounds the wait, re-enumerates exact owned processes, and
   fails closed if the runtime reappears.

The corrected PR #158 head `a7f7df1` passed all checks before merge:

- Windows Setup packaged acceptance: [36749204684](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/36749204684)
- Full CI matrix: [36749204624](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/36749204624)
- CodeQL: [36749204540](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/36749204540)
- Dependency security: [36749204403](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/36749204403)

The Setup run compiled the current-source installer, retained the exact
candidate artifact, and completed the disposable Install/Repair/Uninstall
lifecycle. The candidate SHA-256 is
`438c162c730f4e7eec60971ee965abafd4c1c45cd350628bfe6b376fa09f75d1`.
This is hosted disposable-environment evidence; it is not the missing clean-VM
N-1 → N upgrade/rollback proof.

## Cross-platform and discovery evidence

The current repository already contains sanitized evidence for:

- Windows controller → Windows worker live round trip;
- Windows controller → Linux x86_64 worker live round trip;
- Linux controller → Linux worker live round trip;
- UDP `47830` same-L2 IPv4 discovery through the CLI and desktop bridge.

Discovery is credential-free metadata only. Enrollment remains an explicit,
short-lived pairing step, and routed-subnet enumeration is intentionally not
claimed. The detailed matrix is in
[cross-platform-validation-20260927.md](cross-platform-validation-20260927.md).

## VMware CLI boundary

The D-drive Windows 11 guest at `192.168.6.131` was started and inspected with
`vmrun` only. VMware Tools returned `installed`, and the current candidate
Setup artifact was copied into the guest and launched with `/S`. Setup exited
`0`; the lifecycle diagnostic reached `status=succeeded`, `stage=complete`,
`firewallVerified=true`, and `coreSucceeded=true`. A follow-up health probe
returned HTTP 200 with `database=ok`; the manifest is schema v1, version
`0.0.1`, with 3571 files.

The guest is still provisioned rather than clean. The installed-package
round-trip harness staged a worker credential but exited before a complete
worker-pair/job proof; hosted CI remains the authoritative live Windows
round-trip result. The same guest's `cyc discover --timeout-ms 1500 --pretty`
probe exited `0`, returned the controller on UDP `47830`, and reported
`credentialsTransmitted=false` plus `pairingRequired=true`. Sanitized evidence
is retained under
`D:\ClusterYourCodex-validation\vmware-clean-setup-20260930\`; no credentials
or tokens are in Git.

## Remaining acceptance gates

### Issue #2 — Windows one-click installer and desktop host

Keep open until a genuinely clean Windows 11 guest proves the current-source
Install → Repair → Upgrade → Rollback → Uninstall matrix, signed Setup/helper
behavior where required, and a live controller/worker job. The hosted
disposable lifecycle and the provisioned VMware guest are supporting evidence,
not a replacement for that gate.

### Issue #3 — Heterogeneous Linux and macOS worker packages

Linux x64 and macOS x64/arm64 kits build and pass hosted probes. Per the current
priority, native macOS LaunchAgent and live managed Controller/Worker runtime
validation is deferred. Keep Issue #3 open until the real macOS host gates,
process-containment checks, and any required Developer ID signing/notarization
evidence are captured.

## Reproduction commands

```powershell
git fetch origin --prune
git rev-parse origin/main
gh pr list --repo TypeThe0ry/ClusterYourCodex --state open
gh issue list --repo TypeThe0ry/ClusterYourCodex --state open
git rev-parse v0.0.1
git ls-remote origin refs/tags/v0.0.1
```

No command in this audit mutates the stable tag or release assets.
