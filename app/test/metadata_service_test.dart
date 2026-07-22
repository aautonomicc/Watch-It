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
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/services/tmdb_client.dart';

const _posterBytes = [0x89, 0x50, 0x4E, 0x47];

/// Canned TMDB v3 API: NOTLD by IMDb id, "The Movie (2024)" by search,
/// one TV show with an episode. Everything else is a valid empty result.
http.Response _tmdbApi(http.Request req) {
  final path = req.url.path;
  Map<String, dynamic>? body;
  if (path == '/3/find/tt0063350') {
    body = {
      'movie_results': [
        {'id': 10331}
      ],
      'tv_results': [],
    };
  } else if (path == '/3/movie/10331') {
    body = {
      'title': 'Night of the Living Dead',
      'release_date': '1968-10-04',
      'overview': 'The dead rise in rural Pennsylvania.',
      'genres': [
        {'name': 'Horror'},
        {'name': 'Thriller'},
      ],
      'poster_path': '/notld.jpg',
      'vote_average': 7.5,
    };
  } else if (path == '/3/search/movie') {
    final query = req.url.queryParameters['query'];
    body = {
      'results': query == 'The Movie'
          ? [
              {'id': 42}
            ]
          : [],
    };
  } else if (path == '/3/movie/42') {
    body = {
      'title': 'The Movie',
      'release_date': '2024-06-01',
      'overview': 'A movie.',
      'genres': [
        {'name': 'Drama'}
      ],
      'poster_path': '/movie42.jpg',
      'vote_average': 6.8,
    };
  } else if (path == '/3/search/tv') {
    final query = req.url.queryParameters['query'];
    body = {
      'results': query == 'Show'
          ? [
              {'id': 7}
            ]
          : [],
    };
  } else if (path == '/3/tv/7') {
    body = {
      'name': 'Show',
      'first_air_date': '2019-01-10',
      'overview': 'A show.',
      'genres': [
        {'name': 'Comedy'}
      ],
      'poster_path': '/show7.jpg',
      'vote_average': 8.3,
    };
  } else if (path == '/3/tv/7/season/1') {
    body = {
      'poster_path': '/show7_s1.jpg',
      'overview': 'Season one happens.',
      'episodes': [
        {'episode_number': 1, 'name': 'The First One', 'overview': ''},
        {
          'episode_number': 2,
          'name': 'The Second One',
          'overview': 'Episode two happens.',
          'air_date': '2019-01-17',
          'still_path': '/e2_still.jpg',
        },
      ],
    };
  }
  if (body == null) {
    return http.Response('{"status_message":"not found"}', 404);
  }
  return http.Response(jsonEncode(body), 200,
      headers: {'content-type': 'application/json'});
}

MockClient _mockTmdb(List<http.Request> requestLog) {
  return MockClient((req) async {
    requestLog.add(req);
    if (req.url.host == 'image.tmdb.org') {
      return http.Response.bytes(_posterBytes, 200);
    }
    return _tmdbApi(req);
  });
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const addr =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  late List<http.Request> requests;
  late Directory postersDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    requests = [];
    postersDir = await Directory.systemTemp.createTemp('watchit_posters');
  });

  tearDown(() async {
    await postersDir.delete(recursive: true);
  });

  MetadataService service({String apiKey = 'k3y'}) => MetadataService(
        httpClient: _mockTmdb(requests),
        postersDirProvider: () async => postersDir,
        apiKeyProvider: () async => apiKey,
      );

  group('TmdbClient', () {
    test('imdb-tagged names resolve via /find + details', () async {
      final client = TmdbClient(apiKey: 'k3y', client: _mockTmdb(requests));
      final match = await client.lookup(parseMediaName(
          'Night of the Living Dead (1968) {imdb-tt0063350} - [1080p].mp4'));
      expect(match!.mediaType, 'movie');
      expect(match.title, 'Night of the Living Dead');
      expect(match.year, 1968);
      expect(match.category, 'Horror · Thriller');
      expect(match.posterPath, '/notld.jpg');
      expect(match.rating, 7.5);
      // v3 hex key travels as the api_key query parameter.
      expect(requests.first.url.queryParameters['api_key'], 'k3y');
      expect(requests.first.headers.containsKey('Authorization'), isFalse);
    });

    test('untagged names resolve via title/year search', () async {
      final client = TmdbClient(apiKey: 'k3y', client: _mockTmdb(requests));
      final match =
          await client.lookup(parseMediaName('The.Movie.2024.1080p.mkv'));
      expect(match!.tmdbId, 42);
      expect(match.overview, 'A movie.');
      expect(requests.first.url.path, '/3/search/movie');
      expect(requests.first.url.queryParameters['year'], '2024');
    });

    test('episode names resolve show + episode details', () async {
      final client = TmdbClient(apiKey: 'k3y', client: _mockTmdb(requests));
      final match = await client.lookup(parseMediaName('Show.S01E02.mkv'));
      expect(match!.mediaType, 'tv');
      expect(match.title, 'Show');
      expect(match.year, 2019);
      expect(match.episodeLabel, 'S01E02 · The Second One');
      expect(match.overview, 'Episode two happens.');
      expect(match.category, 'Comedy');
      // Season artwork beats the show poster for episode matches.
      expect(match.season, 1);
      expect(match.episode, 2);
      expect(match.posterPath, '/show7_s1.jpg');
      // Show/season/episode extras for the show and season pages.
      expect(match.rating, 8.3);
      expect(match.showOverview, 'A show.');
      expect(match.seasonOverview, 'Season one happens.');
      expect(match.airDate, '2019-01-17');
      expect(match.stillPath, '/e2_still.jpg');
      expect(match.showPosterPath, '/show7.jpg');
    });

    test('unknown season number keeps show-level metadata', () async {
      final client = TmdbClient(apiKey: 'k3y', client: _mockTmdb(requests));
      final match = await client.lookup(parseMediaName('Show.S09E09.mkv'));
      expect(match!.episodeLabel, 'S09E09');
      expect(match.overview, 'A show.');
      expect(match.posterPath, '/show7.jpg');
    });

    test('unknown episode in a known season keeps season artwork', () async {
      final client = TmdbClient(apiKey: 'k3y', client: _mockTmdb(requests));
      final match = await client.lookup(parseMediaName('Show.S01E09.mkv'));
      expect(match!.episodeLabel, 'S01E09');
      expect(match.overview, 'A show.');
      expect(match.posterPath, '/show7_s1.jpg');
    });

    test('no TMDB result returns null (movie and tv both miss)', () async {
      final client = TmdbClient(apiKey: 'k3y', client: _mockTmdb(requests));
      final match =
          await client.lookup(parseMediaName('Nonexistent.2020.mkv'));
      expect(match, isNull);
      expect(requests.map((r) => r.url.path),
          ['/3/search/movie', '/3/search/tv']);
    });

    test('v4 read access tokens travel as a Bearer header', () async {
      final client =
          TmdbClient(apiKey: 'a.b.c', client: _mockTmdb(requests));
      await client.lookup(parseMediaName('The.Movie.2024.mkv'));
      expect(requests.first.headers['Authorization'], 'Bearer a.b.c');
      expect(
          requests.first.url.queryParameters.containsKey('api_key'), isFalse);
    });

    test('API errors throw TmdbException', () async {
      final client = TmdbClient(
        apiKey: 'k3y',
        client: MockClient((req) async => http.Response('nope', 500)),
      );
      expect(client.lookup(parseMediaName('The.Movie.2024.mkv')),
          throwsA(isA<TmdbException>()));
    });
  });

  group('formatAirDate', () {
    test('formats ISO dates for display', () {
      expect(formatAirDate('2019-01-17'), '17 Jan 2019');
      expect(formatAirDate('2008-12-01'), '1 Dec 2008');
    });

    test('passes non-ISO strings through unchanged', () {
      expect(formatAirDate('2019'), '2019');
      expect(formatAirDate('2019-13-01'), '2019-13-01');
    });
  });

  group('MetadataService', () {
    const entry = MediaEntry(name: 'The.Movie.2024.1080p.mkv', address: addr);

    test('resolves via TMDB, caches match + poster, notifies', () async {
      final svc = service();
      var notified = 0;
      svc.addListener(() => notified++);

      // First call returns the parsed-name fallback and starts a lookup.
      final first = svc.metadataFor(entry);
      expect(first.overview, isNull);
      await svc.whenIdle();
      expect(notified, 1);

      final resolved = svc.metadataFor(entry);
      expect(resolved.title, 'The Movie');
      expect(resolved.year, 2024);
      expect(resolved.overview, 'A movie.');
      expect(resolved.category, 'Drama');
      expect(resolved.rating, 6.8);
      expect(resolved.posterFilePath, isNotNull);
      expect(File(resolved.posterFilePath!).readAsBytesSync(), _posterBytes);
    });

    test('episode posters are cached per season, not per show', () async {
      const ep = MediaEntry(name: 'Show.S01E02.mkv', address: addr);
      final svc = service();
      svc.metadataFor(ep);
      await svc.whenIdle();
      final meta = svc.metadataFor(ep);
      expect(meta.episodeLabel, 'S01E02 · The Second One');
      expect(meta.posterFilePath, endsWith('tv_7_s1.jpg'),
          reason: 'a show-level match must not share the season poster file');
    });

    test('episode extras (still, air date, synopses) survive the cache',
        () async {
      const ep = MediaEntry(name: 'Show.S01E02.mkv', address: addr);
      final svc = service();
      svc.metadataFor(ep);
      await svc.whenIdle();

      // Fresh instance = fresh in-memory state, same database — the
      // second read exercises the SQLite row, not the TMDB response.
      final svc2 = service();
      svc2.metadataFor(ep);
      await svc2.whenIdle();
      final meta = svc2.metadataFor(ep);
      expect(meta.rating, 8.3);
      expect(meta.showOverview, 'A show.');
      expect(meta.seasonOverview, 'Season one happens.');
      expect(meta.airDate, '2019-01-17');
      expect(meta.overview, 'Episode two happens.');
      expect(meta.stillFilePath, endsWith('tv_7_s1e2_still.jpg'));
      expect(meta.showPosterFilePath, endsWith('tv_7.jpg'),
          reason: 'show page needs the show poster, not the season one');
      expect(File(meta.stillFilePath!).readAsBytesSync(), _posterBytes);
    });

    test('second session serves from SQLite with no network', () async {
      final svc = service();
      svc.metadataFor(entry);
      await svc.whenIdle();
      final fetched = requests.length;

      // Fresh instance = fresh in-memory state, same database.
      final svc2 = service();
      svc2.metadataFor(entry);
      await svc2.whenIdle();
      final cached = svc2.metadataFor(entry);
      expect(cached.title, 'The Movie');
      expect(cached.posterFilePath, isNotNull);
      expect(requests.length, fetched, reason: 'cache hit must not refetch');
    });

    test('TMDB misses are cached and not retried next session', () async {
      const unknown = MediaEntry(name: 'Nonexistent.2020.mkv', address: addr);
      final svc = service();
      svc.metadataFor(unknown);
      await svc.whenIdle();
      final fetched = requests.length;
      expect(svc.metadataFor(unknown).title, 'Nonexistent');

      final svc2 = service();
      svc2.metadataFor(unknown);
      await svc2.whenIdle();
      expect(svc2.metadataFor(unknown).title, 'Nonexistent');
      expect(requests.length, fetched);
    });

    test('no API key: falls back to parsed name, nothing cached', () async {
      final svc = service(apiKey: '');
      final meta = svc.metadataFor(entry);
      expect(meta.title, 'The Movie');
      await svc.whenIdle();
      expect(requests, isEmpty);
      final db = await LibraryStore.database();
      expect(await db.select(db.metadataCache).get(), isEmpty);
    });

    test('transport errors leave the cache untouched for retry', () async {
      final failing = MetadataService(
        httpClient: MockClient((req) async => http.Response('down', 500)),
        postersDirProvider: () async => postersDir,
        apiKeyProvider: () async => 'k3y',
      );
      final meta = failing.metadataFor(entry);
      expect(meta.title, 'The Movie'); // parsed fallback, no crash
      await failing.whenIdle();
      final db = await LibraryStore.database();
      expect(await db.select(db.metadataCache).get(), isEmpty,
          reason: 'offline must not be recorded as a permanent miss');
    });

    test('reset clears cached misses so a new key retries them', () async {
      const unknown = MediaEntry(name: 'Nonexistent.2020.mkv', address: addr);
      final svc = service();
      svc.metadataFor(entry);
      svc.metadataFor(unknown);
      await svc.whenIdle();
      await svc.reset();
      final db = await LibraryStore.database();
      final rows = await db.select(db.metadataCache).get();
      expect(rows, hasLength(1), reason: 'found rows survive a reset');
      expect(rows.single.found, isTrue);
    });
  });
}
