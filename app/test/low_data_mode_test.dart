import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/screens/my_watch_screen.dart';
import 'package:watchit/services/backup_follow.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/low_data_mode.dart';
import 'package:watchit/services/my_watch_api.dart';
import 'package:watchit/services/x0x_cellular.dart';
import 'package:watchit/theme/tokens.dart';

import 'fake_embedded_http.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late FakeEmbeddedHttp fake;

  MyWatchApi api() => MyWatchApi(base: FakeEmbeddedHttp.base, token: 't');

  LowDataMode mode({Future<String> Function()? syncNow}) {
    final m = LowDataMode(
      api: api(),
      gate: X0xCellularGate(myWatchApi: api()),
      syncNow: syncNow ?? () async => 'Synced: 1 added.',
    )
      ..joinTimeout = const Duration(milliseconds: 200)
      ..joinPollInterval = const Duration(milliseconds: 5)
      ..linger = Duration.zero;
    return m;
  }

  Map<String, dynamic> linkedStatus({bool enabled = true}) => {
        'supported': true,
        'linked': true,
        'enabled': enabled,
        'state': enabled ? 'ready' : 'off',
        'device_name': 'Office desktop',
        'agent_id': 'aa' * 32,
        'linked_since_ms': 1700000000000,
        'devices': const [],
      };

  setUp(() async {
    fake = FakeEmbeddedHttp();
    HttpOverrides.global = fake;
    SharedPreferences.setMockInitialValues({'defaults_seeded_v4': true});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
  });

  tearDown(() {
    HttpOverrides.global = null;
  });

  group('LowDataMode service', () {
    test('turning the mode on switches the agent off, persists, and '
        'clears any mobile-data pause; off switches it back on',
        () async {
      SharedPreferences.setMockInitialValues({
        'x0x_cellular_paused_v1': ['myWatch'],
      });
      fake.myWatchStatus = linkedStatus();
      final m = mode();
      await m.setEnabled(true);
      expect(m.enabled, isTrue);
      expect(fake.myWatchEnabledPosts, [
        jsonEncode({'enabled': false}),
      ]);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('low_data_mode_v1'), isTrue);
      // The gate forgot its pause — Wi-Fi returning won't re-enable
      // the agent behind the mode's back.
      expect(prefs.getStringList('x0x_cellular_paused_v1'), isEmpty);

      await m.setEnabled(false);
      expect(m.enabled, isFalse);
      expect(fake.myWatchEnabledPosts.last, jsonEncode({'enabled': true}));
      expect(prefs.getBool('low_data_mode_v1'), isFalse);
    });

    test('a manual agent change elsewhere clears the mode without '
        'touching the agent again', () async {
      fake.myWatchStatus = linkedStatus();
      final m = mode();
      await m.setEnabled(true);
      fake.myWatchEnabledPosts.clear();
      await m.noteAgentManualChange();
      expect(m.enabled, isFalse);
      expect(fake.myWatchEnabledPosts, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('low_data_mode_v1'), isFalse);
    });

    test('runBurst joins, syncs, and always switches the agent back off',
        () async {
      fake.myWatchStatus = linkedStatus(enabled: false);
      var synced = 0;
      final m = mode(syncNow: () async {
        synced++;
        // Mid-burst the agent really is on.
        expect(fake.myWatchStatus['enabled'], isTrue);
        return 'Synced: 2 added.';
      });
      final summary = await m.runBurst();
      expect(summary, 'Synced: 2 added.');
      expect(synced, 1);
      expect(m.bursting, isFalse);
      // Agent on to join, off again at the end — whatever happened.
      expect(fake.myWatchEnabledPosts.first, jsonEncode({'enabled': true}));
      expect(fake.myWatchEnabledPosts.last, jsonEncode({'enabled': false}));
      expect(fake.myWatchStatus['enabled'], isFalse);
    });

    test('runBurst times out cleanly when the mesh never comes up — '
        'agent off afterwards, no sync attempted', () async {
      // Not linked: the status never reads ready.
      fake.myWatchStatus = {
        'supported': true,
        'linked': false,
        'state': 'off',
        'devices': const [],
      };
      var synced = 0;
      final m = mode(syncNow: () async {
        synced++;
        return 'nope';
      });
      await expectLater(
        m.runBurst(),
        throwsA(isA<MyWatchApiException>().having(
            (e) => e.message, 'message', contains('in time'))),
      );
      expect(synced, 0);
      expect(m.bursting, isFalse);
      expect(fake.myWatchEnabledPosts.last, jsonEncode({'enabled': false}));
    });

    test('initialize re-asserts agent-off while the mode is on', () async {
      SharedPreferences.setMockInitialValues({'low_data_mode_v1': true});
      fake.myWatchStatus = linkedStatus();
      final m = mode();
      await m.initialize();
      expect(m.enabled, isTrue);
      expect(fake.myWatchEnabledPosts, [
        jsonEncode({'enabled': false}),
      ]);
    });
  });

  group('My W@tch screen in low-data mode', () {
    Future<void> open(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: const MyWatchScreen(apiBase: FakeEmbeddedHttp.base),
      ));
      await tester.pumpAndSettle();
    }

    Future<void> close(WidgetTester tester) =>
        tester.pumpWidget(const SizedBox());

    testWidgets('shows the mode card, keeps Sync now alive, and runs a '
        'burst behind the cost dialog', (tester) async {
      fake.myWatchStatus = linkedStatus(enabled: false);
      var synced = 0;
      final m = mode(syncNow: () async {
        synced++;
        return 'Synced: 3 added.';
      });
      final previous = LowDataMode.instance;
      LowDataMode.instance = m;
      addTearDown(() => LowDataMode.instance = previous);
      await m.setEnabled(true);
      fake.myWatchEnabledPosts.clear();

      await open(tester);
      expect(find.textContaining('Low-data mode — this device syncs'),
          findsOneWidget);
      expect(find.text('Low-data mode'), findsOneWidget);
      final switchTile = tester.widget<SwitchListTile>(
          find.byType(SwitchListTile));
      expect(switchTile.value, isTrue);

      // Sync now is alive despite the agent being off…
      final syncBtn = find.widgetWithText(OutlinedButton, 'Sync now');
      await tester.ensureVisible(syncBtn);
      await tester.pump();
      await tester.tap(syncBtn);
      await tester.pumpAndSettle();
      // …and leads with the honest cost note.
      expect(find.text('Run a live sync session?'), findsOneWidget);
      expect(find.textContaining('100–150 MB'), findsOneWidget);
      await tester.tap(find.text('Sync'));
      await tester.pumpAndSettle();

      expect(synced, 1);
      expect(find.text('Synced: 3 added.'), findsOneWidget);
      // The burst switched the agent on and back off.
      expect(fake.myWatchEnabledPosts.first, jsonEncode({'enabled': true}));
      expect(fake.myWatchEnabledPosts.last, jsonEncode({'enabled': false}));
      await close(tester);
    });

    testWidgets('enabling the switch warns when no shared backup is '
        'followed yet', (tester) async {
      fake.myWatchStatus = linkedStatus();
      final m = mode();
      final previous = LowDataMode.instance;
      LowDataMode.instance = m;
      addTearDown(() => LowDataMode.instance = previous);
      BackupFollowService.status.value = const BackupFollowStatus();
      addTearDown(() =>
          BackupFollowService.status.value = const BackupFollowStatus());

      await open(tester);
      final tile = find.byType(SwitchListTile);
      await tester.ensureVisible(tile);
      await tester.pump();
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(find.text('Turn on low-data mode?'), findsOneWidget);
      // Cancelling leaves everything as it was.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(m.enabled, isFalse);
      expect(fake.myWatchEnabledPosts, isEmpty);

      // Confirming turns the mode on (agent off).
      await tester.tap(tile);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Turn on'));
      await tester.pumpAndSettle();
      expect(m.enabled, isTrue);
      expect(fake.myWatchEnabledPosts.last, jsonEncode({'enabled': false}));
      await close(tester);
    });

    testWidgets('no warning dialog when a shared backup is already '
        'followed', (tester) async {
      fake.myWatchStatus = linkedStatus();
      final m = mode();
      final previous = LowDataMode.instance;
      LowDataMode.instance = m;
      addTearDown(() => LowDataMode.instance = previous);
      BackupFollowService.status.value =
          const BackupFollowStatus(following: true, pointer: 'ab');
      addTearDown(() =>
          BackupFollowService.status.value = const BackupFollowStatus());

      await open(tester);
      final tile = find.byType(SwitchListTile);
      await tester.ensureVisible(tile);
      await tester.pump();
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(find.text('Turn on low-data mode?'), findsNothing);
      expect(m.enabled, isTrue);
      expect(fake.myWatchEnabledPosts.last, jsonEncode({'enabled': false}));
      await close(tester);
    });
  });
}
