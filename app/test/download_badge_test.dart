import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/download_manager.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/download_badge.dart';

String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

MediaEntry _entry(int i) =>
    MediaEntry(name: 'Show.S01E0$i.mkv', address: _addr(i));

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('wi-badge');
    DownloadManager.instance = DownloadManager(directory: dir);
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// Seed one downloads row. Non-done rows use `paused` so loading the
  /// queue never starts a transfer inside the test; done rows get a real
  /// file on disk so the load-time deletion sweep keeps them.
  Future<void> seed(int i, String status,
      {int total = 100, int done = 0}) async {
    final path = '${dir.path}/Show.S01E0$i.mkv';
    if (status == 'done') {
      File(path).writeAsBytesSync(List.filled(done, 0));
    }
    final target = await LibraryStore.database();
    await target.into(target.downloads).insert(DownloadsCompanion.insert(
          address: _addr(i),
          name: 'Show.S01E0$i.mkv',
          filePath: path,
          totalBytes: Value(total),
          downloadedBytes: Value(done),
          status: status,
          createdAt: i,
          updatedAt: i,
        ));
  }

  Widget host(Widget? badge) => MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: Stack(children: [Container(), ?badge]),
      );

  testWidgets('no badge for a never-queued entry', (tester) async {
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    await DownloadManager.instance.ensureLoaded();
    expect(entryDownloadBadge(WiTokens.dark, _entry(1)), isNull);
  });

  testWidgets('check badge for a finished download', (tester) async {
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    await seed(1, 'done', done: 100);
    await DownloadManager.instance.ensureLoaded();

    final badge = entryDownloadBadge(WiTokens.dark, _entry(1));
    expect(badge, isNotNull);
    await tester.pumpWidget(host(badge));
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('progress ring for a download under way', (tester) async {
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    await seed(1, 'paused', done: 40);
    await DownloadManager.instance.ensureLoaded();

    final badge = entryDownloadBadge(WiTokens.dark, _entry(1));
    expect(badge, isNotNull);
    await tester.pumpWidget(host(badge));
    final ring = tester
        .widget<CircularProgressIndicator>(
            find.byType(CircularProgressIndicator));
    expect(ring.value, closeTo(0.4, 0.001));
    expect(find.byIcon(Icons.check), findsNothing);
  });

  testWidgets('group badge: none downloaded → no badge', (tester) async {
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    await seed(1, 'paused', done: 40);
    await DownloadManager.instance.ensureLoaded();

    expect(
        groupDownloadBadge(WiTokens.dark, [_entry(1), _entry(2)]), isNull);
  });

  testWidgets('group badge: some downloaded → count', (tester) async {
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    await seed(1, 'done', done: 100);
    await seed(2, 'paused', done: 40);
    await DownloadManager.instance.ensureLoaded();

    final badge =
        groupDownloadBadge(WiTokens.dark, [_entry(1), _entry(2), _entry(3)]);
    expect(badge, isNotNull);
    await tester.pumpWidget(host(badge));
    expect(find.text('1/3'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsNothing);
  });

  testWidgets('group badge: all downloaded → plain check', (tester) async {
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    await seed(1, 'done', done: 100);
    await seed(2, 'done', done: 100);
    await DownloadManager.instance.ensureLoaded();

    final badge = groupDownloadBadge(WiTokens.dark, [_entry(1), _entry(2)]);
    expect(badge, isNotNull);
    await tester.pumpWidget(host(badge));
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(find.text('2/2'), findsNothing);
  });
}
