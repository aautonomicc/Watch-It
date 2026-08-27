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
  **publishing your own file from the app** (desktop, alpha.55+): the
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

### Upload — in-app uploads (shipped alpha.55/.56 as "Publish", renamed Upload 2026-08-27, desktop)

W@tch uploads to Autonomi itself; the `ant` CLI is no longer required for
the write path. Desktop-only for now (needs the bundled ffmpeg and a
windowed flow). Two new Rust modules in `watchit_core`:

- **Wallet** (`wallet.rs`): the payment key lives in the **OS keychain**
  (Windows Credential Manager / macOS Keychain / Secret Service on Linux,
  with a mode-0600 `wallet.key` file fallback when no keychain is
  available — surfaced in the UI). Create is a BIP-39 12-word ceremony
  (retype-confirm before anything persists); import accepts a raw key or a
  phrase (MetaMask-compatible `m/44'/60'/0'/0/0`); the mnemonic itself is
  never stored. Settings → Wallet shows the address and live ANT/ETH
  balances (Arbitrum One). It is deliberately a **hot wallet** — the docs
  and UI say to fund it small.
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
  invite code `wtch1-<hex64>`, shown as a QR code (scannable in-app on
  Android/iOS) or pasted as text. Devices holding the secret meet in a
  self-keyed **CRDT key-value store** on a gossip topic *derived* (blake3)
  from the secret — the secret itself never goes on the wire, and nothing
  about the group is discoverable without it. The invite is the key:
  share it only with your own devices. Unlink wipes the local agent state.
- **What syncs** (background cycle every 30 s, app-wide — no screen needs
  to be open; plus a manual "Sync now"): each device publishes a sync doc
  under its own store keys. Watch lists merge by title with
  last-writer-wins add/remove semantics (removal tombstones, so a delete
  on one device deletes everywhere); viewing positions merge
  newest-wins and never regress; entries arrive **playable**, because
  each entry's *shrunk* data map (a few hundred bytes regardless of file
  size) travels in the store and is expanded locally on import.
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
- **Presence & status**: 60 s heartbeats drive the My W@tch screen's
  per-device online dots, last-heard times, and the persisted "Last sync"
  stamp. Server routes (`GET/DELETE /mywatch`, `POST /mywatch/link|join|
  announce`, `GET /mywatch/invite`, `POST /mywatch/sync|art/index|art/
  fetch`) sit behind the same `x-watchit-auth` shared secret as Upload.
- **Platforms**: desktop and Android (verified end-to-end on real
  hardware, desktop AppImage ↔ Android phone); iOS is stubbed out for
  now. Devices must be online *together* for changes to travel — there is
  no relay in the middle, by design.

### Channels — public signed media lists (2026-08-27, unreleased)

The PUBLIC content space (docs/PLAN-personal-vs-channels.md; My W@tch +
Upload are the private space). A **channel** is an Ed25519 identity:
its code `wchn1-<base32(pubkey)>` is the subscribe handle, its secret
key is derived from the channel's own 12-word BIP-39 phrase (SLIP-0010
ed25519 master key — deliberately a separate phrase from the disposable
hot wallet) via the same show-words → retype-3 ceremony the wallet
ships, and stored in the OS keychain beside the wallet key
(`native/watchit_core/src/channel.rs`, `channels.rs`; Dart side
`services/channel_service.dart` + `channels_api.dart`,
`screens/channels_screen.dart` + `describe_item_screen.dart`).

- **Manifest**: a bundle-spec-v2 zip (datamap members + metadata.json +
  posters — the required Describe-this-item edits travel as `userEdited`
  rows, so keyless subscribers render fully offline) plus
  `channel.json` (name/description/pubkey + advisory seq/previous
  history chain). Uploaded PUBLICLY — ant-core's
  `file_upload_public_with_progress` stores the serialized data map as
  a fetchable chunk in the same payment batch, so anyone holding the
  address fetches it via `data_map_fetch` + `data_download`
  (`GET /channel/manifest/{addr}` — the only network data-map fetch in
  the app; entries themselves stay datamap-first).
- **Head distribution** (the mutability layer): the owner gossips a
  signed head record `{seq, manifest, sig}` into a self-keyed CRDT KV
  store on an x0x topic derived from the channel pubkey. The topic is
  public by construction; the store accepts strangers' writes, so heads
  are trusted purely by Ed25519 signature — readers verify and follow
  the highest valid seq. Subscribers replicate the store, so late
  joiners get the newest head from any online subscriber; the owner
  need not stay online. The channels agent lives under
  `<data>/channels/` with its own identity, independent of the My W@tch
  agent.
- **Subscribing** (`POST /channel/subscribe`, works on every platform):
  the app follows the verified head, fetches + imports the manifest as
  a read-only amber-badged **channel list** (media_lists.channel_pubkey,
  schema v10) that renders on the normal home wall/drawer and replaces
  wholesale when a newer signed head arrives (5-min background check +
  manual refresh). Unsubscribe deletes the list + replicated store.
- **Publishing** (desktop-only, needs the wallet): items enter one
  explicit pick at a time — pick → required Describe-this-item (title,
  description, artwork mandatory; saved as a normal Edit-details row;
  a **Check TMDB** button looks the item up with the typed title/year
  when a TMDB key is configured — public-domain classics ARE in the
  database — previews the match, and on accept stores the full row
  incl. rating/genres/poster through the normal metadata pipeline, so
  those extras reach keyless subscribers via the manifest)
  → per-item rights attestation → staged; Publish update builds the
  manifest, shows a live cost preview (`/upload/estimate` + balance),
  runs the paid public upload job (`POST /channel/publish`, same job
  surface as Upload + an `announcing` phase for the head) and bumps the
  seq. Since self-encryption is deterministic, chunks of an
  already-uploaded item cost nothing — only the manifest is new.
- **Safety rails** (plan Part 3): "publish" is reserved for channels
  ("upload" = private); every channel surface is amber with a PUBLIC
  badge (blue = private); separate drawer doors (never a toggle on
  Upload); full-screen public/permanent/attributable gate with
  type-the-channel-name confirm before the channel exists; Terms v2
  adds the channel-publishing section (kTermsVersion 2 → re-prompt).
- **Recovery**: losing the key freezes the channel at its last head
  forever, so backup IS creation (the ceremony runs before the channel
  exists). "Restore channel" re-derives the same key/code from the
  phrase, learns its own newest head from the gossip store, and pulls
  the manifest back to repopulate the item list.

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
- **Riverpod** — app state management.
- No accounts, no cloud. Lists, watch state, and user edits sync between a
  user's own linked devices via My W@tch (above) — device-to-device, no
  third party holds anything.

## Platform packaging

| Platform | Artifact | Notes |
|---|---|---|
| Android | APK / AAB | targetSdk 34; Play Store optional, sideload-friendly |
| Android TV | same APK / AAB | leanback launcher entry + TV banner asset; sideloads onto any TV box; Play Store TV listing optional |
| iOS | IPA | needs Apple dev account; TestFlight first |
| Linux | AppImage + Flatpak | AppImage matches existing workflow |
| Windows | portable zip | CI-built, ships with every release since alpha.55; unsigned (SmartScreen "More info → Run anyway"), installer/signing deferred to beta |
| macOS | .dmg | notarization needed for distribution |

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
