import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';

/// Keeps the desktop session from locking while media plays.
///
/// media_kit's Video widget already holds a wakelock during playback
/// (wakelock_plus: FLAG_KEEP_SCREEN_ON on Android, SetThreadExecutionState
/// on Windows, IOKit on macOS), but its Linux path goes through the
/// org.freedesktop.portal.Inhibit portal only, and swallows failures —
/// sessions without a working xdg-desktop-portal lock the screen mid-film.
/// This service holds a parallel inhibit through the older
/// org.freedesktop.ScreenSaver interface, which GNOME Shell, KDE, Cinnamon,
/// MATE and XFCE all serve directly. Non-Linux platforms are no-ops.
class ScreenWake {
  ScreenWake({@visibleForTesting DBusRemoteObject Function()? objectFactory})
      : _objectFactory = objectFactory ?? _sessionScreenSaver;

  static final ScreenWake instance = ScreenWake();

  static DBusRemoteObject _sessionScreenSaver() => DBusRemoteObject(
        DBusClient.session(),
        name: 'org.freedesktop.ScreenSaver',
        path: DBusObjectPath('/org/freedesktop/ScreenSaver'),
      );

  final DBusRemoteObject Function() _objectFactory;
  DBusRemoteObject? _object;
  int? _cookie;
  bool _want = false;

  /// Serializes acquire/release so a fast pause/play cannot interleave
  /// D-Bus calls and leak a cookie.
  Future<void> _queue = Future.value();

  /// Awaitable point where all queued D-Bus work has settled.
  @visibleForTesting
  Future<void> get idle => _queue;

  /// Inhibit the screensaver/lock while [playing]; release otherwise.
  /// Cheap to call repeatedly with the same value.
  void setPlaying(bool playing) {
    if (kIsWeb || !Platform.isLinux) return;
    if (_want == playing) return;
    _want = playing;
    _queue = _queue.then((_) => _apply());
  }

  Future<void> _apply() async {
    try {
      if (_want && _cookie == null) {
        _object ??= _objectFactory();
        final reply = await _object!.callMethod(
          'org.freedesktop.ScreenSaver',
          'Inhibit',
          const [DBusString('W@tch'), DBusString('Playing media')],
          replySignature: DBusSignature('u'),
        );
        _cookie = reply.returnValues.single.asUint32();
      } else if (!_want && _cookie != null) {
        final cookie = _cookie!;
        _cookie = null;
        await _object!.callMethod(
          'org.freedesktop.ScreenSaver',
          'UnInhibit',
          [DBusUint32(cookie)],
          replySignature: DBusSignature(''),
        );
      }
    } on Object {
      // No org.freedesktop.ScreenSaver service on this session — the
      // portal-based wakelock media_kit holds is the remaining guard.
    }
  }
}
