//! Autonomi client lifecycle + data-map resolution + decrypted byte streams.
//!
//! One process-wide [`Engine`] owns the ant-core [`Client`]. The client
//! connects lazily on first use (and is retried on later requests if the
//! first attempt failed); resolved root data maps are cached so seeking
//! within a file never re-fetches the map chunks.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Mutex;

use ant_core::data::{Client, ClientConfig, DataMap, Error as AntError};
use bytes::Bytes;
use futures::StreamExt;
use tokio::runtime::Handle;
use tokio::sync::{mpsc, OnceCell};
use xor_name::XorName;

/// Production network bootstrap peers, mirrored from
/// WithAutonomi/ant-client resources/bootstrap_peers.toml (rev 629b87f).
/// Overridable at runtime via the FFI `peers` argument.
const DEFAULT_PEERS: &[&str] = &[
    "207.148.94.42:10000",
    "45.77.50.10:10000",
    "66.135.23.83:10000",
    "149.248.9.2:10000",
    "49.12.119.240:10000",
    "5.161.25.133:10000",
    "18.228.202.183:10000",
];

/// Bytes of plaintext requested per `get_range` step while serving a Range
/// response. Network chunks are ≤4 MiB, so 8 MiB keeps per-step overhead
/// (at most one boundary chunk refetched) small without holding much RAM.
const RANGE_STEP: usize = 8 * 1024 * 1024;

/// Concurrent chunk fetches within one decrypt batch.
const FETCH_CONCURRENCY: usize = 8;

pub struct Engine {
    client: OnceCell<Client>,
    peers: Vec<SocketAddr>,
    root_maps: Mutex<HashMap<[u8; 32], DataMap>>,
    last_error: Mutex<Option<String>>,
}

impl Engine {
    pub fn new(peers_override: Option<&str>) -> Self {
        let sources: Vec<String> = match peers_override {
            Some(csv) if !csv.trim().is_empty() => {
                csv.split(',').map(|s| s.trim().to_string()).collect()
            }
            _ => DEFAULT_PEERS.iter().map(|s| s.to_string()).collect(),
        };
        let peers = sources.iter().filter_map(|s| s.parse().ok()).collect();
        Self {
            client: OnceCell::new(),
            peers,
            root_maps: Mutex::new(HashMap::new()),
            last_error: Mutex::new(None),
        }
    }

    pub fn last_error(&self) -> Option<String> {
        self.last_error.lock().unwrap().clone()
    }

    pub fn is_ready(&self) -> bool {
        self.client.initialized()
    }

    /// Connected client, connecting on first call. Concurrent callers share
    /// one attempt; a failed attempt leaves the cell empty so the next
    /// request retries.
    pub async fn client(&self) -> Result<&Client, String> {
        let result = self
            .client
            .get_or_try_init(|| async {
                tracing::info!("connecting to Autonomi network ({} bootstrap peers)", self.peers.len());
                // Public peers reject loopback-flavoured handshakes; try the
                // CLI-default dual-stack socket first, fall back to IPv4-only
                // for hosts/carriers with a broken v6 stack.
                let mut config = ClientConfig::default();
                config.allow_loopback = false;
                config.ipv6 = true;
                match Client::connect(&self.peers, config.clone()).await {
                    Ok(c) => Ok(c),
                    Err(e) => {
                        tracing::warn!("dual-stack connect failed ({e}); retrying IPv4-only");
                        config.ipv6 = false;
                        Client::connect(&self.peers, config).await
                    }
                }
            })
            .await;
        match result {
            Ok(c) => {
                *self.last_error.lock().unwrap() = None;
                Ok(c)
            }
            Err(e) => {
                let msg = e.to_string();
                *self.last_error.lock().unwrap() = Some(msg.clone());
                Err(msg)
            }
        }
    }

    pub async fn connected_peer_count(&self) -> usize {
        match self.client.get() {
            Some(c) => c.network().connected_peers().await.len(),
            None => 0,
        }
    }

    /// Root (non-child) data map for a public file address, cached.
    pub async fn root_map(&'static self, addr: [u8; 32]) -> Result<DataMap, String> {
        if let Some(dm) = self.root_maps.lock().unwrap().get(&addr) {
            return Ok(dm.clone());
        }
        let client = self.client().await?;
        let dm = client
            .data_map_fetch(&addr)
            .await
            .map_err(|e| format!("data map fetch failed: {e}"))?;
        let root = if dm.is_child() {
            let handle = Handle::current();
            tokio::task::spawn_blocking(move || {
                let fetch = |batch: &[(usize, XorName)]| {
                    handle.block_on(fetch_chunk_batch(client, batch))
                };
                self_encryption::get_root_data_map_parallel(dm, &fetch)
            })
            .await
            .map_err(|e| format!("data map resolve task failed: {e}"))?
            .map_err(|e| format!("data map resolve failed: {e}"))?
        } else {
            dm
        };
        self.root_maps.lock().unwrap().insert(addr, root.clone());
        Ok(root)
    }

    /// Stream the whole file as decrypted bytes (constant memory).
    pub fn stream_full(
        &'static self,
        root: DataMap,
    ) -> mpsc::Receiver<Result<Bytes, AntError>> {
        let (tx, rx) = mpsc::channel::<Result<Bytes, AntError>>(8);
        tokio::spawn(async move {
            let client = match self.client().await {
                Ok(c) => c,
                Err(e) => {
                    let _ = tx.send(Err(AntError::Network(e))).await;
                    return;
                }
            };
            let sink = tx.clone();
            if let Err(e) = client.file_download_to_sender(&root, sink, None).await {
                let _ = tx.send(Err(e)).await;
            }
        });
        rx
    }

    /// Stream an inclusive byte range as decrypted bytes, fetched in
    /// [`RANGE_STEP`] slices so seeks start playing quickly and memory
    /// stays bounded.
    pub fn stream_range(
        &'static self,
        root: DataMap,
        start: u64,
        end: u64,
    ) -> mpsc::Receiver<Result<Bytes, String>> {
        let (tx, rx) = mpsc::channel::<Result<Bytes, String>>(4);
        tokio::spawn(async move {
            let client = match self.client().await {
                Ok(c) => c,
                Err(e) => {
                    let _ = tx.send(Err(e)).await;
                    return;
                }
            };
            let handle = Handle::current();
            let blocking = tokio::task::spawn_blocking(move || {
                let fetch = |batch: &[(usize, XorName)]| {
                    handle.block_on(fetch_chunk_batch(client, batch))
                };
                let stream = match self_encryption::streaming_decrypt(&root, fetch) {
                    Ok(s) => s,
                    Err(e) => {
                        let _ = tx.blocking_send(Err(format!("decrypt init failed: {e}")));
                        return;
                    }
                };
                let mut pos = start;
                while pos <= end {
                    let want = std::cmp::min(RANGE_STEP as u64, end - pos + 1) as usize;
                    match stream.get_range(pos as usize, want) {
                        Ok(bytes) => {
                            if bytes.is_empty() {
                                let _ = tx.blocking_send(Err(format!(
                                    "range read returned no data at offset {pos}"
                                )));
                                return;
                            }
                            pos += bytes.len() as u64;
                            if tx.blocking_send(Ok(bytes)).is_err() {
                                return; // player disconnected (normal on seek)
                            }
                        }
                        Err(e) => {
                            let _ = tx.blocking_send(Err(format!("range read failed: {e}")));
                            return;
                        }
                    }
                }
            });
            if let Err(e) = blocking.await {
                tracing::warn!("range stream task panicked: {e}");
            }
        });
        rx
    }
}

/// Bridge self_encryption's synchronous batch-fetch callback to async
/// `chunk_get`, fetching the batch concurrently.
async fn fetch_chunk_batch(
    client: &Client,
    batch: &[(usize, XorName)],
) -> self_encryption::Result<Vec<(usize, Bytes)>> {
    let fetches = batch.iter().map(|&(idx, name)| async move {
        let chunk = client
            .chunk_get(&name.0)
            .await
            .map_err(|e| self_encryption::Error::Generic(format!("chunk fetch failed: {e}")))?
            .ok_or_else(|| {
                self_encryption::Error::Generic(format!(
                    "chunk not found: {}",
                    hex::encode(name.0)
                ))
            })?;
        Ok::<_, self_encryption::Error>((idx, chunk.content))
    });
    let mut results: Vec<(usize, Bytes)> = futures::stream::iter(fetches)
        .buffer_unordered(FETCH_CONCURRENCY)
        .collect::<Vec<_>>()
        .await
        .into_iter()
        .collect::<Result<_, _>>()?;
    // get_root_data_map_parallel pairs results positionally with the input
    // batch, so restore input order.
    results.sort_by_key(|(idx, _)| *idx);
    Ok(results)
}
