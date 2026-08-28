import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/main.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/screens/list_home_screen.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/services/watch_state.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/library_drawer.dart';
import 'package:watchit/widgets/poster_cards.dart';
import 'package:watchit/services/terms.dart';

String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

MediaEntry get _movie =>
    MediaEntry(name: 'Alpha (2020).mkv', address: _addr(1));
MediaEntry get _ep1 =>
    MediaEntry(name: 'Showname.S01E01.mkv', address: _addr(2));
MediaEntry get _ep2 =>
    MediaEntry(name: 'Showname.S01E02.mkv', address: _addr(3));

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    // Skip default seeding so surfaces only hold what each test stores.
    SharedPreferences.setMockInitialValues({'defaults_seeded_v4': true,
      'terms_accepted_version_v1': kTermsVersion});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    // Offline: no API key, so screens render from parsed file names plus
    // whatever cache rows the test seeds. The posters dir is injected —
    // the default provider needs path_provider, absent here.
    MetadataService.instance = MetadataService(
      apiKeyProvider: () async => '',
      postersDirProvider: () async => Directory.systemTemp,
    );
    WatchStateStore.instance = WatchStateStore();
  });

  // Seeds INSIDE the test body: the drift DB must see its first use in
  // the testWidgets fake-async zone (see home_rows_flow_test.dart).
  // 'Favourites', not 'Library' — the drawer's section header says
  // Library, and the finders must not collide with it.
  Future<void> seedLibrary() => LibraryStore.save([
        MediaList(
            id: 'l1', title: 'Favourites', entries: [_movie, _ep1, _ep2]),
      ]);

  Future<void> seedCategory(String name,
      {required String category,
      required String mediaType,
      String? title}) async {
    final db = await LibraryStore.database();
    final parsed = parseMediaName(name);
    await db.into(db.metadataCache).insert(MetadataCacheCompanion.insert(
          lookupKey: parsed.lookupKey,
          found: true,
          title: Value(title ?? parsed.title),
          year: Value(parsed.year),
          category: Value(category),
          mediaType: Value(mediaType),
          fetchedAt: DateTime.now().millisecondsSinceEpoch,
        ));
  }

  Widget page(Widget home) => MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: home,
      );

  testWidgets('the wall shows the list rows', (tester) async {
    await seedLibrary();
    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();

    expect(find.text('Favourites'), findsOneWidget);
  });

  testWidgets('drawer lists user lists and opens the list page',
      (tester) async {
    await seedLibrary();
    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Browse lists'));
    await tester.pumpAndSettle();
    final drawerTile = find.descendant(
        of: find.byType(WiLibraryDrawer), matching: find.text('Favourites'));
    expect(drawerTile, findsOneWidget);

    await tester.tap(drawerTile);
    await tester.pumpAndSettle();
    expect(find.byType(ListHomeScreen), findsOneWidget);
    expect(find.text('3 entries'), findsOneWidget);
    // One movie card + one folded show card in the grid.
    expect(find.byType(PosterCard), findsOneWidget);
    expect(find.byType(ShowCard), findsOneWidget);
  });

  testWidgets('genre chips multi-select narrows the grid', (tester) async {
    final gamma = MediaEntry(name: 'Gamma (2022).mkv', address: _addr(4));
    await LibraryStore.save([
      MediaList(id: 'l1', title: 'Films', entries: [
        _movie,
        MediaEntry(name: 'Beta (2021).mkv', address: _addr(5)),
        gamma,
      ]),
    ]);
    await seedCategory('Alpha (2020).mkv',
        category: 'Science Fiction · Comedy', mediaType: 'movie');
    await seedCategory('Beta (2021).mkv',
        category: 'Comedy', mediaType: 'movie');
    // Gamma has no match — it feeds the Uncategorised chip.

    final films = MediaList(id: 'l1', title: 'Films', entries: [
      _movie,
      MediaEntry(name: 'Beta (2021).mkv', address: _addr(5)),
      gamma,
    ]);
    await tester.pumpWidget(page(ListHomeScreen(list: films)));
    await tester.pumpAndSettle();

    expect(find.text('All'), findsOneWidget);
    expect(find.text('Comedy'), findsOneWidget);
    expect(find.text('Science Fiction'), findsOneWidget);
    expect(find.text('Uncategorised'), findsOneWidget);
    expect(find.byType(PosterCard), findsNWidgets(3));

    // Single genre.
    await tester.tap(find.text('Science Fiction'));
    await tester.pumpAndSettle();
    expect(find.text('Alpha (2020)'), findsOneWidget);
    expect(find.text('Beta (2021)'), findsNothing);

    // Multi-select is AND: sci-fi that is also a comedy.
    await tester.tap(find.text('Comedy'));
    await tester.pumpAndSettle();
    expect(find.text('Alpha (2020)'), findsOneWidget);
    expect(find.text('Beta (2021)'), findsNothing);

    // Deselect sci-fi: Comedy alone matches both comedies.
    await tester.tap(find.text('Science Fiction'));
    await tester.pumpAndSettle();
    expect(find.text('Alpha (2020)'), findsOneWidget);
    expect(find.text('Beta (2021)'), findsOneWidget);
    expect(find.text('Gamma (2022)'), findsNothing);

    // An impossible combination shows the empty state, not a blank page.
    await tester.tap(find.text('Uncategorised'));
    await tester.pumpAndSettle();
    expect(find.text('Nothing here matches the selected genres.'),
        findsOneWidget);

    // All resets.
    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    expect(find.byType(PosterCard), findsNWidgets(3));
  });

  testWidgets('no chips at all when nothing in the list is categorised',
      (tester) async {
    // Every entry unmatched → an Uncategorised chip would be the only
    // one, filtering nothing — the whole chip row stays hidden.
    final films = MediaList(id: 'l1', title: 'Films', entries: [
      _movie,
      MediaEntry(name: 'Beta (2021).mkv', address: _addr(5)),
    ]);
    await LibraryStore.save([films]);
    await tester.pumpWidget(page(ListHomeScreen(list: films)));
    await tester.pumpAndSettle();

    expect(find.text('Uncategorised'), findsNothing);
    expect(find.text('All'), findsNothing);
    expect(find.byType(PosterCard), findsNWidgets(2));
  });

  testWidgets('show cards filter by the show genres', (tester) async {
    await seedLibrary();
    await seedCategory('Showname.S01E01.mkv',
        category: 'Drama', mediaType: 'tv', title: 'Showname');
    await seedCategory('Showname.S01E02.mkv',
        category: 'Drama', mediaType: 'tv', title: 'Showname');
    await seedCategory('Alpha (2020).mkv',
        category: 'Comedy', mediaType: 'movie');

    final library = MediaList(
        id: 'l1', title: 'Library', entries: [_movie, _ep1, _ep2]);
    await tester.pumpWidget(page(ListHomeScreen(list: library)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Drama'));
    await tester.pumpAndSettle();
    expect(find.byType(ShowCard), findsOneWidget);
    expect(find.byType(PosterCard), findsNothing);

    await tester.tap(find.text('Comedy'));
    await tester.pumpAndSettle();
    // Drama + Comedy can match nothing — the empty state shows.
    expect(find.text('Nothing here matches the selected genres.'),
        findsOneWidget);
  });

  testWidgets('empty list shows its empty state', (tester) async {
    await tester.pumpWidget(page(ListHomeScreen(
        list: const MediaList(id: 'l9', title: 'Empty'))));
    await tester.pumpAndSettle();
    expect(find.text('This list is empty.'), findsOneWidget);
  });
}
