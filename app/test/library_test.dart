import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/main.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata.dart';
import 'package:watchit/services/stream_settings.dart';

const _addr =
    'a3f1c9e07b6d5a4f2e8c1b0d9f7a6e5c4b3a2d1e0f9c8b7a6d5e4f3c2b1a0d9e';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
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
  });

  group('Default seeding', () {
    test('seeds the built-in test movie once', () async {
      await LibraryStore.ensureDefaults();
      final lists = await LibraryStore.load();
      final seeded = lists.singleWhere((l) => l.title == 'Test Movies');
      expect(seeded.entries.single.address, kDefaultMovieAddress);
      expect(seeded.entries.single.name, 'Night Of The Living Dead (1968)');
    });

    test('does not re-seed after the user deletes it', () async {
      await LibraryStore.ensureDefaults();
      await LibraryStore.save([]);
      await LibraryStore.ensureDefaults();
      expect(await LibraryStore.load(), isEmpty);
    });
  });

  group('Metadata', () {
    test('default movie resolves from the bundled catalog', () {
      final meta = metadataFor(const MediaEntry(
        name: 'Night Of The Living Dead (1968)',
        address: kDefaultMovieAddress,
      ));
      expect(meta.title, 'Night of the Living Dead');
      expect(meta.year, 1968);
      expect(meta.overview, isNotNull);
      expect(meta.posterAsset, 'assets/posters/notld_1968.jpg');
    });

    test('unknown address falls back to parsed file name', () {
      final meta = metadataFor(
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
      expect(parseMediaName('Show.S01E01.mkv').title, 'Show S01E01');
      expect(parseMediaName('Show.S01E01.mkv').year, isNull);
      expect(parseMediaName('plainname').title, 'plainname');
    });
  });

  group('Stream URL', () {
    const entry = MediaEntry(name: 'Movie.mkv', address: _addr);

    test('joins gateway and address, trimming trailing slashes', () {
      expect(streamUrl('http://192.168.20.2:18888', entry),
          'http://192.168.20.2:18888/$_addr');
      expect(streamUrl('http://gw:18888///', entry),
          'http://gw:18888/$_addr');
    });

    test('strips 0x prefix and lowercases the address', () {
      final upper = MediaEntry(
          name: 'Movie.mkv', address: '0x${_addr.toUpperCase()}');
      expect(streamUrl('http://gw', upper), 'http://gw/$_addr');
    });

    test('empty gateway yields null', () {
      expect(streamUrl('', entry), isNull);
      expect(streamUrl('   ', entry), isNull);
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
      // Poster cards show the parsed display title, not the raw file name.
      expect(find.text('Show S01E01'), findsOneWidget);
      expect(find.text('Your library is empty'), findsNothing);
    });
  });
}
