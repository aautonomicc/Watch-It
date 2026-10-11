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

    /// Run one device conversation on a blocking thread. The closure gets
    /// a freshly connected signer; everything it awaits is synchronous
    /// USB underneath, plus however long the user takes at the device's
    /// own confirm screen.
    async fn with_signer<T, F, Fut>(f: F) -> Result<T, String>
    where
        T: Send + 'static,
        F: FnOnce(TrezorSigner) -> Fut + Send + 'static,
        Fut: std::future::Future<Output = Result<T, String>>,
    {
        let handle = tokio::runtime::Handle::current();
        tokio::task::spawn_blocking(move || {
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

    fn signer_address(s: &TrezorSigner) -> String {
        // EIP-55 checksummed via alloy's Address Display. Fully qualified:
        // TrezorSigner carries both Signer::address and TxSigner::address.
        alloy::signers::Signer::address(s).to_string()
    }

    async fn sign_identity(s: &TrezorSigner) -> Result<[u8; 64], String> {
        use alloy::signers::Signer as _;
        let sig = s
            .sign_message(crate::backup::IDENTITY_MESSAGE_V1.as_bytes())
            .await
            .map_err(|e| friendly(format!("identity signing failed: {e}")))?;
        let mut rs = [0u8; 64];
        rs[..32].copy_from_slice(&sig.r().to_be_bytes::<32>());
        rs[32..].copy_from_slice(&sig.s().to_be_bytes::<32>());
        Ok(rs)
    }

    /// Does a Trezor answer on USB? Returns its address at
    /// [DERIVATION_PATH] — silent on the device, nothing is signed.
    pub async fn probe() -> Result<String, String> {
        with_signer(|s| async move { Ok(signer_address(&s)) }).await
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
            let (first, second) = {
                // One attention span for both identity taps: the app's
                // prompt explains the device asks twice (the determinism
                // guard) instead of flashing two separate popups.
                let _attention = super::attention::begin("sign-identity");
                (sign_identity(&s).await?, sign_identity(&s).await?)
            };
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
            let sig = {
                let _attention = super::attention::begin("sign-identity");
                sign_identity(&s).await?
            };
            Ok(derive_keys_from_signature(&sig))
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
            let eip1559 = (tx as &dyn std::any::Any)
                .downcast_ref::<alloy::consensus::TxEip1559>()
                .cloned();
            let mut signed_as = String::new();
            for attempt in 0..2u8 {
                let sig = match &eip1559 {
                    Some(t) => self.sign_eip1559_once(t.clone()).await?,
                    None => {
                        // Not a 1559 tx (never the case on evmlib's payment
                        // path): sign inline on a fresh session.
                        let s = TrezorSigner::new(HDPath::TrezorLive(0), Some(CHAIN_ID))
                            .await
                            .map_err(friendly)?;
                        alloy::network::TxSigner::sign_transaction(&s, tx)
                            .await
                            .map_err(|e| friendly(format!("payment signing failed: {e}")))?
                    }
                };
                match super::verify_payment_signature(&hash, &sig, self.address) {
                    Ok(()) => return Ok(sig),
                    Err(got) => {
                        tracing::warn!(
                            "Trezor payment signature attempt {} recovered to {got}, \
                             expected {} — retrying on a fresh device session",
                            attempt + 1,
                            self.address
                        );
                        signed_as = got;
                    }
                }
            }
            Err(format!(
                "the Trezor's payment signature did not verify: the device \
                 signed as {signed_as} but this wallet is {} — if the device \
                 uses a passphrase, open the same hidden wallet it was set up \
                 with; otherwise unplug it, plug it back in, and try again. \
                 Nothing was sent to the network and nothing was spent.",
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
