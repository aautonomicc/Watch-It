import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/main.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/library_store.dart';

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

      // Persisted: store now holds the list with its entry.
      final lists = await LibraryStore.load();
      expect(lists.single.title, 'My Films');
      expect(lists.single.entries.single.name, 'Movie.mkv');
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
      expect(find.text('Show.S01E01.mkv'), findsOneWidget);
      expect(find.text('Your library is empty'), findsNothing);
    });
  });
}
