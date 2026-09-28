use std::collections::BTreeMap;
use std::net::{IpAddr, SocketAddr, UdpSocket};
use std::time::{Duration, Instant};

use cyc_protocol::{DiscoveryAnnouncementV1, DISCOVERY_PORT, DISCOVERY_QUERY_V1};
use serde::Serialize;

const MAX_DATAGRAM_BYTES: usize = 4096;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LanDiscoveryCandidate {
    pub address: String,
    pub port: u16,
    pub announcement: DiscoveryAnnouncementV1,
    pub next_action: &'static str,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LanDiscoveryResult {
    pub api_version: &'static str,
    pub broadcast: bool,
    pub candidates: Vec<LanDiscoveryCandidate>,
    pub pairing_required: bool,
    pub credentials_transmitted: bool,
}

pub fn scan(timeout_ms: u64) -> Result<LanDiscoveryResult, &'static str> {
    scan_targets(
        timeout_ms,
        [SocketAddr::from(([255, 255, 255, 255], DISCOVERY_PORT))],
        true,
    )
}

fn scan_targets<I>(
    timeout_ms: u64,
    targets: I,
    broadcast: bool,
) -> Result<LanDiscoveryResult, &'static str>
where
    I: IntoIterator<Item = SocketAddr>,
{
    if !(100..=30_000).contains(&timeout_ms) {
        return Err("timeout_ms must be between 100 and 30000");
    }

    let socket = UdpSocket::bind(("0.0.0.0", 0)).map_err(|_| "bind discovery socket failed")?;
    socket
        .set_broadcast(true)
        .map_err(|_| "enable discovery broadcast failed")?;
    for target in targets {
        socket
            .send_to(DISCOVERY_QUERY_V1, target)
            .map_err(|_| "send discovery probe failed")?;
    }

    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    let mut buffer = [0_u8; MAX_DATAGRAM_BYTES];
    let mut candidates = BTreeMap::new();
    while let Some(remaining) = deadline.checked_duration_since(Instant::now()) {
        socket
            .set_read_timeout(Some(remaining))
            .map_err(|_| "configure discovery timeout failed")?;
        let Ok((length, peer)) = socket.recv_from(&mut buffer) else {
            break;
        };
        if !is_private_peer(peer.ip()) {
            continue;
        }
        let Ok(announcement) = serde_json::from_slice::<DiscoveryAnnouncementV1>(&buffer[..length])
        else {
            continue;
        };
        if !announcement.validate() {
            continue;
        }
        candidates.insert(
            peer.to_string(),
            LanDiscoveryCandidate {
                address: peer.ip().to_string(),
                port: peer.port(),
                announcement,
                next_action: "verify the SSH host key, then continue explicit install and pairing",
            },
        );
    }

    Ok(LanDiscoveryResult {
        api_version: cyc_protocol::DISCOVERY_API_VERSION,
        broadcast,
        candidates: candidates.into_values().collect(),
        pairing_required: true,
        credentials_transmitted: false,
    })
}

fn is_private_peer(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => ip.is_private() || ip.is_loopback() || ip.is_link_local(),
        IpAddr::V6(ip) => ip.is_loopback() || ip.is_unique_local() || ip.is_unicast_link_local(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;

    #[test]
    fn rejects_out_of_range_timeout() {
        assert!(matches!(
            scan(99),
            Err("timeout_ms must be between 100 and 30000")
        ));
        assert!(matches!(
            scan(30_001),
            Err("timeout_ms must be between 100 and 30000")
        ));
    }

    #[test]
    fn parses_private_controller_announcement_without_credentials() {
        let beacon = UdpSocket::bind(("127.0.0.1", 0)).unwrap();
        let beacon_addr = beacon.local_addr().unwrap();
        thread::spawn(move || {
            let mut query = [0_u8; 64];
            let (length, peer) = beacon.recv_from(&mut query).unwrap();
            assert_eq!(&query[..length], DISCOVERY_QUERY_V1);
            let payload = serde_json::to_vec(&DiscoveryAnnouncementV1::controller(
                "0.0.1",
                Some("https://127.0.0.1:47842".to_owned()),
            ))
            .unwrap();
            beacon.send_to(&payload, peer).unwrap();
        });

        let result = scan_targets(1_000, [beacon_addr], false).unwrap();
        assert_eq!(result.candidates.len(), 1);
        assert_eq!(result.candidates[0].address, "127.0.0.1");
        assert_eq!(result.candidates[0].announcement.version, "0.0.1");
        assert!(!result.credentials_transmitted);
    }
}
