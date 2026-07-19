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
const kDefaultMovieAddress =
    'cebd7965268b61d98907378670f13e55a2694064d0eed7ef4be9c19eaaf03988';

/// File name of the built-in test movie as stored on the network.
const kDefaultMovieName = 'Night_of_the_Living_Dead_(1968).webm';

/// Stale address the default movie was seeded under up to v0.1.0-alpha.4;
/// migrated to [kDefaultMovieAddress] by [LibraryStore.ensureDefaults].
const kLegacyDefaultMovieAddress =
    'ac855e1e8b17cb4ba0884a4e7025bd5f51d95ed69e4fa15ca37290496a400ea0';

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
  const ParsedName(this.title, this.year);

  final String title;
  final int? year;
}

/// Parse a release-style file name (`The.Movie.2024.1080p.mkv`) into a
/// display title and year. Permissive: plain names pass through unchanged.
ParsedName parseMediaName(String name) {
  var s = name.trim();
  // Drop a media file extension, if present.
  s = s.replaceFirst(
      RegExp(r'\.(mkv|mp4|avi|mov|webm|m4v|mpg|mpeg|ts)$',
          caseSensitive: false),
      '');
  s = s.replaceAll(RegExp(r'[._]+'), ' ').trim();

  int? year;
  var title = s;
  // Year in parens, or the last standalone 19xx/20xx token.
  final match = RegExp(r'^(.*)[\s(]+((?:19|20)\d{2})\)?(?:[\s)].*)?$')
      .firstMatch(s);
  if (match != null && match.group(1)!.trim().isNotEmpty) {
    title = match.group(1)!.trim();
    year = int.parse(match.group(2)!);
  }
  return ParsedName(title.isEmpty ? name : title, year);
}
