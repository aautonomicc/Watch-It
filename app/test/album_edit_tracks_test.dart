import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/screens/album_screen.dart';
import 'package:watchit/services/connectivity.dart';
import 'package:watchit/services/download_manager.dart';
import 'package:watchit/services/embedded_client.dart';
import 'package:watchit/services/favourites.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/services/season_grouping.dart';
import 'package:watchit/services/watch_state.dart';
import 'package:watchit/theme/tokens.dart';

/// The album page's Edit-tracks mode (2026-09-12 collection editor):
/// checkbox rows with bulk Move-to-album / Remove-from-album and the
/// "Renumber 1..N" gap closer. (The drag-reorder renumber's maths are
/// pinned by the renumberAlbumTracks service tests.)
String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

MediaEntry _track(int addr, int n, String title) => MediaEntry(
      name: 'Neat Artist - Neat Album (2020) - '
          '${n.toString().padLeft(2, '0')} $title.mp3',
      address: _addr(addr),
    );

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    MetadataService.instance =
        MetadataService(apiKeyProvider: () async => '');
    final dlDir = Directory.systemTemp.createTempSync('wi-albedit');
    addTearDown(() => dlDir.deleteSync(recursive: true));
    DownloadManager.instance = DownloadManager(directory: dlDir);
    ConnectivityMonitor.instance = ConnectivityMonitor(
        probe: () async => ClientHealth(state: 'ready', peers: 5));
    FavouritesStore.instance = FavouritesStore();
    WatchStateStore.instance = WatchStateStore();
  });

  Future<HomeAlbum> seed(List<MediaEntry> tracks) async {
    await LibraryStore.save(
        [MediaList(id: 'm', title: 'Music', entries: tracks)]);
    return groupShows(tracks).single as HomeAlbum;
  }

  Future<void> pumpAlbum(WidgetTester tester, HomeAlbum album) async {
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: AlbumScreen(
        group: album,
        sourceOverride: (e) => (url: 'fake://${e.address}', local: true),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('Edit tracks: Renumber 1..N closes numbering gaps',
      (tester) async {
    final album = await seed([
      _track(1, 2, 'Alpha'),
      _track(2, 5, 'Beta'),
      _track(3, 9, 'Gamma'),
    ]);
    await pumpAlbum(tester, album);

    await tester.tap(find.byTooltip('Edit tracks'));
    await tester.pumpAndSettle();
    expect(find.byType(CheckboxListTile), findsNWidgets(3));

    await tester.tap(find.text('Renumber 1..3'));
    await tester.pumpAndSettle();

    final names = [
      for (final e in (await LibraryStore.load()).single.entries) e.name,
    ];
    expect(names, [
      'Neat Artist - Neat Album (2020) - 01 Alpha.mp3',
      'Neat Artist - Neat Album (2020) - 02 Beta.mp3',
      'Neat Artist - Neat Album (2020) - 03 Gamma.mp3',
    ]);
    // The page refolded onto the renamed tracks (still 3 rows).
    expect(find.byType(CheckboxListTile), findsNWidgets(3));
  });

  testWidgets(
      'Edit tracks: Remove from album renames the ticked track to a '
      'standalone file and refolds the page', (tester) async {
    final album = await seed([
      _track(1, 1, 'Alpha'),
      _track(2, 2, 'Beta'),
      _track(3, 3, 'Gamma'),
    ]);
    await pumpAlbum(tester, album);

    await tester.tap(find.byTooltip('Edit tracks'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Beta'));
    await tester.pump();
    await tester.tap(find.text('Remove 1 from album'));
    await tester.pumpAndSettle();
    // Confirm dialog explains the rename.
    expect(find.textContaining('renamed to just its title'),
        findsOneWidget);
    await tester.tap(find.text('Remove track'));
    await tester.pumpAndSettle();

    final names = [
      for (final e in (await LibraryStore.load()).single.entries) e.name,
    ];
    expect(names, containsAll([
      'Neat Artist - Neat Album (2020) - 01 Alpha.mp3',
      'Beta.mp3',
      'Neat Artist - Neat Album (2020) - 03 Gamma.mp3',
    ]));
    // The album page now folds 2 tracks.
    expect(find.byType(CheckboxListTile), findsNWidgets(2));
    expect(find.text('Beta'), findsNothing);
  });

  testWidgets(
      'Edit tracks: Move to album renames the ticked track into the '
      'target album after a preview', (tester) async {
    final album = await seed([
      _track(1, 1, 'Alpha'),
      _track(2, 2, 'Beta'),
    ]);
    await pumpAlbum(tester, album);

    await tester.tap(find.byTooltip('Edit tracks'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Beta'));
    await tester.pump();
    await tester.tap(find.text('Move 1 to album…'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Artist'), 'Other Artist');
    await tester.enterText(
        find.widgetWithText(TextField, 'Album'), 'Elsewhere');
    await tester.tap(find.text('Preview new names'));
    await tester.pumpAndSettle();
    expect(find.text('→  Other Artist - Elsewhere - 01 Beta.mp3'),
        findsOneWidget);
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    final names = [
      for (final e in (await LibraryStore.load()).single.entries) e.name,
    ];
    expect(names, containsAll([
      'Neat Artist - Neat Album (2020) - 01 Alpha.mp3',
      'Other Artist - Elsewhere - 01 Beta.mp3',
    ]));
    // This album keeps only Alpha.
    expect(find.byType(CheckboxListTile), findsOneWidget);
  });

  testWidgets('multi-disc albums hide reorder and Renumber',
      (tester) async {
    final tracks = [
      MediaEntry(
          name: 'A - Boxset (2000) - 1-01 One.mp3', address: _addr(1)),
      MediaEntry(
          name: 'A - Boxset (2000) - 2-01 Two.mp3', address: _addr(2)),
    ];
    final album = await seed(tracks);
    await pumpAlbum(tester, album);

    await tester.tap(find.byTooltip('Edit tracks'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Renumber 1..'), findsNothing);
    expect(find.byIcon(Icons.drag_indicator), findsNothing);
    // Checkbox actions stay available.
    expect(find.byType(CheckboxListTile), findsNWidgets(2));
    expect(find.text('Remove from album'), findsOneWidget);
  });
}
