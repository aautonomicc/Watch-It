import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/services/my_watch_api.dart';
import 'package:watchit/services/my_watch_sync.dart';
import 'package:watchit/services/user_metadata.dart';
import 'package:watchit/services/watch_state.dart';

import 'fake_embedded_http.dart';

String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

RemoteSyncDoc _docWithTmdb(
  String agent,
  Map<String, dynamic> tmdb, {
  List<String>? have,
}) =>
    RemoteSyncDoc(agentId: agent, doc: {
      'v': 1,
      'lists': const [],
      'have': ?have,
      'tmdb': tmdb,
    }, maps: const {});

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('metaKeyHash', () {
    test('is 8 hex chars, stable, and key-dependent', () {
      final a = MyWatchSync.metaKeyHash('movie:custom:2020');
      expect(a, matches(RegExp(r'^[0-9a-f]{8}$')));
      expect(MyWatchSync.metaKeyHash('movie:custom:2020'), a);
      expect(MyWatchSync.metaKeyHash('movie:other:2020'), isNot(a));
    });
  });

  group('artRetryDelayMs', () {
    test('doubles from 1 minute to the 10-minute cap', () {
      expect(MyWatchSync.artRetryDelayMs(1), 60000);
      expect(MyWatchSync.artRetryDelayMs(2), 120000);
      expect(MyWatchSync.artRetryDelayMs(3), 240000);
      expect(MyWatchSync.artRetryDelayMs(4), 480000);
      expect(MyWatchSync.artRetryDelayMs(5), MyWatchSync.mapRetryMs);
      expect(MyWatchSync.artRetryDelayMs(50), MyWatchSync.mapRetryMs);
    });
  });

  group('safeArtFileName', () {
    test('accepts TMDB and user names, rejects anything path-like', () {
      expect(MyWatchSync.safeArtFileName('movie_42.jpg'), isTrue);
      expect(MyWatchSync.safeArtFileName('tv_9_s1e2_still.jpg'), isTrue);
      expect(MyWatchSync.safeArtFileName('user_key_ab12_5.jpg'), isTrue);
      expect(MyWatchSync.safeArtFileName(''), isFalse);
      expect(MyWatchSync.safeArtFileName('../evil.jpg'), isFalse);
      expect(MyWatchSync.safeArtFileName('a/b.jpg'), isFalse);
      expect(MyWatchSync.safeArtFileName('.hidden'), isFalse);
      expect(MyWatchSync.safeArtFileName('a..b.jpg'), isFalse);
    });
  });

  group('libraryLookupKeys', () {
    test('parses entry names into lookup keys', () {
      final keys = MyWatchSync.libraryLookupKeys([
        MediaList(id: 'a', title: 'Movies', entries: [
          MediaEntry(name: 'Custom (2020).mp4', address: _addr(1)),
          MediaEntry(name: 'Show S01E02.mkv', address: _addr(2)),
        ]),
      ]);
      expect(keys, {'movie:custom:2020', 'tv:show::s1:e2'});
    });
  });

  group('buildDoc have/tmdb', () {
    test('have always publishes; tmdb only when a section exists', () {
      final without = MyWatchSync.buildDoc(
        lists: const [],
        tombstones: const {},
        watchStates: const [],
        nowMs: 1,
      );
      expect(without['have'], isEmpty);
      expect(without.containsKey('tmdb'), isFalse);
      final with_ = MyWatchSync.buildDoc(
        lists: const [],
        tombstones: const {},
        watchStates: const [],
        nowMs: 1,
        haveHashes: const ['aabbccdd'],
        tmdbSection: {
          'v': 1,
          'rows': [
            {'key': 'k', 'updated_ms': 5},
          ],
        },
      );
      expect(with_['have'], ['aabbccdd']);
      expect(((with_['tmdb'] as Map)['rows'] as List), hasLength(1));
    });
  });

  group('shrunkenTmdbSection', () {
    Map<String, dynamic> section() => {
          'v': 1,
          'rows': [
            for (var i = 0; i < 8; i++)
              {
                'key': 'tv:show $i:2000:s1:e1',
                'updated_ms': 100 - i,
                'poster': 'tv_${i}_s1.jpg',
                'still': 'tv_${i}_s1e1_still.jpg',
              },
          ],
          'shows': {
            for (var i = 0; i < 8; i++)
              'tv:show $i:2000': {'overview': 'show $i', 'poster': 'tv_$i.jpg'},
          },
          'seasons': {
            for (var i = 0; i < 8; i++)
              'tv:show $i:2000:s1': {'overview': 'season $i'},
          },
          'files': {
            for (var i = 0; i < 8; i++) ...{
              'tv_${i}_s1.jpg': {'sha256': 'aa' * 32, 'size': 1},
              'tv_${i}_s1e1_still.jpg': {'sha256': 'bb' * 32, 'size': 2},
              'tv_$i.jpg': {'sha256': 'cc' * 32, 'size': 3},
            },
          },
        };

    test('drops the tail quarter and prunes shared texts and manifests', () {
      final out = MyWatchSync.shrunkenTmdbSection(section())!;
      final rows = out['rows'] as List;
      expect(rows, hasLength(6));
      // The kept head still has everything it references...
      expect((out['shows'] as Map).keys,
          [for (var i = 0; i < 6; i++) 'tv:show $i:2000']);
      expect((out['seasons'] as Map), hasLength(6));
      expect((out['files'] as Map).containsKey('tv_5_s1.jpg'), isTrue);
      // ...and the dropped tail's references are gone.
      expect((out['files'] as Map).containsKey('tv_7_s1.jpg'), isFalse);
      expect((out['shows'] as Map).containsKey('tv:show 7:2000'), isFalse);
    });

    test('shrinks to null once no row is left', () {
      Map<String, dynamic>? s = section();
      var guard = 0;
      while (s != null && guard++ < 20) {
        s = MyWatchSync.shrunkenTmdbSection(s);
      }
      expect(s, isNull);
      expect(guard, lessThan(20));
    });
  });

  group('buildDocWithinBudget priority', () {
    List<WatchState> states(int n) => [
          for (var i = 0; i < n; i++)
            WatchState(
              address: _addr(1000 + i),
              positionMs: 600000,
              durationMs: 1200000,
              completed: false,
              updatedAt: 999999 - i,
            ),
        ];

    Map<String, dynamic> fatTmdb(int n) => {
          'v': 1,
          'rows': [
            for (var i = 0; i < n; i++)
              {
                'key': 'movie:title $i:2020',
                'updated_ms': 5000 - i,
                'title': 'Title $i',
                'overview': 't' * 1500,
              },
          ],
        };

    List<Map<String, dynamic>> metaRows(int n) => [
          for (var i = 0; i < n; i++)
            {
              'key': 'movie:edit $i:2020',
              'updated_ms': 5000 - i,
              'title': 'Edited title $i',
              'overview': 'd' * 1500,
            },
        ];

    test('watch states drop before the tmdb section', () {
      final built = MyWatchSync.buildDocWithinBudget(
        lists: const [],
        tombstones: const {},
        watchStates: states(MyWatchSync.maxDocWatchStates),
        nowMs: 1,
        tmdbSection: fatTmdb(20),
      );
      expect(built.tmdbDropped, 0);
      expect(built.watchDropped, greaterThan(0));
      expect(((built.doc['tmdb'] as Map)['rows'] as List), hasLength(20));
    });

    test('the tmdb section shrinks before any user edit drops', () {
      final built = MyWatchSync.buildDocWithinBudget(
        lists: const [],
        tombstones: const {},
        watchStates: const [],
        nowMs: 1,
        metaRows: metaRows(10),
        tmdbSection: fatTmdb(40), // ~60 KB of overviews alone
      );
      expect(built.metaDropped, 0);
      expect(built.tmdbDropped, greaterThan(0));
      expect(((built.doc['meta'] as Map)['rows'] as List), hasLength(10));
      // Newest matches stay at the head.
      final rows = (built.doc['tmdb'] as Map)['rows'] as List;
      expect((rows.first as Map)['key'], 'movie:title 0:2020');
    });

    test('a tmdb section too big even alone drains to nothing gracefully',
        () {
      final built = MyWatchSync.buildDocWithinBudget(
        lists: const [],
        tombstones: const {},
        watchStates: const [],
        nowMs: 1,
        tmdbSection: fatTmdb(60),
      );
      expect(built.tmdbDropped, greaterThan(0));
      expect(jsonEncode(built.doc).length,
          lessThanOrEqualTo(MyWatchSync.maxDocBytes));
    });
  });

  group('remoteTmdbWinners', () {
    test('newest row per key wins; show/season texts resolve by prefix', () {
      final winners = MyWatchSync.remoteTmdbWinners([
        _docWithTmdb('aa' * 32, {
          'v': 1,
          'rows': [
            {
              'key': 'tv:beyond:1959:s1:e2',
              'updated_ms': 100,
              'title': 'One Step Beyond',
              'episode': 'S01E02 · Night of April 14th',
              'type': 'tv',
              'tmdb_id': 9,
              'rating': 7.1,
              'poster': 'tv_9_s1.jpg',
              'still': 'tv_9_s1e2_still.jpg',
            },
            {'key': '', 'updated_ms': 5},
            {'key': 'no-stamp'},
          ],
          'shows': {
            'tv:beyond:1959': {'overview': 'Anthology.', 'poster': 'tv_9.jpg'},
          },
          'seasons': {
            'tv:beyond:1959:s1': {'overview': 'Season one.'},
          },
        }),
        _docWithTmdb('bb' * 32, {
          'v': 1,
          'rows': [
            {
              'key': 'tv:beyond:1959:s1:e2',
              'updated_ms': 200,
              'title': 'Newer',
              'poster': '../evil.jpg',
            },
          ],
        }),
      ]);
      final w = winners.singleWhere((w) => w.key == 'tv:beyond:1959:s1:e2');
      expect(w.title, 'Newer');
      expect(w.agentId, 'bb' * 32);
      // The unsafe poster name from the winning row is dropped, not saved.
      expect(w.posterFile, isNull);
      expect(winners, hasLength(1));
    });

    test('an episode row inherits its show and season extras', () {
      final winners = MyWatchSync.remoteTmdbWinners([
        _docWithTmdb('aa' * 32, {
          'v': 1,
          'rows': [
            {
              'key': 'tv:beyond:1959:s1:e2',
              'updated_ms': 100,
              'title': 'One Step Beyond',
              'poster': 'tv_9_s1.jpg',
            },
          ],
          'shows': {
            'tv:beyond:1959': {'overview': 'Anthology.', 'poster': 'tv_9.jpg'},
          },
          'seasons': {
            'tv:beyond:1959:s1': {'overview': 'Season one.'},
          },
        }),
      ]);
      final w = winners.single;
      expect(w.showOverview, 'Anthology.');
      expect(w.showPosterFile, 'tv_9.jpg');
      expect(w.seasonOverview, 'Season one.');
      expect(w.posterFile, 'tv_9_s1.jpg');
    });
  });

  group('remoteTmdbFiles', () {
    test('collects owners per file; a hash mismatch is not an owner', () {
      final files = MyWatchSync.remoteTmdbFiles([
        _docWithTmdb('aa' * 32, {
          'v': 1,
          'rows': const [],
          'files': {
            'movie_1.jpg': {'sha256': 'ab' * 32, 'size': 10},
            '../evil.jpg': {'sha256': 'ab' * 32, 'size': 10},
            'bad_sha.jpg': {'sha256': 'nope', 'size': 10},
          },
        }),
        _docWithTmdb('bb' * 32, {
          'v': 1,
          'rows': const [],
          'files': {
            'movie_1.jpg': {'sha256': 'cd' * 32, 'size': 10},
            'movie_2.jpg': {'sha256': 'ef' * 32, 'size': 20},
          },
        }),
        _docWithTmdb('cc' * 32, {
          'v': 1,
          'rows': const [],
          'files': {
            'movie_1.jpg': {'sha256': 'AB' * 32, 'size': 10},
          },
        }),
      ]);
      expect(files.keys, unorderedEquals(['movie_1.jpg', 'movie_2.jpg']));
      expect(files['movie_1.jpg']!.owners, ['aa' * 32, 'cc' * 32]);
      expect(files['movie_2.jpg']!.owners, ['bb' * 32]);
    });
  });

  group('full cycle', () {
    late FakeEmbeddedHttp fake;
    late Directory tempDir;
    late MyWatchSync sync;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await LibraryStore.useForTesting(
          AppDatabase.forTesting(NativeDatabase.memory()));
      WatchStateStore.instance = WatchStateStore();
      tempDir = Directory.systemTemp.createTempSync('wi-tmdb-cycle');
      Directory('${tempDir.path}/posters').createSync();
      MyWatchSync.statePathOverride = '${tempDir.path}/sync_state.json';
      MyWatchSync.postersDirOverride =
          () async => Directory('${tempDir.path}/posters');
      MetadataService.instance = MetadataService(
        postersDirProvider: () async => Directory('${tempDir.path}/posters'),
        apiKeyProvider: () async => '',
        httpClient: MockClient((req) async => http.Response('{}', 404)),
      );
      MyWatchSync.status.value = const MyWatchSyncStatus();
      fake = FakeEmbeddedHttp();
      HttpOverrides.global = fake;
      fake.myWatchStatus = {
        'supported': true,
        'linked': true,
        'state': 'ready',
        'agent_id': 'aa' * 32,
        'last_sync_ms': 0,
        'devices': [
          {
            'agent_id': 'aa' * 32,
            'self': true,
            'name': 'here',
            'platform': 'linux',
            'online': true,
          },
          {
            'agent_id': 'bb' * 32,
            'self': false,
            'name': 'desktop',
            'platform': 'linux',
            'online': true,
          },
        ],
      };
      sync = MyWatchSync(
          api: MyWatchApi(base: FakeEmbeddedHttp.base, token: 't'));
    });

    tearDown(() {
      HttpOverrides.global = null;
      MyWatchSync.statePathOverride = null;
      MyWatchSync.postersDirOverride = null;
      tempDir.deleteSync(recursive: true);
    });

    Future<void> seedLibrary(String name, String addr) async {
      await LibraryStore.save([
        MediaList(id: 'l1', title: 'Movies', entries: [
          MediaEntry(name: name, address: addr, addedAt: 100),
        ]),
      ]);
    }

    test('a keyless device adopts a remote TMDB row and pulls the poster '
        'under its original name', () async {
      await seedLibrary('Custom (2020).mp4', _addr(1));
      final artBytes = List<int>.generate(60000, (i) => (i * 3) % 251);
      final sha = crypto.sha256.convert(artBytes).toString();
      final served = File('${tempDir.path}/served_poster')
        ..writeAsBytesSync(artBytes);
      fake.myWatchArtFiles = {sha: served.path};
      fake.myWatchSyncDevices = [
        {
          'agent_id': 'bb' * 32,
          'doc': {
            'v': 1,
            'lists': const [],
            'have': const <String>[],
            'tmdb': {
              'v': 1,
              'rows': [
                {
                  'key': 'movie:custom:2020',
                  'updated_ms': 4242,
                  'title': 'Custom, Matched',
                  'year': 2020,
                  'overview': 'A film TMDB knows.',
                  'category': 'Drama',
                  'type': 'movie',
                  'tmdb_id': 77,
                  'rating': 7.5,
                  'air_date': '2020-02-02',
                  'poster': 'movie_77.jpg',
                },
              ],
              'files': {
                'movie_77.jpg': {'sha256': sha, 'size': artBytes.length},
              },
            },
          },
          'maps': const {},
        },
      ];

      final summary = await sync.syncNow();
      expect(summary, contains('1 title detail(s) synced'));
      expect(summary, contains('1 artwork file(s) fetched'));

      final row = await metadataRowFor('movie:custom:2020');
      expect(row!.title, 'Custom, Matched');
      expect(row.overview, 'A film TMDB knows.');
      expect(row.userEdited, isFalse);
      expect(row.tmdbId, 77);
      expect(row.rating, 7.5);
      expect(row.fetchedAt, 4242);
      expect(row.posterFile, 'movie_77.jpg');
      final saved = File('${tempDir.path}/posters/movie_77.jpg');
      expect(saved.existsSync(), isTrue);
      expect(crypto.sha256.convert(saved.readAsBytesSync()).toString(), sha);

      // Our published doc now covers the key — the sender can stop —
      // and our art index re-serves the fetched file to third devices.
      final published = jsonDecode(fake.myWatchSyncPublishes.last)
          as Map<String, dynamic>;
      final doc = published['doc'] as Map<String, dynamic>;
      expect(doc['have'],
          contains(MyWatchSync.metaKeyHash('movie:custom:2020')));
      expect(fake.myWatchArtIndexPosts.last, contains(sha));

      // Second cycle: nothing left to do.
      expect(await sync.syncNow(), 'Everything is in sync.');
    });

    test('a cached miss upgrades, but user edits and own matches never '
        'get overwritten', () async {
      await seedLibrary('Custom (2020).mp4', _addr(1));
      final db = await LibraryStore.database();
      await db.into(db.metadataCache).insertOnConflictUpdate(
            MetadataCacheCompanion.insert(
              lookupKey: 'movie:custom:2020',
              found: false, // a confirmed TMDB miss from an old key
              fetchedAt: 1,
            ),
          );
      fake.myWatchSyncDevices = [
        {
          'agent_id': 'bb' * 32,
          'doc': {
            'v': 1,
            'lists': const [],
            'tmdb': {
              'v': 1,
              'rows': [
                {
                  'key': 'movie:custom:2020',
                  'updated_ms': 4242,
                  'title': 'Found elsewhere',
                },
              ],
            },
          },
          'maps': const {},
        },
      ];
      await sync.syncNow();
      var row = await metadataRowFor('movie:custom:2020');
      expect(row!.found, isTrue);
      expect(row.title, 'Found elsewhere');

      // Now the row exists (an "own match") — a newer remote TMDB row
      // must not touch it.
      fake.myWatchSyncDevices = [
        {
          'agent_id': 'bb' * 32,
          'doc': {
            'v': 1,
            'lists': const [],
            'tmdb': {
              'v': 1,
              'rows': [
                {
                  'key': 'movie:custom:2020',
                  'updated_ms': 9999,
                  'title': 'Should not land',
                },
              ],
            },
          },
          'maps': const {},
        },
      ];
      final summary = await sync.syncNow();
      expect(summary, isNot(contains('title detail')));
      row = await metadataRowFor('movie:custom:2020');
      expect(row!.title, 'Found elsewhere');
      expect(row.fetchedAt, 4242);
    });

    test('a device publishes its TMDB rows only while a linked device is '
        'missing them', () async {
      await seedLibrary('Custom (2020).mp4', _addr(1));
      final poster = File('${tempDir.path}/posters/movie_77.jpg')
        ..writeAsBytesSync(List<int>.generate(500, (i) => i % 251));
      final sha =
          crypto.sha256.convert(poster.readAsBytesSync()).toString();
      final db = await LibraryStore.database();
      await db.into(db.metadataCache).insertOnConflictUpdate(
            MetadataCacheCompanion.insert(
              lookupKey: 'movie:custom:2020',
              found: true,
              title: const Value('Custom, Matched'),
              overview: const Value('A film TMDB knows.'),
              mediaType: const Value('movie'),
              tmdbId: const Value(77),
              rating: const Value(7.5),
              posterFile: const Value('movie_77.jpg'),
              fetchedAt: 4242,
            ),
          );

      // The other device understands tmdb sync (`have` present) and has
      // nothing → we publish the row plus the file manifest.
      fake.myWatchSyncDevices = [
        {
          'agent_id': 'bb' * 32,
          'doc': {'v': 1, 'lists': const [], 'have': const <String>[]},
          'maps': const {},
        },
      ];
      await sync.syncNow();
      var doc = (jsonDecode(fake.myWatchSyncPublishes.last)
          as Map<String, dynamic>)['doc'] as Map<String, dynamic>;
      var tmdb = doc['tmdb'] as Map<String, dynamic>;
      final row = (tmdb['rows'] as List).single as Map<String, dynamic>;
      expect(row['key'], 'movie:custom:2020');
      expect(row['title'], 'Custom, Matched');
      expect(row['tmdb_id'], 77);
      expect((tmdb['files'] as Map)['movie_77.jpg'],
          {'sha256': sha, 'size': 500});
      // Our art index serves the TMDB file.
      expect(fake.myWatchArtIndexPosts.last, contains(sha));
      // And our own `have` names the key (row + art complete here).
      expect(doc['have'],
          contains(MyWatchSync.metaKeyHash('movie:custom:2020')));

      // Once the other device reports the key, the section drains away.
      fake.myWatchSyncDevices = [
        {
          'agent_id': 'bb' * 32,
          'doc': {
            'v': 1,
            'lists': const [],
            'have': [MyWatchSync.metaKeyHash('movie:custom:2020')],
          },
          'maps': const {},
        },
      ];
      await sync.syncNow();
      doc = (jsonDecode(fake.myWatchSyncPublishes.last)
          as Map<String, dynamic>)['doc'] as Map<String, dynamic>;
      expect(doc.containsKey('tmdb'), isFalse);
    });

    test('a doc without a have list (older app) gets no tmdb section', () async {
      await seedLibrary('Custom (2020).mp4', _addr(1));
      final db = await LibraryStore.database();
      await db.into(db.metadataCache).insertOnConflictUpdate(
            MetadataCacheCompanion.insert(
              lookupKey: 'movie:custom:2020',
              found: true,
              title: const Value('Custom, Matched'),
              fetchedAt: 4242,
            ),
          );
      fake.myWatchSyncDevices = [
        {
          'agent_id': 'bb' * 32,
          'doc': {'v': 1, 'lists': const []}, // alpha.62 doc shape
          'maps': const {},
        },
      ];
      await sync.syncNow();
      final doc = (jsonDecode(fake.myWatchSyncPublishes.last)
          as Map<String, dynamic>)['doc'] as Map<String, dynamic>;
      expect(doc.containsKey('tmdb'), isFalse);
    });

    test('a row applied without its artwork keeps the key off `have` so '
        'the manifests stay available for retries', () async {
      await seedLibrary('Custom (2020).mp4', _addr(1));
      fake.myWatchSyncDevices = [
        {
          'agent_id': 'bb' * 32,
          'doc': {
            'v': 1,
            'lists': const [],
            'tmdb': {
              'v': 1,
              'rows': [
                {
                  'key': 'movie:custom:2020',
                  'updated_ms': 4242,
                  'title': 'Custom, Matched',
                  'poster': 'movie_77.jpg',
                },
              ],
              'files': {
                'movie_77.jpg': {'sha256': 'cd' * 32, 'size': 10},
              },
            },
          },
          'maps': const {},
        },
      ];
      final summary = await sync.syncNow();
      expect(summary, contains('1 title detail(s) synced'));
      // The pull failed (no served file) — visible on the notifier.
      expect(
        MyWatchSync.status.value.problems.single,
        allOf(contains('Artwork'), contains('movie_77.jpg')),
      );
      final row = await metadataRowFor('movie:custom:2020');
      expect(row!.posterFile, 'movie_77.jpg'); // row applied, art pending
      final doc = (jsonDecode(fake.myWatchSyncPublishes.last)
          as Map<String, dynamic>)['doc'] as Map<String, dynamic>;
      expect(doc['have'],
          isNot(contains(MyWatchSync.metaKeyHash('movie:custom:2020'))));
    });

    test('an episode row lands with show and season extras, and every '
        'referenced art file is pulled', () async {
      await seedLibrary('Beyond (1959) S01E02.mkv', _addr(1));
      final bytes = {
        for (final n in ['tv_9_s1.jpg', 'tv_9_s1e2_still.jpg', 'tv_9.jpg'])
          n: List<int>.generate(300 + n.length, (i) => (i * 7 + n.length) % 251),
      };
      fake.myWatchArtFiles = {};
      for (final e in bytes.entries) {
        final sha = crypto.sha256.convert(e.value).toString();
        final f = File('${tempDir.path}/served_${e.key}')
          ..writeAsBytesSync(e.value);
        fake.myWatchArtFiles[sha] = f.path;
      }
      String sha(String n) => crypto.sha256.convert(bytes[n]!).toString();
      fake.myWatchSyncDevices = [
        {
          'agent_id': 'bb' * 32,
          'doc': {
            'v': 1,
            'lists': const [],
            'tmdb': {
              'v': 1,
              'rows': [
                {
                  'key': 'tv:beyond:1959:s1:e2',
                  'updated_ms': 4242,
                  'title': 'One Step Beyond',
                  'episode': 'S01E02 · Night of April 14th',
                  'type': 'tv',
                  'tmdb_id': 9,
                  'poster': 'tv_9_s1.jpg',
                  'still': 'tv_9_s1e2_still.jpg',
                },
              ],
              'shows': {
                'tv:beyond:1959': {
                  'overview': 'Anthology.',
                  'poster': 'tv_9.jpg',
                },
              },
              'seasons': {
                'tv:beyond:1959:s1': {'overview': 'Season one.'},
              },
              'files': {
                for (final n in bytes.keys)
                  n: {'sha256': sha(n), 'size': bytes[n]!.length},
              },
            },
          },
          'maps': const {},
        },
      ];
      final summary = await sync.syncNow();
      expect(summary, contains('1 title detail(s) synced'));
      expect(summary, contains('3 artwork file(s) fetched'));
      final row = await metadataRowFor('tv:beyond:1959:s1:e2');
      expect(row!.showOverview, 'Anthology.');
      expect(row.seasonOverview, 'Season one.');
      expect(row.showPosterFile, 'tv_9.jpg');
      expect(row.episodeLabel, 'S01E02 · Night of April 14th');
      for (final n in bytes.keys) {
        final f = File('${tempDir.path}/posters/$n');
        expect(f.existsSync(), isTrue, reason: n);
        expect(f.readAsBytesSync(), bytes[n]);
      }
    });
  });
}
