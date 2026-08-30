import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/services/embedded_client.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/services/my_watch_api.dart';
import 'package:watchit/services/my_watch_sync.dart';
import 'package:watchit/services/user_metadata.dart';
import 'package:watchit/services/watch_state.dart';

import 'fake_embedded_http.dart';

MetadataCacheRow _row(
  String key, {
  int fetchedAt = 1000,
  bool userEdited = true,
  String? title = 'Edited title',
  String? overview,
  String? episodeLabel,
  String? posterFile,
}) =>
    MetadataCacheRow(
      lookupKey: key,
      found: true,
      title: title,
      overview: overview,
      episodeLabel: episodeLabel,
      posterFile: posterFile,
      fetchedAt: fetchedAt,
      userEdited: userEdited,
    );

RemoteSyncDoc _docWithMeta(String agent, List<Map<String, dynamic>> rows) =>
    RemoteSyncDoc(agentId: agent, doc: {
      'v': 1,
      'lists': const [],
      'meta': {'v': 1, 'rows': rows},
    }, maps: const {});

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('metaRowsFrom', () {
    test('publishes user rows with art manifests, skips the rest', () {
      final rows = [
        _row('movie:one:2020',
            overview: 'Plot', posterFile: 'user_one_ab_1.jpg'),
        _row('movie:two:2021', userEdited: false),
        _row('movie:three:2022', posterFile: 'tmdb_3.jpg'),
      ];
      final out = MyWatchSync.metaRowsFrom(rows, {
        'user_one_ab_1.jpg': (sha256: 'aa' * 32, size: 123),
      });
      expect(out, hasLength(2));
      expect(out.first['key'], 'movie:one:2020');
      expect(out.first['updated_ms'], 1000);
      expect(out.first['overview'], 'Plot');
      expect(out.first['art'], {'sha256': 'aa' * 32, 'size': 123});
      // TMDB-owned artwork gets no manifest.
      expect(out.last['key'], 'movie:three:2022');
      expect(out.last.containsKey('art'), isFalse);
    });

    test('caps a runaway description', () {
      final out = MyWatchSync.metaRowsFrom(
        [_row('k', overview: 'x' * 5000)],
        const {},
      );
      expect((out.single['overview'] as String).length,
          MyWatchSync.maxMetaOverviewChars);
    });
  });

  group('buildDoc meta', () {
    test('meta rides in the doc only when rows exist', () {
      final without = MyWatchSync.buildDoc(
        lists: const [],
        tombstones: const {},
        watchStates: const [],
        nowMs: 1,
      );
      expect(without.containsKey('meta'), isFalse);
      final with_ = MyWatchSync.buildDoc(
        lists: const [],
        tombstones: const {},
        watchStates: const [],
        nowMs: 1,
        metaRows: [
          {'key': 'k', 'updated_ms': 5},
        ],
      );
      expect((with_['meta'] as Map)['rows'], hasLength(1));
    });
  });

  group('remoteMetaWinners', () {
    test('newest row per key wins across devices', () {
      final winners = MyWatchSync.remoteMetaWinners([
        _docWithMeta('aa' * 32, [
          {'key': 'k', 'updated_ms': 100, 'title': 'Old'},
          {'key': 'other', 'updated_ms': 50, 'title': 'Other'},
        ]),
        _docWithMeta('bb' * 32, [
          {'key': 'k', 'updated_ms': 200, 'title': 'New'},
        ]),
      ]);
      final k = winners.singleWhere((w) => w.key == 'k');
      expect(k.title, 'New');
      expect(k.agentId, 'bb' * 32);
      expect(winners, hasLength(2));
    });

    test('bad rows and bad art manifests are dropped or sanitised', () {
      final winners = MyWatchSync.remoteMetaWinners([
        _docWithMeta('aa' * 32, [
          {'key': '', 'updated_ms': 100},
          {'key': 'no-stamp'},
          {
            'key': 'bad-art',
            'updated_ms': 5,
            'art': {'sha256': 'nope', 'size': 1},
          },
          {
            'key': 'good',
            'updated_ms': 5,
            'episode': 'S01E01 · Pilot',
            'art': {'sha256': 'AB' * 32, 'size': 9},
          },
        ]),
      ]);
      expect(winners, hasLength(2));
      expect(winners.singleWhere((w) => w.key == 'bad-art').art, isNull);
      final good = winners.singleWhere((w) => w.key == 'good');
      expect(good.episodeLabel, 'S01E01 · Pilot');
      expect(good.art, (sha256: 'ab' * 32, size: 9));
    });
  });

  group('shouldApplyRemoteRow', () {
    test('LWW matrix', () {
      // Missing local row and TMDB rows always lose to a user edit.
      expect(
          MyWatchSync.shouldApplyRemoteRow(
              localExists: false,
              localUserEdited: false,
              localUpdatedMs: 0,
              remoteUpdatedMs: 1),
          isTrue);
      expect(
          MyWatchSync.shouldApplyRemoteRow(
              localExists: true,
              localUserEdited: false,
              localUpdatedMs: 999999,
              remoteUpdatedMs: 1),
          isTrue);
      // Local user edit only loses to a strictly newer remote one.
      expect(
          MyWatchSync.shouldApplyRemoteRow(
              localExists: true,
              localUserEdited: true,
              localUpdatedMs: 100,
              remoteUpdatedMs: 200),
          isTrue);
      expect(
          MyWatchSync.shouldApplyRemoteRow(
              localExists: true,
              localUserEdited: true,
              localUpdatedMs: 200,
              remoteUpdatedMs: 200),
          isFalse);
      expect(
          MyWatchSync.shouldApplyRemoteRow(
              localExists: true,
              localUserEdited: true,
              localUpdatedMs: 300,
              remoteUpdatedMs: 200),
          isFalse);
    });
  });

  group('apply helpers', () {
    late Directory postersDir;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await LibraryStore.useForTesting(
          AppDatabase.forTesting(NativeDatabase.memory()));
      postersDir = Directory.systemTemp.createTempSync('wi-meta-sync');
      MetadataService.instance = MetadataService(
        postersDirProvider: () async => postersDir,
        apiKeyProvider: () async => '',
        httpClient: MockClient((req) async => http.Response('{}', 404)),
      );
    });

    tearDown(() {
      postersDir.deleteSync(recursive: true);
    });

    test('applyRemoteUserDetails stamps the remote time and preserves extras',
        () async {
      final db = await LibraryStore.database();
      await db.into(db.metadataCache).insertOnConflictUpdate(
            MetadataCacheCompanion.insert(
              lookupKey: 'movie:x:2020',
              found: true,
              title: const Value('TMDB title'),
              rating: const Value(7.5),
              tmdbId: const Value(42),
              posterFile: const Value('movie_42.jpg'),
              fetchedAt: 111,
            ),
          );
      await applyRemoteUserDetails(
        lookupKey: 'movie:x:2020',
        title: 'My title',
        overview: 'My plot',
        updatedMs: 5555,
        remoteHasArt: false,
        postersDirProvider: () async => postersDir,
      );
      final row = await metadataRowFor('movie:x:2020');
      expect(row!.title, 'My title');
      expect(row.overview, 'My plot');
      expect(row.fetchedAt, 5555);
      expect(row.userEdited, isTrue);
      expect(row.rating, 7.5);
      expect(row.tmdbId, 42);
      // TMDB artwork survives a remote text-only edit.
      expect(row.posterFile, 'movie_42.jpg');
    });

    test('a newer remote row without art clears the local user poster',
        () async {
      final name = await saveUserPoster(
        'movie:x:2020',
        Uint8List.fromList([1, 2, 3]),
        postersDirProvider: () async => postersDir,
      );
      await saveUserDetails(
        lookupKey: 'movie:x:2020',
        title: 'T',
        posterFile: Value(name),
        postersDirProvider: () async => postersDir,
      );
      await applyRemoteUserDetails(
        lookupKey: 'movie:x:2020',
        title: 'T',
        updatedMs: 10,
        remoteHasArt: false,
        postersDirProvider: () async => postersDir,
      );
      final row = await metadataRowFor('movie:x:2020');
      expect(row!.posterFile, isNull);
      expect(File('${postersDir.path}/$name').existsSync(), isFalse);
    });

    test('applyRemotePoster saves the bytes without touching the LWW stamp',
        () async {
      await applyRemoteUserDetails(
        lookupKey: 'movie:x:2020',
        title: 'T',
        updatedMs: 10,
        remoteHasArt: true,
        postersDirProvider: () async => postersDir,
      );
      await applyRemotePoster(
        'movie:x:2020',
        Uint8List.fromList([9, 9, 9]),
        postersDirProvider: () async => postersDir,
      );
      final row = await metadataRowFor('movie:x:2020');
      expect(row!.posterFile, startsWith('user_'));
      expect(row.fetchedAt, 10);
      expect(
        File('${postersDir.path}/${row.posterFile}').readAsBytesSync(),
        [9, 9, 9],
      );
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
      tempDir = Directory.systemTemp.createTempSync('wi-meta-cycle');
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

    test('remote details and artwork land, then republish with a manifest',
        () async {
      final artBytes = List<int>.generate(70000, (i) => i % 251);
      final sha = crypto.sha256.convert(artBytes).toString();
      final served = File('${tempDir.path}/incoming_art')
        ..writeAsBytesSync(artBytes);
      fake.myWatchArtFiles = {sha: served.path};
      fake.myWatchSyncDevices = [
        {
          'agent_id': 'bb' * 32,
          'doc': {
            'v': 1,
            'lists': const [],
            'meta': {
              'v': 1,
              'rows': [
                {
                  'key': 'movie:custom:2020',
                  'updated_ms': 7777,
                  'title': 'Custom cut',
                  'overview': 'A film only I have.',
                  'art': {'sha256': sha, 'size': artBytes.length},
                },
              ],
            },
          },
          'maps': const {},
        },
      ];

      final summary = await sync.syncNow();
      expect(summary, contains('1 detail edit(s) applied'));
      expect(summary, contains('1 artwork file(s) fetched'));

      final row = await metadataRowFor('movie:custom:2020');
      expect(row!.title, 'Custom cut');
      expect(row.overview, 'A film only I have.');
      expect(row.fetchedAt, 7777);
      expect(row.userEdited, isTrue);
      expect(row.posterFile, startsWith('user_'));
      final saved =
          File('${tempDir.path}/posters/${row.posterFile}').readAsBytesSync();
      expect(crypto.sha256.convert(saved).toString(), sha);

      // Our next publish carries the same manifest (identical bytes →
      // identical hash), so a third device can pull it from us.
      expect(fake.myWatchSyncPublishes, isNotEmpty);
      final published = jsonDecode(fake.myWatchSyncPublishes.last)
          as Map<String, dynamic>;
      final meta =
          (published['doc'] as Map<String, dynamic>)['meta'] as Map<String, dynamic>;
      final metaRow = (meta['rows'] as List).single as Map<String, dynamic>;
      expect(metaRow['key'], 'movie:custom:2020');
      expect(metaRow['updated_ms'], 7777);
      expect((metaRow['art'] as Map)['sha256'], sha);
      // And the art index handed to the embedded client names the file.
      expect(fake.myWatchArtIndexPosts, isNotEmpty);
      expect(fake.myWatchArtIndexPosts.last, contains(sha));

      // A second cycle is a no-op: nothing new to apply or fetch.
      final again = await sync.syncNow();
      expect(again, 'Everything is in sync.');
    });

    test('a refusing owner leaves the text synced, the art pending, and '
        'the failure on the status notifier', () async {
      fake.myWatchStatus['devices'] = [
        {
          'agent_id': 'bb' * 32,
          'self': false,
          'name': 'desktop',
          'platform': 'linux',
          'online': false,
        },
      ];
      fake.myWatchSyncDevices = [
        {
          'agent_id': 'bb' * 32,
          'doc': {
            'v': 1,
            'lists': const [],
            'meta': {
              'v': 1,
              'rows': [
                {
                  'key': 'movie:custom:2020',
                  'updated_ms': 7777,
                  'title': 'Custom cut',
                  'art': {'sha256': 'cd' * 32, 'size': 10},
                },
              ],
            },
          },
          'maps': const {},
        },
      ];
      final summary = await sync.syncNow();
      expect(summary, contains('1 detail edit(s) applied'));
      expect(summary, isNot(contains('artwork')));
      final row = await metadataRowFor('movie:custom:2020');
      expect(row!.title, 'Custom cut');
      expect(row.posterFile, isNull);
      // The failed pull is visible on the indicator instead of only in
      // the debug log.
      expect(
        MyWatchSync.status.value.problems.single,
        allOf(contains('Artwork'), contains('Custom cut')),
      );
      expect(MyWatchSync.status.value.lastSummary, summary);
      expect(MyWatchSync.status.value.linked, isTrue);
      expect(MyWatchSync.status.value.syncing, isFalse);
    });

    test('presence saying "offline" does not stop an artwork pull — the '
        'owner is tried anyway', () async {
      final artBytes = List<int>.generate(5000, (i) => (i * 7) % 251);
      final sha = crypto.sha256.convert(artBytes).toString();
      final served = File('${tempDir.path}/offline_owner_art')
        ..writeAsBytesSync(artBytes);
      fake.myWatchArtFiles = {sha: served.path};
      // x0x presence under-reports on real networks; it must order
      // candidates, never gate them.
      fake.myWatchStatus['devices'] = [
        {
          'agent_id': 'bb' * 32,
          'self': false,
          'name': 'desktop',
          'platform': 'linux',
          'online': false,
        },
      ];
      fake.myWatchSyncDevices = [
        {
          'agent_id': 'bb' * 32,
          'doc': {
            'v': 1,
            'lists': const [],
            'meta': {
              'v': 1,
              'rows': [
                {
                  'key': 'movie:custom:2020',
                  'updated_ms': 7777,
                  'title': 'Custom cut',
                  'art': {'sha256': sha, 'size': artBytes.length},
                },
              ],
            },
          },
          'maps': const {},
        },
      ];
      final summary = await sync.syncNow();
      expect(summary, contains('1 artwork file(s) fetched'));
      final row = await metadataRowFor('movie:custom:2020');
      expect(row!.posterFile, startsWith('user_'));
      expect(MyWatchSync.status.value.problems, isEmpty);
    });

    test('a local user edit newer than the remote row is kept', () async {
      await applyRemoteUserDetails(
        lookupKey: 'movie:custom:2020',
        title: 'Mine, newer',
        updatedMs: 9999,
        remoteHasArt: false,
        postersDirProvider: MyWatchSync.postersDirOverride,
      );
      fake.myWatchSyncDevices = [
        {
          'agent_id': 'bb' * 32,
          'doc': {
            'v': 1,
            'lists': const [],
            'meta': {
              'v': 1,
              'rows': [
                {'key': 'movie:custom:2020', 'updated_ms': 7777, 'title': 'Old'},
              ],
            },
          },
          'maps': const {},
        },
      ];
      await sync.syncNow();
      final row = await metadataRowFor('movie:custom:2020');
      expect(row!.title, 'Mine, newer');
      expect(row.fetchedAt, 9999);
    });

    // A remote doc whose entry's shrunk map cannot import (the Autonomi
    // network is unreachable) — the map goes on retry backoff and is
    // reported pending.
    List<Map<String, dynamic>> mapDoc(String addr) => [
          {
            'agent_id': 'bb' * 32,
            'doc': {
              'v': 1,
              'lists': [
                {
                  'title': 'Movies',
                  'entries': [
                    {'name': 'M.mp4', 'address': addr, 'added_ms': 1000},
                  ],
                },
              ],
            },
            'maps': {addr: base64Encode(const [7])},
          },
        ];

    int datamapPosts() =>
        fake.requests.where((r) => r == 'POST /datamap').length;

    test('map backoff resets when connectivity returns, pending surfaces',
        () async {
      var health = const ClientHealth(state: 'connecting');
      final sync2 = MyWatchSync(
        api: MyWatchApi(base: FakeEmbeddedHttp.base, token: 't'),
        health: () async => health,
        clientBase: FakeEmbeddedHttp.base,
      );
      final addr = FakeEmbeddedHttp.addrForByte(7);
      fake.datamapUnavailable = true;
      fake.myWatchSyncDevices = mapDoc(addr);

      await sync2.cycleForTesting();
      expect(datamapPosts(), 1);
      expect(MyWatchSync.status.value.pendingMaps, 1);

      // Still offline: the backoff skips the import, the cycle reports
      // "in sync" while the map stays pending — the user's exact report.
      await sync2.cycleForTesting();
      expect(datamapPosts(), 1);
      expect(MyWatchSync.status.value.pendingMaps, 1);
      expect(MyWatchSync.status.value.lastSummary, 'Everything is in sync.');

      // Connectivity returns: the backoff is dropped, the very next
      // cycle retries and the map lands.
      health = const ClientHealth(state: 'ready', peers: 5);
      fake.datamapUnavailable = false;
      await sync2.cycleForTesting();
      expect(datamapPosts(), 2);
      expect(MyWatchSync.status.value.pendingMaps, 0);
      expect(
          MyWatchSync.status.value.lastSummary, contains('1 map(s) fetched'));
    });

    test('Sync now retries a backed-off map immediately', () async {
      final sync2 = MyWatchSync(
        api: MyWatchApi(base: FakeEmbeddedHttp.base, token: 't'),
        // Health never reports connected: the retry below must come from
        // the manual reset, not the connectivity transition.
        health: () async => const ClientHealth(state: 'connecting'),
        clientBase: FakeEmbeddedHttp.base,
      );
      final addr = FakeEmbeddedHttp.addrForByte(7);
      fake.datamapUnavailable = true;
      fake.myWatchSyncDevices = mapDoc(addr);

      await sync2.syncNow();
      expect(datamapPosts(), 1);
      expect(MyWatchSync.status.value.pendingMaps, 1);

      fake.datamapUnavailable = false;
      final summary = await sync2.syncNow();
      expect(datamapPosts(), 2);
      expect(summary, contains('1 map(s) fetched'));
      expect(MyWatchSync.status.value.pendingMaps, 0);
    });

    test('a stored map never counts as pending, even under backoff',
        () async {
      final sync2 = MyWatchSync(
        api: MyWatchApi(base: FakeEmbeddedHttp.base, token: 't'),
        health: () async => const ClientHealth(state: 'connecting'),
        clientBase: FakeEmbeddedHttp.base,
      );
      final addr = FakeEmbeddedHttp.addrForByte(7);
      fake.datamapUnavailable = true;
      fake.myWatchSyncDevices = mapDoc(addr);
      await sync2.cycleForTesting();
      expect(MyWatchSync.status.value.pendingMaps, 1);

      // The map arrives some other way (manual bundle re-import): the
      // backoff entry must not keep reporting it pending.
      fake.resolvedAddrs.add(addr);
      await sync2.cycleForTesting();
      expect(datamapPosts(), 1);
      expect(MyWatchSync.status.value.pendingMaps, 0);
    });
  });
}
