//! Safe, recoverable materialization of an already publisher-verified Worker Kit.
//!
//! The caller chooses only an existing parent directory. This module owns every
//! name below it, writes through a private operation-specific staging tree, and
//! publishes the complete tree with a no-replace rename. The enrollment JSON is
//! kept in zeroizing memory and is deliberately absent from markers, receipts,
//! diagnostics, and recovery metadata.

use std::{
    collections::BTreeSet,
    fs::{self, OpenOptions},
    io::{self, ErrorKind, Read, Write},
    path::{Component, Path, PathBuf},
};

#[cfg(any(target_os = "linux", target_os = "macos"))]
use std::ffi::CString;

use cyc_protocol::onboarding::EnrollmentBundleV1;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;
use zeroize::{Zeroize, Zeroizing};

use crate::worker_kit::{sha256_hex, WorkerKit, WorkerKitTarget};

const EXPORT_SCHEMA: &str = "cyc.dev/worker-kit-export/v1";
const EXPORT_MARKER: &str = ".cyc-worker-kit-export.json";
const KIT_DIRECTORY: &str = "kit";
const PRIVATE_DIRECTORY: &str = "private";
const ENROLLMENT_FILE: &str = "enrollment.json";
const FINAL_PREFIX: &str = "ClusterYourCodex-WorkerKit-";
const STAGING_PREFIX: &str = ".cyc-worker-kit-export-";
const STAGING_SUFFIX: &str = ".staging";
const WINDOWS_LAUNCHER: &str = "Start-ClusterYourCodex-Worker.ps1";
const POSIX_LAUNCHER: &str = "start-clusteryourcodex-worker.sh";
const MAX_ENROLLMENT_BYTES: usize = 256 * 1024;
const MAX_MARKER_BYTES: u64 = 64 * 1024;
const MAX_LAUNCHER_BYTES: u64 = 32 * 1024;

const WINDOWS_LAUNCHER_BYTES: &[u8] =
    br#"# ClusterYourCodex worker bootstrap. Generated from a fixed template.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -LiteralPath $PSCommandPath -Parent
$kit = Join-Path $root 'kit'
$private = Join-Path $root 'private'
$enrollment = Join-Path $private 'enrollment.json'
$lifecycle = Join-Path $kit 'Install-Worker.ps1'
try {
    & $lifecycle -Action Install -BundleRoot $kit
    if (-not $?) { throw 'worker preinstall failed' }
    & $lifecycle -Action Repair -BundleRoot $kit -EnrollmentFile $enrollment -PairOnly
    if (-not $?) { throw 'worker pairing failed' }
    & $lifecycle -Action Repair -BundleRoot $kit
    if (-not $?) { throw 'worker activation failed' }
} catch {
    [Console]::Error.WriteLine('ClusterYourCodex worker bootstrap failed.')
    exit 1
}
"#;

const POSIX_LAUNCHER_BYTES: &[u8] = br#"#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
KIT="$ROOT/kit"
ENROLLMENT="$ROOT/private/enrollment.json"
"$KIT/install-worker.sh" install --bundle-root "$KIT"
"$KIT/install-worker.sh" repair --bundle-root "$KIT" --enrollment "$ENROLLMENT" --pair-only
"$KIT/install-worker.sh" repair --bundle-root "$KIT"
"#;

/// A validated, canonical enrollment document held in zeroizing memory.
///
/// This type intentionally implements neither `Debug` nor `Clone`.
pub struct EnrollmentSecret {
    bytes: Zeroizing<Vec<u8>>,
}

impl EnrollmentSecret {
    /// Serialize an already validated shared protocol DTO into canonical
    /// compact JSON plus LF.
    pub fn from_bundle(bundle: &EnrollmentBundleV1) -> Result<Self, WorkerKitExportError> {
        bundle
            .validate()
            .map_err(|_| WorkerKitExportError::InvalidEnrollment)?;
        let mut bytes =
            serde_json::to_vec(bundle).map_err(|_| WorkerKitExportError::InvalidEnrollment)?;
        bytes.push(b'\n');
        Self::from_canonical_bytes(bytes)
    }

    /// Parse untrusted response bytes into the shared DTO, validate it, and
    /// retain only a newly serialized canonical representation. The supplied
    /// buffer is zeroized on every return path.
    pub fn from_json_bytes(bytes: Vec<u8>) -> Result<Self, WorkerKitExportError> {
        let input = Zeroizing::new(bytes);
        if input.is_empty() || input.len() > MAX_ENROLLMENT_BYTES {
            return Err(WorkerKitExportError::InvalidEnrollment);
        }
        let bundle: EnrollmentBundleV1 = serde_json::from_slice(input.as_slice())
            .map_err(|_| WorkerKitExportError::InvalidEnrollment)?;
        Self::from_bundle(&bundle)
    }

    fn from_canonical_bytes(bytes: Vec<u8>) -> Result<Self, WorkerKitExportError> {
        if bytes.is_empty() || bytes.len() > MAX_ENROLLMENT_BYTES {
            let mut bytes = bytes;
            bytes.zeroize();
            return Err(WorkerKitExportError::InvalidEnrollment);
        }
        Ok(Self {
            bytes: Zeroizing::new(bytes),
        })
    }

    fn as_bytes(&self) -> &[u8] {
        self.bytes.as_slice()
    }
}

/// Non-secret result of a successful or reconciled export.
#[derive(Debug, Eq, PartialEq)]
pub struct WorkerKitExportReceipt {
    operation_id: Uuid,
    target: WorkerKitTarget,
    version: String,
    export_root: PathBuf,
    launcher: PathBuf,
    recovered: bool,
}

impl WorkerKitExportReceipt {
    #[must_use]
    pub fn operation_id(&self) -> Uuid {
        self.operation_id
    }

    #[must_use]
    pub fn target(&self) -> WorkerKitTarget {
        self.target
    }

    #[must_use]
    pub fn version(&self) -> &str {
        &self.version
    }

    #[must_use]
    pub fn export_root(&self) -> &Path {
        &self.export_root
    }

    #[must_use]
    pub fn launcher(&self) -> &Path {
        &self.launcher
    }

    #[must_use]
    pub fn recovered(&self) -> bool {
        self.recovered
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct WorkerKitCleanupReceipt {
    pub staging_removed: bool,
    pub export_removed: bool,
}

/// Materializes a kit under one caller-selected, existing parent directory.
pub struct WorkerKitExporter {
    selected_parent: PathBuf,
    parent_identity: FileSystemIdentity,
}

impl std::fmt::Debug for WorkerKitExporter {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("WorkerKitExporter")
            .field("selected_parent", &self.selected_parent)
            .finish_non_exhaustive()
    }
}

impl WorkerKitExporter {
    pub fn new(selected_parent: impl Into<PathBuf>) -> Result<Self, WorkerKitExportError> {
        let selected_parent = selected_parent.into();
        validate_clean_absolute_path(&selected_parent)?;
        validate_existing_path_chain(&selected_parent, ExpectedKind::Directory)?;
        let metadata = fs::symlink_metadata(&selected_parent).map_err(map_io)?;
        let parent_identity = FileSystemIdentity::from_metadata(&metadata)?;
        Ok(Self {
            selected_parent,
            parent_identity,
        })
    }

    #[must_use]
    pub fn selected_parent(&self) -> &Path {
        &self.selected_parent
    }

    /// Write and atomically publish a manual Worker Kit export. Repeating the
    /// same operation after a lost response validates and returns the already
    /// committed tree; a different or damaged destination is never replaced.
    pub fn export(
        &self,
        operation_id: Uuid,
        kit: &WorkerKit,
        enrollment: EnrollmentSecret,
    ) -> Result<WorkerKitExportReceipt, WorkerKitExportError> {
        self.export_inner(operation_id, kit, enrollment, None)
    }

    pub fn cleanup(
        &self,
        operation_id: Uuid,
    ) -> Result<WorkerKitCleanupReceipt, WorkerKitExportError> {
        if operation_id.is_nil() {
            return Err(WorkerKitExportError::InvalidOperation);
        }
        self.verify_parent_identity()?;
        let paths = ExportPaths::new(&self.selected_parent, operation_id);
        let staging_removed = cleanup_if_owned(&paths.staging, operation_id, &paths.final_leaf)?;
        let export_removed = cleanup_if_owned(&paths.final_root, operation_id, &paths.final_leaf)?;
        self.verify_parent_identity()?;
        sync_directory(&self.selected_parent)?;
        Ok(WorkerKitCleanupReceipt {
            staging_removed,
            export_removed,
        })
    }

    fn export_inner(
        &self,
        operation_id: Uuid,
        kit: &WorkerKit,
        enrollment: EnrollmentSecret,
        #[allow(unused_variables)] fault: Option<ExportFault>,
    ) -> Result<WorkerKitExportReceipt, WorkerKitExportError> {
        if operation_id.is_nil() {
            return Err(WorkerKitExportError::InvalidOperation);
        }
        kit.validate_in_memory()
            .map_err(|_| WorkerKitExportError::TamperedKit)?;
        self.verify_parent_identity()?;
        let paths = ExportPaths::new(&self.selected_parent, operation_id);
        let marker = ExportMarker::for_kit(operation_id, &paths.final_leaf, kit)?;

        if path_exists_nofollow(&paths.final_root)? {
            let receipt =
                validate_committed_export(&paths.final_root, &marker, kit, &enrollment, true)?;
            if path_exists_nofollow(&paths.staging)? {
                cleanup_owned_root(&paths.staging, operation_id, &paths.final_leaf)?;
            }
            return Ok(receipt);
        }
        if path_exists_nofollow(&paths.staging)? {
            cleanup_owned_root(&paths.staging, operation_id, &paths.final_leaf)?;
        }

        self.verify_parent_identity()?;
        create_private_directory(&paths.staging)?;
        let staging_metadata = fs::symlink_metadata(&paths.staging).map_err(map_io)?;
        let staging_identity = FileSystemIdentity::from_metadata(&staging_metadata)?;
        let marker_bytes = marker.canonical_bytes()?;
        let marker_path = paths.staging.join(EXPORT_MARKER);

        let result = (|| {
            write_verified_file(&marker_path, &marker_bytes, 0o600, MAX_MARKER_BYTES)?;
            maybe_fault(fault, ExportFault::MarkerWritten)?;

            let kit_directory = paths.staging.join(KIT_DIRECTORY);
            let private_directory = paths.staging.join(PRIVATE_DIRECTORY);
            create_private_directory(&kit_directory)?;
            create_private_directory(&private_directory)?;

            for file in kit.files() {
                write_verified_file(
                    &kit_directory.join(&file.name),
                    &file.content,
                    file.unix_mode as u32,
                    maximum_kit_file_bytes(&file.name)?,
                )?;
            }

            let enrollment_path = private_directory.join(ENROLLMENT_FILE);
            write_verified_secret(&enrollment_path, enrollment.as_bytes())?;

            let (launcher_name, launcher_bytes) = launcher_for_target(kit.target());
            write_verified_file(
                &paths.staging.join(launcher_name),
                launcher_bytes,
                0o700,
                MAX_LAUNCHER_BYTES,
            )?;

            sync_directory(&kit_directory)?;
            sync_directory(&private_directory)?;
            sync_directory(&paths.staging)?;
            verify_private_tree_permissions(&paths.staging)?;
            validate_export_tree(&paths.staging, &marker, kit, &enrollment)?;
            maybe_fault(fault, ExportFault::FilesWritten)?;

            self.verify_parent_identity()?;
            verify_identity(&paths.staging, ExpectedKind::Directory, &staging_identity)?;
            rename_noreplace(&paths.staging, &paths.final_root)?;
            sync_directory(&self.selected_parent)?;
            maybe_fault(fault, ExportFault::RenameCompleted)?;

            verify_identity(
                &paths.final_root,
                ExpectedKind::Directory,
                &staging_identity,
            )?;
            self.verify_parent_identity()?;
            validate_committed_export(&paths.final_root, &marker, kit, &enrollment, false)
        })();

        if result.is_err()
            && path_exists_nofollow(&paths.staging).unwrap_or(false)
            && !is_injected_crash(&result)
        {
            let _ = cleanup_owned_root(&paths.staging, operation_id, &paths.final_leaf);
        }
        result
    }

    fn verify_parent_identity(&self) -> Result<(), WorkerKitExportError> {
        validate_existing_path_chain(&self.selected_parent, ExpectedKind::Directory)?;
        verify_identity(
            &self.selected_parent,
            ExpectedKind::Directory,
            &self.parent_identity,
        )
    }
}

struct ExportPaths {
    final_leaf: String,
    final_root: PathBuf,
    staging: PathBuf,
}

impl ExportPaths {
    fn new(parent: &Path, operation_id: Uuid) -> Self {
        let compact = operation_id.simple().to_string();
        let final_leaf = format!("{FINAL_PREFIX}{compact}");
        let staging_leaf = format!("{STAGING_PREFIX}{compact}{STAGING_SUFFIX}");
        Self {
            final_root: parent.join(&final_leaf),
            staging: parent.join(staging_leaf),
            final_leaf,
        }
    }
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ExportMarker {
    schema_version: String,
    operation_id: Uuid,
    final_leaf: String,
    target: String,
    version: String,
    launcher: String,
    files: Vec<ExportMarkerFile>,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ExportMarkerFile {
    path: String,
    size_bytes: u64,
    sha256: String,
}

impl ExportMarker {
    fn for_kit(
        operation_id: Uuid,
        final_leaf: &str,
        kit: &WorkerKit,
    ) -> Result<Self, WorkerKitExportError> {
        let (launcher, launcher_bytes) = launcher_for_target(kit.target());
        let mut files = kit
            .files()
            .iter()
            .map(|file| ExportMarkerFile {
                path: format!("{KIT_DIRECTORY}/{}", file.name),
                size_bytes: file.content.len() as u64,
                sha256: file.sha256.clone(),
            })
            .collect::<Vec<_>>();
        files.push(ExportMarkerFile {
            path: launcher.to_owned(),
            size_bytes: launcher_bytes.len() as u64,
            sha256: sha256_hex(launcher_bytes),
        });
        files.sort_by(|left, right| left.path.cmp(&right.path));
        Ok(Self {
            schema_version: EXPORT_SCHEMA.to_owned(),
            operation_id,
            final_leaf: final_leaf.to_owned(),
            target: kit.target().as_str().to_owned(),
            version: kit.version().to_owned(),
            launcher: launcher.to_owned(),
            files,
        })
    }

    fn canonical_bytes(&self) -> Result<Vec<u8>, WorkerKitExportError> {
        let mut bytes =
            serde_json::to_vec(self).map_err(|_| WorkerKitExportError::InvalidMarker)?;
        bytes.push(b'\n');
        if bytes.len() as u64 > MAX_MARKER_BYTES {
            return Err(WorkerKitExportError::InvalidMarker);
        }
        Ok(bytes)
    }

    fn validate_identity(
        &self,
        operation_id: Uuid,
        final_leaf: &str,
    ) -> Result<WorkerKitTarget, WorkerKitExportError> {
        if self.schema_version != EXPORT_SCHEMA
            || self.operation_id != operation_id
            || self.final_leaf != final_leaf
            || self.version.is_empty()
            || self.version.len() > 128
        {
            return Err(WorkerKitExportError::InvalidMarker);
        }
        let target = parse_target(&self.target).ok_or(WorkerKitExportError::InvalidMarker)?;
        if self.launcher != launcher_for_target(target).0 {
            return Err(WorkerKitExportError::InvalidMarker);
        }
        let expected_paths: BTreeSet<String> = target
            .expected_names()
            .into_iter()
            .map(|name| format!("{KIT_DIRECTORY}/{name}"))
            .chain(std::iter::once(self.launcher.clone()))
            .collect();
        let mut observed = BTreeSet::new();
        for file in &self.files {
            if !expected_paths.contains(&file.path)
                || !observed.insert(file.path.clone())
                || file.size_bytes == 0
                || file.sha256.len() != 64
                || !file.sha256.bytes().all(|byte| byte.is_ascii_hexdigit())
            {
                return Err(WorkerKitExportError::InvalidMarker);
            }
        }
        if observed != expected_paths {
            return Err(WorkerKitExportError::InvalidMarker);
        }
        Ok(target)
    }
}

fn validate_committed_export(
    root: &Path,
    marker: &ExportMarker,
    kit: &WorkerKit,
    enrollment: &EnrollmentSecret,
    recovered: bool,
) -> Result<WorkerKitExportReceipt, WorkerKitExportError> {
    validate_export_tree(root, marker, kit, enrollment)?;
    verify_private_tree_permissions(root)?;
    let (launcher, _) = launcher_for_target(kit.target());
    Ok(WorkerKitExportReceipt {
        operation_id: marker.operation_id,
        target: kit.target(),
        version: kit.version().to_owned(),
        export_root: root.to_path_buf(),
        launcher: root.join(launcher),
        recovered,
    })
}

fn validate_export_tree(
    root: &Path,
    expected_marker: &ExportMarker,
    kit: &WorkerKit,
    enrollment: &EnrollmentSecret,
) -> Result<(), WorkerKitExportError> {
    validate_existing_path_chain(root, ExpectedKind::Directory)?;
    let root_identity = identity_for_path(root, ExpectedKind::Directory)?;
    let (launcher_name, launcher_bytes) = launcher_for_target(kit.target());
    assert_exact_names(
        root,
        [
            EXPORT_MARKER,
            KIT_DIRECTORY,
            PRIVATE_DIRECTORY,
            launcher_name,
        ],
    )?;

    let marker_bytes = read_bounded_nofollow(&root.join(EXPORT_MARKER), MAX_MARKER_BYTES)?;
    let marker: ExportMarker =
        serde_json::from_slice(&marker_bytes).map_err(|_| WorkerKitExportError::InvalidMarker)?;
    if marker.canonical_bytes()? != marker_bytes
        || marker.operation_id != expected_marker.operation_id
        || marker.final_leaf != expected_marker.final_leaf
        || marker.target != expected_marker.target
        || marker.version != expected_marker.version
        || marker.launcher != expected_marker.launcher
        || marker.files.len() != expected_marker.files.len()
        || marker
            .files
            .iter()
            .zip(&expected_marker.files)
            .any(|(left, right)| {
                left.path != right.path
                    || left.size_bytes != right.size_bytes
                    || left.sha256 != right.sha256
            })
    {
        return Err(WorkerKitExportError::InvalidMarker);
    }
    marker.validate_identity(expected_marker.operation_id, &expected_marker.final_leaf)?;

    let kit_root = root.join(KIT_DIRECTORY);
    let private_root = root.join(PRIVATE_DIRECTORY);
    validate_existing_path_chain(&kit_root, ExpectedKind::Directory)?;
    validate_existing_path_chain(&private_root, ExpectedKind::Directory)?;
    assert_exact_names(kit_root.as_path(), kit.target().expected_names())?;
    assert_exact_names(private_root.as_path(), [ENROLLMENT_FILE])?;

    for file in kit.files() {
        let content = read_bounded_nofollow(
            &kit_root.join(&file.name),
            maximum_kit_file_bytes(&file.name)?,
        )?;
        if content.len() != file.content.len()
            || sha256_hex(&content) != file.sha256
            || !constant_time_eq(&content, &file.content)
        {
            return Err(WorkerKitExportError::ReadbackMismatch);
        }
        verify_file_permissions(&kit_root.join(&file.name), file.unix_mode as u32)?;
    }

    let launcher = read_bounded_nofollow(&root.join(launcher_name), MAX_LAUNCHER_BYTES)?;
    if !constant_time_eq(&launcher, launcher_bytes) {
        return Err(WorkerKitExportError::ReadbackMismatch);
    }
    verify_file_permissions(&root.join(launcher_name), 0o700)?;

    let enrollment_readback = Zeroizing::new(read_bounded_nofollow(
        &private_root.join(ENROLLMENT_FILE),
        MAX_ENROLLMENT_BYTES as u64,
    )?);
    if !constant_time_eq(enrollment_readback.as_slice(), enrollment.as_bytes()) {
        return Err(WorkerKitExportError::ReadbackMismatch);
    }
    verify_file_permissions(&private_root.join(ENROLLMENT_FILE), 0o600)?;
    verify_file_permissions(&root.join(EXPORT_MARKER), 0o600)?;

    verify_identity(root, ExpectedKind::Directory, &root_identity)?;
    Ok(())
}

fn cleanup_if_owned(
    path: &Path,
    operation_id: Uuid,
    final_leaf: &str,
) -> Result<bool, WorkerKitExportError> {
    if !path_exists_nofollow(path)? {
        return Ok(false);
    }
    cleanup_owned_root(path, operation_id, final_leaf)?;
    Ok(true)
}

fn cleanup_owned_root(
    root: &Path,
    operation_id: Uuid,
    final_leaf: &str,
) -> Result<(), WorkerKitExportError> {
    validate_existing_path_chain(root, ExpectedKind::Directory)?;
    let root_identity = identity_for_path(root, ExpectedKind::Directory)?;
    let marker_path = root.join(EXPORT_MARKER);
    let bytes = read_bounded_nofollow(&marker_path, MAX_MARKER_BYTES)?;
    let marker: ExportMarker =
        serde_json::from_slice(&bytes).map_err(|_| WorkerKitExportError::ForeignDestination)?;
    if marker
        .canonical_bytes()
        .map_err(|_| WorkerKitExportError::ForeignDestination)?
        != bytes
    {
        return Err(WorkerKitExportError::ForeignDestination);
    }
    let target = marker
        .validate_identity(operation_id, final_leaf)
        .map_err(|_| WorkerKitExportError::ForeignDestination)?;

    let allowed_root: BTreeSet<&str> = [
        EXPORT_MARKER,
        KIT_DIRECTORY,
        PRIVATE_DIRECTORY,
        marker.launcher.as_str(),
    ]
    .into_iter()
    .collect();
    for entry in read_dir_entries(root)? {
        if !allowed_root.contains(entry.name.as_str()) {
            return Err(WorkerKitExportError::ForeignDestination);
        }
        reject_reparse_metadata(&entry.metadata)?;
    }

    let kit_root = root.join(KIT_DIRECTORY);
    if path_exists_nofollow(&kit_root)? {
        validate_existing_path_chain(&kit_root, ExpectedKind::Directory)?;
        let allowed: BTreeSet<&str> = target.expected_names().into_iter().collect();
        for entry in read_dir_entries(&kit_root)? {
            if !allowed.contains(entry.name.as_str()) || !metadata_is_safe_file(&entry.metadata) {
                return Err(WorkerKitExportError::ForeignDestination);
            }
            fs::remove_file(kit_root.join(entry.name)).map_err(map_io)?;
        }
        fs::remove_dir(&kit_root).map_err(map_io)?;
    }

    let private_root = root.join(PRIVATE_DIRECTORY);
    if path_exists_nofollow(&private_root)? {
        validate_existing_path_chain(&private_root, ExpectedKind::Directory)?;
        for entry in read_dir_entries(&private_root)? {
            if entry.name != ENROLLMENT_FILE || !metadata_is_safe_file(&entry.metadata) {
                return Err(WorkerKitExportError::ForeignDestination);
            }
            fs::remove_file(private_root.join(entry.name)).map_err(map_io)?;
        }
        fs::remove_dir(&private_root).map_err(map_io)?;
    }

    let launcher_path = root.join(&marker.launcher);
    if path_exists_nofollow(&launcher_path)? {
        let metadata = fs::symlink_metadata(&launcher_path).map_err(map_io)?;
        if !metadata_is_safe_file(&metadata) {
            return Err(WorkerKitExportError::ForeignDestination);
        }
        fs::remove_file(&launcher_path).map_err(map_io)?;
    }
    verify_identity(root, ExpectedKind::Directory, &root_identity)?;
    fs::remove_file(marker_path).map_err(map_io)?;
    fs::remove_dir(root).map_err(map_io)?;
    Ok(())
}

fn write_verified_secret(path: &Path, bytes: &[u8]) -> Result<(), WorkerKitExportError> {
    if bytes.is_empty() || bytes.len() > MAX_ENROLLMENT_BYTES {
        return Err(WorkerKitExportError::InvalidEnrollment);
    }
    write_verified_file(path, bytes, 0o600, MAX_ENROLLMENT_BYTES as u64)?;
    let readback = Zeroizing::new(read_bounded_nofollow(path, MAX_ENROLLMENT_BYTES as u64)?);
    if !constant_time_eq(readback.as_slice(), bytes) {
        return Err(WorkerKitExportError::ReadbackMismatch);
    }
    Ok(())
}

fn write_verified_file(
    path: &Path,
    bytes: &[u8],
    unix_mode: u32,
    maximum: u64,
) -> Result<(), WorkerKitExportError> {
    if bytes.is_empty() || bytes.len() as u64 > maximum {
        return Err(WorkerKitExportError::BoundExceeded);
    }
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    configure_create_mode(&mut options, unix_mode);
    let mut file = options.open(path).map_err(map_create_io)?;
    file.write_all(bytes).map_err(map_io)?;
    file.sync_all().map_err(map_io)?;
    drop(file);
    verify_file_permissions(path, unix_mode)?;
    let readback = read_bounded_nofollow(path, maximum)?;
    if readback.len() != bytes.len()
        || sha256_hex(&readback) != sha256_hex(bytes)
        || !constant_time_eq(&readback, bytes)
    {
        return Err(WorkerKitExportError::ReadbackMismatch);
    }
    Ok(())
}

fn read_bounded_nofollow(path: &Path, maximum: u64) -> Result<Vec<u8>, WorkerKitExportError> {
    let before_metadata = fs::symlink_metadata(path).map_err(map_io)?;
    if !metadata_is_safe_file(&before_metadata)
        || before_metadata.len() == 0
        || before_metadata.len() > maximum
    {
        return Err(WorkerKitExportError::UnsafePath);
    }
    let identity = FileSystemIdentity::from_metadata(&before_metadata)?;
    let mut options = OpenOptions::new();
    options.read(true);
    configure_nofollow_open(&mut options);
    let mut file = options.open(path).map_err(map_io)?;
    let open_metadata = file.metadata().map_err(map_io)?;
    if !metadata_is_safe_file(&open_metadata)
        || FileSystemIdentity::from_metadata(&open_metadata)? != identity
    {
        return Err(WorkerKitExportError::UnsafePath);
    }
    let mut bytes = Vec::with_capacity(before_metadata.len() as usize);
    Read::by_ref(&mut file)
        .take(maximum + 1)
        .read_to_end(&mut bytes)
        .map_err(map_io)?;
    if bytes.len() as u64 != before_metadata.len() || bytes.len() as u64 > maximum {
        bytes.zeroize();
        return Err(WorkerKitExportError::ReadbackMismatch);
    }
    verify_identity(path, ExpectedKind::File, &identity)?;
    Ok(bytes)
}

fn assert_exact_names<const N: usize>(
    directory: &Path,
    expected: [&str; N],
) -> Result<(), WorkerKitExportError> {
    let expected: BTreeSet<&str> = expected.into_iter().collect();
    let entries = read_dir_entries(directory)?;
    let observed: BTreeSet<&str> = entries.iter().map(|entry| entry.name.as_str()).collect();
    if observed != expected {
        return Err(WorkerKitExportError::UnexpectedTree);
    }
    for entry in entries {
        reject_reparse_metadata(&entry.metadata)?;
    }
    Ok(())
}

struct DirectoryEntry {
    name: String,
    metadata: fs::Metadata,
}

fn read_dir_entries(directory: &Path) -> Result<Vec<DirectoryEntry>, WorkerKitExportError> {
    let identity = identity_for_path(directory, ExpectedKind::Directory)?;
    let mut entries = Vec::new();
    for entry in fs::read_dir(directory).map_err(map_io)? {
        let entry = entry.map_err(map_io)?;
        let name = entry
            .file_name()
            .into_string()
            .map_err(|_| WorkerKitExportError::UnsafePath)?;
        if name.is_empty() || name.contains(['/', '\\', '\0', '\r', '\n']) {
            return Err(WorkerKitExportError::UnsafePath);
        }
        let metadata = fs::symlink_metadata(entry.path()).map_err(map_io)?;
        entries.push(DirectoryEntry { name, metadata });
    }
    verify_identity(directory, ExpectedKind::Directory, &identity)?;
    Ok(entries)
}

fn validate_clean_absolute_path(path: &Path) -> Result<(), WorkerKitExportError> {
    if !path.is_absolute()
        || path
            .components()
            .any(|component| matches!(component, Component::CurDir | Component::ParentDir))
    {
        return Err(WorkerKitExportError::InvalidParent);
    }
    Ok(())
}

fn validate_existing_path_chain(
    path: &Path,
    expected_kind: ExpectedKind,
) -> Result<(), WorkerKitExportError> {
    validate_clean_absolute_path(path)?;
    let mut candidate = PathBuf::new();
    for component in path.components() {
        candidate.push(component.as_os_str());
        let metadata = fs::symlink_metadata(&candidate).map_err(map_io)?;
        reject_reparse_metadata(&metadata)?;
    }
    let metadata = fs::symlink_metadata(path).map_err(map_io)?;
    if !metadata_matches_kind(&metadata, expected_kind) {
        return Err(WorkerKitExportError::UnsafePath);
    }
    Ok(())
}

fn path_exists_nofollow(path: &Path) -> Result<bool, WorkerKitExportError> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(false),
        Err(error) => Err(map_io(error)),
    }
}

#[derive(Clone, Copy)]
enum ExpectedKind {
    Directory,
    File,
}

fn identity_for_path(
    path: &Path,
    expected_kind: ExpectedKind,
) -> Result<FileSystemIdentity, WorkerKitExportError> {
    let metadata = fs::symlink_metadata(path).map_err(map_io)?;
    if !metadata_matches_kind(&metadata, expected_kind) {
        return Err(WorkerKitExportError::UnsafePath);
    }
    FileSystemIdentity::from_metadata(&metadata)
}

fn verify_identity(
    path: &Path,
    expected_kind: ExpectedKind,
    identity: &FileSystemIdentity,
) -> Result<(), WorkerKitExportError> {
    let metadata = fs::symlink_metadata(path).map_err(map_io)?;
    if !metadata_matches_kind(&metadata, expected_kind)
        || &FileSystemIdentity::from_metadata(&metadata)? != identity
    {
        return Err(WorkerKitExportError::UnsafePath);
    }
    Ok(())
}

fn metadata_matches_kind(metadata: &fs::Metadata, expected_kind: ExpectedKind) -> bool {
    match expected_kind {
        ExpectedKind::Directory => metadata_is_safe_directory(metadata),
        ExpectedKind::File => metadata_is_safe_file(metadata),
    }
}

fn metadata_is_safe_directory(metadata: &fs::Metadata) -> bool {
    metadata.is_dir()
        && !metadata.file_type().is_symlink()
        && !metadata_is_windows_reparse(metadata)
}

fn metadata_is_safe_file(metadata: &fs::Metadata) -> bool {
    metadata.is_file()
        && !metadata.file_type().is_symlink()
        && !metadata_is_windows_reparse(metadata)
        && metadata_has_single_link(metadata)
}

fn reject_reparse_metadata(metadata: &fs::Metadata) -> Result<(), WorkerKitExportError> {
    if metadata.file_type().is_symlink() || metadata_is_windows_reparse(metadata) {
        return Err(WorkerKitExportError::UnsafePath);
    }
    Ok(())
}

fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }
    let mut difference = 0_u8;
    for (left, right) in left.iter().zip(right) {
        difference |= left ^ right;
    }
    difference == 0
}

fn launcher_for_target(target: WorkerKitTarget) -> (&'static str, &'static [u8]) {
    match target {
        WorkerKitTarget::WindowsX86_64 => (WINDOWS_LAUNCHER, WINDOWS_LAUNCHER_BYTES),
        WorkerKitTarget::LinuxX86_64
        | WorkerKitTarget::LinuxAarch64
        | WorkerKitTarget::MacosX86_64
        | WorkerKitTarget::MacosAarch64 => (POSIX_LAUNCHER, POSIX_LAUNCHER_BYTES),
    }
}

fn parse_target(value: &str) -> Option<WorkerKitTarget> {
    match value {
        "windows-x86_64" => Some(WorkerKitTarget::WindowsX86_64),
        "linux-x86_64" => Some(WorkerKitTarget::LinuxX86_64),
        "linux-aarch64" => Some(WorkerKitTarget::LinuxAarch64),
        "macos-x86_64" => Some(WorkerKitTarget::MacosX86_64),
        "macos-aarch64" => Some(WorkerKitTarget::MacosAarch64),
        _ => None,
    }
}

fn maximum_kit_file_bytes(name: &str) -> Result<u64, WorkerKitExportError> {
    match name {
        "cyc-worker" | "cyc-worker.exe" => Ok(512 * 1024 * 1024),
        "install-worker.sh" | "Install-Worker.ps1" => Ok(2 * 1024 * 1024),
        "worker-kit.json" => Ok(1024 * 1024),
        "worker-kit.sig" => Ok(16 * 1024),
        "SHA256SUMS" => Ok(64 * 1024),
        _ => Err(WorkerKitExportError::TamperedKit),
    }
}

#[cfg(unix)]
fn create_private_directory(path: &Path) -> Result<(), WorkerKitExportError> {
    use std::os::unix::fs::DirBuilderExt;

    let mut builder = fs::DirBuilder::new();
    builder.mode(0o700);
    builder.create(path).map_err(map_create_io)?;
    verify_directory_permissions(path)
}

#[cfg(windows)]
fn create_private_directory(path: &Path) -> Result<(), WorkerKitExportError> {
    fs::create_dir(path).map_err(map_create_io)?;
    if let Err(error) = apply_or_verify_windows_acl(path, "apply") {
        let _ = fs::remove_dir(path);
        return Err(error);
    }
    Ok(())
}

#[cfg(not(any(unix, windows)))]
fn create_private_directory(_path: &Path) -> Result<(), WorkerKitExportError> {
    Err(WorkerKitExportError::UnsupportedPlatform)
}

#[cfg(unix)]
fn configure_create_mode(options: &mut OpenOptions, mode: u32) {
    use std::os::unix::fs::OpenOptionsExt;

    options.mode(mode);
}

#[cfg(not(unix))]
fn configure_create_mode(_options: &mut OpenOptions, _mode: u32) {}

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

#[cfg(unix)]
fn verify_directory_permissions(path: &Path) -> Result<(), WorkerKitExportError> {
    use std::os::unix::fs::PermissionsExt;

    let metadata = fs::symlink_metadata(path).map_err(map_io)?;
    if !metadata_is_safe_directory(&metadata) || metadata.permissions().mode() & 0o777 != 0o700 {
        return Err(WorkerKitExportError::UnsafePermissions);
    }
    Ok(())
}

#[cfg(windows)]
fn verify_directory_permissions(path: &Path) -> Result<(), WorkerKitExportError> {
    apply_or_verify_windows_acl(path, "verify")
}

#[cfg(not(any(unix, windows)))]
fn verify_directory_permissions(_path: &Path) -> Result<(), WorkerKitExportError> {
    Err(WorkerKitExportError::UnsupportedPlatform)
}

#[cfg(unix)]
fn verify_file_permissions(path: &Path, expected: u32) -> Result<(), WorkerKitExportError> {
    use std::os::unix::fs::PermissionsExt;

    let metadata = fs::symlink_metadata(path).map_err(map_io)?;
    if !metadata_is_safe_file(&metadata)
        || metadata.permissions().mode() & 0o777 != expected & 0o777
    {
        return Err(WorkerKitExportError::UnsafePermissions);
    }
    Ok(())
}

#[cfg(windows)]
fn verify_file_permissions(path: &Path, _expected: u32) -> Result<(), WorkerKitExportError> {
    let metadata = fs::symlink_metadata(path).map_err(map_io)?;
    if !metadata_is_safe_file(&metadata) {
        return Err(WorkerKitExportError::UnsafePath);
    }
    Ok(())
}

#[cfg(not(any(unix, windows)))]
fn verify_file_permissions(_path: &Path, _expected: u32) -> Result<(), WorkerKitExportError> {
    Err(WorkerKitExportError::UnsupportedPlatform)
}

fn verify_private_tree_permissions(root: &Path) -> Result<(), WorkerKitExportError> {
    verify_directory_permissions(root)?;
    #[cfg(windows)]
    apply_or_verify_windows_acl(root, "verify-tree")?;
    Ok(())
}

#[cfg(unix)]
fn sync_directory(path: &Path) -> Result<(), WorkerKitExportError> {
    let directory = fs::File::open(path).map_err(map_io)?;
    directory.sync_all().map_err(map_io)
}

#[cfg(windows)]
fn sync_directory(_path: &Path) -> Result<(), WorkerKitExportError> {
    // Every file is individually flushed. Rust's stable Windows directory
    // handles do not expose the backup-semantics open needed for FlushFileBuffers.
    Ok(())
}

#[cfg(not(any(unix, windows)))]
fn sync_directory(_path: &Path) -> Result<(), WorkerKitExportError> {
    Err(WorkerKitExportError::UnsupportedPlatform)
}

#[cfg(target_os = "linux")]
fn rename_noreplace(source: &Path, destination: &Path) -> Result<(), WorkerKitExportError> {
    use std::os::unix::ffi::OsStrExt;

    const AT_FDCWD: i32 = -100;
    const RENAME_NOREPLACE: u32 = 1;
    let source = CString::new(source.as_os_str().as_bytes())
        .map_err(|_| WorkerKitExportError::UnsafePath)?;
    let destination = CString::new(destination.as_os_str().as_bytes())
        .map_err(|_| WorkerKitExportError::UnsafePath)?;
    unsafe extern "C" {
        fn renameat2(
            old_directory: i32,
            old_path: *const std::ffi::c_char,
            new_directory: i32,
            new_path: *const std::ffi::c_char,
            flags: u32,
        ) -> i32;
    }
    // `RENAME_NOREPLACE` is the kernel-enforced commit primitive; a check then
    // ordinary rename would reintroduce the destination replacement race.
    let result = unsafe {
        renameat2(
            AT_FDCWD,
            source.as_ptr(),
            AT_FDCWD,
            destination.as_ptr(),
            RENAME_NOREPLACE,
        )
    };
    if result == 0 {
        Ok(())
    } else {
        Err(map_rename_io(io::Error::last_os_error()))
    }
}

#[cfg(target_os = "macos")]
fn rename_noreplace(source: &Path, destination: &Path) -> Result<(), WorkerKitExportError> {
    use std::os::unix::ffi::OsStrExt;

    const RENAME_EXCL: u32 = 0x0000_0004;
    let source = CString::new(source.as_os_str().as_bytes())
        .map_err(|_| WorkerKitExportError::UnsafePath)?;
    let destination = CString::new(destination.as_os_str().as_bytes())
        .map_err(|_| WorkerKitExportError::UnsafePath)?;
    unsafe extern "C" {
        fn renamex_np(
            old_path: *const std::ffi::c_char,
            new_path: *const std::ffi::c_char,
            flags: u32,
        ) -> i32;
    }
    let result = unsafe { renamex_np(source.as_ptr(), destination.as_ptr(), RENAME_EXCL) };
    if result == 0 {
        Ok(())
    } else {
        Err(map_rename_io(io::Error::last_os_error()))
    }
}

#[cfg(windows)]
fn rename_noreplace(source: &Path, destination: &Path) -> Result<(), WorkerKitExportError> {
    // MoveFileEx without MOVEFILE_REPLACE_EXISTING is the implementation used
    // by `std::fs::rename` on Windows; an existing destination is an error.
    fs::rename(source, destination).map_err(map_rename_io)
}

#[cfg(not(any(target_os = "linux", target_os = "macos", windows)))]
fn rename_noreplace(_source: &Path, _destination: &Path) -> Result<(), WorkerKitExportError> {
    Err(WorkerKitExportError::UnsupportedPlatform)
}

#[cfg(unix)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct FileSystemIdentity {
    device: u64,
    inode: u64,
}

#[cfg(unix)]
impl FileSystemIdentity {
    fn from_metadata(metadata: &fs::Metadata) -> Result<Self, WorkerKitExportError> {
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
    fn from_metadata(metadata: &fs::Metadata) -> Result<Self, WorkerKitExportError> {
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
    fn from_metadata(_metadata: &fs::Metadata) -> Result<Self, WorkerKitExportError> {
        Err(WorkerKitExportError::UnsupportedPlatform)
    }
}

#[cfg(unix)]
fn metadata_has_single_link(metadata: &fs::Metadata) -> bool {
    use std::os::unix::fs::MetadataExt;

    metadata.nlink() == 1
}

#[cfg(windows)]
fn metadata_has_single_link(_metadata: &fs::Metadata) -> bool {
    true
}

#[cfg(not(any(unix, windows)))]
fn metadata_has_single_link(_metadata: &fs::Metadata) -> bool {
    false
}

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

#[cfg(windows)]
fn apply_or_verify_windows_acl(path: &Path, action: &str) -> Result<(), WorkerKitExportError> {
    use std::process::Command;

    let operation = Command::new("powershell.exe")
        .args([
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            WINDOWS_PRIVATE_ACL_SCRIPT,
        ])
        .env("CYC_EXPORT_ACL_PATH", path)
        .env("CYC_EXPORT_ACL_ACTION", action)
        .output()
        .map_err(map_io)?;
    if operation.status.success() {
        Ok(())
    } else {
        Err(WorkerKitExportError::UnsafePermissions)
    }
}

#[cfg(windows)]
const WINDOWS_PRIVATE_ACL_SCRIPT: &str = r#"
$ErrorActionPreference = 'Stop'
try {
    $path = [Environment]::GetEnvironmentVariable('CYC_EXPORT_ACL_PATH')
    $action = [Environment]::GetEnvironmentVariable('CYC_EXPORT_ACL_ACTION')
    if ([string]::IsNullOrWhiteSpace($path) -or $action -notin @('apply','verify','verify-tree')) { throw 'contract' }
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $root = [IO.DirectoryInfo]::new($path)
    $root.Refresh()
    if (-not $root.Exists -or (($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'contract' }
    if ($action -eq 'apply') {
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetOwner($user)
        $acl.SetAccessRuleProtection($true, $false)
        $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
        foreach ($principal in @($user, $system)) {
            $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                $principal,
                [Security.AccessControl.FileSystemRights]::FullControl,
                $inheritance,
                [Security.AccessControl.PropagationFlags]::None,
                [Security.AccessControl.AccessControlType]::Allow)
            [void]$acl.AddAccessRule($rule)
        }
        [IO.FileSystemAclExtensions]::SetAccessControl($root, $acl)
    }
    $items = @([IO.DirectoryInfo]::new($path))
    if ($action -eq 'verify-tree') {
        $items += @(Get-ChildItem -LiteralPath $path -Force -Recurse)
    }
    foreach ($item in $items) {
        $item.Refresh()
        if (-not $item.Exists -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'contract' }
        $acl = [IO.FileSystemAclExtensions]::GetAccessControl($item)
        $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($owner -ne $user.Value) { throw 'contract' }
        if ($item.FullName -eq $path -and -not $acl.AreAccessRulesProtected) { throw 'contract' }
        $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        if ($rules.Count -ne 2) { throw 'contract' }
        $seen = @{$user.Value = $false; $system.Value = $false}
        foreach ($rule in $rules) {
            $sid = $rule.IdentityReference.Value
            if (-not $seen.ContainsKey($sid) -or $seen[$sid]) { throw 'contract' }
            if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { throw 'contract' }
            if (($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne [Security.AccessControl.FileSystemRights]::FullControl) { throw 'contract' }
            $seen[$sid] = $true
        }
        if ($seen.Values -contains $false) { throw 'contract' }
    }
    exit 0
} catch {
    exit 1
}
"#;

fn map_io(error: io::Error) -> WorkerKitExportError {
    WorkerKitExportError::Io(error)
}

fn map_create_io(error: io::Error) -> WorkerKitExportError {
    if error.kind() == ErrorKind::AlreadyExists {
        WorkerKitExportError::DestinationExists
    } else {
        map_io(error)
    }
}

fn map_rename_io(error: io::Error) -> WorkerKitExportError {
    if error.kind() == ErrorKind::AlreadyExists
        || matches!(error.raw_os_error(), Some(17 | 39 | 145 | 183))
    {
        WorkerKitExportError::DestinationExists
    } else {
        map_io(error)
    }
}

#[derive(Debug, Error)]
pub enum WorkerKitExportError {
    #[error("worker-kit export parent is invalid")]
    InvalidParent,
    #[error("worker-kit export operation id is invalid")]
    InvalidOperation,
    #[error("worker-kit enrollment document is invalid")]
    InvalidEnrollment,
    #[error("worker-kit in-memory payload failed integrity validation")]
    TamperedKit,
    #[error("worker-kit export path is unsafe")]
    UnsafePath,
    #[error("worker-kit export permissions are unsafe")]
    UnsafePermissions,
    #[error("worker-kit export destination already exists")]
    DestinationExists,
    #[error("worker-kit export destination is not owned by this operation")]
    ForeignDestination,
    #[error("worker-kit export marker is invalid")]
    InvalidMarker,
    #[error("worker-kit export tree is not exact")]
    UnexpectedTree,
    #[error("worker-kit export size limit was exceeded")]
    BoundExceeded,
    #[error("worker-kit export readback verification failed")]
    ReadbackMismatch,
    #[error("worker-kit export is unsupported on this platform")]
    UnsupportedPlatform,
    #[error("worker-kit export I/O failed")]
    Io(#[source] io::Error),
    #[cfg(test)]
    #[error("worker-kit export fault was injected")]
    InjectedCrash,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ExportFault {
    MarkerWritten,
    FilesWritten,
    RenameCompleted,
}

#[cfg(test)]
fn maybe_fault(
    requested: Option<ExportFault>,
    checkpoint: ExportFault,
) -> Result<(), WorkerKitExportError> {
    if requested == Some(checkpoint) {
        Err(WorkerKitExportError::InjectedCrash)
    } else {
        Ok(())
    }
}

#[cfg(not(test))]
fn maybe_fault(
    _requested: Option<ExportFault>,
    _checkpoint: ExportFault,
) -> Result<(), WorkerKitExportError> {
    Ok(())
}

#[cfg(test)]
fn is_injected_crash<T>(result: &Result<T, WorkerKitExportError>) -> bool {
    matches!(result, Err(WorkerKitExportError::InjectedCrash))
}

#[cfg(not(test))]
fn is_injected_crash<T>(_result: &Result<T, WorkerKitExportError>) -> bool {
    false
}
