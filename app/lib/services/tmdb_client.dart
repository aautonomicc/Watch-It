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
    this.season,
    this.episode,
    this.posterPath,
    this.rating,
    this.showOverview,
    this.seasonOverview,
    this.airDate,
    this.stillPath,
    this.showPosterPath,
  });

  final String mediaType; // 'movie' | 'tv'
  final int tmdbId;
  final String title;
  final int? year;
  final String? overview;
  final String? category;
  final String? episodeLabel;

  /// Season number when this match is for a TV episode; [posterPath] is
  /// then the season's artwork (falling back to the show poster), so the
  /// cached poster file must be keyed per season.
  final int? season;
  final int? episode;

  /// TMDB poster path (`/abc.jpg`) — fetch via [TmdbClient.fetchPoster].
  final String? posterPath;

  /// TMDB community score out of 10 (movie or show level); `null` when
  /// unrated (TMDB reports 0 for those).
  final double? rating;

  /// Show-level synopsis for episode matches, where [overview] is the
  /// episode's own synopsis.
  final String? showOverview;

  /// Season-level synopsis for episode matches, when TMDB has one.
  final String? seasonOverview;

  /// Episode air date (`2008-01-20`), for episode matches.
  final String? airDate;

  /// Episode screenshot path — fetch via [TmdbClient.fetchStill].
  final String? stillPath;

  /// Show poster for episode matches, where [posterPath] is the season's
  /// artwork.
  final String? showPosterPath;
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

  /// w342 is plenty for a 120–240px poster card at 2–3x DPR.
  static const posterBase = 'https://image.tmdb.org/t/p/w342';

  /// 16:9 episode screenshots; w300 covers a ~170px tile at 2x DPR.
  static const stillBase = 'https://image.tmdb.org/t/p/w300';

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
      rating: _ratingOf(d),
      airDate: _nonEmpty(d['release_date']),
    );
  }

  Future<TmdbMatch> _tvDetails(int id, int? season, int? episode) async {
    final d = await _get('/tv/$id', const {});
    String? episodeLabel;
    final showOverview = _nonEmpty(d['overview']);
    String? overview = showOverview;
    String? seasonOverview;
    String? airDate;
    String? stillPath;
    final showPosterPath = _nonEmpty(d['poster_path']);
    String? posterPath = showPosterPath;
    if (season != null && episode != null) {
      final se = 'S${_pad(season)}E${_pad(episode)}';
      episodeLabel = se;
      try {
        // The season payload carries the season poster + synopsis (show
        // and season pages) plus every episode's name/overview/air date/
        // screenshot — one request covers all of it.
        final s = await _get('/tv/$id/season/$season', const {});
        posterPath = _nonEmpty(s['poster_path']) ?? posterPath;
        seasonOverview = _nonEmpty(s['overview']);
        Map<String, dynamic>? ep;
        for (final e in s['episodes'] as List<dynamic>? ?? const []) {
          if ((e as Map<String, dynamic>)['episode_number'] == episode) {
            ep = e;
            break;
          }
        }
        final name = ep == null ? null : _nonEmpty(ep['name']);
        if (name != null) episodeLabel = '$se · $name';
        // Episode synopsis beats the show blurb on a detail page.
        if (ep != null) {
          overview = _nonEmpty(ep['overview']) ?? overview;
          airDate = _nonEmpty(ep['air_date']);
          stillPath = _nonEmpty(ep['still_path']);
        }
      } on TmdbException catch (e) {
        // Unknown season number: keep the show-level metadata.
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
      season: episode != null ? season : null,
      episode: episode,
      posterPath: posterPath,
      rating: _ratingOf(d),
      showOverview: showOverview,
      seasonOverview: seasonOverview,
      airDate: airDate,
      stillPath: stillPath,
      showPosterPath: showPosterPath,
    );
  }

  /// Download poster bytes from the TMDB image CDN (no auth needed).
  Future<List<int>> fetchPoster(String posterPath) =>
      _fetchImage(posterBase, posterPath);

  /// Download an episode screenshot from the TMDB image CDN.
  Future<List<int>> fetchStill(String stillPath) =>
      _fetchImage(stillBase, stillPath);

  Future<List<int>> _fetchImage(String base, String path) async {
    final http.Response resp;
    try {
      resp = await _http
          .get(Uri.parse('$base$path'))
          .timeout(const Duration(seconds: 30));
    } catch (e) {
      throw TmdbException('$e');
    }
    if (resp.statusCode != 200) {
      throw TmdbException('image fetch failed', statusCode: resp.statusCode);
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

  /// TMDB reports `vote_average: 0` for unrated titles — treat as no
  /// rating rather than a zero score.
  static double? _ratingOf(Map<String, dynamic> details) {
    final v = details['vote_average'];
    if (v is! num || v <= 0) return null;
    return v.toDouble();
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
