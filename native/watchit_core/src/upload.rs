//! Paid uploads: the single active slot.
//!
//! Every upload in the app goes through the pooled batch (`batch.rs`,
//! `POST /upload/batch`). This module holds the job table with its one
//! active slot — uploads cost real ANT, so only one paid job runs at a
//! time and a second start is refused rather than queued.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64};
use std::sync::{Arc, Mutex};

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
