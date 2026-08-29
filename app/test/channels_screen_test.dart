import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/screens/channels_screen.dart';
import 'package:watchit/screens/describe_item_screen.dart';
import 'package:watchit/services/channel_service.dart';
import 'package:watchit/services/channels_api.dart';
import 'package:watchit/services/ffmpeg.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/terms.dart';
import 'package:watchit/theme/tokens.dart';

import 'fake_embedded_http.dart';

/// No-process ffmpeg stand-in — the pushed publish screen probes it.
class _NoFfmpeg extends FfmpegService {
  @override
  Future<bool> get available async => false;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late FakeEmbeddedHttp fake;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    fake = FakeEmbeddedHttp();
    HttpOverrides.global = fake;
    ChannelService.resetForTesting();
    ChannelService.instance.importBase = FakeEmbeddedHttp.base;
  });

  tearDown(() {
    HttpOverrides.global = null;
  });

  Future<void> openChannels(WidgetTester tester) async {
    // The My Channel body is a tall ListView — give tests a viewport
    // that renders it whole (same trick as the publish flow tests).
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: ChannelsScreen(
          apiBase: FakeEmbeddedHttp.base, ffmpeg: _NoFfmpeg()),
    ));
    await tester.pumpAndSettle();
  }

  group('Subscribed segment', () {
    testWidgets('default segment, PUBLIC badge, empty-state copy',
        (tester) async {
      await openChannels(tester);
      expect(find.text('PUBLIC'), findsOneWidget);
      expect(find.text('Subscribed'), findsOneWidget);
      expect(find.text('My Channel'), findsOneWidget);
      expect(find.textContaining('No subscribed channels yet'),
          findsOneWidget);
      expect(find.text('Add channel'), findsOneWidget);
    });

    testWidgets(
        'Add channel dialog carries the subscriber note and subscribes',
        (tester) async {
      await openChannels(tester);
      await tester.tap(find.text('Add channel'));
      await tester.pumpAndSettle();
      // Subscriber-side note (Part 3 item 6).
      expect(
          find.textContaining(
              'comes from the channel\'s owner, not from W@tch'),
          findsOneWidget);
      final code = 'wchn1-${'c' * 52}';
      await tester.enterText(find.byType(TextField), code);
      await tester.tap(find.text('Subscribe'));
      await tester.pumpAndSettle();
      expect(fake.channelSubscribes, [code]);
      // A card for the pending channel appears (name unknown yet).
      expect(find.textContaining('Channel '), findsWidgets);
    });

    testWidgets('subscribed channel card shows update state and menu',
        (tester) async {
      final pubkey = 'ab' * 32;
      SharedPreferences.setMockInitialValues({
        'channel_subs_v1': jsonEncode({
          pubkey: {
            'name': 'Nature Films',
            'description': 'My own footage',
            'importedSeq': 2,
          }
        }),
      });
      fake.channelsStatus = {
        'supported': true,
        'state': 'ready',
        'own': null,
        'subs': [
          {
            'pubkey': pubkey,
            'code': 'wchn1-x',
            'head': {'seq': 2, 'manifest': 'ee' * 32},
          },
        ],
      };
      await LibraryStore.save([
        MediaList(
          id: 'channel-x',
          title: 'Nature Films',
          entries: const [MediaEntry(name: 'a.mp4', address: 'aa')],
          channelPubkey: pubkey,
        ),
      ]);
      await openChannels(tester);
      expect(find.text('Nature Films'), findsOneWidget);
      expect(find.text('My own footage'), findsOneWidget);
      expect(find.textContaining('Up to date · v2'), findsOneWidget);
      expect(find.text('CHANNEL'), findsOneWidget);
      // Menu offers unsubscribe (and only channel actions).
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Unsubscribe'), findsOneWidget);
      expect(find.text('Rename'), findsNothing);
    });

    testWidgets(
        'fetch problem reads calm — raw error only in the tooltip',
        (tester) async {
      final pubkey = 'cd' * 32;
      SharedPreferences.setMockInitialValues({
        'channel_subs_v1': jsonEncode({
          pubkey: {'name': 'Nature Films', 'importedSeq': 2}
        }),
      });
      fake.channelsStatus = {
        'supported': true,
        'state': 'ready',
        'own': null,
        'subs': [
          {
            'pubkey': pubkey,
            'code': 'wchn1-x',
            'head': {'seq': 2, 'manifest': 'ee' * 32},
          },
        ],
      };
      const raw = 'manifest lookup failed: not found: '
          'DataMap chunk not found at 6fd42655';
      ChannelService.instance.lastProblem[pubkey] = raw;
      await openChannels(tester);
      expect(
          find.textContaining(
              'Update found — not fully reachable yet, '
              'retrying automatically'),
          findsOneWidget);
      // The scary raw error is off the card…
      expect(find.textContaining('Update failed'), findsNothing);
      expect(find.textContaining('DataMap chunk'), findsNothing);
      // …but stays available via the tooltip, and the line is amber
      // (pending), not the error red.
      final tips = tester.widgetList<Tooltip>(find.byType(Tooltip));
      expect(tips.map((w) => w.message), contains(raw));
      final line = tester.widget<Text>(
          find.textContaining('retrying automatically'));
      expect(line.style?.color, WiTokens.channelAmber);
    });
  });

  group('connection bar', () {
    testWidgets('off state explains the network is idle', (tester) async {
      // Fake default: state off (no own channel, no subs).
      await openChannels(tester);
      expect(
          find.text(
              'Not connected — connects when you create or add a channel'),
          findsOneWidget);
    });

    testWidgets('ready shows Connected on both segments', (tester) async {
      fake.channelsStatus = {
        'supported': true,
        'state': 'ready',
        'own': null,
        'subs': const [],
      };
      await openChannels(tester);
      expect(find.text('Connected to the channel network'), findsOneWidget);
      await tester.tap(find.text('My Channel'));
      await tester.pumpAndSettle();
      expect(find.text('Connected to the channel network'), findsOneWidget);
    });

    testWidgets('starting shows Connecting with a spinner', (tester) async {
      fake.channelsStatus = {
        'supported': true,
        'state': 'starting',
        'own': null,
        'subs': const [],
      };
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: ChannelsScreen(
            apiBase: FakeEmbeddedHttp.base, ffmpeg: _NoFfmpeg()),
      ));
      // An indeterminate spinner never settles — pump a few frames.
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Connecting to the channel network…'),
          findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsWidgets);
    });
  });

  group('My Channel segment', () {
    Future<void> openMine(WidgetTester tester) async {
      await openChannels(tester);
      await tester.tap(find.text('My Channel'));
      await tester.pumpAndSettle();
    }

    testWidgets('no channel yet: warning copy + create/restore',
        (tester) async {
      await openMine(tester);
      expect(find.textContaining('PUBLIC and PERMANENT'), findsOneWidget);
      expect(find.text('Create channel'), findsOneWidget);
      expect(find.text('Restore channel'), findsOneWidget);
    });

    testWidgets('Create channel opens the name/description form',
        (tester) async {
      await openMine(tester);
      await tester.tap(find.text('Create channel'));
      await tester.pumpAndSettle();
      expect(find.text('Channel name'), findsOneWidget);
      expect(find.textContaining('backup ceremony runs before'),
          findsOneWidget);
      expect(find.text('Continue'), findsOneWidget);
    });

    testWidgets(
        'ceremony: 12 words → retype gate → typed-name gate → create',
        (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: ChannelSeedBackupScreen(
          generated: GeneratedChannel(
            mnemonic: fake.channelMnemonic,
            code: fake.channelCode,
          ),
          channelName: 'Nature Films',
          description: 'My own footage',
          api: ChannelsApi(base: FakeEmbeddedHttp.base),
          confirmIndices: const [0, 1, 2],
        ),
      ));
      await tester.pumpAndSettle();
      // All 12 words shown, with the separate-phrase warning.
      expect(find.textContaining('1. legal'), findsOneWidget);
      expect(find.textContaining('12. yellow'), findsOneWidget);
      expect(find.textContaining('restores your CHANNEL, not your wallet'),
          findsOneWidget);
      await tester.tap(find.text("I've written them down"));
      await tester.pumpAndSettle();
      // Confirm step: type the three requested words.
      final words = fake.channelMnemonic.split(RegExp(r'\s+'));
      // A wrong word is caught.
      await tester.enterText(
          find.widgetWithText(TextField, 'Word #1'), 'wrong');
      await tester.enterText(
          find.widgetWithText(TextField, 'Word #2'), words[1]);
      await tester.enterText(
          find.widgetWithText(TextField, 'Word #3'), words[2]);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.textContaining('does not match'), findsOneWidget);
      await tester.enterText(
          find.widgetWithText(TextField, 'Word #1'), words[0]);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      // The full-screen first-publish gate.
      expect(find.text('Before your channel exists'), findsOneWidget);
      expect(find.text('PUBLIC · PERMANENT'), findsOneWidget);
      expect(find.textContaining('ATTRIBUTABLE'), findsOneWidget);
      // Button disabled until the channel name is typed.
      final createButton = find.widgetWithText(
          FilledButton, 'I understand — create the channel');
      expect(
          tester.widget<FilledButton>(createButton).onPressed, isNull);
      await tester.enterText(find.byType(TextField), 'nature films');
      await tester.pumpAndSettle();
      expect(
          tester.widget<FilledButton>(createButton).onPressed, isNotNull);
      await tester.tap(createButton);
      await tester.pumpAndSettle();
      expect(fake.channelCreates, hasLength(1));
      final created =
          jsonDecode(fake.channelCreates.single) as Map<String, dynamic>;
      expect(created['name'], 'Nature Films');
      expect(created['mnemonic'], fake.channelMnemonic);
    });

    testWidgets('own channel view: code, backup row, item staging gates',
        (tester) async {
      fake.channelsStatus = {
        'supported': true,
        'state': 'ready',
        'own': {
          'name': 'Nature Films',
          'description': 'My own footage',
          'pubkey': fake.channelPubkey,
          'code': fake.channelCode,
          'seq': 0,
          'manifest': '',
          'created_at_ms': 1,
          'key_storage': 'keychain',
          'key_missing': false,
          'head': null,
        },
        'subs': const [],
      };
      await openMine(tester);
      expect(find.text('Nature Films'), findsOneWidget);
      expect(find.text(fake.channelCode), findsOneWidget);
      expect(find.text('Recovery phrase backed up ✓'), findsOneWidget);
      expect(find.textContaining('No items yet'), findsOneWidget);
      // First publish is disabled with no items.
      final publish = find.widgetWithText(
          FilledButton, 'Publish channel · public & permanent');
      expect(tester.widget<FilledButton>(publish).onPressed, isNull);
      expect(find.text('Publish an item'), findsOneWidget);
      expect(find.text('Add an item already in the library'),
          findsOneWidget);
    });

    Map<String, dynamic> ownStatus(FakeEmbeddedHttp fake) => {
          'supported': true,
          'state': 'ready',
          'own': {
            'name': 'Nature Films',
            'description': '',
            'pubkey': fake.channelPubkey,
            'code': fake.channelCode,
            'seq': 1,
            'manifest': 'aa' * 32,
            'created_at_ms': 1,
            'key_storage': 'keychain',
            'key_missing': false,
            'head': null,
          },
          'subs': const [],
        };

    testWidgets(
        'Publish an item opens the file-first channel publish screen',
        (tester) async {
      fake.channelsStatus = ownStatus(fake);
      await openMine(tester);
      await tester.tap(find.text('Publish an item'));
      await tester.pumpAndSettle();
      // The new Upload-shaped flow: local file first, staged until
      // Publish update.
      expect(find.text('Choose a file'), findsOneWidget);
      expect(find.textContaining('nothing becomes public until'),
          findsOneWidget);
      // No library dropdown anywhere on this path.
      expect(find.text('Pick an item to publish'), findsNothing);
    });

    testWidgets(
        'Add an item already in the library opens the picker',
        (tester) async {
      // Library holds one pickable entry; drive the pick → describe is
      // skipped by staging directly — here we only exercise the dialog
      // path through the picker.
      fake.channelsStatus = ownStatus(fake);
      await LibraryStore.save([
        const MediaList(
          id: 'mine',
          title: 'Mine',
          entries: [
            MediaEntry(name: 'My Film (2026).mp4', address: 'ab12'),
          ],
        ),
      ]);
      await openMine(tester);
      await tester.tap(find.text('Add an item already in the library'));
      await tester.pumpAndSettle();
      expect(find.text('Pick an item to publish'), findsOneWidget);
      expect(find.text('My Film (2026).mp4'), findsOneWidget);
      // (The describe page needs poster IO; the picker and attestation
      // are covered here, the describe page in its own test below.)
    });
  });

  group('safety rails', () {
    testWidgets('attestation dialog: exact wording, checkbox-gated',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: const Scaffold(
          body: ChannelAttestationDialog(entryName: 'My Film (2026).mp4'),
        ),
      ));
      await tester.pumpAndSettle();
      // The exact attestation text from the plan (Part 3 item 3).
      expect(
        find.textContaining('I created this content myself, or I hold '
            'the rights to distribute it publicly.'),
        findsOneWidget,
      );
      expect(find.textContaining('can never be deleted'), findsOneWidget);
      // Add is disabled until the box is ticked.
      final add = find.widgetWithText(TextButton, 'Add to channel');
      expect(tester.widget<TextButton>(add).onPressed, isNull);
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(tester.widget<TextButton>(add).onPressed, isNotNull);
    });

    testWidgets(
        'describe page requires title, description, and artwork',
        (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: const DescribeItemScreen(
          entry: MediaEntry(name: 'Waterfall.mp4', address: 'ab12'),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('Subscribers only see what you write'),
          findsOneWidget);
      final save = find.widgetWithText(FilledButton, 'Save description');
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      await tester.enterText(
          find.widgetWithText(TextField, 'Title (required)'),
          'Waterfall');
      await tester.enterText(
          find.widgetWithText(TextField, 'Description (required)'),
          'My own footage of a waterfall.');
      await tester.pumpAndSettle();
      // Artwork still missing → still disabled, and it says why.
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      expect(find.textContaining('Still missing: artwork'), findsOneWidget);
    });

    test('terms v2 carry the channel section', () {
      expect(kTermsVersion, 2);
      final channelSection = kTermsSections
          .singleWhere((s) => s.title.contains('Public channels'));
      expect(channelSection.body, contains('irrevocable'));
      expect(channelSection.body, contains('solely responsible'));
      expect(
          kTermsSections.any((s) => s.title.contains('Wallet')), isTrue);
    });
  });
}
