# Roadmap

**Status (2026-08-27):** latest release is **v0.1.0-alpha.62**
([GitHub Releases](https://github.com/aautonomicc/Watch-It/releases)) —
and every release since alpha.55 ships a signed APK, a Linux AppImage,
**and a Windows portable zip**. The headline of the newest releases is
**My W@tch device sync** (see its section below): alpha.61 links a
user's own devices by QR code/invite and syncs watch lists and viewing
positions between them — with data maps travelling too, so synced
entries arrive playable — and brings My W@tch to Android (verified on
a real phone against the desktop AppImage); alpha.62 extends sync to
Edit-details changes and custom artwork at full quality. Around them:
alpha.58 gave Edit details proper TV scoping (show/season/episode each
edit their own level); alpha.59 fixed Publish for files over ~12 MiB
(the finalize step choked on the shrunk child map — the upload itself
had succeeded, so re-publishing finishes it free) and added a poster
crop/zoom step after picking a video frame; alpha.60 added the Terms
of Use & Disclaimer first-launch gate + Settings → About page and the
Publish "Why multiple versions?" explainer. Before that the headline
was **Publish**: W@tch uploads files to Autonomi itself (see the
Publish section below). Alpha.55 shipped the built-in ANT wallet and
single-file private uploads with live cost estimates (paid upload
verified end-to-end on mainnet); alpha.56 grew Publish to multi-file
batches with quality tiers via bundled ffmpeg and added the desktop
update check; alpha.57 added **Edit details** — user-entered
title/year/description and artwork from an image file or a video frame
for content TMDB doesn't know, carried along in `.watch-list` bundles.
Before that: alpha.51 trimmed the built-in seed catalog to the two
Night of the Living Dead versions (fresh installs and factory resets
only; existing installs keep what they seeded, and the dropped uploads
stay playable on the network — see [SEED-CATALOG.md](SEED-CATALOG.md))
and added the Favourites home row; alpha.52 bumped ant-core to 0.5.1
and moved the favourite heart beside Download; alpha.53 made the
AppImage's audio libraries system-first with a bundled fallback
(fixing no-start and silent-audio reports on several distros);
alpha.54 hides the mouse cursor with the player controls and holds a
Linux screen-lock inhibit while playing.
Alpha.50 relays out the home app bar: the search icon moves to the far
left, the library-drawer hamburger to the far right, and the top-right
settings icon is gone (the drawer's Settings tile covers it); the home
screen now also reloads after *any* pushed page pops, so changes made
via drawer-opened pages apply on return.
Alpha.49 ships the same-title version picker: uploads of the same title
share one wall card (info line "2 versions") and the detail page grows a
version dropdown ("480p H.264 · 570 MB" / "1080p H.264 · 5.29 GB") that
switches play/resume/download and the FILE section to the picked
version; both Night of the Living Dead uploads (480p archive.org + the
genuine-1080p re-encode) are bundled to demonstrate it.
Alpha.48 is the seed-catalog release — the fresh-install experience is
now a full library (see the section below and
[SEED-CATALOG.md](SEED-CATALOG.md)): first run seeds all 48
verified-public-domain uploads as three lists with bundled root maps
(instant play) and bundled TMDB metadata + posters (full poster wall
offline, no key needed), every entry shows file size + video format,
and import/export gets UX fixes (Android bundle export via the system
save dialog, offline-import warning, real error messages, File X of Y
progress).
Alpha.47 fixes `.datamap` import on Android: the system file picker
copies picked files into cache and renames unknown extensions to the
MIME-derived `.bin`, so every `X.datamap` reached the app as `X.bin`
and was rejected by name. `.bin` is now accepted as an alias of
`.datamap` (media maps and `*.watch-list.bin` bundle maps both route
correctly, recovering the exact original name); content verification
still gates every import, so the name was never a safety check.
Alpha.46 fixes importing real `ant` uploads — the `.datamap` a private
`ant file upload` writes for any file over ~12 MiB is a shrunk (child)
map, which the app now expands over the network to the full root map
at import — and drops v1 address-keyed `history.json` rows (spec-v2
member-keyed rows are now the only accepted format).
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

## Seed catalog & same-title versions (shipped 2026-08-08, v0.1.0-alpha.48/.49/.50)

The fresh-install experience became a full library. Catalog contents,
upgrade-flag rules, and the regeneration procedure live in
[SEED-CATALOG.md](SEED-CATALOG.md).

- [x] Full PD seed catalog (alpha.48): first run seeds all 48
      verified-public-domain uploads as three lists (10 Movies +
      Petticoat Junction S1's 21 episodes + One Step Beyond's 17
      episodes) from generated `seed_catalog.dart`, with every root map
      bundled as an app asset so seeded titles play instantly; upgrade
      paths merge without duplicating entries or resurrecting user
      deletions (`defaults_seeded_v4`, additions via
      `ensureSeedAdditions`/`seed_additions_v1`)
- [x] Bundled TMDB metadata (alpha.48): 48 metadata rows + 53 images
      (~1.5MB) harvested with the app's own matcher — fresh keyless
      installs show posters, descriptions, ratings, and episode
      names/stills fully offline; an asset-coverage test fails CI if
      the catalog changes without a re-harvest
- [x] Per-entry file size + video format (alpha.48): `sizeBytes` +
      `videoInfo` ("480p H.264") on wall cards, list-editor subtitles,
      and detail pages; size comes free from the datamap at import,
      legacy entries backfill from the local `/resolve`, and the player
      persists mpv-reported resolution on first play
- [x] Import/export UX fixes (alpha.48): Android bundle export via the
      system SAF save dialog (was broken — file_selector never
      implemented getSavePath on Android), offline-import pre-flight
      warning, import errors surfaced verbatim instead of a generic
      "unreadable" count, File/Bundle X of Y progress dialogs with
      Cancel
- [x] Same-title version picker (alpha.49): uploads sharing a parsed
      title fold into one card everywhere (wall, browse grids, Recently
      Added, Downloads, search) with an "N versions" line; the detail
      page's file-info line becomes a dropdown that re-keys
      play/resume/download/FILE to the picked version
- [x] Home app bar relayout (alpha.50): search far left, library-drawer
      hamburger far right, top-right settings icon removed; home
      reloads after any pushed page pops (route-observer fix)

## Upload — in-app uploads (shipped 2026-08-25 as "Publish", v0.1.0-alpha.55/.56/.57; renamed Upload 2026-08-27)

W@tch now uploads to Autonomi itself — no CLI needed. Desktop-only for
now (the pipeline needs bundled ffmpeg and a windowed flow); plan and
decisions in [PLAN-alpha55.md](PLAN-alpha55.md), implementation notes in
[ARCHITECTURE.md](ARCHITECTURE.md) → Publishing.

- [x] Internal ANT wallet (alpha.55): private key in the OS keychain
      (mode-0600 file fallback when none), BIP-39 12-word create
      ceremony with retype-confirm / import key-or-phrase
      (MetaMask-compatible derivation), live ANT/ETH balances on
      Arbitrum One; deliberately a hot wallet — fund it small
- [x] Private upload (alpha.55): pick file → live cost estimate →
      rights/permanence confirm gate → pay + progress; the root map is
      stored locally under its derived address, so the upload is
      instantly playable, addable to the library, and exportable as a
      `.datamap`; money-spending routes gated behind a per-start
      shared-secret header
- [x] Multi-file batches + quality tiers (alpha.56): full-series
      multi-pick with per-file probe verdicts; High 1080p / Medium
      720p / Low 480p tiers (H.264 High 8-bit + AAC faststart MP4 via
      bundled ffmpeg — static in the AppImage, shared in the Windows
      zip; never upscales; graceful as-is-only degrade when ffmpeg is
      missing) or Original as-is; summed live cost estimate; sequential
      encode→upload queue with per-item retry/skip and a batch done
      page (add-all-to-library, save-all `.datamap` files); outputs
      named per [NAMING.md](NAMING.md) with the real output height so
      tiers fold into the alpha.49 version picker
- [x] Update check (alpha.56): desktop-only, at most once per 24h
      against GitHub releases, snackbar + Settings → About badge;
      toggle in About (the app's only phone-home), default on
- [x] Edit details (alpha.57): user metadata (title/year/description)
      plus artwork from an image file, a picked video frame (bundled
      ffmpeg, desktop), or the player's "use this frame" button (all
      platforms); user rows are never overwritten by TMDB and travel
      in bundles
- [x] Edit details for TV (alpha.58): shows and seasons get their own
      edit pencil (title/year/description/artwork at show level,
      description/artwork at season level, overlaid onto every
      episode), and editing an episode edits that episode's name,
      synopsis, and artwork instead of the series — with episode
      artwork never leaking onto season surfaces
- [x] Large-file finalize fix (alpha.59): uploads over ~12 MiB no
      longer fail at the post-payment bookkeeping step (the shrunk
      child map is now expanded to the root, like import does);
      victims of the old bug re-publish the same file for free. Plus
      a crop/zoom step after picking a poster frame
- [x] Terms of Use & Disclaimer (alpha.60): first-launch accept gate +
      read-only page under Settings → About; the Publish quality
      section explains *why* multiple versions are encoded
      (device/bandwidth fit + Autonomi permanence)
- [x] Version-picker labels: universal Original-tier uploads gain
      their real resolution tag in the file name (alpha.60), and
      published entries are stamped with their "1080p H.264"
      resolution/codec label so the picker shows the full quality
      line, matching imported entries (post-alpha.62, next release)
- [ ] Upload on Android/iOS (desktop-only today)
- [ ] External signer / WalletConnect (the internal hot wallet is the
      only signing path today)
- [ ] True self-update (the check only notifies; AppImageUpdate/zsync
      and a Windows helper are deferred — see PLAN-alpha55.md §6)

## My W@tch — device sync (shipped 2026-08-26/27, v0.1.0-alpha.61/.62)

A user's own devices link into a private sync group — no account, no
server, and deliberately not via Autonomi: sync runs device-to-device
over an embedded x0x agent (post-quantum QUIC) with the devices meeting
in a CRDT store on a topic derived from the shared invite secret.
Implementation notes in [ARCHITECTURE.md](ARCHITECTURE.md) → My W@tch.

- [x] Device linking (alpha.61): create a link on one device, join on
      the others via QR code (camera scan on Android/iOS) or pasted
      `wtch1-…` invite; My W@tch drawer page shows Last sync, Linked
      since, and per-device presence; Unlink wipes the link
- [x] Watch-list + viewing-position sync (alpha.61): lists merge by
      title with last-writer-wins add/remove (deletes propagate),
      positions merge newest-wins; each entry's shrunk data map
      travels in the store, so synced entries arrive playable; 30 s
      background cycle app-wide plus a "Sync now" button
- [x] My W@tch on Android (alpha.61): the x0x agent builds into the
      Android core — verified end-to-end on a real phone against the
      desktop AppImage (2026-08-27)
- [x] Edit-details + artwork sync (alpha.62): userEdited titles/years/
      descriptions/episode names travel inline (last-writer-wins by
      edit time); artwork syncs at **full quality** — the sync doc
      carries a sha256 manifest and the bytes are pulled directly from
      any online linked device that has them, hash-verified, never
      downscaled; a device that synced a poster re-serves it
- [x] TMDB metadata + posters for keyless devices (post-alpha.62):
      full TMDB matches (descriptions, ratings, stills, show/season
      texts) and their poster files sync to linked devices without a
      TMDB key, need-driven via a compact per-doc `have` list so the
      traffic drains to nothing once every device has everything
- [ ] My W@tch on iOS (stubbed out today)
- [ ] Sync while apart: devices must currently be online together —
      no relay/mailbox in the middle (by design, for now)

## Channels — public signed media lists (implemented 2026-08-27, unreleased)

Part 2+3 of [PLAN-personal-vs-channels.md](PLAN-personal-vs-channels.md);
implementation notes in [ARCHITECTURE.md](ARCHITECTURE.md) → Channels.

- [x] Channel identity: Ed25519 key from its own 12-word phrase
      (SLIP-0010) via the wallet-style backup ceremony; code
      `wchn1-<base32(pubkey)>`; key in the OS keychain
- [x] Signed manifests (bundle spec v2 + channel.json) uploaded
      publicly; head records gossiped + signature-verified on an x0x
      topic derived from the pubkey; restore-from-phrase resumes
      publishing and recovers the item list from the network
- [x] Subscribe everywhere: read-only amber-badged channel lists on the
      home wall, auto-updating on a newer signed head
- [x] Safety rails: Describe-this-item (required title/description/
      artwork), per-item rights attestation, first-publish typed-name
      gate, cost preview, Terms v2, amber/PUBLIC vs blue/private
- [x] Check TMDB on Describe-this-item: look the item up with the
      typed title/year (public-domain classics are in the database),
      preview, and fill title/description/artwork + rating/genres from
      the match — subscribers get the full metadata keylessly
- [x] Publish an item straight from a file (2026-08-27): the channel
      flow now mirrors Upload — choose a local file, encode the quality
      tiers, describe (TMDB check included), attest, upload; finished
      uploads are auto-staged and can optionally join a library list
      (already-uploaded library items keep a secondary picker path)
- [x] The creator's own channel shows as its amber list too
      (2026-08-27): empty at creation, mirroring each published
      manifest via the subscriber import path
- [x] Channel subscriptions sync over My W@tch (2026-08-27): the sync
      doc carries codes + unsubscribe tombstones, so a channel arrives
      on linked devices amber-badged and auto-updating — never as a
      copy of a personal list; the own channel is announced the same
      way and followed by the user's other devices
- [ ] Channel directory (deliberately NOT in v1 — codes only; a curated
      directory would be a separate repo/site with its own vetting)
- [ ] Mobile channel creation (subscribe works everywhere; publishing
      needs the desktop wallet)
- [ ] Channel avatars, multi-owner channels, comments (parking lot)

## Phase 3 — All desktop platforms
- [x] Windows build + packaging → CI-built portable zip, shipped with
      every release since alpha.55 (unsigned: SmartScreen "More info →
      Run anyway"; installer + code signing deferred to beta —
      decision in [PLAN-alpha55.md](PLAN-alpha55.md) §6)
- [ ] macOS build and packaging (.dmg)
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
  now PLANNED as the public Channels feature: signed manifests + x0x
  head distribution, see PLAN-personal-vs-channels.md (a datamap list
  published at a public address re-leaks every title, so channels use
  deliberate per-item public publishing, never a library export)
- ~~Watch-state + list sync between devices~~ — **shipped** as My W@tch
  (alpha.61/.62, via x0x rather than Autonomi — see the section above)
- tvOS (Apple TV) layout — Android TV is now in Phase 4
- Trakt scrobbling
- Music & photos lists
- Chromecast / AirPlay output
- Skip-intro detection
