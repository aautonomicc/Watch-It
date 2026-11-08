import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'tv_settings.dart';

/// Per-device Impeller opt-out (Android + Linux). Flutter's Impeller
/// renderer draws video as a black picture on Tegra GPUs — confirmed on
/// the Nvidia Shield by the alpha.101 A/B test builds — so MainActivity
/// decides at engine startup whether to pass `--enable-impeller=false`
/// to the Flutter shell: an explicit choice stored under [prefKey] wins,
/// otherwise known Tegra devices (Nvidia Shield family) default to
/// disabled. The Kotlin side owns both the preference read (it runs
/// before the Dart isolate exists) and the device detection; this class
/// is the Dart mirror the Settings toggle drives.
///
/// On Linux desktop (Impeller is this engine's default there too) the
/// runner reads a marker FILE instead — `impeller.off` in the app's data
/// directory, the one path both the C runner (`g_get_user_data_dir()/`
/// + the application id) and path_provider resolve identically — and falls
/// back to Skia when it exists; the `WATCHIT_IMPELLER` environment
/// variable overrides it for terminal A/B launches. The runner exports
/// its decision as `WATCHIT_RENDERER` (see [currentRenderer]). A change
/// only takes effect after the app is fully closed and reopened.
class ImpellerSettings {
  static const prefKey = 'disable_impeller_v1';
  static const linuxMarkerName = 'impeller.off';

  /// Platforms with a renderer opt-out.
  static bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.linux);

  static bool get _linux =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

  /// Whether this device disables Impeller by default (known Tegra
  /// hardware) — cached by [initialize] from the Kotlin side, so the
  /// detection lives in exactly one place: the same check MainActivity
  /// applies at launch. Widget tests set it directly (an unmocked
  /// channel call would hang the fake-async test zone). Always false on
  /// Linux.
  static bool deviceDefaultOff = false;

  /// Test seam: where the Linux marker lives (default: the app support
  /// directory).
  @visibleForTesting
  static Future<Directory> Function()? linuxMarkerDirOverride;

  /// Called once from main() before runApp, TvSettings-style.
  static Future<void> initialize() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      deviceDefaultOff =
          await TvSettings.channel.invokeMethod<bool>('impellerDefaultOff') ??
          false;
    } on MissingPluginException {
      deviceDefaultOff = false;
    } on PlatformException {
      deviceDefaultOff = false;
    }
  }

  /// The renderer the Linux runner chose for THIS launch (`impeller` or
  /// `skia`), null off Linux or on a runner predating the switch.
  static String? get currentRenderer =>
      kIsWeb ? null : Platform.environment['WATCHIT_RENDERER'];

  static Future<File> _linuxMarker() async {
    final dir = await (linuxMarkerDirOverride?.call() ??
        getApplicationSupportDirectory());
    return File(p.join(dir.path, linuxMarkerName));
  }

  /// The stored explicit choice, or null while the toggle was never
  /// touched (then [deviceDefaultOff] applies). On Linux the marker file
  /// IS the choice: present → true, absent → null (Impeller, the default).
  static Future<bool?> explicit() async {
    if (_linux) {
      return (await _linuxMarker()).existsSync() ? true : null;
    }
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(prefKey);
  }

  /// What the launcher will do at the next launch.
  static Future<bool> effectiveDisabled() async =>
      await explicit() ?? deviceDefaultOff;

  static Future<void> setDisabled(bool value) async {
    if (_linux) {
      final marker = await _linuxMarker();
      if (value) {
        marker.parent.createSync(recursive: true);
        marker.writeAsStringSync(
          'Settings → Graphics compatibility mode: the W@tch runner starts '
          'Flutter with Impeller disabled (Skia) while this file exists.\n',
        );
      } else if (marker.existsSync()) {
        marker.deleteSync();
      }
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefKey, value);
  }
}
