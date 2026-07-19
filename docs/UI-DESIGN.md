# UI Design

Look-and-feel target: the Plex/Emby/Silo "streaming service" aesthetic — dark theme,
poster art everywhere, minimal chrome.

## Design language

Colours, fonts, and type scale live in **[BRAND.md](BRAND.md)** — Watch-It follows
the etchit.io family design language (fetch>it / etch/it): warm near-black
"ink" surfaces, bone-white text, copper `#c9732b` accent, system UI fonts,
mono for XOR addresses, lowercase `watch-it` wordmark.

- **Dark-first.** `--ink` (#0a0a0a) canvas, poster art provides the colour.
  Three themes (dark / dim / light), dark default.
- **One accent — copper** (#c9732b): distinct from Plex yellow-orange,
  Jellyfin purple, Emby green; used for play/focus/progress only, never
  large surfaces.
- Poster cards with rounded corners, hover/focus scale on desktop, watched-progress bar
  along the card bottom (copper fill), unwatched-count badge for shows.
- **Download/offline state on every card**: small badge (ash outline = stream-only,
  green check = downloaded, copper progress ring = downloading).

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
- **Import list** (file or, later, Autonomi address) / **export list**
- Reorder, rename, delete lists; re-run metadata match on an entry

### 5. Player
- Video fills the window/screen; controls auto-hide
- Bottom bar: seek bar with chapter markers, play/pause, ±10s skip, audio track,
  subtitle track, speed, volume, fullscreen
- Buffering indicator distinguishes network fetch from decode stalls
- Desktop: full keyboard map (space, ←/→, f, m, s, numbers = percent-seek — mpv-style)
- Mobile: gestures — swipe left edge = brightness, right edge = volume, horizontal =
  seek, double-tap sides = ±10s
- "Up next" card in the last 30 seconds of an episode

### 6. Settings
- Lists (manage, import/export)
- Network (gateway config if applicable, bandwidth limit for downloads)
- Downloads (storage location, storage used, clear)
- Playback (hardware decode, default subtitle language, skip amounts)
- Appearance (theme, poster size)
- About / licenses

## Layout adaptation

| | Mobile (Android/iOS) | Desktop (Linux/Win/Mac) |
|---|---|---|
| Nav | bottom tab bar (Home · Library · Search · Settings) | slim left sidebar |
| Grid | 3 posters wide | responsive, 6–10 wide |
| Detail | vertical scroll | two-column hero |
| Player | gesture-driven | keyboard + mouse hover |

## First deliverable

A clickable Flutter prototype of Home + Library grid + Detail with mock data, to lock
the visual language before wiring the network.
