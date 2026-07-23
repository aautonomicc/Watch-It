//! On-disk cache of resolved root data maps.
//!
//! Data maps are content-addressed and immutable, so a resolved root map
//! for a XOR address is valid forever — persisting it means the multi-round
//! child-map resolution (several seconds of chunk fetches on a movie-sized
//! file) happens once per title per device, not once per app run.
//!
//! Storage is a single-table SQLite database in the app's data directory;
//! maps are stored in the DataMap's own versioned bincode format. Every
//! failure degrades to "no cache" — playback never depends on this store.

use std::path::Path;
use std::sync::Mutex;

use ant_core::data::DataMap;
use rusqlite::{Connection, OptionalExtension};

pub struct MapStore {
    conn: Mutex<Connection>,
}

impl MapStore {
    /// Open (creating if needed) `root_maps.sqlite` inside `dir`.
    pub fn open_in_dir(dir: &Path) -> Result<Self, String> {
        std::fs::create_dir_all(dir)
            .map_err(|e| format!("create {}: {e}", dir.display()))?;
        let path = dir.join("root_maps.sqlite");
        let conn = Connection::open(&path)
            .map_err(|e| format!("open {}: {e}", path.display()))?;
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS root_maps (
                 addr BLOB PRIMARY KEY,
                 map  BLOB NOT NULL
             );",
        )
        .map_err(|e| format!("init root_maps schema: {e}"))?;
        Ok(Self { conn: Mutex::new(conn) })
    }

    /// Cached root map for `addr`, if present. A row that fails to decode
    /// (foreign/corrupt format) is dropped so it can be re-resolved.
    pub fn get(&self, addr: &[u8; 32]) -> Option<DataMap> {
        let conn = self.conn.lock().unwrap();
        let blob = conn
            .query_row(
                "SELECT map FROM root_maps WHERE addr = ?1",
                [addr.as_slice()],
                |row| row.get::<_, Vec<u8>>(0),
            )
            .optional()
            .unwrap_or_default()?;
        match DataMap::from_bytes(&blob) {
            Ok(map) => Some(map),
            Err(e) => {
                tracing::warn!(
                    "dropping undecodable cached root map for {}: {e}",
                    hex::encode(addr)
                );
                let _ = conn.execute(
                    "DELETE FROM root_maps WHERE addr = ?1",
                    [addr.as_slice()],
                );
                None
            }
        }
    }

    /// Persist the resolved root map for `addr` (upsert; best-effort).
    pub fn put(&self, addr: &[u8; 32], map: &DataMap) {
        let blob = match map.to_bytes() {
            Ok(b) => b,
            Err(e) => {
                tracing::warn!("root map serialize failed: {e}");
                return;
            }
        };
        let conn = self.conn.lock().unwrap();
        if let Err(e) = conn.execute(
            "INSERT OR REPLACE INTO root_maps (addr, map) VALUES (?1, ?2)",
            rusqlite::params![addr.as_slice(), blob],
        ) {
            tracing::warn!("root map persist failed: {e}");
        }
    }

    /// Number of cached root maps (for `/health`).
    pub fn len(&self) -> usize {
        self.conn
            .lock()
            .unwrap()
            .query_row("SELECT COUNT(*) FROM root_maps", [], |row| row.get(0))
            .unwrap_or(0usize)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use self_encryption::ChunkInfo;
    use xor_name::XorName;

    fn sample_map() -> DataMap {
        DataMap::new(vec![
            ChunkInfo {
                index: 0,
                dst_hash: XorName([1; 32]),
                src_hash: XorName([2; 32]),
                src_size: 1024,
            },
            ChunkInfo {
                index: 1,
                dst_hash: XorName([3; 32]),
                src_hash: XorName([4; 32]),
                src_size: 2048,
            },
        ])
    }

    #[test]
    fn roundtrip_and_miss() {
        let dir = std::env::temp_dir().join(format!(
            "wi-mapstore-{}",
            std::process::id()
        ));
        let store = MapStore::open_in_dir(&dir).unwrap();
        let addr = [7u8; 32];
        assert!(store.get(&addr).is_none());
        let map = sample_map();
        store.put(&addr, &map);
        assert_eq!(store.get(&addr), Some(map.clone()));
        assert_eq!(store.len(), 1);

        // A second open sees the same row (persistence across restarts).
        drop(store);
        let store = MapStore::open_in_dir(&dir).unwrap();
        assert_eq!(store.get(&addr), Some(map));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn corrupt_row_is_dropped() {
        let dir = std::env::temp_dir().join(format!(
            "wi-mapstore-corrupt-{}",
            std::process::id()
        ));
        let store = MapStore::open_in_dir(&dir).unwrap();
        let addr = [9u8; 32];
        {
            let conn = store.conn.lock().unwrap();
            conn.execute(
                "INSERT INTO root_maps (addr, map) VALUES (?1, ?2)",
                rusqlite::params![addr.as_slice(), b"not a data map".as_slice()],
            )
            .unwrap();
        }
        assert!(store.get(&addr).is_none());
        assert_eq!(store.len(), 0);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
