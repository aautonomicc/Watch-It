# Watch-It

## Description
Cross-platform media player (Android, iOS, Linux, Windows, macOS) for the Autonomi network. Client-only — no server side at all, and no Plex/Emby/Jellyfin server compatibility (stripped by design). Plex-style poster-wall UI.

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
- Repo: github.com/aautonomicc/Watch-It (MIT)

## Recent Changes
- [2026-07-19] Pivot: removed Jellyfin/Silo/Emby server compatibility and local-folder-scan source; Autonomi (ant-client) is the sole media source. Lists of XOR addresses replace server libraries; stream + download retained. All docs rewritten.
- [2026-07-19] Initial design docs: README, docs/VISION.md, docs/ARCHITECTURE.md, docs/UI-DESIGN.md, docs/ROADMAP.md. Framework decision: Flutter + media_kit.
