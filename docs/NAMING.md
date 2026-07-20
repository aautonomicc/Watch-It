# File naming convention

Watch-It resolves artwork and descriptions from the **file name** of each list
entry, so good names mean good metadata. Use the de-facto **Plex/Jellyfin
convention** when naming files before uploading them to Autonomi:

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
  so files can be shared between Watch-It lists and a conventional media server.

## What the parser accepts

`parseMediaName` (app/lib/services/metadata.dart) is permissive. All of these
resolve to a title, year, and (where tagged) IMDb id:

| Name | Title | Year | IMDb id |
|---|---|---|---|
| `Night of the Living Dead (1968) {imdb-tt0063350} - [1080p].mp4` | Night of the Living Dead | 1968 | tt0063350 |
| `The Movie (2024) [imdbid-tt1234567] - [1080p].mkv` (Jellyfin variant) | The Movie | 2024 | tt1234567 |
| `Some Film (1999) - [720p].mkv` | Some Film | 1999 | — |
| `The.Movie.2024.1080p.mkv` (release style) | The Movie | 2024 | — |
| `plainname.mp4` | plainname | — | — |

Rules of thumb:

- Put the year in parentheses right after the title.
- Add the IMDb id as `{imdb-ttXXXXXXX}` (Plex style) or `[imdbid-ttXXXXXXX]`
  (Jellyfin style). Find the id in the movie's IMDb URL.
- Anything else in `{…}` or `[…]` (quality, edition) is stripped from the
  display title.
- TV episodes: `Show S01E02.mkv` style parses today; full episode metadata is a
  later phase.

## Encoding note

Prefer widely hardware-decodable codecs — **H.264 8-bit** plays everywhere,
including phones and older desktops. AV1 10-bit falls back to software decoding
on most devices and struggles even on capable desktops.
