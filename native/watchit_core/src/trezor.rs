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

    /// Serializes the unit tests that read the process-global beacon.
    #[cfg(test)]
    pub(crate) static TEST_GATE: Mutex<()> = Mutex::new(());

    static SEQ: AtomicU64 = AtomicU64::new(0);
    /// The steps open right now, innermost last: (guard id, announced
    /// seq, action). A step can open INSIDE another — a payment
    /// signature that first has to wait for the device to be unlocked, a
    /// session open that asks for the passphrase — and when the inner
    /// one ends the outer one is what the device is waiting on again.
    static OPEN: Mutex<Vec<(u64, u64, &'static str)>> = Mutex::new(Vec::new());

    /// Ends its step on drop, wherever it sits: an older guard dropping
    /// never erases a newer action out from under the poller, and an
    /// inner step ending hands the beacon back to the step around it.
    pub struct Guard {
        id: u64,
    }

    impl Drop for Guard {
        fn drop(&mut self) {
            let mut open = OPEN.lock().unwrap_or_else(|p| p.into_inner());
            let Some(at) = open.iter().position(|(id, _, _)| *id == self.id) else {
                return;
            };
            let was_innermost = at + 1 == open.len();
            open.remove(at);
            if was_innermost {
                // The step underneath is what the device waits on again:
                // give it a fresh seq so the app announces it anew (its
                // card went away when the inner step took over).
                if let Some(under) = open.last_mut() {
                    under.1 = SEQ.fetch_add(1, Ordering::Relaxed) + 1;
                }
            }
        }
    }

    /// Mark the start of a step that waits on a human at the device.
    /// `action` is a stable machine word the app maps to copy:
    /// `sign-identity`, `confirm-address`, `sign-payment`,
    /// `unlock-wallet` (the per-job session open, where a
    /// passphrase-protected device asks for its passphrase once),
    /// `enter-passphrase`, `unlock-device` (the device is locked and
    /// showing its PIN pad) and `connect-device` (no usable device on
    /// USB — plug it in / replug it).
    pub fn begin(action: &'static str) -> Guard {
        let seq = SEQ.fetch_add(1, Ordering::Relaxed) + 1;
        OPEN.lock()
            .unwrap_or_else(|p| p.into_inner())
            .push((seq, seq, action));
        Guard { id: seq }
    }

    /// (active, seq, action) for the innermost open step — seq grows per
    /// announcement so a poller can tell a NEW wait apart from one it
    /// already announced.
    pub fn snapshot() -> (bool, u64, Option<&'static str>) {
        let open = OPEN.lock().unwrap_or_else(|p| p.into_inner());
        match open.last() {
            Some((_, seq, action)) => (true, *seq, Some(action)),
            None => (false, SEQ.load(Ordering::Relaxed), None),
        }
    }
}

/// The app's "Stop waiting" button. A job that finds no usable Trezor on
/// USB waits for one to be plugged in (see `device::await_device`) — the
/// one wait the user cannot end at the device itself, so the app can end
/// it here. Lives outside the desktop-only module so the route compiles
/// on every target.
pub mod waiting {
    use std::sync::atomic::{AtomicBool, Ordering};

    static STOP: AtomicBool = AtomicBool::new(false);

    /// The user gave up on the wait in progress (no-op when none is).
    pub fn stop() {
        STOP.store(true, Ordering::Relaxed);
    }

    /// A new wait starts un-stopped: a stale press never ends a later one.
    pub fn begin() {
        STOP.store(false, Ordering::Relaxed);
    }

    pub fn stopped() -> bool {
        STOP.load(Ordering::Relaxed)
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
/// The mitigation, with no evmlib fork: the device conversation runs as
/// a DETACHED task — a caller dropped at the timeout never cancels it —
/// and the locally VERIFIED signature lands here keyed by sighash, so a
/// retry that rebuilds the SAME transaction joins the conversation (or
/// hits the completed cache) instead of prompting again.
///
/// That only helps when the retry really is the same transaction, and on
/// Arbitrum it often is not: evmlib re-estimates the gas on every retry
/// and the estimate moves with the L1 data price, so the sighash changes
/// and each retry queues ANOTHER confirmation — the endless confirm loop
/// on the first live batch payment (2026-11-09). The real fix is to stay
/// off the deadline-bound send altogether: batch payments and the token
/// allowance sign through payjournal.rs (once, no deadline), and
/// ant-core's own uploads and backups sign through evmlib's journal the
/// same way. This cache stays as the backstop for whatever still goes
/// through the legacy send.
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

    /// How one exchange with the device ended badly — kept typed (not
    /// flattened to text) so [`supervise`] can tell a lost link and a
    /// device that locked itself from a real refusal.
    #[derive(Debug)]
    enum DevError {
        /// No Trezor on USB.
        Missing,
        /// The link failed mid-conversation: unplugged, not answering, or
        /// the two sides out of step. The raw detail rides along for the
        /// final message.
        Link(String),
        /// The device ended the workflow as cancelled — the user's tap on
        /// Cancel, OR the device locking itself while a screen was still
        /// waiting (its auto-lock closes whatever is open).
        Cancelled,
        /// Everything else, already in end-user words. Final.
        Fatal(String),
    }

    impl DevError {
        /// The end-user sentence for an error nothing could ride out.
        fn message(self) -> String {
            match self {
                DevError::Missing => {
                    "no Trezor found — plug it in, unlock it, and try again".into()
                }
                DevError::Link(detail) if detail.to_lowercase().contains("busy") => format!(
                    "another program is holding the Trezor ({detail}) — close \
                     Trezor Suite or any wallet page using it, then try again"
                ),
                DevError::Link(detail) => format!(
                    "lost contact with the Trezor ({detail}) — unplug it, plug \
                     it back in, unlock it, and try again. Nothing was changed."
                ),
                DevError::Cancelled => "cancelled on the Trezor — nothing was changed".into(),
                DevError::Fatal(msg) => msg,
            }
        }
    }

    /// Sort a transport-layer failure: a permission refusal is final
    /// (retrying cannot fix missing udev rules), anything else is the
    /// link.
    fn link_or_denied(detail: String) -> DevError {
        let lower = detail.to_lowercase();
        if lower.contains("denied") || lower.contains("permission") || lower.contains("access") {
            DevError::Fatal(friendly(detail))
        } else {
            DevError::Link(detail)
        }
    }

    /// A `Failure` the device answered with.
    fn failure(f: &protos::Failure) -> DevError {
        use protos::failure::FailureType as F;
        match f.code() {
            F::Failure_ActionCancelled => DevError::Cancelled,
            F::Failure_PinCancelled => DevError::Fatal(
                "PIN entry was cancelled on the Trezor — nothing was changed".into(),
            ),
            F::Failure_PinInvalid => DevError::Fatal(
                "the Trezor refused the PIN — nothing was changed".into(),
            ),
            _ if f.message().to_lowercase().contains("cancel") => DevError::Cancelled,
            _ => DevError::Fatal(format!("the Trezor reported: {}", f.message())),
        }
    }

    /// trezor-client's error → ours.
    fn classify(e: trezor_client::Error) -> DevError {
        use trezor_client::Error as E;
        match e {
            E::NoDeviceFound => DevError::Missing,
            E::DeviceNotUnique => DevError::Fatal(
                "more than one Trezor is plugged in — leave only the one set \
                 up with W@tch connected, then try again"
                    .into(),
            ),
            E::TransportConnect(t)
            | E::TransportBeginSession(t)
            | E::TransportEndSession(t)
            | E::TransportSendMessage(t)
            | E::TransportReceiveMessage(t) => link_or_denied(t.to_string()),
            E::FailureResponse(f) => failure(&f),
            // A reply that makes no sense where it arrived: host and
            // device are out of step (a conversation abandoned earlier).
            // A fresh handle starts clean.
            e @ (E::UnexpectedMessageType(_)
            | E::Protobuf(_)
            | E::UnexpectedInteractionRequest(_)) => DevError::Link(e.to_string()),
            other => DevError::Fatal(friendly(other)),
        }
    }

    /// How long a conversation may wait for the DEVICE to become usable.
    #[derive(Clone, Copy, PartialEq, Eq, Debug)]
    enum Wait {
        /// Fail at once: the presence probe and the setup dialog, which
        /// show "no Trezor" themselves and let the user try again.
        Brief,
        /// A running job (backup, upload): ride out a device that locked
        /// itself, was unplugged, or stopped answering — the app shows
        /// what to do — instead of failing work the user already waited
        /// minutes for.
        Patient,
    }

    /// A job gives up on a device that keeps locking itself mid-screen
    /// after this many rounds (each needs the user's PIN, so this is a
    /// backstop, not a limit anyone meets).
    const MAX_RELOCKS: u32 = 20;
    /// Link failures in a row (device still on the bus) before the user
    /// is asked to replug it.
    const LINK_RETRIES: u32 = 2;
    /// Replug requests per conversation before it fails for good.
    const MAX_REPLUGS: u32 = 2;
    /// How long a job waits for a Trezor to be plugged in / replugged.
    /// (Zero under plain `cargo test`: the suite has no device, and a job
    /// a test leaves behind must not sit on the shared beacon. The
    /// emulator-driven device tests wait for real.)
    fn device_wait() -> std::time::Duration {
        let unit_test = cfg!(test) && std::env::var_os("WATCHIT_TREZOR_EMU_HOME").is_none();
        std::time::Duration::from_secs(if unit_test { 0 } else { 10 * 60 })
    }
    const DEVICE_POLL: std::time::Duration = std::time::Duration::from_secs(1);

    /// What [`await_device`] waits for.
    #[derive(Clone, PartialEq, Eq, Debug)]
    enum Until {
        /// Any Trezor on the bus.
        Present,
        /// A bus that looks different from this snapshot: the device was
        /// unplugged and plugged back in (USB hands it a new address).
        Replugged(Vec<String>),
    }

    /// The Trezors on USB right now — enumeration only, nothing is sent
    /// to the device (a locked device's PIN pad is closed by any message
    /// that arrives, so a wait must never poll it with messages).
    fn bus() -> Vec<String> {
        trezor_client::find_devices(false)
            .iter()
            .map(|d| d.to_string())
            .collect()
    }

    /// Wait for a usable device with the app showing `connect-device`
    /// ("plug it in / replug it"), until it shows up, the user presses
    /// Stop waiting, or `limit` lapses.
    fn await_device(
        until: Until,
        look: &dyn Fn() -> Vec<String>,
        limit: std::time::Duration,
        tick: std::time::Duration,
    ) -> Result<(), String> {
        let arrived = |now: &[String]| match &until {
            Until::Present => !now.is_empty(),
            Until::Replugged(before) => !now.is_empty() && now != before.as_slice(),
        };
        if arrived(&look()) {
            return Ok(());
        }
        if limit.is_zero() {
            return Err(DevError::Missing.message());
        }
        let _attention = super::attention::begin("connect-device");
        super::waiting::begin();
        let started = std::time::Instant::now();
        loop {
            if super::waiting::stopped() {
                return Err("stopped waiting for the Trezor — nothing was changed".into());
            }
            if started.elapsed() >= limit {
                return Err(DevError::Missing.message());
            }
            std::thread::sleep(tick);
            if arrived(&look()) {
                // A device that only just appeared is still starting up.
                std::thread::sleep(tick);
                return Ok(());
            }
        }
    }

    /// Run one device conversation to its end, riding out — for a
    /// [`Wait::Patient`] job — the interruptions that are nobody's
    /// decision:
    ///
    ///   * the device LOCKED ITSELF while a screen was waiting (its
    ///     auto-lock answers the open request "cancelled"): ask again —
    ///     the device shows its PIN pad, then the same screens;
    ///   * NO DEVICE: wait for one to be plugged in;
    ///   * the LINK FAILED: try again on a fresh handle, and when it
    ///     keeps failing ask for a replug and wait for it.
    ///
    /// A cancel with the device still unlocked is the user's own, and
    /// final — as is anything else. `open` yields a fresh handle on the
    /// job's session, `locked` says whether the device is locked right
    /// now, `settle` is [`await_device`].
    fn supervise<T>(
        wait: Wait,
        mut open: impl FnMut() -> Result<trezor_client::Trezor, DevError>,
        op: impl Fn(&mut trezor_client::Trezor) -> Result<T, DevError>,
        mut locked: impl FnMut() -> bool,
        look: &dyn Fn() -> Vec<String>,
        mut settle: impl FnMut(Until) -> Result<(), String>,
        pause: std::time::Duration,
    ) -> Result<T, String> {
        let (mut relocks, mut link_failures, mut replugs) = (0u32, 0u32, 0u32);
        loop {
            let err = match open().and_then(|mut client| op(&mut client)) {
                Ok(value) => return Ok(value),
                Err(e) => e,
            };
            if wait == Wait::Brief {
                return Err(err.message());
            }
            match err {
                DevError::Cancelled if relocks < MAX_RELOCKS && locked() => {
                    relocks += 1;
                    tracing::info!(
                        "the Trezor locked itself while a confirmation was \
                         waiting — asking again (round {relocks})"
                    );
                }
                DevError::Missing => {
                    tracing::info!("no Trezor on USB — waiting for it");
                    settle(Until::Present)?;
                }
                DevError::Link(detail) => {
                    link_failures += 1;
                    tracing::warn!("Trezor link failed ({detail}), failure {link_failures}");
                    if link_failures <= LINK_RETRIES {
                        // Often a one-off (a conversation abandoned
                        // earlier, a device mid-wake): a fresh handle
                        // usually just works.
                        std::thread::sleep(pause);
                        settle(Until::Present)?;
                    } else if replugs < MAX_REPLUGS {
                        replugs += 1;
                        link_failures = 0;
                        settle(Until::Replugged(look()))?;
                    } else {
                        return Err(DevError::Link(detail).message());
                    }
                }
                other => return Err(other.message()),
            }
        }
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
        /// The device session every conversation resumes. Replaced when
        /// the device no longer knows it (a replug wipes its sessions):
        /// the new one is adopted so the passphrase is asked once more,
        /// not once per message.
        session_id: std::sync::Mutex<Vec<u8>>,
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
    ) -> Result<T, DevError> {
        match resp {
            TrezorResponse::Ok(value) => Ok(value),
            TrezorResponse::Failure(f) => Err(failure(&f)),
            TrezorResponse::ButtonRequest(req) => {
                let next = {
                    // A locked device answers any request by putting up
                    // its PIN pad first; the app says so while it waits
                    // (the step around this one takes the card back
                    // when the PIN is in).
                    let _unlock = (req.request_type()
                        == trezor_client::ButtonRequestType::ButtonRequest_PinEntry)
                        .then(|| super::attention::begin("unlock-device"));
                    req.ack().map_err(classify)?
                };
                drive(next, host, always_on_device)
            }
            TrezorResponse::PinMatrixRequest(_) => Err(DevError::Fatal(
                "the Trezor is asking for its PIN to be typed on this computer, \
                 which W@tch does not support — unlock the device itself, then \
                 try again"
                    .into(),
            )),
            TrezorResponse::PassphraseRequest(req) => {
                // Host entry only when the user turned it on AND the
                // firmware allows it; otherwise exactly the old
                // behaviour (let the user enter it on the device).
                if host && !always_on_device {
                    match super::passphrase::request() {
                        super::passphrase::Reply::Host(p) => drive(
                            req.ack_passphrase((*p).clone()).map_err(classify)?,
                            host,
                            always_on_device,
                        ),
                        super::passphrase::Reply::OnDevice => {
                            let on_device = req.on_device();
                            drive(req.ack(!on_device).map_err(classify)?, host, always_on_device)
                        }
                        super::passphrase::Reply::Cancelled => {
                            // Nobody answered. Tell the device too, or it
                            // sits on "enter your passphrase" until the
                            // next conversation knocks it out of it.
                            let _ = req.client.call_raw(protos::Cancel::new());
                            Err(DevError::Fatal(
                                "no passphrase was entered for the Trezor in \
                                 time — nothing was changed"
                                    .into(),
                            ))
                        }
                    }
                } else {
                    let on_device = req.on_device();
                    drive(req.ack(!on_device).map_err(classify)?, host, always_on_device)
                }
            }
        }
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
    ) -> Result<String, DevError> {
        let mut req = protos::EthereumGetAddress::new();
        req.address_n = path.to_vec();
        let resp = client
            .call(
                req,
                Box::new(|_, m: protos::EthereumAddress| Ok(m.address().to_string())),
            )
            .map_err(classify)?;
        drive(resp, host, always)
    }

    fn eth_sign_message(
        client: &mut trezor_client::Trezor,
        path: &[u32],
        message: &[u8],
        host: bool,
        always: bool,
    ) -> Result<Signature, DevError> {
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
            .map_err(classify)?;
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

    fn to_alloy_sig(ts: TrezorSig) -> Result<Signature, DevError> {
        let r = U256::from_be_bytes(ts.r);
        let s = U256::from_be_bytes(ts.s);
        let parity = normalize_v(ts.v)
            .ok_or_else(|| {
                DevError::Fatal(format!(
                    "the Trezor returned an invalid signature parity ({})",
                    ts.v
                ))
            })?;
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
    ) -> Result<TrezorSig, DevError> {
        let mut v = resp.signature_v() as u64;
        if let Some(chain_id) = chain_id {
            if v <= 1 {
                v = v + 2 * chain_id + 35;
            }
        }
        let r: [u8; 32] = resp
            .signature_r()
            .try_into()
            .map_err(|_| DevError::Fatal("the Trezor returned a malformed signature".into()))?;
        let s: [u8; 32] = resp
            .signature_s()
            .try_into()
            .map_err(|_| DevError::Fatal("the Trezor returned a malformed signature".into()))?;
        Ok(TrezorSig { r, s, v })
    }

    /// Feed the device the rest of a transaction's calldata, answering
    /// whatever it asks in between, until it returns the signature.
    ///
    /// trezor-client's own loop (which this replaces) treats every reply
    /// to a data chunk as a plain data request. That held for firmware
    /// that confirmed the transaction BEFORE streaming its data; current
    /// firmware loads the first ~6 KB silently and only then starts
    /// showing confirmation screens, so a `ButtonRequest` arrives as the
    /// reply to a data chunk (and again between later chunks, and before
    /// the signature). Left unanswered, the device shows "Communication
    /// with your connected device failed" two seconds after the user's
    /// tap — the live failure on the first pooled batch payment, whose
    /// calldata is several KB. So every reply goes through [`drive`].
    ///
    /// The chunk size is whatever the device asked for (it rejects more),
    /// not a fixed 1024.
    fn stream_tx_data(
        client: &mut trezor_client::Trezor,
        mut resp: protos::EthereumTxRequest,
        mut data: Vec<u8>,
        host: bool,
        always: bool,
    ) -> Result<protos::EthereumTxRequest, DevError> {
        while resp.data_length() > 0 {
            if data.is_empty() {
                return Err(DevError::Fatal(
                    "the Trezor asked for more transaction data than the \
                     payment contains — nothing was signed"
                        .into(),
                ));
            }
            let take = std::cmp::min(resp.data_length() as usize, data.len());
            let mut ack = protos::EthereumTxAck::new();
            ack.set_data_chunk(data.drain(..take).collect());
            let next = client
                .call(ack, Box::new(|_, m: protos::EthereumTxRequest| Ok(m)))
                .map_err(classify)?;
            resp = drive(next, host, always)?;
        }
        Ok(resp)
    }

    fn eth_sign_eip1559(
        client: &mut trezor_client::Trezor,
        path: &[u32],
        tx: &TxEip1559,
        host: bool,
        always: bool,
    ) -> Result<Signature, DevError> {
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
            .map_err(classify)?;
        let resp = drive(resp, host, always)?;
        let resp = stream_tx_data(client, resp, data, host, always)?;
        to_alloy_sig(convert_tx_signature(&resp, Some(tx.chain_id))?)
    }

    fn eth_sign_legacy(
        client: &mut trezor_client::Trezor,
        path: &[u32],
        tx: &TxLegacy,
        host: bool,
        always: bool,
    ) -> Result<Signature, DevError> {
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
            .map_err(classify)?;
        let resp = drive(resp, host, always)?;
        let resp = stream_tx_data(client, resp, data, host, always)?;
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
    ) -> Result<String, DevError> {
        let mut req = protos::EthereumGetAddress::new();
        req.address_n = path.to_vec();
        req.set_show_display(true);
        let resp = client
            .call(
                req,
                Box::new(|_, m: protos::EthereumAddress| Ok(m.address().to_string())),
            )
            .map_err(classify)?;
        drive(resp, host, always)
    }

    impl OwnTrezorSigner {
        /// Open a brand-new device session and resolve the address — the
        /// first operation, where a locked device asks for its PIN and a
        /// passphrase-protected one for its passphrase, once. The
        /// host-passphrase preference is snapshotted here for the whole
        /// signer.
        fn connect(wait: Wait) -> Result<Self, String> {
            let mut signer = Self {
                session_id: std::sync::Mutex::new(Vec::new()),
                path: super::derivation_path_vec(),
                address: Address::ZERO,
                host_passphrase: super::host_passphrase::enabled(),
                always_on_device: false,
            };
            // Opening the first handle starts the session (adopted in
            // `open`); its features say what the device can do.
            let (firmware_fine, always_on_device) = signer.converse(wait, |client| {
                let features = client.features().ok_or_else(|| {
                    DevError::Fatal("could not read the Trezor's features".into())
                })?;
                Ok((
                    firmware_ok(
                        features.major_version() as u64,
                        features.minor_version() as u64,
                        features.patch_version() as u64,
                    ),
                    features.passphrase_always_on_device(),
                ))
            })?;
            if !firmware_fine {
                return Err(
                    "this Trezor's firmware is too old to sign the network's \
                     payment transactions — update it in Trezor Suite, then \
                     try again"
                        .into(),
                );
            }
            signer.always_on_device = always_on_device;
            let address = signer.get_address(wait)?;
            signer.address = parse_address(&address)?;
            Ok(signer)
        }

        fn address(&self) -> Address {
            self.address
        }

        /// A fresh USB handle on this signer's device session, so a
        /// passphrase already entered this session is not asked again.
        /// A device that no longer knows the session (it was replugged or
        /// restarted) hands back a new one, adopted here.
        fn open(&self) -> Result<trezor_client::Trezor, DevError> {
            let mut client = trezor_client::unique(false).map_err(classify)?;
            let wanted = self
                .session_id
                .lock()
                .unwrap_or_else(|p| p.into_inner())
                .clone();
            client
                .init_device((!wanted.is_empty()).then(|| wanted.clone()))
                .map_err(classify)?;
            let got = client
                .features()
                .map(|f| f.session_id().to_vec())
                .unwrap_or_default();
            if !got.is_empty() && got != wanted {
                if !wanted.is_empty() {
                    tracing::info!(
                        "the Trezor no longer knows this job's session (replugged \
                         or restarted) — carrying on in a new one"
                    );
                }
                *self.session_id.lock().unwrap_or_else(|p| p.into_inner()) = got;
            }
            Ok(client)
        }

        /// Is the device locked right now? (Its features answer without
        /// unlocking; a device with no PIN cannot lock.)
        fn locked_now(&self) -> bool {
            self.open()
                .ok()
                .and_then(|client| {
                    client
                        .features()
                        .map(|f| f.pin_protection() && f.has_unlocked() && !f.unlocked())
                })
                .unwrap_or(false)
        }

        /// One conversation on this signer's session, under [`supervise`].
        fn converse<T>(
            &self,
            wait: Wait,
            op: impl Fn(&mut trezor_client::Trezor) -> Result<T, DevError>,
        ) -> Result<T, String> {
            supervise(
                wait,
                || self.open(),
                op,
                || self.locked_now(),
                &bus,
                |until| await_device(until, &bus, device_wait(), DEVICE_POLL),
                DEVICE_POLL,
            )
        }

        /// A real USB round trip for the current address — never a cached
        /// value, so a session that silently degraded (stale id after a
        /// replug → the device minted a fresh session, maybe on a
        /// different hidden wallet) is caught before any tap is wasted.
        fn get_address(&self, wait: Wait) -> Result<String, String> {
            self.converse(wait, |client| {
                eth_get_address(client, &self.path, self.host_passphrase, self.always_on_device)
            })
        }

        fn sign_message(&self, wait: Wait, message: &[u8]) -> Result<Signature, String> {
            self.converse(wait, |client| {
                eth_sign_message(
                    client,
                    &self.path,
                    message,
                    self.host_passphrase,
                    self.always_on_device,
                )
            })
        }

        fn sign_eip1559(&self, wait: Wait, tx: &TxEip1559) -> Result<Signature, String> {
            self.converse(wait, |client| {
                eth_sign_eip1559(
                    client,
                    &self.path,
                    tx,
                    self.host_passphrase,
                    self.always_on_device,
                )
            })
        }

        fn sign_legacy(&self, wait: Wait, tx: &TxLegacy) -> Result<Signature, String> {
            self.converse(wait, |client| {
                eth_sign_legacy(
                    client,
                    &self.path,
                    tx,
                    self.host_passphrase,
                    self.always_on_device,
                )
            })
        }

        fn show_address_on_device(&self, wait: Wait) -> Result<String, String> {
            self.converse(wait, |client| {
                eth_show_address(client, &self.path, self.host_passphrase, self.always_on_device)
            })
        }
    }

    /// Open the job's one device session, BEFORE any ant-core work: the
    /// address read inside [`OwnTrezorSigner::connect`] is where a locked
    /// device asks for its PIN and a passphrase-protected one for its
    /// passphrase — once (on the device, or in the app when host entry is
    /// on), covering the identity derive and every payment signature of
    /// the whole job. A device that is not plugged in is waited for, with
    /// the app saying so. Refuses a device whose address is not the
    /// configured one — before any encrypt/quote work.
    pub async fn begin_job_session(
        expected_address: &str,
    ) -> Result<TrezorJobSession, String> {
        let expected = expected_address.to_lowercase();
        let _attention = super::attention::begin("unlock-wallet");
        let signer = with_fresh_signer(Wait::Patient, move |s| async move {
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
    /// allows and one is open, else a freshly connected signer (opened
    /// with the given patience); everything it does is synchronous USB
    /// underneath, plus however long the user takes at the device's own
    /// confirm screen (or the app's passphrase field).
    async fn with_signer_locked<T, F, Fut>(
        guard: tokio::sync::MutexGuard<'static, ()>,
        reuse_job_session: bool,
        wait: Wait,
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
                None => std::sync::Arc::new(OwnTrezorSigner::connect(wait)?),
            };
            handle.block_on(f(signer))
        })
        .await
        .map_err(|e| format!("Trezor task failed: {e}"))?
    }

    /// [with_signer_locked] behind a plain wait on the conversation lock,
    /// reusing the job session when one is open.
    async fn with_signer<T, F, Fut>(wait: Wait, f: F) -> Result<T, String>
    where
        T: Send + 'static,
        F: FnOnce(std::sync::Arc<OwnTrezorSigner>) -> Fut + Send + 'static,
        Fut: std::future::Future<Output = Result<T, String>>,
    {
        with_signer_locked(DEVICE_LOCK.lock().await, true, wait, f).await
    }

    /// [with_signer] forced onto a brand-new device session — the setup
    /// ceremony (a fresh binding by intent), the job-session open itself,
    /// and a signing retry that assumes the session went bad.
    async fn with_fresh_signer<T, F, Fut>(wait: Wait, f: F) -> Result<T, String>
    where
        T: Send + 'static,
        F: FnOnce(std::sync::Arc<OwnTrezorSigner>) -> Fut + Send + 'static,
        Fut: std::future::Future<Output = Result<T, String>>,
    {
        with_signer_locked(DEVICE_LOCK.lock().await, false, wait, f).await
    }

    fn signer_address(s: &OwnTrezorSigner) -> String {
        s.address().to_string()
    }

    /// The full signature (for recovery checks) plus the r‖s bytes the
    /// backup identity derives from.
    fn sign_identity(s: &OwnTrezorSigner, wait: Wait) -> Result<(Signature, [u8; 64]), String> {
        let sig = s.sign_message(wait, crate::backup::IDENTITY_MESSAGE_V1.as_bytes())?;
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
        with_signer_locked(guard, true, Wait::Brief, |s| async move {
            s.get_address(Wait::Brief)
        })
        .await
    }

    /// The one-time setup ceremony: resolve the address, sign the frozen
    /// identity message twice (the determinism guard), derive the backup
    /// identity, then SHOW THE ADDRESS ON THE DEVICE for the user to
    /// confirm against what the app displays. Three confirmations on the
    /// device; nothing is spent. Cancelling the address screen aborts the
    /// whole setup — nothing has been persisted yet.
    pub async fn setup_ceremony() -> Result<TrezorIdentity, String> {
        // Brief: the setup dialog shows a missing device itself and
        // offers the retry.
        with_fresh_signer(Wait::Brief, |s| async move {
            let address = signer_address(&s);
            let (first_sig, first) = {
                let _attention = super::attention::begin("sign-identity");
                let a = sign_identity(&s, Wait::Brief)?;
                let b = sign_identity(&s, Wait::Brief)?;
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
                s.show_address_on_device(Wait::Brief)?
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
        with_signer(Wait::Patient, move |s| async move {
            let found = s.get_address(Wait::Patient)?;
            if found.to_lowercase() != expected {
                return Err(format!(
                    "this Trezor holds a different wallet ({found}) than the \
                     one configured — plug in the right device, or re-run the \
                     hardware-wallet setup"
                ));
            }
            let (sig, rs) = {
                let _attention = super::attention::begin("sign-identity");
                sign_identity(&s, Wait::Patient)?
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

    /// Build the payment signer for the configured address. NO device
    /// conversation happens here: the network client attaches this at
    /// every (re)connect, and a device poked then would put up its PIN
    /// pad or passphrase prompt out of nowhere and hold the connect up
    /// until someone answered. The device is checked where it is needed —
    /// the job-session open, and the live address re-check before every
    /// signature.
    pub async fn verified_payment_signer(
        expected_address: &str,
    ) -> Result<VerifiedTrezor, String> {
        Ok(VerifiedTrezor {
            address: parse_address(expected_address)?,
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
        with_signer_locked(
            DEVICE_LOCK.lock().await,
            !force_fresh,
            Wait::Patient,
            move |s| async move {
            let found = s.get_address(Wait::Patient)?;
            if found.to_lowercase() != expected_lower {
                return Err(format!(
                    "this Trezor holds a different wallet ({found}) than \
                     the one configured — if the device uses a \
                     passphrase, open the same hidden wallet it was set \
                     up with, then try again"
                ));
            }
            match tx {
                OwnedTx::Eip1559(t) => s.sign_eip1559(Wait::Patient, &t),
                OwnedTx::Legacy(l) => s.sign_legacy(Wait::Patient, &l),
            }
            },
        )
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
            with_signer(Wait::Brief, |s| async move { s.get_address(Wait::Brief) }),
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

        // ── scripted fake device ──────────────────────────────────────
        //
        // A transport that replays a fixed list of device replies and
        // records everything the host wrote, so the data-streaming loop
        // can be run against the exact message order a firmware uses.

        use std::collections::VecDeque;
        use std::sync::{Arc, Mutex};
        use trezor_client::protos::MessageType as Mt;
        use trezor_client::transport::{error::Error as TransportError, ProtoMessage, Transport};

        #[derive(Default)]
        struct Script {
            replies: VecDeque<(Mt, Vec<u8>)>,
            written: Vec<(Mt, Vec<u8>)>,
        }

        struct FakeDevice(Arc<Mutex<Script>>);

        impl Transport for FakeDevice {
            fn session_begin(&mut self) -> Result<(), TransportError> {
                Ok(())
            }
            fn session_end(&mut self) -> Result<(), TransportError> {
                Ok(())
            }
            fn write_message(&mut self, m: ProtoMessage) -> Result<(), TransportError> {
                let kind = m.message_type();
                self.0.lock().unwrap().written.push((kind, m.into_payload()));
                Ok(())
            }
            fn read_message(&mut self) -> Result<ProtoMessage, TransportError> {
                let (kind, payload) = self
                    .0
                    .lock()
                    .unwrap()
                    .replies
                    .pop_front()
                    .expect("the host kept talking after the script ended");
                Ok(ProtoMessage::new(kind, payload))
            }
        }

        /// `EthereumTxRequest { data_length }` on the wire.
        fn wants(n: u32) -> (Mt, Vec<u8>) {
            let mut bytes = vec![0x08];
            let mut v = n;
            loop {
                let b = (v & 0x7f) as u8;
                v >>= 7;
                if v == 0 {
                    bytes.push(b);
                    break;
                }
                bytes.push(b | 0x80);
            }
            (Mt::MessageType_EthereumTxRequest, bytes)
        }

        /// `EthereumTxRequest { signature_v: 1, r: 0x11.., s: 0x22.. }`.
        fn signed() -> (Mt, Vec<u8>) {
            let mut bytes = vec![0x10, 0x01, 0x1a, 32];
            bytes.extend([0x11u8; 32]);
            bytes.extend([0x22, 32]);
            bytes.extend([0x22u8; 32]);
            (Mt::MessageType_EthereumTxRequest, bytes)
        }

        fn button() -> (Mt, Vec<u8>) {
            (Mt::MessageType_ButtonRequest, Vec::new())
        }

        fn payment_tx(data_len: usize) -> TxEip1559 {
            TxEip1559 {
                chain_id: 42161,
                nonce: 7,
                gas_limit: 900_000,
                max_fee_per_gas: 20_000_000,
                max_priority_fee_per_gas: 1,
                to: TxKind::Call(Address::repeat_byte(0xAB)),
                value: U256::ZERO,
                access_list: Default::default(),
                input: (0..data_len).map(|i| (i % 251) as u8).collect::<Vec<u8>>().into(),
            }
        }

        /// Run one signing conversation against a script; returns the
        /// result and everything the host wrote.
        fn sign_against(
            replies: Vec<(Mt, Vec<u8>)>,
            tx: &TxEip1559,
        ) -> (Result<Signature, String>, Vec<(Mt, Vec<u8>)>) {
            let script = Arc::new(Mutex::new(Script {
                replies: replies.into(),
                written: Vec::new(),
            }));
            let mut client = trezor_client::client::trezor_with_transport(
                trezor_client::Model::Trezor,
                Box::new(FakeDevice(script.clone())),
            );
            let out = eth_sign_eip1559(&mut client, &[0x8000_002c], tx, false, false)
                .map_err(DevError::message);
            let written = std::mem::take(&mut script.lock().unwrap().written);
            (out, written)
        }

        /// The calldata the host actually streamed: the initial chunk in
        /// the sign request plus every later `EthereumTxAck`.
        fn streamed(written: &[(Mt, Vec<u8>)]) -> Vec<u8> {
            let mut all = Vec::new();
            for (kind, payload) in written {
                match kind {
                    Mt::MessageType_EthereumSignTxEIP1559 => {
                        let m: protos::EthereumSignTxEIP1559 =
                            ProtoMessage::new(*kind, payload.clone()).into_message().unwrap();
                        all.extend_from_slice(m.data_initial_chunk());
                    }
                    Mt::MessageType_EthereumTxAck => {
                        let m: protos::EthereumTxAck =
                            ProtoMessage::new(*kind, payload.clone()).into_message().unwrap();
                        all.extend_from_slice(m.data_chunk());
                    }
                    _ => {}
                }
            }
            all
        }

        fn kinds(written: &[(Mt, Vec<u8>)]) -> Vec<Mt> {
            written.iter().map(|(k, _)| *k).collect()
        }

        // ── the conversation supervisor ───────────────────────────────

        /// `Failure { code, message }` on the wire.
        fn failed(code: u8, message: &str) -> (Mt, Vec<u8>) {
            let mut bytes = vec![0x08, code, 0x12, message.len() as u8];
            bytes.extend(message.as_bytes());
            (Mt::MessageType_Failure, bytes)
        }

        /// The device closing whatever is open — what its auto-lock (and
        /// the user's Cancel) both look like.
        fn cancelled() -> (Mt, Vec<u8>) {
            failed(4, "Cancelled")
        }

        fn device(replies: Vec<(Mt, Vec<u8>)>) -> trezor_client::Trezor {
            trezor_client::client::trezor_with_transport(
                trezor_client::Model::Trezor,
                Box::new(FakeDevice(Arc::new(Mutex::new(Script {
                    replies: replies.into(),
                    written: Vec::new(),
                })))),
            )
        }

        /// Run [`supervise`] over a queue of `open` outcomes (one per
        /// handle the supervisor asks for), signing a small payment.
        /// Returns the result, how many handles were opened, and every
        /// wait the supervisor asked for.
        fn supervised(
            wait: Wait,
            opens: Vec<Result<Vec<(Mt, Vec<u8>)>, DevError>>,
            locked: bool,
            settle_result: Result<(), String>,
        ) -> (Result<Signature, String>, usize, Vec<Until>) {
            let tx = payment_tx(100);
            let queue = std::cell::RefCell::new(VecDeque::from(opens));
            let opened = std::cell::Cell::new(0usize);
            let waits = std::cell::RefCell::new(Vec::new());
            let out = supervise(
                wait,
                || {
                    opened.set(opened.get() + 1);
                    queue
                        .borrow_mut()
                        .pop_front()
                        .expect("the supervisor opened more handles than scripted")
                        .map(device)
                },
                |client| eth_sign_eip1559(client, &[0x8000_002c], &tx, false, false),
                || locked,
                &|| vec!["bus-a".to_string()],
                |until| {
                    waits.borrow_mut().push(until);
                    settle_result.clone()
                },
                std::time::Duration::ZERO,
            );
            (out, opened.get(), waits.into_inner())
        }

        /// THE LIVE CASE: a confirmation left waiting until the device
        /// auto-locked. The device answers the open request "cancelled";
        /// it is locked, so nobody decided that — ask again (the device
        /// shows its PIN pad, then the same screens) instead of failing
        /// the whole upload.
        #[test]
        fn a_device_that_locked_itself_mid_confirmation_is_asked_again() {
            let (out, opened, waits) = supervised(
                Wait::Patient,
                vec![Ok(vec![button(), cancelled()]), Ok(vec![button(), signed()])],
                true,
                Ok(()),
            );
            assert!(out.is_ok(), "{out:?}");
            assert_eq!(opened, 2, "one handle per attempt");
            assert!(waits.is_empty(), "the device never left the bus");
        }

        /// The same answer from a device that is still UNLOCKED is the
        /// user's own Cancel — final, never re-asked.
        #[test]
        fn a_cancel_on_an_unlocked_device_is_final() {
            let (out, opened, _) = supervised(
                Wait::Patient,
                vec![Ok(vec![button(), cancelled()])],
                false,
                Ok(()),
            );
            assert_eq!(
                out.unwrap_err(),
                "cancelled on the Trezor — nothing was changed"
            );
            assert_eq!(opened, 1);
        }

        /// Cancelling at the device's PIN pad is a decision too.
        #[test]
        fn a_cancelled_pin_entry_is_final() {
            let (out, opened, _) = supervised(
                Wait::Patient,
                vec![Ok(vec![failed(6, "PIN cancelled")])],
                true,
                Ok(()),
            );
            assert!(out.unwrap_err().contains("PIN entry was cancelled"));
            assert_eq!(opened, 1);
        }

        /// No device: a job waits for one, then carries on.
        #[test]
        fn a_missing_device_is_waited_for() {
            let (out, opened, waits) = supervised(
                Wait::Patient,
                vec![Err(DevError::Missing), Ok(vec![button(), signed()])],
                false,
                Ok(()),
            );
            assert!(out.is_ok(), "{out:?}");
            assert_eq!(opened, 2);
            assert_eq!(waits, vec![Until::Present]);
        }

        /// …unless the user pressed Stop waiting (or the wait ran out):
        /// whatever the wait reports is the job's error.
        #[test]
        fn a_stopped_wait_ends_the_conversation() {
            let (out, opened, _) = supervised(
                Wait::Patient,
                vec![Err(DevError::Missing)],
                false,
                Err("stopped waiting for the Trezor — nothing was changed".into()),
            );
            assert!(out.unwrap_err().contains("stopped waiting"));
            assert_eq!(opened, 1);
        }

        /// The probe and the setup dialog never wait: they report and let
        /// the user retry.
        #[test]
        fn a_brief_conversation_fails_at_once() {
            let (out, opened, waits) =
                supervised(Wait::Brief, vec![Err(DevError::Missing)], false, Ok(()));
            assert_eq!(
                out.unwrap_err(),
                "no Trezor found — plug it in, unlock it, and try again"
            );
            assert_eq!(opened, 1);
            assert!(waits.is_empty());
            let (out, opened, _) = supervised(
                Wait::Brief,
                vec![Ok(vec![button(), cancelled()])],
                true,
                Ok(()),
            );
            assert!(out.unwrap_err().contains("cancelled on the Trezor"));
            assert_eq!(opened, 1);
        }

        /// A link that fails once recovers on a fresh handle (the device
        /// was out of step, or mid-wake).
        #[test]
        fn a_link_hiccup_recovers_on_a_fresh_handle() {
            let (out, opened, waits) = supervised(
                Wait::Patient,
                vec![
                    Err(DevError::Link("Pipe error".into())),
                    Ok(vec![button(), signed()]),
                ],
                false,
                Ok(()),
            );
            assert!(out.is_ok(), "{out:?}");
            assert_eq!(opened, 2);
            assert_eq!(waits, vec![Until::Present]);
        }

        /// A link that KEEPS failing: two quick retries, then the user is
        /// asked to replug (twice at most), then the conversation fails
        /// with the reason — it never spins forever.
        #[test]
        fn a_link_that_keeps_failing_asks_for_a_replug_then_gives_up() {
            let fail = || Err(DevError::Link("Operation timed out".into()));
            let (out, opened, waits) = supervised(
                Wait::Patient,
                (0..9).map(|_| fail()).collect(),
                false,
                Ok(()),
            );
            let err = out.unwrap_err();
            assert!(err.contains("lost contact with the Trezor"), "{err}");
            assert!(err.contains("Operation timed out"), "{err}");
            assert_eq!(opened, 9);
            let replug = Until::Replugged(vec!["bus-a".to_string()]);
            assert_eq!(
                waits,
                vec![
                    Until::Present,
                    Until::Present,
                    replug.clone(),
                    Until::Present,
                    Until::Present,
                    replug,
                    Until::Present,
                    Until::Present,
                ]
            );
        }

        /// A device answering out of turn (a conversation abandoned
        /// earlier left it mid-workflow) is a link problem, not a
        /// refusal: the next handle's `Initialize` resets it.
        #[test]
        fn a_reply_out_of_step_is_retried() {
            let (out, opened, _) = supervised(
                Wait::Patient,
                vec![
                    Ok(vec![(Mt::MessageType_Features, Vec::new())]),
                    Ok(vec![button(), signed()]),
                ],
                false,
                Ok(()),
            );
            assert!(out.is_ok(), "{out:?}");
            assert_eq!(opened, 2);
        }

        #[test]
        fn device_errors_are_sorted_into_what_can_be_ridden_out() {
            use trezor_client::transport::error::Error as T;
            use trezor_client::Error as E;
            assert!(matches!(classify(E::NoDeviceFound), DevError::Missing));
            assert!(matches!(
                classify(E::TransportSendMessage(T::DeviceDisconnected)),
                DevError::Link(_)
            ));
            assert!(matches!(
                classify(E::TransportReceiveMessage(T::DeviceBadMagic)),
                DevError::Link(_)
            ));
            assert!(matches!(classify(E::DeviceNotUnique), DevError::Fatal(_)));
            // A permission refusal is final, with the udev hint on Linux.
            let denied = link_or_denied("Access denied (insufficient permissions)".into());
            match denied {
                DevError::Fatal(msg) => assert!(msg.contains("could not be opened"), "{msg}"),
                other => panic!("expected a final error, got {other:?}"),
            }
            // Another program holding the interface is named as such.
            assert!(DevError::Link("Resource busy".into())
                .message()
                .contains("another program"));
        }

        /// The wait itself. (Shares the process-global beacon with the
        /// attention test, hence the gate.)
        #[test]
        fn await_device_waits_for_the_bus_to_change() {
            let _gate = crate::trezor::attention::TEST_GATE
                .lock()
                .unwrap_or_else(|p| p.into_inner());
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
            while crate::trezor::attention::snapshot().0
                && std::time::Instant::now() < deadline
            {
                std::thread::sleep(std::time::Duration::from_millis(20));
            }
            let tick = std::time::Duration::from_millis(1);
            let limit = std::time::Duration::from_secs(5);
            let looks = std::cell::Cell::new(0u32);
            let looks = &looks;
            // A bus that is empty for the first `n` looks.
            let bus_after = |n: u32| {
                looks.set(0);
                move || {
                    looks.set(looks.get() + 1);
                    if looks.get() > n {
                        vec!["a".to_string()]
                    } else {
                        Vec::new()
                    }
                }
            };
            // Already there: no wait, no card.
            let look = bus_after(0);
            assert!(await_device(Until::Present, &look, limit, tick).is_ok());
            assert_eq!(looks.get(), 1);
            // Shows up on the third look; the card is up meanwhile.
            let seen = std::cell::Cell::new(None);
            let inner = bus_after(2);
            let look = || {
                if looks.get() == 1 {
                    seen.set(crate::trezor::attention::snapshot().2);
                }
                inner()
            };
            assert!(await_device(Until::Present, &look, limit, tick).is_ok());
            assert_eq!(seen.get(), Some("connect-device"));
            assert!(!crate::trezor::attention::snapshot().0, "the card clears");
            // A replug needs a bus that is non-empty AND different.
            let before = vec!["a".to_string()];
            let stage = std::cell::Cell::new(0u32);
            let look = || {
                stage.set(stage.get() + 1);
                match stage.get() {
                    1 | 2 => vec!["a".to_string()], // still the old address
                    3 => Vec::new(),                // unplugged
                    _ => vec!["b".to_string()],     // back, new address
                }
            };
            assert!(await_device(Until::Replugged(before), &look, limit, tick).is_ok());
            assert!(stage.get() >= 4);
            // Stop waiting ends it with its own message…
            let look = || {
                crate::trezor::waiting::stop();
                Vec::new()
            };
            let err = await_device(Until::Present, &look, limit, tick).unwrap_err();
            assert!(err.contains("stopped waiting"), "{err}");
            // …and so does the limit, with the plug-it-in message.
            let look = || Vec::new();
            let err = await_device(
                Until::Present,
                &look,
                std::time::Duration::from_millis(5),
                tick,
            )
            .unwrap_err();
            assert!(err.contains("no Trezor found"), "{err}");
        }

        /// CURRENT firmware (the live "Communication with your connected
        /// device failed" case): it loads the first 6144 bytes silently,
        /// THEN starts confirming — so button requests arrive as replies
        /// to data chunks, between later chunks, and before the
        /// signature. Every one must be acked and the stream must carry
        /// on; the old loop gave up at the first.
        #[test]
        fn data_stream_answers_confirmations_that_arrive_mid_stream() {
            let tx = payment_tx(7000);
            let (out, written) = sign_against(
                vec![
                    // request_initial_data: fill the 6144-byte buffer.
                    wants(1024),
                    wants(1024),
                    wants(1024),
                    wants(1024),
                    wants(1024),
                    // "Input data" intro — the reply to the fifth chunk.
                    button(),
                    // The rest of the calldata, then the summary screens.
                    wants(856),
                    button(),
                    button(),
                    signed(),
                ],
                &tx,
            );
            let sig = out.expect("the conversation completes");
            assert_eq!(sig.r(), U256::from_be_bytes([0x11u8; 32]));
            assert_eq!(sig.s(), U256::from_be_bytes([0x22u8; 32]));
            assert!(sig.v(), "signature_v 1 is odd parity");
            assert_eq!(streamed(&written), tx.input.to_vec(), "all calldata, in order");
            assert_eq!(
                kinds(&written),
                vec![
                    Mt::MessageType_EthereumSignTxEIP1559,
                    Mt::MessageType_EthereumTxAck,
                    Mt::MessageType_EthereumTxAck,
                    Mt::MessageType_EthereumTxAck,
                    Mt::MessageType_EthereumTxAck,
                    Mt::MessageType_EthereumTxAck,
                    Mt::MessageType_ButtonAck,
                    Mt::MessageType_EthereumTxAck,
                    Mt::MessageType_ButtonAck,
                    Mt::MessageType_ButtonAck,
                ],
            );
        }

        /// Mid-size calldata on current firmware: everything fits the
        /// device buffer, so the FIRST confirmation is the reply to the
        /// last data chunk.
        #[test]
        fn data_stream_answers_a_confirmation_after_the_last_chunk() {
            let tx = payment_tx(2500);
            let (out, written) = sign_against(
                vec![wants(1024), wants(452), button(), button(), signed()],
                &tx,
            );
            out.expect("the conversation completes");
            assert_eq!(streamed(&written), tx.input.to_vec());
        }

        /// OLDER firmware confirms first and streams afterwards — the
        /// order trezor-client's own loop was written for. Still works.
        #[test]
        fn data_stream_still_handles_confirm_first_firmware() {
            let tx = payment_tx(2500);
            let (out, written) = sign_against(
                vec![button(), button(), wants(1024), wants(452), signed()],
                &tx,
            );
            out.expect("the conversation completes");
            assert_eq!(streamed(&written), tx.input.to_vec());
        }

        /// The device sets the chunk size (it rejects more than it asked
        /// for), and a device asking past the end is refused instead of
        /// being fed empty chunks forever.
        #[test]
        fn data_stream_honours_the_requested_chunk_size() {
            let tx = payment_tx(1500);
            let (out, written) =
                sign_against(vec![wants(200), wants(276), signed()], &tx);
            out.expect("the conversation completes");
            assert_eq!(streamed(&written), tx.input.to_vec());
            let acks: Vec<usize> = written
                .iter()
                .filter(|(k, _)| *k == Mt::MessageType_EthereumTxAck)
                .map(|(k, p)| {
                    let m: protos::EthereumTxAck =
                        ProtoMessage::new(*k, p.clone()).into_message().unwrap();
                    m.data_chunk().len()
                })
                .collect();
            assert_eq!(acks, vec![200, 276]);

            let (out, _) = sign_against(vec![wants(476), wants(64)], &tx);
            let err = out.expect_err("asking past the end is refused");
            assert!(err.contains("more transaction data"), "{err}");
        }

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

    /// Device tests against Trezor's own firmware EMULATOR — the real
    /// firmware built for the desktop, driven through its debug link by
    /// `scripts/trezor-emulator/operator.py` playing the human. They
    /// cover what a fake transport cannot: what the firmware actually
    /// does when it is locked, locks itself mid-screen, or restarts.
    ///
    /// Ignored by default; `scripts/trezor-emulator/run.sh` starts the
    /// emulator (PIN 1234, passphrase protection on, 10 s auto-lock) and
    /// runs them one at a time.
    #[cfg(test)]
    mod emulator_tests {
        use super::*;
        use alloy::consensus::SignableTransaction;
        use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
        use std::sync::{Arc, Mutex};
        use std::time::Duration;

        /// Hardhat test mnemonic + passphrase "hunter2", m/44'/60'/0'/0/0.
        const ADDRESS: &str = "0x55585EFaaFc6F444A28Dce28322edf57620c88Bf";
        const PASSPHRASE: &str = "hunter2";

        fn emu_home() -> std::path::PathBuf {
            std::env::var_os("WATCHIT_TREZOR_EMU_HOME")
                .expect("run these through scripts/trezor-emulator/run.sh")
                .into()
        }

        fn harness(file: &str) -> std::path::PathBuf {
            std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../scripts/trezor-emulator")
                .join(file)
        }

        fn python(script: &str) -> std::process::Command {
            let mut cmd = std::process::Command::new(emu_home().join("venv/bin/python"));
            cmd.arg("-I").arg(harness(script));
            cmd
        }

        fn ctl(args: &[&str]) {
            let out = python("ctl.py").args(args).output().expect("ctl.py runs");
            println!("ctl {args:?}: {}", String::from_utf8_lossy(&out.stdout).trim());
        }

        /// A freshly set-up device (unlocked, PIN 1234, passphrase
        /// protection, 10 s auto-lock), whatever the last test left.
        fn fresh_device() {
            ctl(&["setup", "10"]);
        }

        /// `run.sh stop` / `run.sh start`: unplug / plug the device.
        fn emulator(verb: &str) {
            let _ = std::process::Command::new(harness("run.sh")).arg(verb).status();
        }

        /// The human at the device, for as long as this lives.
        struct Operator(std::process::Child);

        impl Drop for Operator {
            fn drop(&mut self) {
                let _ = self.0.kill();
                let _ = self.0.wait();
            }
        }

        fn operator(args: &[&str]) -> Operator {
            Operator(
                python("operator.py")
                    .arg("300")
                    .args(args)
                    .spawn()
                    .expect("operator.py starts"),
            )
        }

        /// The app's half: answers the passphrase card the way the user
        /// would, and records every action the beacon announces, in
        /// order — what the prompt cards would have shown.
        struct App {
            stop: Arc<AtomicBool>,
            seen: Arc<Mutex<Vec<&'static str>>>,
            passphrases: Arc<AtomicUsize>,
            thread: Option<std::thread::JoinHandle<()>>,
        }

        impl App {
            fn start() -> Self {
                super::super::host_passphrase::set(true);
                let stop = Arc::new(AtomicBool::new(false));
                let seen = Arc::new(Mutex::new(Vec::new()));
                let passphrases = Arc::new(AtomicUsize::new(0));
                let (s, v, p) = (stop.clone(), seen.clone(), passphrases.clone());
                let thread = std::thread::spawn(move || {
                    let mut last_seq = 0;
                    while !s.load(Ordering::Relaxed) {
                        let (active, seq, action) = super::super::attention::snapshot();
                        if active && seq != last_seq {
                            last_seq = seq;
                            v.lock().unwrap().push(action.unwrap());
                        }
                        if super::super::passphrase::pending()
                            && super::super::passphrase::deliver(PASSPHRASE.into())
                        {
                            p.fetch_add(1, Ordering::Relaxed);
                        }
                        std::thread::sleep(Duration::from_millis(40));
                    }
                });
                Self { stop, seen, passphrases, thread: Some(thread) }
            }

            fn seen(&self) -> Vec<&'static str> {
                self.seen.lock().unwrap().clone()
            }

            fn passphrases(&self) -> usize {
                self.passphrases.load(Ordering::Relaxed)
            }
        }

        impl Drop for App {
            fn drop(&mut self) {
                self.stop.store(true, Ordering::Relaxed);
                if let Some(t) = self.thread.take() {
                    let _ = t.join();
                }
            }
        }

        /// `wanted` appear in `seen` in that order (other actions may sit
        /// in between).
        fn in_order(seen: &[&str], wanted: &[&str]) -> bool {
            let mut it = seen.iter();
            wanted.iter().all(|w| it.any(|s| s == w))
        }

        /// A payment-shaped transaction: a contract call with calldata.
        fn payment(nonce: u64) -> (TxEip1559, alloy::primitives::B256) {
            payment_with(nonce, 200)
        }

        fn payment_with(nonce: u64, calldata: usize) -> (TxEip1559, alloy::primitives::B256) {
            let tx = TxEip1559 {
                chain_id: 42161,
                nonce,
                gas_limit: 300_000,
                max_fee_per_gas: 20_000_000,
                max_priority_fee_per_gas: 1,
                to: TxKind::Call(Address::repeat_byte(0xAB)),
                value: U256::ZERO,
                access_list: Default::default(),
                input: (0..calldata).map(|i| (i % 251) as u8).collect::<Vec<u8>>().into(),
            };
            let hash = tx.signature_hash();
            (tx, hash)
        }

        fn wallet() -> Address {
            ADDRESS.parse().unwrap()
        }

        /// A job that starts on a LOCKED device: the app says "unlock
        /// your Trezor" while the device shows its PIN pad, the
        /// passphrase is asked once, and the session opens — nothing
        /// fails.
        #[tokio::test(flavor = "multi_thread")]
        #[ignore]
        async fn emu_a_job_opens_its_session_on_a_locked_device() {
            fresh_device();
            ctl(&["lock"]);
            let app = App::start();
            let _human = operator(&["--pin-after=2"]);
            let session = begin_job_session(ADDRESS).await;
            assert!(session.is_ok(), "{:?}", session.err());
            let seen = app.seen();
            println!("beacon: {seen:?}");
            // (The opening "unlock-wallet" gives way to the PIN pad
            // within milliseconds; it is back once the PIN is in.)
            assert!(
                in_order(&seen, &["unlock-device", "enter-passphrase", "unlock-wallet"]),
                "{seen:?}"
            );
            assert_eq!(app.passphrases(), 1);
        }

        /// THE LIVE FAILURE: a payment confirmation left on the screen
        /// until the device auto-locks. The firmware closes the screen
        /// and answers "cancelled"; the job used to fail right there.
        /// Now the device is asked again — PIN pad, then the same
        /// confirmation — and the payment gets signed.
        #[tokio::test(flavor = "multi_thread")]
        #[ignore]
        async fn emu_a_confirmation_cut_off_by_auto_lock_comes_back() {
            fresh_device();
            let app = App::start();
            let _session = {
                let _human = operator(&[]);
                begin_job_session(ADDRESS).await.expect("session opens")
            };
            // Nobody touches the first payment screen for 14 s; the
            // device locks itself after 10.
            let _human = operator(&["--hold-first=14"]);
            let (tx, hash) = payment(1);
            let sig = sign_payment_job(wallet(), OwnedTx::Eip1559(tx), hash).await;
            let seen = app.seen();
            println!("beacon: {seen:?}");
            let sig = sig.expect("the payment is signed after the unlock");
            assert!(super::super::verify_payment_signature(&hash, &sig, wallet()).is_ok());
            assert!(
                in_order(&seen, &["sign-payment", "unlock-device", "sign-payment"]),
                "{seen:?}"
            );
            assert_eq!(app.passphrases(), 1, "the session survives the lock");
        }

        /// The usual long upload: the device locks itself while the app
        /// is busy encrypting and quoting, and is locked when the payment
        /// arrives. PIN pad, then the confirmation — and the passphrase
        /// is not asked again (the session outlives a lock).
        #[tokio::test(flavor = "multi_thread")]
        #[ignore]
        async fn emu_a_device_that_locked_while_idle_signs_after_its_pin() {
            fresh_device();
            let app = App::start();
            let _human = operator(&[]);
            let _session = begin_job_session(ADDRESS).await.expect("session opens");
            tokio::time::sleep(Duration::from_secs(13)).await;
            let (tx, hash) = payment(2);
            let sig = sign_payment_job(wallet(), OwnedTx::Eip1559(tx), hash)
                .await
                .expect("signed");
            assert!(super::super::verify_payment_signature(&hash, &sig, wallet()).is_ok());
            let seen = app.seen();
            println!("beacon: {seen:?}");
            assert!(in_order(&seen, &["unlock-device", "sign-payment"]), "{seen:?}");
            assert_eq!(app.passphrases(), 1);
        }

        /// The device vanishes mid-job (unplugged) and comes back: the
        /// job waits with "reconnect your Trezor" instead of failing,
        /// adopts the device's new session (a restarted device forgets
        /// them all), asks for the passphrase once more, and signs.
        ///
        /// On a device WITHOUT a PIN: a PIN-protected Trezor stays off
        /// USB after power-up until its PIN is entered at its boot
        /// screen (firmware `main.py` opens USB after `boot`), and the
        /// emulator's boot screen cannot be reached by the debug link.
        /// To the job that boot-screen wait is simply more of the same
        /// "no device yet" this test covers.
        #[tokio::test(flavor = "multi_thread")]
        #[ignore]
        async fn emu_a_replugged_device_is_waited_for() {
            ctl(&["setup", "10", "nopin"]);
            let app = App::start();
            let _human = operator(&[]);
            let _session = begin_job_session(ADDRESS).await.expect("session opens");
            emulator("stop");
            let back = std::thread::spawn(|| {
                std::thread::sleep(Duration::from_secs(5));
                emulator("start");
            });
            let (tx, hash) = payment(3);
            let sig = sign_payment_job(wallet(), OwnedTx::Eip1559(tx), hash).await;
            back.join().unwrap();
            let seen = app.seen();
            println!("beacon: {seen:?}");
            let sig = sig.expect("signed after the device came back");
            assert!(super::super::verify_payment_signature(&hash, &sig, wallet()).is_ok());
            assert!(
                in_order(&seen, &["connect-device", "enter-passphrase", "sign-payment"]),
                "{seen:?}"
            );
            assert_eq!(app.passphrases(), 2, "a restarted device forgets its sessions");
        }

        /// A pooled batch payment carries several KB of calldata, which
        /// the firmware loads in chunks and confirms part-way through
        /// (the "Communication with your connected device failed" case
        /// of alpha.129-test7): every chunk request and every screen in
        /// between is answered, and the signature verifies.
        #[tokio::test(flavor = "multi_thread")]
        #[ignore]
        async fn emu_a_batch_sized_payment_streams_its_calldata() {
            fresh_device();
            let _app = App::start();
            let _human = operator(&[]);
            let _session = begin_job_session(ADDRESS).await.expect("session opens");
            let (tx, hash) = payment_with(5, 7000);
            let sig = sign_payment_job(wallet(), OwnedTx::Eip1559(tx), hash)
                .await
                .expect("signed");
            assert!(super::super::verify_payment_signature(&hash, &sig, wallet()).is_ok());
        }

        /// Cancel pressed ON the device, with the device unlocked, is the
        /// user's decision: final, never re-asked.
        #[tokio::test(flavor = "multi_thread")]
        #[ignore]
        async fn emu_a_cancel_on_the_device_is_final() {
            fresh_device();
            let _app = App::start();
            let _session = {
                let _human = operator(&[]);
                begin_job_session(ADDRESS).await.expect("session opens")
            };
            let _human = operator(&["--refuse-first"]);
            let (tx, hash) = payment(4);
            let err = sign_payment_job(wallet(), OwnedTx::Eip1559(tx), hash)
                .await
                .unwrap_err();
            assert!(err.contains("cancelled on the Trezor"), "{err}");
        }

        /// The whole setup ceremony on the real firmware: two identity
        /// signatures that match, and the address shown on the device.
        #[tokio::test(flavor = "multi_thread")]
        #[ignore]
        async fn emu_the_setup_ceremony_runs_end_to_end() {
            fresh_device();
            let app = App::start();
            let _human = operator(&[]);
            let identity = setup_ceremony().await.expect("ceremony completes");
            assert_eq!(identity.address.to_lowercase(), ADDRESS.to_lowercase());
            let seen = app.seen();
            println!("beacon: {seen:?}");
            assert!(in_order(&seen, &["sign-identity", "confirm-address"]), "{seen:?}");
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

    /// The attention beacon: begin publishes, drop clears, an OLDER
    /// guard's drop never erases a NEWER action out from under the
    /// poller, and a step that ends INSIDE another hands the beacon back
    /// to the outer one under a fresh seq (the app announces it again).
    /// (Shares the process-global state with the await-device test —
    /// hence the gate.)
    #[test]
    fn attention_tracks_and_clears_actions() {
        let _gate = attention::TEST_GATE.lock().unwrap_or_else(|p| p.into_inner());
        // Other tests start hardware-wallet jobs that hold the beacon for
        // the moment it takes to find no device — let those pass first.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while attention::snapshot().0 && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
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
        let (active, seq3, action) = attention::snapshot();
        assert!(active, "the stale guard must not clear the newer action");
        assert_eq!(action, Some("confirm-address"));
        assert_eq!(seq3, seq2, "and must not re-announce it either");
        drop(second);
        let (active, _, action) = attention::snapshot();
        assert!(!active);
        assert_eq!(action, None);

        // Nested: a payment that first waits for the device to be
        // unlocked. When the unlock ends, the payment is what the device
        // waits on again — re-announced, not silently dropped.
        let payment = attention::begin("sign-payment");
        let (_, seq_payment, _) = attention::snapshot();
        let unlock = attention::begin("unlock-device");
        assert_eq!(attention::snapshot().2, Some("unlock-device"));
        drop(unlock);
        let (active, seq_back, action) = attention::snapshot();
        assert!(active);
        assert_eq!(action, Some("sign-payment"));
        assert!(seq_back > seq_payment, "the outer step is announced afresh");
        drop(payment);
        assert!(!attention::snapshot().0);
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

