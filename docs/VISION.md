# Vision

## One-liner

W@tch makes media on the Autonomi network look and feel like a premium
streaming service — with nothing to host, no server to install, and your
library private by construction.

## The problem

- Plex/Emby/Jellyfin all require someone to run and maintain a server; Plex is
  account-gated and increasingly ad/subscription driven.
- VLC/mpv play everything but have no library experience — no posters, no metadata,
  no "continue watching".
- Media on decentralized storage (Autonomi) has no first-class player — or
  uploader — at all: without W@tch it's CLI commands and raw addresses.

## Goals

1. **One app, six platforms.** Android, Android TV, iOS, Linux, Windows, macOS from
   a single codebase. Same UI language everywhere, adapted to touch vs desktop vs
   the 10-foot TV experience.
2. **Client-only. No server, ever.** The Autonomi network is the backend. Install the
   app, add a list, get a poster-wall library. No accounts, no configuration, nothing
   to host.
3. **Lists as libraries.** A library is a list of entries, each backed by a
   `.datamap` file — the key a private upload produces (W@tch's own Publish
   flow, or `ant file upload`). Users can keep several lists and share them
   as `.watch-list` bundles.
4. **Private by construction.** Public Autonomi uploads are discoverable —
   their data map sits on the network in plaintext, readable by any node
   operator. W@tch therefore takes datamaps only: content stays invisible on
   the network, and access travels exactly as far as the datamap does.
   (Corollary: a datamap grants full access, so bundles should be shared as
   privately as their content deserves — publishing one at a public address
   re-leaks every title in it.)
5. **Metadata like the big apps.** From the file name alone, fetch artwork,
   description, and category from the same public databases the media servers use
   (TMDB for video; MusicBrainz + Cover Art Archive for music, keyless),
   so a bare file list becomes a rich, browsable collection.
6. **Stream or keep.** Play instantly from the network, or download for offline —
   downloaded items keep the full library experience.
7. **Publish from the app.** Getting media *onto* the network shouldn't need
   a terminal either: pick files or whole folders, let the app match them
   against the databases and name them canonically, choose quality tiers,
   pay with a built-in wallet, and the uploads land in the library with
   their datamaps on-device (shipped for desktop in alpha.55/.56; batch
   auto-matching in alpha.77–.79).
8. **Play everything.** libmpv-based engine: every container/codec, subtitles,
   multiple audio tracks, chapters.
9. **Own your data.** Watch history, resume points, lists, and cached metadata stored
   locally. No telemetry. Your own devices can keep each other in sync —
   My W@tch links them peer-to-peer (shipped alpha.61/.62): lists,
   viewing positions, edits, and artwork travel directly between your
   devices, end-to-end encrypted, with no account and no third party in
   the middle.

## Non-goals

- **No server compatibility.** No Plex/Emby/Jellyfin/Silo client support — stripped
  out by design. Autonomi is the only remote source.
- **Not a server itself.** No transcoding for other devices, no user management.
- **No live TV / DVR** in v1. (Music was originally out of scope too,
  but shipped in alpha.76–.79: album wall, inline album player, artist
  pages — W@tch stays video-first, with music as a full library type.)
- **No piracy features** — W@tch plays what its users hold datamaps for on
  Autonomi; it ships no torrent/debrid integrations.

## Target users

1. **The Autonomi early adopter** — has (or knows of) content on the network and
   nothing nice to play it with.
2. **The streaming-fatigued viewer** — wants a Plex-quality library experience
   without running or paying for anything.
3. **The curator** — maintains and shares `.watch-list` bundles of media
   (their own uploads, or the fetched datamaps of legitimately public
   material) for others to import.

## Product principles

- Library first: the app opens to your collection, not to menus.
- Playback is sacred: fast start, reliable seek, remembers position always.
- Desktop is not a blown-up phone app: keyboard shortcuts, resizing, hover.
- TV is not a blown-up phone app either: everything reachable by D-pad, focus always
  visible, no text entry beyond what a remote can bear.
- Offline-first: downloads and all local state work with zero connectivity.
