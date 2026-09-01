use std::{ffi::c_void, io, ptr};

use windows_sys::Win32::Foundation::FILETIME;
use windows_sys::Win32::Security::Credentials::{
    CredDeleteW, CredFree, CredReadW, CredWriteW, CREDENTIALW, CRED_MAX_CREDENTIAL_BLOB_SIZE,
    CRED_MAX_USERNAME_LENGTH, CRED_PERSIST_LOCAL_MACHINE, CRED_TYPE_GENERIC,
};
use zeroize::Zeroize;

use crate::{
    CredentialKey, CredentialReference, CredentialVault, Secret, StoredCredential, VaultError,
};

const ERROR_NOT_FOUND: i32 = 1168;

/// Windows Credential Manager implementation using generic credentials scoped
/// to the current Windows logon.
pub struct WindowsCredentialVault {
    target_prefix: String,
}

impl WindowsCredentialVault {
    pub fn new(target_prefix: impl Into<String>) -> Result<Self, VaultError> {
        let target_prefix = target_prefix.into();
        if target_prefix.is_empty() || target_prefix.encode_utf16().any(|unit| unit == 0) {
            return Err(VaultError::InvalidKey {
                field: "target_prefix",
                reason: "must be non-empty and contain no NUL characters".to_owned(),
            });
        }
        Ok(Self { target_prefix })
    }

    fn target(&self, key: &CredentialKey) -> Vec<u16> {
        format!(
            "{}/{}/{}",
            self.target_prefix,
            key.namespace(),
            key.identifier()
        )
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect()
    }
}

impl CredentialVault for WindowsCredentialVault {
    fn store(
        &self,
        key: &CredentialKey,
        username: &str,
        secret: &Secret,
    ) -> Result<CredentialReference, VaultError> {
        if username.encode_utf16().any(|unit| unit == 0) {
            return Err(VaultError::InvalidUsername);
        }
        if secret.len() > CRED_MAX_CREDENTIAL_BLOB_SIZE as usize {
            return Err(VaultError::SecretTooLarge {
                actual: secret.len(),
                maximum: CRED_MAX_CREDENTIAL_BLOB_SIZE as usize,
            });
        }

        let mut target = self.target(key);
        let mut username: Vec<u16> = username.encode_utf16().chain(std::iter::once(0)).collect();

        // CredWriteW copies all buffers before returning. Nothing here is
        // serialized or passed through a process boundary.
        let credential = CREDENTIALW {
            Flags: 0,
            Type: CRED_TYPE_GENERIC,
            TargetName: target.as_mut_ptr(),
            Comment: ptr::null_mut(),
            LastWritten: FILETIME {
                dwLowDateTime: 0,
                dwHighDateTime: 0,
            },
            CredentialBlobSize: secret.len() as u32,
            CredentialBlob: secret.expose_secret().as_ptr().cast_mut(),
            Persist: CRED_PERSIST_LOCAL_MACHINE,
            AttributeCount: 0,
            Attributes: ptr::null_mut(),
            TargetAlias: ptr::null_mut(),
            UserName: username.as_mut_ptr(),
        };

        // SAFETY: all pointers refer to live buffers for the duration of the
        // call and the structure fields follow the Win32 CREDENTIALW contract.
        let written = unsafe { CredWriteW(&credential, 0) };
        if written == 0 {
            return Err(platform_error("write"));
        }
        Ok(key.reference())
    }

    fn retrieve(&self, key: &CredentialKey) -> Result<Option<StoredCredential>, VaultError> {
        let target = self.target(key);
        let mut raw: *mut CREDENTIALW = ptr::null_mut();

        // SAFETY: target is NUL terminated and `raw` is a valid output pointer.
        let read = unsafe { CredReadW(target.as_ptr(), CRED_TYPE_GENERIC, 0, &mut raw) };
        if read == 0 {
            let source = io::Error::last_os_error();
            if source.raw_os_error() == Some(ERROR_NOT_FOUND) {
                return Ok(None);
            }
            return Err(VaultError::Platform {
                operation: "read",
                source,
            });
        }
        // CredReadW reports success through its return value, but a defensive
        // null check keeps the native boundary fail-closed if a malformed API
        // shim ever returns success without an allocation.
        if raw.is_null() {
            return Err(VaultError::InvalidNativeRecord);
        }
        let guard = CredBuffer(raw.cast());

        // SAFETY: CredReadW succeeded and owns a complete CREDENTIALW allocation
        // until `guard` calls CredFree.
        let credential = unsafe { &*raw };
        let blob_size = credential.CredentialBlobSize as usize;
        if blob_size > CRED_MAX_CREDENTIAL_BLOB_SIZE as usize
            || (blob_size > 0 && credential.CredentialBlob.is_null())
        {
            return Err(VaultError::InvalidNativeRecord);
        }
        let secret_bytes = if blob_size == 0 {
            Vec::new()
        } else {
            // SAFETY: the credential blob has exactly CredentialBlobSize bytes.
            unsafe {
                let native_blob =
                    std::slice::from_raw_parts_mut(credential.CredentialBlob, blob_size);
                let copied = native_blob.to_vec();
                native_blob.zeroize();
                copied
            }
        };
        let username = wide_ptr_to_string(credential.UserName)?;
        drop(guard);

        Ok(Some(StoredCredential {
            username,
            secret: Secret::from_bytes(secret_bytes),
        }))
    }

    fn delete(&self, key: &CredentialKey) -> Result<bool, VaultError> {
        let target = self.target(key);
        // SAFETY: target is a valid NUL-terminated UTF-16 string.
        let deleted = unsafe { CredDeleteW(target.as_ptr(), CRED_TYPE_GENERIC, 0) };
        if deleted != 0 {
            return Ok(true);
        }
        let source = io::Error::last_os_error();
        if source.raw_os_error() == Some(ERROR_NOT_FOUND) {
            return Ok(false);
        }
        Err(VaultError::Platform {
            operation: "delete",
            source,
        })
    }
}

struct CredBuffer(*const c_void);

impl Drop for CredBuffer {
    fn drop(&mut self) {
        // SAFETY: CredBuffer is created only from a successful CredReadW call
        // and is dropped exactly once.
        unsafe { CredFree(self.0) };
    }
}

fn platform_error(operation: &'static str) -> VaultError {
    VaultError::Platform {
        operation,
        source: io::Error::last_os_error(),
    }
}

fn wide_ptr_to_string(pointer: *const u16) -> Result<String, VaultError> {
    if pointer.is_null() {
        return Ok(String::new());
    }
    // SAFETY: pointers returned inside CREDENTIALW are NUL-terminated strings
    // whose lifetime is tied to the CredReadW allocation.
    unsafe {
        for len in 0..=CRED_MAX_USERNAME_LENGTH as usize {
            if *pointer.add(len) == 0 {
                return Ok(String::from_utf16_lossy(std::slice::from_raw_parts(
                    pointer, len,
                )));
            }
        }
    }
    Err(VaultError::InvalidNativeRecord)
}

#[cfg(test)]
mod tests {
    use super::WindowsCredentialVault;
    use crate::{CredentialKey, CredentialVault, Secret, VaultError};

    #[test]
    fn windows_credential_manager_round_trip() {
        let vault = WindowsCredentialVault::new("ClusterYourCodex-Test").expect("vault");
        let key =
            CredentialKey::new("test", uuid::Uuid::new_v4().simple().to_string()).expect("key");
        let secret = Secret::from_string("temporary-password".to_owned());

        if let Err(error) = vault.store(&key, "test-user", &secret) {
            // Windows network/batch logons (including SSH and some CI agents)
            // intentionally have no Credential Manager logon set. Compilation
            // still covers the native API; the round trip runs in interactive
            // desktop sessions where production provisioning is hosted.
            if matches!(
                &error,
                VaultError::Platform { source, .. } if source.raw_os_error() == Some(1312)
            ) {
                return;
            }
            panic!("store credential: {error}");
        }
        let recovered = vault
            .retrieve(&key)
            .expect("read credential")
            .expect("credential exists");
        assert_eq!(recovered.username, "test-user");
        assert_eq!(
            recovered.secret.expose_utf8().expect("utf-8"),
            "temporary-password"
        );
        assert!(vault.delete(&key).expect("delete credential"));
        assert!(vault.retrieve(&key).expect("read after delete").is_none());
    }
}
