# Current GitHub Audit — 2026-09-30

This is the post-merge audit for the live `origin/main` state. It records the
evidence that is safe to claim now and keeps the remaining runtime gates
explicit instead of treating hosted CI as a substitute for a clean physical or
virtual machine.

## Repository and release invariants

- `origin/main`: `34c4f25a499e05b988c21fac473e13c4a00d4909`
- PR #153: merged at `2026-09-30T07:34:41Z` as the commit above
- Open pull requests: none
- Open issues: #2 (Windows one-click installer and desktop host) and #3
  (heterogeneous Linux and macOS worker packages)
- Stable tag `v0.0.1`: `e4fbaef04b764268fa038311d85573b18b549f9f`
- The local tag and `git ls-remote origin refs/tags/v0.0.1` agree. The tag and
  its release assets were not moved or replaced.

## PR #153 and CI evidence

PR #153 (`fix: validate fresh v2 lifecycle requests`) fixed two independent
Windows acceptance defects:

1. Fresh v2 firewall requests are `OrderedDictionary` values in Windows
   PowerShell 5.1, so lifecycle binding now checks dictionary keys as well as
   JSON-recovered object properties. v1 worker-only requests remain isolated
   from v2 discovery-field validation.
2. The packaged acceptance script now uses a Windows PowerShell 5.1-compatible
   protocol pattern instead of treating `if` as an expression.

The corrected head `7ac7c499316904cc1fbe8a4a65a5a8eeb9abfc0a` passed all checks
before merge:

- Windows Setup packaged lifecycle: run
  [36680100392](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/36680100392)
- Full CI matrix (Windows desktop/bridge, Windows Rust, Linux/macOS Rust,
  Worker Kits, MSRV, and product identity): run
  [36680100350](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/36680100350)
- CodeQL: run
  [36680100364](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/36680100364)
- Dependency security (RustSec, Cargo deny, pnpm audit): run
  [36680100382](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/36680100382)

The Setup run compiled the current-source installer, retained the exact
candidate artifact, and completed the disposable Install/Repair/Uninstall
lifecycle. This is hosted disposable-environment evidence; it is not the
missing clean-VM N-1 → N upgrade/rollback proof.

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
Setup artifact was copied into the guest and launched with `/S`.

That guest was not clean: its existing install manifest was timestamped
2026-09-23 and contained the older long native-plugin tree. The attempted
current-source repair therefore entered the old-install transaction backup
path and failed while copying a deeply nested existing file. The sanitized
diagnostic is retained under
`D:\ClusterYourCodex-validation\vmware-clean-setup-20260930\` and contains no
guest password or token. This is useful evidence for the upgrade/long-path
boundary, but it is not a clean Install → Repair → Upgrade → Rollback →
Uninstall pass and must not close Issue #2.

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
