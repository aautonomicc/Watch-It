//! Process-wide LRU cache of encrypted network chunks.
//!
//! Serving and prefetch both fetch chunks through this cache, so a chunk
//! is downloaded at most once while it stays resident: the prefetcher
//! warms the window ahead of playback, the serving path then reads it
//! from RAM, and short rewinds replay without touching the network.
//!
//! Single-flight: a fetch is *claimed* via [`ChunkCache::lookup`] before
//! it starts, so a chunk wanted concurrently by the serving path and the
//! prefetcher is only downloaded once — the second caller sees
//! [`Lookup::InFlight`] and polls until the claimant completes.

use std::collections::{HashMap, HashSet};
use std::sync::Mutex;

use bytes::Bytes;

/// Cache capacity in bytes. 256 MiB ≈ 64 network chunks: the prefetch
/// window plus a few minutes of recently played history, so short rewinds
/// replay from RAM. Halved on Android where the app shares a tighter
/// memory budget with the decoder and the UI.
#[cfg(not(target_os = "android"))]
const CAPACITY_BYTES: usize = 256 * 1024 * 1024;
#[cfg(target_os = "android")]
const CAPACITY_BYTES: usize = 128 * 1024 * 1024;

pub struct ChunkCache {
    inner: Mutex<Inner>,
}

#[derive(Default)]
struct Inner {
    entries: HashMap<[u8; 32], Entry>,
    in_flight: HashSet<[u8; 32]>,
    bytes: usize,
    seq: u64,
}

struct Entry {
    data: Bytes,
    /// Last-touched tick for LRU eviction.
    seq: u64,
}

pub enum Lookup {
    Hit(Bytes),
    /// The caller now owns the fetch and must call [`ChunkCache::complete`]
    /// exactly once (pass `None` on failure to release the claim).
    Fetch,
    /// Another task owns the fetch; poll again shortly.
    InFlight,
}

impl ChunkCache {
    pub fn new() -> Self {
        Self { inner: Mutex::new(Inner::default()) }
    }

    /// Cached or already being fetched — used by the prefetcher to skip
    /// chunks that need no work, without claiming them.
    pub fn contains(&self, name: &[u8; 32]) -> bool {
        let g = self.inner.lock().unwrap();
        g.entries.contains_key(name) || g.in_flight.contains(name)
    }

    /// Bytes currently held (excludes in-flight fetches).
    pub fn resident_bytes(&self) -> usize {
        self.inner.lock().unwrap().bytes
    }

    pub fn lookup(&self, name: &[u8; 32]) -> Lookup {
        let mut g = self.inner.lock().unwrap();
        g.seq += 1;
        let seq = g.seq;
        if let Some(e) = g.entries.get_mut(name) {
            e.seq = seq;
            return Lookup::Hit(e.data.clone());
        }
        if g.in_flight.contains(name) {
            return Lookup::InFlight;
        }
        g.in_flight.insert(*name);
        Lookup::Fetch
    }

    /// Finish a fetch claimed via [`Lookup::Fetch`]. `None` (failed fetch)
    /// releases the claim so the next caller retries; waiters polling on
    /// [`Lookup::InFlight`] then claim the fetch themselves.
    pub fn complete(&self, name: [u8; 32], data: Option<Bytes>) {
        let mut g = self.inner.lock().unwrap();
        g.in_flight.remove(&name);
        let Some(data) = data else { return };
        if data.len() > CAPACITY_BYTES {
            return;
        }
        g.seq += 1;
        let seq = g.seq;
        g.bytes += data.len();
        if let Some(old) = g.entries.insert(name, Entry { data, seq }) {
            g.bytes -= old.data.len();
        }
        while g.bytes > CAPACITY_BYTES {
            // O(n) scan is fine: the cache never holds more than
            // CAPACITY_BYTES / ~4 MiB ≈ a few dozen entries.
            let Some(oldest) = g.entries.iter().min_by_key(|(_, e)| e.seq).map(|(k, _)| *k)
            else {
                break;
            };
            let evicted = g.entries.remove(&oldest).unwrap();
            g.bytes -= evicted.data.len();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(n: u8) -> [u8; 32] {
        [n; 32]
    }

    #[test]
    fn miss_claims_then_hit_after_complete() {
        let c = ChunkCache::new();
        assert!(matches!(c.lookup(&key(1)), Lookup::Fetch));
        // Claimed by the first caller: concurrent lookups must wait.
        assert!(matches!(c.lookup(&key(1)), Lookup::InFlight));
        c.complete(key(1), Some(Bytes::from_static(b"abc")));
        assert!(matches!(c.lookup(&key(1)), Lookup::Hit(b) if b.as_ref() == b"abc"));
        assert_eq!(c.resident_bytes(), 3);
    }

    #[test]
    fn failed_fetch_releases_claim() {
        let c = ChunkCache::new();
        assert!(matches!(c.lookup(&key(1)), Lookup::Fetch));
        c.complete(key(1), None);
        assert!(matches!(c.lookup(&key(1)), Lookup::Fetch));
    }

    #[test]
    fn contains_covers_cached_and_in_flight() {
        let c = ChunkCache::new();
        assert!(!c.contains(&key(1)));
        assert!(matches!(c.lookup(&key(1)), Lookup::Fetch));
        assert!(c.contains(&key(1)));
        c.complete(key(1), Some(Bytes::from_static(b"x")));
        assert!(c.contains(&key(1)));
        assert!(!c.contains(&key(2)));
    }

    #[test]
    fn evicts_least_recently_used_when_over_capacity() {
        let c = ChunkCache::new();
        // Two fit, a third overflows and must evict exactly one.
        let big = vec![0u8; CAPACITY_BYTES / 3 + 1];
        for n in 1..=2u8 {
            assert!(matches!(c.lookup(&key(n)), Lookup::Fetch));
            c.complete(key(n), Some(Bytes::from(big.clone())));
        }
        // Touch 1 so 2 becomes the eviction candidate.
        assert!(matches!(c.lookup(&key(1)), Lookup::Hit(_)));
        assert!(matches!(c.lookup(&key(3)), Lookup::Fetch));
        c.complete(key(3), Some(Bytes::from(big.clone())));
        assert!(c.contains(&key(1)));
        assert!(!c.contains(&key(2)));
        assert!(c.contains(&key(3)));
        assert!(c.resident_bytes() <= CAPACITY_BYTES);
    }

    #[test]
    fn oversized_chunk_is_not_cached() {
        let c = ChunkCache::new();
        assert!(matches!(c.lookup(&key(1)), Lookup::Fetch));
        c.complete(key(1), Some(Bytes::from(vec![0u8; CAPACITY_BYTES + 1])));
        assert!(!c.contains(&key(1)));
        assert_eq!(c.resident_bytes(), 0);
    }
}
