import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/main.dart';
import 'package:watchit/screens/downloads_screen.dart';
import 'package:watchit/services/download_manager.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/services/watch_state.dart';
import 'package:watchit/widgets/downloads_indicator.dart';
import 'package:watchit/services/terms.dart';

String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

DownloadTask _task(int i, DownloadStatus status,
        {int total = 100, int done = 0}) =>
    DownloadTask(
      address: _addr(i),
      name: 'File$i.mkv',
      filePath: '/nonexistent/File$i.mkv',
      totalBytes: total,
      downloadedBytes: done,
      status: status,
      createdAt: i,
    );

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'defaults_seeded_v4': true,
      'terms_accepted_version_v1': kTermsVersion});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    DownloadManager.instance = DownloadManager();
    MetadataService.instance = MetadataService(apiKeyProvider: () async => '');
    WatchStateStore.instance = WatchStateStore();
  });

  Finder ring() => find.descendant(
      of: find.byType(DownloadsIndicator),
      matching: find.byType(CircularProgressIndicator));

  testWidgets('hidden while the queue is idle — even with old finished '
      'downloads', (tester) async {
    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();
    expect(ring(), findsNothing);

    // A download finished in some earlier session was never part of a
    // running batch — the meter stays away.
    DownloadManager.instance
        .debugStageTask(_task(1, DownloadStatus.done, done: 100));
    await tester.pumpAndSettle();
    expect(ring(), findsNothing);
  });

  testWidgets('ring and x-of-y count track the batch, then vanish on '
      'drain', (tester) async {
    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();

    final manager = DownloadManager.instance;
    manager.debugStageTask(_task(1, DownloadStatus.queued));
    manager.debugStageTask(_task(2, DownloadStatus.queued));
    manager.debugStageTask(_task(1, DownloadStatus.downloading, done: 50));
    await tester.pumpAndSettle();
    expect(find.text('0 of 2'), findsOneWidget);
    expect(tester.widget<CircularProgressIndicator>(ring()).value,
        closeTo(0.25, 0.001)); // (0.5 + 0) / 2

    manager.debugStageTask(_task(1, DownloadStatus.done, done: 100));
    await tester.pumpAndSettle();
    expect(find.text('1 of 2'), findsOneWidget);
    expect(tester.widget<CircularProgressIndicator>(ring()).value,
        closeTo(0.5, 0.001));

    manager.debugStageTask(_task(2, DownloadStatus.done, done: 100));
    await tester.pumpAndSettle();
    expect(ring(), findsNothing);
    expect(find.text('2 of 2'), findsNothing);
  });

  testWidgets('a paused-only queue hides the meter', (tester) async {
    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();
    final manager = DownloadManager.instance;
    manager.debugStageTask(_task(1, DownloadStatus.queued));
    await tester.pumpAndSettle();
    expect(ring(), findsOneWidget);

    manager.debugStageTask(_task(1, DownloadStatus.paused, done: 30));
    await tester.pumpAndSettle();
    expect(ring(), findsNothing);
  });

  testWidgets('tap opens Settings → Downloads', (tester) async {
    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();
    DownloadManager.instance
        .debugStageTask(_task(1, DownloadStatus.downloading, done: 40));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DownloadsIndicator));
    await tester.pumpAndSettle();
    expect(find.byType(DownloadsScreen), findsOneWidget);
  });
}
