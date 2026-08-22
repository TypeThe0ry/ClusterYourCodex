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
server identity pinning, and a different per-node credential. Neither token is
accepted as a command-line argument or copied into a job environment.

## Enrollment

1. An authenticated local client requests a one-time pairing bundle.
2. The pairing code has at least 128 bits of entropy, expires after ten minutes,
   and can be consumed once.
3. The worker verifies the controller certificate/SPKI pin before sending the
   code and its capability probe.
4. The controller stores only a hash of the issued per-node credential.
5. The credential maps to one node ID server-side. A request body can never
   choose or impersonate a different node.

Long-lived credentials live in an ACL-restricted file on Windows and a `0600`
file inside a `0700` directory on Linux/macOS.

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

Windows execution uses a Job Object with kill-on-close. Linux and macOS use a
dedicated process group with graceful termination followed by forced kill.

## Evidence gate

`succeeded` is published only after the controller verifies all of:

- exact source identity;
- every step start/end time and native exit code `0`;
- bounded stdout/stderr metadata and SHA-256;
- every declared artifact is a regular job-owned file whose uploaded content
  matches its size and SHA-256;
- run start/end time, state version, and active claim;
- process termination evidence when cancelled or timed out.

Artifact uploads are written to a temporary controller file, hashed while
streaming, then atomically renamed. Repeating the same chunk or completion is
idempotent only when its digest is identical.

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

