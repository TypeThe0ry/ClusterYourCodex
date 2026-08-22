use std::ffi::OsString;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use chrono::{DateTime, Utc};
use cyc_protocol::worker::{StepExecutionEvidence, TerminationReason};
use cyc_protocol::{JobSpec, Shell};
use serde::{Deserialize, Serialize};

use crate::process::{
    os, run_process, LogBudget, LogSink, ProcessContainment, ProcessRequest,
    ProcessTerminationReason, CANCEL_NONE,
};
use crate::source::{write_json_atomic, PreparedJob};

const DEFAULT_JOB_TIMEOUT_SECONDS: u64 = 3600;
const DEFAULT_STEP_TIMEOUT_SECONDS: u64 = 1800;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StepsOutcome {
    pub started_at: DateTime<Utc>,
    pub finished_at: DateTime<Utc>,
    pub exit_code: Option<i32>,
    pub signal: Option<i32>,
    pub termination: TerminationReason,
    pub process_tree_terminated: bool,
    pub forced_kill: bool,
    pub error: Option<String>,
    pub steps: Vec<StepExecutionEvidence>,
}

impl StepsOutcome {
    pub fn succeeded(&self) -> bool {
        self.exit_code == Some(0)
            && self.termination == TerminationReason::Exited
            && self.process_tree_terminated
            && !self.forced_kill
    }

    pub fn cancelled(&self) -> bool {
        matches!(
            self.termination,
            TerminationReason::CancelRequested | TerminationReason::LeaseLost
        )
    }
}

pub async fn execute_steps(
    prepared: &PreparedJob,
    spec: &JobSpec,
    cancellation: Arc<AtomicU8>,
    sink: Arc<dyn LogSink>,
    max_job_timeout_seconds: u64,
    log_budget: Arc<LogBudget>,
) -> StepsOutcome {
    let started_at = Utc::now();
    let configured_timeout = spec.timeout_seconds.unwrap_or(DEFAULT_JOB_TIMEOUT_SECONDS);
    let job_deadline =
        Instant::now() + Duration::from_secs(configured_timeout.min(max_job_timeout_seconds));
    let mut evidence = Vec::with_capacity(spec.steps.len());

    for (index, step) in spec.steps.iter().enumerate() {
        if cancellation.load(Ordering::SeqCst) != CANCEL_NONE {
            return finish_outcome(
                started_at,
                evidence,
                None,
                cancellation_termination(&cancellation),
                true,
                false,
                None,
                None,
            );
        }
        let remaining = job_deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return finish_outcome(
                started_at,
                evidence,
                None,
                TerminationReason::TimedOut,
                true,
                false,
                None,
                None,
            );
        }
        let requested =
            Duration::from_secs(step.timeout_seconds.unwrap_or(DEFAULT_STEP_TIMEOUT_SECONDS));
        let timeout = requested.min(remaining);
        let shell = step.shell.unwrap_or_else(default_shell);
        let step_started = Utc::now();
        let command = (|| -> Result<_> {
            let script_path = write_native_script(&prepared.scripts, index, shell, &step.script)?;
            let cwd =
                safe_working_directory(&prepared.repository, step.working_directory.as_deref())?;
            let (program, arguments) = shell_command(shell, &script_path)?;
            Ok((program, arguments, cwd))
        })();
        let (program, arguments, cwd) = match command {
            Ok(command) => command,
            Err(error) => {
                evidence.push(StepExecutionEvidence {
                    index: index as u32,
                    name: step.name.clone(),
                    shell,
                    started_at: step_started,
                    finished_at: Utc::now(),
                    exit_code: None,
                    termination: TerminationReason::ExecutionFailed,
                });
                return finish_outcome(
                    started_at,
                    evidence,
                    None,
                    TerminationReason::ExecutionFailed,
                    true,
                    false,
                    None,
                    Some(format!("prepare step {index} `{}`: {error:#}", step.name)),
                );
            }
        };
        let result = match run_process(
            ProcessRequest {
                program,
                arguments,
                cwd,
                timeout,
                stdout_path: prepared.logs.join(format!("step-{index:03}.stdout.log")),
                stderr_path: prepared.logs.join(format!("step-{index:03}.stderr.log")),
                log_budget: log_budget.clone(),
                environment: Vec::new(),
                #[cfg(test)]
                fault: None,
            },
            cancellation.clone(),
            sink.clone(),
        )
        .await
        {
            Ok(result) => result,
            Err(error) => {
                let process_tree_terminated =
                    error.containment() == ProcessContainment::ConfirmedEmpty;
                evidence.push(StepExecutionEvidence {
                    index: index as u32,
                    name: step.name.clone(),
                    shell,
                    started_at: step_started,
                    finished_at: Utc::now(),
                    exit_code: None,
                    termination: TerminationReason::ExecutionFailed,
                });
                return finish_outcome(
                    started_at,
                    evidence,
                    None,
                    TerminationReason::ExecutionFailed,
                    process_tree_terminated,
                    false,
                    None,
                    Some(format!("execute step {index} `{}`: {error:#}", step.name)),
                );
            }
        };
        let step_termination = protocol_termination(result.reason);
        evidence.push(StepExecutionEvidence {
            index: index as u32,
            name: step.name.clone(),
            shell,
            started_at: step_started,
            finished_at: Utc::now(),
            exit_code: result.exit_code,
            termination: step_termination,
        });
        if !result.succeeded() {
            let termination = if step_termination == TerminationReason::Exited {
                TerminationReason::ExecutionFailed
            } else {
                step_termination
            };
            return finish_outcome(
                started_at,
                evidence,
                result.exit_code,
                termination,
                result.process_tree_terminated,
                result.forced_kill,
                result.signal,
                Some(result.error.unwrap_or_else(|| {
                    format!("step {index} `{}` terminated as {termination:?}", step.name)
                })),
            );
        }
    }
    finish_outcome(
        started_at,
        evidence,
        Some(0),
        TerminationReason::Exited,
        true,
        false,
        None,
        None,
    )
}

#[allow(clippy::too_many_arguments)]
fn finish_outcome(
    started_at: DateTime<Utc>,
    steps: Vec<StepExecutionEvidence>,
    exit_code: Option<i32>,
    termination: TerminationReason,
    process_tree_terminated: bool,
    forced_kill: bool,
    signal: Option<i32>,
    error: Option<String>,
) -> StepsOutcome {
    StepsOutcome {
        started_at,
        finished_at: Utc::now(),
        exit_code,
        signal,
        termination,
        process_tree_terminated,
        forced_kill,
        error,
        steps,
    }
}

pub fn write_result(prepared: &PreparedJob, outcome: &StepsOutcome) -> Result<()> {
    let result = serde_json::json!({
        "apiVersion": "cyc.dev/worker-result/v1",
        "jobId": prepared.job_id,
        "runId": prepared.run_id,
        "source": prepared.source,
        "exitCode": outcome.exit_code,
        "signal": outcome.signal,
        "termination": outcome.termination,
        "processTreeTerminated": outcome.process_tree_terminated,
        "forcedKill": outcome.forced_kill,
        "error": outcome.error,
        "startedAt": outcome.started_at,
        "finishedAt": outcome.finished_at,
        "steps": outcome.steps,
    });
    write_json_atomic(&prepared.root.join("result.json"), &result)
}

fn write_native_script(
    scripts: &Path,
    index: usize,
    shell: Shell,
    script: &str,
) -> Result<PathBuf> {
    let extension = match shell {
        Shell::Powershell => "ps1",
        Shell::Cmd => "cmd",
        Shell::Bash | Shell::Zsh => "sh",
    };
    let path = scripts.join(format!("step-{index:03}.{extension}"));
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o700);
    }
    let mut file = options
        .open(&path)
        .with_context(|| format!("create native script {}", path.display()))?;
    file.write_all(script.as_bytes())
        .context("write native script")?;
    if !script.ends_with('\n') {
        file.write_all(b"\n").context("finish native script")?;
    }
    file.sync_all().context("flush native script")?;
    Ok(path)
}

pub fn safe_working_directory(repository: &Path, relative: Option<&str>) -> Result<PathBuf> {
    let canonical_repository = fs::canonicalize(repository)
        .with_context(|| format!("canonicalize repository {}", repository.display()))?;
    let Some(relative) = relative else {
        return Ok(canonical_repository);
    };
    if relative.trim().is_empty() || relative.contains('\0') {
        bail!("workingDirectory must be a non-empty safe relative path");
    }
    // Treat both separators as separators on every OS so a Windows-bound job
    // cannot hide an escape from a Linux controller (and vice versa).
    if relative.starts_with(['/', '\\'])
        || relative.contains(':')
        || relative
            .split(['/', '\\'])
            .any(|segment| segment == ".." || segment.is_empty())
    {
        bail!("workingDirectory escapes or is not a normalized relative path");
    }
    let path = Path::new(relative);
    if path.components().any(|component| {
        matches!(
            component,
            Component::ParentDir | Component::RootDir | Component::Prefix(_)
        )
    }) {
        bail!("workingDirectory contains a forbidden path component");
    }
    let candidate = canonical_repository.join(path);
    let canonical = fs::canonicalize(&candidate)
        .with_context(|| format!("workingDirectory does not exist: {}", candidate.display()))?;
    if !canonical.starts_with(&canonical_repository) || !canonical.is_dir() {
        bail!("workingDirectory resolved outside the repository or is not a directory");
    }
    Ok(canonical)
}

fn default_shell() -> Shell {
    if cfg!(windows) {
        Shell::Powershell
    } else if cfg!(target_os = "macos") {
        Shell::Zsh
    } else {
        Shell::Bash
    }
}

fn shell_command(shell: Shell, script_path: &Path) -> Result<(OsString, Vec<OsString>)> {
    let path = script_path.as_os_str().to_owned();
    match shell {
        Shell::Powershell if cfg!(windows) => Ok((
            os("powershell.exe"),
            vec![
                os("-NoLogo"),
                os("-NoProfile"),
                os("-NonInteractive"),
                os("-ExecutionPolicy"),
                os("Bypass"),
                os("-File"),
                path,
            ],
        )),
        Shell::Powershell => Ok((
            os("pwsh"),
            vec![
                os("-NoLogo"),
                os("-NoProfile"),
                os("-NonInteractive"),
                os("-File"),
                path,
            ],
        )),
        Shell::Cmd if cfg!(windows) => {
            Ok((os("cmd.exe"), vec![os("/D"), os("/Q"), os("/C"), path]))
        }
        Shell::Cmd => bail!("cmd shell is only available on Windows workers"),
        Shell::Bash => Ok((os("bash"), vec![os("--noprofile"), os("--norc"), path])),
        Shell::Zsh => Ok((os("zsh"), vec![os("-f"), path])),
    }
}

fn protocol_termination(reason: ProcessTerminationReason) -> TerminationReason {
    match reason {
        ProcessTerminationReason::Exited => TerminationReason::Exited,
        ProcessTerminationReason::ExecutionFailed => TerminationReason::ExecutionFailed,
        ProcessTerminationReason::TimedOut => TerminationReason::TimedOut,
        ProcessTerminationReason::CancelRequested => TerminationReason::CancelRequested,
        ProcessTerminationReason::LeaseLost => TerminationReason::LeaseLost,
        ProcessTerminationReason::TransportFailure => TerminationReason::TransportFailure,
    }
}

fn cancellation_termination(cancellation: &AtomicU8) -> TerminationReason {
    match cancellation.load(Ordering::SeqCst) {
        crate::process::CANCEL_REQUESTED => TerminationReason::CancelRequested,
        crate::process::CANCEL_LEASE_LOST => TerminationReason::LeaseLost,
        crate::process::CANCEL_TRANSPORT_FAILURE => TerminationReason::TransportFailure,
        crate::process::CANCEL_JOB_TIMEOUT => TerminationReason::TimedOut,
        _ => TerminationReason::CancelRequested,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(windows)]
    use crate::process::DiscardLogSink;
    use tempfile::tempdir;

    #[test]
    fn rejects_path_escape_and_symlink_escape() {
        let directory = tempdir().unwrap();
        let repository = directory.path().join("repo");
        fs::create_dir(&repository).unwrap();
        fs::create_dir(repository.join("inside")).unwrap();
        assert!(safe_working_directory(&repository, Some("inside")).is_ok());
        for path in [
            "../outside",
            "inside/../../outside",
            "/tmp",
            "C:\\Windows",
            "a//b",
        ] {
            assert!(
                safe_working_directory(&repository, Some(path)).is_err(),
                "accepted {path}"
            );
        }

        #[cfg(unix)]
        {
            use std::os::unix::fs::symlink;
            let outside = directory.path().join("outside");
            fs::create_dir(&outside).unwrap();
            symlink(&outside, repository.join("link")).unwrap();
            assert!(safe_working_directory(&repository, Some("link")).is_err());
        }
    }

    #[cfg(windows)]
    #[test]
    fn powershell_launcher_uses_bypass_as_fixed_argv() {
        let script = Path::new(r"C:\worker job\scripts\step-000.ps1");
        let (program, arguments) = shell_command(Shell::Powershell, script).unwrap();
        assert_eq!(program, OsString::from("powershell.exe"));
        assert_eq!(
            arguments,
            vec![
                OsString::from("-NoLogo"),
                OsString::from("-NoProfile"),
                OsString::from("-NonInteractive"),
                OsString::from("-ExecutionPolicy"),
                OsString::from("Bypass"),
                OsString::from("-File"),
                script.as_os_str().to_owned(),
            ]
        );
    }

    #[cfg(not(windows))]
    #[test]
    fn non_windows_powershell_launcher_is_unchanged() {
        let script = Path::new("/worker job/scripts/step-000.ps1");
        let (program, arguments) = shell_command(Shell::Powershell, script).unwrap();
        assert_eq!(program, OsString::from("pwsh"));
        assert_eq!(
            arguments,
            vec![
                OsString::from("-NoLogo"),
                OsString::from("-NoProfile"),
                OsString::from("-NonInteractive"),
                OsString::from("-File"),
                script.as_os_str().to_owned(),
            ]
        );
    }

    #[cfg(windows)]
    #[tokio::test]
    async fn powershell_native_step_runs_through_contained_process_runner() {
        let directory = tempdir().unwrap();
        let scripts = directory.path().join("scripts");
        let logs = directory.path().join("logs");
        fs::create_dir(&scripts).unwrap();
        fs::create_dir(&logs).unwrap();
        let script = write_native_script(
            &scripts,
            0,
            Shell::Powershell,
            "$ErrorActionPreference = 'Stop'; Write-Output 'cyc-powershell-step-ok'",
        )
        .unwrap();
        let (program, arguments) = shell_command(Shell::Powershell, &script).unwrap();
        let stdout = logs.join("step.stdout.log");
        let result = run_process(
            ProcessRequest {
                program,
                arguments,
                cwd: directory.path().to_owned(),
                // Windows runners can spend well over ten seconds on the
                // first PowerShell process while Defender/JIT initialization
                // is cold. This is only a failure ceiling: the normal path
                // still returns immediately when the process exits.
                timeout: Duration::from_secs(60),
                stdout_path: stdout.clone(),
                stderr_path: logs.join("step.stderr.log"),
                log_budget: Arc::new(LogBudget::new(16 * 1024)),
                environment: vec![(
                    OsString::from("PSExecutionPolicyPreference"),
                    OsString::from("Restricted"),
                )],
                fault: None,
            },
            Arc::new(AtomicU8::new(CANCEL_NONE)),
            Arc::new(DiscardLogSink),
        )
        .await
        .unwrap();
        assert!(result.succeeded(), "{result:?}");
        assert_eq!(
            fs::read_to_string(stdout).unwrap().trim(),
            "cyc-powershell-step-ok"
        );
    }
}
