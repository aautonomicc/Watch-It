import 'dart:convert';

import 'package:http/http.dart' as http;

/// TMDB match candidate for a video file.
class TmdbHit {
  TmdbHit({
    required this.tmdbId,
    required this.mediaType, // 'movie' | 'tv'
    required this.title,
    this.year,
    this.posterPath,
    this.imdbId,
  });

  final int tmdbId;
  final String mediaType;
  final String title;
  final int? year;
  final String? posterPath;
  String? imdbId;
}

int? _yearOf(String? date) {
  final m = RegExp(r'^(\d{4})').firstMatch(date ?? '');
  return m == null ? null : int.parse(m.group(1)!);
}

/// Normalized title similarity in [0,1] — Levenshtein over lowercased,
/// punctuation-stripped strings (FileBot/tMM-style scoring).
double titleSimilarity(String a, String b) {
  String norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim();
  final x = norm(a), y = norm(b);
  if (x == y) return 1;
  if (x.isEmpty || y.isEmpty) return 0;
  final prev = List<int>.generate(y.length + 1, (i) => i);
  final cur = List<int>.filled(y.length + 1, 0);
  for (var i = 1; i <= x.length; i++) {
    cur[0] = i;
    for (var j = 1; j <= y.length; j++) {
      final cost = x.codeUnitAt(i - 1) == y.codeUnitAt(j - 1) ? 0 : 1;
      cur[j] = [
        cur[j - 1] + 1,
        prev[j] + 1,
        prev[j - 1] + cost,
      ].reduce((m, v) => v < m ? v : m);
    }
    prev.setAll(0, cur);
  }
  final dist = prev[y.length];
  final maxLen = x.length > y.length ? x.length : y.length;
  return 1 - dist / maxLen;
}

/// TMDB client. Accepts a v3 api key (query param) or a v4 read token
/// (contains dots → Bearer header), like the app's Settings → Metadata.
class Tmdb {
  Tmdb(this.key, {http.Client? client}) : _client = client ?? http.Client();

  final String key;
  final http.Client _client;

  bool get _isV4 => key.contains('.');

  Future<Map<String, dynamic>?> _get(String path,
      [Map<String, String> query = const {}]) async {
    final uri = Uri.https('api.themoviedb.org', '/3$path', {
      ...query,
      if (!_isV4) 'api_key': key,
    });
    try {
      final res = await _client.get(uri, headers: {
        if (_isV4) 'Authorization': 'Bearer $key',
        'Accept': 'application/json',
      });
      if (res.statusCode != 200) return null;
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Exact lookup by IMDb id (`tt…`) — no fuzzing needed.
  Future<TmdbHit?> findByImdb(String imdbId) async {
    final doc = await _get('/find/$imdbId', {'external_source': 'imdb_id'});
    if (doc == null) return null;
    final movies = doc['movie_results'] as List<dynamic>? ?? const [];
    final shows = doc['tv_results'] as List<dynamic>? ?? const [];
    if (movies.isNotEmpty) {
      final m = movies.first as Map<String, dynamic>;
      return TmdbHit(
        tmdbId: (m['id'] as num).toInt(),
        mediaType: 'movie',
        title: '${m['title'] ?? ''}',
        year: _yearOf(m['release_date']?.toString()),
        posterPath: m['poster_path']?.toString(),
        imdbId: imdbId,
      );
    }
    if (shows.isNotEmpty) {
      final s = shows.first as Map<String, dynamic>;
      return TmdbHit(
        tmdbId: (s['id'] as num).toInt(),
        mediaType: 'tv',
        title: '${s['name'] ?? ''}',
        year: _yearOf(s['first_air_date']?.toString()),
        posterPath: s['poster_path']?.toString(),
        imdbId: imdbId,
      );
    }
    return null;
  }

  Future<List<TmdbHit>> search(String title,
      {int? year, required bool tv}) async {
    final doc = await _get('/search/${tv ? 'tv' : 'movie'}', {
      'query': title,
      if (year != null) (tv ? 'first_air_date_year' : 'year'): '$year',
    });
    if (doc == null) return const [];
    return [
      for (final r in (doc['results'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>())
        TmdbHit(
          tmdbId: (r['id'] as num).toInt(),
          mediaType: tv ? 'tv' : 'movie',
          title: '${tv ? r['name'] : r['title'] ?? ''}',
          year: _yearOf(
              (tv ? r['first_air_date'] : r['release_date'])?.toString()),
          posterPath: r['poster_path']?.toString(),
        ),
    ];
  }

  /// The IMDb id of a matched title (search results don't carry it; the
  /// canonical name does — `{imdb-tt…}` beats a TMDB-only tag).
  Future<String?> imdbIdOf(int tmdbId, {required bool tv}) async {
    final doc = await _get('/${tv ? 'tv' : 'movie'}/$tmdbId/external_ids');
    final id = doc?['imdb_id'];
    return id is String && id.startsWith('tt') ? id : null;
  }

  Future<TmdbHit?> byId(int tmdbId, {required bool tv}) async {
    final doc = await _get('/${tv ? 'tv' : 'movie'}/$tmdbId');
    if (doc == null) return null;
    return TmdbHit(
      tmdbId: tmdbId,
      mediaType: tv ? 'tv' : 'movie',
      title: '${tv ? doc['name'] : doc['title'] ?? ''}',
      year: _yearOf(
          (tv ? doc['first_air_date'] : doc['release_date'])?.toString()),
      posterPath: doc['poster_path']?.toString(),
    );
  }

  Future<List<int>?> poster(String posterPath) async {
    try {
      final res = await _client
          .get(Uri.parse('https://image.tmdb.org/t/p/w342$posterPath'));
      return res.statusCode == 200 ? res.bodyBytes : null;
    } catch (_) {
      return null;
    }
  }

  void close() => _client.close();
}
