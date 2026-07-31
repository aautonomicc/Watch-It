# UI Design

Look-and-feel target: the Plex/Emby/Silo "streaming service" aesthetic — dark theme,
poster art everywhere, minimal chrome.

## Design language

Colours, fonts, and type scale live in **[BRAND.md](BRAND.md)** — W@tch follows
the etchit.io family design language (fetch>it / etch/it): warm near-black
"ink" surfaces, bone-white text, blue `#42a5f5` accent (a deliberate divergence from the family copper — see BRAND.md), system UI fonts,
mono for XOR addresses, the `W@tch` wordmark in Anton (since 2026-07-31; formerly lowercase mono `watch-it`).

- **Dark-first.** `--ink` (#0a0a0a) canvas, poster art provides the colour.
  Three themes (dark / dim / light), dark default.
- **One accent — blue** (#42a5f5; #1976d2 in the light theme): distinct from Plex yellow-orange,
  Jellyfin purple, Emby green; used for play/focus/progress only, never
  large surfaces.
- Poster cards with rounded corners, hover/focus scale on desktop, watched-progress bar
  along the card bottom (accent fill), unwatched-count badge for shows.
- **Download/offline state on every card**: small badge (ash outline = stream-only,
  green check = downloaded, accent progress ring = downloading).

## Screens

### 1. Home
- Top row: **Continue Watching** (landscape thumbnails with progress bars)
- **Recently Added** per list
- **Next Up** (next unwatched episode per show)
- List switcher in the sidebar/drawer: All · <list name> · <list name> · Downloads

### 2. Library grid
- Poster wall, infinite scroll, alphabet fast-scroller on the right
- Filter/sort bar: category/genre, year, watched state, downloaded-only,
  A-Z / recently added / rating

### 3. Detail page (movie / show)
- Backdrop art with gradient into the page
- Poster, title, year, runtime, rating badges, category/genre chips, overview
  (all fetched from TMDB by file name)
- Big **Play / Resume** button + **Download** button (or Remove Download / progress)
- For shows: season tabs → episode list with thumbnails and per-episode watched state
- Autonomi address shown (copyable) with "share entry" action

### 4. Add / manage lists
- **Add entry**: paste XOR address + file name → live metadata preview card → save to
  a chosen list
- **Import list**: one button, auto-detects plain `.txt` vs `.watch-list` bundle
  by content sniff — never asks about format
- **Export list**: one button, two-step dialog — "List only (.txt)" vs
  "Full bundle (.watch-list)", then bundle-only checkboxes: watch history
  (default off), root maps (default on); see
  [BUNDLE-FORMAT.md](BUNDLE-FORMAT.md)
- Reorder, rename, delete lists; re-run metadata match on an entry

### 5. Player
- Video fills the window/screen; controls auto-hide
- Bottom bar: seek bar with chapter markers, play/pause, ±10s skip, audio track,
  subtitle track, speed, volume, fullscreen
- Buffering indicator distinguishes network fetch from decode stalls
- Desktop: full keyboard map (space, ←/→, f, m, s, numbers = percent-seek — mpv-style)
- Mobile: gestures — swipe left edge = brightness, right edge = volume, horizontal =
  seek, double-tap sides = ±10s
- TV (Android TV remote): select = play/pause, ←/→ = seek (hold to accelerate),
  ↑/↓ = show controls / up-next, back = dismiss controls then exit player;
  media keys (play/pause/FF/RW) mapped directly
- "Up next" card in the last 30 seconds of an episode

### 6. Settings
- Lists (manage, import/export)
- Network (embedded client status, bandwidth limit for downloads)
- Downloads (storage location, storage used, clear)
- Playback (hardware decode, default subtitle language, skip amounts)
- Appearance (theme, poster size)
- About / licenses (incl. TMDB attribution notice + logo)

## Layout adaptation

| | Mobile (Android/iOS) | Desktop (Linux/Win/Mac) | TV (Android TV, 10-foot) |
|---|---|---|---|
| Nav | bottom tab bar (Home · Library · Search · Settings) | slim left sidebar | left rail, collapsed to icons; D-pad only |
| Grid | 3 posters wide | responsive, 6–10 wide | 5–6 wide, focused card scales + accent focus ring |
| Detail | vertical scroll | two-column hero | full-bleed backdrop, focusable button row |
| Player | gesture-driven | keyboard + mouse hover | remote-driven (see Player above) |
| Input | touch | keyboard + mouse | D-pad focus traversal; every action reachable without a pointer |

TV notes: larger base type scale (readable at 3 m), no hover-only affordances, text
entry kept to add/import flows only (paste via network share or a shown-on-TV import
address is preferred over typing XOR addresses with a remote).

## Built so far (alpha.38)

The home poster wall (with show-level grouping and Continue Watching /
Recently Added rows), big-artwork Show → Season → Detail pages (TMDB ratings,
air dates, episode screenshots, Resume / Start over, Watched badge, Next
episode), the player with buffering overlay, resume-from-saved-position and
the end-of-episode Up-next auto-play card, the Media Lists management page
(create/hide/rename/delete, import from file or Autonomi address with
prefetch, per-list export), and Settings (network status, metadata key,
Downloads queue page, size on disk + factory reset) are all live on Android
and Linux. Downloads shipped in alpha.30/.31: a Download button with
progress on detail pages, download badges on every card (accent check =
downloaded, progress ring = downloading, any-downloaded count on show/season
cards), downloaded titles playing locally, and offline gating — browsing
always works, Play is disabled with a hint on non-downloaded titles when
offline. Alpha.32 added a season download-all button, a Downloads row on the
home wall, multi-select/delete-all in the downloads queue, and a top-bar
download meter. Alpha.33 added `.watch-list` bundle export/import (two-step
Export dialog, one auto-detecting Import button) on the Media Lists page,
TMDB attribution in Settings → About, and the Linux taskbar icon.
Alpha.34 added keyless releases (with the dismissible TMDB nudge banner),
show-level Download All, home-row customization (Settings → Home screen:
reorder + show/hide rows), and the 8px watch-progress bar on all cards.
Alpha.35 ships home-page library search (docs/PLAN-home-search.md) —
search icon in the home app bar (`/` or Ctrl+F on desktop) opening a
full-screen live search over the library, grouped Shows / Movies /
Episodes with download/watched badges. Alpha.36 ships the striped
popcorn-bucket logo — launcher/taskbar icon on Android and Linux plus the
icon + wordmark lockup in the home app bar — and alpha.37 turns the
logo stripe and the app accent blue (#42a5f5). Alpha.38 adds Settings →
Network (downloads Wi-Fi-only by default, ask-before-streaming on
cellular), automatic reconnection after network loss on both platforms,
an Android background-download progress notification, and the bundled
demo-movie data map for a fast first play. Still to
come from this document: filter/sort + fast-scroller on
the grid, the full desktop keyboard map, mobile gestures, and the TV layout.
