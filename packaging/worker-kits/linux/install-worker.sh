#!/usr/bin/env bash
# The SSH fixed-command surface invokes POSIX lifecycle scripts as
# `/bin/sh <script> -- <args>`. Re-enter Bash before any Bash-only syntax and
# consume the fixed separator so the first lifecycle argument remains action.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /bin/bash "$0" "$@"
fi
set -euo pipefail
umask 077
if [[ "${1:-}" == -- ]]; then shift; fi

SCHEMA='cyc.dev/linux-worker-install/v1'
KIT_SCHEMA='cyc.dev/worker-kit/v1'
SIGNATURE_SCHEMA='cyc.dev/worker-kit-signature/v1'
PUBLISHER_KEY_ID='cyc-release-2026-02'
PUBLISHER_PUBLIC_KEY_BASE64='__CYC_PUBLISHER_PUBLIC_KEY_BASE64__'
SERVICE_NAME='clusteryourcodex-worker.service'
MARKER_NAME='.clusteryourcodex-worker-owned'
EXIT_USER_SYSTEMD_UNAVAILABLE=78
TRANSACTION_NAME='.repair-transaction'
TRANSACTION_SCHEMA='cyc.dev/linux-worker-repair-transaction/v1'
TRANSACTION_TOMBSTONE_NAME='.repair-transaction.tombstone'
TRANSACTION_TOMBSTONE_SCHEMA='cyc.dev/linux-worker-repair-tombstone/v1'
TRANSACTION_TOMBSTONE_RETIRED="${TRANSACTION_TOMBSTONE_SCHEMA}:retired"
TRANSACTION_RETIRE_NAME='.repair-transaction.removing'

action="${1:-install}"
if [[ $# -gt 0 ]]; then shift; fi
bundle_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
install_root="${HOME}/.local/lib/clusteryourcodex-worker"
data_root="${XDG_DATA_HOME:-${HOME}/.local/share}/clusteryourcodex/worker"
workspace_root="${XDG_DATA_HOME:-${HOME}/.local/share}/clusteryourcodex/worker/workspace"
enrollment_file=''
scope='auto'
allow_on_battery=0
pair_only=0
purge_data=0
failure_injection='none'

usage() {
  cat <<'EOF'
Usage: install-worker.sh <install|repair|uninstall> [options]
  --bundle-root PATH
  --install-root PATH
  --data-root PATH
  --workspace-root PATH
  --enrollment PATH
  --scope auto|user|system
  --allow-on-battery
  --pair-only
  --purge-data
  --failure-injection none|after-pair|after-service-registration|before-manifest-write|after-marker-removal
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-root) bundle_root="$2"; shift 2 ;;
    --install-root) install_root="$2"; shift 2 ;;
    --data-root) data_root="$2"; shift 2 ;;
    --workspace-root) workspace_root="$2"; shift 2 ;;
    --enrollment) enrollment_file="$2"; shift 2 ;;
    --scope) scope="$2"; shift 2 ;;
    --allow-on-battery) allow_on_battery=1; shift ;;
    --pair-only) pair_only=1; shift ;;
    --purge-data) purge_data=1; shift ;;
    --failure-injection) failure_injection="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$action" in install|repair|uninstall) ;; *) usage >&2; exit 2 ;; esac
case "$scope" in auto|user|system) ;; *) printf 'Invalid scope\n' >&2; exit 2 ;; esac
case "$failure_injection" in
  none|after-pair|after-service-registration|before-manifest-write|after-marker-removal) ;;
  *) printf 'Invalid failure injection point\n' >&2; exit 2 ;;
esac
if [[ "$scope" == auto ]]; then
  if [[ "$(id -u)" -eq 0 ]]; then scope=system; else scope=user; fi
fi
if [[ "$scope" == system && "$(id -u)" -ne 0 ]]; then
  printf 'System scope requires root.\n' >&2
  exit 1
fi

normalize_path() {
  local value="$1"
  local control_pattern=$'[\001-\037\177]'
  [[ ! "$value" =~ $control_pattern ]] || {
    printf 'Control characters are not allowed in paths.\n' >&2
    return 1
  }
  [[ "$value" == /* ]] || value="${PWD}/${value}"
  realpath -ms -- "$value"
}

verify_worker_kit_signature() {
  local manifest_path="$1"
  local signature_path="$2"
  local kit_root="$3"
  local expected_target="$4"
  local expected_arch="$5"
  local python_command=''
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; assert sys.version_info >= (3, 8)' >/dev/null 2>&1; then
      python_command="$candidate"
      break
    fi
  done
  [[ -n "$python_command" ]] || {
    printf 'Python 3.8+ is required for worker-kit Ed25519 verification.\n' >&2
    return 1
  }
  "$python_command" - "$PUBLISHER_PUBLIC_KEY_BASE64" "$PUBLISHER_KEY_ID" \
    "$manifest_path" "$signature_path" "$kit_root" "$expected_target" "$expected_arch" <<'PY'
import base64
import hashlib
import json
import os
import stat
import sys

Q = 2**255 - 19
L = 2**252 + 27742317777372353535851937790883648493
D = (-121665 * pow(121666, Q - 2, Q)) % Q
I = pow(2, (Q - 1) // 4, Q)
IDENTITY = (0, 1, 1, 0)


def decode_point(encoded):
    if len(encoded) != 32:
        raise ValueError('point length')
    raw = bytearray(encoded)
    sign = raw[31] >> 7
    raw[31] &= 0x7f
    y = int.from_bytes(raw, 'little')
    if y >= Q:
        raise ValueError('non-canonical point')
    y2 = y * y % Q
    x2 = (y2 - 1) * pow(D * y2 + 1, Q - 2, Q) % Q
    x = pow(x2, (Q + 3) // 8, Q)
    if (x * x - x2) % Q:
        x = x * I % Q
    if (x * x - x2) % Q or (x == 0 and sign):
        raise ValueError('invalid point')
    if (x & 1) != sign:
        x = Q - x
    return (x, y, 1, x * y % Q)


def point_add(p, q):
    x1, y1, z1, t1 = p
    x2, y2, z2, t2 = q
    a = (y1 - x1) * (y2 - x2) % Q
    b = (y1 + x1) * (y2 + x2) % Q
    c = 2 * D * t1 * t2 % Q
    d = 2 * z1 * z2 % Q
    e, f, g, h = (b - a) % Q, (d - c) % Q, (d + c) % Q, (b + a) % Q
    return (e * f % Q, g * h % Q, f * g % Q, e * h % Q)


def point_double(p):
    x, y, z, _ = p
    a, b, c = x * x % Q, y * y % Q, 2 * z * z % Q
    d = -a % Q
    e = ((x + y) * (x + y) - a - b) % Q
    g, f, h = (d + b) % Q, (d + b - c) % Q, (d - b) % Q
    return (e * f % Q, g * h % Q, f * g % Q, e * h % Q)


def point_multiply(point, scalar):
    result = IDENTITY
    while scalar:
        if scalar & 1:
            result = point_add(result, point)
        point = point_double(point)
        scalar >>= 1
    return result


def point_equal(left, right):
    return ((left[0] * right[2] - right[0] * left[2]) % Q == 0 and
            (left[1] * right[2] - right[1] * left[2]) % Q == 0)


def prime_order(point):
    return not point_equal(point, IDENTITY) and point_equal(point_multiply(point, L), IDENTITY)


def canonical_json(path, ordered_fields):
    raw = open(path, 'rb').read()
    if not raw.endswith(b'\n') or b'\r' in raw:
        raise ValueError('JSON is not LF terminated')
    value = json.loads(raw.decode('utf-8'))
    if not isinstance(value, dict) or list(value) != ordered_fields:
        raise ValueError('JSON field order or set is invalid')
    canonical = (json.dumps(value, ensure_ascii=False, separators=(',', ':')) + '\n').encode('utf-8')
    if raw != canonical:
        raise ValueError('JSON is not canonical')
    return raw, value


try:
    (public_key_text, key_id, manifest_path, signature_path,
     kit_root, expected_target, expected_arch) = sys.argv[1:]
    expected_names = {
        'cyc-worker', 'install-worker.sh', 'worker-kit.json',
        'worker-kit.sig', 'SHA256SUMS',
    }
    entries = list(os.scandir(kit_root))
    if {entry.name for entry in entries} != expected_names or len(entries) != 5:
        raise ValueError('worker-kit file set')
    for entry in entries:
        mode = entry.stat(follow_symlinks=False).st_mode
        if not stat.S_ISREG(mode) or entry.is_symlink():
            raise ValueError('worker-kit filesystem entry')

    public_key = base64.b64decode(public_key_text, validate=True)
    if len(public_key) != 32 or base64.b64encode(public_key).decode('ascii') != public_key_text:
        raise ValueError('publisher trust root')
    manifest_raw, manifest = canonical_json(
        manifest_path,
        ['schemaVersion', 'product', 'version', 'target', 'os', 'architecture', 'files'],
    )
    if (manifest['schemaVersion'] != 'cyc.dev/worker-kit/v1' or
            manifest['product'] != 'ClusterYourCodex Managed Worker' or
            manifest['target'] != expected_target or manifest['os'] != 'linux' or
            manifest['architecture'] != expected_arch):
        raise ValueError('manifest target')
    expected_files = [('cyc-worker', 'worker'), ('install-worker.sh', 'lifecycle')]
    if not isinstance(manifest['files'], list) or len(manifest['files']) != len(expected_files):
        raise ValueError('manifest files')
    for entry, (expected_path, expected_role) in zip(manifest['files'], expected_files):
        if (not isinstance(entry, dict) or
                list(entry) != ['path', 'sizeBytes', 'sha256', 'role'] or
                entry['path'] != expected_path or entry['role'] != expected_role or
                not isinstance(entry['sizeBytes'], int) or isinstance(entry['sizeBytes'], bool) or
                entry['sizeBytes'] <= 0 or
                not isinstance(entry['sha256'], str) or
                len(entry['sha256']) != 64 or
                any(char not in '0123456789abcdef' for char in entry['sha256'])):
            raise ValueError('manifest file fields')
        path = os.path.join(kit_root, expected_path)
        raw = open(path, 'rb').read()
        if (entry['sizeBytes'] != len(raw) or
                entry['sha256'] != hashlib.sha256(raw).hexdigest()):
            raise ValueError('manifest payload digest')
    _, envelope = canonical_json(
        signature_path,
        ['schemaVersion', 'algorithm', 'keyId', 'signedObject', 'manifestSha256', 'signature'],
    )
    if (envelope['schemaVersion'] != 'cyc.dev/worker-kit-signature/v1' or
            envelope['algorithm'] != 'Ed25519' or envelope['keyId'] != key_id or
            envelope['signedObject'] != 'worker-kit.json' or
            envelope['manifestSha256'] != hashlib.sha256(manifest_raw).hexdigest()):
        raise ValueError('signature envelope')
    signature = base64.b64decode(envelope['signature'], validate=True)
    if len(signature) != 64 or base64.b64encode(signature).decode('ascii') != envelope['signature']:
        raise ValueError('signature encoding')
    r_encoded, s_encoded = signature[:32], signature[32:]
    scalar = int.from_bytes(s_encoded, 'little')
    if scalar >= L:
        raise ValueError('signature scalar')
    public_point, r_point = decode_point(public_key), decode_point(r_encoded)
    if not prime_order(public_point) or not prime_order(r_point):
        raise ValueError('signature subgroup')
    h = int.from_bytes(hashlib.sha512(r_encoded + public_key + manifest_raw).digest(), 'little') % L
    base_point = decode_point(bytes([0x58]) + bytes([0x66]) * 31)
    if not point_equal(point_multiply(base_point, scalar), point_add(r_point, point_multiply(public_point, h))):
        raise ValueError('signature mismatch')
except Exception:
    print('Worker-kit publisher signature verification failed.', file=sys.stderr)
    sys.exit(1)
PY
}

bundle_root="$(normalize_path "$bundle_root")"
install_root="$(normalize_path "$install_root")"
data_root="$(normalize_path "$data_root")"
workspace_root="$(normalize_path "$workspace_root")"
if [[ -n "$enrollment_file" ]]; then enrollment_file="$(normalize_path "$enrollment_file")"; fi
transaction_tombstone_path="${data_root}/${TRANSACTION_TOMBSTONE_NAME}"
transaction_retired_root="${data_root}/${TRANSACTION_RETIRE_NAME}"

reject_link_chain() {
  local value="$1" current
  current="$(realpath -ms -- "$value")"
  while [[ "$current" != / ]]; do
    if [[ -L "$current" ]]; then printf 'Symlink path rejected: %s\n' "$current" >&2; return 1; fi
    current="$(dirname -- "$current")"
  done
}

private_dir() {
  reject_link_chain "$1"
  install -d -m 0700 -- "$1"
  [[ -d "$1" && ! -L "$1" ]] || { printf 'Private directory invalid: %s\n' "$1" >&2; return 1; }
  chmod 0700 -- "$1"
}

systemd_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//%/%%}"
  printf '"%s"' "$value"
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

service_ctl_for_scope() {
  local requested_scope="$1"
  shift
  if [[ "$requested_scope" == system ]]; then systemctl "$@"; else systemctl --user "$@"; fi
}

service_ctl() {
  service_ctl_for_scope "$scope" "$@"
}

fail_user_systemd_unavailable() {
  printf '%s\n' \
    '[CYC-LINUX-USER-SYSTEMD-UNAVAILABLE] User-scope service activation requires a working systemd user manager and enabled linger. Re-run as root with --scope system.' \
    >&2
  exit "$EXIT_USER_SYSTEMD_UNAVAILABLE"
}

require_user_systemd_ready() {
  local current_user linger_enabled_here linger_state runtime_dir
  [[ "$scope" == user ]] || return 0

  command -v systemctl >/dev/null 2>&1 || fail_user_systemd_unavailable
  command -v loginctl >/dev/null 2>&1 || fail_user_systemd_unavailable
  current_user="$(id -un)"
  linger_enabled_here=0

  linger_state="$(loginctl show-user "$current_user" --property=Linger --value 2>/dev/null || true)"
  if [[ "$linger_state" != yes ]]; then
    loginctl enable-linger "$current_user" >/dev/null 2>&1 || fail_user_systemd_unavailable
    linger_enabled_here=1
    linger_state="$(loginctl show-user "$current_user" --property=Linger --value 2>/dev/null || true)"
    if [[ "$linger_state" != yes ]]; then
      loginctl disable-linger "$current_user" >/dev/null 2>&1 || true
      fail_user_systemd_unavailable
    fi
  fi

  # SSH sessions do not always export XDG_RUNTIME_DIR even when linger has
  # started the per-user manager. Use the canonical runtime directory only
  # when it is a real directory owned by this user.
  if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
    runtime_dir="/run/user/$(id -u)"
    if [[ -d "$runtime_dir" && ! -L "$runtime_dir" && -O "$runtime_dir" ]]; then
      export XDG_RUNTIME_DIR="$runtime_dir"
    fi
  fi
  if ! systemctl --user show-environment >/dev/null 2>&1; then
    if [[ "$linger_enabled_here" -eq 1 ]]; then
      loginctl disable-linger "$current_user" >/dev/null 2>&1 || true
    fi
    fail_user_systemd_unavailable
  fi
}

service_path_for_scope() {
  local requested_scope="$1" path
  if [[ "$requested_scope" == system ]]; then
    path="/etc/systemd/system/${SERVICE_NAME}"
  else
    path="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user/${SERVICE_NAME}"
  fi
  normalize_path "$path"
}

service_path() {
  service_path_for_scope "$scope"
}

remove_service_for_scope() {
  local requested_scope="$1" unit
  unit="$(service_path_for_scope "$requested_scope")"
  service_ctl_for_scope "$requested_scope" disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  if [[ -f "$unit" && ! -L "$unit" ]]; then rm -f -- "$unit"; fi
  service_ctl_for_scope "$requested_scope" daemon-reload >/dev/null 2>&1 || true
}

remove_service() {
  remove_service_for_scope "$scope"
}

install_service() {
  local unit unit_dir tmp wanted_by
  unit="$(service_path)"
  unit_dir="$(dirname -- "$unit")"
  if [[ "$scope" == system ]]; then
    reject_link_chain "$unit_dir"
    if [[ ! -d "$unit_dir" ]]; then install -d -m 0755 -- "$unit_dir"; fi
    wanted_by='multi-user.target'
  else
    require_user_systemd_ready
    private_dir "$unit_dir"
    wanted_by='default.target'
  fi
  [[ ! -L "$unit_dir" && ! -L "$unit" ]] || { printf 'Service path symlink rejected.\n' >&2; return 1; }
  tmp="${unit}.new.$$"
  cat >"$tmp" <<EOF
[Unit]
Description=ClusterYourCodex managed worker
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$(systemd_quote "${install_root}/cyc-worker") run --config $(systemd_quote "${data_root}/config.json")
WorkingDirectory=$(systemd_quote "$workspace_root")
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
KillMode=control-group

[Install]
WantedBy=${wanted_by}
EOF
  chmod 0600 -- "$tmp"
  mv -f -- "$tmp" "$unit"
  service_ctl daemon-reload
  service_ctl enable --now "$SERVICE_NAME"
  service_ctl is-active --quiet "$SERVICE_NAME"
}

assert_transaction_tree_safe() {
  local transaction_root="$1" expected
  expected="${data_root}/${TRANSACTION_NAME}"
  [[ "$transaction_root" == "$expected" && -d "$transaction_root" && ! -L "$transaction_root" ]] || {
    printf 'Worker repair transaction escaped the owned data root.\n' >&2
    return 1
  }
  if find "$transaction_root" -xdev -type l -print -quit | grep -q .; then
    printf 'Worker repair transaction contains a symlink.\n' >&2
    return 1
  fi
}

remove_transaction() {
  local transaction_root="$1" retired_root="$transaction_retired_root"
  if [[ ! -e "$transaction_root" && ! -L "$transaction_root" ]]; then
    # A prior process may have atomically retired the journal and been
    # interrupted while removing the private retirement tree. Finish that
    # idempotently before reporting the transaction as gone.
    remove_transaction_retirement "$retired_root"
    return 0
  fi
  assert_transaction_tree_safe "$transaction_root"
  if [[ -e "$retired_root" || -L "$retired_root" ]]; then
    remove_transaction_retirement "$retired_root"
  fi
  # Recursive deletion is not atomic. Move the journal out of its authoritative
  # name first, so an interruption can never leave a partially deleted journal
  # that looks recoverable on the next invocation.
  mv -T -- "$transaction_root" "$retired_root"
  assert_transaction_retirement_tree_safe "$retired_root"
  if [[ -e "$transaction_tombstone_path" || -L "$transaction_tombstone_path" ]]; then
    # Validate the complete journal once, then publish the retired state in the
    # sidecar before beginning recursive deletion. A later re-entry can safely
    # finish deleting a partially removed retirement tree.
    if ! mark_rollback_tombstone_retired; then return 1; fi
  fi
  remove_transaction_retirement "$retired_root"
}

assert_transaction_retirement_tree_safe() {
  local value="$1"
  [[ "$value" == "$transaction_retired_root" && -d "$value" && ! -L "$value" ]] || {
    printf 'Worker repair transaction retirement path escaped the owned data root.\n' >&2
    return 1
  }
  if find "$value" -xdev -type l -print -quit | grep -q .; then
    printf 'Worker repair transaction retirement tree contains a symlink.\n' >&2
    return 1
  fi
}

remove_transaction_retirement() {
  local value="$1"
  [[ ! -e "$value" && ! -L "$value" ]] && return 0
  assert_transaction_retirement_tree_safe "$value"
  rm -rf --one-file-system -- "$value"
}

rollback_tombstone_contents_valid() {
  local raw
  [[ -f "$transaction_tombstone_path" && ! -L "$transaction_tombstone_path" ]] || return 1
  raw="$(cat -- "$transaction_tombstone_path")" || return 1
  [[ "$raw" == "$TRANSACTION_TOMBSTONE_SCHEMA" || "$raw" == "$(retired_tombstone_value)" ]]
}

rollback_tombstone_valid_for_transaction() {
  local marker_state
  assert_transaction_tree_safe "$transaction_root" || return 1
  [[ -f "$transaction_tombstone_path" && ! -L "$transaction_tombstone_path" ]] || return 1
  [[ "$(cat -- "$transaction_tombstone_path")" == "$TRANSACTION_TOMBSTONE_SCHEMA" ]] || return 1
  [[ -f "$transaction_root/marker-existed" && ! -L "$transaction_root/marker-existed" ]] || return 1
  marker_state="$(cat -- "$transaction_root/marker-existed")" || return 1
  [[ "$marker_state" == 0 ]] || return 1
  [[ ! -e "$transaction_root/committed" && ! -L "$transaction_root/committed" ]]
}

rollback_tombstone_is_retired() {
  local raw
  raw="$(cat -- "$transaction_tombstone_path")" || return 1
  [[ "$raw" == "$(retired_tombstone_value)" ]]
}

retired_tombstone_value() {
  printf '%s:journal=%s:uid=%s:marker-existed=0:committed=0' \
    "$TRANSACTION_TOMBSTONE_RETIRED" "$TRANSACTION_SCHEMA" "$(id -u)"
}

validate_retired_transaction_identity() {
  assert_transaction_retirement_tree_safe "$transaction_retired_root" || return 1
  [[ -f "$transaction_retired_root/schema" && ! -L "$transaction_retired_root/schema" &&
     "$(cat -- "$transaction_retired_root/schema")" == "$TRANSACTION_SCHEMA" ]] || return 1
  [[ -f "$transaction_retired_root/installer-uid" && ! -L "$transaction_retired_root/installer-uid" ]] || return 1
  [[ "$(cat -- "$transaction_retired_root/installer-uid")" == "$(id -u)" ]]
}

validate_retired_transaction() {
  local marker_state
  validate_retired_transaction_identity || return 1
  [[ -f "$transaction_retired_root/marker-existed" && ! -L "$transaction_retired_root/marker-existed" ]] || return 1
  marker_state="$(cat -- "$transaction_retired_root/marker-existed")" || return 1
  [[ "$marker_state" == 0 ]] || return 1
  [[ ! -e "$transaction_retired_root/committed" && ! -L "$transaction_retired_root/committed" ]]
}

mark_rollback_tombstone_retired() {
  local temporary
  rollback_tombstone_contents_valid || {
    printf 'Worker repair rollback tombstone is invalid.\n' >&2
    return 1
  }
  rollback_tombstone_is_retired && return 0
  validate_retired_transaction || {
    printf 'Worker repair retired transaction state is invalid.\n' >&2
    return 1
  }
  temporary="${transaction_tombstone_path}.new.$$"
  [[ ! -e "$temporary" && ! -L "$temporary" ]] || {
    printf 'Worker repair rollback tombstone staging path already exists.\n' >&2
    return 1
  }
  if ! retired_tombstone_value >"$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  if ! chmod 0600 -- "$temporary" || ! mv -f -- "$temporary" "$transaction_tombstone_path"; then
    rm -f -- "$temporary"
    return 1
  fi
}

write_rollback_tombstone() {
  local temporary
  if [[ -e "$transaction_tombstone_path" || -L "$transaction_tombstone_path" ]]; then
    rollback_tombstone_valid_for_transaction || {
      printf 'Worker repair rollback tombstone is invalid.\n' >&2
      return 1
    }
    return 0
  fi
  temporary="${transaction_tombstone_path}.new.$$"
  [[ ! -e "$temporary" && ! -L "$temporary" ]] || {
    printf 'Worker repair rollback tombstone staging path already exists.\n' >&2
    return 1
  }
  if ! printf '%s\n' "$TRANSACTION_TOMBSTONE_SCHEMA" >"$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  if ! chmod 0600 -- "$temporary" || ! mv -f -- "$temporary" "$transaction_tombstone_path"; then
    rm -f -- "$temporary"
    return 1
  fi
  rollback_tombstone_valid_for_transaction || {
    printf 'Worker repair rollback tombstone could not be validated.\n' >&2
    return 1
  }
}

remove_rollback_tombstone() {
  [[ ! -e "$transaction_tombstone_path" && ! -L "$transaction_tombstone_path" ]] && return 0
  rollback_tombstone_contents_valid || {
    printf 'Worker repair rollback tombstone is invalid.\n' >&2
    return 1
  }
  rm -f -- "$transaction_tombstone_path"
}

manifest_scope_or_current() {
  local detected=''
  if [[ -f "$install_manifest" && ! -L "$install_manifest" ]]; then
    detected="$(sed -n 's/.*"scope"[[:space:]]*:[[:space:]]*"\(user\|system\)".*/\1/p' "$install_manifest" | head -n 1)"
  fi
  if [[ "$detected" == user || "$detected" == system ]]; then printf '%s' "$detected"; else printf '%s' "$scope"; fi
}

validate_owned_manifest() {
  local raw byte_count expected recorded_scope
  if [[ ! -f "$install_manifest" || -L "$install_manifest" ]]; then
    printf 'Owned worker install manifest is missing or unsafe.\n' >&2
    return 1
  fi
  byte_count="$(wc -c <"$install_manifest" | tr -d '[:space:]')"
  if [[ ! "$byte_count" =~ ^[0-9]+$ || "$byte_count" -le 0 || "$byte_count" -gt 1048576 ]]; then
    printf 'Owned worker install manifest is not a bounded normal file.\n' >&2
    return 1
  fi
  raw="$(cat -- "$install_manifest")"
  if [[ "$raw" == *$'\n'* || "$raw" == *$'\r'* ]]; then
    printf 'Owned worker install manifest is not a single-line record.\n' >&2
    return 1
  fi
  [[ "$raw" == *"\"schemaVersion\":\"${SCHEMA}\""* ]] || {
    printf 'Owned worker install manifest has an unexpected schema.\n' >&2
    return 1
  }
  expected="$(json_escape "$install_root")"
  [[ "$raw" == *"\"installRoot\":\"${expected}\""* ]] || {
    printf 'Installer paths do not match the existing owned installation.\n' >&2
    return 1
  }
  expected="$(json_escape "$data_root")"
  [[ "$raw" == *"\"dataRoot\":\"${expected}\""* ]] || {
    printf 'Installer paths do not match the existing owned installation.\n' >&2
    return 1
  }
  expected="$(json_escape "$workspace_root")"
  [[ "$raw" == *"\"workspaceRoot\":\"${expected}\""* ]] || {
    printf 'Installer paths do not match the existing owned installation.\n' >&2
    return 1
  }
  recorded_scope="$(manifest_scope_or_current)"
  expected="$(json_escape "$(service_path_for_scope "$recorded_scope")")"
  [[ "$raw" == *"\"servicePath\":\"${expected}\""* ]] || {
    printf 'Installer service path does not match the existing owned installation.\n' >&2
    return 1
  }
}

begin_transaction() {
  local transaction_root="$1" staging old_scope old_unit candidate
  [[ ! -e "$transaction_root" && ! -L "$transaction_root" ]] || {
    printf 'A worker repair transaction is already present.\n' >&2
    return 1
  }
  staging="${transaction_root}.new.$$"
  [[ ! -e "$staging" && ! -L "$staging" ]] || { printf 'Worker repair staging path already exists.\n' >&2; return 1; }
  old_scope="$(manifest_scope_or_current)"
  old_unit="$(service_path_for_scope "$old_scope")"
  if ! (
    set -euo pipefail
    install -d -m 0700 -- "$staging" "$staging/identity"
    printf '%s\n' "$TRANSACTION_SCHEMA" >"$staging/schema"
    printf '%s\n' "$old_scope" >"$staging/old-scope"
    printf '%s\n' "$(id -u)" >"$staging/installer-uid"
    printf '%s\n' "$installation_owned_before" >"$staging/marker-existed"
    chmod 0600 -- "$staging/schema" "$staging/old-scope" "$staging/installer-uid" "$staging/marker-existed"

    if [[ -f "$worker_path" && ! -L "$worker_path" ]]; then
      install -m 0700 -- "$worker_path" "$staging/cyc-worker"
      : >"$staging/binary-existed"
    elif [[ -e "$worker_path" || -L "$worker_path" ]]; then
      printf 'Existing worker binary is unsafe.\n' >&2
      exit 1
    fi

    for candidate in "$data_root"/config.* "$data_root"/*.credential; do
      [[ -e "$candidate" || -L "$candidate" ]] || continue
      [[ -f "$candidate" && ! -L "$candidate" ]] || { printf 'Worker identity storage is unsafe.\n' >&2; exit 1; }
      cp -p -- "$candidate" "$staging/identity/$(basename -- "$candidate")"
      chmod 0600 -- "$staging/identity/$(basename -- "$candidate")"
    done

    if [[ -f "$install_manifest" && ! -L "$install_manifest" ]]; then
      cp -p -- "$install_manifest" "$staging/install-manifest.json"
      chmod 0600 -- "$staging/install-manifest.json"
      : >"$staging/manifest-existed"
    elif [[ -e "$install_manifest" || -L "$install_manifest" ]]; then
      printf 'Existing install manifest is unsafe.\n' >&2
      exit 1
    fi

    if [[ -f "$old_unit" && ! -L "$old_unit" ]]; then
      cp -p -- "$old_unit" "$staging/service.unit"
      chmod 0600 -- "$staging/service.unit"
      : >"$staging/unit-existed"
      if service_ctl_for_scope "$old_scope" is-enabled --quiet "$SERVICE_NAME" >/dev/null 2>&1; then : >"$staging/service-enabled"; fi
      if service_ctl_for_scope "$old_scope" is-active --quiet "$SERVICE_NAME" >/dev/null 2>&1; then : >"$staging/service-active"; fi
    elif [[ -e "$old_unit" || -L "$old_unit" ]]; then
      printf 'Existing service unit is unsafe.\n' >&2
      exit 1
    fi
  ); then
    if [[ -d "$staging" && ! -L "$staging" ]]; then rm -rf --one-file-system -- "$staging"; fi
    return 1
  fi
  if ! mv -T -- "$staging" "$transaction_root"; then
    if [[ -d "$staging" && ! -L "$staging" ]]; then rm -rf --one-file-system -- "$staging"; fi
    printf 'Another worker repair transaction won the atomic journal publish race.\n' >&2
    return 1
  fi
}

restore_transaction() {
  local transaction_root="$1" old_scope old_unit candidate marker_existed
  assert_transaction_tree_safe "$transaction_root"
  [[ -f "$transaction_root/schema" && ! -L "$transaction_root/schema" &&
     "$(cat "$transaction_root/schema")" == "$TRANSACTION_SCHEMA" ]] || {
    printf 'Unsupported worker repair transaction state.\n' >&2
    return 1
  }
  old_scope="$(cat "$transaction_root/old-scope")"
  [[ "$old_scope" == user || "$old_scope" == system ]] || { printf 'Worker repair transaction scope is invalid.\n' >&2; return 1; }
  [[ -f "$transaction_root/installer-uid" && "$(cat "$transaction_root/installer-uid")" == "$(id -u)" ]] || {
    printf 'Worker repair transaction belongs to a different installer identity.\n' >&2
    return 1
  }
  # marker-existed was added after the original journal format. Infer the
  # legacy value from manifest-existed so an interrupted first install does
  # not leave an ownership marker that can authorize destructive cleanup.
  if [[ -f "$transaction_root/marker-existed" && ! -L "$transaction_root/marker-existed" ]]; then
    marker_existed="$(cat "$transaction_root/marker-existed")"
  elif [[ -f "$transaction_root/manifest-existed" && ! -L "$transaction_root/manifest-existed" ]]; then
    marker_existed=1
  else
    marker_existed=0
  fi
  [[ "$marker_existed" == 0 || "$marker_existed" == 1 ]] || {
    printf 'Worker repair transaction ownership state is invalid.\n' >&2
    return 1
  }
  if [[ -e "$transaction_tombstone_path" || -L "$transaction_tombstone_path" ]]; then
    # The active sidecar may have been published just before a process was
    # stopped while removing the first-install marker. Its journal
    # marker-existed=0 state is the authority for this recovery, not the still-
    # present marker. A retired sidecar cannot coexist with an active journal.
    rollback_tombstone_valid_for_transaction || {
      printf 'Worker repair rollback tombstone is invalid for this transaction.\n' >&2
      return 1
    }
    marker_existed=0
  fi

  remove_service_for_scope "$scope"
  if [[ "$old_scope" != "$scope" ]]; then remove_service_for_scope "$old_scope"; fi

  for candidate in "$data_root"/config.* "$data_root"/*.credential; do
    [[ -e "$candidate" || -L "$candidate" ]] || continue
    rm -f -- "$candidate"
  done
  for candidate in "$transaction_root"/identity/*; do
    [[ -e "$candidate" || -L "$candidate" ]] || continue
    [[ -f "$candidate" && ! -L "$candidate" ]] || { printf 'Worker repair identity snapshot is unsafe.\n' >&2; return 1; }
    install -m 0600 -- "$candidate" "$data_root/$(basename -- "$candidate")"
  done

  rm -f -- "$install_manifest"
  if [[ -f "$transaction_root/manifest-existed" ]]; then
    install -m 0600 -- "$transaction_root/install-manifest.json" "$install_manifest"
  fi

  rm -f -- "$worker_path"
  if [[ -f "$transaction_root/binary-existed" ]]; then
    install -m 0700 -- "$transaction_root/cyc-worker" "$worker_path"
  fi

  old_unit="$(service_path_for_scope "$old_scope")"
  if [[ -f "$transaction_root/unit-existed" ]]; then
    reject_link_chain "$(dirname -- "$old_unit")"
    if [[ "$old_scope" == user ]]; then
      private_dir "$(dirname -- "$old_unit")"
    elif [[ ! -d "$(dirname -- "$old_unit")" ]]; then
      install -d -m 0755 -- "$(dirname -- "$old_unit")"
    fi
    install -m 0600 -- "$transaction_root/service.unit" "$old_unit"
    service_ctl_for_scope "$old_scope" daemon-reload
    if [[ -f "$transaction_root/service-enabled" ]]; then
      service_ctl_for_scope "$old_scope" enable "$SERVICE_NAME" >/dev/null
    fi
    if [[ -f "$transaction_root/service-active" ]]; then
      service_ctl_for_scope "$old_scope" start "$SERVICE_NAME"
      service_ctl_for_scope "$old_scope" is-active --quiet "$SERVICE_NAME"
    fi
  fi
  if [[ "$marker_existed" == 0 ]]; then
    # Keep a sidecar recovery capability while the ownership marker and the
    # recursive journal cleanup transition are in flight. The sidecar lives
    # outside the journal so rm -rf cannot delete it before the journal root.
    write_rollback_tombstone || return 1
    rm -f -- "$marker_path" || return 1
    if ! inject_failure after-marker-removal; then return 1; fi
  fi
  if ! remove_transaction "$transaction_root"; then return 1; fi
  if [[ "$marker_existed" == 0 ]]; then
    remove_rollback_tombstone || return 1
  fi
}

inject_failure() {
  local expected="$1"
  if [[ "$failure_injection" == "$expected" ]]; then
    printf 'Injected worker repair failure at %s.\n' "$expected" >&2
    return 1
  fi
}

install_manifest="${data_root}/install-manifest.json"
worker_path="${install_root}/cyc-worker"
config_path="${data_root}/config.json"
marker_path="${data_root}/${MARKER_NAME}"
transaction_root="${data_root}/${TRANSACTION_NAME}"
installation_owned_before=0

for path in "$bundle_root" "$install_root" "$data_root" "$workspace_root"; do
  reject_link_chain "$path"
done

if [[ -L "$transaction_tombstone_path" || ( -e "$transaction_tombstone_path" && ! -f "$transaction_tombstone_path" ) ]]; then
  printf 'Worker repair rollback tombstone is not a regular file.\n' >&2
  exit 1
elif [[ -f "$transaction_tombstone_path" ]]; then
  rollback_tombstone_contents_valid || {
    printf 'Worker repair rollback tombstone is invalid.\n' >&2
    exit 1
  }
fi
if [[ -L "$transaction_retired_root" || ( -e "$transaction_retired_root" && ! -d "$transaction_retired_root" ) ]]; then
  printf 'Worker repair transaction retirement path is unsafe.\n' >&2
  exit 1
fi

if [[ -L "$marker_path" || ( -e "$marker_path" && ! -f "$marker_path" ) ]]; then
  printf 'Worker ownership marker is not a regular file.\n' >&2
  exit 1
elif [[ -f "$marker_path" ]]; then
  if [[ "$(cat "$marker_path")" == "$SCHEMA" ]]; then
    installation_owned_before=1
  else
    printf 'Worker ownership marker has an unexpected value.\n' >&2
    exit 1
  fi
fi

if [[ "$installation_owned_before" -eq 1 ]]; then
  if [[ -e "$install_manifest" || -L "$install_manifest" ]]; then
    validate_owned_manifest
  elif [[ ! -e "$transaction_root" && ! -L "$transaction_root" ]]; then
    printf 'Owned worker install manifest is missing or unsafe.\n' >&2
    exit 1
  elif [[ -f "$transaction_root/committed" && ! -L "$transaction_root/committed" ]]; then
    # A committed journal has no rollback work left to perform. It must not
    # be used to authorize cleanup after the authoritative manifest vanished.
    printf 'Owned worker install manifest is missing or unsafe.\n' >&2
    exit 1
  fi
fi

if [[ -e "$transaction_retired_root" || -L "$transaction_retired_root" ]]; then
  [[ ! -e "$transaction_root" && ! -L "$transaction_root" ]] || {
    printf 'Worker repair transaction has both active and retired journal state.\n' >&2
    exit 1
  }
  if [[ -e "$transaction_tombstone_path" && ! -L "$transaction_tombstone_path" ]]; then
    # A tombstone makes this the first-install rollback state. Validate the
    # retired journal identity and ownership state before deleting anything;
    # this also covers an interruption between journal rename and tombstone
    # state publication.
    validate_retired_transaction || {
      printf 'Worker repair retired transaction state is invalid.\n' >&2
      exit 1
    }
    if ! rollback_tombstone_is_retired; then mark_rollback_tombstone_retired; fi
    remove_transaction_retirement "$transaction_retired_root"
  elif [[ "$installation_owned_before" -eq 1 ]]; then
    # A committed repair has no tombstone. Keep the normal owned-installation
    # cleanup path, but still bind it to this installer's journal identity.
    validate_retired_transaction_identity || {
      printf 'Worker repair retired transaction state is invalid.\n' >&2
      exit 1
    }
    remove_transaction_retirement "$transaction_retired_root"
  else
    printf 'Found a worker repair transaction retirement without a valid ownership marker.\n' >&2
    exit 1
  fi
fi

if [[ -e "$transaction_root" || -L "$transaction_root" ]]; then
  if [[ -f "$transaction_root/committed" && ! -L "$transaction_root/committed" ]]; then
    [[ "$installation_owned_before" -eq 1 && ! -e "$transaction_tombstone_path" && ! -L "$transaction_tombstone_path" ]] || {
      printf 'Found a committed worker repair transaction without a valid ownership marker.\n' >&2
      exit 1
    }
    remove_transaction "$transaction_root"
  elif [[ "$installation_owned_before" -eq 1 ]]; then
    restore_transaction "$transaction_root"
  elif rollback_tombstone_valid_for_transaction; then
    # The marker is intentionally absent only after rollback has published its
    # sidecar recovery capability. Resume that transaction instead of treating
    # the first-install state as an unowned foreign tree.
    restore_transaction "$transaction_root"
  else
    printf 'Found a worker repair transaction without a valid ownership marker.\n' >&2
    exit 1
  fi
elif [[ -e "$transaction_tombstone_path" || -L "$transaction_tombstone_path" ]]; then
  [[ "$installation_owned_before" -eq 0 && ! -L "$transaction_tombstone_path" ]] || {
    printf 'Worker repair rollback tombstone has no resumable transaction.\n' >&2
    exit 1
  }
  rollback_tombstone_is_retired || {
    printf 'Worker repair rollback tombstone has no retired journal.\n' >&2
    exit 1
  }
  # The journal was already atomically retired; only the final tombstone
  # unlink was interrupted. It is safe and idempotent to finish that unlink.
  remove_rollback_tombstone
fi

if [[ "$action" == uninstall ]]; then
  if [[ ! -f "$marker_path" || -L "$marker_path" ]]; then
    printf '{"schemaVersion":"%s","action":"uninstall","succeeded":true,"alreadyAbsent":true,"dataPreserved":true}\n' "$SCHEMA"
    exit 0
  fi
  remove_service
  if [[ -f "$worker_path" && ! -L "$worker_path" ]]; then rm -f -- "$worker_path"; fi
  rmdir -- "$install_root" 2>/dev/null || true
  if [[ "$purge_data" -eq 1 ]]; then
    default_data="${XDG_DATA_HOME:-${HOME}/.local/share}/clusteryourcodex/worker"
    default_data="$(normalize_path "$default_data")"
    reject_link_chain "$data_root"
    [[ "$data_root" == "$default_data" ]] || { printf 'Data purge is limited to the default owned root.\n' >&2; exit 1; }
    [[ -f "${data_root}/${MARKER_NAME}" && ! -L "${data_root}/${MARKER_NAME}" ]] || { printf 'Ownership marker missing.\n' >&2; exit 1; }
    rm -rf --one-file-system -- "$data_root"
  fi
  printf '{"schemaVersion":"%s","action":"uninstall","succeeded":true,"dataPreserved":%s}\n' "$SCHEMA" "$([[ "$purge_data" -eq 1 ]] && printf false || printf true)"
  exit 0
fi

for required in worker-kit.json worker-kit.sig SHA256SUMS cyc-worker install-worker.sh; do
  [[ -f "${bundle_root}/${required}" && ! -L "${bundle_root}/${required}" ]] || { printf 'Worker kit file missing or unsafe: %s\n' "$required" >&2; exit 1; }
done
mapfile -t checksum_lines <"${bundle_root}/SHA256SUMS"
[[ "${#checksum_lines[@]}" -eq 4 ]] || { printf 'SHA256SUMS must contain exactly four signed-kit files.\n' >&2; exit 1; }
for required in cyc-worker install-worker.sh worker-kit.json worker-kit.sig; do
  [[ "$(grep -Ec "^[0-9A-Fa-f]{64}  ${required//./\\.}$" "${bundle_root}/SHA256SUMS")" -eq 1 ]] || {
    printf 'SHA256SUMS entry is missing or duplicated: %s\n' "$required" >&2
    exit 1
  }
done
(cd -- "$bundle_root" && sha256sum --check --strict SHA256SUMS)
[[ "$(wc -l <"${bundle_root}/worker-kit.sig")" -eq 1 &&
    "$(tail -c 1 -- "${bundle_root}/worker-kit.sig" | od -An -tx1 | tr -d '[:space:]')" == 0a ]] || {
  printf 'Worker-kit publisher signature envelope is not canonical.\n' >&2
  exit 1
}
signature_line="$(cat -- "${bundle_root}/worker-kit.sig")"
signature_pattern='^\{"schemaVersion":"cyc\.dev/worker-kit-signature/v1","algorithm":"Ed25519","keyId":"cyc-release-2026-02","signedObject":"worker-kit\.json","manifestSha256":"([0-9a-f]{64})","signature":"([A-Za-z0-9+/]{86}==)"\}$'
[[ "$signature_line" =~ $signature_pattern ]] || {
  printf 'Worker-kit publisher signature envelope is invalid.\n' >&2
  exit 1
}
manifest_digest="$(sha256sum -- "${bundle_root}/worker-kit.json" | awk '{print $1}')"
[[ "$manifest_digest" == "${BASH_REMATCH[1]}" ]] || {
  printf 'Worker-kit publisher signature is not bound to this manifest.\n' >&2
  exit 1
}
signature_length="$(printf '%s' "${BASH_REMATCH[2]}" | base64 --decode | wc -c)" || {
  printf 'Worker-kit publisher signature encoding is invalid.\n' >&2
  exit 1
}
[[ "$signature_length" -eq 64 ]] || {
  printf 'Worker-kit publisher signature length is invalid.\n' >&2
  exit 1
}
case "$(uname -m)" in
  x86_64|amd64) machine_arch='x86_64' ;;
  aarch64|arm64) machine_arch='aarch64' ;;
  *) printf 'Unsupported worker architecture: %s\n' "$(uname -m)" >&2; exit 1 ;;
esac
verify_worker_kit_signature \
  "${bundle_root}/worker-kit.json" \
  "${bundle_root}/worker-kit.sig" \
  "$bundle_root" \
  "linux-${machine_arch}" \
  "$machine_arch"

unit_path="$(service_path)"
if [[ ! -f "$marker_path" && ( -e "$worker_path" || -e "$unit_path" || -L "$worker_path" || -L "$unit_path" ) ]]; then
  printf 'Refusing to overwrite a worker or service not owned by this installer.\n' >&2
  exit 1
fi

# Fail before changing the worker, config, manifest, or service whenever this
# invocation is expected to activate a user-scoped service. Pair-only and the
# enrollment-free preinstall intentionally remain service-independent.
if [[ "$scope" == user && "$pair_only" -eq 0 && ( -e "$config_path" || -n "$enrollment_file" ) ]]; then
  require_user_systemd_ready
fi

private_dir "$install_root"
private_dir "$data_root"
private_dir "$workspace_root"
config_existed_before_pair=0
if [[ -e "$config_path" || -L "$config_path" ]]; then
  [[ -f "$config_path" && ! -L "$config_path" ]] || { printf 'Worker config path is not a regular file.\n' >&2; exit 1; }
  config_existed_before_pair=1
fi
temporary_worker="${worker_path}.new.$$"
protected_enrollment=''
committed=0
transaction_active=0
cleanup() {
  local exit_code=$?
  rm -f -- "$temporary_worker"
  rm -f -- "${install_manifest}.new.$$"
  if [[ -n "$protected_enrollment" ]]; then rm -f -- "$protected_enrollment"; fi
  if [[ -n "$enrollment_file" ]]; then rm -f -- "$enrollment_file"; fi
  if [[ "$exit_code" -ne 0 && "$committed" -eq 0 ]]; then
    if [[ "$transaction_active" -eq 1 ]]; then
      if ! restore_transaction "$transaction_root"; then
        printf 'Worker repair failed and the protected rollback transaction could not be restored.\n' >&2
      fi
    elif [[ "$installation_owned_before" -eq 0 ]]; then
      # The marker is an ownership capability. Do not leave a new marker
      # behind when journal creation failed before rollback became active.
      rm -f -- "$marker_path"
    fi
  fi
  return "$exit_code"
}
trap cleanup EXIT
printf '%s\n' "$SCHEMA" >"${data_root}/${MARKER_NAME}"
chmod 0600 -- "${data_root}/${MARKER_NAME}"
install -m 0700 -- "${bundle_root}/cyc-worker" "$temporary_worker"
begin_transaction "$transaction_root"
transaction_active=1
old_scope="$(cat "$transaction_root/old-scope")"
if [[ -f "$transaction_root/unit-existed" ]]; then
  remove_service_for_scope "$old_scope"
  if [[ "$scope" != "$old_scope" ]]; then remove_service_for_scope "$scope"; fi
fi
if [[ -L "$worker_path" || ( -e "$worker_path" && ! -f "$worker_path" ) ]]; then
  printf 'Existing worker path is unsafe.\n' >&2
  exit 1
elif [[ -f "$worker_path" ]]; then
  rm -f -- "$worker_path"
fi
mv -- "$temporary_worker" "$worker_path"

if [[ -n "$enrollment_file" ]]; then
  [[ -f "$enrollment_file" && ! -L "$enrollment_file" ]] || { printf 'Enrollment file is missing or unsafe.\n' >&2; exit 1; }
  protected_enrollment="${data_root}/enrollment.$$.json"
  install -m 0600 -- "$enrollment_file" "$protected_enrollment"
  pair_args=(pair --enrollment-file "$protected_enrollment" --config "$config_path" --workspace-root "$workspace_root")
  if [[ "$config_existed_before_pair" -eq 1 ]]; then
    pair_args+=(--repair)
  fi
  if ! "$worker_path" "${pair_args[@]}" >/dev/null; then
    printf 'Worker pairing failed.\n' >&2
    exit 1
  fi
  inject_failure after-pair
  rm -f -- "$protected_enrollment" "$enrollment_file"
fi
if [[ -e "$config_path" || -L "$config_path" ]]; then
  [[ -f "$config_path" && ! -L "$config_path" ]] || { printf 'Worker config path is not a regular file.\n' >&2; exit 1; }
  paired=true
else
  paired=false
fi
if [[ -n "$enrollment_file" && "$paired" != true ]]; then
  printf 'Worker pairing completed without producing its protected config.\n' >&2
  exit 1
fi
service_state='not_enabled'
service_enabled=false
if [[ "$paired" == true ]]; then
  chmod 0600 -- "$config_path"
  "$worker_path" status --config "$config_path" >/dev/null
fi
if [[ "$paired" == true && "$pair_only" -eq 0 ]]; then
  install_service
  inject_failure after-service-registration
  service_state="systemd-${scope}"
  service_enabled=true
fi

worker_hash="$(sha256sum -- "$worker_path" | awk '{print $1}')"
inject_failure before-manifest-write
cat >"${install_manifest}.new.$$" <<EOF
{"schemaVersion":"${SCHEMA}","installedAt":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","installRoot":"$(json_escape "$install_root")","dataRoot":"$(json_escape "$data_root")","workspaceRoot":"$(json_escape "$workspace_root")","servicePath":"$(json_escape "$(service_path_for_scope "$scope")")","workerSha256":"${worker_hash}","paired":${paired},"serviceEnabled":${service_enabled},"service":"${service_state}","scope":"${scope}","allowOnBattery":$([[ "$allow_on_battery" -eq 1 ]] && printf true || printf false),"pairOnly":$([[ "$pair_only" -eq 1 ]] && printf true || printf false)}
EOF
chmod 0600 -- "${install_manifest}.new.$$"
mv -f -- "${install_manifest}.new.$$" "$install_manifest"
printf '%s\n' committed >"$transaction_root/committed"
chmod 0600 -- "$transaction_root/committed"
committed=1
transaction_active=0
remove_transaction "$transaction_root" || true
printf '{"schemaVersion":"%s","action":"%s","succeeded":true,"paired":%s,"service":"%s","serviceEnabled":%s,"scope":"%s","allowOnBattery":%s}\n' "$SCHEMA" "$action" "$paired" "$service_state" "$service_enabled" "$scope" "$([[ "$allow_on_battery" -eq 1 ]] && printf true || printf false)"
