# Roadmap

**Status (2026-07-23):** v0.1.0-alpha.28 released ([GitHub Releases](https://github.com/aautonomicc/Watch-It/releases))
— signed Android APK + Linux AppImage on every release. Phase 0 is done and Phase 1
is mostly done: both platforms stream from the live Autonomi network via the embedded
Rust client (`native/watchit_core`) with byte-exact seek, a chunk LRU cache with
keep-ahead prefetch, and resolved root data maps persisted in SQLite (any title's
map is fetched from the network at most once per device — cold ~30s, then ~7ms
across restarts). The library is a full poster-wall experience: TMDB metadata from
file names (key bundled in official builds since alpha.24; BYO key overrides),
show-level grouping on the home wall, big-artwork Show → Season → Detail pages with
ratings, air dates, and episode screenshots, list import from file or Autonomi
address with prefetch-on-import, and a Media Lists management page. Still open in
Phase 1: Continue Watching / Recently Added rows and resume points. The seeded
default movie is an H.264 8-bit 1080p encode named per the Plex/Jellyfin
convention — see [NAMING.md](NAMING.md).

## Phase 0 — Foundations (1–2 weeks)
- [x] Flutter project scaffold in `app/` targeting Linux + Android first (dev machines)
      → both fully working; Linux ships as AppImage with a vendored
      media_kit_video H/W-rendering patch (alpha.18/.20)
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
of an Autonomi-hosted file by address. → **Met on both platforms.**

## Phase 1 — Lists + metadata MVP
- [x] List model in SQLite; add-entry flow (paste XOR address + file name)
      → add/edit/remove entries via the Media Lists page (create, show/hide,
      rename/delete lists); lists persist in SQLite (drift) with a one-time
      import of the shared_preferences blob earlier alphas wrote
- [x] Filename → title/year/episode parser; TMDB artwork/description/category fetch,
      cached locally → done: parser handles Plex/Jellyfin + release-style names and
      S01E02/1x02 episode markers; TMDB matching (exact /find by IMDb id, else
      title/year search) cached in SQLite with poster files on disk; official
      builds bundle a key since alpha.24, a user key in Settings → Metadata
      overrides it
- [ ] Home (Continue Watching / Recently Added), Library grid, Detail page
      → home poster wall with show-level grouping (all seasons of a show under
      one tile) + network status bar; big-artwork ShowScreen → SeasonScreen
      (episode tiles with TMDB screenshots, air dates, synopses) → DetailScreen
      with ratings (alpha.26–.28); Continue Watching / Recently Added rows not yet
- [x] Stream playback from Autonomi via the Phase-0 mechanism → done, plus a
      chunk LRU cache with keep-ahead prefetch (~64 MiB warm during playback)
      and root data maps persisted in SQLite — network resolve at most once per
      title per device, `/resolve` endpoint + prefetch-on-import with a
      hideable/resumable progress dialog, tile-open map warm-up (alpha.28)
- [ ] Resume points + watched state
- [x] Packaging: AppImage (Linux) + APK (Android)
      → signed APK + AppImage on every GitHub Release; built by
      scripts/release_build.sh as a systemd user unit

**Exit criteria:** paste addresses → poster wall with real artwork → press play →
streams from the network → resume works after app restart. v0.1 release.
→ **All met except resume**; Continue Watching + resume points are the remaining
Phase 1 work.

## Phase 2 — Downloads & offline
- [ ] Download manager: queue, progress, pause/resume, storage settings
- [ ] Offline library: downloaded items fully browsable/playable with no connectivity
- [ ] Card badges for stream/downloading/downloaded state
- [x] List **import** as files — pulled forward, shipped in alpha.25: local file
      picker or download from Autonomi by XOR address; multi-list files via
      `ListName="..."` sections; merge / create-new / skip on name clash; 10MB cap
- [ ] List **export** as files
- [x] Storage controls — pulled forward, shipped in alpha.28: Size on disk +
      double-confirmed Clear all data (factory reset) in Settings → About
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
