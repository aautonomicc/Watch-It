import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/main.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/app_settings.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata.dart';
import 'package:watchit/services/embedded_client.dart';

const _addr =
    'a3f1c9e07b6d5a4f2e8c1b0d9f7a6e5c4b3a2d1e0f9c8b7a6d5e4f3c2b1a0d9e';

void main() {
  // Each test gets its own in-memory database, so the multiple-instance
  // race drift warns about cannot happen.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
  });

  group('MediaList model', () {
    test('JSON round-trip preserves title and entries', () {
      final list = MediaList(
        id: '1',
        title: 'Films',
        entries: const [MediaEntry(name: 'Movie.mkv', address: _addr)],
      );
      final restored = MediaList.fromJson(list.toJson());
      expect(restored.id, '1');
      expect(restored.title, 'Films');
      expect(restored.entries.single.name, 'Movie.mkv');
      expect(restored.entries.single.address, _addr);
    });

    test('XOR address validation', () {
      expect(looksLikeXorAddress(_addr), isTrue);
      expect(looksLikeXorAddress('0x$_addr'), isTrue);
      expect(looksLikeXorAddress('not-an-address'), isFalse);
      expect(looksLikeXorAddress(_addr.substring(1)), isFalse);
    });
  });

  group('LibraryStore', () {
    test('save then load returns the same lists', () async {
      await LibraryStore.save([
        MediaList(
          id: '42',
          title: 'Series',
          entries: const [MediaEntry(name: 'Ep1.mkv', address: _addr)],
        ),
      ]);
      final loaded = await LibraryStore.load();
      expect(loaded.single.title, 'Series');
      expect(loaded.single.entries.single.address, _addr);
    });

    test('empty store loads as empty list', () async {
      expect(await LibraryStore.load(), isEmpty);
    });

    test('save preserves list and entry order', () async {
      await LibraryStore.save([
        for (var i = 0; i < 3; i++)
          MediaList(
            id: 'l$i',
            title: 'List $i',
            entries: [
              for (var j = 0; j < 3; j++)
                MediaEntry(name: 'e$i-$j.mkv', address: _addr),
            ],
          ),
      ]);
      final loaded = await LibraryStore.load();
      expect(loaded.map((l) => l.title), ['List 0', 'List 1', 'List 2']);
      expect(loaded[1].entries.map((e) => e.name),
          ['e1-0.mkv', 'e1-1.mkv', 'e1-2.mkv']);
    });
  });

  group('Legacy SharedPreferences import', () {
    test('imports the pre-SQLite JSON blob once and removes it', () async {
      SharedPreferences.setMockInitialValues({
        'media_lists_v1': jsonEncode([
          MediaList(
            id: 'legacy',
            title: 'From Prefs',
            entries: const [MediaEntry(name: 'Old.mkv', address: _addr)],
          ).toJson(),
        ]),
      });
      final loaded = await LibraryStore.load();
      expect(loaded.single.title, 'From Prefs');
      expect(loaded.single.entries.single.name, 'Old.mkv');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('media_lists_v1'), isNull);
    });

    test('corrupt blob is dropped without error', () async {
      SharedPreferences.setMockInitialValues({'media_lists_v1': 'not-json'});
      expect(await LibraryStore.load(), isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('media_lists_v1'), isNull);
    });
  });

  group('Default seeding', () {
    test('seeds the built-in test movie once', () async {
      await LibraryStore.ensureDefaults();
      final lists = await LibraryStore.load();
      final seeded = lists.singleWhere((l) => l.title == 'Test Movies');
      expect(seeded.entries.single.address, kDefaultMovieAddress);
      expect(seeded.entries.single.name, kDefaultMovieName);
    });

    test('does not re-seed after the user deletes it', () async {
      await LibraryStore.ensureDefaults();
      await LibraryStore.save([]);
      await LibraryStore.ensureDefaults();
      expect(await LibraryStore.load(), isEmpty);
    });

    for (final legacy in kLegacyDefaultMovieAddresses) {
      test('rewrites stale default address $legacy in place', () async {
        await LibraryStore.save([
          MediaList(
            id: 'default-test-movies',
            title: 'Test Movies',
            entries: [
              MediaEntry(
                name: 'Night Of The Living Dead (1968)',
                address: legacy,
              ),
            ],
          ),
        ]);
        await LibraryStore.ensureDefaults();
        final lists = await LibraryStore.load();
        final seeded = lists.singleWhere((l) => l.title == 'Test Movies');
        expect(seeded.entries.single.address, kDefaultMovieAddress);
        expect(seeded.entries.single.name, kDefaultMovieName);
        // Other lists/entries with the current address are not duplicated.
        expect(
          lists
              .expand((l) => l.entries)
              .where((e) => e.address == kDefaultMovieAddress),
          hasLength(1),
        );
      });
    }
  });

  group('Metadata', () {
    test('default movie resolves from the bundled catalog', () {
      final meta = fallbackMetadataFor(const MediaEntry(
        name: kDefaultMovieName,
        address: kDefaultMovieAddress,
      ));
      expect(meta.title, 'Night of the Living Dead');
      expect(meta.year, 1968);
      expect(meta.overview, isNotNull);
      expect(meta.posterAsset, 'assets/posters/notld_1968.jpg');
    });

    test('unknown address falls back to parsed file name', () {
      final meta = fallbackMetadataFor(
          const MediaEntry(name: 'The.Movie.2024.1080p.mkv', address: _addr));
      expect(meta.title, 'The Movie');
      expect(meta.year, 2024);
      expect(meta.posterAsset, isNull);
    });

    test('parseMediaName handles common shapes', () {
      expect(parseMediaName('The.Movie.2024.1080p.mkv').title, 'The Movie');
      expect(parseMediaName('The.Movie.2024.1080p.mkv').year, 2024);
      expect(parseMediaName('Some Film (1999)').title, 'Some Film');
      expect(parseMediaName('Some Film (1999)').year, 1999);
      expect(parseMediaName('plainname').title, 'plainname');
      expect(parseMediaName('The.Movie.2024.1080p.mkv').imdbId, isNull);
      expect(parseMediaName('The.Movie.2024.1080p.mkv').isEpisode, isFalse);
    });

    test('parseMediaName extracts season/episode markers', () {
      final sxxeyy = parseMediaName('Show.S01E01.mkv');
      expect(sxxeyy.title, 'Show');
      expect(sxxeyy.year, isNull);
      expect(sxxeyy.season, 1);
      expect(sxxeyy.episode, 1);
      expect(sxxeyy.isEpisode, isTrue);

      final full = parseMediaName(
          'The Show (2019) S02E13 The Episode Name [1080p].mkv');
      expect(full.title, 'The Show');
      expect(full.year, 2019);
      expect(full.season, 2);
      expect(full.episode, 13);

      final xStyle = parseMediaName('Show 2x05.mkv');
      expect(xStyle.title, 'Show');
      expect(xStyle.season, 2);
      expect(xStyle.episode, 5);

      // Resolutions must not read as episode markers.
      final res = parseMediaName('The.Movie.2024.1920x1080.mkv');
      expect(res.isEpisode, isFalse);
      expect(res.title, 'The Movie');
      expect(res.year, 2024);
    });

    test('lookupKey shares cache rows across renames of one film', () {
      expect(
        parseMediaName('The Movie (2024) - [1080p].mkv').lookupKey,
        parseMediaName('The.Movie.2024.720p.mkv').lookupKey,
      );
      expect(
        parseMediaName('A (2024) {imdb-tt1} - [1080p].mkv').lookupKey,
        'imdb:tt1',
      );
      expect(parseMediaName('Show.S01E02.mkv').lookupKey,
          'tv:show::s1:e2');
    });

    test('parseMediaName handles Plex/Jellyfin naming with id tags', () {
      const plex =
          'Night of the Living Dead (1968) {imdb-tt0063350} - [1080p].mp4';
      expect(parseMediaName(plex).title, 'Night of the Living Dead');
      expect(parseMediaName(plex).year, 1968);
      expect(parseMediaName(plex).imdbId, 'tt0063350');

      const jellyfin = 'The Movie (2024) [imdbid-tt1234567] - [1080p].mkv';
      expect(parseMediaName(jellyfin).title, 'The Movie');
      expect(parseMediaName(jellyfin).year, 2024);
      expect(parseMediaName(jellyfin).imdbId, 'tt1234567');

      // Quality tag but no id tag.
      const tagged = 'Some Film (1999) - [720p].mkv';
      expect(parseMediaName(tagged).title, 'Some Film');
      expect(parseMediaName(tagged).year, 1999);
      expect(parseMediaName(tagged).imdbId, isNull);
    });
  });

  group('Stream URL', () {
    const entry = MediaEntry(name: 'Movie.mkv', address: _addr);

    test('joins server base and address, trimming trailing slashes', () {
      expect(streamUrl('http://127.0.0.1:43210', entry),
          'http://127.0.0.1:43210/xor/$_addr');
      expect(streamUrl('http://127.0.0.1:43210///', entry),
          'http://127.0.0.1:43210/xor/$_addr');
    });

    test('strips 0x prefix and lowercases the address', () {
      final upper = MediaEntry(
          name: 'Movie.mkv', address: '0x${_addr.toUpperCase()}');
      expect(streamUrl('http://gw', upper), 'http://gw/xor/$_addr');
    });

    test('missing server yields null', () {
      expect(streamUrl(null, entry), isNull);
      expect(streamUrl('', entry), isNull);
      expect(streamUrl('   ', entry), isNull);
    });
  });

  group('Byte label', () {
    test('formats KB and MB for buffering progress', () {
      expect(byteLabel(0), '0 KB');
      expect(byteLabel(870 * 1024), '870 KB');
      expect(byteLabel(12 * 1024 * 1024 + 400 * 1024), '12.4 MB');
      expect(byteLabel(250 * 1024 * 1024), '250 MB');
    });
  });

  group('Settings flow', () {
    testWidgets('home has a settings button that opens Settings',
        (tester) async {
      await tester.pumpWidget(const WatchItApp());
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();

      expect(find.text('MEDIA LISTS'), findsOneWidget);
      expect(find.text('New list'), findsOneWidget);

      // Streaming section: buffer size tile showing the current value.
      await tester.scrollUntilVisible(find.text('Buffer size'), 100);
      expect(find.text('32 MB'), findsOneWidget);

      // About section: app blurb and installed version.
      await tester.scrollUntilVisible(find.text('Version'), 100);
      expect(find.text('ABOUT'), findsOneWidget);
      expect(find.text('Version'), findsOneWidget);
    });

    testWidgets('buffer size can be changed and persists', (tester) async {
      await tester.pumpWidget(const WatchItApp());
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('Buffer size'), 100);
      await tester.tap(find.text('Buffer size'));
      await tester.pumpAndSettle();

      expect(find.text('32 MB  ·  default'), findsOneWidget);
      await tester.tap(find.text('128 MB'));
      await tester.pumpAndSettle();

      // Tile reflects the new choice, and the store holds it.
      expect(find.text('128 MB'), findsOneWidget);
      expect(await AppSettings.bufferSizeMb(), 128);
    });

    testWidgets('create a titled list, then add an entry', (tester) async {
      await tester.pumpWidget(const WatchItApp());
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();

      // Create list with a title.
      await tester.tap(find.text('New list'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'My Films');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('My Films'), findsOneWidget);
      expect(find.text('0 entries'), findsOneWidget);

      // Open it and add an entry.
      await tester.tap(find.text('My Films'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add entry'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextField, 'File name'), 'Movie.mkv');
      await tester.enterText(
          find.widgetWithText(TextField, 'XOR address'), _addr);
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(find.text('Movie.mkv'), findsOneWidget);

      // Persisted: store now holds the list with its entry (alongside the
      // seeded Test Movies list).
      final lists = await LibraryStore.load();
      final mine = lists.singleWhere((l) => l.title == 'My Films');
      expect(mine.entries.single.name, 'Movie.mkv');
    });

    testWidgets('home shows the list after returning from settings',
        (tester) async {
      await LibraryStore.save([
        MediaList(
          id: '7',
          title: 'Weekend Queue',
          entries: const [MediaEntry(name: 'Show.S01E01.mkv', address: _addr)],
        ),
      ]);
      await tester.pumpWidget(const WatchItApp());
      await tester.pumpAndSettle();

      expect(find.text('Weekend Queue'), findsOneWidget);
      // Poster cards show the parsed display title, not the raw file name
      // (episode markers are stripped into season/episode since alpha.23).
      expect(find.text('Show'), findsOneWidget);
      expect(find.text('Your library is empty'), findsNothing);
    });
  });
}
