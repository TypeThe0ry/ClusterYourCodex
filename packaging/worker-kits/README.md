# Managed Worker kits

Worker kits are publisher-signed, integrity-checked payloads uploaded by the native desktop
provisioner after SSH host-key verification and authentication. The current
release contract uses an Ed25519 detached signature over the canonical
`worker-kit.json` bytes and binds every kit file into `SHA256SUMS` and the
parent release manifest. The controller pins the audited public key from
`crates/cyc-provision/publisher_keys/cyc-release-2026-01.pub` and verifies the
signature before staging any byte. SSH is only
the bootstrap, repair, update, and removal transport; normal jobs use the
managed worker protocol.

The kit never contains an SSH password, controller token, pairing code, worker
credential, or private key. A short-lived enrollment document is created only
after the kit has been staged and verified, transferred separately with private
permissions, consumed once, and deleted.

## Build a kit

```powershell
./packaging/worker-kits/New-WorkerKit.ps1 `
  -Target windows-x86_64 `
  -WorkerExecutable ./target/release/cyc-worker.exe `
  -SigningKeyPath C:/private/cyc-release-2026-01.pem `
  -OutputDirectory ./artifacts/worker-windows-x86_64

./packaging/worker-kits/New-WorkerKit.ps1 `
  -Target linux-x86_64 `
  -WorkerExecutable ./artifacts/linux-x86_64/cyc-worker `
  -SigningKeyPath C:/private/cyc-release-2026-01.pem `
  -OutputDirectory ./artifacts/worker-linux-x86_64
```

The signing key must be an Ed25519 PKCS#8 PEM matching the pinned public key;
missing, malformed, foreign, or mismatched keys fail closed. Every output
contains exactly `worker-kit.json`, `worker-kit.sig`, `SHA256SUMS`, one worker
executable, and the platform lifecycle script. The release pipeline binds the
complete kit into its parent release manifest.

The remote lifecycle does not depend on an OpenSSL installation. Controller
loads the exact five local files, verifies the Ed25519 signature and manifest
payload digests, then uploads only those verified in-memory bytes over the
host-key-pinned SSH session and reads each byte sequence back to verify its
SHA-256. The remote lifecycle requires the exact five-file set, rechecks the
four `SHA256SUMS` entries, validates the canonical signature envelope, pinned
key id, signature encoding, and manifest digest binding before installation.
Thus remote verification is explicitly the transport continuation of the
controller's publisher verification, not a claim that PowerShell 5.1 or Bash
performs Ed25519 cryptography itself.

## Publisher key provisioning and rotation

Production releases require repository secret
`CYC_WORKER_KIT_SIGNING_KEY_PEM_B64`, containing Base64 of the complete private
PKCS#8 PEM. The release workflow fails rather than emitting an unsigned kit
when the secret is absent or invalid, materializes it only as a bounded
runner-private temporary file, and deletes that file after kit construction.
The private key must never be committed.

Generate a new pair with `openssl genpkey -algorithm ED25519 -out <private.pem>`.
Derive the SPKI public key with
`openssl pkey -in <private.pem> -pubout -outform DER -out <public.der>`, write
the final 32 DER bytes as standard padded Base64 plus LF to the pinned `.pub`
file, review and commit that public-key change, then set the GitHub secret from
Base64 of the PEM via standard input. A rotation changes both the key id in
code/scripts and the pinned public file atomically; previously signed kits are
rejected unless their old public key remains explicitly trusted.

PowerShell rotation skeleton (it never prints the private key):

```powershell
$private = 'C:\private\cyc-release-2026-01.pem'
$der = Join-Path $env:TEMP 'cyc-release-2026-01-public.der'
$public = 'crates\cyc-provision\publisher_keys\cyc-release-2026-01.pub'
openssl genpkey -algorithm ED25519 -out $private
openssl pkey -in $private -pubout -outform DER -out $der
$bytes = [IO.File]::ReadAllBytes($der)
if ($bytes.Length -ne 44) { throw 'unexpected Ed25519 SPKI encoding' }
[IO.File]::WriteAllText(
  $public,
  [Convert]::ToBase64String([byte[]]$bytes[12..43]) + "`n",
  [Text.UTF8Encoding]::new($false)
)
[Convert]::ToBase64String([IO.File]::ReadAllBytes($private)) |
  gh secret set CYC_WORKER_KIT_SIGNING_KEY_PEM_B64
[IO.File]::Delete($der)
```

Review/commit only the `.pub` file. Keep `$private` offline after the repository
secret is set.

## Remote lifecycle

Windows:

```powershell
# Phase 1: integrity-check and atomically preinstall; no service starts yet.
./Install-Worker.ps1 -Action Install -WorkspaceRoot C:/CodexWorker
# Phase 2: consume the one-time enrollment without racing service startup.
./Install-Worker.ps1 -Action Repair -WorkspaceRoot C:/CodexWorker `
  -EnrollmentFile C:/private/enrollment.json -PairOnly
# Phase 3: enable the already-paired service.
./Install-Worker.ps1 -Action Repair -WorkspaceRoot C:/CodexWorker
./Install-Worker.ps1 -Action Uninstall
```

Linux:

```bash
./install-worker.sh install --workspace-root /srv/codex-worker
./install-worker.sh repair --workspace-root /srv/codex-worker \
  --enrollment /private/enrollment.json --pair-only
./install-worker.sh repair --workspace-root /srv/codex-worker
./install-worker.sh uninstall
```

For a non-root invocation, `--scope auto` selects a user systemd unit. Before
the service phase mutates the worker, config, manifest, or unit, the installer
requires `loginctl` to report linger enabled (enabling it for the current user
when permitted) and requires `systemctl --user show-environment` to reach the
user manager. If the bus probe fails after this invocation enabled linger, it
restores the prior non-lingering state. If either prerequisite is unavailable,
it exits with code `78`
and `[CYC-LINUX-USER-SYSTEMD-UNAVAILABLE]`; rerun as root with
`--scope system`. Root `--scope auto` selects the system unit and does not
probe or alter a user manager. The unpaired preinstall and `--pair-only`
phases remain service-independent.

The enrollment-free first phase returns `paired:false` and intentionally does
not create/start a service. This preserves the state contract that Controller
issues the ten-minute one-time enrollment only after the exact Worker Kit has
been installed. The second phase consumes and deletes the enrollment, writes
the protected worker config with the selected absolute workspace, and remains
service-off. The third phase validates that config and enables the service.

A routine repair of a Ready node does **not** receive an enrollment document:
it keeps the existing node identity and credential, swaps the worker binary
and service definition transactionally, runs `status` plus a service-running
smoke check, then commits the new manifest. Credential recovery is an
explicit, separate same-node re-enrollment and automatically uses the worker's
guarded `--repair` path while preserving the exact workspace.

Install and repair maintain a private crash-recovery journal containing opaque
copies of the old config/credential files, install manifest, worker binary,
service/task definition, and prior enabled/running state. Credential bytes are
copied without being decoded or logged. The journal is committed and removed
only after pairing (when explicitly requested), config health, service
registration/start, the running smoke check, and atomic manifest replacement
all succeed. A caught failure restores the old bytes and service state before
returning; an interrupted invocation is recovered at the start of the next
lifecycle call. Install and repair are idempotent. Uninstall removes only
manifest-owned
binaries and service definitions; paired data and workspaces are preserved by
default. Purging data is a separate explicit operation and is limited to the
installer's default owned data root.
