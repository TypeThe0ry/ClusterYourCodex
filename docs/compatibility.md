# Compatibility and security boundary

## Preview matrix

| Component | Platform/architecture | Current state |
|---|---|---|
| Controller + desktop | Windows x64 | Implemented/CI packaged prerelease; full clean-profile/live acceptance pending |
| Controller + CLI portable | Linux x64 | Developer artifact |
| Managed worker | Windows x64 | Implemented/CI for trusted jobs; live two-machine/auth acceptance pending |
| Managed worker | Linux x64 | Implemented/CI for trusted jobs; live two-machine/auth acceptance pending |
| Managed worker kit | Linux aarch64 | Built/cross-validated; hardware acceptance tracked |
| Controller/CLI/worker portable | macOS x64/arm64 | Experimental native archive; trusted process-group backend implemented, package activation runtime-gated |
| Signed exact-five Worker Kit | macOS x64/arm64 | Packaged; lifecycle validation only, LaunchAgent/live readiness false |
| Managed execution | macOS x64/arm64 | Fail-closed until LaunchAgent lifecycle acceptance; hostile tier remains unavailable |

The exact matrix in each published archive's `platform-status.json` is
authoritative for that asset.

## Controller topology

The controller runs with the Codex execution session. A remote Mac can control
a Codex session hosted on Windows without becoming the controller. Workers
connect to that Windows controller.

## Workload trust

Current workers execute native steps as the worker account. Windows Job Objects,
Linux process/descendant tracking, and the macOS native process-group probe
provide trusted-job lifecycle cleanup; they do not
create a multi-tenant hostile-workload boundary. A same-account job may access
resources available to that account. Submit only repositories and commands you
trust until opt-in isolated execution is released and proven.

The internal Linux dedicated-identity/cgroup-v2 mechanism has one native P1
mechanism test, but independent review identified additional escape, identity,
resource, and reconciliation proofs required before it can be enabled. The
preview therefore fails every configured hostile backend closed and publishes
no hostile scheduling capability. A Windows hostile-workload external guard is
not implemented; the native process-group backends are trusted-job lifecycle
cleanup, not hostile-workload guards.

## Authentication

- Controller/MCP: native loopback token boundary; no bearer token in renderer
  or MCP tool inputs.
- Worker channel: controller identity, enrollment/pairing, and TLS.
- SSH onboarding: strict host-key verification before password, native-agent,
  or local private-key authentication. Accepted remembered passwords use the
  Windows native credential vault. Private-key passphrases remain transient;
  the durable journal stores only a redacted, revalidated key-path policy.
- The three SSH authentication paths are implementation/fixture/CI verified,
  not yet live-server accepted across the declared Windows/Linux matrix.
- Non-Windows controller vault support remains tracked work; the supported
  preview controller is Windows.

## Release channels

- `preview`, `alpha`, `beta`, `rc`: GitHub prereleases, never stable claims.
- stable SemVer: blocked until production signing, full dependency/payload SBOM
  and notices, independent attestation verification, supported upgrade,
  Windows 11 profile acceptance, live two-worker E2E, governance, and all
  declared-scope issue gates pass. The prerelease release-asset SBOM and tagged
  provenance do not satisfy those broader GA gates.
