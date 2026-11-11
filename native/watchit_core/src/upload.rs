//! Paid uploads: the single active slot and the wallet-attached client.
//!
//! Every upload in the app goes through the pooled batch (`batch.rs`,
//! `POST /upload/batch`). This module holds what the batch and the backup
//! share: the job table with its one active slot — uploads cost real ANT,
//! so only one paid job runs at a time and a second start is refused
//! rather than queued — and the network client with the upload wallet
//! attached.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64};
use std::sync::{Arc, Mutex};

use crate::engine::Engine;

#[derive(Default)]
pub struct UploadManager {
    pub(crate) batch_jobs:
        Mutex<HashMap<u64, Arc<Mutex<crate::batch::BatchJobState>>>>,
    pub(crate) next_id: AtomicU64,
    /// One paid job at a time, whatever starts it.
    pub(crate) active: AtomicBool,
}

impl UploadManager {
    pub fn batch_state(&self, id: u64) -> Option<crate::batch::BatchJobState> {
        let job = self.batch_jobs.lock().unwrap().get(&id).cloned()?;
        let state = job.lock().unwrap().clone();
        Some(state)
    }
}

/// A connected client with the upload wallet attached (forcing one
/// reconnect when the client pre-dates the wallet import). Shared with
/// the backup module — backups pay from the same wallet.
pub(crate) async fn wallet_client(
    engine: &'static Engine,
) -> Result<std::sync::Arc<ant_core::data::Client>, String> {
    let mut client = engine.client().await?;
    if client.wallet().is_none() {
        tracing::info!("client has no wallet attached — reconnecting to attach it");
        engine.reconnect_for_wallet();
        client = engine.client().await?;
        if client.wallet().is_none() {
            let hardware = engine.signer().map(|s| s.is_hardware()).unwrap_or(false);
            return Err(if hardware {
                "the wallet could not be attached — is the Trezor plugged in \
                 and unlocked?"
                    .into()
            } else {
                "wallet could not be attached to the network client".into()
            });
        }
    }
    Ok(client)
}
