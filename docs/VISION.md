# Vision

## One-liner

Watch-It makes public media on the Autonomi network look and feel like a premium
streaming service — with nothing to host and no server to install.

## The problem

- Plex/Emby/Jellyfin all require someone to run and maintain a server; Plex is
  account-gated and increasingly ad/subscription driven.
- VLC/mpv play everything but have no library experience — no posters, no metadata,
  no "continue watching".
- Media on decentralized storage (Autonomi) has no first-class player at all: today
  it's CLI downloads and raw addresses.

## Goals

1. **One app, five platforms.** Android, iOS, Linux, Windows, macOS from a single
   codebase. Same UI language everywhere, adapted to touch vs desktop.
2. **Client-only. No server, ever.** The Autonomi network is the backend. Install the
   app, add a list, get a poster-wall library. No accounts, no configuration, nothing
   to host.
3. **Lists as libraries.** A library is a list of entries — XOR public file address +
   file name. Users can keep several lists, and lists can be shared/imported (a list
   is itself just data that can live on Autonomi).
4. **Metadata like the big apps.** From the file name alone, fetch artwork,
   description, and category from the same public databases the media servers use
   (TMDB), so a bare address list becomes a rich, browsable collection.
5. **Stream or keep.** Play instantly from the network, or download for offline —
   downloaded items keep the full library experience.
6. **Play everything.** libmpv-based engine: every container/codec, subtitles,
   multiple audio tracks, chapters.
7. **Own your data.** Watch history, resume points, lists, and cached metadata stored
   locally. No telemetry.

## Non-goals

- **No server compatibility.** No Plex/Emby/Jellyfin/Silo client support — stripped
  out by design. Autonomi is the only remote source.
- **Not a server itself.** No transcoding for other devices, no user management.
- **No live TV / DVR, no music-first experience** in v1.
- **No piracy features** — Watch-It plays what's publicly addressed on Autonomi; it
  ships no torrent/debrid integrations.

## Target users

1. **The Autonomi early adopter** — has (or knows of) content on the network and
   nothing nice to play it with.
2. **The streaming-fatigued viewer** — wants a Plex-quality library experience
   without running or paying for anything.
3. **The curator** — maintains and shares lists of public media for others to import.

## Product principles

- Library first: the app opens to your collection, not to menus.
- Playback is sacred: fast start, reliable seek, remembers position always.
- Desktop is not a blown-up phone app: keyboard shortcuts, resizing, hover.
- Offline-first: downloads and all local state work with zero connectivity.
