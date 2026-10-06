//! Seed-phrase backup: the full W@tch state published to Autonomi under
//! keys derived OFFLINE from the upload wallet's private key, so a fresh
//! install restores from the 12 words alone (docs/ROADMAP.md, plan
//! adopted 2026-10-06).
//!
//! Shape: a content-addressed encrypted object store. Every object
//! (the sync-doc-shaped state document, the root-map bundle, each
//! artwork file) is encrypted DETERMINISTICALLY — key and nonce derive
//! from the backup key and the object's own content hash — so an
//! unchanged object is byte-identical ciphertext, lands on the identical
//! network chunks, and re-backups are nearly free via chunk dedup. A
//! manifest lists the objects (each with its private shrunk data map);
//! the manifest's map rides inside an encrypted HEAD chunk (which also
//! links the previous head — a free walkable history), and an ML-DSA
//! pointer (`autonomi.pointer.address.v1` over the derived owner key)
//! targets the head. Nothing about the backup is plaintext on the
//! network except the pointer record itself; the pointer address is
//! underivable without the seed.
//!
//! Reading is free (no wallet needed): restore = derive → pointer_get →
//! head chunk → manifest → objects. Writing is paid from the upload
//! wallet, so backups only run on a wallet-holding device.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use ant_core::data::{
    ml_dsa_65, pointer_address, DataMap, MlDsaPublicKey, MlDsaSecretKey,
    PointerTarget, PointerTargetKind,
};
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine as _;
use bytes::Bytes;
use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use rand::RngCore;
use crate::engine::Engine;

// Key-derivation domains. NEVER change released domain strings: they are
// the backup identity — a change orphans every existing backup.
const DOMAIN_POINTER: &str = "watchit.backup.pointer.v1";
const DOMAIN_ENC: &str = "watchit.backup.enc.v1";
const DOMAIN_OBJECT_KEY: &str = "watchit.backup.object-key.v1";
const DOMAIN_OBJECT_NONCE: &str = "watchit.backup.object-nonce.v1";
const DOMAIN_ENVELOPE: &str = "watchit.backup.envelope.v1";

/// Artwork files above this are skipped (mirrors the Dart-side
/// `MyWatchSync.maxArtBytes` and the x0x art-transfer cap).
pub const MAX_ART_BYTES: u64 = 10 * 1024 * 1024;

/// The keys one wallet key derives: pointer owner pair, content key, and
/// the pointer address every backup of this identity lives under.
pub struct BackupKeys {
    pub sk: MlDsaSecretKey,
    pub pk: MlDsaPublicKey,
    pub enc: [u8; 32],
    pub pointer: [u8; 32],
}

/// Derive the backup identity from the wallet's private key (the exact
/// bytes the 12 words produce at m/44'/60'/0'/0/0 — both wallet import
/// paths land here, so both restore the same backup).
pub fn derive_keys(wallet_key_hex: &str) -> Result<BackupKeys, String> {
    let cleaned = wallet_key_hex.trim().trim_start_matches("0x");
    let bytes = hex::decode(cleaned)
        .map_err(|_| "wallet key is not valid hex".to_string())?;
    if bytes.len() != 32 {
        return Err("wallet key must be 32 bytes".into());
    }
    let seed = blake3::derive_key(DOMAIN_POINTER, &bytes);
    let (pk, sk) = ml_dsa_65().generate_keypair_from_seed(&seed);
    let enc = blake3::derive_key(DOMAIN_ENC, &bytes);
    let pointer = pointer_address(&pk);
    Ok(BackupKeys { sk, pk, enc, pointer })
}

/// blake3 content hash of an object's plaintext — the object's identity
/// in the manifest and the input to its deterministic cipher.
pub fn object_hash(plain: &[u8]) -> String {
    blake3::hash(plain).to_hex().to_string()
}

fn object_cipher(enc: &[u8; 32], hash_hex: &str) -> (ChaCha20Poly1305, Nonce) {
    let mut material = Vec::with_capacity(32 + hash_hex.len());
    material.extend_from_slice(enc);
    material.extend_from_slice(hash_hex.as_bytes());
    let key = blake3::derive_key(DOMAIN_OBJECT_KEY, &material);
    let nonce_full = blake3::derive_key(DOMAIN_OBJECT_NONCE, &material);
    let mut nonce = Nonce::default();
    nonce.copy_from_slice(&nonce_full[..12]);
    (ChaCha20Poly1305::new(Key::from_slice(&key)), nonce)
}

/// Deterministic seal: same plaintext (under the same backup key) is
/// byte-identical ciphertext — the convergent-encryption property the
/// chunk-dedup economy rests on. The equality leak is visible only to
/// the seed holder (key and nonce derive from the secret enc key).
pub fn seal_object(enc: &[u8; 32], plain: &[u8]) -> (String, Vec<u8>) {
    let hash = object_hash(plain);
    let (cipher, nonce) = object_cipher(enc, &hash);
    let ct = cipher
        .encrypt(&nonce, plain)
        .expect("ChaCha20-Poly1305 encryption is infallible for in-memory data");
    (hash, ct)
}

/// Open an object sealed by [seal_object]; the decrypted bytes must hash
/// back to [hash_hex] (belt and braces on top of the AEAD tag).
pub fn open_object(
    enc: &[u8; 32],
    hash_hex: &str,
    ciphertext: &[u8],
) -> Result<Vec<u8>, String> {
    let (cipher, nonce) = object_cipher(enc, hash_hex);
    let plain = cipher
        .decrypt(&nonce, ciphertext)
        .map_err(|_| "backup object failed to decrypt (wrong key or corrupted data)")?;
    if object_hash(&plain) != hash_hex.to_lowercase() {
        return Err("backup object content does not match its hash".into());
    }
    Ok(plain)
}

/// Seal the head/manifest envelopes: fresh random nonce (prepended) —
/// these change every backup, so determinism buys nothing there.
pub fn seal_envelope(enc: &[u8; 32], plain: &[u8]) -> Vec<u8> {
    let key = blake3::derive_key(DOMAIN_ENVELOPE, enc);
    let cipher = ChaCha20Poly1305::new(Key::from_slice(&key));
    let mut nonce_bytes = [0u8; 12];
    rand::thread_rng().fill_bytes(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);
    let ct = cipher
        .encrypt(nonce, plain)
        .expect("ChaCha20-Poly1305 encryption is infallible for in-memory data");
    let mut out = Vec::with_capacity(12 + ct.len());
    out.extend_from_slice(&nonce_bytes);
    out.extend_from_slice(&ct);
    out
}

pub fn open_envelope(enc: &[u8; 32], data: &[u8]) -> Result<Vec<u8>, String> {
    if data.len() < 13 {
        return Err("backup envelope too short".into());
    }
    let key = blake3::derive_key(DOMAIN_ENVELOPE, enc);
    let cipher = ChaCha20Poly1305::new(Key::from_slice(&key));
    cipher
        .decrypt(Nonce::from_slice(&data[..12]), &data[12..])
        .map_err(|_| {
            "backup envelope failed to decrypt (wrong seed phrase, or corrupted data)"
                .to_string()
        })
}

/// Only plain file names may be written on a backup's say-so — mirrors
/// the Dart `safeArtFileName` rule.
pub fn safe_art_file_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 151
        && !name.contains("..")
        && !name.starts_with('.')
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

// ---- persisted local state -------------------------------------------

/// `backup_state.json` beside the other app state: which object hashes
/// already uploaded (hash → shrunk map + size, so unchanged objects skip
/// the network entirely) plus the last backup's summary for the UI.
#[derive(Default)]
struct BackupState {
    objects: BTreeMap<String, (String, u64)>,
    last: Option<serde_json::Value>,
}

impl BackupState {
    fn load(path: &PathBuf) -> Self {
        let Ok(text) = std::fs::read_to_string(path) else {
            return Self::default();
        };
        let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) else {
            return Self::default();
        };
        let mut objects = BTreeMap::new();
        if let Some(map) = v.get("objects").and_then(|o| o.as_object()) {
            for (hash, entry) in map {
                let (Some(map_b64), Some(size)) = (
                    entry.get("map").and_then(|m| m.as_str()),
                    entry.get("size").and_then(|s| s.as_u64()),
                ) else {
                    continue;
                };
                objects.insert(hash.clone(), (map_b64.to_string(), size));
            }
        }
        Self { objects, last: v.get("last").cloned().filter(|l| !l.is_null()) }
    }

    fn save(&self, path: &PathBuf) {
        let mut objects = serde_json::Map::new();
        for (hash, (map_b64, size)) in &self.objects {
            objects.insert(
                hash.clone(),
                serde_json::json!({"map": map_b64, "size": size}),
            );
        }
        let out = serde_json::json!({
            "objects": objects,
            "last": self.last,
        });
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Err(e) = std::fs::write(path, out.to_string()) {
            tracing::warn!("backup state save failed: {e}");
        }
    }
}

// ---- job management ----------------------------------------------------

#[derive(Clone)]
pub struct JobState {
    /// "backup" | "restore"
    pub kind: &'static str,
    /// deriving → packing → uploading → manifest → head → pointer → done
    /// (backup); deriving → locating → fetching → importing → done
    /// (restore); either ends in `error`.
    pub phase: String,
    pub done: usize,
    pub total: usize,
    pub error: Option<String>,
    pub result: Option<serde_json::Value>,
}

impl JobState {
    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "kind": self.kind,
            "phase": self.phase,
            "done": self.done,
            "total": self.total,
            "error": self.error,
            "result": self.result,
        })
    }
}

/// One backup or restore at a time (both spend network rounds; backups
/// spend money). The finished job's state stays readable until the next
/// one starts.
pub struct BackupManager {
    state_path: Option<PathBuf>,
    job: Mutex<Option<Arc<Mutex<JobState>>>>,
    active: AtomicBool,
}

impl BackupManager {
    pub fn new(data_dir: Option<&str>) -> Self {
        Self {
            state_path: data_dir
                .filter(|d| !d.trim().is_empty())
                .map(|d| PathBuf::from(d).join("backup_state.json")),
            job: Mutex::new(None),
            active: AtomicBool::new(false),
        }
    }

    pub fn job_json(&self) -> Option<serde_json::Value> {
        let job = self.job.lock().unwrap().clone()?;
        let state = job.lock().unwrap().clone();
        Some(state.to_json())
    }

    fn state(&self) -> BackupState {
        self.state_path
            .as_ref()
            .map(|p| BackupState::load(p))
            .unwrap_or_default()
    }

    fn save_state(&self, state: &BackupState) {
        if let Some(p) = &self.state_path {
            state.save(p);
        }
    }

    pub fn last_json(&self) -> Option<serde_json::Value> {
        self.state().last
    }

    fn begin(
        &self,
        kind: &'static str,
        phase: &str,
    ) -> Result<Arc<Mutex<JobState>>, String> {
        if self.active.swap(true, Ordering::SeqCst) {
            return Err("a backup or restore is already running — wait for it to finish".into());
        }
        let job = Arc::new(Mutex::new(JobState {
            kind,
            phase: phase.to_string(),
            done: 0,
            total: 0,
            error: None,
            result: None,
        }));
        *self.job.lock().unwrap() = Some(job.clone());
        Ok(job)
    }
}

fn set_phase(job: &Arc<Mutex<JobState>>, phase: &str) {
    job.lock().unwrap().phase = phase.to_string();
}

fn set_progress(job: &Arc<Mutex<JobState>>, done: usize, total: usize) {
    let mut s = job.lock().unwrap();
    s.done = done;
    s.total = total;
}

// ---- backup ------------------------------------------------------------

/// One object headed for the store: a label (for errors), its plaintext,
/// and — for artwork — the file name the manifest records.
struct PendingObject {
    label: String,
    art_file: Option<String>,
    plain: Vec<u8>,
}

impl Engine {
    /// Kick off a backup. `input` is the app-assembled payload:
    /// `{"doc": {...}, "art": [{"file","path"}...], "map_addrs": [...]}`.
    pub fn start_backup(&'static self, input: serde_json::Value) -> Result<(), String> {
        let Some((key_hex, _)) = self.wallet.load() else {
            return Err(
                "no upload wallet configured — the backup identity derives from \
                 its 12 words (Settings → Wallet)"
                    .into(),
            );
        };
        if input.get("doc").and_then(|d| d.as_object()).is_none() {
            return Err("backup payload needs a \"doc\" object".into());
        }
        let job = self.backups.begin("backup", "deriving")?;
        tokio::spawn(run_backup(self, job, key_hex, input));
        Ok(())
    }

    /// Kick off a restore. Reads are free: `key_hex` (a pasted wallet
    /// key, for fresh installs restoring before importing the wallet) or
    /// the stored wallet provide the identity; decrypted artwork lands in
    /// `art_dir` for the app to sort into place.
    pub fn start_restore(
        &'static self,
        key_hex: Option<String>,
        art_dir: String,
    ) -> Result<(), String> {
        let key = match key_hex {
            Some(k) => crate::wallet::normalize_private_key(&k)?,
            None => {
                self.wallet
                    .load()
                    .ok_or("no wallet on this device — paste the wallet key, or import \
                            the 12 words in Settings → Wallet first")?
                    .0
            }
        };
        if art_dir.trim().is_empty() {
            return Err("restore needs an art_dir".into());
        }
        let job = self.backups.begin("restore", "deriving")?;
        tokio::spawn(run_restore(self, job, key, art_dir));
        Ok(())
    }
}

async fn run_backup(
    engine: &'static Engine,
    job: Arc<Mutex<JobState>>,
    key_hex: String,
    input: serde_json::Value,
) {
    let outcome = drive_backup(engine, &job, &key_hex, &input).await;
    {
        let mut s = job.lock().unwrap();
        match outcome {
            Ok(result) => {
                s.phase = "done".into();
                s.result = Some(result);
            }
            Err(e) => {
                s.phase = "error".into();
                s.error = Some(e);
            }
        }
    }
    engine.backups.active.store(false, Ordering::SeqCst);
}

async fn drive_backup(
    engine: &'static Engine,
    job: &Arc<Mutex<JobState>>,
    key_hex: &str,
    input: &serde_json::Value,
) -> Result<serde_json::Value, String> {
    let keys = derive_keys(key_hex)?;
    let now_ms = chrono::Utc::now().timestamp_millis();

    // -- pack the objects ------------------------------------------------
    set_phase(job, "packing");
    let mut objects = Vec::<PendingObject>::new();
    let mut skipped = Vec::<String>::new();

    let doc = input.get("doc").cloned().unwrap_or(serde_json::json!({}));
    let doc_bytes = serde_json::to_vec(&doc)
        .map_err(|e| format!("state document serialize failed: {e}"))?;
    objects.push(PendingObject {
        label: "state document".into(),
        art_file: None,
        plain: doc_bytes,
    });

    // Root maps: bincode-serialized ROOT maps (not shrunk) so a restore
    // imports them fully offline — no per-entry network expansion.
    let mut maps = serde_json::Map::new();
    let mut maps_missing = 0usize;
    for addr_hex in input
        .get("map_addrs")
        .and_then(|a| a.as_array())
        .map(|a| a.as_slice())
        .unwrap_or(&[])
    {
        let Some(addr_hex) = addr_hex.as_str() else { continue };
        let Ok(bytes) = hex::decode(addr_hex) else { continue };
        let Ok(addr) = <[u8; 32]>::try_from(bytes.as_slice()) else { continue };
        match engine.stored_root_map(&addr) {
            Some(root) => {
                let raw = root
                    .to_bytes()
                    .map_err(|e| format!("map encode failed: {e}"))?;
                maps.insert(
                    addr_hex.to_lowercase(),
                    serde_json::Value::String(B64.encode(raw)),
                );
            }
            None => maps_missing += 1,
        }
    }
    let have_maps = !maps.is_empty();
    if have_maps {
        let maps_bytes = serde_json::to_vec(&serde_json::Value::Object(maps))
            .map_err(|e| format!("map bundle serialize failed: {e}"))?;
        objects.push(PendingObject {
            label: "data maps".into(),
            art_file: None,
            plain: maps_bytes,
        });
    }

    for art in input
        .get("art")
        .and_then(|a| a.as_array())
        .map(|a| a.as_slice())
        .unwrap_or(&[])
    {
        let (Some(file), Some(path)) = (
            art.get("file").and_then(|f| f.as_str()),
            art.get("path").and_then(|p| p.as_str()),
        ) else {
            continue;
        };
        if !safe_art_file_name(file) {
            skipped.push(format!("{file} (unsafe name)"));
            continue;
        }
        match std::fs::read(path) {
            Ok(bytes) if bytes.len() as u64 <= MAX_ART_BYTES && bytes.len() >= 3 => {
                objects.push(PendingObject {
                    label: file.to_string(),
                    art_file: Some(file.to_string()),
                    plain: bytes,
                });
            }
            Ok(_) => skipped.push(format!("{file} (size)")),
            Err(_) => skipped.push(format!("{file} (unreadable)")),
        }
    }

    // -- upload what the store does not already hold ----------------------
    let client = crate::upload::wallet_client(engine).await?;
    let mut state = engine.backups.state();
    let total = objects.len();
    set_phase(job, "uploading");
    set_progress(job, 0, total);
    let mut uploaded = 0usize;
    let mut manifest_objects = serde_json::Map::new();
    let mut doc_hash = String::new();
    let mut maps_hash: Option<String> = None;
    let mut art_entries = Vec::<serde_json::Value>::new();

    for (i, obj) in objects.iter().enumerate() {
        let hash = object_hash(&obj.plain);
        let known = state.objects.get(&hash).cloned();
        let (map_b64, size) = match known {
            Some(hit) => hit,
            None => {
                let (sealed_hash, ciphertext) = seal_object(&keys.enc, &obj.plain);
                debug_assert_eq!(sealed_hash, hash);
                let result = client
                    .data_upload(Bytes::from(ciphertext))
                    .await
                    .map_err(|e| format!("uploading {} failed: {e}", obj.label))?;
                let map_bytes = rmp_serde::to_vec(&result.data_map)
                    .map_err(|e| format!("map encode failed: {e}"))?;
                uploaded += 1;
                let entry = (B64.encode(map_bytes), obj.plain.len() as u64);
                state.objects.insert(hash.clone(), entry.clone());
                // Save after every upload: a crashed backup resumes free.
                engine.backups.save_state(&state);
                entry
            }
        };
        manifest_objects.insert(
            hash.clone(),
            serde_json::json!({"map": map_b64, "size": size}),
        );
        match (&obj.art_file, i) {
            (Some(file), _) => {
                art_entries.push(serde_json::json!({"file": file, "hash": hash}))
            }
            (None, 0) => doc_hash = hash.clone(),
            (None, _) => maps_hash = Some(hash.clone()),
        }
        set_progress(job, i + 1, total);
    }

    // -- manifest → head chunk → pointer ----------------------------------
    set_phase(job, "manifest");
    let manifest = serde_json::json!({
        "v": 1,
        "created_ms": now_ms,
        "objects": manifest_objects,
        "doc": doc_hash,
        "maps": maps_hash,
        "art": art_entries,
    });
    let manifest_ct = seal_envelope(
        &keys.enc,
        &serde_json::to_vec(&manifest).map_err(|e| e.to_string())?,
    );
    let manifest_map = client
        .data_upload(Bytes::from(manifest_ct))
        .await
        .map_err(|e| format!("uploading the backup manifest failed: {e}"))?
        .data_map;
    let manifest_map_b64 = B64.encode(
        rmp_serde::to_vec(&manifest_map).map_err(|e| e.to_string())?,
    );

    set_phase(job, "head");
    let prev = state
        .last
        .as_ref()
        .and_then(|l| l.get("head").and_then(|h| h.as_str()))
        .map(str::to_string);
    let backups_count = state
        .last
        .as_ref()
        .and_then(|l| l.get("backups").and_then(|b| b.as_u64()))
        .unwrap_or(0)
        + 1;
    let head = serde_json::json!({
        "v": 1,
        "created_ms": now_ms,
        "manifest": manifest_map_b64,
        "prev": prev,
        "backups": backups_count,
    });
    let head_ct = seal_envelope(
        &keys.enc,
        &serde_json::to_vec(&head).map_err(|e| e.to_string())?,
    );
    let head_addr = client
        .chunk_put(Bytes::from(head_ct))
        .await
        .map_err(|e| format!("storing the backup head failed: {e}"))?;

    set_phase(job, "pointer");
    client
        .pointer_update(
            &keys.sk,
            &keys.pk,
            PointerTarget::new(PointerTargetKind::Chunk, head_addr),
        )
        .await
        .map_err(|e| format!("updating the backup pointer failed: {e}"))?;

    let summary = serde_json::json!({
        "ms": now_ms,
        "head": hex::encode(head_addr),
        "pointer": hex::encode(keys.pointer),
        "backups": backups_count,
        "objects": total,
        "uploaded": uploaded,
        "maps_missing": maps_missing,
        "skipped": skipped,
    });
    state.last = Some(summary.clone());
    engine.backups.save_state(&state);
    tracing::info!(
        "backup #{backups_count} published: {total} objects ({uploaded} uploaded), \
         head {}",
        hex::encode(head_addr)
    );
    Ok(summary)
}

// ---- restore -------------------------------------------------------------

async fn run_restore(
    engine: &'static Engine,
    job: Arc<Mutex<JobState>>,
    key_hex: String,
    art_dir: String,
) {
    let outcome = drive_restore(engine, &job, &key_hex, &art_dir).await;
    {
        let mut s = job.lock().unwrap();
        match outcome {
            Ok(result) => {
                s.phase = "done".into();
                s.result = Some(result);
            }
            Err(e) => {
                s.phase = "error".into();
                s.error = Some(e);
            }
        }
    }
    engine.backups.active.store(false, Ordering::SeqCst);
}

/// Fetch and decrypt one object blob by its manifest entry.
async fn fetch_blob(
    engine: &'static Engine,
    client: &Arc<ant_core::data::Client>,
    map_b64: &str,
) -> Result<Vec<u8>, String> {
    let map_bytes = B64
        .decode(map_b64)
        .map_err(|_| "manifest holds an invalid data map".to_string())?;
    let map: DataMap = rmp_serde::from_slice(&map_bytes)
        .map_err(|_| "manifest holds an undecodable data map".to_string())?;
    let root = if map.is_child() {
        engine.expand_child_map(map).await?
    } else {
        map
    };
    client
        .data_download(&root)
        .await
        .map(|b| b.to_vec())
        .map_err(|e| format!("fetch failed: {e}"))
}

async fn drive_restore(
    engine: &'static Engine,
    job: &Arc<Mutex<JobState>>,
    key_hex: &str,
    art_dir: &str,
) -> Result<serde_json::Value, String> {
    let keys = derive_keys(key_hex)?;
    set_phase(job, "locating");
    let client = engine.client().await?;

    let pointer = client
        .pointer_get(&keys.pointer)
        .await
        .map_err(|e| format!("backup lookup failed: {e}"))?
        .ok_or(
            "no backup found for this wallet — nothing has been backed up under \
             these 12 words yet",
        )?;
    let head_addr = pointer.target().address;
    let head_chunk = client
        .chunk_get(&head_addr)
        .await
        .map_err(|e| format!("backup head fetch failed: {e}"))?
        .ok_or("the backup head is not reachable right now — try again later")?;
    let head: serde_json::Value =
        serde_json::from_slice(&open_envelope(&keys.enc, &head_chunk.content)?)
            .map_err(|_| "backup head is not valid".to_string())?;

    let manifest_map = head
        .get("manifest")
        .and_then(|m| m.as_str())
        .ok_or("backup head carries no manifest")?;
    let manifest: serde_json::Value = serde_json::from_slice(&open_envelope(
        &keys.enc,
        &fetch_blob(engine, &client, manifest_map).await?,
    )?)
    .map_err(|_| "backup manifest is not valid".to_string())?;

    let objects = manifest
        .get("objects")
        .and_then(|o| o.as_object())
        .ok_or("backup manifest lists no objects")?;
    let object_map = |hash: &str| -> Option<String> {
        objects
            .get(hash)
            .and_then(|o| o.get("map"))
            .and_then(|m| m.as_str())
            .map(str::to_string)
    };

    let art_list: Vec<(String, String)> = manifest
        .get("art")
        .and_then(|a| a.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|e| {
                    Some((
                        e.get("file")?.as_str()?.to_string(),
                        e.get("hash")?.as_str()?.to_string(),
                    ))
                })
                .collect()
        })
        .unwrap_or_default();

    // Fetch plan: doc + maps + art.
    let maps_hash = manifest.get("maps").and_then(|m| m.as_str());
    let total = 1 + usize::from(maps_hash.is_some()) + art_list.len();
    set_phase(job, "fetching");
    set_progress(job, 0, total);
    let mut done = 0usize;

    let doc_hash = manifest
        .get("doc")
        .and_then(|d| d.as_str())
        .ok_or("backup manifest names no state document")?;
    let doc_map = object_map(doc_hash).ok_or("state document missing from manifest")?;
    let doc_bytes = open_object(
        &keys.enc,
        doc_hash,
        &fetch_blob(engine, &client, &doc_map).await?,
    )?;
    let doc: serde_json::Value = serde_json::from_slice(&doc_bytes)
        .map_err(|_| "backup state document is not valid".to_string())?;
    done += 1;
    set_progress(job, done, total);

    // Root maps straight into the local map store (verified), so every
    // restored entry is playable.
    let mut maps_imported = 0usize;
    let mut maps_failed = 0usize;
    if let Some(mh) = maps_hash {
        if let Some(mm) = object_map(mh) {
            let bytes = open_object(
                &keys.enc,
                mh,
                &fetch_blob(engine, &client, &mm).await?,
            )?;
            done += 1;
            set_progress(job, done, total);
            set_phase(job, "importing");
            if let Ok(serde_json::Value::Object(entries)) =
                serde_json::from_slice::<serde_json::Value>(&bytes)
            {
                for (addr_hex, map_b64) in entries {
                    let imported = (|| -> Result<(), String> {
                        let addr_bytes =
                            hex::decode(&addr_hex).map_err(|_| "bad addr".to_string())?;
                        let addr = <[u8; 32]>::try_from(addr_bytes.as_slice())
                            .map_err(|_| "bad addr".to_string())?;
                        let raw = B64
                            .decode(map_b64.as_str().unwrap_or_default())
                            .map_err(|_| "bad map".to_string())?;
                        let root = DataMap::from_bytes(&raw)
                            .map_err(|_| "bad map".to_string())?;
                        engine.import_root_map(addr, root)
                    })();
                    match imported {
                        Ok(()) => maps_imported += 1,
                        Err(_) => maps_failed += 1,
                    }
                }
            }
            set_phase(job, "fetching");
        }
    }

    // Artwork into the staging dir the app empties into place.
    let dir = std::path::Path::new(art_dir);
    let _ = std::fs::create_dir_all(dir);
    let mut art_files = Vec::<serde_json::Value>::new();
    let mut art_failed = 0usize;
    for (file, hash) in &art_list {
        done += 1;
        if !safe_art_file_name(file) {
            art_failed += 1;
            continue;
        }
        let Some(map_b64) = object_map(hash) else {
            art_failed += 1;
            continue;
        };
        let fetched = fetch_blob(engine, &client, &map_b64)
            .await
            .and_then(|ct| open_object(&keys.enc, hash, &ct));
        match fetched {
            Ok(bytes) => {
                if std::fs::write(dir.join(file), &bytes).is_ok() {
                    art_files.push(serde_json::Value::String(file.clone()));
                } else {
                    art_failed += 1;
                }
            }
            Err(e) => {
                tracing::warn!("backup art {file} fetch failed: {e}");
                art_failed += 1;
            }
        }
        set_progress(job, done, total);
    }

    // When this device's own wallet IS the backup identity, warm the
    // local object cache so its next backup skips re-uploading anything
    // the restored backup already holds.
    if let Some((stored_key, _)) = engine.wallet.load() {
        if let Ok(stored) = derive_keys(&stored_key) {
            if stored.pointer == keys.pointer {
                let mut state = engine.backups.state();
                for (hash, entry) in objects {
                    let (Some(map_b64), Some(size)) = (
                        entry.get("map").and_then(|m| m.as_str()),
                        entry.get("size").and_then(|s| s.as_u64()),
                    ) else {
                        continue;
                    };
                    state
                        .objects
                        .entry(hash.clone())
                        .or_insert((map_b64.to_string(), size));
                }
                engine.backups.save_state(&state);
            }
        }
    }

    Ok(serde_json::json!({
        "created_ms": head.get("created_ms"),
        "backups": head.get("backups"),
        "doc": doc,
        "maps_imported": maps_imported,
        "maps_failed": maps_failed,
        "art_files": art_files,
        "art_failed": art_failed,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: &str =
        "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

    #[test]
    fn derivation_is_deterministic_and_domain_separated() {
        let a = derive_keys(KEY).unwrap();
        let b = derive_keys(KEY).unwrap();
        assert_eq!(a.pointer, b.pointer);
        assert_eq!(a.enc, b.enc);
        assert_eq!(a.pk.to_bytes(), b.pk.to_bytes());
        // 0x prefix and whitespace are tolerated (both wallet import
        // paths land on the same identity).
        let c = derive_keys(&format!("  {} ", &KEY[2..])).unwrap();
        assert_eq!(a.pointer, c.pointer);
        // The enc key and the ML-DSA seed live in separate domains.
        let seed = blake3::derive_key(
            DOMAIN_POINTER,
            &hex::decode(&KEY[2..]).unwrap(),
        );
        assert_ne!(a.enc, seed);
        // The pointer address is the canonical upstream derivation.
        assert_eq!(a.pointer, pointer_address(&a.pk));
        // A different wallet is a different identity.
        let other = derive_keys(
            "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
        )
        .unwrap();
        assert_ne!(a.pointer, other.pointer);
        assert_ne!(a.enc, other.enc);
    }

    #[test]
    fn bad_wallet_keys_are_refused() {
        assert!(derive_keys("zz").is_err());
        assert!(derive_keys("0x1234").is_err());
        assert!(derive_keys("").is_err());
    }

    #[test]
    fn object_seal_is_deterministic_and_round_trips() {
        let keys = derive_keys(KEY).unwrap();
        let plain = b"the backup object bytes".to_vec();
        let (h1, c1) = seal_object(&keys.enc, &plain);
        let (h2, c2) = seal_object(&keys.enc, &plain);
        // Convergent: identical plaintext = identical ciphertext — the
        // property the chunk-dedup economy rests on.
        assert_eq!(h1, h2);
        assert_eq!(c1, c2);
        assert_ne!(c1, plain);
        assert_eq!(open_object(&keys.enc, &h1, &c1).unwrap(), plain);
        // Tampered ciphertext and wrong hashes are refused.
        let mut bad = c1.clone();
        bad[0] ^= 1;
        assert!(open_object(&keys.enc, &h1, &bad).is_err());
        let other = seal_object(&keys.enc, b"different").0;
        assert!(open_object(&keys.enc, &other, &c1).is_err());
        // A different backup key cannot open it.
        let other_keys = derive_keys(
            "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
        )
        .unwrap();
        assert!(open_object(&other_keys.enc, &h1, &c1).is_err());
    }

    #[test]
    fn envelope_round_trips_with_fresh_nonces() {
        let keys = derive_keys(KEY).unwrap();
        let plain = b"head or manifest".to_vec();
        let a = seal_envelope(&keys.enc, &plain);
        let b = seal_envelope(&keys.enc, &plain);
        assert_ne!(a, b); // random nonce per seal
        assert_eq!(open_envelope(&keys.enc, &a).unwrap(), plain);
        assert_eq!(open_envelope(&keys.enc, &b).unwrap(), plain);
        assert!(open_envelope(&keys.enc, &a[..10]).is_err());
        let mut bad = a.clone();
        let last = bad.len() - 1;
        bad[last] ^= 1;
        assert!(open_envelope(&keys.enc, &bad).is_err());
    }

    #[test]
    fn art_file_names_are_vetted() {
        assert!(safe_art_file_name("movie_4808.jpg"));
        assert!(safe_art_file_name("user_movie_x_1a2b3c_170.jpg"));
        assert!(!safe_art_file_name("../etc/passwd"));
        assert!(!safe_art_file_name("a/b.jpg"));
        assert!(!safe_art_file_name(".hidden"));
        assert!(!safe_art_file_name(""));
    }

    #[test]
    fn state_round_trips_on_disk() {
        let dir = std::env::temp_dir()
            .join(format!("wi-backup-state-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let path = dir.join("backup_state.json");
        let mut state = BackupState::default();
        state
            .objects
            .insert("abc".into(), ("bWFw".into(), 42));
        state.last = Some(serde_json::json!({"ms": 7, "head": "ff", "backups": 3}));
        state.save(&path);
        let loaded = BackupState::load(&path);
        assert_eq!(loaded.objects.get("abc"), Some(&("bWFw".to_string(), 42)));
        assert_eq!(
            loaded.last.unwrap().get("backups").and_then(|b| b.as_u64()),
            Some(3)
        );
        // Garbage degrades to empty instead of erroring.
        std::fs::write(&path, b"not json").unwrap();
        let garbage = BackupState::load(&path);
        assert!(garbage.objects.is_empty());
        assert!(garbage.last.is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn backup_refuses_without_wallet_or_doc() {
        let dir = std::env::temp_dir()
            .join(format!("wi-backup-nowallet-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let engine: &'static Engine =
            Box::leak(Box::new(Engine::new(None, dir.to_str())));
        engine.wallet.disable_keychain();
        let err = engine
            .start_backup(serde_json::json!({"doc": {}}))
            .unwrap_err();
        assert!(err.contains("wallet"), "{err}");
        engine.wallet.store(KEY).unwrap();
        let err = engine.start_backup(serde_json::json!({})).unwrap_err();
        assert!(err.contains("doc"), "{err}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn restore_arg_validation() {
        let dir = std::env::temp_dir()
            .join(format!("wi-backup-restoreargs-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let engine: &'static Engine =
            Box::leak(Box::new(Engine::new(None, dir.to_str())));
        engine.wallet.disable_keychain();
        // No wallet and no pasted key: a clear pointer at the fix.
        let err = engine
            .start_restore(None, "/tmp/x".into())
            .unwrap_err();
        assert!(err.contains("wallet"), "{err}");
        let err = engine
            .start_restore(Some("nothex".into()), "/tmp/x".into())
            .unwrap_err();
        assert!(err.contains("not a valid private key"), "{err}");
        let err = engine
            .start_restore(Some(KEY.into()), "  ".into())
            .unwrap_err();
        assert!(err.contains("art_dir"), "{err}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
