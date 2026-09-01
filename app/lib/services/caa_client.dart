import 'package:http/http.dart' as http;

/// Transport failure talking to the Cover Art Archive (offline, 5xx).
/// Distinct from "the release has no cover art", which is a `null`
/// fetch result — only genuine no-art answers are cached.
class CaaException implements Exception {
  const CaaException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'CaaException($statusCode): $message';
}

/// Minimal Cover Art Archive client: keyless GET of a release's front
/// cover by MusicBrainz release id — no API key, no auth, no rate-limit
/// registration (unlike the MusicBrainz API itself). The endpoint
/// redirects to the archive.org file; `http` follows redirects.
class CaaClient {
  CaaClient({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;

  static const _base = 'https://coverartarchive.org/release';

  /// Front cover bytes at 500px (plenty for the 120–240px album tiles at
  /// 2–3x DPR), or `null` when the release has no cover art (404).
  /// Throws [CaaException] on transport/server errors.
  Future<List<int>?> fetchFront(String releaseMbid) async {
    final http.Response resp;
    try {
      resp = await _http
          .get(Uri.parse('$_base/$releaseMbid/front-500'))
          .timeout(const Duration(seconds: 30));
    } catch (e) {
      throw CaaException('$e');
    }
    if (resp.statusCode == 404) return null;
    if (resp.statusCode != 200) {
      throw CaaException('cover fetch failed', statusCode: resp.statusCode);
    }
    return resp.bodyBytes;
  }

  void close() => _http.close();
}
