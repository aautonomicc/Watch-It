import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:watchit/widgets/wi_qr.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/screens/my_watch_screen.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/my_watch_sync.dart';
import 'package:watchit/theme/tokens.dart';

import 'fake_embedded_http.dart';

String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late FakeEmbeddedHttp fake;

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

  // settle: false for views with an indeterminate spinner (the
  // connecting banner) — pumpAndSettle would never settle on those.
  Future<void> open(WidgetTester tester, {bool settle = true}) async {
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: const MyWatchScreen(apiBase: FakeEmbeddedHttp.base),
    ));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  // Dispose the screen so its periodic refresh timer is cancelled before
  // the test framework checks for pending timers.
  Future<void> close(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox());

  group('MyWatchScreen unlinked', () {
    testWidgets('offers create and join, announces the library',
        (tester) async {
      await open(tester);
      expect(find.text('Create a link on this device'), findsOneWidget);
      expect(find.text('Join with invite code'), findsOneWidget);
      expect(find.textContaining('in sync automatically'), findsOneWidget);
      // Opening the page announces the (empty) library.
      expect(fake.requests, contains('POST /mywatch/announce'));
      await close(tester);
    });

    testWidgets('create link shows the QR invite dialog', (tester) async {
      await open(tester);
      await tester.tap(find.text('Create a link on this device'));
      await tester.pumpAndSettle();
      // Device-name dialog with a prefilled name.
      expect(find.text('Name this device'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Office desktop');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      // Invite dialog: QR code + copyable code string.
      expect(fake.requests, contains('POST /mywatch/link'));
      expect(find.byType(WiQr), findsOneWidget);
      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.textContaining('wtch1-'), findsWidgets);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      // The fake flipped to linked; the screen reloaded into linked view.
      expect(find.text('Last sync'), findsOneWidget);
      await close(tester);
    });

    testWidgets('join posts the pasted invite', (tester) async {
      await open(tester);
      await tester.tap(find.text('Join with invite code'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextField, 'Invite code'), fake.myWatchInvite);
      await tester.tap(find.text('Join'));
      await tester.pumpAndSettle();
      expect(fake.requests, contains('POST /mywatch/join'));
      expect(find.text('Last sync'), findsOneWidget);
      await close(tester);
    });

    testWidgets('a bad invite surfaces the server message', (tester) async {
      await open(tester);
      await tester.tap(find.text('Join with invite code'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextField, 'Invite code'), 'garbage');
      await tester.tap(find.text('Join'));
      await tester.pumpAndSettle();
      expect(find.textContaining('not a My W@tch invite code'), findsOneWidget);
      await close(tester);
    });
  });

  group('MyWatchScreen linked', () {
    setUp(() {
      fake.myWatchStatus = {
        'supported': true,
        'linked': true,
        'state': 'ready',
        'device_name': 'Office desktop',
        'agent_id': 'aa' * 32,
        'linked_since_ms': 1700000000000,
        'last_sync_ms':
            DateTime.now().millisecondsSinceEpoch - 3 * 60 * 1000,
        'devices': [
          {
            'agent_id': 'aa' * 32,
            'self': true,
            'name': 'Office desktop',
            'platform': 'linux',
            'lists': 3,
            'entries': 42,
            'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
            'online': true,
          },
          {
            'agent_id': 'bb' * 32,
            'self': false,
            'name': 'Living-room laptop',
            'platform': 'windows',
            'lists': 2,
            'entries': 17,
            'updated_at_ms':
                DateTime.now().millisecondsSinceEpoch - 2 * 60 * 1000,
            'online': false,
          },
        ],
      };
    });

    testWidgets('shows last sync, devices, and their info', (tester) async {
      await open(tester);
      expect(find.text('Last sync'), findsOneWidget);
      expect(find.text('3 min ago'), findsOneWidget);
      expect(find.text('Office desktop'), findsOneWidget);
      expect(find.text('Living-room laptop'), findsOneWidget);
      expect(find.textContaining('· this device ·'), findsOneWidget);
      expect(find.textContaining('last heard 2 min ago'), findsOneWidget);
      expect(find.textContaining('2 lists · 17 items'), findsOneWidget);
      expect(find.text('Show invite (add a device)'), findsOneWidget);
      expect(find.text('Unlink this device'), findsOneWidget);
      await close(tester);
    });

    testWidgets('starting state shows the connecting banner', (tester) async {
      fake.myWatchStatus['state'] = 'starting';
      fake.myWatchStatus['message'] = 'network join failed: no route';
      await open(tester, settle: false);
      expect(find.textContaining('Connecting to your devices'), findsOneWidget);
      expect(find.textContaining('no route'), findsOneWidget);
      await close(tester);
    });

    testWidgets('sync activity card shows the last outcome and problems',
        (tester) async {
      MyWatchSync.status.value = const MyWatchSyncStatus(
        supported: true,
        linked: true,
        agentState: 'ready',
        lastSummary: 'Synced: 2 added.',
        problems: ['Artwork for "Custom cut" could not be fetched: refused'],
      );
      await open(tester);
      expect(find.text('Synced: 2 added.'), findsOneWidget);
      expect(find.textContaining('Artwork for "Custom cut"'), findsOneWidget);
      // A running cycle swaps the outcome for the live stage.
      MyWatchSync.status.value = const MyWatchSyncStatus(
        supported: true,
        linked: true,
        agentState: 'ready',
        syncing: true,
        activity: 'Fetching artwork…',
      );
      await tester.pump();
      expect(find.text('Fetching artwork…'), findsOneWidget);
      MyWatchSync.status.value = const MyWatchSyncStatus();
      await tester.pump();
      await close(tester);
    });

    testWidgets('sync activity card reports pending data maps', (tester) async {
      MyWatchSync.status.value = const MyWatchSyncStatus(
        supported: true,
        linked: true,
        agentState: 'ready',
        lastSummary: 'Everything is in sync.',
        pendingMaps: 2,
      );
      await open(tester);
      expect(find.textContaining('2 data map(s) pending'), findsOneWidget);
      expect(find.textContaining("can't play on this device yet"),
          findsOneWidget);
      // The pending line clears with the count.
      MyWatchSync.status.value = const MyWatchSyncStatus(
        supported: true,
        linked: true,
        agentState: 'ready',
        lastSummary: 'Everything is in sync.',
      );
      await tester.pump();
      expect(find.textContaining('data map(s) pending'), findsNothing);
      MyWatchSync.status.value = const MyWatchSyncStatus();
      await tester.pump();
      await close(tester);
    });

    testWidgets('unlink confirms, deletes, and returns to unlinked view',
        (tester) async {
      await open(tester);
      // The sync activity card above can push the button off-screen.
      await tester.ensureVisible(find.text('Unlink this device'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unlink this device'));
      await tester.pumpAndSettle();
      expect(find.textContaining('other devices stay linked'), findsOneWidget);
      await tester.tap(find.text('Unlink'));
      await tester.pumpAndSettle();
      expect(fake.requests, contains('DELETE /mywatch'));
      expect(find.text('Create a link on this device'), findsOneWidget);
      await close(tester);
    });

    testWidgets('announce carries real library counts', (tester) async {
      await LibraryStore.save([
        MediaList(id: 'l1', title: 'Movies', entries: [
          MediaEntry(name: 'Alpha (2020).mkv', address: _addr(1)),
          MediaEntry(name: 'Beta (2021).mkv', address: _addr(2)),
        ]),
      ]);
      await open(tester);
      expect(fake.myWatchAnnounces, isNotEmpty);
      final body =
          jsonDecode(fake.myWatchAnnounces.last) as Map<String, dynamic>;
      expect(body['lists'], 1);
      expect(body['entries'], 2);
      await close(tester);
    });
  });

  testWidgets('unsupported platform explains itself', (tester) async {
    fake.myWatchStatus = {
      'supported': false,
      'linked': false,
      'state': 'off',
      'devices': const [],
    };
    await open(tester);
    expect(
        find.textContaining('not available on this platform'), findsOneWidget);
    await close(tester);
  });
}
