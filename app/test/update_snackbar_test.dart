// The startup "Update available" snackbar: on platforms where the app
// can update itself its action is Update and runs the same in-app
// download-and-install flow as the Settings → About row; elsewhere the
// old View action still opens the release page. Regression cover for
// the Android report "selecting the update notification took me to the
// release page".
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watchit/main.dart';
import 'package:watchit/services/update_check.dart';
import 'package:watchit/services/update_install.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/messenger.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('wi-upd-snack');
    UpdateCheck.resetForTesting();
    UpdateInstaller.resetForTesting();
  });

  tearDown(() {
    UpdateInstaller.androidPlatformOverride = null;
    UpdateInstaller.appImagePathOverride = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Widget host() => MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        scaffoldMessengerKey: wiMessengerKey,
        home: const Scaffold(body: SizedBox()),
      );

  /// Pumps 1s frames until [text] shows (snackbar queue transitions
  /// need one frame per animation segment).
  Future<void> pumpUntilText(WidgetTester tester, String text) async {
    for (var i = 0; i < 15; i++) {
      if (find.textContaining(text).evaluate().isNotEmpty) return;
      await tester.pump(const Duration(seconds: 1));
    }
  }

  UpdateAsset apkAsset(List<int> bytes) => UpdateAsset(
        name: 'Watch-It-0.1.0-alpha.103.apk',
        url: 'https://example.com/W.apk',
        size: bytes.length,
        sha256: sha256.convert(bytes).toString(),
      );

  test('self-update platform → snackbar action is Update', () {
    UpdateInstaller.androidPlatformOverride = true;
    UpdateCheck.instance
      ..availableTag = 'v0.1.0-alpha.103'
      ..assets = [apkAsset(const [1, 2, 3])];
    final bar = updateAvailableSnackBar(
        'v0.1.0-alpha.103', 'https://example.com/release');
    expect(bar.action?.label, 'Update');
  });

  test('no self-update path → View still opens the release page', () {
    // No overrides, no matching asset for this host → fallback.
    UpdateCheck.instance
      ..availableTag = 'v0.1.0-alpha.103'
      ..assets = const [];
    final bar = updateAvailableSnackBar(
        'v0.1.0-alpha.103', 'https://example.com/release');
    expect(bar.action?.label, 'View');
    expect(updateAvailableSnackBar('v0.1.0-alpha.103', null).action, isNull);
  }, skip: Platform.environment['APPIMAGE'] != null);

  testWidgets(
      'Android: tapping Update downloads the APK and opens the installer',
      (tester) async {
    UpdateInstaller.androidPlatformOverride = true;
    final bytes = utf8.encode('apk-bytes');
    UpdateCheck.instance
      ..availableTag = 'v0.1.0-alpha.103'
      ..assets = [apkAsset(bytes)];
    String? launchedPath;
    UpdateInstaller.instance
      ..client = MockClient((_) async => http.Response.bytes(bytes, 200))
      ..cacheDirOverride = tmp
      ..apkInstallLauncher = (p) async => launchedPath = p;

    await tester.pumpWidget(host());
    wiMessengerKey.currentState!.showSnackBar(updateAvailableSnackBar(
        'v0.1.0-alpha.103', 'https://example.com/release'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1)); // snackbar slide-in
    expect(find.text('Update available: v0.1.0-alpha.103'), findsOneWidget);

    // Real file IO — run outside the fake-async zone.
    await tester.runAsync(() async {
      await tester.tap(find.text('Update'));
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (UpdateInstaller.instance.stage !=
              UpdateInstallStage.readyToInstall &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    expect(UpdateInstaller.instance.stage, UpdateInstallStage.readyToInstall);
    expect(launchedPath, endsWith('Watch-It-0.1.0-alpha.103.apk'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1)); // previous bar slides out
    expect(find.textContaining('Downloading the update'), findsOneWidget);
    // Drop pending snackbar timers before teardown.
    wiMessengerKey.currentState?.clearSnackBars();
    await tester.pump(const Duration(seconds: 1));
    // The tap ran inside runAsync, so its hide-animation callbacks
    // live in the real-async zone — flush them while still mounted.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  });

  testWidgets('AppImage: snackbar update swaps and asks for a restart',
      (tester) async {
    final current = File('${tmp.path}/W.AppImage')
      ..writeAsStringSync('old-version');
    UpdateInstaller.appImagePathOverride = current.path;
    final bytes = utf8.encode('new-version');
    UpdateCheck.instance
      ..availableTag = 'v0.1.0-alpha.103'
      ..assets = [
        UpdateAsset(
          name: 'Watch-It-0.1.0-alpha.103-x86_64.AppImage',
          url: 'https://example.com/W.AppImage',
          size: bytes.length,
          sha256: sha256.convert(bytes).toString(),
        ),
      ];
    UpdateInstaller.instance.client =
        MockClient((_) async => http.Response.bytes(bytes, 200));

    await tester.pumpWidget(host());
    wiMessengerKey.currentState!.showSnackBar(
        updateAvailableSnackBar('v0.1.0-alpha.103', null));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1)); // snackbar slide-in

    await tester.runAsync(() async {
      await tester.tap(find.text('Update'));
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (UpdateInstaller.instance.stage !=
              UpdateInstallStage.awaitingRestart &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    expect(
        UpdateInstaller.instance.stage, UpdateInstallStage.awaitingRestart);
    expect(current.readAsStringSync(), 'new-version');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1)); // previous bar slides out
    expect(find.textContaining('Downloading the update'), findsOneWidget);
    // The progress snackbar expires, then the queued outcome shows.
    await pumpUntilText(tester, 'restart W@tch to finish');
    expect(find.textContaining('restart W@tch to finish'), findsOneWidget);
    wiMessengerKey.currentState?.clearSnackBars();
    await tester.pump(const Duration(seconds: 1));
    // The tap ran inside runAsync, so its hide-animation callbacks
    // live in the real-async zone — flush them while still mounted.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  });

  testWidgets('a failed snackbar update reports the error with a pointer',
      (tester) async {
    UpdateInstaller.androidPlatformOverride = true;
    UpdateCheck.instance
      ..availableTag = 'v0.1.0-alpha.103'
      ..assets = [apkAsset(utf8.encode('apk-bytes'))];
    UpdateInstaller.instance
      ..client = MockClient((_) async => http.Response('nope', 500))
      ..cacheDirOverride = tmp;

    await tester.pumpWidget(host());
    wiMessengerKey.currentState!.showSnackBar(
        updateAvailableSnackBar('v0.1.0-alpha.103', null));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1)); // snackbar slide-in

    await tester.runAsync(() async {
      await tester.tap(find.text('Update'));
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (
          UpdateInstaller.instance.stage != UpdateInstallStage.failed &&
              DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    expect(UpdateInstaller.instance.stage, UpdateInstallStage.failed);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1)); // previous bar slides out
    // Progress snackbar first, then the queued failure report.
    await pumpUntilText(tester, 'Download failed (HTTP 500)');
    expect(find.textContaining('Download failed (HTTP 500)'), findsOneWidget);
    expect(find.textContaining('retry from Settings → About'), findsOneWidget);
    wiMessengerKey.currentState?.clearSnackBars();
    await tester.pump(const Duration(seconds: 1));
    // The tap ran inside runAsync, so its hide-animation callbacks
    // live in the real-async zone — flush them while still mounted.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  });
}
