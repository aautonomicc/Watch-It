# UI Design

Look-and-feel target: the Plex/Emby/Silo "streaming service" aesthetic — dark theme,
poster art everywhere, minimal chrome.

## Design language

- **Dark-first.** Near-black background (#0e0e12), poster art provides the color.
  Light theme later.
- **One accent color** (candidate: warm amber/orange — distinct from Plex yellow-orange,
  Jellyfin purple, Emby green).
- Poster cards with rounded corners, hover/focus scale on desktop, watched-progress bar
  along the card bottom, unwatched-count badge for shows.
- Typography: Inter (UI) — clean, free, everywhere.

## Screens

### 1. Home
- Top row: **Continue Watching** (landscape thumbnails with progress bars)
- **Recently Added** per library
- **Next Up** (next unwatched episode per show)
- Source switcher in the sidebar/drawer: Local · <server name> · Autonomi

### 2. Library grid
- Poster wall, infinite scroll, alphabet fast-scroller on the right
- Filter/sort bar: genre, year, watched state, A-Z / recently added / rating

### 3. Detail page (movie / show)
- Backdrop art with gradient into the page
- Poster, title, year, runtime, rating badges, genre chips, overview
- Big **Play / Resume** button; for shows: season tabs → episode list with thumbnails
  and per-episode watched state
- Cast row (metadata permitting), "mark watched", "go to folder/source"

### 4. Player
- Video fills the window/screen; controls auto-hide
- Bottom bar: seek bar with chapter markers and hover thumbnails (later), play/pause,
  ±10s skip, audio track, subtitle track, speed, volume, fullscreen
- Desktop: full keyboard map (space, ←/→, f, m, s, numbers = percent-seek — mpv-style)
- Mobile: gestures — swipe left edge = brightness, right edge = volume, horizontal = seek,
  double-tap sides = ±10s
- "Up next" card in the last 30 seconds of an episode

### 5. Settings
- Sources (add folder / add server / Autonomi gateway)
- Playback (hardware decode, default subtitle language, skip amounts)
- Appearance (theme, poster size)
- About / licenses

## Layout adaptation

| | Mobile (Android/iOS) | Desktop (Linux/Win/Mac) |
|---|---|---|
| Nav | bottom tab bar (Home · Libraries · Search · Settings) | slim left sidebar |
| Grid | 3 posters wide | responsive, 6–10 wide |
| Detail | vertical scroll | two-column hero |
| Player | gesture-driven | keyboard + mouse hover |

## First deliverable

A clickable Flutter prototype of Home + Library grid + Detail with mock data, to lock
the visual language before wiring real sources.
