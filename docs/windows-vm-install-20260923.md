# Clean Windows VM: published Setup path failure

## Environment and artifact

Windows 11 installed and reached the desktop in a disposable VMware VM using
CLI-only control. The VM uses SATA storage and an e1000e adapter behind a PCIe
root port. Installation used modified no-prompt media and a guest-only TPM
Setup exception; this is a compatibility environment, not proof of supported
Windows 11 hardware compliance. VMware Tools and the test file share worked.

The unchanged published `v0.0.1` Setup executable was verified inside the guest:

```text
SHA-256 F49DF3F288EAD7D167E0197ED1BD3F5F4EB60F6FE54A3BC2E7B1FE79D90F8C65
Started  2026-09-22T23:55:38Z
Finished 2026-09-22T23:58:47Z
Exit     1
Stage    core-applying
```

The installer copied executables, then failed and removed them. The retained
private lifecycle diagnostic identified `Install-PlannedFiles` in
`bootstrap.ps1`, at the `Copy-Item` to its temporary destination. The failing
payload was the MCP SDK's `server/middleware/hostHeaderValidation.d.ts.map`.
The destination was 216 characters; appending `.cyc-install-` and a 32-character
GUID made the staging path 261 characters. Windows PowerShell 5.1 in the clean
guest rejected it with `DirectoryNotFoundException`. Current main retained
the same staging expression, so this is not only a historical release defect.

## Fix and verification

Stage under a GUID-based name in the destination directory rather than append
to the complete destination filename. Keep source and copied-file hash checks,
same-directory replacement, and temporary-file cleanup.

`Test-InstallPlannedFiles.Tests.ps1` uses a valid 241-character destination whose
old staging name would exceed MAX_PATH, plus a source-integrity failure case:

| Environment | Before fix | After fix |
| --- | --- | --- |
| Clean VM, Windows PowerShell 5.1 | Long-path case failed; integrity case passed | Both passed |
| Existing development host, Windows PowerShell 5.1 | Both passed | Both passed |

The host result alone would have missed this defect. The same regression now
runs in the Windows installer test step in CI. The broader local packaging
script was blocked before execution by antivirus (`ScriptContainedMaliciousContent`);
it is not reported as passed, and protection was not disabled.

## Diagnostic Setup and controller startup

An unpublished diagnostic Setup was repacked from the verified `v0.0.1`
archive with only the bootstrap staging-path fix and corresponding package
hash metadata updated. The original release manifest was excluded rather than
reuse an attestation for changed bytes. This is not a current-source release
candidate, and the published release was not replaced.

```text
SHA-256 FFEF281CE84BB060EA5AE0427BD193D4D5A6EADD9221360A608E48E8128F9196
Started  2026-09-23T00:14:44Z
Finished 2026-09-23T00:21:21Z
Exit     0
```

The desktop, controller, worker, CLI, bundled Node runtime and Windows worker
kit were installed. A fresh guest observation at `2026-09-23T00:25:52Z`
confirmed the controller scheduled task and process were running. An
authenticated request to `/v1/health` returned HTTP 200, `status: ok`,
`apiVersion: cyc.dev/v1`, `controllerVersion: 0.0.1`, and `database: ok`.
The token was read inside the guest and was not included in commands or reports.

Launching the installed desktop through the guest Run dialog rendered the
Chinese home screen with zero computers. The captured first-launch screen
includes Windows' controller firewall prompt, which remained unresolved at
this observation. This proves rendering, not remote connectivity or completion
of the Add Computer and Codex integration flows.

![Diagnostic desktop first launch](assets/windows-vm-first-launch.png)

At `2026-09-23T00:32:00Z`, the installed plugin passed
`Test-NativeCodexPlugin.ps1` (six required payload files and bundled runtime).
The installed Node executable then ran `Test-McpDeployment.mjs` against the
installed MCP directory and exited 0. Initialization negotiated protocol
`2025-06-18`, and `tools/list` returned all eight expected tools. The probe
uses self-test mode: this verifies the installed stdio server and payload,
not registration in a Codex client or an actual fleet job.

This verifies diagnostic Setup installation and controller/database startup,
not desktop interaction, native Codex plugin use, a live worker job, or the
complete repair/upgrade/rollback/uninstall lifecycle. Issue #2 remains open
until the applicable checks finish against a current-source candidate.
Published `v0.0.1` bytes and tag are unchanged.
