import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/services/app_settings.dart';
import 'package:watchit/services/my_watch_api.dart';
import 'package:watchit/services/network_events.dart';
import 'package:watchit/services/x0x_cellular.dart';

import 'fake_embedded_http.dart';

/// The mobile-data gate for the x0x agent: pauses My W@tch on cellular
/// when its Settings → Network → Mobile data switch says Wi-Fi only,
/// resumes on Wi-Fi, and never overrides a user's own off.
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
  });

  tearDown(() {
    HttpOverrides.global = null;
  });

  X0xCellularGate gate({NetworkEvents? network}) => X0xCellularGate(
        myWatchApi: MyWatchApi(base: FakeEmbeddedHttp.base),
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
  test('mobile data defaults to allowed', () async {
    expect(await AppSettings.myWatchOnCellular(), isTrue);
  });

  test('with the default allow settings nothing happens on cellular',
      () async {
    final network = cellular();
    await Future<void>.delayed(Duration.zero);
    final g = gate(network: network);
    await g.onPolicyChanged();
    expect(fake.myWatchEnabledPosts, isEmpty);
    expect(g.isPaused(X0xAgent.myWatch), isFalse);
  });

  test('pauses the disallowed agent on cellular and persists the '
      'pause', () async {
    SharedPreferences.setMockInitialValues({'mywatch_cellular_v1': false});
    final network = cellular();
    await Future<void>.delayed(Duration.zero);
    final g = gate(network: network);
    await g.onPolicyChanged();
    expect(myWatchPosts(), [false]);
    expect(g.isPaused(X0xAgent.myWatch), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('x0x_cellular_paused_v1'), ['myWatch']);
  });

  test('resumes a gate-paused agent when Wi-Fi returns', () async {
    SharedPreferences.setMockInitialValues({
      'mywatch_cellular_v1': false,
      'x0x_cellular_paused_v1': ['myWatch'],
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
    expect(myWatchPosts(), isEmpty);
    expect(g.isPaused(X0xAgent.myWatch), isTrue);

    transport.add([ConnectivityResult.wifi]);
    await Future<void>.delayed(Duration.zero);
    await g.onPolicyChanged(); // joins the queued transport apply
    expect(myWatchPosts(), [true]);
    expect(g.isPaused(X0xAgent.myWatch), isFalse);
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
    SharedPreferences.setMockInitialValues({'mywatch_cellular_v1': false});
    fake.myWatchStatus = {'supported': false};
    final network = cellular();
    await Future<void>.delayed(Duration.zero);
    final g = gate(network: network);
    await g.onPolicyChanged();
    expect(fake.myWatchEnabledPosts, isEmpty);
    expect(g.isPaused(X0xAgent.myWatch), isFalse);
  });

  test('a manual switch change clears the pause so Wi-Fi cannot '
      'override it', () async {
    SharedPreferences.setMockInitialValues({
      'mywatch_cellular_v1': false,
      'x0x_cellular_paused_v1': ['myWatch'],
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

    await g.noteManualChange(X0xAgent.myWatch);
    expect(g.isPaused(X0xAgent.myWatch), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('x0x_cellular_paused_v1'), isEmpty);

    // Wi-Fi returning must not touch the switch the user now owns.
    transport.add([ConnectivityResult.wifi]);
    await Future<void>.delayed(Duration.zero);
    await g.onPolicyChanged();
    expect(fake.myWatchEnabledPosts, isEmpty);
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
      network: NetworkEvents(
          stream: const Stream.empty(),
          check: () async => [ConnectivityResult.wifi]),
    );
    await g.onPolicyChanged();
    expect(g.isPaused(X0xAgent.myWatch), isTrue);
  });
}
