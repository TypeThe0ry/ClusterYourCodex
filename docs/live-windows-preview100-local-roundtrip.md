# Windows preview.100 published-binary round trip

Verified on 2026-09-08 on a Windows x64 development host (build 26200).

## Artifact and harness identity

- Product binaries: downloaded public `v0.1.0-preview.100` Windows x64 portable
  archive, `bin/cyc.exe`, `bin/cyc-controller.exe`, and `bin/cyc-worker.exe`.
- Immutable product source: `2c269842dbc15934b5cfcf6a4cb3e0844cec3ed5`.
- Archive SHA-256: `eb53351aa3fe4ecb2fc734ba13a6e62773135777fee8fc336a1882c0df23fc63`.
- Harness: `scripts/Test-WindowsControllerWorkerRoundTrip.ps1` based on
  `bfd7e38753f3031a4a9f7058d15787889f29971a`, with the DACL-only fixture repair
  committed alongside this record. The result's `sourceCommit` is the harness
  checkout HEAD, not the released binaries' source commit.
- Evidence root:
  `D:\Projects\ClusterYourCodex\release-validation\preview100-fixed\cyc-windows-controller-worker-roundtrip.4316f2c61faa4cf4807b099f5eb2f903`.

## Result

Probe exit `0`; result `passed`; all 14 recorded checks true.
Observed `queued -> running -> succeeded`, with an 8-second job.
Job ID: `2ab317cf-6f00-4fd7-9c90-6e017d4fdbca`.

Verified private-root ACL, controller health, TLS identity, pairing readiness,
node reporting, job claim, heartbeat, completion, stdout/stderr retrieval,
artifact content/digest, route trace, cleanup receipt, process cleanup, and
secret scanning. Cleanup reported `removed`, `jobRootDeleted=true`, and the
reservation was released. The pre-existing preview.95 controller was left running.

## Fixture repair and boundaries

The original harness failed before invoking any product binary because
replacing the complete directory security descriptor requested an ownership
operation unavailable to this desktop session. PowerShell 5.1 and 7 both
reproduced it. The corrected harness preserves owner/group, refuses a foreign
owner, removes inherited/extra access rules, grants only the current user and
SYSTEM, then rereads and verifies the same strict private-root contract.
Nine PowerShell contract tests passed; no product binary or machine-wide ACL
was changed, and failed-attempt directories were retained.

This is a real same-host protocol/job round trip using released binaries. It
does not prove desktop Add Computer/SSH credential retention, a cross-machine
GUI/MCP run, a clean VM, real macOS LaunchAgent operation, or production signing.
Those remain explicit next checks rather than inferred completion.
