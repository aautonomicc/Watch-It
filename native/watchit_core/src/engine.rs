//! Autonomi client lifecycle + data-map resolution + decrypted byte streams.
//!
//! One process-wide [`Engine`] owns the ant-core [`Client`]. The client
//! connects lazily on first use (and is retried on later requests if the
//! first attempt failed); resolved root data maps are cached so seeking
//! within a file never re-fetches the map chunks.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Mutex;
use std::time::Duration;

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

/// First `get_range` step of a Range response. A step blocks the response
/// until every chunk under it is fetched, so the opening step stays small
/// (one network chunk) to get first bytes to the player quickly — cold
/// starts on a phone were minutes of blank spinner with an 8 MiB opener.
/// Steps double from here up to [`RANGE_STEP`].
const INITIAL_RANGE_STEP: usize = 1024 * 1024;

/// Chunks fetched from the network since process start (all requests).
pub static FETCHED_CHUNKS: std::sync::atomic::AtomicU64 =
    std::sync::atomic::AtomicU64::new(0);
/// Ciphertext bytes fetched from the network since process start. The UI
/// polls this while buffering to show that data is actually flowing.
pub static FETCHED_BYTES: std::sync::atomic::AtomicU64 =
    std::sync::atomic::AtomicU64::new(0);

/// Concurrent chunk fetches within one decrypt batch.
const FETCH_CONCURRENCY: usize = 8;

/// Hard ceiling on one `Client::connect` attempt (per socket config).
/// The transport's own dial timeouts should finish well inside this; the
/// ceiling exists so a wedged transport can never pin the app in
/// "connecting" forever (the stuck state observed on Android).
const CONNECT_ATTEMPT_TIMEOUT: Duration = Duration::from_secs(60);

pub struct Engine {
    client: OnceCell<Client>,
    peers: Vec<SocketAddr>,
    root_maps: Mutex<HashMap<[u8; 32], DataMap>>,
    last_error: Mutex<Option<String>>,
    attempts: AtomicU32,
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
            attempts: AtomicU32::new(0),
        }
    }

    pub fn last_error(&self) -> Option<String> {
        self.last_error.lock().unwrap().clone()
    }

    /// Connect attempts started so far (both socket configs of one round
    /// count as one attempt).
    pub fn attempts(&self) -> u32 {
        self.attempts.load(Ordering::SeqCst)
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
                let attempt = self.attempts.fetch_add(1, Ordering::SeqCst) + 1;
                tracing::info!(
                    "connecting to Autonomi network (attempt {attempt}, {} bootstrap peers)",
                    self.peers.len()
                );
                // Public peers reject loopback-flavoured handshakes; try the
                // CLI-default dual-stack socket first, fall back to IPv4-only
                // for hosts/carriers with a broken v6 stack.
                let mut config = ClientConfig::default();
                config.allow_loopback = false;
                config.ipv6 = true;
                match connect_bounded(self.peers.clone(), config.clone()).await {
                    Ok(c) => Ok(c),
                    Err(e) => {
                        tracing::warn!("dual-stack connect failed ({e}); retrying IPv4-only");
                        config.ipv6 = false;
                        connect_bounded(self.peers.clone(), config).await
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
                let mut step = INITIAL_RANGE_STEP;
                while pos <= end {
                    let want = std::cmp::min(step as u64, end - pos + 1) as usize;
                    step = (step * 2).min(RANGE_STEP);
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

/// `Client::connect` with the three silent-failure modes converted into
/// ordinary errors so the caller's retry/health machinery sees them:
///
/// * a wedged transport — bounded by [`CONNECT_ATTEMPT_TIMEOUT`];
/// * a panic anywhere in the connect stack — run in its own task so the
///   panic surfaces as a `JoinError` instead of killing the caller (a
///   panicked warm-up task is invisible: no error recorded, health stuck
///   on "connecting" forever);
/// * saorsa-core treating "all bootstrap dials failed" as a successful
///   start with zero peers — useless for streaming, so reported as an
///   error to trigger a fresh round of dials.
async fn connect_bounded(
    peers: Vec<SocketAddr>,
    config: ClientConfig,
) -> Result<Client, ant_core::data::Error> {
    use ant_core::data::Error;
    let net_err = |m: String| Error::Network(m);

    let mut task = tokio::spawn(async move { Client::connect(&peers, config).await });
    let client = match tokio::time::timeout(CONNECT_ATTEMPT_TIMEOUT, &mut task).await {
        Err(_) => {
            task.abort();
            return Err(net_err(format!(
                "connect attempt timed out after {}s",
                CONNECT_ATTEMPT_TIMEOUT.as_secs()
            )));
        }
        Ok(Err(join)) if join.is_panic() => {
            return Err(net_err(format!("connect attempt panicked: {join}")))
        }
        Ok(Err(join)) => return Err(net_err(format!("connect task failed: {join}"))),
        Ok(Ok(Err(e))) => return Err(e),
        Ok(Ok(Ok(c))) => c,
    };

    let peers_up = client.network().connected_peers().await.len();
    if peers_up == 0 {
        return Err(net_err(
            "network stack started but 0 bootstrap peers reachable".to_string(),
        ));
    }
    tracing::info!("connected to Autonomi network ({peers_up} bootstrap peers up)");
    Ok(client)
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
        FETCHED_CHUNKS.fetch_add(1, Ordering::Relaxed);
        FETCHED_BYTES.fetch_add(chunk.content.len() as u64, Ordering::Relaxed);
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
