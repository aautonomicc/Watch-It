# File naming convention

W@tch resolves artwork and descriptions from the **file name** of each list
entry, so good names mean good metadata. Matching runs against TMDB and needs a
free API key (Settings → Metadata; create one at themoviedb.org → Settings →
API) — without one, cards show the parsed title only. Use the de-facto
**Plex/Jellyfin convention** when naming files before uploading them to
Autonomi:

```
Title (Year) {imdb-ttXXXXXXX} - [quality].ext
```

Example (the built-in test movie):

```
Night of the Living Dead (1968) {imdb-tt0063350} - [1080p].mp4
```

## Why

- **Exact metadata matches.** The `{imdb-tt…}` tag carries the IMDb id, letting
  the metadata matcher do an exact TMDB `/find` lookup instead of a fuzzy
  title/year search — no wrong-movie artwork.
- **Interoperable.** The same names work unchanged on Plex, Jellyfin, and Emby,
  so files can be shared between W@tch lists and a conventional media server.

## What the parser accepts

`parseMediaName` (app/lib/services/metadata.dart) is permissive. All of these
resolve to a title, year, and (where tagged) IMDb id:

| Name | Title | Year | IMDb id |
|---|---|---|---|
| `Night of the Living Dead (1968) {imdb-tt0063350} - [1080p].mp4` | Night of the Living Dead | 1968 | tt0063350 |
| `The Movie (2024) [imdbid-tt1234567] - [1080p].mkv` (Jellyfin variant) | The Movie | 2024 | tt1234567 |
| `Some Film (1999) - [720p].mkv` | Some Film | 1999 | — |
| `The.Movie.2024.1080p.mkv` (release style) | The Movie | 2024 | — |
| `Show S01E02.mkv` (also `Show.S01E02…`, `Show 1x02`) | Show *(season 1, episode 2)* | — | — |
| `plainname.mp4` | plainname | — | — |

Rules of thumb:

- Put the year in parentheses right after the title.
- Add the IMDb id as `{imdb-ttXXXXXXX}` (Plex style) or `[imdbid-ttXXXXXXX]`
  (Jellyfin style). Find the id in the movie's IMDb URL.
- Anything else in `{…}` or `[…]` (quality, edition) is stripped from the
  display title.
- TV episodes: name files `Show S01E02.mkv` (or `Show 1x02.mkv`). The matcher
  finds the show on TMDB and pulls the episode name and synopsis, the show
  poster, and genres.

## Music

An audio extension (`.flac .mp3 .ogg .oga .opus .m4a .wav .aac .wma`) marks a
file as music — the coarse video/music discriminator. Music tracks follow their
own convention (what the upload CLI's `prepare` writes):

```
Artist - Album (Year) - NN Title {mbid-<release-mbid>}.flac
```

- Track `NN` plays the role `SxxEyy` does for TV: every track of one release
  folds into a single square **album card** on the wall and list pages, which
  opens the album page (cover + tracklist). Multi-disc releases use `D-NN`
  (`2-03`).
- `{mbid-…}` is the MusicBrainz *release* id. It keys the album's metadata the
  way `{imdb-…}` keys a movie's, and fetches the album's front cover from the
  Cover Art Archive — keyless and free, no API key or settings needed (unlike
  TMDB).
- No mbid tag (case-B custom albums) still folds and displays — artist, album,
  year, and track names all come from the file name; there is just no cover
  fetch.
- Folding ignores the artist part: tracks sharing an album name (and year, or
  mbid tag) group into one card even when each track credits its own artist —
  a hand-renamed compilation shows as a single **Various Artists** album. A
  year-less track adopts the year (or mbid) its album name carries elsewhere
  in the list. Guard: if the same track number is credited to two different
  artists, they are really two same-named albums (two `Greatest Hits`) and
  stay separate.
- Audio files without a track marker (`BegBlag.mp3`) stay single entries, typed
  music.

## Uploading from the app

The desktop **Upload** flow (alpha.55+, named *Publish* before
2026-08-27) applies this convention
automatically. When a quality tier re-encodes a file, the output keeps the
source name with the resolution tag replaced by the *real* output height —
`Title (Year) [720p].mp4` for the Medium tier, or `[360p]` for a 360p
source on the Low tier (the encoder never upscales) — and the extension
switched to `.mp4`. Episode markers (`SxxEyy`) are preserved, so multiple
tiers of one title fold into the same card's version picker. A file
uploaded **as-is** (the Original tier) normally keeps its name, but when
it already plays everywhere (H.264 8-bit MP4, ≤1080p — the case where
Original stands in for an encode tier) it gains its real resolution tag
too, so a 1080p `Movie.mp4` uploads as `Movie [1080p].mp4` and lines up
with any encoded siblings. Name your source files per this convention
before uploading and the tags take care of themselves.

Beyond the file name, Upload also stamps each library entry it creates
with a **resolution + codec label** ("1080p H.264") — the same label
imported and seeded entries carry — so the detail page's version picker
shows the full `1080p H.264 · 1.1 GB` line for every tier instead of just
a size. Encode tiers are labelled with their real output height (always
H.264); an Original-tier upload gets its probed height and codec. Entries
published before this shipped stay size-only until their first playback
backfills the resolution.

## Encoding note

Prefer widely hardware-decodable codecs — **H.264 8-bit** plays everywhere,
including phones and older desktops. AV1 10-bit falls back to software decoding
on most devices and struggles even on capable desktops.
