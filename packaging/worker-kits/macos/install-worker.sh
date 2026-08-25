#!/usr/bin/env bash
# The SSH fixed-command surface deliberately invokes POSIX scripts through
# `/bin/sh <script> -- <args>`. Re-enter Bash before any Bash-only syntax and
# consume the fixed separator so the first lifecycle argument remains action.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /bin/bash "$0" "$@"
fi
set -euo pipefail
umask 077
if [[ "${1:-}" == -- ]]; then shift; fi

SCHEMA='cyc.dev/macos-worker-install/v1'
KIT_SCHEMA='cyc.dev/worker-kit/v1'
PUBLISHER_KEY_ID='cyc-release-2026-02'
PUBLISHER_PUBLIC_KEY_BASE64='__CYC_PUBLISHER_PUBLIC_KEY_BASE64__'
LAUNCH_AGENT_LABEL='dev.clusteryourcodex.worker'
MARKER_NAME='.clusteryourcodex-worker-owned'
LOG_MARKER_NAME='.clusteryourcodex-worker-logs-owned'
TRANSACTION_NAME='.repair-transaction'
TRANSACTION_SCHEMA='cyc.dev/macos-worker-repair-transaction/v1'
EXIT_RUNTIME_GATED=78

# This is deliberately a compile-time packaging gate, not an environment
# switch. Preinstall, integrity verification, pairing, status, and uninstall
# are safe. No invocation can bootstrap or start cyc-worker until native macOS
# worker containment has been implemented and passed a live-macOS lifecycle.
readonly MACOS_WORKER_CONTAINMENT_READY=0

action="${1:-install}"
if [[ $# -gt 0 ]]; then shift; fi

bundle_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
application_support="${HOME}/Library/Application Support/ClusterYourCodex/Worker"
install_root="${application_support}/Program"
data_root="${application_support}/Data"
workspace_root="${application_support}/Data/workspace"
logs_root="${HOME}/Library/Logs/ClusterYourCodex/Worker"
launch_agent_path="${HOME}/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"
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
  --logs-root PATH
  --enrollment PATH
  --scope auto|user|system
  --allow-on-battery
  --pair-only
  --purge-data
  --failure-injection none|after-pair|after-launchagent-registration|before-manifest-write

macOS preview contract:
  * install without an enrollment safely preinstalls an unpaired worker.
  * repair --enrollment FILE --pair-only safely pairs without a LaunchAgent.
  * worker LaunchAgent activation is fail-closed until native containment is ready.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-root) bundle_root="$2"; shift 2 ;;
    --install-root) install_root="$2"; shift 2 ;;
    --data-root) data_root="$2"; shift 2 ;;
    --workspace-root) workspace_root="$2"; shift 2 ;;
    --logs-root) logs_root="$2"; shift 2 ;;
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
case "$scope" in auto|user|system) ;; *) printf 'Invalid scope.\n' >&2; exit 2 ;; esac
case "$failure_injection" in
  none|after-pair|after-launchagent-registration|before-manifest-write) ;;
  *) printf 'Invalid failure injection point.\n' >&2; exit 2 ;;
esac

if [[ "$(uname -s)" != Darwin ]]; then
  printf '%s\n' \
    '[CYC-MACOS-PLATFORM-REQUIRED] This worker lifecycle package can run only on macOS.' \
    >&2
  exit "$EXIT_RUNTIME_GATED"
fi
if [[ "$scope" == system ]]; then
  printf '%s\n' \
    '[CYC-MACOS-LAUNCHAGENT-USER-SCOPE-REQUIRED] macOS worker preview supports only a current-user LaunchAgent.' \
    >&2
  exit "$EXIT_RUNTIME_GATED"
fi
scope='user'

normalize_path() {
  local value="$1" part result index
  local control_pattern=$'[\001-\037\177]'
  local -a components=()
  local -a normalized=()
  [[ ! "$value" =~ $control_pattern ]] || {
    printf 'Control characters are not allowed in paths.\n' >&2
    return 1
  }
  [[ "$value" == /* ]] || value="${PWD}/${value}"
  IFS='/' read -r -a components <<<"$value"
  for part in "${components[@]}"; do
    case "$part" in
      ''|.) ;;
      ..)
        if [[ "${#normalized[@]}" -gt 0 ]]; then
          index=$((${#normalized[@]} - 1))
          unset "normalized[$index]"
        fi
        ;;
      *) normalized[${#normalized[@]}]="$part" ;;
    esac
  done
  result=''
  for ((index = 0; index < ${#normalized[@]}; index++)); do
    result="${result}/${normalized[$index]}"
  done
  [[ -n "$result" ]] || result='/'
  printf '%s\n' "$result"
}

bundle_root="$(normalize_path "$bundle_root")"
install_root="$(normalize_path "$install_root")"
data_root="$(normalize_path "$data_root")"
workspace_root="$(normalize_path "$workspace_root")"
logs_root="$(normalize_path "$logs_root")"
launch_agent_path="$(normalize_path "$launch_agent_path")"
if [[ -n "$enrollment_file" ]]; then enrollment_file="$(normalize_path "$enrollment_file")"; fi

default_data_root="$(normalize_path "${HOME}/Library/Application Support/ClusterYourCodex/Worker/Data")"
default_logs_root="$(normalize_path "${HOME}/Library/Logs/ClusterYourCodex/Worker")"

case "$(uname -m)" in
  x86_64|amd64) machine_arch='x86_64' ;;
  arm64|aarch64) machine_arch='aarch64' ;;
  *) printf 'Unsupported worker architecture: %s\n' "$(uname -m)" >&2; exit 1 ;;
esac
expected_target="macos-${machine_arch}"

python_command=''
resolve_python_verifier() {
  local candidate
  [[ -z "$python_command" ]] || return 0
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 &&
       "$candidate" -c 'import sys; assert sys.version_info >= (3, 8)' >/dev/null 2>&1; then
      python_command="$candidate"
      return 0
    fi
  done
  printf '%s\n' \
    '[CYC-MACOS-PYTHON-REQUIRED] Python 3.8+ is required for canonical Ed25519 worker-kit verification.' \
    >&2
  return "$EXIT_RUNTIME_GATED"
}

reject_link_chain() {
  local current="$1"
  while [[ "$current" != / ]]; do
    if [[ -L "$current" ]]; then
      printf 'Symlink path rejected: %s\n' "$current" >&2
      return 1
    fi
    current="$(dirname "$current")"
  done
}

private_dir() {
  reject_link_chain "$1"
  mkdir -p "$1"
  [[ -d "$1" && ! -L "$1" ]] || {
    printf 'Private directory invalid: %s\n' "$1" >&2
    return 1
  }
  chmod 0700 "$1"
}

hash_file() {
  shasum -a 256 "$1" | awk '{print tolower($1)}'
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf '%s' "$value"
}

verify_worker_kit_signature() {
  local manifest_path="$1"
  local signature_path="$2"
  "$python_command" - \
    "$PUBLISHER_PUBLIC_KEY_BASE64" \
    "$PUBLISHER_KEY_ID" \
    "$manifest_path" \
    "$signature_path" \
    "$bundle_root" \
    "$expected_target" \
    "$machine_arch" <<'PY'
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
            manifest['target'] != expected_target or manifest['os'] != 'macos' or
            manifest['architecture'] != expected_arch):
        raise ValueError('manifest target')
    expected_files = [('cyc-worker', 'worker'), ('install-worker.sh', 'lifecycle')]
    if not isinstance(manifest['files'], list) or len(manifest['files']) != 2:
        raise ValueError('manifest files')
    for entry, (expected_path, expected_role) in zip(manifest['files'], expected_files):
        if (not isinstance(entry, dict) or
                list(entry) != ['path', 'sizeBytes', 'sha256', 'role'] or
                entry['path'] != expected_path or entry['role'] != expected_role):
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
    if not point_equal(point_multiply(base_point, scalar),
                       point_add(r_point, point_multiply(public_point, h))):
        raise ValueError('signature mismatch')
except Exception:
    print('Worker-kit publisher signature verification failed.', file=sys.stderr)
    sys.exit(1)
PY
}

verify_worker_kit() {
  local required line digest name actual seen='|'
  resolve_python_verifier || exit "$EXIT_RUNTIME_GATED"
  command -v shasum >/dev/null 2>&1 || {
    printf 'shasum is required for worker-kit integrity verification.\n' >&2
    return 1
  }
  for required in worker-kit.json worker-kit.sig SHA256SUMS cyc-worker install-worker.sh; do
    [[ -f "${bundle_root}/${required}" && ! -L "${bundle_root}/${required}" ]] || {
      printf 'Worker kit file missing or unsafe: %s\n' "$required" >&2
      return 1
    }
  done
  [[ "$(wc -l <"${bundle_root}/SHA256SUMS" | tr -d '[:space:]')" -eq 4 ]] || {
    printf 'SHA256SUMS must contain exactly four signed-kit files.\n' >&2
    return 1
  }
  while IFS= read -r line; do
    if [[ ! "$line" =~ ^([0-9A-Fa-f]{64})\ \ (.+)$ ]]; then
      printf 'SHA256SUMS contains a malformed entry.\n' >&2
      return 1
    fi
    digest="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
    name="${BASH_REMATCH[2]}"
    case "$name" in cyc-worker|install-worker.sh|worker-kit.json|worker-kit.sig) ;; *)
      printf 'SHA256SUMS contains an unexpected entry: %s\n' "$name" >&2
      return 1 ;;
    esac
    if [[ "$seen" == *"|${name}|"* ]]; then
      printf 'SHA256SUMS contains a duplicate entry: %s\n' "$name" >&2
      return 1
    fi
    actual="$(hash_file "${bundle_root}/${name}")"
    [[ "$digest" == "$actual" ]] || {
      printf 'Worker-kit digest mismatch: %s\n' "$name" >&2
      return 1
    }
    seen="${seen}${name}|"
  done <"${bundle_root}/SHA256SUMS"
  for required in cyc-worker install-worker.sh worker-kit.json worker-kit.sig; do
    [[ "$seen" == *"|${required}|"* ]] || {
      printf 'SHA256SUMS entry is missing: %s\n' "$required" >&2
      return 1
    }
  done
  verify_worker_kit_signature \
    "${bundle_root}/worker-kit.json" \
    "${bundle_root}/worker-kit.sig"
}

launch_domain="gui/$(id -u)"
launch_target="${launch_domain}/${LAUNCH_AGENT_LABEL}"

launch_agent_loaded() {
  launchctl print "$launch_target" >/dev/null 2>&1
}

remove_launch_agent() {
  if command -v launchctl >/dev/null 2>&1; then
    launchctl bootout "$launch_domain" "$launch_agent_path" >/dev/null 2>&1 || true
    launchctl bootout "$launch_target" >/dev/null 2>&1 || true
  fi
  if [[ -f "$launch_agent_path" && ! -L "$launch_agent_path" ]]; then
    rm -f "$launch_agent_path"
  fi
}

require_worker_containment() {
  if [[ "$MACOS_WORKER_CONTAINMENT_READY" -ne 1 ]]; then
    printf '%s\n' \
      '[CYC-MACOS-WORKER-CONTAINMENT-UNAVAILABLE] LaunchAgent activation is disabled until native macOS worker containment and a live lifecycle test are complete. Preinstall and --pair-only remain available.' \
      >&2
    exit "$EXIT_RUNTIME_GATED"
  fi
}

install_launch_agent() {
  local plist_dir temporary_plist worker_xml config_xml workspace_xml stdout_xml stderr_xml
  require_worker_containment
  command -v launchctl >/dev/null 2>&1 || {
    printf 'launchctl is required for LaunchAgent activation.\n' >&2
    return 1
  }
  command -v plutil >/dev/null 2>&1 || {
    printf 'plutil is required for LaunchAgent validation.\n' >&2
    return 1
  }
  launchctl print "$launch_domain" >/dev/null 2>&1 || {
    printf '%s\n' \
      '[CYC-MACOS-LAUNCHAGENT-DOMAIN-UNAVAILABLE] The current user GUI launchd domain is unavailable.' \
      >&2
    return "$EXIT_RUNTIME_GATED"
  }
  plist_dir="$(dirname "$launch_agent_path")"
  private_dir "$plist_dir"
  private_dir "$logs_root"
  worker_xml="$(xml_escape "${install_root}/cyc-worker")"
  config_xml="$(xml_escape "${data_root}/config.json")"
  workspace_xml="$(xml_escape "$workspace_root")"
  stdout_xml="$(xml_escape "${logs_root}/worker.stdout.log")"
  stderr_xml="$(xml_escape "${logs_root}/worker.stderr.log")"
  temporary_plist="${launch_agent_path}.new.$$"
  cat >"$temporary_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LAUNCH_AGENT_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${worker_xml}</string>
    <string>run</string>
    <string>--config</string>
    <string>${config_xml}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${workspace_xml}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ThrottleInterval</key>
  <integer>5</integer>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>${stdout_xml}</string>
  <key>StandardErrorPath</key>
  <string>${stderr_xml}</string>
</dict>
</plist>
EOF
  chmod 0600 "$temporary_plist"
  plutil -lint "$temporary_plist" >/dev/null
  mv -f "$temporary_plist" "$launch_agent_path"
  launchctl bootstrap "$launch_domain" "$launch_agent_path"
  launchctl kickstart -k "$launch_target"
  launchctl print "$launch_target" >/dev/null
}

install_manifest="${data_root}/install-manifest.json"
worker_path="${install_root}/cyc-worker"
config_path="${data_root}/config.json"
marker_path="${data_root}/${MARKER_NAME}"
log_marker_path="${logs_root}/${LOG_MARKER_NAME}"
transaction_root="${data_root}/${TRANSACTION_NAME}"
installation_owned_before=0

for path in "$bundle_root" "$install_root" "$data_root" "$workspace_root" "$logs_root" "$launch_agent_path"; do
  reject_link_chain "$path"
done

assert_transaction_tree_safe() {
  local value="$1"
  [[ "$value" == "$transaction_root" && -d "$value" && ! -L "$value" ]] || {
    printf 'Worker repair transaction escaped the owned data root.\n' >&2
    return 1
  }
  if [[ -n "$(find "$value" -type l -print 2>/dev/null | head -n 1)" ]]; then
    printf 'Worker repair transaction contains a symlink.\n' >&2
    return 1
  fi
}

remove_transaction() {
  local value="$1"
  [[ ! -e "$value" && ! -L "$value" ]] && return 0
  assert_transaction_tree_safe "$value"
  rm -rf "$value"
}

begin_transaction() {
  local staging candidate
  [[ ! -e "$transaction_root" && ! -L "$transaction_root" ]] || {
    printf 'A worker repair transaction is already present.\n' >&2
    return 1
  }
  staging="${transaction_root}.new.$$"
  [[ ! -e "$staging" && ! -L "$staging" ]] || {
    printf 'Worker repair staging path already exists.\n' >&2
    return 1
  }
  if ! (
    set -euo pipefail
    mkdir -p "$staging/identity"
    chmod 0700 "$staging" "$staging/identity"
    printf '%s\n' "$TRANSACTION_SCHEMA" >"$staging/schema"
    printf '%s\n' "$(id -u)" >"$staging/installer-uid"
    chmod 0600 "$staging/schema" "$staging/installer-uid"

    if [[ -f "$worker_path" && ! -L "$worker_path" ]]; then
      install -m 0700 "$worker_path" "$staging/cyc-worker"
      : >"$staging/binary-existed"
    elif [[ -e "$worker_path" || -L "$worker_path" ]]; then
      printf 'Existing worker binary is unsafe.\n' >&2
      exit 1
    fi

    for candidate in "$data_root"/config.* "$data_root"/*.credential; do
      [[ -e "$candidate" || -L "$candidate" ]] || continue
      [[ -f "$candidate" && ! -L "$candidate" ]] || {
        printf 'Worker identity storage is unsafe.\n' >&2
        exit 1
      }
      cp -p "$candidate" "$staging/identity/$(basename "$candidate")"
      chmod 0600 "$staging/identity/$(basename "$candidate")"
    done

    if [[ -f "$install_manifest" && ! -L "$install_manifest" ]]; then
      cp -p "$install_manifest" "$staging/install-manifest.json"
      chmod 0600 "$staging/install-manifest.json"
      : >"$staging/manifest-existed"
    elif [[ -e "$install_manifest" || -L "$install_manifest" ]]; then
      printf 'Existing install manifest is unsafe.\n' >&2
      exit 1
    fi

    if [[ -f "$launch_agent_path" && ! -L "$launch_agent_path" ]]; then
      cp -p "$launch_agent_path" "$staging/launch-agent.plist"
      chmod 0600 "$staging/launch-agent.plist"
      : >"$staging/launchagent-existed"
      if launch_agent_loaded; then : >"$staging/launchagent-loaded"; fi
    elif [[ -e "$launch_agent_path" || -L "$launch_agent_path" ]]; then
      printf 'Existing LaunchAgent is unsafe.\n' >&2
      exit 1
    fi
  ); then
    if [[ -d "$staging" && ! -L "$staging" ]]; then rm -rf "$staging"; fi
    return 1
  fi
  if ! mv "$staging" "$transaction_root"; then
    if [[ -d "$staging" && ! -L "$staging" ]]; then rm -rf "$staging"; fi
    printf 'Another worker repair transaction won the journal publish race.\n' >&2
    return 1
  fi
}

restore_transaction() {
  local candidate
  assert_transaction_tree_safe "$transaction_root"
  [[ -f "$transaction_root/schema" && ! -L "$transaction_root/schema" &&
     "$(cat "$transaction_root/schema")" == "$TRANSACTION_SCHEMA" ]] || {
    printf 'Unsupported worker repair transaction state.\n' >&2
    return 1
  }
  [[ -f "$transaction_root/installer-uid" &&
     "$(cat "$transaction_root/installer-uid")" == "$(id -u)" ]] || {
    printf 'Worker repair transaction belongs to a different installer identity.\n' >&2
    return 1
  }

  remove_launch_agent
  for candidate in "$data_root"/config.* "$data_root"/*.credential; do
    [[ -e "$candidate" || -L "$candidate" ]] || continue
    rm -f "$candidate"
  done
  for candidate in "$transaction_root"/identity/*; do
    [[ -e "$candidate" || -L "$candidate" ]] || continue
    [[ -f "$candidate" && ! -L "$candidate" ]] || {
      printf 'Worker repair identity snapshot is unsafe.\n' >&2
      return 1
    }
    install -m 0600 "$candidate" "$data_root/$(basename "$candidate")"
  done

  rm -f "$install_manifest"
  if [[ -f "$transaction_root/manifest-existed" ]]; then
    install -m 0600 "$transaction_root/install-manifest.json" "$install_manifest"
  fi
  rm -f "$worker_path"
  if [[ -f "$transaction_root/binary-existed" ]]; then
    install -m 0700 "$transaction_root/cyc-worker" "$worker_path"
  fi
  if [[ -f "$transaction_root/launchagent-existed" ]]; then
    private_dir "$(dirname "$launch_agent_path")"
    install -m 0600 "$transaction_root/launch-agent.plist" "$launch_agent_path"
    if [[ -f "$transaction_root/launchagent-loaded" ]]; then
      # This branch is unreachable for packages emitted while the gate is 0.
      # Keep the state transition implementation ready for the future live-
      # macOS containment gate without allowing this preview to start a worker.
      require_worker_containment
      launchctl bootstrap "$launch_domain" "$launch_agent_path"
      launchctl kickstart -k "$launch_target"
      launchctl print "$launch_target" >/dev/null
    fi
  fi
  remove_transaction "$transaction_root"
}

inject_failure() {
  local expected="$1"
  if [[ "$failure_injection" == "$expected" ]]; then
    printf 'Injected worker repair failure at %s.\n' "$expected" >&2
    return 1
  fi
}

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

if [[ -e "$transaction_root" || -L "$transaction_root" ]]; then
  [[ "$installation_owned_before" -eq 1 ]] || {
    printf 'Found a worker repair transaction without a valid ownership marker.\n' >&2
    exit 1
  }
  if [[ -f "$transaction_root/committed" && ! -L "$transaction_root/committed" ]]; then
    remove_transaction "$transaction_root"
  else
    restore_transaction
  fi
fi

if [[ "$action" == uninstall ]]; then
  if [[ ! -f "$marker_path" || -L "$marker_path" ]]; then
    printf '{"schemaVersion":"%s","action":"uninstall","succeeded":true,"alreadyAbsent":true,"dataPreserved":true}\n' "$SCHEMA"
    exit 0
  fi
  if [[ "$purge_data" -eq 1 ]]; then
    [[ "$data_root" == "$default_data_root" && "$logs_root" == "$default_logs_root" ]] || {
      printf 'Data purge is limited to the default owned macOS roots.\n' >&2
      exit 1
    }
    [[ -f "$marker_path" && ! -L "$marker_path" ]] || {
      printf 'Worker data ownership marker is missing.\n' >&2
      exit 1
    }
    [[ -f "$log_marker_path" && ! -L "$log_marker_path" &&
       "$(cat "$log_marker_path")" == "$SCHEMA" ]] || {
      printf 'Worker log ownership marker is missing.\n' >&2
      exit 1
    }
  fi
  remove_launch_agent
  if [[ -f "$worker_path" && ! -L "$worker_path" ]]; then rm -f "$worker_path"; fi
  rmdir "$install_root" 2>/dev/null || true
  if [[ "$purge_data" -eq 1 ]]; then
    reject_link_chain "$data_root"
    reject_link_chain "$logs_root"
    rm -rf "$data_root"
    rm -rf "$logs_root"
  fi
  printf '{"schemaVersion":"%s","action":"uninstall","succeeded":true,"dataPreserved":%s}\n' \
    "$SCHEMA" "$([[ "$purge_data" -eq 1 ]] && printf false || printf true)"
  exit 0
fi

verify_worker_kit

if [[ ! -f "$marker_path" &&
      ( -e "$worker_path" || -L "$worker_path" ||
        -e "$launch_agent_path" || -L "$launch_agent_path" ) ]]; then
  printf 'Refusing to overwrite a worker or LaunchAgent not owned by this installer.\n' >&2
  exit 1
fi

# Fail before worker/config/manifest/LaunchAgent mutation whenever this call
# would activate a paired worker. Enrollment-free preinstall and --pair-only
# intentionally remain available and service-independent.
if [[ "$pair_only" -eq 0 && ( -e "$config_path" || -n "$enrollment_file" ) ]]; then
  require_worker_containment
fi

private_dir "$install_root"
private_dir "$data_root"
private_dir "$workspace_root"
private_dir "$logs_root"
printf '%s\n' "$SCHEMA" >"$marker_path"
printf '%s\n' "$SCHEMA" >"$log_marker_path"
chmod 0600 "$marker_path" "$log_marker_path"

config_existed_before_pair=0
if [[ -e "$config_path" || -L "$config_path" ]]; then
  [[ -f "$config_path" && ! -L "$config_path" ]] || {
    printf 'Worker config path is not a regular file.\n' >&2
    exit 1
  }
  config_existed_before_pair=1
fi

temporary_worker="${worker_path}.new.$$"
protected_enrollment=''
committed=0
transaction_active=0
cleanup() {
  local exit_code=$?
  rm -f "$temporary_worker"
  rm -f "${install_manifest}.new.$$"
  if [[ -n "$protected_enrollment" ]]; then rm -f "$protected_enrollment"; fi
  if [[ -n "$enrollment_file" ]]; then rm -f "$enrollment_file"; fi
  if [[ "$exit_code" -ne 0 && "$committed" -eq 0 && "$transaction_active" -eq 1 ]]; then
    if ! restore_transaction; then
      printf 'Worker repair failed and the protected rollback transaction could not be restored.\n' >&2
    fi
  fi
  return "$exit_code"
}
trap cleanup EXIT

install -m 0700 "${bundle_root}/cyc-worker" "$temporary_worker"
begin_transaction
transaction_active=1
if [[ -f "$transaction_root/launchagent-existed" ]]; then remove_launch_agent; fi
if [[ -L "$worker_path" || ( -e "$worker_path" && ! -f "$worker_path" ) ]]; then
  printf 'Existing worker path is unsafe.\n' >&2
  exit 1
elif [[ -f "$worker_path" ]]; then
  rm -f "$worker_path"
fi
mv "$temporary_worker" "$worker_path"

if [[ -n "$enrollment_file" ]]; then
  [[ -f "$enrollment_file" && ! -L "$enrollment_file" ]] || {
    printf 'Enrollment file is missing or unsafe.\n' >&2
    exit 1
  }
  protected_enrollment="${data_root}/enrollment.$$.json"
  install -m 0600 "$enrollment_file" "$protected_enrollment"
  pair_args=(pair --enrollment-file "$protected_enrollment" --config "$config_path" --workspace-root "$workspace_root")
  if [[ "$config_existed_before_pair" -eq 1 ]]; then pair_args+=(--repair); fi
  if ! "$worker_path" "${pair_args[@]}" >/dev/null; then
    printf 'Worker pairing failed.\n' >&2
    exit 1
  fi
  inject_failure after-pair
  rm -f "$protected_enrollment" "$enrollment_file"
fi

if [[ -e "$config_path" || -L "$config_path" ]]; then
  [[ -f "$config_path" && ! -L "$config_path" ]] || {
    printf 'Worker config path is not a regular file.\n' >&2
    exit 1
  }
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
  chmod 0600 "$config_path"
  "$worker_path" status --config "$config_path" >/dev/null
fi
if [[ "$paired" == true && "$pair_only" -eq 0 ]]; then
  require_worker_containment
  install_launch_agent
  inject_failure after-launchagent-registration
  service_state='launchagent-user'
  service_enabled=true
fi

worker_hash="$(hash_file "$worker_path")"
inject_failure before-manifest-write
cat >"${install_manifest}.new.$$" <<EOF
{"schemaVersion":"${SCHEMA}","installedAt":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","installRoot":"$(json_escape "$install_root")","dataRoot":"$(json_escape "$data_root")","workspaceRoot":"$(json_escape "$workspace_root")","logsRoot":"$(json_escape "$logs_root")","launchAgent":"$(json_escape "$launch_agent_path")","workerSha256":"${worker_hash}","paired":${paired},"serviceEnabled":${service_enabled},"service":"${service_state}","scope":"user","allowOnBattery":$([[ "$allow_on_battery" -eq 1 ]] && printf true || printf false),"pairOnly":$([[ "$pair_only" -eq 1 ]] && printf true || printf false),"containmentReady":false,"runtimeGated":true}
EOF
chmod 0600 "${install_manifest}.new.$$"
mv -f "${install_manifest}.new.$$" "$install_manifest"
printf '%s\n' committed >"$transaction_root/committed"
chmod 0600 "$transaction_root/committed"
committed=1
transaction_active=0
remove_transaction "$transaction_root" || true
printf '{"schemaVersion":"%s","action":"%s","succeeded":true,"paired":%s,"service":"%s","serviceEnabled":%s,"scope":"user","allowOnBattery":%s}\n' \
  "$SCHEMA" "$action" "$paired" "$service_state" "$service_enabled" \
  "$([[ "$allow_on_battery" -eq 1 ]] && printf true || printf false)"
