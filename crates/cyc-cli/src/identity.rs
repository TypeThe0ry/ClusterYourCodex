use std::collections::BTreeSet;
use std::fs;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use rcgen::{CertificateParams, DnType, ExtendedKeyUsagePurpose, IsCa, KeyPair, KeyUsagePurpose};
use rustls::pki_types::{pem::PemObject, CertificateDer, PrivateKeyDer};
use rustls::sign::CertifiedKey;
use sha2::{Digest, Sha256};
use time::{Duration, OffsetDateTime};
use x509_parser::extensions::GeneralName;
use x509_parser::prelude::{FromDer, X509Certificate};
use zeroize::Zeroize;

const CERTIFICATE_FILE: &str = "controller.crt.pem";
const PRIVATE_KEY_FILE: &str = "controller.key.pem";
const MAX_IDENTITY_FILE_BYTES: u64 = 128 * 1024;

pub(crate) fn init(output_dir: &Path, hosts: &[String]) -> Result<serde_json::Value> {
    let hosts = normalize_hosts(hosts)?;
    let certificate_path = output_dir.join(CERTIFICATE_FILE);
    let private_key_path = output_dir.join(PRIVATE_KEY_FILE);
    if super::path_entry_exists(&certificate_path) || super::path_entry_exists(&private_key_path) {
        bail!(
            "identity init requires both output files to be absent; existing identities are verify-only"
        );
    }

    let now = OffsetDateTime::now_utc();
    let mut parameters = CertificateParams::new(hosts.clone())
        .context("validate identity subject alternative names")?;
    parameters.not_before = now - Duration::minutes(5);
    parameters.not_after = now + Duration::days(3_650);
    parameters.is_ca = IsCa::NoCa;
    parameters.key_usages = vec![KeyUsagePurpose::DigitalSignature];
    parameters.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
    parameters.distinguished_name.remove(DnType::CommonName);
    parameters
        .distinguished_name
        .push(DnType::CommonName, hosts[0].clone());

    let key_pair = KeyPair::generate().context("generate ECDSA P-256 identity key")?;
    let certificate = parameters
        .self_signed(&key_pair)
        .context("self-sign controller identity certificate")?;
    let certificate_pem = certificate.pem();
    let mut private_key_pem = key_pair.serialize_pem();

    let write_result = (|| -> Result<()> {
        // Persist the secret first. A crash can leave one protected key file,
        // which a later installer must treat as an explicit incomplete pair;
        // it is never silently rotated or overwritten.
        super::write_secret_file(&private_key_path, private_key_pem.as_bytes())?;
        if let Err(error) = super::write_secret_file(&certificate_path, certificate_pem.as_bytes())
        {
            remove_created_identity_file(&private_key_path);
            return Err(error).context("write controller identity certificate");
        }
        Ok(())
    })();
    private_key_pem.zeroize();
    write_result?;

    match verify(&certificate_path, &private_key_path, &hosts[0]) {
        Ok(metadata) => Ok(metadata),
        Err(error) => {
            remove_created_identity_file(&certificate_path);
            remove_created_identity_file(&private_key_path);
            Err(error).context("verify newly generated controller identity")
        }
    }
}

pub(crate) fn verify(
    certificate_path: &Path,
    private_key_path: &Path,
    expected_host: &str,
) -> Result<serde_json::Value> {
    let expected_host = normalize_host(expected_host)?;
    verify_direct_regular_file(certificate_path, false)?;
    verify_direct_regular_file(private_key_path, true)?;

    let certificate_bytes = read_bounded(certificate_path, "certificate")?;
    let private_key_bytes = read_bounded(private_key_path, "private key")?;
    let certificate_der = parse_single_certificate(&certificate_bytes)?;
    let private_key_der = parse_single_pkcs8_key(&private_key_bytes)?;

    let provider = rustls::crypto::ring::default_provider();
    let certified =
        CertifiedKey::from_der(vec![certificate_der.clone()], private_key_der, &provider)
            .context("certificate and private key do not form a supported matching identity")?;
    certified
        .keys_match()
        .context("certificate public key does not match the private key")?;

    let (remaining, certificate) = X509Certificate::from_der(certificate_der.as_ref())
        .map_err(|error| anyhow::anyhow!("parse certificate DER: {error}"))?;
    if !remaining.is_empty() {
        bail!("certificate DER contains trailing data");
    }
    if certificate.subject() != certificate.issuer() {
        bail!("controller identity certificate must be self-issued");
    }
    certificate
        .verify_signature(None)
        .context("controller identity certificate self-signature is invalid")?;
    if !certificate.validity().is_valid() {
        bail!("controller identity certificate is not currently valid");
    }
    let sans = certificate_sans(&certificate)?;
    if !sans.iter().any(|san| san == &expected_host) {
        bail!("controller identity certificate SAN does not contain the expected host");
    }

    let fingerprint = Sha256::digest(certificate_der.as_ref());
    let certificate_path = absolute_existing_path(certificate_path)?;
    let private_key_path = absolute_existing_path(private_key_path)?;
    Ok(serde_json::json!({
        "apiVersion": "cyc.dev/identity/v1",
        "certificate": certificate_path,
        "privateKey": private_key_path,
        "sha256Fingerprint": hex_lower(&fingerprint),
        "subjectAltNames": sans,
        "notBefore": certificate.validity().not_before.to_datetime().to_string(),
        "notAfter": certificate.validity().not_after.to_datetime().to_string(),
        "valid": true
    }))
}

fn normalize_hosts(hosts: &[String]) -> Result<Vec<String>> {
    if hosts.is_empty() || hosts.len() > 32 {
        bail!("identity init requires between 1 and 32 --host values");
    }
    let mut unique = BTreeSet::new();
    let mut normalized = Vec::new();
    for host in hosts {
        let host = normalize_host(host)?;
        if unique.insert(host.clone()) {
            normalized.push(host);
        }
    }
    Ok(normalized)
}

fn normalize_host(host: &str) -> Result<String> {
    let host = host.trim();
    if host.is_empty()
        || host.len() > 253
        || host.chars().any(char::is_control)
        || host.contains(['/', '\\', ':', '@', '*'])
    {
        // A colon is accepted only as part of an IPv6 literal below.
        if let Ok(ip) = host.parse::<IpAddr>() {
            return Ok(ip.to_string());
        }
        bail!("identity host must be an IP literal or portable DNS hostname");
    }
    if let Ok(ip) = host.parse::<IpAddr>() {
        return Ok(ip.to_string());
    }
    let host = host.trim_end_matches('.').to_ascii_lowercase();
    if host.is_empty()
        || host.split('.').any(|label| {
            label.is_empty()
                || label.len() > 63
                || label.starts_with('-')
                || label.ends_with('-')
                || !label
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        })
    {
        bail!("identity host must be an IP literal or portable DNS hostname");
    }
    Ok(host)
}

fn certificate_sans(certificate: &X509Certificate<'_>) -> Result<Vec<String>> {
    let extension = certificate
        .subject_alternative_name()
        .context("parse certificate subjectAltName extension")?
        .context("controller identity certificate has no subjectAltName extension")?;
    let mut values = BTreeSet::new();
    for name in &extension.value.general_names {
        let value = match name {
            GeneralName::DNSName(name) => normalize_host(name)?,
            GeneralName::IPAddress(bytes) => encoded_ip(bytes)?.to_string(),
            _ => bail!("controller identity certificate contains an unsupported SAN type"),
        };
        values.insert(value);
    }
    if values.is_empty() {
        bail!("controller identity certificate has no usable SAN entries");
    }
    Ok(values.into_iter().collect())
}

fn encoded_ip(bytes: &[u8]) -> Result<IpAddr> {
    match bytes {
        [a, b, c, d] => Ok(Ipv4Addr::new(*a, *b, *c, *d).into()),
        bytes if bytes.len() == 16 => {
            let octets: [u8; 16] = bytes.try_into().expect("length checked");
            Ok(Ipv6Addr::from(octets).into())
        }
        _ => bail!("certificate contains an invalid IP SAN"),
    }
}

fn parse_single_certificate(bytes: &[u8]) -> Result<CertificateDer<'static>> {
    require_single_pem_text(bytes, "CERTIFICATE")?;
    CertificateDer::from_pem_slice(bytes).context("parse certificate PEM")
}

fn parse_single_pkcs8_key(bytes: &[u8]) -> Result<PrivateKeyDer<'static>> {
    require_single_pem_text(bytes, "PRIVATE KEY")?;
    let key = PrivateKeyDer::from_pem_slice(bytes).context("parse private-key PEM")?;
    if !matches!(key, PrivateKeyDer::Pkcs8(_)) {
        bail!("private-key file must contain exactly one unencrypted PKCS#8 PRIVATE KEY PEM item");
    }
    Ok(key)
}

fn require_single_pem_text(bytes: &[u8], label: &str) -> Result<()> {
    let text = std::str::from_utf8(bytes).context("identity PEM is not UTF-8")?;
    let trimmed = text.trim();
    let begin = format!("-----BEGIN {label}-----");
    let end = format!("-----END {label}-----");
    if !trimmed.starts_with(&begin)
        || !trimmed.ends_with(&end)
        || trimmed.matches("-----BEGIN ").count() != 1
        || trimmed.matches("-----END ").count() != 1
        || trimmed.matches(&begin).count() != 1
        || trimmed.matches(&end).count() != 1
    {
        bail!("identity file must contain exactly one {label} PEM item and no surrounding data");
    }
    Ok(())
}

fn read_bounded(path: &Path, label: &str) -> Result<Vec<u8>> {
    let metadata = fs::metadata(path)?;
    if metadata.len() == 0 || metadata.len() > MAX_IDENTITY_FILE_BYTES {
        bail!("{label} file has an invalid bounded size");
    }
    fs::read(path).with_context(|| format!("read {label} file {}", path.display()))
}

fn verify_direct_regular_file(path: &Path, private: bool) -> Result<()> {
    let metadata = fs::symlink_metadata(path)
        .with_context(|| format!("inspect identity file {}", path.display()))?;
    if !metadata.is_file() || metadata.file_type().is_symlink() || metadata_is_reparse(&metadata) {
        bail!(
            "identity input must be a direct regular file: {}",
            path.display()
        );
    }
    if private {
        verify_private_permissions(path, &metadata)?;
    }
    Ok(())
}

#[cfg(unix)]
fn verify_private_permissions(path: &Path, metadata: &fs::Metadata) -> Result<()> {
    use std::os::unix::fs::MetadataExt;

    if metadata.mode() & 0o077 != 0 || metadata.uid() != unsafe { libc::geteuid() } {
        bail!("private key must be owned by the current user with mode 0600 or stricter");
    }
    let parent = path.parent().context("private key must have a parent")?;
    let parent_metadata = fs::symlink_metadata(parent)?;
    if !parent_metadata.is_dir()
        || parent_metadata.file_type().is_symlink()
        || parent_metadata.mode() & 0o077 != 0
        || parent_metadata.uid() != unsafe { libc::geteuid() }
    {
        bail!("private-key parent must be owned by the current user with mode 0700 or stricter");
    }
    Ok(())
}

#[cfg(windows)]
fn verify_private_permissions(path: &Path, _metadata: &fs::Metadata) -> Result<()> {
    super::verify_windows_secret_acl(path).context("private-key DACL is not private")?;
    let parent = path.parent().context("private key must have a parent")?;
    super::verify_windows_secret_acl(parent).context("private-key parent DACL is not private")
}

#[cfg(not(any(unix, windows)))]
fn verify_private_permissions(_path: &Path, _metadata: &fs::Metadata) -> Result<()> {
    bail!("identity private-key permission verification is unsupported on this platform")
}

#[cfg(windows)]
fn metadata_is_reparse(metadata: &fs::Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;
    metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

#[cfg(not(windows))]
fn metadata_is_reparse(_metadata: &fs::Metadata) -> bool {
    false
}

fn absolute_existing_path(path: &Path) -> Result<PathBuf> {
    fs::canonicalize(path).with_context(|| format!("canonicalize identity path {}", path.display()))
}

fn remove_created_identity_file(path: &Path) {
    if let Ok(metadata) = fs::symlink_metadata(path) {
        if metadata.is_file()
            && !metadata.file_type().is_symlink()
            && !metadata_is_reparse(&metadata)
        {
            let _ = fs::remove_file(path);
        }
    }
}

fn hex_lower(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn init_verify_match_san_and_never_replace() {
        let temporary = tempfile::tempdir().unwrap();
        let output = temporary.path().join("private-identity");
        let metadata = init(&output, &["127.0.0.1".to_owned(), "LOCALHOST".to_owned()]).unwrap();
        let certificate = output.join(CERTIFICATE_FILE);
        let private_key = output.join(PRIVATE_KEY_FILE);
        assert!(metadata["valid"].as_bool().unwrap());
        assert_eq!(metadata["sha256Fingerprint"].as_str().unwrap().len(), 64);
        assert!(!metadata.to_string().contains("BEGIN PRIVATE KEY"));
        verify(&certificate, &private_key, "localhost").unwrap();
        assert!(verify(&certificate, &private_key, "192.0.2.1").is_err());
        assert!(init(&output, &["127.0.0.1".to_owned()]).is_err());

        let certificate_pem = fs::read(&certificate).unwrap();
        let mut doubled = certificate_pem.clone();
        doubled.extend_from_slice(&certificate_pem);
        fs::write(&certificate, doubled).unwrap();
        assert!(verify(&certificate, &private_key, "127.0.0.1").is_err());

        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            assert_eq!(fs::metadata(&output).unwrap().mode() & 0o777, 0o700);
            assert_eq!(fs::metadata(&private_key).unwrap().mode() & 0o777, 0o600);
        }
    }

    #[test]
    fn init_rejects_incomplete_preexisting_pair() {
        let temporary = tempfile::tempdir().unwrap();
        let output = temporary.path().join("incomplete");
        fs::create_dir(&output).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&output, fs::Permissions::from_mode(0o700)).unwrap();
        }
        fs::write(output.join(CERTIFICATE_FILE), b"preexisting").unwrap();
        assert!(init(&output, &["127.0.0.1".to_owned()]).is_err());
        assert!(!output.join(PRIVATE_KEY_FILE).exists());
    }
}
