import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

const _mbBase = 'https://musicbrainz.org/ws/2';
const kUserAgent =
    'WatchItUploadCLI/0.1 (https://github.com/aautonomicc/Watch-It)';

/// One release track as needed for naming.
class MbTrack {
  MbTrack({
    required this.position,
    required this.title,
    required this.disc,
    this.artistCredit,
    this.recordingMbid,
  });

  final int position;
  final String title;
  final int disc;

  /// MB artist-credit string verbatim (featuring credits included).
  final String? artistCredit;
  final String? recordingMbid;
}

class MbRelease {
  MbRelease({
    required this.mbid,
    required this.title,
    required this.artistCredit,
    this.year,
    this.discCount = 1,
    this.tracks = const [],
  });

  final String mbid;
  final String title;

  /// Joined artist-credit string verbatim ("A feat. B"). Compilations
  /// come back as "Various Artists" from MB itself.
  final String artistCredit;
  final int? year;
  final int discCount;
  final List<MbTrack> tracks;

  MbTrack? trackAt({int? disc, int? position, String? recordingMbid}) {
    if (recordingMbid != null) {
      for (final t in tracks) {
        if (t.recordingMbid == recordingMbid) return t;
      }
    }
    if (position != null) {
      for (final t in tracks) {
        if (t.position == position && (disc == null || t.disc == disc)) {
          return t;
        }
      }
    }
    return null;
  }
}

class MbSearchHit {
  MbSearchHit({required this.mbid, required this.title,
      required this.artist, this.year, this.score = 0});
  final String mbid;
  final String title;
  final String artist;
  final int? year;
  final int score;
}

String joinArtistCredit(List<dynamic>? credit) {
  if (credit == null) return '';
  final buf = StringBuffer();
  for (final c in credit.cast<Map<String, dynamic>>()) {
    buf.write(c['name'] ?? c['artist']?['name'] ?? '');
    buf.write(c['joinphrase'] ?? '');
  }
  return buf.toString();
}

int? _yearOf(String? date) {
  final m = RegExp(r'^(\d{4})').firstMatch(date ?? '');
  return m == null ? null : int.parse(m.group(1)!);
}

/// MusicBrainz client: 1 req/s throttle (MB terms), disk cache so a
/// 50-album batch does one lookup per release ever.
class MusicBrainz {
  MusicBrainz({required this.cacheDir, http.Client? client})
      : _client = client ?? http.Client();

  final Directory cacheDir;
  final http.Client _client;
  DateTime _lastCall = DateTime.fromMillisecondsSinceEpoch(0);

  Future<Map<String, dynamic>?> _get(String pathAndQuery) async {
    final cacheFile = File(p.join(cacheDir.path,
        '${sha1.convert(utf8.encode(pathAndQuery))}.json'));
    if (cacheFile.existsSync()) {
      try {
        return jsonDecode(cacheFile.readAsStringSync())
            as Map<String, dynamic>;
      } catch (_) {}
    }
    // MB throttles per-IP and 503s freely; retry a couple of times with
    // backoff on top of the 1 req/s pacing.
    for (var attempt = 0; attempt < 3; attempt++) {
      final wait = const Duration(seconds: 1) -
          DateTime.now().difference(_lastCall);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      _lastCall = DateTime.now();
      try {
        final res = await _client.get(Uri.parse('$_mbBase$pathAndQuery'),
            headers: {
              'User-Agent': kUserAgent,
              'Accept': 'application/json'
            }).timeout(const Duration(seconds: 30));
        if (res.statusCode == 200) {
          cacheDir.createSync(recursive: true);
          cacheFile.writeAsStringSync(res.body);
          return jsonDecode(res.body) as Map<String, dynamic>;
        }
        if (res.statusCode == 404) return null;
      } catch (_) {
        // fall through to retry
      }
      await Future<void>.delayed(Duration(seconds: 2 * (attempt + 1)));
    }
    return null;
  }

  Future<MbRelease?> release(String mbid) async {
    final doc = await _get(
        '/release/$mbid?inc=artist-credits+recordings+media&fmt=json');
    if (doc == null) return null;
    final media = (doc['media'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();
    final tracks = <MbTrack>[];
    var disc = 0;
    for (final m in media) {
      disc = (m['position'] as num?)?.toInt() ?? disc + 1;
      for (final t in (m['tracks'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>()) {
        tracks.add(MbTrack(
          position: (t['position'] as num?)?.toInt() ?? 0,
          title: '${t['title'] ?? t['recording']?['title'] ?? ''}',
          disc: disc,
          artistCredit: t['artist-credit'] != null
              ? joinArtistCredit(t['artist-credit'] as List<dynamic>)
              : null,
          recordingMbid: t['recording']?['id']?.toString(),
        ));
      }
    }
    return MbRelease(
      mbid: '${doc['id'] ?? mbid}',
      title: '${doc['title'] ?? ''}',
      artistCredit: joinArtistCredit(doc['artist-credit'] as List<dynamic>?),
      year: _yearOf(doc['date']?.toString()),
      discCount: media.isEmpty ? 1 : media.length,
      tracks: tracks,
    );
  }

  /// Lucene release search (natively fuzzy). Returns hits best-first.
  Future<List<MbSearchHit>> searchReleases(String artist, String album,
      {int limit = 5}) async {
    String esc(String s) =>
        s.replaceAllMapped(RegExp(r'[+\-&|!(){}\[\]^"~*?:\\/]'), (m) => ' ');
    final query = Uri.encodeQueryComponent(
        'release:"${esc(album)}" AND artist:"${esc(artist)}"');
    final doc = await _get('/release/?query=$query&limit=$limit&fmt=json');
    if (doc == null) return const [];
    return [
      for (final r in (doc['releases'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>())
        MbSearchHit(
          mbid: '${r['id']}',
          title: '${r['title'] ?? ''}',
          artist: joinArtistCredit(r['artist-credit'] as List<dynamic>?),
          year: _yearOf(r['date']?.toString()),
          score: (r['score'] as num?)?.toInt() ?? 0,
        ),
    ];
  }

  /// Which release does this recording belong to? Used by the AcoustID
  /// path: fingerprint → recording mbid → its releases.
  Future<List<String>> releasesOfRecording(String recordingMbid) async {
    final doc =
        await _get('/recording/$recordingMbid?inc=releases&fmt=json');
    if (doc == null) return const [];
    return [
      for (final r in (doc['releases'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>())
        '${r['id']}',
    ];
  }

  /// Cover Art Archive front cover (500px) for a release — square CAA
  /// front as-is per the music edge-case decisions. No key needed.
  /// In-memory cached per release (definitive answers only, so a whole
  /// album resolving track by track fetches its cover once; transport
  /// errors stay retryable).
  Future<List<int>?> caaFrontCover(String releaseMbid) async {
    if (_caaCache.containsKey(releaseMbid)) return _caaCache[releaseMbid];
    try {
      final res = await _client.get(
          Uri.parse('https://coverartarchive.org/release/$releaseMbid'
              '/front-500'),
          headers: {'User-Agent': kUserAgent});
      if (res.statusCode == 200) return _caaCache[releaseMbid] = res.bodyBytes;
      if (res.statusCode == 404) return _caaCache[releaseMbid] = null;
      return null;
    } catch (_) {
      return null;
    }
  }

  final _caaCache = <String, List<int>?>{};

  void close() => _client.close();
}
