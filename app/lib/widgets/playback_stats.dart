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
    if (frames != null) (label: 'Flutter', value: frames.describe()),
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

/// Flutter's own frame health over a recent window — the half of "jerky"
/// mpv can't see. mpv renders into a texture; Flutter composites that
/// texture on its raster thread once per scheduled frame, so a raster
/// thread that is slow (software rendering, a heavy compositor) or frames
/// that overrun the vsync budget stutter the video even with every mpv
/// counter at zero. Built from [FrameTiming]s (SchedulerBinding's
/// timings callback) by [summarizeFrameTimings].
class FlutterFrameSummary {
  const FlutterFrameSummary({
    required this.frames,
    required this.fps,
    required this.rasterAvgMs,
    required this.rasterMaxMs,
    required this.overBudget,
    required this.budgetMs,
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

  String describe() {
    if (frames == 0) return '—';
    return '${fps.toStringAsFixed(1)} fps · raster '
        '${rasterAvgMs.toStringAsFixed(1)} avg / '
        '${rasterMaxMs.toStringAsFixed(1)} max ms · '
        '$overBudget over ${budgetMs.toStringAsFixed(1)} ms';
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
  var over = 0;
  var first = newest;
  for (final t in recent) {
    final raster = t.rasterDuration.inMicroseconds / 1000;
    rasterSum += raster;
    if (raster > rasterMax) rasterMax = raster;
    if (t.totalSpan.inMicroseconds / 1000 > budgetMs) over++;
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
  );
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
    this.interval = const Duration(seconds: 1),
    this.environment = const {},
    this.frameSampler,
    this.frameBudgetMs = 1000 / 60,
  });

  final MpvPropertyReader read;
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
      if (mounted) setState(() => _props = props);
    } finally {
      _reading = false;
    }
  }

  List<PlaybackStatsRow> _rows() => playbackStatsRows(
        _props,
        frames: summarizeFrameTimings(
          _sampler.timings,
          budgetMs: widget.frameBudgetMs,
        ),
      );

  Future<void> _copy() async {
    final text = playbackStatsReport(
      rows: _rows(),
      environment: widget.environment,
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
                  Text(row.value, style: style),
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
