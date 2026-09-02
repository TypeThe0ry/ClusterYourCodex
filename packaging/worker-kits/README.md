# Managed Worker kits

Worker kits are publisher-signed, integrity-checked payloads uploaded by the native desktop
provisioner after SSH host-key verification and authentication. The current
release contract uses an Ed25519 detached signature over the canonical
`worker-kit.json` bytes and binds every kit file into `SHA256SUMS` and the
parent release manifest. The controller pins the audited public key from
`crates/cyc-provision/publisher_keys/cyc-release-2026-02.pub` and verifies the
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
  -SigningKeyPath C:/private/cyc-release-2026-02.pem `
  -OutputDirectory ./artifacts/worker-windows-x86_64

./packaging/worker-kits/New-WorkerKit.ps1 `
  -Target linux-x86_64 `
  -WorkerExecutable ./artifacts/linux-x86_64/cyc-worker `
  -SigningKeyPath C:/private/cyc-release-2026-02.pem `
  -OutputDirectory ./artifacts/worker-linux-x86_64

./packaging/worker-kits/New-WorkerKit.ps1 `
  -Target macos-x86_64 `
  -WorkerExecutable ./artifacts/macos-x86_64/cyc-worker `
  -SigningKeyPath C:/private/cyc-release-2026-02.pem `
  -OutputDirectory ./artifacts/worker-macos-x86_64

./packaging/worker-kits/New-WorkerKit.ps1 `
  -Target macos-aarch64 `
  -WorkerExecutable ./artifacts/macos-aarch64/cyc-worker `
  -SigningKeyPath C:/private/cyc-release-2026-02.pem `
  -OutputDirectory ./artifacts/worker-macos-aarch64
```

The signing key must be an Ed25519 PKCS#8 PEM matching the pinned public key;
missing, malformed, foreign, or mismatched keys fail closed. Every output
contains exactly `worker-kit.json`, `worker-kit.sig`, `SHA256SUMS`, one worker
executable, and the platform lifecycle script. The release pipeline binds the
complete kit into its parent release manifest.

When `-Version` is omitted, the builder reads the repository-root `VERSION`
file. That file must be a bounded, normal UTF-8 file containing exactly one
LF-terminated SemVer-compatible value; missing or malformed version identity
fails closed. An explicit `-Version` remains available to isolated fixtures.

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

Production releases require the `production-signing` environment secret
`CYC_WORKER_KIT_SIGNING_KEY_PEM_B64`, containing Base64 of the complete private
PKCS#8 PEM. The release workflow fails rather than emitting an unsigned kit
when the secret is absent or invalid, materializes it only as a bounded
runner-private temporary file with verified mode `0600` on Unix or a protected
runner-SID/SYSTEM DACL on Windows, and deletes that file after kit construction.
The environment requires a reviewer, disables administrator bypass, and
accepts only `v*` tag deployments; manual runs from branches fail closed before
any signing job. The private key must never be committed or stored as a
repository-level secret.

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
$private = 'C:\private\cyc-release-2026-02.pem'
$der = Join-Path $env:TEMP 'cyc-release-2026-02-public.der'
$public = 'crates\cyc-provision\publisher_keys\cyc-release-2026-02.pub'
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
  gh secret set CYC_WORKER_KIT_SIGNING_KEY_PEM_B64 --env production-signing
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

macOS preview package:

```bash
# Phase 1 is safe: exact-kit verification plus dormant preinstall.
./install-worker.sh install \
  --workspace-root "$HOME/Library/Application Support/ClusterYourCodex/Worker/Data/workspace"

# Phase 2 is safe: consume enrollment and validate config, but stay dormant.
./install-worker.sh repair \
  --workspace-root "$HOME/Library/Application Support/ClusterYourCodex/Worker/Data/workspace" \
  --enrollment /private/enrollment.json --pair-only

# Phase 3 is intentionally gated in prerelease packages. It exits 78 and does
# not mutate the paired installation or start cyc-worker.
./install-worker.sh repair

# Removes owned executable/LaunchAgent material while preserving paired data,
# workspace, and logs by default. It is safe to repeat.
./install-worker.sh uninstall
```

The macOS package is generated for both `macos-x86_64` and
`macos-aarch64`, but **macOS runtime support is not claimed yet**. Native worker
containment and a live macOS lifecycle test are release gates. Until both are
complete, the lifecycle has a non-overridable
`MACOS_WORKER_CONTAINMENT_READY=0` packaging gate. Any invocation that would
bootstrap or start the LaunchAgent fails before worker, config, manifest, or
LaunchAgent mutation with exit code `78` and the machine-readable diagnostic:

```text
[CYC-MACOS-WORKER-CONTAINMENT-UNAVAILABLE]
```

Safe enrollment-free preinstall, integrity verification, `--pair-only`,
status validation, uninstall, and rollback remain available. The macOS
lifecycle re-verifies the exact five-file package and its canonical Ed25519
signature before preinstall or pairing; this preview implementation requires
Python 3.8+ for that pure-software verifier and fails closed with
`[CYC-MACOS-PYTHON-REQUIRED]` when it is unavailable.

The current-user LaunchAgent foundation is
`~/Library/LaunchAgents/dev.clusteryourcodex.worker.plist`. Its future enabled
state uses `launchctl bootstrap`, `kickstart`, `print`, and `bootout`; program
data and workspace live below
`~/Library/Application Support/ClusterYourCodex/Worker`, while stdout/stderr
logs live below `~/Library/Logs/ClusterYourCodex/Worker`. System scope is
rejected with exit code `78` and
`[CYC-MACOS-LAUNCHAGENT-USER-SCOPE-REQUIRED]`. The plist/start wrapper exists
so the post-containment lifecycle does not require a product fork, but the
hard gate makes it unreachable in current prereleases.

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
lifecycle call. Journal retirement is itself crash-safe: the journal is moved
atomically to a private, schema/installer-UID-bound retirement path before
recursive deletion, and a first-install rollback publishes a sidecar tombstone
until both the journal and ownership markers have been consumed. Re-entry can
therefore finish an interrupted marker/journal cleanup without treating a
partial first install as an owned installation. Install and repair are
idempotent.

### Lifecycle path binding

After the ownership marker and `install-manifest.json` exist, the manifest is
the authoritative binding for lifecycle cleanup and repair. Linux requires the
invocation's normalized `installRoot`, `dataRoot`, and `workspaceRoot` to match
the recorded roots before it can recover a transaction, stop/remove a systemd
unit, remove the worker, or write a replacement. The macOS preview applies the
same check to those roots plus `logsRoot` and the HOME-derived `launchAgent`
path. A mismatch fails before any service/LaunchAgent operation or worker,
config, manifest, log, or workspace mutation, so a same-named path elsewhere
cannot be mistaken for the owned installation.

The ownership marker is not sufficient authority by itself: if it remains but
the manifest is missing or unsafe, lifecycle operations fail closed before
touching the worker or service layer unless an uncommitted crash-recovery
journal is present to restore the authoritative state. The journal records
whether the marker predated the transaction, so a failed first install does
not leave a new marker that can authorize later cleanup. During first-install
rollback, `.repair-transaction.tombstone` and the private
`.repair-transaction.removing` retirement path are validated before any
cleanup; malformed, symlinked, mismatched, or foreign state remains fail
closed. Linux systemd units also set `KillMode=control-group` explicitly so
stopping or removing the unit terminates every process still in that unit's
cgroup. The gated macOS
LaunchAgent plist carries the corresponding explicit
`AbandonProcessGroup=false` contract; live LaunchAgent teardown remains an
external acceptance gate.

Treat a root change as an explicit migration or new installation, not as a
repair/uninstall override. Existing paired data and workspaces are preserved by
default; explicit data purge remains separately constrained to the installer
owned default roots.

Uninstall removes only manifest-owned
binaries and service definitions; paired data and workspaces are preserved by
default. Purging data is a separate explicit operation and is limited to the
installer's default owned data root.
