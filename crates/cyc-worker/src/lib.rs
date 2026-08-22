use std::collections::BTreeSet;
use std::env;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Command;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sysinfo::{Disks, System};

const MIB: u64 = 1024 * 1024;

/// A transport-neutral hardware and toolchain report. It deliberately contains
/// no endpoint credentials or environment-variable values.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ProbeReport {
    pub api_version: String,
    pub generated_at: DateTime<Utc>,
    pub hostname: String,
    pub os: String,
    pub arch: String,
    pub os_version: Option<String>,
    pub cpu: CpuProbe,
    pub memory_total_mib: u64,
    pub disk_available_mib: u64,
    pub capabilities: BTreeSet<String>,
    pub gpus: Vec<GpuProbe>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CpuProbe {
    pub logical_cores: usize,
    pub model: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GpuProbe {
    pub vendor: String,
    pub name: String,
    pub memory_total_mib: Option<u64>,
    pub driver_version: Option<String>,
}

pub fn probe() -> ProbeReport {
    let mut system = System::new_all();
    system.refresh_all();
    let disks = Disks::new_with_refreshed_list();

    let mut capabilities = detect_tools();
    let gpus = probe_nvidia_gpus();
    if !gpus.is_empty() {
        capabilities.insert("gpu.nvidia".to_owned());
    }
    capabilities.insert(format!("os.{}", normalized_os()));
    capabilities.insert(format!("arch.{}", normalized_arch()));

    ProbeReport {
        api_version: "cyc.dev/worker-probe/v1".to_owned(),
        generated_at: Utc::now(),
        hostname: System::host_name().unwrap_or_else(|| "unknown".to_owned()),
        os: normalized_os().to_owned(),
        arch: normalized_arch().to_owned(),
        os_version: System::long_os_version(),
        cpu: CpuProbe {
            logical_cores: system.cpus().len().max(1),
            model: system
                .cpus()
                .first()
                .map(|cpu| cpu.brand().trim().to_owned())
                .filter(|model| !model.is_empty()),
        },
        memory_total_mib: system.total_memory() / MIB,
        disk_available_mib: disks.iter().map(|disk| disk.available_space()).sum::<u64>() / MIB,
        capabilities,
        gpus,
    }
}

fn normalized_os() -> &'static str {
    env::consts::OS
}

fn normalized_arch() -> &'static str {
    env::consts::ARCH
}

fn detect_tools() -> BTreeSet<String> {
    let mut capabilities = [
        ("git", "tool.git"),
        ("docker", "tool.docker"),
        ("cargo", "tool.cargo"),
        ("rustc", "tool.rustc"),
        ("node", "tool.node"),
        ("pnpm", "tool.pnpm"),
        ("python", "tool.python"),
        ("python3", "tool.python"),
        ("cmake", "tool.cmake"),
        ("ninja", "tool.ninja"),
        ("cl", "tool.msvc"),
        ("xcodebuild", "tool.xcode"),
        ("nvcc", "tool.cuda"),
        ("nvidia-smi", "tool.nvidia-smi"),
    ]
    .into_iter()
    .filter_map(|(binary, capability)| find_executable(binary).map(|_| capability.to_owned()))
    .collect::<BTreeSet<_>>();
    if visual_studio_installed() {
        capabilities.insert("tool.msvc".to_owned());
    }
    capabilities
}

fn visual_studio_installed() -> bool {
    if !cfg!(windows) {
        return false;
    }
    ["ProgramFiles(x86)", "ProgramFiles"]
        .into_iter()
        .filter_map(env::var_os)
        .map(PathBuf::from)
        .map(|root| {
            root.join("Microsoft Visual Studio")
                .join("Installer")
                .join("vswhere.exe")
        })
        .any(|path| path.is_file())
}

fn executable_extensions() -> Vec<OsString> {
    if cfg!(windows) {
        env::var_os("PATHEXT")
            .map(|value| {
                value
                    .to_string_lossy()
                    .split(';')
                    .filter(|item| !item.is_empty())
                    .map(OsString::from)
                    .collect()
            })
            .unwrap_or_else(|| {
                [".COM", ".EXE", ".BAT", ".CMD"]
                    .into_iter()
                    .map(OsString::from)
                    .collect()
            })
    } else {
        vec![OsString::new()]
    }
}

fn find_executable(name: &str) -> Option<PathBuf> {
    let path = Path::new(name);
    if path.components().count() > 1 && path.is_file() {
        return Some(path.to_owned());
    }

    let search_path = env::var_os("PATH")?;
    let extensions = executable_extensions();
    for directory in env::split_paths(&search_path) {
        for extension in &extensions {
            let mut filename = OsString::from(name);
            filename.push(extension);
            let candidate = directory.join(filename);
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    None
}

fn probe_nvidia_gpus() -> Vec<GpuProbe> {
    let Some(executable) = find_executable("nvidia-smi") else {
        return Vec::new();
    };
    let Ok(output) = Command::new(executable)
        .args([
            "--query-gpu=name,memory.total,driver_version",
            "--format=csv,noheader,nounits",
        ])
        .output()
    else {
        return Vec::new();
    };
    if !output.status.success() {
        return Vec::new();
    }

    String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| {
            let mut fields = line.split(',').map(str::trim);
            let name = fields.next()?.to_owned();
            let memory_total_mib = fields.next().and_then(|value| value.parse().ok());
            let driver_version = fields
                .next()
                .map(str::to_owned)
                .filter(|value| !value.is_empty());
            if name.is_empty() {
                return None;
            }
            Some(GpuProbe {
                vendor: "nvidia".to_owned(),
                name,
                memory_total_mib,
                driver_version,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn probe_is_serializable_and_contains_no_secret_fields() {
        let report = probe();
        let json = serde_json::to_string(&report).unwrap();
        assert!(json.contains("apiVersion"));
        for forbidden in ["password", "privateKey", "secret", "credential", "token"] {
            assert!(!json.contains(forbidden), "probe leaked field {forbidden}");
        }
    }

    #[test]
    fn current_platform_is_normalized() {
        assert!(!normalized_os().is_empty());
        assert!(!normalized_arch().is_empty());
    }
}
