import '../models/media_list.dart';

/// Display metadata for a media entry: artwork, description, year.
///
/// Phase 0 stand-in for the on-device TMDB matcher (ARCHITECTURE.md):
/// a small bundled catalog covers the default test movie; everything else
/// falls back to a parsed file name with no artwork. Live TMDB matching
/// needs an API key and lands with the SQLite cache.
class MediaMetadata {
  const MediaMetadata({
    required this.title,
    this.year,
    this.overview,
    this.posterAsset,
  });

  final String title;
  final int? year;
  final String? overview;

  /// Bundled asset path (e.g. `assets/posters/notld_1968.jpg`), if any.
  final String? posterAsset;
}

/// XOR address of the built-in test movie seeded on first run.
/// H.264 8-bit 1080p re-encode — plays with hardware decoding on phones and
/// older desktops, unlike the AV1 10-bit original it replaces.
const kDefaultMovieAddress =
    '66cacd0604b01b2c2f1da1c1c3c05609d3b4cc448cff3b6cdd868e6b7eebcb13';

/// File name of the built-in test movie as stored on the network.
/// Follows the Plex/Jellyfin naming convention
/// (`Title (Year) {imdb-ttXXXXXXX} - [quality].ext`) — see docs/NAMING.md.
const kDefaultMovieName =
    'Night of the Living Dead (1968) {imdb-tt0063350} - [1080p].mp4';

/// Stale addresses the default movie was seeded under in older releases;
/// migrated to [kDefaultMovieAddress] by [LibraryStore.ensureDefaults].
/// In order: up to v0.1.0-alpha.4 (dead upload), and the AV1 10-bit webm
/// used up to v0.1.0-alpha.15.
const kLegacyDefaultMovieAddresses = [
  'ac855e1e8b17cb4ba0884a4e7025bd5f51d95ed69e4fa15ca37290496a400ea0',
  'cebd7965268b61d98907378670f13e55a2694064d0eed7ef4be9c19eaaf03988',
];

const _notld = MediaMetadata(
  title: 'Night of the Living Dead',
  year: 1968,
  overview:
      'Seven strangers barricade themselves inside a rural Pennsylvania '
      'farmhouse as the recently dead rise to feed on the living. George A. '
      'Romero’s landmark 1968 independent film invented the modern '
      'zombie genre and is now in the public domain.',
  posterAsset: 'assets/posters/notld_1968.jpg',
);

/// Bundled catalog, keyed by XOR address.
const _byAddress = <String, MediaMetadata>{
  kDefaultMovieAddress: _notld,
};

/// Look up metadata for [entry]. Always returns something displayable:
/// catalog hit by address, else a parsed title/year with no artwork.
MediaMetadata metadataFor(MediaEntry entry) {
  final addr = entry.address.toLowerCase().replaceFirst('0x', '');
  final hit = _byAddress[addr];
  if (hit != null) return hit;
  final parsed = parseMediaName(entry.name);
  return MediaMetadata(title: parsed.title, year: parsed.year);
}

class ParsedName {
  const ParsedName(this.title, this.year, {this.imdbId});

  final String title;
  final int? year;

  /// IMDb id (`tt0063350`) from a Plex/Jellyfin id tag, if present.
  /// Lets the TMDB matcher do an exact `/find` lookup instead of a
  /// title/year search.
  final String? imdbId;
}

/// Parse a media file name into a display title, year, and optional IMDb id.
/// Handles the Plex/Jellyfin convention
/// (`Title (Year) {imdb-ttXXXXXXX} - [1080p].mkv`, Jellyfin's
/// `[imdbid-ttXXXXXXX]` variant included) as well as release-style names
/// (`The.Movie.2024.1080p.mkv`). Permissive: plain names pass through
/// unchanged.
ParsedName parseMediaName(String name) {
  var s = name.trim();
  // Drop a media file extension, if present.
  s = s.replaceFirst(
      RegExp(r'\.(mkv|mp4|avi|mov|webm|m4v|mpg|mpeg|ts)$',
          caseSensitive: false),
      '');
  // Plex `{imdb-tt...}` / Jellyfin `[imdbid-tt...]` database-id tag.
  final idMatch = RegExp(r'[{\[]imdb(?:id)?[-=](tt\d+)[}\]]',
          caseSensitive: false)
      .firstMatch(s);
  final imdbId = idMatch?.group(1);
  // Strip all {...} and [...] tag blocks (ids, quality, edition), then any
  // separator dash they leave dangling at the end.
  s = s.replaceAll(RegExp(r'\{[^}]*\}|\[[^\]]*\]'), ' ');
  s = s.replaceAll(RegExp(r'[._]+'), ' ').trim();
  s = s.replaceFirst(RegExp(r'[\s-]+$'), '');

  int? year;
  var title = s;
  // Year in parens, or the last standalone 19xx/20xx token.
  final match = RegExp(r'^(.*)[\s(]+((?:19|20)\d{2})\)?(?:[\s)].*)?$')
      .firstMatch(s);
  if (match != null && match.group(1)!.trim().isNotEmpty) {
    title = match.group(1)!.trim();
    year = int.parse(match.group(2)!);
  }
  return ParsedName(title.isEmpty ? name : title, year, imdbId: imdbId);
}
