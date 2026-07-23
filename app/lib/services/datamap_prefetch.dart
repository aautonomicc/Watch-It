import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../models/media_list.dart';
import 'embedded_client.dart';

/// Prefetch of root data maps via the embedded client's `/resolve`
/// endpoint.
///
/// A file's data map must be resolved (fetched and, for large files,
/// unshrunk level by level) before its first byte can play — several
/// seconds of chunk fetches for a movie. The embedded client persists
/// every resolved map in SQLite, so resolving a list's maps right after
/// import makes the *first* play of each title start fast; without the
/// prefetch the map is persisted on first play instead (second play fast).
class PrefetchResult {
  const PrefetchResult({
    required this.done,
    required this.failed,
    required this.cancelled,
  });

  /// Addresses successfully resolved (or already cached).
  final int done;

  /// Addresses that could not be resolved (network errors — the map is
  /// simply resolved on first play instead).
  final int failed;

  /// True when [DataMapPrefetcher.cancel] stopped the run early.
  final bool cancelled;
}

class DataMapPrefetcher {
  DataMapPrefetcher({String? base}) : _base = base ?? EmbeddedClient.baseUrl();

  /// Addresses already warmed (or being warmed) this session by [warm].
  static final Set<String> _warmed = {};

  /// Fire-and-forget resolve of one entry's data map, called when the
  /// entry's detail page opens: by the time the user presses Play the map
  /// is resolved (or resolving — the embedded client single-flights the
  /// underlying chunk fetches), so playback starts as fast as possible.
  /// Each address is attempted once per session; failures are silent
  /// because playback resolves the map itself anyway.
  static Future<bool> warm(MediaEntry entry, {String? base}) async {
    final addr = entry.address.toLowerCase().replaceFirst('0x', '');
    if (!_warmed.add(addr)) return false;
    final prefetcher = DataMapPrefetcher(base: base);
    if (!prefetcher.available) {
      _warmed.remove(addr);
      return false;
    }
    final ok = await prefetcher._resolve(entry);
    prefetcher._client.close(force: true);
    // Transient failure (still connecting, network hiccup): allow a later
    // page open to try again.
    if (!ok) _warmed.remove(addr);
    return ok;
  }

  @visibleForTesting
  static void resetWarmedForTesting() => _warmed.clear();

  final String? _base;
  final HttpClient _client = HttpClient();
  bool _cancelled = false;

  /// Whether prefetching is possible (embedded client running).
  bool get available => _base != null;

  /// Stop after the file currently being resolved; the in-flight request
  /// is aborted.
  void cancel() {
    _cancelled = true;
    _client.close(force: true);
  }

  /// Resolve the data map of every entry, one file at a time so progress
  /// is honest. Duplicate addresses are resolved once. [onProgress] fires
  /// before each file with the 1-based number, the total, and the file
  /// name being fetched.
  Future<PrefetchResult> run(
    List<MediaEntry> entries, {
    void Function(int current, int total, String name)? onProgress,
  }) async {
    final seen = <String>{};
    final unique = [
      for (final e in entries)
        if (seen.add(e.address.toLowerCase().replaceFirst('0x', ''))) e,
    ];
    var done = 0, failed = 0;
    for (var i = 0; i < unique.length; i++) {
      if (_cancelled) break;
      final entry = unique[i];
      onProgress?.call(i + 1, unique.length, entry.name);
      if (await _resolve(entry)) {
        done++;
      } else if (!_cancelled) {
        failed++;
      }
    }
    _client.close(force: true);
    return PrefetchResult(done: done, failed: failed, cancelled: _cancelled);
  }

  /// One `/resolve/<addr>` call; true on HTTP 200 with a parsable body.
  Future<bool> _resolve(MediaEntry entry) async {
    final base = _base;
    if (base == null) return false;
    final addr = entry.address.toLowerCase().replaceFirst('0x', '');
    try {
      final req = await _client.getUrl(Uri.parse('$base/resolve/$addr'));
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) return false;
      jsonDecode(body);
      return true;
    } catch (_) {
      return false;
    }
  }
}
