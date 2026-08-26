//! My W@tch device linking (test implementation).
//!
//! Links a user's own devices through an in-process x0x agent
//! (saorsa-gossip over ant-quic, post-quantum, mDNS LAN discovery plus
//! the public bootstrap overlay). The link is a 32-byte secret shared
//! via QR/paste; devices meet in a self-keyed CRDT key-value store on a
//! topic *derived* from that secret (the raw secret never goes on the
//! wire), where each device owns exactly one record — its agent-id key —
//! holding name/platform/library counts/heartbeat time. Merging is the
//! CRDT's, so it is bidirectional and order-free by construction.
//!
//! Besides the presence records, each device publishes a library sync
//! document and its entries' shrunk data maps under its bound
//! `<agent>/sync` and `<agent>/maps/N` keys (see `publish_sync`); the
//! app's `MyWatchSync` service merges the remote documents. User-made
//! artwork syncs at full quality outside the store: the sync doc only
//! carries a manifest (sha256/size), and a device missing the bytes
//! pulls them from the owning device over x0x direct messages while it
//! is online (`fetch_art` / the art_req listener). Built for
//! desktop and Android (the NDK build links against API 24+ for
//! `getifaddrs`); other platforms get the stub at the bottom which
//! reports `supported: false`.

/// Invite string prefix; version-bumped if the format ever changes.
pub const INVITE_PREFIX: &str = "wtch1-";

/// Everything the routes call, real on desktop, stub elsewhere.
pub use imp::MyWatchStore;

#[cfg(any(
    target_os = "linux",
    target_os = "windows",
    target_os = "macos",
    target_os = "android"
))]
mod imp {
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::Arc;
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    use serde_json::{json, Value};
    use tokio::sync::Mutex;

    use super::INVITE_PREFIX;

    /// Seconds between own-record heartbeats while linked (also bounds
    /// how stale another device's "last heard" can look while online).
    const HEARTBEAT_SECS: u64 = 60;
    /// Seconds between store polls watching for remote-record changes
    /// (drives the persisted last-sync stamp).
    const WATCH_SECS: u64 = 5;
    /// Ceiling for one published KV value; the store's hard cap is
    /// 64 KiB (`MAX_INLINE_SIZE`), this leaves protocol headroom.
    const MAX_VALUE_BYTES: usize = 60_000;
    /// How many `<agent>/maps/N` part keys a device may publish. Bounded
    /// by the store's 256 KiB per-agent byte quota: presence record +
    /// sync doc + 3 map parts stays under it with margin.
    const MAX_MAP_PARTS: usize = 3;
    /// Raw bytes per artwork chunk DM. Base64 in a small JSON wrapper
    /// lands around 40 KB — inside the DM envelope cap (x0x's own file
    /// protocol uses 32 KiB chunks the same way).
    const ART_CHUNK_BYTES: usize = 30_000;
    /// Ceiling for one artwork file (matches the app's 10 MB image-pick
    /// cap) — refuses runaway transfers on both ends.
    const MAX_ART_BYTES: u64 = 10 * 1024 * 1024;
    /// Whole-transfer deadline for one artwork fetch. Chunks are pulled
    /// one round trip at a time, so a large poster on a slow link needs
    /// real time.
    const ART_FETCH_TIMEOUT: Duration = Duration::from_secs(120);
    /// How long to wait for one requested chunk before asking again.
    const ART_CHUNK_TIMEOUT: Duration = Duration::from_secs(10);
    /// Requests per chunk before the fetch gives up.
    const ART_CHUNK_RETRIES: u32 = 3;

    fn now_ms() -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0)
    }

    /// Persisted link config (`<data_dir>/mywatch/link.json`).
    #[derive(Clone)]
    struct LinkConfig {
        device_name: String,
        secret_hex: String,
        created_at_ms: u64,
    }

    /// Persisted mutable state (`<data_dir>/mywatch/state.json`): the
    /// last-sync stamp and the last announced library counts, so a
    /// restarted device republishes real numbers before the app's first
    /// announce.
    #[derive(Clone, Copy, Default)]
    struct PersistedState {
        last_sync_ms: u64,
        lists: u64,
        entries: u64,
    }

    struct Running {
        agent: Arc<x0x::Agent>,
        store: x0x::KvStoreHandle,
        config: LinkConfig,
        cancel: tokio_util::sync::CancellationToken,
        /// A KV snapshot existed on disk before this join — the watcher's
        /// first scan then re-reads old records (history, not a sync) and
        /// must not stamp last-sync. On a fresh join every record arriving
        /// in the first scan IS a sync.
        restored_from_snapshot: bool,
    }

    enum Phase {
        Off,
        /// Link config exists; agent/network still coming up (retrying).
        Starting,
        Ready(Running),
    }

    /// State the background task shares with the store (spawned futures
    /// must be 'static, so this rides in an `Arc` instead of `&self`).
    struct Shared {
        /// Wall-clock ms when a *remote* device's record last changed
        /// under us — i.e. the last time we demonstrably synced.
        last_sync_ms: AtomicU64,
        /// Library counts from the app's last announce, echoed by the
        /// heartbeat.
        lists: AtomicU64,
        entries: AtomicU64,
        state_path: Option<PathBuf>,
        /// sha256(hex) → local file path of user artwork this device can
        /// serve to its linked peers (set by the app each sync cycle).
        art_index: std::sync::Mutex<std::collections::HashMap<String, PathBuf>>,
    }

    impl Shared {
        fn save(&self) {
            let Some(path) = &self.state_path else { return };
            if let Some(parent) = path.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            let body = json!({
                "last_sync_ms": self.last_sync_ms.load(Ordering::SeqCst),
                "lists": self.lists.load(Ordering::SeqCst),
                "entries": self.entries.load(Ordering::SeqCst),
            })
            .to_string();
            let _ = std::fs::write(path, body);
        }
    }

    pub struct MyWatchStore {
        dir: Option<PathBuf>,
        phase: Mutex<Phase>,
        /// Last startup/sync problem, for the status UI.
        message: std::sync::Mutex<Option<String>>,
        shared: Arc<Shared>,
        /// One artwork fetch at a time — posters are small and the app
        /// requests them sequentially anyway.
        art_fetch: Mutex<()>,
    }

    impl MyWatchStore {
        pub fn new(data_dir: Option<&str>) -> Self {
            let dir = data_dir
                .filter(|d| !d.trim().is_empty())
                .map(|d| Path::new(d).join("mywatch"));
            let store = Self {
                shared: Arc::new(Shared {
                    last_sync_ms: AtomicU64::new(0),
                    lists: AtomicU64::new(0),
                    entries: AtomicU64::new(0),
                    state_path: dir.as_ref().map(|d| d.join("state.json")),
                    art_index: std::sync::Mutex::new(Default::default()),
                }),
                dir,
                phase: Mutex::new(Phase::Off),
                message: std::sync::Mutex::new(None),
                art_fetch: Mutex::new(()),
            };
            let persisted = store.load_state();
            store
                .shared
                .last_sync_ms
                .store(persisted.last_sync_ms, Ordering::SeqCst);
            store.shared.lists.store(persisted.lists, Ordering::SeqCst);
            store.shared.entries.store(persisted.entries, Ordering::SeqCst);
            store
        }

        // ---- persistence ------------------------------------------------

        fn link_path(&self) -> Option<PathBuf> {
            self.dir.as_ref().map(|d| d.join("link.json"))
        }

        fn load_config(&self) -> Option<LinkConfig> {
            let text = std::fs::read_to_string(self.link_path()?).ok()?;
            let v: Value = serde_json::from_str(&text).ok()?;
            let secret_hex = v["secret"].as_str()?.to_string();
            (secret_hex.len() == 64 && hex::decode(&secret_hex).is_ok()).then(
                || LinkConfig {
                    device_name: v["device_name"]
                        .as_str()
                        .unwrap_or("unnamed device")
                        .to_string(),
                    secret_hex,
                    created_at_ms: v["created_at_ms"].as_u64().unwrap_or(0),
                },
            )
        }

        fn save_config(&self, cfg: &LinkConfig) -> Result<(), String> {
            let path = self
                .link_path()
                .ok_or("no data dir available for My W@tch")?;
            if let Some(parent) = path.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            let body = json!({
                "device_name": cfg.device_name,
                "secret": cfg.secret_hex,
                "created_at_ms": cfg.created_at_ms,
            })
            .to_string();
            std::fs::write(&path, body).map_err(|e| format!("link save failed: {e}"))?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = std::fs::set_permissions(
                    &path,
                    std::fs::Permissions::from_mode(0o600),
                );
            }
            Ok(())
        }

        fn load_state(&self) -> PersistedState {
            let Some(path) = &self.shared.state_path else {
                return PersistedState::default();
            };
            let Ok(text) = std::fs::read_to_string(path) else {
                return PersistedState::default();
            };
            let v: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
            PersistedState {
                last_sync_ms: v["last_sync_ms"].as_u64().unwrap_or(0),
                lists: v["lists"].as_u64().unwrap_or(0),
                entries: v["entries"].as_u64().unwrap_or(0),
            }
        }

        fn set_message(&self, msg: Option<String>) {
            *self.message.lock().unwrap() = msg;
        }

        // ---- link lifecycle ---------------------------------------------

        /// Resume an existing link after process start. Spawned once from
        /// `start()`; a device that was never linked returns immediately.
        pub async fn autostart(&'static self) {
            if let Some(cfg) = self.load_config() {
                self.start_with_config(cfg).await;
            }
        }

        /// Create a brand-new link on this device and return the invite
        /// other devices join with.
        pub async fn create_link(&'static self, device_name: &str) -> Result<Value, String> {
            self.ensure_unlinked().await?;
            let mut secret = [0u8; 32];
            use rand::RngCore;
            rand::thread_rng().fill_bytes(&mut secret);
            let cfg = LinkConfig {
                device_name: clean_name(device_name)?,
                secret_hex: hex::encode(secret),
                created_at_ms: now_ms(),
            };
            self.save_config(&cfg)?;
            let invite = format!("{INVITE_PREFIX}{}", cfg.secret_hex);
            tokio::spawn(self.start_with_config(cfg));
            Ok(json!({ "invite": invite }))
        }

        /// Join a link created elsewhere from its invite string.
        pub async fn join_link(
            &'static self,
            device_name: &str,
            invite: &str,
        ) -> Result<Value, String> {
            self.ensure_unlinked().await?;
            let secret_hex = parse_invite(invite)?;
            let cfg = LinkConfig {
                device_name: clean_name(device_name)?,
                secret_hex,
                created_at_ms: now_ms(),
            };
            self.save_config(&cfg)?;
            tokio::spawn(self.start_with_config(cfg));
            Ok(json!({ "joined": true }))
        }

        /// The invite string for the existing link (QR display, adding a
        /// third device later).
        pub async fn invite(&self) -> Result<Value, String> {
            let cfg = self.load_config().ok_or("this device is not linked")?;
            Ok(json!({ "invite": format!("{INVITE_PREFIX}{}", cfg.secret_hex) }))
        }

        /// Update this device's library summary and republish its record.
        pub async fn announce(&self, lists: u64, entries: u64) -> Result<Value, String> {
            self.shared.lists.store(lists, Ordering::SeqCst);
            self.shared.entries.store(entries, Ordering::SeqCst);
            self.shared.save();
            let phase = self.phase.lock().await;
            if let Phase::Ready(running) = &*phase {
                put_own_record(running, lists, entries).await?;
            }
            Ok(json!({ "announced": true }))
        }

        /// Publish this device's library sync document (lists, entries,
        /// tombstones, watch states — built by the app) plus the shrunk
        /// data maps for the entries it holds (collected by the server
        /// route from the local map store), under this device's bound
        /// keys `<agent>/sync` and `<agent>/maps/N`. Maps that do not
        /// fit the per-agent byte quota are dropped, most-recent first
        /// kept — membership and progress still sync, the dropped maps
        /// just cannot make the entry playable remotely.
        pub async fn publish_sync(
            &self,
            doc: Value,
            maps: Vec<(String, String)>,
        ) -> Result<Value, String> {
            let doc_bytes = doc.to_string();
            if doc_bytes.len() > MAX_VALUE_BYTES {
                return Err(format!(
                    "sync document too large ({} bytes > {MAX_VALUE_BYTES})",
                    doc_bytes.len()
                ));
            }
            let phase = self.phase.lock().await;
            let Phase::Ready(running) = &*phase else {
                return Err(match &*phase {
                    Phase::Off => "this device is not linked".into(),
                    _ => "the link is still starting — try again shortly".to_string(),
                });
            };
            let own = hex::encode(running.agent.agent_id().as_bytes());
            running
                .store
                .put(
                    format!("{own}/sync"),
                    doc_bytes.into_bytes(),
                    "application/json".into(),
                )
                .await
                .map_err(|e| format!("sync publish failed: {e}"))?;
            // Greedy-pack the maps into value-capped parts.
            let mut parts: Vec<serde_json::Map<String, Value>> = vec![Default::default()];
            let mut part_bytes = 2usize;
            let mut attached = 0usize;
            let mut dropped = 0usize;
            for (addr, b64) in maps {
                // `"addr":"b64",` — 8 bytes of JSON punctuation.
                let cost = addr.len() + b64.len() + 8;
                if part_bytes + cost > MAX_VALUE_BYTES {
                    if parts.len() >= MAX_MAP_PARTS {
                        dropped += 1;
                        continue;
                    }
                    parts.push(Default::default());
                    part_bytes = 2;
                }
                part_bytes += cost;
                parts.last_mut().unwrap().insert(addr, Value::String(b64));
                attached += 1;
            }
            if dropped > 0 {
                tracing::warn!(
                    "mywatch sync: {dropped} entry maps over the store quota were not published"
                );
            }
            for (i, part) in parts.iter().enumerate() {
                running
                    .store
                    .put(
                        format!("{own}/maps/{i}"),
                        Value::Object(part.clone()).to_string().into_bytes(),
                        "application/json".into(),
                    )
                    .await
                    .map_err(|e| format!("map publish failed: {e}"))?;
            }
            // A shrinking library frees stale part keys (tombstones do
            // not count against the quota).
            for i in parts.len()..MAX_MAP_PARTS {
                let _ = running.store.remove(&format!("{own}/maps/{i}")).await;
            }
            Ok(json!({ "published": true, "maps": attached, "dropped": dropped }))
        }

        /// Every *remote* device's sync document and entry maps, for the
        /// app's merge pass. Contains whatever the CRDT last converged
        /// on; an offline device's doc is simply its last published one.
        pub async fn sync_docs(&self) -> Result<Value, String> {
            let phase = self.phase.lock().await;
            let Phase::Ready(running) = &*phase else {
                return Err(match &*phase {
                    Phase::Off => "this device is not linked".into(),
                    _ => "the link is still starting — try again shortly".to_string(),
                });
            };
            let own = hex::encode(running.agent.agent_id().as_bytes());
            let entries = running
                .store
                .keys()
                .await
                .map_err(|e| format!("store read failed: {e}"))?;
            let mut docs: std::collections::HashMap<String, Value> = Default::default();
            let mut maps: std::collections::HashMap<String, serde_json::Map<String, Value>> =
                Default::default();
            for entry in entries {
                let Some((agent, suffix)) = entry.key.split_once('/') else {
                    continue;
                };
                if agent == own {
                    continue;
                }
                if suffix == "sync" {
                    if let Ok(doc) = serde_json::from_slice::<Value>(&entry.value) {
                        docs.insert(agent.to_string(), doc);
                    }
                } else if suffix.starts_with("maps/") {
                    if let Ok(Value::Object(part)) =
                        serde_json::from_slice::<Value>(&entry.value)
                    {
                        maps.entry(agent.to_string()).or_default().extend(part);
                    }
                }
            }
            let devices: Vec<Value> = docs
                .into_iter()
                .map(|(agent, doc)| {
                    let m = maps.remove(&agent).unwrap_or_default();
                    json!({ "agent_id": agent, "doc": doc, "maps": m })
                })
                .collect();
            Ok(json!({
                "agent_id": own,
                "last_sync_ms": self.shared.last_sync_ms.load(Ordering::SeqCst),
                "devices": devices,
            }))
        }

        /// Replace the set of user-artwork files this device serves to
        /// its linked peers (`sha256(hex) → path`). The app refreshes it
        /// whenever its artwork changes; requests for anything else are
        /// refused.
        pub fn set_art_index(&self, files: Vec<(String, PathBuf)>) -> Result<Value, String> {
            let mut idx = self.shared.art_index.lock().unwrap();
            idx.clear();
            for (sha, path) in files {
                let sha = sha.trim().to_lowercase();
                if sha.len() == 64 && hex::decode(&sha).is_ok() {
                    idx.insert(sha, path);
                }
            }
            Ok(json!({ "indexed": idx.len() }))
        }

        /// Pull one artwork file from linked device [`agent_hex`] over
        /// x0x direct messages, one chunk per request (proving link
        /// membership with a tag derived from the invite secret), verify
        /// the whole file's sha256, park it under `<dir>/art/<sha256>`
        /// and return `{path, size}`. The transfer is pull-based on
        /// purpose: firing the chunks as a back-to-back DM stream loses
        /// messages beyond a ~4-message burst (observed live between two
        /// devservers — the sends succeed but only the tail arrives), so
        /// the receiver requests each chunk and retries the ones that go
        /// missing. The owning device must be online; the app checks
        /// presence first.
        pub async fn fetch_art(&self, agent_hex: &str, sha256: &str) -> Result<Value, String> {
            let sha = sha256.trim().to_lowercase();
            if sha.len() != 64 || hex::decode(&sha).is_err() {
                return Err("sha256 must be 64 hex characters".into());
            }
            let mut id = [0u8; 32];
            if hex::decode_to_slice(agent_hex.trim(), &mut id).is_err() {
                return Err("agent id must be 64 hex characters".into());
            }
            let (agent, secret, dir) = {
                let phase = self.phase.lock().await;
                let Phase::Ready(running) = &*phase else {
                    return Err(match &*phase {
                        Phase::Off => "this device is not linked".into(),
                        _ => "the link is still starting — try again shortly".to_string(),
                    });
                };
                (
                    Arc::clone(&running.agent),
                    running.config.secret_hex.clone(),
                    self.dir.clone().ok_or("no data dir")?,
                )
            };
            let _one_at_a_time = self.art_fetch.lock().await;
            let to = x0x::identity::AgentId(id);
            // Subscribe before the first request so no reply can slip
            // past, then make sure a direct path exists.
            let mut rx = agent.subscribe_direct();
            let _ = agent.connect_to_agent(&to).await;
            let auth = art_auth(&secret, &sha);

            use base64::Engine as _;
            let deadline = tokio::time::Instant::now() + ART_FETCH_TIMEOUT;
            let mut out: Vec<u8> = Vec::new();
            let mut next_seq: usize = 0;
            let mut total: Option<usize> = None;
            while total.is_none_or(|t| next_seq < t) {
                let mut attempts = 0;
                'chunk: loop {
                    attempts += 1;
                    let req = json!({
                        "wtch": "art_req",
                        "v": 2,
                        "sha256": sha,
                        "auth": auth,
                        "seq": next_seq,
                    });
                    agent
                        .send_direct(&to, req.to_string().into_bytes())
                        .await
                        .map_err(|e| format!("artwork request failed: {e}"))?;
                    let retry_at = tokio::time::Instant::now() + ART_CHUNK_TIMEOUT;
                    loop {
                        let msg = tokio::select! {
                            _ = tokio::time::sleep_until(deadline) => {
                                return Err("artwork transfer timed out".into());
                            }
                            _ = tokio::time::sleep_until(retry_at) => {
                                if attempts >= ART_CHUNK_RETRIES {
                                    return Err(format!(
                                        "artwork chunk {next_seq} never arrived"
                                    ));
                                }
                                continue 'chunk;
                            }
                            m = rx.recv() => {
                                m.ok_or("the link shut down mid-transfer")?
                            }
                        };
                        if msg.sender != to {
                            continue;
                        }
                        let Ok(v) = serde_json::from_slice::<Value>(&msg.payload) else {
                            continue;
                        };
                        if v["sha256"].as_str() != Some(sha.as_str()) {
                            continue;
                        }
                        match v["wtch"].as_str() {
                            Some("art_err") => {
                                let e = v["error"].as_str().unwrap_or("remote error");
                                return Err(format!("the other device refused: {e}"));
                            }
                            Some("art_chunk") => {
                                // A retried request can produce a duplicate
                                // reply; anything but the chunk we are
                                // waiting for is stale — drop it.
                                if v["seq"].as_u64() != Some(next_seq as u64) {
                                    continue;
                                }
                                let Some(data) = v["data"].as_str() else { continue };
                                let raw = base64::engine::general_purpose::STANDARD
                                    .decode(data)
                                    .map_err(|_| "artwork chunk was not valid base64")?;
                                let t = v["total"].as_u64().unwrap_or(0) as usize;
                                if t == 0 || total.is_some_and(|known| known != t) {
                                    return Err(
                                        "artwork chunk carried a bad chunk count".into()
                                    );
                                }
                                total = Some(t);
                                out.extend_from_slice(&raw);
                                if out.len() as u64 > MAX_ART_BYTES {
                                    return Err("artwork exceeds the 10 MB limit".into());
                                }
                                next_seq += 1;
                                break 'chunk;
                            }
                            _ => continue,
                        }
                    }
                }
            }
            let bytes = out;
            if sha256_hex(&bytes) != sha {
                return Err("artwork failed its integrity check".into());
            }
            let art_dir = dir.join("art");
            std::fs::create_dir_all(&art_dir)
                .map_err(|e| format!("artwork dir create failed: {e}"))?;
            let path = art_dir.join(&sha);
            std::fs::write(&path, &bytes)
                .map_err(|e| format!("artwork save failed: {e}"))?;
            Ok(json!({
                "path": path.to_string_lossy(),
                "size": bytes.len(),
            }))
        }

        /// Tear the link down on this device: stop the agent and delete
        /// every mywatch artefact (secret, identity, KV snapshots). Other
        /// devices keep the link; this device's stale record ages out on
        /// their screens.
        pub async fn unlink(&self) -> Result<Value, String> {
            let mut phase = self.phase.lock().await;
            if let Phase::Ready(running) = &*phase {
                running.cancel.cancel();
                running.store.cancel_sync();
                running.agent.shutdown().await;
            }
            *phase = Phase::Off;
            drop(phase);
            if let Some(dir) = &self.dir {
                let _ = std::fs::remove_dir_all(dir);
            }
            self.shared.last_sync_ms.store(0, Ordering::SeqCst);
            self.set_message(None);
            Ok(json!({ "unlinked": true }))
        }

        async fn ensure_unlinked(&self) -> Result<(), String> {
            if self.load_config().is_some() {
                return Err("this device is already linked — unlink first".into());
            }
            if self.dir.is_none() {
                return Err("no data dir available for My W@tch".into());
            }
            Ok(())
        }

        /// Bring the agent up for `cfg`, retrying with backoff until it
        /// sticks or the link is removed underneath us.
        async fn start_with_config(&'static self, cfg: LinkConfig) {
            {
                let mut phase = self.phase.lock().await;
                if matches!(*phase, Phase::Starting | Phase::Ready(_)) {
                    return;
                }
                *phase = Phase::Starting;
            }
            let mut backoff = Duration::from_secs(2);
            loop {
                if self.load_config().is_none() {
                    // Unlinked while we were still starting.
                    let mut phase = self.phase.lock().await;
                    if matches!(*phase, Phase::Starting) {
                        *phase = Phase::Off;
                    }
                    return;
                }
                match self.bring_up(&cfg).await {
                    Ok(running) => {
                        self.spawn_tasks(&running);
                        let lists = self.shared.lists.load(Ordering::SeqCst);
                        let entries = self.shared.entries.load(Ordering::SeqCst);
                        if let Err(e) = put_own_record(&running, lists, entries).await {
                            tracing::warn!("mywatch first record put failed: {e}");
                        }
                        self.set_message(None);
                        *self.phase.lock().await = Phase::Ready(running);
                        tracing::info!("mywatch link up");
                        return;
                    }
                    Err(e) => {
                        tracing::warn!("mywatch start failed (will retry): {e}");
                        self.set_message(Some(e));
                        tokio::time::sleep(backoff).await;
                        backoff = (backoff * 2).min(Duration::from_secs(60));
                    }
                }
            }
        }

        async fn bring_up(&self, cfg: &LinkConfig) -> Result<Running, String> {
            let dir = self.dir.clone().ok_or("no data dir")?;
            let _ = std::fs::create_dir_all(&dir);
            // Every path is pinned inside our own dir: two instances on
            // one host (or the devserver next to the app) must not share
            // ~/.x0x machine keys or peer caches.
            let agent = x0x::Agent::builder()
                .with_machine_key(dir.join("machine.key"))
                .with_agent_key_path(dir.join("agent.key"))
                .with_identity_dir(&dir)
                .with_peer_cache_dir(dir.join("peers"))
                .with_network_config(x0x::network::NetworkConfig::default())
                .build()
                .await
                .map_err(|e| format!("agent build failed: {e}"))?;
            agent
                .join_network()
                .await
                .map_err(|e| format!("network join failed: {e}"))?;
            let restored_from_snapshot = std::fs::read_dir(&dir)
                .map(|entries| {
                    entries.flatten().any(|e| {
                        e.path().extension().is_some_and(|ext| ext == "bin")
                    })
                })
                .unwrap_or(false);
            let store = agent
                .join_self_keyed_kv_store_persistent(&topic_for(&cfg.secret_hex), &dir)
                .await
                .map_err(|e| format!("sync store join failed: {e}"))?;
            Ok(Running {
                agent: Arc::new(agent),
                store,
                config: cfg.clone(),
                cancel: tokio_util::sync::CancellationToken::new(),
                restored_from_snapshot,
            })
        }

        /// Heartbeat + remote-change watcher, one task. Holds no lock on
        /// the phase mutex — it talks to a cloned store handle and dies
        /// via the cancellation token on unlink.
        fn spawn_tasks(&self, running: &Running) {
            let cancel = running.cancel.clone();
            let store = running.store.clone();
            let shared = Arc::clone(&self.shared);
            let own_key = hex::encode(running.agent.agent_id().as_bytes());
            let device_name = running.config.device_name.clone();
            let restored = running.restored_from_snapshot;
            tokio::spawn(async move {
                let mut seen: std::collections::HashMap<String, String> =
                    std::collections::HashMap::new();
                let mut first_scan = restored;
                let mut ticks: u64 = 0;
                loop {
                    tokio::select! {
                        _ = cancel.cancelled() => return,
                        _ = tokio::time::sleep(Duration::from_secs(WATCH_SECS)) => {}
                    }
                    // Heartbeat: republish our record so other devices see
                    // a fresh "last heard" while we are running.
                    ticks += WATCH_SECS;
                    if ticks >= HEARTBEAT_SECS {
                        ticks = 0;
                        let record = record_json(
                            &device_name,
                            shared.lists.load(Ordering::SeqCst),
                            shared.entries.load(Ordering::SeqCst),
                        );
                        if let Err(e) = store
                            .put(own_key.clone(), record.into_bytes(), "application/json".into())
                            .await
                        {
                            tracing::debug!("mywatch heartbeat put failed: {e}");
                        }
                    }
                    // Watch: any remote record new/changed => we synced.
                    // Keys under our own prefix (`<own>/sync`, `<own>/maps/N`)
                    // are our publishes, not evidence of a sync.
                    let Ok(entries) = store.keys().await else { continue };
                    let mut changed = false;
                    for entry in entries {
                        if entry.key.starts_with(&own_key) {
                            continue;
                        }
                        if seen.get(&entry.key) != Some(&entry.content_hash) {
                            seen.insert(entry.key.clone(), entry.content_hash.clone());
                            changed = true;
                        }
                    }
                    // The very first scan after a restart re-reads records
                    // from the local snapshot — that is history, not a sync.
                    if changed && !first_scan {
                        shared.last_sync_ms.store(now_ms(), Ordering::SeqCst);
                        shared.save();
                    }
                    first_scan = false;
                }
            });
            // Artwork server: answer linked peers' art_req DMs, one
            // chunk per request (the receiver pulls and retries — see
            // fetch_art). Requests must carry the membership tag derived
            // from the invite secret — a stranger who somehow learns our
            // agent-id still gets nothing.
            let cancel = running.cancel.clone();
            let agent = Arc::clone(&running.agent);
            let shared = Arc::clone(&self.shared);
            let secret = running.config.secret_hex.clone();
            tokio::spawn(async move {
                let mut rx = agent.subscribe_direct();
                loop {
                    let msg = tokio::select! {
                        _ = cancel.cancelled() => return,
                        m = rx.recv() => match m {
                            Some(m) => m,
                            None => return,
                        },
                    };
                    let Ok(v) = serde_json::from_slice::<Value>(&msg.payload) else {
                        continue;
                    };
                    if v["wtch"].as_str() != Some("art_req") {
                        continue;
                    }
                    let (Some(sha), Some(auth)) = (v["sha256"].as_str(), v["auth"].as_str())
                    else {
                        continue;
                    };
                    if auth != art_auth(&secret, sha) {
                        tracing::debug!("mywatch art: request with a bad link tag ignored");
                        continue;
                    }
                    let seq = v["seq"].as_u64().unwrap_or(0) as usize;
                    let path = shared.art_index.lock().unwrap().get(sha).cloned();
                    if let Err(e) = serve_art(&agent, &msg.sender, sha, seq, path).await {
                        tracing::debug!("mywatch art: serve failed: {e}");
                    }
                }
            });
        }

        // ---- status -----------------------------------------------------

        pub async fn status(&self) -> Value {
            let cfg = self.load_config();
            let phase = self.phase.lock().await;
            let (state, running) = match &*phase {
                Phase::Off => (if cfg.is_some() { "starting" } else { "off" }, None),
                Phase::Starting => ("starting", None),
                Phase::Ready(r) => ("ready", Some(r)),
            };
            let mut devices = Vec::new();
            let mut own_id = String::new();
            if let Some(running) = running {
                own_id = hex::encode(running.agent.agent_id().as_bytes());
                let online: std::collections::HashSet<String> = running
                    .agent
                    .presence()
                    .await
                    .unwrap_or_default()
                    .iter()
                    .map(|a| hex::encode(a.as_bytes()))
                    .collect();
                if let Ok(entries) = running.store.keys().await {
                    for entry in entries {
                        // Presence records are the bare agent-id keys;
                        // `<agent>/sync` and `<agent>/maps/N` are the
                        // sync payloads, not devices.
                        if entry.key.contains('/') {
                            continue;
                        }
                        let v: Value =
                            serde_json::from_slice(&entry.value).unwrap_or(Value::Null);
                        let is_self = entry.key == own_id;
                        devices.push(json!({
                            "agent_id": entry.key,
                            "self": is_self,
                            "name": v["name"].as_str().unwrap_or("unknown device"),
                            "platform": v["platform"].as_str().unwrap_or("?"),
                            "lists": v["lists"].as_u64().unwrap_or(0),
                            "entries": v["entries"].as_u64().unwrap_or(0),
                            "updated_at_ms": v["updated_at_ms"].as_u64().unwrap_or(0),
                            "online": is_self || online.contains(&entry.key),
                        }));
                    }
                }
            }
            json!({
                "supported": true,
                "linked": cfg.is_some(),
                "state": state,
                "message": *self.message.lock().unwrap(),
                "device_name": cfg.as_ref().map(|c| c.device_name.clone()),
                "linked_since_ms": cfg.as_ref().map(|c| c.created_at_ms),
                "agent_id": own_id,
                "last_sync_ms": self.shared.last_sync_ms.load(Ordering::SeqCst),
                "devices": devices,
            })
        }
    }

    fn clean_name(name: &str) -> Result<String, String> {
        let name = name.trim();
        if name.is_empty() {
            return Err("device name is required".into());
        }
        Ok(name.chars().take(48).collect())
    }

    fn parse_invite(invite: &str) -> Result<String, String> {
        let hex_part = invite
            .trim()
            .strip_prefix(INVITE_PREFIX)
            .ok_or("not a My W@tch invite code")?;
        if hex_part.len() != 64 || hex::decode(hex_part).is_err() {
            return Err("invite code is damaged (wrong length or characters)".into());
        }
        Ok(hex_part.to_lowercase())
    }

    /// Membership tag for an artwork request: proves the requester holds
    /// the link's invite secret without putting the secret on the wire.
    /// Domain-separated from [`topic_for`], and bound to the requested
    /// hash so tags cannot be replayed for other files.
    fn art_auth(secret_hex: &str, sha256: &str) -> String {
        let mut hasher = blake3::Hasher::new();
        hasher.update(b"watchit mywatch v1 art");
        hasher.update(secret_hex.as_bytes());
        hasher.update(sha256.as_bytes());
        hasher.finalize().to_hex().to_string()
    }

    fn sha256_hex(bytes: &[u8]) -> String {
        use sha2::Digest;
        hex::encode(sha2::Sha256::digest(bytes))
    }

    /// Answer one pull request with exactly one chunk DM (the file is
    /// re-read and re-hashed per request so a file replaced on disk
    /// mid-transfer can never ship under the old name — the requester's
    /// final whole-file hash check backstops the cross-chunk case).
    /// Problems the requester should hear about (unknown file, changed
    /// file, out-of-range chunk) go back as `art_err`; transport
    /// failures just log — the requester's retry covers them.
    async fn serve_art(
        agent: &x0x::Agent,
        to: &x0x::identity::AgentId,
        sha: &str,
        seq: usize,
        path: Option<PathBuf>,
    ) -> Result<(), String> {
        use base64::Engine as _;
        let refuse = |why: &str| {
            json!({ "wtch": "art_err", "sha256": sha, "error": why })
                .to_string()
                .into_bytes()
        };
        let Some(path) = path else {
            let _ = agent.send_direct(to, refuse("artwork not available")).await;
            return Ok(());
        };
        let bytes = match std::fs::read(&path) {
            Ok(b) => b,
            Err(e) => {
                let _ = agent.send_direct(to, refuse("artwork not available")).await;
                return Err(format!("read {} failed: {e}", path.display()));
            }
        };
        if bytes.is_empty()
            || bytes.len() as u64 > MAX_ART_BYTES
            || sha256_hex(&bytes) != sha
        {
            let _ = agent.send_direct(to, refuse("artwork changed on disk")).await;
            return Ok(());
        }
        let total = bytes.len().div_ceil(ART_CHUNK_BYTES);
        if seq >= total {
            let _ = agent.send_direct(to, refuse("no such chunk")).await;
            return Ok(());
        }
        let start = seq * ART_CHUNK_BYTES;
        let chunk = &bytes[start..(start + ART_CHUNK_BYTES).min(bytes.len())];
        let payload = json!({
            "wtch": "art_chunk",
            "sha256": sha,
            "seq": seq,
            "total": total,
            "size": bytes.len(),
            "data": base64::engine::general_purpose::STANDARD.encode(chunk),
        });
        agent
            .send_direct(to, payload.to_string().into_bytes())
            .await
            .map_err(|e| format!("chunk {seq} send failed: {e}"))?;
        Ok(())
    }

    /// Gossip topic for a link. Derived, so the raw invite secret never
    /// appears in topic-shaped places on the wire, and a future encrypted
    /// payload could key itself from the same secret independently.
    fn topic_for(secret_hex: &str) -> String {
        let mut hasher = blake3::Hasher::new();
        hasher.update(b"watchit mywatch v1 topic");
        hasher.update(secret_hex.as_bytes());
        format!("wtch-mywatch-{}", hasher.finalize().to_hex())
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn art_auth_is_stable_and_bound_to_hash_and_secret() {
            let a = art_auth("aa".repeat(32).as_str(), &"11".repeat(32));
            assert_eq!(a, art_auth(&"aa".repeat(32), &"11".repeat(32)));
            assert_ne!(a, art_auth(&"aa".repeat(32), &"22".repeat(32)));
            assert_ne!(a, art_auth(&"bb".repeat(32), &"11".repeat(32)));
            // Domain-separated from the gossip topic derivation.
            assert!(!topic_for(&"aa".repeat(32)).contains(&a));
        }

        #[test]
        fn sha256_hex_matches_known_vector() {
            assert_eq!(
                sha256_hex(b"abc"),
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
            );
        }
    }

    fn record_json(device_name: &str, lists: u64, entries: u64) -> String {
        json!({
            "name": device_name,
            "platform": std::env::consts::OS,
            "lists": lists,
            "entries": entries,
            "updated_at_ms": now_ms(),
        })
        .to_string()
    }

    async fn put_own_record(running: &Running, lists: u64, entries: u64) -> Result<(), String> {
        let key = hex::encode(running.agent.agent_id().as_bytes());
        running
            .store
            .put(
                key,
                record_json(&running.config.device_name, lists, entries).into_bytes(),
                "application/json".into(),
            )
            .await
            .map_err(|e| format!("record publish failed: {e}"))
    }
}

/// Stub for platforms without the x0x tree (iOS for now): same surface,
/// everything reports unsupported so the UI can say so instead of
/// erroring blind.
#[cfg(not(any(
    target_os = "linux",
    target_os = "windows",
    target_os = "macos",
    target_os = "android"
)))]
mod imp {
    use serde_json::{json, Value};

    const UNSUPPORTED: &str = "My W@tch is not available on this platform yet";

    pub struct MyWatchStore;

    impl MyWatchStore {
        pub fn new(_data_dir: Option<&str>) -> Self {
            Self
        }
        pub async fn autostart(&'static self) {}
        pub async fn status(&self) -> Value {
            json!({ "supported": false, "linked": false, "state": "off", "devices": [] })
        }
        pub async fn create_link(&'static self, _name: &str) -> Result<Value, String> {
            Err(UNSUPPORTED.into())
        }
        pub async fn join_link(&'static self, _n: &str, _i: &str) -> Result<Value, String> {
            Err(UNSUPPORTED.into())
        }
        pub async fn invite(&self) -> Result<Value, String> {
            Err(UNSUPPORTED.into())
        }
        pub async fn announce(&self, _l: u64, _e: u64) -> Result<Value, String> {
            Err(UNSUPPORTED.into())
        }
        pub async fn publish_sync(
            &self,
            _doc: Value,
            _maps: Vec<(String, String)>,
        ) -> Result<Value, String> {
            Err(UNSUPPORTED.into())
        }
        pub async fn sync_docs(&self) -> Result<Value, String> {
            Err(UNSUPPORTED.into())
        }
        pub fn set_art_index(
            &self,
            _files: Vec<(String, std::path::PathBuf)>,
        ) -> Result<Value, String> {
            Err(UNSUPPORTED.into())
        }
        pub async fn fetch_art(&self, _agent: &str, _sha: &str) -> Result<Value, String> {
            Err(UNSUPPORTED.into())
        }
        pub async fn unlink(&self) -> Result<Value, String> {
            Err(UNSUPPORTED.into())
        }
    }
}
