# Plan: drop v1 address-keyed history.json rows (next release after alpha.45)

Planned 2026-08-04. **Not implemented yet** — lands in the first release
after v0.1.0-alpha.45 ships (alpha.46 unless renumbered).

## Context

Alpha.45's address hygiene (271f2cd) made history.json **spec v2**: rows
are keyed by `.datamap` member name (`{member, positionMs, ...}`,
`version: 2`) so the file never carries a bare derived address. Every
exporter before alpha.45 (alpha.33–44) wrote v1 rows keyed by address
(`{address, ...}`), and alpha.45 kept accepting those read-side so old
bundles keep their history.

User decision (2026-08-04): the test group is small — backwards
compatibility is not required, remove it on the next build.

## Precondition

v0.1.0-alpha.45 is released and testers have re-exported any bundle
whose watch history they care about (any alpha.45+ export writes v2
rows). Entries/metadata/posters in old bundles are unaffected either
way — only history rows are at stake.

## Changes (all in `app/lib/services/bundle.dart` unless noted)

- Delete the v1 parse branch in the `history.json` case
  (~line 530: the `row['address']` fallback) — rows without a
  `member` are silently skipped.
- Delete `ParsedBundle.history` (the legacy address-keyed
  `Map<String, WatchState>`, ~line 151) and its constructor param;
  `historyCount` becomes `historyByMember.length`.
- Delete the seed-time consumer (~line 835,
  `...bundle.history.values` in the merge).
- `bundle_test.dart` ~line 393 ("v1 address rows still accepted"):
  invert — assert address-keyed rows are ignored and import still
  succeeds.
- `docs/BUNDLE-FORMAT.md`: history.json table row — replace
  "Legacy `{address, ...}` rows … accepted read-side" with "rows
  without `member` are ignored (v1 acceptance removed)"; also touch
  the Identity-section bullet claiming legacy history rows "need no
  migration".

Out of scope: the v1 *bundle* paths (hex `list.txt` lines,
`rootmaps/`) were already removed in alpha.41 — nothing to do there.

## Effect on old bundles

An alpha.33–44 export still imports fine (entries, metadata, posters);
its watch-history rows are silently dropped. Fix is a one-time
re-export on alpha.45+.

Estimate: ~30–60 min including tests.
