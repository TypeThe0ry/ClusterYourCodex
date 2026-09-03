#!/usr/bin/env bash
#
# Run a real Linux controller <-> managed-worker round trip against a
# disposable controller database, TLS identity, pairing bundle, snapshot, and
# worker workspace.  The controller API remains loopback-only; the worker TLS
# listener uses an assigned RFC1918 IPv4 address because the controller rejects
# loopback worker binds.
#
# This is deliberately a live Linux probe.  --self-test is the only mode that
# is useful from Windows/Git Bash: it checks shell helpers but never starts a
# controller or pretends that Windows is a Linux acceptance host.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

REPO_INPUT="${REPO_INPUT:-${SCRIPT_DIR%/scripts}}"
WORK_ROOT_INPUT="${WORK_ROOT_INPUT:-${TMPDIR:-/tmp}}"
TIMEOUT_SECONDS=180
KEEP_EVIDENCE=0
SELF_TEST=0

REPO=""
WORK_ROOT=""
JOB_ROOT=""
LOG_DIR=""
EVIDENCE_DIR=""
IDENTITY_DIR=""
WORKER_DIR=""
WORKSPACE_DIR=""
FIXTURE_DIR=""
DOWNLOAD_DIR=""

MANIFEST_PATH=""
RESULT_PATH=""
EVENT_LOG=""
BUILD_LOG=""
CONTROLLER_LOG=""
WORKER_LOG=""
PID_FILE=""

CONTROLLER_DB=""
CONTROLLER_TOKEN=""
CONTROLLER_PORT=""
CONTROLLER_URL=""
WORKER_IP=""
WORKER_PORT=""
WORKER_URL=""
CERTIFICATE_FILE=""
PRIVATE_KEY_FILE=""

ENROLLMENT_FILE=""
PAIRING_ID=""
NODE_ID=""
WORKER_CONFIG=""
WORKER_CREDENTIAL_FILE=""
STAGED_CREDENTIAL_FILE=""

SNAPSHOT_ARCHIVE=""
SNAPSHOT_DIGEST=""
SNAPSHOT_SIZE=""
JOB_SPEC=""
JOB_ID=""
RUN_ID=""

SUBMIT_JSON=""
POLL_LATEST=""
POLL_LOG=""
POLL_ERRORS=""
FINAL_JOB_JSON=""
PAIR_STATUS_LATEST=""
FLEET_LATEST=""
CLEANUP_JSON=""
ARTIFACT_LIST_JSON=""
ARTIFACT_DOWNLOAD=""
EXPECTED_ARTIFACT=""
STDOUT_DOWNLOAD=""
STDERR_DOWNLOAD=""

CYC_BIN="${CYC_BIN:-}"
CONTROLLER_BIN="${CYC_CONTROLLER_BIN:-}"
WORKER_BIN="${CYC_WORKER_BIN:-}"
CARGO_TARGET_DIR_INPUT="${CYC_TARGET_DIR:-}"

CONTROLLER_PID=""
WORKER_PID=""
SERVICES_STOPPED=0
ROOT_CREATED=0
FLOW_DEADLINE=0
TEST_PASSED=0
FAIL_REASON=""

PAIR_READY=0
PAIR_ROUTE_OBSERVED=0
PAIR_ACK_ROUTE_OBSERVED=0
NODE_REPORTED=0
NODE_REPORT_ROUTE_OBSERVED=0
CLAIM_OBSERVED=0
CLAIM_ROUTE_OBSERVED=0
HEARTBEAT_OBSERVED=0
HEARTBEAT_ROUTE_OBSERVED=0
COMPLETE_OBSERVED=0
COMPLETE_ROUTE_OBSERVED=0
CLEANUP_OBSERVED=0
CLEANUP_ROUTE_OBSERVED=0
LOGS_VERIFIED=0
ARTIFACT_VERIFIED=0
CREDENTIAL_LEAK_SCAN=0
PROCESS_CLEAN=0
CLEANUP_STATUS="pending"
RUN_DURATION_SECONDS=""
QUEUED_OBSERVED=0
PREPARING_OBSERVED=0
RUNNING_OBSERVED=0
VERIFYING_OBSERVED=0
SUCCEEDED_OBSERVED=0

usage() {
  cat <<'EOF'
Usage: test-linux-controller-worker-roundtrip.sh [options]

Start a real Linux cyc-controller worker TLS listener and cyc-worker, pair the
worker, submit a snapshot-backed JobSpec, poll it to success, verify protocol
routes/logs/artifacts/cleanup, and then stop both daemons.

Options:
  --repo PATH       ClusterYourCodex checkout (default: checkout containing this script)
  --work-root PATH  Parent for one disposable round-trip directory (default: $TMPDIR or /tmp)
  --timeout SEC     Whole live-flow timeout, 30..3600 seconds (default: 180)
  --keep-evidence   Retain the sanitized evidence directory after success
  --self-test       Run shell-only helper checks; never starts Linux services
  -h, --help        Show this help

Live mode requires Linux, cargo, python3, bash, the standard proc/network
utilities, and a private assigned IPv4 address for the worker TLS
listener.  The controller API is always bound to loopback.  On success the
temporary root is removed unless --keep-evidence is supplied; on failure a
sanitized evidence root is retained for diagnosis.
EOF
}

die() {
  FAIL_REASON="$*"
  printf 'ERROR: %s\n' "$FAIL_REASON" >&2
  exit 1
}

is_uint() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

json_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

reject_control_chars() {
  case "$1" in
    *$'\n'*|*$'\r'*|*$'\t'*) die "path or option value contains a control character" ;;
  esac
}

now_iso() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

now_epoch() {
  date '+%s'
}

log_event() {
  [[ -n "$EVENT_LOG" && -f "$EVENT_LOG" ]] || return 0
  printf '[%s] %s\n' "$(now_iso)" "$*" >>"$EVENT_LOG" 2>/dev/null || true
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

resolve_executable() {
  local input="$1"
  local resolved
  if [[ "$input" == */* ]]; then
    [[ -f "$input" && -x "$input" && ! -L "$input" ]] || die "executable is not a direct executable file: $input"
    resolved="$(CDPATH= cd -- "$(dirname -- "$input")" && pwd -P)/$(basename -- "$input")"
  else
    resolved="$(command -v -- "$input" 2>/dev/null || true)"
    [[ -n "$resolved" && -f "$resolved" && -x "$resolved" ]] || die "executable not found: $input"
    resolved="$(readlink -f -- "$resolved")"
  fi
  printf '%s' "$resolved"
}

resolve_directory() {
  local input="$1"
  local label="$2"
  reject_control_chars "$input"
  [[ -n "$input" ]] || die "$label must not be empty"
  [[ -L "$input" ]] && die "$label must not be a symlink: $input"
  if [[ ! -e "$input" ]]; then
    mkdir -p -- "$input" || die "failed to create $label: $input"
  fi
  [[ -d "$input" && ! -L "$input" ]] || die "$label is not a direct directory: $input"
  CDPATH= cd -- "$input" || die "cannot enter $label: $input"
  pwd -P
}

is_private_ipv4() {
  local address="$1"
  local first second third fourth
  [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r first second third fourth <<<"$address"
  is_uint "$first" && is_uint "$second" && is_uint "$third" && is_uint "$fourth" || return 1
  (( first <= 255 && second <= 255 && third <= 255 && fourth <= 255 )) || return 1
  (( first == 10 || (first == 172 && second >= 16 && second <= 31) || (first == 192 && second == 168) ))
}

find_private_ipv4() {
  local candidate candidates
  if command -v ip >/dev/null 2>&1; then
    candidates="$(ip -o -4 addr show scope global up 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)"
  else
    candidates="$(hostname -I 2>/dev/null | tr ' ' '\n' || true)"
  fi
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    if is_private_ipv4 "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done <<<"$candidates"
  return 1
}

find_free_port() {
  python3 - "$1" <<'PY'
import socket
import sys

host = sys.argv[1]
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((host, 0))
    print(sock.getsockname()[1])
PY
}

wait_for_worker_listener() {
  local end=$(( $(now_epoch) + 15 ))
  while (( $(now_epoch) <= end && $(now_epoch) < FLOW_DEADLINE )); do
    if python3 - "$WORKER_IP" "$WORKER_PORT" <<'PY'
import socket
import sys

with socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=1):
    pass
PY
    then
      log_event "worker TLS listener accepted a TCP connection"
      return 0
    fi
    sleep 0.25
  done
  die "worker TLS listener did not become reachable before pairing"
}

json_validate_file() {
  python3 - "$1" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
with path.open("rb") as handle:
    json.load(handle)
PY
}

json_value() {
  python3 - "$1" "$2" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
selector = sys.argv[2]
with path.open("rb") as handle:
    value = json.load(handle)
for part in selector.split("."):
    if isinstance(value, dict) and part in value:
        value = value[part]
    else:
        raise SystemExit(f"JSON field not found: {selector}")
if isinstance(value, str):
    print(value)
elif value is True:
    print("true")
elif value is False:
    print("false")
elif value is None:
    print("null")
elif isinstance(value, (int, float)):
    print(value)
else:
    print(json.dumps(value, separators=(",", ":")))
PY
}

json_duration_seconds() {
  python3 - "$1" <<'PY'
from datetime import datetime
import json
import pathlib
import sys

with pathlib.Path(sys.argv[1]).open("rb") as handle:
    document = json.load(handle)
run = document["run"]
started = datetime.fromisoformat(run["startedAt"].replace("Z", "+00:00"))
finished = datetime.fromisoformat(run["finishedAt"].replace("Z", "+00:00"))
duration = (finished - started).total_seconds()
if duration < 0:
    raise SystemExit("run finished before it started")
print(int(duration))
PY
}

fleet_contains_node() {
  python3 - "$1" "$2" <<'PY'
import json
import pathlib
import sys

with pathlib.Path(sys.argv[1]).open("rb") as handle:
    document = json.load(handle)
node_id = sys.argv[2]
for item in document.get("nodes", []):
    if item.get("id") == node_id:
        raise SystemExit(0)
for item in document.get("nodeViews", []):
    if item.get("nodeId") == node_id:
        raise SystemExit(0)
raise SystemExit(1)
PY
}

artifact_record() {
  python3 - "$1" <<'PY'
import json
import pathlib
import sys

with pathlib.Path(sys.argv[1]).open("rb") as handle:
    document = json.load(handle)
for artifact in document.get("artifacts", []):
    if artifact.get("name") == "result.txt":
        print("\t".join([
            str(artifact["id"]),
            str(artifact["sha256"]),
            str(artifact["size"]),
            str(artifact["name"]),
        ]))
        raise SystemExit(0)
raise SystemExit("result.txt artifact was not listed")
PY
}

controller_cleanup_get() {
  python3 - "$CONTROLLER_PORT" "$JOB_ID" "$CONTROLLER_TOKEN" <<'PY'
import http.client
import pathlib
import sys

port = int(sys.argv[1])
job_id = sys.argv[2]
token = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8").strip()
connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
try:
    connection.request(
        "GET",
        f"/v1/jobs/{job_id}/cleanup",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    response = connection.getresponse()
    body = response.read(1024 * 1024 + 1)
    if response.status != 200:
        raise SystemExit(f"cleanup endpoint returned HTTP {response.status}")
    sys.stdout.buffer.write(body)
finally:
    connection.close()
PY
}

scan_secret_leaks() {
  [[ -n "$JOB_ROOT" && -d "$JOB_ROOT" ]] || return 0
  python3 - "$LOG_DIR" "$EVIDENCE_DIR" "$MANIFEST_PATH" "$RESULT_PATH" "$JOB_SPEC" \
    "$CONTROLLER_TOKEN" "$PRIVATE_KEY_FILE" "$ENROLLMENT_FILE" "$WORKER_CREDENTIAL_FILE" <<'PY'
import json
import pathlib
import re
import sys

log_root = pathlib.Path(sys.argv[1])
evidence_root = pathlib.Path(sys.argv[2])
targets = [log_root, evidence_root]
for raw in sys.argv[3:6]:
    if raw:
        targets.append(pathlib.Path(raw))
secret_paths = [pathlib.Path(raw) for raw in sys.argv[6:] if raw]
secrets = []

def add_secret(raw: bytes) -> None:
    raw = raw.strip()
    if len(raw) >= 16 and raw not in secrets:
        secrets.append(raw)

for path in secret_paths:
    try:
        if not path.is_file() or path.is_symlink():
            continue
        raw = path.read_bytes()
    except OSError:
        continue
    if path.name == "enrollment.json":
        try:
            add_secret(str(json.loads(raw)["pairingCode"]).encode("utf-8"))
        except (ValueError, KeyError, TypeError):
            pass
    else:
        add_secret(raw)

for root in targets:
    if root.is_dir() and not root.is_symlink():
        paths = (item for item in root.rglob("*") if item.is_file() and not item.is_symlink())
    elif root.is_file() and not root.is_symlink():
        paths = (root,)
    else:
        continue
    for path in paths:
        if path in secret_paths:
            continue
        try:
            data = path.read_bytes()
        except OSError:
            continue
        for secret in secrets:
            if secret in data:
                print(f"secret value appeared in evidence file: {path}", file=sys.stderr)
                raise SystemExit(1)
        lowered = data.lower()
        if b"-----begin private key-----" in lowered or b"-----begin rsa private key-----" in lowered:
            print(f"private-key PEM marker appeared in evidence file: {path}", file=sys.stderr)
            raise SystemExit(1)
        if b"x-cyc-run-credential" in lowered or b"authorization: pairing" in lowered:
            print(f"credential-bearing HTTP marker appeared in evidence file: {path}", file=sys.stderr)
            raise SystemExit(1)
        if re.search(rb'"pairingCode"\s*:', data):
            print(f"pairingCode field appeared in evidence file: {path}", file=sys.stderr)
            raise SystemExit(1)
PY
}

write_manifest() {
  [[ -n "$MANIFEST_PATH" ]] || return 0
  local repo work job logs evidence
  repo="$(json_escape "$REPO")"
  work="$(json_escape "$WORK_ROOT")"
  job="$(json_escape "$JOB_ROOT")"
  logs="$(json_escape "$LOG_DIR")"
  evidence="$(json_escape "$EVIDENCE_DIR")"
  cat >"$MANIFEST_PATH" <<EOF
{
  "schema": "cyc.dev/linux-controller-worker-roundtrip-manifest/v1",
  "hostOs": "Linux",
  "repo": "$repo",
  "workRoot": "$work",
  "jobRoot": "$job",
  "logs": "$logs",
  "evidence": "$evidence",
  "controllerUrl": "http://127.0.0.1:$CONTROLLER_PORT",
  "workerUrl": "$(json_escape "$WORKER_URL")",
  "workerAddress": "$(json_escape "$WORKER_IP")",
  "timeoutSeconds": $TIMEOUT_SECONDS,
  "heartbeatIntervalSeconds": 5,
  "createdAt": "$(now_iso)"
}
EOF
}

write_result() {
  [[ -n "$RESULT_PATH" ]] || return 0
  local status repo work job run node cleanup
  if (( TEST_PASSED == 1 )); then status="passed"; else status="failed"; fi
  repo="$(json_escape "$REPO")"
  work="$(json_escape "$WORK_ROOT")"
  job="$(json_escape "$JOB_ID")"
  run="$(json_escape "$RUN_ID")"
  node="$(json_escape "$NODE_ID")"
  cleanup="$(json_escape "$CLEANUP_STATUS")"
  cat >"$RESULT_PATH" <<EOF
{
  "schema": "cyc.dev/linux-controller-worker-roundtrip-result/v1",
  "status": "$status",
  "exitCode": ${1:-1},
  "hostOs": "Linux",
  "repo": "$repo",
  "workRoot": "$work",
  "jobId": "$job",
  "runId": "$run",
  "nodeId": "$node",
  "controllerUrl": "http://127.0.0.1:$CONTROLLER_PORT",
  "workerUrl": "$(json_escape "$WORKER_URL")",
  "checks": {
    "pairReady": $([[ "$PAIR_READY" == 1 ]] && printf true || printf false),
    "pairRoute": $([[ "$PAIR_ROUTE_OBSERVED" == 1 ]] && printf true || printf false),
    "pairAckRoute": $([[ "$PAIR_ACK_ROUTE_OBSERVED" == 1 ]] && printf true || printf false),
    "nodeReported": $([[ "$NODE_REPORTED" == 1 ]] && printf true || printf false),
    "nodeReportRoute": $([[ "$NODE_REPORT_ROUTE_OBSERVED" == 1 ]] && printf true || printf false),
    "claimObserved": $([[ "$CLAIM_OBSERVED" == 1 ]] && printf true || printf false),
    "claimRoute": $([[ "$CLAIM_ROUTE_OBSERVED" == 1 ]] && printf true || printf false),
    "queuedObserved": $([[ "$QUEUED_OBSERVED" == 1 ]] && printf true || printf false),
    "preparingObserved": $([[ "$PREPARING_OBSERVED" == 1 ]] && printf true || printf false),
    "runningObserved": $([[ "$RUNNING_OBSERVED" == 1 ]] && printf true || printf false),
    "verifyingObserved": $([[ "$VERIFYING_OBSERVED" == 1 ]] && printf true || printf false),
    "succeededObserved": $([[ "$SUCCEEDED_OBSERVED" == 1 ]] && printf true || printf false),
    "heartbeatObserved": $([[ "$HEARTBEAT_OBSERVED" == 1 ]] && printf true || printf false),
    "heartbeatRoute": $([[ "$HEARTBEAT_ROUTE_OBSERVED" == 1 ]] && printf true || printf false),
    "completeObserved": $([[ "$COMPLETE_OBSERVED" == 1 ]] && printf true || printf false),
    "completeRoute": $([[ "$COMPLETE_ROUTE_OBSERVED" == 1 ]] && printf true || printf false),
    "cleanupObserved": $([[ "$CLEANUP_OBSERVED" == 1 ]] && printf true || printf false),
    "cleanupRoute": $([[ "$CLEANUP_ROUTE_OBSERVED" == 1 ]] && printf true || printf false),
    "logsVerified": $([[ "$LOGS_VERIFIED" == 1 ]] && printf true || printf false),
    "artifactsVerified": $([[ "$ARTIFACT_VERIFIED" == 1 ]] && printf true || printf false),
    "credentialLeakScan": $([[ "$CREDENTIAL_LEAK_SCAN" == 1 ]] && printf true || printf false),
    "processesCleaned": $([[ "$PROCESS_CLEAN" == 1 ]] && printf true || printf false)
  },
  "cleanupStatus": "$cleanup",
  "runDurationSeconds": ${RUN_DURATION_SECONDS:-null},
  "evidenceRetained": $([[ "$KEEP_EVIDENCE" == 1 || "$TEST_PASSED" != 1 ]] && printf true || printf false),
  "failure": "$(json_escape "$FAIL_REASON")",
  "finishedAt": "$(now_iso)"
}
EOF
}

run_logged() {
  local label="$1"
  local output="$2"
  shift 2
  log_event "start $label"
  if "$@" >"$output" 2>&1; then
    log_event "pass $label"
    return 0
  else
    local status=$?
    log_event "fail $label exit=$status"
    return "$status"
  fi
}

run_python_logged() {
  local label="$1"
  local output="$2"
  shift 2
  log_event "start $label"
  if python3 "$@" >"$output" 2>&1; then
    log_event "pass $label"
    return 0
  else
    local status=$?
    log_event "fail $label exit=$status"
    return "$status"
  fi
}

proc_start_time() {
  local pid="$1"
  [[ -r "/proc/$pid/stat" ]] || return 1
  awk '{ sub(/^.*\) /, ""); print $20 }' "/proc/$pid/stat" 2>/dev/null
}

proc_exe() {
  local pid="$1"
  readlink -f -- "/proc/$pid/exe" 2>/dev/null
}

pid_state_from_record() {
  local pid="$1"
  local expected_exe="$2"
  local expected_start="$3"
  local current_exe current_start
  kill -0 "$pid" 2>/dev/null || return 0
  current_start="$(proc_start_time "$pid" || true)"
  current_exe="$(proc_exe "$pid" || true)"
  if [[ -n "$current_start" && "$current_start" == "$expected_start" && "$current_exe" == "$expected_exe" ]]; then
    return 1
  fi
  return 2
}

record_process_once() {
  local pid="$1"
  local label="$2"
  local exe start
  [[ "$pid" =~ ^[0-9]+$ && "$pid" != 0 ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  exe="$(proc_exe "$pid" || true)"
  start="$(proc_start_time "$pid" || true)"
  [[ -n "$exe" && -n "$start" ]] || return 1
  if ! grep -Fq -- "${pid}|" "$PID_FILE" 2>/dev/null; then
    printf '%s|%s|%s|%s\n' "$pid" "$label" "$exe" "$start" >>"$PID_FILE"
  fi
}

record_process_wait() {
  local pid="$1"
  local label="$2"
  local end=$(( $(now_epoch) + 10 ))
  while (( $(now_epoch) <= end )); do
    if record_process_once "$pid" "$label"; then return 0; fi
    sleep 0.05
  done
  die "could not capture process identity for $label (pid $pid)"
}

collect_descendants_of() {
  local root="$1"
  local child
  while IFS= read -r child; do
    [[ "$child" =~ ^[0-9]+$ && "$child" != 0 ]] || continue
    record_process_once "$child" "descendant-of-$root" || true
    collect_descendants_of "$child"
  done < <(ps -eo pid=,ppid= 2>/dev/null | awk -v parent="$root" '$2 == parent {print $1}')
}

collect_process_tree() {
  [[ -f "$PID_FILE" ]] || return 0
  local root
  for root in "$WORKER_PID" "$CONTROLLER_PID"; do
    [[ "$root" =~ ^[0-9]+$ ]] || continue
    collect_descendants_of "$root"
  done
}

send_signal_to_recorded() {
  local signal="$1"
  local pid label exe start state
  [[ -f "$PID_FILE" ]] || return 0
  while IFS='|' read -r pid label exe start; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    pid_state_from_record "$pid" "$exe" "$start"
    state=$?
    if (( state == 1 )); then
      kill -"$signal" "$pid" 2>>"$EVENT_LOG" || true
      log_event "sent SIG$signal pid=$pid label=$label"
    elif (( state == 2 )); then
      log_event "refused SIG$signal for reused-or-mismatched pid=$pid label=$label"
    fi
  done <"$PID_FILE"
}

recorded_processes_clear() {
  local pid label exe start state
  [[ -f "$PID_FILE" ]] || return 0
  while IFS='|' read -r pid label exe start; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    pid_state_from_record "$pid" "$exe" "$start"
    state=$?
    if (( state != 0 )); then
      log_event "residual process record pid=$pid label=$label state=$state"
      return 1
    fi
  done <"$PID_FILE"
  return 0
}

wait_for_recorded_processes_clear() {
  local seconds="$1"
  local deadline=$(( $(now_epoch) + seconds ))
  while (( $(now_epoch) <= deadline )); do
    if recorded_processes_clear; then return 0; fi
    sleep 0.1
  done
  recorded_processes_clear
}

stop_services() {
  (( SERVICES_STOPPED == 1 )) && return 0
  collect_process_tree
  log_event "stopping worker/controller with SIGINT"
  send_signal_to_recorded INT
  if ! wait_for_recorded_processes_clear 8; then
    log_event "SIGINT grace period expired; sending SIGTERM"
    send_signal_to_recorded TERM
    if ! wait_for_recorded_processes_clear 5; then
      log_event "SIGTERM grace period expired; sending SIGKILL"
      send_signal_to_recorded KILL
      wait_for_recorded_processes_clear 3 || true
    fi
  fi
  if [[ "$WORKER_PID" =~ ^[0-9]+$ ]]; then wait "$WORKER_PID" 2>/dev/null || true; fi
  if [[ "$CONTROLLER_PID" =~ ^[0-9]+$ ]]; then wait "$CONTROLLER_PID" 2>/dev/null || true; fi
  if recorded_processes_clear; then
    PROCESS_CLEAN=1
    SERVICES_STOPPED=1
    log_event "all recorded daemon/descendant processes are gone"
    return 0
  fi
  log_event "recorded daemon/descendant process residue remains"
  return 1
}

remove_owned_file() {
  local path="$1"
  [[ -n "$path" ]] || return 0
  [[ -e "$path" || -L "$path" ]] || return 0
  case "$path" in
    "$JOB_ROOT"/*) ;;
    *) log_event "refused to remove path outside job root: $path"; return 1 ;;
  esac
  if [[ -d "$path" && ! -L "$path" ]]; then
    log_event "refused to remove directory as a secret file: $path"
    return 1
  fi
  rm -f -- "$path" || { log_event "failed to remove owned secret file: $path"; return 1; }
  [[ ! -e "$path" && ! -L "$path" ]] || { log_event "secret file remains after removal: $path"; return 1; }
  return 0
}

remove_secret_material() {
  local status=0
  remove_owned_file "$CONTROLLER_TOKEN" || status=1
  remove_owned_file "$PRIVATE_KEY_FILE" || status=1
  remove_owned_file "$ENROLLMENT_FILE" || status=1
  remove_owned_file "$WORKER_CREDENTIAL_FILE" || status=1
  remove_owned_file "$STAGED_CREDENTIAL_FILE" || status=1
  return "$status"
}

remove_job_root_safely() {
  [[ -n "$JOB_ROOT" && -d "$JOB_ROOT" && ! -L "$JOB_ROOT" ]] || return 0
  [[ "$JOB_ROOT" != / && "$JOB_ROOT" != "$WORK_ROOT" ]] || { log_event "refused unsafe job-root removal"; return 1; }
  [[ "$(CDPATH= cd -- "$(dirname -- "$JOB_ROOT")" && pwd -P)" == "$WORK_ROOT" ]] || {
    log_event "refused job-root removal outside work-root"
    return 1
  }
  [[ "$(basename -- "$JOB_ROOT")" == cyc-linux-controller-worker-roundtrip.* ]] || {
    log_event "refused job-root removal with unexpected basename"
    return 1
  }
  rm -rf -- "$JOB_ROOT" || return 1
  [[ ! -e "$JOB_ROOT" && ! -L "$JOB_ROOT" ]]
}

cleanup_on_exit() {
  local original_status="${1:-1}"
  local cleanup_status=0
  trap - EXIT INT TERM HUP
  set +e
  if (( ROOT_CREATED == 1 )); then
    if ! stop_services; then cleanup_status=1; fi
    if ! scan_secret_leaks; then
      CREDENTIAL_LEAK_SCAN=0
      cleanup_status=1
    else
      CREDENTIAL_LEAK_SCAN=1
    fi
    if ! remove_secret_material; then cleanup_status=1; fi
    write_manifest
    if (( original_status == 0 && TEST_PASSED == 1 && cleanup_status == 0 )); then
      write_result 0
      if (( KEEP_EVIDENCE == 1 )); then
        printf 'PASS: Linux controller/worker round-trip complete; sanitized evidence retained at %s\n' "$JOB_ROOT" >&2
      elif remove_job_root_safely; then
        printf 'PASS: Linux controller/worker round-trip complete; temporary evidence removed\n' >&2
      else
        cleanup_status=1
        printf 'ERROR: round-trip passed but safe evidence-root removal failed; retained at %s\n' "$JOB_ROOT" >&2
      fi
    else
      write_result "$original_status"
      printf 'FAIL: Linux controller/worker round-trip did not pass; sanitized evidence retained at %s\n' "$JOB_ROOT" >&2
    fi
  fi
  if (( original_status == 0 && cleanup_status != 0 )); then original_status=1; fi
  exit "$original_status"
}

on_signal() {
  local signal_name="$1"
  TEST_PASSED=0
  FAIL_REASON="received SIG$signal_name"
  if [[ "$signal_name" == INT ]]; then exit 130; else exit 143; fi
}

run_self_test() {
  local escaped
  is_uint 0 || die "self-test: is_uint(0)"
  is_uint 123 || die "self-test: is_uint(123)"
  is_uint 12x && die "self-test: is_uint accepted letters"
  is_private_ipv4 10.0.0.1 || die "self-test: RFC1918 10/8"
  is_private_ipv4 172.16.1.1 || die "self-test: RFC1918 172.16/12"
  is_private_ipv4 192.168.1.1 || die "self-test: RFC1918 192.168/16"
  is_private_ipv4 127.0.0.1 && die "self-test: loopback accepted as worker address"
  is_private_ipv4 8.8.8.8 && die "self-test: public address accepted as worker address"
  escaped="$(json_escape 'a"b\c')"
  [[ "$escaped" == 'a\"b\\c' ]] || die "self-test: JSON escaping"
  printf 'PASS: shell self-test passed; no Linux services were started\n'
}

parse_args() {
  while (($#)); do
    case "$1" in
      --repo)
        (($# >= 2)) || die "--repo requires PATH"
        REPO_INPUT="$2"
        shift 2
        ;;
      --work-root)
        (($# >= 2)) || die "--work-root requires PATH"
        WORK_ROOT_INPUT="$2"
        shift 2
        ;;
      --timeout)
        (($# >= 2)) || die "--timeout requires seconds"
        TIMEOUT_SECONDS="$2"
        shift 2
        ;;
      --keep-evidence)
        KEEP_EVIDENCE=1
        shift
        ;;
      --self-test)
        SELF_TEST=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done
  is_uint "$TIMEOUT_SECONDS" || die "--timeout must be an integer in 30..3600"
  (( TIMEOUT_SECONDS >= 30 && TIMEOUT_SECONDS <= 3600 )) || die "--timeout must be an integer in 30..3600"
}

setup_binaries() {
  local target_dir
  if [[ -n "$CYC_BIN" && -n "$CONTROLLER_BIN" && -n "$WORKER_BIN" ]]; then
    CYC_BIN="$(resolve_executable "$CYC_BIN")"
    CONTROLLER_BIN="$(resolve_executable "$CONTROLLER_BIN")"
    WORKER_BIN="$(resolve_executable "$WORKER_BIN")"
  else
    require_command cargo
    target_dir="${CARGO_TARGET_DIR_INPUT:-$REPO/target}"
    reject_control_chars "$target_dir"
    if [[ "$target_dir" != /* ]]; then
      target_dir="$REPO/$target_dir"
    fi
    mkdir -p -- "$target_dir" || die "failed to create cargo target directory: $target_dir"
    log_event "building cyc-cli/cyc-controller/cyc-worker with cargo"
    if ! cargo build --locked --manifest-path "$REPO/Cargo.toml" --target-dir "$target_dir" \
      -p cyc-cli -p cyc-controller -p cyc-worker >"$BUILD_LOG" 2>&1; then
      die "cargo build failed; inspect $BUILD_LOG"
    fi
    [[ -n "$CYC_BIN" ]] || CYC_BIN="$target_dir/debug/cyc"
    [[ -n "$CONTROLLER_BIN" ]] || CONTROLLER_BIN="$target_dir/debug/cyc-controller"
    [[ -n "$WORKER_BIN" ]] || WORKER_BIN="$target_dir/debug/cyc-worker"
    CYC_BIN="$(resolve_executable "$CYC_BIN")"
    CONTROLLER_BIN="$(resolve_executable "$CONTROLLER_BIN")"
    WORKER_BIN="$(resolve_executable "$WORKER_BIN")"
  fi
  {
    "$CYC_BIN" --version
    "$CONTROLLER_BIN" --version
    "$WORKER_BIN" --version
  } >"$EVIDENCE_DIR/toolchain-versions.txt" 2>&1 || die "cyc binary version probe failed"
}

wait_for_controller_health() {
  local output="$EVIDENCE_DIR/controller-health.json"
  local end=$(( $(now_epoch) + 30 ))
  local status
  while (( $(now_epoch) <= end && $(now_epoch) < FLOW_DEADLINE )); do
    kill -0 "$CONTROLLER_PID" 2>/dev/null || die "controller exited before health became ready"
    if "${CYC_BIN}" --controller "$CONTROLLER_URL" health >"$output" 2>>"$EVENT_LOG"; then
      if json_validate_file "$output" 2>/dev/null; then
        status="$(json_value "$output" status 2>/dev/null || true)"
        if [[ "$status" == ok ]]; then
          log_event "controller health is ok"
          return 0
        fi
      fi
    fi
    sleep 0.25
  done
  die "controller health did not become ready before timeout"
}

wait_for_pair_ready() {
  local output="$PAIR_STATUS_LATEST"
  local phase ready node
  while (( $(now_epoch) < FLOW_DEADLINE )); do
    if "${CYC_BIN}" --controller "$CONTROLLER_URL" --token-file "$CONTROLLER_TOKEN" pair status "$PAIRING_ID" >"$output" 2>>"$EVENT_LOG"; then
      if json_validate_file "$output" 2>/dev/null; then
        phase="$(json_value "$output" phase 2>/dev/null || true)"
        ready="$(json_value "$output" ready 2>/dev/null || true)"
        node="$(json_value "$output" nodeId 2>/dev/null || true)"
        if [[ "$phase" == ready && "$ready" == true && "$node" == "$NODE_ID" ]]; then
          PAIR_READY=1
          log_event "pairing status is ready"
          return 0
        fi
        case "$phase" in
          failed|expired|revoked) die "pairing entered terminal phase $phase" ;;
        esac
      fi
    fi
    sleep 0.5
  done
  die "pairing did not become ready before timeout"
}

wait_for_node_report() {
  local end=$(( $(now_epoch) + 30 ))
  while (( $(now_epoch) <= end && $(now_epoch) < FLOW_DEADLINE )); do
    if ! fleet_contains_node "$FLEET_LATEST" "$NODE_ID" 2>/dev/null; then
      "${CYC_BIN}" --controller "$CONTROLLER_URL" --token-file "$CONTROLLER_TOKEN" nodes >"$FLEET_LATEST" 2>>"$EVENT_LOG" || true
    fi
    if [[ -s "$FLEET_LATEST" ]] && fleet_contains_node "$FLEET_LATEST" "$NODE_ID" 2>/dev/null; then
      NODE_REPORTED=1
      log_event "fleet contains paired node"
      return 0
    fi
    sleep 0.5
  done
  die "worker node report did not appear in controller fleet"
}

observe_controller_routes() {
  local deadline=$(( $(now_epoch) + 8 ))
  while (( $(now_epoch) <= deadline )); do
    route_seen() { [[ -f "$CONTROLLER_LOG" ]] && grep -Fq -- "$1" "$CONTROLLER_LOG"; }
    route_seen '/worker/v1/pair' && PAIR_ROUTE_OBSERVED=1
    route_seen '/worker/v1/pair/ack' && PAIR_ACK_ROUTE_OBSERVED=1
    route_seen '/worker/v1/node-report' && NODE_REPORT_ROUTE_OBSERVED=1
    route_seen '/worker/v1/claim' && CLAIM_ROUTE_OBSERVED=1
    route_seen '/worker/v1/runs/' && route_seen '/heartbeat' && HEARTBEAT_ROUTE_OBSERVED=1
    route_seen '/worker/v1/runs/' && route_seen '/complete' && COMPLETE_ROUTE_OBSERVED=1
    route_seen '/worker/v1/runs/' && route_seen '/cleanup' && CLEANUP_ROUTE_OBSERVED=1
    (( PAIR_ROUTE_OBSERVED == 1 && PAIR_ACK_ROUTE_OBSERVED == 1 && NODE_REPORT_ROUTE_OBSERVED == 1 \
      && CLAIM_ROUTE_OBSERVED == 1 && HEARTBEAT_ROUTE_OBSERVED == 1 && COMPLETE_ROUTE_OBSERVED == 1 \
      && CLEANUP_ROUTE_OBSERVED == 1 )) && return 0
    sleep 0.25
  done
  return 1
}

poll_job_until_terminal() {
  local state node error raw
  while (( $(now_epoch) < FLOW_DEADLINE )); do
    if ! kill -0 "$WORKER_PID" 2>/dev/null; then
      die "worker process exited before job reached terminal state"
    fi
    if "${CYC_BIN}" --controller "$CONTROLLER_URL" --token-file "$CONTROLLER_TOKEN" jobs "$JOB_ID" >"$POLL_LATEST" 2>>"$POLL_ERRORS"; then
      json_validate_file "$POLL_LATEST" || die "controller returned invalid job JSON"
      raw="$(<"$POLL_LATEST")"
      printf '[%s] %s\n' "$(now_iso)" "$raw" >>"$POLL_LOG"
      state="$(json_value "$POLL_LATEST" run.state)"
      node="$(json_value "$POLL_LATEST" run.nodeId 2>/dev/null || true)"
      case "$state" in
        queued) QUEUED_OBSERVED=1 ;;
        preparing|running|verifying|succeeded|failed|cancelled)
          [[ "$node" == "$NODE_ID" ]] && CLAIM_OBSERVED=1
          [[ "$state" == preparing ]] && PREPARING_OBSERVED=1
          [[ "$state" == running ]] && RUNNING_OBSERVED=1
          [[ "$state" == verifying ]] && VERIFYING_OBSERVED=1
          [[ "$state" == succeeded ]] && SUCCEEDED_OBSERVED=1
          ;;
        *) die "unknown run state from controller: $state" ;;
      esac
      case "$state" in
        queued) ;;
        preparing) ;;
        running) ;;
        verifying) ;;
        succeeded|failed|cancelled)
          cp -- "$POLL_LATEST" "$FINAL_JOB_JSON"
          [[ "$state" == succeeded ]] || die "job reached non-success terminal state: $state"
          RUN_DURATION_SECONDS="$(json_duration_seconds "$FINAL_JOB_JSON")"
          (( RUN_DURATION_SECONDS >= 6 )) || die "run duration was too short to exercise a five-second heartbeat"
          return 0
          ;;
      esac
    fi
    sleep 1
  done
  die "job did not reach terminal state before --timeout"
}

main() {
  parse_args "$@"
  if (( SELF_TEST == 1 )); then
    run_self_test
    return 0
  fi
  [[ "$(uname -s)" == Linux ]] || die "live round-trip requires Linux; refusing to fake Linux acceptance on $(uname -s)"

  require_command bash
  require_command cargo
  require_command python3
  require_command mktemp
  require_command date
  require_command sleep
  require_command ps
  require_command readlink
  require_command stat
  require_command sha256sum
  require_command grep
  require_command awk
  require_command cut
  require_command tr
  require_command cp
  require_command cmp
  require_command hostname
  command -v ip >/dev/null 2>&1 || true

  REPO="$(resolve_directory "$REPO_INPUT" '--repo')"
  WORK_ROOT="$(resolve_directory "$WORK_ROOT_INPUT" '--work-root')"
  [[ -f "$REPO/Cargo.toml" && -d "$REPO/crates/cyc-controller" && -d "$REPO/crates/cyc-worker" \
    && -d "$REPO/crates/cyc-cli" ]] || die "--repo is not a ClusterYourCodex checkout: $REPO"

  JOB_ROOT="$(mktemp -d "$WORK_ROOT/cyc-linux-controller-worker-roundtrip.XXXXXX")" || die "failed to create disposable job root"
  chmod 700 -- "$JOB_ROOT"
  ROOT_CREATED=1
  LOG_DIR="$JOB_ROOT/logs"
  EVIDENCE_DIR="$JOB_ROOT/evidence"
  IDENTITY_DIR="$JOB_ROOT/identity"
  WORKER_DIR="$JOB_ROOT/worker"
  WORKSPACE_DIR="$JOB_ROOT/workspace"
  FIXTURE_DIR="$JOB_ROOT/source"
  DOWNLOAD_DIR="$EVIDENCE_DIR/downloads"
  mkdir -p -- "$LOG_DIR" "$EVIDENCE_DIR" "$IDENTITY_DIR" "$WORKER_DIR" "$FIXTURE_DIR" "$DOWNLOAD_DIR"
  chmod 700 -- "$LOG_DIR" "$EVIDENCE_DIR" "$IDENTITY_DIR" "$WORKER_DIR" "$FIXTURE_DIR" "$DOWNLOAD_DIR"
  MANIFEST_PATH="$JOB_ROOT/manifest.json"
  RESULT_PATH="$JOB_ROOT/result.json"
  EVENT_LOG="$LOG_DIR/events.log"
  BUILD_LOG="$LOG_DIR/cargo-build.log"
  CONTROLLER_LOG="$LOG_DIR/controller.log"
  WORKER_LOG="$LOG_DIR/worker.log"
  PID_FILE="$LOG_DIR/owned-pids.txt"
  : >"$EVENT_LOG"
  : >"$CONTROLLER_LOG"
  : >"$WORKER_LOG"
  : >"$PID_FILE"
  trap 'cleanup_on_exit "$?"' EXIT
  trap 'on_signal INT' INT
  trap 'on_signal TERM' TERM
  trap 'on_signal HUP' HUP

  CONTROLLER_DB="$JOB_ROOT/controller.db"
  CONTROLLER_TOKEN="$JOB_ROOT/controller.token"
  CERTIFICATE_FILE="$IDENTITY_DIR/controller.crt.pem"
  PRIVATE_KEY_FILE="$IDENTITY_DIR/controller.key.pem"
  ENROLLMENT_FILE="$JOB_ROOT/enrollment.json"
  WORKER_CONFIG="$WORKER_DIR/worker.json"
  SNAPSHOT_ARCHIVE="$JOB_ROOT/source.tar.zst"
  JOB_SPEC="$JOB_ROOT/job.json"
  SUBMIT_JSON="$EVIDENCE_DIR/submit.json"
  POLL_LATEST="$EVIDENCE_DIR/job-latest.json"
  POLL_LOG="$EVIDENCE_DIR/job-poll.log"
  POLL_ERRORS="$LOG_DIR/job-poll-errors.log"
  FINAL_JOB_JSON="$EVIDENCE_DIR/job-final.json"
  PAIR_STATUS_LATEST="$EVIDENCE_DIR/pair-status.json"
  FLEET_LATEST="$EVIDENCE_DIR/fleet.json"
  CLEANUP_JSON="$EVIDENCE_DIR/cleanup.json"
  ARTIFACT_LIST_JSON="$EVIDENCE_DIR/artifacts.json"
  ARTIFACT_DOWNLOAD="$DOWNLOAD_DIR/result.txt"
  EXPECTED_ARTIFACT="$EVIDENCE_DIR/expected-result.txt"
  STDOUT_DOWNLOAD="$DOWNLOAD_DIR/stdout.log"
  STDERR_DOWNLOAD="$DOWNLOAD_DIR/stderr.log"
  write_manifest

  setup_binaries
  WORKER_IP="$(find_private_ipv4 || true)"
  [[ -n "$WORKER_IP" ]] || die "no assigned RFC1918 IPv4 address; controller refuses a loopback/public worker bind"
  CONTROLLER_PORT="$(find_free_port 127.0.0.1)"
  WORKER_PORT="$(find_free_port "$WORKER_IP")"
  is_uint "$CONTROLLER_PORT" && is_uint "$WORKER_PORT" || die "free-port probe returned a non-integer port"
  [[ "$CONTROLLER_PORT" != 0 && "$WORKER_PORT" != 0 ]] || die "free-port probe returned port zero"
  CONTROLLER_URL="http://127.0.0.1:$CONTROLLER_PORT"
  WORKER_URL="https://$WORKER_IP:$WORKER_PORT"
  FLOW_DEADLINE=$(( $(now_epoch) + TIMEOUT_SECONDS ))
  write_manifest

  run_logged 'identity init' "$EVIDENCE_DIR/identity-init.json" \
    "$CYC_BIN" identity init --output-dir "$IDENTITY_DIR" --host "$WORKER_IP" || die "cyc identity init failed"
  run_logged 'identity verify' "$EVIDENCE_DIR/identity-verify.json" \
    "$CYC_BIN" identity verify --certificate "$CERTIFICATE_FILE" --private-key "$PRIVATE_KEY_FILE" \
      --host "$WORKER_IP" --json || die "generated TLS identity failed cyc identity verify"
  [[ -f "$CERTIFICATE_FILE" && ! -L "$CERTIFICATE_FILE" ]] || die "TLS certificate was not created as a direct file"
  [[ -f "$PRIVATE_KEY_FILE" && ! -L "$PRIVATE_KEY_FILE" ]] || die "TLS private key was not created as a direct file"
  [[ "$(stat -c '%a' "$PRIVATE_KEY_FILE")" == 600 ]] || die "TLS private key is not mode 600"

  log_event "starting controller on loopback and worker TLS on $WORKER_IP"
  RUST_LOG="${CYC_ROUNDTRIP_RUST_LOG:-debug}" "$CONTROLLER_BIN" \
    --bind "127.0.0.1:$CONTROLLER_PORT" \
    --database "$CONTROLLER_DB" \
    --token-file "$CONTROLLER_TOKEN" \
    --worker-bind "$WORKER_IP:$WORKER_PORT" \
    --worker-public-url "$WORKER_URL" \
    --worker-cert "$CERTIFICATE_FILE" \
    --worker-key "$PRIVATE_KEY_FILE" >"$CONTROLLER_LOG" 2>&1 &
  CONTROLLER_PID=$!
  record_process_wait "$CONTROLLER_PID" controller
  wait_for_controller_health
  wait_for_worker_listener
  [[ -f "$CONTROLLER_TOKEN" && ! -L "$CONTROLLER_TOKEN" ]] || die "controller did not create a token file"
  [[ "$(stat -c '%a' "$CONTROLLER_TOKEN")" == 600 ]] || die "controller token is not mode 600"
  local_token_size="$(stat -c '%s' "$CONTROLLER_TOKEN")"
  (( local_token_size >= 32 && local_token_size <= 256 )) || die "controller token size is outside the protocol bound"

  RUN_ID=""
  run_logged 'pair create' "$EVIDENCE_DIR/pair-create.json" \
    "$CYC_BIN" --controller "$CONTROLLER_URL" --token-file "$CONTROLLER_TOKEN" pair create \
      --output "$ENROLLMENT_FILE" --operation-id "linux-live-roundtrip-$(basename -- "$JOB_ROOT")" || die "cyc pair create failed"
  json_validate_file "$EVIDENCE_DIR/pair-create.json" || die "pair create returned invalid JSON"
  PAIRING_ID="$(json_value "$EVIDENCE_DIR/pair-create.json" pairingId)"
  NODE_ID="$(json_value "$EVIDENCE_DIR/pair-create.json" intendedNodeId)"
  [[ "$PAIRING_ID" =~ ^[0-9a-f-]{36}$ && "$NODE_ID" =~ ^[0-9a-f-]{36}$ ]] || die "pair create returned invalid identifiers"
  [[ -f "$ENROLLMENT_FILE" && ! -L "$ENROLLMENT_FILE" ]] || die "pair create did not create enrollment bundle"
  [[ "$(stat -c '%a' "$ENROLLMENT_FILE")" == 600 ]] || die "enrollment bundle is not mode 600"
  STAGED_CREDENTIAL_FILE="${WORKER_CONFIG%.json}.${PAIRING_ID}.credential"

  run_logged 'worker pair' "$EVIDENCE_DIR/worker-pair.txt" \
    "$WORKER_BIN" pair --enrollment-file "$ENROLLMENT_FILE" --config "$WORKER_CONFIG" \
      --workspace-root "$WORKSPACE_DIR" || die "cyc-worker pair failed"
  wait_for_pair_ready
  run_logged 'worker status after pair' "$EVIDENCE_DIR/worker-status-paired.json" \
    "$WORKER_BIN" status --config "$WORKER_CONFIG" --pretty || die "cyc-worker status failed after pair"
  [[ "$(json_value "$EVIDENCE_DIR/worker-status-paired.json" paired)" == true ]] || die "worker status did not report paired=true"
  [[ "$(json_value "$EVIDENCE_DIR/worker-status-paired.json" credentialProtected)" == true ]] || die "worker status did not report credentialProtected=true"
  [[ "$(json_value "$EVIDENCE_DIR/worker-status-paired.json" quarantined)" == false ]] || die "worker status reported a quarantine marker"
  WORKER_CREDENTIAL_FILE="$(json_value "$WORKER_CONFIG" credentialFile)"
  case "$WORKER_CREDENTIAL_FILE" in
    "$WORKER_DIR"/*) ;;
    *) die "worker credential path escaped the pairing-owned directory" ;;
  esac
  [[ -f "$WORKER_CREDENTIAL_FILE" && ! -L "$WORKER_CREDENTIAL_FILE" ]] || die "worker credential file missing after pair"
  [[ "$(stat -c '%a' "$WORKER_CREDENTIAL_FILE")" == 600 ]] || die "worker credential file is not mode 600"
  log_event "pairing succeeded; enrollment retained until final secret scan"

  RUST_LOG="${CYC_ROUNDTRIP_WORKER_LOG:-info}" "$WORKER_BIN" run --config "$WORKER_CONFIG" >"$WORKER_LOG" 2>&1 &
  WORKER_PID=$!
  record_process_wait "$WORKER_PID" worker
  wait_for_node_report

  printf 'roundtrip-input\n' >"$FIXTURE_DIR/input.txt"
  run_logged 'snapshot pack' "$EVIDENCE_DIR/snapshot-pack.json" \
    "$CYC_BIN" snapshot pack --source "$FIXTURE_DIR" --output "$SNAPSHOT_ARCHIVE" || die "snapshot pack failed"
  json_validate_file "$EVIDENCE_DIR/snapshot-pack.json" || die "snapshot pack returned invalid JSON"
  SNAPSHOT_DIGEST="$(json_value "$EVIDENCE_DIR/snapshot-pack.json" digest)"
  SNAPSHOT_SIZE="$(json_value "$EVIDENCE_DIR/snapshot-pack.json" sizeBytes)"
  [[ "$SNAPSHOT_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || die "snapshot pack returned invalid digest"
  is_uint "$SNAPSHOT_SIZE" && (( SNAPSHOT_SIZE > 0 )) || die "snapshot pack returned invalid size"
  [[ "$(stat -c '%s' "$SNAPSHOT_ARCHIVE")" == "$SNAPSHOT_SIZE" ]] || die "snapshot metadata size does not match archive"
  run_logged 'snapshot upload' "$EVIDENCE_DIR/snapshot-upload.json" \
    "$CYC_BIN" --controller "$CONTROLLER_URL" --token-file "$CONTROLLER_TOKEN" snapshot upload \
      --archive "$SNAPSHOT_ARCHIVE" || die "snapshot upload failed"
  run_logged 'snapshot status' "$EVIDENCE_DIR/snapshot-status.json" \
    "$CYC_BIN" --controller "$CONTROLLER_URL" --token-file "$CONTROLLER_TOKEN" snapshot status \
      "$SNAPSHOT_DIGEST" || die "snapshot status failed"
  [[ "$(json_value "$EVIDENCE_DIR/snapshot-status.json" available)" == true ]] || die "uploaded snapshot was not available"

  JOB_ID="$(< /proc/sys/kernel/random/uuid)"
  [[ "$JOB_ID" =~ ^[0-9a-f-]{36}$ ]] || die "Linux UUID source is unavailable"
  cat >"$JOB_SPEC" <<EOF
{
  "apiVersion": "cyc.dev/v1",
  "id": "$JOB_ID",
  "kind": "test",
  "source": {
    "type": "snapshot",
    "digest": "$SNAPSHOT_DIGEST",
    "sizeBytes": $SNAPSHOT_SIZE
  },
  "steps": [
    {
      "name": "controller-worker-roundtrip",
      "shell": "bash",
      "script": "set -eu\nprintf 'roundtrip-step-start\\n'\nprintf 'roundtrip-output\\n' > result.txt\nsleep 8\nprintf 'roundtrip-step-complete\\n' >> result.txt\nprintf 'roundtrip-step-complete\\n'"
    }
  ],
  "artifacts": {
    "include": ["result.txt"],
    "exclude": [".git/**"]
  },
  "timeoutSeconds": 60,
  "placementPolicy": "balanced"
}
EOF
  json_validate_file "$JOB_SPEC" || die "generated JobSpec is invalid JSON"
  run_logged 'job submit' "$SUBMIT_JSON" \
    "$CYC_BIN" --controller "$CONTROLLER_URL" --token-file "$CONTROLLER_TOKEN" submit --file "$JOB_SPEC" || die "job submit failed"
  json_validate_file "$SUBMIT_JSON" || die "job submit returned invalid JSON"
  [[ "$(json_value "$SUBMIT_JSON" job.id)" == "$JOB_ID" ]] || die "controller submit response changed job id"
  RUN_ID="$(json_value "$SUBMIT_JSON" run.id)"
  [[ "$RUN_ID" =~ ^[0-9a-f-]{36}$ ]] || die "controller submit response returned invalid run id"
  : >"$POLL_LOG"
  : >"$POLL_ERRORS"
  poll_job_until_terminal
  [[ "$(json_value "$FINAL_JOB_JSON" run.state)" == succeeded ]] || die "final run state is not succeeded"
  [[ "$(json_value "$FINAL_JOB_JSON" run.exitCode)" == 0 ]] || die "successful run did not report exitCode=0"
  [[ "$(json_value "$FINAL_JOB_JSON" run.nodeId)" == "$NODE_ID" ]] || die "run was not claimed by the paired node"
  [[ "$(json_value "$FINAL_JOB_JSON" run.artifactIds)" != '[]' ]] || die "successful run did not report artifact ids"

  printf 'roundtrip-output\nroundtrip-step-complete\n' >"$EXPECTED_ARTIFACT"
  run_logged 'stdout download' "$EVIDENCE_DIR/stdout-download.json" \
    "$CYC_BIN" --controller "$CONTROLLER_URL" --token-file "$CONTROLLER_TOKEN" logs "$JOB_ID" \
      --stream stdout --output "$STDOUT_DOWNLOAD" || die "stdout download failed"
  run_logged 'stderr download' "$EVIDENCE_DIR/stderr-download.json" \
    "$CYC_BIN" --controller "$CONTROLLER_URL" --token-file "$CONTROLLER_TOKEN" logs "$JOB_ID" \
      --stream stderr --output "$STDERR_DOWNLOAD" || die "stderr download failed"
  grep -Fq -- 'roundtrip-step-start' "$STDOUT_DOWNLOAD" || die "stdout artifact did not contain step-start marker"
  grep -Fq -- 'roundtrip-step-complete' "$STDOUT_DOWNLOAD" || die "stdout artifact did not contain step-complete marker"
  run_logged 'artifact list' "$ARTIFACT_LIST_JSON" \
    "$CYC_BIN" --controller "$CONTROLLER_URL" --token-file "$CONTROLLER_TOKEN" artifacts "$JOB_ID" || die "artifact list failed"
  json_validate_file "$ARTIFACT_LIST_JSON" || die "artifact list returned invalid JSON"
  IFS=$'\t' read -r ARTIFACT_ID ARTIFACT_SHA ARTIFACT_SIZE ARTIFACT_NAME <<<"$(artifact_record "$ARTIFACT_LIST_JSON")"
  [[ "$ARTIFACT_NAME" == result.txt && "$ARTIFACT_ID" =~ ^[0-9a-f-]{36}$ ]] || die "result.txt artifact record is invalid"
  [[ "$ARTIFACT_SHA" =~ ^[0-9a-f]{64}$ ]] || die "result.txt artifact digest is invalid"
  run_logged 'artifact download' "$EVIDENCE_DIR/artifact-download.json" \
    "$CYC_BIN" --controller "$CONTROLLER_URL" --token-file "$CONTROLLER_TOKEN" artifacts "$JOB_ID" \
      --artifact-id "$ARTIFACT_ID" --output "$ARTIFACT_DOWNLOAD" || die "artifact download failed"
  cmp -- "$EXPECTED_ARTIFACT" "$ARTIFACT_DOWNLOAD" || die "downloaded artifact bytes did not match expected output"
  [[ "$(sha256sum "$ARTIFACT_DOWNLOAD" | awk '{print $1}')" == "$ARTIFACT_SHA" ]] || die "downloaded artifact digest did not match controller metadata"
  ARTIFACT_VERIFIED=1
  LOGS_VERIFIED=1

  while (( $(now_epoch) < FLOW_DEADLINE )); do
    if controller_cleanup_get >"$CLEANUP_JSON" 2>>"$EVENT_LOG" && json_validate_file "$CLEANUP_JSON" 2>/dev/null; then
      CLEANUP_STATUS="$(json_value "$CLEANUP_JSON" status 2>/dev/null || true)"
      if [[ "$CLEANUP_STATUS" == removed && "$(json_value "$CLEANUP_JSON" jobRootDeleted 2>/dev/null || true)" == true ]]; then
        [[ "$(json_value "$CLEANUP_JSON" jobId)" == "$JOB_ID" ]] || die "cleanup response job id mismatch"
        [[ "$(json_value "$CLEANUP_JSON" runId)" == "$RUN_ID" ]] || die "cleanup response run id mismatch"
        [[ "$(json_value "$CLEANUP_JSON" relativeRoot)" == "jobs/$RUN_ID" ]] || die "cleanup response root binding mismatch"
        [[ "$(json_value "$CLEANUP_JSON" terminalAck.finalState)" == succeeded ]] || die "cleanup terminal ack was not succeeded"
        [[ "$(json_value "$CLEANUP_JSON" terminalAck.runId)" == "$RUN_ID" ]] || die "cleanup terminal ack run id mismatch"
        [[ ! -e "$WORKSPACE_DIR/jobs/$RUN_ID" && ! -L "$WORKSPACE_DIR/jobs/$RUN_ID" ]] || die "worker job root remains after removed cleanup receipt"
        CLEANUP_OBSERVED=1
        break
      fi
    fi
    sleep 0.5
  done
  (( CLEANUP_OBSERVED == 1 )) || die "controller never recorded a removed cleanup receipt"

  observe_controller_routes || true
  [[ "$PAIR_ROUTE_OBSERVED" == 1 ]] || die "controller trace did not show worker pair route"
  [[ "$PAIR_ACK_ROUTE_OBSERVED" == 1 ]] || die "controller trace did not show pairing acknowledgement route"
  [[ "$NODE_REPORT_ROUTE_OBSERVED" == 1 && "$NODE_REPORTED" == 1 ]] || die "controller trace/fleet did not show node report"
  [[ "$CLAIM_ROUTE_OBSERVED" == 1 && "$CLAIM_OBSERVED" == 1 ]] || die "controller trace/job view did not show claim"
  [[ "$HEARTBEAT_ROUTE_OBSERVED" == 1 && "$RUN_DURATION_SECONDS" -ge 6 ]] || die "controller trace/duration did not show heartbeat window"
  HEARTBEAT_OBSERVED=1
  [[ "$COMPLETE_ROUTE_OBSERVED" == 1 ]] || die "controller trace did not show completion route"
  COMPLETE_OBSERVED=1
  [[ "$CLEANUP_ROUTE_OBSERVED" == 1 ]] || die "controller trace did not show cleanup route"
  CREDENTIAL_LEAK_SCAN=1
  scan_secret_leaks || die "credential material was found in logs or evidence"
  log_event "all protocol, output, cleanup, and secret-hygiene checks passed"
  TEST_PASSED=1
  exit 0
}

main "$@"
