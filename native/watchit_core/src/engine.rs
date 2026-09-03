//! Autonomi client lifecycle + data-map resolution + decrypted byte streams.
//!
//! One process-wide [`Engine`] owns the ant-core [`Client`]. The client
//! connects lazily on first use (and is retried on later requests if the
//! first attempt failed); resolved root data maps are cached so seeking
//! within a file never re-fetches the map chunks.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, LazyLock, Mutex, RwLock};
use std::time::Duration;

use ant_core::data::{Client, ClientConfig, DataMap, Error as AntError};
use ant_core::data::{EvmNetwork, Wallet as EvmWallet};
use bytes::Bytes;
use futures::StreamExt;
use tokio::runtime::Handle;
use tokio::sync::{mpsc, watch, Mutex as AsyncMutex, Notify};
use xor_name::XorName;

use crate::cache::{ChunkCache, Lookup};
use crate::mapstore::MapStore;

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

/// Chunk fetches answered from the RAM cache since process start.
pub static CACHE_HIT_CHUNKS: std::sync::atomic::AtomicU64 =
    std::sync::atomic::AtomicU64::new(0);

/// Concurrent chunk fetches within one decrypt batch. Chunks are ≤4 MiB,
/// so 16 in flight bounds transient buffering at ~64 MiB. (The no-Range
/// full-file path in `stream_full` is sized separately by ant-core's
/// adaptive controller and does not read this.)
const FETCH_CONCURRENCY: usize = 16;

/// Smallest prefetch window: what a fresh range request starts with.
/// Network chunks are ≤4 MiB, so this is ~4 MiB. Traffic captures
/// (2026-09-03) showed every track/episode start or seek pulling the
/// whole window whether or not it was watched (~98% of the app's data
/// usage, back when the window was a fixed 16 chunks), so starts — and
/// seeks, which open a new request — must be cheap.
const PREFETCH_AHEAD_MIN_CHUNKS: usize = 1;

/// Largest prefetch window a long-playing stream grows into (~32 MiB ≈
/// 30–35 s of typical 1080p at 7–8 Mbps): a stream that has played for
/// minutes is actually being watched and earns a bigger cushion against
/// chunk-fetch stalls. The player's own demuxer buffer (Settings →
/// Buffer size) sits in front of the window and provides further
/// headroom.
const PREFETCH_AHEAD_MAX_CHUNKS: usize = 8;

/// The prefetch window grows by one chunk per this much serving time on
/// one range request, [`PREFETCH_AHEAD_MIN_CHUNKS`] →
/// [`PREFETCH_AHEAD_MAX_CHUNKS`] (reached after ~3.5 min of playback).
const PREFETCH_GROW_INTERVAL: Duration = Duration::from_secs(30);

/// Chunks to keep warm ahead of the served position after `played` of
/// serving on the current range request.
fn adaptive_prefetch_ahead(played: Duration) -> usize {
    let steps = (played.as_secs() / PREFETCH_GROW_INTERVAL.as_secs()) as usize;
    PREFETCH_AHEAD_MIN_CHUNKS
        .saturating_add(steps)
        .min(PREFETCH_AHEAD_MAX_CHUNKS)
}

/// Concurrent chunk fetches used by the prefetcher — kept below
/// [`FETCH_CONCURRENCY`] so a foreground batch the player is blocked on
/// is never starved of connections by background prefetch.
const PREFETCH_CONCURRENCY: usize = 4;

/// All chunk traffic (serving and prefetch) goes through this cache, so a
/// chunk is downloaded at most once while resident and prefetched chunks
/// are ready when the serving path asks for them.
static CHUNK_CACHE: LazyLock<ChunkCache> = LazyLock::new(ChunkCache::new);

/// Bytes currently resident in the chunk cache (for `/health`).
pub fn cache_resident_bytes() -> usize {
    CHUNK_CACHE.resident_bytes()
}

/// Hard ceiling on one `Client::connect` attempt (per socket config).
/// The transport's own dial timeouts should finish well inside this; the
/// ceiling exists so a wedged transport can never pin the app in
/// "connecting" forever (the stuck state observed on Android).
const CONNECT_ATTEMPT_TIMEOUT: Duration = Duration::from_secs(60);

/// How often the supervisor samples the connected-peer count while a
/// client is installed.
const SUPERVISE_POLL: Duration = Duration::from_secs(10);

/// Consecutive zero-peer samples before the supervisor declares the
/// client dead and re-dials (~20s — rides out transient blips without
/// tearing down a connection that is about to recover).
const OFFLINE_POLLS_BEFORE_RECONNECT: u32 = 2;

pub struct Engine {
    /// The live client, replaceable: the supervisor evicts it when its
    /// peers are all gone (cable pull, phone sleep) so the connect
    /// machinery runs again. Streams in flight keep their own `Arc` and
    /// die on their next fetch — their error paths already handle that.
    client: RwLock<Option<Arc<Client>>>,
    /// Serializes connect attempts so concurrent callers share one dial
    /// round instead of racing the bootstrap peers.
    connect_gate: AsyncMutex<()>,
    /// `POST /reconnect` pings this to cut short the supervisor's backoff
    /// sleep / next poll (cable replug and phone wake feel instant).
    kick: Notify,
    /// User-facing network pause (`POST /network/pause`): while set, no
    /// client is dialled, `client()` refuses, and in-flight range streams
    /// stop at their next step — the app goes network-silent until the
    /// user unpauses. `Arc` so streams/prefetchers spawned before a pause
    /// observe it without holding `&'static self`.
    paused: Arc<AtomicBool>,
    peers: Vec<SocketAddr>,
    root_maps: Mutex<HashMap<[u8; 32], DataMap>>,
    /// On-disk root-map cache; `None` when no data dir is available
    /// (devserver/tests) — resolution then stays memory-only as before.
    map_store: Option<MapStore>,
    last_error: Mutex<Option<String>>,
    attempts: AtomicU32,
    /// Upload-wallet key storage; the key is attached to every client the
    /// connect path builds (ant-core wallets are set at construct time).
    pub wallet: crate::wallet::WalletStore,
    /// Publish upload jobs (`POST /upload` → poll `GET /upload/{id}`).
    pub uploads: crate::upload::UploadManager,
    /// My W@tch device linking (x0x agent; test implementation).
    pub mywatch: crate::mywatch::MyWatchStore,
    /// Channels: public signed manifests + gossiped heads (x0x agent of
    /// its own, independent lifecycle from the My W@tch link).
    pub channels: crate::channels::ChannelStore,
}

impl Engine {
    pub fn new(peers_override: Option<&str>, data_dir: Option<&str>) -> Self {
        let sources: Vec<String> = match peers_override {
            Some(csv) if !csv.trim().is_empty() => {
                csv.split(',').map(|s| s.trim().to_string()).collect()
            }
            _ => DEFAULT_PEERS.iter().map(|s| s.to_string()).collect(),
        };
        let peers = sources.iter().filter_map(|s| s.parse().ok()).collect();
        let map_store = data_dir
            .filter(|d| !d.trim().is_empty())
            .and_then(|d| match MapStore::open_in_dir(std::path::Path::new(d)) {
                Ok(store) => {
                    tracing::info!(
                        "root-map store open ({} cached maps)",
                        store.len()
                    );
                    Some(store)
                }
                Err(e) => {
                    tracing::warn!("root-map store unavailable: {e}");
                    None
                }
            });
        Self {
            client: RwLock::new(None),
            connect_gate: AsyncMutex::new(()),
            kick: Notify::new(),
            paused: Arc::new(AtomicBool::new(false)),
            peers,
            root_maps: Mutex::new(HashMap::new()),
            map_store,
            last_error: Mutex::new(None),
            attempts: AtomicU32::new(0),
            wallet: crate::wallet::WalletStore::new(data_dir, true),
            uploads: crate::upload::UploadManager::default(),
            mywatch: crate::mywatch::MyWatchStore::new(data_dir),
            channels: crate::channels::ChannelStore::new(data_dir),
        }
    }

    /// Root maps persisted on disk (for `/health`).
    pub fn stored_maps(&self) -> usize {
        self.map_store.as_ref().map_or(0, MapStore::len)
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
        self.client.read().unwrap().is_some()
    }

    /// Whether the user has paused all network use.
    pub fn paused(&self) -> bool {
        self.paused.load(Ordering::SeqCst)
    }

    /// Pause or resume all network use. Pausing evicts the installed
    /// client (streams end at their next fetch step, the supervisor
    /// parks instead of re-dialling); resuming kicks the supervisor so a
    /// fresh dial starts immediately.
    pub fn set_paused(&self, paused: bool) {
        self.paused.store(paused, Ordering::SeqCst);
        if paused {
            self.evict();
        }
        // Both directions: wake the supervisor so it re-checks the flag
        // now (drop its client Arc and park, or start dialling).
        self.kick_reconnect();
    }

    /// The client currently installed, without connecting.
    fn current(&self) -> Option<Arc<Client>> {
        self.client.read().unwrap().clone()
    }

    /// Drop the installed client so the next request (or supervisor
    /// round) dials afresh. Streams holding their own `Arc` clones just
    /// drain it; nothing else to do.
    fn evict(&self) {
        *self.client.write().unwrap() = None;
    }

    /// Connected client, dialling if none is installed. Concurrent
    /// callers queue on one gate, and whoever wins installs the client
    /// for the rest; a failed attempt leaves the slot empty so the next
    /// request retries.
    pub async fn client(&self) -> Result<Arc<Client>, String> {
        if self.paused() {
            return Err("network is paused — resume it in Settings".to_string());
        }
        if let Some(c) = self.current() {
            return Ok(c);
        }
        let _gate = self.connect_gate.lock().await;
        // A caller queued on the gate finds the winner's client here.
        if let Some(c) = self.current() {
            return Ok(c);
        }
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
        let result = match connect_bounded(self.peers.clone(), config.clone()).await {
            Ok(c) => Ok(c),
            Err(e) => {
                tracing::warn!("dual-stack connect failed ({e}); retrying IPv4-only");
                config.ipv6 = false;
                connect_bounded(self.peers.clone(), config).await
            }
        };
        match result {
            Ok(c) => {
                // A pause that landed while this dial was in flight must
                // win — installing the client would leave it connected
                // (and chattering) behind a "paused" health state.
                if self.paused() {
                    return Err(
                        "network is paused — resume it in Settings".to_string()
                    );
                }
                let c = Arc::new(self.attach_wallet(c));
                *self.client.write().unwrap() = Some(c.clone());
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

    /// Attach the stored upload wallet, if any. Wallets are builder-set
    /// (`with_wallet` consumes the client), so this runs on every fresh
    /// connect; a bad stored key degrades to a wallet-less client rather
    /// than blocking streaming.
    fn attach_wallet(&self, client: Client) -> Client {
        let Some((key, _)) = self.wallet.load() else {
            return client;
        };
        match EvmWallet::new_from_private_key(EvmNetwork::ArbitrumOne, &key) {
            Ok(w) => {
                tracing::info!("upload wallet attached ({})", w.address());
                client.with_wallet(w)
            }
            Err(e) => {
                tracing::warn!("stored wallet key unusable, continuing without: {e:?}");
                client
            }
        }
    }

    /// Wallet config changed (import/remove): drop the installed client
    /// and re-dial so the connect path rebuilds it with the new wallet
    /// state. Active streams end on their next fetch — acceptable, the
    /// user is in the wallet settings, not mid-movie (and the supervisor
    /// reconnects within seconds).
    pub fn reconnect_for_wallet(&self) {
        self.evict();
        self.kick_reconnect();
    }

    pub async fn connected_peer_count(&self) -> usize {
        match self.current() {
            Some(c) => c.network().connected_peers().await.len(),
            None => 0,
        }
    }

    /// Cut short the supervisor's current backoff sleep / poll interval
    /// so an externally observed network recovery (cable replug, phone
    /// wake) is acted on immediately instead of on the next timer tick.
    /// Harmless while healthy: the supervisor just re-samples the peer
    /// count and carries on.
    pub fn kick_reconnect(&self) {
        self.kick.notify_one();
    }

    /// Keep the engine connected, forever: dial until a client is up
    /// (2s→60s backoff, restarted per round), then watch its peer count
    /// and evict it once the network is gone ([`SUPERVISE_POLL`] ×
    /// [`OFFLINE_POLLS_BEFORE_RECONNECT`], or one poll after a kick) —
    /// `/health` then reports `connecting` again and the UI's offline
    /// machinery takes over while this loop re-dials. saorsa-core never
    /// re-dials bootstrap peers on its own, so without this a network
    /// drop left a "ready" client with zero peers forever.
    pub async fn supervise(&'static self) {
        let mut delay = Duration::from_secs(2);
        loop {
            // Paused: park until the next kick (set_paused kicks on both
            // edges), never dialling. Backoff restarts fresh on resume.
            if self.paused() {
                self.kick.notified().await;
                delay = Duration::from_secs(2);
                continue;
            }
            let client = match self.client().await {
                Ok(c) => c,
                Err(e) => {
                    tracing::warn!("connect failed, retrying in {delay:?}: {e}");
                    tokio::select! {
                        _ = tokio::time::sleep(delay) => {}
                        _ = self.kick.notified() => {
                            tracing::info!("reconnect kick — retrying now");
                        }
                    }
                    delay = (delay * 2).min(Duration::from_secs(60));
                    continue;
                }
            };
            delay = Duration::from_secs(2);
            let mut zero_polls = 0u32;
            loop {
                let kicked = tokio::select! {
                    _ = tokio::time::sleep(SUPERVISE_POLL) => false,
                    _ = self.kick.notified() => true,
                };
                // A pause must drop this loop's own client Arc too, or
                // the evicted client would be kept alive (and its network
                // chatter running) by the supervisor itself. Evict again
                // here: a dial that was in flight when the pause landed
                // could have installed a client after set_paused's evict.
                if self.paused() {
                    tracing::info!("network paused — disconnecting");
                    self.evict();
                    break;
                }
                let peers = client.network().connected_peers().await.len();
                if peers > 0 {
                    zero_polls = 0;
                    continue;
                }
                zero_polls += 1;
                // A kick is outside knowledge that the network changed:
                // skip the second confirming poll and re-dial now.
                if kicked || zero_polls >= OFFLINE_POLLS_BEFORE_RECONNECT {
                    tracing::warn!(
                        "connection lost (0 peers, {zero_polls} polls{}) — re-dialling",
                        if kicked { ", kicked" } else { "" }
                    );
                    *self.last_error.lock().unwrap() =
                        Some("connection lost — reconnecting".to_string());
                    self.evict();
                    break;
                }
            }
        }
    }

    /// Root map held locally (memory or disk). The only way a map exists
    /// at all — since the datamap-first model, maps arrive exclusively via
    /// import (`POST /datamap`, bundle members, the seeded demo asset);
    /// there is no network fetch path.
    pub fn stored_root_map(&self, addr: &[u8; 32]) -> Option<DataMap> {
        if let Some(dm) = self.root_maps.lock().unwrap().get(addr) {
            return Some(dm.clone());
        }
        let dm = self.map_store.as_ref().and_then(|s| s.get(addr))?;
        self.root_maps.lock().unwrap().insert(*addr, dm.clone());
        Some(dm)
    }

    /// Verify an externally supplied root map (bundle import) fully
    /// offline and store it in the memory + disk caches. A map that fails
    /// verification is rejected so a tampered bundle cannot poison the
    /// cache — the caller skips that entry and reports it.
    pub fn import_root_map(&self, addr: [u8; 32], root: DataMap) -> Result<(), String> {
        crate::verify::verify_root_map(&addr, &root)?;
        self.store_root_map(addr, &root);
        Ok(())
    }

    /// Store a root map under an address the caller just *derived* from
    /// the map itself (`verify::derive_address`) — consistency holds by
    /// construction, so no verification round. The `.datamap` import path.
    pub fn store_root_map(&self, addr: [u8; 32], root: &DataMap) {
        self.root_maps.lock().unwrap().insert(addr, root.clone());
        if let Some(store) = &self.map_store {
            store.put(&addr, root);
        }
    }

    /// Expand a shrunk (child) data map back to its root over the
    /// network: fetch the wrapper chunks the upload stored (through the
    /// chunk cache) and unwrap level by level — exactly reversing the
    /// shrink the uploader ran. In practice one level of ≤3 small chunks,
    /// and only ever needed once per map (the root is stored after).
    pub async fn expand_child_map(
        &'static self,
        map: DataMap,
    ) -> Result<DataMap, String> {
        let client = self.client().await?;
        let handle = Handle::current();
        let task = tokio::task::spawn_blocking(move || {
            let mut fetch = |name: XorName| {
                handle
                    .block_on(cached_chunk_get(&client, name))
                    .map_err(self_encryption::Error::Generic)
            };
            self_encryption::get_root_data_map(map, &mut fetch)
                .map_err(|e| format!("wrapper chunk fetch failed: {e}"))
        });
        task.await.map_err(|e| format!("expand task failed: {e}"))?
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
    /// stays bounded. A background prefetcher keeps an adaptive window of
    /// chunks ([`adaptive_prefetch_ahead`]) warm ahead of the served
    /// position so one slow chunk batch stalls prefetch, not the player.
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
            // The serving loop reports the last byte handed to the player;
            // the prefetcher follows. Dropping the sender (loop returns for
            // any reason) shuts the prefetcher down.
            let (pos_tx, pos_rx) = watch::channel(start);
            let paused = self.paused.clone();
            tokio::spawn(prefetch_ahead(
                client.clone(),
                chunk_offsets(&root),
                pos_rx,
                end,
                paused.clone(),
            ));
            let handle = Handle::current();
            let blocking = tokio::task::spawn_blocking(move || {
                let fetch = |batch: &[(usize, XorName)]| {
                    handle.block_on(fetch_chunk_batch(&client, batch))
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
                    // A pause ends the stream at the next step so this
                    // task's client Arc drops instead of fetching on
                    // against the user's wishes (the player surfaces the
                    // error; already-buffered video keeps playing).
                    if paused.load(Ordering::SeqCst) {
                        let _ = tx.blocking_send(Err(
                            "network is paused — resume it in Settings".to_string(),
                        ));
                        return;
                    }
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
                            let _ = pos_tx.send(pos);
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
/// chunk fetches through the cache, fetching the batch concurrently.
async fn fetch_chunk_batch(
    client: &Client,
    batch: &[(usize, XorName)],
) -> self_encryption::Result<Vec<(usize, Bytes)>> {
    let fetches = batch.iter().map(|&(idx, name)| async move {
        let bytes = cached_chunk_get(client, name)
            .await
            .map_err(self_encryption::Error::Generic)?;
        Ok::<_, self_encryption::Error>((idx, bytes))
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

/// Releases a claimed fetch if the owning future is dropped before
/// completion (task cancellation), so waiters never poll a dead claim.
struct FetchClaim {
    name: [u8; 32],
    done: bool,
}

impl Drop for FetchClaim {
    fn drop(&mut self) {
        if !self.done {
            CHUNK_CACHE.complete(self.name, None);
        }
    }
}

/// Chunk fetch through the process-wide cache. Single-flight: the first
/// caller downloads, concurrent callers for the same chunk poll the cache
/// until it lands (chunk downloads take hundreds of ms to seconds, so a
/// 50 ms poll adds nothing measurable and avoids the lost-wakeup hazards
/// of a notification handoff).
async fn cached_chunk_get(client: &Client, name: XorName) -> Result<Bytes, String> {
    loop {
        match CHUNK_CACHE.lookup(&name.0) {
            Lookup::Hit(bytes) => {
                CACHE_HIT_CHUNKS.fetch_add(1, Ordering::Relaxed);
                return Ok(bytes);
            }
            Lookup::InFlight => tokio::time::sleep(Duration::from_millis(50)).await,
            Lookup::Fetch => {
                let mut claim = FetchClaim { name: name.0, done: false };
                let result = client.chunk_get(&name.0).await;
                claim.done = true;
                return match result {
                    Ok(Some(chunk)) => {
                        FETCHED_CHUNKS.fetch_add(1, Ordering::Relaxed);
                        FETCHED_BYTES.fetch_add(chunk.content.len() as u64, Ordering::Relaxed);
                        CHUNK_CACHE.complete(name.0, Some(chunk.content.clone()));
                        Ok(chunk.content)
                    }
                    Ok(None) => {
                        CHUNK_CACHE.complete(name.0, None);
                        Err(format!("chunk not found: {}", hex::encode(name.0)))
                    }
                    Err(e) => {
                        CHUNK_CACHE.complete(name.0, None);
                        Err(format!("chunk fetch failed: {e}"))
                    }
                };
            }
        }
    }
}

/// Chunks of a root data map as `(first plaintext byte, network address)`
/// in file order — the map self_encryption's `get_range` uses to pick
/// chunks, rebuilt here so the prefetcher can address them directly.
fn chunk_offsets(root: &DataMap) -> Vec<(u64, XorName)> {
    let mut infos: Vec<_> = root
        .infos()
        .iter()
        .map(|i| (i.index, i.src_size as u64, i.dst_hash))
        .collect();
    infos.sort_by_key(|&(index, _, _)| index);
    let mut offset = 0u64;
    infos
        .into_iter()
        .map(|(_, src_size, name)| {
            let start = offset;
            offset += src_size;
            (start, name)
        })
        .collect()
}

/// Keep an adaptive window of chunks ([`adaptive_prefetch_ahead`] — small
/// at request start, growing the longer the stream plays) warm ahead of
/// the last byte the serving loop has handed to the player, so each
/// serving step finds its chunks already in RAM instead of blocking the
/// stream on the network. Exits when the serving side drops its position
/// sender (stream done or player disconnected).
async fn prefetch_ahead(
    client: Arc<Client>,
    chunks: Vec<(u64, XorName)>,
    mut pos: watch::Receiver<u64>,
    end: u64,
    paused: Arc<AtomicBool>,
) {
    // Last chunk this request can ever need.
    let Some(last) = chunks.iter().rposition(|&(start, _)| start <= end) else {
        return;
    };
    let started = std::time::Instant::now();
    loop {
        // A network pause ends prefetch outright (dropping this task's
        // client Arc); the serving loop is winding down the same way.
        if paused.load(Ordering::SeqCst) {
            return;
        }
        let served = *pos.borrow_and_update();
        let current = chunks
            .partition_point(|&(start, _)| start <= served)
            .saturating_sub(1);
        let target = (current + adaptive_prefetch_ahead(started.elapsed())).min(last);
        let wanted: Vec<XorName> = chunks[current..=target]
            .iter()
            .filter(|(_, name)| !CHUNK_CACHE.contains(&name.0))
            .map(|&(_, name)| name)
            .collect();
        if wanted.is_empty() {
            // Window is warm; sleep until playback advances. Err means the
            // serving side is gone.
            if pos.changed().await.is_err() {
                return;
            }
            continue;
        }
        let results = futures::stream::iter(
            wanted.into_iter().map(|name| cached_chunk_get(&client, name)),
        )
        .buffer_unordered(PREFETCH_CONCURRENCY)
        .collect::<Vec<_>>()
        .await;
        if let Some(Err(e)) = results.iter().find(|r| r.is_err()) {
            // Back off instead of hammering a failing chunk; the serving
            // path will surface the error if playback actually needs it.
            tracing::debug!("prefetch fetch failed, backing off: {e}");
            tokio::time::sleep(Duration::from_secs(2)).await;
        }
        if pos.has_changed().is_err() {
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prefetch_window_starts_small_and_grows_to_the_cap() {
        assert_eq!(adaptive_prefetch_ahead(Duration::ZERO), PREFETCH_AHEAD_MIN_CHUNKS);
        assert_eq!(adaptive_prefetch_ahead(Duration::from_secs(29)), 1);
        assert_eq!(adaptive_prefetch_ahead(Duration::from_secs(30)), 2);
        assert_eq!(adaptive_prefetch_ahead(Duration::from_secs(95)), 4);
        // Long playback caps out and stays there.
        assert_eq!(
            adaptive_prefetch_ahead(Duration::from_secs(210)),
            PREFETCH_AHEAD_MAX_CHUNKS
        );
        assert_eq!(
            adaptive_prefetch_ahead(Duration::from_secs(3600)),
            PREFETCH_AHEAD_MAX_CHUNKS
        );
    }
}
