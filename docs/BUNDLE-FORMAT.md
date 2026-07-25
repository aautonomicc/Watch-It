# .watch-list bundle format — spec v1

**Status: locked 2026-07-25, implemented 2026-07-25 (unreleased).** All six
open design decisions were closed with the user; this document is the
implementation reference. Implementation: `app/lib/services/bundle.dart`
(build/parse/seed), the import/export flows in
`app/lib/screens/media_lists_screen.dart`, and offline map verification in
`native/watchit_core/src/verify.rs` + the `/rootmap` endpoints in `server.rs`.

## What it is

A `.watch-list` file is a **zip archive** that carries a media list *plus*
everything needed to enjoy it instantly on another device: TMDB metadata,
poster images, optionally resolved root data maps (instant playback, no 20–30s
cold resolve) and optionally watch history (device migration).

The plain-text list format (see ARCHITECTURE.md open question 4) remains
unchanged and remains the interchange baseline — a `.watch-list` bundle
contains it verbatim as `list.txt`, so unzipping and importing the inner file
always works.

## Container members

| Member | Required | Contents |
|---|---|---|
| `list.txt` | ✅ | The current plain-text export format, byte-identical to a plain export. Multi-list files use the existing `ListName="..."` markers (this is how a whole-library export is one file). |
| `metadata.json` | no | `metadata_cache` rows for the bundled entries, keyed by `lookupKey`, plus a top-level `attribution` field (see Attribution below). |
| `posters/` | no | The cached w342 poster JPGs for the bundled entries, deduped. |
| `rootmaps/<addr>.map` | no | Resolved root data maps in `DataMap::to_bytes` format, **only** for the bundled entries' addresses (never a wholesale `root_maps.sqlite` dump — that would leak every title ever played). |
| `library.json` | no | Library export only: per-list `{enabled, position}` so a fresh-device import restores home-screen order/visibility. |
| `history.json` | no | Watch-history rows `{address, positionMs, durationMs, completed, updatedAt}`. Keyed by XOR content address, so device-independent — no remapping needed. |

Partial bundles are always valid: whatever a member is absent, import simply
doesn't seed it and the entry degrades gracefully (name-only cards, normal
network resolve, no history).

## Import

- **One Import button, no format question.** Import sniffs the first bytes:
  zip magic (`PK`) → bundle path, otherwise plain text. The `.watch-list`
  extension is cosmetic; routing never depends on it. The same sniff applies
  to lists fetched from an Autonomi address.
- **Seeding fills gaps only.** Existing local `metadata_cache` rows and poster
  files win; only missing ones are seeded (`fetchedAt` stamped at import).
  Keyless installs get full posters/overviews/episode names with zero TMDB
  calls.
- **Root maps are verified fully offline before storing.** For each
  `rootmaps/<addr>.map`: re-shrink the map
  (`self_encryption::shrink_data_map`, deterministic convergent encryption),
  serialize the top-level map with `rmp_serde` (exactly ant-core's
  `data_map_store` path at the pinned rev), hash, and require the content hash
  to equal the entry's XOR address. Mismatch → discard that map and fall back
  to a normal network resolve; import never fails and tampered maps cannot
  poison the cache. Verification costs ~ms per map.
- **History merges newer-`updatedAt`-wins** — an import never regresses local
  progress.
- **`library.json` applies only to lists the import creates.** Existing lists
  are never reordered, hidden, or re-enabled. Fresh-device migration hits an
  empty library, so full home state restores anyway.
- **Caps:** plain text stays 10 MB; bundles are capped at 200 MB with
  per-member decompressed-size sanity limits (zip-bomb guard).

## Export

- **One Export button** (per-list 3-dot menu *and* the library option), with a
  two-step dialog:
  1. Radio: **List only** (`.txt`, today's byte-identical plain export) vs
     **Full bundle** (`.watch-list`).
  2. Full bundle only — checkboxes: **Include watch history** (default
     **OFF**, for both per-list and library export: shared lists shouldn't
     leak viewing habits; a migration backup opts in explicitly) and
     **Include root maps (instant play on import)** (default **ON** — the
     addresses are already in `list.txt`, so no privacy delta).
- **Pre-resolve pass:** entries never browsed/played lack cached metadata and
  root maps (a cold root-map resolve is 22–31 s per movie-sized title), so a
  bundle export runs a cancellable DataMapPrefetcher-style progress pass
  (spinner, `File X of N`, Cancel). **Cancel keeps the partial bundle** —
  missing members degrade gracefully on import.
- **Library export** = `serializeMediaList` over all lists (including
  disabled ones — it's a backup) in position order, concatenated into one
  `list.txt`; metadata/posters/maps are the union across all entries;
  `library.json` added.
- **Delivery:** desktop uses the save-file dialog for both formats. Mobile
  uses the SAF save-file dialog (`file_selector.getSaveLocation`) for
  bundles (reliable at ~200 MB) and keeps the share sheet for plain `.txt`.

## Native plumbing

`root_maps.sqlite` is Rust-owned, so the embedded server gains two endpoints:

- `GET /rootmap/{addr}` — export; returns the stored map, 404 if unresolved.
- `PUT /rootmap/{addr}` — import; runs the offline verification above **in
  Rust** (verify-then-store), 4xx on mismatch.

New Flutter dependency: the pure-Dart `archive` package for zip read/write.

## Attribution

TMDB terms require attribution wherever their data/images appear — owed by the
app today, independent of bundles:

- Settings → About/Metadata shows the standard TMDB notice + logo
  ("This product uses the TMDB API but is not endorsed or certified by TMDB").
- `metadata.json` carries a top-level `attribution` field with the same
  notice, so redistributed data keeps the credit.

## Explicitly not migrated

- The `downloads` table and downloaded files (absolute local paths;
  re-download on the new device).
- Anything in `root_maps.sqlite` beyond the bundled entries' own maps.

## Estimate breakdown

- ~1 day — base bundle: zip read/write + `archive` dep, export pre-resolve
  pass with progress UI, two-step export dialog, sniff + seed import, cap
  raise, round-trip test into a clean keyless profile.
- ~0.5 day — `library.json` + `history.json`.
- ~0.5 day — root maps: the two Rust endpoints + offline
  shrink/serialize/hash verification.
