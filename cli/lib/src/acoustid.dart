import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// AcoustID audio-fingerprint lookup — the gold standard for identifying
/// a recording regardless of file name (the beets/Picard pipeline).
/// Needs `fpcalc` (chromaprint) on PATH and a free API key
/// (`acoustid_key` in config.yaml / ACOUSTID_API_KEY). Both optional:
/// when either is missing the matcher just skips to MusicBrainz search.
/// AcoustID runs once per file at prepare — never at upload.
class AcoustIdHit {
  AcoustIdHit({required this.recordingMbid, required this.score,
      this.title, this.artist});
  final String recordingMbid;
  final double score;
  final String? title;
  final String? artist;
}

Future<bool> fpcalcAvailable() async {
  try {
    final r = await Process.run('fpcalc', ['-version']);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<List<AcoustIdHit>> acoustidLookup(String filePath, String apiKey,
    {http.Client? client}) async {
  final String fingerprint;
  final int duration;
  try {
    final r = await Process.run('fpcalc', ['-json', filePath]);
    if (r.exitCode != 0) return const [];
    final doc = jsonDecode(r.stdout as String) as Map<String, dynamic>;
    fingerprint = '${doc['fingerprint']}';
    duration = (doc['duration'] as num).round();
  } catch (_) {
    return const [];
  }
  final ownClient = client == null;
  client ??= http.Client();
  try {
    final res = await client.post(
      Uri.parse('https://api.acoustid.org/v2/lookup'),
      body: {
        'client': apiKey,
        'duration': '$duration',
        'fingerprint': fingerprint,
        'meta': 'recordings',
      },
    );
    if (res.statusCode != 200) return const [];
    final doc = jsonDecode(res.body) as Map<String, dynamic>;
    if (doc['status'] != 'ok') return const [];
    final hits = <AcoustIdHit>[];
    for (final result in (doc['results'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>()) {
      final score = (result['score'] as num?)?.toDouble() ?? 0;
      for (final rec in (result['recordings'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>()) {
        final id = rec['id'];
        if (id is String) {
          hits.add(AcoustIdHit(
            recordingMbid: id,
            score: score,
            title: rec['title']?.toString(),
            artist: ((rec['artists'] as List<dynamic>?)?.firstOrNull
                    as Map<String, dynamic>?)?['name']
                ?.toString(),
          ));
        }
      }
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits;
  } catch (_) {
    return const [];
  } finally {
    if (ownClient) client.close();
  }
}
