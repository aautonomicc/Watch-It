import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/services/tmdb_client.dart';

/// Live TMDB smoke tests — hit the real API with the credentials from the
/// repo-root `.env`. Skipped (e.g. in CI) unless the key is in the
/// environment:
///
///     set -a; source ../.env; set +a; flutter test test/tmdb_live_test.dart
///
/// The widgets binding is needed (LibraryStore's legacy-import check reads
/// SharedPreferences), but flutter_test's binding replaces HttpClient with
/// a 400-only mock — clearing HttpOverrides.global restores real network
/// access for the live calls these tests exist to make.
void main() {
  final apiKey = Platform.environment['TMDB_API_KEY'] ?? '';
  final readToken = Platform.environment['TMDB_READ_ACCESS_TOKEN'] ?? '';

  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  SharedPreferences.setMockInitialValues({});
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('live TMDB (v3 api key)', () {
    late TmdbClient client;

    setUp(() => client = TmdbClient(apiKey: apiKey));
    tearDown(() => client.close());

    test('movie lookup by title/year', () async {
      final match = await client.lookup(parseMediaName('Inception (2010).mkv'));
      expect(match, isNotNull);
      expect(match!.mediaType, 'movie');
      expect(match.title, 'Inception');
      expect(match.year, 2010);
      expect(match.overview, isNotEmpty);
      expect(match.category, isNotEmpty);
      expect(match.posterPath, isNotNull);
    });

    test('tv episode lookup with episode details', () async {
      final match =
          await client.lookup(parseMediaName('Breaking Bad S01E02.mkv'));
      expect(match, isNotNull);
      expect(match!.mediaType, 'tv');
      expect(match.title, 'Breaking Bad');
      expect(match.year, 2008);
      expect(match.episodeLabel, startsWith('S01E02'));
      // Episode synopsis should have replaced the show blurb.
      expect(match.overview, isNotEmpty);
    });

    test('nonsense title is a miss, not an error', () async {
      final match = await client
          .lookup(parseMediaName('Zqxv Wpltk Nonexistent 9843.mkv'));
      expect(match, isNull);
    });

    test('poster CDN fetch returns image bytes', () async {
      final match = await client.lookup(parseMediaName('Inception (2010).mkv'));
      final bytes = await client.fetchPoster(match!.posterPath!);
      expect(bytes.length, greaterThan(5000));
      // JPEG magic bytes.
      expect(bytes[0], 0xFF);
      expect(bytes[1], 0xD8);
    });
  }, skip: apiKey.isEmpty ? 'TMDB_API_KEY not set (source .env)' : false);

  group('live TMDB (v4 read token)', () {
    test('bearer-header auth path works', () async {
      final client = TmdbClient(apiKey: readToken);
      try {
        final match =
            await client.lookup(parseMediaName('Inception (2010).mkv'));
        expect(match, isNotNull);
        expect(match!.title, 'Inception');
      } finally {
        client.close();
      }
    });
  },
      skip: readToken.isEmpty
          ? 'TMDB_READ_ACCESS_TOKEN not set (source .env)'
          : false);

  group('live end-to-end MetadataService', () {
    late Directory postersDir;
    late MetadataService service;

    setUp(() async {
      await LibraryStore.useForTesting(
          AppDatabase.forTesting(NativeDatabase.memory()));
      postersDir = await Directory.systemTemp.createTemp('watchit_live');
      service = MetadataService(
        postersDirProvider: () async => postersDir,
        apiKeyProvider: () async => apiKey,
      );
    });

    tearDown(() async {
      await postersDir.delete(recursive: true);
    });

    test('file name resolves to cached TMDB metadata + poster on disk',
        () async {
      const entry = MediaEntry(
        name: 'Inception.2010.1080p.BluRay.x264.mkv',
        address:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      // First call schedules the background resolve and returns the
      // parsed-name fallback.
      expect(service.metadataFor(entry).title, 'Inception');
      await service.whenIdle();

      final meta = service.metadataFor(entry);
      expect(meta.year, 2010);
      expect(meta.overview, isNotEmpty);
      expect(meta.category, isNotEmpty);
      expect(meta.posterFilePath, isNotNull);
      final poster = File(meta.posterFilePath!);
      expect(poster.existsSync(), isTrue);
      expect(poster.lengthSync(), greaterThan(5000));

      // The result must be in the SQLite cache: a fresh service instance
      // resolves from the DB (no fetch would find the poster file again
      // in the same temp dir either way, but title/year come from cache).
      final second = MetadataService(
        postersDirProvider: () async => postersDir,
        apiKeyProvider: () async => '', // no key → cache is the only source
      );
      expect(second.metadataFor(entry).title, 'Inception'); // fallback
      await second.whenIdle();
      final cached = second.metadataFor(entry);
      expect(cached.year, 2010);
      expect(cached.posterFilePath, meta.posterFilePath);
    });
  }, skip: apiKey.isEmpty ? 'TMDB_API_KEY not set (source .env)' : false);
}
