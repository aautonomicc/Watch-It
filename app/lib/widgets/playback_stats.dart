import 'dart:async';

import 'package:flutter/material.dart';

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
  'demuxer-cache-duration',
  'video-bitrate',
  'audio-codec-name',
  'audio-codec',
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
/// bottleneck.
List<PlaybackStatsRow> playbackStatsRows(Map<String, String?> props) {
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
    (label: 'Buffered', value: '$cache ahead · $rate'),
    // `audio-codec-name` is the short tag; `audio-codec` the long form —
    // whichever this mpv answers (both blank with no audio device).
    (label: 'Audio', value: or('audio-codec-name', or('audio-codec', '—'))),
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

/// The `I`-key playback-statistics card (UI-DESIGN §5): a small translucent
/// mono panel in the player's top-left corner that re-reads the mpv
/// counters every [interval]. Diagnostic only — it never changes playback.
class PlaybackStatsOverlay extends StatefulWidget {
  const PlaybackStatsOverlay({
    super.key,
    required this.read,
    this.interval = const Duration(seconds: 1),
  });

  final MpvPropertyReader read;
  final Duration interval;

  @override
  State<PlaybackStatsOverlay> createState() => _PlaybackStatsOverlayState();
}

class _PlaybackStatsOverlayState extends State<PlaybackStatsOverlay> {
  Timer? _timer;
  Map<String, String?> _props = const {};
  bool _reading = false;

  @override
  void initState() {
    super.initState();
    unawaited(_tick());
    _timer = Timer.periodic(widget.interval, (_) => unawaited(_tick()));
  }

  @override
  void dispose() {
    _timer?.cancel();
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

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final rows = playbackStatsRows(_props);
    final style = TextStyle(
      fontSize: 11.5,
      height: 1.35,
      color: t.bone,
      fontFamily: wiMonoFamily,
      fontFamilyFallback: wiMonoFallback,
    );
    return IgnorePointer(
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
          ],
        ),
      ),
    );
  }
}
