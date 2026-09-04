import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/screens/data_usage_screen.dart';
import 'package:watchit/services/embedded_client.dart';
import 'package:watchit/theme/tokens.dart';

import 'fake_embedded_http.dart';

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

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: const DataUsageScreen(
          baseOverride: FakeEmbeddedHttp.base, tokenOverride: 'sekrit'),
    ));
    await tester.pumpAndSettle();
  }

  /// Unmounts the screen so its 5 s poll timer is cancelled.
  Future<void> close(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox());

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
    expect(find.text('My W@tch'), findsOneWidget);
    expect(find.text('Channels'), findsOneWidget);
    final antY = tester.getTopLeft(find.text('Autonomi client')).dy;
    final mwY = tester.getTopLeft(find.text('My W@tch')).dy;
    final chY = tester.getTopLeft(find.text('Channels')).dy;
    expect(antY, lessThan(mwY));
    expect(mwY, lessThan(chY));
    // Autonomi extras: the media split and the summary freshness.
    expect(find.text('of which media: 200 MB'), findsOneWidget);
    expect(find.text('updated 2 min ago'), findsOneWidget);
    // Period footer with a working date and the reset button.
    expect(find.text('Since 1 Sep 2026'), findsOneWidget);
    expect(find.text('Reset'), findsOneWidget);
    // The fake reports both agents on — no Off tags.
    expect(find.text('Off'), findsNothing);
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
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: DataUsageScreen(
        baseOverride: FakeEmbeddedHttp.base,
        tokenOverride: 'sekrit',
        clock: () => now,
      ),
    ));
    await tester.pumpAndSettle();
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
    expect(find.textContaining('Current rate: ↓ 1.0 MB/s'), findsOneWidget);
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

  testWidgets('switched-off agents show the Off tag', (tester) async {
    fake.myWatchStatus = {
      'supported': true,
      'linked': false,
      'state': 'off',
      'enabled': false,
      'devices': const [],
    };
    fake.channelsStatus['enabled'] = false;
    await open(tester);
    expect(find.text('Off'), findsNWidgets(2));
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
}
