use anyhow::Result;
use std::path::PathBuf;

use clap::{Parser, Subcommand};

#[derive(Debug, Parser)]
#[command(
    name = "cyc-worker",
    version,
    about = "Pair and run a secure ClusterYourCodex managed worker"
)]
struct Args {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Debug, Subcommand)]
enum Commands {
    /// Inspect hardware, capacity, and installed toolchains.
    Probe {
        /// Workspace whose actual disk volume should be measured.
        #[arg(long, default_value = ".")]
        workspace: PathBuf,
        /// Pretty-print the probe JSON.
        #[arg(long)]
        pretty: bool,
    },
    /// Consume a one-time protected enrollment bundle and persist a worker credential.
    Pair {
        #[arg(long)]
        enrollment_file: PathBuf,
        #[arg(long)]
        config: PathBuf,
        /// Absolute job workspace selected by the installer or operator.
        #[arg(long)]
        workspace_root: Option<PathBuf>,
        /// Rotate credentials for the same controller and intended node.
        #[arg(long)]
        repair: bool,
    },
    /// Poll, execute, and report jobs. One worker process runs one job at a time.
    Run {
        #[arg(long)]
        config: PathBuf,
    },
    /// Validate local pairing state without printing credential material.
    Status {
        #[arg(long)]
        config: PathBuf,
        /// Pretty-print the status JSON.
        #[arg(long)]
        pretty: bool,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    match args.command {
        Commands::Probe { workspace, pretty } => {
            let report = cyc_worker::probe_at(&workspace)?;
            print_json(&report, pretty)?;
        }
        Commands::Pair {
            enrollment_file,
            config,
            workspace_root,
            repair,
        } => {
            let paired = cyc_worker::runtime::pair(
                &enrollment_file,
                &config,
                cyc_worker::runtime::PairOptions {
                    workspace_root,
                    repair,
                },
            )
            .await?;
            println!(
                "paired node {} to controller {}; config={}",
                paired.node_id,
                paired.controller_id,
                config.display()
            );
        }
        Commands::Run { config } => cyc_worker::runtime::run_forever(&config).await?,
        Commands::Status { config, pretty } => {
            let status = cyc_worker::runtime::status(&config)?;
            print_json(&status, pretty)?;
        }
    }
    Ok(())
}

fn print_json(value: &impl serde::Serialize, pretty: bool) -> Result<()> {
    if pretty {
        println!("{}", serde_json::to_string_pretty(value)?);
    } else {
        println!("{}", serde_json::to_string(value)?);
    }
    Ok(())
}
