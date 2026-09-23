import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ffmpeg.dart';

/// Frame source seam for tests: seconds in, JPEG bytes (or null) out.
typedef SeekFrameExtractor = Future<Uint8List?> Function(double atSeconds);

/// Thumbnail cache behind the seek bar's hover preview.
///
/// LOCAL FILES ONLY by policy: ffmpeg seeking a downloaded file returns a
/// frame in ~100–300 ms, real hover territory; seeking the streamed
/// `/xor` URL would open a fresh network prefetch window per hover point
/// (seconds to tens of seconds each, competing with playback), so
/// PlayerScreen never builds one of these for a network stream.
///
/// Positions fold into [bucketSeconds] buckets so a sweep along the bar
/// resolves to a bounded set of frames; requests are debounced (only a
/// pointer that RESTS somewhere costs a grab), grabs run one at a time
/// (FfmpegService tracks a single frame process), failures are cached so
/// a broken timestamp is never hammered, and the cache is a small LRU.
class SeekPreview extends ChangeNotifier {
  SeekPreview({
    required String source,
    SeekFrameExtractor? extractor,
    this.bucketSeconds = 5,
    this.debounce = const Duration(milliseconds: 180),
    this.maxEntries = 64,
  }) : _extractor = extractor ?? _ffmpegExtractor(source);

  /// Hover positions within the same bucket share one frame.
  final int bucketSeconds;

  /// Quiet time required before a grab starts.
  final Duration debounce;

  /// LRU cap on cached frames.
  final int maxEntries;

  final SeekFrameExtractor _extractor;

  // Insertion-ordered → oldest first; re-inserting on hit keeps it LRU.
  final _cache = <int, Uint8List>{};
  final _failed = <int>{};
  Timer? _timer;
  bool _inFlight = false;
  bool _disposed = false;
  int _wanted = -1;

  static SeekFrameExtractor _ffmpegExtractor(String source) {
    final ffmpeg = FfmpegService();
    return (atSeconds) =>
        ffmpeg.extractFrame(source: source, atSeconds: atSeconds, maxHeight: 180);
  }

  int bucketFor(Duration position) {
    final seconds = position.inSeconds;
    return seconds <= 0 ? 0 : seconds ~/ bucketSeconds;
  }

  /// The timestamp a bucket's frame is grabbed at (bucket middle — the
  /// keyframe fast-seek snaps anyway, and 0.0 is often a black frame).
  double secondsFor(int bucket) => bucket * bucketSeconds + bucketSeconds / 2;

  /// The cached frame covering [position], or null — in which case a
  /// debounced grab is scheduled and listeners fire when it lands.
  Uint8List? frameFor(Duration position) {
    final bucket = bucketFor(position);
    final cached = _cache.remove(bucket);
    if (cached != null) {
      _cache[bucket] = cached; // Refresh LRU position.
      return cached;
    }
    if (_failed.contains(bucket)) return null;
    _wanted = bucket;
    _timer?.cancel();
    _timer = Timer(debounce, _pump);
    return null;
  }

  Future<void> _pump() async {
    if (_disposed || _inFlight) return;
    final bucket = _wanted;
    if (bucket < 0 || _cache.containsKey(bucket) || _failed.contains(bucket)) {
      return;
    }
    _inFlight = true;
    Uint8List? bytes;
    try {
      bytes = await _extractor(secondsFor(bucket));
    } catch (_) {
      bytes = null;
    }
    _inFlight = false;
    if (_disposed) return;
    if (bytes == null || bytes.isEmpty) {
      _failed.add(bucket);
    } else {
      _cache[bucket] = bytes;
      while (_cache.length > maxEntries) {
        _cache.remove(_cache.keys.first);
      }
    }
    notifyListeners();
    // The pointer moved on while this grab ran — chase the newest bucket.
    if (_wanted != bucket &&
        !_cache.containsKey(_wanted) &&
        !_failed.contains(_wanted)) {
      unawaited(_pump());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
