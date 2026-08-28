import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/screens/list_edit_screen.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/theme/tokens.dart';

String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

MediaEntry get _movie =>
    MediaEntry(name: 'Alpha (2020).mkv', address: _addr(1));
MediaEntry get _s1e1 =>
    MediaEntry(name: 'Showname.S01E01.mkv', address: _addr(2));
MediaEntry get _s1e2 =>
    MediaEntry(name: 'Showname.S01E02.mkv', address: _addr(3));
MediaEntry get _s2e1 =>
    MediaEntry(name: 'Showname.S02E01.mkv', address: _addr(4));

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'defaults_seeded_v4': true});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    MetadataService.instance = MetadataService(
      apiKeyProvider: () async => '',
      postersDirProvider: () async => Directory.systemTemp,
    );
  });

  Future<void> seed({List<MediaList> extra = const []}) =>
      LibraryStore.save([
        MediaList(
            id: 'l1',
            title: 'Mixed',
            entries: [_movie, _s1e1, _s1e2, _s2e1]),
        ...extra,
      ]);

  Widget page() => MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: const ListEditScreen(listId: 'l1'),
      );

  Future<List<MediaList>> stored() => LibraryStore.load();

  testWidgets('entries group show → season → episode', (tester) async {
    await seed();
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    // Top level: the movie row and one collapsed show tile.
    expect(find.text('Alpha (2020).mkv'), findsOneWidget);
    expect(find.text('Showname'), findsOneWidget);
    expect(find.text('2 seasons · 3 episodes'), findsOneWidget);
    expect(find.text('Season 1'), findsNothing);
    expect(find.text('Showname.S01E01.mkv'), findsNothing);

    // Expand the show: its seasons appear, episodes still folded.
    await tester.tap(find.text('Showname'));
    await tester.pumpAndSettle();
    expect(find.text('Season 1'), findsOneWidget);
    expect(find.text('Season 2'), findsOneWidget);
    expect(find.text('2 episodes'), findsOneWidget);
    expect(find.text('Showname.S01E01.mkv'), findsNothing);

    // Expand a season: its episodes appear.
    await tester.tap(find.text('Season 1'));
    await tester.pumpAndSettle();
    expect(find.text('Showname.S01E01.mkv'), findsOneWidget);
    expect(find.text('Showname.S01E02.mkv'), findsOneWidget);
    expect(find.text('Showname.S02E01.mkv'), findsNothing);
  });

  testWidgets('removing a season asks and drops its episodes',
      (tester) async {
    await seed();
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Showname'));
    await tester.pumpAndSettle();
    // The season row's menu is the second Options button (show first).
    await tester.tap(find.descendant(
        of: find.widgetWithText(ListTile, 'Season 1'),
        matching: find.byTooltip('Options')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from list'));
    await tester.pumpAndSettle();
    expect(find.text('Remove season 1 of "Showname"?'), findsOneWidget);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();

    final lists = await stored();
    expect(lists.single.entries.map((e) => e.name),
        ['Alpha (2020).mkv', 'Showname.S02E01.mkv']);
  });

  testWidgets('moving a show to a fresh list creates it', (tester) async {
    await seed();
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(
        of: find.widgetWithText(ListTile, 'Showname'),
        matching: find.byTooltip('Options')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to another list…'));
    await tester.pumpAndSettle();
    expect(find.text('Move "Showname" to…'), findsOneWidget);

    await tester.tap(find.text('Create new list'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Shows only');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final lists = await stored();
    expect(lists.map((l) => l.title), ['Mixed', 'Shows only']);
    expect(lists[0].entries.map((e) => e.name), ['Alpha (2020).mkv']);
    expect(lists[1].entries.map((e) => e.name), [
      'Showname.S01E01.mkv',
      'Showname.S01E02.mkv',
      'Showname.S02E01.mkv',
    ]);
    expect(find.text('Moved 3 entries to "Shows only"'), findsOneWidget);
  });

  testWidgets('moving an item to an existing list skips duplicates',
      (tester) async {
    await seed(extra: [
      MediaList(id: 'l2', title: 'Films', entries: [
        MediaEntry(name: 'Alpha copy.mkv', address: '0x${_addr(1)}'),
      ]),
    ]);
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(
        of: find.widgetWithText(ListTile, 'Alpha (2020).mkv'),
        matching: find.byTooltip('Options')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to another list…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Films'));
    await tester.pumpAndSettle();

    final lists = await stored();
    // Gone from the source; the target already held the same address
    // (0x-prefixed), so nothing was doubled.
    expect(lists[0].entries.map((e) => e.name), [
      'Showname.S01E01.mkv',
      'Showname.S01E02.mkv',
      'Showname.S02E01.mkv',
    ]);
    expect(lists[1].entries.map((e) => e.name), ['Alpha copy.mkv']);
    expect(find.text('Moved 1 entry to "Films" (1 already there)'),
        findsOneWidget);
  });

  testWidgets('channel lists are not offered as move targets',
      (tester) async {
    await seed(extra: [
      MediaList(
          id: 'ch',
          title: 'A Channel',
          channelPubkey: 'f' * 64,
          entries: const []),
    ]);
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(
        of: find.widgetWithText(ListTile, 'Alpha (2020).mkv'),
        matching: find.byTooltip('Options')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to another list…'));
    await tester.pumpAndSettle();
    expect(find.text('A Channel'), findsNothing);
    expect(find.text('Create new list'), findsOneWidget);
  });
}
