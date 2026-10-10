import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/backup.dart';
import 'package:watchit/services/backup_follow.dart';
import 'package:watchit/services/embedded_client.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/services/my_watch_api.dart';
import 'package:watchit/services/my_watch_sync.dart';
import 'package:watchit/services/profiles.dart';
import 'package:watchit/services/watch_state.dart';

import 'fake_embedded_http.dart';

String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late FakeEmbeddedHttp fake;
  late Directory tempDir;
  late BackupService backupService;
  late BackupFollowService follow;
  ClientHealth health = const ClientHealth(state: 'ready', peers: 5);

  final ptrA = 'ab' * 32;
  final keyA = 'cd' * 32;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'defaults_seeded_v4': true});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    WatchStateStore.instance = WatchStateStore();
    ProfileStore.onSwitch = null;
    ProfileStore.instance = ProfileStore();
    tempDir = Directory.systemTemp.createTempSync('wi-backup-follow');
    Directory('${tempDir.path}/posters').createSync();
    Directory('${tempDir.path}/staging').createSync();
    BackupService.postersDirOverride =
        () async => Directory('${tempDir.path}/posters');
    BackupService.stagingDirOverride =
        () async => Directory('${tempDir.path}/staging');
    ProfileStore.postersDirProvider =
        () async => Directory('${tempDir.path}/posters');
    BackupFollowService.statePathOverride =
        '${tempDir.path}/backup_follow.json';
    MetadataService.instance = MetadataService(
      postersDirProvider: () async => Directory('${tempDir.path}/posters'),
      apiKeyProvider: () async => '',
      httpClient: MockClient((req) async => http.Response('{}', 404)),
    );
    fake = FakeEmbeddedHttp();
    HttpOverrides.global = fake;
    health = const ClientHealth(state: 'ready', peers: 5);
    backupService = BackupService(
      api: BackupApi(base: FakeEmbeddedHttp.base, token: 't'),
      pollInterval: const Duration(milliseconds: 1),
    );
    follow = BackupFollowService(
      api: BackupApi(base: FakeEmbeddedHttp.base, token: 't'),
      backup: backupService,
      health: () async => health,
    );
    BackupFollowService.status.value = const BackupFollowStatus();
    BackupService.onBackupPublished = null;
  });

  tearDown(() {
    HttpOverrides.global = null;
    BackupService.postersDirOverride = null;
    BackupService.stagingDirOverride = null;
    ProfileStore.postersDirProvider = null;
    BackupFollowService.statePathOverride = null;
    BackupService.onBackupPublished = null;
    tempDir.deleteSync(recursive: true);
  });

  Map<String, dynamic> stateOnDisk() => jsonDecode(
          File('${tempDir.path}/backup_follow.json').readAsStringSync())
      as Map<String, dynamic>;

  RemoteSyncDoc docWith(Map<String, dynamic>? backup,
          {String agent = 'aa'}) =>
      RemoteSyncDoc(agentId: agent * 32, doc: {
        'v': 1,
        'lists': const [],
        'backup': ?backup,
      }, maps: const {});

  group('sectionForPublish', () {
    test('null without a wallet, null before the first backup, and the '
        'shared read keys once one exists', () async {
      expect(await follow.sectionForPublish(), isNull);
      fake.backupStatus = {
        'configured': true,
        'pointer': ptrA,
        'key': keyA,
        'last': null,
        'job': null,
      };
      expect(await follow.sectionForPublish(), isNull);
      fake.backupStatus = {
        ...fake.backupStatus,
        'last': {'ms': 123456, 'backups': 3, 'objects': 5, 'uploaded': 1},
      };
      expect(await follow.sectionForPublish(), {
        'v': 1,
        'ptr': ptrA,
        'key': keyA,
        'ms': 123456,
        'n': 3,
      });
    });
  });

  group('adopting shared keys', () {
    test('newest valid section wins, junk is skipped, keys land in the '
        'keychain store (never the state file), and adoption checks the '
        'pointer immediately', () async {
      await follow.noteRemoteDocs([
        docWith({'v': 1, 'ptr': 'nothex', 'key': keyA, 'ms': 999}),
        docWith({'v': 1, 'ptr': ptrA, 'key': keyA, 'ms': 500, 'n': 2}),
        docWith({'v': 1, 'ptr': _addr(7), 'key': _addr(8), 'ms': 100}),
        docWith(null),
      ]);
      // The read keys go to the core's keychain store…
      expect(fake.followKeys, {'ptr': ptrA, 'key': keyA});
      // …and the plain state file holds only non-secret bookkeeping.
      final state = stateOnDisk();
      expect(state.containsKey('ptr'), isFalse);
      expect(state.containsKey('key'), isFalse);
      expect(state['shared_ms'], 500);
      // The adoption ran a check right away: one free pointer peek, and
      // (nothing published yet) no follow fetch.
      expect(fake.backupPeekPosts, hasLength(1));
      expect(jsonDecode(fake.backupPeekPosts.single), {'ptr': ptrA});
      expect(fake.backupFollowPosts, isEmpty);
      expect(BackupFollowService.status.value.following, isTrue);
    });

    test('a fresh instance loads the keys back from the keychain store, '
        'and a legacy plaintext state file migrates into it', () async {
      // Keys already in the keychain (an earlier session adopted them).
      fake.followKeys = {'ptr': ptrA, 'key': keyA};
      await follow.initialize();
      expect(BackupFollowService.status.value.following, isTrue);
      final outcome = await follow.checkNow();
      expect(outcome, contains('No backup published'));
      expect(jsonDecode(fake.backupPeekPosts.single), {'ptr': ptrA});

      // Legacy migration: a pre-keychain state file still carrying the
      // plaintext pair hands it to the keychain and strips the file.
      fake.followKeys = null;
      File('${tempDir.path}/backup_follow.json')
          .writeAsStringSync(jsonEncode({
        'ptr': _addr(7),
        'key': _addr(8),
        'shared_ms': 700,
      }));
      final fresh = BackupFollowService(
        api: BackupApi(base: FakeEmbeddedHttp.base, token: 't'),
        backup: backupService,
        health: () async => health,
      );
      await fresh.initialize();
      expect(fake.followKeys, {'ptr': _addr(7), 'key': _addr(8)});
      final state = stateOnDisk();
      expect(state.containsKey('ptr'), isFalse);
      expect(state.containsKey('key'), isFalse);
      expect(state['shared_ms'], 700);
      expect(BackupFollowService.status.value.following, isTrue);
    });

    test('never follows this device\'s own backup line', () async {
      fake.backupStatus = {
        'configured': true,
        'pointer': ptrA,
        'key': keyA,
        'last': null,
        'job': null,
      };
      await follow.noteRemoteDocs([
        docWith({'v': 1, 'ptr': ptrA, 'key': keyA, 'ms': 500}),
      ]);
      expect(File('${tempDir.path}/backup_follow.json').existsSync(),
          isFalse);
      expect(fake.backupPeekPosts, isEmpty);
    });

    test('an unchanged record does not re-check; a newer stamp does',
        () async {
      final record = {'v': 1, 'ptr': ptrA, 'key': keyA, 'ms': 500};
      await follow.noteRemoteDocs([docWith(record)]);
      expect(fake.backupPeekPosts, hasLength(1));
      await follow.noteRemoteDocs([docWith(record)]);
      expect(fake.backupPeekPosts, hasLength(1));
      await follow.noteRemoteDocs([
        docWith({...record, 'ms': 600}),
      ]);
      expect(fake.backupPeekPosts, hasLength(2));
    });
  });

  group('checkNow', () {
    test('without shared keys there is nothing to do', () async {
      final outcome = await follow.checkNow();
      expect(outcome, contains('Not following'));
      expect(fake.backupPeekPosts, isEmpty);
    });

    test('waits for the network instead of peeking blind', () async {
      health = const ClientHealth(state: 'connecting');
      await follow.noteRemoteDocs([
        docWith({'v': 1, 'ptr': ptrA, 'key': keyA, 'ms': 500}),
      ]);
      final outcome = await follow.checkNow();
      expect(outcome, contains('network'));
      expect(fake.backupPeekPosts, isEmpty);
    });

    test('fetches only when the head moved, folds the backup in, and '
        'records the applied head', () async {
      await LibraryStore.save([
        MediaList(id: 'l1', title: 'Movies', entries: [
          MediaEntry(name: 'Held.mp4', address: _addr(9), addedAt: 1),
        ]),
      ]);
      await ProfileStore.instance.ensureLoaded();
      fake.backupPeek = {'found': true, 'head': 'ee' * 32, 'counter': 4};
      fake.backupJobStates.add({
        'kind': 'follow',
        'phase': 'done',
        'result': {
          'created_ms': 50000,
          'head': 'ee' * 32,
          'doc': {
            'v': 1,
            'lists': [
              {
                'title': 'Movies',
                'entries': [
                  {
                    'name': 'From Backup (2021).mp4',
                    'address': _addr(1),
                    'added_ms': 2000,
                  },
                ],
              },
            ],
            'watch': [
              {
                'address': _addr(1),
                'pos_ms': 60000,
                'dur_ms': 90000,
                'completed': false,
                'updated_ms': 999,
              },
            ],
          },
          'maps_imported': 1,
          'maps_failed': 0,
          'art_files': const [],
          'art_failed': 0,
        },
      });
      await follow.noteRemoteDocs([
        docWith({'v': 1, 'ptr': ptrA, 'key': keyA, 'ms': 500}),
      ]);

      // The adoption's check fetched and folded the backup.
      final posted =
          jsonDecode(fake.backupFollowPosts.single) as Map<String, dynamic>;
      expect(posted['ptr'], ptrA);
      expect(posted['key'], keyA);
      expect(posted['art_dir'], '${tempDir.path}/staging');
      final lists = await LibraryStore.load();
      final movies = lists.singleWhere((l) => l.title == 'Movies');
      expect(movies.entries.map((e) => e.address),
          containsAll([_addr(9), _addr(1)]));
      final states = await WatchStateStore.instance.all();
      expect(states.single.positionMs, 60000);
      expect(stateOnDisk()['applied_head'], 'ee' * 32);
      expect(BackupFollowService.status.value.lastSummary,
          contains('1 added'));

      // Same head again: one more free peek, no second fetch.
      final outcome = await follow.checkNow();
      expect(outcome, contains('Already caught up'));
      expect(fake.backupPeekPosts, hasLength(2));
      expect(fake.backupFollowPosts, hasLength(1));
    });

    test('an unpublished backup line stays quiet', () async {
      await follow.noteRemoteDocs([
        docWith({'v': 1, 'ptr': ptrA, 'key': keyA, 'ms': 500}),
      ]);
      final outcome = await follow.checkNow();
      expect(outcome, contains('No backup published'));
      expect(fake.backupFollowPosts, isEmpty);
      expect(stateOnDisk()['last_check_ms'], isNotNull);
    });
  });

  group('automatic backup', () {
    Future<void> configureMaster({int lastMs = 0}) async {
      fake.backupStatus = {
        'configured': true,
        'pointer': ptrA,
        'key': keyA,
        'last': lastMs == 0
            ? null
            : {'ms': lastMs, 'backups': 1, 'objects': 2, 'uploaded': 1},
        'job': null,
      };
      fake.backupJobStates.add({
        'kind': 'backup',
        'phase': 'done',
        'result': {'objects': 2, 'uploaded': 1, 'backups': 2},
      });
      await LibraryStore.save([
        MediaList(id: 'l1', title: 'Movies', entries: [
          MediaEntry(name: 'Mine.mp4', address: _addr(3), addedAt: 1),
        ]),
      ]);
      await ProfileStore.instance.ensureLoaded();
    }

    test('off by default — never spends without the opt-in', () async {
      await configureMaster();
      expect(await follow.maybeAutoBackup(), isFalse);
      expect(fake.backupRunPosts, isEmpty);
    });

    test('runs when enabled, due and changed; skips when unchanged or '
        'recent', () async {
      SharedPreferences.setMockInitialValues({
        'defaults_seeded_v4': true,
        'backup_auto_v1': true,
      });
      BackupService.onBackupPublished = follow.noteBackupPublished;
      await configureMaster();
      final now = DateTime.now().millisecondsSinceEpoch;

      // Due (never backed up) and changed → runs, and the published
      // fingerprint is recorded through the hook.
      expect(await follow.maybeAutoBackup(nowMs: now), isTrue);
      expect(fake.backupRunPosts, hasLength(1));
      expect(stateOnDisk()['last_backup_fp'], isNotNull);

      // Unchanged state → skipped even though it is overdue.
      fake.backupStatus = {
        ...fake.backupStatus,
        'last': {'ms': 1000, 'backups': 2, 'objects': 2, 'uploaded': 1},
      };
      expect(await follow.maybeAutoBackup(nowMs: now), isFalse);
      expect(fake.backupRunPosts, hasLength(1));

      // Changed state, but the last backup is fresh → waits out the day.
      await LibraryStore.save([
        MediaList(id: 'l1', title: 'Movies', entries: [
          MediaEntry(name: 'Mine.mp4', address: _addr(3), addedAt: 1),
          MediaEntry(name: 'New.mp4', address: _addr(4), addedAt: 2),
        ]),
      ]);
      fake.backupStatus = {
        ...fake.backupStatus,
        'last': {'ms': now - 1000, 'backups': 2, 'objects': 2, 'uploaded': 1},
      };
      expect(await follow.maybeAutoBackup(nowMs: now), isFalse);

      // Due again and changed → runs again.
      fake.backupStatus = {
        ...fake.backupStatus,
        'last': {
          'ms': now - BackupFollowService.autoMinIntervalMs - 1,
          'backups': 2,
          'objects': 2,
          'uploaded': 1,
        },
      };
      fake.backupJobStates.add({
        'kind': 'backup',
        'phase': 'done',
        'result': {'objects': 3, 'uploaded': 1, 'backups': 3},
      });
      expect(await follow.maybeAutoBackup(nowMs: now), isTrue);
      expect(fake.backupRunPosts, hasLength(2));
    });

    test('a follower (no wallet) never auto-backs-up', () async {
      SharedPreferences.setMockInitialValues({
        'defaults_seeded_v4': true,
        'backup_auto_v1': true,
      });
      expect(await follow.maybeAutoBackup(), isFalse);
      expect(fake.backupRunPosts, isEmpty);
    });
  });

  group('payloadFingerprint', () {
    test('ignores the build stamp, tracks the content', () {
      final a = BackupService.payloadFingerprint({
        'doc': {'v': 1, 'updated_ms': 111, 'lists': const []},
        'art': const [],
        'map_addrs': const [],
      });
      final b = BackupService.payloadFingerprint({
        'doc': {'v': 1, 'updated_ms': 222, 'lists': const []},
        'art': const [],
        'map_addrs': const [],
      });
      final c = BackupService.payloadFingerprint({
        'doc': {
          'v': 1,
          'updated_ms': 111,
          'lists': [
            {'title': 'Movies'},
          ],
        },
        'art': const [],
        'map_addrs': const [],
      });
      expect(a, b);
      expect(a, isNot(c));
    });
  });

  group('sync-doc plumbing', () {
    test('the backup section rides doc part 0 only and is never trimmed',
        () {
      final section = {'v': 1, 'ptr': ptrA, 'key': keyA, 'ms': 5, 'n': 1};
      final built = MyWatchSync.buildDocParts(
        lists: [
          MediaList(id: 'l1', title: 'Movies', entries: [
            for (var i = 0; i < 900; i++)
              MediaEntry(
                  name: 'Movie $i with a long padded name.mp4',
                  address: _addr(i + 1),
                  addedAt: i + 1),
          ]),
        ],
        tombstones: const {},
        watchStates: const [],
        nowMs: 1000,
        backupSection: section,
      );
      expect(built.parts.length, greaterThan(1));
      expect(built.parts.first['backup'], section);
      for (final p in built.parts.skip(1)) {
        expect(p.containsKey('backup'), isFalse);
      }
    });

    test('a full cycle publishes the section and hands remote docs to '
        'the follower', () async {
      fake.myWatchStatus = {
        'supported': true,
        'linked': true,
        'state': 'ready',
        'enabled': true,
        'devices': const [],
      };
      fake.backupStatus = {
        'configured': true,
        'pointer': _addr(7),
        'key': _addr(8),
        'last': {'ms': 42, 'backups': 1, 'objects': 1, 'uploaded': 1},
        'job': null,
      };
      // A remote device shares DIFFERENT keys for us to adopt.
      fake.myWatchSyncDevices = [
        {
          'agent_id': 'bb' * 32,
          'doc': {
            'v': 1,
            'lists': const [],
            'backup': {'v': 1, 'ptr': ptrA, 'key': keyA, 'ms': 900},
          },
          'maps': const {},
        },
      ];
      MyWatchSync.statePathOverride = '${tempDir.path}/mywatch_sync.json';
      MyWatchSync.postersDirOverride =
          () async => Directory('${tempDir.path}/posters');
      addTearDown(() {
        MyWatchSync.statePathOverride = null;
        MyWatchSync.postersDirOverride = null;
      });
      final sync = MyWatchSync(
        api: MyWatchApi(base: FakeEmbeddedHttp.base, token: 't'),
        health: () async => health,
        clientBase: FakeEmbeddedHttp.base,
      );
      final seen = <List<RemoteSyncDoc>>[];
      sync.onRemoteDocs = seen.add;
      sync.backupSectionProvider = follow.sectionForPublish;
      await ProfileStore.instance.ensureLoaded();

      await sync.cycleForTesting();

      // Publish side: our doc carries our own shared keys.
      final published = jsonDecode(fake.myWatchSyncPublishes.single)
          as Map<String, dynamic>;
      expect((published['doc'] as Map)['backup'], {
        'v': 1,
        'ptr': _addr(7),
        'key': _addr(8),
        'ms': 42,
        'n': 1,
      });
      // Follower side: the cycle handed the remote docs over.
      expect(seen.single.single.doc['backup'], isNotNull);
    });
  });

  group('backup-first bootstrap gate', () {
    String statePath() => '${tempDir.path}/backup_follow.json';

    Future<void> seedKeys({String? appliedHead}) async {
      fake.followKeys = {'ptr': ptrA, 'key': keyA};
      File(statePath()).writeAsStringSync(jsonEncode({
        'shared_ms': 900,
        'applied_head': appliedHead,
      }));
      await follow.initialize();
    }

    test('never activates without keys or a shared section in sight',
        () async {
      expect(follow.deferGossipMergeFor(const []), isFalse);
      expect(follow.deferGossipMergeFor([docWith(null)]), isFalse);
    });

    test('activates on a shared section and resolves for good once the '
        'first check answers', () async {
      final docs = [
        docWith({'v': 1, 'ptr': ptrA, 'key': keyA, 'ms': 900}),
      ];
      expect(follow.deferGossipMergeFor(docs), isTrue);
      // The adoption the sync cycle runs in parallel: the peek answers
      // found:false — a terminal outcome, live sync takes over.
      await follow.noteRemoteDocs(docs);
      expect(follow.deferGossipMergeFor(docs), isFalse);
      expect(follow.deferGossipMergeFor(const []), isFalse);
    });

    test('a junk-only section never activates the gate', () async {
      expect(
        follow.deferGossipMergeFor([
          docWith({'v': 1, 'ptr': 'nothex', 'key': keyA, 'ms': 900}),
          docWith({'v': 1, 'ptr': ptrA, 'key': keyA, 'ms': 0}),
        ]),
        isFalse,
      );
    });

    test('a device that already folded this backup in never defers',
        () async {
      await seedKeys(appliedHead: 'ee' * 32);
      expect(follow.deferGossipMergeFor(const []), isFalse);
    });

    test('the deadline ends the deferral even when the check cannot '
        'finish', () async {
      health = const ClientHealth(state: 'connecting', peers: 0);
      await seedKeys();
      expect(follow.deferGossipMergeFor(const [], nowMs: 1000), isTrue);
      expect(
        follow.deferGossipMergeFor(const [],
            nowMs: 1000 + BackupFollowService.bootstrapGateMs),
        isFalse,
      );
      // Resolved is forever — an earlier clock never re-arms it.
      expect(follow.deferGossipMergeFor(const [], nowMs: 1000), isFalse);
      // Let the kicked background check (which only waited for the
      // network) finish before teardown.
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });

    test('a failed first follow resolves the gate', () async {
      await seedKeys();
      fake.backupPeek = {'found': true, 'head': 'ee' * 32, 'counter': 2};
      fake.backupJobStates.add({
        'kind': 'follow',
        'phase': 'error',
        'error': 'chunk fetch failed',
      });
      await expectLater(follow.checkNow(), throwsA(anything));
      expect(follow.deferGossipMergeFor(const [], nowMs: 1), isFalse);
    });

    test('a gated sync cycle publishes without merging, then merges once '
        'the follower resolved', () async {
      fake.myWatchStatus = {
        'supported': true,
        'linked': true,
        'state': 'ready',
        'enabled': true,
        'devices': const [],
      };
      // The remote device shares both a library entry AND its backup
      // read keys: the first cycle must hold the entry back.
      fake.myWatchSyncDevices = [
        {
          'agent_id': 'bb' * 32,
          'doc': {
            'v': 1,
            'lists': [
              {
                'title': 'Movies',
                'entries': [
                  {
                    'name': 'Remote.mp4',
                    'address': _addr(2),
                    'added_ms': 2000,
                  },
                ],
              },
            ],
            'backup': {'v': 1, 'ptr': ptrA, 'key': keyA, 'ms': 900},
          },
          'maps': const {},
        },
      ];
      MyWatchSync.statePathOverride = '${tempDir.path}/mywatch_sync.json';
      MyWatchSync.postersDirOverride =
          () async => Directory('${tempDir.path}/posters');
      addTearDown(() {
        MyWatchSync.statePathOverride = null;
        MyWatchSync.postersDirOverride = null;
      });
      final sync = MyWatchSync(
        api: MyWatchApi(base: FakeEmbeddedHttp.base, token: 't'),
        health: () async => health,
        clientBase: FakeEmbeddedHttp.base,
      );
      sync.onRemoteDocs = follow.noteRemoteDocs;
      sync.bootstrapGate = follow.deferGossipMergeFor;
      await ProfileStore.instance.ensureLoaded();

      final first = await sync.cycleForTesting();
      expect(first?.bootstrapDeferred, isTrue);
      expect(first?.entriesAdded, 0);
      // Nothing merged — but our own state still went out.
      var lists = await LibraryStore.load();
      expect(lists.where((l) => l.title == 'Movies'), isEmpty);
      expect(fake.myWatchSyncPublishes, isNotEmpty);
      expect(
        MyWatchSync.summarize(first!),
        contains('shared backup first'),
      );

      // The parallel adoption's check answered (no backup published) —
      // make the resolution deterministic, then the next cycle merges.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await follow.checkNow();
      final second = await sync.cycleForTesting();
      expect(second?.bootstrapDeferred, isFalse);
      expect(second?.entriesAdded, 1);
      lists = await LibraryStore.load();
      expect(
        lists.firstWhere((l) => l.title == 'Movies').entries.single.address,
        _addr(2),
      );
    });
  });
}
