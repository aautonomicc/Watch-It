import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/screens/edit_details_screen.dart';
import 'package:watchit/services/ffmpeg.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/services/user_metadata.dart';
import 'package:watchit/theme/tokens.dart';

/// ffmpeg reported missing — the "From video frame" button must hide.
class _NoFfmpeg extends FfmpegService {
  @override
  Future<bool> get available async => false;
}

class _FakeFileSelector extends FileSelectorPlatform
    with MockPlatformInterfaceMixin {
  _FakeFileSelector(this.file);
  final XFile? file;

  @override
  Future<XFile?> openFile(
          {List<XTypeGroup>? acceptedTypeGroups,
          String? initialDirectory,
          String? confirmButtonText}) async =>
      file;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const name = 'Beach Day 2021.mp4';
  final key = parseMediaName(name).lookupKey;
  const addr =
      'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
  final entry = MediaEntry(name: name, address: addr);

  late Directory postersDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    postersDir = Directory.systemTemp.createTempSync('wi-edit-details');
    MetadataService.instance = MetadataService(
      postersDirProvider: () async => postersDir,
      apiKeyProvider: () async => '',
    );
  });

  tearDown(() {
    postersDir.deleteSync(recursive: true);
  });

  Future<void> pumpEditor(WidgetTester tester,
      {MediaEntry? forEntry,
      EditDetailsScope scope = EditDetailsScope.entry}) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: EditDetailsScreen(
        entry: forEntry ?? entry,
        scope: scope,
        ffmpeg: _NoFfmpeg(),
        postersDirProvider: () async => postersDir,
      ),
    ));
    await tester.pumpAndSettle();
  }

  Finder fieldWithLabel(String label) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == label);

  testWidgets('prefills from parsed name, saves user details',
      (tester) async {
    await pumpEditor(tester);

    // Prefilled with the parsed-name fallback; no frame button without
    // ffmpeg.
    expect(find.widgetWithText(TextField, 'Beach Day'), findsOneWidget);
    expect(find.text('From video frame'), findsNothing);
    expect(find.text('From image file'), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, 'Beach Day'), 'Beach Day With Nan');
    await tester.enterText(
        find.byWidgetPredicate((w) =>
            w is TextField &&
            w.decoration?.labelText == 'Description (optional)'),
        'Granny finally got in the sea.');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final row = await metadataRowFor(key);
    expect(row!.userEdited, true);
    expect(row.title, 'Beach Day With Nan');
    expect(row.overview, 'Granny finally got in the sea.');
    expect(row.year, 2021);
  });

  testWidgets('artwork from an image file lands in the posters dir',
      (tester) async {
    // A real (1x1 transparent) PNG — the editor previews the pick with
    // Image.memory, which decodes it.
    final bytes = Uint8List.fromList([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00,
      0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
      0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89,
      0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62,
      0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4,
      0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60,
      0x82,
    ]);
    FileSelectorPlatform.instance = _FakeFileSelector(
        XFile.fromData(bytes, name: 'poster.jpg', path: 'poster.jpg'));
    await pumpEditor(tester);

    await tester.tap(find.text('From image file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final row = await metadataRowFor(key);
    expect(row!.posterFile, startsWith('user_'));
    final saved = File('${postersDir.path}/${row.posterFile}');
    expect(saved.existsSync(), true);
    expect(saved.readAsBytesSync(), bytes);
  });

  group('TV scopes', () {
    const epName = 'My Show S01E02.mkv';
    final epParsed = parseMediaName(epName);
    final episode = MediaEntry(
        name: epName,
        address:
            'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd');

    testWidgets('episode entries edit the episode, not the show',
        (tester) async {
      await pumpEditor(tester, forEntry: episode);

      // No show-title/year fields; the text field is the episode name.
      expect(fieldWithLabel('Title'), findsNothing);
      expect(fieldWithLabel('Year (optional)'), findsNothing);
      final nameField =
          fieldWithLabel('Episode name (optional) — S01E02');
      expect(nameField, findsOneWidget);
      expect(find.text('Edit episode details'), findsOneWidget);

      await tester.enterText(nameField, 'The One With The Beach');
      await tester.enterText(fieldWithLabel('Description (optional)'),
          'They go to the beach.');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final row = await metadataRowFor(epParsed.lookupKey);
      expect(row!.userEdited, true);
      expect(row.episodeLabel, 'S01E02 · The One With The Beach');
      expect(row.overview, 'They go to the beach.');
      expect(row.title, 'My Show'); // show title kept, not rewritten
      expect(await metadataRowFor(epParsed.showLookupKey), isNull);
    });

    testWidgets('show scope writes the show key', (tester) async {
      await pumpEditor(tester,
          forEntry: episode, scope: EditDetailsScope.show);

      expect(find.text('Edit show details'), findsOneWidget);
      expect(fieldWithLabel('Title'), findsOneWidget);
      await tester.enterText(fieldWithLabel('Title'), 'Renamed Show');
      await tester.enterText(
          fieldWithLabel('Description (optional)'), 'A show of ours.');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final row = await metadataRowFor(epParsed.showLookupKey);
      expect(row!.userEdited, true);
      expect(row.title, 'Renamed Show');
      expect(row.overview, 'A show of ours.');
      expect(await metadataRowFor(epParsed.lookupKey), isNull);
    });

    testWidgets('season scope writes the season key', (tester) async {
      await pumpEditor(tester,
          forEntry: episode, scope: EditDetailsScope.season);

      expect(find.text('Edit season 1 details'), findsOneWidget);
      expect(fieldWithLabel('Title'), findsNothing);
      await tester.enterText(fieldWithLabel('Description (optional)'),
          'The first season.');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final row = await metadataRowFor(epParsed.seasonLookupKey!);
      expect(row!.userEdited, true);
      expect(row.overview, 'The first season.');
      expect(await metadataRowFor(epParsed.lookupKey), isNull);
    });
  });

  testWidgets('remove-my-edits appears for user rows and clears them',
      (tester) async {
    await saveUserDetails(
      lookupKey: key,
      title: 'My Title',
      postersDirProvider: () async => postersDir,
    );
    await pumpEditor(tester);

    final remove = find.textContaining('Remove my edits');
    expect(remove, findsOneWidget);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove edits'));
    await tester.pumpAndSettle();

    expect(await metadataRowFor(key), isNull);
  });
}
