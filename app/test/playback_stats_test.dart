import 'dart:ui' show FrameTiming;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
        'avsync': '0.0123',
        'demuxer-cache-duration': '42.345000',
        'video-bitrate': '5234123',
        'audio-codec-name': 'aac',
      });
      final byLabel = {for (final r in rows) r.label: r.value};
      expect(byLabel['Video'], 'h264 (High) · 1920×1080');
      expect(byLabel['Rate'], '29.97 fps · playing 29.97 fps');
      expect(byLabel['Decoder'], 'software');
      expect(byLabel['Dropped'], 'decoder 0 · output 3');
      expect(byLabel['A/V sync'], '+12.3 ms');
      expect(byLabel['Buffered'], '42.3 s ahead · 5.2 Mb/s');
      expect(byLabel['Audio'], 'aac');
      // No frame summary passed → no Flutter row.
      expect(byLabel.containsKey('Flutter'), isFalse);
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
      expect(byLabel['A/V sync'], '—');
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

  // Helper: a FrameTiming whose vsync starts at [startUs] with the given
  // build/raster lengths (microseconds). FrameTiming's constructor takes
  // the raw phase timestamps, so synthetic frames are cheap to pin.
  FrameTiming frame(int startUs, {int buildUs = 2000, int rasterUs = 4000}) =>
      FrameTiming(
        vsyncStart: startUs,
        buildStart: startUs + 100,
        buildFinish: startUs + 100 + buildUs,
        rasterStart: startUs + 200 + buildUs,
        rasterFinish: startUs + 200 + buildUs + rasterUs,
        rasterFinishWallTime: startUs + 200 + buildUs + rasterUs,
        frameNumber: startUs ~/ 1000,
      );

  group('summarizeFrameTimings', () {
    test('summarizes only the recent window, counting over-budget frames', () {
      // 30 fps worth of frames over 3 s; the last 2 s hold 60 of them,
      // one of which overruns the 16.7 ms budget with a 40 ms raster.
      final timings = [
        for (var i = 0; i < 90; i++)
          frame(i * 33333, rasterUs: i == 80 ? 40000 : 4000),
      ];
      final s = summarizeFrameTimings(timings);
      expect(s.frames, inInclusiveRange(59, 61));
      expect(s.fps, closeTo(30, 0.6));
      expect(s.rasterMaxMs, 40);
      expect(s.rasterAvgMs, closeTo(4.6, 0.1));
      expect(s.overBudget, 1);
      expect(s.describe(), contains('fps · raster'));
      expect(s.describe(), endsWith('1 over 16.7 ms'));
    });

    test('empty input reads as a dash', () {
      final s = summarizeFrameTimings(const []);
      expect(s.frames, 0);
      expect(s.describe(), '—');
      expect(playbackStatsRows(const {}, frames: s).last.value, '—');
    });

    test('the sampler keeps only the newest frames', () {
      final sampler = FlutterFrameSampler(capacity: 3);
      sampler.add([frame(0), frame(1000), frame(2000), frame(3000)]);
      expect(sampler.timings.length, 3);
      expect(sampler.timings.first.frameNumber, 1);
    });
  });

  test('playbackStatsReport carries rows, environment and raw properties', () {
    final text = playbackStatsReport(
      rows: const [(label: 'Video', value: 'h264 · 1920×1080')],
      environment: const {'App': 'v0.1.0-alpha.129', 'Display': '60 Hz'},
      raw: const {'avsync': '0.01', 'display-fps': null},
      now: DateTime.utc(2026, 11, 8, 12),
    );
    expect(text, startsWith('W@tch playback stats — 2026-11-08T12:00:00.000Z'));
    expect(text, contains('\nVideo: h264 · 1920×1080\n'));
    expect(text, contains('-- environment --\nApp: v0.1.0-alpha.129\nDisplay: 60 Hz'));
    expect(text, contains('-- mpv --\navsync=0.01\ndisplay-fps=(unavailable)'));
    expect(text, isNot(endsWith('\n')));
  });

  testWidgets('tapping the card copies the full report and confirms', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    final sampler = FlutterFrameSampler()
      ..add([for (var i = 0; i < 30; i++) frame(i * 33333)]);
    await tester.pumpWidget(
      MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: Scaffold(
          body: PlaybackStatsOverlay(
            read: (p) async => p == 'hwdec-current' ? 'vaapi' : null,
            environment: const {'Flutter renderer': 'skia'},
            frameSampler: sampler,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('tap to copy for a report'), findsOneWidget);
    expect(find.textContaining('fps · raster'), findsOneWidget);

    await tester.tap(find.text('PLAYBACK STATS'));
    await tester.pump();
    expect(copied, isNotNull);
    expect(copied, contains('Decoder: hardware (vaapi)'));
    expect(copied, contains('Flutter renderer: skia'));
    expect(copied, contains('hwdec-current=vaapi'));
    expect(copied, contains('Flutter: '));
    expect(find.text('Copied to clipboard'), findsOneWidget);
    expect(find.text('Playback stats copied to the clipboard'), findsOneWidget);

    // The confirmation reverts after two seconds.
    await tester.pump(const Duration(seconds: 2, milliseconds: 100));
    expect(find.text('tap to copy for a report'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
