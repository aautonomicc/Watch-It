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
import 'package:watchit/screens/album_screen.dart';
import 'package:watchit/services/connectivity.dart';
import 'package:watchit/services/download_manager.dart';
import 'package:watchit/services/embedded_client.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/services/season_grouping.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/poster_cards.dart';

const _mbid = 'c07f0676-9d95-4443-a841-b1cbcfa48f4e';
const _coverBytes = [0xFF, 0xD8, 0xFF, 0xE0];

String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

MediaEntry _track(int n, String title, {int? disc}) => MediaEntry(
      name: 'The Rolling Stones - Let It Bleed (1969) - '
          '${disc != null ? '$disc-' : ''}${n.toString().padLeft(2, '0')} '
          '$title {mbid-$_mbid}.flac',
      address: _addr(100 * (disc ?? 1) + n),
    );

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory postersDir;
  late List<http.Request> requests;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    requests = [];
    // Sync I/O only in setUp — async dart:io never completes in the
    // fake-async test zone.
    postersDir = Directory.systemTemp.createTempSync('wi-album');
  });

  tearDown(() {
    try {
      postersDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// Keyless service (no TMDB key on purpose — CAA needs none) over a
  /// canned Cover Art Archive answering [status] for the album's mbid.
  MetadataService caaService({int status = 200}) => MetadataService(
        httpClient: MockClient((req) async {
          requests.add(req);
          expect(req.url.host, 'coverartarchive.org');
          if (status != 200) return http.Response('', status);
          return http.Response.bytes(_coverBytes, 200);
        }),
        postersDirProvider: () async => postersDir,
        apiKeyProvider: () async => '',
      );

  group('groupSeasons album folding', () {
    test('tracks fold into one HomeAlbum sorted by disc then track', () {
      final movie = MediaEntry(name: 'A Movie (2020).mp4', address: _addr(9));
      final items = groupSeasons([
        _track(2, 'Love In Vain'),
        movie,
        _track(9, 'You Got the Silver', disc: 2),
        _track(1, 'Gimme Shelter'),
      ]);
      expect(items, hasLength(2));
      final album = items.first as HomeAlbum;
      expect(album.artist, 'The Rolling Stones');
      expect(album.album, 'Let It Bleed');
      // disc 1 tracks (added 2 then 1 → sorted 1, 2) before disc 2's 9.
      expect(
          [for (final e in album.tracks) parseMediaName(e.name).trackMarker],
          ['01', '02', '2-09']);
      expect((items[1] as HomeEntry).entry, movie);
    });

    test('different releases stay separate albums', () {
      final other = MediaEntry(
          name: 'Other Artist - Other Album (1980) - 01 Something.mp3',
          address: _addr(50));
      final items = groupSeasons([_track(1, 'Gimme Shelter'), other]);
      expect(items, hasLength(2));
      expect((items[0] as HomeAlbum).album, 'Let It Bleed');
      expect((items[1] as HomeAlbum).album, 'Other Album');
    });

    test('groupShows passes albums through untouched', () {
      final items = groupShows([_track(1, 'Gimme Shelter')]);
      expect(items.single, isA<HomeAlbum>());
    });

    test('plain audio without a track marker stays a single entry', () {
      final items =
          groupShows([MediaEntry(name: 'BegBlag.mp3', address: _addr(3))]);
      expect(items.single, isA<HomeEntry>());
    });
  });

  group('music fallback metadata', () {
    test('tracks: album title, music type, NN · Title label', () {
      final meta = fallbackMetadataFor(_track(5, 'Gimme Shelter'));
      expect(meta.title, 'Let It Bleed');
      expect(meta.year, 1969);
      expect(meta.mediaType, 'music');
      expect(meta.episodeLabel, '05 · Gimme Shelter');
    });

    test('plain audio is music too', () {
      final meta = fallbackMetadataFor(
          MediaEntry(name: 'BegBlag.mp3', address: _addr(3)));
      expect(meta.mediaType, 'music');
      expect(meta.episodeLabel, isNull);
    });
  });

  group('Cover Art Archive fetch', () {
    test('keyless fetch saves music_<mbid>.jpg and caches the row',
        () async {
      final svc = caaService();
      final meta1 = svc.metadataFor(_track(1, 'Gimme Shelter'));
      expect(meta1.title, 'Let It Bleed'); // fallback while resolving
      await svc.whenIdle();
      final meta = svc.metadataFor(_track(1, 'Gimme Shelter'));
      expect(meta.posterFilePath, '${postersDir.path}/music_$_mbid.jpg');
      expect(File(meta.posterFilePath!).readAsBytesSync(), _coverBytes);
      expect(meta.mediaType, 'music');
      expect(meta.episodeLabel, '01 · Gimme Shelter');
      expect(requests, hasLength(1));
      expect(requests.single.url.path, '/release/$_mbid/front-500');

      // A fresh service reads the cached row — no second CAA request,
      // and the shared row re-attaches each track's own label.
      final svc2 = caaService();
      svc2.metadataFor(_track(2, 'Love In Vain'));
      await svc2.whenIdle();
      final cached = svc2.metadataFor(_track(2, 'Love In Vain'));
      expect(cached.posterFilePath, meta.posterFilePath);
      expect(cached.episodeLabel, '02 · Love In Vain');
      expect(requests, hasLength(1));
    });

    test('404 (release has no cover) caches a found row without art',
        () async {
      final svc = caaService(status: 404);
      svc.metadataFor(_track(1, 'Gimme Shelter'));
      await svc.whenIdle();
      expect(svc.metadataFor(_track(1, 'Gimme Shelter')).posterFilePath,
          isNull);
      // Cached: a fresh service asks the network nothing.
      final svc2 = caaService(status: 404);
      svc2.metadataFor(_track(1, 'Gimme Shelter'));
      await svc2.whenIdle();
      expect(requests, hasLength(1));
    });

    test('transport error caches nothing — art retried next session',
        () async {
      final failing = caaService(status: 503);
      failing.metadataFor(_track(1, 'Gimme Shelter'));
      await failing.whenIdle();
      expect(requests, hasLength(1));
      // The next session's service retries and succeeds.
      final svc = caaService();
      svc.metadataFor(_track(1, 'Gimme Shelter'));
      await svc.whenIdle();
      expect(requests, hasLength(2));
      expect(svc.metadataFor(_track(1, 'Gimme Shelter')).posterFilePath,
          isNotNull);
    });

    test('case-B track without mbid fetches nothing', () async {
      final svc = caaService();
      final entry = MediaEntry(
          name: 'Home Artist - Demos (2025) - 01 First Song.mp3',
          address: _addr(7));
      svc.metadataFor(entry);
      await svc.whenIdle();
      final meta = svc.metadataFor(entry);
      expect(meta.title, 'Demos');
      expect(meta.episodeLabel, '01 · First Song');
      expect(meta.mediaType, 'music');
      expect(requests, isEmpty);
    });
  });

  group('album widgets', () {
    setUp(() {
      MetadataService.instance =
          MetadataService(apiKeyProvider: () async => '');
      final dlDir = Directory.systemTemp.createTempSync('wi-album-dl');
      addTearDown(() => dlDir.deleteSync(recursive: true));
      DownloadManager.instance = DownloadManager(directory: dlDir);
      ConnectivityMonitor.instance = ConnectivityMonitor(
          probe: () async => ClientHealth(state: 'ready', peers: 5));
    });

    HomeAlbum album() => groupShows([
          _track(1, 'Gimme Shelter'),
          _track(2, 'Love In Vain'),
          _track(3, 'Country Honk'),
        ]).single as HomeAlbum;

    testWidgets('AlbumCard shows album, artist, and track count',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: Scaffold(
          body: AlbumCard(
              group: album(), tokens: WiTokens.dark, onTap: () {}),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Let It Bleed'), findsOneWidget);
      expect(find.text('The Rolling Stones · 3 tracks'), findsOneWidget);
      // Square cover art frame (1:1, not the 2:3 poster shape).
      final box = tester.getSize(find.byType(ClipRRect));
      expect(box.width, box.height);
    });

    testWidgets('AlbumScreen lists the tracks in order', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: AlbumScreen(group: album()),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Let It Bleed'), findsNWidgets(2)); // app bar + header
      expect(find.text('The Rolling Stones · 1969 · 3 tracks'),
          findsOneWidget);
      expect(find.text('TRACKS'), findsOneWidget);
      expect(find.text('Gimme Shelter'), findsOneWidget);
      expect(find.text('Love In Vain'), findsOneWidget);
      expect(find.text('Country Honk'), findsOneWidget);
      // Track order follows the numbers.
      final y1 = tester.getTopLeft(find.text('Gimme Shelter')).dy;
      final y3 = tester.getTopLeft(find.text('Country Honk')).dy;
      expect(y1, lessThan(y3));
      expect(find.widgetWithText(OutlinedButton, 'Download album'),
          findsOneWidget);
    });
  });
}
