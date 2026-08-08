import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/main.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/screens/detail_screen.dart';
import 'package:watchit/screens/search_screen.dart';
import 'package:watchit/screens/show_screen.dart';
import 'package:watchit/services/download_manager.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/services/watch_state.dart';
import 'package:watchit/theme/tokens.dart';

String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

List<MediaList> _library() => [
      MediaList(id: 'l1', title: 'Library', entries: [
        MediaEntry(
            name: 'Night of the Living Dead (1968).mkv', address: _addr(1)),
        MediaEntry(name: 'Show S01E01.mkv', address: _addr(2)),
        MediaEntry(name: 'Show S01E02.mkv', address: _addr(3)),
      ]),
    ];

Widget _page(List<MediaList> lists) => MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: SearchScreen(lists: lists),
    );

/// Type [text] and let the 150 ms debounce fire.
Future<void> _search(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pumpAndSettle();
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'defaults_seeded_v4': true});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    // Offline: no API key, so tiles render from parsed file names.
    MetadataService.instance = MetadataService(apiKeyProvider: () async => '');
    WatchStateStore.instance = WatchStateStore();
    DownloadManager.instance = DownloadManager();
  });

  testWidgets('home app bar search icon opens the search screen',
      (tester) async {
    await LibraryStore.save(_library());
    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();

    expect(find.byType(SearchScreen), findsOneWidget);
    expect(find.text('Search your library'), findsOneWidget);
  });

  testWidgets('typing finds shows, movies, and episodes grouped',
      (tester) async {
    await tester.pumpWidget(_page(_library()));
    await tester.pumpAndSettle();

    await _search(tester, 'show');
    expect(find.text('Shows'), findsOneWidget);
    expect(find.text('Episodes'), findsOneWidget);
    expect(find.text('Season 1 · 2 ep'), findsOneWidget);
    expect(find.text('S01E01'), findsOneWidget);
    expect(find.text('S01E02'), findsOneWidget);

    await _search(tester, 'night living');
    expect(find.text('Movies'), findsOneWidget);
    expect(find.text('Shows'), findsNothing);
    expect(find.text('Night of the Living Dead (1968)'), findsOneWidget);
  });

  testWidgets('short and unmatched queries show the empty states',
      (tester) async {
    await tester.pumpWidget(_page(_library()));
    await tester.pumpAndSettle();

    await _search(tester, 'n');
    expect(find.text('Search your library — titles, years, S01E02'),
        findsOneWidget);

    await _search(tester, 'zzzzz');
    expect(find.text('No matches in your library'), findsOneWidget);
  });

  testWidgets('clear button empties the query and results', (tester) async {
    await tester.pumpWidget(_page(_library()));
    await tester.pumpAndSettle();

    await _search(tester, 'night');
    expect(find.text('Night of the Living Dead (1968)'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.text('Night of the Living Dead (1968)'), findsNothing);
    expect(find.text('Search your library — titles, years, S01E02'),
        findsOneWidget);
  });

  testWidgets('tapping a movie result opens its detail page', (tester) async {
    await tester.pumpWidget(_page(_library()));
    await tester.pumpAndSettle();

    await _search(tester, 'night');
    await tester.tap(find.text('Night of the Living Dead (1968)'));
    await tester.pumpAndSettle();

    expect(find.byType(DetailScreen), findsOneWidget);
  });

  testWidgets('tapping a show result opens the show page', (tester) async {
    await tester.pumpWidget(_page(_library()));
    await tester.pumpAndSettle();

    await _search(tester, 'show');
    await tester.tap(find.text('Season 1 · 2 ep'));
    await tester.pumpAndSettle();

    expect(find.byType(ShowScreen), findsOneWidget);
  });

  testWidgets('groups cap at 20 with a Show all expander', (tester) async {
    tester.view.physicalSize = const Size(1000, 2800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final many = [
      MediaList(id: 'l1', title: 'Library', entries: [
        for (var i = 1; i <= 25; i++)
          MediaEntry(name: 'Movie $i (2000).mkv', address: _addr(i)),
      ]),
    ];
    await tester.pumpWidget(_page(many));
    await tester.pumpAndSettle();

    await _search(tester, 'movie');
    expect(find.byType(ListTile), findsNWidgets(20));
    expect(find.text('Show all 25'), findsOneWidget);

    await tester.tap(find.text('Show all 25'));
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNWidgets(25));
    expect(find.text('Show all 25'), findsNothing);
  });
}
