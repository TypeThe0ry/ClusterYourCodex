use std::ffi::OsString;
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicU8;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use cyc_protocol::worker::WorkspaceAssignment;
use cyc_protocol::{JobSpec, SourceSpec};
use reqwest::Url;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::process::{
    os, run_process, LogBudget, LogSink, ProcessContainment, ProcessRequest, ProcessRunError,
    ProcessTerminationReason,
};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceEvidence {
    pub kind: String,
    pub repository: String,
    pub requested_revision: String,
    pub resolved_revision: String,
    pub tree: String,
    pub git_version: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ConfirmedSourceTermination {
    pub reason: Option<ProcessTerminationReason>,
    pub forced_kill: bool,
    pub root_exit_code: Option<i32>,
    pub signal: Option<i32>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SourceContainment {
    Confirmed(ConfirmedSourceTermination),
    Unconfirmed,
}

#[derive(Debug)]
pub struct PrepareJobError {
    error: anyhow::Error,
    containment: SourceContainment,
}

impl PrepareJobError {
    fn confirmed_empty(error: anyhow::Error) -> Self {
        Self {
            error,
            containment: SourceContainment::Confirmed(ConfirmedSourceTermination {
                reason: None,
                forced_kill: false,
                root_exit_code: None,
                signal: None,
            }),
        }
    }

    fn from_process_error(error: ProcessRunError) -> Self {
        let containment = match error.containment() {
            ProcessContainment::ConfirmedEmpty => {
                SourceContainment::Confirmed(ConfirmedSourceTermination {
                    reason: None,
                    forced_kill: false,
                    root_exit_code: None,
                    signal: None,
                })
            }
            ProcessContainment::Unconfirmed => SourceContainment::Unconfirmed,
        };
        Self {
            error: error.into_inner(),
            containment,
        }
    }

    fn from_process_result(label: &str, result: crate::process::ProcessResult) -> Self {
        let detail = result.error.as_deref().unwrap_or("no additional detail");
        let error = anyhow::anyhow!(
            "protected Git {label} failed: exit={:?}, reason={:?}, detail={detail}",
            result.exit_code,
            result.reason
        );
        let containment = if result.process_tree_terminated {
            SourceContainment::Confirmed(ConfirmedSourceTermination {
                reason: Some(result.reason),
                forced_kill: result.forced_kill,
                root_exit_code: result.exit_code,
                signal: result.signal,
            })
        } else {
            SourceContainment::Unconfirmed
        };
        Self { error, containment }
    }

    pub fn containment(&self) -> SourceContainment {
        self.containment
    }

    fn append_context(mut self, context: impl fmt::Display) -> Self {
        self.error = self.error.context(context.to_string());
        self
    }
}

impl From<anyhow::Error> for PrepareJobError {
    fn from(error: anyhow::Error) -> Self {
        Self::confirmed_empty(error)
    }
}

impl fmt::Display for PrepareJobError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}", self.error)
    }
}

impl std::error::Error for PrepareJobError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(self.error.as_ref())
    }
}

#[derive(Clone, Debug)]
pub struct PreparedJob {
    pub job_id: Uuid,
    pub run_id: Uuid,
    pub root: PathBuf,
    pub repository: PathBuf,
    pub scripts: PathBuf,
    pub logs: PathBuf,
    pub artifacts: PathBuf,
    pub source: SourceEvidence,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct JobManifest<'a> {
    api_version: &'static str,
    job_id: Uuid,
    run_id: Uuid,
    source: &'a SourceEvidence,
}

#[allow(clippy::too_many_arguments)]
pub async fn prepare_job(
    workspace_root: &Path,
    job_id: Uuid,
    run_id: Uuid,
    spec: &JobSpec,
    workspace: &WorkspaceAssignment,
    cancellation: Arc<AtomicU8>,
    sink: Arc<dyn LogSink>,
    log_budget: Arc<LogBudget>,
) -> std::result::Result<PreparedJob, PrepareJobError> {
    spec.validate().context("validate assigned JobSpec")?;
    workspace
        .validate()
        .context("validate assigned workspace")?;
    fs::create_dir_all(workspace_root)
        .with_context(|| format!("create worker workspace {}", workspace_root.display()))?;
    let canonical_workspace = fs::canonicalize(workspace_root)
        .with_context(|| format!("canonicalize worker workspace {}", workspace_root.display()))?;
    let root = join_portable(&canonical_workspace, &workspace.relative_root);
    let root_parent = root.parent().context("job root must have a parent")?;
    fs::create_dir_all(root_parent).context("create worker jobs directory")?;
    let canonical_parent = fs::canonicalize(root_parent).context("canonicalize jobs directory")?;
    if !canonical_parent.starts_with(&canonical_workspace) {
        return Err(anyhow::anyhow!("assigned job parent escaped the configured workspace").into());
    }
    fs::create_dir(&root).with_context(|| {
        format!(
            "create fresh job-owned directory {}; an existing directory is never reused",
            root.display()
        )
    })?;
    let canonical_root = fs::canonicalize(&root).context("canonicalize job-owned directory")?;
    if !canonical_root.starts_with(&canonical_workspace) {
        return Err(anyhow::anyhow!("job-owned directory escaped the configured workspace").into());
    }

    let repository = join_portable(&canonical_root, &workspace.source_directory);
    let scripts = canonical_root.join("scripts");
    let logs = join_portable(&canonical_root, &workspace.logs_directory);
    let artifacts = join_portable(&canonical_root, &workspace.artifacts_directory);
    if repository == logs || repository == artifacts || logs == artifacts {
        return Err(anyhow::anyhow!(
            "assigned source, logs, and artifact directories must be distinct"
        )
        .into());
    }
    for directory in [&repository, &scripts, &logs, &artifacts] {
        fs::create_dir_all(directory)
            .with_context(|| format!("create job directory {}", directory.display()))?;
        let canonical = fs::canonicalize(directory)
            .with_context(|| format!("canonicalize job directory {}", directory.display()))?;
        if !canonical.starts_with(&canonical_root) {
            return Err(
                anyhow::anyhow!("assigned job directory escaped the job-owned root").into(),
            );
        }
    }

    let source_result = match &spec.source {
        SourceSpec::Git {
            repository: remote,
            revision,
        } => {
            checkout_git(
                remote,
                revision,
                &repository,
                &logs,
                cancellation,
                sink,
                log_budget,
                false,
            )
            .await
        }
        SourceSpec::Snapshot { digest, .. } => Err(PrepareJobError::confirmed_empty(
            anyhow::anyhow!(
                "snapshot source `{digest}` is not supported by this worker version; no command was executed"
            ),
        )),
    };
    let source = match source_result {
        Ok(source) => source,
        Err(mut error) => {
            if let Err(write_error) = write_failure_result(&canonical_root, job_id, run_id, &error)
            {
                error = error.append_context(format!(
                    "also failed to persist local preparation evidence: {write_error:#}"
                ));
            }
            return Err(error);
        }
    };

    let manifest = JobManifest {
        api_version: "cyc.dev/worker-manifest/v1",
        job_id,
        run_id,
        source: &source,
    };
    write_json_atomic(&canonical_root.join("manifest.json"), &manifest)?;
    Ok(PreparedJob {
        job_id,
        run_id,
        root: canonical_root,
        repository,
        scripts,
        logs,
        artifacts,
        source,
    })
}

fn join_portable(root: &Path, relative: &str) -> PathBuf {
    relative
        .split('/')
        .filter(|segment| !segment.is_empty())
        .fold(root.to_owned(), |path, segment| path.join(segment))
}

#[allow(clippy::too_many_arguments)]
async fn checkout_git(
    remote: &str,
    revision: &str,
    repository: &Path,
    logs: &Path,
    cancellation: Arc<AtomicU8>,
    sink: Arc<dyn LogSink>,
    log_budget: Arc<LogBudget>,
    allow_local_fixture: bool,
) -> std::result::Result<SourceEvidence, PrepareJobError> {
    validate_full_oid(revision)?;
    validate_repository(remote, allow_local_fixture)?;
    let external_remote = if allow_local_fixture {
        let canonical_remote = fs::canonicalize(remote)
            .with_context(|| format!("canonicalize local Git fixture {remote}"))?;
        external_tool_path(&canonical_remote)?.into_os_string()
    } else {
        os(remote)
    };
    let empty_hooks = repository
        .parent()
        .context("repository must have a parent")?
        .join("empty-hooks");
    fs::create_dir(&empty_hooks).context("create empty Git hooks directory")?;
    let isolated_home = repository
        .parent()
        .context("repository must have a parent")?
        .join("git-home");
    fs::create_dir(&isolated_home).context("create isolated Git home")?;
    fs::write(isolated_home.join(".gitconfig"), b"").context("create empty global Git config")?;

    run_git(
        repository,
        logs,
        "version",
        &[os("--version")],
        &empty_hooks,
        cancellation.clone(),
        sink.clone(),
        log_budget.clone(),
        allow_local_fixture,
    )
    .await?;
    let git_version = read_single_line(&logs.join("git-version.stdout.log"))?;

    run_git(
        repository,
        logs,
        "init",
        &[os("init"), os("--quiet"), os(".")],
        &empty_hooks,
        cancellation.clone(),
        sink.clone(),
        log_budget.clone(),
        allow_local_fixture,
    )
    .await?;
    run_git(
        repository,
        logs,
        "remote",
        &[os("remote"), os("add"), os("origin"), external_remote],
        &empty_hooks,
        cancellation.clone(),
        sink.clone(),
        log_budget.clone(),
        allow_local_fixture,
    )
    .await?;
    run_git(
        repository,
        logs,
        "fetch",
        &[
            os("fetch"),
            os("--quiet"),
            os("--no-tags"),
            os("--depth=1"),
            os("origin"),
            os(revision),
        ],
        &empty_hooks,
        cancellation.clone(),
        sink.clone(),
        log_budget.clone(),
        allow_local_fixture,
    )
    .await?;
    run_git(
        repository,
        logs,
        "checkout",
        &[
            os("checkout"),
            os("--quiet"),
            os("--detach"),
            os("FETCH_HEAD"),
        ],
        &empty_hooks,
        cancellation.clone(),
        sink.clone(),
        log_budget.clone(),
        allow_local_fixture,
    )
    .await?;
    run_git(
        repository,
        logs,
        "head",
        &[os("rev-parse"), os("HEAD")],
        &empty_hooks,
        cancellation.clone(),
        sink.clone(),
        log_budget.clone(),
        allow_local_fixture,
    )
    .await?;
    let resolved = read_single_line(&logs.join("git-head.stdout.log"))?;
    if resolved != revision {
        return Err(anyhow::anyhow!(
            "Git HEAD mismatch: requested {revision}, resolved {resolved}"
        )
        .into());
    }
    run_git(
        repository,
        logs,
        "tree",
        &[os("rev-parse"), os("HEAD^{tree}")],
        &empty_hooks,
        cancellation,
        sink,
        log_budget,
        allow_local_fixture,
    )
    .await?;
    let tree = read_single_line(&logs.join("git-tree.stdout.log"))?;
    validate_full_oid(&tree).context("validate resolved Git tree OID")?;

    Ok(SourceEvidence {
        kind: "git".to_owned(),
        repository: remote.to_owned(),
        requested_revision: revision.to_ascii_lowercase(),
        resolved_revision: resolved.to_ascii_lowercase(),
        tree: tree.to_ascii_lowercase(),
        git_version,
    })
}

fn validate_repository(remote: &str, allow_local_fixture: bool) -> Result<()> {
    if allow_local_fixture {
        return Ok(());
    }
    let url = Url::parse(remote).context("Git repository must be an absolute HTTPS URL")?;
    if url.scheme() != "https"
        || url.host_str().is_none()
        || url.username() != ""
        || url.password().is_some()
        || url.fragment().is_some()
    {
        bail!("Git repository must be HTTPS and contain no embedded credentials or fragment");
    }
    Ok(())
}

fn validate_full_oid(revision: &str) -> Result<()> {
    if !matches!(revision.len(), 40 | 64)
        || !revision
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        bail!("Git revision must be an exact full 40- or 64-hex object ID");
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn run_git(
    repository: &Path,
    logs: &Path,
    label: &str,
    arguments: &[OsString],
    empty_hooks: &Path,
    cancellation: Arc<AtomicU8>,
    sink: Arc<dyn LogSink>,
    log_budget: Arc<LogBudget>,
    allow_local_fixture: bool,
) -> std::result::Result<(), PrepareJobError> {
    // Rust canonical paths use the Win32 verbatim namespace (`\\?\`) on
    // Windows. Keep those paths for containment and filesystem validation, but
    // pass Git the equivalent DOS/UNC spelling: Git for Windows can start and
    // answer `--version` with verbatim paths yet fail later while loading its
    // configuration during `init`.
    let external_repository = external_tool_path(repository)?;
    let external_hooks = external_tool_path(empty_hooks)?;
    let mut hooks_config = OsString::from("core.hooksPath=");
    hooks_config.push(&external_hooks);
    let mut protected = vec![
        os("-c"),
        os("credential.helper="),
        os("-c"),
        hooks_config,
        os("-c"),
        os("protocol.allow=never"),
        os("-c"),
        os("protocol.https.allow=always"),
        os("-c"),
        os("protocol.ext.allow=never"),
        os("-c"),
        os("filter.lfs.clean="),
        os("-c"),
        os("filter.lfs.smudge="),
        os("-c"),
        os("filter.lfs.process="),
        os("-c"),
        os("filter.lfs.required=false"),
    ];
    if allow_local_fixture {
        protected.extend([os("-c"), os("protocol.file.allow=always")]);
    } else {
        protected.extend([os("-c"), os("protocol.file.allow=never")]);
    }
    protected.extend_from_slice(arguments);
    let isolation_root = empty_hooks
        .parent()
        .context("Git hooks directory must have a parent")?;
    let isolated_home = isolation_root.join("git-home");
    let empty_config = isolated_home.join(".gitconfig");
    let external_home = external_tool_path(&isolated_home)?;
    let external_config = external_tool_path(&empty_config)?;
    let environment = vec![
        (os("GIT_TERMINAL_PROMPT"), os("0")),
        (os("GCM_INTERACTIVE"), os("Never")),
        (os("GIT_CONFIG_NOSYSTEM"), os("1")),
        (os("GIT_ATTR_NOSYSTEM"), os("1")),
        (
            os("GIT_CONFIG_GLOBAL"),
            external_config.as_os_str().to_owned(),
        ),
        (
            os("GIT_CONFIG_SYSTEM"),
            external_config.as_os_str().to_owned(),
        ),
        (os("GIT_LFS_SKIP_SMUDGE"), os("1")),
        (os("HOME"), external_home.as_os_str().to_owned()),
        (os("XDG_CONFIG_HOME"), external_home.as_os_str().to_owned()),
    ];
    #[cfg(windows)]
    let environment = {
        let mut environment = environment;
        environment.push((os("USERPROFILE"), external_home.as_os_str().to_owned()));
        environment
    };
    let result = run_process(
        ProcessRequest {
            program: os("git"),
            arguments: protected,
            cwd: external_repository,
            timeout: Duration::from_secs(300),
            stdout_path: logs.join(format!("git-{label}.stdout.log")),
            stderr_path: logs.join(format!("git-{label}.stderr.log")),
            log_budget,
            environment,
            #[cfg(test)]
            fault: None,
        },
        cancellation,
        sink,
    )
    .await
    .map_err(PrepareJobError::from_process_error)?;
    if !result.succeeded() {
        return Err(PrepareJobError::from_process_result(label, result));
    }
    Ok(())
}

#[cfg(not(windows))]
fn external_tool_path(path: &Path) -> Result<PathBuf> {
    Ok(path.to_owned())
}

#[cfg(windows)]
fn external_tool_path(path: &Path) -> Result<PathBuf> {
    // Do not let removing the verbatim prefix change which object the external
    // tool opens. Win32 DOS paths normalize trailing dots/spaces and reserved
    // device names, while the verbatim namespace does not. Canonicalize the
    // converted spelling and require it to resolve back to the exact same
    // typed volume and component sequence before exposing it to Git.
    let canonical = fs::canonicalize(path)
        .with_context(|| format!("canonicalize external tool path {}", path.display()))?;
    let output = deverbatim_windows_path(&canonical)?;
    let roundtrip = fs::canonicalize(&output).with_context(|| {
        format!(
            "canonicalize converted external tool path {}",
            output.display()
        )
    })?;
    if !windows_path_identity_eq(&canonical, &roundtrip) {
        bail!(
            "converted external tool path changed filesystem identity: {} -> {}",
            canonical.display(),
            roundtrip.display()
        );
    }
    Ok(output)
}

#[cfg(windows)]
fn deverbatim_windows_path(path: &Path) -> Result<PathBuf> {
    use std::path::{Component, Prefix};

    let mut components = path.components();
    let Component::Prefix(prefix) = components
        .next()
        .context("external tool path must identify a Windows volume")?
    else {
        bail!("external tool path must identify a Windows volume");
    };
    let mut output = match prefix.kind() {
        Prefix::Disk(drive) | Prefix::VerbatimDisk(drive) => {
            PathBuf::from(format!("{}:\\", char::from(drive.to_ascii_uppercase())))
        }
        Prefix::UNC(server, share) | Prefix::VerbatimUNC(server, share) => {
            validate_windows_external_component(server, "UNC server")?;
            validate_windows_external_component(share, "UNC share")?;
            let mut root = OsString::from(r"\\");
            root.push(server);
            root.push(r"\");
            root.push(share);
            root.push(r"\");
            PathBuf::from(root)
        }
        Prefix::Verbatim(_) | Prefix::DeviceNS(_) => {
            bail!("external tool path uses an unsupported Windows device namespace")
        }
    };
    if !matches!(components.next(), Some(Component::RootDir)) {
        bail!("external tool path must be absolute");
    }
    for component in components {
        match component {
            Component::Normal(value) => {
                validate_windows_external_component(value, "path")?;
                output.push(value);
            }
            Component::CurDir => {}
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => {
                bail!("external tool path contains an ambiguous component")
            }
        }
    }
    Ok(output)
}

#[cfg(windows)]
fn validate_windows_external_component(value: &std::ffi::OsStr, kind: &str) -> Result<()> {
    use std::os::windows::ffi::OsStrExt;

    let units = value.encode_wide().collect::<Vec<_>>();
    if units.is_empty() {
        bail!("external tool {kind} component is empty");
    }
    if matches!(
        units.last().copied(),
        Some(unit) if unit == u16::from(b'.') || unit == u16::from(b' ')
    ) {
        bail!("external tool {kind} component ends in a dot or space");
    }
    if units.contains(&(b':' as u16)) {
        bail!("external tool {kind} component contains an alternate-data-stream separator");
    }

    let stem = units
        .iter()
        .copied()
        .take_while(|unit| *unit != b'.' as u16)
        .map(|unit| {
            if unit <= u16::from(u8::MAX) {
                char::from((unit as u8).to_ascii_uppercase())
            } else {
                '\0'
            }
        })
        .collect::<String>();
    let reserved = matches!(
        stem.as_str(),
        "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$"
    ) || matches_reserved_numbered_device(&stem, "COM")
        || matches_reserved_numbered_device(&stem, "LPT");
    if reserved {
        bail!("external tool {kind} component is a reserved DOS device name");
    }
    Ok(())
}

#[cfg(windows)]
fn matches_reserved_numbered_device(value: &str, prefix: &str) -> bool {
    let Some(suffix) = value.strip_prefix(prefix) else {
        return false;
    };
    matches!(suffix, "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9")
}

#[cfg(windows)]
#[derive(Debug)]
enum ExternalWindowsVolumeIdentity<'a> {
    Disk(u8),
    Unc(&'a std::ffi::OsStr, &'a std::ffi::OsStr),
}

#[cfg(windows)]
impl ExternalWindowsVolumeIdentity<'_> {
    fn matches(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::Disk(left), Self::Disk(right)) => left.eq_ignore_ascii_case(right),
            (Self::Unc(left_server, left_share), Self::Unc(right_server, right_share)) => {
                windows_external_component_eq(left_server, right_server)
                    && windows_external_component_eq(left_share, right_share)
            }
            _ => false,
        }
    }
}

#[cfg(windows)]
#[derive(Debug)]
struct ExternalWindowsPathIdentity<'a> {
    volume: ExternalWindowsVolumeIdentity<'a>,
    components: Vec<&'a std::ffi::OsStr>,
}

#[cfg(windows)]
impl<'a> ExternalWindowsPathIdentity<'a> {
    fn parse(path: &'a Path) -> Option<Self> {
        use std::path::{Component, Prefix};

        let mut components = path.components();
        let Component::Prefix(prefix) = components.next()? else {
            return None;
        };
        let volume = match prefix.kind() {
            Prefix::Disk(drive) | Prefix::VerbatimDisk(drive) => {
                ExternalWindowsVolumeIdentity::Disk(drive)
            }
            Prefix::UNC(server, share) | Prefix::VerbatimUNC(server, share) => {
                ExternalWindowsVolumeIdentity::Unc(server, share)
            }
            Prefix::Verbatim(_) | Prefix::DeviceNS(_) => return None,
        };
        if !matches!(components.next(), Some(Component::RootDir)) {
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
fn windows_path_identity_eq(left: &Path, right: &Path) -> bool {
    let (Some(left), Some(right)) = (
        ExternalWindowsPathIdentity::parse(left),
        ExternalWindowsPathIdentity::parse(right),
    ) else {
        return false;
    };
    left.volume.matches(&right.volume)
        && left.components.len() == right.components.len()
        && left
            .components
            .iter()
            .zip(&right.components)
            .all(|(left, right)| windows_external_component_eq(left, right))
}

#[cfg(windows)]
fn windows_external_component_eq(left: &std::ffi::OsStr, right: &std::ffi::OsStr) -> bool {
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

fn read_single_line(path: &Path) -> Result<String> {
    let value = fs::read_to_string(path)
        .with_context(|| format!("read Git evidence {}", path.display()))?;
    let value = value.trim();
    if value.is_empty() || value.contains(['\r', '\n']) {
        bail!("Git evidence is empty or contains multiple lines");
    }
    Ok(value.to_owned())
}

fn write_failure_result(
    root: &Path,
    job_id: Uuid,
    run_id: Uuid,
    error: &PrepareJobError,
) -> Result<()> {
    let value = serde_json::json!({
        "apiVersion": "cyc.dev/worker-result/v1",
        "jobId": job_id,
        "runId": run_id,
        "state": "failed",
        "error": format!("{error:#}"),
    });
    write_json_atomic(&root.join("result.json"), &value)
}

pub fn write_json_atomic(path: &Path, value: &impl Serialize) -> Result<()> {
    let bytes = serde_json::to_vec_pretty(value).context("serialize job evidence")?;
    let temporary = path.with_extension("json.tmp");
    fs::write(&temporary, bytes)
        .with_context(|| format!("write temporary evidence {}", temporary.display()))?;
    fs::rename(&temporary, path).with_context(|| format!("install evidence {}", path.display()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::process::{
        DiscardLogSink, ProcessContainment, ProcessRequest, TestProcessFault, CANCEL_NONE,
    };
    use std::process::Command;
    use tempfile::tempdir;

    #[test]
    fn requires_full_oid_and_https_repository() {
        assert!(validate_full_oid("abcdef0").is_err());
        assert!(validate_full_oid(&"a".repeat(40)).is_ok());
        assert!(validate_repository("file:///tmp/repo", false).is_err());
        assert!(validate_repository("https://user:secret@example.com/repo", false).is_err());
        assert!(validate_repository("https://example.com/repo.git", false).is_ok());
    }

    #[tokio::test]
    async fn monitor_failure_stays_unconfirmed_through_source_classification() {
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
        let process_error = run_process(
            ProcessRequest {
                program,
                arguments,
                cwd: directory.path().to_owned(),
                timeout: Duration::from_secs(5),
                stdout_path: directory.path().join("fault.stdout.log"),
                stderr_path: directory.path().join("fault.stderr.log"),
                log_budget: Arc::new(LogBudget::new(2048)),
                environment: Vec::new(),
                fault: Some(TestProcessFault::MonitorFailureAfterAttach),
            },
            Arc::new(AtomicU8::new(CANCEL_NONE)),
            Arc::new(DiscardLogSink),
        )
        .await
        .unwrap_err();
        assert_eq!(process_error.containment(), ProcessContainment::Unconfirmed);
        let source_error = PrepareJobError::from_process_error(process_error);
        assert_eq!(source_error.containment(), SourceContainment::Unconfirmed);
    }

    #[tokio::test]
    async fn checks_out_exact_sha_from_local_fixture() {
        let fixture_guard = crate::process::test_exclusive_child_process_guard().await;
        if Command::new("git").arg("--version").output().is_err() {
            return;
        }
        let fixture = tempdir().unwrap();
        run_git_fixture(fixture.path(), &["init", "--quiet"]);
        run_git_fixture(fixture.path(), &["config", "user.name", "Worker Test"]);
        run_git_fixture(
            fixture.path(),
            &["config", "user.email", "worker@example.invalid"],
        );
        fs::write(fixture.path().join("README.md"), "fixture\n").unwrap();
        run_git_fixture(fixture.path(), &["add", "README.md"]);
        run_git_fixture(fixture.path(), &["commit", "--quiet", "-m", "fixture"]);
        let revision = String::from_utf8(
            Command::new("git")
                .args(["rev-parse", "HEAD"])
                .current_dir(fixture.path())
                .output()
                .unwrap()
                .stdout,
        )
        .unwrap()
        .trim()
        .to_owned();
        drop(fixture_guard);

        let destination = tempdir().unwrap();
        let canonical_destination = destination.path().canonicalize().unwrap();
        #[cfg(windows)]
        assert!(
            canonical_destination.to_string_lossy().starts_with(r"\\?\"),
            "Windows regression requires a verbatim canonical path: {}",
            canonical_destination.display()
        );
        let repo = canonical_destination.join("repo");
        let logs = canonical_destination.join("logs");
        fs::create_dir(&repo).unwrap();
        fs::create_dir(&logs).unwrap();
        let evidence = checkout_git(
            fixture.path().to_str().unwrap(),
            &revision,
            &repo,
            &logs,
            Arc::new(AtomicU8::new(CANCEL_NONE)),
            Arc::new(DiscardLogSink),
            Arc::new(LogBudget::new(16 * 1024 * 1024)),
            true,
        )
        .await
        .unwrap();
        assert_eq!(evidence.resolved_revision, revision);
        assert_eq!(
            fs::read_to_string(repo.join("README.md")).unwrap(),
            "fixture\n"
        );
    }

    #[cfg(windows)]
    #[test]
    fn external_git_paths_deverbatim_only_typed_disk_and_unc_paths() {
        let cases = [
            (r"\\?\C:\Worker\repo", r"C:\Worker\repo"),
            (r"c:/Worker/repo", r"C:\Worker\repo"),
            (
                r"\\?\UNC\server\share\Worker\repo",
                r"\\server\share\Worker\repo",
            ),
            (r"\\SERVER\Share\Worker\repo", r"\\SERVER\Share\Worker\repo"),
        ];
        for (input, expected) in cases {
            assert_eq!(
                deverbatim_windows_path(Path::new(input)).unwrap(),
                PathBuf::from(expected),
                "input={input:?}"
            );
        }

        for rejected in [
            r"C:relative\repo",
            r"\\?\Volume{00000000-0000-0000-0000-000000000000}\repo",
            r"\\.\C:\repo",
        ] {
            assert!(
                deverbatim_windows_path(Path::new(rejected)).is_err(),
                "unexpectedly accepted {rejected:?}"
            );
        }
    }

    #[cfg(windows)]
    #[test]
    fn external_git_paths_reject_win32_normalization_aliases() {
        for rejected in [
            r"\\?\C:\Worker\foo.",
            r"\\?\C:\Worker\foo ",
            r"\\?\C:\Worker\CON",
            r"\\?\C:\Worker\con.txt",
            r"\\?\C:\Worker\NUL",
            r"\\?\C:\Worker\nul.log",
            r"\\?\C:\Worker\COM1",
            r"\\?\C:\Worker\com9.txt",
            r"\\?\C:\Worker\LPT1",
            r"\\?\C:\Worker\lpt9.dat",
            r"\\?\C:\Worker\stream:name",
            r"\\?\UNC\server\share\foo.",
            r"\\?\UNC\server\share\foo ",
            r"\\?\UNC\server\share\CON.txt",
        ] {
            assert!(
                deverbatim_windows_path(Path::new(rejected)).is_err(),
                "unexpectedly accepted Win32-normalized alias {rejected:?}"
            );
        }

        assert_eq!(
            deverbatim_windows_path(Path::new(r"\\?\C:\Worker\foo")).unwrap(),
            PathBuf::from(r"C:\Worker\foo")
        );
        assert!(!windows_path_identity_eq(
            Path::new(r"\\?\C:\Worker\foo"),
            Path::new(r"C:\Worker\foo.")
        ));
    }

    #[cfg(windows)]
    #[test]
    fn external_git_path_identity_handles_unc_without_string_prefix_matching() {
        assert!(windows_path_identity_eq(
            Path::new(r"\\?\UNC\SERVER\Share\Worker\repo"),
            Path::new(r"\\server\share\worker\REPO")
        ));
        assert!(!windows_path_identity_eq(
            Path::new(r"\\?\UNC\SERVER\Share\Worker\repo"),
            Path::new(r"\\server\share-other\Worker\repo")
        ));
        assert!(!windows_path_identity_eq(
            Path::new(r"\\?\UNC\SERVER\Share\Worker\repo"),
            Path::new(r"\\server\share\Worker\repo-other")
        ));
    }

    #[cfg(windows)]
    #[test]
    fn external_git_path_roundtrips_a_real_temporary_directory() {
        let directory = tempdir().unwrap();
        let canonical = directory.path().canonicalize().unwrap();
        assert!(
            canonical.to_string_lossy().starts_with(r"\\?\"),
            "test requires a verbatim canonical path: {}",
            canonical.display()
        );

        let external = external_tool_path(&canonical).unwrap();
        assert!(!external.to_string_lossy().starts_with(r"\\?\"));
        let roundtrip = external.canonicalize().unwrap();
        assert!(windows_path_identity_eq(&canonical, &roundtrip));
    }

    fn run_git_fixture(directory: &Path, arguments: &[&str]) {
        let status = Command::new("git")
            .args(arguments)
            .current_dir(directory)
            .status()
            .unwrap();
        assert!(status.success(), "git {arguments:?}");
    }
}
