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

  /// Windows only: the zip is verified and the swap helper has been
  /// launched — the app is closing so the helper can replace the
  /// install folder and relaunch it.
  applying,

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
/// Windows: the running exe can't overwrite itself, so the zip is
/// downloaded to the system temp dir and a small PowerShell helper
/// (written by the app at update time — it always matches this build
/// and, like the zip, carries no Mark-of-the-Web) is launched detached
/// before the app exits; the helper waits for the process to end,
/// extracts the zip over the install folder and relaunches W@tch.
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
  @visibleForTesting
  static bool? windowsPlatformOverride;
  @visibleForTesting
  static String? windowsInstallDirOverride;
  @visibleForTesting
  Future<void> Function(String executable, List<String> args)?
      processStarter;
  @visibleForTesting
  void Function()? exitOverride;

  UpdateInstallStage stage = UpdateInstallStage.idle;

  /// 0..1 while downloading (0 when the size is unknown).
  double progress = 0;
  String? error;

  bool _cancelled = false;
  String? _apkPath;

  bool get busy =>
      stage == UpdateInstallStage.downloading ||
      stage == UpdateInstallStage.applying;

  /// The running AppImage's path, or null when not launched from one
  /// (dev runs, plain bundles) — then only the release page can help.
  static String? get runningAppImagePath =>
      appImagePathOverride ?? Platform.environment['APPIMAGE'];

  /// True on Windows (test-overridable).
  static bool get onWindows => windowsPlatformOverride ?? Platform.isWindows;

  /// The Windows install folder (the directory holding watchit.exe),
  /// or null when not running from the release bundle (dev runs) —
  /// then only the release page can help.
  static String? get windowsInstallDir {
    final override = windowsInstallDirOverride;
    if (override != null) return override;
    if (!onWindows) return null;
    final exe = File(Platform.resolvedExecutable);
    if (exe.uri.pathSegments.last.toLowerCase() != 'watchit.exe') {
      return null;
    }
    return exe.parent.path;
  }

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

  /// Windows: download the release zip into the system temp dir,
  /// verify it, then hand off to the swap helper and exit — the helper
  /// waits for this process to die, extracts the zip over the install
  /// folder (retrying while file locks clear), relaunches W@tch and
  /// cleans up after itself.
  Future<void> downloadAndRunWindowsUpdate(UpdateAsset asset) async {
    if (busy) return;
    final installDir = windowsInstallDir;
    if (installDir == null) {
      _fail(UpdateInstallException(
          'Not running from an installed W@tch folder — use the release '
          'page instead.'));
      return;
    }
    _begin();
    Directory? work;
    try {
      final root = cacheDirOverride ?? Directory.systemTemp;
      work = Directory('${root.path}/watchit-update');
      // One update at a time — drop any earlier download first.
      if (work.existsSync()) work.deleteSync(recursive: true);
      work.createSync(recursive: true);
      final zip = File('${work.path}/${_safeName(asset.name)}');
      await _download(asset, zip);
      final script = File('${work.path}/watchit-update.ps1')
        ..writeAsStringSync(kWindowsUpdaterScript);
      final start = processStarter ??
          (exe, args) async {
            await Process.start(exe, args,
                mode: ProcessStartMode.detached);
          };
      await start('powershell.exe', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
        '-ZipPath',
        zip.path,
        '-InstallDir',
        installDir,
        '-ExeName',
        _windowsExeName,
        '-AppPid',
        '$pid',
        '-LogPath',
        '${work.path}/watchit-update.log',
      ]);
      stage = UpdateInstallStage.applying;
      progress = 1;
      notifyListeners();
      // The helper waits for this process to end before touching any
      // file, so leave right away.
      (exitOverride ?? () => exit(0))();
    } on _Cancelled {
      _tryDeleteDir(work);
      _reset();
    } catch (e) {
      _tryDeleteDir(work);
      _fail(e);
    }
  }

  /// The name the helper relaunches. Defensive fallback for test runs
  /// whose executable isn't the app.
  static String get _windowsExeName {
    final name = File(Platform.resolvedExecutable).uri.pathSegments.last;
    return name.toLowerCase() == 'watchit.exe' ? name : 'watchit.exe';
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

  static void _tryDeleteDir(Directory? d) {
    try {
      if (d != null && d.existsSync()) d.deleteSync(recursive: true);
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

/// The Windows swap helper. Written next to the downloaded zip and run
/// detached; everything in here executes after the app has exited (the
/// zip's own integrity was already verified before the handoff).
const kWindowsUpdaterScript = r'''
param(
  [Parameter(Mandatory = $true)][string]$ZipPath,
  [Parameter(Mandatory = $true)][string]$InstallDir,
  [Parameter(Mandatory = $true)][string]$ExeName,
  [Parameter(Mandatory = $true)][int]$AppPid,
  [string]$LogPath
)
$ErrorActionPreference = 'Stop'
function Log($msg) {
  if ($LogPath) {
    try {
      Add-Content -LiteralPath $LogPath `
        -Value ("{0} {1}" -f (Get-Date -Format o), $msg)
    } catch {}
  }
}
try {
  Log "waiting for W@tch (pid $AppPid) to exit"
  try { Wait-Process -Id $AppPid -Timeout 60 -ErrorAction Stop } catch {}
  Start-Sleep -Milliseconds 500

  $staging = Join-Path ([System.IO.Path]::GetTempPath()) `
    ("watchit-update-staging-" + [System.IO.Path]::GetRandomFileName())
  Log "extracting $ZipPath"
  Expand-Archive -LiteralPath $ZipPath -DestinationPath $staging -Force

  # The zip's members live at its root (watchit.exe, DLLs, data\) --
  # copy them over the install folder, retrying while stray file locks
  # clear.
  $tries = 0
  while ($true) {
    try {
      Copy-Item -Path (Join-Path $staging '*') -Destination $InstallDir `
        -Recurse -Force
      break
    } catch {
      $tries++
      if ($tries -ge 10) { throw }
      Log "copy attempt $tries failed: $_"
      Start-Sleep -Seconds 1
    }
  }
  Log "relaunching"
  Start-Process -FilePath (Join-Path $InstallDir $ExeName) `
    -WorkingDirectory $InstallDir
  Remove-Item -LiteralPath $staging -Recurse -Force `
    -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
  Log "done"
} catch {
  Log "update failed: $_"
  # Leave the user with a running app either way: whatever sits in the
  # install folder still starts, and re-running the in-app update
  # repairs a partial copy.
  try {
    Start-Process -FilePath (Join-Path $InstallDir $ExeName) `
      -WorkingDirectory $InstallDir
  } catch {}
  exit 1
}
''';
