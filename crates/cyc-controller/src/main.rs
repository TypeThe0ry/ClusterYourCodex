use std::net::SocketAddr;
use std::path::PathBuf;

use anyhow::{bail, Context, Result};
use clap::Parser;
use cyc_controller::api::AppState;
use cyc_controller::store::Store;
use rustls::pki_types::{pem::PemObject, CertificateDer};
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

    /// Optional managed-worker TLS listen address. Requires all worker TLS options.
    #[arg(long)]
    worker_bind: Option<SocketAddr>,

    /// Externally reachable HTTPS base URL returned in pairing bundles.
    #[arg(long)]
    worker_public_url: Option<String>,

    /// Single PEM certificate for the managed-worker listener and enrollment pin.
    #[arg(long)]
    worker_cert: Option<PathBuf>,

    /// PEM private key for the managed-worker listener. The key is never read into logs.
    #[arg(long)]
    worker_key: Option<PathBuf>,
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
    let worker = worker_options(&args)?;
    let database = args.database.unwrap_or_else(default_database_path);
    let token_file = args.token_file.unwrap_or_else(default_token_path);
    // Preflight existing database/object state before token initialization can
    // alter a shared parent directory. Store::open performs the exclusive
    // create/harden phase only after both trust checks have passed.
    cyc_controller::auth::preflight_database_layout(&database).with_context(|| {
        format!(
            "database security preflight failed for {}",
            database.display()
        )
    })?;
    let token = cyc_controller::auth::load_or_create(&token_file)
        .with_context(|| format!("failed to initialize token file {}", token_file.display()))?;
    let store = Store::open(&database)
        .with_context(|| format!("failed to open database {}", database.display()))?;
    let listener = tokio::net::TcpListener::bind(args.bind)
        .await
        .with_context(|| format!("failed to bind {}", args.bind))?;
    tracing::info!(address = %args.bind, "ClusterYourCodex controller listening");
    let mut state = AppState::new(store, token, args.bind.port());
    if let Some(worker) = worker {
        state = state.with_worker_endpoint(worker.public_url.clone(), worker.certificate_pem);
        tracing::info!(address = %worker.bind, "managed-worker TLS listener enabled");
        let client_state = state.clone();
        tokio::select! {
            result = cyc_controller::serve(listener, client_state) => result,
            result = cyc_controller::serve_worker_tls(
                worker.bind,
                state,
                worker.certificate,
                worker.private_key,
            ) => result,
        }
    } else {
        cyc_controller::serve(listener, state).await
    }
}

struct WorkerOptions {
    bind: SocketAddr,
    public_url: String,
    certificate: PathBuf,
    certificate_pem: String,
    private_key: PathBuf,
}

fn worker_options(args: &Args) -> Result<Option<WorkerOptions>> {
    let configured = [
        args.worker_bind.is_some(),
        args.worker_public_url.is_some(),
        args.worker_cert.is_some(),
        args.worker_key.is_some(),
    ];
    if configured.iter().all(|configured| !configured) {
        return Ok(None);
    }
    if !configured.iter().all(|configured| *configured) {
        bail!("--worker-bind, --worker-public-url, --worker-cert, and --worker-key are required together");
    }
    let public_url = args
        .worker_public_url
        .as_deref()
        .unwrap()
        .trim_end_matches('/');
    let uri: axum::http::Uri = public_url
        .parse()
        .context("--worker-public-url is invalid")?;
    if uri.scheme_str() != Some("https")
        || uri.authority().is_none()
        || uri
            .authority()
            .is_some_and(|authority| authority.as_str().contains('@'))
        || !matches!(uri.path(), "" | "/")
        || uri.query().is_some()
    {
        bail!("--worker-public-url must be an HTTPS origin without credentials, path, query, or fragment");
    }
    let certificate = args.worker_cert.clone().unwrap();
    let private_key = args.worker_key.clone().unwrap();
    cyc_controller::auth::validate_public_file(&certificate).with_context(|| {
        format!(
            "managed-worker TLS certificate is not a safe regular file: {}",
            certificate.display()
        )
    })?;
    cyc_controller::auth::validate_private_file(&private_key).with_context(|| {
        format!(
            "managed-worker TLS private key permissions are unsafe: {}",
            private_key.display()
        )
    })?;
    let certificate_pem = std::fs::read_to_string(&certificate).with_context(|| {
        format!(
            "failed to read worker certificate {}",
            certificate.display()
        )
    })?;
    let certificate_pem = single_certificate_pem(&certificate_pem)?;
    Ok(Some(WorkerOptions {
        bind: args.worker_bind.unwrap(),
        public_url: public_url.to_owned(),
        certificate,
        certificate_pem,
        private_key,
    }))
}

/// Return the exact public certificate distributed in enrollment bundles.
/// Requiring one PEM item also prevents a mistakenly combined certificate/key
/// file from serializing private key material through the local client API.
fn single_certificate_pem(input: &str) -> Result<String> {
    const BEGIN: &str = "-----BEGIN CERTIFICATE-----";
    const END: &str = "-----END CERTIFICATE-----";
    let trimmed = input.trim();
    if !trimmed.starts_with(BEGIN)
        || !trimmed.ends_with(END)
        || trimmed.matches(BEGIN).count() != 1
        || trimmed.matches(END).count() != 1
        || trimmed.matches("-----BEGIN ").count() != 1
        || trimmed.matches("-----END ").count() != 1
    {
        bail!("--worker-cert must contain exactly one certificate PEM item");
    }
    CertificateDer::from_pem_slice(trimmed.as_bytes())
        .context("failed to parse --worker-cert PEM")?;
    Ok(format!("{trimmed}\n"))
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
    use std::ffi::OsString;
    use uuid::Uuid;

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

    #[test]
    fn worker_listener_fails_closed_without_complete_tls_configuration() {
        let args =
            Args::try_parse_from(["cyc-controller", "--worker-bind", "0.0.0.0:47832"]).unwrap();
        assert!(worker_options(&args).is_err());
    }

    #[test]
    fn enrollment_certificate_rejects_chains_keys_and_surrounding_data() {
        let certificate = "-----BEGIN CERTIFICATE-----\nAA==\n-----END CERTIFICATE-----\n";
        assert_eq!(single_certificate_pem(certificate).unwrap(), certificate);
        assert!(single_certificate_pem(&format!("{certificate}{certificate}")).is_err());
        assert!(single_certificate_pem(&format!(
            "{certificate}-----BEGIN PRIVATE KEY-----\nAA==\n-----END PRIVATE KEY-----\n"
        ))
        .is_err());
        assert!(single_certificate_pem(&format!("secret\n{certificate}")).is_err());
    }

    #[test]
    fn worker_listener_rejects_a_weak_key_until_it_is_explicitly_provisioned() {
        // macOS reports its temporary directory through `/var`, a symlink to
        // `/private/var`. Resolve that existing Unix root before constructing
        // the fixture so production private-path validation remains strictly
        // fail-closed for symlink components.
        #[cfg(unix)]
        let temp_root = std::fs::canonicalize(std::env::temp_dir())
            .expect("canonicalize the existing system temporary directory");
        // Canonicalization introduces a verbatim (`\\?\`) prefix on Windows;
        // retain the ordinary Win32 path form used by production callers.
        #[cfg(not(unix))]
        let temp_root = std::env::temp_dir();
        let directory = temp_root.join(format!("cyc-tls-files-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&directory).unwrap();
        let certificate = directory.join("controller.crt");
        let private_key = directory.join("controller.key");
        std::fs::write(
            &certificate,
            "-----BEGIN CERTIFICATE-----\nAA==\n-----END CERTIFICATE-----\n",
        )
        .unwrap();
        std::fs::write(
            &private_key,
            "-----BEGIN PRIVATE KEY-----\nAA==\n-----END PRIVATE KEY-----\n",
        )
        .unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&private_key, std::fs::Permissions::from_mode(0o644)).unwrap();
        }

        let argv = vec![
            OsString::from("cyc-controller"),
            OsString::from("--worker-bind"),
            OsString::from("127.0.0.1:47832"),
            OsString::from("--worker-public-url"),
            OsString::from("https://127.0.0.1:47832"),
            OsString::from("--worker-cert"),
            certificate.as_os_str().to_owned(),
            OsString::from("--worker-key"),
            private_key.as_os_str().to_owned(),
        ];
        let args = Args::try_parse_from(argv).unwrap();
        assert!(worker_options(&args).is_err());

        cyc_controller::auth::prepare_private_directory(&directory).unwrap();
        cyc_controller::auth::prepare_private_file_permissions(&private_key).unwrap();
        assert!(worker_options(&args).unwrap().is_some());
        std::fs::remove_dir_all(directory).unwrap();
    }
}
