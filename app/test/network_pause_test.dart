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

/// The Settings → Network "Pause all network activity" switch: pauses
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
  });

  test('start() without a persisted pause does nothing', () async {
    final p = pause();
    await p.start();
    expect(p.paused, isFalse);
    expect(corePosts(), isEmpty);
  });
}
