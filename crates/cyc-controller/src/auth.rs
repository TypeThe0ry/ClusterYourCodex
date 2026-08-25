use std::fs::{self, File, OpenOptions};
use std::io::{ErrorKind, Write};
use std::path::{Path, PathBuf};
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
    let parent = containing_directory(path);
    let token_preexisted = match fs::symlink_metadata(path) {
        Ok(_) => true,
        Err(error) if error.kind() == ErrorKind::NotFound => false,
        Err(error) => {
            return Err(error)
                .with_context(|| format!("failed to inspect token file {}", path.display()));
        }
    };

    if token_preexisted {
        // Never repair and then trust a token that was already present in a
        // weak directory. An untrusted local principal could have planted a
        // known bearer value before controller startup.
        verify_private_directory(&parent).with_context(|| {
            format!(
                "refusing an existing token in an insecure directory {}",
                parent.display()
            )
        })?;
        validate_private_file(path)
            .with_context(|| format!("refusing an insecure token file {}", path.display()))?;
        return read_token(path)
            .with_context(|| format!("failed to read token file {}", path.display()));
    }

    // Protect the directory before any bearer bytes exist. On Windows a new
    // file inherits only current-user and SYSTEM FullControl; on Unix the
    // directory is owned by the effective uid and mode 0700.
    prepare_private_directory(&parent)
        .with_context(|| format!("failed to secure token directory {}", parent.display()))?;

    let generated = format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple());
    let mut file = match create_token_file(path) {
        Ok(file) => file,
        Err(error) if error.kind() == ErrorKind::AlreadyExists => {
            bail!("token file appeared during secure creation; refusing to trust it");
        }
        Err(error) => {
            return Err(error)
                .with_context(|| format!("failed to create token file {}", path.display()));
        }
    };
    if let Err(error) = harden_permissions(path) {
        // The file is still empty here: ACL/mode hardening always precedes the
        // first secret byte.
        drop(file);
        let _ = fs::remove_file(path);
        return Err(error)
            .with_context(|| format!("failed to secure token file {}", path.display()));
    }
    if let Err(error) = file
        .write_all(generated.as_bytes())
        .and_then(|()| file.sync_all())
    {
        drop(file);
        let _ = fs::remove_file(path);
        return Err(error)
            .with_context(|| format!("failed to persist token file {}", path.display()));
    }
    drop(file);
    validate_private_file(path)
        .with_context(|| format!("failed to verify token file {}", path.display()))?;
    AuthToken::parse(&generated)
}

/// Create (when needed), de-link, and replace a data directory's permissions
/// with the exact single-user controller allowlist.
pub fn prepare_private_directory(path: &Path) -> Result<()> {
    fs::create_dir_all(path)
        .with_context(|| format!("failed to create private directory {}", path.display()))?;
    ensure_no_reparse_components(path)?;
    if !fs::symlink_metadata(path)?.is_dir() {
        bail!("private path is not a directory: {}", path.display());
    }
    harden_directory_permissions(path)?;
    verify_private_directory(path)
}

/// Apply the exact private-file permission contract. This is intentionally an
/// explicit provisioning operation; TLS startup validation below never repairs
/// and silently trusts a weak pre-existing private key.
pub fn prepare_private_file_permissions(path: &Path) -> Result<()> {
    ensure_regular_file_without_reparse(path)?;
    harden_permissions(path)?;
    validate_private_file(path)
}

/// Establish the controller database and object-store trust boundary before
/// SQLite opens a handle. Existing state is never repaired-and-trusted: its
/// parent, database, sidecars, and object root must already satisfy the exact
/// private contract. A new layout is created only after its parent is private.
pub fn prepare_database_layout(path: &Path) -> Result<()> {
    let parent = containing_directory(path);
    let object_root = parent.join("jobs");
    let sidecars = sqlite_sidecar_paths(path);
    let database_exists = inspect_database_layout(path)?;

    if database_exists {
        if !path_exists_no_follow(&object_root)? {
            create_new_private_directory(&object_root)?;
        }
        return Ok(());
    }

    prepare_private_directory(&parent)?;
    // Close the inspection-to-hardening race. Anything that appeared while
    // the namespace was weak is rejected rather than adopted.
    for sidecar in &sidecars {
        if path_exists_no_follow(sidecar)? {
            bail!("refusing SQLite sidecar that appeared during secure database creation");
        }
    }
    if path_exists_no_follow(&object_root)? {
        bail!("refusing object storage that appeared during secure database creation");
    }
    let file = create_token_file(path).with_context(|| {
        format!(
            "failed to create an empty private database {}",
            path.display()
        )
    })?;
    if let Err(error) = harden_permissions(path).and_then(|()| validate_private_file(path)) {
        drop(file);
        let _ = fs::remove_file(path);
        return Err(error).context("failed to secure a new controller database");
    }
    file.sync_all()?;
    drop(file);
    create_new_private_directory(&object_root)?;
    Ok(())
}

/// Validate pre-existing database state without changing any permissions or
/// creating files. `main` uses this before token initialization so securing a
/// new token in the same directory cannot mask a weak, prepositioned database.
pub fn preflight_database_layout(path: &Path) -> Result<()> {
    inspect_database_layout(path).map(|_| ())
}

/// Verify and harden files SQLite materialized while enabling WAL. The exact
/// parent DACL/mode was established before SQLite started, so this operation
/// never trusts bytes created in a weak namespace.
pub fn finalize_database_layout(path: &Path) -> Result<()> {
    verify_private_directory(&containing_directory(path))?;
    validate_private_file(path)?;
    for sidecar in sqlite_sidecar_paths(path) {
        if path_exists_no_follow(&sidecar)? {
            prepare_private_file_permissions(&sidecar).with_context(|| {
                format!("failed to secure SQLite sidecar {}", sidecar.display())
            })?;
        }
    }
    verify_private_directory(&containing_directory(path).join("jobs"))?;
    Ok(())
}

fn inspect_database_layout(path: &Path) -> Result<bool> {
    let parent = containing_directory(path);
    let object_root = parent.join("jobs");
    let sidecars = sqlite_sidecar_paths(path);
    let database_exists = path_exists_no_follow(path)?;

    if database_exists {
        verify_private_directory(&parent).with_context(|| {
            format!(
                "refusing an existing database in an insecure directory {}",
                parent.display()
            )
        })?;
        validate_private_file(path)
            .with_context(|| format!("refusing an insecure database {}", path.display()))?;
        for sidecar in &sidecars {
            if path_exists_no_follow(sidecar)? {
                validate_private_file(sidecar).with_context(|| {
                    format!("refusing an insecure SQLite sidecar {}", sidecar.display())
                })?;
            }
        }
        if path_exists_no_follow(&object_root)? {
            verify_private_directory(&object_root).with_context(|| {
                format!(
                    "refusing an insecure controller object root {}",
                    object_root.display()
                )
            })?;
        }
        return Ok(true);
    }

    if path_exists_no_follow(&parent)? {
        ensure_no_reparse_components(&parent)?;
        if !fs::symlink_metadata(&parent)?.is_dir() {
            bail!("database parent is not a directory: {}", parent.display());
        }
    }
    // A missing main database alongside pre-existing sidecars or objects is an
    // ambiguous, potentially prepositioned layout. Never absorb it into a new
    // controller identity.
    for sidecar in &sidecars {
        if path_exists_no_follow(sidecar)? {
            bail!("refusing pre-existing SQLite sidecars without a database");
        }
    }
    if path_exists_no_follow(&object_root)? {
        bail!("refusing pre-existing object storage without a database");
    }
    Ok(false)
}

/// Public certificates are not secret, but accepting links/reparse points can
/// swap the enrollment identity after validation.
pub fn validate_public_file(path: &Path) -> Result<()> {
    ensure_regular_file_without_reparse(path)
}

/// Validate a secret file without repairing it.
pub fn validate_private_file(path: &Path) -> Result<()> {
    verify_private_directory(&containing_directory(path))?;
    ensure_regular_file_without_reparse(path)?;
    verify_private_file_permissions(path)
}

fn containing_directory(path: &Path) -> PathBuf {
    path.parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."))
        .to_path_buf()
}

fn path_exists_no_follow(path: &Path) -> Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(false),
        Err(error) => {
            Err(error).with_context(|| format!("failed to inspect private path {}", path.display()))
        }
    }
}

fn create_new_private_directory(path: &Path) -> Result<()> {
    fs::create_dir(path)
        .with_context(|| format!("failed to exclusively create directory {}", path.display()))?;
    if let Err(error) = prepare_private_directory(path) {
        let _ = fs::remove_dir(path);
        return Err(error);
    }
    Ok(())
}

fn sqlite_sidecar_paths(path: &Path) -> [PathBuf; 3] {
    ["-wal", "-shm", "-journal"].map(|suffix| {
        let mut value = path.as_os_str().to_os_string();
        value.push(suffix);
        PathBuf::from(value)
    })
}

fn read_token(path: &Path) -> std::io::Result<AuthToken> {
    let value = fs::read_to_string(path)?;
    AuthToken::parse(&value).map_err(|error| std::io::Error::new(ErrorKind::InvalidData, error))
}

#[cfg(unix)]
fn create_token_file(path: &Path) -> std::io::Result<File> {
    use std::os::unix::fs::OpenOptionsExt;

    OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
}

#[cfg(not(unix))]
fn create_token_file(path: &Path) -> std::io::Result<File> {
    OpenOptions::new().write(true).create_new(true).open(path)
}

#[cfg(unix)]
fn harden_directory_permissions(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;

    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}

#[cfg(windows)]
fn harden_directory_permissions(path: &Path) -> Result<()> {
    invoke_windows_acl("powershell.exe", path, "directory", "apply")
        .context("failed to replace and verify the private directory DACL")
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
    invoke_windows_acl("powershell.exe", path, "file", "apply")
        .context("failed to replace and verify the private file DACL")
}

fn ensure_regular_file_without_reparse(path: &Path) -> Result<()> {
    ensure_no_reparse_components(path)?;
    let metadata = fs::symlink_metadata(path)
        .with_context(|| format!("failed to inspect {}", path.display()))?;
    if !metadata.file_type().is_file() {
        bail!("{} must be a regular file", path.display());
    }
    Ok(())
}

fn ensure_no_reparse_components(path: &Path) -> Result<()> {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .context("failed to resolve the current directory")?
            .join(path)
    };
    let mut candidate = PathBuf::new();
    for component in absolute.components() {
        candidate.push(component.as_os_str());
        let metadata = match fs::symlink_metadata(&candidate) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == ErrorKind::NotFound => continue,
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("failed to inspect {}", candidate.display()));
            }
        };
        if metadata.file_type().is_symlink() || metadata_is_windows_reparse(&metadata) {
            bail!(
                "reparse points and symbolic links are forbidden in private paths: {}",
                candidate.display()
            );
        }
    }
    Ok(())
}

#[cfg(windows)]
fn metadata_is_windows_reparse(metadata: &fs::Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;

    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
    metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

#[cfg(not(windows))]
fn metadata_is_windows_reparse(_metadata: &fs::Metadata) -> bool {
    false
}

#[cfg(unix)]
fn verify_private_directory(path: &Path) -> Result<()> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    ensure_no_reparse_components(path)?;
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_dir() {
        bail!("private path is not a directory");
    }
    if metadata.uid() != unsafe { libc::geteuid() } {
        bail!("private directory is not owned by the effective user");
    }
    if metadata.permissions().mode() & 0o777 != 0o700 {
        bail!("private directory mode must be 0700");
    }
    Ok(())
}

#[cfg(windows)]
fn verify_private_directory(path: &Path) -> Result<()> {
    ensure_no_reparse_components(path)?;
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_dir() {
        bail!("private path is not a directory");
    }
    invoke_windows_acl("powershell.exe", path, "directory", "verify")
        .context("private directory DACL is not the exact current-user and SYSTEM allowlist")
}

#[cfg(not(any(unix, windows)))]
fn verify_private_directory(path: &Path) -> Result<()> {
    ensure_no_reparse_components(path)?;
    if !fs::symlink_metadata(path)?.is_dir() {
        bail!("private path is not a directory");
    }
    Ok(())
}

#[cfg(unix)]
fn verify_private_file_permissions(path: &Path) -> Result<()> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    let metadata = fs::symlink_metadata(path)?;
    if metadata.uid() != unsafe { libc::geteuid() } {
        bail!("private file is not owned by the effective user");
    }
    if metadata.permissions().mode() & 0o777 != 0o600 {
        bail!("private file mode must be 0600");
    }
    Ok(())
}

#[cfg(windows)]
fn verify_private_file_permissions(path: &Path) -> Result<()> {
    invoke_windows_acl("powershell.exe", path, "file", "verify")
        .context("private file DACL is not the exact current-user and SYSTEM allowlist")
}

#[cfg(not(any(unix, windows)))]
fn verify_private_file_permissions(_path: &Path) -> Result<()> {
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
        .context("whoami did not return a valid Windows SID")?;
    Ok(sid.to_owned())
}

#[cfg(windows)]
fn invoke_windows_acl(shell: &str, path: &Path, kind: &str, action: &str) -> Result<()> {
    use std::process::Command;

    let sid = current_windows_user_sid()?;
    let operation = Command::new(shell)
        .args([
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            WINDOWS_ACL_SCRIPT,
        ])
        .env("CYC_PRIVATE_ACL_PATH", path)
        .env("CYC_PRIVATE_ACL_SID", sid)
        .env("CYC_PRIVATE_ACL_KIND", kind)
        .env("CYC_PRIVATE_ACL_ACTION", action)
        .output()
        .with_context(|| format!("failed to launch {shell} ACL operation"))?;
    if !operation.status.success() {
        if let Some(detail) = bounded_windows_acl_diagnostic(
            &operation.stderr,
            "controller private-path ACL operation failed: ",
        ) {
            bail!("private path ACL operation failed ({detail})");
        }
        bail!("private path ACL operation failed");
    }
    Ok(())
}

#[cfg(windows)]
fn bounded_windows_acl_diagnostic(stderr: &[u8], expected_prefix: &str) -> Option<String> {
    const MAX_DIAGNOSTIC_BYTES: usize = 384;

    String::from_utf8_lossy(stderr).lines().find_map(|line| {
        let sanitized = line
            .chars()
            .map(|character| {
                if character.is_ascii_control() || !character.is_ascii() {
                    '?'
                } else {
                    character
                }
            })
            .take(MAX_DIAGNOSTIC_BYTES)
            .collect::<String>();
        let suffix = sanitized.trim().strip_prefix(expected_prefix)?;
        if suffix.is_empty()
            || !suffix.bytes().all(|byte| {
                byte.is_ascii_lowercase()
                    || byte.is_ascii_digit()
                    || matches!(byte, b'A'..=b'F' | b'=' | b',' | b'-' | b'_' | b'x')
            })
        {
            return None;
        }
        Some(format!("{expected_prefix}{suffix}"))
    })
}

#[cfg(windows)]
const WINDOWS_ACL_SCRIPT: &str = r#"
$ErrorActionPreference = 'Stop'
$diagnostic = 'stage=bootstrap'
try {
    function ConvertTo-CanonicalFileAccessMask([int64]$rawMask) {
        if ($rawMask -lt 0) { $rawMask += 0x100000000L }
        if ($rawMask -lt 0 -or $rawMask -gt 0xFFFFFFFFL) {
            throw 'access mask is outside the 32-bit range'
        }

        # FILE_GENERIC_MAPPING. Generic bits are replaced, not retained, and
        # Synchronize is never added independently to a non-generic mask.
        $canonical = $rawMask -band 0x0FFFFFFFL
        if (($rawMask -band 0x80000000L) -ne 0) { $canonical = $canonical -bor 0x00120089L }
        if (($rawMask -band 0x40000000L) -ne 0) { $canonical = $canonical -bor 0x00120116L }
        if (($rawMask -band 0x20000000L) -ne 0) { $canonical = $canonical -bor 0x001200A0L }
        if (($rawMask -band 0x10000000L) -ne 0) { $canonical = $canonical -bor 0x001F01FFL }
        return [int64]$canonical
    }

    $action = [Environment]::GetEnvironmentVariable('CYC_PRIVATE_ACL_ACTION')
    if ($action -eq 'normalize-mask') {
        $diagnostic = 'stage=normalize-mask'
        $rawMaskText = [Environment]::GetEnvironmentVariable('CYC_PRIVATE_ACL_RAW_MASK')
        if ([string]::IsNullOrWhiteSpace($rawMaskText)) {
            $diagnostic = 'code=missing-mask'
            throw 'ACL contract violation'
        }
        $rawMask = [int64]::Parse(
            $rawMaskText,
            [Globalization.NumberStyles]::Integer,
            [Globalization.CultureInfo]::InvariantCulture)
        $canonicalMask = ConvertTo-CanonicalFileAccessMask $rawMask
        $isExact = $canonicalMask -eq 0x001F01FFL
        [Console]::Out.WriteLine(('{0:X8},{1}' -f $canonicalMask, $isExact.ToString().ToLowerInvariant()))
        exit 0
    }

    $diagnostic = 'stage=read-input'
    $path = [Environment]::GetEnvironmentVariable('CYC_PRIVATE_ACL_PATH')
    $sidText = [Environment]::GetEnvironmentVariable('CYC_PRIVATE_ACL_SID')
    $kind = [Environment]::GetEnvironmentVariable('CYC_PRIVATE_ACL_KIND')
    if ([string]::IsNullOrWhiteSpace($path) -or [string]::IsNullOrWhiteSpace($sidText) -or $kind -notin @('file', 'directory')) {
        $diagnostic = 'code=missing-input'
        throw 'ACL contract violation'
    }
    if ($action -notin @('apply', 'verify')) {
        $diagnostic = 'code=invalid-action'
        throw 'ACL contract violation'
    }
    $diagnostic = 'stage=parse-principals'
    $user = [System.Security.Principal.SecurityIdentifier]::new($sidText)
    $system = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $diagnostic = 'stage=resolve-target'
    if ($kind -eq 'directory') {
        $item = [System.IO.DirectoryInfo]::new($path)
        $inheritance = ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit)
    } else {
        $item = [System.IO.FileInfo]::new($path)
        $inheritance = [System.Security.AccessControl.InheritanceFlags]::None
    }
    $item.Refresh()
    if (-not $item.Exists) {
        $diagnostic = 'code=target-missing'
        throw 'ACL contract violation'
    }
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        $diagnostic = 'code=target-reparse'
        throw 'ACL contract violation'
    }
    if ($action -eq 'apply') {
        $diagnostic = 'stage=build-dacl'
        if ($kind -eq 'directory') {
            $replacement = [System.Security.AccessControl.DirectorySecurity]::new()
        } else {
            $replacement = [System.Security.AccessControl.FileSecurity]::new()
        }
        $replacement.SetOwner($user)
        $replacement.SetAccessRuleProtection($true, $false)
        foreach ($principal in @($user, $system)) {
            $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                $principal,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                $inheritance,
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow)
            [void]$replacement.AddAccessRule($rule)
        }
        $diagnostic = 'stage=apply-dacl'
        if ($item.PSObject.Methods.Name -contains 'SetAccessControl') {
            $item.SetAccessControl($replacement)
        } else {
            [System.IO.FileSystemAclExtensions]::SetAccessControl($item, $replacement)
        }
    }

    # Discard the FileSystemInfo used to write the descriptor. Windows
    # PowerShell and pwsh can otherwise expose a cached pre-write descriptor.
    $diagnostic = 'stage=reload-target'
    if ($kind -eq 'directory') {
        $item = [System.IO.DirectoryInfo]::new($path)
    } else {
        $item = [System.IO.FileInfo]::new($path)
    }
    $item.Refresh()
    if (-not $item.Exists) {
        $diagnostic = 'code=target-missing-after-reload'
        throw 'ACL contract violation'
    }
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        $diagnostic = 'code=target-reparse-after-reload'
        throw 'ACL contract violation'
    }

    $diagnostic = 'stage=read-dacl'
    if ($item.PSObject.Methods.Name -contains 'GetAccessControl') {
        $acl = $item.GetAccessControl()
    } else {
        $acl = [System.IO.FileSystemAclExtensions]::GetAccessControl($item)
    }
    if (-not $acl.AreAccessRulesProtected) {
        $diagnostic = 'code=dacl-not-protected'
        throw 'ACL contract violation'
    }
    $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    if ($owner -ne $sidText) {
        $diagnostic = 'code=owner'
        throw 'ACL contract violation'
    }
    $rules = @($acl.GetAccessRules(
        $true, $true, [System.Security.Principal.SecurityIdentifier]))
    if ($rules.Count -ne 2) {
        $diagnostic = 'code=ace-count,count=' + [string]$rules.Count
        throw 'ACL contract violation'
    }
    $expected = @{$sidText = $false; 'S-1-5-18' = $false}
    $ruleIndex = 0
    foreach ($rule in $rules) {
        $ruleSid = $rule.IdentityReference.Value
        if (-not $expected.ContainsKey($ruleSid) -or $expected[$ruleSid]) {
            $diagnostic = 'code=principal,index=' + [string]$ruleIndex
            throw 'ACL contract violation'
        }
        if ($rule.IsInherited) {
            $diagnostic = 'code=inherited,index=' + [string]$ruleIndex
            throw 'ACL contract violation'
        }
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) {
            $diagnostic = 'code=access-type,index=' + [string]$ruleIndex
            throw 'ACL contract violation'
        }
        if ($rule.InheritanceFlags -ne $inheritance) {
            $diagnostic = 'code=inheritance,index=' + [string]$ruleIndex
            throw 'ACL contract violation'
        }
        if ($rule.PropagationFlags -ne [System.Security.AccessControl.PropagationFlags]::None) {
            $diagnostic = 'code=propagation,index=' + [string]$ruleIndex
            throw 'ACL contract violation'
        }
        $diagnostic = 'stage=normalize-mask,index=' + [string]$ruleIndex
        $canonicalMask = ConvertTo-CanonicalFileAccessMask ([int64]$rule.FileSystemRights)
        if ($canonicalMask -ne 0x001F01FFL) {
            $diagnostic = 'code=access-mask,index=' + [string]$ruleIndex +
                ',mask=0x' + $canonicalMask.ToString('X8', [Globalization.CultureInfo]::InvariantCulture)
            throw 'ACL contract violation'
        }
        $expected[$ruleSid] = $true
        $ruleIndex++
    }
    if ($expected.Values -contains $false) {
        $diagnostic = 'code=required-principal'
        throw 'ACL contract violation'
    }
} catch {
    [Console]::Error.WriteLine('controller private-path ACL operation failed: ' + $diagnostic)
    exit 1
}
"#;

#[cfg(not(any(unix, windows)))]
fn harden_permissions(_path: &Path) -> Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_directory(label: &str) -> PathBuf {
        // macOS exposes its per-user temporary directory through `/var`,
        // which is itself a symlink to `/private/var`. Production private
        // paths deliberately reject every symlink component, so construct
        // security-test fixtures below the resolved temporary root instead of
        // weakening that fail-closed contract for the platform default.
        #[cfg(unix)]
        let root = fs::canonicalize(std::env::temp_dir())
            .expect("canonicalize the existing system temporary directory");
        // `std::fs::canonicalize` introduces a verbatim (`\\?\`) prefix on
        // Windows. The production component walker intentionally handles the
        // normal Win32 path supplied by callers, so tests keep that form.
        #[cfg(not(unix))]
        let root = std::env::temp_dir();
        root.join(format!("cyc-auth-{label}-{}", Uuid::new_v4()))
    }

    #[cfg(unix)]
    fn make_directory_weak(path: &Path) {
        use std::os::unix::fs::PermissionsExt;

        fs::set_permissions(path, fs::Permissions::from_mode(0o777)).unwrap();
    }

    #[cfg(windows)]
    fn make_directory_weak(path: &Path) {
        use std::process::Command;

        let output = Command::new("icacls.exe")
            .arg(path)
            .args(["/grant", "*S-1-1-0:(OI)(CI)(F)"])
            .output()
            .unwrap();
        assert!(output.status.success());
    }

    #[cfg(unix)]
    fn make_file_weak(path: &Path) {
        use std::os::unix::fs::PermissionsExt;

        fs::set_permissions(path, fs::Permissions::from_mode(0o666)).unwrap();
    }

    #[cfg(windows)]
    fn make_file_weak(path: &Path) {
        use std::process::Command;

        let output = Command::new("icacls.exe")
            .arg(path)
            .args(["/grant", "*S-1-1-0:(R)"])
            .output()
            .unwrap();
        assert!(output.status.success());
    }

    #[test]
    fn creates_and_reuses_a_random_token_file() {
        let directory = test_directory("roundtrip");
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
    fn prepositioned_known_token_in_a_weak_parent_is_rejected() {
        let directory = test_directory("prepositioned");
        fs::create_dir_all(&directory).unwrap();
        let path = directory.join("controller.token");
        fs::write(&path, "known-token-value-that-is-long-enough").unwrap();
        make_directory_weak(&directory);

        let error = format!("{:#}", load_or_create(&path).err().unwrap());
        assert!(error.contains("insecure directory"), "{error}");
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn new_token_secures_a_weak_parent_before_persisting_secret_bytes() {
        let directory = test_directory("weak-parent");
        fs::create_dir_all(&directory).unwrap();
        make_directory_weak(&directory);
        let path = directory.join("controller.token");

        let token = load_or_create(&path).unwrap();
        let persisted = fs::read_to_string(&path).unwrap();
        assert!(token.matches(&persisted));
        verify_private_directory(&directory).unwrap();
        validate_private_file(&path).unwrap();
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn reparse_or_symlink_parent_is_rejected() {
        let base = test_directory("linked-parent");
        let target = base.join("target");
        let link = base.join("link");
        fs::create_dir_all(&target).unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(&target, &link).unwrap();
        #[cfg(windows)]
        {
            use std::process::Command;

            let output = Command::new("cmd.exe")
                .args(["/d", "/c", "mklink", "/J"])
                .arg(&link)
                .arg(&target)
                .output()
                .unwrap();
            assert!(output.status.success());
        }

        let error = format!(
            "{:#}",
            load_or_create(&link.join("controller.token"))
                .err()
                .unwrap()
        );
        assert!(
            error.contains("reparse") || error.contains("symbolic"),
            "{error}"
        );
        #[cfg(windows)]
        fs::remove_dir(&link).unwrap();
        #[cfg(unix)]
        fs::remove_file(&link).unwrap();
        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn new_database_layout_secures_database_sidecars_and_object_root() {
        let directory = test_directory("database-new");
        fs::create_dir_all(&directory).unwrap();
        make_directory_weak(&directory);
        let database = directory.join("controller.db");

        prepare_database_layout(&database).unwrap();
        verify_private_directory(&directory).unwrap();
        validate_private_file(&database).unwrap();
        verify_private_directory(&directory.join("jobs")).unwrap();

        let wal = sqlite_sidecar_paths(&database)[0].clone();
        fs::write(&wal, b"simulated SQLite WAL").unwrap();
        make_file_weak(&wal);
        assert!(validate_private_file(&wal).is_err());
        finalize_database_layout(&database).unwrap();
        validate_private_file(&wal).unwrap();

        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn prepositioned_database_in_a_weak_parent_is_rejected() {
        let directory = test_directory("database-prepositioned");
        prepare_private_directory(&directory).unwrap();
        let database = directory.join("controller.db");
        fs::write(&database, b"known database bytes").unwrap();
        prepare_private_file_permissions(&database).unwrap();
        make_directory_weak(&directory);

        let error = format!("{:#}", prepare_database_layout(&database).err().unwrap());
        assert!(error.contains("insecure directory"), "{error}");
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn weak_existing_database_file_is_rejected_without_repair() {
        let directory = test_directory("database-weak-file");
        prepare_private_directory(&directory).unwrap();
        let database = directory.join("controller.db");
        fs::write(&database, b"known database bytes").unwrap();
        make_file_weak(&database);

        let error = format!("{:#}", prepare_database_layout(&database).err().unwrap());
        assert!(error.contains("insecure database"), "{error}");
        assert!(validate_private_file(&database).is_err());
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn weak_existing_sqlite_sidecar_is_rejected_without_repair() {
        let directory = test_directory("database-weak-sidecar");
        prepare_private_directory(&directory).unwrap();
        let database = directory.join("controller.db");
        fs::write(&database, b"database bytes").unwrap();
        prepare_private_file_permissions(&database).unwrap();
        let wal = sqlite_sidecar_paths(&database)[0].clone();
        fs::write(&wal, b"prepositioned WAL bytes").unwrap();
        make_file_weak(&wal);

        let error = format!("{:#}", prepare_database_layout(&database).err().unwrap());
        assert!(error.contains("SQLite sidecar"), "{error}");
        assert!(validate_private_file(&wal).is_err());
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn precreated_or_weak_object_root_is_rejected() {
        let without_database = test_directory("objects-precreated");
        fs::create_dir_all(without_database.join("jobs")).unwrap();
        let database = without_database.join("controller.db");
        let error = format!("{:#}", prepare_database_layout(&database).err().unwrap());
        assert!(
            error.contains("object storage without a database"),
            "{error}"
        );
        fs::remove_dir_all(without_database).unwrap();

        let directory = test_directory("objects-weak");
        prepare_private_directory(&directory).unwrap();
        let database = directory.join("controller.db");
        fs::write(&database, b"database bytes").unwrap();
        prepare_private_file_permissions(&database).unwrap();
        let object_root = directory.join("jobs");
        fs::create_dir(&object_root).unwrap();
        make_directory_weak(&object_root);

        let error = format!("{:#}", prepare_database_layout(&database).err().unwrap());
        assert!(error.contains("object root"), "{error}");
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn database_reparse_or_symlink_parent_is_rejected() {
        let base = test_directory("database-linked-parent");
        let target = base.join("target");
        let link = base.join("link");
        fs::create_dir_all(&target).unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(&target, &link).unwrap();
        #[cfg(windows)]
        {
            use std::process::Command;

            let output = Command::new("cmd.exe")
                .args(["/d", "/c", "mklink", "/J"])
                .arg(&link)
                .arg(&target)
                .output()
                .unwrap();
            assert!(output.status.success());
        }

        let error = format!(
            "{:#}",
            prepare_database_layout(&link.join("controller.db"))
                .err()
                .unwrap()
        );
        assert!(
            error.contains("reparse") || error.contains("symbolic"),
            "{error}"
        );
        #[cfg(windows)]
        fs::remove_dir(&link).unwrap();
        #[cfg(unix)]
        fs::remove_file(&link).unwrap();
        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn matching_is_exact() {
        let token = AuthToken::test_token();
        assert!(token.matches(&"a".repeat(64)));
        assert!(!token.matches(&"a".repeat(63)));
        assert!(!token.matches(&"b".repeat(64)));
    }

    #[cfg(windows)]
    #[test]
    fn windows_acl_mask_normalization_is_strict_and_maps_generic_bits() {
        use std::process::Command;

        let cases = [
            (0x001F01FF_i64, "001F01FF,true"),
            (0x10000000_i64, "001F01FF,true"),
            (-0x80000000_i64, "00120089,false"),
            (0x40000000_i64, "00120116,false"),
            (0x20000000_i64, "001200A0,false"),
            (0x000F01FF_i64, "000F01FF,false"),
            (0x011F01FF_i64, "011F01FF,false"),
            (0x021F01FF_i64, "021F01FF,false"),
        ];

        for (raw_mask, expected) in cases {
            let output = Command::new("powershell.exe")
                .args([
                    "-NoLogo",
                    "-NoProfile",
                    "-NonInteractive",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-Command",
                    WINDOWS_ACL_SCRIPT,
                ])
                .env("CYC_PRIVATE_ACL_ACTION", "normalize-mask")
                .env("CYC_PRIVATE_ACL_RAW_MASK", raw_mask.to_string())
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "normalization failed for {raw_mask}: {}",
                String::from_utf8_lossy(&output.stderr)
            );
            assert_eq!(String::from_utf8_lossy(&output.stdout).trim(), expected);
        }
    }

    #[cfg(windows)]
    #[test]
    fn hardening_removes_preexisting_explicit_everyone_allow() {
        use std::process::Command;

        let directory = test_directory("acl-repair");
        prepare_private_directory(&directory).unwrap();
        let path = directory.join("controller.token");
        fs::write(&path, "a".repeat(64)).unwrap();
        let injected = Command::new("icacls.exe")
            .arg(&path)
            .args(["/grant", "*S-1-1-0:(R)"])
            .output()
            .unwrap();
        assert!(injected.status.success());
        assert!(validate_private_file(&path).is_err());
        prepare_private_file_permissions(&path).unwrap();
        validate_private_file(&path).unwrap();
        fs::remove_dir_all(directory).unwrap();
    }

    #[cfg(windows)]
    #[test]
    fn acl_contract_runs_under_windows_powershell_and_pwsh() {
        use std::process::Command;

        let directory = test_directory("acl-runtimes");
        prepare_private_directory(&directory).unwrap();
        let path = directory.join("controller.token");
        fs::write(&path, "a".repeat(64)).unwrap();
        prepare_private_file_permissions(&path).unwrap();

        for shell in ["powershell.exe", "pwsh.exe"] {
            if shell == "pwsh.exe"
                && !Command::new("where.exe")
                    .arg(shell)
                    .output()
                    .is_ok_and(|output| output.status.success())
            {
                continue;
            }
            invoke_windows_acl(shell, &directory, "directory", "verify").unwrap();
            invoke_windows_acl(shell, &path, "file", "verify").unwrap();
        }
        fs::remove_dir_all(directory).unwrap();
    }
}
