# Windows runtime ownership repair — 2026-10-01

This note records the evidence behind PR #158. It is an intermediate audit,
not a release-acceptance claim. PR #158 is merged as
`8d9fd499bd3312a81dda986985fd2cace09efac0`; the stable release remains
untouched.

## Confirmed failure chain

The packaged Setup executable is an x86 NSIS process. When that process starts
`$SYSDIR\\WindowsPowerShell\\v1.0\\powershell.exe`, Windows file-system
redirection selects the 32-bit (WOW64) PowerShell. In that process,
`Get-Process.Path` may be empty for a 64-bit `cyc-controller.exe`. The
lifecycle stop path could therefore fail to recognize its own controller and
report a false port-occupied error during repair.

There was a second, independent race: the owned scheduled task can have a
restart policy and relaunch the controller between a normal task stop and the
port preflight. A stop operation must end the exact task, quiesce exact-path
owned processes, and fail closed if an owned process remains.

## Repair recorded in PR #158

- `Get-CimInstance Win32_Process` is used to obtain the exact
  `ExecutablePath` for owned runtime processes. The fallback still compares
  exact paths; it never kills by a process name alone.
- The x86 NSIS launcher resolves `Sysnative\\WindowsPowerShell\\v1.0\\powershell.exe`
  when available, so lifecycle code normally runs in native PowerShell. It
  falls back to the system PowerShell path only when Sysnative is unavailable.
- Scheduler cleanup uses a properly quoted `schtasks.exe /End` invocation,
  bounded re-enumeration, and a fail-closed remaining-process check. This
  covers both the `RestartCount` relaunch race and the x86 process-inspection
  limitation.

## Verification already completed

- Targeted Windows Pester coverage: **31/31 passed**, including the lifecycle
  port-preflight reappearance case.
- An x86 read-only CIM smoke check returned the expected exact executable path
  for a 64-bit target process; no process was modified by that check.
- Static packaging assertions cover the CIM `Win32_Process`/`ExecutablePath`
  path, `CycResolvePowerShellPath`, Sysnative selection, `/End`, bounded
  re-enumeration, and fail-closed behavior.
- Full CI run `36749204624` passed the Windows desktop/bridge, bounded Windows
  Rust, live Windows controller/worker, Linux/macOS Rust, Worker Kits, MSRV,
  product-identity, CodeQL, RustSec, Cargo deny, and pnpm audit jobs.
- Windows Setup acceptance run `36749204684` passed and produced the candidate
  artifact with SHA-256
  `438c162c730f4e7eec60971ee965abafd4c1c45cd350628bfe6b376fa09f75d1`.
- The earlier runs `2951015` and `7ca323f` exposed static-test assumptions;
  those were corrected before the green `a7f7df1` candidate was merged.

## VMware command-line validation

The D-drive Windows 11 guest was driven with `vmrun` only. The installed
candidate Setup exited with code `0`; the guest diagnostic reached
`status=succeeded`, `stage=complete`, `firewallVerified=true`, and
`coreSucceeded=true`. A follow-up health probe returned HTTP 200 with
`database=ok`; the install manifest reported schema v1, version `0.0.1`, and
3571 files. Evidence is retained outside Git under
`D:\ClusterYourCodex-validation\vmware-clean-setup-20260930\`.

The same guest's credential-free LAN discovery probe exited `0` and returned a
controller candidate on UDP `47830` with `credentialsTransmitted=false` and
`pairingRequired=true`; its retained output is
`cyc-discover-158.txt` in that evidence directory.

The installed-package round-trip harness created the controller pairing bundle
and staged a worker credential, but exited before a complete worker-pair/worker
job proof. Its sanitized evidence is retained under the same directory. This
is recorded as a VM harness boundary, not as a product success claim; hosted
CI remains the authoritative live Windows round-trip proof for this candidate.

## Still pending

- **Issue #2:** a genuinely clean Windows guest still must prove the complete
  current-source Install → Repair → Upgrade → Rollback → Uninstall lifecycle,
  plus a live controller/worker job. The provisioned guest Setup/health and LAN
  discovery results above, and hosted CI, are supporting evidence, not that
  gate.
- **Issue #3:** native macOS validation is deferred by the current priority;
  Linux worker evidence remains separate from the deferred macOS gates.

The stable `v0.0.1` tag and its release assets remain immutable at
`e4fbaef04b764268fa038311d85573b18b549f9`.

<!-- Do not convert this note into a clean-VM or GA claim without the artifacts
     listed above and the remaining Issue #2 lifecycle evidence. -->
