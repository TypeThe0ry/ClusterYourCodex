# Current GitHub Audit — 2026-09-23

This record is based on the live repository state queried on 2026-09-23. It is
kept in the repository so the README does not rely on an implicit chat state.

## Repository and release invariants

- `origin/main`: `19b60fef50d83f7e04a706840efdfb877bec99c0`
- PR #122: merged at `2026-09-23T02:03:29Z`
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
