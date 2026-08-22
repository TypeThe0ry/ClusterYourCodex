#[cfg(windows)]
use std::path::Path;
use std::path::PathBuf;

use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use cyc_protocol::JobSpec;
use reqwest::{Client, Method};
use serde_json::Value;
use uuid::Uuid;

const DEFAULT_CONTROLLER: &str = "http://127.0.0.1:47831";

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
enum PairCommands {
    /// Create a ten-minute one-time pairing bundle and save it to a new file.
    Create {
        #[arg(long)]
        output: PathBuf,
    },
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
    let token = if matches!(&cli.command, Commands::Health) {
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
            command: PairCommands::Create { output },
        } => {
            let bundle = request_json(
                &client,
                Method::POST,
                &base,
                "/v1/pairings",
                Some(serde_json::json!({})),
                None,
                token.as_deref(),
            )
            .await?;
            let enrollment = worker_enrollment_bundle(&bundle)?;
            write_secret_json(output, &enrollment)?;
            serde_json::json!({
                "pairingId": bundle.get("pairingId"),
                "expiresAt": bundle.get("expiresAt"),
                "bundleFile": output,
            })
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

fn write_secret_json(path: &PathBuf, value: &Value) -> Result<()> {
    let bytes = serde_json::to_vec_pretty(value)?;
    write_secret_file(path, &bytes)
}

/// Convert the richer local API response into the strict document consumed by
/// `cyc-worker pair`. Pairing metadata stays in the non-secret CLI summary and
/// cannot make the worker's deny-unknown-fields parser reject the bundle.
fn worker_enrollment_bundle(pairing_response: &Value) -> Result<Value> {
    let object = pairing_response
        .as_object()
        .context("controller pairing response must be a JSON object")?;
    let required_string = |field: &str| -> Result<String> {
        let value = object
            .get(field)
            .and_then(Value::as_str)
            .with_context(|| format!("controller pairing response is missing {field}"))?;
        if value.is_empty() {
            bail!("controller pairing response contains an empty {field}");
        }
        Ok(value.to_owned())
    };
    let controller_id = required_string("controllerId")?;
    Uuid::parse_str(&controller_id)
        .context("controller pairing response has invalid controllerId")?;
    Ok(serde_json::json!({
        "workerUrl": required_string("workerUrl")?,
        "certificatePem": required_string("certificatePem")?,
        "pairingCode": required_string("pairingCode")?,
        "controllerId": controller_id,
    }))
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
        for forbidden in ["password", "private-key", "token", "secret", "credential"] {
            assert!(
                forbidden == "token" || !joined.contains(forbidden),
                "forbidden CLI option: {forbidden}"
            );
        }
        assert!(Cli::try_parse_from(["cyc", "--token", "raw-secret", "health"]).is_err());
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
    fn pairing_response_is_reduced_to_the_worker_enrollment_contract() {
        let response = serde_json::json!({
            "pairingId": "00000000-0000-0000-0000-000000000001",
            "controllerId": "00000000-0000-0000-0000-000000000002",
            "workerUrl": "https://192.0.2.10:47832",
            "certificatePem": "-----BEGIN CERTIFICATE-----\nAA==\n-----END CERTIFICATE-----\n",
            "pairingCode": "0123456789abcdef0123456789abcdef",
            "createdAt": "2026-08-22T00:00:00Z",
            "expiresAt": "2026-08-22T00:10:00Z"
        });
        let enrollment = worker_enrollment_bundle(&response).unwrap();
        let keys = enrollment
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect::<std::collections::BTreeSet<_>>();
        assert_eq!(
            keys,
            std::collections::BTreeSet::from([
                "certificatePem",
                "controllerId",
                "pairingCode",
                "workerUrl",
            ])
        );
        assert_eq!(enrollment["pairingCode"], response["pairingCode"]);
        assert!(worker_enrollment_bundle(&serde_json::json!({})).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn pairing_bundle_output_creates_or_requires_a_private_parent() {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};

        let temporary = tempfile::tempdir().unwrap();
        let private_output = temporary.path().join("new-private").join("pairing.json");
        write_secret_json(&private_output, &serde_json::json!({ "secret": "fixture" })).unwrap();
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
        assert!(write_secret_json(&rejected, &serde_json::json!({ "secret": "fixture" })).is_err());
        assert!(!rejected.exists());
    }

    #[cfg(windows)]
    #[test]
    fn pairing_bundle_acl_repair_removes_explicit_everyone_allow() {
        use std::process::Command;

        let temporary = tempfile::tempdir().unwrap();
        let private_parent = temporary.path().join("private");
        let output = private_parent.join("pairing.json");
        write_secret_json(&output, &serde_json::json!({ "secret": "fixture" })).unwrap();
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
        assert!(write_secret_json(&rejected, &serde_json::json!({ "secret": "fixture" })).is_err());
        assert!(!rejected.exists());
    }
}
