import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/screens/media_lists_screen.dart';
import 'package:watchit/services/bundle.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata.dart';
import 'package:watchit/services/watch_state.dart';
import 'package:watchit/theme/tokens.dart';

import 'fake_embedded_http.dart';

const _addrA =
    '66cacd06ae5b02aeb0b4b8a463885bd7ec392b1b4291c1eda75253e831c1bcbb';
const _addrB =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _addrC =
    'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';

/// Serves fixed in-memory files to `openFile()`/`openFiles()`;
/// null/empty = picker cancelled.
class _FakeFileSelector extends FileSelectorPlatform
    with MockPlatformInterfaceMixin {
  _FakeFileSelector(this.files);
  final List<XFile> files;

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async =>
      files.isEmpty ? null : files.first;

  @override
  Future<List<XFile>> openFiles({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async =>
      files;
}

Uint8List _zipOf(Map<String, List<int>> members) {
  final archive = Archive();
  for (final e in members.entries) {
    archive.addFile(ArchiveFile.bytes(e.key, e.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late FakeEmbeddedHttp fake;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    WatchStateStore.instance = WatchStateStore();
    fake = FakeEmbeddedHttp();
    HttpOverrides.global = fake;
  });

  tearDown(() {
    HttpOverrides.global = null;
  });

  Future<void> openMediaLists(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: const MediaListsScreen(importBase: FakeEmbeddedHttp.base),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> importLocal(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Add to library'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Import .watch-list bundle'));
    await tester.pumpAndSettle();
  }

  group('Bundle import (v2)', () {
    testWidgets(
        'members become entries, refs assign lists, extras seeded, '
        'library.json applied to the created list only', (tester) async {
      final bundle = _zipOf({
        'datamaps/Bundled Movie (2024).mkv.datamap': [1],
        'datamaps/Loose Show S01E01.mkv.datamap': [2],
        'list.txt': utf8.encode('ListName="Bundle Pack"\n'
            'Bundled Movie (2024).mkv.datamap\n'),
        'metadata.json': utf8.encode(jsonEncode({
          'version': 1,
          'attribution': kTmdbAttributionNotice,
          'entries': [
            {
              'lookupKey':
                  parseMediaName('Bundled Movie (2024).mkv').lookupKey,
              'title': 'Bundled Movie',
              'year': 2024,
              'mediaType': 'movie',
              'tmdbId': 7,
            },
          ],
        })),
        'library.json': utf8.encode(jsonEncode({
          'version': 1,
          'lists': [
            {'title': 'Bundle Pack', 'enabled': false, 'position': 0},
          ],
        })),
      });
      FileSelectorPlatform.instance = _FakeFileSelector(
          // Extension deliberately wrong: routing must use the zip magic.
          [XFile.fromData(bundle, path: 'pack.txt')]);
      await openMediaLists(tester);
      await importLocal(tester);

      final lists = await LibraryStore.load();
      final pack = lists.firstWhere((l) => l.title == 'Bundle Pack');
      expect(pack.entries.single.name, 'Bundled Movie (2024).mkv');
      expect(pack.entries.single.address, FakeEmbeddedHttp.addrForByte(1));
      expect(pack.enabled, isFalse); // library.json applied
      // The unreferenced member lands in a list named after the file.
      final loose = lists.firstWhere((l) => l.title == 'pack');
      expect(loose.entries.single.address, FakeEmbeddedHttp.addrForByte(2));

      final db = await LibraryStore.database();
      final rows = await db.select(db.metadataCache).get();
      expect(rows.single.title, 'Bundled Movie'); // metadata seeded
    });

    testWidgets('a hand-made zip of loose .datamap files imports into a '
        'list named after the bundle file', (tester) async {
      FileSelectorPlatform.instance = _FakeFileSelector([
        XFile.fromData(
            _zipOf({
              'A Movie (2020).mkv.datamap': [3],
              'B Movie (2021).mkv.datamap': [4],
            }),
            path: 'My Films.watch-list'),
      ]);
      await openMediaLists(tester);
      await importLocal(tester);

      expect(find.textContaining('Imported "My Films"'), findsOneWidget);
      final list = (await LibraryStore.load())
          .firstWhere((l) => l.title == 'My Films');
      expect(list.entries.map((e) => e.address), [
        FakeEmbeddedHttp.addrForByte(3),
        FakeEmbeddedHttp.addrForByte(4),
      ]);
    });

    testWidgets('a v1 bundle converts hex entries at the border: rootmaps '
        'member offline, network resolve, or dropped', (tester) async {
      fake.resolvable.add(_addrB);
      FileSelectorPlatform.instance = _FakeFileSelector([
        XFile.fromData(
            _zipOf({
              'list.txt': utf8.encode('ListName="Legacy Pack"\n'
                  '$_addrA Offline Movie (1968).mp4\n'
                  '$_addrB Network Movie (2024).mkv\n'
                  '$_addrC Doomed Movie (1999).mkv\n'),
              'rootmaps/$_addrA.map': [7, 7],
            }),
            path: 'legacy.watch-list'),
      ]);
      await openMediaLists(tester);
      await importLocal(tester);

      expect(find.textContaining('Imported "Legacy Pack"'), findsOneWidget);
      expect(find.textContaining('1 legacy entry skipped'), findsOneWidget);
      final list = (await LibraryStore.load())
          .firstWhere((l) => l.title == 'Legacy Pack');
      expect(list.entries.map((e) => e.address), [_addrA, _addrB]);
      expect(fake.rootmapPuts[_addrA], [7, 7]);
    });

    testWidgets('a plain text list file is refused with a bundle pointer',
        (tester) async {
      FileSelectorPlatform.instance = _FakeFileSelector([
        XFile.fromData(
            utf8.encode('Imported Movies\n$_addrA First Movie.mkv\n'),
            path: 'movies.list'),
      ]);
      await openMediaLists(tester);
      final before = (await LibraryStore.load()).length;
      await importLocal(tester);
      expect(find.textContaining('Plain-text lists are no longer '
          'supported'), findsOneWidget);
      expect((await LibraryStore.load()).length, before);
    });

    testWidgets('cancelling the picker changes nothing', (tester) async {
      FileSelectorPlatform.instance = _FakeFileSelector(const []);
      await openMediaLists(tester);
      final before = (await LibraryStore.load()).length;
      await importLocal(tester);
      expect((await LibraryStore.load()).length, before);
    });
  });

  group('Bundle import (watch history dialog)', () {
    Uint8List bundleWithHistory() => _zipOf({
          'datamaps/Watched Movie (2024).mkv.datamap': [
            0x66 // derived address = _addrA's first byte spread = matches
          ],
          'history.json': utf8.encode(jsonEncode({
            'version': 1,
            'entries': [
              {
                'address': FakeEmbeddedHttp.addrForByte(0x66),
                'positionMs': 90000,
                'durationMs': 120000,
                'completed': false,
                'updatedAt': 5000,
              },
            ],
          })),
        });

    MediaEntry historyEntry() => MediaEntry(
        name: 'w', address: FakeEmbeddedHttp.addrForByte(0x66));

    testWidgets('asks first; leaving the box checked merges it',
        (tester) async {
      FileSelectorPlatform.instance = _FakeFileSelector([
        XFile.fromData(bundleWithHistory(), path: 'pack.watch-list'),
      ]);
      await openMediaLists(tester);
      await importLocal(tester);

      expect(find.text('This bundle also contains'), findsOneWidget);
      expect(find.textContaining('Watch history (1 entry)'), findsOneWidget);
      await tester.tap(find.text('Import'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Imported "pack"'), findsOneWidget);
      final state =
          await WatchStateStore.instance.stateFor(historyEntry());
      expect(state!.positionMs, 90000);
    });

    testWidgets('unchecking watch history imports the list but not the '
        'history', (tester) async {
      FileSelectorPlatform.instance = _FakeFileSelector([
        XFile.fromData(bundleWithHistory(), path: 'pack.watch-list'),
      ]);
      await openMediaLists(tester);
      await importLocal(tester);

      await tester.tap(find.textContaining('Watch history (1 entry)'));
      await tester.pump();
      await tester.tap(find.text('Import'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Imported "pack"'), findsOneWidget);
      expect(await WatchStateStore.instance.stateFor(historyEntry()),
          isNull);
    });

    testWidgets('cancelling the dialog aborts the whole import',
        (tester) async {
      FileSelectorPlatform.instance = _FakeFileSelector([
        XFile.fromData(bundleWithHistory(), path: 'pack.watch-list'),
      ]);
      await openMediaLists(tester);
      final before = (await LibraryStore.load()).length;
      await importLocal(tester);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect((await LibraryStore.load()).length, before);
      expect(await WatchStateStore.instance.stateFor(historyEntry()),
          isNull);
    });
  });

  group('Add .datamap files', () {
    testWidgets('picked files become entries in the named list',
        (tester) async {
      FileSelectorPlatform.instance = _FakeFileSelector([
        XFile.fromData(Uint8List.fromList([5]),
            path: 'First Movie (2024).mkv.datamap'),
        XFile.fromData(Uint8List.fromList([6]),
            path: 'Second Movie (1999).mp4.datamap'),
      ]);
      await openMediaLists(tester);
      await tester.tap(find.byTooltip('Add to library'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Add .datamap files'));
      await tester.pumpAndSettle();

      // List-name prompt, prefilled "Imported".
      expect(find.text('Add to which list?'), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Imported "Imported"'), findsOneWidget);
      final list = (await LibraryStore.load())
          .firstWhere((l) => l.title == 'Imported');
      expect(list.entries.map((e) => e.name),
          ['First Movie (2024).mkv', 'Second Movie (1999).mp4']);
      expect(list.entries.map((e) => e.address), [
        FakeEmbeddedHttp.addrForByte(5),
        FakeEmbeddedHttp.addrForByte(6),
      ]);
    });

    testWidgets('unreadable files are skipped and reported',
        (tester) async {
      FileSelectorPlatform.instance = _FakeFileSelector([
        XFile.fromData(Uint8List.fromList([5]),
            path: 'Good Movie (2024).mkv.datamap'),
        XFile.fromData(Uint8List.fromList([0xBA, 0xD1]),
            path: 'Bad.mkv.datamap'),
      ]);
      await openMediaLists(tester);
      await tester.tap(find.byTooltip('Add to library'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Add .datamap files'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('1 file skipped (not a data map)'),
          findsOneWidget);
      final list = (await LibraryStore.load())
          .firstWhere((l) => l.title == 'Imported');
      expect(list.entries.single.name, 'Good Movie (2024).mkv');
    });
  });

  group('Import when the list name already exists', () {
    Future<void> importTwice(WidgetTester tester,
        {required String secondAction}) async {
      FileSelectorPlatform.instance = _FakeFileSelector([
        XFile.fromData(
            _zipOf({
              'datamaps/First Movie.mkv.datamap': [1],
              'datamaps/Second Movie.mkv.datamap': [2],
              'list.txt': utf8.encode('ListName="Clash Movies"\n'
                  'First Movie.mkv.datamap\n'
                  'Second Movie.mkv.datamap\n'),
            }),
            path: 'first.watch-list'),
      ]);
      await openMediaLists(tester);
      await importLocal(tester);
      // Same list name again: one duplicate entry, one new one.
      FileSelectorPlatform.instance = _FakeFileSelector([
        XFile.fromData(
            _zipOf({
              'datamaps/Second Movie.mkv.datamap': [2],
              'datamaps/Third Movie.mkv.datamap': [3],
              'list.txt': utf8.encode('ListName="Clash Movies"\n'
                  'Second Movie.mkv.datamap\n'
                  'Third Movie.mkv.datamap\n'),
            }),
            path: 'second.watch-list'),
      ]);
      await importLocal(tester);
      expect(find.textContaining('"Clash Movies" already exists'),
          findsOneWidget);
      await tester.tap(find.text(secondAction));
      await tester.pumpAndSettle();
    }

    testWidgets('Merge appends only the new entries', (tester) async {
      await importTwice(tester, secondAction: 'Merge');
      final list = (await LibraryStore.load())
          .firstWhere((l) => l.title == 'Clash Movies');
      expect(list.entries, hasLength(3));
      expect(list.entries.map((e) => e.address), [
        FakeEmbeddedHttp.addrForByte(1),
        FakeEmbeddedHttp.addrForByte(2),
        FakeEmbeddedHttp.addrForByte(3),
      ]);
    });

    testWidgets('Create new makes a numbered copy', (tester) async {
      await importTwice(tester, secondAction: 'Create new');
      final lists = await LibraryStore.load();
      expect(lists.firstWhere((l) => l.title == 'Clash Movies').entries,
          hasLength(2));
      final copy =
          lists.firstWhere((l) => l.title == 'Clash Movies (2)');
      expect(copy.entries.map((e) => e.address), [
        FakeEmbeddedHttp.addrForByte(2),
        FakeEmbeddedHttp.addrForByte(3),
      ]);
    });

    testWidgets('Skip leaves the existing list untouched', (tester) async {
      await importTwice(tester, secondAction: 'Skip');
      final lists = await LibraryStore.load();
      expect(lists.where((l) => l.title.startsWith('Clash Movies')),
          hasLength(1));
      expect(lists.firstWhere((l) => l.title == 'Clash Movies').entries,
          hasLength(2));
    });
  });
}
