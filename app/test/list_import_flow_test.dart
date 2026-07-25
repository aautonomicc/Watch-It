import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/main.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/bundle.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata.dart';
import 'package:watchit/services/watch_state.dart';

const _addrA =
    '66cacd06ae5b02aeb0b4b8a463885bd7ec392b1b4291c1eda75253e831c1bcbb';
const _addrB =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _addrC =
    'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';

/// Serves a fixed in-memory file to `openFile()`; null = picker cancelled.
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
    WatchStateStore.instance = WatchStateStore();
  });

  Future<void> openMediaLists(WidgetTester tester) async {
    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Media Lists'));
    await tester.pumpAndSettle();
  }

  Future<void> importLocal(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Import list from file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local file'));
    await tester.pumpAndSettle();
  }

  group('Import list from local file', () {
    testWidgets('imports a well-formed list file', (tester) async {
      FileSelectorPlatform.instance = _FakeFileSelector(XFile.fromData(
        utf8.encode('Imported Movies\n'
            '$_addrA First Movie (2024).mkv\n'
            'garbage line\n'
            '$_addrB Second Movie (1999).mp4\n'),
        name: 'movies.list',
      ));
      await openMediaLists(tester);
      await importLocal(tester);

      expect(find.textContaining('Imported "Imported Movies"'),
          findsOneWidget);
      expect(find.textContaining('1 invalid line skipped'), findsOneWidget);
      final imported = (await LibraryStore.load())
          .firstWhere((l) => l.title == 'Imported Movies');
      expect(imported.entries, hasLength(2));
      expect(imported.entries[0].name, 'First Movie (2024).mkv');
      expect(imported.entries[0].address, _addrA);
      expect(imported.entries[1].address, _addrB);
    });

    testWidgets('cancelling the picker changes nothing', (tester) async {
      FileSelectorPlatform.instance = _FakeFileSelector(null);
      await openMediaLists(tester);
      final before = (await LibraryStore.load()).length;
      await importLocal(tester);
      expect((await LibraryStore.load()).length, before);
    });

    testWidgets('a file with no valid entries shows an error and adds '
        'no list', (tester) async {
      FileSelectorPlatform.instance = _FakeFileSelector(XFile.fromData(
        utf8.encode('Only A Name\nnot an entry at all\n'),
        name: 'bad.list',
      ));
      await openMediaLists(tester);
      final before = (await LibraryStore.load()).length;
      await importLocal(tester);
      expect(find.textContaining('No "<xor address> <file name>" entries'),
          findsOneWidget);
      expect((await LibraryStore.load()).length, before);
    });

    testWidgets('a multi-list ListName= file imports every list',
        (tester) async {
      FileSelectorPlatform.instance = _FakeFileSelector(XFile.fromData(
        utf8.encode('ListName="TV Series"\n'
            '$_addrA Show S01E01.mkv\n'
            '$_addrB Show S01E02.mkv\n'
            'ListName="Movies Pack"\n'
            '$_addrC A Movie (2024).mkv\n'),
        name: 'combined.list',
      ));
      await openMediaLists(tester);
      await importLocal(tester);

      expect(find.textContaining('Imported 2 lists'), findsOneWidget);
      final lists = await LibraryStore.load();
      expect(lists.firstWhere((l) => l.title == 'TV Series').entries,
          hasLength(2));
      expect(lists.firstWhere((l) => l.title == 'Movies Pack').entries,
          hasLength(1));
    });

    testWidgets('a .watch-list bundle imports through the same button — '
        'sniffed by zip magic, extras seeded, library.json applied to the '
        'created list only', (tester) async {
      final archive = Archive();
      archive.addFile(ArchiveFile.string(
          'list.txt',
          'ListName="Bundle Pack"\n'
          '$_addrA Bundled Movie (2024).mkv\n'));
      archive.addFile(ArchiveFile.string(
          'metadata.json',
          jsonEncode({
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
          })));
      archive.addFile(ArchiveFile.string(
          'library.json',
          jsonEncode({
            'version': 1,
            'lists': [
              {'title': 'Bundle Pack', 'enabled': false, 'position': 0},
            ],
          })));
      FileSelectorPlatform.instance = _FakeFileSelector(XFile.fromData(
        Uint8List.fromList(ZipEncoder().encode(archive)),
        // Extension is deliberately wrong: routing must use the zip magic.
        name: 'bundle.txt',
      ));
      await openMediaLists(tester);
      await importLocal(tester);

      expect(find.textContaining('Imported "Bundle Pack"'), findsOneWidget);
      final imported = (await LibraryStore.load())
          .firstWhere((l) => l.title == 'Bundle Pack');
      expect(imported.entries.single.address, _addrA);
      expect(imported.enabled, isFalse); // library.json applied

      final db = await LibraryStore.database();
      final rows = await db.select(db.metadataCache).get();
      expect(rows.single.title, 'Bundled Movie'); // metadata seeded
    });

    Uint8List bundleWithHistory() {
      final archive = Archive();
      archive.addFile(ArchiveFile.string(
          'list.txt',
          'ListName="History Pack"\n'
          '$_addrA Watched Movie (2024).mkv\n'));
      archive.addFile(ArchiveFile.string(
          'history.json',
          jsonEncode({
            'version': 1,
            'entries': [
              {
                'address': _addrA,
                'positionMs': 90000,
                'durationMs': 120000,
                'completed': false,
                'updatedAt': 5000,
              },
            ],
          })));
      return Uint8List.fromList(ZipEncoder().encode(archive));
    }

    testWidgets('a bundle with watch history asks first; leaving the box '
        'checked merges it', (tester) async {
      FileSelectorPlatform.instance = _FakeFileSelector(
          XFile.fromData(bundleWithHistory(), name: 'pack.watch-list'));
      await openMediaLists(tester);
      await importLocal(tester);

      expect(find.text('This bundle also contains'), findsOneWidget);
      expect(find.textContaining('Watch history (1 entry)'), findsOneWidget);
      // No data maps in this bundle: no row for them.
      expect(find.textContaining('Data maps'), findsNothing);
      await tester.tap(find.text('Import'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Imported "History Pack"'), findsOneWidget);
      final state = await WatchStateStore.instance
          .stateFor(const MediaEntry(name: 'w', address: _addrA));
      expect(state!.positionMs, 90000);
    });

    testWidgets('unchecking watch history imports the list but not the '
        'history', (tester) async {
      FileSelectorPlatform.instance = _FakeFileSelector(
          XFile.fromData(bundleWithHistory(), name: 'pack.watch-list'));
      await openMediaLists(tester);
      await importLocal(tester);

      await tester.tap(find.textContaining('Watch history (1 entry)'));
      await tester.pump();
      await tester.tap(find.text('Import'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Imported "History Pack"'), findsOneWidget);
      expect(
          await WatchStateStore.instance
              .stateFor(const MediaEntry(name: 'w', address: _addrA)),
          isNull);
    });

    testWidgets('cancelling the bundle-extras dialog aborts the whole '
        'import', (tester) async {
      FileSelectorPlatform.instance = _FakeFileSelector(
          XFile.fromData(bundleWithHistory(), name: 'pack.watch-list'));
      await openMediaLists(tester);
      final before = (await LibraryStore.load()).length;
      await importLocal(tester);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect((await LibraryStore.load()).length, before);
      expect(
          await WatchStateStore.instance
              .stateFor(const MediaEntry(name: 'w', address: _addrA)),
          isNull);
    });
  });

  group('Import when the list name already exists', () {
    Future<void> importTwice(WidgetTester tester,
        {required String secondAction}) async {
      FileSelectorPlatform.instance = _FakeFileSelector(XFile.fromData(
        utf8.encode('Clash Movies\n'
            '$_addrA First Movie.mkv\n'
            '$_addrB Second Movie.mkv\n'),
        name: 'first.list',
      ));
      await openMediaLists(tester);
      await importLocal(tester);
      // Same list name again: one duplicate entry, one new one.
      FileSelectorPlatform.instance = _FakeFileSelector(XFile.fromData(
        utf8.encode('Clash Movies\n'
            '$_addrB Second Movie.mkv\n'
            '$_addrC Third Movie.mkv\n'),
        name: 'second.list',
      ));
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
      expect(list.entries.map((e) => e.address),
          [_addrA, _addrB, _addrC]);
    });

    testWidgets('Create new makes a numbered copy', (tester) async {
      await importTwice(tester, secondAction: 'Create new');
      final lists = await LibraryStore.load();
      expect(lists.firstWhere((l) => l.title == 'Clash Movies').entries,
          hasLength(2));
      final copy =
          lists.firstWhere((l) => l.title == 'Clash Movies (2)');
      expect(copy.entries.map((e) => e.address), [_addrB, _addrC]);
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
