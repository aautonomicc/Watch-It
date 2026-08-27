import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/main.dart';
import 'package:watchit/screens/my_watch_screen.dart';
import 'package:watchit/services/embedded_client.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/my_watch_sync.dart';
import 'package:watchit/services/terms.dart';
import 'package:watchit/theme/tokens.dart';

Widget _bar({String state = 'ready', int peers = 5}) => MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: Scaffold(
        body: NetworkStatusBar(
          healthProvider: () async => ClientHealth(state: state, peers: peers),
        ),
      ),
    );

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    SharedPreferences.setMockInitialValues(
        {'terms_accepted_version_v1': kTermsVersion});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    MyWatchSync.status.value = const MyWatchSyncStatus();
  });

  group('NetworkStatusBar', () {
    testWidgets('simplified wording, no My W@tch segment while unlinked',
        (tester) async {
      await tester.pumpWidget(_bar());
      await tester.pump();
      expect(find.text('Connected · 5 peers'), findsOneWidget);
      expect(find.textContaining('Autonomi network'), findsNothing);
      expect(find.textContaining('My W@tch'), findsNothing);
      await tester.pumpWidget(const SizedBox()); // cancel the poll timer
    });

    testWidgets('connecting and error states stay short', (tester) async {
      await tester.pumpWidget(_bar(state: 'connecting'));
      await tester.pump();
      expect(find.text('Connecting…'), findsOneWidget);
      // Fresh state so the new provider is polled from initState.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_bar(state: 'error'));
      await tester.pump();
      expect(find.text('Connection error'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('My W@tch segment follows the sync status', (tester) async {
      await tester.pumpWidget(_bar());
      await tester.pump();

      MyWatchSync.status.value = MyWatchSyncStatus(
        supported: true,
        linked: true,
        agentState: 'ready',
        lastSyncMs: DateTime.now().millisecondsSinceEpoch - 30000,
      );
      await tester.pump();
      expect(find.text('My W@tch: synced just now'), findsOneWidget);

      MyWatchSync.status.value = const MyWatchSyncStatus(
          supported: true, linked: true, agentState: 'starting');
      await tester.pump();
      expect(find.text('My W@tch: connecting…'), findsOneWidget);

      MyWatchSync.status.value = const MyWatchSyncStatus(
          supported: true, linked: true, agentState: 'ready', syncing: true);
      await tester.pump();
      expect(find.text('My W@tch: syncing…'), findsOneWidget);

      MyWatchSync.status.value = const MyWatchSyncStatus(
        supported: true,
        linked: true,
        agentState: 'ready',
        problems: ['Artwork for "X" could not be fetched: refused'],
      );
      await tester.pump();
      expect(find.text('My W@tch: sync issue'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('tapping the My W@tch segment opens the My W@tch page',
        (tester) async {
      MyWatchSync.status.value = const MyWatchSyncStatus(
          supported: true, linked: true, agentState: 'ready');
      await tester.pumpWidget(_bar());
      await tester.pump();
      await tester.tap(find.text('My W@tch: linked'));
      await tester.pumpAndSettle();
      expect(find.byType(MyWatchScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('Settings → Network', () {
    testWidgets('My W@tch tile sits in the Network section and navigates',
        (tester) async {
      await tester.pumpWidget(const WatchItApp());
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Browse lists'));
      await tester.pumpAndSettle();
      // The drawer no longer has a My W@tch tile — it moved to Settings.
      expect(find.text('My W@tch'), findsNothing);
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('My W@tch'), 100);
      await tester.ensureVisible(find.text('My W@tch'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('My W@tch'));
      await tester.pumpAndSettle();
      expect(find.byType(MyWatchScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
