use std::fmt;
use std::fs::{self, OpenOptions};
use std::future::Future;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, AtomicU8, Ordering};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use chrono::{DateTime, Utc};
use cyc_protocol::worker::{
    ArtifactMetadata, ClaimAssignment, ClaimRequest, ExecutionEvidence, ExecutionSourceEvidence,
    HeartbeatRequest, PairRequest, RunCompletion, RunEvidence, RunStreamsEvidence, StateUpdate,
    TerminationEvidence, TerminationReason,
};
use cyc_protocol::{canonical_job_digest, JobState};
use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;

use crate::artifacts::{collect_artifacts, ArtifactEvidence, MAX_ARTIFACT_BYTES};
use crate::config::{EnrollmentBundle, WorkerConfig, WORKER_CONFIG_VERSION};
use crate::executor::{execute_steps, write_result, StepsOutcome};
use crate::http::{HttpLogSink, RunSession, VersionConflict, WorkerClient};
use crate::probe_at;
use crate::process::{
    ensure_process_containment_available, LogBudget, LogSink, ProcessTerminationReason,
    CANCEL_JOB_TIMEOUT, CANCEL_LEASE_LOST, CANCEL_NONE, CANCEL_REQUESTED, CANCEL_TRANSPORT_FAILURE,
};
use crate::security::{
    ensure_no_windows_reparse_points, ensure_protected_directory, prepare_private_directory,
    write_secret_file,
};
use crate::source::{prepare_job, PreparedJob, SourceContainment, SourceEvidence};

const CONTAINMENT_QUARANTINE_FILE: &str = ".cyc-containment-quarantine.json";
const ACTIVE_RUN_GUARD_VERSION: &str = "cyc.dev/active-run-guard/v1";
const ACTIVE_RUN_GUARD_REASON: &str = "active_run_pending_terminal_ack";

pub async fn pair(enrollment_file: &Path, config_path: &Path) -> Result<WorkerConfig> {
    let layout = prepare_pairing_layout(config_path)?;
    let enrollment = EnrollmentBundle::load(enrollment_file)?;
    let request = PairRequest {
        display_name: None,
        probe: probe_at(&layout.workspace_root)?,
    };
    let paired = WorkerClient::pair(&enrollment, &request).await?;
    // Re-verify the namespace after the network round trip and before any
    // long-lived identity bytes are persisted.
    ensure_protected_directory(&layout.config_parent)?;
    ensure_protected_directory(&layout.workspace_root)?;
    write_secret_file(&layout.credential_file, paired.credential.expose())?;
    let config = WorkerConfig {
        api_version: WORKER_CONFIG_VERSION.to_owned(),
        worker_url: enrollment.worker_url.clone(),
        certificate_pem: enrollment.certificate_pem.clone(),
        controller_id: paired.response.controller_id,
        node_id: paired.response.node_id,
        worker_api_version: paired.response.api_version,
        heartbeat_interval_seconds: u64::from(paired.response.heartbeat_interval_seconds),
        lease_seconds: u64::from(paired.response.lease_seconds),
        workspace_root: layout.workspace_root,
        credential_file: layout.credential_file.clone(),
    };
    if let Err(error) = config.write(&layout.config_path) {
        let _ = fs::remove_file(&layout.credential_file);
        return Err(error);
    }
    Ok(config)
}

#[derive(Debug)]
struct PairingLayout {
    config_path: PathBuf,
    config_parent: PathBuf,
    workspace_root: PathBuf,
    credential_file: PathBuf,
}

fn prepare_pairing_layout(config_path: &Path) -> Result<PairingLayout> {
    let config_path = absolute_path(config_path)?;
    if path_entry_exists(&config_path)? {
        bail!("worker config already exists: {}", config_path.display());
    }
    let config_parent = config_path
        .parent()
        .context("worker config must have a parent directory")?
        .to_path_buf();
    prepare_private_directory(&config_parent).with_context(|| {
        format!(
            "provision or verify worker config directory {}",
            config_parent.display()
        )
    })?;

    // Anything prepositioned while a new directory was being secured is
    // rejected before the one-time pairing code can be consumed.
    if path_entry_exists(&config_path)? {
        bail!(
            "worker config appeared during secure layout creation: {}",
            config_path.display()
        );
    }
    let credential_file = config_path.with_extension("credential");
    if path_entry_exists(&credential_file)? {
        bail!(
            "worker credential already exists before pairing: {}",
            credential_file.display()
        );
    }

    let workspace_root = config_parent.join("workspace");
    prepare_private_directory(&workspace_root).with_context(|| {
        format!(
            "provision or verify worker workspace {}",
            workspace_root.display()
        )
    })?;
    ensure_protected_directory(&config_parent)?;
    ensure_protected_directory(&workspace_root)?;
    Ok(PairingLayout {
        config_path,
        config_parent,
        workspace_root,
        credential_file,
    })
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkerStatus {
    api_version: &'static str,
    paired: bool,
    controller_id: uuid::Uuid,
    node_id: uuid::Uuid,
    worker_url: String,
    workspace_root: PathBuf,
    credential_protected: bool,
    quarantined: bool,
    quarantine_file: Option<PathBuf>,
    probe: cyc_protocol::worker::ProbeReport,
}

pub fn status(config_path: &Path) -> Result<WorkerStatus> {
    let config = WorkerConfig::load(config_path)?;
    // Reading validates that the protected file exists and has acceptable
    // permissions. The credential value never enters the status object.
    let _credential = config.load_credential()?;
    ensure_protected_directory(&config.workspace_root)
        .context("refuse unprotected worker workspace during status")?;
    let quarantine_file = containment_quarantine_path(&config);
    let quarantined = path_entry_exists(&quarantine_file)?;
    Ok(WorkerStatus {
        api_version: WORKER_CONFIG_VERSION,
        paired: true,
        controller_id: config.controller_id,
        node_id: config.node_id,
        worker_url: config.worker_url.clone(),
        workspace_root: config.workspace_root.clone(),
        credential_protected: true,
        quarantined,
        quarantine_file: quarantined.then_some(quarantine_file),
        probe: probe_at(&config.workspace_root)?,
    })
}

pub async fn run_forever(config_path: &Path) -> Result<()> {
    let config = WorkerConfig::load(config_path)?;
    ensure_protected_directory(&config.workspace_root)
        .context("refuse unprotected worker workspace before run")?;
    refuse_containment_quarantine(&config)?;
    ensure_process_containment_available()
        .context("managed execution containment gate failed; refusing to claim work")?;
    let client = Arc::new(WorkerClient::from_config(&config)?);
    let mut transient_failures = 0u32;
    loop {
        ensure_protected_directory(&config.workspace_root)
            .context("worker workspace protection changed; refusing another claim")?;
        // Check on every poll, not only at daemon startup. Any marker entry --
        // including a truncated or malformed record left by a crash -- blocks
        // another claim before a resource probe or controller request can run.
        refuse_containment_quarantine(&config)?;
        let request = ClaimRequest {
            probe: probe_at(&config.workspace_root)?,
            active_run_ids: Vec::new(),
        };
        refuse_containment_quarantine(&config)?;
        let claim = match client.claim(&request).await {
            Ok(claim) => {
                transient_failures = 0;
                claim
            }
            Err(error) if !fatal_controller_error(&error) => {
                transient_failures = transient_failures.saturating_add(1);
                let delay = 2u64.saturating_pow(transient_failures.min(4)).min(30);
                eprintln!("worker claim failed; retrying in {delay}s: {error:#}");
                tokio::select! {
                    _ = tokio::time::sleep(Duration::from_secs(delay)) => continue,
                    _ = tokio::signal::ctrl_c() => return Ok(()),
                }
            }
            Err(error) => return Err(error.context("worker claim failed permanently")),
        };
        let Some(assignment) = claim.assignment else {
            let delay = u64::from(claim.retry_after_seconds.clamp(1, 300));
            tokio::select! {
                _ = tokio::time::sleep(Duration::from_secs(delay)) => continue,
                _ = tokio::signal::ctrl_c() => return Ok(()),
            }
        };
        let cancellation = Arc::new(AtomicU8::new(CANCEL_NONE));
        let run_id = assignment.run_id;
        let work = run_guarded_assignment(&config, run_id, async {
            let run_credential = claim
                .run_credential
                .context("claimed assignment omitted run credential")?;
            process_assignment(
                &config,
                client.clone(),
                assignment,
                run_credential,
                cancellation.clone(),
            )
            .await
        });
        tokio::pin!(work);
        tokio::select! {
            result = &mut work => {
                if let Err(error) = result {
                    handle_guarded_assignment_error(error).await?;
                }
            },
            _ = tokio::signal::ctrl_c() => {
                cancellation.store(CANCEL_REQUESTED, Ordering::SeqCst);
                if let Err(error) = work.await {
                    handle_guarded_assignment_error(error).await?;
                }
                return Ok(());
            }
        }
    }
}

async fn process_assignment(
    config: &WorkerConfig,
    client: Arc<WorkerClient>,
    assignment: ClaimAssignment,
    run_credential: crate::security::SecretString,
    cancellation: Arc<AtomicU8>,
) -> Result<()> {
    assignment
        .validate()
        .context("validate claimed assignment")?;
    validate_job_digest(&assignment)?;
    if assignment.lease_until <= Utc::now() {
        bail!("claimed assignment lease is already expired");
    }
    let session = Arc::new(client.run_session(&assignment, run_credential));
    let log_sink = Arc::new(HttpLogSink::new(session.clone()));
    let sink: Arc<dyn LogSink> = log_sink.clone();
    let log_budget = Arc::new(LogBudget::new(assignment.limits.max_log_bytes));
    let control = Arc::new(RunControl::new(
        assignment.state_version,
        assignment.lease_until,
        JobState::Preparing,
        cancellation.clone(),
    ));

    let heartbeat = tokio::spawn(heartbeat_loop(
        config.clone(),
        assignment.run_id,
        assignment.lease_id,
        session.clone(),
        control.clone(),
        log_sink.clone(),
    ));
    let watchdog = tokio::spawn(lease_watchdog(control.clone()));
    let effective_timeout = assignment
        .job_spec
        .timeout_seconds
        .unwrap_or(assignment.limits.job_timeout_seconds)
        .min(assignment.limits.job_timeout_seconds);
    let timeout_cancel = cancellation.clone();
    let timeout_watchdog = tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(effective_timeout)).await;
        let _ = timeout_cancel.compare_exchange(
            CANCEL_NONE,
            CANCEL_JOB_TIMEOUT,
            Ordering::SeqCst,
            Ordering::SeqCst,
        );
    });

    let result = execute_assignment(
        config,
        &assignment,
        session.clone(),
        control.clone(),
        cancellation,
        sink,
        log_sink,
        log_budget,
    )
    .await;
    heartbeat.abort();
    watchdog.abort();
    timeout_watchdog.abort();
    let _ = heartbeat.await;
    let _ = watchdog.await;
    let _ = timeout_watchdog.await;
    result
}

#[allow(clippy::too_many_arguments)]
async fn execute_assignment(
    config: &WorkerConfig,
    assignment: &ClaimAssignment,
    session: Arc<RunSession>,
    control: Arc<RunControl>,
    cancellation: Arc<AtomicU8>,
    sink: Arc<dyn LogSink>,
    log_sink: Arc<HttpLogSink>,
    log_budget: Arc<LogBudget>,
) -> Result<()> {
    let prepared = match prepare_job(
        &config.workspace_root,
        assignment.job_id,
        assignment.run_id,
        &assignment.job_spec,
        &assignment.workspace,
        cancellation.clone(),
        sink.clone(),
        log_budget.clone(),
    )
    .await
    {
        Ok(prepared) => prepared,
        Err(error) => {
            let finished_at = Utc::now();
            let (final_state, termination) = source_failure_termination(
                &assignment.job_spec.source,
                error.containment(),
                &cancellation,
                finished_at,
            )
            .with_context(|| {
                format!(
                    "source preparation failed without terminal containment proof; refusing completion: {error:#}"
                )
            })?;
            let execution = ExecutionEvidence {
                source: assigned_source_evidence(assignment),
                steps: Vec::new(),
                streams: log_sink.streams(&log_budget),
                termination,
            };
            return complete_early_failure(
                &session,
                &control,
                assignment,
                final_state,
                format!("source preparation failed: {error:#}"),
                finished_at,
                execution,
            )
            .await;
        }
    };
    let started_at = Utc::now();
    transition(
        &session,
        &control,
        assignment,
        JobState::Running,
        Some(RunEvidence {
            started_at: Some(started_at),
            ..RunEvidence::default()
        }),
    )
    .await?;

    let outcome = execute_steps(
        &prepared,
        &assignment.job_spec,
        cancellation.clone(),
        sink,
        assignment.limits.job_timeout_seconds,
        log_budget.clone(),
    )
    .await;
    if let Err(error) = write_result(&prepared, &outcome) {
        eprintln!("write local result evidence failed: {error:#}");
    }
    if !outcome.process_tree_terminated {
        return Err(ContainmentProofLost::new(
            "step execution ended without proof that the managed process tree is empty",
        )
        .into());
    }
    if !outcome.succeeded() {
        let final_state = if outcome.cancelled() {
            JobState::Cancelled
        } else {
            JobState::Failed
        };
        let finished_at = Utc::now();
        let execution = execution_from_outcome(
            &prepared.source,
            &outcome,
            log_sink.streams(&log_budget),
            outcome.termination,
            finished_at,
        );
        return complete_after_start(
            &session,
            &control,
            assignment,
            started_at,
            final_state,
            outcome.exit_code,
            Some(
                outcome
                    .error
                    .clone()
                    .unwrap_or_else(|| format!("job terminated: {:?}", outcome.termination)),
            ),
            Vec::new(),
            finished_at,
            execution,
        )
        .await;
    }

    transition(
        &session,
        &control,
        assignment,
        JobState::Verifying,
        Some(RunEvidence {
            started_at: Some(started_at),
            ..RunEvidence::default()
        }),
    )
    .await?;
    let upload = collect_and_upload(&prepared, assignment, &session, cancellation.as_ref()).await;
    let artifacts = match upload.error {
        None => upload.artifacts,
        Some(error) => {
            let finished_at = Utc::now();
            let reason = cancellation_termination_reason(&cancellation)
                .unwrap_or(TerminationReason::ArtifactVerificationFailed);
            let final_state = cancellation_final_state(&cancellation);
            let execution = execution_from_outcome(
                &prepared.source,
                &outcome,
                log_sink.streams(&log_budget),
                reason,
                finished_at,
            );
            return complete_after_start(
                &session,
                &control,
                assignment,
                started_at,
                final_state,
                Some(0),
                Some(format!("artifact verification failed: {error:#}")),
                upload.artifacts,
                finished_at,
                execution,
            )
            .await;
        }
    };
    let finished_at = Utc::now();
    let artifact_ids = artifacts.iter().map(|artifact| artifact.id).collect();
    let execution = execution_from_outcome(
        &prepared.source,
        &outcome,
        log_sink.streams(&log_budget),
        TerminationReason::Exited,
        finished_at,
    );
    let completion = RunCompletion {
        run_id: assignment.run_id,
        lease_id: assignment.lease_id,
        expected_version: control.version.load(Ordering::SeqCst),
        final_state: JobState::Succeeded,
        evidence: RunEvidence {
            started_at: Some(started_at),
            finished_at: Some(finished_at),
            exit_code: Some(0),
            error: None,
            artifact_ids,
        },
        execution,
        artifacts,
    };
    let _guard = control.api_gate.lock().await;
    submit_completion(&session, &control, &completion).await
}

struct ArtifactUploadOutcome {
    artifacts: Vec<ArtifactMetadata>,
    error: Option<anyhow::Error>,
}

async fn collect_and_upload(
    prepared: &PreparedJob,
    assignment: &ClaimAssignment,
    session: &RunSession,
    cancellation: &AtomicU8,
) -> ArtifactUploadOutcome {
    let artifacts = match collect_artifacts(prepared, &assignment.job_spec.artifacts) {
        Ok(artifacts) => artifacts,
        Err(error) => {
            return ArtifactUploadOutcome {
                artifacts: Vec::new(),
                error: Some(error),
            };
        }
    };
    if artifacts.len() > assignment.limits.max_artifact_count as usize {
        return ArtifactUploadOutcome {
            artifacts: Vec::new(),
            error: Some(anyhow::anyhow!("artifact count exceeds assignment limit")),
        };
    }
    let total_bytes = match artifacts
        .iter()
        .try_fold(0u64, |total, artifact| {
            total.checked_add(artifact.size_bytes)
        })
        .context("artifact byte count overflow")
    {
        Ok(total) => total,
        Err(error) => {
            return ArtifactUploadOutcome {
                artifacts: Vec::new(),
                error: Some(error),
            };
        }
    };
    if total_bytes > assignment.limits.max_artifact_bytes {
        return ArtifactUploadOutcome {
            artifacts: Vec::new(),
            error: Some(anyhow::anyhow!("artifact bytes exceed assignment limit")),
        };
    }
    let mut uploaded = Vec::with_capacity(artifacts.len());
    for artifact in artifacts {
        if cancellation.load(Ordering::SeqCst) != CANCEL_NONE {
            return ArtifactUploadOutcome {
                artifacts: uploaded,
                error: Some(anyhow::anyhow!(
                    "artifact verification interrupted by run cancellation"
                )),
            };
        }
        if artifact.size_bytes > assignment.limits.max_artifact_bytes.min(MAX_ARTIFACT_BYTES) {
            return ArtifactUploadOutcome {
                artifacts: uploaded,
                error: Some(anyhow::anyhow!(
                    "artifact `{}` exceeds per-upload limit",
                    artifact.name
                )),
            };
        }
        if let Err(error) = session.upload_artifact(&artifact).await {
            return ArtifactUploadOutcome {
                artifacts: uploaded,
                error: Some(error),
            };
        }
        uploaded.push(artifact_metadata(assignment.run_id, artifact));
    }
    ArtifactUploadOutcome {
        artifacts: uploaded,
        error: None,
    }
}

fn artifact_metadata(run_id: uuid::Uuid, artifact: ArtifactEvidence) -> ArtifactMetadata {
    ArtifactMetadata {
        id: artifact.id,
        run_id,
        relative_path: artifact.name,
        size_bytes: artifact.size_bytes,
        sha256: artifact.sha256,
        media_type: None,
        created_at: Utc::now(),
    }
}

fn assigned_source_evidence(assignment: &ClaimAssignment) -> ExecutionSourceEvidence {
    match &assignment.job_spec.source {
        cyc_protocol::SourceSpec::Git {
            repository,
            revision,
        } => ExecutionSourceEvidence {
            kind: "git".to_owned(),
            repository: repository.clone(),
            requested_revision: revision.clone(),
            resolved_revision: String::new(),
            tree: String::new(),
            git_version: "unavailable".to_owned(),
        },
        cyc_protocol::SourceSpec::Snapshot { digest, .. } => ExecutionSourceEvidence {
            kind: "snapshot".to_owned(),
            repository: "snapshot".to_owned(),
            requested_revision: digest.clone(),
            resolved_revision: String::new(),
            tree: String::new(),
            git_version: "not-applicable".to_owned(),
        },
    }
}

fn prepared_source_evidence(source: &SourceEvidence) -> ExecutionSourceEvidence {
    ExecutionSourceEvidence {
        kind: source.kind.clone(),
        repository: source.repository.clone(),
        requested_revision: source.requested_revision.clone(),
        resolved_revision: source.resolved_revision.clone(),
        tree: source.tree.clone(),
        git_version: source.git_version.clone(),
    }
}

fn execution_from_outcome(
    source: &SourceEvidence,
    outcome: &StepsOutcome,
    streams: RunStreamsEvidence,
    reason: TerminationReason,
    observed_at: DateTime<Utc>,
) -> ExecutionEvidence {
    ExecutionEvidence {
        source: prepared_source_evidence(source),
        steps: outcome.steps.clone(),
        streams,
        termination: TerminationEvidence {
            reason,
            process_tree_terminated: outcome.process_tree_terminated,
            forced_kill: outcome.forced_kill,
            root_exit_code: outcome.exit_code,
            signal: outcome.signal,
            observed_at,
        },
    }
}

async fn complete_early_failure(
    session: &RunSession,
    control: &RunControl,
    assignment: &ClaimAssignment,
    final_state: JobState,
    error: String,
    finished_at: DateTime<Utc>,
    execution: ExecutionEvidence,
) -> Result<()> {
    let completion = early_failure_completion(
        assignment,
        control.version.load(Ordering::SeqCst),
        final_state,
        error,
        finished_at,
        execution,
    );
    let _guard = control.api_gate.lock().await;
    submit_completion(session, control, &completion).await
}

fn early_failure_completion(
    assignment: &ClaimAssignment,
    expected_version: u64,
    final_state: JobState,
    error: String,
    finished_at: DateTime<Utc>,
    execution: ExecutionEvidence,
) -> RunCompletion {
    // Source preparation can fail after a managed Git process exits. Bind the
    // run-level exit code to that exact observed root result, just as the
    // protocol requires for step completions. Snapshot/local validation
    // failures and termination paths without a root process remain `None` on
    // both sides of the invariant.
    let exit_code = execution.termination.root_exit_code;
    RunCompletion {
        run_id: assignment.run_id,
        lease_id: assignment.lease_id,
        expected_version,
        final_state,
        evidence: RunEvidence {
            finished_at: Some(finished_at),
            exit_code,
            error: Some(error),
            ..RunEvidence::default()
        },
        execution,
        artifacts: Vec::new(),
    }
}

#[allow(clippy::too_many_arguments)]
async fn complete_after_start(
    session: &RunSession,
    control: &RunControl,
    assignment: &ClaimAssignment,
    started_at: DateTime<Utc>,
    final_state: JobState,
    exit_code: Option<i32>,
    error: Option<String>,
    artifacts: Vec<ArtifactMetadata>,
    finished_at: DateTime<Utc>,
    execution: ExecutionEvidence,
) -> Result<()> {
    let artifact_ids = artifacts.iter().map(|artifact| artifact.id).collect();
    let completion = RunCompletion {
        run_id: assignment.run_id,
        lease_id: assignment.lease_id,
        expected_version: control.version.load(Ordering::SeqCst),
        final_state,
        evidence: RunEvidence {
            started_at: Some(started_at),
            finished_at: Some(finished_at),
            exit_code,
            error,
            artifact_ids,
        },
        execution,
        artifacts,
    };
    let _guard = control.api_gate.lock().await;
    submit_completion(session, control, &completion).await
}

async fn submit_completion(
    session: &RunSession,
    control: &RunControl,
    completion: &RunCompletion,
) -> Result<()> {
    let mut pending = completion.clone();
    pending.expected_version = control.version.load(Ordering::SeqCst);
    for attempt in 0..3 {
        match session.complete(&pending).await {
            Ok(response) => {
                if response.run.id != pending.run_id || response.run.state != pending.final_state {
                    bail!("controller completion acknowledgement does not match the terminal run");
                }
                control
                    .version
                    .store(response.state_version, Ordering::SeqCst);
                *control.state.lock().await = pending.final_state;
                if response.cancel_requested {
                    control
                        .cancellation
                        .store(CANCEL_REQUESTED, Ordering::SeqCst);
                }
                return Ok(());
            }
            Err(error) => {
                if let Some(conflict) = error.downcast_ref::<VersionConflict>() {
                    apply_version_conflict(control, conflict).await;
                    if conflict.current_state.is_some_and(JobState::is_terminal) {
                        return Err(
                            error.context("controller run became terminal during completion")
                        );
                    }
                    pending.expected_version = conflict.current_version;
                    if conflict.cancel_requested && pending.final_state != JobState::Cancelled {
                        if !pending.execution.termination.process_tree_terminated {
                            return Err(error.context(
                                "controller requested cancellation before process-tree termination was proven",
                            ));
                        }
                        let observed_at = Utc::now();
                        pending.final_state = JobState::Cancelled;
                        pending.evidence.finished_at = Some(observed_at);
                        pending.evidence.error =
                            Some("controller cancellation observed during terminal CAS".to_owned());
                        pending.execution.termination.reason = TerminationReason::CancelRequested;
                        pending.execution.termination.observed_at = observed_at;
                    }
                    continue;
                }
                if crate::http::is_retryable_transport_error(&error) && attempt < 2 {
                    // The controller may have committed before the connection
                    // dropped. Retry the byte-for-byte identical receipt so its
                    // durable digest can acknowledge a lost response.
                    tokio::time::sleep(Duration::from_millis(200 * (attempt + 1) as u64)).await;
                    continue;
                }
                return Err(error);
            }
        }
    }
    bail!("controller completion version changed repeatedly")
}

async fn transition(
    session: &RunSession,
    control: &RunControl,
    assignment: &ClaimAssignment,
    next_state: JobState,
    evidence: Option<RunEvidence>,
) -> Result<()> {
    let _guard = control.api_gate.lock().await;
    for attempt in 0..3 {
        let update = StateUpdate {
            run_id: assignment.run_id,
            lease_id: assignment.lease_id,
            expected_version: control.version.load(Ordering::SeqCst),
            next_state,
            evidence: evidence.clone(),
        };
        match session.state(&update).await {
            Ok(response) => {
                if response.run.id != assignment.run_id || response.run.state != next_state {
                    bail!("controller state acknowledgement does not match the run transition");
                }
                control
                    .version
                    .store(response.state_version, Ordering::SeqCst);
                *control.state.lock().await = next_state;
                if response.cancel_requested {
                    control
                        .cancellation
                        .store(CANCEL_REQUESTED, Ordering::SeqCst);
                }
                return Ok(());
            }
            Err(error) => {
                if let Some(conflict) = error.downcast_ref::<VersionConflict>() {
                    apply_version_conflict(control, conflict).await;
                    if conflict.cancel_requested {
                        return Ok(());
                    }
                    if conflict.current_state == Some(next_state) {
                        return Ok(());
                    }
                    if conflict.current_state.is_some_and(JobState::is_terminal) {
                        return Err(
                            error.context("controller run became terminal during transition")
                        );
                    }
                    continue;
                }
                if crate::http::is_retryable_transport_error(&error) && attempt < 2 {
                    tokio::time::sleep(Duration::from_millis(200 * (attempt + 1) as u64)).await;
                    continue;
                }
                return Err(error);
            }
        }
    }
    bail!("controller state version changed repeatedly")
}

async fn apply_version_conflict(control: &RunControl, conflict: &VersionConflict) {
    control
        .version
        .store(conflict.current_version, Ordering::SeqCst);
    if let Some(state) = conflict.current_state {
        *control.state.lock().await = state;
    }
    if conflict.cancel_requested {
        control
            .cancellation
            .store(CANCEL_REQUESTED, Ordering::SeqCst);
    }
}

struct RunControl {
    version: AtomicU64,
    lease_until: Mutex<DateTime<Utc>>,
    state: Mutex<JobState>,
    api_gate: Mutex<()>,
    cancellation: Arc<AtomicU8>,
}

impl RunControl {
    fn new(
        version: u64,
        lease_until: DateTime<Utc>,
        state: JobState,
        cancellation: Arc<AtomicU8>,
    ) -> Self {
        Self {
            version: AtomicU64::new(version),
            lease_until: Mutex::new(lease_until),
            state: Mutex::new(state),
            api_gate: Mutex::new(()),
            cancellation,
        }
    }
}

async fn heartbeat_loop(
    config: WorkerConfig,
    run_id: uuid::Uuid,
    lease_id: uuid::Uuid,
    session: Arc<RunSession>,
    control: Arc<RunControl>,
    log_sink: Arc<HttpLogSink>,
) {
    let mut interval =
        tokio::time::interval(Duration::from_secs(config.heartbeat_interval_seconds));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    interval.tick().await;
    loop {
        interval.tick().await;
        if control.cancellation.load(Ordering::SeqCst) != CANCEL_NONE {
            return;
        }
        let _guard = control.api_gate.lock().await;
        let state = *control.state.lock().await;
        let last_log_sequence = log_sink.last_sequence();
        let request = HeartbeatRequest {
            run_id,
            lease_id,
            expected_version: control.version.load(Ordering::SeqCst),
            state,
            // Do not spawn probe helpers (for example nvidia-smi) while a
            // managed process is active. Linux descendant containment relies
            // on the daemon having no unrelated concurrent children.
            probe: None,
            last_log_sequence,
        };
        match session.heartbeat(&request).await {
            Ok(response) => {
                control
                    .version
                    .store(response.current_version, Ordering::SeqCst);
                *control.lease_until.lock().await = response.lease_until;
                if response.cancel_requested {
                    control
                        .cancellation
                        .store(CANCEL_REQUESTED, Ordering::SeqCst);
                    return;
                }
            }
            Err(error) => {
                if let Some(conflict) = error.downcast_ref::<VersionConflict>() {
                    apply_version_conflict(&control, conflict).await;
                    if conflict.cancel_requested {
                        return;
                    }
                    continue;
                }
                eprintln!("run heartbeat failed; lease watchdog remains active: {error:#}");
            }
        }
    }
}

async fn lease_watchdog(control: Arc<RunControl>) {
    let mut interval = tokio::time::interval(Duration::from_millis(250));
    loop {
        interval.tick().await;
        if control.cancellation.load(Ordering::SeqCst) != CANCEL_NONE {
            return;
        }
        if Utc::now() >= *control.lease_until.lock().await {
            let _ = control.cancellation.compare_exchange(
                CANCEL_NONE,
                CANCEL_LEASE_LOST,
                Ordering::SeqCst,
                Ordering::SeqCst,
            );
            return;
        }
    }
}

fn validate_job_digest(assignment: &ClaimAssignment) -> Result<()> {
    let actual = canonical_job_digest(&assignment.job_spec)
        .context("canonicalize assigned job for digest validation")?;
    if actual != assignment.job_digest {
        bail!("assigned jobDigest does not match the immutable JobSpec");
    }
    Ok(())
}

fn cancellation_final_state(cancellation: &AtomicU8) -> JobState {
    match cancellation.load(Ordering::SeqCst) {
        CANCEL_REQUESTED | CANCEL_LEASE_LOST => JobState::Cancelled,
        _ => JobState::Failed,
    }
}

fn cancellation_termination_reason(cancellation: &AtomicU8) -> Option<TerminationReason> {
    match cancellation.load(Ordering::SeqCst) {
        CANCEL_REQUESTED => Some(TerminationReason::CancelRequested),
        CANCEL_LEASE_LOST => Some(TerminationReason::LeaseLost),
        CANCEL_TRANSPORT_FAILURE => Some(TerminationReason::TransportFailure),
        CANCEL_JOB_TIMEOUT => Some(TerminationReason::TimedOut),
        _ => None,
    }
}

fn source_failure_termination(
    source: &cyc_protocol::SourceSpec,
    containment: SourceContainment,
    cancellation: &AtomicU8,
    observed_at: DateTime<Utc>,
) -> Result<(JobState, TerminationEvidence)> {
    let SourceContainment::Confirmed(confirmed) = containment else {
        return Err(
            ContainmentProofLost::new("managed source process tree was not proven empty").into(),
        );
    };
    let process_reason = confirmed.reason.map(|reason| match reason {
        ProcessTerminationReason::TimedOut => TerminationReason::TimedOut,
        ProcessTerminationReason::CancelRequested => TerminationReason::CancelRequested,
        ProcessTerminationReason::LeaseLost => TerminationReason::LeaseLost,
        ProcessTerminationReason::TransportFailure => TerminationReason::TransportFailure,
        ProcessTerminationReason::Exited | ProcessTerminationReason::ExecutionFailed => {
            TerminationReason::SourcePreparationFailed
        }
    });
    let (final_state, reason) = match source {
        cyc_protocol::SourceSpec::Snapshot { .. } => {
            (JobState::Failed, TerminationReason::SourcePreparationFailed)
        }
        cyc_protocol::SourceSpec::Git { .. } => {
            let reason = cancellation_termination_reason(cancellation)
                .or(process_reason)
                .unwrap_or(TerminationReason::SourcePreparationFailed);
            let state = match reason {
                TerminationReason::CancelRequested | TerminationReason::LeaseLost => {
                    JobState::Cancelled
                }
                _ => JobState::Failed,
            };
            (state, reason)
        }
    };
    Ok((
        final_state,
        TerminationEvidence {
            reason,
            process_tree_terminated: true,
            forced_kill: confirmed.forced_kill,
            root_exit_code: confirmed.root_exit_code,
            signal: confirmed.signal,
            observed_at,
        },
    ))
}

/// Marker error for the one assignment failure that poisons the daemon.
///
/// Ordinary malformed assignments and controller failures remain isolated to
/// their run. Losing containment proof is different: the worker may still own
/// a live descendant, so claiming another run would invalidate both process
/// attribution and terminal evidence. The daemon must durably quarantine the
/// worker until an operator has inspected or rebooted the host and explicitly
/// clears the marker.
#[derive(Debug)]
struct ContainmentProofLost {
    detail: String,
}

impl ContainmentProofLost {
    fn new(detail: impl Into<String>) -> Self {
        Self {
            detail: detail.into(),
        }
    }
}

impl fmt::Display for ContainmentProofLost {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}", self.detail)
    }
}

impl std::error::Error for ContainmentProofLost {}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct ContainmentQuarantineRecord {
    api_version: String,
    node_id: uuid::Uuid,
    run_id: uuid::Uuid,
    observed_at: DateTime<Utc>,
    reason: String,
}

#[derive(Debug)]
struct GuardDurabilityLost {
    operation: &'static str,
    source: anyhow::Error,
}

impl GuardDurabilityLost {
    fn new(operation: &'static str, source: anyhow::Error) -> Self {
        Self { operation, source }
    }
}

impl fmt::Display for GuardDurabilityLost {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "active-run guard durability failed during {}: {:#}",
            self.operation, self.source
        )
    }
}

impl std::error::Error for GuardDurabilityLost {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(self.source.as_ref())
    }
}

#[derive(Debug)]
struct AssignmentQuarantined {
    marker: PathBuf,
    source: anyhow::Error,
}

impl fmt::Display for AssignmentQuarantined {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "assignment did not receive an authoritative terminal acknowledgement; active-run guard retained as containment quarantine at {}: {:#}",
            self.marker.display(),
            self.source
        )
    }
}

impl std::error::Error for AssignmentQuarantined {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(self.source.as_ref())
    }
}

#[derive(Debug)]
struct ActiveRunGuard {
    marker: PathBuf,
    node_id: uuid::Uuid,
    run_id: uuid::Uuid,
    #[cfg(test)]
    clear_fault: bool,
}

impl ActiveRunGuard {
    fn arm(config: &WorkerConfig, run_id: uuid::Uuid) -> Result<Self> {
        let marker = persist_active_run_guard(config, run_id)?;
        Ok(Self {
            marker,
            node_id: config.node_id,
            run_id,
            #[cfg(test)]
            clear_fault: false,
        })
    }

    #[cfg(test)]
    fn inject_clear_fault(&mut self) {
        self.clear_fault = true;
    }

    fn verify(&self) -> Result<()> {
        verify_active_run_guard(&self.marker, self.node_id, self.run_id)
    }

    fn clear(self) -> Result<()> {
        self.verify()?;
        #[cfg(test)]
        if self.clear_fault {
            bail!("injected active-run guard clear failure");
        }
        fs::remove_file(&self.marker)
            .with_context(|| format!("remove active-run guard {}", self.marker.display()))?;
        #[cfg(unix)]
        FileSync::sync_directory(
            self.marker
                .parent()
                .context("active-run guard must have a parent")?,
        )?;
        Ok(())
    }
}

async fn run_guarded_assignment<F>(config: &WorkerConfig, run_id: uuid::Uuid, work: F) -> Result<()>
where
    F: Future<Output = Result<()>>,
{
    run_guarded_assignment_inner(config, run_id, work, false).await
}

async fn run_guarded_assignment_inner<F>(
    config: &WorkerConfig,
    run_id: uuid::Uuid,
    work: F,
    #[cfg_attr(not(test), allow(unused_variables))] inject_clear_fault: bool,
) -> Result<()>
where
    F: Future<Output = Result<()>>,
{
    // Async futures are lazy: arming completes before `work` receives its
    // first poll, so prepare_job/git/step process creation is always guarded.
    let guard = ActiveRunGuard::arm(config, run_id)
        .map_err(|error| GuardDurabilityLost::new("establish", error))?;
    #[cfg(test)]
    let mut guard = guard;
    #[cfg(test)]
    if inject_clear_fault {
        guard.inject_clear_fault();
    }

    match work.await {
        Ok(()) => guard
            .clear()
            .map_err(|error| GuardDurabilityLost::new("clear", error).into()),
        Err(error) => {
            guard
                .verify()
                .map_err(|guard_error| GuardDurabilityLost::new("retain", guard_error))?;
            Err(AssignmentQuarantined {
                marker: guard.marker,
                source: error,
            }
            .into())
        }
    }
}

fn containment_quarantine_path(config: &WorkerConfig) -> PathBuf {
    config.workspace_root.join(CONTAINMENT_QUARANTINE_FILE)
}

fn path_entry_exists(path: &Path) -> Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error).with_context(|| format!("inspect path entry {}", path.display())),
    }
}

fn refuse_containment_quarantine(config: &WorkerConfig) -> Result<()> {
    let marker = containment_quarantine_path(config);
    ensure_no_windows_reparse_points(&marker)
        .context("validate containment quarantine path before claim")?;
    if path_entry_exists(&marker)? {
        bail!(
            "worker containment quarantine is active at {}; inspect the host and confirm no managed descendants remain (or reboot), then explicitly remove this marker before restarting",
            marker.display()
        );
    }
    Ok(())
}

fn persist_active_run_guard(config: &WorkerConfig, run_id: uuid::Uuid) -> Result<PathBuf> {
    let marker = containment_quarantine_path(config);
    ensure_no_windows_reparse_points(&marker)
        .context("validate active-run guard path before creation")?;
    if path_entry_exists(&marker)? {
        bail!(
            "active-run guard path already exists and is quarantined: {}",
            marker.display()
        );
    }
    let parent = marker
        .parent()
        .context("containment quarantine marker must have a parent")?;
    let metadata = fs::symlink_metadata(parent)
        .with_context(|| format!("inspect worker workspace {}", parent.display()))?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        bail!(
            "worker workspace is not a direct directory: {}",
            parent.display()
        );
    }

    let record = ContainmentQuarantineRecord {
        api_version: ACTIVE_RUN_GUARD_VERSION.to_owned(),
        node_id: config.node_id,
        run_id,
        observed_at: Utc::now(),
        reason: ACTIVE_RUN_GUARD_REASON.to_owned(),
    };
    let bytes = serde_json::to_vec_pretty(&record).context("serialize containment quarantine")?;
    let temporary = parent.join(format!(
        ".{CONTAINMENT_QUARANTINE_FILE}.{}.tmp",
        uuid::Uuid::new_v4()
    ));
    ensure_no_windows_reparse_points(&temporary)
        .context("validate active-run temporary path before creation")?;
    let write_result = (|| -> Result<()> {
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options
            .open(&temporary)
            .with_context(|| format!("create active-run temporary {}", temporary.display()))?;
        file.write_all(&bytes).context("write active-run guard")?;
        file.write_all(b"\n").context("finish active-run guard")?;
        file.sync_all().context("flush active-run guard")?;
        drop(file);
        ensure_no_windows_reparse_points(&temporary)
            .context("validate flushed active-run temporary path")?;

        // The target is never replaced. On Unix an atomic hard-link install
        // supplies create-new semantics; on Windows rename itself fails when
        // the destination exists. A second daemon therefore cannot adopt or
        // overwrite another run's guard.
        ensure_no_windows_reparse_points(&marker)
            .context("revalidate active-run guard destination before installation")?;
        if path_entry_exists(&marker)? {
            bail!(
                "active-run guard appeared concurrently at {}",
                marker.display()
            );
        }

        #[cfg(unix)]
        {
            fs::hard_link(&temporary, &marker).with_context(|| {
                format!(
                    "atomically install active-run guard {} -> {}",
                    temporary.display(),
                    marker.display()
                )
            })?;
            FileSync::sync_directory(parent)?;
            fs::remove_file(&temporary)
                .with_context(|| format!("remove active-run temporary {}", temporary.display()))?;
            FileSync::sync_directory(parent)?;
        }
        #[cfg(windows)]
        {
            atomic_install_active_run_guard_windows(&temporary, &marker)?;
        }
        #[cfg(not(any(unix, windows)))]
        compile_error!("active-run guard atomic installation is not implemented for this platform");
        Ok(())
    })();
    if write_result.is_err() && !path_entry_exists(&marker).unwrap_or(false) {
        let _ = fs::remove_file(&temporary);
    }
    write_result?;
    if !path_entry_exists(&marker)? {
        bail!("active-run guard did not persist at {}", marker.display());
    }
    verify_active_run_guard(&marker, config.node_id, run_id)?;
    Ok(marker)
}

fn verify_active_run_guard(
    marker: &Path,
    expected_node_id: uuid::Uuid,
    expected_run_id: uuid::Uuid,
) -> Result<()> {
    ensure_no_windows_reparse_points(marker).context("validate active-run guard path")?;
    let metadata = fs::symlink_metadata(marker)
        .with_context(|| format!("inspect active-run guard {}", marker.display()))?;
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        bail!(
            "active-run guard is not a direct regular file: {}",
            marker.display()
        );
    }
    let record: ContainmentQuarantineRecord = serde_json::from_slice(
        &fs::read(marker).with_context(|| format!("read active-run guard {}", marker.display()))?,
    )
    .with_context(|| format!("parse active-run guard {}", marker.display()))?;
    if record.api_version != ACTIVE_RUN_GUARD_VERSION
        || record.node_id != expected_node_id
        || record.run_id != expected_run_id
        || record.reason != ACTIVE_RUN_GUARD_REASON
    {
        bail!(
            "active-run guard identity or version mismatch at {}",
            marker.display()
        );
    }
    Ok(())
}

#[cfg(unix)]
struct FileSync;

#[cfg(unix)]
impl FileSync {
    fn sync_directory(path: &Path) -> Result<()> {
        fs::File::open(path)
            .with_context(|| format!("open quarantine parent {}", path.display()))?
            .sync_all()
            .with_context(|| format!("flush quarantine parent {}", path.display()))
    }
}

#[cfg(windows)]
fn atomic_install_active_run_guard_windows(source: &Path, destination: &Path) -> Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{MoveFileExW, MOVEFILE_WRITE_THROUGH};

    let source_wide = source
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    let destination_wide = destination
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    // Omitting MOVEFILE_REPLACE_EXISTING gives atomic create-new semantics;
    // WRITE_THROUGH does not return until the move is flushed to disk.
    let moved = unsafe {
        MoveFileExW(
            source_wide.as_ptr(),
            destination_wide.as_ptr(),
            MOVEFILE_WRITE_THROUGH,
        )
    };
    if moved == 0 {
        return Err(std::io::Error::last_os_error()).with_context(|| {
            format!(
                "atomically install and flush active-run guard {} -> {}",
                source.display(),
                destination.display()
            )
        });
    }
    Ok(())
}

async fn handle_guarded_assignment_error(error: anyhow::Error) -> Result<()> {
    if error.downcast_ref::<GuardDurabilityLost>().is_some() {
        // Exiting here could let a restart-on-failure supervisor relaunch a
        // worker whose guard update was not durable. Stay alive but never poll
        // or claim again; an operator must stop and repair the service.
        eprintln!(
            "fatal active-run guard durability failure; worker is permanently parked and will not claim again: {error:#}"
        );
        loop {
            tokio::time::sleep(Duration::from_secs(3600)).await;
        }
    }

    // Every post-claim error keeps the already durable guard. This includes
    // execution, transition, lease, transport, and completion-ack ambiguity.
    // Exiting is safe because any supervisor restart refuses the marker before
    // another claim.
    Err(error)
}

fn fatal_controller_error(error: &anyhow::Error) -> bool {
    let text = format!("{error:#}");
    text.contains("HTTP 401")
        || text.contains("HTTP 403")
        || text.contains("certificate")
        || text.contains("worker config")
}

fn absolute_path(path: &Path) -> Result<PathBuf> {
    if path.is_absolute() {
        Ok(path.to_owned())
    } else {
        Ok(std::env::current_dir()?.join(path))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cyc_protocol::worker::{ExecutionLimits, WorkspaceAssignment};
    use cyc_protocol::{JobKind, JobSpec, JobStep, SourceSpec};
    use tempfile::tempdir;
    use uuid::Uuid;

    fn worker_config(directory: &tempfile::TempDir) -> WorkerConfig {
        let workspace = directory.path().join("workspace");
        fs::create_dir(&workspace).unwrap();
        WorkerConfig {
            api_version: WORKER_CONFIG_VERSION.to_owned(),
            worker_url: "https://controller.example.invalid/worker".to_owned(),
            certificate_pem: "test-certificate".to_owned(),
            controller_id: Uuid::new_v4(),
            node_id: Uuid::new_v4(),
            worker_api_version: "cyc.dev/worker-api/v1".to_owned(),
            heartbeat_interval_seconds: 5,
            lease_seconds: 30,
            workspace_root: workspace,
            credential_file: directory.path().join("worker.credential"),
        }
    }

    #[cfg(unix)]
    fn make_directory_weak(path: &Path) {
        use std::os::unix::fs::PermissionsExt;

        fs::set_permissions(path, fs::Permissions::from_mode(0o777)).unwrap();
    }

    #[cfg(windows)]
    fn make_directory_weak(path: &Path) {
        let status = std::process::Command::new("icacls.exe")
            .arg(path)
            .args(["/grant", "*S-1-1-0:(OI)(CI)(R)"])
            .status()
            .unwrap();
        assert!(status.success());
    }

    #[cfg(windows)]
    fn create_directory_junction(junction: &Path, target: &Path) {
        let output = std::process::Command::new("powershell.exe")
            .args([
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-Command",
                "$ErrorActionPreference = 'Stop'; New-Item -ItemType Junction -Path $env:CYC_TEST_JUNCTION -Target $env:CYC_TEST_TARGET | Out-Null",
            ])
            .env("CYC_TEST_JUNCTION", junction)
            .env("CYC_TEST_TARGET", target)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "failed to create test junction: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    #[test]
    fn digest_binds_exact_job_spec() {
        let job = JobSpec::new(
            JobKind::Build,
            SourceSpec::Git {
                repository: "https://example.invalid/repo.git".into(),
                revision: "a".repeat(40),
            },
            vec![JobStep::new("build", "cargo build")],
        );
        let digest = canonical_job_digest(&job).unwrap();
        let mut assignment = ClaimAssignment {
            job_id: job.id,
            run_id: Uuid::new_v4(),
            job_digest: digest,
            lease_id: Uuid::new_v4(),
            lease_until: Utc::now() + chrono::Duration::minutes(1),
            state_version: 1,
            job_spec: job,
            workspace: WorkspaceAssignment {
                relative_root: format!("jobs/{}", Uuid::new_v4()),
                source_directory: "repo".into(),
                logs_directory: "logs".into(),
                artifacts_directory: "artifacts".into(),
            },
            limits: ExecutionLimits::default(),
        };
        validate_job_digest(&assignment).unwrap();
        assignment.job_spec.steps[0].script.push_str(" --release");
        assert!(validate_job_digest(&assignment).is_err());
    }

    #[test]
    fn snapshot_failure_evidence_binds_the_exact_digest() {
        let digest = format!("sha256:{}", "b".repeat(64));
        let job = JobSpec::new(
            JobKind::Build,
            SourceSpec::Snapshot {
                digest: digest.clone(),
                size_bytes: Some(128),
            },
            vec![JobStep::new("build", "cargo build")],
        );
        let assignment = ClaimAssignment {
            job_id: job.id,
            run_id: Uuid::new_v4(),
            job_digest: canonical_job_digest(&job).unwrap(),
            lease_id: Uuid::new_v4(),
            lease_until: Utc::now() + chrono::Duration::minutes(1),
            state_version: 1,
            job_spec: job,
            workspace: WorkspaceAssignment {
                relative_root: format!("jobs/{}", Uuid::new_v4()),
                source_directory: "repo".into(),
                logs_directory: "logs".into(),
                artifacts_directory: "artifacts".into(),
            },
            limits: ExecutionLimits::default(),
        };
        let evidence = assigned_source_evidence(&assignment);
        evidence.validate().unwrap();
        assert_eq!(evidence.kind, "snapshot");
        assert_eq!(evidence.requested_revision, digest);
    }

    #[test]
    fn transport_and_timeout_are_failures_not_user_cancellations() {
        let cancellation = AtomicU8::new(CANCEL_TRANSPORT_FAILURE);
        assert_eq!(cancellation_final_state(&cancellation), JobState::Failed);
        cancellation.store(CANCEL_JOB_TIMEOUT, Ordering::SeqCst);
        assert_eq!(cancellation_final_state(&cancellation), JobState::Failed);
        cancellation.store(CANCEL_REQUESTED, Ordering::SeqCst);
        assert_eq!(cancellation_final_state(&cancellation), JobState::Cancelled);
    }

    #[test]
    fn unconfirmed_source_containment_refuses_terminal_evidence() {
        let source = SourceSpec::Git {
            repository: "https://example.invalid/repo.git".into(),
            revision: "a".repeat(40),
        };
        let cancellation = AtomicU8::new(CANCEL_NONE);
        let error = source_failure_termination(
            &source,
            SourceContainment::Unconfirmed,
            &cancellation,
            Utc::now(),
        )
        .unwrap_err();
        assert!(error
            .to_string()
            .contains("process tree was not proven empty"));
        let contextualized = error.context("assignment execution failed");
        assert!(contextualized
            .downcast_ref::<ContainmentProofLost>()
            .is_some());
        assert!(anyhow::anyhow!("ordinary malformed assignment")
            .downcast_ref::<ContainmentProofLost>()
            .is_none());
    }

    #[test]
    fn git_source_exit_failure_builds_protocol_valid_completion() {
        let source = SourceSpec::Git {
            repository: "https://example.invalid/repo.git".into(),
            // Models the syntactically valid but nonexistent OID used by the
            // real TLS regression scenario.
            revision: "f".repeat(40),
        };
        let job = JobSpec::new(JobKind::Build, source.clone(), Vec::new());
        let assignment = ClaimAssignment {
            job_id: job.id,
            run_id: Uuid::new_v4(),
            job_digest: canonical_job_digest(&job).unwrap(),
            lease_id: Uuid::new_v4(),
            lease_until: Utc::now() + chrono::Duration::minutes(1),
            state_version: 1,
            job_spec: job,
            workspace: WorkspaceAssignment {
                relative_root: format!("jobs/{}", Uuid::new_v4()),
                source_directory: "repo".into(),
                logs_directory: "logs".into(),
                artifacts_directory: "artifacts".into(),
            },
            limits: ExecutionLimits::default(),
        };
        let finished_at = Utc::now();
        let cancellation = AtomicU8::new(CANCEL_NONE);
        let (final_state, termination) = source_failure_termination(
            &source,
            SourceContainment::Confirmed(crate::source::ConfirmedSourceTermination {
                reason: Some(ProcessTerminationReason::Exited),
                forced_kill: false,
                root_exit_code: Some(128),
                signal: None,
            }),
            &cancellation,
            finished_at,
        )
        .unwrap();
        let empty_stream = cyc_protocol::worker::StreamEvidence {
            byte_count: 0,
            sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855".into(),
            truncated: false,
            chunk_count: 0,
        };
        let execution = ExecutionEvidence {
            source: assigned_source_evidence(&assignment),
            steps: Vec::new(),
            streams: RunStreamsEvidence {
                stdout: empty_stream.clone(),
                stderr: empty_stream,
            },
            termination,
        };

        let completion = early_failure_completion(
            &assignment,
            assignment.state_version,
            final_state,
            "source preparation failed: protected Git checkout failed".into(),
            finished_at,
            execution,
        );

        assert_eq!(completion.final_state, JobState::Failed);
        assert_eq!(completion.evidence.exit_code, Some(128));
        assert_eq!(completion.execution.termination.root_exit_code, Some(128));
        completion.validate().unwrap();
    }

    #[test]
    fn source_failures_without_a_root_exit_keep_both_exit_codes_absent() {
        let digest = format!("sha256:{}", "b".repeat(64));
        let source = SourceSpec::Snapshot {
            digest,
            size_bytes: Some(128),
        };
        let job = JobSpec::new(JobKind::Build, source.clone(), Vec::new());
        let assignment = ClaimAssignment {
            job_id: job.id,
            run_id: Uuid::new_v4(),
            job_digest: canonical_job_digest(&job).unwrap(),
            lease_id: Uuid::new_v4(),
            lease_until: Utc::now() + chrono::Duration::minutes(1),
            state_version: 1,
            job_spec: job,
            workspace: WorkspaceAssignment {
                relative_root: format!("jobs/{}", Uuid::new_v4()),
                source_directory: "repo".into(),
                logs_directory: "logs".into(),
                artifacts_directory: "artifacts".into(),
            },
            limits: ExecutionLimits::default(),
        };
        let finished_at = Utc::now();
        let (final_state, termination) = source_failure_termination(
            &source,
            SourceContainment::Confirmed(crate::source::ConfirmedSourceTermination {
                reason: None,
                forced_kill: false,
                root_exit_code: None,
                signal: None,
            }),
            &AtomicU8::new(CANCEL_NONE),
            finished_at,
        )
        .unwrap();
        let empty_stream = cyc_protocol::worker::StreamEvidence {
            byte_count: 0,
            sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855".into(),
            truncated: false,
            chunk_count: 0,
        };
        let completion = early_failure_completion(
            &assignment,
            assignment.state_version,
            final_state,
            "source preparation failed before a root process was spawned".into(),
            finished_at,
            ExecutionEvidence {
                source: assigned_source_evidence(&assignment),
                steps: Vec::new(),
                streams: RunStreamsEvidence {
                    stdout: empty_stream.clone(),
                    stderr: empty_stream,
                },
                termination,
            },
        );

        assert_eq!(completion.evidence.exit_code, None);
        assert_eq!(completion.execution.termination.root_exit_code, None);
        completion.validate().unwrap();
    }

    #[test]
    fn cancelled_and_timed_out_source_failures_preserve_exit_code_invariant() {
        let source = SourceSpec::Git {
            repository: "https://example.invalid/repo.git".into(),
            revision: "f".repeat(40),
        };
        let job = JobSpec::new(JobKind::Build, source.clone(), Vec::new());
        let assignment = ClaimAssignment {
            job_id: job.id,
            run_id: Uuid::new_v4(),
            job_digest: canonical_job_digest(&job).unwrap(),
            lease_id: Uuid::new_v4(),
            lease_until: Utc::now() + chrono::Duration::minutes(1),
            state_version: 1,
            job_spec: job,
            workspace: WorkspaceAssignment {
                relative_root: format!("jobs/{}", Uuid::new_v4()),
                source_directory: "repo".into(),
                logs_directory: "logs".into(),
                artifacts_directory: "artifacts".into(),
            },
            limits: ExecutionLimits::default(),
        };

        for (cancellation_code, process_reason, root_exit_code, expected_state) in [
            (
                CANCEL_REQUESTED,
                ProcessTerminationReason::CancelRequested,
                Some(130),
                JobState::Cancelled,
            ),
            (
                CANCEL_JOB_TIMEOUT,
                ProcessTerminationReason::TimedOut,
                None,
                JobState::Failed,
            ),
        ] {
            let finished_at = Utc::now();
            let (final_state, termination) = source_failure_termination(
                &source,
                SourceContainment::Confirmed(crate::source::ConfirmedSourceTermination {
                    reason: Some(process_reason),
                    forced_kill: true,
                    root_exit_code,
                    signal: None,
                }),
                &AtomicU8::new(cancellation_code),
                finished_at,
            )
            .unwrap();
            let empty_stream = cyc_protocol::worker::StreamEvidence {
                byte_count: 0,
                sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855".into(),
                truncated: false,
                chunk_count: 0,
            };
            let completion = early_failure_completion(
                &assignment,
                assignment.state_version,
                final_state,
                "source preparation was interrupted".into(),
                finished_at,
                ExecutionEvidence {
                    source: assigned_source_evidence(&assignment),
                    steps: Vec::new(),
                    streams: RunStreamsEvidence {
                        stdout: empty_stream.clone(),
                        stderr: empty_stream,
                    },
                    termination,
                },
            );

            assert_eq!(completion.final_state, expected_state);
            assert_eq!(completion.evidence.exit_code, root_exit_code);
            assert_eq!(
                completion.execution.termination.root_exit_code,
                root_exit_code
            );
            completion.validate().unwrap();
        }
    }

    #[test]
    fn durable_quarantine_blocks_restart_until_explicit_repair() {
        let directory = tempdir().unwrap();
        let config = worker_config(&directory);
        refuse_containment_quarantine(&config).unwrap();

        let run_id = Uuid::new_v4();
        let marker = persist_active_run_guard(&config, run_id).unwrap();
        let value: serde_json::Value = serde_json::from_slice(&fs::read(&marker).unwrap()).unwrap();
        assert_eq!(value["apiVersion"], ACTIVE_RUN_GUARD_VERSION);
        assert_eq!(value["reason"], ACTIVE_RUN_GUARD_REASON);
        assert_eq!(value["runId"], run_id.to_string());

        // A freshly constructed config models a supervisor restart. Mere
        // process exit/relaunch must not clear the durable poison state.
        let restarted = config.clone();
        let error = refuse_containment_quarantine(&restarted).unwrap_err();
        assert!(error.to_string().contains("quarantine is active"));

        fs::remove_file(&marker).unwrap();
        #[cfg(unix)]
        FileSync::sync_directory(&config.workspace_root).unwrap();
        refuse_containment_quarantine(&restarted).unwrap();
    }

    #[test]
    fn pairing_rejects_an_existing_weak_config_parent_without_repair() {
        let directory = tempdir().unwrap();
        let parent = directory.path().join("worker-state");
        fs::create_dir(&parent).unwrap();
        make_directory_weak(&parent);
        let config_path = parent.join("worker.json");

        let error = prepare_pairing_layout(&config_path).unwrap_err();
        assert!(format!("{error:#}").contains("private directory"));
        assert!(ensure_protected_directory(&parent).is_err());
    }

    #[test]
    fn pairing_rejects_a_prepositioned_weak_workspace_without_repair() {
        let directory = tempdir().unwrap();
        let parent = directory.path().join("worker-state");
        prepare_private_directory(&parent).unwrap();
        let workspace = parent.join("workspace");
        fs::create_dir(&workspace).unwrap();
        make_directory_weak(&workspace);

        let error = prepare_pairing_layout(&parent.join("worker.json")).unwrap_err();
        assert!(format!("{error:#}").contains("worker workspace"));
        ensure_protected_directory(&parent).unwrap();
        assert!(ensure_protected_directory(&workspace).is_err());
    }

    #[tokio::test]
    async fn status_and_run_reject_a_workspace_that_became_weak() {
        let directory = tempdir().unwrap();
        let parent = directory.path().join("worker-state");
        let workspace = parent.join("workspace");
        prepare_private_directory(&parent).unwrap();
        prepare_private_directory(&workspace).unwrap();
        let credential = parent.join("worker.credential");
        write_secret_file(&credential, "opaque-worker-credential").unwrap();
        let config_path = parent.join("worker.json");
        let config = WorkerConfig {
            api_version: WORKER_CONFIG_VERSION.to_owned(),
            worker_url: "https://controller.example.invalid/worker".to_owned(),
            certificate_pem: "test-certificate".to_owned(),
            controller_id: Uuid::new_v4(),
            node_id: Uuid::new_v4(),
            worker_api_version: "cyc.dev/worker-api/v1".to_owned(),
            heartbeat_interval_seconds: 5,
            lease_seconds: 30,
            workspace_root: workspace.clone(),
            credential_file: credential,
        };
        config.write(&config_path).unwrap();
        make_directory_weak(&workspace);

        let status_error = status(&config_path).err().unwrap();
        assert!(format!("{status_error:#}").contains("workspace"));
        assert!(
            format!("{:#}", run_forever(&config_path).await.unwrap_err()).contains("workspace")
        );
        assert!(ensure_protected_directory(&workspace).is_err());
    }

    #[cfg(windows)]
    #[test]
    fn pairing_rejects_a_prepositioned_workspace_junction() {
        let directory = tempdir().unwrap();
        let parent = directory.path().join("worker-state");
        let backing = directory.path().join("backing");
        prepare_private_directory(&parent).unwrap();
        prepare_private_directory(&backing).unwrap();
        let workspace = parent.join("workspace");
        create_directory_junction(&workspace, &backing);

        let error = prepare_pairing_layout(&parent.join("worker.json")).unwrap_err();
        assert!(format!("{error:#}").contains("reparse"));
        assert!(!path_entry_exists(&parent.join("worker.json")).unwrap());

        fs::remove_dir(&workspace).unwrap();
    }

    #[cfg(windows)]
    #[test]
    fn guard_rejects_a_junction_anywhere_in_its_existing_path_chain() {
        let directory = tempdir().unwrap();
        let mut config = worker_config(&directory);
        fs::remove_dir(&config.workspace_root).unwrap();

        let backing = directory.path().join("backing");
        let backing_workspace = backing.join("workspace");
        let junction = directory.path().join("junction");
        fs::create_dir_all(&backing_workspace).unwrap();
        create_directory_junction(&junction, &backing);
        config.workspace_root = junction.join("workspace");

        // The workspace itself resolves as an ordinary directory. The guard
        // must still walk upward and reject the junction above it before a
        // claim or temporary/marker creation can occur.
        let claim_error = refuse_containment_quarantine(&config).unwrap_err();
        assert!(format!("{claim_error:#}").contains("reparse point"));
        let arm_error = ActiveRunGuard::arm(&config, Uuid::new_v4()).unwrap_err();
        assert!(format!("{arm_error:#}").contains("reparse point"));
        assert!(!path_entry_exists(&containment_quarantine_path(&config)).unwrap());

        fs::remove_dir(&junction).unwrap();
    }

    #[tokio::test]
    async fn guard_is_durable_before_work_can_spawn_and_clears_after_ack() {
        let directory = tempdir().unwrap();
        let config = worker_config(&directory);
        let run_id = Uuid::new_v4();
        let marker = containment_quarantine_path(&config);

        run_guarded_assignment(&config, run_id, async {
            // This block models the first source/job spawn. It cannot receive
            // a poll until run_guarded_assignment has durably armed the file.
            assert!(path_entry_exists(&marker).unwrap());
            verify_active_run_guard(&marker, config.node_id, run_id).unwrap();

            // The Linux containment tests enable a process-wide subreaper and
            // intentionally inspect/terminate newly adopted children. Keep
            // this deliberately uncontained probe mutually exclusive with
            // those tests so a concurrent managed tree cannot claim it.
            let _child_process_guard = crate::process::test_exclusive_child_process_guard().await;

            #[cfg(unix)]
            let status = std::process::Command::new("sh")
                .args(["-c", "test -f \"$1\"", "guard-check"])
                .arg(&marker)
                .status()
                .unwrap();
            #[cfg(windows)]
            let status = std::process::Command::new("cmd.exe")
                .args(["/D", "/C", "exit /b 0"])
                .status()
                .unwrap();
            assert!(status.success(), "guarded work did not spawn successfully");

            // Production reaches Ok only after source/step containment is
            // ConfirmedEmpty and submit_completion returns a matching terminal
            // controller acknowledgement.
            Ok(())
        })
        .await
        .unwrap();

        assert!(!path_entry_exists(&marker).unwrap());
    }

    #[tokio::test]
    async fn post_claim_error_retains_guard_and_blocks_restart() {
        let directory = tempdir().unwrap();
        let config = worker_config(&directory);
        let run_id = Uuid::new_v4();
        let marker = containment_quarantine_path(&config);

        let error = run_guarded_assignment(&config, run_id, async {
            Err(anyhow::anyhow!(
                "controller terminal acknowledgement was lost"
            ))
        })
        .await
        .unwrap_err();
        assert!(error.downcast_ref::<AssignmentQuarantined>().is_some());
        verify_active_run_guard(&marker, config.node_id, run_id).unwrap();

        let restarted = config.clone();
        assert!(refuse_containment_quarantine(&restarted).is_err());
    }

    #[tokio::test]
    async fn guard_clear_fault_parks_instead_of_returning_to_supervisor() {
        let directory = tempdir().unwrap();
        let config = worker_config(&directory);
        let run_id = Uuid::new_v4();
        let marker = containment_quarantine_path(&config);

        let error = run_guarded_assignment_inner(&config, run_id, async { Ok(()) }, true)
            .await
            .unwrap_err();
        assert!(error.downcast_ref::<GuardDurabilityLost>().is_some());
        assert!(path_entry_exists(&marker).unwrap());

        let parked = tokio::time::timeout(
            Duration::from_millis(25),
            handle_guarded_assignment_error(error),
        )
        .await;
        assert!(
            parked.is_err(),
            "guard durability failure returned instead of parking"
        );
        assert!(path_entry_exists(&marker).unwrap());
    }

    #[test]
    fn malformed_or_non_file_marker_is_fail_closed() {
        let directory = tempdir().unwrap();
        let config = worker_config(&directory);
        let marker = containment_quarantine_path(&config);
        fs::write(&marker, b"{truncated").unwrap();

        assert!(refuse_containment_quarantine(&config).is_err());
        assert!(ActiveRunGuard::arm(&config, Uuid::new_v4()).is_err());
    }
}
