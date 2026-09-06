# Core usability smoke — 2026-09-07

This record follows the active delivery goal: prove the shortest usable path
before spending time on non-blocking defect cleanup, visual polish, or PR
churn. It is source-bound to the current checkout and contains no credentials.

## Candidate and runtime

- Repository checkout: `D:\Projects\ClusterYourCodex\ClusterYourCodex`
- Product candidate: `0.1.0-preview.94` (local source candidate)
- Published tag: `v0.1.0-preview.91` remains the last immutable public baseline
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

## Core-path blockers found and corrected after the smoke

The first native Add Computer attempt against Helio reached
`host_key_pending` and inventory successfully, then stopped at `kit_staged`
with the generic `WORKER_LIFECYCLE_FAILED` code. A direct transport probe
captured the real cause: the Windows PowerShell command renderer array-splatted
`-Action` as a literal positional value, so `Install-Worker.ps1` rejected it
before any worker mutation. The renderer now uses an explicit named-parameter
hashtable; the same Helio installer invocation returns the expected
`succeeded=true`, `paired=false`, `serviceEnabled=false` receipt.

The packaged WebView2 host exposed the second blocker: its URL credential
properties are `undefined` rather than empty strings, so the old origin gate
returned before defining `window.__CLUSTER_YOUR_CODEX__`. The bridge now accepts
both WebView2 and Chromium empty-credential forms while retaining the existing
protocol, host, and port checks. The native source build and bridge regression
test pass; the next public preview must carry this build before claiming the
GUI Add Computer path is ready.

The Windows controller dependency also opts into the OpenSSL-backed libssh2
backend so modern Linux workers with curve25519/ECDH-only KEX offers remain
reachable. Local source tests pass; the Windows CI runner is the authoritative
build check for the vendored OpenSSL toolchain.

The next source-bound blocker was found by running the current Windows live
round-trip probe rather than stopping at unit tests: the worker's rustls client
negotiated HTTP/2 with the controller, but the shared reqwest dependency had
HTTP/2 disabled, which made hyper-util panic before pairing. Preview.94 enables
reqwest's `http2` feature. Rebuilding both binaries and rerunning the probe
then passed pairing, node report, snapshot transfer, queued → running →
succeeded, heartbeat, logs, artifact verification, cleanup, and process
reaping; the retained acceptance marker is
`windows controller/worker live round-trip passed`.

## Next highest-value action

Use the packaged preview desktop host for one operator-driven Add Computer
session against a reachable Windows or Linux worker. Preserve the resulting
host-key, credential-vault, install, pairing, heartbeat, smoke, and cleanup
receipt. Non-blocking UI wording and follow-up defects go to the feedback
backlog after this path is usable.
