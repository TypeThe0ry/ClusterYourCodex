use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::ffi::OsString;
#[cfg(target_os = "linux")]
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result};
use chrono::Utc;
use cyc_protocol::worker::{NodeReportRequest, ProbeReport, WORKER_API_VERSION};
use cyc_protocol::{
    Architecture, BatteryTelemetry, Capability, ContainmentBackend, ContainmentInventory,
    GpuDevice, GpuInventory, GpuTelemetry, GpuVendor, NodeInventory, NodeLoad, NodeResources,
    NodeStatus, NodeTelemetry, NodeTransport, OperatingSystem, PowerSource, PROTOCOL_VERSION,
};
use sysinfo::{Disks, System};
use uuid::Uuid;

pub mod artifacts;
pub mod config;
pub mod executor;
pub mod http;
pub mod isolation;
pub mod process;
pub mod runtime;
pub mod security;
pub mod source;

const MIB: u64 = 1024 * 1024;
const CPU_EWMA_ALPHA: f64 = 0.35;

pub fn probe() -> ProbeReport {
    let workspace = env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    probe_at_or_conservative(&workspace)
}

/// Pairing and claim compatibility probes fail closed on capacity rather than
/// terminating the daemon when an optional hardware/tool probe is unavailable.
pub fn probe_at_or_conservative(workspace: &Path) -> ProbeReport {
    probe_at(workspace).unwrap_or_else(|error| {
        eprintln!("worker compatibility probe degraded to conservative capacity: {error:#}");
        conservative_probe()
    })
}

/// Probe resources relative to the configured workspace. Disk capacity is
/// reported for the volume that actually owns that workspace, never as a sum
/// of unrelated mounts.
pub fn probe_at(workspace: &Path) -> Result<ProbeReport> {
    let mut sampler = NodeSampler::new(workspace)?;
    let node_report = sampler.sample(&[])?;
    let inventory = node_report
        .inventory
        .context("local sampler omitted initial inventory")?;
    let telemetry = node_report.telemetry;
    let gpus = inventory
        .gpus
        .iter()
        .zip(&telemetry.gpus)
        .map(|(inventory, telemetry)| GpuDevice {
            vendor: inventory.vendor,
            model: inventory.model.clone(),
            total_vram_mib: inventory.total_vram_mib,
            available_vram_mib: telemetry.available_vram_mib,
            allocatable: telemetry.allocatable,
        })
        .collect();
    let report = ProbeReport {
        protocol_version: PROTOCOL_VERSION,
        agent_version: env!("CARGO_PKG_VERSION").to_owned(),
        observed_at: telemetry.observed_at,
        hostname: System::host_name().unwrap_or_else(|| "unknown".to_owned()),
        os: inventory.os,
        arch: inventory.arch,
        capabilities: inventory.capabilities,
        resources: NodeResources {
            logical_cpu_cores: inventory.logical_cpu_cores,
            available_cpu_cores: telemetry.available_cpu_cores,
            memory_mib: inventory.memory_mib,
            available_memory_mib: telemetry.available_memory_mib,
            disk_mib: inventory.disk_mib,
            available_disk_mib: telemetry.available_disk_mib,
            gpus,
        },
        load: telemetry.load,
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
            available_cpu_cores: 0,
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

fn detect_tools() -> (BTreeSet<Capability>, BTreeMap<String, String>) {
    let mut capabilities = BTreeSet::new();
    let mut versions = BTreeMap::new();
    for (binary, capability, key, arguments) in [
        ("git", "tool.git", "git", &["--version"][..]),
        ("docker", "tool.docker", "docker", &["--version"][..]),
        ("cargo", "tool.cargo", "cargo", &["--version"][..]),
        ("rustc", "tool.rustc", "rustc", &["--version"][..]),
        ("node", "tool.node", "node", &["--version"][..]),
        ("pnpm", "tool.pnpm", "pnpm", &["--version"][..]),
        ("python", "tool.python", "python", &["--version"][..]),
        ("python3", "tool.python", "python", &["--version"][..]),
        ("cmake", "tool.cmake", "cmake", &["--version"][..]),
        ("ninja", "tool.ninja", "ninja", &["--version"][..]),
        ("xcodebuild", "tool.xcode", "xcodebuild", &["-version"][..]),
        ("nvcc", "tool.cuda", "nvcc", &["--version"][..]),
        (
            "nvidia-smi",
            "tool.nvidia-smi",
            "nvidia-smi",
            &["--version"][..],
        ),
    ] {
        let Some(executable) = find_executable(binary) else {
            continue;
        };
        capabilities.insert(Capability::new(capability));
        if !versions.contains_key(key) {
            let version = tool_version(&executable, arguments).unwrap_or_else(|| "present".into());
            versions.insert(key.to_owned(), version);
        }
    }
    if find_executable("cl").is_some() {
        capabilities.insert(Capability::new("tool.msvc"));
        versions.insert("msvc".to_owned(), "available-in-environment".to_owned());
    }
    if visual_studio_installed() {
        capabilities.insert(Capability::new("tool.msvc"));
        versions
            .entry("msvc".to_owned())
            .or_insert_with(|| "visual-studio-installed".to_owned());
    }
    (capabilities, versions)
}

fn tool_version(executable: &Path, arguments: &[&str]) -> Option<String> {
    let output = Command::new(executable).args(arguments).output().ok()?;
    if !output.status.success() {
        return None;
    }
    sanitize_version_output(&output.stdout).or_else(|| sanitize_version_output(&output.stderr))
}

fn sanitize_version_output(bytes: &[u8]) -> Option<String> {
    let output = String::from_utf8_lossy(bytes);
    let line = output
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())?;
    let sanitized = line
        .chars()
        .filter(|character| !character.is_control())
        .take(512)
        .collect::<String>();
    (!sanitized.is_empty()).then_some(sanitized)
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

#[derive(Clone, Debug, Eq, PartialEq)]
struct NvidiaGpuSample {
    stable_id: String,
    model: String,
    total_vram_mib: u64,
    available_vram_mib: u64,
    utilization_percent: Option<u8>,
    temperature_c: Option<i16>,
    driver_version: Option<String>,
}

fn probe_nvidia_gpus() -> Vec<NvidiaGpuSample> {
    let Some(executable) = find_executable("nvidia-smi") else {
        return Vec::new();
    };
    let Ok(output) = Command::new(executable)
        .args([
            "--query-gpu=uuid,name,memory.total,memory.free,utilization.gpu,temperature.gpu,driver_version",
            "--format=csv,noheader,nounits",
        ])
        .output()
    else {
        return Vec::new();
    };
    if !output.status.success() {
        return Vec::new();
    }

    parse_nvidia_smi_csv(&String::from_utf8_lossy(&output.stdout))
}

fn parse_nvidia_smi_csv(output: &str) -> Vec<NvidiaGpuSample> {
    output
        .lines()
        .filter_map(|line| {
            let fields = line.split(',').map(str::trim).collect::<Vec<_>>();
            if fields.len() != 7 {
                return None;
            }
            let stable_id = fields[0].to_owned();
            let model = fields[1].to_owned();
            let total_vram_mib = fields[2].parse::<u64>().ok()?;
            let available_vram_mib = fields[3].parse::<u64>().ok()?;
            if stable_id.is_empty() || model.is_empty() || total_vram_mib == 0 {
                return None;
            }
            Some(NvidiaGpuSample {
                stable_id,
                model,
                total_vram_mib,
                available_vram_mib: available_vram_mib.min(total_vram_mib),
                utilization_percent: parse_optional_percent(fields[4]),
                temperature_c: parse_optional_temperature(fields[5]),
                driver_version: parse_optional_text(fields[6]),
            })
        })
        .collect()
}

fn parse_optional_percent(value: &str) -> Option<u8> {
    value.parse::<u8>().ok().filter(|percent| *percent <= 100)
}

fn parse_optional_temperature(value: &str) -> Option<i16> {
    value
        .parse::<i16>()
        .ok()
        .filter(|temperature| (-100..=200).contains(temperature))
}

fn parse_optional_text(value: &str) -> Option<String> {
    (!value.is_empty() && value != "N/A").then(|| value.chars().take(128).collect())
}

/// Stateful dynamic sampler. CPU history, boot identity, and sequence belong
/// to one worker daemon lifetime and are never reconstructed from wall time.
pub struct NodeSampler {
    workspace: PathBuf,
    system: System,
    inventory: NodeInventory,
    boot_generation: u64,
    boot_id: Uuid,
    sequence: u64,
    cpu_ewma: Option<f64>,
    gpu_telemetry: Vec<GpuTelemetry>,
    conservative_capacity: bool,
}

impl NodeSampler {
    pub fn new(workspace: &Path) -> Result<Self> {
        Self::new_with_boot_generation(workspace, 0)
    }

    pub fn new_with_boot_generation(workspace: &Path, boot_generation: u64) -> Result<Self> {
        let mut system = System::new_all();
        system.refresh_all();
        let disks = Disks::new_with_refreshed_list();
        let (disk_mib, _) = workspace_disk(&disks, workspace)?;
        let (mut capabilities, mut tool_versions) = detect_tools();
        capabilities.insert(Capability::new(format!("os.{}", normalized_os_name())));
        capabilities.insert(Capability::new(format!("arch.{}", normalized_arch_name())));
        add_hostile_isolation_capabilities(&mut capabilities);
        let gpu_samples = probe_nvidia_gpus();
        if !gpu_samples.is_empty() {
            capabilities.insert(Capability::new("gpu.nvidia"));
        }
        if let Some(driver) = gpu_samples
            .iter()
            .find_map(|gpu| gpu.driver_version.clone())
        {
            tool_versions.insert("nvidia-driver".to_owned(), driver);
        }
        let logical_cpu_cores = u32::try_from(system.cpus().len().max(1)).unwrap_or(u32::MAX);
        let cpu_model = system
            .cpus()
            .first()
            .map(|cpu| cpu.brand().trim())
            .filter(|brand| !brand.is_empty())
            .unwrap_or("unknown")
            .chars()
            .take(512)
            .collect::<String>();
        let inventory = NodeInventory {
            transport: NodeTransport::Managed {
                endpoint: "worker-authenticated".to_owned(),
                credential_ref: cyc_protocol::CredentialRef::new("worker-authenticated"),
            },
            os: normalized_os(),
            arch: normalized_arch(),
            capabilities,
            logical_cpu_cores,
            memory_mib: (system.total_memory() / MIB).max(1),
            disk_mib: disk_mib.max(1),
            gpus: gpu_samples
                .iter()
                .map(|gpu| GpuInventory {
                    vendor: GpuVendor::Nvidia,
                    model: gpu.model.clone(),
                    total_vram_mib: gpu.total_vram_mib,
                    stable_id: Some(gpu.stable_id.clone()),
                    driver_version: gpu.driver_version.clone(),
                })
                .collect(),
            cpu_model,
            tool_versions,
            worker_version: env!("CARGO_PKG_VERSION").to_owned(),
            protocol_version: PROTOCOL_VERSION,
            containment: containment_inventory(),
        };
        let gpu_telemetry = gpu_samples
            .iter()
            .map(gpu_sample_telemetry)
            .collect::<Vec<_>>();
        inventory.validate().context("validate worker inventory")?;
        Ok(Self {
            workspace: workspace.to_owned(),
            system,
            inventory,
            boot_generation,
            boot_id: Uuid::new_v4(),
            sequence: 0,
            cpu_ewma: None,
            gpu_telemetry,
            conservative_capacity: false,
        })
    }

    /// Conservative construction is used only after a probe failure. It keeps
    /// the daemon alive and advertises zero allocatable resources rather than
    /// inventing capacity.
    pub fn conservative(workspace: &Path) -> Self {
        Self::conservative_with_boot_generation(workspace, 0)
    }

    pub fn conservative_with_boot_generation(workspace: &Path, boot_generation: u64) -> Self {
        let inventory = NodeInventory {
            transport: NodeTransport::Managed {
                endpoint: "worker-authenticated".to_owned(),
                credential_ref: cyc_protocol::CredentialRef::new("worker-authenticated"),
            },
            os: normalized_os(),
            arch: normalized_arch(),
            capabilities: {
                let mut capabilities = BTreeSet::new();
                add_hostile_isolation_capabilities(&mut capabilities);
                capabilities
            },
            logical_cpu_cores: 1,
            memory_mib: 1,
            disk_mib: 1,
            gpus: Vec::new(),
            cpu_model: "unknown".to_owned(),
            tool_versions: BTreeMap::new(),
            worker_version: env!("CARGO_PKG_VERSION").to_owned(),
            protocol_version: PROTOCOL_VERSION,
            containment: containment_inventory(),
        };
        Self {
            workspace: workspace.to_owned(),
            system: System::new(),
            inventory,
            boot_generation,
            boot_id: Uuid::new_v4(),
            sequence: 0,
            cpu_ewma: None,
            gpu_telemetry: Vec::new(),
            conservative_capacity: true,
        }
    }

    pub fn boot_generation(&self) -> u64 {
        self.boot_generation
    }

    pub fn boot_id(&self) -> Uuid {
        self.boot_id
    }

    pub fn next_sequence(&self) -> Option<u64> {
        self.sequence.checked_add(1)
    }

    pub fn sample(&mut self, active_run_ids: &[Uuid]) -> Result<NodeReportRequest> {
        let sequence = self
            .sequence
            .checked_add(1)
            .context("node telemetry sequence exhausted")?;
        self.system.refresh_cpu_usage();
        self.system.refresh_memory();
        let cpu_percent = self.system.global_cpu_usage().round().clamp(0.0, 100.0) as u8;
        let cpu_ewma_percent = update_cpu_ewma(&mut self.cpu_ewma, cpu_percent);
        let available_cpu_cores =
            available_cpu_cores(self.inventory.logical_cpu_cores, cpu_percent);
        let disks = Disks::new_with_refreshed_list();
        let (_, available_disk_mib) =
            workspace_disk(&disks, &self.workspace).unwrap_or((self.inventory.disk_mib, 0));

        // A managed Linux process tree relies on the daemon not spawning an
        // unrelated helper during execution. Keep the last full GPU sample
        // while active; CPU, memory, disk, power, and active IDs remain fresh.
        if active_run_ids.is_empty() {
            let samples = probe_nvidia_gpus();
            if samples.len() == self.inventory.gpus.len()
                && self.inventory.gpus.iter().all(|inventory| {
                    inventory.stable_id.as_ref().is_some_and(|stable_id| {
                        samples.iter().any(|sample| {
                            &sample.stable_id == stable_id
                                && sample.model == inventory.model
                                && sample.total_vram_mib == inventory.total_vram_mib
                        })
                    })
                })
            {
                self.gpu_telemetry = self
                    .inventory
                    .gpus
                    .iter()
                    .filter_map(|inventory| {
                        let stable_id = inventory.stable_id.as_ref()?;
                        samples
                            .iter()
                            .find(|sample| &sample.stable_id == stable_id)
                            .map(gpu_sample_telemetry)
                    })
                    .collect();
            } else {
                // Probe failure and device-set mismatch are both ambiguous.
                // Never carry a previously allocatable VRAM sample through
                // ambiguity; keep stable identities but publish zero capacity
                // until a complete matching probe succeeds.
                self.gpu_telemetry = fail_closed_gpu_telemetry(&self.inventory);
            }
        }

        let (power_source, battery) = probe_power_state();
        let mut temperature_c = probe_host_temperature();
        for gpu in &self.gpu_telemetry {
            if let Some(gpu_temperature) = gpu.temperature_c {
                temperature_c = Some(
                    temperature_c.map_or(gpu_temperature, |current| current.max(gpu_temperature)),
                );
            }
        }
        let mut active_run_ids = active_run_ids.to_vec();
        active_run_ids.sort_unstable();
        active_run_ids.dedup();
        let running_jobs = u32::try_from(active_run_ids.len()).unwrap_or(u32::MAX);
        let telemetry = NodeTelemetry {
            status: if self.conservative_capacity {
                NodeStatus::Degraded
            } else {
                NodeStatus::Online
            },
            available_cpu_cores: if self.conservative_capacity {
                0
            } else {
                available_cpu_cores
            },
            available_memory_mib: if self.conservative_capacity {
                0
            } else {
                (self.system.available_memory() / MIB).min(self.inventory.memory_mib)
            },
            available_disk_mib: if self.conservative_capacity {
                0
            } else {
                available_disk_mib.min(self.inventory.disk_mib)
            },
            gpus: self.gpu_telemetry.clone(),
            load: NodeLoad {
                cpu_percent,
                queue_depth: 0,
                running_jobs,
            },
            cached_sources: BTreeSet::new(),
            observed_at: Utc::now(),
            boot_generation: self.boot_generation,
            boot_id: self.boot_id,
            sequence,
            cpu_ewma_percent,
            active_run_ids,
            power_source,
            battery,
            temperature_c,
        };
        let request = NodeReportRequest {
            api_version: WORKER_API_VERSION.to_owned(),
            inventory: Some(self.inventory.clone()),
            telemetry,
        };
        request.validate().context("validate sampled node report")?;
        self.sequence = sequence;
        Ok(request)
    }
}

fn fail_closed_gpu_telemetry(inventory: &NodeInventory) -> Vec<GpuTelemetry> {
    inventory
        .gpus
        .iter()
        .map(|gpu| GpuTelemetry {
            available_vram_mib: 0,
            allocatable: false,
            stable_id: gpu.stable_id.clone(),
            utilization_percent: None,
            temperature_c: None,
        })
        .collect()
}

fn gpu_sample_telemetry(gpu: &NvidiaGpuSample) -> GpuTelemetry {
    GpuTelemetry {
        available_vram_mib: gpu.available_vram_mib,
        allocatable: true,
        stable_id: Some(gpu.stable_id.clone()),
        utilization_percent: gpu.utilization_percent,
        temperature_c: gpu.temperature_c,
    }
}

fn containment_inventory() -> ContainmentInventory {
    let backend = if cfg!(windows) {
        ContainmentBackend::WindowsJobObject
    } else if cfg!(target_os = "linux") {
        ContainmentBackend::LinuxSubreaperProcessGroup
    } else {
        ContainmentBackend::Unsupported
    };
    ContainmentInventory {
        backend,
        version: "v2".to_owned(),
        max_safe_slots: 1,
        hostile_isolation: isolation::hostile_isolation_inventory(),
    }
}

fn add_hostile_isolation_capabilities(capabilities: &mut BTreeSet<Capability>) {
    let inventory = isolation::hostile_isolation_inventory();
    add_hostile_isolation_capabilities_from_inventory(capabilities, &inventory);
}

fn add_hostile_isolation_capabilities_from_inventory(
    capabilities: &mut BTreeSet<Capability>,
    inventory: &cyc_protocol::HostileIsolationInventory,
) {
    if !inventory.opt_in || !inventory.ready {
        return;
    }
    // Scheduler-visible capability strings are emitted only as one ready set.
    // Configured/unverified state lives exclusively in structured inventory so
    // even a job requesting the opt-in marker cannot target an unready worker.
    capabilities.insert(Capability::new("isolation.hostile.opt_in"));
    let backend = match inventory.backend {
        cyc_protocol::HostileIsolationBackend::LinuxCgroupV2DedicatedIdentity => {
            "isolation.hostile.linux_cgroup_v2"
        }
        cyc_protocol::HostileIsolationBackend::WindowsJobObjectExternalGuard => {
            "isolation.hostile.windows_external_guard"
        }
        cyc_protocol::HostileIsolationBackend::MacosExternalReconciliation => {
            "isolation.hostile.macos_external_reconciliation"
        }
        cyc_protocol::HostileIsolationBackend::Disabled
        | cyc_protocol::HostileIsolationBackend::Unsupported => return,
    };
    capabilities.insert(Capability::new(backend));
    capabilities.insert(Capability::new("isolation.hostile.ready"));
    capabilities.insert(Capability::new("isolation.hostile.worker_state_separated"));
}

fn available_cpu_cores(logical_cpu_cores: u32, cpu_percent: u8) -> u32 {
    let busy = (u64::from(logical_cpu_cores) * u64::from(cpu_percent)).div_ceil(100);
    u32::try_from(u64::from(logical_cpu_cores).saturating_sub(busy)).unwrap_or(0)
}

fn update_cpu_ewma(previous: &mut Option<f64>, current: u8) -> u8 {
    let current = f64::from(current);
    let next = previous.map_or(current, |previous| {
        CPU_EWMA_ALPHA * current + (1.0 - CPU_EWMA_ALPHA) * previous
    });
    *previous = Some(next);
    next.round().clamp(0.0, 100.0) as u8
}

#[cfg(target_os = "linux")]
fn probe_power_state() -> (PowerSource, Option<BatteryTelemetry>) {
    let Ok(entries) = fs::read_dir("/sys/class/power_supply") else {
        return (PowerSource::Unknown, None);
    };
    let mut ac_online = false;
    let mut battery = None;
    for entry in entries.flatten() {
        let root = entry.path();
        let kind = read_trimmed(root.join("type"));
        match kind.as_deref() {
            Some("Battery") => {
                let charge_percent = read_trimmed(root.join("capacity"))
                    .and_then(|value| value.parse::<u8>().ok())
                    .filter(|value| *value <= 100);
                let charging =
                    read_trimmed(root.join("status")).and_then(|status| match status.as_str() {
                        "Charging" => Some(true),
                        "Discharging" | "Not charging" | "Full" => Some(false),
                        _ => None,
                    });
                battery = Some(BatteryTelemetry {
                    charge_percent,
                    charging,
                });
            }
            Some("Mains" | "USB" | "USB_C") => {
                ac_online |= read_trimmed(root.join("online")).as_deref() == Some("1");
            }
            _ => {}
        }
    }
    let source = if ac_online {
        PowerSource::Ac
    } else if battery.is_some() {
        PowerSource::Battery
    } else {
        PowerSource::Unknown
    };
    (source, battery)
}

#[cfg(windows)]
fn probe_power_state() -> (PowerSource, Option<BatteryTelemetry>) {
    #[repr(C)]
    struct SystemPowerStatus {
        ac_line_status: u8,
        battery_flag: u8,
        battery_life_percent: u8,
        _system_status_flag: u8,
        _battery_life_time: u32,
        _battery_full_life_time: u32,
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetSystemPowerStatus(status: *mut SystemPowerStatus) -> i32;
    }
    let mut status = SystemPowerStatus {
        ac_line_status: 255,
        battery_flag: 255,
        battery_life_percent: 255,
        _system_status_flag: 0,
        _battery_life_time: 0,
        _battery_full_life_time: 0,
    };
    if unsafe { GetSystemPowerStatus(&mut status) } == 0 {
        return (PowerSource::Unknown, None);
    }
    let power_source = match status.ac_line_status {
        0 => PowerSource::Battery,
        1 => PowerSource::Ac,
        _ => PowerSource::Unknown,
    };
    let no_battery = status.battery_flag == 128;
    let battery = (!no_battery).then_some(BatteryTelemetry {
        charge_percent: (status.battery_life_percent <= 100).then_some(status.battery_life_percent),
        charging: (status.battery_flag != 255).then_some(status.battery_flag & 8 != 0),
    });
    (power_source, battery)
}

#[cfg(not(any(target_os = "linux", windows)))]
fn probe_power_state() -> (PowerSource, Option<BatteryTelemetry>) {
    (PowerSource::Unknown, None)
}

#[cfg(target_os = "linux")]
fn probe_host_temperature() -> Option<i16> {
    fs::read_dir("/sys/class/thermal")
        .ok()?
        .flatten()
        .filter_map(|entry| read_trimmed(entry.path().join("temp")))
        .filter_map(|value| value.parse::<i64>().ok())
        .map(|value| {
            if value.abs() > 1_000 {
                value / 1_000
            } else {
                value
            }
        })
        .filter_map(|value| i16::try_from(value).ok())
        .filter(|value| (-100..=200).contains(value))
        .max()
}

#[cfg(not(target_os = "linux"))]
fn probe_host_temperature() -> Option<i16> {
    None
}

#[cfg(target_os = "linux")]
fn read_trimmed(path: impl AsRef<Path>) -> Option<String> {
    fs::read_to_string(path)
        .ok()
        .map(|value| value.trim().to_owned())
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
        assert_eq!(containment_inventory().max_safe_slots, 1);
    }

    #[test]
    fn unready_hostile_backend_has_no_schedulable_backend_capability() {
        let inventory = cyc_protocol::HostileIsolationInventory {
            opt_in: true,
            ready: false,
            backend: cyc_protocol::HostileIsolationBackend::LinuxCgroupV2DedicatedIdentity,
            dedicated_identity: false,
            external_reconciliation: false,
            protected_guard_state: false,
            worker_state_isolated: false,
            reason_code: Some("hostile_isolation_experimental_unverified".to_owned()),
        };
        let mut capabilities = BTreeSet::new();
        add_hostile_isolation_capabilities_from_inventory(&mut capabilities, &inventory);
        let names = capabilities
            .iter()
            .map(Capability::as_str)
            .collect::<BTreeSet<_>>();

        assert!(names.is_empty());
        assert!(!names.contains("isolation.hostile.opt_in"));
        assert!(!names.contains("isolation.hostile.linux_cgroup_v2"));
        assert!(!names.contains("isolation.hostile.ready"));
        assert!(!names.contains("isolation.hostile.worker_state_separated"));
    }

    #[test]
    fn nvidia_csv_parser_recovers_stable_dynamic_gpu_fields() {
        let parsed = parse_nvidia_smi_csv(
            "GPU-deadbeef, NVIDIA RTX 4070, 8188, 6144, 37, 64, 555.42\n\
             malformed\n\
             GPU-second, NVIDIA T4, 16384, 17000, N/A, N/A, 550.1\n",
        );
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].stable_id, "GPU-deadbeef");
        assert_eq!(parsed[0].available_vram_mib, 6_144);
        assert_eq!(parsed[0].utilization_percent, Some(37));
        assert_eq!(parsed[0].temperature_c, Some(64));
        assert_eq!(parsed[1].available_vram_mib, 16_384);
        assert_eq!(parsed[1].utilization_percent, None);
        assert_eq!(parsed[1].temperature_c, None);
    }

    #[test]
    fn cpu_ewma_and_available_cores_are_deterministic_at_full_load() {
        let mut ewma = None;
        assert_eq!(update_cpu_ewma(&mut ewma, 20), 20);
        assert_eq!(update_cpu_ewma(&mut ewma, 100), 48);
        assert_eq!(available_cpu_cores(16, 100), 0);
        assert_eq!(available_cpu_cores(16, 0), 16);
    }

    #[test]
    fn sampler_keeps_boot_id_increments_sequence_and_reports_active_run() {
        let directory = tempfile::tempdir().unwrap();
        let mut sampler = NodeSampler::new(directory.path())
            .unwrap_or_else(|_| NodeSampler::conservative(directory.path()));
        let boot_id = sampler.boot_id();
        let idle = sampler.sample(&[]).unwrap();
        let run_id = Uuid::new_v4();
        let active = sampler.sample(&[run_id]).unwrap();
        assert_eq!(idle.telemetry.boot_id, boot_id);
        assert_eq!(active.telemetry.boot_id, boot_id);
        assert_eq!(idle.telemetry.sequence, 1);
        assert_eq!(active.telemetry.sequence, 2);
        assert!(idle.telemetry.active_run_ids.is_empty());
        assert_eq!(active.telemetry.active_run_ids, vec![run_id]);
        assert_eq!(active.telemetry.load.running_jobs, 1);
        assert_eq!(
            active
                .inventory
                .as_ref()
                .unwrap()
                .containment
                .max_safe_slots,
            1
        );
    }

    #[test]
    fn managed_generation_is_stable_and_conservative_capacity_stays_zero() {
        let directory = tempfile::tempdir().unwrap();
        let mut sampler = NodeSampler::conservative_with_boot_generation(directory.path(), 42);
        let first = sampler.sample(&[]).unwrap();
        let second = sampler.sample(&[]).unwrap();
        assert_eq!(sampler.boot_generation(), 42);
        assert_eq!(first.telemetry.boot_generation, 42);
        assert_eq!(second.telemetry.boot_generation, 42);
        for report in [first, second] {
            assert_eq!(report.telemetry.status, NodeStatus::Degraded);
            assert_eq!(report.telemetry.available_cpu_cores, 0);
            assert_eq!(report.telemetry.available_memory_mib, 0);
            assert_eq!(report.telemetry.available_disk_mib, 0);
            assert!(report.telemetry.gpus.is_empty());
        }
    }

    #[test]
    fn ambiguous_gpu_probe_state_is_explicitly_non_allocatable() {
        let directory = tempfile::tempdir().unwrap();
        let mut sampler = NodeSampler::conservative(directory.path());
        sampler.inventory.gpus.push(GpuInventory {
            vendor: GpuVendor::Nvidia,
            model: "test gpu".to_owned(),
            total_vram_mib: 8_192,
            stable_id: Some("GPU-test".to_owned()),
            driver_version: Some("test".to_owned()),
        });
        let telemetry = fail_closed_gpu_telemetry(&sampler.inventory);
        assert_eq!(telemetry.len(), 1);
        assert_eq!(telemetry[0].stable_id.as_deref(), Some("GPU-test"));
        assert!(!telemetry[0].allocatable);
        assert_eq!(telemetry[0].available_vram_mib, 0);
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
