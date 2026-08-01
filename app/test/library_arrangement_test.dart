import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/app_settings.dart';
import 'package:watchit/services/library_arrangement.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata.dart';
import 'package:watchit/services/metadata_service.dart';

String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    // Offline: no API key, so classification runs from parsed file names
    // (plus whatever cache rows a test seeds). The posters dir is
    // injected — the default provider needs path_provider, absent here.
    MetadataService.instance = MetadataService(
      apiKeyProvider: () async => '',
      postersDirProvider: () async => Directory.systemTemp,
    );
    ArrangementStore.instance = ArrangementStore();
  });

  group('autoListTitleForType', () {
    test('maps mediaType case-insensitively', () {
      expect(autoListTitleForType('movie', 'x.mkv'), 'Movies');
      expect(autoListTitleForType('Movie', 'x.mkv'), 'Movies');
      expect(autoListTitleForType('MOVIE', 'x.mkv'), 'Movies');
      expect(autoListTitleForType('tv', 'x.mkv'), 'TV Shows');
      expect(autoListTitleForType('TV', 'x.mkv'), 'TV Shows');
    });

    test('unknown type falls back to the episode marker', () {
      expect(autoListTitleForType(null, 'Show S01E02.mkv'), 'TV Shows');
      expect(autoListTitleForType(null, 'Show 1x02.mkv'), 'TV Shows');
      expect(autoListTitleForType(null, 'Movie (2020).mkv'), 'Movies');
      expect(autoListTitleForType('weird', 'Show S01E02.mkv'), 'TV Shows');
    });
  });

  test('fallback metadata carries the media type', () {
    expect(
        fallbackMetadataFor(
                MediaEntry(name: 'Show S01E01.mkv', address: _addr(1)))
            .mediaType,
        'tv');
    expect(
        fallbackMetadataFor(MediaEntry(name: 'A.2020.mkv', address: _addr(2)))
            .mediaType,
        'movie');
  });

  test('cached TMDB media type wins over the filename guess', () async {
    // A movie-looking name whose TMDB match says TV.
    const name = 'Ambiguous (2020).mkv';
    final db = await LibraryStore.database();
    await db.into(db.metadataCache).insert(MetadataCacheCompanion.insert(
          lookupKey: parseMediaName(name).lookupKey,
          found: true,
          title: const Value('Ambiguous'),
          mediaType: const Value('tv'),
          fetchedAt: DateTime.now().millisecondsSinceEpoch,
        ));
    final entry = MediaEntry(name: name, address: _addr(9));
    MetadataService.instance.metadataFor(entry); // schedules the resolve
    await MetadataService.instance.whenIdle();
    expect(autoListTitleFor(entry), 'TV Shows');
  });

  group('autoLists', () {
    test('splits by type, dedupes by address, skips disabled lists', () {
      final movie = MediaEntry(name: 'Alpha.2020.mkv', address: _addr(1));
      final movieCopy =
          MediaEntry(name: 'Alpha copy.mkv', address: '0x${_addr(1)}');
      final ep = MediaEntry(name: 'Show.S01E01.mkv', address: _addr(2));
      final hidden = MediaEntry(name: 'Beta.2021.mkv', address: _addr(3));
      final lists = [
        MediaList(id: 'l1', title: 'One', entries: [movie, ep]),
        MediaList(id: 'l2', title: 'Two', entries: [movieCopy]),
        MediaList(
            id: 'l3', title: 'Off', entries: [hidden], enabled: false),
      ];
      final auto = autoLists(lists);
      expect(auto.map((l) => l.id), [kAutoMoviesListId, kAutoTvShowsListId]);
      expect(auto.map((l) => l.title), ['Movies', 'TV Shows']);
      expect(auto[0].entries.map((e) => e.name), ['Alpha.2020.mkv']);
      expect(auto[1].entries.map((e) => e.name), ['Show.S01E01.mkv']);
    });

    test('drops empty groups', () {
      final lists = [
        MediaList(id: 'l1', title: 'One', entries: [
          MediaEntry(name: 'Alpha.2020.mkv', address: _addr(1)),
        ]),
      ];
      final auto = autoLists(lists);
      expect(auto.map((l) => l.id), [kAutoMoviesListId]);
    });
  });

  test('autoIdForEntry classifies like the virtual lists', () {
    expect(autoIdForEntry(MediaEntry(name: 'Show S01E01.mkv', address: _addr(4))),
        kAutoTvShowsListId);
    expect(autoIdForEntry(MediaEntry(name: 'Movie (2020).mkv', address: _addr(5))),
        kAutoMoviesListId);
  });

  group('visibleAutoLists', () {
    final lists = [
      MediaList(id: 'l1', title: 'One', entries: [
        MediaEntry(name: 'Alpha.2020.mkv', address: _addr(1)),
        MediaEntry(name: 'Show.S01E01.mkv', address: _addr(2)),
      ]),
    ];

    test('filters hidden ids', () {
      expect(visibleAutoLists(lists, const {}).map((l) => l.id),
          [kAutoMoviesListId, kAutoTvShowsListId]);
      expect(visibleAutoLists(lists, {kAutoTvShowsListId}).map((l) => l.id),
          [kAutoMoviesListId]);
    });

    test('both hidden yields an empty wall', () {
      expect(
          visibleAutoLists(lists, {kAutoMoviesListId, kAutoTvShowsListId}),
          isEmpty);
    });
  });

  test('browsableLists drops hidden virtual lists only in auto mode', () {
    final lists = [
      MediaList(id: 'l1', title: 'One', entries: [
        MediaEntry(name: 'Alpha.2020.mkv', address: _addr(1)),
        MediaEntry(name: 'Show.S01E01.mkv', address: _addr(2)),
      ]),
    ];
    expect(
        browsableLists(lists, LibraryArrangement.autoByType,
            hiddenAutoIds: {kAutoTvShowsListId}).map((l) => l.id),
        [kAutoMoviesListId]);
    // User mode ignores the auto-mode hide set entirely.
    expect(
        browsableLists(lists, LibraryArrangement.userLists,
            hiddenAutoIds: {kAutoTvShowsListId}).map((l) => l.id),
        ['l1']);
  });

  test('browsableLists follows the arrangement', () {
    final lists = [
      MediaList(id: 'l1', title: 'One', entries: [
        MediaEntry(name: 'Alpha.2020.mkv', address: _addr(1)),
      ]),
      MediaList(id: 'l2', title: 'Off', enabled: false),
    ];
    expect(
        browsableLists(lists, LibraryArrangement.userLists).map((l) => l.id),
        ['l1']);
    expect(
        browsableLists(lists, LibraryArrangement.autoByType).map((l) => l.id),
        [kAutoMoviesListId]);
  });

  test('genreNames splits the category string', () {
    expect(genreNames('Horror · Thriller'), ['Horror', 'Thriller']);
    expect(genreNames('Comedy'), ['Comedy']);
    expect(genreNames(null), isEmpty);
    expect(genreNames('  '), isEmpty);
  });

  test('ArrangementStore persists and reloads the choice', () async {
    await ArrangementStore.instance.ensureLoaded();
    expect(ArrangementStore.instance.value, LibraryArrangement.userLists);

    await ArrangementStore.instance.set(LibraryArrangement.autoByType);
    expect(ArrangementStore.instance.isAuto, isTrue);
    expect(
        await AppSettings.libraryArrangement(), LibraryArrangement.autoByType);

    final fresh = ArrangementStore();
    await fresh.ensureLoaded();
    expect(fresh.value, LibraryArrangement.autoByType);
  });

  test('ArrangementStore toggles and persists hidden virtual lists',
      () async {
    await ArrangementStore.instance.ensureLoaded();
    expect(ArrangementStore.instance.hiddenAutoIds, isEmpty);

    await ArrangementStore.instance.toggleAutoHidden(kAutoTvShowsListId);
    expect(ArrangementStore.instance.hiddenAutoIds, {kAutoTvShowsListId});
    expect(await AppSettings.autoHiddenLists(), {kAutoTvShowsListId});

    // A fresh store reloads the persisted set; toggling again clears it.
    final fresh = ArrangementStore();
    await fresh.ensureLoaded();
    expect(fresh.hiddenAutoIds, {kAutoTvShowsListId});
    await fresh.toggleAutoHidden(kAutoTvShowsListId);
    expect(fresh.hiddenAutoIds, isEmpty);
    expect(await AppSettings.autoHiddenLists(), isEmpty);
  });
}
