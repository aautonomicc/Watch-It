import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/main.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/screens/season_screen.dart';
import 'package:watchit/services/connectivity.dart';
import 'package:watchit/services/download_manager.dart';
import 'package:watchit/services/embedded_client.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/services/season_grouping.dart';
import 'package:watchit/services/watch_state.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/watch_progress.dart';

String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

MediaEntry get _movie =>
    MediaEntry(name: 'Movie.2020.mkv', address: _addr(1));
MediaEntry get _movie2 =>
    MediaEntry(name: 'Other.2021.mkv', address: _addr(2));
MediaEntry _ep(int i) =>
    MediaEntry(name: 'Show.S01E0$i.mkv', address: _addr(10 + i));

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory dir;

  setUp(() async {
    // Skip default seeding so the wall only holds what each test stores.
    SharedPreferences.setMockInitialValues({'defaults_seeded_v3': true});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    MetadataService.instance = MetadataService(apiKeyProvider: () async => '');
    WatchStateStore.instance = WatchStateStore();
    // Sync I/O only in setUp — async dart:io never completes in the
    // fake-async test zone.
    dir = Directory.systemTemp.createTempSync('wi-watch-bar');
    DownloadManager.instance = DownloadManager(directory: dir);
    ConnectivityMonitor.instance = ConnectivityMonitor(
        probe: () async => ClientHealth(state: 'ready', peers: 5));
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> resume(MediaEntry entry) => WatchStateStore.instance.record(
      entry,
      position: const Duration(minutes: 10),
      duration: const Duration(minutes: 100));

  /// Every visible watch bar must render at the doubled height.
  void expectBarHeights(WidgetTester tester) {
    for (final size
        in find.byType(LinearProgressIndicator).evaluate().map((e) =>
            tester.getSize(find.byWidget(e.widget)))) {
      expect(size.height, watchBarHeight);
    }
  }

  testWidgets('home wall: bars on the continue card and poster cards, '
      'none on unplayed files', (tester) async {
    await LibraryStore.save([
      MediaList(id: 'l1', title: 'Library', entries: [_movie, _movie2]),
    ]);
    await resume(_movie);
    // Tall enough that all three rows (Continue Watching, Recently
    // Added, Library) build — off-viewport rows never mount their cards.
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();

    expect(find.text('Continue Watching'), findsOneWidget);
    // One bar on the continue card + one per poster card of the watched
    // movie (Recently Added row and the Library row); the unplayed movie
    // contributes none.
    expect(find.byType(LinearProgressIndicator), findsNWidgets(3));
    expectBarHeights(tester);
  });

  testWidgets('completed file shows no bar anywhere', (tester) async {
    await LibraryStore.save([
      MediaList(id: 'l1', title: 'Library', entries: [_movie]),
    ]);
    await WatchStateStore.instance
        .markCompleted(_movie, duration: const Duration(minutes: 100));
    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();

    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('season page: bar only under the watched episode\'s artwork',
      (tester) async {
    await resume(_ep(1));
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: SeasonScreen(
          group: showSeasons([_ep(1), _ep(2), _ep(3)], 'Show').single),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expectBarHeights(tester);
  });
}
