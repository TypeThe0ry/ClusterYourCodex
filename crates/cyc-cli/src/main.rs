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
            r#"{"apiVersion":"cyc.dev/v1","id":"00000000-0000-0000-0000-000000000123","kind":"build","source":{"type":"git","repository":"https://example.invalid/repository.git","revision":"0123456789abcdef"},"requirements":{},"steps":[{"name":"build","script":"cargo build"}],"artifacts":{},"placementPolicy":"balanced"}"#
        );
        assert!(parse_job_spec(json).is_ok());
    }
}
