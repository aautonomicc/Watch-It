# Vision

## One-liner

Watch-It is the media player you install on every device you own: it makes your media —
wherever it lives — look and feel like a premium streaming service.

## The problem

- Plex is polished but proprietary, account-gated, and increasingly ad/subscription driven.
- Emby is semi-proprietary. Jellyfin is open but its clients are uneven across platforms.
- VLC/mpv play everything but have no library experience — no posters, no metadata,
  no "continue watching".
- Nothing today plays content from decentralized storage (Autonomi) with a first-class UI.

## Goals

1. **One app, five platforms.** Android, iOS, Linux, Windows, macOS from a single codebase.
   Same UI language everywhere, adapted to touch vs desktop.
2. **Zero-setup value.** Install → pick a folder → get a poster-wall library. No server,
   no account, no configuration.
3. **Best-in-class Jellyfin-compatible client.** Users with a Jellyfin/Silo/Emby server
   get a client that feels better than the official ones.
4. **Play everything.** libmpv-based engine: every container/codec, subtitles (embedded,
   external, styling), multiple audio tracks, chapters, HDR passthrough where possible.
5. **Own your data.** Watch history, resume points, and library metadata stored locally
   (and optionally synced). No telemetry.
6. *(Proposed differentiator)* **Autonomi playback.** Stream public media from the
   Autonomi network through AntTP; paste an address or browse a curated index and hit play.

## Non-goals (v1)

- **Not a server.** No transcoding for remote devices, no user management, no remote
  streaming to third parties. Server people already have Jellyfin/Silo.
- **No live TV / DVR** in v1.
- **No music-first experience** — music playback works, but movies/TV are the focus.
- **No piracy features** — no built-in torrent/debrid integrations.

## Target users

1. **The hoarder with folders** — has movies/shows on a disk, wants Plex looks without
   running a server.
2. **The Jellyfin/Silo self-hoster** — wants one good client on every device.
3. **The Autonomi early adopter** — has content on the network and nothing nice to play
   it with.

## Product principles

- Library first: the app opens to your content, not to menus.
- Playback is sacred: fast start, frame-perfect seek, remembers position always.
- Desktop is not a blown-up phone app: keyboard shortcuts, window resizing, mouse hover.
- Offline-first: everything works without connectivity except remote sources.
