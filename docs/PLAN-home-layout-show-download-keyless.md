# Plan: Home layout settings · Show-level Download All · Strip bundled TMDB key

Status: items **2 and 3 implemented** (2026-07-25); item **1 still planned,
not implemented**. Grounded in code as of commit c321d58.

---

## 1. Home screen row customization (visibility + order)

### Current state
- The home wall is built by `_posterWall` in `app/lib/main.dart:227-275`. Rows in
  fixed order: Continue Watching (inline, 235-251), Downloads (252-255),
  Recently Added (256-259), then one row per enabled media list via a `for`
  loop (260-272). The three special rows are hardcoded `if` blocks — there is
  no data-driven section list today.
- Media lists already persist visibility (`MediaList.enabled`) and order
  (`position` column, `library_store.dart:145-146, 180-203`); the Media Lists
  screen's checkbox (`media_lists_screen.dart:865-872, 986-994`) is the
  existing show/hide pattern.
- No `ReorderableListView` anywhere in the app yet — this introduces the first.
- Settings screen is a hardcoded ListView (`settings_screen.dart:250-500`);
  scalar prefs live in `AppSettings` (shared_preferences wrapper,
  `app_settings.dart`).

### Design
**Section identity.** Give every home row a stable id:
`continue`, `downloads`, `recent` for the special rows; `list:<mediaListId>`
for media-list rows.

**Persistence.** One new `AppSettings` key, `home_sections_v1`, storing a
JSON-encoded ordered array of `{id, visible}`. Rules:
- Order of ALL home rows (special + list rows interleaved) comes from this key.
- Visibility of the three special rows comes from this key's `visible` flag.
- Visibility of list rows keeps using the existing `MediaList.enabled` flag
  (single source of truth — the Media Lists screen checkbox and the new Home
  layout screen both read/write it via `LibraryStore.save()`), so we don't
  create two competing hide mechanisms.
- Reconciliation on load: lists that exist but aren't in the stored order are
  appended at the end; stored ids whose list was deleted are dropped; key
  absent → default order = current behavior (continue, downloads, recent,
  lists by `position`).

**Refactor.** `_posterWall` builds a `List<HomeSection>` descriptor list
(id, title, row-builder closure) from the reconciled config, then renders in
order, skipping hidden/empty rows. The three special-row builders are extracted
from the current `if` blocks unchanged.

**UI.** New "Home screen" `ListTile` in Settings' LIBRARY section (sibling of
"Media Lists", `settings_screen.dart:264-279`) → new `HomeLayoutScreen`:
a `ReorderableListView` with drag handles, one row per section, a visibility
`Checkbox` per row (special rows → `home_sections_v1`; list rows →
`LibraryStore`). Empty rows still listed (they're only hidden on home when
empty). `_openSettings` in `main.dart:101-106` already calls `_reload()` on
return, so home refreshes for free.

**Tests.** Unit: reconciliation (new list appended, deleted list dropped,
default order, round-trip through `AppSettings`). Widget: `_posterWall`
renders in configured order and hides toggled-off special rows. Templates:
`test/home_rows_test.dart`, `test/app_settings_test.dart`.

**Size:** medium — the `_posterWall` refactor plus one new screen.

---

## 2. Show overview: Download All (all seasons)

### Current state
- Show overview: `ShowScreen` (`app/lib/screens/show_screen.dart:14-107`)
  renders season tiles; header block at 50-91.
- Per-season Download All already exists (`season_screen.dart:39-49, 59-64,
  120-143`): filters episodes whose task status != done, loops
  `DownloadManager.instance.enqueue(entry)` (idempotent, one-at-a-time queue),
  snackbar "N episodes added to downloads", offline-gated via
  `ConnectivityMonitor`.
- Crucially, **every season's full episode list is already in memory** on the
  show overview: `ShowScreen.seasons` is `List<HomeSeason>`, each carrying
  `List<MediaEntry> episodes` (`season_grouping.dart:16-31`). No extra fetch
  needed.

### Design
Mirror the season button at show level:
- Button in the `ShowScreen` header (after line 91, above the SEASONS label,
  styled like the season one).
- Enumerate `[for (final s in seasons) ...s.episodes]`, filter
  `taskFor(e.address)?.status != DownloadStatus.done`, enqueue loop, snackbar.
- Label states matching the season pattern: "Download show" (nothing queued),
  "Download remaining (N)" (partial), disabled "Show downloaded" (none left).
- Add `ConnectivityMonitor.instance` to `ShowScreen`'s merged listenable
  (currently only Metadata + DownloadManager, `show_screen.dart:25-28`) so the
  button offline-gates and live-updates like `SeasonScreen`.
- Optional niceties: a `DownloadManager.enqueueAll(Iterable<MediaEntry>)`
  paralleling the existing `removeMany` (`download_manager.dart:286-290`); a
  confirm dialog when N is large (a whole show can be dozens of GB) — the
  season button doesn't confirm, so skipping it is also defensible for
  consistency.

**Tests.** Widget test for the three button states + enqueue count across
multiple seasons (mirror the existing season-screen tests).

**Size:** small.

---

## 3. Strip the bundled TMDB key

### Current state
- The key enters release binaries via one path: `scripts/release_build.sh`
  sources `.env` (line 35) and passes
  `--dart-define=TMDB_API_KEY=...` to the APK build (line 41) and to
  `build_appimage.sh` (line 45) → picked up by the single compile-time read
  `AppSettings.bundledTmdbApiKey` (`app_settings.dart:31`,
  `String.fromEnvironment`).
- `tmdbApiKey()` (`app_settings.dart:35-39`) prefers the user's
  shared_preferences key (`tmdb_api_key_v1`) and falls back to the bundled one;
  `tmdbKeySource()` reports user/bundled/none and the Settings METADATA tile
  already shows it and has an edit dialog (`settings_screen.dart:134-151,
  374-406`) accepting v3 key or v4 token (`TmdbClient` auto-detects,
  `tmdb_client.dart:101-110`).
- Keyless behavior is already graceful: `MetadataService._fetch` returns null
  on empty key (`metadata_service.dart:151-152`) → filename-parsed fallback
  metadata, no artwork. Bundled catalog poster, on-disk metadata cache, and
  `.watch-list` bundle seeding (metadata + posters) all work **entirely
  keyless** — a bundle-importing user needs no key at all. Playback/downloads
  don't touch TMDB.

### Design
1. **Build:** remove the `--dart-define` from `release_build.sh` lines 41/45
   (keep `.env` for dev runs and live tests — it's gitignored and used by
   `flutter run --dart-define-from-file` and `tmdb_live_test.dart`).
2. **Code:** delete `bundledTmdbApiKey` and its fallback; collapse
   `TmdbKeySource` to `user | none` and simplify the Settings subtitle. (Merely
   leaving the const would also compile to empty, but removing it makes the
   intent explicit and un-shippable by accident.)
3. **UX for keyless users:** the Settings tile already handles entry. Add a
   gentle nudge where the absence is felt: when metadata lookup is skipped for
   lack of a key, surface a one-time dismissible banner/snackbar on home —
   "Add a free TMDB API key in Settings → Metadata for posters & details" —
   plus a short "how to get a key" note (link to
   themoviedb.org/settings/api) in the edit dialog and README.
4. **Docs:** README + ROADMAP note that releases are keyless by design and
   bundles carry metadata/posters so casual users never need a key.
5. **⚠️ Rotate the key after shipping.** The current v3 key is already
   extractable from published alpha.32/alpha.33 binaries; stripping it from
   future builds does not retract it. After the first keyless release,
   regenerate the TMDB key on the TMDB account and update `.env` (dev-only
   from then on).

**Tests.** Update `app_settings_test.dart` for the source enum change; keyless
metadata path is already covered.

**Size:** small.

---

## Suggested implementation order
3 (small, has a security angle — key rotation) → 2 (small) → 1 (medium).
2 + 3 could ship together in the next release; 1 is its own PR.
