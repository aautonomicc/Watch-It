import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/screens/player_screen.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/theme/tokens.dart';

/// PlayerScreen's audio layout ([AudioPlayerView]) — the surface music
/// gets instead of a black Video widget. PlayerScreen itself needs
/// native libmpv, so the view is pinned standalone with fake state.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final track = MediaEntry(
    name: 'Singer - Album (2001) - 01 Song One.mp3',
    address: '1'.padLeft(64, '0'),
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    MetadataService.instance = MetadataService(apiKeyProvider: () async => '');
  });

  Future<void> pumpView(
    WidgetTester tester, {
    Duration position = const Duration(seconds: 30),
    Duration duration = const Duration(minutes: 3),
    bool playing = true,
    VoidCallback? onPlayPause,
    ValueChanged<Duration>? onSeek,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: AudioPlayerView(
          entry: track,
          position: position,
          duration: duration,
          playing: playing,
          onPlayPause: onPlayPause ?? () {},
          onSeek: onSeek ?? (_) {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('shows track title, credit, artwork slot, and transport',
      (tester) async {
    await pumpView(tester);

    // Track name from the file name, not the album title.
    expect(find.text('Song One'), findsOneWidget);
    expect(find.text('Singer · Album'), findsOneWidget);
    // No artwork cached — the music-note placeholder fills the square.
    expect(find.byIcon(Icons.music_note), findsOneWidget);
    // Transport: seek bar, skips, pause (it is playing).
    expect(find.byType(Slider), findsOneWidget);
    expect(find.byIcon(Icons.replay_10), findsOneWidget);
    expect(find.byIcon(Icons.forward_30), findsOneWidget);
    expect(find.byIcon(Icons.pause), findsOneWidget);
    // No video frame-capture button in audio mode.
    expect(find.byIcon(Icons.photo_camera_outlined), findsNothing);
    // Clocks.
    expect(find.text('0:30'), findsOneWidget);
    expect(find.text('3:00'), findsOneWidget);
  });

  testWidgets('paused shows play; tap forwards to onPlayPause',
      (tester) async {
    var taps = 0;
    await pumpView(tester, playing: false, onPlayPause: () => taps++);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    await tester.tap(find.byIcon(Icons.play_arrow));
    expect(taps, 1);
  });

  testWidgets('skip buttons seek relative and clamp to the track',
      (tester) async {
    final seeks = <Duration>[];
    await pumpView(tester,
        position: const Duration(seconds: 5),
        duration: const Duration(seconds: 20),
        onSeek: seeks.add);

    // Back 10 from 0:05 clamps to the start.
    await tester.tap(find.byIcon(Icons.replay_10));
    expect(seeks, [Duration.zero]);
    // Forward 30 from 0:05 clamps to the 20s end.
    await tester.tap(find.byIcon(Icons.forward_30));
    expect(seeks.last, const Duration(seconds: 20));
  });

  testWidgets('unknown duration disables the seek bar', (tester) async {
    await pumpView(tester, duration: Duration.zero);
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.onChanged, isNull);
  });
}
