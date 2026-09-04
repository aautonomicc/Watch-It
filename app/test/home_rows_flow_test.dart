import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/main.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/screens/detail_screen.dart';
import 'package:watchit/services/download_manager.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/services/watch_state.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/services/terms.dart';

String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

const _movieName = 'Movie.2020.mkv';

MediaEntry get _movie => MediaEntry(name: _movieName, address: _addr(1));
MediaEntry get _ep1 =>
    MediaEntry(name: 'Show.S01E01.mkv', address: _addr(2));
MediaEntry get _ep2 =>
    MediaEntry(name: 'Show.S01E02.mkv', address: _addr(3));

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    // Skip default seeding so the rows only hold what each test stores.
    SharedPreferences.setMockInitialValues({'defaults_seeded_v4': true,
      'terms_accepted_version_v1': kTermsVersion});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    // Offline: no API key, so screens render from parsed file names.
    MetadataService.instance = MetadataService(apiKeyProvider: () async => '');
    WatchStateStore.instance = WatchStateStore();
    // The detail page awaits the download queue (default-version pick) —
    // a fresh manager per test keeps its load future in this test's DB
    // and zone (a cached cross-zone drift future deadlocks).
    DownloadManager.instance = DownloadManager();
  });

  // Seeds the library INSIDE the test body: the drift DB must see its
  // first use in the testWidgets fake-async zone. Warming it in setUp
  // (real zone) leaves every later in-test query hanging forever — the
  // whole suite deadlocked on exactly that before this was split out.
  Future<void> seedLibrary() => LibraryStore.save([
        MediaList(id: 'l1', title: 'Library', entries: [_movie, _ep1, _ep2]),
      ]);

  testWidgets('home shows Continue Watching and Recently Added rows',
      (tester) async {
    await seedLibrary();
    await WatchStateStore.instance.record(_movie,
        position: const Duration(minutes: 10),
        duration: const Duration(minutes: 100));
    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();

    expect(find.text('Continue Watching'), findsOneWidget);
    expect(find.text('1 h 30 min left'), findsOneWidget);
    // Entries were just saved, so they are all recent; episodes fold into
    // one show card alongside the movie card.
    expect(find.text('Recently Added'), findsOneWidget);
  });

  testWidgets('finishing an episode surfaces the next one as Next up',
      (tester) async {
    await seedLibrary();
    await WatchStateStore.instance
        .markCompleted(_ep1, duration: const Duration(minutes: 45));
    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();

    expect(find.text('Continue Watching'), findsOneWidget);
    expect(find.text('Next up · S01E02'), findsOneWidget);
  });

  testWidgets('a resumed music track gets a music-note Continue badge',
      (tester) async {
    final track = MediaEntry(
        name: 'Singer - Album (2001) - 01 Song.mp3', address: _addr(9));
    await LibraryStore.save([
      MediaList(id: 'l1', title: 'Music', entries: [track]),
    ]);
    await WatchStateStore.instance.record(track,
        position: const Duration(minutes: 2),
        duration: const Duration(minutes: 5));
    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();

    expect(find.text('Continue Watching'), findsOneWidget);
    // The music-note badge marks the card as a track, not a video.
    expect(find.byIcon(Icons.music_note), findsWidgets);
    expect(find.byIcon(Icons.movie_outlined), findsNothing);
  });

  testWidgets('no watch activity hides the Continue Watching row',
      (tester) async {
    await seedLibrary();
    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();

    expect(find.text('Continue Watching'), findsNothing);
    expect(find.text('Recently Added'), findsOneWidget);
  });

  Widget page(Widget home) => MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: home,
      );

  testWidgets('detail page offers Resume and Start over mid-file',
      (tester) async {
    await seedLibrary();
    await WatchStateStore.instance.record(_movie,
        position: const Duration(minutes: 10),
        duration: const Duration(minutes: 100));
    await tester.pumpWidget(page(DetailScreen(entry: _movie)));
    await tester.pumpAndSettle();

    expect(find.text('Resume · 10:00'), findsOneWidget);
    expect(find.text('Start over'), findsOneWidget);
    expect(find.text('Play'), findsNothing);
  });

  testWidgets('watched episode shows the badge and Next episode jump',
      (tester) async {
    await seedLibrary();
    await WatchStateStore.instance
        .markCompleted(_ep1, duration: const Duration(minutes: 45));
    await tester.pumpWidget(page(DetailScreen(entry: _ep1)));
    await tester.pumpAndSettle();

    expect(find.text('Watched'), findsOneWidget);
    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Next episode'), findsOneWidget);

    // The jump replaces the page with the next episode's detail page.
    await tester.ensureVisible(find.text('Next episode'));
    await tester.tap(find.text('Next episode'));
    await tester.pumpAndSettle();
    expect(find.text('S01E02'), findsOneWidget);
    expect(find.text('Watched'), findsNothing);
  });

  testWidgets('movie detail page has no Next episode button',
      (tester) async {
    await seedLibrary();
    await tester.pumpWidget(page(DetailScreen(entry: _movie)));
    await tester.pumpAndSettle();

    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Next episode'), findsNothing);
  });
}
