# Roadmap

**Status (2026-08-04):** latest release is **v0.1.0-alpha.45**
([GitHub Releases](https://github.com/aautonomicc/Watch-It/releases)).
Alpha.45 ships the single import entry point (the list editor's
"Add .datamap files" button and the Media page's "New list" button are
gone — all importing goes through Add to library, which routes each
file correctly and creates lists) and address hygiene (bundle
`history.json` is spec v2, keyed by `.datamap` member names instead of
derived addresses, with a missing-map entry's history kept out of the
bundle entirely; the ADDRESS section on detail pages and the
list-editor address subtitle are deleted).
Alpha.44 made "Add to library" a single multi-select picker that works
out what each file is — media `.datamap` files, `.watch-list` bundles,
or a bundle's own `.watch-list.datamap` fetched straight from the
network (progress + cancel, 200MB cap) — added plain-English
import/share guidance on the Media page and export dialog, and fixed
licensing for FOSS distribution (source MIT, binaries GPLv3 via the
statically linked self_encryption crate; new Settings → About →
Open-source licenses page). Alpha.42 added library arrangement: a "My lists | Auto by type" toggle on
the Media page that swaps the home wall and the new left library drawer to
virtual Movies / TV Shows lists (derived from cached TMDB media types,
never stored), per-list browse pages with multi-select genre filter chips,
and a checkbox list-picker on `.datamap` import (multi-select into
existing lists or create-new, silent merge). Alpha.43 refined auto mode:
the Settings section is now just "Media", the checkbox rows follow the
arrangement mode so the virtual lists can be hidden (wall + drawer;
hidden lists also filter Continue Watching / Recently Added, while the
Downloads row always shows on-device files), and an all-hidden home shows
a small prompt to re-enable a list. Before that, the
**datamap-first privacy model** was completed —
all three releases of the schedule below have shipped (v0.1.0-alpha.40 =
the feature, v0.1.0-alpha.41 = deprecation window closed + cleanup):
public XOR addresses are gone as an entry type — every entry is created from
a `.datamap` file (private `ant file upload` output) or a `.watch-list`
bundle, its address derived offline, its map required locally; nothing in
the app fetches a data map from the network anymore (`data_map_fetch` is
deleted from the crate), killing the 20–30 s cold resolve for good. Bundle
spec v2 ([BUNDLE-FORMAT.md](BUNDLE-FORMAT.md)); v1 bundles and the upgrade
migration pass retired in alpha.41 after all testers rolled over. Previously: rebranded **watch-it → W@tch** (display-only: Anton
wordmark, launcher labels, window titles, user-facing strings; repo and all
technical identifiers keep their names — see BRAND.md), shipped in
v0.1.0-alpha.39 ([GitHub Releases](https://github.com/aautonomicc/Watch-It/releases))
— signed Android APK + Linux AppImage on every release. Phases 0, 1, and 2 are
done: both platforms stream from the live Autonomi network via the embedded
Rust client (`native/watchit_core`) with byte-exact seek, a chunk LRU cache with
keep-ahead prefetch, and root data maps persisted in SQLite (imported once,
looked up in ~7ms across restarts — never fetched from the network). The library is a full poster-wall experience: TMDB metadata from
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
striped popcorn-bucket logo as the launcher/taskbar
icon and app-bar lockup on both platforms; alpha.37 turns the logo stripe
and the whole app accent blue (#42a5f5, replacing the family copper).
Alpha.38 ships the connectivity & background work (see the section below):
automatic reconnect after network loss on both platforms, Android
background downloads with a progress notification, Wi-Fi/mobile-data
policies in Settings → Network, and the demo movie's root data map bundled
into the app for a fast first play. The seeded
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
- [x] Decide accent color / app icon → blue #42a5f5 accent since 2026-07-30 (was copper #c9732b); icon: striped popcorn bucket (bone/blue #42a5f5/bone, branding/icon.svg) — bucket replaced the original `[>]` chevron 2026-07-29 (too close to Plex), stripe went red→blue with the accent change; name/wordmark: **W@tch** in Anton since 2026-07-31 (was lowercase mono `watch-it`)
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
- [x] Card badges for stream/downloading/downloaded state → alpha.31: accent
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
Auto-resume of connection-loss pauses shipped in alpha.38 (system pauses
auto-resume on reconnect/Wi-Fi/app-resume/next-launch; user pauses stay
manual). Still deferred: per-direction bandwidth/concurrency settings.
The old total-network-loss blind spot (ant-core reporting ready with stale
peers) is handled since alpha.38: the reconnect supervisor evicts the
client when peers stay at 0 and re-dials automatically.

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

## Connectivity & background (planned 2026-07-30, released in v0.1.0-alpha.38)

From the alpha.37 field reports — full plan in
[PLAN-connectivity-and-background.md](PLAN-connectivity-and-background.md):

- [x] Auto-reconnect after network loss (both platforms): the embedded
      client is supervised — when peers drop to 0 it is evicted and
      re-dialled with backoff, kicked immediately on OS
      connectivity/lifecycle events (cable replug, phone wake); no app
      restart needed
- [x] Android background downloads: dataSync foreground service with
      wake/Wi-Fi locks and a silent progress notification; the 6-hour
      Android timeout system-pauses the queue with a "reopen to continue"
      notice; Samsung battery-settings tip card in Settings → Downloads
- [x] Wi-Fi / mobile-data policies (Settings → Network): downloads
      Wi-Fi-only by default (queue shows "Waiting for Wi-Fi"), streaming
      asks once per session on cellular (or always-allow / Wi-Fi-only)
- [x] Bundled demo-movie root data map: the NOTLD map ships as an app
      asset and is seeded into the map store at startup — first play on a
      fresh install skips the 20–30s network resolve
- [x] System-pause auto-resume: pauses caused by the system (connection
      loss, waiting-for-Wi-Fi, Android timeout) resume automatically on
      reconnect/Wi-Fi/app-resume/next-launch; user pauses stay manual

## Datamap-first privacy (planned 2026-08-01, three releases)

Public Autonomi uploads store their root data map as a plaintext chunk on
the network, so public content is discoverable and readable by any node
operator — and an app keyed on public XOR addresses structurally nudges
users into uploading their media libraries insecurely. The fix: the
`.datamap` file (private-upload output) is the **only** way content enters
the library; the entry's identity is the address *derived offline* from the
map. Full plan in [PLAN-datamap-privacy.md](PLAN-datamap-privacy.md), spec
in [BUNDLE-FORMAT.md](BUNDLE-FORMAT.md).

**Release 1 — v0.1.0-alpha.40 (implemented 2026-08-01): the whole feature.**
- [x] Rust: offline address derivation (`verify.rs::derive_address`),
      `POST /datamap` (import + derive, msgpack/legacy-JSON) and
      `GET /datamap/{addr}` (ant-cli-compatible export); `/xor` stream path
      serves locally stored maps only and fast-fails with "re-import"
      instead of a doomed network resolve
- [x] Entry model: one kind — `{derived address, name}`, map required in
      the local store; XOR add-entry dialog, plain-text list import/export,
      and the `<64-hex>` line grammar deleted
- [x] Import: multi-select "Add .datamap files" (library page and list
      editor), `.watch-list` bundle (local file; by network address until
      alpha.41 dropped it)
- [x] Bundle spec v2: `datamaps/` members named by original filename (zip
      root accepted — a hand-made `zip lib.watch-list *.datamap` is valid),
      optional filename-line `list.txt`, unclaimed members → default list;
      v1 bundles convert at the import border (`rootmaps/` member offline,
      else one import-time network fetch; unresolvable entries skipped)
- [x] Export: bundle only, members from the local store, no pre-resolve
      pass (maps arrive at import by construction); history checkbox stays
- [x] Migration: one-time background pass on first launch fills the map
      store for pre-alpha.40 entries (public XOR addr == derived addr, so
      rows/downloads/history/metadata are untouched); cancellable, retries
      next launch; unresolved entries fast-fail at play with a re-import
      hint
- [x] DataMapPrefetcher, prefetch dialogs, and the tile-open map warm
      deleted — nothing left to prefetch

**Releases 2+3 — v0.1.0-alpha.41 (implemented 2026-08-01): deprecation
window closed + cleanup, shipped together.** The window's condition was
met early — every testing device upgraded and every library/bundle
migrated — so the cleanup landed in one release:

- [x] `data_map_fetch` deleted from the crate (`Engine::root_map` and the
      child-map resolution went with it); `GET /resolve/{addr}` is now a
      local-store lookup (size/chunks, 404 for a never-imported address) —
      kept only for the download manager's size pre-fill
- [x] v1 bundles no longer import: hex `list.txt` lines are skipped (an
      all-v1 file gets a "re-export from 0.1.0-alpha.40+" error),
      `rootmaps/` members are ignored, border conversion deleted
- [x] The one-time upgrade migration pass deleted
      (`services/library_migration.dart`) — all testers migrated
- [x] Read-side acceptance of v1 address-keyed `history.json` rows
      dropped (implemented 2026-08-04, ships in the release after
      alpha.45) — spec-v2 (member-keyed) rows are now the only format
      read or written; the test group is small enough to just re-export.
      See [PLAN-drop-v1-history-rows.md](PLAN-drop-v1-history-rows.md).
- [x] Bundle-download by network address dropped; bundles are shared as
      files only. This settled the open question the consistent way: a
      bundle's network address *is* a public XOR address — the thing this
      plan removed — and a publicly addressed bundle re-leaks every
      datamap inside it anyway. Curated/PD libraries travel as
      `.watch-list` files, which any channel can carry.

Honest scope (also in the docs/UI): a datamap **is** full access — the gain
is non-discoverability by third parties, not confidentiality against list
recipients; privacy is transitive (publishing a bundle at a public address
re-leaks every title); already-public uploads are immutable and stay
public. Curators of genuinely public material (the NOTLD demo, PD
pipelines) fetch the public file's datamap once and ship it in a bundle —
consumers never see an address.

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
- Publish/subscribe community lists on Autonomi (curated "channels") —
  must default private (a datamap list published at a public address
  re-leaks every title; see PLAN-datamap-privacy.md)
- Watch-state + list sync between devices via Autonomi
- tvOS (Apple TV) layout — Android TV is now in Phase 4
- Trakt scrobbling
- Music & photos lists
- Chromecast / AirPlay output
- Skip-intro detection
