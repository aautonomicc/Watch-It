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
    let mut client = engine.client().await?;
    if client.wallet().is_none() {
        // The client connected before the wallet was imported: force one
        // reconnect so the wallet-bearing connect path runs, then retry.
        tracing::info!("client has no wallet attached — reconnecting to attach it");
        engine.reconnect_for_wallet();
        client = engine.client().await?;
        if client.wallet().is_none() {
            return Err("wallet could not be attached to the network client".into());
        }
    }

    let (tx, mut rx) = mpsc::channel::<UploadEvent>(64);
    let progress_job = job.clone();
    let progress = tokio::spawn(async move {
        while let Some(ev) = rx.recv().await {
            let mut s = progress_job.lock().unwrap();
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
    });

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
    // makes the upload instantly playable/exportable.
    let addr = crate::verify::derive_address(&result.data_map)?;
    engine.store_root_map(addr, &result.data_map);

    Ok(Outcome {
        address: hex::encode(addr),
        size: result.data_map.original_file_size() as u64,
        chunks: result.total_chunks,
        cost_atto: result.storage_cost_atto.clone(),
        gas_wei: result.gas_cost_wei,
    })
}
