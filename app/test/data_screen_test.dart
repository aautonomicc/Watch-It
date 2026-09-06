import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/screens/data_screen.dart';
import 'package:watchit/services/app_settings.dart';
import 'package:watchit/services/channels_api.dart';
import 'package:watchit/services/embedded_client.dart';
import 'package:watchit/services/my_watch_api.dart';
import 'package:watchit/services/network_pause.dart';
import 'package:watchit/services/x0x_cellular.dart';
import 'package:watchit/theme/tokens.dart';

import 'fake_embedded_http.dart';

/// Records policy-change notifications instead of talking to the
/// embedded client.
class _RecordingGate extends X0xCellularGate {
  int policyChanges = 0;

  @override
  Future<void> onPolicyChanged() {
    policyChanges++;
    return Future.value();
  }
}

void main() {
  late FakeEmbeddedHttp fake;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    fake = FakeEmbeddedHttp();
    HttpOverrides.global = fake;
  });

  tearDown(() {
    HttpOverrides.global = null;
  });

  Future<void> open(
    WidgetTester tester, {
    X0xCellularGate? gate,
    Future<ClientHealth> Function()? health,
    DateTime Function()? clock,
  }) async {
    // The page holds usage + auto-pause + clients + mobile data — a
    // tall viewport builds it all, so no per-assert scrolling.
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: DataScreen(
        baseOverride: FakeEmbeddedHttp.base,
        tokenOverride: 'sekrit',
        myWatchApi: MyWatchApi(base: FakeEmbeddedHttp.base),
        channelsApi: ChannelsApi(base: FakeEmbeddedHttp.base),
        gate: gate,
        healthProvider: health,
        clock: clock,
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// Unmounts the screen so its 5 s poll timer is cancelled.
  Future<void> close(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox());

  group('usage block', () {
    testWidgets('shows total and per-component up/down from /stats',
        (tester) async {
      fake.stats = {
        'period_start_ms': DateTime(2026, 9, 1).millisecondsSinceEpoch,
        'total': {'rx': 300 * 1024 * 1024, 'tx': 30 * 1024 * 1024},
        'ant': {
          'rx': 250 * 1024 * 1024,
          'tx': 20 * 1024 * 1024,
          'media_rx': 200 * 1024 * 1024,
          'stale_secs': 120,
        },
        'mywatch': {'rx': 40 * 1024 * 1024, 'tx': 6 * 1024 * 1024},
        'channels': {'rx': 10 * 1024 * 1024, 'tx': 4 * 1024 * 1024},
      };
      await open(tester);

      expect(find.text('Total data usage'), findsOneWidget);
      expect(find.text('330 MB'), findsOneWidget); // big total
      expect(find.text('↑ 30.0 MB'), findsOneWidget);
      expect(find.text('↓ 300 MB'), findsOneWidget);
      // Component rows, top to bottom: Autonomi, My W@tch, Channels.
      expect(find.text('Autonomi client'), findsOneWidget);
      final antY = tester.getTopLeft(find.text('Autonomi client')).dy;
      final mwY = tester.getTopLeft(find.text('My W@tch').first).dy;
      final chY = tester.getTopLeft(find.text('Channels').first).dy;
      expect(antY, lessThan(mwY));
      expect(mwY, lessThan(chY));
      // Autonomi extras: the media split and the summary freshness.
      expect(find.text('of which media: 200 MB'), findsOneWidget);
      expect(find.text('updated 2 min ago'), findsOneWidget);
      // Period footer with a working date and the reset button.
      expect(find.text('Since 1 Sep 2026'), findsOneWidget);
      expect(find.text('Reset'), findsOneWidget);
      await close(tester);
    });

    testWidgets('rate row appears from consecutive polls', (tester) async {
      fake.stats = {
        'period_start_ms': DateTime(2026, 9, 1).millisecondsSinceEpoch,
        'total': {'rx': 1000, 'tx': 100},
        'ant': {'rx': 1000, 'tx': 100, 'media_rx': 0, 'stale_secs': null},
        'mywatch': {'rx': 0, 'tx': 0},
        'channels': {'rx': 0, 'tx': 0},
      };
      // Injected clock: fake-async pumps don't advance DateTime.now().
      var now = DateTime(2026, 9, 4, 12, 0, 0);
      await open(tester, clock: () => now);
      // One poll answered: no rate yet, and the pre-first-summary caption.
      expect(find.textContaining('Current rate'), findsNothing);
      expect(find.text('first update within ~5 minutes of connecting'),
          findsOneWidget);

      // 5 MB more down over the next 5 s poll ≈ 1.0 MB/s.
      fake.stats = Map.of(fake.stats)
        ..['total'] = {'rx': 1000 + 5 * 1024 * 1024, 'tx': 100};
      now = now.add(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(
          find.textContaining('Current rate: ↓ 1.0 MB/s'), findsOneWidget);
      await close(tester);
    });

    testWidgets('reset asks for confirmation, posts, and zeroes',
        (tester) async {
      fake.stats = {
        'period_start_ms': DateTime(2026, 9, 1).millisecondsSinceEpoch,
        'total': {'rx': 5 * 1024 * 1024, 'tx': 1024 * 1024},
        'ant': {
          'rx': 5 * 1024 * 1024,
          'tx': 1024 * 1024,
          'media_rx': 0,
          'stale_secs': 10,
        },
        'mywatch': {'rx': 0, 'tx': 0},
        'channels': {'rx': 0, 'tx': 0},
      };
      await open(tester);
      // 6 MB period total on the card and as the ant row's own total;
      // the ↓ 5 MB appears on both the card and the ant row.
      expect(find.text('6.0 MB'), findsNWidgets(2));
      expect(find.text('↓ 5.0 MB'), findsNWidgets(2));

      // Cancel first: nothing posted, totals stand.
      await tester.tap(find.text('Reset'));
      await tester.pumpAndSettle();
      expect(find.text('Reset data usage?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(fake.statsResets, 0);
      expect(find.text('6.0 MB'), findsNWidgets(2));

      // Confirm: POST /stats/reset, screen shows the fresh zeros.
      await tester.tap(find.text('Reset'));
      await tester.pumpAndSettle();
      // The dialog's own Reset button is the last on screen.
      await tester.tap(find.text('Reset').last);
      await tester.pumpAndSettle();
      expect(fake.statsResets, 1);
      expect(find.text('6.0 MB'), findsNothing);
      expect(find.text('0 B'), findsWidgets);
      await close(tester);
    });

    testWidgets('switched-off agents show the Off tag beside their usage',
        (tester) async {
      fake.myWatchStatus = {
        'supported': true,
        'linked': false,
        'state': 'off',
        'enabled': false,
        'devices': const [],
      };
      fake.channelsStatus['enabled'] = false;
      await open(tester);
      // Two usage-row tags plus the two pills' own Off segments.
      expect(find.text('Off'), findsNWidgets(4));
      await close(tester);
    });

    test('DataUsageStats parses the /stats shape', () {
      final stats = DataUsageStats.fromJson({
        'period_start_ms': 1234,
        'total': {'rx': 10, 'tx': 2},
        'ant': {'rx': 7, 'tx': 1, 'media_rx': 5, 'stale_secs': 60},
        'mywatch': {'rx': 2, 'tx': 1},
        'channels': {'rx': 1, 'tx': 0},
      });
      expect(stats.periodStart.millisecondsSinceEpoch, 1234);
      expect(stats.total.total, 12);
      expect(stats.ant.rx, 7);
      expect(stats.antMediaRx, 5);
      expect(stats.antStaleSecs, 60);
      expect(stats.myWatch.tx, 1);
      expect(stats.channels.rx, 1);
      // Absent stale_secs (pre-first-summary) parses as null.
      final fresh = DataUsageStats.fromJson({
        'period_start_ms': 1,
        'total': {'rx': 0, 'tx': 0},
        'ant': {'rx': 0, 'tx': 0, 'media_rx': 0, 'stale_secs': null},
        'mywatch': {'rx': 0, 'tx': 0},
        'channels': {'rx': 0, 'tx': 0},
      });
      expect(fresh.antStaleSecs, isNull);
    });

    test('sinceDateLabel formats without intl', () {
      expect(sinceDateLabel(DateTime(2026, 9, 4)), '4 Sep 2026');
      expect(sinceDateLabel(DateTime(2025, 12, 31)), '31 Dec 2025');
      expect(sinceDateLabel(DateTime(2027, 1, 1)), '1 Jan 2027');
    });
  });

  group('built-in clients', () {
    testWidgets(
        'page order: usage, auto-pause, clients with default pills, '
        'mobile data', (tester) async {
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

      final usageY = tester.getTopLeft(find.text('Total data usage')).dy;
      final pauseY =
          tester.getTopLeft(find.text('Auto-pause when idle')).dy;
      final clientsY =
          tester.getTopLeft(find.text('BUILT-IN CLIENTS')).dy;
      final mobileY = tester.getTopLeft(find.text('MOBILE DATA')).dy;
      expect(usageY, lessThan(pauseY));
      expect(pauseY, lessThan(clientsY));
      expect(clientsY, lessThan(mobileY));

      // State lines, and Channels' pill above My W@tch's (the CONTENT
      // section's order).
      expect(find.text('On — connected to your devices'), findsOneWidget);
      expect(find.text('On — connected to the channel network'),
          findsOneWidget);
      final pills = find.byType(SegmentedButton<ClientNetMode>);
      expect(pills, findsNWidgets(2));
      // Both agents on with the cellular default: Wi-Fi + mobile.
      for (final pill in
          tester.widgetList<SegmentedButton<ClientNetMode>>(pills)) {
        expect(pill.selected, {ClientNetMode.wifiAndMobile});
      }
      // Streaming and Downloads with their defaults.
      expect(find.text('Streaming'), findsOneWidget);
      expect(find.text('Downloads'), findsOneWidget);
      expect(find.text('Ask first'), findsOneWidget);
      expect(find.text('Wi-Fi only'), findsOneWidget);
      await close(tester);
    });

    testWidgets('Off pill switches the agent off and reads back off',
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

      // The Channels pill sits above My W@tch's — its Off is first.
      await tester.tap(find.text('Off').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(fake.channelEnabledPosts, hasLength(1));
      expect(jsonDecode(fake.channelEnabledPosts.single),
          {'enabled': false});
      expect(find.textContaining('Off — channels get no updates'),
          findsOneWidget);
      await close(tester);
    });

    testWidgets(
        'Wi-Fi and Wi-Fi + mobile pills persist the cellular pref and '
        'poke the gate — no agent flip while it is on', (tester) async {
      final gate = _RecordingGate();
      fake.channelsStatus = {
        'supported': true,
        'enabled': true,
        'state': 'ready',
        'message': null,
        'own': null,
        'subs': const [],
      };
      await open(tester, gate: gate);

      await tester.tap(find.text('Wi-Fi').first);
      await tester.pumpAndSettle();
      expect(await AppSettings.channelsOnCellular(), isFalse);
      expect(await AppSettings.myWatchOnCellular(), isTrue);
      expect(gate.policyChanges, 1);
      expect(fake.channelEnabledPosts, isEmpty);

      await tester.tap(find.text('Wi-Fi + mobile').first);
      await tester.pumpAndSettle();
      expect(await AppSettings.channelsOnCellular(), isTrue);
      expect(gate.policyChanges, 2);
      expect(fake.channelEnabledPosts, isEmpty);
      await close(tester);
    });

    testWidgets('Wi-Fi pill turns a hand-switched-off agent back on',
        (tester) async {
      final gate = _RecordingGate();
      fake.myWatchStatus = {
        'supported': true,
        'enabled': false,
        'linked': true,
        'state': 'off',
        'devices': const [],
      };
      await open(tester, gate: gate);
      expect(find.text('Off — nothing syncs between devices'),
          findsOneWidget);

      // My W@tch's pill is the lower one.
      await tester.tap(find.text('Wi-Fi').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(jsonDecode(fake.myWatchEnabledPosts.single),
          {'enabled': true});
      expect(await AppSettings.myWatchOnCellular(), isFalse);
      expect(gate.policyChanges, 1);
      await close(tester);
    });

    testWidgets(
        'a gate-paused agent reads Wi-Fi + paused, and Off clears the '
        'pause', (tester) async {
      // A gate pause only ever exists alongside the Wi-Fi-only pref.
      SharedPreferences.setMockInitialValues({
        'x0x_cellular_paused_v1': ['channels'],
        'channels_cellular_v1': false,
      });
      final gate = X0xCellularGate();
      await gate.ensureLoaded();
      fake.channelsStatus = {
        'supported': true,
        'enabled': false,
        'state': 'off',
        'message': null,
        'own': null,
        'subs': const [],
      };
      await open(tester, gate: gate);

      expect(find.text('Paused on mobile data — resumes on Wi-Fi'),
          findsOneWidget);
      // The pause is the Wi-Fi rule at work — the pill must NOT read
      // Off (Wi-Fi's return resumes the agent by itself).
      final channelsPill = tester.widget<SegmentedButton<ClientNetMode>>(
          find.byType(SegmentedButton<ClientNetMode>).first);
      expect(channelsPill.selected, {ClientNetMode.wifi});

      // An explicit Off wins over the gate: pause forgotten, agent off.
      // (Scoped to the pill — the usage block shows an 'Off' tag too.)
      await tester.tap(find.descendant(
          of: find.byType(SegmentedButton<ClientNetMode>).first,
          matching: find.text('Off')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(gate.isPaused(X0xAgent.channels), isFalse);
      expect(jsonDecode(fake.channelEnabledPosts.single),
          {'enabled': false});
      await close(tester);
    });

    testWidgets('an unsupported feature renders a disabled pill',
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
      // My W@tch is the second pill (Channels sits on top).
      final myWatchPill = tester.widget<SegmentedButton<ClientNetMode>>(
          find.byType(SegmentedButton<ClientNetMode>).last);
      expect(myWatchPill.onSelectionChanged, isNull);
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
  });

  group('mobile data policies', () {
    testWidgets('streaming policy change persists', (tester) async {
      await open(tester);

      await tester.tap(find.text('Streaming'));
      await tester.pumpAndSettle();
      expect(find.text('Streaming on mobile data'), findsOneWidget);
      // Pick Wi-Fi only from the dialog (the Downloads tile already
      // shows the same words — the dialog's copy is the last on screen).
      await tester.tap(find.text('Wi-Fi only').last);
      await tester.pumpAndSettle();

      expect(await AppSettings.streamingNetworkPolicy(),
          StreamingNetworkPolicy.wifiOnly);
      // Tile now shows the choice (plus the Downloads tile's own).
      expect(find.text('Wi-Fi only'), findsNWidgets(2));
      await close(tester);
    });

    testWidgets('downloads policy change persists', (tester) async {
      await open(tester);

      await tester.tap(find.text('Downloads'));
      await tester.pumpAndSettle();
      expect(find.text('Download over'), findsOneWidget);
      await tester.tap(find.text('Wi-Fi + mobile data'));
      await tester.pumpAndSettle();

      expect(await AppSettings.downloadNetworkPolicy(),
          DownloadNetworkPolicy.any);
      expect(find.text('Wi-Fi + mobile data'), findsOneWidget);
      await close(tester);
    });
  });

  group('auto-pause when idle', () {
    testWidgets('tile opens the picker and persists the choice',
        (tester) async {
      await open(tester);

      await tester.tap(find.text('Auto-pause when idle'));
      await tester.pumpAndSettle();
      expect(find.text('After 30 minutes  ·  default'), findsOneWidget);
      await tester.tap(find.text('After 10 minutes'));
      await tester.pumpAndSettle();

      expect(NetworkPause.instance.idleMinutes, 10);
      expect(find.textContaining('After 10 minutes'), findsOneWidget);
      // Restore the singleton's default for other tests.
      await NetworkPause.instance.setIdleMinutes(30);
      await close(tester);
    });
  });
}
