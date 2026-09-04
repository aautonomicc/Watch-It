import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'now_playing.dart';

/// Mirrors [NowPlaying] into the Android media playback service
/// (`MediaPlaybackService`), which is what keeps music audible with the
/// screen off: Android 12+ freezes cached app processes — mpv *and* the
/// embedded Rust client — and Doze cuts their network. The service holds
/// a MediaSession (controls + track info in the notification shade and
/// on the lock screen, headset/Bluetooth buttons) plus a partial
/// wakelock + Wi-Fi lock while playing; the actual player stays 100% in
/// Dart/mpv.
///
/// State flows out over the `watchit/media_session` MethodChannel
/// (start/update/stop, throttled like the download bridge); button and
/// audio-focus events flow back and dispatch to the handlers the active
/// player registered on [NowPlaying].
///
/// No-op everywhere but Android.
class MediaSessionBridge {
  MediaSessionBridge({MethodChannel? channel, bool? isAndroid})
      : _channel = channel ?? const MethodChannel('watchit/media_session'),
        _isAndroid = isAndroid ?? Platform.isAndroid;

  /// Replaceable for tests (fresh instance per test).
  static MediaSessionBridge instance = MediaSessionBridge();

  final MethodChannel _channel;
  final bool _isAndroid;
  NowPlaying? _nowPlaying;
  bool _running = false;
  bool _requestedNotifications = false;
  DateTime _lastSync = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _trailing;

  /// State updates are throttled to one per this interval (the position
  /// stream ticks far more often).
  static const syncInterval = Duration(seconds: 1);

  void bind(NowPlaying nowPlaying) {
    if (!_isAndroid) return;
    _nowPlaying?.removeListener(_onChanged);
    _nowPlaying = nowPlaying;
    nowPlaying.addListener(_onChanged);
    _channel.setMethodCallHandler(_onPlatformCall);
  }

  Future<Object?> _onPlatformCall(MethodCall call) async {
    final np = _nowPlaying;
    if (np == null) return null;
    switch (call.method) {
      case 'onPlay':
        np.remotePlay();
      case 'onPause':
        np.remotePause();
      case 'onNext':
        np.remoteNext();
      case 'onPrevious':
        np.remotePrevious();
      case 'onSeek':
        final ms = (call.arguments as Map?)?['positionMs'] as int? ?? 0;
        np.remoteSeek(Duration(milliseconds: ms));
      case 'onStop':
        // The service is already gone — just end the Dart-side session.
        _running = false;
        np.remoteStop();
    }
    return null;
  }

  void _onChanged() {
    final since = DateTime.now().difference(_lastSync);
    if (since >= syncInterval) {
      _lastSync = DateTime.now();
      unawaited(_sync());
    } else {
      // Trailing sync so the final state (session ended → stop) always
      // lands.
      _trailing ??= Timer(syncInterval - since, () {
        _trailing = null;
        _lastSync = DateTime.now();
        unawaited(_sync());
      });
    }
  }

  Future<void> _sync() async {
    final np = _nowPlaying;
    if (np == null) return;
    final track = np.track;
    if (track == null) {
      if (_running) {
        _running = false;
        try {
          await _channel.invokeMethod('stop');
        } catch (_) {}
      }
      return;
    }
    final args = <String, Object?>{
      'title': track.title,
      'artist': track.artist ?? '',
      'album': track.album ?? '',
      'artworkPath': track.artworkPath ?? '',
      'playing': np.playing,
      'positionMs': np.position.inMilliseconds,
      'durationMs': np.duration.inMilliseconds,
      'canNext': np.canNext,
      'canPrev': np.canPrev,
    };
    if (!_running) {
      _running = true;
      if (!_requestedNotifications) {
        // Android 13+ runtime notification permission, asked on the
        // first playback session (the download bridge asks the same way
        // on the first enqueue). Denial only costs the notification —
        // foreground playback still works.
        _requestedNotifications = true;
        try {
          await _channel.invokeMethod('requestNotifications');
        } catch (_) {}
      }
      try {
        await _channel.invokeMethod('start', args);
      } catch (_) {
        _running = false; // no service; foreground playback still works
      }
    } else {
      try {
        await _channel.invokeMethod('update', args);
      } catch (_) {}
    }
  }
}
