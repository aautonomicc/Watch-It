import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

/// Editing a music track edits EVERY field: artist/album/year/
/// description/artwork live on the album's shared cache row, the
/// track's own title in a per-track row overlaid onto it — so naming
/// mistakes anywhere in a rip stay fixable from the app.
class _NoFfmpeg extends FfmpegService {
  @override
  Future<bool> get available async => false;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory postersDir;

  MediaEntry track(int n, String title) => MediaEntry(
        name: 'Misspelt Artist - Misspelt Album (1999) - '
            '${n.toString().padLeft(2, '0')} $title.mp3',
        address: n.toRadixString(16).padLeft(64, '0'),
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    MetadataService.instance = MetadataService(
      postersDirProvider: () async => postersDir,
      apiKeyProvider: () async => '',
    );
    postersDir = Directory.systemTemp.createTempSync('wi-musicedit');
  });

  tearDown(() {
    try {
      postersDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('parsed fallback carries the artist; keys derive per track', () {
    final parsed = parseMediaName(track(1, 'First Song').name);
    expect(parsed.artist, 'Misspelt Artist');
    expect(fallbackMetadataFor(track(1, 'First Song')).artist,
        'Misspelt Artist');
    expect(trackLookupKey(parsed),
        'music:misspelt artist:misspelt album:1999:t1-1');
  });

  test(
      'artist/album edits land on the shared row; the track title in '
      'its own row — and every track sees them', () async {
    final t1 = track(1, 'First Song');
    final t2 = track(2, 'Second Song');
    final parsed = parseMediaName(t1.name);

    // The album-level edit (what the track editor's Save writes).
    await saveUserDetails(
      lookupKey: parsed.lookupKey,
      title: 'Real Album',
      year: 2001,
      artist: const Value('Real Artist'),
      postersDirProvider: () async => postersDir,
    );
    // The track-level title fix for track 1 only.
    await saveUserDetails(
      lookupKey: trackLookupKey(parsed)!,
      title: 'Real Album',
      episodeLabel: const Value('01 · Real Song'),
      postersDirProvider: () async => postersDir,
    );

    final service = MetadataService.instance;
    service.metadataFor(t1); // schedule resolves
    service.metadataFor(t2);
    await service.whenIdle();

    final m1 = service.metadataFor(t1);
    expect(m1.title, 'Real Album');
    expect(m1.artist, 'Real Artist');
    expect(m1.year, 2001);
    expect(m1.episodeLabel, '01 · Real Song');
    // The sibling shares the album fixes but keeps its own file title.
    final m2 = service.metadataFor(t2);
    expect(m2.title, 'Real Album');
    expect(m2.artist, 'Real Artist');
    expect(m2.episodeLabel, '02 · Second Song');
  });

  testWidgets(
      'track editor shows every field and saves artist/album/track '
      'title', (tester) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final entry = track(1, 'First Song');
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: EditDetailsScreen(
        entry: entry,
        ffmpeg: _NoFfmpeg(),
        postersDirProvider: () async => postersDir,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Edit track details'), findsOneWidget);
    // All fields present, prefilled from the file name.
    expect(find.widgetWithText(TextField, 'Artist'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Album'), findsOneWidget);
    expect(find.text('Misspelt Artist'), findsOneWidget);
    expect(find.text('Misspelt Album'), findsOneWidget);
    expect(find.text('First Song'), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, 'Artist'), 'Fixed Artist');
    await tester.enterText(
        find.widgetWithText(TextField, 'Album'), 'Fixed Album');
    await tester.enterText(
        find.widgetWithText(TextField, 'Track title — 01'), 'Fixed Song');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final parsed = parseMediaName(entry.name);
    final albumRow = await metadataRowFor(parsed.lookupKey);
    expect(albumRow!.userEdited, isTrue);
    expect(albumRow.title, 'Fixed Album');
    expect(albumRow.artist, 'Fixed Artist');
    final trackRow = await metadataRowFor(trackLookupKey(parsed)!);
    expect(trackRow!.episodeLabel, '01 · Fixed Song');
  });

  testWidgets(
      'typing the original track title back removes the override row',
      (tester) async {
    final entry = track(3, 'Kept Song');
    final parsed = parseMediaName(entry.name);
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Pre-existing override to clear. (No runAsync anywhere in this
    // test — the in-memory drift DB deadlocks when opened in one zone
    // and queried from the other.)
    await saveUserDetails(
      lookupKey: trackLookupKey(parsed)!,
      title: 'Misspelt Album',
      episodeLabel: const Value('03 · Wrong Fix'),
      postersDirProvider: () async => postersDir,
    );
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: EditDetailsScreen(
        entry: entry,
        ffmpeg: _NoFfmpeg(),
        postersDirProvider: () async => postersDir,
      ),
    ));
    await tester.pumpAndSettle();
    // Typing the file name's own title back removes the override.
    await tester.enterText(
        find.widgetWithText(TextField, 'Track title — 03'), 'Kept Song');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(await metadataRowFor(trackLookupKey(parsed)!), isNull);
  });
}
