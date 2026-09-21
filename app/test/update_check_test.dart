import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchit/services/update_check.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('isNewerTag', () {
    test('alpha number decides within the same semver', () {
      expect(UpdateCheck.isNewerTag('v0.1.0-alpha.57', '0.1.0', '56'), true);
      expect(UpdateCheck.isNewerTag('v0.1.0-alpha.56', '0.1.0', '56'), false);
      expect(UpdateCheck.isNewerTag('v0.1.0-alpha.55', '0.1.0', '56'), false);
    });

    test('higher semver wins regardless of alpha', () {
      expect(UpdateCheck.isNewerTag('v0.2.0-alpha.1', '0.1.0', '99'), true);
      expect(UpdateCheck.isNewerTag('v1.0.0', '0.1.0', '99'), true);
      expect(UpdateCheck.isNewerTag('v0.0.9-alpha.99', '0.1.0', '1'), false);
    });

    test('stable tag beats any alpha of the same version', () {
      expect(UpdateCheck.isNewerTag('v0.1.0', '0.1.0', '56'), true);
    });

    test('garbage tags are never newer', () {
      expect(UpdateCheck.isNewerTag('nightly', '0.1.0', '56'), false);
      expect(UpdateCheck.isNewerTag('', '0.1.0', '56'), false);
      expect(UpdateCheck.isNewerTag('v0.1.0-beta.1', '0.1.0', '56'), false);
    });
  });

  group('maybeCheck', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      PackageInfo.setMockInitialValues(
        appName: 'watchit',
        packageName: 'watchit',
        version: '0.1.0',
        buildNumber: '56',
        buildSignature: '',
      );
      UpdateCheck.resetForTesting();
    });

    MockClient releaseClient(String tag, {int status = 200}) =>
        MockClient((request) async {
          expect(request.url.host, 'api.github.com');
          return http.Response(
              jsonEncode({
                'tag_name': tag,
                'html_url':
                    'https://github.com/aautonomicc/Watch-It/releases/tag/$tag',
              }),
              status);
        });

    test('newer release sets the tag and notifies', () async {
      final check = UpdateCheck.instance..client = releaseClient('v0.1.0-alpha.57');
      var notified = 0;
      check.addListener(() => notified++);
      await check.maybeCheck();
      expect(check.availableTag, 'v0.1.0-alpha.57');
      expect(check.releaseUrl, contains('alpha.57'));
      expect(notified, 1);
    }, skip: !Platform.isLinux && !Platform.isWindows && !Platform.isMacOS);

    test('same release stays quiet but stamps the check time', () async {
      final check = UpdateCheck.instance..client = releaseClient('v0.1.0-alpha.56');
      await check.maybeCheck();
      expect(check.availableTag, null);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(UpdateCheck.lastCheckPref), isNotNull);
    }, skip: !Platform.isLinux && !Platform.isWindows && !Platform.isMacOS);

    test('24h gate: a recent check short-circuits before any request',
        () async {
      final now = DateTime(2026, 8, 25, 12);
      SharedPreferences.setMockInitialValues({
        UpdateCheck.lastCheckPref:
            now.subtract(const Duration(hours: 23)).millisecondsSinceEpoch,
      });
      var called = false;
      final check = UpdateCheck.instance
        ..client = MockClient((_) async {
          called = true;
          return http.Response('{}', 200);
        });
      await check.maybeCheck(now: () => now);
      expect(called, false);

      // A day later it checks again.
      await check.maybeCheck(
          now: () => now.add(const Duration(hours: 2)));
      expect(called, true);
    }, skip: !Platform.isLinux && !Platform.isWindows && !Platform.isMacOS);

    test('toggle off: no request', () async {
      SharedPreferences.setMockInitialValues(
          {UpdateCheck.enabledPref: false});
      var called = false;
      final check = UpdateCheck.instance
        ..client = MockClient((_) async {
          called = true;
          return http.Response('{}', 200);
        });
      await check.maybeCheck();
      expect(called, false);
    }, skip: !Platform.isLinux && !Platform.isWindows && !Platform.isMacOS);

    test('assets are parsed: apk skips tvtest, AppImage found, digest kept',
        () async {
      final check = UpdateCheck.instance
        ..client = MockClient((request) async => http.Response(
            jsonEncode({
              'tag_name': 'v0.1.0-alpha.57',
              'html_url': 'https://example.com/tag',
              'assets': [
                {
                  'name': 'Watch-It-0.1.0-alpha.57-armeabi-v7a-tvtest.apk',
                  'browser_download_url': 'https://example.com/tvtest.apk',
                  'size': 5,
                },
                {
                  'name': 'Watch-It-0.1.0-alpha.57.apk',
                  'browser_download_url': 'https://example.com/app.apk',
                  'size': 10,
                  'digest': 'sha256:ABCDEF0123',
                },
                {
                  'name': 'Watch-It-0.1.0-alpha.57-x86_64.AppImage',
                  'browser_download_url': 'https://example.com/app.AppImage',
                  'size': 20,
                },
                {
                  'name': 'Watch-It-0.1.0-alpha.57-windows-x64.zip',
                  'browser_download_url': 'https://example.com/win.zip',
                  'size': 30,
                },
                {
                  'name': 'Watch-It-0.1.0-alpha.57-macos-universal.dmg',
                  'browser_download_url': 'https://example.com/mac.dmg',
                  'size': 40,
                },
                {'name': 42}, // malformed entry is skipped, not fatal
              ],
            }),
            200));
      await check.maybeCheck();
      expect(check.assets, hasLength(5));
      expect(check.apkAsset?.name, 'Watch-It-0.1.0-alpha.57.apk');
      expect(check.apkAsset?.size, 10);
      expect(check.apkAsset?.sha256, 'abcdef0123');
      expect(check.appImageAsset?.url, 'https://example.com/app.AppImage');
      expect(check.appImageAsset?.sha256, null);
      expect(check.windowsZipAsset?.url, 'https://example.com/win.zip');
      expect(check.windowsZipAsset?.size, 30);
      expect(check.macDmgAsset?.url, 'https://example.com/mac.dmg');
      expect(check.macDmgAsset?.size, 40);
    }, skip: !Platform.isLinux && !Platform.isWindows && !Platform.isMacOS);

    test('newer release persists; a throttled later launch restores it',
        () async {
      final check = UpdateCheck.instance
        ..client = MockClient((request) async => http.Response(
            jsonEncode({
              'tag_name': 'v0.1.0-alpha.57',
              'html_url': 'https://example.com/tag',
              'assets': [
                {
                  'name': 'Watch-It-0.1.0-alpha.57.apk',
                  'browser_download_url': 'https://example.com/app.apk',
                  'size': 10,
                  'digest': 'sha256:abcdef0123',
                },
              ],
            }),
            200));
      await check.maybeCheck();
      expect(check.availableTag, 'v0.1.0-alpha.57');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(UpdateCheck.availablePref), isNotNull);

      // "Next launch" inside the 24h throttle: no request runs, but the
      // About row / snackbar state comes back from the persisted result
      // (previously it was in-memory only — a rolling blind window).
      UpdateCheck.resetForTesting();
      final relaunch = UpdateCheck.instance
        ..client = MockClient((_) async {
          fail('throttled launch must not hit the network');
        });
      var notified = 0;
      relaunch.addListener(() => notified++);
      await relaunch.maybeCheck();
      expect(relaunch.availableTag, 'v0.1.0-alpha.57');
      expect(relaunch.releaseUrl, 'https://example.com/tag');
      expect(relaunch.apkAsset?.url, 'https://example.com/app.apk');
      expect(relaunch.apkAsset?.size, 10);
      expect(relaunch.apkAsset?.sha256, 'abcdef0123');
      expect(notified, 1);

      // Same launch, second call (app resume): already restored — quiet.
      await relaunch.maybeCheck();
      expect(notified, 1);
    }, skip: !Platform.isLinux && !Platform.isWindows && !Platform.isMacOS);

    test('persisted update is dropped once the app has caught up',
        () async {
      // The stored tag equals the running version — installed some
      // other way since the check that stored it.
      SharedPreferences.setMockInitialValues({
        UpdateCheck.lastCheckPref: DateTime.now().millisecondsSinceEpoch,
        UpdateCheck.availablePref: jsonEncode({
          'tag': 'v0.1.0-alpha.56',
          'url': 'https://example.com/tag',
          'assets': [],
        }),
      });
      final check = UpdateCheck.instance
        ..client = MockClient((_) async {
          fail('throttled launch must not hit the network');
        });
      await check.maybeCheck();
      expect(check.availableTag, null);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(UpdateCheck.availablePref), null);
    }, skip: !Platform.isLinux && !Platform.isWindows && !Platform.isMacOS);

    test('an up-to-date check clears a stale announced update', () async {
      // Restored as available (newer than the running build), but the
      // fresh check says the latest release IS the running build — the
      // row and the stored value must both go.
      SharedPreferences.setMockInitialValues({
        UpdateCheck.availablePref: jsonEncode({
          'tag': 'v0.1.0-alpha.57',
          'url': 'https://example.com/tag',
          'assets': [],
        }),
      });
      final check = UpdateCheck.instance
        ..client = releaseClient('v0.1.0-alpha.56');
      await check.maybeCheck();
      expect(check.availableTag, null);
      expect(check.assets, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(UpdateCheck.availablePref), null);
    }, skip: !Platform.isLinux && !Platform.isWindows && !Platform.isMacOS);

    test('failure is silent and does not stamp the check time', () async {
      final check = UpdateCheck.instance
        ..client = MockClient((_) async => throw const SocketException('offline'));
      await check.maybeCheck();
      expect(check.availableTag, null);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(UpdateCheck.lastCheckPref), null);
    }, skip: !Platform.isLinux && !Platform.isWindows && !Platform.isMacOS);
  });
}
