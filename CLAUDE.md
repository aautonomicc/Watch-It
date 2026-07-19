# Watch-It

## Description
Cross-platform media player app (Android, iOS, Linux, Windows, macOS) with a Plex/Emby/Silo-style poster-wall library UI. Player/client only — not a server.

## Tech Stack
Flutter + media_kit (libmpv) planned; SQLite via drift; Riverpod. No code yet — design phase.

## Test Commands
None yet (docs only). Later: `flutter analyze`, `flutter test` in `app/`.

## Dev Server
N/A (desktop/mobile app). Later: `flutter run -d linux` in `app/`.

## Current Status
Design phase. Vision/architecture/UI/roadmap docs written; no Flutter scaffold yet. Next step: Phase 0 of docs/ROADMAP.md (Flutter scaffold, media_kit playing a file on Linux + Android).

## Architecture Notes
- Three media sources behind one plugin interface: LocalSource (folder scan + TMDB metadata), JellyfinSource (open Jellyfin API — also works with Silo/Emby servers), AutonomiSource (proposed: stream via AntTP HTTP gateway, phase 3 differentiator)
- Playback via libmpv (media_kit) on all platforms — no per-platform player code
- Watch state/resume points in local SQLite; synced to Jellyfin server when connected
- Reference project: github.com/Silo-Server (Go/React media server with Jellyfin-compatible API)
- Repo: github.com/aautonomicc/Watch-It (MIT)

## Recent Changes
- [2026-07-19] Initial design docs: README, docs/VISION.md, docs/ARCHITECTURE.md, docs/UI-DESIGN.md, docs/ROADMAP.md. Framework decision: Flutter + media_kit.
