# Roadmap and release gates

Status vocabulary:

- **implemented**: production code exists;
- **CI verified**: repository workflow exercises it;
- **live acceptance pending**: real clean machine/hardware evidence remains;
- **preview blocker**: required before the next advertised preview scope;
- **GA blocker**: prereleases may continue, stable may not ship;
- **deferred**: outside the declared `0.1.0` scope.

## Milestone 0: executable architecture

| Capability | Status |
|---|---|
| Versioned protocol/schema | implemented, CI verified |
| Explainable compatibility and placement | implemented, CI verified |
| Loopback controller API and persistent jobs | implemented, CI verified |
| Capability probe and diagnostics CLI | implemented, CI verified |
| Codex Skill and MCP bridge | implemented, CI verified |
| Desktop dashboard | implemented, CI verified |

## Milestone 1: Windows prerelease

| Capability | Status |
|---|---|
| Self-contained Setup, Repair, Uninstall | implemented, CI/fresh-deployment verified; clean Windows 11 ARM64 x64-emulation workflow added, full standard/admin/non-ASCII acceptance evidence pending |
| Managed worker pairing/identity | implemented, CI verified; live two-machine acceptance pending |
| Password SSH import and host-key approval | implemented, CI verified; live GUI acceptance pending |
| SSH key/agent authentication | implemented, CI verified; live server acceptance pending |
| Git/snapshot source and artifact round trip | implemented, CI verified; live cross-node acceptance pending |
| Job-owned lifecycle/cancellation/cleanup | implemented for trusted jobs; live cancellation evidence pending |
| Additive Codex integration/rollback | implemented, CI verified; rollback fault hardening active |
| Tray and single-instance desktop | implemented; packaged interactive acceptance pending |
| Product version/tag identity | preview gate active |

## Milestone 2: heterogeneous beta

| Capability | Status |
|---|---|
| Linux x64/aarch64 Worker Kits + systemd | implemented/CI verified; arm64 hardware acceptance pending |
| macOS x64/arm64 portable archives + signed Worker Kits | implemented and locally packaging-verified; tagged native-workflow evidence pending |
| macOS managed worker + LaunchAgent lifecycle | packaged; `runtimeGated=true`, containment/live acceptance blocker for issue #3 |
| Resource leases/session isolation | implemented for trusted single-user scheduling |
| Hostile-workload isolation | Linux mechanism passed a native P1 test, but audited escape/identity/resource/reconciliation gates and Windows/macOS native guards remain issue #5 blockers; all production hostile tiers are unavailable and multi-tenant claims are forbidden |
| GPU/container/cache-aware scheduling | partial; expand after base live E2E |
| Supported upgrade/downgrade channel | GA blocker |

## Milestone 3: stable public release

| Gate | Status |
|---|---|
| Production Authenticode / macOS signing as applicable | GA blocker |
| Release-asset SBOM + tagged provenance | prerelease workflow implemented; full dependency/payload SBOM, notices, and independent verification remain GA blockers |
| Protected branch/tag/environment governance | prerelease `production-signing` and `production` environments require review, disable administrator bypass, wait, and accept only `v*` tags; a separate protected stable branch/tag workflow remains a GA blocker |
| Clean Windows 11 standard/admin/profile matrix | GA blocker |
| Signed `N-1 -> N` migration and rollback | GA blocker |
| Windows-controller -> Windows/Linux-worker live GUI/MCP E2E | GA blocker |
| Localization/accessibility/guided diagnostics | GA blocker |
| Compatibility/support/release documentation | in progress |
| Stable product release | blocked until all applicable GA gates pass |

See `RELEASE.md` for the executable checklist and
`docs/release-process.md` for prerelease/stable policy.
