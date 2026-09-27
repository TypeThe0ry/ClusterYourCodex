use serde::{Deserialize, Serialize};

/// UDP port used by the LAN discovery handshake. The handshake contains no
/// credentials and is only a hint for the operator; pairing still requires an
/// explicit, short-lived enrollment bundle.
pub const DISCOVERY_PORT: u16 = 47830;
pub const DISCOVERY_QUERY_V1: &[u8] = b"CYC_DISCOVERY_V1\n";
pub const DISCOVERY_API_VERSION: &str = "cyc.dev/discovery/v1";

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DiscoveryAnnouncementV1 {
    pub api_version: String,
    pub service: String,
    pub role: String,
    pub version: String,
    pub worker_public_url: Option<String>,
}

impl DiscoveryAnnouncementV1 {
    pub fn controller(version: impl Into<String>, worker_public_url: Option<String>) -> Self {
        Self {
            api_version: DISCOVERY_API_VERSION.to_owned(),
            service: "clusteryourcodex".to_owned(),
            role: "controller".to_owned(),
            version: version.into(),
            worker_public_url,
        }
    }

    pub fn validate(&self) -> bool {
        self.api_version == DISCOVERY_API_VERSION
            && self.service == "clusteryourcodex"
            && self.role == "controller"
            && !self.version.trim().is_empty()
            && self
                .worker_public_url
                .as_deref()
                .is_none_or(|url| url.starts_with("https://"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn announcement_is_credential_free_and_round_trips() {
        let announcement = DiscoveryAnnouncementV1::controller(
            "0.0.1",
            Some("https://192.168.1.10:47832".to_owned()),
        );
        let encoded = serde_json::to_vec(&announcement).unwrap();
        assert!(!String::from_utf8_lossy(&encoded).contains("token"));
        assert!(serde_json::from_slice::<DiscoveryAnnouncementV1>(&encoded)
            .unwrap()
            .validate());
    }

    #[test]
    fn malformed_announcement_is_rejected() {
        let mut announcement = DiscoveryAnnouncementV1::controller("0.0.1", None);
        announcement.service = "other".to_owned();
        assert!(!announcement.validate());
    }
}
