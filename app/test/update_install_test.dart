import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watchit/services/update_check.dart';
import 'package:watchit/services/update_install.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('wi-update-test');
    UpdateInstaller.resetForTesting();
    UpdateInstaller.appImagePathOverride = null;
  });

  tearDown(() {
    UpdateInstaller.appImagePathOverride = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  UpdateAsset assetFor(List<int> bytes, String name,
          {String? sha, int? size}) =>
      UpdateAsset(
        name: name,
        url: 'https://example.com/$name',
        size: size ?? bytes.length,
        sha256: sha,
      );

  MockClient bytesClient(List<int> bytes) =>
      MockClient((req) async => http.Response.bytes(bytes, 200));

  group('AppImage swap', () {
    test('downloads, verifies sha, swaps in place, keeps .old', () async {
      final current = File('${tmp.path}/W.AppImage')
        ..writeAsStringSync('old-version');
      UpdateInstaller.appImagePathOverride = current.path;
      final newBytes = utf8.encode('new-version-bytes');
      final installer = UpdateInstaller.instance
        ..client = bytesClient(newBytes);

      await installer.downloadAndSwapAppImage(assetFor(
          newBytes, 'W.AppImage', sha: sha256.convert(newBytes).toString()));

      expect(installer.stage, UpdateInstallStage.awaitingRestart);
      expect(installer.error, null);
      expect(current.readAsStringSync(), 'new-version-bytes');
      // Executable bit set on the swapped-in image.
      expect(current.statSync().mode & 0x40, isNot(0),
          reason: 'owner-executable bit expected');
      final old = File('${current.path}.old');
      expect(old.readAsStringSync(), 'old-version');
      expect(File('${current.path}.part').existsSync(), false);

      // Next launch drops the backup.
      await UpdateInstaller.cleanupOldAppImage();
      expect(old.existsSync(), false);
    });

    test('size mismatch fails and leaves the running image untouched',
        () async {
      final current = File('${tmp.path}/W.AppImage')
        ..writeAsStringSync('old-version');
      UpdateInstaller.appImagePathOverride = current.path;
      final newBytes = utf8.encode('short');
      final installer = UpdateInstaller.instance
        ..client = bytesClient(newBytes);

      await installer.downloadAndSwapAppImage(
          assetFor(newBytes, 'W.AppImage', size: newBytes.length + 99));

      expect(installer.stage, UpdateInstallStage.failed);
      expect(installer.error, contains('incomplete'));
      expect(current.readAsStringSync(), 'old-version');
      expect(File('${current.path}.part').existsSync(), false);
      expect(File('${current.path}.old').existsSync(), false);
    });

    test('checksum mismatch fails', () async {
      final current = File('${tmp.path}/W.AppImage')
        ..writeAsStringSync('old-version');
      UpdateInstaller.appImagePathOverride = current.path;
      final newBytes = utf8.encode('tampered-bytes');
      final installer = UpdateInstaller.instance
        ..client = bytesClient(newBytes);

      await installer.downloadAndSwapAppImage(assetFor(newBytes,
          'W.AppImage', sha: 'deadbeef${'0' * 56}'));

      expect(installer.stage, UpdateInstallStage.failed);
      expect(installer.error, contains('checksum'));
      expect(current.readAsStringSync(), 'old-version');
    });

    test('HTTP error fails cleanly', () async {
      final current = File('${tmp.path}/W.AppImage')
        ..writeAsStringSync('old-version');
      UpdateInstaller.appImagePathOverride = current.path;
      final installer = UpdateInstaller.instance
        ..client = MockClient((_) async => http.Response('nope', 404));

      await installer
          .downloadAndSwapAppImage(assetFor([1, 2, 3], 'W.AppImage'));

      expect(installer.stage, UpdateInstallStage.failed);
      expect(installer.error, contains('404'));
      expect(current.readAsStringSync(), 'old-version');
    });

    test('missing running image refuses up front', () async {
      UpdateInstaller.appImagePathOverride = '${tmp.path}/gone.AppImage';
      final installer = UpdateInstaller.instance
        ..client = bytesClient([1, 2, 3]);

      await installer
          .downloadAndSwapAppImage(assetFor([1, 2, 3], 'W.AppImage'));

      expect(installer.stage, UpdateInstallStage.failed);
      expect(installer.error, contains('release page'));
    });

    test('cancel mid-download resets to idle and deletes the partial',
        () async {
      final current = File('${tmp.path}/W.AppImage')
        ..writeAsStringSync('old-version');
      UpdateInstaller.appImagePathOverride = current.path;
      final chunk = List<int>.filled(1024, 7);
      final installer = UpdateInstaller.instance
        ..client = MockClient.streaming((req, body) async =>
            http.StreamedResponse(
                Stream.fromIterable([chunk, chunk, chunk, chunk]), 200));
      // Cancel as soon as the first progress tick lands.
      installer.addListener(() {
        if (installer.progress > 0 &&
            installer.stage == UpdateInstallStage.downloading) {
          installer.cancel();
        }
      });

      await installer.downloadAndSwapAppImage(UpdateAsset(
          name: 'W.AppImage',
          url: 'https://example.com/W.AppImage',
          size: chunk.length * 4));

      expect(installer.stage, UpdateInstallStage.idle);
      expect(current.readAsStringSync(), 'old-version');
      expect(File('${current.path}.part').existsSync(), false);
    });

    test('cleanupOldAppImage is a no-op without an .old file', () async {
      UpdateInstaller.appImagePathOverride = '${tmp.path}/W.AppImage';
      await UpdateInstaller.cleanupOldAppImage(); // must not throw
    });
  });

  group('Windows helper swap', () {
    setUp(() {
      UpdateInstaller.windowsPlatformOverride = true;
    });

    tearDown(() {
      UpdateInstaller.windowsPlatformOverride = null;
      UpdateInstaller.windowsInstallDirOverride = null;
    });

    test('downloads, verifies, writes the helper, hands off and exits',
        () async {
      final install = Directory('${tmp.path}/install')..createSync();
      UpdateInstaller.windowsInstallDirOverride = install.path;
      final bytes = utf8.encode('zip-bytes');
      final started = <List<String>>[];
      var exited = 0;
      final installer = UpdateInstaller.instance
        ..client = bytesClient(bytes)
        ..cacheDirOverride = tmp
        ..processStarter = (exe, args) async {
          started.add([exe, ...args]);
        }
        ..exitOverride = () => exited++;

      await installer.downloadAndRunWindowsUpdate(assetFor(
          bytes, 'Watch-It-0.1.0-alpha.101-windows-x64.zip',
          sha: sha256.convert(bytes).toString()));

      expect(installer.stage, UpdateInstallStage.applying);
      expect(installer.error, null);
      expect(exited, 1);
      expect(started, hasLength(1));
      final args = started.single;
      expect(args.first, 'powershell.exe');
      final script = File(args[args.indexOf('-File') + 1]);
      expect(script.readAsStringSync(), contains('Expand-Archive'));
      final zip = File(args[args.indexOf('-ZipPath') + 1]);
      expect(zip.readAsStringSync(), 'zip-bytes');
      expect(args[args.indexOf('-InstallDir') + 1], install.path);
      expect(args[args.indexOf('-ExeName') + 1], 'watchit.exe');
      expect(int.parse(args[args.indexOf('-AppPid') + 1]), pid);
    });

    test('checksum mismatch fails, cleans up, never hands off', () async {
      final install = Directory('${tmp.path}/install')..createSync();
      UpdateInstaller.windowsInstallDirOverride = install.path;
      final bytes = utf8.encode('tampered');
      final started = <List<String>>[];
      var exited = 0;
      final installer = UpdateInstaller.instance
        ..client = bytesClient(bytes)
        ..cacheDirOverride = tmp
        ..processStarter = (exe, args) async {
          started.add([exe, ...args]);
        }
        ..exitOverride = () => exited++;

      await installer.downloadAndRunWindowsUpdate(assetFor(
          bytes, 'W-windows-x64.zip', sha: 'deadbeef${'0' * 56}'));

      expect(installer.stage, UpdateInstallStage.failed);
      expect(installer.error, contains('checksum'));
      expect(started, isEmpty);
      expect(exited, 0);
      expect(Directory('${tmp.path}/watchit-update').existsSync(), false);
    });

    test('not running from an installed bundle refuses up front',
        () async {
      // No install-dir override and the test runner's executable is not
      // watchit.exe → windowsInstallDir resolves null.
      final started = <List<String>>[];
      final installer = UpdateInstaller.instance
        ..client = bytesClient([1, 2, 3])
        ..cacheDirOverride = tmp
        ..processStarter = (exe, args) async {
          started.add([exe]);
        };

      await installer
          .downloadAndRunWindowsUpdate(assetFor([1, 2, 3], 'W.zip'));

      expect(installer.stage, UpdateInstallStage.failed);
      expect(installer.error, contains('release page'));
      expect(started, isEmpty);
    });

    test('helper launch failure surfaces and does not exit the app',
        () async {
      final install = Directory('${tmp.path}/install')..createSync();
      UpdateInstaller.windowsInstallDirOverride = install.path;
      final bytes = utf8.encode('zip-bytes');
      var exited = 0;
      final installer = UpdateInstaller.instance
        ..client = bytesClient(bytes)
        ..cacheDirOverride = tmp
        ..processStarter = (exe, args) async {
          throw Exception('powershell missing');
        }
        ..exitOverride = () => exited++;

      await installer.downloadAndRunWindowsUpdate(
          assetFor(bytes, 'W-windows-x64.zip'));

      expect(installer.stage, UpdateInstallStage.failed);
      expect(installer.error, contains('powershell missing'));
      expect(exited, 0);
      expect(Directory('${tmp.path}/watchit-update').existsSync(), false);
    });

    test('cancel mid-download resets to idle and cleans the work dir',
        () async {
      final install = Directory('${tmp.path}/install')..createSync();
      UpdateInstaller.windowsInstallDirOverride = install.path;
      final chunk = List<int>.filled(1024, 7);
      final started = <List<String>>[];
      final installer = UpdateInstaller.instance
        ..cacheDirOverride = tmp
        ..processStarter = (exe, args) async {
          started.add([exe]);
        }
        ..client = MockClient.streaming((req, body) async =>
            http.StreamedResponse(
                Stream.fromIterable([chunk, chunk, chunk, chunk]), 200));
      installer.addListener(() {
        if (installer.progress > 0 &&
            installer.stage == UpdateInstallStage.downloading) {
          installer.cancel();
        }
      });

      await installer.downloadAndRunWindowsUpdate(UpdateAsset(
          name: 'W-windows-x64.zip',
          url: 'https://example.com/W-windows-x64.zip',
          size: chunk.length * 4));

      expect(installer.stage, UpdateInstallStage.idle);
      expect(started, isEmpty);
      expect(Directory('${tmp.path}/watchit-update').existsSync(), false);
    });
  });

  group('macOS app swap', () {
    setUp(() {
      UpdateInstaller.macPlatformOverride = true;
    });

    tearDown(() {
      UpdateInstaller.macPlatformOverride = null;
      UpdateInstaller.macAppBundleOverride = null;
    });

    Directory installBundle() {
      final bundle = Directory('${tmp.path}/Applications/W@tch.app');
      File('${bundle.path}/Contents/MacOS/W@tch')
        ..createSync(recursive: true)
        ..writeAsStringSync('old-version');
      UpdateInstaller.macAppBundleOverride = bundle.path;
      return bundle;
    }

    void copyTree(Directory from, String to) {
      Directory(to).createSync(recursive: true);
      for (final e in from.listSync(recursive: true, followLinks: false)) {
        final rel = e.path.substring(from.path.length);
        if (e is Directory) {
          Directory('$to$rel').createSync(recursive: true);
        } else if (e is File) {
          File('$to$rel')
            ..createSync(recursive: true)
            ..writeAsBytesSync(e.readAsBytesSync());
        }
      }
    }

    // Simulates hdiutil attach/detach + ditto with real file IO: attach
    // materializes the dmg's volume (the app plus the Applications
    // symlink), ditto copies the tree.
    Future<ProcessResult> Function(String, List<String>) fakeRunner(
      List<List<String>> commands, {
      bool failAttach = false,
      bool dittoWritesNothing = false,
    }) {
      return (exe, args) async {
        commands.add([exe, ...args]);
        if (exe == 'hdiutil' && args.first == 'attach') {
          if (failAttach) {
            return ProcessResult(0, 1, '', 'no mountable file systems');
          }
          final mnt = args[args.indexOf('-mountpoint') + 1];
          File('$mnt/W@tch.app/Contents/MacOS/W@tch')
            ..createSync(recursive: true)
            ..writeAsStringSync('new-version');
          Link('$mnt/Applications').createSync('/Applications');
          return ProcessResult(0, 0, '', '');
        }
        if (exe == 'ditto') {
          if (!dittoWritesNothing) {
            copyTree(Directory(args[0]), args[1]);
          }
          return ProcessResult(0, 0, '', '');
        }
        return ProcessResult(0, 0, '', ''); // detach
      };
    }

    test('downloads, verifies, mounts, swaps the bundle, keeps .old',
        () async {
      final bundle = installBundle();
      final dmgBytes = utf8.encode('dmg-bytes');
      final commands = <List<String>>[];
      final installer = UpdateInstaller.instance
        ..client = bytesClient(dmgBytes)
        ..cacheDirOverride = tmp
        ..processRunner = fakeRunner(commands);

      await installer.downloadAndSwapMacApp(assetFor(
          dmgBytes, 'Watch-It-0.1.0-alpha.101-macos-universal.dmg',
          sha: sha256.convert(dmgBytes).toString()));

      expect(installer.stage, UpdateInstallStage.awaitingRestart);
      expect(installer.error, null);
      expect(File('${bundle.path}/Contents/MacOS/W@tch').readAsStringSync(),
          'new-version');
      final old = Directory('${bundle.path}.old');
      expect(File('${old.path}/Contents/MacOS/W@tch').readAsStringSync(),
          'old-version');
      expect(Directory('${bundle.path}.update').existsSync(), false);
      // The dmg + mount work dir are gone once the swap lands.
      expect(Directory('${tmp.path}/watchit-update').existsSync(), false);
      // attach → ditto → detach, with the safety flags on the mount.
      expect(
          commands
              .map((c) =>
                  c.first == 'hdiutil' ? '${c[0]} ${c[1]}' : c.first)
              .toList(),
          ['hdiutil attach', 'ditto', 'hdiutil detach']);
      expect(commands.first, containsAll(['-readonly', '-nobrowse']));

      // Next launch drops the backup.
      await UpdateInstaller.cleanupOldMacApp();
      expect(old.existsSync(), false);
    });

    test('checksum mismatch fails, cleans up, never mounts', () async {
      final bundle = installBundle();
      final dmgBytes = utf8.encode('tampered');
      final commands = <List<String>>[];
      final installer = UpdateInstaller.instance
        ..client = bytesClient(dmgBytes)
        ..cacheDirOverride = tmp
        ..processRunner = fakeRunner(commands);

      await installer.downloadAndSwapMacApp(assetFor(
          dmgBytes, 'W-macos-universal.dmg', sha: 'deadbeef${'0' * 56}'));

      expect(installer.stage, UpdateInstallStage.failed);
      expect(installer.error, contains('checksum'));
      expect(commands, isEmpty);
      expect(File('${bundle.path}/Contents/MacOS/W@tch').readAsStringSync(),
          'old-version');
      expect(Directory('${tmp.path}/watchit-update').existsSync(), false);
    });

    test('not running from an app bundle refuses up front', () async {
      // No bundle override and the test runner's executable is not
      // inside a .app → macAppBundlePath resolves null.
      final commands = <List<String>>[];
      final installer = UpdateInstaller.instance
        ..client = bytesClient([1, 2, 3])
        ..cacheDirOverride = tmp
        ..processRunner = fakeRunner(commands);

      await installer
          .downloadAndSwapMacApp(assetFor([1, 2, 3], 'W.dmg'));

      expect(installer.stage, UpdateInstallStage.failed);
      expect(installer.error, contains('release page'));
      expect(commands, isEmpty);
    });

    test('unwritable install folder refuses before downloading', () async {
      final bundle = installBundle();
      var downloaded = false;
      final installer = UpdateInstaller.instance
        ..client = MockClient((_) async {
          downloaded = true;
          return http.Response.bytes([1, 2, 3], 200);
        })
        ..cacheDirOverride = tmp;
      final parent = bundle.parent.path;
      Process.runSync('chmod', ['555', parent]);
      try {
        await installer
            .downloadAndSwapMacApp(assetFor([1, 2, 3], 'W.dmg'));
      } finally {
        Process.runSync('chmod', ['755', parent]);
      }

      expect(installer.stage, UpdateInstallStage.failed);
      expect(installer.error, contains("isn't writable"));
      expect(downloaded, false);
    });

    test('mount failure surfaces and leaves the bundle untouched',
        () async {
      final bundle = installBundle();
      final dmgBytes = utf8.encode('dmg-bytes');
      final commands = <List<String>>[];
      final installer = UpdateInstaller.instance
        ..client = bytesClient(dmgBytes)
        ..cacheDirOverride = tmp
        ..processRunner = fakeRunner(commands, failAttach: true);

      await installer.downloadAndSwapMacApp(
          assetFor(dmgBytes, 'W-macos-universal.dmg'));

      expect(installer.stage, UpdateInstallStage.failed);
      expect(installer.error, contains('disk image'));
      expect(installer.error, contains('no mountable file systems'));
      expect(File('${bundle.path}/Contents/MacOS/W@tch').readAsStringSync(),
          'old-version');
      expect(Directory('${bundle.path}.old').existsSync(), false);
      expect(Directory('${tmp.path}/watchit-update').existsSync(), false);
    });

    test('failed final rename puts the running bundle back', () async {
      final bundle = installBundle();
      final dmgBytes = utf8.encode('dmg-bytes');
      final commands = <List<String>>[];
      // ditto "succeeds" but writes nothing → the staging dir is
      // missing when the final rename runs, which throws.
      final installer = UpdateInstaller.instance
        ..client = bytesClient(dmgBytes)
        ..cacheDirOverride = tmp
        ..processRunner = fakeRunner(commands, dittoWritesNothing: true);

      await installer.downloadAndSwapMacApp(
          assetFor(dmgBytes, 'W-macos-universal.dmg'));

      expect(installer.stage, UpdateInstallStage.failed);
      expect(File('${bundle.path}/Contents/MacOS/W@tch').readAsStringSync(),
          'old-version');
      expect(Directory('${bundle.path}.old').existsSync(), false);
    });

    test('cancel mid-download resets to idle and cleans the work dir',
        () async {
      final bundle = installBundle();
      final chunk = List<int>.filled(1024, 7);
      final commands = <List<String>>[];
      final installer = UpdateInstaller.instance
        ..cacheDirOverride = tmp
        ..processRunner = fakeRunner(commands)
        ..client = MockClient.streaming((req, body) async =>
            http.StreamedResponse(
                Stream.fromIterable([chunk, chunk, chunk, chunk]), 200));
      installer.addListener(() {
        if (installer.progress > 0 &&
            installer.stage == UpdateInstallStage.downloading) {
          installer.cancel();
        }
      });

      await installer.downloadAndSwapMacApp(UpdateAsset(
          name: 'W-macos-universal.dmg',
          url: 'https://example.com/W.dmg',
          size: chunk.length * 4));

      expect(installer.stage, UpdateInstallStage.idle);
      expect(commands, isEmpty);
      expect(File('${bundle.path}/Contents/MacOS/W@tch').readAsStringSync(),
          'old-version');
      expect(Directory('${tmp.path}/watchit-update').existsSync(), false);
    });
  });

  group('APK download and install', () {
    test('downloads into the cache and fires the installer', () async {
      final bytes = utf8.encode('apk-bytes');
      // A stale earlier download must be swept.
      Directory('${tmp.path}/updates').createSync(recursive: true);
      File('${tmp.path}/updates/stale.apk').writeAsStringSync('stale');
      final launched = <String>[];
      final installer = UpdateInstaller.instance
        ..client = bytesClient(bytes)
        ..cacheDirOverride = tmp
        ..apkInstallLauncher = (p) async => launched.add(p);

      await installer.downloadAndInstallApk(assetFor(
          bytes, 'Watch-It-0.1.0-alpha.101.apk',
          sha: sha256.convert(bytes).toString()));

      expect(installer.stage, UpdateInstallStage.readyToInstall);
      expect(launched, hasLength(1));
      expect(launched.single, endsWith('Watch-It-0.1.0-alpha.101.apk'));
      expect(File(launched.single).readAsStringSync(), 'apk-bytes');
      expect(File('${tmp.path}/updates/stale.apk').existsSync(), false);

      // The installer prompt can be re-opened without re-downloading.
      await installer.launchApkInstaller();
      expect(launched, hasLength(2));
    });

    test('failed download never reaches the installer', () async {
      final bytes = utf8.encode('apk-bytes');
      final launched = <String>[];
      final installer = UpdateInstaller.instance
        ..client = bytesClient(bytes)
        ..cacheDirOverride = tmp
        ..apkInstallLauncher = (p) async => launched.add(p);

      await installer.downloadAndInstallApk(
          assetFor(bytes, 'W.apk', size: bytes.length + 1));

      expect(installer.stage, UpdateInstallStage.failed);
      expect(launched, isEmpty);
    });

    test('launcher error surfaces as failure', () async {
      final bytes = utf8.encode('apk-bytes');
      final installer = UpdateInstaller.instance
        ..client = bytesClient(bytes)
        ..cacheDirOverride = tmp
        ..apkInstallLauncher = (p) async => throw Exception('no installer');

      await installer.downloadAndInstallApk(assetFor(bytes, 'W.apk'));

      expect(installer.stage, UpdateInstallStage.failed);
      expect(installer.error, contains('installer'));
    });
  });
}
