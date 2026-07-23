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

### Lists — the library model

A **list** is the unit of library organization. Each entry:

```
{ address: <XOR public file address>, name: "The Movie (2023).mkv" }
```

- Users can hold multiple lists (e.g. "Movies", "Kids", "Docs") and add entries by
  pasting an address + name.
- Lists are plain data → import/export as files, and (later) publish/subscribe to
  lists stored on Autonomi itself.
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
- **Root data-map persistence** — resolved root data maps are content-addressed
  and immutable, so they are stored in SQLite (`root_maps.sqlite`) forever: a
  title's map is fetched from the network at most once per device (cold ~30s for
  a 5GB file, ~7ms from disk afterwards, across app restarts). `GET /resolve/{addr}`
  resolves and persists a map without streaming it — used by prefetch-on-import
  and by warming a title when its detail page opens.

### Downloads / offline

- **Download manager** in app core: queue, progress, pause/resume, per-item location
  under app storage.
- A downloaded item is the same library entry with a local path — full poster/detail/
  resume experience offline. Stream vs downloaded is a playback-source detail, not a
  different library.

### Playback

- `media_kit` (libmpv) everywhere; plays local files (downloads) and the embedded
  localhost streaming URL.
- Subtitles: embedded + sidecar; external subtitle files can be their own list entries
  attached to a media entry (open question 3).
- Watch state: positions saved every ~10s to SQLite.

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
│   │   │                      #   matcher, TMDB client, import, prefetch
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
2. ~~TMDB API key strategy~~ — **resolved (alpha.24)**: official builds bundle a
   shared key via `--dart-define=TMDB_API_KEY`, so metadata works out of the box;
   a user key entered in Settings → Metadata (v3 API key or v4 read access token)
   overrides it. Without any key, cards fall back to parsed file names.
3. Subtitles for streamed items: sidecar files as linked list entries, or embedded-only
   in v1?
4. ~~List format~~ — **resolved (alpha.25)**: plain text, not JSON — optional
   `ListName="..."` section markers, then one `<xor-address> <file name>` per line;
   bad lines skipped and reported, 10MB file cap. Import from a local file or from
   an Autonomi address; the same format will serve export.
5. ~~Streaming seek~~ — **resolved**: range/offset fetch verified byte-exact against
   the live network; with the chunk cache, keep-ahead prefetch, and persisted root
   maps, seek and warm starts are fast. Remaining UX cost is the cold first
   resolve of a new title (~20–30s), mitigated by prefetch-on-import and
   tile-open warm-up.
