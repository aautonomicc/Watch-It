import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/screens/describe_item_screen.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/theme/tokens.dart';

/// A real (1x1 transparent) PNG — the preview dialog and the artwork
/// slot render it with Image widgets, which decode it.
const _posterBytes = [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
  0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89,
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62,
  0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4,
  0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60,
  0x82,
];

/// Canned TMDB v3 API: "The Movie (2024)" by search, everything else a
/// valid empty result (same shape as metadata_service_test.dart).
MockClient _mockTmdb() {
  return MockClient((req) async {
    if (req.url.host == 'image.tmdb.org') {
      return http.Response.bytes(_posterBytes, 200);
    }
    final path = req.url.path;
    Map<String, dynamic>? body;
    if (path == '/3/search/movie') {
      body = {
        'results': req.url.queryParameters['query'] == 'The Movie'
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
      body = {'results': []};
    }
    if (body == null) {
      return http.Response('{"status_message":"not found"}', 404);
    }
    return http.Response(jsonEncode(body), 200,
        headers: {'content-type': 'application/json'});
  });
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory postersDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    postersDir = await Directory.systemTemp.createTemp('watchit_posters');
  });

  tearDown(() async {
    MetadataService.instance = MetadataService();
    await postersDir.delete(recursive: true);
  });

  MetadataService service({String apiKey = 'k3y'}) => MetadataService(
        httpClient: _mockTmdb(),
        postersDirProvider: () async => postersDir,
        apiKeyProvider: () async => apiKey,
      );

  group('tmdbSearchName', () {
    test('unchanged typed fields keep the parsed name (imdb id intact)',
        () {
      final parsed = parseMediaName(
          'Night of the Living Dead (1968) {imdb-tt0063350}.mp4');
      final search =
          tmdbSearchName(parsed, 'night of the living dead', '1968');
      expect(identical(search, parsed), isTrue);
      expect(search.imdbId, 'tt0063350');
    });

    test('empty typed title keeps the parsed name', () {
      final parsed = parseMediaName('Waterfall.mp4');
      expect(identical(tmdbSearchName(parsed, '  ', ''), parsed), isTrue);
    });

    test('typed correction beats the file name, drops the imdb tag', () {
      final parsed =
          parseMediaName('Wrong Title (1999) {imdb-tt0000001}.mp4');
      final search = tmdbSearchName(parsed, 'The Movie', '2024');
      expect(search.title, 'The Movie');
      expect(search.year, 2024);
      expect(search.imdbId, isNull);
    });

    test('episode markers survive a typed show rename', () {
      final parsed = parseMediaName('Shw S01E02.mkv');
      final search = tmdbSearchName(parsed, 'Show', '');
      expect(search.title, 'Show');
      expect(search.season, 1);
      expect(search.episode, 2);
    });
  });

  group('lookupTmdb / adoptTmdbMatch', () {
    test('lookupTmdb resolves without touching the cache', () async {
      final s = service();
      final match =
          await s.lookupTmdb(const ParsedName('The Movie', 2024));
      expect(match!.tmdbId, 42);
      expect(match.rating, 6.8);
      final db = await LibraryStore.database();
      expect(await db.select(db.metadataCache).get(), isEmpty);
    });

    test('lookupTmdb returns null on a genuine miss, still uncached',
        () async {
      final s = service();
      final match =
          await s.lookupTmdb(const ParsedName('No Such Film', null));
      expect(match, isNull);
      final db = await LibraryStore.database();
      expect(await db.select(db.metadataCache).get(), isEmpty);
    });

    test('adoptTmdbMatch persists the full row + poster and updates '
        'metadataFor immediately', () async {
      final s = service();
      final match =
          await s.lookupTmdb(const ParsedName('The Movie', 2024));
      final adopted = await s.adoptTmdbMatch('movie:the movie:2024', match!);
      expect(adopted.title, 'The Movie');
      expect(adopted.posterFilePath, isNotNull);
      expect(File(adopted.posterFilePath!).existsSync(), isTrue);
      final db = await LibraryStore.database();
      final row = await db.select(db.metadataCache).getSingle();
      expect(row.lookupKey, 'movie:the movie:2024');
      expect(row.tmdbId, 42);
      expect(row.rating, 6.8);
      expect(row.category, 'Drama');
      expect(row.userEdited, isFalse);
      // The adopted answer is in memory — no async resolve needed.
      const entry =
          MediaEntry(name: 'The Movie (2024).mp4', address: 'ab12');
      expect(s.metadataFor(entry).overview, 'A movie.');
    });
  });

  group('DescribeItemScreen Check TMDB', () {
    Future<void> pump(WidgetTester tester,
        {String name = 'The.Movie.2024.1080p.mkv'}) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: DescribeItemScreen(
          entry: MediaEntry(name: name, address: 'ab12'),
          postersDirProvider: () async => postersDir,
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('keyless press explains where the key goes',
        (tester) async {
      MetadataService.instance = service(apiKey: '');
      await pump(tester);
      await tester.tap(find.text('Check TMDB'));
      await tester.pumpAndSettle();
      expect(find.text('No TMDB key'), findsOneWidget);
      expect(find.textContaining('Settings → Metadata'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
    });

    testWidgets('a miss shows a snackbar, nothing adopted',
        (tester) async {
      MetadataService.instance = service();
      await pump(tester, name: 'No Such Film.mp4');
      await tester.tap(find.text('Check TMDB'));
      await tester.pumpAndSettle();
      expect(find.textContaining('TMDB has no match for “No Such Film”'),
          findsOneWidget);
    });

    testWidgets('match preview → Use these details fills the form and '
        'enables Save', (tester) async {
      MetadataService.instance = service();
      await pump(tester);
      // Artwork + description missing → Save disabled.
      final save = find.widgetWithText(FilledButton, 'Save description');
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      await tester.tap(find.text('Check TMDB'));
      await tester.pumpAndSettle();
      // Preview dialog with the match, extras line, and attribution.
      expect(find.text('TMDB match'), findsOneWidget);
      expect(find.text('The Movie (2024)'), findsOneWidget);
      expect(find.text('6.8/10 · Drama'), findsOneWidget);
      expect(find.textContaining('The Movie Database'), findsWidgets);
      await tester.tap(find.text('Use these details'));
      await tester.pumpAndSettle();
      // Fields prefilled from the match, poster adopted → Save enabled.
      expect(
          tester
              .widget<TextField>(
                  find.widgetWithText(TextField, 'Title (required)'))
              .controller!
              .text,
          'The Movie');
      expect(
          tester
              .widget<TextField>(find.widgetWithText(
                  TextField, 'Description (required)'))
              .controller!
              .text,
          'A movie.');
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      expect(find.textContaining('Still missing'), findsNothing);
    });

    testWidgets('typed correction searches TMDB; Cancel adopts nothing',
        (tester) async {
      MetadataService.instance = service();
      // The file name misses on TMDB — the typed title is what matches.
      await pump(tester, name: 'No Such Film.mp4');
      await tester.enterText(
          find.widgetWithText(TextField, 'Title (required)'), 'The Movie');
      await tester.enterText(
          find.widgetWithText(TextField, 'Year (optional)'), '2024');
      await tester.tap(find.text('Check TMDB'));
      await tester.pumpAndSettle();
      expect(find.text('The Movie (2024)'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<TextField>(find.widgetWithText(
                  TextField, 'Description (required)'))
              .controller!
              .text,
          isEmpty);
      // Nothing adopted — the only cache row is the auto-matcher's miss
      // for the unmatchable file name.
      final db = await LibraryStore.database();
      final rows = await db.select(db.metadataCache).get();
      expect(rows.where((r) => r.found), isEmpty);
    });
  });

  group('DescribeItemScreen category', () {
    // Pushed onto a base route so tapping Save (which pops) is safe.
    Future<void> pump(WidgetTester tester,
        {String name = 'The.Movie.2024.1080p.mkv'}) async {
      tester.view.physicalSize = const Size(900, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => DescribeItemScreen(
                    entry: MediaEntry(name: name, address: 'ab12'),
                    postersDirProvider: () async => postersDir,
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    // Channels carry no category tags (2026-08-29): the Describe page
    // offers no genre chips, and a save leaves whatever category a TMDB
    // match stored locally untouched (the manifest build nulls it out
    // before anything is published).
    testWidgets('the describe page offers no category chips',
        (tester) async {
      MetadataService.instance = service();
      await pump(tester);
      expect(find.text('CATEGORY (optional)'), findsNothing);
      expect(find.byType(FilterChip), findsNothing);
    });

    testWidgets('saving preserves the TMDB match\'s local category',
        (tester) async {
      MetadataService.instance = service();
      await pump(tester);
      await tester.tap(find.text('Check TMDB'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use these details'));
      await tester.pumpAndSettle();

      final save = find.widgetWithText(FilledButton, 'Save description');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();

      // The local row keeps the match's genres (they still feed the
      // user's own library pages) — the save omits category on purpose.
      final db = await LibraryStore.database();
      final rows = await db.select(db.metadataCache).get();
      final row = rows.singleWhere((r) => r.userEdited);
      expect(row.category, 'Drama');
    });
  });
}
