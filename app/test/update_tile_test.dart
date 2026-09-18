import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watchit/services/update_check.dart';
import 'package:watchit/services/update_install.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/update_tile.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('wi-tile-test');
    UpdateCheck.resetForTesting();
    UpdateInstaller.resetForTesting();
    UpdateInstaller.appImagePathOverride = null;
  });

  tearDown(() {
    UpdateInstaller.appImagePathOverride = null;
    UpdateInstaller.windowsPlatformOverride = null;
    UpdateInstaller.windowsInstallDirOverride = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Widget host() => MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: const Scaffold(body: UpdateAvailableTile()),
      );

  const appImageAssetJson = UpdateAsset(
    name: 'Watch-It-0.1.0-alpha.101-x86_64.AppImage',
    url: 'https://example.com/W.AppImage',
    size: 3,
  );

  testWidgets('hidden while no update is known', (tester) async {
    await tester.pumpWidget(host());
    expect(find.text('Update available'), findsNothing);
  });

  testWidgets('no self-update path → release-page row', (tester) async {
    UpdateCheck.instance
      ..availableTag = 'v0.1.0-alpha.101'
      ..assets = const [appImageAssetJson];
    // appImagePathOverride stays null and APPIMAGE is unset in tests →
    // not an AppImage run → fallback.
    await tester.pumpWidget(host());
    expect(find.text('Update available'), findsOneWidget);
    expect(find.textContaining('open the release page'), findsOneWidget);
  }, skip: Platform.environment['APPIMAGE'] != null);

  testWidgets('AppImage run → tap downloads, swaps, asks for a restart',
      (tester) async {
    final current = File('${tmp.path}/W.AppImage')
      ..writeAsStringSync('old-version');
    UpdateInstaller.appImagePathOverride = current.path;
    final newBytes = utf8.encode('new');
    UpdateCheck.instance
      ..availableTag = 'v0.1.0-alpha.101'
      ..assets = [
        UpdateAsset(
          name: 'Watch-It-0.1.0-alpha.101-x86_64.AppImage',
          url: 'https://example.com/W.AppImage',
          size: newBytes.length,
          sha256: sha256.convert(newBytes).toString(),
        ),
      ];
    UpdateInstaller.instance.client =
        MockClient((_) async => http.Response.bytes(newBytes, 200));

    await tester.pumpWidget(host());
    expect(find.textContaining('download and update in place'),
        findsOneWidget);

    // Real file IO — run outside the fake-async zone.
    await tester.runAsync(() async {
      await tester.tap(find.text('Update available'));
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (UpdateInstaller.instance.stage !=
              UpdateInstallStage.awaitingRestart &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    expect(
        UpdateInstaller.instance.stage, UpdateInstallStage.awaitingRestart);
    await tester.pump();
    expect(find.textContaining('restart W@tch'), findsOneWidget);
    expect(current.readAsStringSync(), 'new');
  });

  testWidgets('Windows install → tap downloads and hands off to the helper',
      (tester) async {
    UpdateInstaller.windowsPlatformOverride = true;
    final install = Directory('${tmp.path}/install')..createSync();
    UpdateInstaller.windowsInstallDirOverride = install.path;
    final bytes = utf8.encode('zip-bytes');
    UpdateCheck.instance
      ..availableTag = 'v0.1.0-alpha.101'
      ..assets = [
        UpdateAsset(
          name: 'Watch-It-0.1.0-alpha.101-windows-x64.zip',
          url: 'https://example.com/win.zip',
          size: bytes.length,
          sha256: sha256.convert(bytes).toString(),
        ),
      ];
    var handedOff = false;
    var exited = false;
    UpdateInstaller.instance
      ..client = MockClient((_) async => http.Response.bytes(bytes, 200))
      ..cacheDirOverride = tmp
      ..processStarter = (exe, args) async {
        handedOff = true;
      }
      ..exitOverride = () => exited = true;

    await tester.pumpWidget(host());
    expect(find.textContaining('W@tch restarts to finish'), findsOneWidget);

    // Real file IO — run outside the fake-async zone.
    await tester.runAsync(() async {
      await tester.tap(find.text('Update available'));
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (UpdateInstaller.instance.stage != UpdateInstallStage.applying &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    expect(UpdateInstaller.instance.stage, UpdateInstallStage.applying);
    expect(handedOff, true);
    expect(exited, true);
    await tester.pump();
    expect(find.textContaining('close and reopen'), findsOneWidget);
  });

  testWidgets('downloading state shows progress and a cancel button',
      (tester) async {
    final current = File('${tmp.path}/W.AppImage')
      ..writeAsStringSync('old-version');
    UpdateInstaller.appImagePathOverride = current.path;
    UpdateCheck.instance
      ..availableTag = 'v0.1.0-alpha.101'
      ..assets = const [appImageAssetJson];
    UpdateInstaller.instance
      ..stage = UpdateInstallStage.downloading
      ..progress = 0.42;

    await tester.pumpWidget(host());
    expect(find.textContaining('42%'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byTooltip('Cancel download'), findsOneWidget);
  });

  testWidgets('failure shows the error and offers a retry tap',
      (tester) async {
    final current = File('${tmp.path}/W.AppImage')
      ..writeAsStringSync('old-version');
    UpdateInstaller.appImagePathOverride = current.path;
    UpdateCheck.instance
      ..availableTag = 'v0.1.0-alpha.101'
      ..assets = const [appImageAssetJson];
    UpdateInstaller.instance
      ..stage = UpdateInstallStage.failed
      ..error = 'The download was incomplete (1 of 3 bytes) — try again.';

    await tester.pumpWidget(host());
    expect(find.textContaining('incomplete'), findsOneWidget);
    expect(find.textContaining('Tap to try again'), findsOneWidget);
  });
}
