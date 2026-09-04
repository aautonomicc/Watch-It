import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/screens/show_screen.dart';
import 'package:watchit/services/connectivity.dart';
import 'package:watchit/services/download_manager.dart';
import 'package:watchit/services/embedded_client.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/services/season_grouping.dart';
import 'package:watchit/theme/tokens.dart';

String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

/// Three episodes across two seasons — the show button must count and
/// queue across all of them, not just one season.
final _episodes = [
  MediaEntry(name: 'Show.S01E01.mkv', address: _addr(1)),
  MediaEntry(name: 'Show.S01E02.mkv', address: _addr(2)),
  MediaEntry(name: 'Show.S02E01.mkv', address: _addr(3)),
];

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    MetadataService.instance = MetadataService(apiKeyProvider: () async => '');
    // Sync I/O only in setUp — async dart:io never completes in the
    // fake-async test zone.
    dir = Directory.systemTemp.createTempSync('wi-show-dl');
    DownloadManager.instance = DownloadManager(directory: dir);
    ConnectivityMonitor.instance = ConnectivityMonitor(
        probe: () async => ClientHealth(state: 'ready', peers: 5));
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> setOffline() async {
    ConnectivityMonitor.instance = ConnectivityMonitor(
        probe: () async => ClientHealth(state: 'ready', peers: 0));
    await ConnectivityMonitor.instance.refresh();
  }

  /// Seed one downloads row (non-done rows use `paused` so loading the
  /// queue never starts a transfer inside the test; done rows get a real
  /// file on disk so the load-time deletion sweep keeps them).
  Future<void> seed(int i, String status, {int done = 0}) async {
    if (status == 'done') {
      File('${dir.path}/${_episodes[i - 1].name}')
          .writeAsBytesSync(List.filled(done, 0));
    }
    final db = await LibraryStore.database();
    await db.into(db.downloads).insert(DownloadsCompanion.insert(
          address: _addr(i),
          name: _episodes[i - 1].name,
          filePath: '${dir.path}/${_episodes[i - 1].name}',
          totalBytes: const Value(100),
          downloadedBytes: Value(done),
          status: status,
          createdAt: i,
          updatedAt: i,
        ));
  }

  Widget page() => MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: ShowScreen(seasons: showSeasons(_episodes, 'Show')),
      );

  OutlinedButton button(WidgetTester tester, String label) => tester
      .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, label));

  testWidgets('nothing downloaded → enabled "Download show" button',
      (tester) async {
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(button(tester, 'Download show').onPressed, isNotNull);
  });

  testWidgets('some episodes downloaded → "Download remaining (N)"',
      (tester) async {
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    await seed(1, 'done', done: 100);
    await DownloadManager.instance.ensureLoaded();
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(button(tester, 'Download remaining (2)').onPressed, isNotNull);
  });

  testWidgets('all episodes downloaded → disabled "Show downloaded"',
      (tester) async {
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    for (var i = 1; i <= 3; i++) {
      await seed(i, 'done', done: 100);
    }
    await DownloadManager.instance.ensureLoaded();
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(button(tester, 'Show downloaded').onPressed, isNull);
  });

  testWidgets('offline disables starting the show download',
      (tester) async {
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    await setOffline();
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(button(tester, 'Download show').onPressed, isNull);
  });

  testWidgets('tapping the button queues every episode of every season',
      (tester) async {
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download show'));
    // Enqueueing touches the file system; runAsync lets that I/O
    // complete, then a pump renders the result.
    var queued = false;
    for (var i = 0; i < 50 && !queued; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      queued = DownloadManager.instance.tasks.length == 3;
    }
    expect(DownloadManager.instance.tasks, hasLength(3));
    for (var i = 1; i <= 3; i++) {
      expect(DownloadManager.instance.taskFor(_addr(i)), isNotNull);
    }
    expect(find.text('3 episodes added to downloads'), findsOneWidget);
    // Let the snackbar and any trailing persistence work drain.
    await tester.pumpAndSettle();
  });
}
