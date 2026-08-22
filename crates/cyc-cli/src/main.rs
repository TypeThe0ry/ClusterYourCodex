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
    },
    /// Request cancellation of a queued or active job.
    Cancel { id: Uuid },
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let client = Client::builder()
        .user_agent(concat!("cyc-cli/", env!("CARGO_PKG_VERSION")))
        .build()
        .context("failed to build HTTP client")?;
    let base = normalize_base_url(&cli.controller)?;

    let response = match &cli.command {
        Commands::Health => request_json(&client, Method::GET, &base, "/v1/health", None).await?,
        Commands::Nodes => request_json(&client, Method::GET, &base, "/v1/fleet", None).await?,
        Commands::Jobs { id: Some(id) } => {
            request_json(&client, Method::GET, &base, &format!("/v1/jobs/{id}"), None).await?
        }
        Commands::Jobs { id: None } => {
            request_json(&client, Method::GET, &base, "/v1/jobs", None).await?
        }
        Commands::Plan { file } => {
            let spec = read_job_spec(file)?;
            request_json(
                &client,
                Method::POST,
                &base,
                "/v1/plans",
                Some(serde_json::json!({ "job": spec })),
            )
            .await?
        }
        Commands::Submit { file } => {
            let spec = read_job_spec(file)?;
            request_json(
                &client,
                Method::POST,
                &base,
                "/v1/jobs",
                Some(serde_json::json!({ "job": spec })),
            )
            .await?
        }
        Commands::Cancel { id } => {
            request_json(
                &client,
                Method::POST,
                &base,
                &format!("/v1/jobs/{id}/cancel"),
                None,
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
    if !(value.starts_with("http://") || value.starts_with("https://")) {
        bail!("controller URL must use http:// or https://");
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
) -> Result<Value> {
    let mut request = client.request(method, format!("{base}{path}"));
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
        for forbidden in ["password", "private-key", "token", "secret", "credential"] {
            assert!(
                !joined.contains(forbidden),
                "forbidden CLI option: {forbidden}"
            );
        }
    }

    #[test]
    fn normalizes_controller_url() {
        assert_eq!(
            normalize_base_url("http://127.0.0.1:47831/").unwrap(),
            DEFAULT_CONTROLLER
        );
        assert!(normalize_base_url("127.0.0.1:47831").is_err());
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
