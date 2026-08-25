# Getting started on Windows

> **Acceptance status:** Windows packaging, plan, and fresh-deployment paths are
> CI tested. Adding a real worker, exercising password/agent/private-key SSH,
> and completing a cross-node Full Run are acceptance procedures whose global
> live evidence remains pending.

## What this installs

The current preview installs for the initiating Windows user:

```text
Program files: %LOCALAPPDATA%\Programs\ClusterYourCodex
Product data:  %LOCALAPPDATA%\ClusterYourCodex
```

It installs the desktop host, local controller, CLI, optional local worker,
private Node runtime, Codex marketplace/plugin, signed Worker Kits, per-user
Scheduled Tasks, uninstall registration, and—when a managed LAN listener is
enabled—one product-owned firewall rule. Unrelated global `AGENTS.md` bytes are
preserved outside the uniquely marked ClusterYourCodex block.

## Requirements

- Windows 10/11 x64; Windows 11 is the primary acceptance target.
- A per-user `%LOCALAPPDATA%` profile.
- Codex Desktop or Codex CLI for Codex integration.
- OpenSSH server access to each computer being added.
- Network reachability between the controller and worker.

Rust, Node.js, pnpm, Git, and NSIS are build-time requirements for contributors,
not prerequisites for a self-contained Setup user.

## Install

1. Download `ClusterYourCodex-Setup.exe` and
   `ClusterYourCodex-Setup.exe.sha256` from the same GitHub prerelease.
2. Verify the exact bytes:

   ```powershell
   $setup = (Resolve-Path .\ClusterYourCodex-Setup.exe).ProviderPath
   $sidecar = "$setup.sha256"
   $declared = ((Get-Content -LiteralPath $sidecar -Raw).Trim() -split '\s+')[0]
   $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $setup).Hash
   if ($actual -cne $declared) { throw "Installer SHA-256 mismatch" }
   ```

3. Double-click Setup. The per-user lifecycle remains non-elevated; only the
   narrowly scoped firewall helper may request UAC when a listener rule is
   required.
4. Wait for the GUI. If it does not open, launch:

   ```powershell
   & "$env:LOCALAPPDATA\Programs\ClusterYourCodex\ClusterYourCodex.exe"
   ```

5. Confirm the dashboard shows the controller and Codex integration status.
   Use **Install/Repair Plugin** if the integration says repair is required.
6. Exercise adding a Windows or Linux computer using the matching acceptance
   guide.
7. Run **Full Run Check**. A green controller probe alone is not enough: the
   check must verify source snapshot, placement, native execution, logs,
   artifact hash, and cleanup. Preserve the evidence as acceptance for those
   exact machines; do not generalize it to an untested authentication/platform
   combination.

## Silent install

The silent NSIS path uses the same manifest-bound lifecycle:

```powershell
$process = Start-Process -FilePath .\ClusterYourCodex-Setup.exe `
  -ArgumentList '/S' -Wait -PassThru
if ($process.ExitCode -ne 0) { throw "Setup failed: $($process.ExitCode)" }
```

Do not use `/D=` as a test-isolation mechanism. The lifecycle binds installation
and data roots to the initiating user's profile. Use a disposable local user or
Windows VM for a clean-machine test.

## Next

- [Add a Windows computer](add-windows-computer.md)
- [Add a Linux computer](add-linux-computer.md)
- [Verify Codex integration](codex-integration.md)
- [Upgrade, repair, rollback, uninstall](upgrade-rollback.md)
- [Troubleshooting](troubleshooting.md)
