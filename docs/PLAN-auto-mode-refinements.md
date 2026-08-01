# Plan: Auto-mode refinements — "Media" rename, hideable virtual lists

Status: **IMPLEMENTED — shipped in v0.1.0-alpha.43.**
Follows up on the alpha.42 auto-arrange feature (docs/PLAN-auto-arrange-list-browse.md).

Rev 2 (2026-08-01): user decision — the original §3 (real untyped state +
leftover lists) is **dropped**; untyped media without an episode marker keeps
being assigned to Movies (alpha.42 behaviour, see §3). Two changes remain,
all display-layer — no DB schema change anywhere.

Rev 3 (2026-08-01): all open questions **resolved** (user): Q1 no tap on
auto rows, Q2 hiding applies to wall + drawer, Q3 both-hidden allowed —
with the both-hidden home behaviour now specified in §4: hidden virtual
lists also filter Continue Watching (and Recently Added), the Downloads
row is exempt (on-device files always show), and a fully empty auto-mode
home gets a small "enable a list" message.

---

## 1. Rename "Media Lists" → "Media"

User-facing surfaces only; identifiers, file names, and class names stay.

| Surface | File | Change |
|---|---|---|
| Settings tile title | `screens/settings_screen.dart:373` | `'Media Lists'` → `'Media'` |
| Page app-bar title | `screens/media_lists_screen.dart:914` | `'Media Lists'` → `'Media'` |
| Drawer footer entry | `widgets/library_drawer.dart:138` | `'Media Lists'` → `'Media'` |
| Home empty-state hint | `main.dart:615` | `'Settings → Media Lists'` → `'Settings → Media'` |

Update any tests that find these strings (`list_browse_flow_test.dart`,
media-lists screen tests). Doc comments referencing "Media Lists page"
can stay or be swept opportunistically.

## 2. Auto mode: the checkbox rows show the virtual lists

Today the rows under the segmented control always show the stored user
lists, even in Auto by type. Change: the rows follow the selected mode.

- **My lists selected** — unchanged (checkbox = `list.enabled`,
  tap → ListEditScreen, 3-dot rename/export/delete).
- **Auto by type selected** — rows are the *virtual* lists that auto
  mode currently produces (Movies, TV Shows), each with a checkbox
  meaning "shown in auto mode". No 3-dot menu, no tap action (virtual
  lists can't be edited/renamed); subtitle = entry count (+ "hidden
  from home" when unchecked). Helper text under the control adjusts
  to explain the checkboxes.

### Persistence

New pref `auto_hidden_lists_v1` (StringList of virtual-list ids) in
`AppSettings`, mirrored into `ArrangementStore` (new
`Set<String> hiddenAutoIds` + `toggleAutoHidden(id)`, loaded in
`ensureLoaded`, `notifyListeners` on change) so the wall, drawer, and
Media page all flip live — same pattern as the arrangement value itself.

Virtual ids: `auto:movies`, `auto:tv-shows` (existing) — keyed
independently of the user-mode `enabled` flag, so hiding a virtual
list in auto mode does not affect My-lists mode (and vice versa;
`enabled` still gates which lists feed the union, as today).

### Consumers

- `autoLists(lists)` stays **unfiltered** (the Media page needs hidden
  rows too, unchecked).
- `browsableLists(...)` (drawer) and the home-wall loop
  (`main.dart:362`) filter out hidden ids — add
  `visibleAutoLists(lists, hidden)` or a `hidden:` param on
  `browsableLists` so every surface shares one rule.
- `ListHomeScreen` refresh keeps working (it rebuilds from
  `autoLists`); a list hidden while its page is open simply stays until
  popped and disappears from the drawer.

## 3. Untyped media — DROPPED (rev 2 user decision)

Original request was to keep type-less media in its own original list
in auto mode. User reconsidered after the keyless-install consequence
was flagged: **untyped media without an episode marker should just be
assigned to Movies** — i.e. exactly what `fallbackMetadataFor`
(services/metadata.dart:122) already does in alpha.42 (episode marker →
TV, everything else → movie, TMDB/catalog match wins when present).

**No code change.** Every entry always has a type, so there are no
leftover lists, no merge-by-name, and no `auto:list:<id>` ids; the
virtual lists remain exactly Movies + TV Shows.

## 4. Hidden virtual lists and the home special rows (rev 3)

Today Continue Watching, Downloads, and Recently Added all draw from
`_visibleEntries` (services/home_rows.dart:24 — entries of `enabled`
user lists) and know nothing about auto-mode hiding. Rule set (user
decision):

- **Continue Watching** — in auto mode, entries whose virtual list is
  hidden drop out of the row (hide TV Shows → its episodes leave
  Continue Watching too; both hidden → row empty and its title
  suppressed, as `_continueSection` already does for an empty row).
- **Recently Added** — same filter, for consistency (a hidden type
  resurfacing in Recently Added would undercut the hide; decision
  taken, not left open).
- **Downloads** — **never filtered.** Downloaded files live on the
  device and stay playable, so the row shows whenever any download
  exists, even with both virtual lists hidden (user decision).

Implementation: factor the entry→virtual-id classification out of
`autoLists` into `autoIdForEntry(MediaEntry)` (same mediaType +
episode-marker fallback) in `library_arrangement.dart`. Filter at
*build* time in `_posterWall` (main.dart) — `_continue`/`_recent` are
computed async in `_reload`, but `_posterWall` rebuilds inside the
ListenableBuilder on every ArrangementStore notification, so a
checkbox flip on the Media page hides/reveals the rows live without
re-running the async row queries. User mode: no change, filter inert.

### Auto-mode empty home

Both virtual lists hidden (or empty) + filtered Continue/Recently
empty + no downloads → the wall would render a blank scroll view.
Instead, when auto mode produces **zero** children, show a small
centred message (reuse the `_EmptyState` pattern / widget with a new
variant):

- Enabled lists contain media → "All media is hidden" / "Enable a
  list in Settings → Media to show it here." (rename from §1 applies).
- No media at all → the existing empty/all-hidden variants as today.

The drawer in this state lists no browsable lists but keeps its
Media/Settings footer, so navigation back to the checkboxes is one
tap from the hamburger — no dead end.

## Open questions — RESOLVED (rev 3, user)

1. Tap on an auto-mode row? **No tap — checkbox only.**
2. Where does hiding apply? **Home wall and drawer both.**
3. Both virtual lists hidden? **Allowed**, with the §4 behaviour:
   special rows follow the hide (Downloads exempt), empty home shows
   the enable-a-list message.

## Tests

- `library_arrangement_test.dart`: hidden-id filtering
  (visibleAutoLists/browsableLists), hidden state independent of
  `enabled`, both-hidden → empty; `autoIdForEntry` classification.
- `list_browse_flow_test.dart` / media-lists tests: auto-mode rows show
  virtual lists with working hide checkboxes and no 3-dot menu; "Media"
  rename string updates.
- Home-row tests: auto + hidden TV Shows → episodes gone from Continue
  Watching/Recently Added, downloads row unaffected; both hidden + a
  download → Downloads row only; both hidden + none → "All media is
  hidden" message; user mode unaffected by hiddenAutoIds.
- Xvfb GUI drive for the mode-dependent rows, a hidden virtual list
  vanishing from wall and drawer, and the empty-home message.

## Touched files

`services/library_arrangement.dart`, `services/app_settings.dart`,
`screens/media_lists_screen.dart`, `screens/settings_screen.dart`,
`widgets/library_drawer.dart`, `main.dart` (+ tests).
(`services/metadata.dart` no longer touched — §3 dropped;
`services/home_rows.dart` unchanged — the auto filter sits in
`_posterWall`, classification helper in `library_arrangement.dart`.)

**Estimate:** ~half a day to a day including tests and GUI verify.
Fits alpha.43.
