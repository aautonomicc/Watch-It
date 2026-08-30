//! Publish: paid uploads to the network, one at a time, with pollable
//! progress.
//!
//! `Engine::start_upload` spawns ant-core's one-shot internal-wallet
//! upload (`file_upload_with_progress`, PaymentMode::Auto — payment,
//! retries and already-stored dedup all inside ant-core) and mirrors its
//! progress events into a job record the UI polls via
//! `GET /upload/{id}`. On success the resulting root data map goes
//! straight into the map store under its derived address — the exact
//! state a `.datamap` import would have produced, so the new title is
//! playable and exportable like any other entry.
//!
//! Uploads cost real ANT, so only one runs at a time; a second POST
//! while one is active is refused rather than queued (the UI drives one
//! Publish flow anyway, and a queue of paid actions the user forgot
//! about is a footgun).

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use ant_core::data::{PaymentMode, UploadEvent};
use tokio::sync::mpsc;

use crate::engine::Engine;

#[derive(Clone)]
pub struct JobState {
    pub name: String,
    /// starting → encrypting → quoting → paying → storing → done | error
    pub phase: &'static str,
    pub done: usize,
    pub total: usize,
    pub error: Option<String>,
    pub result: Option<Outcome>,
}

#[derive(Clone)]
pub struct Outcome {
    pub address: String,
    pub size: u64,
    pub chunks: usize,
    pub cost_atto: String,
    pub gas_wei: u128,
    /// Channel-publish jobs only: the head sequence number announced for
    /// this manifest. `None` for normal (private) uploads.
    pub seq: Option<u64>,
    /// Channel-publish jobs only: false when the signed head could not be
    /// gossiped yet (channels switch off) and waits for the agent to run
    /// again. Always true for normal uploads.
    pub announced: bool,
}

impl JobState {
    pub fn to_json(&self, id: u64) -> serde_json::Value {
        serde_json::json!({
            "id": id,
            "name": self.name,
            "phase": self.phase,
            "done": self.done,
            "total": self.total,
            "error": self.error,
            "result": self.result.as_ref().map(|r| serde_json::json!({
                "address": r.address,
                "size": r.size,
                "chunks": r.chunks,
                "cost_atto": r.cost_atto,
                "gas_wei": r.gas_wei.to_string(),
                "seq": r.seq,
                "announced": r.announced,
            })),
        })
    }
}

#[derive(Default)]
pub struct UploadManager {
    jobs: Mutex<HashMap<u64, Arc<Mutex<JobState>>>>,
    next_id: AtomicU64,
    active: AtomicBool,
}

impl UploadManager {
    pub fn state(&self, id: u64) -> Option<JobState> {
        let job = self.jobs.lock().unwrap().get(&id).cloned()?;
        let state = job.lock().unwrap().clone();
        Some(state)
    }
}

impl Engine {
    /// Kick off a paid upload; returns the job id to poll. Refused when a
    /// job is already running or no wallet is configured.
    pub fn start_upload(&'static self, path: PathBuf, name: String) -> Result<u64, String> {
        if !path.is_file() {
            return Err(format!("no such file: {}", path.display()));
        }
        if self.wallet.load().is_none() {
            return Err("no upload wallet configured — set one up in Settings → Wallet".into());
        }
        if self.uploads.active.swap(true, Ordering::SeqCst) {
            return Err("an upload is already running — wait for it to finish".into());
        }
        let id = self.uploads.next_id.fetch_add(1, Ordering::SeqCst) + 1;
        let job = Arc::new(Mutex::new(JobState {
            name,
            phase: "starting",
            done: 0,
            total: 0,
            error: None,
            result: None,
        }));
        self.uploads.jobs.lock().unwrap().insert(id, job.clone());
        tokio::spawn(run_upload(self, job, path));
        Ok(id)
    }

    /// Kick off a channel-manifest publish: the file uploads PUBLICLY
    /// (the serialized data map itself becomes a fetchable chunk in the
    /// same payment batch), then the new address is announced as a
    /// signed head on the channel topic. Same single paid slot and same
    /// poll surface as [`Engine::start_upload`].
    pub fn start_channel_publish(
        &'static self,
        path: PathBuf,
        name: String,
    ) -> Result<u64, String> {
        if !path.is_file() {
            return Err(format!("no such file: {}", path.display()));
        }
        if self.wallet.load().is_none() {
            return Err("no upload wallet configured — set one up in Settings → Wallet".into());
        }
        if !self.channels.has_own() {
            return Err("this device has no channel (or its key is missing)".into());
        }
        if self.uploads.active.swap(true, Ordering::SeqCst) {
            return Err("an upload is already running — wait for it to finish".into());
        }
        let id = self.uploads.next_id.fetch_add(1, Ordering::SeqCst) + 1;
        let job = Arc::new(Mutex::new(JobState {
            name,
            phase: "starting",
            done: 0,
            total: 0,
            error: None,
            result: None,
        }));
        self.uploads.jobs.lock().unwrap().insert(id, job.clone());
        tokio::spawn(run_channel_publish(self, job, path));
        Ok(id)
    }
}

async fn run_channel_publish(
    engine: &'static Engine,
    job: Arc<Mutex<JobState>>,
    path: PathBuf,
) {
    let outcome = drive_channel_publish(engine, &job, &path).await;
    {
        let mut state = job.lock().unwrap();
        match outcome {
            Ok(result) => {
                state.phase = "done";
                state.result = Some(result);
            }
            Err(e) => {
                state.phase = "error";
                state.error = Some(e);
            }
        }
    }
    engine.uploads.active.store(false, Ordering::SeqCst);
}

async fn drive_channel_publish(
    engine: &'static Engine,
    job: &Arc<Mutex<JobState>>,
    path: &std::path::Path,
) -> Result<Outcome, String> {
    let client = wallet_client(engine).await?;

    let (tx, rx) = mpsc::channel::<UploadEvent>(64);
    let progress = spawn_progress_mirror(job.clone(), rx);
    let result = client
        .file_upload_public_with_progress(path, PaymentMode::Auto, Some(tx))
        .await
        .map_err(|e| format!("manifest upload failed: {e}"));
    let _ = progress.await;
    let result = result?;

    if result.chunks_failed > 0 {
        return Err(format!(
            "{} of {} chunks failed to store — the manifest is not fully \
             on the network; publish again (already-stored chunks are free)",
            result.chunks_failed, result.total_chunks
        ));
    }
    let manifest_addr = result
        .data_map_address
        .ok_or("public upload returned no data-map address")?;
    let manifest_hex = hex::encode(manifest_addr);

    // Everything below runs after payment + storage succeeded; a failure
    // here must not read as a lost upload.
    let finish_note = |e: String| {
        format!(
            "the manifest upload itself succeeded (all chunks stored and \
             paid for) but finishing failed: {e} — publish again to \
             finish for free (already-stored chunks cost nothing)"
        )
    };
    // Keep the manifest's root map locally so this device can serve and
    // export its own manifest like any imported entry.
    let (addr, root) = uploaded_root_map(engine, &result.data_map)
        .await
        .map_err(&finish_note)?;
    engine.store_root_map(addr, &root);
    // Announce the new head on the channel topic (signed; subscribers
    // verify and follow the highest seq).
    job.lock().unwrap().phase = "announcing";
    let head = engine
        .channels
        .publish_head(&manifest_hex)
        .await
        .map_err(&finish_note)?;

    Ok(Outcome {
        address: manifest_hex,
        size: root.original_file_size() as u64,
        chunks: result.total_chunks,
        cost_atto: result.storage_cost_atto.clone(),
        gas_wei: result.gas_cost_wei,
        seq: head["seq"].as_u64(),
        announced: head["announced"].as_bool().unwrap_or(true),
    })
}

/// A connected client with the upload wallet attached (forcing one
/// reconnect when the client pre-dates the wallet import).
async fn wallet_client(
    engine: &'static Engine,
) -> Result<std::sync::Arc<ant_core::data::Client>, String> {
    let mut client = engine.client().await?;
    if client.wallet().is_none() {
        tracing::info!("client has no wallet attached — reconnecting to attach it");
        engine.reconnect_for_wallet();
        client = engine.client().await?;
        if client.wallet().is_none() {
            return Err("wallet could not be attached to the network client".into());
        }
    }
    Ok(client)
}

/// Mirror ant-core upload events into the job record the UI polls.
fn spawn_progress_mirror(
    job: Arc<Mutex<JobState>>,
    mut rx: mpsc::Receiver<UploadEvent>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        while let Some(ev) = rx.recv().await {
            let mut s = job.lock().unwrap();
            match ev {
                UploadEvent::Encrypting { chunks_done } => {
                    s.phase = "encrypting";
                    s.done = chunks_done;
                }
                UploadEvent::Encrypted { total_chunks } => {
                    s.phase = "quoting";
                    s.done = 0;
                    s.total = total_chunks;
                }
                UploadEvent::QuotingChunks { .. } => s.phase = "quoting",
                UploadEvent::ChunkQuoted { quoted, total } => {
                    s.phase = if quoted >= total { "paying" } else { "quoting" };
                    s.done = quoted;
                    s.total = total;
                }
                UploadEvent::ChunkStored { stored, total } => {
                    s.phase = "storing";
                    s.done = stored;
                    s.total = total;
                }
            }
        }
    })
}

async fn run_upload(engine: &'static Engine, job: Arc<Mutex<JobState>>, path: PathBuf) {
    let outcome = drive_upload(engine, &job, &path).await;
    {
        let mut state = job.lock().unwrap();
        match outcome {
            Ok(result) => {
                state.phase = "done";
                state.result = Some(result);
            }
            Err(e) => {
                state.phase = "error";
                state.error = Some(e);
            }
        }
    }
    engine.uploads.active.store(false, Ordering::SeqCst);
}

async fn drive_upload(
    engine: &'static Engine,
    job: &Arc<Mutex<JobState>>,
    path: &std::path::Path,
) -> Result<Outcome, String> {
    let client = wallet_client(engine).await?;

    let (tx, rx) = mpsc::channel::<UploadEvent>(64);
    let progress = spawn_progress_mirror(job.clone(), rx);

    let result = client
        .file_upload_with_progress(path, PaymentMode::Auto, Some(tx))
        .await
        .map_err(|e| format!("upload failed: {e}"));
    let _ = progress.await;
    let result = result?;

    if result.chunks_failed > 0 {
        return Err(format!(
            "{} of {} chunks failed to store — the file is not fully on the \
             network; retry the upload (already-stored chunks are free)",
            result.chunks_failed, result.total_chunks
        ));
    }

    // Same identity a `.datamap` import derives; storing the root map
    // makes the upload instantly playable/exportable. Everything below
    // runs after payment + storage succeeded, so any failure here must
    // not read as a lost upload — the file is on the network and a
    // retry finishes for free.
    let (addr, root) =
        uploaded_root_map(engine, &result.data_map).await.map_err(|e| {
            format!(
                "the upload itself succeeded (all chunks stored and paid \
                 for) but finishing the library entry failed: {e} — \
                 publish the same file again to finish for free \
                 (already-stored chunks cost nothing)"
            )
        })?;
    engine.store_root_map(addr, &root);

    Ok(Outcome {
        address: hex::encode(addr),
        size: root.original_file_size() as u64,
        chunks: result.total_chunks,
        cost_atto: result.storage_cost_atto.clone(),
        gas_wei: result.gas_cost_wei,
        seq: None,
        announced: true,
    })
}

/// Address + root map for what ant-core handed back. A ≤3-chunk file's
/// map is its own root, but anything bigger (~12 MiB up — every real
/// movie) arrives as the SHRUNK child map (the same shape ant-cli
/// writes to `.datamap` files): its own hash IS the address, and the
/// root is recovered by fetching the wrapper chunks this upload just
/// stored — exactly the `POST /datamap` import path (server.rs).
async fn uploaded_root_map(
    engine: &'static Engine,
    map: &ant_core::data::DataMap,
) -> Result<([u8; 32], ant_core::data::DataMap), String> {
    if !map.is_child() {
        return Ok((crate::verify::derive_address(map)?, map.clone()));
    }
    let addr = crate::verify::shrunk_map_address(map)?;
    // Re-publish of a file already imported/published here: the stored
    // root went through expand+verify — no network round needed.
    if let Some(root) = engine.stored_root_map(&addr) {
        return Ok((addr, root));
    }
    let root = engine.expand_child_map(map.clone()).await?;
    crate::verify::verify_root_map(&addr, &root)?;
    Ok((addr, root))
}

#[cfg(test)]
mod tests {
    use super::*;
    use ant_core::data::DataMap;
    use std::collections::HashMap;
    use xor_name::XorName;

    /// Offline upload-equivalent (same as verify.rs tests): encrypt
    /// deterministic content, derive the address, resolve the root.
    fn upload(len: usize) -> ([u8; 32], DataMap, DataMap) {
        let mut v = Vec::with_capacity(len);
        let mut x = 0x51ED2701u64;
        while v.len() < len {
            x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            v.extend_from_slice(&x.to_le_bytes());
        }
        v.truncate(len);
        let (shrunk, chunks) = self_encryption::encrypt(v.into()).unwrap();
        let addr = *blake3::hash(&rmp_serde::to_vec(&shrunk).unwrap()).as_bytes();
        let by_name: HashMap<XorName, bytes::Bytes> = chunks
            .iter()
            .map(|c| (self_encryption::hash::content_hash(&c.content), c.content.clone()))
            .collect();
        let mut fetch = |name: XorName| {
            by_name
                .get(&name)
                .cloned()
                .ok_or_else(|| self_encryption::Error::Generic("missing chunk".into()))
        };
        let root = self_encryption::get_root_data_map(shrunk.clone(), &mut fetch).unwrap();
        (addr, shrunk, root)
    }

    fn test_engine(name: &str) -> &'static Engine {
        let dir = std::env::temp_dir()
            .join(format!("wi-upload-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        // Engine::new never touches the network; the client connects only
        // when a request needs it, which these branches never do.
        Box::leak(Box::new(Engine::new(None, dir.to_str())))
    }

    #[tokio::test]
    async fn small_upload_map_is_its_own_root() {
        let engine = test_engine("small");
        let (addr, map, root) = upload(10 * 1024);
        assert!(!map.is_child()); // ≤3 chunks: ant-core returns the root itself
        let (got_addr, got_root) = uploaded_root_map(engine, &map).await.unwrap();
        assert_eq!(got_addr, addr);
        assert_eq!(got_root.infos(), root.infos());
    }

    #[tokio::test]
    async fn large_upload_child_map_resolves_via_stored_root() {
        // What the bug hit: >3-chunk uploads hand back the SHRUNK child
        // map. With the root already stored (re-publish of an imported
        // file) it must resolve offline instead of erroring out.
        let engine = test_engine("large");
        let (addr, shrunk, root) = upload(14 * 1024 * 1024);
        assert!(shrunk.is_child());
        engine.store_root_map(addr, &root);
        let (got_addr, got_root) =
            uploaded_root_map(engine, &shrunk).await.unwrap();
        assert_eq!(got_addr, addr);
        assert_eq!(got_root.infos(), root.infos());
        assert!(!got_root.is_child());
        assert_eq!(got_root.original_file_size(), 14 * 1024 * 1024);
    }
}
