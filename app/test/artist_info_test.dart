import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/screens/artist_screen.dart';
import 'package:watchit/services/artist_info.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/services/musicbrainz_client.dart';
import 'package:watchit/services/season_grouping.dart';
import 'package:watchit/theme/tokens.dart';

const _relMbid = 'c07f0676-9d95-4443-a841-b1cbcfa48f4e';
const _artistMbid = 'b071f9fa-14b0-4217-8e97-eb41da73f598';
const _portraitBytes = [0xFF, 0xD8, 0xFF, 0xE0];
const _thumbBytes = [0xFF, 0xD8, 0xFF, 0xE1];

String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

MediaEntry _track(String album, int year, int n, {String? mbid}) =>
    MediaEntry(
      name: 'The Rolling Stones - $album ($year) - '
          '0$n Track $n${mbid != null ? ' {mbid-$mbid}' : ''}.mp3',
      address: _addr(year * 10 + n),
    );

/// The artist fold the page shows: two Stones albums, one release
/// mbid-tagged.
HomeArtist _artist({String? mbid = _relMbid}) => groupShows([
      _track('Let It Bleed', 1969, 1, mbid: mbid),
      _track('Beggars Banquet', 1968, 1),
    ]).single as HomeArtist;

/// Canned keyless chain: MusicBrainz release/artist/search, Wikidata,
/// Wikipedia summary, Commons portrait.
http.Response _wire(http.Request req, {String bio = 'An English rock band '
    'formed in London in 1962, among the most influential of all time.'}) {
  final url = req.url;
  Map<String, dynamic>? body;
  if (url.host == 'musicbrainz.org') {
    if (url.path == '/ws/2/release/$_relMbid') {
      body = {
        'artist-credit': [
          {
            'artist': {'id': _artistMbid, 'name': 'The Rolling Stones'},
          }
        ],
      };
    } else if (url.path == '/ws/2/artist/$_artistMbid') {
      body = {
        'name': 'The Rolling Stones',
        'life-span': {'begin': '1962-07'},
        'area': {'name': 'London'},
        'genres': [
          {'name': 'blues rock', 'count': 5},
          {'name': 'rock', 'count': 11},
        ],
        'relations': [
          {
            'type': 'wikidata',
            'url': {'resource': 'https://www.wikidata.org/wiki/Q11036'},
          }
        ],
      };
    } else if (url.path == '/ws/2/artist') {
      final q = url.queryParameters['query'] ?? '';
      body = {
        'artists': q.contains('The Rolling Stones')
            ? [
                {
                  'id': _artistMbid,
                  'name': 'The Rolling Stones',
                  'score': 100,
                }
              ]
            : q.contains('Close Enough')
                ? [
                    {'id': 'x', 'name': 'Close Enough Band', 'score': 95}
                  ]
                : [],
      };
    }
  } else if (url.host == 'www.wikidata.org' &&
      url.path == '/wiki/Special:EntityData/Q11036.json') {
    body = {
      'entities': {
        'Q11036': {
          'claims': {
            'P18': [
              {
                'mainsnak': {
                  'datavalue': {'value': 'Stones 1965.jpg'},
                },
              }
            ],
          },
          'sitelinks': {
            'enwiki': {'title': 'The Rolling Stones'},
          },
        },
      },
    };
  } else if (url.host == 'en.wikipedia.org' &&
      url.path.startsWith('/api/rest_v1/page/summary/')) {
    body = {
      'extract': bio,
      'content_urls': {
        'desktop': {
          'page': 'https://en.wikipedia.org/wiki/The_Rolling_Stones',
        },
      },
      'thumbnail': {'source': 'https://upload.wikimedia.org/thumb.jpg'},
    };
  } else if (url.host == 'commons.wikimedia.org') {
    return http.Response.bytes(_portraitBytes, 200);
  } else if (url.host == 'upload.wikimedia.org') {
    return http.Response.bytes(_thumbBytes, 200);
  }
  if (body == null) return http.Response('not found', 404);
  return http.Response(jsonEncode(body), 200,
      headers: {'content-type': 'application/json'});
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory postersDir;
  late List<http.Request> requests;
  var paused = false;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    requests = [];
    paused = false;
    postersDir = Directory.systemTemp.createTempSync('wi-artistinfo');
  });

  tearDown(() {
    try {
      postersDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> freshDb() => LibraryStore.useForTesting(
      AppDatabase.forTesting(NativeDatabase.memory()));

  ArtistInfoService service({http.Response Function(http.Request)? wire}) =>
      ArtistInfoService(
        httpClient: MockClient((req) async {
          requests.add(req);
          return (wire ?? _wire)(req);
        }),
        postersDirProvider: () async => postersDir,
        pausedProvider: () => paused,
        mbInterval: Duration.zero,
      );

  /// Resolve through [infoFor]'s background schedule and return the
  /// settled answer.
  Future<ArtistInfo?> resolve(ArtistInfoService s,
      {String artist = 'The Rolling Stones',
      List<String> mbids = const [_relMbid]}) async {
    final first = s.infoFor(artist, releaseMbids: mbids);
    if (first != null) return first;
    await s.whenIdle();
    return s.infoFor(artist, releaseMbids: mbids);
  }

  group('ArtistInfoService', () {
    test('release mbid resolves the full chain: facts, bio, portrait',
        () async {
      await freshDb();
      final info = await resolve(service());
      expect(info, isNotNull);
      expect(info!.name, 'The Rolling Stones');
      expect(info.mbid, _artistMbid);
      expect(info.formedYear, 1962);
      expect(info.country, 'London');
      // Genres sorted by community count, capitalized, joined ` · `.
      expect(info.genres, 'Rock · Blues rock');
      expect(info.bio, contains('English rock band'));
      expect(info.bioUrl,
          'https://en.wikipedia.org/wiki/The_Rolling_Stones');
      expect(info.factsLine, 'Formed 1962 · London · Rock · Blues rock');
      // The P18 Commons portrait landed on disk under the artist mbid.
      expect(info.portraitPath, endsWith('artist_$_artistMbid.jpg'));
      expect(File(info.portraitPath!).readAsBytesSync(), _portraitBytes);
      // The DB row persists it all for offline rendering.
      final db = await LibraryStore.database();
      final row = await db.select(db.artistMeta).getSingle();
      expect(row.artistKey, 'the rolling stones');
      expect(row.found, isTrue);
      expect(row.portraitFile, 'artist_$_artistMbid.jpg');
      // MusicBrainz etiquette: a real User-Agent on every request.
      for (final req
          in requests.where((r) => r.url.host == 'musicbrainz.org')) {
        expect(req.headers['User-Agent'], MusicBrainzClient.userAgent);
      }
      // No name search needed — the release tag identified the artist.
      expect(requests.map((r) => r.url.path),
          isNot(contains('/ws/2/artist')));
    });

    test('pull-once: a cached row serves a fresh session with zero '
        'network', () async {
      await freshDb();
      await resolve(service());
      requests.clear();
      final again = await resolve(service());
      expect(again!.name, 'The Rolling Stones');
      expect(again.bio, contains('English rock band'));
      expect(again.portraitPath, isNotNull);
      expect(requests, isEmpty);
    });

    test('no release tag falls back to the exact-name search', () async {
      await freshDb();
      final info = await resolve(service(), mbids: const []);
      expect(info!.mbid, _artistMbid);
      expect(
          requests.first.url.path, '/ws/2/artist'); // search came first
    });

    test('a fuzzy search hit is refused and cached as a miss', () async {
      await freshDb();
      // Top hit scores 95 with a different name — wrong-artist risk, so
      // the page gets nothing rather than someone else's bio.
      final info = await resolve(service(),
          artist: 'Close Enough', mbids: const []);
      expect(info, isNull);
      final db = await LibraryStore.database();
      final row = await db.select(db.artistMeta).getSingle();
      expect(row.found, isFalse);
      // Pull-once applies to misses too: a fresh session stays quiet.
      requests.clear();
      expect(
          await resolve(service(), artist: 'Close Enough', mbids: const []),
          isNull);
      expect(requests, isEmpty);
    });

    test('a transport error caches nothing, so the next session retries',
        () async {
      await freshDb();
      final info = await resolve(
          service(wire: (req) => http.Response('down', 500)));
      expect(info, isNull);
      final db = await LibraryStore.database();
      expect(await db.select(db.artistMeta).get(), isEmpty);
      requests.clear();
      // Next session (fresh instance): the chain runs again and lands.
      final again = await resolve(service());
      expect(again!.name, 'The Rolling Stones');
      expect(requests, isNotEmpty);
    });

    test('Offline mode skips the fetch without caching a miss', () async {
      await freshDb();
      paused = true;
      final info = await resolve(service());
      expect(info, isNull);
      expect(requests, isEmpty);
      final db = await LibraryStore.database();
      expect(await db.select(db.artistMeta).get(), isEmpty);
    });

    test('a failing Wikimedia leg degrades to facts-only, still cached '
        'as found', () async {
      await freshDb();
      final info = await resolve(service(
          wire: (req) => req.url.host == 'musicbrainz.org'
              ? _wire(req)
              : http.Response('down', 500)));
      expect(info!.name, 'The Rolling Stones');
      expect(info.formedYear, 1962);
      expect(info.bio, isNull);
      expect(info.portraitPath, isNull);
      final db = await LibraryStore.database();
      expect((await db.select(db.artistMeta).getSingle()).found, isTrue);
    });

    test('ambiguous release credits with no exact match resolve to a '
        'miss, one agreed credit is adopted', () async {
      await freshDb();
      http.Response two(http.Request req) {
        final path = req.url.path;
        if (path == '/ws/2/release/aaa') {
          return http.Response(
              jsonEncode({
                'artist-credit': [
                  {
                    'artist': {'id': 'a1', 'name': 'Somebody Else'}
                  }
                ]
              }),
              200);
        }
        if (path == '/ws/2/release/bbb') {
          return http.Response(
              jsonEncode({
                'artist-credit': [
                  {
                    'artist': {'id': 'a2', 'name': 'Another Act'}
                  }
                ]
              }),
              200);
        }
        return http.Response('not found', 404);
      }

      // Two tagged releases crediting two different artists, neither
      // matching the page name, search missing → no info.
      expect(
          await resolve(service(wire: two),
              artist: 'Renamed Artist', mbids: const ['aaa', 'bbb']),
          isNull);

      // But when every tagged release agrees on ONE artist, a
      // formatting-only name difference is accepted.
      await freshDb();
      http.Response one(http.Request req) {
        if (req.url.path == '/ws/2/release/aaa') {
          return http.Response(
              jsonEncode({
                'artist-credit': [
                  {
                    'artist': {'id': _artistMbid, 'name': 'Rolling Stones'}
                  }
                ]
              }),
              200);
        }
        return _wire(req);
      }

      final info = await resolve(service(wire: one),
          artist: 'The Stones', mbids: const ['aaa']);
      expect(info!.mbid, _artistMbid);
    });

    test('refresh drops the row and portrait and refetches', () async {
      await freshDb();
      final db = await LibraryStore.database();
      // Seed a stale row with an old portrait file.
      File('${postersDir.path}/artist_old.jpg')
          .writeAsBytesSync([1, 2, 3]);
      await db.into(db.artistMeta).insertOnConflictUpdate(
            ArtistMetaCompanion.insert(
              artistKey: 'the rolling stones',
              found: true,
              name: const Value('Old Name'),
              portraitFile: const Value('artist_old.jpg'),
              fetchedAt: 1,
            ),
          );
      final s = service();
      await s.refresh('The Rolling Stones', releaseMbids: const [_relMbid]);
      expect(File('${postersDir.path}/artist_old.jpg').existsSync(),
          isFalse);
      final row = await db.select(db.artistMeta).getSingle();
      expect(row.name, 'The Rolling Stones');
      expect(row.portraitFile, 'artist_$_artistMbid.jpg');
      expect(s.infoFor('The Rolling Stones')!.name, 'The Rolling Stones');
    });

    test('refresh surfaces transport errors to the caller', () async {
      await freshDb();
      final s = service(wire: (req) => http.Response('down', 500));
      await expectLater(
          s.refresh('The Rolling Stones',
              releaseMbids: const [_relMbid]),
          throwsA(isA<MbException>()));
    });
  });

  group('ArtistScreen', () {
    Future<void> pump(WidgetTester tester, {String? mbid = _relMbid}) async {
      await tester.pumpWidget(MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: ArtistScreen(group: _artist(mbid: mbid)),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('renders cached facts, bio, portrait and attribution '
        'offline', (tester) async {
      await freshDb();
      final db = await LibraryStore.database();
      File('${postersDir.path}/artist_$_artistMbid.jpg')
          .writeAsBytesSync(_portraitBytes);
      await db.into(db.artistMeta).insertOnConflictUpdate(
            ArtistMetaCompanion.insert(
              artistKey: 'the rolling stones',
              found: true,
              mbid: const Value(_artistMbid),
              name: const Value('The Rolling Stones'),
              bio: const Value('An English rock band formed in London.'),
              bioUrl: const Value('https://en.wikipedia.org/wiki/X'),
              formedYear: const Value(1962),
              country: const Value('London'),
              genres: const Value('Rock'),
              portraitFile: const Value('artist_$_artistMbid.jpg'),
              fetchedAt: 1,
            ),
          );
      ArtistInfoService.instance = service();
      MetadataService.instance = MetadataService(
          httpClient: MockClient((req) async => http.Response('', 404)),
          postersDirProvider: () async => postersDir,
          apiKeyProvider: () async => '');
      await pump(tester);
      expect(find.text('Formed 1962 · London · Rock'), findsOneWidget);
      expect(find.text('An English rock band formed in London.'),
          findsOneWidget);
      expect(find.text('Bio from Wikipedia (CC BY-SA)'), findsOneWidget);
      expect(find.text('2 albums · 2 tracks'), findsOneWidget);
      expect(find.byType(ClipOval), findsOneWidget); // portrait circle
      // Offline: the cached row answered — nothing was fetched.
      expect(requests, isEmpty);
    });

    testWidgets('long bios collapse behind a More/Less toggle',
        (tester) async {
      await freshDb();
      final db = await LibraryStore.database();
      final longBio =
          List.filled(40, 'A very long biography sentence.').join(' ');
      await db.into(db.artistMeta).insertOnConflictUpdate(
            ArtistMetaCompanion.insert(
              artistKey: 'the rolling stones',
              found: true,
              name: const Value('The Rolling Stones'),
              bio: Value(longBio),
              fetchedAt: 1,
            ),
          );
      ArtistInfoService.instance = service();
      MetadataService.instance = MetadataService(
          httpClient: MockClient((req) async => http.Response('', 404)),
          postersDirProvider: () async => postersDir,
          apiKeyProvider: () async => '');
      await pump(tester);
      final collapsed =
          tester.widget<Text>(find.text(longBio, findRichText: false));
      expect(collapsed.maxLines, 4);
      await tester.tap(find.text('More'));
      await tester.pump();
      expect(
          tester.widget<Text>(find.text(longBio)).maxLines, isNull);
      // The expanded bio pushes the toggle below the fold.
      await tester.ensureVisible(find.text('Less'));
      await tester.pump();
      await tester.tap(find.text('Less'));
      await tester.pump();
      expect(tester.widget<Text>(find.text(longBio)).maxLines, 4);
    });

    testWidgets('the Refresh action reruns the chain and updates the '
        'page', (tester) async {
      await freshDb();
      final db = await LibraryStore.database();
      // A cached miss — pull-once would never retry it on its own.
      await db.into(db.artistMeta).insertOnConflictUpdate(
            ArtistMetaCompanion.insert(
              artistKey: 'the rolling stones',
              found: false,
              fetchedAt: 1,
            ),
          );
      ArtistInfoService.instance = service();
      MetadataService.instance = MetadataService(
          httpClient: MockClient((req) async => http.Response('', 404)),
          postersDirProvider: () async => postersDir,
          apiKeyProvider: () async => '');
      await pump(tester);
      expect(find.textContaining('Formed 1962'), findsNothing);
      await tester.tap(find.byTooltip('Refresh artist info'));
      await tester.pumpAndSettle();
      expect(find.text('Formed 1962 · London · Rock · Blues rock'),
          findsOneWidget);
      expect(requests, isNotEmpty);
      expect((await db.select(db.artistMeta).getSingle()).found, isTrue);
    });
  });
}
