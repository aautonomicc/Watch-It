# Watch-It

## Description
Cross-platform media player (Android, Android TV, iOS, Linux, Windows, macOS) for the Autonomi network. Client-only — no server side at all, and no Plex/Emby/Jellyfin server compatibility (stripped by design). Plex-style poster-wall UI.

## Tech Stack
Flutter 3.44.6 (SDK at ~/flutter) + media_kit (libmpv) planned; SQLite via drift; Riverpod; Autonomi access via WithAutonomi/ant-client (gateway sidecar or Rust FFI — Phase 0 spike decides).

## Test Commands
In `app/`: `flutter analyze`, `flutter test` (PATH needs `~/flutter/bin`; `source ~/Android/env.sh` for Android builds).

## Dev Server
`flutter run -d linux` in `app/` — blocked until clang/ninja/libgtk-3-dev are apt-installed (Linux desktop toolchain incomplete; Android is fully working).

## Current Status
Phase 0 in progress: scaffold + media list management done (v0.1.0-alpha.2 released). Remaining Phase 0: media_kit local playback, Autonomi fetch/seek spike, CI. Lists persist via shared_preferences (stand-in until drift/SQLite). Release signing: keystore ~/keystores/watchit-release.jks + password in ~/keystores/watchit-key.properties (copy to app/android/key.properties, gitignored). gh CLI authenticated as aautonomicc; publish APKs via `gh release create`.

## Architecture Notes
- Library = user-held **lists**; each entry is `{XOR public file address, file name}`. Multiple lists; import/export; later publish/subscribe lists on Autonomi
- Metadata matcher parses file name → TMDB → artwork/description/category (same pipeline media servers use, but on-device); cached in SQLite
- Playback via libmpv (media_kit) everywhere; streaming needs range/offset access to Autonomi content — the key technical risk, spiked in Phase 0
- Download manager for offline: downloaded item = same entry with local path, full library UX offline
- Watch state/resume points local-only in SQLite; no accounts, no telemetry
- Branding follows the etchit.io family (fetch>it/etch/it): ink/bone/copper tokens, system fonts, mono for XOR addresses — see docs/BRAND.md (mirrors etchit-io/fetchit docs/BRAND.md)
- Repo: github.com/aautonomicc/Watch-It (MIT)

## Recent Changes
- [2026-07-19] v0.1.0-alpha.2: Settings screen (gear on home) — create/rename/delete titled media lists, add/remove entries (file name + XOR address, 64-hex validated); persistence via shared_preferences; lists render on home. 9 tests pass; signed APK on GitHub Release (SHA-256 58be...dee8)
- [2026-07-19] Proper GitHub Release created (gh now authenticated): APK attached to https://github.com/aautonomicc/Watch-It/releases/tag/v0.1.0-alpha.1 (SHA-256 8a9e...60d4); orphan `apk` branch workaround deleted locally and on origin
- [2026-07-19] Phase 0 scaffold: Flutter app in app/ (android+linux), WiTokens ThemeExtension from BRAND.md, branded home screen, widget+token tests. Signed release APK built and verified (cert CN=Watch-It, SHA-256 7911...0a69); tag v0.1.0-alpha.1 pushed; APK copied to ~/watch-it-v0.1.0-alpha.1.apk
- [2026-07-19] Installed Flutter 3.44.6 stable to ~/flutter; Android SDK licenses accepted; release keystore generated (~/keystores/, 30-yr validity)
- [2026-07-19] Android TV added as sixth first-class platform (was in "Later"): same Android APK + leanback launcher entry, D-pad focus nav shared with desktop keyboard map, 10-foot layout mode; scheduled in Phase 4; tvOS stays in Later
- [2026-07-19] Added docs/BRAND.md: colours/fonts/type scale adopted from etchit-io/fetchit brand contract (copper #c9732b accent, dark/dim/light themes, `watch-it` wordmark); UI-DESIGN.md aligned (Inter dropped for system fonts)
- [2026-07-19] Pushed to github.com/aautonomicc/Watch-It (main up to date with origin)
- [2026-07-19] Pivot: removed Jellyfin/Silo/Emby server compatibility and local-folder-scan source; Autonomi (ant-client) is the sole media source. Lists of XOR addresses replace server libraries; stream + download retained. All docs rewritten.
- [2026-07-19] Initial design docs: README, docs/VISION.md, docs/ARCHITECTURE.md, docs/UI-DESIGN.md, docs/ROADMAP.md. Framework decision: Flutter + media_kit.
