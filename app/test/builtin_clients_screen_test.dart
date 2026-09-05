import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/screens/builtin_clients_screen.dart';
import 'package:watchit/services/embedded_client.dart';
import 'package:watchit/services/channels_api.dart';
import 'package:watchit/services/my_watch_api.dart';
import 'package:watchit/services/x0x_cellular.dart';
import 'package:watchit/theme/tokens.dart';

import 'fake_embedded_http.dart';

void main() {
  late FakeEmbeddedHttp fake;

  setUp(() {
    fake = FakeEmbeddedHttp();
    HttpOverrides.global = fake;
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    HttpOverrides.global = null;
  });

  Future<void> open(
    WidgetTester tester, {
    Future<ClientHealth> Function()? health,
    Future<ClientVersions?> Function()? versions,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: BuiltInClientsScreen(
        myWatchApi: MyWatchApi(base: FakeEmbeddedHttp.base),
        channelsApi: ChannelsApi(base: FakeEmbeddedHttp.base),
        healthProvider: health,
        versionsProvider: versions ??
            () => EmbeddedClient.versions(baseOverride: FakeEmbeddedHttp.base),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  // Dispose the screen so its poll timer is cancelled before the test
  // framework checks for pending timers.
  Future<void> close(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox());

  testWidgets('renders both switches on with their state lines',
      (tester) async {
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
      'subs': [
        {'pubkey': 'ab' * 32, 'code': 'wchn1-x', 'head': null},
      ],
    };
    await open(tester);

    expect(find.text('My W@tch'), findsOneWidget);
    expect(find.text('Channels'), findsOneWidget);
    expect(find.text('On — connected to your devices'), findsOneWidget);
    expect(
        find.text('On — connected to the channel network'), findsOneWidget);
    final switches =
        tester.widgetList<SwitchListTile>(find.byType(SwitchListTile));
    expect(switches.map((s) => s.value), everyElement(isTrue));
    await close(tester);
  });

  testWidgets('switching My W@tch off posts the switch and reads back off',
      (tester) async {
    fake.myWatchStatus = {
      'supported': true,
      'enabled': true,
      'linked': true,
      'state': 'ready',
      'devices': const [],
    };
    await open(tester);

    await tester.tap(find.text('My W@tch'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(fake.myWatchEnabledPosts, hasLength(1));
    expect(jsonDecode(fake.myWatchEnabledPosts.single), {'enabled': false});
    expect(find.text('Switched off — nothing syncs between devices'),
        findsOneWidget);

    // And back on again.
    await tester.tap(find.text('My W@tch'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(jsonDecode(fake.myWatchEnabledPosts.last), {'enabled': true});
    expect(find.text('On — connected to your devices'), findsOneWidget);
    await close(tester);
  });

  testWidgets('switching Channels off posts the switch and reads back off',
      (tester) async {
    fake.channelsStatus = {
      'supported': true,
      'enabled': true,
      'state': 'ready',
      'message': null,
      'own': null,
      'subs': [
        {'pubkey': 'ab' * 32, 'code': 'wchn1-x', 'head': null},
      ],
    };
    await open(tester);

    await tester.tap(find.text('Channels'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(fake.channelEnabledPosts, hasLength(1));
    expect(jsonDecode(fake.channelEnabledPosts.single), {'enabled': false});
    expect(
        find.textContaining('Switched off — channels get no updates'),
        findsOneWidget);
    await close(tester);
  });

  testWidgets('agents the mobile-data gate paused say paused, and a '
      'manual flip clears the pause', (tester) async {
    SharedPreferences.setMockInitialValues({
      'x0x_cellular_paused_v1': ['myWatch', 'channels'],
    });
    final gate = X0xCellularGate();
    await gate.ensureLoaded();
    fake.myWatchStatus = {
      'supported': true,
      'enabled': false,
      'linked': true,
      'state': 'off',
      'devices': const [],
    };
    fake.channelsStatus = {
      'supported': true,
      'enabled': false,
      'state': 'off',
      'message': null,
      'own': null,
      'subs': const [],
    };
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: BuiltInClientsScreen(
        myWatchApi: MyWatchApi(base: FakeEmbeddedHttp.base),
        channelsApi: ChannelsApi(base: FakeEmbeddedHttp.base),
        gate: gate,
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Paused on mobile data — resumes on Wi-Fi'),
        findsNWidgets(2));
    expect(find.textContaining('Switched off'), findsNothing);

    // Flipping My W@tch on by hand takes the pause with it — Wi-Fi's
    // return must not override the user's explicit choice.
    await tester.tap(find.text('My W@tch'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(jsonDecode(fake.myWatchEnabledPosts.single), {'enabled': true});
    expect(gate.isPaused(X0xAgent.myWatch), isFalse);
    expect(gate.isPaused(X0xAgent.channels), isTrue);
    await close(tester);
  });

  testWidgets('an unsupported feature renders a disabled switch',
      (tester) async {
    fake.myWatchStatus = {
      'supported': false,
      'enabled': true,
      'linked': false,
      'state': 'off',
      'devices': const [],
    };
    await open(tester);

    expect(find.text('Not available on this platform'), findsOneWidget);
    // My W@tch is the second switch (Channels sits on top).
    final myWatchTile = tester.widget<SwitchListTile>(
        find.byType(SwitchListTile).last);
    expect(myWatchTile.onChanged, isNull);
    await close(tester);
  });

  testWidgets('Channels switch sits above My W@tch (CONTENT order)',
      (tester) async {
    await open(tester);
    expect(
      tester.getTopLeft(find.text('Channels')).dy,
      lessThan(tester.getTopLeft(find.text('My W@tch')).dy),
    );
    await close(tester);
  });

  testWidgets('shows the Autonomi connection status from /health',
      (tester) async {
    await open(tester,
        health: () async =>
            const ClientHealth(state: 'ready', peers: 5));
    expect(find.text('Connection'), findsOneWidget);
    expect(find.text('Connected (5 peers)'), findsOneWidget);
    await close(tester);
  });

  testWidgets(
      'per-client version lines come from GET /versions, and the '
      'Details expansion lists the whole stack', (tester) async {
    await open(tester);
    // The fake server's deliberately fake numbers — the UI must render
    // whatever the route says, never hardcoded versions.
    expect(find.text('ant-core 8.8.8 (git abcd1234)'), findsOneWidget);
    expect(find.text('x0x 9.9.9'), findsOneWidget);

    expect(find.text('saorsa-core'), findsNothing); // collapsed
    await tester.scrollUntilVisible(find.text('Version details'), 100);
    await tester.tap(find.text('Version details'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('saorsa-core'), findsOneWidget);
    expect(find.text('7.7.7'), findsOneWidget);
    expect(find.text('saorsa-gossip'), findsOneWidget);
    expect(find.text('6.6.6'), findsOneWidget);
    expect(find.text('ant-quic'), findsOneWidget);
    expect(find.text('5.5.5'), findsOneWidget);
    expect(find.text('App'), findsOneWidget);
    await close(tester);
  });

  testWidgets('Copy versions puts the whole stack on the clipboard',
      (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    await open(tester);
    await tester.scrollUntilVisible(find.text('Version details'), 100);
    await tester.tap(find.text('Version details'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // ensureVisible needs a pump for the scroll to take effect before
    // the tap resolves its hit-test position.
    await tester.ensureVisible(find.text('Copy versions'));
    await tester.pump();
    await tester.tap(find.text('Copy versions'));
    await tester.pump();
    expect(copied, isNotNull);
    expect(copied, contains('W@tch '));
    expect(copied, contains('ant-core 8.8.8 (git abcd1234)'));
    expect(copied, contains('x0x 9.9.9'));
    expect(copied, contains('saorsa-gossip 6.6.6'));
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    await close(tester);
  });

  testWidgets('an old core without /versions hides the version rows',
      (tester) async {
    await open(tester, versions: () async => null);
    expect(find.text('Version details'), findsNothing);
    expect(find.textContaining('ant-core'), findsNothing);
    // The switches still work without version data.
    expect(find.text('Channels'), findsOneWidget);
    expect(find.text('My W@tch'), findsOneWidget);
    await close(tester);
  });
}
