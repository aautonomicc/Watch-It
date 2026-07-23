import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/screens/media_lists_screen.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/theme/tokens.dart';

const _addrA =
    '66cacd06ae5b02aeb0b4b8a463885bd7ec392b1b4291c1eda75253e831c1bcbb';
const _addrB =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

class _FakeFileSelector extends FileSelectorPlatform
    with MockPlatformInterfaceMixin {
  _FakeFileSelector(this.file);
  final XFile? file;

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async =>
      file;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    FileSelectorPlatform.instance = _FakeFileSelector(XFile.fromData(
      utf8.encode('Prefetch Movies\n'
          '$_addrA First Movie (2024).mkv\n'
          '$_addrB Second Movie (1999).mp4\n'),
      name: 'movies.list',
    ));
  });

  Future<void> importWithPrefetchServer(WidgetTester tester) async {
    // Any non-null base makes the prefetcher "available"; widget tests
    // mock all HTTP to status 400, so every resolve deterministically
    // fails — which is exactly the wiring (dialogs, counters, summary)
    // this test is about.
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: const MediaListsScreen(prefetchBase: 'http://127.0.0.1:1'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Import list from file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local file'));
    await tester.pumpAndSettle();
  }

  testWidgets('import offers a prefetch and Skip declines it',
      (tester) async {
    await importWithPrefetchServer(tester);
    expect(find.text('Prefetch data maps?'), findsOneWidget);
    expect(find.textContaining('each of the 2 imported files'),
        findsOneWidget);
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(find.text('Prefetch data maps?'), findsNothing);
    expect(find.textContaining('File 1 of'), findsNothing);
    // The list itself imported regardless.
    final list = (await LibraryStore.load())
        .firstWhere((l) => l.title == 'Prefetch Movies');
    expect(list.entries, hasLength(2));
  });

  testWidgets('Prefetch walks every file and reports a summary',
      (tester) async {
    await importWithPrefetchServer(tester);
    await tester.tap(find.text('Prefetch'));
    await tester.pumpAndSettle();
    // The summary snackbar queues behind the import one — let that expire.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    // Mocked HTTP fails every resolve; the summary still names the count
    // and the resolve-on-first-play fallback.
    expect(
        find.textContaining('2 failed — those resolve on first play'),
        findsOneWidget);
    expect(find.textContaining('File 1 of'), findsNothing); // dialog closed
  });

  testWidgets('no prefetch offer without an embedded server',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: const MediaListsScreen(),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Import list from file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local file'));
    await tester.pumpAndSettle();
    expect(find.text('Prefetch data maps?'), findsNothing);
    expect(find.textContaining('Imported "Prefetch Movies"'),
        findsOneWidget);
  });
}
