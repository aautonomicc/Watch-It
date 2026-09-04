import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/screens/downloads_screen.dart';
import 'package:watchit/services/download_manager.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/theme/tokens.dart';

String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('wi-dl-select');
    DownloadManager.instance = DownloadManager(directory: dir);
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// Seed one downloads row (non-done rows use `paused` so loading the
  /// queue never starts a transfer inside the test; done rows get a real
  /// file on disk so the load-time deletion sweep keeps them).
  Future<void> seed(int i, String status, {int done = 0}) async {
    if (status == 'done') {
      File('${dir.path}/Movie$i.mkv').writeAsBytesSync(List.filled(done, 0));
    }
    final db = await LibraryStore.database();
    await db.into(db.downloads).insert(DownloadsCompanion.insert(
          address: _addr(i),
          name: 'Movie$i.mkv',
          filePath: '${dir.path}/Movie$i.mkv',
          totalBytes: const Value(100),
          downloadedBytes: Value(done),
          status: status,
          createdAt: i,
          updatedAt: i,
        ));
  }

  /// Deleting touches the file system; runAsync lets that I/O complete,
  /// then a pump renders the result.
  Future<void> drain(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 50 && !done(); i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: const DownloadsScreen(),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('every queue item gets a checkbox; ticking reveals '
      'Delete selected', (tester) async {
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    await seed(1, 'done', done: 100);
    await seed(2, 'paused', done: 40);
    await pumpScreen(tester);

    expect(find.byType(Checkbox), findsNWidgets(2));
    expect(find.textContaining('Delete selected'), findsNothing);
    expect(find.text('Delete all'), findsOneWidget);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(find.text('Delete selected (1)'), findsOneWidget);
  });

  testWidgets('Delete selected removes only the ticked downloads',
      (tester) async {
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    await seed(1, 'done', done: 100);
    await seed(2, 'paused', done: 40);
    await seed(3, 'done', done: 100);
    await pumpScreen(tester);

    await tester.tap(find.byType(Checkbox).at(0));
    await tester.tap(find.byType(Checkbox).at(2));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete selected (2)'));
    await tester.pumpAndSettle();
    expect(find.text('Delete 2 downloads?'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await drain(tester, () => DownloadManager.instance.tasks.length == 1);
    await tester.pumpAndSettle();

    expect(DownloadManager.instance.taskFor(_addr(1)), isNull);
    expect(DownloadManager.instance.taskFor(_addr(3)), isNull);
    expect(DownloadManager.instance.taskFor(_addr(2)), isNotNull);
    expect(find.text('Movie2.mkv'), findsOneWidget);
    expect(find.text('Movie1.mkv'), findsNothing);
  });

  testWidgets('cancelling the dialog deletes nothing', (tester) async {
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    await seed(1, 'done', done: 100);
    await pumpScreen(tester);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete selected (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(DownloadManager.instance.tasks, hasLength(1));
    // The tick survives the backed-out dialog.
    expect(find.text('Delete selected (1)'), findsOneWidget);
  });

  testWidgets('Delete all clears the whole queue', (tester) async {
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    await seed(1, 'done', done: 100);
    await seed(2, 'paused', done: 40);
    await pumpScreen(tester);

    await tester.tap(find.text('Delete all'));
    await tester.pumpAndSettle();
    expect(find.text('Delete all downloads?'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await drain(tester, () => DownloadManager.instance.tasks.isEmpty);
    await tester.pumpAndSettle();

    expect(DownloadManager.instance.tasks, isEmpty);
    expect(find.textContaining('Nothing downloaded yet'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
  });
}
