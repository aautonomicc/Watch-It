import 'dart:async';
import 'dart:io';
import 'dart:math' show min;

import 'package:flutter/services.dart';

import 'download_manager.dart';

/// Mirrors the download queue into the Android foreground service
/// (`DownloadForegroundService`), which is what keeps transfers running
/// with the screen off: Android 12+ freezes cached app processes — the
/// Dart pump *and* the embedded Rust client — and Doze cuts their
/// network. The service holds a partial wakelock + Wi-Fi lock and shows
/// an ongoing silent notification with the queue's progress
/// ("Downloading 2 of 5 · 43%"). Tapping it opens the app.
///
/// The pump itself stays in Dart untouched; this bridge only tells the
/// platform side when the queue goes active (start), roughly once a
/// second while it moves (update), and when it drains or pauses (stop).
/// On Android 15+ the dataSync service class has a ~6h/day budget; when
/// it runs out the service calls back and the queue system-pauses —
/// reopening the app resumes from the bytes on disk.
///
/// No-op everywhere but Android.
class DownloadForegroundBridge {
  DownloadForegroundBridge({MethodChannel? channel, bool? isAndroid})
      : _channel = channel ?? const MethodChannel('watchit/downloads'),
        _isAndroid = isAndroid ?? Platform.isAndroid;

  /// Replaceable for tests (fresh instance per test).
  static DownloadForegroundBridge instance = DownloadForegroundBridge();

  final MethodChannel _channel;
  final bool _isAndroid;
  DownloadManager? _manager;
  bool _running = false;
  bool _requestedNotifications = false;
  DateTime _lastSync = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _trailing;

  /// Progress updates are throttled to one per this interval.
  static const syncInterval = Duration(seconds: 1);

  void bind(DownloadManager manager) {
    if (!_isAndroid) return;
    _manager?.removeListener(_onQueueChanged);
    _manager = manager;
    manager.addListener(_onQueueChanged);
    _channel.setMethodCallHandler(_onPlatformCall);
  }

  Future<Object?> _onPlatformCall(MethodCall call) async {
    if (call.method == 'onTimeout') {
      // Android's dataSync budget ran out: park the queue as a system
      // pause. Resume-from-byte loses nothing; the next app open (or
      // connectivity event) restarts it.
      _running = false;
      await _manager?.systemPauseAll();
    }
    return null;
  }

  /// Device manufacturer (lowercase), for the Samsung battery tip card.
  /// Empty off Android or on channel failure.
  Future<String> manufacturer() async {
    if (!_isAndroid) return '';
    try {
      final m = await _channel.invokeMethod<String>('manufacturer');
      return (m ?? '').toLowerCase();
    } catch (_) {
      return '';
    }
  }

  void _onQueueChanged() {
    final since = DateTime.now().difference(_lastSync);
    if (since >= syncInterval) {
      _lastSync = DateTime.now();
      unawaited(_sync());
    } else {
      // Trailing sync so the final state (drained → stop) always lands.
      _trailing ??= Timer(syncInterval - since, () {
        _trailing = null;
        _lastSync = DateTime.now();
        unawaited(_sync());
      });
    }
  }

  Future<void> _sync() async {
    final manager = _manager;
    if (manager == null) return;
    final batch = manager.hasActive ? manager.batchProgress : null;
    if (batch == null) {
      if (_running) {
        _running = false;
        try {
          await _channel.invokeMethod('stop');
        } catch (_) {}
      }
      return;
    }
    DownloadTask? current;
    for (final task in manager.tasks) {
      if (task.status == DownloadStatus.downloading) {
        current = task;
        break;
      }
      if (current == null && task.status == DownloadStatus.queued) {
        current = task;
      }
    }
    final percent = (batch.progress * 100).round();
    final args = <String, Object?>{
      'title': batch.total > 1
          ? 'Downloading ${min(batch.done + 1, batch.total)} of '
              '${batch.total} · $percent%'
          : 'Downloading · $percent%',
      'text': current?.name ?? '',
      'percent': percent,
    };
    if (!_running) {
      _running = true;
      if (!_requestedNotifications) {
        // Android 13+ runtime notification permission, asked on the
        // first enqueue of the session. Denial only costs the progress
        // notification/background guarantee — downloads still run in
        // the foreground.
        _requestedNotifications = true;
        try {
          await _channel.invokeMethod('requestNotifications');
        } catch (_) {}
      }
      try {
        await _channel.invokeMethod('start', args);
      } catch (_) {
        _running = false; // no service; foreground downloads still work
      }
    } else {
      try {
        await _channel.invokeMethod('update', args);
      } catch (_) {}
    }
  }
}
