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
//! Test-implementation scope: linking + per-device presence records
//! only. Actual watch-list/viewpoint sync would ride the same store (or
//! an MLS group for stronger confidentiality) and is deliberately not
//! here yet. Desktop-only for now: the x0x tree is not yet proven under
//! the Android NDK, so Android builds get the stub at the bottom which
//! reports `supported: false`.

/// Invite string prefix; version-bumped if the format ever changes.
pub const INVITE_PREFIX: &str = "wtch1-";

/// Everything the routes call, real on desktop, stub elsewhere.
pub use imp::MyWatchStore;

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos"))]
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
        agent: x0x::Agent,
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
                }),
                dir,
                phase: Mutex::new(Phase::Off),
                message: std::sync::Mutex::new(None),
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
                agent,
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
                    let Ok(entries) = store.keys().await else { continue };
                    let mut changed = false;
                    for entry in entries {
                        if entry.key == own_key {
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

    /// Gossip topic for a link. Derived, so the raw invite secret never
    /// appears in topic-shaped places on the wire, and a future encrypted
    /// payload could key itself from the same secret independently.
    fn topic_for(secret_hex: &str) -> String {
        let mut hasher = blake3::Hasher::new();
        hasher.update(b"watchit mywatch v1 topic");
        hasher.update(secret_hex.as_bytes());
        format!("wtch-mywatch-{}", hasher.finalize().to_hex())
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

/// Android (and any other non-desktop) stub: same surface, everything
/// reports unsupported so the UI can say so instead of erroring blind.
#[cfg(not(any(target_os = "linux", target_os = "windows", target_os = "macos")))]
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
        pub async fn unlink(&self) -> Result<Value, String> {
            Err(UNSUPPORTED.into())
        }
    }
}
