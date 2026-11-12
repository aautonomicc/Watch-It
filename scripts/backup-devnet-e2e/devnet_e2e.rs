//! One-payment backup against real local nodes + Anvil. NOT part of the
//! crate: run.sh copies the crate to a scratch dir, switches on ant-core's
//! `devnet` feature there and adds this file as a test module.
use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use ant_core::data::{DataMap, LocalDevnet, Wallet};
use ant_node::devnet::DevnetConfig;
use bytes::Bytes;

use crate::backup::*;

struct CountingSigner {
    inner: alloy::signers::local::PrivateKeySigner,
    signatures: Arc<AtomicUsize>,
}
#[async_trait::async_trait]
impl alloy::network::TxSigner<alloy::primitives::Signature> for CountingSigner {
    fn address(&self) -> alloy::primitives::Address {
        alloy::network::TxSigner::address(&self.inner)
    }
    async fn sign_transaction(
        &self,
        tx: &mut dyn alloy::consensus::SignableTransaction<alloy::primitives::Signature>,
    ) -> alloy::signers::Result<alloy::primitives::Signature> {
        self.signatures.fetch_add(1, Ordering::SeqCst);
        tokio::time::sleep(std::time::Duration::from_secs(7)).await;
        alloy::network::TxSigner::sign_transaction(&self.inner, tx).await
    }
}

fn counting_wallet(devnet: &LocalDevnet) -> (Wallet, Arc<AtomicUsize>) {
    let inner: alloy::signers::local::PrivateKeySigner = devnet
        .wallet_private_key()
        .trim_start_matches("0x")
        .parse()
        .unwrap();
    let signatures = Arc::new(AtomicUsize::new(0));
    let signer = CountingSigner { inner, signatures: signatures.clone() };
    (
        Wallet::new(
            devnet.evm_network().clone(),
            alloy::network::EthereumWallet::from(signer),
        ),
        signatures,
    )
}

/// Build a backup's chunk set the way drive_backup does.
fn build(
    keys: &BackupKeys,
    objects: &[Vec<u8>],
    n: u64,
) -> (HashMap<[u8; 32], Bytes>, [u8; 32], Vec<u8>) {
    let mut chunks = HashMap::new();
    let mut maps = Vec::new();
    for plain in objects {
        let (_, ct) = seal_object(&keys.enc, plain);
        let map = stage_blob(&mut chunks, ct).unwrap();
        maps.push(hex::encode(rmp_serde::to_vec(&map).unwrap()));
    }
    let manifest = serde_json::to_vec(&serde_json::json!({"n": n, "maps": maps})).unwrap();
    let map = stage_blob(&mut chunks, seal_envelope(&keys.enc, &manifest)).unwrap();
    let head = serde_json::to_vec(&serde_json::json!({
        "manifest": hex::encode(rmp_serde::to_vec(&map).unwrap()), "n": n,
    }))
    .unwrap();
    let head_ct = Bytes::from(seal_envelope(&keys.enc, &head));
    let head_addr = ant_core::data::compute_address(&head_ct);
    chunks.insert(head_addr, head_ct);
    (chunks, head_addr, manifest)
}

async fn read_back(client: &ant_core::data::Client, keys: &BackupKeys) -> (u64, [u8; 32], Vec<u8>) {
    let pointer = client.pointer_get(&keys.pointer).await.unwrap().expect("pointer");
    let head_addr = pointer.target().address;
    let chunk = client.chunk_get(&head_addr).await.unwrap().expect("head");
    let head: serde_json::Value =
        serde_json::from_slice(&open_envelope(&keys.enc, &chunk.content).unwrap()).unwrap();
    let map: DataMap =
        rmp_serde::from_slice(&hex::decode(head["manifest"].as_str().unwrap()).unwrap()).unwrap();
    assert!(!map.is_child());
    let manifest_ct = client.data_download(&map).await.unwrap();
    let manifest = open_envelope(&keys.enc, &manifest_ct).unwrap();
    // every object reads back too
    let m: serde_json::Value = serde_json::from_slice(&manifest).unwrap();
    for om in m["maps"].as_array().unwrap() {
        let map: DataMap =
            rmp_serde::from_slice(&hex::decode(om.as_str().unwrap()).unwrap()).unwrap();
        if !map.is_child() {
            client.data_download(&map).await.unwrap();
        }
    }
    (pointer.counter(), head_addr, manifest)
}

async fn run(nodes: usize, big: bool) {
    let mut config = DevnetConfig::small();
    config.node_count = nodes;
    let mut devnet = LocalDevnet::start(config).await.expect("devnet");
    // funded client; also grants the allowance with the plain key
    let client = devnet.create_funded_client().await.expect("client");
    let (wallet, signatures) = counting_wallet(&devnet);
    let keys = derive_keys("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80").unwrap();
    let before = wallet.balance_of_tokens().await.unwrap();

    // -- first backup: creates the pointer --------------------------------
    let doc1 = br#"{"lists":["Movies"],"watch":{"a":1}}"#.to_vec();
    let (chunks, head1, manifest1) = build(&keys, &[doc1.clone()], 1);
    let n1 = chunks.len();
    let stored = Arc::new(AtomicUsize::new(0));
    let s2 = stored.clone();
    let out = publish_backup(&client, wallet.clone(), &keys, chunks, head1,
        Box::new(|p, d, t| eprintln!("progress {p} {d}/{t}")),
        move || { s2.fetch_add(1, Ordering::SeqCst); })
        .await
        .expect("first publish");
    eprintln!("first: chunks {} payments {} signatures {}", out.chunks, out.payments, signatures.load(Ordering::SeqCst));
    assert_eq!(out.chunks, n1);
    assert_eq!(out.payments, 1, "one wallet transaction for chunks + pointer");
    assert_eq!(signatures.load(Ordering::SeqCst), 1, "one signature");
    assert_eq!(stored.load(Ordering::SeqCst), 1);
    let (counter, head, manifest) = read_back(&client, &keys).await;
    assert_eq!((counter, head, manifest), (0, head1, manifest1));
    let spent1 = before - wallet.balance_of_tokens().await.unwrap();
    eprintln!("first backup spent {spent1} atto");

    // -- routine backup: the doc changed; pointer UPDATE ------------------
    let doc2 = br#"{"lists":["Movies"],"watch":{"a":2,"b":7}}"#.to_vec();
    let (chunks, head2, manifest2) = build(&keys, &[doc2], 2);
    let out = publish_backup(&client, wallet.clone(), &keys, chunks, head2,
        Box::new(|_, _, _| {}), || {})
        .await
        .expect("second publish");
    assert_eq!(out.payments, 1);
    assert_eq!(signatures.load(Ordering::SeqCst), 2, "one more signature");
    let (counter, head, manifest) = read_back(&client, &keys).await;
    assert_eq!((counter, head, manifest), (1, head2, manifest2));

    // -- nothing new but the manifest/head (object already stored) --------
    let (chunks, head3, manifest3) = build(&keys, &[doc1], 3);
    let out = publish_backup(&client, wallet.clone(), &keys, chunks, head3,
        Box::new(|_, _, _| {}), || {})
        .await
        .expect("third publish");
    assert_eq!(out.payments, 1);
    assert_eq!(signatures.load(Ordering::SeqCst), 3);
    let (counter, head, manifest) = read_back(&client, &keys).await;
    assert_eq!((counter, head, manifest), (2, head3, manifest3));

    if big {
        // -- a big backup: > 64 chunks → merkle + the pointer alone -------
        let objects: Vec<Vec<u8>> = (0..30u32)
            .map(|i| format!("artwork file number {i} with some bytes in it").into_bytes())
            .collect();
        let (chunks, head4, manifest4) = build(&keys, &objects, 4);
        let n = chunks.len();
        assert!(n > 64, "{n}");
        let sig_before = signatures.load(Ordering::SeqCst);
        let out = publish_backup(&client, wallet.clone(), &keys, chunks, head4,
            Box::new(|_, _, _| {}), || {})
            .await
            .expect("big publish");
        let sigs = signatures.load(Ordering::SeqCst) - sig_before;
        eprintln!("big: chunks {} payments {} signatures {sigs}", out.chunks, out.payments);
        assert_eq!(out.payments, sigs);
        assert!(out.payments <= 3, "{}", out.payments);
        let (counter, head, manifest) = read_back(&client, &keys).await;
        assert_eq!((counter, head, manifest), (3, head4, manifest4));
    }
    if !big {
        // -- artwork packs: 40 posters ride ONE object of a few chunks,
        //    paid with the pointer in one transaction, and every file
        //    comes back out of the pack read from the network -----------
        let posters: Vec<(String, Vec<u8>)> = (0..40usize)
            .map(|n| {
                let bytes: Vec<u8> =
                    (0..20_000 + n).map(|i| (i * 31 + n * 7) as u8).collect();
                (format!("movie_{n}.jpg"), bytes)
            })
            .collect();
        let packing = pack_art(
            posters.clone(),
            &std::collections::BTreeMap::new(),
            |_| false,
            PACK_TARGET_BYTES,
        );
        assert_eq!(packing.packs.len(), 1);
        let (pack_hash, pack_plain) = packing.packs[0].clone();
        let (chunks, head5, _) = build(&keys, &[pack_plain], 5);
        let n = chunks.len();
        assert!(n <= 8, "40 posters should be a handful of chunks, got {n}");
        let sig_before = signatures.load(Ordering::SeqCst);
        let out = publish_backup(&client, wallet.clone(), &keys, chunks, head5,
            Box::new(|_, _, _| {}), || {})
            .await
            .expect("pack publish");
        eprintln!("packs: 40 files in {} chunks, {} payment(s)", out.chunks, out.payments);
        assert_eq!(out.payments, 1);
        assert_eq!(signatures.load(Ordering::SeqCst) - sig_before, 1);
        let (counter, head, manifest) = read_back(&client, &keys).await;
        assert_eq!((counter, head), (3, head5));
        let m: serde_json::Value = serde_json::from_slice(&manifest).unwrap();
        let map: DataMap = rmp_serde::from_slice(
            &hex::decode(m["maps"][0].as_str().unwrap()).unwrap(),
        )
        .unwrap();
        let fetched = client.data_download(&map).await.expect("pack download");
        let opened = open_object(&keys.enc, &pack_hash, &fetched).unwrap();
        for ((file, hash, loc), (name, bytes)) in packing.entries.iter().zip(&posters) {
            assert_eq!(file, name);
            assert_eq!(unpack_art(&opened, hash, loc).unwrap(), bytes.as_slice());
        }
    }
    let _ = devnet.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn one_payment_backup_on_a_local_network() {
    run(14, false).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn big_backup_on_a_local_network() {
    run(40, true).await;
}
