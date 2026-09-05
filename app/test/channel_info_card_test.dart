import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/screens/list_home_screen.dart';
import 'package:watchit/services/channel_service.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/channel_avatar.dart';
import 'package:watchit/widgets/channel_info_card.dart';
import 'package:watchit/widgets/wi_qr.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  // Known base32 vector: bytes 0x00..0x1f.
  const pubkey =
      '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';
  const code =
      'wchn1-aaaqeayeaudaocajbifqydiob4ibceqtcqkrmfyydenbwha5dypq';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    ChannelService.resetForTesting();
    // Real path_provider IO hangs the fake-async zone — override the
    // avatar-resolving dirs (created sync for the same reason).
    final postersDir = Directory.systemTemp.createTempSync('wi-cic');
    addTearDown(() => postersDir.deleteSync(recursive: true));
    ChannelService.instance.postersDirProvider = () async => postersDir;
    ChannelService.instance.profileDirProvider = () async => postersDir;
  });

  test('channelCodeFromPubkeyHex matches the Rust encoding', () {
    expect(channelCodeFromPubkeyHex(pubkey), code);
    expect(channelCodeFromPubkeyHex(pubkey).length, 'wchn1-'.length + 52);
    expect(channelCodeFromPubkeyHex('nonsense'), '');
    expect(channelCodeFromPubkeyHex('zz' * 32), '');
  });

  Future<void> pumpListPage(WidgetTester tester, MediaList list) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: ListHomeScreen(list: list),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'channel list page shows the profile card: avatar, by-author line, '
      'QR button; the app bar drops the entry count', (tester) async {
    SharedPreferences.setMockInitialValues({
      'channel_subs_v1': jsonEncode({
        pubkey: {
          'name': 'Nature Films',
          'description': 'My own footage of the local wetlands.',
          'author': '@neil',
          'importedSeq': 1,
        }
      }),
    });
    await pumpListPage(
      tester,
      MediaList(
        id: 'channel-x',
        title: 'Nature Films',
        entries: [
          MediaEntry(name: 'Waterfall (2026).mp4', address: 'aa' * 32),
        ],
        channelPubkey: pubkey,
        channelAuthor: '@neil',
        channelAvatar: 'channel_avatar_00112233.img',
      ),
    );
    expect(find.byType(ChannelInfoCard), findsOneWidget);
    expect(find.byType(ChannelAvatar), findsOneWidget);
    expect(find.text('by @neil · 1 entry'), findsOneWidget);
    expect(find.text('My own footage of the local wetlands.'),
        findsOneWidget);
    // The code line is gone — sharing goes through the QR button below
    // the badge, which opens the same dialog the Channels screen uses.
    expect(find.text(code), findsNothing);
    expect(find.byIcon(Icons.qr_code_2), findsOneWidget);
    await tester.tap(find.byIcon(Icons.qr_code_2));
    await tester.pumpAndSettle();
    expect(find.text('Share this code'), findsOneWidget);
    final qr = tester.widget<WiQr>(find.byType(WiQr));
    expect(qr.data, code);
    expect(find.text(code), findsOneWidget);
    await tester.tap(find.text('Copy & close'));
    await tester.pumpAndSettle();
    expect(find.text('Share this code'), findsNothing);
    // The card owns the count — the app bar shows only the title.
    expect(find.text('1 entry'), findsNothing);
    expect(find.text('CHANNEL'), findsOneWidget);
  });

  testWidgets('an authorless channel renders no "by" line', (tester) async {
    await pumpListPage(
      tester,
      MediaList(
        id: 'channel-x',
        title: 'Nature Films',
        entries: [
          MediaEntry(name: 'Waterfall (2026).mp4', address: 'aa' * 32),
        ],
        channelPubkey: pubkey,
      ),
    );
    expect(find.byType(ChannelInfoCard), findsOneWidget);
    expect(find.text('1 entry'), findsOneWidget);
    expect(find.textContaining('by '), findsNothing);
  });

  testWidgets('a plain list gets no card and keeps the app-bar count',
      (tester) async {
    await pumpListPage(
      tester,
      MediaList(
        id: 'mine',
        title: 'Movies',
        entries: [
          MediaEntry(name: 'Waterfall (2026).mp4', address: 'aa' * 32),
        ],
      ),
    );
    expect(find.byType(ChannelInfoCard), findsNothing);
    expect(find.text('1 entry'), findsOneWidget);
  });
}
