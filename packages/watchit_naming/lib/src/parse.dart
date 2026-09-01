/// Moved verbatim from `app/lib/services/metadata.dart` (2026-09-01,
/// upload-CLI extraction) so the app and the CLI share one parser. The
/// only change since the move: audio extensions joined the extension
/// strip — audio files are the coarse music/video discriminator
/// (docs/NAMING.md, music planning 2026-09-01).
library;

class ParsedName {
  const ParsedName(this.title, this.year,
      {this.imdbId, this.season, this.episode});

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
      RegExp(
          r'\.(mkv|mp4|avi|mov|webm|m4v|mpg|mpeg|ts'
          r'|flac|mp3|ogg|oga|opus|m4a|wav|aac|wma)$',
          caseSensitive: false),
      '');
  // Plex `{imdb-tt...}` / Jellyfin `[imdbid-tt...]` database-id tag.
  final idMatch =
      RegExp(r'[{\[]imdb(?:id)?[-=](tt\d+)[}\]]', caseSensitive: false)
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
  final epMatch =
      RegExp(r'\bS(\d{1,2})[ ._-]?E(\d{1,3})\b', caseSensitive: false)
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
  final match =
      RegExp(r'^(.*)[\s(]+((?:19|20)\d{2})\)?(?:[\s)].*)?$').firstMatch(s);
  if (match != null && match.group(1)!.trim().isNotEmpty) {
    title = match.group(1)!.trim();
    year = int.parse(match.group(2)!);
  }
  return ParsedName(title.isEmpty ? name : title, year,
      imdbId: imdbId, season: season, episode: episode);
}
