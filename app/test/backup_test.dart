import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/screens/backup_screen.dart';
import 'package:watchit/services/app_settings.dart';
import 'package:watchit/services/backup.dart';
import 'package:watchit/services/backup_follow.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/my_watch_api.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/services/profiles.dart';
import 'package:watchit/services/user_metadata.dart';
import 'package:watchit/services/watch_state.dart';
import 'package:watchit/theme/tokens.dart';

import 'fake_embedded_http.dart';

String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late FakeEmbeddedHttp fake;
  late Directory tempDir;
  late BackupService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'defaults_seeded_v4': true});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    WatchStateStore.instance = WatchStateStore();
    ProfileStore.onSwitch = null;
    ProfileStore.instance = ProfileStore();
    tempDir = Directory.systemTemp.createTempSync('wi-backup');
    Directory('${tempDir.path}/posters').createSync();
    Directory('${tempDir.path}/staging').createSync();
    BackupService.postersDirOverride =
        () async => Directory('${tempDir.path}/posters');
    BackupService.stagingDirOverride =
        () async => Directory('${tempDir.path}/staging');
    ProfileStore.postersDirProvider =
        () async => Directory('${tempDir.path}/posters');
    MetadataService.instance = MetadataService(
      postersDirProvider: () async => Directory('${tempDir.path}/posters'),
      apiKeyProvider: () async => '',
      httpClient: MockClient((req) async => http.Response('{}', 404)),
    );
    fake = FakeEmbeddedHttp();
    HttpOverrides.global = fake;
    service = BackupService(
      api: BackupApi(base: FakeEmbeddedHttp.base, token: 't'),
      pollInterval: const Duration(milliseconds: 1),
    );
  });

  tearDown(() {
    HttpOverrides.global = null;
    BackupService.postersDirOverride = null;
    BackupService.stagingDirOverride = null;
    ProfileStore.postersDirProvider = null;
    tempDir.deleteSync(recursive: true);
  });

  File poster(String name, List<int> bytes) =>
      File('${tempDir.path}/posters/$name')..writeAsBytesSync(bytes);

  group('buildPayload', () {
    test('carries the whole state: entries, uncapped watch states, edits, '
        'TMDB rows, profiles, art and map addresses', () async {
      await LibraryStore.save([
        MediaList(id: 'l1', title: 'Movies', entries: [
          MediaEntry(name: 'Custom (2020).mp4', address: _addr(1), addedAt: 5),
        ]),
        MediaList(id: 'l2', title: 'Shows', entries: [
          MediaEntry(name: 'Show S01E02.mkv', address: _addr(2), addedAt: 6),
        ]),
      ]);
      // 305 watch states — past the sync doc's 300 cap, which a backup
      // must ignore (it has no byte budget).
      await WatchStateStore.instance.mergeAll([
        for (var i = 0; i < 305; i++)
          WatchState(
            address: _addr(100 + i),
            positionMs: 1000 + i,
            durationMs: 60000,
            completed: false,
            updatedAt: 1000 + i,
          ),
      ]);
      // A user edit with artwork.
      final artBytes = List<int>.generate(900, (i) => i % 251);
      final artName = await saveUserPoster(
          'movie:custom:2020', Uint8List.fromList(artBytes),
          postersDirProvider: BackupService.postersDirOverride);
      await saveUserDetails(
        lookupKey: 'movie:custom:2020',
        title: 'Custom, Renamed',
        year: 2020,
        overview: 'my words',
        posterFile: Value(artName),
        postersDirProvider: BackupService.postersDirOverride,
      );
      // A TMDB row for the episode, with a shared poster file.
      poster('tv_9_s1.jpg', [1, 2, 3, 4]);
      await applyRemoteTmdbDetails(
        lookupKey: 'tv:show::s1:e2',
        updatedMs: 777,
        title: 'Show',
        mediaType: 'tv',
        tmdbId: 9,
        posterFile: 'tv_9_s1.jpg',
      );
      // A kid profile with a file avatar and her own watch point.
      final store = ProfileStore.instance;
      await store.ensureLoaded();
      final kid = await store.create(name: 'Ellie', kind: ProfileKind.kid);
      final avatar = await ProfileStore.saveAvatarImage(
          kid.id, Uint8List.fromList(List.filled(64, 7)));
      await store.updateProfile(kid.copyWith(avatar: avatar));
      await WatchStateStore.instance.mergeAll([
        WatchState(
            address: _addr(2),
            positionMs: 123,
            durationMs: 456,
            completed: false,
            updatedAt: 42),
      ], profileId: kid.id);

      final payload = await service.buildPayload();
      final doc = payload['doc'] as Map<String, dynamic>;
      final lists = doc['lists'] as List;
      expect(lists, hasLength(2));
      expect(((lists[0] as Map)['entries'] as List), hasLength(1));
      expect((doc['watch'] as List), hasLength(305));
      final meta = doc['meta'] as Map<String, dynamic>;
      final metaRow = (meta['rows'] as List).single as Map<String, dynamic>;
      expect(metaRow['key'], 'movie:custom:2020');
      expect(metaRow['title'], 'Custom, Renamed');
      expect((metaRow['art'] as Map)['sha256'],
          crypto.sha256.convert(artBytes).toString());
      final tmdb = doc['tmdb'] as Map<String, dynamic>;
      final tmdbRow = (tmdb['rows'] as List).single as Map<String, dynamic>;
      expect(tmdbRow['key'], 'tv:show::s1:e2');
      expect((tmdb['files'] as Map).keys, contains('tv_9_s1.jpg'));
      final profiles = doc['profiles'] as Map<String, dynamic>;
      expect((profiles['items'] as Map).length, 2); // admin + Ellie
      expect((profiles['watch'] as Map).length, 1);
      final artFiles = {
        for (final a in payload['art'] as List) (a as Map)['file'] as String,
      };
      expect(artFiles, containsAll([artName, 'tv_9_s1.jpg', avatar]));
      expect(payload['map_addrs'], containsAll([_addr(1), _addr(2)]));
    });
  });

  group('runBackup', () {
    test('posts the payload and polls the job to its summary', () async {
      await LibraryStore.save([
        MediaList(id: 'l1', title: 'Movies', entries: [
          MediaEntry(name: 'Custom (2020).mp4', address: _addr(1)),
        ]),
      ]);
      await ProfileStore.instance.ensureLoaded();
      fake.backupJobStates.addAll([
        {'kind': 'backup', 'phase': 'uploading', 'done': 1, 'total': 3},
        {
          'kind': 'backup',
          'phase': 'done',
          'done': 3,
          'total': 3,
          'result': {
            'objects': 3,
            'uploaded': 2,
            'backups': 4,
            'maps_missing': 1,
          },
        },
      ]);
      final seen = <String>[];
      final summary =
          await service.runBackup(onProgress: (j) => seen.add(j.phase));
      expect(summary.objects, 3);
      expect(summary.uploaded, 2);
      expect(summary.backups, 4);
      expect(summary.mapsMissing, 1);
      expect(seen, containsAllInOrder(['uploading', 'done']));
      final posted =
          jsonDecode(fake.backupRunPosts.single) as Map<String, dynamic>;
      expect(posted['doc'], isA<Map<String, dynamic>>());
      expect(posted['map_addrs'], contains(_addr(1)));
    });

    test('a failed job surfaces the server error', () async {
      await ProfileStore.instance.ensureLoaded();
      fake.backupJobStates.add({
        'kind': 'backup',
        'phase': 'error',
        'error': 'updating the backup pointer failed: out of gas',
      });
      await expectLater(
        service.runBackup(),
        throwsA(predicate(
            (e) => e is BackupException && e.message.contains('out of gas'))),
      );
    });
  });

  group('restore', () {
    test('merges the whole backup: entries, watch points, profiles with '
        'avatar, detail edits with artwork, TMDB rows and files', () async {
      await LibraryStore.save([
        MediaList(id: 'l1', title: 'Movies', entries: [
          MediaEntry(name: 'Held (2019).mp4', address: _addr(9), addedAt: 1),
        ]),
      ]);
      await ProfileStore.instance.ensureLoaded();

      final userArt = List<int>.generate(700, (i) => (i * 7) % 251);
      final userArtSha = crypto.sha256.convert(userArt).toString();
      final avatarBytes = List<int>.generate(80, (i) => (i * 3) % 251);
      final avatarSha = crypto.sha256.convert(avatarBytes).toString();
      fake.onBackupRestore = (artDir) {
        File('$artDir/user_movie_custom_2020_ab12_5.jpg')
            .writeAsBytesSync(userArt);
        File('$artDir/movie_7.jpg').writeAsBytesSync([9, 9, 9]);
        File('$artDir/profile_avatar_pX_7.img').writeAsBytesSync(avatarBytes);
      };
      final doc = {
        'v': 1,
        'updated_ms': 50000,
        'lists': [
          {
            'title': 'Movies',
            'entries': [
              {'name': 'Restored (2021).mp4', 'address': _addr(1), 'added_ms': 10},
            ],
          },
        ],
        'have': const <String>[],
        'watch': [
          {
            'address': _addr(1),
            'pos_ms': 60000,
            'dur_ms': 120000,
            'completed': false,
            'updated_ms': 999,
          },
        ],
        'meta': {
          'v': 1,
          'rows': [
            {
              'key': 'movie:custom:2020',
              'updated_ms': 888,
              'title': 'Custom, Edited',
              'year': 2020,
              'overview': 'from the backup',
              'art': {'sha256': userArtSha, 'size': userArt.length},
            },
          ],
        },
        'tmdb': {
          'v': 1,
          'rows': [
            {
              'key': 'movie:restored:2021',
              'updated_ms': 777,
              'title': 'Restored',
              'type': 'movie',
              'tmdb_id': 7,
              'poster': 'movie_7.jpg',
            },
          ],
          'files': {
            'movie_7.jpg': {'sha256': 'ab' * 32, 'size': 3},
          },
        },
        'profiles': {
          'v': 1,
          'items': {
            'sid-ellie': {
              'name': 'Ellie',
              'kind': 'kid',
              'updated_ms': 500,
              'art': {'sha256': avatarSha, 'size': avatarBytes.length},
              'allow': ['Movies'],
            },
          },
          'watch': {
            'sid-ellie': [
              {
                'address': _addr(1),
                'pos_ms': 42,
                'dur_ms': 100,
                'completed': false,
                'updated_ms': 77,
              },
            ],
          },
        },
      };
      fake.backupJobStates.addAll([
        {'kind': 'restore', 'phase': 'fetching', 'done': 1, 'total': 3},
        {
          'kind': 'restore',
          'phase': 'done',
          'result': {
            'created_ms': 50000,
            'doc': doc,
            'maps_imported': 2,
            'maps_failed': 0,
            'art_files': [
              'user_movie_custom_2020_ab12_5.jpg',
              'movie_7.jpg',
              'profile_avatar_pX_7.img',
            ],
            'art_failed': 0,
          },
        },
      ]);

      final summary = await service.restore();

      // The restore posted a staging dir and cleaned it up afterwards.
      final posted =
          jsonDecode(fake.backupRestorePosts.single) as Map<String, dynamic>;
      expect(posted['art_dir'], '${tempDir.path}/staging');
      expect(posted.containsKey('key'), isFalse);
      expect(Directory('${tempDir.path}/staging').existsSync(), isFalse);

      // Lists: the backup entry joined the held list.
      final lists = await LibraryStore.load();
      final movies = lists.singleWhere((l) => l.title == 'Movies');
      expect(movies.entries.map((e) => e.address),
          containsAll([_addr(9), _addr(1)]));
      expect(summary.entriesAdded, 1);

      // Watch points: the admin's landed, the kid's landed on her
      // freshly created profile.
      final adminStates = await WatchStateStore.instance.all();
      expect(adminStates.any((s) => s.address == _addr(1) && s.positionMs == 60000),
          isTrue);
      final store = ProfileStore.instance;
      final ellie =
          store.profiles.where((p) => p.name == 'Ellie').single;
      expect(ellie.isKid, isTrue);
      final kidStates =
          await WatchStateStore.instance.all(profileId: ellie.id);
      expect(kidStates.single.positionMs, 42);
      expect(summary.profilesChanged, 1);
      // Her avatar bytes landed from staging under her local id.
      expect(ellie.avatar, isNotNull);
      expect(
          File('${tempDir.path}/posters/${ellie.avatar}')
              .readAsBytesSync(),
          avatarBytes);

      // Detail edit applied with its artwork.
      final row = await metadataRowFor('movie:custom:2020');
      expect(row!.userEdited, isTrue);
      expect(row.title, 'Custom, Edited');
      expect(row.fetchedAt, 888);
      expect(row.posterFile, startsWith('user_'));
      expect(File('${tempDir.path}/posters/${row.posterFile}').existsSync(),
          isTrue);
      expect(summary.detailsApplied, 1);

      // TMDB row + its shared artwork file under the original name.
      final tmdbRow = await metadataRowFor('movie:restored:2021');
      expect(tmdbRow!.userEdited, isFalse);
      expect(tmdbRow.tmdbId, 7);
      expect(File('${tempDir.path}/posters/movie_7.jpg').readAsBytesSync(),
          [9, 9, 9]);
      expect(summary.tmdbApplied, 1);
      expect(summary.artInstalled, 1);
      expect(summary.mapsImported, 2);
      expect(summary.problems, isEmpty);
    });

    test('a failed restore cleans the staging dir too', () async {
      await ProfileStore.instance.ensureLoaded();
      fake.backupJobStates.add({
        'kind': 'restore',
        'phase': 'error',
        'error': 'no backup found for this wallet',
      });
      await expectLater(
        service.restore(),
        throwsA(predicate((e) =>
            e is BackupException && e.message.contains('no backup found'))),
      );
      expect(Directory('${tempDir.path}/staging').existsSync(), isFalse);
    });

    test('never regresses newer local state (LWW guards hold)', () async {
      await LibraryStore.save([
        MediaList(id: 'l1', title: 'Movies', entries: [
          MediaEntry(name: 'Custom (2020).mp4', address: _addr(1), addedAt: 1),
        ]),
      ]);
      await ProfileStore.instance.ensureLoaded();
      // A local edit NEWER than the backup's row.
      await saveUserDetails(
        lookupKey: 'movie:custom:2020',
        title: 'Mine, Newer',
        postersDirProvider: BackupService.postersDirOverride,
      );
      fake.backupJobStates.add({
        'kind': 'restore',
        'phase': 'done',
        'result': {
          'created_ms': 1,
          'doc': {
            'v': 1,
            'lists': const [],
            'watch': [
              {
                'address': _addr(1),
                'pos_ms': 10,
                'dur_ms': 100,
                'completed': false,
                'updated_ms': 1, // stale
              },
            ],
            'meta': {
              'v': 1,
              'rows': [
                {
                  'key': 'movie:custom:2020',
                  'updated_ms': 2, // older than the local edit
                  'title': 'Backup, Older',
                },
              ],
            },
          },
          'maps_imported': 0,
          'maps_failed': 0,
          'art_files': const [],
          'art_failed': 0,
        },
      });
      // Newer local watch state for the same address.
      await WatchStateStore.instance.mergeAll([
        WatchState(
            address: _addr(1),
            positionMs: 90,
            durationMs: 100,
            completed: false,
            updatedAt: 999999),
      ]);

      final summary = await service.restore();
      final row = await metadataRowFor('movie:custom:2020');
      expect(row!.title, 'Mine, Newer');
      expect(summary.detailsApplied, 0);
      final states = await WatchStateStore.instance.all();
      expect(states.single.positionMs, 90);
      expect(summary.watchApplied, 0);
    });
  });

  group('BackupScreen', () {
    testWidgets('without a wallet it points at the wallet setup',
        (tester) async {
      final screenService = BackupService(
        api: BackupApi(base: FakeEmbeddedHttp.base, token: 't'),
      );
      await tester.pumpWidget(MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: BackupScreen(service: screenService),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Set up the wallet'), findsOneWidget);
      expect(find.text('Back up now'), findsNothing);
    });

    testWidgets('with a wallet it shows the status and confirms before '
        'backing up', (tester) async {
      fake.backupStatus = {
        'configured': true,
        'pointer': 'aa' * 32,
        'last': {'ms': 1700000000000, 'backups': 2, 'objects': 7, 'uploaded': 1},
        'job': null,
      };
      final screenService = BackupService(
        api: BackupApi(base: FakeEmbeddedHttp.base, token: 't'),
      );
      await tester.pumpWidget(MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: BackupScreen(service: screenService),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('Backup #2'), findsOneWidget);
      expect(find.text('Restore from backup'), findsOneWidget);
      await tester.tap(find.text('Back up now'));
      await tester.pumpAndSettle();
      expect(find.text('Back up now?'), findsOneWidget);
      // Cancelling runs nothing.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(fake.backupRunPosts, isEmpty);
    });

    testWidgets('never-backed-up state reads so', (tester) async {
      fake.backupStatus = {
        'configured': true,
        'pointer': 'aa' * 32,
        'last': null,
        'job': null,
      };
      final screenService = BackupService(
        api: BackupApi(base: FakeEmbeddedHttp.base, token: 't'),
      );
      await tester.pumpWidget(MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: BackupScreen(service: screenService),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Never backed up from this device'), findsOneWidget);
    });

    testWidgets('the automatic-backup switch persists the opt-in',
        (tester) async {
      fake.backupStatus = {
        'configured': true,
        'pointer': 'aa' * 32,
        'last': null,
        'job': null,
      };
      final screenService = BackupService(
        api: BackupApi(base: FakeEmbeddedHttp.base, token: 't'),
      );
      await tester.pumpWidget(MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: BackupScreen(service: screenService),
      ));
      await tester.pumpAndSettle();
      final toggle = find.text('Back up automatically');
      expect(toggle, findsOneWidget);
      expect(
          tester
              .widget<SwitchListTile>(find.byType(SwitchListTile))
              .value,
          isFalse);
      await tester.ensureVisible(toggle);
      await tester.pump();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(
          tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('backup_auto_v1'), isTrue);
    });

    testWidgets('nudges toward automatic backups once a linked device '
        'follows this one', (tester) async {
      fake.backupStatus = {
        'configured': true,
        'pointer': 'aa' * 32,
        'last': {'ms': 1700000000000, 'backups': 2, 'objects': 7, 'uploaded': 1},
        'job': null,
      };
      fake.myWatchStatus = {
        'supported': true,
        'linked': true,
        'state': 'ready',
        'devices': [
          {'agent_id': 'aa' * 32, 'self': true, 'name': 'Here'},
          {'agent_id': 'bb' * 32, 'self': false, 'name': 'Phone'},
        ],
      };
      final screenService = BackupService(
        api: BackupApi(base: FakeEmbeddedHttp.base, token: 't'),
      );
      Future<void> open() async {
        await tester.pumpWidget(MaterialApp(
          theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
          home: BackupScreen(
            service: screenService,
            myWatchApi: MyWatchApi(base: FakeEmbeddedHttp.base, token: 't'),
          ),
        ));
        await tester.pumpAndSettle();
      }

      await open();
      expect(find.textContaining('follow this device\'s backups'),
          findsOneWidget);
      // Turn on flips the opt-in and retires the nudge.
      await tester.tap(find.text('Turn on'));
      await tester.pumpAndSettle();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('backup_auto_v1'), isTrue);
      expect(find.textContaining('follow this device\'s backups'),
          findsNothing);

      // Fresh screen with auto off again: "Not now" dismisses for good.
      // (Dispose first — pumping the same widget would reuse the State.)
      await AppSettings.setBackupAuto(false);
      await tester.pumpWidget(const SizedBox());
      await open();
      expect(find.textContaining('follow this device\'s backups'),
          findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(find.textContaining('follow this device\'s backups'),
          findsNothing);
      expect(prefs.getBool('backup_auto_nudge_dismissed_v1'), isTrue);
      await tester.pumpWidget(const SizedBox());
      await open();
      expect(find.textContaining('follow this device\'s backups'),
          findsNothing);
    });

    testWidgets('no nudge without followers or before the first backup',
        (tester) async {
      // Followers but never backed up: keys are not even published yet.
      fake.backupStatus = {
        'configured': true,
        'pointer': 'aa' * 32,
        'last': null,
        'job': null,
      };
      fake.myWatchStatus = {
        'supported': true,
        'linked': true,
        'state': 'ready',
        'devices': [
          {'agent_id': 'bb' * 32, 'self': false, 'name': 'Phone'},
        ],
      };
      final screenService = BackupService(
        api: BackupApi(base: FakeEmbeddedHttp.base, token: 't'),
      );
      await tester.pumpWidget(MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: BackupScreen(
          service: screenService,
          myWatchApi: MyWatchApi(base: FakeEmbeddedHttp.base, token: 't'),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('follow this device\'s backups'),
          findsNothing);
    });

    testWidgets('a wallet-less follower shows the shared-backup card',
        (tester) async {
      BackupFollowService.status.value = BackupFollowStatus(
        following: true,
        pointer: 'ab' * 32,
        lastAppliedMs:
            DateTime.now().millisecondsSinceEpoch - 5 * 60 * 1000,
        lastSummary: 'Caught up from the backup: 2 added.',
      );
      addTearDown(() =>
          BackupFollowService.status.value = const BackupFollowStatus());
      final screenService = BackupService(
        api: BackupApi(base: FakeEmbeddedHttp.base, token: 't'),
      );
      await tester.pumpWidget(MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: BackupScreen(service: screenService),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Following a shared backup'), findsOneWidget);
      expect(find.textContaining('Last caught up 5 min ago'), findsOneWidget);
      expect(find.text('Check the backup now'), findsOneWidget);
      // The wallet CTA stays available below the card.
      expect(find.text('Set up the wallet'), findsOneWidget);
    });
  });
}
