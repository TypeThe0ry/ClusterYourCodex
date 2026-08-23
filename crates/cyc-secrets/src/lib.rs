//! Native credential storage primitives for ClusterYourCodex.
//!
//! Secret material intentionally has no `Debug`, `Display`, `Clone`, or serde
//! implementation. Callers receive only a stable [`CredentialReference`] for
//! persistence in application databases.

use std::fmt;

use serde::{de::Error as _, Deserialize, Deserializer, Serialize, Serializer};
use thiserror::Error;
use zeroize::Zeroize;

#[cfg(windows)]
mod windows;

#[cfg(windows)]
pub use windows::WindowsCredentialVault;

const MAX_KEY_COMPONENT_LEN: usize = 128;

/// Owned secret bytes which are zeroed before their allocation is released.
///
/// This type deliberately does not implement `Debug`, `Display`, `Clone`,
/// `Serialize`, or `Deserialize`.
pub struct Secret(Vec<u8>);

impl Secret {
    /// Takes ownership of a byte allocation without making another plaintext
    /// copy.
    pub fn from_bytes(bytes: Vec<u8>) -> Self {
        Self(bytes)
    }

    /// Takes ownership of a UTF-8 string's allocation. The allocation is
    /// zeroed when this value is dropped.
    pub fn from_string(value: String) -> Self {
        Self(value.into_bytes())
    }

    /// Explicitly exposes the secret to a cryptographic or authentication API.
    #[must_use]
    pub fn expose_secret(&self) -> &[u8] {
        &self.0
    }

    /// Explicitly exposes a UTF-8 secret without allocating another copy.
    pub fn expose_utf8(&self) -> Result<&str, SecretEncodingError> {
        std::str::from_utf8(&self.0).map_err(|_| SecretEncodingError)
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.0.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

impl From<String> for Secret {
    fn from(value: String) -> Self {
        Self::from_string(value)
    }
}

impl Drop for Secret {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

/// Returned when an API requires a UTF-8 secret and the stored bytes are not
/// valid UTF-8. The error never includes the secret material.
#[derive(Debug, Error, Clone, Copy, PartialEq, Eq)]
#[error("secret is not valid UTF-8")]
pub struct SecretEncodingError;

/// Stable, validated identifier used to address a native vault entry.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct CredentialKey {
    namespace: String,
    identifier: String,
}

impl CredentialKey {
    pub fn new(
        namespace: impl Into<String>,
        identifier: impl Into<String>,
    ) -> Result<Self, VaultError> {
        let namespace = namespace.into();
        let identifier = identifier.into();
        validate_component("namespace", &namespace)?;
        validate_component("identifier", &identifier)?;
        Ok(Self {
            namespace,
            identifier,
        })
    }

    #[must_use]
    pub fn namespace(&self) -> &str {
        &self.namespace
    }

    #[must_use]
    pub fn identifier(&self) -> &str {
        &self.identifier
    }

    #[must_use]
    pub fn reference(&self) -> CredentialReference {
        CredentialReference(format!(
            "cyc://credential/{}/{}",
            self.namespace, self.identifier
        ))
    }
}

fn validate_component(field: &'static str, value: &str) -> Result<(), VaultError> {
    if value.is_empty() || value.len() > MAX_KEY_COMPONENT_LEN {
        return Err(VaultError::InvalidKey {
            field,
            reason: format!("length must be between 1 and {MAX_KEY_COMPONENT_LEN} bytes"),
        });
    }
    if !value
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
    {
        return Err(VaultError::InvalidKey {
            field,
            reason: "only ASCII letters, digits, '.', '_', and '-' are allowed".to_owned(),
        });
    }
    Ok(())
}

/// Opaque reference safe to persist in application state and logs.
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct CredentialReference(String);

impl CredentialReference {
    pub fn parse(value: impl Into<String>) -> Result<Self, VaultError> {
        let value = value.into();
        let suffix = value
            .strip_prefix("cyc://credential/")
            .ok_or(VaultError::InvalidReference)?;
        let mut components = suffix.split('/');
        let namespace = components.next().ok_or(VaultError::InvalidReference)?;
        let identifier = components.next().ok_or(VaultError::InvalidReference)?;
        if components.next().is_some() {
            return Err(VaultError::InvalidReference);
        }
        let key =
            CredentialKey::new(namespace, identifier).map_err(|_| VaultError::InvalidReference)?;
        Ok(key.reference())
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl Serialize for CredentialReference {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(&self.0)
    }
}

impl<'de> Deserialize<'de> for CredentialReference {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Self::parse(value).map_err(D::Error::custom)
    }
}

impl fmt::Debug for CredentialReference {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_tuple("CredentialReference")
            .field(&self.0)
            .finish()
    }
}

impl fmt::Display for CredentialReference {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

/// A credential retrieved from the native vault.
///
/// The username is metadata. The password/secret remains wrapped and
/// non-printable.
pub struct StoredCredential {
    pub username: String,
    pub secret: Secret,
}

/// Cross-platform boundary for OS-native credential stores.
pub trait CredentialVault: Send + Sync {
    /// Stores or replaces a credential and returns the only value application
    /// databases should persist.
    fn store(
        &self,
        key: &CredentialKey,
        username: &str,
        secret: &Secret,
    ) -> Result<CredentialReference, VaultError>;

    fn retrieve(&self, key: &CredentialKey) -> Result<Option<StoredCredential>, VaultError>;

    /// Deletes a credential. Returns `false` if no entry existed.
    fn delete(&self, key: &CredentialKey) -> Result<bool, VaultError>;
}

#[derive(Debug, Error)]
pub enum VaultError {
    #[error("invalid credential {field}: {reason}")]
    InvalidKey { field: &'static str, reason: String },
    #[error("credential username contains a NUL character")]
    InvalidUsername,
    #[error("credential reference is invalid")]
    InvalidReference,
    #[error("credential secret is too large for the native vault ({actual} > {maximum} bytes)")]
    SecretTooLarge { actual: usize, maximum: usize },
    #[error("native credential vault returned an invalid record")]
    InvalidNativeRecord,
    #[error("native credential vault is unavailable on this platform")]
    UnsupportedPlatform,
    #[error("native credential vault {operation} failed: {source}")]
    Platform {
        operation: &'static str,
        #[source]
        source: std::io::Error,
    },
}

#[cfg(test)]
mod tests {
    use super::{CredentialKey, Secret};

    #[test]
    fn credential_key_produces_non_secret_reference() {
        let key = CredentialKey::new("ssh-password", "node-01").expect("valid key");
        assert_eq!(
            key.reference().as_str(),
            "cyc://credential/ssh-password/node-01"
        );
    }

    #[test]
    fn credential_reference_deserialization_is_validated() {
        let reference =
            super::CredentialReference::parse("cyc://credential/ssh-password/node-01".to_owned())
                .expect("reference");
        let encoded = serde_json::to_string(&reference).expect("serialize");
        assert_eq!(encoded, "\"cyc://credential/ssh-password/node-01\"");
        assert!(serde_json::from_str::<super::CredentialReference>(
            "\"cyc://credential/ssh-password/../../escape\""
        )
        .is_err());
    }

    #[test]
    fn credential_key_rejects_path_and_control_characters() {
        assert!(CredentialKey::new("ssh-password", "../node").is_err());
        assert!(CredentialKey::new("ssh-password", "node\n2").is_err());
        assert!(CredentialKey::new("ssh/password", "node").is_err());
    }

    #[test]
    fn secret_requires_explicit_exposure() {
        let secret = Secret::from_string("not-logged".to_owned());
        assert_eq!(secret.len(), 10);
        assert_eq!(secret.expose_utf8().expect("utf-8"), "not-logged");
    }
}
