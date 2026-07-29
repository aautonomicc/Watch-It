# Watch-It

A beautiful, cross-platform media player for the **Autonomi network** — one codebase,
six platforms: **Android, Android TV, iPhone (iOS), Linux, Windows, and Mac.**

Think the Plex / Emby / [Silo](https://github.com/Silo-Server/) experience —
poster-wall library, rich metadata, resume-watching — but **with no server to install**.
Watch-It is client-only: your media library is one or more lists of publicly available
files on the decentralized [Autonomi](https://github.com/WithAutonomi/ant-client)
network, streamed on demand or downloaded for offline watching.

## How it works

1. **Lists of media.** You keep one or more lists of public media. Each entry is an
   Autonomi **XOR public file address** plus a **file name**.
2. **Metadata from the name.** From the file name Watch-It looks up the same public
   databases the media servers use (TMDB) and fetches artwork, description, and
   category to organize and display the collection as a poster-wall library. Name
   files with the Plex/Jellyfin convention —
   `Title (Year) {imdb-ttXXXXXXX} - [quality].ext` — for exact matches; see
   [docs/NAMING.md](docs/NAMING.md).
3. **Stream or download.** Hit play to stream straight from the network, or download
   an item to the device for offline watching. Downloaded items play with the full
   library experience, no connectivity needed.

No server, no accounts, no telemetry. There is deliberately **no Plex/Emby/Jellyfin
server compatibility** — Autonomi *is* the backend.

## Status

**Working alpha on Android and Linux** — [v0.1.0-alpha.35](https://github.com/aautonomicc/Watch-It/releases)
ships a signed APK and a Linux AppImage that connect to the live Autonomi network
with an embedded Rust client (no gateway, no sidecar) and stream by XOR address
with byte-exact seeking, a chunk cache with keep-ahead prefetch, and persisted
data maps (a title resolves over the network at most once per device — instant
on every later open). TMDB metadata gives entries artwork, descriptions,
ratings, and categories from their file names, with shows grouped into
big-artwork Show → Season → Episode pages. Releases are keyless by design:
no TMDB key ships in the binaries — add your own free key (create one at
[themoviedb.org](https://www.themoviedb.org/settings/api)) in
Settings → Metadata, or skip it entirely: imported `.watch-list` bundles
carry metadata and posters, so bundle-importing users never need a key. Media lists can be created and
managed in-app and imported from a local file or straight from an Autonomi
address, with optional prefetch of all data maps on import. Playback position
is remembered per title: the home screen opens with Continue Watching and
Recently Added rows, detail pages offer Resume / Start over with a Watched
badge, and finishing an episode auto-plays the next one via an Up-next
overlay. Downloads for offline watching shipped in alpha.30/.31: a download
queue with pause/resume that survives restarts and auto-pauses when the
connection drops, download badges on every card (check = downloaded,
progress ring = downloading, count on show/season cards), and offline-aware
playback — browsing always works offline, downloaded titles play locally
with the full library experience, and stream-only titles are gated with a
hint until the network returns. Alpha.32 rounds downloads out with a season
download-all button, a Downloads row on the home wall, queue multi-delete,
and a top-bar download meter. Alpha.33 ships `.watch-list` bundles: lists
export as plain text or as a bundle carrying TMDB metadata, posters,
offline-verified instant-play root maps, and optional watch history, with a
single auto-detecting Import button — see
[docs/BUNDLE-FORMAT.md](docs/BUNDLE-FORMAT.md). The Linux AppImage also
gained a proper taskbar icon. Alpha.34 shipped the keyless releases
described above, a show-level Download All button, home-row customization
(reorder/hide the home wall rows in Settings), and a taller watch-progress
bar on every card. Alpha.35 adds home-page library search: a search icon in
the home app bar (`/` or Ctrl+F on desktop) opens a full-screen
live-as-you-type search over your library — titles, years, and episode
markers like s02e05 — grouped into Shows / Movies / Episodes with the usual
download and watched badges.
Docs:

- [docs/VISION.md](docs/VISION.md) — goals, non-goals, target users
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — tech stack decision and app structure
- [docs/NAMING.md](docs/NAMING.md) — file naming convention (Plex/Jellyfin style)
- [docs/UI-DESIGN.md](docs/UI-DESIGN.md) — screens and look-and-feel
- [docs/BUNDLE-FORMAT.md](docs/BUNDLE-FORMAT.md) — `.watch-list` bundle spec (locked, unimplemented)
- [docs/ROADMAP.md](docs/ROADMAP.md) — phased milestones

## License

MIT
