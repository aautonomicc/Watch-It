//! Hardware-wallet plan, phase 3: Trezor over direct USB.
//!
//! The device keeps the 12 words; W@tch only ever sees ADDRESSES and
//! SIGNATURES. Payments sign on the device (one physical confirmation
//! per transaction — evmlib drives whatever signer the seam in signer.rs
//! hands it), and the backup identity derives from the device's
//! deterministic EIP-191 signature of [IDENTITY_MESSAGE_V1] (phase 1's
//! sign-to-derive), so the same 12 words land on the same address AND
//! the same backup line whether they live in the app or in a Trezor.
//!
//! Key policy (phase 4, settled 2026-10-10): the device being the only
//! holder of the private key makes paranoid payments automatic. The
//! WRITE half of the backup identity (the ML-DSA pointer seed) is never
//! persisted — each backup re-derives it with one confirmation on the
//! device, and the derived pointer must match the configured one (a
//! wrong device or changed passphrase fails loudly instead of minting a
//! parallel backup line). The READ half (content key) persists in the
//! OS keychain only when the user keeps "share backup read keys" on at
//! setup — the default, so linked devices can follow backups and the
//! Backup screen works with the device unplugged.
//!
//! Transport is trezor-client over rusb — direct USB, no Trezor Bridge.
//! On Linux the standard Trezor udev rules must be installed; permission
//! failures map to a message that says so. Every device conversation
//! runs on a blocking thread (`spawn_blocking` + `Handle::block_on`):
//! the alloy signer's async methods do synchronous USB I/O inside, and a
//! signature takes as long as the user takes to press the button — never
//! park that on an async worker.

use crate::backup::{derive_keys_from_signature, BackupKeys};

/// The derivation the signer uses — m/44'/60'/0'/0/0, the exact path the
/// software wallet's 12 words derive at (wallet.rs), so the same words
/// in a Trezor land on the same address and backup line as an import.
pub const DERIVATION_PATH: &str = "m/44'/60'/0'/0/0";

/// [DERIVATION_PATH] as the BIP-32 integer path trezor-client takes
/// (hardened = bit 31) — must stay in lock-step with the constant above;
/// pinned against a string parse in the tests.
pub fn derivation_path_vec() -> Vec<u32> {
    const H: u32 = 0x8000_0000;
    vec![44 | H, 60 | H, H, 0, 0]
}

/// What the setup ceremony yields: the device's address at
/// [DERIVATION_PATH] — shown AND confirmed on the device's own screen as
/// the ceremony's last step — and the backup identity its signature
/// derives.
pub struct TrezorIdentity {
    pub address: String,
    pub keys: BackupKeys,
}

/// Sign-twice determinism guard (the pure half, pinned by tests): a
/// signer that does not repeat the identity signature would mint a
/// backup identity nothing could ever re-derive — refuse before deriving
/// anything. Trezor ECDSA is RFC-6979 deterministic, so a mismatch means
/// a broken or impostor device.
pub fn ceremony_keys(first: &[u8; 64], second: &[u8; 64]) -> Result<BackupKeys, String> {
    if first != second {
        return Err(
            "the Trezor did not repeat the identity signature — refusing to \
             derive backup keys a fresh install could never re-derive"
                .into(),
        );
    }
    Ok(derive_keys_from_signature(first))
}

/// The attention beacon: whenever a device conversation is WAITING FOR A
/// HUMAN at the Trezor (a confirmation tap, the address screen), the
/// action is published here and served over `GET /trezor/activity`, so
/// the app can pop an explanation + play a sound the moment the device
/// lights up. Silent USB round trips (probe, address reads) never set
/// it — only steps that stall until someone touches the device.
///
/// Lives outside the desktop-only module so the route compiles on every
/// target; nothing ever sets it off-desktop.
pub mod attention {
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::Mutex;

    static SEQ: AtomicU64 = AtomicU64::new(0);
    static CURRENT: Mutex<Option<(u64, &'static str)>> = Mutex::new(None);

    /// Clears the action on drop — but only if a newer action has not
    /// replaced it (two overlapping guards never erase each other's
    /// state out from under the poller).
    pub struct Guard {
        seq: u64,
    }

    impl Drop for Guard {
        fn drop(&mut self) {
            let mut current = CURRENT.lock().unwrap_or_else(|p| p.into_inner());
            if matches!(*current, Some((seq, _)) if seq == self.seq) {
                *current = None;
            }
        }
    }

    /// Mark the start of a step that waits on the device's button.
    /// `action` is a stable machine word the app maps to copy:
    /// `sign-identity`, `confirm-address`, `sign-payment`.
    pub fn begin(action: &'static str) -> Guard {
        let seq = SEQ.fetch_add(1, Ordering::Relaxed) + 1;
        *CURRENT.lock().unwrap_or_else(|p| p.into_inner()) = Some((seq, action));
        Guard { seq }
    }

    /// (active, seq, action) — seq grows per action so a poller can tell
    /// a NEW tap apart from one it already announced.
    pub fn snapshot() -> (bool, u64, Option<&'static str>) {
        let current = CURRENT.lock().unwrap_or_else(|p| p.into_inner());
        match *current {
            Some((seq, action)) => (true, seq, Some(action)),
            None => (false, SEQ.load(Ordering::Relaxed), None),
        }
    }
}

/// Did this signature really come from the expected wallet? Recover the
/// signer over the transaction's own signature hash and compare — the
/// local, tap-free version of the check evmlib's payment journal does
/// right before broadcasting, pulled forward so a bad device signature
/// fails HERE with a message that names the device instead of surfacing
/// later as "journaled transaction does not match". On mismatch the
/// recovered address (or the recovery error) comes back as the Err.
pub fn verify_payment_signature(
    hash: &alloy::primitives::B256,
    sig: &alloy::primitives::Signature,
    expected: alloy::primitives::Address,
) -> Result<(), String> {
    match sig.recover_address_from_prehash(hash) {
        Ok(got) if got == expected => Ok(()),
        Ok(got) => Err(format!("{got}")),
        Err(e) => Err(format!("an unrecoverable signature ({e})")),
    }
}

/// The secp256k1 group order — needed to try the low-s normalization of
/// a signature some stack handed over in high-s form.
fn secp256k1_order() -> alloy::primitives::U256 {
    alloy::primitives::U256::from_str_radix(
        "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141",
        16,
    )
    .expect("the secp256k1 order is a valid hex constant")
}

/// The signature shapes a CORRECT device signature could arrive in after
/// a v-conversion or canonicalization quirk somewhere in the transport
/// stack: as handed over, parity-flipped, and (for a high-s signature)
/// the low-s normalization under both parities. The original always
/// comes first so an already-good signature is returned untouched.
fn signature_repair_candidates(
    sig: &alloy::primitives::Signature,
) -> Vec<alloy::primitives::Signature> {
    use alloy::primitives::Signature;
    let mut out = vec![*sig, Signature::new(sig.r(), sig.s(), !sig.v())];
    let order = secp256k1_order();
    let half = order >> 1;
    if sig.s() > half {
        let low = order - sig.s();
        out.push(Signature::new(sig.r(), low, sig.v()));
        out.push(Signature::new(sig.r(), low, !sig.v()));
    }
    out
}

/// [verify_payment_signature] with self-repair: when the signature as
/// handed over does not recover to the expected wallet but one of its
/// parity/low-s siblings DOES, that sibling is returned — recovery to
/// the expected address over the transaction's own hash is the final
/// arbiter, so a repaired signature is by definition a valid signature
/// of this wallet over this transaction and accepting it loses nothing.
/// Err carries what the ORIGINAL recovered to (the diagnostic).
pub fn verify_or_repair_payment_signature(
    hash: &alloy::primitives::B256,
    sig: &alloy::primitives::Signature,
    expected: alloy::primitives::Address,
) -> Result<alloy::primitives::Signature, String> {
    let mut original_err = None;
    for candidate in signature_repair_candidates(sig) {
        match verify_payment_signature(hash, &candidate, expected) {
            Ok(()) => return Ok(candidate),
            Err(e) => {
                if original_err.is_none() {
                    original_err = Some(e);
                }
            }
        }
    }
    Err(original_err.unwrap_or_else(|| "an unrecoverable signature".into()))
}

/// The concrete EIP-1559 transaction behind whatever `dyn` shape the
/// caller hands over. alloy's `EthereumWallet` signs through
/// `sign_transaction_from(sender, tx: TypedTransaction)` and passes the
/// ENUM itself down as the `dyn SignableTransaction` — so on evmlib's
/// payment path the concrete `Any` type is `TypedTransaction`, never a
/// bare `TxEip1559`. That matters because alloy-signer-trezor picks the
/// device request by downcasting to the concrete `TxEip1559`: when the
/// downcast misses, it silently falls back to a LEGACY
/// `ethereum_sign_tx` request, the device signs the EIP-155 legacy hash
/// of the same fields, and that signature can never recover over the
/// EIP-1559 typed hash — recovery lands on a pseudo-random address that
/// changes with every nonce/fee change (the 2026-10-11 "signed as a
/// different wallet each run" failure, root-caused from the field dump:
/// `tx: non-eip1559` proved the enum reaches the signer). The fix is to
/// always sign with the CONCRETE transaction this helper extracts.
pub fn concrete_eip1559(
    tx: &dyn alloy::consensus::SignableTransaction<alloy::primitives::Signature>,
) -> Option<alloy::consensus::TxEip1559> {
    let any = tx as &dyn std::any::Any;
    if let Some(t) = any.downcast_ref::<alloy::consensus::TxEip1559>() {
        return Some(t.clone());
    }
    any.downcast_ref::<alloy::consensus::TypedTransaction>()
        .and_then(|t| t.eip1559().cloned())
}

/// Does this EIP-191 signature of [crate::backup::IDENTITY_MESSAGE_V1]
/// really come from `reported_address` (the address the device claims
/// over USB)? Tried with the signature's own parity and flipped (v
/// encodings vary across firmware); a key that matches under NEITHER
/// means the device signs with a different key than the account it
/// reports — the one failure the ceremony's address checks can never
/// see, caught here BEFORE anything is persisted. Err names what the
/// signature actually recovered to.
pub fn identity_recovers_to(
    sig: &alloy::primitives::Signature,
    reported_address: &str,
) -> Result<(), String> {
    let expected: alloy::primitives::Address = reported_address
        .parse()
        .map_err(|_| format!("the device reported an unparseable address ({reported_address})"))?;
    let hash =
        alloy::primitives::eip191_hash_message(crate::backup::IDENTITY_MESSAGE_V1.as_bytes());
    let mut got = String::new();
    for candidate in [
        *sig,
        alloy::primitives::Signature::new(sig.r(), sig.s(), !sig.v()),
    ] {
        match candidate.recover_address_from_prehash(&hash) {
            Ok(addr) if addr == expected => return Ok(()),
            Ok(addr) => {
                if got.is_empty() {
                    got = format!("{addr}");
                }
            }
            Err(e) => {
                if got.is_empty() {
                    got = format!("an unrecoverable signature ({e})");
                }
            }
        }
    }
    Err(got)
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos"))]
mod device {
    use super::*;
    use alloy_signer_trezor::{HDPath, TrezorSigner};

    /// Arbitrum One — the chain every W@tch payment lives on; baked into
    /// the signer so the device shows the right network at confirm time.
    const CHAIN_ID: u64 = 42161;

    /// Map transport/device errors to end-user language. The udev hint
    /// matters: on Linux a fresh machine without the Trezor rules sees a
    /// permission error, not "no device".
    fn friendly(e: impl std::fmt::Display) -> String {
        let msg = e.to_string();
        let lower = msg.to_lowercase();
        if lower.contains("no device")
            || lower.contains("not found")
            || lower.contains("could not be found")
            || lower.contains("unable to connect")
        {
            return "no Trezor found — plug it in, unlock it, and try again".into();
        }
        if lower.contains("cancel") {
            return "cancelled on the Trezor — nothing was changed".into();
        }
        if lower.contains("denied") || lower.contains("permission") || lower.contains("access") {
            let hint = if cfg!(target_os = "linux") {
                " On Linux this usually means the Trezor udev rules are not \
                 installed — install them (trezor.io → Learn → udev rules), \
                 replug the device, and try again."
            } else {
                ""
            };
            return format!("the Trezor was found but could not be opened ({msg}).{hint}");
        }
        format!("Trezor: {msg}")
    }

    /// ONE device conversation at a time, process-wide: two concurrent
    /// USB conversations with the same Trezor interleave messages and
    /// can abort each other's in-progress workflow (the wallet screen's
    /// presence probe racing a setup ceremony was the live case). Every
    /// full conversation holds this; the probe only try-locks so it can
    /// answer "busy" instead of stalling behind a minutes-long tap wait.
    static DEVICE_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

    /// Run one device conversation on a blocking thread, holding the
    /// already-acquired conversation lock for its whole duration. The
    /// closure gets a freshly connected signer; everything it awaits is
    /// synchronous USB underneath, plus however long the user takes at
    /// the device's own confirm screen.
    async fn with_signer_locked<T, F, Fut>(
        guard: tokio::sync::MutexGuard<'static, ()>,
        f: F,
    ) -> Result<T, String>
    where
        T: Send + 'static,
        F: FnOnce(TrezorSigner) -> Fut + Send + 'static,
        Fut: std::future::Future<Output = Result<T, String>>,
    {
        let handle = tokio::runtime::Handle::current();
        tokio::task::spawn_blocking(move || {
            let _guard = guard;
            handle.block_on(async move {
                let signer = TrezorSigner::new(HDPath::TrezorLive(0), Some(CHAIN_ID))
                    .await
                    .map_err(friendly)?;
                f(signer).await
            })
        })
        .await
        .map_err(|e| format!("Trezor task failed: {e}"))?
    }

    /// [with_signer_locked] behind a plain wait on the conversation lock.
    async fn with_signer<T, F, Fut>(f: F) -> Result<T, String>
    where
        T: Send + 'static,
        F: FnOnce(TrezorSigner) -> Fut + Send + 'static,
        Fut: std::future::Future<Output = Result<T, String>>,
    {
        with_signer_locked(DEVICE_LOCK.lock().await, f).await
    }

    fn signer_address(s: &TrezorSigner) -> String {
        // EIP-55 checksummed via alloy's Address Display. Fully qualified:
        // TrezorSigner carries both Signer::address and TxSigner::address.
        alloy::signers::Signer::address(s).to_string()
    }

    /// The full signature (for recovery checks) plus the r‖s bytes the
    /// backup identity derives from.
    async fn sign_identity(
        s: &TrezorSigner,
    ) -> Result<(alloy::primitives::Signature, [u8; 64]), String> {
        use alloy::signers::Signer as _;
        let sig = s
            .sign_message(crate::backup::IDENTITY_MESSAGE_V1.as_bytes())
            .await
            .map_err(|e| friendly(format!("identity signing failed: {e}")))?;
        let mut rs = [0u8; 64];
        rs[..32].copy_from_slice(&sig.r().to_be_bytes::<32>());
        rs[32..].copy_from_slice(&sig.s().to_be_bytes::<32>());
        Ok((sig, rs))
    }

    /// Does a Trezor answer on USB? Returns its address at
    /// [DERIVATION_PATH] — silent on the device, nothing is signed.
    /// Never waits behind a running conversation: a ceremony or payment
    /// in flight answers "busy" instead (the Dart presence poll treats
    /// any error as "not found", which is the right door copy while the
    /// device is mid-ceremony anyway).
    pub async fn probe() -> Result<String, String> {
        let Ok(guard) = DEVICE_LOCK.try_lock() else {
            return Err(
                "the Trezor is busy with another W@tch request right now".into()
            );
        };
        with_signer_locked(guard, |s| async move { Ok(signer_address(&s)) }).await
    }

    /// Show the wallet address on the DEVICE's own screen and return what
    /// it displayed (one confirmation tap). This is the defense against a
    /// compromised host binding the wrong account at setup: the address
    /// the user verifies comes from the Trezor's screen, which no
    /// software on this computer can draw. Synchronous USB — callers are
    /// already on the blocking thread.
    fn show_address_on_device() -> Result<String, String> {
        let mut client = trezor_client::unique(false).map_err(friendly)?;
        client.init_device(None).map_err(friendly)?;
        let mut req = trezor_client::protos::EthereumGetAddress::new();
        req.address_n = super::derivation_path_vec();
        req.set_show_display(true);
        let resp = client
            .call(
                req,
                Box::new(|_, m: trezor_client::protos::EthereumAddress| {
                    Ok(m.address().to_string())
                }),
            )
            .map_err(friendly)?;
        trezor_client::client::handle_interaction(resp).map_err(friendly)
    }

    /// The one-time setup ceremony: resolve the address, sign the frozen
    /// identity message twice (the determinism guard), derive the backup
    /// identity, then SHOW THE ADDRESS ON THE DEVICE for the user to
    /// confirm against what the app displays (the compromised-host
    /// wrong-account defense). Three confirmations on the device; nothing
    /// is spent. Cancelling the address screen aborts the whole setup —
    /// nothing has been persisted yet.
    pub async fn setup_ceremony() -> Result<TrezorIdentity, String> {
        with_signer(|s| async move {
            let address = signer_address(&s);
            let ((first_sig, first), (_, second)) = {
                // One attention span for both identity taps: the app's
                // prompt explains the device asks twice (the determinism
                // guard) instead of flashing two separate popups.
                let _attention = super::attention::begin("sign-identity");
                (sign_identity(&s).await?, sign_identity(&s).await?)
            };
            // The signature must really come from the address the device
            // reports — every later check (backup pointer, payment
            // pre-tap address read) compares against this address, so a
            // device whose signatures recover elsewhere must be refused
            // BEFORE the marker is ever stored.
            if let Err(got) = identity_recovers_to(&first_sig, &address) {
                return Err(format!(
                    "the Trezor reports address {address} but its signature \
                     comes from {got} — refusing to set up. If the device \
                     uses a passphrase, make sure the same hidden wallet \
                     stays open for the whole setup; otherwise unplug it, \
                     plug it back in, and try again."
                ));
            }
            let keys = ceremony_keys(&first, &second)?;
            let shown = {
                let _attention = super::attention::begin("confirm-address");
                show_address_on_device()?
            };
            if shown.to_lowercase() != address.to_lowercase() {
                return Err(format!(
                    "the Trezor displayed a different address ({shown}) than \
                     it reported over USB ({address}) — refusing to continue"
                ));
            }
            Ok(TrezorIdentity { address, keys })
        })
        .await
    }

    /// Re-derive the full backup identity — write keys included — with
    /// ONE device confirmation: the per-backup tap of the settled
    /// paranoid policy. Refuses a device whose address differs from the
    /// configured one; the caller (signer.rs) additionally verifies the
    /// derived pointer against the stored one.
    pub async fn derive_write_keys(expected_address: &str) -> Result<BackupKeys, String> {
        let expected = expected_address.to_lowercase();
        with_signer(move |s| async move {
            let found = signer_address(&s);
            if found.to_lowercase() != expected {
                return Err(format!(
                    "this Trezor holds a different wallet ({found}) than the \
                     one configured — plug in the right device, or re-run the \
                     hardware-wallet setup"
                ));
            }
            let (sig, rs) = {
                let _attention = super::attention::begin("sign-identity");
                sign_identity(&s).await?
            };
            // Same guard as the ceremony: a signature that does not come
            // from the configured address means the device key and the
            // reported account disagree — name it instead of letting the
            // pointer check (or a payment) fail with less to go on.
            if let Err(got) = identity_recovers_to(&sig, &found) {
                return Err(format!(
                    "the Trezor reports address {found} but its signature \
                     comes from {got} — if the device uses a passphrase, \
                     open the same hidden wallet it was set up with; \
                     otherwise unplug it, plug it back in, and try again"
                ));
            }
            Ok(derive_keys_from_signature(&rs))
        })
        .await
    }

    /// The payment signer evmlib drives, bound to the configured address.
    ///
    /// Hardened after the first live backup failed with evmlib's
    /// "journaled transaction does not match this wallet, chain, or
    /// payment intent" (2026-10-11): with the same in-memory payment
    /// request at prepare and validate time, the only check that can
    /// fail there is signer RECOVERY — i.e. the device produced a
    /// signature that does not recover to the configured wallet. The
    /// old signer opened ONE USB session when the wallet was built and
    /// held it across the whole upload; between quoting (minutes on
    /// mainnet) and the tap the device can auto-lock or drop the
    /// session, and a re-initialized session on a passphrase-capable
    /// device can silently bind a different wallet state. So this
    /// signer:
    ///   1. opens a FRESH device session per signature, on a blocking
    ///      thread (the signing waits for a human);
    ///   2. re-checks the device address right before signing (silent
    ///      USB read — a swapped device/passphrase fails loudly with no
    ///      wasted tap);
    ///   3. VERIFIES the returned signature recovers to the configured
    ///      address before handing it to evmlib, retrying once on a
    ///      completely fresh session;
    ///   4. publishes `sign-payment` on the attention beacon while the
    ///      device waits for the tap.
    pub struct VerifiedTrezor {
        address: alloy::primitives::Address,
    }

    /// Build the payment signer: probes the device once (friendly
    /// "plug it in" errors surface before any encrypt/quote work) and
    /// refuses a device whose address is not the configured one.
    pub async fn verified_payment_signer(
        expected_address: &str,
    ) -> Result<VerifiedTrezor, String> {
        let expected = expected_address.to_lowercase();
        let address = with_signer(move |s| async move {
            let found = signer_address(&s);
            if found.to_lowercase() != expected {
                return Err(format!(
                    "this Trezor holds a different wallet ({found}) than the \
                     one configured"
                ));
            }
            Ok(alloy::signers::Signer::address(&s))
        })
        .await?;
        Ok(VerifiedTrezor { address })
    }

    impl VerifiedTrezor {
        /// One fresh-session signing round for the concrete EIP-1559
        /// transaction evmlib always builds. Runs entirely on a blocking
        /// thread; the address re-check is silent on the device.
        async fn sign_eip1559_once(
            &self,
            tx: alloy::consensus::TxEip1559,
        ) -> Result<alloy::primitives::Signature, String> {
            let expected = self.address.to_string().to_lowercase();
            with_signer(move |s| async move {
                let found = signer_address(&s);
                if found.to_lowercase() != expected {
                    return Err(format!(
                        "this Trezor holds a different wallet ({found}) than \
                         the one configured — if the device uses a \
                         passphrase, open the same hidden wallet it was set \
                         up with, then try again"
                    ));
                }
                let mut tx = tx;
                alloy::network::TxSigner::sign_transaction(&s, &mut tx)
                    .await
                    .map_err(|e| friendly(format!("payment signing failed: {e}")))
            })
            .await
        }

        async fn sign_verified(
            &self,
            tx: &mut dyn alloy::consensus::SignableTransaction<alloy::primitives::Signature>,
        ) -> Result<alloy::primitives::Signature, String> {
            // The hash the signature must verify against is the ORIGINAL
            // transaction's — computed before anything is cloned, so no
            // clone drift could ever slip past the check.
            let hash = tx.signature_hash();
            let _attention = super::attention::begin("sign-payment");
            // ALWAYS unwrap to the concrete TxEip1559 (see concrete_eip1559's
            // doc comment): handing the TypedTransaction enum down as a dyn
            // makes alloy-signer-trezor fall back to a LEGACY device request,
            // whose signature can never verify against the 1559 hash.
            let eip1559 = super::concrete_eip1559(tx);
            if eip1559.is_none() && tx.ty() != 0 {
                // Not 1559 in any shape and not legacy either: the driver
                // would mis-encode it as legacy and the device would sign
                // bytes that can never verify — refuse before wasting a tap.
                return Err(format!(
                    "this payment is a type-{} transaction, which the Trezor \
                     driver cannot sign faithfully — nothing was sent and \
                     nothing was spent; please copy this message into a bug \
                     report",
                    tx.ty()
                ));
            }
            let mut attempts: Vec<String> = Vec::new();
            for attempt in 0..2u8 {
                let sig = match &eip1559 {
                    Some(t) => self.sign_eip1559_once(t.clone()).await?,
                    None => {
                        // A true legacy tx: the generic path is correct here
                        // (the driver's legacy request matches the legacy
                        // EIP-155 hash). Sign inline on a fresh session.
                        let _guard = DEVICE_LOCK.lock().await;
                        let s = TrezorSigner::new(HDPath::TrezorLive(0), Some(CHAIN_ID))
                            .await
                            .map_err(friendly)?;
                        alloy::network::TxSigner::sign_transaction(&s, tx)
                            .await
                            .map_err(|e| friendly(format!("payment signing failed: {e}")))?
                    }
                };
                match super::verify_or_repair_payment_signature(&hash, &sig, self.address) {
                    Ok(good) => {
                        if good != sig {
                            tracing::warn!(
                                "Trezor payment signature arrived in a non-canonical \
                                 shape (parity/s) and was repaired — it recovers to \
                                 the configured wallet {} and is used as repaired",
                                self.address
                            );
                        }
                        return Ok(good);
                    }
                    Err(got) => {
                        // Everything a field report needs to pin where the
                        // chain breaks: the tx the hash covers, the hash,
                        // and the signature the device returned.
                        let tx_line = eip1559
                            .as_ref()
                            .map(|t| {
                                format!(
                                    "chain_id={} nonce={} to={:?} gas_limit={} \
                                     max_fee={} max_priority={} value={} data_len={}",
                                    t.chain_id,
                                    t.nonce,
                                    t.to,
                                    t.gas_limit,
                                    t.max_fee_per_gas,
                                    t.max_priority_fee_per_gas,
                                    t.value,
                                    t.input.len()
                                )
                            })
                            .unwrap_or_else(|| "legacy (non-eip1559)".into());
                        tracing::warn!(
                            "Trezor payment signature attempt {} recovered to {got}, \
                             expected {} — sighash={hash} r={:#x} s={:#x} parity={} \
                             tx: {tx_line}; retrying on a fresh device session",
                            attempt + 1,
                            self.address,
                            sig.r(),
                            sig.s(),
                            sig.v(),
                        );
                        attempts.push(got);
                    }
                }
            }
            // Both attempts failed. One more SILENT device read tells the
            // user (and us) which failure class this is: a device that now
            // reports a different wallet (passphrase/hidden-wallet drift)
            // vs one that still reports the right wallet while its
            // signatures recover elsewhere (device/transport fault).
            let now_reports = tokio::time::timeout(
                std::time::Duration::from_secs(10),
                with_signer(|s| async move { Ok(signer_address(&s)) }),
            )
            .await
            .ok()
            .and_then(|r| r.ok());
            let signed_as = if attempts.len() == 2 && attempts[0] == attempts[1] {
                format!("consistently signed as {}", attempts[0])
            } else {
                format!("signed as {}", attempts.join(", then "))
            };
            let diagnosis = match &now_reports {
                Some(z) if z.to_lowercase() != self.address.to_string().to_lowercase() => {
                    format!(
                        " The device is on a different wallet right now (it \
                         reports {z}): if it uses a passphrase, open the same \
                         hidden wallet it was set up with, then try again."
                    )
                }
                Some(_) => {
                    " The device still reports the right wallet, so this looks \
                     like a device or transport fault — unplug it, plug it \
                     back in, and try again; if it keeps happening, copy this \
                     message into a bug report."
                        .to_string()
                }
                None => {
                    " If the device uses a passphrase, open the same hidden \
                     wallet it was set up with; otherwise unplug it, plug it \
                     back in, and try again."
                        .to_string()
                }
            };
            Err(format!(
                "the Trezor's payment signature did not verify: the device \
                 {signed_as} but this wallet is {}.{diagnosis} Nothing was \
                 sent to the network and nothing was spent.",
                self.address
            ))
        }
    }

    #[async_trait::async_trait]
    impl alloy::network::TxSigner<alloy::primitives::Signature> for VerifiedTrezor {
        fn address(&self) -> alloy::primitives::Address {
            self.address
        }

        async fn sign_transaction(
            &self,
            tx: &mut dyn alloy::consensus::SignableTransaction<alloy::primitives::Signature>,
        ) -> alloy::signers::Result<alloy::primitives::Signature> {
            self.sign_verified(tx).await.map_err(alloy::signers::Error::other)
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos"))]
pub use device::*;

/// Non-desktop stubs: the Signer enum still parses a synced-over marker,
/// but no device conversation is possible.
#[cfg(not(any(target_os = "linux", target_os = "windows", target_os = "macos")))]
mod device_stub {
    use super::*;

    pub const UNSUPPORTED: &str = "hardware wallets work in the desktop app only";

    pub async fn probe() -> Result<String, String> {
        Err(UNSUPPORTED.into())
    }
    pub async fn setup_ceremony() -> Result<TrezorIdentity, String> {
        Err(UNSUPPORTED.into())
    }
    pub async fn derive_write_keys(_expected_address: &str) -> Result<BackupKeys, String> {
        Err(UNSUPPORTED.into())
    }
}

#[cfg(not(any(target_os = "linux", target_os = "windows", target_os = "macos")))]
pub use device_stub::*;

#[cfg(test)]
mod tests {
    use super::*;

    /// derivation_path_vec must stay the integer form of DERIVATION_PATH
    /// — parse the string exactly the way alloy-signer-trezor's
    /// convert_path does and compare, so the show-address call can never
    /// drift onto a different account than the signer.
    #[test]
    fn path_vec_matches_the_derivation_path_string() {
        let parsed: Vec<u32> = DERIVATION_PATH
            .split('/')
            .skip(1)
            .map(|e| {
                let hardened = e.contains('\'');
                let idx: u32 = e.replace('\'', "").parse().unwrap();
                if hardened { idx | 0x8000_0000 } else { idx }
            })
            .collect();
        assert_eq!(derivation_path_vec(), parsed);
    }

    /// Equal signatures derive exactly the signature-derived identity;
    /// the vectors behind derive_keys_from_signature are frozen in
    /// backup.rs, so pin equivalence rather than bytes here.
    #[test]
    fn ceremony_accepts_a_deterministic_signer() {
        const KEY: &str =
            "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
        let sig = crate::backup::identity_signature(KEY).unwrap();
        let keys = ceremony_keys(&sig, &sig).unwrap();
        let direct = crate::backup::derive_keys(KEY).unwrap();
        assert_eq!(keys.pointer, direct.pointer);
        assert_eq!(keys.enc, direct.enc);
    }

    /// The attention beacon: begin publishes, drop clears, and an OLDER
    /// guard's drop never erases a NEWER action out from under the
    /// poller. (The only test touching the process-global state.)
    #[test]
    fn attention_tracks_and_clears_actions() {
        let (active, _, _) = attention::snapshot();
        assert!(!active, "nothing should be active before the test begins");
        let first = attention::begin("sign-payment");
        let (active, seq1, action) = attention::snapshot();
        assert!(active);
        assert_eq!(action, Some("sign-payment"));
        let second = attention::begin("confirm-address");
        let (active, seq2, action) = attention::snapshot();
        assert!(active);
        assert!(seq2 > seq1, "every action gets a fresh seq");
        assert_eq!(action, Some("confirm-address"));
        drop(first);
        let (active, _, action) = attention::snapshot();
        assert!(active, "the stale guard must not clear the newer action");
        assert_eq!(action, Some("confirm-address"));
        drop(second);
        let (active, _, action) = attention::snapshot();
        assert!(!active);
        assert_eq!(action, None);
    }

    /// The local recovery check behind VerifiedTrezor: a signature from
    /// the right key verifies; the wrong expected wallet (or a
    /// parity-flipped signature — the classic conversion-bug shape) is
    /// refused with the RECOVERED address in the error, the diagnostic
    /// evmlib's "journaled transaction does not match" never gives.
    #[tokio::test]
    async fn payment_signature_verification_names_the_signing_wallet() {
        use alloy::consensus::{SignableTransaction, TxEip1559};
        use alloy::network::TxSigner;
        use alloy::signers::local::PrivateKeySigner;
        let signer: PrivateKeySigner =
            "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
                .parse()
                .unwrap();
        let mut tx = TxEip1559 {
            chain_id: 42161,
            nonce: 7,
            gas_limit: 100_000,
            max_fee_per_gas: 100_000_000,
            max_priority_fee_per_gas: 0,
            to: alloy::primitives::TxKind::Call(alloy::primitives::Address::repeat_byte(0x11)),
            value: alloy::primitives::U256::ZERO,
            access_list: Default::default(),
            input: alloy::primitives::Bytes::from_static(&[0xde, 0xad, 0xbe, 0xef]),
        };
        let hash = tx.signature_hash();
        let sig = TxSigner::sign_transaction(&signer, &mut tx).await.unwrap();
        verify_payment_signature(&hash, &sig, signer.address())
            .expect("the right wallet's signature must verify");
        let err = verify_payment_signature(
            &hash,
            &sig,
            alloy::primitives::Address::repeat_byte(0x22),
        )
        .expect_err("a different expected wallet must refuse");
        assert_eq!(
            err.to_lowercase(),
            signer.address().to_string().to_lowercase(),
            "the error names who really signed"
        );
        let flipped = alloy::primitives::Signature::new(sig.r(), sig.s(), !sig.v());
        assert!(
            verify_payment_signature(&hash, &flipped, signer.address()).is_err(),
            "a parity-flipped signature must never verify"
        );
    }

    /// The self-repair wrapper: a correct signature passes untouched, a
    /// parity-flipped one (the classic v-conversion bug shape) is
    /// repaired back to a signature that recovers to the expected
    /// wallet, a high-s sibling is normalized, and a signature from the
    /// WRONG key is still refused naming who really signed — repair can
    /// never accept a signature the expected wallet did not make.
    #[tokio::test]
    async fn payment_signature_repair_fixes_parity_and_s_but_never_the_key() {
        use alloy::consensus::{SignableTransaction, TxEip1559};
        use alloy::network::TxSigner;
        use alloy::signers::local::PrivateKeySigner;
        let signer: PrivateKeySigner =
            "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
                .parse()
                .unwrap();
        let mut tx = TxEip1559 {
            chain_id: 42161,
            nonce: 9,
            gas_limit: 90_000,
            max_fee_per_gas: 50_000_000,
            max_priority_fee_per_gas: 0,
            to: alloy::primitives::TxKind::Call(alloy::primitives::Address::repeat_byte(0x33)),
            value: alloy::primitives::U256::ZERO,
            access_list: Default::default(),
            input: alloy::primitives::Bytes::from_static(&[0x01, 0x02]),
        };
        let hash = tx.signature_hash();
        let sig = TxSigner::sign_transaction(&signer, &mut tx).await.unwrap();

        let good = verify_or_repair_payment_signature(&hash, &sig, signer.address())
            .expect("a correct signature must pass");
        assert_eq!(good, sig, "a correct signature is returned untouched");

        let flipped = alloy::primitives::Signature::new(sig.r(), sig.s(), !sig.v());
        let repaired = verify_or_repair_payment_signature(&hash, &flipped, signer.address())
            .expect("a parity-flipped signature must repair");
        assert_eq!(
            repaired.recover_address_from_prehash(&hash).unwrap(),
            signer.address(),
            "the repaired signature recovers to the expected wallet"
        );

        // The high-s sibling (r, N-s, !parity) signs the same message with
        // the same key in non-canonical form — repair must land on the
        // expected wallet whichever candidate gets there.
        let high_s = alloy::primitives::Signature::new(
            sig.r(),
            secp256k1_order() - sig.s(),
            !sig.v(),
        );
        let healed = verify_or_repair_payment_signature(&hash, &high_s, signer.address())
            .expect("a high-s sibling must repair");
        assert_eq!(
            healed.recover_address_from_prehash(&hash).unwrap(),
            signer.address()
        );

        let err = verify_or_repair_payment_signature(
            &hash,
            &sig,
            alloy::primitives::Address::repeat_byte(0x44),
        )
        .expect_err("the wrong expected wallet must still refuse");
        assert_eq!(
            err.to_lowercase(),
            signer.address().to_string().to_lowercase(),
            "the error names who really signed (the ORIGINAL recovery)"
        );
    }

    /// The ceremony's new key↔address guard: the identity signature must
    /// recover to the address the device reports — with the signature's
    /// own parity or flipped (v encodings vary) — and a mismatch names
    /// the address the key really belongs to.
    #[tokio::test]
    async fn identity_recovery_binds_the_signature_to_the_reported_address() {
        use alloy::signers::{local::PrivateKeySigner, Signer as _};
        let signer: PrivateKeySigner =
            "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
                .parse()
                .unwrap();
        let sig = signer
            .sign_message(crate::backup::IDENTITY_MESSAGE_V1.as_bytes())
            .await
            .unwrap();
        let addr = signer.address().to_string();
        identity_recovers_to(&sig, &addr).expect("the signer's own address matches");
        let flipped = alloy::primitives::Signature::new(sig.r(), sig.s(), !sig.v());
        identity_recovers_to(&flipped, &addr)
            .expect("a flipped-parity encoding of the same signature still matches");
        let other = format!("{}", alloy::primitives::Address::repeat_byte(0x55));
        let err = identity_recovers_to(&sig, &other)
            .expect_err("a different reported address must refuse");
        assert_eq!(err.to_lowercase(), addr.to_lowercase(), "names the real key");
    }

    /// Pin the conversion the live Trezor payment path rides:
    /// trezor-client turns a 1559 parity (0/1) into the EIP-155 form
    /// `v = parity + 2*chain_id + 35`, and alloy-signer-trezor
    /// normalize_v's it back — the round trip must preserve parity on
    /// Arbitrum One for BOTH parities, or every device signature with
    /// that parity would fail recovery.
    #[test]
    fn trezor_electrum_v_transform_preserves_parity_on_arbitrum() {
        const CHAIN_ID: u64 = 42161;
        for parity in [false, true] {
            let electrum = u64::from(parity) + 2 * CHAIN_ID + 35;
            let normalized = alloy::primitives::normalize_v(electrum)
                .expect("the EIP-155 form must normalize");
            assert_eq!(normalized, parity, "parity {parity} must survive");
        }
    }

    /// The 2026-10-11 live failure's regression pin: evmlib's payment
    /// path hands the signer alloy's `TypedTransaction` ENUM as the dyn
    /// tx (never the bare `TxEip1559`), and alloy-signer-trezor picks
    /// the device request by downcasting to the CONCRETE `TxEip1559` —
    /// a miss silently signs LEGACY and the signature can never recover
    /// over the 1559 hash. concrete_eip1559 must therefore (a) unwrap
    /// the enum to the exact inner tx, (b) still accept a bare concrete
    /// tx, (c) return None for legacy (whose generic path IS correct),
    /// and (d) the enum's signature_hash must equal the inner tx's, so
    /// a signature made over the extracted concrete tx verifies against
    /// the dyn caller's hash.
    #[test]
    fn concrete_eip1559_unwraps_the_wallet_fillers_typed_transaction() {
        use alloy::consensus::{SignableTransaction, TxEip1559, TypedTransaction};
        let tx = TxEip1559 {
            chain_id: 42161,
            nonce: 3,
            gas_limit: 120_000,
            max_fee_per_gas: 25_000_000,
            max_priority_fee_per_gas: 0,
            to: alloy::primitives::TxKind::Call(alloy::primitives::Address::repeat_byte(0x66)),
            value: alloy::primitives::U256::ZERO,
            access_list: Default::default(),
            input: alloy::primitives::Bytes::from_static(&[0xaa, 0xbb]),
        };
        let typed: TypedTransaction = tx.clone().into();

        // (a) the enum — the shape that actually reaches the signer live.
        let dyn_typed: &dyn SignableTransaction<alloy::primitives::Signature> = &typed;
        let extracted = concrete_eip1559(dyn_typed)
            .expect("the TypedTransaction enum must unwrap to its 1559 payload");
        assert_eq!(extracted, tx);

        // (d) hash identity: signing the extracted tx answers the dyn's hash.
        assert_eq!(dyn_typed.signature_hash(), tx.signature_hash());

        // (b) a bare concrete tx still extracts.
        let dyn_bare: &dyn SignableTransaction<alloy::primitives::Signature> = &tx;
        assert_eq!(concrete_eip1559(dyn_bare), Some(tx.clone()));

        // (c) a legacy tx yields None — its generic signing path is sound.
        let legacy: TypedTransaction = alloy::consensus::TxLegacy {
            chain_id: Some(42161),
            nonce: 3,
            gas_price: 25_000_000,
            gas_limit: 120_000,
            to: alloy::primitives::TxKind::Call(alloy::primitives::Address::repeat_byte(0x66)),
            value: alloy::primitives::U256::ZERO,
            input: alloy::primitives::Bytes::new(),
        }
        .into();
        let dyn_legacy: &dyn SignableTransaction<alloy::primitives::Signature> = &legacy;
        assert_eq!(concrete_eip1559(dyn_legacy), None);
        use alloy::consensus::Transaction as _;
        assert_eq!(dyn_legacy.ty(), 0);
    }

    /// The sign-twice guard: differing signatures must refuse BEFORE any
    /// derivation — a non-deterministic signer would mint an identity a
    /// fresh install could never re-derive.
    #[test]
    fn ceremony_refuses_a_nondeterministic_signer() {
        let a = [1u8; 64];
        let mut b = a;
        b[63] ^= 1;
        let err = match ceremony_keys(&a, &b) {
            Err(e) => e,
            Ok(_) => panic!("nondeterministic signatures must refuse"),
        };
        assert!(err.contains("did not repeat"), "{err}");
    }
}
