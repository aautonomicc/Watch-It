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
