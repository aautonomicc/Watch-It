import 'dart:convert';
import 'dart:io';

/// Media file classification + embedded tags via ffprobe (the same tool
/// the app bundles). `ffprobe` must be on PATH.
class MediaProbe {
  MediaProbe({
    required this.hasAudio,
    required this.hasRealVideo,
    this.width,
    this.height,
    this.durationSeconds,
    this.tags = const {},
  });

  final bool hasAudio;

  /// True when the file has a genuine moving-picture stream — cover art
  /// (`attached_pic`) and still-image codecs don't count.
  final bool hasRealVideo;
  final int? width;
  final int? height;
  final double? durationSeconds;

  /// Format + stream tags, keys lowercased with spaces/underscores
  /// normalized to `_` (ffprobe key spelling varies by container).
  final Map<String, String> tags;

  /// Music vs video per the locked rule: audio-only, or audio + only
  /// still/attached-picture video (an m/v toggle at confirm covers music
  /// videos that trip this).
  bool get isMusic => hasAudio && !hasRealVideo;

  String? tag(String key) => tags[_normKey(key)];

  int? get trackNumber => _leadInt(tag('track'));
  int? get trackTotal => _slashTotal(tag('track')) ?? _leadInt(tag('tracktotal'));
  int? get discNumber => _leadInt(tag('disc'));
  int? get discTotal => _slashTotal(tag('disc')) ?? _leadInt(tag('disctotal'));
  int? get year {
    for (final k in ['date', 'year', 'originalyear', 'origdate']) {
      final m = RegExp(r'(19|20)\d{2}').firstMatch(tag(k) ?? '');
      if (m != null) return int.parse(m.group(0)!);
    }
    return null;
  }

  String? get releaseMbid =>
      tag('musicbrainz_albumid') ?? tag('musicbrainz_album_id');
  String? get recordingMbid =>
      tag('musicbrainz_trackid') ?? tag('musicbrainz_track_id');
}

int? _leadInt(String? s) {
  if (s == null) return null;
  final m = RegExp(r'^\s*(\d+)').firstMatch(s);
  return m == null ? null : int.parse(m.group(1)!);
}

int? _slashTotal(String? s) {
  if (s == null) return null;
  final m = RegExp(r'^\s*\d+\s*/\s*(\d+)').firstMatch(s);
  return m == null ? null : int.parse(m.group(1)!);
}

String _normKey(String k) =>
    k.toLowerCase().replaceAll(RegExp(r'[\s_]+'), '_');

const _stillImageCodecs = {'mjpeg', 'png', 'bmp', 'gif', 'tiff', 'webp'};

/// Parse `ffprobe -print_format json -show_format -show_streams` output.
/// Split out from [probeFile] so tests can feed canned JSON.
MediaProbe parseFfprobeJson(String jsonText) {
  final doc = jsonDecode(jsonText) as Map<String, dynamic>;
  final streams = (doc['streams'] as List<dynamic>? ?? const [])
      .cast<Map<String, dynamic>>();
  final format = doc['format'] as Map<String, dynamic>? ?? const {};

  var hasAudio = false, hasRealVideo = false;
  int? width, height;
  final tags = <String, String>{};
  void addTags(Object? raw) {
    if (raw is Map) {
      raw.forEach((k, v) => tags[_normKey('$k')] = '$v');
    }
  }

  addTags(format['tags']);
  for (final s in streams) {
    final type = s['codec_type'];
    if (type == 'audio') hasAudio = true;
    if (type == 'video') {
      final attached =
          (s['disposition'] as Map<String, dynamic>?)?['attached_pic'] == 1;
      final still = _stillImageCodecs.contains(s['codec_name']);
      if (!attached && !still) {
        hasRealVideo = true;
        width ??= s['width'] as int?;
        height ??= s['height'] as int?;
      }
    }
    addTags(s['tags']);
  }
  return MediaProbe(
    hasAudio: hasAudio,
    hasRealVideo: hasRealVideo,
    width: width,
    height: height,
    durationSeconds: double.tryParse('${format['duration']}'),
    tags: tags,
  );
}

/// Run ffprobe on [path]. Returns null (with a stderr note) when ffprobe
/// is missing or the file is not media.
Future<MediaProbe?> probeFile(String path) async {
  try {
    final result = await Process.run('ffprobe', [
      '-v', 'quiet',
      '-print_format', 'json',
      '-show_format',
      '-show_streams',
      path,
    ]);
    if (result.exitCode != 0) return null;
    return parseFfprobeJson(result.stdout as String);
  } on ProcessException {
    stderr.writeln('warning: ffprobe not found on PATH — '
        'cannot classify or read tags');
    return null;
  } catch (_) {
    return null;
  }
}
