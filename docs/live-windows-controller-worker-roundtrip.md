# Live Windows controller/worker round-trip acceptance

`scripts/Test-WindowsControllerWorkerRoundTrip.ps1` exercises the managed
worker protocol on a Windows host using a disposable controller database,
TLS identity, pairing bundle, worker config, snapshot, workspace, and job.
It is designed for the hosted `windows-latest` CI runner and for an operator's
Windows checkout. The controller API stays on `127.0.0.1`; the worker TLS
listener uses an IPv4 address already assigned to the same host because the
controller rejects loopback and public worker binds.

This is a real same-host Windows protocol fixture. It is not evidence of a
clean Windows 11 VM, a two-machine fleet, production Authenticode signing, or
GUI/MCP acceptance. Those remain external Issue #2/GA gates.

## Preconditions

The host needs:

- Windows PowerShell 5.1 or PowerShell 7;
- `cargo` and the workspace lockfile, unless all three binaries are supplied;
- a Windows `cyc.exe`, `cyc-controller.exe`, and `cyc-worker.exe` built from
  the reviewed checkout (the script can build debug binaries when paths are
  omitted); and
- one assigned RFC1918 IPv4 address in `10/8`, `172.16/12`, or `192.168/16`.

The probe discovers the address through `Get-NetIPAddress` and allocates two
ephemeral ports immediately before launch. It never guesses an address,
uses loopback as a worker address, or reuses the installed controller data
directory.

## Commands

Run the parser and shell-only checks first:

```powershell
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
  (Resolve-Path .\scripts\Test-WindowsControllerWorkerRoundTrip.ps1),
  [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count) { $errors | ForEach-Object Message; throw 'PowerShell parse failed' }
pwsh -NoLogo -NoProfile -NonInteractive `
  -File .\scripts\Test-WindowsControllerWorkerRoundTrip.ps1 -SelfTest
```

Run with workspace-built debug binaries:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive `
  -File .\scripts\Test-WindowsControllerWorkerRoundTrip.ps1 `
  -RepositoryRoot $PWD `
  -WorkRoot $env:TEMP `
  -TimeoutSeconds 180 `
  -KeepEvidence
```

The CI invocation builds locked release binaries once and passes their direct
paths explicitly:

```powershell
cargo build --locked --release -p cyc-cli -p cyc-controller -p cyc-worker
pwsh -NoLogo -NoProfile -NonInteractive `
  -File .\scripts\Test-WindowsControllerWorkerRoundTrip.ps1 `
  -RepositoryRoot $PWD `
  -WorkRoot $env:RUNNER_TEMP `
  -CycBin (Join-Path $PWD 'target\release\cyc.exe') `
  -ControllerBin (Join-Path $PWD 'target\release\cyc-controller.exe') `
  -WorkerBin (Join-Path $PWD 'target\release\cyc-worker.exe') `
  -KeepEvidence
```

The same probe runs in the tagged `rust-artifacts` Windows x64 job in
`.github/workflows/release.yml`, using that matrix target's release binaries.
Both CI and tagged runs upload `manifest.json`, `result.json`, sanitized
evidence, and daemon logs as short-retention artifacts. This adds a real
hosted Windows protocol signal to preview candidates while preserving the
workflow's existing prerelease semantics; it does not turn the hosted runner
into the separate clean-profile or production-signing gate.

When `-KeepEvidence` is set, the script removes the token, private key,
enrollment bundle, and worker credential before retaining the sanitized job
root. On a pass without that switch, it removes the uniquely named disposable
root after the process and secret scans. A failed run retains sanitized logs
and JSON for diagnosis; an incomplete cleanup changes the exit code to
failure.

## Acceptance checks

The result and evidence record:

1. controller health on loopback and an exact self-signed TLS identity for the
   assigned worker address;
2. one-time pairing, matching pairing/node IDs, and protected worker config/
   credential files inside the job-owned worker directory;
3. a fresh online node report from the running worker;
4. immutable snapshot pack/upload/status, a PowerShell job submitted through
   the controller, a claim bound to the paired node, and a run lasting at
   least six seconds so the five-second heartbeat window is exercised;
5. controller-delivered stdout/stderr and an exact-byte `result.txt` artifact;
6. a `removed` cleanup receipt with matching job/run IDs, terminal success
   acknowledgement, and no remaining worker job root;
7. controller trace routes for pair, pair acknowledgement, node report, claim,
   heartbeat, complete, and cleanup; and
8. daemon process termination, direct-file checks, and a secret/credential
   marker scan before disposable secret material is removed.

The probe never passes a bearer value as a process argument. CLI commands use
`--token-file`; the cleanup request reads the token only into an in-memory HTTP
header. Route logs and evidence are scanned for token values, private-key PEM,
pairing-code fields, and worker credential markers.

## Evidence boundary

`result.json` labels the output `same-host Windows live fixture; not clean-VM,
production-signing, or cross-machine evidence`. A passing CI run proves the
Windows binaries can complete this protocol round trip on that hosted runner.
It does not close the Issue #2 `cleanWindows11Vm`, production signing,
cross-machine Windows/Linux, GUI/MCP, or stable-release gates.
