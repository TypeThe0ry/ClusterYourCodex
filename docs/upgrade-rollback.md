# Upgrade, repair, rollback, and uninstall

> **Current boundary:** Same-version Repair and Uninstall have local lifecycle
> validation. Cross-version prerelease upgrade is an experimental acceptance
> path, not a supported update channel. Signed `N-1 -> N`, interrupted-upgrade
> rollback, and downgrade policy remain GA blockers.

## Exercise an experimental prerelease upgrade

1. Read `CHANGELOG.md` and the target release notes.
2. Download Setup and its sidecar from the same prerelease and verify SHA-256.
3. Close active delegated jobs or wait for terminal cleanup.
4. Back up the profile or use a disposable VM, then run the newer Setup from the
   same Windows user profile. The lifecycle is designed to recognize owned
   state, validate the package/manifest, snapshot replaced files, preserve
   data/identities, install the new version, and verify before commit. The run
   itself must prove each property; the design is not prior `N-1 -> N`
   acceptance evidence.
5. Open the GUI, verify the displayed version, run Integration Self Test, then
   Full Run Check.

An older installer must not be used to silently downgrade a newer data schema.
Until the signed update channel and formal downgrade gate ship, restore a known
good backup/VM snapshot or test a newer prerelease in a disposable environment
instead of forcing a downgrade.

## Repair

Rerun the exact current-version Setup. Repair is transactional and idempotent:
it verifies owned binaries/catalogs, Codex integration, Scheduled Tasks,
worker configuration, TLS identity, and the product-owned firewall state. A
failed repair preserves or restores the prior verified state and leaves
machine-readable recovery evidence.

## Rollback after failure

Do not delete transaction files or product directories manually. Rerun the
same Setup/Repair operation; startup reconciliation resumes or compensates a
recognized incomplete transaction. If it still fails, retain the diagnostic
JSON and exact installer hash for the bug report.

## Uninstall

Use **Windows Settings > Apps > Installed apps > ClusterYourCodex > Uninstall**.
The default removes only product-owned program files, tasks, registration,
firewall state, plugin registration, and the managed `AGENTS.md` range while
preserving product data.

For an explicit data purge, use the installed uninstaller script from the same
user profile:

```powershell
& "$env:LOCALAPPDATA\Programs\ClusterYourCodex\installer\Uninstall-ClusterYourCodex.ps1" -PurgeData
```

Back up needed logs/artifacts first. After uninstall, verify product-owned
tasks, firewall rule, Apps registration, process, install root, plugin entry,
and managed `AGENTS.md` block are absent; do not remove unrelated user files.
