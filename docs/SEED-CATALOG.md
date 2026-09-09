# Built-in seed catalog

Since the post-alpha.92 swap (2026-09-09) the app seeds a single Movies
list with **Big Buck Bunny (2008)** in three quality tiers on first
run: the official Blender "sunflower" 1080p 30fps release uploaded
as-is (`ant file upload`, 2026-09-09) plus the project's own 720p and
480p encodes made with the app's exact Publish tier ffmpeg settings.
The three share a parsed lookup key but carry per-tier quality tags in
their names (exactly as the in-app Publish flow names tiers), so they
fold into one wall card — "3 versions", version dropdown on the detail
page, told apart by `sizeBytes`/`videoInfo`. 3 catalog entries, 3
bundled root maps (+2 legacy, below).

**Licence:** BBB is CC-BY 3.0 Blender Foundation — *not* public
domain. It is therefore **seed-only**: never added to
`catalog/Public Domain.watch-list` (or any published list), and the
attribution ("© 2008 Blender Foundation | www.bigbuckbunny.org …
Creative Commons Attribution 3.0") is appended to its description both
in the bundled seed metadata (via `kOverviewAttribution` in
`tool/harvest_seed_metadata.dart` — survives regeneration) and the
offline `_bbb` fallback in `metadata.dart`, so it shows wherever the
description renders.

History: alpha.48–.50 seeded a full 48-title PD catalog (10 movies plus
Petticoat Junction 21 season-1 episodes and One Step Beyond 17
episodes). Alpha.51 trimmed the bundle to the two Night of the Living
Dead uploads, and the post-alpha.92 swap replaced NOTLD with BBB so app
stores don't get a horror film as the only pre-installed title. Both
changes touch the **app bundle only**: Autonomi data is permanent, so
every dropped upload remains live and playable for anyone holding its
`.datamap`, and installs that already seeded them keep every entry,
root map, and cached poster they have (no removal migration — the
alpha.51 Option A precedent, reaffirmed for the BBB swap 2026-09-09).
Only fresh installs and factory resets see the current catalog. The two
NOTLD root maps stay bundled as **legacy assets**
(`kLegacyBundledRootMapAddresses` in `rootmap_seeder.dart`) so an
existing install that loses its map store can still re-seed offline;
current code never adds NOTLD to any library.

## Moving parts

| Piece | Where |
|---|---|
| Catalog (names + derived addresses + file info) | `app/lib/services/seed_catalog.dart` (`kSeedLists`) — each entry also carries `sizeBytes` (exact upload size) and `videoInfo` (`480p H.264`, ffprobed from the source files) |
| Library seeding / upgrade migration | `LibraryStore.ensureDefaults` (`defaults_seeded_v4` flag); file info gap-fill for installs seeded before the columns existed: `ensureSeedFileInfo` (`seed_fileinfo_v1` flag — annotates by address, never re-adds); post-v4 catalog additions for already-seeded installs: `ensureSeedAdditions` (`kSeedAdditionAddresses` + `seed_additions_v1` flag — skips held addresses, never recreates a deleted seed list) |
| Bundled root maps (one per tier, plus the two legacy NOTLD maps) | `app/assets/rootmaps/<address>.map`, seeded into the local map store at startup by `rootmap_seeder.dart` (`kBundledRootMapAddresses` = catalog + `kLegacyBundledRootMapAddresses`) |
| Bundled TMDB metadata + artwork | `app/assets/seed_metadata/metadata.json` + `posters/*.jpg`, gap-filled into the metadata cache at startup by `metadata_seeder.dart` (`seed_metadata_v1` flag) — fresh keyless installs show the poster/description offline; BBB's rows carry the CC-BY attribution in `overview` |
| Seed movie constants | `kSeedMovie{1080,720,480}Address` / `…Name` in `metadata.dart` (the BBB tiers). The NOTLD-era `kDefaultMovieAddress` / `kDefaultMovieName` / `kDefaultMovie1080Address` survive only as the `kLegacyDefaultMovieAddresses` rewrite target and the legacy bundled-root-map list (`kLegacyDefaultMovieAddresses` itself still holds only the two dead pre-alpha.16 addresses) |

The bundled root maps are **required** for the seeded entries to play:
the play path serves locally stored maps only (no network resolve since
alpha.41), and the catalog ships addresses, not `.datamap` files.
`ensureDefaults` never duplicates an entry the user already holds and
never re-adds anything the user deleted; upgraded v3-seeded installs
gain the new titles once and get their old default-movie entry rewritten
to the new address in place.

## Regenerating

Each upload's ant-cli `.datamap` (a shrunk child map) is kept by the
uploader (BBB tiers: `~/bbb-seed/` on the build host; the old PD
uploads: `~/Public domain`). To regenerate after re-uploading or adding
titles:

1. Start a connected devserver and `POST /datamap` each `.datamap` file
   — the response carries the derived address, and the expanded root map
   is then exported with `GET /rootmap/<address>` into
   `app/assets/rootmaps/<address>.map`.
2. Rewrite `kSeedLists` from the name → address results (movies list
   leads with the default movie, then alphabetical; episodes in SxxEyy
   order). Each entry also needs `sizeBytes` (`stat -c%s` of the source
   file — identical to the uploaded bytes) and `videoInfo`
   (`ffprobe -select_streams v:0 -show_entries stream=codec_name,height`,
   mapped to a ladder label via `resolutionLabel()` + codec name, e.g.
   `480p H.264`). Use the **probed** values, not the file name's quality
   tag — third-party sources can lie (the old 480p NOTLD archive.org
   upload said `[1080p]` in its name); for the self-encoded BBB tiers a
   `file_info_test.dart` test pins that tag and probe agree. Bump
   `seed_fileinfo_v1` in `library_store.dart` if existing installs
   should receive corrected info.
3. To deliver **added** titles to installs that already ran the v4 seed,
   list their addresses in `kSeedAdditionAddresses` and bump the
   `seed_additions_vN` flag in `library_store.dart` — do NOT bump
   `defaults_seeded_vN`, which would re-run the full merge and re-add
   every catalog entry the user has deleted. An addition slots in next
   to the catalog entry that precedes it when the user still holds that
   sibling, else at the end of its list; a deleted seed list is not
   recreated.
4. Regenerate the bundled TMDB metadata + artwork (from `app/`, with the
   repo-root `.env` loaded):

   ```
   set -a; source ../.env; set +a
   dart run tool/harvest_seed_metadata.dart
   ```

   The tool resolves every `kSeedLists` entry with the app's own matcher
   (identical lookup keys, cache-row shape, and image file names to
   `metadata_service.dart`) and rewrites `app/assets/seed_metadata/`.
   It does NOT delete `posters/` files the new catalog no longer
   references — prune those by hand after a trim (only images named in
   the fresh `metadata.json` belong in the bundle). It fails loudly on
   any unmatched entry, and appends any licence attribution registered
   in its `kOverviewAttribution` map (BBB's CC-BY credit) to the
   harvested overview. Bump `kSeedMetadataFlag` in
   `metadata_seeder.dart` (`seed_metadata_vN`) so existing installs
   gap-fill the new titles' rows — NOT done for the BBB swap, which is
   deliberately fresh-installs-only.

The rootmap-seeder test asserts an asset exists for every catalog
address, and the metadata-seeder test asserts a bundled metadata row +
artwork exist for every entry — a catalog/asset mismatch fails CI.
