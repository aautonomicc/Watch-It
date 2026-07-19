# Roadmap

## Phase 0 — Foundations (1–2 weeks)
- [ ] Flutter project scaffold in `app/` targeting Linux + Android first (dev machines)
- [ ] media_kit playing a local file with basic controls on both
- [ ] **Autonomi spike**: fetch a known public file by XOR address with ant-client;
      test range/offset access → decide gateway-sidecar vs Rust-FFI
- [ ] CI: `flutter analyze` + `flutter test` on push
- [ ] Decide accent color / app icon

**Exit criteria:** play a video file on Linux and Android, and prove seekable playback
of an Autonomi-hosted file by address.

## Phase 1 — Lists + metadata MVP
- [ ] List model in SQLite; add-entry flow (paste XOR address + file name)
- [ ] Filename → title/year/episode parser; TMDB artwork/description/category fetch,
      cached locally
- [ ] Home (Continue Watching / Recently Added), Library grid, Detail page
- [ ] Stream playback from Autonomi via the Phase-0 mechanism
- [ ] Resume points + watched state
- [ ] Packaging: AppImage (Linux) + APK (Android)

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
