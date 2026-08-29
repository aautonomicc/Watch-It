//! Channels: public, signed, updatable media lists ("a YouTube channel").
//!
//! The public half of the two content spaces (docs/
//! PLAN-personal-vs-channels.md; My W@tch is the private half). A channel
//! is an Ed25519 identity (channel.rs): its *manifest* — a
//! `.watch-list`-style zip plus `channel.json` — is uploaded PUBLICLY to
//! Autonomi (chunks + the serialized data map itself, so anyone holding
//! the address can fetch it), and the mutable "which manifest is
//! current" pointer travels as a signed head record `{seq, manifest,
//! sig}` in a self-keyed CRDT KV store on an x0x gossip topic derived
//! from the channel's public key. The topic is public by construction —
//! anyone with the `wchn1-` code derives it and joins — so head records
//! are trusted purely by signature: strangers can write into the store,
//! and everything not signed by the channel key is ignored. Subscribers
//! replicate the store, so a late joiner gets the newest head from any
//! online subscriber; the owner does not need to stay online.
//!
//! This store owns its own x0x agent (identity pinned under
//! `<data>/channels/`, separate from the My W@tch agent — the two links
//! have independent lifecycles) and one KV store handle per channel
//! (own + each subscription), with per-channel snapshot dirs so
//! unsubscribing can cleanly delete one channel's state.

pub use imp::ChannelStore;

#[cfg(any(
    target_os = "linux",
    target_os = "windows",
    target_os = "macos",
    target_os = "android"
))]
mod imp {
    use std::collections::HashMap;
    use std::path::{Path, PathBuf};
    use std::sync::Arc;
    use std::time::{SystemTime, UNIX_EPOCH};

    use serde_json::{json, Value};
    use tokio::sync::Mutex;

    use crate::channel;

    fn now_ms() -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0)
    }

    /// Persisted own-channel config (`<data>/channels/my.json`). The
    /// secret key is NOT here — it lives in the OS keychain / fallback
    /// file via the wallet store machinery.
    #[derive(Clone, Default)]
    struct OwnConfig {
        name: String,
        description: String,
        /// Display name or handle of whoever runs the channel. Optional —
        /// empty string means unset (description's convention).
        author: String,
        pubkey_hex: String,
        /// Highest sequence number this device has published.
        seq: u64,
        /// Manifest address of that publish (hex; empty before the first).
        manifest_hex: String,
        created_at_ms: u64,
    }

    struct Running {
        agent: Arc<x0x::Agent>,
        /// One store per channel topic, keyed by channel pubkey (hex).
        stores: HashMap<String, x0x::KvStoreHandle>,
    }

    enum Phase {
        Off,
        /// Config exists; agent/network still coming up (retrying).
        Starting,
        Ready(Running),
    }

    pub struct ChannelStore {
        dir: Option<PathBuf>,
        /// Channel signing key, keychain-first with file fallback —
        /// exactly the wallet key's storage rules.
        keys: crate::wallet::WalletStore,
        phase: Mutex<Phase>,
        /// Last startup problem, for the status UI.
        message: std::sync::Mutex<Option<String>>,
    }

    impl ChannelStore {
        pub fn new(data_dir: Option<&str>) -> Self {
            let dir = data_dir
                .filter(|d| !d.trim().is_empty())
                .map(|d| Path::new(d).join("channels"));
            Self {
                keys: crate::wallet::WalletStore::named(
                    dir.as_deref().and_then(Path::to_str),
                    true,
                    crate::wallet::CHANNEL_KEYCHAIN_USER,
                    crate::wallet::CHANNEL_KEY_FILE,
                ),
                dir,
                phase: Mutex::new(Phase::Off),
                message: std::sync::Mutex::new(None),
            }
        }

        /// Force the file backend (tests must never touch a real keychain).
        pub fn disable_keychain(&self) {
            self.keys.disable_keychain();
        }

        // ---- persistence ------------------------------------------------

        fn my_path(&self) -> Option<PathBuf> {
            self.dir.as_ref().map(|d| d.join("my.json"))
        }

        fn subs_path(&self) -> Option<PathBuf> {
            self.dir.as_ref().map(|d| d.join("subs.json"))
        }

        fn store_dir(&self, pubkey_hex: &str) -> Option<PathBuf> {
            // First 16 hex chars are plenty unique for a directory name.
            let short = pubkey_hex.get(..16).unwrap_or(pubkey_hex);
            self.dir.as_ref().map(|d| d.join("stores").join(short))
        }

        fn load_own(&self) -> Option<OwnConfig> {
            let text = std::fs::read_to_string(self.my_path()?).ok()?;
            let v: Value = serde_json::from_str(&text).ok()?;
            let pubkey_hex = v["pubkey"].as_str()?.to_string();
            Some(OwnConfig {
                name: v["name"].as_str().unwrap_or("").to_string(),
                description: v["description"].as_str().unwrap_or("").to_string(),
                author: v["author"].as_str().unwrap_or("").to_string(),
                pubkey_hex,
                seq: v["seq"].as_u64().unwrap_or(0),
                manifest_hex: v["manifest"].as_str().unwrap_or("").to_string(),
                created_at_ms: v["created_at_ms"].as_u64().unwrap_or(0),
            })
        }

        fn save_own(&self, cfg: &OwnConfig) -> Result<(), String> {
            let path = self.my_path().ok_or("no data dir available for Channels")?;
            if let Some(parent) = path.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            let body = json!({
                "name": cfg.name,
                "description": cfg.description,
                "author": cfg.author,
                "pubkey": cfg.pubkey_hex,
                "seq": cfg.seq,
                "manifest": cfg.manifest_hex,
                "created_at_ms": cfg.created_at_ms,
            })
            .to_string();
            std::fs::write(&path, body).map_err(|e| format!("channel save failed: {e}"))
        }

        fn load_subs(&self) -> Vec<String> {
            let Some(path) = self.subs_path() else { return Vec::new() };
            let Ok(text) = std::fs::read_to_string(path) else {
                return Vec::new();
            };
            let v: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
            v["subs"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|s| s.as_str())
                .filter(|s| s.len() == 64 && hex::decode(s).is_ok())
                .map(str::to_string)
                .collect()
        }

        fn save_subs(&self, subs: &[String]) -> Result<(), String> {
            let path = self
                .subs_path()
                .ok_or("no data dir available for Channels")?;
            if let Some(parent) = path.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            std::fs::write(&path, json!({ "subs": subs }).to_string())
                .map_err(|e| format!("subscription save failed: {e}"))
        }

        fn set_message(&self, msg: Option<String>) {
            *self.message.lock().unwrap() = msg;
        }

        /// Every channel this device should be joined to (own + subs).
        fn wanted_pubkeys(&self) -> Vec<String> {
            let mut keys: Vec<String> = self.load_subs();
            if let Some(own) = self.load_own() {
                if !keys.contains(&own.pubkey_hex) {
                    keys.push(own.pubkey_hex);
                }
            }
            keys
        }

        // ---- lifecycle --------------------------------------------------

        /// Resume on process start; a device with no channel state
        /// returns immediately.
        pub async fn autostart(&'static self) {
            if !self.wanted_pubkeys().is_empty() {
                self.ensure_running().await;
            }
        }

        /// Bring the agent up (retrying with backoff) and join every
        /// configured channel topic. Idempotent; concurrent callers
        /// coalesce on the Starting phase.
        async fn ensure_running(&'static self) {
            {
                let mut phase = self.phase.lock().await;
                match &*phase {
                    Phase::Ready(_) | Phase::Starting => return,
                    Phase::Off => *phase = Phase::Starting,
                }
            }
            tokio::spawn(async move {
                let mut backoff = std::time::Duration::from_secs(2);
                loop {
                    if self.wanted_pubkeys().is_empty() {
                        let mut phase = self.phase.lock().await;
                        if matches!(*phase, Phase::Starting) {
                            *phase = Phase::Off;
                        }
                        return;
                    }
                    match self.bring_up().await {
                        Ok(running) => {
                            self.set_message(None);
                            *self.phase.lock().await = Phase::Ready(running);
                            tracing::info!("channels agent up");
                            return;
                        }
                        Err(e) => {
                            tracing::warn!("channels start failed (will retry): {e}");
                            self.set_message(Some(e));
                            tokio::time::sleep(backoff).await;
                            backoff = (backoff * 2).min(std::time::Duration::from_secs(60));
                        }
                    }
                }
            });
        }

        async fn bring_up(&self) -> Result<Running, String> {
            let dir = self.dir.clone().ok_or("no data dir")?;
            let agent_dir = dir.join("x0x");
            let _ = std::fs::create_dir_all(&agent_dir);
            // Identity pinned inside our own dir: the My W@tch agent (and
            // a devserver on the same host) must not share machine keys
            // or peer caches with us.
            let agent = x0x::Agent::builder()
                .with_machine_key(agent_dir.join("machine.key"))
                .with_agent_key_path(agent_dir.join("agent.key"))
                .with_identity_dir(&agent_dir)
                .with_peer_cache_dir(agent_dir.join("peers"))
                .with_network_config(x0x::network::NetworkConfig::default())
                .build()
                .await
                .map_err(|e| format!("agent build failed: {e}"))?;
            agent
                .join_network()
                .await
                .map_err(|e| format!("network join failed: {e}"))?;
            let agent = Arc::new(agent);
            let mut stores = HashMap::new();
            for pubkey in self.wanted_pubkeys() {
                match self.join_channel_store(&agent, &pubkey).await {
                    Ok(store) => {
                        stores.insert(pubkey, store);
                    }
                    Err(e) => {
                        // One broken snapshot must not take every channel
                        // down; the status UI reports it.
                        tracing::warn!("channel {pubkey}: store join failed: {e}");
                        self.set_message(Some(format!("channel store join failed: {e}")));
                    }
                }
            }
            Ok(Running { agent, stores })
        }

        async fn join_channel_store(
            &self,
            agent: &x0x::Agent,
            pubkey_hex: &str,
        ) -> Result<x0x::KvStoreHandle, String> {
            let dir = self
                .store_dir(pubkey_hex)
                .ok_or("no data dir available for Channels")?;
            let _ = std::fs::create_dir_all(&dir);
            agent
                .join_self_keyed_kv_store_persistent(&topic_for(pubkey_hex), &dir)
                .await
                .map_err(|e| format!("channel store join failed: {e}"))
        }

        // ---- own channel ------------------------------------------------

        /// Create this device's channel from an already-ceremonied
        /// phrase: derive + store the key, persist the config, join the
        /// topic. Refused while a channel exists (one channel per device).
        pub async fn create(
            &'static self,
            name: &str,
            description: &str,
            author: &str,
            phrase: &str,
        ) -> Result<Value, String> {
            if self.load_own().is_some() {
                return Err("this device already has a channel — remove it first".into());
            }
            if self.dir.is_none() {
                return Err("no data dir available for Channels".into());
            }
            let name = name.trim();
            if name.is_empty() {
                return Err("channel name is required".into());
            }
            let secret = channel::secret_from_mnemonic(phrase)?;
            let pubkey_hex = channel::pubkey_of(&secret)?;
            let code = channel::code_from_pubkey_hex(&pubkey_hex)?;
            let storage = tokio::task::spawn_blocking(move || self.keys.store(&secret))
                .await
                .map_err(|e| e.to_string())??;
            self.save_own(&OwnConfig {
                name: name.chars().take(80).collect(),
                description: description.trim().chars().take(500).collect(),
                author: author.trim().chars().take(80).collect(),
                pubkey_hex: pubkey_hex.clone(),
                seq: 0,
                manifest_hex: String::new(),
                created_at_ms: now_ms(),
            })?;
            self.join_wanted(&pubkey_hex).await;
            Ok(json!({
                "code": code,
                "pubkey": pubkey_hex,
                "key_storage": storage.as_str(),
            }))
        }

        /// Restore a channel from its recovery phrase on a new machine:
        /// same key, same code, publishing resumes. The name/description/
        /// author are recovered from the fetched manifest by the app
        /// (`set_meta`) once the head arrives.
        pub async fn restore(&'static self, phrase: &str) -> Result<Value, String> {
            if self.load_own().is_some() {
                return Err("this device already has a channel — remove it first".into());
            }
            if self.dir.is_none() {
                return Err("no data dir available for Channels".into());
            }
            let secret = channel::secret_from_mnemonic(phrase)?;
            let pubkey_hex = channel::pubkey_of(&secret)?;
            let code = channel::code_from_pubkey_hex(&pubkey_hex)?;
            let storage = tokio::task::spawn_blocking(move || self.keys.store(&secret))
                .await
                .map_err(|e| e.to_string())??;
            self.save_own(&OwnConfig {
                name: String::new(),
                description: String::new(),
                author: String::new(),
                pubkey_hex: pubkey_hex.clone(),
                seq: 0,
                manifest_hex: String::new(),
                created_at_ms: now_ms(),
            })?;
            self.join_wanted(&pubkey_hex).await;
            Ok(json!({
                "code": code,
                "pubkey": pubkey_hex,
                "key_storage": storage.as_str(),
            }))
        }

        /// Update the locally displayed name/description/author (the
        /// canonical copy lives in the published manifest).
        pub async fn set_meta(
            &self,
            name: &str,
            description: &str,
            author: &str,
        ) -> Result<Value, String> {
            let mut own = self.load_own().ok_or("this device has no channel")?;
            let name = name.trim();
            if !name.is_empty() {
                own.name = name.chars().take(80).collect();
            }
            own.description = description.trim().chars().take(500).collect();
            own.author = author.trim().chars().take(80).collect();
            self.save_own(&own)?;
            Ok(json!({ "updated": true }))
        }

        /// Delete the channel key + config from this device. The channel
        /// itself lives on (subscribers keep following the last head);
        /// only the phrase can bring publishing back.
        pub async fn remove_own(&self) -> Result<Value, String> {
            let own = self.load_own().ok_or("this device has no channel")?;
            // Keychain access already runs on its own dedicated thread
            // inside the wallet store (zbus must never block a tokio
            // worker), so no spawn_blocking dance is needed here.
            self.keys.remove();
            if let Some(path) = self.my_path() {
                let _ = std::fs::remove_file(path);
            }
            // Drop the store handle unless a subscription still uses it.
            if !self.load_subs().contains(&own.pubkey_hex) {
                let mut phase = self.phase.lock().await;
                if let Phase::Ready(running) = &mut *phase {
                    if let Some(store) = running.stores.remove(&own.pubkey_hex) {
                        store.cancel_sync();
                    }
                }
                if let Some(dir) = self.store_dir(&own.pubkey_hex) {
                    let _ = std::fs::remove_dir_all(dir);
                }
            }
            Ok(json!({ "removed": true }))
        }

        /// The channel secret for signing, if this device has one.
        pub fn own_secret(&self) -> Option<String> {
            self.load_own()?;
            self.keys.load().map(|(secret, _)| secret)
        }

        pub fn has_own(&self) -> bool {
            self.load_own().is_some() && self.keys.load().is_some()
        }

        /// Sign and gossip a new head for [`manifest_hex`]; returns the
        /// sequence number it published. The next seq tops both what this
        /// device published before AND the newest head visible in the
        /// store, so a restored channel continues its history instead of
        /// re-issuing old numbers.
        pub async fn publish_head(&self, manifest_hex: &str) -> Result<Value, String> {
            let mut own = self.load_own().ok_or("this device has no channel")?;
            let (secret, _) = self.keys.load().ok_or("channel key is missing")?;
            let phase = self.phase.lock().await;
            let Phase::Ready(running) = &*phase else {
                return Err(match &*phase {
                    Phase::Off => "the channel link is not running".into(),
                    _ => "the channel link is still starting — try again shortly"
                        .to_string(),
                });
            };
            let store = running
                .stores
                .get(&own.pubkey_hex)
                .ok_or("the channel topic is not joined yet — try again shortly")?;
            let visible = best_head(store, &own.pubkey_hex)
                .await
                .map(|h| h.0)
                .unwrap_or(0);
            let seq = own.seq.max(visible) + 1;
            let sig = channel::sign_head(&secret, seq, manifest_hex)?;
            let record = json!({
                "wchn": "head",
                "v": 1,
                "pubkey": own.pubkey_hex,
                "seq": seq,
                "manifest": manifest_hex,
                "sig": sig,
                "updated_at_ms": now_ms(),
            });
            let key = hex::encode(running.agent.agent_id().as_bytes());
            store
                .put(key, record.to_string().into_bytes(), "application/json".into())
                .await
                .map_err(|e| format!("head publish failed: {e}"))?;
            own.seq = seq;
            own.manifest_hex = manifest_hex.to_string();
            self.save_own(&own)?;
            Ok(json!({ "seq": seq, "manifest": manifest_hex }))
        }

        // ---- subscriptions ----------------------------------------------

        /// Subscribe to a channel by its `wchn1-` code: join the topic
        /// store and persist the subscription. The head arrives via
        /// gossip; the app polls `status` for it.
        pub async fn subscribe(&'static self, code: &str) -> Result<Value, String> {
            let pubkey_hex = channel::pubkey_from_code(code)?;
            if self.dir.is_none() {
                return Err("no data dir available for Channels".into());
            }
            if let Some(own) = self.load_own() {
                if own.pubkey_hex == pubkey_hex {
                    return Err("that code is this device's own channel".into());
                }
            }
            let mut subs = self.load_subs();
            if subs.contains(&pubkey_hex) {
                return Err("already subscribed to that channel".into());
            }
            subs.push(pubkey_hex.clone());
            self.save_subs(&subs)?;
            self.join_wanted(&pubkey_hex).await;
            Ok(json!({ "pubkey": pubkey_hex }))
        }

        /// Drop a subscription and delete its replicated store state.
        pub async fn unsubscribe(&self, pubkey_hex: &str) -> Result<Value, String> {
            let pubkey_hex = pubkey_hex.trim().to_lowercase();
            let mut subs = self.load_subs();
            let before = subs.len();
            subs.retain(|s| s != &pubkey_hex);
            if subs.len() == before {
                return Err("not subscribed to that channel".into());
            }
            self.save_subs(&subs)?;
            let own_uses = self
                .load_own()
                .is_some_and(|own| own.pubkey_hex == pubkey_hex);
            if !own_uses {
                let mut phase = self.phase.lock().await;
                if let Phase::Ready(running) = &mut *phase {
                    if let Some(store) = running.stores.remove(&pubkey_hex) {
                        store.cancel_sync();
                    }
                }
                if let Some(dir) = self.store_dir(&pubkey_hex) {
                    let _ = std::fs::remove_dir_all(dir);
                }
            }
            Ok(json!({ "unsubscribed": true }))
        }

        /// Join [`pubkey_hex`]'s topic now if the agent is Ready, else
        /// kick the bring-up (which joins every wanted topic itself).
        async fn join_wanted(&'static self, pubkey_hex: &str) {
            {
                let mut phase = self.phase.lock().await;
                if let Phase::Ready(running) = &mut *phase {
                    if !running.stores.contains_key(pubkey_hex) {
                        let agent = Arc::clone(&running.agent);
                        match self.join_channel_store(&agent, pubkey_hex).await {
                            Ok(store) => {
                                running.stores.insert(pubkey_hex.to_string(), store);
                            }
                            Err(e) => {
                                tracing::warn!("channel {pubkey_hex}: join failed: {e}");
                                self.set_message(Some(e));
                            }
                        }
                    }
                    return;
                }
            }
            self.ensure_running().await;
        }

        // ---- status -----------------------------------------------------

        pub async fn status(&self) -> Value {
            let own = self.load_own();
            let subs = self.load_subs();
            let phase = self.phase.lock().await;
            let (state, running) = match &*phase {
                Phase::Off => (
                    if own.is_some() || !subs.is_empty() {
                        "starting"
                    } else {
                        "off"
                    },
                    None,
                ),
                Phase::Starting => ("starting", None),
                Phase::Ready(r) => ("ready", Some(r)),
            };
            let head_json = |head: Option<(u64, String)>| {
                head.map(|(seq, manifest)| json!({ "seq": seq, "manifest": manifest }))
                    .unwrap_or(Value::Null)
            };
            let mut sub_entries = Vec::new();
            for pubkey in &subs {
                let head = match running {
                    Some(r) => match r.stores.get(pubkey) {
                        Some(store) => best_head(store, pubkey).await,
                        None => None,
                    },
                    None => None,
                };
                sub_entries.push(json!({
                    "pubkey": pubkey,
                    "code": channel::code_from_pubkey_hex(pubkey).unwrap_or_default(),
                    "head": head_json(head),
                }));
            }
            let own_json = match &own {
                Some(cfg) => {
                    let head = match running {
                        Some(r) => match r.stores.get(&cfg.pubkey_hex) {
                            Some(store) => best_head(store, &cfg.pubkey_hex).await,
                            None => None,
                        },
                        None => None,
                    };
                    let key_storage = self.keys.load().map(|(_, s)| s.as_str());
                    json!({
                        "name": cfg.name,
                        "description": cfg.description,
                        "author": cfg.author,
                        "pubkey": cfg.pubkey_hex,
                        "code": channel::code_from_pubkey_hex(&cfg.pubkey_hex)
                            .unwrap_or_default(),
                        "seq": cfg.seq,
                        "manifest": cfg.manifest_hex,
                        "created_at_ms": cfg.created_at_ms,
                        "key_storage": key_storage,
                        "key_missing": key_storage.is_none(),
                        "head": head_json(head),
                    })
                }
                None => Value::Null,
            };
            json!({
                "supported": true,
                "state": state,
                "message": *self.message.lock().unwrap(),
                "own": own_json,
                "subs": sub_entries,
            })
        }
    }

    /// The newest head record in [`store`] that carries a valid signature
    /// from [`pubkey_hex`], as `(seq, manifest_hex)`. The store is public
    /// and self-keyed — anything unsigned or mis-signed is stranger junk
    /// and skipped.
    async fn best_head(
        store: &x0x::KvStoreHandle,
        pubkey_hex: &str,
    ) -> Option<(u64, String)> {
        let entries = store.keys().await.ok()?;
        let mut best: Option<(u64, String)> = None;
        for entry in entries {
            let Ok(v) = serde_json::from_slice::<Value>(&entry.value) else {
                continue;
            };
            if v["wchn"].as_str() != Some("head") {
                continue;
            }
            if v["pubkey"].as_str() != Some(pubkey_hex) {
                continue;
            }
            let (Some(seq), Some(manifest), Some(sig)) = (
                v["seq"].as_u64(),
                v["manifest"].as_str(),
                v["sig"].as_str(),
            ) else {
                continue;
            };
            if manifest.len() != 64 || hex::decode(manifest).is_err() {
                continue;
            }
            if !crate::channel::verify_head(pubkey_hex, seq, manifest, sig) {
                continue;
            }
            if best.as_ref().is_none_or(|(s, _)| seq > *s) {
                best = Some((seq, manifest.to_string()));
            }
        }
        best
    }

    /// Gossip topic for a channel. Derived from the public key with its
    /// own domain tag — public by construction (anyone with the code can
    /// compute it), just namespaced away from every other topic scheme.
    fn topic_for(pubkey_hex: &str) -> String {
        let mut hasher = blake3::Hasher::new();
        hasher.update(b"watchit channel v1 topic");
        hasher.update(pubkey_hex.as_bytes());
        format!("wtch-channel-{}", hasher.finalize().to_hex())
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn topic_is_stable_and_domain_separated() {
            let a = topic_for(&"aa".repeat(32));
            assert_eq!(a, topic_for(&"aa".repeat(32)));
            assert_ne!(a, topic_for(&"bb".repeat(32)));
            assert!(a.starts_with("wtch-channel-"));
        }

        fn test_store(name: &str) -> ChannelStore {
            let dir = std::env::temp_dir()
                .join(format!("wi-channels-{name}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&dir);
            let store = ChannelStore::new(dir.to_str());
            store.disable_keychain();
            store
        }

        #[tokio::test]
        async fn own_config_round_trips() {
            let store = test_store("own");
            assert!(store.load_own().is_none());
            store
                .save_own(&OwnConfig {
                    name: "My Films".into(),
                    description: "d".into(),
                    author: "@neil".into(),
                    pubkey_hex: "ab".repeat(32),
                    seq: 4,
                    manifest_hex: "cd".repeat(32),
                    created_at_ms: 123,
                })
                .unwrap();
            let own = store.load_own().unwrap();
            assert_eq!(own.name, "My Films");
            assert_eq!(own.author, "@neil");
            assert_eq!(own.seq, 4);
            assert_eq!(own.manifest_hex, "cd".repeat(32));
            // set_meta trims + keeps name when blank; author follows the
            // given value (empty clears — it is optional).
            store.set_meta("", "new description", " Neil ").await.unwrap();
            let own = store.load_own().unwrap();
            assert_eq!(own.name, "My Films");
            assert_eq!(own.description, "new description");
            assert_eq!(own.author, "Neil");
            store.set_meta("", "new description", "").await.unwrap();
            assert_eq!(store.load_own().unwrap().author, "");
        }

        #[tokio::test]
        async fn author_caps_at_80_and_old_config_reads_unset() {
            let store = test_store("author");
            // A pre-author my.json (no "author" key) loads as unset.
            let path = store.my_path().unwrap();
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(
                &path,
                json!({ "name": "Old", "pubkey": "ab".repeat(32) }).to_string(),
            )
            .unwrap();
            assert_eq!(store.load_own().unwrap().author, "");
            store.set_meta("Old", "", &"x".repeat(200)).await.unwrap();
            assert_eq!(store.load_own().unwrap().author.chars().count(), 80);
        }

        #[tokio::test]
        async fn subs_persist_and_unsubscribe_validates() {
            let store = test_store("subs");
            assert!(store.load_subs().is_empty());
            store.save_subs(&["ab".repeat(32)]).unwrap();
            assert_eq!(store.load_subs(), vec!["ab".repeat(32)]);
            // Unknown pubkey refuses; known one removes.
            assert!(store.unsubscribe(&"ff".repeat(32)).await.is_err());
            store.unsubscribe(&"ab".repeat(32)).await.unwrap();
            assert!(store.load_subs().is_empty());
        }

        #[tokio::test]
        async fn status_off_when_nothing_configured() {
            let store = test_store("status");
            let v = store.status().await;
            assert_eq!(v["supported"], serde_json::json!(true));
            assert_eq!(v["state"], serde_json::json!("off"));
            assert!(v["own"].is_null());
            assert_eq!(v["subs"].as_array().unwrap().len(), 0);
        }
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

    const UNSUPPORTED: &str = "Channels are not available on this platform yet";

    pub struct ChannelStore;

    impl ChannelStore {
        pub fn new(_data_dir: Option<&str>) -> Self {
            Self
        }
        pub fn disable_keychain(&self) {}
        pub async fn autostart(&'static self) {}
        pub async fn status(&self) -> Value {
            json!({ "supported": false, "state": "off", "own": null, "subs": [] })
        }
        pub async fn create(
            &'static self,
            _n: &str,
            _d: &str,
            _a: &str,
            _p: &str,
        ) -> Result<Value, String> {
            Err(UNSUPPORTED.into())
        }
        pub async fn restore(&'static self, _p: &str) -> Result<Value, String> {
            Err(UNSUPPORTED.into())
        }
        pub async fn set_meta(
            &self,
            _n: &str,
            _d: &str,
            _a: &str,
        ) -> Result<Value, String> {
            Err(UNSUPPORTED.into())
        }
        pub async fn remove_own(&self) -> Result<Value, String> {
            Err(UNSUPPORTED.into())
        }
        pub fn own_secret(&self) -> Option<String> {
            None
        }
        pub fn has_own(&self) -> bool {
            false
        }
        pub async fn publish_head(&self, _m: &str) -> Result<Value, String> {
            Err(UNSUPPORTED.into())
        }
        pub async fn subscribe(&'static self, _c: &str) -> Result<Value, String> {
            Err(UNSUPPORTED.into())
        }
        pub async fn unsubscribe(&self, _p: &str) -> Result<Value, String> {
            Err(UNSUPPORTED.into())
        }
    }
}
