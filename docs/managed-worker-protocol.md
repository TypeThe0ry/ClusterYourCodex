# Managed worker execution contract

Status: design contract for the Windows private preview. The capability probe
and scheduling model exist today; this document defines the execution gate that
must pass before the project calls a node an executable worker.

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

The certificate SAN must match the host in `--worker-public-url`. The preview
accepts an explicitly provisioned, self-signed end-entity certificate; keep the
private key in a separate file. Controller startup rejects reparse points,
requires the data/key directories and private-file DACLs to be a protected
exact allowlist for the current user and SYSTEM, and will not
repair-and-trust pre-existing token, database, sidecar, or object-store state
from a weak namespace. Use the current user's data directory rather than an
ad-hoc shared `ProgramData` path. For an IP-based controller on Windows (using
the OpenSSL shipped with Git, or another current OpenSSL):

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

New-Item -ItemType Directory -Force -Path $Data, "$Data\tls" | Out-Null
Set-CycPrivateAcl $Data -Directory
Set-CycPrivateAcl "$Data\tls" -Directory
openssl req -x509 -newkey rsa:3072 -nodes -days 365 `
  -keyout "$Data\tls\controller.key" `
  -out "$Data\tls\controller.crt" `
  -subj '/CN=192.168.1.10' `
  -addext 'subjectAltName=IP:192.168.1.10' `
  -addext 'basicConstraints=critical,CA:FALSE' `
  -addext 'keyUsage=critical,digitalSignature,keyEncipherment' `
  -addext 'extendedKeyUsage=serverAuth'
Set-CycPrivateAcl "$Data\tls\controller.key"

.\cyc-controller.exe `
  --bind 127.0.0.1:47831 `
  --database "$Data\controller.db" `
  --token-file "$Data\controller.token" `
  --worker-bind 0.0.0.0:47832 `
  --worker-public-url https://192.168.1.10:47832 `
  --worker-cert "$Data\tls\controller.crt" `
  --worker-key "$Data\tls\controller.key"
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
  --config C:\ClusterYourCodex\worker.json
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

Heartbeats renew both the run claim and resource lease. If a worker cannot
renew before the local deadline, it terminates the job-owned process tree.
Expired claims are failed atomically before resources are released; they are
never silently reallocated while the old process may still be running.

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

The first executable source type is a public HTTPS Git repository at an exact,
full 40- or 64-character lowercase hexadecimal commit object ID. Userinfo,
query strings, fragments, submodules, Git LFS, credential helpers, and
interactive prompts are disabled in the preview.

The worker records the requested object ID, resolved `HEAD`, tree ID, and Git
version. `HEAD` must exactly equal the requested object ID before any job step
runs. Filtered controller snapshots and private repository credentials are a
later protocol extension.

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

Windows execution uses a Job Object with kill-on-close. Linux requires
`PR_SET_CHILD_SUBREAPER` before claiming work, combines a dedicated process
group with PID/start-time descendant tracking, and fails closed when it cannot
confirm that every descendant (including a `setsid` escape) is gone. The first
macOS preview can pair and probe, but refuses to claim executable work until a
platform containment backend can provide the same proof.

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

## Acceptance gate

The private-preview label requires all of the following:

1. concurrent claim tests prove one winner per run and one slot per node;
2. cross-node credential isolation and stale-CAS tests pass;
3. traversal, symlink/reparse-point, oversized body/log/artifact, and digest
   mismatch tests pass;
4. timeout and cancellation tests prove descendants do not survive;
5. a Windows controller executes exact-SHA jobs on a Windows worker and a Linux
   worker, then retrieves logs and a SHA-verified artifact;
6. failure and cancellation are exercised end to end;
7. macOS compiles and passes platform unit tests, without claiming a live macOS
   run until one is actually performed.
