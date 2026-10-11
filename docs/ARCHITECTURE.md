# Architecture

## Framework decision

**Recommendation: Flutter + media_kit (libmpv).**

| Option | All 6 platforms? | Player engine | Notes |
|---|---|---|---|
| **Flutter** | ✅ yes, first-class | `media_kit` wraps libmpv on all platforms | Single UI codebase, 120fps UI, proven media apps. **Recommended.** |
| Kotlin Multiplatform | UI (Compose MP) still maturing on iOS/desktop | wrap ExoPlayer/AVPlayer/libmpv per platform | More per-platform work |
| React Native | desktop via forks (Windows/macOS ok, Linux weak) | react-native-video | Linux support is the blocker |
| Tauri 2 | ✅ incl. mobile | web `<video>` or mpv sidecar | Web video stack = codec pain; mpv integration is hacky |
| Qt/QML | ✅ | libmpv | Great engine story, slower UI dev, licensing friction |

Why Flutter wins here: it is the only stack where *both* the UI and the playback engine
(libmpv via `media_kit`) are first-class on all six targets, including Linux. libmpv
gives us every codec/container, subtitle rendering, and hardware decode without
per-platform player code.

**Android TV rides on the Android build.** Android TV is Android, so the same Flutter
APK covers it — no extra platform port. What it needs on top:

- Manifest: a `LEANBACK_LAUNCHER` intent filter so the app appears on the TV home
  screen, `android.software.leanback` + `android.hardware.touchscreen required=false`
  so TV devices aren't filtered out.
- **D-pad focus navigation** everywhere (Flutter's `FocusTraversalGroup` /
  `Shortcuts`): the same plumbing as the desktop keyboard map, so it's shared work,
  not TV-only work.
- A 10-foot layout mode (see UI-DESIGN.md): larger type, focus-scaled poster cards,
  no hover- or touch-only affordances.
- Hardware decode matters more here (TV boxes have weak CPUs) — libmpv uses
  MediaCodec on Android, same path as phones.

Status (alpha.115): the manifest work (leanback entry, TV banner,
leanback/touchscreen not-required) and card-level D-pad focus shipped
in alpha.95; alpha.96 merged the full TV UX wave (the first external
PR): UiModeManager TV detection over a method channel, an overscan
safe area (0–10% margins) framing the app while video renders
full-bleed behind it, a labelled TV app bar, a remote player
transport with preview-then-commit timeline seeking, audio/caption
track menus with local SRT/VTT or pasted caption files, and an
optional Grove palette — interaction spec in
[ANDROID-TV.md](ANDROID-TV.md). Since alpha.98 the release APK is
dual-ABI (armeabi-v7a + arm64-v8a), so 32-bit-app TV devices (Fire TV
Stick, Google TV Streamer) install the normal APK, and real-device
testing runs on both via the tester group — the alpha.98–.112 TV
fixes (seek-bar D-pad traversal, single control bar for music, audio
media keys from any focus, Tegra Impeller default-off + the Graphics
compatibility toggle, About reachable by D-pad with a focusable
found-update row) all came out of it. The 10-foot layout
mode is still open.

## High-level structure

Client-only. There is no server component anywhere in the design; the Autonomi network
is the only remote source, accessed via the
[ant-client](https://github.com/WithAutonomi/ant-client) stack.

```
┌──────────────────────────────────────────────┐
│                Flutter UI                     │
│  (library, detail pages, player, settings)    │
├──────────────────────────────────────────────┤
│               App core (Dart)                 │
│  lists · metadata matcher · watch state       │
│  downloads · upload · device sync (My W@tch)  │
│  playback controller                          │
├──────────────────────┬───────────────────────┤
│   Autonomi access    │   Metadata fetcher     │
│  (ant-client: fetch  │  (filename → TMDB →    │
│   by XOR address,    │   artwork/description/ │
│   stream + download) │   category, cached)    │
├──────────────────────┴───────────────────────┤
│         media_kit / libmpv playback           │
└──────────────────────────────────────────────┘
```

### Lists — the library model (datamap-first since alpha.40)

A **list** is the unit of library organization. Each entry:

```
{ address: <derived address>, name: "The Movie (2023).mkv" }
```

The **derived address** is `blake3(rmp_serde(shrink(root data map)))` —
computed fully offline from the entry's `.datamap` file at import, with the
root map stored in the embedded client's local map store. There is no other
entry kind: **public XOR addresses were removed as an entry type in
alpha.40**, because a public Autonomi upload stores its root data map as a
plaintext chunk on the network (any node operator can trawl chunks for valid
maps and read the whole file), and an app keyed on public addresses nudges
users into uploading their media libraries insecurely. A private upload
(`ant file upload`, no flags) stores the same encrypted chunks but keeps the
map in the local `.datamap` file — without it the chunks are unlinkable
noise. For a file that *was* uploaded publicly the derived address equals
its XOR address, so entries created by older versions kept their identity
unchanged.

- Content enters the library exactly three ways: importing `.datamap` files
  (multi-select picker; the file name minus `.datamap` is the media name,
  feeding the metadata matcher), importing a `.watch-list` **bundle** (a
  zip of datamap members plus TMDB metadata, posters, optional watch
  history) — spec v2 in [BUNDLE-FORMAT.md](BUNDLE-FORMAT.md) — or
  **publishing your own file from the app** (desktop alpha.55+, Android
  2026-09-18 — originals only there, no encode tiers): the
  upload's root map is stored locally under its derived address, so the
  new entry behaves exactly like an import. Export is the bundle, full
  stop (a name list without maps is unplayable).
- A datamap is full access to its content: sharing a bundle shares the
  ability to watch, and publishing one at a public address re-leaks every
  title (privacy is transitive). Future publish/subscribe features must
  default private.
- An entry whose map is missing locally cannot play — the stream path
  fast-fails with a "re-import" message rather than attempting a network
  resolve (no such resolve exists anymore).
- On add, the **metadata matcher** parses the file name (title/year, `SxxEyy`) and
  queries TMDB for artwork, overview, and genre/category — exactly the pipeline
  Plex/Emby/Jellyfin servers run, but on-device. Results cached in SQLite; entries
  that don't match still appear with name-only cards.

### Autonomi access

**Decided (Phase 0): embedded Rust client, in-process.** `native/watchit_core` links
ant-core (WithAutonomi/ant-client, pinned rev) as a cdylib the app loads over
dart:ffi. It runs a tokio runtime plus a **localhost HTTP server** inside the app
process: `GET /xor/<address>` with full **HTTP range support** (via
`self_encryption::streaming_decrypt().get_range`), so libmpv plays the URL directly
and gets seeking for free — while staying a single self-contained app with no
sidecar process and nothing for users to set up. Bootstrap peers are compiled in
(overridable via FFI). `GET /health` reports connection state to the Settings UI.

Two layers of caching keep streaming fast:

- **Chunk LRU cache + keep-ahead prefetch** — all chunk traffic goes through a
  byte-bounded in-memory LRU (256 MiB desktop / 128 MiB Android); while serving,
  a prefetcher keeps ~64 MiB ahead of the playhead warm.
- **Root data-map store** — root maps are content-addressed and immutable,
  so they are stored in SQLite (`root_maps.sqlite`) forever. Since alpha.40
  maps arrive **at import time** (`POST /datamap` derives the address
  offline and stores the map; `GET /datamap/{addr}` exports ant-cli-
  compatible bytes), and the `/xor` stream path serves locally stored maps
  only — no cold first-play resolve exists anymore. Since alpha.41 the
  crate has no network map fetch at all (`data_map_fetch` deleted);
  `GET /resolve/{addr}` remains as a local-store `{size, chunks}` lookup
  for the download manager's size pre-fill.

### Downloads / offline

**Shipped (alpha.30/.31), pure Dart — no new native code.** The download
manager streams the existing Range-capable `GET /xor/<addr>` endpoint (which
serves deterministic decrypted bytes) to disk:

- **Queue** persisted in SQLite (drift `downloads` table): sequential, with
  pause/resume/remove; partial files resume from the bytes on disk via
  `Range: bytes=N-`; total size pre-filled from `/resolve`. Files live in
  app-private storage (Android, no permissions needed) or a user-chosen
  desktop folder.
- **Connection-loss handling**: a failed transfer probes `/health` and
  auto-pauses (bytes kept, no error) when the embedded client is offline
  (connecting, or ready with 0 peers), with a 2-minute no-data stall timeout
  as backstop; resume is manual. Streaming playback with active downloads
  can pause them (ask/always/never, remembered choice) and resumes them when
  the player closes.
- **Offline-aware UI**: a `ConnectivityMonitor` polls `/health` with the same
  offline rule; browsing always works offline, downloaded titles play
  locally with the full library experience (badges on every card: check =
  downloaded, ring = downloading, any-downloaded count on show/season
  cards), and Play is disabled with a hint on non-downloaded titles only.
  The Up-next chain stops at a non-downloaded next episode only when
  offline — online it falls back to streaming.
- A downloaded item is the same library entry with a local path — stream vs
  downloaded is a playback-source detail, not a different library.

### Upload — in-app uploads (shipped alpha.55/.56 as "Publish", renamed Upload 2026-08-27; desktop + Android)

W@tch uploads to Autonomi itself; the `ant` CLI is no longer required for
the write path. Desktop and, since 2026-09-18, Android (which bundles no
ffmpeg: files upload exactly as picked — no quality tiers, no QUALITY
section; the ledger/matcher cache live in `<appSupport>/upload_config`,
folder picking stays desktop-only, and the wallet key uses the 0600 file
fallback). iOS deferred. Two new Rust modules in `watchit_core`:

- **Wallet** (`wallet.rs`): the payment key lives in the **OS keychain**
  (Windows Credential Manager / macOS Keychain / Secret Service on Linux,
  with a mode-0600 `wallet.key` file fallback when no keychain is
  available — surfaced in the UI). Create is a BIP-39 12-word ceremony
  (retype-confirm before anything persists); import accepts a raw key or a
  phrase (MetaMask-compatible `m/44'/60'/0'/0/0`); the mnemonic itself is
  never stored. Settings → Wallet shows the address and live ANT/ETH
  balances (Arbitrum One). It is deliberately a **hot wallet** — the docs
  and UI say to fund it small. Since 2026-10-11 the file fallback can be
  **passphrase-protected**: Argon2id derives a ChaCha20-Poly1305 key and
  the file becomes `wenck1:<address>:<salt>:<nonce>:<ciphertext>` (the
  public address rides in the clear so the locked state still shows which
  wallet is waiting). After a restart the wallet reads as `locked` until
  `POST /wallet/unlock` decrypts it into memory for the session —
  balances, uploads and backups all refuse with "unlock it in Settings →
  Wallet" until then. Keychain-stored keys never need this (already
  protected at rest), and a hardware marker is public by construction so
  protection is refused for it. Transient key material (derivation
  intermediates, passphrase-derived keys, the removed wallet's in-memory
  copy) is zeroized on drop throughout wallet.rs/backup.rs.
- **Upload** (`upload.rs`): a single-slot job around ant-core's
  `file_upload_with_progress` (automatic payment) that the UI polls for
  phase/progress. The finished upload's root map goes straight into the
  local map store under its derived address, so the result is immediately
  playable, addable to the library, and exportable as a `.datamap` file.
- **Routes**: `GET/POST/DELETE /wallet`, `POST /wallet/generate`,
  `GET /wallet/balances`, `POST /upload/estimate`, `POST /upload`,
  `GET /upload/{id}` — all behind an `x-watchit-auth` shared secret
  (random per app start, passed to Dart over FFI): the localhost port is
  visible to every local process and these routes spend money.

On the Dart side (`publish_screen.dart`, `publish_plan.dart`,
`ffmpeg.dart`): multi-file batches (full series in one go), per-file
ffprobe verdicts, **quality tiers** — High 1080p/5Mbps, Medium
720p/2.5Mbps, Low 480p/1Mbps, encoded to H.264 High 8-bit + AAC stereo
faststart MP4, plus "Original (as-is)" — with per-tier applicability (no
upscaling) and a summed live cost estimate scaled per-chunk from one
`/upload/estimate` call; then a sequential encode→upload queue with
per-item retry/skip. Encoded outputs are named per
[NAMING.md](NAMING.md) with the *real* output height tag, so tiers fold
into the alpha.49 same-title version picker, and each created library
entry is stamped with its "1080p H.264"-style resolution/codec label so
the picker shows the full quality line, not just a size. ffmpeg/ffprobe
are bundled (static builds in the AppImage, shared build in the Windows
zip); when missing, Upload degrades gracefully to as-is-only uploads
with a banner.

Finalize note (fixed alpha.59): for any file over ~12 MiB (more than 3
chunks) ant-core's upload returns the *shrunk child* data map, which the
finalize step now expands to the root map exactly like `.datamap` import
does. Because the error fired *after* payment and storage, a file caught
by the old bug is fully on the network — re-publishing it finishes the
bookkeeping at no extra cost (already-stored chunks are free).

**Upload-all batch payments** (2026-10-10, shipped in alpha.113 —
hardware-wallet plan phase 0): the batch uploader no longer pays per file. A new
`batch.rs` pools EVERY chunk of the whole batch into ant-core's public
multi-record driver (`Client::upload_records`, `PaymentMode::Merkle`):
each file stream-encrypts locally into a disk spill (the chunk set is
the file's identity — pinned against the single-file path), the root
map recovers with zero network rounds, and the pooled set pays **one
`payForMerkleTree` transaction per ≤256-chunk merkle sub-batch** — a
typical batch is one payment instead of one+ per file. The
`UploadAdapter` implementation is the batch's single money seam; since
phase 2 its wallet is signer-built (see "The signer seam" below), so a
hardware signer (Trezor/Ledger, phase 3) plugs in without touching it. Payment proofs
checkpoint to `<data>/batch-upload/` (keyed by the batch's chunk
fingerprint; merkle payments stay valid 7 days), so failed stores — and
app restarts — retry free; a checkpoint that died inside the seconds-
wide payment window is discarded rather than reconciled by guesswork.
Routes: `POST /upload/batch` + `GET /upload/batch/{id}` (protected,
same single active slot as `/upload`). The Dart session
(`batch_upload.dart`) encodes all tier outputs first (payment needs
every chunk address), posts one batch, maps per-file outcomes back in
input order, and the review page states the payment count up front
("Paid together in 1 payment transaction" / "~N … one per ~1 GB of
chunks").

**The signer seam** (2026-10-10, shipped in alpha.114 —
hardware-wallet plan phase 2): everything that signs goes through `signer.rs`'s `Signer`
type — a `Software` variant wrapping the stored key, and (phase 3) a
`Trezor` variant holding only public identity.
`Signer::payment_wallet()` (async since phase 3) builds the evmlib wallet with
`Wallet::new(ArbitrumOne, EthereumWallet::from(signer))` — evmlib's
`Wallet` is just an alloy `EthereumWallet` (any `TxSigner`) plus a
network, so this ONE seam signs every paid call: the client's attached
wallet (`engine.attach_wallet`, covering single-file uploads and the
backup's `data_upload`/`chunk_put`/`pointer_update`), the batch
adapter's `pay`/`pay_merkle`, and the balances query.
`new_from_private_key` is gone from the tree — the raw key string
never crosses into ant-core. The backup identity rides the same type
(`identity_signature`/`backup_keys`; the pre-phase-1 legacy derivation
is `backup_keys_legacy() -> Ok(None)` for signers with no raw key, so
a hardware wallet correctly has no legacy restore line). Alloy-tree
note: the payment signer must implement **evmlib's** alloy (1.x
facade, already in the lockfile) — phase 3 therefore uses
alloy-signer-trezor 1.8.x, not the 2.4.x tree backup.rs's identity
signature uses (the r‖s bytes are identical across trees by RFC-6979).

**Hardware wallet — Trezor** (2026-10-10, shipped in alpha.114;
hardened in alpha.115 — hardware-wallet
plan phase 3 + the settled phase-4 key policy): `trezor.rs` talks to
the device over alloy-signer-trezor 1.8.3 → trezor-client → rusb
(DIRECT USB, no Trezor Bridge; Linux needs the standard Trezor udev
rules — the permission error says so; desktop-only, Android gets
stubs). Every device conversation runs on a blocking thread
(`spawn_blocking` + `Handle::block_on`) because the signer's async
methods do synchronous USB inside and a signature takes as long as the
user takes at the button. Setup (`POST /wallet/trezor`,
`{"share_keys": bool}` default true): the device at m/44'/60'/0'/0/0
(the software wallet's exact path — the same 12 words land on the same
address and backup line) signs `IDENTITY_MESSAGE_V1` TWICE
(determinism guard), then SHOWS the wallet address on its own screen
for a third confirmation (raw trezor-client
`EthereumGetAddress{show_display:true}` — the compromised-host
wrong-account defense: the address the user verifies is drawn by the
device, and a mismatch with the USB-reported address aborts setup);
the backup identity derives in RAM, and the
wallet store keeps only the public marker
`trezor:v1:<address>:<pointer_hex>:<fingerprint>` — address, backup
pointer address and public line fingerprint, so the Backup screen
shows the identity and its last-backup record with the device
unplugged. Key policy: the WRITE half (ML-DSA pointer seed) is NEVER
persisted — each backup sets job phase `trezor` ("Confirm on your
Trezor…"), re-derives on-device, and the derived pointer must equal
the configured one (wrong device / changed passphrase fails loudly
instead of minting a parallel line). The READ half (content key)
persists in the `backup-read-keys` keychain entry
(`Engine::trezor_keys`, 0600-file fallback) only while "share backup
read keys" is on (the setup default) — `GET /backup` serves `key`
only then, so an opted-out install can never publish the phase-2
key-share section by construction; opting out makes restore ask the
device once. Payments: `Signer::payment_wallet()` opens a USB session
bound to the configured address and every transaction waits for a
physical confirmation (first payment may be two: evmlib's allowance
approve, then pay); an unplugged device degrades to a wallet-less
client with a plug-it-in hint at the paid call. `GET /wallet` reports
`kind` (`software`/`trezor`) + `keys_held`; balances for a hardware
wallet query by address via evmlib's free functions. A software import
or wallet delete sweeps the kept read key with the marker.

### My W@tch — device linking & sync (shipped alpha.61/.62)

Keeps a user's **own devices** in sync — watch lists, viewing positions,
and Edit-details changes including artwork — with no account and no
server. It deliberately does *not* ride Autonomi: sync is device-to-device
over an in-process [x0x](https://crates.io/crates/x0x) agent
(saorsa-gossip over ant-quic — post-quantum QUIC; mDNS discovery on the
LAN plus public bootstrap for remote devices), implemented in
`native/watchit_core/src/mywatch.rs` with the Dart side in
`services/my_watch_sync.dart` and `screens/my_watch_screen.dart`.

- **Linking**: one device creates a link — a 32-byte secret shared as an
  invite code `wtch2-<hex64>` (the `wtch1-` form is the pre-encryption
  format; a v2 build rejects it with a specific "update that device
  first" message), shown as a QR code (scannable in-app on
  Android/iOS) or pasted as text. Devices holding the secret meet in a
  self-keyed **CRDT key-value store** on a gossip topic *derived* (blake3)
  from the secret — the secret itself never goes on the wire, and nothing
  about the group is discoverable without it. The invite is the key:
  share it only with your own devices. Unlink wipes the local agent state.
- **Store encryption (2026-10-07)**: the store's own layer is signed but
  NOT encrypted, so every value W@tch publishes (sync doc parts, entry
  maps, device records) is sealed app-side with ChaCha20-Poly1305 under
  `blake3::derive_key("watchit.mywatch.store.v1", link secret)`, format
  `wenc1 ‖ 12-byte random nonce ‖ AEAD` with **AAD = the store key
  string** (a sealed value is bound to its slot — no cross-slot
  replay). Values that do not open — plaintext from an injector,
  garbage, wrong key, tampered — are skipped, which also keeps
  anything a topic-holder without the secret writes out of the merge,
  and the on-disk store snapshots now hold sealed bytes by
  construction. The topic domain bumped to v2 with the same change, so
  sealed and plaintext eras never mix in one store and harvested v1
  topic strings lead nowhere.
- **Reverse-QR pairing (alpha.102)**: a device
  with a screen but no camera (TV, desktop) joins by *showing* a
  `wtchp2-` pairing code (`wtchp1-` was the pre-encryption label,
  rejected with the same update-first message) — an ephemeral x25519
  public key + 16-byte
  nonce rendered as a branded QR. A linked phone scans it and
  publishes the group's existing 32-byte link secret on a short-lived
  rendezvous gossip topic (blake3 of the nonce), sealed to the code's
  key with a fresh-per-seal x25519 exchange + ChaCha20-Poly1305; the
  joiner decrypts and runs the normal join, so it lands in the SAME
  My W@tch. The receiver runs a throwaway agent in its own directory
  (wiped per attempt) and acks with the ciphertext's blake3; codes
  expire after 10 minutes and every attempt uses a fresh key + nonce.
  Any linked device can onboard the next — there is no "original"
  device, since all linked devices hold the same secret.
- **What syncs** (background cycle every 30 s, app-wide — no screen needs
  to be open; plus a manual "Sync now"): each device publishes a sync doc
  under its own store keys. Watch lists merge by title with
  last-writer-wins add/remove semantics (removal tombstones, so a delete
  on one device deletes everywhere); viewing positions merge
  newest-wins and never regress; entries arrive **playable**, because
  each entry's *shrunk* data map (a few hundred bytes regardless of file
  size) travels in the store and is expanded locally on import.
  File renames travel too (alpha.97, newest-stamp-wins by rename time),
  playlists arrive as playlists, and a playlist's drag-reordered play
  order follows (alpha.98, newest-reorder-wins with a deterministic
  tie-break so devices converge). Since 2026-09-27 (alpha.108) the
  whole family of viewing profiles syncs too — every profile, its
  avatar (via the artwork transfer), PIN pair, kid allow-list and its
  OWN watch points, with delete-everywhere tombstones — see the
  Profiles bullet under "Data & state" and
  `app/lib/services/profile_sync.dart`.
- **Capacity — sharding + rotation (alpha.96/.98)**: store values are
  byte-capped, and a large library's doc doesn't fit in one. Since
  alpha.96 the doc builder trims until the doc ALWAYS fits (down to
  list entries, last); since alpha.98 the doc additionally **shards**
  across up to three store keys (`sync` + `sync/N` — part 0 alone
  carries the removal tombstones, so older builds see a
  safe partial view) and **rotates** whatever still doesn't fit, so
  the dropped tail leads the next cycle and everything reaches the
  other devices over the following cycles — nothing starves. Receivers
  fold the parts back together; the merge is union-based, so a partial
  doc can never delete anything.
- **User edits + artwork (alpha.62)**: `userEdited` metadata rows
  (titles, years, descriptions, episode names) travel inline in the sync
  doc, merged last-writer-wins by edit time. Artwork is too big for the
  store's value caps, so the doc carries only a **sha256 manifest**; a
  device missing the bytes pulls the file directly from any *online*
  linked device that has it (a pull-based chunk protocol over x0x direct
  messages, hash-verified) — full quality, byte-identical, never
  downscaled. Any device that completes the pull re-serves the file, so
  the original editor doesn't have to stay online forever.
- **TMDB metadata for keyless devices (post-alpha.62)**: full TMDB
  matches (titles, descriptions, ratings, categories, episode stills,
  show/season texts) and their poster files sync between linked devices
  too, so a device *without* a TMDB API key gets the complete
  experience from one that has a key. Each doc publishes a compact
  `have` list (8-hex hashes of the library keys whose metadata and
  artwork the device already holds); a device publishes its TMDB rows
  — with per-show/per-season texts deduplicated and a sha256 file
  manifest — only for keys some linked device still reports missing,
  so the section drains to nothing at steady state. Receivers fill
  only missing rows and cached misses (a user edit or an own TMDB
  match always wins) and pull the artwork bytes over the same x0x
  transfer, saved under the original TMDB file names — a synced
  device re-serves both rows and files to devices joining later.
- *(Historical: from alpha.65 to 2026-09-27 the sync doc also carried a
  `channels` section syncing public-channel subscriptions between
  linked devices — removed together with the whole Channels feature.)*
- **Presence & status**: 60 s heartbeats drive the My W@tch screen's
  per-device online dots, last-heard times, and the persisted "Last sync"
  stamp. Server routes (`GET/DELETE /mywatch`, `POST /mywatch/link|join|
  announce`, `GET /mywatch/invite`, `POST /mywatch/sync|art/index|art/
  fetch`, and for pairing `POST /mywatch/pair/start|send|cancel` +
  `GET /mywatch/pair`) sit behind the same `x-watchit-auth` shared
  secret as Upload.
- **Platforms**: desktop and Android (verified end-to-end on real
  hardware, desktop AppImage ↔ Android phone); iOS is stubbed out for
  now. Devices must be online *together* for changes to travel — there is
  no relay in the middle, by design.

### Seed-phrase backup (implemented 2026-10-06, shipped in alpha.110)

The all-devices-lost recovery layer (`native/watchit_core/src/backup.rs`
+ `app/lib/services/backup.dart`, Settings → Backup): the FULL state —
lists + entries, ROOT data maps, user edits, TMDB rows, posters/art,
watch states, profiles — published to Autonomi under keys derived
OFFLINE from the upload wallet, so the 12 words restore it anywhere.
Derivation (SIGN-TO-DERIVE since the hw-wallet plan's phase 1,
2026-10-10): the wallet signs the frozen versioned
`IDENTITY_MESSAGE_V1` (EIP-191 personal-sign, RFC-6979 deterministic —
signed twice and compared as a determinism guard, because a
non-repeating signer would mint an identity nothing could re-derive);
`blake3::derive_key("watchit.backup.identity.v1", r‖s)` is the root,
`watchit.backup.pointer.v2` seeds an ML-DSA-65 owner pair whose
`autonomi.pointer.address.v1` pointer address is the backup's location,
and `watchit.backup.enc.v2` yields the ChaCha20-Poly1305 content key. A
hardware wallet signing the same message lands on the SAME identity
without its key ever leaving the device (`derive_keys_from_signature`
is the phase-3 seam). The pre-phase-1 raw-key derivation
(`…pointer.v1`/`…enc.v1` straight over the key bytes) is kept as
`derive_keys_legacy` purely so restores fall back to the old line when
the new pointer is empty; `backup_state.json` is identity-stamped so a
changed identity starts a clean line (fresh head chain, no stale object
cache), and `GET /backup` hides a `last` recorded under a different
identity so the phase-2 key share never advertises an empty line. Storage is a content-addressed encrypted object store:
each object (the sync-doc-shaped state document, the root-map bundle,
each artwork file) is encrypted DETERMINISTICALLY (key/nonce from the
backup key ‖ the object's blake3 content hash), so unchanged objects
are byte-identical ciphertext → identical chunks → re-backups are
nearly free via network dedup (a local `backup_state.json` skips the
upload rounds entirely for known hashes). An encrypted manifest lists
the objects with their private shrunk data maps; its map rides in an
encrypted HEAD chunk that also links the previous head (free walkable
history); the pointer targets the head. Nothing is plaintext on the
network except the pointer record itself. Writes are paid (the wallet
client: per-object `data_upload`, `chunk_put` for the head,
`pointer_update`); READS ARE FREE — restore needs no wallet funds and
no linked device: `pointer_get` → head → manifest → objects, root maps
imported straight into the local map store (so restored entries play),
artwork staged for the app, and the state document applied through the
EXACT My W@tch sync merge rules (LWW everywhere — a restore never
regresses newer local state). The backup complements the x0x link, it
never replaces it (decided 2026-10-06): gossip stays the free live
two-way channel; the backup is the paid, slow-cadence, one-writer
recovery layer on the wallet-holding device. Routes (token-guarded):
`GET /backup`, `POST /backup/run`, `POST /backup/restore`,
`POST /backup/peek`, `POST /backup/follow`.

Phase 2 — shared read keys (implemented 2026-10-06, shipped in alpha.110): the
wallet holder publishes its derived READ keys (pointer address +
content key — never the wallet key, so spend stays put) as a tiny
`backup` section in its My W@tch sync doc, which already travels
encrypted in the link store. Linked devices adopt the newest shared
keys (`app/lib/services/backup_follow.dart`; a device never follows
its own line) and poll the backup on a slow cadence — launch + every
6 h + immediately when a linked doc advertises a newer backup —
peek-first: `POST /backup/peek` is one free `pointer_get`, and the
full `POST /backup/follow` fetch (job kind `follow`, the same walk as
a restore with explicit keys) runs only when the head moved. The fold
reuses the restore merge wholesale, so an offline-while-the-others-
synced device catches up from the backup instead of needing to be
online together. The same service runs the opt-in daily automatic
backup on the master (Settings → Backup switch, default OFF; a
payload fingerprint skips unchanged state so no-change days spend
nothing). Keys deliberately do not rotate on unlink: rotation would
re-encrypt every object (full re-upload) while the removed device
keeps the old keys anyway — replacing the wallet starts a new backup
line.

At-rest hardening (2026-10-10, shipped in alpha.113 — hardware-wallet
plan phase 4's recommended-now piece): the follower's adopted read keys no
longer persist in plaintext `backup_follow.json` — they live in the
core's keychain store (`Engine::follow_keys`, the wallet.rs
`WalletStore::named` idiom: OS keychain with a 0600 `follow.keys`
fallback) behind `GET/POST/DELETE /backup/followkeys`; the Dart
service caches them in memory and migrates a pre-keychain state
file's plaintext pair into the keychain on first launch, stripping
the file only after the store confirmed. The state file keeps only
non-secret bookkeeping (stamps, applied head, fingerprints).

Low-data mode (2026-10-08, shipped in alpha.112): a per-device switch on the
linked My W@tch screen (`app/lib/services/low_data_mode.dart`, pref
`low_data_mode_v1`) that keeps the x0x agent off — the idle mesh
costs ~tens of MB per minute just by being connected — and lets the
backup follower above carry the sync (free pointer reads). "Sync
now" then runs a bounded live burst: agent on → join → one full sync
cycle both ways → a short linger so the published store deltas
gossip out → agent off regardless of outcome, behind a dialog that
names the real cost (~100–150 MB per session). Enabling clears any
mobile-data-gate pause; a manual Data-page pill change or an unlink
clears the mode. Ride-along: a backup-first bootstrap gate
(`MyWatchSync.bootstrapGate` →
`BackupFollowService.deferGossipMergeFor`) defers the gossip merge
on a device that holds (or is just receiving) shared read keys and
has never folded that backup in, so one bulk backup fetch populates
it instead of many doc-budget cycles — the own publish still runs,
the gate needs keys in sight to activate, and it resolves when the
first follow completes/fails or at a 5-minute deadline.

### Channels — public signed media lists (REMOVED 2026-09-27)

The public content space (Ed25519 channel identities with `wchn1-…`
codes, publicly uploaded signed manifests, heads gossiped on an x0x
topic, subscribe-by-code amber channel lists, channel publishing)
shipped in alpha.65 and was **removed entirely on 2026-09-27** after a
publishing-liability review — W@tch has no public publishing surface
anymore. My W@tch + Upload (both private) are unaffected; the Terms of
Use dropped their public-channels section (now v3), and drift schema
v17 dropped the channel columns and lists. History in
[PLAN-personal-vs-channels.md](PLAN-personal-vs-channels.md)
(historical) and the git history of this file.

### Playback

- `media_kit` (libmpv) everywhere; plays local files (downloads) and the embedded
  localhost streaming URL.
- Subtitles: embedded + sidecar; external subtitle files can be their own list entries
  attached to a media entry (open question 3).
- Watch state: position saved to SQLite every few seconds during playback and on
  player exit; ≥95% watched marks the title as watched (shipped in alpha.29).

### Data & state

- **SQLite (drift)** — lists, metadata cache, watch history, resume points, download
  index, settings.
- **Playlists (alpha.97/.98)** — a playlist is a media list with
  `kind = 'playlist'` (schema v14): entries are address references
  into the library, row position is the play order (`ordered_at`,
  schema v15, stamps reorders for sync), and playlists are excluded
  from home rows, move/copy targets, and the personal sync doc's
  list-membership semantics they don't share. No new entity, so
  bundles/export/import needed no format change.
- **Riverpod** — app state management.
- **Profiles (alpha.93)** — Netflix-style family viewing profiles are
  a *viewing-state scope*, not accounts: watch positions, favourites
  and colour scheme are keyed per profile (drift schema v13 —
  `profiles` + `profile_list_access` tables, `watch_states.profile_id`),
  while the library, downloads, wallet and the network
  identity stay install-global. PINs are salted-hashed and rate-limited —
  stretched with Argon2id since 2026-10-11 (parameters embedded in the hash
  with hostile-input ceilings, since hashes travel to link members over the
  profiles sync; legacy single-SHA-256 hashes still verify and upgrade on
  the next successful entry) — and the
  admin PIN has a one-time recovery code, itself stored hashed. Since
  alpha.95 profiles can optionally ride a library bundle (export
  checkbox → `profiles.json` + avatar members; import merges by name,
  device wins — old importers ignore the members). Since 2026-09-27
  (alpha.108) profiles also sync automatically over My W@tch: the
  sync doc's `profiles` section carries every profile (name/kind,
  avatar manifest, PIN pair, kid allow-list titles) plus EACH
  profile's own watch points, merged last-writer-wins on a per-profile
  edit stamp with deletion tombstones (schema v18: `updated_ms` +
  stable cross-device `sync_id`); the admin profile's watch states
  keep riding the doc's top-level `watch` section for old builds. A
  per-device "Show on this device" toggle (never synced) hides a
  profile from the picker locally without unsyncing it.
- No accounts, no cloud. Lists, watch state, and user edits sync between a
  user's own linked devices via My W@tch (above) — device-to-device, no
  third party holds anything.

## Platform packaging

| Platform | Artifact | Notes |
|---|---|---|
| Android | APK / AAB | targetSdk 34; dual-ABI (armeabi-v7a + arm64-v8a) since alpha.98; Play Store optional, sideload-friendly |
| Android TV | same APK / AAB | leanback launcher entry + TV banner since alpha.95, full TV UX since alpha.96; the dual-ABI APK installs directly on 32-bit-app devices (Fire TV Stick, Google TV Streamer); Play Store TV listing optional |
| iOS | IPA | needs Apple dev account; TestFlight first |
| Linux | AppImage + Flatpak | AppImage matches existing workflow |
| Windows | portable zip | CI-built, ships with every release since alpha.55; unsigned (SmartScreen "More info → Run anyway"), installer/signing deferred to beta |
| macOS | .dmg | CI-built universal (Apple Silicon + Intel) dmg with bundled ffmpeg, ships with every release since alpha.92; unsigned (right-click → Open), notarization deferred to beta |

## Repo layout

```
Watch-It/
├── app/                       # Flutter project
│   ├── lib/
│   │   ├── db/                # drift database (lists, metadata cache)
│   │   ├── services/          # embedded client FFI, library store, metadata
│   │   │                      #   matcher, TMDB client, datamap/bundle
│   │   │                      #   import/export, downloads, connectivity,
│   │   │                      #   publish plan/API, ffmpeg, update check,
│   │   │                      #   My W@tch sync
│   │   ├── screens/           # home wall, show/season/detail, player,
│   │   │                      #   media lists, My W@tch, publish, settings
│   │   ├── widgets/           # shared UI (detail header, …)
│   │   └── main.dart
│   ├── third_party/           # vendored media_kit_video (Linux H/W patch)
│   └── ...platform dirs
├── native/watchit_core/       # embedded Rust client (ant-core, axum, caches)
├── scripts/                   # release_build.sh, build_appimage.sh
├── docs/
└── README.md
```

## Open questions

1. ~~Gateway sidecar vs Rust FFI~~ — **resolved**: embedded Rust FFI client with an
   in-process localhost server (see Autonomi access).
2. ~~TMDB API key strategy~~ — **re-resolved (alpha.34): keyless by design.**
   Alpha.24–.33 bundled a shared key via `--dart-define=TMDB_API_KEY`; that key
   is strings-extractable from shipped binaries, so official builds no longer
   bundle one. Users enter their own free key in Settings → Metadata (v3 API
   key or v4 read access token); a one-time dismissible banner on home nudges
   keyless users there. Without a key, cards fall back to parsed file names —
   and `.watch-list` bundles carry metadata + posters, so bundle-importing
   users need no key at all. The repo-root `.env` remains for dev runs and
   live tests only.
3. Subtitles for streamed items: sidecar files as linked list entries, or embedded-only
   in v1?
4. ~~List format~~ — **re-resolved (alpha.40): the `.watch-list` bundle is the
   only interchange format.** The alpha.25 plain-text `<xor-address> <name>`
   list was removed together with public-XOR entries; bundle spec v2 carries
   raw `.datamap` members named by original filename plus an optional
   filename-line `list.txt` — see [BUNDLE-FORMAT.md](BUNDLE-FORMAT.md)
   (v1 bundles convert at the import border during the deprecation window).
5. ~~Streaming seek~~ — **resolved**: range/offset fetch verified byte-exact against
   the live network; with the chunk cache, keep-ahead prefetch, and the local
   map store, seek and warm starts are fast. The old cold-first-resolve UX
   cost (~20–30s per new title) is gone since alpha.40 — maps arrive at
   import time by construction.
