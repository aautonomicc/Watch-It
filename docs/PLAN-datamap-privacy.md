# Plan: datamap-first entries — remove public XOR addresses entirely

**Status: RELEASE 1 IMPLEMENTED (2026-08-01), ships in v0.1.0-alpha.40.**
The three-release schedule (1: whole feature · 2: deprecation window ·
3: delete `data_map_fetch` + `/resolve` network path) is tracked in
ROADMAP.md; the implemented container spec is BUNDLE-FORMAT.md (spec v2).
Implementation notes vs this plan: the derived-address helper became
`POST /datamap` / `GET /datamap/{addr}` HTTP endpoints (msgpack + legacy-
JSON sniff, mirroring ant-core `read_datamap`); the migration pass surfaces
as a cancellable snackbar; bundle-download-by-address now pre-resolves via
`GET /resolve` because `/xor` is local-map-only — that flow is the release-3
open question. The "confirm derivation against a real private upload" item
remains open (verify.rs' shrink-then-hash equals the public-upload address
by construction and by test; an on-network ant-cli cross-check is still
worth one run before release 3 freezes anything).
**Rev 3 (2026-08-01): user decision — XOR support is REMOVED COMPLETELY, not
demoted to a Legacy path. No XOR entry dialog, no `<64-hex>` list lines, no
`source` flag, no beta deferral.**

## Why

A *public* Autonomi upload stores the file's serialized root `DataMap` as a
**plaintext chunk** on the network (ant-core `file.rs`: public visibility
bundles `rmp_serde::to_vec(&data_map)` as an extra chunk; its blake3 hash is
the shareable XOR address). Any node operator can trawl the chunks they store
for bytes that deserialize as a valid `DataMap` and then download the entire
file — the data chunks themselves are encrypted, but every key is in the map.
**Public content is therefore discoverable and readable by third parties who
were never given the address.**

A *private* upload stores the exact same encrypted data chunks but never puts
the datamap on the network — it stays with the uploader (ant-cli writes
`<name>.datamap`, msgpack `DataMap`, see ant-core `datamap_file.rs`). Without
the map, the chunks are unlinkable noise. Sharing the `.datamap` file grants
access; nobody else can find the content. Bonus: private upload is slightly
**cheaper** (one fewer chunk to pay for).

Today Watch-It entries are `{64-hex XOR address, name}`, which only works
with public uploads — so the app structurally nudges users into uploading
their media libraries publicly. This plan makes the datamap the **only**
content reference: accepting XOR addresses at all would keep encouraging
insecure public library uploads, so the entry type is removed, not demoted.

### Honest scope of the privacy gain (say this in the docs/UI)

- A datamap **is** full access. Anyone who obtains the list obtains the
  content. The gain over XOR is *non-discoverability by third parties* (node
  operators, chunk crawlers), not confidentiality against list recipients.
- **Privacy is transitive.** Publishing a list-of-datamaps at a public XOR
  address re-leaks every title in it. List sharing must itself travel
  privately (file, or private upload shared by *its own* datamap). Any future
  publish/subscribe feature must default private.
- Already-public uploads are immutable and cannot be retracted. Going
  datamap-first protects *future* uploads only.
- Removing XOR entries does **not** strand genuinely public material: a
  public file's datamap is itself fetchable, so a curator fetches it once,
  saves it as a `.datamap` file, and distributes a `.watch-list` bundle. The
  NOTLD demo and any archive.org PD catalog work this way — the *bundle*
  carries the map; consumers never see or type an address.

## Why it's cheap: the core is already datamap-native

- Streaming (`stream_full`/`stream_range`), prefetch, downloads, and the
  cache all take a `DataMap` — the XOR address was used **only** to fetch the
  root map (`data_map_fetch`) and as the cache key.
- `verify.rs` already derives the address *offline* from a root map:
  `blake3(rmp_serde(shrink_data_map(root)))`. For a public upload this
  derived address **is** the file's XOR address (that's what verify.rs checks
  fetched maps against today). So every entry keeps a 64-hex **derived
  address** computed from its map, and every addr-keyed subsystem (mapstore,
  chunk cache, `/xor/<addr>` route, downloads PK, watch history, bundle
  `metadata.json`/`history.json`) keeps working **unchanged** — including for
  entries that were created from XOR addresses in old versions (same addr).
- ant-cli's `.datamap` wire format (bare msgpack `DataMap`, root map — the
  file-upload path does not shrink) is byte-compatible with what
  `import_root_map` / bundle members already consume. An ant-cli private
  upload's `.datamap` file can be imported as-is.

## Design

**Entry model.** One entry kind: `{derived address, name}` with the root map
**required** in the local mapstore. No `source` field — there is nothing to
distinguish. `address` stays the PK/identity everywhere. An entry whose map
is missing (see Migration) is unplayable and shows a "map missing —
re-import" state; it is never resolved from the network.

**Import.** Exactly two user-facing sources:
1. *.datamap file(s)* — new picker (multi-select). Name = filename minus
   `.datamap` (ant-cli preserves the original name: `Movie (2024).mkv.datamap`
   → feeds the existing TMDB matcher untouched). Map → `import_root_map`
   under the derived address.
2. *.watch-list bundle* — the canonical share format; container spec v2
   below.

**Removed import surfaces:** the XOR-address dialog, plain-`.txt` list
import, and the `<64-hex> <name>` line grammar everywhere. v1 bundles are
handled by border conversion (below), not by keeping the entry type.

### Bundle container spec v2 (revised 2026-08-01, not frozen)

A `.watch-list` stays a zip. Members:

- `datamaps/<original filename>.datamap` — raw ant-cli private-upload
  datamap files, byte-identical to what ant-cli wrote. Filename minus
  `.datamap` = the media filename, which feeds the NAMING.md parser / TMDB
  matcher. Size is fine: a movie root map ≈ 100 KB (NOTLD 108 KB / 1357
  chunks); a 100-title library ≈ 10 MB, well under the 200 MB cap. Import
  also accepts `.datamap` members at the zip **root** so a hand-made
  `zip "My Library.watch-list" *.datamap` (no Watch-It, no list.txt) is a
  valid bundle — this is the format's floor and a deliberate feature.
- `list.txt` — **optional**. v2 grammar: `ListName="..."` markers split
  lists; entry lines are **only** the filename form — a line ending in
  `.datamap`, referencing a member:

  ```
  ListName="TV Series"
  Some Show S01E01 (2023) [1080p].mkv.datamap
  Some Show S01E02 (2023) [1080p].mkv.datamap
  ListName="Movies"
  Some Movie (2024) [2160p].mp4.datamap
  ```

  One member may be referenced from several lists (no duplication). The v1
  `<64-hex> <name>` line form is **dropped from v2** — a v2 exporter never
  writes it, and a hex line in a bundle marks it as v1 for the converter.
- `rootmaps/<addr>.map` — **gone from v2** (was cache-warming for XOR
  entries). Read only when converting v1 bundles.
- `metadata.json`, `posters/`, `library.json`, `history.json` — unchanged
  (keyed by derived addresses; history stays device-independent because
  derivation is deterministic).

Edge rules (define now, they bite later):

- Datamap member referenced by no list.txt (or no list.txt at all) →
  default list named from the bundle filename minus `.watch-list`; a bundle
  fetched from an Autonomi address has no filename → prompt (fallback
  "Imported").
- list.txt line referencing a missing member → skip with a warning; import
  never fails.
- Export name collisions (two entries, identical filename) → short
  derived-addr suffix before `.datamap` (same trick as download filenames).
- Import sanitizes member names: reject absolute paths and `..` segments;
  existing zip-bomb / per-member size caps apply.
- Filenames are the identity carrier, so NAMING.md conventions apply
  pre-upload; note in docs that `:` etc. in names breaks extraction on
  Windows (rarely an issue — the names come from real files).

### v1 bundle border conversion (import-time, one release cycle)

Old exports exist (alpha.33+ testers). A v1 bundle (hex lines in list.txt)
imports by **converting each hex entry to a datamap entry at the border**:

1. `rootmaps/<addr>.map` member present → import that map under the addr
   (offline, free — Full-bundle exports always included these).
2. No member → one network `data_map_fetch(addr)` **during import only**
   (progress dialog, per-entry skip-on-failure + warning, never fails the
   import). This is the *only* surviving use of the network map fetch, it
   creates a normal datamap entry, and it is scheduled for deletion (see
   Deprecation window).

No XOR entry is ever created; after import the bundle's content is
indistinguishable from a native v2 import.

### Migration of existing installs (drift schema bump)

A public file's XOR address == its derived address, so **entry rows don't
change** — the entry just needs its map in the local mapstore:

- Map already stored (played once, prefetched at import, or the NOTLD
  bundled asset) → nothing to do. This covers most real libraries.
- Map missing → one-time background resolve pass on first launch after
  upgrade ("Upgrading library — fetching data maps, X of N", cancellable,
  retried next launch). Entries still unresolved after the pass show the
  "map missing" state with a Retry action.
- Downloads, watch states, history, metadata cache, posters: all keyed by
  address → untouched.

The NOTLD demo needs **zero changes**: its root map already ships as a
bundled asset seeded via PUT /rootmap (alpha.38), which under this plan
simply *is* its datamap. `ensureDefaults` keeps seeding the same address.

### Deprecation window for the network map fetch

`data_map_fetch` survives only in (a) v1 border conversion and (b) the
upgrade migration pass — both one-shot, import/startup-scoped, never on the
play path. Target: delete both (and `GET /resolve`'s network path) after one
or two releases, once testers' libraries and bundles have rolled over. Until
then `/resolve` stays for the migration pass but is dropped from all UI
flows (DataMapPrefetcher and the post-import "Prefetch data maps?" dialog
are **deleted** — maps now arrive at import time by construction, which also
kills the 20-31s cold-resolve UX problem for good).

**Verification.** Same `verify_root_map` on every import — it *is* the
identity check (recompute derived addr from the map). Tampered maps still
can't poison the cache.

**Playback/downloads.** Zero streaming changes. The `/xor/<addr>` route and
downloads keep working off the mapstore. One Rust guard: a missing map
fails fast with "data map missing — re-import the list/bundle" instead of
falling through to `data_map_fetch` (today that would be a slow doomed
timeout; after the deprecation window the fetch path won't even exist).

**Export.** Full bundle (spec v2) or loose `.datamap` files. The
"List only (.txt)" export is **removed** — a filename line without its
member is useless, and a hex list would recreate the format we're killing.

**UI.**
- Add-entry: "Add .datamap files" + "Import .watch-list bundle". The XOR
  dialog is deleted, along with the `xorAddress` validators and the "public"
  badge concept (nothing left to badge).
- Settings/docs: uploader workflow = `ant file upload <file>` (private is
  the default; **no `-p`**) → keep the printed `.datamap` → import → share
  as a `.watch-list` bundle. NAMING.md conventions apply to the filename
  before upload so metadata still resolves. Include the transitive-privacy
  warning and the "public uploads are discoverable by anyone" rationale.
- Curator workflow for genuinely-public material (PD pipeline): fetch the
  public file's datamap once (small helper or ant-cli), bundle it. Users
  never handle addresses.

## Work plan (≈ 3–4 days + release)

1. **Rust (~1 day):** derived-address helper over FFI/HTTP (reuse
   verify.rs); missing-map fast-fail on the stream path; keep
   `data_map_fetch` only behind the import/migration entry points (feature
   note for its later deletion). Tests beside existing verify/server ones.
2. **Dart (~2 days):** `.datamap` picker + import flow; bundle spec v2
   build/parse (datamaps/ members + optional filename-line list.txt); v1
   border conversion; upgrade migration pass + "map missing" entry state
   (schema bump); delete XOR dialog, .txt import/export, DataMapPrefetcher
   + prefetch dialog; tests (incl. v1-bundle and migration fixtures).
3. **Docs (~½ day):** BUNDLE-FORMAT.md spec v2 (v1 marked
   convert-on-import), ARCHITECTURE.md entry model rewrite, README/VISION
   privacy note, uploader + curator how-tos.

## Open items / risks

- **Confirm derivation against a real private upload** (small file,
  `ant file upload`, check `verify_root_map(derived_addr, map)` accepts the
  `.datamap` bytes) before freezing spec v2 — verify.rs mirrors
  `data_map_store` (shrink-then-hash); the file-upload public path serializes
  *without* shrinking, so the derived addr for small maps must be validated
  on-network once. (For maps ≤1 chunk, shrink is a no-op, so they should
  agree — still: test it.)
- Legacy JSON `.datamap` files (old ant-gui) — `read_datamap` sniffing exists
  in ant-core; decide whether Watch-It accepts them too (probably yes, free).
- Decide how long the v1-conversion + migration network fetch lives (one
  release? two?) before `data_map_fetch` is deleted from the crate.
- Users offline at first post-upgrade launch with never-played entries: the
  migration pass retries next launch, but a permanently-offline device with
  such entries can only recover via re-import — acceptable? (Entries that
  were ever played are already covered by the mapstore.)
- Watch-history/bundle `history.json` stays keyed by (derived) address —
  device-independent because the derivation is deterministic. No migration.
