//! Internal upload wallet: key storage, BIP-39 derivation, balances.
//!
//! The private key lives in the OS keychain (Secret Service / Windows
//! Credential Manager / macOS Keychain) when one is available, else in a
//! mode-0600 file under the app data dir — some Linux setups (headless,
//! minimal WMs) have no Secret Service daemon, and refusing to work there
//! would strand exactly the users the AppImage exists for. The backend in
//! use is reported to the UI so a file-stored key is never silently
//! "secure". The mnemonic is never stored anywhere: generation returns it
//! once for the paper-backup ceremony, only the derived key persists.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::RwLock;

use ant_core::data::{EvmNetwork, Wallet as EvmWallet};

const KEYCHAIN_SERVICE: &str = "watchit";
const KEYCHAIN_USER: &str = "upload-wallet";

/// Keychain entry / fallback file for the channel signing key (channels.rs
/// reuses this store wholesale — same backends, same threading rules).
pub const CHANNEL_KEYCHAIN_USER: &str = "channel-key";
pub const CHANNEL_KEY_FILE: &str = "channel.key";

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Storage {
    Keychain,
    File,
}

impl Storage {
    pub fn as_str(self) -> &'static str {
        match self {
            Storage::Keychain => "keychain",
            Storage::File => "file",
        }
    }
}

pub struct WalletStore {
    /// Fallback key file (`wallet.key` in the data dir); `None` when the
    /// engine runs without a data dir (devserver/tests) — keychain-only.
    file_path: Option<PathBuf>,
    /// Keychain entry name — the upload wallet and the channel key are
    /// separate entries in the same keychain service.
    keychain_user: &'static str,
    /// Whether the OS keychain is tried at all. Off in tests so `cargo
    /// test` can never write into a developer's real keychain.
    use_keychain: AtomicBool,
    cached: RwLock<Option<(String, Storage)>>,
}

impl WalletStore {
    pub fn new(data_dir: Option<&str>, use_keychain: bool) -> Self {
        Self::named(data_dir, use_keychain, KEYCHAIN_USER, "wallet.key")
    }

    /// A store for a different secret under the same service (the
    /// channel signing key lives beside the wallet key, never in it).
    pub fn named(
        data_dir: Option<&str>,
        use_keychain: bool,
        keychain_user: &'static str,
        file_name: &str,
    ) -> Self {
        Self {
            file_path: data_dir
                .filter(|d| !d.trim().is_empty())
                .map(|d| PathBuf::from(d).join(file_name)),
            keychain_user,
            use_keychain: AtomicBool::new(use_keychain),
            cached: RwLock::new(None),
        }
    }

    /// Force the file backend (tests must never touch a real keychain).
    pub fn disable_keychain(&self) {
        self.use_keychain.store(false, Ordering::SeqCst);
    }

    /// The stored key (0x-prefixed hex) and where it lives, if configured.
    pub fn load(&self) -> Option<(String, Storage)> {
        if let Some(hit) = self.cached.read().unwrap().clone() {
            return Some(hit);
        }
        let found = self
            .keychain_get()
            .map(|k| (k, Storage::Keychain))
            .or_else(|| self.file_get().map(|k| (k, Storage::File)))?;
        *self.cached.write().unwrap() = Some(found.clone());
        Some(found)
    }

    /// Persist a key, keychain first, file fallback. Returns the backend
    /// that took it.
    pub fn store(&self, key_hex: &str) -> Result<Storage, String> {
        let storage = if self.keychain_set(key_hex) {
            // A stale fallback file must not shadow (or outlive) the
            // keychain copy.
            self.file_delete();
            Storage::Keychain
        } else {
            self.file_set(key_hex)?;
            Storage::File
        };
        *self.cached.write().unwrap() = Some((key_hex.to_string(), storage));
        Ok(storage)
    }

    /// Remove the key from every backend it could live in.
    pub fn remove(&self) {
        self.keychain_delete();
        self.file_delete();
        *self.cached.write().unwrap() = None;
    }

    /// Run a keyring operation on a dedicated plain thread. The Secret
    /// Service backend drives zbus with a `block_on`, which must never
    /// run on (or panic) a tokio worker — callers reach here from the
    /// engine's connect path and axum handlers. A panicked closure
    /// degrades to `None` (treated as "no keychain") instead of taking
    /// the caller down.
    #[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos"))]
    fn with_keychain<T: Send + 'static>(
        &self,
        f: impl FnOnce(keyring::Entry) -> T + Send + 'static,
    ) -> Option<T> {
        if !self.use_keychain.load(Ordering::SeqCst) {
            return None;
        }
        let user = self.keychain_user;
        std::thread::spawn(move || {
            let entry = keyring::Entry::new(KEYCHAIN_SERVICE, user).ok()?;
            Some(f(entry))
        })
        .join()
        .ok()
        .flatten()
    }

    #[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos"))]
    fn keychain_get(&self) -> Option<String> {
        let key = self.with_keychain(|e| e.get_password().ok())??;
        (!key.trim().is_empty()).then(|| key.trim().to_string())
    }

    #[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos"))]
    fn keychain_set(&self, key: &str) -> bool {
        let key = key.to_string();
        match self.with_keychain(move |e| e.set_password(&key)) {
            Some(Ok(())) => true,
            Some(Err(err)) => {
                tracing::warn!("keychain store failed, using file fallback: {err}");
                false
            }
            None => false,
        }
    }

    #[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos"))]
    fn keychain_delete(&self) {
        let _ = self.with_keychain(|e| e.delete_credential());
    }

    #[cfg(not(any(target_os = "linux", target_os = "windows", target_os = "macos")))]
    fn keychain_get(&self) -> Option<String> {
        None
    }
    #[cfg(not(any(target_os = "linux", target_os = "windows", target_os = "macos")))]
    fn keychain_set(&self, _key: &str) -> bool {
        false
    }
    #[cfg(not(any(target_os = "linux", target_os = "windows", target_os = "macos")))]
    fn keychain_delete(&self) {}

    fn file_get(&self) -> Option<String> {
        let path = self.file_path.as_ref()?;
        let key = std::fs::read_to_string(path).ok()?;
        (!key.trim().is_empty()).then(|| key.trim().to_string())
    }

    fn file_set(&self, key: &str) -> Result<(), String> {
        let path = self
            .file_path
            .as_ref()
            .ok_or("no keychain available and no data dir for the fallback file")?;
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        std::fs::write(path, key).map_err(|e| format!("key file write failed: {e}"))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
        }
        Ok(())
    }

    fn file_delete(&self) {
        if let Some(path) = &self.file_path {
            let _ = std::fs::remove_file(path);
        }
    }
}

/// A fresh 12-word BIP-39 mnemonic plus the wallet it derives —
/// `(phrase, private_key_hex, address)`. Nothing is stored; the caller
/// runs the backup ceremony and imports the phrase on confirm.
pub fn generate() -> Result<(String, String, String), String> {
    use coins_bip39::{English, Mnemonic};
    let mnemonic: Mnemonic<English> = Mnemonic::new_with_count(&mut rand::thread_rng(), 12)
        .map_err(|e| format!("mnemonic generation failed: {e}"))?;
    let phrase = mnemonic.to_phrase();
    let key = key_from_mnemonic(&phrase)?;
    let address = address_of(&key)?;
    Ok((phrase, key, address))
}

/// Derive the EVM private key from a BIP-39 phrase at m/44'/60'/0'/0/0 —
/// the standard path, so the same words restore the same wallet in
/// MetaMask/Trust/any BIP-44 wallet app.
pub fn key_from_mnemonic(phrase: &str) -> Result<String, String> {
    use alloy_signer_local::MnemonicBuilder;
    use coins_bip39::English;
    let normalized = phrase.split_whitespace().collect::<Vec<_>>().join(" ");
    let signer = MnemonicBuilder::<English>::default()
        .phrase(normalized.to_lowercase())
        .index(0)
        .map_err(|e| format!("derivation path invalid: {e}"))?
        .build()
        .map_err(|e| format!("not a valid seed phrase: {e}"))?;
    Ok(format!("0x{}", hex::encode(signer.to_bytes())))
}

/// Validate a pasted private key and return its canonical 0x-hex form.
pub fn normalize_private_key(input: &str) -> Result<String, String> {
    use alloy_signer_local::PrivateKeySigner;
    let cleaned = input.trim().trim_start_matches("0x");
    let signer: PrivateKeySigner = cleaned
        .parse()
        .map_err(|_| "not a valid private key (expect 64 hex characters)".to_string())?;
    Ok(format!("0x{}", hex::encode(signer.to_bytes())))
}

/// EIP-55 checksummed address of a stored key.
pub fn address_of(key_hex: &str) -> Result<String, String> {
    use alloy_signer_local::PrivateKeySigner;
    let signer: PrivateKeySigner = key_hex
        .trim()
        .trim_start_matches("0x")
        .parse()
        .map_err(|_| "stored wallet key is not a valid private key".to_string())?;
    Ok(signer.address().to_string())
}

/// The evmlib wallet for the stored key on Arbitrum One (the network
/// Autonomi mainnet payments live on; hardcoded RPC/token/vault).
pub fn evm_wallet(key_hex: &str) -> Result<EvmWallet, String> {
    EvmWallet::new_from_private_key(EvmNetwork::ArbitrumOne, key_hex)
        .map_err(|e| format!("wallet init failed: {e:?}"))
}

/// ANT + ETH balances on Arbitrum One as raw base-unit decimal strings
/// `(ant_atto, eth_wei)`. Talks to the public RPC, not the Autonomi
/// network — works while the ant client is still connecting.
pub async fn balances(key_hex: &str) -> Result<(String, String), String> {
    let wallet = evm_wallet(key_hex)?;
    let ant = wallet
        .balance_of_tokens()
        .await
        .map_err(|e| format!("ANT balance query failed: {e}"))?;
    let eth = wallet
        .balance_of_gas_tokens()
        .await
        .map_err(|e| format!("ETH balance query failed: {e}"))?;
    Ok((ant.to_string(), eth.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    // The canonical all-`test` BIP-39 vector (hardhat/foundry account 0):
    // both the phrase and its m/44'/60'/0'/0/0 key must land on the same
    // well-known address, proving the derivation path is the standard one.
    const VECTOR_PHRASE: &str =
        "test test test test test test test test test test test junk";
    const VECTOR_KEY: &str =
        "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
    const VECTOR_ADDR: &str = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

    #[test]
    fn mnemonic_derives_standard_path() {
        let key = key_from_mnemonic(VECTOR_PHRASE).unwrap();
        assert_eq!(key, VECTOR_KEY);
        assert_eq!(address_of(&key).unwrap(), VECTOR_ADDR);
    }

    #[test]
    fn mnemonic_tolerates_case_and_whitespace() {
        let messy = format!("  Test  test test\ttest test test\n test test test test TEST junk ");
        assert_eq!(key_from_mnemonic(&messy).unwrap(), VECTOR_KEY);
    }

    #[test]
    fn bad_mnemonic_rejected() {
        assert!(key_from_mnemonic("not a real seed phrase at all").is_err());
        assert!(key_from_mnemonic("").is_err());
    }

    #[test]
    fn private_key_normalizes_with_and_without_prefix() {
        assert_eq!(normalize_private_key(VECTOR_KEY).unwrap(), VECTOR_KEY);
        assert_eq!(
            normalize_private_key(&format!("  {} ", &VECTOR_KEY[2..])).unwrap(),
            VECTOR_KEY
        );
        assert!(normalize_private_key("0x1234").is_err());
        assert!(normalize_private_key("zz").is_err());
    }

    #[test]
    fn generate_makes_importable_wallets() {
        let (phrase, key, address) = generate().unwrap();
        assert_eq!(phrase.split_whitespace().count(), 12);
        // Re-importing the phrase must land on the identical wallet.
        assert_eq!(key_from_mnemonic(&phrase).unwrap(), key);
        assert_eq!(address_of(&key).unwrap(), address);
        // Two generations must differ (sanity check on the entropy path).
        let (phrase2, ..) = generate().unwrap();
        assert_ne!(phrase, phrase2);
    }

    #[test]
    fn store_round_trips_via_file_fallback() {
        let dir = std::env::temp_dir().join(format!("wi-wallet-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        // use_keychain=false: tests must never touch a real keychain.
        let store = WalletStore::new(dir.to_str(), false);
        assert!(store.load().is_none());
        assert_eq!(store.store(VECTOR_KEY).unwrap(), Storage::File);
        assert_eq!(
            store.load().unwrap(),
            (VECTOR_KEY.to_string(), Storage::File)
        );
        // A fresh store (cold cache) reads the same key back from disk.
        let store2 = WalletStore::new(dir.to_str(), false);
        assert_eq!(
            store2.load().unwrap(),
            (VECTOR_KEY.to_string(), Storage::File)
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(dir.join("wallet.key"))
                .unwrap()
                .permissions()
                .mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        store.remove();
        assert!(store.load().is_none());
        assert!(WalletStore::new(dir.to_str(), false).load().is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn no_data_dir_and_no_keychain_errors_clearly() {
        let store = WalletStore::new(None, false);
        let err = store.store(VECTOR_KEY).unwrap_err();
        assert!(err.contains("no keychain"));
    }

    #[test]
    fn evm_wallet_builds_on_arbitrum_one() {
        let w = evm_wallet(VECTOR_KEY).unwrap();
        assert_eq!(w.address().to_string(), VECTOR_ADDR);
    }
}
