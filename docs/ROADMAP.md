# Roadmap

**Status (2026-07-29):** v0.1.0-alpha.36 released ([GitHub Releases](https://github.com/aautonomicc/Watch-It/releases))
— signed Android APK + Linux AppImage on every release. Phases 0, 1, and 2 are
done: both platforms stream from the live Autonomi network via the embedded
Rust client (`native/watchit_core`) with byte-exact seek, a chunk LRU cache with
keep-ahead prefetch, and resolved root data maps persisted in SQLite (any title's
map is fetched from the network at most once per device — cold ~30s, then ~7ms
across restarts). The library is a full poster-wall experience: TMDB metadata from
file names (bring your own free key — releases are keyless by design since
alpha.34, and bundles carry metadata + posters so casual users need no key),
show-level grouping on the home wall, big-artwork Show → Season → Detail pages with
ratings, air dates, and episode screenshots, list import from file or Autonomi
address with prefetch-on-import, and a Media Lists management page. Since
alpha.29 watch state is remembered per title: Continue Watching and Recently
Added rows on home, Resume / Start over + Watched badge on detail pages, and
end-of-episode Up-next auto-play. Alpha.30/.31 added downloads and offline:
a persistent download queue with pause/resume and auto-pause on connection
loss, download badges on all cards, offline gating (browse always, downloaded
titles play locally, stream-only Play disabled with a hint), and per-list
export. Alpha.32 added season download-all, a home Downloads row, queue
multi-select/delete-all, and a home top-bar download meter. Alpha.33 ships
`.watch-list` bundles (lists with metadata, posters, offline-verified
instant-play root maps, and optional watch history — see
[BUNDLE-FORMAT.md](BUNDLE-FORMAT.md)), TMDB attribution in Settings → About,
and a Linux taskbar icon. Alpha.34 shipped keyless releases (the shared
TMDB key is no longer bundled; a dismissible home banner points keyless
users to Settings → Metadata), a show-level Download All button (all
seasons at once), home-row customization (reorder/hide home wall rows),
and the 8px watch-progress bar on every card. Alpha.35 adds home-page
library search: a search icon on the home app bar (`/` / Ctrl+F on
desktop) opens a live full-screen search over parsed titles, years, and
episode markers, grouped Shows / Movies / Episodes. Alpha.36 adopts the
striped popcorn-bucket logo (bone/red/bone on ink) as the launcher/taskbar
icon and app-bar lockup on both platforms. The seeded
default movie is an H.264 8-bit 1080p encode named per the Plex/Jellyfin
convention — see [NAMING.md](NAMING.md).

## Phase 0 — Foundations (1–2 weeks)
- [x] Flutter project scaffold in `app/` targeting Linux + Android first (dev machines)
      → both fully working; Linux ships as AppImage with a vendored
      media_kit_video H/W-rendering patch (alpha.18/.20)
- [x] media_kit playing with basic controls → done on Android, streaming from the
      network; player controls lifted clear of the nav bar, thicker seek bar (alpha.11)
- [x] **Autonomi spike**: fetch a known public file by XOR address;
      test range/offset access → done: embedded Rust-FFI client (watchit_core),
      HTTP Range seek verified byte-exact against the live network
- [x] CI: `flutter analyze` + `flutter test` on push → GitHub Actions
      (.github/workflows/ci.yml), pinned Flutter 3.44.6, runs on push to main + PRs
- [x] Decide accent color / app icon → copper #c9732b accent; icon: striped popcorn bucket (bone/red #ef5350/bone, branding/icon.svg) — replaced the original `[>]` chevron 2026-07-29 (too close to Plex)
      icon on ink, app-bar wordmark lockup matches (alpha.12); see BRAND.md

**Exit criteria:** play a video file on Linux and Android, and prove seekable playback
of an Autonomi-hosted file by address. → **Met on both platforms.**

## Phase 1 — Lists + metadata MVP
- [x] List model in SQLite; add-entry flow (paste XOR address + file name)
      → add/edit/remove entries via the Media Lists page (create, show/hide,
      rename/delete lists); lists persist in SQLite (drift) with a one-time
      import of the shared_preferences blob earlier alphas wrote
- [x] Filename → title/year/episode parser; TMDB artwork/description/category fetch,
      cached locally → done: parser handles Plex/Jellyfin + release-style names and
      S01E02/1x02 episode markers; TMDB matching (exact /find by IMDb id, else
      title/year search) cached in SQLite with poster files on disk; official
      builds bundle a key since alpha.24, a user key in Settings → Metadata
      overrides it
- [x] Home (Continue Watching / Recently Added), Library grid, Detail page
      → home poster wall with show-level grouping (all seasons of a show under
      one tile) + network status bar; big-artwork ShowScreen → SeasonScreen
      (episode tiles with TMDB screenshots, air dates, synopses) → DetailScreen
      with ratings (alpha.26–.28); Continue Watching row (progress bar,
      remaining time, next-up episode after a finished one) + Recently Added
      row (episodes folded into show cards) shipped in alpha.29
- [x] Stream playback from Autonomi via the Phase-0 mechanism → done, plus a
      chunk LRU cache with keep-ahead prefetch (~64 MiB warm during playback)
      and root data maps persisted in SQLite — network resolve at most once per
      title per device, `/resolve` endpoint + prefetch-on-import with a
      hideable/resumable progress dialog, tile-open map warm-up (alpha.28)
- [x] Resume points + watched state → shipped in alpha.29: position saved
      every few seconds during playback and on player exit (≥95% = watched);
      DetailScreen gets Resume / Start over + a Watched badge + Next episode;
      PlayerScreen resumes from the saved point and ends episodes with an
      Up-next auto-play overlay that chains across episodes
- [x] Packaging: AppImage (Linux) + APK (Android)
      → signed APK + AppImage on every GitHub Release; built by
      scripts/release_build.sh as a systemd user unit

**Exit criteria:** paste addresses → poster wall with real artwork → press play →
streams from the network → resume works after app restart. v0.1 release.
→ **All met** as of alpha.29; Phase 1 is feature-complete.

## Phase 2 — Downloads & offline
- [x] Download manager: queue, progress, pause/resume, storage settings
      → shipped in alpha.30: pure Dart over the existing Range-capable `/xor`
      endpoint (no Rust changes); sequential queue persisted in SQLite,
      resume from bytes on disk, Download button with progress on detail
      pages, Settings → Downloads (queue, desktop folder picker,
      pause-downloads-while-streaming behaviour with remembered choice);
      auto-pauses on connection loss instead of erroring (alpha.31), with a
      2-minute stall-timeout backstop — resume is manual for now
- [x] Offline library: downloaded items fully browsable/playable with no
      connectivity → alpha.30/.31: finished downloads play locally (including
      chained Up-next episodes); browsing always works offline; when offline
      (embedded client connecting or 0 peers) Play is disabled with a hint on
      non-downloaded titles only, and the Up-next chain stops at a
      non-downloaded next episode — online it falls back to streaming
- [x] Card badges for stream/downloading/downloaded state → alpha.31: copper
      check = downloaded, progress ring = downloading, no badge = stream;
      show/season cards badge once ANY episode is downloaded, with a count
- [x] List **import** as files — pulled forward, shipped in alpha.25: local file
      picker or download from Autonomi by XOR address; multi-list files via
      `ListName="..."` sections; merge / create-new / skip on name clash; 10MB cap
- [x] List **export** as files → alpha.31: per-list from the Media Lists menu,
      same plain-text format import reads; save dialog on desktop, share
      sheet on Android
- [x] Storage controls — pulled forward, shipped in alpha.28: Size on disk +
      double-confirmed Clear all data (factory reset) in Settings → About
- v0.2 release (Linux + Android)

**Exit criteria: all met** as of alpha.31; Phase 2 is feature-complete.
Deferred niceties: auto-resume downloads on reconnect, per-direction
bandwidth/concurrency settings. Known upstream limitation: ant-core's
`/health` can report ready with stale peers when the OS network vanishes
entirely, so total-network-loss detection (airplane mode) is unreliable —
VPN-cut style losses are detected fine.

## `.watch-list` bundles (spec locked 2026-07-25, released in v0.1.0-alpha.33)

Share-ready list bundles: a zip carrying the plain-text list plus TMDB
metadata, posters, optional root data maps (instant play on import, verified
offline), and optional watch history (device migration). Full spec in
[BUNDLE-FORMAT.md](BUNDLE-FORMAT.md):

- [x] TMDB attribution (owed today, independent of bundles): standard notice +
      logo in Settings → About/Metadata
- [x] Base bundle: zip read/write (`archive` dep), single Import
      button with zip-magic sniff (plain `.txt` vs bundle, extension
      irrelevant), single Export button with two-step dialog (List only /
      Full bundle → checkboxes), cancellable pre-resolve pass on export
      (Cancel keeps the partial bundle), caps 10MB txt / 200MB bundle with
      per-member decompressed sanity limits, mobile SAF save for bundles,
      round-trip verified into a clean keyless profile
- [x] Library + history: whole-library export as one bundle,
      `library.json` home-state restore (applies only to lists the import
      creates), `history.json` merge with newer-updatedAt-wins, history
      checkbox default OFF
- [x] Root maps: `GET`/`PUT /rootmap/{addr}` endpoints in the
      embedded Rust server, offline shrink/serialize/hash verification on
      import (garbage → 400, wrong address → 422), root-maps checkbox
      default ON

## Phase 3 — All desktop platforms
- [ ] Windows + macOS builds and packaging (MSIX, .dmg)
- [ ] Keyboard map, window polish, hover thumbnails on seek bar
- [ ] Shared-list format v1 documented → plain text shipped (alpha.25/.31),
      bundle spec locked ([BUNDLE-FORMAT.md](BUNDLE-FORMAT.md)); import from an
      Autonomi address already works
- v0.3 release + demo video (poster-wall streaming from Autonomi is the headline)

## Phase 4 — Android TV, polish & iOS
- [ ] Android TV: leanback launcher entry + TV banner, D-pad focus traversal across
      all screens, 10-foot layout mode, remote player controls; test on a real TV box
- [ ] iOS build + TestFlight (FFI path required if sidecar chosen elsewhere)
- [ ] Chapter markers, playback speed, subtitle handling for streamed items
- [ ] Light theme, poster size options, keyboard-map settings
- [ ] Flatpak + notarized .dmg
- v1.0: all six platforms

## Later / ideas parking lot
- Publish/subscribe community lists on Autonomi (curated "channels")
- Watch-state + list sync between devices via Autonomi
- tvOS (Apple TV) layout — Android TV is now in Phase 4
- Trakt scrobbling
- Music & photos lists
- Chromecast / AirPlay output
- Skip-intro detection
