import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device settings, deliberately separate from per-profile appearance.
/// A wide phone/tablet is not a TV: Android supplies its actual UI mode.
class TvSettings extends ChangeNotifier {
  TvSettings({this.enabled = false});

  static TvSettings instance = TvSettings();
  static const channel = MethodChannel('watchit/device');
  bool enabled;
  int marginPercent = 5;
  bool grove = false;

  Future<void> initialize() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      enabled = await channel.invokeMethod<bool>('isTelevision') ?? false;
    } on MissingPluginException {
      enabled = false;
    } on PlatformException {
      enabled = false;
    }
    if (!enabled) return;
    final prefs = await SharedPreferences.getInstance();
    marginPercent = (prefs.getInt('tv_margin_percent_v1') ?? 5).clamp(0, 10);
    grove = prefs.getBool('tv_grove_v1') ?? false;
  }

  Future<void> setMargin(int value) async {
    marginPercent = value.clamp(0, 10);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('tv_margin_percent_v1', marginPercent);
  }

  Future<void> setGrove(bool value) async {
    grove = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('tv_grove_v1', value);
  }
}
