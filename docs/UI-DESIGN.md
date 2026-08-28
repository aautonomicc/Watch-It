# UI Design

Look-and-feel target: the Plex/Emby/Silo "streaming service" aesthetic — dark theme,
poster art everywhere, minimal chrome.

## Design language

Colours, fonts, and type scale live in **[BRAND.md](BRAND.md)** — W@tch follows
the etchit.io family design language (fetch>it / etch/it): warm near-black
"ink" surfaces, bone-white text, blue `#42a5f5` accent (a deliberate divergence from the family copper — see BRAND.md), system UI fonts,
mono for content addresses, the `W@tch` wordmark in Anton (since 2026-07-31; formerly lowercase mono `watch-it`).

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
- Derived address shown (copyable; the entry's content identity)

### 4. Add / manage lists
- **Add entry**: multi-select `.datamap` file picker (the file name carries the
  media name → metadata matches automatically); no address is ever typed
- **Import**: "Add .datamap files" or "Import .watch-list bundle" (local
  file); zip magic sniffed, extension irrelevant
- **Export**: `.watch-list` bundle only, with a watch-history checkbox
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
- Wallet (renamed from Publishing 2026-08-27: create with 12-word
  ceremony + retype confirm, import key/phrase, live ANT/ETH balances,
  remove; one wallet will fund both private uploads and the planned
  public Channels)
- Playback (hardware decode, default subtitle language, skip amounts)
- Appearance (theme, poster size)
- About / licenses (incl. TMDB attribution notice + logo; the Terms of
  Use & Disclaimer page — also gated on first launch; update-check
  toggle + "Update available" row on desktop)

### 7. Upload (desktop, alpha.55/.56; renamed from Publish 2026-08-27)
- Drawer tile between Media and Settings (desktop-only), subtitle
  "Private · only your devices" — the word "publish" is reserved for
  the planned public Channels (PLAN-personal-vs-channels.md)
- Multi-select file pick with "Add more" / per-file remove; per-file
  probe verdict line ("1080p H.264 10-bit — many devices can't play
  this" / "480p H.264 — plays everywhere")
- Quality checkboxes — High 1080p / Medium 720p / Low 480p (H.264+AAC
  MP4, never upscaled) or Original as-is — with per-tier
  "applies to N of M · ≈size · ≈ANT" and a summed live cost estimate
- Rights/permanence confirm gate → sequential encode→upload queue with
  progress and per-item retry/skip → done page: per-title address +
  copy, add-all-to-library via the list picker, save-all `.datamap`
  files

### 8. My W@tch (alpha.61/.62)
- Lives under Settings → Network since alpha.63 (desktop + Android)
- Unlinked: **Link this device** (names the device, shows the invite as
  a QR code + copyable `wtch1-…` code) or **Join** (paste the code, or
  scan the QR with the camera on Android/iOS)
- Linked: Last sync / Linked since, a row per device with online dot,
  last-heard time, and list/item counts; Show invite, **Sync now**, and
  Unlink (with confirm)
- Sync itself is invisible: a background cycle keeps lists, viewing
  positions, edits, and artwork current whenever linked devices are
  online together — the page never needs to be open

### 9. Channels (2026-08-27, unreleased)
- Drawer tile **Channels** (amber icon, "Public · anyone with the
  code") — a separate door from the blue Upload tile on purpose; every
  channel surface carries an amber PUBLIC/CHANNEL badge
- **Subscribed** segment (default, all platforms): channel cards with
  name/description/item count/update state, Add channel (paste
  `wchn1-…` or scan QR on mobile, with the content-comes-from-the-owner
  note); subscribed channels render on the home wall + drawer as
  read-only amber-badged lists that update automatically
- **My Channel** segment (desktop): Create channel → name/description →
  12-word key ceremony (show → retype 3) → full-screen
  public/permanent/attributable gate confirmed by typing the channel
  name; then code + QR to share, backup-status row, the item list
  subscribers see, "Publish an item" (a LOCAL FILE first, the Upload
  flow's shape: choose a file → quality tiers to encode → required
  Describe-this-item, whose Check TMDB button fills title/description/
  artwork from a previewed TMDB match → rights attestation → encode +
  upload → staged, with an optional add-to-library leg; "Add an item
  already in the library" keeps the picker for existing uploads) and
  "Publish update" with a live cost preview; Restore channel by phrase
- Settings is untouched — publishing is an activity, not a setting

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
address is preferred over typing addresses with a remote).

## Built so far (alpha.64 + unreleased Channels)

The home poster wall (with show-level grouping and Continue Watching /
Recently Added rows), big-artwork Show → Season → Detail pages (TMDB ratings,
air dates, episode screenshots, Resume / Start over, Watched badge, Next
episode), the player with buffering overlay, resume-from-saved-position and
the end-of-episode Up-next auto-play card, the Media Lists management page
(create/hide/rename/delete, datamap/bundle import — local or by network
address — per-list bundle export), and Settings (network status, metadata key,
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
demo-movie data map for a fast first play. Alpha.42/.43 add the left
library drawer and the "My lists | Auto by type" arrangement toggle
(virtual Movies / TV Shows lists; the toggle was removed again after
alpha.66 — it hid custom lists with no TMDB match, so browsing is
always the user's own lists) plus per-list browse pages with
multi-select genre filter chips (since the post-alpha.66 changes the
Uncategorised chip only appears when the list also has categorised
items, and the list editor curates entries in a show → season tree
with per-item/season/show remove and move-to-list). Alpha.48 seeds a full public-domain
poster wall (three rows with bundled artwork) on first run and adds a
file-size/format line ("480p H.264 · 570 MB") to cards and detail
pages; alpha.49 folds same-title uploads into one card with an
"N versions" line and a detail-page version dropdown. Alpha.50 settles
the home app bar layout: search icon far left, library-drawer hamburger
far right, and the settings icon removed from the bar (Settings lives
in the drawer). Alpha.51 adds the Favourites home row (heart on detail
pages, beside Download since alpha.52). Alpha.54 hides the mouse cursor
when the player controls fade. Alpha.55/.56 ship the Upload screen (named Publish until 2026-08-27)
and the Settings → Wallet section described above, plus the update-check
toggle and badge in Settings → About. Alpha.57 adds the detail-page
Edit details editor (pencil in the app bar): title/year/description
plus artwork from an image file, a 12-frame video-frame picker
(desktop), or the player's camera button; alpha.58 extends the pencil
to show and season pages with properly scoped editors, and alpha.59
adds a crop/zoom step after picking a poster frame. Alpha.60 adds the
first-launch Terms of Use accept gate (and its read-only page in
Settings → About) plus the upload quality explainer dialog. Alpha.61
adds the My W@tch drawer page described above (link/join with QR,
device presence, Sync now) with camera QR scanning on Android;
alpha.62 makes edits and full-quality artwork ride the same sync.
Still to come from this document: filter/sort + fast-scroller on
the grid, the full desktop keyboard map, mobile gestures, and the TV layout.
