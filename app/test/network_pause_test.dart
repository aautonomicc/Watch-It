import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/services/app_settings.dart';
import 'package:watchit/services/channels_api.dart';
import 'package:watchit/services/my_watch_api.dart';
import 'package:watchit/services/network_pause.dart';
import 'package:watchit/services/x0x_cellular.dart' show X0xAgent;

import 'fake_embedded_http.dart';

/// The Settings → Network "Offline mode" switch: pauses
/// the embedded Autonomi client and switches off both x0x agents,
/// remembering which so resume re-enables exactly those.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeEmbeddedHttp fake;

  setUp(() {
    fake = FakeEmbeddedHttp();
    HttpOverrides.global = fake;
    SharedPreferences.setMockInitialValues({});
    fake.myWatchStatus = {
      'supported': true,
      'enabled': true,
      'linked': true,
      'state': 'ready',
      'devices': const [],
    };
    fake.channelsStatus = {
      'supported': true,
      'enabled': true,
      'state': 'ready',
      'message': null,
      'own': null,
      'subs': const [],
    };
  });

  tearDown(() {
    HttpOverrides.global = null;
  });

  NetworkPause pause() => NetworkPause(
        base: FakeEmbeddedHttp.base,
        token: 'test',
        myWatchApi: MyWatchApi(base: FakeEmbeddedHttp.base),
        channelsApi: ChannelsApi(base: FakeEmbeddedHttp.base),
      );

  List<bool> corePosts() => [
        for (final body in fake.networkPausePosts)
          (jsonDecode(body) as Map<String, dynamic>)['paused'] as bool,
      ];
  List<bool> myWatchPosts() => [
        for (final body in fake.myWatchEnabledPosts)
          (jsonDecode(body) as Map<String, dynamic>)['enabled'] as bool,
      ];
  List<bool> channelsPosts() => [
        for (final body in fake.channelEnabledPosts)
          (jsonDecode(body) as Map<String, dynamic>)['enabled'] as bool,
      ];

  test('pausing silences the core and both running agents', () async {
    final p = pause();
    await p.setPaused(true);

    expect(p.paused, isTrue);
    expect(await AppSettings.networkPaused(), isTrue);
    expect(corePosts(), [true]);
    expect(myWatchPosts(), [false]);
    expect(channelsPosts(), [false]);
    expect(p.isAgentPaused(X0xAgent.myWatch), isTrue);
    expect(p.isAgentPaused(X0xAgent.channels), isTrue);
  });

  test('resume re-enables exactly what the pause switched off — even '
      'across a restart (fresh instance)', () async {
    await pause().setPaused(true);

    // "Restart": a fresh instance loads the persisted memory.
    final p = pause();
    await p.setPaused(false);

    expect(p.paused, isFalse);
    expect(await AppSettings.networkPaused(), isFalse);
    expect(corePosts(), [true, false]);
    expect(myWatchPosts(), [false, true]);
    expect(channelsPosts(), [false, true]);
    expect(p.isAgentPaused(X0xAgent.myWatch), isFalse);
    expect(p.isAgentPaused(X0xAgent.channels), isFalse);
  });

  test("a user's own off is never touched: not paused, not resumed",
      () async {
    fake.myWatchStatus['enabled'] = false; // user switched it off
    final p = pause();
    await p.setPaused(true);
    expect(myWatchPosts(), isEmpty);
    expect(channelsPosts(), [false]);
    expect(p.isAgentPaused(X0xAgent.myWatch), isFalse);

    await p.setPaused(false);
    // Only channels comes back; My W@tch stays the user's off.
    expect(myWatchPosts(), isEmpty);
    expect(channelsPosts(), [false, true]);
  });

  test('unsupported agents are never touched', () async {
    fake.myWatchStatus = {'supported': false};
    fake.channelsStatus = {'supported': false};
    final p = pause();
    await p.setPaused(true);
    expect(myWatchPosts(), isEmpty);
    expect(channelsPosts(), isEmpty);
    expect(corePosts(), [true]); // the Autonomi client still pauses
  });

  test('start() re-applies a persisted pause to the fresh core',
      () async {
    SharedPreferences.setMockInitialValues({'network_paused_v1': true});
    final p = pause();
    await p.start();
    expect(p.paused, isTrue);
    expect(corePosts(), [true]);
    // Agents are NOT re-touched at startup — their off state persists
    // in the core's own marker files.
    expect(myWatchPosts(), isEmpty);
    expect(channelsPosts(), isEmpty);
    p.dispose(); // stops the idle timer start() armed
  });

  test('start() without a persisted pause does nothing', () async {
    final p = pause();
    await p.start();
    expect(p.paused, isFalse);
    expect(corePosts(), isEmpty);
    p.dispose();
  });

  group('auto-pause when idle', () {
    // Injected clock + activity probes so the tests drive time and
    // busyness directly (the real instance polls DownloadManager and
    // BatchUploadSession once a minute).
    late DateTime now;
    var downloadsBusy = false;
    var uploadsBusy = false;

    setUp(() {
      now = DateTime(2026, 9, 3, 12);
      downloadsBusy = false;
      uploadsBusy = false;
    });

    NetworkPause idle() => NetworkPause(
          base: FakeEmbeddedHttp.base,
          token: 'test',
          myWatchApi: MyWatchApi(base: FakeEmbeddedHttp.base),
          channelsApi: ChannelsApi(base: FakeEmbeddedHttp.base),
          now: () => now,
          downloadsActive: () => downloadsBusy,
          uploadsActive: () => uploadsBusy,
        );

    test('pauses after the threshold with nothing going on — the full '
        'pause, agents included', () async {
      final p = idle();
      await p.ensureLoaded();
      expect(p.idleMinutes, 30); // default

      now = now.add(const Duration(minutes: 29));
      await p.checkIdle();
      expect(p.paused, isFalse);

      now = now.add(const Duration(minutes: 1));
      await p.checkIdle();
      expect(p.paused, isTrue);
      expect(p.autoPaused, isTrue);
      expect(await AppSettings.networkPaused(), isTrue);
      expect(corePosts(), [true]);
      expect(myWatchPosts(), [false]);
      expect(channelsPosts(), [false]);
    });

    test('playback, downloads and uploads each hold the pause off',
        () async {
      final p = idle();

      p.setStreamingActive('player', true);
      now = now.add(const Duration(hours: 2));
      await p.checkIdle();
      expect(p.paused, isFalse);
      p.setStreamingActive('player', false);

      downloadsBusy = true;
      now = now.add(const Duration(hours: 2));
      await p.checkIdle();
      expect(p.paused, isFalse);
      downloadsBusy = false;

      uploadsBusy = true;
      now = now.add(const Duration(hours: 2));
      await p.checkIdle();
      expect(p.paused, isFalse);
      uploadsBusy = false;

      // Activity was stamped at the last busy tick, so the idle clock
      // starts from there — not from the hours of busy time before.
      now = now.add(const Duration(minutes: 29));
      await p.checkIdle();
      expect(p.paused, isFalse);
      now = now.add(const Duration(minutes: 1));
      await p.checkIdle();
      expect(p.paused, isTrue);
    });

    test('noteActivity lifts an automatic pause — and restarts the idle '
        'clock', () async {
      final p = idle();
      now = now.add(const Duration(minutes: 30));
      await p.checkIdle();
      expect(p.paused, isTrue);

      await p.noteActivity();
      expect(p.paused, isFalse);
      expect(p.autoPaused, isFalse);
      expect(corePosts(), [true, false]);
      expect(myWatchPosts(), [false, true]);
      expect(channelsPosts(), [false, true]);

      // The clock restarted at the resume.
      now = now.add(const Duration(minutes: 29));
      await p.checkIdle();
      expect(p.paused, isFalse);
    });

    test("noteActivity never lifts the user's own pause", () async {
      final p = idle();
      await p.setPaused(true);
      await p.noteActivity();
      expect(p.paused, isTrue);
      expect(corePosts(), [true]); // no resume post
    });

    test('the automatic flag survives a restart (fresh instance)',
        () async {
      final p = idle();
      now = now.add(const Duration(minutes: 30));
      await p.checkIdle();
      expect(p.paused, isTrue);

      final fresh = idle();
      await fresh.ensureLoaded();
      expect(fresh.paused, isTrue);
      expect(fresh.autoPaused, isTrue);
      await fresh.noteActivity();
      expect(fresh.paused, isFalse);
    });

    test('0 minutes switches the automatic pause off; checkIdle never '
        'fires while already paused', () async {
      final p = idle();
      await p.setIdleMinutes(0);
      now = now.add(const Duration(days: 1));
      await p.checkIdle();
      expect(p.paused, isFalse);
      expect(await AppSettings.networkAutoPauseMinutes(), 0);

      await p.setIdleMinutes(10);
      await p.setPaused(true); // manual
      now = now.add(const Duration(hours: 1));
      await p.checkIdle();
      expect(p.autoPaused, isFalse); // untouched — still the manual pause
    });
  });
}
