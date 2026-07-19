# Roadmap

## Phase 0 — Foundations (1–2 weeks)
- [ ] Flutter project scaffold in `app/` targeting Linux + Android first (dev machines)
- [ ] media_kit playing a local file with basic controls on both
- [ ] CI: `flutter analyze` + `flutter test` on push
- [ ] Decide accent color / app icon

**Exit criteria:** open a video file, play/pause/seek/subtitles, on Linux and Android.

## Phase 1 — Local library MVP
- [ ] Folder picker + recursive scan, filename → title/year/episode parser
- [ ] TMDB metadata + artwork fetch, SQLite cache
- [ ] Home (Continue Watching / Recently Added), Library grid, Detail page
- [ ] Resume points + watched state
- [ ] Packaging: AppImage (Linux) + APK (Android)

**Exit criteria:** point at a movies folder → poster wall → play → resume works after
app restart. First release: v0.1 (Linux AppImage + Android APK).

## Phase 2 — Jellyfin-compatible client
- [ ] Server sign-in (Quick Connect + user/pass), server library browsing
- [ ] Direct play with transcode fallback via Jellyfin API
- [ ] Two-way watch-state sync
- [ ] Windows + macOS builds
- v0.2 release: 4 platforms, local + server sources

## Phase 3 — Autonomi source (differentiator)
- [ ] Play a public Autonomi file via AntTP gateway URL (HTTP range streaming)
- [ ] "Add Autonomi item" — paste address, fetch/attach metadata, appears in library
- [ ] Evaluate bundling AntTP as a desktop sidecar vs configurable gateway
- v0.3 release + a demo video (this is the headline feature)

## Phase 4 — Polish & iOS
- [ ] iOS build + TestFlight
- [ ] Chapter markers, playback speed, external subtitle search
- [ ] Light theme, poster size options, keyboard-map settings
- [ ] Flatpak, MSIX, notarized .dmg
- v1.0: all five platforms

## Later / ideas parking lot
- Trakt scrobbling; watch-state sync between devices via Autonomi scratch file
- Android TV / tvOS layouts (10-foot UI)
- Music & photos libraries
- Chromecast / AirPlay output
- Skip-intro detection
- Publish/browse community Autonomi media indexes
