import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

/// Pref slot for the remembered desktop window geometry.
const kWindowStatePref = 'window_state_v1';

/// Runtime minimum — below this the layout stops being usable (and the
/// runners hardcode no minimum at all, so the window could collapse to a
/// sliver). Deliberately under the 1000px pinned-drawer breakpoint: both
/// home layouts stay reachable by resizing.
const Size kMinWindowSize = Size(800, 600);

/// Remembered window geometry: last normal (unmaximized) bounds plus
/// whether the window was maximized. Pure codec — unit-tested; the
/// window_manager calls live in [WindowStateKeeper].
class WindowStateData {
  const WindowStateData({
    this.x,
    this.y,
    required this.width,
    required this.height,
    this.maximized = false,
  });

  /// Top-left position; null = let the OS place the window.
  final double? x;
  final double? y;
  final double width;
  final double height;
  final bool maximized;

  /// Stored size with the minimum applied (a pref written by a future
  /// build, or hand-edited, must never restore an unusable window).
  Size get sanitizedSize => Size(
        width.isFinite ? width.clamp(kMinWindowSize.width, 100000) : 1280,
        height.isFinite ? height.clamp(kMinWindowSize.height, 100000) : 720,
      );

  /// Position when both coordinates are sane, else null (never restore a
  /// window to NaN/absurd coordinates — off-screen on a detached monitor
  /// is fine, the OS window manager handles that).
  Offset? get sanitizedPosition {
    final px = x, py = y;
    if (px == null || py == null || !px.isFinite || !py.isFinite) return null;
    if (px.abs() > 100000 || py.abs() > 100000) return null;
    return Offset(px, py);
  }

  String encode() => jsonEncode({
        if (x != null) 'x': x,
        if (y != null) 'y': y,
        'w': width,
        'h': height,
        'max': maximized,
      });

  /// Tolerant decode — null on garbage (the window just opens at the
  /// runner default).
  static WindowStateData? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      double? num_(dynamic v) => v is num ? v.toDouble() : null;
      final w = num_(json['w']);
      final h = num_(json['h']);
      if (w == null || h == null) return null;
      return WindowStateData(
        x: num_(json['x']),
        y: num_(json['y']),
        width: w,
        height: h,
        maximized: json['max'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Desktop window polish: enforces a minimum size and remembers
/// size/position/maximized across launches (the runners hardcode
/// 1280×720 and no minimum). Started once from main(); no-op off
/// desktop. Saves are debounced off window_manager's resize/move events.
class WindowStateKeeper with WindowListener {
  WindowStateKeeper._();

  static final WindowStateKeeper instance = WindowStateKeeper._();

  static bool get supported =>
      !kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS);

  Timer? _debounce;
  bool _started = false;

  /// Last known unmaximized bounds — kept so maximizing doesn't clobber
  /// the size the window should restore to next launch.
  Rect? _normalBounds;
  bool _maximized = false;

  Future<void> start() async {
    if (!supported || _started) return;
    _started = true;
    await windowManager.ensureInitialized();
    await windowManager.setMinimumSize(kMinWindowSize);
    final prefs = await SharedPreferences.getInstance();
    final stored = WindowStateData.decode(prefs.getString(kWindowStatePref));
    if (stored != null) {
      final size = stored.sanitizedSize;
      final position = stored.sanitizedPosition;
      _normalBounds = Rect.fromLTWH(
        position?.dx ?? 0,
        position?.dy ?? 0,
        size.width,
        size.height,
      );
      await windowManager.setSize(size);
      if (position != null) await windowManager.setPosition(position);
      if (stored.maximized) await windowManager.maximize();
    }
    windowManager.addListener(this);
  }

  @override
  void onWindowResize() => _scheduleSave();
  @override
  void onWindowResized() => _scheduleSave();
  @override
  void onWindowMove() => _scheduleSave();
  @override
  void onWindowMoved() => _scheduleSave();
  @override
  void onWindowMaximize() => _scheduleSave();
  @override
  void onWindowUnmaximize() => _scheduleSave();

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () {
      unawaited(_save());
    });
  }

  Future<void> _save() async {
    try {
      _maximized = await windowManager.isMaximized();
      if (!_maximized) _normalBounds = await windowManager.getBounds();
      final bounds = _normalBounds;
      if (bounds == null) return;
      final data = WindowStateData(
        x: bounds.left,
        y: bounds.top,
        width: bounds.width,
        height: bounds.height,
        maximized: _maximized,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kWindowStatePref, data.encode());
    } catch (_) {
      // Window gone mid-save (app closing) — nothing to persist.
    }
  }
}
