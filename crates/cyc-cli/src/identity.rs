use std::collections::BTreeSet;
use std::fs;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use rcgen::{
    CertificateParams, DnType, ExtendedKeyUsagePurpose, IsCa, KeyPair, KeyUsagePurpose, SanType,
};
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
const MAX_IDENTITY_HOSTS: usize = 32;

#[derive(Clone, Debug, Eq, PartialEq)]
enum CanonicalHost {
    Dns(String),
    Ip(IpAddr),
}

impl CanonicalHost {
    fn safe_string(&self) -> String {
        match self {
            Self::Dns(name) => name.clone(),
            Self::Ip(address) => address.to_string(),
        }
    }

    fn kind_order(&self) -> u8 {
        match self {
            Self::Dns(_) => 0,
            Self::Ip(_) => 1,
        }
    }

    fn to_rcgen_san(&self) -> Result<SanType> {
        match self {
            Self::Dns(name) => Ok(SanType::DnsName(
                name.as_str()
                    .try_into()
                    .context("encode canonical DNS identity SAN")?,
            )),
            Self::Ip(address) => Ok(SanType::IpAddress(*address)),
        }
    }
}

impl Ord for CanonicalHost {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.safe_string()
            .cmp(&other.safe_string())
            .then_with(|| self.kind_order().cmp(&other.kind_order()))
    }
}

impl PartialOrd for CanonicalHost {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

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
    let mut parameters = CertificateParams::default();
    parameters.subject_alt_names = hosts
        .iter()
        .map(CanonicalHost::to_rcgen_san)
        .collect::<Result<Vec<_>>>()?;
    parameters.not_before = now - Duration::minutes(5);
    parameters.not_after = now + Duration::days(3_650);
    parameters.is_ca = IsCa::NoCa;
    parameters.key_usages = vec![KeyUsagePurpose::DigitalSignature];
    parameters.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
    parameters.distinguished_name.remove(DnType::CommonName);
    parameters
        .distinguished_name
        .push(DnType::CommonName, hosts[0].safe_string());

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

    match verify_canonical(&certificate_path, &private_key_path, &hosts) {
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
    expected_hosts: &[String],
) -> Result<serde_json::Value> {
    let expected_hosts = normalize_hosts(expected_hosts)?;
    verify_canonical(certificate_path, private_key_path, &expected_hosts)
}

fn verify_canonical(
    certificate_path: &Path,
    private_key_path: &Path,
    expected_hosts: &[CanonicalHost],
) -> Result<serde_json::Value> {
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
    if sans.as_slice() != expected_hosts {
        bail!("controller identity certificate SAN set does not exactly match expected hosts");
    }

    // The certificate SAN type remains part of the trust decision above. Only a
    // successfully matched typed set is converted to the legacy safe string
    // representation consumed by installers and diagnostics.
    let subject_alt_names = sans
        .iter()
        .map(CanonicalHost::safe_string)
        .collect::<Vec<_>>();

    let fingerprint = Sha256::digest(certificate_der.as_ref());
    let certificate_path = absolute_existing_path(certificate_path)?;
    let private_key_path = absolute_existing_path(private_key_path)?;
    Ok(serde_json::json!({
        "apiVersion": "cyc.dev/identity/v1",
        "certificate": certificate_path,
        "privateKey": private_key_path,
        "sha256Fingerprint": hex_lower(&fingerprint),
        "subjectAltNames": subject_alt_names,
        "notBefore": certificate.validity().not_before.to_datetime().to_string(),
        "notAfter": certificate.validity().not_after.to_datetime().to_string(),
        "valid": true
    }))
}

fn normalize_hosts(hosts: &[String]) -> Result<Vec<CanonicalHost>> {
    if hosts.is_empty() || hosts.len() > MAX_IDENTITY_HOSTS {
        bail!("identity commands require between 1 and 32 --host values");
    }
    let mut unique = BTreeSet::new();
    for host in hosts {
        unique.insert(normalize_host(host)?);
    }
    Ok(unique.into_iter().collect())
}

fn normalize_host(host: &str) -> Result<CanonicalHost> {
    if host.chars().any(char::is_control) {
        bail!("identity host must be an IP literal or portable DNS hostname");
    }
    let host = host.trim_matches(' ');
    if !host.is_ascii() || host.is_empty() {
        bail!("identity host must be an IP literal or portable DNS hostname");
    }
    if let Ok(ip) = host.parse::<IpAddr>() {
        return Ok(CanonicalHost::Ip(ip));
    }

    let dns_name = normalize_dns_name(host)?;
    // A terminal root dot does not let an IP-shaped value masquerade as a DNS
    // identity. This keeps every successfully stringified metadata value
    // unambiguous while certificate dNSName/IPAddress types remain distinct.
    if let Ok(ip) = dns_name.parse::<IpAddr>() {
        return Ok(CanonicalHost::Ip(ip));
    }
    Ok(CanonicalHost::Dns(dns_name))
}

fn normalize_dns_name(name: &str) -> Result<String> {
    if name.chars().any(char::is_control) {
        bail!("identity host must be an IP literal or portable DNS hostname");
    }
    if !name.is_ascii() || name.is_empty() {
        bail!("identity host must be an IP literal or portable DNS hostname");
    }
    let name = match name.strip_suffix('.') {
        Some(without_root_dot) if without_root_dot.ends_with('.') => {
            bail!("identity DNS hostname may contain at most one terminal root dot")
        }
        Some(without_root_dot) => without_root_dot,
        None => name,
    };
    if name.is_empty()
        || name.len() > 253
        || name.split('.').any(|label| {
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
    Ok(name.to_ascii_lowercase())
}

fn certificate_sans(certificate: &X509Certificate<'_>) -> Result<Vec<CanonicalHost>> {
    let extension = certificate
        .subject_alternative_name()
        .context("parse certificate subjectAltName extension")?
        .context("controller identity certificate has no subjectAltName extension")?;
    let mut values = BTreeSet::new();
    for name in &extension.value.general_names {
        let value = match name {
            GeneralName::DNSName(name) => CanonicalHost::Dns(normalize_dns_name(name)?),
            GeneralName::IPAddress(bytes) => CanonicalHost::Ip(encoded_ip(bytes)?),
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

    fn hosts(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_owned()).collect()
    }

    fn safe_strings(values: &[CanonicalHost]) -> Vec<String> {
        values.iter().map(CanonicalHost::safe_string).collect()
    }

    fn dns_san(value: &str) -> SanType {
        SanType::DnsName(value.try_into().unwrap())
    }

    fn write_crafted_identity(
        output: &Path,
        subject_alt_names: Vec<SanType>,
    ) -> (PathBuf, PathBuf) {
        let now = OffsetDateTime::now_utc();
        let mut parameters = CertificateParams::default();
        parameters.subject_alt_names = subject_alt_names;
        parameters.not_before = now - Duration::minutes(5);
        parameters.not_after = now + Duration::days(1);
        parameters.is_ca = IsCa::NoCa;
        parameters.key_usages = vec![KeyUsagePurpose::DigitalSignature];
        parameters.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
        parameters.distinguished_name.remove(DnType::CommonName);
        parameters
            .distinguished_name
            .push(DnType::CommonName, "crafted-identity.test");

        let key_pair = KeyPair::generate().unwrap();
        let certificate_pem = parameters.self_signed(&key_pair).unwrap().pem();
        let mut private_key_pem = key_pair.serialize_pem();
        let certificate_path = output.join(CERTIFICATE_FILE);
        let private_key_path = output.join(PRIVATE_KEY_FILE);
        crate::write_secret_file(&private_key_path, private_key_pem.as_bytes()).unwrap();
        crate::write_secret_file(&certificate_path, certificate_pem.as_bytes()).unwrap();
        private_key_pem.zeroize();
        (certificate_path, private_key_path)
    }

    #[test]
    fn init_verify_exact_san_set_is_order_independent_and_private() {
        let temporary = tempfile::tempdir().unwrap();
        let output = temporary.path().join("private-identity");
        let metadata = init(&output, &hosts(&["LOCALHOST.", "127.0.0.1", "localhost"])).unwrap();
        let certificate = output.join(CERTIFICATE_FILE);
        let private_key = output.join(PRIVATE_KEY_FILE);
        assert!(metadata["valid"].as_bool().unwrap());
        assert_eq!(metadata["sha256Fingerprint"].as_str().unwrap().len(), 64);
        assert_eq!(
            metadata["subjectAltNames"],
            serde_json::json!(["127.0.0.1", "localhost"])
        );

        let serialized = metadata.to_string();
        let private_key_pem = fs::read_to_string(&private_key).unwrap();
        let private_key_payload = private_key_pem
            .lines()
            .find(|line| !line.is_empty() && !line.starts_with("-----"))
            .unwrap();
        assert!(!serialized.contains("BEGIN PRIVATE KEY"));
        assert!(!serialized.contains(private_key_payload));

        verify(
            &certificate,
            &private_key,
            &hosts(&["localhost", "127.0.0.1"]),
        )
        .unwrap();
        verify(
            &certificate,
            &private_key,
            &hosts(&["LOCALHOST", "127.0.0.1", "localhost."]),
        )
        .unwrap();
        assert!(verify(&certificate, &private_key, &hosts(&["localhost"])).is_err());
        assert!(verify(
            &certificate,
            &private_key,
            &hosts(&["127.0.0.1", "localhost", "192.0.2.1"])
        )
        .is_err());
        assert!(init(&output, &hosts(&["127.0.0.1"])).is_err());

        let certificate_pem = fs::read(&certificate).unwrap();
        let mut doubled = certificate_pem.clone();
        doubled.extend_from_slice(&certificate_pem);
        fs::write(&certificate, doubled).unwrap();
        assert!(verify(
            &certificate,
            &private_key,
            &hosts(&["127.0.0.1", "localhost"])
        )
        .is_err());

        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            assert_eq!(fs::metadata(&output).unwrap().mode() & 0o777, 0o700);
            assert_eq!(fs::metadata(&private_key).unwrap().mode() & 0o777, 0o600);
        }
    }

    #[test]
    fn single_host_init_and_verify_remain_compatible() {
        let temporary = tempfile::tempdir().unwrap();
        let output = temporary.path().join("single-host");
        init(&output, &hosts(&["192.0.2.10"])).unwrap();
        verify(
            &output.join(CERTIFICATE_FILE),
            &output.join(PRIVATE_KEY_FILE),
            &hosts(&["192.0.2.10"]),
        )
        .unwrap();
    }

    #[test]
    fn terminal_root_dot_does_not_make_an_ip_literal_a_dns_identity() {
        let temporary = tempfile::tempdir().unwrap();
        let output = temporary.path().join("root-dot-ip-literal");
        let metadata = init(&output, &hosts(&["127.0.0.1."])).unwrap();
        assert_eq!(
            metadata["subjectAltNames"],
            serde_json::json!(["127.0.0.1"])
        );
        verify(
            &output.join(CERTIFICATE_FILE),
            &output.join(PRIVATE_KEY_FILE),
            &hosts(&["127.0.0.1."]),
        )
        .unwrap();
        verify(
            &output.join(CERTIFICATE_FILE),
            &output.join(PRIVATE_KEY_FILE),
            &hosts(&["127.0.0.1"]),
        )
        .unwrap();
    }

    #[test]
    fn crafted_dns_ip_text_collision_is_rejected_for_expected_ip() {
        let temporary = tempfile::tempdir().unwrap();
        let output = temporary.path().join("dns-ip-collision");
        let (certificate, private_key) =
            write_crafted_identity(&output, vec![dns_san("127.0.0.1")]);

        assert!(verify(&certificate, &private_key, &hosts(&["127.0.0.1"])).is_err());
        assert!(verify(&certificate, &private_key, &hosts(&["127.0.0.1."])).is_err());
    }

    #[test]
    fn crafted_dns_and_ip_same_text_extra_is_rejected() {
        let temporary = tempfile::tempdir().unwrap();
        let output = temporary.path().join("dns-and-ip-extra");
        let (certificate, private_key) = write_crafted_identity(
            &output,
            vec![
                dns_san("127.0.0.1"),
                SanType::IpAddress("127.0.0.1".parse().unwrap()),
            ],
        );

        assert!(verify(&certificate, &private_key, &hosts(&["127.0.0.1"])).is_err());
        assert!(verify(&certificate, &private_key, &hosts(&["127.0.0.1."])).is_err());
    }

    #[test]
    fn crafted_invalid_and_unsupported_san_types_are_rejected() {
        let temporary = tempfile::tempdir().unwrap();
        for (case, dns_name) in [
            ("multiple-root-dots", "example.test.."),
            ("wildcard", "*.example.test"),
            ("control", "example.test\n"),
            ("leading-ascii-space", " example.test"),
            ("trailing-ascii-space", "example.test "),
            ("surrounding-ascii-spaces", " example.test "),
        ] {
            let output = temporary.path().join(case);
            let (certificate, private_key) =
                write_crafted_identity(&output, vec![dns_san(dns_name)]);
            assert!(
                verify(&certificate, &private_key, &hosts(&["example.test"])).is_err(),
                "crafted {case} dNSName unexpectedly verified"
            );
        }

        let output = temporary.path().join("unsupported-uri");
        let (certificate, private_key) = write_crafted_identity(
            &output,
            vec![SanType::URI(
                "https://example.test/identity".try_into().unwrap(),
            )],
        );
        assert!(verify(&certificate, &private_key, &hosts(&["example.test"])).is_err());
    }

    #[test]
    fn host_normalization_rejects_invalid_wildcard_control_and_out_of_bounds_sets() {
        assert!(normalize_hosts(&[]).is_err());
        for invalid in [
            "",
            "*",
            "*.example.test",
            "bad/name",
            "bad\\name",
            "bad@example.test",
            "example.test\n",
            "example\u{0000}.test",
            "example.test..",
            "example.test...",
            "\u{00a0}example.test",
            "example.test\u{2003}",
            "ｅxample.test",
        ] {
            assert!(
                normalize_hosts(&hosts(&[invalid])).is_err(),
                "unexpected valid host: {invalid:?}"
            );
        }

        assert_eq!(
            safe_strings(
                &normalize_hosts(&hosts(&[" LOCALHOST. ", "localhost", "192.0.2.10"])).unwrap()
            ),
            hosts(&["192.0.2.10", "localhost"])
        );

        let maximum_dns_name = format!(
            "{}.{}.{}.{}",
            "a".repeat(63),
            "b".repeat(63),
            "c".repeat(63),
            "d".repeat(61)
        );
        assert_eq!(maximum_dns_name.len(), 253);
        assert_eq!(
            normalize_host(&format!("{maximum_dns_name}.")).unwrap(),
            CanonicalHost::Dns(maximum_dns_name.clone())
        );
        let too_long_dns_name = format!("{maximum_dns_name}e");
        assert_eq!(too_long_dns_name.len(), 254);
        assert!(normalize_host(&format!("{too_long_dns_name}.")).is_err());

        let thirty_two = (0..MAX_IDENTITY_HOSTS)
            .map(|index| format!("host-{index}.example.test"))
            .collect::<Vec<_>>();
        assert_eq!(normalize_hosts(&thirty_two).unwrap().len(), 32);

        let thirty_three = (0..=MAX_IDENTITY_HOSTS)
            .map(|index| format!("host-{index}.example.test"))
            .collect::<Vec<_>>();
        assert!(normalize_hosts(&thirty_three).is_err());
    }

    #[test]
    fn init_and_verify_enforce_32_host_bound() {
        let temporary = tempfile::tempdir().unwrap();
        let output = temporary.path().join("thirty-two-hosts");
        let thirty_two = (0..MAX_IDENTITY_HOSTS)
            .map(|index| format!("host-{index}.example.test"))
            .collect::<Vec<_>>();
        let metadata = init(&output, &thirty_two).unwrap();
        assert_eq!(metadata["subjectAltNames"].as_array().unwrap().len(), 32);

        let mut reordered = thirty_two.clone();
        reordered.reverse();
        verify(
            &output.join(CERTIFICATE_FILE),
            &output.join(PRIVATE_KEY_FILE),
            &reordered,
        )
        .unwrap();

        let mut thirty_three = thirty_two;
        thirty_three.push("overflow.example.test".to_owned());
        assert!(verify(
            &output.join(CERTIFICATE_FILE),
            &output.join(PRIVATE_KEY_FILE),
            &thirty_three,
        )
        .is_err());
        assert!(init(&temporary.path().join("too-many"), &thirty_three).is_err());
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
        assert!(init(&output, &hosts(&["127.0.0.1"])).is_err());
        assert!(!output.join(PRIVATE_KEY_FILE).exists());
    }
}
