import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' hide Row;

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/services/my_watch_api.dart';
import 'package:watchit/services/my_watch_sync.dart';
import 'package:watchit/services/profile_sync.dart';
import 'package:watchit/services/profiles.dart';
import 'package:watchit/services/watch_state.dart';

import 'fake_embedded_http.dart';

String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

MediaEntry _e(String name, int i) =>
    MediaEntry(name: name, address: _addr(i), addedAt: 1000);

RemoteSyncDoc _doc(String agent, Map<String, dynamic> profiles) =>
    RemoteSyncDoc(
      agentId: agent,
      doc: {'v': 1, 'lists': const [], 'profiles': profiles},
      maps: const {},
    );

Future<({String sha256, int size})?> _noArt(String name) async => null;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'defaults_seeded_v4': true});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    ProfileStore.onSwitch = null;
    ProfileStore.instance = ProfileStore();
    WatchStateStore.instance = WatchStateStore();
  });

  group('buildLocalProfilesSection', () {
    test('publishes every profile with stamps, PIN pairs, allow titles '
        'and per-profile watch states', () async {
      final store = ProfileStore.instance;
      await store.ensureLoaded();
      await store.setAdminPin('4321');
      await LibraryStore.save([
        MediaList(id: 'l1', title: 'Movies', entries: [_e('A.mkv', 1)]),
      ]);
      final lists = await LibraryStore.load();
      final kid = await store.create(
          name: 'Ellie',
          kind: ProfileKind.kid,
          avatar: 'preset:2',
          allowedLists: {lists.first.id});
      await store.setPin(kid.id, '1111');
      await WatchStateStore.instance.mergeAll([
        WatchState(
            address: _addr(1),
            positionMs: 60000,
            durationMs: 600000,
            completed: false,
            updatedAt: 5000),
      ], profileId: kid.id);
      // The admin's own states ride the doc's top-level watch section,
      // never the profiles one.
      await WatchStateStore.instance.mergeAll([
        WatchState(
            address: _addr(2),
            positionMs: 1,
            durationMs: 2,
            completed: false,
            updatedAt: 1),
      ]);

      final section = await buildLocalProfilesSection(
        lists: lists,
        nowMs: 10000,
        avatarInfo: _noArt,
        tombstoneTtlMs: MyWatchSync.tombstoneTtlMs,
      );
      final items = section['items'] as Map<String, dynamic>;
      expect(items.keys, contains(kProfileAdminKey));
      final admin = items[kProfileAdminKey] as Map<String, dynamic>;
      expect(admin['kind'], 'admin');
      expect(admin['pin'], isNotNull);
      // The admin PIN travels with its recovery hash — a pair.
      expect(admin['rec'], isNotNull);

      final kidRow = store.profiles.firstWhere((p) => p.id == kid.id);
      expect(kidRow.syncId, isNotNull, reason: 'publish mints the sync id');
      final kidItem = items[kidRow.syncId] as Map<String, dynamic>;
      expect(kidItem['name'], 'Ellie');
      expect(kidItem['kind'], 'kid');
      expect(kidItem['avatar'], 'preset:2');
      expect(kidItem['pin'], isNotNull);
      expect(kidItem.containsKey('rec'), isFalse);
      expect(kidItem['allow'], ['Movies']);
      expect(kidItem['updated_ms'], greaterThan(0));

      final watch = section['watch'] as Map<String, dynamic>;
      expect(watch.keys, [kidRow.syncId]);
      final row = (watch[kidRow.syncId] as List).single as Map;
      expect(row['address'], _addr(1));
      expect(row['updated_ms'], 5000);
    });

    test('a deleted profile leaves a tombstone that rides the section '
        '(and old stones are GC\'d)', () async {
      final store = ProfileStore.instance;
      await store.ensureLoaded();
      await store.create(name: 'Old', kind: ProfileKind.adult);
      // Mint sync ids (as the first publish would), then delete.
      await store.ensureSyncIds();
      final victim = store.profiles.firstWhere((p) => !p.isAdmin);
      await store.deleteProfile(victim.id);
      // A stale stone from long ago is GC'd at publish.
      final stones = await ProfileStore.profileStones();
      stones['ancient'] = 1;
      await ProfileStore.saveProfileStones(stones);

      final section = await buildLocalProfilesSection(
        lists: const [],
        nowMs: DateTime.now().millisecondsSinceEpoch,
        avatarInfo: _noArt,
        tombstoneTtlMs: MyWatchSync.tombstoneTtlMs,
      );
      final removed = section['removed'] as Map<String, dynamic>;
      expect(removed.keys, [victim.syncId]);
      expect(removed[victim.syncId], greaterThan(0));
    });

    test('a profile that never synced needs (and gets) no stone',
        () async {
      final store = ProfileStore.instance;
      await store.ensureLoaded();
      final p = await store.create(name: 'Brief', kind: ProfileKind.adult);
      expect(p.syncId, isNull);
      await store.deleteProfile(p.id);
      expect(await ProfileStore.profileStones(), isEmpty);
    });
  });

  group('applyProfileActions', () {
    test('a new remote profile is created whole, and its watch points '
        'land on the new local id', () async {
      final store = ProfileStore.instance;
      await store.ensureLoaded();
      await LibraryStore.save([
        MediaList(id: 'l1', title: 'Movies', entries: [_e('A.mkv', 1)]),
      ]);
      final lists = await LibraryStore.load();
      final docs = [
        _doc('bb' * 32, {
          'v': 1,
          'items': {
            'sid-ellie': {
              'name': 'Ellie',
              'kind': 'kid',
              'updated_ms': 5000,
              'avatar': 'preset:3',
              'pin': 'aa:bb',
              'allow': ['Movies'],
            },
          },
          'watch': {
            'sid-ellie': [
              {
                'address': _addr(1),
                'pos_ms': 90000,
                'dur_ms': 600000,
                'completed': false,
                'updated_ms': 7000,
              },
            ],
          },
        }),
      ];
      final actions = profileActionsFrom(docs);
      final apply = await applyProfileActions(
          items: actions.items, remoteStones: actions.stones, lists: lists);
      expect(apply.created, 1);

      final kid = store.profiles.firstWhere((p) => p.isKid);
      expect(kid.name, 'Ellie');
      expect(kid.syncId, 'sid-ellie');
      expect(kid.updatedMs, 5000);
      expect(kid.avatar, 'preset:3');
      expect(kid.pinHash, 'aa:bb');
      expect(await store.allowedListIds(kid.id), {lists.first.id});
      expect(apply.localIdByKey['sid-ellie'], kid.id);

      final watch = remoteProfileWatch(docs);
      final n = await WatchStateStore.instance
          .mergeAll(watch['sid-ellie']!, profileId: kid.id);
      expect(n, 1);
      final states = await WatchStateStore.instance.all(profileId: kid.id);
      expect(states.single.positionMs, 90000);
      // Nothing leaked onto the admin profile.
      expect(await WatchStateStore.instance.all(profileId: kAdminProfileId),
          isEmpty);
    });

    test('last writer wins: a newer remote row updates everything, an '
        'older one changes nothing', () async {
      final store = ProfileStore.instance;
      await store.ensureLoaded();
      final kid = await store.create(
          name: 'Ellie', kind: ProfileKind.kid, syncId: 'sid', updatedMs: 100);
      RemoteProfileActions actions(int ms, String name) =>
          profileActionsFrom([
            _doc('bb' * 32, {
              'v': 1,
              'items': {
                'sid': {
                  'name': name,
                  'kind': 'adult',
                  'updated_ms': ms,
                  'pin': 'cc:dd',
                },
              },
            }),
          ]);

      var a = actions(200, 'Elly');
      var apply = await applyProfileActions(
          items: a.items, remoteStones: a.stones, lists: const []);
      expect(apply.updated, 1);
      var p = store.profiles.firstWhere((p) => p.id == kid.id);
      expect(p.name, 'Elly');
      expect(p.kind, ProfileKind.adult);
      expect(p.pinHash, 'cc:dd');
      expect(p.updatedMs, 200);

      // Older row: nothing moves (ties keep local too — stable on both
      // devices, exactly the meta-row rule).
      a = actions(150, 'Stale');
      apply = await applyProfileActions(
          items: a.items, remoteStones: a.stones, lists: const []);
      expect(apply.changed, 0);
      p = store.profiles.firstWhere((p) => p.id == kid.id);
      expect(p.name, 'Elly');
      expect(p.updatedMs, 200);
    });

    test('a remote tombstone deletes the profile (and its watch states); '
        'a strictly newer local edit beats a stale stone', () async {
      final store = ProfileStore.instance;
      await store.ensureLoaded();
      final kid = await store.create(
          name: 'Ellie', kind: ProfileKind.kid, syncId: 'sid', updatedMs: 100);
      await WatchStateStore.instance.mergeAll([
        WatchState(
            address: _addr(1),
            positionMs: 1,
            durationMs: 2,
            completed: false,
            updatedAt: 1),
      ], profileId: kid.id);

      final a = profileActionsFrom([
        _doc('bb' * 32, {
          'v': 1,
          'items': const {},
          'removed': {'sid': 200},
        }),
      ]);
      final apply = await applyProfileActions(
          items: a.items, remoteStones: a.stones, lists: const []);
      expect(apply.deleted, 1);
      expect(store.profiles.any((p) => p.isKid), isFalse);
      expect(await WatchStateStore.instance.all(profileId: kid.id), isEmpty);
      // The stone was adopted, so we keep propagating the deletion.
      expect(await ProfileStore.profileStones(), containsPair('sid', 200));

      // A profile edited AFTER the stone survives it.
      await store.create(
          name: 'Ellie', kind: ProfileKind.kid, syncId: 'sid2',
          updatedMs: 500);
      final b = profileActionsFrom([
        _doc('bb' * 32, {
          'v': 1,
          'items': const {},
          'removed': {'sid2': 300},
        }),
      ]);
      final apply2 = await applyProfileActions(
          items: b.items, remoteStones: b.stones, lists: const []);
      expect(apply2.deleted, 0);
      expect(store.profiles.any((p) => p.isKid), isTrue);
    });

    test('the admin never dies to a stone, adopts its PIN only as a '
        'pair, and a pin-less newer row clears it', () async {
      final store = ProfileStore.instance;
      await store.ensureLoaded();
      final admin = store.adminProfile!;
      await store.updateProfile(admin.copyWith(pinHash: 'aa:bb'),
          updatedMs: 100);

      // Stones never touch the admin key.
      final s = profileActionsFrom([
        _doc('bb' * 32, {
          'v': 1,
          'items': const {},
          'removed': {'admin': 999},
        }),
      ]);
      expect(s.stones, isEmpty);

      // PIN without its recovery pair: name adopts, the PIN stays ours.
      var a = profileActionsFrom([
        _doc('bb' * 32, {
          'v': 1,
          'items': {
            'admin': {
              'name': 'Dad',
              'kind': 'admin',
              'updated_ms': 200,
              'pin': 'cc:dd',
            },
          },
        }),
      ]);
      await applyProfileActions(
          items: a.items, remoteStones: a.stones, lists: const []);
      var p = store.adminProfile!;
      expect(p.name, 'Dad');
      expect(p.pinHash, 'aa:bb');
      expect(p.updatedMs, 200);

      // The full pair adopts together.
      a = profileActionsFrom([
        _doc('bb' * 32, {
          'v': 1,
          'items': {
            'admin': {
              'name': 'Dad',
              'kind': 'admin',
              'updated_ms': 300,
              'pin': 'cc:dd',
              'rec': 'ee:ff',
            },
          },
        }),
      ]);
      await applyProfileActions(
          items: a.items, remoteStones: a.stones, lists: const []);
      p = store.adminProfile!;
      expect(p.pinHash, 'cc:dd');
      expect(await store.adminRecoveryHash(), 'ee:ff');

      // A newer row with no PIN at all = the admin removed it there.
      a = profileActionsFrom([
        _doc('bb' * 32, {
          'v': 1,
          'items': {
            'admin': {'name': 'Dad', 'kind': 'admin', 'updated_ms': 400},
          },
        }),
      ]);
      await applyProfileActions(
          items: a.items, remoteStones: a.stones, lists: const []);
      p = store.adminProfile!;
      expect(p.pinHash, isNull);
      expect(await store.adminRecoveryHash(), isNull);
    });

    test('same-name profiles created on two devices converge on one '
        'sync id (newest row wins)', () async {
      final store = ProfileStore.instance;
      await store.ensureLoaded();
      final kid = await store.create(
          name: 'Ellie', kind: ProfileKind.kid, syncId: 'aaa', updatedMs: 100);

      // The remote row is newer → we adopt ITS id (and fields).
      var a = profileActionsFrom([
        _doc('bb' * 32, {
          'v': 1,
          'items': {
            'bbb': {'name': 'ellie', 'kind': 'kid', 'updated_ms': 200},
          },
        }),
      ]);
      var apply = await applyProfileActions(
          items: a.items, remoteStones: a.stones, lists: const []);
      var p = store.profiles.firstWhere((p) => p.id == kid.id);
      expect(p.syncId, 'bbb');
      expect(apply.localIdByKey['bbb'], kid.id);
      expect(store.profiles.where((x) => !x.isAdmin), hasLength(1),
          reason: 'no duplicate was created');

      // An OLDER same-name row keeps our id (the other side adopts).
      a = profileActionsFrom([
        _doc('bb' * 32, {
          'v': 1,
          'items': {
            'ccc': {'name': 'Ellie', 'kind': 'kid', 'updated_ms': 50},
          },
        }),
      ]);
      apply = await applyProfileActions(
          items: a.items, remoteStones: a.stones, lists: const []);
      p = store.profiles.firstWhere((p) => p.id == kid.id);
      expect(p.syncId, 'bbb');
      // Its watch states still land on the shared profile.
      expect(apply.localIdByKey['ccc'], kid.id);
      expect(store.profiles.where((x) => !x.isAdmin), hasLength(1));
    });

    test('equal stamps top a kid allow-list up with titles that resolve '
        'now, and never remove', () async {
      final store = ProfileStore.instance;
      await store.ensureLoaded();
      await LibraryStore.save([
        MediaList(id: 'l1', title: 'Movies', entries: [_e('A.mkv', 1)]),
        MediaList(id: 'l2', title: 'TV Shows', entries: [_e('B.mkv', 2)]),
      ]);
      final lists = await LibraryStore.load();
      final movies = lists.firstWhere((l) => l.title == 'Movies');
      final tv = lists.firstWhere((l) => l.title == 'TV Shows');
      final kid = await store.create(
          name: 'Ellie',
          kind: ProfileKind.kid,
          syncId: 'sid',
          updatedMs: 100,
          allowedLists: {movies.id});

      final a = profileActionsFrom([
        _doc('bb' * 32, {
          'v': 1,
          'items': {
            'sid': {
              'name': 'Ellie',
              'kind': 'kid',
              'updated_ms': 100,
              'allow': ['Movies', 'TV Shows'],
            },
          },
        }),
      ]);
      await applyProfileActions(
          items: a.items, remoteStones: a.stones, lists: lists);
      expect(await store.allowedListIds(kid.id), {movies.id, tv.id});

      // An equal-stamp row with FEWER titles removes nothing (removals
      // only happen on a strictly newer row).
      final b = profileActionsFrom([
        _doc('bb' * 32, {
          'v': 1,
          'items': {
            'sid': {
              'name': 'Ellie',
              'kind': 'kid',
              'updated_ms': 100,
              'allow': <String>[],
            },
          },
        }),
      ]);
      await applyProfileActions(
          items: b.items, remoteStones: b.stones, lists: lists);
      expect(await store.allowedListIds(kid.id), {movies.id, tv.id});
    });

    test('an avatar manifest is wanted until the bytes are held',
        () async {
      final store = ProfileStore.instance;
      await store.ensureLoaded();
      await store.create(
          name: 'Ellie', kind: ProfileKind.kid, syncId: 'sid',
          updatedMs: 100);
      final a = profileActionsFrom([
        _doc('bb' * 32, {
          'v': 1,
          'items': {
            'sid': {
              'name': 'Ellie',
              'kind': 'kid',
              'updated_ms': 200,
              'art': {'sha256': 'ab' * 32, 'size': 10},
            },
          },
        }),
      ]);
      final apply = await applyProfileActions(
          items: a.items, remoteStones: a.stones, lists: const []);
      expect(apply.wantedAvatars.single.sha256, 'ab' * 32);

      // Once a local file with the same hash is on the profile, the
      // manifest is satisfied — nothing wanted.
      final kid = store.profiles.firstWhere((p) => p.isKid);
      await store.updateProfile(
          kid.copyWith(avatar: 'profile_avatar_${kid.id}_1.img'),
          updatedMs: kid.updatedMs);
      final again = await applyProfileActions(
          items: a.items,
          remoteStones: a.stones,
          lists: const [],
          avatarInfo: (name) async => (sha256: 'ab' * 32, size: 10));
      expect(again.wantedAvatars, isEmpty);
    });
  });

  group('doc budget', () {
    Map<String, dynamic> section(int states) => {
          'v': 1,
          'items': {
            'sid': {'name': 'Ellie', 'kind': 'kid', 'updated_ms': 1},
          },
          'watch': {
            'sid': [
              for (var i = 0; i < states; i++)
                {
                  'address': _addr(i),
                  'pos_ms': 1,
                  'dur_ms': 2,
                  'completed': false,
                  'updated_ms': i,
                },
            ],
          },
        };

    test('shrunkenProfilesWatch drops the stalest quarter, keeps items',
        () {
      final s = MyWatchSync.shrunkenProfilesWatch(section(8));
      expect(MyWatchSync.profilesWatchCount(s), 6);
      final kept = ((s['watch'] as Map)['sid'] as List)
          .map((r) => (r as Map)['updated_ms'])
          .toSet();
      // The two STALEST (updated_ms 0 and 1) dropped.
      expect(kept, {2, 3, 4, 5, 6, 7});
      expect((s['items'] as Map).keys, ['sid']);
    });

    test('buildDocWithinBudget trims profile watch states, never the '
        'items or stones', () {
      final built = MyWatchSync.buildDocWithinBudget(
        lists: const [],
        tombstones: const {},
        watchStates: const [],
        nowMs: 1,
        profilesSection: {...section(2000), 'removed': {'gone': 5}},
      );
      expect(utf8.encode(jsonEncode(built.doc)).length,
          lessThanOrEqualTo(MyWatchSync.maxDocBytes));
      expect(built.profileWatchDropped, greaterThan(0));
      final sec = built.doc['profiles'] as Map<String, dynamic>;
      expect((sec['items'] as Map).keys, ['sid']);
      expect(sec['removed'], {'gone': 5});
      expect(MyWatchSync.profilesWatchCount(sec),
          2000 - built.profileWatchDropped);
    });

    test('buildDocParts puts the section in part 0 only', () {
      final built = MyWatchSync.buildDocParts(
        lists: const [],
        tombstones: const {},
        watchStates: const [],
        nowMs: 1,
        profilesSection: section(1),
      );
      expect(built.parts.first.containsKey('profiles'), isTrue);
      for (final p in built.parts.skip(1)) {
        expect(p.containsKey('profiles'), isFalse);
      }
    });
  });

  group('per-device visibility', () {
    test('hidden profiles leave the picker set, the admin never can, '
        'and a hidden auto-login profile does not auto-select',
        () async {
      final store = ProfileStore.instance;
      await store.ensureLoaded();
      final kid = await store.create(name: 'Ellie', kind: ProfileKind.kid);
      await store.create(name: 'Mum', kind: ProfileKind.adult);
      await store.setAutoLogin(kid.id);
      await store.setHidden(kid.id, true);
      expect(store.isHidden(kid.id), isTrue);
      expect(store.visibleProfiles.map((p) => p.name),
          isNot(contains('Ellie')));

      await store.setHidden(kAdminProfileId, true);
      expect(store.visibleProfiles.map((p) => p.id),
          contains(kAdminProfileId));

      // A fresh launch: the hidden auto-login profile must NOT silently
      // open on this device — the picker asks instead.
      ProfileStore.instance = ProfileStore();
      await ProfileStore.instance.ensureLoaded();
      expect(ProfileStore.instance.hasActive, isFalse);
    });
  });

  group('schema migration v18', () {
    test('a v17 profiles table gains the sync stamp and sync id',
        () async {
      final dir = await Directory.systemTemp.createTemp('watchit-v18');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/watchit.sqlite');
      final raw = sqlite3.open(file.path);
      raw.execute('''
        CREATE TABLE profiles (
          id TEXT NOT NULL,
          name TEXT NOT NULL,
          kind TEXT NOT NULL,
          avatar TEXT NULL,
          pin_hash TEXT NULL,
          auto_login INTEGER NOT NULL DEFAULT 0,
          position INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (id));
        INSERT INTO profiles (id, name, kind) VALUES ('admin', 'Admin', 'admin');
        INSERT INTO profiles (id, name, kind) VALUES ('pkid1', 'Ellie', 'kid');
        PRAGMA user_version = 17;
      ''');
      raw.close();

      await LibraryStore.useForTesting(
          AppDatabase.forTesting(NativeDatabase(file)));
      ProfileStore.instance = ProfileStore();
      final store = ProfileStore.instance;
      await store.ensureLoaded();
      final kid = store.profiles.firstWhere((p) => p.id == 'pkid1');
      expect(kid.updatedMs, 0);
      expect(kid.syncId, isNull);
      // Edits stamp, publishes mint.
      await store.updateProfile(kid.copyWith(name: 'Ellie B'));
      await store.ensureSyncIds();
      final after = store.profiles.firstWhere((p) => p.id == 'pkid1');
      expect(after.updatedMs, greaterThan(0));
      expect(after.syncId, isNotNull);
    });
  });

  group('full cycle', () {
    late FakeEmbeddedHttp fake;
    late Directory tempDir;
    late MyWatchSync sync;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('wi-profile-cycle');
      Directory('${tempDir.path}/posters').createSync();
      MyWatchSync.statePathOverride = '${tempDir.path}/sync_state.json';
      MyWatchSync.postersDirOverride =
          () async => Directory('${tempDir.path}/posters');
      ProfileStore.postersDirProvider =
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
            'name': 'phone',
            'platform': 'android',
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
      ProfileStore.postersDirProvider = null;
      tempDir.deleteSync(recursive: true);
    });

    test('a phone-made kid profile lands whole — avatar bytes included — '
        'and the republish carries our own profiles section', () async {
      final avatarBytes = List<int>.generate(4000, (i) => i % 251);
      final sha = crypto.sha256.convert(avatarBytes).toString();
      final served = File('${tempDir.path}/incoming_avatar')
        ..writeAsBytesSync(avatarBytes);
      fake.myWatchArtFiles = {sha: served.path};
      fake.myWatchSyncDevices = [
        {
          'agent_id': 'bb' * 32,
          'doc': {
            'v': 1,
            'lists': [
              {
                'title': 'Movies',
                'entries': [
                  {'name': 'A.mkv', 'address': _addr(1), 'added_ms': 1000},
                ],
              },
            ],
            'profiles': {
              'v': 1,
              'items': {
                'sid-ellie': {
                  'name': 'Ellie',
                  'kind': 'kid',
                  'updated_ms': 5000,
                  'art': {'sha256': sha, 'size': avatarBytes.length},
                  'allow': ['Movies'],
                },
              },
              'watch': {
                'sid-ellie': [
                  {
                    'address': _addr(1),
                    'pos_ms': 90000,
                    'dur_ms': 600000,
                    'completed': false,
                    'updated_ms': 7000,
                  },
                ],
              },
            },
          },
          'maps': const {},
        },
      ];

      final summary = await sync.syncNow();
      expect(summary, contains('1 profile(s) updated'));

      final store = ProfileStore.instance;
      final kid = store.profiles.firstWhere((p) => p.isKid);
      expect(kid.name, 'Ellie');
      expect(kid.syncId, 'sid-ellie');
      // The kid sees the just-synced list.
      final lists = await LibraryStore.load();
      final movies = lists.firstWhere((l) => l.title == 'Movies');
      expect(await store.allowedListIds(kid.id), {movies.id});
      // The avatar bytes arrived over the art transfer, byte-identical,
      // stored under the LOCAL id.
      expect(kid.avatar, startsWith('profile_avatar_${kid.id}_'));
      final savedBytes =
          File('${tempDir.path}/posters/${kid.avatar}').readAsBytesSync();
      expect(crypto.sha256.convert(savedBytes).toString(), sha);
      // Her watch point followed her.
      final states = await WatchStateStore.instance.all(profileId: kid.id);
      expect(states.single.positionMs, 90000);

      // Our republished doc carries the profiles section: the admin
      // item, HER item (same sync id, same stamp) with the avatar
      // manifest we now also serve, and her watch states.
      expect(fake.myWatchSyncPublishes, isNotEmpty);
      final published = jsonDecode(fake.myWatchSyncPublishes.last)
          as Map<String, dynamic>;
      final sec = ((published['doc'] as Map)['profiles'] as Map)
          .cast<String, dynamic>();
      final items = (sec['items'] as Map).cast<String, dynamic>();
      expect(items.keys, containsAll([kProfileAdminKey, 'sid-ellie']));
      final ellie = items['sid-ellie'] as Map;
      expect(ellie['updated_ms'], 5000);
      expect((ellie['art'] as Map)['sha256'], sha);
      expect(((sec['watch'] as Map)['sid-ellie'] as List), hasLength(1));
      // And the art index we handed the client serves her avatar.
      expect(fake.myWatchArtIndexPosts.last, contains(sha));

      // A second cycle: nothing new.
      final again = await sync.syncNow();
      expect(again, 'Everything is in sync.');
    });

    test('deleting the profile here publishes the tombstone that removes '
        'it everywhere', () async {
      final store = ProfileStore.instance;
      await store.ensureLoaded();
      await store.create(
          name: 'Ellie', kind: ProfileKind.kid, syncId: 'sid-ellie',
          updatedMs: 5000);
      final kid = store.profiles.firstWhere((p) => p.isKid);
      await store.deleteProfile(kid.id);

      await sync.syncNow();
      final published = jsonDecode(fake.myWatchSyncPublishes.last)
          as Map<String, dynamic>;
      final sec = ((published['doc'] as Map)['profiles'] as Map)
          .cast<String, dynamic>();
      final removed = (sec['removed'] as Map).cast<String, dynamic>();
      expect(removed['sid-ellie'], greaterThan(5000));
      expect((sec['items'] as Map).keys, [kProfileAdminKey]);
    });
  });
}
