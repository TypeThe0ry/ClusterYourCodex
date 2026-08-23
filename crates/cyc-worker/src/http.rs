use std::io::Cursor;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use anyhow::{bail, Context, Result};
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use cyc_protocol::worker::{
    ClaimAssignment, ClaimRequest, ClaimResponse, HeartbeatRequest, HeartbeatResponse,
    NodeReportRequest, PairAckRequest, PairAckResponse, PairRequest, PairResponse, RunCompletion,
    RunStreamsEvidence, StateUpdate, StateUpdateResponse, StreamEvidence, ARTIFACT_NAME_HEADER,
    LEASE_ID_HEADER, LOG_OFFSET_HEADER, LOG_STREAM_HEADER, NODE_REPORT_ACCEPTED_HEADER,
    NODE_REPORT_BOOT_GENERATION_HEADER, NODE_REPORT_INVENTORY_REVISION_HEADER,
    NODE_REPORT_SEQUENCE_HEADER, PAIR_AUTH_SCHEME, RUN_CREDENTIAL_HEADER, SHA256_HEADER,
    WORKER_AUTH_SCHEME,
};
use cyc_protocol::{
    CleanupReceiptV1, JobState, TerminalCompletionAckV1, COMPLETION_ACKNOWLEDGED_AT_HEADER,
    COMPLETION_SHA256_HEADER, MAX_SNAPSHOT_ARCHIVE_BYTES, SNAPSHOT_API_VERSION,
    SNAPSHOT_MEDIA_TYPE,
};
use reqwest::header::{HeaderValue, AUTHORIZATION, CONTENT_LENGTH, CONTENT_TYPE};
use reqwest::{Client, Response, StatusCode, Url};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::client::WebPkiServerVerifier;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, RootCertStore, SignatureScheme};
use serde::de::DeserializeOwned;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::artifacts::{read_regular_file_no_follow, ArtifactEvidence};
use crate::config::{
    validate_enrollment_bundle, validate_https_url, EnrollmentBundle, WorkerConfig,
};
use crate::process::{LogBudget, LogChunk, LogSink, LogStream};
use crate::security::SecretString;

const MAX_RESPONSE_BYTES: usize = 1024 * 1024;
const MAX_LOG_CHUNK_BYTES: usize = 1024 * 1024;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VersionConflict {
    pub current_version: u64,
    pub cancel_requested: bool,
    pub current_state: Option<JobState>,
}

impl std::fmt::Display for VersionConflict {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "worker API version conflict at version {} (cancelRequested={}, currentState={:?})",
            self.current_version, self.cancel_requested, self.current_state
        )
    }
}

impl std::error::Error for VersionConflict {}

#[derive(Clone, Debug, Eq, PartialEq)]
struct RetryableHttpError {
    status: StatusCode,
    code: String,
}

impl std::fmt::Display for RetryableHttpError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "worker API transient HTTP {} ({})",
            self.status, self.code
        )
    }
}

impl std::error::Error for RetryableHttpError {}

/// Structured non-retryable controller response.  Pairing recovery consumes
/// the code through this type rather than scraping a formatted anyhow message.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct WorkerApiHttpError {
    status: StatusCode,
    code: String,
}

impl WorkerApiHttpError {
    pub(crate) fn code(&self) -> &str {
        &self.code
    }

    #[cfg(test)]
    fn status(&self) -> StatusCode {
        self.status
    }
}

impl std::fmt::Display for WorkerApiHttpError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "worker API returned HTTP {} ({})",
            self.status, self.code
        )
    }
}

impl std::error::Error for WorkerApiHttpError {}

pub(crate) fn pairing_terminal_code(error: &anyhow::Error) -> Option<&str> {
    let code = error
        .chain()
        .find_map(|source| source.downcast_ref::<WorkerApiHttpError>())?
        .code();
    matches!(
        code,
        "pairing_unavailable" | "pairing_binding_mismatch" | "pairing_ack_unauthorized"
    )
    .then_some(code)
}

#[cfg(test)]
pub(crate) fn test_worker_api_error(status: StatusCode, code: &str) -> anyhow::Error {
    anyhow::Error::new(WorkerApiHttpError {
        status,
        code: code.to_owned(),
    })
}

/// True only for errors where replaying an idempotent request with identical
/// bytes is safe: transport loss/timeouts and HTTP 5xx responses.
pub(crate) fn is_retryable_transport_error(error: &anyhow::Error) -> bool {
    if error.downcast_ref::<RetryableHttpError>().is_some() {
        return true;
    }
    error.chain().any(|source| {
        source
            .downcast_ref::<reqwest::Error>()
            .is_some_and(|error| {
                error.is_timeout() || error.is_connect() || error.is_body() || error.is_request()
            })
    })
}

pub struct ClaimResult {
    pub assignment: Option<ClaimAssignment>,
    pub run_credential: Option<SecretString>,
    pub retry_after_seconds: u32,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LogChunkResponse {
    run_id: Uuid,
    stream: String,
    offset: u64,
    length: u64,
    sha256: String,
}

pub struct WorkerClient {
    client: Client,
    worker_url: Url,
    node_credential: SecretString,
    control_timeout: Duration,
}

impl WorkerClient {
    pub fn from_config(config: &WorkerConfig) -> Result<Self> {
        Ok(Self {
            client: build_tls_client(&config.certificate_pem)?,
            worker_url: validate_https_url(&config.worker_url)?,
            node_credential: config.load_credential()?,
            control_timeout: control_request_timeout(config)?,
        })
    }

    pub async fn pair(bundle: &EnrollmentBundle, request: &PairRequest) -> Result<PairResponse> {
        validate_enrollment_bundle(bundle)?;
        request.validate().context("validate pair request")?;
        let client = build_tls_client(&bundle.certificate_pem)?;
        let worker_url = validate_https_url(&bundle.worker_url)?;
        let mut authorization = HeaderValue::from_str(&format!(
            "{} {}",
            PAIR_AUTH_SCHEME,
            bundle.pairing_code.trim()
        ))
        .context("pairing code cannot be represented in an HTTP header")?;
        authorization.set_sensitive(true);
        let response = client
            .post(endpoint(&worker_url, "pair")?)
            .header(AUTHORIZATION, authorization)
            .json(request)
            .send()
            .await
            .context("send worker pairing request")?;
        let response: PairResponse = decode_json(response).await?;
        response.validate().context("validate pairing response")?;
        if bundle.controller_id != response.controller_id {
            bail!("pairing response controllerId does not match enrollment bundle");
        }
        if bundle.intended_node_id != response.node_id {
            bail!("pairing response nodeId does not match enrollment intendedNodeId");
        }
        if bundle.pairing_id != response.pairing_id {
            bail!("pairing response pairingId does not match enrollment bundle");
        }
        if request.credential_sha256 != response.credential_sha256 {
            bail!("pairing response credentialSha256 does not match staged credential");
        }
        Ok(response)
    }

    pub async fn acknowledge_pairing(&self, request: &PairAckRequest) -> Result<PairAckResponse> {
        request
            .validate()
            .context("validate pairing acknowledgement")?;
        let response = self
            .authorized(self.client.post(endpoint(&self.worker_url, "pair/ack")?))?
            .json(request)
            .send()
            .await
            .context("send pairing acknowledgement")?;
        let response: PairAckResponse = decode_json(response).await?;
        response
            .validate()
            .context("validate pairing acknowledgement response")?;
        if response.pairing_id != request.pairing_id
            || response.node_id != request.node_id
            || response.credential_sha256 != request.credential_sha256
        {
            bail!("pairing acknowledgement response changed the immutable binding");
        }
        Ok(response)
    }

    pub async fn claim(&self, request: &ClaimRequest) -> Result<ClaimResult> {
        request.validate().context("validate claim request")?;
        let response = self
            .authorized(self.client.post(endpoint(&self.worker_url, "claim")?))?
            .json(request)
            .send()
            .await
            .context("send worker claim request")?;
        if response.status() == StatusCode::NO_CONTENT {
            return Ok(ClaimResult {
                assignment: None,
                run_credential: None,
                retry_after_seconds: response
                    .headers()
                    .get("retry-after")
                    .and_then(|value| value.to_str().ok())
                    .and_then(|value| value.parse().ok())
                    .unwrap_or(2),
            });
        }
        let run_credential = response
            .headers()
            .get(RUN_CREDENTIAL_HEADER)
            .map(|value| {
                value
                    .to_str()
                    .context("run credential response header is not ASCII")
                    .and_then(|value| SecretString::new(value.to_owned()))
            })
            .transpose()?;
        let status = response.status();
        if response
            .headers()
            .get(CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .is_none_or(|value| !value.eq_ignore_ascii_case("application/json"))
        {
            bail!("claim response must use Content-Type application/json");
        }
        let bytes = bounded_body(response).await?;
        if !status.is_success() {
            return Err(http_status_error(status, &bytes));
        }
        let response: ClaimResponse =
            serde_json::from_slice(&bytes).context("decode ClaimResponse")?;
        let assignment = response.assignment;
        let retry_after_seconds = response.retry_after_seconds;
        if let Some(assignment) = &assignment {
            assignment.validate().context("validate assignment")?;
            if run_credential.is_none() {
                bail!("claim response omitted the one-time run credential header");
            }
        } else if run_credential.is_some() {
            bail!("claim response issued a run credential without an assignment");
        }
        Ok(ClaimResult {
            assignment,
            run_credential,
            retry_after_seconds,
        })
    }

    /// Publish worker-owned inventory and telemetry independently of claim or
    /// run lease heartbeats. Authentication, not the body, binds the node.
    pub async fn node_report(&self, request: &NodeReportRequest) -> Result<bool> {
        request.validate().context("validate node report request")?;
        let response = self
            .authorized(self.client.post(endpoint(&self.worker_url, "node-report")?))?
            .json(request)
            .send()
            .await
            .context("send worker node report")?;
        let status = response.status();
        if status == StatusCode::NO_CONTENT {
            let accepted =
                parse_node_report_accepted(response.headers().get(NODE_REPORT_ACCEPTED_HEADER))?;
            let _inventory_revision = parse_u64_response_header(
                response
                    .headers()
                    .get(NODE_REPORT_INVENTORY_REVISION_HEADER),
                NODE_REPORT_INVENTORY_REVISION_HEADER,
            )?;
            let boot_generation = parse_u64_response_header(
                response.headers().get(NODE_REPORT_BOOT_GENERATION_HEADER),
                NODE_REPORT_BOOT_GENERATION_HEADER,
            )?;
            let sequence = parse_u64_response_header(
                response.headers().get(NODE_REPORT_SEQUENCE_HEADER),
                NODE_REPORT_SEQUENCE_HEADER,
            )?;
            if accepted
                && (boot_generation != request.telemetry.boot_generation
                    || sequence != request.telemetry.sequence)
            {
                bail!(
                    "accepted node-report receipt does not match the submitted generation/sequence"
                );
            }
            return Ok(accepted);
        }
        let bytes = bounded_body(response).await?;
        if !status.is_success() {
            return Err(http_status_error(status, &bytes));
        }
        bail!("worker node-report endpoint must return HTTP 204 No Content")
    }

    pub fn run_session(
        self: &Arc<Self>,
        assignment: &ClaimAssignment,
        run_credential: SecretString,
    ) -> RunSession {
        RunSession {
            worker: self.clone(),
            run_id: assignment.run_id,
            lease_id: assignment.lease_id,
            run_credential,
        }
    }

    fn authorized(&self, builder: reqwest::RequestBuilder) -> Result<reqwest::RequestBuilder> {
        let mut authorization = HeaderValue::from_str(&format!(
            "{} {}",
            WORKER_AUTH_SCHEME,
            self.node_credential.expose()
        ))
        .context("worker credential cannot be represented in an HTTP header")?;
        authorization.set_sensitive(true);
        Ok(builder.header(AUTHORIZATION, authorization))
    }
}

fn parse_node_report_accepted(value: Option<&HeaderValue>) -> Result<bool> {
    let value = value
        .context("worker node-report response omitted x-cyc-report-accepted")?
        .to_str()
        .context("worker node-report acceptance header is not ASCII")?;
    match value {
        "true" => Ok(true),
        "false" => Ok(false),
        _ => bail!("worker node-report acceptance header must be `true` or `false`"),
    }
}

fn parse_u64_response_header(value: Option<&HeaderValue>, name: &str) -> Result<u64> {
    value
        .with_context(|| format!("worker node-report response omitted {name}"))?
        .to_str()
        .with_context(|| format!("worker node-report {name} header is not ASCII"))?
        .parse::<u64>()
        .with_context(|| format!("worker node-report {name} header is not an unsigned integer"))
}

pub struct RunSession {
    worker: Arc<WorkerClient>,
    run_id: Uuid,
    lease_id: Uuid,
    run_credential: SecretString,
}

impl RunSession {
    pub async fn download_snapshot(&self, digest: &str, size_bytes: u64) -> Result<Vec<u8>> {
        cyc_protocol::validate_snapshot_digest(digest).context("validate snapshot digest")?;
        cyc_protocol::validate_snapshot_size(size_bytes).context("validate snapshot size")?;
        for attempt in 0..3 {
            match self.download_snapshot_once(digest, size_bytes).await {
                Ok(bytes) => return Ok(bytes),
                Err(error) if is_retryable_transport_error(&error) && attempt < 2 => {
                    tokio::time::sleep(Duration::from_millis(200 * (attempt + 1) as u64)).await;
                }
                Err(error) => return Err(error),
            }
        }
        unreachable!("bounded snapshot retry loop always returns")
    }

    async fn download_snapshot_once(&self, digest: &str, size_bytes: u64) -> Result<Vec<u8>> {
        let sha256 =
            cyc_protocol::snapshot_digest_hex(digest).context("validate snapshot digest")?;
        let endpoint = format!("source/{sha256}");
        let mut response = self
            .run_authorized(self.worker.client.get(run_endpoint(
                &self.worker.worker_url,
                self.run_id,
                &endpoint,
            )?))?
            .send()
            .await
            .context("download assigned snapshot")?;
        let status = response.status();
        if !status.is_success() {
            let bytes = bounded_body(response).await?;
            return Err(http_status_error(status, &bytes));
        }
        let content_type = response
            .headers()
            .get(CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.split(';').next())
            .map(str::trim);
        if !content_type.is_some_and(|value| value.eq_ignore_ascii_case(SNAPSHOT_MEDIA_TYPE)) {
            bail!("snapshot response has an invalid Content-Type");
        }
        let content_length = response
            .headers()
            .get(CONTENT_LENGTH)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.parse::<u64>().ok());
        if content_length != Some(size_bytes) {
            bail!("snapshot response Content-Length does not match assignment sizeBytes");
        }
        if response
            .headers()
            .get(SHA256_HEADER)
            .and_then(|value| value.to_str().ok())
            != Some(digest)
        {
            bail!("snapshot response digest header does not match the assignment");
        }
        if response
            .headers()
            .get("x-cyc-snapshot-version")
            .and_then(|value| value.to_str().ok())
            != Some(SNAPSHOT_API_VERSION)
        {
            bail!("snapshot response protocol version is unsupported");
        }

        let capacity = usize::try_from(size_bytes).context("snapshot size does not fit memory")?;
        let mut bytes = Vec::with_capacity(capacity);
        let mut hasher = Sha256::new();
        while let Some(chunk) = response.chunk().await.context("read snapshot body")? {
            let next = u64::try_from(bytes.len())
                .unwrap_or(u64::MAX)
                .saturating_add(u64::try_from(chunk.len()).unwrap_or(u64::MAX));
            if next > size_bytes || next > MAX_SNAPSHOT_ARCHIVE_BYTES {
                bail!("snapshot response exceeded the assigned bound");
            }
            hasher.update(&chunk);
            bytes.extend_from_slice(&chunk);
        }
        if u64::try_from(bytes.len()).unwrap_or(u64::MAX) != size_bytes {
            bail!("snapshot response ended before assignment sizeBytes");
        }
        let actual = format!("sha256:{}", hex::encode(hasher.finalize()));
        if actual != digest {
            bail!("snapshot response bytes do not match the assigned digest");
        }
        Ok(bytes)
    }

    pub async fn heartbeat(&self, request: &HeartbeatRequest) -> Result<HeartbeatResponse> {
        self.verify_binding(request.run_id, request.lease_id)?;
        request.validate().context("validate heartbeat request")?;
        let response = self
            .run_authorized(self.worker.client.post(run_endpoint(
                &self.worker.worker_url,
                self.run_id,
                "heartbeat",
            )?))?
            .json(request)
            .timeout(self.worker.control_timeout)
            .send()
            .await
            .context("send run heartbeat")?;
        decode_json(response).await
    }

    pub async fn state(&self, update: &StateUpdate) -> Result<StateUpdateResponse> {
        self.verify_binding(update.run_id, update.lease_id)?;
        update.validate().context("validate run state update")?;
        let response = self
            .run_authorized(self.worker.client.post(run_endpoint(
                &self.worker.worker_url,
                self.run_id,
                "state",
            )?))?
            .json(update)
            .timeout(self.worker.control_timeout)
            .send()
            .await
            .context("send run state update")?;
        decode_json(response).await
    }

    pub async fn complete(
        &self,
        completion: &RunCompletion,
    ) -> Result<(StateUpdateResponse, TerminalCompletionAckV1)> {
        self.verify_binding(completion.run_id, completion.lease_id)?;
        completion.validate().context("validate run completion")?;
        let response = self
            .run_authorized(self.worker.client.post(run_endpoint(
                &self.worker.worker_url,
                self.run_id,
                "complete",
            )?))?
            .json(completion)
            .timeout(self.worker.control_timeout)
            .send()
            .await
            .context("send run completion")?;
        let completion_sha256 = response
            .headers()
            .get(COMPLETION_SHA256_HEADER)
            .and_then(|value| value.to_str().ok())
            .map(str::to_owned);
        let acknowledged_at = response
            .headers()
            .get(COMPLETION_ACKNOWLEDGED_AT_HEADER)
            .and_then(|value| value.to_str().ok())
            .map(str::to_owned);
        let state: StateUpdateResponse = decode_json(response).await?;
        let ack = TerminalCompletionAckV1 {
            run_id: completion.run_id,
            lease_id: completion.lease_id,
            completion_sha256: completion_sha256
                .context("completion response omitted the terminal receipt digest")?,
            state_version: state.state_version,
            final_state: state.run.state,
            acknowledged_at: DateTime::parse_from_rfc3339(
                &acknowledged_at
                    .context("completion response omitted the acknowledgement timestamp")?,
            )
            .context("completion acknowledgement timestamp is invalid")?
            .with_timezone(&Utc),
        };
        ack.validate()
            .context("validate terminal completion acknowledgement")?;
        Ok((state, ack))
    }

    pub async fn cleanup(&self, receipt: &CleanupReceiptV1) -> Result<CleanupReceiptV1> {
        self.verify_binding(receipt.run_id, receipt.lease_id)?;
        receipt.validate().context("validate cleanup receipt")?;
        for attempt in 0..3 {
            let result = async {
                let response = self
                    .run_authorized(self.worker.client.post(run_endpoint(
                        &self.worker.worker_url,
                        self.run_id,
                        "cleanup",
                    )?))?
                    .json(receipt)
                    .send()
                    .await
                    .context("send cleanup receipt")?;
                let stored: CleanupReceiptV1 = decode_json(response).await?;
                if stored != *receipt {
                    bail!("controller cleanup acknowledgement changed the immutable receipt");
                }
                Ok(stored)
            }
            .await;
            match result {
                Ok(stored) => return Ok(stored),
                Err(error) if is_retryable_transport_error(&error) && attempt < 2 => {
                    tokio::time::sleep(Duration::from_millis(200 * (attempt + 1) as u64)).await;
                }
                Err(error) => return Err(error),
            }
        }
        unreachable!("bounded cleanup retry loop always returns")
    }

    pub async fn upload_artifact(&self, artifact: &ArtifactEvidence) -> Result<()> {
        if artifact.size_bytes > crate::artifacts::MAX_ARTIFACT_BYTES {
            bail!("artifact exceeds worker upload limit");
        }
        if !artifact.name.is_ascii() || artifact.name.chars().any(char::is_control) {
            bail!("artifact path must be printable ASCII for the current upload protocol");
        }
        let path = artifact.path.clone();
        let bytes = tokio::task::spawn_blocking(move || {
            read_regular_file_no_follow(&path, crate::artifacts::MAX_ARTIFACT_BYTES)
        })
        .await
        .context("artifact reader task panicked")??;
        if bytes.len() as u64 != artifact.size_bytes || sha256(&bytes) != artifact.sha256 {
            bail!("artifact changed after collection: {}", artifact.name);
        }
        let endpoint = format!("artifacts/{}", artifact.id);
        for attempt in 0..3 {
            let result = async {
                let response = self
                    .run_authorized(self.worker.client.post(run_endpoint(
                        &self.worker.worker_url,
                        self.run_id,
                        &endpoint,
                    )?))?
                    .header(CONTENT_TYPE, "application/octet-stream")
                    .header(ARTIFACT_NAME_HEADER, &artifact.name)
                    .header(SHA256_HEADER, &artifact.sha256)
                    .body(bytes.clone())
                    .send()
                    .await
                    .context("upload artifact")?;
                let uploaded: cyc_protocol::worker::ArtifactMetadata =
                    decode_json(response).await?;
                uploaded
                    .validate()
                    .context("validate artifact upload receipt")?;
                if uploaded.id != artifact.id
                    || uploaded.run_id != self.run_id
                    || uploaded.relative_path != artifact.name
                    || uploaded.size_bytes != artifact.size_bytes
                    || uploaded.sha256 != artifact.sha256
                {
                    bail!("controller artifact receipt does not match uploaded bytes");
                }
                Ok(())
            }
            .await;
            match result {
                Ok(()) => return Ok(()),
                Err(error) if is_retryable_transport_error(&error) && attempt < 2 => {
                    tokio::time::sleep(Duration::from_millis(200 * (attempt + 1) as u64)).await;
                }
                Err(error) => return Err(error),
            }
        }
        unreachable!("bounded artifact retry loop always returns")
    }

    async fn upload_log(&self, stream: LogStream, offset: u64, bytes: &[u8]) -> Result<()> {
        if bytes.is_empty() || bytes.len() > MAX_LOG_CHUNK_BYTES {
            bail!("log chunk size must be in 1..={MAX_LOG_CHUNK_BYTES}");
        }
        let digest = sha256(bytes);
        let bytes_len = bytes.len() as u64;
        for attempt in 0..3 {
            let result = async {
                let response = self
                    .run_authorized(self.worker.client.post(run_endpoint(
                        &self.worker.worker_url,
                        self.run_id,
                        "logs",
                    )?))?
                    .header(CONTENT_TYPE, "application/octet-stream")
                    .header(LOG_STREAM_HEADER, stream.as_header())
                    .header(LOG_OFFSET_HEADER, offset)
                    .header(SHA256_HEADER, &digest)
                    .body(bytes.to_vec())
                    .send()
                    .await
                    .context("upload run log chunk")?;
                let receipt: LogChunkResponse = decode_json(response).await?;
                if receipt.run_id != self.run_id
                    || receipt.stream != stream.as_header()
                    || receipt.offset != offset
                    || receipt.length != bytes_len
                    || receipt.sha256 != digest
                {
                    bail!("controller log receipt does not match uploaded chunk");
                }
                Ok(())
            }
            .await;
            match result {
                Ok(()) => return Ok(()),
                Err(error) if is_retryable_transport_error(&error) && attempt < 2 => {
                    tokio::time::sleep(Duration::from_millis(200 * (attempt + 1) as u64)).await;
                }
                Err(error) => return Err(error),
            }
        }
        unreachable!("bounded log retry loop always returns")
    }

    fn run_authorized(&self, builder: reqwest::RequestBuilder) -> Result<reqwest::RequestBuilder> {
        let builder = self.worker.authorized(builder)?;
        let mut run = HeaderValue::from_str(self.run_credential.expose())
            .context("run credential cannot be represented in an HTTP header")?;
        run.set_sensitive(true);
        Ok(builder
            .header(RUN_CREDENTIAL_HEADER, run)
            .header(LEASE_ID_HEADER, self.lease_id.to_string()))
    }

    fn verify_binding(&self, run_id: Uuid, lease_id: Uuid) -> Result<()> {
        if run_id != self.run_id || lease_id != self.lease_id {
            bail!("run request does not match the authenticated run session");
        }
        Ok(())
    }
}

pub struct HttpLogSink {
    session: Arc<RunSession>,
    stdout_offset: AtomicU64,
    stderr_offset: AtomicU64,
    stdout_chunks: AtomicU64,
    stderr_chunks: AtomicU64,
    stdout_hasher: Mutex<Sha256>,
    stderr_hasher: Mutex<Sha256>,
}

impl HttpLogSink {
    pub fn new(session: Arc<RunSession>) -> Self {
        Self {
            session,
            stdout_offset: AtomicU64::new(0),
            stderr_offset: AtomicU64::new(0),
            stdout_chunks: AtomicU64::new(0),
            stderr_chunks: AtomicU64::new(0),
            stdout_hasher: Mutex::new(Sha256::new()),
            stderr_hasher: Mutex::new(Sha256::new()),
        }
    }

    pub fn streams(&self, budget: &LogBudget) -> RunStreamsEvidence {
        RunStreamsEvidence {
            stdout: self.stream_evidence(LogStream::Stdout, budget),
            stderr: self.stream_evidence(LogStream::Stderr, budget),
        }
    }

    pub fn last_sequence(&self) -> Option<u64> {
        let count = self
            .stdout_chunks
            .load(Ordering::SeqCst)
            .saturating_add(self.stderr_chunks.load(Ordering::SeqCst));
        count.checked_sub(1)
    }

    fn stream_evidence(&self, stream: LogStream, budget: &LogBudget) -> StreamEvidence {
        let (byte_count, chunk_count, hasher) = match stream {
            LogStream::Stdout => (
                self.stdout_offset.load(Ordering::SeqCst),
                self.stdout_chunks.load(Ordering::SeqCst),
                &self.stdout_hasher,
            ),
            LogStream::Stderr => (
                self.stderr_offset.load(Ordering::SeqCst),
                self.stderr_chunks.load(Ordering::SeqCst),
                &self.stderr_hasher,
            ),
        };
        let sha256 = {
            let guard = hasher
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            hex::encode(guard.clone().finalize())
        };
        StreamEvidence {
            byte_count,
            sha256,
            truncated: budget.truncated(stream),
            chunk_count,
        }
    }
}

#[async_trait]
impl LogSink for HttpLogSink {
    async fn upload(&self, chunk: LogChunk) -> Result<()> {
        let offset = match chunk.stream {
            LogStream::Stdout => self.stdout_offset.load(Ordering::SeqCst),
            LogStream::Stderr => self.stderr_offset.load(Ordering::SeqCst),
        };
        let bytes = chunk.bytes;
        let length = bytes.len() as u64;
        self.session
            .upload_log(chunk.stream, offset, &bytes)
            .await?;
        match chunk.stream {
            LogStream::Stdout => {
                self.stdout_hasher
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .update(&bytes);
                self.stdout_chunks.fetch_add(1, Ordering::SeqCst);
                self.stdout_offset.fetch_add(length, Ordering::SeqCst)
            }
            LogStream::Stderr => {
                self.stderr_hasher
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .update(&bytes);
                self.stderr_chunks.fetch_add(1, Ordering::SeqCst);
                self.stderr_offset.fetch_add(length, Ordering::SeqCst)
            }
        };
        Ok(())
    }
}

fn control_request_timeout(config: &WorkerConfig) -> Result<Duration> {
    config.validate()?;
    let seconds = config.lease_seconds.saturating_sub(1).min(30);
    if seconds == 0 || seconds >= config.lease_seconds {
        bail!("control request timeout must be positive and strictly below leaseSeconds");
    }
    Ok(Duration::from_secs(seconds))
}

fn build_tls_client(certificate_pem: &str) -> Result<Client> {
    ensure_rustls_crypto_provider();
    let certificate = parse_single_certificate(certificate_pem)?;
    let mut roots = RootCertStore::empty();
    roots
        .add(certificate.clone())
        .context("trust enrollment certificate")?;
    let webpki = WebPkiServerVerifier::builder(Arc::new(roots))
        .build()
        .context("build enrollment certificate verifier")?;
    let verifier = Arc::new(ExactCertificateVerifier {
        webpki,
        certificate_sha256: Sha256::digest(certificate.as_ref()).into(),
    });
    let mut tls = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(verifier)
        .with_no_client_auth();
    tls.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
    Client::builder()
        .https_only(true)
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .use_preconfigured_tls(tls)
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(60))
        .build()
        .context("build exact-certificate-pinned worker HTTPS client")
}

fn parse_single_certificate(certificate_pem: &str) -> Result<CertificateDer<'static>> {
    let mut reader = Cursor::new(certificate_pem.as_bytes());
    let items = rustls_pemfile::read_all(&mut reader)
        .collect::<std::result::Result<Vec<_>, _>>()
        .context("parse enrollment certificatePem")?;
    let [rustls_pemfile::Item::X509Certificate(certificate)] = items.as_slice() else {
        bail!(
            "enrollment certificatePem must contain exactly one certificate and no other PEM items"
        );
    };
    Ok(certificate.clone())
}

#[derive(Debug)]
struct ExactCertificateVerifier {
    webpki: Arc<WebPkiServerVerifier>,
    certificate_sha256: [u8; 32],
}

impl ServerCertVerifier for ExactCertificateVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        server_name: &ServerName<'_>,
        ocsp_response: &[u8],
        now: UnixTime,
    ) -> std::result::Result<ServerCertVerified, rustls::Error> {
        let verified = self.webpki.verify_server_cert(
            end_entity,
            intermediates,
            server_name,
            ocsp_response,
            now,
        )?;
        let actual: [u8; 32] = Sha256::digest(end_entity.as_ref()).into();
        if actual != self.certificate_sha256 {
            return Err(rustls::Error::General(
                "server certificate did not match enrollment pin".to_owned(),
            ));
        }
        Ok(verified)
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        certificate: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> std::result::Result<HandshakeSignatureValid, rustls::Error> {
        self.webpki
            .verify_tls12_signature(message, certificate, signature)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        certificate: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> std::result::Result<HandshakeSignatureValid, rustls::Error> {
        self.webpki
            .verify_tls13_signature(message, certificate, signature)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.webpki.supported_verify_schemes()
    }
}

fn ensure_rustls_crypto_provider() {
    static PROVIDER: OnceLock<()> = OnceLock::new();
    PROVIDER.get_or_init(|| {
        // A workspace-wide build can unify rustls' ring and aws-lc features.
        // Installing one provider explicitly keeps the worker deterministic
        // instead of relying on rustls' feature-based auto-selection.
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
}

fn endpoint(base: &Url, action: &str) -> Result<Url> {
    base.join(&format!("/worker/v1/{action}"))
        .context("build worker endpoint URL")
}

fn run_endpoint(base: &Url, run_id: Uuid, action: &str) -> Result<Url> {
    base.join(&format!("/worker/v1/runs/{run_id}/{action}"))
        .context("build worker run endpoint URL")
}

async fn decode_json<T: DeserializeOwned>(response: Response) -> Result<T> {
    let status = response.status();
    if response
        .headers()
        .get(CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .is_none_or(|value| !value.eq_ignore_ascii_case("application/json"))
    {
        bail!("worker API response must use Content-Type application/json");
    }
    let bytes = bounded_body(response).await?;
    if !status.is_success() {
        return Err(http_status_error(status, &bytes));
    }
    serde_json::from_slice(&bytes).context("decode strict worker API JSON")
}

async fn bounded_body(response: Response) -> Result<Vec<u8>> {
    if response
        .content_length()
        .is_some_and(|length| length > MAX_RESPONSE_BYTES as u64)
    {
        bail!("worker API response exceeds {MAX_RESPONSE_BYTES} bytes");
    }
    let bytes = response.bytes().await.context("read worker API response")?;
    if bytes.len() > MAX_RESPONSE_BYTES {
        bail!("worker API response exceeds {MAX_RESPONSE_BYTES} bytes");
    }
    Ok(bytes.to_vec())
}

fn http_status_error(status: StatusCode, body: &[u8]) -> anyhow::Error {
    let value = serde_json::from_slice::<serde_json::Value>(body).ok();
    let summary = value
        .as_ref()
        .and_then(|value| value.pointer("/error/code"))
        .and_then(|code| code.as_str())
        .filter(|code| {
            !code.is_empty()
                && code.len() <= 128
                && code.bytes().all(|byte| {
                    byte.is_ascii_lowercase()
                        || byte.is_ascii_digit()
                        || matches!(byte, b'_' | b'-' | b'.')
                })
        })
        .unwrap_or("worker_api_error");
    if status == StatusCode::CONFLICT && matches!(summary, "version_conflict" | "state_conflict") {
        if let Some(current_version) = value
            .as_ref()
            .and_then(|value| value.pointer("/error/currentVersion"))
            .and_then(serde_json::Value::as_u64)
        {
            let cancel_requested = value
                .as_ref()
                .and_then(|value| value.pointer("/error/cancelRequested"))
                .and_then(serde_json::Value::as_bool)
                .unwrap_or(false);
            let current_state = value
                .as_ref()
                .and_then(|value| value.pointer("/error/currentState"))
                .cloned()
                .and_then(|state| serde_json::from_value(state).ok());
            return anyhow::Error::new(VersionConflict {
                current_version,
                cancel_requested,
                current_state,
            });
        }
    }
    if status.is_server_error() {
        return anyhow::Error::new(RetryableHttpError {
            status,
            code: summary.to_owned(),
        });
    }
    anyhow::Error::new(WorkerApiHttpError {
        status,
        code: summary.to_owned(),
    })
}

fn sha256(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn endpoints_are_rooted_and_never_inherit_credentials() {
        let base = validate_https_url("https://controller.example:7443/base").unwrap();
        assert_eq!(
            endpoint(&base, "pair").unwrap().as_str(),
            "https://controller.example:7443/worker/v1/pair"
        );
        assert_eq!(
            endpoint(&base, "node-report").unwrap().as_str(),
            "https://controller.example:7443/worker/v1/node-report"
        );
    }

    #[test]
    fn digest_is_lowercase_sha256() {
        assert_eq!(
            sha256(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn version_conflict_keeps_authoritative_cancel_state() {
        for code in ["version_conflict", "state_conflict"] {
            let body = format!(
                r#"{{"error":{{"code":"{code}","message":"stale","currentVersion":9,"cancelRequested":true,"currentState":"running"}}}}"#
            );
            let error = http_status_error(StatusCode::CONFLICT, body.as_bytes());
            let conflict = error.downcast_ref::<VersionConflict>().unwrap();
            assert_eq!(conflict.current_version, 9);
            assert!(conflict.cancel_requested);
            assert_eq!(conflict.current_state, Some(JobState::Running));
        }
    }

    #[test]
    fn only_transport_and_server_errors_are_retryable() {
        let server = http_status_error(
            StatusCode::BAD_GATEWAY,
            br#"{"error":{"code":"upstream_reset"}}"#,
        );
        assert!(is_retryable_transport_error(&server));

        let validation = http_status_error(
            StatusCode::UNPROCESSABLE_ENTITY,
            br#"{"error":{"code":"invalid_completion"}}"#,
        );
        assert!(!is_retryable_transport_error(&validation));
    }

    #[test]
    fn pairing_terminal_errors_are_typed_and_never_scraped_from_display_text() {
        for (status, code) in [
            (StatusCode::GONE, "pairing_unavailable"),
            (StatusCode::CONFLICT, "pairing_binding_mismatch"),
            (StatusCode::UNAUTHORIZED, "pairing_ack_unauthorized"),
        ] {
            let body = format!(r#"{{"error":{{"code":"{code}"}}}}"#);
            let error = http_status_error(status, body.as_bytes());
            assert_eq!(pairing_terminal_code(&error), Some(code));
            let typed = error.downcast_ref::<WorkerApiHttpError>().unwrap();
            assert_eq!(typed.status(), status);
            assert_eq!(typed.code(), code);
        }

        let coincidental_text =
            anyhow::anyhow!("worker API returned HTTP 410 Gone (pairing_unavailable)");
        assert_eq!(pairing_terminal_code(&coincidental_text), None);
    }

    #[test]
    fn hostile_or_oversized_api_error_codes_are_not_reflected() {
        let hostile = http_status_error(
            StatusCode::BAD_REQUEST,
            br#"{"error":{"code":"pairing_unavailable\nsecret"}}"#,
        );
        let typed = hostile.downcast_ref::<WorkerApiHttpError>().unwrap();
        assert_eq!(typed.code(), "worker_api_error");
        assert_eq!(pairing_terminal_code(&hostile), None);
    }

    #[test]
    fn node_report_receipt_requires_an_explicit_acceptance_header() {
        let accepted = HeaderValue::from_static("true");
        let replayed = HeaderValue::from_static("false");
        let invalid = HeaderValue::from_static("yes");
        assert!(parse_node_report_accepted(Some(&accepted)).unwrap());
        assert!(!parse_node_report_accepted(Some(&replayed)).unwrap());
        assert!(parse_node_report_accepted(Some(&invalid)).is_err());
        assert!(parse_node_report_accepted(None).is_err());
        assert_eq!(
            parse_u64_response_header(Some(&HeaderValue::from_static("42")), "x-test").unwrap(),
            42
        );
        assert!(parse_u64_response_header(Some(&invalid), "x-test").is_err());
        assert!(parse_u64_response_header(None, "x-test").is_err());
    }

    #[test]
    fn control_timeout_is_positive_and_strictly_below_the_lease() {
        let directory = tempfile::tempdir().unwrap();
        let mut config = WorkerConfig {
            api_version: crate::config::WORKER_CONFIG_VERSION.to_owned(),
            worker_url: "https://controller.example.invalid/worker".to_owned(),
            certificate_pem: "certificate".to_owned(),
            controller_id: Uuid::new_v4(),
            node_id: Uuid::new_v4(),
            worker_api_version: cyc_protocol::worker::WORKER_API_VERSION.to_owned(),
            heartbeat_interval_seconds: 5,
            lease_seconds: 90,
            workspace_root: directory.path().join("workspace"),
            credential_file: directory.path().join("credential"),
        };
        assert_eq!(
            control_request_timeout(&config).unwrap(),
            Duration::from_secs(30)
        );
        config.lease_seconds = 6;
        assert_eq!(
            control_request_timeout(&config).unwrap(),
            Duration::from_secs(5)
        );
        config.lease_seconds = config.heartbeat_interval_seconds;
        assert!(control_request_timeout(&config).is_err());
    }

    #[test]
    fn enrollment_pin_accepts_exactly_one_certificate_item() {
        let one = "-----BEGIN CERTIFICATE-----\nAA==\n-----END CERTIFICATE-----\n";
        assert_eq!(parse_single_certificate(one).unwrap().as_ref(), &[0]);
        let two = format!("{one}{one}");
        assert!(parse_single_certificate(&two).is_err());
        let key = "-----BEGIN PRIVATE KEY-----\nAA==\n-----END PRIVATE KEY-----\n";
        assert!(parse_single_certificate(key).is_err());
    }
}
