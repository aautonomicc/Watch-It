# Plan: trim the seed catalog to the two NOTLD versions (alpha.51)

Status: IMPLEMENTED 2026-08-09 (option A). The user resolved §2 on
2026-08-09: removal only applies to future installs and factory resets
— existing installs keep everything they seeded (option A, no removal
migration). Option B's `ensureSeedRemovals` was NOT built; it can be
added later if removal-everywhere is ever wanted.

## 1. Goal

Next release ships a seed catalog containing ONLY the two Night of the
Living Dead versions (480p `442180e7…` = current default movie, and the
1080p re-encode `66cacd06…`). The other 47 entries go: 9 movies, the
Petticoat Junction list (21 eps), and the One Step Beyond list (17 eps).
The same-title version picker keeps working — one wall card, "2
versions", dropdown on the detail page.

Note: this removes titles from the **app**, not the network. Autonomi
data is permanent; the 47 uploads stay live and playable for anyone who
holds their `.datamap` files. We only stop bundling their addresses,
root maps, and metadata.

## 2. DECISION NEEDED: existing installs

Fresh installs trivially get the trimmed catalog. But alpha.48–.50
installs already seeded all 48 titles, and nothing in the code removes
entries today. Options:

- **A — catalog trim only.** Existing installs keep everything they
  have; only fresh installs (and factory resets) see just NOTLD. Zero
  user-data risk, no new mechanism.
- **B — removal migration (recommended if "remove" means remove
  everywhere).** New one-time `LibraryStore.ensureSeedRemovals` behind
  `seed_removals_v1`, driven by a `kSeedRemovedAddresses` const (the 47
  dropped addresses): deletes matching entries from every list, then
  deletes the two TV seed lists if left empty. Called from both
  `ensureDefaults` branches like `ensureSeedAdditions`. Caveats:
  - Matching is by address, so a user's *manual* re-import of one of
    these exact uploads is also removed (unavoidable — same address).
  - Do NOT touch downloads, watch states, cached metadata/posters, or
    stored root maps in `root_maps.sqlite` — user artifacts / harmless
    orphans; a later re-import picks them right back up.

## 3. Code changes

1. `app/lib/services/seed_catalog.dart` — `kSeedLists` shrinks to the
   single Movies list (`default-test-movies`) with the two NOTLD
   entries. `kSeedAdditionAddresses` stays `[kDefaultMovie1080Address]`
   (still a catalog member, so the membership-invariant test holds).
   If option B: add `kSeedRemovedAddresses` here (47 addresses — take
   them from the current file before editing, or from git).
2. `app/lib/services/library_store.dart` — option B only:
   `ensureSeedRemovals` + `seed_removals_v1` flag, wired into both
   `ensureDefaults` branches. Do NOT bump `defaults_seeded_v4` (would
   re-add NOTLD to users who deleted it); `seed_fileinfo_v1` /
   `seed_metadata_v1` need no bump (gap-fills only add, nothing new to
   deliver).
3. `app/lib/services/metadata.dart` — no change (only NOTLD constants
   live there; `kLegacyDefaultMovieAddresses` untouched).

## 4. Assets

- Delete 47 of the 49 `app/assets/rootmaps/*.map`; keep
  `442180e7….map` and `66cacd06….map` (~552K → ~120K).
- Regenerate `app/assets/seed_metadata/` with
  `set -a; source ../.env; set +a; dart run tool/harvest_seed_metadata.dart`
  (from `app/`) — emits just the shared NOTLD row + poster
  (~1.5M → ~tens of KB). The tool iterates `kSeedLists`, so run it
  AFTER the catalog edit.
- Net bundle shrink ≈ 1.9MB in both APK and AppImage.

## 5. Tests

- `test/library_test.dart` — repin seeding tests that expect three
  lists / 48 entries to one list / 2 entries. Keep the additions +
  pre-v4 migration tests (still valid). Option B: new group for
  `ensureSeedRemovals` (removes by address across lists, deletes
  emptied seed lists, leaves non-seed entries and a non-empty Movies
  list alone, one-time flag).
- `test/file_info_test.dart` — the truth-beats-name pin covers NOTLD +
  Lady Vanishes; Lady Vanishes leaves the catalog, keep the NOTLD half.
- `test/rootmap_seeder_test.dart` + `test/metadata_seeder_test.dart`
  coverage tests iterate `kSeedLists` — pass automatically once assets
  are regenerated; they FAIL the build if the asset trim is forgotten.
- `test/version_grouping_test.dart` / picker tests — unaffected.

## 6. Docs + release

- Rewrite `docs/SEED-CATALOG.md` (2 entries; note the alpha.48–.50
  full-catalog history and that the old uploads remain on the network).
- README "Bundled catalog" section + ROADMAP status.
- alpha.51 also carries the already-unreleased loose-name version-fold
  fix (74f2b0b). Smoke expectations change: clean-HOME `/health`
  `stored_maps=2`; wall shows ONE row (Movies) with ONE NOTLD card
  reading "2 versions"; TV rows gone. Upgrade smoke (option B): run the
  AppImage against a copied alpha.50 library dir and check the 47
  entries + two TV lists disappear while downloads/watch state survive.
