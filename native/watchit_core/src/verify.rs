//! Offline verification of externally supplied root data maps.
//!
//! A `.watch-list` bundle can carry pre-resolved root maps so imported
//! titles play instantly, but a tampered map must never poison the
//! cache. Verification reverses the upload's address derivation without
//! touching the network: re-shrink the root map (convergent encryption,
//! so the wrapper chunks are reproduced bit-for-bit), serialize the
//! outermost map exactly like ant-core's `data_map_store`
//! (`rmp_serde::to_vec`), hash it (`blake3`, ant-protocol's
//! `compute_address`), and require the result to equal the claimed XOR
//! address. Costs ~ms per map.

use ant_core::data::DataMap;

/// Derive the content address of a root data map — the same shrink →
/// serialize → hash pipeline a public upload runs, computed fully
/// offline. For a file that was uploaded publicly this equals its XOR
/// address; for a private upload it is the entry's stable identity
/// (nothing at this address exists on the network — that is the point).
pub fn derive_address(root: &DataMap) -> Result<[u8; 32], String> {
    if root.is_child() {
        return Err("map is a shrunk child map, not a root map".to_string());
    }
    // No-op store: re-shrinking only needs the resulting outermost map,
    // not the wrapper chunks themselves.
    let (shrunk, _) = self_encryption::shrink_data_map(root.clone(), |_, _| Ok(()))
        .map_err(|e| format!("re-shrink failed: {e}"))?;
    shrunk_map_address(&shrunk)
}

/// The shrunk serialization of a stored root map — the exact bytes an
/// ant-cli private upload writes to its `.datamap` file, so another
/// device imports them through `POST /datamap` like any shared map
/// (expanding the wrapper chunks over the network when it is a child
/// map). A few hundred bytes regardless of file size, which is what lets
/// entry maps ride the My W@tch sync store's 64 KiB value cap.
pub fn shrunk_map_bytes(root: &DataMap) -> Result<Vec<u8>, String> {
    if root.is_child() {
        return Err("map is a shrunk child map, not a root map".to_string());
    }
    let (shrunk, _) = self_encryption::shrink_data_map(root.clone(), |_, _| Ok(()))
        .map_err(|e| format!("re-shrink failed: {e}"))?;
    rmp_serde::to_vec(&shrunk).map_err(|e| format!("serialize failed: {e}"))
}

/// Address of an already-shrunk map — the hash of its own serialization,
/// no shrink round. This is what ant-cli's private upload wrote to the
/// `.datamap` file (it persists the shrunk result verbatim), so for a
/// child map the file itself carries the address; the root map is then
/// recovered from the wrapper chunks the upload stored on the network.
pub fn shrunk_map_address(map: &DataMap) -> Result<[u8; 32], String> {
    let serialized =
        rmp_serde::to_vec(map).map_err(|e| format!("serialize failed: {e}"))?;
    Ok(*blake3::hash(&serialized).as_bytes())
}

/// Check that `root` really is the resolved root data map published at
/// `addr`. Any failure (shrink/serialize error or hash mismatch) means
/// the map must be discarded.
pub fn verify_root_map(addr: &[u8; 32], root: &DataMap) -> Result<(), String> {
    if derive_address(root)? == *addr {
        Ok(())
    } else {
        Err("content hash does not match the address".to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytes::Bytes;
    use std::collections::HashMap;
    use xor_name::XorName;

    /// Deterministic pseudo-random content (no rand dependency).
    fn content(len: usize) -> Bytes {
        let mut v = Vec::with_capacity(len);
        let mut x = 0x2545F491u64;
        while v.len() < len {
            x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            v.extend_from_slice(&x.to_le_bytes());
        }
        v.truncate(len);
        Bytes::from(v)
    }

    /// Upload-equivalent: encrypt, derive the public address the way
    /// ant-core's public upload does, then resolve the root map back
    /// from the encrypted chunks — all offline.
    fn upload(len: usize) -> ([u8; 32], DataMap) {
        let (shrunk, chunks) = self_encryption::encrypt(content(len)).unwrap();
        let addr = *blake3::hash(&rmp_serde::to_vec(&shrunk).unwrap()).as_bytes();
        let by_name: HashMap<XorName, Bytes> = chunks
            .iter()
            .map(|c| (self_encryption::hash::content_hash(&c.content), c.content.clone()))
            .collect();
        let mut fetch = |name: XorName| {
            by_name
                .get(&name)
                .cloned()
                .ok_or_else(|| self_encryption::Error::Generic("missing chunk".into()))
        };
        let root = self_encryption::get_root_data_map(shrunk, &mut fetch).unwrap();
        (addr, root)
    }

    #[test]
    fn small_file_roundtrip() {
        // 3 chunks — the map is its own root, no shrink round.
        let (addr, root) = upload(10 * 1024);
        assert!(!root.is_child());
        verify_root_map(&addr, &root).unwrap();
    }

    #[test]
    fn large_file_roundtrip() {
        // >3 chunks — the published map is a shrunk child, so verification
        // exercises the real re-shrink path.
        let (addr, root) = upload(14 * 1024 * 1024);
        assert!(!root.is_child());
        verify_root_map(&addr, &root).unwrap();
    }

    #[test]
    fn derived_address_matches_public_upload_address() {
        // Both sizes: shrink is a no-op for ≤3-chunk maps and a real
        // re-shrink round for larger ones — the derived address must be
        // the public upload's XOR address either way.
        for len in [10 * 1024, 14 * 1024 * 1024] {
            let (addr, root) = upload(len);
            assert_eq!(derive_address(&root).unwrap(), addr);
        }
    }

    #[test]
    fn derive_rejects_child_map() {
        let (_, root) = upload(14 * 1024 * 1024);
        let child = DataMap::with_child(root.infos().to_vec(), 1);
        assert!(derive_address(&child).is_err());
    }

    #[test]
    fn shrunk_map_address_matches_upload_address() {
        // What ant-cli writes for a >3-chunk file is the shrunk child map;
        // its own hash must be the upload's address.
        let (addr, root) = upload(14 * 1024 * 1024);
        let (shrunk, _) =
            self_encryption::shrink_data_map(root, |_, _| Ok(())).unwrap();
        assert!(shrunk.is_child());
        assert_eq!(shrunk_map_address(&shrunk).unwrap(), addr);
    }

    #[test]
    fn tampered_map_rejected() {
        let (addr, root) = upload(10 * 1024);
        let mut infos = root.infos().to_vec();
        infos[0].src_size += 1;
        let tampered = DataMap::new(infos);
        assert!(verify_root_map(&addr, &tampered).is_err());
    }

    #[test]
    fn wrong_address_rejected() {
        let (_, root) = upload(10 * 1024);
        assert!(verify_root_map(&[0u8; 32], &root).is_err());
    }

    #[test]
    fn child_map_rejected() {
        let (addr, root) = upload(14 * 1024 * 1024);
        let child = DataMap::with_child(root.infos().to_vec(), 1);
        assert!(verify_root_map(&addr, &child).is_err());
    }
}
