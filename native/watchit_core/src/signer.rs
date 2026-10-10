//! The signer seam (hardware-wallet plan, phase 2).
//!
//! Everything that SIGNS — on-chain payments (merkle batch and quote
//! payments, pointer updates, chunk puts, single-file uploads) and the
//! deterministic backup-identity signature — reaches the wallet key
//! through this one type instead of passing raw key hex into ant-core.
//! Phase 3 adds a hardware variant (Trezor over USB): a new match arm in
//! each method here, zero changes at the payment/backup call sites.
//!
//! The payment seam works because evmlib's `Wallet` is just an alloy
//! `EthereumWallet` (any `TxSigner`) plus a network — `Wallet::new`
//! accepts a signer-built `EthereumWallet`, so EVERY paid ant-core call
//! (the client's attached wallet included) signs through whatever signer
//! this type wraps. No external prepare/finalize plumbing is needed.
//!
//! Two alloy trees meet here, deliberately:
//! - PAYMENTS ride evmlib's tree (the `alloy` 1.x facade, already in the
//!   lockfile via evmlib): `evmlib::Wallet::new` takes THAT tree's
//!   `EthereumWallet`. Phase 3's hardware signer must come from the same
//!   line (alloy-signer-trezor 1.8.x, NOT the 2.4.x one) or its
//!   `TxSigner` impl won't unify.
//! - The IDENTITY signature keeps phase 1's alloy 2.x `SignerSync` path
//!   in backup.rs — frozen by test vectors, and r‖s bytes are identical
//!   across trees for the same key by RFC-6979.

use ant_core::data::{EvmNetwork, Wallet as EvmWallet};

use crate::backup::BackupKeys;
use crate::engine::Engine;

/// How this install signs payments and the backup identity. Today always
/// the stored software key; phase 3 adds `Trezor { ... }`.
#[derive(Clone)]
pub enum Signer {
    /// A raw secp256k1 key held in process (keychain/file-stored).
    Software {
        /// Canonical 0x-prefixed hex, validated at construction.
        key_hex: String,
    },
}

/// Never derive Debug here: it would print the raw key. The redacted
/// form is all logs/asserts ever see.
impl std::fmt::Debug for Signer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Signer::Software { .. } => f.write_str("Signer::Software{key: <redacted>}"),
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

    /// EIP-55 checksummed address payments come from.
    pub fn address(&self) -> Result<String, String> {
        match self {
            Signer::Software { key_hex } => crate::wallet::address_of(key_hex),
        }
    }

    /// The evmlib wallet every paid network call signs through, on
    /// Arbitrum One. Built from a signer object via `Wallet::new` —
    /// never `new_from_private_key` — so a hardware variant is a new
    /// match arm here, not a new payment path.
    pub fn payment_wallet(&self) -> Result<EvmWallet, String> {
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
        }
    }

    /// The deterministic identity signature the backup keys derive from
    /// (phase 1's sign-to-derive; the sign-twice determinism guard lives
    /// in the delegate). A hardware variant signs the same frozen message
    /// on-device and lands on the same identity for the same 12 words.
    pub fn identity_signature(&self) -> Result<[u8; 64], String> {
        match self {
            Signer::Software { key_hex } => crate::backup::identity_signature(key_hex),
        }
    }

    /// The (v2, signature-derived) backup identity for this signer.
    pub fn backup_keys(&self) -> Result<BackupKeys, String> {
        Ok(crate::backup::derive_keys_from_signature(
            &self.identity_signature()?,
        ))
    }

    /// The pre-sign-to-derive backup identity (blake3 over the raw key
    /// bytes), used only as a restore fallback for backups made before
    /// the phase-1 flip. `Ok(None)` for signers that never expose a raw
    /// key (hardware, phase 3) — such a wallet is new by construction,
    /// so no legacy line can exist for it.
    pub fn backup_keys_legacy(&self) -> Result<Option<BackupKeys>, String> {
        match self {
            Signer::Software { key_hex } => {
                crate::backup::derive_keys_legacy(key_hex).map(Some)
            }
        }
    }
}

impl Engine {
    /// The configured signer, or a clear error when no wallet is set up.
    /// Today this always wraps the stored software key; phase 3 reads
    /// the signer kind from config and may return a hardware-backed
    /// variant instead. May touch the OS keychain on a cold cache —
    /// same blocking discipline as `wallet.load()` applies.
    pub fn signer(&self) -> Result<Signer, String> {
        let (key, _) = self
            .wallet
            .load()
            .ok_or("no upload wallet configured — set one up in Settings → Wallet")?;
        Signer::software(&key)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // The hardhat/foundry vector key wallet.rs pins its derivation with.
    const KEY: &str = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
    const ADDR: &str = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

    #[test]
    fn software_normalizes_and_validates() {
        let s = Signer::software(&format!("  {} ", &KEY[2..])).unwrap();
        let Signer::Software { key_hex } = &s;
        assert_eq!(key_hex, KEY);
        assert_eq!(s.address().unwrap(), ADDR);
        assert!(Signer::software("zz").is_err());
        assert!(Signer::software("0x1234").is_err());
    }

    /// The signer-built evmlib wallet must land on the signer's own
    /// address on Arbitrum One — proves the payment path really signs
    /// with OUR signer object (replaces the old `evm_wallet` pin).
    #[test]
    fn payment_wallet_lands_on_the_signer_address() {
        let w = Signer::software(KEY).unwrap().payment_wallet().unwrap();
        assert_eq!(w.address().to_string(), ADDR);
    }

    /// The seam must not move the backup identity: signatures and derived
    /// keys through `Signer` are byte-identical to the phase-1 key-hex
    /// path (whose vectors are frozen in backup.rs).
    #[test]
    fn backup_identity_is_unchanged_through_the_seam() {
        let s = Signer::software(KEY).unwrap();
        assert_eq!(
            s.identity_signature().unwrap(),
            crate::backup::identity_signature(KEY).unwrap()
        );
        let via_seam = s.backup_keys().unwrap();
        let direct = crate::backup::derive_keys(KEY).unwrap();
        assert_eq!(via_seam.pointer, direct.pointer);
        assert_eq!(via_seam.enc, direct.enc);
        let legacy_seam = s.backup_keys_legacy().unwrap().unwrap();
        let legacy_direct = crate::backup::derive_keys_legacy(KEY).unwrap();
        assert_eq!(legacy_seam.pointer, legacy_direct.pointer);
        assert_eq!(legacy_seam.enc, legacy_direct.enc);
    }

    #[test]
    fn engine_signer_requires_a_wallet() {
        let dir = std::env::temp_dir().join(format!("wi-signer-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let engine = Engine::new(None, dir.to_str());
        engine.wallet.disable_keychain();
        engine.follow_keys.disable_keychain();
        let err = engine.signer().unwrap_err();
        assert!(err.contains("wallet"));
        engine.wallet.store(KEY).unwrap();
        assert_eq!(engine.signer().unwrap().address().unwrap(), ADDR);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
