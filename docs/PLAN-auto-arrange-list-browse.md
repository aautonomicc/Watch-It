# Plan: Arrangement toggle (My lists / Auto by type), list drawer, per-list genre browse

Status: IMPLEMENTED (2026-08-01, ships in alpha.42). Open questions were
resolved as: virtual lists (Q1), home wall switches too (Q2),
**multi-select** genre chips with AND semantics (Q3 — user decision,
overriding the single-select plan below), modal drawer everywhere (Q4).
One deviation from §5/§6: with a drawer mounted Flutter drops the back
button, so ListHomeScreen keeps an explicit BackButton in `leading` and
opens the drawer from a menu action on the right instead.

## What the user asked for

1. On the Media Lists page: a slider selector to choose between **user-defined
   lists** and **auto-arrange** — content assigned to lists created from TMDB
   metadata, keyed by `mediaType`: `movie` → **Movies**, `tv` → **TV Shows**
   (mapping not case-sensitive).
2. A **collapsible drawer on the left** to select a list.
3. Selecting a list opens a **list home page** with **selector buttons at the
   top** to filter by the genres the file is listed under on TMDB (sci-fi,
   comedy, …).

## What we already have (verified in code)

- `metadata_cache` (db/app_database.dart:66) already stores per-match
  `mediaType` (`'movie' | 'tv'`, written by tmdb_client.dart:176/229) and
  genres as the `category` string (`'Horror · Thriller'`, `_genres()` joins
  with `· `; for TV it is the **show's** genre list). Neither is exposed to
  screens: `MediaMetadata` has `category` but no `mediaType`, and
  `MetadataService._fromCache` never reads `row.mediaType`.
- `parseMediaName` gives `isEpisode` — a solid offline/unmatched fallback for
  the movie/tv split (episodes are TV, the rest movies).
- Home wall rows, show folding (`groupShows`), and the poster/show cards all
  exist; the cards (`_PosterCard`/`_ShowCard`) are **private to main.dart** and
  need extracting to be reused by the new list page.
- No drawer exists anywhere today; HomeScreen's app bar carries the brand
  lockup as `title`.

## Design

### 1. Auto lists are VIRTUAL (derived at display time), not DB rows

The toggle switches how the library is *arranged for browsing*; it never
creates, edits, or deletes stored lists.

Why not materialize real "Movies"/"TV Shows" rows in the DB:
- Metadata lands asynchronously and can change (key added later, rename,
  7-day miss TTL) — materialized lists would drift stale and need re-sync
  hooks in the import, metadata, and rename paths.
- Toggling back would leave junk lists behind (or destroy them + the user's
  membership edits). A virtual view makes the slider instantly reversible.
- Same entry in several user lists would need duplicate bookkeeping; a derived
  view just dedupes by address.

So: new service `lib/services/library_arrangement.dart`:

```dart
enum LibraryArrangement { userLists, autoByType }

/// 'movie' → Movies, 'tv' → TV Shows. Case-insensitive on the stored
/// mediaType; unmatched entries fall back to parseMediaName
/// (isEpisode → tv, else movie), so the split works keyless/offline too.
String autoListTitleFor(MediaEntry entry);   // 'Movies' | 'TV Shows'

/// Union of entries from ENABLED user lists, deduped by normalized
/// address, split into two virtual MediaLists (ids 'auto:movies',
/// 'auto:tv-shows'). Empty groups are dropped.
List<MediaList> autoLists(List<MediaList> lists);
```

Virtual ids get an `auto:` prefix so nothing confuses them with drift rows
(ListEditScreen, export, rename are simply never offered for them). A user
list already named "movies" (any case) does not clash — auto lists are keyed
by id, not title.

### 2. Surface mediaType (one small metadata change, no schema change)

- `MediaMetadata` gains `final String? mediaType;`.
- `MetadataService._fromCache` copies `row.mediaType`; `_fetch` copies
  `match.mediaType` (both already persisted — **zero drift migration**).
- `fallbackMetadataFor` sets `mediaType: parsed.isEpisode ? 'tv' : 'movie'`
  so `autoListTitleFor` = `metadataFor(entry).mediaType` normalized
  lowercase, with the TMDB match winning over the filename guess as it lands.

### 3. The slider: SegmentedButton on the Media Lists page

- Top of `media_lists_screen.dart`, above the list tiles:
  `SegmentedButton<LibraryArrangement>` — `[ My lists | Auto by type ]`
  (a two-option segmented control is the Material form of a "slider
  selector"; an actual Switch reads as on/off, not A/B).
- Persisted in `AppSettings`: key `library_arrangement_v1`, enum name string,
  default `userLists` (same pattern as `downloadNetworkPolicy`).
- The page's management surface (create/rename/delete/import/export,
  checkboxes) stays user-list only and fully functional in both modes — auto
  mode only changes what the *browse* surfaces show. A one-line hint under
  the control says so ("Auto arranges browsing by type; your lists are kept").

### 4. What auto mode changes

- **Home wall**: list-backed rows are replaced by the two virtual rows
  (Movies, TV Shows); the special rows (Continue Watching, Downloads,
  Recently Added) keep their current behaviour and settings. Implementation:
  `_posterWall` picks `arrangement == autoByType ? autoLists(_lists) :
  visible` for the list-section source. Home-layout reorder/visibility
  (home_sections) applies to user mode; auto rows use a fixed order
  (Movies, TV Shows) — cheap and predictable, revisit if asked.
- **Drawer**: lists shown are mode-dependent (user lists when `userLists`,
  the two virtual lists when `autoByType`).
- Genre browse page works identically for both kinds of list.

### 5. Collapsible left drawer

- `HomeScreen` gets `drawer: WiLibraryDrawer(...)` (new widget,
  `lib/widgets/library_drawer.dart`); Flutter shows the hamburger
  automatically as `leading`, brand lockup stays in `title`. Standard modal
  drawer = "collapsible" (swipe from left / hamburger / tap-away closes).
- Contents: "Library" header, then one `ListTile` per browsable list
  (enabled user lists, or Movies/TV Shows in auto mode) with entry count;
  tapping pushes `ListHomeScreen` for that list. Footer entries: Media
  Lists (management page) and Settings — cheap, discoverable.
- The same drawer is mounted on `ListHomeScreen` too, so hopping list → list
  doesn't need back-navigation. (Push uses `pushReplacement` from a list page
  to avoid stacking N list pages.)
- Desktop wide-window persistent rail: **deferred** — modal drawer everywhere
  first; a `NavigationRail` variant can come later without rework.

### 6. ListHomeScreen (new): per-list page with genre filter

New `lib/screens/list_home_screen.dart`, takes any `MediaList` (real or
virtual):

- App bar: list title + entry count; drawer mounted.
- **Genre chip row** at the top (horizontal scroll of `ChoiceChip`s):
  built from the union of `metadataFor(entry).category` values across the
  list's entries, split on `' · '`, deduped, sorted; `All` first and
  selected by default. **Single-select** (matches "selector buttons";
  multi-select is a later nicety). If any entries have no matched genre, a
  trailing `Uncategorised` chip appears. Chips appear/refine live as TMDB
  matches land (the whole body sits in the same
  `ListenableBuilder(MetadataService.instance)` pattern the wall uses).
  Keyless/offline: just `All` (+ `Uncategorised`) — page still works.
- **Body**: poster GRID (`GridView`, same card aspect as the wall shelves —
  a dedicated page should show everything, not one scrolling shelf), built
  from `groupShows(list.entries)` so a show is one card. Show cards filter
  by the show's genres (TV `category` IS the show's genre list — verified
  in tmdb_client.dart:229-234); a group matches if its first episode's
  metadata carries the selected genre. Cards reuse the extracted wall cards
  and keep download badges / watch bars.
- Note for the UI copy: TMDB's genre name is "Science Fiction" — chips show
  TMDB names as-is, so "sci-fi" appears as Science Fiction.

### 7. Refactor required: extract wall cards

`_PosterCard`, `_ShowCard` (+ `_itemsRow` helpers as needed) move from
main.dart to `lib/widgets/poster_cards.dart` unchanged, so ListHomeScreen and
the wall share one implementation. Pure move, no behaviour change.

## Files touched

| File | Change |
|---|---|
| `lib/services/library_arrangement.dart` | NEW — enum, `autoListTitleFor`, `autoLists`, `genresFor(list)` |
| `lib/services/app_settings.dart` | `libraryArrangement()` / setter, key `library_arrangement_v1` |
| `lib/services/metadata.dart` | `MediaMetadata.mediaType`; fallback sets it from `isEpisode` |
| `lib/services/metadata_service.dart` | plumb `row.mediaType` / `match.mediaType` into `MediaMetadata` |
| `lib/screens/media_lists_screen.dart` | SegmentedButton + hint at top |
| `lib/main.dart` | drawer hookup; mode-aware wall source; cards extracted out |
| `lib/widgets/poster_cards.dart` | NEW — extracted `_PosterCard`/`_ShowCard` |
| `lib/widgets/library_drawer.dart` | NEW — shared drawer |
| `lib/screens/list_home_screen.dart` | NEW — genre chips + grid |

No drift schema change, no Rust change, no import/bundle/download changes.

## Edge rules

- Auto union covers **enabled** lists only (consistent with the wall);
  dedupe by normalized address (same rule as home_rows `_visibleEntries` +
  recentlyAdded).
- An auto group with zero entries is dropped from wall + drawer.
- `mediaType` compare is lowercase-normalized (user requirement); values are
  written by our own tmdb_client so this is belt-and-braces.
- Genre filtering never hides the page: empty result under a chip shows the
  usual empty-state text.

## Tests

- Unit (`library_arrangement_test.dart`): mediaType mapping incl. case
  variants; fallback split by episode marker; dedupe across lists; disabled
  lists excluded; empty-group drop; genre union/split from `category`.
- Metadata: `mediaType` round-trips through cache and fallback.
- Widget: slider persists + wall switches rows; drawer lists mode-correct
  entries and navigates; ListHomeScreen chip filtering (incl. show-group
  case and Uncategorised); keyless page shows All only.
- Existing 313 tests must stay green (cards extraction is the risky move —
  finders that referenced main.dart privates may need imports updated).

## Open questions (plan assumes the bolded answer)

1. Auto mode: **virtual lists** (recommended, reversible) vs actually
   creating stored lists — if you truly want real, editable "Movies"/"TV
   Shows" lists materialized in the DB, say so; that is a different (and
   messier) plan.
2. In auto mode the **home wall also switches** to Movies/TV Shows rows —
   or should auto apply only to the drawer/list pages?
3. Genre chips: **single-select + All** (tap another chip to switch) — or
   multi-select?
4. Drawer on desktop: **modal drawer everywhere** first; persistent side
   rail on wide windows later?

## Estimate

≈ 1.5–2 days including the card extraction, tests, and Xvfb verify.
Fold into alpha.42 or 43 depending on release timing.
