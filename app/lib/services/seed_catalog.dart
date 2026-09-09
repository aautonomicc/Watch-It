// GENERATED from the public-domain uploads in ~/Public domain (see
// docs/SEED-CATALOG.md) — addresses derived by POST /datamap from each
// upload's ant-cli .datamap file; regenerate rather than hand-edit.

import 'metadata.dart';

/// One entry of the built-in seed catalog: the media file name as stored
/// on the network (feeds the NAMING.md parser / TMDB matcher) and its
/// derived address, whose root map ships as a bundled asset
/// (assets/rootmaps/<address>.map), plus the upload's exact size and
/// probed video format (ffprobe of the source files — NOT the name's
/// quality tag, which is wrong on some archive.org sources: the 480p
/// NOTLD upload says `[1080p]` but is really 480p).
class SeedEntry {
  const SeedEntry(
    this.name,
    this.address, {
    required this.sizeBytes,
    required this.videoInfo,
  });

  final String name;
  final String address;

  /// Exact size of the uploaded file in bytes.
  final int sizeBytes;

  /// `480p H.264` — resolution ladder label + codec of the upload.
  final String videoInfo;
}

/// A list the seed catalog creates (or merges into, matched by [id]) on
/// first run — see [LibraryStore.ensureDefaults].
class SeedList {
  const SeedList(
      {required this.id, required this.title, required this.entries});
  final String id;
  final String title;
  final List<SeedEntry> entries;
}

/// The built-in catalog seeded on first run: Big Buck Bunny (2008) in
/// three quality tiers — the official Blender "sunflower" 1080p release
/// uploaded as-is plus the project's own 720p/480p encodes (the app's
/// exact Publish tier settings), uploaded 2026-09-09. Replaces the two
/// NOTLD uploads seeded alpha.51–.92 (see docs/SEED-CATALOG.md — the
/// NOTLD uploads remain live on the network; existing installs keep
/// whatever they already seeded). BBB is CC-BY 3.0 Blender Foundation,
/// not public domain: it is seeded ONLY (never exported to
/// catalog/*.watch-list) and its seeded description carries the
/// attribution. The Movies list reuses the pre-v4 default list id so
/// upgraded installs merge into their existing list.
const kSeedLists = <SeedList>[
  SeedList(id: 'default-test-movies', title: 'Movies', entries: [
    SeedEntry(
      kSeedMovie1080Name,
      kSeedMovie1080Address,
      sizeBytes: 276134947,
      videoInfo: '1080p H.264',
    ),
    SeedEntry(
      kSeedMovie720Name,
      kSeedMovie720Address,
      sizeBytes: 205139247,
      videoInfo: '720p H.264',
    ),
    SeedEntry(
      kSeedMovie480Name,
      kSeedMovie480Address,
      sizeBytes: 86052285,
      videoInfo: '480p H.264',
    ),
  ]),
];

/// Catalog entries added AFTER the v4 seed shipped (v0.1.0-alpha.48).
/// Installs that already ran the one-time v4 seed never re-enter the
/// full merge, so [LibraryStore.ensureSeedAdditions] delivers exactly
/// these addresses to them behind its own one-time flag. Fresh (and
/// pre-v4) installs get them through the normal [kSeedLists] merge.
/// Empty since the BBB swap: existing installs deliberately get nothing
/// (they keep their seeded NOTLD; BBB is fresh-installs-only, and every
/// addition address must be a [kSeedLists] member).
const kSeedAdditionAddresses = <String>[];
