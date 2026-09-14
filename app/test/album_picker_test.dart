import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/organize.dart';
import 'package:watchit/services/season_grouping.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/organize_dialogs.dart';

/// The existing-album picker (2026-09-14): [pickAlbumTargetFlow]'s
/// full-screen album chooser replaces free-text-only move targets. The
/// key correctness pin: a target derived from a PICKED album carries
/// its `{mbid-...}` tag, because tagged albums fold on the mbid — a
/// re-typed artist/album/year of the same album would create a second
/// wall card.
String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

const _mbid = '499485cb-aaaa-bbbb-cccc-123456789012';

MediaEntry _tagged(int addr, int n, String title) => MediaEntry(
      name: 'Neon Cascade - Peak Bloom (2021) - '
          '${n.toString().padLeft(2, '0')} $title {mbid-$_mbid}.mp3',
      address: _addr(addr),
    );

MediaEntry _duo(int addr, String album, int year, String title) =>
    MediaEntry(
      name: 'Duo Band - $album ($year) - 01 $title.mp3',
      address: _addr(addr),
    );

MediaEntry _mix(int addr) =>
    MediaEntry(name: 'mixfile.mp3', address: _addr(addr));

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
  });

  test('planOrganize with releaseMbid tags the new names so they fold '
      'into the existing mbid album', () async {
    final existing = [_tagged(1, 1, 'Alpha'), _tagged(2, 2, 'Beta')];
    await LibraryStore.save(
        [MediaList(id: 'm', title: 'Music', entries: existing)]);
    final plan = await planOrganize(
      [_mix(9)],
      artist: 'Neon Cascade',
      album: 'Peak Bloom',
      year: 2021,
      releaseMbid: _mbid,
    );
    expect(plan.error, isNull);
    final newName = plan.items.single.newName;
    expect(newName,
        'Neon Cascade - Peak Bloom (2021) - 03 mixfile {mbid-$_mbid}.mp3');
    // The renamed file folds into the SAME album card as the tagged
    // tracks (mbid cluster), not a second same-named one.
    final folded = groupShows(
        [...existing, MediaEntry(name: newName, address: _addr(9))]);
    expect(folded.whereType<HomeAlbum>().length, 1);
    expect(folded.whereType<HomeAlbum>().single.tracks.length, 3);
  });

  test(
      'with two same-named tagged releases only the mbid places the '
      'move — an untagged rename forks a third card', () async {
    // Two releases of the same album (distinct mbids): title/year
    // adoption is ambiguous, so an untagged newcomer folds into
    // NEITHER — the fork the picker-derived mbid prevents. (Against a
    // SINGLE tagged album, AlbumKeys' adoption rescues an untagged
    // exact-match rename; the ambiguous case is where the tag is
    // load-bearing.)
    const other = '11111111-2222-3333-4444-555555555555';
    final existing = [
      _tagged(1, 1, 'Alpha'),
      MediaEntry(
          name: 'Neon Cascade - Peak Bloom (2021) - 01 Alpha '
              '{mbid-$other}.mp3',
          address: _addr(2)),
    ];
    await LibraryStore.save(
        [MediaList(id: 'm', title: 'Music', entries: existing)]);
    final untagged = await planOrganize(
      [_mix(9)],
      artist: 'Neon Cascade',
      album: 'Peak Bloom',
      year: 2021,
    );
    // Same artist throughout, so the albums fold under a HomeArtist
    // card — flatten before counting.
    List<HomeAlbum> albumsOf(List<MediaEntry> entries) => [
          for (final item in groupShows(entries))
            ...switch (item) {
              HomeAlbum() => [item],
              HomeArtist(:final albums) => albums,
              _ => <HomeAlbum>[],
            },
        ];
    expect(untagged.error, isNull);
    expect(
        albumsOf([
          ...existing,
          MediaEntry(
              name: untagged.items.single.newName, address: _addr(9)),
        ]).length,
        3);
    final tagged = await planOrganize(
      [_mix(9)],
      artist: 'Neon Cascade',
      album: 'Peak Bloom',
      year: 2021,
      releaseMbid: _mbid,
    );
    expect(tagged.error, isNull);
    final folded = albumsOf([
      ...existing,
      MediaEntry(name: tagged.items.single.newName, address: _addr(9)),
    ]);
    expect(folded.length, 2);
    expect(
        folded.where((a) => a.tracks.length == 2).length, 1);
  });

  /// Pumps a host whose button runs [pickAlbumTargetFlow] and opens
  /// the picker; returns a getter for the flow's result (valid once
  /// the picker has been driven to completion).
  Future<AlbumTarget? Function()> pumpFlowHost(
    WidgetTester tester, {
    bool askTrackNumber = false,
    MediaEntry? excludeAlbumOf,
  }) async {
    AlbumTarget? captured;
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () async {
                captured = await pickAlbumTargetFlow(context,
                    count: 1,
                    askTrackNumber: askTrackNumber,
                    excludeAlbumOf: excludeAlbumOf);
              },
              child: const Text('go'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    return () => captured;
  }

  testWidgets(
      'picking an existing album derives artist/album/year AND the '
      'mbid from its own tracks', (tester) async {
    await LibraryStore.save([
      MediaList(id: 'm', title: 'Music', entries: [
        // The tag sits on track 2 only — any track's tag identifies
        // the fold, so it must still be adopted.
        MediaEntry(
            name: 'Neon Cascade - Peak Bloom (2021) - 01 Alpha.mp3',
            address: _addr(1)),
        _tagged(2, 2, 'Beta'),
      ]),
    ]);
    final read = await pumpFlowHost(tester);
    expect(find.text('Move 1 file to album'), findsOneWidget);
    await tester.tap(find.text('Peak Bloom (2021)'));
    await tester.pumpAndSettle();
    final target = read();
    expect(target, isNotNull);
    expect(target!.artist, 'Neon Cascade');
    expect(target.album, 'Peak Bloom');
    expect(target.year, 2021);
    expect(target.mbid, _mbid);
    expect(target.track, isNull);
    // No free-text dialog was involved.
    expect(find.text('Preview new names'), findsNothing);
  });

  testWidgets(
      'an artist with several albums expands; the current album is '
      'hidden (self-move is a no-op)', (tester) async {
    final first = _duo(1, 'First', 2001, 'One');
    await LibraryStore.save([
      MediaList(id: 'm', title: 'Music', entries: [
        first,
        _duo(2, 'Second', 2002, 'Two'),
        _duo(3, 'Third', 2003, 'Three'),
      ]),
    ]);
    final read = await pumpFlowHost(tester, excludeAlbumOf: first);
    // First is hidden; the artist tile folds the remaining two.
    await tester.tap(find.text('Duo Band'));
    await tester.pumpAndSettle();
    expect(find.text('First (2001)'), findsNothing);
    expect(find.text('Second (2002)'), findsOneWidget);
    await tester.tap(find.text('Third (2003)'));
    await tester.pumpAndSettle();
    final target = read();
    expect(target!.album, 'Third');
    expect(target.year, 2003);
    expect(target.mbid, isNull);
  });

  testWidgets(
      'search narrows the list and New album… prefills the typed '
      'artist into the free-text dialog', (tester) async {
    await LibraryStore.save([
      MediaList(id: 'm', title: 'Music', entries: [
        _tagged(1, 1, 'Alpha'),
        _duo(2, 'Second', 2002, 'Two'),
        _duo(3, 'Third', 2003, 'Three'),
      ]),
    ]);
    final read = await pumpFlowHost(tester);
    await tester.enterText(
        find.widgetWithText(TextField, 'Search albums…'), 'Fresh Artist');
    await tester.pump(const Duration(milliseconds: 200));
    // Nothing matches; the artist tile flattens away too.
    expect(find.text('Duo Band'), findsNothing);
    expect(find.text('No album matches.'), findsOneWidget);
    await tester.tap(find.text('New album…'));
    await tester.pumpAndSettle();
    // The free-text dialog opens with the query as the artist.
    expect(find.text('Preview new names'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Fresh Artist'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Album'), 'Brand New');
    await tester.tap(find.text('Preview new names'));
    await tester.pumpAndSettle();
    final target = read();
    expect(target!.artist, 'Fresh Artist');
    expect(target.album, 'Brand New');
    expect(target.mbid, isNull);
  });

  testWidgets(
      'a track search hit surfaces its album; askTrackNumber asks the '
      'optional number after an existing pick', (tester) async {
    await LibraryStore.save([
      MediaList(id: 'm', title: 'Music', entries: [
        _tagged(1, 1, 'Sunrise Shuffle'),
        _duo(2, 'Second', 2002, 'Two'),
      ]),
    ]);
    final read = await pumpFlowHost(tester, askTrackNumber: true);
    await tester.enterText(
        find.widgetWithText(TextField, 'Search albums…'), 'sunrise');
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Second (2002)'), findsNothing);
    await tester.tap(find.text('Peak Bloom (2021)'));
    await tester.pumpAndSettle();
    expect(find.text('Track number in "Peak Bloom"'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Track number (optional)'), '5');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    final target = read();
    expect(target!.album, 'Peak Bloom');
    expect(target.track, 5);
    expect(target.mbid, _mbid);
  });
}
