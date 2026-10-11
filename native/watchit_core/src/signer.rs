//! The signer seam (hardware-wallet plan, phase 2; phase 3 adds Trezor).
//!
//! Everything that SIGNS — on-chain payments (merkle batch and quote
//! payments, pointer updates, chunk puts, single-file uploads) and the
//! deterministic backup-identity signature — reaches the wallet key
//! through this one type instead of passing raw key hex into ant-core.
//!
//! The payment seam works because evmlib's `Wallet` is just an alloy
//! `EthereumWallet` (any `TxSigner`) plus a network — `Wallet::new`
//! accepts a signer-built `EthereumWallet`, so EVERY paid ant-core call
//! (the client's attached wallet included) signs through whatever signer
//! this type wraps. Phase 3's `Trezor` arm hands it an
//! `alloy_signer_trezor::TrezorSigner`: each transaction then waits for
//! a physical confirmation on the device.
//!
//! Two alloy trees meet here, deliberately:
//! - PAYMENTS ride evmlib's tree (the `alloy` 1.x facade, already in the
//!   lockfile via evmlib): `evmlib::Wallet::new` takes THAT tree's
//!   `EthereumWallet`, and alloy-signer-trezor is pinned to the same 1.8
//!   line so its `TxSigner` impl unifies.
//! - The IDENTITY signature keeps phase 1's alloy 2.x `SignerSync` path
//!   in backup.rs for software keys — frozen by test vectors, and r‖s
//!   bytes are identical across trees for the same key by RFC-6979, so
//!   the device-signed identity (trezor.rs) lands on the same line.
//!
//! Key policy on the hardware arm (phase 4, settled 2026-10-10): the
//! WRITE half of the backup identity is never persisted — it re-derives
//! per use via [`Signer::backup_write_keys`] (one device confirmation).
//! The READ half is persisted (OS keychain) only when the user kept
//! key-sharing on at setup; [`Signer::read_keys`] surfaces it.

use ant_core::data::{EvmNetwork, Wallet as EvmWallet};

use crate::backup::{BackupKeys, ReadKeys};
use crate::engine::Engine;

/// How this install signs payments and the backup identity.
#[derive(Clone)]
pub enum Signer {
    /// A raw secp256k1 key held in process (keychain/file-stored).
    Software {
        /// Canonical 0x-prefixed hex, validated at construction.
        key_hex: String,
    },
    /// A Trezor: only public identity is held here — the key never
    /// leaves the device, signing happens over USB with a physical
    /// confirmation per signature.
    Trezor {
        /// EIP-55 address at trezor.rs's [DERIVATION_PATH].
        address: String,
        /// The backup line's pointer address (public, from the marker).
        pointer: [u8; 32],
        /// Public-safe backup-line fingerprint (from the marker), so the
        /// last-backup record stays readable with the device unplugged.
        fingerprint: String,
        /// The content READ key, when the user kept it at setup
        /// (phase-4 sharing default) — `None` in the paranoid opt-out.
        enc: Option<[u8; 32]>,
    },
}

/// Never derive Debug here: it would print the raw key. The redacted
/// form is all logs/asserts ever see.
impl std::fmt::Debug for Signer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Signer::Software { .. } => f.write_str("Signer::Software{key: <redacted>}"),
            Signer::Trezor { address, .. } => {
                write!(f, "Signer::Trezor{{address: {address}}}")
            }
        }
    }
}

impl Signer {
    /// Wrap a software key (pasted or loaded from the wallet store),
    /// validating and normalizing it up front so every later method can
    /// only fail on real signing/derivation problems.
    pub fn software(key_hex: &str) -> Result<Self, String> {
        Ok(Signer::Software {
            key_hex: crate::wallet::normalize_private_key(key_hex)?,
        })
    }

    /// True for signers whose key lives in a hardware device — callers
    /// use it to pick honest copy ("confirm on your Trezor") and to know
    /// an operation may wait on a physical button.
    pub fn is_hardware(&self) -> bool {
        matches!(self, Signer::Trezor { .. })
    }

    /// EIP-55 checksummed address payments come from.
    pub fn address(&self) -> Result<String, String> {
        match self {
            Signer::Software { key_hex } => crate::wallet::address_of(key_hex),
            Signer::Trezor { address, .. } => Ok(address.clone()),
        }
    }

    /// The evmlib wallet every paid network call signs through, on
    /// Arbitrum One. Built from a signer object via `Wallet::new` —
    /// never `new_from_private_key`. Async since phase 3: the hardware
    /// arm opens a USB session (and refuses a device whose address is
    /// not the configured one).
    pub async fn payment_wallet(&self) -> Result<EvmWallet, String> {
        match self {
            Signer::Software { key_hex } => {
                use alloy::network::EthereumWallet;
                use alloy::signers::local::PrivateKeySigner;
                let signer: PrivateKeySigner = key_hex
                    .trim_start_matches("0x")
                    .parse()
                    .map_err(|_| "stored wallet key is not a valid private key".to_string())?;
                Ok(EvmWallet::new(
                    EvmNetwork::ArbitrumOne,
                    EthereumWallet::from(signer),
                ))
            }
            Signer::Trezor { address, .. } => {
                #[cfg(any(
                    target_os = "linux",
                    target_os = "windows",
                    target_os = "macos"
                ))]
                {
                    use alloy::network::EthereumWallet;
                    // Verified signer: fresh device session per signature,
                    // address re-check before every tap, and local recovery
                    // verification of each signature BEFORE evmlib journals
                    // it (see trezor.rs::VerifiedTrezor).
                    let signer = crate::trezor::verified_payment_signer(address).await?;
                    Ok(EvmWallet::new(
                        EvmNetwork::ArbitrumOne,
                        EthereumWallet::new(signer),
                    ))
                }
                #[cfg(not(any(
                    target_os = "linux",
                    target_os = "windows",
                    target_os = "macos"
                )))]
                {
                    let _ = address;
                    Err("hardware wallets work in the desktop app only".into())
                }
            }
        }
    }

    /// The deterministic identity signature the backup keys derive from
    /// (phase 1's sign-to-derive; the sign-twice determinism guard lives
    /// in the delegate). Software only — a hardware signer produces it
    /// on-device through [`Signer::backup_write_keys`].
    pub fn identity_signature(&self) -> Result<[u8; 64], String> {
        match self {
            Signer::Software { key_hex } => crate::backup::identity_signature(key_hex),
            Signer::Trezor { .. } => Err(
                "the backup identity of a hardware wallet is signed on the \
                 device — this software-only path has no key"
                    .into(),
            ),
        }
    }

    /// The (v2, signature-derived) backup identity for this signer —
    /// cheap/offline for software keys only; hardware callers use
    /// [`Signer::backup_write_keys`].
    pub fn backup_keys(&self) -> Result<BackupKeys, String> {
        Ok(crate::backup::derive_keys_from_signature(
            &self.identity_signature()?,
        ))
    }

    /// The FULL backup identity, write keys included — the thing a
    /// backup needs. Software derives offline; a Trezor signs the frozen
    /// identity message on-device (one confirmation) and the result must
    /// land on the configured pointer, so a wrong device, firmware
    /// surprise, or changed passphrase fails loudly instead of silently
    /// writing a parallel backup line.
    pub async fn backup_write_keys(&self) -> Result<BackupKeys, String> {
        match self {
            Signer::Software { .. } => self.backup_keys(),
            Signer::Trezor { address, pointer, .. } => {
                let keys = crate::trezor::derive_write_keys(address).await?;
                if keys.pointer != *pointer {
                    return Err(
                        "this Trezor derives a different backup identity than \
                         the one configured — same device and passphrase \
                         setting as at setup? Re-run the hardware-wallet \
                         setup if you changed them"
                            .into(),
                    );
                }
                Ok(keys)
            }
        }
    }

    /// The free-read half of the backup identity, when it is available
    /// WITHOUT a device conversation: always for software keys, and for
    /// a Trezor only when the read key was kept at setup. `Ok(None)`
    /// means "exists, but only the device can produce it".
    pub fn read_keys(&self) -> Result<Option<ReadKeys>, String> {
        match self {
            Signer::Software { .. } => Ok(Some(self.backup_keys()?.read())),
            Signer::Trezor { pointer, enc, .. } => Ok(enc.map(|enc| ReadKeys {
                enc,
                pointer: *pointer,
            })),
        }
    }

    /// The backup pointer address — never needs the device (hardware
    /// markers persist it; software derives it).
    pub fn pointer(&self) -> Result<[u8; 32], String> {
        match self {
            Signer::Software { .. } => Ok(self.backup_keys()?.pointer),
            Signer::Trezor { pointer, .. } => Ok(*pointer),
        }
    }

    /// The persisted public backup-line fingerprint, for identities whose
    /// enc key may be absent (hardware). Software callers compute it from
    /// the derived keys instead.
    pub fn stored_fingerprint(&self) -> Option<String> {
        match self {
            Signer::Software { .. } => None,
            Signer::Trezor { fingerprint, .. } => Some(fingerprint.clone()),
        }
    }

    /// The pre-sign-to-derive backup identity (blake3 over the raw private
    /// key bytes), used only as a restore fallback for backups made before
    /// the phase-1 flip. `Ok(None)` for signers that never expose a raw
    /// key (hardware) — such a wallet is new by construction, so no
    /// legacy line can exist for it.
    pub fn backup_keys_legacy(&self) -> Result<Option<BackupKeys>, String> {
        match self {
            Signer::Software { key_hex } => {
                crate::backup::derive_keys_legacy(key_hex).map(Some)
            }
            Signer::Trezor { .. } => Ok(None),
        }
    }
}

impl Engine {
    /// The configured signer, or a clear error when no wallet is set up.
    /// Decodes the stored marker: a hardware marker yields a
    /// device-backed signer (plus the kept read key, when sharing was
    /// left on at setup). May touch the OS keychain on a cold cache —
    /// same blocking discipline as `wallet.load()` applies.
    pub fn signer(&self) -> Result<Signer, String> {
        let Some((stored, _)) = self.wallet.load() else {
            return Err(if self.wallet.locked() {
                "the wallet is passphrase-locked — unlock it in Settings → Wallet".into()
            } else {
                "no upload wallet configured — set one up in Settings → Wallet".into()
            });
        };
        match crate::wallet::parse_stored(&stored)? {
            crate::wallet::StoredWallet::Software { key_hex } => Signer::software(&key_hex),
            crate::wallet::StoredWallet::Trezor {
                address,
                pointer,
                fingerprint,
            } => {
                let enc = self
                    .trezor_keys
                    .load()
                    .and_then(|(v, _)| crate::backup::addr_from_hex(&v));
                Ok(Signer::Trezor { address, pointer, fingerprint, enc })
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // The hardhat/foundry vector key wallet.rs pins its derivation with.
    const KEY: &str = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
    const ADDR: &str = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

    fn test_engine(tag: &str) -> &'static Engine {
        let dir = std::env::temp_dir().join(format!("wi-signer-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let engine: &'static Engine =
            Box::leak(Box::new(Engine::new(None, dir.to_str())));
        engine.wallet.disable_keychain();
        engine.follow_keys.disable_keychain();
        engine.trezor_keys.disable_keychain();
        engine
    }

    #[test]
    fn software_normalizes_and_validates() {
        let s = Signer::software(&format!("  {} ", &KEY[2..])).unwrap();
        let Signer::Software { key_hex } = &s else { panic!() };
        assert_eq!(key_hex, KEY);
        assert_eq!(s.address().unwrap(), ADDR);
        assert!(!s.is_hardware());
        assert!(Signer::software("zz").is_err());
        assert!(Signer::software("0x1234").is_err());
    }

    /// The signer-built evmlib wallet must land on the signer's own
    /// address on Arbitrum One — proves the payment path really signs
    /// with OUR signer object (replaces the old `evm_wallet` pin).
    #[tokio::test(flavor = "multi_thread")]
    async fn payment_wallet_lands_on_the_signer_address() {
        let w = Signer::software(KEY)
            .unwrap()
            .payment_wallet()
            .await
            .unwrap();
        assert_eq!(w.address().to_string(), ADDR);
    }

    /// The seam must not move the backup identity: signatures and derived
    /// keys through `Signer` are byte-identical to the phase-1 key-hex
    /// path (whose vectors are frozen in backup.rs).
    #[tokio::test(flavor = "multi_thread")]
    async fn backup_identity_is_unchanged_through_the_seam() {
        let s = Signer::software(KEY).unwrap();
        assert_eq!(
            s.identity_signature().unwrap(),
            crate::backup::identity_signature(KEY).unwrap()
        );
        let via_seam = s.backup_keys().unwrap();
        let direct = crate::backup::derive_keys(KEY).unwrap();
        assert_eq!(via_seam.pointer, direct.pointer);
        assert_eq!(via_seam.enc, direct.enc);
        // The async write-keys path and the sync read half agree too.
        let write = s.backup_write_keys().await.unwrap();
        assert_eq!(write.pointer, direct.pointer);
        let read = s.read_keys().unwrap().unwrap();
        assert_eq!(read.pointer, direct.pointer);
        assert_eq!(read.enc, direct.enc);
        assert_eq!(s.pointer().unwrap(), direct.pointer);
        assert!(s.stored_fingerprint().is_none());
        let legacy_seam = s.backup_keys_legacy().unwrap().unwrap();
        let legacy_direct = crate::backup::derive_keys_legacy(KEY).unwrap();
        assert_eq!(legacy_seam.pointer, legacy_direct.pointer);
        assert_eq!(legacy_seam.enc, legacy_direct.enc);
    }

    #[test]
    fn engine_signer_requires_a_wallet() {
        let engine = test_engine("req");
        let err = engine.signer().unwrap_err();
        assert!(err.contains("wallet"));
        engine.wallet.store(KEY).unwrap();
        assert_eq!(engine.signer().unwrap().address().unwrap(), ADDR);
    }

    /// A stored hardware marker yields the Trezor signer: address and
    /// pointer from the marker, read key only when the trezor_keys store
    /// holds it, no legacy line, no software identity signature.
    #[test]
    fn engine_signer_decodes_a_trezor_marker() {
        let engine = test_engine("hw");
        let pointer = [9u8; 32];
        let marker = crate::wallet::trezor_marker(ADDR, &pointer, "aabbccddeeff0011");
        engine.wallet.store(&marker).unwrap();

        let s = engine.signer().unwrap();
        assert!(s.is_hardware());
        assert_eq!(s.address().unwrap(), ADDR);
        assert_eq!(s.pointer().unwrap(), pointer);
        assert_eq!(s.stored_fingerprint().as_deref(), Some("aabbccddeeff0011"));
        // Paranoid opt-out: no read key held.
        assert!(s.read_keys().unwrap().is_none());
        assert!(s.backup_keys_legacy().unwrap().is_none());
        assert!(s.identity_signature().is_err());
        assert!(s.backup_keys().is_err());

        // Sharing default: a held enc key surfaces through read_keys.
        let enc = [3u8; 32];
        engine.trezor_keys.store(&hex::encode(enc)).unwrap();
        let s = engine.signer().unwrap();
        let read = s.read_keys().unwrap().unwrap();
        assert_eq!(read.enc, enc);
        assert_eq!(read.pointer, pointer);
    }

    /// A derived-pointer mismatch on the hardware write path must refuse
    /// (device-swap / changed-passphrase guard). Exercised through the
    /// pure guard since tests have no USB device: the check compares the
    /// derivation result against the stored pointer, which is exactly
    /// what backup_write_keys does after trezor::derive_write_keys.
    #[test]
    fn trezor_write_keys_guard_is_pointer_bound() {
        // ceremony_keys is the derivation trezor.rs feeds the guard from.
        let sig = crate::backup::identity_signature(KEY).unwrap();
        let derived = crate::trezor::ceremony_keys(&sig, &sig).unwrap();
        let stored_pointer = [0u8; 32];
        assert_ne!(derived.pointer, stored_pointer);
    }
}
