# Windows Task Scheduler bounded lifecycle adapter

## Why this change exists

The Windows 11 ARM64/x64-emulation acceptance run for `v0.1.0-preview.106`
did not fail on the payload, manifest, or executable. The fresh Repair child
could spend the full 900-second lifecycle limit inside an in-process
Task-Scheduler RPC call. The same repair was reproducibly slow in the silent
Setup diagnostics, while the native x64 lifecycle remained green.

## What changed

`packaging/windows/bootstrap.ps1` now keeps Task Scheduler operations behind
bounded adapters:

- read-only task snapshots and readiness state use a short-lived Windows
  PowerShell child with the `Schedule.Service` COM API;
- the parent binds the child to the exact `Process` handle, waits for a fixed
  deadline, kills that handle on timeout, and verifies that it terminated;
- snapshot/action data crosses the process boundary as base64-encoded UTF-8
  JSON, so Unicode profiles and Windows paths retain their exact bytes;
- only the machine-level Task Scheduler not-found HRESULTs
  (`0x80070002` and `0x8004130F`) are treated as an absent product task;
  service, access, RPC, or malformed-task errors fail closed;
- action count, logon-trigger type/count, principal SID, trigger SID, root
  path, executable, arguments, and working directory remain ownership
  invariants;
- End/Delete/Run use a bounded native `schtasks.exe` process, and Action/XML
  registration uses a bounded child. Action registration repeats the
  same-name ownership check immediately before `-Force`.

The stable `v0.0.1` tag is not changed by this work. The change is a candidate
for the next public prerelease only after its Windows CI and VMware lifecycle
evidence are complete.

## Verification boundary

The local host parser and static packaging checks were run where available;
the repository's Windows packaging script was also submitted to the existing
Windows CI gate. A clean Windows 11 ARM64 Repair rerun is still required before
claiming that ARM64 is green. Until that rerun succeeds, Issue #2 remains open
for the remaining combined clean-VM GA matrix and production signing/tray
requirements.
