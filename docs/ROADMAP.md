# Roadmap

**Status (2026-07-20):** v0.1.0-alpha.16 released ([GitHub Releases](https://github.com/aautonomicc/Watch-It/releases))
— signed Android APK + Linux AppImage. Phase 0 is done: both platforms stream a real
movie from the live Autonomi network via the embedded Rust client
(`native/watchit_core`), with seek, buffering progress, configurable buffer size,
etchit-family branding, and CI on every push. The seeded default movie is now an
H.264 8-bit 1080p encode (hardware-decodable on phones and older desktops, replacing
the AV1 10-bit original) named per the Plex/Jellyfin convention — see
[NAMING.md](NAMING.md). Phase 1 is partially started.

## Phase 0 — Foundations (1–2 weeks)
- [x] Flutter project scaffold in `app/` targeting Linux + Android first (dev machines)
      → Android fully working; Linux desktop blocked on toolchain
      (clang/ninja/libgtk-3-dev not yet installed)
- [x] media_kit playing with basic controls → done on Android, streaming from the
      network; player controls lifted clear of the nav bar, thicker seek bar (alpha.11)
- [x] **Autonomi spike**: fetch a known public file by XOR address;
      test range/offset access → done: embedded Rust-FFI client (watchit_core),
      HTTP Range seek verified byte-exact against the live network
- [x] CI: `flutter analyze` + `flutter test` on push → GitHub Actions
      (.github/workflows/ci.yml), pinned Flutter 3.44.6, runs on push to main + PRs
- [x] Decide accent color / app icon → copper #c9732b accent; adaptive `[>]` chevron
      icon on ink, app-bar wordmark lockup matches (alpha.12); see BRAND.md

**Exit criteria:** play a video file on Linux and Android, and prove seekable playback
of an Autonomi-hosted file by address. → **Met on Android** (streaming + seek proven);
Linux playback pending the desktop toolchain.

## Phase 1 — Lists + metadata MVP
- [x] List model in SQLite; add-entry flow (paste XOR address + file name)
      → add/edit/remove entries via Settings → media lists; lists persist in
      SQLite (drift) with a one-time import of the shared_preferences blob
      earlier alphas wrote
- [x] Filename → title/year/episode parser; TMDB artwork/description/category fetch,
      cached locally → done: parser handles Plex/Jellyfin + release-style names and
      S01E02/1x02 episode markers; TMDB matching (exact /find by IMDb id, else
      title/year search) cached in SQLite with poster files on disk; needs a
      TMDB API key (Settings → Metadata, or --dart-define=TMDB_API_KEY)
- [ ] Home (Continue Watching / Recently Added), Library grid, Detail page
      → home poster grid + network status bar and Detail page (artwork, description,
      Play) exist; Continue Watching / Recently Added rows not yet
- [x] Stream playback from Autonomi via the Phase-0 mechanism → done (alpha.4–.10):
      embedded client, buffering overlay with live MB counter, error surfacing,
      configurable buffer size
- [ ] Resume points + watched state
- [ ] Packaging: AppImage (Linux) + APK (Android)
      → signed APK on GitHub Releases since alpha.1; AppImage pending Linux build

**Exit criteria:** paste addresses → poster wall with real artwork → press play →
streams from the network → resume works after app restart. v0.1 release.

## Phase 2 — Downloads & offline
- [ ] Download manager: queue, progress, pause/resume, storage settings
- [ ] Offline library: downloaded items fully browsable/playable with no connectivity
- [ ] Card badges for stream/downloading/downloaded state
- [ ] List import/export as files
- v0.2 release (Linux + Android)

## Phase 3 — All desktop platforms
- [ ] Windows + macOS builds and packaging (MSIX, .dmg)
- [ ] Keyboard map, window polish, hover thumbnails on seek bar
- [ ] Shared-list format v1 documented; import a list from an Autonomi address
- v0.3 release + demo video (poster-wall streaming from Autonomi is the headline)

## Phase 4 — Android TV, polish & iOS
- [ ] Android TV: leanback launcher entry + TV banner, D-pad focus traversal across
      all screens, 10-foot layout mode, remote player controls; test on a real TV box
- [ ] iOS build + TestFlight (FFI path required if sidecar chosen elsewhere)
- [ ] Chapter markers, playback speed, subtitle handling for streamed items
- [ ] Light theme, poster size options, keyboard-map settings
- [ ] Flatpak + notarized .dmg
- v1.0: all six platforms

## Later / ideas parking lot
- Publish/subscribe community lists on Autonomi (curated "channels")
- Watch-state + list sync between devices via Autonomi
- tvOS (Apple TV) layout — Android TV is now in Phase 4
- Trakt scrobbling
- Music & photos lists
- Chromecast / AirPlay output
- Skip-intro detection
