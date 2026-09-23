import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/services/data_alert.dart';
import 'package:watchit/services/embedded_client.dart';
import 'package:watchit/widgets/messenger.dart';

/// A /stats body whose only content is [gb] GB of ant download on
/// [day] (`2026-09-23` style key).
DataUsageStats statsWithDay(String day, int gb) {
  const gib = 1024 * 1024 * 1024;
  return DataUsageStats.fromJson({
    'period_start_ms': 1,
    'total': {'rx': gb * gib, 'tx': 0},
    'ant': {'rx': gb * gib, 'tx': 0, 'media_rx': 0, 'stale_secs': null},
    'mywatch': {'rx': 0, 'tx': 0},
    'channels': {'rx': 0, 'tx': 0},
    'days': [
      {
        'day': day,
        'ant': {'rx': gb * gib, 'tx': 0},
        'mywatch': {'rx': 0, 'tx': 0},
        'channels': {'rx': 0, 'tx': 0},
      },
    ],
  });
}

void main() {
  Future<void> pumpHost(WidgetTester tester) => tester.pumpWidget(
        MaterialApp(
          scaffoldMessengerKey: wiMessengerKey,
          home: const Scaffold(),
        ),
      );

  testWidgets('one notice per day when usage passes the level, and a '
      'fresh day fires again', (tester) async {
    SharedPreferences.setMockInitialValues({'data_alert_gb_v1': 5});
    await pumpHost(tester);
    var now = DateTime(2026, 9, 23, 12);
    var stats = statsWithDay('2026-09-23', 6);
    final alert =
        DataAlert(stats: () async => stats, clock: () => now);

    await alert.check();
    await tester.pump();
    expect(find.textContaining('6.00 GB — over your 5 GB daily alert'),
        findsOneWidget);

    // Same day again: the notice is spent — clear the visible snackbar
    // and prove nothing new appears.
    wiMessengerKey.currentState!.removeCurrentSnackBar();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(SnackBar), findsNothing);
    await alert.check();
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);

    // Next local day over the level: fires again.
    now = DateTime(2026, 9, 24, 9);
    stats = statsWithDay('2026-09-24', 7);
    await alert.check();
    await tester.pump();
    expect(find.textContaining('7.00 GB — over your 5 GB daily alert'),
        findsOneWidget);
    wiMessengerKey.currentState!.clearSnackBars();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('under the level, or with the alert off, nothing shows',
      (tester) async {
    SharedPreferences.setMockInitialValues({'data_alert_gb_v1': 5});
    await pumpHost(tester);
    final under = DataAlert(
      stats: () async => statsWithDay('2026-09-23', 4),
      clock: () => DateTime(2026, 9, 23, 12),
    );
    await under.check();
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);

    // Off (the default): even a huge day stays quiet.
    SharedPreferences.setMockInitialValues({});
    final off = DataAlert(
      stats: () async => statsWithDay('2026-09-23', 50),
      clock: () => DateTime(2026, 9, 23, 12),
    );
    await off.check();
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('an old core without day history stays quiet',
      (tester) async {
    SharedPreferences.setMockInitialValues({'data_alert_gb_v1': 1});
    await pumpHost(tester);
    final alert = DataAlert(
      stats: () async => DataUsageStats.fromJson({
        'period_start_ms': 1,
        'total': {'rx': 1 << 40, 'tx': 0},
        'ant': {'rx': 1 << 40, 'tx': 0},
        'mywatch': {'rx': 0, 'tx': 0},
        'channels': {'rx': 0, 'tx': 0},
      }),
      clock: () => DateTime(2026, 9, 23, 12),
    );
    await alert.check();
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);
  });
}
