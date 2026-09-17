import 'dart:convert';

import 'package:http/http.dart' as http;

/// Transport failure talking to MusicBrainz (offline, 5xx, 503 rate
/// limit). Distinct from "MusicBrainz has no such artist/release", which
/// is a `null` result — only genuine no-match answers are cached.
class MbException implements Exception {
  const MbException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'MbException($statusCode): $message';
}

/// An artist reference from a release's artist credit or a search hit.
class MbArtistRef {
  const MbArtistRef({required this.id, required this.name});

  /// MusicBrainz artist id (UUID).
  final String id;
  final String name;
}

/// The artist-page facts from a MusicBrainz artist lookup.
class MbArtistDetails {
  const MbArtistDetails({
    required this.name,
    this.formedYear,
    this.area,
    this.genres,
    this.wikidataId,
  });

  final String name;

  /// Year the artist formed / was born (`life-span.begin`).
  final int? formedYear;

  /// Area name ("London", "United Kingdom") or ISO country code.
  final String? area;

  /// Top community genres joined with ` · ` (the [MediaMetadata.category]
  /// convention); null when untagged.
  final String? genres;

  /// Wikidata item id (`Q392`) from the artist's URL relationships —
  /// the bridge to the Wikipedia bio and Commons portrait.
  final String? wikidataId;
}

/// Minimal MusicBrainz client: keyless, but etiquette applies — a real
/// User-Agent and at most ~1 request/second, enforced here by spacing
/// consecutive requests [minInterval] apart (shared per instance; the
/// app uses one [ArtistInfoService] instance, so this covers all calls).
class MusicBrainzClient {
  MusicBrainzClient({
    http.Client? client,
    this.minInterval = const Duration(milliseconds: 1100),
  }) : _http = client ?? http.Client();

  final http.Client _http;
  final Duration minInterval;

  static const _base = 'https://musicbrainz.org/ws/2';

  /// MusicBrainz rejects generic library agents; identify the app.
  static const userAgent =
      'Watch-It/alpha (https://github.com/aautonomicc/Watch-It)';

  DateTime? _lastRequest;
  Future<void> _gate = Future.value();

  Future<Map<String, dynamic>?> _getJson(String pathAndQuery) {
    // Serialize requests through a chain so concurrent callers cannot
    // burst past the rate etiquette.
    final result = _gate.then((_) async {
      final last = _lastRequest;
      if (last != null) {
        final wait = minInterval - DateTime.now().difference(last);
        if (wait > Duration.zero) await Future.delayed(wait);
      }
      _lastRequest = DateTime.now();
      final http.Response resp;
      try {
        resp = await _http.get(
          Uri.parse('$_base$pathAndQuery'),
          headers: const {
            'User-Agent': userAgent,
            'Accept': 'application/json',
          },
        ).timeout(const Duration(seconds: 30));
      } catch (e) {
        throw MbException('$e');
      }
      if (resp.statusCode == 404) return null;
      if (resp.statusCode != 200) {
        throw MbException('lookup failed', statusCode: resp.statusCode);
      }
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      return decoded is Map<String, dynamic> ? decoded : null;
    });
    _gate = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// The first artist credited on [releaseMbid] (the album artist for
  /// the releases the app's `{mbid-...}` tags name), or null when the
  /// release is unknown.
  Future<MbArtistRef?> releaseArtist(String releaseMbid) async {
    final json =
        await _getJson('/release/$releaseMbid?fmt=json&inc=artist-credits');
    final credits = json?['artist-credit'];
    if (credits is! List || credits.isEmpty) return null;
    final first = credits.first;
    final artist = first is Map ? first['artist'] : null;
    if (artist is! Map) return null;
    final id = artist['id'];
    final name = artist['name'];
    if (id is! String || name is! String) return null;
    return MbArtistRef(id: id, name: name);
  }

  /// Search for an artist by name. Name-only search is collision-prone
  /// (many artists share names), so only a top hit with a perfect score
  /// AND a case-insensitive exact name match is returned — anything
  /// fuzzier resolves to null rather than risking the wrong artist's
  /// bio on the page.
  Future<MbArtistRef?> searchArtist(String name) async {
    final cleaned = name.trim().replaceAll('"', '');
    if (cleaned.isEmpty) return null;
    final query = Uri.encodeQueryComponent('artist:"$cleaned"');
    final json = await _getJson('/artist?fmt=json&limit=5&query=$query');
    final artists = json?['artists'];
    if (artists is! List || artists.isEmpty) return null;
    final top = artists.first;
    if (top is! Map) return null;
    final score = top['score'];
    final id = top['id'];
    final hitName = top['name'];
    if (id is! String || hitName is! String) return null;
    if (score is! int || score < 100) return null;
    if (hitName.trim().toLowerCase() != cleaned.toLowerCase()) return null;
    return MbArtistRef(id: id, name: hitName);
  }

  /// Facts for the artist page: formed year, area, genres, and the
  /// Wikidata id bridging to the bio/portrait chain.
  Future<MbArtistDetails?> artistDetails(String mbid) async {
    final json = await _getJson('/artist/$mbid?fmt=json&inc=url-rels+genres');
    if (json == null) return null;
    final name = json['name'];
    if (name is! String) return null;

    int? formedYear;
    final lifeSpan = json['life-span'];
    final begin = lifeSpan is Map ? lifeSpan['begin'] : null;
    if (begin is String && begin.length >= 4) {
      formedYear = int.tryParse(begin.substring(0, 4));
    }

    final areaMap = json['area'];
    final areaName = areaMap is Map ? areaMap['name'] : null;
    final area = areaName is String
        ? areaName
        : (json['country'] is String ? json['country'] as String : null);

    String? genres;
    final rawGenres = json['genres'];
    if (rawGenres is List && rawGenres.isNotEmpty) {
      final scored = <(int, String)>[];
      for (final g in rawGenres) {
        if (g is! Map) continue;
        final n = g['name'];
        if (n is! String || n.isEmpty) continue;
        final count = g['count'];
        scored.add((count is int ? count : 0, n));
      }
      scored.sort((a, b) => b.$1.compareTo(a.$1));
      final names = [
        for (final (_, n) in scored.take(3))
          n[0].toUpperCase() + n.substring(1),
      ];
      if (names.isNotEmpty) genres = names.join(' · ');
    }

    String? wikidataId;
    final relations = json['relations'];
    if (relations is List) {
      for (final rel in relations) {
        if (rel is! Map || rel['type'] != 'wikidata') continue;
        final url = rel['url'];
        final resource = url is Map ? url['resource'] : null;
        if (resource is String) {
          final m = RegExp(r'(Q\d+)').firstMatch(resource);
          if (m != null) {
            wikidataId = m.group(1);
            break;
          }
        }
      }
    }

    return MbArtistDetails(
      name: name,
      formedYear: formedYear,
      area: area,
      genres: genres,
      wikidataId: wikidataId,
    );
  }

  void close() => _http.close();
}
