# Core usability smoke — 2026-09-07

This record follows the active delivery goal: prove the shortest usable path
before spending time on non-blocking defect cleanup, visual polish, or PR
churn. It is source-bound to the current checkout and contains no credentials.

## Candidate and runtime

- Repository checkout: `D:\Projects\ClusterYourCodex\ClusterYourCodex`
- Product candidate: `0.1.0-preview.91`
- Published tag: `v0.1.0-preview.91`
- Published channel: GitHub public prerelease (`isPrerelease=true`,
  `isDraft=false`)
- Local controller health: HTTP 200, API `cyc.dev/v1`, database `ok`
- Native desktop host: packaged Windows preview launched and remained
  responsive as `ClusterYourCodex.exe`

## Core checks

| Check | Result | Evidence |
| --- | --- | --- |
| Desktop renderer tests | passed | `pnpm --filter @clusteryourcodex/desktop test` — 5 files, 96 tests |
| Desktop renderer build | passed | `pnpm --filter @clusteryourcodex/desktop build` |
| Native desktop host compile | passed | `pnpm --filter @clusteryourcodex/desktop native:check` |
| Native bridge/provisioning tests | passed | `cargo test --locked --manifest-path apps/desktop/src-tauri/Cargo.toml` — 78 passed, 0 failed |
| Credential vault round-trip | passed | `cyc-secrets` Windows Credential Manager test — 1 passed |
| Provisioning state machine | passed | `cyc-provision` state-machine suite — 25 passed |
| SSH transport | passed | `cyc-ssh` suite — 13 passed |
| Real Windows worker run | passed | [Helio preview.91 round-trip](live-windows-preview91-helio-roundtrip.md) |
| Real Linux worker run | passed | [P1 preview.91 round-trip](live-linux-preview91-p1-roundtrip.md) |
| Chrome preview navigation/locales | passed | Home, Computers, Add Computer modal, English, Simplified Chinese, Spanish, and Japanese were inspected in the local preview |

## Explicit boundary

The Vite page at `http://127.0.0.1:1420/` is a renderer preview. It does not
contain the Tauri secure provisioning bridge, so pressing Add Computer there
must show the localized `bridge_unavailable` state rather than pretending to
save an SSH password in a browser. Actual SSH credential storage, host-key
approval, worker installation, and pairing belong to the packaged native
desktop host.

The two real worker round-trips prove the controller/worker execution path,
including pairing, scheduling, logs, artifacts, exit status, and cleanup. They
do not by themselves close the remaining native GUI Add Computer and clean-VM
acceptance gates. Stable GA remains blocked; future public builds stay
prereleases until those gates are independently satisfied.

## Next highest-value action

Use the packaged preview desktop host for one operator-driven Add Computer
session against a reachable Windows or Linux worker. Preserve the resulting
host-key, credential-vault, install, pairing, heartbeat, smoke, and cleanup
receipt. Non-blocking UI wording and follow-up defects go to the feedback
backlog after this path is usable.
