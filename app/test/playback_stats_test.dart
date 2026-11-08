import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/playback_stats.dart';

// The `I`-key playback-statistics overlay: the row formatter is pure over a
// property→string map (what mpv answers), and the widget polls a reader
// seam, so both are pinned without a real player.
void main() {
  group('playbackStatsRows', () {
    test('formats a healthy software-decoded 1080p stream', () {
      final rows = playbackStatsRows({
        'video-codec': 'h264 (High)',
        'hwdec-current': 'no',
        'video-params/w': '1920',
        'video-params/h': '1080',
        'container-fps': '29.970030',
        'estimated-vf-fps': '29.968',
        'decoder-frame-drop-count': '0',
        'frame-drop-count': '3',
        'demuxer-cache-duration': '42.345000',
        'video-bitrate': '5234123',
        'audio-codec-name': 'aac',
      });
      final byLabel = {for (final r in rows) r.label: r.value};
      expect(byLabel['Video'], 'h264 (High) · 1920×1080');
      expect(byLabel['Rate'], '29.97 fps · playing 29.97 fps');
      expect(byLabel['Decoder'], 'software');
      expect(byLabel['Dropped'], 'decoder 0 · output 3');
      expect(byLabel['Buffered'], '42.3 s ahead · 5.2 Mb/s');
      expect(byLabel['Audio'], 'aac');
    });

    test('names the hardware decoder and tolerates missing properties', () {
      final rows = playbackStatsRows({
        'hwdec-current': 'vaapi',
        'video-params/w': '1280',
        // height, fps, counters, cache all absent (null / empty).
        'container-fps': '',
        'decoder-frame-drop-count': null,
      });
      final byLabel = {for (final r in rows) r.label: r.value};
      expect(byLabel['Decoder'], 'hardware (vaapi)');
      expect(byLabel['Video'], '— · —');
      expect(byLabel['Rate'], '— · playing —');
      expect(byLabel['Dropped'], 'decoder — · output —');
      expect(byLabel['Buffered'], '— ahead · —');
      expect(byLabel['Audio'], '—');
    });

    test('audio falls back to the long codec name', () {
      final rows = playbackStatsRows({
        'audio-codec': 'AAC (Advanced Audio Coding)',
      });
      expect(
        rows.firstWhere((r) => r.label == 'Audio').value,
        'AAC (Advanced Audio Coding)',
      );
    });

    test('an unanswered decoder property reads as unknown, not software', () {
      final rows = playbackStatsRows(const {});
      expect(rows.firstWhere((r) => r.label == 'Decoder').value, '—');
    });
  });

  test(
    'readPlaybackStats batches every property and survives throws',
    () async {
      final asked = <String>[];
      final props = await readPlaybackStats((p) async {
        asked.add(p);
        if (p == 'hwdec-current') throw StateError('disposed');
        return p == 'video-params/w' ? '640' : null;
      });
      expect(asked.toSet(), kPlaybackStatsProperties.toSet());
      expect(props['video-params/w'], '640');
      expect(props['hwdec-current'], isNull);
      expect(props.length, kPlaybackStatsProperties.length);
    },
  );

  testWidgets('overlay renders the rows and re-polls on its interval', (
    tester,
  ) async {
    var polls = 0;
    var dropped = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: Scaffold(
          body: PlaybackStatsOverlay(
            interval: const Duration(seconds: 1),
            read: (p) async {
              if (p == 'video-codec') polls++;
              if (p == 'decoder-frame-drop-count') return '${dropped++}';
              if (p == 'hwdec-current') return 'nvdec';
              return null;
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('PLAYBACK STATS'), findsOneWidget);
    expect(find.text('hardware (nvdec)'), findsOneWidget);
    expect(find.textContaining('decoder 0 ·'), findsOneWidget);
    expect(polls, 1);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(polls, 2);
    expect(find.textContaining('decoder 1 ·'), findsOneWidget);

    // Disposing stops the timer (no pending-timer complaint from the test).
    await tester.pumpWidget(const SizedBox());
  });
}
