//! Upload-all: one paid batch for many files (hardware-wallet plan,
//! phase 0 — docs/PLAN in CLAUDE.md 2026-10-10).
//!
//! The per-file upload path (`upload.rs`) pays once per file — a 10-file
//! batch is 10+ wallet transactions. This module pools EVERY chunk of the
//! whole batch into ant-core's multi-record upload driver
//! (`Client::upload_records`), which pays one `payForMerkleTree`
//! transaction per ≤256-chunk merkle sub-batch — so a typical batch is
//! ONE payment confirmation, and the same seam later takes an external
//! signer (Ledger/Trezor) without reshaping the flow: the adapter below
//! is the only place money is signed.
//!
//! Flow: encrypt every file locally into a disk spill (no network, no
//! payment — self-encryption is deterministic, so the chunk set is the
//! file's identity) → hand the pooled chunk records to `upload_records`
//! with `PaymentMode::Merkle` (the planner skips chunks already on the
//! network, partitions the rest ≤256 per tree, pays each tree in one
//! transaction, stores with close-group replication + retries) → store
//! each file's root map locally so every uploaded title is instantly
//! playable/exportable, exactly like the single-file path.
//!
//! Crash safety: the driver's recovery state (paid proofs, valid 7 days)
//! checkpoints to disk after every payment and store wave, keyed by the
//! batch's chunk fingerprint. A re-run of the same batch restores it and
//! never re-pays what a previous run already paid — failed stores retry
//! FREE inside the proof window. The one unrecoverable sliver: a crash in
//! the seconds between broadcasting a payment and confirming it leaves a
//! pending attempt we cannot reconcile without a tx journal; that
//! checkpoint is discarded (one sub-batch may be paid again) rather than
//! guessed at.

use std::collections::{HashMap, HashSet};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};

use ant_core::data::client::batch::ChunkPaymentPlan;
use ant_core::data::client::upload::{
    MerkleUploadPayment, UploadAdapter, UploadPayment, UploadRecord,
};
use ant_core::data::client::upload_state::UploadState;
use ant_core::data::error::Error as AntError;
use ant_core::data::{DataMap, PaymentMode, PreparedMerkleBatch, Wallet};
use bytes::Bytes;

use crate::engine::Engine;

/// Merkle tree capacity (`ant_protocol::evm::MAX_LEAVES`): one wallet
/// transaction pays for up to this many chunks. Mirrored here for the
/// payments-count estimate; the driver does the real partitioning.
pub const CHUNKS_PER_PAYMENT: usize = 256;

#[derive(Clone)]
pub struct BatchFile {
    pub name: String,
    pub path: PathBuf,
    /// pending → uploading → done | failed
    pub status: &'static str,
    pub error: Option<String>,
    /// Derived library address (the `.datamap` import identity), set once
    /// the file is encrypted.
    pub address: Option<String>,
    pub size: u64,
    pub chunks: usize,
}

#[derive(Clone)]
pub struct BatchJobState {
    /// starting → encrypting → quoting → paying → storing → finishing →
    /// done | error
    pub phase: &'static str,
    /// Phase-scoped progress: encrypting counts files, quoting/storing
    /// count chunks.
    pub done: usize,
    pub total: usize,
    /// Merkle payment transactions: one per ≤256-chunk sub-batch.
    /// `payments_total` is the upper-bound estimate (already-stored
    /// chunks can only lower it).
    pub payments_done: usize,
    pub payments_total: usize,
    pub files: Vec<BatchFile>,
    pub error: Option<String>,
    pub cost_atto: String,
    pub gas_wei: u128,
}

impl BatchJobState {
    pub fn to_json(&self, id: u64) -> serde_json::Value {
        serde_json::json!({
            "id": id,
            "phase": self.phase,
            "done": self.done,
            "total": self.total,
            "payments_done": self.payments_done,
            "payments_total": self.payments_total,
            "error": self.error,
            "cost_atto": self.cost_atto,
            "gas_wei": self.gas_wei.to_string(),
            "files": self.files.iter().map(|f| serde_json::json!({
                "name": f.name,
                "path": f.path.to_string_lossy(),
                "status": f.status,
                "error": f.error,
                "address": f.address,
                "size": f.size,
                "chunks": f.chunks,
            })).collect::<Vec<_>>(),
        })
    }
}

impl Engine {
    /// Kick off a paid batch upload; returns the job id to poll on
    /// `GET /upload/batch/{id}`. Shares the single active-upload slot
    /// with `start_upload` — paid work never runs concurrently.
    pub fn start_batch_upload(
        &'static self,
        files: Vec<(PathBuf, String)>,
    ) -> Result<u64, String> {
        if files.is_empty() {
            return Err("no files in the batch".into());
        }
        for (path, _) in &files {
            if !path.is_file() {
                return Err(format!("no such file: {}", path.display()));
            }
        }
        if self.wallet.load().is_none() {
            return Err("no upload wallet configured — set one up in Settings → Wallet".into());
        }
        if self.uploads.active.swap(true, Ordering::SeqCst) {
            return Err("an upload is already running — wait for it to finish".into());
        }
        let id = self.uploads.next_id.fetch_add(1, Ordering::SeqCst) + 1;
        let job = Arc::new(Mutex::new(BatchJobState {
            phase: "starting",
            done: 0,
            total: files.len(),
            payments_done: 0,
            payments_total: 0,
            files: files
                .iter()
                .map(|(path, name)| BatchFile {
                    name: name.clone(),
                    path: path.clone(),
                    status: "pending",
                    error: None,
                    address: None,
                    size: 0,
                    chunks: 0,
                })
                .collect(),
            error: None,
            cost_atto: "0".into(),
            gas_wei: 0,
        }));
        self.uploads
            .batch_jobs
            .lock()
            .unwrap()
            .insert(id, job.clone());
        tokio::spawn(run_batch(self, id, job));
        Ok(id)
    }

    /// Where batch spills and payment checkpoints live; `None` without a
    /// data dir (devserver/tests) — then spills go to the system temp dir
    /// and checkpoints are skipped.
    fn batch_dir(&self) -> Option<PathBuf> {
        self.data_dir().map(|d| d.join("batch-upload"))
    }
}

async fn run_batch(engine: &'static Engine, id: u64, job: Arc<Mutex<BatchJobState>>) {
    let result = drive_batch(engine, id, &job).await;
    {
        let mut s = job.lock().unwrap();
        match result {
            Ok(()) => s.phase = "done",
            Err(e) => {
                s.phase = "error";
                // Files the per-file finish never reached (e.g. the whole
                // batch died at the payment) read failed, not stuck
                // "uploading" — the job error is their reason.
                for f in s.files.iter_mut() {
                    if f.status != "done" && f.status != "failed" {
                        f.status = "failed";
                    }
                }
                s.error = Some(e);
            }
        }
    }
    engine.uploads.active.store(false, Ordering::SeqCst);
}

/// One encrypted file, spilled to disk.
struct EncryptedFile {
    /// (chunk address, size) in upload order — data chunks plus the root
    /// map's shrink wrapper chunks, exactly what the single-file upload
    /// stores.
    chunks: Vec<([u8; 32], u64)>,
    /// Derived library address + the expanded root map to store locally.
    address: [u8; 32],
    root: DataMap,
    size: u64,
}

async fn drive_batch(
    engine: &'static Engine,
    id: u64,
    job: &Arc<Mutex<BatchJobState>>,
) -> Result<(), String> {
    let (paths, total_files) = {
        let s = job.lock().unwrap();
        (
            s.files
                .iter()
                .map(|f| f.path.clone())
                .collect::<Vec<_>>(),
            s.files.len(),
        )
    };

    // ---- 1) Encrypt everything locally (free, no network) ---------------
    let spill_root = engine
        .batch_dir()
        .unwrap_or_else(std::env::temp_dir)
        .join(format!("spill-{id}"));
    std::fs::create_dir_all(&spill_root)
        .map_err(|e| format!("could not create the staging folder: {e}"))?;
    let _cleanup = SpillCleanup(spill_root.clone());

    {
        let mut s = job.lock().unwrap();
        s.phase = "encrypting";
        s.done = 0;
        s.total = total_files;
    }
    let mut encrypted: Vec<EncryptedFile> = Vec::with_capacity(paths.len());
    for (i, path) in paths.iter().enumerate() {
        let spill = spill_root.clone();
        let p = path.clone();
        // CPU + disk heavy; keep it off the async workers.
        let enc = tokio::task::spawn_blocking(move || encrypt_file_to_spill(&spill, &p))
            .await
            .map_err(|e| format!("encryption task failed: {e}"))?
            .map_err(|e| format!("could not read/encrypt {}: {e}", path.display()))?;
        let mut s = job.lock().unwrap();
        s.files[i].size = enc.size;
        s.files[i].chunks = enc.chunks.len();
        s.files[i].address = Some(hex::encode(enc.address));
        s.files[i].status = "uploading";
        s.done = i + 1;
        encrypted.push(enc);
    }

    // ---- 2) Pool every chunk into one record set ------------------------
    let mut seen = HashSet::new();
    let mut records = Vec::new();
    for enc in &encrypted {
        for &(addr, size) in &enc.chunks {
            if seen.insert(addr) {
                records.push(UploadRecord {
                    address: addr,
                    size,
                    index: records.len(),
                });
            }
        }
    }
    let total_chunks = records.len();
    {
        let mut s = job.lock().unwrap();
        s.payments_total = total_chunks.div_ceil(CHUNKS_PER_PAYMENT);
        s.phase = "quoting";
        s.done = 0;
        s.total = total_chunks;
    }

    // ---- 3) Restore the payment checkpoint, if one is clean -------------
    let fingerprint = batch_fingerprint(&records);
    let ckpt_path = engine
        .batch_dir()
        .map(|d| d.join(format!("batch-{}.ckpt", &fingerprint[..16])));
    let mut state = load_checkpoint(ckpt_path.as_deref());

    // ---- 4) Client for quoting/storing, wallet for paying ---------------
    let client = engine.client().await?;
    let (key, _) = engine
        .wallet
        .load()
        .ok_or("no upload wallet configured — set one up in Settings → Wallet")?;
    let wallet = crate::wallet::evm_wallet(&key)?;

    let adapter = BatchAdapter {
        spill: spill_root.clone(),
        wallet,
        job: job.clone(),
        ckpt_path: ckpt_path.clone(),
    };

    // ---- 5) One pooled upload: pay per merkle sub-batch, store all ------
    let outcome = client
        .upload_records(records, &mut state, &adapter, PaymentMode::Merkle)
        .await;

    let (stored, cost_atto, gas_wei, failure) = match outcome {
        Ok(out) => (
            out.addresses.into_iter().collect::<HashSet<_>>(),
            out.amount.to_string(),
            out.gas,
            None,
        ),
        Err(AntError::PartialUpload {
            stored,
            failed,
            spend,
            reason,
            ..
        }) => {
            // Paid proofs survive in the checkpoint — the retry is free.
            let per_addr: HashMap<[u8; 32], String> = failed.into_iter().collect();
            (
                stored.into_iter().collect::<HashSet<_>>(),
                spend.storage_cost_atto.clone(),
                spend.gas_cost_wei,
                Some((per_addr, reason)),
            )
        }
        Err(e) => {
            return Err(format!(
                "batch upload failed: {e} — anything already paid for is \
                 remembered; running the same batch again never pays twice \
                 for it"
            ));
        }
    };

    // ---- 6) Per-file finish: root maps for fully-stored files -----------
    {
        let mut s = job.lock().unwrap();
        s.phase = "finishing";
        s.cost_atto = cost_atto;
        s.gas_wei = gas_wei;
    }
    let mut any_failed = false;
    for (i, enc) in encrypted.iter().enumerate() {
        let missing: Vec<_> = enc
            .chunks
            .iter()
            .filter(|(addr, _)| !stored.contains(addr))
            .collect();
        let mut s = job.lock().unwrap();
        if missing.is_empty() {
            engine.store_root_map(enc.address, &enc.root);
            s.files[i].status = "done";
        } else {
            any_failed = true;
            s.files[i].status = "failed";
            let reason = failure
                .as_ref()
                .and_then(|(per_addr, _)| {
                    missing.iter().find_map(|(a, _)| per_addr.get(a).cloned())
                })
                .or_else(|| failure.as_ref().map(|(_, r)| r.clone()))
                .unwrap_or_else(|| "some chunks did not store".into());
            s.files[i].error = Some(format!(
                "{} of {} chunks did not store — {reason}",
                missing.len(),
                enc.chunks.len()
            ));
        }
    }

    if any_failed {
        let reason = failure
            .map(|(_, r)| r)
            .unwrap_or_else(|| "some chunks did not store".into());
        return Err(format!(
            "the batch did not finish: {reason} — everything paid for is \
             remembered (payments stay valid for 7 days), so uploading the \
             same batch again only retries the failed stores, free"
        ));
    }

    // Full success: the paid-proof checkpoint has served its purpose.
    if let Some(path) = &ckpt_path {
        let _ = std::fs::remove_file(path);
    }
    Ok(())
}

/// Deletes the spill directory when the job ends, success or failure —
/// chunks are re-derived by re-encrypting, so nothing is lost.
struct SpillCleanup(PathBuf);
impl Drop for SpillCleanup {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// blake3 over the sorted unique chunk addresses: the batch's identity for
/// checkpoint reuse (same files → same chunks → same fingerprint).
fn batch_fingerprint(records: &[UploadRecord]) -> String {
    let mut addrs: Vec<[u8; 32]> = records.iter().map(|r| r.address).collect();
    addrs.sort_unstable();
    let mut hasher = blake3::Hasher::new();
    for a in &addrs {
        hasher.update(a);
    }
    hex::encode(hasher.finalize().as_bytes())
}

/// Restore a previous run's payment state when it is clean. A checkpoint
/// holding a PENDING payment attempt died inside the payment window; with
/// no tx journal its outcome is unknowable, so it is discarded (and that
/// one sub-batch may be paid again) rather than reconciled by guesswork.
fn load_checkpoint(path: Option<&Path>) -> UploadState {
    let Some(path) = path else {
        return UploadState::default();
    };
    let Ok(bytes) = std::fs::read(path) else {
        return UploadState::default();
    };
    match UploadState::restore(&bytes) {
        Ok(state) if state.pending_payment.is_none() => {
            tracing::info!("batch upload: resuming from payment checkpoint");
            state
        }
        Ok(_) => {
            tracing::warn!(
                "batch upload: checkpoint died mid-payment — discarding it \
                 (its outcome is unknowable without a tx journal)"
            );
            let _ = std::fs::remove_file(path);
            UploadState::default()
        }
        Err(e) => {
            tracing::warn!("batch upload: unreadable checkpoint discarded: {e}");
            let _ = std::fs::remove_file(path);
            UploadState::default()
        }
    }
}

/// Stream-encrypt one file into the spill dir (one file per chunk, named
/// by content address — identical chunks across files share bytes), and
/// recover the ROOT data map locally: every chunk is on disk, so the
/// child-map expansion that `upload.rs` does over the network happens
/// with zero network rounds here.
fn encrypt_file_to_spill(spill: &Path, path: &Path) -> Result<EncryptedFile, String> {
    let file = std::fs::File::open(path).map_err(|e| format!("open failed: {e}"))?;
    let size = file
        .metadata()
        .map_err(|e| format!("stat failed: {e}"))?
        .len();
    if (size as usize) < self_encryption::MIN_ENCRYPTABLE_BYTES {
        return Err("file too small to upload".into());
    }
    let mut reader = std::io::BufReader::with_capacity(1 << 20, file);
    let blocks = std::iter::from_fn(move || {
        let mut buf = vec![0u8; 1 << 20];
        match reader.read(&mut buf) {
            Ok(0) => None,
            Ok(n) => {
                buf.truncate(n);
                Some(Bytes::from(buf))
            }
            // stream_encrypt's iterator is infallible; a read error here
            // truncates the stream, which the size check below catches.
            Err(_) => None,
        }
    });
    let mut stream = self_encryption::stream_encrypt(size as usize, blocks)
        .map_err(|e| format!("encryption failed: {e}"))?;
    let mut chunks = Vec::new();
    for item in stream.chunks() {
        let (name, content) =
            item.map_err(|e| format!("encryption failed: {e}"))?;
        let addr: [u8; 32] = name.0;
        let chunk_path = spill.join(hex::encode(addr));
        if !chunk_path.exists() {
            std::fs::write(&chunk_path, &content)
                .map_err(|e| format!("staging write failed: {e}"))?;
        }
        chunks.push((addr, content.len() as u64));
    }
    let shrunk = stream
        .into_datamap()
        .ok_or("encryption ended without a data map")?;
    let (address, root) = if shrunk.is_child() {
        let addr = crate::verify::shrunk_map_address(&shrunk)?;
        let mut fetch = |name: xor_name::XorName| -> Result<Bytes, self_encryption::Error> {
            std::fs::read(spill.join(hex::encode(name.0)))
                .map(Bytes::from)
                .map_err(|e| self_encryption::Error::Generic(format!("spill read: {e}")))
        };
        let root = self_encryption::get_root_data_map(shrunk, &mut fetch)
            .map_err(|e| format!("root map recovery failed: {e}"))?;
        crate::verify::verify_root_map(&addr, &root)?;
        (addr, root)
    } else {
        (crate::verify::derive_address(&shrunk)?, shrunk)
    };
    Ok(EncryptedFile {
        chunks,
        address,
        root,
        size,
    })
}

/// The money seam: byte staging + wallet submission for the pooled batch.
/// Phase 2 of the hardware-wallet plan swaps the `Wallet` here for an
/// external signer — `pay`/`pay_merkle` are the only two places a batch
/// spends.
struct BatchAdapter {
    spill: PathBuf,
    wallet: Wallet,
    job: Arc<Mutex<BatchJobState>>,
    ckpt_path: Option<PathBuf>,
}

impl BatchAdapter {
    fn set_phase(&self, phase: &'static str) {
        let mut s = self.job.lock().unwrap();
        if s.phase != phase {
            s.phase = phase;
            s.done = 0;
        }
    }
}

#[async_trait::async_trait]
impl UploadAdapter for BatchAdapter {
    async fn load(&self, record: UploadRecord) -> ant_core::data::Result<Bytes> {
        let path = self.spill.join(hex::encode(record.address));
        tokio::fs::read(&path).await.map(Bytes::from).map_err(|e| {
            AntError::InvalidData(format!("staged chunk unreadable: {e}"))
        })
    }

    /// Single-node fallback payments (only when fewer than 2 chunks need
    /// paying — everything else rides the merkle path). One batched
    /// `pay_for_quotes` call; the driver validates the reported total.
    async fn pay(&self, plans: &[ChunkPaymentPlan]) -> ant_core::data::Result<UploadPayment> {
        self.set_phase("paying");
        let mut quote_payments = Vec::new();
        let mut amount = ant_core::data::U256::ZERO;
        for plan in plans {
            for q in &plan.payment.quotes {
                quote_payments.push((q.quote_hash, q.rewards_address, q.amount));
            }
            amount += plan.payment.total_amount();
        }
        let (txs, gas) = self
            .wallet
            .pay_for_quotes(quote_payments)
            .await
            .map_err(|e| AntError::Payment(format!("payment failed: {e:?}")))?;
        {
            let mut s = self.job.lock().unwrap();
            s.payments_done += 1;
        }
        // Upper-bound wei (limit × max fee) — evmlib reports the submitted
        // transaction's gas config, not the settled receipt; UI shows "≈".
        let gas_wei = u128::from(gas.gas_with_buffer)
            .saturating_mul(gas.max_fee_per_gas.unwrap_or(0));
        Ok(UploadPayment {
            transactions: txs.into_iter().collect(),
            amount,
            gas: gas_wei,
        })
    }

    /// One merkle sub-batch = one on-chain `payForMerkleTree` call. The
    /// wallet checks balance and token allowance itself (approving when
    /// needed) and returns the confirmed winner pool.
    async fn pay_merkle(
        &self,
        batch: &PreparedMerkleBatch,
    ) -> ant_core::data::Result<MerkleUploadPayment> {
        self.set_phase("paying");
        let (winner_pool, amount, gas) = self
            .wallet
            .pay_for_merkle_tree(
                batch.depth,
                batch.pool_commitments.clone(),
                batch.merkle_payment_timestamp,
            )
            .await
            .map_err(|e| AntError::Payment(format!("payment failed: {e}")))?;
        {
            let mut s = self.job.lock().unwrap();
            s.payments_done += 1;
        }
        let gas_wei = u128::from(gas.gas_with_buffer)
            .saturating_mul(gas.max_fee_per_gas.unwrap_or(0));
        Ok(MerkleUploadPayment {
            winner_pool,
            amount,
            gas: gas_wei,
        })
    }

    /// Persist the driver's recovery state (paid proofs) so a crashed or
    /// failed batch resumes without paying again.
    async fn checkpoint(
        &self,
        state: &UploadState,
        _payment: Option<&UploadPayment>,
    ) -> ant_core::data::Result<()> {
        let Some(path) = &self.ckpt_path else {
            return Ok(());
        };
        let bytes = state
            .checkpoint()
            .map_err(|e| AntError::InvalidData(format!("checkpoint encode: {e}")))?;
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        tokio::fs::write(path, bytes).await.map_err(|e| {
            AntError::InvalidData(format!("checkpoint write failed: {e}"))
        })
    }

    // ---- progress hooks → the polled job record -------------------------

    fn checked(&self, checked: usize, total: usize) {
        let mut s = self.job.lock().unwrap();
        s.phase = "quoting";
        s.done = checked;
        s.total = total;
    }

    fn payment_quotes(&self, completed: usize, total: usize) {
        let mut s = self.job.lock().unwrap();
        s.phase = "quoting";
        s.done = completed;
        s.total = total;
    }

    fn stored(&self, stored: usize, total: usize) {
        let mut s = self.job.lock().unwrap();
        s.phase = "storing";
        s.done = stored;
        s.total = total;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lcg_bytes(len: usize) -> Vec<u8> {
        let mut v = Vec::with_capacity(len);
        let mut x = 0x51ED2701u64;
        while v.len() < len {
            x = x
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            v.extend_from_slice(&x.to_le_bytes());
        }
        v.truncate(len);
        v
    }

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "wi-batch-{name}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// The spill encryption must reproduce the exact identity the
    /// single-file upload path derives: same chunk set (incl. shrink
    /// wrappers), same derived address, same root map.
    #[test]
    fn spill_encryption_matches_single_file_identity() {
        let dir = temp_dir("identity");
        let content = lcg_bytes(14 * 1024 * 1024); // >3 chunks → child map
        let src = dir.join("movie.bin");
        std::fs::write(&src, &content).unwrap();
        let spill = dir.join("spill");
        std::fs::create_dir_all(&spill).unwrap();

        let enc = encrypt_file_to_spill(&spill, &src).unwrap();

        // Reference identity via the in-memory path (upload.rs test idiom).
        let (shrunk, ref_chunks) = self_encryption::encrypt(content.into()).unwrap();
        assert!(shrunk.is_child());
        let ref_addr =
            *blake3::hash(&rmp_serde::to_vec(&shrunk).unwrap()).as_bytes();
        assert_eq!(enc.address, ref_addr);
        assert_eq!(enc.size, 14 * 1024 * 1024);
        assert_eq!(enc.root.original_file_size(), 14 * 1024 * 1024);
        assert!(!enc.root.is_child());

        // Chunk set equality (spill carries data + wrapper chunks).
        let got: HashSet<[u8; 32]> = enc.chunks.iter().map(|(a, _)| *a).collect();
        let want: HashSet<[u8; 32]> = ref_chunks
            .iter()
            .map(|c| self_encryption::hash::content_hash(&c.content).0)
            .collect();
        assert_eq!(got, want);
        // Every chunk is on disk under its address with matching bytes.
        for (addr, size) in &enc.chunks {
            let bytes = std::fs::read(spill.join(hex::encode(addr))).unwrap();
            assert_eq!(bytes.len() as u64, *size);
            assert_eq!(blake3::hash(&bytes).as_bytes(), addr);
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn fingerprint_is_order_independent_and_content_bound() {
        let rec = |addr: u8| UploadRecord {
            address: [addr; 32],
            size: 1,
            index: 0,
        };
        let a = batch_fingerprint(&[rec(1), rec(2)]);
        let b = batch_fingerprint(&[rec(2), rec(1)]);
        let c = batch_fingerprint(&[rec(1), rec(3)]);
        assert_eq!(a, b);
        assert_ne!(a, c);
    }

    #[test]
    fn checkpoint_with_pending_payment_is_discarded() {
        let dir = temp_dir("ckpt");
        let path = dir.join("batch.ckpt");
        // Clean state round-trips.
        let state = UploadState::default();
        std::fs::write(&path, state.checkpoint().unwrap()).unwrap();
        let restored = load_checkpoint(Some(&path));
        assert!(restored.pending_payment.is_none());
        assert!(path.exists());
        // A pending payment attempt poisons the checkpoint: discarded and
        // deleted rather than reconciled by guesswork.
        let mut dirty = UploadState::default();
        dirty.pending_payment =
            Some(ant_core::data::client::upload_state::PaymentAttempt {
                merkle: true,
                addresses: Vec::new(),
                submissions: Vec::new(),
                receipt: None,
            });
        std::fs::write(&path, dirty.checkpoint().unwrap()).unwrap();
        let restored = load_checkpoint(Some(&path));
        assert!(restored.pending_payment.is_none());
        assert!(!path.exists(), "poisoned checkpoint must be deleted");
        // Garbage is discarded the same way.
        std::fs::write(&path, b"garbage").unwrap();
        let _ = load_checkpoint(Some(&path));
        assert!(!path.exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn payments_estimate_matches_merkle_capacity() {
        assert_eq!(1usize.div_ceil(CHUNKS_PER_PAYMENT), 1);
        assert_eq!(256usize.div_ceil(CHUNKS_PER_PAYMENT), 1);
        assert_eq!(257usize.div_ceil(CHUNKS_PER_PAYMENT), 2);
    }

    /// Batch jobs share the one active-upload slot and refuse bad input
    /// up front — no file, no wallet, or a job already running.
    #[tokio::test]
    async fn start_batch_refusals() {
        let dir = temp_dir("refusals");
        let engine: &'static Engine =
            Box::leak(Box::new(Engine::new(None, dir.to_str())));
        engine.wallet.disable_keychain();
        engine.follow_keys.disable_keychain();
        let src = dir.join("a.bin");
        std::fs::write(&src, lcg_bytes(8192)).unwrap();

        let err = engine.start_batch_upload(vec![]).unwrap_err();
        assert!(err.contains("no files"));
        let err = engine
            .start_batch_upload(vec![(dir.join("missing.bin"), "x".into())])
            .unwrap_err();
        assert!(err.contains("no such file"));
        let err = engine
            .start_batch_upload(vec![(src.clone(), "a".into())])
            .unwrap_err();
        assert!(err.contains("wallet"));

        engine
            .wallet
            .store("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")
            .unwrap();
        engine.uploads.active.store(true, Ordering::SeqCst);
        let err = engine
            .start_batch_upload(vec![(src, "a".into())])
            .unwrap_err();
        assert!(err.contains("already running"));
        engine.uploads.active.store(false, Ordering::SeqCst);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
