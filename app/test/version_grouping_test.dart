import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/screens/detail_screen.dart';
import 'package:watchit/services/connectivity.dart';
import 'package:watchit/services/download_manager.dart';
import 'package:watchit/services/embedded_client.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/services/season_grouping.dart';
import 'package:watchit/services/watch_state.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/poster_cards.dart';

// Same-title version grouping: multiple uploads of one film share a
// single wall card, and the detail page switches between them with a
// version dropdown.

String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

const _name = 'Night of the Living Dead (1968) {imdb-tt0063350}.mp4';

MediaEntry get _v480 => MediaEntry(
    name: _name, address: _addr(1), sizeBytes: 597585042,
    videoInfo: '480p H.264');
MediaEntry get _v1080 => MediaEntry(
    name: _name, address: _addr(2), sizeBytes: 5682464056,
    videoInfo: '1080p H.264');

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('groupSeasons version folding', () {
    test('same-title uploads fold into one card carrying all versions', () {
      final items = groupSeasons([_v480, _v1080]);
      final item = items.single as HomeEntry;
      expect(item.entry.address, _addr(1)); // first version is primary
      expect(item.versions.map((e) => e.address), [_addr(1), _addr(2)]);
      expect(item.allVersions, hasLength(2));
    });

    test('the folded card sits where the first upload appeared', () {
      final items = groupSeasons([
        _v480,
        MediaEntry(name: 'Nosferatu (1922).mp4', address: _addr(3)),
        _v1080,
      ]);
      expect(items, hasLength(2));
      expect((items[0] as HomeEntry).allVersions, hasLength(2));
      expect((items[1] as HomeEntry).entry.name, 'Nosferatu (1922).mp4');
    });

    test('different titles and years never fold', () {
      final items = groupSeasons([
        MediaEntry(name: 'The Movie (2020).mp4', address: _addr(1)),
        MediaEntry(name: 'The Movie (2021).mp4', address: _addr(2)),
        MediaEntry(name: 'Other Film (2020).mp4', address: _addr(3)),
      ]);
      expect(items, hasLength(3));
      for (final item in items.cast<HomeEntry>()) {
        expect(item.versions, isEmpty);
        expect(item.allVersions, hasLength(1));
      }
    });

    test('an imdb id tag folds uploads whose display names differ', () {
      // The id wins over the title text in the lookup key, exactly like
      // the metadata matcher.
      final items = groupSeasons([
        _v480,
        MediaEntry(
            name: 'NOTLD.1968.{imdb-tt0063350}.remaster.mkv',
            address: _addr(9)),
      ]);
      expect((items.single as HomeEntry).allVersions, hasLength(2));
    });

    test('a loosely named copy folds with its imdb-tagged sibling', () {
      // The regression behind the alpha.50 desktop report: an entry
      // imported/kept under `Title (Year).mp4` (no imdb tag) parsed to a
      // title/year key and sat beside the tagged catalog entries as a
      // second card.
      final loose = MediaEntry(
          name: 'Night of the Living Dead (1968).mp4', address: _addr(7));
      for (final order in [
        [_v480, _v1080, loose],
        [loose, _v480, _v1080],
      ]) {
        final items = groupSeasons(order);
        final item = items.single as HomeEntry;
        expect(item.allVersions, hasLength(3));
        expect(item.entry.address, order.first.address);
      }
    });

    test('an untagged copy with no year folds by title alone', () {
      final items = groupSeasons([
        _v480,
        MediaEntry(name: 'Night of the Living Dead.mp4', address: _addr(7)),
      ]);
      expect((items.single as HomeEntry).allVersions, hasLength(2));
    });

    test('a title claimed by two imdb ids never absorbs untagged copies',
        () {
      // Two remakes sharing a title: folding the untagged copy into
      // either would guess. It keeps its own card.
      final items = groupSeasons([
        MediaEntry(
            name: 'Nosferatu (1922) {imdb-tt0013442}.mp4', address: _addr(1)),
        MediaEntry(
            name: 'Nosferatu (2024) {imdb-tt5040012}.mp4', address: _addr(2)),
        MediaEntry(name: 'Nosferatu.mp4', address: _addr(3)),
      ]);
      expect(items, hasLength(3));
    });

    test('a year mismatch against the tagged sibling never folds', () {
      final items = groupSeasons([
        _v480,
        MediaEntry(
            name: 'Night of the Living Dead (1990).mp4', address: _addr(7)),
      ]);
      expect(items, hasLength(2));
    });

    test('duplicate addresses dedup instead of listing twice', () {
      final items = groupSeasons([_v480, _v480]);
      final item = items.single as HomeEntry;
      expect(item.versions, isEmpty); // still a single-version card
      expect(item.allVersions, hasLength(1));
    });

    test('episodes keep folding by season, not by version', () {
      final items = groupSeasons([
        MediaEntry(name: 'Show S01E01.mkv', address: _addr(1)),
        MediaEntry(name: 'Show S01E02.mkv', address: _addr(2)),
      ]);
      expect(items.single, isA<HomeSeason>());
    });
  });

  group('widgets', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({'defaults_seeded_v4': true});
      await LibraryStore.useForTesting(
          AppDatabase.forTesting(NativeDatabase.memory()));
      MetadataService.instance =
          MetadataService(apiKeyProvider: () async => '');
      WatchStateStore.instance = WatchStateStore();
      DownloadManager.instance = DownloadManager();
      ConnectivityMonitor.instance = ConnectivityMonitor(
          probe: () async => ClientHealth(state: 'ready', peers: 5));
      await ConnectivityMonitor.instance.refresh();
    });

    Widget page(Widget home) => MaterialApp(
          theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
          home: home,
        );

    testWidgets('a multi-version card shows the count, not one format',
        (tester) async {
      await tester.pumpWidget(page(Scaffold(
        body: PosterCard(
          entry: _v480,
          versionCount: 2,
          tokens: WiTokens.dark,
          onTap: () {},
        ),
      )));
      await tester.pumpAndSettle();
      expect(find.text('2 versions'), findsOneWidget);
      expect(find.textContaining('480p'), findsNothing);
    });

    testWidgets('detail page grows a dropdown that switches versions',
        (tester) async {
      await LibraryStore.save([
        MediaList(id: 'l1', title: 'Movies', entries: [_v480, _v1080]),
      ]);
      await tester.pumpWidget(page(DetailScreen(entry: _v480)));
      await tester.pumpAndSettle();

      // The picker shows the current version's format/size line.
      expect(find.byType(DropdownButton<String>), findsOneWidget);
      expect(find.text('480p H.264 · 570 MB'), findsWidgets);

      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      expect(find.text('1080p H.264 · 5.29 GB'), findsWidgets);
      await tester.tap(find.text('1080p H.264 · 5.29 GB').last);
      await tester.pumpAndSettle();

      // Page-wide switch: the header/FILE info now describes the 1080p
      // upload, and the 480p line is gone.
      expect(find.text('1080p H.264 · 5.29 GB'), findsWidgets);
      expect(find.text('480p H.264 · 570 MB'), findsNothing);
    });

    testWidgets('a version found only via the library still selects',
        (tester) async {
      // Opened from Continue Watching with the 1080p copy: the picker
      // starts on that version, not on the library's first.
      await LibraryStore.save([
        MediaList(id: 'l1', title: 'Movies', entries: [_v480, _v1080]),
      ]);
      await tester.pumpWidget(page(DetailScreen(entry: _v1080)));
      await tester.pumpAndSettle();
      expect(find.text('1080p H.264 · 5.29 GB'), findsWidgets);
      expect(find.byType(DropdownButton<String>), findsOneWidget);
    });

    testWidgets('the dropdown also finds a loosely named library sibling',
        (tester) async {
      final loose = MediaEntry(
          name: 'Night of the Living Dead (1968).mp4',
          address: _addr(7),
          sizeBytes: 5682464056,
          videoInfo: '1080p H.264');
      await LibraryStore.save([
        MediaList(id: 'l1', title: 'Movies', entries: [_v480, loose]),
      ]);
      await tester.pumpWidget(page(DetailScreen(entry: _v480)));
      await tester.pumpAndSettle();
      expect(find.byType(DropdownButton<String>), findsOneWidget);
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      expect(find.text('1080p H.264 · 5.29 GB'), findsWidgets);
    });

    testWidgets('single-version titles keep the plain info line',
        (tester) async {
      await LibraryStore.save([
        MediaList(id: 'l1', title: 'Movies', entries: [_v480]),
      ]);
      await tester.pumpWidget(page(DetailScreen(entry: _v480)));
      await tester.pumpAndSettle();
      expect(find.byType(DropdownButton<String>), findsNothing);
      expect(find.text('480p H.264 · 570 MB'), findsWidgets);
    });
  });
}
