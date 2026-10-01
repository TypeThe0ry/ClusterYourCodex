# SSH Add Computer acceptance harness — 2026-10-01

The desktop provisioning path now has a reusable, opt-in live acceptance
harness. It is separate from the controller/worker round-trip fixtures: those
fixtures prove the runtime protocol after a worker exists, while this harness
proves the SSH onboarding path that creates that worker.

## Scope

The ignored test drives the native provisioning manager through one disposable
worker:

```text
Start → observe host key → exact fingerprint approval → SSH authentication
→ remote inventory → kit staging/install → enrollment → pairing
→ service/heartbeat → smoke check → Ready → owned cleanup
```

The harness uses the real `Ssh2Transport`, controller boundary, worker-kit
catalog, and provisioning state machine. It does not use the fake driver used
by the ordinary unit tests.

## Safety boundary

The test is disabled unless `CYC_PROVISIONING_E2E_CONFIG` points to a private
JSON file that explicitly opts into both live SSH and a disposable target. The
configuration schema rejects unknown fields, so passwords, tokens, private
keys, and other raw credential fields cannot be placed in the JSON. Password
and controller-token values are read only from separate private files. The
expected SSH `SHA256:` host-key fingerprint is mandatory and must match the
fingerprint observed before approval; the test never approves an unknown key.

Data, install, and report roots must be absolute, separate paths. The report
root is created or reused only when it contains the harness ownership marker.
Cleanup removes the provisioning record through the state machine using the
current revision and verifies that the record is gone. The report contains no
endpoint, username, password, token, host key, or raw remote error body.

The live path always requests session-only authentication. Windows Credential
Manager persistence remains available to the normal Windows desktop flow; on
controllers without a native persistent vault, the Add Computer UI now
disables password remembering and labels the operation as session-only rather
than allowing a late credential-store failure after SSH succeeds.

## Running it

Run the focused tests (the live case remains ignored):

```powershell
cargo test --manifest-path apps/desktop/src-tauri/Cargo.toml --lib provisioning -- --nocapture
```

For a real acceptance run, prepare the private config and secret files outside
the repository, then invoke the ignored test with the environment variable:

```powershell
$env:CYC_PROVISIONING_E2E_CONFIG = 'D:\validation\cyc-live-ssh\config.json'
cargo test --manifest-path apps/desktop/src-tauri/Cargo.toml --lib `
  provisioning::provisioning_e2e::live_ssh_provisioning -- --ignored --nocapture
```

The command must be run only against a disposable worker and a controller
whose token and worker-kit install roots are dedicated to that run. Do not put
the private config, secret files, or generated report under Git.

## Current evidence boundary

The harness and its configuration-guard tests are now in the repository. A
successful Windows↔Windows, Windows↔Linux, or Linux↔Linux runtime round trip
does not by itself count as SSH Add Computer evidence; the live harness must
also complete on the target controller/worker pair. Native macOS managed
runtime validation remains intentionally deferred by the current acceptance
priority, although the harness itself is portable and session-only.
