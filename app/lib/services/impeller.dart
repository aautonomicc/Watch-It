import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'tv_settings.dart';

/// Per-device Impeller opt-out (Android only). Flutter's Impeller
/// renderer draws video as a black picture on Tegra GPUs — confirmed on
/// the Nvidia Shield by the alpha.101 A/B test builds — so MainActivity
/// decides at engine startup whether to pass `--enable-impeller=false`
/// to the Flutter shell: an explicit choice stored under [prefKey] wins,
/// otherwise known Tegra devices (Nvidia Shield family) default to
/// disabled. The Kotlin side owns both the preference read (it runs
/// before the Dart isolate exists) and the device detection; this class
/// is the Dart mirror the Settings toggle drives. A change only takes
/// effect after the app is fully closed and reopened.
class ImpellerSettings {
  static const prefKey = 'disable_impeller_v1';

  /// Whether this device disables Impeller by default (known Tegra
  /// hardware) — cached by [initialize] from the Kotlin side, so the
  /// detection lives in exactly one place: the same check MainActivity
  /// applies at launch. Widget tests set it directly (an unmocked
  /// channel call would hang the fake-async test zone).
  static bool deviceDefaultOff = false;

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

  /// The stored explicit choice, or null while the toggle was never
  /// touched (then [defaultDisabled] applies).
  static Future<bool?> explicit() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(prefKey);
  }

  /// What MainActivity will do at the next launch.
  static Future<bool> effectiveDisabled() async =>
      await explicit() ?? deviceDefaultOff;

  static Future<void> setDisabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefKey, value);
  }
}
