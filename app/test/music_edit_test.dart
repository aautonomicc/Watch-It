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
import 'package:watchit/services/season_grouping.dart' show AlbumKeys;
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

  Future<void> seedAlbum(List<MediaEntry> entries) => LibraryStore.save(
      [MediaList(id: 'music', title: 'Music', entries: entries)]);

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
    await seedAlbum([entry, track(2, 'Second Song')]);
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

    // The album name is identity (it drives the album fold), so the
    // edit renamed BOTH tracks of the album; the row lands on the
    // renamed key.
    final lists = await LibraryStore.load();
    expect([for (final e in lists.single.entries) e.name], [
      'Misspelt Artist - Fixed Album (1999) - 01 First Song.mp3',
      'Misspelt Artist - Fixed Album (1999) - 02 Second Song.mp3',
    ]);
    final parsed = parseMediaName(lists.single.entries.first.name);
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

  // ── track-number edit (renames the entry: the number IS identity) ──

  testWidgets('changing the track number renames the library entry',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final t1 = track(1, 'First Song');
    await seedAlbum([t1, track(2, 'Second Song')]);
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: EditDetailsScreen(
        entry: t1,
        ffmpeg: _NoFfmpeg(),
        postersDirProvider: () async => postersDir,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Track number'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Track number'), '7');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final lists = await LibraryStore.load();
    final names = [for (final e in lists.single.entries) e.name];
    expect(
        names,
        containsAll([
          'Misspelt Artist - Misspelt Album (1999) - 07 First Song.mp3',
          track(2, 'Second Song').name,
        ]));
    // Same address — playback/downloads never notice the rename.
    expect(lists.single.entries
        .singleWhere((e) => e.name.contains('07')).address, t1.address);
  });

  testWidgets('a taken (disc, track) number is refused, nothing renamed',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final t1 = track(1, 'First Song');
    await seedAlbum([t1, track(2, 'Second Song')]);
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: EditDetailsScreen(
        entry: t1,
        ffmpeg: _NoFfmpeg(),
        postersDirProvider: () async => postersDir,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Track number'), '2');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    // Refused with an explanation; the editor stays open.
    expect(find.textContaining('already taken'), findsOneWidget);
    expect(find.text('Edit track details'), findsOneWidget);
    final lists = await LibraryStore.load();
    expect([for (final e in lists.single.entries) e.name],
        [t1.name, track(2, 'Second Song').name]);
  });

  test('renumberTrackEntry migrates the per-track override row', () async {
    final t3 = track(3, 'Kept Song');
    await seedAlbum([t3]);
    final parsed = parseMediaName(t3.name);
    await saveUserDetails(
      lookupKey: trackLookupKey(parsed)!,
      title: 'Misspelt Album',
      episodeLabel: const Value('03 · My Fixed Name'),
      postersDirProvider: () async => postersDir,
    );

    final result = await renumberTrackEntry(t3,
        track: 5, postersDirProvider: () async => postersDir);
    expect(result.error, isNull);
    expect(result.newName,
        'Misspelt Artist - Misspelt Album (1999) - 05 Kept Song.mp3');
    // The row moved to the renamed key, marker updated in its label.
    expect(await metadataRowFor(trackLookupKey(parsed)!), isNull);
    final moved =
        await metadataRowFor(trackLookupKey(parseMediaName(result.newName!))!);
    expect(moved!.episodeLabel, '05 · My Fixed Name');
    // And the list entry is renamed.
    final lists = await LibraryStore.load();
    expect(lists.single.entries.single.name, result.newName);
  });

  test('renumberTrackEntry moves a track to another disc', () async {
    final t1 = track(1, 'First Song');
    await seedAlbum([t1, track(2, 'Second Song')]);
    // Same track number, different disc — no collision (disc 1 holds
    // the plain-marker sibling).
    final result = await renumberTrackEntry(t1,
        track: 2, disc: 2, postersDirProvider: () async => postersDir);
    expect(result.error, isNull);
    expect(result.newName,
        'Misspelt Artist - Misspelt Album (1999) - 2-02 First Song.mp3');
    final parsed = parseMediaName(result.newName!);
    expect(parsed.disc, 2);
    expect(parsed.track, 2);
  });

  // ── album/year edit (renames the whole album: they ARE the fold) ──

  testWidgets('changing only the year renames every track of the album',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final t1 = track(1, 'First Song');
    final other = MediaEntry(
        name: 'Other Artist - Loose Single (2003) - 03 Road Song.mp3',
        address: 'c' * 64);
    await seedAlbum([t1, track(2, 'Second Song'), other]);
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: EditDetailsScreen(
        entry: t1,
        ffmpeg: _NoFfmpeg(),
        postersDirProvider: () async => postersDir,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Year (optional)'), '2006');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final lists = await LibraryStore.load();
    expect([for (final e in lists.single.entries) e.name], [
      'Misspelt Artist - Misspelt Album (2006) - 01 First Song.mp3',
      'Misspelt Artist - Misspelt Album (2006) - 02 Second Song.mp3',
      other.name, // a different album never moves
    ]);
  });

  test(
      'renaming loose singles to one album/year combines them into a '
      'single album fold', () async {
    final a = MediaEntry(
        name: 'Singer A - Single A (1999) - 01 Song A.mp3',
        address: 'a' * 64);
    final b = MediaEntry(
        name: 'Singer B - Single B (2001) - 02 Song B.mp3',
        address: 'b' * 64);
    await seedAlbum([a, b]);
    final r1 = await renameTrackAlbum(a,
        album: 'My Album', year: 2006,
        postersDirProvider: () async => postersDir);
    expect(r1.error, isNull);
    final r2 = await renameTrackAlbum(b,
        album: 'My Album', year: 2006,
        postersDirProvider: () async => postersDir);
    expect(r2.error, isNull);
    final entries = (await LibraryStore.load()).single.entries;
    expect([for (final e in entries) e.name], [
      'Singer A - My Album (2006) - 01 Song A.mp3',
      'Singer B - My Album (2006) - 02 Song B.mp3',
    ]);
    // The wall's fold now sees ONE album (a Various Artists compilation).
    final keys = AlbumKeys(entries);
    expect(keys.keyFor(parseMediaName(entries.first.name)),
        keys.keyFor(parseMediaName(entries.last.name)));
  });

  testWidgets(
      'a taken track number in the target album is refused, nothing '
      'renamed', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final a = MediaEntry(
        name: 'Singer A - One (2001) - 01 X.mp3', address: 'a' * 64);
    final b = MediaEntry(
        name: 'Singer B - Two (2002) - 01 Y.mp3', address: 'b' * 64);
    await seedAlbum([a, b]);
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: EditDetailsScreen(
        entry: a,
        ffmpeg: _NoFfmpeg(),
        postersDirProvider: () async => postersDir,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Album'), 'Two');
    await tester.enterText(
        find.widgetWithText(TextField, 'Year (optional)'), '2002');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    // Refused with an explanation (the silent alternative: the
    // same-number-different-artist guard splitting the album apart).
    expect(find.textContaining('already taken'), findsOneWidget);
    expect(find.text('Edit track details'), findsOneWidget);
    expect([for (final e in (await LibraryStore.load()).single.entries) e.name],
        [a.name, b.name]);
  });

  test(
      'renameTrackAlbum drops the mbid tag, migrates the per-track row '
      'and carries the album artwork', () async {
    final entry = MediaEntry(
        name: 'The Rolling Stones - Let It Bleed (1969) - '
            '01 Gimme Shelter {mbid-xyz}.mp3',
        address: 'd' * 64);
    await seedAlbum([entry]);
    final parsed = parseMediaName(entry.name);
    expect(parsed.lookupKey, 'mbid:xyz');
    // The matched album row with artwork + a custom track title.
    File('${postersDir.path}/caa_test.jpg')
        .writeAsBytesSync([1, 2, 3], flush: true);
    await saveUserDetails(
      lookupKey: parsed.lookupKey,
      title: 'Let It Bleed',
      year: 1969,
      posterFile: const Value('caa_test.jpg'),
      postersDirProvider: () async => postersDir,
    );
    await saveUserDetails(
      lookupKey: trackLookupKey(parsed)!,
      title: 'Let It Bleed',
      episodeLabel: const Value('01 · My Name'),
      postersDirProvider: () async => postersDir,
    );

    final result = await renameTrackAlbum(entry,
        album: 'My Mix', year: 2006,
        postersDirProvider: () async => postersDir);
    expect(result.error, isNull);
    expect(result.newName,
        'The Rolling Stones - My Mix (2006) - 01 Gimme Shelter.mp3');
    final np = parseMediaName(result.newName!);
    expect(np.releaseMbid, isNull);
    // Per-track override moved to the renamed key, marker label kept.
    expect(await metadataRowFor(trackLookupKey(parsed)!), isNull);
    final moved = await metadataRowFor(trackLookupKey(np)!);
    expect(moved!.episodeLabel, '01 · My Name');
    // Artwork carried as a fresh copy under the new album key.
    expect(result.carriedPosterFile, isNotNull);
    expect(
        File('${postersDir.path}/${result.carriedPosterFile}')
            .readAsBytesSync(),
        [1, 2, 3]);
  });

  testWidgets(
      'a database match\'s differing canonical title alone never '
      'renames', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final t1 = track(1, 'First Song');
    await seedAlbum([t1]);
    final parsed = parseMediaName(t1.name);
    // A matched (NOT user-edited) row whose canonical title differs
    // from the sanitized file name.
    await applyRemoteTmdbDetails(
        lookupKey: parsed.lookupKey,
        updatedMs: 1,
        title: 'Fancy: Album',
        year: 1999);
    // Warm the service so the editor prefills from the row. (Drive the
    // scheduled resolve with pumps — whenIdle() awaits a timer-backed
    // future and hangs in the fake-async zone.)
    await tester.pumpWidget(const SizedBox());
    MetadataService.instance.metadataFor(t1);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: EditDetailsScreen(
        entry: t1,
        ffmpeg: _NoFfmpeg(),
        postersDirProvider: () async => postersDir,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Fancy: Album'), findsOneWidget); // prefilled
    await tester.enterText(
        find.widgetWithText(TextField, 'Description (optional)'),
        'Just a description edit.');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    // Untouched album/year fields → the file name stands.
    expect((await LibraryStore.load()).single.entries.single.name, t1.name);
    final row = await metadataRowFor(parsed.lookupKey);
    expect(row!.overview, 'Just a description edit.');
  });

  testWidgets(
      'a pre-existing album override (the old display-only edit) heals '
      'into a rename on Save', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final t1 = track(1, 'First Song');
    await seedAlbum([t1, track(2, 'Second Song')]);
    final parsed = parseMediaName(t1.name);
    // What the pre-alpha.83 editor stored: a user row that only ever
    // changed the display, never the grouping.
    await saveUserDetails(
      lookupKey: parsed.lookupKey,
      title: 'My Album',
      year: 2006,
      postersDirProvider: () async => postersDir,
    );
    // Warm the service so the editor prefills 'My Album' (see the pump
    // note in the previous test).
    await tester.pumpWidget(const SizedBox());
    MetadataService.instance.metadataFor(t1);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: EditDetailsScreen(
        entry: t1,
        ffmpeg: _NoFfmpeg(),
        postersDirProvider: () async => postersDir,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('My Album'), findsOneWidget); // prefilled override
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    // The user's own edit finally lands in the file names.
    expect([for (final e in (await LibraryStore.load()).single.entries) e.name], [
      'Misspelt Artist - My Album (2006) - 01 First Song.mp3',
      'Misspelt Artist - My Album (2006) - 02 Second Song.mp3',
    ]);
  });
}
