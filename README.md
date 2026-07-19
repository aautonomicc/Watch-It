# Watch-It

A beautiful, cross-platform media player for the **Autonomi network** — one codebase,
five platforms: **Android, iPhone (iOS), Linux, Windows, and Mac.**

Think the Plex / Emby / [Silo](https://github.com/Silo-Server/) experience —
poster-wall library, rich metadata, resume-watching — but **with no server to install**.
Watch-It is client-only: your media library is one or more lists of publicly available
files on the decentralized [Autonomi](https://github.com/WithAutonomi/ant-client)
network, streamed on demand or downloaded for offline watching.

## How it works

1. **Lists of media.** You keep one or more lists of public media. Each entry is an
   Autonomi **XOR public file address** plus a **file name**.
2. **Metadata from the name.** From the file name (`Movie (2023).mkv`,
   `Show S01E02.mkv`) Watch-It looks up the same public databases the media servers
   use (TMDB) and fetches artwork, description, and category to organize and display
   the collection as a poster-wall library.
3. **Stream or download.** Hit play to stream straight from the network, or download
   an item to the device for offline watching. Downloaded items play with the full
   library experience, no connectivity needed.

No server, no accounts, no telemetry. There is deliberately **no Plex/Emby/Jellyfin
server compatibility** — Autonomi *is* the backend.

## Status

Early design phase. See:

- [docs/VISION.md](docs/VISION.md) — goals, non-goals, target users
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — tech stack decision and app structure
- [docs/UI-DESIGN.md](docs/UI-DESIGN.md) — screens and look-and-feel
- [docs/ROADMAP.md](docs/ROADMAP.md) — phased milestones

## License

MIT
