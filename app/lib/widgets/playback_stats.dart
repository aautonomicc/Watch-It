import 'dart:async';
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';

/// Reads one mpv property by name; null when the player can't answer
/// (not initialised yet, disposed, property unknown on this build).
typedef MpvPropertyReader = Future<String?> Function(String property);

/// The mpv properties the overlay polls each tick, in one batch.
const kPlaybackStatsProperties = <String>[
  'video-codec',
  'hwdec-current',
  'video-params/w',
  'video-params/h',
  'container-fps',
  'estimated-vf-fps',
  'decoder-frame-drop-count',
  'frame-drop-count',
  'avsync',
  'demuxer-cache-duration',
  'video-bitrate',
  'audio-codec-name',
  'audio-codec',
  'video-sync',
  'display-fps',
];

/// One overlay row: a short label and its value.
typedef PlaybackStatsRow = ({String label, String value});

/// Formats a batch of mpv property strings into the overlay's rows. Pure —
/// what the player answers is a map of property → raw string (null/empty
/// when unavailable), so this stays unit-testable without a player.
///
/// The two drop counters are the ones that matter under the audio-synced
/// timing W@tch runs (`video-sync=audio` — mpv's display-sync-only counters
/// such as `vo-delayed-frame-count`/`mistimed-frame-count` stay blank or 0
/// there, so they are deliberately not shown): `decoder-frame-drop-count`
/// = frames the DECODER dropped (CPU/decoder too slow — hardware decoding
/// or a smaller version helps), `frame-drop-count` = decoded frames the
/// OUTPUT skipped because they were late (GPU / rendering path too slow —
/// the S/W-rendering fallback shows here). mpv's naming is the trap: the
/// bare `frame-drop-count` is the VO counter (verified in 0.37 command.c).
/// Both idle at 0 on a healthy desktop; a steadily climbing one names the
/// bottleneck. `avsync` (audio/video offset, works under video-sync=audio)
/// is the third signal: a drifting or large value means frames are shown
/// off their audio time even when nothing is dropped — the pacing class.
List<PlaybackStatsRow> playbackStatsRows(
  Map<String, String?> props, {
  FlutterFrameSummary? frames,
}) {
  String raw(String key) => (props[key] ?? '').trim();
  String or(String key, String fallback) {
    final v = raw(key);
    return v.isEmpty ? fallback : v;
  }

  double? num(String key) => double.tryParse(raw(key));
  String fps(String key) {
    final v = num(key);
    return v == null ? '—' : '${v.toStringAsFixed(2)} fps';
  }

  final w = raw('video-params/w');
  final h = raw('video-params/h');
  final size = (w.isEmpty || h.isEmpty) ? '—' : '$w×$h';
  final containerFps = fps('container-fps');
  final measuredFps = fps('estimated-vf-fps');

  final hwdec = raw('hwdec-current');
  final String decoder;
  if (hwdec.isEmpty) {
    decoder = '—';
  } else if (hwdec == 'no' || hwdec == 'none') {
    decoder = 'software';
  } else {
    decoder = 'hardware ($hwdec)';
  }

  String count(String key) => or(key, '—');

  final avsync = num('avsync');
  final sync = avsync == null
      ? '—'
      : '${avsync >= 0 ? '+' : ''}${(avsync * 1000).toStringAsFixed(1)} ms';

  final cacheSecs = num('demuxer-cache-duration');
  final cache = cacheSecs == null ? '—' : '${cacheSecs.toStringAsFixed(1)} s';
  final bitrate = num('video-bitrate');
  final rate = bitrate == null
      ? '—'
      : '${(bitrate / 1e6).toStringAsFixed(1)} Mb/s';

  return [
    (label: 'Video', value: '${or('video-codec', '—')} · $size'),
    (label: 'Rate', value: '$containerFps · playing $measuredFps'),
    (label: 'Decoder', value: decoder),
    (
      label: 'Dropped',
      value:
          'decoder ${count('decoder-frame-drop-count')} · '
          'output ${count('frame-drop-count')}',
    ),
    (label: 'A/V sync', value: sync),
    (label: 'Buffered', value: '$cache ahead · $rate'),
    // `audio-codec-name` is the short tag; `audio-codec` the long form —
    // whichever this mpv answers (both blank with no audio device).
    (label: 'Audio', value: or('audio-codec-name', or('audio-codec', '—'))),
    // "UI frames" on purpose, not "Flutter fps": FrameTimings only cover
    // frames Dart BUILT. A video texture update re-rasters the last layer
    // tree without a Dart build and never reaches the timings callback, so
    // this row is the widget-rebuild rate (controls, this card's 1 Hz
    // refresh), NOT the video composite rate — that is the Pipeline row's
    // "renders/s". Caught live 2026-11-08: a 30 fps stream rendered 30
    // textures/s while this row read 1.0 fps.
    if (frames != null) (label: 'UI frames', value: frames.describe()),
    if (frames != null && frames.frames > 0)
      (label: 'UI detail', value: frames.describeDetail()),
  ];
}

/// Reads every property in [kPlaybackStatsProperties] through [read] in one
/// batch, tolerating per-property failures.
Future<Map<String, String?>> readPlaybackStats(MpvPropertyReader read) async {
  final values = await Future.wait(
    kPlaybackStatsProperties.map((p) async {
      try {
        return await read(p);
      } catch (_) {
        return null;
      }
    }),
  );
  return {
    for (var i = 0; i < kPlaybackStatsProperties.length; i++)
      kPlaybackStatsProperties[i]: values[i],
  };
}

/// Flutter's UI-frame health over a recent window, built from
/// [FrameTiming]s (SchedulerBinding's timings callback) by
/// [summarizeFrameTimings]. These are the frames Dart BUILT (widget
/// rebuilds: controls, position ticks, this card's own refresh); the
/// engine re-rasters a video-texture update without a Dart build and
/// reports no timing for it, so [fps] here is not the video composite rate
/// (see [renderPipelineRows]). Raster time still matters: a slow raster
/// thread (software rendering, a heavy compositor) delays video frames.
class FlutterFrameSummary {
  const FlutterFrameSummary({
    required this.frames,
    required this.fps,
    required this.rasterAvgMs,
    required this.rasterMaxMs,
    required this.overBudget,
    required this.budgetMs,
    this.buildAvgMs = 0,
    this.buildMaxMs = 0,
    this.vsyncWaitAvgMs = 0,
    this.spanAvgMs = 0,
    this.spanMaxMs = 0,
    this.windowSecs = 2,
  });

  /// Frames composited inside the window.
  final int frames;

  /// Frames per second over the window (0 when fewer than two frames).
  final double fps;
  final double rasterAvgMs;
  final double rasterMaxMs;

  /// Frames whose vsync-to-raster-finish span exceeded [budgetMs].
  final int overBudget;
  final double budgetMs;

  /// UI-thread build time (Dart widget build + layout + paint recording).
  final double buildAvgMs;
  final double buildMaxMs;

  /// Time between the vsync signal and the build starting — a UI thread
  /// that is busy with other Dart work shows up here.
  final double vsyncWaitAvgMs;

  /// Whole vsync-to-raster-finish span.
  final double spanAvgMs;
  final double spanMaxMs;
  final double windowSecs;

  String describe() {
    if (frames == 0) return '—';
    return '${fps.toStringAsFixed(1)} fps · raster '
        '${rasterAvgMs.toStringAsFixed(1)} avg / '
        '${rasterMaxMs.toStringAsFixed(1)} max ms · '
        '$overBudget over ${budgetMs.toStringAsFixed(1)} ms';
  }

  /// The second line: where each frame's time went. A low [fps] with a
  /// short span means frames were SCHEDULED rarely (the texture signalled
  /// rarely, or the engine's pipeline stalled), not that they were slow.
  String describeDetail() {
    if (frames == 0) return '—';
    return '$frames in ${windowSecs.toStringAsFixed(0)} s · build '
        '${buildAvgMs.toStringAsFixed(1)} avg / '
        '${buildMaxMs.toStringAsFixed(1)} max · wait '
        '${vsyncWaitAvgMs.toStringAsFixed(1)} avg · span '
        '${spanAvgMs.toStringAsFixed(1)} avg / '
        '${spanMaxMs.toStringAsFixed(1)} max ms';
  }
}

/// Summarizes the [FrameTiming]s whose raster finished within [window] of
/// the newest one. [budgetMs] is the per-frame budget a frame may not
/// overrun (one display refresh — 16.7 ms at 60 Hz). Pure.
FlutterFrameSummary summarizeFrameTimings(
  List<FrameTiming> timings, {
  Duration window = const Duration(seconds: 2),
  double budgetMs = 1000 / 60,
}) {
  if (timings.isEmpty) {
    return FlutterFrameSummary(
      frames: 0,
      fps: 0,
      rasterAvgMs: 0,
      rasterMaxMs: 0,
      overBudget: 0,
      budgetMs: budgetMs,
    );
  }
  final newest = timings
      .map((t) => t.timestampInMicroseconds(FramePhase.rasterFinish))
      .reduce((a, b) => a > b ? a : b);
  final cutoff = newest - window.inMicroseconds;
  final recent = timings
      .where((t) => t.timestampInMicroseconds(FramePhase.rasterFinish) > cutoff)
      .toList();
  if (recent.isEmpty) {
    return summarizeFrameTimings(const [], window: window, budgetMs: budgetMs);
  }
  var rasterSum = 0.0;
  var rasterMax = 0.0;
  var buildSum = 0.0;
  var buildMax = 0.0;
  var waitSum = 0.0;
  var spanSum = 0.0;
  var spanMax = 0.0;
  var over = 0;
  var first = newest;
  for (final t in recent) {
    final raster = t.rasterDuration.inMicroseconds / 1000;
    rasterSum += raster;
    if (raster > rasterMax) rasterMax = raster;
    final build = t.buildDuration.inMicroseconds / 1000;
    buildSum += build;
    if (build > buildMax) buildMax = build;
    waitSum += t.vsyncOverhead.inMicroseconds / 1000;
    final span = t.totalSpan.inMicroseconds / 1000;
    spanSum += span;
    if (span > spanMax) spanMax = span;
    if (span > budgetMs) over++;
    final start = t.timestampInMicroseconds(FramePhase.vsyncStart);
    if (start < first) first = start;
  }
  final spanSecs = (newest - first) / 1e6;
  final fps = recent.length >= 2 && spanSecs > 0
      ? (recent.length - 1) / spanSecs
      : 0.0;
  return FlutterFrameSummary(
    frames: recent.length,
    fps: fps,
    rasterAvgMs: rasterSum / recent.length,
    rasterMaxMs: rasterMax,
    overBudget: over,
    budgetMs: budgetMs,
    buildAvgMs: buildSum / recent.length,
    buildMaxMs: buildMax,
    vsyncWaitAvgMs: waitSum / recent.length,
    spanAvgMs: spanSum / recent.length,
    spanMaxMs: spanMax,
    windowSecs: window.inMilliseconds / 1000,
  );
}

/// One reading of the native video output's render counters (the Linux
/// plugin's `GetRenderInfo` map) stamped with when it was taken. Counters
/// are monotonic since the output was created; [renderPipelineRows]
/// differences two snapshots into per-second rates.
class NativeRenderSnapshot {
  const NativeRenderSnapshot(this.raw, this.at);

  final Map<String, Object?> raw;
  final DateTime at;

  int count(String key) {
    final v = raw[key];
    return v is num ? v.toInt() : 0;
  }

  String text(String key) => (raw[key] ?? '').toString().trim();
  bool flag(String key) => raw[key] == true;

  /// GDK's frame-clock refresh interval in ms, null when unknown.
  double? get gdkRefreshMs {
    final us = count('gdk_refresh_us');
    return us > 0 ? us / 1000 : null;
  }

  /// Host facts for the report's environment section (static per output).
  Map<String, String> environment() {
    String or(String v, String fallback) => v.isEmpty ? fallback : v;
    final backend = text('backend');
    final scale = count('scale_factor');
    return {
      'GL driver': or(
        [text('gl_vendor'), text('gl_renderer'), text('gl_version')]
            .where((p) => p.isNotEmpty)
            .join(' | '),
        'unknown',
      ),
      'EGL': or(
        [text('egl_vendor'), text('egl_version')]
            .where((p) => p.isNotEmpty)
            .join(' '),
        'unknown',
      ),
      'GDK': '${or(backend, 'unknown backend')} · '
          '${flag('composited') ? 'composited' : 'not composited'}'
          '${scale > 0 ? ' · scale $scale' : ''}'
          '${gdkRefreshMs != null ? ' · refresh ${gdkRefreshMs!.toStringAsFixed(2)} ms' : ''}',
      'Pacing: update-via-main': flag('update_via_main') ? '1' : '0 (default)',
      'Pacing: sw-render': flag('sw_forced') ? '1' : '0 (default)',
      if (raw.containsKey('present_hooks')) ...{
        'Present: hooks': flag('present_hooks') ? 'on' : 'off',
        'Present: downscale': count('present_downscale') > 1
            ? '${count('present_downscale')}'
            : '1 (default)',
        'Present: opaque': flag('present_opaque') ? '1' : '0 (default)',
      },
    };
  }
}

/// The two pipeline rows of the stats card — pure over two snapshots.
///
/// `Pipeline` reads "mpv N frames/s → Flutter M renders/s": N is how often
/// mpv signalled a new frame, M how often Flutter actually rendered the
/// texture on its raster thread. M far below N with a short render time
/// means Flutter is not scheduling frames (the engine side), not that the
/// GPU is slow. `GTK` reads the GTK frame-clock tick rate, paint rate and
/// paint duration of the Flutter window: under a compositor GDK freezes the
/// clock until the compositor acknowledges the previous frame, so a low
/// tick rate names the compositor as the pacer; a long paint (the FlView
/// blit plus GDK's GL swap) names a blocking swap on the GTK thread.
///
/// `Present` breaks one presented frame down on X11, where the embedder
/// cannot share Flutter's framebuffer with GDK and copies every frame
/// through the CPU: the size Flutter rendered and the size that crossed the
/// CPU (smaller under `WATCHIT_PRESENT_DOWNSCALE`), the raster thread's wait
/// for the GPU and its readback, the GTK thread's upload, and the paint
/// phase split around the FlView draw (`pre` = GDK's paint surface + window
/// background, `draw` = upload + blit, `swap` = end-of-frame compositing +
/// GL swap). Omitted when the plugin has no such counters.
///
/// Empty without a previous snapshot (rates need
/// an interval) or when the plugin returned no counters.
List<PlaybackStatsRow> renderPipelineRows(
  NativeRenderSnapshot? prev,
  NativeRenderSnapshot? cur,
) {
  if (cur == null || !cur.raw.containsKey('update_count')) return const [];
  if (prev == null) {
    return const [
      (label: 'Pipeline', value: 'measuring…'),
    ];
  }
  final dt = cur.at.difference(prev.at).inMicroseconds / 1e6;
  if (dt <= 0) return const [(label: 'Pipeline', value: 'measuring…')];
  double rate(String key) => (cur.count(key) - prev.count(key)) / dt;
  final updates = rate('update_count');
  final populates = rate('populate_count');
  final dPop = cur.count('populate_count') - prev.count('populate_count');
  final renderAvg = dPop > 0
      ? (cur.count('render_us_total') - prev.count('render_us_total')) /
          dPop /
          1000
      : 0.0;
  final populateAvg = dPop > 0
      ? (cur.count('populate_us_total') - prev.count('populate_us_total')) /
          dPop /
          1000
      : 0.0;
  final renderMax = cur.count('render_us_max') / 1000;
  final ticks = rate('gtk_tick_count');
  final draws = rate('gtk_draw_count');
  // Paint phase = before-paint → after-paint on the view's frame clock: the
  // FlView blit plus GDK's GL swap, i.e. how long the GTK thread is blocked
  // per painted frame. Old plugins without the counter read as zeros.
  final dPaint = cur.count('gtk_paint_count') - prev.count('gtk_paint_count');
  final paintAvg = dPaint > 0
      ? (cur.count('gtk_paint_us_total') - prev.count('gtk_paint_us_total')) /
          dPaint /
          1000
      : 0.0;
  final paintMax = cur.count('gtk_paint_us_max') / 1000;
  final hasPaint = cur.raw.containsKey('gtk_paint_count');
  String r(double v) => v.toStringAsFixed(1);
  double avgMs(String totalKey, int n) => n > 0
      ? (cur.count(totalKey) - prev.count(totalKey)) / n / 1000
      : 0.0;
  // The embedder's X11 frame copies and the paint phase split three ways.
  String? present;
  final hasSplit = cur.raw.containsKey('gtk_pre_us_total');
  final hasCopies = cur.flag('present_hooks');
  if (hasSplit || hasCopies) {
    final parts = <String>[];
    if (hasCopies) {
      final dRead = cur.count('present_readback_count') -
          prev.count('present_readback_count');
      final dUp = cur.count('present_upload_count') -
          prev.count('present_upload_count');
      final fw = cur.count('present_frame_width');
      final fh = cur.count('present_frame_height');
      final cw = cur.count('present_copy_width');
      final ch = cur.count('present_copy_height');
      if (fw > 0 && fh > 0) {
        parts.add(cw == fw && ch == fh
            ? 'frame $fw×$fh'
            : 'frame $fw×$fh → copied $cw×$ch');
      }
      parts.add(dRead > 0
          ? 'gpu wait ${r(avgMs('present_wait_us_total', dRead))}'
              ' · readback ${r(avgMs('present_copy_us_total', dRead))}'
              ' · upload ${r(avgMs('present_upload_us_total', dUp))} ms'
          : 'no CPU copies');
      if (cur.flag('present_opaque')) {
        final dOpaque = cur.count('present_opaque_count') -
            prev.count('present_opaque_count');
        parts.add(dOpaque > 0 ? 'opaque' : 'opaque not applied');
      }
    }
    if (hasSplit && dPaint > 0) {
      parts.add('GTK pre ${r(avgMs('gtk_pre_us_total', dPaint))}'
          ' / draw ${r(avgMs('gtk_draw_us_total', dPaint))}'
          ' / swap ${r(avgMs('gtk_post_us_total', dPaint))} ms');
    }
    if (parts.isNotEmpty) present = parts.join(' · ');
  }
  return [
    (
      label: 'Pipeline',
      value: 'mpv ${r(updates)} frames/s → Flutter ${r(populates)} renders/s'
          ' · render ${r(renderAvg)} avg / ${r(renderMax)} max ms'
          ' · populate ${r(populateAvg)} ms',
    ),
    (
      label: 'GTK',
      value: '${r(ticks)} ticks/s · ${r(draws)} paints/s'
          '${hasPaint ? ' · paint ${r(paintAvg)} avg / ${r(paintMax)} max ms' : ''}'
          '${cur.gdkRefreshMs != null ? ' · refresh ${cur.gdkRefreshMs!.toStringAsFixed(2)} ms' : ''}'
          ' · ${cur.flag('composited') ? 'composited' : 'no compositor'}',
    ),
    if (present != null) (label: 'Present', value: present),
  ];
}

/// Collects [FrameTiming]s from the scheduler while started; the overlay
/// summarizes them each tick. Keeps the newest [capacity] frames only.
class FlutterFrameSampler {
  FlutterFrameSampler({this.capacity = 240});

  final int capacity;
  final List<FrameTiming> _timings = [];
  bool _started = false;

  List<FrameTiming> get timings => List.unmodifiable(_timings);

  void start() {
    if (_started) return;
    _started = true;
    SchedulerBinding.instance.addTimingsCallback(add);
  }

  void stop() {
    if (!_started) return;
    _started = false;
    SchedulerBinding.instance.removeTimingsCallback(add);
  }

  /// Also the test seam: feed timings without a running scheduler.
  void add(List<FrameTiming> timings) {
    _timings.addAll(timings);
    if (_timings.length > capacity) {
      _timings.removeRange(0, _timings.length - capacity);
    }
  }
}

/// The plain-text report a tap on the card copies: the visible rows, the
/// host-supplied environment facts (app version, renderer, display…) and
/// every raw mpv property, so a pasted report carries everything needed
/// to reason about a judder without a follow-up question. Pure.
String playbackStatsReport({
  required List<PlaybackStatsRow> rows,
  Map<String, String> environment = const {},
  Map<String, String?> raw = const {},
  DateTime? now,
}) {
  final b = StringBuffer();
  b.writeln('W@tch playback stats — ${(now ?? DateTime.now()).toIso8601String()}');
  for (final row in rows) {
    b.writeln('${row.label}: ${row.value}');
  }
  if (environment.isNotEmpty) {
    b.writeln('-- environment --');
    environment.forEach((k, v) => b.writeln('$k: $v'));
  }
  if (raw.isNotEmpty) {
    b.writeln('-- mpv --');
    raw.forEach((k, v) {
      final value = (v ?? '').trim();
      b.writeln('$k=${value.isEmpty ? '(unavailable)' : value}');
    });
  }
  return b.toString().trimRight();
}

/// The `I`-key playback-statistics card (UI-DESIGN §5): a small translucent
/// mono panel in the player's top-left corner that re-reads the mpv
/// counters every [interval] and samples Flutter's own frame timings.
/// Tapping the card copies the full [playbackStatsReport] to the
/// clipboard (the card confirms inline — snackbars can't reach a fullscreen
/// route — and through the nearest ScaffoldMessenger when one exists).
/// Diagnostic only — it never changes playback.
class PlaybackStatsOverlay extends StatefulWidget {
  const PlaybackStatsOverlay({
    super.key,
    required this.read,
    this.readRender,
    this.interval = const Duration(seconds: 1),
    this.environment = const {},
    this.frameSampler,
    this.frameBudgetMs = 1000 / 60,
    this.now,
  });

  final MpvPropertyReader read;

  /// Clock for stamping render snapshots (rates = counter delta / elapsed);
  /// null = wall time. Test seam — fake-async zones freeze DateTime.now().
  final DateTime Function()? now;

  /// Reads the native video output's render counters (the Linux plugin's
  /// GetRenderInfo map); null = no pipeline rows. Polled every [interval]
  /// alongside the mpv properties.
  final Future<Map<String, Object?>?> Function()? readRender;
  final Duration interval;

  /// Host facts for the copied report (app version, renderer, display…),
  /// in the order they should print.
  final Map<String, String> environment;

  /// Injected sampler (tests feed it timings); null = the overlay runs its
  /// own against the live scheduler.
  final FlutterFrameSampler? frameSampler;

  /// One display refresh in ms — the per-frame budget the Flutter row
  /// counts overruns against.
  final double frameBudgetMs;

  @override
  State<PlaybackStatsOverlay> createState() => _PlaybackStatsOverlayState();
}

class _PlaybackStatsOverlayState extends State<PlaybackStatsOverlay> {
  Timer? _timer;
  Timer? _copiedTimer;
  Map<String, String?> _props = const {};
  NativeRenderSnapshot? _renderPrev;
  NativeRenderSnapshot? _renderCur;
  bool _reading = false;
  bool _copied = false;
  late final FlutterFrameSampler _sampler;
  late final bool _ownSampler;

  @override
  void initState() {
    super.initState();
    _ownSampler = widget.frameSampler == null;
    _sampler = widget.frameSampler ?? FlutterFrameSampler();
    if (_ownSampler) _sampler.start();
    unawaited(_tick());
    _timer = Timer.periodic(widget.interval, (_) => unawaited(_tick()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _copiedTimer?.cancel();
    if (_ownSampler) _sampler.stop();
    super.dispose();
  }

  Future<void> _tick() async {
    if (_reading) return; // a slow player never stacks reads
    _reading = true;
    try {
      final props = await readPlaybackStats(widget.read);
      Map<String, Object?>? render;
      if (widget.readRender != null) {
        try {
          render = await widget.readRender!();
        } catch (_) {
          render = null;
        }
      }
      if (mounted) {
        setState(() {
          _props = props;
          if (render != null) {
            _renderPrev = _renderCur;
            _renderCur = NativeRenderSnapshot(
              render,
              (widget.now ?? DateTime.now)(),
            );
          }
        });
      }
    } finally {
      _reading = false;
    }
  }

  /// GDK's real refresh interval beats the caller's budget when known
  /// (Flutter reports no refresh rate on Linux).
  double get _budgetMs => _renderCur?.gdkRefreshMs ?? widget.frameBudgetMs;

  List<PlaybackStatsRow> _rows() => [
        ...playbackStatsRows(
          _props,
          frames: summarizeFrameTimings(
            _sampler.timings,
            budgetMs: _budgetMs,
          ),
        ),
        ...renderPipelineRows(_renderPrev, _renderCur),
      ];

  Map<String, String> _environment() => {
        ...widget.environment,
        ...?_renderCur?.environment(),
      };

  Future<void> _copy() async {
    final text = playbackStatsReport(
      rows: _rows(),
      environment: _environment(),
      raw: _props,
    );
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _copied = true);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('Playback stats copied to the clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final rows = _rows();
    final style = TextStyle(
      fontSize: 11.5,
      height: 1.35,
      color: t.bone,
      fontFamily: wiMonoFamily,
      fontFamilyFallback: wiMonoFallback,
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => unawaited(_copy()),
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'PLAYBACK STATS',
              style: style.copyWith(
                fontSize: 10,
                color: t.accent,
                letterSpacing: 1.2,
              ),
            ),
            for (final row in rows)
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 72,
                    child: Text(
                      row.label,
                      style: style.copyWith(color: t.boneDim),
                    ),
                  ),
                  Flexible(child: Text(row.value, style: style)),
                ],
              ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _copied ? 'Copied to clipboard' : 'tap to copy for a report',
                style: style.copyWith(
                  fontSize: 10,
                  color: _copied ? t.accent : t.boneDim,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
