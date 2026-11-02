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
    /// `sign-identity`, `confirm-address`, `sign-payment`,
    /// `unlock-wallet` (the per-job session open, where a
    /// passphrase-protected device asks for its passphrase once).
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

/// Host-side Trezor passphrase entry (opt-in; device entry is the
/// default and the more secure path).
///
/// A BIP-39 passphrase (the "25th word" / hidden-wallet secret) is
/// normally typed on the Trezor's own screen, so it never touches this
/// computer. On a Model One (no touchscreen) that is awkward, and some
/// users simply prefer typing it in the app — so W@tch can, WHEN TURNED
/// ON, answer the device's passphrase request with a string the app
/// collects instead of telling the device to ask on-screen. This is
/// strictly LESS secure (the passphrase lives in app memory and crosses
/// USB), so it is OFF by default and the firmware's
/// "always enter on device" setting overrides it.
///
/// The toggle is a process-global flag the app sets at startup from its
/// stored preference (and whenever the user flips it); every device
/// conversation reads it when the device asks for a passphrase.
pub mod host_passphrase {
    use std::sync::atomic::{AtomicBool, Ordering};

    static ENABLED: AtomicBool = AtomicBool::new(false);

    /// Turn host-side passphrase entry on or off (the app's preference).
    pub fn set(on: bool) {
        ENABLED.store(on, Ordering::Relaxed);
    }

    /// Is host-side passphrase entry currently enabled?
    pub fn enabled() -> bool {
        ENABLED.load(Ordering::Relaxed)
    }
}

/// The channel a blocked device conversation waits on for the passphrase
/// the app collects — and the routes the app POSTs it through.
///
/// When a device conversation (on its own blocking thread) receives a
/// passphrase request and host entry is enabled, it publishes the
/// `enter-passphrase` attention action and BLOCKS here until the app
/// delivers a passphrase (or says "enter it on the device instead", or a
/// 3-minute timeout lapses). Device conversations serialize on
/// `DEVICE_LOCK`, so at most one request is ever pending.
///
/// Lives outside the desktop-only module so the delivery route compiles
/// on every target; off-desktop nothing ever waits, so delivery is a
/// no-op that reports "no one was waiting".
pub mod passphrase {
    use std::sync::mpsc;
    use std::sync::Mutex;
    use std::time::Duration;
    use zeroize::Zeroizing;

    /// How a waiting conversation is answered.
    pub enum Reply {
        /// The app collected this passphrase — send it to the device.
        Host(Zeroizing<String>),
        /// The user chose to enter it on the device instead.
        OnDevice,
        /// Cancelled or timed out — abort the conversation.
        Cancelled,
    }

    static PENDING: Mutex<Option<mpsc::Sender<Reply>>> = Mutex::new(None);

    /// Generous: a human finding and typing a passphrase, well past any
    /// reasonable entry time; on timeout the conversation aborts cleanly.
    const TIMEOUT: Duration = Duration::from_secs(180);

    /// Called from the SYNC device thread: publish `enter-passphrase`,
    /// block until the app answers (or the timeout lapses). The attention
    /// guard is held for the whole wait so the app's card stays up.
    pub fn request() -> Reply {
        let (tx, rx) = mpsc::channel();
        *PENDING.lock().unwrap_or_else(|p| p.into_inner()) = Some(tx);
        let _attention = super::attention::begin("enter-passphrase");
        let reply = rx.recv_timeout(TIMEOUT).unwrap_or(Reply::Cancelled);
        // Clear the slot (idempotent — deliver() already took the sender
        // on a real answer; a timeout leaves it to drop here).
        *PENDING.lock().unwrap_or_else(|p| p.into_inner()) = None;
        reply
    }

    /// From the async route: hand the app's passphrase to the waiter.
    /// Returns whether anyone was actually waiting.
    pub fn deliver(pass: String) -> bool {
        send(Reply::Host(Zeroizing::new(pass)))
    }

    /// From the async route: the user chose on-device entry.
    pub fn use_device() -> bool {
        send(Reply::OnDevice)
    }

    /// Whether a conversation is waiting for a passphrase right now
    /// (test seam; the app reads the `enter-passphrase` attention action
    /// instead).
    pub fn pending() -> bool {
        PENDING
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .is_some()
    }

    fn send(reply: Reply) -> bool {
        let tx = PENDING.lock().unwrap_or_else(|p| p.into_inner()).take();
        match tx {
            Some(tx) => tx.send(reply).is_ok(),
            None => false,
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

/// The owned legacy transaction behind a dyn shape — [concrete_eip1559]'s
/// mirror for true legacy transactions. The trezor driver's generic path
/// encodes a legacy request correctly (its legacy hash matches), but the
/// signature-memoization path needs an OWNED transaction to carry into
/// the detached signing task, so the enum/bare shapes are unwrapped here
/// the same way.
pub fn concrete_legacy(
    tx: &dyn alloy::consensus::SignableTransaction<alloy::primitives::Signature>,
) -> Option<alloy::consensus::TxLegacy> {
    let any = tx as &dyn std::any::Any;
    if let Some(t) = any.downcast_ref::<alloy::consensus::TxLegacy>() {
        return Some(t.clone());
    }
    any.downcast_ref::<alloy::consensus::TypedTransaction>()
        .and_then(|t| t.legacy().cloned())
}

/// Signature memoization keyed by the transaction's signature hash.
///
/// Why this exists: evmlib 0.10.0 wraps `provider.send_transaction` in a
/// hardcoded 5-second broadcast timeout, and with alloy's wallet-filler
/// provider that call INCLUDES SIGNING — for a hardware wallet that is a
/// human passphrase entry plus a physical tap, impossible in 5s by
/// construction. The dropped future used to discard the eventually-
/// completed signature, so every evmlib retry opened a brand-new device
/// conversation (another prompt), and a payment only succeeded when one
/// attempt's tap squeaked under the window (the 2026-10-12 live "15
/// passphrase entries per backup" report).
///
/// The fix, with no evmlib fork: the device conversation runs as a
/// DETACHED task — a caller dropped at the timeout never cancels it —
/// and the locally VERIFIED signature lands here keyed by sighash.
/// evmlib's retry rebuilds the same transaction (same pending nonce;
/// fees are re-queried but near-constant on Arbitrum), so its sign
/// request joins the still-waiting conversation or hits the completed
/// cache and returns in milliseconds — well inside the 5s window — and
/// the broadcast proceeds. Fee drift between attempts changes the
/// sighash and simply costs one more confirmation (safe fallback).
///
/// Errors are delivered to whoever is waiting but never cached: a
/// cancelled tap or a transport fault must not poison the next attempt.
pub mod sigcache {
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    use alloy::primitives::{Signature, B256};
    use tokio::sync::watch;

    /// Completed signatures stay reusable this long — generously past
    /// evmlib's whole retry ladder (~1 min), and a signature over a
    /// given sighash never stops being valid, so the horizon only
    /// bounds memory.
    const TTL: Duration = Duration::from_secs(15 * 60);

    type Slot = watch::Receiver<Option<Result<Signature, String>>>;

    struct Entry {
        created: Instant,
        slot: Slot,
    }

    /// One cache per signer object (evmlib wallets hold their signer for
    /// as long as the wallet lives, so the cache spans a whole retry
    /// ladder by construction).
    pub struct SigCache {
        entries: Arc<Mutex<HashMap<B256, Entry>>>,
    }

    impl SigCache {
        pub fn new() -> Self {
            Self {
                entries: Arc::new(Mutex::new(HashMap::new())),
            }
        }

        /// The signature for `hash`: served from the completed cache,
        /// joined onto a conversation already in flight, or produced by
        /// `sign` spawned as a detached task (so it survives this caller
        /// being dropped at a timeout).
        pub async fn get_or_sign<F, Fut>(
            &self,
            hash: B256,
            sign: F,
        ) -> Result<Signature, String>
        where
            F: FnOnce() -> Fut,
            Fut: std::future::Future<Output = Result<Signature, String>> + Send + 'static,
        {
            let mut slot = {
                let mut map = self.entries.lock().unwrap_or_else(|p| p.into_inner());
                // Prune stale COMPLETED entries; in-flight ones stay put —
                // a second concurrent device conversation for the same tx
                // would be strictly worse than a long-lived entry.
                map.retain(|_, e| {
                    e.created.elapsed() < TTL || e.slot.borrow().is_none()
                });
                if let Some(e) = map.get(&hash) {
                    tracing::info!(
                        "payment signature request for sighash {hash} joins the \
                         signing cache (an earlier conversation covers it)"
                    );
                    e.slot.clone()
                } else {
                    let (tx, rx) = watch::channel(None);
                    map.insert(
                        hash,
                        Entry {
                            created: Instant::now(),
                            slot: rx.clone(),
                        },
                    );
                    let entries = Arc::clone(&self.entries);
                    let fut = sign();
                    tokio::spawn(async move {
                        let result = fut.await;
                        if result.is_err() {
                            // Never cache a failure — the next attempt
                            // deserves a fresh conversation.
                            entries
                                .lock()
                                .unwrap_or_else(|p| p.into_inner())
                                .remove(&hash);
                        }
                        let _ = tx.send(Some(result));
                    });
                    rx
                }
            };
            let value = {
                let guard = slot
                    .wait_for(|v| v.is_some())
                    .await
                    .map_err(|_| "the signing task ended without a result".to_string())?;
                guard.clone()
            };
            value.expect("wait_for guarantees Some")
        }
    }
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
    use alloy::consensus::{TxEip1559, TxLegacy};
    use alloy::primitives::{normalize_v, Address, Signature, TxKind, U256};
    use trezor_client::{protos, TrezorResponse};

    /// Minimum firmware that signs EIP-1559 (what every W@tch payment is)
    /// — the check alloy-signer-trezor used to run, kept now that we own
    /// the signer. Older majors we don't know about are assumed capable.
    fn firmware_ok(major: u64, minor: u64, patch: u64) -> bool {
        let min = match major {
            1 => (1, 11, 1),
            2 => (2, 5, 1),
            _ => return true,
        };
        (major, minor, patch) >= min
    }

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

    /// The one device session a whole JOB (backup, batch upload, single
    /// upload) signs through. Trezor caches its passphrase PER SESSION,
    /// so opening ONE session up front means one passphrase entry
    /// (on-device, or in the app when host entry is enabled) covers the
    /// identity derive and every payment signature of the job.
    static JOB_SESSION: std::sync::Mutex<Option<std::sync::Arc<OwnTrezorSigner>>> =
        std::sync::Mutex::new(None);

    /// Guard handed to the job that opened the session; dropping it (job
    /// end, success or failure) closes the reuse window. A newer session
    /// is never clobbered by an older guard's drop.
    pub struct TrezorJobSession {
        signer: std::sync::Arc<OwnTrezorSigner>,
    }

    impl Drop for TrezorJobSession {
        fn drop(&mut self) {
            let mut slot = JOB_SESSION.lock().unwrap_or_else(|p| p.into_inner());
            if slot
                .as_ref()
                .is_some_and(|s| std::sync::Arc::ptr_eq(s, &self.signer))
            {
                *slot = None;
            }
        }
    }

    /// Our own Trezor Ethereum signer over trezor-client — direct USB, no
    /// Trezor Bridge, and no alloy-signer-trezor.
    ///
    /// Owning the transport buys three things the alloy wrapper could
    /// not give us:
    ///   1. HOST-SIDE PASSPHRASE ENTRY (opt-in): alloy-signer-trezor's
    ///      interaction loop hard-codes `ack(on_device)`, so the device
    ///      always prompts on its own screen. Our [`drive`] loop answers
    ///      a passphrase request with a string the app collects when
    ///      [`super::host_passphrase::enabled`] is on and the firmware
    ///      permits it (`passphrase_always_on_device` wins);
    ///   2. a RESUMABLE SESSION: we read the device session id at connect
    ///      and reopen with it, so one passphrase entry covers the whole
    ///      job (alloy-signer-trezor's session id was private — the old
    ///      fresh-session-per-signature workaround re-prompted);
    ///   3. the LEGACY-ENUM BUG GONE BY CONSTRUCTION: we always build the
    ///      concrete EIP-1559 (or legacy) device request from the owned
    ///      transaction, so the alpha.118 downcast-miss-signs-legacy
    ///      failure class cannot recur (the recovery-verify in
    ///      [`VerifiedTrezor`] stays as the backstop regardless).
    pub struct OwnTrezorSigner {
        session_id: Vec<u8>,
        path: Vec<u32>,
        address: Address,
        /// Host-side passphrase entry snapshotted at connect; the
        /// firmware's "always on device" forces device entry regardless.
        host_passphrase: bool,
        always_on_device: bool,
    }

    /// Drive one device response to completion, handling the button /
    /// PIN / passphrase interactions. This is trezor-client's own
    /// `handle_interaction`, except the passphrase arm can answer with a
    /// host-collected string.
    fn drive<T, R: trezor_client::TrezorMessage>(
        resp: TrezorResponse<'_, T, R>,
        host: bool,
        always_on_device: bool,
    ) -> Result<T, String> {
        match resp {
            TrezorResponse::Ok(value) => Ok(value),
            TrezorResponse::Failure(f) => Err(friendly(format!(
                "the Trezor reported: {}",
                f.message()
            ))),
            TrezorResponse::ButtonRequest(req) => {
                drive(req.ack().map_err(friendly)?, host, always_on_device)
            }
            TrezorResponse::PinMatrixRequest(_) => Err(
                "the Trezor is asking for its PIN to be typed on this computer, \
                 which W@tch does not support — unlock the device itself, then \
                 try again"
                    .into(),
            ),
            TrezorResponse::PassphraseRequest(req) => {
                // Host entry only when the user turned it on AND the
                // firmware allows it; otherwise exactly the old
                // behaviour (let the user enter it on the device).
                if host && !always_on_device {
                    match super::passphrase::request() {
                        super::passphrase::Reply::Host(p) => drive(
                            req.ack_passphrase((*p).clone()).map_err(friendly)?,
                            host,
                            always_on_device,
                        ),
                        super::passphrase::Reply::OnDevice => {
                            let on_device = req.on_device();
                            drive(req.ack(!on_device).map_err(friendly)?, host, always_on_device)
                        }
                        super::passphrase::Reply::Cancelled => Err(
                            "passphrase entry was cancelled — nothing was changed"
                                .into(),
                        ),
                    }
                } else {
                    let on_device = req.on_device();
                    drive(req.ack(!on_device).map_err(friendly)?, host, always_on_device)
                }
            }
        }
    }

    /// Open a fresh USB handle resumed onto this signer's session (so a
    /// passphrase already entered this session is not re-prompted).
    fn open_session(session_id: &[u8]) -> Result<trezor_client::Trezor, String> {
        let mut client = trezor_client::unique(false).map_err(friendly)?;
        client
            .init_device(Some(session_id.to_vec()))
            .map_err(friendly)?;
        Ok(client)
    }

    /// EIP-55 address string → `Address`.
    fn parse_address(s: &str) -> Result<Address, String> {
        s.parse()
            .map_err(|_| format!("the Trezor returned an unparseable address ({s})"))
    }

    fn eth_get_address(
        client: &mut trezor_client::Trezor,
        path: &[u32],
        host: bool,
        always: bool,
    ) -> Result<String, String> {
        let mut req = protos::EthereumGetAddress::new();
        req.address_n = path.to_vec();
        let resp = client
            .call(
                req,
                Box::new(|_, m: protos::EthereumAddress| Ok(m.address().to_string())),
            )
            .map_err(friendly)?;
        drive(resp, host, always)
    }

    fn eth_sign_message(
        client: &mut trezor_client::Trezor,
        path: &[u32],
        message: &[u8],
        host: bool,
        always: bool,
    ) -> Result<Signature, String> {
        let mut req = protos::EthereumSignMessage::new();
        req.address_n = path.to_vec();
        req.set_message(message.to_vec());
        let resp = client
            .call(
                req,
                Box::new(|_, m: protos::EthereumMessageSignature| {
                    let sig = m.signature();
                    if sig.len() != 65 {
                        return Err(trezor_client::Error::MalformedSignature);
                    }
                    Ok(TrezorSig {
                        r: sig[0..32].try_into().unwrap(),
                        s: sig[32..64].try_into().unwrap(),
                        v: sig[64] as u64,
                    })
                }),
            )
            .map_err(friendly)?;
        let ts = drive(resp, host, always)?;
        to_alloy_sig(ts)
    }

    /// The raw (r, s, v) a Trezor returns — v in "Electrum" form for
    /// transactions, raw 0/1/27/28 for messages. `normalize_v` lands
    /// both on a parity.
    struct TrezorSig {
        r: [u8; 32],
        s: [u8; 32],
        v: u64,
    }

    fn to_alloy_sig(ts: TrezorSig) -> Result<Signature, String> {
        let r = U256::from_be_bytes(ts.r);
        let s = U256::from_be_bytes(ts.s);
        let parity = normalize_v(ts.v)
            .ok_or_else(|| format!("the Trezor returned an invalid signature parity ({})", ts.v))?;
        Ok(Signature::new(r, s, parity))
    }

    // Big-endian, leading-zero-trimmed encodings the Trezor wire wants
    // (mirrors alloy-signer-trezor's helpers exactly).
    fn u64_to_trezor(x: u64) -> Vec<u8> {
        x.to_be_bytes()[x.leading_zeros() as usize / 8..].to_vec()
    }
    fn u128_to_trezor(x: u128) -> Vec<u8> {
        x.to_be_bytes()[x.leading_zeros() as usize / 8..].to_vec()
    }
    fn u256_to_trezor(x: U256) -> Vec<u8> {
        x.to_be_bytes::<32>()[x.leading_zeros() / 8..].to_vec()
    }
    fn to_string_of(kind: &TxKind) -> String {
        match kind {
            TxKind::Call(to) => format!("{to:?}"),
            TxKind::Create => String::new(),
        }
    }

    /// trezor-client's `convert_signature`: a 1559/legacy response's
    /// `signature_v` is wrapped to EIP-155 form when a chain id is set,
    /// which `to_alloy_sig`'s `normalize_v` then un-wraps back to parity
    /// (the round trip pinned by `trezor_electrum_v_transform_*`).
    fn convert_tx_signature(
        resp: &protos::EthereumTxRequest,
        chain_id: Option<u64>,
    ) -> Result<TrezorSig, String> {
        let mut v = resp.signature_v() as u64;
        if let Some(chain_id) = chain_id {
            if v <= 1 {
                v = v + 2 * chain_id + 35;
            }
        }
        let r: [u8; 32] = resp
            .signature_r()
            .try_into()
            .map_err(|_| "the Trezor returned a malformed signature".to_string())?;
        let s: [u8; 32] = resp
            .signature_s()
            .try_into()
            .map_err(|_| "the Trezor returned a malformed signature".to_string())?;
        Ok(TrezorSig { r, s, v })
    }

    fn eth_sign_eip1559(
        client: &mut trezor_client::Trezor,
        path: &[u32],
        tx: &TxEip1559,
        host: bool,
        always: bool,
    ) -> Result<Signature, String> {
        let mut data = tx.input.to_vec();
        let mut req = protos::EthereumSignTxEIP1559::new();
        req.address_n = path.to_vec();
        req.set_nonce(u64_to_trezor(tx.nonce));
        req.set_max_gas_fee(u128_to_trezor(tx.max_fee_per_gas));
        req.set_max_priority_fee(u128_to_trezor(tx.max_priority_fee_per_gas));
        req.set_gas_limit(u64_to_trezor(tx.gas_limit));
        req.set_value(u256_to_trezor(tx.value));
        req.set_chain_id(tx.chain_id);
        req.set_to(to_string_of(&tx.to));
        if !tx.access_list.0.is_empty() {
            req.access_list = tx
                .access_list
                .0
                .iter()
                .map(|item| protos::ethereum_sign_tx_eip1559::EthereumAccessList {
                    address: Some(format!("{:?}", item.address)),
                    storage_keys: item.storage_keys.iter().map(|k| k.to_vec()).collect(),
                    ..Default::default()
                })
                .collect();
        }
        req.set_data_length(data.len() as u32);
        req.set_data_initial_chunk(
            data.splice(..std::cmp::min(1024, data.len()), []).collect(),
        );
        let resp = client
            .call(req, Box::new(|_, m: protos::EthereumTxRequest| Ok(m)))
            .map_err(friendly)?;
        let mut resp = drive(resp, host, always)?;
        while resp.data_length() > 0 {
            let mut ack = protos::EthereumTxAck::new();
            ack.set_data_chunk(data.splice(..std::cmp::min(1024, data.len()), []).collect());
            resp = client
                .call(ack, Box::new(|_, m: protos::EthereumTxRequest| Ok(m)))
                .map_err(friendly)?
                .ok()
                .map_err(friendly)?;
        }
        to_alloy_sig(convert_tx_signature(&resp, Some(tx.chain_id))?)
    }

    fn eth_sign_legacy(
        client: &mut trezor_client::Trezor,
        path: &[u32],
        tx: &TxLegacy,
        host: bool,
        always: bool,
    ) -> Result<Signature, String> {
        let mut data = tx.input.to_vec();
        let mut req = protos::EthereumSignTx::new();
        req.address_n = path.to_vec();
        req.set_nonce(u64_to_trezor(tx.nonce));
        req.set_gas_price(u128_to_trezor(tx.gas_price));
        req.set_gas_limit(u64_to_trezor(tx.gas_limit));
        req.set_value(u256_to_trezor(tx.value));
        if let Some(chain_id) = tx.chain_id {
            req.set_chain_id(chain_id);
        }
        req.set_to(to_string_of(&tx.to));
        req.set_data_length(data.len() as u32);
        req.set_data_initial_chunk(
            data.splice(..std::cmp::min(1024, data.len()), []).collect(),
        );
        let resp = client
            .call(req, Box::new(|_, m: protos::EthereumTxRequest| Ok(m)))
            .map_err(friendly)?;
        let mut resp = drive(resp, host, always)?;
        while resp.data_length() > 0 {
            let mut ack = protos::EthereumTxAck::new();
            ack.set_data_chunk(data.splice(..std::cmp::min(1024, data.len()), []).collect());
            resp = client
                .call(ack, Box::new(|_, m: protos::EthereumTxRequest| Ok(m)))
                .map_err(friendly)?
                .ok()
                .map_err(friendly)?;
        }
        to_alloy_sig(convert_tx_signature(&resp, tx.chain_id)?)
    }

    /// Show the wallet address on the DEVICE's own screen (one tap) and
    /// return what it displayed — the compromised-host wrong-account
    /// defense at setup. Driven through our interaction loop so a
    /// passphrase prompt here is handled the same way.
    fn eth_show_address(
        client: &mut trezor_client::Trezor,
        path: &[u32],
        host: bool,
        always: bool,
    ) -> Result<String, String> {
        let mut req = protos::EthereumGetAddress::new();
        req.address_n = path.to_vec();
        req.set_show_display(true);
        let resp = client
            .call(
                req,
                Box::new(|_, m: protos::EthereumAddress| Ok(m.address().to_string())),
            )
            .map_err(friendly)?;
        drive(resp, host, always)
    }

    impl OwnTrezorSigner {
        /// Open a brand-new device session (reads the session id and
        /// resolves the address — the first operation, where a
        /// passphrase-protected device asks for its passphrase once). The
        /// host-passphrase preference is snapshotted here for the whole
        /// signer.
        fn connect() -> Result<Self, String> {
            let host = super::host_passphrase::enabled();
            let path = super::derivation_path_vec();
            let mut client = trezor_client::unique(false).map_err(friendly)?;
            client.init_device(None).map_err(friendly)?;
            let features = client
                .features()
                .ok_or_else(|| "could not read the Trezor's features".to_string())?;
            if !firmware_ok(
                features.major_version() as u64,
                features.minor_version() as u64,
                features.patch_version() as u64,
            ) {
                return Err(
                    "this Trezor's firmware is too old to sign the network's \
                     payment transactions — update it in Trezor Suite, then \
                     try again"
                        .into(),
                );
            }
            let session_id = features.session_id().to_vec();
            let always_on_device = features.passphrase_always_on_device();
            let address_str = eth_get_address(&mut client, &path, host, always_on_device)?;
            let address = parse_address(&address_str)?;
            Ok(Self {
                session_id,
                path,
                address,
                host_passphrase: host,
                always_on_device,
            })
        }

        fn address(&self) -> Address {
            self.address
        }

        /// A real USB round trip for the current address — never a cached
        /// value, so a session that silently degraded (stale id after a
        /// replug → the device minted a fresh session, maybe on a
        /// different hidden wallet) is caught before any tap is wasted.
        fn get_address(&self) -> Result<String, String> {
            let mut client = open_session(&self.session_id)?;
            eth_get_address(&mut client, &self.path, self.host_passphrase, self.always_on_device)
        }

        fn sign_message(&self, message: &[u8]) -> Result<Signature, String> {
            let mut client = open_session(&self.session_id)?;
            eth_sign_message(
                &mut client,
                &self.path,
                message,
                self.host_passphrase,
                self.always_on_device,
            )
        }

        fn sign_eip1559(&self, tx: &TxEip1559) -> Result<Signature, String> {
            let mut client = open_session(&self.session_id)?;
            eth_sign_eip1559(
                &mut client,
                &self.path,
                tx,
                self.host_passphrase,
                self.always_on_device,
            )
        }

        fn sign_legacy(&self, tx: &TxLegacy) -> Result<Signature, String> {
            let mut client = open_session(&self.session_id)?;
            eth_sign_legacy(
                &mut client,
                &self.path,
                tx,
                self.host_passphrase,
                self.always_on_device,
            )
        }

        fn show_address_on_device(&self) -> Result<String, String> {
            let mut client = open_session(&self.session_id)?;
            eth_show_address(&mut client, &self.path, self.host_passphrase, self.always_on_device)
        }
    }

    /// Open the job's one device session, BEFORE any ant-core work: the
    /// address read inside [`OwnTrezorSigner::connect`] is where a
    /// passphrase-protected device asks for its passphrase — once (on the
    /// device, or in the app when host entry is on), covering the
    /// identity derive and every payment signature of the whole job.
    /// Refuses a device whose address is not the configured one (and
    /// fails with the friendly "plug it in" message before any
    /// encrypt/quote work when no device answers).
    pub async fn begin_job_session(
        expected_address: &str,
    ) -> Result<TrezorJobSession, String> {
        let expected = expected_address.to_lowercase();
        let _attention = super::attention::begin("unlock-wallet");
        let signer = with_fresh_signer(move |s| async move {
            let found = signer_address(&s);
            if found.to_lowercase() != expected {
                return Err(format!(
                    "this Trezor holds a different wallet ({found}) than the \
                     one configured — if the device uses a passphrase, open \
                     the same hidden wallet it was set up with, then try again"
                ));
            }
            Ok(s)
        })
        .await?;
        *JOB_SESSION.lock().unwrap_or_else(|p| p.into_inner()) = Some(signer.clone());
        Ok(TrezorJobSession { signer })
    }

    /// Run one device conversation on a blocking thread, holding the
    /// already-acquired conversation lock for its whole duration. The
    /// closure gets the open job-session signer when `reuse_job_session`
    /// allows and one is open, else a freshly connected signer;
    /// everything it does is synchronous USB underneath, plus however
    /// long the user takes at the device's own confirm screen (or the
    /// app's passphrase field).
    async fn with_signer_locked<T, F, Fut>(
        guard: tokio::sync::MutexGuard<'static, ()>,
        reuse_job_session: bool,
        f: F,
    ) -> Result<T, String>
    where
        T: Send + 'static,
        F: FnOnce(std::sync::Arc<OwnTrezorSigner>) -> Fut + Send + 'static,
        Fut: std::future::Future<Output = Result<T, String>>,
    {
        let session = if reuse_job_session {
            JOB_SESSION.lock().unwrap_or_else(|p| p.into_inner()).clone()
        } else {
            None
        };
        let handle = tokio::runtime::Handle::current();
        tokio::task::spawn_blocking(move || {
            let _guard = guard;
            let signer = match session {
                Some(s) => s,
                None => std::sync::Arc::new(OwnTrezorSigner::connect()?),
            };
            handle.block_on(f(signer))
        })
        .await
        .map_err(|e| format!("Trezor task failed: {e}"))?
    }

    /// [with_signer_locked] behind a plain wait on the conversation lock,
    /// reusing the job session when one is open.
    async fn with_signer<T, F, Fut>(f: F) -> Result<T, String>
    where
        T: Send + 'static,
        F: FnOnce(std::sync::Arc<OwnTrezorSigner>) -> Fut + Send + 'static,
        Fut: std::future::Future<Output = Result<T, String>>,
    {
        with_signer_locked(DEVICE_LOCK.lock().await, true, f).await
    }

    /// [with_signer] forced onto a brand-new device session — the setup
    /// ceremony (a fresh binding by intent), the job-session open itself,
    /// and a signing retry that assumes the session went bad.
    async fn with_fresh_signer<T, F, Fut>(f: F) -> Result<T, String>
    where
        T: Send + 'static,
        F: FnOnce(std::sync::Arc<OwnTrezorSigner>) -> Fut + Send + 'static,
        Fut: std::future::Future<Output = Result<T, String>>,
    {
        with_signer_locked(DEVICE_LOCK.lock().await, false, f).await
    }

    /// The device's CURRENT address at the signer's path — a real USB
    /// round trip, never the construction-time cache.
    /// The device's CURRENT address at the signer's path — a real USB
    /// round trip, never the construction-time cache.
    async fn live_address(s: &OwnTrezorSigner) -> Result<String, String> {
        s.get_address()
    }

    fn signer_address(s: &OwnTrezorSigner) -> String {
        s.address().to_string()
    }

    /// The full signature (for recovery checks) plus the r‖s bytes the
    /// backup identity derives from.
    fn sign_identity(s: &OwnTrezorSigner) -> Result<(Signature, [u8; 64]), String> {
        let sig = s
            .sign_message(crate::backup::IDENTITY_MESSAGE_V1.as_bytes())
            .map_err(|e| friendly(format!("identity signing failed: {e}")))?;
        let mut rs = [0u8; 64];
        rs[..32].copy_from_slice(&sig.r().to_be_bytes::<32>());
        rs[32..].copy_from_slice(&sig.s().to_be_bytes::<32>());
        Ok((sig, rs))
    }

    /// Does a Trezor answer on USB? Returns its address at
    /// [DERIVATION_PATH] — silent on the device, nothing is signed.
    /// Never waits behind a running conversation: a ceremony or payment
    /// in flight answers "busy" instead.
    pub async fn probe() -> Result<String, String> {
        let Ok(guard) = DEVICE_LOCK.try_lock() else {
            return Err("the Trezor is busy with another W@tch request right now".into());
        };
        with_signer_locked(guard, true, |s| async move { live_address(&s).await }).await
    }

    /// The one-time setup ceremony: resolve the address, sign the frozen
    /// identity message twice (the determinism guard), derive the backup
    /// identity, then SHOW THE ADDRESS ON THE DEVICE for the user to
    /// confirm against what the app displays. Three confirmations on the
    /// device; nothing is spent. Cancelling the address screen aborts the
    /// whole setup — nothing has been persisted yet.
    pub async fn setup_ceremony() -> Result<TrezorIdentity, String> {
        with_fresh_signer(|s| async move {
            let address = signer_address(&s);
            let (first_sig, first) = {
                let _attention = super::attention::begin("sign-identity");
                let a = sign_identity(&s)?;
                let b = sign_identity(&s)?;
                // The determinism guard: a signer that does not repeat the
                // identity signature would mint a backup identity a fresh
                // install could never re-derive — refuse before deriving.
                ceremony_keys(&a.1, &b.1)?;
                (a.0, a.1)
            };
            if let Err(got) = identity_recovers_to(&first_sig, &address) {
                return Err(format!(
                    "the Trezor reports address {address} but its signature \
                     comes from {got} — refusing to set up. If the device \
                     uses a passphrase, make sure the same hidden wallet \
                     stays open for the whole setup; otherwise unplug it, \
                     plug it back in, and try again."
                ));
            }
            let keys = derive_keys_from_signature(&first);
            let shown = {
                let _attention = super::attention::begin("confirm-address");
                s.show_address_on_device()?
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
    /// ONE device confirmation. Refuses a device whose address differs
    /// from the configured one.
    pub async fn derive_write_keys(expected_address: &str) -> Result<BackupKeys, String> {
        let expected = expected_address.to_lowercase();
        with_signer(move |s| async move {
            let found = live_address(&s).await?;
            if found.to_lowercase() != expected {
                return Err(format!(
                    "this Trezor holds a different wallet ({found}) than the \
                     one configured — plug in the right device, or re-run the \
                     hardware-wallet setup"
                ));
            }
            let (sig, rs) = {
                let _attention = super::attention::begin("sign-identity");
                sign_identity(&s)?
            };
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
    /// The hardening across alpha.115–.118 stands (job session, LIVE
    /// pre-tap re-check, recovery-verify + repair, sighash memoization),
    /// now over our own signer so the device request is always the
    /// concrete EIP-1559/legacy transaction.
    pub struct VerifiedTrezor {
        address: Address,
        cache: super::sigcache::SigCache,
    }

    pub async fn verified_payment_signer(
        expected_address: &str,
    ) -> Result<VerifiedTrezor, String> {
        let expected = expected_address.to_lowercase();
        let address = with_signer(move |s| async move {
            let found = live_address(&s).await?;
            let parsed = parse_address(&found)?;
            if found.to_lowercase() != expected {
                return Err(format!(
                    "this Trezor holds a different wallet ({found}) than the \
                     one configured"
                ));
            }
            Ok(parsed)
        })
        .await?;
        Ok(VerifiedTrezor {
            address,
            cache: super::sigcache::SigCache::new(),
        })
    }

    /// The owned transaction a detached signing job carries.
    #[derive(Clone)]
    enum OwnedTx {
        Eip1559(TxEip1559),
        Legacy(TxLegacy),
    }

    /// One signing round on the device: job session unless `force_fresh`,
    /// LIVE address re-check, then the type-matched device request.
    async fn sign_tx_once(
        expected: Address,
        tx: OwnedTx,
        force_fresh: bool,
    ) -> Result<Signature, String> {
        let expected_lower = expected.to_string().to_lowercase();
        with_signer_locked(DEVICE_LOCK.lock().await, !force_fresh, move |s| async move {
            let found = live_address(&s).await?;
            if found.to_lowercase() != expected_lower {
                return Err(format!(
                    "this Trezor holds a different wallet ({found}) than \
                     the one configured — if the device uses a \
                     passphrase, open the same hidden wallet it was set \
                     up with, then try again"
                ));
            }
            match tx {
                OwnedTx::Eip1559(t) => s.sign_eip1559(&t),
                OwnedTx::Legacy(l) => s.sign_legacy(&l),
            }
        })
        .await
    }

    /// The whole device conversation for one payment, run DETACHED under
    /// [sigcache]: both attempts, local verification/repair, and the
    /// double-failure diagnosis.
    async fn sign_payment_job(
        address: Address,
        tx: OwnedTx,
        hash: alloy::primitives::B256,
    ) -> Result<Signature, String> {
        let _attention = super::attention::begin("sign-payment");
        let mut attempts: Vec<String> = Vec::new();
        for attempt in 0..2u8 {
            let sig = sign_tx_once(address, tx.clone(), attempt > 0).await?;
            match super::verify_or_repair_payment_signature(&hash, &sig, address) {
                Ok(good) => {
                    if good != sig {
                        tracing::warn!(
                            "Trezor payment signature arrived in a non-canonical \
                             shape (parity/s) and was repaired — it recovers to \
                             the configured wallet {address} and is used as repaired"
                        );
                    }
                    return Ok(good);
                }
                Err(got) => {
                    let tx_line = match &tx {
                        OwnedTx::Eip1559(t) => format!(
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
                        ),
                        OwnedTx::Legacy(_) => "legacy (non-eip1559)".into(),
                    };
                    tracing::warn!(
                        "Trezor payment signature attempt {} recovered to {got}, \
                         expected {address} — sighash={hash} r={:#x} s={:#x} parity={} \
                         tx: {tx_line}; retrying on a fresh device session",
                        attempt + 1,
                        sig.r(),
                        sig.s(),
                        sig.v(),
                    );
                    attempts.push(got);
                }
            }
        }
        let now_reports = tokio::time::timeout(
            std::time::Duration::from_secs(10),
            with_signer(|s| async move { live_address(&s).await }),
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
            Some(z) if z.to_lowercase() != address.to_string().to_lowercase() => format!(
                " The device is on a different wallet right now (it reports \
                 {z}): if it uses a passphrase, open the same hidden wallet \
                 it was set up with, then try again."
            ),
            Some(_) => " The device still reports the right wallet, so this \
                 looks like a device or transport fault — unplug it, plug it \
                 back in, and try again; if it keeps happening, copy this \
                 message into a bug report."
                .to_string(),
            None => " If the device uses a passphrase, open the same hidden \
                 wallet it was set up with; otherwise unplug it, plug it back \
                 in, and try again."
                .to_string(),
        };
        Err(format!(
            "the Trezor's payment signature did not verify: the device \
             {signed_as} but this wallet is {address}.{diagnosis} Nothing was \
             sent to the network and nothing was spent."
        ))
    }

    impl VerifiedTrezor {
        async fn sign_verified(
            &self,
            tx: &mut dyn alloy::consensus::SignableTransaction<Signature>,
        ) -> Result<Signature, String> {
            let hash = tx.signature_hash();
            let owned = if let Some(t) = super::concrete_eip1559(tx) {
                OwnedTx::Eip1559(t)
            } else if let Some(l) = super::concrete_legacy(tx) {
                OwnedTx::Legacy(l)
            } else {
                return Err(format!(
                    "this payment is a type-{} transaction in a shape the \
                     Trezor driver cannot sign faithfully — nothing was \
                     sent and nothing was spent; please copy this message \
                     into a bug report",
                    tx.ty()
                ));
            };
            let address = self.address;
            self.cache
                .get_or_sign(hash, move || sign_payment_job(address, owned, hash))
                .await
        }
    }

    #[async_trait::async_trait]
    impl alloy::network::TxSigner<Signature> for VerifiedTrezor {
        fn address(&self) -> Address {
            self.address
        }

        async fn sign_transaction(
            &self,
            tx: &mut dyn alloy::consensus::SignableTransaction<Signature>,
        ) -> alloy::signers::Result<Signature> {
            self.sign_verified(tx)
                .await
                .map_err(alloy::signers::Error::other)
        }
    }

    #[cfg(test)]
    mod device_tests {
        use super::*;

        #[test]
        fn firmware_version_gate() {
            assert!(!firmware_ok(1, 11, 0), "1.11.0 is below the 1.11.1 floor");
            assert!(firmware_ok(1, 11, 1));
            assert!(firmware_ok(1, 12, 0));
            assert!(!firmware_ok(2, 5, 0));
            assert!(firmware_ok(2, 5, 1));
            assert!(firmware_ok(2, 9, 6));
            // Unknown future majors are assumed capable.
            assert!(firmware_ok(3, 0, 0));
        }

        #[test]
        fn trezor_wire_encodings_trim_leading_zeros() {
            assert_eq!(u64_to_trezor(0), Vec::<u8>::new(), "zero is the empty encoding");
            assert_eq!(u64_to_trezor(1), vec![1]);
            assert_eq!(u64_to_trezor(0x0102), vec![0x01, 0x02]);
            assert_eq!(u128_to_trezor(0), Vec::<u8>::new());
            assert_eq!(u128_to_trezor(255), vec![0xff]);
            assert_eq!(u256_to_trezor(U256::ZERO), Vec::<u8>::new());
            assert_eq!(u256_to_trezor(U256::from(256u64)), vec![0x01, 0x00]);
        }

        #[test]
        fn tx_kind_to_string() {
            let addr = Address::repeat_byte(0xab);
            assert_eq!(to_string_of(&TxKind::Call(addr)), format!("{addr:?}"));
            assert_eq!(to_string_of(&TxKind::Create), "");
        }

        /// convert_tx_signature wraps a 0/1 parity into EIP-155 electrum
        /// form, which to_alloy_sig's normalize_v un-wraps — the exact
        /// round trip the live device path rides, for BOTH parities on
        /// Arbitrum One.
        #[test]
        fn convert_tx_signature_round_trips_parity() {
            for parity in [0u32, 1u32] {
                let mut resp = protos::EthereumTxRequest::new();
                resp.set_signature_v(parity);
                resp.set_signature_r(vec![0x11; 32]);
                resp.set_signature_s(vec![0x22; 32]);
                let ts = convert_tx_signature(&resp, Some(42161)).unwrap();
                // electrum form for a set chain id
                assert_eq!(ts.v, parity as u64 + 2 * 42161 + 35);
                let sig = to_alloy_sig(ts).unwrap();
                assert_eq!(sig.v(), parity == 1, "parity {parity} survives");
            }
        }

        #[test]
        fn to_alloy_sig_handles_raw_message_parities() {
            // A message signature's v is raw 27/28 (or 0/1) — normalize_v
            // must land it on a parity.
            for (v, parity) in [(27u64, false), (28u64, true), (0u64, false), (1u64, true)] {
                let ts = TrezorSig { r: [1u8; 32], s: [2u8; 32], v };
                assert_eq!(to_alloy_sig(ts).unwrap().v(), parity, "v={v}");
            }
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
    /// Job-session guard stub — no device conversation exists here.
    pub struct TrezorJobSession;
    pub async fn begin_job_session(
        _expected_address: &str,
    ) -> Result<TrezorJobSession, String> {
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

    /// concrete_legacy mirrors concrete_eip1559 for the memoization
    /// path: the TypedTransaction enum's legacy payload unwraps, a bare
    /// TxLegacy unwraps, and a 1559 shape yields None (that side has its
    /// own extractor).
    #[test]
    fn concrete_legacy_unwraps_enum_and_bare_shapes() {
        use alloy::consensus::{SignableTransaction, TxEip1559, TxLegacy, TypedTransaction};
        let legacy = TxLegacy {
            chain_id: Some(42161),
            nonce: 5,
            gas_price: 30_000_000,
            gas_limit: 80_000,
            to: alloy::primitives::TxKind::Call(alloy::primitives::Address::repeat_byte(0x77)),
            value: alloy::primitives::U256::ZERO,
            input: alloy::primitives::Bytes::from_static(&[0x0c]),
        };
        let typed: TypedTransaction = legacy.clone().into();
        let dyn_typed: &dyn SignableTransaction<alloy::primitives::Signature> = &typed;
        assert_eq!(concrete_legacy(dyn_typed), Some(legacy.clone()));
        let dyn_bare: &dyn SignableTransaction<alloy::primitives::Signature> = &legacy;
        assert_eq!(concrete_legacy(dyn_bare), Some(legacy.clone()));
        let t1559: TypedTransaction = TxEip1559 {
            chain_id: 42161,
            nonce: 5,
            gas_limit: 80_000,
            max_fee_per_gas: 30_000_000,
            max_priority_fee_per_gas: 0,
            to: alloy::primitives::TxKind::Call(alloy::primitives::Address::repeat_byte(0x77)),
            value: alloy::primitives::U256::ZERO,
            access_list: Default::default(),
            input: alloy::primitives::Bytes::new(),
        }
        .into();
        let dyn_1559: &dyn SignableTransaction<alloy::primitives::Signature> = &t1559;
        assert_eq!(concrete_legacy(dyn_1559), None);
    }

    fn test_sig(byte: u8) -> alloy::primitives::Signature {
        alloy::primitives::Signature::new(
            alloy::primitives::U256::from(byte),
            alloy::primitives::U256::from(byte),
            false,
        )
    }

    /// The memoization heart: a second request for the same sighash is
    /// served from the first conversation's result — the signer closure
    /// runs exactly once.
    #[tokio::test(flavor = "multi_thread")]
    async fn sigcache_signs_once_per_sighash() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        use std::sync::Arc;
        let cache = sigcache::SigCache::new();
        let runs = Arc::new(AtomicUsize::new(0));
        let hash = alloy::primitives::B256::repeat_byte(0x01);
        for _ in 0..3 {
            let runs = runs.clone();
            let sig = cache
                .get_or_sign(hash, move || async move {
                    runs.fetch_add(1, Ordering::SeqCst);
                    Ok(test_sig(7))
                })
                .await
                .unwrap();
            assert_eq!(sig, test_sig(7));
        }
        assert_eq!(runs.load(Ordering::SeqCst), 1, "one device conversation only");
        // A different sighash is its own conversation.
        let other = alloy::primitives::B256::repeat_byte(0x02);
        let runs2 = runs.clone();
        cache
            .get_or_sign(other, move || async move {
                runs2.fetch_add(1, Ordering::SeqCst);
                Ok(test_sig(9))
            })
            .await
            .unwrap();
        assert_eq!(runs.load(Ordering::SeqCst), 2);
    }

    /// The evmlib-timeout scenario this whole module exists for: the
    /// first caller is DROPPED mid-wait (evmlib's 5s broadcast timeout),
    /// the detached conversation finishes anyway, and the retry's
    /// request for the same sighash gets the finished signature without
    /// a second conversation.
    #[tokio::test(flavor = "multi_thread")]
    async fn sigcache_survives_a_dropped_caller() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        use std::sync::Arc;
        let cache = sigcache::SigCache::new();
        let runs = Arc::new(AtomicUsize::new(0));
        let hash = alloy::primitives::B256::repeat_byte(0x03);
        {
            let runs = runs.clone();
            let first = cache.get_or_sign(hash, move || async move {
                runs.fetch_add(1, Ordering::SeqCst);
                // The "human at the device" delay — far past the
                // caller's timeout below.
                tokio::time::sleep(std::time::Duration::from_millis(300)).await;
                Ok(test_sig(5))
            });
            // Drop the caller at a tight timeout, like evmlib does.
            let timed_out =
                tokio::time::timeout(std::time::Duration::from_millis(30), first).await;
            assert!(timed_out.is_err(), "the first caller must get cut off");
        }
        // The retry: joins the still-running conversation and gets the
        // signature the moment the "tap" lands.
        let sig = cache
            .get_or_sign(hash, move || async move {
                panic!("the retry must never start a second conversation")
            })
            .await
            .unwrap();
        assert_eq!(sig, test_sig(5));
        assert_eq!(runs.load(Ordering::SeqCst), 1);
    }

    /// Failures are delivered but never cached: a cancelled tap must not
    /// poison the next attempt, which gets a brand-new conversation.
    #[tokio::test(flavor = "multi_thread")]
    async fn sigcache_never_caches_a_failure() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        use std::sync::Arc;
        let cache = sigcache::SigCache::new();
        let runs = Arc::new(AtomicUsize::new(0));
        let hash = alloy::primitives::B256::repeat_byte(0x04);
        let runs1 = runs.clone();
        let err = cache
            .get_or_sign(hash, move || async move {
                runs1.fetch_add(1, Ordering::SeqCst);
                Err("cancelled on the Trezor".to_string())
            })
            .await
            .unwrap_err();
        assert!(err.contains("cancelled"));
        let runs2 = runs.clone();
        let sig = cache
            .get_or_sign(hash, move || async move {
                runs2.fetch_add(1, Ordering::SeqCst);
                Ok(test_sig(6))
            })
            .await
            .unwrap();
        assert_eq!(sig, test_sig(6));
        assert_eq!(runs.load(Ordering::SeqCst), 2, "the failure re-ran the signer");
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

    /// Host-passphrase toggle: off by default, flips with set().
    #[test]
    fn host_passphrase_toggle() {
        host_passphrase::set(false);
        assert!(!host_passphrase::enabled());
        host_passphrase::set(true);
        assert!(host_passphrase::enabled());
        host_passphrase::set(false);
        assert!(!host_passphrase::enabled());
    }

    /// The passphrase channel: delivering to nobody reports false; a
    /// waiting conversation receives the app's passphrase; "enter on
    /// device" and cancellation are their own replies; pending() tracks
    /// whether a request is outstanding.
    #[test]
    fn passphrase_channel_delivers_to_a_waiter() {
        use passphrase::Reply;
        // Nobody waiting.
        assert!(!passphrase::pending());
        assert!(!passphrase::deliver("x".into()), "no waiter → not delivered");

        // A host answer.
        let h = std::thread::spawn(|| passphrase::request());
        // Wait until the request registers.
        for _ in 0..200 {
            if passphrase::pending() { break; }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        assert!(passphrase::pending());
        assert!(passphrase::deliver("hunter2".into()));
        match h.join().unwrap() {
            Reply::Host(p) => assert_eq!(&*p, "hunter2"),
            _ => panic!("expected a host passphrase"),
        }
        assert!(!passphrase::pending(), "the slot clears after delivery");

        // The on-device escape.
        let h = std::thread::spawn(|| passphrase::request());
        for _ in 0..200 {
            if passphrase::pending() { break; }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        assert!(passphrase::use_device());
        assert!(matches!(h.join().unwrap(), Reply::OnDevice));
    }
}

