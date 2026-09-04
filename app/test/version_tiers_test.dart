import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/screens/detail_screen.dart';
import 'package:watchit/services/connectivity.dart';
import 'package:watchit/services/download_manager.dart';
import 'package:watchit/services/embedded_client.dart';
import 'package:watchit/services/home_rows.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/services/season_grouping.dart';
import 'package:watchit/services/version_choice.dart';
import 'package:watchit/services/watch_state.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/poster_cards.dart';

// Multi-quality-tier behavior: episode version folding, aggregated
// download tick / watch bar, the detail page's default-version pick
// (best downloaded copy, else the last-streamed tier), and Continue
// Watching folding by version.

String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

const _movieName = 'Night of the Living Dead (1968) {imdb-tt0063350}.mp4';

MediaEntry get _m480 => MediaEntry(
    name: _movieName,
    address: _addr(1),
    sizeBytes: 597585042,
    videoInfo: '480p H.264');
MediaEntry get _m1080 => MediaEntry(
    name: _movieName,
    address: _addr(2),
    sizeBytes: 5682464056,
    videoInfo: '1080p H.264');
MediaEntry get _m720 => MediaEntry(
    name: _movieName,
    address: _addr(3),
    sizeBytes: 1500000000,
    videoInfo: '720p H.264');

MediaEntry _ep(int season, int episode, int i, {String tag = ''}) =>
    MediaEntry(
        name: 'Show S0${season}E0$episode$tag.mkv',
        address: _addr(i),
        videoInfo: tag.contains('1080') ? '1080p H.264' : '480p H.264');

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('videoInfoHeight', () {
    test('parses the ladder tag out of a format label', () {
      expect(videoInfoHeight('1080p H.264'), 1080);
      expect(videoInfoHeight('480p'), 480);
      expect(videoInfoHeight('2160p HEVC'), 2160);
      expect(videoInfoHeight('H.264'), isNull);
      expect(videoInfoHeight(null), isNull);
      expect(videoInfoHeight(''), isNull);
    });
  });

  group('preferredVersion', () {
    final versions = [_m480, _m1080, _m720];

    test('highest-resolution downloaded version beats everything', () {
      final picked = preferredVersion(versions,
          isDownloaded: (e) => e.address != _addr(2), // 480 + 720 on disk
          preferredHeight: 480);
      expect(picked.address, _addr(3)); // 720p — best downloaded
    });

    test('a downloaded copy with unknown resolution still beats none', () {
      final unknown = MediaEntry(name: _movieName, address: _addr(9));
      final picked = preferredVersion([_m480, unknown],
          isDownloaded: (e) => e.address == _addr(9));
      expect(picked.address, _addr(9));
    });

    test('a deliberately opened non-primary version is kept', () {
      final picked = preferredVersion(versions,
          isDownloaded: (_) => false, preferredHeight: 480, opened: _m1080);
      expect(picked.address, _addr(2));
    });

    test('last-streamed tier picks the nearest resolution, ties low', () {
      MediaEntry pick(int h) => preferredVersion(versions,
          isDownloaded: (_) => false, preferredHeight: h, opened: _m480);
      expect(pick(1080).address, _addr(2));
      expect(pick(720).address, _addr(3));
      expect(pick(2160).address, _addr(2));
      // 600 sits between 480 (diff 120) and 720 (diff 240) — 480 wins.
      expect(pick(600).address, _addr(1));
    });

    test('falls back to the primary with no signal at all', () {
      final picked =
          preferredVersion(versions, isDownloaded: (_) => false);
      expect(picked.address, _addr(1));
    });
  });

  group('episode version folding', () {
    test('same-episode uploads fold into one slot carrying all versions',
        () {
      final e1a = _ep(1, 1, 1);
      final e1b = _ep(1, 1, 2, tag: ' [1080p]');
      final e2 = _ep(1, 2, 3);
      final items = groupShows([e1a, e1b, e2]);
      final show = items.single as HomeShow;
      expect(show.episodeCount, 2); // files: 3, episodes: 2
      final season = show.seasons.single;
      expect(season.episodes, hasLength(2));
      expect(season.episodes.first.address, _addr(1)); // first is primary
      expect(season.versionsOf(season.episodes.first).map((e) => e.address),
          [_addr(1), _addr(2)]);
      expect(season.versionsOf(season.episodes.last).map((e) => e.address),
          [_addr(3)]);
    });

    test('versionsInLibrary folds episodes like movies', () {
      final e1a = _ep(1, 1, 1);
      final e1b = _ep(1, 1, 2, tag: ' [1080p]');
      final lists = [
        MediaList(id: 'l1', title: 'TV', entries: [e1a, e1b, _ep(1, 2, 3)]),
      ];
      expect(versionsInLibrary(lists, e1a).map((e) => e.address),
          [_addr(1), _addr(2)]);
      // An entry the library no longer holds is prepended.
      final gone = _ep(2, 5, 9);
      expect(versionsInLibrary(lists, gone).single.address, _addr(9));
    });
  });

  group('continueWatching version folding', () {
    late WatchStateStore store;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await LibraryStore.useForTesting(
          AppDatabase.forTesting(NativeDatabase.memory()));
      store = WatchStateStore.instance = WatchStateStore();
    });

    test('quality tiers of one movie share a single card', () async {
      final lists = [
        MediaList(id: 'l1', title: 'Movies', entries: [_m480, _m1080]),
      ];
      await store.record(_m480,
          position: const Duration(minutes: 10),
          duration: const Duration(minutes: 100));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await store.record(_m1080,
          position: const Duration(minutes: 30),
          duration: const Duration(minutes: 100));
      final row = await continueWatching(lists, store: store);
      expect(row, hasLength(1));
      // The newest state's version fronts the card, carrying both tiers.
      expect(row.single.entry.address, _addr(2));
      expect(row.single.state!.positionMs,
          const Duration(minutes: 30).inMilliseconds);
      expect(row.single.allVersions.map((e) => e.address),
          containsAll([_addr(1), _addr(2)]));
    });

    test('an episode finished on any tier surfaces the next episode',
        () async {
      final e1a = _ep(1, 1, 1);
      final e1b = _ep(1, 1, 2, tag: ' [1080p]');
      final e2 = _ep(1, 2, 3);
      final lists = [
        MediaList(id: 'l1', title: 'TV', entries: [e1a, e1b, e2]),
      ];
      // Finished the 1080p copy — the fold marks the episode watched.
      await store.markCompleted(e1b, duration: const Duration(minutes: 45));
      final row = await continueWatching(lists, store: store);
      expect(row, hasLength(1));
      expect(row.single.entry.address, _addr(3)); // next up: E02
      expect(row.single.isNextUp, isTrue);
    });
  });

  group('widgets', () {
    late Directory dir;

    setUp(() async {
      SharedPreferences.setMockInitialValues({'defaults_seeded_v4': true});
      await LibraryStore.useForTesting(
          AppDatabase.forTesting(NativeDatabase.memory()));
      MetadataService.instance =
          MetadataService(apiKeyProvider: () async => '');
      WatchStateStore.instance = WatchStateStore();
      dir = Directory.systemTemp.createTempSync('wi-tiers');
      DownloadManager.instance = DownloadManager(directory: dir);
      ConnectivityMonitor.instance = ConnectivityMonitor(
          probe: () async => ClientHealth(state: 'ready', peers: 5));
      await ConnectivityMonitor.instance.refresh();
    });

    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    /// Seed a finished download row (with its file on disk, so the
    /// load-time deletion sweep keeps it) for [e].
    Future<void> seedDone(MediaEntry e) async {
      final path = '${dir.path}/${e.name}-${e.address.substring(0, 8)}';
      File(path).writeAsBytesSync(List.filled(10, 0));
      final db = await LibraryStore.database();
      await db.into(db.downloads).insert(DownloadsCompanion.insert(
            address: e.address,
            name: e.name,
            filePath: path,
            totalBytes: const Value(10),
            downloadedBytes: const Value(10),
            status: 'done',
            createdAt: 1,
            updatedAt: 1,
          ));
    }

    Widget page(Widget home) => MaterialApp(
          theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
          home: home,
        );

    testWidgets('poster card ticks when any version is downloaded',
        (tester) async {
      await seedDone(_m1080); // the NON-primary tier is the one on disk
      await DownloadManager.instance.ensureLoaded();
      await tester.pumpWidget(page(Scaffold(
        body: PosterCard(
          entry: _m480,
          versions: [_m480, _m1080],
          tokens: WiTokens.dark,
          onTap: () {},
        ),
      )));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('detail page defaults to the downloaded version',
        (tester) async {
      await LibraryStore.save([
        MediaList(id: 'l1', title: 'Movies', entries: [_m480, _m1080]),
      ]);
      await seedDone(_m1080);
      await tester.pumpWidget(page(DetailScreen(entry: _m480)));
      await tester.pumpAndSettle();
      // The picker starts on the downloaded 1080p copy, marked as such,
      // and the page reports local playback.
      expect(find.text('1080p H.264 · 5.29 GB · Downloaded'), findsWidgets);
      expect(find.textContaining('plays from this device'), findsOneWidget);
    });

    testWidgets('detail page defaults to the last-streamed tier',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'defaults_seeded_v4': true,
        'last_streamed_height_v1': 1080,
      });
      await LibraryStore.save([
        MediaList(id: 'l1', title: 'Movies', entries: [_m480, _m1080]),
      ]);
      await tester.pumpWidget(page(DetailScreen(entry: _m480)));
      await tester.pumpAndSettle();
      expect(find.text('1080p H.264 · 5.29 GB'), findsWidgets);
      expect(find.text('480p H.264 · 570 MB'), findsNothing);
    });

    testWidgets('resume point reaches the page from any tier',
        (tester) async {
      await LibraryStore.save([
        MediaList(id: 'l1', title: 'Movies', entries: [_m480, _m1080]),
      ]);
      // Watched on the 1080p copy; open the page for the 480p primary.
      await WatchStateStore.instance.record(_m1080,
          position: const Duration(minutes: 10),
          duration: const Duration(minutes: 100));
      await tester.pumpWidget(page(DetailScreen(entry: _m480)));
      await tester.pumpAndSettle();
      expect(find.text('Resume · 10:00'), findsOneWidget);
    });

    testWidgets('episode pages get the version picker too',
        (tester) async {
      final e1a = _ep(1, 1, 1);
      final e1b = _ep(1, 1, 2, tag: ' [1080p]');
      await LibraryStore.save([
        MediaList(id: 'l1', title: 'TV', entries: [e1a, e1b]),
      ]);
      await tester.pumpWidget(page(DetailScreen(entry: e1a)));
      await tester.pumpAndSettle();
      expect(find.byType(DropdownButton<String>), findsOneWidget);
    });
  });
}
