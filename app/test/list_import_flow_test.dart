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

  // "Add to library" opens the picker directly — no source dialog; the
  // app routes each picked file by content and name.
  Future<void> importLocal(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Add to library'));
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

    testWidgets('a v1 bundle (hex entries only) is refused with the '
        're-export pointer', (tester) async {
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
      final before = (await LibraryStore.load()).length;
      await importLocal(tester);

      expect(find.textContaining('Re-export'), findsOneWidget);
      expect((await LibraryStore.load()).length, before);
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
    List<XFile> twoDatamaps() => [
          XFile.fromData(Uint8List.fromList([5]),
              path: 'First Movie (2024).mkv.datamap'),
          XFile.fromData(Uint8List.fromList([6]),
              path: 'Second Movie (1999).mp4.datamap'),
        ];

    Future<void> pickDatamaps(WidgetTester tester) =>
        importLocal(tester);

    // The screen behind the dialog shows the same titles and entry
    // counts — scope finders to the dialog.
    Finder inDialog(String text) => find.descendant(
        of: find.byType(AlertDialog), matching: find.text(text));

    testWidgets('empty library goes straight to the new-list prompt, '
        'prefilled "Imported"', (tester) async {
      FileSelectorPlatform.instance = _FakeFileSelector(twoDatamaps());
      await openMediaLists(tester);
      await pickDatamaps(tester);

      expect(find.text('New media list'), findsOneWidget);
      expect(find.text('Add to which lists?'), findsNothing);
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

    testWidgets('checking an existing list merges silently — no clash '
        'dialog, duplicates skipped', (tester) async {
      await LibraryStore.save([
        MediaList(id: '1', title: 'Movies', entries: [
          MediaEntry(
              name: 'First Movie (2024).mkv',
              address: FakeEmbeddedHttp.addrForByte(5)),
        ]),
      ]);
      FileSelectorPlatform.instance = _FakeFileSelector(twoDatamaps());
      await openMediaLists(tester);
      await pickDatamaps(tester);

      expect(find.text('Add to which lists?'), findsOneWidget);
      expect(inDialog('1 entry'), findsOneWidget);
      await tester.tap(inDialog('Movies'));
      await tester.pump();
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(find.textContaining('already exists'), findsNothing);
      expect(find.textContaining('Merged into 1 existing list'),
          findsOneWidget);
      expect(find.textContaining('1 duplicate entry skipped'),
          findsOneWidget);
      final list = (await LibraryStore.load())
          .firstWhere((l) => l.title == 'Movies');
      expect(list.entries.map((e) => e.address), [
        FakeEmbeddedHttp.addrForByte(5),
        FakeEmbeddedHttp.addrForByte(6),
      ]);
    });

    testWidgets('multi-select puts the entries in both lists',
        (tester) async {
      await LibraryStore.save([
        MediaList(id: '1', title: 'Movies'),
        MediaList(id: '2', title: 'Kids'),
      ]);
      FileSelectorPlatform.instance = _FakeFileSelector(twoDatamaps());
      await openMediaLists(tester);
      await pickDatamaps(tester);

      await tester.tap(inDialog('Movies'));
      await tester.pump();
      await tester.tap(inDialog('Kids'));
      await tester.pump();
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      final lists = await LibraryStore.load();
      for (final title in ['Movies', 'Kids']) {
        expect(
            lists
                .firstWhere((l) => l.title == title)
                .entries
                .map((e) => e.address),
            [
              FakeEmbeddedHttp.addrForByte(5),
              FakeEmbeddedHttp.addrForByte(6),
            ]);
      }
    });

    testWidgets('"Create new list" adds a checked list saved only on '
        'confirm', (tester) async {
      await LibraryStore.save([MediaList(id: '1', title: 'Movies')]);
      FileSelectorPlatform.instance = _FakeFileSelector(twoDatamaps());
      await openMediaLists(tester);
      await pickDatamaps(tester);

      await tester.tap(find.text('Create new list'));
      await tester.pumpAndSettle();
      expect(find.text('New media list'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Fresh');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('Fresh'), findsOneWidget); // checked pseudo-row
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Imported "Fresh"'), findsOneWidget);
      final lists = await LibraryStore.load();
      expect(lists.firstWhere((l) => l.title == 'Fresh').entries,
          hasLength(2));
      expect(lists.firstWhere((l) => l.title == 'Movies').entries,
          isEmpty);
    });

    testWidgets('cancelling the list picker imports nothing',
        (tester) async {
      await LibraryStore.save([MediaList(id: '1', title: 'Movies')]);
      FileSelectorPlatform.instance = _FakeFileSelector(twoDatamaps());
      await openMediaLists(tester);
      await pickDatamaps(tester);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      final lists = await LibraryStore.load();
      expect(lists, hasLength(1));
      expect(lists.single.entries, isEmpty);
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
      await pickDatamaps(tester);
      // Empty library → new-list prompt, prefilled "Imported".
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('1 file skipped (not a data map)'),
          findsOneWidget);
      final list = (await LibraryStore.load())
          .firstWhere((l) => l.title == 'Imported');
      expect(list.entries.single.name, 'Good Movie (2024).mkv');
    });
  });

  group('Combined import routing', () {
    testWidgets('a mixed pick imports the bundle and batches the loose '
        'datamaps', (tester) async {
      await LibraryStore.save([MediaList(id: '1', title: 'Movies')]);
      FileSelectorPlatform.instance = _FakeFileSelector([
        XFile.fromData(
            _zipOf({'Bundled Movie (2024).mkv.datamap': [1]}),
            path: 'My Films.watch-list'),
        XFile.fromData(Uint8List.fromList([5]),
            path: 'Loose Movie (2020).mkv.datamap'),
      ]);
      await openMediaLists(tester);
      await importLocal(tester);

      // The bundle imported first; the loose datamap batch now asks for
      // its target lists.
      expect(find.text('Add to which lists?'), findsOneWidget);
      await tester.tap(find.descendant(
          of: find.byType(AlertDialog), matching: find.text('Movies')));
      await tester.pump();
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      final lists = await LibraryStore.load();
      expect(
          lists
              .firstWhere((l) => l.title == 'My Films')
              .entries
              .single
              .address,
          FakeEmbeddedHttp.addrForByte(1));
      expect(
          lists
              .firstWhere((l) => l.title == 'Movies')
              .entries
              .single
              .address,
          FakeEmbeddedHttp.addrForByte(5));
    });

    testWidgets('unrecognised files in a mixed pick are counted in the '
        'snackbar', (tester) async {
      FileSelectorPlatform.instance = _FakeFileSelector([
        XFile.fromData(Uint8List.fromList([5]),
            path: 'Good Movie (2024).mkv.datamap'),
        XFile.fromData(utf8.encode('$_addrA Old Movie.mkv\n'),
            path: 'movies.list'),
      ]);
      await openMediaLists(tester);
      await importLocal(tester);
      // Empty library → new-list prompt.
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('1 file skipped (not recognised)'),
          findsOneWidget);
      final list = (await LibraryStore.load())
          .firstWhere((l) => l.title == 'Imported');
      expect(list.entries.single.name, 'Good Movie (2024).mkv');
    });

    testWidgets('a pick of only unrecognised files is refused',
        (tester) async {
      FileSelectorPlatform.instance = _FakeFileSelector([
        XFile.fromData(utf8.encode('not a datamap'), path: 'a.txt'),
        XFile.fromData(utf8.encode('also not one'), path: 'b.txt'),
      ]);
      await openMediaLists(tester);
      final before = (await LibraryStore.load()).length;
      await importLocal(tester);
      expect(find.textContaining('None of the picked files'),
          findsOneWidget);
      expect((await LibraryStore.load()).length, before);
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
