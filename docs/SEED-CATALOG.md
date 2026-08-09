# Built-in seed catalog

Since alpha.51 the app seeds a single Movies list with the two Night of
the Living Dead uploads on first run: the 480p archive.org upload
(verified public domain, uploaded with plain `ant file upload` on
2026-08-07) and the genuine-1080p 5.68GB re-encode that was the default
movie up to alpha.47. Both ship under the identical network file name
and are told apart by their `sizeBytes`/`videoInfo` columns (the
same-title differentiation feature exists for exactly this) — one wall
card, "2 versions", version dropdown on the detail page. 2 catalog
entries, 2 bundled root maps.

History: alpha.48–.50 seeded a full 48-title PD catalog (10 movies plus
Petticoat Junction 21 season-1 episodes and One Step Beyond 17
episodes). Alpha.51 stopped bundling everything but NOTLD — a trim of
the **app bundle only**: Autonomi data is permanent, so the 47 dropped
uploads remain live and playable for anyone holding their `.datamap`
files, and installs that already seeded them keep every entry, root
map, and cached poster they have (no removal migration — decided
2026-08-09, see `docs/PLAN-trim-seed-catalog-to-notld.md`). Only fresh
installs and factory resets see the trimmed catalog.

## Moving parts

| Piece | Where |
|---|---|
| Catalog (names + derived addresses + file info) | `app/lib/services/seed_catalog.dart` (`kSeedLists`) — each entry also carries `sizeBytes` (exact upload size) and `videoInfo` (`480p H.264`, ffprobed from the source files) |
| Library seeding / upgrade migration | `LibraryStore.ensureDefaults` (`defaults_seeded_v4` flag); file info gap-fill for installs seeded before the columns existed: `ensureSeedFileInfo` (`seed_fileinfo_v1` flag — annotates by address, never re-adds); post-v4 catalog additions for already-seeded installs: `ensureSeedAdditions` (`kSeedAdditionAddresses` + `seed_additions_v1` flag — skips held addresses, never recreates a deleted seed list) |
| Bundled root maps (one per title) | `app/assets/rootmaps/<address>.map`, seeded into the local map store at startup by `rootmap_seeder.dart` |
| Bundled TMDB metadata + artwork | `app/assets/seed_metadata/metadata.json` + `posters/*.jpg` (~56K since the alpha.51 trim), gap-filled into the metadata cache at startup by `metadata_seeder.dart` (`seed_metadata_v1` flag) — fresh keyless installs show the poster/description offline |
| Default movie constants | `kDefaultMovieAddress` / `kDefaultMovieName` / `kDefaultMovie1080Address` in `metadata.dart` — the default is the catalog's 480p NOTLD upload; the 5.68GB re-encode is a catalog entry again (NOT in `kLegacyDefaultMovieAddresses`, which holds only the two dead pre-alpha.16 addresses) |

The bundled root maps are **required** for the seeded entries to play:
the play path serves locally stored maps only (no network resolve since
alpha.41), and the catalog ships addresses, not `.datamap` files.
`ensureDefaults` never duplicates an entry the user already holds and
never re-adds anything the user deleted; upgraded v3-seeded installs
gain the new titles once and get their old default-movie entry rewritten
to the new address in place.

## Regenerating

Each upload's ant-cli `.datamap` (a shrunk child map) sits next to its
`.mp4` in the uploader's `~/Public domain` directory. To regenerate
after re-uploading or adding titles:

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
   tag — the 480p NOTLD archive.org upload says `[1080p]` in its name
   but is really 480p (a `file_info_test.dart` test pins this). Bump
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
   any unmatched entry. Bump `kSeedMetadataFlag` in
   `metadata_seeder.dart` (`seed_metadata_vN`) so existing installs
   gap-fill the new titles' rows.

The rootmap-seeder test asserts an asset exists for every catalog
address, and the metadata-seeder test asserts a bundled metadata row +
artwork exist for every entry — a catalog/asset mismatch fails CI.
