# Watch-It

## Description
Cross-platform media player (Android, Android TV, iOS, Linux, Windows, macOS) for the Autonomi network. Client-only — no server side at all, and no Plex/Emby/Jellyfin server compatibility (stripped by design). Plex-style poster-wall UI.

## Tech Stack
Flutter + media_kit (libmpv) planned; SQLite via drift; Riverpod; Autonomi access via WithAutonomi/ant-client (gateway sidecar or Rust FFI — Phase 0 spike decides). No code yet — design phase.

## Test Commands
None yet (docs only). Later: `flutter analyze`, `flutter test` in `app/`.

## Dev Server
N/A (desktop/mobile app). Later: `flutter run -d linux` in `app/`.

## Current Status
Design phase, docs rewritten for the client-only Autonomi model. Next step: Phase 0 of docs/ROADMAP.md (Flutter scaffold + Autonomi fetch/seek spike).

## Architecture Notes
- Library = user-held **lists**; each entry is `{XOR public file address, file name}`. Multiple lists; import/export; later publish/subscribe lists on Autonomi
- Metadata matcher parses file name → TMDB → artwork/description/category (same pipeline media servers use, but on-device); cached in SQLite
- Playback via libmpv (media_kit) everywhere; streaming needs range/offset access to Autonomi content — the key technical risk, spiked in Phase 0
- Download manager for offline: downloaded item = same entry with local path, full library UX offline
- Watch state/resume points local-only in SQLite; no accounts, no telemetry
- Branding follows the etchit.io family (fetch>it/etch/it): ink/bone/copper tokens, system fonts, mono for XOR addresses — see docs/BRAND.md (mirrors etchit-io/fetchit docs/BRAND.md)
- Repo: github.com/aautonomicc/Watch-It (MIT)

## Recent Changes
- [2026-07-19] Android TV added as sixth first-class platform (was in "Later"): same Android APK + leanback launcher entry, D-pad focus nav shared with desktop keyboard map, 10-foot layout mode; scheduled in Phase 4; tvOS stays in Later
- [2026-07-19] Added docs/BRAND.md: colours/fonts/type scale adopted from etchit-io/fetchit brand contract (copper #c9732b accent, dark/dim/light themes, `watch-it` wordmark); UI-DESIGN.md aligned (Inter dropped for system fonts)
- [2026-07-19] Pushed to github.com/aautonomicc/Watch-It (main up to date with origin)
- [2026-07-19] Pivot: removed Jellyfin/Silo/Emby server compatibility and local-folder-scan source; Autonomi (ant-client) is the sole media source. Lists of XOR addresses replace server libraries; stream + download retained. All docs rewritten.
- [2026-07-19] Initial design docs: README, docs/VISION.md, docs/ARCHITECTURE.md, docs/UI-DESIGN.md, docs/ROADMAP.md. Framework decision: Flutter + media_kit.
