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
│  download manager · playback controller       │
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

- Content enters the library exactly two ways: importing `.datamap` files
  (multi-select picker; the file name minus `.datamap` is the media name,
  feeding the metadata matcher) or importing a `.watch-list` **bundle** (a
  zip of datamap members plus TMDB metadata, posters, optional watch
  history) — spec v2 in [BUNDLE-FORMAT.md](BUNDLE-FORMAT.md). Export is the
  bundle, full stop (a name list without maps is unplayable).
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

Known upstream limitation: when the OS network vanishes entirely, ant-core's
`/health` can keep reporting ready with stale peers, so airplane-mode-style
loss may go undetected (VPN-cut / handshake-timeout loss is detected fine).

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
- No accounts, no cloud. Optional future: sync lists + watch-state between devices via
  Autonomi.

## Platform packaging

| Platform | Artifact | Notes |
|---|---|---|
| Android | APK / AAB | targetSdk 34; Play Store optional, sideload-friendly |
| Android TV | same APK / AAB | leanback launcher entry + TV banner asset; sideloads onto any TV box; Play Store TV listing optional |
| iOS | IPA | needs Apple dev account; TestFlight first |
| Linux | AppImage + Flatpak | AppImage matches existing workflow |
| Windows | MSIX / portable zip | |
| macOS | .dmg | notarization needed for distribution |

## Repo layout

```
Watch-It/
├── app/                       # Flutter project
│   ├── lib/
│   │   ├── db/                # drift database (lists, metadata cache)
│   │   ├── services/          # embedded client FFI, library store, metadata
│   │   │                      #   matcher, TMDB client, datamap/bundle
│   │   │                      #   import/export, downloads, connectivity
│   │   ├── screens/           # home wall, show/season/detail, player,
│   │   │                      #   media lists, settings
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
