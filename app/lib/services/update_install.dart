import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'update_check.dart';

/// Where the in-app updater stands.
enum UpdateInstallStage {
  /// Nothing running (also after a cancel).
  idle,

  /// Streaming the release asset to disk; [UpdateInstaller.progress]
  /// moves 0 → 1.
  downloading,

  /// Android only: the APK is downloaded and verified; the system
  /// installer has been (or can be re-)launched.
  readyToInstall,

  /// Linux only: the running AppImage was replaced on disk — the new
  /// version starts on next launch.
  awaitingRestart,

  /// The attempt failed; [UpdateInstaller.error] says why. Starting
  /// again retries from scratch.
  failed,
}

class UpdateInstallException implements Exception {
  UpdateInstallException(this.message);
  final String message;
  @override
  String toString() => message;
}

class _Cancelled implements Exception {}

/// Applies an update the user asked for — never automatically.
///
/// Android: downloads the release APK to the app cache and hands it to
/// the system package installer (FileProvider + ACTION_VIEW; same
/// signing cert, so data is kept). The OS owns the actual install and
/// its one-time "install unknown apps" grant.
///
/// Linux (AppImage runs only): downloads the new AppImage beside the
/// running one, sets it executable, and atomically renames it over the
/// running file — safe while running, the old inode stays mapped. The
/// previous file is kept as `<image>.old` until the next launch
/// ([cleanupOldAppImage]) in case anything goes wrong.
///
/// Every download verifies the byte size GitHub declared and, when the
/// API supplies a sha256 digest, the checksum too — a short or
/// tampered file is never installed.
class UpdateInstaller extends ChangeNotifier {
  UpdateInstaller._();
  static UpdateInstaller instance = UpdateInstaller._();

  @visibleForTesting
  static void resetForTesting() => instance = UpdateInstaller._();

  static const _channel = MethodChannel('watchit/update');

  /// Test seams.
  @visibleForTesting
  http.Client? client;
  @visibleForTesting
  Future<void> Function(String apkPath)? apkInstallLauncher;
  @visibleForTesting
  static String? appImagePathOverride;
  @visibleForTesting
  Directory? cacheDirOverride;

  UpdateInstallStage stage = UpdateInstallStage.idle;

  /// 0..1 while downloading (0 when the size is unknown).
  double progress = 0;
  String? error;

  bool _cancelled = false;
  String? _apkPath;

  bool get busy => stage == UpdateInstallStage.downloading;

  /// The running AppImage's path, or null when not launched from one
  /// (dev runs, plain bundles) — then only the release page can help.
  static String? get runningAppImagePath =>
      appImagePathOverride ?? Platform.environment['APPIMAGE'];

  /// Asks the user's session to stop the download.
  void cancel() {
    if (busy) _cancelled = true;
  }

  /// Android: download [asset] into the app cache and hand it to the
  /// system installer.
  Future<void> downloadAndInstallApk(UpdateAsset asset) async {
    if (busy) return;
    _begin();
    File? target;
    try {
      final root = cacheDirOverride ?? await getTemporaryDirectory();
      final dir = Directory('${root.path}/updates');
      // One update at a time — drop any earlier download first.
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      dir.createSync(recursive: true);
      target = File('${dir.path}/${_safeName(asset.name)}');
      await _download(asset, target);
      _apkPath = target.path;
      stage = UpdateInstallStage.readyToInstall;
      notifyListeners();
      await launchApkInstaller();
    } on _Cancelled {
      _reset(deleting: target);
    } catch (e) {
      _fail(e, deleting: target);
    }
  }

  /// Re-fires the system installer for an already-downloaded APK (the
  /// user may have dismissed the first prompt).
  Future<void> launchApkInstaller() async {
    final path = _apkPath;
    if (path == null || !File(path).existsSync()) {
      _fail(UpdateInstallException(
          'The downloaded update is gone — download it again.'));
      return;
    }
    try {
      final launch = apkInstallLauncher ??
          (p) => _channel.invokeMethod('installApk', {'path': p});
      await launch(path);
    } catch (e) {
      _fail(UpdateInstallException('Could not open the installer: $e'));
    }
  }

  /// Linux: download [asset] and swap it over the running AppImage.
  Future<void> downloadAndSwapAppImage(UpdateAsset asset) async {
    if (busy) return;
    final current = runningAppImagePath;
    if (current == null || !File(current).existsSync()) {
      _fail(UpdateInstallException(
          'Not running from an AppImage — use the release page instead.'));
      return;
    }
    _begin();
    final part = File('$current.part');
    try {
      await _download(asset, part);
      final chmod = await Process.run('chmod', ['+x', part.path]);
      if (chmod.exitCode != 0) {
        throw UpdateInstallException(
            'Could not mark the new AppImage executable.');
      }
      final old = File('$current.old');
      if (old.existsSync()) old.deleteSync();
      await File(current).rename(old.path);
      try {
        await part.rename(current);
      } catch (e) {
        // Put the running image back — never leave the path empty.
        await old.rename(current);
        rethrow;
      }
      stage = UpdateInstallStage.awaitingRestart;
      progress = 1;
      notifyListeners();
    } on _Cancelled {
      _reset(deleting: part);
    } catch (e) {
      _fail(e, deleting: part);
    }
  }

  /// Startup housekeeping: a completed AppImage swap leaves the old
  /// version as `<image>.old` — this launch proves the new one runs,
  /// so drop it. Silent, fire-and-forget.
  static Future<void> cleanupOldAppImage() async {
    final current = runningAppImagePath;
    if (current == null) return;
    try {
      final old = File('$current.old');
      if (old.existsSync()) old.deleteSync();
    } catch (_) {
      // Best effort only.
    }
  }

  void _begin() {
    stage = UpdateInstallStage.downloading;
    progress = 0;
    error = null;
    _cancelled = false;
    _apkPath = null;
    notifyListeners();
  }

  void _reset({File? deleting}) {
    _tryDelete(deleting);
    stage = UpdateInstallStage.idle;
    progress = 0;
    notifyListeners();
  }

  void _fail(Object e, {File? deleting}) {
    _tryDelete(deleting);
    stage = UpdateInstallStage.failed;
    error = e is UpdateInstallException ? e.message : 'Update failed: $e';
    notifyListeners();
  }

  static void _tryDelete(File? f) {
    try {
      if (f != null && f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// Streams [asset] into [target], reporting progress and verifying
  /// the declared size + sha256 (when known) before returning.
  Future<void> _download(UpdateAsset asset, File target) async {
    final ownsClient = client == null;
    final c = client ?? http.Client();
    try {
      final req = http.Request('GET', Uri.parse(asset.url))
        ..headers['accept'] = 'application/octet-stream';
      final res = await c.send(req);
      if (res.statusCode != 200) {
        throw UpdateInstallException(
            'Download failed (HTTP ${res.statusCode}).');
      }
      final digestSink = _DigestSink();
      final hasher = sha256.startChunkedConversion(digestSink);
      var received = 0;
      final sink = target.openWrite();
      try {
        await for (final chunk in res.stream) {
          if (_cancelled) throw _Cancelled();
          sink.add(chunk);
          hasher.add(chunk);
          received += chunk.length;
          if (asset.size > 0) {
            final p = received / asset.size;
            // Throttle notifications to visible steps.
            if (p - progress >= 0.01 || p >= 1) {
              progress = p.clamp(0, 1).toDouble();
              notifyListeners();
            }
          }
        }
      } finally {
        await sink.close();
      }
      hasher.close();
      if (asset.size > 0 && received != asset.size) {
        throw UpdateInstallException(
            'The download was incomplete ($received of ${asset.size} '
            'bytes) — try again.');
      }
      final sha = asset.sha256;
      if (sha != null && digestSink.value.toString() != sha) {
        throw UpdateInstallException(
            'The downloaded file failed its checksum — try again.');
      }
    } finally {
      if (ownsClient) c.close();
    }
  }

  /// Keeps a release-asset name safe as a bare file name.
  static String _safeName(String name) {
    final base = name.split('/').last.split('\\').last;
    return base.isEmpty ? 'update.apk' : base;
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
