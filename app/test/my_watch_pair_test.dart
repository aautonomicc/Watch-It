import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchit/db/app_database.dart';
import 'package:watchit/screens/my_watch_screen.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/my_watch_api.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/pair_dialogs.dart';
import 'package:watchit/widgets/wi_qr.dart';

import 'fake_embedded_http.dart';

/// Reverse-QR pairing: the unlinked device (TV/desktop — screen, no
/// camera) shows a `wtchp1-` code; a linked phone scans it and sends
/// the link secret over a rendezvous gossip topic.
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

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: const MyWatchScreen(apiBase: FakeEmbeddedHttp.base),
    ));
    await tester.pumpAndSettle();
  }

  // Cancels every live timer (screen refresh + dialog polls).
  Future<void> close(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox());

  group('receive side (unlinked screen)', () {
    testWidgets('pair button shows the code dialog with a QR',
        (tester) async {
      await open(tester);
      expect(find.text('Pair by showing a code'), findsOneWidget);
      expect(find.textContaining('No camera on this device?'), findsOneWidget);
      await tester.tap(find.text('Pair by showing a code'));
      await tester.pumpAndSettle();
      // Device-name dialog first, like create/join.
      expect(find.text('Name this device'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Living-room TV');
      await tester.tap(find.text('Continue'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // pair/start was posted with the name; the dialog renders the
      // returned code as a QR and waits.
      expect(fake.requests, contains('POST /mywatch/pair/start'));
      expect(fake.myWatchPairPosts.first, contains('Living-room TV'));
      final qr = tester.widget<WiQr>(find.byType(WiQr));
      expect(qr.data, fake.myWatchPairCode);
      expect(find.textContaining('Waiting for a linked device'),
          findsOneWidget);
      await close(tester);
    });

    testWidgets('dialog pops into the linked view once the secret lands',
        (tester) async {
      await open(tester);
      await tester.tap(find.text('Pair by showing a code'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(PairCodeDialog), findsOneWidget);
      // The linked phone scanned + sent; the core joined the link.
      fake.myWatchStatus = {
        'supported': true,
        'linked': true,
        'state': 'ready',
        'device_name': 'Living-room TV',
        'agent_id': 'aa' * 32,
        'devices': const [],
      };
      fake.myWatchPairStatus = {'active': false};
      // Next 3s poll sees linked and pops with the success snackbar.
      await tester.pump(const Duration(seconds: 3));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byType(PairCodeDialog), findsNothing);
      expect(find.textContaining('Linked!'), findsOneWidget);
      expect(find.text('Last sync'), findsOneWidget);
      await close(tester);
    });

    testWidgets('an expired code surfaces the failure, Close sweeps it',
        (tester) async {
      await open(tester);
      await tester.tap(find.text('Pair by showing a code'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      fake.myWatchPairStatus = {
        'active': true,
        'role': 'receive',
        'code': fake.myWatchPairCode,
        'state': 'failed',
        'message': 'the pairing code expired — show a fresh one',
      };
      await tester.pump(const Duration(seconds: 3));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.textContaining('pairing code expired'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(PairCodeDialog), findsNothing);
      expect(fake.myWatchPairPosts, contains('cancel'));
      await close(tester);
    });

    testWidgets('Cancel abandons the attempt', (tester) async {
      await open(tester);
      await tester.tap(find.text('Pair by showing a code'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(PairCodeDialog), findsNothing);
      expect(fake.myWatchPairPosts, contains('cancel'));
      await close(tester);
    });
  });

  group('send side', () {
    testWidgets('desktop linked view hides the scan button (no camera)',
        (tester) async {
      fake.myWatchStatus = {
        'supported': true,
        'linked': true,
        'state': 'ready',
        'device_name': 'Desk',
        'agent_id': 'aa' * 32,
        'devices': const [],
      };
      await open(tester);
      expect(find.text('Show invite (add a device)'), findsOneWidget);
      // Tests run on desktop: no camera, so no scan entry point.
      expect(find.text('Link a new device (scan its code)'), findsNothing);
      await close(tester);
    });

    Future<void> openSendDialog(WidgetTester tester) async {
      final api = MyWatchApi(base: FakeEmbeddedHttp.base);
      await tester.pumpWidget(MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showDialog<bool>(
                context: context,
                builder: (_) => PairSendDialog(api: api),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('send dialog waits, then pops and sweeps on delivery',
        (tester) async {
      fake.myWatchPairStatus = {
        'active': true,
        'role': 'send',
        'code': fake.myWatchPairCode,
        'state': 'sending',
        'message': null,
      };
      await openSendDialog(tester);
      expect(find.textContaining('Sending the link'), findsOneWidget);
      fake.myWatchPairStatus = {
        'active': true,
        'role': 'send',
        'code': fake.myWatchPairCode,
        'state': 'delivered',
        'message': null,
      };
      await tester.pump(const Duration(seconds: 2));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byType(PairSendDialog), findsNothing);
      // The finished session is swept so the next attempt starts clean.
      expect(fake.myWatchPairPosts, contains('cancel'));
      await close(tester);
    });

    testWidgets('a failed send shows the reason', (tester) async {
      fake.myWatchPairStatus = {
        'active': true,
        'role': 'send',
        'code': fake.myWatchPairCode,
        'state': 'sending',
        'message': null,
      };
      await openSendDialog(tester);
      fake.myWatchPairStatus = {
        'active': true,
        'role': 'send',
        'code': fake.myWatchPairCode,
        'state': 'failed',
        'message': 'no confirmation from the new device — it may still '
            'have linked (check its screen)',
      };
      await tester.pump(const Duration(seconds: 2));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
          find.textContaining('no confirmation from the new device'),
          findsOneWidget);
      await tester.tap(find.text('Close'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(PairSendDialog), findsNothing);
      await close(tester);
    });
  });
}
