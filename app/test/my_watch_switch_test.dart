import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/screens/my_watch_screen.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/low_data_mode.dart';
import 'package:watchit/services/my_watch_api.dart';
import 'package:watchit/services/network_events.dart';
import 'package:watchit/services/network_pause.dart';
import 'package:watchit/services/x0x_cellular.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/wi_qr.dart';

import 'fake_embedded_http.dart';

/// My W@tch while its switch (Settings → Network → Data) is off:
/// creating or joining says it switched the feature on, a linked
/// device turns it on from the page itself, showing an invite warns
/// first, and offline mode / Wi-Fi only are asked about, never
/// overridden silently.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late FakeEmbeddedHttp fake;

  Future<void> boot(Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues({
      'defaults_seeded_v4': true,
      ...prefs,
    });
    await LibraryStore.useForTesting(
      AppDatabase.forTesting(NativeDatabase.memory()),
    );
  }

  setUp(() {
    fake = FakeEmbeddedHttp();
    HttpOverrides.global = fake;
    final api = MyWatchApi(base: FakeEmbeddedHttp.base);
    final pause = NetworkPause.instance;
    final events = NetworkEvents.instance;
    final gate = X0xCellularGate.instance;
    final lowData = LowDataMode.instance;
    NetworkPause.instance = NetworkPause(
      base: FakeEmbeddedHttp.base,
      token: 'test',
      myWatchApi: api,
    );
    NetworkEvents.instance = NetworkEvents(
      stream: const Stream.empty(),
      check: () async => [ConnectivityResult.wifi],
    );
    X0xCellularGate.instance = X0xCellularGate(myWatchApi: api);
    LowDataMode.instance = LowDataMode(api: api);
    addTearDown(() {
      NetworkPause.instance = pause;
      NetworkEvents.instance = events;
      X0xCellularGate.instance = gate;
      LowDataMode.instance = lowData;
      HttpOverrides.global = null;
    });
  });

  Map<String, dynamic> linked({bool enabled = true}) => {
    'supported': true,
    'enabled': enabled,
    'linked': true,
    'state': enabled ? 'ready' : 'off',
    'device_name': 'Office desktop',
    'agent_id': 'aa' * 32,
    'last_sync_ms': 0,
    'devices': const [],
  };

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: const MyWatchScreen(apiBase: FakeEmbeddedHttp.base),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox());

  Future<void> tapScrolled(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  List<bool> enabledPosts() => [
    for (final body in fake.myWatchEnabledPosts)
      (jsonDecode(body) as Map<String, dynamic>)['enabled'] as bool,
  ];

  Future<void> createLink(WidgetTester tester) async {
    await tester.tap(find.text('Start a new My W@tch'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Office desktop');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
  }

  testWidgets('creating a link with the switch off says it was switched on', (
    tester,
  ) async {
    await boot({});
    fake.myWatchStatus = {...fake.myWatchStatus, 'enabled': false};
    await open(tester);
    await createLink(tester);
    expect(fake.requests, contains('POST /mywatch/link'));
    expect(find.text('My W@tch was switched on.'), findsOneWidget);
    await close(tester);
  });

  testWidgets('creating a link with the switch on says nothing extra', (
    tester,
  ) async {
    await boot({});
    await open(tester);
    await createLink(tester);
    expect(find.text('Last sync'), findsOneWidget);
    expect(find.textContaining('was switched on'), findsNothing);
    await close(tester);
  });

  testWidgets('joining with the switch off says it was switched on', (
    tester,
  ) async {
    await boot({});
    fake.myWatchStatus = {...fake.myWatchStatus, 'enabled': false};
    await open(tester);
    await tester.tap(find.text('Enter an invite code (from a linked device)'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Invite code'),
      fake.myWatchInvite,
    );
    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();
    expect(fake.requests, contains('POST /mywatch/join'));
    expect(find.text('Joined. My W@tch was switched on.'), findsOneWidget);
    await close(tester);
  });

  testWidgets('a linked device that is off turns on from the page', (
    tester,
  ) async {
    await boot({});
    fake.myWatchStatus = linked(enabled: false);
    await open(tester);
    expect(find.textContaining('My W@tch is switched off'), findsOneWidget);
    // No detour through the Data menu.
    expect(find.textContaining('Settings → Network → Data'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Turn on'));
    await tester.pumpAndSettle();
    expect(enabledPosts(), [true]);
    expect(find.textContaining('My W@tch is switched off'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Turn on'), findsNothing);
    await close(tester);
  });

  testWidgets('showing an invite while off warns, and can show it anyway', (
    tester,
  ) async {
    await boot({});
    fake.myWatchStatus = linked(enabled: false);
    await open(tester);
    await tapScrolled(tester, find.text('Add a device — show invite code'));
    expect(find.text('This device is not connected'), findsOneWidget);
    expect(find.byType(WiQr), findsNothing);
    await tester.tap(find.text('Show code anyway'));
    await tester.pumpAndSettle();
    expect(find.byType(WiQr), findsOneWidget);
    expect(enabledPosts(), isEmpty);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await close(tester);
  });

  testWidgets('the invite warning can turn My W@tch on first', (tester) async {
    await boot({});
    fake.myWatchStatus = linked(enabled: false);
    await open(tester);
    await tapScrolled(tester, find.text('Add a device — show invite code'));
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Turn on'),
      ),
    );
    await tester.pumpAndSettle();
    expect(enabledPosts(), [true]);
    expect(find.byType(WiQr), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await close(tester);
  });

  testWidgets('no invite warning while My W@tch is on', (tester) async {
    await boot({});
    fake.myWatchStatus = linked();
    await open(tester);
    await tapScrolled(tester, find.text('Add a device — show invite code'));
    expect(find.text('This device is not connected'), findsNothing);
    expect(find.byType(WiQr), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await close(tester);
  });

  testWidgets('in low-data mode the invite warning offers to leave the mode', (
    tester,
  ) async {
    await boot({'low_data_mode_v1': true});
    await tester.runAsync(LowDataMode.instance.initialize);
    fake.myWatchStatus = linked(enabled: false);
    await open(tester);
    // The mode's own switch sits right below the card: no second button.
    expect(find.widgetWithText(FilledButton, 'Turn on'), findsNothing);
    await tapScrolled(tester, find.text('Add a device — show invite code'));
    expect(
      find.textContaining('Low-data mode keeps this device'),
      findsOneWidget,
    );
    await tester.tap(find.text('Turn off low-data mode'));
    await tester.pumpAndSettle();
    expect(LowDataMode.instance.enabled, isFalse);
    expect(enabledPosts(), [true]);
    expect(find.byType(WiQr), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await close(tester);
  });

  group('on mobile data with My W@tch set to Wi-Fi only', () {
    Future<void> onCellular(WidgetTester tester) async {
      await boot({'mywatch_cellular_v1': false});
      final events = NetworkEvents(
        stream: const Stream.empty(),
        check: () async => [ConnectivityResult.mobile],
      );
      NetworkEvents.instance = events;
      events.start();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(events.onCellular, isTrue);
    }

    testWidgets('creating asks first, and Cancel changes nothing', (
      tester,
    ) async {
      await onCellular(tester);
      await open(tester);
      await tester.tap(find.text('Start a new My W@tch'));
      await tester.pumpAndSettle();
      expect(find.text('Use mobile data?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Name this device'), findsNothing);
      expect(fake.requests, isNot(contains('POST /mywatch/link')));
      await close(tester);
    });

    testWidgets('Continue carries on to the link', (tester) async {
      await onCellular(tester);
      await open(tester);
      await tester.tap(find.text('Start a new My W@tch'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Name this device'), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(fake.requests, contains('POST /mywatch/link'));
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await close(tester);
    });

    testWidgets('Turn on asks first too', (tester) async {
      await onCellular(tester);
      fake.myWatchStatus = linked(enabled: false);
      await open(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Turn on'));
      await tester.pumpAndSettle();
      expect(find.text('Use mobile data?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(enabledPosts(), isEmpty);
      await close(tester);
    });
  });

  group('in offline mode', () {
    testWidgets('joining asks first, and Cancel stays offline', (tester) async {
      await boot({'network_paused_v1': true});
      await open(tester);
      await tester.tap(
        find.text('Enter an invite code (from a linked device)'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Offline mode is on'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Join'), findsNothing);
      expect(NetworkPause.instance.paused, isTrue);
      expect(fake.networkPausePosts, isEmpty);
      await close(tester);
    });

    testWidgets('a linked device says why it is off, and Go online '
        'leaves offline mode and connects', (tester) async {
      await boot({
        'network_paused_v1': true,
        'network_pause_x0x_v1': <String>['myWatch'],
      });
      fake.myWatchStatus = linked(enabled: false);
      await open(tester);
      expect(
        find.textContaining('Offline mode is on — My W@tch is paused'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Turn on'));
      await tester.pumpAndSettle();
      expect(find.text('Offline mode is on'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('Go online'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      expect(NetworkPause.instance.paused, isFalse);
      // Leaving offline mode re-enabled the agent it had paused — once.
      expect(enabledPosts(), [true]);
      expect(find.textContaining('Offline mode is on'), findsNothing);
      await close(tester);
    });
  });
}
