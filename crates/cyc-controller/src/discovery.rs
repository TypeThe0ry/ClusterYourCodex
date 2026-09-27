use std::net::{IpAddr, SocketAddr};

use anyhow::{Context, Result};
use cyc_protocol::{DiscoveryAnnouncementV1, DISCOVERY_PORT, DISCOVERY_QUERY_V1};
use tokio::net::UdpSocket;

/// Answer a credential-free LAN probe. The responder is deliberately
/// metadata-only: it never exposes controller tokens, pairing codes, keys, or
/// database paths. A positive answer only lets the desktop pre-fill a
/// candidate; the normal explicit pairing flow remains mandatory.
pub async fn run_beacon(worker_public_url: Option<String>) -> Result<()> {
    let socket = UdpSocket::bind(SocketAddr::from(([0, 0, 0, 0], DISCOVERY_PORT)))
        .await
        .context("bind CYC LAN discovery beacon")?;
    run_beacon_socket(socket, worker_public_url).await
}

async fn run_beacon_socket(socket: UdpSocket, worker_public_url: Option<String>) -> Result<()> {
    let announcement = serde_json::to_vec(&DiscoveryAnnouncementV1::controller(
        env!("CARGO_PKG_VERSION"),
        worker_public_url,
    ))?;
    let mut buffer = [0_u8; 256];
    loop {
        let (length, peer) = socket.recv_from(&mut buffer).await?;
        if &buffer[..length] != DISCOVERY_QUERY_V1 || !is_private_peer(peer.ip()) {
            continue;
        }
        let _ = socket.send_to(&announcement, peer).await;
    }
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
    use cyc_protocol::DiscoveryAnnouncementV1;

    #[tokio::test]
    async fn answers_private_probe_without_credentials() {
        let socket = UdpSocket::bind(("127.0.0.1", 0)).await.unwrap();
        let address = socket.local_addr().unwrap();
        let task = tokio::spawn(run_beacon_socket(
            socket,
            Some("https://192.168.1.10:47832".to_owned()),
        ));
        let probe = UdpSocket::bind(("127.0.0.1", 0)).await.unwrap();
        probe.send_to(DISCOVERY_QUERY_V1, address).await.unwrap();
        let mut response = [0_u8; 4096];
        let (length, _) = tokio::time::timeout(
            std::time::Duration::from_secs(1),
            probe.recv_from(&mut response),
        )
        .await
        .unwrap()
        .unwrap();
        let announcement: DiscoveryAnnouncementV1 =
            serde_json::from_slice(&response[..length]).unwrap();
        assert!(announcement.validate());
        assert_eq!(
            announcement.worker_public_url.as_deref(),
            Some("https://192.168.1.10:47832")
        );
        assert!(!String::from_utf8_lossy(&response[..length]).contains("token"));
        task.abort();
    }
}
