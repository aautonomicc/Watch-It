# Watch-It

A beautiful, cross-platform media player app — one codebase, five platforms:
**Android, iPhone (iOS), Linux, Windows, and Mac.**

Think the Plex / Emby / [Silo](https://github.com/Silo-Server/) client experience —
poster-wall library, rich metadata, resume-watching — but as a lightweight open-source
player you own, with no account, no telemetry, and no server required to get started.

## What it is

- A **media player and library browser**, not a server. It plays:
  1. **Local files** — point it at folders on your device; it scans, matches metadata,
     and builds a poster-wall library.
  2. **Jellyfin-compatible servers** — connect to Jellyfin, Silo, or Emby servers using
     the open Jellyfin API, so Watch-It works as a polished universal client.
  3. *(Proposed)* **Autonomi network content** — stream media from the decentralized
     Autonomi network via an AntTP HTTP gateway. This would make Watch-It the first
     media player with native decentralized-storage playback.

## Status

Early design phase. See:

- [docs/VISION.md](docs/VISION.md) — goals, non-goals, target users
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — tech stack decision and app structure
- [docs/UI-DESIGN.md](docs/UI-DESIGN.md) — screens and look-and-feel
- [docs/ROADMAP.md](docs/ROADMAP.md) — phased milestones

## License

MIT
