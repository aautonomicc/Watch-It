import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/main.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/screens/album_screen.dart' show AlbumAudioPlayer;
import 'package:watchit/screens/detail_screen.dart';
import 'package:watchit/screens/edit_details_screen.dart';
import 'package:watchit/screens/needs_sorting_screen.dart';
import 'package:watchit/screens/playlist_screen.dart';
import 'package:watchit/services/connectivity.dart';
import 'package:watchit/services/download_manager.dart';
import 'package:watchit/services/embedded_client.dart';
import 'package:watchit/services/favourites.dart';
import 'package:watchit/services/ffmpeg.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/services/terms.dart';
import 'package:watchit/services/watch_state.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/library_drawer.dart';

/// Playlists (own drawer section, ordered track page, shared play
/// queue) and the Needs-sorting bulk organizer — the 2026-09-11 music
/// cleanup plan's UI layer.
String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

MediaEntry _track(int n, String title) => MediaEntry(
      name: 'Neat Artist - Neat Album (2020) - '
          '${n.toString().padLeft(2, '0')} $title.mp3',
      address: _addr(n),
    );

MediaEntry _mix(int n, String name) =>
    MediaEntry(name: name, address: _addr(n));

class _FakePlayer implements AlbumAudioPlayer {
  final opened = <String>[];
  bool playing = false;
  final _playing = StreamController<bool>.broadcast(sync: true);
  final _position = StreamController<Duration>.broadcast(sync: true);
  final _duration = StreamController<Duration>.broadcast(sync: true);
  final _completed = StreamController<bool>.broadcast(sync: true);

  @override
  Future<void> open(String url) async {
    opened.add(url);
    playing = true;
    _playing.add(true);
    _duration.add(const Duration(minutes: 3));
  }

  @override
  Future<void> playOrPause() async {
    playing = !playing;
    _playing.add(playing);
  }

  @override
  Future<void> seek(Duration position) async => _position.add(position);

  void completeTrack() => _completed.add(true);

  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<Duration> get positionStream => _position.stream;
  @override
  Stream<Duration> get durationStream => _duration.stream;
  @override
  Stream<bool> get completedStream => _completed.stream;

  @override
  Future<void> dispose() async {
    await _playing.close();
    await _position.close();
    await _duration.close();
    await _completed.close();
  }
}

class _NoFfmpeg extends FfmpegService {
  @override
  Future<bool> get available async => false;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late _FakePlayer player;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'defaults_seeded_v4': true,
      'terms_accepted_version_v1': kTermsVersion,
    });
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    MetadataService.instance = MetadataService(
      apiKeyProvider: () async => '',
      postersDirProvider: () async => Directory.systemTemp,
    );
    final dlDir = Directory.systemTemp.createTempSync('wi-playlist');
    addTearDown(() => dlDir.deleteSync(recursive: true));
    DownloadManager.instance = DownloadManager(directory: dlDir);
    ConnectivityMonitor.instance = ConnectivityMonitor(
        probe: () async => ClientHealth(state: 'ready', peers: 5));
    FavouritesStore.instance = FavouritesStore();
    WatchStateStore.instance = WatchStateStore();
    player = _FakePlayer();
  });

  Future<void> seed() => LibraryStore.save([
        MediaList(
            id: 'm',
            title: 'Music',
            entries: [_track(1, 'One'), _track(2, 'Two'), _track(3, 'Three')]),
        MediaList(
            id: 'p',
            title: 'Good Energy',
            kind: kListKindPlaylist,
            entries: [_track(2, 'Two'), _track(1, 'One')]),
      ]);

  Future<void> pumpPlaylist(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => PlaylistScreen(
                        playlistId: 'p',
                        playerFactory: () => player,
                        sourceOverride: (e) =>
                            (url: 'fake://${e.address}', local: true),
                      ))),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'playlist page: ordered rows, Play all runs the queue in playlist '
      'order, completion advances', (tester) async {
    await seed();
    await pumpPlaylist(tester);

    expect(find.text('Playlist · 2 tracks'), findsOneWidget);
    // Playlist order (Two before One), not album order.
    final twoY = tester.getTopLeft(find.text('Two')).dy;
    final oneY = tester.getTopLeft(find.text('One')).dy;
    expect(twoY, lessThan(oneY));

    await tester.tap(find.text('Play all'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(player.opened, ['fake://${_addr(2)}']);

    player.completeTrack();
    await tester.pump(const Duration(milliseconds: 100));
    expect(player.opened, ['fake://${_addr(2)}', 'fake://${_addr(1)}']);
    // Transport is on show.
    expect(find.byIcon(Icons.skip_next), findsOneWidget);
  });

  testWidgets('drag-reorder persists the order AND stamps orderedAt for '
      'order sync; removal keeps the stamp', (tester) async {
    await seed();
    await pumpPlaylist(tester);

    // Drag the first row (Two) below the second (One) by its handle —
    // stepped moves with pumps in between so the reorder logic sees the
    // crossing; total distance = 1.5× the real row spacing.
    final rowGap = tester.getTopLeft(find.text('One')).dy -
        tester.getTopLeft(find.text('Two')).dy;
    final handle = find.byIcon(Icons.drag_indicator).first;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 100));
    for (var i = 0; i < 3; i++) {
      await gesture.moveBy(Offset(0, rowGap / 2));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    var pl = (await LibraryStore.load()).firstWhere((l) => l.id == 'p');
    expect([for (final e in pl.entries) e.address], [_addr(1), _addr(2)]);
    final stamp = pl.orderedAt;
    expect(stamp, isNotNull);

    // Removing a track never re-stamps — the remaining rows' relative
    // order is unchanged and a newer remote reorder must stay adoptable.
    await tester.tap(find.byTooltip('Track menu').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from playlist'));
    await tester.pumpAndSettle();
    pl = (await LibraryStore.load()).firstWhere((l) => l.id == 'p');
    expect(pl.entries, hasLength(1));
    expect(pl.orderedAt, stamp);
  });

  testWidgets('row menu: Remove from playlist keeps the track in the '
      'library', (tester) async {
    await seed();
    await pumpPlaylist(tester);

    await tester.tap(find.byTooltip('Track menu').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from playlist'));
    await tester.pumpAndSettle();

    expect(find.text('Playlist · 1 track'), findsOneWidget);
    final lists = await LibraryStore.load();
    expect(lists.firstWhere((l) => l.id == 'p').entries.length, 1);
    // The library list is untouched.
    expect(lists.firstWhere((l) => l.id == 'm').entries.length, 3);
  });

  testWidgets('app-bar menu renames and deletes the playlist',
      (tester) async {
    await seed();
    await pumpPlaylist(tester);

    await tester.tap(find.byTooltip('Playlist menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename playlist'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Better Energy');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Better Energy'), findsOneWidget);

    await tester.tap(find.byTooltip('Playlist menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete playlist'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    // Back on the launcher; the playlist is gone from the store.
    expect(find.text('open'), findsOneWidget);
    final lists = await LibraryStore.load();
    expect(lists.any((l) => l.isPlaylist), isFalse);
  });

  testWidgets('Add media offers library titles not already here',
      (tester) async {
    await seed();
    await pumpPlaylist(tester);

    await tester.tap(find.text('Add media'));
    await tester.pumpAndSettle();
    // Tracks One and Two are already in the playlist — only Three left.
    expect(find.byType(CheckboxListTile), findsOneWidget);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(find.text('Playlist · 3 tracks'), findsOneWidget);
    final lists = await LibraryStore.load();
    expect(lists.firstWhere((l) => l.id == 'p').entries.length, 3);
  });

  testWidgets('drawer: Playlists section below Library, tile opens the '
      'playlist page', (tester) async {
    await seed();
    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Browse lists'));
    await tester.pumpAndSettle();
    final drawer = find.byType(WiLibraryDrawer);
    final header =
        find.descendant(of: drawer, matching: find.text('Playlists'));
    expect(header, findsOneWidget);
    final tile =
        find.descendant(of: drawer, matching: find.text('Good Energy'));
    expect(tile, findsOneWidget);
    // Below the Library section header.
    final libraryY = tester.getTopLeft(
        find.descendant(of: drawer, matching: find.text('Library'))).dy;
    expect(tester.getTopLeft(header).dy, greaterThan(libraryY));
    expect(
        find.descendant(of: drawer, matching: find.text('New playlist')),
        findsOneWidget);

    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.byType(PlaylistScreen), findsOneWidget);

    // And the playlist is NOT a wall shelf: back on home there is no
    // Good Energy row.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Good Energy'), findsNothing);
  });

  testWidgets(
      'needs sorting: select all → move to album previews the renames '
      'and applies them', (tester) async {
    await LibraryStore.save([
      MediaList(id: 'm', title: 'Music', entries: [
        _track(1, 'One'),
        _mix(11, 'trk_a_final.mp3'),
        _mix(12, 'trk_b_final.mp3'),
      ]),
    ]);
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: const NeedsSortingScreen(),
    ));
    await tester.pumpAndSettle();

    expect(find.text('2 unsorted audio files'), findsOneWidget);
    await tester.tap(find.byTooltip('Select all'));
    await tester.pump();
    await tester.tap(find.text('Move 2 to album…'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Artist'), 'Neat Artist');
    await tester.enterText(
        find.widgetWithText(TextField, 'Album'), 'Neat Album');
    await tester.enterText(
        find.widgetWithText(TextField, 'Year (optional)'), '2020');
    await tester.tap(find.text('Preview new names'));
    await tester.pumpAndSettle();

    // Numbers continue after the album's existing track 01.
    expect(find.text('→  Neat Artist - Neat Album (2020) - 02 trk a final.mp3'),
        findsOneWidget);
    expect(find.text('→  Neat Artist - Neat Album (2020) - 03 trk b final.mp3'),
        findsOneWidget);
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    // Everything sorted now; the store holds the renamed entries.
    expect(find.textContaining('Nothing needs sorting'), findsOneWidget);
    final names = [
      for (final e in (await LibraryStore.load()).single.entries) e.name,
    ];
    expect(names,
        contains('Neat Artist - Neat Album (2020) - 02 trk a final.mp3'));
  });

  testWidgets(
      'needs sorting: Add to playlist creates a new playlist on the fly',
      (tester) async {
    await LibraryStore.save([
      MediaList(id: 'm', title: 'Music', entries: [
        _mix(11, 'summer megamix.mp3'),
      ]),
    ]);
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: const NeedsSortingScreen(),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.text('Add to playlist…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New playlist…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Mixes');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Added 1 item to "Mixes".'), findsOneWidget);
    final lists = await LibraryStore.load();
    final playlist = lists.firstWhere((l) => l.isPlaylist);
    expect(playlist.title, 'Mixes');
    expect(playlist.entries.single.address, _addr(11));
  });

  testWidgets(
      'editor: an unsorted audio file gains the organize fields; Save '
      'renames it into the album', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await LibraryStore.save([
      MediaList(id: 'm', title: 'Music', entries: [
        _mix(11, 'mystery tune.mp3'),
      ]),
    ]);
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: EditDetailsScreen(
        entry: _mix(11, 'mystery tune.mp3'),
        ffmpeg: _NoFfmpeg(),
        postersDirProvider: () async => Directory.systemTemp,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('MOVE INTO AN ALBUM'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Artist'), 'Neat Artist');
    await tester.enterText(
        find.widgetWithText(TextField, 'Album'), 'Neat Album');
    await tester.enterText(
        find.widgetWithText(TextField, 'Year (optional)'), '2020');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final entry = (await LibraryStore.load()).single.entries.single;
    expect(entry.name,
        'Neat Artist - Neat Album (2020) - 01 mystery tune.mp3');
    expect(entry.renamedAt, isNotNull);
  });

  group('movie playlists (2026-09-12)', () {
    MediaEntry movie(int n, String title) =>
        MediaEntry(name: '$title (2021).mp4', address: _addr(n));

    Future<void> seedMixed() => LibraryStore.save([
          MediaList(id: 'm', title: 'Music', entries: [_track(1, 'One')]),
          MediaList(
              id: 'v',
              title: 'Movies',
              entries: [movie(21, 'Midnight Ferry'), movie(22, 'Dust County')]),
          MediaList(
              id: 'p',
              title: 'Marathon',
              kind: kListKindPlaylist,
              entries: [movie(21, 'Midnight Ferry'), _track(1, 'One')]),
        ]);

    Future<({List<MediaEntry?> firsts, List<List<MediaEntry>> orders})>
        pumpMixed(WidgetTester tester) async {
      final firsts = <MediaEntry?>[];
      final orders = <List<MediaEntry>>[];
      await tester.pumpWidget(MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: PlaylistScreen(
          playlistId: 'p',
          playerFactory: () => player,
          sourceOverride: (e) => (url: 'fake://${e.address}', local: true),
          videoLauncherOverride: (first, order) {
            firsts.add(first);
            orders.add(order);
          },
        ),
      ));
      await tester.pumpAndSettle();
      return (firsts: firsts, orders: orders);
    }

    testWidgets(
        'mixed playlist: items wording, video row poster thumb, tap '
        'launches the PlayerScreen marathon from that row', (tester) async {
      await seedMixed();
      final launches = await pumpMixed(tester);

      expect(find.text('Playlist · 2 items'), findsOneWidget);
      // The video row's placeholder thumb carries the movie icon.
      expect(find.byIcon(Icons.movie_outlined), findsWidgets);

      await tester.tap(find.text('Midnight Ferry'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(launches.firsts.single!.address, _addr(21));
      // The whole playlist order rides along for Up-next chaining.
      expect(launches.orders.single.map((e) => e.address),
          [_addr(21), _addr(1)]);
      // The inline audio queue stayed out of it.
      expect(player.opened, isEmpty);
    });

    testWidgets(
        'mixed playlist: an AUDIO row also goes through the marathon '
        '(the inline queue would play the following movie sound-only)',
        (tester) async {
      await seedMixed();
      final launches = await pumpMixed(tester);

      await tester.tap(find.text('One'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(launches.firsts.single!.address, _addr(1));
      expect(player.opened, isEmpty);
    });

    testWidgets('Play all and Shuffle launch the marathon over the '
        'playlist', (tester) async {
      await seedMixed();
      final launches = await pumpMixed(tester);

      await tester.tap(find.text('Play all'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(launches.firsts.single!.address, _addr(21));
      expect(launches.orders.single.map((e) => e.address),
          [_addr(21), _addr(1)]);

      await tester.tap(find.text('Shuffle'));
      await tester.pump(const Duration(milliseconds: 100));
      // A shuffled full pass: both entries, any order.
      expect(launches.orders.last.map((e) => e.address).toSet(),
          {_addr(21), _addr(1)});
      expect(launches.firsts.last!.address,
          launches.orders.last.first.address);
    });

    testWidgets(
        'Add media picker offers video with type chips; adding a movie '
        'flips an audio playlist to items wording', (tester) async {
      await LibraryStore.save([
        MediaList(id: 'm', title: 'Music', entries: [_track(1, 'One')]),
        MediaList(
            id: 'v', title: 'Movies', entries: [movie(21, 'Midnight Ferry')]),
        MediaList(
            id: 'p',
            title: 'Good Energy',
            kind: kListKindPlaylist,
            entries: const []),
      ]);
      await tester.pumpWidget(MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: PlaylistScreen(
          playlistId: 'p',
          playerFactory: () => player,
          sourceOverride: (e) => (url: 'fake://${e.address}', local: true),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add media'));
      await tester.pumpAndSettle();
      // Mixed pool → chips; Movies narrows to the movie.
      expect(find.text('Music'), findsOneWidget);
      await tester.tap(find.text('Movies'));
      await tester.pumpAndSettle();
      expect(find.byType(CheckboxListTile), findsOneWidget);
      expect(find.text('Midnight Ferry'), findsOneWidget);
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(find.text('Playlist · 1 item'), findsOneWidget);
      final lists = await LibraryStore.load();
      expect(lists.firstWhere((l) => l.id == 'p').entries.single.address,
          _addr(21));
    });

    testWidgets('detail page: Add to playlist is offered on video too',
        (tester) async {
      await seedMixed();
      await tester.pumpWidget(MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: DetailScreen(entry: movie(22, 'Dust County')),
      ));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Add to playlist'), findsOneWidget);
      await tester.tap(find.byTooltip('Add to playlist'));
      await tester.pumpAndSettle();
      // The picker lists the mixed playlist with its content icon.
      expect(find.text('Marathon'), findsOneWidget);
      expect(find.byIcon(Icons.playlist_play), findsOneWidget);
      await tester.tap(find.text('Marathon'));
      await tester.pumpAndSettle();
      expect(find.text('Added 1 item to "Marathon".'), findsOneWidget);
      final lists = await LibraryStore.load();
      expect(
          lists
              .firstWhere((l) => l.id == 'p')
              .entries
              .map((e) => e.address),
          contains(_addr(22)));
    });

    testWidgets('drawer: playlist icons derive from content',
        (tester) async {
      await seedMixed();
      await tester.pumpWidget(const WatchItApp());
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Browse lists'));
      await tester.pumpAndSettle();
      final drawer = find.byType(WiLibraryDrawer);
      // Mixed playlist → playlist_play icon on its row.
      final row = find.ancestor(
          of: find.descendant(
              of: drawer, matching: find.text('Marathon')),
          matching: find.byType(ListTile));
      expect(
          find.descendant(
              of: row, matching: find.byIcon(Icons.playlist_play)),
          findsOneWidget);
    });
  });

  testWidgets('editor: artist without album refuses with a clear message',
      (tester) async {
    // The organize fields sit below the artwork/title blocks — a taller
    // window keeps the whole ListView built (offstage children are
    // never laid out, so finders would miss them).
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await LibraryStore.save([
      MediaList(id: 'm', title: 'Music', entries: [
        _mix(11, 'mystery tune.mp3'),
      ]),
    ]);
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: EditDetailsScreen(
        entry: _mix(11, 'mystery tune.mp3'),
        ffmpeg: _NoFfmpeg(),
        postersDirProvider: () async => Directory.systemTemp,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Artist'), 'Neat Artist');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.textContaining('fill in BOTH'), findsOneWidget);
    // Nothing renamed.
    final entry = (await LibraryStore.load()).single.entries.single;
    expect(entry.name, 'mystery tune.mp3');
  });
}
