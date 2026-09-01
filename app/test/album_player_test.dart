import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/screens/album_screen.dart';
import 'package:watchit/screens/detail_screen.dart';
import 'package:watchit/services/connectivity.dart';
import 'package:watchit/services/download_manager.dart';
import 'package:watchit/services/embedded_client.dart';
import 'package:watchit/services/favourites.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/services/season_grouping.dart';
import 'package:watchit/theme/tokens.dart';

/// The album page's inline player: tap-to-play, transport controls,
/// auto-advance, shuffle, and the favourite heart — against a fake
/// audio player (no native libmpv in widget tests).
const _mbid = 'c07f0676-9d95-4443-a841-b1cbcfa48f4e';

String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

MediaEntry _track(int n, String title) => MediaEntry(
      name: 'The Rolling Stones - Let It Bleed (1969) - '
          '${n.toString().padLeft(2, '0')} $title {mbid-$_mbid}.flac',
      address: _addr(n),
    );

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

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late _FakePlayer player;
  late HomeAlbum album;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    MetadataService.instance = MetadataService(apiKeyProvider: () async => '');
    final dlDir = Directory.systemTemp.createTempSync('wi-albumplay');
    addTearDown(() => dlDir.deleteSync(recursive: true));
    DownloadManager.instance = DownloadManager(directory: dlDir);
    ConnectivityMonitor.instance = ConnectivityMonitor(
        probe: () async => ClientHealth(state: 'ready', peers: 5));
    FavouritesStore.instance = FavouritesStore();
    player = _FakePlayer();
    album = groupShows([
      _track(1, 'Gimme Shelter'),
      _track(2, 'Love In Vain'),
      _track(3, 'Country Honk'),
    ]).single as HomeAlbum;
  });

  Future<void> pumpAlbum(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: AlbumScreen(
        group: album,
        playerFactory: () => player,
        // Local sources: no embedded client, no cellular gating.
        sourceOverride: (e) => (url: 'fake://${e.address}', local: true),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('tapping a track plays it inline with transport controls',
      (tester) async {
    await pumpAlbum(tester);
    // No controls before anything plays — just the Play album button.
    expect(find.text('Play album'), findsOneWidget);
    expect(find.byIcon(Icons.skip_next), findsNothing);

    await tester.tap(find.text('Love In Vain'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(player.opened, ['fake://${_addr(2)}']);
    // Transport row: shuffle, previous, pause (playing), next, heart.
    expect(find.byIcon(Icons.shuffle), findsOneWidget);
    expect(find.byIcon(Icons.skip_previous), findsOneWidget);
    expect(find.byIcon(Icons.pause), findsOneWidget);
    expect(find.byIcon(Icons.skip_next), findsOneWidget);
    expect(find.byIcon(Icons.favorite_border), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    // The playing row is marked; no navigation happened.
    expect(find.byIcon(Icons.graphic_eq), findsOneWidget);
    expect(find.byType(DetailScreen), findsNothing);
    // Play album is folded away while something plays.
    expect(find.text('Play album'), findsNothing);
  });

  testWidgets('play/pause toggles; next and completion advance in order',
      (tester) async {
    await pumpAlbum(tester);
    await tester.tap(find.text('Gimme Shelter'));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byIcon(Icons.pause));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);

    await tester.tap(find.byIcon(Icons.skip_next));
    await tester.pump(const Duration(milliseconds: 100));
    expect(player.opened.last, 'fake://${_addr(2)}');

    player.completeTrack();
    await tester.pump(const Duration(milliseconds: 100));
    expect(player.opened.last, 'fake://${_addr(3)}');

    // Last track done — the album ends instead of looping.
    player.completeTrack();
    await tester.pump(const Duration(milliseconds: 100));
    expect(player.opened.length, 3);
  });

  testWidgets('shuffle visits every track once', (tester) async {
    await pumpAlbum(tester);
    await tester.tap(find.text('Play album'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byIcon(Icons.shuffle));
    await tester.pump(const Duration(milliseconds: 100));

    player.completeTrack();
    await tester.pump(const Duration(milliseconds: 100));
    player.completeTrack();
    await tester.pump(const Duration(milliseconds: 100));
    player.completeTrack();
    await tester.pump(const Duration(milliseconds: 100));

    // Three plays, no repeats, then silence.
    expect(player.opened.length, 3);
    expect(player.opened.toSet().length, 3);
  });

  testWidgets('heart favourites the playing track', (tester) async {
    await pumpAlbum(tester);
    await tester.tap(find.text('Country Honk'));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byIcon(Icons.favorite_border));
    await tester.pump(const Duration(milliseconds: 100));
    expect(FavouritesStore.instance.isFavourite(_addr(3)), isTrue);
    expect(find.byIcon(Icons.favorite), findsOneWidget);
  });

  testWidgets('the ⓘ button opens the track detail page', (tester) async {
    await pumpAlbum(tester);
    await tester.tap(find.byIcon(Icons.info_outline).first);
    await tester.pumpAndSettle();
    expect(find.byType(DetailScreen), findsOneWidget);
    // Nothing started playing.
    expect(player.opened, isEmpty);
  });
}
