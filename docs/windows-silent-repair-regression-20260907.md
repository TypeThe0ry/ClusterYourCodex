# Windows silent Setup Repair regression

This record is bound to the current source checkout and is kept separate from
the public-release status. It documents why `v0.1.0-preview.96` was not
published and what `preview.97` changes.

## Observed failure

The immutable `v0.1.0-preview.96` tag workflow was run as
[GitHub Actions run 34070273617](https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/34070273617).
The Windows x64 portable job passed. The self-contained job passed toolchain,
Rust, desktop, install, worker-kit, archive, and fresh-deployment checks, but
the disposable silent-Setup step was canceled at its 900-second bound while
running the second `Repair` invocation. The run conclusion was `cancelled`, so
no `preview.96` GitHub Release was created.

The retained diagnostics showed this deterministic sequence:

1. silent Install completed and wrote a succeeded lifecycle receipt;
2. the first Repair completed and its controller/worker probes passed;
3. the second Repair child remained alive until the outer bounded runner was
   canceled at the deadline.

This was a lifecycle-process failure, not a Rust compile failure or a reason to
mark the prerelease green by assertion.

## Source fix in preview.97

`packaging/windows/bootstrap.ps1` now:

- runs Codex marketplace/plugin add/remove through the bounded native process
  runner, including child-tree termination on timeout;
- checks the exact active plugin receipt before registering it again, making a
  repeated Repair idempotent and avoiding an unbounded duplicate CLI call;
- passes the normal bootstrap action timeout through the Codex lifecycle.

`packaging/windows/Test-SetupSilent.ps1` now writes an atomic
`<label>.progress.json` heartbeat every five seconds. The receipt includes the
stage label, deadline, process evidence, child-process tree, visible PowerShell
PID (when observed), and final exit state. This keeps in-flight evidence when a
hosted runner cancels a bounded process before stdout/stderr are flushed.

## Release rule

`v0.1.0-preview.97` remains a prerelease candidate until its tagged workflow
passes the repeated Repair and uninstall gates. Stable GA is still separately
blocked by the real Windows, macOS, and hostile-isolation acceptance gates; this
fix does not waive those gates.
