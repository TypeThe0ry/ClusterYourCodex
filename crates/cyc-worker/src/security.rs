use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
#[cfg(windows)]
use std::process::Command;

use anyhow::{bail, Context, Result};

/// A deliberately non-debuggable, non-serializable credential value.
pub struct SecretString(String);

impl SecretString {
    pub fn new(value: String) -> Result<Self> {
        let value = value.trim().to_owned();
        if value.is_empty() {
            bail!("credential file is empty");
        }
        if value.contains(['\r', '\n', '\0']) {
            bail!("credential contains an invalid control character");
        }
        Ok(Self(value))
    }

    pub fn expose(&self) -> &str {
        &self.0
    }
}

impl Drop for SecretString {
    fn drop(&mut self) {
        // Avoid leaving an additional long-lived copy in allocator memory. This
        // is best-effort (String itself does not promise zeroization).
        unsafe { self.0.as_bytes_mut().fill(0) };
    }
}

pub fn read_secret_file(path: &Path) -> Result<SecretString> {
    ensure_protected_input(path)?;

    let mut file = File::open(path)
        .with_context(|| format!("open protected credential file {}", path.display()))?;
    let length = file.metadata().context("read credential metadata")?.len();
    if length > 16 * 1024 {
        bail!("credential file is unexpectedly large");
    }
    let mut value = String::new();
    file.read_to_string(&mut value)
        .context("read credential as UTF-8")?;
    SecretString::new(value)
}

pub fn ensure_protected_input(path: &Path) -> Result<()> {
    ensure_no_links_or_reparse_points(path)?;
    ensure_regular_non_link(path)?;
    verify_private_directory(&containing_directory(path))?;
    verify_private_file_permissions(path)?;
    Ok(())
}

pub fn write_secret_file(path: &Path, value: &str) -> Result<()> {
    if value.is_empty() || value.contains(['\r', '\n', '\0']) {
        bail!("refusing to persist an empty or malformed credential");
    }
    write_protected_file(path, value.as_bytes())
}

/// Persist trusted worker state without ever repairing and then consuming an
/// existing file. The containing directory may be freshly provisioned, but an
/// existing directory is verify-only. The target itself is always create-new.
pub(crate) fn write_protected_file(path: &Path, value: &[u8]) -> Result<()> {
    let parent = containing_directory(path);
    prepare_private_directory(&parent)?;
    if path_entry_exists(path)? {
        bail!("protected output already exists: {}", path.display());
    }

    let temporary = sibling_temporary_path(path)?;
    let result = (|| -> Result<()> {
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options
            .open(&temporary)
            .with_context(|| format!("create protected temporary file {}", temporary.display()))?;
        if let Err(error) = harden_private_file(&temporary) {
            drop(file);
            let _ = fs::remove_file(&temporary);
            return Err(error).context("secure protected temporary file before writing bytes");
        }

        file.write_all(value).context("write protected file")?;
        file.sync_all().context("flush protected file")?;
        drop(file);

        ensure_protected_input(&temporary)?;
        ensure_no_links_or_reparse_points(path)?;
        if path_entry_exists(path)? {
            bail!("protected output appeared concurrently: {}", path.display());
        }

        #[cfg(unix)]
        {
            fs::hard_link(&temporary, path).with_context(|| {
                format!(
                    "atomically install protected file {} -> {}",
                    temporary.display(),
                    path.display()
                )
            })?;
            sync_directory(&parent)?;
            fs::remove_file(&temporary)
                .with_context(|| format!("remove protected temporary {}", temporary.display()))?;
            sync_directory(&parent)?;
        }
        #[cfg(windows)]
        atomic_install_private_file_windows(&temporary, path)?;
        #[cfg(not(any(unix, windows)))]
        compile_error!("protected file atomic installation is not implemented for this platform");

        ensure_protected_input(path)?;
        Ok(())
    })();
    if result.is_err() && !path_entry_exists(path).unwrap_or(false) {
        let _ = fs::remove_file(&temporary);
    }
    result
}

/// Provision a missing private directory, or verify an existing one without
/// changing it. Missing path components are created one at a time and secured
/// before a child can be created below them.
pub(crate) fn prepare_private_directory(path: &Path) -> Result<()> {
    let absolute = absolute_path_without_following_links(path)?;
    ensure_no_links_or_reparse_points(&absolute)?;
    if path_entry_exists(&absolute)? {
        return verify_private_directory(&absolute);
    }

    let mut missing = Vec::new();
    let mut candidate = absolute.as_path();
    loop {
        match fs::symlink_metadata(candidate) {
            Ok(metadata) => {
                if !metadata.is_dir()
                    || metadata.file_type().is_symlink()
                    || metadata_is_windows_reparse(&metadata)
                {
                    bail!(
                        "private directory ancestor is not a direct directory: {}",
                        candidate.display()
                    );
                }
                break;
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                missing.push(candidate.to_path_buf());
                candidate = candidate
                    .parent()
                    .context("private directory path has no existing ancestor")?;
            }
            Err(error) => {
                return Err(error).with_context(|| {
                    format!("inspect private directory ancestor {}", candidate.display())
                });
            }
        }
    }

    for directory in missing.iter().rev() {
        fs::create_dir(directory).with_context(|| {
            format!(
                "exclusively create fresh private directory {}",
                directory.display()
            )
        })?;
        if let Err(error) =
            harden_private_directory(directory).and_then(|()| verify_private_directory(directory))
        {
            let _ = fs::remove_dir(directory);
            return Err(error).with_context(|| {
                format!("secure fresh private directory {}", directory.display())
            });
        }
    }
    verify_private_directory(&absolute)
}

pub(crate) fn ensure_protected_directory(path: &Path) -> Result<()> {
    verify_private_directory(path)
}

fn sibling_temporary_path(path: &Path) -> Result<PathBuf> {
    let filename = path
        .file_name()
        .context("protected output must have a filename")?;
    let mut temporary = std::ffi::OsString::from(".");
    temporary.push(filename);
    temporary.push(format!(".tmp-{}", uuid::Uuid::new_v4()));
    Ok(path.with_file_name(temporary))
}

/// Reject every Windows reparse point already present in `path` or one of its
/// ancestors. `symlink_metadata` alone only identifies a link when that link is
/// the final component; walking upward is required to catch a junction in the
/// workspace path before a guard file is created below it.
pub(crate) fn ensure_no_windows_reparse_points(path: &Path) -> Result<()> {
    #[cfg(windows)]
    ensure_no_links_or_reparse_points(path)?;
    #[cfg(not(windows))]
    let _ = path;
    Ok(())
}

fn ensure_no_links_or_reparse_points(path: &Path) -> Result<()> {
    let absolute = absolute_path_without_following_links(path)?;
    #[cfg(windows)]
    let components = absolute.ancestors().collect::<Vec<_>>();
    // Unix private-file verification separately checks the file and its exact
    // containing directory. Avoid rejecting conventional platform aliases
    // such as macOS `/var` while still refusing a linked trust boundary.
    #[cfg(not(windows))]
    let components = vec![absolute.as_path()];
    for component in components {
        let metadata = match fs::symlink_metadata(component) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => {
                return Err(error).with_context(|| {
                    format!("inspect existing path component {}", component.display())
                });
            }
        };
        if metadata.file_type().is_symlink() || metadata_is_windows_reparse(&metadata) {
            bail!(
                "symbolic links and reparse points are forbidden in protected paths: {}",
                component.display()
            );
        }
    }
    Ok(())
}

fn absolute_path_without_following_links(path: &Path) -> Result<PathBuf> {
    if path.is_absolute() {
        Ok(path.to_path_buf())
    } else {
        Ok(std::env::current_dir()
            .context("resolve current directory for protected path")?
            .join(path))
    }
}

fn containing_directory(path: &Path) -> PathBuf {
    path.parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."))
        .to_path_buf()
}

fn path_entry_exists(path: &Path) -> Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error).with_context(|| format!("inspect path entry {}", path.display())),
    }
}

#[cfg(windows)]
fn metadata_is_windows_reparse(metadata: &fs::Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;
    use windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT;

    metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

#[cfg(not(windows))]
fn metadata_is_windows_reparse(_metadata: &fs::Metadata) -> bool {
    false
}

fn ensure_regular_non_link(path: &Path) -> Result<()> {
    let metadata = fs::symlink_metadata(path)
        .with_context(|| format!("inspect protected file {}", path.display()))?;
    if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
        bail!(
            "protected path is not a regular non-link file: {}",
            path.display()
        );
    }
    if metadata_is_windows_reparse(&metadata) {
        bail!("protected path is a reparse point: {}", path.display());
    }
    Ok(())
}

#[cfg(unix)]
fn harden_private_directory(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;

    fs::set_permissions(path, fs::Permissions::from_mode(0o700))
        .with_context(|| format!("set private directory mode on {}", path.display()))
}

#[cfg(windows)]
fn harden_private_directory(path: &Path) -> Result<()> {
    restrict_windows_acl(path)
}

#[cfg(not(any(unix, windows)))]
fn harden_private_directory(_path: &Path) -> Result<()> {
    Ok(())
}

#[cfg(unix)]
fn harden_private_file(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;

    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
        .with_context(|| format!("set private file mode on {}", path.display()))
}

#[cfg(windows)]
fn harden_private_file(path: &Path) -> Result<()> {
    restrict_windows_acl(path)
}

#[cfg(not(any(unix, windows)))]
fn harden_private_file(_path: &Path) -> Result<()> {
    Ok(())
}

#[cfg(unix)]
fn verify_private_directory(path: &Path) -> Result<()> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    ensure_no_links_or_reparse_points(path)?;
    let metadata = fs::symlink_metadata(path)
        .with_context(|| format!("inspect private directory {}", path.display()))?;
    if !metadata.is_dir() {
        bail!("private path is not a directory: {}", path.display());
    }
    if metadata.uid() != unsafe { libc::geteuid() } {
        bail!(
            "private directory is not owned by the effective user: {}",
            path.display()
        );
    }
    if metadata.permissions().mode() & 0o777 != 0o700 {
        bail!(
            "private directory mode must be exactly 0700: {}",
            path.display()
        );
    }
    Ok(())
}

#[cfg(windows)]
fn verify_private_directory(path: &Path) -> Result<()> {
    ensure_no_links_or_reparse_points(path)?;
    let metadata = fs::symlink_metadata(path)
        .with_context(|| format!("inspect private directory {}", path.display()))?;
    if !metadata.is_dir() {
        bail!("private path is not a directory: {}", path.display());
    }
    verify_windows_acl(path)
        .with_context(|| format!("private directory DACL is not exact: {}", path.display()))
}

#[cfg(not(any(unix, windows)))]
fn verify_private_directory(path: &Path) -> Result<()> {
    ensure_no_links_or_reparse_points(path)?;
    if !fs::symlink_metadata(path)?.is_dir() {
        bail!("private path is not a directory: {}", path.display());
    }
    Ok(())
}

#[cfg(unix)]
fn verify_private_file_permissions(path: &Path) -> Result<()> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    let metadata = fs::symlink_metadata(path)?;
    if metadata.uid() != unsafe { libc::geteuid() } {
        bail!(
            "private file is not owned by the effective user: {}",
            path.display()
        );
    }
    if metadata.permissions().mode() & 0o777 != 0o600 {
        bail!("private file mode must be exactly 0600: {}", path.display());
    }
    Ok(())
}

#[cfg(windows)]
fn verify_private_file_permissions(path: &Path) -> Result<()> {
    verify_windows_acl(path)
        .with_context(|| format!("private file DACL is not exact: {}", path.display()))
}

#[cfg(not(any(unix, windows)))]
fn verify_private_file_permissions(_path: &Path) -> Result<()> {
    Ok(())
}

#[cfg(unix)]
fn sync_directory(path: &Path) -> Result<()> {
    File::open(path)
        .with_context(|| format!("open private parent directory {}", path.display()))?
        .sync_all()
        .with_context(|| format!("flush private parent directory {}", path.display()))
}

#[cfg(windows)]
fn atomic_install_private_file_windows(source: &Path, destination: &Path) -> Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{MoveFileExW, MOVEFILE_WRITE_THROUGH};

    let source_wide = source
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    let destination_wide = destination
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    let moved = unsafe {
        MoveFileExW(
            source_wide.as_ptr(),
            destination_wide.as_ptr(),
            MOVEFILE_WRITE_THROUGH,
        )
    };
    if moved == 0 {
        return Err(std::io::Error::last_os_error()).with_context(|| {
            format!(
                "atomically install and flush protected file {} -> {}",
                source.display(),
                destination.display()
            )
        });
    }
    Ok(())
}

#[cfg(windows)]
fn restrict_windows_acl(path: &Path) -> Result<()> {
    run_windows_acl_operation(path, "apply")
        .with_context(|| format!("replace and verify the DACL on {}", path.display()))
}

#[cfg(windows)]
fn verify_windows_acl(path: &Path) -> Result<()> {
    run_windows_acl_operation(path, "verify")
        .with_context(|| format!("verify the DACL on {}", path.display()))
}

#[cfg(windows)]
fn run_windows_acl_operation(path: &Path, action: &str) -> Result<()> {
    ensure_no_links_or_reparse_points(path)?;
    let metadata = fs::symlink_metadata(path)
        .with_context(|| format!("inspect Windows ACL target {}", path.display()))?;
    if metadata.file_type().is_symlink() || (!metadata.is_file() && !metadata.is_dir()) {
        bail!(
            "credential ACL target is not a regular file or directory: {}",
            path.display()
        );
    }
    if metadata_is_windows_reparse(&metadata) {
        bail!("Windows ACL target is a reparse point: {}", path.display());
    }
    if !matches!(action, "apply" | "verify") {
        bail!("invalid Windows credential ACL action");
    }

    let sid = current_windows_user_sid()?;
    let operation = Command::new("powershell.exe")
        .args([
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            WINDOWS_CREDENTIAL_ACL_SCRIPT,
        ])
        .env("CYC_WORKER_ACL_PATH", path)
        .env("CYC_WORKER_ACL_SID", sid)
        .env("CYC_WORKER_ACL_ACTION", action)
        .output()
        .context("launch Windows credential ACL operation")?;
    if !operation.status.success() {
        let detail = String::from_utf8_lossy(&operation.stderr);
        let detail = detail.trim();
        if detail.is_empty() {
            bail!("Windows credential ACL operation failed");
        }
        bail!("Windows credential ACL operation failed: {detail}");
    }
    Ok(())
}

#[cfg(windows)]
fn current_windows_user_sid() -> Result<String> {
    let identity_output = Command::new("whoami.exe")
        .args(["/user", "/fo", "csv", "/nh"])
        .output()
        .context("query current Windows SID for credential ACL")?;
    if !identity_output.status.success() {
        bail!("whoami failed while querying the current Windows SID");
    }
    let identity = String::from_utf8_lossy(&identity_output.stdout);
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
const WINDOWS_CREDENTIAL_ACL_SCRIPT: &str = r#"
$ErrorActionPreference = 'Stop'
try {
    $path = [Environment]::GetEnvironmentVariable('CYC_WORKER_ACL_PATH')
    $sidText = [Environment]::GetEnvironmentVariable('CYC_WORKER_ACL_SID')
    $action = [Environment]::GetEnvironmentVariable('CYC_WORKER_ACL_ACTION')
    if ([string]::IsNullOrWhiteSpace($path) -or [string]::IsNullOrWhiteSpace($sidText)) {
        throw 'missing ACL input'
    }

    $item = Get-Item -LiteralPath $path -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'ACL target is a reparse point'
    }
    $isDirectory = [bool]$item.PSIsContainer
    $user = [System.Security.Principal.SecurityIdentifier]::new($sidText)
    $system = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
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
            $rule.FileSystemRights -ne [System.Security.AccessControl.FileSystemRights]::FullControl -or
            $rule.InheritanceFlags -ne $expectedInheritance -or
            $rule.PropagationFlags -ne [System.Security.AccessControl.PropagationFlags]::None) {
            throw 'unexpected access rule'
        }
        $expected[$ruleSid] = $true
    }
    if ($expected.Values -contains $false) { throw 'required principal missing' }
} catch {
    [Console]::Error.WriteLine('worker credential ACL operation failed: ' + $_.Exception.Message)
    exit 1
}
"#;

pub fn sanitized_environment() -> Vec<(String, String)> {
    env::vars()
        .filter(|(name, _)| is_allowed_environment_name(name))
        .collect()
}

fn is_allowed_environment_name(name: &str) -> bool {
    let upper = name.to_ascii_uppercase();
    if upper.starts_with("CYC_")
        || upper.starts_with("AWS_")
        || upper.starts_with("AZURE_")
        || upper.starts_with("GOOGLE_")
        || upper.starts_with("GCP_")
        || upper.starts_with("CLOUDSDK_")
        || upper.starts_with("DOCKER_AUTH")
        || upper.starts_with("SSH_")
        || upper.starts_with("GIT_ASKPASS")
        || upper.starts_with("GITLAB_")
        || upper.contains("TOKEN")
        || upper.contains("PASSWORD")
        || upper.contains("SECRET")
        || upper.contains("CREDENTIAL")
    {
        return false;
    }

    matches!(
        upper.as_str(),
        "PATH"
            | "PATHEXT"
            | "SYSTEMROOT"
            | "WINDIR"
            | "COMSPEC"
            | "TEMP"
            | "TMP"
            | "TMPDIR"
            | "HOME"
            | "USERPROFILE"
            | "LOCALAPPDATA"
            | "APPDATA"
            | "PROGRAMDATA"
            | "PROGRAMFILES"
            | "PROGRAMFILES(X86)"
            | "PROGRAMW6432"
            | "NUMBER_OF_PROCESSORS"
            | "PROCESSOR_ARCHITECTURE"
            | "TERM"
            | "COLORTERM"
            | "LANG"
    ) || upper.starts_with("LC_")
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[cfg(unix)]
    fn make_directory_weak(path: &Path) {
        use std::os::unix::fs::PermissionsExt;

        fs::set_permissions(path, fs::Permissions::from_mode(0o777)).unwrap();
    }

    #[cfg(windows)]
    fn make_directory_weak(path: &Path) {
        let status = std::process::Command::new("icacls.exe")
            .arg(path)
            .args(["/grant", "*S-1-1-0:(OI)(CI)(R)"])
            .status()
            .unwrap();
        assert!(status.success());
    }

    #[cfg(unix)]
    fn make_file_weak(path: &Path) {
        use std::os::unix::fs::PermissionsExt;

        fs::set_permissions(path, fs::Permissions::from_mode(0o644)).unwrap();
    }

    #[cfg(windows)]
    fn make_file_weak(path: &Path) {
        let status = std::process::Command::new("icacls.exe")
            .arg(path)
            .args(["/grant", "*S-1-1-0:(R)"])
            .status()
            .unwrap();
        assert!(status.success());
    }

    #[cfg(unix)]
    fn create_directory_link(link: &Path, target: &Path) {
        std::os::unix::fs::symlink(target, link).unwrap();
    }

    #[cfg(windows)]
    fn create_directory_link(link: &Path, target: &Path) {
        let output = std::process::Command::new("cmd.exe")
            .args(["/d", "/c", "mklink", "/J"])
            .arg(link)
            .arg(target)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "failed to create junction: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    #[test]
    fn sensitive_child_environment_names_are_removed() {
        for name in [
            "CYC_WORKER_TOKEN",
            "AWS_ACCESS_KEY_ID",
            "AZURE_CLIENT_SECRET",
            "GOOGLE_APPLICATION_CREDENTIALS",
            "SSH_AUTH_SOCK",
            "GITHUB_TOKEN",
            "MY_PASSWORD",
        ] {
            assert!(!is_allowed_environment_name(name), "leaked {name}");
        }
        assert!(is_allowed_environment_name("PATH"));
        assert!(is_allowed_environment_name("SystemRoot"));
        assert!(is_allowed_environment_name("LC_ALL"));
    }

    #[test]
    fn persisted_secret_round_trips_only_through_a_protected_file() {
        let directory = tempdir().unwrap();
        let protected = directory.path().join("private");
        let credential = protected.join("worker.credential");
        write_secret_file(&credential, "opaque-worker-credential").unwrap();
        assert_eq!(
            read_secret_file(&credential).unwrap().expose(),
            "opaque-worker-credential"
        );

        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;

            assert_eq!(fs::metadata(&protected).unwrap().mode() & 0o777, 0o700);
            assert_eq!(fs::metadata(&credential).unwrap().mode() & 0o777, 0o600);
        }
    }

    #[test]
    fn existing_weak_parent_is_rejected_without_repair() {
        let directory = tempdir().unwrap();
        let protected = directory.path().join("private");
        let credential = protected.join("worker.credential");
        write_secret_file(&credential, "opaque-worker-credential").unwrap();

        make_directory_weak(&protected);
        assert!(read_secret_file(&credential).is_err());
        assert!(ensure_protected_directory(&protected).is_err());
        assert!(read_secret_file(&credential).is_err());
    }

    #[test]
    fn existing_weak_file_is_rejected_without_repair() {
        let directory = tempdir().unwrap();
        let protected = directory.path().join("private");
        let credential = protected.join("worker.credential");
        write_secret_file(&credential, "opaque-worker-credential").unwrap();

        make_file_weak(&credential);
        assert!(read_secret_file(&credential).is_err());
        assert!(ensure_protected_input(&credential).is_err());
        assert!(read_secret_file(&credential).is_err());
    }

    #[test]
    fn protected_input_rejects_a_link_or_junction_ancestor() {
        let directory = tempdir().unwrap();
        let target = directory.path().join("target");
        let credential = target.join("worker.credential");
        write_secret_file(&credential, "opaque-worker-credential").unwrap();
        let link = directory.path().join("link");
        create_directory_link(&link, &target);

        let error = format!(
            "{:#}",
            read_secret_file(&link.join("worker.credential"))
                .err()
                .unwrap()
        );
        assert!(
            error.contains("symbolic") || error.contains("reparse"),
            "{error}"
        );

        #[cfg(unix)]
        fs::remove_file(&link).unwrap();
        #[cfg(windows)]
        fs::remove_dir(&link).unwrap();
    }
}
