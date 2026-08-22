pub mod api;
pub mod auth;
pub mod store;

use std::net::SocketAddr;

use anyhow::{bail, Context, Result};
use tokio::net::TcpListener;

pub const DEFAULT_BIND: &str = "127.0.0.1:47831";

pub async fn serve(listener: TcpListener, state: api::AppState) -> Result<()> {
    let address = listener
        .local_addr()
        .context("failed to read listener address")?;
    ensure_loopback(address)?;
    axum::serve(listener, api::router(state))
        .with_graceful_shutdown(shutdown_signal())
        .await
        .context("controller HTTP server failed")
}

pub fn ensure_loopback(address: SocketAddr) -> Result<()> {
    if !address.ip().is_loopback() {
        bail!("controller must bind to a loopback address");
    }
    Ok(())
}

async fn shutdown_signal() {
    let ctrl_c = async {
        if let Err(error) = tokio::signal::ctrl_c().await {
            tracing::error!(%error, "failed to install Ctrl+C handler");
        }
    };

    #[cfg(unix)]
    let terminate = async {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut stream) => {
                stream.recv().await;
            }
            Err(error) => tracing::error!(%error, "failed to install terminate handler"),
        }
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        () = ctrl_c => {},
        () = terminate => {},
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn controller_is_loopback_only() {
        ensure_loopback("127.0.0.1:47831".parse().unwrap()).unwrap();
        ensure_loopback("[::1]:47831".parse().unwrap()).unwrap();
        assert!(ensure_loopback("0.0.0.0:47831".parse().unwrap()).is_err());
        assert!(ensure_loopback("192.0.2.4:47831".parse().unwrap()).is_err());
    }
}
