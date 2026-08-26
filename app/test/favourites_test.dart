import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/main.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/screens/detail_screen.dart';
import 'package:watchit/services/favourites.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/services/season_grouping.dart';
import 'package:watchit/services/watch_state.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/services/terms.dart';

String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

MediaEntry _e(String name, int i) => MediaEntry(name: name, address: _addr(i));

List<MediaList> _library(List<MediaEntry> entries, {bool enabled = true}) => [
      MediaList(id: 'l1', title: 'Library', entries: entries, enabled: enabled),
    ];

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    // Skip default seeding so surfaces only hold what each test stores.
    SharedPreferences.setMockInitialValues({'defaults_seeded_v4': true,
      'terms_accepted_version_v1': kTermsVersion});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    // Offline: no API key, so screens render from parsed file names.
    MetadataService.instance = MetadataService(apiKeyProvider: () async => '');
    WatchStateStore.instance = WatchStateStore();
    FavouritesStore.instance = FavouritesStore();
  });

  group('FavouritesStore', () {
    test('toggle adds, toggles off, and notifies', () async {
      final store = FavouritesStore();
      var notified = 0;
      store.addListener(() => notified++);
      expect(store.isFavourite(_addr(1)), isFalse);
      await store.toggle(_addr(1));
      expect(store.isFavourite(_addr(1)), isTrue);
      await store.toggle(_addr(1));
      expect(store.isFavourite(_addr(1)), isFalse);
      expect(notified, 2);
    });

    test('addresses are normalized (case, 0x prefix)', () async {
      final store = FavouritesStore();
      await store.toggle('0x${_addr(1).toUpperCase()}');
      expect(store.isFavourite(_addr(1)), isTrue);
      expect(store.isFavourite('0x${_addr(1)}'), isTrue);
    });

    test('favourites persist across store instances', () async {
      final store = FavouritesStore();
      await store.toggle(_addr(1));
      await store.toggle(_addr(2));
      await store.toggle(_addr(2)); // off again — must not persist

      final reloaded = FavouritesStore();
      await reloaded.ensureLoaded();
      expect(reloaded.isFavourite(_addr(1)), isTrue);
      expect(reloaded.isFavourite(_addr(2)), isFalse);
    });
  });

  group('favouriteItems', () {
    test('only favourited entries appear, in library order', () {
      final lists = _library([
        _e('Movie.2020.mkv', 1),
        _e('Other.2021.mkv', 2),
        _e('Third.2022.mkv', 3),
      ]);
      final row =
          favouriteItems(lists, isFavourite: (e) => e.address != _addr(2));
      expect(
        [for (final item in row) (item as HomeEntry).entry.address],
        [_addr(1), _addr(3)],
      );
    });

    test('a show\'s favourited episodes fold into one show card', () {
      final lists = _library([
        _e('Show.S01E01.mkv', 1),
        _e('Show.S01E02.mkv', 2),
        _e('Show.S02E01.mkv', 3),
        _e('Movie.2020.mkv', 4),
      ]);
      final row =
          favouriteItems(lists, isFavourite: (e) => e.address != _addr(2));
      expect(row, hasLength(2));
      expect(row.first, isA<HomeShow>());
      expect((row.first as HomeShow).episodeCount, 2);
      expect((row.last as HomeEntry).entry.address, _addr(4));
    });

    test('empty when nothing is favourited; hidden lists excluded', () {
      final lists = _library([_e('Movie.2020.mkv', 1)]);
      expect(favouriteItems(lists, isFavourite: (_) => false), isEmpty);
      final hidden = _library([_e('Movie.2020.mkv', 1)], enabled: false);
      expect(favouriteItems(hidden, isFavourite: (_) => true), isEmpty);
    });

    test('duplicate addresses across lists appear once', () {
      final lists = [
        MediaList(id: 'l1', title: 'A', entries: [_e('Movie.2020.mkv', 1)]),
        MediaList(id: 'l2', title: 'B', entries: [_e('Movie.2020.mkv', 1)]),
      ];
      expect(favouriteItems(lists, isFavourite: (_) => true), hasLength(1));
    });

    test('same-title versions fold into one card', () {
      final lists = _library([
        _e('Movie (2020) {imdb-tt0000001} - [480p].mkv', 1),
        _e('Movie (2020) {imdb-tt0000001} - [1080p].mkv', 2),
      ]);
      final row = favouriteItems(lists, isFavourite: (_) => true);
      expect(row, hasLength(1));
      expect((row.single as HomeEntry).allVersions, hasLength(2));
    });
  });

  // Seeds the library INSIDE the test body: the drift DB must see its
  // first use in the testWidgets fake-async zone (see home_rows_flow_test).
  Future<void> seedLibrary() => LibraryStore.save(
      _library([_e('Movie.2020.mkv', 1), _e('Other.2021.mkv', 2)]));

  Widget page(Widget home) => MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: home,
      );

  testWidgets('detail page heart toggles the favourite', (tester) async {
    await seedLibrary();
    await tester.pumpWidget(page(DetailScreen(entry: _e('Movie.2020.mkv', 1))));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Add to Favourites'), findsOneWidget);
    await tester.tap(find.byTooltip('Add to Favourites'));
    await tester.pumpAndSettle();
    expect(FavouritesStore.instance.isFavourite(_addr(1)), isTrue);
    expect(find.byIcon(Icons.favorite), findsOneWidget);

    await tester.tap(find.byTooltip('Remove from Favourites'));
    await tester.pumpAndSettle();
    expect(FavouritesStore.instance.isFavourite(_addr(1)), isFalse);
    expect(find.byIcon(Icons.favorite_border), findsOneWidget);
  });

  testWidgets('heart sits in the action row beside Download, not the app bar',
      (tester) async {
    await seedLibrary();
    await tester.pumpWidget(page(DetailScreen(entry: _e('Movie.2020.mkv', 1))));
    await tester.pumpAndSettle();

    final heart = find.byTooltip('Add to Favourites');
    expect(
        find.descendant(of: find.byType(AppBar), matching: heart),
        findsNothing);
    expect(
        find.ancestor(of: heart, matching: find.byType(Wrap)),
        findsOneWidget);
    // Same Wrap as the Download button, immediately to its right.
    final wrap = tester.widget<Wrap>(
        find.ancestor(of: heart, matching: find.byType(Wrap)).first);
    final children = wrap.children;
    final downloadIndex = children.indexWhere((w) =>
        w is OutlinedButton &&
        find
            .descendant(
                of: find.byWidget(w), matching: find.text('Download'))
            .evaluate()
            .isNotEmpty);
    expect(downloadIndex, greaterThanOrEqualTo(0));
    expect(children[downloadIndex + 1], isA<IconButton>());
  });

  testWidgets('home shows the Favourites row only when hearts exist',
      (tester) async {
    await seedLibrary();
    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();
    expect(find.text('Favourites'), findsNothing);

    await FavouritesStore.instance.toggle(_addr(1));
    await tester.pumpAndSettle();
    expect(find.text('Favourites'), findsOneWidget);

    await FavouritesStore.instance.toggle(_addr(1));
    await tester.pumpAndSettle();
    expect(find.text('Favourites'), findsNothing);
  });

  testWidgets('stored favourites load on a fresh start', (tester) async {
    SharedPreferences.setMockInitialValues({
      'defaults_seeded_v4': true,
      'terms_accepted_version_v1': kTermsVersion,
      'favourites_v1': [_addr(2)],
    });
    await seedLibrary();
    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();
    expect(find.text('Favourites'), findsOneWidget);
  });
}
