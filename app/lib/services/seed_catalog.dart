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

/// The built-in catalog seeded on first run: the two Night of the Living
/// Dead uploads (verified public-domain, uploaded 2026-08-07 from an
/// archive.org source + the project's own 1080p re-encode). Trimmed from
/// the full 48-title PD catalog shipped in alpha.48–.50 (see
/// docs/SEED-CATALOG.md — the old uploads remain live on the network;
/// existing installs keep whatever they already seeded). The Movies list
/// reuses the pre-v4 default list id so upgraded installs merge into
/// their existing list.
const kSeedLists = <SeedList>[
  SeedList(id: 'default-test-movies', title: 'Movies', entries: [
    SeedEntry(
      kDefaultMovieName,
      kDefaultMovieAddress,
      sizeBytes: 597585042,
      videoInfo: '480p H.264',
    ),
    // Second upload of the same film under the identical network file
    // name: the genuine-1080p re-encode that was the default movie up to
    // alpha.47. Size/format info is what tells the two apart in the UI.
    SeedEntry(
      kDefaultMovieName,
      kDefaultMovie1080Address,
      sizeBytes: 5682464056,
      videoInfo: '1080p H.264',
    ),
  ]),
];

/// Catalog entries added AFTER the v4 seed shipped (v0.1.0-alpha.48).
/// Installs that already ran the one-time v4 seed never re-enter the
/// full merge, so [LibraryStore.ensureSeedAdditions] delivers exactly
/// these addresses to them behind its own one-time flag. Fresh (and
/// pre-v4) installs get them through the normal [kSeedLists] merge.
const kSeedAdditionAddresses = [
  kDefaultMovie1080Address,
];
