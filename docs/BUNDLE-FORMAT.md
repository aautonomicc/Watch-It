# .watch-list bundle format — spec v2

**Status: implemented 2026-08-01, ships in v0.1.0-alpha.40.** Spec v2 is the
datamap-first container from docs/PLAN-datamap-privacy.md: the `.datamap`
files *are* the entries, and the public-XOR-address line grammar is gone.
v1 bundles (alpha.33–39 exports) no longer import as of v0.1.0-alpha.41 —
see "v1 bundles" below. Implementation:
`app/lib/services/bundle.dart` (build/parse/seed), the import/export
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
| `list.txt` | no* | Optional list assignment. `ListName="..."` markers split lists; entry lines are **only** the member-file-name form — a line ending in `.datamap`, referencing a member. One member may be referenced from several lists (no duplication). Members no list references land in a default list named after the bundle file (fallback "Imported"). |
| `metadata.json` | no | `metadata_cache` rows for the bundled entries, keyed by `lookupKey`, plus a top-level `attribution` field (see Attribution below). Since alpha.57 rows carry a `userEdited` flag (the Edit details feature): user-entered titles/descriptions/artwork export like any other row and gap-fill on import, so recipients see them offline; on the importing device a `userEdited` row is never overwritten by a later TMDB match. |
| `posters/` | no | The cached w342 poster JPGs for the bundled entries, deduped. Channel manifests may add `posters/channel_avatar_<sha8>.img` — the channel's avatar, content-hash-named so an unchanged avatar keeps its name across updates (the channel delta fetch skips it) and a changed one is a new member; named by `channel.json`'s optional `avatar` key. To plain-bundle importers it is just an unused small file in the posters dir. |
| `library.json` | no | Library export only: per-list `{enabled, position}` so a fresh-device import restores home-screen order/visibility. |
| `history.json` | no | Watch-history rows `{member, positionMs, durationMs, completed, updatedAt}` (`version: 2`). Keyed by `.datamap` member name, exactly like `list.txt` — the importer resolves each member to its derived address, so the file never carries a bare address. An entry whose map is missing from the exporter's store has no member and its history stays out. Rows without a `member` — including the legacy `{address, ...}` rows alpha.33–44 exporters wrote — are ignored (v1 acceptance removed after alpha.45, [PLAN-drop-v1-history-rows.md](PLAN-drop-v1-history-rows.md)); re-export on alpha.45+ to restore dropped history. |

\* A bundle must carry at least one `.datamap` member or a `list.txt`;
otherwise there is nothing to import.

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
- `metadata.json` and poster references need no migration (legacy
  address-keyed `history.json` rows did — their read-side acceptance was
  removed after alpha.45; re-export to carry history in spec v2);
- importing the same content twice (any route) dedupes naturally.

Nothing exists *on the network* at a private upload's derived address —
that is the point: the map never leaves the devices you share it with.

## Import

- **One picker, routing sniffs bytes and names.** Since the combined
  importer (post-alpha.43) "Add to library" opens a single multi-select
  picker; per picked file: zip magic (`PK`) → bundle;
  `<name>.watch-list.datamap` → the map of a bundle *stored on the
  network* (fetched over `GET /xor/{addr}`, then imported like a local
  bundle — see below); any other `.datamap` file imports as an entry;
  anything else — including the removed plain-text list format — is
  skipped with a note (or refused with a pointer at bundles when it was
  the only pick). Mixed picks work; loose datamaps import as one batch.
- **Network-stored bundles travel as their datamap.** Upload a bundle
  privately (`ant file upload "My Library.watch-list"`) and share the
  resulting `My Library.watch-list.datamap` file — ant-cli names the map
  after the uploaded file, so the double suffix survives on its own and
  is the routing signal (a renamed map falls through to the loose-entry
  route). Import stores the bundle's map, refuses anything whose declared
  size exceeds the 200 MB bundle cap *before* downloading, streams the
  bundle through the embedded client behind a progress dialog with
  Cancel, and then runs the normal bundle import under the bundle's file
  name. This shares only a ~KB map file instead of the whole bundle — and
  unlike the deleted bundle-download-by-public-address (alpha.41), no
  public address is ever typed or published; privacy stays transitive
  (whoever holds the bundle's map can fetch every map inside it).
- **Members become entries first.** Each `.datamap` member is parsed
  (msgpack canonically; legacy ant-gui JSON accepted via the same first-byte
  sniff as ant-core's `read_datamap`), its address derived offline, and the
  map stored in the local map store. Unparseable members are skipped and
  counted. Maps arrive at import time *by construction* — there is no
  post-import resolve step and no cold first-play resolve.
- **Watch history is opt-out at import.** A bundle carrying `history.json`
  shows the "This bundle also contains" dialog (pre-checked checkbox,
  Cancel aborts the whole import). Member-keyed rows resolve to the
  address the member's import derived; rows naming a member that didn't
  import are dropped. History merges
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

### v1 bundles (alpha.33–39): no longer import

A v1 `list.txt` line is `<64-hex address> <file name>`. The border
conversion that turned these into datamap entries needed a network map
fetch, which was deleted in v0.1.0-alpha.41 (release 3 of the datamap-first
plan, after the deprecation window closed). Today: hex lines are **skipped**
(counted with the other invalid lines), `rootmaps/` members are ignored,
and a bundle containing nothing else is refused with "re-export it as a
bundle from Watch-It 0.1.0-alpha.40 or later" — an alpha.40+ install whose
library came from that v1 bundle exports a fully self-contained v2 bundle.

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
  (`DataMap::to_bytes`) variants kept for the NOTLD seeder asset; PUT
  verifies-then-stores.
- `GET /resolve/{addr}` — `{size, chunks}` of a **locally stored** map
  (404 otherwise); the download manager's size pre-fill. The network fetch
  this endpoint once performed was deleted in alpha.41.
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
