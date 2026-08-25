import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Desktop update check-and-notify.
///
/// At most once per 24h on startup, asks GitHub for the latest release
/// and compares its tag to the running version; a newer one sets
/// [availableTag]/[releaseUrl] and notifies (main.dart shows a quiet
/// snackbar, Settings → About grows a row). Failures are silent —
/// offline must never nag. This is the app's only phone-home besides the
/// Autonomi network and the user's own TMDB key, so it sits behind a
/// visible Settings toggle (default ON) and is skipped entirely on
/// mobile (an APK can't self-serve an install anyway).
class UpdateCheck extends ChangeNotifier {
  UpdateCheck._();
  static UpdateCheck instance = UpdateCheck._();

  @visibleForTesting
  static void resetForTesting() => instance = UpdateCheck._();

  static const enabledPref = 'update_check_enabled_v1';
  static const lastCheckPref = 'update_check_last_v1';
  static const releasePage =
      'https://github.com/aautonomicc/Watch-It/releases/latest';
  static const _api =
      'https://api.github.com/repos/aautonomicc/Watch-It/releases/latest';

  /// Test seam for the HTTP call.
  @visibleForTesting
  http.Client? client;

  String? availableTag;
  String? releaseUrl;

  bool get updateAvailable => availableTag != null;

  static Future<bool> enabled() async =>
      (await SharedPreferences.getInstance()).getBool(enabledPref) ?? true;

  static Future<void> setEnabled(bool value) async {
    await (await SharedPreferences.getInstance())
        .setBool(enabledPref, value);
  }

  /// Startup entry point; no-op on mobile, when switched off, or within
  /// 24h of the last successful check.
  Future<void> maybeCheck({DateTime Function() now = DateTime.now}) async {
    if (!Platform.isLinux && !Platform.isWindows && !Platform.isMacOS) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(enabledPref) ?? true)) return;
    final nowMs = now().millisecondsSinceEpoch;
    final last = prefs.getInt(lastCheckPref) ?? 0;
    if (nowMs - last < const Duration(hours: 24).inMilliseconds) return;
    final ownsClient = client == null;
    final c = client ?? http.Client();
    try {
      final res = await c.get(Uri.parse(_api),
          headers: {'accept': 'application/vnd.github+json'});
      if (res.statusCode != 200) return;
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final tag = json['tag_name'] as String? ?? '';
      final info = await PackageInfo.fromPlatform();
      // Stamp only after a successful fetch — a failed/offline attempt
      // retries on the next launch instead of waiting a day.
      await prefs.setInt(lastCheckPref, nowMs);
      if (isNewerTag(tag, info.version, info.buildNumber)) {
        availableTag = tag;
        releaseUrl = json['html_url'] as String? ?? releasePage;
        notifyListeners();
      }
    } catch (_) {
      // Silent by design.
    } finally {
      if (ownsClient) c.close();
    }
  }

  /// Is release [tag] (`v0.1.0-alpha.57`) newer than the running
  /// `version` + `buildNumber` (`0.1.0` + `57`, where the build number is
  /// the alpha number)? A stable tag (no `-alpha.N`) of the same semver
  /// counts as newer than any alpha. Unparseable tags are never newer.
  static bool isNewerTag(String tag, String version, String buildNumber) {
    final match = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:-alpha\.(\d+))?$')
        .firstMatch(tag.trim());
    if (match == null) return false;
    final current =
        version.split('.').map(int.tryParse).toList(growable: false);
    if (current.length != 3 || current.contains(null)) return false;
    for (var i = 0; i < 3; i++) {
      final tagPart = int.parse(match.group(i + 1)!);
      if (tagPart != current[i]) return tagPart > current[i]!;
    }
    final tagAlpha = match.group(4);
    if (tagAlpha == null) return true;
    return int.parse(tagAlpha) > (int.tryParse(buildNumber) ?? 0);
  }
}
