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

## Milestone 0.5: core usability first (active goal)

This milestone is the current delivery priority. It deliberately values a
working end-to-end path over polishing non-blocking defects or splitting
additional pull requests. Once the exit criteria below are met on the
packaged desktop host, new UI wording and edge-case issues move to the user
feedback backlog and are handled in priority order.

| Capability | Status |
|---|---|
| Add Computer form and host-key approval | implemented; renderer and native bridge tests pass, packaged-host acceptance remains the final operator check |
| SSH password retention through the native boundary | implemented; Windows Credential Manager round-trip passes; secrets stay out of renderer/controller logs |
| Worker install, pairing, heartbeat, and smoke check | implemented; Windows preview.95 local path and Helio/P1 evidence are retained |
| Typed job placement and dynamic capacity selection | implemented; controller selects from current telemetry and reservations |
| Result, log, artifact, exit-code, and cleanup return | implemented; Windows preview.95 round-trip passed `queued → running → succeeded` with verification evidence |
| Controller/worker platform boundary | Windows and Linux trusted-worker paths are usable; macOS kits are packaged but managed runtime remains explicitly gated |

**Exit criteria:** a packaged Windows desktop session can add one reachable
computer, retain its credential in the native vault, complete install/pair,
submit a meaningful build or test, and show the verified result and logs. The
current public candidate for this check is
[`v0.1.0-preview.100`](https://github.com/TypeThe0ry/ClusterYourCodex/releases/tag/v0.1.0-preview.100).

**Following goal:** after the core path is exercised, collect user feedback
from the same build, record each reproducible issue with environment and
evidence, and only then spend time on non-blocking UI polish and edge cases.

## Milestone 1: Windows prerelease

| Capability | Status |
|---|---|
| Self-contained Setup, Repair, Uninstall | implemented, CI/fresh-deployment verified; preview.75 passed the hosted Windows 11 ARM64 x64-emulation profile matrix for standard/admin × ASCII/non-ASCII profiles (all four cases exitCode=0); preview.76 carries the native selector guard and same-host Windows controller/worker live round-trip probe; native Windows x64 clean-profile, clean-VM, lifecycle, and live cross-machine acceptance remain pending |
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
| macOS managed worker + LaunchAgent lifecycle | native process-group backend implemented; package remains `runtimeGated=true` until live LaunchAgent acceptance for issue #3 |
| Resource leases/session isolation | implemented for trusted single-user scheduling |
| Hostile-workload isolation | Linux mechanism passed a native P1 test, but audited escape/identity/resource/reconciliation gates and Windows/macOS native guards remain issue #5 blockers; all production hostile tiers are unavailable and multi-tenant claims are forbidden |
| GPU/container/cache-aware scheduling | partial; expand after base live E2E |
| Supported upgrade/downgrade channel | GA blocker |

## Milestone 3: stable public release

| Gate | Status |
|---|---|
| Production Authenticode / macOS signing as applicable | GA blocker |
| Release-asset SBOM + tagged provenance | prerelease workflow implemented; full dependency/payload SBOM, notices, and independent verification remain GA blockers |
| Protected branch/tag/environment governance | `production-signing` and stable `production` environments require review, disable administrator bypass, wait, and accept only `v*` tags; prerelease publication uses a separate `preview-publication` environment and remains `prerelease: true`; a protected stable branch/tag workflow remains a GA blocker |
| Clean Windows 11 standard/admin/profile matrix | preview.75 hosted ARM64 x64-emulation matrix passed; preview.76 repeats the acceptance with the selector guard and Windows live round-trip probe; independent external clean-VM GA evidence remains a GA blocker |
| Signed `N-1 -> N` migration and rollback | GA blocker |
| Windows-controller -> Windows/Linux-worker live GUI/MCP E2E | GA blocker |
| Localization/accessibility/guided diagnostics | GA blocker |
| Compatibility/support/release documentation | in progress |
| Stable product release | blocked until all applicable GA gates pass |

See `RELEASE.md` for the executable checklist and
`docs/release-process.md` for prerelease/stable policy.
