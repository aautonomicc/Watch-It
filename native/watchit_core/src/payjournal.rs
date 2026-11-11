//! Sign-once payments for the pooled batch upload.
//!
//! evmlib has two ways to pay. The legacy one (`Wallet::pay_for_quotes`,
//! `Wallet::pay_for_merkle_tree`) signs INSIDE a 5-second broadcast
//! timeout and, on every retry, re-reads the fees and re-estimates the
//! gas — so each retry is a different transaction that needs its own
//! signature. A software key never notices. A hardware wallet cannot
//! finish a multi-screen confirmation in 5 seconds, so every retry put a
//! brand-new "confirm payment" on the device while the confirmation the
//! user had just given went to a transaction evmlib had already walked
//! away from: the endless confirm loop on the first live Trezor batch
//! payment (2026-11-09).
//!
//! The journal path (`evmlib::wallet::journal`) is the one ant-core's own
//! uploads use: [`Wallet::prepare_payment`] signs ONCE with no timeout,
//! [`Wallet::broadcast_payment`] only ever sends those exact bytes, and
//! [`Wallet::observe_payment`] watches the chain for them. ant-core keeps
//! its driver for that path private, so this module is ours, mirroring
//! `ant_core::data::client::native_payment` step for step:
//!
//!   * the signed bytes are saved in the upload checkpoint BEFORE the
//!     first broadcast, so a crash or a slow confirmation is picked up by
//!     the next run instead of being paid again;
//!   * an ambiguous outcome never signs or pays a second time — the same
//!     bytes are re-sent (a consumed nonce is rejected, never paid twice);
//!   * a stale nonce on bytes that never left the process is the one case
//!     that prepares again (once).
//!
//! The token allowance is granted here too, ahead of `prepare_payment`,
//! through a send with no signing deadline: evmlib's own approve goes
//! through the legacy path and would loop on a hardware wallet the same
//! way.

use std::time::Duration;

use alloy::network::TransactionBuilder;
use alloy::providers::Provider;
use ant_core::data::client::upload::UploadAdapter;
use ant_core::data::client::upload_state::{PaymentAttempt, UploadState};
use ant_core::data::error::{Error as AntError, Result as AntResult};
use ant_core::data::Wallet;
use evmlib::common::{Amount, U256};
use evmlib::contract::network_token::NetworkToken;
use evmlib::wallet::journal::{PaymentReceipt, PaymentRequest, PaymentStatus, SignedPayment};

/// How long a broadcast payment is watched before the run gives up and
/// leaves the journal for the next run to reconcile. Arbitrum confirms in
/// a second or two; this is headroom for a lagging public RPC endpoint.
const OBSERVE_WINDOW: Duration = Duration::from_secs(60);
/// How long an allowance transaction may take to confirm.
const APPROVE_WINDOW: Duration = Duration::from_secs(90);

/// Key of the journal marker inside `PaymentAttempt::submissions`.
const JOURNAL_KEY: &str = "watchit_payment_v1";

/// What the checkpoint holds for a payment in flight.
enum Journal {
    /// Nothing has been signed, so nothing can have been broadcast.
    Preparing,
    /// Signed bytes — the only thing this attempt will ever broadcast.
    Signed(SignedPayment),
}

impl Journal {
    fn to_value(&self) -> AntResult<serde_json::Value> {
        Ok(match self {
            Journal::Preparing => serde_json::json!({ JOURNAL_KEY: "preparing" }),
            Journal::Signed(signed) => serde_json::json!({
                JOURNAL_KEY: "signed",
                "transaction": serde_json::to_value(signed)
                    .map_err(|e| AntError::Serialization(e.to_string()))?,
            }),
        })
    }

    fn from_value(value: &serde_json::Value) -> Option<Self> {
        match value.get(JOURNAL_KEY)?.as_str()? {
            "preparing" => Some(Journal::Preparing),
            "signed" => serde_json::from_value(value.get("transaction")?.clone())
                .ok()
                .map(Journal::Signed),
            _ => None,
        }
    }
}

/// Mark a fresh attempt as "nothing signed yet". Runs synchronously,
/// before the attempt is first persisted and before any wallet I/O.
pub fn initialize(attempt: &mut PaymentAttempt) {
    attempt.submissions = vec![serde_json::json!({ JOURNAL_KEY: "preparing" })];
}

/// Does a restored attempt carry a journal this module can finish? An
/// attempt without one (a checkpoint written before the journal existed)
/// has an unknowable outcome.
pub fn is_reconcilable(attempt: &PaymentAttempt) -> bool {
    matches!(
        attempt.submissions.as_slice(),
        [value] if Journal::from_value(value).is_some()
    )
}

/// The network refused the nonce of a payment signed in this call. Those
/// bytes never left the process, so nothing was paid and preparing again
/// is safe.
const STALE_UNSENT_NONCE: &str = "stale nonce on an unsent payment; preparing again";

fn is_stale_nonce(message: &str) -> bool {
    message.to_ascii_lowercase().contains("nonce too low")
}

/// Did the endpoint itself refuse the transaction (as opposed to the
/// request failing on the way, which leaves the outcome unknown)? alloy
/// prints an RPC error response as "error code N: message"; the backend
/// timeouts a load balancer dresses up as error responses stay ambiguous.
fn is_definitive_rejection(message: &str) -> bool {
    let message = message.to_ascii_lowercase();
    message.contains("error code")
        && ![
            "deadline exceeded",
            "timeout",
            "timed out",
            "too many requests",
            "rate limit",
        ]
        .iter()
        .any(|needle| message.contains(needle))
}

/// Storage tokens the request will move, as evmlib itself computes it
/// (the worst-case pool for a merkle batch).
fn request_amount(wallet: &Wallet, request: &PaymentRequest) -> Amount {
    match request {
        PaymentRequest::Quotes(quotes) => quotes
            .iter()
            .fold(Amount::ZERO, |sum, (_, _, amount)| sum.saturating_add(*amount)),
        PaymentRequest::Merkle { depth, pools, .. } => {
            wallet.network().estimate_merkle_payment_cost(*depth, pools)
        }
    }
}

/// Make sure the payment vault may move `amount` of the wallet's tokens,
/// granting the (unlimited, one-time) allowance when it may not. The
/// signature is requested with NO deadline — the user confirms on a
/// hardware wallet at their own pace — and the send is not retried, so
/// there is exactly one confirmation.
async fn ensure_allowance(wallet: &Wallet, amount: Amount) -> Result<(), String> {
    let vault = *wallet.network().payment_vault_address();
    let allowance = wallet
        .token_allowance(vault)
        .await
        .map_err(|e| format!("could not read the token allowance: {e}"))?;
    if allowance >= amount {
        return Ok(());
    }
    tracing::info!("payment journal: granting the payment vault its token allowance");
    let provider = wallet.to_provider();
    let (calldata, token) =
        NetworkToken::new(*wallet.network().payment_token_address(), provider.clone())
            .approve_calldata(vault, U256::MAX);
    let mut tx = provider
        .transaction_request()
        .with_from(wallet.address())
        .with_to(token)
        .with_input(calldata);
    // The same 20% headroom evmlib adds everywhere: Arbitrum's estimate
    // moves with the L1 data price between estimate and inclusion.
    let gas = provider
        .estimate_gas(tx.clone())
        .await
        .map_err(|e| format!("allowance gas estimate failed: {e}"))?;
    tx.set_gas_limit(gas.saturating_mul(120) / 100);
    let pending = provider
        .send_transaction(tx)
        .await
        .map_err(|e| format!("the allowance transaction was not sent: {e}"))?;
    let receipt = pending
        .with_timeout(Some(APPROVE_WINDOW))
        .get_receipt()
        .await
        .map_err(|e| format!("the allowance transaction did not confirm: {e}"))?;
    if !receipt.status() {
        return Err("the allowance transaction reverted on-chain".into());
    }
    // `prepare_payment` reads the allowance again, possibly from a
    // replica a block behind — wait until the grant is visible so it does
    // not fall back to evmlib's own (deadline-bound) approve.
    for _ in 0..20 {
        if wallet
            .token_allowance(vault)
            .await
            .is_ok_and(|seen| seen >= amount)
        {
            return Ok(());
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    Err("the allowance was granted but is not visible on the network yet — try again in a moment".into())
}

/// Everything up to and including the one payment signature: the
/// balance check first (so an empty wallet hears "insufficient tokens",
/// not an allowance failure), then the allowance, then evmlib's
/// sign-without-broadcasting.
async fn prepare(wallet: &Wallet, request: &PaymentRequest) -> Result<SignedPayment, String> {
    let amount = request_amount(wallet, request);
    let balance = wallet
        .balance_of_tokens()
        .await
        .map_err(|e| format!("could not read the token balance: {e}"))?;
    if balance < amount {
        return Err(
            evmlib::wallet::Error::InsufficientTokensForQuotes(balance, amount).to_string(),
        );
    }
    ensure_allowance(wallet, amount).await?;
    wallet.prepare_payment(request).await
}

/// Grant the payment vault its (unlimited, one-time) token allowance up
/// front when the wallet has not granted it yet. For hardware wallets:
/// batch uploads ask before encryption instead of at the first payment,
/// and on the backup path ant-core drives itself the allowance would
/// otherwise be requested mid-job through evmlib's deadline-bound send,
/// re-asking for a confirmation on every retry.
pub async fn ensure_unlimited_allowance(wallet: &Wallet) -> Result<(), String> {
    ensure_allowance(wallet, U256::MAX >> 1).await
}

/// Pay `request` through the journal recorded on `state.pending_payment`:
/// sign once, save, broadcast, watch. Safe to call again on a restored
/// state — a journal that already holds signed bytes is observed (and at
/// most re-sent), never re-signed.
///
/// `fresh` says whether the quotes behind the request are still valid;
/// `signing` runs right before the wallet is asked for a signature.
pub async fn execute<A, F, S>(
    wallet: &Wallet,
    adapter: &A,
    request: &PaymentRequest,
    state: &mut UploadState,
    fresh: F,
    signing: S,
) -> AntResult<PaymentReceipt>
where
    A: UploadAdapter,
    F: Fn(&UploadState) -> bool + Send + Sync,
    S: Fn() + Send + Sync,
{
    // A nonce read from a public endpoint can lag the chain, so a freshly
    // signed payment can carry a nonce already consumed. Such bytes can
    // never be mined and were never sent: one re-preparation is the fix.
    match execute_once(wallet, adapter, request, state, &fresh, &signing).await {
        Err(AntError::Payment(message)) if message == STALE_UNSENT_NONCE => {
            execute_once(wallet, adapter, request, state, &fresh, &signing).await
        }
        outcome => outcome,
    }
}

async fn execute_once<A, F, S>(
    wallet: &Wallet,
    adapter: &A,
    request: &PaymentRequest,
    state: &mut UploadState,
    fresh: &F,
    signing: &S,
) -> AntResult<PaymentReceipt>
where
    A: UploadAdapter,
    F: Fn(&UploadState) -> bool + Send + Sync,
    S: Fn() + Send + Sync,
{
    let attempt = state
        .pending_payment
        .as_ref()
        .ok_or_else(|| AntError::Payment("missing payment attempt".into()))?;
    let journal: Journal = match attempt.submissions.as_slice() {
        [value] => Journal::from_value(value).ok_or_else(|| {
            AntError::Payment(
                "unknown payment journal; its outcome cannot be established".into(),
            )
        })?,
        _ => {
            return Err(AntError::Payment(
                "pending payment has no transaction journal; its outcome cannot be established"
                    .into(),
            ))
        }
    };
    let _wallet_lock = wallet.lock().await;
    // True only for bytes signed below, in this call: they have never
    // been broadcast, so there is nothing on chain to observe first.
    let mut unsent = false;
    let signed = match journal {
        Journal::Signed(signed) => signed,
        Journal::Preparing => {
            // The marker proves this attempt broadcast nothing.
            let prepared = if !fresh(state) {
                Err("unsubmitted payment quotes expired; retry to prepare fresh quotes".to_string())
            } else {
                signing();
                prepare(wallet, request).await
            };
            let signed = match prepared {
                Ok(signed) => signed,
                Err(message) => {
                    state.pending_payment = None;
                    adapter.checkpoint(state, None).await?;
                    return Err(AntError::Payment(message));
                }
            };
            let value = Journal::Signed(signed.clone()).to_value()?;
            if let Some(attempt) = &mut state.pending_payment {
                attempt.submissions = vec![value];
            }
            adapter.checkpoint(state, None).await?;
            unsent = true;
            signed
        }
    };
    let mut broadcast = false;
    let observation = async {
        loop {
            if unsent && !broadcast {
                // A rejected nonce here can only be a stale nonce read:
                // discard the journal and let `execute` prepare again.
                // Any other rejection is final for this attempt.
                match wallet.broadcast_payment(&signed, request).await {
                    Ok(_) => broadcast = true,
                    Err(message) if is_stale_nonce(&message) => {
                        if let Some(attempt) = &mut state.pending_payment {
                            initialize(attempt);
                        }
                        adapter.checkpoint(state, None).await?;
                        return Err(AntError::Payment(STALE_UNSENT_NONCE.into()));
                    }
                    Err(message) if is_definitive_rejection(&message) => {
                        // The endpoint answered and refused these bytes,
                        // so they are in no mempool. Nothing was paid; a
                        // later attempt reuses the same nonce, so these
                        // bytes can never be mined beside it.
                        state.pending_payment = None;
                        adapter.checkpoint(state, None).await?;
                        return Err(AntError::Payment(message));
                    }
                    // Anything else is ambiguous (the send may have
                    // landed): keep the journal so the next run observes
                    // and re-sends these bytes instead of paying again.
                    Err(message) => return Err(AntError::Payment(message)),
                }
            }
            match wallet
                .observe_payment(&signed, request)
                .await
                .map_err(AntError::Payment)?
            {
                PaymentStatus::Confirmed(receipt) => {
                    if let Some(attempt) = &mut state.pending_payment {
                        attempt.receipt = Some(
                            serde_json::to_value(&receipt)
                                .map_err(|e| AntError::Serialization(e.to_string()))?,
                        );
                    }
                    adapter.checkpoint(state, None).await?;
                    return Ok(receipt);
                }
                PaymentStatus::Reverted => {
                    state.pending_payment = None;
                    adapter.checkpoint(state, None).await?;
                    return Err(AntError::Payment(
                        "payment reverted on-chain; retry is safe".into(),
                    ));
                }
                PaymentStatus::Finalizing => {
                    return Err(AntError::Payment(
                        "payment outcome is awaiting chain finality; run the upload again in a few minutes — it will not be paid twice"
                            .into(),
                    ));
                }
                PaymentStatus::Replaced { transaction_hash } => {
                    state.pending_payment = None;
                    adapter.checkpoint(state, None).await?;
                    return Err(AntError::Payment(format!(
                        "payment nonce was finalized by transaction {transaction_hash}; retry is safe"
                    )));
                }
                PaymentStatus::Pending => {
                    if !broadcast {
                        if !fresh(state) {
                            return Err(AntError::Payment(
                                "pending payment has expired quotes; its transaction journal is kept for reconciliation"
                                    .into(),
                            ));
                        }
                        // An ambiguous send only ever retries these exact
                        // signed bytes.
                        wallet
                            .broadcast_payment(&signed, request)
                            .await
                            .map_err(AntError::Payment)?;
                        broadcast = true;
                    }
                    tokio::time::sleep(Duration::from_secs(1)).await;
                }
            }
        }
    };
    tokio::time::timeout(OBSERVE_WINDOW, observation)
        .await
        .map_err(|_| {
            AntError::Payment(
                "the payment was sent but has not confirmed yet — run the upload again to pick it up; it will not be paid twice"
                    .into(),
            )
        })?
}

#[cfg(test)]
mod tests {
    use super::*;
    use ant_core::data::client::batch::ChunkPaymentPlan;
    use ant_core::data::client::upload::{UploadPayment, UploadRecord};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    /// Persists nothing, counts everything.
    #[derive(Default)]
    struct CountingAdapter {
        checkpoints: AtomicUsize,
    }

    #[async_trait::async_trait]
    impl UploadAdapter for CountingAdapter {
        async fn load(&self, _record: UploadRecord) -> AntResult<bytes::Bytes> {
            Err(AntError::InvalidData("not used".into()))
        }
        async fn pay(&self, _plans: &[ChunkPaymentPlan]) -> AntResult<UploadPayment> {
            Err(AntError::Payment("not used".into()))
        }
        async fn checkpoint(
            &self,
            _state: &UploadState,
            _payment: Option<&UploadPayment>,
        ) -> AntResult<()> {
            self.checkpoints.fetch_add(1, Ordering::SeqCst);
            Ok(())
        }
    }

    fn pending_state() -> UploadState {
        let mut state = UploadState::default();
        let mut attempt = PaymentAttempt {
            merkle: false,
            addresses: Vec::new(),
            submissions: Vec::new(),
            receipt: None,
        };
        initialize(&mut attempt);
        state.pending_payment = Some(attempt);
        state
    }

    #[test]
    fn journal_markers_round_trip_and_gate_reconciliation() {
        let mut attempt = PaymentAttempt {
            merkle: true,
            addresses: Vec::new(),
            submissions: Vec::new(),
            receipt: None,
        };
        // No journal at all (a checkpoint from before this module).
        assert!(!is_reconcilable(&attempt));
        initialize(&mut attempt);
        assert!(is_reconcilable(&attempt));
        assert!(matches!(
            Journal::from_value(&attempt.submissions[0]),
            Some(Journal::Preparing)
        ));
        // Somebody else's journal is not ours to finish.
        attempt.submissions = vec![serde_json::json!({ "native_payment_v1": "preparing" })];
        assert!(!is_reconcilable(&attempt));
        attempt.submissions = vec![serde_json::json!("garbage"), serde_json::json!(1)];
        assert!(!is_reconcilable(&attempt));
    }

    #[test]
    fn broadcast_errors_are_sorted_by_what_they_prove() {
        assert!(is_stale_nonce("server returned an error: Nonce too low: next 5"));
        assert!(!is_stale_nonce("insufficient funds for gas * price + value"));
        // The endpoint refused the bytes: nothing is in flight.
        assert!(is_definitive_rejection(
            "server returned an error response: error code -32000: insufficient funds for gas * price + value"
        ));
        // The request never got a real answer: the bytes may have landed.
        assert!(!is_definitive_rejection("error sending request for url (https://arb1.arbitrum.io/rpc)"));
        assert!(!is_definitive_rejection("HTTP error 429 with body: too many requests"));
        assert!(!is_definitive_rejection(
            "server returned an error response: error code -32000: context deadline exceeded"
        ));
    }

    /// Counts every signature the wallet is asked for — the number that
    /// must stay at one per payment whatever happens around it.
    struct CountingSigner {
        inner: alloy::signers::local::PrivateKeySigner,
        signatures: Arc<AtomicUsize>,
        delay: Duration,
        /// Answer like a hardware wallet whose user pressed Cancel.
        refuse: bool,
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
            // A person at a hardware wallet: far past evmlib's 5 s
            // broadcast deadline.
            tokio::time::sleep(self.delay).await;
            if self.refuse {
                return Err(alloy::signers::Error::other("cancelled on the device"));
            }
            alloy::network::TxSigner::sign_transaction(&self.inner, tx).await
        }
    }

    fn anvil_available() -> bool {
        std::process::Command::new("anvil")
            .arg("--version")
            .output()
            .is_ok_and(|o| o.status.success())
    }

    fn slow_wallet(
        testnet: &evmlib::testnet::Testnet,
        delay: Duration,
    ) -> (Wallet, Arc<AtomicUsize>) {
        test_wallet(testnet, delay, false)
    }

    fn test_wallet(
        testnet: &evmlib::testnet::Testnet,
        delay: Duration,
        refuse: bool,
    ) -> (Wallet, Arc<AtomicUsize>) {
        let key = testnet.default_wallet_private_key().unwrap();
        let inner: alloy::signers::local::PrivateKeySigner =
            key.trim_start_matches("0x").parse().unwrap();
        let signatures = Arc::new(AtomicUsize::new(0));
        let signer = CountingSigner {
            inner,
            signatures: signatures.clone(),
            delay,
            refuse,
        };
        let wallet = Wallet::new(
            testnet.to_network(),
            alloy::network::EthereumWallet::from(signer),
        );
        (wallet, signatures)
    }

    fn quote(byte: u8, amount: u64) -> evmlib::common::QuotePayment {
        (
            evmlib::common::QuoteHash::repeat_byte(byte),
            evmlib::common::Address::repeat_byte(byte),
            Amount::from(amount),
        )
    }

    /// The live failure, on a real (local) chain: a signer that takes 7 s
    /// per signature — longer than evmlib's 5 s broadcast deadline — pays
    /// with exactly ONE allowance signature and ONE payment signature,
    /// and a second run over the saved journal confirms the same
    /// transaction without signing anything.
    ///
    /// Needs `anvil` (Foundry) on PATH; skipped without it.
    #[tokio::test(flavor = "multi_thread")]
    async fn slow_signer_pays_once_and_reconciles_without_signing() {
        if !anvil_available() {
            eprintln!("skipped: anvil is not installed");
            return;
        }
        let testnet = evmlib::testnet::Testnet::new().await.unwrap();
        let (wallet, signatures) = slow_wallet(&testnet, Duration::from_secs(7));
        let vault = *wallet.network().payment_vault_address();
        assert_eq!(wallet.token_allowance(vault).await.unwrap(), Amount::ZERO);
        let before = wallet.balance_of_tokens().await.unwrap();

        let adapter = CountingAdapter::default();
        let request = PaymentRequest::Quotes(vec![quote(1, 1_000), quote(2, 2_500)]);
        let mut state = pending_state();
        let signing_calls = AtomicUsize::new(0);
        let receipt = execute(
            &wallet,
            &adapter,
            &request,
            &mut state,
            |_| true,
            || {
                signing_calls.fetch_add(1, Ordering::SeqCst);
            },
        )
        .await
        .unwrap();

        assert_eq!(receipt.amount, Amount::from(3_500u64));
        assert_eq!(
            before - wallet.balance_of_tokens().await.unwrap(),
            Amount::from(3_500u64)
        );
        // One allowance + one payment, despite 7 s per signature.
        assert_eq!(signatures.load(Ordering::SeqCst), 2);
        assert_eq!(signing_calls.load(Ordering::SeqCst), 1);
        assert!(wallet.token_allowance(vault).await.unwrap() >= Amount::from(3_500u64));
        // Saved after signing (before the first broadcast) and again with
        // the receipt.
        assert!(adapter.checkpoints.load(Ordering::SeqCst) >= 2);
        let attempt = state.pending_payment.as_ref().unwrap();
        assert!(attempt.receipt.is_some());
        assert!(matches!(
            Journal::from_value(&attempt.submissions[0]),
            Some(Journal::Signed(_))
        ));

        // A later run restores the same journal (the app died before the
        // receipt was recorded): same transaction, no signature, no spend.
        let mut restored = UploadState::restore(&state.checkpoint().unwrap()).unwrap();
        if let Some(attempt) = &mut restored.pending_payment {
            attempt.receipt = None;
        }
        let again = execute(&wallet, &adapter, &request, &mut restored, |_| false, || {
            panic!("a signed journal must never ask for another signature")
        })
        .await
        .unwrap();
        assert_eq!(again.transaction_hash, receipt.transaction_hash);
        assert_eq!(signatures.load(Ordering::SeqCst), 2);
        assert_eq!(
            before - wallet.balance_of_tokens().await.unwrap(),
            Amount::from(3_500u64)
        );

        // With the allowance in place, the next payment is one signature.
        let mut next = pending_state();
        let request = PaymentRequest::Quotes(vec![quote(3, 400)]);
        execute(&wallet, &adapter, &request, &mut next, |_| true, || {})
            .await
            .unwrap();
        assert_eq!(signatures.load(Ordering::SeqCst), 3);
    }

    /// The path this module replaces, pinned so the reason stays visible:
    /// the same slow signer through evmlib's legacy send is asked to sign
    /// again and again (once per retry) and still fails.
    ///
    /// Slow by nature (evmlib's own retry ladder, about 80 s) and needs
    /// `anvil`; run with `--ignored`.
    #[tokio::test(flavor = "multi_thread")]
    #[ignore]
    async fn legacy_send_asks_a_slow_signer_again_on_every_retry() {
        if !anvil_available() {
            eprintln!("skipped: anvil is not installed");
            return;
        }
        let testnet = evmlib::testnet::Testnet::new().await.unwrap();
        let (wallet, signatures) = slow_wallet(&testnet, Duration::from_secs(7));
        let result = wallet
            .approve_to_spend_tokens(*wallet.network().payment_vault_address(), U256::MAX)
            .await;
        assert!(result.is_err(), "the 5 s deadline cannot contain a 7 s signature");
        assert!(signatures.load(Ordering::SeqCst) >= 2);
    }

    /// An empty wallet is told it lacks tokens — before any allowance
    /// transaction or signature is attempted.
    #[tokio::test(flavor = "multi_thread")]
    async fn empty_wallet_hears_insufficient_tokens_before_any_signature() {
        if !anvil_available() {
            eprintln!("skipped: anvil is not installed");
            return;
        }
        let testnet = evmlib::testnet::Testnet::new().await.unwrap();
        let signatures = Arc::new(AtomicUsize::new(0));
        let signer = CountingSigner {
            inner: alloy::signers::local::PrivateKeySigner::random(),
            signatures: signatures.clone(),
            delay: Duration::ZERO,
            refuse: false,
        };
        let wallet = Wallet::new(
            testnet.to_network(),
            alloy::network::EthereumWallet::from(signer),
        );
        let adapter = CountingAdapter::default();
        let request = PaymentRequest::Quotes(vec![quote(1, 1_000)]);
        let mut state = pending_state();
        let err = execute(&wallet, &adapter, &request, &mut state, |_| true, || {})
            .await
            .unwrap_err();
        assert!(
            err.to_string().to_lowercase().contains("insufficient"),
            "unexpected error: {err}"
        );
        assert!(state.pending_payment.is_none());
        assert_eq!(signatures.load(Ordering::SeqCst), 0);
    }

    /// The user presses Cancel on the device: the run fails with the
    /// signer's own words, nothing is spent, and no pending attempt is
    /// left behind for the next run to chase.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_refused_signature_spends_nothing_and_clears_the_attempt() {
        if !anvil_available() {
            eprintln!("skipped: anvil is not installed");
            return;
        }
        let testnet = evmlib::testnet::Testnet::new().await.unwrap();
        let (wallet, signatures) = test_wallet(&testnet, Duration::ZERO, true);
        let before = wallet.balance_of_tokens().await.unwrap();
        let adapter = CountingAdapter::default();
        let request = PaymentRequest::Quotes(vec![quote(1, 1_000)]);
        let mut state = pending_state();
        let err = execute(&wallet, &adapter, &request, &mut state, |_| true, || {})
            .await
            .unwrap_err();
        assert!(
            err.to_string().contains("cancelled on the device"),
            "unexpected error: {err}"
        );
        assert!(state.pending_payment.is_none());
        // Asked once, not once per retry.
        assert_eq!(signatures.load(Ordering::SeqCst), 1);
        assert_eq!(wallet.balance_of_tokens().await.unwrap(), before);
    }

    /// A payment that never reaches the signer (its quotes expired first)
    /// leaves no pending attempt behind: the next run starts clean
    /// instead of trying to reconcile a payment that never existed.
    #[tokio::test(flavor = "multi_thread")]
    async fn refused_quotes_clear_the_attempt() {
        if !anvil_available() {
            eprintln!("skipped: anvil is not installed");
            return;
        }
        let testnet = evmlib::testnet::Testnet::new().await.unwrap();
        let (wallet, signatures) = slow_wallet(&testnet, Duration::ZERO);
        let adapter = CountingAdapter::default();
        let request = PaymentRequest::Quotes(vec![quote(1, 1_000)]);
        let mut state = pending_state();
        let err = execute(&wallet, &adapter, &request, &mut state, |_| false, || {})
            .await
            .unwrap_err();
        assert!(err.to_string().contains("expired"));
        assert!(state.pending_payment.is_none());
        assert_eq!(signatures.load(Ordering::SeqCst), 0);
        assert_eq!(adapter.checkpoints.load(Ordering::SeqCst), 1);
    }
}
