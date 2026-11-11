//! One payment per backup.
//!
//! A backup used to be a string of separate wallet transactions: one per
//! new object (`data_upload`), one for the manifest, one for the head
//! chunk, one for the pointer. On a hardware wallet that is one physical
//! confirmation each — five for a routine backup.
//!
//! Everything a backup stores is known before anything is paid: the
//! objects, manifest and head are encrypted locally (backup.rs), and the
//! pointer record is signed against the head's content address. So the
//! whole backup goes through ant-core's multi-record driver
//! (`Client::upload_records`) with this adapter, and the pointer's
//! pre-quoted payment plan rides INSIDE the chunks' `payForQuotes`
//! transaction: one transaction, one signature, through the sign-once
//! journal (payjournal.rs).
//!
//! The driver checks that the adapter reports exactly the chunks' total,
//! so [`BackupAdapter`] reports the chunk share and keeps the pointer's
//! transaction hashes for [`BackupAdapter::pointer_proof`].
//!
//! Large backups (more than one 64-chunk payment wave — a first backup
//! with lots of artwork) pay their chunks through merkle batches instead
//! and the pointer in one journaled payment of its own
//! ([`BackupAdapter::pay_pointer_alone`]).

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use ant_core::data::client::batch::ChunkPaymentPlan;
use ant_core::data::client::upload::{
    MerkleUploadPayment, UploadAdapter, UploadPayment, UploadRecord,
};
use ant_core::data::client::upload_state::{PaymentAttempt, UploadState};
use ant_core::data::error::Error as AntError;
use ant_core::data::{PreparedMerkleBatch, Wallet};
use bytes::Bytes;
use evmlib::common::{Amount, QuoteHash, TxHash};
use evmlib::wallet::journal::PaymentRequest;

use crate::payjournal;

/// ant-core's single-payment wave size (`batch::PAYMENT_WAVE_SIZE`): up
/// to this many chunks are paid by one `payForQuotes` transaction.
pub const SINGLE_PAYMENT_CHUNKS: usize = 64;

type ProgressFn = dyn Fn(&'static str, usize, usize) + Send + Sync;

pub struct BackupAdapter {
    pub wallet: Wallet,
    /// Every chunk of the backup, by content address.
    pub chunks: Arc<HashMap<[u8; 32], Bytes>>,
    /// The pointer's pre-quoted plan, to be paid with the chunks. `None`
    /// once paid (or when the pointer pays alone).
    ride_along: Mutex<Option<ChunkPaymentPlan>>,
    /// The plan as paid + the transactions that paid it.
    pointer_paid: Mutex<Option<(ChunkPaymentPlan, HashMap<QuoteHash, TxHash>)>>,
    /// Wallet transactions confirmed through this adapter.
    payments: Mutex<usize>,
    /// (phase, done, total) for the job's progress line.
    progress: Box<ProgressFn>,
}

impl BackupAdapter {
    pub fn new(
        wallet: Wallet,
        chunks: Arc<HashMap<[u8; 32], Bytes>>,
        pointer_plan: Option<ChunkPaymentPlan>,
        progress: Box<ProgressFn>,
    ) -> Self {
        Self {
            wallet,
            chunks,
            ride_along: Mutex::new(pointer_plan),
            pointer_paid: Mutex::new(None),
            payments: Mutex::new(0),
            progress,
        }
    }

    /// Wallet transactions confirmed so far.
    pub fn payments(&self) -> usize {
        *self.payments.lock().unwrap()
    }

    /// The pointer's payment proof, once its plan has been paid.
    pub fn pointer_proof(&self) -> Option<Result<Vec<u8>, String>> {
        self.pointer_paid
            .lock()
            .unwrap()
            .as_ref()
            .map(|(plan, txs)| plan.proof(txs).map_err(|e| e.to_string()))
    }

    fn quotes_of(plans: &[ChunkPaymentPlan]) -> Vec<evmlib::common::QuotePayment> {
        plans
            .iter()
            .flat_map(|p| p.payment.quotes.iter())
            .filter(|q| q.amount != Amount::ZERO)
            .map(|q| (q.quote_hash, q.rewards_address, q.amount))
            .collect()
    }

    /// One `payForQuotes` transaction for the chunk plans plus — when it
    /// has not been paid yet — the pointer's plan. Also the reconcile
    /// path: the request is rebuilt identically, and a journal that
    /// already holds a signed transaction is watched, never re-signed.
    async fn pay_quotes<F>(
        &self,
        plans: &[ChunkPaymentPlan],
        state: &mut UploadState,
        fresh: F,
    ) -> ant_core::data::Result<UploadPayment>
    where
        F: Fn(&UploadState) -> bool + Send + Sync,
    {
        let pointer = self.ride_along.lock().unwrap().clone();
        let chunk_quotes = Self::quotes_of(plans);
        let chunk_hashes = chunk_quotes.iter().map(|q| q.0).collect::<Vec<_>>();
        let pointer_quotes = pointer
            .as_ref()
            .map(|p| Self::quotes_of(std::slice::from_ref(p)))
            .unwrap_or_default();
        let pointer_total = pointer_quotes
            .iter()
            .fold(Amount::ZERO, |sum, q| sum.saturating_add(q.2));
        let mut quotes = chunk_quotes;
        quotes.extend(pointer_quotes.iter().cloned());

        let receipt = payjournal::execute(
            &self.wallet,
            self,
            &PaymentRequest::Quotes(quotes),
            state,
            fresh,
            || (self.progress)("paying", 0, 0),
        )
        .await?;
        *self.payments.lock().unwrap() += 1;

        if let Some(plan) = pointer {
            let txs = pointer_quotes
                .iter()
                .map(|q| (q.0, receipt.transaction_hash))
                .collect();
            *self.pointer_paid.lock().unwrap() = Some((plan, txs));
            // Paid: a later wave (or a retry) must not pay it again.
            *self.ride_along.lock().unwrap() = None;
        }
        Ok(UploadPayment {
            transactions: chunk_hashes
                .into_iter()
                .map(|h| (h, receipt.transaction_hash))
                .collect(),
            // The driver compares this against the chunk plans' total.
            amount: receipt.amount.saturating_sub(pointer_total),
            gas: receipt.gas_cost_wei,
        })
    }

    async fn pay_quotes_checked(
        &self,
        plans: &[ChunkPaymentPlan],
        state: &mut UploadState,
    ) -> ant_core::data::Result<UploadPayment> {
        let fresh = |state: &UploadState| {
            plans.iter().all(|p| {
                state
                    .retained_plan(&p.address, p.data_size, std::time::SystemTime::now())
                    .is_some()
            })
        };
        self.pay_quotes(plans, state, fresh).await
    }

    /// Pay the pointer's plan in a transaction of its own — when no chunk
    /// payment carried it (every chunk was already stored, or the chunks
    /// went through merkle batches). `state` is the pointer's own journal
    /// and must be kept by the caller across retries.
    pub async fn pay_pointer_alone(&self, state: &mut UploadState) -> Result<(), String> {
        if self.ride_along.lock().unwrap().is_none() {
            return Ok(());
        }
        if state.pending_payment.is_none() {
            let mut attempt = PaymentAttempt {
                merkle: false,
                addresses: Vec::new(),
                submissions: Vec::new(),
                receipt: None,
            };
            payjournal::initialize(&mut attempt);
            state.pending_payment = Some(attempt);
        }
        self.pay_quotes(&[], state, |_| true)
            .await
            .map(|_| ())
            .map_err(|e| e.to_string())
    }
}

/// ant-core's own `merkle_fresh`, which it keeps private.
fn merkle_fresh(timestamp: u64, now: std::time::SystemTime) -> bool {
    now.duration_since(std::time::UNIX_EPOCH)
        .ok()
        .is_some_and(|now| {
            timestamp <= now.as_secs()
                && now.as_secs() - timestamp
                    < evmlib::merkle_payments::MERKLE_PAYMENT_EXPIRATION
        })
}

#[async_trait::async_trait]
impl UploadAdapter for BackupAdapter {
    async fn load(&self, record: UploadRecord) -> ant_core::data::Result<Bytes> {
        self.chunks
            .get(&record.address)
            .cloned()
            .ok_or_else(|| AntError::InvalidData("backup chunk missing from staging".into()))
    }

    /// Never reached: the driver calls `submit_payment`, overridden below
    /// onto the journal.
    async fn pay(&self, _plans: &[ChunkPaymentPlan]) -> ant_core::data::Result<UploadPayment> {
        Err(AntError::Payment(
            "backup payments go through the payment journal".into(),
        ))
    }

    fn initialize_payment_attempt(&self, attempt: &mut PaymentAttempt) {
        payjournal::initialize(attempt);
    }

    async fn submit_payment(
        &self,
        plans: &[ChunkPaymentPlan],
        state: &mut UploadState,
    ) -> ant_core::data::Result<UploadPayment> {
        self.pay_quotes_checked(plans, state).await
    }

    async fn reconcile_payment(
        &self,
        plans: &[ChunkPaymentPlan],
        state: &mut UploadState,
    ) -> ant_core::data::Result<UploadPayment> {
        self.pay_quotes_checked(plans, state).await
    }

    async fn submit_merkle_payment(
        &self,
        batch: &PreparedMerkleBatch,
        state: &mut UploadState,
    ) -> ant_core::data::Result<MerkleUploadPayment> {
        let request = PaymentRequest::Merkle {
            depth: batch.depth,
            pools: batch.pool_commitments.clone(),
            timestamp: batch.merkle_payment_timestamp,
        };
        let timestamp = batch.merkle_payment_timestamp;
        let receipt = payjournal::execute(
            &self.wallet,
            self,
            &request,
            state,
            move |_| merkle_fresh(timestamp, std::time::SystemTime::now()),
            || (self.progress)("paying", 0, 0),
        )
        .await?;
        *self.payments.lock().unwrap() += 1;
        Ok(MerkleUploadPayment {
            winner_pool: receipt.winner_pool.ok_or_else(|| {
                AntError::Payment("missing confirmed Merkle winner".into())
            })?,
            amount: receipt.amount,
            gas: receipt.gas_cost_wei,
        })
    }

    async fn reconcile_merkle_payment(
        &self,
        batch: &PreparedMerkleBatch,
        state: &mut UploadState,
    ) -> ant_core::data::Result<MerkleUploadPayment> {
        self.submit_merkle_payment(batch, state).await
    }

    fn quoted(&self, quoted: usize, total: usize) {
        (self.progress)("quoting", quoted, total);
    }

    fn stored(&self, stored: usize, total: usize) {
        (self.progress)("storing", stored, total);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ant_core::data::client::batch::SingleNodeQuotePayment;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Duration;

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
            // A person at a hardware wallet.
            tokio::time::sleep(Duration::from_secs(2)).await;
            alloy::network::TxSigner::sign_transaction(&self.inner, tx).await
        }
    }

    fn anvil_available() -> bool {
        std::process::Command::new("anvil")
            .arg("--version")
            .output()
            .is_ok_and(|o| o.status.success())
    }

    fn wallet(testnet: &evmlib::testnet::Testnet) -> (Wallet, Arc<AtomicUsize>) {
        let key = testnet.default_wallet_private_key().unwrap();
        let inner: alloy::signers::local::PrivateKeySigner =
            key.trim_start_matches("0x").parse().unwrap();
        let signatures = Arc::new(AtomicUsize::new(0));
        let signer = CountingSigner { inner, signatures: signatures.clone() };
        (
            Wallet::new(
                testnet.to_network(),
                alloy::network::EthereumWallet::from(signer),
            ),
            signatures,
        )
    }

    /// A plan whose median quote pays `amount` (plus one zero-amount
    /// quote, as every real plan carries).
    fn plan(byte: u8, amount: u64) -> ChunkPaymentPlan {
        // QuotePaymentInfo lives in ant-protocol (not a direct dependency
        // here), so the payment is built through its serde form.
        let info = |b: u8, amount: u64| {
            serde_json::json!({
                "quote_hash": QuoteHash::repeat_byte(b),
                "rewards_address": evmlib::common::Address::repeat_byte(b),
                "amount": Amount::from(amount),
                "price": Amount::from(amount / 3),
            })
        };
        let payment: SingleNodeQuotePayment = serde_json::from_value(serde_json::json!({
            "quotes": [info(byte, amount), info(byte.wrapping_add(100), 0)],
        }))
        .unwrap();
        ChunkPaymentPlan {
            address: [byte; 32],
            data_size: 3,
            quoted_peers: Vec::new(),
            payment,
            peer_quotes: Vec::new(),
            commitment_sidecars: Vec::new(),
        }
    }

    fn pending() -> UploadState {
        let mut state = UploadState::default();
        let mut attempt = PaymentAttempt {
            merkle: false,
            addresses: Vec::new(),
            submissions: Vec::new(),
            receipt: None,
        };
        payjournal::initialize(&mut attempt);
        state.pending_payment = Some(attempt);
        state
    }

    fn adapter(wallet: Wallet, pointer: Option<ChunkPaymentPlan>) -> BackupAdapter {
        BackupAdapter::new(
            wallet,
            Arc::new(HashMap::new()),
            pointer,
            Box::new(|_, _, _| {}),
        )
    }

    /// The whole point, on a real (local) chain: the chunks AND the
    /// pointer are paid by ONE signed transaction; the driver is told
    /// only the chunk share; the pointer's quote is bound to that same
    /// transaction; nothing is ever paid twice.
    ///
    /// Needs `anvil` (Foundry) on PATH; skipped without it.
    #[tokio::test(flavor = "multi_thread")]
    async fn chunks_and_pointer_share_one_signed_payment() {
        if !anvil_available() {
            eprintln!("skipped: anvil is not installed");
            return;
        }
        let testnet = evmlib::testnet::Testnet::new().await.unwrap();
        let (wallet, signatures) = wallet(&testnet);
        // The allowance is granted up front, as the backup job does.
        payjournal::ensure_unlimited_allowance(&wallet).await.unwrap();
        assert_eq!(signatures.load(Ordering::SeqCst), 1);
        let before = wallet.balance_of_tokens().await.unwrap();

        let adapter = adapter(wallet.clone(), Some(plan(9, 700)));
        assert!(adapter.pointer_proof().is_none());
        let chunk_plans = vec![plan(1, 1_000), plan(2, 2_500)];
        let mut state = pending();
        let payment = adapter
            .pay_quotes(&chunk_plans, &mut state, |_| true)
            .await
            .unwrap();

        // ONE signature paid for everything.
        assert_eq!(signatures.load(Ordering::SeqCst), 2);
        assert_eq!(adapter.payments(), 1);
        // The driver hears the chunk share only…
        assert_eq!(payment.amount, Amount::from(3_500u64));
        assert_eq!(payment.transactions.len(), 2);
        // …while the wallet paid chunks + pointer.
        assert_eq!(
            before - wallet.balance_of_tokens().await.unwrap(),
            Amount::from(4_200u64)
        );
        // The pointer's paid quote is bound to the same transaction.
        let tx = *payment.transactions.values().next().unwrap();
        let paid = adapter.pointer_paid.lock().unwrap().clone().unwrap();
        assert_eq!(paid.1.get(&QuoteHash::repeat_byte(9)), Some(&tx));
        assert_eq!(paid.1.len(), 1);

        // A later wave pays chunks only — the pointer never rides twice.
        let mut next = pending();
        let later = adapter
            .pay_quotes(&[plan(3, 400)], &mut next, |_| true)
            .await
            .unwrap();
        assert_eq!(later.amount, Amount::from(400u64));
        assert_eq!(
            before - wallet.balance_of_tokens().await.unwrap(),
            Amount::from(4_600u64)
        );
        // And paying the pointer "alone" afterwards is a no-op.
        let mut own = UploadState::default();
        adapter.pay_pointer_alone(&mut own).await.unwrap();
        assert_eq!(signatures.load(Ordering::SeqCst), 3);
    }

    /// The driver's reconcile after a lapsed confirmation window: the
    /// same request is rebuilt (pointer included), the saved transaction
    /// is found, nothing is signed, and the pointer's proof material is
    /// recovered.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_reconciled_payment_recovers_the_pointer_without_signing() {
        if !anvil_available() {
            eprintln!("skipped: anvil is not installed");
            return;
        }
        let testnet = evmlib::testnet::Testnet::new().await.unwrap();
        let (wallet, signatures) = wallet(&testnet);
        payjournal::ensure_unlimited_allowance(&wallet).await.unwrap();
        let before = wallet.balance_of_tokens().await.unwrap();

        let first = adapter(wallet.clone(), Some(plan(9, 700)));
        let mut state = pending();
        let paid = first
            .pay_quotes(&[plan(1, 1_000)], &mut state, |_| true)
            .await
            .unwrap();
        assert_eq!(signatures.load(Ordering::SeqCst), 2);

        // The run "forgot" the outcome: journal kept, receipt lost, and a
        // fresh adapter that still believes the pointer is unpaid.
        if let Some(attempt) = &mut state.pending_payment {
            attempt.receipt = None;
        }
        let again = adapter(wallet.clone(), Some(plan(9, 700)));
        let recovered = again
            .pay_quotes(&[plan(1, 1_000)], &mut state, |_| false)
            .await
            .unwrap();
        assert_eq!(signatures.load(Ordering::SeqCst), 2);
        assert_eq!(recovered.amount, paid.amount);
        assert_eq!(recovered.transactions, paid.transactions);
        assert!(again.pointer_paid.lock().unwrap().is_some());
        assert_eq!(
            before - wallet.balance_of_tokens().await.unwrap(),
            Amount::from(1_700u64)
        );
    }

    /// When no chunk payment carried it, the pointer pays alone: one
    /// signature, and a retry over the kept journal signs nothing.
    #[tokio::test(flavor = "multi_thread")]
    async fn the_pointer_pays_alone_when_nothing_carried_it() {
        if !anvil_available() {
            eprintln!("skipped: anvil is not installed");
            return;
        }
        let testnet = evmlib::testnet::Testnet::new().await.unwrap();
        let (wallet, signatures) = wallet(&testnet);
        payjournal::ensure_unlimited_allowance(&wallet).await.unwrap();
        let before = wallet.balance_of_tokens().await.unwrap();

        let adapter = adapter(wallet.clone(), Some(plan(9, 700)));
        let mut own = UploadState::default();
        adapter.pay_pointer_alone(&mut own).await.unwrap();
        assert_eq!(signatures.load(Ordering::SeqCst), 2);
        assert_eq!(adapter.payments(), 1);
        assert!(adapter.pointer_paid.lock().unwrap().is_some());
        assert_eq!(
            before - wallet.balance_of_tokens().await.unwrap(),
            Amount::from(700u64)
        );
        adapter.pay_pointer_alone(&mut own).await.unwrap();
        assert_eq!(signatures.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn zero_amount_quotes_are_never_sent_to_the_vault() {
        let quotes = BackupAdapter::quotes_of(&[plan(1, 10), plan(2, 20)]);
        assert_eq!(quotes.len(), 2);
        assert!(quotes.iter().all(|q| q.2 != Amount::ZERO));
    }
}
