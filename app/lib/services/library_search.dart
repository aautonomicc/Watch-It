import '../models/media_list.dart';
import 'metadata.dart';
import 'season_grouping.dart';

/// Pure in-memory search over the user's library (docs/PLAN-home-search.md):
/// the home screen's lists, folded with the same show grouping as the wall,
/// matched against parsed titles, years, SxxEyy markers, and already-cached
/// TMDB episode names. No network, no database — build once per screen
/// open, query per keystroke. No Flutter imports, fully unit-testable.

/// One search hit. A show's episodes fold into a single [ShowResult] (like
/// the wall); movies and individual episodes are [EntryResult]s.
sealed class SearchResult {
  const SearchResult();
}

class ShowResult extends SearchResult {
  const ShowResult(this.show);

  final HomeShow show;
}

class EntryResult extends SearchResult {
  const EntryResult(this.entry, {required this.isEpisode});

  final MediaEntry entry;

  /// True for an episode of a show (file name carries an SxxEyy/1x02
  /// marker); false for movies and other single files.
  final bool isEpisode;
}

/// Common Latin diacritics folded to their base letter so "Amelie" finds
/// "Amélie" (and vice versa — the query is folded the same way).
const _diacriticFold = <String, String>{
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ā': 'a',
  'ă': 'a', 'ą': 'a',
  'ç': 'c', 'ć': 'c', 'č': 'c',
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e', 'ė': 'e', 'ę': 'e',
  'ě': 'e',
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i', 'į': 'i',
  'ñ': 'n', 'ń': 'n', 'ň': 'n',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', 'ō': 'o',
  'ő': 'o',
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ū': 'u', 'ů': 'u', 'ű': 'u',
  'ý': 'y', 'ÿ': 'y',
  'š': 's', 'ś': 's', 'ž': 'z', 'ź': 'z', 'ż': 'z',
  'ł': 'l', 'đ': 'd', 'ď': 'd', 'ť': 't', 'ř': 'r',
  'ß': 'ss', 'æ': 'ae', 'œ': 'oe', 'ð': 'd', 'þ': 'th',
};

/// Lowercase, fold diacritics, and collapse everything that is not a
/// letter or digit into single spaces — applied to queries and indexed
/// titles alike so matching is accent- and punctuation-blind.
String normalizeSearchText(String input) {
  final b = StringBuffer();
  for (final ch in input.toLowerCase().split('')) {
    for (final c in (_diacriticFold[ch] ?? ch).split('')) {
      final code = c.codeUnitAt(0);
      final alnum = (code >= 0x61 && code <= 0x7A) ||
          (code >= 0x30 && code <= 0x39);
      b.write(alnum ? c : ' ');
    }
  }
  return b.toString().split(' ').where((w) => w.isNotEmpty).join(' ');
}

/// Match quality of one query token against one record.
const _wordStart = 1;
const _substring = 2;

class _Record {
  _Record(
    this.result, {
    required this.title,
    List<String> extraWords = const [],
    this.year,
    this.season,
    this.episode,
  }) : words = [
          ...title.split(' ').where((w) => w.isNotEmpty),
          ...extraWords,
        ];

  final SearchResult result;

  /// Normalized display title — rank-0 prefix checks and tie-breaking.
  final String title;

  /// Normalized haystack words: title words plus year / episode marker /
  /// cached episode-name words.
  final List<String> words;

  late final String haystack = words.join(' ');

  /// Parsed year (movies) and episode marker (episodes) for exact token
  /// matches; null where not applicable.
  final int? year;
  final int? season;
  final int? episode;
}

/// The library folded into searchable records. Build is cheap (pure
/// in-memory scan of the lists) — the screen rebuilds it when cached
/// metadata lands rather than tracking invalidation.
class SearchIndex {
  SearchIndex._(this._records);

  final List<_Record> _records;

  /// Index [lists] (enabled ones only, duplicate addresses dropped),
  /// grouped exactly like the home wall: one show record per show plus
  /// one record per episode, one record per movie/single file.
  ///
  /// [episodeName] supplies an already-cached TMDB episode name for an
  /// entry, or null — injected so this file stays free of service
  /// imports (and search never becomes a network trigger).
  factory SearchIndex.build(
    List<MediaList> lists, {
    String? Function(MediaEntry entry)? episodeName,
  }) {
    final seen = <String>{};
    final entries = <MediaEntry>[
      for (final l in lists)
        if (l.enabled)
          for (final e in l.entries)
            if (seen.add(e.address.toLowerCase().replaceFirst('0x', ''))) e,
    ];
    final records = <_Record>[];
    // Each track searchable by artist/album (title words), its own name
    // and — on compilations, where the album credit reads Various
    // Artists — its own track's artist (extra words); results open the
    // track's detail page.
    void indexAlbum(HomeAlbum album) {
      for (final trackEntry in album.tracks) {
        final parsed = parseMediaName(trackEntry.name);
        records.add(_Record(
          EntryResult(trackEntry, isEpisode: false),
          title: normalizeSearchText('${album.artist} ${album.album}'),
          extraWords: [
            if (parsed.trackTitle != null)
              ...normalizeSearchText(parsed.trackTitle!)
                  .split(' ')
                  .where((w) => w.isNotEmpty),
            if (parsed.artist != null && parsed.artist != album.artist)
              ...normalizeSearchText(parsed.artist!)
                  .split(' ')
                  .where((w) => w.isNotEmpty),
            if (parsed.year != null) '${parsed.year}',
          ],
          year: parsed.year,
        ));
      }
    }

    for (final item in groupShows(entries)) {
      switch (item) {
        case HomeEntry(:final entry):
          final parsed = parseMediaName(entry.name);
          records.add(_Record(
            EntryResult(entry, isEpisode: false),
            title: normalizeSearchText(parsed.title),
            extraWords: [if (parsed.year != null) '${parsed.year}'],
            year: parsed.year,
          ));
        case HomeShow():
          final title = normalizeSearchText(item.show);
          records.add(_Record(ShowResult(item), title: title));
          for (final season in item.seasons) {
            for (final ep in season.episodes) {
              final parsed = parseMediaName(ep.name);
              final marker = 's${'${parsed.season}'.padLeft(2, '0')}'
                  'e${'${parsed.episode}'.padLeft(2, '0')}';
              final name = episodeName?.call(ep);
              records.add(_Record(
                EntryResult(ep, isEpisode: true),
                title: title,
                extraWords: [
                  marker,
                  if (name != null)
                    ...normalizeSearchText(name)
                        .split(' ')
                        .where((w) => w.isNotEmpty),
                ],
                season: parsed.season,
                episode: parsed.episode,
              ));
            }
          }
        case HomeAlbum():
          indexAlbum(item);
        case HomeArtist():
          item.albums.forEach(indexAlbum);
        case HomeSeason():
          break; // groupShows never yields bare seasons
      }
    }
    return SearchIndex._(records);
  }

  static final _yearToken = RegExp(r'^(?:19|20)\d{2}$');
  static final _seToken = RegExp(r'^s(\d{1,2})(?:e(\d{1,3}))?$');
  static final _xToken = RegExp(r'^(\d{1,2})x(\d{1,3})$');

  /// Matches for [raw], best first. An item matches when **every** query
  /// token matches it: at a word start, as an exact year (4 digits), as
  /// an episode marker (`s01e02` / `s01` / `1x02`), or as a plain
  /// substring fallback — so "dark kni", "knight dark", and "s02" all
  /// behave sensibly. Ranked title-starts-with-query, then all-tokens-
  /// at-word-starts, then substring; ties alphabetical (episodes of one
  /// show in season/episode order).
  List<SearchResult> query(String raw) {
    final q = normalizeSearchText(raw);
    if (q.isEmpty) return const [];
    final tokens = q.split(' ');
    final matches = <(_Record, int)>[];
    for (final r in _records) {
      var allWordStart = true;
      var failed = false;
      for (final token in tokens) {
        final quality = _tokenQuality(r, token);
        if (quality == null) {
          failed = true;
          break;
        }
        if (quality != _wordStart) allWordStart = false;
      }
      if (failed) continue;
      final rank = r.title.startsWith(q) ? 0 : (allWordStart ? 1 : 2);
      matches.add((r, rank));
    }
    matches.sort((a, b) {
      var c = a.$2.compareTo(b.$2);
      if (c != 0) return c;
      c = a.$1.title.compareTo(b.$1.title);
      if (c != 0) return c;
      c = (a.$1.season ?? -1).compareTo(b.$1.season ?? -1);
      if (c != 0) return c;
      return (a.$1.episode ?? -1).compareTo(b.$1.episode ?? -1);
    });
    return [for (final (r, _) in matches) r.result];
  }

  static int? _tokenQuality(_Record r, String token) {
    // A 4-digit token matching the parsed year, or an episode-marker
    // token matching the record's season(/episode), counts as a word-
    // start match; when it doesn't match numerically it falls through to
    // text matching (a movie titled "1984" still matches "1984").
    if (r.year != null &&
        _yearToken.hasMatch(token) &&
        int.parse(token) == r.year) {
      return _wordStart;
    }
    if (r.season != null) {
      final m = _seToken.firstMatch(token) ?? _xToken.firstMatch(token);
      if (m != null &&
          int.parse(m.group(1)!) == r.season &&
          (m.group(2) == null || int.parse(m.group(2)!) == r.episode)) {
        return _wordStart;
      }
    }
    for (final w in r.words) {
      if (w.startsWith(token)) return _wordStart;
    }
    if (r.haystack.contains(token)) return _substring;
    return null;
  }
}
