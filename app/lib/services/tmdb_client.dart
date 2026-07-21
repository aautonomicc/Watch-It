import 'dart:convert';

import 'package:http/http.dart' as http;

import 'metadata.dart';

/// Transport/API failure talking to TMDB (offline, rate limit, bad key).
/// Distinct from "TMDB has no match", which is a `null` lookup result —
/// only genuine misses are cached as not-found.
class TmdbException implements Exception {
  const TmdbException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'TmdbException($statusCode): $message';
}

/// One resolved TMDB match, ready to cache and display.
class TmdbMatch {
  const TmdbMatch({
    required this.mediaType,
    required this.tmdbId,
    required this.title,
    this.year,
    this.overview,
    this.category,
    this.episodeLabel,
    this.posterPath,
  });

  final String mediaType; // 'movie' | 'tv'
  final int tmdbId;
  final String title;
  final int? year;
  final String? overview;
  final String? category;
  final String? episodeLabel;

  /// TMDB poster path (`/abc.jpg`) — fetch via [TmdbClient.fetchPoster].
  final String? posterPath;
}

/// Thin TMDB v3 API client: exact `/find` lookup by IMDb id when the file
/// name carries one, title/year search otherwise, then a details fetch for
/// overview/genres/poster (the same pipeline Plex/Jellyfin scrapers use).
class TmdbClient {
  TmdbClient({required this.apiKey, http.Client? client})
      : _http = client ?? http.Client();

  final String apiKey;
  final http.Client _http;

  static const _apiBase = 'api.themoviedb.org';

  /// w342 is plenty for a 120–140px poster card at 2–3x DPR.
  static const posterBase = 'https://image.tmdb.org/t/p/w342';

  /// TMDB issues two credential kinds from the same settings page: a v3
  /// API key (32 hex chars, `api_key` query param) and a v4 Read Access
  /// Token (a JWT — always contains dots, sent as a Bearer header).
  bool get _isBearerToken => apiKey.contains('.');

  Future<Map<String, dynamic>> _get(
      String path, Map<String, String> query) async {
    final uri = Uri.https(_apiBase, '/3$path',
        {if (!_isBearerToken) 'api_key': apiKey, ...query});
    final http.Response resp;
    try {
      resp = await _http.get(uri, headers: {
        if (_isBearerToken) 'Authorization': 'Bearer $apiKey',
      }).timeout(const Duration(seconds: 20));
    } on TmdbException {
      rethrow;
    } catch (e) {
      throw TmdbException('$e');
    }
    if (resp.statusCode != 200) {
      throw TmdbException('GET $path failed', statusCode: resp.statusCode);
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// Resolve [parsed] to a TMDB match, or `null` when TMDB has no result.
  /// Throws [TmdbException] on transport/API errors.
  Future<TmdbMatch?> lookup(ParsedName parsed) async {
    final (type, id) = await _resolveId(parsed);
    if (id == null) return null;
    return type == 'tv'
        ? _tvDetails(id, parsed.season, parsed.episode)
        : _movieDetails(id);
  }

  /// Find the TMDB id: exact `/find` by IMDb id if tagged, else a
  /// title(/year) search — TV first for names with an episode marker.
  Future<(String, int?)> _resolveId(ParsedName parsed) async {
    if (parsed.imdbId != null) {
      final found = await _get(
          '/find/${parsed.imdbId}', {'external_source': 'imdb_id'});
      final movies = found['movie_results'] as List<dynamic>? ?? [];
      final shows = found['tv_results'] as List<dynamic>? ?? [];
      final ordered = parsed.isEpisode ? [shows, movies] : [movies, shows];
      for (final results in ordered) {
        if (results.isNotEmpty) {
          final hit = results.first as Map<String, dynamic>;
          return (identical(results, shows) ? 'tv' : 'movie', hit['id'] as int);
        }
      }
      return ('movie', null);
    }
    if (parsed.isEpisode) {
      return ('tv', await _searchId('/search/tv', {
        'query': parsed.title,
        if (parsed.year != null) 'first_air_date_year': '${parsed.year}',
      }));
    }
    final movieId = await _searchId('/search/movie', {
      'query': parsed.title,
      'include_adult': 'false',
      if (parsed.year != null) 'year': '${parsed.year}',
    });
    if (movieId != null) return ('movie', movieId);
    // Not a movie TMDB knows — maybe a show named without episode markers.
    return ('tv', await _searchId('/search/tv', {'query': parsed.title}));
  }

  Future<int?> _searchId(String path, Map<String, String> query) async {
    final results =
        (await _get(path, query))['results'] as List<dynamic>? ?? [];
    if (results.isEmpty) return null;
    return (results.first as Map<String, dynamic>)['id'] as int?;
  }

  Future<TmdbMatch> _movieDetails(int id) async {
    final d = await _get('/movie/$id', const {});
    return TmdbMatch(
      mediaType: 'movie',
      tmdbId: id,
      title: d['title'] as String? ?? '',
      year: _yearOf(d['release_date']),
      overview: _nonEmpty(d['overview']),
      category: _genres(d),
      posterPath: _nonEmpty(d['poster_path']),
    );
  }

  Future<TmdbMatch> _tvDetails(int id, int? season, int? episode) async {
    final d = await _get('/tv/$id', const {});
    String? episodeLabel;
    String? overview = _nonEmpty(d['overview']);
    if (season != null && episode != null) {
      final se = 'S${_pad(season)}E${_pad(episode)}';
      episodeLabel = se;
      try {
        final ep = await _get('/tv/$id/season/$season/episode/$episode',
            const {});
        final name = _nonEmpty(ep['name']);
        if (name != null) episodeLabel = '$se · $name';
        // Episode synopsis beats the show blurb on a detail page.
        overview = _nonEmpty(ep['overview']) ?? overview;
      } on TmdbException catch (e) {
        // Unknown episode number: keep the show-level metadata.
        if (e.statusCode != 404) rethrow;
      }
    }
    return TmdbMatch(
      mediaType: 'tv',
      tmdbId: id,
      title: d['name'] as String? ?? '',
      year: _yearOf(d['first_air_date']),
      overview: overview,
      category: _genres(d),
      episodeLabel: episodeLabel,
      posterPath: _nonEmpty(d['poster_path']),
    );
  }

  /// Download poster bytes from the TMDB image CDN (no auth needed).
  Future<List<int>> fetchPoster(String posterPath) async {
    final http.Response resp;
    try {
      resp = await _http
          .get(Uri.parse('$posterBase$posterPath'))
          .timeout(const Duration(seconds: 30));
    } catch (e) {
      throw TmdbException('$e');
    }
    if (resp.statusCode != 200) {
      throw TmdbException('poster fetch failed', statusCode: resp.statusCode);
    }
    return resp.bodyBytes;
  }

  void close() => _http.close();

  static String? _genres(Map<String, dynamic> details) {
    final names = (details['genres'] as List<dynamic>? ?? [])
        .map((g) => (g as Map<String, dynamic>)['name'] as String?)
        .whereType<String>()
        .take(3)
        .toList();
    return names.isEmpty ? null : names.join(' · ');
  }

  static int? _yearOf(Object? date) {
    final s = date as String?;
    if (s == null || s.length < 4) return null;
    return int.tryParse(s.substring(0, 4));
  }

  static String? _nonEmpty(Object? s) =>
      (s is String && s.trim().isNotEmpty) ? s : null;

  static String _pad(int n) => n.toString().padLeft(2, '0');
}
