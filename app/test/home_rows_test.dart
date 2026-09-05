import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/home_rows.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/season_grouping.dart';
import 'package:watchit/services/watch_state.dart';

String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

MediaEntry _e(String name, int i, {int? addedAt}) =>
    MediaEntry(name: name, address: _addr(i), addedAt: addedAt);

List<MediaList> _library(List<MediaEntry> entries, {bool enabled = true}) =>
    [MediaList(id: 'l1', title: 'Stuff', entries: entries, enabled: enabled)];

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late WatchStateStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    store = WatchStateStore.instance = WatchStateStore();
  });

  Future<void> resume(MediaEntry e, {int minutes = 10}) => store.record(e,
      position: Duration(minutes: minutes),
      duration: const Duration(minutes: 100));

  group('nextEpisode', () {
    final lists = _library([
      _e('Show.S01E01.mkv', 1),
      _e('Show.S01E02.mkv', 2),
      _e('Show.S02E01.mkv', 3),
      _e('Movie.2020.mkv', 4),
    ]);

    test('next within the season', () {
      expect(nextEpisode(lists, lists.first.entries[0])!.address, _addr(2));
    });

    test('season finale rolls into the next season', () {
      expect(nextEpisode(lists, lists.first.entries[1])!.address, _addr(3));
    });

    test('null after the last episode and for movies', () {
      expect(nextEpisode(lists, lists.first.entries[2]), isNull);
      expect(nextEpisode(lists, lists.first.entries[3]), isNull);
    });
  });

  group('continueWatching', () {
    test('partially watched files appear, most recent first', () async {
      final movie = _e('Movie.2020.mkv', 1);
      final other = _e('Other.2021.mkv', 2);
      final lists = _library([movie, other]);
      await resume(movie);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await resume(other);
      final row = await continueWatching(lists);
      expect(row.map((i) => i.entry.address).toList(),
          [_addr(2), _addr(1)]);
      expect(row.first.isNextUp, isFalse);
      expect(row.first.state, isNotNull);
    });

    test('completed movies drop out; sub-minute progress ignored', () async {
      final done = _e('Done.2020.mkv', 1);
      final barely = _e('Barely.2021.mkv', 2);
      final lists = _library([done, barely]);
      await store.markCompleted(done, duration: const Duration(minutes: 90));
      await store.record(barely,
          position: const Duration(seconds: 30),
          duration: const Duration(minutes: 90));
      expect(await continueWatching(lists), isEmpty);
    });

    test('finished episode promotes the next episode as next up', () async {
      final e1 = _e('Show.S01E01.mkv', 1);
      final e2 = _e('Show.S01E02.mkv', 2);
      final lists = _library([e1, e2]);
      await store.markCompleted(e1, duration: const Duration(minutes: 45));
      final row = await continueWatching(lists);
      expect(row, hasLength(1));
      expect(row.single.entry.address, _addr(2));
      expect(row.single.isNextUp, isTrue);
    });

    test('next-up skips episodes already watched', () async {
      final e1 = _e('Show.S01E01.mkv', 1);
      final e2 = _e('Show.S01E02.mkv', 2);
      final e3 = _e('Show.S01E03.mkv', 3);
      final lists = _library([e1, e2, e3]);
      await store.markCompleted(e2, duration: const Duration(minutes: 45));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await store.markCompleted(e1, duration: const Duration(minutes: 45));
      final row = await continueWatching(lists);
      expect(row, hasLength(1));
      expect(row.single.entry.address, _addr(3));
    });

    test('one card per show — the latest activity wins', () async {
      final e1 = _e('Show.S01E01.mkv', 1);
      final e2 = _e('Show.S01E02.mkv', 2);
      final lists = _library([e1, e2]);
      await resume(e1);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await resume(e2);
      final row = await continueWatching(lists);
      expect(row, hasLength(1));
      expect(row.single.entry.address, _addr(2));
    });

    test('a fully watched show yields nothing', () async {
      final e1 = _e('Show.S01E01.mkv', 1);
      final e2 = _e('Show.S01E02.mkv', 2);
      final lists = _library([e1, e2]);
      await store.markCompleted(e1, duration: const Duration(minutes: 45));
      await store.markCompleted(e2, duration: const Duration(minutes: 45));
      expect(await continueWatching(lists), isEmpty);
    });

    test('audio shorter than 15 min is excluded, longer audio stays',
        () async {
      final song = _e('Singer - Album (2001) - 01 Song.mp3', 1);
      final mix = _e('DJ - Sets (2002) - 01 Long Mix.mp3', 2);
      final lists = _library([song, mix]);
      await store.record(song,
          position: const Duration(minutes: 2),
          duration: const Duration(minutes: 4));
      await store.record(mix,
          position: const Duration(minutes: 20),
          duration: const Duration(minutes: 60));
      final row = await continueWatching(lists);
      expect(row.map((i) => i.entry.address), [_addr(2)]);
    });

    test('short-audio filter never touches video or unknown durations',
        () async {
      final clip = _e('Clip.2020.mkv', 1);
      final unknown = _e('Singer - Album (2001) - 02 Mystery.mp3', 2);
      final lists = _library([clip, unknown]);
      await store.record(clip,
          position: const Duration(minutes: 2),
          duration: const Duration(minutes: 10));
      await store.record(unknown,
          position: const Duration(minutes: 2), duration: Duration.zero);
      final row = await continueWatching(lists);
      expect(row.map((i) => i.entry.address).toSet(), {_addr(1), _addr(2)});
    });

    test('states for removed or hidden entries are skipped', () async {
      final visible = _e('Movie.2020.mkv', 1);
      final gone = _e('Gone.2019.mkv', 2);
      await resume(visible);
      await resume(gone);
      final hiddenLists = _library([visible], enabled: false);
      expect(await continueWatching(hiddenLists), isEmpty);
      final row = await continueWatching(_library([visible]));
      expect(row.map((i) => i.entry.address), [_addr(1)]);
    });
  });

  group('downloadedItems', () {
    test('only downloaded entries appear, in library order', () {
      final lists = _library([
        _e('Movie.2020.mkv', 1),
        _e('Other.2021.mkv', 2),
        _e('Third.2022.mkv', 3),
      ]);
      final row = downloadedItems(lists,
          isDownloaded: (e) => e.address != _addr(2));
      expect(
        [for (final item in row) (item as HomeEntry).entry.address],
        [_addr(1), _addr(3)],
      );
    });

    test('a show\'s downloaded episodes fold into one show card', () {
      final lists = _library([
        _e('Show.S01E01.mkv', 1),
        _e('Show.S01E02.mkv', 2),
        _e('Show.S02E01.mkv', 3),
        _e('Movie.2020.mkv', 4),
      ]);
      final row = downloadedItems(lists,
          isDownloaded: (e) => e.address != _addr(2));
      expect(row, hasLength(2));
      expect(row.first, isA<HomeShow>());
      expect((row.first as HomeShow).episodeCount, 2);
      expect((row.last as HomeEntry).entry.address, _addr(4));
    });

    test('empty when nothing is downloaded; hidden lists excluded', () {
      final lists = _library([_e('Movie.2020.mkv', 1)]);
      expect(downloadedItems(lists, isDownloaded: (_) => false), isEmpty);
      final hidden = _library([_e('Movie.2020.mkv', 1)], enabled: false);
      expect(downloadedItems(hidden, isDownloaded: (_) => true), isEmpty);
    });

    test('duplicate addresses across lists appear once', () {
      final lists = [
        MediaList(id: 'l1', title: 'A', entries: [_e('Movie.2020.mkv', 1)]),
        MediaList(id: 'l2', title: 'B', entries: [_e('Movie.2020.mkv', 1)]),
      ];
      expect(downloadedItems(lists, isDownloaded: (_) => true), hasLength(1));
    });
  });

  group('recentlyAdded', () {
    test('newest first, unknown add times excluded', () {
      final lists = _library([
        _e('Old.2019.mkv', 1, addedAt: 100),
        _e('Legacy.2018.mkv', 2, addedAt: 0),
        _e('New.2024.mkv', 3, addedAt: 300),
        _e('Mid.2022.mkv', 4, addedAt: 200),
      ]);
      final row = recentlyAdded(lists);
      expect(
        [for (final item in row) (item as HomeEntry).entry.address],
        [_addr(3), _addr(4), _addr(1)],
      );
    });

    test('episodes of one show fold into a single show card', () {
      final lists = _library([
        _e('Movie.2020.mkv', 1, addedAt: 100),
        _e('Show.S01E01.mkv', 2, addedAt: 300),
        _e('Show.S01E02.mkv', 3, addedAt: 200),
      ]);
      final row = recentlyAdded(lists);
      expect(row, hasLength(2));
      expect(row.first, isA<HomeShow>());
      expect((row.first as HomeShow).episodeCount, 2);
      expect((row.last as HomeEntry).entry.address, _addr(1));
    });

    test('respects the limit and hidden lists', () {
      final entries = [
        for (var i = 1; i <= 15; i++)
          _e('Movie$i.2020.mkv', i, addedAt: i),
      ];
      expect(recentlyAdded(_library(entries)), hasLength(10));
      expect(recentlyAdded(_library(entries, enabled: false)), isEmpty);
    });
  });
}
