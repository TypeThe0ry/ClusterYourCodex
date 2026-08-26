# Managed worker execution contract

Status: execution contract for the Windows-first developer preview. Windows,
Linux, and macOS preview archives contain the managed-worker binary or a signed
Worker Kit. Windows/Linux execution remains limited to trusted, single-user
jobs. The packaged macOS x64/arm64 Worker Kits are lifecycle artifacts only:
managed execution remains `runtimeGated=true`, `containmentReady=false`, and
`liveReady=false` until its process-containment and native acceptance gates
pass.

## Trust boundary

ClusterYourCodex is a single-user, user-owned-computer executor. A submitted
`JobSpec` contains native scripts and is therefore equivalent to code execution
under the worker account. It is not a multi-tenant sandbox.

The controller exposes two separate surfaces:

```text
127.0.0.1:47831   client API   GUI / CLI / Codex MCP
private LAN port  worker API   paired managed workers only
```

The client API stays loopback-only and uses the controller token. The worker
API exposes no fleet, submit, or administration routes. It requires TLS,
an enrollment-specific trust root, and a different per-node credential.
Neither token is accepted as a command-line argument or copied into a job
environment.

## Enrollment

1. An authenticated local client requests a one-time pairing bundle.
2. The pairing code has at least 128 bits of entropy, expires after ten minutes,
   and can be consumed once.
3. The enrollment bundle contains exactly one public certificate PEM. The
   worker builds an isolated TLS trust store from it, delegates HTTPS name,
   validity-time, signature, and chain checks to WebPKI, and additionally
   requires the server leaf certificate's DER SHA-256 to match that exact
   enrollment certificate before sending the code or probe. SPKI-based pinning
   and certificate-rotation support remain later hardening work.
4. The controller stores only a hash of the issued per-node credential.
5. The credential maps to one node ID server-side. A request body can never
   choose or impersonate a different node.

Long-lived credentials live in an ACL-restricted file on Windows and a `0600`
file inside a `0700` directory on Linux/macOS.

The standalone worker treats its enrollment bundle, config, credential,
config parent, and workspace as trust-root state. Existing inputs are
verify-only: Windows requires owner=current user, a protected exact allowlist
containing only that user and SYSTEM, and no reparse point in the full existing
path; Unix requires effective-uid ownership with directory mode `0700` and file
mode `0600`. A weak existing parent, file, or workspace is rejected without
repair. Missing config directories and workspaces are created exclusively and
made private before a probe or pairing request can cross the network. Config
and credential files use a fresh private temporary, file flush, atomic
no-replace publication, post-write verification, and Unix parent-directory
flush. `status` and `run` revalidate the persisted trust root before use.

The standalone controller applies the same fail-closed trust boundary to its
persistent state before SQLite opens it. An existing database, any `-wal`,
`-shm`, or `-journal` sidecar, and the sibling `jobs` object root must be
regular/non-reparse state owned by the current identity with the exact private
ACL (Windows: current user and SYSTEM only) or modes (Unix: directory `0700`,
file `0600`). A weak or prepositioned layout is rejected, not repaired and
trusted. For a new layout, the parent is protected first, the empty database
and object root are created exclusively, and SQLite-created sidecars are
post-hardened and verified before startup completes.

### Minimal private-LAN bring-up

The Windows installer produces one
`cyc.dev/windows-managed-worker-network/v1` plan before requesting elevation.
It considers only `Up` interfaces and source-eligible RFC1918 IPv4 or ULA IPv6
addresses. Selection is deterministic: default gateway, interface metric,
interface index, IPv4 before IPv6, then canonical address order. The plan
records the selected interface index, controller hostname, exact bind/public
host and port, every selected-interface private address, identity version, and
the exact SAN set. The SAN set is the canonical union of `127.0.0.1`, `::1`,
controller hostname, public host, and all selected private addresses.

The managed listener binds only the selected private address. It never binds a
wildcard, loopback, link-local, or public address. The firewall remains one
program-and-port-bound inbound TCP rule restricted to `Private` and
`LocalSubnet`. Readiness connects to the bind host but authenticates the public
host. Controller startup repeats the private-bind, public-IP equality, and
exact-port checks as defense in depth.

PlanOnly, firewall coordination, and the per-user core propagate the exact
typed plan; they do not independently rediscover an interface. Once installed,
Repair reuses the manifest plan exactly and fails closed on replacement,
missing current state, malformed arrays, or a different SAN set. The current
identity lives below the versioned `tls/managed-worker-v2` directory. A
complete legacy prerelease identity in the old `tls` root is left untouched
while a new identity is created; rollback removes only that new versioned
identity. A partial legacy pair is rejected.

The certificate SAN must exactly match the planned set and therefore includes
the host in `--worker-public-url`. The preview accepts an explicitly
provisioned, self-signed end-entity certificate; keep the private key in a
separate file. Controller startup rejects reparse points, requires the data/key
directories and private-file DACLs to be a protected exact allowlist for the
current user and SYSTEM, and will not repair-and-trust pre-existing token,
database, sidecar, or object-store state from a weak namespace. Use the current
user's data directory rather than an ad-hoc shared `ProgramData` path. A manual
IP-based Windows bring-up equivalent to the installer contract is:

```powershell
$Data = Join-Path $env:LOCALAPPDATA 'ClusterYourCodex'
function Set-CycPrivateAcl([string]$Path, [switch]$Directory) {
  $user = [Security.Principal.WindowsIdentity]::GetCurrent().User
  $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
  if ($Directory) {
    $item = [IO.DirectoryInfo]::new($Path)
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor `
                   [Security.AccessControl.InheritanceFlags]::ObjectInherit
  } else {
    $item = [IO.FileInfo]::new($Path)
    $acl = [Security.AccessControl.FileSecurity]::new()
    $inheritance = [Security.AccessControl.InheritanceFlags]::None
  }
  $acl.SetOwner($user)
  $acl.SetAccessRuleProtection($true, $false)
  foreach ($principal in @($user, $system)) {
    [void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
      $principal, [Security.AccessControl.FileSystemRights]::FullControl,
      $inheritance, [Security.AccessControl.PropagationFlags]::None,
      [Security.AccessControl.AccessControlType]::Allow))
  }
  if ($item.PSObject.Methods.Name -contains 'SetAccessControl') {
    $item.SetAccessControl($acl) # Windows PowerShell 5.1
  } else {
    [IO.FileSystemAclExtensions]::SetAccessControl($item, $acl) # PowerShell 7
  }
}

$LanAddress = '192.168.1.10' # assigned RFC1918 address on the selected interface
$ControllerHostName = [Net.Dns]::GetHostName().ToLowerInvariant()
$Tls = Join-Path $Data 'tls\managed-worker-v2'
New-Item -ItemType Directory -Force -Path $Data, $Tls | Out-Null
Set-CycPrivateAcl $Data -Directory
Set-CycPrivateAcl $Tls -Directory
.\cyc.exe identity init --output-dir $Tls `
  --host 127.0.0.1 `
  --host ::1 `
  --host $ControllerHostName `
  --host $LanAddress
Set-CycPrivateAcl "$Tls\controller.key.pem"
.\cyc.exe identity verify `
  --certificate "$Tls\controller.crt.pem" `
  --private-key "$Tls\controller.key.pem" `
  --host 127.0.0.1 `
  --host ::1 `
  --host $ControllerHostName `
  --host $LanAddress `
  --json

.\cyc-controller.exe `
  --bind 127.0.0.1:47831 `
  --database "$Data\controller.db" `
  --token-file "$Data\controller.token" `
  --worker-bind "${LanAddress}:47832" `
  --worker-public-url "https://${LanAddress}:47832" `
  --worker-cert "$Tls\controller.crt.pem" `
  --worker-key "$Tls\controller.key.pem"
```

In a second controller terminal, create a one-time file. The CLI writes only
the strict worker enrollment document; it prints non-secret pairing metadata
separately. Copy the file to the worker over an authenticated private-LAN
channel, consume it once, and delete it:

```powershell
$Data = Join-Path $env:LOCALAPPDATA 'ClusterYourCodex'
.\cyc.exe --token-file "$Data\controller.token" pair create `
  --output "$Data\pairing\enrollment.json"

# On the Windows worker, define Set-CycPrivateAcl exactly as above, then copy
# the enrollment document into this newly private directory before pairing:
$WorkerData = 'C:\ClusterYourCodex'
New-Item -ItemType Directory -Path $WorkerData | Out-Null
Set-CycPrivateAcl $WorkerData -Directory
# authenticated copy -> $WorkerData\enrollment.json
Set-CycPrivateAcl "$WorkerData\enrollment.json"
.\cyc-worker.exe pair --enrollment-file C:\ClusterYourCodex\enrollment.json `
  --config C:\ClusterYourCodex\worker.json `
  --workspace-root C:\CodexWorker
Remove-Item -LiteralPath C:\ClusterYourCodex\enrollment.json
.\cyc-worker.exe status --config C:\ClusterYourCodex\worker.json --pretty
.\cyc-worker.exe run --config C:\ClusterYourCodex\worker.json
```

On Linux, use `install -d -m 0700 <worker-data>` and
`install -m 0600 <received-enrollment> <worker-data>/enrollment.json` before
pairing; copying into an arbitrary shared directory and asking the worker to
repair it is intentionally rejected. The Linux worker must pass its
subreaper/descendant-containment startup gate before it polls for work. A Unix
controller likewise requires the TLS-key parent to be owned by its effective
uid with mode `0700`, the key to be a regular non-symlink file owned by that uid
with mode `0600`, and every component of the key/certificate path to be free of
symbolic links.

Repair preserves logical identity: create the replacement enrollment with
`cyc pair create --node-id <existing-node-id>`, stop the installed service,
and call `cyc-worker pair` with the same protected config and absolute
workspace plus `--repair`. The worker requires the same controller and intended
node ID, atomically rotates the local credential/config, and leaves the chosen
workspace unchanged unless the installer explicitly supplies that same path.

Pair and repair are one config-scoped local transaction. The worker takes the
stable `worker.pair.lock` with an exclusive Windows file handle or Unix
`flock` before it re-reads enrollment/config state, and holds that OS lock
through the pair request, config commit, acknowledgement, and garbage
collection. The protected lock inode is never unlinked, so two processes
cannot lock different replacement files; process exit releases the kernel
lock. A protected, atomically replaced `worker.pairing-state.json` records only
pairing/controller/node bindings, exact credential paths, SHA-256 digests,
times, state, and pending cleanup. It never stores credential plaintext.

Credential cleanup is fail-closed. Unknown or possibly accepted requests, the
current invocation, and the credential referenced by committed config remain
protected. Cleanup removes only a ledger-owned canonical direct child whose
regular-file protections and digest still match, after a definite terminal or
superseded result, or an ACK that authorizes removal of the previous repair
credential. A verification/removal failure leaves durable `cleanupPending`
state for retry. If an ACK response is lost after config commit, replay uses
the committed credential and ledger binding and completes the pending old-file
cleanup only after an affirmative ACK.

After a worker has paired and reported a fresh probe, the local client can
submit an exact Git object ID and retrieve evidence without exposing any
credential on the command line:

```powershell
.\cyc.exe --token-file "$Data\controller.token" plan --file .\job.json
.\cyc.exe --token-file "$Data\controller.token" submit --file .\job.json
.\cyc.exe --token-file "$Data\controller.token" jobs <job-id>
.\cyc.exe --token-file "$Data\controller.token" logs <job-id> `
  --stream stdout --output .\stdout.log
.\cyc.exe --token-file "$Data\controller.token" artifacts <job-id>
```

## Inventory and telemetry ordering

Inventory and telemetry are separate versioned documents. A daemon allocates
and durably commits a monotonically increasing `bootGeneration` before it
starts reporting. Each process also owns a random `bootId` and a monotonically
increasing `sequence`. The controller accepts reports in lexicographic order
by `(bootGeneration, bootId, sequence)`: a newer generation retires every
older process, while reports in one generation must retain the same boot ID
and advance the sequence. Generation zero is reserved for legacy workers; new
managed workers always report a positive value.

The public Fleet API, Desktop bridge, and MCP types expose `bootGeneration` as
a non-negative JSON integer alongside `bootId` and `sequence`. A controller
ACK echoes the accepted generation and sequence in bounded response headers.
Delayed reports from a retired process are rejected and cannot overwrite the
current resource snapshot. Inventory remains pending and is retransmitted
until its digest/revision receives an affirmative ACK.

`GET /v1/fleet` returns `fleetRevision` (bounded to the JavaScript exact-integer
range) and one controller `observedAt`. The revision, merged `nodes`, split
`nodeViews`, active reservations, and `recentJobs` are read from one SQLite WAL
read transaction. Concurrent controller writes can therefore appear wholly
before or wholly after a response, never as a three-query torn fleet view.
`fleetRevision` is the authoritative placement/capacity revision, not a count
of every heartbeat or job-document mutation; lease renewal alone does not make
an otherwise valid placement plan stale.

## Immutable placement authority

`POST /v1/plans` returns the shared
`cyc.dev/placement-plan-binding/v1` document directly. It binds `planId`, the
normalized `JobSpec` ID and canonical SHA-256, creation/expiry times, exact
JavaScript-safe fleet/node/policy revisions, and the selected node, score, and
complete original explanation. The controller does not maintain a second
private response shape.

Planned submission validates and consumes that exact binding in the same
SQLite `IMMEDIATE` transaction that stores the normalized job, run, dispatch
lease, and `plans.used_at`. Fresh telemetry may update `run.placement` only
when it still selects the binding's node; it never rewrites `planBinding` or
the original explanation. Submission without a caller-created plan generates
and consumes an equivalent controller-authored plan inside that transaction,
so every new managed job has immutable authority.

`POST /v1/jobs`, job GET/list, and fleet `recentJobs` always include the stored
`planBinding`. A JSON `null` is an explicit pre-binding legacy marker. Migration
backfills it only when exactly one validated used plan proves the canonical job
and current run node; missing, malformed, or ambiguous evidence remains null.
Database triggers reject new null bindings and mutation of a stored binding.
After an unclaimed dispatch expires, bound jobs may rearm only on the same node
even if another node later scores higher; an ineligible bound node leaves the
job waiting rather than silently changing authority. Legacy null rows retain
the prior re-selection behavior.

## Claim and lease

The initial preview uses one active slot per node and an exclusive GPU lease.
Claim is a single SQLite transaction:

```text
authenticate node
  -> select oldest compatible queued run for that node
  -> confirm node/resource lease and cancellation state
  -> CAS queued to preparing
  -> create a short run claim
  -> commit
```

No work returns `204 No Content` with bounded polling guidance. A successful
claim returns the immutable `JobSpec`, its canonical SHA-256 digest, run ID,
state version, job-owned relative workspace, upload limits, and lease deadline.
The claimed node must equal the stored placement binding's selected node.

Heartbeats renew both the run claim and resource lease. If a worker cannot
renew before the local deadline, it terminates the job-owned process tree.
Expired claims are failed atomically before resources are released; they are
never silently reallocated while the old process may still be running.

Managed terminal completion does not immediately release scheduler capacity.
The terminal transaction revokes the run claim, stores the exact completion
digest/ACK, and changes the same lease to durable `cleanup_pending` for 15
minutes. A cleanup obligation binds `jobId`, `runId`, `leaseId`, terminal state
version, final state, completion SHA-256, and acknowledgement time. Only an
immutable, exactly matching `removed` receipt permits capacity release, and
the receipt plus release commit in the same SQLite `IMMEDIATE` transaction.
Duplicate receipts are idempotent; a mismatched receipt is rejected, while
durable `not_created` evidence keeps capacity reserved.

If no `removed` receipt arrives before the durable deadline, the lease reaper
may release capacity only after re-reading and proving every terminal binding.
It records `releaseReason=deadline_recovery` plus bounded
`cleanupFailure.code=removed_receipt_deadline_exceeded`; cleanup phase remains
`pending` and `jobRootDeleted=false`. It never inserts or synthesizes a
`removed` receipt. These fields survive restart and keep Full Run fail-closed
even though scheduler capacity is eventually recovered. Historical databases
whose old controller already released a terminal lease are marked
`legacy_migration` with explicit failure evidence unless a matching removed
receipt was already durable.
If any terminal/job/run/lease/digest binding fails revalidation, the failure is
recorded but the expired `cleanup_pending` lease continues to count against CPU,
memory, disk, slot, and GPU capacity until an operator repairs the evidence or
an exact `removed` receipt resolves it.

Immediately after every successful claim, and before the claimed assignment
can poll `prepare_job` or spawn a Git/source/step process, the worker durably
creates `<worker-root>/.cyc-containment-quarantine.json`. The guard is installed
atomically, its file contents are flushed, and its parent directory is flushed
on Unix. Any existing path entry at that name is fail-closed, even if the entry
is truncated, malformed, or not a regular file. The daemon repeats this check
immediately before every claim rather than relying only on startup state.

The guard covers the complete assignment. It is removed only after every
source and step tree has been positively proven empty **and** the controller
returns a matching authoritative terminal acknowledgement. Removal is followed
by a parent-directory flush on Unix. A crash, `SIGKILL`, power loss, monitor
ambiguity, transition/transport failure, or missing terminal acknowledgement
therefore leaves the guard as a durable containment quarantine. A restarted
service refuses to claim until an operator has inspected the host (or rebooted
it) and explicitly removed the marker. Failure to create, verify, remove, or
flush the guard parks the current daemon permanently instead of exiting into an
automatic supervisor restart loop. This is crash fail-closed state, not a
hostile-code or multi-tenant sandbox. Its guarantee covers non-adversarial
daemon crashes, `SIGKILL`, and power loss while assignments are trusted to run
under the worker's own OS identity. Same-identity code can tamper with worker
state, including this marker; process containment is lifecycle correctness, not
a security boundary against a malicious submitted job.

## Source contract

Executable source may be either a public HTTPS Git repository at an exact,
full 40- or 64-character lowercase hexadecimal commit object ID or an
immutable controller snapshot identified by the SHA-256 of its bounded
`tar+zstd` archive. Userinfo, query strings, fragments, submodules, Git LFS,
credential helpers, and interactive prompts are disabled for Git sources.

The worker records the requested object ID, resolved `HEAD`, tree ID, and Git
version. `HEAD` must exactly equal the requested object ID before any job step
runs. For snapshots, the CLI/MCP packer rejects secret/cache paths, links,
reparse points, unsafe archive names, and size overruns; both upload and worker
download recheck exact byte length and digest before safe extraction. Private
repository credentials remain a later protocol extension.

## Job-owned filesystem

Every run receives a new exclusive directory:

```text
<worker-root>/jobs/<run-id>/
  repo/
  scripts/
  logs/
  artifacts/
  tmp/
  manifest.json
  result.json
  .lock/
```

Protocol paths always use `/` separators and are relative. Absolute paths,
drive prefixes, UNC paths, backslashes, NUL, empty segments, `.`, `..`, and
symlink/reparse-point escape are rejected. Artifact collection never follows
links and excludes `.git/**` by default.

Cleanup, cancellation, and rollback may touch only the proven run directory
and process tree. Unknown directories and unrelated processes are never swept.

## Execution and cancellation

Each step is written to a native script file rather than nested into another
shell command string. Supported shells are PowerShell/Cmd on Windows and
Bash/Zsh on Unix. The default is PowerShell on Windows, Bash on Linux, and Zsh
on macOS.

Standard output and error are drained concurrently into bounded files and
uploaded in idempotent, checksum-addressed chunks. The effective deadline is
the earliest of the job timeout and current step timeout.

Cancellation semantics are explicit:

- an unclaimed queued run can become terminal `cancelled` immediately;
- preparing/running/verifying sets `cancelRequested` and keeps its lease;
- the worker terminates and waits for the complete process tree, then submits
  cancellation evidence;
- a stale state version returns conflict instead of overwriting newer state.

Windows trusted-job execution uses a Job Object with kill-on-close. Linux
requires `PR_SET_CHILD_SUBREAPER` before claiming work, combines a dedicated
process group with PID/start-time descendant tracking, and fails closed when it
cannot confirm that every descendant (including a `setsid` escape) is gone.
macOS now probes the native process inventory before claiming work and verifies
the dedicated process group through `proc_listpgrppids`; this is the trusted-job
backend used by the future LaunchAgent lifecycle. These lifecycle mechanisms
are not hostile-workload guards. The opt-in Linux
dedicated-identity/cgroup-v2 mechanism has passed an internal native P1 test,
but it remains production-gated while issue #5's cgroup-escape, identity,
resource, and reconciliation proof set is completed. A Windows hostile-workload
external guard is not implemented. All three platforms report hostile readiness
as false, publish no hostile scheduling capability, and reject configured
hostile execution before launch. A packaged macOS worker can pair and probe, but
its Worker Kit still refuses to activate a LaunchAgent until the native macOS
lifecycle acceptance is complete. Packaging and signature validation do not
change that package-level runtime gate.

## Evidence gate

`succeeded` is published only after the controller verifies all of:

- exact source identity;
- every step start/end time and native exit code `0`;
- bounded stdout/stderr metadata and SHA-256;
- every declared artifact is a regular job-owned file whose uploaded content
  matches its size and SHA-256;
- run start/end time, state version, and active claim;
- proof that the complete process tree is terminated for every terminal
  receipt, including ordinary success and failure as well as cancellation and
  timeout.

Worker credentials are validated from the HTTP request head before any body is
polled. The private preview then buffers each bounded upload, recomputes its
SHA-256 on the controller, writes a temporary file, and atomically renames it.
Streaming directly to disk is a later hardening step. Repeating the same chunk
or completion is idempotent only when its digest is identical.

## Managed-execution acceptance gate

The Windows/Linux managed-worker preview is evaluated against all of the
following. The release workflow's unit, native-binary, archive, and checksum
checks are necessary but do not themselves constitute or attest a live
cross-node acceptance run:

1. concurrent claim tests prove one winner per run and one slot per node;
2. cross-node credential isolation and stale-CAS tests pass;
3. traversal, symlink/reparse-point, oversized body/log/artifact, and digest
   mismatch tests pass;
4. timeout and cancellation tests prove descendants do not survive;
5. a Windows controller executes exact-SHA jobs on a Windows worker and a Linux
   worker, then retrieves logs and a SHA-verified artifact;
6. failure and cancellation are exercised end to end;
7. macOS compiles, passes platform/unit packaging checks, and produces signed
   exact-five-file x64/arm64 Worker Kits without claiming a live macOS run;
   packaged workers remain runtime-gated until containment and live acceptance
   are actually proven.
