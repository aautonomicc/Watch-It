# Plan: Home-page library search

Status: **implemented as specced** (2026-07-29; spec written the same day).
Landed as `app/lib/services/library_search.dart` + `app/lib/screens/search_screen.dart`
plus the home app-bar icon and `/` / Ctrl+F shortcuts in `main.dart`; Escape is
handled on the query field's own focus node (an ancestor shortcut never sees the
key while the field is focused). The "Later" section below remains future work.
Fills the "Search" nav item and part of the "filter/sort bar" listed as still-to-come in UI-DESIGN.md.

## Scope

Search the **user's library** (all enabled lists) — this is a local library search like
Plex/Jellyfin, **not** a TMDB catalog search of the internet. Everything needed is already
in memory on the home screen (`_HomeScreenState._lists`), so search is pure Dart over
in-memory data: no DB queries per keystroke, no network, no schema changes.

## Entry point & UI

- **Search icon** (`Icons.search`) in the home `AppBar.actions`, first in the row, before
  `DownloadsIndicator` (main.dart:165-172).
- Opens a dedicated full-screen **`SearchScreen`** (`app/lib/screens/search_screen.dart`)
  with an autofocused `TextField` in its app bar (clear ✕ button, back closes). A dedicated
  screen beats an inline expanding field: works identically on phone/TV/desktop and keeps
  the home wall untouched.
- Desktop/TV niceties (cheap, same screen): `/` or `Ctrl+F` on HomeScreen opens search;
  Escape closes; results are focus-traversable for D-pad/arrow keys.
- **Live search-as-you-type**, ~150 ms debounce (cosmetic — the scan is in-memory and fast).
- Below ~2 typed characters: show nothing (or recent searches, see Later). Zero results:
  "No matches in your library" empty state.

## What is searched (v1)

Index is built once per screen-open from `LibraryStore` lists (enabled lists only),
reusing the exact grouping home already does (`groupShows`/`parseMediaName`):

| Result kind | Matched against | Result tile shows | Tap → |
|---|---|---|---|
| Show | parsed show title | poster, title, `N seasons · M episodes` | `ShowScreen(seasons: showSeasons(...))` |
| Movie / single file | parsed title + year | poster, `Title (Year)` | `DetailScreen(entry:)` |
| Episode | parsed title + `SxxEyy` + cached TMDB episode name when present | still/poster, show + `S01E02 · Name` | `DetailScreen(entry:)` |

- Titles/years come from `parseMediaName` (always available, offline, keyless).
- TMDB **episode names** are matched only when already in the metadata cache
  (`episodeLabel` via `MetadataService`) — free bonus, never a network trigger.
- Explicit **non-goals for v1**: overview/genre/cast text search (cache is partial and
  keyless installs have none — matching against it is misleading), fuzzy edit-distance
  typo tolerance, TMDB online search, search inside disabled lists.

## Matching & ranking

- Normalize both sides: lowercase, diacritics folded (é→e), punctuation stripped.
- Query is split into tokens; an item matches if **every token matches some word**
  (prefix match at word starts, plus plain substring as fallback) — so "dark kni",
  "knight dark", and "s02" all behave sensibly.
- Rank: title-starts-with-query > word-start matches > substring matches; ties broken
  alphabetically. Results grouped under headers **Shows / Movies / Episodes**, capped at
  ~20 per group with a "show all N" expander.
- Year tokens (4 digits) match the parsed year; `sXXeYY` / `1x02` tokens match episode
  markers.

## Result decorations

Reuse existing sync stores (both already keyed by address, both ChangeNotifiers the
screen listens to):
- Watched ✓ / progress via `WatchStateStore.cachedStateFor` — same accent bar / badge
  as cards.
- Downloaded badge via `DownloadManager.taskFor(addr)?.status == done` (same predicate
  as `home_rows.dart` downloadedItems).

## Architecture

- **`app/lib/services/library_search.dart`** — pure functions + a small `SearchIndex`
  class: `SearchIndex.build(List<MediaList>)` precomputes normalized strings and
  show/movie/episode records; `index.query(String) → List<SearchResult>` (sealed:
  `ShowResult`/`EntryResult`). 100% unit-testable, no Flutter imports.
- **`app/lib/screens/search_screen.dart`** — UI only: debounce, sections, tiles,
  navigation (reuses `_openEntry`/`_openShow` logic; pass lists in or reload via
  `LibraryStore.load()`).
- `main.dart`: +1 IconButton, +keyboard shortcut. No drift/schema/Rust changes.

Performance: library is a handful of lists (import caps 10 MB txt / 200 MB bundle);
even ~10k entries scan in well under a frame. Index rebuild on `LibraryStore` change is
unnecessary in v1 — the screen is short-lived.

## Later (explicitly out of v1)

1. **Filter chips** on the results/grid: Downloaded only · Unwatched · per-list ·
   movie/show — pairs with the UI-DESIGN filter/sort bar.
2. **Recent searches** (last 8, `AppSettings` key `search_recent_v1`) shown on empty query.
3. Genre/overview matching once metadata coverage is knowable; simple typo tolerance.
4. Search as a bottom-nav tab if/when the nav-tab layout from UI-DESIGN.md lands.

## Test plan

- Unit: normalizer, tokenizer, ranking order, year/SxxEyy tokens, multi-token AND,
  show-vs-movie-vs-episode classification, disabled-list exclusion (~10 tests).
- Widget: type → results appear, tap navigates, empty state, clear button.
- Live: Xvfb run, type into the field, screenshot results (`Watch-It:verify` skill).

## Voice search feasibility (Android TV, Phase 4) — planning note 2026-07-29

Voice is just another way to produce the query string: `SearchIndex.query(String)` is
pure in-memory Dart, so no index/DB/Rust/network changes are needed. Three tiers:

1. **Free (zero code):** the Android TV on-screen keyboard (Gboard for TV / Leanback
   IME) has a built-in mic key — dictation into this screen's `TextField` works as soon
   as the app runs on TV. Ships automatically with this spec.
2. **In-app mic button (recommended TV v1):** D-pad-focusable mic icon in the
   SearchScreen app bar firing `RecognizerIntent.ACTION_RECOGNIZE_SPEECH` via a small
   platform channel; system draws the "Speak now" overlay and returns the transcript →
   set the TextField text, existing live query runs. No RECORD_AUDIO permission needed
   (system speech activity holds it). Hide the button when `resolveActivity` finds no
   recognizer (AOSP boxes, Fire TV, Linux desktop — voice stays Android-only).
3. **Global Assistant search** (remote mic outside the app, "find X on Watch-It"):
   needs native Kotlin (`searchable.xml` + Leanback ContentProvider) and an exported
   queryable copy of the in-memory library. Disproportionate — defer indefinitely.

Sequencing: tier 2 belongs in ROADMAP Phase 4 after D-pad focus traversal exists (the
mic button must be focusable). Requires Google speech services (Play-certified boxes).
