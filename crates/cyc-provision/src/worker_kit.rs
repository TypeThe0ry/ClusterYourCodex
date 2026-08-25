use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, OpenOptions},
    io::{self, Read},
    path::{Path, PathBuf},
};

use base64::{engine::general_purpose::STANDARD as BASE64_STANDARD, Engine as _};
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;

use crate::DiscoveredComputer;

const KIT_SCHEMA: &str = "cyc.dev/worker-kit/v1";
const KIT_PRODUCT: &str = "ClusterYourCodex Managed Worker";
const MAX_WORKER_BYTES: u64 = 512 * 1024 * 1024;
const MAX_LIFECYCLE_BYTES: u64 = 2 * 1024 * 1024;
const MAX_MANIFEST_BYTES: u64 = 1024 * 1024;
const MAX_SUMS_BYTES: u64 = 64 * 1024;
const MAX_SIGNATURE_BYTES: u64 = 16 * 1024;
const SIGNATURE_SCHEMA: &str = "cyc.dev/worker-kit-signature/v1";
const SIGNATURE_ALGORITHM: &str = "Ed25519";
const SIGNED_OBJECT: &str = "worker-kit.json";

#[cfg(test)]
const COMPILED_KEY_ID: &str = "cyc-test-fixture-rfc8032-1";
#[cfg(test)]
const COMPILED_PUBLIC_KEY_B64: &str = "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=";

#[cfg(not(test))]
const COMPILED_KEY_ID: &str = "cyc-release-2026-02";
#[cfg(not(test))]
const COMPILED_PUBLIC_KEY_B64: &str = include_str!("../publisher_keys/cyc-release-2026-02.pub");

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WorkerKitTarget {
    WindowsX86_64,
    LinuxX86_64,
    LinuxAarch64,
    MacosX86_64,
    MacosAarch64,
}

impl WorkerKitTarget {
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::WindowsX86_64 => "windows-x86_64",
            Self::LinuxX86_64 => "linux-x86_64",
            Self::LinuxAarch64 => "linux-aarch64",
            Self::MacosX86_64 => "macos-x86_64",
            Self::MacosAarch64 => "macos-aarch64",
        }
    }

    #[must_use]
    pub fn operating_system(self) -> &'static str {
        match self {
            Self::WindowsX86_64 => "windows",
            Self::LinuxX86_64 | Self::LinuxAarch64 => "linux",
            Self::MacosX86_64 | Self::MacosAarch64 => "macos",
        }
    }

    #[must_use]
    pub fn architecture(self) -> &'static str {
        match self {
            Self::WindowsX86_64 | Self::LinuxX86_64 | Self::MacosX86_64 => "x86_64",
            Self::LinuxAarch64 | Self::MacosAarch64 => "aarch64",
        }
    }

    pub(crate) fn expected_names(self) -> [&'static str; 5] {
        match self {
            Self::WindowsX86_64 => [
                "cyc-worker.exe",
                "Install-Worker.ps1",
                "worker-kit.json",
                "worker-kit.sig",
                "SHA256SUMS",
            ],
            Self::LinuxX86_64 | Self::LinuxAarch64 | Self::MacosX86_64 | Self::MacosAarch64 => [
                "cyc-worker",
                "install-worker.sh",
                "worker-kit.json",
                "worker-kit.sig",
                "SHA256SUMS",
            ],
        }
    }

    fn worker_name(self) -> &'static str {
        self.expected_names()[0]
    }

    fn lifecycle_name(self) -> &'static str {
        self.expected_names()[1]
    }

    pub fn from_inventory(inventory: &DiscoveredComputer) -> Result<Self, WorkerKitError> {
        match (
            inventory.operating_system.as_str(),
            inventory.architecture.as_str(),
        ) {
            ("windows", "x86_64") => Ok(Self::WindowsX86_64),
            ("linux", "x86_64") => Ok(Self::LinuxX86_64),
            ("linux", "aarch64") => Ok(Self::LinuxAarch64),
            ("macos", "x86_64") => Ok(Self::MacosX86_64),
            ("macos", "aarch64") => Ok(Self::MacosAarch64),
            _ => Err(WorkerKitError::UnsupportedTarget),
        }
    }
}

#[derive(Clone, Debug)]
pub struct WorkerKitCatalog {
    root: PathBuf,
    trusted_publisher: Option<TrustedPublisher>,
}

#[derive(Clone, Debug)]
struct TrustedPublisher {
    key_id: String,
    verifying_key: VerifyingKey,
}

impl WorkerKitCatalog {
    /// Construct from the desktop installation root. Kits are accepted only
    /// from the fixed `<InstallRoot>/worker-kits/<target>` payload hierarchy;
    /// no recursive search or fallback directories are used.
    pub fn from_install_root(install_root: impl AsRef<Path>) -> Result<Self, WorkerKitError> {
        let install_root = install_root.as_ref();
        if !install_root.is_absolute()
            || install_root
                .components()
                .any(|component| matches!(component, std::path::Component::ParentDir))
        {
            return Err(WorkerKitError::InvalidCatalogRoot);
        }
        Ok(Self {
            root: install_root.join("worker-kits"),
            trusted_publisher: compiled_trusted_publisher(),
        })
    }

    /// Construct from an already-resolved exact `worker-kits` root. This is
    /// useful for isolated tests and embedders that do not have an installer
    /// root, and still never scans outside the five fixed target children.
    #[must_use]
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self {
            root: root.into(),
            trusted_publisher: compiled_trusted_publisher(),
        }
    }

    /// Construct a catalog with an explicit pinned publisher. This is intended
    /// for embedders and isolated tests; production installers use the key id
    /// and public key compiled into the controller release.
    pub fn with_trusted_publisher(
        root: impl Into<PathBuf>,
        key_id: impl Into<String>,
        public_key: [u8; 32],
    ) -> Result<Self, WorkerKitError> {
        let key_id = key_id.into();
        if !valid_key_id(&key_id) {
            return Err(WorkerKitError::InvalidManifest);
        }
        let verifying_key =
            VerifyingKey::from_bytes(&public_key).map_err(|_| WorkerKitError::InvalidManifest)?;
        Ok(Self {
            root: root.into(),
            trusted_publisher: Some(TrustedPublisher {
                key_id,
                verifying_key,
            }),
        })
    }

    #[must_use]
    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn load_for_inventory(
        &self,
        inventory: &DiscoveredComputer,
    ) -> Result<WorkerKit, WorkerKitError> {
        self.load_target(WorkerKitTarget::from_inventory(inventory)?)
    }

    pub fn load_target(&self, target: WorkerKitTarget) -> Result<WorkerKit, WorkerKitError> {
        validate_absolute_existing_path(&self.root, EntryKind::Directory)?;
        let root_metadata = fs::symlink_metadata(&self.root).map_err(WorkerKitError::Io)?;
        if !metadata_is_safe_directory(&root_metadata) {
            return Err(WorkerKitError::UnsafeEntry);
        }
        let root_identity = FileSystemIdentity::from_metadata(&root_metadata)?;
        let directory = self.root.join(target.as_str());
        validate_absolute_existing_path(&directory, EntryKind::Directory)?;
        let directory_metadata = fs::symlink_metadata(&directory).map_err(WorkerKitError::Io)?;
        if !metadata_is_safe_directory(&directory_metadata) {
            return Err(WorkerKitError::UnsafeEntry);
        }
        let directory_identity = FileSystemIdentity::from_metadata(&directory_metadata)?;

        let expected: BTreeSet<String> = target
            .expected_names()
            .into_iter()
            .map(str::to_owned)
            .collect();
        let mut actual = BTreeSet::new();
        for entry in fs::read_dir(&directory).map_err(WorkerKitError::Io)? {
            let entry = entry.map_err(WorkerKitError::Io)?;
            let name = entry
                .file_name()
                .into_string()
                .map_err(|_| WorkerKitError::UnsafeEntry)?;
            let metadata = fs::symlink_metadata(entry.path()).map_err(WorkerKitError::Io)?;
            if !metadata_is_safe_regular_file(&metadata) || !actual.insert(name) {
                return Err(WorkerKitError::UnsafeEntry);
            }
        }
        if actual != expected {
            return Err(WorkerKitError::UnexpectedFileSet);
        }

        let mut bytes = BTreeMap::new();
        for name in target.expected_names() {
            let maximum = match name {
                "cyc-worker" | "cyc-worker.exe" => MAX_WORKER_BYTES,
                "install-worker.sh" | "Install-Worker.ps1" => MAX_LIFECYCLE_BYTES,
                "worker-kit.json" => MAX_MANIFEST_BYTES,
                "worker-kit.sig" => MAX_SIGNATURE_BYTES,
                "SHA256SUMS" => MAX_SUMS_BYTES,
                _ => return Err(WorkerKitError::UnexpectedFileSet),
            };
            bytes.insert(
                name.to_owned(),
                read_bounded_nofollow(&directory.join(name), maximum)?,
            );
        }

        verify_unchanged_identity(&directory, EntryKind::Directory, &directory_identity)?;
        verify_unchanged_identity(&self.root, EntryKind::Directory, &root_identity)?;

        let manifest_bytes = bytes
            .get("worker-kit.json")
            .ok_or(WorkerKitError::UnexpectedFileSet)?;
        let manifest: WorkerKitManifest =
            serde_json::from_slice(manifest_bytes).map_err(|_| WorkerKitError::InvalidManifest)?;
        let mut canonical_manifest =
            serde_json::to_vec(&manifest).map_err(|_| WorkerKitError::InvalidManifest)?;
        canonical_manifest.push(b'\n');
        if canonical_manifest.as_slice() != manifest_bytes.as_slice() {
            return Err(WorkerKitError::InvalidManifest);
        }
        verify_publisher_signature(
            self.trusted_publisher
                .as_ref()
                .ok_or(WorkerKitError::InvalidManifest)?,
            manifest_bytes,
            bytes
                .get("worker-kit.sig")
                .ok_or(WorkerKitError::UnexpectedFileSet)?,
        )?;
        validate_manifest(target, &manifest, &bytes)?;
        let sums = parse_sums(
            bytes
                .get("SHA256SUMS")
                .ok_or(WorkerKitError::UnexpectedFileSet)?,
        )?;
        let expected_sum_names: BTreeSet<String> = [
            target.worker_name().to_owned(),
            target.lifecycle_name().to_owned(),
            "worker-kit.json".to_owned(),
            "worker-kit.sig".to_owned(),
        ]
        .into_iter()
        .collect();
        if sums.keys().cloned().collect::<BTreeSet<_>>() != expected_sum_names {
            return Err(WorkerKitError::InvalidChecksums);
        }
        for (name, expected_hash) in &sums {
            let content = bytes.get(name).ok_or(WorkerKitError::InvalidChecksums)?;
            if &sha256_hex(content) != expected_hash {
                return Err(WorkerKitError::DigestMismatch);
            }
        }

        let files = target
            .expected_names()
            .into_iter()
            .map(|name| WorkerKitFile {
                name: name.to_owned(),
                sha256: sha256_hex(
                    bytes
                        .get(name)
                        .expect("validated exact worker-kit file set"),
                ),
                content: bytes
                    .remove(name)
                    .expect("validated exact worker-kit file set"),
                unix_mode: if matches!(
                    name,
                    "cyc-worker" | "cyc-worker.exe" | "install-worker.sh" | "Install-Worker.ps1"
                ) {
                    0o700
                } else {
                    0o600
                },
            })
            .collect();

        Ok(WorkerKit {
            target,
            version: manifest.version,
            files,
        })
    }
}

pub struct WorkerKit {
    target: WorkerKitTarget,
    version: String,
    files: Vec<WorkerKitFile>,
}

impl std::fmt::Debug for WorkerKit {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("WorkerKit")
            .field("target", &self.target)
            .field("version", &self.version)
            .field("file_count", &self.files.len())
            .finish()
    }
}

impl WorkerKit {
    #[must_use]
    pub fn target(&self) -> WorkerKitTarget {
        self.target
    }

    #[must_use]
    pub fn version(&self) -> &str {
        &self.version
    }

    pub(crate) fn files(&self) -> &[WorkerKitFile] {
        &self.files
    }

    pub(crate) fn lifecycle_name(&self) -> &'static str {
        self.target.lifecycle_name()
    }

    /// Recheck the private in-memory representation immediately before a
    /// materializer or transport consumes it. `WorkerKit` can only be built by
    /// the signature-verifying catalog, and this second check ensures an
    /// accidental mutation inside this crate cannot turn that verified value
    /// into an unbound export.
    pub(crate) fn validate_in_memory(&self) -> Result<(), WorkerKitError> {
        if !valid_version(&self.version) || self.files.len() != 5 {
            return Err(WorkerKitError::UnsafeEntry);
        }
        let expected: BTreeSet<&str> = self.target.expected_names().into_iter().collect();
        let mut observed = BTreeSet::new();
        for file in &self.files {
            if !expected.contains(file.name.as_str())
                || !observed.insert(file.name.as_str())
                || file.content.is_empty()
                || file.content.len() as u64 > maximum_for_name(&file.name)?
                || !valid_sha256(&file.sha256)
                || sha256_hex(&file.content) != file.sha256
                || !matches!(file.unix_mode, 0o600 | 0o700)
            {
                return Err(WorkerKitError::DigestMismatch);
            }
        }
        if observed != expected {
            return Err(WorkerKitError::UnexpectedFileSet);
        }
        Ok(())
    }
}

pub(crate) struct WorkerKitFile {
    pub(crate) name: String,
    pub(crate) content: Vec<u8>,
    pub(crate) sha256: String,
    pub(crate) unix_mode: i32,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkerKitManifest {
    schema_version: String,
    product: String,
    version: String,
    target: String,
    os: String,
    architecture: String,
    files: Vec<ManifestFile>,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ManifestFile {
    path: String,
    size_bytes: u64,
    sha256: String,
    role: String,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkerKitSignatureEnvelope {
    schema_version: String,
    algorithm: String,
    key_id: String,
    signed_object: String,
    manifest_sha256: String,
    signature: String,
}

fn compiled_trusted_publisher() -> Option<TrustedPublisher> {
    let key_id = COMPILED_KEY_ID.trim();
    let encoded = COMPILED_PUBLIC_KEY_B64.trim();
    if !valid_key_id(key_id) || encoded.is_empty() {
        return None;
    }
    let decoded = BASE64_STANDARD.decode(encoded).ok()?;
    let public_key: [u8; 32] = decoded.try_into().ok()?;
    let verifying_key = VerifyingKey::from_bytes(&public_key).ok()?;
    Some(TrustedPublisher {
        key_id: key_id.to_owned(),
        verifying_key,
    })
}

fn verify_publisher_signature(
    publisher: &TrustedPublisher,
    manifest_bytes: &[u8],
    envelope_bytes: &[u8],
) -> Result<(), WorkerKitError> {
    let envelope: WorkerKitSignatureEnvelope =
        serde_json::from_slice(envelope_bytes).map_err(|_| WorkerKitError::InvalidManifest)?;
    let mut canonical_envelope =
        serde_json::to_vec(&envelope).map_err(|_| WorkerKitError::InvalidManifest)?;
    canonical_envelope.push(b'\n');
    if canonical_envelope != envelope_bytes
        || envelope.schema_version != SIGNATURE_SCHEMA
        || envelope.algorithm != SIGNATURE_ALGORITHM
        || envelope.key_id != publisher.key_id
        || envelope.signed_object != SIGNED_OBJECT
        || envelope.manifest_sha256 != sha256_hex(manifest_bytes)
        || !valid_sha256(&envelope.manifest_sha256)
    {
        return Err(WorkerKitError::InvalidManifest);
    }
    let signature_bytes = BASE64_STANDARD
        .decode(&envelope.signature)
        .map_err(|_| WorkerKitError::InvalidManifest)?;
    if BASE64_STANDARD.encode(&signature_bytes) != envelope.signature {
        return Err(WorkerKitError::InvalidManifest);
    }
    let signature =
        Signature::from_slice(&signature_bytes).map_err(|_| WorkerKitError::InvalidManifest)?;
    publisher
        .verifying_key
        .verify(manifest_bytes, &signature)
        .map_err(|_| WorkerKitError::InvalidManifest)
}

fn validate_manifest(
    target: WorkerKitTarget,
    manifest: &WorkerKitManifest,
    bytes: &BTreeMap<String, Vec<u8>>,
) -> Result<(), WorkerKitError> {
    if manifest.schema_version != KIT_SCHEMA
        || manifest.product != KIT_PRODUCT
        || manifest.target != target.as_str()
        || manifest.os != target.operating_system()
        || manifest.architecture != target.architecture()
        || !valid_version(&manifest.version)
        || manifest.files.len() != 2
    {
        return Err(WorkerKitError::InvalidManifest);
    }
    let expected_files: BTreeSet<&str> = [target.worker_name(), target.lifecycle_name()]
        .into_iter()
        .collect();
    let mut observed_files = BTreeSet::new();
    let mut roles = BTreeSet::new();
    for file in &manifest.files {
        if !expected_files.contains(file.path.as_str())
            || !observed_files.insert(file.path.as_str())
            || !matches!(file.role.as_str(), "worker" | "lifecycle")
            || !roles.insert(file.role.as_str())
            || !valid_sha256(&file.sha256)
        {
            return Err(WorkerKitError::InvalidManifest);
        }
        let content = bytes
            .get(&file.path)
            .ok_or(WorkerKitError::InvalidManifest)?;
        if content.len() as u64 != file.size_bytes
            || sha256_hex(content) != file.sha256.to_ascii_lowercase()
        {
            return Err(WorkerKitError::DigestMismatch);
        }
        if (file.role == "worker") != (file.path == target.worker_name()) {
            return Err(WorkerKitError::InvalidManifest);
        }
    }
    if observed_files != expected_files || roles != ["lifecycle", "worker"].into_iter().collect() {
        return Err(WorkerKitError::InvalidManifest);
    }
    Ok(())
}

fn parse_sums(content: &[u8]) -> Result<BTreeMap<String, String>, WorkerKitError> {
    let text = std::str::from_utf8(content).map_err(|_| WorkerKitError::InvalidChecksums)?;
    if text.is_empty() || !text.ends_with('\n') || text.contains('\r') {
        return Err(WorkerKitError::InvalidChecksums);
    }
    let mut result = BTreeMap::new();
    for line in text.lines() {
        let (hash, name) = line
            .split_once("  ")
            .ok_or(WorkerKitError::InvalidChecksums)?;
        if !valid_sha256(hash)
            || name.is_empty()
            || name.contains(['/', '\\', '\0', '\r', '\n'])
            || result
                .insert(name.to_owned(), hash.to_ascii_lowercase())
                .is_some()
        {
            return Err(WorkerKitError::InvalidChecksums);
        }
    }
    Ok(result)
}

fn maximum_for_name(name: &str) -> Result<u64, WorkerKitError> {
    match name {
        "cyc-worker" | "cyc-worker.exe" => Ok(MAX_WORKER_BYTES),
        "install-worker.sh" | "Install-Worker.ps1" => Ok(MAX_LIFECYCLE_BYTES),
        "worker-kit.json" => Ok(MAX_MANIFEST_BYTES),
        "worker-kit.sig" => Ok(MAX_SIGNATURE_BYTES),
        "SHA256SUMS" => Ok(MAX_SUMS_BYTES),
        _ => Err(WorkerKitError::UnexpectedFileSet),
    }
}

fn read_bounded_nofollow(path: &Path, maximum: u64) -> Result<Vec<u8>, WorkerKitError> {
    let metadata = fs::symlink_metadata(path).map_err(WorkerKitError::Io)?;
    if !metadata_is_safe_regular_file(&metadata) || metadata.len() == 0 || metadata.len() > maximum
    {
        return Err(WorkerKitError::UnsafeEntry);
    }
    let before = FileSystemIdentity::from_metadata(&metadata)?;
    let mut options = OpenOptions::new();
    options.read(true);
    configure_nofollow_open(&mut options);
    let mut file = options.open(path).map_err(WorkerKitError::Io)?;
    let open_metadata = file.metadata().map_err(WorkerKitError::Io)?;
    if !metadata_is_safe_regular_file(&open_metadata)
        || FileSystemIdentity::from_metadata(&open_metadata)? != before
    {
        return Err(WorkerKitError::UnsafeEntry);
    }
    let mut content = Vec::with_capacity(metadata.len() as usize);
    file.by_ref()
        .take(maximum + 1)
        .read_to_end(&mut content)
        .map_err(WorkerKitError::Io)?;
    if content.len() as u64 != metadata.len() || content.len() as u64 > maximum {
        return Err(WorkerKitError::UnsafeEntry);
    }
    let after_open = file.metadata().map_err(WorkerKitError::Io)?;
    if FileSystemIdentity::from_metadata(&after_open)? != before {
        return Err(WorkerKitError::UnsafeEntry);
    }
    verify_unchanged_identity(path, EntryKind::File, &before)?;
    Ok(content)
}

#[derive(Clone, Copy)]
enum EntryKind {
    Directory,
    File,
}

fn validate_absolute_existing_path(path: &Path, kind: EntryKind) -> Result<(), WorkerKitError> {
    if !path.is_absolute()
        || path.components().any(|component| {
            matches!(
                component,
                std::path::Component::CurDir | std::path::Component::ParentDir
            )
        })
    {
        return Err(WorkerKitError::InvalidCatalogRoot);
    }
    let mut candidate = PathBuf::new();
    for component in path.components() {
        candidate.push(component.as_os_str());
        let metadata = fs::symlink_metadata(&candidate).map_err(WorkerKitError::Io)?;
        if metadata.file_type().is_symlink() || metadata_is_windows_reparse(&metadata) {
            return Err(WorkerKitError::UnsafeEntry);
        }
    }
    let metadata = fs::symlink_metadata(path).map_err(WorkerKitError::Io)?;
    let valid = match kind {
        EntryKind::Directory => metadata_is_safe_directory(&metadata),
        EntryKind::File => metadata_is_safe_regular_file(&metadata),
    };
    if !valid {
        return Err(WorkerKitError::UnsafeEntry);
    }
    Ok(())
}

fn verify_unchanged_identity(
    path: &Path,
    kind: EntryKind,
    expected: &FileSystemIdentity,
) -> Result<(), WorkerKitError> {
    let metadata = fs::symlink_metadata(path).map_err(WorkerKitError::Io)?;
    let valid = match kind {
        EntryKind::Directory => metadata_is_safe_directory(&metadata),
        EntryKind::File => metadata_is_safe_regular_file(&metadata),
    };
    if !valid || &FileSystemIdentity::from_metadata(&metadata)? != expected {
        return Err(WorkerKitError::UnsafeEntry);
    }
    Ok(())
}

fn metadata_is_safe_directory(metadata: &fs::Metadata) -> bool {
    metadata.is_dir()
        && !metadata.file_type().is_symlink()
        && !metadata_is_windows_reparse(metadata)
}

fn metadata_is_safe_regular_file(metadata: &fs::Metadata) -> bool {
    metadata.is_file()
        && !metadata.file_type().is_symlink()
        && !metadata_is_windows_reparse(metadata)
        && metadata_has_single_link(metadata)
}

#[cfg(unix)]
fn metadata_has_single_link(metadata: &fs::Metadata) -> bool {
    use std::os::unix::fs::MetadataExt;

    metadata.nlink() == 1
}

#[cfg(windows)]
fn metadata_has_single_link(_metadata: &fs::Metadata) -> bool {
    // The stable Windows MetadataExt surface does not expose the link count.
    // Read handles exclude write/delete sharing and are revalidated before and
    // after use, which prevents a second hard-link name from changing bytes
    // during verification.
    true
}

#[cfg(not(any(unix, windows)))]
fn metadata_has_single_link(_metadata: &fs::Metadata) -> bool {
    false
}

#[cfg(unix)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct FileSystemIdentity {
    device: u64,
    inode: u64,
}

#[cfg(unix)]
impl FileSystemIdentity {
    fn from_metadata(metadata: &fs::Metadata) -> Result<Self, WorkerKitError> {
        use std::os::unix::fs::MetadataExt;

        Ok(Self {
            device: metadata.dev(),
            inode: metadata.ino(),
        })
    }
}

#[cfg(windows)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct FileSystemIdentity {
    creation_time: u64,
    file_size: u64,
    attributes: u32,
}

#[cfg(windows)]
impl FileSystemIdentity {
    fn from_metadata(metadata: &fs::Metadata) -> Result<Self, WorkerKitError> {
        use std::os::windows::fs::MetadataExt;

        Ok(Self {
            creation_time: metadata.creation_time(),
            file_size: metadata.file_size(),
            attributes: metadata.file_attributes(),
        })
    }
}

#[cfg(not(any(unix, windows)))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct FileSystemIdentity;

#[cfg(not(any(unix, windows)))]
impl FileSystemIdentity {
    fn from_metadata(_metadata: &fs::Metadata) -> Result<Self, WorkerKitError> {
        Err(WorkerKitError::UnsafeEntry)
    }
}

#[cfg(target_os = "linux")]
fn configure_nofollow_open(options: &mut OpenOptions) {
    use std::os::unix::fs::OpenOptionsExt;

    const O_NOFOLLOW: i32 = 0x0002_0000;
    options.custom_flags(O_NOFOLLOW);
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
fn configure_nofollow_open(options: &mut OpenOptions) {
    use std::os::unix::fs::OpenOptionsExt;

    const O_NOFOLLOW: i32 = 0x0000_0100;
    options.custom_flags(O_NOFOLLOW);
}

#[cfg(windows)]
fn configure_nofollow_open(options: &mut OpenOptions) {
    use std::os::windows::fs::OpenOptionsExt;

    const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
    const FILE_SHARE_READ: u32 = 0x0000_0001;
    options
        .share_mode(FILE_SHARE_READ)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT);
}

#[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "ios", windows)))]
fn configure_nofollow_open(_options: &mut OpenOptions) {}

#[cfg(windows)]
fn metadata_is_windows_reparse(metadata: &fs::Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;

    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;
    metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

#[cfg(not(windows))]
fn metadata_is_windows_reparse(_metadata: &fs::Metadata) -> bool {
    false
}

fn valid_sha256(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn valid_key_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 96
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

fn valid_version(value: &str) -> bool {
    if value.is_empty()
        || value.len() > 128
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'+'))
    {
        return false;
    }
    let boundary = value.find(['-', '+']).unwrap_or(value.len());
    let core = &value[..boundary];
    let mut components = core.split('.');
    let numeric = (0..3).all(|_| {
        components.next().is_some_and(|component| {
            !component.is_empty() && component.bytes().all(|byte| byte.is_ascii_digit())
        })
    });
    numeric
        && components.next().is_none()
        && (boundary == value.len() || boundary + 1 < value.len())
}

pub(crate) fn sha256_hex(content: &[u8]) -> String {
    Sha256::digest(content)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[derive(Debug, Error)]
pub enum WorkerKitError {
    #[error("worker-kit installation root is invalid")]
    InvalidCatalogRoot,
    #[error("worker-kit target is unsupported")]
    UnsupportedTarget,
    #[error("worker-kit contains an unsafe filesystem entry")]
    UnsafeEntry,
    #[error("worker-kit file set is not exact")]
    UnexpectedFileSet,
    #[error("worker-kit manifest is invalid")]
    InvalidManifest,
    #[error("worker-kit SHA256SUMS is invalid")]
    InvalidChecksums,
    #[error("worker-kit digest does not match")]
    DigestMismatch,
    #[error("worker-kit I/O failed")]
    Io(#[source] io::Error),
}

#[cfg(test)]
mod tests {
    use std::{collections::BTreeMap, fs};

    use base64::{engine::general_purpose::STANDARD as BASE64_STANDARD, Engine as _};
    use ed25519_dalek::{Signer, SigningKey};
    use tempfile::TempDir;

    use super::{
        sha256_hex, ManifestFile, WorkerKitCatalog, WorkerKitError, WorkerKitManifest,
        WorkerKitSignatureEnvelope, WorkerKitTarget,
    };

    const FIXTURE_SEED: [u8; 32] = [
        0x9d, 0x61, 0xb1, 0x9d, 0xef, 0xfd, 0x5a, 0x60, 0xba, 0x84, 0x4a, 0xf4, 0x92, 0xec, 0x2c,
        0xc4, 0x44, 0x49, 0xc5, 0x69, 0x7b, 0x32, 0x69, 0x19, 0x70, 0x3b, 0xac, 0x03, 0x1c, 0xae,
        0x7f, 0x60,
    ];

    fn fixture_for(target: WorkerKitTarget) -> TempDir {
        let root = TempDir::new().unwrap();
        let directory = root.path().join(target.as_str());
        fs::create_dir(&directory).unwrap();
        let worker = b"fixture-worker";
        let lifecycle = b"#!/bin/sh\nexit 0\n";
        fs::write(directory.join(target.worker_name()), worker).unwrap();
        fs::write(directory.join(target.lifecycle_name()), lifecycle).unwrap();
        let manifest = WorkerKitManifest {
            schema_version: "cyc.dev/worker-kit/v1".to_owned(),
            product: "ClusterYourCodex Managed Worker".to_owned(),
            version: "0.1.0-test.1".to_owned(),
            target: target.as_str().to_owned(),
            os: target.operating_system().to_owned(),
            architecture: target.architecture().to_owned(),
            files: vec![
                ManifestFile {
                    path: target.worker_name().to_owned(),
                    size_bytes: worker.len() as u64,
                    sha256: sha256_hex(worker),
                    role: "worker".to_owned(),
                },
                ManifestFile {
                    path: target.lifecycle_name().to_owned(),
                    size_bytes: lifecycle.len() as u64,
                    sha256: sha256_hex(lifecycle),
                    role: "lifecycle".to_owned(),
                },
            ],
        };
        let mut manifest_bytes = serde_json::to_vec(&manifest).unwrap();
        manifest_bytes.push(b'\n');
        fs::write(directory.join("worker-kit.json"), &manifest_bytes).unwrap();
        let signing_key = SigningKey::from_bytes(&FIXTURE_SEED);
        let signature = signing_key.sign(&manifest_bytes);
        let signature_envelope = WorkerKitSignatureEnvelope {
            schema_version: "cyc.dev/worker-kit-signature/v1".to_owned(),
            algorithm: "Ed25519".to_owned(),
            key_id: "cyc-test-fixture-rfc8032-1".to_owned(),
            signed_object: "worker-kit.json".to_owned(),
            manifest_sha256: sha256_hex(&manifest_bytes),
            signature: BASE64_STANDARD.encode(signature.to_bytes()),
        };
        let mut signature_bytes = serde_json::to_vec(&signature_envelope).unwrap();
        signature_bytes.push(b'\n');
        fs::write(directory.join("worker-kit.sig"), &signature_bytes).unwrap();
        fs::write(
            directory.join("SHA256SUMS"),
            format!(
                "{}  {}\n{}  {}\n{}  worker-kit.json\n{}  worker-kit.sig\n",
                sha256_hex(worker),
                target.worker_name(),
                sha256_hex(lifecycle),
                target.lifecycle_name(),
                sha256_hex(&manifest_bytes),
                sha256_hex(&signature_bytes)
            ),
        )
        .unwrap();
        root
    }

    fn fixture() -> TempDir {
        fixture_for(WorkerKitTarget::LinuxX86_64)
    }

    fn inventory(operating_system: &str, architecture: &str) -> crate::DiscoveredComputer {
        crate::DiscoveredComputer {
            hostname: "fixture-worker".to_owned(),
            operating_system: operating_system.to_owned(),
            architecture: architecture.to_owned(),
            cpu_model: "fixture-cpu".to_owned(),
            logical_cpu_count: 8,
            memory_bytes: 16 * 1024 * 1024 * 1024,
            workspace_free_bytes: 100 * 1024 * 1024,
            gpu_devices: Vec::new(),
            toolchains: BTreeMap::new(),
        }
    }

    #[test]
    fn exact_manifest_and_sha256sums_load() {
        let root = fixture();
        let kit = WorkerKitCatalog::new(root.path())
            .load_target(WorkerKitTarget::LinuxX86_64)
            .unwrap();
        assert_eq!(kit.target(), WorkerKitTarget::LinuxX86_64);
        assert_eq!(kit.version(), "0.1.0-test.1");
        assert_eq!(kit.files().len(), 5);
    }

    #[test]
    fn macos_targets_map_from_inventory_and_load_exact_signed_kits() {
        for (architecture, target) in [
            ("x86_64", WorkerKitTarget::MacosX86_64),
            ("aarch64", WorkerKitTarget::MacosAarch64),
        ] {
            let discovered = inventory("macos", architecture);
            assert_eq!(
                WorkerKitTarget::from_inventory(&discovered).unwrap(),
                target
            );
            let root = fixture_for(target);
            let kit = WorkerKitCatalog::new(root.path())
                .load_for_inventory(&discovered)
                .unwrap();
            assert_eq!(kit.target(), target);
            assert_eq!(kit.files().len(), 5);
            assert_eq!(
                kit.files()
                    .iter()
                    .map(|file| file.name.as_str())
                    .collect::<std::collections::BTreeSet<_>>(),
                [
                    "SHA256SUMS",
                    "cyc-worker",
                    "install-worker.sh",
                    "worker-kit.json",
                    "worker-kit.sig",
                ]
                .into_iter()
                .collect()
            );
        }
        assert!(matches!(
            WorkerKitTarget::from_inventory(&inventory("macos", "armv7")),
            Err(WorkerKitError::UnsupportedTarget)
        ));
    }

    #[test]
    fn install_root_maps_only_to_fixed_worker_kits_child() {
        let install_root = TempDir::new().unwrap();
        let catalog = WorkerKitCatalog::from_install_root(install_root.path()).unwrap();
        assert_eq!(catalog.root(), install_root.path().join("worker-kits"));
        assert!(WorkerKitCatalog::from_install_root("relative-install-root").is_err());
    }

    #[test]
    fn repository_publisher_public_key_is_a_valid_ed25519_trust_root() {
        let encoded = include_str!("../publisher_keys/cyc-release-2026-02.pub").trim();
        let decoded = BASE64_STANDARD.decode(encoded).unwrap();
        let public_key: [u8; 32] = decoded.try_into().unwrap();
        assert!(ed25519_dalek::VerifyingKey::from_bytes(&public_key).is_ok());
    }

    #[test]
    fn tampered_or_extra_files_are_rejected() {
        let root = fixture();
        fs::write(
            root.path().join("linux-x86_64/cyc-worker"),
            b"tampered-worker",
        )
        .unwrap();
        assert!(matches!(
            WorkerKitCatalog::new(root.path()).load_target(WorkerKitTarget::LinuxX86_64),
            Err(WorkerKitError::DigestMismatch)
        ));

        let root = fixture();
        fs::write(root.path().join("linux-x86_64/unexpected"), b"x").unwrap();
        assert!(matches!(
            WorkerKitCatalog::new(root.path()).load_target(WorkerKitTarget::LinuxX86_64),
            Err(WorkerKitError::UnexpectedFileSet)
        ));
    }

    #[test]
    fn recomputed_hashes_do_not_replace_publisher_signature() {
        let root = fixture();
        let directory = root.path().join("linux-x86_64");
        let tampered = b"tampered-worker";
        fs::write(directory.join("cyc-worker"), tampered).unwrap();
        let manifest_path = directory.join("worker-kit.json");
        let mut manifest: WorkerKitManifest =
            serde_json::from_slice(&fs::read(&manifest_path).unwrap()).unwrap();
        manifest.files[0].size_bytes = tampered.len() as u64;
        manifest.files[0].sha256 = sha256_hex(tampered);
        let mut manifest_bytes = serde_json::to_vec(&manifest).unwrap();
        manifest_bytes.push(b'\n');
        fs::write(&manifest_path, &manifest_bytes).unwrap();
        let signature_bytes = fs::read(directory.join("worker-kit.sig")).unwrap();
        fs::write(
            directory.join("SHA256SUMS"),
            format!(
                "{}  cyc-worker\n{}  install-worker.sh\n{}  worker-kit.json\n{}  worker-kit.sig\n",
                sha256_hex(tampered),
                sha256_hex(&fs::read(directory.join("install-worker.sh")).unwrap()),
                sha256_hex(&manifest_bytes),
                sha256_hex(&signature_bytes),
            ),
        )
        .unwrap();
        assert!(matches!(
            WorkerKitCatalog::new(root.path()).load_target(WorkerKitTarget::LinuxX86_64),
            Err(WorkerKitError::InvalidManifest)
        ));
    }

    #[test]
    fn missing_signature_and_untrusted_publisher_are_rejected() {
        let root = fixture();
        fs::remove_file(root.path().join("linux-x86_64/worker-kit.sig")).unwrap();
        assert!(WorkerKitCatalog::new(root.path())
            .load_target(WorkerKitTarget::LinuxX86_64)
            .is_err());

        let root = fixture();
        let foreign = SigningKey::from_bytes(&[7_u8; 32]);
        let catalog = WorkerKitCatalog::with_trusted_publisher(
            root.path(),
            "foreign-publisher",
            foreign.verifying_key().to_bytes(),
        )
        .unwrap();
        assert!(matches!(
            catalog.load_target(WorkerKitTarget::LinuxX86_64),
            Err(WorkerKitError::InvalidManifest)
        ));
    }
}
