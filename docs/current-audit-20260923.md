# Current GitHub Audit — 2026-09-23

This record is based on the live repository state queried on 2026-09-23. It is
kept in the repository so the README does not rely on an implicit chat state.

## Repository and release invariants

- `origin/main`: verify with `git fetch origin --prune; git rev-parse origin/main`
- PR #122: merged at `2026-09-23T02:03:29Z`
- PR #123: merged at `2026-09-23T03:02:06Z`
- PR #124: merged at `2026-09-23T03:43:42Z`
- PR #125: merged at `2026-09-23T04:30:28Z`
- PR #126: merged at `2026-09-23T05:21:04Z`
- PR #127: merged at `2026-09-23T06:09:35Z`
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
- Audit self-reference correction PR #127 uses the same full matrix; its
  checks are linked from the pull request and the live ref is intentionally
  resolved by command rather than copied into this document.
- CodeQL and dependency-security runs for PR #122 completed successfully.
- The clean Windows VM diagnostic record documents Setup exit `0`, Controller
  health `200`, desktop first launch, and the installed native MCP eight-tool
  probe in [windows-vm-install-20260923.md](windows-vm-install-20260923.md).

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
Issue #3 still requires a real macOS host running the LaunchAgent and a live
managed Controller/Worker round trip. macOS descendant/new-session cleanup and
process-identity checks also need native runtime evidence; package compilation
alone is insufficient.

## Reproduction commands

```powershell
gh pr list --repo TypeThe0ry/ClusterYourCodex --state open
gh issue list --repo TypeThe0ry/ClusterYourCodex --state open
git rev-parse v0.0.1
git ls-remote origin refs/tags/v0.0.1
```

No command in this audit mutates the stable tag or release assets.
