# Architecture

## Framework decision

**Recommendation: Flutter + media_kit (libmpv).**

| Option | All 5 platforms? | Player engine | Notes |
|---|---|---|---|
| **Flutter** | ✅ yes, first-class | `media_kit` wraps libmpv on all platforms | Single UI codebase, 120fps UI, proven media apps. **Recommended.** |
| Kotlin Multiplatform | UI (Compose MP) still maturing on iOS/desktop | wrap ExoPlayer/AVPlayer/libmpv per platform | More per-platform work |
| React Native | desktop via forks (Windows/macOS ok, Linux weak) | react-native-video | Linux support is the blocker |
| Tauri 2 | ✅ incl. mobile | web `<video>` or mpv sidecar | Web video stack = codec pain; mpv integration is hacky |
| Qt/QML | ✅ | libmpv | Great engine story, slower UI dev, licensing friction |

Why Flutter wins here: it is the only stack where *both* the UI and the playback engine
(libmpv via `media_kit`) are first-class on all five targets, including Linux. libmpv
gives us every codec/container, subtitle rendering, and hardware decode without
per-platform player code.

## High-level structure

```
┌─────────────────────────────────────────────┐
│                Flutter UI                    │
│   (library, detail pages, player, settings)  │
├─────────────────────────────────────────────┤
│               App core (Dart)                │
│  library index · watch state · settings      │
│  metadata matcher · playback controller      │
├──────────────┬──────────────┬───────────────┤
│ Local source │ Jellyfin API │ Autonomi src  │
│ (file scan)  │ (Silo/Emby/  │ (AntTP HTTP   │
│              │  Jellyfin)   │  gateway)     │
├──────────────┴──────────────┴───────────────┤
│        media_kit / libmpv playback           │
└─────────────────────────────────────────────┘
```

### Media sources — one plugin interface

Every source implements the same interface: `listLibraries()`, `listItems()`,
`getStreamUrl(item)`, `reportProgress(item, position)`. Sources:

1. **LocalSource** — recursive folder scan; filename parsing (`Movie (2023).mkv`,
   `Show/S01E02.mkv`); metadata lookup via TMDB API (user-supplied or shared key);
   artwork cached locally. Index stored in SQLite (`drift` package).
2. **JellyfinSource** — the open Jellyfin REST API (also spoken by Silo and largely by
   Emby). Gets us server libraries, artwork, watch-state sync, and transcode fallback
   (server decides direct-play vs transcode) essentially for free.
3. **AutonomiSource** *(proposed, phase 3)* — plays `ant://<address>` content by
   resolving through a local or public **AntTP** gateway (HTTP range requests →
   seekable streaming). Library = user-saved addresses + optional published indexes.

### Playback

- `media_kit` (libmpv) everywhere: direct play of anything local/HTTP.
- Seekable network playback relies on HTTP range support (Jellyfin ✅, AntTP ✅).
- Subtitles: embedded + sidecar files + Jellyfin subtitle streams.
- Watch state: positions saved every ~10s to SQLite; pushed to Jellyfin when connected.

### Data & state

- **SQLite (drift)** — library index, watch history, resume points, settings.
- **Riverpod** — app state management.
- No accounts, no cloud. Optional future: sync watch-state via a file on Autonomi.

## Platform packaging

| Platform | Artifact | Notes |
|---|---|---|
| Android | APK / AAB | targetSdk 34; Play Store optional, sideload-friendly |
| iOS | IPA | needs Apple dev account; TestFlight first |
| Linux | AppImage + Flatpak | AppImage matches existing workflow |
| Windows | MSIX / portable zip | |
| macOS | .dmg | notarization needed for distribution |

## Repo layout (planned)

```
Watch-It/
├── app/                  # Flutter project
│   ├── lib/
│   │   ├── core/         # models, db, playback controller
│   │   ├── sources/      # local / jellyfin / autonomi
│   │   ├── ui/           # screens & widgets
│   │   └── main.dart
│   └── ...platform dirs
├── docs/
└── README.md
```

## Open questions

1. TMDB API key strategy — bundled shared key vs bring-your-own (rate limits).
2. Autonomi: bundle a local AntTP, or talk to a configurable gateway URL? (Bundling
   ant/AntTP as a sidecar binary is easy on desktop, harder on iOS.)
3. iOS release: worth the $99/yr + review friction in v1, or TestFlight-only until v2?
4. Min Flutter/mpv versions and HDR/tone-mapping expectations per platform.
