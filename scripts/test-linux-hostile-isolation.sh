#!/bin/bash
# Run the opt-in Linux hostile-isolation acceptance probe with a disposable
# system identity and a disposable cgroup.  This script deliberately leaves the
# job directory behind for evidence; the trap removes only objects it created.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077
# SSH service accounts may provide a minimal environment.  Keep explicit
# caller values, but provide deterministic defaults before `set -u` reaches
# toolchain/path expansion below.
PATH="${PATH:-}"
HOME="${HOME:-/root}"
for path_entry in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
  case ":$PATH:" in
    *":$path_entry:"*) ;;
    *) PATH="${PATH:+$PATH:}$path_entry" ;;
  esac
done
unset path_entry
export PATH HOME

readonly TEST_NAME="isolation::tests::linux_live_dedicated_identity_credential_and_residual_reconciliation"
readonly CGROUP_ROOT="/sys/fs/cgroup"

REPO_INPUT=""
WORK_ROOT_INPUT=""
REPO=""
WORK_ROOT=""
JOB_ROOT=""
LOG_DIR=""
STATE_DIR=""
MANIFEST_PATH=""
RESULT_PATH=""
TEST_LOG=""
CLEANUP_LOG=""
PREFLIGHT_LOG=""
GUARD_SCRIPT=""
BASELINE_CGROUPS=""
OWNED_CGROUPS=""
PREFLIGHT_CGROUP=""
HOSTILE_HOME=""
HOSTILE_USER=""
HOSTILE_GROUP=""
HOSTILE_UID=""
HOSTILE_GID=""
SOURCE_SHA=""
CGROUP_CONTROLLERS=""
CGROUP_SUBTREE_CONTROLLERS=""
CGROUP_THREADS_VERIFIED=0
TEST_STARTED_AT=""
TEST_FINISHED_AT=""
TEST_START_EPOCH=""
TEST_END_EPOCH=""
TEST_EXIT_CODE=""
TEST_RAN=0
USER_CREATED=0
GROUP_CREATED=0
PREFLIGHT_CGROUP_CREATED=0
CLEANUP_EXIT_CODE=0
CLEANUP_RUNNING=0

usage() {
  cat <<'EOF'
Usage: test-linux-hostile-isolation.sh [options]

Run the ignored native Linux hostile-isolation acceptance test with a unique,
temporary system user/group and a disposable cgroup-v2 child.

Options:
  --repo PATH       ClusterYourCodex checkout (default: current directory)
  --work-root PATH  Absolute job-artifact root (default: $TMPDIR or /tmp)
  -h, --help        Show this help

The command writes manifest.json, result.json, and logs/ below a unique job
directory.  The job directory is retained; only the temporary identity,
cgroup, and empty identity home are cleaned by the exit trap.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

is_uint() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

reject_control_chars() {
  local value="$1"
  case "$value" in
    *$'\n'*|*$'\r'*) die "path contains a newline or carriage return" ;;
  esac
}

json_escape() {
  # All values passed here are generated paths/names or timestamps.  Escape
  # the JSON metacharacters explicitly so no external serializer is required.
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

now_iso() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

now_epoch() {
  date '+%s'
}

log_cleanup() {
  [[ -n "$CLEANUP_LOG" ]] || return 0
  printf '[%s] %s\n' "$(now_iso)" "$*" >>"$CLEANUP_LOG" 2>/dev/null || true
}

log_preflight() {
  [[ -n "$PREFLIGHT_LOG" ]] || return 0
  printf '[%s] %s\n' "$(now_iso)" "$*" >>"$PREFLIGHT_LOG" 2>/dev/null || true
}

snapshot_cgroups() {
  local path
  : >"$BASELINE_CGROUPS"
  for path in "$CGROUP_ROOT"/cyc-hostile-*; do
    # Record every existing matching entry, including a symlink or an
    # unexpected non-directory.  Baseline entries are left untouched, while
    # newly appearing unsafe entries are reported as residue and never
    # followed by cleanup_one_cgroup.
    [[ -e "$path" || -L "$path" ]] || continue
    printf '%s\n' "$path" >>"$BASELINE_CGROUPS"
  done
}

is_baseline_cgroup() {
  local path="$1"
  grep -Fqx -- "$path" "$BASELINE_CGROUPS" 2>/dev/null
}

collect_owned_cgroups() {
  local path
  : >"$OWNED_CGROUPS"
  for path in "$CGROUP_ROOT"/cyc-hostile-*; do
    [[ -e "$path" || -L "$path" ]] || continue
    [[ "$path" == "$PREFLIGHT_CGROUP" ]] && continue
    if ! is_baseline_cgroup "$path"; then
      printf '%s\n' "$path" >>"$OWNED_CGROUPS"
    fi
  done
}

current_owned_cgroups() {
  local path
  for path in "$CGROUP_ROOT"/cyc-hostile-*; do
    [[ -e "$path" || -L "$path" ]] || continue
    [[ "$path" == "$PREFLIGHT_CGROUP" ]] && continue
    if ! is_baseline_cgroup "$path"; then
      printf '%s\n' "$path"
    fi
  done
}

cleanup_one_cgroup() {
  local path="$1"
  local deadline now pids threads populated

  [[ -e "$path" ]] || return 0
  if [[ ! -d "$path" || -L "$path" ]]; then
    log_cleanup "refusing to touch non-directory or symlink cgroup: $path"
    return 1
  fi
  if [[ ! -w "$path/cgroup.kill" ]]; then
    log_cleanup "cgroup.kill is not writable: $path"
    return 1
  fi
  if [[ ! -f "$path/cgroup.threads" ]]; then
    log_cleanup "cgroup.threads is missing: $path"
    return 1
  fi

  printf '1\n' >"$path/cgroup.kill" 2>>"$CLEANUP_LOG" || {
    log_cleanup "failed to request cgroup kill: $path"
    return 1
  }

  deadline=$(( $(now_epoch) + 15 ))
  while :; do
    pids="$(cat "$path/cgroup.procs" 2>/dev/null || true)"
    threads="$(cat "$path/cgroup.threads" 2>/dev/null || true)"
    populated="$(awk '$1 == "populated" { print $2; found = 1 } END { if (!found) exit 1 }' \
      "$path/cgroup.events" 2>/dev/null || true)"
    if [[ -z "$pids" && -z "$threads" && "$populated" == "0" ]]; then
      break
    fi
    now=$(now_epoch)
    if (( now >= deadline )); then
      log_cleanup "cgroup still populated after kill timeout: $path (pids=${pids:-none}; threads=${threads:-none})"
      return 1
    fi
    sleep 0.05
  done

  rmdir -- "$path" 2>>"$CLEANUP_LOG" || {
    log_cleanup "failed to remove empty job-owned cgroup: $path"
    return 1
  }
  log_cleanup "removed job-owned cgroup: $path"
  return 0
}

list_uid_pids() {
  local uid="$1"
  ps -eo pid=,uid= 2>/dev/null | awk -v target="$uid" '$2 == target { print $1 }'
}

terminate_uid_processes() {
  local pid pids
  [[ -n "$HOSTILE_UID" ]] || return 0
  pids="$(list_uid_pids "$HOSTILE_UID" || true)"
  if [[ -n "$pids" ]]; then
    log_cleanup "terminating residual processes for uid $HOSTILE_UID: $(printf '%s ' $pids)"
    while IFS= read -r pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      [[ "$pid" == "0" ]] && continue
      kill -TERM "$pid" 2>>"$CLEANUP_LOG" || true
    done <<<"$pids"
    sleep 0.2
    pids="$(list_uid_pids "$HOSTILE_UID" || true)"
    while IFS= read -r pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      [[ "$pid" == "0" ]] && continue
      kill -KILL "$pid" 2>>"$CLEANUP_LOG" || true
    done <<<"$pids"
  fi
}

verify_no_uid_processes() {
  local pids
  [[ -n "$HOSTILE_UID" ]] || return 0
  pids="$(list_uid_pids "$HOSTILE_UID" || true)"
  if [[ -n "$pids" ]]; then
    log_cleanup "residual processes remain for temporary uid $HOSTILE_UID: $pids"
    return 1
  fi
  return 0
}

write_manifest() {
  local repo work job manifest_log test_log cleanup_log source_sha controllers guard_script
  repo="$(json_escape "$REPO")"
  work="$(json_escape "$WORK_ROOT")"
  job="$(json_escape "$JOB_ROOT")"
  manifest_log="$(json_escape "$PREFLIGHT_LOG")"
  test_log="$(json_escape "$TEST_LOG")"
  cleanup_log="$(json_escape "$CLEANUP_LOG")"
  guard_script="$(json_escape "$GUARD_SCRIPT")"
  source_sha="$(json_escape "$SOURCE_SHA")"
  controllers="$(json_escape "$CGROUP_CONTROLLERS")"
  cat >"$MANIFEST_PATH" <<EOF
{
  "schemaVersion": 1,
  "kind": "linux-hostile-isolation-native-test",
  "test": "$(json_escape "$TEST_NAME")",
  "repo": "$repo",
  "workRoot": "$work",
  "jobRoot": "$(json_escape "$JOB_ROOT")",
  "sourceSha": "$source_sha",
  "cgroupRoot": "$CGROUP_ROOT",
  "cgroupControllers": "$controllers",
  "cgroupSubtreeControllers": "$(json_escape "$CGROUP_SUBTREE_CONTROLLERS")",
  "cgroupControls": ["cgroup.procs", "cgroup.threads", "cgroup.events", "cgroup.kill", "pids.max"],
  "nativeProbeMarkers": {
    "cgroupThreadsControl": "cgroup.threads",
    "cgroupThreadsBoundaryVerified": $CGROUP_THREADS_VERIFIED
  },
  "temporaryUser": "$(json_escape "$HOSTILE_USER")",
  "temporaryGroup": "$(json_escape "$HOSTILE_GROUP")",
  "executionUid": ${HOSTILE_UID:-null},
  "executionGid": ${HOSTILE_GID:-null},
  "environment": {
    "CYC_TEST_HOSTILE_LIVE_UID": ${HOSTILE_UID:-null},
    "CYC_TEST_HOSTILE_LIVE_GID": ${HOSTILE_GID:-null}
  },
  "command": [
    "cargo", "test", "--manifest-path", "$(json_escape "$REPO/Cargo.toml")",
    "-p", "cyc-worker", "--lib", "--locked", "--",
    "--ignored", "--exact", "--nocapture", "$(json_escape "$TEST_NAME")"
  ],
  "selectorGuard": [
    "python3", "$guard_script", "--repo", "$repo", "--platform", "linux"
  ],
  "artifacts": {
    "preflightLog": "$manifest_log",
    "testLog": "$test_log",
    "cleanupLog": "$cleanup_log",
    "result": "$(json_escape "$RESULT_PATH")"
  }
}
EOF
}

write_result() {
  local final_status="$1"
  local cleanup_status="$2"
  local test_code="null" uid_json="null" gid_json="null"
  local source_sha repo work test_log cleanup_log preflight_log tmp
  local residual_cgroup=0 residual_uid=0 elapsed=0 cgroup_threads_marker=0

  [[ -n "$TEST_EXIT_CODE" ]] && test_code="$TEST_EXIT_CODE"
  is_uint "${HOSTILE_UID:-}" && uid_json="$HOSTILE_UID"
  is_uint "${HOSTILE_GID:-}" && gid_json="$HOSTILE_GID"
  if [[ -n "$HOSTILE_UID" ]] && [[ -z "$(current_owned_cgroups || true)" ]] &&
     verify_no_uid_processes; then
    residual_uid=1
  fi
  [[ -z "$(current_owned_cgroups || true)" ]] && residual_cgroup=1

  source_sha="$(json_escape "$SOURCE_SHA")"
  repo="$(json_escape "$REPO")"
  work="$(json_escape "$WORK_ROOT")"
  test_log="$(json_escape "$TEST_LOG")"
  cleanup_log="$(json_escape "$CLEANUP_LOG")"
  preflight_log="$(json_escape "$PREFLIGHT_LOG")"
  if [[ -n "$TEST_START_EPOCH" && -n "$TEST_END_EPOCH" ]] &&
     is_uint "$TEST_START_EPOCH" && is_uint "$TEST_END_EPOCH"; then
    elapsed=$(( TEST_END_EPOCH - TEST_START_EPOCH ))
  fi
  if [[ "$CGROUP_THREADS_VERIFIED" == 1 && "${TEST_EXIT_CODE:-}" == 0 ]]; then
    cgroup_threads_marker=1
  fi
  tmp="$RESULT_PATH.tmp.$$"
  cat >"$tmp" <<EOF
{
  "schemaVersion": 1,
  "kind": "linux-hostile-isolation-native-test-result",
  "test": "$(json_escape "$TEST_NAME")",
  "repo": "$repo",
  "workRoot": "$work",
  "jobRoot": "$(json_escape "$JOB_ROOT")",
  "sourceSha": "$source_sha",
  "startedAt": "$(json_escape "$TEST_STARTED_AT")",
  "finishedAt": "$(json_escape "$TEST_FINISHED_AT")",
  "elapsedSeconds": $elapsed,
  "testRan": $TEST_RAN,
  "testExitCode": $test_code,
  "cleanupExitCode": $cleanup_status,
  "finalExitCode": $final_status,
  "temporaryUser": "$(json_escape "$HOSTILE_USER")",
  "temporaryGroup": "$(json_escape "$HOSTILE_GROUP")",
  "executionUid": $uid_json,
  "executionGid": $gid_json,
  "nativeProbeMarkers": {
    "cgroupThreadsControlVerified": $CGROUP_THREADS_VERIFIED,
    "cgroupThreadsBoundaryVerified": $cgroup_threads_marker
  },
  "residualCgroupVerified": $residual_cgroup,
  "residualIdentityProcessesVerified": $residual_uid,
  "logs": {
    "preflight": "$preflight_log",
    "test": "$test_log",
    "cleanup": "$cleanup_log"
  }
}
EOF
  mv -f -- "$tmp" "$RESULT_PATH" 2>/dev/null || {
    log_cleanup "failed to publish result.json"
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
  }
  return 0
}

cleanup() {
  local original_status="$1"
  local path residual final_status
  [[ "$CLEANUP_RUNNING" == 0 ]] || exit "$original_status"
  CLEANUP_RUNNING=1
  trap - EXIT INT TERM
  set +e

  [[ -n "$TEST_FINISHED_AT" ]] || TEST_FINISHED_AT="$(now_iso)"
  [[ -n "$TEST_END_EPOCH" ]] || TEST_END_EPOCH="$(now_epoch)"

  # Re-scan after an interrupted cargo invocation.  Only names absent from the
  # preflight snapshot are considered ours; pre-existing cgroups are never
  # touched.
  if [[ -n "$BASELINE_CGROUPS" ]]; then
    collect_owned_cgroups
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      cleanup_one_cgroup "$path" || CLEANUP_EXIT_CODE=1
    done <"$OWNED_CGROUPS"
  fi
  if [[ "$PREFLIGHT_CGROUP_CREATED" == 1 && -n "$PREFLIGHT_CGROUP" ]]; then
    cleanup_one_cgroup "$PREFLIGHT_CGROUP" || CLEANUP_EXIT_CODE=1
    PREFLIGHT_CGROUP_CREATED=0
  fi

  terminate_uid_processes
  # A process can be observed just after the first cgroup scan (for example
  # when cargo is interrupted while the Rust Drop guard is running).  Re-scan
  # after UID cleanup and retry only the newly observed job-owned children.
  if [[ -n "$BASELINE_CGROUPS" ]]; then
    collect_owned_cgroups
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      cleanup_one_cgroup "$path" || CLEANUP_EXIT_CODE=1
    done <"$OWNED_CGROUPS"
  fi
  verify_no_uid_processes || CLEANUP_EXIT_CODE=1

  if [[ "$USER_CREATED" == 1 && -n "$HOSTILE_USER" ]]; then
    if getent passwd "$HOSTILE_USER" >/dev/null 2>&1; then
      userdel "$HOSTILE_USER" >>"$CLEANUP_LOG" 2>&1 || CLEANUP_EXIT_CODE=1
    fi
    if getent passwd "$HOSTILE_USER" >/dev/null 2>&1; then
      log_cleanup "temporary user still exists after userdel: $HOSTILE_USER"
      CLEANUP_EXIT_CODE=1
    else
      USER_CREATED=0
    fi
  fi
  if [[ "$GROUP_CREATED" == 1 && -n "$HOSTILE_GROUP" ]]; then
    if getent group "$HOSTILE_GROUP" >/dev/null 2>&1; then
      groupdel "$HOSTILE_GROUP" >>"$CLEANUP_LOG" 2>&1 || CLEANUP_EXIT_CODE=1
    fi
    if getent group "$HOSTILE_GROUP" >/dev/null 2>&1; then
      log_cleanup "temporary group still exists after groupdel: $HOSTILE_GROUP"
      CLEANUP_EXIT_CODE=1
    else
      GROUP_CREATED=0
    fi
  fi

  # The home is intentionally an empty direct child of the job root.  Remove
  # it only with rmdir; never recursively remove an operator-selected path.
  if [[ -n "$HOSTILE_HOME" && -d "$HOSTILE_HOME" ]]; then
    case "$HOSTILE_HOME" in
      "$JOB_ROOT"/*) rmdir -- "$HOSTILE_HOME" >>"$CLEANUP_LOG" 2>&1 || CLEANUP_EXIT_CODE=1 ;;
      *) log_cleanup "refusing to remove unexpected identity home: $HOSTILE_HOME"; CLEANUP_EXIT_CODE=1 ;;
    esac
  fi

  residual="$(current_owned_cgroups || true)"
  if [[ -n "$residual" ]]; then
    log_cleanup "job-owned cgroup residue remains: $residual"
    CLEANUP_EXIT_CODE=1
  fi
  if [[ "$USER_CREATED" == 1 || "$GROUP_CREATED" == 1 ]]; then
    CLEANUP_EXIT_CODE=1
  fi

  final_status="$original_status"
  if [[ "$final_status" == 0 && "$CLEANUP_EXIT_CODE" != 0 ]]; then
    final_status="$CLEANUP_EXIT_CODE"
  fi
  if [[ -n "$RESULT_PATH" && -d "$JOB_ROOT" ]]; then
    write_result "$final_status" "$CLEANUP_EXIT_CODE" || {
      [[ "$final_status" == 0 ]] && final_status=1
    }
  fi
  printf 'jobRoot=%s\nresult=%s\ntestExitCode=%s\ncleanupExitCode=%s\n' \
    "$JOB_ROOT" "$RESULT_PATH" "${TEST_EXIT_CODE:-not-run}" "$CLEANUP_EXIT_CODE"
  exit "$final_status"
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --repo|-r)
        (($# >= 2)) || die "$1 requires a path"
        REPO_INPUT="$2"
        shift 2
        ;;
      --repo=*)
        REPO_INPUT="${1#*=}"
        shift
        ;;
      --work-root|-w)
        (($# >= 2)) || die "$1 requires a path"
        WORK_ROOT_INPUT="$2"
        shift 2
        ;;
      --work-root=*)
        WORK_ROOT_INPUT="${1#*=}"
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1 (use --help)"
        ;;
    esac
  done
}

preflight() {
  local uid required token
  # Non-interactive SSH shells commonly omit the Rust toolchain path.  Source
  # the standard rustup environment when neither tool is visible, then try the
  # conventional cargo/rustc locations without guessing a user-specific
  # account.  Append fallback directories rather than prepending them so an
  # intentional test wrapper (for example, a failure-path harness) remains the
  # selected cargo.
  if ! command -v cargo >/dev/null 2>&1 && ! command -v rustc >/dev/null 2>&1; then
    if [[ -f "${CARGO_HOME:-$HOME/.cargo}/env" ]]; then
      # shellcheck disable=SC1090
      . "${CARGO_HOME:-$HOME/.cargo}/env"
    fi
  fi
  if ! command -v cargo >/dev/null 2>&1 || ! command -v rustc >/dev/null 2>&1; then
    local candidate
    for candidate in "${CARGO_HOME:-$HOME/.cargo}/bin" /root/.cargo/bin; do
      if [[ -x "$candidate/cargo" || -x "$candidate/rustc" ]]; then
        case ":$PATH:" in
          *":$candidate:"*) ;;
          *) PATH="$PATH:$candidate" ;;
        esac
        export PATH
        command -v cargo >/dev/null 2>&1 && command -v rustc >/dev/null 2>&1 && break
      fi
    done
  fi
  require_command id
  require_command getent
  require_command groupadd
  require_command useradd
  require_command userdel
  require_command groupdel
  require_command ps
  require_command awk
  require_command grep
  require_command sed
  require_command tr
  require_command od
  require_command mktemp
  require_command mkdir
  require_command chmod
  require_command cat
  require_command kill
  require_command mv
  require_command rm
  require_command cargo
  require_command rustc
  require_command python3
  require_command date
  require_command sleep
  require_command rmdir

  uid="$(id -u)"
  [[ "$uid" == 0 ]] || die "Linux hostile-isolation probe must run as root (uid=$uid)"
  [[ -r /proc/self/mountinfo ]] || die "/proc/self/mountinfo is unavailable"
  grep -q ' - cgroup2 ' /proc/self/mountinfo || die "cgroup v2 mount not found"
  [[ -d "$CGROUP_ROOT" ]] || die "expected cgroup-v2 mount path is missing: $CGROUP_ROOT"
  [[ -f "$CGROUP_ROOT/cgroup.controllers" ]] || die "cgroup.controllers is missing"
  [[ -f "$CGROUP_ROOT/cgroup.subtree_control" ]] || die "cgroup.subtree_control is missing"
  [[ -w "$CGROUP_ROOT" ]] || die "cgroup-v2 root is not writable"
  [[ -f "$CGROUP_ROOT/cgroup.procs" ]] || die "cgroup.procs is missing from cgroup-v2 root"
  [[ -f "$CGROUP_ROOT/cgroup.threads" ]] || die "cgroup.threads is missing from cgroup-v2 root"
  CGROUP_CONTROLLERS="$(tr '\n' ' ' <"$CGROUP_ROOT/cgroup.controllers" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
  case " $CGROUP_CONTROLLERS " in
    *' pids '*) ;;
    *) die "the pids controller is not available (controllers: ${CGROUP_CONTROLLERS:-none})" ;;
  esac
  CGROUP_SUBTREE_CONTROLLERS="$(tr '\n' ' ' <"$CGROUP_ROOT/cgroup.subtree_control" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
  case " $CGROUP_SUBTREE_CONTROLLERS " in
    *' pids '*) ;;
    *) die "the pids controller is not enabled for child cgroups (subtree: ${CGROUP_SUBTREE_CONTROLLERS:-none})" ;;
  esac
  log_preflight "uid=0; cgroupRoot=$CGROUP_ROOT; controllers=$CGROUP_CONTROLLERS; subtree=$CGROUP_SUBTREE_CONTROLLERS"

  [[ -d "$REPO" ]] || die "repository directory does not exist: $REPO"
  [[ -f "$REPO/Cargo.toml" ]] || die "repository has no Cargo.toml: $REPO"
  GUARD_SCRIPT="$REPO/scripts/Test-Issue5Selector.py"
  [[ -f "$GUARD_SCRIPT" ]] || die "Issue #5 selector guard is missing: $GUARD_SCRIPT"
  if ! (cd "$REPO" && cargo metadata --no-deps --format-version 1 --manifest-path "$REPO/Cargo.toml") \
    >/dev/null 2>>"$PREFLIGHT_LOG"; then
    die "cargo metadata failed; see $PREFLIGHT_LOG"
  fi
  log_preflight "cargo metadata passed for $REPO"

  snapshot_cgroups
  token="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || true)"
  [[ "$token" =~ ^[0-9a-f]+$ && ${#token} -ge 8 ]] || token="$(date +%s%N)$$$RANDOM"
  token="${token:0:16}"
  PREFLIGHT_CGROUP="$CGROUP_ROOT/cyc-hostile-probe-$token"
  [[ ! -e "$PREFLIGHT_CGROUP" ]] || die "preflight cgroup name collision: $PREFLIGHT_CGROUP"
  mkdir -- "$PREFLIGHT_CGROUP" || die "cannot create a writable cgroup-v2 child: $PREFLIGHT_CGROUP"
  PREFLIGHT_CGROUP_CREATED=1
  for required in cgroup.procs cgroup.threads cgroup.events cgroup.kill pids.max; do
    [[ -f "$PREFLIGHT_CGROUP/$required" ]] || die "new cgroup lacks required controller file: $required"
  done
  [[ -z "$(cat "$PREFLIGHT_CGROUP/cgroup.threads" 2>/dev/null || true)" ]] ||
    die "new cgroup unexpectedly contains cgroup.threads entries"
  CGROUP_THREADS_VERIFIED=1
  printf '64\n' >"$PREFLIGHT_CGROUP/pids.max" || die "cannot write pids.max in cgroup-v2 child"
  cleanup_one_cgroup "$PREFLIGHT_CGROUP" || die "preflight cgroup cleanup failed"
  PREFLIGHT_CGROUP_CREATED=0
  log_preflight "created, configured, checked cgroup.threads, killed, and removed disposable cgroup"

}

create_identity() {
  local token shell_path group_gid account_gid
  token="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || true)"
  [[ "$token" =~ ^[0-9a-f]+$ && ${#token} -ge 8 ]] || token="$(date +%s%N)$$$RANDOM"
  token="${token:0:16}"
  HOSTILE_GROUP="cyciso_g_$token"
  HOSTILE_USER="cyciso_u_$token"
  HOSTILE_HOME="$JOB_ROOT/identity-home"
  mkdir -- "$HOSTILE_HOME"
  chmod 700 "$HOSTILE_HOME"

  getent group "$HOSTILE_GROUP" >/dev/null 2>&1 && die "temporary group collision: $HOSTILE_GROUP"
  getent passwd "$HOSTILE_USER" >/dev/null 2>&1 && die "temporary user collision: $HOSTILE_USER"
  groupadd --system "$HOSTILE_GROUP" >>"$PREFLIGHT_LOG" 2>&1 || die "groupadd failed"
  GROUP_CREATED=1
  shell_path="$(command -v nologin 2>/dev/null || printf '/usr/sbin/nologin')"
  useradd --system --no-create-home --home-dir "$HOSTILE_HOME" --shell "$shell_path" \
    --gid "$HOSTILE_GROUP" "$HOSTILE_USER" >>"$PREFLIGHT_LOG" 2>&1 || die "useradd failed"
  USER_CREATED=1

  HOSTILE_UID="$(id -u "$HOSTILE_USER")"
  HOSTILE_GID="$(id -g "$HOSTILE_USER")"
  group_gid="$(getent group "$HOSTILE_GROUP" | awk -F: '{print $3}')"
  account_gid="$HOSTILE_GID"
  is_uint "$HOSTILE_UID" && (( HOSTILE_UID > 0 )) || die "temporary uid is invalid: $HOSTILE_UID"
  is_uint "$HOSTILE_GID" && (( HOSTILE_GID > 0 )) || die "temporary gid is invalid: $HOSTILE_GID"
  [[ "$group_gid" == "$account_gid" ]] || die "temporary account primary gid mismatch"
  export CYC_TEST_HOSTILE_LIVE_UID="$HOSTILE_UID"
  export CYC_TEST_HOSTILE_LIVE_GID="$HOSTILE_GID"
  log_preflight "temporary system identity created uid=$HOSTILE_UID gid=$HOSTILE_GID"
}

run_native_test() {
  local cargo_target
  cargo_target="$JOB_ROOT/target"
  export CARGO_TARGET_DIR="$cargo_target"
  export CARGO_TERM_COLOR=never
  TEST_STARTED_AT="$(now_iso)"
  TEST_START_EPOCH="$(now_epoch)"
  TEST_RAN=1
  set +e
  (
    cd "$REPO" || exit 125
    python3 "$GUARD_SCRIPT" --repo "$REPO" --platform linux
  ) >"$TEST_LOG" 2>&1
  TEST_EXIT_CODE=$?
  set -e
  TEST_FINISHED_AT="$(now_iso)"
  TEST_END_EPOCH="$(now_epoch)"
  collect_owned_cgroups
  log_preflight "native test exit code: $TEST_EXIT_CODE"
}

main() {
  parse_args "$@"

  REPO_INPUT="${REPO_INPUT:-$PWD}"
  WORK_ROOT_INPUT="${WORK_ROOT_INPUT:-${TMPDIR:-/tmp}/clusteryourcodex-linux-hostile-isolation}"
  reject_control_chars "$REPO_INPUT"
  reject_control_chars "$WORK_ROOT_INPUT"
  [[ "$WORK_ROOT_INPUT" == /* ]] || die "--work-root must be an absolute path"
  if [[ "$REPO_INPUT" != /* ]]; then
    REPO_INPUT="$(cd -- "$REPO_INPUT" 2>/dev/null && pwd -P)" || die "cannot resolve repository path: $REPO_INPUT"
  fi
  [[ -d "$REPO_INPUT" ]] || die "repository directory does not exist: $REPO_INPUT"
  REPO="$(cd "$REPO_INPUT" && pwd -P)"
  mkdir -p -- "$WORK_ROOT_INPUT"
  WORK_ROOT="$(cd "$WORK_ROOT_INPUT" && pwd -P)"
  [[ "$WORK_ROOT" != "/" ]] || die "refusing to use filesystem root as --work-root"
  case "$WORK_ROOT" in
    "$CGROUP_ROOT"|"$CGROUP_ROOT"/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*)
      die "refusing a kernel pseudo-filesystem as --work-root: $WORK_ROOT" ;;
  esac

  JOB_ROOT="$(mktemp -d "$WORK_ROOT/linux-hostile.XXXXXX")"
  chmod 700 "$JOB_ROOT"
  LOG_DIR="$JOB_ROOT/logs"
  STATE_DIR="$JOB_ROOT/.state"
  mkdir -- "$LOG_DIR" "$STATE_DIR"
  MANIFEST_PATH="$JOB_ROOT/manifest.json"
  RESULT_PATH="$JOB_ROOT/result.json"
  TEST_LOG="$LOG_DIR/native-test.log"
  CLEANUP_LOG="$LOG_DIR/cleanup.log"
  PREFLIGHT_LOG="$LOG_DIR/preflight.log"
  BASELINE_CGROUPS="$STATE_DIR/baseline-cgroups.txt"
  OWNED_CGROUPS="$STATE_DIR/owned-cgroups.txt"
  : >"$CLEANUP_LOG"
  : >"$PREFLIGHT_LOG"
  trap 'cleanup "$?"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if command -v git >/dev/null 2>&1; then
    SOURCE_SHA="$(git -C "$REPO" rev-parse --verify HEAD 2>/dev/null || true)"
  fi
  preflight
  create_identity
  write_manifest
  run_native_test

  if (( TEST_EXIT_CODE != 0 )); then
    printf 'Native test failed; inspect %s\n' "$TEST_LOG" >&2
  else
    printf 'Native test passed; cleanup and residue verification are running.\n'
  fi
  # The EXIT trap publishes the result and performs all cleanup.
  return "$TEST_EXIT_CODE"
}

main "$@"
