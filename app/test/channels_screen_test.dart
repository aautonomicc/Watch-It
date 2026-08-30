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
import 'package:watchit/widgets/channel_avatar.dart';

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
    // Real path_provider IO would hang the fake-async zone — the avatar
    // lookups need overridden dirs (created sync for the same reason).
    final postersDir =
        Directory.systemTemp.createTempSync('wi-chs-posters');
    final profileDir =
        Directory.systemTemp.createTempSync('wi-chs-profile');
    addTearDown(() => postersDir.deleteSync(recursive: true));
    addTearDown(() {
      if (profileDir.existsSync()) profileDir.deleteSync(recursive: true);
    });
    ChannelService.instance.postersDirProvider = () async => postersDir;
    ChannelService.instance.profileDirProvider = () async => profileDir;
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
          author: '@neil',
          avatar: Uint8List.fromList(List<int>.generate(64, (i) => i)),
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
      // The profile warning: name always, author/avatar when set.
      expect(
          find.textContaining(
              'author name and avatar if you set them'),
          findsOneWidget);
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
      expect(created['author'], '@neil');
      expect(created['mnemonic'], fake.channelMnemonic);
      // The staged avatar crop was stored under its content-hash name.
      final avatarFile = await ChannelService.instance.myAvatarFile();
      expect(avatarFile, isNotNull);
      expect(
          isChannelAvatarMemberName(avatarFile!.uri.pathSegments.last),
          isTrue);
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

    /// Stage one item (with its datamap in the fake) so Publish update
    /// is enabled, and drive the flow through the cost preview into the
    /// progress dialog. The manifest build does real file IO, which the
    /// fake-async test zone never completes on its own — alternating
    /// runAsync (real event loop turns) with pumps (fake-zone microtask
    /// drains) carries it through.
    Future<void> startPublishUpdate(WidgetTester tester) async {
      await tester.tap(find.textContaining('Publish update'));
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      // Cost preview → confirm.
      await tester.tap(find.text('Publish · public & permanent'));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('failed publish offers Try again; the retry succeeds',
        (tester) async {
      fake.wallet = {'address': '0x1', 'storage': 'keychain'};
      fake.channelsStatus = ownStatus(fake);
      fake.datamaps['cd' * 32] = [1, 2, 3];
      await ChannelService.instance.addMyItem(
          MediaEntry(name: 'My Film (2026).mp4', address: 'cd' * 32));
      fake.uploadStates.add({
        'phase': 'error',
        'error': 'head publish failed: gossip timed out',
      });
      await openMine(tester);
      await startPublishUpdate(tester);
      expect(fake.channelPublishes, hasLength(1));

      // First poll tick fails the job — the dialog now offers a retry.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('Publish failed'), findsOneWidget);
      expect(find.textContaining('gossip timed out'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);

      // Try again restarts the job with the SAME built manifest.
      fake.uploadStates.clear();
      fake.uploadResult = {...fake.uploadResult, 'seq': 2};
      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump();
      expect(fake.channelPublishes, hasLength(2));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.textContaining('Published v2 — subscribers update'),
          findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets(
        'publish with Channels switched off reports the deferred announce',
        (tester) async {
      fake.wallet = {'address': '0x1', 'storage': 'keychain'};
      fake.channelsStatus = ownStatus(fake);
      fake.datamaps['cd' * 32] = [1, 2, 3];
      await ChannelService.instance.addMyItem(
          MediaEntry(name: 'My Film (2026).mp4', address: 'cd' * 32));
      fake.uploadResult = {
        ...fake.uploadResult,
        'seq': 2,
        'announced': false,
      };
      await openMine(tester);
      await startPublishUpdate(tester);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(
          find.textContaining(
              'subscribers are told when Channels is switched back on'),
          findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('a waiting announce is called out on My Channel',
        (tester) async {
      final status = ownStatus(fake);
      (status['own'] as Map<String, dynamic>)['pending_announce'] = true;
      fake.channelsStatus = status;
      await openMine(tester);
      expect(
          find.textContaining('not announced yet'), findsOneWidget);
      expect(
          find.textContaining(
              'told automatically when Channels is switched back on'),
          findsOneWidget);
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

  group('channel profile UI', () {
    testWidgets('create form: avatar picker + optional author field',
        (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home:
            CreateChannelScreen(api: ChannelsApi(base: FakeEmbeddedHttp.base)),
      ));
      await tester.pumpAndSettle();
      // The 96px circular picker with its camera badge and the empty
      // podcasts fallback.
      expect(find.byType(ChannelAvatarPicker), findsOneWidget);
      expect(find.byIcon(Icons.photo_camera_outlined), findsOneWidget);
      expect(find.byIcon(Icons.podcasts), findsOneWidget);
      // Author is optional, with the public-and-permanent helper.
      expect(find.text('Author name or handle'), findsOneWidget);
      expect(find.textContaining('Optional. Shown as "by <author>"'),
          findsOneWidget);
    });

    testWidgets('edit screen prefills the profile and saves author',
        (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      fake.channelsStatus = {
        'supported': true,
        'state': 'ready',
        'own': {
          'name': 'Nature Films',
          'description': 'My own footage',
          'author': 'Neil',
          'pubkey': fake.channelPubkey,
          'code': fake.channelCode,
          'seq': 0,
          'manifest': '',
          'created_at_ms': 1,
          'head': null,
        },
        'subs': const [],
      };
      await tester.pumpWidget(MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: EditChannelScreen(api: ChannelsApi(base: FakeEmbeddedHttp.base)),
      ));
      await tester.pumpAndSettle();
      // Prefilled from the channel config.
      expect(find.widgetWithText(TextField, 'Nature Films'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Neil'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'My own footage'),
          findsOneWidget);
      expect(find.byType(ChannelAvatarPicker), findsOneWidget);
      expect(find.textContaining('go public with the next publish'),
          findsOneWidget);
      // Change the author, save → the meta post carries all three.
      await tester.enterText(
          find.widgetWithText(TextField, 'Neil'), '@neil');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(fake.channelMetaPosts, hasLength(1));
      final posted =
          jsonDecode(fake.channelMetaPosts.single) as Map<String, dynamic>;
      expect(posted['name'], 'Nature Films');
      expect(posted['author'], '@neil');
      expect(posted['description'], 'My own footage');
    });

    testWidgets('own channel header shows avatar, author, and Edit',
        (tester) async {
      fake.channelsStatus = {
        'supported': true,
        'state': 'ready',
        'own': {
          'name': 'Nature Films',
          'description': 'My own footage',
          'author': 'Neil',
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
      await openChannels(tester);
      await tester.tap(find.text('My Channel'));
      await tester.pumpAndSettle();
      expect(find.text('by Neil'), findsOneWidget);
      expect(find.text('Edit channel details'), findsOneWidget);
      // The header's avatar renders (podcasts fallback — none set).
      expect(find.byType(ChannelAvatar), findsWidgets);
    });

    testWidgets('subscribed card shows the author line', (tester) async {
      final pubkey = 'cd' * 32;
      SharedPreferences.setMockInitialValues({
        'channel_subs_v1': jsonEncode({
          pubkey: {
            'name': 'Nature Films',
            'description': 'My own footage',
            'author': '@neil',
            'importedSeq': 1,
          }
        }),
      });
      await openChannels(tester);
      expect(find.text('by @neil'), findsOneWidget);
    });
  });
}
