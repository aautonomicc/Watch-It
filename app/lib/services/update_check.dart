import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One downloadable file attached to a GitHub release.
@immutable
class UpdateAsset {
  const UpdateAsset({
    required this.name,
    required this.url,
    required this.size,
    this.sha256,
  });

  final String name;
  final String url;
  final int size;

  /// Lower-case hex sha256 from the API's `digest` field when GitHub
  /// provides one; downloads verify against it (size-only otherwise).
  final String? sha256;

  static UpdateAsset? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final name = json['name'];
    final url = json['browser_download_url'];
    if (name is! String || url is! String) return null;
    final digest = json['digest'];
    String? sha;
    if (digest is String && digest.startsWith('sha256:')) {
      sha = digest.substring('sha256:'.length).toLowerCase();
    }
    return UpdateAsset(
      name: name,
      url: url,
      size: json['size'] is int ? json['size'] as int : 0,
      sha256: sha,
    );
  }

  /// GitHub's own field shape, so [fromJson] round-trips a persisted
  /// asset exactly like an API one.
  Map<String, Object?> toJson() => {
        'name': name,
        'browser_download_url': url,
        'size': size,
        if (sha256 != null) 'digest': 'sha256:$sha256',
      };
}

/// What a user-triggered [UpdateCheck.checkNow] found, so Settings can
/// answer out loud where the background check stays silent.
enum UpdateCheckOutcome { updateFound, upToDate, failed }

/// Update check-and-notify, and the asset list the in-app updater
/// feeds from.
///
/// At most once per 24h — on startup and whenever the app returns to
/// the foreground (phones often go weeks without a cold start, so a
/// startup-only check never ran there) — asks GitHub for the latest
/// release and compares its tag to the running version; a newer one
/// sets [availableTag]/[releaseUrl]/[assets], persists the result so
/// later launches inside the throttle window still show it, and
/// notifies (main.dart shows a quiet snackbar, Settings → About grows
/// a row that can download and apply the update on Android, AppImage
/// Linux, Windows and installed macOS bundles). Failures are
/// silent — offline must never nag. This is the app's only phone-home
/// besides the Autonomi network and the user's own TMDB key, so it
/// sits behind a visible Settings toggle (default ON). Runs on desktop
/// and Android (iOS has no sideload path).
class UpdateCheck extends ChangeNotifier {
  UpdateCheck._();
  static UpdateCheck instance = UpdateCheck._();

  @visibleForTesting
  static void resetForTesting() => instance = UpdateCheck._();

  static const enabledPref = 'update_check_enabled_v1';
  static const lastCheckPref = 'update_check_last_v1';

  /// The last successful check's newer release, persisted so the
  /// Settings → About row (and the startup snackbar) survive the 24h
  /// throttle: without it, a launch inside the throttle window showed
  /// nothing at all — a rolling blind window on devices that rarely
  /// stay open long enough to pass a fresh check.
  static const availablePref = 'update_check_available_v1';
  static const releasePage =
      'https://github.com/aautonomicc/Watch-It/releases/latest';
  static const _api =
      'https://api.github.com/repos/aautonomicc/Watch-It/releases/latest';

  /// Platforms the check (and the Settings toggle) exist on.
  static bool get supportedPlatform =>
      Platform.isLinux ||
      Platform.isWindows ||
      Platform.isMacOS ||
      Platform.isAndroid;

  /// Test seam for the HTTP call.
  @visibleForTesting
  http.Client? client;

  String? availableTag;
  String? releaseUrl;

  /// The newer release's downloadable files (empty until a newer
  /// release is seen).
  List<UpdateAsset> assets = const [];

  bool get updateAvailable => availableTag != null;

  /// The release's regular APK (dual-ABI since alpha.98). Side assets
  /// like the historical `-tvtest` APKs are never offered.
  UpdateAsset? get apkAsset => assets
      .where((a) =>
          a.name.endsWith('.apk') && !a.name.contains('tvtest'))
      .firstOrNull;

  /// The release's Linux AppImage.
  UpdateAsset? get appImageAsset =>
      assets.where((a) => a.name.endsWith('.AppImage')).firstOrNull;

  /// The release's Windows portable zip (`…-windows-x64.zip`).
  UpdateAsset? get windowsZipAsset => assets
      .where((a) => a.name.endsWith('.zip') && a.name.contains('windows'))
      .firstOrNull;

  /// The release's macOS disk image (`…-macos-universal.dmg`).
  UpdateAsset? get macDmgAsset =>
      assets.where((a) => a.name.endsWith('.dmg')).firstOrNull;

  static Future<bool> enabled() async =>
      (await SharedPreferences.getInstance()).getBool(enabledPref) ?? true;

  static Future<void> setEnabled(bool value) async {
    await (await SharedPreferences.getInstance())
        .setBool(enabledPref, value);
  }

  /// Entry point on startup AND app resume; no-op on unsupported
  /// platforms or when switched off. A persisted earlier result is
  /// restored first so the update surfaces even inside the 24h
  /// throttle; the network check itself still runs at most once a day.
  Future<void> maybeCheck({DateTime Function() now = DateTime.now}) async {
    if (!supportedPlatform) return;
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(enabledPref) ?? true)) return;
    await _restorePersisted(prefs);
    final nowMs = now().millisecondsSinceEpoch;
    final last = prefs.getInt(lastCheckPref) ?? 0;
    if (nowMs - last < const Duration(hours: 24).inMilliseconds) return;
    await _fetchAndCompare(prefs, nowMs);
  }

  /// Explicit "check now" from Settings → About: skips the 24h
  /// throttle AND the startup-check toggle (pressing the button is its
  /// own consent), and reports the outcome — the silent-failure rule
  /// exists for background checks, not for a user asking directly.
  Future<UpdateCheckOutcome> checkNow(
      {DateTime Function() now = DateTime.now}) async {
    if (!supportedPlatform) return UpdateCheckOutcome.failed;
    final prefs = await SharedPreferences.getInstance();
    return _fetchAndCompare(prefs, now().millisecondsSinceEpoch);
  }

  /// One real GitHub fetch + compare. Shared by the throttled
  /// background path and [checkNow]; stamps [lastCheckPref] only on a
  /// successful fetch so failures retry on the next launch.
  Future<UpdateCheckOutcome> _fetchAndCompare(
      SharedPreferences prefs, int nowMs) async {
    final ownsClient = client == null;
    final c = client ?? http.Client();
    try {
      final res = await c.get(Uri.parse(_api),
          headers: {'accept': 'application/vnd.github+json'});
      if (res.statusCode != 200) return UpdateCheckOutcome.failed;
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final tag = json['tag_name'] as String? ?? '';
      final info = await PackageInfo.fromPlatform();
      // Stamp only after a successful fetch — a failed/offline attempt
      // retries on the next launch instead of waiting a day.
      await prefs.setInt(lastCheckPref, nowMs);
      if (isNewerTag(tag, info.version, info.buildNumber)) {
        availableTag = tag;
        releaseUrl = json['html_url'] as String? ?? releasePage;
        final rawAssets = json['assets'];
        assets = rawAssets is List
            ? rawAssets.map(UpdateAsset.fromJson).nonNulls.toList()
            : const [];
        await prefs.setString(
            availablePref,
            jsonEncode({
              'tag': availableTag,
              'url': releaseUrl,
              'assets': [for (final a in assets) a.toJson()],
            }));
        notifyListeners();
        return UpdateCheckOutcome.updateFound;
      } else {
        // Up to date: a stale restored/announced update (the app was
        // updated some other way) must disappear again.
        await prefs.remove(availablePref);
        if (availableTag != null) {
          availableTag = null;
          releaseUrl = null;
          assets = const [];
          notifyListeners();
        }
        return UpdateCheckOutcome.upToDate;
      }
    } catch (_) {
      // Silent by design (background path); checkNow surfaces this.
      return UpdateCheckOutcome.failed;
    } finally {
      if (ownsClient) c.close();
    }
  }

  /// Brings a previously seen newer release back into memory (About
  /// row + snackbar) without any network. Drops the stored value once
  /// it no longer beats the running version.
  Future<void> _restorePersisted(SharedPreferences prefs) async {
    final raw = prefs.getString(availablePref);
    if (raw == null) return;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final tag = json['tag'] as String? ?? '';
      final info = await PackageInfo.fromPlatform();
      if (!isNewerTag(tag, info.version, info.buildNumber)) {
        await prefs.remove(availablePref);
        return;
      }
      if (availableTag == tag) return;
      availableTag = tag;
      releaseUrl = json['url'] as String? ?? releasePage;
      final rawAssets = json['assets'];
      assets = rawAssets is List
          ? rawAssets.map(UpdateAsset.fromJson).nonNulls.toList()
          : const [];
      notifyListeners();
    } catch (_) {
      await prefs.remove(availablePref);
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
