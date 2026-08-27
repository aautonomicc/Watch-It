//! Channel identity: Ed25519 keys from a 12-word phrase, channel codes,
//! and signed head records.
//!
//! A channel is identified by an Ed25519 public key; its shareable code
//! is `wchn1-<base32(pubkey)>` — deliberately a different prefix and
//! alphabet than the `wtch1-` My W@tch invites, so the two kinds of
//! string can never be mistaken for each other. The secret key is
//! derived from the channel's own 12-word BIP-39 phrase (separate from
//! the wallet phrase on purpose: the wallet is a disposable hot wallet,
//! the channel key IS the channel's identity and must outlive any
//! wallet rotation) via SLIP-0010's ed25519 master-key derivation, so
//! the same words restore the same channel anywhere. The phrase itself
//! is never stored — display-once ceremony, only the derived key
//! persists (in the OS keychain beside the wallet key).
//!
//! The mutable part of a channel — which manifest is current — travels
//! as a *head record* `{seq, manifest, sig}` gossiped on a topic derived
//! from the public key. Anyone can write into that (public, self-keyed)
//! store, so heads are trusted purely by signature: [`verify_head`]
//! accepts only records signed by the channel key, and readers take the
//! highest valid `seq`.

use ed25519_dalek::{Signer, SigningKey, Verifier, VerifyingKey};

/// Channel code prefix; version-bumped if the format ever changes.
pub const CODE_PREFIX: &str = "wchn1-";

/// A fresh channel identity: `(phrase, secret_hex, code)`. Nothing is
/// stored; the caller runs the backup ceremony and creates the channel
/// from the phrase on confirm.
pub fn generate() -> Result<(String, String, String), String> {
    use coins_bip39::{English, Mnemonic};
    let mnemonic: Mnemonic<English> = Mnemonic::new_with_count(&mut rand::thread_rng(), 12)
        .map_err(|e| format!("mnemonic generation failed: {e}"))?;
    let phrase = mnemonic.to_phrase();
    let secret = secret_from_mnemonic(&phrase)?;
    let code = code_of(&secret)?;
    Ok((phrase, secret, code))
}

/// Derive the channel secret key (32 bytes, hex) from a BIP-39 phrase:
/// BIP-39 seed → SLIP-0010 ed25519 master key (`HMAC-SHA512("ed25519
/// seed", seed)`, left half). Deterministic, so the phrase alone
/// restores the identical channel on any machine.
pub fn secret_from_mnemonic(phrase: &str) -> Result<String, String> {
    use coins_bip39::{English, Mnemonic};
    let normalized = phrase
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase();
    let mnemonic: Mnemonic<English> = normalized
        .parse()
        .map_err(|_| "not a valid 12-word recovery phrase".to_string())?;
    let seed = mnemonic
        .to_seed(None)
        .map_err(|e| format!("seed derivation failed: {e}"))?;
    Ok(hex::encode(slip10_ed25519_master(&seed)))
}

/// SLIP-0010 ed25519 master secret key for a BIP-39 seed (the spec's
/// `I_L` of `HMAC-SHA512(Key = "ed25519 seed", Data = seed)`).
fn slip10_ed25519_master(seed: &[u8]) -> [u8; 32] {
    use hmac::{Hmac, Mac};
    let mut mac = <Hmac<sha2::Sha512> as Mac>::new_from_slice(b"ed25519 seed")
        .expect("HMAC accepts any key length");
    mac.update(seed);
    let out = mac.finalize().into_bytes();
    let mut key = [0u8; 32];
    key.copy_from_slice(&out[..32]);
    key
}

fn signing_key(secret_hex: &str) -> Result<SigningKey, String> {
    let mut secret = [0u8; 32];
    hex::decode_to_slice(secret_hex.trim(), &mut secret)
        .map_err(|_| "stored channel key is damaged".to_string())?;
    Ok(SigningKey::from_bytes(&secret))
}

/// Public key (hex) of a stored secret.
pub fn pubkey_of(secret_hex: &str) -> Result<String, String> {
    Ok(hex::encode(
        signing_key(secret_hex)?.verifying_key().to_bytes(),
    ))
}

/// Channel code of a stored secret.
pub fn code_of(secret_hex: &str) -> Result<String, String> {
    Ok(code_from_pubkey_hex(&pubkey_of(secret_hex)?)?)
}

/// `wchn1-<base32(pubkey)>` for a 32-byte public key (lowercase,
/// unpadded RFC 4648 base32 — 52 characters).
pub fn code_from_pubkey_hex(pubkey_hex: &str) -> Result<String, String> {
    let mut pk = [0u8; 32];
    hex::decode_to_slice(pubkey_hex.trim(), &mut pk)
        .map_err(|_| "public key must be 64 hex characters".to_string())?;
    Ok(format!(
        "{CODE_PREFIX}{}",
        data_encoding::BASE32_NOPAD.encode(&pk).to_lowercase()
    ))
}

/// Parse a channel code back to the public key (hex). Rejects anything
/// that is not a well-formed code for a valid Ed25519 point.
pub fn pubkey_from_code(code: &str) -> Result<String, String> {
    // Case-insensitive throughout — codes travel through chat apps and
    // auto-capitalizing keyboards.
    let trimmed = code.trim();
    let body = trimmed
        .get(..CODE_PREFIX.len())
        .filter(|p| p.eq_ignore_ascii_case(CODE_PREFIX))
        .map(|_| &trimmed[CODE_PREFIX.len()..])
        .ok_or("not a channel code (it should start with wchn1-)")?;
    let bytes = data_encoding::BASE32_NOPAD
        .decode(body.to_uppercase().as_bytes())
        .map_err(|_| "channel code is damaged (bad characters)".to_string())?;
    let pk: [u8; 32] = bytes
        .try_into()
        .map_err(|_| "channel code is damaged (wrong length)".to_string())?;
    VerifyingKey::from_bytes(&pk)
        .map_err(|_| "channel code is damaged (not a valid key)".to_string())?;
    Ok(hex::encode(pk))
}

/// The bytes a head record's signature covers. Binding the public key in
/// keeps a signature from ever validating under a different channel.
fn head_message(pubkey_hex: &str, seq: u64, manifest_hex: &str) -> Vec<u8> {
    format!("watchit channel head v1|{pubkey_hex}|{seq}|{manifest_hex}").into_bytes()
}

/// Sign a head record `{seq, manifest}` with the channel secret.
pub fn sign_head(secret_hex: &str, seq: u64, manifest_hex: &str) -> Result<String, String> {
    let key = signing_key(secret_hex)?;
    let pubkey_hex = hex::encode(key.verifying_key().to_bytes());
    let sig = key.sign(&head_message(&pubkey_hex, seq, manifest_hex));
    Ok(hex::encode(sig.to_bytes()))
}

/// Verify a head record against the channel public key. `false` for any
/// malformed field — a public store can carry arbitrary junk.
pub fn verify_head(pubkey_hex: &str, seq: u64, manifest_hex: &str, sig_hex: &str) -> bool {
    let mut pk = [0u8; 32];
    if hex::decode_to_slice(pubkey_hex.trim(), &mut pk).is_err() {
        return false;
    }
    let Ok(key) = VerifyingKey::from_bytes(&pk) else {
        return false;
    };
    let Ok(sig_bytes) = hex::decode(sig_hex.trim()) else {
        return false;
    };
    let Ok(sig_arr) = <[u8; 64]>::try_from(sig_bytes.as_slice()) else {
        return false;
    };
    let sig = ed25519_dalek::Signature::from_bytes(&sig_arr);
    key.verify(&head_message(pubkey_hex, seq, manifest_hex), &sig)
        .is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slip10_master_matches_spec_vector() {
        // SLIP-0010 test vector 1 for ed25519:
        // seed 000102030405060708090a0b0c0d0e0f → master key m.
        let seed = hex::decode("000102030405060708090a0b0c0d0e0f").unwrap();
        assert_eq!(
            hex::encode(slip10_ed25519_master(&seed)),
            "2b4be7f19ee27bbf30c667b642d5f4aa69fd169872f8fc3059c08ebae2eb19e7"
        );
    }

    #[test]
    fn phrase_restores_identical_channel() {
        let (phrase, secret, code) = generate().unwrap();
        assert_eq!(phrase.split_whitespace().count(), 12);
        let restored = secret_from_mnemonic(&phrase).unwrap();
        assert_eq!(restored, secret);
        assert_eq!(code_of(&restored).unwrap(), code);
        // Messy re-typing still lands on the same key.
        let messy = format!("  {}  ", phrase.to_uppercase().replace(' ', "\t "));
        assert_eq!(secret_from_mnemonic(&messy).unwrap(), secret);
        // Distinct generations are distinct channels.
        let (_, secret2, code2) = generate().unwrap();
        assert_ne!(secret2, secret);
        assert_ne!(code2, code);
    }

    #[test]
    fn bad_phrase_rejected() {
        assert!(secret_from_mnemonic("definitely not a seed phrase").is_err());
        assert!(secret_from_mnemonic("").is_err());
    }

    #[test]
    fn code_round_trips_and_rejects_damage() {
        let (_, secret, code) = generate().unwrap();
        assert!(code.starts_with(CODE_PREFIX));
        // 52 base32 chars for 32 bytes.
        assert_eq!(code.len(), CODE_PREFIX.len() + 52);
        let pubkey = pubkey_from_code(&code).unwrap();
        assert_eq!(pubkey, pubkey_of(&secret).unwrap());
        // Case-insensitive on purpose (codes travel through chat apps).
        assert_eq!(pubkey_from_code(&code.to_uppercase()).unwrap(), pubkey);
        assert!(pubkey_from_code("wtch1-abcdef").is_err()); // My W@tch invite
        assert!(pubkey_from_code("wchn1-tooshort").is_err());
        assert!(pubkey_from_code("").is_err());
    }

    #[test]
    fn head_signature_round_trips_and_binds_every_field() {
        let (_, secret, _) = generate().unwrap();
        let pubkey = pubkey_of(&secret).unwrap();
        let manifest = "11".repeat(32);
        let sig = sign_head(&secret, 3, &manifest).unwrap();
        assert!(verify_head(&pubkey, 3, &manifest, &sig));
        // Any field change kills the signature.
        assert!(!verify_head(&pubkey, 4, &manifest, &sig));
        assert!(!verify_head(&pubkey, 3, &"22".repeat(32), &sig));
        let (_, other, _) = generate().unwrap();
        assert!(!verify_head(&pubkey_of(&other).unwrap(), 3, &manifest, &sig));
        // Garbage never verifies (public store carries strangers' junk).
        assert!(!verify_head(&pubkey, 3, &manifest, "junk"));
        assert!(!verify_head("nothex", 3, &manifest, &sig));
    }
}
