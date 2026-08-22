use std::fs::{self, OpenOptions};
use std::io::{ErrorKind, Write};
use std::path::Path;
use std::sync::Arc;

use anyhow::{bail, Context, Result};
use subtle::ConstantTimeEq;
use uuid::Uuid;

const MIN_TOKEN_LEN: usize = 32;
const MAX_TOKEN_LEN: usize = 256;

/// An in-memory bearer token. It intentionally implements neither `Debug` nor
/// `Display`, preventing accidental inclusion in diagnostics.
#[derive(Clone)]
pub struct AuthToken(Arc<str>);

impl AuthToken {
    pub fn parse(value: &str) -> Result<Self> {
        let value = value.trim();
        if !(MIN_TOKEN_LEN..=MAX_TOKEN_LEN).contains(&value.len()) {
            bail!("controller token has an invalid length");
        }
        if !value
            .bytes()
            .all(|byte| byte.is_ascii_graphic() && !byte.is_ascii_whitespace())
        {
            bail!("controller token contains invalid characters");
        }
        Ok(Self(Arc::from(value)))
    }

    pub fn matches(&self, candidate: &str) -> bool {
        let expected = self.0.as_bytes();
        let candidate = candidate.as_bytes();
        expected.len() == candidate.len() && bool::from(expected.ct_eq(candidate))
    }

    #[cfg(test)]
    pub(crate) fn test_token() -> Self {
        Self::parse(&"a".repeat(64)).expect("test token")
    }
}

pub fn load_or_create(path: &Path) -> Result<AuthToken> {
    if let Some(parent) = path.parent().filter(|path| !path.as_os_str().is_empty()) {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create token directory {}", parent.display()))?;
        harden_directory_permissions(parent)
            .with_context(|| format!("failed to secure token directory {}", parent.display()))?;
    }

    match read_token(path) {
        Ok(token) => {
            harden_permissions(path)
                .with_context(|| format!("failed to secure token file {}", path.display()))?;
            return Ok(token);
        }
        Err(error) if error.kind() != ErrorKind::NotFound => {
            return Err(error)
                .with_context(|| format!("failed to read token file {}", path.display()));
        }
        Err(_) => {}
    }

    let generated = format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple());
    match create_token_file(path, generated.as_bytes()) {
        Ok(()) => {}
        Err(error) if error.kind() == ErrorKind::AlreadyExists => {
            // Another controller won the create race. Read its complete value.
            let token = read_token(path)
                .with_context(|| format!("failed to read token file {}", path.display()))?;
            harden_permissions(path)
                .with_context(|| format!("failed to secure token file {}", path.display()))?;
            return Ok(token);
        }
        Err(error) => {
            return Err(error)
                .with_context(|| format!("failed to create token file {}", path.display()));
        }
    }
    if let Err(error) = harden_permissions(path) {
        // Do not leave a newly generated bearer token behind with an unknown
        // DACL/mode when permission hardening failed.
        let _ = fs::remove_file(path);
        return Err(error)
            .with_context(|| format!("failed to secure token file {}", path.display()));
    }
    AuthToken::parse(&generated)
}

fn read_token(path: &Path) -> std::io::Result<AuthToken> {
    let value = fs::read_to_string(path)?;
    AuthToken::parse(&value).map_err(|error| std::io::Error::new(ErrorKind::InvalidData, error))
}

#[cfg(unix)]
fn create_token_file(path: &Path, token: &[u8]) -> std::io::Result<()> {
    use std::os::unix::fs::OpenOptionsExt;

    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(token)?;
    file.sync_all()
}

#[cfg(not(unix))]
fn create_token_file(path: &Path, token: &[u8]) -> std::io::Result<()> {
    let mut file = OpenOptions::new().write(true).create_new(true).open(path)?;
    file.write_all(token)?;
    file.sync_all()
}

#[cfg(unix)]
fn harden_directory_permissions(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;

    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}

#[cfg(windows)]
fn harden_directory_permissions(_path: &Path) -> Result<()> {
    // The installer owns the Windows data-directory DACL bootstrap. The
    // controller still secures the token file itself below and fails closed.
    Ok(())
}

#[cfg(not(any(unix, windows)))]
fn harden_directory_permissions(_path: &Path) -> Result<()> {
    Ok(())
}

#[cfg(unix)]
fn harden_permissions(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;

    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    Ok(())
}

#[cfg(windows)]
fn harden_permissions(path: &Path) -> Result<()> {
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
        .context("whoami did not return a valid Windows SID")?;
    let current_user = format!("*{sid}:(R,W)");
    let permissions = Command::new("icacls.exe")
        .arg(path)
        .args([
            "/inheritance:r",
            "/grant:r",
            &current_user,
            "*S-1-5-18:(R,W)",
        ])
        .output()
        .context("failed to run icacls")?;
    if !permissions.status.success() {
        bail!("icacls failed to secure the controller token");
    }
    Ok(())
}

#[cfg(not(any(unix, windows)))]
fn harden_permissions(_path: &Path) -> Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn creates_and_reuses_a_random_token_file() {
        let directory = std::env::temp_dir().join(format!("cyc-auth-{}", Uuid::new_v4()));
        fs::create_dir_all(&directory).unwrap();
        let path = directory.join("controller.token");
        let first = load_or_create(&path).unwrap();
        let persisted = fs::read_to_string(&path).unwrap();
        assert_eq!(persisted.len(), 64);
        assert!(first.matches(&persisted));
        let second = load_or_create(&path).unwrap();
        assert!(second.matches(&persisted));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;

            assert_eq!(
                fs::metadata(&directory).unwrap().permissions().mode() & 0o777,
                0o700
            );
            assert_eq!(
                fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn matching_is_exact() {
        let token = AuthToken::test_token();
        assert!(token.matches(&"a".repeat(64)));
        assert!(!token.matches(&"a".repeat(63)));
        assert!(!token.matches(&"b".repeat(64)));
    }
}
