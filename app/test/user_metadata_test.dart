import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart'
    show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/bundle.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/services/user_metadata.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const name = 'Holiday 2019.mp4';
  final key = parseMediaName(name).lookupKey;
  const addr =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  final entry = MediaEntry(name: name, address: addr);

  late Directory postersDir;
  late List<http.Request> requests;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    postersDir = Directory.systemTemp.createTempSync('wi-user-meta');
    requests = [];
    MetadataService.instance = MetadataService(
      postersDirProvider: () async => postersDir,
      apiKeyProvider: () async => '',
      httpClient: MockClient((req) async {
        requests.add(req);
        return http.Response('{}', 404);
      }),
    );
  });

  tearDown(() {
    postersDir.deleteSync(recursive: true);
  });

  Future<MediaMetadata> resolvedMetadata() async {
    MetadataService.instance.metadataFor(entry);
    await MetadataService.instance.whenIdle();
    return MetadataService.instance.metadataFor(entry);
  }

  test('saved details come back through the metadata service', () async {
    await saveUserDetails(
      lookupKey: key,
      title: 'Our Holiday',
      year: 2019,
      overview: 'Two weeks at the coast.',
      postersDirProvider: () async => postersDir,
    );
    final meta = await resolvedMetadata();
    expect(meta.title, 'Our Holiday');
    expect(meta.year, 2019);
    expect(meta.overview, 'Two weeks at the coast.');
    final row = await metadataRowFor(key);
    expect(row!.userEdited, true);
    expect(row.found, true);
  });

  test('editing on top of a TMDB match keeps its extras', () async {
    final db = await LibraryStore.database();
    await db.into(db.metadataCache).insert(
          MetadataCacheCompanion.insert(
            lookupKey: key,
            found: true,
            title: const Value('Holiday'),
            year: const Value(2019),
            category: const Value('Drama'),
            rating: const Value(6.4),
            tmdbId: const Value(99),
            mediaType: const Value('movie'),
            fetchedAt: 0,
          ),
        );
    await saveUserDetails(
      lookupKey: key,
      title: 'Our Holiday',
      year: 2019,
      overview: 'Better description.',
      postersDirProvider: () async => postersDir,
    );
    final row = await metadataRowFor(key);
    expect(row!.title, 'Our Holiday');
    expect(row.overview, 'Better description.');
    expect(row.category, 'Drama');
    expect(row.rating, 6.4);
    expect(row.tmdbId, 99);
    expect(row.userEdited, true);
  });

  test('a user row is never re-fetched from TMDB', () async {
    // With an API key configured a cache miss would hit the mock TMDB
    // API; a found user row must short-circuit before any request.
    MetadataService.instance = MetadataService(
      postersDirProvider: () async => postersDir,
      apiKeyProvider: () async => 'some-key',
      httpClient: MockClient((req) async {
        requests.add(req);
        return http.Response(
            '{"results":[{"id":1}]}', 200,
            headers: {'content-type': 'application/json'});
      }),
    );
    await saveUserDetails(
      lookupKey: key,
      title: 'Our Holiday',
      postersDirProvider: () async => postersDir,
    );
    final meta = await resolvedMetadata();
    expect(meta.title, 'Our Holiday');
    expect(requests, isEmpty);
  });

  test('a new poster replaces the previous user file', () async {
    final first = await saveUserPoster(
        key, Uint8List.fromList([1, 2, 3]),
        postersDirProvider: () async => postersDir);
    await Future<void>.delayed(const Duration(milliseconds: 2));
    final second = await saveUserPoster(
        key, Uint8List.fromList([4, 5, 6]),
        postersDirProvider: () async => postersDir);
    expect(first, isNot(second));
    expect(File('${postersDir.path}/$first').existsSync(), false);
    expect(File('${postersDir.path}/$second').existsSync(), true);
  });

  test('removing artwork deletes user files but not TMDB ones', () async {
    final tmdbPoster = File('${postersDir.path}/movie_99.jpg')
      ..writeAsBytesSync([9, 9]);
    final userFile = await saveUserPoster(
        key, Uint8List.fromList([1]),
        postersDirProvider: () async => postersDir);
    await saveUserDetails(
      lookupKey: key,
      title: 'T',
      posterFile: Value(userFile),
      postersDirProvider: () async => postersDir,
    );
    // Remove the artwork: user file gone, unrelated TMDB file stays.
    await saveUserDetails(
      lookupKey: key,
      title: 'T',
      posterFile: const Value(null),
      postersDirProvider: () async => postersDir,
    );
    final row = await metadataRowFor(key);
    expect(row!.posterFile, isNull);
    expect(File('${postersDir.path}/$userFile').existsSync(), false);
    expect(tmdbPoster.existsSync(), true);
  });

  test('clearUserEdits removes the row and its artwork', () async {
    final file = await saveUserPoster(
        key, Uint8List.fromList([1]),
        postersDirProvider: () async => postersDir);
    await saveUserDetails(
      lookupKey: key,
      title: 'Our Holiday',
      posterFile: Value(file),
      postersDirProvider: () async => postersDir,
    );
    await clearUserEdits(key, postersDirProvider: () async => postersDir);
    expect(await metadataRowFor(key), isNull);
    expect(File('${postersDir.path}/$file').existsSync(), false);
    final meta = await resolvedMetadata();
    expect(meta.title, 'Holiday'); // parsed-name fallback again
  });

  test('clearUserEdits leaves a TMDB row alone', () async {
    final db = await LibraryStore.database();
    await db.into(db.metadataCache).insert(
          MetadataCacheCompanion.insert(
            lookupKey: key,
            found: true,
            title: const Value('Holiday'),
            fetchedAt: 0,
          ),
        );
    await clearUserEdits(key, postersDirProvider: () async => postersDir);
    expect(await metadataRowFor(key), isNotNull);
  });

  test('poster prefixes are unique for long keys', () {
    final a = userPosterPrefix('movie:${'x' * 80}a:2000');
    final b = userPosterPrefix('movie:${'x' * 80}b:2000');
    expect(a, isNot(b));
  });

  group('show/season scoping', () {
    const ep1Name = 'My Show S01E01.mkv';
    const ep2Name = 'My Show S01E02.mkv';
    final ep1 = MediaEntry(
        name: ep1Name,
        address:
            'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd');
    final ep2 = MediaEntry(
        name: ep2Name,
        address:
            'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee');
    final parsed = parseMediaName(ep1Name);

    Future<MediaMetadata> composed(MediaEntry e) async {
      MetadataService.instance.metadataFor(e);
      await MetadataService.instance.whenIdle();
      return MetadataService.instance.metadataFor(e);
    }

    test('show and season keys derive from the episode key', () {
      expect(parsed.lookupKey, 'tv:my show::s1:e1');
      expect(parsed.showLookupKey, 'tv:my show:');
      expect(parsed.seasonLookupKey, 'tv:my show::s1');
      final movie = parseMediaName(name);
      expect(movie.showLookupKey, movie.lookupKey);
      expect(movie.seasonLookupKey, isNull);
    });

    test('a show-level user row overlays every episode', () async {
      final poster = await saveUserPoster(
          parsed.showLookupKey, Uint8List.fromList([7]),
          postersDirProvider: () async => postersDir);
      await saveUserDetails(
        lookupKey: parsed.showLookupKey,
        title: 'Renamed Show',
        year: 1999,
        overview: 'A show of ours.',
        posterFile: Value(poster),
        postersDirProvider: () async => postersDir,
      );
      for (final e in [ep1, ep2]) {
        final meta = await composed(e);
        expect(meta.title, 'Renamed Show');
        expect(meta.year, 1999);
        expect(meta.showOverview, 'A show of ours.');
        expect(meta.showPosterFilePath, '${postersDir.path}/$poster');
        // Episode-level fields stay the episode's own.
        expect(meta.episodeLabel, startsWith('S01E'));
      }
    });

    test('a season-level user row overlays artwork and synopsis',
        () async {
      final poster = await saveUserPoster(
          parsed.seasonLookupKey!, Uint8List.fromList([8]),
          postersDirProvider: () async => postersDir);
      await saveUserDetails(
        lookupKey: parsed.seasonLookupKey!,
        title: 'My Show',
        overview: 'The first season.',
        posterFile: Value(poster),
        postersDirProvider: () async => postersDir,
      );
      final meta = await composed(ep1);
      expect(meta.posterFilePath, '${postersDir.path}/$poster');
      expect(meta.seasonOverview, 'The first season.');
      expect(meta.title, 'My Show'); // no show overlay — base title
    });

    test('an episode-scoped label save touches nothing show-level',
        () async {
      await saveUserDetails(
        lookupKey: parsed.lookupKey,
        title: 'My Show',
        episodeLabel: const Value('S01E01 · The One With The Beach'),
        overview: 'They go to the beach.',
        postersDirProvider: () async => postersDir,
      );
      final m1 = await composed(ep1);
      expect(m1.episodeLabel, 'S01E01 · The One With The Beach');
      expect(m1.overview, 'They go to the beach.');
      final m2 = await composed(ep2);
      expect(m2.episodeLabel, 'S01E02'); // sibling untouched
      expect(m2.overview, isNull);
      expect(await metadataRowFor(parsed.showLookupKey), isNull);
    });

    test('exported bundles carry show and season rows', () async {
      await saveUserDetails(
        lookupKey: parsed.showLookupKey,
        title: 'Renamed Show',
        postersDirProvider: () async => postersDir,
      );
      await saveUserDetails(
        lookupKey: parsed.seasonLookupKey!,
        title: 'Renamed Show',
        overview: 'The first season.',
        postersDirProvider: () async => postersDir,
      );
      final built = await buildBundle(
        [
          MediaList(id: 'l1', title: 'Shows', entries: [ep1, ep2])
        ],
        const BundleExportOptions(includeHistory: false),
        base: null,
        postersDirProvider: () async => postersDir,
      );
      final archive = ZipDecoder().decodeBytes(built.bytes);
      final metadataFile =
          archive.files.firstWhere((f) => f.name == 'metadata.json');
      final keys = ((jsonDecode(utf8.decode(metadataFile.readBytes()!))
              as Map<String, dynamic>)['entries'] as List)
          .cast<Map<String, dynamic>>()
          .map((r) => r['lookupKey'])
          .toSet();
      expect(keys, contains(parsed.showLookupKey));
      expect(keys, contains(parsed.seasonLookupKey));
    });
  });

  test('exported bundles carry userEdited and imports seed it', () async {
    await saveUserDetails(
      lookupKey: key,
      title: 'Our Holiday',
      overview: 'Ours.',
      postersDirProvider: () async => postersDir,
    );
    // Export: no embedded client in tests (base: null) so no datamap
    // members, but the metadata rows for the entries still go out.
    final built = await buildBundle(
      [
        MediaList(id: 'l1', title: 'Mine', entries: [entry])
      ],
      const BundleExportOptions(includeHistory: false),
      base: null,
      postersDirProvider: () async => postersDir,
    );
    final archive = ZipDecoder().decodeBytes(built.bytes);
    final metadataFile =
        archive.files.firstWhere((f) => f.name == 'metadata.json');
    final decoded = jsonDecode(utf8.decode(metadataFile.readBytes()!))
        as Map<String, dynamic>;
    final row = (decoded['entries'] as List).cast<Map<String, dynamic>>()
        .firstWhere((r) => r['lookupKey'] == key);
    expect(row['userEdited'], true);
    expect(row['title'], 'Our Holiday');

    // Import on a "fresh device": wipe the cache, gap-fill from the
    // exported rows, and the flag survives the round trip.
    final db = await LibraryStore.database();
    await db.delete(db.metadataCache).go();
    await seedMetadataGapFill(
      {key: row},
      const {},
      postersDirProvider: () async => postersDir,
    );
    final seeded = await metadataRowFor(key);
    expect(seeded!.userEdited, true);
    expect(seeded.title, 'Our Holiday');
  });
}
