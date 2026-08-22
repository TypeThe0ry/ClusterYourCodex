use std::ffi::{OsStr, OsString};
use std::fmt;
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::PathBuf;
use std::process::{Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use async_trait::async_trait;
use sha2::{Digest, Sha256};
use tokio::sync::mpsc;

use crate::security::sanitized_environment;

static PROCESS_EXECUTION_LOCK: OnceLock<tokio::sync::Mutex<()>> = OnceLock::new();

#[cfg(target_os = "linux")]
static LINUX_SUBREAPER: OnceLock<std::result::Result<(), String>> = OnceLock::new();

#[cfg(test)]
pub async fn test_exclusive_child_process_guard() -> tokio::sync::MutexGuard<'static, ()> {
    PROCESS_EXECUTION_LOCK
        .get_or_init(|| tokio::sync::Mutex::new(()))
        .lock()
        .await
}

pub const CANCEL_NONE: u8 = 0;
pub const CANCEL_REQUESTED: u8 = 1;
pub const CANCEL_LEASE_LOST: u8 = 2;
pub const CANCEL_TRANSPORT_FAILURE: u8 = 3;
pub const CANCEL_JOB_TIMEOUT: u8 = 4;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LogStream {
    Stdout,
    Stderr,
}

impl LogStream {
    pub fn as_header(self) -> &'static str {
        match self {
            Self::Stdout => "stdout",
            Self::Stderr => "stderr",
        }
    }
}

#[derive(Clone, Debug)]
pub struct LogChunk {
    pub stream: LogStream,
    pub bytes: Vec<u8>,
}

#[async_trait]
pub trait LogSink: Send + Sync {
    async fn upload(&self, chunk: LogChunk) -> Result<()>;
}

pub struct DiscardLogSink;

#[async_trait]
impl LogSink for DiscardLogSink {
    async fn upload(&self, _chunk: LogChunk) -> Result<()> {
        Ok(())
    }
}

pub struct ProcessRequest {
    pub program: OsString,
    pub arguments: Vec<OsString>,
    pub cwd: PathBuf,
    pub timeout: Duration,
    pub stdout_path: PathBuf,
    pub stderr_path: PathBuf,
    pub log_budget: Arc<LogBudget>,
    pub environment: Vec<(OsString, OsString)>,
    #[cfg(test)]
    pub fault: Option<TestProcessFault>,
}

#[cfg(test)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TestProcessFault {
    MonitorFailureAfterAttach,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProcessContainment {
    /// No process was started, or the complete managed tree was synchronously
    /// observed empty after termination.
    ConfirmedEmpty,
    /// A process existed and an OS/monitor/cleanup failure prevented a proof
    /// that every descendant was gone. This must never become terminal wire
    /// evidence.
    Unconfirmed,
}

#[derive(Debug)]
pub struct ProcessRunError {
    error: anyhow::Error,
    containment: ProcessContainment,
}

impl ProcessRunError {
    fn confirmed_empty(error: anyhow::Error) -> Self {
        Self {
            error,
            containment: ProcessContainment::ConfirmedEmpty,
        }
    }

    fn unconfirmed(error: anyhow::Error) -> Self {
        Self {
            error,
            containment: ProcessContainment::Unconfirmed,
        }
    }

    pub fn containment(&self) -> ProcessContainment {
        self.containment
    }

    pub fn into_inner(self) -> anyhow::Error {
        self.error
    }
}

impl fmt::Display for ProcessRunError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}", self.error)
    }
}

impl std::error::Error for ProcessRunError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(self.error.as_ref())
    }
}

/// Enforce the platform gate before the daemon claims work. Linux uses a
/// subreaper plus PID/start-time descendant tracking; Windows uses a Job
/// Object. Other Unix targets remain probe/pair capable but fail closed for
/// managed execution until an equally strong containment backend exists.
pub fn ensure_process_containment_available() -> Result<()> {
    #[cfg(windows)]
    {
        Ok(())
    }
    #[cfg(target_os = "linux")]
    {
        let status = LINUX_SUBREAPER.get_or_init(|| {
            if !std::path::Path::new("/proc/self/task").is_dir() {
                return Err("Linux /proc task topology is unavailable".to_owned());
            }
            let configured = unsafe { libc::prctl(libc::PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) };
            if configured == -1 {
                return Err(format!(
                    "PR_SET_CHILD_SUBREAPER failed: {}",
                    io::Error::last_os_error()
                ));
            }
            let mut enabled = 0i32;
            let queried = unsafe {
                libc::prctl(
                    libc::PR_GET_CHILD_SUBREAPER,
                    &mut enabled as *mut i32,
                    0,
                    0,
                    0,
                )
            };
            if queried == -1 || enabled != 1 {
                return Err(format!(
                    "PR_GET_CHILD_SUBREAPER did not confirm containment: {}",
                    io::Error::last_os_error()
                ));
            }
            Ok(())
        });
        status
            .as_ref()
            .map(|_| ())
            .map_err(|message| anyhow::anyhow!(message.clone()))
    }
    #[cfg(all(unix, not(target_os = "linux")))]
    {
        bail!(
            "managed execution is unsupported on this Unix platform: no reliable descendant containment backend"
        );
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProcessTerminationReason {
    Exited,
    ExecutionFailed,
    TimedOut,
    CancelRequested,
    LeaseLost,
    TransportFailure,
}

#[derive(Debug)]
pub struct LogBudget {
    remaining: AtomicU64,
    stdout_truncated: AtomicBool,
    stderr_truncated: AtomicBool,
}

impl LogBudget {
    pub fn new(max_bytes: u64) -> Self {
        Self {
            remaining: AtomicU64::new(max_bytes),
            stdout_truncated: AtomicBool::new(false),
            stderr_truncated: AtomicBool::new(false),
        }
    }

    fn retain(&self, stream: LogStream, requested: usize) -> usize {
        let requested = requested as u64;
        let mut remaining = self.remaining.load(Ordering::SeqCst);
        loop {
            let retained = remaining.min(requested);
            match self.remaining.compare_exchange_weak(
                remaining,
                remaining - retained,
                Ordering::SeqCst,
                Ordering::SeqCst,
            ) {
                Ok(_) => {
                    if retained != requested {
                        self.mark_truncated(stream);
                    }
                    return retained as usize;
                }
                Err(actual) => remaining = actual,
            }
        }
    }

    pub fn truncated(&self, stream: LogStream) -> bool {
        match stream {
            LogStream::Stdout => self.stdout_truncated.load(Ordering::SeqCst),
            LogStream::Stderr => self.stderr_truncated.load(Ordering::SeqCst),
        }
    }

    fn mark_truncated(&self, stream: LogStream) {
        match stream {
            LogStream::Stdout => self.stdout_truncated.store(true, Ordering::SeqCst),
            LogStream::Stderr => self.stderr_truncated.store(true, Ordering::SeqCst),
        }
    }

    #[cfg(test)]
    fn remaining(&self) -> u64 {
        self.remaining.load(Ordering::SeqCst)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProcessStreamEvidence {
    pub byte_count: u64,
    pub sha256: String,
    pub truncated: bool,
    pub chunk_count: u64,
}

#[derive(Debug)]
pub struct ProcessResult {
    pub exit_code: Option<i32>,
    pub signal: Option<i32>,
    pub reason: ProcessTerminationReason,
    pub stdout: ProcessStreamEvidence,
    pub stderr: ProcessStreamEvidence,
    pub process_tree_terminated: bool,
    pub forced_kill: bool,
    pub error: Option<String>,
}

impl ProcessResult {
    pub fn succeeded(&self) -> bool {
        self.reason == ProcessTerminationReason::Exited
            && self.exit_code == Some(0)
            && self.process_tree_terminated
            && !self.forced_kill
    }

    fn not_started(error: anyhow::Error) -> Self {
        let empty = hex::encode(Sha256::digest([]));
        let stream = ProcessStreamEvidence {
            byte_count: 0,
            sha256: empty,
            truncated: false,
            chunk_count: 0,
        };
        Self {
            exit_code: None,
            signal: None,
            reason: ProcessTerminationReason::ExecutionFailed,
            stdout: stream.clone(),
            stderr: stream,
            process_tree_terminated: true,
            forced_kill: false,
            error: Some(format!("process did not start: {error:#}")),
        }
    }
}

pub async fn run_process(
    request: ProcessRequest,
    cancellation: Arc<AtomicU8>,
    sink: Arc<dyn LogSink>,
) -> std::result::Result<ProcessResult, ProcessRunError> {
    let execution_lock = PROCESS_EXECUTION_LOCK.get_or_init(|| tokio::sync::Mutex::new(()));
    let execution_guard = execution_lock.lock().await;
    run_process_locked(request, cancellation, sink, execution_guard).await
}

async fn run_process_locked(
    request: ProcessRequest,
    cancellation: Arc<AtomicU8>,
    sink: Arc<dyn LogSink>,
    _execution_guard: tokio::sync::MutexGuard<'_, ()>,
) -> std::result::Result<ProcessResult, ProcessRunError> {
    if request.timeout.is_zero() {
        return Err(ProcessRunError::confirmed_empty(anyhow::anyhow!(
            "process timeout must be greater than zero"
        )));
    }
    fs::create_dir_all(
        request
            .stdout_path
            .parent()
            .context("stdout log must have a parent")
            .map_err(ProcessRunError::confirmed_empty)?,
    )
    .context("create stdout log directory")
    .map_err(ProcessRunError::confirmed_empty)?;
    fs::create_dir_all(
        request
            .stderr_path
            .parent()
            .context("stderr log must have a parent")
            .map_err(ProcessRunError::confirmed_empty)?,
    )
    .context("create stderr log directory")
    .map_err(ProcessRunError::confirmed_empty)?;

    ensure_process_containment_available()
        .context("secure process-tree containment is unavailable")
        .map_err(ProcessRunError::confirmed_empty)?;
    let containment_seed = capture_containment_seed()
        .context("capture process-tree containment baseline")
        .map_err(ProcessRunError::confirmed_empty)?;

    let mut command = Command::new(&request.program);
    command
        .args(&request.arguments)
        .current_dir(&request.cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .env_clear()
        .envs(sanitized_environment())
        .envs(request.environment.iter().cloned());
    configure_process_group(&mut command).map_err(ProcessRunError::confirmed_empty)?;

    let mut child = match command.spawn().with_context(|| {
        format!(
            "spawn process `{}` in {}",
            request.program.to_string_lossy(),
            request.cwd.display()
        )
    }) {
        Ok(child) => child,
        Err(error) => {
            fs::write(&request.stdout_path, b"")
                .context("create empty stdout log")
                .map_err(ProcessRunError::confirmed_empty)?;
            fs::write(&request.stderr_path, b"")
                .context("create empty stderr log")
                .map_err(ProcessRunError::confirmed_empty)?;
            return Ok(ProcessResult::not_started(error));
        }
    };
    let process_tree = match ProcessTree::attach(&mut child, containment_seed) {
        Ok(tree) => tree,
        Err(error) => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(ProcessRunError::unconfirmed(
                error.context("secure process-tree containment failed"),
            ));
        }
    };
    let stdout = child
        .stdout
        .take()
        .context("capture child stdout")
        .map_err(ProcessRunError::unconfirmed)?;
    let stderr = child
        .stderr
        .take()
        .context("capture child stderr")
        .map_err(ProcessRunError::unconfirmed)?;

    let (sender, mut receiver) = mpsc::channel::<LogChunk>(16);
    let stdout_reader = spawn_reader(
        stdout,
        request.stdout_path,
        LogStream::Stdout,
        request.log_budget.clone(),
        sender.clone(),
    );
    let stderr_reader = spawn_reader(
        stderr,
        request.stderr_path,
        LogStream::Stderr,
        request.log_budget,
        sender.clone(),
    );
    drop(sender);

    let timeout = request.timeout;
    let cancellation_for_wait = cancellation.clone();
    #[cfg(test)]
    let fault = request.fault;
    let wait_task = tokio::task::spawn_blocking(move || {
        monitor_child(
            child,
            process_tree,
            timeout,
            cancellation_for_wait,
            #[cfg(test)]
            fault,
        )
    });
    tokio::pin!(wait_task);
    let mut wait_result = None;
    let mut upload_error = None;
    loop {
        if wait_result.is_some() && receiver.is_closed() && receiver.is_empty() {
            break;
        }
        tokio::select! {
            biased;
            result = &mut wait_task, if wait_result.is_none() => {
                let result = result
                    .context("process monitor task panicked")
                    .map_err(ProcessRunError::unconfirmed)?
                    .map_err(ProcessRunError::unconfirmed)?;
                wait_result = Some(result);
            }
            chunk = receiver.recv() => {
                match chunk {
                    Some(chunk) => {
                        if upload_error.is_none() {
                            if let Err(error) = sink.upload(chunk).await {
                                cancellation.store(CANCEL_TRANSPORT_FAILURE, Ordering::SeqCst);
                                upload_error = Some(error);
                            }
                        }
                    }
                    None => {
                        if wait_result.is_some() {
                            break;
                        }
                    }
                }
            }
        }
    }

    let stdout_stats = stdout_reader
        .await
        .context("stdout reader task panicked")
        .map_err(ProcessRunError::unconfirmed)?
        .map_err(ProcessRunError::unconfirmed)?;
    let stderr_stats = stderr_reader
        .await
        .context("stderr reader task panicked")
        .map_err(ProcessRunError::unconfirmed)?
        .map_err(ProcessRunError::unconfirmed)?;
    let monitored = wait_result
        .context("process monitor returned no result")
        .map_err(ProcessRunError::unconfirmed)?;
    let reason = if upload_error.is_some() {
        ProcessTerminationReason::TransportFailure
    } else {
        monitored.reason
    };
    Ok(ProcessResult {
        exit_code: monitored.status.code(),
        signal: exit_signal(&monitored.status),
        reason,
        stdout: stdout_stats.into(),
        stderr: stderr_stats.into(),
        process_tree_terminated: monitored.process_tree_terminated,
        forced_kill: monitored.forced_kill,
        error: upload_error.map(|error| format!("upload process log chunk: {error:#}")),
    })
}

#[derive(Debug)]
struct ReaderStats {
    bytes: u64,
    sha256: String,
    truncated: bool,
    chunks: u64,
}

impl From<ReaderStats> for ProcessStreamEvidence {
    fn from(value: ReaderStats) -> Self {
        Self {
            byte_count: value.bytes,
            sha256: value.sha256,
            truncated: value.truncated,
            chunk_count: value.chunks,
        }
    }
}

fn spawn_reader<R>(
    mut reader: R,
    path: PathBuf,
    stream: LogStream,
    budget: Arc<LogBudget>,
    sender: mpsc::Sender<LogChunk>,
) -> tokio::task::JoinHandle<Result<ReaderStats>>
where
    R: Read + Send + 'static,
{
    tokio::task::spawn_blocking(move || {
        let mut file = File::create(&path)
            .with_context(|| format!("create bounded log {}", path.display()))?;
        let mut buffer = vec![0u8; 64 * 1024];
        let mut stored = 0u64;
        let mut truncated = false;
        let mut chunks = 0u64;
        let mut hasher = Sha256::new();
        loop {
            let count = reader.read(&mut buffer).context("drain child output")?;
            if count == 0 {
                break;
            }
            let retained = budget.retain(stream, count);
            if retained > 0 {
                let bytes = buffer[..retained].to_vec();
                file.write_all(&bytes).context("write bounded child log")?;
                hasher.update(&bytes);
                sender
                    .blocking_send(LogChunk { stream, bytes })
                    .map_err(|_| anyhow::anyhow!("log upload channel closed"))?;
                stored += retained as u64;
                chunks += 1;
            }
            if retained != count {
                truncated = true;
            }
        }
        file.sync_all().context("flush bounded child log")?;
        Ok(ReaderStats {
            bytes: stored,
            sha256: hex::encode(hasher.finalize()),
            truncated,
            chunks,
        })
    })
}

fn monitor_child(
    mut child: std::process::Child,
    mut process_tree: ProcessTree,
    timeout: Duration,
    cancellation: Arc<AtomicU8>,
    #[cfg(test)] fault: Option<TestProcessFault>,
) -> Result<MonitorResult> {
    #[cfg(test)]
    if fault == Some(TestProcessFault::MonitorFailureAfterAttach) {
        bail!("injected process monitor failure after containment attach");
    }
    let deadline = Instant::now() + timeout;
    loop {
        process_tree.observe()?;
        if let Some(status) = child.try_wait().context("poll child process")? {
            let forced_kill = cleanup_after_root_exit(&mut process_tree)?;
            process_tree.disarm();
            drop(process_tree);
            return Ok(MonitorResult {
                status,
                reason: ProcessTerminationReason::Exited,
                process_tree_terminated: true,
                forced_kill,
            });
        }
        let signal = cancellation.load(Ordering::SeqCst);
        let reason = match signal {
            CANCEL_REQUESTED => Some(ProcessTerminationReason::CancelRequested),
            CANCEL_LEASE_LOST => Some(ProcessTerminationReason::LeaseLost),
            CANCEL_TRANSPORT_FAILURE => Some(ProcessTerminationReason::TransportFailure),
            CANCEL_JOB_TIMEOUT => Some(ProcessTerminationReason::TimedOut),
            _ if Instant::now() >= deadline => Some(ProcessTerminationReason::TimedOut),
            _ => None,
        };
        if let Some(reason) = reason {
            process_tree.terminate()?;
            let (status, forced_kill) = wait_after_termination(&mut child, &mut process_tree)?;
            process_tree.disarm();
            drop(process_tree);
            return Ok(MonitorResult {
                status,
                reason,
                process_tree_terminated: true,
                forced_kill,
            });
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

struct MonitorResult {
    status: ExitStatus,
    reason: ProcessTerminationReason,
    process_tree_terminated: bool,
    forced_kill: bool,
}

/// A successful root exit is not permission for daemonized descendants to
/// escape the job. Confirm the group/job is empty and terminate leftovers.
fn cleanup_after_root_exit(tree: &mut ProcessTree) -> Result<bool> {
    if tree.is_empty()? {
        return Ok(false);
    }
    tree.terminate()?;
    if wait_for_tree_empty(tree, Duration::from_secs(3))? {
        return Ok(false);
    }
    tree.force_kill()?;
    if !wait_for_tree_empty(tree, Duration::from_secs(3))? {
        bail!("process tree remained alive after forced termination");
    }
    Ok(true)
}

fn wait_after_termination(
    child: &mut std::process::Child,
    tree: &mut ProcessTree,
) -> Result<(ExitStatus, bool)> {
    let grace_deadline = Instant::now() + Duration::from_secs(3);
    let mut status = None;
    loop {
        if status.is_none() {
            status = child.try_wait().context("wait after tree termination")?;
        }
        if status.is_some() && tree.is_empty()? {
            return Ok((
                status.context("terminated root process has no status")?,
                false,
            ));
        }
        if Instant::now() >= grace_deadline {
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    tree.force_kill()?;
    let forced_deadline = Instant::now() + Duration::from_secs(3);
    loop {
        if status.is_none() {
            status = child
                .try_wait()
                .context("wait after forced tree termination")?;
        }
        if status.is_some() && tree.is_empty()? {
            return Ok((
                status.context("force-killed root process has no status")?,
                true,
            ));
        }
        if Instant::now() >= forced_deadline {
            bail!("process tree remained alive after forced termination");
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn wait_for_tree_empty(tree: &mut ProcessTree, timeout: Duration) -> Result<bool> {
    let deadline = Instant::now() + timeout;
    loop {
        if tree.is_empty()? {
            return Ok(true);
        }
        if Instant::now() >= deadline {
            return Ok(false);
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[cfg(unix)]
fn exit_signal(status: &ExitStatus) -> Option<i32> {
    use std::os::unix::process::ExitStatusExt;
    status.signal()
}

#[cfg(windows)]
fn exit_signal(_status: &ExitStatus) -> Option<i32> {
    None
}

fn configure_process_group(command: &mut Command) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        unsafe {
            command.pre_exec(|| {
                if libc::setpgid(0, 0) == -1 {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        use windows_sys::Win32::System::Threading::{CREATE_NEW_PROCESS_GROUP, CREATE_SUSPENDED};
        // Suspension closes the spawn-before-AssignProcessToJobObject escape
        // window. ProcessTree::attach resumes only after containment succeeds.
        command.creation_flags(CREATE_NEW_PROCESS_GROUP | CREATE_SUSPENDED);
    }
    Ok(())
}

struct ContainmentSeed {
    #[cfg(target_os = "linux")]
    worker_pid: i32,
    #[cfg(target_os = "linux")]
    baseline_children: std::collections::HashSet<ProcessIdentity>,
    #[cfg(target_os = "linux")]
    not_before_start_time: u64,
}

fn capture_containment_seed() -> Result<ContainmentSeed> {
    #[cfg(target_os = "linux")]
    {
        let worker_pid = i32::try_from(std::process::id()).context("worker PID exceeds i32")?;
        let baseline_children = direct_child_processes(worker_pid)?
            .into_iter()
            .map(|process| process.identity)
            .collect();
        let not_before_start_time = linux_uptime_ticks()?.saturating_sub(2);
        Ok(ContainmentSeed {
            worker_pid,
            baseline_children,
            not_before_start_time,
        })
    }
    #[cfg(not(target_os = "linux"))]
    {
        Ok(ContainmentSeed {})
    }
}

#[cfg(target_os = "linux")]
fn linux_uptime_ticks() -> Result<u64> {
    let uptime = fs::read_to_string("/proc/uptime").context("read Linux uptime")?;
    let seconds = uptime
        .split_whitespace()
        .next()
        .context("Linux uptime is empty")?
        .parse::<f64>()
        .context("parse Linux uptime")?;
    let ticks_per_second = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
    if ticks_per_second <= 0 || !seconds.is_finite() || seconds.is_sign_negative() {
        bail!("Linux uptime/clock tick values are invalid");
    }
    Ok((seconds * ticks_per_second as f64).floor() as u64)
}

#[cfg(target_os = "linux")]
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
struct ProcessIdentity {
    pid: i32,
    start_time: u64,
}

#[cfg(target_os = "linux")]
#[derive(Clone, Copy, Debug)]
struct ProcStat {
    identity: ProcessIdentity,
    parent_pid: i32,
    state: char,
}

#[cfg(target_os = "linux")]
fn read_proc_stat(pid: i32) -> Result<Option<ProcStat>> {
    let path = PathBuf::from(format!("/proc/{pid}/stat"));
    let value = match fs::read_to_string(&path) {
        Ok(value) => value,
        Err(error) if process_disappeared(&error) => return Ok(None),
        Err(error) => {
            return Err(error).with_context(|| format!("read process identity {}", path.display()))
        }
    };
    let close = value
        .rfind(')')
        .context("Linux process stat omitted command terminator")?;
    let fields = value[close + 1..].split_whitespace().collect::<Vec<_>>();
    if fields.len() < 20 {
        bail!("Linux process stat has too few fields for PID {pid}");
    }
    let state = fields[0]
        .chars()
        .next()
        .context("Linux process stat omitted state")?;
    let parent_pid = fields[1].parse::<i32>().context("parse Linux parent PID")?;
    let start_time = fields[19]
        .parse::<u64>()
        .context("parse Linux process start time")?;
    Ok(Some(ProcStat {
        identity: ProcessIdentity { pid, start_time },
        parent_pid,
        state,
    }))
}

#[cfg(target_os = "linux")]
fn process_disappeared(error: &io::Error) -> bool {
    // procfs can report ESRCH rather than ENOENT when a task exits between
    // path lookup and reading its stat record. Both mean that exact PID is no
    // longer observable; treating ESRCH as ambiguity makes normal cleanup
    // spuriously fail closed under the expected exit race.
    error.kind() == io::ErrorKind::NotFound || error.raw_os_error() == Some(libc::ESRCH)
}

#[cfg(target_os = "linux")]
fn direct_child_processes(parent_pid: i32) -> Result<Vec<ProcStat>> {
    let task_root = PathBuf::from(format!("/proc/{parent_pid}/task"));
    let entries = match fs::read_dir(&task_root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => {
            return Err(error)
                .with_context(|| format!("enumerate process tasks {}", task_root.display()))
        }
    };
    let mut child_pids = std::collections::HashSet::new();
    for entry in entries {
        let entry = entry.context("enumerate Linux process task")?;
        let Some(task_id) = entry
            .file_name()
            .to_str()
            .and_then(|name| name.parse::<i32>().ok())
        else {
            continue;
        };
        let path = PathBuf::from(format!("/proc/{parent_pid}/task/{task_id}/children"));
        let children = match fs::read_to_string(&path) {
            Ok(children) => children,
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("read process children {}", path.display()))
            }
        };
        for child in children.split_whitespace() {
            child_pids.insert(child.parse::<i32>().context("parse Linux child PID")?);
        }
    }
    let mut children = Vec::with_capacity(child_pids.len());
    for child_pid in child_pids {
        if let Some(process) = read_proc_stat(child_pid)? {
            // `/proc/.../children` is authoritative, while the parent field
            // guards against a PID-reuse race between the two reads.
            if process.parent_pid == parent_pid {
                children.push(process);
            }
        }
    }
    Ok(children)
}

#[cfg(target_os = "linux")]
struct LinuxDescendants {
    worker_pid: i32,
    root: ProcessIdentity,
    baseline_children: std::collections::HashSet<ProcessIdentity>,
    tracked: std::collections::HashSet<ProcessIdentity>,
}

#[cfg(target_os = "linux")]
impl LinuxDescendants {
    fn new(root_pid: i32, seed: ContainmentSeed) -> Result<Self> {
        // An extremely short-lived root may already be reaped/reparented by
        // the time Command::spawn returns. In that case retain its PID plus a
        // pre-spawn boot-time threshold and claim only new, non-baseline direct
        // children adopted by this subreaper.
        let root = read_proc_stat(root_pid)?
            .map(|process| process.identity)
            .unwrap_or(ProcessIdentity {
                pid: root_pid,
                start_time: seed.not_before_start_time,
            });
        let mut tracked = std::collections::HashSet::new();
        tracked.insert(root);
        let mut descendants = Self {
            worker_pid: seed.worker_pid,
            root,
            baseline_children: seed.baseline_children,
            tracked,
        };
        descendants.refresh()?;
        Ok(descendants)
    }

    fn refresh(&mut self) -> Result<()> {
        let mut still_live = std::collections::HashSet::new();
        for identity in self.tracked.iter().copied() {
            if read_proc_stat(identity.pid)?.is_some_and(|process| {
                process.identity == identity && !matches!(process.state, 'Z' | 'X')
            }) {
                still_live.insert(identity);
            }
        }
        self.tracked = still_live;

        let direct_worker = direct_child_processes(self.worker_pid)?;
        for process in direct_worker {
            if process.identity.pid != self.root.pid
                && process.state == 'Z'
                && !self.baseline_children.contains(&process.identity)
            {
                // Reap adopted descendants without stealing the root Child's
                // status or any child that predated this managed invocation.
                unsafe {
                    libc::waitpid(process.identity.pid, std::ptr::null_mut(), libc::WNOHANG);
                }
                continue;
            }
            if process.identity == self.root
                || (!self.baseline_children.contains(&process.identity)
                    && process.identity.start_time >= self.root.start_time
                    && !matches!(process.state, 'Z' | 'X'))
            {
                self.tracked.insert(process.identity);
            }
        }

        let mut pending = self.tracked.iter().copied().collect::<Vec<_>>();
        let mut index = 0usize;
        while index < pending.len() {
            let parent = pending[index];
            index += 1;
            for child in direct_child_processes(parent.pid)? {
                if matches!(child.state, 'Z' | 'X') {
                    continue;
                }
                if self.tracked.insert(child.identity) {
                    pending.push(child.identity);
                }
            }
        }
        Ok(())
    }

    fn is_empty(&mut self) -> Result<bool> {
        self.refresh()?;
        Ok(self.tracked.is_empty())
    }

    fn signal_all(&mut self, signal: i32) -> Result<()> {
        // Refresh both before and after signaling. A process that daemonizes
        // during the first pass is adopted by the subreaper and appears in the
        // next pass rather than escaping through a new session/process group.
        for _ in 0..2 {
            self.refresh()?;
            for identity in self.tracked.iter().copied() {
                let Some(current) = read_proc_stat(identity.pid)? else {
                    continue;
                };
                if current.identity != identity || matches!(current.state, 'Z' | 'X') {
                    continue;
                }
                let result = unsafe { libc::kill(identity.pid, signal) };
                if result == -1 {
                    let error = io::Error::last_os_error();
                    if error.raw_os_error() != Some(libc::ESRCH) {
                        return Err(error)
                            .with_context(|| format!("signal contained PID {}", identity.pid));
                    }
                }
            }
        }
        Ok(())
    }

    fn best_effort_kill(&mut self) {
        for _ in 0..3 {
            if self.signal_all(libc::SIGKILL).is_err() {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }
}

struct ProcessTree {
    #[cfg(unix)]
    process_group: i32,
    #[cfg(target_os = "linux")]
    descendants: LinuxDescendants,
    #[cfg(windows)]
    job: windows_sys::Win32::Foundation::HANDLE,
    #[cfg(unix)]
    armed: bool,
}

unsafe impl Send for ProcessTree {}

impl ProcessTree {
    fn attach(child: &mut std::process::Child, seed: ContainmentSeed) -> Result<Self> {
        #[cfg(unix)]
        {
            let process_group = i32::try_from(child.id()).context("child PID exceeds i32")?;
            #[cfg(target_os = "linux")]
            let descendants = LinuxDescendants::new(process_group, seed)?;
            #[cfg(not(target_os = "linux"))]
            let _ = seed;
            Ok(Self {
                process_group,
                #[cfg(target_os = "linux")]
                descendants,
                armed: true,
            })
        }
        #[cfg(windows)]
        {
            let _ = seed;
            use std::os::windows::io::AsRawHandle;
            use std::ptr;
            use windows_sys::Win32::System::JobObjects::{
                AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
                SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
                JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
            };

            let job = unsafe { CreateJobObjectW(ptr::null(), ptr::null()) };
            if job.is_null() {
                return Err(io::Error::last_os_error()).context("CreateJobObjectW");
            }
            let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { std::mem::zeroed() };
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            let configured = unsafe {
                SetInformationJobObject(
                    job,
                    JobObjectExtendedLimitInformation,
                    (&limits as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
                    std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
                )
            };
            if configured == 0 {
                unsafe { windows_sys::Win32::Foundation::CloseHandle(job) };
                return Err(io::Error::last_os_error()).context("SetInformationJobObject");
            }
            let assigned = unsafe { AssignProcessToJobObject(job, child.as_raw_handle().cast()) };
            if assigned == 0 {
                unsafe { windows_sys::Win32::Foundation::CloseHandle(job) };
                return Err(io::Error::last_os_error()).context("AssignProcessToJobObject");
            }
            if let Err(error) = resume_suspended_process(child.id()) {
                unsafe {
                    windows_sys::Win32::System::JobObjects::TerminateJobObject(job, 125);
                    windows_sys::Win32::Foundation::CloseHandle(job);
                }
                return Err(error.context("resume contained child process"));
            }
            Ok(Self { job })
        }
    }

    fn terminate(&mut self) -> Result<()> {
        #[cfg(unix)]
        {
            #[cfg(target_os = "linux")]
            self.descendants.signal_all(libc::SIGTERM)?;
            let result = unsafe { libc::kill(-self.process_group, libc::SIGTERM) };
            if result == -1 {
                let error = io::Error::last_os_error();
                if error.raw_os_error() != Some(libc::ESRCH) {
                    return Err(error).context("send SIGTERM to process group");
                }
            }
        }
        #[cfg(windows)]
        {
            let result = unsafe {
                windows_sys::Win32::System::JobObjects::TerminateJobObject(self.job, 125)
            };
            if result == 0 {
                return Err(io::Error::last_os_error()).context("TerminateJobObject");
            }
        }
        Ok(())
    }

    fn observe(&mut self) -> Result<()> {
        #[cfg(target_os = "linux")]
        self.descendants.refresh()?;
        Ok(())
    }

    fn is_empty(&mut self) -> Result<bool> {
        #[cfg(unix)]
        {
            #[cfg(target_os = "linux")]
            {
                self.descendants.is_empty()
            }
            #[cfg(not(target_os = "linux"))]
            {
                let result = unsafe { libc::kill(-self.process_group, 0) };
                if result == 0 {
                    return Ok(false);
                }
                let error = io::Error::last_os_error();
                if error.raw_os_error() == Some(libc::ESRCH) {
                    return Ok(true);
                }
                if error.raw_os_error() == Some(libc::EPERM) {
                    return Ok(false);
                }
                Err(error).context("probe process group")
            }
        }
        #[cfg(windows)]
        {
            use windows_sys::Win32::System::JobObjects::{
                JobObjectBasicAccountingInformation, QueryInformationJobObject,
                JOBOBJECT_BASIC_ACCOUNTING_INFORMATION,
            };
            let mut accounting: JOBOBJECT_BASIC_ACCOUNTING_INFORMATION =
                unsafe { std::mem::zeroed() };
            let queried = unsafe {
                QueryInformationJobObject(
                    self.job,
                    JobObjectBasicAccountingInformation,
                    (&mut accounting as *mut JOBOBJECT_BASIC_ACCOUNTING_INFORMATION).cast(),
                    std::mem::size_of::<JOBOBJECT_BASIC_ACCOUNTING_INFORMATION>() as u32,
                    std::ptr::null_mut(),
                )
            };
            if queried == 0 {
                return Err(io::Error::last_os_error()).context("QueryInformationJobObject");
            }
            Ok(accounting.ActiveProcesses == 0)
        }
    }

    fn force_kill(&mut self) -> Result<()> {
        #[cfg(unix)]
        {
            #[cfg(target_os = "linux")]
            self.descendants.signal_all(libc::SIGKILL)?;
            let result = unsafe { libc::kill(-self.process_group, libc::SIGKILL) };
            if result == -1 {
                let error = io::Error::last_os_error();
                if error.raw_os_error() != Some(libc::ESRCH) {
                    return Err(error).context("send SIGKILL to process group");
                }
            }
        }
        #[cfg(windows)]
        {
            let result = unsafe {
                windows_sys::Win32::System::JobObjects::TerminateJobObject(self.job, 125)
            };
            if result == 0 {
                return Err(io::Error::last_os_error()).context("force TerminateJobObject");
            }
        }
        Ok(())
    }

    fn disarm(&mut self) {
        #[cfg(unix)]
        {
            self.armed = false;
        }
    }
}

impl Drop for ProcessTree {
    fn drop(&mut self) {
        #[cfg(unix)]
        if self.armed {
            // Last-resort containment if monitoring encounters an unexpected
            // OS error. We intentionally do not claim terminal evidence on
            // that error path because this fallback cannot synchronously
            // prove the group became empty.
            unsafe {
                libc::kill(-self.process_group, libc::SIGKILL);
            }
            #[cfg(target_os = "linux")]
            self.descendants.best_effort_kill();
        }
        #[cfg(windows)]
        unsafe {
            windows_sys::Win32::Foundation::CloseHandle(self.job);
        }
    }
}

#[cfg(windows)]
fn resume_suspended_process(process_id: u32) -> Result<()> {
    use windows_sys::Win32::Foundation::{CloseHandle, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, Thread32First, Thread32Next, TH32CS_SNAPTHREAD, THREADENTRY32,
    };
    use windows_sys::Win32::System::Threading::{OpenThread, ResumeThread, THREAD_SUSPEND_RESUME};

    let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0) };
    if snapshot == INVALID_HANDLE_VALUE {
        return Err(io::Error::last_os_error()).context("CreateToolhelp32Snapshot threads");
    }
    let mut entry: THREADENTRY32 = unsafe { std::mem::zeroed() };
    entry.dwSize = std::mem::size_of::<THREADENTRY32>() as u32;
    let mut found = false;
    let mut has_entry = unsafe { Thread32First(snapshot, &mut entry) } != 0;
    while has_entry {
        if entry.th32OwnerProcessID == process_id {
            let thread = unsafe { OpenThread(THREAD_SUSPEND_RESUME, 0, entry.th32ThreadID) };
            if thread.is_null() {
                unsafe { CloseHandle(snapshot) };
                return Err(io::Error::last_os_error()).context("OpenThread suspended child");
            }
            let previous = unsafe { ResumeThread(thread) };
            unsafe { CloseHandle(thread) };
            if previous == u32::MAX {
                unsafe { CloseHandle(snapshot) };
                return Err(io::Error::last_os_error()).context("ResumeThread contained child");
            }
            found = true;
        }
        has_entry = unsafe { Thread32Next(snapshot, &mut entry) } != 0;
    }
    unsafe { CloseHandle(snapshot) };
    if !found {
        bail!("suspended child process exposed no resumable thread");
    }
    Ok(())
}

pub fn os(value: impl AsRef<OsStr>) -> OsString {
    value.as_ref().to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[cfg(target_os = "linux")]
    #[test]
    fn procfs_esrch_is_a_completed_exit_race() {
        let error = io::Error::from_raw_os_error(libc::ESRCH);
        assert!(process_disappeared(&error));
        assert!(!process_disappeared(&io::Error::from_raw_os_error(
            libc::EACCES
        )));
    }

    #[tokio::test]
    async fn timeout_terminates_process() {
        let directory = tempdir().unwrap();
        #[cfg(windows)]
        let (program, arguments) = (
            OsString::from("cmd.exe"),
            vec![
                OsString::from("/D"),
                OsString::from("/C"),
                OsString::from("ping -n 20 127.0.0.1 >NUL"),
            ],
        );
        #[cfg(unix)]
        let (program, arguments) = (
            OsString::from("sh"),
            vec![OsString::from("-c"), OsString::from("sleep 20")],
        );
        let result = run_process(
            ProcessRequest {
                program,
                arguments,
                cwd: directory.path().to_owned(),
                timeout: Duration::from_millis(250),
                stdout_path: directory.path().join("stdout.log"),
                stderr_path: directory.path().join("stderr.log"),
                log_budget: Arc::new(LogBudget::new(2048)),
                environment: Vec::new(),
                fault: None,
            },
            Arc::new(AtomicU8::new(CANCEL_NONE)),
            Arc::new(DiscardLogSink),
        )
        .await
        .unwrap();
        assert_eq!(result.reason, ProcessTerminationReason::TimedOut);
        assert!(result.process_tree_terminated);
        assert!(!result.succeeded());
    }

    #[tokio::test]
    async fn spawn_failure_has_empty_logs_and_a_confirmed_empty_tree() {
        let directory = tempdir().unwrap();
        let stdout = directory.path().join("stdout.log");
        let stderr = directory.path().join("stderr.log");
        let result = run_process(
            ProcessRequest {
                program: OsString::from("cyc-command-that-does-not-exist"),
                arguments: Vec::new(),
                cwd: directory.path().to_owned(),
                timeout: Duration::from_secs(1),
                stdout_path: stdout.clone(),
                stderr_path: stderr.clone(),
                log_budget: Arc::new(LogBudget::new(2048)),
                environment: Vec::new(),
                fault: None,
            },
            Arc::new(AtomicU8::new(CANCEL_NONE)),
            Arc::new(DiscardLogSink),
        )
        .await
        .unwrap();
        assert_eq!(result.reason, ProcessTerminationReason::ExecutionFailed);
        assert!(result.process_tree_terminated);
        assert_eq!(fs::metadata(stdout).unwrap().len(), 0);
        assert_eq!(fs::metadata(stderr).unwrap().len(), 0);
    }

    #[tokio::test]
    async fn injected_monitor_failure_is_unconfirmed_not_terminal_proof() {
        let directory = tempdir().unwrap();
        #[cfg(windows)]
        let (program, arguments) = (
            OsString::from("cmd.exe"),
            vec![
                OsString::from("/D"),
                OsString::from("/C"),
                OsString::from("ping -n 20 127.0.0.1 >NUL"),
            ],
        );
        #[cfg(unix)]
        let (program, arguments) = (
            OsString::from("sh"),
            vec![OsString::from("-c"), OsString::from("sleep 20")],
        );
        let error = run_process(
            ProcessRequest {
                program,
                arguments,
                cwd: directory.path().to_owned(),
                timeout: Duration::from_secs(5),
                stdout_path: directory.path().join("stdout.log"),
                stderr_path: directory.path().join("stderr.log"),
                log_budget: Arc::new(LogBudget::new(2048)),
                environment: Vec::new(),
                fault: Some(TestProcessFault::MonitorFailureAfterAttach),
            },
            Arc::new(AtomicU8::new(CANCEL_NONE)),
            Arc::new(DiscardLogSink),
        )
        .await
        .unwrap_err();
        assert_eq!(error.containment(), ProcessContainment::Unconfirmed);
    }

    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn setsid_double_fork_cannot_escape_normal_root_exit() {
        let directory = tempdir().unwrap();
        let result = run_process(
            ProcessRequest {
                program: OsString::from("sh"),
                arguments: vec![
                    OsString::from("-c"),
                    OsString::from(
                        "setsid sh -c 'sleep 30 & echo $! > escaped.pid; exit 0' & \
                         while [ ! -s escaped.pid ]; do sleep 0.01; done; exit 0",
                    ),
                ],
                cwd: directory.path().to_owned(),
                timeout: Duration::from_secs(5),
                stdout_path: directory.path().join("stdout.log"),
                stderr_path: directory.path().join("stderr.log"),
                log_budget: Arc::new(LogBudget::new(2048)),
                environment: Vec::new(),
                fault: None,
            },
            Arc::new(AtomicU8::new(CANCEL_NONE)),
            Arc::new(DiscardLogSink),
        )
        .await
        .unwrap();
        assert_eq!(result.reason, ProcessTerminationReason::Exited);
        assert!(result.process_tree_terminated);
        let escaped_pid = fs::read_to_string(directory.path().join("escaped.pid"))
            .unwrap()
            .trim()
            .parse::<i32>()
            .unwrap();
        assert!(
            read_proc_stat(escaped_pid).unwrap().is_none(),
            "setsid descendant {escaped_pid} survived a successful receipt"
        );
    }

    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn rapid_exit_double_fork_stress_leaves_no_adopted_process() {
        let directory = tempdir().unwrap();
        for index in 0..20 {
            let pid_file = format!("rapid-{index}.pid");
            let command =
                format!("setsid sh -c 'sleep 30 & echo $! > {pid_file}; exit 0' & exit 0");
            let result = run_process(
                ProcessRequest {
                    program: OsString::from("sh"),
                    arguments: vec![OsString::from("-c"), OsString::from(command)],
                    cwd: directory.path().to_owned(),
                    timeout: Duration::from_secs(5),
                    stdout_path: directory.path().join(format!("stdout-{index}.log")),
                    stderr_path: directory.path().join(format!("stderr-{index}.log")),
                    log_budget: Arc::new(LogBudget::new(2048)),
                    environment: Vec::new(),
                    fault: None,
                },
                Arc::new(AtomicU8::new(CANCEL_NONE)),
                Arc::new(DiscardLogSink),
            )
            .await
            .unwrap();
            assert!(result.process_tree_terminated);
            if let Ok(value) = fs::read_to_string(directory.path().join(&pid_file)) {
                // Containment may terminate the writer between create/truncate
                // and writing its PID. An empty file is therefore valid race
                // evidence; a complete PID still must identify no survivor.
                if let Ok(escaped_pid) = value.trim().parse::<i32>() {
                    assert!(
                        read_proc_stat(escaped_pid).unwrap().is_none(),
                        "rapid double-fork descendant {escaped_pid} survived iteration {index}"
                    );
                } else {
                    assert!(
                        value.trim().is_empty(),
                        "unexpected PID evidence: {value:?}"
                    );
                }
            }
        }
    }

    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn preexisting_concurrent_child_is_not_claimed_by_managed_tree() {
        let execution_guard = test_exclusive_child_process_guard().await;
        let mut unrelated = Command::new("sh").args(["-c", "sleep 30"]).spawn().unwrap();
        let directory = tempdir().unwrap();
        let result = run_process_locked(
            ProcessRequest {
                program: OsString::from("sh"),
                arguments: vec![OsString::from("-c"), OsString::from("exit 0")],
                cwd: directory.path().to_owned(),
                timeout: Duration::from_secs(5),
                stdout_path: directory.path().join("stdout.log"),
                stderr_path: directory.path().join("stderr.log"),
                log_budget: Arc::new(LogBudget::new(2048)),
                environment: Vec::new(),
                fault: None,
            },
            Arc::new(AtomicU8::new(CANCEL_NONE)),
            Arc::new(DiscardLogSink),
            execution_guard,
        )
        .await
        .unwrap();
        assert!(result.succeeded());
        assert!(unrelated.try_wait().unwrap().is_none());
        unrelated.kill().unwrap();
        unrelated.wait().unwrap();
    }

    #[tokio::test]
    async fn timeout_kills_descendants_before_they_can_write_a_sentinel() {
        let directory = tempdir().unwrap();
        #[cfg(windows)]
        let (program, arguments) = (
            OsString::from("powershell.exe"),
            vec![
                OsString::from("-NoLogo"),
                OsString::from("-NoProfile"),
                OsString::from("-NonInteractive"),
                OsString::from("-Command"),
                OsString::from(
                    "$psi=[Diagnostics.ProcessStartInfo]::new(); \
                     $psi.FileName='cmd.exe'; \
                     $psi.Arguments='/D /C \"ping -n 3 127.0.0.1 >NUL & echo leaked>sentinel\"'; \
                     $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true; \
                     [Diagnostics.Process]::Start($psi) | Out-Null; \
                     Start-Sleep -Seconds 20",
                ),
            ],
        );
        #[cfg(unix)]
        let (program, arguments) = (
            OsString::from("sh"),
            vec![
                OsString::from("-c"),
                OsString::from("(sleep 1; echo leaked > sentinel) & wait"),
            ],
        );
        let result = run_process(
            ProcessRequest {
                program,
                arguments,
                cwd: directory.path().to_owned(),
                timeout: Duration::from_millis(200),
                stdout_path: directory.path().join("stdout.log"),
                stderr_path: directory.path().join("stderr.log"),
                log_budget: Arc::new(LogBudget::new(2048)),
                environment: Vec::new(),
                fault: None,
            },
            Arc::new(AtomicU8::new(CANCEL_NONE)),
            Arc::new(DiscardLogSink),
        )
        .await
        .unwrap();
        assert_eq!(result.reason, ProcessTerminationReason::TimedOut);
        assert!(result.process_tree_terminated);
        tokio::time::sleep(Duration::from_millis(1200)).await;
        assert!(!directory.path().join("sentinel").exists());
    }

    #[tokio::test]
    async fn normal_root_exit_cleans_up_background_descendants() {
        let directory = tempdir().unwrap();
        #[cfg(windows)]
        let (program, arguments) = (
            OsString::from("powershell.exe"),
            vec![
                OsString::from("-NoLogo"),
                OsString::from("-NoProfile"),
                OsString::from("-NonInteractive"),
                OsString::from("-Command"),
                OsString::from(
                    "$psi=[Diagnostics.ProcessStartInfo]::new(); \
                     $psi.FileName='cmd.exe'; \
                     $psi.Arguments='/D /C \"ping -n 3 127.0.0.1 >NUL & echo leaked>sentinel\"'; \
                     $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true; \
                     [Diagnostics.Process]::Start($psi) | Out-Null; exit 0",
                ),
            ],
        );
        #[cfg(unix)]
        let (program, arguments) = (
            OsString::from("sh"),
            vec![
                OsString::from("-c"),
                OsString::from("(sleep 1; echo leaked > sentinel) & exit 0"),
            ],
        );
        let result = run_process(
            ProcessRequest {
                program,
                arguments,
                cwd: directory.path().to_owned(),
                timeout: Duration::from_secs(5),
                stdout_path: directory.path().join("stdout.log"),
                stderr_path: directory.path().join("stderr.log"),
                log_budget: Arc::new(LogBudget::new(2048)),
                environment: Vec::new(),
                fault: None,
            },
            Arc::new(AtomicU8::new(CANCEL_NONE)),
            Arc::new(DiscardLogSink),
        )
        .await
        .unwrap();
        assert_eq!(result.reason, ProcessTerminationReason::Exited);
        assert!(result.process_tree_terminated);
        tokio::time::sleep(Duration::from_millis(1200)).await;
        assert!(!directory.path().join("sentinel").exists());
    }

    #[tokio::test]
    async fn one_log_budget_is_shared_across_processes_and_streams() {
        let directory = tempdir().unwrap();
        let budget = Arc::new(LogBudget::new(10));
        for index in 0..2 {
            #[cfg(windows)]
            let (program, arguments) = (
                OsString::from("cmd.exe"),
                vec![
                    OsString::from("/D"),
                    OsString::from("/C"),
                    OsString::from("echo 12345678"),
                ],
            );
            #[cfg(unix)]
            let (program, arguments) = (
                OsString::from("sh"),
                vec![OsString::from("-c"), OsString::from("printf 12345678")],
            );
            run_process(
                ProcessRequest {
                    program,
                    arguments,
                    cwd: directory.path().to_owned(),
                    timeout: Duration::from_secs(5),
                    stdout_path: directory.path().join(format!("stdout-{index}.log")),
                    stderr_path: directory.path().join(format!("stderr-{index}.log")),
                    log_budget: budget.clone(),
                    environment: Vec::new(),
                    fault: None,
                },
                Arc::new(AtomicU8::new(CANCEL_NONE)),
                Arc::new(DiscardLogSink),
            )
            .await
            .unwrap();
        }
        let stored = fs::metadata(directory.path().join("stdout-0.log"))
            .unwrap()
            .len()
            + fs::metadata(directory.path().join("stdout-1.log"))
                .unwrap()
                .len();
        assert_eq!(stored, 10);
        assert_eq!(budget.remaining(), 0);
        assert!(budget.truncated(LogStream::Stdout));
    }
}
