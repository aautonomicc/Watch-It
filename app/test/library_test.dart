import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions, Value;
import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/main.dart';
import 'package:watchit/screens/builtin_clients_screen.dart';
import 'package:watchit/screens/data_saving_screen.dart';
import 'package:watchit/screens/mobile_data_screen.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/app_settings.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata.dart';
import 'package:watchit/services/seed_catalog.dart';
import 'package:watchit/services/embedded_client.dart';
import 'package:watchit/services/terms.dart';

const _addr =
    'a3f1c9e07b6d5a4f2e8c1b0d9f7a6e5c4b3a2d1e0f9c8b7a6d5e4f3c2b1a0d9e';

void main() {
  // Each test gets its own in-memory database, so the multiple-instance
  // race drift warns about cannot happen.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    SharedPreferences.setMockInitialValues(
        {'terms_accepted_version_v1': kTermsVersion});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
  });

  group('MediaList model', () {
    test('JSON round-trip preserves title and entries', () {
      final list = MediaList(
        id: '1',
        title: 'Films',
        entries: const [MediaEntry(name: 'Movie.mkv', address: _addr)],
      );
      final restored = MediaList.fromJson(list.toJson());
      expect(restored.id, '1');
      expect(restored.title, 'Films');
      expect(restored.entries.single.name, 'Movie.mkv');
      expect(restored.entries.single.address, _addr);
    });

    test('JSON round-trip preserves the enabled flag', () {
      final hidden = MediaList(id: '2', title: 'Hidden', enabled: false);
      expect(MediaList.fromJson(hidden.toJson()).enabled, isFalse);
      // Pre-alpha.25 blobs have no flag: default to shown.
      expect(MediaList.fromJson({'id': '3', 'title': 'Old'}).enabled, isTrue);
    });

    test('XOR address validation', () {
      expect(looksLikeXorAddress(_addr), isTrue);
      expect(looksLikeXorAddress('0x$_addr'), isTrue);
      expect(looksLikeXorAddress('not-an-address'), isFalse);
      expect(looksLikeXorAddress(_addr.substring(1)), isFalse);
    });
  });

  group('LibraryStore', () {
    test('save then load returns the same lists', () async {
      await LibraryStore.save([
        MediaList(
          id: '42',
          title: 'Series',
          entries: const [MediaEntry(name: 'Ep1.mkv', address: _addr)],
        ),
      ]);
      final loaded = await LibraryStore.load();
      expect(loaded.single.title, 'Series');
      expect(loaded.single.entries.single.address, _addr);
    });

    test('save then load preserves the enabled flag', () async {
      await LibraryStore.save([
        MediaList(id: 'on', title: 'Shown'),
        MediaList(id: 'off', title: 'Hidden', enabled: false),
      ]);
      final loaded = await LibraryStore.load();
      expect(loaded.singleWhere((l) => l.id == 'on').enabled, isTrue);
      expect(loaded.singleWhere((l) => l.id == 'off').enabled, isFalse);
    });

    test('empty store loads as empty list', () async {
      expect(await LibraryStore.load(), isEmpty);
    });

    test('save stamps addedAt on new entries and preserves it after', () async {
      final before = DateTime.now().millisecondsSinceEpoch;
      await LibraryStore.save([
        MediaList(
          id: 'l',
          title: 'L',
          entries: const [MediaEntry(name: 'New.mkv', address: _addr)],
        ),
      ]);
      final stamped = (await LibraryStore.load()).single.entries.single;
      expect(stamped.addedAt, isNotNull);
      expect(stamped.addedAt, greaterThanOrEqualTo(before));

      // A later save (any list edit) keeps the original stamp.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await LibraryStore.save(await LibraryStore.load());
      final reloaded = (await LibraryStore.load()).single.entries.single;
      expect(reloaded.addedAt, stamped.addedAt);
    });

    test('addedAt 0 (pre-column rows) survives the save round-trip', () async {
      await LibraryStore.save([
        MediaList(
          id: 'l',
          title: 'L',
          entries: const [
            MediaEntry(name: 'Legacy.mkv', address: _addr, addedAt: 0),
          ],
        ),
      ]);
      final loaded = (await LibraryStore.load()).single.entries.single;
      expect(loaded.addedAt, 0);
    });

    test('save preserves list and entry order', () async {
      await LibraryStore.save([
        for (var i = 0; i < 3; i++)
          MediaList(
            id: 'l$i',
            title: 'List $i',
            entries: [
              for (var j = 0; j < 3; j++)
                MediaEntry(name: 'e$i-$j.mkv', address: _addr),
            ],
          ),
      ]);
      final loaded = await LibraryStore.load();
      expect(loaded.map((l) => l.title), ['List 0', 'List 1', 'List 2']);
      expect(loaded[1].entries.map((e) => e.name),
          ['e1-0.mkv', 'e1-1.mkv', 'e1-2.mkv']);
    });
  });

  group('Schema migration', () {
    test('v2 database gains the enabled column on upgrade', () async {
      final dir = await Directory.systemTemp.createTemp('watchit-migration');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/watchit.sqlite');

      // Hand-build the alpha.22–24 (schema v2) shape of the lists tables.
      final raw = sqlite3.open(file.path);
      raw.execute('''
        CREATE TABLE media_lists (
          id TEXT NOT NULL, title TEXT NOT NULL, position INTEGER NOT NULL,
          PRIMARY KEY (id));
        CREATE TABLE media_entries (
          entry_id INTEGER PRIMARY KEY AUTOINCREMENT,
          list_id TEXT NOT NULL REFERENCES media_lists (id) ON DELETE CASCADE,
          name TEXT NOT NULL, address TEXT NOT NULL,
          position INTEGER NOT NULL);
        INSERT INTO media_lists VALUES ('l1', 'Old List', 0);
        INSERT INTO media_entries (list_id, name, address, position)
          VALUES ('l1', 'Old.mkv', '$_addr', 0);
        PRAGMA user_version = 2;
      ''');
      raw.close();

      await LibraryStore.useForTesting(
          AppDatabase.forTesting(NativeDatabase(file)));
      final lists = await LibraryStore.load();
      expect(lists.single.title, 'Old List');
      expect(lists.single.entries.single.name, 'Old.mkv');
      // Migrated lists default to shown on home.
      expect(lists.single.enabled, isTrue);
    });

    test('v3 metadata cache is dropped on upgrade and gains new columns',
        () async {
      final dir = await Directory.systemTemp.createTemp('watchit-migration');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/watchit.sqlite');

      // Hand-build the alpha.25/26 (schema v3) shape of the cache table
      // with one stale row that lacks the alpha.27 fields.
      final raw = sqlite3.open(file.path);
      raw.execute('''
        CREATE TABLE media_lists (
          id TEXT NOT NULL, title TEXT NOT NULL, position INTEGER NOT NULL,
          enabled INTEGER NOT NULL DEFAULT 1, PRIMARY KEY (id));
        CREATE TABLE media_entries (
          entry_id INTEGER PRIMARY KEY AUTOINCREMENT,
          list_id TEXT NOT NULL REFERENCES media_lists (id) ON DELETE CASCADE,
          name TEXT NOT NULL, address TEXT NOT NULL,
          position INTEGER NOT NULL);
        CREATE TABLE metadata_cache (
          lookup_key TEXT NOT NULL, found INTEGER NOT NULL,
          title TEXT, year INTEGER, overview TEXT, category TEXT,
          episode_label TEXT, poster_file TEXT, media_type TEXT,
          tmdb_id INTEGER, fetched_at INTEGER NOT NULL,
          PRIMARY KEY (lookup_key));
        INSERT INTO metadata_cache (lookup_key, found, title, fetched_at)
          VALUES ('movie:old:2020', 1, 'Old Match', 0);
        PRAGMA user_version = 3;
      ''');
      raw.close();

      await LibraryStore.useForTesting(
          AppDatabase.forTesting(NativeDatabase(file)));
      final db = await LibraryStore.database();
      // Stale rows are gone (they will refetch with the new fields)...
      expect(await db.select(db.metadataCache).get(), isEmpty);
      // ...and the recreated table accepts the alpha.27 columns.
      await db.into(db.metadataCache).insert(MetadataCacheCompanion.insert(
            lookupKey: 'movie:new:2024',
            found: true,
            rating: const Value(7.5),
            airDate: const Value('2024-06-01'),
            stillFile: const Value('x.jpg'),
            showOverview: const Value('s'),
            seasonOverview: const Value('se'),
            showPosterFile: const Value('p.jpg'),
            fetchedAt: 1,
          ));
      expect((await db.select(db.metadataCache).get()).single.rating, 7.5);
    });

    test('v4 database gains watch states and addedAt on upgrade', () async {
      final dir = await Directory.systemTemp.createTemp('watchit-migration');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/watchit.sqlite');

      // Hand-build the alpha.27/28 (schema v4) shape: no watch_states
      // table, no added_at column.
      final raw = sqlite3.open(file.path);
      raw.execute('''
        CREATE TABLE media_lists (
          id TEXT NOT NULL, title TEXT NOT NULL, position INTEGER NOT NULL,
          enabled INTEGER NOT NULL DEFAULT 1, PRIMARY KEY (id));
        CREATE TABLE media_entries (
          entry_id INTEGER PRIMARY KEY AUTOINCREMENT,
          list_id TEXT NOT NULL REFERENCES media_lists (id) ON DELETE CASCADE,
          name TEXT NOT NULL, address TEXT NOT NULL,
          position INTEGER NOT NULL);
        CREATE TABLE metadata_cache (
          lookup_key TEXT NOT NULL, found INTEGER NOT NULL,
          title TEXT, year INTEGER, overview TEXT, category TEXT,
          episode_label TEXT, poster_file TEXT, media_type TEXT,
          tmdb_id INTEGER, fetched_at INTEGER NOT NULL, rating REAL,
          show_overview TEXT, season_overview TEXT, air_date TEXT,
          still_file TEXT, show_poster_file TEXT, PRIMARY KEY (lookup_key));
        INSERT INTO media_lists VALUES ('l1', 'Old List', 0, 1);
        INSERT INTO media_entries (list_id, name, address, position)
          VALUES ('l1', 'Old.mkv', '$_addr', 0);
        PRAGMA user_version = 4;
      ''');
      raw.close();

      await LibraryStore.useForTesting(
          AppDatabase.forTesting(NativeDatabase(file)));
      // Existing entries load with an unknown (0) add time.
      final lists = await LibraryStore.load();
      expect(lists.single.entries.single.addedAt, 0);
      // The new watch_states table is queryable and empty.
      final db = await LibraryStore.database();
      expect(await db.select(db.watchStates).get(), isEmpty);
    });

    test('v6 downloads gain pausedBySystem on upgrade, defaulting false',
        () async {
      final dir = await Directory.systemTemp.createTemp('watchit-migration');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/watchit.sqlite');

      // Hand-build the alpha.30–37 (schema v6) downloads table: no
      // paused_by_system column yet, one task paused mid-flight.
      final raw = sqlite3.open(file.path);
      raw.execute('''
        CREATE TABLE media_lists (
          id TEXT NOT NULL, title TEXT NOT NULL, position INTEGER NOT NULL,
          enabled INTEGER NOT NULL DEFAULT 1, PRIMARY KEY (id));
        CREATE TABLE media_entries (
          entry_id INTEGER PRIMARY KEY AUTOINCREMENT,
          list_id TEXT NOT NULL REFERENCES media_lists (id) ON DELETE CASCADE,
          name TEXT NOT NULL, address TEXT NOT NULL,
          position INTEGER NOT NULL, added_at INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE metadata_cache (
          lookup_key TEXT NOT NULL, found INTEGER NOT NULL,
          title TEXT, year INTEGER, overview TEXT, category TEXT,
          episode_label TEXT, poster_file TEXT, media_type TEXT,
          tmdb_id INTEGER, fetched_at INTEGER NOT NULL, rating REAL,
          show_overview TEXT, season_overview TEXT, air_date TEXT,
          still_file TEXT, show_poster_file TEXT, PRIMARY KEY (lookup_key));
        CREATE TABLE downloads (
          address TEXT NOT NULL, name TEXT NOT NULL,
          file_path TEXT NOT NULL,
          total_bytes INTEGER NOT NULL DEFAULT 0,
          downloaded_bytes INTEGER NOT NULL DEFAULT 0,
          status TEXT NOT NULL, error TEXT,
          created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
          PRIMARY KEY (address));
        INSERT INTO downloads (address, name, file_path, status,
          created_at, updated_at)
          VALUES ('$_addr', 'Old.mkv', '/tmp/Old.mkv', 'paused', 1, 1);
        PRAGMA user_version = 6;
      ''');
      raw.close();

      await LibraryStore.useForTesting(
          AppDatabase.forTesting(NativeDatabase(file)));
      final db = await LibraryStore.database();
      final row = (await db.select(db.downloads).get()).single;
      // An old pause was by definition a user pause — never auto-resume.
      expect(row.pausedBySystem, isFalse);
      expect(row.status, 'paused');
    });

    test('v8 metadata cache gains userEdited on upgrade, defaulting false',
        () async {
      final dir = await Directory.systemTemp.createTemp('watchit-migration');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/watchit.sqlite');

      // Hand-build the alpha.48–56 (schema v8) cache table: no
      // user_edited column yet, one cached TMDB match.
      final raw = sqlite3.open(file.path);
      raw.execute('''
        CREATE TABLE media_lists (
          id TEXT NOT NULL, title TEXT NOT NULL, position INTEGER NOT NULL,
          enabled INTEGER NOT NULL DEFAULT 1, PRIMARY KEY (id));
        CREATE TABLE media_entries (
          entry_id INTEGER PRIMARY KEY AUTOINCREMENT,
          list_id TEXT NOT NULL REFERENCES media_lists (id) ON DELETE CASCADE,
          name TEXT NOT NULL, address TEXT NOT NULL,
          position INTEGER NOT NULL, added_at INTEGER NOT NULL DEFAULT 0,
          size_bytes INTEGER, video_info TEXT);
        CREATE TABLE metadata_cache (
          lookup_key TEXT NOT NULL, found INTEGER NOT NULL,
          title TEXT, year INTEGER, overview TEXT, category TEXT,
          episode_label TEXT, poster_file TEXT, media_type TEXT,
          tmdb_id INTEGER, fetched_at INTEGER NOT NULL, rating REAL,
          show_overview TEXT, season_overview TEXT, air_date TEXT,
          still_file TEXT, show_poster_file TEXT, PRIMARY KEY (lookup_key));
        INSERT INTO metadata_cache (lookup_key, found, title, fetched_at)
          VALUES ('movie:old:2020', 1, 'Old', 1);
        PRAGMA user_version = 8;
      ''');
      raw.close();

      await LibraryStore.useForTesting(
          AppDatabase.forTesting(NativeDatabase(file)));
      final db = await LibraryStore.database();
      final row = (await db.select(db.metadataCache).get()).single;
      // Every pre-upgrade row is a TMDB match, not a user edit.
      expect(row.userEdited, isFalse);
      expect(row.title, 'Old');
    });

    test('v10 lists gain channelAuthor + channelAvatar on upgrade',
        () async {
      final dir = await Directory.systemTemp.createTemp('watchit-migration');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/watchit.sqlite');

      // Hand-build the alpha.65–69 (schema v10) lists table: channel
      // pubkey column exists, no profile columns yet.
      final raw = sqlite3.open(file.path);
      raw.execute('''
        CREATE TABLE media_lists (
          id TEXT NOT NULL, title TEXT NOT NULL, position INTEGER NOT NULL,
          enabled INTEGER NOT NULL DEFAULT 1, channel_pubkey TEXT,
          PRIMARY KEY (id));
        CREATE TABLE media_entries (
          entry_id INTEGER PRIMARY KEY AUTOINCREMENT,
          list_id TEXT NOT NULL REFERENCES media_lists (id) ON DELETE CASCADE,
          name TEXT NOT NULL, address TEXT NOT NULL,
          position INTEGER NOT NULL, added_at INTEGER NOT NULL DEFAULT 0,
          size_bytes INTEGER, video_info TEXT);
        CREATE TABLE metadata_cache (
          lookup_key TEXT NOT NULL PRIMARY KEY, found INTEGER NOT NULL,
          title TEXT, year INTEGER, overview TEXT, category TEXT,
          episode_label TEXT, poster_file TEXT, media_type TEXT,
          tmdb_id INTEGER, fetched_at INTEGER NOT NULL, rating REAL,
          show_overview TEXT, season_overview TEXT, air_date TEXT,
          still_file TEXT, show_poster_file TEXT,
          user_edited INTEGER NOT NULL DEFAULT 0);
        INSERT INTO media_lists (id, title, position, channel_pubkey)
          VALUES ('channel-x', 'Their channel', 0, '${'ab' * 32}');
        PRAGMA user_version = 10;
      ''');
      raw.close();

      await LibraryStore.useForTesting(
          AppDatabase.forTesting(NativeDatabase(file)));
      final lists = await LibraryStore.load();
      // Pre-upgrade channel lists have no profile yet…
      expect(lists.single.channelAuthor, isNull);
      expect(lists.single.channelAvatar, isNull);
      // …and the new columns round-trip through a save.
      await LibraryStore.save([
        MediaList(
          id: 'channel-x',
          title: 'Their channel',
          channelPubkey: 'ab' * 32,
          channelAuthor: '@neil',
          channelAvatar: 'channel_avatar_00112233.img',
        ),
      ]);
      final reloaded = (await LibraryStore.load()).single;
      expect(reloaded.channelAuthor, '@neil');
      expect(reloaded.channelAvatar, 'channel_avatar_00112233.img');
    });
  });

  group('Legacy SharedPreferences import', () {
    test('imports the pre-SQLite JSON blob once and removes it', () async {
      SharedPreferences.setMockInitialValues({
        'media_lists_v1': jsonEncode([
          MediaList(
            id: 'legacy',
            title: 'From Prefs',
            entries: const [MediaEntry(name: 'Old.mkv', address: _addr)],
          ).toJson(),
        ]),
      });
      final loaded = await LibraryStore.load();
      expect(loaded.single.title, 'From Prefs');
      expect(loaded.single.entries.single.name, 'Old.mkv');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('media_lists_v1'), isNull);
    });

    test('corrupt blob is dropped without error', () async {
      SharedPreferences.setMockInitialValues({'media_lists_v1': 'not-json'});
      expect(await LibraryStore.load(), isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('media_lists_v1'), isNull);
    });
  });

  group('Default seeding', () {
    test('seeds the full public-domain catalog once', () async {
      await LibraryStore.ensureDefaults();
      final lists = await LibraryStore.load();
      for (final seed in kSeedLists) {
        final seeded = lists.singleWhere((l) => l.title == seed.title);
        expect(seeded.entries, hasLength(seed.entries.length));
        for (final (i, entry) in seed.entries.indexed) {
          expect(seeded.entries[i].name, entry.name);
          expect(seeded.entries[i].address, entry.address);
        }
      }
      final movies = lists.singleWhere((l) => l.title == 'Movies');
      expect(
        movies.entries.where((e) =>
            e.address == kDefaultMovieAddress && e.name == kDefaultMovieName),
        hasLength(1),
      );
    });

    test('a catalog entry the user already holds is not re-added',
        () async {
      await LibraryStore.save([
        const MediaList(
          id: 'mine',
          title: 'My Films',
          entries: [
            MediaEntry(name: kDefaultMovieName, address: kDefaultMovieAddress),
          ],
        ),
      ]);
      await LibraryStore.ensureDefaults();
      final lists = await LibraryStore.load();
      // The user's copy is the only one; the seeded Movies list carries
      // the rest of the catalog.
      expect(
        lists
            .expand((l) => l.entries)
            .where((e) => e.address == kDefaultMovieAddress),
        hasLength(1),
      );
      final movies = lists.singleWhere((l) => l.title == 'Movies');
      final seedMovies =
          kSeedLists.singleWhere((l) => l.title == 'Movies');
      expect(movies.entries, hasLength(seedMovies.entries.length - 1));
    });

    test('renames the pre-alpha.26 "Test Movies" list to "Movies"', () async {
      // Already-seeded install: the flag is set, the old title persists.
      // Additions flag too — this test pins the rename, not the seeding.
      SharedPreferences.setMockInitialValues(
          {'defaults_seeded_v4': true,
      'terms_accepted_version_v1': kTermsVersion, 'seed_additions_v1': true});
      await LibraryStore.save([
        MediaList(
          id: 'default-test-movies',
          title: 'Test Movies',
          entries: const [
            MediaEntry(name: kDefaultMovieName, address: kDefaultMovieAddress),
          ],
        ),
      ]);
      await LibraryStore.ensureDefaults();
      final lists = await LibraryStore.load();
      expect(lists.single.title, 'Movies');
      expect(lists.single.entries.single.address, kDefaultMovieAddress);
    });

    test('a user-renamed default list keeps its name', () async {
      SharedPreferences.setMockInitialValues({'defaults_seeded_v4': true,
      'terms_accepted_version_v1': kTermsVersion});
      await LibraryStore.save([
        const MediaList(id: 'default-test-movies', title: 'My Flicks'),
      ]);
      await LibraryStore.ensureDefaults();
      expect((await LibraryStore.load()).single.title, 'My Flicks');
    });

    test('does not re-seed after the user deletes it', () async {
      await LibraryStore.ensureDefaults();
      await LibraryStore.save([]);
      await LibraryStore.ensureDefaults();
      expect(await LibraryStore.load(), isEmpty);
    });

    test('a pre-v4 install keeps the held 1080p re-encode in place',
        () async {
      // The 5.68GB re-encode was the default up to alpha.47 and is a
      // catalog entry again — it must NOT be rewritten like the truly
      // stale addresses, and the merge must not duplicate it.
      await LibraryStore.save([
        const MediaList(
          id: 'default-test-movies',
          title: 'Movies',
          entries: [
            MediaEntry(
                name: kDefaultMovieName, address: kDefaultMovie1080Address),
          ],
        ),
      ]);
      await LibraryStore.ensureDefaults();
      final lists = await LibraryStore.load();
      final movies = lists.singleWhere((l) => l.title == 'Movies');
      expect(movies.entries.first.address, kDefaultMovie1080Address);
      expect(
        movies.entries.where((e) => e.address == kDefaultMovie1080Address),
        hasLength(1),
      );
      final seedMovies =
          kSeedLists.singleWhere((l) => l.id == 'default-test-movies');
      expect(movies.entries, hasLength(seedMovies.entries.length));
      // The file-info backfill annotates the held copy on the same pass.
      expect(movies.entries.first.sizeBytes, 5682464056);
      expect(movies.entries.first.videoInfo, '1080p H.264');
    });

    for (final legacy in kLegacyDefaultMovieAddresses) {
      test('rewrites stale default address $legacy in place', () async {
        await LibraryStore.save([
          MediaList(
            id: 'default-test-movies',
            title: 'Test Movies',
            entries: [
              MediaEntry(
                name: 'Night Of The Living Dead (1968)',
                address: legacy,
              ),
            ],
          ),
        ]);
        await LibraryStore.ensureDefaults();
        final lists = await LibraryStore.load();
        // The rename migration also applies on the same pass, and the
        // rest of the catalog seeds around the migrated entry.
        final seeded = lists.singleWhere((l) => l.title == 'Movies');
        expect(seeded.entries.first.address, kDefaultMovieAddress);
        expect(seeded.entries.first.name, kDefaultMovieName);
        expect(
          seeded.entries,
          hasLength(kSeedLists
              .singleWhere((l) => l.title == 'Movies')
              .entries
              .length),
        );
        // Seeding does not duplicate the migrated entry.
        expect(
          lists
              .expand((l) => l.entries)
              .where((e) => e.address == kDefaultMovieAddress),
          hasLength(1),
        );
      });
    }
  });

  group('Seed additions', () {
    test('a v4-seeded install gains the addition next to its sibling',
        () async {
      SharedPreferences.setMockInitialValues({
        'defaults_seeded_v4': true,
      'terms_accepted_version_v1': kTermsVersion,
        'seed_fileinfo_v1': true,
      });
      await LibraryStore.save([
        const MediaList(id: 'default-test-movies', title: 'Movies', entries: [
          MediaEntry(name: kDefaultMovieName, address: kDefaultMovieAddress),
          MediaEntry(name: 'Mine.mp4', address: _addr),
        ]),
      ]);
      await LibraryStore.ensureDefaults();
      final movies = (await LibraryStore.load()).single;
      expect(movies.entries, hasLength(3));
      final added = movies.entries[1];
      expect(added.address, kDefaultMovie1080Address);
      expect(added.name, kDefaultMovieName);
      expect(added.sizeBytes, 5682464056);
      expect(added.videoInfo, '1080p H.264');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('seed_additions_v1'), isTrue);
    });

    test('appends at the end when the sibling entry is gone', () async {
      SharedPreferences.setMockInitialValues({
        'defaults_seeded_v4': true,
      'terms_accepted_version_v1': kTermsVersion,
        'seed_fileinfo_v1': true,
      });
      await LibraryStore.save([
        const MediaList(id: 'default-test-movies', title: 'Movies', entries: [
          MediaEntry(name: 'Mine.mp4', address: _addr),
        ]),
      ]);
      await LibraryStore.ensureDefaults();
      final movies = (await LibraryStore.load()).single;
      expect(movies.entries, hasLength(2));
      expect(movies.entries.last.address, kDefaultMovie1080Address);
    });

    test('an addition the user already holds is not re-added', () async {
      SharedPreferences.setMockInitialValues({
        'defaults_seeded_v4': true,
      'terms_accepted_version_v1': kTermsVersion,
        'seed_fileinfo_v1': true,
      });
      await LibraryStore.save([
        const MediaList(id: 'mine', title: 'My Films', entries: [
          MediaEntry(
              name: kDefaultMovieName, address: kDefaultMovie1080Address),
        ]),
        const MediaList(id: 'default-test-movies', title: 'Movies', entries: [
          MediaEntry(name: kDefaultMovieName, address: kDefaultMovieAddress),
        ]),
      ]);
      await LibraryStore.ensureDefaults();
      final lists = await LibraryStore.load();
      expect(
        lists
            .expand((l) => l.entries)
            .where((e) => e.address == kDefaultMovie1080Address),
        hasLength(1),
      );
    });

    test('a deleted seed list is not recreated for an addition', () async {
      SharedPreferences.setMockInitialValues({
        'defaults_seeded_v4': true,
      'terms_accepted_version_v1': kTermsVersion,
        'seed_fileinfo_v1': true,
      });
      await LibraryStore.save([
        const MediaList(id: 'mine', title: 'My Films', entries: [
          MediaEntry(name: 'Mine.mp4', address: _addr),
        ]),
      ]);
      await LibraryStore.ensureDefaults();
      final lists = await LibraryStore.load();
      expect(lists, hasLength(1));
      expect(lists.single.id, 'mine');
      expect(lists.single.entries, hasLength(1));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('seed_additions_v1'), isTrue);
    });

    test('runs once — the flag short-circuits later launches', () async {
      SharedPreferences.setMockInitialValues({
        'defaults_seeded_v4': true,
      'terms_accepted_version_v1': kTermsVersion,
        'seed_fileinfo_v1': true,
        'seed_additions_v1': true,
      });
      await LibraryStore.save([
        const MediaList(id: 'default-test-movies', title: 'Movies', entries: [
          MediaEntry(name: kDefaultMovieName, address: kDefaultMovieAddress),
        ]),
      ]);
      await LibraryStore.ensureDefaults();
      final movies = (await LibraryStore.load()).single;
      expect(movies.entries, hasLength(1));
    });

    test('every addition address is a catalog entry', () {
      final catalog = {
        for (final l in kSeedLists)
          for (final e in l.entries) e.address,
      };
      for (final addr in kSeedAdditionAddresses) {
        expect(catalog, contains(addr));
        expect(kLegacyDefaultMovieAddresses, isNot(contains(addr)));
      }
    });
  });

  group('Metadata', () {
    test('default movie resolves from the bundled catalog', () {
      final meta = fallbackMetadataFor(const MediaEntry(
        name: kDefaultMovieName,
        address: kDefaultMovieAddress,
      ));
      expect(meta.title, 'Night of the Living Dead');
      expect(meta.year, 1968);
      expect(meta.overview, isNotNull);
      expect(meta.posterAsset, 'assets/posters/notld_1968.jpg');
    });

    test('unknown address falls back to parsed file name', () {
      final meta = fallbackMetadataFor(
          const MediaEntry(name: 'The.Movie.2024.1080p.mkv', address: _addr));
      expect(meta.title, 'The Movie');
      expect(meta.year, 2024);
      expect(meta.posterAsset, isNull);
    });

    test('parseMediaName handles common shapes', () {
      expect(parseMediaName('The.Movie.2024.1080p.mkv').title, 'The Movie');
      expect(parseMediaName('The.Movie.2024.1080p.mkv').year, 2024);
      expect(parseMediaName('Some Film (1999)').title, 'Some Film');
      expect(parseMediaName('Some Film (1999)').year, 1999);
      expect(parseMediaName('plainname').title, 'plainname');
      expect(parseMediaName('The.Movie.2024.1080p.mkv').imdbId, isNull);
      expect(parseMediaName('The.Movie.2024.1080p.mkv').isEpisode, isFalse);
    });

    test('parseMediaName extracts season/episode markers', () {
      final sxxeyy = parseMediaName('Show.S01E01.mkv');
      expect(sxxeyy.title, 'Show');
      expect(sxxeyy.year, isNull);
      expect(sxxeyy.season, 1);
      expect(sxxeyy.episode, 1);
      expect(sxxeyy.isEpisode, isTrue);

      final full = parseMediaName(
          'The Show (2019) S02E13 The Episode Name [1080p].mkv');
      expect(full.title, 'The Show');
      expect(full.year, 2019);
      expect(full.season, 2);
      expect(full.episode, 13);

      final xStyle = parseMediaName('Show 2x05.mkv');
      expect(xStyle.title, 'Show');
      expect(xStyle.season, 2);
      expect(xStyle.episode, 5);

      // Resolutions must not read as episode markers.
      final res = parseMediaName('The.Movie.2024.1920x1080.mkv');
      expect(res.isEpisode, isFalse);
      expect(res.title, 'The Movie');
      expect(res.year, 2024);
    });

    test('lookupKey shares cache rows across renames of one film', () {
      expect(
        parseMediaName('The Movie (2024) - [1080p].mkv').lookupKey,
        parseMediaName('The.Movie.2024.720p.mkv').lookupKey,
      );
      expect(
        parseMediaName('A (2024) {imdb-tt1} - [1080p].mkv').lookupKey,
        'imdb:tt1',
      );
      expect(parseMediaName('Show.S01E02.mkv').lookupKey,
          'tv:show::s1:e2');
    });

    test('parseMediaName handles Plex/Jellyfin naming with id tags', () {
      const plex =
          'Night of the Living Dead (1968) {imdb-tt0063350} - [1080p].mp4';
      expect(parseMediaName(plex).title, 'Night of the Living Dead');
      expect(parseMediaName(plex).year, 1968);
      expect(parseMediaName(plex).imdbId, 'tt0063350');

      const jellyfin = 'The Movie (2024) [imdbid-tt1234567] - [1080p].mkv';
      expect(parseMediaName(jellyfin).title, 'The Movie');
      expect(parseMediaName(jellyfin).year, 2024);
      expect(parseMediaName(jellyfin).imdbId, 'tt1234567');

      // Quality tag but no id tag.
      const tagged = 'Some Film (1999) - [720p].mkv';
      expect(parseMediaName(tagged).title, 'Some Film');
      expect(parseMediaName(tagged).year, 1999);
      expect(parseMediaName(tagged).imdbId, isNull);
    });
  });

  group('Stream URL', () {
    const entry = MediaEntry(name: 'Movie.mkv', address: _addr);

    test('joins server base and address, trimming trailing slashes', () {
      expect(streamUrl('http://127.0.0.1:43210', entry),
          'http://127.0.0.1:43210/xor/$_addr');
      expect(streamUrl('http://127.0.0.1:43210///', entry),
          'http://127.0.0.1:43210/xor/$_addr');
    });

    test('strips 0x prefix and lowercases the address', () {
      final upper = MediaEntry(
          name: 'Movie.mkv', address: '0x${_addr.toUpperCase()}');
      expect(streamUrl('http://gw', upper), 'http://gw/xor/$_addr');
    });

    test('missing server yields null', () {
      expect(streamUrl(null, entry), isNull);
      expect(streamUrl('', entry), isNull);
      expect(streamUrl('   ', entry), isNull);
    });
  });

  group('Byte label', () {
    test('formats KB and MB for buffering progress', () {
      expect(byteLabel(0), '0 KB');
      expect(byteLabel(870 * 1024), '870 KB');
      expect(byteLabel(12 * 1024 * 1024 + 400 * 1024), '12.4 MB');
      expect(byteLabel(250 * 1024 * 1024), '250 MB');
    });
  });

  group('Settings flow', () {
    testWidgets('home drawer has a Settings entry that opens Settings',
        (tester) async {
      await tester.pumpWidget(const WatchItApp());
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Browse lists'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      // Content section (renamed from LIBRARY 2026-08-30), in order:
      // Channels (public, on top), My W@tch, My Media, Upload
      // (desktop-only — tests run on the desktop host), Downloads
      // (moved in from its own section 2026-08-30).
      expect(find.text('CONTENT'), findsOneWidget);
      expect(find.text('LIBRARY'), findsNothing);
      expect(find.text('My Media'), findsOneWidget);
      expect(find.text('Channels'), findsOneWidget);
      expect(find.text('My W@tch'), findsOneWidget);
      expect(find.text('Upload'), findsOneWidget);
      expect(find.text('New list'), findsNothing);
      final channelsY = tester.getTopLeft(find.text('Channels')).dy;
      final myWatchY = tester.getTopLeft(find.text('My W@tch')).dy;
      final myMediaY = tester.getTopLeft(find.text('My Media')).dy;
      final uploadY = tester.getTopLeft(find.text('Upload')).dy;
      // The Downloads *tile* (queue/storage) — its title collides with
      // the network Downloads policy tile, so pin via the subtitle.
      final downloadsY = tester
          .getTopLeft(find.text('Queue, storage, and playback behaviour'))
          .dy;
      expect(channelsY, lessThan(myWatchY));
      expect(myWatchY, lessThan(myMediaY));
      expect(myMediaY, lessThan(uploadY));
      expect(uploadY, lessThan(downloadsY));

      // Network section (2026-09-05 reorg): Offline mode leads (the
      // renamed pause-all switch), then Data usage, Buffer size, the
      // Data saving sub-page (which absorbed Auto-pause when idle +
      // Mobile data) and the merged Built-in clients tile. The old
      // per-client tiles and the section-level Auto-pause / Mobile
      // data tiles are gone.
      await tester.scrollUntilVisible(find.text('Built-in clients'), 100);
      expect(find.text('STREAMING'), findsNothing);
      expect(find.text('Offline mode'), findsOneWidget);
      expect(find.text('Pause all network activity'), findsNothing);
      expect(find.text('Data usage'), findsOneWidget);
      expect(find.text('Buffer size'), findsOneWidget);
      expect(find.text('32 MB'), findsOneWidget);
      expect(find.text('Data saving'), findsOneWidget);
      expect(find.text('Built-in clients'), findsOneWidget);
      expect(find.text('Built-in Autonomi client'), findsNothing);
      expect(find.text('Built-in x0x client'), findsNothing);
      expect(find.text('Auto-pause when idle'), findsNothing);
      expect(find.text('Mobile data'), findsNothing);
      expect(find.text('Streaming on mobile data'), findsNothing);
      expect(find.text('Wi-Fi only'), findsNothing);
      final offlineY = tester.getTopLeft(find.text('Offline mode')).dy;
      final dataUsageY = tester.getTopLeft(find.text('Data usage')).dy;
      final bufferY = tester.getTopLeft(find.text('Buffer size')).dy;
      final dataSavingY = tester.getTopLeft(find.text('Data saving')).dy;
      final clientsY = tester.getTopLeft(find.text('Built-in clients')).dy;
      expect(offlineY, lessThan(dataUsageY));
      expect(dataUsageY, lessThan(bufferY));
      expect(bufferY, lessThan(dataSavingY));
      expect(dataSavingY, lessThan(clientsY));

      // Appearance sits below Metadata (2026-08-30).
      await tester.scrollUntilVisible(find.text('Colour scheme'), 100);
      expect(find.text('APPEARANCE'), findsOneWidget);
      final metadataY = tester.getTopLeft(find.text('TMDB API key')).dy;
      final colourY = tester.getTopLeft(find.text('Colour scheme')).dy;
      expect(metadataY, lessThan(colourY));

      // About section: app blurb and installed version.
      await tester.scrollUntilVisible(find.text('Version'), 100);
      expect(find.text('ABOUT'), findsOneWidget);
      expect(find.text('Version'), findsOneWidget);
    });

    testWidgets('Built-in clients tile opens the merged clients page',
        (tester) async {
      await tester.pumpWidget(const WatchItApp());
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Browse lists'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('Built-in clients'), 100);
      await tester.ensureVisible(find.text('Built-in clients'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Built-in clients'));
      await tester.pumpAndSettle();

      // Autonomi status and the two x0x switches on one page.
      expect(find.byType(BuiltInClientsScreen), findsOneWidget);
      expect(find.text('Connection'), findsOneWidget);
      expect(find.text('My W@tch'), findsOneWidget);
      expect(find.text('Channels'), findsOneWidget);
      // Dispose the screen so its status poll timer is cancelled.
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Data saving groups Auto-pause and Mobile data, and its '
        'Mobile data tile opens the consolidated screen', (tester) async {
      await tester.pumpWidget(const WatchItApp());
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Browse lists'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('Data saving'), 100);
      await tester.ensureVisible(find.text('Data saving'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Data saving'));
      await tester.pumpAndSettle();

      // The sub-page holds both moved tiles (2026-09-05 reorg).
      expect(find.byType(DataSavingScreen), findsOneWidget);
      expect(find.text('Auto-pause when idle'), findsOneWidget);
      expect(find.text('Mobile data'), findsOneWidget);

      await tester.tap(find.text('Mobile data'));
      await tester.pumpAndSettle();

      // All four consumers in one place, defaults shown.
      expect(find.byType(MobileDataScreen), findsOneWidget);
      expect(find.text('Streaming'), findsOneWidget);
      expect(find.text('Downloads'), findsOneWidget);
      expect(find.text('Channels'), findsOneWidget);
      expect(find.text('My W@tch'), findsOneWidget);
      expect(find.text('Ask first'), findsOneWidget);
      expect(find.text('Wi-Fi only'), findsOneWidget);
    });

    testWidgets('buffer size can be changed and persists', (tester) async {
      await tester.pumpWidget(const WatchItApp());
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Browse lists'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('Buffer size'), 100);
      // The tile can sit half off-screen after the scroll — bring it in
      // fully before tapping.
      await tester.ensureVisible(find.text('Buffer size'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Buffer size'));
      await tester.pumpAndSettle();

      expect(find.text('32 MB  ·  default'), findsOneWidget);
      await tester.tap(find.text('128 MB'));
      await tester.pumpAndSettle();

      // Tile reflects the new choice, and the store holds it.
      expect(find.text('128 MB'), findsOneWidget);
      expect(await AppSettings.bufferSizeMb(), 128);
    });

    testWidgets('lists are created at import time only — no New list '
        'button, and the edit page has no add button', (tester) async {
      await LibraryStore.save([
        const MediaList(id: '9', title: 'My Films'),
      ]);
      await tester.pumpWidget(const WatchItApp());
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Browse lists'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('My Media'));
      await tester.pumpAndSettle();

      // Creating lists moved into the import flow ("Add to library" →
      // "Create new list", covered in list_import_flow_test.dart).
      expect(find.text('New list'), findsNothing);
      expect(find.text('My Films'), findsOneWidget);
      expect(find.text('0 entries'), findsOneWidget);

      // The edit page only curates entries; its empty state points back
      // at the Media page import.
      await tester.tap(find.text('My Films'));
      await tester.pumpAndSettle();
      expect(find.text('Add .datamap files'), findsNothing);
      expect(find.textContaining('Add to library'), findsOneWidget);
    });

    testWidgets('home shows the list after returning from settings',
        (tester) async {
      SharedPreferences.setMockInitialValues({'defaults_seeded_v4': true,
      'terms_accepted_version_v1': kTermsVersion});
      await LibraryStore.save([
        MediaList(
          id: '7',
          title: 'Weekend Queue',
          entries: const [MediaEntry(name: 'Show.S01E01.mkv', address: _addr)],
        ),
      ]);
      await tester.pumpWidget(const WatchItApp());
      await tester.pumpAndSettle();

      expect(find.text('Weekend Queue'), findsOneWidget);
      // Poster cards show the parsed display title, not the raw file name
      // (episode markers are stripped into season/episode since alpha.23).
      // The freshly saved entry appears twice: once in the Recently Added
      // row and once on its list's wall row.
      expect(find.text('Show'), findsNWidgets(2));
      expect(find.text('Your library is empty'), findsNothing);
    });
  });

  group('Media Lists page', () {
    testWidgets('unchecking a list hides it from home', (tester) async {
      SharedPreferences.setMockInitialValues({'defaults_seeded_v4': true,
      'terms_accepted_version_v1': kTermsVersion});
      await LibraryStore.save([
        MediaList(
          id: 'm',
          title: 'Movies',
          entries: const [MediaEntry(name: 'A.mkv', address: _addr)],
        ),
      ]);
      await tester.pumpWidget(const WatchItApp());
      await tester.pumpAndSettle();
      expect(find.text('Movies'), findsOneWidget);

      await tester.tap(find.byTooltip('Browse lists'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('My Media'));
      await tester.pumpAndSettle();

      // The built-in home rows carry checkboxes here too — target the
      // Movies list row's own.
      await tester.tap(find.descendant(
        of: find.widgetWithText(ListTile, 'Movies'),
        matching: find.byType(Checkbox),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('hidden from home'), findsOneWidget);
      expect((await LibraryStore.load()).single.enabled, isFalse);

      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Movies'), findsNothing);
      expect(find.text('All your lists are hidden'), findsOneWidget);
    });

    testWidgets('disabled list stays off the home wall', (tester) async {
      await LibraryStore.save([
        MediaList(
          id: 'on',
          title: 'Shown List',
          entries: const [MediaEntry(name: 'A.mkv', address: _addr)],
        ),
        MediaList(
          id: 'off',
          title: 'Hidden List',
          enabled: false,
          entries: const [MediaEntry(name: 'B.mkv', address: _addr)],
        ),
      ]);
      await tester.pumpWidget(const WatchItApp());
      await tester.pumpAndSettle();

      expect(find.text('Shown List'), findsOneWidget);
      expect(find.text('Hidden List'), findsNothing);
    });

    testWidgets('delete a list from its 3-dot menu', (tester) async {
      SharedPreferences.setMockInitialValues({'defaults_seeded_v4': true,
      'terms_accepted_version_v1': kTermsVersion});
      await LibraryStore.save([
        const MediaList(id: 'm', title: 'Movies'),
      ]);
      await tester.pumpWidget(const WatchItApp());
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Browse lists'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('My Media'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('List options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      // Confirmation dialog, then the list is gone from page and store.
      expect(find.textContaining('Delete "Movies"'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Movies'), findsNothing);
      expect(await LibraryStore.load(), isEmpty);
    });

    testWidgets('rename a list from its 3-dot menu', (tester) async {
      SharedPreferences.setMockInitialValues({'defaults_seeded_v4': true,
      'terms_accepted_version_v1': kTermsVersion});
      await LibraryStore.save([
        const MediaList(id: 'm', title: 'Movies'),
      ]);
      await tester.pumpWidget(const WatchItApp());
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Browse lists'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('My Media'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('List options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Renamed Movies');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('Renamed Movies'), findsOneWidget);
      expect((await LibraryStore.load()).single.title, 'Renamed Movies');
    });
  });

  group('Season grouping on home', () {
    testWidgets('episodes fold into a season card that opens the episodes',
        (tester) async {
      SharedPreferences.setMockInitialValues({'defaults_seeded_v4': true,
      'terms_accepted_version_v1': kTermsVersion});
      await LibraryStore.save([
        MediaList(
          id: 's',
          title: 'Series',
          entries: const [
            MediaEntry(name: 'Show.S01E02.mkv', address: _addr),
            MediaEntry(name: 'Show.S01E01.mkv', address: _addr),
            MediaEntry(name: 'The.Movie.2024.mkv', address: _addr),
          ],
        ),
      ]);
      await tester.pumpWidget(const WatchItApp());
      await tester.pumpAndSettle();

      // One season card + one movie card — not three cards. The entries
      // share one XOR address here, so the Recently Added row dedupes
      // them into a single extra show card ('Show' appears twice, the
      // full season/movie cards only on the list's wall row).
      expect(find.text('Show'), findsNWidgets(2));
      expect(find.text('Season 1 · 2 ep'), findsOneWidget);
      expect(find.text('The Movie (2024)'), findsOneWidget);

      // The keyless-nudge banner (shown here — no key, not dismissed)
      // pushes the wall down; scroll the card into view first.
      await tester.ensureVisible(find.text('Season 1 · 2 ep'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Season 1 · 2 ep'));
      await tester.pumpAndSettle();

      // Show page: big artwork header + the show's seasons as tiles.
      expect(find.text('SEASONS'), findsOneWidget);
      await tester.ensureVisible(find.text('Season 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Season 1'));
      await tester.pumpAndSettle();

      // Season screen: header + episodes sorted by number, each showing
      // its SxxEyy marker and name (fallback without TMDB).
      expect(find.text('Show — Season 1'), findsOneWidget);
      expect(find.textContaining('2 episodes'), findsOneWidget);
      expect(find.textContaining('S01E01'), findsOneWidget);
      expect(find.textContaining('S01E02'), findsOneWidget);
      expect(find.textContaining('Episode 1'), findsOneWidget);
      expect(find.textContaining('Episode 2'), findsOneWidget);

      // Tapping an episode opens the regular detail screen.
      await tester.ensureVisible(find.textContaining('Episode 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Episode 1'));
      await tester.pumpAndSettle();
      expect(find.text('Show.S01E01.mkv'), findsOneWidget);
      expect(find.text('FILE'), findsOneWidget);
    });
  });

  group('TMDB key privacy', () {
    testWidgets('key in use is never shown or prefilled', (tester) async {
      await AppSettings.setTmdbApiKey('supersecret9876');
      await tester.pumpWidget(const WatchItApp());
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Browse lists'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('TMDB API key'), 100);
      expect(find.text('Using your key'), findsOneWidget);
      // No fragment of the key anywhere on the page.
      expect(find.textContaining('9876'), findsNothing);
      expect(find.textContaining('supersecret'), findsNothing);

      // The edit dialog starts empty instead of prefilling the key.
      await tester.ensureVisible(find.text('TMDB API key'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('TMDB API key'));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller?.text ?? '', isEmpty);
    });
  });
}
