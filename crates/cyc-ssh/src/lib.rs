//! Host-key-pinned SSH bootstrap transport.
//!
//! Passwords and private-key passphrases are borrowed from
//! [`cyc_secrets::Secret`] only at the in-process authentication call. This
//! crate never constructs secret-bearing command lines, environment variables,
//! persistent request structures, or loggable authentication values.

use std::{
    fmt, fs,
    io::{self, Read, Write},
    net::{SocketAddr, TcpStream, ToSocketAddrs},
    path::{Component, Path, PathBuf},
    thread,
    time::{Duration, Instant},
};

use base64::{engine::general_purpose::STANDARD_NO_PAD, Engine as _};
use cyc_secrets::Secret;
use sha2::{Digest, Sha256};
use ssh2::{Channel, HostKeyType, OpenFlags, OpenType, RenameFlags, Session};
use thiserror::Error;

const DEFAULT_PORT: u16 = 22;
const DEFAULT_TIMEOUT: Duration = Duration::from_secs(15);
const DEFAULT_MAX_OUTPUT_BYTES: usize = 8 * 1024 * 1024;
const DEFAULT_MAX_DOWNLOAD_BYTES: usize = 128 * 1024 * 1024;
const MAX_HOST_KEY_BYTES: usize = 64 * 1024;
const MAX_PRIVATE_KEY_PATH_UNITS: usize = 4096;

/// Public connection coordinates. Authentication data is intentionally absent.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SshEndpoint {
    host: String,
    port: u16,
}

impl SshEndpoint {
    pub fn new(host: impl Into<String>, port: u16) -> Result<Self, SshError> {
        let host = host.into();
        if host.trim().is_empty() || host.contains(['\0', '\r', '\n']) {
            return Err(SshError::InvalidEndpoint);
        }
        if port == 0 {
            return Err(SshError::InvalidEndpoint);
        }
        Ok(Self { host, port })
    }

    pub fn with_default_port(host: impl Into<String>) -> Result<Self, SshError> {
        Self::new(host, DEFAULT_PORT)
    }

    #[must_use]
    pub fn host(&self) -> &str {
        &self.host
    }

    #[must_use]
    pub fn port(&self) -> u16 {
        self.port
    }
}

/// Full SSH host public key plus the conventional SHA-256 fingerprint.
/// Persist the algorithm and `key_bytes`; the fingerprint is for display.
#[derive(Clone, PartialEq, Eq)]
pub struct HostKey {
    algorithm: String,
    key_bytes: Vec<u8>,
    fingerprint: String,
}

impl HostKey {
    fn from_ssh2(algorithm: HostKeyType, key_bytes: &[u8]) -> Result<Self, SshError> {
        if key_bytes.is_empty() || key_bytes.len() > MAX_HOST_KEY_BYTES {
            return Err(SshError::HostKeyUnavailable);
        }
        let algorithm = host_key_algorithm(algorithm)?.to_owned();
        let fingerprint = sha256_fingerprint(key_bytes);
        Ok(Self {
            algorithm,
            key_bytes: key_bytes.to_vec(),
            fingerprint,
        })
    }

    pub fn from_parts(algorithm: impl Into<String>, key_bytes: Vec<u8>) -> Result<Self, SshError> {
        let algorithm = algorithm.into();
        if !matches!(
            algorithm.as_str(),
            "ssh-rsa"
                | "ssh-dss"
                | "ecdsa-sha2-nistp256"
                | "ecdsa-sha2-nistp384"
                | "ecdsa-sha2-nistp521"
                | "ssh-ed25519"
        ) {
            return Err(SshError::UnsupportedHostKeyAlgorithm);
        }
        if key_bytes.is_empty() || key_bytes.len() > MAX_HOST_KEY_BYTES {
            return Err(SshError::HostKeyUnavailable);
        }
        let fingerprint = sha256_fingerprint(&key_bytes);
        Ok(Self {
            algorithm,
            key_bytes,
            fingerprint,
        })
    }

    #[must_use]
    pub fn algorithm(&self) -> &str {
        &self.algorithm
    }

    #[must_use]
    pub fn key_bytes(&self) -> &[u8] {
        &self.key_bytes
    }

    #[must_use]
    pub fn fingerprint(&self) -> &str {
        &self.fingerprint
    }
}

impl fmt::Debug for HostKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("HostKey")
            .field("algorithm", &self.algorithm)
            .field("fingerprint", &self.fingerprint)
            .finish_non_exhaustive()
    }
}

/// Fixed, structured remote command surface. Arbitrary shell fragments are not
/// accepted; installers upload a native script and invoke that file with
/// individually escaped arguments.
#[derive(Clone, PartialEq, Eq)]
pub enum FixedCommand {
    PosixScript {
        remote_path: RemotePath,
        arguments: Vec<CommandArgument>,
    },
    WindowsPowerShellScript {
        remote_path: RemotePath,
        arguments: Vec<CommandArgument>,
    },
}

impl fmt::Debug for FixedCommand {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::PosixScript {
                remote_path,
                arguments,
            } => formatter
                .debug_struct("PosixScript")
                .field("remote_path", remote_path)
                .field("argument_count", &arguments.len())
                .finish(),
            Self::WindowsPowerShellScript {
                remote_path,
                arguments,
            } => formatter
                .debug_struct("WindowsPowerShellScript")
                .field("remote_path", remote_path)
                .field("argument_count", &arguments.len())
                .finish(),
        }
    }
}

impl FixedCommand {
    pub fn posix_script(
        remote_path: RemotePath,
        arguments: impl IntoIterator<Item = CommandArgument>,
    ) -> Self {
        Self::PosixScript {
            remote_path,
            arguments: arguments.into_iter().collect(),
        }
    }

    pub fn windows_powershell_script(
        remote_path: RemotePath,
        arguments: impl IntoIterator<Item = CommandArgument>,
    ) -> Self {
        Self::WindowsPowerShellScript {
            remote_path,
            arguments: arguments.into_iter().collect(),
        }
    }

    fn render(&self) -> String {
        match self {
            Self::PosixScript {
                remote_path,
                arguments,
            } => {
                let mut rendered = format!("/bin/sh {} --", quote_posix(remote_path.as_str()));
                for argument in arguments {
                    rendered.push(' ');
                    rendered.push_str(&quote_posix(argument.as_str()));
                }
                rendered
            }
            Self::WindowsPowerShellScript {
                remote_path,
                arguments,
            } => {
                let mut script = String::from("$ErrorActionPreference='Stop';$cycArgs=@(");
                for (index, argument) in arguments.iter().enumerate() {
                    if index > 0 {
                        script.push(',');
                    }
                    script.push_str(&quote_powershell(argument.as_str()));
                }
                script.push_str("); & ");
                script.push_str(&quote_powershell(remote_path.as_str()));
                script.push_str(" @cycArgs; if($null -ne $LASTEXITCODE){exit $LASTEXITCODE}");
                let utf16le = script
                    .encode_utf16()
                    .flat_map(u16::to_le_bytes)
                    .collect::<Vec<_>>();
                format!(
                    "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand {}",
                    base64::engine::general_purpose::STANDARD.encode(utf16le)
                )
            }
        }
    }
}

/// A validated argument for a fixed installer script. It may contain shell
/// metacharacters because rendering always applies platform-specific quoting.
#[derive(Clone, PartialEq, Eq)]
pub struct CommandArgument(String);

impl CommandArgument {
    pub fn new(value: impl Into<String>) -> Result<Self, SshError> {
        let value = value.into();
        if value.contains(['\0', '\r', '\n']) {
            return Err(SshError::InvalidCommandArgument);
        }
        Ok(Self(value))
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for CommandArgument {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("CommandArgument(<redacted>)")
    }
}

/// Remote path accepted by the SFTP and fixed-script interfaces.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct RemotePath(String);

impl RemotePath {
    pub fn new(value: impl Into<String>) -> Result<Self, SshError> {
        let value = value.into();
        let normalized = value.replace('\\', "/");
        let windows_absolute = normalized.as_bytes().get(1) == Some(&b':')
            && normalized
                .as_bytes()
                .first()
                .is_some_and(u8::is_ascii_alphabetic)
            && normalized.as_bytes().get(2) == Some(&b'/');
        let posix_absolute = normalized.starts_with('/') && !normalized.starts_with("//");
        let has_dot_component = normalized
            .split('/')
            .any(|component| matches!(component, "." | ".."));
        if value.is_empty()
            || value.contains(['\0', '\r', '\n'])
            || (!windows_absolute && !posix_absolute)
            || has_dot_component
        {
            return Err(SshError::InvalidRemotePath);
        }
        Ok(Self(value))
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct CommandOutput {
    pub exit_code: i32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

impl fmt::Debug for CommandOutput {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CommandOutput")
            .field("exit_code", &self.exit_code)
            .field("stdout_bytes", &self.stdout.len())
            .field("stderr_bytes", &self.stderr.len())
            .finish()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TransferReceipt {
    pub bytes: u64,
    pub sha256: String,
}

/// Authentication mechanisms supported by the transport boundary.
///
/// This enum contains no authentication material and is safe to include in a
/// fixed error code or diagnostic event.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AuthenticationMethod {
    Password,
    Agent,
    PrivateKey,
}

impl fmt::Display for AuthenticationMethod {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Password => "password",
            Self::Agent => "agent",
            Self::PrivateKey => "private-key",
        })
    }
}

/// A validated local private-key file.
///
/// Construction and every authentication attempt reject relative or
/// traversing paths, symbolic links, Windows reparse points, non-regular files,
/// and paths whose parent chain contains a link/reparse point. The path is
/// deliberately redacted from `Debug` and all [`SshError`] variants.
#[derive(Clone, PartialEq, Eq)]
pub struct PrivateKeyFile {
    path: PathBuf,
}

impl PrivateKeyFile {
    pub fn new(path: impl Into<PathBuf>) -> Result<Self, SshError> {
        let path = path.into();
        validate_private_key_path(&path)?;
        validate_private_key_file(&path)?;
        Ok(Self { path })
    }

    /// Returns the already validated path for non-secret configuration state.
    /// Callers must not assume this replaces the authentication-time safety
    /// check; [`Ssh2Transport`] validates the file again immediately before use.
    #[must_use]
    pub fn as_path(&self) -> &Path {
        &self.path
    }

    fn revalidate(&self) -> Result<(), SshError> {
        validate_private_key_path(&self.path)?;
        validate_private_key_file(&self.path)
    }
}

impl fmt::Debug for PrivateKeyFile {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("PrivateKeyFile(<redacted>)")
    }
}

/// Borrowed authentication input for provisioning and GUI integrations.
///
/// It intentionally has no owned secret fields and no serialization support;
/// password and passphrase material cannot outlive the caller's [`Secret`].
pub enum SshAuthentication<'a> {
    Password(&'a Secret),
    Agent,
    PrivateKey {
        private_key: &'a PrivateKeyFile,
        passphrase: Option<&'a Secret>,
    },
}

impl fmt::Debug for SshAuthentication<'_> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Password(_) => formatter.write_str("SshAuthentication::Password(<redacted>)"),
            Self::Agent => formatter.write_str("SshAuthentication::Agent"),
            Self::PrivateKey {
                private_key,
                passphrase,
            } => formatter
                .debug_struct("SshAuthentication::PrivateKey")
                .field("private_key", private_key)
                .field("passphrase", &passphrase.map(|_| "<redacted>"))
                .finish(),
        }
    }
}

/// Injectable SSH boundary for GUI provisioning flows and unit tests.
pub trait SshTransport: Send + Sync {
    fn probe_host_key(&self, endpoint: &SshEndpoint) -> Result<HostKey, SshError>;

    /// Reconnects, verifies the full pinned host key, then performs password
    /// authentication. Authentication is never attempted before verification.
    fn connect_password(
        &self,
        endpoint: &SshEndpoint,
        pinned_host_key: &HostKey,
        username: &str,
        password: &Secret,
    ) -> Result<Box<dyn RemoteSession>, SshError>;

    /// Reconnects, verifies the full pinned host key, then attempts every
    /// identity exposed by the process' SSH agent. Legacy/mock transports get
    /// a fixed unsupported error without requiring an implementation change.
    fn connect_agent(
        &self,
        _endpoint: &SshEndpoint,
        _pinned_host_key: &HostKey,
        _username: &str,
    ) -> Result<Box<dyn RemoteSession>, SshError> {
        Err(SshError::UnsupportedAuthenticationMethod {
            method: AuthenticationMethod::Agent,
        })
    }

    /// Reconnects, verifies the full pinned host key, revalidates the local key
    /// file, and only then borrows the optional passphrase for libssh2.
    fn connect_private_key(
        &self,
        _endpoint: &SshEndpoint,
        _pinned_host_key: &HostKey,
        _username: &str,
        _private_key: &PrivateKeyFile,
        _passphrase: Option<&Secret>,
    ) -> Result<Box<dyn RemoteSession>, SshError> {
        Err(SshError::UnsupportedAuthenticationMethod {
            method: AuthenticationMethod::PrivateKey,
        })
    }

    /// Safe common dispatch point for provisioning. Authentication values stay
    /// borrowed and are forwarded directly to the selected method.
    fn connect_with_authentication(
        &self,
        endpoint: &SshEndpoint,
        pinned_host_key: &HostKey,
        username: &str,
        authentication: SshAuthentication<'_>,
    ) -> Result<Box<dyn RemoteSession>, SshError> {
        match authentication {
            SshAuthentication::Password(password) => {
                self.connect_password(endpoint, pinned_host_key, username, password)
            }
            SshAuthentication::Agent => self.connect_agent(endpoint, pinned_host_key, username),
            SshAuthentication::PrivateKey {
                private_key,
                passphrase,
            } => self.connect_private_key(
                endpoint,
                pinned_host_key,
                username,
                private_key,
                passphrase,
            ),
        }
    }
}

pub trait RemoteSession: Send {
    fn exec_fixed(&mut self, command: &FixedCommand) -> Result<CommandOutput, SshError>;

    fn upload_bytes(
        &mut self,
        remote_path: &RemotePath,
        content: &[u8],
        unix_mode: i32,
    ) -> Result<TransferReceipt, SshError>;

    fn download_bytes(
        &mut self,
        remote_path: &RemotePath,
        maximum_bytes: usize,
    ) -> Result<Vec<u8>, SshError>;

    fn create_dir(&mut self, remote_path: &RemotePath, unix_mode: i32) -> Result<(), SshError>;

    fn rename(
        &mut self,
        from: &RemotePath,
        to: &RemotePath,
        overwrite: bool,
    ) -> Result<(), SshError>;

    fn remove_file(&mut self, remote_path: &RemotePath) -> Result<(), SshError>;
}

#[derive(Clone, Debug)]
pub struct Ssh2Transport {
    connect_timeout: Duration,
    io_timeout: Duration,
    maximum_output_bytes: usize,
    maximum_download_bytes: usize,
}

impl Default for Ssh2Transport {
    fn default() -> Self {
        Self {
            connect_timeout: DEFAULT_TIMEOUT,
            io_timeout: DEFAULT_TIMEOUT,
            maximum_output_bytes: DEFAULT_MAX_OUTPUT_BYTES,
            maximum_download_bytes: DEFAULT_MAX_DOWNLOAD_BYTES,
        }
    }
}

impl Ssh2Transport {
    pub fn new(
        connect_timeout: Duration,
        io_timeout: Duration,
        maximum_output_bytes: usize,
        maximum_download_bytes: usize,
    ) -> Result<Self, SshError> {
        if connect_timeout.is_zero()
            || io_timeout.is_zero()
            || maximum_output_bytes == 0
            || maximum_download_bytes == 0
        {
            return Err(SshError::InvalidTransportLimits);
        }
        Ok(Self {
            connect_timeout,
            io_timeout,
            maximum_output_bytes,
            maximum_download_bytes,
        })
    }

    fn handshake(&self, endpoint: &SshEndpoint) -> Result<(Session, HostKey), SshError> {
        let tcp = connect_tcp(endpoint, self.connect_timeout)?;
        tcp.set_read_timeout(Some(self.io_timeout))?;
        tcp.set_write_timeout(Some(self.io_timeout))?;

        let mut session = Session::new()?;
        session.set_timeout(duration_millis(self.io_timeout));
        session.set_tcp_stream(tcp);
        session.handshake()?;
        let (bytes, algorithm) = session.host_key().ok_or(SshError::HostKeyUnavailable)?;
        let host_key = HostKey::from_ssh2(algorithm, bytes)?;
        Ok((session, host_key))
    }

    fn remote_session(&self, session: Session) -> Box<dyn RemoteSession> {
        Box::new(Ssh2RemoteSession {
            session,
            output_inactivity_timeout: self.io_timeout,
            maximum_output_bytes: self.maximum_output_bytes,
            maximum_download_bytes: self.maximum_download_bytes,
        })
    }
}

impl SshTransport for Ssh2Transport {
    fn probe_host_key(&self, endpoint: &SshEndpoint) -> Result<HostKey, SshError> {
        self.handshake(endpoint).map(|(_, host_key)| host_key)
    }

    fn connect_password(
        &self,
        endpoint: &SshEndpoint,
        pinned_host_key: &HostKey,
        username: &str,
        password: &Secret,
    ) -> Result<Box<dyn RemoteSession>, SshError> {
        validate_username(username)?;

        let (session, actual_host_key) = self.handshake(endpoint)?;
        authenticate_after_host_key(&actual_host_key, pinned_host_key, || {
            let password = password
                .expose_utf8()
                .map_err(|_| SshError::PasswordNotUtf8)?;
            session
                .userauth_password(username, password)
                .map_err(|source| SshError::Authentication { source })?;
            if !session.authenticated() {
                return Err(SshError::AuthenticationRejected);
            }
            Ok(self.remote_session(session))
        })
    }

    fn connect_agent(
        &self,
        endpoint: &SshEndpoint,
        pinned_host_key: &HostKey,
        username: &str,
    ) -> Result<Box<dyn RemoteSession>, SshError> {
        validate_username(username)?;

        let (session, actual_host_key) = self.handshake(endpoint)?;
        authenticate_after_host_key(&actual_host_key, pinned_host_key, || {
            let authenticated = {
                let mut agent = session.agent().map_err(|_| SshError::AgentUnavailable)?;
                agent.connect().map_err(|_| SshError::AgentUnavailable)?;
                agent
                    .list_identities()
                    .map_err(|_| SshError::AgentAuthenticationFailed)?;
                let identities = agent
                    .identities()
                    .map_err(|_| SshError::AgentAuthenticationFailed)?;
                if identities.is_empty() {
                    return Err(SshError::AgentAuthenticationRejected);
                }

                let mut authenticated = false;
                for identity in &identities {
                    if agent.userauth(username, identity).is_ok() && session.authenticated() {
                        authenticated = true;
                        break;
                    }
                }
                let _ = agent.disconnect();
                authenticated
            };

            if !authenticated {
                return Err(SshError::AgentAuthenticationRejected);
            }
            Ok(self.remote_session(session))
        })
    }

    fn connect_private_key(
        &self,
        endpoint: &SshEndpoint,
        pinned_host_key: &HostKey,
        username: &str,
        private_key: &PrivateKeyFile,
        passphrase: Option<&Secret>,
    ) -> Result<Box<dyn RemoteSession>, SshError> {
        validate_username(username)?;

        let (session, actual_host_key) = self.handshake(endpoint)?;
        authenticate_after_host_key(&actual_host_key, pinned_host_key, || {
            // Recheck after the network identity is pinned. A caller may keep a
            // validated path for a long-lived GUI form, but auth never trusts
            // that stale validation result.
            private_key.revalidate()?;
            let passphrase = passphrase
                .map(Secret::expose_utf8)
                .transpose()
                .map_err(|_| SshError::PrivateKeyPassphraseNotUtf8)?;
            session
                .userauth_pubkey_file(username, None, private_key.as_path(), passphrase)
                .map_err(|_| SshError::PrivateKeyAuthenticationFailed)?;
            if !session.authenticated() {
                return Err(SshError::PrivateKeyAuthenticationRejected);
            }
            Ok(self.remote_session(session))
        })
    }
}

struct Ssh2RemoteSession {
    session: Session,
    output_inactivity_timeout: Duration,
    maximum_output_bytes: usize,
    maximum_download_bytes: usize,
}

impl RemoteSession for Ssh2RemoteSession {
    fn exec_fixed(&mut self, command: &FixedCommand) -> Result<CommandOutput, SshError> {
        let mut channel = self.session.channel_session()?;
        channel.exec(&command.render())?;

        let (stdout, stderr) = read_channel_output_interleaved(
            &self.session,
            &channel,
            self.maximum_output_bytes,
            self.output_inactivity_timeout,
        )?;
        channel.wait_close()?;
        let exit_code = channel.exit_status()?;
        Ok(CommandOutput {
            exit_code,
            stdout,
            stderr,
        })
    }

    fn upload_bytes(
        &mut self,
        remote_path: &RemotePath,
        content: &[u8],
        unix_mode: i32,
    ) -> Result<TransferReceipt, SshError> {
        let sftp = self.session.sftp()?;
        let mut file = sftp.open_mode(
            Path::new(remote_path.as_str()),
            OpenFlags::WRITE | OpenFlags::CREATE | OpenFlags::TRUNCATE,
            unix_mode,
            OpenType::File,
        )?;
        file.write_all(content)?;
        file.flush()?;
        file.fsync()?;
        file.close()?;
        Ok(TransferReceipt {
            bytes: content.len() as u64,
            sha256: sha256_hex(content),
        })
    }

    fn download_bytes(
        &mut self,
        remote_path: &RemotePath,
        maximum_bytes: usize,
    ) -> Result<Vec<u8>, SshError> {
        let maximum_bytes = maximum_bytes.min(self.maximum_download_bytes);
        if maximum_bytes == 0 {
            return Err(SshError::InvalidTransportLimits);
        }
        let sftp = self.session.sftp()?;
        let mut file = sftp.open(Path::new(remote_path.as_str()))?;
        read_limited(&mut file, maximum_bytes, "SFTP download")
    }

    fn create_dir(&mut self, remote_path: &RemotePath, unix_mode: i32) -> Result<(), SshError> {
        let sftp = self.session.sftp()?;
        let path = Path::new(remote_path.as_str());

        // Provisioning reuses one operation-owned staging directory across
        // discovery, kit upload, enrollment and crash recovery. SFTP mkdir is
        // not idempotent, so a plain second call fails with SSH_FX_FAILURE on
        // common OpenSSH servers. Treat an existing directory as success, but
        // never silently accept a regular file (or another object) in its
        // place. The post-mkdir stat also closes the harmless TOCTOU race where
        // another retry creates the same directory after the first stat.
        // Use lstat so a symlink to an attacker-controlled directory is not
        // accepted as the operation-owned staging directory.
        match sftp.lstat(path) {
            Ok(stat) if stat.is_dir() => return Ok(()),
            Ok(_) => return Err(SshError::RemotePathNotDirectory),
            Err(_) => {}
        }

        match sftp.mkdir(path, unix_mode) {
            Ok(()) => Ok(()),
            Err(mkdir_error) => match sftp.lstat(path) {
                Ok(stat) if stat.is_dir() => Ok(()),
                Ok(_) => Err(SshError::RemotePathNotDirectory),
                Err(_) => Err(SshError::Protocol(mkdir_error)),
            },
        }
    }

    fn rename(
        &mut self,
        from: &RemotePath,
        to: &RemotePath,
        overwrite: bool,
    ) -> Result<(), SshError> {
        let flags = if overwrite {
            Some(RenameFlags::OVERWRITE | RenameFlags::ATOMIC)
        } else {
            Some(RenameFlags::ATOMIC)
        };
        self.session
            .sftp()?
            .rename(Path::new(from.as_str()), Path::new(to.as_str()), flags)?;
        Ok(())
    }

    fn remove_file(&mut self, remote_path: &RemotePath) -> Result<(), SshError> {
        self.session
            .sftp()?
            .unlink(Path::new(remote_path.as_str()))?;
        Ok(())
    }
}

/// Drains stdout and stderr in non-blocking rounds. SSH applies a shared receive
/// window to channel streams, so reading one stream to EOF before touching the
/// other can deadlock when the other stream fills that window.
fn read_channel_output_interleaved(
    session: &Session,
    channel: &Channel,
    maximum_bytes: usize,
    inactivity_timeout: Duration,
) -> Result<(Vec<u8>, Vec<u8>), SshError> {
    let blocking_guard = NonBlockingSessionGuard::new(session);
    let mut stdout_stream = channel.stream(0);
    let mut stderr_stream = channel.stderr();
    let mut stdout = Vec::new();
    let mut stderr = Vec::new();
    let mut last_progress = Instant::now();

    loop {
        let progressed = pump_available_pair(
            &mut stdout_stream,
            &mut stderr_stream,
            &mut stdout,
            &mut stderr,
            maximum_bytes,
        )?;
        if progressed {
            last_progress = Instant::now();
        }

        // libssh2 reports channel EOF only after all buffered stdout and
        // extended-data bytes have been consumed. Both streams were drained
        // immediately before this check.
        if channel.eof() {
            break;
        }
        if last_progress.elapsed() >= inactivity_timeout {
            return Err(SshError::CommandOutputTimedOut {
                timeout_millis: inactivity_timeout.as_millis().min(u64::MAX as u128) as u64,
            });
        }
        if !progressed {
            thread::sleep(Duration::from_millis(5));
        }
    }

    drop(blocking_guard);
    Ok((stdout, stderr))
}

struct NonBlockingSessionGuard<'a>(&'a Session);

impl<'a> NonBlockingSessionGuard<'a> {
    fn new(session: &'a Session) -> Self {
        session.set_blocking(false);
        Self(session)
    }
}

impl Drop for NonBlockingSessionGuard<'_> {
    fn drop(&mut self) {
        self.0.set_blocking(true);
    }
}

fn pump_available_pair(
    stdout_reader: &mut impl Read,
    stderr_reader: &mut impl Read,
    stdout: &mut Vec<u8>,
    stderr: &mut Vec<u8>,
    maximum_bytes: usize,
) -> Result<bool, SshError> {
    let stdout_progressed = drain_available(
        stdout_reader,
        stdout,
        stderr.len(),
        maximum_bytes,
        "command stdout",
    )?;
    let stderr_progressed = drain_available(
        stderr_reader,
        stderr,
        stdout.len(),
        maximum_bytes,
        "command stderr",
    )?;
    Ok(stdout_progressed || stderr_progressed)
}

fn drain_available(
    reader: &mut impl Read,
    output: &mut Vec<u8>,
    other_stream_bytes: usize,
    maximum_bytes: usize,
    stream: &'static str,
) -> Result<bool, SshError> {
    let mut progressed = false;
    let mut buffer = [0_u8; 16 * 1024];
    loop {
        match reader.read(&mut buffer) {
            Ok(0) => return Ok(progressed),
            Ok(count) => {
                if output
                    .len()
                    .saturating_add(other_stream_bytes)
                    .saturating_add(count)
                    > maximum_bytes
                {
                    return Err(SshError::OutputLimitExceeded {
                        stream,
                        maximum_bytes,
                    });
                }
                output.extend_from_slice(&buffer[..count]);
                progressed = true;
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(progressed),
            Err(error) => return Err(SshError::Io(error)),
        }
    }
}

fn validate_username(username: &str) -> Result<(), SshError> {
    if username.is_empty() || username.contains(['\0', '\r', '\n']) {
        return Err(SshError::InvalidUsername);
    }
    Ok(())
}

fn authenticate_after_host_key<T>(
    actual_host_key: &HostKey,
    pinned_host_key: &HostKey,
    authenticate: impl FnOnce() -> Result<T, SshError>,
) -> Result<T, SshError> {
    if actual_host_key != pinned_host_key {
        return Err(SshError::HostKeyMismatch {
            expected: pinned_host_key.fingerprint().to_owned(),
            actual: actual_host_key.fingerprint().to_owned(),
        });
    }
    authenticate()
}

fn validate_private_key_path(path: &Path) -> Result<(), SshError> {
    if !path.is_absolute()
        || path
            .components()
            .any(|component| matches!(component, Component::CurDir | Component::ParentDir))
    {
        return Err(SshError::InvalidPrivateKeyPath);
    }

    // Windows drive-rooted paths are accepted. UNC, device namespace and
    // verbatim paths are rejected so an apparently local key cannot cross a
    // network/share or device boundary during authentication.
    #[cfg(windows)]
    {
        use std::{os::windows::ffi::OsStrExt, path::Prefix};

        match path.components().next() {
            Some(Component::Prefix(prefix)) if matches!(prefix.kind(), Prefix::Disk(_)) => {}
            _ => return Err(SshError::InvalidPrivateKeyPath),
        }
        let mut units = 0usize;
        for unit in path.as_os_str().encode_wide() {
            units = units.saturating_add(1);
            if matches!(unit, 0 | 10 | 13) || units > MAX_PRIVATE_KEY_PATH_UNITS {
                return Err(SshError::InvalidPrivateKeyPath);
            }
        }
    }

    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;

        let bytes = path.as_os_str().as_bytes();
        if bytes.len() > MAX_PRIVATE_KEY_PATH_UNITS
            || bytes.iter().any(|byte| matches!(byte, 0 | b'\n' | b'\r'))
        {
            return Err(SshError::InvalidPrivateKeyPath);
        }
    }

    #[cfg(not(any(unix, windows)))]
    {
        let _ = path;
        return Err(SshError::PrivateKeyPathValidationUnavailable);
    }

    Ok(())
}

fn validate_private_key_file(path: &Path) -> Result<(), SshError> {
    for (index, ancestor) in path.ancestors().enumerate() {
        let metadata =
            fs::symlink_metadata(ancestor).map_err(|_| SshError::PrivateKeyUnavailable)?;
        if metadata.file_type().is_symlink() || metadata_is_reparse_point(&metadata) {
            return Err(SshError::UnsafePrivateKeyPath);
        }
        if index == 0 {
            if !metadata.is_file() {
                return Err(SshError::PrivateKeyNotRegularFile);
            }
        } else if !metadata.is_dir() {
            return Err(SshError::UnsafePrivateKeyPath);
        }
    }
    Ok(())
}

#[cfg(windows)]
fn metadata_is_reparse_point(metadata: &fs::Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;

    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;
    metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

#[cfg(not(windows))]
fn metadata_is_reparse_point(_metadata: &fs::Metadata) -> bool {
    false
}

fn connect_tcp(endpoint: &SshEndpoint, timeout: Duration) -> Result<TcpStream, SshError> {
    let addresses = (endpoint.host(), endpoint.port())
        .to_socket_addrs()
        .map_err(SshError::Io)?
        .collect::<Vec<SocketAddr>>();
    if addresses.is_empty() {
        return Err(SshError::NoResolvedAddress);
    }

    let mut last_error = None;
    for address in addresses {
        match TcpStream::connect_timeout(&address, timeout) {
            Ok(stream) => return Ok(stream),
            Err(error) => last_error = Some(error),
        }
    }
    Err(SshError::Io(last_error.unwrap_or_else(|| {
        io::Error::new(io::ErrorKind::NotFound, "no resolved SSH address")
    })))
}

fn duration_millis(duration: Duration) -> u32 {
    duration.as_millis().min(u32::MAX as u128) as u32
}

fn host_key_algorithm(kind: HostKeyType) -> Result<&'static str, SshError> {
    match kind {
        HostKeyType::Rsa => Ok("ssh-rsa"),
        HostKeyType::Dss => Ok("ssh-dss"),
        HostKeyType::Ecdsa256 => Ok("ecdsa-sha2-nistp256"),
        HostKeyType::Ecdsa384 => Ok("ecdsa-sha2-nistp384"),
        HostKeyType::Ecdsa521 => Ok("ecdsa-sha2-nistp521"),
        HostKeyType::Ed25519 => Ok("ssh-ed25519"),
        HostKeyType::Unknown => Err(SshError::UnsupportedHostKeyAlgorithm),
    }
}

fn read_limited(
    reader: &mut impl Read,
    maximum_bytes: usize,
    stream: &'static str,
) -> Result<Vec<u8>, SshError> {
    let mut output = Vec::new();
    let mut buffer = [0_u8; 16 * 1024];
    loop {
        let count = reader.read(&mut buffer)?;
        if count == 0 {
            return Ok(output);
        }
        if output.len().saturating_add(count) > maximum_bytes {
            return Err(SshError::OutputLimitExceeded {
                stream,
                maximum_bytes,
            });
        }
        output.extend_from_slice(&buffer[..count]);
    }
}

fn quote_posix(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

fn quote_powershell(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

fn sha256_fingerprint(bytes: &[u8]) -> String {
    format!("SHA256:{}", STANDARD_NO_PAD.encode(Sha256::digest(bytes)))
}

fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[derive(Debug, Error)]
pub enum SshError {
    #[error("SSH endpoint is invalid")]
    InvalidEndpoint,
    #[error("SSH username is invalid")]
    InvalidUsername,
    #[error("SSH password must be valid UTF-8")]
    PasswordNotUtf8,
    #[error("SSH private-key passphrase must be valid UTF-8")]
    PrivateKeyPassphraseNotUtf8,
    #[error("SSH private-key path is invalid")]
    InvalidPrivateKeyPath,
    #[error("SSH private-key path safety validation is unavailable on this platform")]
    PrivateKeyPathValidationUnavailable,
    #[error("SSH private-key file is unavailable")]
    PrivateKeyUnavailable,
    #[error("SSH private-key path contains a link or reparse point")]
    UnsafePrivateKeyPath,
    #[error("SSH private-key path is not a regular file")]
    PrivateKeyNotRegularFile,
    #[error("remote path is invalid")]
    InvalidRemotePath,
    #[error("remote command argument is invalid")]
    InvalidCommandArgument,
    #[error("SSH transport limits must be non-zero")]
    InvalidTransportLimits,
    #[error("SSH host did not resolve to an address")]
    NoResolvedAddress,
    #[error("SSH server did not provide a host key")]
    HostKeyUnavailable,
    #[error("SSH server selected an unsupported host-key algorithm")]
    UnsupportedHostKeyAlgorithm,
    #[error("SSH host key changed (expected {expected}, received {actual})")]
    HostKeyMismatch { expected: String, actual: String },
    #[error("SSH {method} authentication is unsupported by this transport")]
    UnsupportedAuthenticationMethod { method: AuthenticationMethod },
    #[error("SSH password authentication failed")]
    Authentication {
        #[source]
        source: ssh2::Error,
    },
    #[error("SSH server rejected password authentication")]
    AuthenticationRejected,
    #[error("SSH agent is unavailable")]
    AgentUnavailable,
    #[error("SSH agent authentication failed")]
    AgentAuthenticationFailed,
    #[error("SSH server rejected all SSH-agent identities")]
    AgentAuthenticationRejected,
    #[error("SSH private-key authentication failed")]
    PrivateKeyAuthenticationFailed,
    #[error("SSH server rejected private-key authentication")]
    PrivateKeyAuthenticationRejected,
    #[error("{stream} exceeded the {maximum_bytes}-byte safety limit")]
    OutputLimitExceeded {
        stream: &'static str,
        maximum_bytes: usize,
    },
    #[error("SSH command produced no output for {timeout_millis} milliseconds")]
    CommandOutputTimedOut { timeout_millis: u64 },
    #[error("remote path exists but is not a directory")]
    RemotePathNotDirectory,
    #[error("SSH I/O failed: {0}")]
    Io(#[from] io::Error),
    #[error("SSH protocol operation failed: {0}")]
    Protocol(#[from] ssh2::Error),
}

#[cfg(test)]
mod tests {
    use std::{
        cell::Cell,
        fs,
        io::{self, Read},
        path::{Path, PathBuf},
        sync::{Arc, Mutex},
    };

    use cyc_secrets::Secret;
    use uuid::Uuid;

    use super::{
        AuthenticationMethod, CommandArgument, CommandOutput, FixedCommand, HostKey,
        PrivateKeyFile, RemotePath, RemoteSession, SshAuthentication, SshEndpoint, SshError,
        SshTransport, TransferReceipt,
    };

    #[test]
    fn host_key_fingerprint_matches_openssh_shape() {
        let key = HostKey::from_parts("ssh-ed25519", b"public-host-key".to_vec()).expect("key");
        assert_eq!(key.algorithm(), "ssh-ed25519");
        assert!(key.fingerprint().starts_with("SHA256:"));
        assert!(!key.fingerprint().ends_with('='));
    }

    #[test]
    fn remote_path_requires_an_absolute_non_traversing_path() {
        assert!(RemotePath::new("relative/install.sh").is_err());
        assert!(RemotePath::new("/tmp/../etc/passwd").is_err());
        assert!(RemotePath::new("C:\\CYC\\..\\Windows").is_err());
        assert!(RemotePath::new("/tmp/cyc install.sh").is_ok());
        assert!(RemotePath::new("C:\\CYC Work\\install.ps1").is_ok());
    }

    #[test]
    fn posix_fixed_command_quotes_each_argument() {
        let command = FixedCommand::posix_script(
            RemotePath::new("/tmp/cyc install.sh").expect("path"),
            [CommandArgument::new("$(touch /tmp/nope);'quoted'").expect("argument")],
        );
        assert_eq!(
            command.render(),
            "/bin/sh '/tmp/cyc install.sh' -- '$(touch /tmp/nope);'\"'\"'quoted'\"'\"''"
        );
    }

    #[test]
    fn powershell_fixed_command_uses_encoded_command() {
        let command = FixedCommand::windows_powershell_script(
            RemotePath::new("C:\\CYC Work\\install.ps1").expect("path"),
            [CommandArgument::new("'; Remove-Item C:\\ -Recurse; '").expect("argument")],
        );
        let rendered = command.render();
        assert!(rendered.starts_with("powershell.exe -NoLogo -NoProfile -NonInteractive"));
        assert!(rendered.contains(" -EncodedCommand "));
        assert!(!rendered.contains("Remove-Item"));
    }

    #[test]
    fn debug_output_redacts_arguments_and_remote_output() {
        let command = FixedCommand::posix_script(
            RemotePath::new("/tmp/install.sh").expect("path"),
            [CommandArgument::new("sensitive-looking-value").expect("argument")],
        );
        let command_debug = format!("{command:?}");
        assert!(!command_debug.contains("sensitive-looking-value"));
        assert!(command_debug.contains("argument_count: 1"));

        let output = CommandOutput {
            exit_code: 0,
            stdout: b"sensitive-output".to_vec(),
            stderr: b"sensitive-error".to_vec(),
        };
        let output_debug = format!("{output:?}");
        assert!(!output_debug.contains("sensitive-output"));
        assert!(!output_debug.contains("sensitive-error"));
        assert!(output_debug.contains("stdout_bytes: 16"));
    }

    #[test]
    fn host_key_mismatch_precedes_every_authentication_attempt() {
        let expected = HostKey::from_parts("ssh-ed25519", vec![1, 2, 3]).expect("expected key");
        let actual = HostKey::from_parts("ssh-ed25519", vec![4, 5, 6]).expect("actual key");
        let attempted = Cell::new(false);

        let error = super::authenticate_after_host_key(&actual, &expected, || {
            attempted.set(true);
            Ok(())
        })
        .expect_err("mismatched host key must fail");

        assert!(!attempted.get());
        assert!(matches!(error, SshError::HostKeyMismatch { .. }));
    }

    #[test]
    fn username_validation_rejects_nul_and_line_breaks() {
        assert!(matches!(
            super::validate_username("worker\0admin"),
            Err(SshError::InvalidUsername)
        ));
        assert!(matches!(
            super::validate_username("worker\nadmin"),
            Err(SshError::InvalidUsername)
        ));
        assert!(matches!(
            super::validate_username("worker\radmin"),
            Err(SshError::InvalidUsername)
        ));
        assert!(super::validate_username("worker").is_ok());
    }

    #[test]
    fn private_key_path_is_absolute_regular_and_debug_redacted() {
        let temp = TemporaryDirectory::new();
        let key_path = temp.path().join("id_secret_name");
        fs::write(&key_path, b"private-key-fixture").expect("write key fixture");
        let key = PrivateKeyFile::new(&key_path).expect("validated key");

        let debug = format!("{key:?}");
        assert_eq!(debug, "PrivateKeyFile(<redacted>)");
        assert!(!debug.contains("id_secret_name"));
        assert_eq!(key.as_path(), key_path);

        assert!(matches!(
            PrivateKeyFile::new("relative/id_key"),
            Err(SshError::InvalidPrivateKeyPath)
        ));
        let invalid_control_path = temp.path().join("id\nkey");
        let error = PrivateKeyFile::new(&invalid_control_path).expect_err("newline path");
        assert!(matches!(error, SshError::InvalidPrivateKeyPath));
        assert!(!format!("{error:?}").contains("id\nkey"));
        assert!(matches!(
            PrivateKeyFile::new(temp.path()),
            Err(SshError::PrivateKeyNotRegularFile)
        ));
    }

    #[cfg(unix)]
    #[test]
    fn private_key_path_rejects_symlinks_and_symlinked_parents() {
        use std::os::unix::fs::symlink;

        let temp = TemporaryDirectory::new();
        let real_directory = temp.path().join("real");
        fs::create_dir(&real_directory).expect("real directory");
        let key_path = real_directory.join("id_key");
        fs::write(&key_path, b"private-key-fixture").expect("write key fixture");

        let key_link = temp.path().join("id_link");
        symlink(&key_path, &key_link).expect("key symlink");
        assert!(matches!(
            PrivateKeyFile::new(&key_link),
            Err(SshError::UnsafePrivateKeyPath)
        ));

        let directory_link = temp.path().join("linked-parent");
        symlink(&real_directory, &directory_link).expect("directory symlink");
        assert!(matches!(
            PrivateKeyFile::new(directory_link.join("id_key")),
            Err(SshError::UnsafePrivateKeyPath)
        ));
    }

    #[cfg(windows)]
    #[test]
    fn private_key_path_rejects_windows_reparse_points_when_available() {
        use std::os::windows::fs::symlink_file;

        let temp = TemporaryDirectory::new();
        let key_path = temp.path().join("id_key");
        fs::write(&key_path, b"private-key-fixture").expect("write key fixture");
        let key_link = temp.path().join("id_link");
        match symlink_file(&key_path, &key_link) {
            Ok(()) => assert!(matches!(
                PrivateKeyFile::new(&key_link),
                Err(SshError::UnsafePrivateKeyPath)
            )),
            Err(error)
                if error.kind() == io::ErrorKind::PermissionDenied
                    || error.raw_os_error() == Some(1314) =>
            {
                // Some non-elevated Windows builders cannot create a reparse
                // point. Production rejection is still compiled and covered
                // by the metadata predicate on capable builders.
            }
            Err(error) => panic!("create key symlink: {error}"),
        }
    }

    #[test]
    fn legacy_transport_defaults_new_methods_to_fixed_unsupported_errors() {
        let temp = TemporaryDirectory::new();
        let key_path = temp.path().join("id_key");
        fs::write(&key_path, b"private-key-fixture").expect("write key fixture");
        let key = PrivateKeyFile::new(key_path).expect("validated key");
        let transport = MockTransport::new();
        let endpoint = SshEndpoint::with_default_port("worker.local").expect("endpoint");
        let pinned = transport.probe_host_key(&endpoint).expect("probe");

        assert!(matches!(
            transport.connect_agent(&endpoint, &pinned, "worker"),
            Err(SshError::UnsupportedAuthenticationMethod {
                method: AuthenticationMethod::Agent
            })
        ));
        assert!(matches!(
            transport.connect_private_key(&endpoint, &pinned, "worker", &key, None),
            Err(SshError::UnsupportedAuthenticationMethod {
                method: AuthenticationMethod::PrivateKey
            })
        ));
    }

    #[test]
    fn borrowed_authentication_dispatch_redacts_and_does_not_persist_secrets() {
        let temp = TemporaryDirectory::new();
        let key_path = temp.path().join("id_sensitive_name");
        fs::write(&key_path, b"private-key-fixture").expect("write key fixture");
        let key = PrivateKeyFile::new(&key_path).expect("validated key");
        let passphrase = Secret::from_string("ephemeral-passphrase".to_owned());
        let authentication = SshAuthentication::PrivateKey {
            private_key: &key,
            passphrase: Some(&passphrase),
        };
        let debug = format!("{authentication:?}");
        assert!(!debug.contains("ephemeral-passphrase"));
        assert!(!debug.contains("id_sensitive_name"));
        assert!(debug.contains("<redacted>"));

        let observed = Arc::new(Mutex::new(Vec::new()));
        let transport = AuthenticationBoundaryTransport {
            host_key: HostKey::from_parts("ssh-ed25519", vec![9, 8, 7]).expect("key"),
            observed: Arc::clone(&observed),
        };
        let endpoint = SshEndpoint::with_default_port("worker.local").expect("endpoint");
        let pinned = transport.probe_host_key(&endpoint).expect("probe");
        transport
            .connect_with_authentication(&endpoint, &pinned, "worker", authentication)
            .expect("private-key dispatch");
        transport
            .connect_with_authentication(&endpoint, &pinned, "worker", SshAuthentication::Agent)
            .expect("agent dispatch");

        assert_eq!(
            *observed.lock().expect("observation lock"),
            vec![
                AuthenticationObservation::PrivateKey {
                    passphrase_bytes: Some(20)
                },
                AuthenticationObservation::Agent
            ]
        );
    }

    #[test]
    fn output_pump_interleaves_large_stdout_and_stderr() {
        // Each side is larger than a typical SSH channel receive window. The
        // fake streams only permit one side to read at a time, so a sequential
        // read-to-EOF implementation cannot make progress.
        const STREAM_BYTES: usize = 3 * 1024 * 1024;
        let turn = Arc::new(Mutex::new(0usize));
        let mut stdout_reader = AlternatingReader::new(0, 0x53, STREAM_BYTES, Arc::clone(&turn));
        let mut stderr_reader = AlternatingReader::new(1, 0x45, STREAM_BYTES, Arc::clone(&turn));
        let mut stdout = Vec::new();
        let mut stderr = Vec::new();

        while stdout.len() < STREAM_BYTES || stderr.len() < STREAM_BYTES {
            let progressed = super::pump_available_pair(
                &mut stdout_reader,
                &mut stderr_reader,
                &mut stdout,
                &mut stderr,
                2 * STREAM_BYTES,
            )
            .expect("pump output");
            assert!(progressed);
        }

        assert_eq!(stdout.len(), STREAM_BYTES);
        assert_eq!(stderr.len(), STREAM_BYTES);
        assert!(stdout.iter().all(|byte| *byte == 0x53));
        assert!(stderr.iter().all(|byte| *byte == 0x45));
    }

    #[test]
    fn mock_transport_exercises_password_boundary_without_storing_it() {
        let seen_password_len = Arc::new(Mutex::new(None));
        let transport = MockTransport {
            host_key: HostKey::from_parts("ssh-ed25519", vec![1, 2, 3]).expect("key"),
            seen_password_len: Arc::clone(&seen_password_len),
        };
        let endpoint = SshEndpoint::with_default_port("worker.local").expect("endpoint");
        let pinned = transport.probe_host_key(&endpoint).expect("probe");
        let password = Secret::from_string("one-time-value".to_owned());
        let mut session = transport
            .connect_password(&endpoint, &pinned, "worker", &password)
            .expect("connect");
        let result = session
            .exec_fixed(&FixedCommand::posix_script(
                RemotePath::new("/tmp/check.sh").expect("path"),
                [],
            ))
            .expect("exec");
        assert_eq!(result.exit_code, 0);
        assert_eq!(*seen_password_len.lock().expect("lock"), Some(14));
    }

    struct MockTransport {
        host_key: HostKey,
        seen_password_len: Arc<Mutex<Option<usize>>>,
    }

    impl MockTransport {
        fn new() -> Self {
            Self {
                host_key: HostKey::from_parts("ssh-ed25519", vec![1, 2, 3]).expect("key"),
                seen_password_len: Arc::new(Mutex::new(None)),
            }
        }
    }

    struct TemporaryDirectory {
        path: PathBuf,
    }

    impl TemporaryDirectory {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!("cyc-ssh-test-{}", Uuid::new_v4()));
            fs::create_dir(&path).expect("create temporary directory");
            Self { path }
        }

        fn path(&self) -> &Path {
            &self.path
        }
    }

    impl Drop for TemporaryDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }

    #[derive(Debug, PartialEq, Eq)]
    enum AuthenticationObservation {
        Agent,
        PrivateKey { passphrase_bytes: Option<usize> },
    }

    struct AuthenticationBoundaryTransport {
        host_key: HostKey,
        observed: Arc<Mutex<Vec<AuthenticationObservation>>>,
    }

    impl SshTransport for AuthenticationBoundaryTransport {
        fn probe_host_key(&self, _endpoint: &SshEndpoint) -> Result<HostKey, SshError> {
            Ok(self.host_key.clone())
        }

        fn connect_password(
            &self,
            _endpoint: &SshEndpoint,
            pinned_host_key: &HostKey,
            _username: &str,
            _password: &Secret,
        ) -> Result<Box<dyn RemoteSession>, SshError> {
            super::authenticate_after_host_key(&self.host_key, pinned_host_key, || {
                Ok(Box::new(MockSession) as Box<dyn RemoteSession>)
            })
        }

        fn connect_agent(
            &self,
            _endpoint: &SshEndpoint,
            pinned_host_key: &HostKey,
            username: &str,
        ) -> Result<Box<dyn RemoteSession>, SshError> {
            super::validate_username(username)?;
            super::authenticate_after_host_key(&self.host_key, pinned_host_key, || {
                self.observed
                    .lock()
                    .expect("observation lock")
                    .push(AuthenticationObservation::Agent);
                Ok(Box::new(MockSession) as Box<dyn RemoteSession>)
            })
        }

        fn connect_private_key(
            &self,
            _endpoint: &SshEndpoint,
            pinned_host_key: &HostKey,
            username: &str,
            private_key: &PrivateKeyFile,
            passphrase: Option<&Secret>,
        ) -> Result<Box<dyn RemoteSession>, SshError> {
            super::validate_username(username)?;
            super::authenticate_after_host_key(&self.host_key, pinned_host_key, || {
                private_key.revalidate()?;
                let passphrase_bytes = passphrase.map(Secret::len);
                self.observed
                    .lock()
                    .expect("observation lock")
                    .push(AuthenticationObservation::PrivateKey { passphrase_bytes });
                Ok(Box::new(MockSession) as Box<dyn RemoteSession>)
            })
        }
    }

    struct AlternatingReader {
        id: usize,
        byte: u8,
        remaining: usize,
        turn: Arc<Mutex<usize>>,
    }

    impl AlternatingReader {
        fn new(id: usize, byte: u8, remaining: usize, turn: Arc<Mutex<usize>>) -> Self {
            Self {
                id,
                byte,
                remaining,
                turn,
            }
        }
    }

    impl Read for AlternatingReader {
        fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
            if self.remaining == 0 {
                return Ok(0);
            }
            let mut turn = self.turn.lock().expect("turn lock");
            if *turn != self.id {
                return Err(io::Error::new(
                    io::ErrorKind::WouldBlock,
                    "other stream must be drained",
                ));
            }
            let count = buffer.len().min(self.remaining);
            buffer[..count].fill(self.byte);
            self.remaining -= count;
            *turn = 1 - self.id;
            Ok(count)
        }
    }

    impl SshTransport for MockTransport {
        fn probe_host_key(&self, _endpoint: &SshEndpoint) -> Result<HostKey, SshError> {
            Ok(self.host_key.clone())
        }

        fn connect_password(
            &self,
            _endpoint: &SshEndpoint,
            pinned_host_key: &HostKey,
            _username: &str,
            password: &Secret,
        ) -> Result<Box<dyn RemoteSession>, SshError> {
            if pinned_host_key != &self.host_key {
                return Err(SshError::HostKeyMismatch {
                    expected: pinned_host_key.fingerprint().to_owned(),
                    actual: self.host_key.fingerprint().to_owned(),
                });
            }
            *self.seen_password_len.lock().expect("lock") = Some(password.len());
            Ok(Box::new(MockSession))
        }
    }

    struct MockSession;

    impl RemoteSession for MockSession {
        fn exec_fixed(&mut self, _command: &FixedCommand) -> Result<CommandOutput, SshError> {
            Ok(CommandOutput {
                exit_code: 0,
                stdout: b"ok".to_vec(),
                stderr: Vec::new(),
            })
        }

        fn upload_bytes(
            &mut self,
            _remote_path: &RemotePath,
            content: &[u8],
            _unix_mode: i32,
        ) -> Result<TransferReceipt, SshError> {
            Ok(TransferReceipt {
                bytes: content.len() as u64,
                sha256: super::sha256_hex(content),
            })
        }

        fn download_bytes(
            &mut self,
            _remote_path: &RemotePath,
            _maximum_bytes: usize,
        ) -> Result<Vec<u8>, SshError> {
            Ok(Vec::new())
        }

        fn create_dir(
            &mut self,
            _remote_path: &RemotePath,
            _unix_mode: i32,
        ) -> Result<(), SshError> {
            Ok(())
        }

        fn rename(
            &mut self,
            _from: &RemotePath,
            _to: &RemotePath,
            _overwrite: bool,
        ) -> Result<(), SshError> {
            Ok(())
        }

        fn remove_file(&mut self, _remote_path: &RemotePath) -> Result<(), SshError> {
            Ok(())
        }
    }
}
