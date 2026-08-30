import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/services/app_settings.dart';
import 'package:watchit/services/my_watch_api.dart';
import 'package:watchit/services/channels_api.dart';
import 'package:watchit/services/network_events.dart';
import 'package:watchit/services/x0x_cellular.dart';

import 'fake_embedded_http.dart';

/// The mobile-data gate for the x0x agents: pauses My W@tch / Channels
/// on cellular when their Settings → Network → Mobile data switch says
/// Wi-Fi only, resumes on Wi-Fi, and never overrides a user's own off.
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

  X0xCellularGate gate({NetworkEvents? network}) => X0xCellularGate(
        myWatchApi: MyWatchApi(base: FakeEmbeddedHttp.base),
        channelsApi: ChannelsApi(base: FakeEmbeddedHttp.base),
        network: network,
      );

  NetworkEvents cellular() {
    final network = NetworkEvents(
        stream: const Stream.empty(),
        check: () async => [ConnectivityResult.mobile]);
    network.start();
    return network;
  }

  List<bool> myWatchPosts() => [
        for (final body in fake.myWatchEnabledPosts)
          (jsonDecode(body) as Map<String, dynamic>)['enabled'] as bool,
      ];
  List<bool> channelsPosts() => [
        for (final body in fake.channelEnabledPosts)
          (jsonDecode(body) as Map<String, dynamic>)['enabled'] as bool,
      ];

  test('mobile data defaults to allowed for both agents', () async {
    expect(await AppSettings.myWatchOnCellular(), isTrue);
    expect(await AppSettings.channelsOnCellular(), isTrue);
  });

  test('with the default allow settings nothing happens on cellular',
      () async {
    final network = cellular();
    await Future<void>.delayed(Duration.zero);
    final g = gate(network: network);
    await g.onPolicyChanged();
    expect(fake.myWatchEnabledPosts, isEmpty);
    expect(fake.channelEnabledPosts, isEmpty);
    expect(g.isPaused(X0xAgent.myWatch), isFalse);
    expect(g.isPaused(X0xAgent.channels), isFalse);
  });

  test('pauses only the disallowed agent on cellular and persists the '
      'pause', () async {
    SharedPreferences.setMockInitialValues({'mywatch_cellular_v1': false});
    final network = cellular();
    await Future<void>.delayed(Duration.zero);
    final g = gate(network: network);
    await g.onPolicyChanged();
    expect(myWatchPosts(), [false]);
    expect(channelsPosts(), isEmpty); // still allowed
    expect(g.isPaused(X0xAgent.myWatch), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('x0x_cellular_paused_v1'), ['myWatch']);
  });

  test('resumes a gate-paused agent when Wi-Fi returns', () async {
    SharedPreferences.setMockInitialValues({
      'channels_cellular_v1': false,
      'x0x_cellular_paused_v1': ['channels'],
    });
    final transport =
        StreamController<List<ConnectivityResult>>.broadcast();
    final network = NetworkEvents(
        stream: transport.stream,
        check: () async => [ConnectivityResult.mobile]);
    network.start();
    await Future<void>.delayed(Duration.zero);
    final g = gate(network: network);
    g.start(initialDelay: Duration.zero);
    await Future<void>.delayed(Duration.zero);
    await g.onPolicyChanged(); // still on cellular: stays paused
    expect(channelsPosts(), isEmpty);
    expect(g.isPaused(X0xAgent.channels), isTrue);

    transport.add([ConnectivityResult.wifi]);
    await Future<void>.delayed(Duration.zero);
    await g.onPolicyChanged(); // joins the queued transport apply
    expect(channelsPosts(), [true]);
    expect(g.isPaused(X0xAgent.channels), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('x0x_cellular_paused_v1'), isEmpty);
    await transport.close();
  });

  test('allowing mobile data again resumes a paused agent right away',
      () async {
    SharedPreferences.setMockInitialValues({
      'x0x_cellular_paused_v1': ['myWatch'],
    });
    final network = cellular();
    await Future<void>.delayed(Duration.zero);
    final g = gate(network: network);
    await g.onPolicyChanged(); // mywatch_cellular back at default true
    expect(myWatchPosts(), [true]);
    expect(g.isPaused(X0xAgent.myWatch), isFalse);
  });

  test('never pauses an agent the user already switched off — and never '
      'switches it back on', () async {
    SharedPreferences.setMockInitialValues({'mywatch_cellular_v1': false});
    fake.myWatchStatus['enabled'] = false; // user's own off
    final network = cellular();
    await Future<void>.delayed(Duration.zero);
    final g = gate(network: network);
    await g.onPolicyChanged();
    expect(fake.myWatchEnabledPosts, isEmpty);
    expect(g.isPaused(X0xAgent.myWatch), isFalse);
  });

  test('unsupported agent is never touched', () async {
    SharedPreferences.setMockInitialValues({'channels_cellular_v1': false});
    fake.channelsStatus = {
      'supported': false,
      'enabled': true,
      'state': 'off',
      'message': null,
      'own': null,
      'subs': const [],
    };
    final network = cellular();
    await Future<void>.delayed(Duration.zero);
    final g = gate(network: network);
    await g.onPolicyChanged();
    expect(fake.channelEnabledPosts, isEmpty);
    expect(g.isPaused(X0xAgent.channels), isFalse);
  });

  test('a manual switch change clears the pause so Wi-Fi cannot '
      'override it', () async {
    SharedPreferences.setMockInitialValues({
      'channels_cellular_v1': false,
      'x0x_cellular_paused_v1': ['channels'],
    });
    final transport =
        StreamController<List<ConnectivityResult>>.broadcast();
    final network = NetworkEvents(
        stream: transport.stream,
        check: () async => [ConnectivityResult.mobile]);
    network.start();
    await Future<void>.delayed(Duration.zero);
    final g = gate(network: network);
    g.start(initialDelay: Duration.zero);
    await Future<void>.delayed(Duration.zero);

    await g.noteManualChange(X0xAgent.channels);
    expect(g.isPaused(X0xAgent.channels), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('x0x_cellular_paused_v1'), isEmpty);

    // Wi-Fi returning must not touch the switch the user now owns.
    transport.add([ConnectivityResult.wifi]);
    await Future<void>.delayed(Duration.zero);
    await g.onPolicyChanged();
    expect(fake.channelEnabledPosts, isEmpty);
    await transport.close();
  });

  test('a failed resume keeps the pause flagged for a later retry',
      () async {
    SharedPreferences.setMockInitialValues({
      'x0x_cellular_paused_v1': ['myWatch'],
    });
    // Unreachable client: setEnabled(true) throws. The fake intercepts
    // every port, so drop it for this test to hit a real dead socket.
    HttpOverrides.global = null;
    final g = X0xCellularGate(
      myWatchApi: MyWatchApi(base: 'http://127.0.0.1:1'),
      channelsApi: ChannelsApi(base: 'http://127.0.0.1:1'),
      network: NetworkEvents(
          stream: const Stream.empty(),
          check: () async => [ConnectivityResult.wifi]),
    );
    await g.onPolicyChanged();
    expect(g.isPaused(X0xAgent.myWatch), isTrue);
  });
}
