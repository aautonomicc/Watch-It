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
      expect(byLabel.containsKey('UI frames'), isFalse);
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
      // The detail line: build / vsync wait / whole span, and the frame
      // count inside the window.
      expect(s.buildAvgMs, closeTo(2.0, 0.01));
      expect(s.buildMaxMs, closeTo(2.0, 0.01));
      expect(s.vsyncWaitAvgMs, closeTo(0.1, 0.01));
      expect(s.spanMaxMs, closeTo(42.2, 0.01));
      expect(s.spanAvgMs, closeTo(6.8, 0.1));
      expect(s.describeDetail(), startsWith('${s.frames} in 2 s · build 2.0 avg / 2.0 max · wait 0.1 avg · span'));
      final rows = playbackStatsRows(const {}, frames: s);
      expect(rows.last.label, 'UI detail');
      expect(rows.last.value, s.describeDetail());
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

  group('renderPipelineRows', () {
    final t0 = DateTime.utc(2026, 11, 8, 17);
    const facts = {
      'hardware': true,
      'composited': true,
      'backend': 'x11',
      'scale_factor': 2,
      'gl_vendor': 'NVIDIA Corporation',
      'gl_renderer': 'NVIDIA GeForce RTX 3080/PCIe/SSE2',
      'gl_version': 'OpenGL ES 3.2 NVIDIA 550.120',
      'egl_vendor': 'NVIDIA',
      'egl_version': '1.5',
      'update_via_main': false,
      'sw_forced': false,
    };
    NativeRenderSnapshot snap(
      int secs, {
      required int updates,
      required int populates,
      required int renderUs,
      required int populateUs,
      required int ticks,
      required int draws,
      int refreshUs = 16667,
      int? paints,
      int paintUs = 0,
      int paintUsMax = 0,
    }) =>
        NativeRenderSnapshot({
          ...facts,
          'update_count': updates,
          'populate_count': populates,
          'render_us_total': renderUs,
          'render_us_max': 18000,
          'populate_us_total': populateUs,
          'populate_us_max': 22000,
          'gtk_tick_count': ticks,
          'gtk_draw_count': draws,
          'gtk_paint_count': ?paints,
          if (paints != null) 'gtk_paint_us_total': paintUs,
          if (paints != null) 'gtk_paint_us_max': paintUsMax,
          'gdk_refresh_us': refreshUs,
        }, t0.add(Duration(seconds: secs)));

    test('no snapshot or a counter-less map yields no rows', () {
      expect(renderPipelineRows(null, null), isEmpty);
      expect(
        renderPipelineRows(
          null,
          NativeRenderSnapshot(const {'hardware': true}, t0),
        ),
        isEmpty,
      );
    });

    test('the first snapshot only says measuring', () {
      final rows = renderPipelineRows(
        null,
        snap(0, updates: 10, populates: 2, renderUs: 0, populateUs: 0, ticks: 0, draws: 0),
      );
      expect(rows.single.label, 'Pipeline');
      expect(rows.single.value, 'measuring…');
    });

    test('two snapshots become per-second rates and average times', () {
      // Two seconds apart: mpv signalled 48 frames, Flutter rendered 12 of
      // them (3.2 ms each inside mpv, 5.0 ms whole populate); GTK ticked
      // 120 times but painted only 14.
      final a = snap(0, updates: 100, populates: 50, renderUs: 160000,
          populateUs: 250000, ticks: 600, draws: 70);
      final b = snap(2, updates: 148, populates: 62, renderUs: 198400,
          populateUs: 310000, ticks: 720, draws: 84);
      final rows = renderPipelineRows(a, b);
      final byLabel = {for (final r in rows) r.label: r.value};
      expect(byLabel['Pipeline'],
          'mpv 24.0 frames/s → Flutter 6.0 renders/s · render 3.2 avg / 18.0 max ms · populate 5.0 ms');
      expect(byLabel['GTK'],
          '60.0 ticks/s · 7.0 paints/s · refresh 16.67 ms · composited');
      expect(b.gdkRefreshMs, closeTo(16.667, 0.001));
      final env = b.environment();
      expect(env['GL driver'],
          'NVIDIA Corporation | NVIDIA GeForce RTX 3080/PCIe/SSE2 | OpenGL ES 3.2 NVIDIA 550.120');
      expect(env['EGL'], 'NVIDIA 1.5');
      expect(env['GDK'], 'x11 · composited · scale 2 · refresh 16.67 ms');
      expect(env['Pacing: update-via-main'], '0 (default)');
      expect(env['Pacing: sw-render'], '0 (default)');
    });

    test('an unknown refresh and no populates read as zeros, not NaN', () {
      final a = snap(0, updates: 0, populates: 0, renderUs: 0, populateUs: 0,
          ticks: 0, draws: 0, refreshUs: 0);
      final b = snap(1, updates: 24, populates: 0, renderUs: 0, populateUs: 0,
          ticks: 60, draws: 0, refreshUs: 0);
      final byLabel = {for (final r in renderPipelineRows(a, b)) r.label: r.value};
      expect(byLabel['Pipeline'], startsWith('mpv 24.0 frames/s → Flutter 0.0 renders/s · render 0.0 avg'));
      expect(byLabel['GTK'], '60.0 ticks/s · 0.0 paints/s · composited');
      expect(b.gdkRefreshMs, isNull);
      expect(b.environment()['GDK'], 'x11 · composited · scale 2');
    });

    test('a plugin that times paint phases adds the paint duration', () {
      // 14 paints in two seconds taking 392 ms together = 28 ms each, the
      // worst one 41 ms: a GTK thread blocked for most of each refresh.
      final a = snap(0, updates: 0, populates: 0, renderUs: 0, populateUs: 0,
          ticks: 0, draws: 0, paints: 100, paintUs: 1000000, paintUsMax: 30000);
      final b = snap(2, updates: 48, populates: 40, renderUs: 40000,
          populateUs: 50000, ticks: 120, draws: 14, paints: 114,
          paintUs: 1392000, paintUsMax: 41000);
      final byLabel = {for (final r in renderPipelineRows(a, b)) r.label: r.value};
      expect(byLabel['GTK'],
          '60.0 ticks/s · 7.0 paints/s · paint 28.0 avg / 41.0 max ms · refresh 16.67 ms · composited');
    });
  });

  testWidgets('the overlay polls the render reader and reports its facts', (
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
    var reads = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: Scaffold(
          body: PlaybackStatsOverlay(
            read: (p) async => null,
            // One second of clock per render read — the fake-async zone's
            // wall clock does not advance across pumps.
            now: () => DateTime.utc(2026, 11, 8, 17).add(Duration(seconds: reads)),
            readRender: () async {
              reads++;
              return {
                'hardware': true,
                'update_count': reads * 24,
                'populate_count': reads * 6,
                'render_us_total': reads * 6 * 3000,
                'render_us_max': 9000,
                'populate_us_total': reads * 6 * 4000,
                'populate_us_max': 12000,
                'gtk_tick_count': reads * 60,
                'gtk_draw_count': reads * 7,
                'gdk_refresh_us': 16667,
                'composited': true,
                'backend': 'x11',
                'scale_factor': 2,
                'gl_vendor': 'Mesa',
                'gl_renderer': 'llvmpipe (LLVM 17.0.6, 256 bits)',
                'gl_version': 'OpenGL ES 3.2 Mesa 24.0.9',
                'egl_vendor': 'Mesa Project',
                'egl_version': '1.5',
                'update_via_main': true,
                'sw_forced': false,
              };
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('measuring…'), findsOneWidget);
    expect(find.textContaining('ticks/s'), findsNothing);

    // The overlay's own tick timer fires at the default 1 s interval; the
    // second snapshot turns the counters into rates.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(reads, 2);
    expect(find.textContaining('frames/s → Flutter'), findsOneWidget);
    expect(find.textContaining('ticks/s'), findsOneWidget);

    await tester.tap(find.text('PLAYBACK STATS'));
    await tester.pump();
    expect(copied, contains('GL driver: Mesa | llvmpipe (LLVM 17.0.6, 256 bits) | OpenGL ES 3.2 Mesa 24.0.9'));
    expect(copied, contains('GDK: x11 · composited · scale 2 · refresh 16.67 ms'));
    expect(copied, contains('Pacing: update-via-main: 1'));
    expect(copied, contains('Pipeline: mpv 24.0 frames/s → Flutter 6.0 renders/s'));
    await tester.pumpWidget(const SizedBox());
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
    expect(copied, contains('UI frames: '));
    expect(find.text('Copied to clipboard'), findsOneWidget);
    expect(find.text('Playback stats copied to the clipboard'), findsOneWidget);

    // The confirmation reverts after two seconds.
    await tester.pump(const Duration(seconds: 2, milliseconds: 100));
    expect(find.text('tap to copy for a report'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
