# Current GitHub audit — 2026-10-01

This is the post-PR-#163 audit for the current repository state. It records
what is proven by the latest checks and keeps the remaining native-environment
gates explicit. The exact moving `origin/main` hash is resolved by the commands
below rather than copied into this document.

## Repository and release invariants

- PR #163 (`test: cover inherited transaction ACL creation`) merged at
  `2026-10-01T00:24:52Z` as `2556b876eba478e57d9605cb70f4d4e0fb7a89fd`.
- PR #163 added a regression test for a transaction child created beneath a
  parent with inherited ACLs. The child must be owner/SYSTEM-only, protected
  from inheritance, and safe for the private state-tree assertions.
- PR #163 also hardened the Windows live round-trip fixture: a candidate
  RFC1918 address must pass a local TCP self-connect probe before it is used as
  `worker-public-url`. This prevents a virtual adapter with a non-usable
  address from causing a 60-second worker-pair timeout.
- The remote open-PR list is empty after the merge. Issues #2 and #3 remain
  open because their final native-environment gates are not complete.
- Stable `v0.0.1` remains immutable at
  `e4fbaef04b764268fa038311d85573b18b549f9`; local and remote tag hashes
  agree, and no release asset was replaced.

## Verification

PR #163's exact head `288fbb1936c1349c291b9f7daa3dbc79e922b483` passed the
complete required candidate matrix:

- Desktop/Windows host/Codex bridge, including the Windows
  controller/worker live round trip: [job 110148552448](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/36792430897/job/110148552448), 40m41s.
- Rust Windows workspace: [job 110148552483](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/36792430897/job/110148552483), 36m18s.
- Packaged silent install and running-controller repair: [job 110148189619](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/36792430990/job/110148189619), 36m53s.
- Linux/macOS Rust, Linux x64 and macOS x64/arm64 Worker Kits, MSRV, CodeQL,
  RustSec, Cargo deny, pnpm audit, and product-version identity all passed in
  the same candidate runs.
- Local Windows PowerShell 5.1/Pester contract tests passed 10/10, and a
  local release-binary controller/worker round trip passed all 15 runtime
  checks (health, TLS identity, pairing, node report, scheduling, heartbeat,
  completion, logs, artifact, cleanup, route trace, process cleanup, and
  secret scan).

The CI failure that motivated the address fix was independently reproduced
from its retained artifact: the controller was healthy, but the selected
`192.168.192.1` address never received `/worker/v1/pair`; the prior passing run
selected `172.28.0.1`. The fix rejects unusable candidates without relaxing
TLS, pairing, ACL, or cleanup checks.

## Cross-platform and LAN evidence

Sanitized records still prove Windows↔Windows, Windows↔Linux, Linux↔Linux,
and credential-free same-L2 IPv4 discovery. Discovery returns metadata only;
pairing remains explicit and routed-subnet enumeration is not claimed. The
desktop Add Computer path now queries the native credential-vault capability:
Windows keeps the Credential Manager option, while controllers without a
persistent native vault use an explicit session-only password path. A stale or
direct request to persist a password on an unsupported controller is rejected
before SSH or record creation. The reusable live SSH acceptance harness is
documented in [`provisioning-ssh-e2e-20261001.md`](provisioning-ssh-e2e-20261001.md);
its ignored live case is not counted until a disposable real target completes.
The matrix is documented in
[`cross-platform-validation-20260927.md`](cross-platform-validation-20260927.md).

## VMware CLI boundary

The D-drive Windows guest was operated with VMware `vmrun` only. Controller
health, database health, the managed-worker TCP listener, and `cyc discover`
all passed on the provisioned guest; discovery reported
`credentialsTransmitted=false` and `pairingRequired=true`. A second CLI-only
inspection on 2026-10-01 started and soft-stopped the guest cleanly, but found
no logged-on user (`quser` had no session, Winlogon had `AutoAdminLogon=0`, and
`runProgramInGuest -interactive` was rejected). The default Interactive
scheduled task therefore cannot be proven in this headless guest. This is an
environment/session boundary, not evidence to bypass the product's fail-closed
task-health or ACL checks. See
[`vmware-cli-recheck-20261001.md`](vmware-cli-recheck-20261001.md) for the
sanitized procedure and evidence location.

A follow-up CLI-only session-channel probe confirmed that host keyboard
injection is rejected by `vmrun`. An initial guest command did not change the
RDP registry state, but a later explicitly credentialed guest PowerShell
command enabled TermService and a `3389` listener was confirmed. The host
`mstsc.exe` attempt still did not yield a stable interactive session, so it is
not counted as lifecycle evidence. Temporary RDP credential material was
deleted after the probe, and RDP was disabled before shutdown. No product task
or ACL guard was weakened.

The exact current `packaging/windows/bootstrap.ps1` was then executed in the
same guest through VMware Tools. Its focused ACL proof passed: a fresh child
under an inheritance-enabled parent became protected with no inherited ACEs,
and an already-existing weak child was rejected without changing its security
descriptor. This confirms the existing fail-closed helper contract; it is not
clean-VM lifecycle evidence.

The follow-up then used a separate D-drive full clone rather than the linked
clone that retained a pre-existing weak transaction directory. The per-user
install/data roots were reset; the first Setup attempt exited `1` because the
installer diagnostic reported an active lifecycle mutex. After that process
ended, the `install2` retry exited `0` and reached `status=succeeded`,
`lastStage=complete`, `coreSucceeded=true`, and `firewallVerified=true`. A
second same-version Setup run completed the idempotent Repair-equivalent path,
and the installed health/listener/discovery probes passed. A quiet uninstall
removed the install root, scheduled task, firewall rules, and uninstall
registration while preserving the user data root. The sanitized procedure and
exact evidence boundary are recorded in
[`vmware-clean-full-lifecycle-20261001.md`](vmware-clean-full-lifecycle-20261001.md).

A separate reset full clone was then booted with a temporary private autologon
only so its Interactive scheduled task could be exercised. The post-logon
Setup run succeeded and the installed controller/worker harness passed all 15
checks (`queued → running → succeeded`, exit code `0`); the evidence and
boundary are recorded in
[`vmware-installed-task-roundtrip-20261001.md`](vmware-installed-task-roundtrip-20261001.md).

This still does not close Issue #2's full
Install → Repair → Upgrade → Rollback → Uninstall matrix: the version-changing
Upgrade and interrupted-install Rollback remain unproven. Hosted CI and the
retained cross-platform records remain the authoritative live Windows,
Windows↔Linux, and Linux↔Linux runtime evidence. No credentials, tokens, or
pairing material are stored in Git.

## Remaining issues

### Issue #2 — Windows one-click installer and desktop host

Keep open until a genuinely clean current-source Windows 11 guest completes
the full lifecycle and records the required signed Setup/helper and live
installed-package worker evidence. Hosted CI and a provisioned guest are
supporting evidence, not a replacement for that gate.

### Issue #3 — Heterogeneous Linux and macOS worker packages

Linux x64 and macOS x64/arm64 package/build checks pass. Native macOS
LaunchAgent install/start/stop/restart, managed Controller/Worker runtime,
detached-descendant/PID-reuse evidence, and any required signing/notarization
remain intentionally deferred. Keep the issue open.

## Reproduction commands

```powershell
git fetch origin --prune
git rev-parse origin/main
gh pr list --repo TypeThe0ry/ClusterYourCodex --state open
gh issue list --repo TypeThe0ry/ClusterYourCodex --state open
git rev-parse v0.0.1
git ls-remote origin refs/tags/v0.0.1
```

These commands inspect the live repository and do not mutate the stable tag or
release assets.
