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

This verifies the payload-copy fix, not a complete rebuilt Setup install,
repair, upgrade, rollback, uninstall, or live job. Issue #2 remains open until
those applicable lifecycle checks finish. Published `v0.0.1` bytes and tag are
unchanged; a corrected installer requires a new candidate artifact.
