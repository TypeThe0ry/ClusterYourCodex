use std::collections::BTreeSet;
use std::env;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result};
use chrono::Utc;
use cyc_protocol::worker::ProbeReport;
use cyc_protocol::{
    Architecture, Capability, GpuDevice, GpuVendor, NodeLoad, NodeResources, OperatingSystem,
    PROTOCOL_VERSION,
};
use sysinfo::{Disks, System};

pub mod artifacts;
pub mod config;
pub mod executor;
pub mod http;
pub mod process;
pub mod runtime;
pub mod security;
pub mod source;

const MIB: u64 = 1024 * 1024;

pub fn probe() -> ProbeReport {
    let workspace = env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    probe_at(&workspace).unwrap_or_else(|_| conservative_probe())
}

/// Probe resources relative to the configured workspace. Disk capacity is
/// reported for the volume that actually owns that workspace, never as a sum
/// of unrelated mounts.
pub fn probe_at(workspace: &Path) -> Result<ProbeReport> {
    let mut system = System::new_all();
    system.refresh_all();
    let disks = Disks::new_with_refreshed_list();

    let mut capabilities = detect_tools();
    let gpus = probe_nvidia_gpus();
    if !gpus.is_empty() {
        capabilities.insert(Capability::new("gpu.nvidia"));
    }
    capabilities.insert(Capability::new(format!("os.{}", normalized_os_name())));
    capabilities.insert(Capability::new(format!("arch.{}", normalized_arch_name())));
    let logical_cores = u32::try_from(system.cpus().len().max(1)).unwrap_or(u32::MAX);
    let cpu_percent = system.global_cpu_usage().round().clamp(0.0, 100.0) as u8;
    let busy_cores = (u64::from(logical_cores) * u64::from(cpu_percent)).div_ceil(100);
    let available_cpu_cores =
        u32::try_from(u64::from(logical_cores).saturating_sub(busy_cores).max(1)).unwrap_or(1);
    let (disk_mib, available_disk_mib) = workspace_disk(&disks, workspace)?;
    let report = ProbeReport {
        protocol_version: PROTOCOL_VERSION,
        agent_version: env!("CARGO_PKG_VERSION").to_owned(),
        observed_at: Utc::now(),
        hostname: System::host_name().unwrap_or_else(|| "unknown".to_owned()),
        os: normalized_os(),
        arch: normalized_arch(),
        capabilities,
        resources: NodeResources {
            logical_cpu_cores: logical_cores,
            available_cpu_cores,
            memory_mib: (system.total_memory() / MIB).max(1),
            available_memory_mib: system.available_memory() / MIB,
            disk_mib: disk_mib.max(1),
            available_disk_mib,
            gpus,
        },
        load: NodeLoad {
            cpu_percent,
            queue_depth: 0,
            running_jobs: 0,
        },
    };
    report.validate().context("validate local probe")?;
    Ok(report)
}

fn conservative_probe() -> ProbeReport {
    ProbeReport {
        protocol_version: PROTOCOL_VERSION,
        agent_version: env!("CARGO_PKG_VERSION").to_owned(),
        observed_at: Utc::now(),
        hostname: System::host_name().unwrap_or_else(|| "unknown".to_owned()),
        os: normalized_os(),
        arch: normalized_arch(),
        capabilities: BTreeSet::new(),
        resources: NodeResources {
            logical_cpu_cores: 1,
            available_cpu_cores: 1,
            memory_mib: 1,
            available_memory_mib: 0,
            disk_mib: 1,
            available_disk_mib: 0,
            gpus: Vec::new(),
        },
        load: NodeLoad::default(),
    }
}

fn normalized_os() -> OperatingSystem {
    match env::consts::OS {
        "windows" => OperatingSystem::Windows,
        "macos" => OperatingSystem::Macos,
        _ => OperatingSystem::Linux,
    }
}

fn normalized_os_name() -> &'static str {
    match normalized_os() {
        OperatingSystem::Windows => "windows",
        OperatingSystem::Linux => "linux",
        OperatingSystem::Macos => "macos",
    }
}

fn normalized_arch() -> Architecture {
    match env::consts::ARCH {
        "aarch64" => Architecture::Aarch64,
        _ => Architecture::X86_64,
    }
}

fn normalized_arch_name() -> &'static str {
    match normalized_arch() {
        Architecture::X86_64 => "x86_64",
        Architecture::Aarch64 => "aarch64",
    }
}

fn detect_tools() -> BTreeSet<Capability> {
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
    .filter_map(|(binary, capability)| find_executable(binary).map(|_| Capability::new(capability)))
    .collect::<BTreeSet<_>>();
    if visual_studio_installed() {
        capabilities.insert(Capability::new("tool.msvc"));
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

fn probe_nvidia_gpus() -> Vec<GpuDevice> {
    let Some(executable) = find_executable("nvidia-smi") else {
        return Vec::new();
    };
    let Ok(output) = Command::new(executable)
        .args([
            "--query-gpu=name,memory.total,memory.free,driver_version",
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
            let total_vram_mib: u64 = fields.next().and_then(|value| value.parse().ok())?;
            let available_vram_mib: u64 = fields.next().and_then(|value| value.parse().ok())?;
            let _driver_version = fields.next();
            if name.is_empty() || total_vram_mib == 0 {
                return None;
            }
            Some(GpuDevice {
                vendor: GpuVendor::Nvidia,
                model: name,
                total_vram_mib,
                available_vram_mib: available_vram_mib.min(total_vram_mib),
                allocatable: true,
            })
        })
        .collect()
}

fn workspace_disk(disks: &Disks, workspace: &Path) -> Result<(u64, u64)> {
    let mut existing = workspace;
    while !existing.exists() {
        existing = existing
            .parent()
            .context("workspace has no existing ancestor")?;
    }
    let canonical = existing
        .canonicalize()
        .with_context(|| format!("canonicalize workspace ancestor {}", existing.display()))?;
    let selected = disks
        .iter()
        .filter(|disk| workspace_is_on_mount(&canonical, disk.mount_point()))
        .max_by_key(|disk| disk.mount_point().components().count())
        .context("no mounted disk contains the configured workspace")?;
    Ok((
        selected.total_space() / MIB,
        selected.available_space() / MIB,
    ))
}

#[cfg(not(windows))]
fn workspace_is_on_mount(workspace: &Path, mount: &Path) -> bool {
    workspace.starts_with(mount)
}

#[cfg(windows)]
fn workspace_is_on_mount(workspace: &Path, mount: &Path) -> bool {
    let Some(workspace) = WindowsPathIdentity::parse(workspace) else {
        return false;
    };
    let Some(mount) = WindowsPathIdentity::parse(mount) else {
        return false;
    };
    workspace.volume.matches(&mount.volume)
        && mount.components.len() <= workspace.components.len()
        && mount
            .components
            .iter()
            .zip(&workspace.components)
            .all(|(mount, workspace)| windows_component_eq(mount, workspace))
}

#[cfg(windows)]
#[derive(Debug)]
enum WindowsVolumeIdentity<'a> {
    Disk(u8),
    Unc(&'a std::ffi::OsStr, &'a std::ffi::OsStr),
    Verbatim(&'a std::ffi::OsStr),
    Device(&'a std::ffi::OsStr),
}

#[cfg(windows)]
impl WindowsVolumeIdentity<'_> {
    fn matches(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::Disk(left), Self::Disk(right)) => left.eq_ignore_ascii_case(right),
            (Self::Unc(left_server, left_share), Self::Unc(right_server, right_share)) => {
                windows_component_eq(left_server, right_server)
                    && windows_component_eq(left_share, right_share)
            }
            (Self::Verbatim(left), Self::Verbatim(right))
            | (Self::Device(left), Self::Device(right)) => windows_component_eq(left, right),
            _ => false,
        }
    }
}

#[cfg(windows)]
#[derive(Debug)]
struct WindowsPathIdentity<'a> {
    volume: WindowsVolumeIdentity<'a>,
    components: Vec<&'a std::ffi::OsStr>,
}

#[cfg(windows)]
impl<'a> WindowsPathIdentity<'a> {
    fn parse(path: &'a Path) -> Option<Self> {
        use std::path::{Component, Prefix};

        let mut components = path.components();
        let Component::Prefix(prefix) = components.next()? else {
            return None;
        };
        let volume = match prefix.kind() {
            Prefix::Disk(drive) | Prefix::VerbatimDisk(drive) => WindowsVolumeIdentity::Disk(drive),
            Prefix::UNC(server, share) | Prefix::VerbatimUNC(server, share) => {
                WindowsVolumeIdentity::Unc(server, share)
            }
            Prefix::Verbatim(name) => WindowsVolumeIdentity::Verbatim(name),
            Prefix::DeviceNS(name) => WindowsVolumeIdentity::Device(name),
        };
        if !matches!(components.next(), Some(Component::RootDir)) {
            // Reject drive-relative paths such as C:workspace. Both canonical
            // workspace paths and disk mount points must identify a root.
            return None;
        }
        let mut normal = Vec::new();
        for component in components {
            match component {
                Component::Normal(value) => normal.push(value),
                Component::CurDir => {}
                Component::ParentDir | Component::RootDir | Component::Prefix(_) => return None,
            }
        }
        Some(Self {
            volume,
            components: normal,
        })
    }
}

#[cfg(windows)]
fn windows_component_eq(left: &std::ffi::OsStr, right: &std::ffi::OsStr) -> bool {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Globalization::{CompareStringOrdinal, CSTR_EQUAL};

    let left = left.encode_wide().collect::<Vec<_>>();
    let right = right.encode_wide().collect::<Vec<_>>();
    let (Ok(left_len), Ok(right_len)) = (i32::try_from(left.len()), i32::try_from(right.len()))
    else {
        return false;
    };
    unsafe {
        CompareStringOrdinal(
            left.as_ptr(),
            left_len,
            right.as_ptr(),
            right_len,
            true.into(),
        ) == CSTR_EQUAL
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn probe_is_serializable_and_contains_no_secret_fields() {
        let report = probe();
        let json = serde_json::to_string(&report).unwrap();
        assert!(json.contains("protocolVersion"));
        for forbidden in ["password", "privateKey", "secret", "credential", "token"] {
            assert!(!json.contains(forbidden), "probe leaked field {forbidden}");
        }
    }

    #[test]
    fn current_platform_is_normalized() {
        assert!(!normalized_os_name().is_empty());
        assert!(!normalized_arch_name().is_empty());
    }

    #[cfg(windows)]
    #[test]
    fn windows_mount_matching_normalizes_prefix_case_and_separators() {
        let cases = [
            (r"\\?\C:\Worker\Jobs\1", r"C:\", true),
            (r"c:/Worker/Jobs/1", r"C:\", true),
            (r"C:\WORKER\Jobs\1", r"\\?\c:\worker", true),
            (r"C:\worker-other\Jobs\1", r"C:\worker", false),
            (r"\\?\D:\Worker\Jobs\1", r"C:\", false),
            (r"\\?\UNC\SERVER\Share\Worker\1", r"\\server\share\", true),
            (
                r"\\server\share\Worker\1",
                r"\\?\UNC\server\SHARE\worker",
                true,
            ),
            (
                r"\\?\UNC\server\share-other\Worker\1",
                r"\\server\share\",
                false,
            ),
            (
                r"\\?\UNC\server-two\share\Worker\1",
                r"\\server\share\",
                false,
            ),
        ];

        for (workspace, mount, expected) in cases {
            assert_eq!(
                workspace_is_on_mount(Path::new(workspace), Path::new(mount)),
                expected,
                "workspace={workspace:?}, mount={mount:?}"
            );
        }
    }

    #[cfg(windows)]
    #[test]
    fn probe_at_accepts_a_real_temporary_windows_workspace() {
        let directory = tempfile::tempdir().unwrap();
        let canonical = directory.path().canonicalize().unwrap();
        assert!(
            canonical.to_string_lossy().starts_with(r"\\?\"),
            "test requires the Windows extended-length canonical form: {}",
            canonical.display()
        );

        let report = probe_at(directory.path()).unwrap();
        assert!(report.resources.disk_mib > 0);
        assert!(report.resources.available_disk_mib <= report.resources.disk_mib);
    }
}
