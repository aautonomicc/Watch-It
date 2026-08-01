# W@tch

*Formerly **watch-it** — rebranded 2026-07-31. The repository keeps the name
`Watch-It` (GitHub disallows `@`), as do all technical identifiers.*

A beautiful, cross-platform media player for the **Autonomi network** — one codebase,
six platforms: **Android, Android TV, iPhone (iOS), Linux, Windows, and Mac.**

Think the Plex / Emby / [Silo](https://github.com/Silo-Server/) experience —
poster-wall library, rich metadata, resume-watching — but **with no server to install**.
W@tch is client-only: your media library is one or more lists of files stored
privately on the decentralized [Autonomi](https://github.com/WithAutonomi/ant-client)
network, streamed on demand or downloaded for offline watching.

## How it works

1. **Upload privately, keep the datamap.** Upload media with
   `ant file upload <file>` (private is the default — **don't** use `-p`).
   The upload prints a small `<file name>.datamap` file: that file *is* the
   key to the content. The encrypted chunks on the network are unreadable
   noise to everyone who doesn't hold it — unlike a *public* upload, whose
   datamap is itself stored on the network where any node operator can find
   it and watch the file. That's why W@tch takes datamaps only, and has no
   public-address entry type.
2. **Lists of media.** Import `.datamap` files into one or more lists; share
   a library as a `.watch-list` bundle (datamaps + artwork). A datamap grants
   full access, so share bundles as privately as the content deserves.
3. **Metadata from the name.** From the file name W@tch looks up the same public
   databases the media servers use (TMDB) and fetches artwork, description, and
   category to organize and display the collection as a poster-wall library. Name
   files with the Plex/Jellyfin convention —
   `Title (Year) {imdb-ttXXXXXXX} - [quality].ext` — **before uploading**; see
   [docs/NAMING.md](docs/NAMING.md).
4. **Stream or download.** Hit play to stream straight from the network, or download
   an item to the device for offline watching. Downloaded items play with the full
   library experience, no connectivity needed.

No server, no accounts, no telemetry. There is deliberately **no Plex/Emby/Jellyfin
server compatibility** — Autonomi *is* the backend.

## Status

**Working alpha on Android and Linux** — [the latest release](https://github.com/aautonomicc/Watch-It/releases)
ships a signed APK and a Linux AppImage that connect to the live Autonomi network
with an embedded Rust client (no gateway, no sidecar) and stream with
byte-exact seeking and a chunk cache with keep-ahead prefetch. Since
alpha.40 the library is **datamap-first**: entries are created from
`.datamap` files or `.watch-list` bundles, addresses are derived offline,
and every title's data map is on-device from the moment it's imported — so
first plays start fast (no cold network resolve) and nothing about your
library is discoverable on the network. TMDB metadata gives entries artwork, descriptions,
ratings, and categories from their file names, with shows grouped into
big-artwork Show → Season → Episode pages. Releases are keyless by design:
no TMDB key ships in the binaries — add your own free key (create one at
[themoviedb.org](https://www.themoviedb.org/settings/api)) in
Settings → Metadata, or skip it entirely: imported `.watch-list` bundles
carry metadata and posters, so bundle-importing users never need a key. Media lists can be created and
managed in-app; `.datamap` files import via a multi-select picker and
bundles import from a local file. Playback position
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
download and watched badges. Alpha.36 gives W@tch its own identity: a
new striped popcorn-bucket logo as the launcher
and taskbar icon on both platforms and as the icon + wordmark lockup in
the app bar; alpha.37 turns the logo stripe and the app accent blue
(#42a5f5). Alpha.38 makes the connection self-healing and downloads
phone-friendly: the app automatically reconnects after a network loss
(cable unplugged, phone sleep/wake) with no restart needed, Android
downloads keep running in the background with a progress notification,
Settings → Network adds Wi-Fi/mobile-data policies (downloads Wi-Fi-only
by default, ask-before-streaming on cellular), and the demo movie's data
map ships inside the app so it starts fast on a fresh install. Alpha.40
removes public XOR addresses entirely in favour of the datamap-first model
above: adding media means importing `.datamap` files or bundles (spec v2 —
raw datamap members named by original filename, so even a hand-made
`zip lib.watch-list *.datamap` imports), the plain-text address list format
is gone, old bundles convert on import, and existing libraries migrate
automatically in a one-time background pass on first launch.
Docs:

- [docs/VISION.md](docs/VISION.md) — goals, non-goals, target users
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — tech stack decision and app structure
- [docs/NAMING.md](docs/NAMING.md) — file naming convention (Plex/Jellyfin style)
- [docs/UI-DESIGN.md](docs/UI-DESIGN.md) — screens and look-and-feel
- [docs/BUNDLE-FORMAT.md](docs/BUNDLE-FORMAT.md) — `.watch-list` bundle spec v2 (datamap-first)
- [docs/ROADMAP.md](docs/ROADMAP.md) — phased milestones

## License

MIT
