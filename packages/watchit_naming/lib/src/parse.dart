/// Moved verbatim from `app/lib/services/metadata.dart` (2026-09-01,
/// upload-CLI extraction) so the app and the CLI share one parser. The
/// only change since the move: audio extensions joined the extension
/// strip — audio files are the coarse music/video discriminator
/// (docs/NAMING.md, music planning 2026-09-01).
library;

class ParsedName {
  const ParsedName(this.title, this.year,
      {this.imdbId,
      this.season,
      this.episode,
      this.releaseMbid,
      this.artist,
      this.trackTitle,
      this.track,
      this.disc,
      this.isAudio = false});

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

  /// MusicBrainz release id from an `{mbid-...}` tag, if present. Keys
  /// the album's metadata (as [imdbId] does for movies) and fetches its
  /// Cover Art Archive front cover.
  final String? releaseMbid;

  /// Music fields from the W@tch music convention
  /// (`Artist - Album (Year) - NN Title {mbid-...}.flac`, docs/NAMING.md).
  /// When [track] is set, [title] is the album name — the role the show
  /// name plays for episodes.
  final String? artist;
  final String? trackTitle;
  final int? track;

  /// Disc number from a `D-NN` track marker; null for single-disc
  /// releases (plain `NN`).
  final int? disc;

  /// The file has an audio extension — the coarse music/video
  /// discriminator (an audio file is music even without a track marker).
  final bool isAudio;

  bool get isEpisode => season != null;
  bool get isTrack => track != null;

  /// The album name for tracks (alias of [title]), null otherwise.
  String? get album => isTrack ? title : null;

  /// Cache key for this lookup: same key means the same metadata query,
  /// so renamed copies and duplicates share one cached match. All tracks
  /// of one album share a single key — album art and metadata are
  /// per-release, and each track's own name/number comes from its file
  /// name.
  String get lookupKey =>
      isEpisode ? '$showLookupKey:s$season:e$episode' : showLookupKey;

  /// Episode-less key for the show an episode belongs to (equals
  /// [lookupKey] for non-episodes). User-authored show-level details —
  /// Edit details on a show page — live in the metadata cache under this
  /// key; no TMDB match is ever stored there.
  String get showLookupKey {
    if (releaseMbid != null) return 'mbid:$releaseMbid';
    if (imdbId != null) return 'imdb:$imdbId';
    if (isTrack) {
      return 'music:${artist!.toLowerCase()}'
          ':${title.toLowerCase()}:${year ?? ''}';
    }
    return '${isEpisode ? 'tv' : 'movie'}'
        ':${title.toLowerCase()}:${year ?? ''}';
  }

  /// Season-level key (`<showLookupKey>:sN`), null for non-episodes.
  /// User-authored season artwork/description lives under this key.
  String? get seasonLookupKey => isEpisode ? '$showLookupKey:s$season' : null;

  /// `05` / `2-03` display marker for tracks (disc prefix only on
  /// multi-disc releases), null otherwise.
  String? get trackMarker {
    if (!isTrack) return null;
    final n = track.toString().padLeft(2, '0');
    return disc != null ? '$disc-$n' : n;
  }
}

/// Parse a media file name into a display title, year, optional IMDb id,
/// and optional season/episode. Handles the Plex/Jellyfin convention
/// (`Title (Year) {imdb-ttXXXXXXX} - [1080p].mkv`, Jellyfin's
/// `[imdbid-ttXXXXXXX]` variant included), release-style names
/// (`The.Movie.2024.1080p.mkv`), episode markers (`Show S01E02.mkv`,
/// `Show 1x02.mkv`), and the W@tch music convention
/// (`Artist - Album (Year) - NN Title {mbid-<release-mbid>}.flac` —
/// [musicFileName]'s output). Permissive: plain names pass through
/// unchanged.
ParsedName parseMediaName(String name) {
  var s = name.trim();
  // Audio extension = music (the coarse discriminator, docs/NAMING.md).
  final isAudio = RegExp(r'\.(flac|mp3|ogg|oga|opus|m4a|wav|aac|wma)$',
          caseSensitive: false)
      .hasMatch(s);
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
  // `{mbid-<release-mbid>}` tag from the music convention.
  final mbidMatch =
      RegExp(r'[{\[]mbid[-=]([0-9a-zA-Z-]+)[}\]]', caseSensitive: false)
          .firstMatch(s);
  final releaseMbid = mbidMatch?.group(1);
  // Strip all {...} and [...] tag blocks (ids, quality, edition), then any
  // separator dash they leave dangling at the end.
  s = s.replaceAll(RegExp(r'\{[^}]*\}|\[[^\]]*\]'), ' ');
  s = s.replaceAll(RegExp(r'[._]+'), ' ').trim();

  // Music track: `Artist - Album (Year) - NN Title` (`D-NN` on
  // multi-disc releases, year optional). Only tried for audio files, and
  // a non-matching audio name falls through to the generic parse below.
  if (isAudio) {
    final m = RegExp(
            r'^(.+?) - (.+?)(?: \((\d{4})\))? - (?:(\d{1,2})-)?(\d{2,3}) (.+)$')
        .firstMatch(s.replaceAll(RegExp(r'\s+'), ' ').trim());
    if (m != null) {
      return ParsedName(
        m.group(2)!,
        m.group(3) != null ? int.parse(m.group(3)!) : null,
        releaseMbid: releaseMbid,
        artist: m.group(1)!,
        disc: m.group(4) != null ? int.parse(m.group(4)!) : null,
        track: int.parse(m.group(5)!),
        trackTitle: m.group(6)!,
        isAudio: true,
      );
    }
  }

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
      imdbId: imdbId,
      season: season,
      episode: episode,
      releaseMbid: releaseMbid,
      isAudio: isAudio);
}
