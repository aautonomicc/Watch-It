//! Seed-phrase backup: the full W@tch state published to Autonomi under
//! keys derived OFFLINE from the upload wallet, so a fresh install
//! restores from the 12 words alone (docs/ROADMAP.md, plan adopted
//! 2026-10-06).
//!
//! SIGN-TO-DERIVE (hw-wallet plan phase 1, 2026-10-10): the identity no
//! longer derives from the raw private key — it derives from the
//! wallet's deterministic (RFC-6979) EIP-191 signature of the frozen
//! [IDENTITY_MESSAGE_V1]. A hardware wallet signs exactly that message
//! once at setup and lands on the SAME identity as the software wallet
//! holding the same 12 words, without the key ever leaving the device.
//! Breaking by design: pre-phase-1 backups live under the old raw-key
//! derivation, kept as [derive_keys_legacy] so a restore falls back to
//! the old line when the new one is empty.
//!
//! Shape: a content-addressed encrypted object store. Every object
//! (the sync-doc-shaped state document, the root-map bundle, each
//! artwork PACK) is encrypted DETERMINISTICALLY — key and nonce derive
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
//! ARTWORK PACKS (2026-11-12): artwork files are not objects of their
//! own — a self-encrypted object is at least three chunks however small,
//! so a 40 KB poster cost three paid chunks and three lookups to read
//! back. New artwork is concatenated into pack objects (up to
//! [PACK_TARGET_BYTES]); the manifest's `art` entries name the pack plus
//! the file's offset and length. A pack is never rewritten: each backup
//! packs only the files no earlier pack holds, so unchanged artwork still
//! costs nothing. Manifests written before packs (an `art` entry with no
//! `pack`, its hash an object of its own) stay readable.
//!
//! Reading is free (no wallet needed): restore = derive → pointer_get →
//! head chunk → manifest → objects. Writing is paid from the upload
//! wallet, so backups only run on a wallet-holding device.

use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use ant_core::data::client::upload::UploadRecord;
use ant_core::data::client::upload_state::UploadState;
use ant_core::data::error::Error as AntError;
use ant_core::data::{
    ml_dsa_65, pointer_address, DataMap, MlDsaPublicKey, MlDsaSecretKey,
    PaymentMode, PointerTarget, PointerTargetKind,
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
// v1 pointer/enc = the pre-phase-1 raw-key derivation, kept only for the
// legacy restore fallback; v2 hangs off the identity signature.
const DOMAIN_POINTER_LEGACY: &str = "watchit.backup.pointer.v1";
const DOMAIN_ENC_LEGACY: &str = "watchit.backup.enc.v1";
const DOMAIN_IDENTITY: &str = "watchit.backup.identity.v1";
const DOMAIN_POINTER: &str = "watchit.backup.pointer.v2";
const DOMAIN_ENC: &str = "watchit.backup.enc.v2";
const DOMAIN_OBJECT_KEY: &str = "watchit.backup.object-key.v1";
const DOMAIN_OBJECT_NONCE: &str = "watchit.backup.object-nonce.v1";
const DOMAIN_ENVELOPE: &str = "watchit.backup.envelope.v1";
const DOMAIN_STATE_ID: &str = "watchit.backup.state-id.v1";

/// The message whose EIP-191 signature IS the backup identity. FROZEN
/// FOREVER: changing one byte orphans every v2 backup. Future rotation
/// bumps the epoch line into a new frozen message (a new backup line) —
/// never edits this one. A hardware wallet shows this text at setup; the
/// wording must stay true: signing it spends nothing.
pub const IDENTITY_MESSAGE_V1: &str = "W@tch backup identity\n\
version: 1\n\
epoch: 0\n\n\
Signing this message derives the keys that encrypt this wallet's W@tch \
backups. It costs nothing and authorizes no transaction.";

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

/// The free-read half of a backup identity: the pointer address to poll
/// and the content key that opens everything under it. This — never the
/// wallet key — is what a wallet-holding device shares with its linked
/// devices over the My W@tch store (phase 2), so they can fold its
/// backups in: reading is free, spending stays with the wallet holder.
#[derive(Clone, Copy, Debug)]
pub struct ReadKeys {
    pub enc: [u8; 32],
    pub pointer: [u8; 32],
}

impl BackupKeys {
    pub fn read(&self) -> ReadKeys {
        ReadKeys { enc: self.enc, pointer: self.pointer }
    }
}

/// Parse shared read keys (pointer address + content key, 64 hex each).
pub fn read_keys_from_hex(ptr_hex: &str, key_hex: &str) -> Result<ReadKeys, String> {
    Ok(ReadKeys {
        pointer: addr_from_hex(ptr_hex)
            .ok_or("the backup pointer must be 64 hex characters")?,
        enc: addr_from_hex(key_hex)
            .ok_or("the backup read key must be 64 hex characters")?,
    })
}

/// 64-hex → 32 bytes, or None.
pub fn addr_from_hex(hex_str: &str) -> Option<[u8; 32]> {
    hex::decode(hex_str.trim())
        .ok()
        .and_then(|b| <[u8; 32]>::try_from(b.as_slice()).ok())
}

/// The wallet's deterministic identity signature: EIP-191 personal-sign
/// of [IDENTITY_MESSAGE_V1], returned as r‖s (64 bytes — the recovery
/// byte is dropped because its encoding varies across signers while r‖s
/// is identical for the same key, RFC-6979). This is the exact signature
/// a Trezor/Ledger produces for the same message, so the hardware path
/// (phase 3) plugs in by swapping the signer, nothing else.
pub fn identity_signature(wallet_key_hex: &str) -> Result<[u8; 64], String> {
    use alloy_signer::SignerSync;
    use alloy_signer_local::PrivateKeySigner;
    let cleaned = wallet_key_hex.trim().trim_start_matches("0x");
    let signer: PrivateKeySigner = cleaned
        .parse()
        .map_err(|_| "wallet key is not a valid private key".to_string())?;
    let sign_once = || -> Result<[u8; 64], String> {
        let sig = signer
            .sign_message_sync(IDENTITY_MESSAGE_V1.as_bytes())
            .map_err(|e| format!("identity signing failed: {e}"))?;
        let mut rs = [0u8; 64];
        rs[..32].copy_from_slice(&sig.r().to_be_bytes::<32>());
        rs[32..].copy_from_slice(&sig.s().to_be_bytes::<32>());
        Ok(rs)
    };
    // Determinism guard: a signer that does not repeat the signature
    // would mint a backup identity nothing can ever re-derive — refuse
    // before deriving anything. Trivially true for RFC-6979 software
    // signing; load-bearing once hardware signers arrive.
    let first = sign_once()?;
    if first != sign_once()? {
        return Err(
            "the signer did not repeat the identity signature — refusing to \
             derive backup keys a fresh install could never re-derive"
                .into(),
        );
    }
    Ok(first)
}

/// Derive the backup identity from the wallet's private key (the exact
/// bytes the 12 words produce at m/44'/60'/0'/0/0 — both wallet import
/// paths land here, so both restore the same backup). Since phase 1 the
/// key only SIGNS; the keys hang off the signature.
pub fn derive_keys(wallet_key_hex: &str) -> Result<BackupKeys, String> {
    Ok(derive_keys_from_signature(&identity_signature(
        wallet_key_hex,
    )?))
}

/// The signature → keys half of [derive_keys]: the seam an external
/// signer (phase 3) feeds — hand it the 64-byte r‖s of the device's
/// [IDENTITY_MESSAGE_V1] signature and it lands on the same identity.
pub fn derive_keys_from_signature(sig_rs: &[u8; 64]) -> BackupKeys {
    use zeroize::Zeroizing;
    let root = Zeroizing::new(blake3::derive_key(DOMAIN_IDENTITY, sig_rs));
    let seed = Zeroizing::new(blake3::derive_key(DOMAIN_POINTER, root.as_ref()));
    let (pk, sk) = ml_dsa_65().generate_keypair_from_seed(&seed);
    let enc = blake3::derive_key(DOMAIN_ENC, root.as_ref());
    let pointer = pointer_address(&pk);
    BackupKeys { sk, pk, enc, pointer }
}

/// The pre-phase-1 derivation (blake3 straight over the raw key bytes).
/// Kept ONLY so restores reach backups made before the sign-to-derive
/// flip; nothing ever writes under this identity again.
pub fn derive_keys_legacy(wallet_key_hex: &str) -> Result<BackupKeys, String> {
    use zeroize::Zeroizing;
    let cleaned = wallet_key_hex.trim().trim_start_matches("0x");
    let bytes = Zeroizing::new(
        hex::decode(cleaned).map_err(|_| "wallet key is not valid hex".to_string())?,
    );
    if bytes.len() != 32 {
        return Err("wallet key must be 32 bytes".into());
    }
    let seed = Zeroizing::new(blake3::derive_key(DOMAIN_POINTER_LEGACY, &bytes));
    let (pk, sk) = ml_dsa_65().generate_keypair_from_seed(&seed);
    let enc = blake3::derive_key(DOMAIN_ENC_LEGACY, &bytes);
    let pointer = pointer_address(&pk);
    Ok(BackupKeys { sk, pk, enc, pointer })
}

/// A short public-safe fingerprint of a backup identity (derived from
/// the enc key through its own one-way domain), stamped into the local
/// state file so a changed identity — the phase-1 flip, or a swapped
/// wallet — starts a CLEAN line instead of reusing the old line's object
/// cache and head chain.
pub fn identity_fingerprint(enc: &[u8; 32]) -> String {
    hex::encode(&blake3::derive_key(DOMAIN_STATE_ID, enc)[..8])
}

/// blake3 content hash of an object's plaintext — the object's identity
/// in the manifest and the input to its deterministic cipher.
pub fn object_hash(plain: &[u8]) -> String {
    blake3::hash(plain).to_hex().to_string()
}

fn object_cipher(enc: &[u8; 32], hash_hex: &str) -> (ChaCha20Poly1305, Nonce) {
    use zeroize::Zeroizing;
    let mut material = Vec::with_capacity(32 + hash_hex.len());
    material.extend_from_slice(enc);
    material.extend_from_slice(hash_hex.as_bytes());
    let material = Zeroizing::new(material);
    let key = Zeroizing::new(blake3::derive_key(DOMAIN_OBJECT_KEY, &material));
    let nonce_full = Zeroizing::new(blake3::derive_key(DOMAIN_OBJECT_NONCE, &material));
    let mut nonce = Nonce::default();
    nonce.copy_from_slice(&nonce_full[..12]);
    (ChaCha20Poly1305::new(Key::from_slice(key.as_ref())), nonce)
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

// ---- artwork packs -----------------------------------------------------

/// A pack is closed once the next file would take it past this. Four
/// full 4 MiB chunks: big enough that small files share chunks instead of
/// costing three each, small enough to fetch and hold in memory whole.
pub const PACK_TARGET_BYTES: usize = 16 * 1024 * 1024;

/// How many packs (or pre-pack artwork objects) a restore fetches at once.
const ART_FETCH_CONCURRENCY: usize = 6;

/// Where a pack holds one artwork file.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ArtLoc {
    /// The pack object's content hash (its key in the manifest's objects).
    pub pack: String,
    pub off: u64,
    pub len: u64,
}

impl ArtLoc {
    fn from_json(v: &serde_json::Value) -> Option<Self> {
        Some(Self {
            pack: v.get("pack")?.as_str()?.to_string(),
            off: v.get("off")?.as_u64()?,
            len: v.get("len")?.as_u64()?,
        })
    }

    fn to_json(&self) -> serde_json::Value {
        serde_json::json!({"pack": self.pack, "off": self.off, "len": self.len})
    }
}

/// What [pack_art] decided for one backup's artwork.
pub(crate) struct ArtPacking {
    /// Every file of this backup: name, content hash, where it sits.
    pub entries: Vec<(String, String, ArtLoc)>,
    /// Packs this backup adds: content hash + plaintext.
    pub packs: Vec<(String, Vec<u8>)>,
    /// Content hash → place, for the files the new packs hold.
    pub new_locs: Vec<(String, ArtLoc)>,
}

/// Place a backup's artwork: a file an earlier pack already holds keeps
/// its place (`known`, as long as `pack_stored` still vouches for that
/// pack); everything else is concatenated, in order, into new packs of up
/// to `target` bytes. Identical content under two names is packed once.
pub(crate) fn pack_art(
    files: Vec<(String, Vec<u8>)>,
    known: &BTreeMap<String, ArtLoc>,
    pack_stored: impl Fn(&str) -> bool,
    target: usize,
) -> ArtPacking {
    let mut named = Vec::<(String, String)>::new();
    let mut placed = HashMap::<String, ArtLoc>::new();
    let mut fresh = Vec::<(String, Vec<u8>)>::new();
    let mut queued = std::collections::HashSet::<String>::new();
    for (file, bytes) in files {
        let hash = object_hash(&bytes);
        match known.get(&hash).filter(|loc| pack_stored(&loc.pack)) {
            Some(loc) => {
                placed.insert(hash.clone(), loc.clone());
            }
            None => {
                if queued.insert(hash.clone()) {
                    fresh.push((hash.clone(), bytes));
                }
            }
        }
        named.push((file, hash));
    }

    let mut packs = Vec::<(String, Vec<u8>)>::new();
    let mut new_locs = Vec::<(String, ArtLoc)>::new();
    let mut plain = Vec::<u8>::new();
    let mut members = Vec::<(String, u64, u64)>::new();
    let mut close = |plain: &mut Vec<u8>, members: &mut Vec<(String, u64, u64)>| {
        if members.is_empty() {
            return;
        }
        let pack = object_hash(plain);
        for (hash, off, len) in members.drain(..) {
            new_locs.push((hash, ArtLoc { pack: pack.clone(), off, len }));
        }
        packs.push((pack, std::mem::take(plain)));
    };
    for (hash, bytes) in fresh {
        if !plain.is_empty() && plain.len() + bytes.len() > target {
            close(&mut plain, &mut members);
        }
        members.push((hash, plain.len() as u64, bytes.len() as u64));
        plain.extend_from_slice(&bytes);
    }
    close(&mut plain, &mut members);

    for (hash, loc) in &new_locs {
        placed.insert(hash.clone(), loc.clone());
    }
    let entries = named
        .into_iter()
        .filter_map(|(file, hash)| {
            let loc = placed.get(&hash)?.clone();
            Some((file, hash, loc))
        })
        .collect();
    ArtPacking { entries, packs, new_locs }
}

/// Cut one file back out of its pack. The bytes must hash to what the
/// manifest recorded for them.
pub(crate) fn unpack_art<'a>(
    pack: &'a [u8],
    hash: &str,
    loc: &ArtLoc,
) -> Result<&'a [u8], String> {
    let start = usize::try_from(loc.off).map_err(|_| "artwork offset out of range")?;
    let len = usize::try_from(loc.len).map_err(|_| "artwork length out of range")?;
    let end = start.checked_add(len).ok_or("artwork range out of range")?;
    let bytes = pack
        .get(start..end)
        .ok_or("artwork range lies outside its pack")?;
    if object_hash(bytes) != hash.to_lowercase() {
        return Err("artwork does not match its hash".into());
    }
    Ok(bytes)
}

// ---- persisted local state -------------------------------------------

/// `backup_state.json` beside the other app state: which object hashes
/// already uploaded (hash → shrunk map + size, so unchanged objects skip
/// the network entirely) plus the last backup's summary for the UI —
/// all stamped with the identity fingerprint they belong to, because a
/// different identity means different ciphertexts and a different
/// pointer: its cache and head chain are poison for the new line.
#[derive(Default)]
struct BackupState {
    identity: Option<String>,
    objects: BTreeMap<String, (String, u64)>,
    /// Artwork content hash → where an already-stored pack holds it.
    art: BTreeMap<String, ArtLoc>,
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
        let mut art = BTreeMap::new();
        if let Some(map) = v.get("art").and_then(|o| o.as_object()) {
            for (hash, entry) in map {
                if let Some(loc) = ArtLoc::from_json(entry) {
                    art.insert(hash.clone(), loc);
                }
            }
        }
        Self {
            identity: v
                .get("identity")
                .and_then(|i| i.as_str())
                .map(str::to_string),
            objects,
            art,
            last: v.get("last").cloned().filter(|l| !l.is_null()),
        }
    }

    fn save(&self, path: &PathBuf) {
        let mut objects = serde_json::Map::new();
        for (hash, (map_b64, size)) in &self.objects {
            objects.insert(
                hash.clone(),
                serde_json::json!({"map": map_b64, "size": size}),
            );
        }
        let art: serde_json::Map<String, serde_json::Value> = self
            .art
            .iter()
            .map(|(hash, loc)| (hash.clone(), loc.to_json()))
            .collect();
        let out = serde_json::json!({
            "identity": self.identity,
            "objects": objects,
            "art": art,
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
    /// deriving → (trezor → allowance) → packing → quoting → paying →
    /// storing → pointer → done (backup); deriving → locating → fetching →
    /// importing → art → done (restore — during `art` the result already
    /// holds the library, artwork still arriving); either ends in `error`.
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
    /// A hardware wallet's derived write keys, kept IN MEMORY for the app
    /// run (never on disk — the settled key policy) so only the first
    /// backup after launch asks the device for the identity signature.
    /// Keyed by wallet address; dropped on any wallet change.
    write_keys: Mutex<Option<(String, Arc<BackupKeys>)>>,
}

impl BackupManager {
    pub fn new(data_dir: Option<&str>) -> Self {
        Self {
            state_path: data_dir
                .filter(|d| !d.trim().is_empty())
                .map(|d| PathBuf::from(d).join("backup_state.json")),
            job: Mutex::new(None),
            active: AtomicBool::new(false),
            write_keys: Mutex::new(None),
        }
    }

    /// Drop the in-memory write keys (wallet imported/removed, device
    /// session settings changed).
    pub fn forget_keys(&self) {
        *self.write_keys.lock().unwrap() = None;
    }

    fn kept_keys(&self, address: &str, pointer: &[u8; 32]) -> Option<Arc<BackupKeys>> {
        self.write_keys
            .lock()
            .unwrap()
            .as_ref()
            .filter(|(a, k)| a.eq_ignore_ascii_case(address) && k.pointer == *pointer)
            .map(|(_, k)| k.clone())
    }

    fn keep_keys(&self, address: &str, keys: Arc<BackupKeys>) {
        *self.write_keys.lock().unwrap() = Some((address.to_string(), keys));
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

    /// The persisted state AS SEEN BY one identity: a stored state from a
    /// different identity (or from before states were stamped — every
    /// pre-phase-1 file) is discarded and the line starts clean, so the
    /// old line's object cache can never feed the new line's manifest.
    fn state_for(&self, identity_fp: &str) -> BackupState {
        let mut state = self.state();
        if state.identity.as_deref() != Some(identity_fp) {
            if !state.objects.is_empty() || state.last.is_some() {
                tracing::info!(
                    "backup identity changed — starting a new backup line"
                );
            }
            state = BackupState::default();
        }
        state.identity = Some(identity_fp.to_string());
        state
    }

    fn save_state(&self, state: &BackupState) {
        if let Some(p) = &self.state_path {
            state.save(p);
        }
    }

    /// True when the state file belongs to a DIFFERENT identity that has
    /// recorded at least one backup — i.e. the configured identity's
    /// first backup will start a fresh line and re-upload everything once
    /// (the post-sign-to-derive-update / swapped-wallet case). Drives the
    /// Backup screen's one-time notice; clears itself the moment a backup
    /// runs under the current identity (the state re-stamps).
    pub fn previous_line_exists(&self, identity_fp: &str) -> bool {
        let state = self.state();
        state.identity.as_deref() != Some(identity_fp)
            && (state.last.is_some() || !state.objects.is_empty())
    }

    /// The last backup recorded for THIS identity — a summary left behind
    /// by a different (pre-flip) identity reads as "never backed up", so
    /// the UI and the phase-2 key-share section never present the new
    /// line as populated (followers would adopt keys to an empty line).
    pub fn last_json(&self, identity_fp: Option<&str>) -> Option<serde_json::Value> {
        let state = self.state();
        match (identity_fp, state.identity.as_deref()) {
            (Some(fp), Some(id)) if fp == id => state.last,
            _ => None,
        }
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

/// How many times a backup's store/payment step is driven before the job
/// gives up, and the pause between rounds. A round after the first never
/// signs or pays again: it watches the journaled payment and re-sends
/// chunks whose paid proofs it still holds.
const PUBLISH_ROUNDS: usize = 4;
const PUBLISH_RETRY_DELAY: std::time::Duration = std::time::Duration::from_secs(15);

/// Self-encrypt one blob locally and stage its chunks for the pooled
/// upload — exactly the chunks and data map `Client::data_upload` would
/// produce, without touching the network or the wallet.
pub(crate) fn stage_blob(
    chunks: &mut HashMap<[u8; 32], Bytes>,
    data: Vec<u8>,
) -> Result<DataMap, String> {
    let (map, encrypted) =
        self_encryption::encrypt(Bytes::from(data)).map_err(|e| e.to_string())?;
    for chunk in encrypted {
        chunks.insert(ant_core::data::compute_address(&chunk.content), chunk.content);
    }
    Ok(map)
}

/// What a stored object is to the manifest.
#[derive(Clone, Copy, PartialEq)]
enum ObjectRole {
    Doc,
    Maps,
    ArtPack,
}

/// One object headed for the store: a label (for errors), its role, and
/// its plaintext.
struct PendingObject {
    label: String,
    role: ObjectRole,
    plain: Vec<u8>,
}

impl Engine {
    /// Kick off a backup. `input` is the app-assembled payload:
    /// `{"doc": {...}, "art": [{"file","path"}...], "map_addrs": [...]}`.
    pub fn start_backup(&'static self, input: serde_json::Value) -> Result<(), String> {
        if self.wallet.load().is_none() {
            return Err(self.wallet_unavailable(
                "no upload wallet configured — the backup identity derives from \
                 its 12 words (Settings → Wallet)",
            ));
        }
        let signer = self.signer()?;
        if input.get("doc").and_then(|d| d.as_object()).is_none() {
            return Err("backup payload needs a \"doc\" object".into());
        }
        let job = self.backups.begin("backup", "deriving")?;
        tokio::spawn(run_backup(self, job, signer, input));
        Ok(())
    }

    /// Kick off a restore. Reads are free: `key_hex` (a pasted wallet
    /// key, for fresh installs restoring before importing the wallet) or
    /// the configured signer provide the identity; decrypted artwork
    /// lands in `art_dir` for the app to sort into place.
    pub fn start_restore(
        &'static self,
        key_hex: Option<String>,
        art_dir: String,
    ) -> Result<(), String> {
        let signer = match key_hex {
            Some(k) => crate::signer::Signer::software(&k)?,
            None => {
                if self.wallet.load().is_none() {
                    return Err("no wallet on this device — paste the wallet key, or import \
                                the 12 words in Settings → Wallet first"
                        .into());
                }
                self.signer()?
            }
        };
        if art_dir.trim().is_empty() {
            return Err("restore needs an art_dir".into());
        }
        let job = self.backups.begin("restore", "deriving")?;
        tokio::spawn(run_restore(self, job, signer, art_dir));
        Ok(())
    }

    /// Kick off a follow fetch (phase 2): read another device's backup
    /// with its SHARED read keys — pointer address + content key, never
    /// a wallet key — and stage it exactly like a restore. Free: reads
    /// only, no wallet needed on this device.
    pub fn start_follow(
        &'static self,
        ptr_hex: &str,
        key_hex: &str,
        art_dir: String,
    ) -> Result<(), String> {
        let keys = read_keys_from_hex(ptr_hex, key_hex)?;
        if art_dir.trim().is_empty() {
            return Err("follow needs an art_dir".into());
        }
        let job = self.backups.begin("follow", "locating")?;
        tokio::spawn(run_follow(self, job, keys, art_dir));
        Ok(())
    }
}

/// Record a finished job's outcome and free the single job slot.
fn finish_job(
    engine: &'static Engine,
    job: &Arc<Mutex<JobState>>,
    outcome: Result<serde_json::Value, String>,
) {
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

async fn run_backup(
    engine: &'static Engine,
    job: Arc<Mutex<JobState>>,
    signer: crate::signer::Signer,
    input: serde_json::Value,
) {
    let outcome = drive_backup(engine, &job, &signer, &input).await;
    finish_job(engine, &job, outcome);
}

async fn drive_backup(
    engine: &'static Engine,
    job: &Arc<Mutex<JobState>>,
    signer: &crate::signer::Signer,
    input: &serde_json::Value,
) -> Result<serde_json::Value, String> {
    // A hardware signer re-derives the write keys on-device (the settled
    // paranoid policy: never persisted) — one physical confirmation. The
    // dedicated phase keeps the UI honest about what it is waiting for.
    // ONE device session is opened up front and held for the whole job:
    // the Trezor caches its passphrase per session, so the identity
    // derive and every payment signature below reuse this session — one
    // passphrase entry per backup instead of one per signature (the
    // 2026-10-12 passphrase-storm fix).
    let mut _job_session = None;
    if signer.is_hardware() {
        set_phase(job, "trezor");
        _job_session = Some(crate::trezor::begin_job_session(&signer.address()?).await?);
    }
    // The write keys: a hardware wallet signs the identity message
    // on-device (one confirmation) — once per app run while "ask for the
    // passphrase once per app run" is on; the derived keys then stay in
    // memory only, so later backups need just the payment confirmation.
    let keys: Arc<BackupKeys> = if signer.is_hardware() {
        let address = signer.address()?;
        match engine.backups.kept_keys(&address, &signer.pointer()?) {
            Some(kept) => kept,
            None => {
                let derived = Arc::new(signer.backup_write_keys().await?);
                if crate::trezor::keep_session::enabled() {
                    engine.backups.keep_keys(&address, derived.clone());
                }
                derived
            }
        }
    } else {
        Arc::new(signer.backup_write_keys().await?)
    };
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
        role: ObjectRole::Doc,
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
            role: ObjectRole::Maps,
            plain: maps_bytes,
        });
    }

    let mut art_files = Vec::<(String, Vec<u8>)>::new();
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
                art_files.push((file.to_string(), bytes));
            }
            Ok(_) => skipped.push(format!("{file} (size)")),
            Err(_) => skipped.push(format!("{file} (unreadable)")),
        }
    }

    // -- encrypt everything locally: nothing is paid or sent yet ----------
    // Every chunk of the backup — new objects, manifest, head — is known
    // before the wallet is asked for anything, so the whole backup (the
    // pointer included) is paid by ONE transaction (backuppay.rs).
    let client = engine.client().await?;
    let wallet = signer.payment_wallet().await?;
    // A hardware wallet grants the one-time token allowance here, with no
    // signing deadline, while the user is still at the device.
    if _job_session.is_some() {
        set_phase(job, "allowance");
        crate::payjournal::ensure_unlimited_allowance(&wallet).await?;
    }
    let mut state = engine
        .backups
        .state_for(&identity_fingerprint(&keys.enc));
    // Artwork: files an earlier pack holds keep their place; the rest
    // go into new packs (never a rewrite of an old one).
    let art_count = art_files.len();
    let packing = pack_art(
        art_files,
        &state.art,
        |pack| state.objects.contains_key(pack),
        PACK_TARGET_BYTES,
    );
    let art_packed = packing.new_locs.len();
    let new_packs = packing.packs.len();
    for (n, (_, plain)) in packing.packs.into_iter().enumerate() {
        objects.push(PendingObject {
            label: format!("artwork pack {}", n + 1),
            role: ObjectRole::ArtPack,
            plain,
        });
    }
    let total = objects.len() - new_packs + art_count;
    set_phase(job, "packing");
    let mut chunks = HashMap::<[u8; 32], Bytes>::new();
    let mut new_objects = Vec::<(String, (String, u64))>::new();
    let mut manifest_objects = serde_json::Map::new();
    let mut doc_hash = String::new();
    let mut maps_hash: Option<String> = None;
    let mut uploaded = art_packed;

    for obj in objects.iter() {
        let hash = object_hash(&obj.plain);
        let known = state.objects.get(&hash).cloned();
        let (map_b64, size) = match known {
            Some(hit) => hit,
            None => {
                let (sealed_hash, ciphertext) = seal_object(&keys.enc, &obj.plain);
                debug_assert_eq!(sealed_hash, hash);
                let map = stage_blob(&mut chunks, ciphertext)
                    .map_err(|e| format!("packing {} failed: {e}", obj.label))?;
                let map_bytes = rmp_serde::to_vec(&map)
                    .map_err(|e| format!("map encode failed: {e}"))?;
                let entry = (B64.encode(map_bytes), obj.plain.len() as u64);
                new_objects.push((hash.clone(), entry.clone()));
                if obj.role != ObjectRole::ArtPack {
                    uploaded += 1;
                }
                entry
            }
        };
        manifest_objects.insert(
            hash.clone(),
            serde_json::json!({"map": map_b64, "size": size}),
        );
        match obj.role {
            ObjectRole::Doc => doc_hash = hash.clone(),
            ObjectRole::Maps => maps_hash = Some(hash.clone()),
            ObjectRole::ArtPack => {}
        }
    }
    // Packs from earlier backups that this one still reads from.
    let mut art_entries = Vec::<serde_json::Value>::new();
    for (file, hash, loc) in &packing.entries {
        if !manifest_objects.contains_key(&loc.pack) {
            let Some((map_b64, size)) = state.objects.get(&loc.pack) else {
                skipped.push(format!("{file} (pack missing)"));
                continue;
            };
            manifest_objects.insert(
                loc.pack.clone(),
                serde_json::json!({"map": map_b64, "size": size}),
            );
        }
        art_entries.push(serde_json::json!({
            "file": file,
            "hash": hash,
            "pack": loc.pack,
            "off": loc.off,
            "len": loc.len,
        }));
    }
    let new_art = packing.new_locs;

    let manifest = serde_json::json!({
        "v": 2,
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
    let manifest_map = stage_blob(&mut chunks, manifest_ct)
        .map_err(|e| format!("packing the backup manifest failed: {e}"))?;
    let manifest_map_b64 = B64.encode(
        rmp_serde::to_vec(&manifest_map).map_err(|e| e.to_string())?,
    );

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
    let head_ct = Bytes::from(seal_envelope(
        &keys.enc,
        &serde_json::to_vec(&head).map_err(|e| e.to_string())?,
    ));
    if head_ct.len() > ant_core::data::MAX_CHUNK_SIZE {
        return Err("the backup head does not fit one chunk".into());
    }
    let head_addr = ant_core::data::compute_address(&head_ct);
    chunks.insert(head_addr, head_ct);

    // -- one payment, then store ------------------------------------------
    let progress_job = job.clone();
    let published = publish_backup(
        &client,
        wallet,
        &keys,
        chunks,
        head_addr,
        Box::new(move |phase, done, total| {
            let mut s = progress_job.lock().unwrap();
            s.phase = phase.to_string();
            s.done = done;
            s.total = total;
        }),
        || {
            // The objects are on the network now, whatever happens to
            // the pointer: remember them so the next backup never pays
            // for them again.
            for (hash, entry) in new_objects {
                state.objects.insert(hash, entry);
            }
            for (hash, loc) in new_art {
                state.art.insert(hash, loc);
            }
            engine.backups.save_state(&state);
        },
    )
    .await?;
    let (chunk_count, payments) = (published.chunks, published.payments);

    let summary = serde_json::json!({
        "ms": now_ms,
        "head": hex::encode(head_addr),
        "pointer": hex::encode(keys.pointer),
        "backups": backups_count,
        "objects": total,
        "uploaded": uploaded,
        "packs": new_packs,
        "chunks": chunk_count,
        "payments": payments,
        "maps_missing": maps_missing,
        "skipped": skipped,
    });
    state.last = Some(summary.clone());
    engine.backups.save_state(&state);
    tracing::info!(
        "backup #{backups_count} published: {total} objects ({uploaded} new), \
         {chunk_count} chunks, {payments} payment(s), head {}",
        hex::encode(head_addr)
    );
    Ok(summary)
}

type ProgressFn = dyn Fn(&'static str, usize, usize) + Send + Sync;

/// What [`publish_backup`] did.
pub(crate) struct Published {
    /// Chunks in the backup (already-stored ones included).
    pub chunks: usize,
    /// Wallet transactions it took.
    pub payments: usize,
}

/// Everything that touches the network or the wallet: sign + quote the
/// pointer for `head_addr`, pay for the staged chunks and the pointer in
/// ONE transaction (backuppay.rs), store the chunks, then store the
/// pointer with its share of that payment. `on_stored` runs once every
/// chunk is on the network, before the pointer is written.
pub(crate) async fn publish_backup(
    client: &ant_core::data::Client,
    wallet: ant_core::data::Wallet,
    keys: &BackupKeys,
    chunks: HashMap<[u8; 32], Bytes>,
    head_addr: [u8; 32],
    progress: Box<ProgressFn>,
    on_stored: impl FnOnce() + Send,
) -> Result<Published, String> {
    // -- the pointer: signed and quoted now, paid with the chunks ---------
    progress("quoting", 0, 0);
    let record = client
        .pointer_sign_update(
            &keys.sk,
            &keys.pk,
            PointerTarget::new(PointerTargetKind::Chunk, head_addr),
        )
        .await
        .map_err(|e| format!("preparing the backup pointer failed: {e}"))?;
    let pointer_plan = client
        .prepare_pointer_payment(&record)
        .await
        .map_err(|e| format!("quoting the backup pointer failed: {e}"))?;

    let mut addrs: Vec<[u8; 32]> = chunks.keys().copied().collect();
    addrs.sort_unstable();
    let records: Vec<UploadRecord> = addrs
        .iter()
        .enumerate()
        .map(|(index, addr)| UploadRecord {
            address: *addr,
            size: chunks[addr].len() as u64,
            index,
        })
        .collect();
    let chunk_count = records.len();
    // Up to one payment wave rides a single `payForQuotes` transaction
    // together with the pointer. A bigger backup (a first one with lots
    // of artwork) pays its chunks through merkle batches and the pointer
    // on its own.
    let mode = if chunk_count <= crate::backuppay::SINGLE_PAYMENT_CHUNKS {
        PaymentMode::Single
    } else {
        PaymentMode::Merkle
    };
    let progress: Arc<ProgressFn> = Arc::from(progress);
    let adapter_progress = progress.clone();
    let adapter = crate::backuppay::BackupAdapter::new(
        wallet,
        Arc::new(chunks),
        Some(pointer_plan),
        Box::new(move |phase, done, total| {
            // Quote callbacks carry a record index, not a count.
            if phase == "storing" {
                adapter_progress(phase, done, total)
            } else {
                adapter_progress(phase, 0, 0)
            }
        }),
    );
    let mut upload_state = UploadState::default();
    let mut round = 0;
    loop {
        round += 1;
        match client
            .upload_records(records.clone(), &mut upload_state, &adapter, mode)
            .await
        {
            Ok(_) => break,
            Err(e) => {
                // Worth another round only when money may be in flight (a
                // journaled payment still unresolved — the next round
                // watches it, never signs again) or paid chunks fell
                // short (their proofs are kept — storing again is free).
                let retry = upload_state.pending_payment.is_some()
                    || matches!(e, AntError::PartialUpload { .. });
                if !retry || round >= PUBLISH_ROUNDS {
                    return Err(format!("storing the backup failed: {e}"));
                }
                tracing::warn!("backup: store round {round} fell short ({e}); trying again");
                tokio::time::sleep(PUBLISH_RETRY_DELAY).await;
            }
        }
    }
    on_stored();

    // No chunk payment carried the pointer (merkle batches, or every
    // chunk already stored): it pays on its own.
    let mut pointer_state = UploadState::default();
    let mut round = 0;
    loop {
        round += 1;
        match adapter.pay_pointer_alone(&mut pointer_state).await {
            Ok(()) => break,
            Err(e) => {
                if pointer_state.pending_payment.is_none() || round >= PUBLISH_ROUNDS {
                    return Err(format!("paying for the backup pointer failed: {e}"));
                }
                tokio::time::sleep(PUBLISH_RETRY_DELAY).await;
            }
        }
    }
    let proof = adapter
        .pointer_proof()
        .ok_or("the backup pointer was not paid for")?
        .map_err(|e| format!("building the pointer payment proof failed: {e}"))?;

    progress("pointer", 0, 0);
    client
        .pointer_put_paid(&record, proof)
        .await
        .map_err(|e| format!("updating the backup pointer failed: {e}"))?;
    Ok(Published { chunks: chunk_count, payments: adapter.payments() })
}

// ---- restore -------------------------------------------------------------

async fn run_restore(
    engine: &'static Engine,
    job: Arc<Mutex<JobState>>,
    signer: crate::signer::Signer,
    art_dir: String,
) {
    const MISSING: &str = "no backup found for this wallet — nothing has been \
                           backed up under these 12 words yet";
    // Restores only READ. Software keys derive the read half offline; a
    // hardware wallet uses the kept read key, or — in the paranoid
    // opt-out where none is kept — asks the device once.
    let read = match signer.read_keys() {
        Ok(Some(r)) => Ok(r),
        Ok(None) => {
            set_phase(&job, "trezor");
            signer.backup_write_keys().await.map(|k| k.read())
        }
        Err(e) => Err(e),
    };
    let outcome = match read {
        Ok(keys) => {
            match drive_restore(engine, &job, keys, &art_dir, MISSING)
                .await
            {
                // Nothing under the signature-derived (v2) pointer: fall
                // back to the pre-phase-1 raw-key derivation so backups
                // made before the flip stay restorable from the same 12
                // words. Only the clean not-found falls through — a
                // transport error surfaces as itself (retrying the walk
                // under different keys would not help it). A signer with
                // no raw key (hardware, phase 3) has no legacy line by
                // construction and keeps the clean not-found.
                Err(e) if e == MISSING => match signer.backup_keys_legacy() {
                    Ok(Some(old)) => {
                        tracing::info!(
                            "no backup under the current identity — trying \
                             the pre-upgrade backup line"
                        );
                        set_phase(&job, "locating");
                        drive_restore(engine, &job, old.read(), &art_dir, MISSING)
                            .await
                            .map(|mut v| {
                                v["legacy"] = serde_json::Value::Bool(true);
                                v
                            })
                    }
                    Ok(None) => Err(MISSING.into()),
                    Err(e) => Err(e),
                },
                other => other,
            }
        }
        Err(e) => Err(e),
    };
    finish_job(engine, &job, outcome);
}

async fn run_follow(
    engine: &'static Engine,
    job: Arc<Mutex<JobState>>,
    keys: ReadKeys,
    art_dir: String,
) {
    let outcome = drive_restore(
        engine,
        &job,
        keys,
        &art_dir,
        "no backup found under the shared keys — the other device has not \
         backed up yet",
    )
    .await;
    finish_job(engine, &job, outcome);
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

/// The shared read path: a restore (keys derived from a wallet key) and
/// a phase-2 follow fetch (keys shared over My W@tch) are the same walk
/// — pointer → head → manifest → objects — differing only in where the
/// [ReadKeys] came from.
async fn drive_restore(
    engine: &'static Engine,
    job: &Arc<Mutex<JobState>>,
    keys: ReadKeys,
    art_dir: &str,
    missing: &'static str,
) -> Result<serde_json::Value, String> {
    set_phase(job, "locating");
    let client = engine.client().await?;

    let pointer = client
        .pointer_get(&keys.pointer)
        .await
        .map_err(|e| format!("backup lookup failed: {e}"))?
        .ok_or(missing)?;
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

    let art_list: Vec<(String, String, Option<ArtLoc>)> = manifest
        .get("art")
        .and_then(|a| a.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|e| {
                    Some((
                        e.get("file")?.as_str()?.to_string(),
                        e.get("hash")?.as_str()?.to_string(),
                        ArtLoc::from_json(e),
                    ))
                })
                .collect()
        })
        .unwrap_or_default();

    // The library first: state document + data maps.
    let maps_hash = manifest.get("maps").and_then(|m| m.as_str());
    let total = 1 + usize::from(maps_hash.is_some());
    set_phase(job, "fetching");
    set_progress(job, 0, total);

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
    set_progress(job, 1, total);

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
            set_progress(job, 2, total);
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
        }
    }

    // The library is complete without its artwork: hand it to the app
    // now (the job's result while the phase is still "art") so a restored
    // or joining device is usable while the artwork is still arriving.
    let mut result = serde_json::json!({
        "created_ms": head.get("created_ms"),
        "backups": head.get("backups"),
        // The head chunk this fetch walked — the follower records it so
        // its next peek can tell "unchanged" without fetching anything.
        "head": hex::encode(head_addr),
        "doc": doc,
        "maps_imported": maps_imported,
        "maps_failed": maps_failed,
    });
    {
        let mut s = job.lock().unwrap();
        s.phase = "art".into();
        s.done = 0;
        s.total = art_list.len();
        s.result = Some(result.clone());
    }

    // Artwork into the staging dir the app empties into place: one fetch
    // per pack (or per file, for a backup written before packs), several
    // at a time.
    let dir = std::path::Path::new(art_dir);
    let _ = std::fs::create_dir_all(dir);
    let mut art_files = Vec::<serde_json::Value>::new();
    let mut art_failed = 0usize;
    let mut by_pack = BTreeMap::<String, Vec<(String, String, ArtLoc)>>::new();
    let mut singles = Vec::<(String, String)>::new();
    for (file, hash, loc) in art_list.iter().cloned() {
        if !safe_art_file_name(&file) {
            art_failed += 1;
            continue;
        }
        match loc {
            Some(loc) => by_pack
                .entry(loc.pack.clone())
                .or_default()
                .push((file, hash, loc)),
            None => singles.push((file, hash)),
        }
    }
    // Each fetch owns what it needs (the walk runs inside a spawned job).
    type Fetched = Vec<(String, Result<Vec<u8>, String>)>;
    type FetchJob = futures::future::BoxFuture<'static, Fetched>;
    let enc = keys.enc;
    let pack_jobs: Vec<FetchJob> = by_pack
        .into_iter()
        .map(|(pack, members)| {
            let map_b64 = object_map(&pack);
            let client = client.clone();
            Box::pin(async move {
                let fetched = match map_b64 {
                    Some(map_b64) => fetch_blob(engine, &client, &map_b64)
                        .await
                        .and_then(|ct| open_object(&enc, &pack, &ct)),
                    None => Err("pack missing from manifest".to_string()),
                };
                members
                    .into_iter()
                    .map(|(file, hash, loc)| {
                        let bytes = match &fetched {
                            Ok(plain) => {
                                unpack_art(plain, &hash, &loc).map(<[u8]>::to_vec)
                            }
                            Err(e) => Err(e.clone()),
                        };
                        (file, bytes)
                    })
                    .collect::<Fetched>()
            }) as FetchJob
        })
        .collect();
    let single_jobs: Vec<FetchJob> = singles
        .into_iter()
        .map(|(file, hash)| {
            let map_b64 = object_map(&hash);
            let client = client.clone();
            Box::pin(async move {
                let bytes = match map_b64 {
                    Some(map_b64) => fetch_blob(engine, &client, &map_b64)
                        .await
                        .and_then(|ct| open_object(&enc, &hash, &ct)),
                    None => Err("missing from manifest".to_string()),
                };
                vec![(file, bytes)]
            }) as FetchJob
        })
        .collect();
    let wanted = art_list.len();
    let limit = Arc::new(tokio::sync::Semaphore::new(ART_FETCH_CONCURRENCY));
    let mut fetches = tokio::task::JoinSet::new();
    for fetch in pack_jobs.into_iter().chain(single_jobs) {
        let limit = limit.clone();
        fetches.spawn(async move {
            let _slot = limit.acquire_owned().await;
            fetch.await
        });
    }
    let mut done = art_failed;
    while let Some(joined) = fetches.join_next().await {
        for (file, bytes) in joined.unwrap_or_default() {
            done += 1;
            match bytes {
                Ok(bytes) if std::fs::write(dir.join(&file), &bytes).is_ok() => {
                    art_files.push(serde_json::Value::String(file));
                }
                Ok(_) => art_failed += 1,
                Err(e) => {
                    tracing::warn!("backup art {file} fetch failed: {e}");
                    art_failed += 1;
                }
            }
        }
        set_progress(job, done, wanted);
    }
    // A fetch task that died took its files with it.
    art_failed += wanted - done;

    // When this device's own wallet IS the backup identity, warm the
    // local object cache so its next backup skips re-uploading anything
    // the restored backup already holds.
    if let Ok(Some(stored)) = engine.signer().and_then(|s| s.read_keys()) {
        if stored.pointer == keys.pointer {
            let mut state = engine
                .backups
                .state_for(&identity_fingerprint(&keys.enc));
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
            for (_, hash, loc) in &art_list {
                if let Some(loc) = loc {
                    state.art.entry(hash.clone()).or_insert(loc.clone());
                }
            }
            engine.backups.save_state(&state);
        }
    }

    result["art_files"] = serde_json::Value::Array(art_files);
    result["art_failed"] = serde_json::Value::from(art_failed);
    Ok(result)
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
        // The enc key and the ML-DSA seed live in separate domains of the
        // signature root.
        let root = blake3::derive_key(DOMAIN_IDENTITY, &identity_signature(KEY).unwrap());
        assert_ne!(a.enc, root);
        assert_ne!(a.enc, blake3::derive_key(DOMAIN_POINTER, &root));
        // The pointer address is the canonical upstream derivation.
        assert_eq!(a.pointer, pointer_address(&a.pk));
        // A different wallet is a different identity.
        let other = derive_keys(
            "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
        )
        .unwrap();
        assert_ne!(a.pointer, other.pointer);
        assert_ne!(a.enc, other.enc);
        // The sign-to-derive flip is real: the same key's v2 identity is
        // NOT the legacy raw-key identity (old backups live on the old
        // line, reached only through the restore fallback).
        let legacy = derive_keys_legacy(KEY).unwrap();
        assert_ne!(a.pointer, legacy.pointer);
        assert_ne!(a.enc, legacy.enc);
        // And the signature→keys seam is the whole derivation: feeding
        // the signature in by hand lands on the identical identity (the
        // exact hardware-wallet path of phase 3).
        let by_sig = derive_keys_from_signature(&identity_signature(KEY).unwrap());
        assert_eq!(a.pointer, by_sig.pointer);
        assert_eq!(a.enc, by_sig.enc);
    }

    #[test]
    fn identity_signature_is_deterministic_and_key_bound() {
        let a = identity_signature(KEY).unwrap();
        let b = identity_signature(KEY).unwrap();
        assert_eq!(a, b);
        let other = identity_signature(
            "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
        )
        .unwrap();
        assert_ne!(a, other);
        assert!(identity_signature("zz").is_err());
        // The message is FROZEN: pin the bytes a hardware wallet will be
        // shown and must sign — any drift orphans every v2 backup.
        assert_eq!(
            blake3::hash(IDENTITY_MESSAGE_V1.as_bytes()).to_hex().to_string(),
            IDENTITY_MESSAGE_HASH_PIN,
        );
    }

    // Frozen vectors for the hardhat key: the legacy pin guarantees the
    // restore fallback keeps reaching pre-flip backups forever; the v2
    // pin freezes the identity message + derivation chain end to end.
    const IDENTITY_MESSAGE_HASH_PIN: &str =
        "048d199807b3af402b0ab9f0ad4b012843d53bfda65b9102bc43a689f5056c9c";
    // == the pointer the 2026-10-06 phase-1 live verify saw for this key
    // (the pre-flip devserver smoke) — the fallback reaches real old lines.
    const LEGACY_POINTER_PIN: &str =
        "884a878e6f9da0ed566278602da3064bbb2f5ed5be0e97cb78238c74c2b3e0ae";
    const V2_POINTER_PIN: &str =
        "d478d0596351025560ddace86f555833601440037b7944309763ca0c3e3f3a09";
    const V2_ENC_PIN: &str =
        "2498b3cc81cc9c9d1d4a6a192d9524ad1fd9b75965a23e637b02be06ceff8bc2";

    #[test]
    fn derivation_vectors_are_pinned() {
        let legacy = derive_keys_legacy(KEY).unwrap();
        assert_eq!(hex::encode(legacy.pointer), LEGACY_POINTER_PIN);
        let v2 = derive_keys(KEY).unwrap();
        assert_eq!(hex::encode(v2.pointer), V2_POINTER_PIN);
        assert_eq!(hex::encode(v2.enc), V2_ENC_PIN);
    }

    #[test]
    fn state_resets_when_identity_changes() {
        let dir = std::env::temp_dir()
            .join(format!("wi-backup-identity-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mgr = BackupManager::new(dir.to_str());
        // A pre-phase-1 state file carries no identity stamp: it must
        // read as a foreign line (hidden last, clean object cache) for
        // EVERY identity — its cache and head chain belong to the old
        // raw-key derivation.
        let mut old = BackupState::default();
        old.objects.insert("aaa".into(), ("bWFw".into(), 9));
        old.last = Some(serde_json::json!({"ms": 1, "head": "ff", "backups": 2}));
        mgr.save_state(&old);
        assert!(mgr.last_json(Some("f00d")).is_none());
        let fresh = mgr.state_for("f00d");
        assert!(fresh.objects.is_empty());
        assert!(fresh.last.is_none());
        assert_eq!(fresh.identity.as_deref(), Some("f00d"));
        // Once stamped, the same identity sees its own state…
        mgr.save_state(&fresh);
        let mut mine = mgr.state_for("f00d");
        mine.objects.insert("bbb".into(), ("bWFw".into(), 4));
        mine.last = Some(serde_json::json!({"ms": 2, "head": "aa", "backups": 1}));
        mgr.save_state(&mine);
        assert_eq!(
            mgr.last_json(Some("f00d"))
                .unwrap()
                .get("backups")
                .and_then(|b| b.as_u64()),
            Some(1)
        );
        assert_eq!(mgr.state_for("f00d").objects.len(), 1);
        // …while a different identity (swapped wallet) starts clean, and
        // an identity-less caller (no wallet) sees no last either.
        assert!(mgr.last_json(Some("beef")).is_none());
        assert!(mgr.last_json(None).is_none());
        assert!(mgr.state_for("beef").objects.is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn bad_wallet_keys_are_refused() {
        assert!(derive_keys("zz").is_err());
        assert!(derive_keys("0x1234").is_err());
        assert!(derive_keys("").is_err());
    }

    #[test]
    fn read_keys_round_trip_the_derived_identity() {
        // The hex a master publishes over My W@tch parses back to the
        // exact identity its wallet derives — the whole phase-2 handoff.
        let keys = derive_keys(KEY).unwrap();
        let parsed = read_keys_from_hex(
            &hex::encode(keys.pointer),
            &hex::encode(keys.enc),
        )
        .unwrap();
        assert_eq!(parsed.pointer, keys.pointer);
        assert_eq!(parsed.enc, keys.enc);
        assert_eq!(keys.read().pointer, keys.pointer);
        assert_eq!(keys.read().enc, keys.enc);
        // A follower can open what the master sealed, and nothing else.
        let (hash, ct) = seal_object(&keys.enc, b"shared state");
        assert_eq!(
            open_object(&parsed.enc, &hash, &ct).unwrap(),
            b"shared state"
        );
        // Malformed halves are refused with a pointer at which half.
        let ok = &hex::encode(keys.pointer);
        assert!(read_keys_from_hex("zz", ok).unwrap_err().contains("pointer"));
        assert!(read_keys_from_hex(ok, "1234").unwrap_err().contains("read key"));
        assert!(read_keys_from_hex("", "").is_err());
    }

    #[test]
    fn follow_arg_validation_needs_no_wallet() {
        let dir = std::env::temp_dir()
            .join(format!("wi-backup-followargs-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let engine: &'static Engine =
            Box::leak(Box::new(Engine::new(None, dir.to_str())));
        engine.wallet.disable_keychain();
        let ptr = "ab".repeat(32);
        let key = "cd".repeat(32);
        // Reading is free: a wallet-less device may follow, so only the
        // arguments themselves are vetted here.
        let err = engine
            .start_follow("nothex", &key, "/tmp/x".into())
            .unwrap_err();
        assert!(err.contains("pointer"), "{err}");
        let err = engine
            .start_follow(&ptr, "short", "/tmp/x".into())
            .unwrap_err();
        assert!(err.contains("read key"), "{err}");
        let err = engine.start_follow(&ptr, &key, "  ".into()).unwrap_err();
        assert!(err.contains("art_dir"), "{err}");
        let _ = std::fs::remove_dir_all(&dir);
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

    /// Local staging must produce exactly what `data_upload` would: a
    /// data map that decrypts the staged chunks back to the blob, with
    /// every chunk filed under its content address.
    #[test]
    fn staged_blobs_decrypt_from_their_own_chunks() {
        let keys = derive_keys(KEY).unwrap();
        let plain: Vec<u8> = (0..200_000u32).flat_map(|i| i.to_le_bytes()).collect();
        let (_, sealed) = seal_object(&keys.enc, &plain);
        let mut chunks = HashMap::new();
        let map = stage_blob(&mut chunks, sealed.clone()).unwrap();
        assert!(chunks.len() >= 3);
        for (addr, content) in &chunks {
            assert_eq!(*addr, ant_core::data::compute_address(content));
        }
        let staged: Vec<self_encryption::EncryptedChunk> = chunks
            .values()
            .map(|content| self_encryption::EncryptedChunk { content: content.clone() })
            .collect();
        let back = self_encryption::decrypt(&map, &staged).unwrap();
        assert_eq!(back.as_ref(), sealed.as_slice());
        // Deterministic: an unchanged object stages the identical chunks
        // (so it is found already stored and costs nothing).
        let mut again = HashMap::new();
        stage_blob(&mut again, sealed).unwrap();
        assert_eq!(
            chunks.keys().collect::<std::collections::BTreeSet<_>>(),
            again.keys().collect::<std::collections::BTreeSet<_>>()
        );
        // Too small to self-encrypt is an error, not a panic.
        assert!(stage_blob(&mut again, vec![1, 2]).is_err());
    }

    fn poster(n: usize, size: usize) -> (String, Vec<u8>) {
        let bytes: Vec<u8> = (0..size).map(|i| (i * 31 + n * 7 + n / 3) as u8).collect();
        (format!("movie_{n}.jpg"), bytes)
    }

    /// A hundred small posters used to be a hundred objects of three
    /// chunks each; packed they are one object of a handful of chunks,
    /// and every file comes back out byte for byte.
    #[test]
    fn artwork_packs_share_chunks_and_round_trip() {
        let keys = derive_keys(KEY).unwrap();
        let files: Vec<_> = (0..100).map(|n| poster(n, 40_000 + n)).collect();
        let packing = pack_art(files.clone(), &BTreeMap::new(), |_| false, PACK_TARGET_BYTES);
        assert_eq!(packing.packs.len(), 1);
        assert_eq!(packing.entries.len(), 100);
        assert_eq!(packing.new_locs.len(), 100);

        let (pack_hash, plain) = &packing.packs[0];
        let (sealed_hash, sealed) = seal_object(&keys.enc, plain);
        assert_eq!(&sealed_hash, pack_hash);
        let mut chunks = HashMap::new();
        let map = stage_blob(&mut chunks, sealed).unwrap();
        assert!(chunks.len() <= 4, "{} chunks", chunks.len());

        let staged: Vec<self_encryption::EncryptedChunk> = chunks
            .values()
            .map(|content| self_encryption::EncryptedChunk { content: content.clone() })
            .collect();
        let back = self_encryption::decrypt(&map, &staged).unwrap();
        let opened = open_object(&keys.enc, pack_hash, &back).unwrap();
        for ((file, hash, loc), (name, bytes)) in packing.entries.iter().zip(&files) {
            assert_eq!(file, name);
            assert_eq!(&loc.pack, pack_hash);
            assert_eq!(unpack_art(&opened, hash, loc).unwrap(), bytes.as_slice());
        }
        // A wrong range or a wrong hash is refused.
        let (_, hash, loc) = &packing.entries[3];
        let shifted = ArtLoc { off: loc.off + 1, ..loc.clone() };
        assert!(unpack_art(&opened, hash, &shifted).is_err());
        let outside = ArtLoc { off: opened.len() as u64, ..loc.clone() };
        assert!(unpack_art(&opened, hash, &outside).is_err());
        let huge = ArtLoc { off: u64::MAX, len: 2, pack: loc.pack.clone() };
        assert!(unpack_art(&opened, hash, &huge).is_err());
    }

    /// A pack is never rewritten: the next backup packs only what no
    /// stored pack holds, and unchanged artwork adds nothing.
    #[test]
    fn later_backups_pack_only_new_artwork() {
        let first: Vec<_> = (0..10).map(|n| poster(n, 5_000)).collect();
        let one = pack_art(first.clone(), &BTreeMap::new(), |_| false, PACK_TARGET_BYTES);
        let known: BTreeMap<String, ArtLoc> = one.new_locs.iter().cloned().collect();
        let stored = one.packs[0].0.clone();

        // Nothing changed: nothing to pack, every file keeps its place.
        let same = pack_art(first.clone(), &known, |p| p == stored, PACK_TARGET_BYTES);
        assert!(same.packs.is_empty());
        assert!(same.new_locs.is_empty());
        assert_eq!(same.entries, one.entries);

        // One new poster: a pack holding just that file.
        let mut second = first.clone();
        second.push(poster(99, 7_000));
        let two = pack_art(second, &known, |p| p == stored, PACK_TARGET_BYTES);
        assert_eq!(two.packs.len(), 1);
        assert_eq!(two.packs[0].1.len(), 7_000);
        assert_eq!(two.new_locs.len(), 1);
        assert_eq!(two.entries.len(), 11);
        assert_eq!(two.entries[..10], one.entries[..]);

        // A pack the store no longer vouches for is packed again.
        let lost = pack_art(first, &known, |_| false, PACK_TARGET_BYTES);
        assert_eq!(lost.new_locs.len(), 10);
    }

    #[test]
    fn packs_close_at_the_target_and_fold_duplicates() {
        let mut files: Vec<_> = (0..5).map(|n| poster(n, 400)).collect();
        // The same bytes under a second name are stored once.
        files.push(("copy.jpg".into(), files[0].1.clone()));
        let packing = pack_art(files, &BTreeMap::new(), |_| false, 1_000);
        // 400-byte files, 1000-byte target: 2 + 2 + 1.
        assert_eq!(
            packing.packs.iter().map(|(_, p)| p.len()).collect::<Vec<_>>(),
            vec![800, 800, 400]
        );
        assert_eq!(packing.new_locs.len(), 5);
        assert_eq!(packing.entries.len(), 6);
        assert_eq!(packing.entries[5].2, packing.entries[0].2);
        for (pack, plain) in &packing.packs {
            assert_eq!(pack, &object_hash(plain));
        }
        // A file larger than the target still gets a pack of its own.
        let big = pack_art(vec![poster(1, 5_000)], &BTreeMap::new(), |_| false, 1_000);
        assert_eq!(big.packs.len(), 1);
    }

    /// The in-memory write keys answer only for the wallet and backup
    /// line they were derived for, and are gone after a wallet change.
    #[test]
    fn kept_write_keys_are_bound_to_wallet_and_line() {
        let manager = BackupManager::new(None);
        let keys = Arc::new(derive_keys(KEY).unwrap());
        let pointer = keys.pointer;
        assert!(manager.kept_keys("0xAbC", &pointer).is_none());
        manager.keep_keys("0xAbC", keys);
        assert!(manager.kept_keys("0xabc", &pointer).is_some());
        assert!(manager.kept_keys("0xdef", &pointer).is_none());
        assert!(manager.kept_keys("0xabc", &[7u8; 32]).is_none());
        manager.forget_keys();
        assert!(manager.kept_keys("0xabc", &pointer).is_none());
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
        let loc = ArtLoc { pack: "abc".into(), off: 5, len: 9 };
        state.art.insert("f00".into(), loc.clone());
        state.save(&path);
        let loaded = BackupState::load(&path);
        assert_eq!(loaded.art.get("f00"), Some(&loc));
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
