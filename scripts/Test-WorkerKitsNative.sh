#!/usr/bin/env bash
# Validate a signed Worker Kit on its native Unix host without mutating a
# systemd manager or LaunchAgent. Live managed-worker acceptance is an
# external GA gate and is never inferred from this check.
set -euo pipefail

usage() {
  local exit_code="${1:-2}"
  cat >&2 <<'USAGE'
Usage: Test-WorkerKitsNative.sh --platform linux|macos --kit-root PATH
       [--public-key PATH] [--expected-version VERSION] [--skip-live]
USAGE
  exit "$exit_code"
}

platform=''
kit_root_input=''
public_key=''
expected_version=''
skip_live=0

while (($# > 0)); do
  case "$1" in
    --platform)
      (($# >= 2)) || usage
      platform="$2"
      shift 2
      ;;
    --kit-root)
      (($# >= 2)) || usage
      kit_root_input="$2"
      shift 2
      ;;
    --public-key)
      (($# >= 2)) || usage
      public_key="$2"
      shift 2
      ;;
    --expected-version)
      (($# >= 2)) || usage
      expected_version="$2"
      shift 2
      ;;
    --skip-live)
      skip_live=1
      shift
      ;;
    -h|--help)
      usage 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      ;;
  esac
done

case "$platform" in
  linux|macos) ;;
  *) echo '--platform must be linux or macos' >&2; usage ;;
esac
if [[ -z "$kit_root_input" ]]; then
  echo '--kit-root is required' >&2
  usage
fi

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(CDPATH= cd -- "$script_dir/.." && pwd -P)"
if [[ -z "$public_key" ]]; then
  public_key="$repo_root/crates/cyc-provision/publisher_keys/cyc-release-2026-02.pub"
fi

# Refuse symlinked roots and key files before canonicalising them.
if [[ -L "$kit_root_input" || -L "$public_key" ]]; then
  echo 'kit root and public key must not be symlinks' >&2
  exit 1
fi
if [[ ! -d "$kit_root_input" ]]; then
  echo "kit root is not a directory: $kit_root_input" >&2
  exit 1
fi
if [[ ! -f "$public_key" ]]; then
  echo "public key is not a regular file: $public_key" >&2
  exit 1
fi
kit_root="$(CDPATH= cd -- "$kit_root_input" && pwd -P)"
public_key="$(CDPATH= cd -- "$(dirname -- "$public_key")" && pwd -P)/$(basename -- "$public_key")"

case "$(uname -s)" in
  Linux) [[ "$platform" == linux ]] || { echo 'platform/host mismatch' >&2; exit 1; } ;;
  Darwin) [[ "$platform" == macos ]] || { echo 'platform/host mismatch' >&2; exit 1; } ;;
  *) echo "unsupported native host: $(uname -s)" >&2; exit 1 ;;
esac

for command_name in python3 openssl bash; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "required native tool is unavailable: $command_name" >&2
    exit 1
  }
done
if ! openssl version 2>/dev/null | grep -Eq '^OpenSSL 3\.'; then
  echo 'OpenSSL 3.x is required for Ed25519 verification' >&2
  exit 1
fi

expected_names=(SHA256SUMS cyc-worker install-worker.sh worker-kit.json worker-kit.sig)
python3 - "$kit_root" <<'PY'
import os
import sys
root = sys.argv[1]
entries = list(os.scandir(root))
if len(entries) != 5:
    raise SystemExit(f'Worker Kit must contain exactly five direct entries (found {len(entries)})')
for entry in entries:
    if entry.is_symlink() or not entry.is_file(follow_symlinks=False):
        raise SystemExit(f'Worker Kit contains a directory, symlink, or special entry: {entry.name}')
print('worker-kit-native-entry-set=passed')
PY
for name in "${expected_names[@]}"; do
  path="$kit_root/$name"
  [[ -f "$path" && ! -L "$path" ]] || {
    echo "Worker Kit entry is missing or not a normal file: $name" >&2
    exit 1
  }
done
for name in cyc-worker install-worker.sh; do
  [[ -x "$kit_root/$name" ]] || {
    echo "Worker Kit entry is not executable: $name" >&2
    exit 1
  }
done

bash -n "$kit_root/install-worker.sh"

temporary="$(mktemp -d "${TMPDIR:-/tmp}/cyc-worker-kit-native.XXXXXX")"
cleanup() {
  if [[ -n "${temporary:-}" && -d "$temporary" ]]; then
    rm -rf -- "$temporary"
  fi
}
trap cleanup EXIT HUP INT TERM

# Python performs strict UTF-8/JSON, path, digest, mode, and checksum parsing;
# OpenSSL is kept as the verifier for the Ed25519 primitive itself.
python3 - "$kit_root" "$platform" "$public_key" "$temporary/worker-kit-signature.raw" "$expected_version" <<'PY'
import base64
import hashlib
import json
import os
import platform as platform_module
import stat
import sys

root, expected_platform, public_key_path, signature_path, expected_version = sys.argv[1:]

def fail(message):
    raise SystemExit(message)

def read_utf8(path, label, limit=4 * 1024 * 1024):
    try:
        with open(path, 'rb') as stream:
            data = stream.read(limit + 1)
    except OSError as exc:
        fail(f'{label} cannot be read: {exc}')
    if len(data) == 0 or len(data) > limit:
        fail(f'{label} has an invalid bounded size')
    if data.startswith(b'\xef\xbb\xbf'):
        fail(f'{label} must be UTF-8 without a BOM')
    try:
        return data.decode('utf-8')
    except UnicodeDecodeError:
        fail(f'{label} is not strict UTF-8')

def read_json(path, label):
    try:
        value = json.loads(read_utf8(path, label))
    except json.JSONDecodeError as exc:
        fail(f'{label} is not valid JSON: {exc}')
    if not isinstance(value, dict):
        fail(f'{label} must be a JSON object')
    return value

def digest(path):
    hasher = hashlib.sha256()
    with open(path, 'rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            hasher.update(block)
    return hasher.hexdigest()

manifest_path = os.path.join(root, 'worker-kit.json')
signature_envelope_path = os.path.join(root, 'worker-kit.sig')
manifest = read_json(manifest_path, 'worker-kit.json')
if set(manifest) != {'schemaVersion', 'product', 'version', 'target', 'os', 'architecture', 'files'}:
    fail('worker-kit.json contains an unexpected or missing field')
if manifest['schemaVersion'] != 'cyc.dev/worker-kit/v1':
    fail('worker-kit.json schemaVersion is invalid')
if manifest['product'] != 'ClusterYourCodex Managed Worker':
    fail('worker-kit.json product identity is invalid')
if manifest['os'] != expected_platform:
    fail('worker-kit.json platform does not match the native check')
target = manifest['target']
if expected_platform == 'linux' and target not in ('linux-x86_64', 'linux-aarch64'):
    fail('worker-kit.json Linux target is invalid')
if expected_platform == 'macos' and target not in ('macos-x86_64', 'macos-aarch64'):
    fail('worker-kit.json macOS target is invalid')
target_architecture = target.rsplit('-', 1)[-1]
if target_architecture == 'x86_64':
    target_architecture = 'x86_64'
elif target_architecture == 'aarch64':
    target_architecture = 'aarch64'
else:
    fail('worker-kit.json target architecture is invalid')
if expected_version and manifest['version'] != expected_version:
    fail('worker-kit.json version does not match the requested candidate')
if manifest['architecture'] not in ('x86_64', 'aarch64'):
    fail('worker-kit.json architecture is invalid')
if manifest['architecture'] != target_architecture:
    fail('worker-kit.json target and architecture are inconsistent')
host_arch = platform_module.machine().lower()
if host_arch in ('amd64', 'x86-64'):
    host_arch = 'x86_64'
elif host_arch in ('arm64', 'aarch64'):
    host_arch = 'aarch64'
if host_arch != manifest['architecture']:
    fail(f"worker-kit.json architecture {manifest['architecture']} does not match native host {host_arch}")

files = manifest['files']
if not isinstance(files, list) or len(files) != 2:
    fail('worker-kit.json files must contain exactly two payload records')
expected_payloads = {'cyc-worker': 'worker', 'install-worker.sh': 'lifecycle'}
seen = set()
for record in files:
    if not isinstance(record, dict) or set(record) != {'path', 'sizeBytes', 'sha256', 'role'}:
        fail('worker-kit.json payload record shape is invalid')
    name = record['path']
    if name in seen or name not in expected_payloads:
        fail('worker-kit.json payload path set is invalid')
    seen.add(name)
    if record['role'] != expected_payloads[name]:
        fail(f'worker-kit.json role is invalid for {name}')
    if (not isinstance(record['sizeBytes'], int) or
            isinstance(record['sizeBytes'], bool) or record['sizeBytes'] <= 0):
        fail(f'worker-kit.json sizeBytes is invalid for {name}')
    if not isinstance(record['sha256'], str) or len(record['sha256']) != 64 or any(c not in '0123456789abcdef' for c in record['sha256']):
        fail(f'worker-kit.json sha256 is invalid for {name}')
    path = os.path.join(root, name)
    if os.path.islink(path) or not os.path.isfile(path):
        fail(f'Worker Kit payload is not a normal file: {name}')
    mode = os.stat(path, follow_symlinks=False).st_mode
    if name in ('cyc-worker', 'install-worker.sh') and not (mode & stat.S_IXUSR):
        fail(f'Worker Kit payload is not owner-executable: {name}')
    if os.path.getsize(path) != record['sizeBytes'] or digest(path) != record['sha256']:
        fail(f'worker-kit.json payload digest/size mismatch: {name}')

checksum_text = read_utf8(os.path.join(root, 'SHA256SUMS'), 'SHA256SUMS', 64 * 1024)
if '\r' in checksum_text or not checksum_text.endswith('\n') or checksum_text.endswith('\n\n'):
    fail('SHA256SUMS must contain one LF-terminated record per line')
checksum_records = {}
for line in checksum_text.splitlines():
    parts = line.split('  ')
    if len(parts) != 2 or len(parts[0]) != 64 or any(c not in '0123456789abcdef' for c in parts[0]):
        fail('SHA256SUMS contains a malformed record')
    name = parts[1]
    if name in checksum_records or name not in ('cyc-worker', 'install-worker.sh', 'worker-kit.json', 'worker-kit.sig'):
        fail('SHA256SUMS file set is not the exact signed four-file set')
    checksum_records[name] = parts[0]
if set(checksum_records) != {'cyc-worker', 'install-worker.sh', 'worker-kit.json', 'worker-kit.sig'}:
    fail('SHA256SUMS is missing a signed-kit file')
for name, expected_digest in checksum_records.items():
    if digest(os.path.join(root, name)) != expected_digest:
        fail(f'SHA256SUMS digest mismatch: {name}')

signature = read_json(signature_envelope_path, 'worker-kit.sig')
if set(signature) != {'schemaVersion', 'algorithm', 'keyId', 'signedObject', 'manifestSha256', 'signature'}:
    fail('worker-kit.sig contains an unexpected or missing field')
if signature['schemaVersion'] != 'cyc.dev/worker-kit-signature/v1' or signature['algorithm'] != 'Ed25519':
    fail('worker-kit.sig algorithm/schema is invalid')
if not isinstance(signature['keyId'], str) or not signature['keyId'] or len(signature['keyId']) > 96:
    fail('worker-kit.sig keyId is invalid')
if signature['signedObject'] != 'worker-kit.json' or signature['manifestSha256'] != digest(manifest_path):
    fail('worker-kit.sig is not bound to the exact worker-kit.json bytes')
try:
    raw_signature = base64.b64decode(signature['signature'], validate=True)
except (ValueError, TypeError):
    fail('worker-kit.sig signature is not strict Base64')
if len(raw_signature) != 64:
    fail('worker-kit.sig signature must be exactly 64 bytes')
with open(signature_path, 'wb') as stream:
    stream.write(raw_signature)

try:
    public_key_text = read_utf8(public_key_path, 'trusted public key', 4096).strip()
    raw_key = base64.b64decode(public_key_text, validate=True)
except (ValueError, TypeError):
    fail('trusted public key is not strict Base64')
if len(raw_key) != 32:
    fail('trusted public key must be exactly 32 Ed25519 bytes')
spki_prefix = bytes.fromhex('302a300506032b6570032100')
with open(os.path.join(os.path.dirname(signature_path), 'worker-kit-public.der'), 'wb') as stream:
    stream.write(spki_prefix + raw_key)
print('worker-kit-native-json-and-digest=passed')
PY

openssl pkey -pubin -inform DER -in "$temporary/worker-kit-public.der" \
  -outform PEM -out "$temporary/worker-kit-public.pem" >/dev/null 2>&1
openssl pkeyutl -verify -rawin -pubin -inkey "$temporary/worker-kit-public.pem" \
  -in "$kit_root/worker-kit.json" -sigfile "$temporary/worker-kit-signature.raw" \
  >/dev/null 2>&1

if ((skip_live == 0)); then
  # Only non-mutating host capability probes run here. Service registration,
  # LaunchAgent bootstrap, and controller round-trip need an external host.
  if [[ "$platform" == linux ]]; then
    command -v systemctl >/dev/null 2>&1 || echo 'native-live-probe=systemd-unavailable'
  else
    command -v launchctl >/dev/null 2>&1 || echo 'native-live-probe=launchctl-unavailable'
  fi
else
  echo 'native-live-probe=skipped'
fi

target_value="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["target"])' "$kit_root/worker-kit.json")"
echo "worker-kit native contract passed (platform=$platform target=$target_value)"
