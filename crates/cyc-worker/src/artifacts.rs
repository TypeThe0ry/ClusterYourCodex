use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use cyc_protocol::ArtifactSpec;
use globset::{Glob, GlobSet, GlobSetBuilder};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;
use walkdir::WalkDir;

use crate::source::PreparedJob;

pub const MAX_ARTIFACT_BYTES: u64 = 64 * 1024 * 1024;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ArtifactEvidence {
    pub id: Uuid,
    pub name: String,
    pub size_bytes: u64,
    pub sha256: String,
    #[serde(skip)]
    pub path: PathBuf,
}

pub fn collect_artifacts(
    prepared: &PreparedJob,
    specification: &ArtifactSpec,
) -> Result<Vec<ArtifactEvidence>> {
    if specification.include.is_empty() {
        return Ok(Vec::new());
    }
    let includes = compile_globs(&specification.include, "include")?;
    let excludes = compile_globs(&specification.exclude, "exclude")?;
    let canonical_repository = fs::canonicalize(&prepared.repository)?;
    let mut artifacts = Vec::new();
    for entry in WalkDir::new(&canonical_repository)
        .follow_links(false)
        .same_file_system(true)
        .into_iter()
    {
        let entry = entry.context("walk repository artifact candidates")?;
        if !entry.file_type().is_file() || entry.file_type().is_symlink() {
            continue;
        }
        let path = entry.path();
        if is_reparse_point(path)? {
            continue;
        }
        let relative = path
            .strip_prefix(&canonical_repository)
            .context("artifact path escaped repository")?;
        let name = slash_path(relative)?;
        if name.split('/').any(|segment| segment == ".git") {
            continue;
        }
        if !includes.is_match(&name) || excludes.is_match(&name) {
            continue;
        }
        let (size_bytes, sha256) = hash_regular_file_no_follow(path)?;
        if size_bytes > MAX_ARTIFACT_BYTES {
            bail!(
                "artifact `{name}` is {size_bytes} bytes; maximum upload size is {MAX_ARTIFACT_BYTES}"
            );
        }
        artifacts.push(ArtifactEvidence {
            id: Uuid::new_v4(),
            name,
            size_bytes,
            sha256,
            path: path.to_owned(),
        });
    }
    artifacts.sort_by(|left, right| left.name.cmp(&right.name));
    write_artifact_manifest(prepared, &artifacts)?;
    Ok(artifacts)
}

fn compile_globs(patterns: &[String], field: &str) -> Result<GlobSet> {
    let mut builder = GlobSetBuilder::new();
    for pattern in patterns {
        if pattern.trim().is_empty()
            || pattern.starts_with(['/', '\\'])
            || pattern.contains(':')
            || pattern.split(['/', '\\']).any(|part| part == "..")
        {
            bail!("artifact {field} pattern must be a safe repository-relative glob");
        }
        builder.add(
            Glob::new(&pattern.replace('\\', "/"))
                .with_context(|| format!("compile artifact {field} glob `{pattern}`"))?,
        );
    }
    builder
        .build()
        .with_context(|| format!("build artifact {field} glob set"))
}

fn slash_path(path: &Path) -> Result<String> {
    let mut output = String::new();
    for component in path.components() {
        let value = component
            .as_os_str()
            .to_str()
            .context("artifact path is not valid UTF-8")?;
        if !output.is_empty() {
            output.push('/');
        }
        output.push_str(value);
    }
    if output.is_empty() {
        bail!("artifact relative path is empty");
    }
    Ok(output)
}

fn hash_regular_file_no_follow(path: &Path) -> Result<(u64, String)> {
    let bytes = read_regular_file_no_follow(path, MAX_ARTIFACT_BYTES)?;
    Ok((bytes.len() as u64, hex::encode(Sha256::digest(bytes))))
}

pub fn read_regular_file_no_follow(path: &Path, max_bytes: u64) -> Result<Vec<u8>> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.file_type().is_file()
        || metadata.file_type().is_symlink()
        || is_reparse_point(path)?
    {
        bail!(
            "artifact is not a regular non-link file: {}",
            path.display()
        );
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        use windows_sys::Win32::Storage::FileSystem::FILE_FLAG_OPEN_REPARSE_POINT;
        options.custom_flags(FILE_FLAG_OPEN_REPARSE_POINT);
    }
    let mut file = options
        .open(path)
        .with_context(|| format!("open artifact without following links {}", path.display()))?;
    let opened_metadata = file.metadata()?;
    #[cfg(windows)]
    let opened_is_reparse = {
        use std::os::windows::fs::MetadataExt;
        use windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT;
        opened_metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
    };
    #[cfg(not(windows))]
    let opened_is_reparse = false;
    if !opened_metadata.is_file() || opened_is_reparse || opened_metadata.len() != metadata.len() {
        bail!(
            "artifact changed while it was being opened: {}",
            path.display()
        );
    }
    if opened_metadata.len() > max_bytes {
        bail!(
            "artifact is {} bytes; maximum readable size is {max_bytes}",
            opened_metadata.len()
        );
    }
    let capacity = usize::try_from(opened_metadata.len()).context("artifact is too large")?;
    let mut bytes = Vec::with_capacity(capacity);
    file.read_to_end(&mut bytes)
        .context("read artifact handle")?;
    if bytes.len() as u64 != opened_metadata.len() {
        bail!("artifact length changed while reading: {}", path.display());
    }
    Ok(bytes)
}

fn write_artifact_manifest(prepared: &PreparedJob, artifacts: &[ArtifactEvidence]) -> Result<()> {
    let path = prepared.artifacts.join("manifest.json");
    let temporary = prepared.artifacts.join("manifest.json.tmp");
    let mut file = File::create(&temporary)?;
    serde_json::to_writer_pretty(&mut file, artifacts)?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    drop(file);
    fs::rename(temporary, path)?;
    Ok(())
}

#[cfg(windows)]
fn is_reparse_point(path: &Path) -> Result<bool> {
    use std::os::windows::fs::MetadataExt;
    use windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT;
    Ok(fs::symlink_metadata(path)?.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0)
}

#[cfg(not(windows))]
fn is_reparse_point(_path: &Path) -> Result<bool> {
    Ok(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::source::SourceEvidence;
    use tempfile::tempdir;

    #[test]
    fn collects_matching_regular_files_and_skips_links() {
        let directory = tempdir().unwrap();
        let repository = directory.path().join("repo");
        let artifacts_dir = directory.path().join("artifacts");
        fs::create_dir(&repository).unwrap();
        fs::create_dir(&artifacts_dir).unwrap();
        fs::write(repository.join("ok.txt"), b"hello").unwrap();
        fs::write(repository.join("skip.bin"), b"bin").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(repository.join("ok.txt"), repository.join("link.txt")).unwrap();
        let prepared = PreparedJob {
            job_id: Uuid::new_v4(),
            run_id: Uuid::new_v4(),
            root: directory.path().to_owned(),
            repository,
            scripts: directory.path().join("scripts"),
            logs: directory.path().join("logs"),
            artifacts: artifacts_dir,
            source: SourceEvidence {
                kind: "git".into(),
                repository: "https://example.invalid/repo".into(),
                requested_revision: "a".repeat(40),
                resolved_revision: "a".repeat(40),
                tree: "b".repeat(40),
                git_version: "git version test".into(),
            },
        };
        let found = collect_artifacts(
            &prepared,
            &ArtifactSpec {
                include: vec!["**/*.txt".into(), "*.txt".into()],
                exclude: vec![],
                retention_days: None,
            },
        )
        .unwrap();
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].name, "ok.txt");
        assert_eq!(found[0].sha256.len(), 64);
    }

    #[test]
    fn rejects_parent_globs() {
        assert!(compile_globs(&["../secret".into()], "include").is_err());
    }
}
