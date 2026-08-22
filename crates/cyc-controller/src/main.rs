use std::net::SocketAddr;
use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::Parser;
use cyc_controller::api::AppState;
use cyc_controller::store::Store;
use tracing_subscriber::EnvFilter;

#[derive(Debug, Parser)]
#[command(
    name = "cyc-controller",
    version,
    about = "Local ClusterYourCodex scheduling controller"
)]
struct Args {
    /// Loopback listen address. Non-loopback binds are rejected.
    #[arg(long, default_value = cyc_controller::DEFAULT_BIND)]
    bind: SocketAddr,

    /// SQLite database file.
    #[arg(long, env = "CYC_DATABASE")]
    database: Option<PathBuf>,

    /// File containing the local API bearer token. The token itself is never a CLI argument.
    #[arg(long, env = "CYC_TOKEN_FILE")]
    token_file: Option<PathBuf>,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .with_target(false)
        .compact()
        .init();

    let args = Args::parse();
    cyc_controller::ensure_loopback(args.bind)?;
    let database = args.database.unwrap_or_else(default_database_path);
    let token_file = args.token_file.unwrap_or_else(default_token_path);
    if let Some(parent) = database
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
    {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("failed to create data directory {}", parent.display()))?;
    }
    let store = Store::open(&database)
        .with_context(|| format!("failed to open database {}", database.display()))?;
    let token = cyc_controller::auth::load_or_create(&token_file)
        .with_context(|| format!("failed to initialize token file {}", token_file.display()))?;
    let listener = tokio::net::TcpListener::bind(args.bind)
        .await
        .with_context(|| format!("failed to bind {}", args.bind))?;
    tracing::info!(address = %args.bind, "ClusterYourCodex controller listening");
    cyc_controller::serve(listener, AppState::new(store, token, args.bind.port())).await
}

fn default_database_path() -> PathBuf {
    default_data_directory().join("controller.db")
}

fn default_token_path() -> PathBuf {
    default_data_directory().join("controller.token")
}

fn default_data_directory() -> PathBuf {
    if let Some(data) = std::env::var_os("LOCALAPPDATA") {
        return PathBuf::from(data).join("ClusterYourCodex");
    }
    if let Some(data) = std::env::var_os("XDG_DATA_HOME") {
        return PathBuf::from(data).join("clusteryourcodex");
    }
    if let Some(home) = std::env::var_os("HOME") {
        let home = PathBuf::from(home);
        if cfg!(target_os = "macos") {
            return home
                .join("Library")
                .join("Application Support")
                .join("ClusterYourCodex");
        }
        return home.join(".local").join("share").join("clusteryourcodex");
    }
    PathBuf::from(".")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn database_path_has_a_file_name() {
        assert_eq!(
            default_database_path().file_name().unwrap(),
            "controller.db"
        );
        assert_eq!(
            default_token_path().file_name().unwrap(),
            "controller.token"
        );
    }
}
