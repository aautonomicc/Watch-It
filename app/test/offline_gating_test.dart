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
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/services/watch_state.dart';
import 'package:watchit/theme/tokens.dart';

String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

MediaEntry get _movie =>
    MediaEntry(name: 'Movie.2020.mkv', address: _addr(1));

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'defaults_seeded_v3': true});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    MetadataService.instance = MetadataService(apiKeyProvider: () async => '');
    WatchStateStore.instance = WatchStateStore();
    DownloadManager.instance = DownloadManager();
  });

  Future<void> setConnectivity({required bool online}) async {
    ConnectivityMonitor.instance = ConnectivityMonitor(
        probe: () async =>
            ClientHealth(state: 'ready', peers: online ? 5 : 0));
    await ConnectivityMonitor.instance.refresh();
  }

  Future<void> seedLibrary() => LibraryStore.save([
        MediaList(id: 'l1', title: 'Library', entries: [_movie]),
      ]);

  Future<void> seedDone() async {
    final db = await LibraryStore.database();
    await db.into(db.downloads).insert(DownloadsCompanion.insert(
          address: _addr(1),
          name: 'Movie.2020.mkv',
          filePath: '/nonexistent/Movie.2020.mkv',
          totalBytes: const Value(100),
          downloadedBytes: const Value(100),
          status: 'done',
          createdAt: 1,
          updatedAt: 1,
        ));
  }

  Widget page(Widget home) => MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: home,
      );

  ButtonStyleButton playButton(WidgetTester tester) =>
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Play'));

  OutlinedButton downloadButton(WidgetTester tester, String label) => tester
      .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, label));

  testWidgets('online: Play and Download enabled, no offline hint',
      (tester) async {
    await seedLibrary();
    await setConnectivity(online: true);
    await tester.pumpWidget(page(DetailScreen(entry: _movie)));
    await tester.pumpAndSettle();

    expect(playButton(tester).onPressed, isNotNull);
    expect(downloadButton(tester, 'Download').onPressed, isNotNull);
    expect(find.textContaining('Offline'), findsNothing);
  });

  testWidgets('offline + not downloaded: Play and Download disabled, hint',
      (tester) async {
    await seedLibrary();
    await setConnectivity(online: false);
    await tester.pumpWidget(page(DetailScreen(entry: _movie)));
    await tester.pumpAndSettle();

    expect(playButton(tester).onPressed, isNull);
    expect(downloadButton(tester, 'Download').onPressed, isNull);
    expect(find.textContaining('Offline'), findsOneWidget);
  });

  testWidgets('offline + downloaded: Play stays enabled, no hint',
      (tester) async {
    await seedLibrary();
    await seedDone();
    await DownloadManager.instance.ensureLoaded();
    await setConnectivity(online: false);
    await tester.pumpWidget(page(DetailScreen(entry: _movie)));
    await tester.pumpAndSettle();

    expect(playButton(tester).onPressed, isNotNull);
    // The finished download's button ("Downloaded") keeps its local
    // action (remove) available offline.
    expect(downloadButton(tester, 'Downloaded').onPressed, isNotNull);
    expect(find.textContaining('Offline'), findsNothing);
  });

  testWidgets('connectivity coming back re-enables Play without a rebuild',
      (tester) async {
    await seedLibrary();
    var online = false;
    ConnectivityMonitor.instance = ConnectivityMonitor(
        probe: () async =>
            ClientHealth(state: 'ready', peers: online ? 5 : 0));
    await ConnectivityMonitor.instance.refresh();
    await tester.pumpWidget(page(DetailScreen(entry: _movie)));
    await tester.pumpAndSettle();
    expect(playButton(tester).onPressed, isNull);

    online = true;
    await ConnectivityMonitor.instance.refresh();
    await tester.pumpAndSettle();
    expect(playButton(tester).onPressed, isNotNull);
    expect(find.textContaining('Offline'), findsNothing);
  });
}
