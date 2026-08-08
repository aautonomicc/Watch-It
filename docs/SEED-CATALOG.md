# Built-in seed catalog

Since alpha.48 the app seeds a full public-domain catalog on first run —
10 movies plus two TV lists (Petticoat Junction, 21 season-1 episodes;
One Step Beyond, 17 episodes), 48 titles total — replacing the single
default movie (Night of the Living Dead) earlier alphas shipped. All
titles are verified public domain (see the uploader's per-title PD
research); the sources were downloaded from archive.org and uploaded to
Autonomi with plain `ant file upload` on 2026-08-07.

## Moving parts

| Piece | Where |
|---|---|
| Catalog (names + derived addresses) | `app/lib/services/seed_catalog.dart` (`kSeedLists`) |
| Library seeding / upgrade migration | `LibraryStore.ensureDefaults` (`defaults_seeded_v4` flag) |
| Bundled root maps (one per title) | `app/assets/rootmaps/<address>.map`, seeded into the local map store at startup by `rootmap_seeder.dart` |
| Bundled TMDB metadata + artwork | `app/assets/seed_metadata/metadata.json` + `posters/*.jpg` (~1.5MB), gap-filled into the metadata cache at startup by `metadata_seeder.dart` (`seed_metadata_v1` flag) — fresh keyless installs show posters/descriptions/episode names offline |
| Default movie constants | `kDefaultMovieAddress` / `kDefaultMovieName` in `metadata.dart` — now the catalog's NOTLD upload; the pre-alpha.48 5.68GB re-encode address moved to `kLegacyDefaultMovieAddresses` |

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
   order).
3. Bump the `defaults_seeded_vN` flag in `library_store.dart` only if
   existing installs should receive the changes.
4. Regenerate the bundled TMDB metadata + artwork (from `app/`, with the
   repo-root `.env` loaded):

   ```
   set -a; source ../.env; set +a
   dart run tool/harvest_seed_metadata.dart
   ```

   The tool resolves every `kSeedLists` entry with the app's own matcher
   (identical lookup keys, cache-row shape, and image file names to
   `metadata_service.dart`) and rewrites `app/assets/seed_metadata/`.
   It fails loudly on any unmatched entry. Bump `kSeedMetadataFlag` in
   `metadata_seeder.dart` (`seed_metadata_vN`) so existing installs
   gap-fill the new titles' rows.

The rootmap-seeder test asserts an asset exists for every catalog
address, and the metadata-seeder test asserts a bundled metadata row +
artwork exist for every entry — a catalog/asset mismatch fails CI.
