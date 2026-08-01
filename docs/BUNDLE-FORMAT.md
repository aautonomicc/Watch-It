# .watch-list bundle format — spec v2

**Status: implemented 2026-08-01, ships in v0.1.0-alpha.40.** Spec v2 is the
datamap-first container from docs/PLAN-datamap-privacy.md: the `.datamap`
files *are* the entries, and the public-XOR-address line grammar is gone.
v1 bundles (alpha.33–39 exports) still import — every legacy entry is
converted at the import border (see "v1 bundles" below). Implementation:
`app/lib/services/bundle.dart` (build/parse/convert/seed), the import/export
flows in `app/lib/screens/media_lists_screen.dart`, and the address
derivation in `native/watchit_core/src/verify.rs` + the `/datamap` endpoints
in `server.rs`.

## What it is

A `.watch-list` file is a **zip archive** that carries the `.datamap` files
of a media library *plus* everything needed to enjoy it instantly on another
device: TMDB metadata, poster images, optionally watch history (device
migration). A datamap grants full access to its content, so **share a bundle
as privately as the content deserves** — and note that publishing a bundle
at a public Autonomi address makes every title in it discoverable
(privacy is transitive).

The format's floor is deliberate: a hand-made
`zip "My Library.watch-list" *.datamap` — no W@tch involved, no `list.txt`
— is a valid bundle. Everything else is optional decoration.

## Container members

| Member | Required | Contents |
|---|---|---|
| `datamaps/<file name>.datamap` | no* | Raw ant-cli private-upload datamap files (bare msgpack root `DataMap`), byte-identical to what `ant file upload` wrote. The file name minus `.datamap` is the media file name, which feeds the NAMING.md parser / TMDB matcher. Members are **also accepted at the zip root** (the hand-made floor above); on a duplicate base name the `datamaps/` copy wins. |
| `list.txt` | no* | Optional list assignment. `ListName="..."` markers split lists; entry lines are **only** the member-file-name form — a line ending in `.datamap`, referencing a member. One member may be referenced from several lists (no duplication). Members no list references land in a default list named after the bundle file (a network-fetched bundle has no file name — the importer prompts, fallback "Imported"). |
| `metadata.json` | no | `metadata_cache` rows for the bundled entries, keyed by `lookupKey`, plus a top-level `attribution` field (see Attribution below). |
| `posters/` | no | The cached w342 poster JPGs for the bundled entries, deduped. |
| `library.json` | no | Library export only: per-list `{enabled, position}` so a fresh-device import restores home-screen order/visibility. |
| `history.json` | no | Watch-history rows `{address, positionMs, durationMs, completed, updatedAt}`. Keyed by derived address — deterministic from the map, so device-independent with no remapping. |

\* A bundle must carry at least one `.datamap` member or a `list.txt`
(a v1 bundle has only the latter); otherwise there is nothing to import.

Example `list.txt`:

```
ListName="TV Series"
Some Show S01E01 (2023) [1080p].mkv.datamap
Some Show S01E02 (2023) [1080p].mkv.datamap
ListName="Movies"
Some Movie (2024) [2160p].mp4.datamap
```

Partial bundles are always valid: whatever member is absent, import simply
doesn't seed it and the entry degrades gracefully (name-only cards, no
history). A `list.txt` line referencing a missing member is skipped with a
warning; import never fails on extras.

## Identity: the derived address

Every entry's identity is its **derived address**: `blake3` of the
`rmp_serde`-serialized, re-shrunk root data map — computed fully offline by
the embedded client (`POST /datamap`) at import. This is exactly the address
a *public* upload of the same file would have had, which is why:

- entries created from XOR addresses by pre-alpha.40 versions keep their
  identity unchanged after conversion;
- `history.json`, `metadata.json` and poster references need no migration;
- importing the same content twice (any route) dedupes naturally.

Nothing exists *on the network* at a private upload's derived address —
that is the point: the map never leaves the devices you share it with.

## Import

- **Routing sniffs bytes, not extensions.** Zip magic (`PK`) → bundle;
  a loose `.datamap` file imports as a single entry; anything else —
  including the removed plain-text list format — is refused with a pointer
  at bundles.
- **Members become entries first.** Each `.datamap` member is parsed
  (msgpack canonically; legacy ant-gui JSON accepted via the same first-byte
  sniff as ant-core's `read_datamap`), its address derived offline, and the
  map stored in the local map store. Unparseable members are skipped and
  counted. Maps arrive at import time *by construction* — there is no
  post-import resolve step and no cold first-play resolve.
- **Watch history is opt-out at import.** A bundle carrying `history.json`
  shows the "This bundle also contains" dialog (pre-checked checkbox,
  Cancel aborts the whole import). History merges
  newer-`updatedAt`-wins — an import never regresses local progress.
- **Metadata and posters always seed, gaps only.** Existing local rows and
  files win. Keyless installs get full posters/overviews/episode names with
  zero TMDB calls.
- **`library.json` applies only to lists the import creates.** Existing
  lists are never reordered, hidden, or re-enabled.
- **Member-name hygiene:** member names with path separators or `..`
  segments are dropped (nothing can escape the archive); export neutralizes
  separators in entry names and resolves name collisions with a short
  derived-address suffix before `.datamap`. Windows-illegal characters
  (`:` etc.) in media names would break extraction there — rarely an issue
  because the names come from real files.
- **Caps:** bundles are capped at 200 MB with per-member decompressed-size
  sanity limits (zip-bomb guard); a `.datamap` member is capped at 32 MB
  (a root map is ~100 bytes per chunk — NOTLD's 5.3 GB movie has a 108 KB
  map; a 100-title library ≈ 10 MB of maps).

### v1 bundles (alpha.33–39): border conversion

A v1 `list.txt` line is `<64-hex address> <file name>` — finding one marks
the bundle as v1. **No legacy entry type exists anymore**; each hex entry is
converted into a datamap entry at the import border:

1. A `rootmaps/<addr>.map` member (Full-bundle v1 exports always carried
   them) is imported under that address — offline and free. The map is
   verified in Rust (re-shrink → serialize → hash must equal the address)
   so a tampered bundle cannot poison the store.
2. No member (or verification failed) → **one** network
   `data_map_fetch` via `GET /resolve/{addr}` during the import, behind a
   progress dialog. An entry whose map cannot be obtained is **skipped with
   a warning** — it is never imported map-less.

Public XOR address == derived address, so a converted entry is
indistinguishable from a native v2 import. This conversion path (and the
`/resolve` network fetch behind it) is scheduled for removal after the
deprecation window — see ROADMAP.md.

## Export

- **One format: the bundle.** The plain `.txt` export is gone — a filename
  list without its maps is unplayable, and a hex list would recreate the
  public-address format this app no longer supports. The export dialog has
  one checkbox: **Include watch history** (default **OFF** — shared lists
  shouldn't leak viewing habits; a migration backup opts in explicitly),
  plus `library.json` for the whole-library export.
- **Members come straight from the local store** (`GET /datamap/{addr}`,
  ant-cli-compatible bytes). Maps are local by construction, so there is no
  pre-resolve pass; a rare "map missing" entry (interrupted upgrade
  migration) is skipped, counted, and left out of `list.txt` too.
- **Library export** includes disabled lists (it's a backup) in position
  order; metadata/posters are the union across all entries.
- **Delivery:** the save-file dialog everywhere (SAF on mobile — reliable
  at ~200 MB).

## Native plumbing

The embedded server's map endpoints:

- `POST /datamap` — import; body is raw `.datamap` bytes (msgpack, or
  legacy JSON sniffed by first byte `{`). Rejects shrunk child maps.
  Derives the address offline, stores the map, returns
  `{address, size, chunks}`.
- `GET /datamap/{addr}` — export; the stored root map as canonical msgpack
  (a byte-valid standalone `.datamap` file), 404 when not stored.
- `GET /rootmap/{addr}` / `PUT /rootmap/{addr}` — bincode
  (`DataMap::to_bytes`) variants kept for the NOTLD seeder asset and v1
  `rootmaps/` members; PUT verifies-then-stores.
- `GET /resolve/{addr}` — network map fetch + persist; **only** used by v1
  border conversion, the upgrade migration pass, and bundle-download by
  address. Scheduled for deletion (ROADMAP.md release 3).
- `GET /xor/{addr}` — the stream path; serves **locally stored maps only**
  and fast-fails 404 ("data map missing — re-import the list or bundle")
  instead of the old doomed 20–30 s network resolve.

## Attribution

TMDB terms require attribution wherever their data/images appear — owed by
the app today, independent of bundles:

- Settings → About/Metadata shows the standard TMDB notice + logo
  ("This product uses the TMDB API but is not endorsed or certified by TMDB").
- `metadata.json` carries a top-level `attribution` field with the same
  notice, so redistributed data keeps the credit.

## Explicitly not migrated

- The `downloads` table and downloaded files (absolute local paths;
  re-download on the new device).
- Anything in the map store beyond the bundled entries' own maps (a
  wholesale dump would leak every title ever played).
