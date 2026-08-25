import '../models/media_list.dart';

/// Display metadata for a media entry: artwork, description, year,
/// category.
///
/// Three sources, best wins (see services/metadata_service.dart):
/// live TMDB match cached in SQLite, the small bundled catalog covering
/// the default test movie, and the parsed file name with no artwork.
class MediaMetadata {
  const MediaMetadata({
    required this.title,
    this.year,
    this.overview,
    this.category,
    this.episodeLabel,
    this.posterAsset,
    this.posterFilePath,
    this.rating,
    this.showOverview,
    this.seasonOverview,
    this.airDate,
    this.stillFilePath,
    this.showPosterFilePath,
    this.episodePosterFilePath,
    this.mediaType,
  });

  final String title;
  final int? year;
  final String? overview;

  /// Genre names joined with ` · ` (e.g. `Horror · Thriller`), if matched.
  final String? category;

  /// `'movie'` or `'tv'` from the TMDB match; the fallback guesses from
  /// the file name (episode marker → `'tv'`). Drives the auto-by-type
  /// arrangement (services/library_arrangement.dart).
  final String? mediaType;

  /// For TV episodes: `S01E02 · Episode Name` (name when TMDB knows it).
  final String? episodeLabel;

  /// Bundled asset path (e.g. `assets/posters/notld_1968.jpg`), if any.
  final String? posterAsset;

  /// Locally cached artwork file downloaded from TMDB, if any.
  /// Season artwork for episode entries.
  final String? posterFilePath;

  /// TMDB community score out of 10; null when unrated/unmatched.
  final double? rating;

  /// Show/season synopses for episode entries ([overview] is then the
  /// episode's own synopsis).
  final String? showOverview;
  final String? seasonOverview;

  /// Episode air date / movie release date (`2008-01-20`), if known.
  final String? airDate;

  /// Cached episode screenshot file, if any (episode entries only).
  final String? stillFilePath;

  /// Cached show poster file for episode entries ([posterFilePath] is
  /// then the season's artwork).
  final String? showPosterFilePath;

  /// User-authored artwork for this episode entry only (Edit details on
  /// the episode). Kept apart from [posterFilePath] — the season-art
  /// slot — so season tiles and headers, which read the first episode's
  /// metadata, never show one episode's artwork.
  final String? episodePosterFilePath;
}

/// XOR address of the built-in default movie seeded on first run — the
/// public-domain catalog's NOTLD upload (H.264 8-bit archive.org source,
/// uploaded 2026-08-07; part of kSeedLists in seed_catalog.dart).
const kDefaultMovieAddress =
    '442180e7d60e9a16bfaeb7f00aff6e47c754934986b9010f5f75e101ef4da20e';

/// File name of the built-in default movie as stored on the network.
/// Follows the Plex/Jellyfin naming convention
/// (`Title (Year) {imdb-ttXXXXXXX} - [quality].ext`) — see docs/NAMING.md.
const kDefaultMovieName =
    'Night of the Living Dead (1968) {imdb-tt0063350} - [1080p].mp4';

/// The genuine-1080p NOTLD upload (the 5.68GB H.264 re-encode that was
/// the default movie up to v0.1.0-alpha.47). Back in the seed catalog as
/// a second entry alongside [kDefaultMovieAddress] — same film, same
/// network file name, told apart by size/format info — so it must NOT be
/// listed in [kLegacyDefaultMovieAddresses].
const kDefaultMovie1080Address =
    '66cacd0604b01b2c2f1da1c1c3c05609d3b4cc448cff3b6cdd868e6b7eebcb13';

/// Stale addresses the default movie was seeded under in older releases;
/// migrated to [kDefaultMovieAddress] by [LibraryStore.ensureDefaults].
/// In order: up to v0.1.0-alpha.4 (dead upload), and the AV1 10-bit webm
/// used up to v0.1.0-alpha.15. The 5.68GB re-encode that followed is a
/// catalog entry again ([kDefaultMovie1080Address]), not a stale address.
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
  mediaType: 'movie',
);

/// Bundled catalog, keyed by XOR address.
const _byAddress = <String, MediaMetadata>{
  kDefaultMovieAddress: _notld,
  kDefaultMovie1080Address: _notld,
};

/// Offline fallback metadata for [entry]. Always returns something
/// displayable: catalog hit by address, else a parsed title/year with no
/// artwork. Screens go through `MetadataService.instance.metadataFor`,
/// which upgrades this with the cached/live TMDB match.
MediaMetadata fallbackMetadataFor(MediaEntry entry) {
  final addr = entry.address.toLowerCase().replaceFirst('0x', '');
  final hit = _byAddress[addr];
  if (hit != null) return hit;
  final parsed = parseMediaName(entry.name);
  return MediaMetadata(
    title: parsed.title,
    year: parsed.year,
    episodeLabel: parsed.isEpisode
        ? 'S${parsed.season.toString().padLeft(2, '0')}'
            'E${parsed.episode.toString().padLeft(2, '0')}'
        : null,
    mediaType: parsed.isEpisode ? 'tv' : 'movie',
  );
}

/// `2008-01-20` → `20 Jan 2008` for display; anything that is not an
/// ISO date passes through unchanged.
String formatAirDate(String date) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(date);
  if (m == null) return date;
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final month = int.parse(m.group(2)!);
  if (month < 1 || month > 12) return date;
  return '${int.parse(m.group(3)!)} ${months[month - 1]} ${m.group(1)}';
}

class ParsedName {
  const ParsedName(this.title, this.year, {this.imdbId, this.season, this.episode});

  final String title;
  final int? year;

  /// IMDb id (`tt0063350`) from a Plex/Jellyfin id tag, if present.
  /// Lets the TMDB matcher do an exact `/find` lookup instead of a
  /// title/year search.
  final String? imdbId;

  /// Season/episode from an `S01E02` or `1x02` marker; both set or both
  /// null. When set, [title] is the show name (text before the marker).
  final int? season;
  final int? episode;

  bool get isEpisode => season != null;

  /// Cache key for this lookup: same key means the same TMDB query, so
  /// renamed copies and duplicates share one cached match.
  String get lookupKey =>
      isEpisode ? '$showLookupKey:s$season:e$episode' : showLookupKey;

  /// Episode-less key for the show an episode belongs to (equals
  /// [lookupKey] for non-episodes). User-authored show-level details —
  /// Edit details on a show page — live in the metadata cache under this
  /// key; no TMDB match is ever stored there.
  String get showLookupKey {
    if (imdbId != null) return 'imdb:$imdbId';
    return '${isEpisode ? 'tv' : 'movie'}'
        ':${title.toLowerCase()}:${year ?? ''}';
  }

  /// Season-level key (`<showLookupKey>:sN`), null for non-episodes.
  /// User-authored season artwork/description lives under this key.
  String? get seasonLookupKey => isEpisode ? '$showLookupKey:s$season' : null;
}

/// Parse a media file name into a display title, year, optional IMDb id,
/// and optional season/episode. Handles the Plex/Jellyfin convention
/// (`Title (Year) {imdb-ttXXXXXXX} - [1080p].mkv`, Jellyfin's
/// `[imdbid-ttXXXXXXX]` variant included), release-style names
/// (`The.Movie.2024.1080p.mkv`), and episode markers (`Show S01E02.mkv`,
/// `Show 1x02.mkv`). Permissive: plain names pass through unchanged.
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

  // Episode marker: `S01E02` / `s01 e02` / `1x02`. Everything before it is
  // the show name; everything after (episode title, quality) is dropped —
  // TMDB supplies the episode name. `\d{1,2}x` cannot match inside
  // resolutions like 1920x1080 (no word boundary mid-number).
  int? season, episode;
  final epMatch = RegExp(r'\bS(\d{1,2})[ ._-]?E(\d{1,3})\b',
              caseSensitive: false)
          .firstMatch(s) ??
      RegExp(r'\b(\d{1,2})x(\d{2,3})\b').firstMatch(s);
  if (epMatch != null && s.substring(0, epMatch.start).trim().isNotEmpty) {
    season = int.parse(epMatch.group(1)!);
    episode = int.parse(epMatch.group(2)!);
    s = s.substring(0, epMatch.start);
  }
  s = s.replaceFirst(RegExp(r'[\s-]+$'), '').trim();

  int? year;
  var title = s;
  // Year in parens, or the last standalone 19xx/20xx token.
  final match = RegExp(r'^(.*)[\s(]+((?:19|20)\d{2})\)?(?:[\s)].*)?$')
      .firstMatch(s);
  if (match != null && match.group(1)!.trim().isNotEmpty) {
    title = match.group(1)!.trim();
    year = int.parse(match.group(2)!);
  }
  return ParsedName(title.isEmpty ? name : title, year,
      imdbId: imdbId, season: season, episode: episode);
}
