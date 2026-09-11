import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/home_sections.dart';
import 'package:watchit/services/library_arrangement.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata.dart';
import 'package:watchit/services/metadata_service.dart';
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
}
