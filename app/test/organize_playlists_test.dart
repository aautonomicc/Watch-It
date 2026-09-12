import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' hide Row;

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/home_sections.dart';
import 'package:watchit/services/library_arrangement.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/services/my_watch_api.dart' show combinedSyncDoc;
import 'package:watchit/services/my_watch_sync.dart';
import 'package:watchit/services/organize.dart';
import 'package:watchit/services/user_metadata.dart';

/// Organizing music (renaming unsorted audio into the album convention),
/// playlists as a list kind, and rename sync (renamed_ms newest-name-
/// wins) — the 2026-09-11 music cleanup plan's service layer.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory postersDir;

  String addr(int n) => n.toRadixString(16).padLeft(64, '0');

  MediaEntry unsorted(int n, String name) =>
      MediaEntry(name: name, address: addr(n));

  MediaEntry track(int n, int number, String title) => MediaEntry(
        name: 'Neat Artist - Neat Album (2020) - '
            '${number.toString().padLeft(2, '0')} $title.mp3',
        address: addr(n),
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    MetadataService.instance = MetadataService(
      postersDirProvider: () async => postersDir,
      apiKeyProvider: () async => '',
    );
    postersDir = Directory.systemTemp.createTempSync('wi-organize');
  });

  tearDown(() {
    try {
      postersDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('unsorted audio detection', () {
    test('audio outside the track convention needs sorting; tracks, '
        'video, channels and playlists do not', () async {
      final mix = unsorted(1, 'summer megamix 2024.mp3');
      final sorted = track(2, 1, 'First');
      final video = unsorted(3, 'Home Movie (2020).mp4');
      final lists = [
        MediaList(id: 'a', title: 'Music', entries: [mix, sorted, video]),
        MediaList(
            id: 'c',
            title: 'Chan',
            channelPubkey: 'f' * 64,
            entries: [unsorted(4, 'channel mix.mp3')]),
        MediaList(
            id: 'p',
            title: 'Playlist',
            kind: kListKindPlaylist,
            entries: [mix]),
      ];
      expect(isUnsortedAudio(mix), isTrue);
      expect(isUnsortedAudio(sorted), isFalse);
      expect(isUnsortedAudio(video), isFalse);
      final found = unsortedAudioEntries(lists);
      // The mix once (playlist copy deduplicated), never the channel's.
      expect(found.map((e) => e.address), [addr(1)]);
    });
  });

  group('planOrganize / applyOrganize', () {
    test('numbers continue after the album\'s existing tracks; the new '
        'names parse into the album fold', () async {
      final existing = [track(1, 1, 'One'), track(2, 2, 'Two')];
      final loose = [
        unsorted(3, 'mystery song.mp3'),
        unsorted(4, 'other song.flac'),
      ];
      await LibraryStore.save([
        MediaList(id: 'm', title: 'Music', entries: [...existing, ...loose]),
      ]);
      final plan = await planOrganize(loose,
          artist: 'Neat Artist', album: 'Neat Album', year: 2020);
      expect(plan.error, isNull);
      expect(plan.items[0].newName,
          'Neat Artist - Neat Album (2020) - 03 mystery song.mp3');
      expect(plan.items[1].newName,
          'Neat Artist - Neat Album (2020) - 04 other song.flac');
      final n = await applyOrganize(plan.items,
          postersDirProvider: () async => postersDir);
      expect(n, 2);
      final lists = await LibraryStore.load();
      final names = [for (final e in lists.single.entries) e.name];
      expect(names,
          contains('Neat Artist - Neat Album (2020) - 03 mystery song.mp3'));
      // Renamed entries carry the rename stamp for sync.
      final renamed = lists.single.entries
          .firstWhere((e) => e.address == addr(3));
      expect(renamed.renamedAt, isNotNull);
      expect(renamed.renamedAt! > 0, isTrue);
      // Untouched entries stay unstamped.
      final untouched = lists.single.entries
          .firstWhere((e) => e.address == addr(1));
      expect(untouched.renamedAt, isNull);
    });

    test('an explicit track number already taken is refused', () async {
      await LibraryStore.save([
        MediaList(id: 'm', title: 'Music', entries: [
          track(1, 1, 'Holder'),
          unsorted(2, 'newcomer.mp3'),
        ]),
      ]);
      final plan = await planOrganize(
        [unsorted(2, 'newcomer.mp3')],
        artist: 'Neat Artist',
        album: 'Neat Album',
        year: 2020,
        tracks: [1],
      );
      expect(plan.error, contains('already taken'));
      expect(plan.items, isEmpty);
    });

    test('a user-edited display title becomes the track title; the old '
        'row\'s description and artwork migrate to the new track row',
        () async {
      final loose = unsorted(1, 'trk07_final_v2.mp3');
      await LibraryStore.save([
        MediaList(id: 'm', title: 'Music', entries: [loose]),
        MediaList(
            id: 'p',
            title: 'Mixes',
            kind: kListKindPlaylist,
            entries: [loose]),
      ]);
      // The tester's old workaround: a custom display title + details
      // on the (dead) movie: row.
      final oldKey = parseMediaName(loose.name).lookupKey;
      final poster = await saveUserPoster(
          oldKey, Uint8List.fromList([1, 2, 3]),
          postersDirProvider: () async => postersDir);
      await saveUserDetails(
        lookupKey: oldKey,
        title: 'Golden Hour',
        overview: 'A song about sunsets.',
        posterFile: Value(poster),
        postersDirProvider: () async => postersDir,
      );

      final plan = await planOrganize([loose],
          artist: 'Neat Artist', album: 'Neat Album', year: 2020);
      expect(plan.error, isNull);
      expect(plan.items.single.newName,
          'Neat Artist - Neat Album (2020) - 01 Golden Hour.mp3');
      await applyOrganize(plan.items,
          postersDirProvider: () async => postersDir);

      final lists = await LibraryStore.load();
      // The rename lands in the regular list AND the playlist row.
      for (final l in lists) {
        expect(l.entries.single.name,
            'Neat Artist - Neat Album (2020) - 01 Golden Hour.mp3');
      }
      // Old row cleared; description + artwork now on the track's row.
      expect(await metadataRowFor(oldKey), isNull);
      final newParsed =
          parseMediaName(plan.items.single.newName);
      final trackRow = await metadataRowFor(trackLookupKey(newParsed)!);
      expect(trackRow, isNotNull);
      expect(trackRow!.overview, 'A song about sunsets.');
      expect(trackRow.posterFile, isNotNull);
      expect(
          File('${postersDir.path}/${trackRow.posterFile}').existsSync(),
          isTrue);
    });
  });

  group('playlists', () {
    test('createPlaylist + addTracksToPlaylist dedup by address',
        () async {
      await LibraryStore.save([
        MediaList(id: 'm', title: 'Music', entries: [track(1, 1, 'One')]),
      ]);
      final playlist = await createPlaylist('Good Energy');
      expect(playlist.isPlaylist, isTrue);
      expect(
          await addTracksToPlaylist(
              playlist.id, [track(1, 1, 'One'), track(2, 2, 'Two')]),
          2);
      // Same addresses again: nothing added.
      expect(
          await addTracksToPlaylist(playlist.id, [track(1, 1, 'One')]), 0);
      final lists = await LibraryStore.load();
      final saved = lists.firstWhere((l) => l.id == playlist.id);
      expect(saved.kind, kListKindPlaylist);
      expect(saved.entries.length, 2);
      // A vanished playlist reports -1.
      expect(await addTracksToPlaylist('nope', [track(3, 3, 'T')]), -1);
    });

    test('playlists never become home rows or drawer Library lists',
        () {
      final lists = [
        MediaList(id: 'm', title: 'Music', entries: [track(1, 1, 'One')]),
        MediaList(
            id: 'p',
            title: 'Good Energy',
            kind: kListKindPlaylist,
            entries: [track(1, 1, 'One')]),
      ];
      final sections = reconcileHomeSections(const [], lists);
      expect(
          sections.map((s) => s.id), isNot(contains(listSectionId('p'))));
      // Even a stale stored blob naming the playlist drops it.
      final stored = [HomeSection(id: listSectionId('p'))];
      expect(reconcileHomeSections(stored, lists).map((s) => s.id),
          isNot(contains(listSectionId('p'))));
      expect(browsableLists(lists).map((l) => l.id), ['m']);
    });

    test('addEntriesToLists never merges into a playlist by title',
        () async {
      await LibraryStore.save([
        MediaList(
            id: 'p',
            title: 'Faves',
            kind: kListKindPlaylist,
            entries: const []),
      ]);
      await addEntriesToLists([track(1, 1, 'One')], ['Faves']);
      final lists = await LibraryStore.load();
      final playlist = lists.firstWhere((l) => l.id == 'p');
      expect(playlist.entries, isEmpty);
      // A NEW plain list was created beside it instead.
      final created = lists.firstWhere((l) => l.id != 'p');
      expect(created.title, 'Faves');
      expect(created.isPlaylist, isFalse);
      expect(created.entries.single.address, addr(1));
    });
  });

  group('rename sync', () {
    Map<String, dynamic> docWith(List<Map<String, dynamic>> entries,
            {String? kind}) =>
        {
          'v': 1,
          'updated_ms': 1,
          'lists': [
            {
              'title': 'Music',
              'kind': ?kind,
              'entries': entries,
            },
          ],
        };

    test('buildDoc: renamed_ms only on stamped entries; playlists carry '
        'their kind', () {
      final doc = MyWatchSync.buildDoc(
        lists: [
          MediaList(id: 'm', title: 'Music', entries: [
            MediaEntry(
                name: 'A - B (2020) - 01 T.mp3',
                address: addr(1),
                addedAt: 5,
                renamedAt: 99),
            MediaEntry(name: 'Plain.mp3', address: addr(2), addedAt: 5),
          ]),
          MediaList(
              id: 'p',
              title: 'Faves',
              kind: kListKindPlaylist,
              entries: const []),
        ],
        tombstones: const {},
        watchStates: const [],
        nowMs: 10,
      );
      final lists = doc['lists'] as List;
      final music = lists[0] as Map<String, dynamic>;
      final entries = music['entries'] as List;
      expect((entries[0] as Map)['renamed_ms'], 99);
      expect((entries[1] as Map).containsKey('renamed_ms'), isFalse);
      expect(music.containsKey('kind'), isFalse);
      expect((lists[1] as Map)['kind'], 'playlist');
    });

    test('a remote rename with a newer stamp lands on a held entry; an '
        'older or unstamped one never does', () {
      final local = MediaList(id: 'm', title: 'Music', entries: [
        MediaEntry(
            name: 'Old Name.mp3',
            address: addr(1),
            addedAt: 5,
            renamedAt: 50),
      ]);
      // Newer remote rename wins.
      var merge = MyWatchSync.mergeRemoteDocs(
        lists: [local],
        tombstones: const {},
        remoteDocs: [
          docWith([
            {
              'name': 'A - B (2020) - 01 New.mp3',
              'address': addr(1),
              'added_ms': 5,
              'renamed_ms': 60,
            },
          ]),
        ],
      );
      expect(merge.changed, isTrue);
      expect(merge.entriesRenamed, 1);
      final entry = merge.lists.single.entries.single;
      expect(entry.name, 'A - B (2020) - 01 New.mp3');
      expect(entry.renamedAt, 60);

      // Older stamp: ignored.
      merge = MyWatchSync.mergeRemoteDocs(
        lists: [local],
        tombstones: const {},
        remoteDocs: [
          docWith([
            {
              'name': 'Stale.mp3',
              'address': addr(1),
              'added_ms': 5,
              'renamed_ms': 40,
            },
          ]),
        ],
      );
      expect(merge.entriesRenamed, 0);
      expect(merge.lists.single.entries.single.name, 'Old Name.mp3');

      // No stamp at all (old build / never renamed): ignored.
      merge = MyWatchSync.mergeRemoteDocs(
        lists: [local],
        tombstones: const {},
        remoteDocs: [
          docWith([
            {'name': 'Unstamped.mp3', 'address': addr(1), 'added_ms': 5},
          ]),
        ],
      );
      expect(merge.changed, isFalse);
      expect(merge.lists.single.entries.single.name, 'Old Name.mp3');
    });

    test('identical stamps tie-break on name bytes — both devices '
        'converge on one name', () {
      MediaList held(String name) =>
          MediaList(id: 'm', title: 'Music', entries: [
            MediaEntry(
                name: name, address: addr(1), addedAt: 5, renamedAt: 70),
          ]);
      Map<String, dynamic> remote(String name) => docWith([
            {
              'name': name,
              'address': addr(1),
              'added_ms': 5,
              'renamed_ms': 70,
            },
          ]);
      // Device A holds "Alpha", sees B's "Beta" (larger) → adopts.
      final a = MyWatchSync.mergeRemoteDocs(
          lists: [held('Alpha.mp3')],
          tombstones: const {},
          remoteDocs: [remote('Beta.mp3')]);
      expect(a.lists.single.entries.single.name, 'Beta.mp3');
      // Device B holds "Beta", sees A's "Alpha" (smaller) → keeps.
      final b = MyWatchSync.mergeRemoteDocs(
          lists: [held('Beta.mp3')],
          tombstones: const {},
          remoteDocs: [remote('Alpha.mp3')]);
      expect(b.lists.single.entries.single.name, 'Beta.mp3');
    });

    test('a remote playlist arrives as a playlist (and stays off the '
        'wall)', () {
      final merge = MyWatchSync.mergeRemoteDocs(
        lists: const [],
        tombstones: const {},
        remoteDocs: [
          {
            'v': 1,
            'updated_ms': 1,
            'lists': [
              {
                'title': 'Good Energy',
                'kind': 'playlist',
                'entries': [
                  {
                    'name': 'A - B (2020) - 01 T.mp3',
                    'address': addr(1),
                    'added_ms': 5,
                    'renamed_ms': 9,
                  },
                ],
              },
            ],
          },
        ],
      );
      final created = merge.lists.single;
      expect(created.isPlaylist, isTrue);
      expect(created.entries.single.renamedAt, 9);
      expect(reconcileHomeSections(const [], merge.lists), hasLength(4));
    });
  });

  group('order sync', () {
    MediaEntry plain(int n) =>
        MediaEntry(name: 'T$n.mp3', address: addr(n), addedAt: 5);

    Map<String, dynamic> orderDoc(int orderMs, Map<int, int> posByN,
            {String title = 'Faves'}) =>
        {
          'v': 1,
          'updated_ms': 1,
          'lists': [
            {
              'title': title,
              'kind': kListKindPlaylist,
              'order_ms': orderMs,
              'entries': [
                for (final e in posByN.entries)
                  {
                    'name': 'T${e.key}.mp3',
                    'address': addr(e.key),
                    'added_ms': 5,
                    'pos': e.value,
                  },
              ],
            },
          ],
        };

    test('buildDoc: a reordered playlist carries order_ms + per-entry '
        'pos (full-playlist indices, surviving a trimmed window); '
        'unstamped playlists and plain lists carry neither', () {
      final faves = MediaList(
          id: 'p',
          title: 'Faves',
          kind: kListKindPlaylist,
          orderedAt: 77,
          entries: [plain(1), plain(2), plain(3)]);
      final doc = MyWatchSync.buildDoc(
        lists: [
          faves,
          // A plain list never emits order keys, reorder stamp or not.
          MediaList(id: 'm', title: 'Music', orderedAt: 88, entries: [
            plain(8),
          ]),
          MediaList(
              id: 'q',
              title: 'Quiet',
              kind: kListKindPlaylist,
              entries: [plain(9)]),
        ],
        tombstones: const {},
        watchStates: const [],
        nowMs: 10,
      );
      final lists = doc['lists'] as List;
      final favesDoc = lists[0] as Map<String, dynamic>;
      expect(favesDoc['order_ms'], 77);
      expect(
          [for (final e in favesDoc['entries'] as List) (e as Map)['pos']],
          [0, 1, 2]);
      final musicDoc = lists[1] as Map<String, dynamic>;
      expect(musicDoc.containsKey('order_ms'), isFalse);
      expect(
          (musicDoc['entries'] as List).single, isNot(contains('pos')));
      expect((lists[2] as Map).containsKey('order_ms'), isFalse);

      // A rotation window keeps the FULL-playlist indices: cap 2 at
      // offset 1 ships T2/T3 still marked pos 1/2.
      final windowed = MyWatchSync.buildDoc(
        lists: [faves],
        tombstones: const {},
        watchStates: const [],
        nowMs: 10,
        entryCap: 2,
        entryOffset: 1,
      );
      final w = (windowed['lists'] as List)[0] as Map<String, dynamic>;
      expect(
          [for (final e in w['entries'] as List) (e as Map)['pos']], [1, 2]);
    });

    test('a remote order with a newer stamp reorders the held playlist; '
        'an older one never does', () {
      final local = MediaList(
          id: 'p',
          title: 'Faves',
          kind: kListKindPlaylist,
          entries: [plain(1), plain(2), plain(3)]);
      var merge = MyWatchSync.mergeRemoteDocs(
        lists: [local],
        tombstones: const {},
        remoteDocs: [
          orderDoc(50, {3: 0, 1: 1, 2: 2}),
        ],
      );
      expect(merge.changed, isTrue);
      expect(merge.listsReordered, 1);
      expect([for (final e in merge.lists.single.entries) e.address],
          [addr(3), addr(1), addr(2)]);
      expect(merge.lists.single.orderedAt, 50);

      // Local reorder is newer: the remote order is ignored.
      merge = MyWatchSync.mergeRemoteDocs(
        lists: [local.copyWith(orderedAt: 60)],
        tombstones: const {},
        remoteDocs: [
          orderDoc(50, {3: 0, 1: 1, 2: 2}),
        ],
      );
      expect(merge.changed, isFalse);
      expect(merge.listsReordered, 0);
      expect([for (final e in merge.lists.single.entries) e.address],
          [addr(1), addr(2), addr(3)]);
    });

    test('identical stamps tie-break on the ordered address bytes — '
        'both devices converge on one order', () {
      MediaList held(List<int> order) => MediaList(
          id: 'p',
          title: 'Faves',
          kind: kListKindPlaylist,
          orderedAt: 70,
          entries: [for (final n in order) plain(n)]);
      // Device A holds [1,2]; B's [2,1] joins to the larger key → adopts.
      final a = MyWatchSync.mergeRemoteDocs(
          lists: [held([1, 2])],
          tombstones: const {},
          remoteDocs: [orderDoc(70, {2: 0, 1: 1})]);
      expect([for (final e in a.lists.single.entries) e.address],
          [addr(2), addr(1)]);
      // Device B holds [2,1]; A's [1,2] joins smaller → keeps its own.
      final b = MyWatchSync.mergeRemoteDocs(
          lists: [held([2, 1])],
          tombstones: const {},
          remoteDocs: [orderDoc(70, {1: 0, 2: 1})]);
      expect([for (final e in b.lists.single.entries) e.address],
          [addr(2), addr(1)]);
    });

    test('a partial remote doc orders the entries it mentions (new ones '
        'included); unmentioned entries keep their relative order after '
        'them', () {
      final local = MediaList(
          id: 'p',
          title: 'Faves',
          kind: kListKindPlaylist,
          entries: [plain(1), plain(2), plain(3)]);
      // addr(4) is new here — it lands via the membership merge, then
      // the order pass slots it by pos.
      final merge = MyWatchSync.mergeRemoteDocs(
        lists: [local],
        tombstones: const {},
        remoteDocs: [
          orderDoc(50, {4: 0, 2: 1}),
        ],
      );
      expect(merge.entriesAdded, 1);
      expect(merge.listsReordered, 1);
      expect([for (final e in merge.lists.single.entries) e.address],
          [addr(4), addr(2), addr(1), addr(3)]);
      expect(merge.lists.single.orderedAt, 50);
    });

    test('a plain list never adopts remote order keys', () {
      final local = MediaList(
          id: 'm', title: 'Faves', entries: [plain(1), plain(2)]);
      final doc = orderDoc(50, {2: 0, 1: 1});
      ((doc['lists'] as List)[0] as Map).remove('kind');
      final merge = MyWatchSync.mergeRemoteDocs(
          lists: [local], tombstones: const {}, remoteDocs: [doc]);
      expect(merge.listsReordered, 0);
      expect([for (final e in merge.lists.single.entries) e.address],
          [addr(1), addr(2)]);
    });

    test('combinedSyncDoc folds order_ms across parts (newest wins)',
        () {
      final main = orderDoc(50, {1: 0});
      final part = orderDoc(60, {2: 1});
      final folded = combinedSyncDoc(main, [part]);
      final list = (folded['lists'] as List).single as Map<String, dynamic>;
      expect(list['order_ms'], 60);
      expect((list['entries'] as List), hasLength(2));
    });

    test('v14 → v15 migration adds the order stamp to existing lists',
        () async {
      final dir = Directory.systemTemp.createTempSync('wi-order-mig');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/watchit.sqlite');
      // Hand-build the alpha.97-era (schema v14) list tables.
      final raw = sqlite3.open(file.path);
      raw.execute('''
        CREATE TABLE media_lists (
          id TEXT NOT NULL,
          title TEXT NOT NULL,
          position INTEGER NOT NULL,
          enabled INTEGER NOT NULL DEFAULT 1,
          channel_pubkey TEXT,
          channel_author TEXT,
          channel_avatar TEXT,
          kind TEXT,
          PRIMARY KEY (id));
        CREATE TABLE media_entries (
          entry_id INTEGER PRIMARY KEY AUTOINCREMENT,
          list_id TEXT NOT NULL,
          name TEXT NOT NULL,
          address TEXT NOT NULL,
          position INTEGER NOT NULL,
          added_at INTEGER NOT NULL DEFAULT 0,
          size_bytes INTEGER,
          video_info TEXT,
          renamed_at INTEGER NOT NULL DEFAULT 0);
        INSERT INTO media_lists
          VALUES ('p', 'Faves', 0, 1, NULL, NULL, NULL, 'playlist');
        PRAGMA user_version = 14;
      ''');
      raw.close();
      await LibraryStore.useForTesting(
          AppDatabase.forTesting(NativeDatabase(file)));
      final loaded = await LibraryStore.load();
      expect(loaded.single.isPlaylist, isTrue);
      expect(loaded.single.orderedAt, isNull);
      await LibraryStore.save([loaded.single.copyWith(orderedAt: 5)]);
      expect((await LibraryStore.load()).single.orderedAt, 5);
    });

    test('orderedAt round-trips through the store', () async {
      await LibraryStore.save([
        MediaList(
            id: 'p',
            title: 'Faves',
            kind: kListKindPlaylist,
            orderedAt: 123,
            entries: [plain(1)]),
        MediaList(id: 'm', title: 'Music', entries: [plain(2)]),
      ]);
      final loaded = await LibraryStore.load();
      expect(loaded[0].orderedAt, 123);
      expect(loaded[1].orderedAt, isNull);
    });
  });

  group('planUnalbum / applyUnalbum (remove from album)', () {
    test('track renames to plain Title.ext everywhere (playlist rows '
        'included), custom title made real, per-track artist/artwork '
        'migrate to the standalone key, album shared row untouched',
        () async {
      final leaving = track(1, 2, 'Wrong Name');
      final staying = track(2, 1, 'One');
      await LibraryStore.save([
        MediaList(id: 'm', title: 'Music', entries: [staying, leaving]),
        MediaList(
            id: 'p',
            title: 'Faves',
            kind: kListKindPlaylist,
            entries: [leaving]),
      ]);
      // Per-track override row: custom display title + artist + art.
      final parsed = parseMediaName(leaving.name);
      final trackKey = trackLookupKey(parsed)!;
      final poster = await saveUserPoster(
          trackKey, Uint8List.fromList([9, 9, 9]),
          postersDirProvider: () async => postersDir);
      await saveUserDetails(
        lookupKey: trackKey,
        title: parsed.title,
        episodeLabel: const Value('02 · Right Name'),
        artist: const Value('Solo Singer'),
        posterFile: Value(poster),
        postersDirProvider: () async => postersDir,
      );
      // The album's shared row (description) must survive for the
      // track staying behind.
      final albumKey = albumLookupKey(parsed)!;
      await saveUserDetails(
        lookupKey: albumKey,
        title: parsed.title,
        overview: 'Album blurb.',
        postersDirProvider: () async => postersDir,
      );

      final plan = await planUnalbum([leaving]);
      expect(plan.error, isNull);
      expect(plan.items.single.newName, 'Right Name.mp3');
      final n = await applyUnalbum(plan.items,
          postersDirProvider: () async => postersDir);
      expect(n, 2); // regular list + playlist row
      final lists = await LibraryStore.load();
      final music = lists.firstWhere((l) => l.id == 'm');
      expect(music.entries.map((e) => e.name),
          containsAll([staying.name, 'Right Name.mp3']));
      final faves = lists.firstWhere((l) => l.id == 'p');
      expect(faves.entries.single.name, 'Right Name.mp3');
      expect(faves.entries.single.renamedAt, isNotNull);
      // Old per-track row cleared, standalone row carries artist + art.
      expect(await metadataRowFor(trackKey), isNull);
      final newRow = await metadataRowFor(
          parseMediaName('Right Name.mp3').lookupKey);
      expect(newRow, isNotNull);
      expect(newRow!.artist, 'Solo Singer');
      expect(newRow.posterFile, isNotNull);
      expect(File('${postersDir.path}/${newRow.posterFile}').existsSync(),
          isTrue);
      // Album shared row untouched.
      expect((await metadataRowFor(albumKey))?.overview, 'Album blurb.');
      // The removed file is now unsorted audio.
      expect(unsortedAudioEntries(lists).single.name, 'Right Name.mp3');
    });

    test('non-track selection refuses', () async {
      final plan = await planUnalbum([unsorted(1, 'loose.mp3')]);
      expect(plan.error, contains('not an album track'));
    });
  });

  group('renumberAlbumTracks (Edit tracks reorder / gap close)', () {
    test('a swap the one-at-a-time renumber refuses just works, and '
        'per-track rows swap without clobbering each other', () async {
      final one = track(1, 1, 'First');
      final two = track(2, 2, 'Second');
      await LibraryStore.save([
        MediaList(id: 'm', title: 'Music', entries: [one, two]),
      ]);
      // Both tracks carry per-track custom titles — the swap must not
      // let one row overwrite the other mid-migration.
      for (final (e, label) in [(one, '01 · Custom A'), (two, '02 · Custom B')]) {
        await saveUserDetails(
          lookupKey: trackLookupKey(parseMediaName(e.name))!,
          title: 'Neat Album',
          episodeLabel: Value(label),
          postersDirProvider: () async => postersDir,
        );
      }
      // New order: two first, one second → 2↔1 swap.
      final error = await renumberAlbumTracks([two, one],
          postersDirProvider: () async => postersDir);
      expect(error, isNull);
      final entries = (await LibraryStore.load()).single.entries;
      expect(entries.map((e) => e.name).toSet(), {
        'Neat Artist - Neat Album (2020) - 02 First.mp3',
        'Neat Artist - Neat Album (2020) - 01 Second.mp3',
      });
      // Rows followed their tracks (with re-marked labels).
      final rowA = await metadataRowFor(trackLookupKey(
          parseMediaName('Neat Artist - Neat Album (2020) - 02 First.mp3'))!);
      expect(rowA?.episodeLabel, '02 · Custom A');
      final rowB = await metadataRowFor(trackLookupKey(
          parseMediaName('Neat Artist - Neat Album (2020) - 01 Second.mp3'))!);
      expect(rowB?.episodeLabel, '01 · Custom B');
    });

    test('gap close renumbers 1..N in the given order; no-op when '
        'already 1..N', () async {
      final five = track(1, 5, 'Alpha');
      final nine = track(2, 9, 'Beta');
      await LibraryStore.save([
        MediaList(id: 'm', title: 'Music', entries: [five, nine]),
      ]);
      expect(await renumberAlbumTracks([five, nine]), isNull);
      final entries = (await LibraryStore.load()).single.entries;
      expect(entries.map((e) => e.name).toSet(), {
        'Neat Artist - Neat Album (2020) - 01 Alpha.mp3',
        'Neat Artist - Neat Album (2020) - 02 Beta.mp3',
      });
      // Already 1..N: nothing renamed (no fresh rename stamps).
      final before = [
        for (final e in (await LibraryStore.load()).single.entries) e,
      ];
      before.sort((a, b) => a.name.compareTo(b.name));
      expect(await renumberAlbumTracks(before), isNull);
      final after = (await LibraryStore.load()).single.entries.toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      for (final (i, e) in after.indexed) {
        expect(e.name, before[i].name);
      }
    });

    test('multi-disc albums are refused', () async {
      final disc = MediaEntry(
          name: 'A - B (2000) - 2-01 Song.mp3', address: addr(1));
      await LibraryStore.save([
        MediaList(id: 'm', title: 'Music', entries: [disc]),
      ]);
      expect(await renumberAlbumTracks([disc]),
          contains('Multi-disc'));
    });
  });
}
