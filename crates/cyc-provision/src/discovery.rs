use std::collections::BTreeMap;

use base64::{engine::general_purpose::STANDARD, Engine as _};
use thiserror::Error;

use crate::{DiscoveredComputer, GpuInventory};

pub(crate) const MAX_DISCOVERY_OUTPUT_BYTES: usize = 256 * 1024;
const MAX_DISCOVERY_LINES: usize = 256;
const MAX_LINE_BYTES: usize = 4 * 1024;
const MAX_VALUE_BYTES: usize = 512;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RemotePlatform {
    Linux,
    Macos,
    Windows,
}

impl RemotePlatform {
    #[must_use]
    pub fn operating_system(self) -> &'static str {
        match self {
            Self::Linux => "linux",
            Self::Macos => "macos",
            Self::Windows => "windows",
        }
    }

    pub(crate) fn discovery_file_name(self) -> &'static str {
        match self {
            Self::Linux => "cyc-discovery.sh",
            Self::Macos => "cyc-discovery-macos.sh",
            Self::Windows => "cyc-discovery.ps1",
        }
    }

    pub(crate) fn discovery_script(self) -> &'static [u8] {
        match self {
            Self::Linux => LINUX_DISCOVERY_SCRIPT.as_bytes(),
            Self::Macos => MACOS_DISCOVERY_SCRIPT.as_bytes(),
            Self::Windows => WINDOWS_DISCOVERY_SCRIPT.as_bytes(),
        }
    }
}

pub(crate) fn parse_discovery(
    content: &[u8],
    expected_platform: RemotePlatform,
) -> Result<DiscoveredComputer, DiscoveryError> {
    if content.is_empty() || content.len() > MAX_DISCOVERY_OUTPUT_BYTES {
        return Err(DiscoveryError::SizeLimit);
    }
    let text = std::str::from_utf8(content).map_err(|_| DiscoveryError::InvalidEncoding)?;
    if text.contains('\0') {
        return Err(DiscoveryError::InvalidEncoding);
    }
    let mut lines = text.lines();
    if lines.next() != Some("CYC_DISCOVERY_V1") {
        return Err(DiscoveryError::InvalidHeader);
    }

    let mut scalar = BTreeMap::new();
    let mut gpus = Vec::new();
    let mut toolchains = BTreeMap::new();
    let mut count = 1_usize;
    for line in lines {
        count += 1;
        if count > MAX_DISCOVERY_LINES || line.is_empty() || line.len() > MAX_LINE_BYTES {
            return Err(DiscoveryError::SizeLimit);
        }
        let (key, value) = line.split_once('=').ok_or(DiscoveryError::InvalidField)?;
        match key {
            "hostname"
            | "operating_system"
            | "architecture"
            | "cpu_model"
            | "logical_cpu_count"
            | "memory_bytes"
            | "workspace_free_bytes" => {
                if scalar.insert(key, value).is_some() {
                    return Err(DiscoveryError::DuplicateField);
                }
            }
            "gpu" => gpus.push(parse_gpu(value)?),
            "tool" => {
                let (name, version) = value.split_once('|').ok_or(DiscoveryError::InvalidField)?;
                let name = decode_value(name)?;
                let version = decode_value(version)?;
                if toolchains.insert(name, version).is_some() {
                    return Err(DiscoveryError::DuplicateField);
                }
            }
            _ => return Err(DiscoveryError::UnknownField),
        }
    }

    let operating_system = required_plain(&scalar, "operating_system")?;
    if operating_system != expected_platform.operating_system() {
        return Err(DiscoveryError::PlatformMismatch);
    }
    let architecture = required_plain(&scalar, "architecture")?;
    if !matches!(architecture.as_str(), "x86_64" | "aarch64") {
        return Err(DiscoveryError::InvalidField);
    }
    let discovered = DiscoveredComputer {
        hostname: decode_value(required(&scalar, "hostname")?)?,
        operating_system,
        architecture,
        cpu_model: decode_value(required(&scalar, "cpu_model")?)?,
        logical_cpu_count: parse_number(required(&scalar, "logical_cpu_count")?)?,
        memory_bytes: parse_number(required(&scalar, "memory_bytes")?)?,
        workspace_free_bytes: parse_number(required(&scalar, "workspace_free_bytes")?)?,
        gpu_devices: gpus,
        toolchains,
    };
    discovered
        .validate()
        .map_err(|_| DiscoveryError::InvalidField)?;
    Ok(discovered)
}

fn parse_gpu(value: &str) -> Result<GpuInventory, DiscoveryError> {
    let mut components = value.split('|');
    let name = decode_value(components.next().ok_or(DiscoveryError::InvalidField)?)?;
    let stable_id = components.next().ok_or(DiscoveryError::InvalidField)?;
    let memory = components.next().ok_or(DiscoveryError::InvalidField)?;
    if components.next().is_some() {
        return Err(DiscoveryError::InvalidField);
    }
    Ok(GpuInventory {
        name,
        stable_device_id: if stable_id.is_empty() {
            None
        } else {
            Some(decode_value(stable_id)?)
        },
        memory_bytes: if memory.is_empty() {
            None
        } else {
            Some(parse_number(memory)?)
        },
    })
}

fn required<'a>(
    fields: &'a BTreeMap<&str, &str>,
    name: &'static str,
) -> Result<&'a str, DiscoveryError> {
    fields
        .get(name)
        .copied()
        .ok_or(DiscoveryError::MissingField)
}

fn required_plain(
    fields: &BTreeMap<&str, &str>,
    name: &'static str,
) -> Result<String, DiscoveryError> {
    let value = required(fields, name)?;
    if value.is_empty()
        || value.len() > MAX_VALUE_BYTES
        || value
            .bytes()
            .any(|byte| !byte.is_ascii_lowercase() && byte != b'_' && !byte.is_ascii_digit())
    {
        return Err(DiscoveryError::InvalidField);
    }
    Ok(value.to_owned())
}

fn decode_value(value: &str) -> Result<String, DiscoveryError> {
    if value.len() > MAX_VALUE_BYTES.saturating_mul(2) {
        return Err(DiscoveryError::SizeLimit);
    }
    let bytes = STANDARD
        .decode(value.as_bytes())
        .map_err(|_| DiscoveryError::InvalidEncoding)?;
    if bytes.is_empty() || bytes.len() > MAX_VALUE_BYTES {
        return Err(DiscoveryError::SizeLimit);
    }
    let value = String::from_utf8(bytes).map_err(|_| DiscoveryError::InvalidEncoding)?;
    if value.chars().any(char::is_control) {
        return Err(DiscoveryError::InvalidField);
    }
    Ok(value)
}

fn parse_number<T>(value: &str) -> Result<T, DiscoveryError>
where
    T: std::str::FromStr,
{
    if value.is_empty() || value.len() > 20 || !value.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(DiscoveryError::InvalidField);
    }
    value.parse().map_err(|_| DiscoveryError::InvalidField)
}

#[derive(Clone, Copy, Debug, Error, PartialEq, Eq)]
pub enum DiscoveryError {
    #[error("discovery output exceeded a safety limit")]
    SizeLimit,
    #[error("discovery output encoding is invalid")]
    InvalidEncoding,
    #[error("discovery output header is invalid")]
    InvalidHeader,
    #[error("discovery output field is invalid")]
    InvalidField,
    #[error("discovery output contains an unknown field")]
    UnknownField,
    #[error("discovery output contains a duplicate field")]
    DuplicateField,
    #[error("discovery output is missing a required field")]
    MissingField,
    #[error("discovery output platform does not match the executed probe")]
    PlatformMismatch,
}

const LINUX_DISCOVERY_SCRIPT: &str = r#"#!/bin/sh
set -eu
umask 077
export LC_ALL=C
[ "${1:-}" != "--" ] || shift
[ "$(uname -s 2>/dev/null || true)" = "Linux" ] || exit 3
workspace="${1:-${HOME:-/tmp}}"
b64() { printf '%s' "$1" | base64 | tr -d '\r\n'; }
one_line() { printf '%s' "$1" | tr '\r\n' '  ' | cut -c1-512; }
architecture="$(uname -m 2>/dev/null || true)"
case "$architecture" in
  x86_64|amd64) architecture=x86_64 ;;
  aarch64|arm64) architecture=aarch64 ;;
  *) architecture=unsupported ;;
esac
hostname_value="$(hostname 2>/dev/null || uname -n)"
cpu_model="$(awk -F: '/^(model name|Hardware)[[:space:]]*:/{sub(/^[[:space:]]+/,"",$2);print $2;exit}' /proc/cpuinfo 2>/dev/null || true)"
[ -n "$cpu_model" ] || cpu_model="unknown-cpu"
logical_cpu_count="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')"
memory_kib="$(awk '/^MemTotal:/{print $2;exit}' /proc/meminfo 2>/dev/null || printf '0')"
case "$memory_kib" in ''|*[!0-9]*) memory_kib=0 ;; esac
memory_bytes=$((memory_kib * 1024))
workspace_free_bytes="$(df -Pk -- "$workspace" 2>/dev/null | awk 'NR==2{print $4 * 1024}' | cut -d. -f1 || true)"
case "$workspace_free_bytes" in ''|*[!0-9]*) workspace_free_bytes=0 ;; esac
printf 'CYC_DISCOVERY_V1\n'
printf 'hostname=%s\n' "$(b64 "$(one_line "$hostname_value")")"
printf 'operating_system=linux\n'
printf 'architecture=%s\n' "$architecture"
printf 'cpu_model=%s\n' "$(b64 "$(one_line "$cpu_model")")"
printf 'logical_cpu_count=%s\n' "$logical_cpu_count"
printf 'memory_bytes=%s\n' "$memory_bytes"
printf 'workspace_free_bytes=%s\n' "$workspace_free_bytes"
tool_version() {
  tool="$1"
  command -v "$tool" >/dev/null 2>&1 || return 0
  if command -v timeout >/dev/null 2>&1; then
    version="$(timeout 2 "$tool" --version 2>/dev/null | head -n 1 || true)"
  else
    version="present"
  fi
  [ -n "$version" ] || version=present
  printf 'tool=%s|%s\n' "$(b64 "$tool")" "$(b64 "$(one_line "$version")")"
}
for tool in git cargo rustc docker cmake ninja node python3 nvidia-smi; do tool_version "$tool"; done
if command -v nvidia-smi >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
  timeout 3 nvidia-smi --query-gpu=name,uuid,memory.total --format=csv,noheader,nounits 2>/dev/null |
  while IFS=, read -r name uuid memory_mib; do
    name="$(printf '%s' "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    uuid="$(printf '%s' "$uuid" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    memory_mib="$(printf '%s' "$memory_mib" | tr -cd '0-9')"
    [ -n "$name" ] || continue
    [ -n "$memory_mib" ] || memory_mib=0
    printf 'gpu=%s|%s|%s\n' "$(b64 "$(one_line "$name")")" "$(b64 "$(one_line "$uuid")")" "$((memory_mib * 1024 * 1024))"
  done
fi
"#;

const MACOS_DISCOVERY_SCRIPT: &str = r#"#!/bin/sh
set -eu
umask 077
export LC_ALL=C
[ "${1:-}" != "--" ] || shift
[ "$(uname -s 2>/dev/null || true)" = "Darwin" ] || exit 3
workspace="${1:-${HOME:-/tmp}}"
b64() { printf '%s' "$1" | base64 | tr -d '\r\n'; }
one_line() { printf '%s' "$1" | tr '\r\n' '  ' | cut -c1-512; }
architecture="$(uname -m 2>/dev/null || true)"
case "$architecture" in
  x86_64|amd64) architecture=x86_64 ;;
  arm64|aarch64) architecture=aarch64 ;;
  *) architecture=unsupported ;;
esac
hostname_value="$(hostname 2>/dev/null || uname -n)"
cpu_model="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)"
[ -n "$cpu_model" ] || cpu_model="$(sysctl -n hw.model 2>/dev/null || true)"
[ -n "$cpu_model" ] || cpu_model="unknown-cpu"
logical_cpu_count="$(sysctl -n hw.logicalcpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')"
case "$logical_cpu_count" in ''|*[!0-9]*|0) logical_cpu_count=1 ;; esac
memory_bytes="$(sysctl -n hw.memsize 2>/dev/null || printf '0')"
case "$memory_bytes" in ''|*[!0-9]*) memory_bytes=0 ;; esac
workspace_free_bytes="$(df -Pk "$workspace" 2>/dev/null | awk 'NR==2{printf "%.0f", $4 * 1024}' || true)"
case "$workspace_free_bytes" in ''|*[!0-9]*) workspace_free_bytes=0 ;; esac
printf 'CYC_DISCOVERY_V1\n'
printf 'hostname=%s\n' "$(b64 "$(one_line "$hostname_value")")"
printf 'operating_system=macos\n'
printf 'architecture=%s\n' "$architecture"
printf 'cpu_model=%s\n' "$(b64 "$(one_line "$cpu_model")")"
printf 'logical_cpu_count=%s\n' "$logical_cpu_count"
printf 'memory_bytes=%s\n' "$memory_bytes"
printf 'workspace_free_bytes=%s\n' "$workspace_free_bytes"
tool_version() {
  tool="$1"
  command -v "$tool" >/dev/null 2>&1 || return 0
  version=present
  timeout_tool=''
  if command -v timeout >/dev/null 2>&1; then timeout_tool=timeout
  elif command -v gtimeout >/dev/null 2>&1; then timeout_tool=gtimeout
  fi
  if [ -n "$timeout_tool" ]; then
    observed="$($timeout_tool 2 "$tool" --version 2>/dev/null | head -n 1 || true)"
    [ -z "$observed" ] || version="$observed"
  fi
  printf 'tool=%s|%s\n' "$(b64 "$tool")" "$(b64 "$(one_line "$version")")"
}
for tool in git cargo rustc docker cmake ninja node python3 xcrun swift; do tool_version "$tool"; done
"#;

const WINDOWS_DISCOVERY_SCRIPT: &str = r#"param([string]$WorkspaceRoot = '')
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
function B64([string]$Value) {
    if ($Value.Length -gt 512) { $Value = $Value.Substring(0, 512) }
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
}
function OneLine([string]$Value) { return (($Value -replace '[\r\n]+', ' ').Trim()) }
function ToolVersion([string]$Name) {
    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { return }
    $version = $null
    try {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $command.Source
        $psi.Arguments = '--version'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($psi)
        if ($process.WaitForExit(2000)) {
            $version = ($process.StandardOutput.ReadLine())
            if (-not $version) { $version = $process.StandardError.ReadLine() }
        } else {
            $process.Kill()
        }
    } catch { $version = $null }
    if (-not $version) { $version = 'present' }
    Write-Output ('tool=' + (B64 $Name) + '|' + (B64 (OneLine $version)))
}
$architecture = switch ($env:PROCESSOR_ARCHITECTURE.ToUpperInvariant()) {
    'AMD64' { 'x86_64' }
    'ARM64' { 'aarch64' }
    default { 'unsupported' }
}
$computer = Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 3
$processor = Get-CimInstance Win32_Processor -OperationTimeoutSec 3 | Select-Object -First 1
if (-not $WorkspaceRoot) { $WorkspaceRoot = $env:LOCALAPPDATA }
$root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($WorkspaceRoot)).TrimEnd('\')
$drive = Get-PSDrive -Name $root.TrimEnd(':') -ErrorAction Stop
Write-Output 'CYC_DISCOVERY_V1'
Write-Output ('hostname=' + (B64 (OneLine ([Environment]::MachineName))))
Write-Output 'operating_system=windows'
Write-Output ('architecture=' + $architecture)
Write-Output ('cpu_model=' + (B64 (OneLine ([string]$processor.Name))))
Write-Output ('logical_cpu_count=' + [Environment]::ProcessorCount)
Write-Output ('memory_bytes=' + [uint64]$computer.TotalPhysicalMemory)
Write-Output ('workspace_free_bytes=' + [uint64]$drive.Free)
foreach ($tool in @('git','cargo','rustc','docker','cmake','ninja','node','python','nvidia-smi')) { ToolVersion $tool }
foreach ($gpu in @(Get-CimInstance Win32_VideoController -OperationTimeoutSec 3)) {
    $memory = if ($null -eq $gpu.AdapterRAM) { '' } else { [string][uint64]$gpu.AdapterRAM }
    Write-Output ('gpu=' + (B64 (OneLine ([string]$gpu.Name))) + '|' + (B64 (OneLine ([string]$gpu.PNPDeviceID))) + '|' + $memory)
}
"#;

#[cfg(test)]
mod tests {
    use base64::{engine::general_purpose::STANDARD, Engine as _};

    use super::{parse_discovery, DiscoveryError, RemotePlatform, MAX_DISCOVERY_OUTPUT_BYTES};

    fn b64(value: &str) -> String {
        STANDARD.encode(value)
    }

    #[test]
    fn strict_line_protocol_parses_bounded_inventory() {
        let payload = format!(
            "CYC_DISCOVERY_V1\nhostname={}\noperating_system=linux\narchitecture=x86_64\ncpu_model={}\nlogical_cpu_count=16\nmemory_bytes=34359738368\nworkspace_free_bytes=999\ngpu={}|{}|8589934592\ntool={}|{}\n",
            b64("worker-01"),
            b64("Fixture CPU"),
            b64("Fixture GPU"),
            b64("GPU-1"),
            b64("cargo"),
            b64("cargo 1.90.0"),
        );
        let inventory = parse_discovery(payload.as_bytes(), RemotePlatform::Linux).unwrap();
        assert_eq!(inventory.hostname, "worker-01");
        assert_eq!(inventory.cpu_model, "Fixture CPU");
        assert_eq!(inventory.gpu_devices.len(), 1);
        assert_eq!(inventory.toolchains["cargo"], "cargo 1.90.0");
    }

    #[test]
    fn macos_inventory_is_platform_bound_and_supports_both_release_architectures() {
        for architecture in ["x86_64", "aarch64"] {
            let payload = format!(
                "CYC_DISCOVERY_V1\nhostname={}\noperating_system=macos\narchitecture={architecture}\ncpu_model={}\nlogical_cpu_count=10\nmemory_bytes=17179869184\nworkspace_free_bytes=999\ntool={}|{}\n",
                b64("mac-worker"),
                b64("Apple CPU"),
                b64("xcrun"),
                b64("present"),
            );
            let inventory = parse_discovery(payload.as_bytes(), RemotePlatform::Macos).unwrap();
            assert_eq!(inventory.operating_system, "macos");
            assert_eq!(inventory.architecture, architecture);
            assert_eq!(inventory.toolchains["xcrun"], "present");
            assert_eq!(
                parse_discovery(payload.as_bytes(), RemotePlatform::Linux),
                Err(DiscoveryError::PlatformMismatch)
            );
        }
    }

    #[test]
    fn platform_scripts_are_distinct_and_fail_closed_on_the_wrong_kernel() {
        assert_eq!(RemotePlatform::Macos.operating_system(), "macos");
        assert_eq!(
            RemotePlatform::Macos.discovery_file_name(),
            "cyc-discovery-macos.sh"
        );
        let linux = std::str::from_utf8(RemotePlatform::Linux.discovery_script()).unwrap();
        let macos = std::str::from_utf8(RemotePlatform::Macos.discovery_script()).unwrap();
        assert!(linux.contains("= \"Linux\" ] || exit 3"));
        assert!(macos.contains("= \"Darwin\" ] || exit 3"));
        assert!(macos.contains("operating_system=macos"));
        assert!(macos.contains("sysctl -n hw.memsize"));
        assert!(macos.contains("df -Pk \"$workspace\""));
    }

    #[test]
    fn parser_rejects_unknown_duplicate_and_oversized_output() {
        let base = format!(
            "CYC_DISCOVERY_V1\nhostname={}\noperating_system=windows\narchitecture=x86_64\ncpu_model={}\nlogical_cpu_count=1\nmemory_bytes=1\nworkspace_free_bytes=1\n",
            b64("host"),
            b64("cpu")
        );
        let duplicate = format!("{base}hostname={}\n", b64("other"));
        assert_eq!(
            parse_discovery(duplicate.as_bytes(), RemotePlatform::Windows),
            Err(DiscoveryError::DuplicateField)
        );
        let unknown = format!("{base}secret={}\n", b64("must-not-pass"));
        assert_eq!(
            parse_discovery(unknown.as_bytes(), RemotePlatform::Windows),
            Err(DiscoveryError::UnknownField)
        );
        assert_eq!(
            parse_discovery(
                &vec![b'x'; MAX_DISCOVERY_OUTPUT_BYTES + 1],
                RemotePlatform::Linux
            ),
            Err(DiscoveryError::SizeLimit)
        );
    }
}
