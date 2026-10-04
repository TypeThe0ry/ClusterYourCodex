# Preview.111 live LAN deployment — 2026-10-04

This record covers the first live deployment of the public
`v0.1.0-preview.111` payload across the current Windows controller, a Linux
worker, and a second Windows worker. Credentials and enrollment secrets are
intentionally excluded from this document and remain outside the repository.

## Deployed topology

| Role | Host | Result | Evidence |
| --- | --- | --- | --- |
| Controller | Current Windows PC | Running; loopback health returned `status=ok`, `apiVersion=cyc.dev/v1`, and `database=ok` | local native controller health probe |
| Worker | NUC (`192.168.1.77`) | `systemd-system` service enabled and active; worker `0.1.0-preview.111`; live telemetry online | `cyc nodes` fleet revision 56+, node `8cc47cff-5c6c-47e9-a777-f46d30c6fa3a` |
| Worker | Helio (`192.168.1.63`) | user-scope Scheduled Task enabled and Running; worker `0.1.0-preview.111`; live telemetry online | `cyc nodes` fleet revision 62+, node `7e207f14-6f4c-4d49-8c4c-26de7b2f9e16` |

The Helio account was not using an elevated administrator session. The first
automatic system-scope attempt failed closed; the existing Helio node was
then re-paired with a fresh one-time enrollment while preserving its logical
node ID, and the explicit user-scope install completed with
`succeeded=true`, `paired=true`, `serviceEnabled=true`, and
`version=0.1.0-preview.111`. This is a working deployment, but the worker
task follows the `sshadmin` user session rather than a machine-wide SYSTEM
service until an elevated install is intentionally performed.

## Live execution evidence

### Linux worker

The controller submitted a manual Linux job to the NUC. It reached exit code
`0`, produced artifact `3c4f87c8-89d4-4058-8cfb-01bd94640f58`, and the downloaded
proof file contained `CYC_NUC_ROUNDTRIP_OK`. The downloaded proof SHA-256 was
`1F0149E73C47A97F340E0CC8FA85A2A471DF2B48541C80D805B7E9E7DE8351D7`.

### Windows worker

The controller planned a Windows/x86_64 job to Helio only; the planner marked
Helio eligible and NUC ineligible for the Windows requirement. The second
clean proof job was:

- job: `0a8b1ab4-8e4d-4e33-9e1e-d2c9a9dc2e94`
- run: `eb2a4a98-360c-4560-b6a4-317e7022438e`
- selected node: `7e207f14-6f4c-4d49-8c4c-26de7b2f9e16`
- state / exit: `succeeded` / `0`
- artifact: `dfefc6ca-65c6-41c0-bbb4-b0a6ca42674f`
- downloaded proof: `CYC_HELIO_ROUNDTRIP_OK`
- proof SHA-256: `50B4534C869ECB94634F7BDB1EC8314B693C611B02B3BEA7CDF2164B4E080C54`

The job exercised snapshot reuse, manual placement, Windows PowerShell
execution, artifact transfer, and controller-side verification. A preceding
probe used a literal PowerShell backtick sequence in the proof text; it also
completed successfully, but it is not used as the clean evidence above.

## Scope and remaining gates

This proves a usable three-machine Windows-controller deployment and live
Windows↔Linux plus Windows↔Windows execution path. It does not close the
native macOS LaunchAgent and detached-descendant gates in Issue #3, nor the
clean-guest Install → Repair → Upgrade → Rollback → Uninstall matrix and
production-signing gates tracked in Issue #2. The public
`v0.1.0-preview.111` release therefore remains a prerelease; stable `v0.0.1`
is unchanged.
