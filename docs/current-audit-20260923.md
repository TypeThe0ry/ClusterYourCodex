# Current GitHub Audit — 2026-09-23

This record is based on the live repository state queried on 2026-09-24. It is
kept in the repository so the README does not rely on an implicit chat state.

## Repository and release invariants

- `origin/main`: verify with `git fetch origin --prune; git rev-parse origin/main`
- Resolve the live `origin/main` with `git fetch origin --prune; git rev-parse
  origin/main`; this document intentionally does not copy a moving branch hash.
- PR #122: merged at `2026-09-23T02:03:29Z`
- PR #123: merged at `2026-09-23T03:02:06Z`
- PR #124: merged at `2026-09-23T03:43:42Z`
- PR #125: merged at `2026-09-23T04:30:28Z`
- PR #126: merged at `2026-09-23T05:21:04Z`
- PR #127: merged at `2026-09-23T06:09:35Z`
- PR #128: merged at `2026-09-23T06:58:06Z`
- PR #129: merged at `2026-09-23T07:49:24Z`
- PR #130: merged at `2026-09-23T11:19:05Z`
- PR #131: merged at `2026-09-23T14:41:56Z`
- PR #133: merged at `2026-09-24T06:30:51Z`
- PR #135: merged at `2026-09-24T09:22:13Z`
- PR #136: merged at `2026-09-24T10:11:31Z`
- PR #137: merged at `2026-09-25T04:41:38Z`
- Open pull requests: none
- Published stable tag `v0.0.1`: `e4fbaef04b764268fa038311d85573b18b549f9f`
- `git rev-parse v0.0.1` and `git ls-remote origin refs/tags/v0.0.1` agree.

## Completed evidence

- Windows Setup acceptance run
  [`35805960001`](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/35805960001)
  completed successfully. It compiled the installer, resolved/retried NSIS,
  installed the packaged application, and exercised the disposable repair
  lifecycle.
- Candidate CI run
  [`35805960000`](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/35805960000)
  completed successfully across Windows, Ubuntu, macOS, MSRV, native Worker
  Kits, and the Windows controller/bridge job.
- Documentation audit PR #123 CI run
  [`35809739780`](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/35809739780)
  completed successfully with the same platform matrix, including the
  37-minute Windows Rust test and the 42-minute Windows controller/worker
  live round trip.
- Documentation audit PR #124 CI run
  [`35812813465`](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/35812813465)
  completed successfully, including the final Windows Rust bounded-process test
  and Windows controller/worker live round trip.
- Final audit merge PR #125 CI run
  [`35815622469`](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/35815622469)
  completed successfully. It included Windows desktop/host/Codex bridge,
  Windows managed Worker Kits, and the Windows controller/worker live
  round-trip, plus the Linux/macOS, MSRV, CodeQL, RustSec, Cargo deny, and
  pnpm audit checks.
- Audit correction PR #126 CI run
  [`35818882361`](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/35818882361)
  completed successfully with the full Windows, Linux, macOS, Worker Kit,
  CodeQL, MSRV, RustSec, Cargo deny, and pnpm audit matrix.
- Audit self-reference correction PR #128 uses the same full matrix; its
  checks are linked from the pull request and the live ref is intentionally
  resolved by command rather than copied into this document.
- The post-merge CI run for PR #129's merge commit completed successfully as
  run [`35833742598`](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/35833742598).
- PR #131's candidate CI run
  [`35870549904`](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/35870549904)
  completed successfully before merge. It covered the full Windows, Linux, and
  macOS Rust matrix, including the macOS process-containment regressions, the
  Windows bounded-process suite, the Windows controller/worker live round trip,
  native Linux/macOS Worker Kits, MSRV, CodeQL, RustSec, Cargo deny, pnpm audit,
  and product-version identity checks. The merge commit is
  `83de510bca30cf6116a20ced105b86ec3e2e9ba5`.
- CodeQL and dependency-security runs for PR #122 completed successfully.
- The clean Windows VM diagnostic record documents Setup exit `0`, Controller
  health `200`, desktop first launch, and the installed native MCP eight-tool
  probe in [windows-vm-install-20260923.md](windows-vm-install-20260923.md).
- A follow-up CLI-only VMware probe confirmed that the controller has
  `vmrun.exe`, the D-drive retry VM is registered, VMware Tools can be queried,
  and the installed guest payload reports `cyc`, `cyc-controller`, and
  `cyc-worker` version `0.0.1`. After restarting that disposable VM to isolate
  the round-trip probe, the console entered Windows Automatic Repair and Tools
  stopped responding; no lifecycle or live-job pass is claimed from this
  observation.
- A new disposable D-drive clone was created and started entirely through
  VMware CLI on 2026-09-24. The verified Windows 11 25H2 English x64 ISO was
  attached, `vmrun` returned exit code `0`, and `checkToolsState` reported
  `installed`. The details are in
  [vmware-cli-install-20260924.md](vmware-cli-install-20260924.md). This is
  boot/tooling evidence only; it does not close the clean-guest lifecycle or
  live-worker acceptance gate.
- PR #135 additionally records the blank-disk installation attempt. VMware
  reported `capacity=0` and `No Media` for both generated SATA and IDE
  CD-ROM configurations, so no clean Windows installation is claimed from
  that attempt.
- PR #137 raised the finite Windows ACL helper deadline from 30 to 120 seconds
  after a cold-runner timeout in the migration-document test. The focused test
  passed locally, and the replacement candidate run
  [`36092595363`](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/36092595363)
  passed the full Windows, Linux, macOS, MSRV, Worker Kit, security, and live
  controller/worker checks.

## Open acceptance boundaries

### Issue #2 — Windows one-click installer and desktop host

The product and hosted acceptance jobs cover the desktop host, native proxy,
scheduled tasks, ACL checks, bundled MCP runtime, and packaged repair path.
The retained D-drive VM record is still diagnostic: it does not prove the
current-source `Install -> Repair -> Upgrade -> Rollback -> Uninstall` matrix
plus a live worker job in a clean Windows 11 guest. Keep the issue open until
that evidence is captured.

### Issue #3 — Heterogeneous Linux and macOS worker packages

Linux x64 and macOS x64/arm64 packages build and pass their hosted probes.
PR #131 is now merged. Its macOS process-table containment backend tracks
`(pid, lstart)` identities, discovers descendants across new process groups,
and re-checks identity before signaling. The merged candidate compiled and ran
the full macOS Rust suite in CI, including detached-descendant and timeout
cleanup regressions. That is stronger than a package-only check, but it is not
customer-host acceptance.
Issue #3 still requires a real macOS host running the LaunchAgent and a live
managed Controller/Worker round trip. macOS descendant/new-session cleanup and
process-identity checks also need native runtime evidence; package compilation
alone, or a hosted runner, is insufficient. Keep
`MACOS_WORKER_CONTAINMENT_READY=0` until those native gates are captured.

## Reproduction commands

```powershell
gh pr list --repo TypeThe0ry/ClusterYourCodex --state open
gh issue list --repo TypeThe0ry/ClusterYourCodex --state open
git rev-parse v0.0.1
git ls-remote origin refs/tags/v0.0.1
```

No command in this audit mutates the stable tag or release assets.
