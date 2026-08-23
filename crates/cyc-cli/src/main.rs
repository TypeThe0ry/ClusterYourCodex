use std::path::{Path, PathBuf};
use std::{fs, io};

use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use cyc_protocol::onboarding::{CreatePairingRequestV1, EnrollmentBundleV1, PairingStatusV1};
use cyc_protocol::{
    JobSpec, SnapshotMetadataV1, MAX_SNAPSHOT_ARCHIVE_BYTES, MAX_SNAPSHOT_ENTRIES,
    MAX_SNAPSHOT_EXPANDED_BYTES, MAX_SNAPSHOT_FILE_BYTES, SNAPSHOT_ARCHIVE_FORMAT,
    SNAPSHOT_MEDIA_TYPE,
};
use reqwest::{Client, Method};
use serde_json::Value;
use sha2::{Digest, Sha256};
use uuid::Uuid;

mod identity;

const DEFAULT_CONTROLLER: &str = "http://127.0.0.1:47831";

#[derive(Clone, Copy)]
enum SnapshotPackEntryKind {
    Directory,
    File,
}

struct SnapshotPackEntry {
    source: PathBuf,
    portable: String,
    kind: SnapshotPackEntryKind,
    size: u64,
}

fn pack_snapshot(source: &Path, output: &Path, max_bytes: u64) -> Result<Value> {
    if !(1..=MAX_SNAPSHOT_ARCHIVE_BYTES).contains(&max_bytes) {
        bail!("--max-bytes must be within the snapshot protocol archive limit");
    }
    let source = fs::canonicalize(source)
        .with_context(|| format!("failed to resolve snapshot source {}", source.display()))?;
    let source_metadata = fs::symlink_metadata(&source)?;
    if !source_metadata.is_dir()
        || source_metadata.file_type().is_symlink()
        || metadata_is_reparse(&source_metadata)
    {
        bail!("snapshot source must be a direct directory, not a link or reparse point");
    }
    let entries = collect_snapshot_entries(&source)?;
    let output_parent = output
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(output_parent)?;
    if path_entry_exists(output) {
        bail!("snapshot output already exists and will not be replaced");
    }
    let temporary = output_parent.join(format!(".snapshot-pack-{}.tmp", Uuid::new_v4()));
    let result = (|| -> Result<()> {
        let file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
            .context("create snapshot archive temporary")?;
        let limited = LimitedWriter::new(file, max_bytes);
        let mut encoder = zstd::stream::write::Encoder::new(limited, 3)
            .context("create deterministic zstd encoder")?;
        encoder.include_checksum(true)?;
        let mut archive = tar::Builder::new(encoder);
        archive.mode(tar::HeaderMode::Deterministic);
        for entry in entries {
            let mut header = tar::Header::new_gnu();
            header.set_uid(0);
            header.set_gid(0);
            header.set_mtime(0);
            match entry.kind {
                SnapshotPackEntryKind::Directory => {
                    header.set_entry_type(tar::EntryType::Directory);
                    header.set_mode(0o755);
                    header.set_size(0);
                    header.set_cksum();
                    archive
                        .append_data(&mut header, Path::new(&entry.portable), io::empty())
                        .with_context(|| format!("pack snapshot directory {}", entry.portable))?;
                }
                SnapshotPackEntryKind::File => {
                    header.set_entry_type(tar::EntryType::Regular);
                    header.set_mode(0o644);
                    header.set_size(entry.size);
                    header.set_cksum();
                    let mut file = open_snapshot_pack_file(&entry.source, entry.size)?;
                    archive
                        .append_data(&mut header, Path::new(&entry.portable), &mut file)
                        .with_context(|| format!("pack snapshot file {}", entry.portable))?;
                    if file.metadata()?.len() != entry.size {
                        bail!("snapshot source changed while it was being packed");
                    }
                }
            }
        }
        let encoder = archive.into_inner().context("finish tar snapshot")?;
        let mut limited = encoder.finish().context("finish zstd snapshot")?;
        io::Write::flush(&mut limited)?;
        limited.into_inner().sync_all()?;
        if path_entry_exists(output) {
            bail!("snapshot output appeared concurrently and will not be replaced");
        }
        #[cfg(unix)]
        {
            fs::hard_link(&temporary, output).context("atomically install snapshot archive")?;
            fs::remove_file(&temporary).context("remove snapshot archive temporary")?;
        }
        #[cfg(windows)]
        fs::rename(&temporary, output).context("atomically install snapshot archive")?;
        #[cfg(not(any(unix, windows)))]
        compile_error!("snapshot packing requires Unix or Windows");
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result?;
    let bytes = read_snapshot_archive(output)?;
    let digest = format!("sha256:{}", sha256_hex(&bytes));
    Ok(serde_json::json!({
        "apiVersion": cyc_protocol::SNAPSHOT_API_VERSION,
        "format": SNAPSHOT_ARCHIVE_FORMAT,
        "digest": digest,
        "sizeBytes": bytes.len(),
        "archive": output,
    }))
}

fn collect_snapshot_entries(source: &Path) -> Result<Vec<SnapshotPackEntry>> {
    let mut entries = Vec::new();
    let mut expanded = 0_u64;
    let mut case_paths = std::collections::BTreeMap::<String, String>::new();
    let walker = walkdir::WalkDir::new(source)
        .follow_links(false)
        .min_depth(1)
        .into_iter()
        .filter_entry(|entry| snapshot_walk_entry_allowed(source, entry.path()));
    for entry in walker {
        let entry = entry.context("walk snapshot source")?;
        let relative = entry
            .path()
            .strip_prefix(source)
            .context("snapshot walk escaped source")?;
        if snapshot_path_is_sensitive(relative) {
            continue;
        }
        let metadata = fs::symlink_metadata(entry.path())?;
        if metadata.file_type().is_symlink() || metadata_is_reparse(&metadata) {
            continue;
        }
        let kind = if metadata.is_dir() {
            SnapshotPackEntryKind::Directory
        } else if metadata.is_file() {
            if metadata.len() > MAX_SNAPSHOT_FILE_BYTES {
                bail!("snapshot source contains a file larger than the protocol limit");
            }
            expanded = expanded
                .checked_add(metadata.len())
                .context("snapshot expanded-size overflow")?;
            if expanded > MAX_SNAPSHOT_EXPANDED_BYTES {
                bail!("snapshot source exceeds the expanded-size protocol limit");
            }
            SnapshotPackEntryKind::File
        } else {
            bail!("snapshot source contains a non-file filesystem object");
        };
        let portable = portable_snapshot_path(relative)?;
        register_pack_case_path(&portable, &mut case_paths)?;
        entries.push(SnapshotPackEntry {
            source: entry.path().to_owned(),
            portable,
            kind,
            size: metadata.len(),
        });
        if u64::try_from(entries.len()).unwrap_or(u64::MAX) > MAX_SNAPSHOT_ENTRIES {
            bail!("snapshot source exceeds the entry-count protocol limit");
        }
    }
    entries.sort_by(|left, right| left.portable.cmp(&right.portable));
    Ok(entries)
}

fn snapshot_walk_entry_allowed(source: &Path, path: &Path) -> bool {
    let Ok(relative) = path.strip_prefix(source) else {
        return false;
    };
    if snapshot_path_is_sensitive(relative) {
        return false;
    }
    fs::symlink_metadata(path)
        .is_ok_and(|metadata| !metadata.file_type().is_symlink() && !metadata_is_reparse(&metadata))
}

/// Built-in exclusions are deliberately not configurable: a one-click pack
/// must never turn an adjacent credential or dependency cache into source
/// merely because a project forgot to provide an ignore file.
fn snapshot_path_is_sensitive(path: &Path) -> bool {
    path.components().any(|component| {
        component
            .as_os_str()
            .to_str()
            .is_some_and(snapshot_segment_is_sensitive)
    })
}

fn snapshot_segment_is_sensitive(segment: &str) -> bool {
    let segment = segment.to_ascii_lowercase();
    matches!(
        segment.as_str(),
        ".git" | ".ssh" | ".aws" | ".azure" | ".codex" | "node_modules" | "target"
    ) || segment.starts_with(".env")
        || segment.ends_with(".pem")
        || segment.ends_with(".key")
        || segment.starts_with("id_rsa")
        || segment.starts_with("id_ed25519")
        || segment.starts_with("credentials")
        || segment.starts_with("secrets")
}

fn portable_snapshot_path(path: &Path) -> Result<String> {
    let mut segments = Vec::new();
    for component in path.components() {
        let std::path::Component::Normal(segment) = component else {
            bail!("snapshot source contains a non-portable path component");
        };
        let segment = segment
            .to_str()
            .context("snapshot source paths must be valid UTF-8")?;
        validate_pack_segment(segment)?;
        segments.push(segment);
    }
    let portable = segments.join("/");
    cyc_protocol::validate_portable_relative_path(&portable)
        .context("snapshot source path is not portable")?;
    if portable.len() > cyc_protocol::MAX_SNAPSHOT_PATH_BYTES {
        bail!("snapshot source path exceeds the protocol limit");
    }
    Ok(portable)
}

fn validate_pack_segment(segment: &str) -> Result<()> {
    if segment.len() > 255
        || segment.chars().any(char::is_control)
        || segment.ends_with(['.', ' '])
        || segment
            .chars()
            .any(|character| matches!(character, ':' | '*' | '?' | '"' | '<' | '>' | '|'))
    {
        bail!("snapshot source contains a non-portable path component");
    }
    let stem = segment
        .split('.')
        .next()
        .unwrap_or(segment)
        .to_ascii_uppercase();
    let reserved = matches!(
        stem.as_str(),
        "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$"
    ) || numbered_device(&stem, "COM")
        || numbered_device(&stem, "LPT");
    if reserved {
        bail!("snapshot source contains a reserved filesystem device name");
    }
    Ok(())
}

fn numbered_device(value: &str, prefix: &str) -> bool {
    value
        .strip_prefix(prefix)
        .is_some_and(|suffix| matches!(suffix, "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9"))
}

fn register_pack_case_path(
    portable: &str,
    case_paths: &mut std::collections::BTreeMap<String, String>,
) -> Result<()> {
    let mut prefix = String::new();
    for segment in portable.split('/') {
        if !prefix.is_empty() {
            prefix.push('/');
        }
        prefix.push_str(segment);
        let folded = prefix.to_lowercase();
        if let Some(existing) = case_paths.get(&folded) {
            if existing != &prefix {
                bail!("snapshot source contains case-colliding paths");
            }
        } else {
            case_paths.insert(folded, prefix.clone());
        }
    }
    Ok(())
}

#[cfg(windows)]
fn metadata_is_reparse(metadata: &fs::Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;
    metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

#[cfg(not(windows))]
fn metadata_is_reparse(_metadata: &fs::Metadata) -> bool {
    false
}

fn path_entry_exists(path: &Path) -> bool {
    match fs::symlink_metadata(path) {
        Ok(_) => true,
        Err(error) if error.kind() == io::ErrorKind::NotFound => false,
        Err(_) => true,
    }
}

fn open_snapshot_pack_file(path: &Path, expected_size: u64) -> Result<fs::File> {
    let mut options = fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
        options.custom_flags(FILE_FLAG_OPEN_REPARSE_POINT);
    }
    let file = options
        .open(path)
        .with_context(|| format!("open snapshot source file {}", path.display()))?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata_is_reparse(&metadata) || metadata.len() != expected_size {
        bail!("snapshot source file changed type or size while packing");
    }
    Ok(file)
}

struct LimitedWriter<W> {
    inner: W,
    written: u64,
    maximum: u64,
}

impl<W> LimitedWriter<W> {
    fn new(inner: W, maximum: u64) -> Self {
        Self {
            inner,
            written: 0,
            maximum,
        }
    }

    fn into_inner(self) -> W {
        self.inner
    }
}

impl<W: io::Write> io::Write for LimitedWriter<W> {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        let next = self
            .written
            .saturating_add(u64::try_from(buffer.len()).unwrap_or(u64::MAX));
        if next > self.maximum {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "snapshot archive exceeds the configured compressed-size limit",
            ));
        }
        let length = self.inner.write(buffer)?;
        self.written = self
            .written
            .saturating_add(u64::try_from(length).unwrap_or(u64::MAX));
        Ok(length)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.inner.flush()
    }
}

fn read_snapshot_archive(path: &Path) -> Result<Vec<u8>> {
    let metadata = fs::symlink_metadata(path)
        .with_context(|| format!("inspect snapshot archive {}", path.display()))?;
    if !metadata.is_file()
        || metadata.file_type().is_symlink()
        || metadata_is_reparse(&metadata)
        || !(1..=MAX_SNAPSHOT_ARCHIVE_BYTES).contains(&metadata.len())
    {
        bail!("snapshot archive must be a bounded direct regular file");
    }
    let mut file = open_snapshot_pack_file(path, metadata.len())?;
    let mut bytes = Vec::with_capacity(usize::try_from(metadata.len())?);
    io::Read::read_to_end(&mut file, &mut bytes)?;
    if u64::try_from(bytes.len()).unwrap_or(u64::MAX) != metadata.len() {
        bail!("snapshot archive changed while being read");
    }
    Ok(bytes)
}

fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

async fn upload_snapshot(
    client: &Client,
    base: &str,
    archive: &Path,
    token: &str,
) -> Result<Value> {
    let bytes = read_snapshot_archive(archive)?;
    let size_bytes = u64::try_from(bytes.len()).unwrap_or(u64::MAX);
    let digest = format!("sha256:{}", sha256_hex(&bytes));
    let sha256 = cyc_protocol::snapshot_digest_hex(&digest)?;
    let path = format!("/v1/snapshots/{sha256}");
    let response = client
        .put(format!("{base}{path}"))
        .bearer_auth(token)
        .header(reqwest::header::CONTENT_TYPE, SNAPSHOT_MEDIA_TYPE)
        .header(reqwest::header::CONTENT_LENGTH, size_bytes)
        .body(bytes)
        .send()
        .await
        .with_context(|| format!("controller snapshot upload to {path} failed"))?;
    let status = response.status();
    if !status.is_success() {
        bail!("controller returned HTTP {status} for {path}");
    }
    let metadata = response
        .json::<SnapshotMetadataV1>()
        .await
        .context("controller returned invalid snapshot metadata")?;
    metadata
        .validate()
        .context("validate snapshot upload receipt")?;
    if metadata.digest != digest || metadata.size_bytes != size_bytes {
        bail!("controller snapshot receipt does not match uploaded archive bytes");
    }
    Ok(serde_json::to_value(metadata)?)
}

async fn snapshot_status(client: &Client, base: &str, digest: &str, token: &str) -> Result<Value> {
    cyc_protocol::validate_snapshot_digest(digest).context("invalid snapshot digest")?;
    let sha256 = cyc_protocol::snapshot_digest_hex(digest)?;
    let path = format!("/v1/snapshots/{sha256}");
    let response = client
        .head(format!("{base}{path}"))
        .bearer_auth(token)
        .send()
        .await
        .with_context(|| format!("controller snapshot status request to {path} failed"))?;
    let status = response.status();
    if !status.is_success() {
        bail!("controller returned HTTP {status} for {path}");
    }
    let size = response
        .headers()
        .get("x-cyc-snapshot-size")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<u64>().ok())
        .context("snapshot status omitted a valid size")?;
    cyc_protocol::validate_snapshot_size(size)?;
    let etag = response
        .headers()
        .get(reqwest::header::ETAG)
        .and_then(|value| value.to_str().ok())
        .context("snapshot status omitted ETag")?;
    if etag != format!("\"{digest}\"") {
        bail!("snapshot status ETag does not match the requested digest");
    }
    Ok(serde_json::json!({
        "apiVersion": cyc_protocol::SNAPSHOT_API_VERSION,
        "format": SNAPSHOT_ARCHIVE_FORMAT,
        "digest": digest,
        "sizeBytes": size,
        "available": true,
    }))
}

#[derive(Debug, Parser)]
#[command(
    name = "cyc",
    version,
    about = "ClusterYourCodex controller diagnostics and job client"
)]
struct Cli {
    /// Controller base URL. Credentials are intentionally not accepted by this CLI.
    #[arg(long, env = "CYC_CONTROLLER_URL", default_value = DEFAULT_CONTROLLER)]
    controller: String,

    /// File containing the controller bearer token; never pass the token itself on argv.
    #[arg(long, env = "CYC_CONTROLLER_TOKEN_FILE")]
    token_file: Option<PathBuf>,

    /// Pretty-print JSON responses.
    #[arg(long, global = true)]
    pretty: bool,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Debug, Subcommand)]
enum Commands {
    /// Check controller and database health.
    Health,
    /// List registered worker nodes and their current capabilities.
    Nodes,
    /// List jobs, or fetch a single job by id.
    Jobs {
        #[arg(value_name = "JOB_ID")]
        id: Option<Uuid>,
    },
    /// Ask the scheduler where a job would run without creating it.
    Plan {
        /// JobSpec JSON file, or '-' for stdin.
        #[arg(short, long, default_value = "-")]
        file: PathBuf,
    },
    /// Validate and submit a JobSpec JSON document.
    Submit {
        /// JobSpec JSON file, or '-' for stdin.
        #[arg(short, long, default_value = "-")]
        file: PathBuf,
        /// Reuse a previously issued, still-valid placement plan.
        #[arg(long)]
        plan_id: Option<Uuid>,
    },
    /// Request cancellation of a queued or active job.
    Cancel {
        id: Uuid,
        /// Optional optimistic-concurrency version from a prior job response.
        #[arg(long)]
        expected_version: Option<u64>,
    },
    /// Create or revoke a managed-worker pairing.
    Pair {
        #[command(subcommand)]
        command: PairCommands,
    },
    /// Pack, upload, or inspect immutable source snapshots.
    Snapshot {
        #[command(subcommand)]
        command: SnapshotCommands,
    },
    /// Generate or strictly verify the controller TLS identity used by workers.
    Identity {
        #[command(subcommand)]
        command: IdentityCommands,
    },
    /// List log chunks or download a reconstructed log stream.
    Logs {
        id: Uuid,
        /// Download stdout or stderr instead of listing chunk metadata.
        #[arg(long)]
        stream: Option<String>,
        /// Required destination for a downloaded stream.
        #[arg(long)]
        output: Option<PathBuf>,
    },
    /// List artifacts or download one artifact by id.
    Artifacts {
        id: Uuid,
        #[arg(long)]
        artifact_id: Option<Uuid>,
        /// Required destination for an artifact download.
        #[arg(long)]
        output: Option<PathBuf>,
    },
}

#[derive(Debug, Subcommand)]
enum SnapshotCommands {
    /// Reproducibly pack a source directory as a bounded tar.zst archive.
    Pack {
        #[arg(long, default_value = ".")]
        source: PathBuf,
        #[arg(long)]
        output: PathBuf,
        #[arg(long, default_value_t = MAX_SNAPSHOT_ARCHIVE_BYTES)]
        max_bytes: u64,
    },
    /// Upload an existing tar.zst archive by its raw-byte SHA-256 identity.
    Upload {
        #[arg(long)]
        archive: PathBuf,
    },
    /// Check whether a content-addressed snapshot exists on the controller.
    Status {
        #[arg(value_name = "SHA256_DIGEST")]
        digest: String,
    },
}

#[derive(Debug, Subcommand)]
enum IdentityCommands {
    /// Generate a new self-signed identity without replacing existing files.
    Init {
        #[arg(long)]
        output_dir: PathBuf,
        /// DNS name or IP SAN. Repeat to include more than one host.
        #[arg(long, required = true)]
        host: Vec<String>,
    },
    /// Verify an existing one-certificate, PKCS#8-key identity pair.
    Verify {
        #[arg(long)]
        certificate: PathBuf,
        #[arg(long)]
        private_key: PathBuf,
        #[arg(long)]
        host: String,
        /// Emit safe machine-readable metadata (the default CLI output format).
        #[arg(long)]
        json: bool,
    },
}

#[derive(Debug, Subcommand)]
enum PairCommands {
    /// Create a ten-minute one-time pairing bundle and save it to a new file.
    Create {
        #[arg(long)]
        output: PathBuf,
        /// Existing logical node id to preserve while repairing/re-pairing.
        #[arg(long)]
        node_id: Option<Uuid>,
        /// Durable controller idempotency key. Reuse it after a failed handoff.
        #[arg(long)]
        operation_id: Option<String>,
    },
    /// Poll non-secret enrollment state.
    Status { pairing_id: Uuid },
    /// Revoke a pairing and its associated worker credential.
    Revoke { pairing_id: Uuid },
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let client = Client::builder()
        .user_agent(concat!("cyc-cli/", env!("CARGO_PKG_VERSION")))
        .build()
        .context("failed to build HTTP client")?;
    let base = normalize_base_url(&cli.controller)?;
    let token = if matches!(
        &cli.command,
        Commands::Health
            | Commands::Snapshot {
                command: SnapshotCommands::Pack { .. }
            }
            | Commands::Identity { .. }
    ) {
        None
    } else {
        let token_file = cli.token_file.unwrap_or_else(default_token_path);
        Some(read_controller_token(&token_file)?)
    };

    let response = match &cli.command {
        Commands::Health => {
            request_json(&client, Method::GET, &base, "/v1/health", None, None, None).await?
        }
        Commands::Nodes => {
            request_json(
                &client,
                Method::GET,
                &base,
                "/v1/fleet",
                None,
                None,
                token.as_deref(),
            )
            .await?
        }
        Commands::Jobs { id: Some(id) } => {
            request_json(
                &client,
                Method::GET,
                &base,
                &format!("/v1/jobs/{id}"),
                None,
                None,
                token.as_deref(),
            )
            .await?
        }
        Commands::Jobs { id: None } => {
            request_json(
                &client,
                Method::GET,
                &base,
                "/v1/jobs",
                None,
                None,
                token.as_deref(),
            )
            .await?
        }
        Commands::Plan { file } => {
            let spec = read_job_spec(file)?;
            request_json(
                &client,
                Method::POST,
                &base,
                "/v1/plans",
                Some(serde_json::json!({ "job": spec })),
                None,
                token.as_deref(),
            )
            .await?
        }
        Commands::Submit { file, plan_id } => {
            let spec = read_job_spec(file)?;
            let mut body = serde_json::json!({ "job": spec });
            if let Some(plan_id) = plan_id {
                body["planId"] = serde_json::to_value(plan_id)?;
            }
            request_json(
                &client,
                Method::POST,
                &base,
                "/v1/jobs",
                Some(body),
                None,
                token.as_deref(),
            )
            .await?
        }
        Commands::Cancel {
            id,
            expected_version,
        } => {
            request_json(
                &client,
                Method::POST,
                &base,
                &format!("/v1/jobs/{id}/cancel"),
                None,
                *expected_version,
                token.as_deref(),
            )
            .await?
        }
        Commands::Pair {
            command:
                PairCommands::Create {
                    output,
                    node_id,
                    operation_id,
                },
        } => {
            let operation_id = operation_id
                .clone()
                .unwrap_or_else(|| format!("cyc-cli:{}", Uuid::new_v4()));
            let request = CreatePairingRequestV1 {
                intended_node_id: *node_id,
            };
            request.validate().context("invalid pairing request")?;
            let bundle = request_enrollment_bundle(
                &client,
                &base,
                "/v1/pairings",
                &request,
                &operation_id,
                token.as_deref(),
            )
            .await?;
            write_secret_json(output, &bundle)?;
            serde_json::json!({
                "pairingId": bundle.pairing_id,
                "intendedNodeId": bundle.intended_node_id,
                "expiresAt": bundle.expires_at,
                "bundleFile": output,
                "operationId": operation_id,
            })
        }
        Commands::Pair {
            command: PairCommands::Status { pairing_id },
        } => {
            let status = request_pairing_status(
                &client,
                &base,
                &format!("/v1/pairings/{pairing_id}"),
                token.as_deref(),
            )
            .await?;
            serde_json::to_value(status)?
        }
        Commands::Pair {
            command: PairCommands::Revoke { pairing_id },
        } => {
            request_json(
                &client,
                Method::POST,
                &base,
                &format!("/v1/pairings/{pairing_id}/revoke"),
                None,
                None,
                token.as_deref(),
            )
            .await?
        }
        Commands::Snapshot {
            command:
                SnapshotCommands::Pack {
                    source,
                    output,
                    max_bytes,
                },
        } => pack_snapshot(source, output, *max_bytes)?,
        Commands::Snapshot {
            command: SnapshotCommands::Upload { archive },
        } => {
            upload_snapshot(
                &client,
                &base,
                archive,
                token.as_deref().context("controller token is required")?,
            )
            .await?
        }
        Commands::Snapshot {
            command: SnapshotCommands::Status { digest },
        } => {
            snapshot_status(
                &client,
                &base,
                digest,
                token.as_deref().context("controller token is required")?,
            )
            .await?
        }
        Commands::Identity {
            command: IdentityCommands::Init { output_dir, host },
        } => identity::init(output_dir, host)?,
        Commands::Identity {
            command:
                IdentityCommands::Verify {
                    certificate,
                    private_key,
                    host,
                    json: _,
                },
        } => identity::verify(certificate, private_key, host)?,
        Commands::Logs {
            id,
            stream: None,
            output: None,
        } => {
            request_json(
                &client,
                Method::GET,
                &base,
                &format!("/v1/jobs/{id}/logs"),
                None,
                None,
                token.as_deref(),
            )
            .await?
        }
        Commands::Logs {
            id,
            stream: Some(stream),
            output: Some(output),
        } => {
            if !matches!(stream.as_str(), "stdout" | "stderr") {
                bail!("--stream must be stdout or stderr");
            }
            let bytes = request_bytes(
                &client,
                &base,
                &format!("/v1/jobs/{id}/logs/{stream}"),
                token.as_deref(),
            )
            .await?;
            write_new_file(output, &bytes)?;
            serde_json::json!({ "output": output, "bytes": bytes.len() })
        }
        Commands::Logs { .. } => {
            bail!("--stream and --output must be provided together for log downloads")
        }
        Commands::Artifacts {
            id,
            artifact_id: None,
            output: None,
        } => {
            request_json(
                &client,
                Method::GET,
                &base,
                &format!("/v1/jobs/{id}/artifacts"),
                None,
                None,
                token.as_deref(),
            )
            .await?
        }
        Commands::Artifacts {
            id,
            artifact_id: Some(artifact_id),
            output: Some(output),
        } => {
            let bytes = request_bytes(
                &client,
                &base,
                &format!("/v1/jobs/{id}/artifacts/{artifact_id}"),
                token.as_deref(),
            )
            .await?;
            write_new_file(output, &bytes)?;
            serde_json::json!({ "output": output, "bytes": bytes.len(), "artifactId": artifact_id })
        }
        Commands::Artifacts { .. } => {
            bail!("--artifact-id and --output must be provided together for artifact downloads")
        }
    };

    if cli.pretty {
        println!("{}", serde_json::to_string_pretty(&response)?);
    } else {
        println!("{}", serde_json::to_string(&response)?);
    }
    Ok(())
}

fn normalize_base_url(raw: &str) -> Result<String> {
    let value = raw.trim_end_matches('/');
    let parsed = reqwest::Url::parse(value).context("controller URL is invalid")?;
    if !matches!(parsed.scheme(), "http" | "https") {
        bail!("controller URL must use http:// or https://");
    }
    if !parsed.username().is_empty() || parsed.password().is_some() {
        bail!("controller URL must not contain credentials");
    }
    let Some(host) = parsed.host_str() else {
        bail!("controller URL must include a host");
    };
    let is_loopback = host.eq_ignore_ascii_case("localhost")
        || host
            .parse::<std::net::IpAddr>()
            .is_ok_and(|address| address.is_loopback());
    if !is_loopback {
        bail!("controller URL must use a loopback host");
    }
    if parsed.query().is_some() || parsed.fragment().is_some() {
        bail!("controller URL must not include query or fragment components");
    }
    Ok(value.to_owned())
}

fn default_token_path() -> PathBuf {
    if let Some(data) = std::env::var_os("LOCALAPPDATA") {
        return PathBuf::from(data)
            .join("ClusterYourCodex")
            .join("controller.token");
    }
    if let Some(data) = std::env::var_os("XDG_DATA_HOME") {
        return PathBuf::from(data)
            .join("clusteryourcodex")
            .join("controller.token");
    }
    if let Some(home) = std::env::var_os("HOME") {
        let home = PathBuf::from(home);
        if cfg!(target_os = "macos") {
            return home
                .join("Library")
                .join("Application Support")
                .join("ClusterYourCodex")
                .join("controller.token");
        }
        return home
            .join(".local")
            .join("share")
            .join("clusteryourcodex")
            .join("controller.token");
    }
    PathBuf::from("controller.token")
}

fn read_controller_token(path: &PathBuf) -> Result<String> {
    let value = std::fs::read_to_string(path)
        .with_context(|| format!("failed to read controller token file {}", path.display()))?;
    let value = value.trim();
    if !(32..=256).contains(&value.len())
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_graphic() && !byte.is_ascii_whitespace())
    {
        bail!("controller token file is invalid");
    }
    Ok(value.to_owned())
}

fn read_job_spec(path: &PathBuf) -> Result<JobSpec> {
    let json = if path.as_os_str() == "-" {
        let mut value = String::new();
        std::io::Read::read_to_string(&mut std::io::stdin().lock(), &mut value)
            .context("failed to read JobSpec from stdin")?;
        value
    } else {
        std::fs::read_to_string(path)
            .with_context(|| format!("failed to read JobSpec file {}", path.display()))?
    };

    parse_job_spec(&json)
}

fn parse_job_spec(json: &str) -> Result<JobSpec> {
    // Windows PowerShell 5 writes a UTF-8 BOM for `-Encoding utf8`. Accept it
    // so a generated JobSpec can be submitted without an encoding conversion.
    let json = json.strip_prefix('\u{feff}').unwrap_or(json);
    let spec: JobSpec =
        serde_json::from_str(json).context("JobSpec is not valid cyc.dev/v1 JSON")?;
    spec.validate().context("JobSpec validation failed")?;
    Ok(spec)
}

async fn request_json(
    client: &Client,
    method: Method,
    base: &str,
    path: &str,
    body: Option<Value>,
    expected_version: Option<u64>,
    token: Option<&str>,
) -> Result<Value> {
    let mut request = client.request(method, format!("{base}{path}"));
    if let Some(token) = token {
        request = request.bearer_auth(token);
    }
    if let Some(version) = expected_version {
        request = request.header("if-match", format!("\"{version}\""));
    }
    if let Some(body) = body {
        request = request.json(&body);
    }
    let response = request
        .send()
        .await
        .with_context(|| format!("controller request to {path} failed"))?;
    let status = response.status();
    if !status.is_success() {
        // Never echo arbitrary response bodies: a remote endpoint could reflect a
        // malformed payload containing material that should stay out of logs.
        bail!("controller returned HTTP {status} for {path}");
    }
    response
        .json::<Value>()
        .await
        .with_context(|| format!("controller returned invalid JSON for {path}"))
}

/// Pairing bundles bypass the generic `serde_json::Value` response path so a
/// secret-bearing document can never become Debug-printable application data.
async fn request_enrollment_bundle(
    client: &Client,
    base: &str,
    path: &str,
    body: &CreatePairingRequestV1,
    operation_id: &str,
    token: Option<&str>,
) -> Result<EnrollmentBundleV1> {
    let mut request = client
        .post(format!("{base}{path}"))
        .header("idempotency-key", operation_id)
        .json(body);
    if let Some(token) = token {
        request = request.bearer_auth(token);
    }
    let response = request
        .send()
        .await
        .with_context(|| format!("controller request to {path} failed"))?;
    let status = response.status();
    if !status.is_success() {
        bail!("controller returned HTTP {status} for {path}");
    }
    let bundle = response
        .json::<EnrollmentBundleV1>()
        .await
        .with_context(|| format!("controller returned invalid enrollment JSON for {path}"))?;
    bundle
        .validate()
        .context("controller returned an invalid enrollment bundle")?;
    Ok(bundle)
}

async fn request_pairing_status(
    client: &Client,
    base: &str,
    path: &str,
    token: Option<&str>,
) -> Result<PairingStatusV1> {
    let mut request = client.get(format!("{base}{path}"));
    if let Some(token) = token {
        request = request.bearer_auth(token);
    }
    let response = request
        .send()
        .await
        .with_context(|| format!("controller request to {path} failed"))?;
    let http_status = response.status();
    if !http_status.is_success() {
        bail!("controller returned HTTP {http_status} for {path}");
    }
    let status = response
        .json::<PairingStatusV1>()
        .await
        .with_context(|| format!("controller returned invalid pairing status JSON for {path}"))?;
    status
        .validate()
        .context("controller returned an inconsistent pairing status")?;
    Ok(status)
}

async fn request_bytes(
    client: &Client,
    base: &str,
    path: &str,
    token: Option<&str>,
) -> Result<Vec<u8>> {
    let mut request = client.get(format!("{base}{path}"));
    if let Some(token) = token {
        request = request.bearer_auth(token);
    }
    let response = request
        .send()
        .await
        .with_context(|| format!("controller request to {path} failed"))?;
    let status = response.status();
    if !status.is_success() {
        bail!("controller returned HTTP {status} for {path}");
    }
    Ok(response
        .bytes()
        .await
        .with_context(|| format!("controller response body for {path} failed"))?
        .to_vec())
}

fn write_secret_json(path: &PathBuf, value: &EnrollmentBundleV1) -> Result<()> {
    let mut bytes = serde_json::to_vec_pretty(value)?;
    let result = write_secret_file(path, &bytes);
    bytes.fill(0);
    result
}

#[cfg(unix)]
fn write_secret_file(path: &PathBuf, bytes: &[u8]) -> Result<()> {
    use std::io::Write;
    use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};

    let parent = path
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .context("--output must include a private parent directory")?;
    if !parent.exists() {
        let mut builder = std::fs::DirBuilder::new();
        builder.recursive(true).mode(0o700).create(parent)?;
    }
    let metadata = std::fs::symlink_metadata(parent)?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() || metadata.mode() & 0o077 != 0 {
        bail!("pairing bundle parent must be a non-link directory with mode 0700 or stricter");
    }
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .with_context(|| format!("failed to create pairing bundle {}", path.display()))?;
    file.write_all(bytes)?;
    file.sync_all()?;
    Ok(())
}

#[cfg(windows)]
fn write_secret_file(path: &PathBuf, bytes: &[u8]) -> Result<()> {
    use std::io::Write;

    let parent = path
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .context("--output must include a private parent directory")?;
    let parent_existed = parent.exists();
    std::fs::create_dir_all(parent)?;
    if parent_existed {
        // An arbitrary pre-existing directory must never be silently rewritten
        // (for example, a user's Desktop). Require it to already be private.
        verify_windows_secret_acl(parent)
            .context("pairing-bundle parent directory is not private")?;
    } else if let Err(error) = replace_windows_secret_acl(parent) {
        let _ = std::fs::remove_dir(parent);
        return Err(error).context("failed to secure the new pairing-bundle directory");
    }
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .with_context(|| format!("failed to create pairing bundle {}", path.display()))?;
    file.write_all(bytes)?;
    file.sync_all()?;
    drop(file);

    if let Err(error) = replace_windows_secret_acl(path) {
        let _ = std::fs::remove_file(path);
        return Err(error);
    }
    Ok(())
}

#[cfg(windows)]
fn current_windows_user_sid() -> Result<String> {
    use std::process::Command;

    let identity = Command::new("whoami.exe")
        .args(["/user", "/fo", "csv", "/nh"])
        .output()
        .context("failed to query the current Windows SID")?;
    if !identity.status.success() {
        bail!("failed to query the current Windows SID");
    }
    let identity = String::from_utf8_lossy(&identity.stdout);
    let sid = identity
        .split(|character: char| character == ',' || character == '"' || character.is_whitespace())
        .find(|field| {
            field.starts_with("S-1-")
                && field
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || byte == b'S' || byte == b'-')
        })
        .context("whoami did not return a Windows SID")?;
    Ok(sid.to_owned())
}

#[cfg(windows)]
fn replace_windows_secret_acl(path: &Path) -> Result<()> {
    use std::process::Command;

    let sid = current_windows_user_sid()?;
    let hardening = Command::new("powershell.exe")
        .args([
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            WINDOWS_SECRET_ACL_SCRIPT,
        ])
        .env("CYC_SECRET_ACL_PATH", path)
        .env("CYC_SECRET_ACL_SID", sid)
        .env("CYC_SECRET_ACL_ACTION", "apply")
        .output()
        .context("failed to launch pairing-bundle ACL hardening")?;
    if !hardening.status.success() {
        bail!("failed to replace and verify the pairing-bundle DACL");
    }
    Ok(())
}

#[cfg(windows)]
fn verify_windows_secret_acl(path: &Path) -> Result<()> {
    use std::process::Command;

    let sid = current_windows_user_sid()?;
    let verification = Command::new("powershell.exe")
        .args([
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            WINDOWS_SECRET_ACL_SCRIPT,
        ])
        .env("CYC_SECRET_ACL_PATH", path)
        .env("CYC_SECRET_ACL_SID", sid)
        .env("CYC_SECRET_ACL_ACTION", "verify")
        .output()
        .context("failed to launch pairing-bundle ACL verification")?;
    if !verification.status.success() {
        bail!("pairing-bundle DACL contains an unexpected access rule");
    }
    Ok(())
}

#[cfg(windows)]
const WINDOWS_SECRET_ACL_SCRIPT: &str = r#"
$ErrorActionPreference = 'Stop'
try {
    $path = [Environment]::GetEnvironmentVariable('CYC_SECRET_ACL_PATH')
    $sidText = [Environment]::GetEnvironmentVariable('CYC_SECRET_ACL_SID')
    $action = [Environment]::GetEnvironmentVariable('CYC_SECRET_ACL_ACTION')
    if ([string]::IsNullOrWhiteSpace($path) -or [string]::IsNullOrWhiteSpace($sidText)) {
        throw 'missing ACL input'
    }
    $user = [System.Security.Principal.SecurityIdentifier]::new($sidText)
    $system = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $isDirectory = [System.IO.Directory]::Exists($path)
    $isFile = [System.IO.File]::Exists($path)
    if (-not $isDirectory -and -not $isFile) { throw 'ACL target does not exist' }
    $item = if ($isDirectory) {
        [System.IO.DirectoryInfo]::new($path)
    } else {
        [System.IO.FileInfo]::new($path)
    }
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'ACL target is a reparse point'
    }
    $expectedInheritance = if ($isDirectory) {
        [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
            [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    } else {
        [System.Security.AccessControl.InheritanceFlags]::None
    }
    if ($action -eq 'apply') {
        $replacement = if ($isDirectory) {
            [System.Security.AccessControl.DirectorySecurity]::new()
        } else {
            [System.Security.AccessControl.FileSecurity]::new()
        }
        $replacement.SetOwner($user)
        $replacement.SetAccessRuleProtection($true, $false)
        foreach ($principal in @($user, $system)) {
            $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                $principal,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                $expectedInheritance,
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow)
            [void]$replacement.AddAccessRule($rule)
        }
        if ($null -ne $item.PSObject.Methods['SetAccessControl']) {
            $item.SetAccessControl($replacement)
        } elseif ($isDirectory) {
            [System.IO.FileSystemAclExtensions]::SetAccessControl(
                [System.IO.DirectoryInfo]$item,
                [System.Security.AccessControl.DirectorySecurity]$replacement)
        } else {
            [System.IO.FileSystemAclExtensions]::SetAccessControl(
                [System.IO.FileInfo]$item,
                [System.Security.AccessControl.FileSecurity]$replacement)
        }
    } elseif ($action -ne 'verify') {
        throw 'invalid ACL action'
    }

    $acl = if ($null -ne $item.PSObject.Methods['GetAccessControl']) {
        $item.GetAccessControl()
    } elseif ($isDirectory) {
        [System.IO.FileSystemAclExtensions]::GetAccessControl([System.IO.DirectoryInfo]$item)
    } else {
        [System.IO.FileSystemAclExtensions]::GetAccessControl([System.IO.FileInfo]$item)
    }
    if (-not $acl.AreAccessRulesProtected) { throw 'DACL inheritance remains enabled' }
    $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    if ($owner -ne $sidText) { throw 'unexpected owner' }
    $rules = @($acl.GetAccessRules(
        $true, $true, [System.Security.Principal.SecurityIdentifier]))
    if ($rules.Count -ne 2) { throw 'unexpected ACE count' }
    $expected = @{$sidText = $false; 'S-1-5-18' = $false}
    foreach ($rule in $rules) {
        $ruleSid = $rule.IdentityReference.Value
        if (-not $expected.ContainsKey($ruleSid) -or $expected[$ruleSid]) {
            throw 'unexpected or duplicate principal'
        }
        if ($rule.IsInherited -or
            $rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or
            $rule.InheritanceFlags -ne $expectedInheritance -or
            $rule.PropagationFlags -ne [System.Security.AccessControl.PropagationFlags]::None -or
            $rule.FileSystemRights -ne [System.Security.AccessControl.FileSystemRights]::FullControl) {
            throw 'unexpected access rule'
        }
        $expected[$ruleSid] = $true
    }
    if ($expected.Values -contains $false) { throw 'required principal missing' }
} catch {
    [Console]::Error.WriteLine('pairing-bundle ACL operation failed')
    exit 1
}
"#;

#[cfg(not(any(unix, windows)))]
fn write_secret_file(path: &PathBuf, bytes: &[u8]) -> Result<()> {
    write_new_file(path, bytes)
}

fn write_new_file(path: &PathBuf, bytes: &[u8]) -> Result<()> {
    use std::io::Write;

    if let Some(parent) = path.parent().filter(|path| !path.as_os_str().is_empty()) {
        std::fs::create_dir_all(parent)?;
    }
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .with_context(|| format!("failed to create output file {}", path.display()))?;
    file.write_all(bytes)?;
    file.sync_all()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::{Command, CommandFactory};

    fn enrollment_bundle() -> EnrollmentBundleV1 {
        serde_json::from_value(serde_json::json!({
            "apiVersion": cyc_protocol::onboarding::ENROLLMENT_API_VERSION,
            "pairingId": "00000000-0000-0000-0000-000000000001",
            "controllerId": "00000000-0000-0000-0000-000000000002",
            "intendedNodeId": "00000000-0000-0000-0000-000000000003",
            "workerUrl": "https://192.0.2.10:47832",
            "certificatePem": "-----BEGIN CERTIFICATE-----\nAA==\n-----END CERTIFICATE-----\n",
            "pairingCode": "0123456789abcdef0123456789abcdef",
            "createdAt": "2026-08-22T00:00:00Z",
            "expiresAt": "2026-08-22T00:10:00Z"
        }))
        .unwrap()
    }

    fn all_long_options(command: &Command, output: &mut Vec<String>) {
        for arg in command.get_arguments() {
            if let Some(long) = arg.get_long() {
                output.push(long.to_owned());
            }
        }
        for subcommand in command.get_subcommands() {
            all_long_options(subcommand, output);
        }
    }

    #[test]
    fn command_definition_is_valid() {
        Cli::command().debug_assert();
    }

    #[test]
    fn cli_has_no_secret_bearing_options() {
        let mut options = Vec::new();
        all_long_options(&Cli::command(), &mut options);
        let joined = options.join(" ").to_ascii_lowercase();
        assert!(options.iter().any(|option| option == "token-file"));
        for forbidden in ["password", "secret", "credential"] {
            assert!(
                !joined.contains(forbidden),
                "forbidden CLI option: {forbidden}"
            );
        }
        // Identity verification accepts a private-key *path*, never key material.
        assert!(options.iter().any(|option| option == "private-key"));
        assert!(Cli::try_parse_from(["cyc", "--token", "raw-secret", "health"]).is_err());
    }

    #[test]
    fn parses_packaging_identity_contract() {
        let init = Cli::try_parse_from([
            "cyc",
            "identity",
            "init",
            "--output-dir",
            "/private/controller",
            "--host",
            "192.0.2.10",
        ]);
        assert!(init.is_ok());

        let verify = Cli::try_parse_from([
            "cyc",
            "identity",
            "verify",
            "--certificate",
            "/private/controller/controller.crt.pem",
            "--private-key",
            "/private/controller/controller.key.pem",
            "--host",
            "192.0.2.10",
            "--json",
        ]);
        assert!(verify.is_ok());
    }

    #[test]
    fn normalizes_controller_url() {
        assert_eq!(
            normalize_base_url("http://127.0.0.1:47831/").unwrap(),
            DEFAULT_CONTROLLER
        );
        assert!(normalize_base_url("127.0.0.1:47831").is_err());
        assert!(normalize_base_url("https://attacker.example:47831").is_err());
        assert!(normalize_base_url("http://user:password@127.0.0.1:47831").is_err());
    }

    #[test]
    fn accepts_windows_utf8_bom_job_files() {
        let json = concat!(
            "\u{feff}",
            r#"{"apiVersion":"cyc.dev/v1","id":"00000000-0000-0000-0000-000000000123","kind":"build","source":{"type":"git","repository":"https://example.invalid/repository.git","revision":"0123456789abcdef0123456789abcdef01234567"},"requirements":{},"steps":[{"name":"build","script":"cargo build"}],"artifacts":{},"placementPolicy":"balanced"}"#
        );
        assert!(parse_job_spec(json).is_ok());
    }

    #[test]
    fn pairing_bundle_uses_the_shared_strict_contract() {
        let enrollment = enrollment_bundle();
        enrollment.validate().unwrap();
        let value = serde_json::to_value(&enrollment).unwrap();
        assert_eq!(
            value["apiVersion"],
            cyc_protocol::onboarding::ENROLLMENT_API_VERSION
        );
        assert_eq!(
            value["intendedNodeId"],
            enrollment.intended_node_id.to_string()
        );
        assert!(serde_json::from_value::<EnrollmentBundleV1>(serde_json::json!({})).is_err());
    }

    #[test]
    fn snapshot_pack_is_reproducible_and_excludes_secrets_caches_and_links() {
        let temporary = tempfile::tempdir().unwrap();
        let source = temporary.path().join("source");
        fs::create_dir_all(source.join("nested")).unwrap();
        fs::create_dir_all(source.join(".git")).unwrap();
        fs::write(source.join("nested/input.txt"), b"stable bytes\n").unwrap();
        fs::write(source.join(".git/config"), b"must not ship\n").unwrap();
        for relative in [
            ".EnV.PROD",
            "server.PEM",
            "private.Key",
            "id_RSA_backup",
            "id_ED25519-old",
            "Credentials.json",
            "Secrets.toml",
        ] {
            fs::write(source.join(relative), b"must not ship\n").unwrap();
        }
        for relative in [".SSH", ".Aws", ".AZURE", ".Codex", "node_modules", "TARGET"] {
            fs::create_dir_all(source.join(relative)).unwrap();
            fs::write(
                source.join(relative).join("payload.txt"),
                b"must not ship\n",
            )
            .unwrap();
        }
        #[cfg(unix)]
        std::os::unix::fs::symlink(
            temporary.path().join("outside.txt"),
            source.join("outside-link"),
        )
        .unwrap();
        let first = temporary.path().join("first.tar.zst");
        let second = temporary.path().join("second.tar.zst");
        let first_meta = pack_snapshot(&source, &first, MAX_SNAPSHOT_ARCHIVE_BYTES).unwrap();
        let second_meta = pack_snapshot(&source, &second, MAX_SNAPSHOT_ARCHIVE_BYTES).unwrap();
        assert_eq!(fs::read(&first).unwrap(), fs::read(&second).unwrap());
        assert_eq!(first_meta["digest"], second_meta["digest"]);

        let decoder = zstd::stream::read::Decoder::new(fs::File::open(&first).unwrap()).unwrap();
        let mut archive = tar::Archive::new(decoder);
        let paths = archive
            .entries()
            .unwrap()
            .map(|entry| {
                entry
                    .unwrap()
                    .path()
                    .unwrap()
                    .to_string_lossy()
                    .replace('\\', "/")
            })
            .collect::<Vec<_>>();
        assert!(paths.iter().any(|path| path == "nested/input.txt"));
        for denied in [
            ".git",
            ".env",
            ".pem",
            ".key",
            "id_rsa",
            "id_ed25519",
            "credentials",
            "secrets",
            ".ssh",
            ".aws",
            ".azure",
            ".codex",
            "node_modules",
            "target",
        ] {
            assert!(
                !paths
                    .iter()
                    .any(|path| path.to_ascii_lowercase().contains(denied)),
                "sensitive snapshot entry survived: {denied}: {paths:?}"
            );
        }
        assert!(!paths.iter().any(|path| path == "outside-link"));

        let rejected = temporary.path().join("too-small.tar.zst");
        assert!(pack_snapshot(&source, &rejected, 1).is_err());
        assert!(!rejected.exists());
    }

    #[cfg(unix)]
    #[test]
    fn pairing_bundle_output_creates_or_requires_a_private_parent() {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};

        let temporary = tempfile::tempdir().unwrap();
        let private_output = temporary.path().join("new-private").join("pairing.json");
        write_secret_json(&private_output, &enrollment_bundle()).unwrap();
        assert_eq!(
            std::fs::metadata(private_output.parent().unwrap())
                .unwrap()
                .mode()
                & 0o777,
            0o700
        );
        assert_eq!(
            std::fs::metadata(&private_output).unwrap().mode() & 0o777,
            0o600
        );

        let public_parent = temporary.path().join("public");
        std::fs::create_dir(&public_parent).unwrap();
        std::fs::set_permissions(&public_parent, std::fs::Permissions::from_mode(0o755)).unwrap();
        let rejected = public_parent.join("pairing.json");
        assert!(write_secret_json(&rejected, &enrollment_bundle()).is_err());
        assert!(!rejected.exists());
    }

    #[cfg(windows)]
    #[test]
    fn pairing_bundle_acl_repair_removes_explicit_everyone_allow() {
        use std::process::Command;

        let temporary = tempfile::tempdir().unwrap();
        let private_parent = temporary.path().join("private");
        let output = private_parent.join("pairing.json");
        write_secret_json(&output, &enrollment_bundle()).unwrap();
        verify_windows_secret_acl(&private_parent).unwrap();
        verify_windows_secret_acl(&output).unwrap();

        let parent_injected = Command::new("icacls.exe")
            .arg(&private_parent)
            .args(["/grant", "*S-1-1-0:(OI)(CI)(R)"])
            .status()
            .unwrap();
        assert!(parent_injected.success());
        let file_injected = Command::new("icacls.exe")
            .arg(&output)
            .args(["/grant", "*S-1-1-0:(R)"])
            .status()
            .unwrap();
        assert!(file_injected.success());
        assert!(verify_windows_secret_acl(&private_parent).is_err());
        assert!(verify_windows_secret_acl(&output).is_err());
        replace_windows_secret_acl(&private_parent).unwrap();
        replace_windows_secret_acl(&output).unwrap();
        verify_windows_secret_acl(&private_parent).unwrap();
        verify_windows_secret_acl(&output).unwrap();

        let public_parent = temporary.path().join("public");
        std::fs::create_dir(&public_parent).unwrap();
        let rejected = public_parent.join("pairing.json");
        assert!(write_secret_json(&rejected, &enrollment_bundle()).is_err());
        assert!(!rejected.exists());
    }
}
